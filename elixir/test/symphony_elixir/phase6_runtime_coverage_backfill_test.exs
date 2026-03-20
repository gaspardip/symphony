defmodule SymphonyElixir.Phase6RuntimeCoverageBackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{GitManager, RunLedger, RunStateStore, RunnerRuntime}

  test "git manager covers branch preparation paths and missing checkouts" do
    workspace = tmp_dir!("git-manager-prepare")
    on_exit(fn -> File.rm_rf(workspace) end)
    File.mkdir_p!(Path.join(workspace, ".git"))

    existing_branch_runner = fn
      "git", ["fetch", "origin", "develop"], _opts -> {"", 0}
      "git", ["checkout", "feature/phase-6"], _opts -> {"", 0}
      "git", ["reset", "--hard", "origin/develop"], _opts -> {"", 0}
      "git", ["config", "branch.feature/phase-6.symphony-base-branch", "develop"], _opts -> {"", 0}
      command, args, _opts -> raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert {:ok, %{branch: "feature/phase-6", base_branch: "develop"}} =
             GitManager.prepare_issue_branch(
               workspace,
               %{branchName: "Feature/Phase 6"},
               %{base_branch: "develop"},
               command_runner: existing_branch_runner
             )

    new_branch_runner = fn
      "git", ["fetch", "origin", "main"], _opts -> {"", 0}
      "git", ["checkout", "symphony/mt-611"], _opts -> {"missing", 1}
      "git", ["checkout", "-B", "symphony/mt-611", "origin/main"], _opts -> {"", 0}
      "git", ["config", "branch.symphony/mt-611.symphony-base-branch", "main"], _opts -> {"", 0}
      command, args, _opts -> raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert {:ok, %{branch: "symphony/mt-611", base_branch: "main"}} =
             GitManager.prepare_issue_branch(
               workspace,
               %{"identifier" => "MT 611"},
               nil,
               command_runner: new_branch_runner
             )

    assert {:error, :missing_checkout} =
             GitManager.prepare_issue_branch(
               Path.join(workspace, "missing"),
               %{"identifier" => "MT-612"},
               nil,
               command_runner: new_branch_runner
             )

    assert {:error, :missing_checkout} =
             GitManager.prepare_issue_branch(
               Path.join(workspace, "missing-default"),
               %{
                 identifier: "MT-612"
               },
               nil
             )

    assert GitManager.issue_branch_name(%Issue{identifier: "MT-617"}) == "symphony/mt-617"
  end

  test "git manager covers commit, noop, error, push, and reset flows" do
    workspace = tmp_dir!("git-manager-ops")
    on_exit(fn -> File.rm_rf(workspace) end)
    File.mkdir_p!(Path.join(workspace, ".git"))

    test_pid = self()

    success_runner = fn
      "git", ["status", "--porcelain"], _opts ->
        {" M README.md\n", 0}

      "git", ["add", "-A"], _opts ->
        {"", 0}

      "git", ["commit", "-m", message], _opts ->
        send(test_pid, {:commit_message, message})
        {"", 0}

      "git", ["rev-parse", "HEAD"], _opts ->
        {"abc123\n", 0}

      command, args, _opts ->
        raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert {:ok, %{sha: "abc123", message: message}} =
             GitManager.commit_all(
               workspace,
               %{"identifier" => "MT-613"},
               "  ship\nthis summary that is intentionally much longer than seventy two characters  ",
               command_runner: success_runner
             )

    assert_received {:commit_message, ^message}
    assert String.starts_with?(message, "MT-613: ")
    assert message |> String.replace_prefix("MT-613: ", "") |> String.length() <= 72
    refute String.contains?(message, "\n")

    noop_runner = fn
      "git", ["status", "--porcelain"], _opts -> {"", 0}
      command, args, _opts -> raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert {:ok, :noop} =
             GitManager.commit_all(
               workspace,
               %{"identifier" => "MT-614"},
               "noop",
               command_runner: noop_runner
             )

    assert {:error, :missing_checkout} =
             GitManager.commit_all(Path.join(workspace, "missing-default"), %{identifier: "MT-614"}, "noop")

    status_error_runner = fn
      "git", ["status", "--porcelain"], _opts -> {"boom", 1}
      command, args, _opts -> raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert {:ok, :noop} =
             GitManager.commit_all(
               workspace,
               %{identifier: "MT-614"},
               "noop",
               command_runner: status_error_runner
             )

    error_runner = fn
      "git", ["status", "--porcelain"], _opts -> {" M README.md\n", 0}
      "git", ["add", "-A"], _opts -> {"", 0}
      "git", ["commit", "-m", "MT-615: broken"], _opts -> {"nope", 1}
      command, args, _opts -> raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert {:error, {:git_failed, "commit -m MT-615: broken", 1, "nope"}} =
             GitManager.commit_all(
               workspace,
               %{identifier: "MT-615"},
               "broken",
               command_runner: error_runner
             )

    rev_parse_error_runner = fn
      "git", ["status", "--porcelain"], _opts -> {" M README.md\n", 0}
      "git", ["add", "-A"], _opts -> {"", 0}
      "git", ["commit", "-m", "MT-615: rev-parse"], _opts -> {"", 0}
      "git", ["rev-parse", "HEAD"], _opts -> {"unknown", 1}
      command, args, _opts -> raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert {:error, {:git_failed, "rev-parse HEAD", 1, "unknown"}} =
             GitManager.commit_all(
               workspace,
               %{identifier: "MT-615"},
               "rev-parse",
               command_runner: rev_parse_error_runner
             )

    push_runner = fn
      "git", ["push", "-u", "origin", "symphony/mt-616"], _opts -> {"", 0}
      command, args, _opts -> raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert :ok = GitManager.push_branch(workspace, "symphony/mt-616", command_runner: push_runner)

    assert {:error, {:git_failed, "push -u origin symphony/mt-616", 128, _output}} =
             GitManager.push_branch(workspace, "symphony/mt-616")

    reset_runner = fn
      "git", ["fetch", "origin", "main"], _opts -> {"", 0}
      "git", ["checkout", "-f", "main"], _opts -> {"", 0}
      "git", ["reset", "--hard", "origin/main"], _opts -> {"", 0}
      command, args, _opts -> raise "unexpected git call: #{command} #{inspect(args)}"
    end

    assert :ok = GitManager.reset_to_base(workspace, nil, command_runner: reset_runner)
    assert {:error, :missing_checkout} = GitManager.reset_to_base(Path.join(workspace, "missing-reset"), nil)
  end

  test "run state store covers transition defaults and write error branches" do
    workspace = tmp_dir!("run-state-store")
    broken_workspace = tmp_dir!("run-state-store-broken")
    on_exit(fn -> File.rm_rf(workspace) end)
    on_exit(fn -> File.rm_rf(broken_workspace) end)

    with_log_file_env(Path.join(workspace, "symphony.log"), fn ->
      assert {:ok, state} = RunStateStore.transition(workspace, "verify")
      assert state.stage == "verify"
      assert [%{stage: "verify", reason: nil}] = state.stage_history
      assert state.stage_transition_counts == %{"verify" => 1}
      assert is_binary(state.last_ledger_event_id)

      assert {:ok, updated_state} =
               RunStateStore.update(workspace, &Map.put(&1, :validation_attempts, 2))

      assert updated_state.validation_attempts == 2

      assert {:ok, same_stage_state} =
               RunStateStore.transition(workspace, "verify", %{last_decision_summary: "polled"})

      assert same_stage_state.last_decision_summary == "polled"
      assert same_stage_state.stage_transition_counts == %{verify: 1}
      assert length(same_stage_state.stage_history) == 1
      assert same_stage_state.last_ledger_event_id == state.last_ledger_event_id

      assert :ok = RunStateStore.delete(workspace)
    end)

    File.mkdir_p!(Path.join(broken_workspace, ".symphony/run_state.json"))

    with_log_file_env(Path.join(broken_workspace, "symphony.log"), fn ->
      assert {:error, reason} = RunStateStore.transition(broken_workspace, "verify")
      assert is_atom(reason)

      assert {:error, update_reason} =
               RunStateStore.update(broken_workspace, &Map.put(&1, :stage, "done"))

      assert is_atom(update_reason)
    end)
  end

  test "run ledger covers persistence fallbacks and malformed recent entries" do
    with_log_file_env(self(), fn ->
      assert :ok = RunLedger.append("legacy.event", %{issue_identifier: "MT-LEDGER"})

      nil_actor_entry =
        RunLedger.record("operator.action", %{
          issue_identifier: "MT-LEDGER",
          actor_type: nil,
          policy_class: "   ",
          summary: "   ",
          metadata: %{source: "test"},
          extra_note: "kept"
        })

      assert is_binary(nil_actor_entry.event_id)
      assert nil_actor_entry.metadata == %{source: "test", extra_note: "kept"}
      refute Map.has_key?(nil_actor_entry, :actor_type)
      refute Map.has_key?(nil_actor_entry, :policy_class)
      refute Map.has_key?(nil_actor_entry, :summary)

      blank_actor_entry =
        RunLedger.record("operator.action", %{
          actor_type: "   ",
          details: "   ",
          extra_note: "blank actor"
        })

      refute Map.has_key?(blank_actor_entry, :actor_type)
      refute Map.has_key?(blank_actor_entry, :details)
      assert RunLedger.recent_entries(5) == []
    end)

    log_root = tmp_dir!("run-ledger")
    on_exit(fn -> File.rm_rf(log_root) end)

    with_log_file_env(Path.join(log_root, "symphony.log"), fn ->
      path = RunLedger.ledger_file_path()
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        "not json\n" <>
          Jason.encode!(%{"event" => "valid", "event_type" => "valid", "summary" => "kept"}) <>
          "\n"
      )

      assert [%{"event" => "valid", "summary" => "kept"}] = RunLedger.recent_entries()
      assert RunLedger.recent_entries(0) == []
    end)
  end

  test "runner runtime covers malformed files and fallback helpers" do
    runner_root = tmp_dir!("runner-runtime")
    broken_history_root = tmp_dir!("runner-runtime-history-dir")
    fake_git_root = tmp_dir!("runner-runtime-fake-git")
    missing_history_root = tmp_dir!("runner-runtime-missing-history")
    missing_metadata_root = Path.join(runner_root, "missing")
    on_exit(fn -> File.rm_rf(runner_root) end)
    on_exit(fn -> File.rm_rf(broken_history_root) end)
    on_exit(fn -> File.rm_rf(fake_git_root) end)
    on_exit(fn -> File.rm_rf(missing_history_root) end)

    File.write!(RunnerRuntime.metadata_path(runner_root), "{bad")

    File.write!(
      RunnerRuntime.history_path(runner_root),
      "not json\n" <>
        Jason.encode!(%{"event_type" => "runner.promoted", "summary" => "Promoted"}) <> "\n"
    )

    assert RunnerRuntime.load_metadata(runner_root) == %{}
    assert RunnerRuntime.load_metadata(missing_metadata_root) == %{}

    assert [%{"event_type" => "runner.promoted", "summary" => "Promoted"}] =
             RunnerRuntime.recent_history(runner_root)

    assert RunnerRuntime.recent_history(missing_history_root, 5) == []
    assert RunnerRuntime.recent_history(runner_root, 0) == []

    File.mkdir_p!(RunnerRuntime.history_path(broken_history_root))
    assert RunnerRuntime.recent_history(broken_history_root, 5) == []

    File.mkdir_p!(Path.join(fake_git_root, ".git"))
    assert RunnerRuntime.current_version_sha(fake_git_root) == nil
    assert RunnerRuntime.effective_required_labels(["Dogfood"]) == ["dogfood"]
    assert RunnerRuntime.effective_required_labels([" Dogfood ", "", "dogfood"], :invalid) == ["dogfood"]
    assert RunnerRuntime.runner_mode(%{"runner_mode" => " "}) == "stable"
    assert RunnerRuntime.runner_mode(nil) == "stable"
    assert RunnerRuntime.canary_required_labels(%{"canary_required_labels" => []}) == ["canary:symphony"]
    assert RunnerRuntime.canary_required_labels(:invalid) == ["canary:symphony"]
    assert RunnerRuntime.runner_rule_id(%{"runner_mode" => "canary_failed"}) == "runner.canary_failed"
    assert RunnerRuntime.runner_rule_id(%{"runner_mode" => "stable"}) == nil
    assert RunnerRuntime.runner_rule_id(:invalid) == nil
    assert RunnerRuntime.rollback_rule_id(:invalid) == nil

    File.cd!(runner_root, fn ->
      current_root = Path.expand(File.cwd!())
      assert RunnerRuntime.current_checkout_root() == current_root
      assert current_root in RunnerRuntime.protected_paths()
      assert RunnerRuntime.overlaps_protected_path?(Path.join(current_root, "nested"))
    end)
  end

  defp with_log_file_env(value, fun) do
    previous = Application.get_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, value)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous)
      end
    end
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
