defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Config
  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PriorityEngine
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.RunnerRuntime
  alias SymphonyElixir.RunPolicy
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workspace

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @paused_state "Paused"
  @blocked_state "Blocked"
  @human_review_state "Human Review"
  @merging_state "Merging"
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :lease_owner,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      paused_issue_states: %{},
      skipped_issues: [],
      last_candidate_issues: [],
      candidate_fetch_error: nil,
      priority_overrides: %{},
      policy_overrides: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
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
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      lease_owner: "orchestrator-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    :ok = schedule_tick(0)

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)
    state = %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    now_ms = System.monotonic_time(:millisecond)
    next_poll_due_at_ms = now_ms + state.poll_interval_ms
    :ok = schedule_tick(state.poll_interval_ms)

    state = %{state | poll_check_in_progress: false, next_poll_due_at_ms: next_poll_due_at_ms}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation
              })

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}"
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> Map.put(:running, Map.put(running, issue_id, updated_running_entry))
          |> maybe_stop_issue_for_token_budget(issue_id, updated_running_entry)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)
    state = maybe_promote_review_ready_issues(state)
    runner = RunnerRuntime.info()

    if Map.get(runner, :dispatch_enabled, true) do
      with :ok <- Config.validate!(),
           {:ok, issues} <- Tracker.fetch_candidate_issues() do
        {eligible_issues, skipped_issues} = partition_issues_by_label_gate(issues, state)

        state = %{
          state
          | skipped_issues: skipped_issues,
            last_candidate_issues: issues,
            candidate_fetch_error: nil
        }

        if available_slots(state) > 0 do
          choose_issues(eligible_issues, state)
        else
          state
        end
      else
        {:error, :missing_linear_api_token} ->
          Logger.error("Linear API token missing in WORKFLOW.md")
          state

        {:error, :missing_linear_project_slug} ->
          Logger.error("Linear project slug missing in WORKFLOW.md")
          state

        {:error, :missing_tracker_kind} ->
          Logger.error("Tracker kind missing in WORKFLOW.md")

          state

        {:error, {:unsupported_tracker_kind, kind}} ->
          Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

          state

        {:error, {:invalid_codex_approval_policy, value}} ->
          Logger.error("Invalid codex.approval_policy in WORKFLOW.md: #{inspect(value)}")
          state

        {:error, {:invalid_codex_thread_sandbox, value}} ->
          Logger.error("Invalid codex.thread_sandbox in WORKFLOW.md: #{inspect(value)}")
          state

        {:error, {:invalid_codex_turn_sandbox_policy, reason}} ->
          Logger.error("Invalid codex.turn_sandbox_policy in WORKFLOW.md: #{inspect(reason)}")
          state

        {:error, {:missing_workflow_file, path, reason}} ->
          Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
          state

        {:error, :workflow_front_matter_not_a_map} ->
          Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
          state

        {:error, {:workflow_parse_error, reason}} ->
          Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
          state

        {:error, reason} ->
          Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
          %{state | skipped_issues: [], candidate_fetch_error: reason}
      end
    else
      %{
        state
        | skipped_issues: [],
          last_candidate_issues: [],
          candidate_fetch_error: {:runner_health, Map.get(runner, :runner_health_rule_id)}
      }
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          reconcile_running_issue_states(
            issues,
            state,
            active_state_set(),
            terminal_state_set()
          )

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
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
  def reconcile_stalled_running_issues_for_test(%State{} = state) do
    reconcile_stalled_running_issues(state)
  end

  @doc false
  def stall_elapsed_ms_for_test(running_entry, now), do: stall_elapsed_ms(running_entry, now)

  @doc false
  def last_activity_timestamp_for_test(running_entry), do: last_activity_timestamp(running_entry)

  @doc false
  def terminate_task_for_test(pid), do: terminate_task(pid)

  @doc false
  def partition_issues_by_label_gate_for_test(issues, %State{} = state) do
    partition_issues_by_label_gate(issues, state)
  end

  @doc false
  def partition_issues_by_label_gate_for_test(issues, state) do
    partition_issues_by_label_gate(issues, state)
  end

  @doc false
  def skipped_issue_entry_for_test(issue, reason, state), do: skipped_issue_entry(issue, reason, state)

  @doc false
  def choose_issues_for_test(issues, %State{} = state), do: choose_issues(issues, state)

  @doc false
  def choose_issues_for_test(issues, %State{} = state, dispatch_fun) when is_function(dispatch_fun, 2) do
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
  def state_slots_available_for_test(issue, running), do: state_slots_available?(issue, running)

  @doc false
  def running_issue_count_for_state_for_test(running, issue_state),
    do: running_issue_count_for_state(running, issue_state)

  @doc false
  def issue_routable_to_worker_for_test(issue), do: issue_routable_to_worker?(issue)

  @doc false
  def issue_labels_for_test(issue), do: issue_labels(issue)

  @doc false
  def issue_matches_required_labels_for_test(issue), do: issue_matches_required_labels?(issue)

  @doc false
  def label_gate_status_for_test(issue), do: label_gate_status(issue)

  @doc false
  def terminal_issue_state_for_test(state_name, terminal_states),
    do: terminal_issue_state?(state_name, terminal_states)

  @doc false
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
  def revalidate_issue_passthrough_for_test(issue) do
    revalidate_issue_for_dispatch(issue, fn _issue_ids -> :unused end, terminal_state_set())
  end

  @doc false
  def dispatch_issue_for_test(state, issue), do: dispatch_issue_for_test(state, issue, [])

  @doc false
  def dispatch_issue_default_for_test(%State{} = state, %Issue{} = issue, attempt \\ nil) do
    dispatch_issue(state, issue, attempt)
  end

  @doc false
  def dispatch_issue_private_head_for_test(%State{} = state, issue, attempt) do
    dispatch_issue(state, issue, attempt)
  end

  @doc false
  def dispatch_issue_private_head_for_test(%State{} = state, issue) do
    dispatch_issue(state, issue)
  end

  def dispatch_issue_for_test(%State{} = state, %Issue{} = issue, []) do
    dispatch_issue(state, issue, nil)
  end

  def dispatch_issue_for_test(%State{} = state, %Issue{} = issue, opts) when is_list(opts) do
    attempt = Keyword.get(opts, :attempt)
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    dispatch_fun = Keyword.get(opts, :dispatch_fun, &do_dispatch_issue/3)

    dispatch_issue(state, issue, attempt, issue_fetcher, dispatch_fun)
  end

  @doc false
  def do_dispatch_issue_for_test(%State{} = state, %Issue{} = issue, attempt \\ nil) do
    do_dispatch_issue(state, issue, attempt)
  end

  @doc false
  def do_dispatch_issue_for_test(%State{} = state, %Issue{} = issue, attempt, opts)
      when is_list(opts) do
    acquire_fun = Keyword.get(opts, :acquire_fun, &LeaseManager.acquire/3)
    spawn_fun = Keyword.get(opts, :spawn_fun, &do_spawn_issue_worker/4)

    do_dispatch_issue(state, issue, attempt, acquire_fun, spawn_fun)
  end

  @doc false
  def do_spawn_issue_worker_for_test(%State{} = state, %Issue{} = issue, attempt, recipient, opts \\ [])
      when is_list(opts) do
    start_child_fun = Keyword.get(opts, :start_child_fun, &Task.Supervisor.start_child/2)
    do_spawn_issue_worker(state, issue, attempt, recipient, start_child_fun)
  end

  @doc false
  def do_spawn_issue_worker_default_for_test(%State{} = state, %Issue{} = issue, attempt, recipient) do
    do_spawn_issue_worker(state, issue, attempt, recipient)
  end

  @doc false
  def schedule_issue_retry_for_test(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    schedule_issue_retry(state, issue_id, attempt, metadata)
  end

  @doc false
  def handle_retry_issue_for_test(%State{} = state, issue_id, attempt, metadata, issues_result) do
    handle_retry_issue(state, issue_id, attempt, metadata, fn -> issues_result end)
  end

  @doc false
  def handle_retry_issue_lookup_for_test(issue, %State{} = state, issue_id, attempt, metadata) do
    handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
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

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      match?({:error, _}, resolve_policy(issue, state)) ->
        Logger.info("Issue has conflicting policy labels: #{issue_context(issue)} labels=#{inspect(Issue.label_names(issue))}; moving issue to #{@blocked_state}")
        block_issue_for_policy_conflict(state, issue)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      !issue_matches_required_labels?(issue) ->
        Logger.info("Issue no longer matches the configured label gate: #{issue_context(issue)} labels=#{inspect(Issue.label_names(issue))}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        state =
          %{
            state
            | running: Map.delete(state.running, issue_id),
              claimed: MapSet.delete(state.claimed, issue_id),
              retry_attempts: Map.delete(state.retry_attempts, issue_id)
          }

        release_issue_claim(state, issue_id)

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.codex_stall_timeout_ms()

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
        error: "stalled for #{elapsed_ms}ms without codex activity"
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
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp partition_issues_by_label_gate(issues, %State{} = state) when is_list(issues) do
    Enum.reduce(issues, {[], []}, fn issue, {eligible, skipped} ->
      case dispatch_skip_reason(issue, state) do
        nil -> {[issue | eligible], skipped}
        reason -> {eligible, [skipped_issue_entry(issue, reason, state) | skipped]}
      end
    end)
    |> then(fn {eligible, skipped} ->
      {Enum.reverse(eligible), Enum.reverse(skipped)}
    end)
  end

  defp partition_issues_by_label_gate(_issues, _state), do: {[], []}

  defp skipped_issue_entry(%Issue{} = issue, reason, %State{} = state) do
    workspace_path = Path.join(Config.workspace_root(), issue.identifier || issue.id || "issue")
    run_state = load_run_state(workspace_path)
    {policy_class, policy_source, policy_override} = policy_snapshot_values(issue, state, run_state)

    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      state: issue.state,
      labels: Issue.label_names(issue),
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
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !issue_paused?(state, issue) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
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
      issue_matches_required_labels?(issue) and
      match?({:ok, _}, resolve_policy(issue, %State{})) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  defp issue_labels(_issue), do: []

  defp issue_matches_required_labels?(%Issue{} = issue) do
    label_gate_status(issue).eligible?
  end

  defp issue_matches_required_labels?(_issue), do: true

  defp label_gate_status(%Issue{} = issue) do
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

  defp label_gate_status(_issue),
    do: %{eligible?: true, required_labels: routing_required_labels(), reason: nil}

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.linear_terminal_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.linear_active_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
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
    dispatch_issue(state, issue, nil)
  end

  defp dispatch_issue(%State{} = state, issue, attempt) do
    dispatch_issue(state, issue, attempt, &Tracker.fetch_issue_states_by_ids/1, &do_dispatch_issue/3)
  end

  defp dispatch_issue(%State{} = state, issue, attempt, issue_fetcher, dispatch_fun)
       when is_function(issue_fetcher, 1) and is_function(dispatch_fun, 3) do
    case revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        dispatch_fun.(state, refreshed_issue, attempt)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt) do
    do_dispatch_issue(state, issue, attempt, &LeaseManager.acquire/3, &do_spawn_issue_worker/4)
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, acquire_fun, spawn_fun)
       when is_function(acquire_fun, 3) and is_function(spawn_fun, 4) do
    recipient = self()

    case acquire_fun.(issue.id, issue.identifier, state.lease_owner) do
      :ok ->
        RunLedger.record("lease.acquired", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "system",
          actor_id: state.lease_owner,
          summary: "Lease acquired for dispatch.",
          metadata: %{attempt: attempt}
        })

        spawn_fun.(state, issue, attempt, recipient)

      {:error, :claimed} ->
        Logger.info("Skipping dispatch; lease already held for #{issue_context(issue)}")
        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; failed to acquire lease for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_spawn_issue_worker(%State{} = state, issue, attempt, recipient) do
    do_spawn_issue_worker(state, issue, attempt, recipient, &Task.Supervisor.start_child/2)
  end

  defp do_spawn_issue_worker(%State{} = state, issue, attempt, recipient, start_child_fun)
       when is_function(start_child_fun, 2) do
    policy_override = Map.get(state.policy_overrides, issue.identifier)

    case start_child_fun.(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, policy_override: policy_override)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {policy_class, policy_source, _policy_override} = policy_snapshot_values(issue, state)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

        ledger_event =
          RunLedger.record("dispatch.started", %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            actor_type: "runtime",
            actor_id: state.lease_owner,
            policy_class: policy_class,
            summary: "Dispatching issue to an agent worker.",
            details: "Attempt #{inspect(attempt || 1)}.",
            metadata: %{
              policy_source: policy_source,
              retry_attempt: normalize_retry_attempt(attempt)
            }
          })

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_started_input_tokens: 0,
            turn_count: 0,
            recent_codex_updates: [],
            retry_attempt: normalize_retry_attempt(attempt),
            policy_override: policy_override,
            policy_class: policy_class,
            policy_source: policy_source,
            last_ledger_event_id: Map.get(ledger_event, :event_id),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        LeaseManager.release(issue.id, state.lease_owner)
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}"
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    handle_retry_issue(state, issue_id, attempt, metadata, &Tracker.fetch_candidate_issues/0)
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata, candidate_issue_fetcher)
       when is_function(candidate_issue_fetcher, 0) do
    case candidate_issue_fetcher.() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier)
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.linear_terminal_states()) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) do
      {:noreply, dispatch_issue(state, issue, attempt)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

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
    LeaseManager.release(issue_id, state.lease_owner)
    RunLedger.record("lease.released", %{
      issue_id: issue_id,
      actor_type: "system",
      actor_id: state.lease_owner,
      summary: "Lease released."
    })
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
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

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(state.running),
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

  @spec reprioritize_issue(String.t(), integer() | nil) :: map() | :unavailable
  def reprioritize_issue(issue_identifier, override_rank) do
    reprioritize_issue(__MODULE__, issue_identifier, override_rank)
  end

  @spec reprioritize_issue(GenServer.server(), String.t(), integer() | nil) :: map() | :unavailable
  def reprioritize_issue(server, issue_identifier, override_rank) do
    call_if_available(server, {:reprioritize_issue, issue_identifier, override_rank})
  end

  @spec approve_issue_for_merge(String.t()) :: map() | :unavailable
  def approve_issue_for_merge(issue_identifier), do: approve_issue_for_merge(__MODULE__, issue_identifier)

  @spec approve_issue_for_merge(GenServer.server(), String.t()) :: map() | :unavailable
  def approve_issue_for_merge(server, issue_identifier) do
    call_if_available(server, {:approve_issue_for_merge, issue_identifier})
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
    if Process.whereis(server) do
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
    if Process.whereis(server) do
      GenServer.call(server, message)
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running = Enum.map(state.running, fn {issue_id, metadata} -> running_snapshot_entry(issue_id, metadata, now, state) end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        identifier = Map.get(retry, :identifier)
        run_state = retry_run_state(identifier)

        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: identifier,
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
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       runner: RunnerRuntime.info(),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?

    unless coalesced do
      :ok = schedule_tick(0)
    end

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:pause_issue, issue_identifier}, _from, state) do
    {reply, state} = pause_issue_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:resume_issue, issue_identifier}, _from, state) do
    {reply, state} = resume_issue_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:stop_issue, issue_identifier}, _from, state) do
    {reply, state} = stop_issue_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:hold_issue_for_human_review, issue_identifier}, _from, state) do
    {reply, state} = hold_issue_for_human_review_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:retry_issue_now, issue_identifier}, _from, state) do
    {reply, state} = retry_issue_now_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:reprioritize_issue, issue_identifier, override_rank}, _from, state) do
    {reply, state} = reprioritize_issue_runtime(state, issue_identifier, override_rank)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:approve_issue_for_merge, issue_identifier}, _from, state) do
    {reply, state} = approve_issue_for_merge_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:set_policy_class, issue_identifier, policy_class}, _from, state) do
    {reply, state} = set_policy_class_runtime(state, issue_identifier, policy_class)
    notify_dashboard()
    {:reply, reply, state}
  end

  def handle_call({:clear_policy_override, issue_identifier}, _from, state) do
    {reply, state} = clear_policy_override_runtime(state, issue_identifier)
    notify_dashboard()
    {:reply, reply, state}
  end

  # credo:disable-for-next-line
  defp running_snapshot_entry(issue_id, metadata, now, state) do
    workspace_path = Path.join(Config.workspace_root(), metadata.identifier || issue_id)
    inspection = RunInspector.inspect(workspace_path)
    run_state = load_run_state(workspace_path)
    {policy_class, policy_source, policy_override} = policy_snapshot_values(metadata.issue, state, run_state)

    %{
      issue_id: issue_id,
      identifier: metadata.identifier,
      state: metadata.issue.state,
      session_id: metadata.session_id,
      codex_app_server_pid: metadata.codex_app_server_pid,
      codex_input_tokens: metadata.codex_input_tokens,
      codex_output_tokens: metadata.codex_output_tokens,
      codex_total_tokens: metadata.codex_total_tokens,
      turn_count: Map.get(metadata, :turn_count, 0),
      started_at: metadata.started_at,
      last_codex_timestamp: metadata.last_codex_timestamp,
      last_codex_message: metadata.last_codex_message,
      last_codex_event: metadata.last_codex_event,
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
      last_post_merge: Map.get(run_state, :last_post_merge),
      base_branch: Map.get(run_state, :base_branch) || (inspection.harness && inspection.harness.base_branch),
      run_state_pr_url: Map.get(run_state, :pr_url),
      merge_sha: Map.get(run_state, :merge_sha),
      stop_reason: Map.get(run_state, :stop_reason),
      last_decision: Map.get(run_state, :last_decision),
      last_rule_id: Map.get(run_state, :last_rule_id),
      last_failure_class: Map.get(run_state, :last_failure_class),
      last_decision_summary: Map.get(run_state, :last_decision_summary),
      next_human_action: Map.get(run_state, :next_human_action),
      last_ledger_event_id: Map.get(run_state, :last_ledger_event_id),
      lease_owner: stateful_lease_owner(issue_id),
      current_turn_input_tokens:
        max(
          0,
          Map.get(metadata, :codex_input_tokens, 0) -
            Map.get(metadata, :turn_started_input_tokens, 0)
        ),
      recent_codex_updates: Map.get(metadata, :recent_codex_updates, [])
    }
  end

  defp paused_snapshot_entries(paused_issue_states) when is_map(paused_issue_states) do
    paused_issue_states
    |> Enum.map(fn {issue_id, paused_entry} ->
      %{
        issue_id: issue_id,
        identifier: Map.get(paused_entry, :identifier),
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

  defp skipped_snapshot_entries(skipped_issues) when is_list(skipped_issues) do
    Enum.map(skipped_issues, fn entry ->
      %{
        issue_id: Map.get(entry, :issue_id),
        issue_identifier: Map.get(entry, :issue_identifier),
        state: Map.get(entry, :state),
        labels: Map.get(entry, :labels, []),
        required_labels: Map.get(entry, :required_labels, []),
        reason: Map.get(entry, :reason, "label_gate"),
        policy_class: Map.get(entry, :policy_class),
        policy_source: Map.get(entry, :policy_source),
        policy_override: Map.get(entry, :policy_override),
        next_human_action: Map.get(entry, :next_human_action),
        last_rule_id: Map.get(entry, :last_rule_id),
        last_failure_class: Map.get(entry, :last_failure_class)
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
        workspace_path = Path.join(Config.workspace_root(), entry.identifier || entry.issue_id || "issue")
        run_state = load_run_state(workspace_path)
        {policy_class, policy_source, policy_override} = policy_snapshot_values(entry.issue, state, run_state)
        {last_rule_id, last_failure_class, last_decision_summary, next_human_action} =
          queue_policy_reason(entry.issue, state, run_state)

        %{
          issue_id: entry.issue_id,
          issue_identifier: entry.identifier,
          state: entry.issue.state,
          linear_priority: entry.issue.priority,
          operator_override: entry.reasons.operator_override,
          retry_penalty: entry.reasons.retry_penalty,
          rank: entry.rank,
          labels: Issue.label_names(entry.issue),
          required_labels: routing_required_labels(),
          label_gate_eligible: issue_matches_required_labels?(entry.issue),
          policy_class: policy_class,
          policy_source: policy_source,
          policy_override: policy_override,
          next_human_action: next_human_action,
          last_rule_id: last_rule_id,
          last_failure_class: last_failure_class,
          last_decision_summary: last_decision_summary,
          last_ledger_event_id: Map.get(run_state, :last_ledger_event_id)
        }
      end)

    case {queue_entries, Map.get(state, :candidate_fetch_error)} do
      {[], reason} when not is_nil(reason) -> [%{error: inspect(reason)}]
      _ -> queue_entries
    end
  end

  defp pause_issue_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         :ok <- maybe_update_issue_state(issue.id, issue.state, @paused_state) do
      {policy_class, policy_source, policy_override} = policy_snapshot_values(issue, state)

      state =
        state
        |> terminate_running_issue(issue.id, false)
        |> cancel_retry(issue.id)
        |> put_paused_issue(issue)

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          policy_class: policy_class,
          summary: "Paused issue from dashboard.",
          target_state: @paused_state,
          metadata: %{action: "pause", policy_source: policy_source, policy_override: policy_override}
        })

      state =
        put_paused_policy_metadata(state, issue.id, %{
          policy_class: policy_class,
          policy_source: policy_source,
          policy_override: policy_override,
          next_human_action: "Resume the issue when it should re-enter active work.",
          last_ledger_event_id: Map.get(ledger_event, :event_id)
        })

      {%{ok: true, action: "pause", issue_identifier: issue.identifier, state: @paused_state, policy_class: policy_class, policy_source: policy_source, ledger_event_id: Map.get(ledger_event, :event_id)}, state}
    else
      {:error, reason} ->
        {%{ok: false, action: "pause", issue_identifier: issue_identifier, error: inspect(reason)}, state}
    end
  end

  defp resume_issue_runtime(%State{} = state, issue_identifier) do
    with {:ok, issue_id, identifier, resume_state} <- paused_issue_entry(state, issue_identifier),
         :ok <- Tracker.update_issue_state(issue_id, resume_state) do
      state = %{state | paused_issue_states: Map.delete(state.paused_issue_states, issue_id)}
      :ok = schedule_tick(0)
      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue_id,
          issue_identifier: identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          summary: "Resumed paused issue.",
          target_state: resume_state,
          metadata: %{action: "resume", resume_state: resume_state}
        })

      {%{ok: true, action: "resume", issue_identifier: identifier, state: resume_state, ledger_event_id: Map.get(ledger_event, :event_id)}, state}
    else
      {:error, reason} ->
        {%{ok: false, action: "resume", issue_identifier: issue_identifier, error: inspect(reason)}, state}
    end
  end

  defp stop_issue_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         :ok <- Tracker.create_comment(issue.id, "## Symphony operator stop\n\nRule ID: operator.stop\n\nFailure class: policy\n\nStopped by dashboard control.\n\nUnblock action: Move the issue back to an active state when it should run again."),
         :ok <- Tracker.update_issue_state(issue.id, @blocked_state) do
      {policy_class, policy_source, _policy_override} = policy_snapshot_values(issue, state)

      state =
        state
        |> terminate_running_issue(issue.id, false)
        |> cancel_retry(issue.id)
        |> clear_paused_issue(issue.id)

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          policy_class: policy_class,
          failure_class: "policy",
          rule_id: "operator.stop",
          summary: "Stopped issue from dashboard.",
          details: "Moved issue to #{@blocked_state}.",
          target_state: @blocked_state,
          metadata: %{action: "stop", policy_source: policy_source}
        })

      {%{ok: true, action: "stop", issue_identifier: issue.identifier, state: @blocked_state, policy_class: policy_class, policy_source: policy_source, ledger_event_id: Map.get(ledger_event, :event_id)}, state}
    else
      {:error, reason} ->
        {%{ok: false, action: "stop", issue_identifier: issue_identifier, error: inspect(reason)}, state}
    end
  end

  defp hold_issue_for_human_review_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         :ok <- Tracker.update_issue_state(issue.id, @human_review_state) do
      {policy_class, policy_source, _policy_override} = policy_snapshot_values(issue, state)

      state =
        state
        |> terminate_running_issue(issue.id, false)
        |> cancel_retry(issue.id)
        |> clear_paused_issue(issue.id)

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          policy_class: policy_class,
          failure_class: "policy",
          rule_id: "operator.hold_for_human_review",
          summary: "Placed issue in Human Review.",
          details: "Operator requested a manual review hold.",
          target_state: @human_review_state,
          metadata: %{action: "hold_for_human_review", policy_source: policy_source}
        })

      {%{ok: true, action: "hold_for_human_review", issue_identifier: issue.identifier, state: @human_review_state, policy_class: policy_class, policy_source: policy_source, ledger_event_id: Map.get(ledger_event, :event_id)}, state}
    else
      {:error, reason} ->
        {%{ok: false, action: "hold_for_human_review", issue_identifier: issue_identifier, error: inspect(reason)}, state}
    end
  end

  defp retry_issue_now_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         false <- issue_paused?(state, issue) do
      state = cancel_retry(state, issue.id)

      state =
        cond do
          Map.has_key?(state.running, issue.id) ->
            state

          retry_candidate_issue?(issue, terminal_state_set()) and dispatch_slots_available?(issue, state) ->
            dispatch_issue(state, issue, 1)

          true ->
            :ok = schedule_tick(0)
            state
        end

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          summary: "Requested immediate retry.",
          metadata: %{action: "retry_now"}
        })

      {%{ok: true, action: "retry_now", issue_identifier: issue.identifier, ledger_event_id: Map.get(ledger_event, :event_id)}, state}
    else
      true ->
        {%{ok: false, action: "retry_now", issue_identifier: issue_identifier, error: "issue is paused"}, state}

      {:error, reason} ->
        {%{ok: false, action: "retry_now", issue_identifier: issue_identifier, error: inspect(reason)}, state}
    end
  end

  defp reprioritize_issue_runtime(%State{} = state, issue_identifier, override_rank) do
    identifier = issue_identifier |> to_string() |> String.trim()

    if identifier == "" do
      {%{ok: false, action: "reprioritize", issue_identifier: issue_identifier, error: "blank issue identifier"}, state}
    else
      priority_overrides =
        case override_rank do
          nil ->
            Map.delete(state.priority_overrides, identifier)

          value when is_integer(value) ->
            Map.put(state.priority_overrides, identifier, value)

          _ ->
            state.priority_overrides
        end

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_identifier: identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          summary: "Updated queue priority override.",
          metadata: %{action: "reprioritize", override_rank: override_rank}
        })

      {
        %{
          ok: true,
          action: "reprioritize",
          issue_identifier: identifier,
          override_rank: override_rank,
          ledger_event_id: Map.get(ledger_event, :event_id)
        },
        %{state | priority_overrides: priority_overrides}
      }
    end
  end

  defp approve_issue_for_merge_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         {policy_class, policy_source, _policy_override} <- policy_snapshot_values(issue, state),
         false <- policy_class == "never_automerge",
         :ok <- Tracker.update_issue_state(issue.id, @merging_state) do
      :ok = schedule_tick(0)
      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          policy_class: policy_class,
          summary: "Approved issue for merge.",
          target_state: @merging_state,
          metadata: %{action: "approve_for_merge", policy_source: policy_source}
        })

      {%{ok: true, action: "approve_for_merge", issue_identifier: issue.identifier, state: @merging_state, policy_class: policy_class, policy_source: policy_source, ledger_event_id: Map.get(ledger_event, :event_id)}, state}
    else
      true ->
        {%{ok: false, action: "approve_for_merge", issue_identifier: issue_identifier, error: "policy forbids automerge"}, state}

      {:error, reason} ->
        {%{ok: false, action: "approve_for_merge", issue_identifier: issue_identifier, error: inspect(reason)}, state}
    end
  end

  defp set_policy_class_runtime(%State{} = state, issue_identifier, policy_class) do
    identifier = issue_identifier |> to_string() |> String.trim()

    with false <- identifier == "",
         policy_atom when not is_nil(policy_atom) <- IssuePolicy.normalize_class(policy_class) do
      policy_string = IssuePolicy.class_to_string(policy_atom)
      state = %{state | policy_overrides: Map.put(state.policy_overrides, identifier, policy_string)}
      persist_policy_override_for_identifier(identifier, policy_string)

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_identifier: identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          policy_class: policy_string,
          summary: "Set policy override for issue.",
          metadata: %{action: "set_policy_class", policy_source: "override"}
        })

      {%{ok: true, action: "set_policy_class", issue_identifier: identifier, policy_class: policy_string, policy_source: "override", ledger_event_id: Map.get(ledger_event, :event_id)}, state}
    else
      true ->
        {%{ok: false, action: "set_policy_class", issue_identifier: issue_identifier, error: "blank issue identifier"}, state}

      nil ->
        {%{ok: false, action: "set_policy_class", issue_identifier: issue_identifier, error: "invalid policy class"}, state}
    end
  end

  defp clear_policy_override_runtime(%State{} = state, issue_identifier) do
    identifier = issue_identifier |> to_string() |> String.trim()

    if identifier == "" do
      {%{ok: false, action: "clear_policy_override", issue_identifier: issue_identifier, error: "blank issue identifier"}, state}
    else
      state = %{state | policy_overrides: Map.delete(state.policy_overrides, identifier)}
      persist_policy_override_for_identifier(identifier, nil)

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_identifier: identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          summary: "Cleared policy override for issue.",
          metadata: %{action: "clear_policy_override"}
        })

      {%{ok: true, action: "clear_policy_override", issue_identifier: identifier, policy_class: nil, policy_source: "label_or_default", ledger_event_id: Map.get(ledger_event, :event_id)}, state}
    end
  end

  defp maybe_promote_review_ready_issues(%State{} = state) do
    case Tracker.fetch_issues_by_states([@human_review_state]) do
      {:ok, issues} ->
        Enum.reduce(issues, state, fn
          %Issue{} = issue, state_acc ->
            maybe_promote_review_ready_issue(state_acc, issue)

          _issue, state_acc ->
            state_acc
        end)

      {:error, _reason} ->
        state
    end
  end

  defp maybe_promote_review_ready_issue(%State{} = state, %Issue{} = issue) do
    workspace = Path.join(Config.workspace_root(), issue.identifier || issue.id || "issue")
    inspection = RunInspector.inspect(workspace)

    case resolve_policy(issue, state) do
      {:ok, %{class: :fully_autonomous}} ->
        if issue_routable_to_worker?(issue) and issue_matches_required_labels?(issue) and
             RunInspector.ready_for_merge?(inspection) do
          case Tracker.update_issue_state(issue.id, @merging_state) do
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
              Logger.warning("Failed to auto-promote #{issue_context(issue)} to #{@merging_state}: #{inspect(reason)}")
          end

          state
        else
          state
        end

      _ ->
        state
    end
  end

  defp resolve_issue_for_control(%State{} = state, issue_identifier) when is_binary(issue_identifier) do
    issue_identifier = String.trim(issue_identifier)

    cond do
      issue_identifier == "" ->
        {:error, :blank_issue_identifier}

      issue = find_running_issue_by_identifier(state, issue_identifier) ->
        {:ok, issue}

      true ->
        case Tracker.fetch_issue_by_identifier(issue_identifier) do
          {:ok, %Issue{} = issue} -> {:ok, issue}
          {:ok, nil} -> {:error, :issue_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp resolve_issue_for_control(_state, _issue_identifier), do: {:error, :blank_issue_identifier}

  defp find_running_issue_by_identifier(%State{} = state, issue_identifier) do
    Enum.find_value(state.running, fn
      {_issue_id, %{identifier: ^issue_identifier, issue: %Issue{} = issue}} -> issue
      _ -> nil
    end)
  end

  defp paused_issue_entry(%State{} = state, issue_identifier) when is_binary(issue_identifier) do
    issue_identifier = String.trim(issue_identifier)

    case Enum.find(state.paused_issue_states, fn {_issue_id, paused_entry} ->
           Map.get(paused_entry, :identifier) == issue_identifier
         end) do
      {issue_id, paused_entry} ->
        {:ok, issue_id, Map.get(paused_entry, :identifier) || issue_identifier, Map.get(paused_entry, :resume_state) || "Todo"}

      nil ->
        {:error, :issue_not_paused}
    end
  end

  defp paused_issue_entry(_state, _issue_identifier), do: {:error, :blank_issue_identifier}

  defp maybe_update_issue_state(issue_id, current_state, target_state)
       when is_binary(issue_id) and is_binary(target_state) do
    if normalize_issue_state(current_state || "") == normalize_issue_state(target_state) do
      :ok
    else
      Tracker.update_issue_state(issue_id, target_state)
    end
  end

  defp put_paused_issue(%State{} = state, %Issue{} = issue) do
    paused_entry = %{
      identifier: issue.identifier,
      resume_state: pause_resume_state(issue.state)
    }

    %{state | paused_issue_states: Map.put(state.paused_issue_states, issue.id, paused_entry)}
  end

  defp clear_paused_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | paused_issue_states: Map.delete(state.paused_issue_states, issue_id)}
  end

  defp cancel_retry(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)
        %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}

      _ ->
        %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
    end
  end

  defp issue_paused?(%State{} = state, %Issue{id: issue_id}) when is_binary(issue_id) do
    Map.has_key?(state.paused_issue_states, issue_id)
  end

  defp issue_paused?(_state, _issue), do: false

  defp pause_resume_state(state_name) when is_binary(state_name) do
    normalized = normalize_issue_state(state_name)

    case normalized do
      "paused" -> "Todo"
      "blocked" -> "Todo"
      _ -> state_name
    end
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_started_input_tokens:
          turn_started_input_for_update(
            Map.get(running_entry, :turn_started_input_tokens, 0),
            codex_input_tokens + token_delta.input_tokens,
            running_entry.session_id,
            update
          ),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        recent_codex_updates:
          append_recent_codex_update(
            Map.get(running_entry, :recent_codex_updates, []),
            summarize_codex_update(update)
          )
      }),
      token_delta
    }
  end

  defp append_recent_codex_update(existing, summarized_update) when is_list(existing) do
    (existing ++ [summarized_update])
    |> Enum.take(-12)
  end

  defp append_recent_codex_update(_existing, summarized_update), do: [summarized_update]

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

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

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(delay_ms) do
    :timer.send_after(delay_ms, self(), :tick)
    :ok
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    state =
      Enum.reduce(Map.keys(state.running), state, fn issue_id, state_acc ->
        case LeaseManager.refresh(issue_id, state.lease_owner) do
          :ok ->
            state_acc

          {:error, :claimed} ->
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
            Logger.warning("Lease refresh failed for issue_id=#{issue_id}: #{inspect(reason)}")
            state_acc
        end
      end)

    %{
      state
      | poll_interval_ms: Config.poll_interval_ms(),
        max_concurrent_agents: Config.max_concurrent_agents()
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp maybe_stop_issue_for_token_budget(%State{} = state, issue_id, running_entry) do
    issue = Map.get(running_entry, :issue, %{})

    case RunPolicy.maybe_stop_for_token_budget(issue, running_entry) do
      :ok ->
        state

      {:stop, _violation} ->
        terminate_running_issue(state, issue_id, false)
    end
  end

  defp load_run_state(workspace_path) when is_binary(workspace_path) do
    case RunStateStore.load(workspace_path) do
      {:ok, run_state} -> run_state
      _ -> %{}
    end
  end

  defp retry_run_state(identifier) when is_binary(identifier) and identifier != "" do
    identifier
    |> then(&Path.join(Config.workspace_root(), &1))
    |> load_run_state()
  end

  defp retry_run_state(_identifier), do: %{}

  defp resolve_policy(%Issue{} = issue, %State{} = state) do
    IssuePolicy.resolve(issue,
      override: Map.get(state.policy_overrides, issue.identifier),
      default: Config.policy_default_issue_class()
    )
  end

  defp policy_snapshot_values(issue, state, run_state \\ %{})

  defp policy_snapshot_values(%Issue{} = issue, %State{} = state, run_state) when is_map(run_state) do
    override = Map.get(run_state, :policy_override) || Map.get(state.policy_overrides, issue.identifier)

    case IssuePolicy.resolve(issue,
           override: override,
           default: Config.policy_default_issue_class()
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

  defp policy_snapshot_values(_issue, _state, _run_state), do: {nil, nil, nil}

  defp dispatch_skip_reason(%Issue{} = issue, %State{} = state) do
    label_gate = label_gate_status(issue)

    cond do
      match?(%{eligible?: false}, label_gate) ->
        label_gate.reason

      match?({:error, _}, resolve_policy(issue, state)) ->
        RuleCatalog.rule_id(:policy_invalid_labels)

      true ->
        nil
    end
  end

  defp queue_policy_reason(%Issue{} = issue, %State{} = state, run_state) do
    last_decision = Map.get(run_state, :last_decision, %{})

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

  defp next_human_action_for_skip("missing required labels"),
    do: "Add the required routing labels before Symphony can dispatch this issue."

  defp next_human_action_for_skip("missing canary labels"),
    do: "Add the canary routing labels before Symphony can dispatch this issue during canary mode."

  defp next_human_action_for_skip(reason) when is_binary(reason) do
    cond do
      reason == RuleCatalog.rule_id(:policy_invalid_labels) ->
        RuleCatalog.human_action(:policy_invalid_labels)

      true ->
        nil
    end
  end

  defp next_human_action_for_skip(_reason), do: nil

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
    rule = RuleCatalog.rule(:policy_invalid_labels)
    workspace = Path.join(Config.workspace_root(), issue.identifier || issue.id || "issue")
    labels = IssuePolicy.policy_labels(issue)

    ledger_event =
      RunLedger.record("runtime.stopped", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        actor_type: "runtime",
        actor_id: "orchestrator",
        failure_class: rule.failure_class,
        rule_id: rule.rule_id,
        summary: "Conflicting policy labels detected on the issue.",
        details: Enum.join(labels, ", "),
        target_state: @blocked_state,
        metadata: %{human_action: rule.human_action}
      })

    _ =
      RunStateStore.transition(workspace, "blocked", %{
        stop_reason: %{
          code: "policy_invalid_labels",
          rule_id: rule.rule_id,
          failure_class: rule.failure_class,
          details: Enum.join(labels, ", ")
        },
        last_decision: %{
          rule_id: rule.rule_id,
          failure_class: rule.failure_class,
          summary: "Conflicting policy labels detected on the issue.",
          details: Enum.join(labels, ", "),
          human_action: rule.human_action,
          target_state: @blocked_state,
          ledger_event_id: Map.get(ledger_event, :event_id)
        },
        last_rule_id: rule.rule_id,
        last_failure_class: rule.failure_class,
        last_decision_summary: "Conflicting policy labels detected on the issue.",
        next_human_action: rule.human_action
      })

    _ =
      Tracker.create_comment(
        issue.id,
        """
        ## Symphony policy stop

        Issue: #{issue.identifier}
        Rule ID: #{rule.rule_id}
        Failure class: #{rule.failure_class}

        Conflicting policy labels: #{Enum.join(labels, ", ")}

        Unblock action: #{rule.human_action}
        """
        |> String.trim()
      )

    _ = Tracker.update_issue_state(issue.id, @blocked_state)
    terminate_running_issue(state, issue.id, false)
  end

  defp persist_policy_override_for_identifier(identifier, override) when is_binary(identifier) do
    workspace = Path.join(Config.workspace_root(), identifier)

    if File.exists?(workspace) do
      _ =
        RunStateStore.update(workspace, fn state ->
          Map.put(state, :policy_override, override)
        end)
    end

    :ok
  end

  defp put_paused_policy_metadata(%State{} = state, issue_id, attrs) do
    paused_entry =
      state.paused_issue_states
      |> Map.get(issue_id, %{})
      |> Map.merge(attrs)

    %{state | paused_issue_states: Map.put(state.paused_issue_states, issue_id, paused_entry)}
  end

  defp stateful_lease_owner(issue_id) when is_binary(issue_id) do
    case LeaseManager.read(issue_id) do
      {:ok, %{"owner" => owner}} -> owner
      _ -> nil
    end
  end

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

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
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
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
end
