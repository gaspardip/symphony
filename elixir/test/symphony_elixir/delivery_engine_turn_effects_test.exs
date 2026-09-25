defmodule SymphonyElixir.DeliveryEngine.TurnEffectsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentProvider.Claude
  alias SymphonyElixir.AgentProvider.CodexCLI
  alias SymphonyElixir.DeliveryEngine.TurnEffects

  @profiles [{:claude_cli, Claude, Claude.StreamState}, {:codex_cli, CodexCLI, CodexCLI.StreamState}]
  @env_keys ["SYMPHONY_P3A_ROOT", "SYMPHONY_P3A_GIT", "SYMPHONY_P3A_FAIL_GIT", "SYMPHONY_P3A_MIX_STATUS", "SYMPHONY_P3A_EXIT"]

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-p3a-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace with spaces")
    bin = Path.join(root, "bin")
    File.mkdir_p!(workspace)
    File.mkdir_p!(bin)
    previous_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    git = System.find_executable("git")

    System.put_env("SYMPHONY_P3A_ROOT", root)
    System.put_env("SYMPHONY_P3A_GIT", git)
    System.delete_env("SYMPHONY_P3A_FAIL_GIT")
    System.put_env("SYMPHONY_P3A_MIX_STATUS", "0")
    System.put_env("SYMPHONY_P3A_EXIT", "0")

    for args <- [["init", "-q"], ["config", "user.name", "Symphony Test"], ["config", "user.email", "test@example.invalid"]] do
      git!(workspace, args)
    end

    write_progress!(workspace)
    File.write!(Path.join(workspace, ".symphony/progress/turn.md"), "## Work Log\nOriginal\n\n## Evidence\nOriginal\n")
    File.write!(Path.join(workspace, "existing.txt"), "original\n")
    git!(workspace, ["add", "-A"])
    git!(workspace, ["commit", "-qm", "initial"])
    git!(workspace, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    File.write!(Path.join(root, "commands"), "")

    write_executable!(Path.join(bin, "git"), """
    printf 'git %s\\n' "$*" >> "$SYMPHONY_P3A_ROOT/commands"
    if [ -n "$SYMPHONY_P3A_FAIL_GIT" ] && [ "$*" = "$SYMPHONY_P3A_FAIL_GIT" ]; then
      exit 2
    fi
    exec "$SYMPHONY_P3A_GIT" "$@"
    """)

    write_executable!(Path.join(bin, "mix"), """
    printf 'mix %s\\n' "$*" >> "$SYMPHONY_P3A_ROOT/commands"
    cp ../.symphony/progress/turn.md "$SYMPHONY_P3A_ROOT/progress-at-format"
    exit "$SYMPHONY_P3A_MIX_STATUS"
    """)

    for name <- ["claude", "codex"] do
      write_executable!(Path.join(bin, name), """
      printf 'transport\\n' >> "$SYMPHONY_P3A_ROOT/commands"
      cat "$SYMPHONY_P3A_ROOT/stream"
      exit "$SYMPHONY_P3A_EXIT"
      """)
    end

    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace}
  end

  for {profile, provider, state_module} <- @profiles do
    @profile profile
    @provider provider
    @state_module state_module

    test "P3-B1-02 #{@profile}: delivery boundary preserves order, commit, callback process and result", context do
      prepare_changed_workspace!(context)
      write_stream!(context.root, @profile)
      caller = self()
      before_head = git!(context.workspace, ["rev-parse", "HEAD"])

      executor = fn tool, arguments ->
        assert self() == caller
        Process.put(:p3a_report, arguments)
        append_step(context.root, "synthesis")
        assert tool == "report_agent_turn_result"
        assert git!(context.workspace, ["status", "--porcelain"]) == ""
        assert git!(context.workspace, ["show", "HEAD:.symphony/progress/turn.md"]) == expected_progress()
        %{"success" => true}
      end

      on_message = fn event ->
        if event.event == :turn_completed do
          assert Process.get(:p3a_report)["summary"] == "Implemented change"
          append_step(context.root, "completed")
        end
      end

      assert {:ok, session} = @provider.start_session(context.workspace, model: "test-model")
      assert {:ok, result} = run_delivery(@provider, session, "task", %{identifier: "P3-A01"}, tool_executor: executor, on_message: on_message)
      assert result.result == :turn_completed
      assert result.session_id == session.session_id
      assert result.usage == %{input_tokens: 7, output_tokens: 3}
      assert Process.get(:p3a_report) == expected_report(false)
      refute git!(context.workspace, ["rev-parse", "HEAD"]) == before_head
      assert git!(context.workspace, ["log", "-1", "--format=%s"]) == "Implemented change\n"
      assert File.read!(Path.join(context.root, "progress-at-format")) == expected_progress()

      assert command_steps(context.root) ==
               ["transport"] ++
                 detection_steps(@profile) ++
                 [
                   "mix format",
                   "git add -A",
                   "git diff --cached --quiet",
                   "git commit -m Implemented change",
                   "synthesis",
                   "completed"
                 ]
    end

    test "P3-A02 #{@profile}: Git observation retains profile and original stream struct", context do
      File.write!(Path.join(context.workspace, "committed.txt"), "already committed\n")
      git!(context.workspace, ["add", "-A"])
      git!(context.workspace, ["commit", "-qm", "prior turn"])
      File.write!(Path.join(context.workspace, "existing.txt"), "changed\n")
      File.write!(Path.join(context.workspace, "untracked.txt"), "new\n")
      state = struct!(@state_module, files_touched: ["stream.txt", "existing.txt"], error: "retained")
      assert {:ok, updated} = TurnEffects.detect_changed_files(state, context.workspace, @profile)
      expected_files = if @profile == :claude_cli, do: ["stream.txt", "existing.txt", "untracked.txt"], else: ["stream.txt", "existing.txt", "untracked.txt", "committed.txt"]
      assert updated == %{state | files_touched: expected_files}
      assert updated.__struct__ == @state_module
    end

    test "P3-B1-03 #{@profile}: empty progress stays unchanged without triggering a commit", context do
      write_progress!(context.workspace)
      git!(context.workspace, ["add", "-A"])
      git!(context.workspace, ["commit", "-qm", "progress"])
      git!(context.workspace, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      before_head = git!(context.workspace, ["rev-parse", "HEAD"])
      File.write!(Path.join(context.root, "stream"), "")
      assert {:ok, session} = @provider.start_session(context.workspace)
      assert {:ok, %{result: :turn_completed}} = run_delivery(@provider, session, "task", %{identifier: "P3-A03"})
      assert git!(context.workspace, ["rev-parse", "HEAD"]) == before_head
      assert File.read!(Path.join(context.workspace, ".symphony/progress/turn.md")) == "## Work Log\n\n## Evidence\n\n"
      assert command_steps(context.root) == ["transport"] ++ detection_steps(@profile)
    end

    test "P3-B1-06 #{@profile}: failed transport reports blocked without preparing or committing", context do
      prepare_changed_workspace!(context)
      write_stream!(context.root, @profile)
      System.put_env("SYMPHONY_P3A_EXIT", "9")
      before_head = git!(context.workspace, ["rev-parse", "HEAD"])
      assert {:ok, session} = @provider.start_session(context.workspace)

      assert {:ok, %{result: :turn_failed}} =
               run_delivery(@provider, session, "task", %{identifier: "P3-A04"},
                 tool_executor: fn _, result ->
                   Process.put(:p3a_failed_report, result)
                   %{"success" => true}
                 end
               )

      assert Process.get(:p3a_failed_report) == %{expected_report(true) | "files_touched" => ["existing.txt"]}
      assert git!(context.workspace, ["rev-parse", "HEAD"]) == before_head
      assert File.read!(Path.join(context.workspace, ".symphony/progress/turn.md")) == expected_progress()
      assert command_steps(context.root) == ["transport"]
    end

    test "P3-B1-07 #{@profile}: executor throw is caught by delivery after commit", context do
      prepare_changed_workspace!(context)
      write_stream!(context.root, @profile)
      caller = self()
      assert {:ok, session} = @provider.start_session(context.workspace)

      assert {:error, {:turn_effect_failed, %{step: :report_turn_result, reason: {:executor_exception, :throw, :executor_failed}}}} =
               run_delivery(@provider, session, "task", %{identifier: "P3-A05"},
                 tool_executor: fn _, _ -> throw(:executor_failed) end,
                 on_message: fn event -> send(caller, {:p3a_event, event.event}) end
               )

      assert_receive {:p3a_event, :turn_ended_with_error}
      refute_receive {:p3a_event, :turn_completed}
      assert git!(context.workspace, ["log", "-1", "--format=%s"]) == "Implemented change\n"
    end

    test "P3-A06 #{@profile}: existing defaults, empty paths and false error are not normalized" do
      state = struct!(@state_module, files_touched: ["a", "", "a", "b"], error: false)

      assert {:ok, report} = TurnEffects.synthesize_turn_result(state, fn _, _ -> %{"success" => true} end)

      assert report == %{
               "summary" => "Turn completed.",
               "files_touched" => ["a", "b"],
               "needs_another_turn" => false,
               "blocked" => true,
               "blocker_type" => "none"
             }
    end

    for {failing_step, command, prefix} <- [
          {:format, nil, ["mix format"]},
          {:stage, "add -A", ["mix format", "git add -A"]},
          {:index_diff, "diff --cached --quiet", ["mix format", "git add -A", "git diff --cached --quiet"]},
          {:commit, "commit -m Implemented change", ["mix format", "git add -A", "git diff --cached --quiet", "git commit -m Implemented change"]}
        ] do
      @failing_step failing_step
      @failed_command command
      @prefix prefix
      test "P3-B2-04/05/06/07 #{@profile}: #{@failing_step} stops subsequent effects", context do
        prepare_changed_workspace!(context)
        write_stream!(context.root, @profile)
        if @failing_step == :format, do: System.put_env("SYMPHONY_P3A_MIX_STATUS", "2"), else: System.put_env("SYMPHONY_P3A_FAIL_GIT", @failed_command)
        before_head = git!(context.workspace, ["rev-parse", "HEAD"])
        assert {:ok, session} = @provider.start_session(context.workspace)
        caller = self()

        log =
          capture_log(fn ->
            assert {:error, {:turn_effect_failed, %{step: @failing_step, reason: {:exit_status, 2}, output: ""}}} =
                     run_delivery(@provider, session, "task", %{},
                       tool_executor: fn _, _ -> flunk("report after command failure") end,
                       on_message: fn event -> send(caller, {:failed_effect, event.event}) end
                     )
          end)

        refute log =~ "Auto-committed"
        assert_receive {:failed_effect, :turn_ended_with_error}
        refute_receive {:failed_effect, :turn_completed}
        refute_receive {:failed_effect, :turn_ended_with_error}
        assert command_steps(context.root) == ["transport"] ++ detection_steps(@profile) ++ @prefix
        assert git!(context.workspace, ["rev-parse", "HEAD"]) == before_head
        if @failing_step in [:index_diff, :commit], do: assert(git!(context.workspace, ["diff", "--cached", "--name-only"]) != "")
      end
    end
  end

  for {profile, provider, command, expected_steps} <- [
        {:claude_cli, Claude, "diff --name-only HEAD", ["git diff --name-only HEAD"]},
        {:claude_cli, Claude, "ls-files --others --exclude-standard", ["git diff --name-only HEAD", "git ls-files --others --exclude-standard"]},
        {:codex_cli, CodexCLI, "status --porcelain", ["git status --porcelain"]},
        {:codex_cli, CodexCLI, "diff origin/main --name-only", ["git status --porcelain", "git diff origin/main --name-only"]}
      ] do
    @profile profile
    @provider provider
    @command command
    @expected_steps expected_steps
    test "P3-B2-01 #{@profile}: #{@command} fails despite stream evidence", context do
      System.put_env("SYMPHONY_P3A_FAIL_GIT", @command)
      result = observation(@profile, ["stream.txt"])
      caller = self()
      opts = [tool_executor: fn _, _ -> flunk("report after detection failure") end, on_message: fn event -> send(caller, {:detection_event, event.event}) end]
      assert {:error, {:turn_effect_failed, details}} = TurnEffects.apply_result(@provider, result, context.workspace, %{}, opts, :delivery)
      assert details == %{step: :detect_changes, reason: {:exit_status, 2}, executable: "git", argv: String.split(@command), cwd: context.workspace, output: ""}
      assert command_steps(context.root) == @expected_steps
      assert_receive {:detection_event, :turn_ended_with_error}
      refute_receive {:detection_event, _}
    end
  end

  defmodule OpaqueProvider do
    def run_turn(%{opaque: true}, _prompt, _issue, opts) do
      Keyword.fetch!(opts, :on_message).(%{event: :custom_finished})
      {:ok, %{result: :turn_completed, session_id: "opaque", usage: %{input_tokens: 2, output_tokens: 1}, cli_observation: :custom_owned}}
    end
  end

  for {profile, provider, _state_module} <- @profiles do
    @profile profile
    @provider provider

    test "P3-B1-01 #{@profile}: direct transport cannot prepare a dirty workspace", context do
      prepare_changed_workspace!(context)
      write_stream!(context.root, @profile)
      before = workspace_bytes(context.workspace)
      caller = self()
      assert {:ok, session} = @provider.start_session(context.workspace, model: "test-model")
      opts = [tool_executor: fn _, _ -> flunk("transport synthesized delivery") end, on_message: fn message -> send(caller, {:direct_event, message.event}) end]
      assert {:ok, result} = @provider.run_turn(session, "task", %{identifier: "B1-direct"}, opts)
      assert result.cli_observation == %{profile: @profile, files_touched: ["existing.txt"], result_text: "Implemented change", error: nil}
      assert result.usage == %{input_tokens: 7, output_tokens: 3}
      assert workspace_bytes(context.workspace) == before
      assert command_steps(context.root) == ["transport"]
      assert_receive {:direct_event, :notification}
      refute_receive {:direct_event, :turn_completed}
      refute_receive {:direct_event, :turn_ended_with_error}
    end

    test "P3-B1-09 #{@profile}: partial final callback delivery is followed by one error", context do
      write_stream!(context.root, @profile)
      caller = self()
      assert {:ok, session} = @provider.start_session(context.workspace)

      on_message = fn message ->
        send(caller, {:terminal_attempt, message.event})
        if message.event == :turn_completed, do: throw(:final_callback_failed)
      end

      assert {:error, {:throw, :final_callback_failed}} = run_delivery(@provider, session, "task", %{}, on_message: on_message)
      assert_receive {:terminal_attempt, :turn_completed}
      assert_receive {:terminal_attempt, :turn_ended_with_error}
      refute_receive {:terminal_attempt, :turn_ended_with_error}
      assert Enum.count(command_steps(context.root), &(&1 == "git add -A")) == 1
    end

    test "P3-B1-08 #{@profile}: stream callback failure belongs to transport only", context do
      write_stream!(context.root, @profile)
      caller = self()
      assert {:ok, session} = @provider.start_session(context.workspace)

      callback = fn message ->
        send(caller, {:stream_attempt, message.event})
        if message.event == :notification, do: throw(:stream_callback_failed)
      end

      assert {:error, {:throw, :stream_callback_failed}} = run_delivery(@provider, session, "task", %{}, on_message: callback)
      assert_receive {:stream_attempt, :notification}
      assert_receive {:stream_attempt, :turn_ended_with_error}
      refute_receive {:stream_attempt, :turn_completed}
      refute_receive {:stream_attempt, :turn_ended_with_error}
      assert command_steps(context.root) == ["transport"]
    end

    test "P3-B1-12 #{@profile}: a reused handle emits one engine terminal per invocation", context do
      caller = self()
      assert {:ok, session} = @provider.start_session(context.workspace)
      opts = [on_message: fn message -> send(caller, {:usage_event, message}) end]

      for {first_usage, final_usage} <- [
            {%{input_tokens: 2, output_tokens: 1}, %{input_tokens: 7, output_tokens: 3}},
            {%{input_tokens: 1, output_tokens: 1}, %{input_tokens: 3, output_tokens: 2}}
          ] do
        event_types = if @profile == :claude_cli, do: ["message_delta", "result"], else: ["turn.completed", "turn.completed"]

        events =
          Enum.zip_with(event_types, [first_usage, final_usage], fn type, usage ->
            %{"type" => type, "usage" => usage}
          end)

        File.write!(Path.join(context.root, "stream"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")

        assert {:ok, %{session_id: id, usage: ^final_usage}} = run_delivery(@provider, session, "task", %{}, opts)
        assert id == session.session_id
        assert_receive {:usage_event, %{event: :notification, usage: ^first_usage}}
        assert_receive {:usage_event, %{event: :notification, usage: ^final_usage}}
        assert_receive {:usage_event, %{event: :turn_completed, usage: ^final_usage}}
        refute_receive {:usage_event, _}
      end
    end

    test "P3-B1-10 #{@profile}: invalid observation is rejected before effects", context do
      caller = self()

      invalid_results = [
        %{result: :turn_completed, usage: %{}},
        %{result: :turn_completed, usage: %{}, cli_observation: %{profile: :wrong, files_touched: [], result_text: nil, error: nil}},
        %{result: :turn_completed, usage: %{}, cli_observation: %{profile: @profile, files_touched: [1], result_text: nil, error: nil}},
        %{result: :turn_completed, usage: %{}, cli_observation: %{profile: @profile, files_touched: [], result_text: nil}}
      ]

      for result <- invalid_results do
        assert {:error, {:invalid_cli_observation, @profile}} =
                 TurnEffects.apply_result(@provider, {:ok, result}, context.workspace, %{}, [on_message: fn message -> send(caller, {:invalid_event, message.event}) end], :delivery)

        assert_receive {:invalid_event, :turn_ended_with_error}
        refute_receive {:invalid_event, :turn_ended_with_error}
      end

      assert command_steps(context.root) == []

      assert catch_throw(
               TurnEffects.apply_result(
                 @provider,
                 {:ok, %{}},
                 context.workspace,
                 %{},
                 [
                   on_message: fn message ->
                     send(caller, {:invalid_throw, message.event})
                     throw(:error_callback_failed)
                   end
                 ],
                 :delivery
               )
             ) == :error_callback_failed

      assert_receive {:invalid_throw, :turn_ended_with_error}
      refute_receive {:invalid_throw, :turn_ended_with_error}
    end

    test "P3-B1-06 #{@profile}: timeout skips preparation for delivery and verifier", context do
      write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: 1)
      name = if @profile == :claude_cli, do: "claude", else: "codex"
      write_executable!(Path.join([context.root, "bin", name]), "exec sleep 2\n")
      assert {:ok, session} = @provider.start_session(context.workspace)
      before = workspace_bytes(context.workspace)

      for purpose <- [:delivery, :verifier] do
        Process.delete(:timeout_report)

        opts = [
          tool_executor: fn _, report ->
            Process.put(:timeout_report, report)
            %{"success" => true}
          end
        ]

        result = @provider.run_turn(session, "task", %{}, opts)
        assert {:ok, %{result: :turn_failed, cli_observation: %{error: "timeout"}}} = result
        assert ^result = TurnEffects.apply_result(@provider, result, context.workspace, %{}, opts, purpose)
        if purpose == :delivery, do: assert(Process.get(:timeout_report)["blocked"]), else: assert(Process.get(:timeout_report) == nil)
      end

      assert workspace_bytes(context.workspace) == before
      assert command_steps(context.root) == []
    end
  end

  test "P3-B1-11: opaque providers and ErrorHandler retain transport-only contracts", context do
    caller = self()
    opts = [on_message: fn event -> send(caller, event) end]
    {result, log} = SymphonyElixir.DeliveryEngine.ErrorHandler.run_logged_agent_turn(OpaqueProvider, %{opaque: true}, "task", %{}, opts)
    assert {:ok, %{cli_observation: :custom_owned}} = result
    assert log.duration_ms >= 0
    assert_receive %{event: :custom_finished}

    for provider <- [OpaqueProvider, SymphonyElixir.AgentProvider.Codex], purpose <- [:delivery, :verifier] do
      assert TurnEffects.apply_result(provider, result, context.workspace, %{}, opts, purpose) == result
      assert TurnEffects.apply_result(provider, {:error, :original}, context.workspace, %{}, opts, purpose) == {:error, :original}
    end

    refute_receive %{event: _}
    assert command_steps(context.root) == []
  end

  test "P3-B1-09: error callback after final failure escapes without recursive notification", context do
    callback = fn message ->
      send(self(), {:double_failure, message.event})
      throw(message.event)
    end

    result = {:ok, %{result: :turn_completed, usage: %{}, cli_observation: %{profile: :claude_cli, files_touched: [], result_text: nil, error: nil}}}
    assert catch_throw(TurnEffects.apply_result(Claude, result, context.workspace, %{}, [on_message: callback], :verifier)) == :turn_ended_with_error
    assert_receive {:double_failure, :turn_completed}
    assert_receive {:double_failure, :turn_ended_with_error}
    refute_receive {:double_failure, _}
  end

  test "P3-B1-07: raised executor failure is returned after effects without retry", context do
    prepare_changed_workspace!(context)
    write_stream!(context.root, :claude_cli)
    assert {:ok, session} = Claude.start_session(context.workspace)
    caller = self()

    assert {:error, {:turn_effect_failed, %{step: :report_turn_result, reason: {:executor_exception, :error, %RuntimeError{message: "executor raised"}}}}} =
             run_delivery(Claude, session, "task", %{}, tool_executor: fn _, _ -> raise "executor raised" end, on_message: fn event -> send(caller, {:raised_event, event.event}) end)

    assert_receive {:raised_event, :turn_ended_with_error}
    refute_receive {:raised_event, :turn_completed}
    refute_receive {:raised_event, :turn_ended_with_error}
    assert Enum.count(command_steps(context.root), &(&1 == "git commit -m Implemented change")) == 1
  end

  test "P3-B1-08: transport error callback failure escapes without another event", context do
    write_stream!(context.root, :claude_cli)
    assert {:ok, session} = Claude.start_session(context.workspace)
    caller = self()

    callback = fn event ->
      send(caller, {:transport_failure, event.event})
      throw(event.event)
    end

    assert catch_throw(run_delivery(Claude, session, "task", %{}, on_message: callback)) == :turn_ended_with_error
    assert_receive {:transport_failure, :notification}
    assert_receive {:transport_failure, :turn_ended_with_error}
    refute_receive {:transport_failure, :turn_ended_with_error}
    assert command_steps(context.root) == ["transport"]
  end

  test "P3-B1-11: ErrorHandler invokes CLI transport without restoring delivery policy", context do
    prepare_changed_workspace!(context)
    write_stream!(context.root, :claude_cli)
    before = workspace_bytes(context.workspace)
    assert {:ok, session} = Claude.start_session(context.workspace)
    {result, _log} = SymphonyElixir.DeliveryEngine.ErrorHandler.run_logged_agent_turn(Claude, session, "task", %{}, tool_executor: fn _, _ -> flunk("transport-only API synthesized delivery") end)
    assert {:ok, %{cli_observation: %{profile: :claude_cli}}} = result
    assert workspace_bytes(context.workspace) == before
    assert command_steps(context.root) == ["transport"]
  end

  test "P3-B1-03: real publish gate still rejects missing evidence", context do
    for dir <- ["knowledge", "features"], do: File.mkdir_p!(Path.join(context.workspace, ".symphony/#{dir}"))

    harness = %SymphonyElixir.RepoHarness{
      agent_harness: %{
        knowledge: %{root: ".symphony/knowledge", required_files: []},
        features: %{root: ".symphony/features", required_fields: []},
        progress: %{root: ".symphony/progress", pattern: "turn.md", required_sections: ["Work Log", "Evidence"]},
        publish_gate: %{require_progress: true, require_feature_update_on_code_change: false}
      }
    }

    write_progress!(context.workspace)
    assert {:error, {:invalid_progress_file, "turn.md", {:missing_sections, ["Work Log", "Evidence"]}}} = SymphonyElixir.AgentHarness.publish_gate(context.workspace, %{identifier: "B1"}, harness)
    File.write!(Path.join(context.workspace, ".symphony/progress/turn.md"), "## Work Log\nActual change\n")
    assert {:error, {:invalid_progress_file, "turn.md", {:missing_sections, ["Evidence"]}}} = SymphonyElixir.AgentHarness.publish_gate(context.workspace, %{identifier: "B1"}, harness)
  end

  test "P3-B2-02: missing origin/main is explicit and creates no fallback ref", context do
    git!(context.workspace, ["update-ref", "-d", "refs/remotes/origin/main"])
    File.write!(Path.join(context.workspace, "existing.txt"), "changed\n")
    before_refs = git!(context.workspace, ["show-ref"])

    assert {:error, {:turn_effect_failed, %{step: :detect_changes, reason: {:exit_status, 128}, argv: ["diff", "origin/main", "--name-only"], output: output}}} =
             TurnEffects.apply_result(CodexCLI, observation(:codex_cli, ["existing.txt"]), context.workspace, %{}, [tool_executor: fn _, _ -> flunk("missing ref reported success") end], :delivery)

    assert output =~ "origin/main"
    assert git!(context.workspace, ["show-ref"]) == before_refs
    assert command_steps(context.root) == detection_steps(:codex_cli)
  end

  test "P3-B2-03: missing HEAD and non-repository are detection errors", context do
    empty_repo = Path.join(context.root, "empty")
    not_repo = Path.join(context.root, "not-repo")
    File.mkdir_p!(empty_repo)
    File.mkdir_p!(not_repo)
    git!(empty_repo, ["init", "-q"])

    for {workspace, exit_status, expected_output} <- [{empty_repo, 128, "HEAD"}, {not_repo, 129, "Not a git repository"}] do
      assert {:error, {:turn_effect_failed, %{step: :detect_changes, reason: {:exit_status, ^exit_status}, output: output, executable: "git", argv: ["diff", "--name-only", "HEAD"], cwd: ^workspace}}} =
               TurnEffects.detect_changed_files(%Claude.StreamState{}, workspace, :claude_cli)

      assert output != ""
      assert output =~ expected_output
    end
  end

  test "P3-B2-04: partial formatter writes remain after its failure", context do
    prepare_changed_workspace!(context)
    write_executable!(Path.join([context.root, "bin", "mix"]), "printf 'mix format\\n' >> \"$SYMPHONY_P3A_ROOT/commands\"\nprintf partial > ../existing.txt\nexit 2\n")
    assert {:error, {:turn_effect_failed, %{step: :format}}} = TurnEffects.maybe_auto_commit(%Claude.StreamState{files_touched: ["existing.txt"]}, context.workspace)
    assert File.read!(Path.join(context.workspace, "existing.txt")) == "partial"
    assert command_steps(context.root) == ["mix format"]
    assert git!(context.workspace, ["diff", "--cached", "--name-only"]) == ""
  end

  test "P3-B2-05: partial stage writes remain and no later command runs", context do
    File.write!(Path.join(context.workspace, "existing.txt"), "partial stage\n")
    write_executable!(Path.join([context.root, "bin", "git"]), "printf 'git %s\\n' \"$*\" >> \"$SYMPHONY_P3A_ROOT/commands\"\n\"$SYMPHONY_P3A_GIT\" add existing.txt\nexit 2\n")
    assert {:error, {:turn_effect_failed, %{step: :stage}}} = TurnEffects.maybe_auto_commit(%Claude.StreamState{files_touched: ["existing.txt"]}, context.workspace)
    assert git!(context.workspace, ["show", ":existing.txt"]) == "partial stage\n"
    assert command_steps(context.root) == ["git add -A"]
  end

  test "P3-B2-06: index exit zero skips commit but reports once", context do
    caller = self()

    opts = [
      tool_executor: fn _, report ->
        send(caller, {:empty_index_report, report})
        %{"success" => true}
      end
    ]

    assert {:ok, _} = TurnEffects.apply_result(Claude, observation(:claude_cli, ["existing.txt"]), context.workspace, %{}, opts, :delivery)
    assert command_steps(context.root) == detection_steps(:claude_cli) ++ ["git add -A", "git diff --cached --quiet"]
    assert_receive {:empty_index_report, %{"files_touched" => ["existing.txt"]}}
    refute_receive {:empty_index_report, _}
  end

  test "P3-B2-07: failing commit hook leaves its write and staged changes", context do
    File.write!(Path.join(context.workspace, "existing.txt"), "staged\n")
    write_executable!(Path.join(context.workspace, ".git/hooks/pre-commit"), "printf hook-write > hook-output.txt\nexit 1\n")
    before_head = git!(context.workspace, ["rev-parse", "HEAD"])

    log =
      capture_log(fn ->
        assert {:error, {:turn_effect_failed, %{step: :commit, reason: {:exit_status, 1}}}} = TurnEffects.maybe_auto_commit(%Claude.StreamState{files_touched: ["existing.txt"]}, context.workspace)
      end)

    refute log =~ "Auto-committed"
    assert File.read!(Path.join(context.workspace, "hook-output.txt")) == "hook-write"
    assert git!(context.workspace, ["show", ":existing.txt"]) == "staged\n"
    assert git!(context.workspace, ["rev-parse", "HEAD"]) == before_head
  end

  test "P3-B2-08: only string-keyed boolean success accepts the report" do
    state = %Claude.StreamState{result_text: "Report"}

    for response <- [nil, :ok, {:ok, %{"success" => true}}, %{}, %{success: true}, %{"success" => "true"}, %{"success" => 1}] do
      caller = self()

      assert {:error, {:turn_effect_failed, %{step: :report_turn_result, reason: :invalid_tool_response, response: ^response}}} =
               TurnEffects.synthesize_turn_result(state, fn _, _ ->
                 send(caller, :executor_called)
                 response
               end)

      assert_receive :executor_called
      refute_receive :executor_called
    end

    assert {:error, {:turn_effect_failed, %{reason: :tool_rejected, response: %{"success" => false}}}} = TurnEffects.synthesize_turn_result(state, fn _, _ -> %{"success" => false} end)
    assert {:ok, %{"blocked" => true}} = TurnEffects.synthesize_turn_result(%{state | error: "failed"}, fn _, _ -> %{"success" => true, "contentItems" => "ignored diagnostic"} end)
  end

  test "P3-B2-08: absent or wrong-arity executor fails before Git", context do
    for executor <- [nil, fn _ -> :ok end, :invalid], status <- [:turn_completed, :turn_failed] do
      {:ok, result} = observation(:claude_cli, ["existing.txt"])

      assert {:error, {:turn_effect_failed, %{step: :report_turn_result, reason: :missing_tool_executor}}} =
               TurnEffects.apply_result(Claude, {:ok, %{result | result: status}}, context.workspace, %{}, [tool_executor: executor], :delivery)
    end

    assert command_steps(context.root) == []
  end

  test "P3-B2-09: command invocation exception keeps its step and reason", context do
    empty_bin = Path.join(context.root, "empty-bin")
    File.mkdir_p!(empty_bin)
    System.put_env("PATH", empty_bin)
    workspace = context.workspace
    caller = self()
    opts = [tool_executor: fn _, _ -> flunk("report after command exception") end, on_message: fn event -> send(caller, {:command_exception_event, event.event}) end]

    assert {:error, {:turn_effect_failed, %{step: :detect_changes, executable: "git", cwd: ^workspace, reason: {:command_exception, :error, :enoent}}}} =
             TurnEffects.apply_result(Claude, observation(:claude_cli, []), workspace, %{}, opts, :delivery)

    assert_receive {:command_exception_event, :turn_ended_with_error}
    refute_receive {:command_exception_event, _}
  end

  test "P3-B2-13: failed transport still requires an accepted blocked report", context do
    for {profile, provider, _} <- @profiles do
      {:ok, result} = observation(profile, ["stream.txt"])
      result = %{result | result: :turn_failed, cli_observation: %{result.cli_observation | error: "exit_status_9"}}
      caller = self()

      opts = [
        tool_executor: fn _, report ->
          send(caller, {:blocked_report, report})
          %{"success" => false}
        end
      ]

      assert {:error, {:turn_effect_failed, %{step: :report_turn_result, reason: :tool_rejected}}} = TurnEffects.apply_result(provider, {:ok, result}, context.workspace, %{}, opts, :delivery)
      assert_receive {:blocked_report, %{"blocked" => true, "files_touched" => ["stream.txt"]}}
      refute_receive {:blocked_report, _}
    end

    assert command_steps(context.root) == []
  end

  test "P3-B2-09: error callback throw is not recaught after executor throw", context do
    caller = self()

    opts = [
      tool_executor: fn _, _ -> throw(:executor_failed) end,
      on_message: fn event ->
        send(caller, {:error_callback, event.event})
        throw(:callback_failed)
      end
    ]

    assert catch_throw(TurnEffects.apply_result(Claude, observation(:claude_cli, []), context.workspace, %{}, opts, :delivery)) == :callback_failed
    assert_receive {:error_callback, :turn_ended_with_error}
    refute_receive {:error_callback, _}
  end

  test "P3-B2-12: commit survives executor rejection and no normal final occurs", context do
    File.write!(Path.join(context.workspace, "existing.txt"), "retained commit\n")
    caller = self()

    opts = [
      tool_executor: fn _, _ ->
        send(caller, :rejected_report)
        %{"success" => false}
      end,
      on_message: fn event -> send(caller, {:rejected_event, event.event}) end
    ]

    assert {:error, {:turn_effect_failed, %{step: :report_turn_result, reason: :tool_rejected}}} =
             TurnEffects.apply_result(Claude, observation(:claude_cli, []), context.workspace, %{}, opts, :delivery)

    assert git!(context.workspace, ["show", "HEAD:existing.txt"]) == "retained commit\n"
    assert_receive :rejected_report
    refute_receive :rejected_report
    assert_receive {:rejected_event, :turn_ended_with_error}
    refute_receive {:rejected_event, _}
  end

  defp observation(profile, files), do: {:ok, %{result: :turn_completed, usage: %{}, cli_observation: %{profile: profile, files_touched: files, result_text: nil, error: nil}}}

  defp run_delivery(provider, session, prompt, issue, opts \\ []) do
    opts = Keyword.put_new(opts, :tool_executor, fn _, _ -> %{"success" => true} end)
    result = provider.run_turn(session, prompt, issue, opts)
    TurnEffects.apply_result(provider, result, session.workspace, issue, opts, :delivery)
  end

  defp workspace_bytes(workspace) do
    %{head: git!(workspace, ["rev-parse", "HEAD"]), index: File.read!(Path.join(workspace, ".git/index")), progress: File.read!(Path.join(workspace, ".symphony/progress/turn.md"))}
  end

  defp prepare_changed_workspace!(context) do
    write_progress!(context.workspace)
    File.mkdir_p!(Path.join(context.workspace, "elixir"))
    File.write!(Path.join(context.workspace, "existing.txt"), "changed\n")
  end

  defp write_progress!(workspace) do
    File.mkdir_p!(Path.join(workspace, ".symphony/progress"))
    File.write!(Path.join(workspace, ".symphony/progress/turn.md"), "## Work Log\n\n## Evidence\n\n")
  end

  defp write_stream!(root, profile) do
    events =
      case profile do
        :claude_cli ->
          [
            %{"type" => "assistant", "message" => %{"content" => [%{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "existing.txt"}}]}},
            %{"type" => "result", "result" => "Implemented change", "usage" => %{"input_tokens" => 7, "output_tokens" => 3}}
          ]

        :codex_cli ->
          [
            %{"type" => "item.completed", "item" => %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "existing.txt"}}},
            %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => "Implemented change"}},
            %{"type" => "turn.completed", "usage" => %{"input_tokens" => 7, "output_tokens" => 3}}
          ]
      end

    File.write!(Path.join(root, "stream"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  defp expected_progress, do: "## Work Log\n\n## Evidence\n\n"

  defp expected_report(blocked),
    do: %{
      "summary" => "Implemented change",
      "files_touched" => ["existing.txt", ".symphony/progress/turn.md"],
      "needs_another_turn" => false,
      "blocked" => blocked,
      "blocker_type" => if(blocked, do: "implementation", else: "none")
    }

  defp detection_steps(:claude_cli), do: ["git diff --name-only HEAD", "git ls-files --others --exclude-standard"]
  defp detection_steps(:codex_cli), do: ["git status --porcelain", "git diff origin/main --name-only"]

  defp append_step(root, step), do: File.write!(Path.join(root, "commands"), step <> "\n", [:append])
  defp command_steps(root), do: root |> Path.join("commands") |> File.read!() |> String.split("\n", trim: true)

  defp git!(workspace, args) do
    {output, status} = System.cmd(System.fetch_env!("SYMPHONY_P3A_GIT"), args, cd: workspace, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")}: #{output}"
    output
  end

  defp write_executable!(path, body) do
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end
end
