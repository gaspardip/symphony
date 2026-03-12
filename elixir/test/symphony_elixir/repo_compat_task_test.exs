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
    assert :ok = RepoCompatTask.run(["/Users/gaspar/src/events"])
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ "repo.compat: compatible"
    assert message =~ "behavioral_proof"
  end

  test "prints json when requested" do
    assert :ok = RepoCompatTask.run(["--json", "/Users/gaspar/src/events"])
    assert_receive {:mix_shell, :info, [message]}
    assert %{"compatible" => true, "workspace" => "/Users/gaspar/src/events"} = Jason.decode!(message)
  end
end
