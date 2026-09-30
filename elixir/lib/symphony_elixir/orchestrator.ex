defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the tracker and dispatches repository copies to agent-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.AgentExecution
  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Config
  alias SymphonyElixir.DeliveryEngine
  alias SymphonyElixir.DeployAudit
  alias SymphonyElixir.DispatchAudit
  alias SymphonyElixir.DispatchGate
  alias SymphonyElixir.GitHubEvent
  alias SymphonyElixir.GitHubEventInbox
  alias SymphonyElixir.GitManager
  alias SymphonyElixir.IssueSource
  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.PolicyPack
  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ManualIssueSpec
  alias SymphonyElixir.Observability
  alias SymphonyElixir.PriorityEngine
  alias SymphonyElixir.PRWatcher
  alias SymphonyElixir.ReviewEvidenceCollector
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.RunnerRuntime
  alias SymphonyElixir.RunPolicy
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.TrackerEvent
  alias SymphonyElixir.TrackerReader
  alias SymphonyElixir.TrackerEventInbox
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore
  alias SymphonyElixir.WorkflowProfile
  alias SymphonyElixir.Orchestrator.Controls
  alias SymphonyElixir.Workspace

  @continuation_retry_delay_ms 1_000
  @passive_continuation_retry_delay_ms 5_000
  @passive_continuation_retry_delay_mid_ms 15_000
  @passive_continuation_retry_delay_long_ms 30_000
  @passive_continuation_retry_delay_max_ms 60_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @completed_retention_ms 7 * 24 * 60 * 60 * 1000
  @issue_routing_cache_max_keys 500
  @blocked_state "Blocked"
  @merging_state "Merging"
  @empty_agent_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }
  @dialyzer {:nowarn_function,
             persist_review_feedback_for_workspace: 4,
             persist_ci_failure_for_workspace: 5,
             review_thread_state: 2,
             issue_for_run_state: 1,
             seeded_manual_issue_from_run_state: 1,
             issue_ref_for_run_state: 1,
             normalize_issue_source: 1,
             maybe_start_autonomous_review_follow_up: 8,
             maybe_start_autonomous_ci_follow_up: 6,
             autonomous_review_follow_up?: 4,
             paused_issue?: 3,
             maybe_dispatch_autonomous_review_follow_up: 2,
             ci_resume_context: 3,
             ci_failure_summary: 1,
             put_review_resume_context: 5,
             review_resume_context: 5,
             review_feedback_summary: 1}

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :healing_poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :next_healing_poll_due_at_ms,
      :poll_check_in_progress,
      :current_poll_mode,
      :lease_owner,
      tracker_poll_read: nil,
      tracker_poll_cycle: nil,
      tracker_poll_pending: [],
      admission_read: nil,
      admission_batch: nil,
      next_admission_kind: :poll,
      running: %{},
      completed: %{},
      claimed: MapSet.new(),
      lease_claims: %{},
      retry_attempts: %{},
      token_usage_errors: %{},
      paused_issue_states: %{},
      skipped_issues: [],
      last_candidate_issues: [],
      candidate_fetch_error: nil,
      priority_overrides: %{},
      policy_overrides: %{},
      agent_totals: nil,
      agent_rate_limits: nil,
      issue_routing_cache: %{},
      tracker_backoff_until_ms: nil,
      tracker_backoff_reason: nil,
      tracker_backoff_rule_id: nil,
      webhook_last_accepted_at: nil,
      webhook_last_ignored_at: nil,
      webhook_last_ignored_reason: nil,
      webhook_last_ignored_rule_id: nil,
      webhook_last_rejected_at: nil,
      webhook_last_rejected_reason: nil,
      webhook_last_rejected_rule_id: nil,
      inbox_last_drained_at: nil,
      inbox_ack_pending: nil,
      inbox_storage_error: nil,
      tracker_inbox_batch: nil,
      tracker_inbox_wakeup: nil,
      github_webhook_last_accepted_at: nil,
      github_webhook_last_ignored_at: nil,
      github_webhook_last_ignored_reason: nil,
      github_webhook_last_ignored_rule_id: nil,
      github_webhook_last_rejected_at: nil,
      github_webhook_last_rejected_reason: nil,
      github_webhook_last_rejected_rule_id: nil,
      github_inbox_last_drained_at: nil,
      github_inbox_ack_pending: nil,
      github_inbox_storage_error: nil,
      github_webhook_check_in_progress: false,
      github_last_assignment: nil,
      first_poll_completed: false
    ]

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)

    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      healing_poll_interval_ms: Config.healing_poll_interval_ms(),
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      next_healing_poll_due_at_ms: now_ms + Config.healing_poll_interval_ms(),
      poll_check_in_progress: false,
      current_poll_mode: nil,
      lease_owner: "orchestrator-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil
    }

    send(self(), :startup_terminal_cleanup)
    :ok = schedule_tick(0)
    :ok = schedule_healing_tick(Config.healing_poll_interval_ms())

    {:ok, state}
  end

  @impl true
  def handle_info(:startup_terminal_cleanup, state), do: {:noreply, enqueue_tracker_poll(state, :startup_cleanup)}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        current_poll_mode: :discovery,
        next_poll_due_at_ms: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:healing_tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        current_poll_mode: :healing,
        next_healing_poll_due_at_ms: nil
    }

    notify_dashboard()
    :ok = schedule_healing_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state), do: {:noreply, enqueue_tracker_poll(refresh_runtime_config(state), :discovery)}
  def handle_info(:run_healing_cycle, state), do: {:noreply, enqueue_tracker_poll(refresh_runtime_config(state), :healing)}

  def handle_info({:tracker_events_available, attrs}, state) when is_map(attrs) do
    state =
      state
      |> refresh_runtime_config()
      |> record_webhook_accept(attrs)

    notify_dashboard()

    if state.poll_check_in_progress == true do
      {:noreply, queue_tracker_poll(state, :webhook)}
    else
      :ok = schedule_webhook_cycle_start()
      {:noreply, %{state | poll_check_in_progress: true, current_poll_mode: :webhook}}
    end
  end

  def handle_info({:tracker_webhook_rejected, attrs}, state) when is_map(attrs) do
    state = record_webhook_rejection(state, attrs)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:tracker_webhook_ignored, attrs}, state) when is_map(attrs) do
    state = record_webhook_ignored(state, attrs)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:github_events_available, attrs}, state) when is_map(attrs) do
    state =
      state
      |> refresh_runtime_config()
      |> record_github_webhook_accept(attrs)

    notify_dashboard()

    if state.github_webhook_check_in_progress == true do
      {:noreply, queue_tracker_poll(state, :github_webhook)}
    else
      :ok = schedule_github_webhook_cycle_start()
      {:noreply, %{state | github_webhook_check_in_progress: true}}
    end
  end

  def handle_info({:github_webhook_rejected, attrs}, state) when is_map(attrs) do
    state = record_github_webhook_rejection(state, attrs)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:github_webhook_ignored, attrs}, state) when is_map(attrs) do
    state = record_github_webhook_ignored(state, attrs)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(:run_webhook_cycle, state), do: {:noreply, enqueue_tracker_poll(refresh_runtime_config(state), :webhook)}
  def handle_info(:run_github_webhook_cycle, state), do: {:noreply, enqueue_tracker_poll(refresh_runtime_config(state), :github_webhook)}

  def handle_info({:tracker_inbox_continue, ref}, %{tracker_inbox_batch: %{ref: ref}} = state) do
    state =
      cond do
        state.inbox_ack_pending -> state
        state.tracker_inbox_batch.rows == [] -> yield_tracker_inbox(state)
        tracker_inbox_reader_active?(state) -> state
        true -> enqueue_tracker_poll(state, :webhook)
      end

    {:noreply, state}
  end

  def handle_info({:tracker_inbox_continue, _obsolete}, state), do: {:noreply, state}

  def handle_info({:tracker_inbox_ack, cursor}, %{inbox_ack_pending: cursor} = state) when not is_nil(cursor),
    do: {:noreply, confirm_tracker_inbox_prefix(state)}

  def handle_info({:tracker_inbox_ack, _obsolete}, state), do: {:noreply, state}

  def handle_info({:tracker_inbox_wakeup, ref, location, generation}, %{tracker_inbox_wakeup: %{ref: ref, location: location, generation: generation} = wakeup} = state) do
    state = %{state | tracker_inbox_wakeup: nil}
    head_ref = wakeup.head_ref

    state =
      case state.tracker_inbox_batch do
        %{location: ^location, generation: ^generation, head: %{ref: ^head_ref, phase: :backoff}} ->
          if tracker_backoff_active?(state) or tracker_poll_backoff_identity(state) != wakeup.backoff,
            do: backoff_tracker_inbox(state),
            else: enqueue_tracker_poll(state, :webhook)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:tracker_inbox_wakeup, _ref, _location, _generation}, state), do: {:noreply, state}

  def handle_info({:tracker_read_result, ref, result}, %{tracker_poll_read: %{purpose: :inbox_lookup, invalidated: true, ref: ref} = operation} = state) do
    {state, _result} = observe_tracker_inbox_transport(state, operation, result)
    {:noreply, state}
  end

  def handle_info({:tracker_read_result, ref, result}, %{tracker_poll_read: %{purpose: :inbox_lookup, ref: ref} = operation} = state) do
    Process.demonitor(operation.monitor, [:flush])
    state = receive_tracker_inbox_result(%{state | tracker_poll_read: nil}, operation, result)
    {:noreply, state |> finish_tracker_poll() |> advance_admission()}
  end

  def handle_info({:tracker_read_result, ref, result}, %{admission_read: %{purpose: :inbox_admission, invalidated: true, ref: ref} = operation} = state) do
    {state, _result} = observe_tracker_inbox_transport(state, operation, result)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{tracker_poll_read: %{purpose: :inbox_lookup, monitor: ref, pid: pid} = operation} = state) do
    state = receive_tracker_inbox_result(%{state | tracker_poll_read: nil}, operation, {:error, {:tracker_reader_down, reason}})
    state = state |> finish_tracker_poll() |> advance_admission()
    state = if operation.invalidated and state.tracker_inbox_batch, do: enqueue_tracker_poll(state, :webhook), else: state
    {:noreply, state}
  end

  def handle_info({:tracker_read_result, ref, result}, %{tracker_poll_read: %{ref: expected} = operation} = state) when ref == expected do
    Process.demonitor(operation.monitor, [:flush])
    state = %{state | tracker_poll_read: nil}
    {:noreply, receive_tracker_poll_result(state, operation, result)}
  end

  def handle_info({:tracker_read_result, ref, result}, %{admission_read: %{purpose: :promotion, invalidated: true, ref: expected} = operation} = state) when ref == expected do
    {state, _result} = observe_promotion_result(state, operation, result)
    {:noreply, state}
  end

  def handle_info({:promotion_timeout, id, promotion_ref}, state) do
    case Map.get(state.lease_claims, id) do
      %{promotion_ref: ^promotion_ref, deadline: deadline} = claim when is_integer(deadline) ->
        if System.monotonic_time(:millisecond) >= deadline do
          completion = Map.get(claim, :completion)
          outcome = tracker_inbox_cleanup_outcome(state, completion)
          next = if Map.has_key?(state.running, id), do: do_terminate_running_issue(state, id, false), else: release_issue_claim(state, id)
          next = next |> tracker_inbox_outcome(id, outcome) |> finish_tracker_inbox_action(completion, nil)

          case next.candidate_fetch_error do
            {tag, ^id, _reason} when tag in [:lease_release_failed, :lease_release_audit_failed] -> {:noreply, next}
            _ -> {:noreply, %{next | candidate_fetch_error: {:promotion_deadline_expired, id}}}
          end
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:tracker_read_result, ref, result}, %{admission_read: %{ref: expected} = operation} = state) when ref == expected do
    Process.demonitor(operation.monitor, [:flush])
    state = %{state | admission_read: nil}
    {:noreply, receive_admission_result(state, operation, result)}
  end

  def handle_info({:tracker_read_result, _obsolete_ref, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, reason}, %{tracker_poll_read: %{monitor: expected, pid: reader_pid} = operation} = state)
      when ref == expected and pid == reader_pid do
    state = %{state | tracker_poll_read: nil}
    {:noreply, receive_tracker_poll_result(state, operation, {:error, {:tracker_reader_down, reason}})}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{admission_read: %{monitor: expected, pid: reader_pid} = operation} = state)
      when ref == expected and pid == reader_pid do
    state = %{state | admission_read: nil}
    {:noreply, receive_admission_result(state, operation, {:error, {:tracker_reader_down, reason}})}
  end

  def handle_info({:authorize_dispatch, issue_id, dispatch_id, pid}, state) do
    case Map.get(state.running, issue_id) do
      %{pid: ^pid, dispatch_ticket: %{dispatch_id: ^dispatch_id} = ticket} = entry ->
        completion = Map.get(entry, :completion)

        with {:ok, %{holder: :gated} = claim} <- current_issue_custody(state, issue_id, entry.custody_ref),
             :ok <- tracker_inbox_boundary(state, completion),
             {:ok, _workspace} <- current_custody_workspace(state, entry.issue),
             :ok <- DispatchAudit.with_authorization(ticket, fn -> DispatchAudit.ensure_workspace_access(ticket.workspace) end),
             :ok <- LeaseManager.activate_dispatch(claim.token, claim.deadline, pid, dispatch_id) do
          state = transfer_issue_custody(state, issue_id, :running)
          claim = Map.fetch!(state.lease_claims, issue_id)
          if is_reference(claim.timer), do: Process.cancel_timer(claim.timer)
          claim = %{claim | promotion_ref: nil, timer: nil} |> Map.put(:completion, nil)
          state = put_in(state.lease_claims[issue_id], claim)
          entry = %{entry | custody_ref: claim.custody_ref} |> Map.put(:completion, nil) |> Map.put(:execution_started?, true)
          state = %{state | running: Map.put(state.running, issue_id, entry)}
          state = tracker_inbox_outcome(state, issue_id, {:applied, :dispatch_authorized})
          {:noreply, finish_tracker_inbox_action(state, completion, nil)}
        else
          {:ok, _already_transferred_claim} ->
            {:noreply, state}

          {kind, reason} when kind in [:blocked, :recheck] ->
            state = do_terminate_running_issue(state, issue_id, false)
            state = tracker_inbox_outcome(state, issue_id, {kind, reason})
            {:noreply, finish_tracker_inbox_action(state, completion, nil)}

          {:error, reason} ->
            stopped = state |> do_terminate_running_issue(issue_id, false) |> halt_dispatch_audit(issue_id, reason)
            {:noreply, finish_tracker_inbox_action(stopped, completion, nil)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        entry = Map.fetch!(state.running, issue_id)

        cond do
          entry.pid != pid ->
            {:noreply, state}

          accounting_down_cause(entry, reason) != nil ->
            {:noreply, finish_uncertain_worker_down(state, issue_id, entry, accounting_down_cause(entry, reason))}

          Map.has_key?(entry, :execution_stop_requested) ->
            {:noreply, finish_requested_worker_down(state, issue_id, entry)}

          true ->
            completion = Map.get(Map.fetch!(state.running, issue_id), :completion)
            completion_outcome = tracker_inbox_cleanup_outcome(state, completion)
            {running_entry, state} = pop_running_entry(state, issue_id)
            state = record_session_completion_totals(state, running_entry)
            session_id = running_entry_session_id(running_entry)
            issue = Map.get(running_entry, :issue, %{})
            next_attempt = next_retry_attempt_from_running(running_entry) || 1

            state =
              case finish_completed_dispatch(running_entry, reason) do
                {:ownership_uncertain, ownership_reason} ->
                  state
                  |> tracker_inbox_failure(issue_id, {:lease_ownership_uncertain, ownership_reason})
                  |> cancel_dispatch_retry(issue_id)
                  |> Map.put(:candidate_fetch_error, {:lease_ownership_uncertain, issue_id, ownership_reason})

                :ok ->
                  case {reason, RunPolicy.maybe_stop_for_token_budget(issue, running_entry)} do
                    {:normal, {:retry, metadata}} ->
                      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling adaptive #{Map.get(metadata, :budget_mode, "budget")} retry")

                      schedule_issue_retry(state, issue_id, next_attempt, %{
                        identifier: running_entry.identifier,
                        delay_type: :continuation,
                        issue: running_entry.issue,
                        error: Map.get(metadata, :summary, "adaptive token retry"),
                        budget_retry: true,
                        budget_mode: Map.get(metadata, :budget_mode, "review_fix"),
                        budget_retry_count: Map.get(metadata, :retry_count),
                        budget_resume_context: Map.get(metadata, :resume_context)
                      })

                    {:normal, {:stop, _violation}} ->
                      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; recorded token-budget stop")
                      release_issue_claim(state, issue_id)

                    {:normal, :ok} ->
                      continuation = continuation_metadata_for_running_entry(running_entry)
                      continuation_delay_type = Map.get(continuation, :delay_type, :continuation)

                      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling #{continuation_delay_type} continuation check")

                      state = complete_issue(state, issue_id)

                      case continuation_delay_type do
                        :none ->
                          release_issue_claim(state, issue_id)

                        delay_type ->
                          schedule_issue_retry(
                            state,
                            issue_id,
                            1,
                            %{
                              identifier: running_entry.identifier,
                              delay_type: delay_type,
                              issue: running_entry.issue
                            }
                            |> Map.merge(Map.drop(continuation, [:delay_type]))
                          )
                      end

                    {_other_reason, _budget_result} ->
                      Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

                      schedule_issue_retry(state, issue_id, next_attempt, %{
                        identifier: running_entry.identifier,
                        error: "agent exited: #{inspect(reason)}"
                      })
                  end

                {:error, {tag, _} = audit_reason} when tag in [:deploy_audit_pending, :deploy_audit_read_failed] ->
                  halt_dispatch_audit(state, issue_id, audit_reason)

                {:error, audit_reason} ->
                  state
                  |> stop_terminal_dispatch(%{id: issue_id}, audit_reason)
                  |> halt_dispatch_audit(issue_id, audit_reason)
              end

            state = state |> tracker_inbox_outcome(issue_id, completion_outcome) |> finish_tracker_inbox_action(completion, nil)
            Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

            notify_dashboard()
            {:noreply, state}
        end
    end
  end

  def handle_info({:agent_execution_usage, %{context: context} = invocation, observation}, state) do
    {:noreply, receive_execution_usage(state, context, invocation, observation)}
  end

  def handle_info({:agent_execution_usage, _invocation, _observation}, state), do: {:noreply, state}

  def handle_info({:agent_execution_uncertain, context, cause}, state) do
    case matching_execution_entry(state, context) do
      {:ok, issue_id, _entry} -> {:noreply, mark_accounting_uncertain(state, issue_id, cause)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:agent_worker_update, %{context: context} = invocation, %{event: _, timestamp: _} = update}, state) do
    case authorized_execution_invocation(state, context, invocation) do
      {:ok, issue_id, entry} ->
        zero = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, input_reported: 0, output_reported: 0, total_reported: 0}
        {updated, _delta} = integrate_agent_update(entry, update, zero)
        next = state |> Map.put(:running, Map.put(state.running, issue_id, updated)) |> apply_agent_rate_limits(update)
        notify_dashboard()
        {:noreply, next}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:agent_worker_update, %{}, _update}, state), do: {:noreply, state}

  def handle_info(
        {:agent_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      %{dispatch_ticket: _ticket} ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_agent_update(running_entry, update)
        Observability.emit_token_delta(updated_running_entry, token_delta, update)

        state =
          state
          |> apply_agent_token_delta(token_delta)
          |> apply_agent_rate_limits(update)
          |> Map.put(:running, Map.put(running, issue_id, updated_running_entry))
          |> checkpoint_and_check_token_budget(issue_id, updated_running_entry, token_delta)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:agent_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_ref}, state) do
    case Map.get(state.retry_attempts, issue_id) do
      %{retry_ref: ^retry_ref, status: :scheduled} ->
        state = put_in(state.retry_attempts[issue_id].status, :ready)
        state = advance_admission(state)
        notify_dashboard()
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp queue_tracker_poll(state, mode) do
    pending = state.tracker_poll_pending
    %{state | tracker_poll_pending: if(mode in pending, do: pending, else: pending ++ [mode])}
  end

  defp enqueue_tracker_poll(state, mode) do
    state = reconcile_tracker_inbox_context(state)
    state = queue_tracker_poll(state, mode)
    state = if is_nil(state.tracker_poll_cycle), do: begin_next_tracker_poll(state), else: state
    sync_tracker_poll_flags(state)
  end

  defp begin_next_tracker_poll(%{tracker_poll_pending: []} = state), do: state

  defp begin_next_tracker_poll(%{tracker_poll_pending: [mode | pending]} = state) do
    cycle = %{mode: mode, phase: if(mode == :startup_cleanup, do: :cleanup, else: :running), fingerprint: nil, invalidated: MapSet.new(), error: nil}
    state = %{state | tracker_poll_pending: pending, tracker_poll_cycle: cycle}

    state =
      case mode do
        :discovery -> %{state | next_poll_due_at_ms: nil}
        :healing -> %{state | next_healing_poll_due_at_ms: nil}
        _ -> state
      end

    state = if tracker_backoff_active?(state), do: maybe_note_tracker_backoff(state, mode), else: state
    runner = RunnerRuntime.runner_health()

    if mode not in [:startup_cleanup, :github_webhook] and not Map.get(runner, :dispatch_enabled, true) do
      state
      |> Map.put(:last_candidate_issues, [])
      |> Map.put(:skipped_issues, [])
      |> tracker_poll_error({:runner_health, Map.fetch!(runner, :rule_id)})
      |> finish_tracker_poll()
    else
      start_tracker_poll_phase(state)
    end
  end

  defp capture_tracker_poll_context do
    with :ok <- Config.validate!(), do: {:ok, Config.tracker_read_context()}
  rescue
    error in NimbleOptions.ValidationError -> {:error, {:invalid_tracker_read_context, Exception.message(error)}}
  end

  defp start_tracker_poll_phase(%{tracker_poll_cycle: %{fingerprint: nil}} = state) do
    case capture_tracker_poll_context() do
      {:ok, context} ->
        state = put_in(state.tracker_poll_cycle.fingerprint, context.fingerprint)
        start_tracker_poll_read(state, context)

      {:error, reason} ->
        state |> tracker_poll_configuration_error(reason) |> finish_tracker_poll()
    end
  end

  defp start_tracker_poll_read(state, context) do
    phase = state.tracker_poll_cycle.phase
    state = if phase == :running, do: reconcile_stalled_running_issues(state), else: state
    mode = state.tracker_poll_cycle.mode
    manual_only = mode == :github_webhook or tracker_backoff_active?(state)

    args =
      case phase do
        :cleanup -> context.linear_terminal_states
        :running -> Map.keys(state.running)
        :approval -> WorkflowProfile.approval_gate_states(policy_pack: context.policy_pack_name)
        :candidates -> []
      end

    if phase == :running and args == [] do
      advance_tracker_poll(state, context)
    else
      # Capture read inputs only. No State, claims or continuation travels to I/O.
      read = fn -> {:ok, tracker_poll_sources(phase, args, context, manual_only)} end

      case TrackerReader.start(read) do
        {:ok, reader} ->
          operation =
            Map.merge(reader, %{
              phase: phase,
              fingerprint: context.fingerprint,
              running: Map.new(state.running, fn {id, entry} -> {id, tracker_poll_worker_identity(entry)} end),
              backoff: tracker_poll_backoff_identity(state)
            })

          %{state | tracker_poll_read: operation}

        {:error, reason} ->
          state |> tracker_poll_error({:tracker_reader_start_failed, reason}) |> finish_tracker_poll()
      end
    end
  end

  defp tracker_poll_sources(phase, args, context, true) do
    manual =
      case phase do
        :running -> IssueSource.fetch_manual_issue_states_by_ids(args, context)
        :candidates -> IssueSource.fetch_manual_candidate_issues(context)
        _ -> IssueSource.fetch_manual_issues_by_states(args, context)
      end

    %{tracker: :disabled, manual: manual}
  end

  defp tracker_poll_sources(:running, ids, context, false), do: IssueSource.fetch_issue_states_by_ids_outcomes(ids, context)
  defp tracker_poll_sources(:candidates, _args, context, false), do: IssueSource.fetch_candidate_outcomes(context)
  defp tracker_poll_sources(_phase, states, context, false), do: IssueSource.fetch_issues_by_states_outcomes(states, context)

  defp receive_tracker_poll_result(state, operation, result) do
    state = refresh_runtime_config(state)

    case capture_tracker_poll_context() do
      {:ok, %{fingerprint: fingerprint} = context} when fingerprint == operation.fingerprint ->
        runner = RunnerRuntime.runner_health()

        if state.tracker_poll_cycle.mode in [:startup_cleanup, :github_webhook] or Map.get(runner, :dispatch_enabled, true) do
          state |> apply_tracker_poll_result(operation, result) |> advance_tracker_poll(context)
        else
          state |> tracker_poll_error({:runner_health, Map.fetch!(runner, :rule_id)}) |> finish_tracker_poll()
        end

      {:ok, _context} ->
        state |> tracker_poll_error(:tracker_read_context_changed) |> finish_tracker_poll()

      {:error, reason} ->
        state |> tracker_poll_configuration_error(reason) |> finish_tracker_poll()
    end
  end

  defp apply_tracker_poll_result(state, _operation, {:error, reason}), do: tracker_poll_error(state, {:tracker_read_failed, reason})

  defp apply_tracker_poll_result(state, operation, {:ok, %{tracker: tracker, manual: manual}}) do
    # A later throttle decision belongs to current State. The old remote result
    # cannot clear it or feed admission; the independently read manual result stays.
    tracker = if tracker != :disabled and tracker_poll_backoff_identity(state) != operation.backoff, do: :discarded, else: tracker

    state =
      if tracker in [:disabled, :discarded] do
        state
      else
        {next, _result} = tracker_read(state, fn -> tracker end)
        next
      end

    state =
      Enum.reduce([tracker, manual], state, fn
        {:error, reason}, acc -> tracker_poll_error(acc, reason)
        _result, acc -> acc
      end)

    issues =
      [manual, tracker]
      |> Enum.flat_map(fn
        {:ok, issues} when is_list(issues) -> issues
        {:error, _reason} -> []
        outcome when outcome in [:disabled, :discarded] -> []
      end)
      |> Enum.reject(&tracker_poll_issue_invalidated?(state, &1))

    case operation.phase do
      :cleanup ->
        Enum.each(issues, &cleanup_current_terminal_issue(state, &1))
        state

      :running ->
        current_issues =
          Enum.filter(issues, fn
            %Issue{} = issue ->
              case Map.fetch(state.running, issue.id) do
                {:ok, entry} -> Map.get(operation.running, issue.id) == tracker_poll_worker_identity(entry)
                :error -> false
              end

            _issue ->
              false
          end)

        reconcile_running_issue_states(current_issues, state, active_state_set(), terminal_state_set())

      :approval ->
        Enum.reduce(issues, state, fn
          %Issue{} = issue, acc -> maybe_promote_review_ready_issue(acc, issue)
          _issue, acc -> acc
        end)

      :candidates ->
        if match?({:ok, _}, tracker) or match?({:ok, [_ | _]}, manual) or (tracker in [:disabled, :discarded] and match?({:ok, _}, manual)) do
          process_candidate_issues(state, issues)
        else
          %{state | skipped_issues: []}
        end
    end
  end

  defp advance_tracker_poll(%{tracker_poll_cycle: %{phase: :cleanup}} = state, _context), do: finish_tracker_poll(state)

  defp advance_tracker_poll(%{tracker_poll_cycle: %{phase: :running}} = state, context) do
    state |> put_in([Access.key(:tracker_poll_cycle), :phase], :approval) |> start_tracker_poll_read(context)
  end

  defp advance_tracker_poll(%{tracker_poll_cycle: %{phase: :approval, mode: mode}} = state, context) do
    cond do
      mode == :github_webhook ->
        state |> drain_github_events() |> finish_tracker_poll()

      mode == :webhook ->
        state = drain_tracker_events(state)
        if state.tracker_poll_read, do: state, else: finish_tracker_poll(state)

      true ->
        state |> put_in([Access.key(:tracker_poll_cycle), :phase], :candidates) |> start_tracker_poll_read(context)
    end
  end

  defp advance_tracker_poll(state, _context), do: finish_tracker_poll(state)

  defp finish_tracker_poll(state) do
    cycle = state.tracker_poll_cycle
    now_ms = System.monotonic_time(:millisecond)
    state = %{state | tracker_poll_cycle: nil, tracker_poll_read: nil}
    runner = RunnerRuntime.runner_health()

    error =
      cond do
        cycle.mode == :github_webhook and not Map.get(runner, :dispatch_enabled, true) ->
          {:runner_health, Map.fetch!(runner, :rule_id)}

        cycle.mode != :github_webhook and tracker_backoff_active?(state) ->
          {:tracker_backoff, state.tracker_backoff_rule_id}

        true ->
          cycle.error
      end

    state = if error, do: %{state | candidate_fetch_error: error}, else: state

    state =
      case cycle.mode do
        :discovery ->
          if :discovery in state.tracker_poll_pending do
            state
          else
            :ok = schedule_tick(state.poll_interval_ms)
            %{state | next_poll_due_at_ms: now_ms + state.poll_interval_ms}
          end

        :healing ->
          completed = Map.reject(state.completed, fn {_id, at} -> now_ms - at > @completed_retention_ms end)
          state = %{state | completed: completed}

          if :healing in state.tracker_poll_pending do
            state
          else
            :ok = schedule_healing_tick(state.healing_poll_interval_ms)
            %{state | next_healing_poll_due_at_ms: now_ms + state.healing_poll_interval_ms}
          end

        _ ->
          state
      end

    state = begin_next_tracker_poll(state) |> sync_tracker_poll_flags()
    notify_dashboard()
    state
  end

  defp sync_tracker_poll_flags(state) do
    mode = if state.tracker_poll_cycle, do: state.tracker_poll_cycle.mode
    modes = [mode | state.tracker_poll_pending]

    %{
      state
      | poll_check_in_progress: Enum.any?(modes, &(&1 not in [nil, :github_webhook])),
        current_poll_mode: if(mode == :github_webhook, do: nil, else: mode),
        github_webhook_check_in_progress: :github_webhook in modes
    }
  end

  defp tracker_poll_configuration_error(state, reason) do
    record_invalid_dispatch_configuration(reason, %{
      actor_id: state.lease_owner,
      metadata: %{dispatch_mode: state.tracker_poll_cycle.mode}
    })

    Logger.error("Dispatch blocked by config validation: #{inspect(reason)}")
    state |> Map.put(:skipped_issues, []) |> tracker_poll_error(reason)
  end

  defp tracker_poll_error(state, reason) do
    state = put_in(state.tracker_poll_cycle.error, state.tracker_poll_cycle.error || reason)
    %{state | candidate_fetch_error: reason}
  end

  defp invalidate_tracker_poll_issue(state, identifier) when is_binary(identifier) do
    state = invalidate_admission_issue(state, identifier)

    if state.tracker_poll_cycle do
      update_in(state.tracker_poll_cycle.invalidated, &MapSet.put(&1, String.trim(identifier)))
    else
      state
    end
  end

  defp invalidate_tracker_poll_issue(state, _identifier), do: state

  defp tracker_poll_issue_invalidated?(state, %Issue{} = issue) do
    invalidated = state.tracker_poll_cycle.invalidated
    MapSet.member?(invalidated, issue.identifier) or MapSet.member?(invalidated, issue.id)
  end

  defp tracker_poll_issue_invalidated?(_state, _issue), do: false

  defp tracker_poll_worker_identity(entry),
    do: {Map.get(entry, :pid), Map.get(entry, :ref), lease_owner_from_entry(entry), lease_epoch_from_entry(entry)}

  defp tracker_poll_backoff_identity(state),
    do: {state.tracker_backoff_until_ms, state.tracker_backoff_reason, state.tracker_backoff_rule_id}

  defp cleanup_current_terminal_issue(state, %Issue{id: id, identifier: identifier, state: issue_state}) when is_binary(identifier) do
    unavailable =
      Map.has_key?(state.running, id) or MapSet.member?(state.claimed, id) or
        Map.has_key?(state.retry_attempts, id) or Map.has_key?(state.paused_issue_states, id)

    if not unavailable and terminal_issue_state?(issue_state, terminal_state_set()) and LeaseManager.read(id) == {:error, :missing} do
      cleanup_issue_workspace(identifier)
    end
  end

  defp cleanup_current_terminal_issue(_state, _issue), do: :ok

  defp process_candidate_issues(%State{} = state, issues) when is_list(issues) do
    state = invalidate_tracker_inbox_cache(state, issues, nil)
    {state, candidate_issues} = block_candidate_policy_conflicts(state, issues)
    policy_blocked_count = length(issues) - length(candidate_issues)
    {eligible_issues, skipped_issues} = partition_issues_by_label_gate(candidate_issues, state)

    Logger.info("[dispatch] candidates=#{length(issues)} policy_blocked=#{policy_blocked_count} eligible=#{length(eligible_issues)} skipped=#{length(skipped_issues)}")

    next_state = %{
      state
      | skipped_issues: skipped_issues,
        last_candidate_issues: issues,
        candidate_fetch_error: nil,
        issue_routing_cache: remember_issue_cache_entries(state.issue_routing_cache, issues)
    }

    next_state = maybe_warn_first_poll(next_state, length(issues))

    if available_slots(next_state) > 0 do
      pre_dispatch_running = map_size(next_state.running)
      result_state = begin_admission_batch(next_state, eligible_issues)
      dispatched_count = map_size(result_state.running) - pre_dispatch_running

      skip_reasons =
        skipped_issues
        |> Enum.frequencies_by(fn entry -> Map.get(entry, :reason, "unknown") end)

      Logger.info("[dispatch] poll summary: discovered=#{length(issues)} eligible=#{length(eligible_issues)} dispatched=#{dispatched_count} skipped_reasons=#{inspect(skip_reasons)}")

      result_state
    else
      Logger.info("[dispatch] no available slots — skipping dispatch of #{length(eligible_issues)} eligible issue(s)")

      next_state
    end
  end

  # Ordinary poll admission owns one bounded batch and one additional reader.
  # New polls can refresh diagnostics, but never append to or restart this cursor.
  defp begin_admission_batch(%{admission_batch: batch} = state, _issues) when not is_nil(batch), do: state

  defp begin_admission_batch(state, issues) do
    case capture_tracker_poll_context() do
      {:ok, context} ->
        batch = %{issues: sort_issues_for_dispatch(issues, state), invalidated: MapSet.new()}
        advance_admission(%{state | admission_batch: batch}, context)

      {:error, reason} ->
        %{state | candidate_fetch_error: reason}
    end
  end

  defp advance_admission(%{admission_read: operation} = state) when not is_nil(operation), do: state

  defp advance_admission(state) do
    case capture_tracker_poll_context() do
      {:ok, context} -> advance_admission(state, context)
      {:error, reason} -> defer_ready_retries(%{state | candidate_fetch_error: reason, admission_batch: nil})
    end
  end

  defp advance_admission(%{admission_read: operation} = state, _context) when not is_nil(operation), do: state

  defp advance_admission(state, context) do
    retry =
      state.retry_attempts
      |> Enum.filter(fn {_id, entry} -> Map.get(entry, :status) == :ready end)
      |> Enum.min_by(fn {id, entry} -> {entry.due_at_ms, id} end, fn -> nil end)

    ready = %{
      poll: match?(%{issues: [_ | _]}, state.admission_batch),
      retry: retry != nil,
      inbox: match?(%{head: %{phase: :admission_ready}}, state.tracker_inbox_batch) and is_nil(state.inbox_ack_pending)
    }

    order =
      case state.next_admission_kind do
        :poll -> [:poll, :retry, :inbox]
        :retry -> [:retry, :inbox, :poll]
        :inbox -> [:inbox, :poll, :retry]
      end

    case Enum.find(order, &Map.fetch!(ready, &1)) do
      :retry ->
        {id, entry} = retry
        state = start_retry_lookup(%{state | next_admission_kind: :inbox}, id, entry, context)
        advance_admission(state, context)

      :poll ->
        state = advance_admission_batch(%{state | next_admission_kind: :retry}, context)
        advance_admission(state, context)

      :inbox ->
        state = select_tracker_inbox_admission(%{state | next_admission_kind: :poll}, context)
        advance_admission(state, context)

      nil ->
        %{state | admission_batch: if(ready.poll, do: state.admission_batch, else: nil)}
    end
  end

  defp advance_admission_batch(%{admission_batch: %{issues: [issue | rest]}} = state, context) do
    state = put_in(state.admission_batch.issues, rest)

    state =
      if admission_issue_current?(state, issue) do
        dispatch_runtime_issue(
          state,
          issue,
          nil,
          fn current, candidate, _attempt -> start_admission_read(current, candidate, context) end,
          &dispatch_passive_issue/3
        )
      else
        state
      end

    state
  end

  defp start_admission_read(state, issue, context) do
    issue_id = issue.id
    read = fn -> IssueSource.fetch_issue_states_by_ids([issue_id], context) end

    case TrackerReader.start(read) do
      {:ok, reader} ->
        operation = Map.merge(reader, %{purpose: :poll, issue: issue, fingerprint: context.fingerprint, backoff: tracker_poll_backoff_identity(state)})
        Logger.info("[admission] pending issue_id=#{issue.id} remaining=#{length(state.admission_batch.issues)}")
        %{state | admission_read: operation}

      {:error, reason} ->
        admission_discard(state, issue, {:tracker_reader_start_failed, reason})
    end
  end

  defp select_tracker_inbox_admission(state, context) do
    head = state.tracker_inbox_batch.head

    case tracker_inbox_current(state, head.ref) do
      :ok ->
        state = %{state | max_concurrent_agents: Config.max_concurrent_agents()}

        cond do
          tracker_backoff_active?(state) ->
            backoff_tracker_inbox(state)

          tracker_inbox_issue_current?(state, head.issue) ->
            state = begin_tracker_inbox_decision(state)
            state = dispatch_runtime_issue(state, head.issue, nil, fn current, issue, _attempt -> start_tracker_inbox_admission(current, issue, context) end, &dispatch_passive_issue/3)
            settle_tracker_inbox_decision(state)

          true ->
            apply_tracker_inbox_head(state, :not_eligible)
        end

      {:blocked, reason} ->
        block_tracker_inbox(state, reason)

      {:recheck, reason} ->
        recheck_tracker_inbox(state, reason)
    end
  end

  defp tracker_inbox_issue_current?(state, issue) do
    not Map.has_key?(state.retry_attempts, issue.id) and not tracker_backoff_active?(state) and
      Map.get(RunnerRuntime.runner_health(), :dispatch_enabled, true) and is_nil(dispatch_skip_reason(issue, state)) and
      should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  defp start_tracker_inbox_admission(state, issue, context) do
    id = issue.id
    head = state.tracker_inbox_batch.head

    case TrackerReader.start(fn -> IssueSource.fetch_issue_states_by_ids([id], context) end) do
      {:ok, reader} ->
        operation =
          Map.merge(reader, %{
            purpose: :inbox_admission,
            head_ref: head.ref,
            completion: head.completion,
            issue: issue,
            fingerprint: context.fingerprint,
            backoff: tracker_poll_backoff_identity(state),
            invalidated: false
          })

        %{state | admission_read: operation} |> tracker_inbox_outcome(id, {:wait, :admission})

      {:error, reason} ->
        block_tracker_inbox(state, {:tracker_reader_start_failed, reason})
    end
  end

  defp receive_tracker_inbox_admission(state, operation, result) do
    state = refresh_runtime_config(state)
    {state, result} = observe_tracker_inbox_transport(state, operation, result)

    case state.tracker_inbox_batch do
      %{head: %{completion: completion}} when completion == operation.completion ->
        cond do
          operation.invalidated ->
            recheck_tracker_inbox(state, :tracker_inbox_invalidated)

          tracker_reader_failure?(result) ->
            block_tracker_inbox(state, elem(result, 1))

          true ->
            case tracker_inbox_current(state, operation.head_ref) do
              :ok -> apply_tracker_inbox_admission(state, operation, result)
              {:blocked, reason} -> block_tracker_inbox(state, reason)
              {:recheck, reason} -> recheck_tracker_inbox(state, reason)
            end
        end

      _ ->
        state
    end
  end

  defp apply_tracker_inbox_admission(state, _operation, {:error, {:linear_rate_limited, _}}), do: backoff_tracker_inbox(state)
  defp apply_tracker_inbox_admission(state, _operation, {:error, :tracker_inbox_backoff_changed}), do: backoff_tracker_inbox(state)

  defp apply_tracker_inbox_admission(state, operation, {:ok, [%Issue{id: id, identifier: identifier} = refreshed]})
       when id == operation.issue.id and identifier == operation.issue.identifier do
    refreshed = merge_dispatch_refresh_issue(operation.issue, refreshed)

    if tracker_inbox_issue_current?(state, refreshed) do
      state
      |> dispatch_runtime_issue(refreshed, nil, &do_dispatch_issue/3, &dispatch_passive_issue/3)
      |> settle_tracker_inbox_decision()
    else
      apply_tracker_inbox_head(state, :not_eligible)
    end
  end

  defp apply_tracker_inbox_admission(state, _operation, _ordinary_rejection), do: apply_tracker_inbox_head(state, :discarded)

  defp start_promotion_read(state, issue, attempt, recipient, start_child_fun, initial_stage, stage) do
    with {:ok, claim} <- current_issue_custody(state, issue.id),
         {:ok, context} <- capture_tracker_poll_context(),
         :ok <- validate_dispatch_configuration(issue),
         {:ok, run_state} <- RunStateStore.load_checked(claim.workspace, issue) do
      run_identity = Map.take(run_state, [:run_id, :run_identity_event_id, :run_identity_ledger_path])
      deadline = claim.started_at_ms + div(claim.token.storage.ttl_ms, 2)

      if System.monotonic_time(:millisecond) < deadline and is_nil(state.admission_read) and
           (ManualIssueSpec.runtime_issue_id?(issue.id) or not tracker_backoff_active?(state)) do
        promotion_ref = make_ref()
        timer = Process.send_after(self(), {:promotion_timeout, issue.id, promotion_ref}, max(0, deadline - System.monotonic_time(:millisecond)))
        claim = %{claim | deadline: deadline, promotion_ref: promotion_ref, timer: timer}
        state = put_in(state.lease_claims[issue.id], claim)
        id = issue.id

        case TrackerReader.start(fn -> IssueSource.fetch_issue_states_by_ids([id], context) end) do
          {:ok, reader} ->
            operation =
              Map.merge(reader, %{
                purpose: :promotion,
                issue: issue,
                attempt: attempt,
                recipient: recipient,
                start_child_fun: start_child_fun,
                initial_stage: initial_stage,
                stage: stage,
                run_identity: run_identity,
                token: claim.token,
                custody_ref: claim.custody_ref,
                completion: Map.get(claim, :completion),
                head_ref: Map.get(Map.get(claim, :completion) || %{}, :head_ref),
                deadline: deadline,
                fingerprint: context.fingerprint,
                backoff: tracker_poll_backoff_identity(state),
                invalidated: false
              })

            %{state | admission_read: operation} |> tracker_inbox_wait(issue.id, :promotion)

          {:error, reason} ->
            state |> stop_terminal_dispatch(issue, {:promotion_reader_failed, reason}) |> tracker_inbox_outcome(issue.id, {:blocked, {:promotion_reader_failed, reason}})
        end
      else
        outcome =
          cond do
            System.monotonic_time(:millisecond) >= deadline -> {:applied, :dispatch_rejected}
            tracker_backoff_active?(state) -> {:backoff, :transport_changed}
            true -> {:recheck, :promotion_unavailable}
          end

        state |> stop_terminal_dispatch(issue, :promotion_unavailable) |> tracker_inbox_outcome(issue.id, outcome)
      end
    else
      {:error, reason} -> state |> stop_terminal_dispatch(issue, reason) |> tracker_inbox_outcome(issue.id, tracker_inbox_validation_outcome(reason))
      {:mismatch, _snapshot} -> state |> stop_terminal_dispatch(issue, :promotion_identity_mismatch) |> tracker_inbox_outcome(issue.id, {:recheck, :promotion_identity_mismatch})
    end
  end

  defp receive_admission_result(state, %{purpose: :promotion} = operation, result) do
    {state, result} = observe_promotion_result(state, operation, result)
    completion = Map.get(operation, :completion)

    state =
      case tracker_inbox_boundary(state, completion) do
        :ok ->
          cond do
            not is_nil(completion) and tracker_reader_failure?(result) ->
              state |> stop_terminal_dispatch(operation.issue, elem(result, 1)) |> tracker_inbox_outcome(operation.issue.id, {:blocked, elem(result, 1)})

            not is_nil(completion) and (match?({:error, {:linear_rate_limited, _}}, result) or result == :discarded) ->
              state |> release_issue_claim(operation.issue.id) |> tracker_inbox_outcome(operation.issue.id, {:backoff, :transport_changed})

            true ->
              apply_promotion_result(state, operation, result)
          end

        {kind, reason} when kind in [:blocked, :recheck] ->
          state = release_tracker_inbox_operation(state, operation)
          tracker_inbox_outcome(state, operation.issue.id, {kind, reason})
      end

    state |> finish_tracker_inbox_action(completion, nil) |> advance_admission() |> resume_tracker_inbox_after_reader()
  end

  defp receive_admission_result(state, %{purpose: :inbox_admission} = operation, result) do
    state = receive_tracker_inbox_admission(state, operation, result)
    state = if operation.invalidated and state.tracker_inbox_batch, do: enqueue_tracker_poll(state, :webhook), else: state
    advance_admission(state)
  end

  defp receive_admission_result(state, %{purpose: :retry} = operation, result) do
    state |> receive_retry_result(operation, result) |> advance_admission()
  end

  defp receive_admission_result(state, operation, result) do
    state = refresh_runtime_config(state)

    with :ok <- validate_dispatch_configuration(operation.issue),
         {:ok, context} <- capture_tracker_poll_context(),
         true <- context.fingerprint == operation.fingerprint or {:error, :admission_context_changed} do
      state = apply_admission_result(state, operation, result)
      state = advance_admission(state, context)
      notify_dashboard()
      state
    else
      {:error, reason} ->
        state |> admission_discard(operation.issue, reason) |> Map.put(:admission_batch, nil) |> advance_admission()
    end
  end

  defp release_tracker_inbox_operation(state, operation) do
    case current_issue_custody(state, operation.issue.id, operation.custody_ref) do
      {:ok, claim} when claim.token == operation.token -> release_issue_claim(state, operation.issue.id)
      _ -> state
    end
  end

  defp apply_promotion_result(state, operation, result) do
    id = operation.issue.id

    next =
      with false <- operation.invalidated,
           {:ok, claim} <- current_issue_custody(state, id, operation.custody_ref),
           {:ok, context} <- capture_tracker_poll_context(),
           true <- context.fingerprint == operation.fingerprint or {:error, :promotion_context_changed} do
        state = %{state | max_concurrent_agents: Config.max_concurrent_agents()}
        available_state = %{state | lease_claims: Map.delete(state.lease_claims, id)}

        with true <- System.monotonic_time(:millisecond) < operation.deadline or {:error, :promotion_deadline_expired},
             true <- ManualIssueSpec.runtime_issue_id?(id) or tracker_poll_backoff_identity(state) == operation.backoff or {:error, :promotion_backoff_changed},
             {:ok, issues} <- result,
             true <- issues == [] or match?([%Issue{id: ^id, identifier: identifier}] when identifier == operation.issue.identifier, issues),
             {:ok, refreshed} <- revalidate_issue_for_dispatch(operation.issue, fn _ -> {:ok, issues} end, terminal_state_set()),
             true <- retry_active_current?(state, refreshed) or {:error, :promotion_ineligible},
             true <-
               (dispatch_slots_available?(refreshed, available_state) and company_slots_available?(available_state, PolicyPack.resolve(policy_pack_name(refreshed, state)))) or
                 {:error, :promotion_capacity_changed},
             :ok <- validate_dispatch_configuration(refreshed),
             :ok <- persisted_issue_token_budget_guard(refreshed, claim.workspace),
             {:ok, run_state} <- RunStateStore.load_checked(claim.workspace, refreshed),
             true <- Map.take(run_state, [:run_id, :run_identity_event_id, :run_identity_ledger_path]) == operation.run_identity or {:error, :promotion_run_changed},
             {:ok, stage} when stage == operation.stage <- persisted_dispatch_stage(refreshed, claim.workspace) do
          start_active_issue_worker(state, refreshed, operation.attempt, operation.recipient, operation.start_child_fun, stage)
        else
          {:error, :promotion_ineligible} -> stop_terminal_dispatch(state, operation.issue, {:dispatch_no_longer_eligible, id})
          {:skip, _reason} -> stop_terminal_dispatch(state, operation.issue, {:dispatch_no_longer_eligible, id})
          {:error, reason} -> state |> stop_terminal_dispatch(operation.issue, {:promotion_failed, reason}) |> tracker_inbox_outcome(id, tracker_inbox_promotion_outcome(reason))
          {:mismatch, _snapshot} -> state |> stop_terminal_dispatch(operation.issue, :promotion_run_changed) |> tracker_inbox_outcome(id, {:recheck, :promotion_run_changed})
          _ -> stop_terminal_dispatch(state, operation.issue, :promotion_refresh_ineligible)
        end
      else
        true -> state
        {:error, :lease_custody_changed} -> state
        {:error, :lease_custody_missing} -> state
        {:error, reason} -> stop_terminal_dispatch(state, operation.issue, reason)
      end

    next
  end

  defp observe_promotion_result(state, operation, result) do
    case capture_tracker_poll_context() do
      {:ok, context} when context.fingerprint == operation.fingerprint -> observe_retry_transport(state, operation, result)
      _ -> {state, {:error, :promotion_context_changed}}
    end
  end

  defp cancel_promotion_reader(state, issue_id) do
    case state.admission_read do
      %{purpose: :promotion, issue: %{id: ^issue_id}, invalidated: false} = reader ->
        :ok = TrackerReader.cancel(%{owner: reader.owner, pid: reader.pid, monitor: reader.monitor, ref: reader.ref})
        %{state | admission_read: %{reader | invalidated: true}}

      _ ->
        state
    end
  end

  defp apply_admission_result(state, operation, result) do
    issue = operation.issue

    if not ManualIssueSpec.runtime_issue_id?(issue.id) and tracker_poll_backoff_identity(state) != operation.backoff do
      admission_discard(state, issue, :admission_backoff_changed)
    else
      # Throttling belongs to the transport, even when a control or worker made
      # this issue obsolete. Observe it before deciding whether the issue applies.
      {state, result} = if ManualIssueSpec.runtime_issue_id?(issue.id), do: {state, result}, else: tracker_read(state, fn -> result end)

      case result do
        {:error, _reason} ->
          apply_current_admission_result(state, issue, result)

        {:ok, _issues} ->
          if admission_issue_current?(state, issue) do
            apply_current_admission_result(state, issue, result)
          else
            admission_discard(state, issue, :admission_no_longer_eligible)
          end
      end
    end
  end

  defp apply_current_admission_result(state, issue, {:ok, [%Issue{id: id, identifier: identifier} = refreshed]})
       when id == issue.id and identifier == issue.identifier do
    refreshed = merge_dispatch_refresh_issue(issue, refreshed)

    if admission_issue_current?(state, refreshed) do
      # Re-run the ordinary budget, snapshot and audit guards with current State.
      # Only this continuation skips the already completed pre-lease read.
      dispatch_runtime_issue(state, refreshed, nil, &do_dispatch_issue/3, &dispatch_passive_issue/3)
    else
      admission_discard(state, issue, :admission_refresh_ineligible)
    end
  end

  defp apply_current_admission_result(state, issue, {:ok, []}), do: admission_discard(state, issue, :admission_issue_missing)
  defp apply_current_admission_result(state, issue, {:ok, _issues}), do: admission_discard(state, issue, :admission_identity_mismatch)
  defp apply_current_admission_result(state, issue, {:error, reason}), do: admission_discard(state, issue, {:admission_read_failed, reason})

  defp admission_issue_current?(state, issue) do
    invalidated = state.admission_batch.invalidated

    not MapSet.member?(invalidated, issue.id) and not MapSet.member?(invalidated, issue.identifier) and
      not Map.has_key?(state.retry_attempts, issue.id) and
      (ManualIssueSpec.runtime_issue_id?(issue.id) or not tracker_backoff_active?(state)) and
      Map.get(RunnerRuntime.runner_health(), :dispatch_enabled, true) and
      is_nil(dispatch_skip_reason(issue, state)) and
      should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  defp admission_discard(state, issue, reason) do
    Logger.info("[admission] discarded issue_id=#{issue.id} reason=#{inspect(reason)}")
    %{state | candidate_fetch_error: reason}
  end

  defp invalidate_admission_issue(state, identifier, origin \\ nil) do
    identifier = String.trim(identifier)
    state = invalidate_tracker_inbox_issue(state, identifier, origin)

    state =
      if state.admission_batch,
        do: update_in(state.admission_batch.invalidated, &MapSet.put(&1, identifier)),
        else: state

    case state.admission_read do
      %{purpose: :promotion, issue: issue} when identifier in [issue.id, issue.identifier] ->
        release_issue_claim(state, issue.id)

      %{purpose: :retry, issue: issue} when identifier in [issue.id, issue.identifier] ->
        put_in(state.admission_read.invalidated, true)

      _ ->
        state
    end
  end

  defp maybe_warn_first_poll(%State{first_poll_completed: true} = state, _candidate_count),
    do: state

  defp maybe_warn_first_poll(%State{first_poll_completed: false} = state, candidate_count) do
    if candidate_count == 0 do
      assignee = Config.linear_assignee()

      if is_binary(assignee) and assignee != "" do
        Logger.warning(
          "[dispatch] First poll returned 0 candidates with assignee filter '#{assignee}'. " <>
            "Issues may not be assigned to this user."
        )
      end

      Logger.warning(
        "[dispatch] First poll returned 0 candidates. " <>
          "Query: project_slug=#{Config.linear_project_slug()} " <>
          "states=#{inspect(Config.linear_active_states())}"
      )
    end

    %{state | first_poll_completed: true}
  end

  defp block_candidate_policy_conflicts(%State{} = state, issues) when is_list(issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    Enum.reduce(issues, {state, []}, fn
      %Issue{} = issue, {%State{} = state_acc, remaining} ->
        if active_issue_state?(issue.state, active_states) and
             !terminal_issue_state?(issue.state, terminal_states) and
             match?({:error, _}, resolve_policy(issue, state_acc)) do
          {block_issue_for_policy_conflict(state_acc, issue), remaining}
        else
          {state_acc, [issue | remaining]}
        end

      issue, {%State{} = state_acc, remaining} ->
        {state_acc, [issue | remaining]}
    end)
    |> then(fn {state_acc, remaining} -> {state_acc, Enum.reverse(remaining)} end)
  end

  defp block_candidate_policy_conflicts(%State{} = state, _issues), do: {state, []}

  defp drain_tracker_events(%State{} = state) do
    cond do
      state.inbox_ack_pending -> confirm_tracker_inbox_prefix(state)
      state.tracker_inbox_batch -> resume_tracker_inbox(state)
      true -> capture_tracker_inbox(state)
    end
  end

  defp drain_github_events(%State{} = state) do
    fields = %{pending: :github_inbox_ack_pending, error: :github_inbox_storage_error, drained: :github_inbox_last_drained_at}
    drain_inbox(state, GitHubEventInbox, fields, &process_github_inbox_row/2)
  end

  defp process_github_inbox_row(state, {:ok, record}) do
    case decode_github_event_record(record) do
      %GitHubEvent{} = event -> {:ok, maybe_process_github_event(state, event)}
      _ -> {:drop, state}
    end
  end

  defp process_github_inbox_row(state, {:invalid, _reason}), do: {:drop, state}

  defp drain_inbox(state, inbox, fields, process_row) do
    if Map.get(state, fields.pending) do
      # Applied effects are not replayed when only their physical ack is pending.
      confirm_inbox_prefix(state, inbox, fields)
    else
      case inbox.capture(inbox.location(), %{max_rows: 100, max_bytes: 4 * 1024 * 1024}) do
        {:ok, batch} ->
          {state, cursor} =
            Enum.reduce_while(batch.rows, {state, nil}, fn row, {acc, _cursor} ->
              case process_row.(acc, row.record) do
                {:ok, next} -> {:cont, {next, row.cursor}}
                {:drop, next} -> {:cont, {next, row.cursor}}
              end
            end)

          finish_inbox_batch(state, inbox, fields, batch, cursor)

        {:error, error} ->
          inbox_storage_failed(state, fields, error)
      end
    end
  end

  defp finish_inbox_batch(state, inbox, fields, _batch, %SymphonyElixir.EventInbox.Cursor{} = cursor) do
    state |> Map.put(fields.pending, cursor) |> confirm_inbox_prefix(inbox, fields)
  end

  defp finish_inbox_batch(state, _inbox, fields, %{rows: [], tail: :none, limit_reached: false}, nil) do
    state |> Map.put(fields.error, nil) |> Map.put(fields.drained, DateTime.utc_now())
  end

  defp finish_inbox_batch(state, _inbox, fields, _batch, nil), do: Map.put(state, fields.error, nil)

  defp confirm_inbox_prefix(state, inbox, fields) do
    case inbox.ack(Map.fetch!(state, fields.pending)) do
      {:ok, _confirmation} ->
        state |> Map.put(fields.pending, nil) |> Map.put(fields.error, nil) |> Map.put(fields.drained, DateTime.utc_now())

      {:error, %{reason_code: :generation_changed} = error} ->
        state |> Map.put(fields.pending, nil) |> inbox_storage_failed(fields, error)

      {:error, error} ->
        inbox_storage_failed(state, fields, error)
    end
  end

  defp inbox_storage_failed(state, fields, error) do
    summary = SymphonyElixir.EventInbox.error_summary(error)
    Logger.error("Inbox storage failed phase=#{summary.phase} reason=#{summary.reason_code} confirmation=#{summary.confirmation}")
    Map.put(state, fields.error, summary)
  end

  defp inbox_snapshot(inbox, pending, error, drained_at) do
    inbox.stats()
    |> Map.put(:ack_pending, not is_nil(pending))
    |> Map.put(:last_storage_error, error)
    |> Map.put(:last_drained_at, datetime_to_iso8601(drained_at))
  end

  defp maybe_process_github_event(%State{} = state, %GitHubEvent{} = event) do
    cond do
      GitHubEvent.review_affecting?(event) ->
        {next_state, assignment} = refresh_pr_feedback_by_url(state, event)
        record_github_assignment(next_state, event, assignment)

      GitHubEvent.ci_failure_affecting?(event) ->
        {next_state, assignment} = refresh_pr_ci_failure_by_url(state, event)
        record_github_assignment(next_state, event, assignment)

      GitHubEvent.ci_affecting?(event) ->
        record_github_assignment(state, event, %{
          assignment_state: "ignored",
          assignment_reason: "non_failing_ci_event"
        })

      true ->
        record_github_assignment(state, event, %{
          assignment_state: "ignored",
          assignment_reason: "non_review_affecting_event"
        })
    end
  end

  defp refresh_pr_feedback_by_url(%State{} = state, %GitHubEvent{} = event) do
    pr_url = Map.get(event, :pr_url)

    if is_binary(pr_url) and pr_url != "" do
      refresh_pr_feedback_for_url(state, event, pr_url)
    else
      {state,
       %{
         assignment_state: "ignored",
         assignment_reason: "missing_pr_url"
       }}
    end
  end

  defp refresh_pr_feedback_for_url(%State{} = state, %GitHubEvent{} = event, pr_url)
       when is_binary(pr_url) and pr_url != "" do
    {next_state, outcomes} =
      Config.workspace_root()
      |> list_workspace_paths()
      |> Enum.reduce({state, []}, fn workspace, {state_acc, outcomes_acc} ->
        case RunStateStore.load(workspace) do
          {:ok, run_state} ->
            if Map.get(run_state, :pr_url) != pr_url or not canonical_github_workspace?(workspace, run_state) do
              {state_acc, outcomes_acc}
            else
              process_github_workspace_match(
                state_acc,
                workspace,
                run_state,
                pr_url,
                outcomes_acc
              )
            end

          _ ->
            {state_acc, outcomes_acc}
        end
      end)

    {next_state, summarize_github_assignment(event, pr_url, outcomes)}
  end

  defp refresh_pr_feedback_for_url(%State{} = state, _event, _pr_url) do
    {state, %{assignment_state: "ignored", assignment_reason: "missing_pr_url"}}
  end

  defp refresh_pr_ci_failure_by_url(%State{} = state, %GitHubEvent{} = event) do
    pr_url = Map.get(event, :pr_url)

    if is_binary(pr_url) and pr_url != "" do
      refresh_pr_ci_failure_for_url(state, event, pr_url)
    else
      {state,
       %{
         assignment_state: "ignored",
         assignment_reason: "missing_pr_url"
       }}
    end
  end

  defp refresh_pr_ci_failure_for_url(%State{} = state, %GitHubEvent{} = event, pr_url)
       when is_binary(pr_url) and pr_url != "" do
    {next_state, outcomes} =
      Config.workspace_root()
      |> list_workspace_paths()
      |> Enum.reduce({state, []}, fn workspace, {state_acc, outcomes_acc} ->
        case RunStateStore.load(workspace) do
          {:ok, run_state} ->
            if Map.get(run_state, :pr_url) != pr_url or not canonical_github_workspace?(workspace, run_state) do
              {state_acc, outcomes_acc}
            else
              process_github_ci_workspace_match(
                state_acc,
                workspace,
                run_state,
                pr_url,
                event,
                outcomes_acc
              )
            end

          _ ->
            {state_acc, outcomes_acc}
        end
      end)

    {next_state, summarize_github_assignment(event, pr_url, outcomes)}
  end

  defp refresh_pr_ci_failure_for_url(%State{} = state, _event, _pr_url) do
    {state, %{assignment_state: "ignored", assignment_reason: "missing_pr_url"}}
  end

  defp process_github_workspace_match(
         %State{} = state,
         workspace,
         run_state,
         pr_url,
         outcomes
       )
       when is_map(run_state) do
    issue_identifier = Map.get(run_state, :issue_identifier)
    target_runner_channel = Map.get(run_state, :runner_channel)
    runner_instance_id = Map.get(run_state, :runner_instance_id)
    lease_status = review_follow_up_lease_status(state, run_state, workspace)

    cond do
      not run_state_routed_to_current_runner?(run_state) ->
        Logger.info(
          "Skipping PR feedback refresh for workspace=#{workspace} pr_url=#{pr_url} runner_channel=#{target_runner_channel} runner_instance_id=#{runner_instance_id} current_channel=#{Config.runner_channel()} current_instance_id=#{RunnerRuntime.instance_id()}"
        )

        {state,
         [
           %{
             issue_identifier: issue_identifier,
             target_runner_channel: target_runner_channel,
             assigned_runner_channel: target_runner_channel,
             assigned_runner_instance_id: runner_instance_id,
             assignment_state: "routed_to_other_runner",
             assignment_reason: "run_state_owned_by_other_runner"
           }
           | outcomes
         ]}

      match?({:skip, _}, lease_status) ->
        {:skip, owner} = lease_status

        Logger.info("Skipping PR feedback refresh for workspace=#{workspace} pr_url=#{pr_url} lease_owner=#{inspect(owner)} current_owner=#{state.lease_owner}")

        {state,
         [
           %{
             issue_identifier: issue_identifier,
             target_runner_channel: target_runner_channel,
             assigned_runner_channel: Config.runner_channel(),
             assigned_runner_instance_id: RunnerRuntime.instance_id(),
             assignment_state: "leased_elsewhere",
             assignment_reason: "issue_lease_owned_by_other_runner",
             lease_owner: inspect(owner)
           }
           | outcomes
         ]}

      match?({:error, _}, lease_status) ->
        {:error, reason} = lease_status

        Logger.warning("Skipping PR feedback refresh for workspace=#{workspace} pr_url=#{pr_url} due to lease lookup error: #{inspect(reason)}")

        {state,
         [
           %{
             issue_identifier: issue_identifier,
             target_runner_channel: target_runner_channel,
             assigned_runner_channel: Config.runner_channel(),
             assigned_runner_instance_id: RunnerRuntime.instance_id(),
             assignment_state: "lease_lookup_error",
             assignment_reason: inspect(reason)
           }
           | outcomes
         ]}

      true ->
        {
          persist_review_feedback_for_workspace(state, workspace, run_state, pr_url),
          [
            %{
              issue_identifier: issue_identifier,
              target_runner_channel: target_runner_channel || Config.runner_channel(),
              assigned_runner_channel: Config.runner_channel(),
              assigned_runner_instance_id: RunnerRuntime.instance_id(),
              assignment_state:
                case lease_status do
                  {:reclaimable, _owner} -> "stale_lease_reclaimable"
                  _ -> "processed"
                end,
              assignment_reason:
                case lease_status do
                  {:reclaimable, _owner} ->
                    "review_feedback_persisted_pending_stale_lease_takeover"

                  _ ->
                    "review_feedback_persisted"
                end,
              lease_owner:
                case lease_status do
                  {:reclaimable, owner} -> inspect(owner)
                  _ -> nil
                end
            }
            | outcomes
          ]
        }
    end
  end

  defp process_github_workspace_match(%State{} = state, _workspace, _run_state, _pr_url, outcomes) do
    {state, outcomes}
  end

  defp process_github_ci_workspace_match(
         %State{} = state,
         workspace,
         run_state,
         pr_url,
         event,
         outcomes
       )
       when is_map(run_state) do
    issue_identifier = Map.get(run_state, :issue_identifier)
    target_runner_channel = Map.get(run_state, :runner_channel)
    runner_instance_id = Map.get(run_state, :runner_instance_id)
    lease_status = review_follow_up_lease_status(state, run_state, workspace)

    cond do
      not run_state_routed_to_current_runner?(run_state) ->
        {state,
         [
           %{
             issue_identifier: issue_identifier,
             target_runner_channel: target_runner_channel,
             assigned_runner_channel: target_runner_channel,
             assigned_runner_instance_id: runner_instance_id,
             assignment_state: "routed_to_other_runner",
             assignment_reason: "run_state_owned_by_other_runner"
           }
           | outcomes
         ]}

      match?({:skip, _}, lease_status) ->
        {:skip, owner} = lease_status

        {state,
         [
           %{
             issue_identifier: issue_identifier,
             target_runner_channel: target_runner_channel,
             assigned_runner_channel: Config.runner_channel(),
             assigned_runner_instance_id: RunnerRuntime.instance_id(),
             assignment_state: "leased_elsewhere",
             assignment_reason: "issue_lease_owned_by_other_runner",
             lease_owner: inspect(owner)
           }
           | outcomes
         ]}

      match?({:error, _}, lease_status) ->
        {:error, reason} = lease_status

        {state,
         [
           %{
             issue_identifier: issue_identifier,
             target_runner_channel: target_runner_channel,
             assigned_runner_channel: Config.runner_channel(),
             assigned_runner_instance_id: RunnerRuntime.instance_id(),
             assignment_state: "lease_lookup_error",
             assignment_reason: inspect(reason)
           }
           | outcomes
         ]}

      true ->
        {
          persist_ci_failure_for_workspace(state, workspace, run_state, pr_url, event),
          [
            %{
              issue_identifier: issue_identifier,
              target_runner_channel: target_runner_channel || Config.runner_channel(),
              assigned_runner_channel: Config.runner_channel(),
              assigned_runner_instance_id: RunnerRuntime.instance_id(),
              assignment_state:
                case lease_status do
                  {:reclaimable, _owner} -> "stale_lease_reclaimable"
                  _ -> "processed"
                end,
              assignment_reason:
                case lease_status do
                  {:reclaimable, _owner} ->
                    "ci_failure_persisted_pending_stale_lease_takeover"

                  _ ->
                    "ci_failure_persisted"
                end,
              lease_owner:
                case lease_status do
                  {:reclaimable, owner} -> inspect(owner)
                  _ -> nil
                end
            }
            | outcomes
          ]
        }
    end
  end

  defp process_github_ci_workspace_match(%State{} = state, _workspace, _run_state, _pr_url, _event, outcomes) do
    {state, outcomes}
  end

  defp summarize_github_assignment(%GitHubEvent{} = event, pr_url, outcomes)
       when is_list(outcomes) do
    preferred_outcome =
      Enum.find_value(
        [
          "stale_lease_reclaimable",
          "processed",
          "leased_elsewhere",
          "routed_to_other_runner",
          "lease_lookup_error"
        ],
        fn target_state ->
          Enum.find(outcomes, &(Map.get(&1, :assignment_state) == target_state))
        end
      )

    base = %{
      event_id: Map.get(event, :event_id),
      event_name: Map.get(event, :event_name),
      action: Map.get(event, :action),
      pr_url: pr_url,
      repo_full_name: Map.get(event, :repo_full_name),
      received_runner_channel: Map.get(event, :received_runner_channel) || Config.runner_channel(),
      received_runner_instance_id: Map.get(event, :received_runner_instance_id) || RunnerRuntime.instance_id(),
      matched_run_states: length(outcomes),
      processed_at: datetime_to_iso8601(DateTime.utc_now())
    }

    case preferred_outcome do
      nil ->
        Map.merge(base, %{
          assignment_state: "unmatched_pr",
          assignment_reason: "no_workspace_for_pr"
        })

      %{} = outcome ->
        Map.merge(base, outcome)
    end
  end

  defp record_github_assignment(%State{} = state, %GitHubEvent{} = event, attrs)
       when is_map(attrs) do
    assignment =
      attrs
      |> Map.put_new(:event_id, Map.get(event, :event_id))
      |> Map.put_new(:event_name, Map.get(event, :event_name))
      |> Map.put_new(:action, Map.get(event, :action))
      |> Map.put_new(:pr_url, Map.get(event, :pr_url))
      |> Map.put_new(:repo_full_name, Map.get(event, :repo_full_name))
      |> Map.put_new(:conclusion, Map.get(event, :conclusion))
      |> Map.put_new(:check_name, Map.get(event, :check_name))
      |> Map.put_new(:details_url, Map.get(event, :details_url))
      |> Map.put_new(:received_runner_channel, Map.get(event, :received_runner_channel))
      |> Map.put_new(:received_runner_instance_id, Map.get(event, :received_runner_instance_id))
      |> Map.put_new(:processed_at, datetime_to_iso8601(DateTime.utc_now()))

    %{state | github_last_assignment: assignment}
  end

  defp run_state_routed_to_current_runner?(run_state) when is_map(run_state) do
    channel = Map.get(run_state, :runner_channel)
    instance_id = Map.get(run_state, :runner_instance_id)

    channel_matches? = not present?(channel) or channel == Config.runner_channel()
    instance_matches? = not present?(instance_id) or instance_id == RunnerRuntime.instance_id()

    channel_matches? and instance_matches?
  end

  defp review_follow_up_lease_status(%State{} = state, run_state, workspace) when is_map(run_state) do
    with {:ok, _issue, storage, claim} <- follow_up_location(state, run_state, workspace) do
      case LeaseManager.read_at(storage) do
        {:ok, lease} ->
          owner = lease["owner"]

          cond do
            not is_nil(claim) and claim.holder in [:pending, :gated] ->
              {:skip, :lease_attempt_pending}

            not is_nil(claim) and lease["owner"] == claim.token.owner and lease["epoch"] == claim.token.epoch and
              lease["lease_generation"] == claim.token.lease_generation and lease["acquired_at"] == claim.token.acquired_at ->
              :ok

            LeaseManager.reclaimable?(lease, DateTime.utc_now(), ttl_ms: storage.ttl_ms) ->
              {:reclaimable, owner}

            true ->
              {:skip, owner}
          end

        {:error, :missing} when is_nil(claim) ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp follow_up_location(state, run_state, workspace) do
    issue = issue_ref_for_run_state(run_state)

    cond do
      not present?(issue.id) ->
        {:error, :missing_issue_id}

      not is_binary(workspace) ->
        {:error, :lease_workspace_changed}

      true ->
        case Map.get(state.lease_claims, issue.id) do
          %{workspace: captured_workspace, token: token} = claim ->
            if Path.expand(workspace) == Path.expand(captured_workspace), do: {:ok, issue, token.storage, claim}, else: {:error, :lease_workspace_changed}

          nil ->
            with {:ok, context} <- capture_tracker_poll_context(),
                 true <- Path.expand(workspace) == Path.expand(Workspace.path_for_issue(issue)) or {:error, :lease_workspace_changed},
                 {:ok, storage} <- LeaseManager.capture_storage(issue.id),
                 {:ok, current} <- capture_tracker_poll_context(),
                 true <- context.fingerprint == current.fingerprint or {:error, :lease_workspace_changed} do
              {:ok, issue, storage, nil}
            end
        end
    end
  end

  defp persist_review_feedback_for_workspace(%State{} = state, workspace, run_state, pr_url) do
    feedback =
      PRWatcher.review_feedback(
        workspace,
        policy_pack: PolicyPack.name_string(PolicyPack.resolve()),
        thread_states: Map.get(run_state, :review_threads, %{}),
        pr_url: pr_url
      )

    if Map.get(feedback, :status) == "ok" and Map.get(feedback, :pending_drafts_count, 0) > 0 do
      review_claims =
        feedback
        |> Map.get(:items, [])
        |> Enum.reduce(Map.get(run_state, :review_claims, %{}), fn item, acc ->
          case Map.get(item, :thread_key) do
            thread_key when is_binary(thread_key) ->
              persisted = Map.get(acc, thread_key, %{})

              verification_status = review_claim_verification_status(persisted, item)

              claim_state = %{
                "thread_key" => Map.get(item, :thread_key),
                "id" => Map.get(item, :id),
                "kind" => Map.get(item, :kind) |> to_string(),
                "author" => Map.get(item, :author),
                "body" => Map.get(item, :body),
                "path" => Map.get(item, :path),
                "line" => Map.get(item, :line),
                "state" => Map.get(item, :state),
                "review_decision" => Map.get(item, :review_decision),
                "submitted_at" => Map.get(item, :submitted_at),
                "source_class" => Map.get(item, :source_class),
                "claim_type" => Map.get(item, :claim_type),
                "veracity_score" => Map.get(item, :veracity_score),
                "reproducibility_score" => Map.get(item, :reproducibility_score),
                "evidence_quality_score" => Map.get(item, :evidence_quality_score),
                "locality_score" => Map.get(item, :locality_score),
                "source_precision_score" => Map.get(item, :source_precision_score),
                "consensus_score" => Map.get(item, :consensus_score),
                "consensus_state" => Map.get(item, :consensus_state),
                "consensus_summary" => Map.get(item, :consensus_summary),
                "consensus_reasons" => Map.get(item, :consensus_reasons, []),
                "historical_precision_score" => Map.get(item, :historical_precision_score),
                "stagnation_score" => Map.get(item, :stagnation_score),
                "stagnation_state" => Map.get(item, :stagnation_state),
                "repeated_feedback_count" => Map.get(item, :repeated_feedback_count, 1),
                "hard_proof" => Map.get(item, :hard_proof, false),
                "proof_sources" => Map.get(item, :proof_sources, []),
                "contradiction_sources" => Map.get(item, :contradiction_sources, []),
                "disposition" => Map.get(item, :disposition),
                "actionable" => Map.get(item, :actionable, false),
                "adjudication_summary" => Map.get(item, :adjudication_summary),
                "verification_status" => verification_status,
                "verification_attempts" => Map.get(persisted, "verification_attempts", 0),
                "evidence_refs" => Map.get(persisted, "evidence_refs", []),
                "evidence_summary" => Map.get(persisted, "evidence_summary"),
                "pr_url" => pr_url
              }

              Map.put(acc, thread_key, claim_state)

            _ ->
              acc
          end
        end)

      review_threads =
        feedback
        |> Map.get(:items, [])
        |> Enum.reduce(Map.get(run_state, :review_threads, %{}), fn item, acc ->
          case Map.get(item, :thread_key) do
            thread_key when is_binary(thread_key) ->
              Map.put(acc, thread_key, review_thread_state(item, pr_url))

            _ ->
              acc
          end
        end)

      issue = issue_for_run_state(run_state)

      case maybe_start_autonomous_review_follow_up(
             state,
             issue,
             workspace,
             run_state,
             pr_url,
             feedback,
             review_threads,
             review_claims
           ) do
        {:ok, next_state} ->
          next_state

        {:ok, next_state, :non_actionable} ->
          next_state

        {:not_autonomous, state} ->
          summary = "New PR review feedback detected on #{pr_url}."

          human_action =
            "Review drafted replies and decide whether to address code changes or post a response."

          case RunStateStore.update(workspace, fn persisted ->
                 persisted
                 |> Map.put(:review_threads, review_threads)
                 |> Map.put(:review_claims, review_claims)
                 |> Map.put(:last_review_decision, Map.get(feedback, :review_decision))
                 |> Map.put(:last_decision_summary, summary)
                 |> Map.put(:next_human_action, human_action)
                 |> put_review_resume_context(pr_url, review_threads, review_claims, nil)
               end) do
            {:ok, next_run_state} ->
              RunLedger.record("review.feedback_detected", %{
                issue_id: Map.get(next_run_state, :issue_id),
                issue_identifier: Map.get(next_run_state, :issue_identifier),
                actor_type: "runtime",
                actor_id: "github_webhook",
                summary: summary,
                details: pr_url,
                metadata: %{
                  pending_drafts_count: Map.get(feedback, :pending_drafts_count, 0),
                  review_decision: Map.get(feedback, :review_decision)
                }
              })

              state

            {:error, reason} ->
              Logger.warning("Failed to persist manual review feedback for #{pr_url}: #{inspect(reason)}")

              state
          end
      end
    else
      state
    end
  end

  defp persist_ci_failure_for_workspace(
         %State{} = state,
         workspace,
         run_state,
         pr_url,
         %GitHubEvent{} = event
       ) do
    issue = issue_for_run_state(run_state)
    ci_failure = ci_failure_payload(event, pr_url)

    case maybe_start_autonomous_ci_follow_up(state, issue, workspace, run_state, pr_url, ci_failure) do
      {:ok, next_state} ->
        next_state

      {:not_autonomous, state} ->
        summary = "GitHub CI failure detected on #{pr_url}: #{ci_failure_summary(ci_failure)}."

        human_action =
          "Inspect the failing GitHub checks and decide whether Symphony should reopen implementation."

        case RunStateStore.update(workspace, fn persisted ->
               persisted
               |> Map.put(:last_ci_failure, ci_failure)
               |> Map.put(:last_decision_summary, summary)
               |> Map.put(:next_human_action, human_action)
               |> Map.put(:resume_context, ci_resume_context(Map.get(persisted, :resume_context), pr_url, ci_failure))
             end) do
          {:ok, next_run_state} ->
            RunLedger.record("ci.failure_detected", %{
              issue_id: Map.get(next_run_state, :issue_id),
              issue_identifier: Map.get(next_run_state, :issue_identifier),
              actor_type: "runtime",
              actor_id: "github_webhook",
              summary: summary,
              details: Map.get(ci_failure, :details_url) || pr_url,
              metadata: ci_failure
            })

            state

          {:error, reason} ->
            Logger.warning("Failed to persist CI failure for #{pr_url}: #{inspect(reason)}")
            state
        end
    end
  end

  defp maybe_start_autonomous_ci_follow_up(
         %State{} = state,
         issue,
         workspace,
         run_state,
         pr_url,
         ci_failure
       ) do
    if autonomous_review_follow_up?(state, issue, run_state, workspace) do
      summary = "GitHub CI failure detected on #{pr_url}. Returning to implement to fix failing checks."

      next_objective =
        "Investigate and fix the failing GitHub checks on #{pr_url}. Focus first on #{ci_failure_summary(ci_failure)} and return the branch to runtime validation."

      case ensure_review_follow_up_lease(state, run_state, workspace) do
        {:ok, state, lease_attrs, release_on_failure?} ->
          case RunStateStore.transition(
                 workspace,
                 "implement",
                 %{
                   issue_id: Map.get(run_state, :issue_id),
                   issue_identifier: Map.get(run_state, :issue_identifier),
                   issue_source: Map.get(run_state, :issue_source),
                   pr_url: pr_url,
                   stop_reason: nil,
                   last_decision: nil,
                   last_rule_id: nil,
                   last_failure_class: nil,
                   last_decision_summary: summary,
                   next_human_action: nil,
                   await_checks_polls: 0,
                   last_ci_failure: ci_failure,
                   resume_context:
                     ci_resume_context(
                       Map.get(run_state, :resume_context),
                       pr_url,
                       Map.put(ci_failure, :next_objective, next_objective)
                     )
                 }
                 |> Map.merge(lease_attrs)
               ) do
            {:ok, _next_run_state} ->
              issue_ref = issue_ref_for_run_state(run_state)
              _ = IssueSource.update_issue_state(issue || issue_ref, "In Progress")

              refreshed_issue =
                case issue do
                  %Issue{} = existing_issue ->
                    case IssueSource.refresh_issue(existing_issue) do
                      {:ok, %Issue{} = latest_issue} -> latest_issue
                      _ -> %{existing_issue | state: "In Progress"}
                    end

                  _ ->
                    nil
                end

              RunLedger.record("ci.failure_autonomous_follow_up", %{
                issue_id: Map.get(run_state, :issue_id),
                issue_identifier: Map.get(run_state, :issue_identifier),
                actor_type: "runtime",
                actor_id: "github_webhook",
                summary: summary,
                details: Map.get(ci_failure, :details_url) || pr_url,
                metadata: ci_failure
              })

              {:ok, maybe_dispatch_autonomous_review_follow_up(state, refreshed_issue)}

            {:error, reason} ->
              state = if release_on_failure?, do: release_review_follow_up_lease(state, run_state, workspace), else: state

              Logger.warning("Failed to transition #{pr_url} back to implement after CI failure: #{inspect(reason)}")
              {:not_autonomous, state}
          end

        {:skip, owner} ->
          Logger.info("Skipping autonomous CI follow-up for #{pr_url}; lease is owned by #{inspect(owner)}")
          {:not_autonomous, state}

        {:error, reason} ->
          Logger.warning("Unable to secure lease for autonomous CI follow-up on #{pr_url}: #{inspect(reason)}")
          {:ok, state}
      end
    else
      {:not_autonomous, state}
    end
  end

  defp ci_failure_payload(%GitHubEvent{} = event, pr_url) do
    %{
      event_name: Map.get(event, :event_name),
      action: Map.get(event, :action),
      check_name: Map.get(event, :check_name),
      conclusion: Map.get(event, :conclusion),
      details_url: Map.get(event, :details_url),
      head_sha: Map.get(event, :head_sha),
      pr_url: pr_url,
      summary: GitHubEvent.failure_summary(event)
    }
  end

  defp ci_resume_context(current_context, pr_url, ci_failure) when is_map(ci_failure) do
    context =
      case current_context do
        value when is_map(value) -> value
        _ -> %{}
      end

    context
    |> Map.put(:ci_failure_summary, ci_failure_summary(ci_failure))
    |> Map.put(:ci_failure_pr_url, pr_url)
    |> Map.put(:ci_failure_details_url, Map.get(ci_failure, :details_url))
    |> maybe_put_context_value(:next_objective, Map.get(ci_failure, :next_objective))
  end

  defp ci_failure_summary(ci_failure) when is_map(ci_failure) do
    Map.get(ci_failure, :summary) ||
      GitHubEvent.failure_summary(%GitHubEvent{
        provider: "github",
        event_name: to_string(Map.get(ci_failure, :event_name) || ""),
        action: to_string(Map.get(ci_failure, :action) || ""),
        raw: %{},
        conclusion: Map.get(ci_failure, :conclusion),
        check_name: Map.get(ci_failure, :check_name)
      }) ||
      "failing required checks"
  end

  defp maybe_put_context_value(context, _key, value) when value in [nil, ""], do: context
  defp maybe_put_context_value(context, key, value), do: Map.put(context, key, value)

  defp review_thread_state(item, pr_url) when is_map(item) do
    %{
      "thread_key" => Map.get(item, :thread_key),
      "id" => Map.get(item, :id),
      "kind" => Map.get(item, :kind) |> to_string(),
      "author" => Map.get(item, :author),
      "body" => Map.get(item, :body),
      "path" => Map.get(item, :path),
      "line" => Map.get(item, :line),
      "state" => Map.get(item, :state),
      "review_decision" => Map.get(item, :review_decision),
      "submitted_at" => Map.get(item, :submitted_at),
      "draft_state" => Map.get(item, :draft_state, "drafted"),
      "draft_reply" => Map.get(item, :draft_reply),
      "resolution_recommendation" => Map.get(item, :resolution_recommendation),
      "source_class" => Map.get(item, :source_class),
      "claim_type" => Map.get(item, :claim_type),
      "veracity_score" => Map.get(item, :veracity_score),
      "reproducibility_score" => Map.get(item, :reproducibility_score),
      "evidence_quality_score" => Map.get(item, :evidence_quality_score),
      "locality_score" => Map.get(item, :locality_score),
      "source_precision_score" => Map.get(item, :source_precision_score),
      "consensus_score" => Map.get(item, :consensus_score),
      "consensus_state" => Map.get(item, :consensus_state),
      "consensus_summary" => Map.get(item, :consensus_summary),
      "consensus_reasons" => Map.get(item, :consensus_reasons, []),
      "historical_precision_score" => Map.get(item, :historical_precision_score),
      "stagnation_score" => Map.get(item, :stagnation_score),
      "stagnation_state" => Map.get(item, :stagnation_state),
      "repeated_feedback_count" => Map.get(item, :repeated_feedback_count, 1),
      "hard_proof" => Map.get(item, :hard_proof, false),
      "proof_sources" => Map.get(item, :proof_sources, []),
      "contradiction_sources" => Map.get(item, :contradiction_sources, []),
      "disposition" => Map.get(item, :disposition),
      "actionable" => Map.get(item, :actionable, false),
      "adjudication_summary" => Map.get(item, :adjudication_summary),
      "pr_url" => pr_url
    }
  end

  defp review_claim_verification_status(persisted, item)
       when is_map(persisted) and is_map(item) do
    persisted_status = Map.get(persisted, "verification_status")
    disposition = Map.get(item, :disposition)

    cond do
      disposition == "needs_verification" and
          persisted_status in [nil, "", "not_needed", "contradicted"] ->
        "pending"

      is_binary(persisted_status) and persisted_status != "" ->
        persisted_status

      disposition == "needs_verification" ->
        "pending"

      true ->
        "not_needed"
    end
  end

  defp issue_for_run_state(run_state) when is_map(run_state) do
    case IssueSource.fetch_issue(issue_ref_for_run_state(run_state)) do
      {:ok, %Issue{} = issue} -> issue
      _ -> seeded_manual_issue_from_run_state(run_state)
    end
  end

  @doc false
  @spec seeded_manual_issue_from_run_state(map()) :: map() | nil
  def seeded_manual_issue_from_run_state(run_state) when is_map(run_state) do
    source = normalize_issue_source(Map.get(run_state, :issue_source))
    issue_id = Map.get(run_state, :issue_id)
    issue_identifier = Map.get(run_state, :issue_identifier)

    policy_class =
      Map.get(run_state, :effective_policy_class) || Map.get(run_state, :policy_class)

    if source == :manual and is_binary(policy_class) and policy_class != "" and
         is_binary(issue_id) and
         issue_id != "" and is_binary(issue_identifier) and
         issue_identifier != "" do
      %Issue{
        id: issue_id,
        external_id: issue_id,
        canonical_identifier: issue_identifier,
        identifier: issue_identifier,
        title:
          Map.get(run_state, :issue_title) ||
            "Seeded local replay for #{issue_identifier}",
        state: seeded_manual_issue_state(run_state),
        source: :manual,
        branch_name: seeded_manual_issue_branch_name(run_state, issue_identifier),
        labels: seeded_manual_issue_labels(run_state),
        assigned_to_worker: true
      }
    else
      nil
    end
  end

  defp seeded_manual_issue_labels(run_state) when is_map(run_state) do
    labels =
      run_state
      |> Map.get(:issue_labels, [])
      |> List.wrap()

    if seeded_manual_issue_target_runner_channel(run_state) == "canary" do
      labels
      |> Kernel.++(RunnerRuntime.canary_required_labels(%{}))
      |> normalize_labels()
      |> MapSet.to_list()
    else
      labels
    end
  end

  defp seeded_manual_issue_target_runner_channel(run_state) when is_map(run_state) do
    case Map.get(run_state, :target_runner_channel) || Map.get(run_state, :runner_channel) do
      "canary" -> "canary"
      _ -> "stable"
    end
  end

  defp seeded_manual_issue_state(run_state) when is_map(run_state) do
    case Map.get(run_state, :stage) do
      "blocked" ->
        @blocked_state

      "done" ->
        "Done"

      _ ->
        Map.get(run_state, :issue_state) || "In Progress"
    end
  end

  defp seeded_manual_issue_branch_name(run_state, issue_identifier) when is_map(run_state) do
    branch_name =
      Map.get(run_state, :branch_name) ||
        Map.get(run_state, :branch) ||
        workspace_branch_name(issue_identifier)

    case branch_name do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp workspace_branch_name(issue_identifier) when is_binary(issue_identifier) do
    issue_identifier
    |> Workspace.path_for_issue()
    |> RunInspector.inspect()
    |> Map.get(:branch)
  end

  defp workspace_branch_name(_issue_identifier), do: nil

  defp issue_ref_for_run_state(run_state) when is_map(run_state) do
    %{
      source: normalize_issue_source(Map.get(run_state, :issue_source)),
      id: Map.get(run_state, :issue_id),
      identifier: Map.get(run_state, :issue_identifier)
    }
  end

  defp normalize_issue_source(value) when value in [:manual, :tracker], do: value

  defp normalize_issue_source(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "manual" -> :manual
      "tracker" -> :tracker
      _ -> nil
    end
  end

  defp normalize_issue_source(_value), do: nil

  defp maybe_start_autonomous_review_follow_up(
         %State{} = state,
         issue,
         workspace,
         run_state,
         pr_url,
         feedback,
         review_threads,
         review_claims
       ) do
    if autonomous_review_follow_up?(state, issue, run_state, workspace) and
         PRWatcher.actionable_feedback?(feedback) do
      target_stage = PRWatcher.follow_up_stage(feedback)

      next_objective =
        case target_stage do
          "review_verification" ->
            "Verify the pending GitHub review feedback on #{pr_url}, collect local evidence, and reopen implementation only for verified claims."

          _ ->
            "Address the pending GitHub review feedback on #{pr_url}, update the code, and return the branch to runtime validation."
        end

      summary =
        case target_stage do
          "review_verification" ->
            "GitHub review feedback detected on #{pr_url}. Returning to review_verification before reopening implementation."

          _ ->
            "GitHub review feedback detected on #{pr_url}. Returning to implement to address the requested changes."
        end

      case ensure_review_follow_up_lease(state, run_state, workspace) do
        {:ok, state, lease_attrs, release_on_failure?} ->
          case RunStateStore.transition(
                 workspace,
                 target_stage,
                 %{
                   issue_id: Map.get(run_state, :issue_id),
                   issue_identifier: Map.get(run_state, :issue_identifier),
                   issue_source: Map.get(run_state, :issue_source),
                   pr_url: pr_url,
                   review_threads: review_threads,
                   review_claims: review_claims,
                   review_return_stage: Map.get(run_state, :stage),
                   last_review_decision: Map.get(feedback, :review_decision),
                   stop_reason: nil,
                   last_decision: nil,
                   last_rule_id: nil,
                   last_failure_class: nil,
                   last_decision_summary: summary,
                   next_human_action: nil,
                   resume_context:
                     review_resume_context(
                       Map.get(run_state, :resume_context),
                       pr_url,
                       review_threads,
                       review_claims,
                       next_objective
                     )
                 }
                 |> Map.merge(lease_attrs)
               ) do
            {:ok, _next_run_state} ->
              issue_ref = issue_ref_for_run_state(run_state)
              _ = IssueSource.update_issue_state(issue || issue_ref, "In Progress")

              refreshed_issue =
                case issue do
                  %Issue{} = existing_issue ->
                    case IssueSource.refresh_issue(existing_issue) do
                      {:ok, %Issue{} = latest_issue} -> latest_issue
                      _ -> %{existing_issue | state: "In Progress"}
                    end

                  _ ->
                    nil
                end

              RunLedger.record("review.feedback_autonomous_follow_up", %{
                issue_id: Map.get(run_state, :issue_id),
                issue_identifier: Map.get(run_state, :issue_identifier),
                actor_type: "runtime",
                actor_id: "github_webhook",
                summary: summary,
                details: pr_url,
                metadata: %{
                  review_decision: Map.get(feedback, :review_decision),
                  pending_drafts_count: Map.get(feedback, :pending_drafts_count, 0),
                  target_stage: target_stage
                }
              })

              {:ok, maybe_dispatch_autonomous_review_follow_up(state, refreshed_issue)}

            {:error, reason} ->
              state = if release_on_failure?, do: release_review_follow_up_lease(state, run_state, workspace), else: state

              Logger.warning("Failed to transition #{pr_url} back to implement after review feedback: #{inspect(reason)}")

              {:not_autonomous, state}
          end

        {:skip, owner} ->
          Logger.info("Skipping autonomous PR review follow-up for #{pr_url}; lease is owned by #{inspect(owner)}")

          {:not_autonomous, state}

        {:error, reason} ->
          Logger.warning("Unable to secure lease for autonomous PR review follow-up on #{pr_url}: #{inspect(reason)}")

          {:ok, state}
      end
    else
      case {autonomous_review_follow_up?(state, issue, run_state, workspace), PRWatcher.actionable_feedback?(feedback)} do
        {true, false} ->
          summary =
            "GitHub review feedback detected on #{pr_url}, but the current adjudicator triaged it as non-actionable noise."

          case RunStateStore.update(workspace, fn persisted ->
                 persisted
                 |> Map.put(:review_threads, review_threads)
                 |> Map.put(:review_claims, review_claims)
                 |> Map.put(:last_review_decision, Map.get(feedback, :review_decision))
                 |> Map.put(:last_decision_summary, summary)
                 |> Map.put(:next_human_action, nil)
                 |> put_review_resume_context(pr_url, review_threads, review_claims, nil)
               end) do
            {:ok, next_run_state} ->
              RunLedger.record("review.feedback_triaged", %{
                issue_id: Map.get(next_run_state, :issue_id),
                issue_identifier: Map.get(next_run_state, :issue_identifier),
                actor_type: "runtime",
                actor_id: "github_webhook",
                summary: summary,
                details: pr_url,
                metadata: %{
                  pending_drafts_count: Map.get(feedback, :pending_drafts_count, 0),
                  actionable_items_count: Map.get(feedback, :actionable_items_count, 0),
                  review_decision: Map.get(feedback, :review_decision)
                }
              })

              {:ok, state, :non_actionable}

            {:error, reason} ->
              Logger.warning("Failed to persist non-actionable review triage for #{pr_url}: #{inspect(reason)}")

              {:not_autonomous, state}
          end

        _ ->
          {:not_autonomous, state}
      end
    end
  end

  defp autonomous_review_follow_up?(%State{} = state, issue, run_state, workspace) when is_map(run_state) do
    stage = Map.get(run_state, :stage)

    policy_class =
      Map.get(run_state, :effective_policy_class) ||
        case issue do
          %Issue{} = resolved_issue ->
            elem(policy_snapshot_values(resolved_issue, state, run_state), 0)

          _ ->
            nil
        end

    policy_class == "fully_autonomous" and
      run_state_routed_to_current_runner?(run_state) and
      case review_follow_up_lease_status(state, run_state, workspace) do
        :ok -> true
        {:reclaimable, _owner} -> true
        _ -> false
      end and
      stage not in [
        "done",
        "post_merge",
        "deploy_preview",
        "deploy_production",
        "post_deploy_verify"
      ] and
      not paused_issue?(state, issue, run_state)
  end

  defp autonomous_review_follow_up?(_state, _issue, _run_state, _workspace), do: false

  defp paused_issue?(%State{} = state, %Issue{id: issue_id}, _run_state)
       when is_binary(issue_id) do
    Map.has_key?(state.paused_issue_states, issue_id)
  end

  defp paused_issue?(%State{} = state, _issue, run_state) when is_map(run_state) do
    case Map.get(run_state, :issue_id) do
      issue_id when is_binary(issue_id) -> Map.has_key?(state.paused_issue_states, issue_id)
      _ -> false
    end
  end

  defp maybe_dispatch_autonomous_review_follow_up(%State{} = state, %Issue{} = issue) do
    cond do
      Map.has_key?(state.running, issue.id) ->
        state

      retry_candidate_issue?(issue, terminal_state_set()) and
          dispatch_slots_available?(issue, state) ->
        dispatch_runtime_issue(state, issue, nil)

      true ->
        :ok = schedule_tick(0)
        state
    end
  end

  defp maybe_dispatch_autonomous_review_follow_up(%State{} = state, _issue) do
    :ok = schedule_tick(0)
    state
  end

  defp put_review_resume_context(run_state, pr_url, review_threads, review_claims, next_objective)
       when is_map(run_state) do
    Map.put(
      run_state,
      :resume_context,
      review_resume_context(
        Map.get(run_state, :resume_context),
        pr_url,
        review_threads,
        review_claims,
        next_objective
      )
    )
  end

  defp review_resume_context(
         current_context,
         pr_url,
         review_threads,
         review_claims,
         next_objective
       ) do
    context =
      case current_context do
        value when is_map(value) -> value
        _ -> %{}
      end

    context =
      context
      |> Map.put(:review_feedback_summary, review_feedback_summary(review_threads))
      |> Map.put(:review_claim_summary, ReviewEvidenceCollector.summary(review_claims))
      |> Map.put(:review_feedback_pr_url, pr_url)

    if is_binary(next_objective) and String.trim(next_objective) != "" do
      Map.put(context, :next_objective, next_objective)
    else
      context
    end
  end

  defp review_feedback_summary(review_threads) when is_map(review_threads) do
    review_threads
    |> Enum.sort_by(fn {thread_key, _thread_state} -> thread_key end)
    |> Enum.take(8)
    |> Enum.map(fn {_thread_key, thread_state} ->
      kind = Map.get(thread_state, "kind") || "comment"

      location =
        case {Map.get(thread_state, "path"), Map.get(thread_state, "line")} do
          {path, line} when is_binary(path) and is_integer(line) -> " #{path}:#{line}"
          {path, _line} when is_binary(path) -> " #{path}"
          _ -> ""
        end

      body =
        thread_state
        |> Map.get("body")
        |> to_string()
        |> String.trim()
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 280)

      "- #{kind}#{location}: #{body}"
    end)
    |> Enum.reject(&String.ends_with?(&1, ": "))
    |> Enum.join("\n")
    |> case do
      "" -> nil
      summary -> summary
    end
  end

  defp review_feedback_summary(_review_threads), do: nil

  # One physical batch and one head survive asynchronous lookup, admission and gate.
  # Only the checked cursor returned by capture can become an ack intention.
  defp tracker_inbox_phase(%{tracker_inbox_batch: %{head: %{phase: phase}}}), do: phase
  defp tracker_inbox_phase(%{inbox_ack_pending: cursor}) when not is_nil(cursor), do: :ack_pending
  defp tracker_inbox_phase(_state), do: :idle

  defp tracker_inbox_limits, do: %{max_rows: 100, max_bytes: 4 * 1024 * 1024}

  defp reconcile_tracker_inbox_context(%{tracker_inbox_batch: nil} = state), do: state
  defp reconcile_tracker_inbox_context(%{tracker_inbox_batch: %{head: %{phase: :blocked, retryable: false}}} = state), do: state

  defp reconcile_tracker_inbox_context(state) do
    case capture_tracker_poll_context() do
      {:ok, context} ->
        if state.tracker_inbox_batch.location == TrackerEventInbox.location() and state.tracker_inbox_batch.fingerprint == context.fingerprint,
          do: state,
          else: retire_tracker_inbox(state, :tracker_inbox_context_changed)

      {:error, reason} ->
        retire_tracker_inbox(state, reason)
    end
  end

  defp capture_tracker_inbox(state) do
    with {:ok, context} <- capture_tracker_poll_context(),
         {:ok, captured} <- TrackerEventInbox.capture(TrackerEventInbox.location(), tracker_inbox_limits()) do
      case captured.rows do
        [] ->
          if captured.tail == :none and not captured.limit_reached,
            do: %{state | inbox_storage_error: nil, inbox_last_drained_at: DateTime.utc_now()},
            else: %{state | inbox_storage_error: nil}

        rows ->
          batch = Map.merge(captured, %{ref: make_ref(), fingerprint: context.fingerprint, head: nil, applied_cursor: nil, end_offset: List.last(rows).cursor.end_offset})
          resume_tracker_inbox(%{state | tracker_inbox_batch: batch, inbox_storage_error: nil})
      end
    else
      {:error, reason} -> block_tracker_inbox(state, reason)
    end
  end

  defp resume_tracker_inbox(%{tracker_inbox_batch: %{head: %{phase: :blocked, retryable: false}}} = state), do: state

  defp resume_tracker_inbox(state) do
    with {:ok, context} <- capture_tracker_poll_context(),
         true <- TrackerEventInbox.location() == state.tracker_inbox_batch.location and context.fingerprint == state.tracker_inbox_batch.fingerprint,
         {:ok, state} <- rebind_tracker_inbox_prefix(state) do
      state = if tracker_inbox_reader_active?(state), do: state, else: discard_tracker_inbox_prefix(state, context)
      state = ensure_tracker_inbox_head(state, context)

      case state.tracker_inbox_batch do
        %{head: nil} -> yield_tracker_inbox(state)
        %{head: %{phase: :blocked, retryable: true}} -> start_tracker_inbox_lookup(reset_tracker_inbox_head(state), context)
        %{head: %{phase: phase}} when phase in [:lookup_ready, :backoff] -> start_tracker_inbox_lookup(state, context)
        %{head: %{phase: :admission_ready}} -> advance_admission(state, context)
        _ -> state
      end
    else
      false -> retire_tracker_inbox(state, :tracker_inbox_context_changed)
      {:retired, state} -> state
      {:error, reason} -> block_tracker_inbox(state, reason)
    end
  end

  defp rebind_tracker_inbox_prefix(state, acknowledged_end \\ nil) do
    batch = state.tracker_inbox_batch

    case TrackerEventInbox.capture(batch.location, tracker_inbox_limits()) do
      {:ok, %{generation: generation}} when generation != batch.generation ->
        {:retired, retire_tracker_inbox_generation(state)}

      {:ok, captured} ->
        applied_end = if batch.applied_cursor, do: batch.applied_cursor.end_offset, else: captured.start_offset
        rows = Enum.filter(captured.rows, &(&1.cursor.end_offset <= batch.end_offset and &1.cursor.end_offset > applied_end))
        expected_start = acknowledged_end || batch.start_offset

        same_rows =
          if is_nil(acknowledged_end) do
            rows == batch.rows
          else
            Enum.map(rows, &{&1.cursor.end_offset, &1.record}) == Enum.map(batch.rows, &{&1.cursor.end_offset, &1.record})
          end

        if captured.start_offset == expected_start and same_rows do
          head = if batch.head, do: %{batch.head | row: hd(rows)}, else: nil
          {:ok, %{state | tracker_inbox_batch: %{batch | rows: rows, head: head, start_offset: captured.start_offset}}}
        else
          {:error, :tracker_inbox_prefix_changed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_tracker_inbox_head(%{tracker_inbox_batch: %{head: head}} = state, _context) when not is_nil(head), do: state
  defp ensure_tracker_inbox_head(%{tracker_inbox_batch: %{rows: []}} = state, _context), do: state

  defp ensure_tracker_inbox_head(state, context) do
    row = hd(state.tracker_inbox_batch.rows)

    event =
      case row.record do
        {:ok, record} -> decode_tracker_event_record(record)
        {:invalid, _reason} -> nil
      end

    head = %{
      ref: make_ref(),
      row: row,
      event: event,
      phase: :lookup_ready,
      issue: nil,
      observation: nil,
      fingerprint: context.fingerprint,
      completion: nil,
      outcome: nil,
      errors: [],
      invalidated: false,
      retryable: true
    }

    put_in(state.tracker_inbox_batch.head, head)
  end

  defp discard_tracker_inbox_prefix(%{tracker_inbox_batch: %{head: nil, rows: [_ | _]}} = state, context) do
    state = ensure_tracker_inbox_head(state, context)
    batch = state.tracker_inbox_batch

    if discardable_tracker_inbox_event?(batch.head.event) do
      batch = %{batch | head: nil, rows: tl(batch.rows), applied_cursor: batch.head.row.cursor}
      discard_tracker_inbox_prefix(%{state | tracker_inbox_batch: batch}, context)
    else
      state
    end
  end

  defp discard_tracker_inbox_prefix(state, _context), do: state

  defp discardable_tracker_inbox_event?(%TrackerEvent{} = event),
    do: not TrackerEvent.schedule_affecting?(event) or not is_binary(event.entity_id) or event.entity_id == ""

  defp discardable_tracker_inbox_event?(_event), do: true

  defp start_tracker_inbox_lookup(state, context) do
    head = state.tracker_inbox_batch.head

    cond do
      tracker_inbox_reader_active?(state) ->
        state

      discardable_tracker_inbox_event?(head.event) ->
        apply_tracker_inbox_head(state, :discarded)

      stale_tracker_event?(state, head.event) ->
        RunLedger.record("dispatch.skipped", %{
          issue_id: head.event.entity_id,
          issue_identifier: head.event.issue_identifier,
          actor_type: "system",
          actor_id: "tracker_event_inbox",
          rule_id: "tracker.event_replayed",
          summary: "Ignored a stale tracker event during replay.",
          metadata: %{provider: head.event.provider, action: head.event.action}
        })

        apply_tracker_inbox_head(state, :discarded)

      tracker_backoff_active?(state) ->
        backoff_tracker_inbox(state)

      true ->
        cancel_tracker_inbox_wakeup(state)
        state = %{state | tracker_inbox_wakeup: nil}
        event = head.event
        input = %{source: :tracker, id: event.entity_id, canonical_identifier: event.issue_identifier}

        case TrackerReader.start(fn -> IssueSource.fetch_issue(input, context) end) do
          {:ok, reader} ->
            operation =
              Map.merge(reader, %{
                purpose: :inbox_lookup,
                phase: :tracker_inbox,
                head_ref: head.ref,
                fingerprint: context.fingerprint,
                backoff: tracker_poll_backoff_identity(state),
                invalidated: false
              })

            head = %{head | phase: :lookup, observation: tracker_inbox_observation(state, event.entity_id), fingerprint: context.fingerprint, invalidated: false}
            state = put_in(state.tracker_inbox_batch.head, head)
            %{state | tracker_poll_read: operation}

          {:error, reason} ->
            block_tracker_inbox(state, {:tracker_reader_start_failed, reason})
        end
    end
  end

  defp tracker_inbox_observation(state, id) do
    worker =
      case Map.get(state.running, id) do
        nil -> nil
        entry -> {tracker_poll_worker_identity(entry), Map.get(entry, :custody_ref), Map.get(entry, :lease_token)}
      end

    claim =
      case Map.get(state.lease_claims, id) do
        nil -> nil
        custody -> {custody.custody_ref, custody.token}
      end

    {worker, claim, Map.get(state.issue_routing_cache, id), Map.get(state.paused_issue_states, id)}
  end

  defp resume_tracker_inbox_after_reader(%{tracker_inbox_batch: %{head: %{phase: :lookup_ready}}} = state) do
    if tracker_inbox_reader_active?(state), do: state, else: enqueue_tracker_poll(state, :webhook)
  end

  defp resume_tracker_inbox_after_reader(state), do: state

  defp tracker_inbox_reader_active?(state) do
    match?(%{purpose: :inbox_lookup}, state.tracker_poll_read) or
      match?(%{purpose: :inbox_admission}, state.admission_read) or
      match?(%{purpose: :promotion, completion: %{purpose: :tracker_inbox}}, state.admission_read)
  end

  defp tracker_inbox_current(state, head_ref) do
    with %{head: %{ref: ^head_ref, invalidated: false} = head} = batch <- state.tracker_inbox_batch,
         true <- TrackerEventInbox.location() == batch.location,
         {:ok, context} <- capture_tracker_poll_context(),
         true <- context.fingerprint == head.fingerprint,
         true <- tracker_inbox_observation(state, head.event.entity_id) == head.observation,
         {:ok, captured} <- TrackerEventInbox.capture(batch.location, tracker_inbox_limits()),
         true <- captured.generation == batch.generation and captured.start_offset == batch.start_offset,
         true <- Enum.any?(captured.rows, &(&1 == head.row)) do
      :ok
    else
      {:error, reason} -> {:blocked, reason}
      _ -> {:recheck, :tracker_inbox_changed}
    end
  end

  defp receive_tracker_inbox_result(state, operation, result) do
    {state, result} = observe_tracker_inbox_transport(state, operation, result)

    case state.tracker_inbox_batch do
      %{head: %{ref: ref}} when ref == operation.head_ref ->
        cond do
          operation.invalidated ->
            reset_tracker_inbox_head(state)

          tracker_reader_failure?(result) ->
            block_tracker_inbox(state, elem(result, 1))

          true ->
            case tracker_inbox_current(state, operation.head_ref) do
              :ok -> apply_tracker_inbox_lookup(state, result)
              {:blocked, reason} -> block_tracker_inbox(state, reason)
              {:recheck, reason} -> recheck_tracker_inbox(state, reason)
            end
        end

      _ ->
        state
    end
  end

  defp observe_tracker_inbox_transport(state, operation, result) do
    case capture_tracker_poll_context() do
      {:ok, context} when context.fingerprint == operation.fingerprint ->
        if tracker_poll_backoff_identity(state) == operation.backoff,
          do: tracker_read(state, fn -> result end),
          else: {state, {:error, :tracker_inbox_backoff_changed}}

      _ ->
        {state, {:error, :tracker_inbox_context_changed}}
    end
  end

  defp tracker_reader_failure?({:error, {tag, _}}) when tag in [:tracker_reader_down, :tracker_reader_exit, :tracker_reader_start_failed], do: true
  defp tracker_reader_failure?({:error, {:tracker_read_exception, _, _}}), do: true
  defp tracker_reader_failure?({:error, :invalid_tracker_read_result}), do: true
  defp tracker_reader_failure?(_result), do: false

  defp apply_tracker_inbox_lookup(state, {:error, {:linear_rate_limited, _}}), do: backoff_tracker_inbox(state)
  defp apply_tracker_inbox_lookup(state, {:error, :tracker_inbox_backoff_changed}), do: backoff_tracker_inbox(state)

  defp apply_tracker_inbox_lookup(state, {:ok, %Issue{} = issue}) do
    head = state.tracker_inbox_batch.head

    if issue.id == head.event.entity_id and is_binary(issue.identifier) and issue.identifier != "" do
      state = state |> begin_tracker_inbox_decision() |> invalidate_admission_issue(head.event.entity_id, head.ref)
      # Invalidation may release a previous C3 promotion. Keep its explicit
      # outcome/debt; a saved pre-cleanup head would lose that information.
      head = state.tracker_inbox_batch.head

      cond do
        head.errors != [] or not is_nil(head.outcome) ->
          settle_tracker_inbox_decision(state)

        true ->
          head = %{head | issue: issue, observation: tracker_inbox_observation(state, issue.id)}
          state = put_in(state.tracker_inbox_batch.head, head)

          cond do
            Map.has_key?(state.running, issue.id) ->
              state = reconcile_issue_state(issue, state, active_state_set(), terminal_state_set(), head.ref)
              settle_tracker_inbox_decision(state, {:applied, :reconciled})

            retry_candidate_issue?(issue, terminal_state_set()) and dispatch_slots_available?(issue, state) ->
              head = %{head | phase: :admission_ready, completion: nil, outcome: nil}
              state |> put_in([Access.key(:tracker_inbox_batch), :head], head) |> yield_tracker_inbox()

            true ->
              settle_tracker_inbox_decision(state, {:applied, :not_eligible})
          end
      end
    else
      apply_tracker_inbox_head(state, :discarded)
    end
  end

  defp apply_tracker_inbox_lookup(state, {:ok, nil}) do
    head = state.tracker_inbox_batch.head
    state |> begin_tracker_inbox_decision() |> invalidate_admission_issue(head.event.entity_id, head.ref) |> settle_tracker_inbox_decision({:applied, :discarded})
  end

  defp apply_tracker_inbox_lookup(state, {:error, reason}) do
    Logger.warning("Tracker inbox lookup failed reason=#{inspect(reason)}")
    apply_tracker_inbox_head(state, :discarded)
  end

  defp begin_tracker_inbox_decision(state) do
    head = state.tracker_inbox_batch.head
    completion = %{purpose: :tracker_inbox, head_ref: head.ref, decision_ref: make_ref(), custody_ref: nil}
    put_in(state.tracker_inbox_batch.head, %{head | phase: :admission, completion: completion, outcome: nil, errors: []})
  end

  defp invalidate_tracker_inbox_cache(state, issues, origin) do
    Enum.reduce(issues, state, fn issue, current ->
      if remember_issue_cache_entry(current.issue_routing_cache, issue) != current.issue_routing_cache,
        do: invalidate_tracker_inbox_issue(current, issue.id, origin),
        else: current
    end)
  end

  defp tracker_inbox_boundary(_state, nil), do: :ok

  defp tracker_inbox_boundary(state, completion) do
    case state.tracker_inbox_batch do
      %{head: %{completion: ^completion, errors: []}} -> tracker_inbox_current(state, completion.head_ref)
      %{head: %{completion: ^completion, errors: errors}} -> {:blocked, {:tracker_inbox_cleanup_failed, errors}}
      _ -> {:recheck, :tracker_inbox_completion_changed}
    end
  end

  defp tracker_inbox_cleanup_outcome(state, completion) do
    case tracker_inbox_boundary(state, completion) do
      :ok -> {:applied, :dispatch_rejected}
      {kind, reason} when kind in [:blocked, :recheck] -> {kind, reason}
    end
  end

  defp bind_tracker_inbox_custody(state, id, previous, claim) do
    case tracker_inbox_completion(state, id) do
      %{custody_ref: expected} = completion when expected == previous ->
        completion = %{completion | custody_ref: claim.custody_ref}
        claim = Map.put(claim, :completion, completion)
        state = put_in(state.lease_claims[id], claim)
        head = state.tracker_inbox_batch.head
        put_in(state.tracker_inbox_batch.head, %{head | completion: completion, observation: tracker_inbox_observation(state, id)})

      _ ->
        state
    end
  end

  defp tracker_inbox_wait(state, id, phase) do
    case tracker_inbox_completion(state, id) do
      nil ->
        state

      _ ->
        head = state.tracker_inbox_batch.head
        put_in(state.tracker_inbox_batch.head, %{head | phase: phase, outcome: {:wait, phase}, observation: tracker_inbox_observation(state, id)})
    end
  end

  defp tracker_inbox_origin(state, id) do
    case tracker_inbox_completion(state, id) do
      %{head_ref: ref} -> ref
      nil -> nil
    end
  end

  defp tracker_inbox_worker_start_failure(state, _id, {:dispatch_worker_start_failed, reason}), do: {state, reason}
  defp tracker_inbox_worker_start_failure(state, id, reason), do: {tracker_inbox_outcome(state, id, {:blocked, {:worker_start_validation_failed, reason}}), reason}

  defp tracker_inbox_validation_outcome({:persisted_stage_requires_explicit_resume, _}), do: {:applied, :not_eligible}
  defp tracker_inbox_validation_outcome({:token_budget_exhausted, _}), do: {:applied, :not_eligible}
  defp tracker_inbox_validation_outcome(reason) when reason in [:lease_workspace_changed, :lease_location_changed], do: {:recheck, reason}
  defp tracker_inbox_validation_outcome(reason), do: {:blocked, reason}

  defp tracker_inbox_promotion_outcome(reason) when reason in [:promotion_context_changed, :promotion_run_changed], do: {:recheck, reason}
  defp tracker_inbox_promotion_outcome(:promotion_backoff_changed), do: {:backoff, :transport_changed}
  defp tracker_inbox_promotion_outcome({:token_budget_exhausted, _}), do: {:applied, :not_eligible}
  defp tracker_inbox_promotion_outcome(reason) when reason in [:promotion_deadline_expired, :promotion_capacity_changed, :promotion_ineligible], do: {:applied, :dispatch_rejected}
  defp tracker_inbox_promotion_outcome({tag, _}) when tag in [:linear_api_status, :linear_graphql_errors, :linear_api_error], do: {:applied, :dispatch_rejected}
  defp tracker_inbox_promotion_outcome(reason), do: {:blocked, reason}

  defp tracker_inbox_completion(state, id) do
    case state.tracker_inbox_batch do
      %{head: %{event: %{entity_id: ^id}, completion: %{purpose: :tracker_inbox} = completion}} -> completion
      _ -> nil
    end
  end

  defp tracker_inbox_outcome(state, id, outcome) do
    case tracker_inbox_completion(state, id) do
      nil ->
        state

      _ ->
        previous = state.tracker_inbox_batch.head.outcome

        outcome =
          case previous do
            {:blocked, _} -> previous
            {:recheck, _} -> previous
            {:backoff, _} when elem(outcome, 0) in [:applied, :wait] -> previous
            _ -> outcome
          end

        put_in(state.tracker_inbox_batch.head.outcome, outcome)
    end
  end

  defp tracker_inbox_failure(state, id, reason) do
    case tracker_inbox_completion(state, id) do
      nil -> state
      _ -> update_in(state.tracker_inbox_batch.head.errors, &Enum.uniq(&1 ++ [reason]))
    end
  end

  defp finish_tracker_inbox_action(state, nil, _fallback), do: state

  defp finish_tracker_inbox_action(state, completion, fallback) do
    case state.tracker_inbox_batch do
      %{head: %{completion: %{head_ref: head_ref, decision_ref: decision_ref}}}
      when head_ref == completion.head_ref and decision_ref == completion.decision_ref ->
        settle_tracker_inbox_decision(state, fallback)

      _ ->
        state
    end
  end

  defp settle_tracker_inbox_decision(state, fallback \\ nil) do
    case state.tracker_inbox_batch do
      %{head: %{completion: completion, outcome: outcome, errors: errors}} when not is_nil(completion) ->
        outcome =
          cond do
            errors != [] -> {:blocked, {:tracker_inbox_cleanup_failed, errors}}
            not is_nil(fallback) and match?({:wait, _}, outcome) -> fallback
            true -> outcome || fallback
          end

        complete_tracker_inbox_decision(state, completion, outcome)

      _ ->
        state
    end
  end

  defp complete_tracker_inbox_decision(state, nil, _outcome), do: state
  defp complete_tracker_inbox_decision(state, _completion, nil), do: state

  defp complete_tracker_inbox_decision(state, completion, outcome) do
    case state.tracker_inbox_batch do
      %{head: %{completion: ^completion} = head} ->
        cond do
          head.errors != [] -> block_tracker_inbox(state, {:tracker_inbox_cleanup_failed, head.errors}, false)
          head.invalidated -> recheck_tracker_inbox(state, :tracker_inbox_invalidated)
          true -> resolve_tracker_inbox_decision(state, outcome)
        end

      _ ->
        state
    end
  end

  defp resolve_tracker_inbox_decision(state, {:applied, reason}), do: apply_tracker_inbox_head(state, reason)
  defp resolve_tracker_inbox_decision(state, {:wait, phase}), do: put_in(state.tracker_inbox_batch.head.phase, phase)
  defp resolve_tracker_inbox_decision(state, {:recheck, reason}), do: recheck_tracker_inbox(state, reason)
  defp resolve_tracker_inbox_decision(state, {:blocked, reason}), do: block_tracker_inbox(state, reason)
  defp resolve_tracker_inbox_decision(state, {:backoff, _metadata}), do: backoff_tracker_inbox(state)

  defp apply_tracker_inbox_head(state, _reason) do
    batch = state.tracker_inbox_batch
    head = batch.head
    cache = if head.issue, do: remember_issue_cache_entry(state.issue_routing_cache, head.issue), else: state.issue_routing_cache
    batch = %{batch | head: nil, rows: tl(batch.rows), applied_cursor: head.row.cursor}
    send(self(), {:tracker_inbox_continue, batch.ref})
    %{state | tracker_inbox_batch: batch, issue_routing_cache: cache}
  end

  defp yield_tracker_inbox(%{tracker_inbox_batch: %{applied_cursor: nil}} = state), do: state
  defp yield_tracker_inbox(%{inbox_ack_pending: pending} = state) when not is_nil(pending), do: state

  defp yield_tracker_inbox(state) do
    cursor = state.tracker_inbox_batch.applied_cursor
    send(self(), {:tracker_inbox_ack, cursor})
    %{state | inbox_ack_pending: cursor}
  end

  defp resume_tracker_inbox_after_ack(%{tracker_inbox_batch: %{head: %{phase: :admission_ready}}} = state), do: advance_admission(state)
  defp resume_tracker_inbox_after_ack(state), do: state

  defp confirm_tracker_inbox_prefix(state) do
    cursor = state.inbox_ack_pending

    case TrackerEventInbox.ack(cursor) do
      {:ok, _confirmation} ->
        state = %{state | inbox_ack_pending: nil, inbox_storage_error: nil, inbox_last_drained_at: DateTime.utc_now()}

        case state.tracker_inbox_batch do
          %{rows: []} ->
            send(self(), :run_webhook_cycle)
            %{state | tracker_inbox_batch: nil}

          nil ->
            state

          batch ->
            state = %{state | tracker_inbox_batch: %{batch | applied_cursor: nil}}

            case rebind_tracker_inbox_prefix(state, cursor.end_offset) do
              {:ok, next} -> resume_tracker_inbox_after_ack(next)
              {:retired, next} -> next
              {:error, reason} -> block_tracker_inbox(state, reason)
            end
        end

      {:error, %{reason_code: :generation_changed} = error} ->
        retire_tracker_inbox_generation(state) |> tracker_inbox_storage_failed(error)

      {:error, error} ->
        tracker_inbox_storage_failed(state, error)
    end
  end

  defp block_tracker_inbox(state, reason, retryable \\ true) do
    cancel_tracker_inbox_wakeup(state)
    state = tracker_inbox_storage_failed(%{state | tracker_inbox_wakeup: nil}, reason)

    state =
      case state.tracker_inbox_batch do
        %{head: head} when not is_nil(head) ->
          put_in(state.tracker_inbox_batch.head, %{head | phase: :blocked, completion: nil, outcome: nil, retryable: retryable})

        _ ->
          state
      end

    if state.tracker_inbox_batch, do: yield_tracker_inbox(state), else: state
  end

  defp tracker_inbox_storage_failed(state, %SymphonyElixir.EventInbox.Error{} = error) do
    inbox_storage_failed(state, %{error: :inbox_storage_error}, error)
  end

  defp tracker_inbox_storage_failed(state, reason) do
    %{state | inbox_storage_error: %{phase: :continuation, reason_code: tracker_inbox_reason_code(reason), confirmation: :not_applied}, candidate_fetch_error: reason}
  end

  defp tracker_inbox_reason_code(reason) when is_atom(reason), do: reason
  defp tracker_inbox_reason_code(reason) when is_tuple(reason), do: elem(reason, 0)

  defp reset_tracker_inbox_head(%{tracker_inbox_batch: %{head: %{phase: :blocked, retryable: false}}} = state), do: state

  defp reset_tracker_inbox_head(state) do
    case state.tracker_inbox_batch do
      %{head: head} when not is_nil(head) ->
        put_in(state.tracker_inbox_batch.head, %{head | phase: :lookup_ready, completion: nil, outcome: nil, issue: nil, observation: nil, invalidated: false, errors: [], retryable: true})

      _ ->
        state
    end
  end

  defp recheck_tracker_inbox(state, reason) do
    case capture_tracker_poll_context() do
      {:ok, context} when context.fingerprint == state.tracker_inbox_batch.fingerprint ->
        if TrackerEventInbox.location() == state.tracker_inbox_batch.location do
          state = reset_tracker_inbox_head(state)
          send(self(), {:tracker_inbox_continue, state.tracker_inbox_batch.ref})
          state
        else
          retire_tracker_inbox(state, reason)
        end

      _ ->
        retire_tracker_inbox(state, reason)
    end
  end

  defp retire_tracker_inbox_generation(state) do
    # Cursors from a retired generation must never be offered for ack again,
    # including when cleanup leaves a blocked head with known release debt.
    state = %{state | inbox_ack_pending: nil}

    state =
      case state.tracker_inbox_batch do
        nil -> state
        batch -> %{state | tracker_inbox_batch: %{batch | applied_cursor: nil}}
      end

    retire_tracker_inbox(state, :tracker_inbox_generation_changed)
  end

  defp retire_tracker_inbox(state, reason) do
    case state.tracker_inbox_batch do
      nil ->
        state

      batch ->
        state = if batch.head, do: cancel_tracker_inbox_head(state, reason), else: state

        case state.tracker_inbox_batch do
          %{head: %{phase: :blocked, retryable: false}} ->
            state

          _ ->
            state = yield_tracker_inbox(state)
            cancel_tracker_inbox_wakeup(state)
            %{state | tracker_inbox_batch: nil, tracker_inbox_wakeup: nil}
        end
    end
  end

  defp backoff_tracker_inbox(state) do
    state = reset_tracker_inbox_head(state)
    state = put_in(state.tracker_inbox_batch.head.phase, :backoff)
    state = yield_tracker_inbox(state)
    cancel_tracker_inbox_wakeup(state)
    batch = state.tracker_inbox_batch
    ref = make_ref()
    delay = max(0, (state.tracker_backoff_until_ms || System.monotonic_time(:millisecond)) - System.monotonic_time(:millisecond))
    timer = Process.send_after(self(), {:tracker_inbox_wakeup, ref, batch.location, batch.generation}, delay)
    %{state | tracker_inbox_wakeup: %{ref: ref, timer: timer, location: batch.location, generation: batch.generation, head_ref: batch.head.ref, backoff: tracker_poll_backoff_identity(state)}}
  end

  defp cancel_tracker_inbox_wakeup(%{tracker_inbox_wakeup: %{timer: timer}}), do: Process.cancel_timer(timer)
  defp cancel_tracker_inbox_wakeup(_state), do: false

  defp invalidate_tracker_inbox_issue(state, identifier, origin) do
    case state.tracker_inbox_batch do
      %{head: %{ref: ref, event: %TrackerEvent{} = event}} when ref != origin and identifier in [event.entity_id, event.issue_identifier] ->
        cancel_tracker_inbox_head(state, :tracker_inbox_knowledge_changed)

      _ ->
        state
    end
  end

  defp cancel_tracker_inbox_head(state, reason) do
    head = state.tracker_inbox_batch.head
    state = put_in(state.tracker_inbox_batch.head.invalidated, true)

    state =
      Enum.reduce([:tracker_poll_read, :admission_read], state, fn field, acc ->
        case Map.get(acc, field) do
          %{head_ref: ref} = reader when ref == head.ref ->
            :ok = TrackerReader.cancel(Map.take(reader, [:owner, :pid, :monitor, :ref]))
            Map.put(acc, field, Map.put(reader, :invalidated, true))

          _ ->
            acc
        end
      end)

    state =
      case head.completion do
        %{custody_ref: ref} when not is_nil(ref) ->
          case current_issue_custody(state, head.event.entity_id, ref) do
            {:ok, claim} ->
              case Map.get(state.running, head.event.entity_id) do
                %{custody_ref: ^ref, lease_token: token} when token == claim.token -> do_terminate_running_issue(state, head.event.entity_id, false)
                nil -> release_issue_claim(state, head.event.entity_id)
                _successor -> state
              end

            {:error, _changed_or_missing} ->
              state
          end

        _ ->
          state
      end

    case state.tracker_inbox_batch.head.errors do
      [] ->
        state = reset_tracker_inbox_head(state)
        send(self(), {:tracker_inbox_continue, state.tracker_inbox_batch.ref})
        state

      errors ->
        block_tracker_inbox(state, {reason, errors}, false)
    end
  end

  defp decode_tracker_event_record(%{"event" => payload}) when is_map(payload) do
    %TrackerEvent{
      provider: Map.get(payload, "provider") || "linear",
      event_id: Map.get(payload, "event_id"),
      entity_type: Map.get(payload, "entity_type") || "Issue",
      entity_id: Map.get(payload, "entity_id"),
      issue_identifier: Map.get(payload, "issue_identifier"),
      project_slug: Map.get(payload, "project_slug"),
      action: Map.get(payload, "action") || "update",
      state_name: Map.get(payload, "state_name"),
      label_names: Map.get(payload, "label_names") || [],
      assignee_id: Map.get(payload, "assignee_id"),
      updated_at: parse_tracker_event_timestamp(Map.get(payload, "updated_at")),
      raw: Map.get(payload, "raw") || %{}
    }
  end

  defp decode_tracker_event_record(_record), do: nil

  defp decode_github_event_record(%{"event" => payload}) when is_map(payload) do
    %GitHubEvent{
      provider: Map.get(payload, "provider") || "github",
      event_id: Map.get(payload, "event_id"),
      event_name: Map.get(payload, "event_name") || "",
      action: Map.get(payload, "action") || "",
      entity_type: Map.get(payload, "entity_type"),
      entity_id: Map.get(payload, "entity_id"),
      pr_url: Map.get(payload, "pr_url"),
      repo_full_name: Map.get(payload, "repo_full_name"),
      updated_at: parse_tracker_event_timestamp(Map.get(payload, "updated_at")),
      conclusion: Map.get(payload, "conclusion"),
      check_name: Map.get(payload, "check_name"),
      details_url: Map.get(payload, "details_url"),
      head_sha: Map.get(payload, "head_sha"),
      received_runner_channel: Map.get(payload, "received_runner_channel"),
      received_runner_instance_id: Map.get(payload, "received_runner_instance_id"),
      target_runner_channel: Map.get(payload, "target_runner_channel"),
      assigned_runner_channel: Map.get(payload, "assigned_runner_channel"),
      assigned_runner_instance_id: Map.get(payload, "assigned_runner_instance_id"),
      assignment_state: Map.get(payload, "assignment_state"),
      assignment_reason: Map.get(payload, "assignment_reason"),
      raw: Map.get(payload, "raw") || %{}
    }
  rescue
    _error -> nil
  end

  defp decode_github_event_record(_record), do: nil

  defp parse_tracker_event_timestamp(nil), do: nil

  defp parse_tracker_event_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> nil
    end
  end

  defp parse_tracker_event_timestamp(_value), do: nil

  defp stale_tracker_event?(%State{} = state, %TrackerEvent{
         entity_id: entity_id,
         updated_at: %DateTime{} = updated_at
       })
       when is_binary(entity_id) do
    case Map.get(state.issue_routing_cache, entity_id) do
      %{updated_at: %DateTime{} = cached_updated_at} ->
        DateTime.compare(updated_at, cached_updated_at) != :gt

      _ ->
        false
    end
  end

  defp stale_tracker_event?(_state, _event), do: false

  defp tracker_read(%State{} = state, fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, value} ->
        {clear_tracker_backoff(state), {:ok, value}}

      {:error, {:linear_rate_limited, metadata}} ->
        {apply_tracker_backoff(state, metadata), {:error, {:linear_rate_limited, metadata}}}

      {:error, {:linear_api_status, 429, metadata}} ->
        {apply_tracker_backoff(state, metadata), {:error, {:linear_rate_limited, metadata}}}

      other ->
        {state, other}
    end
  end

  defp apply_tracker_backoff(%State{} = state, metadata) do
    now_ms = System.monotonic_time(:millisecond)
    retry_after_ms = backoff_delay_ms(state, metadata)

    Observability.emit_tracker_backoff(:entered, %{
      reason: "Linear API rate limited",
      rule_id: "tracker.rate_limited",
      retry_after_ms: retry_after_ms
    })

    %{
      state
      | tracker_backoff_until_ms: now_ms + retry_after_ms,
        tracker_backoff_reason: "Linear API rate limited",
        tracker_backoff_rule_id: "tracker.rate_limited"
    }
  end

  defp clear_tracker_backoff(%State{} = state) do
    if is_integer(state.tracker_backoff_until_ms) do
      Observability.emit_tracker_backoff(:cleared, %{
        reason: state.tracker_backoff_reason,
        rule_id: state.tracker_backoff_rule_id
      })
    end

    %{
      state
      | tracker_backoff_until_ms: nil,
        tracker_backoff_reason: nil,
        tracker_backoff_rule_id: nil
    }
  end

  defp backoff_delay_ms(%State{} = state, metadata) when is_map(metadata) do
    retry_after_ms =
      case Map.get(metadata, :retry_after_ms) || Map.get(metadata, "retry_after_ms") do
        value when is_integer(value) and value > 0 -> value
        _ -> nil
      end

    cond do
      is_integer(retry_after_ms) ->
        min(retry_after_ms, 1_800_000)

      is_integer(state.tracker_backoff_until_ms) ->
        min(
          max(state.tracker_backoff_until_ms - System.monotonic_time(:millisecond), 60_000) * 2,
          1_800_000
        )

      true ->
        60_000
    end
  end

  defp backoff_delay_ms(_state, _metadata), do: 60_000

  defp tracker_backoff_active?(%State{} = state) do
    is_integer(state.tracker_backoff_until_ms) and
      state.tracker_backoff_until_ms > System.monotonic_time(:millisecond)
  end

  defp maybe_note_tracker_backoff(%State{} = state, _mode) do
    Logger.info("Tracker backoff active; degrading to manual-only dispatch until #{inspect(state.tracker_backoff_until_ms)}")

    state
  end

  defp remember_issue_cache_entries(cache, issues) when is_list(issues) do
    cache =
      if map_size(cache) > @issue_routing_cache_max_keys do
        %{}
      else
        cache
      end

    Enum.reduce(issues, cache, &remember_issue_cache_entry(&2, &1))
  end

  @doc false
  @spec remember_issue_cache_entry(map(), Issue.t()) :: map()
  def remember_issue_cache_entry(cache, %Issue{id: issue_id} = issue)
      when is_map(cache) and is_binary(issue_id) do
    Map.put(cache, issue_id, %{
      state: issue.state,
      assignee_id: issue.assignee_id,
      labels: Issue.label_names(issue),
      updated_at: issue.updated_at
    })
  end

  def remember_issue_cache_entry(cache, _issue), do: cache

  defp record_webhook_accept(%State{} = state, attrs) do
    accepted_at = Map.get(attrs, :accepted_at) || DateTime.utc_now()

    Observability.emit([:symphony, :intake, :tracker, :webhook, :accepted], %{count: 1}, %{
      accepted_at: accepted_at
    })

    %{state | webhook_last_accepted_at: accepted_at}
  end

  defp record_webhook_ignored(%State{} = state, attrs) do
    ignored_at = Map.get(attrs, :ignored_at) || DateTime.utc_now()
    reason = Map.get(attrs, :reason)
    rule_id = Map.get(attrs, :rule_id)

    Observability.emit(
      [:symphony, :intake, :tracker, :webhook, :ignored],
      %{count: 1},
      %{ignored_at: ignored_at, reason: reason, rule_id: rule_id}
    )

    %{
      state
      | webhook_last_ignored_at: ignored_at,
        webhook_last_ignored_reason: Map.get(attrs, :reason),
        webhook_last_ignored_rule_id: Map.get(attrs, :rule_id)
    }
  end

  defp record_webhook_rejection(%State{} = state, attrs) do
    rejected_at = Map.get(attrs, :rejected_at) || DateTime.utc_now()
    reason = Map.get(attrs, :reason)
    rule_id = Map.get(attrs, :rule_id)

    Observability.emit(
      [:symphony, :intake, :tracker, :webhook, :rejected],
      %{count: 1},
      %{rejected_at: rejected_at, reason: reason, rule_id: rule_id}
    )

    %{
      state
      | webhook_last_rejected_at: rejected_at,
        webhook_last_rejected_reason: Map.get(attrs, :reason),
        webhook_last_rejected_rule_id: Map.get(attrs, :rule_id)
    }
  end

  defp record_github_webhook_accept(%State{} = state, attrs) do
    accepted_at = Map.get(attrs, :accepted_at) || DateTime.utc_now()

    Observability.emit([:symphony, :intake, :github, :webhook, :accepted], %{count: 1}, %{
      accepted_at: accepted_at
    })

    %{state | github_webhook_last_accepted_at: accepted_at}
  end

  defp record_github_webhook_ignored(%State{} = state, attrs) do
    ignored_at = Map.get(attrs, :ignored_at) || DateTime.utc_now()
    reason = Map.get(attrs, :reason)
    rule_id = Map.get(attrs, :rule_id)

    Observability.emit(
      [:symphony, :intake, :github, :webhook, :ignored],
      %{count: 1},
      %{ignored_at: ignored_at, reason: reason, rule_id: rule_id}
    )

    %{
      state
      | github_webhook_last_ignored_at: ignored_at,
        github_webhook_last_ignored_reason: Map.get(attrs, :reason),
        github_webhook_last_ignored_rule_id: Map.get(attrs, :rule_id)
    }
  end

  defp record_github_webhook_rejection(%State{} = state, attrs) do
    rejected_at = Map.get(attrs, :rejected_at) || DateTime.utc_now()
    reason = Map.get(attrs, :reason)
    rule_id = Map.get(attrs, :rule_id)

    Observability.emit(
      [:symphony, :intake, :github, :webhook, :rejected],
      %{count: 1},
      %{rejected_at: rejected_at, reason: reason, rule_id: rule_id}
    )

    %{
      state
      | github_webhook_last_rejected_at: rejected_at,
        github_webhook_last_rejected_reason: Map.get(attrs, :reason),
        github_webhook_last_rejected_rule_id: Map.get(attrs, :rule_id)
    }
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_stalled_running_issues_for_test(State.t()) :: State.t()
  def reconcile_stalled_running_issues_for_test(%State{} = state) do
    reconcile_stalled_running_issues(state)
  end

  @doc false
  @spec stall_elapsed_ms_for_test(map(), DateTime.t() | integer() | nil) :: integer() | nil
  def stall_elapsed_ms_for_test(running_entry, now), do: stall_elapsed_ms(running_entry, now)

  @doc false
  @spec last_activity_timestamp_for_test(map()) :: DateTime.t() | integer() | nil
  def last_activity_timestamp_for_test(running_entry), do: last_activity_timestamp(running_entry)

  @doc false
  @spec terminate_task_for_test(pid() | term()) :: :ok
  def terminate_task_for_test(pid), do: terminate_task(pid)

  @doc false
  @spec paused_snapshot_entries_for_test(term()) :: [map()]
  def paused_snapshot_entries_for_test(paused_issue_states),
    do: paused_snapshot_entries(paused_issue_states)

  @spec partition_issues_by_label_gate_for_test([Issue.t()], term()) :: term()
  def partition_issues_by_label_gate_for_test(issues, %State{} = state) do
    partition_issues_by_label_gate(issues, state)
  end

  @doc false
  def partition_issues_by_label_gate_for_test(issues, state) do
    partition_issues_by_label_gate(issues, state)
  end

  @doc false
  @spec skipped_issue_entry_for_test(term(), atom(), term()) :: map()
  def skipped_issue_entry_for_test(issue, reason, state),
    do: skipped_issue_entry(issue, reason, state)

  @doc false
  @spec choose_issues_for_test([Issue.t()], State.t()) :: {[Issue.t()], [Issue.t()]}
  def choose_issues_for_test(issues, %State{} = state), do: choose_issues(issues, state)

  @doc false
  @spec choose_issues_for_test([Issue.t()], State.t(), (Issue.t(), State.t() -> term())) ::
          {[Issue.t()], [Issue.t()]}
  def choose_issues_for_test(issues, %State{} = state, dispatch_fun)
      when is_function(dispatch_fun, 2) do
    choose_issues(issues, state, dispatch_fun)
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  def should_dispatch_issue_for_test(_issue, _state), do: false

  @doc false
  @spec state_slots_available_for_test(term(), list()) :: non_neg_integer()
  def state_slots_available_for_test(issue, running), do: state_slots_available?(issue, running)

  @doc false
  @spec running_issue_count_for_state_for_test(list(), term()) :: non_neg_integer()
  def running_issue_count_for_state_for_test(running, issue_state),
    do: running_issue_count_for_state(running, issue_state)

  @doc false
  @spec issue_routable_to_worker_for_test(term()) :: boolean()
  def issue_routable_to_worker_for_test(issue), do: issue_routable_to_worker?(issue)

  @doc false
  @spec issue_labels_for_test(term()) :: [String.t()]
  def issue_labels_for_test(issue), do: issue_labels(issue)

  @doc false
  @spec issue_matches_required_labels_for_test(term()) :: boolean()
  def issue_matches_required_labels_for_test(issue), do: issue_matches_required_labels?(issue)

  @doc false
  @spec issue_target_runner_channel_for_test(Issue.t()) :: String.t()
  def issue_target_runner_channel_for_test(%Issue{} = issue),
    do: issue_target_runner_channel(issue)

  @doc false
  @spec seeded_manual_issue_from_run_state_for_test(map()) :: Issue.t() | nil
  def seeded_manual_issue_from_run_state_for_test(run_state)
      when is_map(run_state),
      do: seeded_manual_issue_from_run_state(run_state)

  @doc false
  @spec resolve_issue_for_control_for_test(State.t(), String.t()) ::
          {:ok, Issue.t()} | {:error, term()}
  def resolve_issue_for_control_for_test(%State{} = state, issue_identifier)
      when is_binary(issue_identifier),
      do: Controls.resolve_issue_for_control(state, issue_identifier)

  @doc false
  @spec label_gate_status_for_test(term()) :: atom()
  def label_gate_status_for_test(issue), do: label_gate_status(issue)

  @doc false
  @spec terminal_issue_state_for_test(term(), MapSet.t(String.t()) | [String.t()]) :: boolean()
  def terminal_issue_state_for_test(state_name, terminal_states),
    do: terminal_issue_state?(state_name, terminal_states)

  @doc false
  @spec todo_issue_blocked_by_non_terminal_for_test(term(), MapSet.t(String.t()) | [String.t()]) ::
          boolean()
  def todo_issue_blocked_by_non_terminal_for_test(issue, terminal_states),
    do: todo_issue_blocked_by_non_terminal?(issue, terminal_states)

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_passthrough_for_test(Issue.t()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_passthrough_for_test(issue) do
    revalidate_issue_for_dispatch(issue, fn _issue_ids -> :unused end, terminal_state_set())
  end

  @doc false
  @spec dispatch_issue_for_test(State.t(), Issue.t()) :: term()
  def dispatch_issue_for_test(state, issue), do: dispatch_issue_for_test(state, issue, [])

  @doc false
  @spec dispatch_runtime_issue_for_test(State.t(), Issue.t(), term()) :: term()
  def dispatch_runtime_issue_for_test(%State{} = state, %Issue{} = issue, attempt \\ nil) do
    dispatch_runtime_issue(state, issue, attempt)
  end

  @doc false
  @spec dispatch_runtime_issue_for_test(State.t(), Issue.t(), term(), keyword()) :: term()
  def dispatch_runtime_issue_for_test(%State{} = state, %Issue{} = issue, attempt, opts)
      when is_list(opts) do
    active_dispatch_fun = Keyword.get(opts, :active_dispatch_fun, &dispatch_issue/3)
    passive_dispatch_fun = Keyword.get(opts, :passive_dispatch_fun, &dispatch_passive_issue/3)

    dispatch_runtime_issue(state, issue, attempt, active_dispatch_fun, passive_dispatch_fun)
  end

  @doc false
  @spec normalize_dispatch_stage_for_test(Issue.t()) :: String.t()
  def normalize_dispatch_stage_for_test(%Issue{} = issue) do
    normalize_dispatch_stage(issue)
  end

  @doc false
  @spec maybe_resume_blocked_issue_for_test(State.t(), Issue.t()) :: {State.t(), Issue.t()} | {:error, term()}
  def maybe_resume_blocked_issue_for_test(%State{} = state, %Issue{} = issue) do
    Controls.maybe_resume_blocked_issue(state, issue)
  end

  @doc false
  @spec dispatch_issue_default_for_test(State.t(), Issue.t(), term()) :: term()
  def dispatch_issue_default_for_test(%State{} = state, %Issue{} = issue, attempt \\ nil) do
    dispatch_issue(state, issue, attempt)
  end

  @doc false
  @spec dispatch_issue_private_head_for_test(State.t(), term(), term()) :: term()
  def dispatch_issue_private_head_for_test(%State{} = state, issue, attempt) do
    dispatch_issue(state, issue, attempt)
  end

  @doc false
  @spec dispatch_issue_private_head_for_test(State.t(), term()) :: term()
  def dispatch_issue_private_head_for_test(%State{} = state, issue) do
    dispatch_issue(state, issue)
  end

  @spec dispatch_issue_for_test(State.t(), Issue.t(), keyword()) :: term()
  def dispatch_issue_for_test(%State{} = state, %Issue{} = issue, []) do
    dispatch_issue(state, issue, nil)
  end

  def dispatch_issue_for_test(%State{} = state, %Issue{} = issue, opts) when is_list(opts) do
    attempt = Keyword.get(opts, :attempt)
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &IssueSource.fetch_issue_states_by_ids/1)
    dispatch_fun = Keyword.get(opts, :dispatch_fun, &do_dispatch_issue/3)

    dispatch_active_issue(state, issue, attempt, issue_fetcher, dispatch_fun)
  end

  @doc false
  @spec do_dispatch_issue_for_test(State.t(), Issue.t(), term()) :: term()
  def do_dispatch_issue_for_test(%State{} = state, %Issue{} = issue, attempt \\ nil) do
    do_dispatch_issue(state, issue, attempt)
  end

  @doc false
  @spec do_dispatch_issue_for_test(State.t(), Issue.t(), term(), keyword()) :: term()
  def do_dispatch_issue_for_test(%State{} = state, %Issue{} = issue, attempt, opts)
      when is_list(opts) do
    acquire_fun = Keyword.get(opts, :acquire_fun, &LeaseManager.acquire/3)
    spawn_fun = Keyword.get(opts, :spawn_fun, &do_spawn_issue_worker/4)

    do_dispatch_issue(state, issue, attempt, acquire_fun, spawn_fun)
  end

  @doc false
  @spec do_spawn_issue_worker_for_test(State.t(), Issue.t(), term(), pid() | atom(), keyword()) ::
          term()
  def do_spawn_issue_worker_for_test(
        %State{} = state,
        %Issue{} = issue,
        attempt,
        recipient,
        opts \\ []
      )
      when is_list(opts) do
    start_child_fun = Keyword.get(opts, :start_child_fun, &Task.Supervisor.start_child/2)
    do_spawn_issue_worker(state, issue, attempt, recipient, start_child_fun)
  end

  @doc false
  @spec do_spawn_issue_worker_default_for_test(State.t(), Issue.t(), term(), pid() | atom()) ::
          term()
  def do_spawn_issue_worker_default_for_test(
        %State{} = state,
        %Issue{} = issue,
        attempt,
        recipient
      ) do
    do_spawn_issue_worker(state, issue, attempt, recipient)
  end

  @doc false
  @spec do_spawn_passive_worker_for_test(State.t(), Issue.t(), term(), pid() | atom(), keyword()) ::
          term()
  def do_spawn_passive_worker_for_test(
        %State{} = state,
        %Issue{} = issue,
        attempt,
        recipient,
        opts \\ []
      )
      when is_list(opts) do
    start_child_fun = Keyword.get(opts, :start_child_fun, &Task.Supervisor.start_child/2)
    do_spawn_passive_worker(state, issue, attempt, recipient, start_child_fun)
  end

  @doc false
  @spec continuation_metadata_for_running_entry_for_test(map()) :: map()
  def continuation_metadata_for_running_entry_for_test(running_entry),
    do: continuation_metadata_for_running_entry(running_entry)

  @spec maybe_stop_issue_for_token_budget_for_test(State.t(), String.t(), map()) :: State.t()
  def maybe_stop_issue_for_token_budget_for_test(%State{} = state, issue_id, running_entry)
      when is_binary(issue_id) and is_map(running_entry) do
    maybe_stop_issue_for_token_budget(state, issue_id, running_entry)
  end

  @doc false
  @spec dispatch_passive_issue_for_test(State.t(), Issue.t(), keyword()) :: term()
  def dispatch_passive_issue_for_test(%State{} = state, %Issue{} = issue, opts \\ [])
      when is_list(opts) do
    attempt = Keyword.get(opts, :attempt)
    acquire_fun = Keyword.get(opts, :acquire_fun, &LeaseManager.acquire/3)
    spawn_fun = Keyword.get(opts, :spawn_fun, &do_spawn_passive_worker/4)
    dispatch_passive_issue(state, issue, attempt, acquire_fun, spawn_fun)
  end

  @doc false
  @spec passive_delay_ms_for_await_checks_for_test(map()) :: non_neg_integer()
  def passive_delay_ms_for_await_checks_for_test(run_state) when is_map(run_state) do
    passive_delay_ms_for_await_checks(run_state)
  end

  @doc false
  @spec schedule_issue_retry_for_test(State.t(), String.t(), non_neg_integer() | nil, map()) ::
          State.t()
  def schedule_issue_retry_for_test(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    schedule_issue_retry(state, issue_id, attempt, metadata)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues, %State{})
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()], term()) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues, %State{} = state) when is_list(issues) do
    sort_issues_for_dispatch(issues, state)
  end

  def sort_issues_for_dispatch_for_test(issues, _state) when is_list(issues) do
    sort_issues_for_dispatch(issues, %State{})
  end

  @spec manual_issue_refresh_state_for_test(State.t()) :: State.t()
  def manual_issue_refresh_state_for_test(%State{} = state),
    do: Controls.maybe_schedule_manual_issue_refresh(state)

  @doc false
  @spec process_candidate_issues_for_test(State.t(), [Issue.t()]) :: State.t()
  def process_candidate_issues_for_test(%State{} = state, issues) when is_list(issues) do
    process_candidate_issues(state, issues)
  end

  @spec review_follow_up_lease_status_for_test(State.t(), map()) :: term()
  def review_follow_up_lease_status_for_test(%State{} = state, run_state)
      when is_map(run_state) do
    review_follow_up_lease_status(state, run_state, Workspace.path_for_issue(issue_ref_for_run_state(run_state)))
  end

  @spec ensure_review_follow_up_lease_for_test(State.t(), map()) :: term()
  def ensure_review_follow_up_lease_for_test(%State{} = state, run_state)
      when is_map(run_state) do
    ensure_review_follow_up_lease(state, run_state, Workspace.path_for_issue(issue_ref_for_run_state(run_state)))
  end

  @spec release_review_follow_up_lease_for_test(State.t(), map(), Path.t()) :: State.t()
  def release_review_follow_up_lease_for_test(%State{} = state, run_state, workspace)
      when is_map(run_state) and is_binary(workspace) do
    release_review_follow_up_lease(state, run_state, workspace)
  end

  @spec persist_live_issue_lease_for_test(State.t(), Path.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def persist_live_issue_lease_for_test(%State{} = state, workspace, issue)
      when is_binary(workspace) and is_map(issue) do
    persist_live_issue_lease(state, workspace, issue)
  end

  @spec maybe_sync_running_issue_lease_for_test(State.t(), String.t()) :: :ok
  def maybe_sync_running_issue_lease_for_test(%State{} = state, issue_id)
      when is_binary(issue_id) do
    maybe_sync_running_issue_lease(state, issue_id)
  end

  @spec workspace_for_issue_id_for_test(State.t(), String.t()) :: Path.t() | nil
  def workspace_for_issue_id_for_test(%State{} = state, issue_id) when is_binary(issue_id) do
    workspace_for_issue_id(state, issue_id)
  end

  @spec maybe_clear_persisted_lease_for_test(Path.t() | nil) :: :ok
  def maybe_clear_persisted_lease_for_test(workspace), do: maybe_clear_persisted_lease(workspace)

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(issue, state, active_states, terminal_states, origin \\ nil)

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states, origin) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{SymphonyElixir.Util.issue_log_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      match?({:error, _}, resolve_policy(issue, state)) ->
        Logger.info("Issue has invalid policy routing: #{SymphonyElixir.Util.issue_log_context(issue)} labels=#{inspect(Issue.label_names(issue))}; moving issue to #{@blocked_state}")

        block_issue_for_policy_conflict(state, issue)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{SymphonyElixir.Util.issue_log_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      !issue_routed_to_current_runner_channel?(issue) ->
        Logger.info(
          "Issue no longer matches the current runner channel: #{SymphonyElixir.Util.issue_log_context(issue)} target_channel=#{issue_target_runner_channel(issue)} current_channel=#{Config.runner_channel()}; stopping active agent"
        )

        terminate_running_issue(state, issue.id, false)

      !issue_matches_required_labels?(issue) ->
        Logger.info("Issue no longer matches the configured label gate: #{SymphonyElixir.Util.issue_log_context(issue)} labels=#{inspect(Issue.label_names(issue))}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue, origin)

      true ->
        Logger.info("Issue moved to non-active state: #{SymphonyElixir.Util.issue_log_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states, _origin), do: state

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue, origin) do
    state = invalidate_tracker_inbox_cache(state, [issue], origin)
    issue_routing_cache = remember_issue_cache_entry(state.issue_routing_cache, issue)

    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{
          state
          | running: Map.put(state.running, issue.id, %{running_entry | issue: issue}),
            issue_routing_cache: issue_routing_cache
        }

      _ ->
        %{state | issue_routing_cache: issue_routing_cache}
    end
  end

  @doc false
  @spec terminate_running_issue(State.t(), String.t(), boolean()) :: State.t()
  def terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    completion = Map.get(Map.get(state.running, issue_id) || Map.get(state.lease_claims, issue_id) || %{}, :completion)
    outcome = tracker_inbox_cleanup_outcome(state, completion)
    state |> do_terminate_running_issue(issue_id, cleanup_workspace) |> tracker_inbox_outcome(issue_id, outcome) |> finish_tracker_inbox_action(completion, nil)
  end

  defp do_terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      %{execution_started?: true, agent_execution: _execution} = entry ->
        request_accounted_worker_stop(state, issue_id, entry, cleanup_workspace)

      %{lease_ownership_uncertain: reason} ->
        stop_for_uncertain_lease(state, issue_id, reason)

      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        with {:ok, _claim} <- current_issue_custody(state, issue_id, Map.get(running_entry, :custody_ref)) do
          case terminate_task(pid) do
            :ok ->
              if is_reference(ref), do: Process.demonitor(ref, [:flush])
              state = record_session_completion_totals(state, running_entry)
              state = %{state | running: Map.delete(state.running, issue_id)}
              state = cancel_dispatch_retry(state, issue_id)

              case finish_running_dispatch(running_entry, :shutdown) do
                :ok ->
                  if cleanup_workspace and not Map.has_key?(state.lease_claims, issue_id) and legacy_cleanup_allowed?(issue_id), do: cleanup_issue_workspace(identifier)
                  stop_terminal_dispatch(state, %{id: issue_id}, state.candidate_fetch_error)

                {:error, reason} ->
                  state
                  |> stop_terminal_dispatch(%{id: issue_id}, reason)
                  |> halt_dispatch_audit(issue_id, reason)
              end

            {:error, reason} ->
              halt_dispatch_audit(state, issue_id, reason)
          end
        else
          {:error, reason} -> stop_for_uncertain_lease(state, issue_id, reason)
        end

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.agent_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, _issue_id, %{execution_stop_requested: _request}, _now, _timeout_ms), do: state

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without agent activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_agent_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> Process.exit(pid, :shutdown)
    end

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :worker_termination_unconfirmed}
    end
  end

  defp terminate_task(_pid), do: :ok

  @doc false
  @spec partition_issues_by_label_gate([Issue.t()], State.t()) :: {[Issue.t()], [map()]}
  def partition_issues_by_label_gate(issues, %State{} = state) when is_list(issues) do
    Enum.reduce(issues, {[], []}, fn issue, {eligible, skipped} ->
      case dispatch_skip_reason(issue, state) do
        nil ->
          {[issue | eligible], skipped}

        reason ->
          Logger.info("[dispatch] skip #{issue.identifier || issue.id} reason=#{inspect(reason)}")

          {eligible, [skipped_issue_entry(issue, reason, state) | skipped]}
      end
    end)
    |> then(fn {eligible, skipped} ->
      {Enum.reverse(eligible), Enum.reverse(skipped)}
    end)
  end

  def partition_issues_by_label_gate(_issues, _state), do: {[], []}

  defp skipped_issue_entry(%Issue{} = issue, reason, %State{} = state) do
    workspace_path = Workspace.path_for_issue(issue.identifier || issue.id)
    run_state = load_run_state(workspace_path, issue)

    {policy_class, policy_source, policy_override} =
      policy_snapshot_values(issue, state, run_state)

    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      source: issue.source,
      state: issue.state,
      labels: Issue.label_names(issue),
      runner_channel: Config.runner_channel(),
      target_runner_channel: issue_target_runner_channel(issue),
      required_labels: routing_required_labels(),
      reason: reason,
      policy_class: policy_class,
      policy_source: policy_source,
      policy_override: policy_override,
      next_human_action: Map.get(run_state, :next_human_action) || next_human_action_for_skip(reason),
      last_rule_id: Map.get(run_state, :last_rule_id),
      last_failure_class: Map.get(run_state, :last_failure_class),
      last_decision_summary: Map.get(run_state, :last_decision_summary),
      last_ledger_event_id: Map.get(run_state, :last_ledger_event_id)
    }
  end

  defp skipped_issue_entry(_issue, reason, _state), do: %{reason: reason}

  defp choose_issues(issues, state, dispatch_fun \\ &dispatch_issue/2)

  defp choose_issues(issues, state, dispatch_fun) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch(state)
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_fun.(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues, %State{} = state) when is_list(issues) do
    issues
    |> PriorityEngine.rank_issues(
      priority_overrides: state.priority_overrides,
      retry_attempts: state.retry_attempts
    )
    |> Enum.map(& &1.issue)
  end

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    pack = PolicyPack.resolve(policy_pack_name(issue, state))
    id = issue.identifier || issue.id

    cond do
      !candidate_issue?(issue, active_states, terminal_states) ->
        Logger.info("[dispatch] reject #{id} check=candidate_issue")
        false

      todo_issue_blocked_by_non_terminal?(issue, terminal_states) ->
        Logger.info("[dispatch] reject #{id} check=blocked_by_non_terminal")
        false

      issue_paused?(state, issue) ->
        Logger.info("[dispatch] reject #{id} check=issue_paused")
        false

      MapSet.member?(claimed, issue.id) ->
        Logger.info("[dispatch] reject #{id} check=already_claimed")
        false

      Map.has_key?(running, issue.id) ->
        Logger.info("[dispatch] reject #{id} check=already_running")
        false

      available_slots(state) <= 0 ->
        Logger.info("[dispatch] reject #{id} check=no_available_slots")
        false

      !company_slots_available?(state, pack) ->
        Logger.info("[dispatch] reject #{id} check=company_slots_exhausted")
        false

      !state_slots_available?(issue, capacity_entries(state)) ->
        Logger.info("[dispatch] reject #{id} check=state_slots_exhausted")
        false

      true ->
        true
    end
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  @doc false
  @spec state_slots_available?(term(), map()) :: boolean()
  def state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  def state_slots_available?(_issue, _running), do: false

  defp company_slots_available?(%State{} = state, %PolicyPack{} = pack) do
    running = capacity_entries(state)

    case pack.max_concurrent_runs_per_company do
      limit when is_integer(limit) and limit > 0 ->
        map_size(running) < limit

      _ ->
        true
    end
  end

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = SymphonyElixir.Util.normalize_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        SymphonyElixir.Util.normalize_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  @doc false
  @spec candidate_issue?(term(), term(), term()) :: boolean()
  def candidate_issue?(
        %Issue{
          id: id,
          identifier: identifier,
          title: title,
          state: state_name
        } = issue,
        active_states,
        terminal_states
      )
      when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      issue_routed_to_current_runner_channel?(issue) and
      issue_matches_required_labels?(issue) and
      match?({:ok, _}, resolve_policy(issue, %State{})) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  defp issue_labels(_issue), do: []

  @doc false
  @spec issue_matches_required_labels?(term()) :: boolean()
  def issue_matches_required_labels?(%Issue{} = issue) do
    label_gate_status(issue).eligible?
  end

  def issue_matches_required_labels?(_issue), do: true

  @doc false
  @spec label_gate_status(term()) :: map()
  def label_gate_status(%Issue{source: :manual}) do
    %{eligible?: true, required_labels: [], reason: nil}
  end

  def label_gate_status(%Issue{} = issue) do
    required_labels = routing_required_labels()
    required_label_set = normalize_labels(required_labels)

    if MapSet.size(required_label_set) == 0 do
      %{eligible?: true, required_labels: required_labels, reason: nil}
    else
      issue_label_set = issue |> Issue.label_names() |> normalize_labels()

      cond do
        MapSet.subset?(required_label_set, issue_label_set) ->
          %{eligible?: true, required_labels: required_labels, reason: nil}

        missing_canary_labels?(issue_label_set, required_label_set) ->
          %{eligible?: false, required_labels: required_labels, reason: "missing canary labels"}

        true ->
          %{eligible?: false, required_labels: required_labels, reason: "missing required labels"}
      end
    end
  end

  def label_gate_status(_issue),
    do: %{eligible?: true, required_labels: routing_required_labels(), reason: nil}

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    SymphonyElixir.Util.normalize_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, SymphonyElixir.Util.normalize_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, SymphonyElixir.Util.normalize_state(state_name))
  end

  @doc false
  @spec terminal_state_set() :: MapSet.t()
  def terminal_state_set do
    Config.linear_terminal_states()
    |> Enum.map(&SymphonyElixir.Util.normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.linear_active_states()
    |> Enum.map(&SymphonyElixir.Util.normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
    |> MapSet.put(SymphonyElixir.Util.normalize_state(@merging_state))
  end

  defp normalize_labels(labels) do
    labels
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue) do
    dispatch_runtime_issue(state, issue, nil)
  end

  defp dispatch_issue(%State{} = state, issue, attempt) do
    dispatch_runtime_issue(state, issue, attempt)
  end

  defp dispatch_active_issue(%State{} = state, issue, attempt) do
    dispatch_active_issue(
      state,
      issue,
      attempt,
      &IssueSource.fetch_issue_states_by_ids/1,
      &do_dispatch_issue/3
    )
  end

  defp dispatch_active_issue(%State{} = state, issue, attempt, issue_fetcher, dispatch_fun)
       when is_function(issue_fetcher, 1) and is_function(dispatch_fun, 3) do
    case revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        dispatch_fun.(state, refreshed_issue, attempt)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{SymphonyElixir.Util.issue_log_context(issue)}")

        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info(
          "Skipping stale dispatch after issue refresh: #{SymphonyElixir.Util.issue_log_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}"
        )

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{SymphonyElixir.Util.issue_log_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt) do
    do_dispatch_issue(state, issue, attempt, &LeaseManager.acquire/3, &do_spawn_issue_worker/4)
  end

  defp do_dispatch_issue(%State{admission_read: %{purpose: :promotion, issue: %{id: id}}} = state, %{id: id}, _attempt, _acquire_fun, _spawn_fun), do: state

  defp do_dispatch_issue(%State{admission_read: reader} = state, issue, attempt, _acquire_fun, _spawn_fun) when not is_nil(reader) do
    if tracker_inbox_completion(state, issue.id),
      do: tracker_inbox_outcome(state, issue.id, {:recheck, :admission_reader_occupied}),
      else: schedule_issue_retry(state, issue.id, attempt, %{identifier: issue.identifier, issue: issue, delay_type: :passive_continuation, error: "admission reader occupied"})
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, acquire_fun, spawn_fun)
       when is_function(acquire_fun, 3) and is_function(spawn_fun, 4) do
    recipient = self()

    with {:ok, workspace} <- current_custody_workspace(state, issue),
         :ok <- DeployAudit.ensure_available(workspace) do
      case acquire_issue_custody(state, issue, acquire_fun, workspace) do
        {:ok, state} ->
          case persist_dispatchable_issue_lease(state, workspace, issue) do
            {:ok, _run_state} ->
              state = spawn_fun.(state, issue, attempt, recipient)
              if Map.has_key?(state.running, issue.id), do: invalidate_admission_issue(state, issue.id, tracker_inbox_origin(state, issue.id)), else: state

            {:error, reason} ->
              Logger.warning("Skipping dispatch; failed to persist lease state for #{SymphonyElixir.Util.issue_log_context(issue)}: #{inspect(reason)}")

              state |> release_issue_claim(issue.id) |> tracker_inbox_outcome(issue.id, {:blocked, {:lease_snapshot_failed, reason}})
          end

        {:error, :claimed} ->
          Logger.info("Skipping dispatch; lease already held for #{SymphonyElixir.Util.issue_log_context(issue)}")
          tracker_inbox_outcome(state, issue.id, {:applied, :dispatch_rejected})

        {:error, reason} ->
          Logger.warning("Skipping dispatch; failed to acquire lease for #{SymphonyElixir.Util.issue_log_context(issue)}: #{inspect(reason)}")
          tracker_inbox_outcome(state, issue.id, {:blocked, {:lease_acquire_failed, reason}})
      end
    else
      {:error, reason} -> halt_dispatch_audit(state, issue.id, reason)
    end
  end

  defp do_spawn_issue_worker(%State{} = state, issue, attempt, recipient) do
    do_spawn_issue_worker(state, issue, attempt, recipient, &Task.Supervisor.start_child/2)
  end

  defp do_spawn_issue_worker(%State{} = state, issue, attempt, recipient, start_child_fun)
       when is_function(start_child_fun, 2) do
    workspace = workspace_for_issue_id(state, issue.id)

    with {:ok, initial_stage} <- persisted_dispatch_stage(issue, workspace),
         _normalized_stage <- normalize_dispatch_stage(issue, workspace),
         {:ok, stage} <- persisted_dispatch_stage(issue, workspace) do
      if stage in ["merge_readiness", "await_checks", "merge", "post_merge"] do
        start_passive_issue_worker(state, issue, attempt, recipient, start_child_fun, stage)
      else
        if initial_stage in ["merge_readiness", "await_checks", "merge", "post_merge"] do
          start_promotion_read(state, issue, attempt, recipient, start_child_fun, initial_stage, stage)
        else
          start_active_issue_worker(state, issue, attempt, recipient, start_child_fun, stage)
        end
      end
    else
      {:error, {tag, _} = reason} when tag in [:deploy_audit_pending, :deploy_audit_read_failed] ->
        halt_dispatch_audit(state, issue.id, reason)

      {:error, reason} ->
        stop_terminal_dispatch(state, issue, reason)
    end
  end

  defp start_active_issue_worker(%State{} = state, issue, attempt, recipient, start_child_fun, dispatch_stage)
       when is_function(start_child_fun, 2) do
    policy_override = Map.get(state.policy_overrides, issue.identifier)
    workspace = workspace_for_issue_id(state, issue.id)

    retry_metadata = Map.get(state.retry_attempts, issue.id, %{})

    run_state =
      workspace
      |> RunStateStore.load_or_default(issue)
      |> merge_retry_budget_resume_context(retry_metadata)

    with :ok <- RunStateStore.ensure_readable(workspace),
         {:ok, _stage} <- persisted_dispatch_stage(issue, workspace),
         stage <- Map.get(run_state, :stage),
         {:ok, pid, ticket} <-
           start_audited_worker(
             state,
             issue,
             attempt,
             run_state,
             start_child_fun,
             fn ->
               AgentRunner.run(issue, recipient, attempt: attempt, policy_override: policy_override)
             end,
             false
           ) do
      state = transfer_issue_custody(state, issue.id, :gated)
      claim = Map.fetch!(state.lease_claims, issue.id)
      ref = Process.monitor(pid)
      {policy_class, policy_source, _policy_override} = policy_snapshot_values(issue, state, run_state)

      Logger.info("Dispatching issue to agent: #{SymphonyElixir.Util.issue_log_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

      running =
        Map.put(state.running, issue.id, %{
          pid: pid,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          last_agent_message: nil,
          last_agent_timestamp: nil,
          last_agent_event: nil,
          agent_process_id: nil,
          agent_input_tokens: 0,
          agent_output_tokens: 0,
          agent_total_tokens: 0,
          issue_token_usage_base: Map.get(run_state, :token_usage, %{}),
          agent_last_reported_input_tokens: 0,
          agent_last_reported_output_tokens: 0,
          agent_last_reported_total_tokens: 0,
          turn_started_input_tokens: 0,
          turn_count: 0,
          recent_agent_updates: [],
          retry_attempt: normalize_retry_attempt(attempt),
          workspace_path: workspace,
          dispatch_stage: dispatch_stage,
          policy_override: policy_override,
          policy_class: policy_class,
          policy_source: policy_source,
          workspace: workspace,
          stage: stage,
          resume_context: Map.get(run_state, :resume_context, %{}),
          last_ledger_event_id: ticket.entry_event_id,
          dispatch_ticket: ticket,
          agent_execution: %{context: execution_context(ticket, claim.token, self(), pid), registry: AgentExecution.new_registry()},
          lease_token: claim.token,
          custody_ref: claim.custody_ref,
          completion: Map.get(claim, :completion),
          promotion_deadline: claim.deadline,
          started_at: DateTime.utc_now()
        })

      send(self(), {:authorize_dispatch, issue.id, ticket.dispatch_id, pid})

      %{
        state
        | running: running,
          claimed: MapSet.put(state.claimed, issue.id),
          retry_attempts: Map.delete(state.retry_attempts, issue.id)
      }
      |> tracker_inbox_wait(issue.id, :gate)
    else
      {:error, {tag, _} = reason} when tag in [:deploy_audit_pending, :deploy_audit_read_failed] ->
        halt_dispatch_audit(state, issue.id, reason)

      {:error, {:dispatch_audit_failed, {tag, _} = reason}} when tag in [:deploy_audit_pending, :deploy_audit_read_failed] ->
        halt_dispatch_audit(state, issue.id, reason)

      {:error, {:dispatch_audit_failed, reason}} ->
        state
        |> stop_terminal_dispatch(issue, reason)
        |> halt_dispatch_audit(issue.id, reason)

      {:error, {:persisted_stage_requires_explicit_resume, _stage} = reason} ->
        stop_terminal_dispatch(state, issue, reason)

      {:error, reason} ->
        {state, reason} = tracker_inbox_worker_start_failure(state, issue.id, reason)
        Logger.error("Unable to spawn agent for #{SymphonyElixir.Util.issue_log_context(issue)}: #{inspect(reason)}")
        state = tracker_inbox_outcome(state, issue.id, {:applied, :dispatch_rejected})
        state = release_issue_claim(state, issue.id)
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}"
        })
    end
  end

  defp dispatch_passive_issue(%State{} = state, %Issue{} = issue, attempt) do
    dispatch_passive_issue(
      state,
      issue,
      attempt,
      &LeaseManager.acquire/3,
      &do_spawn_passive_worker/4
    )
  end

  defp dispatch_passive_issue(%State{} = state, %Issue{} = issue, attempt, acquire_fun, spawn_fun)
       when is_function(acquire_fun, 3) and is_function(spawn_fun, 4) do
    cond do
      Map.has_key?(state.running, issue.id) ->
        state

      MapSet.member?(state.claimed, issue.id) ->
        case persisted_dispatch_stage(issue) do
          {:ok, _stage} ->
            do_dispatch_issue(state, issue, attempt, acquire_fun, spawn_fun)

          {:error, {:persisted_stage_requires_explicit_resume, _stage} = reason} ->
            stop_terminal_dispatch(state, issue, reason)

          {:error, reason} ->
            state = tracker_inbox_outcome(state, issue.id, tracker_inbox_validation_outcome(reason))
            %{state | candidate_fetch_error: reason}
        end

      true ->
        do_dispatch_issue(state, issue, attempt, acquire_fun, spawn_fun)
    end
  end

  defp do_spawn_passive_worker(%State{} = state, issue, attempt, recipient) do
    do_spawn_passive_worker(state, issue, attempt, recipient, &Task.Supervisor.start_child/2)
  end

  defp do_spawn_passive_worker(%State{} = state, issue, attempt, recipient, start_child_fun)
       when is_function(start_child_fun, 2) do
    do_spawn_issue_worker(state, issue, attempt, recipient, start_child_fun)
  end

  defp start_passive_issue_worker(%State{} = state, issue, attempt, recipient, start_child_fun, dispatch_stage)
       when is_function(start_child_fun, 2) do
    policy_override = Map.get(state.policy_overrides, issue.identifier)
    workspace = workspace_for_issue_id(state, issue.id)

    retry_metadata = Map.get(state.retry_attempts, issue.id, %{})

    with {:ok, _stage} <- persisted_dispatch_stage(issue, workspace),
         {:ok, run_state} <- ensure_dispatch_run_state(state, workspace, issue),
         run_state <- merge_retry_budget_resume_context(run_state, retry_metadata),
         stage <- Map.get(run_state, :stage),
         {:ok, pid, ticket} <-
           start_audited_worker(
             state,
             issue,
             attempt,
             run_state,
             start_child_fun,
             fn ->
               case AgentExecution.entry_context(Workspace.path_for_issue(issue), issue) do
                 {:ok, _context} -> :ok
                 {:stop, {:accounting_uncertain, cause}} -> exit({:accounting_uncertain, cause})
               end

               workspace =
                 case Workspace.create_for_issue(issue) do
                   {:ok, path} ->
                     path

                   {:error, reason} ->
                     raise RuntimeError, "Passive worker setup failed: #{inspect(reason)}"
                 end

               case DeliveryEngine.run(
                      workspace,
                      issue,
                      recipient,
                      attempt: attempt,
                      policy_override: policy_override,
                      issue_state_fetcher: &IssueSource.fetch_issue_states_by_ids/1
                    ) do
                 :ok -> :ok
                 {:done, _issue} -> :ok
                 {:stop, {:accounting_uncertain, _cause}} = terminal -> terminal
                 {:stop, _reason} -> :ok
                 {:error, reason} -> raise RuntimeError, "Passive worker failed: #{inspect(reason)}"
               end
             end,
             true
           ) do
      state = transfer_issue_custody(state, issue.id, :gated)
      claim = Map.fetch!(state.lease_claims, issue.id)
      ref = Process.monitor(pid)
      {policy_class, policy_source, _policy_override} = policy_snapshot_values(issue, state, run_state)

      Logger.info("Dispatching issue to passive runtime worker: #{SymphonyElixir.Util.issue_log_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

      running =
        Map.put(state.running, issue.id, %{
          pid: pid,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          last_agent_message: nil,
          last_agent_timestamp: nil,
          last_agent_event: nil,
          agent_process_id: nil,
          agent_input_tokens: 0,
          agent_output_tokens: 0,
          agent_total_tokens: 0,
          issue_token_usage_base: Map.get(run_state, :token_usage, %{}),
          agent_last_reported_input_tokens: 0,
          agent_last_reported_output_tokens: 0,
          agent_last_reported_total_tokens: 0,
          turn_started_input_tokens: 0,
          turn_count: 0,
          recent_agent_updates: [],
          retry_attempt: normalize_retry_attempt(attempt),
          workspace_path: workspace,
          dispatch_stage: dispatch_stage,
          policy_override: policy_override,
          policy_class: policy_class,
          policy_source: policy_source,
          workspace: workspace,
          stage: stage,
          resume_context: Map.get(run_state, :resume_context, %{}),
          last_ledger_event_id: ticket.entry_event_id,
          dispatch_ticket: ticket,
          agent_execution: %{context: execution_context(ticket, claim.token, self(), pid), registry: AgentExecution.new_registry()},
          lease_token: claim.token,
          custody_ref: claim.custody_ref,
          completion: Map.get(claim, :completion),
          promotion_deadline: claim.deadline,
          passive?: true,
          started_at: DateTime.utc_now()
        })

      send(self(), {:authorize_dispatch, issue.id, ticket.dispatch_id, pid})

      %{
        state
        | running: running,
          claimed: MapSet.put(state.claimed, issue.id),
          retry_attempts: Map.delete(state.retry_attempts, issue.id)
      }
      |> tracker_inbox_wait(issue.id, :gate)
    else
      {:error, {tag, _} = reason} when tag in [:deploy_audit_pending, :deploy_audit_read_failed] ->
        halt_dispatch_audit(state, issue.id, reason)

      {:error, {:dispatch_audit_failed, {tag, _} = reason}} when tag in [:deploy_audit_pending, :deploy_audit_read_failed] ->
        halt_dispatch_audit(state, issue.id, reason)

      {:error, {:dispatch_audit_failed, reason}} ->
        state
        |> stop_terminal_dispatch(issue, reason)
        |> halt_dispatch_audit(issue.id, reason)

      {:error, {:persisted_stage_requires_explicit_resume, _stage} = reason} ->
        stop_terminal_dispatch(state, issue, reason)

      {:error, reason} ->
        {state, reason} = tracker_inbox_worker_start_failure(state, issue.id, reason)
        Logger.error("Unable to spawn passive runtime worker for #{SymphonyElixir.Util.issue_log_context(issue)}: #{inspect(reason)}")
        state = tracker_inbox_outcome(state, issue.id, {:applied, :dispatch_rejected})
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn passive runtime worker: #{inspect(reason)}",
          delay_type: :passive_continuation,
          issue: issue
        })
    end
  end

  defp start_audited_worker(state, issue, attempt, run_state, start_child_fun, worker_fun, passive?) do
    workspace = workspace_for_issue_id(state, issue.id)
    owner = self()
    {policy_class, policy_source, _override} = policy_snapshot_values(issue, state, run_state)

    with {:ok, claim} <- current_issue_custody(state, issue.id),
         lease = claim.lease,
         {:ok, ticket} <-
           DispatchAudit.begin(workspace, %{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             actor_type: "runtime",
             actor_id: state.lease_owner,
             policy_class: policy_class,
             metadata: %{owner: state.lease_owner, epoch: lease["epoch"], passive: passive?, policy_source: policy_source, retry_attempt: normalize_retry_attempt(attempt)}
           }) do
      case start_child_fun.(SymphonyElixir.TaskSupervisor, fn ->
             DispatchGate.run(owner, ticket.dispatch_id, fn ->
               case DispatchAudit.with_authorization(ticket, fn ->
                      {:executed, AgentExecution.with_context(ticket, claim.token, owner, worker_fun)}
                    end) do
                 {:executed, {:stop, {:accounting_uncertain, cause}}} -> exit({:accounting_uncertain, cause})
                 {:executed, result} -> result
                 {:error, reason} -> exit({:accounting_uncertain, {:dispatch_authorization_failed, reason}})
               end
             end)
           end) do
        {:ok, pid} ->
          {:ok, pid, ticket}

        {:error, reason} ->
          case DispatchAudit.finish(ticket, :not_started) do
            :ok -> {:error, {:dispatch_worker_start_failed, reason}}
            {:error, audit_reason} -> {:error, {:dispatch_audit_failed, audit_reason}}
          end
      end
    else
      {:error, reason} -> {:error, {:dispatch_audit_failed, reason}}
    end
  end

  defp finish_completed_dispatch(running_entry, reason) do
    case finish_running_dispatch(running_entry, reason) do
      {:ownership_uncertain, _reason} = uncertain ->
        uncertain

      result ->
        workspace = Map.get(running_entry, :workspace_path) || Workspace.path_for_issue(running_entry.identifier)

        case {DeployAudit.ensure_available(workspace), result} do
          {:ok, result} ->
            result

          {{:error, pending}, :ok} ->
            {:error, pending}

          {{:error, {tag, detail}}, {:error, finish_error}} ->
            {:error, {tag, %{journal: detail, dispatch_finish_error: finish_error}}}
        end
    end
  end

  defp finish_running_dispatch(%{lease_ownership_uncertain: reason}, _exit_reason),
    do: {:ownership_uncertain, reason}

  defp finish_running_dispatch(%{dispatch_ticket: _ticket}, {:dispatch_authorization_failed, _reason} = failure),
    do: {:error, failure}

  defp finish_running_dispatch(%{dispatch_ticket: ticket}, reason) do
    outcome = if reason == :normal, do: :normal, else: {:exit, reason}
    DispatchAudit.finish(ticket, outcome)
  end

  defp finish_running_dispatch(_legacy_entry, _reason), do: :ok

  defp cancel_dispatch_retry(state, issue_id) do
    case get_in(state.retry_attempts, [issue_id, :timer_ref]) do
      timer when is_reference(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  defp halt_dispatch_audit(state, issue_id, reason) do
    Logger.error("Dispatch audit blocked issue_id=#{issue_id}; preserve its journal: #{inspect(reason)}")
    state = cancel_dispatch_retry(state, issue_id)
    state = tracker_inbox_failure(state, issue_id, {:dispatch_audit_failed, reason})
    %{state | candidate_fetch_error: {:dispatch_audit_failed, issue_id, reason}}
  end

  defp ensure_dispatch_run_state(%State{} = state, workspace, issue)
       when is_binary(workspace) and is_map(issue) do
    case RunStateStore.load(workspace) do
      {:ok, run_state} ->
        {:ok, run_state}

      {:error, :missing} ->
        case persist_live_issue_lease(state, workspace, issue) do
          {:ok, run_state} ->
            {:ok, run_state}

          {:error, :missing} ->
            persist_issue_run_state(workspace, issue)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_issue_run_state(workspace, issue) when is_binary(workspace) and is_map(issue) do
    run_state = RunStateStore.load_or_default(workspace, issue)

    case RunStateStore.save(workspace, run_state) do
      :ok -> {:ok, run_state}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec revalidate_issue_for_dispatch(Issue.t(), term(), MapSet.t()) :: {:ok, Issue.t()} | {:skip, term()} | {:error, term()}
  def revalidate_issue_for_dispatch(%Issue{id: issue_id} = issue, issue_fetcher, terminal_states)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        refreshed_issue = merge_dispatch_refresh_issue(issue, refreshed_issue)

        cond do
          retry_candidate_issue?(refreshed_issue, terminal_states) ->
            {:ok, refreshed_issue}

          manual_dispatch_resume_override?(issue, refreshed_issue, terminal_states) ->
            {:ok, %{refreshed_issue | state: issue.state, blocked_by: Map.get(issue, :blocked_by, [])}}

          true ->
            {:skip, refreshed_issue}
        end

      {:ok, []} ->
        missing_issue_dispatch_fallback(issue, terminal_states)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp merge_dispatch_refresh_issue(%Issue{} = issue, %Issue{} = refreshed_issue) do
    issue_map = Map.from_struct(issue)

    refreshed_issue
    |> Map.from_struct()
    |> Enum.reduce(issue_map, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
    |> then(&struct(Issue, &1))
  end

  defp merge_dispatch_refresh_issue(issue, _refreshed_issue), do: issue

  defp manual_dispatch_resume_override?(
         %Issue{source: :manual, state: issue_state} = issue,
         %Issue{source: :manual, state: refreshed_state} = refreshed_issue,
         terminal_states
       )
       when is_binary(issue_state) and is_binary(refreshed_state) do
    issue.identifier == refreshed_issue.identifier and
      active_issue_state?(issue_state, active_state_set()) and
      retry_candidate_issue?(issue, terminal_states) and
      refreshed_state == @blocked_state and
      not retry_candidate_issue?(refreshed_issue, terminal_states)
  end

  defp manual_dispatch_resume_override?(_issue, _refreshed_issue, _terminal_states), do: false

  defp missing_issue_dispatch_fallback(%Issue{source: :manual} = issue, terminal_states) do
    if retry_candidate_issue?(issue, terminal_states) do
      {:ok, issue}
    else
      {:skip, issue}
    end
  end

  defp missing_issue_dispatch_fallback(_issue, _terminal_states), do: {:skip, :missing}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: Map.put(state.completed, issue_id, System.monotonic_time(:millisecond)),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    case Map.get(state.running, issue_id) do
      %{execution_stop_requested: request, agent_execution: %{registry: %{uncertain: nil}}} = entry ->
        request = Map.put(request, :retry, %{attempt: attempt, metadata: metadata})
        %{state | running: Map.put(state.running, issue_id, %{entry | execution_stop_requested: request})}

      %{execution_stop_requested: _request, agent_execution: _execution} ->
        state

      _ ->
        schedule_available_issue_retry(state, issue_id, attempt, metadata)
    end
  end

  defp schedule_available_issue_retry(state, issue_id, attempt, metadata) do
    identifier = Map.get(metadata, :identifier) || get_in(state.retry_attempts, [issue_id, :identifier])
    workspace = workspace_for_issue_id(state, issue_id) || if(is_binary(identifier), do: Workspace.path_for_issue(identifier))

    availability =
      if is_binary(workspace) do
        with :ok <- DeployAudit.ensure_available(workspace), do: DispatchAudit.ensure_available(workspace)
      else
        :ok
      end

    case availability do
      :ok -> do_schedule_issue_retry(state, issue_id, attempt, metadata)
      {:error, reason} -> halt_dispatch_audit(state, issue_id, reason)
    end
  end

  defp do_schedule_issue_retry(state, issue_id, attempt, metadata, delay_override \\ nil, persist_context? \\ true) do
    state = transfer_issue_custody(state, issue_id, :retry)
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    metadata = Map.merge(retry_metadata(previous_retry), metadata)
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = delay_override || retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    retry_ref = make_ref()
    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_ref}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    if persist_context? do
      workspace = workspace_for_issue_id(state, issue_id) || if(is_binary(identifier), do: Workspace.path_for_issue(identifier))
      persist_retry_budget_resume_context(workspace, identifier, metadata)
    end

    %{
      state
      | retry_attempts:
          Map.put(
            state.retry_attempts,
            issue_id,
            %{
              custody_ref: get_in(state.lease_claims, [issue_id, :custody_ref]),
              lease_token: get_in(state.lease_claims, [issue_id, :token]),
              attempt: next_attempt,
              retry_ref: retry_ref,
              status: :scheduled,
              timer_ref: timer_ref,
              due_at_ms: due_at_ms,
              identifier: identifier,
              error: error
            }
            |> Map.merge(Map.drop(metadata, [:identifier, :error, :attempt, :timer_ref, :due_at_ms, :retry_ref, :status, :custody_ref, :lease_token]))
          )
    }
  end

  defp dispatch_retry_guard(state, issue_id) do
    case get_in(state.retry_attempts, [issue_id, :identifier]) do
      identifier when is_binary(identifier) ->
        workspace = workspace_for_issue_id(state, issue_id) || Workspace.path_for_issue(identifier)

        with :ok <- DeployAudit.ensure_available(workspace),
             :ok <- DispatchAudit.ensure_available(workspace),
             do: SymphonyElixir.RunIdentity.ensure_issue(workspace, %{id: issue_id, identifier: identifier})

      _ ->
        :ok
    end
  end

  defp retry_metadata(entry), do: Map.drop(entry, [:attempt, :timer_ref, :due_at_ms, :retry_ref, :status])

  defp defer_ready_retries(state) do
    Enum.reduce(state.retry_attempts, state, fn
      {id, %{status: :ready} = entry}, current -> rearm_retry(current, id, entry)
      _, current -> current
    end)
  end

  defp rearm_retry(state, id, entry) do
    delay =
      if tracker_backoff_active?(state),
        do: max(1, state.tracker_backoff_until_ms - System.monotonic_time(:millisecond)),
        else: retry_delay(entry.attempt, entry)

    do_schedule_issue_retry(state, id, entry.attempt, retry_metadata(entry), delay, false)
  end

  defp start_retry_lookup(state, id, entry, context) do
    state = %{state | max_concurrent_agents: Config.max_concurrent_agents()}
    issue = %Issue{id: id, identifier: entry.identifier}

    cond do
      Map.has_key?(state.running, id) or issue_paused?(state, issue) ->
        cancel_dispatch_retry(state, id)

      not Map.get(RunnerRuntime.runner_health(), :dispatch_enabled, true) ->
        rearm_retry(state, id, entry)

      not ManualIssueSpec.runtime_issue_id?(id) and tracker_backoff_active?(state) ->
        rearm_retry(state, id, entry)

      true ->
        with :ok <- dispatch_retry_guard(state, id),
             {:ok, lease_identity} <- retry_lease_identity(state, id) do
          state = put_in(state.retry_attempts[id].status, :reading)
          passive? = entry[:delay_type] == :passive_continuation
          manual_only? = tracker_backoff_active?(state)

          read = fn ->
            cond do
              passive? -> IssueSource.fetch_issue(%{id: id}, context)
              manual_only? -> {:ok, %{tracker: :disabled, manual: IssueSource.fetch_manual_candidate_issues(context)}}
              true -> {:ok, IssueSource.fetch_candidate_outcomes(context)}
            end
          end

          operation = %{
            purpose: :retry,
            phase: :lookup,
            issue: issue,
            retry_ref: entry.retry_ref,
            fingerprint: context.fingerprint,
            backoff: tracker_poll_backoff_identity(state),
            lease_identity: lease_identity,
            invalidated: false
          }

          start_retry_read(state, operation, read)
        else
          {:error, reason} -> halt_dispatch_audit(state, id, reason)
        end
    end
  end

  defp start_retry_refresh(state, issue, _attempt) do
    entry = Map.fetch!(state.retry_attempts, issue.id)

    with {:ok, context} <- capture_tracker_poll_context(),
         {:ok, lease_identity} <- retry_lease_identity(state, issue.id) do
      operation = %{
        purpose: :retry,
        phase: :refresh,
        issue: issue,
        retry_ref: entry.retry_ref,
        fingerprint: context.fingerprint,
        backoff: tracker_poll_backoff_identity(state),
        lease_identity: lease_identity,
        invalidated: false
      }

      id = issue.id
      start_retry_read(state, operation, fn -> IssueSource.fetch_issue_states_by_ids([id], context) end)
    else
      {:error, reason} ->
        state |> Map.put(:candidate_fetch_error, reason) |> rearm_retry(issue.id, entry)
    end
  end

  defp start_retry_read(state, operation, read) do
    case TrackerReader.start(read) do
      {:ok, reader} -> %{state | admission_read: Map.merge(operation, reader)}
      {:error, reason} -> retry_read_error(state, operation, {:tracker_reader_start_failed, reason})
    end
  end

  defp retry_lease_identity(state, id) do
    with {:ok, storage} <- retry_lease_storage(state, id) do
      case LeaseManager.read_at(storage) do
        {:ok, lease} -> {:ok, %{storage: storage, identity: Map.take(lease, ["owner", "epoch", "acquired_at", "lease_version", "lease_generation"])}}
        {:error, :missing} -> {:ok, %{storage: storage, identity: :missing}}
        {:error, reason} -> {:error, {:retry_lease_read_failed, id, reason}}
      end
    end
  end

  defp retry_lease_storage(state, id) do
    case Map.get(state.lease_claims, id) do
      %{token: token} -> {:ok, token.storage}
      nil -> LeaseManager.capture_storage(id)
    end
  end

  defp receive_retry_result(state, operation, result) do
    id = operation.issue.id

    case capture_tracker_poll_context() do
      {:ok, context} when context.fingerprint == operation.fingerprint ->
        state =
          if retry_generation_current?(state, operation),
            do: %{state | max_concurrent_agents: Config.max_concurrent_agents()},
            else: state

        {state, result} = observe_retry_transport(state, operation, result)

        state =
          cond do
            not retry_generation_current?(state, operation) ->
              state

            operation.invalidated ->
              rearm_current_retry(state, operation)

            Map.has_key?(state.running, id) or issue_paused?(state, operation.issue) ->
              cancel_dispatch_retry(state, id)

            retry_lease_identity(state, id) != {:ok, operation.lease_identity} ->
              rearm_current_retry(state, operation)

            result == :discarded ->
              rearm_current_retry(state, operation)

            true ->
              case dispatch_retry_guard(state, id) do
                :ok -> apply_retry_result(state, operation, result)
                {:error, reason} -> halt_dispatch_audit(state, id, reason)
              end
          end

        finish_retry_read(state, operation)

      _ ->
        state
        |> Map.put(:candidate_fetch_error, :admission_context_changed)
        |> Map.put(:admission_batch, nil)
        |> rearm_current_retry(operation)
    end
  end

  defp retry_generation_current?(state, operation) do
    case Map.get(state.retry_attempts, operation.issue.id) do
      %{retry_ref: ref, status: :reading, identifier: identifier} ->
        ref == operation.retry_ref and identifier == operation.issue.identifier

      _ ->
        false
    end
  end

  defp rearm_current_retry(state, operation) do
    if retry_generation_current?(state, operation),
      do: rearm_retry(state, operation.issue.id, Map.fetch!(state.retry_attempts, operation.issue.id)),
      else: state
  end

  defp finish_retry_read(state, operation) do
    if is_nil(state.admission_read) and retry_generation_current?(state, operation),
      do: cancel_dispatch_retry(state, operation.issue.id),
      else: state
  end

  defp observe_retry_transport(state, operation, {:ok, %{tracker: tracker, manual: manual}}) do
    {state, tracker} = observe_retry_remote(state, operation, tracker)
    selected = if ManualIssueSpec.runtime_issue_id?(operation.issue.id), do: manual, else: tracker
    selected = if selected == :disabled, do: {:ok, []}, else: selected
    {state, selected}
  end

  defp observe_retry_transport(state, operation, result) do
    if ManualIssueSpec.runtime_issue_id?(operation.issue.id),
      do: {state, result},
      else: observe_retry_remote(state, operation, result)
  end

  defp observe_retry_remote(state, _operation, :disabled), do: {state, :disabled}

  defp observe_retry_remote(state, operation, result) do
    if tracker_poll_backoff_identity(state) == operation.backoff,
      do: tracker_read(state, fn -> result end),
      else: {state, :discarded}
  end

  defp apply_retry_result(state, operation, {:error, reason}), do: retry_read_error(state, operation, reason)

  defp apply_retry_result(state, %{phase: :lookup} = operation, {:ok, result}) do
    entry = Map.fetch!(state.retry_attempts, operation.issue.id)
    issue = if is_list(result), do: find_issue_by_id(result, operation.issue.id), else: result
    issue = issue || manual_retry_issue_fallback(entry)

    if is_nil(issue) or retry_issue_identity?(issue, operation.issue) do
      {:noreply, next} = handle_retry_issue_lookup(issue, state, operation.issue.id, entry.attempt, retry_metadata(entry))
      next
    else
      admission_discard(state, operation.issue, :admission_identity_mismatch)
    end
  end

  defp apply_retry_result(state, %{phase: :refresh} = operation, {:ok, []}),
    do: apply_retry_refresh(state, operation, [])

  defp apply_retry_result(state, %{phase: :refresh, issue: expected} = operation, {:ok, [%Issue{id: id, identifier: identifier} = issue]})
       when id == expected.id and identifier == expected.identifier,
       do: apply_retry_refresh(state, operation, [issue])

  defp apply_retry_result(state, %{phase: :refresh} = operation, {:ok, _issues}),
    do: admission_discard(state, operation.issue, :admission_identity_mismatch)

  defp apply_retry_refresh(state, operation, issues) do
    case revalidate_issue_for_dispatch(operation.issue, fn _ -> {:ok, issues} end, terminal_state_set()) do
      {:ok, issue} ->
        if retry_issue_identity?(issue, operation.issue) and retry_active_current?(state, issue) do
          entry = Map.fetch!(state.retry_attempts, issue.id)

          if dispatch_slots_available?(issue, state) and company_slots_available?(state, PolicyPack.resolve(policy_pack_name(issue, state))) do
            dispatch_runtime_issue(state, issue, entry.attempt, &do_dispatch_issue/3, &dispatch_passive_issue/3)
          else
            schedule_issue_retry(state, issue.id, entry.attempt + 1, Map.put(retry_metadata(entry), :error, "no available orchestrator slots"))
          end
        else
          admission_discard(state, operation.issue, :admission_refresh_ineligible)
        end

      {:skip, _} ->
        admission_discard(state, operation.issue, :admission_refresh_ineligible)

      {:error, reason} ->
        retry_read_error(state, operation, reason)
    end
  end

  defp retry_issue_identity?(%Issue{id: id, identifier: identifier}, expected), do: id == expected.id and identifier == expected.identifier
  defp retry_issue_identity?(_issue, _expected), do: false

  defp retry_active_current?(state, issue) do
    not Map.has_key?(state.running, issue.id) and not issue_paused?(state, issue) and
      Map.get(RunnerRuntime.runner_health(), :dispatch_enabled, true) and
      is_nil(dispatch_skip_reason(issue, state)) and
      retry_candidate_issue?(issue, terminal_state_set()) and
      not todo_issue_blocked_by_non_terminal?(issue, terminal_state_set())
  end

  defp retry_read_error(state, operation, reason) do
    entry = Map.fetch!(state.retry_attempts, operation.issue.id)

    prefix =
      cond do
        operation.phase == :refresh -> "retry refresh failed"
        entry[:delay_type] == :passive_continuation -> "passive retry lookup failed"
        true -> "retry poll failed"
      end

    schedule_issue_retry(state, operation.issue.id, entry.attempt + 1, Map.put(retry_metadata(entry), :error, "#{prefix}: #{inspect(reason)}"))
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        if retry_cleanup_allowed?(state, issue_id) do
          if not Map.has_key?(state.lease_claims, issue_id) and legacy_cleanup_allowed?(issue_id), do: cleanup_issue_workspace(issue.identifier)
          {:noreply, release_issue_claim(state, issue_id)}
        else
          {:noreply, stop_terminal_dispatch(state, issue, :retry_ownership_changed)}
        end

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_retry_claim(state, issue)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, attempt, metadata) do
    case manual_retry_issue_fallback(metadata) do
      %Issue{} = issue ->
        handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)

      nil ->
        Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
        {:noreply, release_retry_claim(state, %Issue{id: issue_id, identifier: metadata[:identifier]})}
    end
  end

  defp manual_retry_issue_fallback(%{issue: %Issue{source: :manual} = issue}), do: issue
  defp manual_retry_issue_fallback(_metadata), do: nil

  defp legacy_cleanup_allowed?(issue_id) do
    case LeaseManager.read(issue_id) do
      {:ok, lease} -> lease["lease_version"] in [nil, 1] and not Map.has_key?(lease, "lease_generation")
      _ -> false
    end
  end

  defp retry_cleanup_allowed?(state, id) do
    case current_issue_custody(state, id) do
      {:ok, claim} ->
        case LeaseManager.read_at(claim.token.storage) do
          {:ok, lease} ->
            lease["lease_generation"] == claim.token.lease_generation and lease["epoch"] == claim.token.epoch and lease["owner"] == claim.token.owner and
              lease["acquired_at"] == claim.token.acquired_at

          _ ->
            false
        end

      {:error, _reason} ->
        false
    end
  end

  defp release_retry_claim(state, issue), do: release_issue_claim(state, issue.id)

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    case RunStateStore.load(Workspace.path_for_issue(identifier)) do
      {:ok, %{lease_version: 2}} -> :ok
      {:ok, _legacy} -> Workspace.remove_issue_workspaces(identifier)
      {:error, :missing} -> Workspace.remove_issue_workspaces(identifier)
      {:error, reason} -> Logger.warning("Workspace cleanup blocked identifier=#{identifier}: #{inspect(reason)}")
    end
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    case retry_resume_action(state, issue, metadata) do
      :dispatch ->
        do_handle_active_retry(state, issue, attempt, metadata)

      :resume ->
        resume_review_retry_under_lease(state, issue, attempt, metadata)

      {:error, {tag, _} = reason} when tag in [:dispatch_audit_pending, :dispatch_audit_read_failed, :deploy_audit_pending, :deploy_audit_read_failed] ->
        {:noreply, halt_dispatch_audit(state, issue.id, reason)}

      {:error, reason} ->
        {:noreply, stop_terminal_dispatch(state, issue, reason)}
    end
  end

  defp retry_resume_action(state, issue, metadata) do
    with {:ok, workspace} <- current_custody_workspace(state, issue),
         :ok <- DeployAudit.ensure_available(workspace),
         :ok <- DispatchAudit.ensure_available(workspace) do
      retry_resume_action_from_snapshot(issue, metadata, workspace)
    end
  end

  defp retry_resume_action_from_snapshot(issue, metadata, workspace) do
    case RunStateStore.load_checked(workspace, issue) do
      {:ok, %{stage: "blocked"} = run_state} ->
        if metadata[:delay_type] == :continuation and auto_continue_review_fix_budget_stop?(run_state),
          do: :resume,
          else: {:error, {:persisted_stage_requires_explicit_resume, "blocked"}}

      {:ok, %{stage: "done"}} ->
        {:error, {:persisted_stage_requires_explicit_resume, "done"}}

      {:ok, _state} ->
        :dispatch

      {:mismatch, _state} ->
        :dispatch

      {:error, :missing} ->
        :dispatch

      {:error, reason} ->
        {:error, {:run_state_unreadable, reason}}
    end
  end

  defp resume_review_retry_under_lease(state, issue, attempt, metadata) do
    acquisition =
      with {:ok, workspace} <- current_custody_workspace(state, issue),
           do: acquire_issue_custody(state, issue, &LeaseManager.acquire/3, workspace)

    case acquisition do
      {:ok, acquired_state} ->
        resume_result =
          case retry_resume_action(acquired_state, issue, metadata) do
            :resume -> Controls.maybe_resume_blocked_issue(acquired_state, issue)
            :dispatch -> {acquired_state, issue}
            {:error, _reason} = error -> error
          end

        case resume_result do
          {%State{} = resumed, %Issue{} = next_issue} ->
            do_handle_active_retry(transfer_issue_custody(resumed, issue.id, :retry), next_issue, attempt, metadata)

          {:error, {tag, _} = reason} when tag in [:dispatch_audit_pending, :dispatch_audit_read_failed, :deploy_audit_pending, :deploy_audit_read_failed] ->
            {:noreply, halt_dispatch_audit(acquired_state, issue.id, reason)}

          {:error, reason} ->
            {:noreply, stop_terminal_dispatch(acquired_state, issue, reason)}
        end

      {:error, reason} ->
        {:noreply,
         schedule_issue_retry(
           %{state | candidate_fetch_error: {:retry_resume_lease_failed, issue.id, reason}},
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{identifier: issue.identifier, error: "review continuation lease unavailable: #{inspect(reason)}"})
         )}
    end
  end

  defp do_handle_active_retry(state, issue, attempt, metadata) do
    cond do
      not retry_active_current?(state, issue) ->
        {:noreply, admission_discard(state, issue, :admission_no_longer_eligible)}

      dispatch_slots_available?(issue, state) and company_slots_available?(state, PolicyPack.resolve(policy_pack_name(issue, state))) ->
        dispatch_fun =
          case metadata[:delay_type] do
            :passive_continuation -> &dispatch_passive_issue/3
            _ -> &start_retry_refresh/3
          end

        {:noreply, dispatch_runtime_issue(state, issue, attempt, dispatch_fun, &dispatch_passive_issue/3)}

      true ->
        Logger.debug("No available slots for retrying #{SymphonyElixir.Util.issue_log_context(issue)}; retrying again")

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "no available orchestrator slots"
           })
         )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    if accounting_hold?(state, issue_id), do: state, else: release_healthy_issue_claim(state, issue_id)
  end

  defp release_healthy_issue_claim(%State{} = state, issue_id) do
    state = cancel_promotion_reader(state, issue_id)

    case current_issue_custody(state, issue_id) do
      {:ok, claim} ->
        case LeaseManager.release_token(claim.token) do
          {:ok, outcome} when outcome in [:released, :missing] ->
            state =
              case state.candidate_fetch_error do
                {:lease_release_failed, ^issue_id, _} -> %{state | candidate_fetch_error: nil}
                _ -> state
              end

            released = drop_issue_custody(state, issue_id)
            if outcome == :released, do: record_released_custody(released, issue_id, claim), else: released

          {:error, :lease_token_mismatch} ->
            state |> tracker_inbox_outcome(issue_id, {:recheck, :lease_ownership_changed}) |> drop_issue_custody(issue_id) |> Map.put(:candidate_fetch_error, {:lease_ownership_changed, issue_id})

          {:error, reason} ->
            Logger.error("Lease release failed issue_id=#{issue_id}; persisted ownership was preserved: #{inspect(reason)}")
            state = tracker_inbox_failure(state, issue_id, {:lease_release_failed, reason})
            %{state | claimed: MapSet.put(state.claimed, issue_id), candidate_fetch_error: {:lease_release_failed, issue_id, reason}}
        end

      {:error, :lease_custody_missing} ->
        case LeaseManager.read(issue_id) do
          {:error, :missing} ->
            drop_issue_custody(state, issue_id)

          result ->
            state = tracker_inbox_failure(state, issue_id, {:lease_custody_missing, result})
            %{state | candidate_fetch_error: {:lease_custody_missing, issue_id, result}}
        end
    end
  end

  defp record_released_custody(state, issue_id, claim) do
    result =
      with {:ok, entry} <- RunLedger.prepare_entry("lease.released", %{issue_id: issue_id, actor_type: "system", actor_id: claim.token.owner, summary: "Lease released."}),
           do: RunLedger.CheckedStorage.persist(entry, claim.token.storage.ledger_path)

    case result do
      {:ok, _entry} ->
        state

      {:error, reason} ->
        Logger.error("Lease physically released but its audit was not confirmed issue_id=#{issue_id}: #{inspect(reason)}")
        state = tracker_inbox_failure(state, issue_id, {:lease_release_audit_failed, reason})
        %{state | candidate_fetch_error: {:lease_release_audit_failed, issue_id, reason}}
    end
  end

  @doc false
  @spec prepare_retry_custody(State.t(), String.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def prepare_retry_custody(state, issue_id) do
    if Map.has_key?(state.running, issue_id) do
      {:ok, state}
    else
      state = state |> invalidate_admission_issue(issue_id) |> cancel_dispatch_retry(issue_id)
      released = release_issue_claim(state, issue_id)

      case {Map.has_key?(released.lease_claims, issue_id), released.candidate_fetch_error} do
        {false, {:lease_custody_missing, ^issue_id, _} = reason} -> {:error, reason, released}
        {false, {:lease_ownership_changed, ^issue_id} = reason} -> {:error, reason, released}
        {false, {:lease_release_audit_failed, ^issue_id, _} = reason} -> {:error, reason, released}
        {false, _} -> {:ok, released}
        {true, reason} -> {:error, reason, released}
      end
    end
  end

  defp drop_issue_custody(state, issue_id) do
    case get_in(state.lease_claims, [issue_id, :timer]) do
      timer when is_reference(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    %{state | lease_claims: Map.delete(state.lease_claims, issue_id), claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp current_issue_custody(state, issue_id, expected_ref \\ :current) do
    case Map.fetch(state.lease_claims, issue_id) do
      {:ok, %{custody_ref: ref} = claim} when expected_ref == :current or expected_ref == ref -> {:ok, claim}
      {:ok, _claim} -> {:error, :lease_custody_changed}
      :error -> {:error, :lease_custody_missing}
    end
  end

  defp transfer_issue_custody(state, issue_id, holder) do
    case Map.fetch(state.lease_claims, issue_id) do
      {:ok, claim} ->
        next = %{claim | custody_ref: make_ref(), holder: holder}

        next =
          if holder == :retry do
            if is_reference(claim.timer), do: Process.cancel_timer(claim.timer)
            %{next | timer: nil, promotion_ref: nil, deadline: :not_pending}
          else
            next
          end

        state = %{state | lease_claims: Map.put(state.lease_claims, issue_id, next)}
        bind_tracker_inbox_custody(state, issue_id, claim.custody_ref, next)

      :error ->
        state
    end
  end

  defp current_custody_workspace(state, issue) do
    selected = Workspace.path_for_issue(issue)

    case Map.get(state.lease_claims, issue.id) do
      nil ->
        {:ok, selected}

      %{workspace: captured, token: token} ->
        with true <- Path.expand(selected) == Path.expand(captured) or {:error, :lease_workspace_changed},
             {:ok, current} <- LeaseManager.capture_storage(issue.id),
             true <- (current.lease_path == token.storage.lease_path and current.ledger_path == token.storage.ledger_path) or {:error, :lease_location_changed} do
          {:ok, captured}
        end
    end
  end

  defp acquire_issue_custody(state, issue, acquire_fun, workspace) do
    started = System.monotonic_time(:millisecond)
    existing = Map.get(state.lease_claims, issue.id)

    result =
      if not is_nil(existing) and acquire_fun == (&LeaseManager.acquire/3) do
        LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner, storage: existing.token.storage, expected_token: existing.token)
      else
        acquire_fun.(issue.id, issue.identifier, state.lease_owner)
      end

    case result do
      {:ok, %{token: token, lease: lease}} ->
        claim = %{
          token: token,
          lease: lease,
          custody_ref: make_ref(),
          holder: :pending,
          workspace: workspace,
          issue: issue,
          started_at_ms: started,
          deadline: :not_pending,
          promotion_ref: nil,
          timer: nil
        }

        state = %{state | lease_claims: Map.put(state.lease_claims, issue.id, claim), claimed: MapSet.put(state.claimed, issue.id)}
        previous_ref = if existing, do: existing.custody_ref, else: nil
        {:ok, bind_tracker_inbox_custody(state, issue.id, previous_ref, claim)}

      {:error, _reason} = error ->
        error
    end
  end

  defp retry_delay(attempt, metadata)
       when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case metadata[:delay_type] do
      :continuation when attempt == 1 ->
        @continuation_retry_delay_ms

      :passive_continuation when attempt == 1 ->
        passive_retry_delay(metadata)

      _ ->
        failure_retry_delay(attempt)
    end
  end

  defp passive_retry_delay(metadata) when is_map(metadata) do
    case metadata[:passive_delay_ms] do
      delay when is_integer(delay) and delay > 0 -> delay
      _ -> @passive_continuation_retry_delay_ms
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.max_retry_backoff_ms())
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp continuation_metadata_for_running_entry(%{identifier: identifier})
       when is_binary(identifier) do
    case issue_run_state(identifier) do
      %{stage: "merge_readiness"} = run_state ->
        %{
          delay_type: :passive_continuation,
          passive_delay_ms: passive_delay_ms_for_await_checks(run_state)
        }

      %{stage: "await_checks"} = run_state ->
        %{
          delay_type: :passive_continuation,
          passive_delay_ms: passive_delay_ms_for_await_checks(run_state)
        }

      %{stage: "merge"} ->
        %{
          delay_type: :passive_continuation,
          passive_delay_ms: @passive_continuation_retry_delay_ms
        }

      %{stage: "post_merge"} ->
        %{
          delay_type: :passive_continuation,
          passive_delay_ms: @passive_continuation_retry_delay_ms
        }

      %{stage: "done"} ->
        %{delay_type: :none}

      %{stage: "blocked"} = run_state ->
        if auto_continue_review_fix_budget_stop?(run_state) do
          %{delay_type: :continuation}
        else
          %{delay_type: :none}
        end

      _ ->
        %{delay_type: :continuation}
    end
  end

  defp continuation_metadata_for_running_entry(_running_entry), do: %{delay_type: :continuation}

  defp auto_continue_review_fix_budget_stop?(run_state) when is_map(run_state) do
    blocked_review_fix_budget_stop?(run_state) and
      actionable_review_claims_present?(run_state) and
      (addressed_review_claims_present?(run_state) or
         review_fix_retry_budget_active?(run_state))
  end

  defp review_fix_retry_budget_active?(run_state) when is_map(run_state) do
    review_fix_budget_retry_count(run_state) > 0 and
      resume_context_token_pressure(run_state) == "high"
  end

  defp review_fix_budget_retry_count(run_state) when is_map(run_state) do
    run_state
    |> resume_context_map()
    |> map_value("review_fix_budget_retry_count")
    |> case do
      value when is_integer(value) and value > 0 -> value
      _ -> 0
    end
  end

  defp resume_context_token_pressure(run_state) when is_map(run_state) do
    run_state
    |> resume_context_map()
    |> map_value("token_pressure")
  end

  defp resume_context_map(run_state) when is_map(run_state) do
    case Map.get(run_state, :resume_context) || Map.get(run_state, "resume_context") do
      context when is_map(context) -> context
      _ -> %{}
    end
  end

  defp blocked_review_fix_budget_stop?(run_state) when is_map(run_state) do
    last_rule_id = Map.get(run_state, :last_rule_id) || Map.get(run_state, "last_rule_id")

    stop_reason =
      Map.get(run_state, :stop_reason) ||
        Map.get(run_state, "stop_reason") ||
        %{}

    last_rule_id == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, :rule_id) == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, "rule_id") == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, :code) == "per_turn_input_budget_exceeded" or
      Map.get(stop_reason, "code") == "per_turn_input_budget_exceeded"
  end

  defp addressed_review_claims_present?(run_state) when is_map(run_state) do
    run_state
    |> review_claim_values()
    |> Enum.any?(fn claim ->
      map_value(claim, "implementation_status") == "addressed"
    end)
  end

  defp actionable_review_claims_present?(run_state) when is_map(run_state) do
    run_state
    |> review_claim_values()
    |> Enum.any?(fn claim ->
      map_value(claim, "disposition") == "accepted" and
        truthy_map_value(claim, "actionable") and
        map_value(claim, "implementation_status") != "addressed"
    end)
  end

  defp review_claim_values(run_state) when is_map(run_state) do
    case Map.get(run_state, :review_claims) || Map.get(run_state, "review_claims") do
      claims when is_map(claims) -> Map.values(claims)
      _ -> []
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_map_atom_key(key))
  end

  defp map_value(_map, _key), do: nil

  defp known_map_atom_key("implementation_status"), do: :implementation_status
  defp known_map_atom_key("disposition"), do: :disposition
  defp known_map_atom_key("actionable"), do: :actionable
  defp known_map_atom_key("blocked"), do: :blocked
  defp known_map_atom_key("needs_another_turn"), do: :needs_another_turn
  defp known_map_atom_key(_key), do: nil

  defp truthy_map_value(map, key) do
    case map_value(map, key) do
      true -> true
      "true" -> true
      1 -> true
      "1" -> true
      _ -> false
    end
  end

  defp issue_run_state(identifier) when is_binary(identifier) do
    workspace = Workspace.path_for_issue(identifier)

    case RunStateStore.load(workspace) do
      {:ok, state} when is_map(state) -> state
      _ -> nil
    end
  end

  defp passive_delay_ms_for_await_checks(run_state) when is_map(run_state) do
    case merge_window_delay_ms(run_state) do
      {:ok, delay_ms} ->
        delay_ms

      :error ->
        polls = Map.get(run_state, :await_checks_polls, 0)

        cond do
          polls >= 12 -> @passive_continuation_retry_delay_max_ms
          polls >= 6 -> @passive_continuation_retry_delay_long_ms
          polls >= 3 -> @passive_continuation_retry_delay_mid_ms
          true -> @passive_continuation_retry_delay_ms
        end
    end
  end

  defp merge_window_delay_ms(run_state) when is_map(run_state) do
    with %{} = wait <- Map.get(run_state, :merge_window_wait),
         next_allowed_at when is_binary(next_allowed_at) <-
           Map.get(wait, :next_allowed_at) || Map.get(wait, "next_allowed_at"),
         {:ok, next_allowed_at, _offset} <- DateTime.from_iso8601(next_allowed_at) do
      now = DateTime.utc_now()

      delay_ms =
        case DateTime.diff(next_allowed_at, now, :millisecond) do
          diff when diff <= 0 -> @passive_continuation_retry_delay_ms
          diff -> min(diff, 12 * 60 * 60 * 1000)
        end

      {:ok, delay_ms}
    else
      _ -> :error
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp capacity_entries(state) do
    pending = state.lease_claims |> Enum.filter(fn {_id, claim} -> claim.holder in [:pending, :gated] end) |> Map.new(fn {id, claim} -> {id, %{issue: claim.issue}} end)

    pending =
      case state.admission_read do
        %{purpose: :promotion, issue: issue} -> Map.put_new(pending, issue.id, %{issue: issue})
        _ -> pending
      end

    Map.merge(pending, state.running)
  end

  @doc false
  @spec available_slots(State.t()) :: non_neg_integer()
  def available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(capacity_entries(state)),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    call_if_available(server, :request_refresh)
  end

  @spec submit_manual_issue(map()) :: map() | :unavailable
  def submit_manual_issue(spec), do: submit_manual_issue(__MODULE__, spec)

  @spec submit_manual_issue(GenServer.server(), map()) :: map() | :unavailable
  def submit_manual_issue(server, spec) when is_map(spec) do
    call_if_available(server, {:submit_manual_issue, spec})
  end

  @spec notify_tracker_events(map()) :: :ok
  def notify_tracker_events(attrs) when is_map(attrs) do
    notify_tracker_events(__MODULE__, attrs)
  end

  @spec notify_tracker_events(GenServer.server(), map()) :: :ok
  def notify_tracker_events(server, attrs) when is_map(attrs) do
    send(server, {:tracker_events_available, attrs})
    :ok
  end

  @spec notify_tracker_webhook_rejected(map()) :: :ok
  def notify_tracker_webhook_rejected(attrs) when is_map(attrs) do
    notify_tracker_webhook_rejected(__MODULE__, attrs)
  end

  @spec notify_tracker_webhook_rejected(GenServer.server(), map()) :: :ok
  def notify_tracker_webhook_rejected(server, attrs) when is_map(attrs) do
    send(server, {:tracker_webhook_rejected, attrs})
    :ok
  end

  @spec notify_tracker_webhook_ignored(map()) :: :ok
  def notify_tracker_webhook_ignored(attrs) when is_map(attrs) do
    notify_tracker_webhook_ignored(__MODULE__, attrs)
  end

  @spec notify_tracker_webhook_ignored(GenServer.server(), map()) :: :ok
  def notify_tracker_webhook_ignored(server, attrs) when is_map(attrs) do
    send(server, {:tracker_webhook_ignored, attrs})
    :ok
  end

  @spec notify_github_events(map()) :: :ok
  def notify_github_events(attrs) when is_map(attrs), do: notify_github_events(__MODULE__, attrs)

  @spec notify_github_events(GenServer.server(), map()) :: :ok
  def notify_github_events(server, attrs) when is_map(attrs) do
    send(server, {:github_events_available, attrs})
    :ok
  end

  @spec notify_github_webhook_rejected(map()) :: :ok
  def notify_github_webhook_rejected(attrs) when is_map(attrs),
    do: notify_github_webhook_rejected(__MODULE__, attrs)

  @spec notify_github_webhook_rejected(GenServer.server(), map()) :: :ok
  def notify_github_webhook_rejected(server, attrs) when is_map(attrs) do
    send(server, {:github_webhook_rejected, attrs})
    :ok
  end

  @spec notify_github_webhook_ignored(map()) :: :ok
  def notify_github_webhook_ignored(attrs) when is_map(attrs),
    do: notify_github_webhook_ignored(__MODULE__, attrs)

  @spec notify_github_webhook_ignored(GenServer.server(), map()) :: :ok
  def notify_github_webhook_ignored(server, attrs) when is_map(attrs) do
    send(server, {:github_webhook_ignored, attrs})
    :ok
  end

  @spec pause_issue(String.t()) :: map() | :unavailable
  def pause_issue(issue_identifier), do: pause_issue(__MODULE__, issue_identifier)

  @spec pause_issue(GenServer.server(), String.t()) :: map() | :unavailable
  def pause_issue(server, issue_identifier) do
    call_if_available(server, {:pause_issue, issue_identifier})
  end

  @spec resume_issue(String.t()) :: map() | :unavailable
  def resume_issue(issue_identifier), do: resume_issue(__MODULE__, issue_identifier)

  @spec resume_issue(GenServer.server(), String.t()) :: map() | :unavailable
  def resume_issue(server, issue_identifier) do
    call_if_available(server, {:resume_issue, issue_identifier})
  end

  @spec stop_issue(String.t()) :: map() | :unavailable
  def stop_issue(issue_identifier), do: stop_issue(__MODULE__, issue_identifier)

  @spec stop_issue(GenServer.server(), String.t()) :: map() | :unavailable
  def stop_issue(server, issue_identifier) do
    call_if_available(server, {:stop_issue, issue_identifier})
  end

  @spec hold_issue_for_human_review(String.t()) :: map() | :unavailable
  def hold_issue_for_human_review(issue_identifier),
    do: hold_issue_for_human_review(__MODULE__, issue_identifier)

  @spec hold_issue_for_human_review(GenServer.server(), String.t()) :: map() | :unavailable
  def hold_issue_for_human_review(server, issue_identifier) do
    call_if_available(server, {:hold_issue_for_human_review, issue_identifier})
  end

  @spec retry_issue_now(String.t()) :: map() | :unavailable
  def retry_issue_now(issue_identifier), do: retry_issue_now(__MODULE__, issue_identifier)

  @spec retry_issue_now(GenServer.server(), String.t()) :: map() | :unavailable
  def retry_issue_now(server, issue_identifier) do
    call_if_available(server, {:retry_issue_now, issue_identifier})
  end

  @spec refresh_merge_readiness(String.t()) :: map() | :unavailable
  def refresh_merge_readiness(issue_identifier),
    do: refresh_merge_readiness(__MODULE__, issue_identifier)

  @spec refresh_merge_readiness(GenServer.server(), String.t()) :: map() | :unavailable
  def refresh_merge_readiness(server, issue_identifier) do
    call_if_available(server, {:refresh_merge_readiness, issue_identifier})
  end

  @spec reprioritize_issue(String.t(), integer() | nil) :: map() | :unavailable
  def reprioritize_issue(issue_identifier, override_rank) do
    reprioritize_issue(__MODULE__, issue_identifier, override_rank)
  end

  @spec reprioritize_issue(GenServer.server(), String.t(), integer() | nil) ::
          map() | :unavailable
  def reprioritize_issue(server, issue_identifier, override_rank) do
    call_if_available(server, {:reprioritize_issue, issue_identifier, override_rank})
  end

  @spec approve_issue_for_merge(String.t()) :: map() | :unavailable
  def approve_issue_for_merge(issue_identifier),
    do: approve_issue_for_merge(__MODULE__, issue_identifier)

  @spec approve_issue_for_merge(GenServer.server(), String.t()) :: map() | :unavailable
  def approve_issue_for_merge(server, issue_identifier) do
    call_if_available(server, {:approve_issue_for_merge, issue_identifier})
  end

  @spec approve_issue_for_deploy(String.t()) :: map() | :unavailable
  def approve_issue_for_deploy(issue_identifier),
    do: approve_issue_for_deploy(__MODULE__, issue_identifier)

  @spec approve_issue_for_deploy(GenServer.server(), String.t()) :: map() | :unavailable
  def approve_issue_for_deploy(server, issue_identifier) do
    call_if_available(server, {:approve_issue_for_deploy, issue_identifier})
  end

  @spec approve_review_drafts(String.t()) :: map() | :unavailable
  def approve_review_drafts(issue_identifier),
    do: approve_review_drafts(__MODULE__, issue_identifier)

  @spec approve_review_drafts(GenServer.server(), String.t()) :: map() | :unavailable
  def approve_review_drafts(server, issue_identifier) do
    call_if_available(server, {:approve_review_drafts, issue_identifier})
  end

  @spec reject_review_drafts(String.t()) :: map() | :unavailable
  def reject_review_drafts(issue_identifier),
    do: reject_review_drafts(__MODULE__, issue_identifier)

  @spec reject_review_drafts(GenServer.server(), String.t()) :: map() | :unavailable
  def reject_review_drafts(server, issue_identifier) do
    call_if_available(server, {:reject_review_drafts, issue_identifier})
  end

  @spec mark_review_threads_posted(String.t()) :: map() | :unavailable
  def mark_review_threads_posted(issue_identifier),
    do: mark_review_threads_posted(__MODULE__, issue_identifier)

  @spec mark_review_threads_posted(GenServer.server(), String.t()) :: map() | :unavailable
  def mark_review_threads_posted(server, issue_identifier) do
    call_if_available(server, {:mark_review_threads_posted, issue_identifier})
  end

  @spec post_review_drafts(String.t()) :: map() | :unavailable
  def post_review_drafts(issue_identifier), do: post_review_drafts(__MODULE__, issue_identifier)

  @spec post_review_drafts(GenServer.server(), String.t()) :: map() | :unavailable
  def post_review_drafts(server, issue_identifier) do
    call_if_available(server, {:post_review_drafts, issue_identifier})
  end

  @spec resolve_review_threads(String.t()) :: map() | :unavailable
  def resolve_review_threads(issue_identifier),
    do: resolve_review_threads(__MODULE__, issue_identifier)

  @spec resolve_review_threads(GenServer.server(), String.t()) :: map() | :unavailable
  def resolve_review_threads(server, issue_identifier) do
    call_if_available(server, {:resolve_review_threads, issue_identifier})
  end

  @spec set_policy_class(String.t(), String.t()) :: map() | :unavailable
  def set_policy_class(issue_identifier, policy_class) do
    set_policy_class(__MODULE__, issue_identifier, policy_class)
  end

  @spec set_policy_class(GenServer.server(), String.t(), String.t()) :: map() | :unavailable
  def set_policy_class(server, issue_identifier, policy_class) do
    call_if_available(server, {:set_policy_class, issue_identifier, policy_class})
  end

  @spec clear_policy_override(String.t()) :: map() | :unavailable
  def clear_policy_override(issue_identifier) do
    clear_policy_override(__MODULE__, issue_identifier)
  end

  @spec clear_policy_override(GenServer.server(), String.t()) :: map() | :unavailable
  def clear_policy_override(server, issue_identifier) do
    call_if_available(server, {:clear_policy_override, issue_identifier})
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if present?(server_pid(server)) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  defp call_if_available(server, message) do
    if present?(server_pid(server)) do
      GenServer.call(server, message)
    else
      :unavailable
    end
  end

  defp server_pid(server) when is_pid(server) do
    if Process.alive?(server), do: server, else: nil
  end

  defp server_pid(server) do
    GenServer.whereis(server)
  end

  @impl true
  def handle_call({:agent_execution, %{worker: worker} = context, action}, {caller, _tag}, state) when caller == worker do
    case matching_execution_entry(state, context) do
      {:ok, issue_id, entry} ->
        case execution_owner_action(state, issue_id, entry, action) do
          {:ok, registry} ->
            entry = put_in(entry.agent_execution.registry, registry)
            {:reply, :ok, %{state | running: Map.put(state.running, issue_id, entry)}}

          {:error, {:accounting_uncertain, cause}} ->
            {:reply, {:stop, {:accounting_uncertain, cause}}, state}

          {:error, cause} ->
            next = mark_accounting_uncertain(state, issue_id, cause)
            {:reply, {:stop, {:accounting_uncertain, cause}}, next}
        end

      :error ->
        {:reply, {:stop, {:accounting_uncertain, :execution_context_mismatch}}, state}
    end
  end

  def handle_call({:agent_execution, _context, _action}, _from, state),
    do: {:reply, {:stop, {:accounting_uncertain, :execution_sender_mismatch}}, state}

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      Enum.map(state.running, fn {issue_id, metadata} ->
        running_snapshot_entry(issue_id, metadata, now, state)
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        identifier = Map.get(retry, :identifier)
        run_state = retry_run_state(identifier, Map.get(retry, :issue))

        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: identifier,
          source: Map.get(run_state, :issue_source),
          error: Map.get(retry, :error),
          priority_override: Map.get(state.priority_overrides, identifier),
          policy_class: Map.get(run_state, :effective_policy_class),
          policy_source: Map.get(run_state, :effective_policy_source),
          policy_override: Map.get(run_state, :policy_override),
          next_human_action: Map.get(run_state, :next_human_action),
          last_rule_id: Map.get(run_state, :last_rule_id),
          last_failure_class: Map.get(run_state, :last_failure_class),
          last_decision_summary: Map.get(run_state, :last_decision_summary),
          last_ledger_event_id: Map.get(run_state, :last_ledger_event_id)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       paused: paused_snapshot_entries(state.paused_issue_states),
       skipped: skipped_snapshot_entries(state.skipped_issues),
       queue: queue_snapshot(state),
       priority_overrides: state.priority_overrides,
       policy_overrides: state.policy_overrides,
       agent_totals: state.agent_totals,
       rate_limits: Map.get(state, :agent_rate_limits),
       runner: RunnerRuntime.info(),
       webhooks: %{
         health: webhook_health(state),
         mode: webhook_mode(),
         last_accepted_at: datetime_to_iso8601(Map.get(state, :webhook_last_accepted_at)),
         last_ignored_at: datetime_to_iso8601(Map.get(state, :webhook_last_ignored_at)),
         last_ignored_reason: Map.get(state, :webhook_last_ignored_reason),
         last_ignored_rule_id: Map.get(state, :webhook_last_ignored_rule_id),
         last_rejected_at: datetime_to_iso8601(Map.get(state, :webhook_last_rejected_at)),
         last_rejected_reason: Map.get(state, :webhook_last_rejected_reason),
         last_rejected_rule_id: Map.get(state, :webhook_last_rejected_rule_id)
       },
       github_webhooks: %{
         health: github_webhook_health(state),
         last_accepted_at: datetime_to_iso8601(Map.get(state, :github_webhook_last_accepted_at)),
         last_ignored_at: datetime_to_iso8601(Map.get(state, :github_webhook_last_ignored_at)),
         last_ignored_reason: Map.get(state, :github_webhook_last_ignored_reason),
         last_ignored_rule_id: Map.get(state, :github_webhook_last_ignored_rule_id),
         last_rejected_at: datetime_to_iso8601(Map.get(state, :github_webhook_last_rejected_at)),
         last_rejected_reason: Map.get(state, :github_webhook_last_rejected_reason),
         last_rejected_rule_id: Map.get(state, :github_webhook_last_rejected_rule_id)
       },
       tracker_inbox: inbox_snapshot(TrackerEventInbox, state.inbox_ack_pending, state.inbox_storage_error, state.inbox_last_drained_at) |> Map.put(:phase, tracker_inbox_phase(state)),
       github_inbox:
         inbox_snapshot(GitHubEventInbox, state.github_inbox_ack_pending, state.github_inbox_storage_error, state.github_inbox_last_drained_at)
         |> Map.put(:last_assignment, Map.get(state, :github_last_assignment)),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         mode: state.current_poll_mode,
         dispatch_mode: dispatch_mode(state),
         dispatch_summary: dispatch_summary(state),
         tracker_reads_paused: tracker_backoff_active?(state),
         manual_dispatch_enabled: Config.manual_enabled?(),
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms,
         discovery_interval_ms: state.poll_interval_ms,
         healing_interval_ms: state.healing_poll_interval_ms,
         next_healing_poll_in_ms: next_poll_in_ms(state.next_healing_poll_due_at_ms, now_ms),
         backoff_active: tracker_backoff_active?(state),
         backoff_until_in_ms: next_poll_in_ms(state.tracker_backoff_until_ms, now_ms),
         backoff_reason: state.tracker_backoff_reason,
         backoff_rule_id: state.tracker_backoff_rule_id
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    poll_already_due? =
      is_integer(state.next_poll_due_at_ms) and
        state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    poll_coalesced = state.poll_check_in_progress == true or poll_already_due?
    github_coalesced = state.github_webhook_check_in_progress == true

    unless poll_coalesced do
      :ok = schedule_webhook_cycle_start()
    end

    unless github_coalesced do
      :ok = schedule_github_webhook_cycle_start()
    end

    state = if poll_coalesced, do: queue_tracker_poll(state, :webhook), else: state
    state = if github_coalesced, do: queue_tracker_poll(state, :github_webhook), else: state

    state = %{
      state
      | poll_check_in_progress: state.poll_check_in_progress or not poll_coalesced,
        current_poll_mode: if(poll_coalesced, do: state.current_poll_mode, else: :webhook),
        github_webhook_check_in_progress: state.github_webhook_check_in_progress or not github_coalesced
    }

    {:reply,
     %{
       queued: true,
       coalesced: poll_coalesced and github_coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["events", "github_events", "reconcile"]
     }, state}
  end

  def handle_call({:pause_issue, issue_identifier}, _from, state) do
    state = invalidate_tracker_poll_issue(state, issue_identifier)
    {reply, state} = Controls.pause_issue_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:resume_issue, issue_identifier}, _from, state) do
    state = invalidate_tracker_poll_issue(state, issue_identifier)
    {reply, state} = Controls.resume_issue_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:stop_issue, issue_identifier}, _from, state) do
    state = invalidate_tracker_poll_issue(state, issue_identifier)
    {reply, state} = Controls.stop_issue_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:hold_issue_for_human_review, issue_identifier}, _from, state) do
    state = invalidate_tracker_poll_issue(state, issue_identifier)
    {reply, state} = Controls.hold_issue_for_human_review_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:retry_issue_now, issue_identifier}, _from, state) do
    {reply, state} = Controls.retry_issue_now_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:refresh_merge_readiness, issue_identifier}, _from, state) do
    {reply, state} = Controls.refresh_merge_readiness_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:reprioritize_issue, issue_identifier, override_rank}, _from, state) do
    {reply, state} = Controls.reprioritize_issue_runtime(state, issue_identifier, override_rank)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:approve_issue_for_merge, issue_identifier}, _from, state) do
    {reply, state} = Controls.approve_issue_for_merge_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:approve_issue_for_deploy, issue_identifier}, _from, state) do
    {reply, state} = Controls.approve_issue_for_deploy_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:approve_review_drafts, issue_identifier}, _from, state) do
    {reply, state} =
      Controls.review_thread_action_runtime(state, issue_identifier, "approve_review_drafts")

    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:reject_review_drafts, issue_identifier}, _from, state) do
    {reply, state} = Controls.review_thread_action_runtime(state, issue_identifier, "reject_review_drafts")
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:mark_review_threads_posted, issue_identifier}, _from, state) do
    {reply, state} =
      Controls.review_thread_action_runtime(state, issue_identifier, "mark_review_threads_posted")

    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:post_review_drafts, issue_identifier}, _from, state) do
    {reply, state} = Controls.post_review_drafts_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:resolve_review_threads, issue_identifier}, _from, state) do
    {reply, state} =
      Controls.review_thread_action_runtime(state, issue_identifier, "resolve_review_threads")

    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:set_policy_class, issue_identifier, policy_class}, _from, state) do
    state = invalidate_tracker_poll_issue(state, issue_identifier)
    {reply, state} = Controls.set_policy_class_runtime(state, issue_identifier, policy_class)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:clear_policy_override, issue_identifier}, _from, state) do
    state = invalidate_tracker_poll_issue(state, issue_identifier)
    {reply, state} = Controls.clear_policy_override_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:submit_manual_issue, spec}, _from, state) do
    refresh_coalesced = state.poll_check_in_progress == true
    {reply, state} = Controls.submit_manual_issue_runtime(state, spec)
    state = if refresh_coalesced and match?(%{accepted: true}, reply), do: queue_tracker_poll(state, :discovery), else: state
    notify_dashboard()
    {:reply, reply, state}
  end

  # credo:disable-for-next-line
  defp running_snapshot_entry(issue_id, metadata, now, state) do
    workspace_path = Workspace.path_for_issue(metadata.identifier || issue_id)
    inspection = RunInspector.inspect(workspace_path, include_pr_details: false)
    run_state = load_run_state(workspace_path, metadata.issue)
    lease = stateful_lease_details(issue_id, run_state, now)
    inspection = apply_persisted_review_state(inspection, run_state)

    {policy_class, policy_source, policy_override} =
      policy_snapshot_values(metadata.issue, state, run_state)

    budget_runtime =
      RunPolicy.budget_runtime(metadata.issue, %{
        stage: Map.get(run_state, :stage),
        workspace: workspace_path,
        turn_count: Map.get(metadata, :turn_count, 0),
        agent_input_tokens: Map.get(metadata, :agent_input_tokens, 0),
        agent_output_tokens: Map.get(metadata, :agent_output_tokens, 0),
        agent_total_tokens: Map.get(metadata, :agent_total_tokens, 0),
        turn_started_input_tokens: Map.get(metadata, :turn_started_input_tokens, 0),
        resume_context: Map.get(run_state, :resume_context, %{})
      })

    %{
      issue_id: issue_id,
      identifier: metadata.identifier,
      source: metadata.issue.source,
      state: metadata.issue.state,
      session_id: metadata.session_id,
      agent_process_id: metadata.agent_process_id,
      agent_input_tokens: metadata.agent_input_tokens,
      agent_output_tokens: metadata.agent_output_tokens,
      agent_total_tokens: metadata.agent_total_tokens,
      turn_count: Map.get(metadata, :turn_count, 0),
      started_at: metadata.started_at,
      last_agent_timestamp: metadata.last_agent_timestamp,
      last_agent_message: metadata.last_agent_message,
      last_agent_event: metadata.last_agent_event,
      runtime_seconds: running_seconds(metadata.started_at, now),
      workspace: workspace_path,
      checkout?: inspection.checkout?,
      git?: inspection.git?,
      origin_url: inspection.origin_url,
      branch: inspection.branch,
      head_sha: inspection.head_sha,
      status_text: inspection.status_text,
      dirty?: inspection.dirty?,
      changed_files: inspection.changed_files,
      harness_path: inspection.harness && inspection.harness.path,
      harness_version: inspection.harness && inspection.harness.version,
      harness_error: inspection.harness_error,
      preflight_command: inspection.harness && inspection.harness.preflight_command,
      validation_command: inspection.harness && inspection.harness.validation_command,
      smoke_command: inspection.harness && inspection.harness.smoke_command,
      post_merge_command: inspection.harness && inspection.harness.post_merge_command,
      artifacts_command: inspection.harness && inspection.harness.artifacts_command,
      pr_url: inspection.pr_url,
      pr_state: inspection.pr_state,
      review_decision: inspection.review_decision,
      check_statuses: inspection.check_statuses,
      required_checks: (inspection.harness && inspection.harness.required_checks) || [],
      publish_required_checks: (inspection.harness && inspection.harness.publish_required_checks) || [],
      ci_required_checks: (inspection.harness && inspection.harness.ci_required_checks) || [],
      required_labels: routing_required_labels(),
      labels: issue_labels(metadata.issue),
      label_gate_eligible: issue_matches_required_labels?(metadata.issue),
      policy_class: policy_class,
      policy_source: policy_source,
      policy_override: policy_override,
      ready_for_merge: RunInspector.ready_for_merge?(inspection),
      stage: Map.get(run_state, :stage),
      stage_history: Map.get(run_state, :stage_history, []),
      last_validation: Map.get(run_state, :last_validation),
      last_verifier: Map.get(run_state, :last_verifier),
      last_verifier_verdict: Map.get(run_state, :last_verifier_verdict),
      acceptance_summary: Map.get(run_state, :acceptance_summary),
      last_pr_body_validation: Map.get(run_state, :last_pr_body_validation),
      last_merge_readiness: Map.get(run_state, :last_merge_readiness),
      last_post_merge: Map.get(run_state, :last_post_merge),
      base_branch: Map.get(run_state, :base_branch) || (inspection.harness && inspection.harness.base_branch),
      run_state_pr_url: Map.get(run_state, :pr_url),
      review_approved: Map.get(run_state, :review_approved, false),
      deploy_approved: Map.get(run_state, :deploy_approved, false),
      deploy_window_wait: Map.get(run_state, :deploy_window_wait),
      token_pressure: get_in(run_state, [:resume_context, :token_pressure]),
      budget_runtime: budget_runtime,
      merge_sha: Map.get(run_state, :merge_sha),
      stop_reason: Map.get(run_state, :stop_reason),
      last_decision: Map.get(run_state, :last_decision),
      last_rule_id: Map.get(run_state, :last_rule_id),
      last_failure_class: Map.get(run_state, :last_failure_class),
      last_decision_summary: Map.get(run_state, :last_decision_summary),
      next_human_action: Map.get(run_state, :next_human_action),
      last_ledger_event_id: Map.get(run_state, :last_ledger_event_id),
      passive?: Map.get(metadata, :passive?, false),
      lease: lease,
      lease_owner: Map.get(lease, :lease_owner),
      lease_status: Map.get(lease, :lease_status),
      lease_owner_instance_id: Map.get(lease, :lease_owner_instance_id),
      lease_owner_channel: Map.get(lease, :lease_owner_channel),
      lease_acquired_at: Map.get(lease, :lease_acquired_at),
      lease_updated_at: Map.get(lease, :lease_updated_at),
      lease_epoch: Map.get(lease, :lease_epoch),
      lease_age_ms: Map.get(lease, :lease_age_ms),
      lease_ttl_ms: Map.get(lease, :lease_ttl_ms),
      lease_reclaimable: Map.get(lease, :lease_reclaimable, false),
      current_turn_input_tokens:
        max(
          0,
          Map.get(metadata, :agent_input_tokens, 0) -
            Map.get(metadata, :turn_started_input_tokens, 0)
        ),
      recent_agent_updates: Map.get(metadata, :recent_agent_updates, [])
    }
  end

  defp apply_persisted_review_state(%RunInspector.Snapshot{} = inspection, run_state)
       when is_map(run_state) do
    check_statuses =
      case Map.get(run_state, :last_check_statuses) do
        statuses when is_list(statuses) and statuses != [] -> statuses
        _ -> inspection.check_statuses
      end

    inspection
    |> Map.put(:pr_url, Map.get(run_state, :pr_url) || inspection.pr_url)
    |> Map.put(:pr_state, Map.get(run_state, :last_pr_state) || inspection.pr_state)
    |> Map.put(:review_decision, Map.get(run_state, :last_review_decision) || inspection.review_decision)
    |> Map.put(:check_statuses, check_statuses)
    |> Map.put(:required_checks_state, Map.get(run_state, :last_required_checks_state) || inspection.required_checks_state)
    |> Map.put(:missing_required_checks, persisted_check_list(run_state, :last_missing_required_checks, inspection.missing_required_checks))
    |> Map.put(:pending_required_checks, persisted_check_list(run_state, :last_pending_required_checks, inspection.pending_required_checks))
    |> Map.put(:failing_required_checks, persisted_check_list(run_state, :last_failing_required_checks, inspection.failing_required_checks))
    |> Map.put(:cancelled_required_checks, persisted_check_list(run_state, :last_cancelled_required_checks, inspection.cancelled_required_checks))
  end

  defp persisted_check_list(run_state, key, fallback) when is_map(run_state) do
    case Map.get(run_state, key) do
      values when is_list(values) and values != [] -> values
      _ -> fallback
    end
  end

  defp paused_snapshot_entries(paused_issue_states) when is_map(paused_issue_states) do
    paused_issue_states
    |> Enum.map(fn {issue_id, paused_entry} ->
      %{
        issue_id: issue_id,
        identifier: Map.get(paused_entry, :identifier),
        source: Map.get(paused_entry, :source),
        resume_state: Map.get(paused_entry, :resume_state),
        policy_class: Map.get(paused_entry, :policy_class),
        policy_source: Map.get(paused_entry, :policy_source),
        policy_override: Map.get(paused_entry, :policy_override),
        next_human_action: Map.get(paused_entry, :next_human_action),
        last_rule_id: Map.get(paused_entry, :last_rule_id),
        last_failure_class: Map.get(paused_entry, :last_failure_class),
        last_decision_summary: Map.get(paused_entry, :last_decision_summary),
        last_ledger_event_id: Map.get(paused_entry, :last_ledger_event_id)
      }
    end)
    |> Enum.sort_by(&(&1.identifier || &1.issue_id || ""))
  end

  defp paused_snapshot_entries(_paused_issue_states), do: []

  defp skipped_snapshot_entries(skipped_issues) when is_list(skipped_issues) do
    Enum.map(skipped_issues, fn entry ->
      %{
        issue_id: Map.get(entry, :issue_id),
        issue_identifier: Map.get(entry, :issue_identifier),
        source: Map.get(entry, :source),
        state: Map.get(entry, :state),
        labels: Map.get(entry, :labels, []),
        runner_channel: Map.get(entry, :runner_channel),
        target_runner_channel: Map.get(entry, :target_runner_channel),
        required_labels: Map.get(entry, :required_labels, []),
        reason: Map.get(entry, :reason, "label_gate"),
        policy_class: Map.get(entry, :policy_class),
        policy_source: Map.get(entry, :policy_source),
        policy_override: Map.get(entry, :policy_override),
        next_human_action: Map.get(entry, :next_human_action),
        last_rule_id: Map.get(entry, :last_rule_id),
        last_failure_class: Map.get(entry, :last_failure_class),
        lease: Map.get(entry, :lease),
        lease_owner: lease_owner_from_entry(entry),
        lease_status: lease_status_from_entry(entry),
        lease_owner_instance_id: lease_owner_instance_id_from_entry(entry),
        lease_owner_channel: lease_owner_channel_from_entry(entry),
        lease_acquired_at: lease_acquired_at_from_entry(entry),
        lease_updated_at: lease_updated_at_from_entry(entry),
        lease_epoch: lease_epoch_from_entry(entry),
        lease_age_ms: lease_age_ms_from_entry(entry),
        lease_ttl_ms: lease_ttl_ms_from_entry(entry),
        lease_reclaimable: lease_reclaimable_from_entry(entry)
      }
    end)
  end

  defp skipped_snapshot_entries(_skipped_issues), do: []

  defp queue_snapshot(%State{} = state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    {eligible_issues, _skipped_issues} =
      partition_issues_by_label_gate(Map.get(state, :last_candidate_issues, []), state)

    queue_entries =
      eligible_issues
      |> Enum.filter(&candidate_issue?(&1, active_states, terminal_states))
      |> Enum.reject(fn %Issue{id: issue_id} = issue ->
        issue_paused?(state, issue) or Map.has_key?(state.running, issue_id)
      end)
      |> PriorityEngine.rank_issues(
        priority_overrides: state.priority_overrides,
        retry_attempts: state.retry_attempts
      )
      |> Enum.map(fn entry ->
        workspace_path = Workspace.path_for_issue(entry.identifier || entry.issue_id)

        run_state = load_run_state(workspace_path, entry.issue)
        {policy_class, policy_source, policy_override} = policy_snapshot_values(entry.issue, state, run_state)

        {last_rule_id, last_failure_class, last_decision_summary, next_human_action} =
          queue_policy_reason(entry.issue, state, run_state)

        lease = stateful_lease_details(entry.issue_id, run_state)

        %{
          issue_id: entry.issue_id,
          issue_identifier: entry.identifier,
          source: entry.issue.source,
          state: entry.issue.state,
          linear_priority: entry.issue.priority,
          operator_override: entry.reasons.operator_override,
          retry_penalty: entry.reasons.retry_penalty,
          rank: entry.rank,
          labels: Issue.label_names(entry.issue),
          runner_channel: Config.runner_channel(),
          target_runner_channel: issue_target_runner_channel(entry.issue),
          required_labels: routing_required_labels(),
          label_gate_eligible: issue_matches_required_labels?(entry.issue),
          policy_class: policy_class,
          policy_source: policy_source,
          policy_override: policy_override,
          next_human_action: next_human_action,
          last_rule_id: last_rule_id,
          last_failure_class: last_failure_class,
          last_decision_summary: last_decision_summary,
          last_ledger_event_id: Map.get(run_state, :last_ledger_event_id),
          lease: lease,
          lease_owner: Map.get(lease, :lease_owner),
          lease_status: Map.get(lease, :lease_status),
          lease_owner_instance_id: Map.get(lease, :lease_owner_instance_id),
          lease_owner_channel: Map.get(lease, :lease_owner_channel),
          lease_acquired_at: Map.get(lease, :lease_acquired_at),
          lease_updated_at: Map.get(lease, :lease_updated_at),
          lease_epoch: Map.get(lease, :lease_epoch),
          lease_age_ms: Map.get(lease, :lease_age_ms),
          lease_ttl_ms: Map.get(lease, :lease_ttl_ms),
          lease_reclaimable: Map.get(lease, :lease_reclaimable, false)
        }
      end)

    case {queue_entries, Map.get(state, :candidate_fetch_error)} do
      {[], reason} when not is_nil(reason) -> [%{error: inspect(reason)}]
      _ -> queue_entries
    end
  end

  @doc false
  @spec dispatch_runtime_issue(State.t(), Issue.t(), non_neg_integer()) :: State.t()
  def dispatch_runtime_issue(%State{} = state, %Issue{} = issue, attempt) do
    dispatch_runtime_issue(
      state,
      issue,
      attempt,
      &dispatch_active_issue/3,
      &dispatch_passive_issue/3
    )
  end

  defp dispatch_runtime_issue(%State{admission_read: %{purpose: :promotion, issue: %{id: id}}} = state, %Issue{id: id}, _attempt, _active_dispatch_fun, _passive_dispatch_fun), do: state

  defp dispatch_runtime_issue(
         %State{} = state,
         %Issue{} = issue,
         attempt,
         active_dispatch_fun,
         passive_dispatch_fun
       )
       when is_function(active_dispatch_fun, 3) and is_function(passive_dispatch_fun, 3) do
    with :ok <- token_usage_dispatch_guard(state, issue.id),
         :ok <- validate_dispatch_configuration(issue),
         {:ok, workspace} <- current_custody_workspace(state, issue),
         :ok <- DeployAudit.ensure_available(workspace),
         :ok <- DispatchAudit.ensure_available(workspace),
         :ok <- RunStateStore.ensure_readable(workspace),
         :ok <- persisted_issue_token_budget_guard(issue, workspace),
         {:ok, dispatch_stage} <- persisted_dispatch_stage(issue, workspace) do
      case dispatch_stage do
        stage when stage in ["merge_readiness", "await_checks", "merge", "post_merge"] ->
          passive_dispatch_fun.(state, issue, attempt)

        _ ->
          active_dispatch_fun.(state, issue, attempt)
      end
    else
      {:error, {:persisted_stage_requires_explicit_resume, _stage} = reason} ->
        stop_terminal_dispatch(state, issue, reason)

      {:error, reason} ->
        Logger.error("Dispatch blocked by runtime validation issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
        state = tracker_inbox_outcome(state, issue.id, tracker_inbox_validation_outcome(reason))
        %{state | candidate_fetch_error: reason}
    end
  end

  defp persist_dispatchable_issue_lease(state, workspace, issue) do
    with {:ok, _stage} <- persisted_dispatch_stage(issue, workspace) do
      persist_live_issue_lease(state, workspace, issue)
    end
  end

  defp stop_terminal_dispatch(state, issue, reason) do
    state = tracker_inbox_outcome(state, issue.id, {:applied, :dispatch_rejected})
    released = release_issue_claim(state, issue.id)

    case released.candidate_fetch_error do
      {:lease_release_audit_failed, id, _} when id == issue.id -> released
      _ -> if Map.has_key?(released.lease_claims, issue.id), do: released, else: %{released | candidate_fetch_error: reason}
    end
  end

  defp persisted_dispatch_stage(issue, workspace \\ nil) do
    workspace = workspace || Workspace.path_for_issue(issue)

    with :ok <- DeployAudit.ensure_available(workspace),
         :ok <- DispatchAudit.ensure_available(workspace),
         :ok <- SymphonyElixir.RunIdentity.ensure_issue(workspace, issue) do
      case RunStateStore.load_checked(workspace, issue) do
        {:ok, %{stage: stage}} when stage in ["blocked", "done"] ->
          {:error, {:persisted_stage_requires_explicit_resume, stage}}

        {:ok, %{stage: stage}} ->
          {:ok, stage}

        {:mismatch, _state} ->
          {:ok, "checkout"}

        {:error, :missing} ->
          {:ok, "checkout"}

        {:error, reason} ->
          {:error, {:run_state_unreadable, reason}}
      end
    end
  end

  defp validate_dispatch_configuration(issue) do
    with :ok <- WorkflowStore.force_reload(),
         :ok <- Config.validate!() do
      :ok
    else
      {:error, reason} = error ->
        record_invalid_dispatch_configuration(reason, %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_id: "orchestrator",
          metadata: %{}
        })

        error
    end
  end

  defp record_invalid_dispatch_configuration(reason, context) do
    RunLedger.record(
      "config_invalid",
      Map.merge(context, %{
        actor_type: "runtime",
        rule_id: "config.invalid",
        failure_class: "configuration",
        summary: "New dispatch blocked by invalid workflow configuration.",
        details: inspect(reason),
        metadata: Map.put(context.metadata, :workflow_path, Workflow.workflow_file_path())
      })
    )
  end

  defp persisted_issue_token_budget_guard(issue, workspace) do
    workspace = workspace || Workspace.path_for_issue(issue)
    run_state = RunStateStore.load_or_default(workspace, issue)

    case RunPolicy.maybe_stop_for_token_budget(issue, %{
           workspace_path: workspace,
           stage: Map.get(run_state, :stage),
           resume_context: Map.get(run_state, :resume_context, %{}),
           issue_token_usage_base: Map.get(run_state, :token_usage, %{})
         }) do
      :ok -> :ok
      {:stop, violation} -> {:error, {:token_budget_exhausted, violation.rule_id}}
    end
  end

  defp token_usage_dispatch_guard(state, issue_id) do
    case Map.fetch(state.token_usage_errors, issue_id) do
      {:ok, reason} -> {:error, {:token_usage_persistence_failed, reason}}
      :error -> :ok
    end
  end

  defp normalize_dispatch_stage(%Issue{} = issue, workspace \\ nil) do
    workspace = workspace || Workspace.path_for_issue(issue)
    inspection = RunInspector.inspect(workspace)
    expected_branch = GitManager.issue_branch_name(issue)

    case RunStateStore.load_checked(workspace, issue) do
      {:mismatch, _stale_state} ->
        repair_stage(
          workspace,
          issue,
          "checkout",
          "Recovered from stale run state that belonged to a different issue."
        )

      {:ok, %{stage: stage} = state} ->
        cond do
          merged_pr_without_post_merge?(inspection, stage) ->
            repair_stage(
              workspace,
              issue,
              "post_merge",
              "Recovered from a merged PR with incomplete local runtime state.",
              %{
                pr_url: inspection.pr_url,
                last_pr_state: inspection.pr_state,
                last_merge: %{status: :already_merged, url: inspection.pr_url}
              }
            )

          ambiguous_branch_pr_block?(inspection, state, expected_branch) ->
            block_dispatch_stage(
              workspace,
              issue,
              "The workspace branch or attached PR does not belong to this issue, and Symphony found dirty or publish-related state that it cannot safely repair automatically.",
              :branch_pr_mismatch,
              %{
                current_branch: inspection.branch,
                expected_branch: expected_branch,
                pr_url: inspection.pr_url || Map.get(state, :pr_url)
              }
            )

          pr_metadata_drift_repair?(inspection, state) ->
            repair_stage(
              workspace,
              issue,
              stage,
              "Recovered from stale PR metadata by syncing the current branch PR state.",
              %{
                pr_url: inspection.pr_url,
                last_pr_state: inspection.pr_state
              }
            )

          missing_checkout_repair?(inspection, stage) ->
            repair_stage(
              workspace,
              issue,
              "checkout",
              "Recovered from a workspace without a valid Git checkout."
            )

          branch_mismatch_repair?(inspection, state, expected_branch) ->
            repair_stage(
              workspace,
              issue,
              "checkout",
              "Recovered from a clean checkout on the wrong branch; Symphony will recreate the issue branch."
            )

          true ->
            stage
        end

      {:error, :missing} ->
        "checkout"

      {:error, _reason} ->
        Logger.error("Dispatch blocked by unreadable snapshot issue_identifier=#{issue.identifier} workspace=#{workspace}")
        "blocked"
    end
  end

  defp repair_stage(workspace, issue, stage, reason, attrs \\ %{}) do
    {:ok, _state} =
      RunStateStore.transition(
        workspace,
        stage,
        Map.merge(
          %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            issue_source: issue.source,
            stop_reason: nil,
            last_decision: nil,
            last_rule_id: nil,
            last_failure_class: nil,
            last_decision_summary: reason,
            next_human_action: nil
          },
          attrs
        )
      )

    RunLedger.record("runtime.repaired", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      stage: stage,
      actor_type: "runtime",
      actor_id: "orchestrator",
      summary: reason,
      metadata: %{repair_stage: stage}
    })

    stage
  end

  defp merged_pr_without_post_merge?(inspection, stage) do
    normalize_pr_state(inspection.pr_state) == "MERGED" and stage not in ["post_merge", "done"]
  end

  defp missing_checkout_repair?(inspection, stage) do
    not inspection.git? and stage not in ["checkout", "done"]
  end

  defp pr_metadata_drift_repair?(inspection, state) do
    current_pr_url = Map.get(state, :pr_url)
    current_pr_state = Map.get(state, :last_pr_state)

    is_binary(inspection.pr_url) and inspection.pr_url != "" and
      (current_pr_url != inspection.pr_url or current_pr_state != inspection.pr_state)
  end

  defp branch_mismatch_repair?(inspection, state, expected_branch) do
    stage = Map.get(state, :stage)

    inspection.git? and not inspection.dirty? and
      stage in ["implement", "validate", "verify", "publish"] and
      is_binary(expected_branch) and expected_branch != "" and
      inspection.branch != expected_branch and
      normalize_pr_state(inspection.pr_state) not in ["MERGED", "CLOSED"]
  end

  defp ambiguous_branch_pr_block?(inspection, state, expected_branch) do
    stage = Map.get(state, :stage)
    persisted_branch = Map.get(state, :branch)
    persisted_pr_url = Map.get(state, :pr_url)

    inspection.git? and
      stage in ["implement", "validate", "verify", "publish", "merge_readiness", "await_checks", "merge"] and
      is_binary(expected_branch) and expected_branch != "" and
      is_binary(inspection.branch) and inspection.branch != "" and
      inspection.branch != expected_branch and
      normalize_pr_state(inspection.pr_state) not in ["MERGED", "CLOSED"] and
      (inspection.dirty? or
         (is_binary(inspection.pr_url) and inspection.pr_url != "") or
         (is_binary(persisted_pr_url) and persisted_pr_url != "") or
         (is_binary(persisted_branch) and persisted_branch != "" and
            persisted_branch != expected_branch))
  end

  defp normalize_pr_state(nil), do: nil

  defp normalize_pr_state(pr_state) do
    pr_state
    |> to_string()
    |> String.trim()
    |> String.upcase()
  end

  defp maybe_promote_review_ready_issue(%State{} = state, %Issue{} = issue) do
    workspace = Workspace.path_for_issue(issue.identifier || issue.id)
    inspection = RunInspector.inspect(workspace)

    case resolve_policy(issue, state) do
      {:ok, %{class: :fully_autonomous}} ->
        if issue_routable_to_worker?(issue) and issue_matches_required_labels?(issue) and
             RunInspector.ready_for_merge?(inspection) do
          case IssueSource.update_issue_state(issue, @merging_state) do
            :ok ->
              RunLedger.record("policy.decided", %{
                issue_id: issue.id,
                issue_identifier: issue.identifier,
                actor_type: "runtime",
                actor_id: "orchestrator",
                policy_class: "fully_autonomous",
                rule_id: "policy.fully_autonomous",
                summary: "Auto-promoted review-ready issue to #{@merging_state}.",
                details: inspection.pr_url,
                target_state: @merging_state
              })

            {:error, reason} ->
              Logger.warning("Failed to auto-promote #{SymphonyElixir.Util.issue_log_context(issue)} to #{@merging_state}: #{inspect(reason)}")
          end

          state
        else
          state
        end

      _ ->
        state
    end
  end

  @doc false
  @spec issue_paused?(State.t(), Issue.t()) :: boolean()
  def issue_paused?(%State{} = state, %Issue{id: issue_id}) when is_binary(issue_id) do
    Map.has_key?(state.paused_issue_states, issue_id)
  end

  def issue_paused?(_state, _issue), do: false

  defp integrate_agent_update(running_entry, update), do: integrate_agent_update(running_entry, update, extract_token_delta(running_entry, update))

  defp integrate_agent_update(running_entry, %{event: event, timestamp: timestamp} = update, token_delta) do
    agent_input_tokens = Map.get(running_entry, :agent_input_tokens, 0)
    agent_output_tokens = Map.get(running_entry, :agent_output_tokens, 0)
    agent_total_tokens = Map.get(running_entry, :agent_total_tokens, 0)
    agent_process_id = Map.get(running_entry, :agent_process_id)
    last_reported_input = Map.get(running_entry, :agent_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :agent_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :agent_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_agent_timestamp: timestamp,
        last_agent_message: summarize_agent_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_agent_event: event,
        agent_process_id: agent_process_id_for_update(agent_process_id, update),
        agent_input_tokens: agent_input_tokens + token_delta.input_tokens,
        agent_output_tokens: agent_output_tokens + token_delta.output_tokens,
        agent_total_tokens: agent_total_tokens + token_delta.total_tokens,
        agent_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        agent_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        agent_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_started_input_tokens:
          turn_started_input_for_update(
            Map.get(running_entry, :turn_started_input_tokens, 0),
            agent_input_tokens + token_delta.input_tokens,
            running_entry.session_id,
            update
          ),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        recent_agent_updates:
          append_recent_agent_update(
            Map.get(running_entry, :recent_agent_updates, []),
            summarize_agent_update(update)
          )
      }),
      token_delta
    }
  end

  defp append_recent_agent_update(existing, summarized_update) when is_list(existing) do
    (existing ++ [summarized_update])
    |> Enum.take(-12)
  end

  defp append_recent_agent_update(_existing, summarized_update), do: [summarized_update]

  defp agent_process_id_for_update(_existing, %{agent_process_id: pid})
       when is_binary(pid),
       do: pid

  defp agent_process_id_for_update(_existing, %{agent_process_id: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp agent_process_id_for_update(_existing, %{agent_process_id: pid}) when is_list(pid),
    do: to_string(pid)

  defp agent_process_id_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp turn_started_input_for_update(_existing, current_total, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(current_total) and is_binary(session_id) do
    if session_id == existing_session_id do
      current_total
    else
      current_total
    end
  end

  defp turn_started_input_for_update(existing, _current_total, _existing_session_id, _update)
       when is_integer(existing),
       do: existing

  defp turn_started_input_for_update(_existing, _current_total, _existing_session_id, _update),
    do: 0

  defp summarize_agent_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  @doc false
  @spec schedule_tick(non_neg_integer()) :: reference()
  def schedule_tick(delay_ms) do
    :timer.send_after(delay_ms, self(), :tick)
    :ok
  end

  defp schedule_healing_tick(delay_ms) do
    :timer.send_after(delay_ms, self(), :healing_tick)
    :ok
  end

  @doc false
  @spec schedule_poll_cycle_start() :: reference()
  def schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp schedule_healing_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_healing_cycle)
    :ok
  end

  defp schedule_webhook_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_webhook_cycle)
    :ok
  end

  defp schedule_github_webhook_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_github_webhook_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp dispatch_mode(%State{} = state) do
    cond do
      tracker_backoff_active?(state) and Config.manual_enabled?() -> "manual_only_degraded"
      tracker_backoff_active?(state) -> "tracker_paused"
      true -> "normal"
    end
  end

  defp dispatch_summary(%State{} = state) do
    cond do
      tracker_backoff_active?(state) and Config.manual_enabled?() ->
        "Tracker reads are paused due to rate limiting; manual issues continue to dispatch."

      tracker_backoff_active?(state) ->
        "Tracker reads are paused due to rate limiting; no manual intake is enabled."

      true ->
        "Webhook-first intake is healthy; fallback polling remains available."
    end
  end

  defp webhook_health(%State{} = state) do
    cond do
      not webhook_enabled?() ->
        "disabled"

      present?(Map.get(state, :webhook_last_rejected_reason)) ->
        "degraded"

      true ->
        "healthy"
    end
  end

  defp webhook_mode do
    if webhook_enabled?(), do: "webhook_first", else: "polling_fallback"
  end

  defp webhook_enabled? do
    case Config.linear_webhook_secret() do
      secret when is_binary(secret) -> String.trim(secret) != ""
      _ -> false
    end
  end

  defp github_webhook_enabled? do
    case Config.github_webhook_secret() do
      secret when is_binary(secret) -> String.trim(secret) != ""
      _ -> false
    end
  end

  defp github_webhook_health(%State{} = state) do
    cond do
      not github_webhook_enabled?() ->
        "disabled"

      present?(Map.get(state, :github_webhook_last_rejected_reason)) ->
        "degraded"

      true ->
        "healthy"
    end
  end

  defp list_workspace_paths(root) when is_binary(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      _ ->
        []
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(value), do: value not in [nil, ""]

  defp datetime_to_iso8601(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp datetime_to_iso8601(_timestamp), do: nil

  defp pop_running_entry(state, issue_id) do
    entry = Map.get(state.running, issue_id)

    {entry, state} =
      case current_issue_custody(state, issue_id, Map.get(entry || %{}, :custody_ref)) do
        {:ok, _claim} -> {entry, transfer_issue_custody(state, issue_id, :retry)}
        {:error, reason} -> {Map.put(entry, :lease_ownership_uncertain, reason), state}
      end

    {entry, %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    agent_totals =
      apply_token_delta(
        state.agent_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | agent_totals: agent_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  @doc false
  @spec refresh_runtime_config(State.t()) :: State.t()
  def refresh_runtime_config(%State{} = state) do
    state =
      Enum.reduce(Map.keys(state.running), state, fn issue_id, state_acc ->
        refresh_result =
          case Map.fetch!(state_acc.running, issue_id) do
            %{lease_ownership_uncertain: reason} ->
              {:error, reason}

            %{agent_execution: %{registry: %{uncertain: cause}}} when not is_nil(cause) ->
              :pending

            entry ->
              with {:ok, claim} <- current_issue_custody(state_acc, issue_id, Map.get(entry, :custody_ref)) do
                if claim.holder == :running, do: LeaseManager.refresh_token(claim.token), else: :pending
              end
          end

        case refresh_result do
          {:ok, lease} ->
            state_acc = put_in(state_acc.lease_claims[issue_id].lease, lease)
            maybe_sync_running_issue_lease(state_acc, issue_id)
            state_acc

          :pending ->
            state_acc

          {:error, reason} when reason in [:claimed, :lease_token_mismatch, :lease_custody_missing, :lease_custody_changed] ->
            Logger.warning("Lost persisted lease for running issue_id=#{issue_id}; terminating local worker")

            RunLedger.record("runtime.stopped", %{
              issue_id: issue_id,
              actor_type: "system",
              actor_id: state.lease_owner,
              failure_class: RuleCatalog.failure_class(:lease_lost),
              rule_id: RuleCatalog.rule_id(:lease_lost),
              summary: "Lost the persisted lease for a running issue.",
              details: RuleCatalog.human_action(:lease_lost)
            })

            terminate_running_issue(state_acc, issue_id, false)

          {:error, :missing} ->
            Logger.warning("Lease missing for running issue_id=#{issue_id}; terminating local worker")

            terminate_running_issue(state_acc, issue_id, false)

          {:error, reason} ->
            stop_for_uncertain_lease(state_acc, issue_id, reason)
        end
      end)

    try do
      %{
        state
        | poll_interval_ms: Config.poll_interval_ms(),
          healing_poll_interval_ms: Config.healing_poll_interval_ms(),
          max_concurrent_agents: Config.max_concurrent_agents()
      }
    catch
      :exit, _reason ->
        state
    end
  end

  defp stop_for_uncertain_lease(state, issue_id, reason) do
    completion = Map.get(Map.get(state.running, issue_id) || %{}, :completion)
    state |> do_stop_for_uncertain_lease(issue_id, reason) |> finish_tracker_inbox_action(completion, {:blocked, {:lease_ownership_uncertain, reason}})
  end

  defp do_stop_for_uncertain_lease(state, issue_id, reason) do
    state = tracker_inbox_failure(state, issue_id, {:lease_ownership_uncertain, reason})
    Logger.error("Lease ownership uncertain for issue_id=#{issue_id}; terminating worker and preserving its audit: #{inspect(reason)}")
    running_entry = state.running |> Map.fetch!(issue_id) |> Map.put(:lease_ownership_uncertain, reason)
    state = %{state | running: Map.put(state.running, issue_id, running_entry)}
    state = cancel_dispatch_retry(state, issue_id)

    if Map.get(running_entry, :execution_started?, false) do
      request_accounted_worker_stop(state, issue_id, running_entry, false)
    else
      case terminate_task(running_entry.pid) do
        :ok ->
          if is_reference(running_entry.ref), do: Process.demonitor(running_entry.ref, [:flush])
          state = record_session_completion_totals(state, running_entry)

          %{
            state
            | running: Map.delete(state.running, issue_id),
              candidate_fetch_error: {:lease_ownership_uncertain, issue_id, reason}
          }

        {:error, termination_reason} ->
          %{state | candidate_fetch_error: {:lease_ownership_uncertain, issue_id, reason, termination_reason}}
      end
    end
  end

  @doc false
  @spec retry_candidate_issue?(Issue.t(), MapSet.t()) :: boolean()
  def retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  @doc false
  @spec dispatch_slots_available?(Issue.t(), State.t()) :: boolean()
  def dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, capacity_entries(state))
  end

  defp apply_agent_token_delta(
         %{agent_totals: agent_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
  end

  defp apply_agent_token_delta(state, _token_delta), do: state

  defp apply_agent_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | agent_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_agent_rate_limits(state, _update), do: state

  defp execution_context(ticket, token, owner, worker),
    do: %{ticket: ticket, lease_token: token, owner: owner, worker: worker, issue_id: token.storage.issue_id}

  defp matching_execution_entry(state, %{owner: owner, worker: worker, issue_id: issue_id, ticket: ticket, lease_token: token} = context)
       when owner == self() and is_pid(worker) and is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{pid: ^worker, dispatch_ticket: ^ticket, lease_token: ^token, agent_execution: %{context: ^context}} = entry ->
        {:ok, issue_id, entry}

      _ ->
        :error
    end
  end

  defp matching_execution_entry(_state, _context), do: :error

  defp execution_custody(state, issue_id, entry) do
    with {:ok, claim} <- current_issue_custody(state, issue_id, entry.custody_ref),
         true <- (claim.holder == :running and claim.token == entry.lease_token) or {:error, :execution_custody_changed} do
      :ok
    end
  end

  defp execution_owner_action(state, issue_id, entry, action) do
    registry = entry.agent_execution.registry

    with nil <- registry.uncertain,
         :ok <- execution_custody(state, issue_id, entry) do
      case action do
        {:register, binding, purpose} ->
          AgentExecution.register_binding(registry, binding, purpose)

        {:begin, binding, ordinal} ->
          AgentExecution.begin_binding(registry, binding, ordinal)

        {:retire, binding, ordinal} when ordinal == registry.ordinal ->
          AgentExecution.retire_binding(registry, binding)

        {:confirm, binding, ordinal} ->
          if current_execution_invocation?(registry, binding, ordinal), do: {:ok, registry}, else: {:error, :obsolete_invocation}

        _ ->
          {:error, :invalid_execution_action}
      end
    else
      {:error, _} = error -> error
      cause -> {:error, {:accounting_uncertain, cause}}
    end
  end

  defp current_execution_invocation?(registry, binding, ordinal),
    do: registry.current == binding and registry.ordinal == ordinal and (is_nil(binding) or Map.has_key?(registry.live, binding))

  defp authorized_execution_invocation(state, context, %{binding: binding, ordinal: ordinal}) do
    with {:ok, issue_id, entry} <- matching_execution_entry(state, context),
         nil <- entry.agent_execution.registry.uncertain,
         :ok <- execution_custody(state, issue_id, entry),
         true <- current_execution_invocation?(entry.agent_execution.registry, binding, ordinal) do
      {:ok, issue_id, entry}
    else
      _ -> :error
    end
  end

  defp authorized_execution_invocation(_state, _context, _invocation), do: :error

  defp receive_execution_usage(state, context, invocation, observation) do
    case authorized_execution_invocation(state, context, invocation) do
      {:ok, issue_id, entry} ->
        with {:ok, registry, delta} <- AgentExecution.apply_usage(entry.agent_execution.registry, invocation.binding, invocation.ordinal, observation),
             totals = AgentExecution.total_usage(registry),
             {:ok, usage} <- execution_usage_with_baseline(entry.issue_token_usage_base, totals),
             {:ok, persisted} <- RunStateStore.record_token_usage(entry.workspace_path, entry.issue, usage, context) do
          base = Map.new(totals, fn {dimension, value} -> {dimension, Map.fetch!(persisted.token_usage, dimension) - value} end)

          proposed =
            entry
            |> put_in([:agent_execution, :registry], registry)
            |> Map.merge(%{agent_input_tokens: totals.input_tokens, agent_output_tokens: totals.output_tokens, agent_total_tokens: totals.total_tokens, issue_token_usage_base: base})

          next = state |> Map.put(:running, Map.put(state.running, issue_id, proposed)) |> apply_agent_token_delta(delta)
          Observability.emit_token_delta(proposed, delta, %{event: :usage_observed})
          next = maybe_stop_issue_for_token_budget(next, issue_id, proposed)
          notify_dashboard()
          next
        else
          {:error, cause} -> mark_accounting_uncertain(state, issue_id, cause)
        end

      :error ->
        state
    end
  end

  defp execution_usage_with_baseline(base, totals) when is_map(base) do
    dimensions = [:input_tokens, :output_tokens, :total_tokens]
    valid = base == %{} or (Enum.sort(Map.keys(base)) == Enum.sort(dimensions) and Enum.all?(dimensions, &(is_integer(Map.fetch!(base, &1)) and Map.fetch!(base, &1) >= 0)))
    if valid, do: {:ok, Map.new(totals, fn {key, value} -> {key, Map.get(base, key, 0) + value} end)}, else: {:error, :invalid_token_usage}
  end

  defp execution_usage_with_baseline(_base, _totals), do: {:error, :invalid_token_usage}

  defp mark_accounting_uncertain(state, issue_id, cause) do
    entry = Map.fetch!(state.running, issue_id)
    registry = AgentExecution.mark_uncertain(entry.agent_execution.registry, cause)
    first = registry.uncertain
    entry = put_in(entry.agent_execution.registry, registry)
    error = %{context: entry.agent_execution.context, cause: first}
    next = cancel_dispatch_retry(state, issue_id)

    %{
      next
      | running: Map.put(next.running, issue_id, entry),
        token_usage_errors: Map.put(next.token_usage_errors, issue_id, {:accounting_uncertain, error}),
        candidate_fetch_error: {:accounting_uncertain, issue_id, first}
    }
  end

  defp accounting_down_cause(%{agent_execution: %{registry: %{uncertain: cause}}}, _reason) when not is_nil(cause), do: cause
  defp accounting_down_cause(%{agent_execution: _execution}, {:accounting_uncertain, cause}), do: if(is_nil(cause), do: :invalid_uncertainty_cause, else: cause)
  defp accounting_down_cause(_entry, _reason), do: nil

  defp finish_uncertain_worker_down(state, issue_id, entry, cause) do
    next = mark_accounting_uncertain(state, issue_id, cause)
    next = record_session_completion_totals(next, entry)
    Logger.error("Accounting uncertain issue_id=#{issue_id}; worker stopped and captured lease/journal preserved: #{inspect(cause)}")
    notify_dashboard()
    %{next | running: Map.delete(next.running, issue_id)}
  end

  defp request_accounted_worker_stop(state, issue_id, entry, cleanup_workspace) do
    requested = Map.put(entry, :execution_stop_requested, %{cleanup_workspace: cleanup_workspace})
    next = %{state | running: Map.put(state.running, issue_id, requested)} |> cancel_dispatch_retry(issue_id)

    case terminate_task(entry.pid) do
      :ok -> next
      {:error, reason} -> %{next | candidate_fetch_error: {:accounting_worker_termination_unconfirmed, issue_id, reason}}
    end
  end

  defp finish_requested_worker_down(state, issue_id, entry) do
    completion = Map.get(entry, :completion)
    outcome = tracker_inbox_cleanup_outcome(state, completion)
    next = state |> record_session_completion_totals(entry) |> cancel_dispatch_retry(issue_id)
    next = %{next | running: Map.delete(next.running, issue_id)}

    finish = with :ok <- execution_custody(next, issue_id, entry), do: finish_running_dispatch(entry, :shutdown)

    next =
      case finish do
        :ok ->
          case entry.execution_stop_requested do
            %{retry: %{attempt: attempt, metadata: metadata}} -> schedule_issue_retry(next, issue_id, attempt, metadata)
            _ -> stop_terminal_dispatch(next, %{id: issue_id}, next.candidate_fetch_error)
          end

        {:ownership_uncertain, reason} ->
          %{next | candidate_fetch_error: {:lease_ownership_uncertain, issue_id, reason}}

        {:error, reason} when reason in [:lease_custody_missing, :lease_custody_changed, :execution_custody_changed] ->
          %{next | candidate_fetch_error: {:lease_ownership_uncertain, issue_id, reason}}

        {:error, reason} ->
          next |> stop_terminal_dispatch(%{id: issue_id}, reason) |> halt_dispatch_audit(issue_id, reason)
      end

    next |> tracker_inbox_outcome(issue_id, outcome) |> finish_tracker_inbox_action(completion, nil)
  end

  defp accounting_hold?(state, issue_id) do
    case Map.get(state.token_usage_errors, issue_id) do
      {:accounting_uncertain, %{context: _context, cause: _cause}} -> true
      _ -> false
    end
  end

  defp checkpoint_and_check_token_budget(state, issue_id, running_entry, token_delta) do
    changed? = Enum.any?([:input_tokens, :output_tokens, :total_tokens], &(Map.get(token_delta, &1, 0) > 0))

    if changed? and Map.has_key?(running_entry, :issue_token_usage_base) do
      case RunStateStore.record_token_usage(
             running_entry.workspace_path,
             running_entry.issue,
             RunPolicy.issue_token_usage(running_entry)
           ) do
        {:ok, _persisted} ->
          maybe_stop_issue_for_token_budget(state, issue_id, running_entry)

        {:error, reason} ->
          Logger.error("Stopping issue_id=#{issue_id}: token usage could not be persisted: #{inspect(reason)}")
          state = terminate_running_issue(state, issue_id, false)

          case IssueSource.update_issue_state(running_entry.issue, @blocked_state) do
            :ok -> :ok
            {:error, tracker_reason} -> Logger.error("Unable to block issue_id=#{issue_id} after token usage persistence failure: #{inspect(tracker_reason)}")
          end

          %{state | token_usage_errors: Map.put(state.token_usage_errors, issue_id, reason), candidate_fetch_error: {:token_usage_persistence_failed, reason}}
      end
    else
      maybe_stop_issue_for_token_budget(state, issue_id, running_entry)
    end
  end

  defp maybe_stop_issue_for_token_budget(%State{} = state, issue_id, running_entry) do
    if Map.has_key?(Map.get(state.running, issue_id, %{}), :execution_stop_requested) do
      state
    else
      apply_running_token_budget(state, issue_id, running_entry)
    end
  end

  defp apply_running_token_budget(state, issue_id, running_entry) do
    issue = Map.get(running_entry, :issue, %{})

    case RunPolicy.maybe_stop_for_token_budget(issue, running_entry) do
      :ok ->
        state

      {:retry, metadata} ->
        next_attempt = next_retry_attempt_from_running(running_entry) || 1

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: Map.get(running_entry, :identifier) || issue_id,
          delay_type: :continuation,
          issue: issue,
          error: Map.get(metadata, :summary, "adaptive token retry"),
          budget_retry: true,
          budget_mode: Map.get(metadata, :budget_mode, "review_fix"),
          budget_retry_count: Map.get(metadata, :retry_count),
          budget_resume_context: Map.get(metadata, :resume_context)
        })

      {:stop, _violation} ->
        continuation = continuation_metadata_for_running_entry(running_entry)
        continuation_delay_type = Map.get(continuation, :delay_type, :none)

        state = terminate_running_issue(state, issue_id, false)

        case continuation_delay_type do
          :none ->
            state

          delay_type ->
            schedule_issue_retry(
              state,
              issue_id,
              1,
              %{
                identifier: Map.get(running_entry, :identifier),
                delay_type: delay_type,
                issue: Map.get(running_entry, :issue)
              }
              |> Map.merge(Map.drop(continuation, [:delay_type]))
            )
        end
    end
  end

  defp load_run_state(workspace_path, %Issue{} = issue) when is_binary(workspace_path) do
    RunStateStore.load_or_default(workspace_path, issue)
  end

  defp load_run_state(workspace_path, issue) when is_binary(workspace_path) and is_map(issue) do
    RunStateStore.load_or_default(workspace_path, issue)
  end

  defp load_run_state(workspace_path, _issue) when is_binary(workspace_path) do
    case RunStateStore.load(workspace_path) do
      {:ok, run_state} -> run_state
      _ -> %{}
    end
  end

  defp retry_run_state(identifier, issue, retry_metadata \\ %{})

  defp retry_run_state(identifier, issue, retry_metadata)
       when is_binary(identifier) and identifier != "" do
    identifier
    |> Workspace.path_for_issue()
    |> load_run_state(issue)
    |> merge_retry_budget_resume_context(retry_metadata)
  end

  defp retry_run_state(_identifier, _issue, _retry_metadata), do: %{}

  defp persist_retry_budget_resume_context(workspace, identifier, metadata)
       when is_binary(workspace) and is_binary(identifier) and is_map(metadata) do
    case Map.get(metadata, :budget_resume_context) do
      resume_context when is_map(resume_context) ->
        if File.dir?(workspace) do
          case RunStateStore.update(workspace, fn persisted ->
                 merge_retry_budget_resume_context(persisted, %{budget_resume_context: resume_context})
               end) do
            {:ok, _state} ->
              :ok

            {:error, reason} ->
              Logger.error("Unable to persist budget retry context issue_identifier=#{identifier} error=#{inspect(reason)}")
          end
        end

      _ ->
        :ok
    end

    :ok
  end

  defp persist_retry_budget_resume_context(_workspace, _identifier, _metadata), do: :ok

  defp merge_retry_budget_resume_context(run_state, retry_metadata)
       when is_map(run_state) and is_map(retry_metadata) do
    case Map.get(retry_metadata, :budget_resume_context) do
      resume_context when is_map(resume_context) ->
        Map.update(run_state, :resume_context, resume_context, fn existing ->
          existing_map =
            case existing do
              context when is_map(context) -> context
              _ -> %{}
            end

          Map.merge(existing_map, resume_context)
        end)

      _ ->
        run_state
    end
  end

  defp merge_retry_budget_resume_context(run_state, _retry_metadata), do: run_state

  @doc false
  @spec resolve_policy(Issue.t(), State.t()) :: {:ok, term()} | {:error, term()}
  def resolve_policy(%Issue{} = issue, %State{} = state) do
    pack = PolicyPack.resolve(policy_pack_name(issue, state))

    IssuePolicy.resolve(issue,
      override: Map.get(state.policy_overrides, issue.identifier),
      default: pack.default_issue_class,
      allowed_classes: pack.allowed_policy_classes,
      policy_pack: PolicyPack.name_string(pack)
    )
  end

  @doc false
  def policy_snapshot_values(issue, state, run_state \\ %{})

  @spec policy_snapshot_values(term(), term(), map()) :: {term(), term(), term()}
  def policy_snapshot_values(%Issue{} = issue, %State{} = state, run_state)
      when is_map(run_state) do
    override =
      Map.get(run_state, :policy_override) || Map.get(state.policy_overrides, issue.identifier)

    pack = PolicyPack.resolve(policy_pack_name(issue, state, run_state))

    case IssuePolicy.resolve(issue,
           override: override,
           default: pack.default_issue_class,
           allowed_classes: pack.allowed_policy_classes,
           policy_pack: PolicyPack.name_string(pack)
         ) do
      {:ok, resolution} ->
        {
          IssuePolicy.class_to_string(resolution.class),
          Atom.to_string(resolution.source),
          IssuePolicy.class_to_string(resolution.override)
        }

      {:error, _conflict} ->
        {nil, nil, IssuePolicy.class_to_string(IssuePolicy.normalize_class(override))}
    end
  end

  def policy_snapshot_values(_issue, _state, _run_state), do: {nil, nil, nil}

  @doc false
  @spec policy_pack_name(Issue.t(), State.t(), map()) :: String.t() | nil
  def policy_pack_name(%Issue{} = issue, %State{} = state, run_state \\ %{})
      when is_map(run_state) do
    Map.get(run_state, :policy_pack) ||
      Map.get(state.running[issue.id] || %{}, :policy_pack) ||
      Config.policy_pack_name()
  end

  @doc false
  @spec dispatch_skip_reason(Issue.t(), State.t()) :: String.t() | nil
  def dispatch_skip_reason(%Issue{} = issue, %State{} = state) do
    label_gate = label_gate_status(issue)
    policy_result = resolve_policy(issue, state)

    cond do
      not issue_routed_to_current_runner_channel?(issue) ->
        "wrong runner channel"

      match?(%{eligible?: false}, label_gate) ->
        label_gate.reason

      match?({:error, _}, policy_result) ->
        {:error, conflict} = policy_result
        Map.get(conflict, :rule_id) || RuleCatalog.rule_id(:policy_invalid_labels)

      true ->
        nil
    end
  end

  defp queue_policy_reason(%Issue{} = issue, %State{} = state, run_state) do
    run_state = run_state || %{}

    last_decision =
      case Map.get(run_state, :last_decision) do
        %{} = decision -> decision
        _ -> %{}
      end

    case resolve_policy(issue, state) do
      {:error, conflict} ->
        {conflict.rule_id, conflict.failure_class, conflict.summary, conflict.human_action}

      {:ok, %{class: :review_required}} ->
        {
          RuleCatalog.rule_id(:policy_review_required),
          RuleCatalog.failure_class(:policy_review_required),
          "Policy requires human review before merge.",
          RuleCatalog.human_action(:policy_review_required)
        }

      {:ok, %{class: :never_automerge}} ->
        {
          RuleCatalog.rule_id(:policy_never_automerge),
          RuleCatalog.failure_class(:policy_never_automerge),
          "Policy forbids automerge for this issue.",
          RuleCatalog.human_action(:policy_never_automerge)
        }

      _ ->
        {
          Map.get(run_state, :last_rule_id) || Map.get(last_decision, :rule_id),
          Map.get(run_state, :last_failure_class) || Map.get(last_decision, :failure_class),
          Map.get(run_state, :last_decision_summary) || Map.get(last_decision, :summary),
          Map.get(run_state, :next_human_action) || Map.get(last_decision, :human_action)
        }
    end
  end

  defp issue_routed_to_current_runner_channel?(%Issue{} = issue) do
    issue_target_runner_channel(issue) == Config.runner_channel()
  end

  @doc false
  @spec issue_target_runner_channel(Issue.t()) :: String.t()
  def issue_target_runner_channel(%Issue{} = issue) do
    canary_labels =
      RunnerRuntime.canary_required_labels(%{})
      |> normalize_labels()

    issue_labels =
      issue
      |> Issue.label_names()
      |> normalize_labels()

    if MapSet.size(canary_labels) > 0 and MapSet.subset?(canary_labels, issue_labels) do
      "canary"
    else
      "stable"
    end
  end

  @doc false
  @spec next_human_action_for_skip(term()) :: String.t() | nil
  def next_human_action_for_skip("missing required labels"),
    do: "Add the required routing labels before Symphony can dispatch this issue."

  def next_human_action_for_skip("missing canary labels"),
    do: "Add the canary routing labels before Symphony can dispatch this issue during canary mode."

  def next_human_action_for_skip("wrong runner channel"),
    do: "Route this issue to a runner on the matching channel before Symphony can dispatch it."

  def next_human_action_for_skip(reason) when is_binary(reason) do
    cond do
      reason == RuleCatalog.rule_id(:policy_invalid_labels) ->
        RuleCatalog.human_action(:policy_invalid_labels)

      true ->
        nil
    end
  end

  def next_human_action_for_skip(_reason), do: nil

  defp routing_required_labels do
    RunnerRuntime.effective_required_labels(Config.linear_required_labels())
  end

  defp missing_canary_labels?(issue_label_set, required_label_set)
       when is_struct(issue_label_set, MapSet) and is_struct(required_label_set, MapSet) do
    workflow_required = normalize_labels(Config.linear_required_labels())
    canary_required = MapSet.difference(required_label_set, workflow_required)

    MapSet.size(canary_required) > 0 and not MapSet.subset?(canary_required, issue_label_set)
  end

  defp missing_canary_labels?(_issue_label_set, _required_label_set), do: false

  defp block_issue_for_policy_conflict(%State{} = state, %Issue{} = issue) do
    {:error, conflict} = resolve_policy(issue, state)
    rule_id = Map.get(conflict, :rule_id) || RuleCatalog.rule_id(:policy_invalid_labels)

    failure_class =
      Map.get(conflict, :failure_class) || RuleCatalog.failure_class(:policy_invalid_labels)

    summary = Map.get(conflict, :summary) || "Invalid policy configuration detected on the issue."

    details =
      Map.get(conflict, :details) ||
        case Map.get(conflict, :labels) do
          labels when is_list(labels) and labels != [] -> Enum.join(labels, ", ")
          _ -> "No additional details provided."
        end

    human_action =
      Map.get(conflict, :human_action) || RuleCatalog.human_action(:policy_invalid_labels)

    workspace = Workspace.path_for_issue(issue.identifier || issue.id)

    ledger_event =
      RunLedger.record("runtime.stopped", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        actor_type: "runtime",
        actor_id: "orchestrator",
        failure_class: failure_class,
        rule_id: rule_id,
        summary: summary,
        details: details,
        target_state: @blocked_state,
        metadata: %{human_action: human_action}
      })

    _ =
      RunStateStore.transition(workspace, "blocked", %{
        stop_reason: %{
          code: conflict |> Map.get(:code) |> to_string(),
          rule_id: rule_id,
          failure_class: failure_class,
          details: details
        },
        last_decision: %{
          rule_id: rule_id,
          failure_class: failure_class,
          summary: summary,
          details: details,
          human_action: human_action,
          target_state: @blocked_state,
          ledger_event_id: Map.get(ledger_event, :event_id)
        },
        last_rule_id: rule_id,
        last_failure_class: failure_class,
        last_decision_summary: summary,
        next_human_action: human_action
      })

    _ =
      IssueSource.create_comment(
        issue,
        """
        ## Symphony policy stop

        Issue: #{issue.identifier}
        Rule ID: #{rule_id}
        Failure class: #{failure_class}

        #{summary}

        #{details}

        Unblock action: #{human_action}
        """
        |> String.trim()
      )

    _ = IssueSource.update_issue_state(issue, @blocked_state)
    terminate_running_issue(state, issue.id, false)
  end

  defp block_dispatch_stage(workspace, %Issue{} = issue, summary, rule_key, metadata)
       when is_binary(workspace) and is_binary(summary) and is_atom(rule_key) and is_map(metadata) do
    rule = RuleCatalog.rule(rule_key)

    ledger_event =
      RunLedger.record("runtime.stopped", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        stage: "blocked",
        actor_type: "runtime",
        actor_id: "orchestrator",
        failure_class: rule.failure_class,
        rule_id: rule.rule_id,
        summary: summary,
        details: inspect(metadata),
        target_state: @blocked_state,
        metadata: Map.put(metadata, :human_action, rule.human_action)
      })

    _ =
      RunStateStore.transition(workspace, "blocked", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_source: issue.source,
        stop_reason: %{
          code: Atom.to_string(rule_key),
          rule_id: rule.rule_id,
          failure_class: rule.failure_class,
          details: metadata
        },
        last_decision: %{
          rule_id: rule.rule_id,
          failure_class: rule.failure_class,
          summary: summary,
          details: metadata,
          human_action: rule.human_action,
          target_state: @blocked_state,
          ledger_event_id: Map.get(ledger_event, :event_id)
        },
        last_rule_id: rule.rule_id,
        last_failure_class: rule.failure_class,
        last_decision_summary: summary,
        next_human_action: rule.human_action
      })

    _ =
      IssueSource.create_comment(
        issue,
        """
        ## Symphony recovery stop

        Issue: #{issue.identifier}
        Rule ID: #{rule.rule_id}
        Failure class: #{rule.failure_class}

        #{summary}

        Details: #{inspect(metadata)}

        Unblock action: #{rule.human_action}
        """
        |> String.trim()
      )

    _ = IssueSource.update_issue_state(issue, @blocked_state)
    "blocked"
  end

  defp stateful_lease_details(issue_id, run_state)
       when is_binary(issue_id) and is_map(run_state) do
    stateful_lease_details(issue_id, run_state, DateTime.utc_now())
  end

  defp stateful_lease_details(issue_id, run_state, now)
       when is_binary(issue_id) and is_map(run_state) and is_struct(now, DateTime) do
    live_result = LeaseManager.read(issue_id)

    live_lease =
      case live_result do
        {:ok, lease} when is_map(lease) -> lease
        _ -> nil
      end

    ttl_ms = LeaseManager.ttl_ms()
    lease_owner = lease_field(live_lease, "owner") || Map.get(run_state, :lease_owner)

    lease_updated_at =
      lease_field(live_lease, "updated_at") || Map.get(run_state, :lease_updated_at)

    lease_acquired_at =
      lease_field(live_lease, "acquired_at") || Map.get(run_state, :lease_acquired_at)

    lease_epoch = lease_field(live_lease, "epoch") || Map.get(run_state, :lease_epoch)
    reclaimable? = is_map(live_lease) and lease_reclaimable?(live_lease, lease_updated_at, ttl_ms, now)

    lease_source =
      cond do
        is_map(live_lease) -> "live"
        live_result != {:error, :missing} -> "unverified"
        present?(lease_owner) -> "historical"
        true -> "missing"
      end

    %{
      lease_owner: lease_owner,
      lease_owner_instance_id: Map.get(run_state, :lease_owner_instance_id),
      lease_owner_channel: Map.get(run_state, :lease_owner_channel),
      lease_acquired_at: lease_acquired_at,
      lease_updated_at: lease_updated_at,
      lease_status: if(lease_source == "live", do: lease_status_value(lease_owner, reclaimable?), else: lease_source),
      lease_version: if(live_lease, do: live_lease["lease_version"], else: Map.get(run_state, :lease_version)),
      lease_generation: if(live_lease, do: live_lease["lease_generation"], else: Map.get(run_state, :lease_generation)),
      lease_error: if(lease_source == "unverified", do: inspect(live_result), else: nil),
      lease_epoch: lease_epoch,
      lease_age_ms: lease_age_ms(live_lease, lease_updated_at, now),
      lease_ttl_ms: ttl_ms,
      lease_reclaimable: reclaimable?,
      lease_source: lease_source
    }
  end

  defp stateful_lease_details(_issue_id, _run_state, _now) do
    %{
      lease_owner: nil,
      lease_owner_instance_id: nil,
      lease_owner_channel: nil,
      lease_acquired_at: nil,
      lease_updated_at: nil,
      lease_status: "missing",
      lease_epoch: nil,
      lease_age_ms: nil,
      lease_ttl_ms: LeaseManager.ttl_ms(),
      lease_reclaimable: false,
      lease_source: "missing"
    }
  end

  defp lease_field(nil, _key), do: nil

  defp lease_field(lease, "owner") when is_map(lease),
    do: Map.get(lease, "owner") || Map.get(lease, :owner)

  defp lease_field(lease, "updated_at") when is_map(lease),
    do: Map.get(lease, "updated_at") || Map.get(lease, :updated_at)

  defp lease_field(lease, "acquired_at") when is_map(lease),
    do: Map.get(lease, "acquired_at") || Map.get(lease, :acquired_at)

  defp lease_field(lease, "epoch") when is_map(lease),
    do: Map.get(lease, "epoch") || Map.get(lease, :epoch)

  defp lease_field(_lease, _key), do: nil

  defp lease_reclaimable?(lease, _updated_at, ttl_ms, now) when is_map(lease) do
    LeaseManager.reclaimable?(lease, now, ttl_ms: ttl_ms)
  rescue
    ArgumentError -> false
  end

  defp lease_reclaimable?(_lease, updated_at, ttl_ms, %DateTime{} = now)
       when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, timestamp, _offset} -> DateTime.diff(now, timestamp, :millisecond) > ttl_ms
      _ -> true
    end
  end

  defp lease_reclaimable?(_lease, _updated_at, _ttl_ms, _now), do: false

  defp lease_status_value(nil, _reclaimable?), do: "missing"
  defp lease_status_value(_owner, true), do: "reclaimable"
  defp lease_status_value(_owner, false), do: "held"

  defp lease_age_ms(lease, _updated_at, %DateTime{} = now) when is_map(lease) do
    LeaseManager.age_ms(lease, now)
  end

  defp lease_age_ms(_lease, updated_at, %DateTime{} = now) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, timestamp, _offset} -> max(DateTime.diff(now, timestamp, :millisecond), 0)
      _ -> nil
    end
  end

  defp lease_age_ms(_lease, _updated_at, _now), do: nil

  defp lease_owner_from_entry(entry),
    do: get_in(entry, [:lease, :lease_owner]) || Map.get(entry, :lease_owner)

  defp lease_status_from_entry(entry),
    do: get_in(entry, [:lease, :lease_status]) || Map.get(entry, :lease_status)

  defp lease_owner_instance_id_from_entry(entry),
    do:
      get_in(entry, [:lease, :lease_owner_instance_id]) ||
        Map.get(entry, :lease_owner_instance_id)

  defp lease_owner_channel_from_entry(entry),
    do: get_in(entry, [:lease, :lease_owner_channel]) || Map.get(entry, :lease_owner_channel)

  defp lease_acquired_at_from_entry(entry),
    do: get_in(entry, [:lease, :lease_acquired_at]) || Map.get(entry, :lease_acquired_at)

  defp lease_updated_at_from_entry(entry),
    do: get_in(entry, [:lease, :lease_updated_at]) || Map.get(entry, :lease_updated_at)

  defp lease_epoch_from_entry(entry),
    do: get_in(entry, [:lease, :lease_epoch]) || Map.get(entry, :lease_epoch)

  defp lease_age_ms_from_entry(entry),
    do: get_in(entry, [:lease, :lease_age_ms]) || Map.get(entry, :lease_age_ms)

  defp lease_ttl_ms_from_entry(entry),
    do: get_in(entry, [:lease, :lease_ttl_ms]) || Map.get(entry, :lease_ttl_ms)

  defp lease_reclaimable_from_entry(entry),
    do: get_in(entry, [:lease, :lease_reclaimable]) || Map.get(entry, :lease_reclaimable, false)

  defp ensure_review_follow_up_lease(%State{} = state, run_state, workspace) when is_map(run_state) do
    with {:ok, issue, storage, claim} <- follow_up_location(state, run_state, workspace) do
      case claim do
        %{holder: holder} when holder in [:pending, :gated] ->
          {:skip, :lease_attempt_pending}

        %{} ->
          case LeaseManager.refresh_token(claim.token) do
            {:ok, lease} ->
              next = put_in(state.lease_claims[issue.id].lease, lease)
              {:ok, next, LeaseManager.snapshot_for_state(lease), false}

            {:error, reason} ->
              {:error, reason}
          end

        nil ->
          acquire = fn id, identifier, owner -> LeaseManager.acquire(id, identifier, owner, storage: storage) end

          case acquire_issue_custody(state, issue, acquire, workspace) do
            {:ok, next} ->
              next = transfer_issue_custody(next, issue.id, :follow_up)
              claim = Map.fetch!(next.lease_claims, issue.id)
              {:ok, next, LeaseManager.snapshot_for_state(claim.lease), true}

            {:error, reason} when reason in [:claimed, :lease_token_required] ->
              {:skip, reason}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp release_review_follow_up_lease(%State{} = state, run_state, _workspace) when is_map(run_state) do
    case Map.get(run_state, :issue_id) do
      id when is_binary(id) and id != "" -> release_issue_claim(state, id)
      _ -> state
    end
  end

  defp release_review_follow_up_lease(state, _run_state, _workspace), do: state

  defp persist_live_issue_lease(%State{} = state, workspace, issue) when is_binary(workspace) and is_map(issue) do
    with {:ok, claim} <- current_issue_custody(state, issue.id),
         true <- workspace == claim.workspace or {:error, :lease_workspace_changed},
         :ok <- SymphonyElixir.RunIdentity.ensure_issue(workspace, issue) do
      RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(claim.lease))
    end
  end

  defp maybe_sync_running_issue_lease(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{issue: issue, identifier: identifier}
      when is_map(issue) and is_binary(identifier) and identifier != "" ->
        workspace = workspace_for_issue_id(state, issue_id)

        case persist_live_issue_lease(state, workspace, issue) do
          {:ok, _run_state} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to sync lease state for issue_id=#{issue_id}: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end

  defp maybe_sync_running_issue_lease(_state, _issue_id), do: :ok

  defp workspace_for_issue_id(%State{lease_claims: claims}, issue_id) when is_map_key(claims, issue_id),
    do: Map.fetch!(claims, issue_id).workspace

  defp workspace_for_issue_id(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} when is_binary(identifier) and identifier != "" ->
        Workspace.path_for_issue(identifier)

      _ ->
        case LeaseManager.read(issue_id) do
          {:ok, lease} ->
            case lease["issue_identifier"] || lease[:issue_identifier] do
              identifier when is_binary(identifier) and identifier != "" ->
                Workspace.path_for_issue(identifier)

              _ ->
                nil
            end

          _ ->
            nil
        end
    end
  end

  defp workspace_for_issue_id(_state, _issue_id), do: nil

  defp maybe_clear_persisted_lease(workspace) when is_binary(workspace) do
    if File.exists?(RunStateStore.state_path(workspace)) do
      case RunStateStore.clear_lease(workspace) do
        {:ok, _run_state} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to clear persisted lease metadata for workspace=#{workspace}: #{inspect(reason)}")
      end
    end
  end

  defp maybe_clear_persisted_lease(_workspace), do: :ok

  defp apply_token_delta(agent_totals, token_delta) do
    input_tokens = Map.get(agent_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(agent_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(agent_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(agent_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :agent_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :agent_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :agent_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      Enum.find_value(payloads, &direct_token_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp direct_token_usage_from_payload(payload) when is_map(payload) do
    if integer_token_map?(payload), do: payload
  end

  defp direct_token_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp canonical_github_workspace?(workspace, %{issue_identifier: identifier})
       when is_binary(identifier) and identifier != "" do
    Path.expand(workspace) == Path.expand(Workspace.path_for_issue(identifier))
  end

  defp canonical_github_workspace?(_workspace, _run_state), do: false
end
