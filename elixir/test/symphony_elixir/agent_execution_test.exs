defmodule SymphonyElixir.AgentExecutionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, LogFile, RunStateStore}
  alias SymphonyElixir.AgentProvider.{Claude, Codex, CodexCLI}

  defmodule Owner do
    use GenServer

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    @impl true
    def init(observer), do: {:ok, %{observer: observer, registry: AgentExecution.new_registry(), reply: :ok}}
    @impl true
    def handle_call({:reply, reply}, _from, state), do: {:reply, :ok, %{state | reply: reply}}
    def handle_call(:registry, _from, state), do: {:reply, state.registry, state}

    def handle_call({:agent_execution, context, action}, {caller, _tag}, state) do
      send(state.observer, {:owner_call, caller, context, action})

      if caller == context.worker and context.owner == self() do
        case {state.reply, action} do
          {:hold, _} ->
            {:noreply, state}

          {:ok, {:register, binding, purpose}} ->
            {:ok, registry} = AgentExecution.register_binding(state.registry, binding, purpose)
            {:reply, :ok, %{state | registry: registry}}

          {:ok, {:begin, binding, ordinal}} ->
            {:ok, registry} = AgentExecution.begin_binding(state.registry, binding, ordinal)
            {:reply, :ok, %{state | registry: registry}}

          {:ok, {:retire, binding, _ordinal}} ->
            {:ok, registry} = AgentExecution.retire_binding(state.registry, binding)
            {:reply, :ok, %{state | registry: registry}}

          {reply, _} ->
            {:reply, reply, state}
        end
      else
        {:reply, {:stop, {:accounting_uncertain, :sender_mismatch}}, state}
      end
    end

    @impl true
    def handle_info({:agent_execution_usage, invocation, observation}, state) do
      {:ok, registry, delta} = AgentExecution.apply_usage(state.registry, invocation.binding, invocation.ordinal, observation)
      send(state.observer, {:usage_before_confirmation, invocation, delta})
      {:noreply, %{state | registry: registry}}
    end

    def handle_info(message, state) do
      send(state.observer, {:owner_message, message})
      {:noreply, state}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "agent-execution-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root, observability_tracing_enabled: false)
    issue = %Issue{id: "usage-#{System.unique_integer([:positive])}", identifier: "USAGE-1", state: "In Progress", source: :tracker, labels: []}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, issue: issue, workspace: workspace}
  end

  test "missing usage is different from explicit zero, null and partial dimensions" do
    assert :no_usage = AgentExecution.classify_usage(:claude_cli, %{"type" => "assistant", "message" => %{"content" => []}})
    assert :no_usage = AgentExecution.classify_usage(:app_server, %{params: %{msg: "ordinary notification", total: 7}})
    assert {:ok, :invocation_absolute, %{input_tokens: 0, output_tokens: 0, total_tokens: 0}} = AgentExecution.classify_usage(:claude_cli, %{"usage" => %{"input_tokens" => 0, "output_tokens" => 0}})

    for value <- [
          nil,
          [],
          %{},
          %{input_tokens: 1},
          %{input_tokens: nil, output_tokens: 2},
          %{input_tokens: "1", output_tokens: 2},
          %{input_tokens: 1.0, output_tokens: 2},
          %{input_tokens: -1, output_tokens: 2}
        ] do
      assert {:error, {:accounting_uncertain, _}} = AgentExecution.classify_usage(:claude_cli, %{usage: value})
    end
  end

  test "CLI raw message and terminal usage are invocation absolute without silently coercing aliases" do
    assert AgentExecution.classify_usage(:claude_cli, %{message: %{usage: %{input_tokens: 150, output_tokens: 0}}}) == {:ok, :invocation_absolute, counters(150)}
    assert AgentExecution.classify_usage(:codex_cli, %{"type" => "turn.completed", "usage" => %{"input_tokens" => 35, "output_tokens" => 0}}) == {:ok, :invocation_absolute, counters(35)}
    assert {:error, {:accounting_uncertain, _}} = AgentExecution.classify_usage(:codex_cli, %{usage: %{"input_tokens" => 4, input_tokens: 3, output_tokens: 0}})
    assert {:error, {:accounting_uncertain, _}} = AgentExecution.classify_usage(:codex_cli, %{usage: %{input_tokens: 3, prompt_tokens: 4, output_tokens: 0}})
  end

  test "AppServer explicit thread totals dominate last while unknown scope remains uncertain" do
    expected = counters(100)

    payloads = [
      %{params: %{msg: %{payload: %{info: %{total_token_usage: expected, last_token_usage: %{broken: true}}}}}},
      %{"params" => %{"msg" => %{"info" => %{"total_token_usage" => %{"input_tokens" => 100, "output_tokens" => 0, "total_tokens" => 100}}}}},
      %{params: %{tokenUsage: %{total: %{inputTokens: 100, outputTokens: 0, totalTokens: 100}}}},
      %{"tokenUsage" => %{"total" => %{"inputTokens" => 100, "outputTokens" => 0, "totalTokens" => 100}}}
    ]

    for payload <- payloads, do: assert({:ok, :thread_absolute, ^expected} = AgentExecution.classify_usage(:app_server, payload))
    assert {:ok, :invocation_absolute, ^expected} = AgentExecution.classify_usage(:app_server, %{method: "turn/completed", params: %{usage: expected}})

    for payload <- [%{last_token_usage: expected}, %{usage: expected}, %{params: %{usage: expected}}, %{tokenUsage: %{total: nil, last: expected}}] do
      assert {:error, {:accounting_uncertain, _}} = AgentExecution.classify_usage(:app_server, payload)
    end
  end

  test "CLI same handle counts 100 then 20 20 35 as 100 120 120 135" do
    binding = {Claude, :session, "cli-A"}
    {:ok, registry} = AgentExecution.register_binding(AgentExecution.new_registry(), binding, :main)
    {:ok, registry} = AgentExecution.begin_binding(registry, binding, 1)
    {:ok, registry, delta} = AgentExecution.apply_usage(registry, binding, 1, {:ok, :invocation_absolute, counters(100)})
    assert delta == counters(100)
    {:ok, registry} = AgentExecution.begin_binding(registry, binding, 2)

    {registry, totals} =
      Enum.reduce([20, 20, 35], {registry, []}, fn value, {acc, totals} ->
        {:ok, next, _delta} = AgentExecution.apply_usage(acc, binding, 2, {:ok, :invocation_absolute, counters(value)})
        {next, totals ++ [500 + AgentExecution.total_usage(next).total_tokens]}
      end)

    assert totals == [620, 620, 635]
    assert AgentExecution.total_usage(registry) == counters(135)
    {:ok, repeated, zero} = AgentExecution.apply_usage(registry, binding, 2, {:ok, :invocation_absolute, counters(35)})
    assert repeated == registry
    assert zero == counters(0)
  end

  test "thread maximum never falls and A verifier B A retains both contributions" do
    a = {Codex, :thread, "thread-A"}
    b = {Codex, :thread, "thread-B"}
    {:ok, registry} = AgentExecution.register_binding(AgentExecution.new_registry(), a, :main)
    {:ok, registry} = AgentExecution.begin_binding(registry, a, 1)
    {:ok, registry, _} = AgentExecution.apply_usage(registry, a, 1, {:ok, :thread_absolute, counters(100)})
    {:ok, registry} = AgentExecution.register_binding(registry, b, :verifier)
    {:ok, registry} = AgentExecution.begin_binding(registry, b, 2)
    {:ok, registry, _} = AgentExecution.apply_usage(registry, b, 2, {:ok, :thread_absolute, counters(20)})
    {:ok, registry} = AgentExecution.retire_binding(registry, b)
    {:ok, registry} = AgentExecution.begin_binding(registry, a, 3)
    {:ok, registry, _} = AgentExecution.apply_usage(registry, a, 3, {:ok, :thread_absolute, counters(110)})
    assert AgentExecution.total_usage(registry) == counters(130)
    assert {:error, :obsolete_invocation} = AgentExecution.apply_usage(registry, b, 2, {:ok, :thread_absolute, counters(30)})

    for lower <- [20, 20, 35] do
      assert {:ok, ^registry, zero} = AgentExecution.apply_usage(registry, a, 3, {:ok, :thread_absolute, counters(lower)})
      assert zero == counters(0)
    end

    assert {:error, :binding_identity_reused} = AgentExecution.register_binding(registry, b, :verifier)
  end

  test "mixed scopes use max S T C plus U for each dimension" do
    binding = {Codex, :thread, "mixed"}
    {:ok, registry} = AgentExecution.register_binding(AgentExecution.new_registry(), binding, :main)
    {:ok, registry} = AgentExecution.begin_binding(registry, binding, 1)
    {:ok, registry, _} = AgentExecution.apply_usage(registry, binding, 1, {:ok, :thread_absolute, counters(100)})
    {:ok, registry} = AgentExecution.begin_binding(registry, binding, 2)
    {:ok, registry, delta} = AgentExecution.apply_usage(registry, binding, 2, {:ok, :invocation_absolute, counters(20)})
    assert delta == counters(20)
    {:ok, registry, delta} = AgentExecution.apply_usage(registry, binding, 2, {:ok, :thread_absolute, counters(115)})
    assert delta == counters(0)
    assert AgentExecution.total_usage(registry) == counters(120)
    {:ok, registry, delta} = AgentExecution.apply_usage(registry, binding, 2, {:ok, :thread_absolute, counters(135)})
    assert delta == counters(15)
    assert AgentExecution.total_usage(registry) == counters(135)
  end

  test "two live bindings and 64 lifetime bindings are hard limits without tombstone eviction" do
    a = {Claude, :session, "A"}
    b = {CodexCLI, :session, "B"}
    {:ok, registry} = AgentExecution.register_binding(AgentExecution.new_registry(), a, :main)
    {:ok, full} = AgentExecution.register_binding(registry, b, :verifier)
    assert {:error, :live_binding_limit} = AgentExecution.session_capacity(full)

    registry =
      Enum.reduce(1..64, AgentExecution.new_registry(), fn i, acc ->
        binding = {Claude, :session, "retired-#{i}"}
        {:ok, acc} = AgentExecution.register_binding(acc, binding, :main)
        {:ok, acc} = AgentExecution.retire_binding(acc, binding)
        acc
      end)

    assert map_size(registry.live) == 0
    assert map_size(registry.retired) == 64
    assert {:error, :dispatch_binding_limit} = AgentExecution.session_capacity(registry)
    assert {:error, :dispatch_binding_limit} = AgentExecution.register_binding(registry, {Claude, :session, "65"}, :main)
    assert AgentExecution.total_usage(registry) == counters(0)
  end

  test "registry uncertainty is sticky and rejects subsequent valid usage" do
    binding = {Claude, :session, "A"}
    {:ok, registry} = AgentExecution.register_binding(AgentExecution.new_registry(), binding, :main)
    {:ok, registry} = AgentExecution.begin_binding(registry, binding, 1)
    uncertain = registry |> AgentExecution.mark_uncertain(:checkpoint_failed) |> AgentExecution.mark_uncertain(:later_error)
    assert uncertain.uncertain == :checkpoint_failed
    assert {:error, {:accounting_uncertain, :checkpoint_failed}} = AgentExecution.apply_usage(uncertain, binding, 1, {:ok, :invocation_absolute, counters(100)})
    assert AgentExecution.total_usage(uncertain) == counters(0)
  end

  test "scoped authorization exposes the validated ticket and restores it after an exception", c do
    {ticket, token} = admission!(c)
    assert {:error, :dispatch_context_missing} = DispatchAudit.current_ticket()
    owner = start_supervised!({Owner, self()})

    DispatchAudit.with_authorization(ticket, fn ->
      assert {:ok, ^ticket} = DispatchAudit.current_ticket()

      assert_raise RuntimeError, "controlled", fn ->
        AgentExecution.with_context(ticket, token, owner, fn ->
          assert {:ok, context} = AgentExecution.current_context()
          assert context.ticket == ticket
          assert context.lease_token == token
          assert context.owner == owner
          assert context.worker == self()
          raise "controlled"
        end)
      end

      assert {:error, :execution_context_missing} = AgentExecution.current_context()
      assert {:ok, ^ticket} = DispatchAudit.current_ticket()
    end)

    assert {:error, :dispatch_context_missing} = DispatchAudit.current_ticket()
  end

  test "usage reaches the owner before confirmation and foreign PID or retired callback has no effects", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    DispatchAudit.with_authorization(ticket, fn ->
      AgentExecution.with_context(ticket, token, owner, fn ->
        assert :ok = AgentExecution.ensure_session_capacity()
        assert {:ok, session} = Claude.start_session(c.workspace)
        assert {:ok, binding} = AgentExecution.register_session(Claude, session, :main)
        assert {:ok, invocation} = AgentExecution.begin_invocation(binding)
        assert :ok = AgentExecution.observe_usage(invocation, %{usage: counters(100)})
        assert_receive {:usage_before_confirmation, ^invocation, delta}
        assert delta == counters(100)
        assert AgentExecution.total_usage(GenServer.call(owner, :registry)) == counters(100)
        parent = self()
        {foreign, monitor} = spawn_monitor(fn -> send(parent, {:foreign_guard, AgentExecution.observe_usage(invocation, %{usage: counters(200)})}) end)
        assert_receive {:foreign_guard, {:discard, :foreign_worker}}
        assert_receive {:DOWN, ^monitor, :process, ^foreign, :normal}
        refute_received {:usage_before_confirmation, ^invocation, _}
        assert :ok = AgentExecution.retire_session(binding)
        assert {:discard, :obsolete_invocation} = AgentExecution.forward_update(invocation, %{event: :turn_completed, timestamp: DateTime.utc_now()})
        refute_received {:owner_message, {:agent_worker_update, _, _}}
        assert AgentExecution.total_usage(GenServer.call(owner, :registry)) == counters(100)
      end)
    end)
  end

  test "a caught raw-usage failure keeps the first terminal and emits no second diagnostic", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    result =
      DispatchAudit.with_authorization(ticket, fn ->
        AgentExecution.with_context(ticket, token, owner, fn ->
          {:ok, session} = Claude.start_session(c.workspace)
          {:ok, binding} = AgentExecution.register_session(Claude, session, :main)
          {:ok, invocation} = AgentExecution.begin_invocation(binding)
          assert {:stop, {:accounting_uncertain, :missing_usage_dimension}} = AgentExecution.observe_usage(invocation, %{usage: %{input_tokens: 1}})
          assert {:stop, {:accounting_uncertain, :missing_usage_dimension}} = AgentExecution.observe_usage(invocation, %{usage: counters(10)})
          assert {:stop, {:accounting_uncertain, :missing_usage_dimension}} = AgentExecution.fail(:later_error)
          {:ok, :provider_ignored_callback_result}
        end)
      end)

    assert result == {:stop, {:accounting_uncertain, :missing_usage_dimension}}
    assert_receive {:owner_message, {:agent_execution_uncertain, _, :missing_usage_dimension}}
    refute_receive {:owner_message, {:agent_execution_uncertain, _, _}}, 30
    assert AgentExecution.total_usage(GenServer.call(owner, :registry)) == counters(0)
  end

  test "invalid owner confirmation and owner death do not grant a new session", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})
    assert :ok = GenServer.call(owner, {:reply, :unexpected})
    assert {:stop, {:accounting_uncertain, :invalid_owner_confirmation}} = scoped(c, ticket, token, owner, &AgentExecution.ensure_session_capacity/0)
    assert :ok = GenServer.stop(owner)
    assert {:stop, {:accounting_uncertain, :owner_unavailable}} = scoped(c, ticket, token, owner, &AgentExecution.ensure_session_capacity/0)
  end

  @tag timeout: 10_000
  test "confirmation has one real five-second timeout and no retry", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})
    assert :ok = GenServer.call(owner, {:reply, :hold})
    started = System.monotonic_time(:millisecond)
    assert {:stop, {:accounting_uncertain, :owner_confirmation_timeout}} = scoped(c, ticket, token, owner, &AgentExecution.ensure_session_capacity/0)
    assert System.monotonic_time(:millisecond) - started >= 5_000
    assert_receive {:owner_call, _, _, {:confirm, nil, 0}}
    refute_received {:owner_call, _, _, _}
  end

  test "audited checkpoints preserve actual maxima and reject legacy writes", c do
    {ticket, token} = admission!(c)
    context = %{ticket: ticket, lease_token: token}

    for {input, persisted} <- [{100, 100}, {20, 100}, {135, 135}] do
      assert {:ok, state} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(input), context)
      assert state.token_usage == counters(persisted)
      assert state.run_id == ticket.run_id
      assert {:ok, ^state} = RunStateStore.load(c.workspace)
    end

    bytes = File.read!(RunStateStore.state_path(c.workspace))
    assert {:error, :token_usage_context_required} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(200))
    assert File.read!(RunStateStore.state_path(c.workspace)) == bytes
  end

  test "partial or null identity cannot enter the legacy checkpoint and valid legacy remains supported", c do
    assert {:ok, _} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(7))
    path = RunStateStore.state_path(c.workspace)
    legacy = path |> File.read!() |> Jason.decode!()

    for key <- ["run_id", "run_identity_event_id", "run_identity_ledger_path", "run_identity_pending"], value <- [nil, "partial"] do
      bytes = Jason.encode!(Map.put(legacy, key, value))
      File.write!(path, bytes)
      assert {:error, :token_usage_context_required} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(10))
      assert File.read!(path) == bytes
    end
  end

  test "invalid input or persisted counters leave the audited snapshot unchanged", c do
    {ticket, token} = admission!(c)
    context = %{ticket: ticket, lease_token: token}
    path = RunStateStore.state_path(c.workspace)
    original = File.read!(path)

    for bad <- [%{input_tokens: 1}, Map.put(counters(1), :extra, 1), Map.put(counters(1), :input_tokens, "1"), Map.put(counters(1), :output_tokens, -1), Map.put(counters(1), :total_tokens, 1.5)] do
      assert {:error, :invalid_token_usage} = RunStateStore.record_token_usage(c.workspace, c.issue, bad, context)
      assert File.read!(path) == original
    end

    broken = original |> Jason.decode!() |> Map.put("token_usage", %{"input_tokens" => "bad", "output_tokens" => 0, "total_tokens" => 0}) |> Jason.encode!()
    File.write!(path, broken)
    assert {:error, :invalid_token_usage} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(20), context)
    assert File.read!(path) == broken
  end

  test "checkpoint rejects wrong ticket, run and issue without touching admission evidence", c do
    {ticket, token} = admission!(c)
    path = RunStateStore.state_path(c.workspace)
    snapshot = File.read!(path)
    marker = Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json")
    marker_bytes = File.read!(marker)
    ledger_bytes = File.read!(ticket.ledger_path)

    for key <- [:workspace, :dispatch_id, :run_id, :entry_event_id, :owner, :ledger_path] do
      wrong = Map.update!(ticket, key, &(&1 <> "-wrong"))
      assert {:error, _} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(1), %{ticket: wrong, lease_token: token})
      assert File.read!(path) == snapshot
      assert File.read!(marker) == marker_bytes
      assert File.read!(ticket.ledger_path) == ledger_bytes
    end

    assert {:error, :token_usage_snapshot_mismatch} = RunStateStore.record_token_usage(c.workspace, %{c.issue | identifier: "OTHER"}, counters(1), %{ticket: ticket, lease_token: token})
    assert File.read!(path) == snapshot
  end

  test "same-owner same-epoch successor rejects the captured token without altering either journal", c do
    {ticket, token} = admission!(c)
    assert :ok = LeaseManager.ensure_current(token)
    before = File.read!(token.storage.lease_path)
    assert :ok = LeaseManager.ensure_current(token)
    assert File.read!(token.storage.lease_path) == before
    assert {:ok, :released} = LeaseManager.release_token(token)
    assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, token.owner, storage: token.storage)
    assert successor.token.epoch == token.epoch
    refute successor.token.lease_generation == token.lease_generation
    bytes = File.read!(token.storage.lease_path)
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    assert {:error, :lease_token_mismatch} = LeaseManager.ensure_current(token)
    assert {:error, :lease_token_mismatch} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(10), %{ticket: ticket, lease_token: token})
    assert File.read!(token.storage.lease_path) == bytes
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
  end

  test "expired pending corrupt and missing leases fail without renewal", c do
    {_ticket, token} = admission!(c)
    path = token.storage.lease_path
    original = path |> File.read!() |> Jason.decode!()
    expired = Map.put(original, "updated_at", DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601())

    for {lease, reason} <- [{expired, :lease_expired}, {Map.put(original, "audit_pending", %{}), :invalid_lease_audit_pending}] do
      bytes = Jason.encode!(lease)
      File.write!(path, bytes)
      assert {:error, ^reason} = LeaseManager.ensure_current(token)
      assert File.read!(path) == bytes
    end

    File.write!(path, "broken")
    assert {:error, _} = LeaseManager.ensure_current(token)
    assert File.read!(path) == "broken"
    File.rm!(path)
    assert {:error, :missing} = LeaseManager.ensure_current(token)
  end

  test "provider identity kind is fixed and unsupported or invalid handles are rejected" do
    registry = AgentExecution.new_registry()

    for binding <- [{Codex, :session, "A"}, {Claude, :thread, "A"}, {CodexCLI, :thread, "A"}, {Claude, :session, ""}] do
      assert {:error, :invalid_session_binding} = AgentExecution.register_binding(registry, binding, :main)
    end

    assert {:error, :unsupported_accounting_provider} = AgentExecution.register_binding(registry, {__MODULE__, :session, "A"}, :main)
  end

  test "nil uncertainty is terminal in registry worker and owner response", c do
    registry = AgentExecution.mark_uncertain(AgentExecution.new_registry(), nil)
    assert registry.uncertain == :invalid_uncertainty_cause
    assert {:error, {:accounting_uncertain, :invalid_uncertainty_cause}} = AgentExecution.session_capacity(registry)
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    assert {:stop, {:accounting_uncertain, :invalid_uncertainty_cause}} =
             scoped(c, ticket, token, owner, fn ->
               assert {:stop, {:accounting_uncertain, :invalid_uncertainty_cause}} = AgentExecution.fail(nil)
               :provider_continued
             end)

    assert :ok = GenServer.call(owner, {:reply, {:error, nil}})

    assert {:stop, {:accounting_uncertain, :invalid_uncertainty_cause}} =
             scoped(c, ticket, token, owner, fn ->
               assert {:stop, {:accounting_uncertain, :invalid_uncertainty_cause}} = AgentExecution.ensure_session_capacity()
               :provider_continued
             end)
  end

  test "CLI external raw session id cannot replace the canonical handle identity", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    assert {:stop, {:accounting_uncertain, :session_identity_mismatch}} =
             scoped(c, ticket, token, owner, fn ->
               {:ok, session} = Claude.start_session(c.workspace)
               {:ok, binding} = AgentExecution.register_session(Claude, session, :main)
               {:ok, invocation} = AgentExecution.begin_invocation(binding)
               assert :ok = AgentExecution.observe_usage(invocation, %{session_id: "external-process-id", usage: counters(10)})
               assert AgentExecution.total_usage(GenServer.call(owner, :registry)) == counters(10)
               assert :ok = AgentExecution.confirm_invocation(invocation, %{session_id: session.session_id})
               assert {:stop, {:accounting_uncertain, :session_identity_mismatch}} = AgentExecution.forward_update(invocation, %{session_id: "forged-runtime-id", usage: counters(20)})
               refute_received {:owner_message, {:agent_worker_update, _, _}}
               :provider_continued
             end)

    assert AgentExecution.total_usage(GenServer.call(owner, :registry)) == counters(10)
  end

  test "AppServer explicit foreign thread is rejected before usage or update reaches owner", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    assert {:stop, {:accounting_uncertain, :session_identity_mismatch}} =
             scoped(c, ticket, token, owner, fn ->
               {:ok, binding} = AgentExecution.register_session(Codex, %{thread_id: "A"}, :main)
               {:ok, invocation} = AgentExecution.begin_invocation(binding)
               assert :ok = AgentExecution.observe_usage(invocation, %{params: %{threadId: "A", tokenUsage: %{total: counters(10)}}})
               assert :ok = AgentExecution.confirm_invocation(invocation, %{thread_id: "A", session_id: "A-turn-1"})
               assert_receive {:usage_before_confirmation, ^invocation, _}
               assert {:stop, {:accounting_uncertain, :session_identity_mismatch}} = AgentExecution.observe_usage(invocation, %{thread_id: "B", tokenUsage: %{total: counters(100)}})
               refute_received {:usage_before_confirmation, ^invocation, _}
               assert {:stop, {:accounting_uncertain, :session_identity_mismatch}} = AgentExecution.forward_update(invocation, %{thread_id: "A"})
               refute_received {:owner_message, {:agent_worker_update, _, _}}
             end)

    assert AgentExecution.total_usage(GenServer.call(owner, :registry)) == counters(10)
  end

  test "a canonical result with a foreign identity is rejected without forwarding it", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    assert {:stop, {:accounting_uncertain, :session_identity_mismatch}} =
             scoped(c, ticket, token, owner, fn ->
               {:ok, session} = CodexCLI.start_session(c.workspace)
               {:ok, binding} = AgentExecution.register_session(CodexCLI, session, :main)
               {:ok, invocation} = AgentExecution.begin_invocation(binding)
               assert {:stop, {:accounting_uncertain, :session_identity_mismatch}} = AgentExecution.confirm_invocation(invocation, %{session_id: "forged", usage: counters(10)})
               refute_received {:usage_before_confirmation, _, _}
               refute_received {:owner_message, {:agent_worker_update, _, _}}
             end)
  end

  test "audited checkpoint does not create or adopt missing partial or pending snapshots", c do
    {ticket, token} = admission!(c)
    context = %{ticket: ticket, lease_token: token}
    path = RunStateStore.state_path(c.workspace)
    original = File.read!(path)
    decoded = Jason.decode!(original)

    cases = [
      {Map.put(decoded, "run_identity_pending", nil), :run_identity_pending},
      {Map.delete(decoded, "run_identity_event_id"), :invalid_run_identity},
      {Map.put(decoded, "run_id", "other-run"), :token_usage_snapshot_mismatch},
      {Map.put(decoded, "audit_pending", %{operation_id: "pending"}), {:audit_pending, "pending"}}
    ]

    for {snapshot, reason} <- cases do
      bytes = Jason.encode!(snapshot)
      File.write!(path, bytes)
      assert {:error, ^reason} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(1), context)
      assert File.read!(path) == bytes
    end

    File.write!(path, "corrupt")
    assert {:error, %Jason.DecodeError{}} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(1), context)
    assert File.read!(path) == "corrupt"
    staging = Path.join(Path.dirname(c.workspace), ".#{Path.basename(c.workspace)}.bootstrap-fixture")
    File.mkdir_p!(staging)
    staged_path = Path.join(staging, "run_state.json")
    File.write!(staged_path, original)
    File.rm!(path)
    assert {:error, :missing} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(1), context)
    refute File.exists?(path)
    assert File.read!(staged_path) == original
    assert {:error, :token_usage_context_required} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(1))
    refute File.exists?(path)
    assert File.read!(staged_path) == original
  end

  test "captured lease path is stable and changed ledger configuration rejects checkpoint", c do
    {ticket, token} = admission!(c)
    snapshot_path = RunStateStore.state_path(c.workspace)
    snapshot = File.read!(snapshot_path)
    lease = File.read!(token.storage.lease_path)
    ledger = File.read!(ticket.ledger_path)
    original_log = Application.fetch_env!(:symphony_elixir, :log_file)
    relocated = Path.join(c.root, "relocated-logs")
    File.mkdir_p!(relocated)
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(relocated))

    try do
      assert :ok = LeaseManager.ensure_current(token)
      assert {:error, :dispatch_audit_ledger_changed} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(10), %{ticket: ticket, lease_token: token})
      assert File.read!(snapshot_path) == snapshot
      assert File.read!(token.storage.lease_path) == lease
      assert File.read!(ticket.ledger_path) == ledger
      assert File.ls!(relocated) == []
    after
      Application.put_env(:symphony_elixir, :log_file, original_log)
    end
  end

  test "legacy checkpoint inspects identity after acquiring the snapshot mutation lock", c do
    assert {:ok, _} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(7))
    path = RunStateStore.state_path(c.workspace)
    snapshot = path |> File.read!() |> Jason.decode!() |> Map.put("run_id", "partial") |> Jason.encode!()
    parent = self()

    holder =
      Task.async(fn ->
        RunStateStore.with_workspace_lock(c.workspace, fn ->
          send(parent, :snapshot_lock_held)

          receive do
            :publish_identity -> File.write!(path, snapshot)
          end
        end)
      end)

    assert_receive :snapshot_lock_held
    lock = {{RunStateStore, Path.expand(c.workspace)}, self()}
    acquired = :global.set_lock(lock, [node()], 0)
    if acquired, do: :global.del_lock(lock, [node()])
    refute acquired

    contender =
      Task.async(fn ->
        send(parent, :checkpoint_entered)
        RunStateStore.record_token_usage(c.workspace, c.issue, counters(99))
      end)

    assert_receive :checkpoint_entered
    assert Task.yield(contender, 0) == nil
    send(holder.pid, :publish_identity)
    assert :ok = Task.await(holder)
    assert {:error, :token_usage_context_required} = Task.await(contender)
    assert File.read!(path) == snapshot
  end

  test "nested execution context preserves outer bindings and its first uncertainty", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    assert {:stop, {:accounting_uncertain, :execution_context_already_present}} =
             scoped(c, ticket, token, owner, fn ->
               {:ok, session} = Claude.start_session(c.workspace)
               {:ok, binding} = AgentExecution.register_session(Claude, session, :main)
               {:ok, invocation} = AgentExecution.begin_invocation(binding)
               {:ok, outer} = AgentExecution.current_context()
               assert {:stop, {:accounting_uncertain, :execution_context_already_present}} = AgentExecution.with_context(ticket, token, owner, fn -> flunk("nested context executed") end)
               assert {:ok, ^outer} = AgentExecution.current_context()
               assert {:stop, {:accounting_uncertain, :execution_context_already_present}} = AgentExecution.confirm_invocation(invocation)
               assert GenServer.call(owner, :registry).current == binding
               :provider_continued
             end)

    assert {:error, :execution_context_missing} = AgentExecution.current_context()

    assert {:stop, {:accounting_uncertain, :checkpoint_failed}} =
             scoped(c, ticket, token, owner, fn ->
               AgentExecution.fail(:checkpoint_failed)
               assert {:stop, {:accounting_uncertain, :checkpoint_failed}} = AgentExecution.with_context(ticket, token, owner, fn -> flunk("nested context executed after failure") end)
               :provider_continued
             end)
  end

  test "begin rejects a changed handle with the same ID or a different provider before advancing the owner", c do
    {ticket, token} = admission!(c)

    for mismatch <- [:handle, :provider] do
      owner = start_supervised!(Supervisor.child_spec({Owner, self()}, id: mismatch))

      assert {:stop, {:accounting_uncertain, :execution_handle_mismatch}} =
               scoped(c, ticket, token, owner, fn ->
                 {:ok, session} = Claude.start_session(c.workspace)
                 {:ok, binding} = AgentExecution.register_session(Claude, session, :main)
                 assert {:ok, invocation} = AgentExecution.begin_invocation(Claude, session, binding)
                 assert invocation.ordinal == 1
                 assert_receive {:owner_call, _, _, {:begin, ^binding, 1}}
                 before = GenServer.call(owner, :registry)

                 {provider, handle} =
                   case mismatch do
                     :handle -> {Claude, Map.put(session, :workspace, Path.join(c.workspace, "other"))}
                     :provider -> {CodexCLI, session}
                   end

                 assert handle.session_id == session.session_id
                 assert {:stop, {:accounting_uncertain, :execution_handle_mismatch}} = AgentExecution.begin_invocation(provider, handle, binding)
                 assert GenServer.call(owner, :registry) == before
                 assert before.ordinal == 1
                 refute_received {:owner_call, _, _, {:begin, _, _}}
                 assert {:stop, {:accounting_uncertain, :execution_handle_mismatch}} = AgentExecution.begin_invocation(Claude, session, binding)
                 assert GenServer.call(owner, :registry) == before
                 refute_received {:owner_call, _, _, {:begin, _, _}}
                 :provider_continued
               end)
    end
  end

  test "exact handles preserve scoped A verifier B A and confirm the current ordinal before and after retirement", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    assert :ok =
             scoped(c, ticket, token, owner, fn ->
               assert {:ok, context} = AgentExecution.entry_context(c.workspace, c.issue)
               assert_receive {:owner_call, _, ^context, {:confirm, nil, 0}}
               assert :ok = AgentExecution.confirm_current_invocation()
               assert_receive {:owner_call, _, ^context, {:confirm, nil, 0}}
               a = %{thread_id: "thread-A", workspace: c.workspace}
               b = %{thread_id: "thread-B", workspace: c.workspace}
               {:ok, binding_a} = AgentExecution.register_session(Codex, a, :main)
               assert {:ok, first} = AgentExecution.begin_invocation(Codex, a, binding_a)
               assert first.ordinal == 1
               assert :ok = AgentExecution.observe_usage(first, %{params: %{threadId: a.thread_id, tokenUsage: %{total: counters(100)}}})
               {:ok, binding_b} = AgentExecution.register_session(Codex, b, :verifier)
               assert {:ok, verifier} = AgentExecution.begin_invocation(Codex, b, binding_b)
               assert verifier.ordinal == 2
               assert :ok = AgentExecution.observe_usage(verifier, %{params: %{threadId: b.thread_id, tokenUsage: %{total: counters(20)}}})
               assert :ok = AgentExecution.retire_session(binding_b)
               assert :ok = AgentExecution.confirm_current_invocation()
               assert_receive {:owner_call, _, ^context, {:confirm, nil, 2}}
               assert {:ok, resumed} = AgentExecution.begin_invocation(Codex, a, binding_a)
               assert resumed.ordinal == 3
               assert :ok = AgentExecution.observe_usage(resumed, %{params: %{threadId: a.thread_id, tokenUsage: %{total: counters(110)}}})
               assert_receive {:owner_call, _, ^context, {:confirm, ^binding_a, 3}}
               assert :ok = AgentExecution.confirm_current_invocation()
               assert_receive {:owner_call, _, ^context, {:confirm, ^binding_a, 3}}
               assert {:ok, ^context} = AgentExecution.entry_context(c.workspace, nil)
               registry = GenServer.call(owner, :registry)
               assert registry.ordinal == 3
               assert registry.current == binding_a
               assert Map.has_key?(registry.retired, binding_b)
               assert AgentExecution.total_usage(registry) == counters(130)
               assert {:discard, :obsolete_invocation} = AgentExecution.confirm_invocation(verifier)
               assert :ok = AgentExecution.retire_session(binding_a)
             end)
  end

  test "entry guards allow direct legacy calls but require captured execution authority for identified snapshots", c do
    assert {:ok, :legacy} = AgentExecution.entry_context(c.workspace, nil)
    assert {:ok, _} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(7))
    assert {:ok, :legacy} = AgentExecution.entry_context(c.workspace, c.issue.identifier)
    assert {:stop, {:accounting_uncertain, :execution_context_missing}} = AgentExecution.confirm_current_invocation()
    {ticket, _token} = admission!(c)
    path = RunStateStore.state_path(c.workspace)
    bytes = File.read!(path)
    assert {:stop, {:accounting_uncertain, :execution_context_missing}} = AgentExecution.entry_context(c.workspace, c.issue)
    assert {:stop, {:accounting_uncertain, :execution_context_missing}} = AgentExecution.entry_context(c.workspace, nil)
    assert {:stop, {:accounting_uncertain, :execution_context_missing}} = DispatchAudit.with_authorization(ticket, fn -> AgentExecution.entry_context(c.workspace, c.issue) end)
    assert File.read!(path) == bytes
  end

  test "entry mismatch stays terminal and skips subsequent owner confirmation", c do
    {ticket, token} = admission!(c)
    owner = start_supervised!({Owner, self()})

    assert {:stop, {:accounting_uncertain, :execution_issue_mismatch}} =
             scoped(c, ticket, token, owner, fn ->
               assert {:stop, {:accounting_uncertain, :execution_issue_mismatch}} = AgentExecution.entry_context(c.workspace, %{c.issue | identifier: "OTHER"})
               assert {:stop, {:accounting_uncertain, :execution_issue_mismatch}} = AgentExecution.entry_context(c.workspace, c.issue)
               assert {:stop, {:accounting_uncertain, :execution_issue_mismatch}} = AgentExecution.confirm_current_invocation()
               assert GenServer.call(owner, :registry) == AgentExecution.new_registry()
               refute_received {:owner_call, _, _, _}
               :provider_continued
             end)
  end

  defp admission!(c) do
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "execution-owner")
    assert {:ok, ticket} = DispatchAudit.begin(c.workspace, %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}})
    {ticket, acquired.token}
  end

  defp scoped(_c, ticket, token, owner, fun), do: DispatchAudit.with_authorization(ticket, fn -> AgentExecution.with_context(ticket, token, owner, fun) end)
  defp counters(value), do: %{input_tokens: value, output_tokens: 0, total_tokens: value}
end
