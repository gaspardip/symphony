defmodule SymphonyElixir.EventInbox do
  @moduledoc false
  require Logger

  @max_bytes 4 * 1024 * 1024
  @dedupe_limit 2_000

  defmodule Location do
    @moduledoc false
    @enforce_keys [:kind, :events_path, :state_path, :lock_path]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Cursor do
    @moduledoc false
    @enforce_keys [:location, :generation, :start_offset, :end_offset, :digest]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @moduledoc "A checked inbox operation failed or has an uncertain outcome. Contains no event payload."
    defexception [:phase, :reason_code, :location, confirmation: :not_applied, cleanup_errors: []]
    @type t :: %__MODULE__{}

    @impl true
    def message(error), do: "inbox #{error.phase}: #{error.reason_code} (#{error.confirmation})"
  end

  @spec location(module(), String.t(), String.t()) :: Location.t()
  def location(kind, events_filename, state_filename) do
    root = base_dir()
    state_path = Path.join(root, state_filename)
    %Location{kind: kind, events_path: Path.join(root, events_filename), state_path: state_path, lock_path: state_path <> ".checked.lock"}
  end

  @spec filesystem() :: map()
  def filesystem do
    %{open: &:file.open/2, write: &:file.write/2, sync: &:file.sync/1, close: &:file.close/1, rename: &File.rename/2}
  end

  @spec capture(Location.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def capture(%Location{} = location, %{max_rows: rows, max_bytes: bytes})
      when is_integer(rows) and rows > 0 and is_integer(bytes) and bytes > 0 and bytes <= @max_bytes do
    locked(location, fn ->
      case read_pair(location) do
        {:ok, :uninitialized} -> {:ok, empty_batch(location)}
        {:ok, state} -> capture_state(location, state, rows, bytes)
        error -> error
      end
    end)
  end

  @spec initialize(Location.t()) :: :ok | {:error, Error.t()}
  def initialize(%Location{} = location) do
    locked(location, fn ->
      with {:ok, _state} <- initialized_state(location, filesystem()), do: :ok
    end)
  end

  @spec migrate_legacy(Location.t()) :: :ok | {:error, Error.t()}
  def migrate_legacy(%Location{} = location) do
    locked(location, fn ->
      with {:ok, state} <- read_pair(location, :allow_legacy) do
        case state do
          :uninitialized ->
            failure(location, :migration, :uninitialized)

          %{"schema_version" => 2} ->
            :ok

          %{"acked_count" => count, "seen_dedupe_keys" => keys} ->
            with_events(location, fn device ->
              with {:ok, offset} <- legacy_offset(device, count, 0, location) do
                publish_state(location, new_state(offset, keys), filesystem())
              end
            end)
        end
      end
    end)
  end

  @spec reset(Location.t()) :: :ok | {:error, Error.t()}
  def reset(%Location{} = location) do
    locked(location, fn ->
      with {:ok, _state} <- initialized_state(location, filesystem()),
           {:ok, size} <- complete_size(location) do
        publish_state(location, new_state(size, []), filesystem())
      end
    end)
  end

  @spec enqueue([struct()], Location.t(), map(), (struct() -> map()), map()) :: {:ok, map()} | {:error, Error.t()}
  def enqueue(events, %Location{} = location, config, payload_fun, io \\ filesystem()) when is_list(events) do
    with {:ok, prepared} <- prepare_events(events, config, payload_fun, location) do
      locked(location, fn ->
        with {:ok, state} <- initialized_state(location, io),
             {:ok, _size} <- complete_size(location) do
          {records, keys, duplicates} = dedupe(prepared, state["seen_dedupe_keys"])

          result =
            with :ok <- append_records(location, records, io),
                 :ok <- publish_state(location, %{state | "seen_dedupe_keys" => keys}, io) do
              {:ok, %{accepted: length(records), duplicates: duplicates, event_ids: Enum.map(records, & &1.id)}}
            end

          if records == [], do: result, else: uncertain(result)
        end
      end)
    end
  end

  @spec ack(Cursor.t(), map()) :: {:ok, :advanced | :already_acked} | {:error, Error.t()}
  def ack(%Cursor{location: location} = cursor, io \\ filesystem()) do
    locked(location, fn ->
      with {:ok, state} <- read_pair(location),
           :ok <- cursor_state(location, state, cursor),
           :ok <- verify_prefix(cursor) do
        if state["acked_offset"] == cursor.end_offset do
          {:ok, :already_acked}
        else
          with :ok <- publish_state(location, %{state | "acked_offset" => cursor.end_offset}, io), do: {:ok, :advanced}
        end
      end
    end)
  end

  @spec pending_events(Location.t(), pos_integer()) :: [map()]
  def pending_events(location, limit) when is_integer(limit) and limit > 0 do
    case capture(location, %{max_rows: limit, max_bytes: @max_bytes}) do
      {:ok, batch} -> for %{record: {:ok, record}} <- batch.rows, do: record
      {:error, %Error{} = error} -> raise error
    end
  end

  @spec stats(Location.t()) :: map()
  def stats(location) do
    case capture(location, %{max_rows: 10_000, max_bytes: @max_bytes}) do
      {:ok, batch} ->
        records = for %{record: {:ok, record}} <- batch.rows, do: record

        %{
          status: batch.status,
          depth: length(records),
          oldest_pending_event_at: oldest(records),
          complete: not batch.limit_reached and batch.tail == :none,
          invalid_rows: length(batch.rows) - length(records),
          partial_tail: batch.tail == :partial,
          error: nil
        }

      {:error, error} ->
        %{status: :error, depth: nil, oldest_pending_event_at: nil, complete: false, invalid_rows: nil, partial_tail: nil, error: error_summary(error)}
    end
  end

  @spec error_summary(Error.t()) :: map()
  def error_summary(%Error{} = error) do
    %{
      phase: error.phase,
      reason_code: error.reason_code,
      confirmation: error.confirmation,
      cleanup_errors: Enum.map(error.cleanup_errors, fn {phase, reason} -> %{phase: phase, reason_code: reason} end)
    }
  end

  @spec base_dir() :: Path.t()
  def base_dir, do: SymphonyElixir.RunLedger.ledger_file_path() |> Path.dirname() |> Path.expand()

  @spec timestamp(DateTime.t() | term()) :: String.t() | nil
  def timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def timestamp(_value), do: nil

  defp empty_batch(location) do
    %{location: location, status: :uninitialized, generation: nil, start_offset: 0, rows: [], tail: :none, limit_reached: false}
  end

  defp capture_state(location, state, max_rows, max_bytes) do
    with_events(location, fn device ->
      offset = state["acked_offset"]

      with {:ok, data} <- pread(device, offset, max_bytes + 1, location) do
        {rows, consumed, tail, limited} = scan_rows(data, offset, max_rows, max_bytes, [], 0)

        if rows == [] and limited do
          failure(location, :capture, :row_too_large)
        else
          rows =
            Enum.map(rows, fn row ->
              cursor = %Cursor{
                location: location,
                generation: state["generation"],
                start_offset: offset,
                end_offset: row.end_offset,
                digest: :crypto.hash(:sha256, binary_part(data, 0, row.end_offset - offset))
              }

              Map.put(row, :cursor, cursor)
            end)

          # One byte beyond the budget distinguishes EOF from an uninspected suffix.
          {:ok,
           %{
             location: location,
             status: :ready,
             generation: state["generation"],
             start_offset: offset,
             rows: rows,
             tail: tail,
             limit_reached: limited or (consumed < byte_size(data) and tail == :not_inspected)
           }}
        end
      end
    end)
  end

  defp scan_rows(<<>>, _offset, _rows, _budget, acc, consumed), do: {Enum.reverse(acc), consumed, :none, false}
  defp scan_rows(_data, _offset, 0, _budget, acc, consumed), do: {Enum.reverse(acc), consumed, :not_inspected, true}

  defp scan_rows(data, offset, remaining, budget, acc, consumed) do
    case :binary.match(data, "\n") do
      {index, 1} when index + 1 <= budget ->
        length = index + 1
        <<line::binary-size(length), rest::binary>> = data
        row = %{end_offset: offset + length, record: decode_record(line)}
        scan_rows(rest, offset + length, remaining - 1, budget - length, [row | acc], consumed + length)

      :nomatch when byte_size(data) <= budget ->
        {Enum.reverse(acc), consumed, :partial, false}

      _ ->
        {Enum.reverse(acc), consumed, :not_inspected, true}
    end
  end

  defp decode_record(line) do
    case Jason.decode(line) do
      {:ok, %{} = record} -> {:ok, record}
      {:ok, _} -> {:invalid, :non_object}
      {:error, _} -> {:invalid, :invalid_json}
    end
  end

  defp read_pair(location, mode \\ :current) do
    case {File.read(location.state_path), File.stat(location.events_path)} do
      {{:error, :enoent}, {:error, :enoent}} ->
        {:ok, :uninitialized}

      {{:error, :enoent}, {:ok, _}} ->
        failure(location, :read, :missing_state)

      {{:ok, _}, {:error, :enoent}} ->
        failure(location, :read, :missing_events)

      {{:error, reason}, _} ->
        failure(location, :read_state, reason)

      {_, {:error, reason}} ->
        failure(location, :read_events, reason)

      {{:ok, payload}, {:ok, %{type: :regular, size: size}}} ->
        with {:ok, state} <- decode_state(payload, location, mode),
             :ok <- validate_offset(location, state, size) do
          {:ok, state}
        end

      _ ->
        failure(location, :read_events, :not_regular)
    end
  end

  defp decode_state(payload, location, mode) do
    case Jason.decode(payload) do
      {:ok, %{"schema_version" => 2, "generation" => generation, "acked_offset" => offset, "seen_dedupe_keys" => keys} = state}
      when is_binary(generation) and generation != "" and is_integer(offset) and offset >= 0 ->
        cond do
          Enum.sort(Map.keys(state)) != ~w(acked_offset generation schema_version seen_dedupe_keys) -> failure(location, :state, :invalid_schema)
          valid_keys?(keys) -> {:ok, state}
          true -> failure(location, :state, :invalid_dedupe)
        end

      {:ok, %{"schema_version" => _}} ->
        failure(location, :state, :invalid_schema)

      {:ok, %{"acked_count" => count, "seen_dedupe_keys" => keys} = state} when is_integer(count) and count >= 0 ->
        cond do
          Enum.sort(Map.keys(state)) != ~w(acked_count seen_dedupe_keys) -> failure(location, :state, :invalid_schema)
          not valid_keys?(keys) -> failure(location, :state, :invalid_dedupe)
          mode == :allow_legacy -> {:ok, state}
          true -> failure(location, :state, :migration_required)
        end

      _ ->
        failure(location, :state, :invalid_schema)
    end
  end

  defp valid_keys?(keys), do: is_list(keys) and length(keys) <= @dedupe_limit and Enum.all?(keys, &is_binary/1)
  defp validate_offset(_location, %{"acked_count" => _}, _size), do: :ok

  defp validate_offset(location, %{"acked_offset" => offset}, size) when offset <= size do
    if offset == 0 do
      :ok
    else
      with_events(location, fn device ->
        case :file.pread(device, offset - 1, 1) do
          {:ok, "\n"} -> :ok
          {:error, reason} -> failure(location, :read_events, reason)
          _ -> failure(location, :state, :offset_not_boundary)
        end
      end)
    end
  end

  defp validate_offset(location, _state, _size), do: failure(location, :state, :offset_beyond_eof)

  defp initialized_state(location, io) do
    case read_pair(location) do
      {:ok, :uninitialized} ->
        state = new_state(0, [])

        with :ok <- write_file(location.events_path, [], [:write, :exclusive], location, :initialize, io),
             :ok <- uncertain(publish_state(location, state, io)) do
          {:ok, state}
        end

      result ->
        result
    end
  end

  defp new_state(offset, keys) do
    %{"schema_version" => 2, "generation" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false), "acked_offset" => offset, "seen_dedupe_keys" => keys}
  end

  defp complete_size(location) do
    with_events(location, fn device ->
      case :file.position(device, :eof) do
        {:ok, 0} ->
          {:ok, 0}

        {:ok, size} ->
          case :file.pread(device, size - 1, 1) do
            {:ok, "\n"} -> {:ok, size}
            {:error, reason} -> failure(location, :read_events, reason)
            _ -> failure(location, :enqueue, :partial_tail)
          end

        {:error, reason} ->
          failure(location, :read_events, reason)
      end
    end)
  end

  defp prepare_events(events, config, payload_fun, location) do
    events
    |> Enum.filter(&is_struct(&1, config.event_module))
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, records} ->
      record = %{
        id: event.event_id || config.event_id_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
        dedupe_key: config.event_module.dedupe_key(event),
        enqueued_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        event: payload_fun.(event)
      }

      case Jason.encode(record) do
        {:ok, payload} when byte_size(payload) + 1 <= @max_bytes ->
          {:cont, {:ok, [%{id: record.id, key: record.dedupe_key, bytes: payload <> "\n"} | records]}}

        {:ok, _} ->
          {:halt, failure(location, :prepare, :row_too_large)}

        {:error, _} ->
          {:halt, failure(location, :prepare, :invalid_event)}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp dedupe(records, keys) do
    {accepted, keys, duplicates} =
      Enum.reduce(records, {[], keys, 0}, fn record, {acc, seen, count} ->
        if record.key in seen do
          {acc, seen, count + 1}
        else
          {[record | acc], Enum.take(seen ++ [record.key], -@dedupe_limit), count}
        end
      end)

    {Enum.reverse(accepted), keys, duplicates}
  end

  defp append_records(_location, [], _io), do: :ok
  defp append_records(location, records, io), do: write_file(location.events_path, Enum.map(records, & &1.bytes), [:append], location, :append, io)

  defp publish_state(location, state, io) do
    temporary = location.state_path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    case io.open.(String.to_charlist(temporary), [:raw, :binary, :write, :exclusive]) do
      {:ok, device} ->
        guarded(
          location,
          :temporary_cleanup,
          fn ->
            with :ok <- write_open_file(device, Jason.encode!(state), location, :state_write, io) do
              # A failed rename callback may have applied the rename before reporting failure.
              uncertain(checked_io(io.rename.(temporary, location.state_path), location, :state_publish))
            end
          end,
          fn ->
            case File.rm(temporary) do
              {:error, :enoent} -> :ok
              result -> result
            end
          end
        )

      {:error, reason} ->
        failure(location, :state_open, reason)
    end
  end

  defp write_file(path, bytes, modes, location, phase, io) do
    case io.open.(String.to_charlist(path), [:raw, :binary | modes]) do
      {:ok, device} -> write_open_file(device, bytes, location, phase, io)
      {:error, reason} -> failure(location, phase, reason)
    end
  end

  defp write_open_file(device, bytes, location, phase, io) do
    guarded(
      location,
      :close,
      fn ->
        result = with :ok <- checked_io(io.write.(device, bytes), location, phase), :ok <- checked_io(io.sync.(device), location, :sync), do: :ok
        uncertain(result)
      end,
      fn -> io.close.(device) end
    )
  end

  defp checked_io(:ok, _location, _phase), do: :ok
  defp checked_io({:error, reason}, location, phase), do: failure(location, phase, reason)

  defp cursor_state(location, :uninitialized, _cursor), do: failure(location, :ack, :uninitialized)

  defp cursor_state(location, state, cursor) do
    cond do
      state["generation"] != cursor.generation ->
        failure(location, :ack, :generation_changed)

      not (is_integer(cursor.start_offset) and is_integer(cursor.end_offset) and cursor.start_offset >= 0 and
             cursor.end_offset > cursor.start_offset and cursor.end_offset - cursor.start_offset <= @max_bytes) ->
        failure(location, :ack, :invalid_cursor)

      state["acked_offset"] not in [cursor.start_offset, cursor.end_offset] ->
        failure(location, :ack, :offset_changed)

      true ->
        :ok
    end
  end

  defp verify_prefix(%Cursor{location: location} = cursor) do
    with_events(location, fn device ->
      size = cursor.end_offset - cursor.start_offset

      with {:ok, bytes} <- pread(device, cursor.start_offset, size, location) do
        if byte_size(bytes) == size and :binary.last(bytes) == ?\n and :crypto.hash(:sha256, bytes) == cursor.digest do
          :ok
        else
          failure(location, :ack, :prefix_changed)
        end
      end
    end)
  end

  defp legacy_offset(_device, 0, offset, _location), do: {:ok, offset}

  defp legacy_offset(device, count, offset, location) do
    with {:ok, data} <- pread(device, offset, 64 * 1024, location) do
      if data == "" do
        failure(location, :migration, :count_beyond_eof)
      else
        legacy_chunk(device, data, count, offset, location)
      end
    end
  end

  defp legacy_chunk(device, data, count, offset, location) do
    case :binary.match(data, "\n") do
      {index, 1} ->
        size = index + 1

        if count == 1 do
          {:ok, offset + size}
        else
          legacy_chunk(device, binary_part(data, size, byte_size(data) - size), count - 1, offset + size, location)
        end

      :nomatch ->
        legacy_offset(device, count, offset + byte_size(data), location)
    end
  end

  defp pread(device, offset, size, location) do
    case :file.pread(device, offset, size) do
      :eof -> {:ok, ""}
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> failure(location, :read_events, reason)
    end
  end

  defp with_events(location, fun) do
    case :file.open(String.to_charlist(location.events_path), [:read, :raw, :binary]) do
      {:ok, device} -> guarded(location, :close, fn -> fun.(device) end, fn -> :file.close(device) end)
      {:error, reason} -> failure(location, :read_events, reason)
    end
  end

  defp locked(location, fun) do
    with :ok <- checked_io(File.mkdir_p(Path.dirname(location.state_path)), location, :mkdir) do
      case File.mkdir(location.lock_path) do
        :ok -> guarded(location, :unlock, fun, fn -> File.rmdir(location.lock_path) end)
        {:error, reason} -> failure(location, :lock, reason)
      end
    end
  end

  defp guarded(location, phase, operation, cleanup) do
    result = protect(operation)
    cleaned = protect(cleanup)

    case {result, cleaned} do
      {{:raised, kind, reason, stack}, cleanup_result} ->
        if cleanup_result != :ok, do: Logger.error("Inbox cleanup failed phase=#{phase} while propagating original exception")
        :erlang.raise(kind, reason, stack)

      {value, :ok} ->
        value

      {value, {:error, reason}} ->
        cleanup_error(value, location, phase, reason)

      {value, {:raised, _kind, _reason, _stack}} ->
        Logger.error("Inbox cleanup raised phase=#{phase}")
        cleanup_error(value, location, phase, :cleanup_exception)
    end
  end

  defp protect(operation) do
    operation.()
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp uncertain({:error, %Error{} = error}), do: {:error, %{error | confirmation: :uncertain}}
  defp uncertain(result), do: result

  defp cleanup_error({:error, %Error{} = error}, _location, phase, reason) do
    {:error, %{error | cleanup_errors: error.cleanup_errors ++ [{phase, safe_reason(reason)}]}}
  end

  defp cleanup_error(_result, location, phase, reason), do: failure(location, phase, reason, :uncertain)

  defp failure(location, phase, reason, confirmation \\ :not_applied) do
    {:error, %Error{location: location, phase: phase, reason_code: safe_reason(reason), confirmation: confirmation}}
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :io_failure
  defp oldest([record | _]), do: Map.get(record, "enqueued_at")
  defp oldest([]), do: nil

  defmacro __using__(opts) do
    event_module = opts |> Keyword.fetch!(:event_module) |> Macro.expand(__CALLER__)
    events_filename = Keyword.fetch!(opts, :events_filename)
    state_filename = Keyword.fetch!(opts, :state_filename)
    error_tag = Keyword.fetch!(opts, :error_tag)
    event_id_prefix = Keyword.fetch!(opts, :event_id_prefix)

    quote bind_quoted: [event_module: event_module, events_filename: events_filename, state_filename: state_filename, error_tag: error_tag, event_id_prefix: event_id_prefix] do
      @events_filename events_filename
      @state_filename state_filename
      @error_tag error_tag
      @inbox_config %{event_module: event_module, event_id_prefix: event_id_prefix}

      @spec location() :: SymphonyElixir.EventInbox.Location.t()
      def location, do: SymphonyElixir.EventInbox.location(__MODULE__, @events_filename, @state_filename)

      @spec capture(SymphonyElixir.EventInbox.Location.t(), map()) :: {:ok, map()} | {:error, SymphonyElixir.EventInbox.Error.t()}
      def capture(%SymphonyElixir.EventInbox.Location{kind: __MODULE__} = location, limits), do: SymphonyElixir.EventInbox.capture(location, limits)

      @spec ack(SymphonyElixir.EventInbox.Cursor.t()) :: {:ok, atom()} | {:error, SymphonyElixir.EventInbox.Error.t()}
      def ack(%SymphonyElixir.EventInbox.Cursor{location: %{kind: __MODULE__}} = cursor), do: SymphonyElixir.EventInbox.ack(cursor)

      @spec initialize(SymphonyElixir.EventInbox.Location.t()) :: :ok | {:error, SymphonyElixir.EventInbox.Error.t()}
      def initialize(%SymphonyElixir.EventInbox.Location{kind: __MODULE__} = location), do: SymphonyElixir.EventInbox.initialize(location)

      @spec migrate_legacy(SymphonyElixir.EventInbox.Location.t()) :: :ok | {:error, SymphonyElixir.EventInbox.Error.t()}
      def migrate_legacy(%SymphonyElixir.EventInbox.Location{kind: __MODULE__} = location), do: SymphonyElixir.EventInbox.migrate_legacy(location)

      @spec enqueue([struct()]) :: {:ok, map()} | {:error, term()}
      def enqueue(events) when is_list(events) do
        case SymphonyElixir.EventInbox.enqueue(events, location(), @inbox_config, &event_payload/1) do
          {:error, error} -> {:error, {@error_tag, SymphonyElixir.EventInbox.error_summary(error)}}
          result -> result
        end
      end

      @spec pending_events(pos_integer()) :: [map()]
      def pending_events(limit \\ 100), do: SymphonyElixir.EventInbox.pending_events(location(), limit)

      @spec stats() :: map()
      def stats, do: SymphonyElixir.EventInbox.stats(location())

      @spec reset(SymphonyElixir.EventInbox.Location.t()) :: :ok | {:error, SymphonyElixir.EventInbox.Error.t()}
      def reset(location \\ location())
      def reset(%SymphonyElixir.EventInbox.Location{kind: __MODULE__} = location), do: SymphonyElixir.EventInbox.reset(location)

      @spec events_path() :: Path.t()
      def events_path, do: location().events_path
      @spec state_path() :: Path.t()
      def state_path, do: location().state_path
      @spec base_dir() :: Path.t()
      def base_dir, do: SymphonyElixir.EventInbox.base_dir()
      defp timestamp(value), do: SymphonyElixir.EventInbox.timestamp(value)
    end
  end
end
