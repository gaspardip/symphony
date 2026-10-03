defmodule SymphonyElixir.Orchestrator.Controls do
  @moduledoc """
  Finite operator control phases executed by the orchestrator owner.

  Preparation reads and validates without effects. Advancement carries the
  original deadline and completed-effect evidence through checked reads and
  admission. State always returns to the same owner; readers never carry State.
  The ordinary retry helper below retains its separate historical contract.
  """
  alias SymphonyElixir.BehavioralProof
  alias SymphonyElixir.Config
  alias SymphonyElixir.DeployAudit
  alias SymphonyElixir.GitHubEventInbox
  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.IssueSource
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ManualIssueStore
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.ReviewPublication
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.TrackerEventInbox
  alias SymphonyElixir.WorkflowProfile
  alias SymphonyElixir.Workspace

  @paused_state "Paused"
  @blocked_state "Blocked"
  @merging_state "Merging"

  # -------------------------------------------------------------------
  # Runtime control functions (public API for orchestrator delegation)
  # -------------------------------------------------------------------

  @spec submit_manual_issue_runtime(State.t(), map()) :: {State.t(), map()}
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

  @control_actions ~w(pause resume stop hold_for_human_review retry_now refresh_merge_readiness reprioritize approve_for_merge approve_for_deploy approve_review_drafts reject_review_drafts mark_review_threads_posted post_review_drafts resolve_review_threads set_policy_class clear_policy_override)a
  @local_actions ~w(resume reprioritize set_policy_class clear_policy_override)a
  @refresh_actions ~w(retry_now approve_for_merge approve_for_deploy)a
  @thread_actions ~w(approve_review_drafts reject_review_drafts mark_review_threads_posted resolve_review_threads)a

  @doc false
  @spec prepare(State.t(), map()) :: {:ok, map()} | {:error, map()}
  def prepare(%State{} = state, %{ref: ref, deadline: deadline, action: action, identifier: identifier, args: args} = request)
      when is_reference(ref) and is_integer(deadline) and action in @control_actions and is_binary(identifier) and is_list(args) and map_size(request) == 5 do
    operation = %{
      ref: ref,
      deadline: deadline,
      action: action,
      identifier: String.trim(identifier),
      args: args,
      phase: :ready,
      issue: nil,
      context: nil,
      workspace: nil,
      remote?: false,
      origin: :resolved,
      effect?: false,
      last_effect: nil,
      prepared: %{},
      response: nil,
      ledger: nil,
      checkpoint: nil
    }

    with :ok <- control_arguments(action, args),
         false <- operation.identifier == "",
         :ok <- control_deadline(operation),
         :ok <- preparation_deploy_guard(operation),
         :ok <- Config.validate!() do
      context = Config.tracker_read_context()
      operation = %{operation | context: context, workspace: Workspace.path_for_issue(operation.identifier)}

      result =
        if action in @local_actions do
          prepare_local_control(state, operation)
        else
          prepare_resolved_control(state, operation)
        end

      case result do
        {:ok, prepared} ->
          case control_deadline(prepared) do
            :ok -> {:ok, prepared}
            {:error, _} -> {:error, control_rejection(prepared, "control_deadline_exceeded")}
          end

        {:error, _} = error ->
          error
      end
    else
      true -> {:error, control_domain_payload(operation, "blank issue identifier")}
      {:error, :control_deadline_exceeded} -> {:error, control_rejection(operation, "control_deadline_exceeded")}
      {:error, reason} -> {:error, control_domain_payload(operation, inspect(reason))}
    end
  rescue
    _error in NimbleOptions.ValidationError ->
      {:error, %{ok: false, action: Atom.to_string(action), issue_identifier: identifier, error: "control_read_failed", effect_status: "not_started"}}
  end

  def prepare(_state, request) do
    {:error, %{ok: false, action: "invalid", issue_identifier: Map.get(request, :identifier), error: "invalid_control_request"}}
  end

  @doc false
  @spec advance(State.t(), map(), term()) ::
          {:read, map(), tuple(), State.t()} | {:admit, map(), Issue.t(), non_neg_integer() | nil, State.t()} | {:done, map(), map(), State.t()} | {:rejected, map(), map(), State.t()}
  def advance(%State{} = state, operation, input) do
    case control_phase_boundary(operation) do
      :ok -> advance_control(state, operation, input)
      {:error, :control_deadline_exceeded} -> reject_control(state, operation, "control_deadline_exceeded")
      {:error, :control_invalidated} -> reject_control(state, operation, "control_invalidated")
    end
  end

  defp control_arguments(action, [value]) when action == :reprioritize and (is_integer(value) or is_nil(value)), do: :ok
  defp control_arguments(:set_policy_class, [value]) when is_binary(value), do: :ok
  defp control_arguments(action, []) when action not in [:reprioritize, :set_policy_class], do: :ok
  defp control_arguments(_action, _args), do: {:error, :invalid_control_arguments}

  defp preparation_deploy_guard(%{action: action}) when action in [:pause, :stop, :hold_for_human_review, :reprioritize, :set_policy_class, :clear_policy_override], do: :ok
  defp preparation_deploy_guard(operation), do: ensure_deploy_control_available(operation.identifier)

  defp prepare_local_control(state, %{action: :resume} = operation) do
    case paused_issue_entry(state, operation.identifier) do
      {:ok, entry} -> {:ok, %{operation | prepared: %{paused: entry}}}
      {:error, reason} -> {:error, control_domain_payload(operation, inspect(reason))}
    end
  end

  defp prepare_local_control(_state, %{action: :set_policy_class, args: [value]} = operation) do
    case IssuePolicy.normalize_class(value) do
      nil -> {:error, control_domain_payload(operation, "invalid policy class")}
      policy -> {:ok, %{operation | prepared: %{policy: IssuePolicy.class_to_string(policy)}}}
    end
  end

  defp prepare_local_control(_state, operation), do: {:ok, operation}

  defp prepare_resolved_control(state, operation) do
    case find_running_issue_by_identifier(state, operation.identifier) do
      %Issue{} = issue ->
        prepare_control_issue(operation, issue)

      nil ->
        case pending_stop_issue(state, operation) do
          %Issue{} = issue -> prepare_control_issue(operation, issue)
          {:error, :control_read_failed} -> {:error, control_rejection(operation, "control_read_failed")}
          nil -> prepare_retained_github_stop(state, operation)
        end
    end
  end

  defp pending_stop_issue(
         %{admission_read: %{purpose: :retry, phase: phase, issue: %Issue{id: id, identifier: identifier} = identity} = reader, retry_attempts: retries},
         %{action: action, identifier: identifier} = operation
       )
       when action in [:pause, :stop] and phase in [:lookup, :refresh] do
    if manual_control_issue?(identity) do
      nil
    else
      with true <- is_binary(id) and id != "" and is_binary(identifier) and identifier != "",
           %{retry_ref: ref, status: :reading, identifier: ^identifier} = entry <- Map.get(retries, id),
           true <- is_reference(ref) and ref == reader.retry_ref,
           true <- reader.invalidated == false and reader.fingerprint == operation.context.fingerprint do
        current = if phase == :lookup, do: Map.get(entry, :issue), else: identity

        case current do
          nil when action == :stop and phase == :lookup ->
            identity

          %Issue{id: ^id, identifier: ^identifier, source: source} = issue when source in [nil, :tracker] ->
            if action == :stop or (is_binary(issue.state) and String.trim(issue.state) != ""),
              do: issue,
              else: {:error, :control_read_failed}

          _ ->
            {:error, :control_read_failed}
        end
      else
        _ -> {:error, :control_read_failed}
      end
    end
  end

  defp pending_stop_issue(
         %{admission_read: %{purpose: :poll, issue: %Issue{} = issue, fingerprint: fingerprint}, admission_batch: %{invalidated: %MapSet{} = invalidated}},
         %{action: action} = operation
       )
       when action in [:pause, :stop] do
    if is_binary(issue.id) and issue.id != "" and issue.identifier == operation.identifier and
         fingerprint == operation.context.fingerprint and not MapSet.member?(invalidated, issue.id) and not MapSet.member?(invalidated, issue.identifier) and
         not manual_control_issue?(issue),
       do: issue,
       else: nil
  end

  defp pending_stop_issue(state, %{action: action} = operation) when action in [:pause, :stop] do
    case {state.tracker_inbox_batch, state.admission_read} do
      {%{fingerprint: fingerprint, location: location, head: %{ref: ref, issue: %Issue{} = issue, event: %{entity_id: id}, fingerprint: fingerprint, invalidated: false}},
       %{purpose: :inbox_admission, head_ref: ref, issue: issue, fingerprint: fingerprint, invalidated: false}} ->
        if issue.id == id and issue.identifier == operation.identifier and fingerprint == operation.context.fingerprint and location == TrackerEventInbox.location() and
             not manual_control_issue?(issue),
           do: issue,
           else: nil

      _ ->
        nil
    end
  end

  defp pending_stop_issue(_state, _operation), do: nil

  defp prepare_retained_github_stop(state, %{action: action} = operation) when action in [:pause, :stop] do
    with %{fingerprint: fingerprint, root: root, location: location, head: %{ref: head_ref, blocked: true, operation: pending}} <- state.github_inbox_batch,
         %{phase: :blocked, invalidated: false, issue: %Issue{} = issue, issue_ref: ref, admission_close_error: close_error, ticket: ticket, authority: authority} <- pending,
         true <- not is_nil(close_error) and is_map(ticket) and is_map(authority),
         true <- issue.id == ref.id and issue.identifier == ref.identifier and issue.source == ref.source and issue.identifier == operation.identifier,
         true <- pending.fingerprint == fingerprint and fingerprint == operation.context.fingerprint and root == Config.workspace_root() and location == GitHubEventInbox.location(),
         true <- pending.workspace == operation.workspace and authority.workspace == operation.workspace and ticket.workspace == operation.workspace,
         true <- authority.issue_id == issue.id and authority.issue_identifier == issue.identifier and authority.binding == pending.binding,
         %{custody_ref: custody_ref, token: token, workspace: workspace, completion: completion} <- Map.get(state.lease_claims, issue.id),
         %{purpose: :github_inbox, head_ref: ^head_ref, decision_ref: decision_ref, custody_ref: ^custody_ref} <- completion,
         true <- decision_ref == pending.ref and custody_ref == pending.custody_ref and token == authority.lease_token and pending.custody == {custody_ref, token},
         true <-
           workspace == operation.workspace and token.storage.issue_id == issue.id and ticket.owner == token.owner and ticket.epoch == token.epoch and ticket.ledger_path == token.storage.ledger_path,
         nil <- Map.get(state.running, issue.id) do
      case RunStateStore.load(operation.workspace) do
        {:ok, raw} ->
          if raw[:issue_id] == issue.id and raw[:issue_identifier] == issue.identifier and Map.fetch(raw, :issue_source) == Map.fetch(pending.view, :issue_source) and
               retained_github_binding?(pending.binding, ticket, raw) do
            case LeaseManager.ensure_current(token) do
              :ok -> prepare_control_issue(operation, issue)
              {:error, _reason} -> {:error, control_rejection(operation, "control_read_failed")}
            end
          else
            prepare_local_issue(operation)
          end

        {:error, _reason} ->
          prepare_local_issue(operation)
      end
    else
      _not_current_retained_issue -> prepare_local_issue(operation)
    end
  end

  defp prepare_retained_github_stop(_state, operation), do: prepare_local_issue(operation)

  defp retained_github_binding?(:legacy_absent, ticket, raw),
    do: raw[:run_id] == ticket.run_id and raw[:run_identity_ledger_path] == ticket.ledger_path

  defp retained_github_binding?({:identified, binding}, ticket, raw),
    do: Map.take(raw, [:run_id, :run_identity_event_id, :run_identity_ledger_path]) == binding and raw[:run_id] == ticket.run_id and raw[:run_identity_ledger_path] == ticket.ledger_path

  defp prepare_local_issue(operation) do
    case RunStateStore.load(operation.workspace) do
      {:ok, raw} ->
        case Orchestrator.seeded_manual_issue_from_run_state(raw) do
          %Issue{identifier: identifier} = issue when identifier == operation.identifier ->
            if Map.get(raw, :issue_source) in [:manual, "manual"] do
              case IssueSource.fetch_issue_checked(%{source: :manual, id: issue.id, identifier: issue.identifier}, operation.context) do
                {:ok, {:missing, :manual}} -> prepare_control_issue(%{operation | origin: :seeded_local}, issue)
                {:ok, {:issue, :manual, current}} -> prepare_control_issue(operation, current)
                {:ok, _rejection} -> {:error, control_rejection(operation, "control_read_failed")}
              end
            else
              prepare_manual_control(operation)
            end

          _ ->
            prepare_manual_control(operation)
        end

      {:error, :missing} ->
        prepare_manual_control(operation)

      {:error, :enoent} ->
        prepare_manual_control(operation)

      {:error, _reason} when operation.action in [:pause, :stop] ->
        prepare_manual_control(operation)

      {:error, _reason} ->
        {:error, control_rejection(operation, "control_read_failed")}
    end
  end

  defp prepare_manual_control(%{context: %{manual_enabled: false}} = operation), do: prepare_tracker_control(operation)

  defp prepare_manual_control(operation) do
    case IssueSource.fetch_issue_by_identifier_checked(operation.identifier, :manual, operation.context) do
      {:ok, {:issue, :manual, issue}} -> prepare_control_issue(operation, issue)
      {:ok, {:missing, :manual}} -> prepare_tracker_control(operation)
      {:ok, _rejection} -> {:error, control_rejection(operation, "control_read_failed")}
    end
  end

  defp prepare_tracker_control(operation), do: {:ok, %{operation | phase: :resolve, remote?: true}}

  defp prepare_control_issue(operation, %Issue{} = issue) do
    cond do
      not is_binary(issue.id) or issue.id == "" or issue.identifier != operation.identifier or issue.source not in [nil, :manual, :tracker] ->
        {:error, control_rejection(operation, "control_read_failed")}

      true ->
        remote? = operation.action in @refresh_actions and not manual_control_issue?(issue)
        {:ok, %{operation | issue: issue, remote?: remote?}}
    end
  end

  defp manual_control_issue?(%Issue{source: :manual}), do: true
  defp manual_control_issue?(%Issue{source: nil, id: id}), do: SymphonyElixir.ManualIssueSpec.runtime_issue_id?(id)
  defp manual_control_issue?(%Issue{}), do: false

  defp advance_control(state, %{phase: :resolve} = operation, :start),
    do: {:read, operation, {:identifier, operation.identifier, :tracker}, state}

  defp advance_control(state, %{phase: :resolve} = operation, {:ok, {:issue, :tracker, %Issue{} = issue}}) do
    case prepare_control_issue(operation, issue) do
      {:ok, next} -> advance(state, %{next | phase: :ready}, :start)
      {:error, payload} -> {:rejected, operation, payload, state}
    end
  end

  defp advance_control(state, %{phase: :resolve} = operation, {:ok, {:missing, :tracker}}),
    do: domain_control_error(state, operation, :issue_not_found)

  defp advance_control(state, %{phase: :resolve} = operation, _checked_rejection),
    do: reject_control(state, operation, "control_read_failed")

  defp advance_control(state, %{phase: :refresh} = operation, {:ok, {:issue, _source, %Issue{} = issue}}) do
    previous = operation.issue

    if issue.id == previous.id and issue.identifier == previous.identifier and issue.source == previous.source and control_checkpoint_current?(operation) do
      advance(state, %{operation | issue: issue, phase: Map.fetch!(operation.prepared, :after_refresh)}, :start)
    else
      reject_control(state, operation, "control_invalidated")
    end
  end

  defp advance_control(state, %{phase: :refresh, origin: :seeded_local} = operation, {:ok, {:missing, :manual}}) do
    with true <- control_checkpoint_current?(operation),
         {:ok, raw} <- RunStateStore.load(operation.workspace),
         true <- Map.get(raw, :issue_source) in [:manual, "manual"],
         %Issue{} = issue <- Orchestrator.seeded_manual_issue_from_run_state(raw),
         true <- issue.id == operation.issue.id and issue.identifier == operation.identifier do
      advance(state, %{operation | issue: issue, phase: Map.fetch!(operation.prepared, :after_refresh)}, :start)
    else
      _ -> reject_control(state, operation, "control_invalidated")
    end
  end

  defp advance_control(state, %{phase: :refresh} = operation, _checked_rejection),
    do: reject_control(state, operation, "control_read_failed")

  defp advance_control(state, %{phase: :admitting} = operation, {:admission, outcome}) do
    case operation.action do
      :retry_now ->
        finish_retry_control(state, operation, outcome)

      action when action in [:approve_for_merge, :approve_for_deploy] ->
        case outcome do
          {:error, reason} -> domain_control_error(state, operation, reason)
          outcome when outcome in [:dispatched, :already_running, :retry_scheduled, :deferred] -> advance(state, %{operation | phase: :ledger}, :start)
        end
    end
  end

  defp advance_control(state, %{phase: :ready, action: :pause} = operation, :start) do
    issue = operation.issue
    {class, source, override} = Orchestrator.policy_snapshot_values(issue, state)
    operation = %{operation | prepared: %{policy_class: class, policy_source: source, policy_override: override}, phase: :pause_writer}
    advance(state, operation, :start)
  end

  defp advance_control(state, %{phase: :pause_writer} = operation, :start) do
    issue = operation.issue
    operation = %{operation | phase: :pause_runtime}

    case maybe_update_issue_state(issue.id, issue.state, @paused_state) do
      :ok -> advance(state, record_control_effect(operation, :pause_writer, :ok), :start)
      {:error, reason} -> domain_control_error(state, record_control_effect(operation, :pause_writer, {:error, reason}), reason)
    end
  end

  defp advance_control(state, %{phase: :pause_runtime} = operation, :start) do
    state = state |> Orchestrator.terminate_running_issue(operation.issue.id, false) |> cancel_retry(operation.issue.id) |> put_paused_issue(operation.issue)
    p = operation.prepared
    response = %{state: @paused_state, policy_class: p.policy_class, policy_source: p.policy_source}
    ledger = %{summary: "Paused issue from dashboard.", target_state: @paused_state, policy_class: p.policy_class, metadata: %{policy_source: p.policy_source, policy_override: p.policy_override}}
    finish_control_action(state, operation, response, ledger)
  end

  defp advance_control(state, %{phase: :ready, action: :resume} = operation, :start) do
    with {:ok, entry} <- paused_issue_entry(state, operation.identifier),
         true <- entry == operation.prepared.paused or {:error, :control_invalidated},
         :ok <- DeployAudit.ensure_available(operation.workspace) do
      operation = %{operation | phase: :resume_writer}
      advance(state, operation, :start)
    else
      {:error, :control_invalidated} -> reject_control(state, operation, "control_invalidated")
      {:error, reason} -> domain_control_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :resume_writer} = operation, :start) do
    entry = operation.prepared.paused

    case IssueSource.update_issue_state(paused_issue_ref(entry), entry.resume_state) do
      :ok -> advance(state, record_control_effect(%{operation | phase: :resume_runtime}, :resume_writer, :ok), :start)
      {:error, reason} -> domain_control_error(state, record_control_effect(operation, :resume_writer, {:error, reason}), reason)
    end
  end

  defp advance_control(state, %{phase: :resume_runtime} = operation, :start) do
    entry = operation.prepared.paused
    state = clear_paused_issue(state, entry.issue_id)
    operation = %{operation | prepared: Map.put(operation.prepared, :issue_id, entry.issue_id)}
    finish_control_action(state, operation, %{state: entry.resume_state}, %{summary: "Resumed paused issue.", target_state: entry.resume_state, metadata: %{resume_state: entry.resume_state}}, true)
  end

  defp advance_control(state, %{phase: :ready, action: :stop} = operation, :start) do
    result =
      IssueSource.create_comment(
        operation.issue,
        "## Symphony operator stop\n\nRule ID: operator.stop\n\nFailure class: policy\n\nStopped by dashboard control.\n\nUnblock action: Move the issue back to an active state when it should run again."
      )

    case result do
      :ok -> advance(state, record_control_effect(%{operation | phase: :stop_writer}, :stop_comment, result), :start)
      {:error, reason} -> domain_control_error(state, record_control_effect(operation, :stop_comment, result), reason)
    end
  end

  defp advance_control(state, %{phase: :stop_writer} = operation, :start) do
    case IssueSource.update_issue_state(operation.issue, @blocked_state) do
      :ok -> advance(state, record_control_effect(%{operation | phase: :stop_runtime}, :stop_writer, :ok), :start)
      {:error, reason} -> domain_control_error(state, record_control_effect(operation, :stop_writer, {:error, reason}), reason)
    end
  end

  defp advance_control(state, %{phase: :stop_runtime} = operation, :start) do
    issue = operation.issue
    {class, source, _} = Orchestrator.policy_snapshot_values(issue, state)
    state = state |> Orchestrator.terminate_running_issue(issue.id, false) |> cancel_retry(issue.id) |> clear_paused_issue(issue.id)

    finish_control_action(state, operation, %{state: @blocked_state, policy_class: class, policy_source: source}, %{
      policy_class: class,
      failure_class: "policy",
      rule_id: "operator.stop",
      summary: "Stopped issue from dashboard.",
      details: "Moved issue to #{@blocked_state}.",
      target_state: @blocked_state,
      metadata: %{policy_source: source}
    })
  end

  defp advance_control(state, %{phase: :ready, action: :hold_for_human_review} = operation, :start) do
    {class, source, _} = Orchestrator.policy_snapshot_values(operation.issue, state)
    target = WorkflowProfile.approval_gate_state(class, policy_pack: Orchestrator.policy_pack_name(operation.issue, state))
    operation = %{operation | prepared: %{policy_class: class, policy_source: source, target: target}, phase: :hold_writer}
    advance(state, operation, :start)
  end

  defp advance_control(state, %{phase: :hold_writer} = operation, :start) do
    case IssueSource.update_issue_state(operation.issue, operation.prepared.target) do
      :ok -> advance(state, record_control_effect(%{operation | phase: :hold_runtime}, :hold_writer, :ok), :start)
      {:error, reason} -> domain_control_error(state, record_control_effect(operation, :hold_writer, {:error, reason}), reason)
    end
  end

  defp advance_control(state, %{phase: :hold_runtime} = operation, :start) do
    p = operation.prepared
    state = state |> Orchestrator.terminate_running_issue(operation.issue.id, false) |> cancel_retry(operation.issue.id) |> clear_paused_issue(operation.issue.id)

    finish_control_action(state, operation, %{state: p.target, policy_class: p.policy_class, policy_source: p.policy_source}, %{
      policy_class: p.policy_class,
      failure_class: "policy",
      rule_id: "operator.hold_for_human_review",
      summary: "Placed issue in #{p.target}.",
      details: "Operator requested a manual review hold.",
      target_state: p.target,
      metadata: %{policy_source: p.policy_source, approval_gate_state: p.target}
    })
  end

  defp advance_control(state, %{phase: :ready, action: :reprioritize, args: [rank]} = operation, :start) do
    overrides = if is_nil(rank), do: Map.delete(state.priority_overrides, operation.identifier), else: Map.put(state.priority_overrides, operation.identifier, rank)
    finish_control_action(%{state | priority_overrides: overrides}, operation, %{override_rank: rank}, %{summary: "Updated queue priority override.", metadata: %{override_rank: rank}})
  end

  defp advance_control(state, %{phase: :ready, action: action} = operation, :start) when action in [:set_policy_class, :clear_policy_override] do
    policy = if action == :set_policy_class, do: operation.prepared.policy, else: nil
    overrides = if is_nil(policy), do: Map.delete(state.policy_overrides, operation.identifier), else: Map.put(state.policy_overrides, operation.identifier, policy)
    advance(%{state | policy_overrides: overrides}, %{operation | phase: :policy_snapshot}, :start)
  end

  defp advance_control(state, %{phase: :policy_snapshot} = operation, :start) do
    policy = if operation.action == :set_policy_class, do: operation.prepared.policy, else: nil

    result =
      case File.stat(operation.workspace) do
        {:ok, _stat} ->
          with :ok <- control_deadline(operation), {:ok, _} <- RunStateStore.update(operation.workspace, operation.issue, &Map.put(&1, :policy_override, policy)), do: :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end

    operation = record_control_effect(operation, :policy_snapshot, result)

    case result do
      :ok ->
        source = if is_nil(policy), do: "label_or_default", else: "override"
        summary = if is_nil(policy), do: "Cleared policy override for issue.", else: "Set policy override for issue."
        finish_control_action(state, operation, %{policy_class: policy, policy_source: source}, %{summary: summary, policy_class: policy, metadata: %{policy_source: source}})

      {:error, :control_deadline_exceeded} ->
        reject_control(state, operation, "control_deadline_exceeded")

      {:error, reason} ->
        domain_control_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :ready, action: action} = operation, :start)
       when action in [:refresh_merge_readiness, :approve_for_merge, :approve_for_deploy] or action in @thread_actions or action == :post_review_drafts do
    with :ok <- DeployAudit.ensure_available(operation.workspace),
         false <- action == :refresh_merge_readiness and Orchestrator.issue_paused?(state, operation.issue) do
      advance(state, %{operation | phase: :prepare_action}, :start)
    else
      true -> domain_control_error(state, operation, "issue is paused")
      {:error, reason} -> domain_control_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :prepare_action, action: :approve_for_merge} = operation, :start) do
    {class, source, _} = Orchestrator.policy_snapshot_values(operation.issue, state)

    if class == "never_automerge" do
      domain_control_error(state, operation, "policy forbids automerge")
    else
      operation = %{operation | prepared: %{policy_class: class, policy_source: source}, phase: :approve_merge_writer}
      advance(state, operation, :start)
    end
  end

  defp advance_control(state, %{phase: :approve_merge_writer, origin: :seeded_local} = operation, :start),
    do: request_control_refresh(state, record_control_effect(operation, :approve_merge_writer, :not_applicable), :approve_merge_snapshot)

  defp advance_control(state, %{phase: :approve_merge_writer} = operation, :start) do
    case IssueSource.update_issue_state(operation.issue, @merging_state) do
      :ok -> request_control_refresh(state, record_control_effect(operation, :approve_merge_writer, :ok), :approve_merge_snapshot)
      {:error, reason} -> domain_control_error(state, record_control_effect(operation, :approve_merge_writer, {:error, reason}), reason)
    end
  end

  defp advance_control(state, %{phase: :approve_merge_snapshot} = operation, :start) do
    attrs = %{review_approved: true, automerge_disabled: false, stop_reason: nil, last_decision: nil, last_rule_id: nil, last_failure_class: nil, last_decision_summary: nil, next_human_action: nil}

    case RunStateStore.update(operation.workspace, operation.issue, &Map.merge(&1, attrs)) do
      {:ok, _} = result -> advance(state, record_control_effect(%{operation | phase: :approval_dispatch}, :approve_merge_snapshot, result), :start)
      {:error, reason} = result -> domain_control_error(state, record_control_effect(operation, :approve_merge_snapshot, result), reason)
    end
  end

  defp advance_control(state, %{phase: :prepare_action, action: :approve_for_deploy} = operation, :start) do
    {class, source, _} = Orchestrator.policy_snapshot_values(operation.issue, state)
    operation = %{operation | phase: :approve_deploy_snapshot, prepared: %{policy_class: class, policy_source: source}}
    advance(state, operation, :start)
  end

  defp advance_control(state, %{phase: :approve_deploy_snapshot} = operation, :start) do
    issue = operation.issue

    attrs = %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_source: issue.source,
      effective_policy_class: operation.prepared.policy_class,
      deploy_approved: true,
      stop_reason: nil,
      last_decision: nil,
      last_rule_id: nil,
      last_failure_class: nil,
      last_decision_summary: "Operator approved production deployment.",
      next_human_action: nil,
      current_deploy_target: "production"
    }

    case RunStateStore.transition(operation.workspace, "deploy_production", attrs) do
      {:ok, _} = result -> advance(state, record_control_effect(%{operation | phase: :approve_deploy_writer}, :approve_deploy_snapshot, result), :start)
      {:error, reason} = result -> domain_control_error(state, record_control_effect(operation, :approve_deploy_snapshot, result), reason)
    end
  end

  defp advance_control(state, %{phase: :approve_deploy_writer, origin: :seeded_local} = operation, :start),
    do: request_control_refresh(state, record_control_effect(operation, :approve_deploy_writer, :not_applicable), :approval_dispatch)

  defp advance_control(state, %{phase: :approve_deploy_writer} = operation, :start) do
    case IssueSource.update_issue_state(operation.issue, "In Progress") do
      :ok -> request_control_refresh(state, record_control_effect(operation, :approve_deploy_writer, :ok), :approval_dispatch)
      {:error, reason} -> domain_control_error(state, record_control_effect(operation, :approve_deploy_writer, {:error, reason}), reason)
    end
  end

  defp advance_control(state, %{phase: :approval_dispatch} = operation, :start) do
    merge? = operation.action == :approve_for_merge
    target = if merge?, do: @merging_state, else: "In Progress"
    summary = if merge?, do: "Approved issue for merge.", else: "Approved issue for production deployment."
    p = operation.prepared

    operation = %{
      operation
      | response: %{state: target, policy_class: p.policy_class, policy_source: p.policy_source},
        ledger: %{policy_class: p.policy_class, summary: summary, target_state: target, metadata: %{policy_source: p.policy_source}}
    }

    cond do
      Map.has_key?(state.running, operation.issue.id) ->
        advance(state, %{operation | phase: :ledger}, :start)

      Orchestrator.retry_candidate_issue?(operation.issue, Orchestrator.terminal_state_set()) and Orchestrator.dispatch_slots_available?(operation.issue, state) ->
        {:admit, %{operation | phase: :admitting}, operation.issue, nil, state}

      true ->
        advance(state, %{operation | phase: :tick}, :start)
    end
  end

  defp advance_control(state, %{phase: :prepare_action, action: :refresh_merge_readiness} = operation, :start) do
    with {:ok, run_state} <- RunStateStore.load(operation.workspace),
         pr_url when is_binary(pr_url) and pr_url != "" <- Map.get(run_state, :pr_url),
         :ok <- ensure_merge_readiness_restartable(state, operation.issue.id) do
      advance(state, %{operation | phase: :merge_readiness_writer, prepared: %{pr_url: pr_url}}, :start)
    else
      nil -> domain_control_error(state, operation, "pr url not found")
      {:error, :active_stage_running} -> domain_control_error(state, operation, "issue is currently running an active stage")
      {:error, :missing} -> domain_control_error(state, operation, :missing)
      {:error, reason} -> control_snapshot_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :merge_readiness_writer} = operation, :start) do
    case maybe_update_issue_state(operation.issue.id, operation.issue.state, @merging_state) do
      :ok -> advance(state, record_control_effect(%{operation | phase: :merge_readiness_snapshot}, :merge_readiness_writer, :ok), :start)
      {:error, reason} -> domain_control_error(state, record_control_effect(operation, :merge_readiness_writer, {:error, reason}), reason)
    end
  end

  defp advance_control(state, %{phase: :merge_readiness_snapshot} = operation, :start) do
    issue = operation.issue

    attrs = %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_source: issue.source,
      pr_url: operation.prepared.pr_url,
      await_checks_polls: 0,
      stop_reason: nil,
      last_rule_id: "operator.refresh_merge_readiness",
      last_failure_class: "pr_hygiene",
      last_decision_summary: "Operator requested a merge-readiness refresh.",
      next_human_action: nil
    }

    case RunStateStore.transition(operation.workspace, "merge_readiness", attrs) do
      {:ok, _} = result -> advance(state, record_control_effect(%{operation | phase: :merge_readiness_runtime}, :merge_readiness_snapshot, result), :start)
      {:error, reason} = result -> domain_control_error(state, record_control_effect(operation, :merge_readiness_snapshot, result), reason)
    end
  end

  defp advance_control(state, %{phase: :merge_readiness_runtime} = operation, :start) do
    state = state |> maybe_restart_passive_issue(operation.issue.id) |> cancel_retry(operation.issue.id) |> clear_paused_issue(operation.issue.id)

    finish_control_action(
      state,
      operation,
      %{stage: "merge_readiness", pr_url: operation.prepared.pr_url},
      %{summary: "Requested merge-readiness refresh.", target_state: @merging_state, metadata: %{pr_url: operation.prepared.pr_url}},
      true
    )
  end

  defp advance_control(state, %{phase: :prepare_action, action: action} = operation, :start) when action in @thread_actions do
    with {:ok, run_state} <- RunStateStore.load(operation.workspace),
         threads when is_map(threads) and map_size(threads) > 0 <- Map.get(run_state, :review_threads, %{}),
         {:ok, updated, count, summary, human} <- apply_review_thread_action(Atom.to_string(action), threads) do
      advance(state, %{operation | phase: :review_snapshot, prepared: %{threads: updated, count: count, summary: summary, human: human}}, :start)
    else
      %{} -> domain_control_error(state, operation, "no review threads")
      {:error, :no_changes} -> domain_control_error(state, operation, "no review threads matched the requested transition")
      {:error, reason} -> control_snapshot_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :review_snapshot} = operation, :start) do
    p = operation.prepared
    result = RunStateStore.update(operation.workspace, operation.issue, &Map.merge(&1, %{review_threads: p.threads, last_decision_summary: p.summary, next_human_action: p.human}))
    operation = record_control_effect(operation, :review_snapshot, result)

    case result do
      {:ok, _} -> finish_control_action(state, operation, %{changed_threads: p.count}, %{summary: p.summary, metadata: %{changed_threads: p.count}})
      {:error, reason} -> domain_control_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :prepare_action, action: :post_review_drafts} = operation, :start) do
    with {:ok, {:present, expected}, run_state} <- RunStateStore.read_admission_source(operation.workspace, operation.issue),
         threads when is_map(threads) and map_size(threads) > 0 <- expected["review_threads"],
         pr when is_binary(pr) and pr != "" <- expected["pr_url"] do
      p = %{threads: threads, pr_url: pr, policy_pack: Orchestrator.policy_pack_name(operation.issue, state, run_state), expected: expected}
      advance(state, %{operation | phase: :post_review_writer, prepared: p}, :start)
    else
      {:ok, :missing, _view} -> domain_control_error(state, operation, "run state not found")
      %{} -> domain_control_error(state, operation, "no review threads")
      nil -> domain_control_error(state, operation, "pr url not found")
      {:error, reason} -> control_snapshot_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :post_review_writer} = operation, :start) do
    p = operation.prepared

    result =
      with {:ok, caller} <- publication_caller(operation) do
        precondition = %{kind: :control, context: operation.context, deadline: operation.deadline, expected: p.expected, caller: caller}

        ReviewPublication.publish(operation.workspace, operation.issue, p.pr_url, p.threads, precondition,
          policy_pack: p.policy_pack,
          company_name: Config.company_name(),
          repo_url: Config.company_repo_url()
        )
      end

    operation = record_control_effect(operation, :post_review_writer, result)

    case result do
      {:ok, threads, %{posted_count: posted, skipped_count: skipped, reconciled_count: reconciled, observation_ids: observations}} ->
        fields = ~w(draft_state posted_reply_id posted_reply_url posted_at reply_refresh_needed)

        patches =
          Map.new(
            Enum.flat_map(threads, fn {key, thread} ->
              patch = Map.take(thread, fields)
              if patch != Map.take(Map.fetch!(p.threads, key), fields), do: [{key, patch}], else: []
            end)
          )

        prepared = %{patches: patches, expected: p.expected, posted: posted, skipped: skipped, reconciled: reconciled, observations: observations}
        advance(state, %{operation | phase: :posted_review_snapshot, prepared: prepared}, :start)

      {:error, %RunLedger.PersistenceError{} = error} ->
        publication_control_error(state, operation, "review_publication_persistence_#{error.phase}", error.event_id)

      {:error, {:review_publication_blocked, cause, event_id}} ->
        publication_control_error(state, operation, "review_publication_#{cause}", event_id)

      {:error, reason} ->
        publication_control_error(state, operation, publication_failure_code(reason), nil)
    end
  end

  defp advance_control(state, %{phase: :posted_review_snapshot} = operation, :start) do
    p = operation.prepared

    result =
      with {:ok, _caller} <- publication_caller(operation) do
        RunStateStore.apply_review_publication(operation.workspace, operation.issue, p.expected, p.patches, operation.deadline)
      end

    operation = record_control_effect(operation, :posted_review_snapshot, result)

    case result do
      {:ok, _} ->
        finish_control_action(state, operation, %{posted_threads: p.posted, skipped_threads: p.skipped, reconciled_threads: p.reconciled}, %{
          summary: "Posted approved PR review replies.",
          metadata: %{posted_threads: p.posted, skipped_threads: p.skipped, reconciled_threads: p.reconciled, publication_observation_ids: p.observations}
        })

      {:error, reason} ->
        publication_control_error(state, operation, publication_failure_code(reason), nil)
    end
  end

  defp advance_control(state, %{phase: :ready, action: :retry_now} = operation, :start) do
    issue = operation.issue

    with :ok <- DeployAudit.ensure_available(operation.workspace),
         false <- Orchestrator.issue_paused?(state, issue),
         :ok <- control_deadline(operation),
         {:ok, next_state} <- Orchestrator.prepare_retry_custody(state, issue.id) do
      advance(next_state, %{operation | phase: :retry_prepare}, :start)
    else
      true ->
        domain_control_error(state, operation, "issue is paused")

      {:error, reason, retained} ->
        payload = control_domain_payload(operation, inspect(reason)) |> Map.put(:dispatch_outcome, "deferred")
        {:rejected, operation, payload, retained}

      {:error, reason} ->
        domain_control_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :retry_prepare} = operation, :start) do
    case RunStateStore.load_checked(operation.workspace, operation.issue) do
      {:ok, raw} ->
        resumable? = operation.issue.state == @blocked_state or Map.get(raw, :stage) == "blocked" or (manual_control_issue?(operation.issue) and Map.get(raw, :stage) not in [nil, "checkout", "done"])

        if resumable? do
          with {:ok, stage} <- resumable_stage_from_run_state(raw, operation.issue),
               target when is_binary(target) <- issue_state_for_stage(stage) do
            prepared = %{
              stage: stage,
              target: target,
              resume_context: retry_resume_context(raw, stage),
              manual_resume?: match?(%Issue{source: :manual, state: @blocked_state}, operation.issue)
            }

            advance(state, %{operation | phase: :retry_snapshot, prepared: prepared}, :start)
          else
            _ -> domain_control_error(state, operation, :retry_resume_stage_missing)
          end
        else
          advance(state, %{operation | phase: :retry_writer, prepared: %{target: "Todo"}}, :start)
        end

      {:mismatch, _raw} ->
        advance(state, %{operation | phase: :retry_snapshot, prepared: %{stage: "checkout", target: "Todo", resume_context: %{}}}, :start)

      {:error, reason} when reason in [:missing, :enoent] ->
        advance(state, %{operation | phase: :retry_writer, prepared: %{target: "Todo"}}, :start)

      {:error, reason} ->
        domain_control_error(state, operation, reason)
    end
  end

  defp advance_control(state, %{phase: :retry_snapshot} = operation, :start) do
    issue = operation.issue
    p = operation.prepared

    attrs = %{
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
      resume_context: p.resume_context
    }

    case RunStateStore.transition(operation.workspace, p.stage, attrs) do
      {:ok, persisted} = result ->
        prepared =
          if Map.get(p, :manual_resume?) do
            Map.put(p, :manual_resume_checkpoint, control_checkpoint(persisted))
          else
            p
          end

        advance(state, record_control_effect(%{operation | phase: :retry_writer, prepared: prepared}, :retry_snapshot, result), :start)

      {:error, reason} = result ->
        domain_control_error(state, record_control_effect(operation, :retry_snapshot, result), reason)
    end
  end

  defp advance_control(state, %{phase: :retry_writer, origin: :seeded_local} = operation, :start),
    do: request_control_refresh(state, record_control_effect(operation, :retry_writer, :not_applicable), :retry_dispatch)

  defp advance_control(state, %{phase: :retry_writer} = operation, :start) do
    case IssueSource.update_issue_state(operation.issue, operation.prepared.target) do
      :ok ->
        request_control_refresh(state, record_control_effect(operation, :retry_writer, :ok), :retry_dispatch)

      {:error, reason} ->
        retry_writer_failed(state, record_control_effect(operation, :retry_writer, {:error, reason}), reason)
    end
  end

  defp advance_control(state, %{phase: :retry_dispatch} = operation, :start) do
    state = cancel_retry(state, operation.issue.id)

    cond do
      Map.has_key?(state.running, operation.issue.id) ->
        finish_retry_control(state, operation, :already_running)

      Orchestrator.retry_candidate_issue?(operation.issue, Orchestrator.terminal_state_set()) and Orchestrator.dispatch_slots_available?(operation.issue, state) ->
        {:admit, %{operation | phase: :admitting}, operation.issue, 1, state}

      true ->
        finish_retry_control(state, operation, :deferred)
    end
  end

  defp advance_control(state, %{phase: :tick} = operation, :start) do
    :ok = Orchestrator.schedule_tick(0)
    advance(state, record_control_effect(%{operation | phase: :ledger}, :tick, :ok), :start)
  end

  defp advance_control(state, %{phase: :ledger} = operation, :start) do
    attrs =
      operation.ledger
      |> Map.put(:issue_identifier, operation.identifier)
      |> Map.put(:issue_id, if(operation.issue, do: operation.issue.id, else: Map.get(operation.prepared, :issue_id)))
      |> Map.put(:actor_type, "operator")
      |> Map.put(:actor_id, "dashboard")
      |> Map.update(:metadata, %{action: Atom.to_string(operation.action)}, &Map.put(&1, :action, Atom.to_string(operation.action)))

    event = RunLedger.record("operator.action", attrs)
    operation = record_control_effect(operation, :operator_ledger, event)
    payload = Map.merge(%{ok: true, action: Atom.to_string(operation.action), issue_identifier: operation.identifier, ledger_event_id: Map.get(event, :event_id)}, operation.response)

    state =
      if operation.action == :pause do
        p = operation.prepared

        put_paused_policy_metadata(state, operation.issue.id, %{
          policy_class: p.policy_class,
          policy_source: p.policy_source,
          policy_override: p.policy_override,
          next_human_action: "Resume the issue when it should re-enter active work.",
          last_ledger_event_id: Map.get(event, :event_id)
        })
      else
        state
      end

    case control_deadline(operation) do
      :ok -> {:done, operation, payload, state}
      {:error, _} -> reject_control(state, operation, "control_deadline_exceeded")
    end
  end

  # A denied manual-store write does not erase a confirmed local resume. The
  # captured checkpoint is never replaced by a later read or a caller snapshot.
  defp retry_writer_failed(state, %{issue: %Issue{source: :manual, state: @blocked_state}, prepared: %{manual_resume_checkpoint: _}} = operation, reason)
       when reason in [:eacces, :eperm, :erofs] do
    evidence = %{writer_error: Atom.to_string(reason), store_updated: false, stage: operation.prepared.stage, target_state: operation.prepared.target}
    operation = %{operation | prepared: Map.put(operation.prepared, :manual_resume, evidence)}
    %{id: id, identifier: identifier, source: source} = operation.issue

    with :ok <- manual_resume_current(operation),
         {:ok, {:issue, :manual, %Issue{id: ^id, identifier: ^identifier, source: ^source, state: @blocked_state} = current}} <-
           IssueSource.fetch_issue_checked(%{id: id, identifier: identifier, source: source}, operation.context),
         :ok <- manual_resume_current(operation) do
      issue = %{current | state: operation.prepared.target}
      advance(state, %{operation | issue: issue, phase: :retry_dispatch}, :start)
    else
      {:error, :control_deadline_exceeded} -> reject_manual_resume(state, operation, "control_deadline_exceeded")
      _ -> reject_manual_resume(state, operation, "control_invalidated")
    end
  end

  defp retry_writer_failed(state, operation, reason), do: domain_control_error(state, operation, reason)

  defp manual_resume_current(operation) do
    p = operation.prepared
    {projection, identity} = p.manual_resume_checkpoint

    with :ok <- control_phase_boundary(operation),
         caller when is_pid(caller) <- Map.get(operation, :caller),
         true <- node(caller) == node() and Process.alive?(caller),
         true <- identity[:issue_id] == operation.issue.id and identity[:issue_identifier] == operation.identifier,
         true <- projection["issue_source"] == "manual" and projection["stage"] == p.stage,
         true <- issue_state_for_stage(p.stage) == p.target,
         true <- projection["resume_context"] == RunStateStore.coordinator_projection(%{resume_context: p.resume_context})["resume_context"],
         {:ok, checkpoint} <- read_control_checkpoint(operation),
         true <- checkpoint == p.manual_resume_checkpoint,
         :ok <- control_phase_boundary(operation),
         true <- Process.alive?(caller) do
      :ok
    else
      {:error, :control_deadline_exceeded} = error -> error
      _ -> {:error, :control_invalidated}
    end
  end

  defp reject_manual_resume(state, operation, error) do
    {:rejected, operation, manual_resume_evidence(control_rejection(operation, error), operation), state}
  end

  defp manual_resume_evidence(payload, %{prepared: %{manual_resume: evidence}}), do: Map.put(payload, :manual_resume, evidence)
  defp manual_resume_evidence(payload, _operation), do: payload

  defp request_control_refresh(state, operation, next_phase) do
    with {:ok, checkpoint} <- read_control_checkpoint(operation),
         :ok <- control_deadline(operation) do
      operation = %{operation | phase: :refresh, checkpoint: checkpoint, prepared: Map.put(operation.prepared, :after_refresh, next_phase)}
      {:read, operation, {:refresh, %{id: operation.issue.id, identifier: operation.issue.identifier, source: operation.issue.source}}, state}
    else
      {:error, :control_deadline_exceeded} -> reject_control(state, operation, "control_deadline_exceeded")
      {:error, _reason} -> reject_control(state, operation, "control_invalidated")
    end
  end

  defp read_control_checkpoint(operation) do
    with :ok <- DeployAudit.ensure_available(operation.workspace) do
      case RunStateStore.load(operation.workspace) do
        {:ok, raw} -> {:ok, control_checkpoint(raw)}
        {:error, :missing} -> {:ok, :missing}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp control_checkpoint(raw) do
    {RunStateStore.coordinator_projection(raw), Map.take(raw, ~w(issue_id issue_identifier run_id run_identity_event_id run_identity_ledger_path)a)}
  end

  defp control_checkpoint_current?(operation) do
    case read_control_checkpoint(operation) do
      {:ok, checkpoint} -> checkpoint == operation.checkpoint
      {:error, _reason} -> false
    end
  end

  defp finish_control_action(state, operation, response, ledger, tick? \\ false) do
    advance(state, %{operation | response: response, ledger: ledger, phase: if(tick?, do: :tick, else: :ledger)}, :start)
  end

  defp finish_retry_control(state, operation, outcome) do
    reply =
      case outcome do
        :dispatched ->
          %{ok: true, dispatch_outcome: "dispatched", summary: "Immediate retry dispatched the issue."}

        :already_running ->
          %{ok: true, dispatch_outcome: "already_running", summary: "Immediate retry skipped because the issue is already running."}

        :retry_scheduled ->
          %{ok: true, dispatch_outcome: "retry_scheduled", summary: "Immediate retry could not dispatch immediately and scheduled a retry."}

        :deferred ->
          diagnostic = retry_control_diagnostic(operation.issue, state)
          Map.merge(%{ok: true, dispatch_outcome: "deferred", error: diagnostic.summary}, diagnostic)

        {:error, reason} ->
          %{ok: false, dispatch_outcome: "deferred", error: inspect(reason), summary: "Immediate retry was rejected before dispatch."}
      end

    reply = manual_resume_evidence(reply, operation)

    ledger = %{
      summary: reply.summary,
      details: retry_issue_now_details(reply),
      metadata: retry_issue_now_metadata(reply),
      failure_class: Map.get(reply, :failure_class),
      rule_id: Map.get(reply, :rule_id)
    }

    finish_control_action(state, operation, Map.drop(reply, [:summary]), ledger, outcome == :deferred)
  end

  defp retry_control_diagnostic(issue, state) do
    cond do
      Orchestrator.available_slots(state) <= 0 ->
        retry_issue_now_rule(:dispatch_slots_unavailable, "Immediate retry deferred because no orchestrator dispatch slots are available.", %{
          issue_state: issue.state,
          running_count: map_size(state.running)
        })

      not Orchestrator.state_slots_available?(issue, state.running) ->
        retry_issue_now_rule(:dispatch_slots_unavailable, "Immediate retry deferred because #{issue.state} is already at its per-state concurrency limit.", %{
          issue_state: issue.state,
          running_count: map_size(state.running)
        })

      not Orchestrator.retry_candidate_issue?(issue, Orchestrator.terminal_state_set()) ->
        retry_issue_now_ineligible_diagnostic(issue, state)

      true ->
        retry_issue_now_rule(:retry_dispatch_deferred, "Immediate retry was accepted, but dispatch produced no visible runtime state change.", %{issue_state: issue.state})
    end
  end

  defp control_snapshot_error(state, operation, reason) when reason in [:enoent, :missing], do: domain_control_error(state, operation, "run state not found")
  defp control_snapshot_error(state, operation, reason), do: domain_control_error(state, operation, reason)

  defp control_phase_boundary(operation) do
    with :ok <- control_deadline(operation),
         :ok <- Config.validate!(),
         current = Config.tracker_read_context(),
         true <- current.fingerprint == operation.context.fingerprint,
         true <- Workspace.path_for_issue(operation.identifier) == operation.workspace,
         :ok <- control_deadline(operation) do
      :ok
    else
      {:error, :control_deadline_exceeded} = error -> error
      false -> {:error, :control_invalidated}
      {:error, _reason} -> {:error, :control_invalidated}
    end
  rescue
    _error in NimbleOptions.ValidationError -> {:error, :control_invalidated}
  end

  defp control_deadline(operation) do
    if System.monotonic_time(:millisecond) < operation.deadline, do: :ok, else: {:error, :control_deadline_exceeded}
  end

  defp record_control_effect(operation, effect, result), do: %{operation | effect?: true, last_effect: {effect, result}}
  defp control_rejection(operation, error), do: Map.put(control_domain_payload(operation, error), :effect_status, if(operation.effect?, do: "unknown", else: "not_started"))
  defp control_domain_payload(operation, error), do: %{ok: false, action: Atom.to_string(operation.action), issue_identifier: operation.identifier, error: error}
  defp reject_control(state, operation, error), do: {:rejected, operation, control_rejection(operation, error), state}

  # Captured by the owner from the real GenServer from, never from the request
  # or a remote reservation (local/manual controls need no such reservation).
  defp publication_caller(%{caller: caller}) when is_pid(caller) and node(caller) == node() do
    if Process.alive?(caller), do: {:ok, caller}, else: {:error, {:review_publication_blocked, :control_invalidated, nil}}
  end

  defp publication_failure_code({:review_publication_blocked, cause, _event_id}) when is_atom(cause), do: "review_publication_#{cause}"
  defp publication_failure_code(%Jason.DecodeError{}), do: "review_publication_snapshot_decode"
  defp publication_failure_code({:coordinator_snapshot_cleanup_failed, _primary, _cleanup}), do: "review_publication_snapshot_cleanup_failed"
  defp publication_failure_code({:coordinator_precondition_failed, cause}) when is_atom(cause), do: "review_publication_#{cause}"
  defp publication_failure_code({:external_comment_posting_forbidden, _pack}), do: "external_comment_posting_forbidden"
  defp publication_failure_code({:credential_scope_forbidden, _provider, _operation}), do: "credential_scope_forbidden"
  defp publication_failure_code(reason) when is_atom(reason), do: "review_publication_#{reason}"
  defp publication_failure_code(_reason), do: "review_publication_checked_boundary_failure"

  defp publication_control_error(state, operation, cause, event_id) do
    payload = control_domain_payload(operation, cause) |> Map.put(:publication_event_id, event_id)

    case control_deadline(operation) do
      :ok -> {:rejected, operation, payload, state}
      {:error, _} -> reject_control(state, operation, "control_deadline_exceeded")
    end
  end

  defp domain_control_error(state, operation, reason) do
    case control_deadline(operation) do
      :ok -> {:rejected, operation, control_domain_payload(operation, if(is_binary(reason), do: reason, else: inspect(reason))), state}
      {:error, _} -> reject_control(state, operation, "control_deadline_exceeded")
    end
  end

  # -------------------------------------------------------------------
  # Controls-only helpers (private)
  # -------------------------------------------------------------------

  @doc false
  @spec maybe_schedule_manual_issue_refresh(State.t()) :: State.t()
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

  defp ensure_deploy_control_available(identifier) when is_binary(identifier) do
    case String.trim(identifier) do
      "" -> {:error, :blank_issue_identifier}
      trimmed -> DeployAudit.ensure_available(Workspace.path_for_issue(trimmed))
    end
  end

  @doc false
  @spec resolve_issue_for_control(State.t(), term()) :: {:ok, Issue.t()} | {:error, atom()}
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
      IssueSource.update_issue_state(issue_id, target_state)
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

  # -------------------------------------------------------------------
  # Retry helpers
  # -------------------------------------------------------------------

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
      manual_resume: Map.get(reply, :manual_resume),
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

  # -------------------------------------------------------------------
  # Resume helpers (retry_issue_now support)
  # -------------------------------------------------------------------

  @spec maybe_resume_blocked_issue(State.t(), Issue.t()) :: {State.t(), Issue.t()} | {:error, term()}
  def maybe_resume_blocked_issue(%State{} = state, %Issue{} = issue) do
    workspace = Workspace.path_for_issue(issue.identifier)

    location_matches =
      case Map.get(state.lease_claims, issue.id) do
        nil -> true
        %{workspace: captured} -> Path.expand(workspace) == Path.expand(captured)
      end

    with true <- location_matches or {:error, :lease_workspace_changed},
         :ok <- DeployAudit.ensure_available(workspace) do
      resume_available_blocked_issue(state, issue, workspace)
    end
  end

  defp resume_available_blocked_issue(state, issue, workspace) do
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

    case RunInspector.inspect(workspace, include_pr_details: false) do
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

        case RunInspector.inspect(workspace, include_pr_details: false) do
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
