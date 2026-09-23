defmodule SymphonyElixir.SelectedReleaseRootTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunnerRuntime

  setup do
    root = Path.join(System.tmp_dir!(), "selected-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root = File.cd!(root, &File.cwd!/0)
    install = Path.join(root, "install")
    external = Path.join(root, "external/release")
    File.mkdir_p!(install)
    File.mkdir_p!(external)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      runner_install_root: install,
      policy_require_checkout: false,
      policy_require_validation: false,
      observability_tracing_enabled: false
    )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, install: install, external: external, current: Path.join(install, "current")}
  end

  test "absolute external selection is exposed and rejects overlapping pre-run workspaces", c do
    File.ln_s!(c.external, c.current)

    for workspace <- [c.external, Path.join(c.external, "child"), Path.dirname(c.external)] do
      assert RunnerRuntime.overlaps_protected_path?(workspace)
      issue = %Issue{id: "selected-release-#{System.unique_integer([:positive])}", identifier: "SELECTED-1", title: "local policy probe", state: "In Progress"}
      assert {:stop, %RunPolicy.Violation{code: :runner_overlap}} = RunPolicy.enforce_pre_run(issue, workspace, include_pr_details: false)
    end

    assert RunnerRuntime.selected_release_root() == c.external
    assert RunnerRuntime.info().selected_release_root == c.external
    assert c.external in RunnerRuntime.protected_paths()
    refute RunnerRuntime.overlaps_protected_path?(c.external <> "-neighbor")
    assert Path.expand(c.install) in RunnerRuntime.protected_paths()
    assert RunnerRuntime.current_checkout_root() in RunnerRuntime.protected_paths()
  end

  test "relative current target resolves against the install directory", c do
    File.ln_s!("../external/release", c.current)
    assert RunnerRuntime.overlaps_protected_path?(Path.join(c.external, "nested"))
    assert RunnerRuntime.selected_release_root() == c.external
    assert RunnerRuntime.info().selected_release_root == c.external
  end

  test "missing current does not fall back to promoted metadata", c do
    File.write!(RunnerRuntime.metadata_path(c.install), Jason.encode!(%{"promoted_release_path" => c.external, "current_version_sha" => "metadata-only"}))
    assert RunnerRuntime.selected_release_root() == nil
    assert RunnerRuntime.info().selected_release_root == nil
    refute c.external in RunnerRuntime.protected_paths()
    refute RunnerRuntime.overlaps_protected_path?(c.external)
  end

  test "a regular current entry is not interpreted as a selected release", c do
    File.write!(c.current, c.external)
    assert RunnerRuntime.selected_release_root() == nil
    assert RunnerRuntime.info().selected_release_root == nil
    refute c.external in RunnerRuntime.protected_paths()
  end

  test "a dangling current target stays selected and protected without becoming healthy", c do
    missing = Path.join(c.root, "missing/release")
    File.write!(RunnerRuntime.metadata_path(c.install), Jason.encode!(%{"runner_mode" => "stable", "promoted_release_path" => c.external, "promoted_release_sha" => "release"}))
    File.ln_s!(missing, c.current)
    assert RunnerRuntime.selected_release_root() == missing
    assert RunnerRuntime.overlaps_protected_path?(missing)
    health = RunnerRuntime.runner_health(["dogfood:symphony"], c.install)
    assert health.dispatch_enabled == false
    assert health.rule_id == "runner.current_missing"
  end

  test "changing selected release does not change the existing checkout version field", c do
    checkout = Path.join(c.root, "checkout")
    second = Path.join(c.root, "external/second")
    checkout_sha = seed_git_checkout!(checkout, "checkout")
    selected_sha = seed_git_checkout!(c.external, "first selection")
    second_sha = seed_git_checkout!(second, "second selection")
    assert checkout_sha != selected_sha
    assert selected_sha != second_sha
    File.ln_s!(c.external, c.current)

    File.cd!(checkout, fn ->
      assert RunnerRuntime.runtime_version() == checkout_sha
      first = RunnerRuntime.info()
      assert first.selected_release_root == c.external
      assert first.current_checkout_root == checkout
      assert first.runtime_version == checkout_sha
      assert first.current_version_sha == checkout_sha

      File.rm!(c.current)
      File.ln_s!(second, c.current)
      second_info = RunnerRuntime.info()
      assert second_info.selected_release_root == second
      assert second_info.current_checkout_root == checkout
      assert second_info.runtime_version == checkout_sha
      assert second_info.current_version_sha == checkout_sha
      assert RunnerRuntime.runtime_version() == checkout_sha
    end)
  end

  defp seed_git_checkout!(path, contents) do
    File.mkdir_p!(path)
    assert {_, 0} = System.cmd("git", ["init", "--quiet", path])
    File.write!(Path.join(path, "fixture.txt"), contents)
    assert {_, 0} = System.cmd("git", ["add", "fixture.txt"], cd: path)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-c", "user.name=Symphony Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "local fixture"],
               cd: path
             )

    assert {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    String.trim(sha)
  end
end
