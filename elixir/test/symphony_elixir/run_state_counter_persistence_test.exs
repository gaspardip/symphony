defmodule SymphonyElixir.RunStateCounterPersistenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunStateStore

  setup do
    workspace = Path.join(System.tmp_dir!(), "run-state-counts-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "repeated transitions keep their counts across snapshot reloads", %{workspace: workspace} do
    for stage <- ["implement", "blocked", "implement", "blocked"] do
      assert {:ok, _} = RunStateStore.transition(workspace, stage)
      assert {:ok, _} = RunStateStore.load(workspace)
    end

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage_transition_counts == %{"implement" => 2, "blocked" => 2}
    assert Enum.map(state.stage_history, & &1.stage) == ["implement", "blocked", "implement", "blocked"]
  end
end
