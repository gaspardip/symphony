defmodule SymphonyElixir.AgentExecutionOwnerCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.AgentProvider.Claude

  # Delegates the actual owner handlers and dispatch boundary; no provider,
  # remote tracker, or product-only synchronization hook is introduced.
  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, Orchestrator, RunStateStore}

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    @impl true
    def init(observer) do
      runtime = %Orchestrator.State{
        lease_owner: "i2b-owner-#{System.unique_integer([:positive])}",
        max_concurrent_agents: 2,
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
      }

      {:ok, %{runtime: runtime, observer: observer, hold_usage: false, hold_final_usage: false, usage: [], confirm: nil, hold_down: false, down: nil}}
    end

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}
    def handle_call({:hold_usage, value}, _from, state), do: {:reply, :ok, %{state | hold_usage: value}}
    def handle_call({:hold_down, value}, _from, state), do: {:reply, :ok, %{state | hold_down: value}}
    def handle_call({:hold_final_usage, value}, _from, state), do: {:reply, :ok, %{state | hold_final_usage: value}}

    def handle_call({:dispatch, issue, mode}, _from, state) do
      owner = self()
      observer = state.observer

      start_child = fn supervisor, _job ->
        # Captured synchronously before this fixture returns the new child. The
        # production closure separately captures begin/3's returned RAW.
        admitted_raw = issue |> SymphonyElixir.Workspace.path_for_issue() |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

        Task.Supervisor.start_child(supervisor, fn ->
          receive do
            {:captured, context} ->
              result =
                DispatchGate.run(owner, context.ticket.dispatch_id, fn ->
                  if mode == :held_entry do
                    receive do
                      :release_entry -> :ok
                    end
                  end

                  DispatchAudit.with_authorization(context.ticket, fn ->
                    AgentExecution.with_context(context.ticket, context.lease_token, owner, admitted_raw, fn ->
                      send(observer, {:worker_ready, self(), context})
                      worker_loop()
                    end)
                  end)
                end)

              case result do
                {:stop, {:accounting_uncertain, cause}} -> exit({:accounting_uncertain, cause})
                {:stop, {:stale_execution, ids, cause}} -> exit({:stale_execution, ids, cause})
                other -> other
              end
          end
        end)
      end

      spawn_worker = fn runtime, selected, attempt, recipient ->
        Orchestrator.do_spawn_issue_worker_for_test(runtime, selected, attempt, recipient, start_child_fun: start_child)
      end

      runtime = Orchestrator.do_dispatch_issue_for_test(state.runtime, issue, nil, spawn_fun: spawn_worker)
      entry = Map.get(runtime.running, issue.id)
      if entry, do: send(entry.pid, {:captured, entry.agent_execution.context})
      {:reply, entry, %{state | runtime: runtime}}
    end

    def handle_call({:stop, id}, _from, state) do
      runtime = Orchestrator.terminate_running_issue(state.runtime, id, false)
      {:reply, :ok, %{state | runtime: runtime}}
    end

    def handle_call({:alter_usage_expected, expected}, _from, state) do
      {:reply, :ok, %{state | usage: Enum.map(state.usage, &put_elem(&1, 2, expected))}}
    end

    def handle_call({:alter_usage_ordinal, ordinal}, _from, state) do
      messages = Enum.map(state.usage, fn message -> put_elem(message, 1, Map.put(elem(message, 1), :ordinal, ordinal)) end)
      {:reply, :ok, %{state | usage: messages}}
    end

    def handle_call(:release_usage, _from, state) do
      runtime =
        Enum.reduce(state.usage, state.runtime, fn message, runtime ->
          {:noreply, next} = Orchestrator.handle_info(message, runtime)
          next
        end)

      state = %{state | runtime: runtime, usage: [], hold_usage: false}

      state =
        case state.confirm do
          nil ->
            state

          {message, from} ->
            {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
            GenServer.reply(from, reply)
            %{state | runtime: runtime, confirm: nil}
        end

      {:reply, :ok, state}
    end

    def handle_call(:release_down, _from, %{down: message} = state) when not is_nil(message) do
      next = consume_down(message, %{state | hold_down: false, down: nil})
      {:reply, :ok, next}
    end

    def handle_call({:agent_execution, _invocation, _expected, {:confirm, _, _}} = message, from, %{usage: [_ | _]} = state),
      do: {:noreply, %{state | confirm: {message, from}}}

    def handle_call(message, from, state) do
      {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      {:reply, reply, %{state | runtime: runtime}}
    end

    @impl true
    def handle_info({:agent_execution_usage, _invocation, _expected, _observation} = message, %{hold_usage: true} = state) do
      send(state.observer, {:usage_held, self(), message})
      {:noreply, %{state | usage: state.usage ++ [message]}}
    end

    def handle_info({:agent_execution_usage, %{context: %{issue_id: id}}, _expected, _observation} = message, %{hold_final_usage: true} = state) do
      case get_in(state.runtime.running, [id, :agent_execution, :final_usage_receipt]) do
        nil ->
          {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
          {:noreply, %{state | runtime: runtime}}

        _receipt ->
          send(state.observer, {:usage_held, self(), message})
          {:noreply, %{state | usage: state.usage ++ [message]}}
      end
    end

    def handle_info({:DOWN, _, :process, _, _} = message, %{hold_down: true} = state) do
      send(state.observer, {:down_held, self(), message})
      {:noreply, %{state | down: message}}
    end

    def handle_info({:DOWN, _, :process, _, _} = message, state), do: {:noreply, consume_down(message, state)}

    def handle_info(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end

    defp consume_down(message, state) do
      send(state.observer, {:before_worker_down, self(), message, state.runtime})
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      send(state.observer, {:worker_down, self(), message, runtime})
      %{state | runtime: runtime}
    end

    defp worker_loop do
      receive do
        {:exercise, caller, ref, fun} ->
          result =
            try do
              fun.()
            rescue
              exception -> {:fixture_exception, exception, __STACKTRACE__}
            catch
              kind, reason -> {:fixture_caught, kind, reason, __STACKTRACE__}
            end

          send(caller, {:exercise_result, ref, result})
          worker_loop()

        :finish ->
          :ok

        {:exit, reason} ->
          exit(reason)
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "i2b-owner-#{System.unique_integer([:positive])}")

    issue = %Issue{
      id: "owner-current-#{System.unique_integer([:positive])}",
      identifier: "OWNER-1",
      title: "Current execution",
      description: "## Acceptance Criteria\n- preserve current state",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    configure!(root, 500_000)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    git = System.find_executable("git")

    for args <- [["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] do
      assert {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, "keep.txt"), "preserve workspace")
    assert {_, 0} = System.cmd(git, ["add", "-A"], cd: workspace)
    assert {_, 0} = System.cmd(git, ["commit", "-qm", "fixture"], cd: workspace)
    assert {_, 0} = System.cmd(git, ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)
    assert {_, 0} = System.cmd(git, ["checkout", "-q", "-b", SymphonyElixir.GitManager.issue_branch_name(issue)], cd: workspace)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue}
  end

  test "real admission stores the raw material event rather than the dispatch event", c do
    {owner, worker, entry} = start_worker(c)
    raw = raw!(c)
    assert entry.agent_execution.expected == RunStateStore.material_projection(raw)
    assert entry.last_ledger_event_id == raw["last_ledger_event_id"]
    refute entry.last_ledger_event_id == entry.dispatch_ticket.entry_event_id
    assert {:ok, _} = in_worker(worker, &AgentExecution.ensure_current/0)
    assert runtime(owner).running[c.issue.id].agent_execution.expected == entry.agent_execution.expected
  end

  test "a control after gate but before worker entry prevents its body and preserves custody", c do
    owner = start_driver()
    entry = GenServer.call(owner, {:dispatch, c.issue, :held_entry}, 10_000)
    assert is_map(entry)
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "operator"))
    before = evidence(c, entry)
    send(entry.pid, :release_entry)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, _, {:stale_execution, _, _}}, stopped}, 5_000
    refute_received {:worker_ready, _, _}
    assert_hold(c, stopped, entry, :stale)
    assert evidence(c, entry) == before
  end

  test "material control before queued usage changes neither usage totals nor policy", c do
    {owner, worker, entry} = start_worker(c)
    invocation = invocation(worker)
    assert :ok = GenServer.call(owner, {:hold_usage, true})
    send(worker, {:exercise, self(), make_ref(), fn -> AgentExecution.observe_usage(invocation, %{usage: counters(900_000)}) end})
    assert_receive {:usage_held, ^owner, _}, 2_000
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "operator"))
    before = evidence(c, entry)
    assert :ok = GenServer.call(owner, :release_usage)
    current = runtime(owner)
    assert current.agent_totals.total_tokens == 0
    assert current.running[c.issue.id].agent_total_tokens == 0
    assert current.running[c.issue.id].agent_execution.registry.live[invocation.binding].contribution == counters(0)
    assert current.token_usage_errors == %{}
    assert current.stale_execution_errors[c.issue.id].cause == :material_state_changed
    assert evidence(c, entry) == before
    refute_received {:memory_tracker_comment, _, _}
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_hold(c, stopped, entry, :stale)
  end

  test "control after durable checkpoint is checked again before budget policy", c do
    {owner, worker, entry} = start_worker(c)
    invocation = invocation(worker)
    attach_fault(c, :after_usage)
    assert {:stop, {:stale_execution, _, :material_state_changed}} = in_worker(worker, fn -> AgentExecution.observe_usage(invocation, %{usage: counters(900_000)}) end)
    assert_receive {:fault_applied, :after_usage}, 2_000
    current = runtime(owner)
    assert current.agent_totals.total_tokens == 900_000
    assert raw!(c)["token_usage"]["total_tokens"] == 900_000
    assert raw!(c)["policy_override"] == "operator-after-usage"
    assert raw!(c)["stage"] == "implement"
    refute_received {:memory_tracker_comment, _, _}
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_hold(c, stopped, entry, :stale)
  end

  for first <- [:stale, :accounting] do
    @tag first: first
    test "owner retains #{first} before a later terminal and public stop", c do
      {owner, worker, entry} = start_worker(c)

      assert {:stop, _} =
               in_worker(worker, fn ->
                 if c.first == :stale, do: AgentExecution.stale(:first), else: AgentExecution.fail(:first)
               end)

      other = if c.first == :stale, do: {:agent_execution_uncertain, entry.agent_execution.context, :later}, else: {:agent_execution_stale, entry.agent_execution.context, ids(entry), :later}
      send(owner, other)
      assert :ok = GenServer.call(owner, {:stop, c.issue.id})
      assert_receive {:worker_down, ^owner, _, stopped}, 5_000
      assert_hold(c, stopped, entry, c.first)
      if c.first == :stale, do: assert(stopped.token_usage_errors == %{}), else: assert(stopped.stale_execution_errors == %{})
    end
  end

  for stage <- ["blocked", "done"] do
    @tag stage: stage
    test "own #{stage} finishes exactly once without rebudget retry or workspace cleanup", c do
      {owner, worker, entry} = start_worker(c)
      assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current(c.stage, %{stop_reason: %{code: "own"}}) end)
      assert {:stop, {:execution_stopped, %{stage: stage}}} = in_worker(worker, &AgentExecution.confirm_current_invocation/0)
      assert stage == c.stage
      send(worker, :finish)
      assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, :normal} = down, stopped}, 5_000
      assert ref == entry.ref
      assert stopped.running == %{}
      refute Map.has_key?(stopped.lease_claims, c.issue.id)
      refute Map.has_key?(stopped.retry_attempts, c.issue.id)
      assert Map.has_key?(stopped.completed, c.issue.id) == (c.stage == "done")
      assert File.read!(Path.join(c.workspace, "keep.txt")) == "preserve workspace"
      assert length(finish_events(c)) == 1
      send(owner, down)
      assert runtime(owner).agent_totals == stopped.agent_totals
      assert length(finish_events(c)) == 1
      refute_received {:memory_tracker_comment, _, _}
    end
  end

  test "own terminal abnormal DOWN retains the actual exit outcome", c do
    {owner, worker, _entry} = start_worker(c)
    assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current("done", %{}) end)
    send(worker, {:exit, :provider_failure})
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, :provider_failure}, stopped}, 5_000
    refute Map.has_key?(stopped.completed, c.issue.id)
    assert [event] = finish_events(c)
    assert event["metadata"]["outcome"] == inspect({:exit, :provider_failure})
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
  end

  test "control after own terminal ack blocks DOWN finish and keeps the journal", c do
    {owner, worker, entry} = start_worker(c)
    assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current("blocked", %{stop_reason: %{code: "own"}}) end)
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "operator"))
    before = evidence(c, entry)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_hold(c, stopped, entry, :stale)
    assert evidence(c, entry) == before
    assert finish_events(c) == []
  end

  test "finish failure after its ledger event retains custody and does not replay", c do
    {owner, worker, entry} = start_worker(c)
    assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current("done", %{}) end)
    attach_fault(c, :finish_cleanup)
    send(worker, :finish)
    assert_receive {:fault_applied, :finish_cleanup}, 2_000
    assert_receive {:worker_down, ^owner, down, stopped}, 5_000
    assert_hold(c, stopped, entry, :accounting)
    assert File.exists?(Path.join(DispatchAudit.marker_directory(c.workspace), "retained-evidence"))
    assert length(finish_events(c)) == 1
    send(owner, down)
    assert runtime(owner).agent_totals == stopped.agent_totals
    assert length(finish_events(c)) == 1
  end

  test "normal audited DOWN evaluates an exhausted budget before finishing its ticket", c do
    {owner, worker, _entry} = start_worker(c)
    inv = invocation(worker)
    assert :ok = in_worker(worker, fn -> AgentExecution.observe_usage(inv, %{usage: counters(120_000)}) end)
    configure!(c.root, 100_000)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, :normal}, stopped}, 5_000
    assert raw!(c)["stage"] == "blocked"
    assert raw!(c)["token_usage"]["total_tokens"] == 120_000
    assert stopped.token_usage_errors == %{}
    assert stopped.stale_execution_errors == %{}
    assert stopped.lease_claims == %{}
    assert stopped.retry_attempts == %{}
    refute Map.has_key?(stopped.completed, c.issue.id)
    assert length(finish_events(c)) == 1
    id = c.issue.id
    assert_receive {:memory_tracker_comment, ^id, _}, 2_000
    assert_receive {:memory_tracker_state_update, ^id, "Blocked"}, 2_000
  end

  test "checked policy write failure on DOWN keeps ticket and claim with a visible cause", c do
    {owner, worker, entry} = start_worker(c)
    inv = invocation(worker)
    assert :ok = in_worker(worker, fn -> AgentExecution.observe_usage(inv, %{usage: counters(120_000)}) end)
    configure!(c.root, 100_000)
    marker = marker!(c)
    attach_fault(c, :policy_write)
    send(worker, :finish)
    assert_receive {:fault_applied, :policy_write}, 2_000
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_hold(c, stopped, entry, :accounting)
    assert marker!(c) == marker
    assert File.dir?(RunStateStore.state_path(c.workspace))
    assert finish_events(c) == []
    refute_received {:memory_tracker_comment, _, _}
  end

  test "owner policy stop accepts already queued usage with its exact previous receipt", c do
    configure!(c.root, 100_000)
    {owner, worker, entry} = start_worker(c)
    inv = invocation(worker)

    send(
      worker,
      {:exercise, self(), make_ref(),
       fn ->
         send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(120_000)}})
         send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(150_000)}})
         AgentExecution.confirm_invocation(inv)
       end}
    )

    assert_receive {:before_worker_down, ^owner, _, before_down}, 5_000
    receipt = before_down.running[c.issue.id].agent_execution.final_usage_receipt
    assert receipt.previous == entry.agent_execution.expected
    assert receipt.next == before_down.running[c.issue.id].agent_execution.expected
    assert receipt.binding == inv.binding and receipt.ordinal == inv.ordinal
    assert {:stop, %SymphonyElixir.RunPolicy.Violation{}} = receipt.outcome
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert raw!(c)["stage"] == "blocked"
    assert raw!(c)["token_usage"]["total_tokens"] == 150_000
    assert stopped.agent_totals.total_tokens == 150_000
    assert stopped.token_usage_errors == %{} and stopped.stale_execution_errors == %{}
    assert stopped.lease_claims == %{} and stopped.retry_attempts == %{}
    id = c.issue.id
    assert_receive {:memory_tracker_comment, ^id, _}, 2_000
    assert_receive {:memory_tracker_state_update, ^id, "Blocked"}, 2_000
    refute_received {:memory_tracker_comment, ^id, _}
  end

  test "a worker CAS advances owner expected before its retained callback and progress", c do
    {owner, worker, _entry} = start_worker(c)
    inv = invocation(worker)

    assert :ok =
             in_worker(worker, fn ->
               assert {:ok, _} = AgentExecution.update_current(%{policy_override: "own-change"})
               assert :ok = AgentExecution.observe_usage(inv, %{usage: counters(42)})
               assert :ok = AgentExecution.forward_update(inv, %{event: :session_started, timestamp: DateTime.utc_now(), session_id: "owner-session", expected: %{stage: "foreign"}})
               :ok
             end)

    current = runtime(owner).running[c.issue.id]
    assert current.agent_execution.expected == RunStateStore.material_projection(raw!(c))
    assert current.agent_total_tokens == 42
    assert current.agent_execution.terminal == nil
  end

  test "a material control before final usage rejects its receipt without overwriting the control", c do
    configure!(c.root, 100_000)
    {owner, worker, entry} = start_worker(c)
    inv = invocation(worker)
    assert :ok = GenServer.call(owner, {:hold_final_usage, true})
    assert :ok = GenServer.call(owner, {:hold_down, true})

    send(
      worker,
      {:exercise, self(), make_ref(),
       fn ->
         send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(120_000)}})
         send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(150_000)}})
         AgentExecution.confirm_invocation(inv)
       end}
    )

    assert_receive {:usage_held, ^owner, _}, 5_000
    assert_receive {:down_held, ^owner, _}, 5_000
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "after-own-stop"))
    before = evidence(c, entry)
    assert :ok = GenServer.call(owner, :release_usage)
    assert :ok = GenServer.call(owner, :release_down)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_hold(c, stopped, entry, :stale)
    assert stopped.agent_totals.total_tokens == 120_000
    assert evidence(c, entry) == before
    assert finish_events(c) == []
  end

  test "the terminal next snapshot cannot replace the previous expected of final usage", c do
    configure!(c.root, 100_000)
    {owner, worker, entry} = start_worker(c)
    inv = invocation(worker)
    assert :ok = GenServer.call(owner, {:hold_final_usage, true})
    assert :ok = GenServer.call(owner, {:hold_down, true})

    send(
      worker,
      {:exercise, self(), make_ref(),
       fn ->
         send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(120_000)}})
         send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(150_000)}})
         AgentExecution.confirm_invocation(inv)
       end}
    )

    assert_receive {:usage_held, ^owner, _}, 5_000
    assert_receive {:down_held, ^owner, _}, 5_000
    receipt = runtime(owner).running[c.issue.id].agent_execution.final_usage_receipt
    before = evidence(c, entry)
    assert :ok = GenServer.call(owner, {:alter_usage_expected, receipt.next})
    assert :ok = GenServer.call(owner, :release_usage)
    assert :ok = GenServer.call(owner, :release_down)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_hold(c, stopped, entry, :stale)
    assert stopped.stale_execution_errors[c.issue.id].cause == :final_usage_receipt_mismatch
    assert stopped.agent_totals.total_tokens == 120_000
    assert evidence(c, entry) == before
  end

  test "a final usage callback from another ordinal is discarded without changing the retained stop", c do
    configure!(c.root, 100_000)
    {owner, worker, entry} = start_worker(c)
    inv = invocation(worker)
    assert :ok = GenServer.call(owner, {:hold_final_usage, true})
    assert :ok = GenServer.call(owner, {:hold_down, true})

    send(
      worker,
      {:exercise, self(), make_ref(),
       fn ->
         send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(120_000)}})
         send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(150_000)}})
         AgentExecution.confirm_invocation(inv)
       end}
    )

    assert_receive {:usage_held, ^owner, _}, 5_000
    assert_receive {:down_held, ^owner, _}, 5_000
    assert :ok = GenServer.call(owner, {:alter_usage_ordinal, inv.ordinal + 1})
    assert :ok = GenServer.call(owner, :release_usage)
    assert :ok = GenServer.call(owner, :release_down)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert raw!(c)["token_usage"]["total_tokens"] == 120_000
    assert stopped.agent_totals.total_tokens == 120_000
    assert stopped.token_usage_errors == %{} and stopped.stale_execution_errors == %{}
    assert stopped.lease_claims == %{} and stopped.retry_attempts == %{}
    refute Map.has_key?(stopped.completed, c.issue.id)
    assert length(finish_events(c)) == 1
  end

  test "a contradictory stale exit identity on the current ref becomes accounting uncertainty", c do
    {owner, worker, entry} = start_worker(c)
    foreign = %{run_id: "foreign-run", dispatch_id: entry.dispatch_ticket.dispatch_id}
    before = evidence(c, entry)
    send(worker, {:exit, {:stale_execution, foreign, :synthetic}})
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_hold(c, stopped, entry, :accounting)
    assert {:accounting_uncertain, %{cause: :execution_terminal_identity_mismatch}} = stopped.token_usage_errors[c.issue.id]
    assert stopped.stale_execution_errors == %{}
    assert evidence(c, entry) == before
  end

  test "public stop preserves queued ordinary usage and never runs another budget decision", c do
    {owner, worker, entry} = start_worker(c)
    inv = invocation(worker)
    assert :ok = GenServer.call(owner, {:hold_usage, true})
    assert :ok = GenServer.call(owner, {:hold_down, true})
    send(worker, {:exercise, self(), make_ref(), fn -> AgentExecution.observe_usage(inv, %{usage: counters(150_000)}) end})
    assert_receive {:usage_held, ^owner, _}, 2_000
    configure!(c.root, 100_000)
    assert :ok = GenServer.call(owner, {:stop, c.issue.id})
    assert_receive {:down_held, ^owner, _}, 2_000
    assert :ok = GenServer.call(owner, :release_usage)
    assert :ok = GenServer.call(owner, :release_down)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert raw!(c)["stage"] == "implement"
    assert raw!(c)["token_usage"]["total_tokens"] == 150_000
    assert stopped.agent_totals.total_tokens == 150_000
    assert stopped.token_usage_errors == %{} and stopped.stale_execution_errors == %{}
    assert stopped.lease_claims == %{}
    assert length(finish_events(c)) == 1
    refute_received {:memory_tracker_comment, _, _}
    refute Map.has_key?(stopped.running, entry.issue.id)
  end

  test "old context and DOWN cannot change a successor with a new dispatch", c do
    {owner, worker, old} = start_worker(c)
    old_invocation = invocation(worker)
    assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current("done", %{}) end)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, old_down, _}, 5_000
    assert {:ok, _} = RunStateStore.transition(c.workspace, "implement", %{})
    next = GenServer.call(owner, {:dispatch, c.issue, :controlled}, 10_000)
    next_pid = next.pid
    assert_receive {:worker_ready, ^next_pid, _}, 5_000
    refute next.dispatch_ticket.dispatch_id == old.dispatch_ticket.dispatch_id
    before = runtime(owner)
    send(owner, {:agent_execution_stale, old.agent_execution.context, ids(old), :old})
    send(owner, {:agent_execution_usage, old_invocation, old.agent_execution.expected, {:ok, :invocation_absolute, counters(999)}})
    send(owner, old_down)
    assert runtime(owner) == before
    assert {:ok, _} = in_worker(next_pid, &AgentExecution.ensure_current/0)
  end

  def fault(_event, _measurements, metadata, {observer, c, kind}) do
    if metadata[:issue_id] == c.issue.id do
      case {kind, metadata[:event_type]} do
        {:policy_write, "stage.transition.requested"} ->
          path = RunStateStore.state_path(c.workspace)
          File.rename!(path, path <> ".before-fault")
          File.mkdir!(path)
          send(observer, {:fault_applied, kind})

        {:finish_cleanup, "dispatch.finished"} ->
          File.write!(Path.join(DispatchAudit.marker_directory(c.workspace), "retained-evidence"), "finish cleanup fault")
          send(observer, {:fault_applied, kind})

        {:after_usage, _} ->
          {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "operator-after-usage"))
          send(observer, {:fault_applied, kind})

        _ ->
          :ok
      end
    end
  end

  defp attach_fault(c, kind) do
    name = "i2b-owner-fault-#{System.unique_integer([:positive])}"
    event = if kind == :after_usage, do: [:symphony, :tokens, :turn], else: [:symphony, :ledger, :event]
    assert :ok = :telemetry.attach(name, event, &__MODULE__.fault/4, {self(), c, kind})
    on_exit(fn -> :telemetry.detach(name) end)
  end

  defp configure!(root, total) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner-install"),
      observability_tracing_enabled: false,
      policy_token_budget: %{
        per_turn_input: 1_000_000,
        per_issue_total: total,
        per_issue_total_output: 500_000,
        stages: %{implement: %{per_turn_input_soft: 800_000, per_turn_input_hard: 1_000_000}},
        broad_implement: %{enabled: false}
      }
    )

    assert :ok = WorkflowStore.force_reload()
  end

  defp start_driver do
    {:ok, owner} = Driver.start_link(self())

    on_exit(fn ->
      if Process.alive?(owner) do
        Enum.each(runtime(owner).running, fn {_id, entry} -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid) end)
        GenServer.stop(owner)
      end
    end)

    owner
  end

  defp start_worker(c) do
    owner = start_driver()
    entry = GenServer.call(owner, {:dispatch, c.issue, :controlled}, 10_000)
    assert is_map(entry)
    worker = entry.pid
    assert_receive {:worker_ready, ^worker, context}, 5_000
    assert context == entry.agent_execution.context
    {owner, worker, entry}
  end

  defp in_worker(worker, fun) do
    ref = make_ref()
    send(worker, {:exercise, self(), ref, fun})

    receive do
      {:exercise_result, ^ref, {:fixture_exception, exception, stack}} -> reraise exception, stack
      {:exercise_result, ^ref, {:fixture_caught, kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
      {:exercise_result, ^ref, result} -> result
    after
      10_000 -> flunk("worker fixture did not return")
    end
  end

  defp invocation(worker) do
    in_worker(worker, fn ->
      {:ok, binding} = AgentExecution.register_session(Claude, %{session_id: "owner-session"}, :main)
      {:ok, invocation} = AgentExecution.begin_invocation(binding)
      invocation
    end)
  end

  defp assert_hold(c, stopped, entry, kind) do
    refute Map.has_key?(stopped.running, c.issue.id)
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    refute Map.has_key?(stopped.completed, c.issue.id)
    assert stopped.lease_claims[c.issue.id].token == entry.lease_token
    assert {:ok, _lease} = LeaseManager.read(c.issue.id)
    if kind == :stale, do: assert(Map.has_key?(stopped.stale_execution_errors, c.issue.id)), else: assert(Map.has_key?(stopped.token_usage_errors, c.issue.id))
  end

  defp runtime(owner), do: GenServer.call(owner, :runtime)
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp marker!(c), do: File.read!(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json"))
  defp counters(total), do: %{input_tokens: total, output_tokens: 0, total_tokens: total}
  defp ids(entry), do: %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
  defp finish_events(c), do: Enum.filter(RunLedger.recent_entries(), &(&1["issue_id"] == c.issue.id and &1["event_type"] == "dispatch.finished"))

  defp evidence(c, entry),
    do: %{
      snapshot: File.read!(RunStateStore.state_path(c.workspace)),
      marker: marker!(c),
      lease: File.read!(entry.lease_token.storage.lease_path),
      ledger: File.read!(entry.lease_token.storage.ledger_path)
    }
end
