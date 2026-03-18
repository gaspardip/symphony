defmodule SymphonyElixir.HarnessCheckTaskTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureIO

  test "mix harness.check passes for the checked-in symphony repo" do
    repo_root = Path.expand("../../..", __DIR__)

    File.cd!(repo_root, fn ->
      assert capture_io(fn ->
               Mix.Tasks.Harness.Check.run([])
             end) =~ "harness.check: self-development harness is valid"
    end)
  end

  test "mix harness.check raises outside a Symphony repo root" do
    workspace = temp_workspace("harness-check-missing")

    try do
      init_git_workspace!(workspace)

      File.cd!(workspace, fn ->
        Mix.Task.reenable("harness.check")

        assert_raise RuntimeError, ~r/Unable to locate repo root for harness check/, fn ->
          capture_io(fn ->
            Mix.Tasks.Harness.Check.run([])
          end)
        end
      end)
    after
      File.rm_rf(workspace)
    end
  end

  test "mix harness.check raises for invalid harness files" do
    workspace = temp_workspace("harness-check-invalid")

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.write!(Path.join(workspace, ".symphony/harness.yml"), ":\n")

      File.cd!(workspace, fn ->
        Mix.Task.reenable("harness.check")

        assert_raise Mix.Error, ~r/harness\.check failed/, fn ->
          capture_io(fn ->
            Mix.Tasks.Harness.Check.run([])
          end)
        end
      end)
    after
      File.rm_rf(workspace)
    end
  end

  test "mix harness.check formats list-based harness validation errors" do
    workspace = temp_workspace("harness-check-invalid-base-branch")
    repo_root = Path.expand("../../..", __DIR__)
    harness_path = Path.join(repo_root, ".symphony/harness.yml")

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      invalid_harness =
        harness_path
        |> File.read!()
        |> String.replace("base_branch: main", "base_branch: \"   \"")

      File.write!(Path.join(workspace, ".symphony/harness.yml"), invalid_harness)

      File.cd!(workspace, fn ->
        Mix.Task.reenable("harness.check")

        assert_raise Mix.Error, ~r/harness\.check failed: invalid_harness_value: base_branch/, fn ->
          capture_io(fn ->
            Mix.Tasks.Harness.Check.run([])
          end)
        end
      end)
    after
      File.rm_rf(workspace)
    end
  end

  defp temp_workspace(suffix) do
    Path.join(System.tmp_dir!(), "symphony-#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp init_git_workspace!(workspace) do
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace, stderr_to_stdout: true)
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    System.cmd("git", ["add", "README.md"], cd: workspace, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace, stderr_to_stdout: true)
  end
end
