defmodule SymphonyElixir.DispatchAudit do
  @moduledoc """
  Persists dispatch admission outside the mutable workspace.

  A checked dispatch.started event authorizes execution; it does not assert that
  a worker has started. Only the owner may finish a ticket after observing worker
  exit or proving that no worker was created. Uncertain journals require explicit
  investigation; neither elapsed time nor lease takeover clears them.

  Event workspace text is redacted for display. New events bind the captured
  canonical workspace by SHA-256; older events retain exact literal matching.
  """

  alias SymphonyElixir.{DeployAudit, LeaseManager, RuleCatalog, RunIdentity, RunLedger, RunStateStore}

  @context_key {__MODULE__, :authorization}
  @ticket_key {__MODULE__, :ticket}
  @marker_name "marker.json"
  @type ticket :: %{
          workspace: Path.t(),
          dispatch_id: String.t(),
          run_id: String.t(),
          entry_event_id: String.t(),
          owner: String.t(),
          epoch: pos_integer(),
          ledger_path: Path.t()
        }

  @spec marker_directory(Path.t()) :: Path.t()
  def marker_directory(workspace) when is_binary(workspace) do
    workspace = Path.expand(workspace)
    Path.join(Path.dirname(workspace), "." <> Path.basename(workspace) <> ".dispatch-audit")
  end

  @spec begin(Path.t(), map()) :: {:ok, ticket()} | {:error, term()}
  def begin(workspace, attrs) when is_binary(workspace) and is_map(attrs) do
    workspace = Path.expand(workspace)

    with :ok <- validate_attrs(attrs) do
      RunStateStore.with_workspace_lock(workspace, fn ->
        with :ok <- ensure_available(workspace),
             :ok <- ensure_begin_snapshot(workspace, attrs),
             :ok <- create_marker_directory(workspace),
             {:ok, run_id} <- RunIdentity.admit(workspace, attrs) do
          prepare_dispatch(workspace, Map.put(attrs, :run_id, run_id))
        end
      end)
    end
  end

  @doc "Admits only the captured material source and returns the raw snapshot produced by that admission."
  @spec begin(Path.t(), map(), RunStateStore.admission_source()) :: {:ok, ticket(), map()} | {:error, term()}
  def begin(workspace, attrs, source) when is_binary(workspace) and is_map(attrs) do
    workspace = Path.expand(workspace)

    with :ok <- validate_attrs(attrs) do
      issue = %{id: attrs.issue_id, identifier: attrs.issue_identifier}

      RunStateStore.with_workspace_lock(workspace, fn ->
        with :ok <- ensure_available(workspace),
             {:ok, current_source, view} <- RunStateStore.read_admission_source(workspace, issue),
             :ok <- matching_admission_source(source, current_source),
             :ok <- valid_admission_stage(view, attrs),
             :ok <- create_marker_directory(workspace),
             {:ok, run_id} <- RunIdentity.admit(workspace, attrs),
             {:ok, admitted_raw} <- read_admitted_snapshot(workspace, issue),
             :ok <- matching_admitted_material(current_source, admitted_raw),
             {:ok, ticket} <- prepare_dispatch(workspace, Map.put(attrs, :run_id, run_id)) do
          {:ok, ticket, admitted_raw}
        end
      end)
    end
  end

  defp read_admitted_snapshot(workspace, issue) do
    case RunStateStore.read_admission_source(workspace, issue) do
      {:ok, {:present, raw}, _view} -> {:ok, raw}
      {:ok, :missing, _view} -> {:error, {:stale_execution, :admitted_snapshot_missing}}
      {:error, _reason} = error -> error
    end
  end

  defp matching_admission_source(:missing, :missing), do: :ok

  defp matching_admission_source({:present, expected}, {:present, current}) when is_map(expected) and is_map(current) do
    identity_fields = ~w(issue_id issue_identifier run_id run_identity_event_id run_identity_ledger_path)

    if Map.take(expected, identity_fields) == Map.take(current, identity_fields) and
         RunStateStore.material_projection(expected) == RunStateStore.material_projection(current),
       do: :ok,
       else: {:error, {:stale_execution, :admission_source_changed}}
  end

  defp matching_admission_source(_expected, _current), do: {:error, {:stale_execution, :admission_source_changed}}

  defp matching_admitted_material(:missing, _admitted_raw), do: :ok

  defp matching_admitted_material({:present, previous}, admitted_raw) do
    if RunStateStore.material_projection(previous) == RunStateStore.material_projection(admitted_raw),
      do: :ok,
      else: {:error, {:stale_execution, :admission_material_changed}}
  end

  defp valid_admission_stage(%{stage: stage}, _attrs) when stage in ["blocked", "done"],
    do: {:error, {:persisted_stage_requires_explicit_resume, stage}}

  defp valid_admission_stage(%{stage: stage}, attrs) do
    if is_nil(attrs[:stage]) or attrs[:stage] == stage,
      do: :ok,
      else: {:error, {:stale_execution, :admission_stage_changed}}
  end

  @spec ensure_available(Path.t()) :: :ok | {:error, term()}
  def ensure_available(workspace) when is_binary(workspace) do
    case File.lstat(marker_directory(workspace)) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, {:dispatch_audit_pending, Path.expand(workspace)}}
      {:error, reason} -> {:error, {:dispatch_audit_read_failed, reason}}
    end
  end

  @doc """
  Records a blocked continuation after rejected admission to an interrupted run.
  The caller must have no active worker for this issue. Missing or expired custody
  is not proof of worker death. This preserves the dispatch journal and lease;
  it neither executes work nor grants authority to resolve the old dispatch.
  """
  @spec block_interrupted(Path.t(), %{id: String.t(), identifier: String.t()}) :: {:ok, map()} | {:error, term()}
  def block_interrupted(workspace, issue), do: do_block_interrupted(workspace, issue, :missing_or_expired)

  @doc "Automatically diagnoses only a retained expired lease; missing or live custody preserves the original pending rejection."
  @spec block_interrupted_if_expired(Path.t(), %{id: String.t(), identifier: String.t()}) ::
          {:ok, map() | {:skipped, :lease_missing | :lease_still_active}} | {:error, term()}
  def block_interrupted_if_expired(workspace, issue) do
    case do_block_interrupted(workspace, issue, :expired_only) do
      {:error, :lease_still_active} -> {:ok, {:skipped, :lease_still_active}}
      result -> result
    end
  end

  defp do_block_interrupted(workspace, %{id: id, identifier: identifier} = issue, custody_policy)
       when is_binary(workspace) and is_binary(id) and id != "" and is_binary(identifier) and identifier != "" do
    workspace = Path.expand(workspace)

    result =
      RunStateStore.with_workspace_lock(workspace, fn ->
        with :ok <- DeployAudit.ensure_available(workspace),
             {:ok, marker} <- read_marker(workspace),
             true <- (marker["version"] == 2 and marker["status"] == "authorized") or {:error, :dispatch_audit_not_interrupted},
             true <- (marker["authorized"]["issue_id"] == id and marker["authorized"]["issue_identifier"] == identifier) or {:error, :dispatch_audit_issue_mismatch},
             :ok <- validate_recorded_admission(marker),
             {:ok, rows, _digest} <- RunLedger.CheckedStorage.entries_checked(marker["ledger_path"]),
             true <- not Enum.any?(rows, &interrupted_dispatch_finished?(&1, marker)) or {:error, :dispatch_audit_already_finished},
             {:ok, storage} <- LeaseManager.capture_storage(id),
             true <- storage.ledger_path == marker["ledger_path"] or {:error, :dispatch_audit_ledger_changed} do
          LeaseManager.with_inactive(storage, fn observation ->
            with :ok <- interrupted_observation_allowed(observation, custody_policy),
                 :ok <- interrupted_lease_matches(observation, marker),
                 {:ok, raw, state, bytes} <- interrupted_snapshot(workspace, issue, marker),
                 {:ok, marker_bytes} <- File.read(Path.join(marker_directory(workspace), @marker_name)),
                 true <- Jason.decode(marker_bytes) == {:ok, marker} or {:error, :dispatch_audit_marker_changed} do
              persist_interrupted_block(workspace, marker, marker_bytes, storage, observation, raw, state, bytes)
            end
          end)
        end
      end)

    case result do
      :aborted -> {:error, :dispatch_audit_workspace_lock_aborted}
      result -> result
    end
  end

  defp do_block_interrupted(_workspace, _issue, _custody_policy), do: {:error, :invalid_interrupted_issue}

  defp interrupted_observation_allowed(:missing, :expired_only), do: {:ok, {:skipped, :lease_missing}}
  defp interrupted_observation_allowed(:missing, :missing_or_expired), do: :ok

  defp interrupted_observation_allowed({:expired, _lease, _bytes}, custody_policy)
       when custody_policy in [:missing_or_expired, :expired_only], do: :ok

  defp interrupted_dispatch_finished?(row, marker) do
    row["event_type"] == "dispatch.finished" and is_map(row["metadata"]) and row["metadata"]["dispatch_id"] == marker["dispatch_id"]
  end

  defp interrupted_lease_matches(:missing, _marker), do: :ok

  defp interrupted_lease_matches({:expired, lease, _bytes}, marker) do
    if lease["owner"] == marker["owner"] and lease["epoch"] == marker["epoch"] and lease["issue_identifier"] == marker["authorized"]["issue_identifier"],
      do: :ok,
      else: {:error, :dispatch_audit_lease_mismatch}
  end

  defp interrupted_snapshot(workspace, issue, marker) do
    with :ok <- interrupted_path_type(workspace, :directory),
         :ok <- interrupted_path_type(Path.join(workspace, ".symphony"), :directory),
         :ok <- interrupted_path_type(RunStateStore.state_path(workspace), :regular),
         {:ok, bytes} <- File.read(RunStateStore.state_path(workspace)),
         {:ok, raw} <- Jason.decode(bytes),
         true <- is_map(raw) or {:error, :invalid_state},
         {:ok, state} <- RunStateStore.load(workspace),
         true <- RunStateStore.snapshot_digest(state) == RunStateStore.snapshot_digest(raw) or {:error, :dispatch_audit_snapshot_changed},
         true <- (raw["issue_id"] == issue.id and raw["issue_identifier"] == issue.identifier and raw["run_id"] == marker["run_id"]) or {:error, :dispatch_audit_snapshot_mismatch},
         :ok <- RunIdentity.verify(workspace, marker["run_id"], issue.id, issue.identifier),
         true <- is_map(raw["resume_context"]) or {:error, :invalid_interrupted_resume_context} do
      {:ok, raw, state, bytes}
    end
  end

  defp interrupted_path_type(path, expected) do
    case File.lstat(path) do
      {:ok, %{type: ^expected}} -> :ok
      {:ok, _stat} -> {:error, :invalid_interrupted_snapshot_path_type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_interrupted_block(_workspace, marker, marker_bytes, _storage, _observation, %{"stage" => "blocked"} = raw, state, _bytes) do
    with :ok <- matching_interrupted_block(raw, marker, marker_bytes), do: {:ok, state}
  end

  defp persist_interrupted_block(workspace, marker, marker_bytes, storage, observation, raw, state, bytes) do
    with true <- raw["stage"] in ["implement", "validate"] or {:error, :dispatch_audit_checkpoint_not_interruptible},
         true <- not Map.has_key?(raw["resume_context"], "dispatch_interruption") or {:error, :dispatch_audit_diagnostic_conflict} do
      summary = "Continuation is blocked by an unresolved dispatch from the previous owner; worker termination is unconfirmed."
      rule_id = RuleCatalog.rule_id(:dispatch_audit_pending)
      failure_class = RuleCatalog.failure_class(:dispatch_audit_pending)
      action = RuleCatalog.human_action(:dispatch_audit_pending)

      evidence = %{
        dispatch_id: marker["dispatch_id"],
        run_id: marker["run_id"],
        authorization_event_id: marker["authorized"]["event_id"],
        owner: marker["owner"],
        epoch: marker["epoch"],
        marker_path: Path.join(marker_directory(workspace), @marker_name),
        marker_sha256: workspace_digest(marker_bytes),
        marker_status: marker["status"],
        observed_at: DateTime.to_iso8601(DateTime.utc_now()),
        lease: interrupted_lease_evidence(storage, observation),
        checkpoint: %{
          snapshot_sha256: workspace_digest(bytes),
          previous_fields:
            Map.take(
              raw,
              ~w(stage resume_stage stop_reason last_decision last_rule_id last_failure_class last_decision_summary next_human_action last_ledger_event_id reason stage_history stage_transition_counts)
            )
        }
      }

      RunStateStore.transition(workspace, "blocked", %{
        resume_stage: raw["stage"],
        resume_context: Map.put(state.resume_context, :dispatch_interruption, evidence),
        stop_reason: %{code: "dispatch_audit_pending", rule_id: rule_id, failure_class: failure_class, summary: summary, human_action: action},
        last_decision: nil,
        last_rule_id: rule_id,
        last_failure_class: failure_class,
        last_decision_summary: summary,
        next_human_action: action,
        reason: "Blocked continuation for unresolved dispatch #{marker["dispatch_id"]}, authorization #{marker["authorized"]["event_id"]}."
      })
    end
  end

  defp interrupted_lease_evidence(storage, :missing), do: %{status: "missing", path: storage.lease_path, ttl_ms: storage.ttl_ms}

  defp interrupted_lease_evidence(storage, {:expired, lease, bytes}) do
    %{
      status: "expired",
      path: storage.lease_path,
      sha256: workspace_digest(bytes),
      ttl_ms: storage.ttl_ms,
      age_ms: LeaseManager.age_ms(lease),
      identity: Map.take(lease, ~w(issue_id issue_identifier owner epoch lease_version lease_generation acquired_at updated_at))
    }
  end

  defp matching_interrupted_block(
         %{"resume_context" => %{"dispatch_interruption" => %{"checkpoint" => %{"previous_fields" => %{} = checkpoint}} = evidence}, "stop_reason" => %{} = stop} = raw,
         marker,
         marker_bytes
       ) do
    binding = %{
      "run_id" => raw["run_id"],
      "run_identity_event_id" => raw["run_identity_event_id"],
      "run_identity_ledger_path" => raw["run_identity_ledger_path"],
      "workspace" => SymphonyElixir.SecretRedactor.redact(marker["workspace"]),
      "workspace_digest" => workspace_digest(marker["workspace"])
    }

    valid =
      is_binary(raw["last_ledger_event_id"]) and raw["last_ledger_event_id"] != "" and
        checkpoint["stage"] in ["implement", "validate"] and raw["resume_stage"] == checkpoint["stage"] and
        evidence["dispatch_id"] == marker["dispatch_id"] and evidence["run_id"] == marker["run_id"] and
        evidence["authorization_event_id"] == marker["authorized"]["event_id"] and evidence["owner"] == marker["owner"] and evidence["epoch"] == marker["epoch"] and
        evidence["marker_sha256"] == workspace_digest(marker_bytes) and evidence["marker_status"] == "authorized" and
        stop["code"] == "dispatch_audit_pending" and stop["rule_id"] == RuleCatalog.rule_id(:dispatch_audit_pending) and
        raw["last_rule_id"] == stop["rule_id"] and raw["last_failure_class"] == RuleCatalog.failure_class(:dispatch_audit_pending) and
        raw["next_human_action"] == RuleCatalog.human_action(:dispatch_audit_pending)

    with true <- valid or {:error, :dispatch_audit_diagnostic_conflict},
         {:ok, event} <- RunLedger.fetch_entry_checked(raw["last_ledger_event_id"]),
         true <- match?(%{"metadata" => %{"run_binding" => %{}, "snapshot_digest" => _}}, event) or {:error, :dispatch_audit_diagnostic_unconfirmed},
         before_finalization =
           if(Map.has_key?(checkpoint, "last_ledger_event_id"), do: Map.put(raw, "last_ledger_event_id", checkpoint["last_ledger_event_id"]), else: Map.delete(raw, "last_ledger_event_id")),
         true <-
           (event["event_type"] == "stage.transition" and event["stage"] == "blocked" and event["issue_id"] == raw["issue_id"] and event["issue_identifier"] == raw["issue_identifier"] and
              get_in(event, ["metadata", "run_binding"]) == binding and
              get_in(event, ["metadata", "snapshot_digest"]) == RunStateStore.snapshot_digest(before_finalization)) or {:error, :dispatch_audit_diagnostic_unconfirmed} do
      :ok
    end
  end

  defp matching_interrupted_block(_raw, _marker, _marker_bytes), do: {:error, :dispatch_audit_diagnostic_conflict}

  @spec ensure_workspace_access(Path.t()) :: :ok | {:error, term()}
  def ensure_workspace_access(workspace) when is_binary(workspace) do
    workspace = Path.expand(workspace)

    case ensure_available(workspace) do
      :ok ->
        :ok

      {:error, {:dispatch_audit_pending, _}} ->
        with {:ok, marker} <- read_marker(workspace),
             true <- marker["status"] == "authorized" or {:error, :dispatch_audit_not_authorized},
             true <- Process.get(@context_key) == marker_identity(marker) or {:error, :dispatch_audit_not_authorized} do
          ensure_authorized_snapshot(workspace, marker)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec with_authorization(ticket(), (-> result)) :: result | {:error, term()} when result: var
  def with_authorization(ticket, fun) when is_map(ticket) and is_function(fun, 0) do
    with {:ok, marker} <- validated_ticket(ticket),
         true <- marker["status"] == "authorized" or {:error, :dispatch_audit_not_authorized},
         :ok <- validate_recorded_admission(marker),
         :ok <- RunIdentity.verify(ticket.workspace, marker["run_id"], marker["authorized"]["issue_id"], marker["authorized"]["issue_identifier"]) do
      previous = Process.get(@context_key)
      previous_ticket = Process.get(@ticket_key)
      Process.put(@context_key, marker_identity(marker))
      Process.put(@ticket_key, ticket)

      try do
        fun.()
      after
        if is_nil(previous), do: Process.delete(@context_key), else: Process.put(@context_key, previous)
        if is_nil(previous_ticket), do: Process.delete(@ticket_key), else: Process.put(@ticket_key, previous_ticket)
      end
    end
  end

  @doc "Returns the ticket already validated by the current scoped authorization."
  @spec current_ticket() :: {:ok, ticket()} | {:error, :dispatch_context_missing}
  def current_ticket do
    case Process.get(@ticket_key) do
      nil -> {:error, :dispatch_context_missing}
      ticket -> {:ok, ticket}
    end
  end

  @doc """
  Called only by the owning coordinator after observing worker termination or
  proving that no worker was created. Ticket sharing across live coordinators is
  unsupported; finish and reconciliation use local, not distributed, exclusion.
  """
  @spec finish(ticket(), :normal | :not_started | {:exit, term()}) :: :ok | {:error, term()}
  def finish(%{workspace: workspace} = ticket, outcome) when is_binary(workspace) do
    with :ok <- validate_outcome(outcome) do
      RunStateStore.with_workspace_lock(workspace, fn ->
        with {:ok, marker} <- validated_ticket(ticket),
             true <- marker["status"] == "authorized" or {:error, :dispatch_audit_finish_uncertain},
             :ok <- validate_recorded_admission(marker),
             :ok <- ensure_only_marker(workspace),
             {:ok, finished} <- prepare_finished(marker, outcome),
             :ok <- write_marker(workspace, Map.merge(marker, %{"status" => "finishing", "finished" => finished})),
             {:ok, _entry} <- RunLedger.persist_prepared(finished),
             :ok <- remove_marker(workspace) do
          :ok
        end
      end)
    end
  end

  @doc """
  Explicit operator recovery after the previous execution has stopped, never
  concurrently with its live coordinator. Removes only an exactly confirmed
  finishing journal; never replays an audit write or opens an authorized ticket.
  """
  @spec reconcile_finished(Path.t()) :: :ok | {:error, term()}
  def reconcile_finished(workspace) when is_binary(workspace) do
    RunStateStore.with_workspace_lock(workspace, fn ->
      with {:ok, marker} <- read_marker(workspace),
           true <- marker["status"] == "finishing" or {:error, :dispatch_audit_not_finished},
           :ok <- validate_recorded_admission(marker),
           :ok <- validate_finished(marker),
           {:ok, recorded} <- RunLedger.fetch_entry_checked(marker["finished"]["event_id"]),
           true <- recorded == marker["finished"] or {:error, :dispatch_audit_finish_mismatch},
           :ok <- ensure_only_marker(workspace) do
        remove_marker(workspace)
      end
    end)
  end

  defp prepare_dispatch(workspace, attrs) do
    dispatch_id = SymphonyElixir.Util.generate_id("dispatch_")

    metadata =
      Map.merge(Map.drop(attrs.metadata, ["runtime_build", "workspace_digest"]), %{
        dispatch_id: dispatch_id,
        run_id: attrs.run_id,
        workspace: workspace,
        workspace_digest: workspace_digest(workspace),
        runtime_build: SymphonyElixir.BuildIdentity.summary()
      })

    attrs = attrs |> Map.put(:metadata, metadata) |> Map.put(:actor_type, "runtime") |> Map.put(:actor_id, attrs.metadata.owner)

    with {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
         {:ok, requested} <- RunLedger.prepare_entry("dispatch.requested", Map.put(attrs, :summary, "Requested admission for a gated worker.")),
         {:ok, authorized} <- RunLedger.prepare_entry("dispatch.started", Map.put(attrs, :summary, "Authorized a gated worker; execution has not yet been observed.")),
         {:ok, _entry} <- RunLedger.persist_prepared(requested) do
      marker = %{
        "version" => 2,
        "workspace" => workspace,
        "dispatch_id" => dispatch_id,
        "run_id" => attrs.run_id,
        "owner" => metadata.owner,
        "epoch" => metadata.epoch,
        "ledger_path" => ledger_path,
        "status" => "prepared",
        "requested" => requested,
        "authorized" => authorized
      }

      with :ok <- write_marker(workspace, marker),
           :ok <- ensure_ledger_path(ledger_path),
           {:ok, _entry} <- RunLedger.persist_prepared(authorized),
           :ok <- write_marker(workspace, Map.put(marker, "status", "authorized")) do
        {:ok, %{workspace: workspace, dispatch_id: dispatch_id, run_id: attrs.run_id, entry_event_id: authorized.event_id, owner: metadata.owner, epoch: metadata.epoch, ledger_path: ledger_path}}
      end
    end
  end

  defp validate_attrs(%{issue_id: id, issue_identifier: identifier, metadata: %{owner: owner, epoch: epoch}})
       when is_binary(id) and id != "" and is_binary(identifier) and identifier != "" and is_binary(owner) and owner != "" and is_integer(epoch) and epoch > 0,
       do: :ok

  defp validate_attrs(_attrs), do: {:error, :invalid_dispatch_audit_attrs}
  defp validate_outcome(outcome) when outcome in [:normal, :not_started], do: :ok
  defp validate_outcome({:exit, _reason}), do: :ok
  defp validate_outcome(_outcome), do: {:error, :invalid_dispatch_audit_outcome}

  defp ensure_begin_snapshot(workspace, attrs) do
    with :ok <- RunStateStore.ensure_readable(workspace) do
      case RunStateStore.load_checked(workspace, %{id: attrs.issue_id, identifier: attrs.issue_identifier}) do
        {:ok, %{stage: stage}} when stage in ["blocked", "done"] -> {:error, {:persisted_stage_requires_explicit_resume, stage}}
        {:ok, _state} -> :ok
        {:mismatch, _state} -> {:error, :run_identity_issue_mismatch}
        {:error, :missing} -> :ok
        {:error, reason} -> {:error, {:run_state_unreadable, reason}}
      end
    end
  end

  defp ensure_authorized_snapshot(workspace, marker) do
    case RunStateStore.load(workspace) do
      {:ok, %{stage: stage}} when stage in ["blocked", "done"] -> {:error, {:persisted_stage_requires_explicit_resume, stage}}
      {:ok, _state} -> RunIdentity.verify(workspace, marker["run_id"], marker["authorized"]["issue_id"], marker["authorized"]["issue_identifier"])
      {:error, reason} -> {:error, {:run_state_unreadable, reason}}
    end
  end

  defp create_marker_directory(workspace) do
    directory = marker_directory(workspace)

    with :ok <- File.mkdir_p(Path.dirname(directory)) do
      case File.mkdir(directory) do
        :ok -> :ok
        {:error, reason} -> {:error, {:dispatch_audit_directory_failed, reason}}
      end
    end
  end

  defp write_marker(workspace, marker) do
    path = Path.join(marker_directory(workspace), @marker_name)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with {:ok, encoded} <- Jason.encode(marker),
         :ok <- File.write(temporary, encoded, [:write]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} -> {:error, {:dispatch_audit_marker_write_failed, reason}}
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
      {:error, reason} -> {:error, {:dispatch_audit_marker_unreadable, reason}}
      {:ok, _invalid_type} -> {:error, :invalid_dispatch_audit_marker_type}
    end
  end

  defp validate_marker(
         %{
           "version" => version,
           "workspace" => workspace,
           "dispatch_id" => id,
           "owner" => owner,
           "epoch" => epoch,
           "ledger_path" => path,
           "status" => status,
           "requested" => requested,
           "authorized" => authorized
         } = marker,
         workspace
       )
       when version in [1, 2] and is_binary(id) and id != "" and is_binary(owner) and owner != "" and is_integer(epoch) and epoch > 0 and is_binary(path) and path != "" and
              status in ["prepared", "authorized", "finishing"] and is_map(requested) and is_map(authorized) do
    if valid_marker_identity?(marker) and matching_event?(requested, "dispatch.requested", marker) and matching_event?(authorized, "dispatch.started", marker) and
         requested["event_id"] != authorized["event_id"] and requested["issue_id"] == authorized["issue_id"] and
         requested["issue_identifier"] == authorized["issue_identifier"],
       do: :ok,
       else: {:error, :invalid_dispatch_audit_marker}
  end

  defp validate_marker(_marker, _workspace), do: {:error, :invalid_dispatch_audit_marker}

  defp valid_marker_identity?(%{"version" => 1} = marker), do: not Map.has_key?(marker, "run_id")
  defp valid_marker_identity?(%{"version" => 2, "run_id" => run_id}), do: is_binary(run_id) and run_id != ""
  defp valid_marker_identity?(_marker), do: false

  defp matching_event?(%{"metadata" => %{} = metadata} = event, type, marker) do
    event["event_type"] == type and is_binary(event["event_id"]) and event["event_id"] != "" and
      metadata["run_id"] == marker["run_id"] and metadata["dispatch_id"] == marker["dispatch_id"] and matching_workspace?(metadata, marker["workspace"]) and
      metadata["owner"] == marker["owner"] and metadata["epoch"] == marker["epoch"]
  end

  defp matching_event?(_event, _type, _marker), do: false

  defp matching_workspace?(metadata, workspace) do
    case Map.fetch(metadata, "workspace_digest") do
      {:ok, digest} -> digest == workspace_digest(workspace)
      :error -> metadata["workspace"] == workspace
    end
  end

  defp workspace_digest(workspace), do: :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)

  defp validated_ticket(%{workspace: workspace, dispatch_id: id, run_id: run_id, entry_event_id: event_id, owner: owner, epoch: epoch, ledger_path: ledger_path})
       when is_binary(workspace) do
    with {:ok, marker} <- read_marker(workspace),
         true <-
           (marker_identity(marker) == {Path.expand(workspace), id, run_id, owner, epoch} and
              get_in(marker, ["authorized", "event_id"]) == event_id and marker["ledger_path"] == ledger_path) or {:error, :dispatch_audit_ticket_mismatch} do
      {:ok, marker}
    end
  end

  defp validated_ticket(%{workspace: workspace, dispatch_id: _, entry_event_id: _, owner: _, epoch: _, ledger_path: _} = ticket) when is_binary(workspace) do
    with {:ok, %{"version" => 1}} <- read_marker(workspace),
         false <- Map.has_key?(ticket, :run_id) do
      validated_ticket(Map.put(ticket, :run_id, nil))
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_dispatch_audit_ticket}
    end
  end

  defp validated_ticket(_ticket), do: {:error, :invalid_dispatch_audit_ticket}

  defp marker_identity(marker), do: {marker["workspace"], marker["dispatch_id"], marker["run_id"], marker["owner"], marker["epoch"]}

  defp validate_finished(%{"finished" => finished, "authorized" => authorized} = marker) when is_map(finished) do
    if matching_event?(finished, "dispatch.finished", marker) and
         finished["issue_id"] == authorized["issue_id"] and finished["issue_identifier"] == authorized["issue_identifier"] and
         get_in(finished, ["metadata", "authorization_event_id"]) == authorized["event_id"] and
         is_binary(get_in(finished, ["metadata", "outcome"])),
       do: :ok,
       else: {:error, :invalid_dispatch_audit_finish}
  end

  defp validate_finished(_marker), do: {:error, :invalid_dispatch_audit_finish}

  defp validate_recorded_admission(marker) do
    with :ok <- ensure_ledger_path(marker["ledger_path"]),
         {:ok, requested} <- RunLedger.fetch_entry_checked(marker["requested"]["event_id"]),
         true <- requested == marker["requested"] or {:error, :dispatch_audit_intent_mismatch},
         {:ok, authorized} <- RunLedger.fetch_entry_checked(marker["authorized"]["event_id"]),
         true <- authorized == marker["authorized"] or {:error, :dispatch_audit_authorization_mismatch} do
      :ok
    end
  end

  defp ensure_ledger_path(expected) do
    with {:ok, current} <- RunLedger.ledger_file_path_checked(),
         true <- current == expected or {:error, :dispatch_audit_ledger_changed} do
      :ok
    end
  end

  defp prepare_finished(marker, outcome) do
    authorized = marker["authorized"]

    RunLedger.prepare_entry("dispatch.finished", %{
      issue_id: authorized["issue_id"],
      issue_identifier: authorized["issue_identifier"],
      actor_type: "runtime",
      actor_id: marker["owner"],
      summary: "Closed dispatch admission after observed worker exit or confirmed absence of a worker.",
      metadata: %{
        dispatch_id: marker["dispatch_id"],
        run_id: marker["run_id"],
        workspace: marker["workspace"],
        workspace_digest: workspace_digest(marker["workspace"]),
        owner: marker["owner"],
        epoch: marker["epoch"],
        authorization_event_id: authorized["event_id"],
        outcome: inspect(outcome)
      }
    })
  end

  defp ensure_only_marker(workspace) do
    case File.ls(marker_directory(workspace)) do
      {:ok, [@marker_name]} -> :ok
      {:ok, _entries} -> {:error, :dispatch_audit_unexpected_files}
      {:error, reason} -> {:error, {:dispatch_audit_directory_read_failed, reason}}
    end
  end

  defp remove_marker(workspace) do
    with :ok <- File.rm(Path.join(marker_directory(workspace), @marker_name)),
         :ok <- File.rmdir(marker_directory(workspace)) do
      :ok
    else
      {:error, reason} -> {:error, {:dispatch_audit_cleanup_failed, reason}}
    end
  end
end
