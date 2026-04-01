defmodule SymphonyElixir.Orchestrator.Snapshot do
  @moduledoc """
  Builds the read-only snapshot returned by the orchestrator :snapshot call.

  Every public function here is a pure data builder — it reads workspace state,
  run-state files, lease details, and policy resolution, then returns plain maps
  whose shape defines the `/api/v1/state` contract.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.PriorityEngine
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunnerRuntime
  alias SymphonyElixir.RunPolicy
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.Workspace

  # -------------------------------------------------------------------
  # Public snapshot builders
  # -------------------------------------------------------------------

  # credo:disable-for-next-line
  def running_snapshot_entry(issue_id, metadata, now, state) do
    workspace_path = Workspace.path_for_issue(metadata.identifier || issue_id)
    inspection = RunInspector.inspect(workspace_path, include_pr_details: false)
    run_state = load_run_state(workspace_path, metadata.issue)
    lease = stateful_lease_details(issue_id, run_state, now)
    inspection = apply_persisted_review_state(inspection, run_state)

    {policy_class, policy_source, policy_override} =
      Orchestrator.policy_snapshot_values(metadata.issue, state, run_state)

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
      label_gate_eligible: Orchestrator.issue_matches_required_labels?(metadata.issue),
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

  def paused_snapshot_entries(paused_issue_states) when is_map(paused_issue_states) do
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

  def paused_snapshot_entries(_paused_issue_states), do: []

  def skipped_snapshot_entries(skipped_issues) when is_list(skipped_issues) do
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

  def skipped_snapshot_entries(_skipped_issues), do: []

  def queue_snapshot(%State{} = state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    {eligible_issues, _skipped_issues} =
      Orchestrator.partition_issues_by_label_gate(Map.get(state, :last_candidate_issues, []), state)

    queue_entries =
      eligible_issues
      |> Enum.filter(&Orchestrator.candidate_issue?(&1, active_states, terminal_states))
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

        {policy_class, policy_source, policy_override} =
          Orchestrator.policy_snapshot_values(entry.issue, state, run_state)

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
          target_runner_channel: Orchestrator.issue_target_runner_channel(entry.issue),
          required_labels: routing_required_labels(),
          label_gate_eligible: Orchestrator.issue_matches_required_labels?(entry.issue),
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

  # -------------------------------------------------------------------
  # Private helpers — snapshot-only
  # -------------------------------------------------------------------

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
    |> Map.put(
      :review_decision,
      Map.get(run_state, :last_review_decision) || inspection.review_decision
    )
    |> Map.put(:check_statuses, check_statuses)
    |> Map.put(
      :required_checks_state,
      Map.get(run_state, :last_required_checks_state) || inspection.required_checks_state
    )
    |> Map.put(
      :missing_required_checks,
      persisted_check_list(
        run_state,
        :last_missing_required_checks,
        inspection.missing_required_checks
      )
    )
    |> Map.put(
      :pending_required_checks,
      persisted_check_list(
        run_state,
        :last_pending_required_checks,
        inspection.pending_required_checks
      )
    )
    |> Map.put(
      :failing_required_checks,
      persisted_check_list(
        run_state,
        :last_failing_required_checks,
        inspection.failing_required_checks
      )
    )
    |> Map.put(
      :cancelled_required_checks,
      persisted_check_list(
        run_state,
        :last_cancelled_required_checks,
        inspection.cancelled_required_checks
      )
    )
  end

  defp apply_persisted_review_state(%RunInspector.Snapshot{} = inspection, _run_state),
    do: inspection

  defp persisted_check_list(run_state, key, fallback) when is_map(run_state) do
    case Map.get(run_state, key) do
      values when is_list(values) and values != [] -> values
      _ -> fallback
    end
  end

  defp queue_policy_reason(%Issue{} = issue, %State{} = state, run_state) do
    run_state = run_state || %{}

    last_decision =
      case Map.get(run_state, :last_decision) do
        %{} = decision -> decision
        _ -> %{}
      end

    case Orchestrator.resolve_policy(issue, state) do
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

  # -- lease helpers (stateful) --

  defp stateful_lease_details(issue_id, run_state)
       when is_binary(issue_id) and is_map(run_state) do
    stateful_lease_details(issue_id, run_state, DateTime.utc_now())
  end

  defp stateful_lease_details(issue_id, run_state, now)
       when is_binary(issue_id) and is_map(run_state) and is_struct(now, DateTime) do
    live_lease =
      case LeaseManager.read(issue_id) do
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
    reclaimable? = lease_reclaimable?(live_lease, lease_updated_at, ttl_ms, now)

    lease_source =
      cond do
        is_map(live_lease) -> "live"
        present?(lease_owner) -> "persisted"
        true -> "missing"
      end

    %{
      lease_owner: lease_owner,
      lease_owner_instance_id: Map.get(run_state, :lease_owner_instance_id),
      lease_owner_channel: Map.get(run_state, :lease_owner_channel),
      lease_acquired_at: lease_acquired_at,
      lease_updated_at: lease_updated_at,
      lease_status: lease_status_value(lease_owner, reclaimable?, Map.get(run_state, :lease_status)),
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

  defp lease_status_value(nil, _reclaimable?, _persisted_status), do: "missing"
  defp lease_status_value(_owner, true, _persisted_status), do: "reclaimable"

  defp lease_status_value(_owner, false, persisted_status)
       when is_binary(persisted_status) and persisted_status != "" do
    persisted_status
  end

  defp lease_status_value(_owner, false, _persisted_status), do: "held"

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

  # -- lease_*_from_entry helpers --

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

  # -- inlined trivial helpers --

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

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  defp issue_labels(_issue), do: []

  defp routing_required_labels do
    RunnerRuntime.effective_required_labels(Config.linear_required_labels())
  end

  defp issue_paused?(%State{} = state, %Issue{id: issue_id}) when is_binary(issue_id) do
    Map.has_key?(state.paused_issue_states, issue_id)
  end

  defp issue_paused?(_state, _issue), do: false

  defp active_state_set do
    Config.linear_active_states()
    |> Enum.map(&SymphonyElixir.Util.normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
    |> MapSet.put(SymphonyElixir.Util.normalize_state("Merging"))
  end

  defp terminal_state_set do
    Config.linear_terminal_states()
    |> Enum.map(&SymphonyElixir.Util.normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(value), do: value not in [nil, ""]
end
