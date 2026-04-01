defmodule SymphonyElixir.Orchestrator.Controls do
  @moduledoc """
  Operator control API implementations extracted from the orchestrator.

  Each function takes the orchestrator `%State{}` (and control-specific args)
  and returns `{reply, updated_state}`.  The orchestrator's `handle_call`
  clauses delegate here and handle `notify_dashboard/0` themselves.
  """

  require Logger

  alias SymphonyElixir.BehavioralProof
  alias SymphonyElixir.Config
  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.IssueSource
  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ManualIssueStore
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.PRWatcher
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.WorkflowProfile
  alias SymphonyElixir.Workspace

  @paused_state "Paused"
  @blocked_state "Blocked"
  @merging_state "Merging"

  # -------------------------------------------------------------------
  # Runtime control functions (public API for orchestrator delegation)
  # -------------------------------------------------------------------

  def submit_manual_issue_runtime(%State{} = state, spec) when is_map(spec) do
    case ManualIssueStore.submit(spec) do
      {:ok, %Issue{} = issue} ->
        ledger_event =
          RunLedger.record("dispatch.started", %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            actor_type: "system",
            actor_id: "manual_submit",
            summary: "Accepted manual issue submission.",
            metadata: %{source: "manual"}
          })

        next_state =
          state
          |> Orchestrator.refresh_runtime_config()
          |> Map.update!(:last_candidate_issues, &upsert_candidate_issue(&1, issue))
          |> Map.put(:candidate_fetch_error, nil)
          |> Map.put(
            :issue_routing_cache,
            Orchestrator.remember_issue_cache_entry(state.issue_routing_cache, issue)
          )
          |> maybe_schedule_manual_issue_refresh()

        {%{
           ok: true,
           accepted: true,
           source: "manual",
           issue_id: issue.id,
           issue_identifier: issue.identifier,
           state: issue.state,
           ledger_event_id: Map.get(ledger_event, :event_id)
         }, next_state}

      {:error, reason} ->
        {%{ok: false, accepted: false, error: inspect(reason)}, state}
    end
  end

  def pause_issue_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         :ok <- maybe_update_issue_state(issue.id, issue.state, @paused_state) do
      {policy_class, policy_source, policy_override} = Orchestrator.policy_snapshot_values(issue, state)

      state =
        state
        |> Orchestrator.terminate_running_issue(issue.id, false)
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
          metadata: %{
            action: "pause",
            policy_source: policy_source,
            policy_override: policy_override
          }
        })

      state =
        put_paused_policy_metadata(state, issue.id, %{
          policy_class: policy_class,
          policy_source: policy_source,
          policy_override: policy_override,
          next_human_action: "Resume the issue when it should re-enter active work.",
          last_ledger_event_id: Map.get(ledger_event, :event_id)
        })

      {%{
         ok: true,
         action: "pause",
         issue_identifier: issue.identifier,
         state: @paused_state,
         policy_class: policy_class,
         policy_source: policy_source,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      {:error, reason} ->
        {%{
           ok: false,
           action: "pause",
           issue_identifier: issue_identifier,
           error: inspect(reason)
         }, state}
    end
  end

  def resume_issue_runtime(%State{} = state, issue_identifier) do
    with {:ok, paused_entry} <- paused_issue_entry(state, issue_identifier),
         :ok <-
           IssueSource.update_issue_state(
             paused_issue_ref(paused_entry),
             paused_entry.resume_state
           ) do
      state = %{
        state
        | paused_issue_states: Map.delete(state.paused_issue_states, paused_entry.issue_id)
      }

      :ok = Orchestrator.schedule_tick(0)

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: paused_entry.issue_id,
          issue_identifier: paused_entry.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          summary: "Resumed paused issue.",
          target_state: paused_entry.resume_state,
          metadata: %{action: "resume", resume_state: paused_entry.resume_state}
        })

      {%{
         ok: true,
         action: "resume",
         issue_identifier: paused_entry.identifier,
         state: paused_entry.resume_state,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      {:error, reason} ->
        {%{
           ok: false,
           action: "resume",
           issue_identifier: issue_identifier,
           error: inspect(reason)
         }, state}
    end
  end

  def stop_issue_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         :ok <-
           IssueSource.create_comment(
             issue,
             "## Symphony operator stop\n\nRule ID: operator.stop\n\nFailure class: policy\n\nStopped by dashboard control.\n\nUnblock action: Move the issue back to an active state when it should run again."
           ),
         :ok <- IssueSource.update_issue_state(issue, @blocked_state) do
      {policy_class, policy_source, _policy_override} = Orchestrator.policy_snapshot_values(issue, state)

      state =
        state
        |> Orchestrator.terminate_running_issue(issue.id, false)
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

      {%{
         ok: true,
         action: "stop",
         issue_identifier: issue.identifier,
         state: @blocked_state,
         policy_class: policy_class,
         policy_source: policy_source,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      {:error, reason} ->
        {%{ok: false, action: "stop", issue_identifier: issue_identifier, error: inspect(reason)}, state}
    end
  end

  def hold_issue_for_human_review_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         {policy_class, policy_source, _policy_override} <- Orchestrator.policy_snapshot_values(issue, state),
         approval_gate_state <-
           WorkflowProfile.approval_gate_state(policy_class,
             policy_pack: Orchestrator.policy_pack_name(issue, state)
           ),
         :ok <- IssueSource.update_issue_state(issue, approval_gate_state) do
      state =
        state
        |> Orchestrator.terminate_running_issue(issue.id, false)
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
          summary: "Placed issue in #{approval_gate_state}.",
          details: "Operator requested a manual review hold.",
          target_state: approval_gate_state,
          metadata: %{
            action: "hold_for_human_review",
            policy_source: policy_source,
            approval_gate_state: approval_gate_state
          }
        })

      {%{
         ok: true,
         action: "hold_for_human_review",
         issue_identifier: issue.identifier,
         state: approval_gate_state,
         policy_class: policy_class,
         policy_source: policy_source,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      {:error, reason} ->
        {%{
           ok: false,
           action: "hold_for_human_review",
           issue_identifier: issue_identifier,
           error: inspect(reason)
         }, state}
    end
  end

  def retry_issue_now_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         false <- Orchestrator.issue_paused?(state, issue) do
      state = cancel_retry(state, issue.id)
      {state, issue} = maybe_resume_blocked_issue(state, issue)
      issue = retry_issue_control_envelope(issue)

      if not Map.has_key?(state.running, issue.id) do
        LeaseManager.release(issue.id)
      end

      {reply, state} = retry_issue_now_outcome(state, issue)

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          failure_class: Map.get(reply, :failure_class),
          rule_id: Map.get(reply, :rule_id),
          summary: Map.get(reply, :summary) || "Requested immediate retry.",
          details: retry_issue_now_details(reply),
          metadata: retry_issue_now_metadata(reply)
        })

      {Map.merge(
         %{
           action: "retry_now",
           issue_identifier: issue.identifier,
           ledger_event_id: Map.get(ledger_event, :event_id)
         },
         Map.drop(reply, [:summary])
       ), state}
    else
      true ->
        {%{
           ok: false,
           action: "retry_now",
           issue_identifier: issue_identifier,
           error: "issue is paused"
         }, state}

      {:error, reason} ->
        {%{
           ok: false,
           action: "retry_now",
           issue_identifier: issue_identifier,
           error: inspect(reason)
         }, state}
    end
  end

  def refresh_merge_readiness_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         false <- Orchestrator.issue_paused?(state, issue),
         workspace <- Workspace.path_for_issue(issue.identifier),
         {:ok, run_state} <- RunStateStore.load(workspace),
         pr_url when is_binary(pr_url) and pr_url != "" <- Map.get(run_state, :pr_url),
         :ok <- ensure_merge_readiness_restartable(state, issue.id),
         :ok <- maybe_update_issue_state(issue.id, issue.state, @merging_state),
         {:ok, _next_state} <-
           RunStateStore.transition(workspace, "merge_readiness", %{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             issue_source: issue.source,
             pr_url: pr_url,
             await_checks_polls: 0,
             stop_reason: nil,
             last_rule_id: "operator.refresh_merge_readiness",
             last_failure_class: "pr_hygiene",
             last_decision_summary: "Operator requested a merge-readiness refresh.",
             next_human_action: nil
           }) do
      state =
        state
        |> maybe_restart_passive_issue(issue.id)
        |> cancel_retry(issue.id)
        |> clear_paused_issue(issue.id)

      :ok = Orchestrator.schedule_tick(0)

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          summary: "Requested merge-readiness refresh.",
          target_state: @merging_state,
          metadata: %{action: "refresh_merge_readiness", pr_url: pr_url}
        })

      {%{
         ok: true,
         action: "refresh_merge_readiness",
         issue_identifier: issue.identifier,
         stage: "merge_readiness",
         pr_url: pr_url,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      true ->
        {%{
           ok: false,
           action: "refresh_merge_readiness",
           issue_identifier: issue_identifier,
           error: "issue is paused"
         }, state}

      nil ->
        {%{
           ok: false,
           action: "refresh_merge_readiness",
           issue_identifier: issue_identifier,
           error: "pr url not found"
         }, state}

      {:error, :active_stage_running} ->
        {%{
           ok: false,
           action: "refresh_merge_readiness",
           issue_identifier: issue_identifier,
           error: "issue is currently running an active stage"
         }, state}

      {:error, :enoent} ->
        {%{
           ok: false,
           action: "refresh_merge_readiness",
           issue_identifier: issue_identifier,
           error: "run state not found"
         }, state}

      {:error, reason} ->
        {%{
           ok: false,
           action: "refresh_merge_readiness",
           issue_identifier: issue_identifier,
           error: inspect(reason)
         }, state}
    end
  end

  def reprioritize_issue_runtime(%State{} = state, issue_identifier, override_rank) do
    identifier = issue_identifier |> to_string() |> String.trim()

    if identifier == "" do
      {%{
         ok: false,
         action: "reprioritize",
         issue_identifier: issue_identifier,
         error: "blank issue identifier"
       }, state}
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

  def approve_issue_for_merge_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         {policy_class, policy_source, _policy_override} <- Orchestrator.policy_snapshot_values(issue, state),
         false <- policy_class == "never_automerge",
         :ok <- IssueSource.update_issue_state(issue, @merging_state) do
      refreshed_issue =
        case IssueSource.refresh_issue(issue) do
          {:ok, %Issue{} = latest_issue} -> latest_issue
          _ -> %{issue | state: @merging_state}
        end

      workspace = Workspace.path_for_issue(issue.identifier)

      _ =
        RunStateStore.update(workspace, fn run_state ->
          run_state
          |> Map.put(:review_approved, true)
          |> Map.put(:automerge_disabled, false)
          |> Map.put(:stop_reason, nil)
          |> Map.put(:last_decision, nil)
          |> Map.put(:last_rule_id, nil)
          |> Map.put(:last_failure_class, nil)
          |> Map.put(:last_decision_summary, nil)
          |> Map.put(:next_human_action, nil)
        end)

      state =
        cond do
          Map.has_key?(state.running, issue.id) ->
            state

          Orchestrator.retry_candidate_issue?(refreshed_issue, Orchestrator.terminal_state_set()) and
              Orchestrator.dispatch_slots_available?(refreshed_issue, state) ->
            Orchestrator.dispatch_runtime_issue(state, refreshed_issue, nil)

          true ->
            :ok = Orchestrator.schedule_tick(0)
            state
        end

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

      {%{
         ok: true,
         action: "approve_for_merge",
         issue_identifier: issue.identifier,
         state: @merging_state,
         policy_class: policy_class,
         policy_source: policy_source,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      true ->
        {%{
           ok: false,
           action: "approve_for_merge",
           issue_identifier: issue_identifier,
           error: "policy forbids automerge"
         }, state}

      {:error, reason} ->
        {%{
           ok: false,
           action: "approve_for_merge",
           issue_identifier: issue_identifier,
           error: inspect(reason)
         }, state}
    end
  end

  def approve_issue_for_deploy_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         {policy_class, policy_source, _policy_override} <- Orchestrator.policy_snapshot_values(issue, state),
         workspace <- Workspace.path_for_issue(issue.identifier),
         {:ok, _run_state} <-
           RunStateStore.transition(workspace, "deploy_production", %{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             issue_source: issue.source,
             effective_policy_class: policy_class,
             deploy_approved: true,
             stop_reason: nil,
             last_decision: nil,
             last_rule_id: nil,
             last_failure_class: nil,
             last_decision_summary: "Operator approved production deployment.",
             next_human_action: nil,
             current_deploy_target: "production"
           }),
         :ok <- IssueSource.update_issue_state(issue, "In Progress") do
      refreshed_issue =
        case IssueSource.refresh_issue(issue) do
          {:ok, %Issue{} = latest_issue} -> latest_issue
          _ -> %{issue | state: "In Progress"}
        end

      state =
        cond do
          Map.has_key?(state.running, issue.id) ->
            state

          Orchestrator.retry_candidate_issue?(refreshed_issue, Orchestrator.terminal_state_set()) and
              Orchestrator.dispatch_slots_available?(refreshed_issue, state) ->
            Orchestrator.dispatch_runtime_issue(state, refreshed_issue, nil)

          true ->
            :ok = Orchestrator.schedule_tick(0)
            state
        end

      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          policy_class: policy_class,
          summary: "Approved issue for production deployment.",
          target_state: "In Progress",
          metadata: %{action: "approve_for_deploy", policy_source: policy_source}
        })

      {%{
         ok: true,
         action: "approve_for_deploy",
         issue_identifier: issue.identifier,
         state: "In Progress",
         policy_class: policy_class,
         policy_source: policy_source,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      {:error, reason} ->
        {%{
           ok: false,
           action: "approve_for_deploy",
           issue_identifier: issue_identifier,
           error: inspect(reason)
         }, state}
    end
  end

  def review_thread_action_runtime(%State{} = state, issue_identifier, action) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         workspace <- Workspace.path_for_issue(issue.identifier),
         {:ok, run_state} <- RunStateStore.load(workspace),
         review_threads when is_map(review_threads) and map_size(review_threads) > 0 <-
           Map.get(run_state, :review_threads, %{}),
         {:ok, updated_threads, changed_count, summary, human_action} <-
           apply_review_thread_action(action, review_threads),
         {:ok, _next_state} <-
           RunStateStore.update(workspace, fn persisted ->
             persisted
             |> Map.put(:review_threads, updated_threads)
             |> Map.put(:last_decision_summary, summary)
             |> Map.put(:next_human_action, human_action)
           end) do
      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          summary: summary,
          metadata: %{action: action, changed_threads: changed_count}
        })

      {%{
         ok: true,
         action: action,
         issue_identifier: issue.identifier,
         changed_threads: changed_count,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      %{} ->
        {%{
           ok: false,
           action: action,
           issue_identifier: issue_identifier,
           error: "no review threads"
         }, state}

      {:error, :enoent} ->
        {%{
           ok: false,
           action: action,
           issue_identifier: issue_identifier,
           error: "run state not found"
         }, state}

      {:error, :no_changes} ->
        {%{
           ok: false,
           action: action,
           issue_identifier: issue_identifier,
           error: "no review threads matched the requested transition"
         }, state}

      {:error, reason} ->
        {%{ok: false, action: action, issue_identifier: issue_identifier, error: inspect(reason)}, state}
    end
  end

  def post_review_drafts_runtime(%State{} = state, issue_identifier) do
    with {:ok, %Issue{} = issue} <- resolve_issue_for_control(state, issue_identifier),
         workspace <- Workspace.path_for_issue(issue.identifier),
         {:ok, run_state} <- RunStateStore.load(workspace),
         review_threads when is_map(review_threads) and map_size(review_threads) > 0 <-
           Map.get(run_state, :review_threads, %{}),
         pr_url when is_binary(pr_url) and pr_url != "" <- Map.get(run_state, :pr_url),
         {:ok, updated_threads, %{posted_count: posted_count, skipped_count: skipped_count}} <-
           PRWatcher.post_approved_drafts(
             workspace,
             pr_url,
             review_threads,
             policy_pack: Orchestrator.policy_pack_name(issue, state, run_state),
             company_name: Config.company_name(),
             repo_url: Config.company_repo_url()
           ),
         {:ok, _next_state} <-
           RunStateStore.update(workspace, fn persisted ->
             persisted
             |> Map.put(:review_threads, updated_threads)
             |> Map.put(:last_decision_summary, "Posted approved PR review replies.")
             |> Map.put(
               :next_human_action,
               "Resolve the review threads once the reply has been acknowledged."
             )
           end) do
      ledger_event =
        RunLedger.record("operator.action", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          actor_type: "operator",
          actor_id: "dashboard",
          summary: "Posted approved PR review replies.",
          metadata: %{
            action: "post_review_drafts",
            posted_threads: posted_count,
            skipped_threads: skipped_count
          }
        })

      {%{
         ok: true,
         action: "post_review_drafts",
         issue_identifier: issue.identifier,
         posted_threads: posted_count,
         skipped_threads: skipped_count,
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      %{} ->
        {%{
           ok: false,
           action: "post_review_drafts",
           issue_identifier: issue_identifier,
           error: "no review threads"
         }, state}

      nil ->
        {%{
           ok: false,
           action: "post_review_drafts",
           issue_identifier: issue_identifier,
           error: "pr url not found"
         }, state}

      {:error, :enoent} ->
        {%{
           ok: false,
           action: "post_review_drafts",
           issue_identifier: issue_identifier,
           error: "run state not found"
         }, state}

      {:error, reason} ->
        {%{
           ok: false,
           action: "post_review_drafts",
           issue_identifier: issue_identifier,
           error: inspect(reason)
         }, state}
    end
  end

  def set_policy_class_runtime(%State{} = state, issue_identifier, policy_class) do
    identifier = issue_identifier |> to_string() |> String.trim()

    with false <- identifier == "",
         policy_atom when not is_nil(policy_atom) <- IssuePolicy.normalize_class(policy_class) do
      policy_string = IssuePolicy.class_to_string(policy_atom)

      state = %{
        state
        | policy_overrides: Map.put(state.policy_overrides, identifier, policy_string)
      }

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

      {%{
         ok: true,
         action: "set_policy_class",
         issue_identifier: identifier,
         policy_class: policy_string,
         policy_source: "override",
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    else
      true ->
        {%{
           ok: false,
           action: "set_policy_class",
           issue_identifier: issue_identifier,
           error: "blank issue identifier"
         }, state}

      nil ->
        {%{
           ok: false,
           action: "set_policy_class",
           issue_identifier: issue_identifier,
           error: "invalid policy class"
         }, state}
    end
  end

  def clear_policy_override_runtime(%State{} = state, issue_identifier) do
    identifier = issue_identifier |> to_string() |> String.trim()

    if identifier == "" do
      {%{
         ok: false,
         action: "clear_policy_override",
         issue_identifier: issue_identifier,
         error: "blank issue identifier"
       }, state}
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

      {%{
         ok: true,
         action: "clear_policy_override",
         issue_identifier: identifier,
         policy_class: nil,
         policy_source: "label_or_default",
         ledger_event_id: Map.get(ledger_event, :event_id)
       }, state}
    end
  end

  # -------------------------------------------------------------------
  # Controls-only helpers (private)
  # -------------------------------------------------------------------

  @doc false
  def maybe_schedule_manual_issue_refresh(%State{} = state) do
    if state.poll_check_in_progress == true do
      state
    else
      :ok = Orchestrator.schedule_poll_cycle_start()

      %{
        state
        | poll_check_in_progress: true,
          current_poll_mode: :discovery,
          next_poll_due_at_ms: nil
      }
    end
  end

  defp upsert_candidate_issue(issues, %Issue{} = issue) when is_list(issues) do
    filtered =
      Enum.reject(issues, fn
        %Issue{id: id} when id == issue.id -> true
        _ -> false
      end)

    [issue | filtered]
  end

  @doc false
  def resolve_issue_for_control(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    issue_identifier = String.trim(issue_identifier)

    cond do
      issue_identifier == "" ->
        {:error, :blank_issue_identifier}

      issue = find_running_issue_by_identifier(state, issue_identifier) ->
        {:ok, issue}

      issue = seeded_control_issue(issue_identifier) ->
        {:ok, issue}

      true ->
        case IssueSource.fetch_issue(%{canonical_identifier: issue_identifier}) do
          {:ok, %Issue{} = issue} -> {:ok, issue}
          {:ok, nil} -> {:error, :issue_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def resolve_issue_for_control(_state, _issue_identifier), do: {:error, :blank_issue_identifier}

  defp seeded_control_issue(issue_identifier) when is_binary(issue_identifier) do
    workspace = Workspace.path_for_issue(issue_identifier)

    with true <- File.dir?(workspace),
         {:ok, run_state} <- RunStateStore.load(workspace),
         %Issue{} = issue <- Orchestrator.seeded_manual_issue_from_run_state(run_state),
         ^issue_identifier <- issue.identifier do
      issue
    else
      _ -> nil
    end
  end

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
        {:ok,
         %{
           issue_id: issue_id,
           identifier: Map.get(paused_entry, :identifier) || issue_identifier,
           resume_state: Map.get(paused_entry, :resume_state) || "Todo",
           source: Map.get(paused_entry, :source),
           external_id: Map.get(paused_entry, :external_id),
           canonical_identifier:
             Map.get(paused_entry, :canonical_identifier) ||
               Map.get(paused_entry, :identifier) || issue_identifier
         }}

      nil ->
        {:error, :issue_not_paused}
    end
  end

  defp paused_issue_entry(_state, _issue_identifier), do: {:error, :blank_issue_identifier}

  defp maybe_update_issue_state(issue_id, current_state, target_state)
       when is_binary(issue_id) and is_binary(target_state) do
    if SymphonyElixir.Util.normalize_state(current_state || "") == SymphonyElixir.Util.normalize_state(target_state) do
      :ok
    else
      IssueSource.update_issue_state(%{id: issue_id}, target_state)
    end
  end

  defp ensure_merge_readiness_restartable(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      nil ->
        :ok

      %{passive?: true} ->
        :ok

      %{dispatch_stage: stage} when stage in ["merge_readiness", "await_checks", "merge", "post_merge"] ->
        :ok

      _ ->
        {:error, :active_stage_running}
    end
  end

  defp maybe_restart_passive_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{passive?: true} ->
        Orchestrator.terminate_running_issue(state, issue_id, false)

      %{dispatch_stage: stage} when stage in ["merge_readiness", "await_checks", "merge", "post_merge"] ->
        Orchestrator.terminate_running_issue(state, issue_id, false)

      _ ->
        state
    end
  end

  defp put_paused_issue(%State{} = state, %Issue{} = issue) do
    paused_entry = %{
      identifier: issue.identifier,
      source: issue.source,
      external_id: issue.external_id,
      canonical_identifier: issue.canonical_identifier || issue.identifier,
      resume_state: pause_resume_state(issue.state)
    }

    %{state | paused_issue_states: Map.put(state.paused_issue_states, issue.id, paused_entry)}
  end

  defp paused_issue_ref(%{issue_id: issue_id} = paused_entry) do
    %{
      id: issue_id,
      source: Map.get(paused_entry, :source),
      external_id: Map.get(paused_entry, :external_id),
      canonical_identifier: Map.get(paused_entry, :canonical_identifier)
    }
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

  defp pause_resume_state(state_name) when is_binary(state_name) do
    normalized = SymphonyElixir.Util.normalize_state(state_name)

    case normalized do
      "paused" -> "Todo"
      "blocked" -> "Todo"
      _ -> state_name
    end
  end

  defp put_paused_policy_metadata(%State{} = state, issue_id, attrs) do
    paused_entry =
      state.paused_issue_states
      |> Map.get(issue_id, %{})
      |> Map.merge(attrs)

    %{state | paused_issue_states: Map.put(state.paused_issue_states, issue_id, paused_entry)}
  end

  defp persist_policy_override_for_identifier(identifier, override) when is_binary(identifier) do
    workspace = Workspace.path_for_issue(identifier)

    if File.exists?(workspace) do
      _ =
        RunStateStore.update(workspace, fn state ->
          Map.put(state, :policy_override, override)
        end)
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Retry helpers
  # -------------------------------------------------------------------

  defp retry_issue_now_outcome(%State{} = state, %Issue{} = issue) do
    cond do
      Map.has_key?(state.running, issue.id) ->
        {%{
           ok: true,
           dispatch_outcome: "already_running",
           summary: "Immediate retry skipped because the issue is already running."
         }, state}

      Orchestrator.retry_candidate_issue?(issue, Orchestrator.terminal_state_set()) and Orchestrator.dispatch_slots_available?(issue, state) ->
        next_state = Orchestrator.dispatch_runtime_issue(state, issue, 1)

        cond do
          dispatch_started_for_issue?(state, next_state, issue.id) ->
            {%{
               ok: true,
               dispatch_outcome: "dispatched",
               summary: "Immediate retry dispatched the issue."
             }, next_state}

          retry_scheduled_for_issue?(state, next_state, issue.id) ->
            {%{
               ok: true,
               dispatch_outcome: "retry_scheduled",
               summary: "Immediate retry could not dispatch immediately and scheduled a retry."
             }, next_state}

          true ->
            diagnostic = retry_issue_now_diagnostic(issue, state)

            {Map.merge(
               %{
                 ok: true,
                 dispatch_outcome: "deferred",
                 error: diagnostic.summary
               },
               diagnostic
             ), next_state}
        end

      true ->
        :ok = Orchestrator.schedule_tick(0)
        diagnostic = retry_issue_now_diagnostic(issue, state)

        {Map.merge(
           %{
             ok: true,
             dispatch_outcome: "deferred",
             error: diagnostic.summary
           },
           diagnostic
         ), state}
    end
  end

  defp retry_issue_control_envelope(%Issue{source: :tracker} = issue) do
    case Orchestrator.revalidate_issue_for_dispatch(issue, &IssueSource.fetch_issue_states_by_ids/1, Orchestrator.terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} -> refreshed_issue
      {:skip, %Issue{} = refreshed_issue} -> refreshed_issue
      _ -> issue
    end
  end

  defp retry_issue_control_envelope(%Issue{} = issue), do: issue
  defp retry_issue_control_envelope(issue), do: issue

  defp retry_issue_now_diagnostic(%Issue{} = issue, %State{} = state) do
    cond do
      Orchestrator.available_slots(state) <= 0 ->
        retry_issue_now_rule(
          :dispatch_slots_unavailable,
          "Immediate retry deferred because no orchestrator dispatch slots are available.",
          %{issue_state: issue.state, running_count: map_size(state.running)}
        )

      not Orchestrator.state_slots_available?(issue, state.running) ->
        retry_issue_now_rule(
          :dispatch_slots_unavailable,
          "Immediate retry deferred because #{issue.state} is already at its per-state concurrency limit.",
          %{issue_state: issue.state, running_count: map_size(state.running)}
        )

      not Orchestrator.retry_candidate_issue?(issue, Orchestrator.terminal_state_set()) ->
        retry_issue_now_ineligible_diagnostic(issue, state)

      true ->
        case Orchestrator.revalidate_issue_for_dispatch(issue, &IssueSource.fetch_issue_states_by_ids/1, Orchestrator.terminal_state_set()) do
          {:skip, :missing} ->
            retry_issue_now_rule(
              :retry_dispatch_deferred,
              "Immediate retry deferred because the issue is no longer active or visible during tracker refresh.",
              %{issue_state: issue.state}
            )

          {:skip, %Issue{} = refreshed_issue} ->
            reason = Orchestrator.dispatch_skip_reason(refreshed_issue, state)

            retry_issue_now_rule(
              :retry_dispatch_deferred,
              retry_issue_now_skip_summary(refreshed_issue, reason),
              %{
                issue_state: refreshed_issue.state,
                blocked_by: Map.get(refreshed_issue, :blocked_by, []),
                skip_reason: reason
              },
              Orchestrator.next_human_action_for_skip(reason)
            )

          {:error, reason} ->
            retry_issue_now_rule(
              :retry_dispatch_deferred,
              "Immediate retry deferred because tracker refresh failed before dispatch.",
              %{issue_state: issue.state, refresh_error: inspect(reason)}
            )

          {:ok, _refreshed_issue} ->
            retry_issue_now_rule(
              :retry_dispatch_deferred,
              "Immediate retry was accepted, but dispatch produced no visible runtime state change.",
              %{issue_state: issue.state}
            )
        end
    end
  end

  defp retry_issue_now_ineligible_diagnostic(%Issue{} = issue, %State{} = state) do
    reason = Orchestrator.dispatch_skip_reason(issue, state)

    retry_issue_now_rule(
      :retry_dispatch_deferred,
      retry_issue_now_skip_summary(issue, reason),
      %{
        issue_state: issue.state,
        issue_source: issue.source,
        skip_reason: reason,
        blocked_by: Map.get(issue, :blocked_by, []),
        title_present: is_binary(issue.title) and String.trim(issue.title) != "",
        identifier_present: is_binary(issue.identifier) and String.trim(issue.identifier) != "",
        id_present: is_binary(issue.id) and String.trim(issue.id) != "",
        assigned_to_worker: Map.get(issue, :assigned_to_worker),
        target_runner_channel: Orchestrator.issue_target_runner_channel(issue),
        label_gate: Orchestrator.label_gate_status(issue)
      },
      Orchestrator.next_human_action_for_skip(reason)
    )
  end

  defp retry_issue_now_skip_summary(%Issue{} = issue, reason) when is_binary(reason) do
    "Immediate retry deferred because #{issue.identifier} is not dispatchable right now (#{reason})."
  end

  defp retry_issue_now_skip_summary(%Issue{} = issue, _reason) do
    "Immediate retry deferred because #{issue.identifier} is not dispatchable in state #{issue.state}."
  end

  defp retry_issue_now_rule(rule_key, summary, details, human_action_override \\ nil)
       when is_atom(rule_key) and is_binary(summary) and is_map(details) do
    rule = RuleCatalog.rule(rule_key)

    %{
      rule_id: rule.rule_id,
      failure_class: rule.failure_class,
      summary: summary,
      details: details,
      human_action: human_action_override || rule.human_action
    }
  end

  defp retry_issue_now_metadata(reply) when is_map(reply) do
    %{
      action: "retry_now",
      dispatch_outcome: Map.get(reply, :dispatch_outcome),
      human_action: Map.get(reply, :human_action),
      details: Map.get(reply, :details)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp retry_issue_now_details(reply) when is_map(reply) do
    case Map.get(reply, :details) do
      nil -> nil
      details -> inspect(details)
    end
  end

  defp dispatch_started_for_issue?(%State{} = state, %State{} = next_state, issue_id)
       when is_binary(issue_id) do
    not Map.has_key?(state.running, issue_id) and Map.has_key?(next_state.running, issue_id)
  end

  defp dispatch_started_for_issue?(_state, _next_state, _issue_id), do: false

  defp retry_scheduled_for_issue?(%State{} = state, %State{} = next_state, issue_id)
       when is_binary(issue_id) do
    not Map.has_key?(state.retry_attempts, issue_id) and
      Map.has_key?(next_state.retry_attempts, issue_id)
  end

  defp retry_scheduled_for_issue?(_state, _next_state, _issue_id), do: false

  # -------------------------------------------------------------------
  # Resume helpers (retry_issue_now support)
  # -------------------------------------------------------------------

  def maybe_resume_blocked_issue(%State{} = state, %Issue{} = issue) do
    workspace = Workspace.path_for_issue(issue.identifier)

    local_resume =
      fn resume_state ->
        cond do
          issue.source == :manual and is_binary(resume_state) ->
            {state, %{issue | state: resume_state}}

          true ->
            {state, %{issue | state: "Todo"}}
        end
      end

    with true <- resumable_retry_issue?(workspace, issue),
         run_state when is_map(run_state) <- RunStateStore.load_or_default(workspace, issue),
         {:ok, resume_stage} <- resumable_stage_from_run_state(run_state, issue),
         resume_state when is_binary(resume_state) <- issue_state_for_stage(resume_stage),
         {:ok, _state} <-
           RunStateStore.transition(workspace, resume_stage, %{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             issue_source: issue.source,
             reason: "Operator retry requested",
             stop_reason: nil,
             last_decision: nil,
             last_rule_id: nil,
             last_failure_class: nil,
             last_decision_summary: nil,
             next_human_action: nil,
             resume_context: retry_resume_context(run_state, resume_stage)
           }),
         :ok <- IssueSource.update_issue_state(issue, resume_state),
         {:ok, refreshed_issue} <- IssueSource.refresh_issue(issue) do
      {state, refreshed_issue || %{issue | state: resume_state}}
    else
      _ ->
        resume_state =
          with true <- File.dir?(workspace),
               run_state when is_map(run_state) <- RunStateStore.load_or_default(workspace, issue),
               {:ok, resume_stage} <- resumable_stage_from_run_state(run_state, issue) do
            issue_state_for_stage(resume_stage)
          else
            _ -> nil
          end

        case IssueSource.update_issue_state(issue, "Todo") do
          :ok ->
            case IssueSource.refresh_issue(%{issue | state: "Todo"}) do
              {:ok, %Issue{state: @blocked_state}} ->
                local_resume.(resume_state)

              {:ok, %Issue{} = refreshed_issue} ->
                {state, refreshed_issue}

              _ ->
                local_resume.(resume_state)
            end

          _ ->
            local_resume.(resume_state)
        end
    end
  end

  defp resumable_retry_issue?(workspace, %Issue{} = issue) when is_binary(workspace) do
    resumable_blocked_issue?(workspace, issue) or resumable_seeded_manual_issue?(workspace, issue)
  end

  defp resumable_blocked_issue?(workspace, %Issue{state: @blocked_state})
       when is_binary(workspace) do
    File.dir?(workspace)
  end

  defp resumable_blocked_issue?(workspace, %Issue{} = issue) when is_binary(workspace) do
    File.dir?(workspace) and run_state_blocked_for_issue?(workspace, issue)
  end

  defp run_state_blocked_for_issue?(workspace, issue) when is_binary(workspace) do
    case RunStateStore.load_or_default(workspace, issue) do
      %{stage: "blocked"} -> true
      %{"stage" => "blocked"} -> true
      _ -> false
    end
  end

  defp resumable_seeded_manual_issue?(workspace, %Issue{source: :manual})
       when is_binary(workspace) do
    with true <- File.dir?(workspace),
         {:ok, run_state} <- RunStateStore.load(workspace),
         stage when is_binary(stage) <- resumable_current_stage(run_state) do
      stage not in ["checkout", "done"]
    else
      _ -> false
    end
  end

  defp resumable_seeded_manual_issue?(_workspace, _issue), do: false

  defp resumable_stage_from_run_state(run_state, issue) when is_map(run_state) do
    resume_stage =
      resume_stage_override(run_state, issue) ||
        Map.get(run_state, :resume_stage) ||
        resumable_current_stage(run_state) ||
        run_state
        |> Map.get(:stage_history, [])
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{stage: stage} when is_binary(stage) and stage != "blocked" -> stage
          _ -> nil
        end)

    case resume_stage do
      stage when is_binary(stage) -> {:ok, stage}
      _ -> :error
    end
  end

  defp resumable_current_stage(run_state) when is_map(run_state) do
    case Map.get(run_state, :stage) do
      stage when is_binary(stage) and stage != "blocked" -> stage
      _ -> nil
    end
  end

  defp resume_stage_override(run_state, issue) when is_map(run_state) do
    case {get_in(run_state, [:stop_reason, :code]), behavioral_proof_resume_stage(run_state, issue)} do
      {code, "verify"} when code in ["behavior_proof_missing", "noop_turn"] ->
        "verify"

      {"verifier_failed", _} ->
        if workspace_has_unvalidated_changes?(issue), do: "validate", else: "implement"

      {"behavior_proof_missing", _} ->
        "implement"

      {"validation_failed", _} ->
        "implement"

      {"verifier_blocked", _} ->
        "verify"

      _ ->
        nil
    end
  end

  defp workspace_has_unvalidated_changes?(issue) do
    workspace = Workspace.path_for_issue(issue.identifier)

    case RunInspector.inspect(workspace) do
      %RunInspector.Snapshot{git?: true, dirty?: true} -> true
      _ -> false
    end
  end

  defp retry_resume_context(run_state, resume_stage)
       when is_map(run_state) and is_binary(resume_stage) do
    resume_context =
      case Map.get(run_state, :resume_context) do
        context when is_map(context) -> context
        _ -> %{}
      end

    cond do
      resume_stage == "implement" and scoped_review_retry_candidate?(run_state) ->
        Map.put(
          resume_context,
          :implementation_turn_window_base,
          Map.get(run_state, :implementation_turns, 0)
        )

      true ->
        resume_context
    end
  end

  defp scoped_review_retry_candidate?(run_state) when is_map(run_state) do
    get_in(run_state, [:resume_context, :token_pressure]) == "high" and
      Enum.any?(Map.get(run_state, :review_claims, %{}), fn {_thread_key, claim} ->
        claim_value(claim, :disposition) == "accepted" and claim_value(claim, :actionable, false)
      end)
  end

  defp claim_value(claim, key, default \\ nil) when is_map(claim) and is_atom(key) do
    Map.get(claim, key, Map.get(claim, Atom.to_string(key), default))
  end

  defp behavioral_proof_resume_stage(run_state, issue) when is_map(run_state) do
    case get_in(run_state, [:last_verifier, :reason_code]) do
      "behavior_proof_missing" ->
        workspace = Workspace.path_for_issue(issue.identifier)

        case RunInspector.inspect(workspace) do
          %RunInspector.Snapshot{git?: true, harness: harness} ->
            changed_paths = RunInspector.changed_paths(workspace)
            proof = BehavioralProof.evaluate(workspace, harness, changed_paths)

            if proof.required? and proof.satisfied? do
              "verify"
            else
              nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp issue_state_for_stage(stage) when stage in ["checkout"], do: "Todo"

  defp issue_state_for_stage(stage) when stage in ["implement", "validate", "verify"],
    do: "In Progress"

  defp issue_state_for_stage(stage)
       when stage in [
              "publish",
              "merge_readiness",
              "await_checks",
              "merge",
              "post_merge",
              "deploy_preview",
              "deploy_production",
              "post_deploy_verify"
            ],
       do: "Merging"

  defp issue_state_for_stage(_stage), do: nil

  # -------------------------------------------------------------------
  # Review thread helpers
  # -------------------------------------------------------------------

  defp apply_review_thread_action("approve_review_drafts", review_threads) do
    update_review_threads(
      review_threads,
      &(&1 in ["drafted"]),
      "approved_to_post",
      "Approved drafted PR review replies for posting.",
      "Post the approved replies or continue editing before resolving the threads."
    )
  end

  defp apply_review_thread_action("reject_review_drafts", review_threads) do
    update_review_threads(
      review_threads,
      &(&1 in ["drafted", "approved_to_post"]),
      "rejected",
      "Rejected drafted PR review replies.",
      "Revise the draft replies or keep the review threads open."
    )
  end

  defp apply_review_thread_action("mark_review_threads_posted", review_threads) do
    update_review_threads(
      review_threads,
      &(&1 in ["approved_to_post", "drafted"]),
      "posted",
      "Marked drafted PR review replies as posted.",
      "Resolve the review threads once the reply has been acknowledged."
    )
  end

  defp apply_review_thread_action("resolve_review_threads", review_threads) do
    update_review_threads(
      review_threads,
      &(&1 in ["posted", "approved_to_post"]),
      "resolved",
      "Marked PR review threads as resolved.",
      "No further review-thread action is required."
    )
  end

  defp apply_review_thread_action(_action, _review_threads), do: {:error, :no_changes}

  defp update_review_threads(review_threads, matcher, target_state, summary, human_action) do
    {updated_threads, changed_count} =
      Enum.reduce(review_threads, {%{}, 0}, fn {thread_key, thread_state}, {acc, changed} ->
        current_state =
          thread_state
          |> Map.get("draft_state", "drafted")
          |> to_string()

        if matcher.(current_state) do
          updated =
            thread_state
            |> Map.put("draft_state", target_state)

          {Map.put(acc, thread_key, updated), changed + 1}
        else
          {Map.put(acc, thread_key, thread_state), changed}
        end
      end)

    if changed_count > 0 do
      {:ok, updated_threads, changed_count, summary, human_action}
    else
      {:error, :no_changes}
    end
  end
end
