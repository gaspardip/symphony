defmodule SymphonyElixir.DeliveryEngine.TurnEffectsIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DeliveryEngine, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-b1-engine-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(workspace, ".symphony/progress"))
    git = System.find_executable("git")

    for args <- [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] do
      {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, ".gitignore"), ".symphony/run_state.json\n")
    File.write!(Path.join(workspace, "existing.txt"), "initial\n")
    File.write!(Path.join(workspace, ".symphony/progress/B1.md"), "## Work Log\n\n## Evidence\n\n")
    {_, 0} = System.cmd(git, ["add", "-A"], cd: workspace)
    {_, 0} = System.cmd(git, ["commit", "-qm", "initial"], cd: workspace)
    {_, 0} = System.cmd(git, ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)
    {head, 0} = System.cmd(git, ["rev-parse", "HEAD"], cd: workspace)
    commands = Path.join(root, "commands")
    File.write!(commands, "")
    write_script!(Path.join(bin, "git"), "printf 'git %s\\n' \"$*\" >> '#{commands}'\nexec '#{git}' \"$@\"\n")
    write_script!(Path.join(bin, "gh"), "exit 1\n")
    write_script!(Path.join(bin, "mix"), "printf 'mix %s\\n' \"$*\" >> '#{commands}'\nexit 0\n")
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    on_exit(fn -> File.rm_rf!(root) end)
    issue = %Issue{id: "b1-engine", identifier: "B1", title: "Local delivery", description: "## Acceptance Criteria\n- preserve evidence", state: "In Progress"}
    %{root: root, workspace: workspace, bin: bin, git: git, issue: issue, initial_head: String.trim(head), commands: commands}
  end

  for provider <- ["claude", "codex-cli"], stage <- ["plan", "implement"] do
    @provider provider
    @stage stage
    test "P3-B1-02 #{@provider} #{@stage}: public engine applies each transport result once", context do
      configure!(context, @provider, @stage)
      install_cli!(context, @provider, false)
      progress = Path.join(context.workspace, ".symphony/progress/B1.md")
      progress_before = File.read!(progress)

      log =
        capture_log(fn ->
          assert {:done, %Issue{state: "Done"}} =
                   DeliveryEngine.run(context.workspace, context.issue, self(), issue_state_fetcher: fn _ -> {:ok, [%{context.issue | state: "Done"}]} end, include_pr_details: false)
        end)

      expected_turns = if @stage == "plan", do: 2, else: 1
      commands = File.read!(context.commands) |> String.split("\n", trim: true)
      assert Enum.count(commands, &(&1 == "transport")) == expected_turns
      assert Enum.count(commands, &(&1 == "git add -A")) == expected_turns
      assert Enum.count(commands, &(&1 == "git commit -m engine change")) == expected_turns
      refute Enum.any?(commands, &(&1 == "mix format"))
      assert File.read!(progress) == progress_before
      assert File.read!(Path.join(context.workspace, "existing.txt")) == "initial\n" <> String.duplicate("transport change\n", expected_turns)
      {history, 0} = System.cmd(context.git, ["log", "--format=%s", "#{context.initial_head}..HEAD"], cd: context.workspace)
      assert String.split(history, "\n", trim: true) == List.duplicate("engine change", expected_turns)
      {first_parent, 0} = System.cmd(context.git, ["rev-parse", "HEAD~#{expected_turns}"], cd: context.workspace)
      assert String.trim(first_parent) == context.initial_head
      {committed, 0} = System.cmd(context.git, ["show", "HEAD:existing.txt"], cd: context.workspace)
      assert committed == File.read!(Path.join(context.workspace, "existing.txt"))
      {:ok, state} = RunStateStore.load(context.workspace)
      assert state.stage == "validate"
      assert state.implementation_turns == 1
      assert state.last_turn_result.summary == "engine change"
      assert log =~ "stage=implement"
      if @stage == "plan", do: assert(log =~ "stage=plan")

      for _ <- 1..expected_turns do
        assert_receive {:agent_worker_update, "b1-engine", %{event: :turn_completed}}
      end

      refute_receive {:agent_worker_update, "b1-engine", %{event: :turn_completed}}
    end
  end

  for provider <- ["claude", "codex-cli"] do
    @provider provider
    test "P3-B1-14 #{@provider}: plan retains historical advance after a failed transport", context do
      configure!(context, @provider, "plan")
      install_cli!(context, @provider, true)
      assert {:stop, :implementation} = DeliveryEngine.run(context.workspace, context.issue, self(), include_pr_details: false)
      {:ok, state} = RunStateStore.load(context.workspace)
      assert state.plan_completed == true
      assert Enum.any?(state.stage_history, &(&1.stage == "implement"))
      assert state.stage == "blocked"
      commands = File.read!(context.commands) |> String.split("\n", trim: true)
      assert Enum.count(commands, &(&1 == "transport")) == 2
      refute "git add -A" in commands
      refute "git commit -m engine change" in commands
      {head, 0} = System.cmd(context.git, ["rev-parse", "HEAD"], cd: context.workspace)
      assert String.trim(head) == context.initial_head
    end
  end

  for provider <- ["claude", "codex-cli"], stage <- ["plan", "implement"] do
    @provider provider
    @stage stage
    test "P3-B2-10/11/14 #{@provider} #{@stage}: public engine stops on detection failure", context do
      configure!(context, @provider, @stage)
      install_cli!(context, @provider, false)
      failed_argv = if @provider == "claude", do: "diff --name-only HEAD", else: "status --porcelain"

      write_script!(Path.join(context.bin, "git"), """
      printf 'git %s\\n' "$*" >> '#{context.commands}'
      if [ -f '#{context.root}/transported' ] && [ "$*" = '#{failed_argv}' ]; then
        printf 'controlled detection failure'
        exit 2
      fi
      exec '#{context.git}' "$@"
      """)

      mark_transport!(context, @provider)
      usage = %{input_tokens: 21, output_tokens: 13, total_tokens: 34}
      {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
      {:ok, before_state} = RunStateStore.load(context.workspace)
      Process.put({:symphony_turn_result, context.issue.id}, %SymphonyElixir.TurnResult{summary: "old report"})

      log =
        capture_log(fn ->
          assert {:error, {:turn_effect_failed, %{step: :detect_changes, reason: {:exit_status, 2}, output: "controlled detection failure"}}} =
                   DeliveryEngine.run(context.workspace, context.issue, self(), include_pr_details: false, issue_state_fetcher: fn _ -> flunk("refresh after failed effects") end)
        end)

      after_transport = commands_after_transport(context)
      {:ok, state} = RunStateStore.load(context.workspace)
      assert state.stage == @stage
      assert state.stage_history == before_state.stage_history
      assert state.implementation_turns == before_state.implementation_turns
      assert Map.get(state, :plan_completed) == Map.get(before_state, :plan_completed)
      assert state.token_usage == usage
      assert after_transport == ["git " <> failed_argv]
      assert File.read!(Path.join(context.workspace, "existing.txt")) == "initial\ntransport change\n"
      refute log =~ "plan_completed=true"
      assert log =~ "turn_effect_failed"
      assert_single_error_event(context.issue.id)
    end

    test "P3-B2-10/11/12 #{@provider} #{@stage}: rejected real report preserves commit and stage", context do
      configure!(context, @provider, @stage)
      install_cli!(context, @provider, false)
      binary = Path.join(context.bin, if(@provider == "claude", do: "claude", else: "codex"))
      File.write!(binary, String.replace(File.read!(binary), "engine change", ""))
      # Git accepts the hook-supplied message; the report still has its original
      # empty summary, so the real engine executor rejects it after the commit.
      write_script!(Path.join(context.workspace, ".git/hooks/prepare-commit-msg"), "printf 'hook message\\n' > \"$1\"\n")
      {:ok, before_state} = RunStateStore.load(context.workspace)

      assert {:error, {:turn_effect_failed, %{step: :report_turn_result, reason: :tool_rejected, response: %{"success" => false} = response}}} =
               DeliveryEngine.run(context.workspace, context.issue, self(), include_pr_details: false, issue_state_fetcher: fn _ -> flunk("refresh after report rejection") end)

      assert inspect(response) =~ "empty_summary"
      after_transport = commands_after_transport(context)
      {:ok, state} = RunStateStore.load(context.workspace)
      assert state.stage == @stage
      assert state.stage_history == before_state.stage_history
      assert state.implementation_turns == before_state.implementation_turns
      assert Map.get(state, :plan_completed) == Map.get(before_state, :plan_completed)
      {committed, 0} = System.cmd(context.git, ["show", "HEAD:existing.txt"], cd: context.workspace)
      assert committed == "initial\ntransport change\n"
      {subject, 0} = System.cmd(context.git, ["log", "-1", "--format=%s"], cd: context.workspace)
      assert String.trim(subject) == "hook message"
      detection = if @provider == "claude", do: ["git diff --name-only HEAD", "git ls-files --others --exclude-standard"], else: ["git status --porcelain", "git diff origin/main --name-only"]
      assert after_transport == detection ++ ["git add -A", "git diff --cached --quiet", "git commit -m "]
      assert_single_error_event(context.issue.id)
    end
  end

  defp mark_transport!(context, provider) do
    binary = Path.join(context.bin, if(provider == "claude", do: "claude", else: "codex"))
    File.write!(binary, String.replace(File.read!(binary), "#!/bin/sh\n", "#!/bin/sh\ntouch '#{context.root}/transported'\n"))
  end

  defp commands_after_transport(context) do
    commands = File.read!(context.commands) |> String.split("\n", trim: true)
    assert Enum.count(commands, &(&1 == "transport")) == 1
    [_transport | after_transport] = Enum.drop_while(commands, &(&1 != "transport"))
    after_transport
  end

  defp assert_single_error_event(issue_id) do
    assert_receive {:agent_worker_update, ^issue_id, %{event: :turn_ended_with_error}}
    refute_receive {:agent_worker_update, ^issue_id, %{event: :turn_completed}}
    refute_receive {:agent_worker_update, ^issue_id, %{event: :turn_ended_with_error}}
  end

  defp configure!(context, provider, stage) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.dirname(context.workspace))
    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "agent:\n", "agent:\n  provider: #{provider}\n"))
    WorkflowStore.force_reload()
    {:ok, _} = RunStateStore.transition(context.workspace, stage, %{issue_id: context.issue.id, issue_identifier: context.issue.identifier})
    File.write!(context.commands, "")
  end

  defp install_cli!(context, provider, fail?) do
    binary = if provider == "claude", do: "claude", else: "codex"

    events =
      if provider == "claude" do
        [~s({"type":"result","result":"engine change","usage":{"input_tokens":7,"output_tokens":3}})]
      else
        [~s({"type":"item.completed","item":{"type":"agent_message","text":"engine change"}}), ~s({"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}})]
      end

    script =
      "printf 'transport\\n' >> '#{context.commands}'\n" <>
        if(fail?, do: "", else: "printf 'transport change\\n' >> existing.txt\n") <>
        Enum.map_join(events, "\n", &"printf '%s\\n' '#{&1}'") <>
        "\nexit #{if fail?, do: 9, else: 0}\n"

    write_script!(Path.join(context.bin, binary), script)
  end

  defp write_script!(path, body) do
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end
end
