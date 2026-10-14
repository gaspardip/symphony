defmodule SymphonyElixir.OrchestratorRetryDriver do
  @moduledoc false
  use GenServer
  alias SymphonyElixir.Orchestrator

  def start_link(state, issue_id, recipient \\ self()) do
    GenServer.start_link(__MODULE__, {state, issue_id, recipient})
  end

  def run(state, issue_id) do
    {:ok, pid} = start_link(state, issue_id)

    try do
      send(pid, :run)

      receive do
        {:timer_result, ^pid, {:noreply, next}} -> {:noreply, next}
      after
        3_000 -> raise "retry did not settle: #{inspect(:sys.get_state(pid, 5_000))}"
      end
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  @impl true
  def init({state, id, recipient}), do: {:ok, %{runtime: state, issue_id: id, recipient: recipient, waiting: false}}

  @impl true
  def handle_info(:run, state) do
    entry = Map.fetch!(state.runtime.retry_attempts, state.issue_id)
    dispatch({:retry_issue, state.issue_id, entry.retry_ref}, %{state | waiting: true})
  end

  def handle_info(message, state), do: dispatch(message, state)

  defp dispatch(message, state) do
    {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
    state = %{state | runtime: runtime}
    pending = get_in(runtime.retry_attempts, [state.issue_id, :status]) in [:ready, :reading]

    if state.waiting and is_nil(runtime.admission_read) and not pending do
      send(state.recipient, {:timer_result, self(), {:noreply, runtime}})
      {:noreply, %{state | waiting: false}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

  def handle_call({:schedule, id, attempt, metadata}, _from, state) do
    runtime = Orchestrator.schedule_issue_retry_for_test(state.runtime, id, attempt, metadata)
    {:reply, runtime.retry_attempts[id], %{state | runtime: runtime}}
  end

  def handle_call(message, from, state) do
    case Orchestrator.handle_call(message, from, state.runtime) do
      {:reply, reply, runtime} -> {:reply, reply, %{state | runtime: runtime}}
      {:noreply, runtime} -> {:noreply, %{state | runtime: runtime}}
    end
  end
end
