defmodule SymphonyElixir.RepoCompatTaskTest do
  use ExUnit.Case

  alias Mix.Tasks.Repo.Compat, as: RepoCompatTask

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("repo.compat")

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "prints a human-readable compatibility report" do
    workspace = temp_workspace("repo-compat-task-human")

    try do
      write_compatible_workspace!(workspace)

      assert :ok = RepoCompatTask.run([workspace])
      assert_receive {:mix_shell, :info, [message]}
      assert message =~ "repo.compat: compatible"
      assert message =~ "workspace: #{workspace}"
      assert message =~ "behavioral_proof"
      assert message =~ "branch_base_setup"
    after
      File.rm_rf(workspace)
    end
  end

  test "prints json when requested" do
    workspace = temp_workspace("repo-compat-task-json")

    try do
      write_compatible_workspace!(workspace)

      assert :ok = RepoCompatTask.run(["--json", workspace])
      assert_receive {:mix_shell, :info, [message]}

      assert %{
               "compatible" => true,
               "workspace" => ^workspace,
               "failing_checks" => []
             } = Jason.decode!(message)
    after
      File.rm_rf(workspace)
    end
  end

  defp temp_workspace(suffix) do
    Path.join(System.tmp_dir!(), "symphony-#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp write_compatible_workspace!(workspace) do
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
      verification:
        behavioral_proof:
          required: true
          mode: unit_first
          source_paths:
            - lib/
          test_paths:
            - test/
      pull_request:
        required_checks:
          - make-all
      """
    )
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
