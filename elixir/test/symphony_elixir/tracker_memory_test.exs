defmodule SymphonyElixir.TrackerMemoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Memory

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok
  end

  test "successful writes are visible to every reader before notifications are consumed" do
    issue = %Issue{id: "memory-1", identifier: "MEM-1", state: "Human Review", source: :tracker}
    other = %Issue{id: "memory-2", identifier: "MEM-2", state: "Todo", source: :tracker}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, other])

    assert :ok = Memory.update_issue_state(issue.id, "In Progress")
    assert {:ok, %{state: "In Progress"}} = Memory.fetch_issue_by_id(issue.id)
    assert {:ok, %{state: "In Progress"}} = Memory.fetch_issue_by_identifier(issue.identifier)
    assert {:ok, [%{id: "memory-1", state: "In Progress"}]} = Memory.fetch_issue_states_by_ids([issue.id])
    assert {:ok, [%{id: "memory-1", state: "In Progress"}]} = Memory.fetch_issues_by_states(["In Progress"])
    assert {:ok, [%{state: "In Progress"}, ^other]} = Memory.fetch_candidate_issues()
    assert_received {:memory_tracker_state_update, "memory-1", "In Progress"}
  end

  test "concurrent state updates retain the completed writes of every issue" do
    issues = for index <- 1..8, do: %Issue{id: "memory-#{index}", identifier: "MEM-#{index}", state: "Todo", source: :tracker}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    owner = self()

    writers =
      for issue <- issues do
        Task.async(fn ->
          send(owner, {:writer_ready, self()})

          receive do
            :write -> Memory.update_issue_state(issue.id, "In Progress")
          after
            5_000 -> raise "memory writer was not released"
          end
        end)
      end

    for writer <- writers, do: assert_receive({:writer_ready, pid} when pid == writer.pid)
    for writer <- writers, do: send(writer.pid, :write)
    assert Enum.map(writers, &Task.await(&1, 10_000)) == List.duplicate(:ok, length(issues))
    assert {:ok, updated} = Memory.fetch_candidate_issues()
    assert Enum.map(updated, &{&1.id, &1.state}) == Enum.map(issues, &{&1.id, "In Progress"})
    for issue <- issues, do: assert_received({:memory_tracker_state_update, id, "In Progress"} when id == issue.id)
  end

  test "an unknown ID preserves the notification contract without creating an issue" do
    issue = %Issue{id: "memory-existing", identifier: "MEM-EXISTING", state: "Todo", source: :tracker}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert :ok = Memory.update_issue_state("memory-missing", "Blocked")
    assert {:ok, nil} = Memory.fetch_issue_by_id("memory-missing")
    assert {:ok, [^issue]} = Memory.fetch_candidate_issues()
    assert_received {:memory_tracker_state_update, "memory-missing", "Blocked"}
  end
end
