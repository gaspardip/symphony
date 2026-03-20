defmodule SymphonyElixir.GitManagerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitManager
  alias SymphonyElixir.RunStateStore

  test "reset_to_base preserves runtime state across branch reset" do
    workspace = Path.join(System.tmp_dir!(), "git-manager-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".git"))

    state_path = RunStateStore.state_path(workspace)
    File.mkdir_p!(Path.dirname(state_path))
    File.write!(state_path, ~s({"stage":"post_merge","issue_identifier":"CLZ-14"}))

    harness = %{base_branch: "gaspar/harness-engineering"}

    command_runner = fn
      "git", ["fetch", "origin", "gaspar/harness-engineering:refs/remotes/origin/gaspar/harness-engineering"], _opts ->
        {"", 0}

      "git", ["checkout", "-f", "gaspar/harness-engineering"], _opts ->
        File.write!(state_path, ~s({"stage":"done"}))
        {"", 0}

      "git", ["reset", "--hard", "origin/gaspar/harness-engineering"], _opts ->
        File.rm(state_path)
        {"", 0}
    end

    assert :ok =
             GitManager.reset_to_base(workspace, harness, command_runner: command_runner)

    assert File.read!(state_path) == ~s({"stage":"post_merge","issue_identifier":"CLZ-14"})
  end

  test "prepare_issue_branch clears a stale index lock and retries checkout once" do
    workspace = Path.join(System.tmp_dir!(), "git-manager-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".git"))
    lock_path = Path.join(workspace, ".git/index.lock")
    File.write!(lock_path, "stale\n")

    issue = %{identifier: "EVT-LOCK-01"}
    harness = %{base_branch: "main"}

    parent = self()

    command_runner = fn
      "git", ["fetch", "origin", "main:refs/remotes/origin/main"], _opts ->
        {"", 0}

      "git", ["checkout", "symphony/evt-lock-01"], _opts ->
        {"missing branch", 1}

      "git", ["checkout", "-B", "symphony/evt-lock-01", "origin/main"], _opts ->
        attempt = Process.get(:checkout_attempt, 0)
        Process.put(:checkout_attempt, attempt + 1)
        send(parent, {:checkout_attempt, attempt + 1, File.exists?(lock_path)})

        case attempt do
          0 -> {"fatal: Unable to create '#{lock_path}': File exists.\n", 128}
          _ -> {"", 0}
        end

      "git", ["config", "branch.symphony/evt-lock-01.symphony-base-branch", "main"], _opts ->
        {"", 0}
    end

    assert {:ok, %{branch: "symphony/evt-lock-01", base_branch: "main"}} =
             GitManager.prepare_issue_branch(workspace, issue, harness, command_runner: command_runner)

    assert_receive {:checkout_attempt, 1, true}
    assert_receive {:checkout_attempt, 2, false}
    refute File.exists?(lock_path)
  end

  test "prepare_issue_branch fetches the base branch into origin for branch-only clones" do
    root = Path.join(System.tmp_dir!(), "git-manager-fetch-base-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    workspace = Path.join(root, "workspace")

    try do
      init_git_workspace!(source)
      git_ok!(source, ["checkout", "-b", "codex/proof-feature"])
      File.write!(Path.join(source, "FEATURE.md"), "proof\n")
      git_ok!(source, ["add", "FEATURE.md"])
      git_ok!(source, ["commit", "-m", "feature"])

      git_ok!(root, ["clone", "--depth", "1", "--branch", "codex/proof-feature", source, workspace])

      assert {_, 1} = System.cmd("git", ["rev-parse", "--verify", "--quiet", "origin/main"], cd: workspace)

      issue = %{identifier: "MT-BASE-FETCH"}
      harness = %{base_branch: "main"}

      assert {:ok, %{branch: "symphony/mt-base-fetch", base_branch: "main"}} =
               GitManager.prepare_issue_branch(workspace, issue, harness)

      assert {base_sha, 0} = System.cmd("git", ["rev-parse", "--verify", "--quiet", "origin/main"], cd: workspace)
      assert String.trim(base_sha) != ""
      assert {branch_name, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: workspace)
      assert String.trim(branch_name) == "symphony/mt-base-fetch"
    after
      File.rm_rf(root)
    end
  end

  defp init_git_workspace!(workspace) do
    File.mkdir_p!(workspace)
    git_ok!(workspace, ["init", "-b", "main"])
    git_ok!(workspace, ["config", "user.name", "Test User"])
    git_ok!(workspace, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    git_ok!(workspace, ["add", "README.md"])
    git_ok!(workspace, ["commit", "-m", "initial"])
  end

  defp git_ok!(workspace, args) do
    File.mkdir_p!(workspace)
    assert {_, 0} = System.cmd("git", args, cd: workspace)
  end
end
