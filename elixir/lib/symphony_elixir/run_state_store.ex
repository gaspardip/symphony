defmodule SymphonyElixir.RunStateStore do
  @moduledoc """
  Persists per-workspace runtime state so runs can resume from explicit stages.
  """

  alias SymphonyElixir.DeployAudit
  alias SymphonyElixir.DispatchAudit
  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Observability
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.RunnerRuntime
  alias SymphonyElixir.Config

  @relative_dir ".symphony"
  @filename "run_state.json"
  @stage_history_limit 25

  @spec state_path(Path.t()) :: Path.t()
  def state_path(workspace) when is_binary(workspace) do
    Path.join([workspace, @relative_dir, @filename])
  end

  @spec load(Path.t()) :: {:ok, map()} | {:error, :missing | term()}
  def load(workspace) when is_binary(workspace) do
    with {:ok, path} <- load_path(workspace),
         {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload),
         true <- is_map(decoded) or {:error, :invalid_state},
         :ok <- ensure_audit_complete(decoded),
         :ok <- SymphonyElixir.RunIdentity.validate_snapshot(decoded) do
      {:ok, atomize(decoded)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_audit_complete(%{"audit_pending" => pending}) when is_map(pending),
    do: {:error, {:audit_pending, Map.get(pending, "operation_id")}}

  defp ensure_audit_complete(%{"audit_pending" => _}), do: {:error, :invalid_audit_pending}
  defp ensure_audit_complete(_state), do: :ok

  defp load_path(workspace) when is_binary(workspace) do
    path = state_path(workspace)

    cond do
      File.exists?(path) ->
        {:ok, path}

      true ->
        case staged_bootstrap_state_path(workspace) do
          nil -> {:error, :missing}
          staged_path -> {:ok, staged_path}
        end
    end
  end

  defp staged_bootstrap_state_path(workspace) when is_binary(workspace) do
    basename = Path.basename(workspace)
    parent = Path.dirname(workspace)
    prefix = ".#{basename}.bootstrap-"

    parent
    |> File.ls()
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.map(&Path.join(parent, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(fn dir -> {dir, Path.join([dir, @filename])} end)
        |> Enum.filter(fn {_dir, path} -> File.exists?(path) end)
        |> Enum.max_by(
          fn {dir, _path} ->
            case File.stat(dir, time: :posix) do
              {:ok, stat} -> stat.mtime
              _ -> 0
            end
          end,
          fn -> nil end
        )
        |> case do
          {_dir, path} -> path
          nil -> nil
        end

      _ ->
        nil
    end
  end

  @spec load_checked(Path.t(), map()) :: {:ok, map()} | {:mismatch, map()} | {:error, :missing | term()}
  def load_checked(workspace, issue) when is_binary(workspace) and is_map(issue) do
    case load(workspace) do
      {:ok, state} ->
        if run_state_matches_issue?(state, issue) do
          {:ok, merge_defaults(state, issue)}
        else
          {:mismatch, state}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec load_or_default(Path.t(), map()) :: map()
  def load_or_default(workspace, issue) when is_binary(workspace) and is_map(issue) do
    case load(workspace) do
      {:ok, state} ->
        if run_state_matches_issue?(state, issue) do
          merge_defaults(state, issue)
        else
          default_state(issue)
        end

      {:error, :missing} ->
        default_state(issue)

      {:error, reason} ->
        unreadable_state(issue, reason)
    end
  end

  @spec ensure_readable(Path.t()) :: :ok | {:error, term()}
  def ensure_readable(workspace) when is_binary(workspace) do
    with :ok <- DeployAudit.ensure_available(workspace) do
      case load(workspace) do
        {:ok, _state} -> :ok
        {:error, :missing} -> :ok
        {:error, reason} -> {:error, unreadable_error(reason)}
      end
    end
  end

  @doc "Runs a workspace lifecycle operation while its readable snapshot is protected from local mutations."
  @spec with_readable_snapshot(Path.t(), (-> result)) :: result | {:error, term()} when result: var
  def with_readable_snapshot(workspace, fun) when is_binary(workspace) and is_function(fun, 0) do
    with_workspace_lock(workspace, fn ->
      with :ok <- ensure_readable(workspace), do: fun.()
    end)
  end

  defp load_for_update(workspace, issue) do
    case load_checked(workspace, issue) do
      {:ok, state} -> {:ok, state}
      {:mismatch, _state} -> {:ok, default_state(issue)}
      {:error, :missing} -> {:ok, default_state(issue)}
      {:error, reason} -> {:error, write_error(reason)}
    end
  end

  defp write_error(reason) when is_atom(reason) and reason != :invalid_state, do: reason
  defp write_error(reason), do: unreadable_error(reason)

  defp unreadable_error(%Jason.DecodeError{position: position}),
    do: {:run_state_unreadable, {:invalid_json, position}}

  defp unreadable_error(reason), do: {:run_state_unreadable, reason}

  defp unreadable_state(issue, {:audit_pending, operation_id}) do
    summary = "The persisted transition has an unconfirmed audit result; execution is blocked."
    action = "Reconcile the recorded operation before retrying. Preserve the snapshot and its ledger."

    default_state(issue)
    |> Map.merge(%{
      stage: "blocked",
      last_rule_id: "runtime.audit_pending",
      last_failure_class: "recovery",
      last_decision_summary: summary,
      next_human_action: action,
      stop_reason: %{
        code: "audit_pending",
        rule_id: "runtime.audit_pending",
        failure_class: "recovery",
        summary: summary,
        details: operation_id,
        human_action: action
      }
    })
  end

  defp unreadable_state(issue, reason) do
    summary = "The persisted run snapshot cannot be read; execution is blocked."
    action = "Restore a valid run_state.json from a trusted backup before retrying. The unreadable snapshot has been preserved."

    default_state(issue)
    |> Map.merge(%{
      stage: "blocked",
      last_rule_id: "runtime.snapshot_unreadable",
      last_failure_class: "recovery",
      last_decision_summary: summary,
      next_human_action: action,
      stop_reason: %{
        code: "snapshot_unreadable",
        rule_id: "runtime.snapshot_unreadable",
        failure_class: "recovery",
        summary: summary,
        details: inspect(unreadable_error(reason)),
        human_action: action
      }
    })
  end

  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(workspace, state) when is_binary(workspace) and is_map(state) do
    with_workspace_lock(workspace, fn -> save_unlocked(workspace, state) end)
  end

  @doc "Serializes local snapshot and workspace lifecycle changes, including dispatch admission."
  @spec with_workspace_lock(Path.t(), (-> result)) :: result when result: var
  def with_workspace_lock(workspace, fun) when is_binary(workspace) and is_function(fun, 0) do
    :global.trans({{__MODULE__, Path.expand(workspace)}, self()}, fun, [node()])
  end

  defp save_unlocked(workspace, state) do
    path = state_path(workspace)

    with {:ok, previous_state} <- load_for_update(workspace, %{}),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, state} <- SymphonyElixir.RunIdentity.preserve(state, previous_state) do
      state = preserve_token_usage(state, previous_state)
      write_json_atomically(path, ensure_runner_metadata(state))
    end
  end

  defp preserve_token_usage(state, previous_state) do
    issue = %{id: Map.get(state, :issue_id), identifier: Map.get(state, :issue_identifier)}

    if run_state_matches_issue?(previous_state, issue) and Map.has_key?(previous_state, :token_usage) do
      usage = Map.get(state, :token_usage, %{})
      previous_usage = Map.fetch!(previous_state, :token_usage)

      preserved =
        Map.new([:input_tokens, :output_tokens, :total_tokens], fn key ->
          {key, max(Map.get(usage, key, 0), Map.get(previous_usage, key, 0))}
        end)

      Map.put(state, :token_usage, preserved)
    else
      state
    end
  end

  @doc "Records legacy usage only when the snapshot has no complete or partial run identity."
  @spec record_token_usage(Path.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def record_token_usage(workspace, issue, usage) do
    with_workspace_lock(workspace, fn ->
      with :ok <- ensure_legacy_token_usage(workspace),
           {:ok, state} <- load_for_update(workspace, issue) do
        state = Map.put(state, :token_usage, usage)

        case save_unlocked(workspace, state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  @doc "Checks captured dispatch authority and records monotonic usage without creating or adopting a snapshot."
  @spec record_token_usage(Path.t(), map(), map(), %{ticket: DispatchAudit.ticket(), lease_token: LeaseManager.token()}) :: {:ok, map()} | {:error, term()}
  def record_token_usage(workspace, issue, usage, %{ticket: ticket, lease_token: token})
      when is_binary(workspace) and is_map(issue) and is_map(ticket) do
    with_workspace_lock(workspace, fn ->
      with :ok <- LeaseManager.ensure_current(token),
           {:ok, snapshot} <- read_token_usage_snapshot(state_path(workspace)),
           :ok <- ensure_audit_complete(snapshot),
           :ok <- SymphonyElixir.RunIdentity.validate_snapshot(snapshot),
           state = atomize(snapshot),
           :ok <- matching_token_usage_context(workspace, issue, state, ticket, token),
           {:ok, usage} <- monotonic_token_usage(state, usage) do
        DispatchAudit.with_authorization(ticket, fn ->
          state = Map.put(state, :token_usage, usage)

          with :ok <- DispatchAudit.ensure_workspace_access(workspace),
               :ok <- write_json_atomically(state_path(workspace), state) do
            {:ok, state}
          end
        end)
      end
    end)
  end

  def record_token_usage(_workspace, _issue, _usage, _context), do: {:error, :token_usage_context_mismatch}

  defp matching_token_usage_context(workspace, %{id: id, identifier: identifier}, state, ticket, token)
       when is_binary(id) and id != "" and is_binary(identifier) and identifier != "" do
    cond do
      ticket[:workspace] != Path.expand(workspace) or token.storage.issue_id != id or token.storage.ledger_path != ticket[:ledger_path] or
        token.owner != ticket[:owner] or token.epoch != ticket[:epoch] ->
        {:error, :token_usage_context_mismatch}

      state[:issue_id] != id or state[:issue_identifier] != identifier or not is_binary(ticket[:run_id]) or ticket[:run_id] == "" or state[:run_id] != ticket[:run_id] ->
        {:error, :token_usage_snapshot_mismatch}

      true ->
        :ok
    end
  end

  defp matching_token_usage_context(_workspace, _issue, _state, _ticket, _token), do: {:error, :token_usage_context_mismatch}

  defp monotonic_token_usage(state, usage) do
    previous = Map.get(state, :token_usage, %{input_tokens: 0, output_tokens: 0, total_tokens: 0})

    with :ok <- validate_token_usage(usage),
         :ok <- validate_token_usage(previous) do
      {:ok, Map.new([:input_tokens, :output_tokens, :total_tokens], fn key -> {key, max(Map.fetch!(usage, key), Map.fetch!(previous, key))} end)}
    end
  end

  defp validate_token_usage(%{input_tokens: input, output_tokens: output, total_tokens: total} = usage)
       when map_size(usage) == 3 and is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and is_integer(total) and total >= 0,
       do: :ok

  defp validate_token_usage(_usage), do: {:error, :invalid_token_usage}

  defp ensure_legacy_token_usage(workspace) do
    with {:ok, path} <- load_path(workspace),
         {:ok, snapshot} <- read_token_usage_snapshot(path) do
      if Enum.any?(["run_id", "run_identity_event_id", "run_identity_ledger_path", "run_identity_pending"], &Map.has_key?(snapshot, &1)),
        do: {:error, :token_usage_context_required},
        else: :ok
    else
      {:error, :missing} -> :ok
      {:error, reason} -> {:error, write_error(reason)}
    end
  end

  defp read_token_usage_snapshot(path) do
    with {:ok, payload} <- File.read(path),
         {:ok, snapshot} <- Jason.decode(payload),
         true <- is_map(snapshot) or {:error, :invalid_state} do
      {:ok, snapshot}
    else
      {:error, :enoent} -> {:error, :missing}
      {:error, _reason} = error -> error
    end
  end

  @spec transition(Path.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transition(workspace, stage, attrs \\ %{})
      when is_binary(workspace) and is_binary(stage) and is_map(attrs) do
    with_workspace_lock(workspace, fn ->
      with {:ok, previous_state} <- load_for_update(workspace, %{}) do
        transition_from_state(workspace, stage, attrs, previous_state)
      end
    end)
  end

  @doc "Checks a confirmed deploy against the current snapshot without changing it. Network work must remain outside this lock."
  @spec ensure_deploy_current(DeployAudit.ticket()) :: :ok | {:error, term()}
  def ensure_deploy_current(%{workspace: workspace} = ticket) do
    with_workspace_lock(workspace, fn ->
      with {:ok, context} <- DeployAudit.continuation_context(ticket),
           {:ok, state} <- load(workspace) do
        matching_deploy_snapshot(state, context)
      end
    end)
  end

  @doc "Advances a confirmed deploy once, preserving fresh lease and consumption metadata under one snapshot lock."
  @spec transition_deploy(DeployAudit.ticket(), String.t(), map()) :: {:ok, map(), DeployAudit.continuation()} | {:error, term()}
  def transition_deploy(%{workspace: workspace} = ticket, stage, attrs) when is_map(attrs) and stage in ["post_deploy_verify", "done"] do
    with_workspace_lock(workspace, fn ->
      with {:ok, context} <- DeployAudit.continuation_context(ticket),
           {:ok, previous_state} <- load(workspace),
           :ok <- matching_deploy_snapshot(previous_state, context),
           :ok <- validate_deploy_attrs(attrs),
           {:ok, state} <- transition_from_state(workspace, stage, deploy_attrs(attrs, context), previous_state, deploy_metadata(context)),
           :ok <- DeployAudit.ensure_ledger_path(context.ledger_path),
           {:ok, event} <- RunLedger.fetch_entry_checked(state.last_ledger_event_id) do
        {:ok, state, %{stage: stage, event: event}}
      end
    end)
  end

  def transition_deploy(_ticket, _stage, _attrs), do: {:error, :invalid_deploy_transition}

  defp matching_deploy_snapshot(state, context) do
    if state[:issue_id] == context.issue_id and state[:issue_identifier] == context.issue_identifier and state[:stage] == context.stage and
         state[:last_ledger_event_id] == context.entry_event_id and state[:lease_owner] == context.lease_owner and state[:lease_epoch] == context.lease_epoch and
         is_nil(state[:stop_reason]),
       do: :ok,
       else: {:error, :deploy_audit_snapshot_conflict}
  end

  defp validate_deploy_attrs(attrs) do
    allowed = [:issue_source, :last_decision_summary, :completed_at, :reason, :next_human_action, :stop_reason]

    if Enum.all?(Map.keys(attrs), &(&1 in allowed)) and is_nil(Map.get(attrs, :stop_reason)) and is_nil(Map.get(attrs, :next_human_action)),
      do: :ok,
      else: {:error, :invalid_deploy_transition_attrs}
  end

  defp deploy_attrs(attrs, context) do
    result_key = if context.target == "preview", do: :last_deploy_preview, else: :last_deploy_production

    attrs =
      attrs
      |> Map.put(result_key, context.result)
      |> Map.put(:last_deploy_operation_id, context.operation_id)
      |> Map.put(:current_deploy_target, context.target)
      |> Map.put(:last_decision, nil)

    if context.target == "production",
      do: Map.merge(attrs, %{deploy_window_wait: nil, deploy_approved: false}),
      else: attrs
  end

  defp deploy_metadata(context) do
    %{
      deploy_operation_id: context.operation_id,
      deploy_intent_event_id: context.intent_event_id,
      deploy_result_event_id: context.result_event_id
    }
  end

  defp transition_from_state(workspace, stage, attrs, previous_state, transition_metadata \\ %{}) do
    same_stage? = Map.get(previous_state, :stage) == stage

    state =
      previous_state
      |> Map.merge(attrs)
      |> preserve_token_usage(previous_state)
      |> Map.put(:stage, stage)
      |> maybe_record_stage_transition(stage, Map.get(attrs, :reason), same_stage?)

    if same_stage? do
      with :ok <- save_unlocked(workspace, state), do: {:ok, state}
    else
      commit_audited_transition(workspace, state, attrs, Map.get(previous_state, :stage), transition_metadata)
    end
  end

  defp commit_audited_transition(workspace, state, attrs, previous_stage, transition_metadata) do
    state = ensure_runner_metadata(state)
    operation_id = SymphonyElixir.Util.generate_id("op_")

    event_attrs = %{
      issue_id: Map.get(state, :issue_id),
      issue_identifier: Map.get(state, :issue_identifier),
      stage: state.stage,
      actor_type: "runtime",
      actor_id: "run_state_store",
      policy_class: Map.get(state, :effective_policy_class),
      summary: "Transitioned to #{state.stage}",
      details: Map.get(attrs, :reason),
      metadata:
        Map.merge(transition_metadata, %{
          operation_id: operation_id,
          previous_stage: previous_stage,
          snapshot_digest: snapshot_digest(state),
          stage_transition_count: get_in(state, [:stage_transition_counts, state.stage]),
          stage_history_size: length(Map.get(state, :stage_history, []))
        })
    }

    intent_attrs = Map.put(event_attrs, :summary, "Requested transition to #{state.stage}")

    with {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
         {:ok, intent} <- RunLedger.prepare_entry("stage.transition.requested", intent_attrs),
         {:ok, confirmation} <- RunLedger.prepare_entry("stage.transition", event_attrs),
         {:ok, _} <- RunLedger.persist_prepared(intent) do
      pending = %{
        operation_id: operation_id,
        ledger_path: ledger_path,
        intent_event_id: intent.event_id,
        confirmation: confirmation
      }

      with :ok <- save_unlocked(workspace, Map.put(state, :audit_pending, pending)),
           {:ok, _} <- RunLedger.persist_prepared(confirmation),
           {:ok, persisted} <- finalize_audited_transition(workspace, state, confirmation.event_id) do
        emit_transition(persisted)
        {:ok, persisted}
      end
    end
  end

  defp finalize_audited_transition(workspace, state, event_id) do
    persisted = state |> Map.delete(:audit_pending) |> Map.put(:last_ledger_event_id, event_id)
    with :ok <- write_json_atomically(state_path(workspace), persisted), do: {:ok, persisted}
  end

  defp emit_transition(state) do
    Observability.emit(
      [:symphony, :stage, :transition],
      %{count: 1},
      %{
        issue_id: Map.get(state, :issue_id),
        issue_identifier: Map.get(state, :issue_identifier),
        issue_source: Map.get(state, :issue_source),
        stage: state.stage,
        policy_class: Map.get(state, :effective_policy_class),
        stage_transition_count: get_in(state, [:stage_transition_counts, state.stage]),
        stage_history_size: length(Map.get(state, :stage_history, []))
      }
    )
  end

  @doc """
  Finalizes an interrupted transition only when both its intent and exact
  confirmation already exist in its original ledger. Missing or ambiguous
  evidence leaves the snapshot untouched; this never retries an audit write.
  """
  @spec reconcile_pending_transition(Path.t()) :: {:ok, map()} | {:error, term()}
  def reconcile_pending_transition(workspace) when is_binary(workspace) do
    with_workspace_lock(workspace, fn ->
      with {:ok, payload} <- File.read(state_path(workspace)),
           {:ok, decoded} <- Jason.decode(payload),
           {:ok, state, pending, confirmation} <- validate_pending_transition(decoded),
           {:ok, path} <- RunLedger.ledger_file_path_checked(),
           true <- path == pending["ledger_path"] or {:error, :audit_ledger_changed},
           {:ok, intent} <- RunLedger.fetch_entry_checked(pending["intent_event_id"]),
           :ok <- validate_transition_intent(intent, confirmation, pending),
           {:ok, recorded} <- RunLedger.fetch_entry_checked(confirmation["event_id"]),
           true <- recorded == confirmation or {:error, :audit_confirmation_mismatch} do
        finalize_audited_transition(workspace, atomize(state), confirmation["event_id"])
      end
    end)
  end

  defp validate_pending_transition(%{"audit_pending" => pending} = decoded) when is_map(pending) do
    state = Map.delete(decoded, "audit_pending")

    with %{
           "operation_id" => operation_id,
           "ledger_path" => ledger_path,
           "intent_event_id" => intent_id,
           "confirmation" =>
             %{
               "event_id" => event_id,
               "event_type" => "stage.transition",
               "stage" => stage,
               "metadata" => %{"operation_id" => operation_id, "snapshot_digest" => digest}
             } = confirmation
         } <- pending,
         true <- Enum.all?([operation_id, ledger_path, intent_id, event_id], &(is_binary(&1) and &1 != "")),
         true <- stage == state["stage"] and digest == snapshot_digest(state) do
      {:ok, state, pending, confirmation}
    else
      _ -> {:error, :invalid_audit_pending}
    end
  end

  defp validate_pending_transition(%{}), do: {:error, :no_audit_pending}
  defp validate_pending_transition(_), do: {:error, :invalid_state}

  defp validate_transition_intent(intent, confirmation, pending) do
    valid? =
      intent["event_type"] == "stage.transition.requested" and
        intent["event_id"] == pending["intent_event_id"] and
        intent["issue_id"] == confirmation["issue_id"] and
        intent["issue_identifier"] == confirmation["issue_identifier"] and
        intent["stage"] == confirmation["stage"] and
        intent["metadata"] == confirmation["metadata"]

    if valid?, do: :ok, else: {:error, :audit_intent_mismatch}
  end

  @doc "Canonical checksum shared by checked snapshot transitions and identity adoption."
  @spec snapshot_digest(map()) :: String.t()
  def snapshot_digest(state) do
    state
    |> Jason.encode!()
    |> Jason.decode!()
    |> canonical_snapshot()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_snapshot(value) when is_map(value),
    do: {:map, value |> Enum.map(fn {key, item} -> {key, canonical_snapshot(item)} end) |> Enum.sort()}

  defp canonical_snapshot(value) when is_list(value), do: Enum.map(value, &canonical_snapshot/1)
  defp canonical_snapshot(value), do: value

  @spec update(Path.t(), (map() -> map())) :: {:ok, map()} | {:error, term()}
  def update(workspace, fun) when is_binary(workspace) and is_function(fun, 1) do
    with_workspace_lock(workspace, fn ->
      with {:ok, previous_state} <- load_for_update(workspace, %{}) do
        state = fun.(previous_state)

        case save_unlocked(workspace, state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  @spec sync_lease(Path.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def sync_lease(workspace, issue, lease_attrs)
      when is_binary(workspace) and is_map(issue) and is_map(lease_attrs) do
    with_workspace_lock(workspace, fn ->
      with {:ok, previous_state} <- load_for_update(workspace, issue) do
        state = apply_lease_attrs(previous_state, lease_attrs)

        case save_unlocked(workspace, state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  @spec clear_lease(Path.t()) :: {:ok, map()} | {:error, term()}
  def clear_lease(workspace) when is_binary(workspace) do
    update(workspace, &clear_lease_attrs/1)
  end

  @spec delete(Path.t()) :: :ok
  def delete(workspace) when is_binary(workspace) do
    File.rm(state_path(workspace))
    :ok
  end

  defp maybe_record_stage_transition(state, stage, reason, false) do
    state
    |> bump_stage_transition_count(stage)
    |> update_stage_history(stage, reason)
  end

  defp maybe_record_stage_transition(state, _stage, _reason, true), do: state

  defp update_stage_history(state, stage, reason) do
    entry = %{
      stage: stage,
      at: SymphonyElixir.Util.now_iso8601(),
      reason: reason
    }

    history =
      state
      |> Map.get(:stage_history, [])
      |> List.wrap()
      |> Kernel.++([entry])
      |> Enum.take(-@stage_history_limit)

    Map.put(state, :stage_history, history)
  end

  defp bump_stage_transition_count(state, stage) do
    stage_transition_counts =
      state
      |> Map.get(:stage_transition_counts, %{})
      |> Map.put(stage, Map.get(state |> Map.get(:stage_transition_counts, %{}), stage, 0) + 1)

    Map.put(state, :stage_transition_counts, stage_transition_counts)
  end

  defp default_state(issue) when is_map(issue) do
    issue |> state_defaults() |> ensure_runner_metadata()
  end

  defp state_defaults(issue) when is_map(issue) do
    %{
      issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      issue_source: Map.get(issue, :source) || Map.get(issue, "source"),
      runner_instance_id: nil,
      runner_instance_name: nil,
      runner_channel: nil,
      runner_runtime_version: nil,
      runner_workspace_root: nil,
      stage: "checkout",
      stage_history: [],
      stage_transition_counts: %{},
      implementation_turns: 0,
      validation_attempts: 0,
      verification_attempts: 0,
      publish_attempts: 0,
      await_checks_polls: 0,
      merge_attempts: 0,
      automerge_disabled: false,
      review_approved: false,
      merge_window_wait: nil,
      policy_override: nil,
      effective_policy_class: nil,
      effective_policy_source: nil,
      last_pr_state: nil,
      review_threads: %{},
      review_claims: %{},
      review_return_stage: nil,
      last_review_decision: nil,
      last_ci_failure: nil,
      last_check_statuses: [],
      last_required_checks_state: nil,
      last_missing_required_checks: [],
      last_pending_required_checks: [],
      last_failing_required_checks: [],
      last_cancelled_required_checks: [],
      acceptance_summary: nil,
      last_verifier_verdict: nil,
      last_harness_init: nil,
      last_harness_check: nil,
      harness_status: nil,
      harness_attempts: 0,
      resume_context: %{},
      last_decision: nil,
      last_rule_id: nil,
      last_failure_class: nil,
      last_decision_summary: nil,
      next_human_action: nil,
      last_ledger_event_id: nil,
      last_merge: nil,
      stop_reason: nil,
      lease_owner: nil,
      lease_owner_instance_id: nil,
      lease_owner_channel: nil,
      lease_acquired_at: nil,
      lease_updated_at: nil,
      lease_status: nil,
      lease_epoch: nil,
      lease_version: nil,
      lease_generation: nil
    }
  end

  defp merge_defaults(state, issue) when is_map(state) and is_map(issue) do
    defaults = state_defaults(issue)

    defaults
    |> Map.merge(state)
    |> Map.put(:issue_id, Map.get(state, :issue_id) || Map.get(defaults, :issue_id))
    |> Map.put(
      :issue_identifier,
      Map.get(state, :issue_identifier) || Map.get(defaults, :issue_identifier)
    )
    |> Map.put(
      :issue_source,
      Map.get(state, :issue_source) || Map.get(defaults, :issue_source)
    )
    |> ensure_runner_metadata()
  end

  defp write_json_atomically(path, payload) when is_binary(path) and is_map(payload) do
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, Jason.encode!(payload), [:write]),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp_path)
        error
    end
  end

  defp ensure_runner_metadata(state) when is_map(state) do
    state
    |> put_missing(:runner_instance_id, &Config.runner_instance_id/0)
    |> put_missing(:runner_instance_name, &Config.runner_instance_name/0)
    |> put_missing(:runner_channel, &Config.runner_channel/0)
    |> put_missing(:runner_runtime_version, &RunnerRuntime.runtime_version/0)
    |> put_missing(:runner_workspace_root, &Config.workspace_root/0)
  end

  defp apply_lease_attrs(state, lease_attrs) when is_map(state) and is_map(lease_attrs) do
    lease = normalize_lease_attrs(lease_attrs)

    state
    |> Map.put(:lease_owner, Map.get(lease, :lease_owner))
    |> Map.put(:lease_owner_instance_id, Map.get(lease, :lease_owner_instance_id))
    |> Map.put(:lease_owner_channel, Map.get(lease, :lease_owner_channel))
    |> Map.put(:lease_acquired_at, Map.get(lease, :lease_acquired_at))
    |> Map.put(:lease_updated_at, Map.get(lease, :lease_updated_at))
    |> Map.put(:lease_status, Map.get(lease, :lease_status) || "held")
    |> Map.put(:lease_epoch, Map.get(lease, :lease_epoch))
    |> Map.put(:lease_version, Map.get(lease, :lease_version))
    |> Map.put(:lease_generation, Map.get(lease, :lease_generation))
  end

  defp clear_lease_attrs(state) when is_map(state) do
    state
    |> Map.put(:lease_owner, nil)
    |> Map.put(:lease_owner_instance_id, nil)
    |> Map.put(:lease_owner_channel, nil)
    |> Map.put(:lease_acquired_at, nil)
    |> Map.put(:lease_updated_at, nil)
    |> Map.put(:lease_status, nil)
    |> Map.put(:lease_epoch, nil)
    |> Map.put(:lease_version, nil)
    |> Map.put(:lease_generation, nil)
  end

  defp normalize_lease_attrs(lease_attrs) when is_map(lease_attrs) do
    %{
      lease_owner:
        Map.get(lease_attrs, :lease_owner) || Map.get(lease_attrs, "lease_owner") ||
          Map.get(lease_attrs, :owner) || Map.get(lease_attrs, "owner"),
      lease_owner_instance_id:
        Map.get(lease_attrs, :lease_owner_instance_id) ||
          Map.get(lease_attrs, "lease_owner_instance_id"),
      lease_owner_channel: Map.get(lease_attrs, :lease_owner_channel) || Map.get(lease_attrs, "lease_owner_channel"),
      lease_acquired_at:
        Map.get(lease_attrs, :lease_acquired_at) || Map.get(lease_attrs, "lease_acquired_at") ||
          Map.get(lease_attrs, :acquired_at) || Map.get(lease_attrs, "acquired_at"),
      lease_updated_at:
        Map.get(lease_attrs, :lease_updated_at) || Map.get(lease_attrs, "lease_updated_at") ||
          Map.get(lease_attrs, :updated_at) || Map.get(lease_attrs, "updated_at"),
      lease_version: Map.get(lease_attrs, :lease_version) || Map.get(lease_attrs, "lease_version"),
      lease_generation: Map.get(lease_attrs, :lease_generation) || Map.get(lease_attrs, "lease_generation"),
      lease_status: Map.get(lease_attrs, :lease_status) || Map.get(lease_attrs, "lease_status"),
      lease_epoch:
        Map.get(lease_attrs, :lease_epoch) || Map.get(lease_attrs, "lease_epoch") ||
          Map.get(lease_attrs, :epoch) || Map.get(lease_attrs, "epoch")
    }
  end

  defp put_missing(state, key, value) when is_map(state) and is_function(value, 0) do
    case Map.get(state, key) do
      existing when existing in [nil, ""] -> Map.put(state, key, value.())
      _existing -> state
    end
  end

  defp run_state_matches_issue?(state, issue) when is_map(state) and is_map(issue) do
    state_id = Map.get(state, :issue_id)
    state_identifier = Map.get(state, :issue_identifier)
    issue_id = Map.get(issue, :id) || Map.get(issue, "id")
    issue_identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")

    cond do
      not present?(issue_id) and not present?(issue_identifier) ->
        true

      present?(state_id) ->
        state_id == issue_id

      present?(state_identifier) ->
        state_identifier == issue_identifier

      true ->
        true
    end
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value)

  defp atomize(map) when is_map(map) do
    if preserve_string_keys_map?(map) do
      Map.new(map, fn {key, value} ->
        {key, preserve_string_keys_value(value)}
      end)
    else
      Map.new(map, fn
        {"stage_transition_counts", counts} -> {:stage_transition_counts, counts}
        {key, value} -> {atom_key(key), atomize_value(value)}
      end)
    end
  end

  defp atomize_value(value) when is_map(value), do: atomize(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value

  defp preserve_string_keys_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {key, preserve_string_keys_value(nested_value)}
    end)
  end

  defp preserve_string_keys_value(value) when is_list(value),
    do: Enum.map(value, &preserve_string_keys_value/1)

  defp preserve_string_keys_value(value), do: value

  defp atom_key(key) when is_binary(key) do
    if atomizable_key?(key) do
      String.to_existing_atom(key)
    else
      key
    end
  rescue
    ArgumentError ->
      if atomizable_key?(key) do
        String.to_atom(key)
      else
        key
      end
  end

  defp atomizable_key?(key) when is_binary(key) do
    String.match?(key, ~r/^[a-z_][a-zA-Z0-9_]*[!?]?$/)
  end

  defp preserve_string_keys_map?(map) when is_map(map) do
    Enum.any?(Map.keys(map), fn
      key when is_binary(key) -> not atomizable_key?(key)
      _ -> false
    end)
  end
end
