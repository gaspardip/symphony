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
        %{"success" => false}
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
      updated = TurnEffects.detect_changed_files(state, context.workspace, @profile)
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

      assert {:error, {:throw, :executor_failed}} =
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

      assert TurnEffects.synthesize_turn_result(state, nil) == %{
               "summary" => "Turn completed.",
               "files_touched" => ["a", "b"],
               "needs_another_turn" => false,
               "blocked" => true,
               "blocker_type" => "none"
             }
    end

    for failing_step <- [:format, :add, :commit] do
      @failing_step failing_step
      test "P3-A07 #{@profile}: #{@failing_step} failure retains existing ignored-error behavior", context do
        prepare_changed_workspace!(context)
        write_stream!(context.root, @profile)

        case @failing_step do
          :format -> System.put_env("SYMPHONY_P3A_MIX_STATUS", "2")
          :add -> System.put_env("SYMPHONY_P3A_FAIL_GIT", "add -A")
          :commit -> System.put_env("SYMPHONY_P3A_FAIL_GIT", "commit -m Implemented change")
        end

        before_head = git!(context.workspace, ["rev-parse", "HEAD"])
        assert {:ok, session} = @provider.start_session(context.workspace)

        assert {:ok, %{result: :turn_completed}} =
                 run_delivery(@provider, session, "task", %{identifier: "P3-A07"},
                   tool_executor: fn _, result ->
                     Process.put(:p3a_ignored_error, result)
                     %{"success" => true}
                   end
                 )

        assert Process.get(:p3a_ignored_error) == expected_report(false)
        after_head = git!(context.workspace, ["rev-parse", "HEAD"])
        if @failing_step == :format, do: refute(after_head == before_head), else: assert(after_head == before_head)
        steps = command_steps(context.root)
        assert "mix format" in steps
        assert "git add -A" in steps

        if @failing_step == :add do
          refute "git diff --cached --quiet" in steps
          assert git!(context.workspace, ["diff", "--cached", "--name-only"]) == ""
        else
          assert "git commit -m Implemented change" in steps
        end

        if @failing_step == :commit, do: assert(git!(context.workspace, ["diff", "--cached", "--name-only"]) != "")
      end
    end

    test "P3-A08 #{@profile}: unexpected index diff status still raises CaseClauseError", context do
      System.put_env("SYMPHONY_P3A_FAIL_GIT", "diff --cached --quiet")
      state = struct!(@state_module, files_touched: ["existing.txt"])
      assert_raise CaseClauseError, fn -> TurnEffects.maybe_auto_commit(state, context.workspace) end
    end
  end

  test "P3-A09: Claude ls-files failure remains a MatchError", context do
    System.put_env("SYMPHONY_P3A_FAIL_GIT", "ls-files --others --exclude-standard")
    assert_raise MatchError, fn -> TurnEffects.detect_changed_files(%Claude.StreamState{}, context.workspace, :claude_cli) end
  end

  test "P3-A10: existing Git observation failures keep stream data", context do
    System.put_env("SYMPHONY_P3A_FAIL_GIT", "diff --name-only HEAD")
    claude = %Claude.StreamState{files_touched: ["stream.txt"]}
    assert TurnEffects.detect_changed_files(claude, context.workspace, :claude_cli) == claude
    System.put_env("SYMPHONY_P3A_FAIL_GIT", "status --porcelain")
    codex = %CodexCLI.StreamState{files_touched: ["stream.txt"]}
    assert TurnEffects.detect_changed_files(codex, context.workspace, :codex_cli) == codex
    System.put_env("SYMPHONY_P3A_FAIL_GIT", "diff origin/main --name-only")
    assert TurnEffects.detect_changed_files(codex, context.workspace, :codex_cli) == codex
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
        opts = [tool_executor: fn _, report -> Process.put(:timeout_report, report) end]
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

    assert {:error, {:error, %RuntimeError{message: "executor raised"}}} =
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

  test "P3-B1-13: helper exception is caught at the moved effect boundary", context do
    System.put_env("SYMPHONY_P3A_FAIL_GIT", "ls-files --others --exclude-standard")
    result = {:ok, %{result: :turn_completed, usage: %{}, cli_observation: %{profile: :claude_cli, files_touched: [], result_text: nil, error: nil}}}
    caller = self()
    opts = [on_message: fn event -> send(caller, {:helper_event, event}) end]
    assert {:error, {:error, {:badmatch, {"", 2}}}} = TurnEffects.apply_result(Claude, result, context.workspace, %{}, opts, :delivery)
    assert_receive {:helper_event, %{event: :turn_ended_with_error, payload: %{error: "{:error, {:badmatch, {\"\", 2}}}"}}}
    refute_receive {:helper_event, _}
    assert command_steps(context.root) == detection_steps(:claude_cli)
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

  defp run_delivery(provider, session, prompt, issue, opts \\ []) do
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
