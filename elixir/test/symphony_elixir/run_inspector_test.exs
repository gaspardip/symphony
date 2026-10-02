defmodule SymphonyElixir.RunInspectorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RunInspector

  test "background Git readers preserve the index while still reporting worktree changes" do
    readers = [
      fn workspace -> RunInspector.inspect(workspace, include_pr_details: false).status_text end,
      &RunInspector.changed_paths/1,
      &RunInspector.changed_paths_checked/1
    ]

    for {reader, number} <- Enum.with_index(readers) do
      workspace = Path.join(System.tmp_dir!(), "inspector-index-#{number}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)
      {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)
      path = Path.join(workspace, "tracked.txt")
      File.write!(path, "original\n")
      {_, 0} = System.cmd("git", ["add", "tracked.txt"], cd: workspace)

      {_, 0} =
        System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "fixture"], cd: workspace, stderr_to_stdout: true)

      index = Path.join(workspace, ".git/index")
      before = File.read!(index)
      :ok = File.touch(path, System.os_time(:second) + 10)

      assert reader.(workspace) in [nil, [], {:ok, []}]
      assert File.read!(index) == before

      # Prove the stat change exercises Git's optional refresh on this filesystem.
      {_, 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace, env: [{"GIT_OPTIONAL_LOCKS", "1"}])
      refute File.read!(index) == before

      before = File.read!(index)
      File.write!(path, "changed\n")
      assert reader.(workspace) not in [nil, [], {:ok, []}]
      assert File.read!(index) == before
    end
  end

  test "changed paths expands new nested directories and respects ignored files" do
    workspace = Path.join(System.tmp_dir!(), "changed-paths-nested-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)
    File.write!(Path.join(workspace, ".git/info/exclude"), "*.cache\n")

    for directory <- ["lib/nested", "test/nested", ".symphony"] do
      File.mkdir_p!(Path.join(workspace, directory))
    end

    File.write!(Path.join(workspace, "lib/nested/labels.py"), "def label(): return 'example'\n")
    File.write!(Path.join(workspace, "test/nested/test_labels.py"), "assert label() == 'example'\n")
    File.write!(Path.join(workspace, "lib/nested/ignored.cache"), "ignored\n")
    File.write!(Path.join(workspace, ".symphony/run_state.json"), "{}\n")

    assert Enum.sort(RunInspector.changed_paths(workspace)) == [
             "lib/nested/labels.py",
             "test/nested/test_labels.py"
           ]
  end

  test "required checks rollup classifies missing, pending, failed, and cancelled checks" do
    harness = %RepoHarness{required_checks: ["ci / validate", "ci / ui-tests", "ci / smoke", "ci / docs"]}

    snapshot = %RunInspector.Snapshot{
      pr_url: "https://example.com/pr/1",
      pr_state: "OPEN",
      review_decision: "APPROVED",
      harness: harness,
      check_statuses: [
        %{name: "ci / validate", status: "COMPLETED", conclusion: "SUCCESS"},
        %{name: "ci / ui-tests", status: "IN_PROGRESS", conclusion: nil},
        %{name: "ci / smoke", status: "COMPLETED", conclusion: "FAILURE"},
        %{name: "ci / docs", status: "COMPLETED", conclusion: "CANCELLED"}
      ]
    }

    rollup = RunInspector.required_checks_rollup(snapshot)

    assert rollup.state == :failed
    assert rollup.required == ["ci / validate", "ci / ui-tests", "ci / smoke", "ci / docs"]
    assert rollup.pending == ["ci / ui-tests"]
    assert rollup.failed == ["ci / smoke"]
    assert rollup.cancelled == ["ci / docs"]
    assert rollup.missing == []
    refute RunInspector.required_checks_passed?(snapshot)
    refute RunInspector.ready_for_merge?(snapshot)
  end

  test "required checks rollup treats absent required checks as missing" do
    snapshot = %RunInspector.Snapshot{
      pr_url: "https://example.com/pr/2",
      pr_state: "OPEN",
      review_decision: "APPROVED",
      harness: %RepoHarness{required_checks: ["ci / validate"]},
      check_statuses: []
    }

    rollup = RunInspector.required_checks_rollup(snapshot)

    assert rollup.state == :missing
    assert rollup.missing == ["ci / validate"]
    refute RunInspector.required_checks_passed?(snapshot)
  end

  test "required checks rollup matches GitHub workflow names when the check-run name differs" do
    snapshot = %RunInspector.Snapshot{
      pr_url: "https://example.com/pr/4",
      pr_state: "OPEN",
      review_decision: "APPROVED",
      harness: %RepoHarness{required_checks: ["pr-description-lint"]},
      check_statuses: [
        %{
          name: "validate-pr-description",
          workflow_name: "pr-description-lint",
          status: "COMPLETED",
          conclusion: "SUCCESS"
        }
      ]
    }

    rollup = RunInspector.required_checks_rollup(snapshot)

    assert rollup.state == :passed
    assert rollup.missing == []
    assert RunInspector.required_checks_passed?(snapshot)
  end

  test "ready_for_merge requires an open pull request even when checks and reviews pass" do
    harness = %RepoHarness{required_checks: ["ci / validate"]}

    merged_snapshot = %RunInspector.Snapshot{
      pr_url: "https://example.com/pr/3",
      pr_state: "MERGED",
      review_decision: "APPROVED",
      harness: harness,
      check_statuses: [%{name: "ci / validate", status: "COMPLETED", conclusion: "SUCCESS"}]
    }

    closed_snapshot = %{merged_snapshot | pr_state: "CLOSED"}
    open_snapshot = %{merged_snapshot | pr_state: "OPEN"}

    refute RunInspector.ready_for_merge?(merged_snapshot)
    refute RunInspector.ready_for_merge?(closed_snapshot)
    assert RunInspector.ready_for_merge?(open_snapshot)
  end
end
