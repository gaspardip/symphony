defmodule SymphonyElixir.EvidenceAcceptance do
  @moduledoc """
  Observes the bytes selected by the current verifier. A digest establishes
  integrity of that observation, not the truth of arbitrary claims in a file.

  Only AgentExecution retains an acceptance handle. Persisted history, a model
  verdict and a caller-created map cannot install a handle in a later worker.
  """

  alias SymphonyElixir.{AgentExecution, BehavioralProof, RunInspector, RunLedger}

  @maximum_bytes 1_048_576
  @effects [:publish, :commit, :push, :pr_create, :pr_edit, :pr_attachment, :pr_reference, :handoff]
  @type handle :: reference()
  @type observation :: %{files: [map()], selection: map(), gate: map(), verification: map() | nil}

  @spec begin_observation(Path.t(), BehavioralProof.Result.t(), RunInspector.command_result(), boolean(), map() | nil) ::
          {:ok, handle(), [map()]} | {:error, term()} | AgentExecution.terminal()
  def begin_observation(workspace, selection, gate, validation_required, scope), do: AgentExecution.begin_evidence(workspace, selection, gate, validation_required, scope)

  @spec accept(handle(), map()) :: :ok | {:error, term()} | AgentExecution.terminal()
  def accept(handle, result), do: AgentExecution.accept_evidence(handle, result)

  @spec current(Path.t()) :: {:ok, handle()} | {:error, term()} | AgentExecution.terminal()
  def current(workspace), do: AgentExecution.current_evidence(workspace)

  @spec before_effect(Path.t(), handle(), atom()) :: :ok | {:error, term()} | AgentExecution.terminal()
  def before_effect(workspace, handle, effect) when effect in @effects do
    case current(workspace) do
      {:ok, ^handle} -> :ok
      {:ok, _other_handle} -> {:error, :evidence_handle_mismatch}
      {:error, _reason} = error -> error
      {:stop, _} = terminal -> terminal
    end
  end

  @doc "Returns a closed diagnostic code without paths, contents or decoder payloads."
  @spec failure_code(term()) :: String.t()
  def failure_code(reason)
      when reason in [
             :evidence_missing,
             :evidence_changed,
             :evidence_replaced,
             :evidence_changed_during_read,
             :evidence_too_large,
             :evidence_not_text,
             :evidence_empty,
             :evidence_unsafe_path,
             :evidence_unsupported_file,
             :evidence_event_changed,
             :evidence_handle_mismatch,
             :evidence_handle_required,
             :evidence_workspace_mismatch,
             :evidence_gate_not_passed,
             :evidence_validation_required,
             :evidence_verifier_required,
             :evidence_reverification_required,
             :evidence_not_accepted,
             :evidence_observation_already_attempted,
             :evidence_observation_not_current,
             :evidence_verdict_not_accepted,
             :verifier_pass_with_acceptance_gaps,
             :evidence_base_invalid,
             :evidence_base_missing,
             :evidence_branch_unknown,
             :evidence_branch_changed,
             :evidence_material_invalid,
             :evidence_scope_file_missing,
             :evidence_scope_file_unsupported,
             :evidence_scope_changed
           ],
      do: Atom.to_string(reason)

  def failure_code({:evidence_read_failed, _reason}), do: "evidence_read_failed"
  def failure_code({:evidence_close_failed, _reason}), do: "evidence_close_failed"
  def failure_code({:evidence_read_and_close_failed, _primary, _close}), do: "evidence_read_and_close_failed"
  def failure_code({:evidence_file_selection_failed, _status}), do: "evidence_file_selection_failed"
  def failure_code({:evidence_scope_read_failed, _reason}), do: "evidence_scope_read_failed"

  def failure_code({:evidence_scope_command_failed, phase, _status}) when phase in [:base, :branch, :diff, :untracked, :deleted, :hash],
    do: "evidence_scope_" <> Atom.to_string(phase) <> "_failed"

  def failure_code(%RunLedger.PersistenceError{}), do: "evidence_ledger_failed"
  def failure_code(_reason), do: "evidence_observation_failed"

  @doc false
  @spec capture(Path.t(), BehavioralProof.Result.t(), RunInspector.command_result(), map(), map() | nil) ::
          {:ok, observation(), [map()]} | {:error, term()}
  def capture(workspace, %BehavioralProof.Result{} = selection, %RunInspector.CommandResult{status: :passed} = gate, validation, scope) do
    paths = selected_paths(selection)

    with true <- selection.satisfied? or {:error, :evidence_missing},
         :ok <- RunInspector.confirm_evidence_scope(workspace, scope),
         {:ok, files} <- read_files(workspace, paths) do
      observation = %{
        files: Enum.map(files, &Map.delete(&1, :contents)),
        selection: %{mode: selection.mode, required: selection.required?, paths: paths, scope: scope},
        gate: %{smoke: gate_digest(gate), validation: validation_digest(validation)},
        verification: nil
      }

      {:ok, observation, Enum.map(files, &%{path: &1.path, excerpt: &1.contents})}
    end
  end

  def capture(_workspace, _selection, _gate, _validation, _scope), do: {:error, :evidence_gate_not_passed}

  @doc false
  @spec verify(Path.t(), observation()) :: :ok | {:error, term()}
  def verify(workspace, observation) do
    with :ok <- RunInspector.confirm_evidence_scope(workspace, observation.selection.scope),
         {:ok, files} <- read_files(workspace, observation.selection.paths),
         true <- Enum.map(files, &Map.delete(&1, :contents)) == observation.files or {:error, :evidence_changed} do
      :ok
    end
  end

  @doc false
  @spec prepare(map(), observation()) :: {:ok, map()} | {:error, RunLedger.PersistenceError.t()}
  def prepare(context, observation) do
    RunLedger.prepare_entry("proof.integrity_verified", %{
      issue_id: context.issue_id,
      run_id: context.ticket.run_id,
      stage: "verify",
      actor_type: "runtime",
      actor_id: "evidence_acceptance",
      metadata: %{
        schema_version: 1,
        integrity_only: true,
        dispatch_id: context.ticket.dispatch_id,
        dispatch_event_id: context.ticket.entry_event_id,
        selection: observation.selection,
        verification: observation.verification,
        files: observation.files,
        gate: observation.gate
      }
    })
  end

  @doc false
  @spec confirm_entry(Path.t(), map()) :: :ok | {:error, term()}
  def confirm_entry(path, entry) do
    with {:ok, encoded} <- Jason.encode(entry),
         {:ok, expected} <- Jason.decode(encoded),
         {:ok, ^expected} <- RunLedger.CheckedStorage.fetch(path, RunLedger.CheckedStorage.event_id(entry)) do
      :ok
    else
      {:ok, _different} -> {:error, :evidence_event_changed}
      {:error, _reason} = error -> error
    end
  end

  defp gate_digest(gate), do: %{status: to_string(gate.status), command_sha256: digest(gate.command || ""), output_sha256: digest(gate.output || "")}
  defp validation_digest(%{required: required, observation: nil}), do: %{required: required, observed: false}
  defp validation_digest(%{required: required, observation: observation}), do: %{required: required, observed: true, result: gate_digest(observation)}

  defp selected_paths(%{required?: false}), do: []
  defp selected_paths(%{mode: "artifact_only", artifact_path: path}), do: [path]
  defp selected_paths(%{proof_paths: [_ | _] = paths}), do: paths
  defp selected_paths(%{artifact_path: path}) when is_binary(path), do: [path]
  defp selected_paths(_selection), do: []

  defp read_files(workspace, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, files} ->
      case read_file(workspace, path) do
        {:ok, file} -> {:cont, {:ok, files ++ [file]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp read_file(workspace, relative) do
    with {:ok, path, before} <- confined_regular(workspace, relative),
         {:ok, device} <- File.open(path, [:read, :binary, :raw]) do
      result = read_open_file(device, workspace, relative, before)
      close = File.close(device)

      case {result, close} do
        {{:ok, file}, :ok} -> {:ok, file}
        {{:error, _reason} = error, :ok} -> error
        {{:ok, _file}, {:error, reason}} -> {:error, {:evidence_close_failed, reason}}
        {{:error, primary}, {:error, reason}} -> {:error, {:evidence_read_and_close_failed, primary, reason}}
      end
    end
  end

  defp read_open_file(device, workspace, relative, before) do
    with {:ok, record_before} <- :file.read_file_info(device, time: :universal),
         true <- identity(File.Stat.from_record(record_before)) == identity(before) or {:error, :evidence_replaced},
         {:ok, contents} <- :file.read(device, @maximum_bytes + 1),
         true <- byte_size(contents) <= @maximum_bytes or {:error, :evidence_too_large},
         true <- (String.valid?(contents) and not String.contains?(contents, <<0>>)) or {:error, :evidence_not_text},
         {:ok, record_after} <- :file.read_file_info(device, time: :universal),
         {:ok, _path, after_read} <- confined_regular(workspace, relative),
         true <- (identity(before) == identity(after_read) and identity(before) == identity(File.Stat.from_record(record_after))) or {:error, :evidence_changed_during_read},
         true <- byte_size(contents) == before.size or {:error, :evidence_changed_during_read} do
      {:ok, %{path: relative, size: byte_size(contents), sha256: digest(contents), contents: contents}}
    else
      :eof -> {:error, :evidence_empty}
      {:error, _reason} = error -> error
    end
  end

  defp confined_regular(workspace, relative) when is_binary(relative) do
    segments = Path.split(relative)

    if Path.type(relative) != :relative or segments == [] or Enum.any?(segments, &(&1 in [".", ".."])) do
      {:error, :evidence_unsafe_path}
    else
      with {:ok, %File.Stat{type: :directory}} <- File.lstat(workspace) do
        walk_regular(workspace, segments)
      else
        {:ok, _not_directory} -> {:error, :evidence_unsafe_path}
        {:error, reason} -> {:error, {:evidence_read_failed, reason}}
      end
    end
  end

  defp confined_regular(_workspace, _relative), do: {:error, :evidence_unsafe_path}

  defp walk_regular(workspace, segments) do
    Enum.reduce_while(segments, {:ok, Path.expand(workspace), nil}, fn segment, {:ok, current, _previous} ->
      path = Path.join(current, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: type} = stat} when type in [:regular, :directory] -> {:cont, {:ok, path, stat}}
        {:ok, _stat} -> {:halt, {:error, :evidence_unsupported_file}}
        {:error, reason} -> {:halt, {:error, {:evidence_read_failed, reason}}}
      end
    end)
    |> regular_result()
  end

  defp regular_result({:ok, path, %File.Stat{type: :regular, size: size} = stat}) when size <= @maximum_bytes, do: {:ok, path, stat}
  defp regular_result({:ok, _path, %File.Stat{size: size}}) when size > @maximum_bytes, do: {:error, :evidence_too_large}
  defp regular_result({:ok, _path, _stat}), do: {:error, :evidence_unsupported_file}
  defp regular_result({:error, _reason} = error), do: error
  defp identity(stat), do: Map.take(stat, [:type, :size, :major_device, :minor_device, :inode, :mtime, :ctime])
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
