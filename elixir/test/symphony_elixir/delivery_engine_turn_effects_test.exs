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

    test "P3-A01 #{@profile}: adapter preserves effect order, commit, callback process and result", context do
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
      assert {:ok, result} = @provider.run_turn(session, "task", %{identifier: "P3-A01"}, tool_executor: executor, on_message: on_message)
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

    test "P3-A03 #{@profile}: clean progress is still patched without triggering a commit", context do
      write_progress!(context.workspace)
      git!(context.workspace, ["add", "-A"])
      git!(context.workspace, ["commit", "-qm", "progress"])
      git!(context.workspace, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      before_head = git!(context.workspace, ["rev-parse", "HEAD"])
      File.write!(Path.join(context.root, "stream"), "")
      assert {:ok, session} = @provider.start_session(context.workspace)
      assert {:ok, %{result: :turn_completed}} = @provider.run_turn(session, "task", %{identifier: "P3-A03"})
      assert git!(context.workspace, ["rev-parse", "HEAD"]) == before_head
      assert File.read!(Path.join(context.workspace, ".symphony/progress/turn.md")) == "## Work Log\n\n- Turn completed.\n\n## Evidence\n\n- Changes applied.\n\n"
      assert command_steps(context.root) == ["transport"] ++ detection_steps(@profile)
    end

    test "P3-A04 #{@profile}: failed transport still prepares and commits before reporting blocked", context do
      prepare_changed_workspace!(context)
      write_stream!(context.root, @profile)
      System.put_env("SYMPHONY_P3A_EXIT", "9")
      before_head = git!(context.workspace, ["rev-parse", "HEAD"])
      assert {:ok, session} = @provider.start_session(context.workspace)

      assert {:ok, %{result: :turn_failed}} =
               @provider.run_turn(session, "task", %{identifier: "P3-A04"},
                 tool_executor: fn _, result ->
                   Process.put(:p3a_failed_report, result)
                   %{"success" => true}
                 end
               )

      assert Process.get(:p3a_failed_report) == expected_report(true)
      refute git!(context.workspace, ["rev-parse", "HEAD"]) == before_head
      assert File.read!(Path.join(context.workspace, ".symphony/progress/turn.md")) == expected_progress()
    end

    test "P3-A05 #{@profile}: executor throw remains inside the adapter catch after commit", context do
      prepare_changed_workspace!(context)
      write_stream!(context.root, @profile)
      caller = self()
      assert {:ok, session} = @provider.start_session(context.workspace)

      assert {:error, {:throw, :executor_failed}} =
               @provider.run_turn(session, "task", %{identifier: "P3-A05"}, tool_executor: fn _, _ -> throw(:executor_failed) end, on_message: fn event -> send(caller, {:p3a_event, event.event}) end)

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
                 @provider.run_turn(session, "task", %{identifier: "P3-A07"},
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

  defp expected_progress, do: "## Work Log\n\n- Implemented change\n\n## Evidence\n\n- `existing.txt`\n- `.symphony/progress/turn.md`\n\n"

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
