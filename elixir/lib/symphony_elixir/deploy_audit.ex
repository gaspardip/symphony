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

  alias SymphonyElixir.{RunLedger, RunStateStore}

  @marker_name "marker.json"
  @stages ["deploy_preview", "deploy_production"]
  @destinations ["post_deploy_verify", "done"]
  @type ticket :: %{
          workspace: Path.t(),
          operation_id: String.t(),
          owner_pid: pid(),
          intent_event_id: String.t(),
          ledger_path: Path.t()
        }
  @type continuation :: %{stage: String.t(), event: map()}

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
             {:ok, state} <- RunStateStore.load(workspace),
             :ok <- matching_snapshot(state, attrs),
             {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
             {:ok, entry} <- snapshot_entry(state),
             :ok <- ensure_ledger_path(ledger_path),
             :ok <- create_marker_directory(workspace) do
          prepare_intent(workspace, attrs, state, ledger_path, entry)
        end
      end)
    end
  end

  @doc "Records an observation once. Any non-passed observation remains pending, even if its audit succeeds."
  @spec record_result(ticket(), map()) :: :ok | {:error, term()}
  def record_result(%{workspace: workspace} = ticket, result) when is_binary(workspace) and is_map(result) do
    RunStateStore.with_workspace_lock(workspace, fn ->
      with {:ok, marker} <- validated_ticket(ticket),
           true <- marker["status"] == "authorized" or {:error, :deploy_audit_result_already_started},
           {:ok, observed} <- prepare_result(marker, result),
           pending = Map.merge(marker, %{"status" => "result_pending", "result" => observed}),
           :ok <- write_marker(workspace, pending),
           :ok <- validate_recorded_intent(marker),
           :ok <- ensure_ledger_path(marker["ledger_path"]),
           {:ok, _entry} <- RunLedger.persist_prepared(observed),
           :ok <- ensure_ledger_path(marker["ledger_path"]),
           :ok <- write_marker(workspace, Map.put(pending, "status", "result_confirmed")) do
        successful_result(observed)
      end
    end)
  end

  @doc false
  @spec continuation_context(ticket()) :: {:ok, map()} | {:error, term()}
  def continuation_context(ticket) do
    with {:ok, marker} <- validated_ticket(ticket),
         true <- marker["status"] == "result_confirmed" or {:error, :deploy_audit_result_unconfirmed},
         :ok <- validate_recorded_intent(marker),
         :ok <- validate_result(marker),
         {:ok, result} <- RunLedger.fetch_entry_checked(marker["result"]["event_id"]),
         true <- result == marker["result"] or {:error, :deploy_audit_result_mismatch},
         :ok <- successful_result(result) do
      {:ok,
       %{
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
         result: %{
           status: result["metadata"]["result"]["status"],
           command: result["metadata"]["result"]["command"],
           output: result["metadata"]["result"]["output"]
         }
       }}
    end
  end

  @doc "Closes only a successful operation whose own exact continuation is still current."
  @spec finish(ticket(), continuation()) :: :ok | {:error, term()}
  def finish(%{workspace: workspace} = ticket, %{stage: stage, event: event}) when is_binary(workspace) and is_map(event) do
    RunStateStore.with_workspace_lock(workspace, fn ->
      with {:ok, context} <- continuation_context(ticket),
           true <- stage in @destinations or {:error, :invalid_deploy_audit_destination},
           :ok <- validate_continuation(event, stage, context),
           :ok <- ensure_ledger_path(context.ledger_path),
           {:ok, recorded} <- RunLedger.fetch_entry_checked(event["event_id"]),
           true <- recorded == event or {:error, :deploy_audit_continuation_mismatch},
           {:ok, state} <- RunStateStore.load(workspace),
           :ok <- matching_continuation_snapshot(state, context, stage, event),
           :ok <- ensure_only_marker(workspace),
           {:ok, marker} <- validated_ticket(ticket),
           finishing = Map.merge(marker, %{"status" => "finishing", "continuation" => event}),
           :ok <- write_marker(workspace, finishing) do
        remove_marker(workspace, finishing)
      end
    end)
  end

  def finish(_ticket, _continuation), do: {:error, :invalid_deploy_audit_continuation}

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

  defp prepare_intent(workspace, attrs, state, ledger_path, entry) do
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

    with {:ok, intent} <- RunLedger.prepare_entry("deploy.#{target}.requested", event_attrs(marker, "Requested deployment; command execution has not yet been observed.")),
         marker = Map.put(marker, "intent", intent),
         :ok <- write_marker(workspace, marker),
         :ok <- ensure_ledger_path(ledger_path),
         {:ok, _entry} <- RunLedger.persist_prepared(intent),
         :ok <- ensure_ledger_path(ledger_path),
         :ok <- write_marker(workspace, Map.put(marker, "status", "authorized")) do
      {:ok, %{workspace: workspace, operation_id: operation_id, owner_pid: self(), intent_event_id: intent.event_id, ledger_path: ledger_path}}
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
    %{
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
  end

  defp command_digest(command), do: :crypto.hash(:sha256, command) |> Base.encode16(case: :lower)

  defp validated_ticket(%{workspace: workspace, operation_id: id, owner_pid: owner, intent_event_id: event_id, ledger_path: ledger_path}) when is_binary(workspace) do
    with true <- owner == self() or {:error, :deploy_audit_wrong_owner},
         {:ok, marker} <- read_marker(workspace),
         true <-
           (marker["operation_id"] == id and marker["owner"] == inspect(owner) and
              marker["intent"]["event_id"] == event_id and marker["ledger_path"] == ledger_path) or {:error, :deploy_audit_ticket_mismatch} do
      {:ok, marker}
    end
  end

  defp validated_ticket(_ticket), do: {:error, :invalid_deploy_audit_ticket}

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
           "version" => 1,
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
       when is_binary(id) and id != "" and is_binary(owner) and owner != "" and is_binary(issue_id) and issue_id != "" and is_binary(identifier) and identifier != "" and
              stage in @stages and target in ["preview", "production"] and is_binary(digest) and byte_size(digest) == 64 and
              is_binary(entry_event_id) and entry_event_id != "" and is_map(entry) and (is_binary(lease_owner) or is_nil(lease_owner)) and
              (is_integer(lease_epoch) or is_nil(lease_epoch)) and is_binary(ledger_path) and ledger_path != "" and
              status in ["prepared", "authorized", "result_pending", "result_confirmed", "finishing"] and is_map(intent) do
    if stage == "deploy_" <> target and matching_event?(intent, "deploy.#{target}.requested", marker) and
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
      metadata["lease_owner"] == marker["lease_owner"] and metadata["lease_epoch"] == marker["lease_epoch"] and metadata["entry_event_id"] == marker["entry_event_id"]
  end

  defp matching_event?(_event, _type, _marker), do: false

  defp validate_result(%{"result" => %{"metadata" => %{"result" => result}} = event} = marker) when is_map(result) do
    if matching_event?(event, "deploy.#{marker["target"]}.observed", marker) and
         event["metadata"]["intent_event_id"] == marker["intent"]["event_id"] and event["event_id"] != marker["intent"]["event_id"] and
         is_binary(result["status"]) and is_binary(result["command"]) and is_binary(result["output"]),
       do: :ok,
       else: {:error, :invalid_deploy_audit_result}
  end

  defp validate_result(_marker), do: {:error, :invalid_deploy_audit_result}

  defp validate_recorded_intent(marker) do
    with :ok <- ensure_ledger_path(marker["ledger_path"]),
         {:ok, entry} <- RunLedger.fetch_entry_checked(marker["entry_event_id"]),
         true <- entry == marker["entry"] or {:error, :deploy_audit_entry_mismatch},
         {:ok, intent} <- RunLedger.fetch_entry_checked(marker["intent"]["event_id"]),
         true <- intent == marker["intent"] or {:error, :deploy_audit_intent_mismatch} do
      :ok
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
