defmodule SymphonyElixir.DispatchAudit do
  @moduledoc """
  Persists dispatch admission outside the mutable workspace.

  A checked dispatch.started event authorizes execution; it does not assert that
  a worker has started. Only the owner may finish a ticket after observing worker
  exit or proving that no worker was created. Uncertain journals require explicit
  investigation; neither elapsed time nor lease takeover clears them.
  """

  alias SymphonyElixir.{RunIdentity, RunLedger, RunStateStore}

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

  @spec ensure_available(Path.t()) :: :ok | {:error, term()}
  def ensure_available(workspace) when is_binary(workspace) do
    case File.lstat(marker_directory(workspace)) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, {:dispatch_audit_pending, Path.expand(workspace)}}
      {:error, reason} -> {:error, {:dispatch_audit_read_failed, reason}}
    end
  end

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
    metadata = Map.merge(Map.delete(attrs.metadata, "runtime_build"), %{dispatch_id: dispatch_id, run_id: attrs.run_id, workspace: workspace, runtime_build: SymphonyElixir.BuildIdentity.summary()})
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
      metadata["run_id"] == marker["run_id"] and metadata["dispatch_id"] == marker["dispatch_id"] and metadata["workspace"] == marker["workspace"] and
      metadata["owner"] == marker["owner"] and metadata["epoch"] == marker["epoch"]
  end

  defp matching_event?(_event, _type, _marker), do: false

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
