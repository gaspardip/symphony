defmodule SymphonyElixir.RunLedger do
  @moduledoc """
  Appends typed audit events to a local JSONL ledger while preserving
  compatibility with legacy entries.
  """

  # credo:disable-for-this-file

  alias SymphonyElixir.SecretRedactor

  @default_filename "run_ledger.jsonl"
  @default_recent_limit 50
  @schema_version 1
  @reserved_keys ~w(
    schema_version
    event
    event_type
    event_id
    at
    issue_id
    issue_identifier
    stage
    actor_type
    actor_id
    policy_class
    failure_class
    rule_id
    summary
    details
    target_state
    metadata
  )a

  @spec append(atom() | String.t(), map()) :: :ok
  def append(event_type, attrs \\ %{}) when is_map(attrs) do
    entry =
      attrs
      |> Map.put(:event, to_string(event_type))
      |> Map.put_new(:at, SymphonyElixir.Util.now_iso8601())
      |> SecretRedactor.redact()

    path = ledger_file_path()
    :ok = File.mkdir_p(Path.dirname(path))
    File.write!(path, Jason.encode!(entry) <> "\n", [:append])
    :ok
  rescue
    _error ->
      :ok
  end

  @doc "Returns the confirmed event map; raises PersistenceError without retry when persistence is not confirmed or uncertain."
  @spec record(String.t(), map()) :: map()
  def record(event_type, attrs \\ %{}) when is_binary(event_type) and is_map(attrs) do
    case record_checked(event_type, attrs) do
      {:ok, entry} -> entry
      {:error, error} -> raise error
    end
  end

  defmodule PersistenceError do
    @moduledoc "A checked ledger operation was not confirmed or has an uncertain outcome."
    defexception [:phase, :event_id, :confirmation, :reason, cleanup_errors: []]

    @type t :: %__MODULE__{
            phase: atom(),
            event_id: String.t() | nil,
            confirmation: :not_confirmed | :uncertain,
            reason: term(),
            cleanup_errors: [{atom(), term()}]
          }

    # Keep raw causes and cleanup evidence in fields, never in the rendered message.
    @impl true
    def message(_error), do: "Run ledger persistence failed."
  end

  defmodule CheckedStorage do
    @moduledoc false
    alias SymphonyElixir.RunLedger.PersistenceError
    alias SymphonyElixir.Observability
    require Logger

    @type io_callbacks :: %{
            open: (charlist(), list() -> {:ok, term()} | {:error, term()}),
            write: (term(), iodata() -> :ok | {:error, term()}),
            sync: (term() -> :ok | {:error, term()}),
            close: (term() -> :ok | {:error, term()})
          }

    # Internal boundary: callbacks are explicit per call, never application-global.
    @spec filesystem() :: io_callbacks()
    def filesystem do
      %{open: &:file.open/2, write: &:file.write/2, sync: &:file.sync/1, close: &:file.close/1}
    end

    @spec persist(map(), Path.t(), io_callbacks(), (String.t(), map() -> term())) ::
            {:ok, map()} | {:error, PersistenceError.t()}
    def persist(entry, path, io \\ filesystem(), observer \\ &Observability.emit_ledger_event/2) do
      id = event_id(entry)

      with :ok <- validate_prepared(entry),
           {:ok, payload} <- encode_checked(entry),
           :ok <- checked_mkdir(Path.dirname(path), id) do
        result =
          with_checked_lock(path, id, :not_confirmed, fn ->
            with :ok <- preflight_ledger(path, id) do
              write_prepared(path, payload <> "\n", entry, io)
            end
          end)

        case result do
          {:ok, ^entry} ->
            emit_confirmed_event(entry, observer)
            {:ok, entry}

          {:error, %PersistenceError{}} = error ->
            error
        end
      end
    end

    @spec fetch(Path.t(), String.t()) ::
            {:ok, map()} | {:error, :not_found | PersistenceError.t()}
    def fetch(path, event_id) do
      with_checked_lock(path, event_id, :uncertain, fn ->
        case File.read(path) do
          {:ok, payload} -> decode_complete_ledger(payload, event_id)
          {:error, reason} -> checked_error(:read, event_id, :uncertain, reason)
        end
      end)
    end

    @spec event_id(map()) :: String.t() | nil
    def event_id(entry) do
      case field(entry, :event_id) do
        id when is_binary(id) -> id
        _ -> nil
      end
    end

    defp field(entry, key), do: Map.get(entry, key, Map.get(entry, Atom.to_string(key)))

    defp validate_prepared(entry) do
      keys = Map.keys(entry)
      homogeneous_keys = Enum.all?(keys, &is_atom/1) or Enum.all?(keys, &is_binary/1)

      if homogeneous_keys and field(entry, :schema_version) == 1 and
           is_binary(event_id(entry)) and event_id(entry) != "" and
           is_binary(field(entry, :event_type)) and
           field(entry, :event) == field(entry, :event_type) and
           is_binary(field(entry, :at)) and is_map(field(entry, :metadata)) do
        :ok
      else
        checked_error(:prepare, event_id(entry), :not_confirmed, :invalid_prepared_entry)
      end
    end

    defp emit_confirmed_event(entry, observer) do
      # Normalize only known telemetry keys. Stored/returned entry remains untouched.
      keys =
        ~w(event_id event event_type at issue_id issue_identifier stage actor_type actor_id policy_class failure_class rule_id summary details target_state metadata schema_version)a

      telemetry_entry = Map.new(keys, fn key -> {key, field(entry, key)} end)

      try do
        observer.(field(entry, :event_type), telemetry_entry)
      rescue
        error ->
          Logger.error("Ledger entry confirmed but telemetry failed event_id=#{event_id(entry)} error_type=#{inspect(error.__struct__)}")

          :ok
      end
    end

    defp encode_checked(entry) do
      case Jason.encode(entry) do
        {:ok, payload} ->
          {:ok, payload}

        {:error, error} ->
          checked_error(:encode, event_id(entry), :not_confirmed, error.__struct__)
      end
    end

    defp checked_mkdir(parent, id) do
      case File.mkdir_p(parent) do
        :ok -> :ok
        {:error, reason} -> checked_error(:mkdir, id, :not_confirmed, reason)
      end
    end

    # Atomic mkdir excludes cooperating checked writers/readers across OS processes.
    # Legacy append does not participate. No stale-lock deletion or automatic retry.
    defp with_checked_lock(path, id, confirmation, operation) do
      # This serializes only this VM. The filesystem guard remains authoritative
      # for independent VMs and refuses occupied/orphaned locks without deleting them.
      case :global.trans(
             {{__MODULE__, Path.expand(path)}, self()},
             fn ->
               with_filesystem_lock(path, id, confirmation, operation)
             end,
             [node()]
           ) do
        :aborted -> checked_error(:local_lock, id, confirmation, :aborted)
        result -> result
      end
    end

    defp with_filesystem_lock(path, id, confirmation, operation) do
      lock_path = path <> ".checked.lock"

      case File.mkdir(lock_path) do
        :ok ->
          checked_cleanup(operation, fn -> File.rmdir(lock_path) end, :unlock, id)

        {:error, reason} ->
          checked_error(:lock, id, confirmation, reason)
      end
    end

    # Full validation is O(n) per append. Prefer a visible block over confirming
    # a row that fetch_entry_checked cannot recover from the existing ledger.
    defp preflight_ledger(path, id) do
      case File.read(path) do
        {:ok, payload} ->
          case decode_complete_ledger(payload, id) do
            {:error, :not_found} -> :ok
            {:ok, _existing} -> checked_error(:preflight, id, :uncertain, :event_id_already_present)
            {:error, %PersistenceError{} = error} -> {:error, %{error | phase: :preflight}}
          end

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          checked_error(:preflight, id, :uncertain, reason)
      end
    end

    defp write_prepared(path, payload, entry, io) do
      case io.open.(String.to_charlist(path), [:append, :binary, :raw]) do
        {:ok, device} ->
          checked_cleanup(
            fn ->
              with :ok <- checked_io_result(io.write.(device, payload), :write, event_id(entry)),
                   :ok <- checked_io_result(io.sync.(device), :sync, event_id(entry)) do
                {:ok, entry}
              end
            end,
            fn -> io.close.(device) end,
            :close,
            event_id(entry)
          )

        {:error, reason} ->
          checked_error(:open, event_id(entry), :not_confirmed, reason)
      end
    end

    defp checked_io_result(:ok, _phase, _id), do: :ok

    defp checked_io_result({:error, reason}, phase, id),
      do: checked_error(phase, id, :uncertain, reason)

    # Preserve unexpected programming failures, but close the descriptor / release
    # our lock first. Expected I/O failures stay typed results, never success.
    defp checked_cleanup(operation, cleanup, phase, id) do
      outcome =
        try do
          {:returned, operation.()}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      cleanup_result = cleanup.()

      case {outcome, cleanup_result} do
        {{:returned, result}, :ok} ->
          result

        {{:returned, {:error, %PersistenceError{} = error}}, {:error, reason}} ->
          {:error, %{error | cleanup_errors: error.cleanup_errors ++ [{phase, reason}]}}

        {{:returned, _result}, {:error, reason}} ->
          checked_error(phase, id, :uncertain, reason)

        {{:raised, kind, reason, stacktrace}, cleanup_result} ->
          if cleanup_result != :ok do
            Logger.error("Ledger cleanup failed after programming error phase=#{phase} event_id=#{id}")
          end

          :erlang.raise(kind, reason, stacktrace)
      end
    end

    defp decode_complete_ledger("", _id), do: {:error, :not_found}

    defp decode_complete_ledger(payload, id) do
      if String.ends_with?(payload, "\n") do
        payload
        |> String.split("\n")
        |> Enum.drop(-1)
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, nil, MapSet.new()}, fn {line, number}, {:ok, found, ids} ->
          case Jason.decode(line) do
            {:ok, %{} = entry} ->
              row_id = Map.get(entry, "event_id")

              cond do
                row_id != nil and (not is_binary(row_id) or row_id == "") ->
                  {:halt, checked_error(:decode, id, :uncertain, {:invalid_event_id, number})}

                row_id != nil and MapSet.member?(ids, row_id) ->
                  {:halt, checked_error(:duplicate, id, :uncertain, {:duplicate_event_id, number})}

                true ->
                  next_ids = if row_id == nil, do: ids, else: MapSet.put(ids, row_id)
                  next_found = if row_id == id, do: entry, else: found
                  {:cont, {:ok, next_found, next_ids}}
              end

            _ ->
              {:halt, checked_error(:decode, id, :uncertain, {:invalid_record, number})}
          end
        end)
        |> case do
          {:ok, nil, _ids} -> {:error, :not_found}
          {:ok, entry, _ids} -> {:ok, entry}
          {:error, %PersistenceError{}} = error -> error
        end
      else
        checked_error(:decode, id, :uncertain, :unterminated_record)
      end
    end

    defp checked_error(phase, id, confirmation, reason) do
      {:error, %PersistenceError{phase: phase, event_id: id, confirmation: confirmation, reason: reason}}
    end
  end

  @spec prepare_entry(String.t(), map()) :: {:ok, map()} | {:error, PersistenceError.t()}
  def prepare_entry(event_type, attrs \\ %{}) when is_binary(event_type) and is_map(attrs) do
    if is_map(Map.get(attrs, :metadata, %{})) do
      {:ok, typed_entry(attrs, event_type)}
    else
      checked_error(:prepare, nil, :not_confirmed, :metadata_must_be_a_map)
    end
  end

  @spec record_checked(String.t(), map()) :: {:ok, map()} | {:error, PersistenceError.t()}
  def record_checked(event_type, attrs \\ %{}) when is_binary(event_type) and is_map(attrs) do
    with {:ok, entry} <- prepare_entry(event_type, attrs), do: persist_prepared(entry)
  end

  @doc "Persists the unchanged prepared map, including its JSON-decoded form. Never blindly retry uncertainty."
  @spec persist_prepared(map()) :: {:ok, map()} | {:error, PersistenceError.t()}
  def persist_prepared(entry) when is_map(entry) do
    with {:ok, path} <- checked_path(CheckedStorage.event_id(entry), :not_confirmed) do
      CheckedStorage.persist(entry, path)
    end
  end

  @doc "Reads the complete ledger; returns decoded string keys. Missing files are errors."
  @spec fetch_entry_checked(String.t()) ::
          {:ok, map()} | {:error, :not_found | PersistenceError.t()}
  def fetch_entry_checked(event_id) when is_binary(event_id) do
    with {:ok, path} <- checked_path(event_id, :uncertain) do
      CheckedStorage.fetch(path, event_id)
    end
  end

  @spec ledger_file_path_checked() :: {:ok, Path.t()} | {:error, PersistenceError.t()}
  def ledger_file_path_checked, do: checked_path(nil, :not_confirmed)

  defp checked_path(id, confirmation) do
    case Application.get_env(:symphony_elixir, :log_file) do
      nil ->
        {:ok, Path.expand(Path.join("log", @default_filename))}

      path when is_binary(path) and path != "" ->
        {:ok, Path.expand(Path.join(Path.dirname(path), @default_filename))}

      _ ->
        checked_error(:configuration, id, confirmation, :invalid_log_file)
    end
  end

  defp checked_error(phase, id, confirmation, reason) do
    {:error, %PersistenceError{phase: phase, event_id: id, confirmation: confirmation, reason: reason}}
  end

  @spec ledger_file_path() :: Path.t()
  def ledger_file_path do
    case Application.get_env(:symphony_elixir, :log_file) do
      nil ->
        Path.join(File.cwd!(), Path.join("log", @default_filename))

      log_file when is_binary(log_file) ->
        Path.join(Path.dirname(log_file), @default_filename)
    end
  end

  @spec recent_entries() :: [map()]
  def recent_entries, do: recent_entries(@default_recent_limit)

  @spec recent_entries(pos_integer()) :: [map()]
  def recent_entries(limit) when is_integer(limit) and limit > 0 do
    path = ledger_file_path()

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce([], fn line, acc ->
        case decode_entry(line) do
          nil -> acc
          entry -> [entry | acc] |> Enum.take(limit)
        end
      end)
      |> Enum.reverse()
    else
      []
    end
  rescue
    _error ->
      []
  end

  def recent_entries(_limit), do: []

  defp decode_entry(line) when is_binary(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = entry} -> entry
      _ -> nil
    end
  end

  defp typed_entry(attrs, event_type) do
    %{attrs: attrs, event_type: event_type} = SecretRedactor.redact(%{attrs: attrs, event_type: event_type})

    metadata =
      attrs
      |> Map.get(:metadata, %{})
      |> Map.merge(extra_metadata(attrs))

    %{
      schema_version: @schema_version,
      event: event_type,
      event_type: event_type,
      event_id: SymphonyElixir.Util.generate_id("evt_"),
      at: SymphonyElixir.Util.now_iso8601(),
      issue_id: Map.get(attrs, :issue_id),
      issue_identifier: Map.get(attrs, :issue_identifier),
      stage: Map.get(attrs, :stage),
      actor_type: normalize_actor_type(Map.get(attrs, :actor_type)),
      actor_id: Map.get(attrs, :actor_id),
      policy_class: normalize_string(Map.get(attrs, :policy_class)),
      failure_class: normalize_string(Map.get(attrs, :failure_class)),
      rule_id: normalize_string(Map.get(attrs, :rule_id)),
      summary: normalize_string(Map.get(attrs, :summary)),
      details: normalize_string(Map.get(attrs, :details)),
      target_state: normalize_string(Map.get(attrs, :target_state)),
      metadata: metadata
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> SecretRedactor.redact()
  end

  defp extra_metadata(attrs) do
    attrs
    |> Enum.reject(fn {key, _value} -> key in @reserved_keys end)
    |> Map.new()
  end

  defp normalize_actor_type(nil), do: nil

  defp normalize_actor_type(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      actor_type -> actor_type
    end
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end
end
