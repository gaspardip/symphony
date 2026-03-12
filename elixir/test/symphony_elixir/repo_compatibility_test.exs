defmodule SymphonyElixir.RepoCompatibilityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepoCompatibility

  test "reports events as autonomous-compatible" do
    assert {:ok, report} = RepoCompatibility.report("/Users/gaspar/src/events")
    assert report.compatible
    assert report.failing_checks == []
    assert Enum.any?(report.checks, &(&1.id == "behavioral_proof" and &1.status == :passed))
  end

  test "reports missing behavioral proof as incompatible" do
    workspace = temp_workspace("repo-compat-no-proof")

    try do
      init_git_workspace!(workspace)

      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
        """
        version: 1
        base_branch: main
        preflight:
          command:
            - ./scripts/preflight.sh
        validation:
          command:
            - ./scripts/validate.sh
        smoke:
          command:
            - ./scripts/smoke.sh
        post_merge:
          command:
            - ./scripts/post-merge.sh
        artifacts:
          command:
            - ./scripts/artifacts.sh
        pull_request:
          required_checks:
            - validate
        """
      )

      assert {:ok, report} = RepoCompatibility.report(workspace)
      refute report.compatible
      assert "behavioral_proof" in report.failing_checks
    after
      File.rm_rf(workspace)
    end
  end

  defp temp_workspace(suffix) do
    Path.join(System.tmp_dir!(), "symphony-#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp init_git_workspace!(workspace) do
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    System.cmd("git", ["add", "README.md"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)
  end
end
