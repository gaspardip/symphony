defmodule SymphonyElixir.RunIdentity do
  @moduledoc """
  Creates a logical run identity only during reserved dispatch admission.

  The dispatch reservation excludes competing admissions. A pending snapshot and
  that reservation survive uncertain writes; neither is automatically replayed.
  """

  alias SymphonyElixir.{RunLedger, RunStateStore, Util}

  @binding [:run_id, :run_identity_event_id, :run_identity_ledger_path]

  @spec validate_snapshot(map()) :: :ok | {:error, term()}
  def validate_snapshot(%{"run_identity_pending" => _}), do: {:error, :run_identity_pending}

  def validate_snapshot(state) do
    if Enum.all?(@binding, &(not Map.has_key?(state, Atom.to_string(&1)))) or
         Enum.all?(@binding, &present?(state[Atom.to_string(&1)])),
       do: :ok,
       else: {:error, :invalid_run_identity}
  end

  @doc "Preserves the established binding when an older writer omits it; replacement is an error."
  @spec preserve(map(), map()) :: {:ok, map()} | {:error, term()}
  def preserve(state, previous) do
    if is_nil(previous[:run_id]) do
      {:ok, state}
    else
      if state[:issue_id] == previous[:issue_id] and state[:issue_identifier] == previous[:issue_identifier] and
           Enum.all?(@binding, &(not Map.has_key?(state, &1) or state[&1] == previous[&1])),
         do: {:ok, Map.merge(state, Map.take(previous, @binding))},
         else: {:error, :run_identity_conflict}
    end
  end

  @doc "Rejects contradictory snapshots before pre-admission lease synchronization or stage repair."
  @spec ensure_issue(Path.t(), map()) :: :ok | {:error, term()}
  def ensure_issue(workspace, issue) do
    case RunStateStore.load(workspace) do
      {:ok, state} -> matching_issue(state, issue.id, issue.identifier)
      {:error, :missing} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Called by DispatchAudit under its workspace lock and exclusive journal reservation."
  @spec admit(Path.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def admit(workspace, attrs) do
    issue = %{id: attrs.issue_id, identifier: attrs.issue_identifier}

    with {:ok, state, origin} <- admission_snapshot(workspace, issue),
         :ok <- matching_issue(state, issue.id, issue.identifier) do
      case state[:run_id] do
        nil -> create(workspace, state, attrs, origin)
        run_id -> with :ok <- verify(workspace, run_id, issue.id, issue.identifier), do: {:ok, run_id}
      end
    end
  end

  @spec verify(Path.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def verify(workspace, run_id, issue_id, identifier) do
    with {:ok, state} <- RunStateStore.load(workspace),
         :ok <- matching_issue(state, issue_id, identifier),
         true <- (present?(run_id) and state[:run_id] == run_id) or {:error, :run_identity_mismatch},
         {:ok, path} <- RunLedger.ledger_file_path_checked(),
         true <- state[:run_identity_ledger_path] == path or {:error, :run_identity_ledger_changed},
         {:ok, confirmation} <- RunLedger.fetch_entry_checked(state[:run_identity_event_id]),
         :ok <- matching_confirmation(confirmation, state, workspace),
         {:ok, intent} <- RunLedger.fetch_entry_checked(confirmation["metadata"]["intent_event_id"]),
         :ok <- matching_intent(intent, confirmation) do
      :ok
    end
  end

  defp admission_snapshot(workspace, issue) do
    case RunStateStore.load(workspace) do
      {:ok, state} -> {:ok, state, "adopted"}
      {:error, :missing} -> {:ok, RunStateStore.load_or_default(workspace, issue), "created"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matching_issue(state, issue_id, identifier) do
    if state[:issue_id] == issue_id and state[:issue_identifier] == identifier,
      do: :ok,
      else: {:error, :run_identity_issue_mismatch}
  end

  defp create(workspace, state, attrs, origin) do
    run_id = Util.generate_id("run_")

    event_attrs = %{
      issue_id: attrs.issue_id,
      issue_identifier: attrs.issue_identifier,
      stage: state[:stage],
      actor_type: "runtime",
      actor_id: attrs.metadata.owner,
      summary: "#{origin} logical run identity at authorized dispatch admission."
    }

    with {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
         {:ok, intent} <- RunLedger.prepare_entry("run.identity.requested", event_attrs),
         {:ok, confirmation} <- RunLedger.prepare_entry("run.identity.#{origin}", event_attrs) do
      identified = Map.merge(state, %{run_id: run_id, run_identity_event_id: confirmation.event_id, run_identity_ledger_path: ledger_path})

      metadata = %{
        run_id: run_id,
        workspace: workspace,
        origin: origin,
        intent_event_id: intent.event_id,
        inherited_stage_event_id: state[:last_ledger_event_id],
        previous_snapshot_digest: RunStateStore.snapshot_digest(state),
        snapshot_digest: RunStateStore.snapshot_digest(identified)
      }

      intent = Map.put(intent, :metadata, metadata)
      confirmation = Map.put(confirmation, :metadata, metadata)

      with {:ok, _} <- RunLedger.persist_prepared(intent),
           :ok <- persist(workspace, Map.put(identified, :run_identity_pending, %{intent: intent, confirmation: confirmation, ledger_path: ledger_path})),
           {:ok, current_path} <- RunLedger.ledger_file_path_checked(),
           true <- current_path == ledger_path or {:error, :run_identity_ledger_changed},
           {:ok, _} <- RunLedger.persist_prepared(confirmation),
           :ok <- persist(workspace, identified) do
        {:ok, run_id}
      end
    end
  end

  defp matching_confirmation(%{"metadata" => %{} = metadata} = event, state, workspace) do
    if event["event_type"] in ["run.identity.created", "run.identity.adopted"] and
         event["issue_id"] == state[:issue_id] and event["issue_identifier"] == state[:issue_identifier] and
         metadata["run_id"] == state[:run_id] and metadata["workspace"] == workspace and
         present?(metadata["intent_event_id"]) and present?(metadata["snapshot_digest"]) and
         present?(metadata["previous_snapshot_digest"]),
       do: :ok,
       else: {:error, :run_identity_evidence_mismatch}
  end

  defp matching_confirmation(_event, _state, _workspace), do: {:error, :run_identity_evidence_mismatch}

  defp matching_intent(intent, confirmation) do
    if intent["event_type"] == "run.identity.requested" and intent["issue_id"] == confirmation["issue_id"] and
         intent["issue_identifier"] == confirmation["issue_identifier"] and intent["metadata"] == confirmation["metadata"],
       do: :ok,
       else: {:error, :run_identity_evidence_mismatch}
  end

  defp persist(workspace, state) do
    path = RunStateStore.state_path(workspace)
    temporary = path <> ".identity-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, payload} <- Jason.encode(state),
         :ok <- File.write(temporary, payload, [:write]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} -> {:error, {:run_identity_write_failed, reason}}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
