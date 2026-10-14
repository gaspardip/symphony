defmodule SymphonyElixir.RetryBudgetTotalsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.{DispatchAudit, RunStateStore}

  defmodule OwnerHarness do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, LeaseManager, Orchestrator, RunStateStore, Workspace}
    alias SymphonyElixir.AgentProvider.Claude

    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def init({runtime, observer}), do: {:ok, %{runtime: runtime, observer: observer}}

    def handle_call({:dispatch, issue, attempt}, _from, state) do
      runtime = state.runtime
      {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, runtime.lease_owner)

      claim = %{
        token: acquired.token,
        lease: acquired.lease,
        custody_ref: make_ref(),
        holder: :retry,
        workspace: Workspace.path_for_issue(issue),
        issue: issue,
        started_at_ms: System.monotonic_time(:millisecond),
        deadline: :not_pending,
        promotion_ref: nil,
        timer: nil
      }

      runtime = %{runtime | lease_claims: %{issue.id => claim}}
      observer = state.observer

      # This fixture replaces only the worker body. Production admission, custody,
      # gate authorization, checkpoint and DOWN handlers remain in the real owner.
      start_child = fn supervisor, _job ->
        # This is the canonical RAW immediately after real begin/3, before the child is returned.
        admitted_raw = issue |> Workspace.path_for_issue() |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
        Task.Supervisor.start_child(supervisor, fn -> controlled_worker(observer, admitted_raw) end)
      end

      runtime = Orchestrator.do_spawn_issue_worker_for_test(runtime, issue, attempt, self(), start_child_fun: start_child)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call({:terminate, id}, _from, state) do
      runtime = Orchestrator.terminate_running_issue(state.runtime, id, false)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

    def handle_call(message, from, state) do
      {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      {:reply, reply, %{state | runtime: runtime}}
    end

    def handle_info({:authorize_dispatch, id, _dispatch_id, pid} = message, state) do
      entry = state.runtime.running[id]
      send(pid, {:execution_context, entry.agent_execution.context, entry.agent_execution.expected})
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end

    def handle_info({:agent_execution_usage, _invocation, _expected, _observation} = message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      send(state.observer, {:usage_processed, self(), runtime})
      {:noreply, %{state | runtime: runtime}}
    end

    def handle_info({:DOWN, _ref, :process, _pid, _reason} = message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      send(state.observer, {:budget_worker_exit, self(), message})
      send(state.observer, {:budget_worker_down, self(), runtime})
      {:noreply, %{state | runtime: runtime}}
    end

    def handle_info(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end

    defp controlled_worker(observer, admitted_raw) do
      receive do
        {:execution_context, context, expected} ->
          true = RunStateStore.material_projection(admitted_raw) === expected

          DispatchGate.run(context.owner, context.ticket.dispatch_id, fn ->
            DispatchAudit.with_authorization(context.ticket, fn ->
              AgentExecution.with_context(context.ticket, context.lease_token, context.owner, admitted_raw, fn ->
                :ok = AgentExecution.ensure_session_capacity()
                {:ok, session} = Claude.start_session(context.ticket.workspace)
                {:ok, binding} = AgentExecution.register_session(Claude, session, :main)
                {:ok, invocation} = AgentExecution.begin_invocation(binding)
                send(observer, {:budget_worker_ready, context.owner, self(), RunStateStore.material_projection(admitted_raw)})

                try do
                  usage_loop(observer, invocation)
                after
                  Claude.stop_session(session)
                end
              end)
            end)
          end)
      end
    end

    defp usage_loop(observer, invocation) do
      receive do
        {:observe_usage, input, output} ->
          case AgentExecution.observe_usage(invocation, %{usage: %{input_tokens: input, output_tokens: output, total_tokens: input + output}}) do
            :ok ->
              usage_loop(observer, invocation)

            {:stop, {:accounting_uncertain, cause}} = terminal ->
              send(observer, {:budget_worker_uncertain, self(), terminal})
              receive do: (:finish_uncertain -> exit({:accounting_uncertain, cause}))

            {:stop, {:stale_execution, ids, cause}} = terminal ->
              send(observer, {:budget_worker_stale, self(), terminal})
              receive do: (:finish_stale -> exit({:stale_execution, ids, cause}))

            {:stop, {:execution_stopped, _}} = terminal ->
              terminal
          end
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "retry-budget-totals-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      policy_token_budget: %{
        per_turn_input: 150_000,
        per_issue_total: 200_000,
        per_issue_total_output: 10_000,
        stages: %{implement: %{per_turn_input_soft: 110_000, per_turn_input_hard: 120_000}},
        broad_implement: %{enabled: true, auto_retry_limit: 2}
      }
    )

    issue = %Issue{id: "retry-totals", identifier: "RETRY-TOTALS", title: "Budget recovery", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)

    assert {:ok, _} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               resume_context: %{target_paths: ["lib/example.ex"]}
             })

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, issue: issue, workspace: workspace}
  end

  test "a fresh worker resumes accumulated totals and duplicate provider reports are idempotent", context do
    {first_owner, first} = spawn_worker(context.issue)
    assert first.running[context.issue.id].issue_token_usage_base == %{}
    report_usage(first_owner, context.issue.id, 100_000, 1_000)
    assert {:ok, %{token_usage: %{total_tokens: 101_000}}} = RunStateStore.load(context.workspace)

    duplicate = report_usage(first_owner, context.issue.id, 100_000, 1_000)
    assert duplicate.running[context.issue.id].agent_total_tokens == 101_000
    assert {:ok, %{token_usage: %{total_tokens: 101_000}}} = RunStateStore.load(context.workspace)
    GenServer.call(first_owner, {:terminate, context.issue.id})
    assert_receive {:budget_worker_down, ^first_owner, first_stopped}, 5_000
    refute Map.has_key?(first_stopped.running, context.issue.id)
    GenServer.stop(first_owner, :normal)

    # The next worker gets no prior in-memory state, as on retry after a runtime restart.
    {second_owner, second} = spawn_worker(context.issue, 2)
    assert second.running[context.issue.id].agent_total_tokens == 0
    assert second.running[context.issue.id].issue_token_usage_base.total_tokens == 101_000
    report_usage(second_owner, context.issue.id, 100_000, 1_000)
    assert_receive {:budget_worker_down, ^second_owner, stopped}, 5_000
    refute Map.has_key?(stopped.running, context.issue.id)
    refute Map.has_key?(stopped.retry_attempts, context.issue.id)

    assert {:ok, %{token_usage: %{total_tokens: 202_000}, stop_reason: %{rule_id: "budget.per_issue_total_exceeded"}}} =
             RunStateStore.load(context.workspace)
  end

  test "issue totals cannot be reset by a stale stage snapshot or a duplicate checkpoint", context do
    assert {:ok, old_snapshot} = RunStateStore.load(context.workspace)
    usage = %{input_tokens: 90_000, output_tokens: 1_000, total_tokens: 91_000}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
    assert :ok = RunStateStore.save(context.workspace, Map.put(old_snapshot, :stage, "validate"))
    assert {:ok, %{stage: "validate", token_usage: ^usage}} = RunStateStore.load(context.workspace)
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
    assert {:ok, %{token_usage: ^usage}} = RunStateStore.load(context.workspace)
  end

  test "another issue identity in the same workspace starts with zero prior usage", context do
    usage = %{input_tokens: 90_000, output_tokens: 1_000, total_tokens: 91_000}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
    replacement = %{context.issue | id: "replacement-issue"}
    refute Map.has_key?(RunStateStore.load_or_default(context.workspace, replacement), :token_usage)
    fresh_usage = %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, replacement, fresh_usage)
    assert {:ok, %{issue_id: "replacement-issue", token_usage: ^fresh_usage}} = RunStateStore.load(context.workspace)
  end

  test "broad narrowing cannot bypass totals spent by a previous worker", context do
    entry = %{
      workspace_path: context.workspace,
      dispatch_stage: "implement",
      last_agent_message: "The target is lib/example.ex.",
      agent_input_tokens: 130_000,
      agent_output_tokens: 0,
      agent_total_tokens: 130_000,
      issue_token_usage_base: %{total_tokens: 100_000}
    }

    assert {:stop, %RunPolicy.Violation{code: :per_issue_total_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, entry)
  end

  test "output usage is cumulative while the per-turn input allowance remains local to the worker", context do
    entry = %{
      workspace_path: context.workspace,
      dispatch_stage: "implement",
      agent_input_tokens: 10,
      agent_output_tokens: 600,
      agent_total_tokens: 610,
      issue_token_usage_base: %{input_tokens: 130_000, output_tokens: 9_500, total_tokens: 139_500}
    }

    assert {:stop, %RunPolicy.Violation{code: :per_issue_output_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, entry)
  end

  test "review-fix total exhaustion takes precedence over a simultaneous turn retry", context do
    entry = review_fix_entry(context.workspace)
    entry = Map.put(entry, :issue_token_usage_base, %{total_tokens: 100_000})

    assert {:stop, %RunPolicy.Violation{code: :per_issue_total_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, entry)

    assert {:ok, %{stage: "blocked", stop_reason: %{rule_id: "budget.per_issue_total_exceeded"}}} =
             RunStateStore.load(context.workspace)
  end

  test "review-fix output exhaustion takes precedence over a simultaneous turn retry", context do
    entry =
      context.workspace
      |> review_fix_entry()
      |> Map.put(:agent_output_tokens, 101)
      |> Map.put(:agent_total_tokens, 130_101)
      |> Map.put(:issue_token_usage_base, %{output_tokens: 9_900, total_tokens: 10_000})

    assert {:stop, %RunPolicy.Violation{code: :per_issue_output_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, entry)
  end

  test "exhausted persisted totals block active and passive dispatch before a worker starts", context do
    if is_nil(Process.whereis(WorkflowStore)), do: start_supervised!(WorkflowStore)
    assert :ok = WorkflowStore.force_reload()
    usage = %{input_tokens: 200_001, output_tokens: 0, total_tokens: 200_001}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)

    dispatch = fn state, _issue, _attempt ->
      send(self(), :unexpected_budget_dispatch)
      state
    end

    for stage <- ["implement", "await_checks"] do
      assert {:ok, _} = RunStateStore.transition(context.workspace, stage)

      assert %State{running: running, candidate_fetch_error: {:token_budget_exhausted, "budget.per_issue_total_exceeded"}} =
               Orchestrator.dispatch_runtime_issue_for_test(%State{max_concurrent_agents: 1}, context.issue, nil,
                 active_dispatch_fun: dispatch,
                 passive_dispatch_fun: dispatch
               )

      assert running == %{}
      refute_received :unexpected_budget_dispatch
      assert {:ok, %{stage: "blocked", token_usage: ^usage}} = RunStateStore.load(context.workspace)
    end
  end

  test "a corrupt snapshot during usage checkpoint stops the worker and blocks another dispatch", context do
    {owner, state} = spawn_worker(context.issue)
    entry = state.running[context.issue.id]
    worker = entry.pid
    journal_path = Path.join(DispatchAudit.marker_directory(context.workspace), "marker.json")
    journal_before = File.read!(journal_path)
    lease_before = File.read!(entry.lease_token.storage.lease_path)
    payload = "{broken-snapshot"
    File.write!(RunStateStore.state_path(context.workspace), payload)
    uncertain = report_usage(owner, context.issue.id, 10, 1)
    assert uncertain.running[context.issue.id].pid == worker
    assert Process.alive?(worker)
    ids = %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
    assert {:error, %Jason.DecodeError{} = cause} = Jason.decode(payload)
    assert uncertain.stale_execution_errors[context.issue.id] == %{context: entry.agent_execution.context, ids: ids, cause: cause}
    assert uncertain.token_usage_errors == %{}
    assert uncertain.running[context.issue.id].agent_execution.registry.uncertain == nil
    assert uncertain.running[context.issue.id].agent_total_tokens == 0
    assert uncertain.agent_totals.total_tokens == 0
    assert_receive {:budget_worker_stale, ^worker, {:stop, {:stale_execution, ^ids, ^cause}}}, 5_000
    assert File.read!(RunStateStore.state_path(context.workspace)) == payload
    assert File.read!(journal_path) == journal_before
    assert File.read!(entry.lease_token.storage.lease_path) == lease_before
    refute Map.has_key?(uncertain.retry_attempts, context.issue.id)

    send(worker, :finish_stale)
    assert_receive {:budget_worker_down, ^owner, stopped}, 5_000
    assert_received {:budget_worker_exit, ^owner, {:DOWN, ref, :process, ^worker, {:stale_execution, ^ids, ^cause}}}
    assert ref == entry.ref
    refute Map.has_key?(stopped.running, context.issue.id)
    assert stopped.stale_execution_errors[context.issue.id] == uncertain.stale_execution_errors[context.issue.id]
    assert stopped.token_usage_errors == %{}
    assert stopped.agent_totals.total_tokens == 0
    assert stopped.lease_claims[context.issue.id] == uncertain.lease_claims[context.issue.id]
    assert File.read!(RunStateStore.state_path(context.workspace)) == payload
    assert File.read!(journal_path) == journal_before
    assert File.read!(entry.lease_token.storage.lease_path) == lease_before
    refute Map.has_key?(stopped.retry_attempts, context.issue.id)

    dispatch = fn returned, _issue, _attempt ->
      send(self(), :unexpected_worker)
      returned
    end

    assert %State{candidate_fetch_error: {:stale_execution, ^ids, ^cause}} =
             Orchestrator.dispatch_runtime_issue_for_test(stopped, context.issue, nil,
               active_dispatch_fun: dispatch,
               passive_dispatch_fun: dispatch
             )

    refute_received :unexpected_worker
  end

  test "filesystem errors retain their write API contract", context do
    path = RunStateStore.state_path(context.workspace)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :eisdir} = RunStateStore.save(context.workspace, %{})
    assert {:error, :eisdir} = RunStateStore.transition(context.workspace, "implement")
    assert {:error, :eisdir} = RunStateStore.update(context.workspace, & &1)
    assert {:error, :eisdir} = RunStateStore.sync_lease(context.workspace, context.issue, %{})
    assert {:error, {:run_state_unreadable, :eisdir}} = RunStateStore.ensure_readable(context.workspace)
  end

  defp review_fix_entry(workspace) do
    %{
      workspace_path: workspace,
      stage: "implement",
      turn_count: 1,
      agent_input_tokens: 130_000,
      agent_output_tokens: 0,
      agent_total_tokens: 130_000,
      turn_started_input_tokens: 0,
      resume_context: %{
        budget_mode: "review_fix",
        budget_scope_kind: "review_claim_batch",
        budget_scope_ids: ["comment:1", "comment:2"]
      }
    }
  end

  defp spawn_worker(issue, attempt \\ 1) do
    runtime = %State{
      lease_owner: "budget-totals-owner",
      max_concurrent_agents: 1,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    owner = start_supervised!(Supervisor.child_spec({OwnerHarness, {runtime, self()}}, id: make_ref()))
    state = GenServer.call(owner, {:dispatch, issue, attempt})
    worker = state.running[issue.id].pid
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    assert_receive {:budget_worker_ready, ^owner, ^worker, expected}, 5_000
    assert expected === state.running[issue.id].agent_execution.expected
    {owner, GenServer.call(owner, :runtime)}
  end

  defp report_usage(owner, issue_id, input, output) do
    state = GenServer.call(owner, :runtime)
    send(state.running[issue_id].pid, {:observe_usage, input, output})
    assert_receive {:usage_processed, ^owner, next_state}, 5_000
    next_state
  end
end
