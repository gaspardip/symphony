defmodule SymphonyElixir.AgentExecutionCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunStateStore}
  alias SymphonyElixir.AgentProvider.Claude

  # This fixture exercises the worker protocol against real storage. It is not
  # evidence for Orchestrator custody, monitor/DOWN or real-provider behavior.
  defmodule ControlledOwner do
    use GenServer
    alias SymphonyElixir.{AgentExecution, RunStateStore}

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      context = %{ticket: opts.ticket, lease_token: opts.token, owner: self(), worker: opts.worker, issue_id: opts.issue.id}

      {:ok,
       %{
         context: context,
         authority: %{ticket: opts.ticket, lease_token: opts.token},
         issue: opts.issue,
         expected: RunStateStore.material_projection(opts.raw),
         registry: AgentExecution.new_registry(),
         terminal: nil,
         known_terminal: nil,
         stop: nil,
         receipt: nil,
         calls: [],
         updates: [],
         usage: [],
         before_advance: nil,
         reply_override: nil
       }}
    end

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}
    def handle_call({:before_advance, fun}, _from, state), do: {:reply, :ok, %{state | before_advance: fun}}
    def handle_call({:reply_override, reply}, _from, state), do: {:reply, :ok, %{state | reply_override: reply}}
    def handle_call(:public_stop, _from, state), do: {:reply, :ok, %{state | stop: %{stage: state.expected["stage"]}}}

    def handle_call(:own_policy_stop, _from, state) do
      {:ok, persisted} = RunStateStore.transition_current(state.authority, state.expected, "blocked", %{stop_reason: %{code: "token_budget"}})
      next = RunStateStore.material_projection(persisted)
      receipt = %{previous: state.expected, next: next, binding: state.registry.current, ordinal: state.registry.ordinal, outcome: {:stop, :token_budget}}
      known = %{previous: state.expected, next: next, stage: "blocked"}
      {:reply, :ok, %{state | receipt: receipt, expected: next, stop: %{stage: "blocked"}, known_terminal: known}}
    end

    def handle_call({:agent_execution, invocation, expected, action}, {pid, _tag}, state) do
      true = pid == state.context.worker
      :ok = authenticate(state, invocation)
      state = %{state | calls: state.calls ++ [{expected, action}]}
      {reply, state} = action_reply(state, expected, action)
      if reply == :no_reply, do: {:noreply, state}, else: {:reply, reply, state}
    end

    defp action_reply(%{terminal: terminal} = state, _expected, _action) when not is_nil(terminal), do: {{:stop, terminal}, state}

    defp action_reply(%{stop: stop} = state, _expected, _action) when not is_nil(stop),
      do: {{:stop, {:execution_stopped, stop}}, state}

    defp action_reply(state, expected, action) do
      if expected == state.expected do
        {reply, state} = perform_action(state, action)

        case {action, state.reply_override} do
          {{kind, _previous, _next}, override} when kind in [:advance_current, :confirm_own_terminal] and not is_nil(override) ->
            {override, %{state | reply_override: nil}}

          _ ->
            {reply, state}
        end
      else
        terminal_reply(state, {:stale_execution, :owner_expected_changed})
      end
    end

    defp perform_action(state, {kind, previous, next}) when kind in [:advance_current, :confirm_own_terminal] do
      true = previous == state.expected
      if state.before_advance, do: state.before_advance.()
      state = %{state | before_advance: nil}
      result = if kind == :confirm_own_terminal, do: RunStateStore.confirm_terminal_current(state.authority, next), else: RunStateStore.ensure_current(state.authority, next)

      case result do
        :ok when kind == :confirm_own_terminal ->
          known = %{previous: previous, next: next, stage: next["stage"]}
          {{:ok, :terminal_confirmed}, %{state | expected: next, known_terminal: known}}

        {:ok, _persisted} ->
          {:ok, %{state | expected: next}}

        {:error, reason} ->
          terminal_reply(state, reason)
      end
    end

    defp perform_action(%{known_terminal: %{stage: "blocked", next: next}} = state, :confirm_stop_notification) do
      case RunStateStore.confirm_terminal_current(state.authority, next) do
        :ok -> {:ok, state}
        {:error, reason} -> terminal_reply(state, reason)
      end
    end

    defp perform_action(%{known_terminal: %{stage: stage}} = state, _action), do: {{:stop, {:execution_stopped, %{stage: stage}}}, state}

    defp perform_action(state, action) do
      with {:ok, _current} <- RunStateStore.ensure_current(state.authority, state.expected),
           {:ok, registry} <- registry_action(state.registry, action) do
        {:ok, %{state | registry: registry}}
      else
        {:error, reason} -> terminal_reply(state, reason)
      end
    end

    defp registry_action(registry, {:register, binding, purpose}), do: AgentExecution.register_binding(registry, binding, purpose)
    defp registry_action(registry, {:begin, binding, ordinal}), do: AgentExecution.begin_binding(registry, binding, ordinal)
    defp registry_action(registry, {:retire, binding, ordinal}) when ordinal == registry.ordinal, do: AgentExecution.retire_binding(registry, binding)
    defp registry_action(registry, {:confirm, binding, ordinal}) when binding == registry.current and ordinal == registry.ordinal, do: {:ok, registry}

    @impl true
    def handle_info({:agent_execution_usage, invocation, expected, observation}, state) do
      :ok = authenticate(state, invocation)
      {:ok, registry, _delta} = AgentExecution.apply_usage(state.registry, invocation.binding, invocation.ordinal, observation)
      usage = AgentExecution.total_usage(registry)

      result =
        if state.receipt do
          true = expected == state.receipt.previous
          true = state.expected == state.receipt.next
          RunStateStore.record_final_token_usage_current(state.context.ticket.workspace, state.issue, usage, state.authority, state.receipt)
        else
          true = expected == state.expected
          RunStateStore.record_token_usage_current(state.context.ticket.workspace, state.issue, usage, state.authority, expected)
        end

      case result do
        {:ok, _persisted} ->
          {:noreply, %{state | registry: registry, usage: state.usage ++ [{expected, observation}]}}

        {:error, reason} ->
          {_reply, state} = terminal_reply(state, reason)
          {:noreply, state}
      end
    end

    def handle_info({:agent_worker_update, invocation, expected, update}, state) do
      :ok = authenticate(state, invocation)
      true = expected == state.expected
      {:ok, _current} = RunStateStore.ensure_current(state.authority, expected)
      {:noreply, %{state | updates: state.updates ++ [{expected, update}]}}
    end

    def handle_info({:agent_execution_uncertain, context, cause}, state) do
      true = context == state.context
      {_reply, state} = terminal_reply(state, cause)
      {:noreply, state}
    end

    def handle_info({:agent_execution_stale, context, ids, cause}, state) do
      true = context == state.context
      true = ids == ids(state)
      {_reply, state} = terminal_reply(state, {:stale_execution, cause})
      {:noreply, state}
    end

    defp authenticate(state, %{context: context, binding: binding, ordinal: ordinal}) do
      true = context == state.context
      true = binding == state.registry.current and ordinal == state.registry.ordinal
      :ok
    end

    defp terminal_reply(%{terminal: terminal} = state, _reason) when not is_nil(terminal), do: {{:stop, terminal}, state}

    defp terminal_reply(state, {:stale_execution, cause}) do
      terminal = {:stale_execution, ids(state), cause}
      {{:stop, terminal}, %{state | terminal: terminal}}
    end

    defp terminal_reply(state, reason) do
      terminal = {:accounting_uncertain, reason}
      {{:stop, terminal}, %{state | terminal: terminal, registry: AgentExecution.mark_uncertain(state.registry, reason)}}
    end

    defp ids(state), do: %{run_id: state.context.ticket.run_id, dispatch_id: state.context.ticket.dispatch_id}
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "execution-current-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "CURRENT-1")
    issue = %{id: "execution-current-#{System.unique_integer([:positive])}", identifier: "CURRENT-1"}
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(RunStateStore.state_path(workspace), Jason.encode!(%{"issue_id" => issue.id, "issue_identifier" => issue.identifier, "stage" => "implement"}))
    if tags[:full_defaults], do: assert({:ok, _} = RunStateStore.update(workspace, & &1))
    if tags[:deploy], do: assert({:ok, _} = RunStateStore.transition(workspace, "deploy_preview", %{}))
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "execution-current-owner")
    assert {:ok, source, view} = RunStateStore.read_admission_source(workspace, issue)

    assert {:ok, ticket, raw} =
             DispatchAudit.begin(workspace, %{issue_id: issue.id, issue_identifier: issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}, source)

    owner = start_supervised!({ControlledOwner, %{ticket: ticket, token: acquired.token, worker: self(), raw: raw, issue: issue}})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, token: acquired.token, ticket: ticket, raw: raw, owner: owner}
  end

  test "compatibility arity never captures a later raw precondition", c do
    parent = self()

    assert {:stop, {:accounting_uncertain, :execution_precondition_missing}} =
             DispatchAudit.with_authorization(c.ticket, fn -> AgentExecution.with_context(c.ticket, c.token, c.owner, fn -> send(parent, :unexpected_body) end) end)

    refute_received :unexpected_body
    assert owner_state(c).calls == []
  end

  test "entry uses raw field presence and a control before entry prevents the body", c do
    refute Map.has_key?(c.raw, "policy_override")

    assert :unchanged =
             within(c, fn ->
               assert {:ok, current} = AgentExecution.ensure_current()
               refute Map.has_key?(current, :policy_override)
               :unchanged
             end)

    assert Enum.all?(owner_state(c).calls, fn {expected, _action} -> expected == RunStateStore.material_projection(c.raw) end)
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "control"))
    before = evidence(c)
    parent = self()
    assert {:stop, {:stale_execution, ids, :material_state_changed}} = within(c, fn -> send(parent, :unexpected_body) end)
    assert ids == ids(c)
    refute_received :unexpected_body
    assert evidence(c) == before
  end

  @tag full_defaults: true
  test "checked writes advance from their return while preserving fresh usage and lease metadata", c do
    assert :ok =
             within(c, fn ->
               {binding, invocation} = open_invocation()
               assert :ok = AgentExecution.observe_usage(invocation, %{usage: %{input_tokens: 40, output_tokens: 2}})
               assert {:ok, refreshed} = LeaseManager.refresh_token(c.token)
               assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(refreshed))
               assert {:ok, state} = AgentExecution.update_current(%{policy_override: "accepted"})
               assert state.token_usage == %{input_tokens: 40, output_tokens: 2, total_tokens: 42}
               assert state.lease_updated_at == refreshed["updated_at"]
               assert {:ok, next} = AgentExecution.transition_current("validate", %{})
               assert next.stage == "validate"
               assert {:ok, current} = AgentExecution.ensure_current()
               assert current.last_ledger_event_id == next.last_ledger_event_id
               assert :ok = AgentExecution.retire_session(binding)
             end)

    assert owner_state(c).expected == RunStateStore.material_projection(raw!(c))
  end

  @tag full_defaults: true
  test "same-stage material control rejects writes without replacing evidence", c do
    assert {:stop, {:stale_execution, _, :material_state_changed}} =
             within(c, fn ->
               assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :review_claims, %{"C-1" => %{status: "control"}}))
               before = evidence(c)
               assert {:stop, {:stale_execution, _, :material_state_changed}} = AgentExecution.update_current(%{policy_override: "old"})
               assert evidence(c) == before
               :ok
             end)
  end

  test "a retained current callback sends the new expected outside provider payload", c do
    assert :ok =
             within(c, fn ->
               {_binding, invocation} = open_invocation()
               assert {:ok, changed} = AgentExecution.update_current(%{policy_override: "accepted"})
               assert :ok = AgentExecution.forward_update(invocation, %{session_id: "current-session", expected: %{"stage" => "foreign"}})
               assert [{expected, update}] = owner_state(c).updates
               assert expected == RunStateStore.material_projection(changed)
               assert update.expected == %{"stage" => "foreign"}
               :ok
             end)
  end

  test "obsolete or foreign callbacks are discarded before the current sticky decision", c do
    assert {:stop, {:stale_execution, _, :control}} =
             within(c, fn ->
               {binding, old} = open_invocation()
               assert {:ok, current} = AgentExecution.begin_invocation(binding)
               assert {:stop, {:stale_execution, _, :control}} = AgentExecution.stale(:control)
               assert {:discard, :obsolete_invocation} = AgentExecution.guard_invocation(old)
               assert {:discard, :foreign_worker} = Task.async(fn -> AgentExecution.guard_invocation(current) end) |> Task.await()
               assert {:stop, {:stale_execution, _, :control}} = AgentExecution.guard_invocation(current)
               :ok
             end)
  end

  for first <- [:accounting, :stale] do
    @tag first_cause: first
    test "#{first} remains first even when the caller catches a later terminal and returns ok", c do
      expected = if c.first_cause == :accounting, do: {:stop, {:accounting_uncertain, :first}}, else: {:stop, {:stale_execution, ids(c), :first}}

      assert ^expected =
               within(c, fn ->
                 assert ^expected = if(c.first_cause == :accounting, do: AgentExecution.fail(:first), else: AgentExecution.stale(:first))

                 try do
                   throw({:caught_terminal, if(c.first_cause == :accounting, do: AgentExecution.stale(:second), else: AgentExecution.fail(:second))})
                 catch
                   :throw, {:caught_terminal, terminal} -> assert terminal == expected
                 end

                 :ok
               end)

      state = owner_state(c)
      assert state.registry.uncertain == if(c.first_cause == :accounting, do: :first, else: nil)
    end
  end

  test "ambiguous advance acknowledgement cannot repeat an already persisted CAS", c do
    assert {:stop, {:accounting_uncertain, :invalid_owner_confirmation}} =
             within(c, fn ->
               assert :ok = GenServer.call(c.owner, {:reply_override, :unexpected})
               assert {:stop, {:accounting_uncertain, :invalid_owner_confirmation}} = AgentExecution.transition_current("validate", %{})
               after_cas = evidence(c)
               assert raw!(c)["stage"] == "validate"
               assert {:stop, {:accounting_uncertain, :invalid_owner_confirmation}} = AgentExecution.transition_current("implement", %{})
               assert evidence(c) == after_cas
               :ok
             end)

    assert Enum.count(owner_state(c).calls, fn {_expected, action} -> match?({:advance_current, _, _}, action) end) == 1
  end

  test "owner confirmation timeout retains the completed CAS and prevents replay", c do
    assert {:stop, {:accounting_uncertain, :owner_confirmation_timeout}} =
             within(c, fn ->
               assert :ok = GenServer.call(c.owner, {:reply_override, :no_reply})
               assert {:stop, {:accounting_uncertain, :owner_confirmation_timeout}} = AgentExecution.transition_current("validate", %{})
               after_cas = evidence(c)
               assert raw!(c)["stage"] == "validate"
               assert {:stop, {:accounting_uncertain, :owner_confirmation_timeout}} = AgentExecution.transition_current("implement", %{})
               assert evidence(c) == after_cas
               :ok
             end)

    assert Enum.count(owner_state(c).calls, fn {_expected, action} -> match?({:advance_current, _, _}, action) end) == 1
  end

  for stage <- ["validate", "blocked"] do
    @tag denied_advance_stage: stage
    test "owner stop cannot acknowledge an already persisted #{stage} CAS", c do
      assert {:stop, {:accounting_uncertain, :advance_confirmation_stopped}} =
               within(c, fn ->
                 assert :ok = GenServer.call(c.owner, {:reply_override, {:stop, {:execution_stopped, %{stage: "blocked"}}}})
                 attrs = if c.denied_advance_stage == "blocked", do: %{stop_reason: %{code: "domain_stop"}}, else: %{}
                 assert {:stop, {:accounting_uncertain, :advance_confirmation_stopped}} = AgentExecution.transition_current(c.denied_advance_stage, attrs)
                 assert raw!(c)["stage"] == c.denied_advance_stage
                 :ok
               end)
    end
  end

  for stage <- ["blocked", "done"] do
    @tag terminal_stage: stage
    test "own #{stage} preserves domain result and denies ordinary continuation without false uncertainty", c do
      result = if c.terminal_stage == "blocked", do: {:stop, :domain_stop}, else: {:done, c.issue}

      assert ^result =
               within(c, fn ->
                 {binding, _invocation} = open_invocation()
                 attrs = if c.terminal_stage == "blocked", do: %{stop_reason: %{code: "domain_stop"}}, else: %{}
                 assert {:ok, persisted} = AgentExecution.transition_current(c.terminal_stage, attrs)
                 assert persisted.stage == c.terminal_stage

                 if c.terminal_stage == "blocked" do
                   assert :ok = AgentExecution.confirm_stop_notification()
                   assert :ok = AgentExecution.confirm_stop_notification()
                 end

                 stopped = {:stop, {:execution_stopped, %{stage: c.terminal_stage}}}
                 assert ^stopped = AgentExecution.ensure_current()
                 assert ^stopped = AgentExecution.entry_context(c.workspace, c.issue)
                 assert ^stopped = AgentExecution.update_current(%{policy_override: "forbidden"})
                 assert ^stopped = AgentExecution.ensure_session_capacity(:unsupported_provider)
                 assert ^stopped = AgentExecution.retire_session(binding)
                 result
               end)

      state = owner_state(c)
      assert state.terminal == nil
      assert state.registry.uncertain == nil
      assert state.known_terminal.stage == c.terminal_stage
      assert Enum.count(state.calls, fn {_expected, action} -> action == :confirm_stop_notification end) == if(c.terminal_stage == "blocked", do: 2, else: 0)
    end
  end

  test "control after own blocked CAS rejects notification and preserves the control", c do
    assert {:stop, {:stale_execution, _, :material_state_changed}} =
             within(c, fn ->
               assert {:ok, _} = AgentExecution.transition_current("blocked", %{stop_reason: %{code: "domain_stop"}})
               assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "control"))
               before = evidence(c)
               assert {:stop, {:stale_execution, _, :material_state_changed}} = AgentExecution.confirm_stop_notification()
               assert evidence(c) == before
               :ok
             end)
  end

  test "a generic ok cannot acknowledge a terminal CAS", c do
    assert {:stop, {:accounting_uncertain, :invalid_owner_confirmation}} =
             within(c, fn ->
               assert :ok = GenServer.call(c.owner, {:reply_override, :ok})
               assert {:stop, {:accounting_uncertain, :invalid_owner_confirmation}} = AgentExecution.transition_current("blocked", %{stop_reason: %{code: "domain_stop"}})
               assert {:stop, {:accounting_uncertain, :invalid_owner_confirmation}} = AgentExecution.confirm_stop_notification()
               :ok
             end)

    assert raw!(c)["stage"] == "blocked"
    assert Enum.all?(owner_state(c).calls, fn {_expected, action} -> action != :confirm_stop_notification end)
  end

  test "a control between CAS and its owner acknowledgement never grants known-terminal notification", c do
    assert {:stop, {:stale_execution, _, :material_state_changed}} =
             within(c, fn ->
               assert :ok = GenServer.call(c.owner, {:before_advance, fn -> RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "control")) end})
               assert {:stop, {:stale_execution, _, :material_state_changed}} = AgentExecution.transition_current("blocked", %{stop_reason: %{code: "domain_stop"}})
               assert {:stop, {:stale_execution, _, :material_state_changed}} = AgentExecution.confirm_stop_notification()
               :ok
             end)

    assert owner_state(c).known_terminal == nil
    assert raw!(c)["policy_override"] == "control"
  end

  test "an owner stop accepts final usage only with the retained previous receipt and does not rebind the worker", c do
    expected = RunStateStore.material_projection(c.raw)

    assert {:stop, {:execution_stopped, %{stage: "blocked"}}} =
             within(c, fn ->
               {_binding, invocation} = open_invocation()
               assert :ok = GenServer.call(c.owner, :own_policy_stop)
               assert {:stop, {:execution_stopped, %{stage: "blocked"}}} = AgentExecution.observe_usage(invocation, %{usage: %{input_tokens: 120, output_tokens: 3}})
               assert {:stop, {:execution_stopped, %{stage: "blocked"}}} = AgentExecution.confirm_current_invocation()
             end)

    state = owner_state(c)
    assert [{^expected, _observation}] = state.usage
    assert state.receipt.previous == expected
    assert state.expected == state.receipt.next
    assert state.known_terminal.next == state.receipt.next
    assert raw!(c)["token_usage"]["total_tokens"] == 123
    assert raw!(c)["stage"] == "blocked"
  end

  test "a public stop with unchanged material preserves ordinary queued usage", c do
    assert {:stop, {:execution_stopped, %{stage: "implement"}}} =
             within(c, fn ->
               {_binding, invocation} = open_invocation()
               assert :ok = GenServer.call(c.owner, :public_stop)
               AgentExecution.observe_usage(invocation, %{usage: %{input_tokens: 150_000, output_tokens: 0}})
             end)

    assert raw!(c)["stage"] == "implement"
    assert raw!(c)["token_usage"]["total_tokens"] == 150_000
    assert owner_state(c).receipt == nil
  end

  test "owner-requested stop alone cannot authorize a worker closure notification", c do
    assert {:stop, {:accounting_uncertain, :stop_notification_not_authorized}} =
             within(c, fn ->
               {_binding, invocation} = open_invocation()
               assert :ok = GenServer.call(c.owner, :own_policy_stop)
               assert {:stop, {:execution_stopped, %{stage: "blocked"}}} = AgentExecution.confirm_invocation(invocation)
               AgentExecution.confirm_stop_notification()
             end)

    assert Enum.all?(owner_state(c).calls, fn {_expected, action} -> action != :confirm_stop_notification end)
  end

  test "workspace precondition is captured outside the lifecycle lock and survives exact restoration", c do
    assert :ok =
             within(c, fn ->
               assert {:ok, precondition} = AgentExecution.workspace_precondition(c.workspace, c.issue)
               assert precondition == %{authority: %{ticket: c.ticket, lease_token: c.token}, expected: RunStateStore.material_projection(c.raw)}
               before = raw!(c)
               staged = Path.join(c.root, ".CURRENT-1.bootstrap-current")

               assert :restored =
                        RunStateStore.with_readable_snapshot(c.workspace, precondition, fn ->
                          File.rename!(Path.dirname(RunStateStore.state_path(c.workspace)), staged)
                          File.rename!(staged, Path.dirname(RunStateStore.state_path(c.workspace)))
                          :restored
                        end)

               assert raw!(c) == before
               :ok
             end)
  end

  test "identified missing canonical state never adopts a staged copy through entry", c do
    assert {:stop, {:stale_execution, _, :missing}} =
             within(c, fn ->
               staged = Path.join(c.root, ".CURRENT-1.bootstrap-current")
               File.mkdir_p!(staged)
               File.rename!(RunStateStore.state_path(c.workspace), Path.join(staged, "run_state.json"))
               assert {:ok, _} = RunStateStore.load(c.workspace)
               AgentExecution.workspace_precondition(c.workspace, c.issue)
             end)
  end

  test "a different entry issue is rejected before any additional owner confirmation", c do
    before = evidence(c)

    assert {:stop, {:accounting_uncertain, :execution_issue_mismatch}} =
             within(c, fn ->
               calls = owner_state(c).calls
               assert calls == [{RunStateStore.material_projection(c.raw), {:confirm, nil, 0}}]
               wrong_issue = %{c.issue | identifier: "OTHER-1"}
               assert {:stop, {:accounting_uncertain, :execution_issue_mismatch}} = AgentExecution.entry_context(c.workspace, wrong_issue)
               assert owner_state(c).calls == calls
               assert {:stop, {:accounting_uncertain, :execution_issue_mismatch}} = AgentExecution.entry_context(c.workspace, c.issue)
               assert owner_state(c).calls == calls
             end)

    assert evidence(c) == before
  end

  test "nested context cannot replace the captured authority", c do
    assert {:stop, {:accounting_uncertain, :execution_context_already_present}} =
             within(c, fn ->
               AgentExecution.with_context(c.ticket, c.token, c.owner, c.raw, fn -> flunk("nested body") end)
               :ok
             end)
  end

  @tag deploy: true
  test "checked deploy returns the existing operation continuation and advances only its persisted state", c do
    assert :ok =
             within(c, fn ->
               assert {:ok, deploy} = AgentExecution.begin_deploy(c.workspace, %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: "deploy_preview", command: "local-test-only"})

               assert {:ok, %{authority: :current, persistence: :confirmed, command_status: "passed"}} =
                        AgentExecution.record_deploy_result(deploy, %{status: :passed, command: "local-test-only", output: "observed"})

               assert {:ok, persisted, continuation} = AgentExecution.transition_deploy(deploy, "post_deploy_verify", %{})
               assert persisted.stage == "post_deploy_verify"
               assert continuation.event["event_id"] == persisted.last_ledger_event_id
               assert continuation.event["metadata"]["deploy_operation_id"] == deploy.operation_id
               assert :ok = AgentExecution.finish_deploy(deploy, continuation)
               assert {:ok, _} = AgentExecution.ensure_current()
               :ok
             end)
  end

  defp within(c, fun), do: DispatchAudit.with_authorization(c.ticket, fn -> AgentExecution.with_context(c.ticket, c.token, c.owner, c.raw, fun) end)
  defp owner_state(c), do: GenServer.call(c.owner, :state)
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp ids(c), do: %{run_id: c.ticket.run_id, dispatch_id: c.ticket.dispatch_id}

  defp open_invocation do
    assert {:ok, binding} = AgentExecution.register_session(Claude, %{session_id: "current-session"}, :main)
    assert {:ok, invocation} = AgentExecution.begin_invocation(binding)
    {binding, invocation}
  end

  defp evidence(c),
    do: %{
      snapshot: File.read(RunStateStore.state_path(c.workspace)),
      ledger: File.read(c.token.storage.ledger_path),
      lease: File.read(c.token.storage.lease_path),
      dispatch: File.read(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json"))
    }
end
