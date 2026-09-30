defmodule SymphonyElixir.DeployAudit do
  @moduledoc """
  Records a deploy intent and observed result outside the mutable workspace.

  A pending journal prohibits another deploy even if its owner or VM has exited.
  Only the process that opened a ticket may record its result and finish it.
  Finishing requires the exact checked result and the operation's own checked
  continuation. There is no timeout cleanup or automatic recovery of uncertainty.
  The filesystem reservation excludes independent VMs; subsequent mutations use
  local exclusion and must not be shared between live coordinators.
  """

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunLedger, RunStateStore}

  @marker_name "marker.json"
  @stages ["deploy_preview", "deploy_production"]
  @destinations ["post_deploy_verify", "done"]
  @identity_fields ~w(run_id run_identity_event_id run_identity_ledger_path run_identity_pending)
  @type ticket :: %{
          required(:workspace) => Path.t(),
          required(:operation_id) => String.t(),
          required(:owner_pid) => pid(),
          required(:intent_event_id) => String.t(),
          required(:ledger_path) => Path.t(),
          required(:version) => 1 | 2,
          required(:live_ref) => reference(),
          optional(:execution) => map()
        }
  @type continuation :: %{required(:stage) => String.t(), required(:event) => map(), optional(:version) => 2, optional(:previous) => map(), optional(:next) => map()}

  @spec marker_directory(Path.t()) :: Path.t()
  def marker_directory(workspace) when is_binary(workspace) do
    workspace = Path.expand(workspace)
    Path.join(Path.dirname(workspace), "." <> Path.basename(workspace) <> ".deploy-audit")
  end

  @spec ensure_available(Path.t()) :: :ok | {:error, term()}
  def ensure_available(workspace) when is_binary(workspace) do
    case File.lstat(marker_directory(workspace)) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, {:deploy_audit_pending, Path.expand(workspace)}}
      {:error, reason} -> {:error, {:deploy_audit_read_failed, reason}}
    end
  end

  @spec begin(Path.t(), map()) :: {:ok, ticket()} | {:error, term()}
  def begin(workspace, attrs) when is_binary(workspace) and is_map(attrs) do
    workspace = Path.expand(workspace)

    with :ok <- validate_attrs(attrs) do
      RunStateStore.with_workspace_lock(workspace, fn ->
        with :ok <- ensure_available(workspace),
             {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
             {:ok, state} <- legacy_state(workspace, ledger_path),
             :ok <- matching_snapshot(state, attrs),
             {:ok, entry} <- snapshot_entry(state),
             :ok <- ensure_ledger_path(ledger_path),
             :ok <- create_marker_directory(workspace) do
          prepare_intent(workspace, attrs, state, ledger_path, entry, nil)
        end
      end)
    end
  end

  @doc "Opens an operation only from the worker's captured dispatch, physical token and material witness."
  @spec begin(Path.t(), map(), %{authority: map(), expected: map(), provenance: map()}) :: {:ok, ticket()} | {:error, term()}
  def begin(workspace, attrs, %{authority: authority, expected: expected, provenance: provenance})
      when is_binary(workspace) and is_map(attrs) and is_map(authority) and is_map(expected) and is_map(provenance) do
    workspace = Path.expand(workspace)

    with :ok <- validate_attrs(attrs),
         true <- get_in(authority, [:ticket, :workspace]) == workspace or {:error, :deploy_audit_execution_mismatch} do
      RunStateStore.with_workspace_lock(workspace, fn ->
        with :ok <- ensure_available(workspace),
             {:ok, state} <- RunStateStore.check_deploy_current_locked(authority, expected),
             :ok <- matching_snapshot(state, attrs),
             :ok <- validate_provenance(authority, state, provenance),
             {:ok, entry} <- snapshot_entry(state),
             ledger_path = authority.ticket.ledger_path,
             :ok <- ensure_ledger_path(ledger_path),
             :ok <- create_marker_directory(workspace) do
          prepare_intent(workspace, attrs, state, ledger_path, entry, %{authority: authority, expected: expected, provenance: provenance})
        end
      end)
    end
  end

  def begin(_workspace, _attrs, _execution), do: {:error, :invalid_deploy_execution}

  @doc "Consumes one observation before preparing its event or attempting any writer IO."
  @spec record_result(ticket(), map()) :: :ok | {:ok, map()} | {:error, term()}
  def record_result(ticket, result), do: record_result(ticket, result, :current)

  @doc false
  @spec record_result(ticket(), map(), :current | {:denied, AgentExecution.terminal()}) :: :ok | {:ok, map()} | {:error, term()}
  def record_result(ticket, result, permission) when permission == :current or (is_tuple(permission) and elem(permission, 0) == :denied) do
    with {:ok, live} <- unused_ticket(ticket),
         :ok <- valid_observation(live.marker, result),
         :ok <- valid_observation_permission(ticket, permission) do
      receipt = %{version: ticket.version, operation_id: ticket.operation_id, result_event_id: nil, command_status: to_string(result.status), authority: :not_checked, persistence: :not_attempted}
      put_live(ticket, %{live | observation: {:preparing, receipt}})

      case prepare_result(live.marker, result) do
        {:ok, prepared} ->
          receipt = %{receipt | result_event_id: prepared.event_id}
          put_live(ticket, %{live | observation: {:recording, prepared, receipt}})
          observed = json_value(prepared)
          put_live(ticket, %{live | observation: {:recording, observed, receipt}})
          RunStateStore.with_workspace_lock(ticket.workspace, fn -> record_observation_locked(ticket, observed, receipt, permission) end)

        {:error, reason} ->
          if ticket.version == 1, do: {:error, reason}, else: {:error, {:deploy_observation_prepare_failed, reason, receipt}}
      end
    end
  end

  def record_result(_ticket, _result, _permission), do: {:error, :invalid_deploy_observation_permission}

  @doc false
  @spec continuation_context(ticket()) :: {:ok, map()} | {:error, term()}
  def continuation_context(%{workspace: workspace} = ticket) when is_binary(workspace) do
    RunStateStore.with_workspace_lock(workspace, fn -> continuation_context_locked(ticket) end)
  end

  def continuation_context(_ticket), do: {:error, :invalid_deploy_audit_ticket}

  @doc false
  @spec continuation_context_locked(ticket()) :: {:ok, map()} | {:error, term()}
  def continuation_context_locked(ticket) do
    with {:ok, context} <- confirmed_result_context(ticket),
         {:ok, state} <- continuation_permission_locked(ticket),
         :ok <- legacy_precontinuation_snapshot(ticket, state, context) do
      {:ok, context}
    end
  end

  @doc false
  @spec anchor_continuation_locked(ticket(), continuation()) :: :ok | {:error, term()}
  def anchor_continuation_locked(%{version: 2} = ticket, %{version: 2, previous: previous, next: next, stage: stage, event: event} = continuation)
      when is_map(previous) and is_map(next) and is_map(event) and stage in @destinations do
    with {:ok, live} <- live_ticket(ticket),
         :ok <- settled_current_observation(live),
         true <- is_nil(live.continuation) or {:error, :deploy_audit_continuation_already_anchored},
         true <-
           (map_size(continuation) == 5 and previous == ticket.execution.expected and next["stage"] == stage and
              next["last_ledger_event_id"] == event["event_id"]) or {:error, :deploy_audit_continuation_mismatch} do
      put_live(ticket, %{live | continuation: continuation})
      :ok
    end
  end

  def anchor_continuation_locked(_ticket, _continuation), do: {:error, :invalid_deploy_audit_continuation}

  @doc false
  @spec assert_continuation_locked(ticket(), continuation()) :: :ok | {:error, term()}
  def assert_continuation_locked(%{version: 2} = ticket, continuation) when is_map(continuation) do
    with {:ok, live} <- live_ticket(ticket),
         :ok <- settled_current_observation(live),
         true <- (not is_nil(live.continuation) and live.continuation == continuation) or {:error, :deploy_audit_continuation_mismatch},
         do: :ok
  end

  def assert_continuation_locked(_ticket, _continuation), do: {:error, :invalid_deploy_audit_continuation}

  @doc "Closes only the operation's own exact confirmed continuation, without granting another action."
  @spec finish(ticket(), continuation()) :: :ok | {:error, term()}
  def finish(%{workspace: workspace, version: 2} = ticket, %{version: 2, stage: stage, event: event} = continuation)
      when is_binary(workspace) and is_map(event) do
    with :ok <- assert_continuation_locked(ticket, continuation) do
      RunStateStore.with_workspace_lock(workspace, fn ->
        with {:ok, context} <- confirmed_result_context(ticket),
             true <- stage in @destinations or {:error, :invalid_deploy_audit_destination},
             :ok <- validate_continuation(event, stage, context),
             :ok <- confirm_continuation_event(event, context),
             :ok <- RunStateStore.confirm_deploy_continuation_locked(ticket, ticket.execution.authority, continuation) do
          finish_marker(ticket, event)
        else
          {:error, reason} -> {:error, retain_denial(ticket, reason)}
        end
      end)
    end
  end

  def finish(%{workspace: workspace, version: 1} = ticket, %{stage: stage, event: event}) when is_binary(workspace) and is_map(event) do
    RunStateStore.with_workspace_lock(workspace, fn ->
      with {:ok, context} <- confirmed_result_context(ticket),
           {:ok, state} <- continuation_permission_locked(ticket),
           true <- stage in @destinations or {:error, :invalid_deploy_audit_destination},
           :ok <- validate_continuation(event, stage, context),
           :ok <- confirm_continuation_event(event, context),
           :ok <- legacy_finish_snapshot(ticket, state, context, stage, event) do
        finish_marker(ticket, event)
      end
    end)
  end

  def finish(_ticket, _continuation), do: {:error, :invalid_deploy_audit_continuation}

  @doc "Reads only checked pending evidence. It never imports custody or repairs a journal."
  @spec inspect_pending(Path.t()) :: {:ok, :none | map()} | {:error, term()}
  def inspect_pending(workspace) when is_binary(workspace) do
    workspace = Path.expand(workspace)

    RunStateStore.with_workspace_lock(workspace, fn ->
      case File.lstat(marker_directory(workspace)) do
        {:error, :enoent} -> {:ok, :none}
        {:ok, _stat} -> inspect_marker(workspace)
        {:error, reason} -> {:error, {:deploy_diagnostic_unconfirmed, reason}}
      end
    end)
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp attach_execution(marker, nil), do: marker

  defp attach_execution(marker, %{authority: authority, expected: expected, provenance: provenance}) do
    marker
    |> Map.put("version", 2)
    |> Map.put("lease_owner", authority.lease_token.owner)
    |> Map.put("lease_epoch", authority.lease_token.epoch)
    |> Map.put("execution", json_value(%{version: 1, dispatch_ticket: authority.ticket, lease_token_version: 2, lease_token: authority.lease_token, expected: expected, provenance: provenance}))
  end

  defp legacy_state(workspace, ledger_path) do
    with {:error, :execution_context_missing} <- AgentExecution.current_context(),
         {:error, :dispatch_context_missing} <- DispatchAudit.current_ticket(),
         :ok <- ensure_ledger_path(ledger_path),
         {:ok, payload} <- File.read(RunStateStore.state_path(workspace)),
         {:ok, raw} <- Jason.decode(payload),
         true <- is_map(raw) or {:error, :invalid_state},
         :ok <- legacy_raw(raw),
         :ok <- legacy_physical_lease(raw["issue_id"], ledger_path) do
      keys = [:issue_id, :issue_identifier, :stage, :stop_reason, :last_ledger_event_id, :lease_owner, :lease_epoch, :last_deploy_operation_id]
      {:ok, Map.new(keys, fn key -> {key, raw[Atom.to_string(key)]} end)}
    else
      {:ok, _context} -> {:error, :deploy_audit_execution_context_required}
      {:error, _reason} = error -> error
    end
  end

  defp legacy_raw(%{"audit_pending" => %{} = pending}), do: {:error, {:audit_pending, pending["operation_id"]}}
  defp legacy_raw(%{"audit_pending" => _}), do: {:error, :invalid_audit_pending}

  defp legacy_raw(raw) do
    if Enum.any?(@identity_fields, &Map.has_key?(raw, &1)) or
         not is_nil(raw["lease_version"]) or not is_nil(raw["lease_generation"]),
       do: {:error, :deploy_audit_execution_context_required},
       else: :ok
  end

  defp legacy_physical_lease(issue_id, ledger_path) when is_binary(issue_id) and issue_id != "" do
    with {:ok, storage} <- LeaseManager.capture_storage(issue_id),
         true <- storage.ledger_path == ledger_path or {:error, :deploy_audit_ledger_changed} do
      case LeaseManager.read_at(storage) do
        {:error, :missing} ->
          :ok

        {:ok, lease} ->
          if lease["lease_version"] in [nil, 1] and not Map.has_key?(lease, "lease_generation"), do: :ok, else: {:error, :deploy_audit_execution_context_required}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp legacy_physical_lease(_issue_id, _ledger_path), do: {:error, :invalid_deploy_audit_issue}

  defp valid_observation(marker, %{status: status, command: command, output: output})
       when (is_atom(status) or is_binary(status)) and is_binary(command) and is_binary(output) do
    if to_string(status) != "" and command_digest(command) == marker["command_digest"], do: :ok, else: {:error, :invalid_deploy_audit_result}
  end

  defp valid_observation(_marker, _result), do: {:error, :invalid_deploy_audit_result}
  defp valid_observation_permission(_ticket, :current), do: :ok

  defp valid_observation_permission(
         %{version: 2, execution: %{authority: %{ticket: captured}}},
         {:denied, {:stop, {:stale_execution, %{run_id: run_id, dispatch_id: dispatch_id}, _cause}}}
       ) do
    if run_id == captured.run_id and dispatch_id == captured.dispatch_id, do: :ok, else: {:error, :deploy_audit_denial_identity_mismatch}
  end

  defp valid_observation_permission(%{version: 2}, {:denied, {:stop, {kind, _reason}}}) when kind in [:accounting_uncertain, :execution_stopped], do: :ok
  defp valid_observation_permission(_ticket, _permission), do: {:error, :invalid_deploy_observation_permission}

  defp record_observation_locked(ticket, observed, receipt, permission) do
    receipt = accept_owner_denial(ticket, permission, receipt)

    case authorized_observation_marker(ticket) do
      {:ok, marker} ->
        receipt = observation_authority(ticket, receipt)
        pending = marker |> Map.put("status", "result_pending") |> Map.put("result", observed) |> mark_observation_denied(receipt)
        persistence = persist_observation(ticket.workspace, marker, pending, observed)
        receipt = %{receipt | persistence: persistence}
        settle_observation(ticket, observed, receipt)
        observation_reply(ticket, observed, receipt)

      {:error, reason} ->
        settle_observation(ticket, observed, receipt)
        if ticket.version == 1, do: {:error, reason}, else: {:error, {:deploy_observation_rejected, reason, receipt}}
    end
  end

  defp authorized_observation_marker(ticket) do
    with {:ok, marker} <- validated_ticket(ticket),
         true <- marker["status"] == "authorized" or {:error, :deploy_audit_result_already_started},
         do: {:ok, marker}
  end

  defp accept_owner_denial(ticket, {:denied, terminal}, receipt) do
    reason = retain_denial(ticket, terminal)
    %{receipt | authority: {:rejected, reason}}
  end

  defp accept_owner_denial(_ticket, :current, receipt), do: receipt

  defp observation_authority(%{version: 1}, receipt), do: receipt

  defp observation_authority(%{version: 2} = ticket, receipt) do
    {:ok, live} = live_ticket(ticket)

    result =
      if is_nil(live.denial),
        do: RunStateStore.check_deploy_current_locked(ticket.execution.authority, ticket.execution.expected),
        else: {:error, live.denial}

    case result do
      {:ok, _state} -> %{receipt | authority: :current}
      {:error, reason} -> %{receipt | authority: {:rejected, retain_denial(ticket, reason)}}
    end
  end

  defp persist_observation(workspace, marker, pending, observed) do
    case write_marker(workspace, pending) do
      :ok ->
        result =
          with :ok <- validate_recorded_intent(marker),
               :ok <- ensure_ledger_path(marker["ledger_path"]),
               {:ok, _entry} <- RunLedger.persist_prepared(observed),
               :ok <- ensure_ledger_path(marker["ledger_path"]),
               do: write_marker(workspace, Map.put(pending, "status", "result_confirmed"))

        case result do
          :ok -> :confirmed
          {:error, reason} -> {:marker_only, reason}
        end

      {:error, reason} ->
        {:unconfirmed, reason}
    end
  end

  defp settle_observation(ticket, observed, receipt) do
    {:ok, live} = live_ticket(ticket)
    put_live(ticket, %{live | observation: {:settled, observed, receipt}})
    :ok
  end

  defp observation_reply(%{version: 2}, _observed, receipt), do: {:ok, receipt}
  defp observation_reply(%{version: 1}, observed, %{persistence: :confirmed}), do: successful_result(observed)
  defp observation_reply(%{version: 1}, _observed, %{persistence: {_phase, reason}}), do: {:error, reason}

  defp mark_observation_denied(marker, %{authority: {:rejected, reason}}) do
    Map.put(marker, "continuation_denied", Map.put(safe_denial(reason), "phase", "record_result"))
  end

  defp mark_observation_denied(marker, _receipt), do: marker
  defp safe_denial({:stop, terminal}), do: safe_denial(terminal)
  defp safe_denial({:stale_execution, _ids, cause}), do: %{"kind" => "stale_execution", "reason_tag" => reason_tag(cause)}
  defp safe_denial({:stale_execution, cause}), do: %{"kind" => "stale_execution", "reason_tag" => reason_tag(cause)}
  defp safe_denial({:accounting_uncertain, cause}), do: %{"kind" => "accounting_uncertain", "reason_tag" => reason_tag(cause)}
  defp safe_denial({:execution_stopped, _details}), do: %{"kind" => "execution_stopped", "reason_tag" => "owner_stop"}
  defp safe_denial(cause), do: %{"kind" => "storage_rejection", "reason_tag" => reason_tag(cause)}
  defp reason_tag(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_tag(%Jason.DecodeError{}), do: "invalid_json"
  defp reason_tag(%RunLedger.PersistenceError{}), do: "ledger_persistence_error"
  defp reason_tag({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_tag({tag, _first, _second}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_tag(_reason), do: "execution_rejected"

  defp retain_denial(ticket, reason) do
    {:ok, live} = live_ticket(ticket)
    retained = if is_nil(live.denial), do: reason, else: live.denial
    put_live(ticket, %{live | denial: retained})
    retained
  end

  defp continuation_permission_locked(ticket) do
    {:ok, live} = live_ticket(ticket)

    result =
      cond do
        not is_nil(live.denial) -> {:error, live.denial}
        ticket.version == 1 -> legacy_state(ticket.workspace, ticket.ledger_path)
        ticket.version == 2 -> RunStateStore.check_deploy_current_locked(ticket.execution.authority, ticket.execution.expected)
      end

    case result do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, retain_denial(ticket, reason)}
    end
  end

  defp legacy_precontinuation_snapshot(%{version: 2}, _state, _context), do: :ok

  defp legacy_precontinuation_snapshot(ticket, state, context) do
    original =
      state[:issue_id] == context.issue_id and state[:issue_identifier] == context.issue_identifier and
        state[:stage] == context.stage and state[:last_ledger_event_id] == context.entry_event_id and
        state[:lease_owner] == context.lease_owner and state[:lease_epoch] == context.lease_epoch and is_nil(state[:stop_reason])

    if original do
      :ok
    else
      # An already confirmed own successor still belongs to this live operation.
      # RSS rejects another pre-CAS transition; finish checks that successor separately.
      result =
        with true <- state[:stage] in @destinations or {:error, :deploy_audit_snapshot_conflict},
             true <- is_binary(state[:last_ledger_event_id]) or {:error, :deploy_audit_snapshot_conflict},
             {:ok, event} <- RunLedger.fetch_entry_checked(state[:last_ledger_event_id]),
             :ok <- validate_continuation(event, state[:stage], context),
             :ok <- matching_continuation_snapshot(state, context, state[:stage], event),
             do: :ok

      case result do
        :ok -> :ok
        {:error, _reason} -> {:error, retain_denial(ticket, :deploy_audit_snapshot_conflict)}
      end
    end
  end

  defp legacy_finish_snapshot(ticket, state, context, stage, event) do
    case matching_continuation_snapshot(state, context, stage, event) do
      :ok -> :ok
      {:error, reason} -> {:error, retain_denial(ticket, reason)}
    end
  end

  defp confirmed_result_context(ticket) do
    with {:ok, live} <- live_ticket(ticket),
         true <- is_nil(live.denial) or {:error, live.denial} do
      case read_confirmed_result_context(ticket) do
        {:error, reason} = error ->
          case live.observation do
            {:settled, _event, %{persistence: :confirmed}} -> {:error, retain_denial(ticket, reason)}
            _not_confirmed -> error
          end

        {:ok, _context} = result ->
          result
      end
    end
  end

  defp read_confirmed_result_context(ticket) do
    with {:ok, marker} <- validated_ticket(ticket),
         true <- marker["status"] == "result_confirmed" or {:error, :deploy_audit_result_unconfirmed},
         :ok <- validate_recorded_intent(marker),
         :ok <- validate_result(marker),
         {:ok, result} <- RunLedger.fetch_entry_checked(marker["result"]["event_id"]),
         true <- result == marker["result"] or {:error, :deploy_audit_result_mismatch},
         :ok <- matching_live_observation(ticket, result),
         :ok <- successful_result(result) do
      context = %{
        version: ticket.version,
        workspace: marker["workspace"],
        operation_id: marker["operation_id"],
        intent_event_id: marker["intent"]["event_id"],
        result_event_id: result["event_id"],
        ledger_path: marker["ledger_path"],
        issue_id: marker["issue_id"],
        issue_identifier: marker["issue_identifier"],
        stage: marker["stage"],
        target: marker["target"],
        entry_event_id: marker["entry_event_id"],
        lease_owner: marker["lease_owner"],
        lease_epoch: marker["lease_epoch"],
        result: %{status: result["metadata"]["result"]["status"], command: result["metadata"]["result"]["command"], output: result["metadata"]["result"]["output"]}
      }

      {:ok, if(ticket.version == 2, do: Map.put(context, :execution, ticket.execution), else: context)}
    end
  end

  defp matching_live_observation(ticket, result) do
    with {:ok, live} <- live_ticket(ticket) do
      case live.observation do
        {:settled, ^result, %{persistence: :confirmed}} -> :ok
        _ -> {:error, :deploy_audit_result_unconfirmed}
      end
    end
  end

  defp settled_current_observation(%{denial: reason}) when not is_nil(reason), do: {:error, reason}
  defp settled_current_observation(%{observation: {:settled, _event, %{authority: :current, persistence: :confirmed, command_status: "passed"}}}), do: :ok
  defp settled_current_observation(_live), do: {:error, :deploy_audit_result_unconfirmed}

  defp validate_provenance(authority, state, provenance) do
    prior = state[:last_agent_session]
    expected_prior = if is_map(prior), do: Map.take(prior, [:event_id, :run_id, :dispatch_id, :agent_session]), else: nil

    expected = %{
      version: 1,
      actor_role: "runtime",
      run_id: authority.ticket.run_id,
      dispatch_id: authority.ticket.dispatch_id,
      lease_generation: authority.lease_token.lease_generation,
      agent_session: provenance[:agent_session],
      prior_agent_session: expected_prior
    }

    with true <- provenance == expected or {:error, :execution_provenance_mismatch},
         true <- valid_session?(json_value(provenance.agent_session)) or {:error, :invalid_execution_agent_session},
         :ok <- validate_prior(state, prior),
         do: :ok
  end

  defp validate_prior(state, nil) do
    if Map.has_key?(state, :last_agent_session), do: {:error, :invalid_prior_agent_session}, else: :ok
  end

  defp validate_prior(state, %{version: 1, event_id: id, run_id: run, dispatch_id: dispatch, agent_session: session} = prior)
       when is_binary(id) and is_binary(run) and is_binary(dispatch) and is_map(session) and map_size(prior) == 5 do
    with true <- (run == state[:run_id] and valid_session?(json_value(session))) or {:error, :invalid_prior_agent_session},
         {:ok, event} <- RunLedger.fetch_entry_checked(id),
         execution when is_map(execution) <- get_in(event, ["metadata", "execution"]),
         true <-
           (event["event_type"] == "stage.transition" and event["issue_id"] == state[:issue_id] and
              event["issue_identifier"] == state[:issue_identifier] and execution["version"] == 1 and execution["actor_role"] == "runtime" and
              execution["run_id"] == run and execution["dispatch_id"] == dispatch and execution["agent_session"] == json_value(session)) or
             {:error, :invalid_prior_agent_session} do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_prior_agent_session}
    end
  end

  defp validate_prior(_state, _prior), do: {:error, :invalid_prior_agent_session}
  defp valid_session?(nil), do: true

  defp valid_session?(%{"provider" => provider, "kind" => kind, "id" => id, "invocation" => ordinal} = session),
    do:
      map_size(session) == 4 and provider in ["claude_cli", "codex_cli", "app_server"] and kind in ["session", "thread"] and
        is_binary(id) and id != "" and is_integer(ordinal) and ordinal > 0

  defp valid_session?(_session), do: false

  defp valid_denial?(%{"phase" => "record_result", "kind" => kind, "reason_tag" => tag} = denial),
    do: map_size(denial) == 3 and kind in ["stale_execution", "accounting_uncertain", "execution_stopped", "storage_rejection"] and is_binary(tag)

  defp valid_denial?(_denial), do: false

  defp valid_marker_execution?(%{"version" => 1} = marker), do: not Map.has_key?(marker, "execution")

  defp valid_marker_execution?(
         %{
           "version" => 2,
           "execution" => %{"version" => 1, "dispatch_ticket" => dispatch, "lease_token_version" => 2, "lease_token" => token, "expected" => expected, "provenance" => provenance} = execution
         } = marker
       )
       when is_map(dispatch) and is_map(token) and is_map(expected) and is_map(provenance) do
    storage = token["storage"]

    map_size(execution) == 6 and map_size(dispatch) == 7 and map_size(token) == 5 and is_map(storage) and map_size(storage) == 4 and
      Enum.all?(~w(dispatch_id run_id entry_event_id owner ledger_path workspace), &(is_binary(dispatch[&1]) and dispatch[&1] != "")) and
      is_integer(dispatch["epoch"]) and dispatch["epoch"] > 0 and dispatch["workspace"] == marker["workspace"] and
      dispatch["ledger_path"] == marker["ledger_path"] and storage["ledger_path"] == marker["ledger_path"] and
      storage["issue_id"] == marker["issue_id"] and is_binary(storage["lease_path"]) and is_integer(storage["ttl_ms"]) and storage["ttl_ms"] > 0 and
      token["owner"] == dispatch["owner"] and token["epoch"] == dispatch["epoch"] and token["owner"] == marker["lease_owner"] and
      token["epoch"] == marker["lease_epoch"] and is_binary(token["lease_generation"]) and token["lease_generation"] != "" and is_binary(token["acquired_at"]) and
      expected["stage"] == marker["stage"] and expected["last_ledger_event_id"] == marker["entry_event_id"] and
      map_size(provenance) == 7 and provenance["version"] == 1 and provenance["actor_role"] == "runtime" and
      provenance["run_id"] == dispatch["run_id"] and provenance["dispatch_id"] == dispatch["dispatch_id"] and
      provenance["lease_generation"] == token["lease_generation"] and valid_session?(provenance["agent_session"]) and
      (is_nil(provenance["prior_agent_session"]) or is_map(provenance["prior_agent_session"]))
  end

  defp valid_marker_execution?(_marker), do: false

  defp inspect_marker(workspace) do
    with :ok <- ensure_only_marker(workspace),
         {:ok, marker} <- read_marker(workspace),
         :ok <- validate_recorded_intent(marker),
         {:ok, result} <- inspect_result(marker),
         :ok <- inspect_continuation(marker) do
      summary = %{
        version: marker["version"],
        operation_id: marker["operation_id"],
        issue_id: marker["issue_id"],
        stage: marker["stage"],
        target: marker["target"],
        status: marker["status"],
        event_ids: %{entry: marker["entry_event_id"], intent: marker["intent"]["event_id"]},
        chain: :confirmed
      }

      summary = if is_nil(result), do: summary, else: summary |> put_in([:event_ids, :result], result["event_id"]) |> Map.put(:result_status, result["metadata"]["result"]["status"])

      summary =
        case marker["execution"] do
          %{"dispatch_ticket" => dispatch} -> Map.merge(summary, %{run_id: dispatch["run_id"], dispatch_id: dispatch["dispatch_id"]})
          nil -> summary
        end

      summary = if Map.has_key?(marker, "continuation_denied"), do: Map.put(summary, :continuation_denied, Map.take(marker["continuation_denied"], ["phase", "kind", "reason_tag"])), else: summary
      {:ok, summary}
    else
      {:error, reason} -> {:error, {:deploy_diagnostic_unconfirmed, reason}}
    end
  end

  defp inspect_result(%{"status" => status} = marker) when status in ["result_pending", "result_confirmed", "finishing"] do
    with :ok <- validate_result(marker),
         {:ok, result} <- RunLedger.fetch_entry_checked(marker["result"]["event_id"]),
         true <- result == marker["result"] or {:error, :deploy_audit_result_mismatch},
         do: {:ok, result}
  end

  defp inspect_result(_marker), do: {:ok, nil}

  defp inspect_continuation(%{"status" => "finishing", "continuation" => %{} = event} = marker) do
    context = %{
      issue_id: marker["issue_id"],
      issue_identifier: marker["issue_identifier"],
      stage: marker["stage"],
      operation_id: marker["operation_id"],
      intent_event_id: marker["intent"]["event_id"],
      result_event_id: marker["result"]["event_id"],
      ledger_path: marker["ledger_path"]
    }

    with true <- event["stage"] in @destinations or {:error, :invalid_deploy_audit_destination},
         :ok <- validate_continuation(event, event["stage"], context),
         do: confirm_continuation_event(event, context)
  end

  defp inspect_continuation(%{"status" => "finishing"}), do: {:error, :invalid_deploy_audit_continuation}
  defp inspect_continuation(_marker), do: :ok

  defp confirm_continuation_event(event, context) do
    with :ok <- ensure_ledger_path(context.ledger_path),
         {:ok, recorded} <- RunLedger.fetch_entry_checked(event["event_id"]),
         true <- recorded == event or {:error, :deploy_audit_continuation_mismatch},
         do: :ok
  end

  defp finish_marker(ticket, event) do
    with :ok <- ensure_only_marker(ticket.workspace),
         {:ok, marker} <- validated_ticket(ticket),
         finishing = Map.merge(marker, %{"status" => "finishing", "continuation" => event}),
         :ok <- write_marker(ticket.workspace, finishing),
         :ok <- remove_marker(ticket.workspace, finishing) do
      Process.delete({__MODULE__, ticket.operation_id})
      :ok
    end
  end

  defp validate_attrs(%{issue_id: id, issue_identifier: identifier, stage: stage, command: command})
       when is_binary(id) and id != "" and is_binary(identifier) and identifier != "" and stage in @stages and is_binary(command) and command != "",
       do: :ok

  defp validate_attrs(_attrs), do: {:error, :invalid_deploy_audit_attrs}

  defp matching_snapshot(state, attrs) do
    if state[:issue_id] == attrs.issue_id and state[:issue_identifier] == attrs.issue_identifier and
         state[:stage] == attrs.stage and is_nil(state[:stop_reason]) do
      :ok
    else
      {:error, :deploy_audit_snapshot_conflict}
    end
  end

  defp snapshot_entry(%{last_ledger_event_id: event_id} = state) when is_binary(event_id) and event_id != "" do
    with {:ok, event} <- RunLedger.fetch_entry_checked(event_id),
         true <-
           (event["event_type"] == "stage.transition" and event["issue_id"] == state[:issue_id] and
              event["issue_identifier"] == state[:issue_identifier] and event["stage"] == state[:stage]) or {:error, :deploy_audit_entry_mismatch} do
      {:ok, event}
    end
  end

  defp snapshot_entry(_state), do: {:error, :deploy_audit_entry_missing}

  defp prepare_intent(workspace, attrs, state, ledger_path, entry, execution) do
    operation_id = SymphonyElixir.Util.generate_id("deploy_")
    target = if attrs.stage == "deploy_preview", do: "preview", else: "production"

    marker = %{
      "version" => 1,
      "workspace" => workspace,
      "operation_id" => operation_id,
      "owner" => inspect(self()),
      "issue_id" => attrs.issue_id,
      "issue_identifier" => attrs.issue_identifier,
      "stage" => attrs.stage,
      "target" => target,
      "command_digest" => command_digest(attrs.command),
      "entry_event_id" => state[:last_ledger_event_id],
      "entry" => entry,
      "ledger_path" => ledger_path,
      "lease_owner" => state[:lease_owner],
      "lease_epoch" => state[:lease_epoch],
      "status" => "prepared"
    }

    marker = attach_execution(marker, execution)

    with {:ok, intent} <- RunLedger.prepare_entry("deploy.#{target}.requested", event_attrs(marker, "Requested deployment; command execution has not yet been observed.")),
         marker = Map.put(marker, "intent", intent),
         :ok <- write_marker(workspace, marker),
         :ok <- ensure_ledger_path(ledger_path),
         {:ok, _entry} <- RunLedger.persist_prepared(intent),
         :ok <- ensure_ledger_path(ledger_path),
         :ok <- write_marker(workspace, Map.put(marker, "status", "authorized")) do
      ticket = %{workspace: workspace, operation_id: operation_id, owner_pid: self(), intent_event_id: intent.event_id, ledger_path: ledger_path, version: marker["version"], live_ref: make_ref()}
      ticket = if is_nil(execution), do: ticket, else: Map.put(ticket, :execution, execution)
      canonical = marker |> Map.put("status", "authorized") |> json_value()
      put_live(ticket, %{ticket: ticket, marker: canonical, immutable: Map.delete(canonical, "status"), observation: :unused, denial: nil, continuation: nil})
      {:ok, ticket}
    end
  end

  defp prepare_result(marker, %{status: status, command: command, output: output}) when is_binary(command) and is_binary(output) do
    status = if is_atom(status), do: Atom.to_string(status), else: status

    if is_binary(status) and status != "" and command_digest(command) == marker["command_digest"] do
      attrs = event_attrs(marker, "Observed a deployment command result; remote effects are not independently verified.")

      metadata = Map.merge(attrs.metadata, %{intent_event_id: marker["intent"]["event_id"], result: %{status: status, command: command, output: output}})
      RunLedger.prepare_entry("deploy.#{marker["target"]}.observed", Map.put(attrs, :metadata, metadata))
    else
      {:error, :invalid_deploy_audit_result}
    end
  end

  defp prepare_result(_marker, _result), do: {:error, :invalid_deploy_audit_result}

  defp successful_result(event) do
    case get_in(event, ["metadata", "result", "status"]) || get_in(event, [:metadata, :result, :status]) do
      "passed" -> :ok
      status -> {:error, {:deploy_audit_result_uncertain, status}}
    end
  end

  defp event_attrs(marker, summary) do
    attrs = %{
      issue_id: marker["issue_id"],
      issue_identifier: marker["issue_identifier"],
      stage: marker["stage"],
      actor_type: "runtime",
      actor_id: marker["owner"],
      summary: summary,
      metadata: %{
        deploy_operation_id: marker["operation_id"],
        workspace: marker["workspace"],
        target: marker["target"],
        command_digest: marker["command_digest"],
        owner: marker["owner"],
        lease_owner: marker["lease_owner"],
        lease_epoch: marker["lease_epoch"],
        entry_event_id: marker["entry_event_id"]
      }
    }

    case get_in(marker, ["execution", "provenance"]) do
      nil -> attrs
      execution -> put_in(attrs, [:metadata, :execution], execution)
    end
  end

  defp command_digest(command), do: :crypto.hash(:sha256, command) |> Base.encode16(case: :lower)

  defp live_ticket(%{operation_id: id, owner_pid: owner, version: version, live_ref: ref} = ticket)
       when is_binary(id) and version in [1, 2] and is_reference(ref) do
    with true <- owner == self() or {:error, :deploy_audit_wrong_owner} do
      case Process.get({__MODULE__, id}) do
        %{ticket: ^ticket} = live -> {:ok, live}
        _ -> {:error, :deploy_audit_ticket_mismatch}
      end
    end
  end

  defp live_ticket(_ticket), do: {:error, :invalid_deploy_audit_ticket}
  defp put_live(ticket, live), do: Process.put({__MODULE__, ticket.operation_id}, live)

  defp unused_ticket(ticket) do
    with {:ok, live} <- live_ticket(ticket) do
      case live.observation do
        :unused -> {:ok, live}
        _ when ticket.version == 1 -> {:error, :deploy_audit_result_already_started}
        {phase, receipt} -> {:error, {:deploy_audit_observation_already_attempted, %{phase: phase, receipt: receipt}}}
        {phase, _event, receipt} -> {:error, {:deploy_audit_observation_already_attempted, %{phase: phase, receipt: receipt}}}
      end
    end
  end

  defp validated_ticket(ticket) do
    with {:ok, live} <- live_ticket(ticket),
         {:ok, marker} <- read_marker(ticket.workspace),
         true <-
           Map.drop(marker, ["status", "result", "continuation", "continuation_denied"]) == live.immutable or
             {:error, :deploy_audit_ticket_mismatch} do
      {:ok, marker}
    end
  end

  defp read_marker(workspace) do
    directory = marker_directory(workspace)
    path = Path.join(directory, @marker_name)

    with {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, payload} <- File.read(path),
         {:ok, marker} <- Jason.decode(payload),
         :ok <- validate_marker(marker, Path.expand(workspace)) do
      {:ok, marker}
    else
      {:error, reason} -> {:error, {:deploy_audit_marker_unreadable, reason}}
      {:ok, _invalid_type} -> {:error, :invalid_deploy_audit_marker_type}
    end
  end

  defp validate_marker(
         %{
           "version" => version,
           "workspace" => workspace,
           "operation_id" => id,
           "owner" => owner,
           "issue_id" => issue_id,
           "issue_identifier" => identifier,
           "stage" => stage,
           "target" => target,
           "command_digest" => digest,
           "entry_event_id" => entry_event_id,
           "entry" => entry,
           "lease_owner" => lease_owner,
           "lease_epoch" => lease_epoch,
           "ledger_path" => ledger_path,
           "status" => status,
           "intent" => intent
         } = marker,
         workspace
       )
       when version in [1, 2] and is_binary(id) and id != "" and is_binary(owner) and owner != "" and is_binary(issue_id) and issue_id != "" and is_binary(identifier) and identifier != "" and
              stage in @stages and target in ["preview", "production"] and is_binary(digest) and byte_size(digest) == 64 and
              is_binary(entry_event_id) and entry_event_id != "" and is_map(entry) and (is_binary(lease_owner) or is_nil(lease_owner)) and
              (is_integer(lease_epoch) or is_nil(lease_epoch)) and is_binary(ledger_path) and ledger_path != "" and
              status in ["prepared", "authorized", "result_pending", "result_confirmed", "finishing"] and is_map(intent) do
    if (not Map.has_key?(marker, "continuation_denied") or valid_denial?(marker["continuation_denied"])) and
         valid_marker_execution?(marker) and stage == "deploy_" <> target and matching_event?(intent, "deploy.#{target}.requested", marker) and
         entry["event_id"] == entry_event_id and entry["event_type"] == "stage.transition" and entry["issue_id"] == issue_id and
         entry["issue_identifier"] == identifier and entry["stage"] == stage,
       do: :ok,
       else: {:error, :invalid_deploy_audit_marker}
  end

  defp validate_marker(_marker, _workspace), do: {:error, :invalid_deploy_audit_marker}

  defp matching_event?(%{"metadata" => %{} = metadata} = event, type, marker) do
    event["event_type"] == type and is_binary(event["event_id"]) and event["event_id"] != "" and
      event["issue_id"] == marker["issue_id"] and event["issue_identifier"] == marker["issue_identifier"] and event["stage"] == marker["stage"] and
      metadata["deploy_operation_id"] == marker["operation_id"] and metadata["workspace"] == marker["workspace"] and
      metadata["target"] == marker["target"] and metadata["command_digest"] == marker["command_digest"] and metadata["owner"] == marker["owner"] and
      metadata["lease_owner"] == marker["lease_owner"] and metadata["lease_epoch"] == marker["lease_epoch"] and metadata["entry_event_id"] == marker["entry_event_id"] and
      metadata["execution"] == get_in(marker, ["execution", "provenance"])
  end

  defp matching_event?(_event, _type, _marker), do: false

  defp validate_result(%{"result" => %{"metadata" => %{"result" => result}} = event} = marker) when is_map(result) do
    if matching_event?(event, "deploy.#{marker["target"]}.observed", marker) and
         event["metadata"]["intent_event_id"] == marker["intent"]["event_id"] and event["event_id"] != marker["intent"]["event_id"] and
         is_binary(result["status"]) and result["status"] != "" and is_binary(result["command"]) and is_binary(result["output"]) and
         command_digest(result["command"]) == marker["command_digest"],
       do: :ok,
       else: {:error, :invalid_deploy_audit_result}
  end

  defp validate_result(_marker), do: {:error, :invalid_deploy_audit_result}

  defp validate_recorded_intent(marker) do
    with :ok <- ensure_ledger_path(marker["ledger_path"]),
         {:ok, entry} <- RunLedger.fetch_entry_checked(marker["entry_event_id"]),
         true <- entry == marker["entry"] or {:error, :deploy_audit_entry_mismatch},
         {:ok, intent} <- RunLedger.fetch_entry_checked(marker["intent"]["event_id"]),
         true <- intent == marker["intent"] or {:error, :deploy_audit_intent_mismatch},
         :ok <- validate_dispatch_evidence(marker) do
      :ok
    end
  end

  defp validate_dispatch_evidence(%{"version" => 1}), do: :ok

  defp validate_dispatch_evidence(%{"version" => 2, "execution" => %{"dispatch_ticket" => dispatch}} = marker) do
    with {:ok, event} <- RunLedger.fetch_entry_checked(dispatch["entry_event_id"]),
         metadata when is_map(metadata) <- event["metadata"],
         true <-
           (event["event_type"] == "dispatch.started" and event["issue_id"] == marker["issue_id"] and
              event["issue_identifier"] == marker["issue_identifier"] and metadata["workspace"] == dispatch["workspace"] and
              metadata["run_id"] == dispatch["run_id"] and metadata["dispatch_id"] == dispatch["dispatch_id"] and
              metadata["owner"] == dispatch["owner"] and metadata["epoch"] == dispatch["epoch"]) or {:error, :deploy_audit_dispatch_mismatch} do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :deploy_audit_dispatch_mismatch}
    end
  end

  @doc false
  @spec ensure_ledger_path(Path.t()) :: :ok | {:error, term()}
  def ensure_ledger_path(expected) do
    with {:ok, current} <- RunLedger.ledger_file_path_checked(),
         true <- current == expected or {:error, :deploy_audit_ledger_changed} do
      :ok
    end
  end

  defp validate_continuation(%{"event_type" => "stage.transition", "metadata" => %{} = metadata} = event, stage, context) do
    if is_binary(event["event_id"]) and event["event_id"] != "" and event["issue_id"] == context.issue_id and
         event["issue_identifier"] == context.issue_identifier and event["stage"] == stage and metadata["previous_stage"] == context.stage and
         metadata["deploy_operation_id"] == context.operation_id and metadata["deploy_intent_event_id"] == context.intent_event_id and
         metadata["deploy_result_event_id"] == context.result_event_id,
       do: :ok,
       else: {:error, :deploy_audit_continuation_mismatch}
  end

  defp validate_continuation(_event, _stage, _context), do: {:error, :deploy_audit_continuation_mismatch}

  defp matching_continuation_snapshot(state, context, stage, event) do
    if state[:issue_id] == context.issue_id and state[:issue_identifier] == context.issue_identifier and state[:stage] == stage and
         state[:last_ledger_event_id] == event["event_id"] and state[:last_deploy_operation_id] == context.operation_id and
         state[:lease_owner] == context.lease_owner and state[:lease_epoch] == context.lease_epoch and is_nil(state[:stop_reason]),
       do: :ok,
       else: {:error, :deploy_audit_snapshot_conflict}
  end

  defp create_marker_directory(workspace) do
    directory = marker_directory(workspace)

    with :ok <- File.mkdir_p(Path.dirname(directory)) do
      case File.mkdir(directory) do
        :ok -> :ok
        {:error, reason} -> {:error, {:deploy_audit_directory_failed, reason}}
      end
    end
  end

  defp write_marker(workspace, marker) do
    path = Path.join(marker_directory(workspace), @marker_name)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- ensure_marker_target(workspace),
         {:ok, encoded} <- Jason.encode(marker),
         :ok <- File.write(temporary, encoded, [:write, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} -> {:error, {:deploy_audit_marker_write_failed, reason}}
    end
  end

  defp ensure_only_marker(workspace) do
    case File.ls(marker_directory(workspace)) do
      {:ok, [@marker_name]} -> :ok
      {:ok, _entries} -> {:error, :deploy_audit_unexpected_files}
      {:error, reason} -> {:error, {:deploy_audit_read_failed, reason}}
    end
  end

  defp ensure_marker_target(workspace) do
    with {:ok, %{type: :directory}} <- File.lstat(marker_directory(workspace)) do
      case File.lstat(Path.join(marker_directory(workspace), @marker_name)) do
        {:ok, %{type: :regular}} -> :ok
        {:error, :enoent} -> :ok
        {:ok, _unexpected} -> {:error, :invalid_marker_type}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, _unexpected} -> {:error, :invalid_marker_directory_type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_marker(workspace, marker) do
    case File.rm(Path.join(marker_directory(workspace), @marker_name)) do
      :ok ->
        case File.rmdir(marker_directory(workspace)) do
          :ok -> :ok
          {:error, reason} -> {:error, {:deploy_audit_cleanup_failed, reason, write_marker(workspace, marker)}}
        end

      {:error, reason} ->
        {:error, {:deploy_audit_cleanup_failed, reason}}
    end
  end
end
