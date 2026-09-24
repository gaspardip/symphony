defmodule SymphonyElixir.GitManagerFetchIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{GitManager, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "git-fetch-integration-#{System.unique_integer([:positive])}")
    template = Path.join(root, "empty-template")
    File.mkdir_p!(template)
    on_exit(fn -> File.rm_rf!(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 0,
      workspace_root: Path.join(root, "workspaces"),
      manual_store_root: Path.join(root, "manual"),
      runner_install_root: Path.join(root, "install"),
      observability_debug_artifact_root: Path.join(root, "debug")
    )

    inherited_git =
      for {key, _value} <- System.get_env(), String.starts_with?(key, "GIT_"), do: {key, nil}

    env =
      inherited_git ++
        [
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_CONFIG_COUNT", "0"},
          {"GIT_ALLOW_PROTOCOL", "file"},
          {"GIT_TERMINAL_PROMPT", "0"},
          {"GIT_TEMPLATE_DIR", template}
        ]

    {:ok, root: root, git: System.find_executable("git") || raise("git unavailable"), env: env}
  end

  test "prepare fetches main outside a feature-only clone and refreshes the same work branch", context do
    assert_prepares_and_refreshes(context, "codex/proof-feature", "main", nil)
  end

  test "prepare fetches a custom base outside a main-only clone and refreshes the same work branch", context do
    assert_prepares_and_refreshes(context, "main", "release/local-base", %{base_branch: "release/local-base"})
  end

  test "reset creates an absent local base and preserves runtime state across repeated resets", context do
    fixture = fixture!(context, "main", "release/local-base")
    state_path = RunStateStore.state_path(fixture.workspace)
    contents = ~s({"stage":"post_merge","issue_identifier":"FETCH-RESET"})
    File.mkdir_p!(Path.dirname(state_path))
    File.write!(state_path, contents)
    harness = %{base_branch: fixture.base}
    options = [command_runner: runner(context)]

    assert {_, 1} = command(context, fixture.workspace, ["show-ref", "--verify", "--quiet", "refs/heads/#{fixture.base}"])

    first = advance!(context, fixture, "first")
    assert :ok = GitManager.reset_to_base(fixture.workspace, harness, options)
    assert git!(context, fixture.workspace, ["branch", "--show-current"]) == fixture.base
    assert git!(context, fixture.workspace, ["rev-parse", "HEAD"]) == first
    assert git!(context, fixture.workspace, ["rev-parse", "origin/#{fixture.base}"]) == first
    assert File.read!(state_path) == contents

    second = advance!(context, fixture, "second")
    File.write!(Path.join(fixture.workspace, "README.md"), "discarded local change\n")
    assert :ok = GitManager.reset_to_base(fixture.workspace, harness, options)
    assert git!(context, fixture.workspace, ["branch", "--show-current"]) == fixture.base
    assert git!(context, fixture.workspace, ["rev-parse", "HEAD"]) == second
    assert git!(context, fixture.workspace, ["rev-parse", "origin/#{fixture.base}"]) == second
    assert File.read!(state_path) == contents
    assert File.read!(Path.join(fixture.workspace, "README.md")) == "second\n"
    assert git!(context, fixture.workspace, ["config", "--get-all", "remote.origin.fetch"]) == fixture.refmap
    assert git!(context, fixture.workspace, ["rev-parse", "origin/main"]) == fixture.clone_oid
    assert git!(context, context.root, ["--git-dir=#{fixture.origin}", "rev-parse", "#{fixture.base}"]) == second
  end

  test "missing remote base surfaces fetch errors and preserves checkout and runtime state", context do
    fixture = fixture!(context, "main", "release/local-base")
    state_path = RunStateStore.state_path(fixture.workspace)
    contents = ~s({"stage":"post_merge","issue_identifier":"FETCH-MISSING"})
    File.mkdir_p!(Path.dirname(state_path))
    File.write!(state_path, contents)
    status = git!(context, fixture.workspace, ["status", "--porcelain"])
    options = [command_runner: runner(context)]
    harness = %{base_branch: "missing/base"}

    assert {:error, {:git_failed, prepare_command, 128, _output}} =
             GitManager.prepare_issue_branch(fixture.workspace, %{identifier: "FETCH-MISSING"}, harness, options)

    assert String.starts_with?(prepare_command, "fetch ")
    assert File.read!(state_path) == contents
    assert git!(context, fixture.workspace, ["rev-parse", "HEAD"]) == fixture.clone_oid

    assert {:error, {:git_failed, reset_command, 128, _output}} =
             GitManager.reset_to_base(fixture.workspace, harness, options)

    assert String.starts_with?(reset_command, "fetch ")
    assert File.read!(state_path) == contents
    assert git!(context, fixture.workspace, ["rev-parse", "HEAD"]) == fixture.clone_oid
    assert git!(context, fixture.workspace, ["branch", "--show-current"]) == "main"
    assert git!(context, fixture.workspace, ["status", "--porcelain"]) == status
    assert {_, 1} = command(context, fixture.workspace, ["show-ref", "--verify", "--quiet", "refs/heads/symphony/fetch-missing"])
  end

  defp assert_prepares_and_refreshes(context, cloned_branch, base, harness) do
    fixture = fixture!(context, cloned_branch, base)
    issue = %{identifier: "FETCH-BASE", branch_name: "work/fetch-base"}
    options = [command_runner: runner(context)]

    for label <- ["first", "second"] do
      expected = advance!(context, fixture, label)

      assert {:ok, %{branch: "work/fetch-base", base_branch: ^base}} =
               GitManager.prepare_issue_branch(fixture.workspace, issue, harness, options)

      assert git!(context, fixture.workspace, ["rev-parse", "HEAD"]) == expected
      assert git!(context, fixture.workspace, ["rev-parse", "origin/#{base}"]) == expected
      assert git!(context, fixture.workspace, ["branch", "--show-current"]) == "work/fetch-base"
      assert git!(context, fixture.workspace, ["config", "branch.work/fetch-base.symphony-base-branch"]) == base
      assert git!(context, fixture.workspace, ["config", "--get-all", "remote.origin.fetch"]) == fixture.refmap
      assert git!(context, fixture.workspace, ["rev-parse", "origin/#{cloned_branch}"]) == fixture.clone_oid
      assert git!(context, fixture.workspace, ["status", "--porcelain"]) == ""
      assert git!(context, context.root, ["--git-dir=#{fixture.origin}", "rev-parse", base]) == expected
    end
  end

  defp fixture!(context, cloned_branch, base) do
    seed = Path.join(context.root, "seed")
    origin = Path.join(context.root, "origin.git")
    workspace = Path.join(context.root, "workspace")
    git!(context, context.root, ["init", "-b", "main", seed])
    commit!(context, seed, "main")
    other = if base == "main", do: cloned_branch, else: base
    git!(context, seed, ["checkout", "-b", other])
    commit!(context, seed, "other")
    git!(context, context.root, ["clone", "--bare", "--no-local", "--", seed, origin])
    git!(context, context.root, ["--git-dir=#{origin}", "symbolic-ref", "HEAD", "refs/heads/main"])
    git!(context, context.root, ["clone", "--single-branch", "--branch", cloned_branch, "--no-local", "--", origin, workspace])

    assert {_, 1} = command(context, workspace, ["show-ref", "--verify", "--quiet", "refs/remotes/origin/#{base}"])
    refmap = git!(context, workspace, ["config", "--get-all", "remote.origin.fetch"])
    assert refmap == "+refs/heads/#{cloned_branch}:refs/remotes/origin/#{cloned_branch}"

    %{seed: seed, origin: origin, workspace: workspace, base: base, refmap: refmap, clone_oid: git!(context, workspace, ["rev-parse", "HEAD"])}
  end

  defp advance!(context, fixture, label) do
    git!(context, fixture.seed, ["checkout", fixture.base])
    commit!(context, fixture.seed, label)
    git!(context, context.root, ["--git-dir=#{fixture.origin}", "fetch", fixture.seed, "refs/heads/#{fixture.base}:refs/heads/#{fixture.base}"])
    git!(context, fixture.seed, ["rev-parse", "HEAD"])
  end

  defp commit!(context, seed, label) do
    File.write!(Path.join(seed, "README.md"), label <> "\n")
    git!(context, seed, ["add", "README.md"])
    git!(context, seed, ["-c", "user.name=Local fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", label])
  end

  defp runner(context) do
    fn "git", args, options ->
      System.cmd(context.git, args, Keyword.put(options, :env, context.env))
    end
  end

  defp command(context, cwd, args) do
    System.cmd(context.git, args, cd: cwd, env: context.env, stderr_to_stdout: true)
  end

  defp git!(context, cwd, args) do
    assert {output, 0} = command(context, cwd, args)
    String.trim(output)
  end
end
