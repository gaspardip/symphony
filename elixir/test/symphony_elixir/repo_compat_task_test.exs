defmodule SymphonyElixir.RepoCompatTaskTest do
  use ExUnit.Case

  alias Mix.Tasks.Repo.Compat, as: RepoCompatTask

  @compatible_workspace Path.expand("../../..", __DIR__)

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
    assert :ok = RepoCompatTask.run([@compatible_workspace])
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ "repo.compat: compatible"
    assert message =~ "workspace: #{@compatible_workspace}"
    assert message =~ "behavioral_proof"
  end

  test "prints json when requested" do
    assert :ok = RepoCompatTask.run(["--json", @compatible_workspace])
    assert_receive {:mix_shell, :info, [message]}

    assert %{"compatible" => true, "workspace" => @compatible_workspace} =
             Jason.decode!(message)
  end
end
