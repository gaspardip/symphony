defmodule SymphonyElixir.OrchestratorPhase6Test do
  use SymphonyElixir.TestSupport

  test "snapshot returns unavailable for a missing orchestrator" do
    assert Orchestrator.snapshot(Module.concat(__MODULE__, :MissingOrchestrator), 10) == :unavailable
  end

  test "down messages for unknown refs do not change orchestrator state" do
    orchestrator_name = Module.concat(__MODULE__, :UnknownDownOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    before_state = :sys.get_state(pid)
    send(pid, {:DOWN, make_ref(), :process, self(), :normal})
    Process.sleep(20)
    after_state = :sys.get_state(pid)

    assert after_state.running == before_state.running
    assert after_state.retry_attempts == before_state.retry_attempts
  end

  test "codex updates for unknown issues are ignored" do
    orchestrator_name = Module.concat(__MODULE__, :UnknownCodexUpdateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    before_state = :sys.get_state(pid)

    send(
      pid,
      {:codex_worker_update, "missing-issue", %{event: :notification, payload: %{method: "noop"}, timestamp: DateTime.utc_now()}}
    )

    Process.sleep(20)
    after_state = :sys.get_state(pid)

    assert after_state.running == before_state.running
    assert after_state.codex_totals == before_state.codex_totals
  end

  test "retry_issue for a missing retry entry is a no-op" do
    orchestrator_name = Module.concat(__MODULE__, :MissingRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    before_state = :sys.get_state(pid)
    send(pid, {:retry_issue, "missing-issue"})
    Process.sleep(20)
    after_state = :sys.get_state(pid)

    assert after_state.retry_attempts == before_state.retry_attempts
    assert after_state.running == before_state.running
  end

  test "unexpected messages are ignored" do
    orchestrator_name = Module.concat(__MODULE__, :UnexpectedMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    before_state = :sys.get_state(pid)
    send(pid, {:something, :unexpected})
    Process.sleep(20)
    after_state = :sys.get_state(pid)

    assert after_state.running == before_state.running
    assert after_state.retry_attempts == before_state.retry_attempts
  end
end
