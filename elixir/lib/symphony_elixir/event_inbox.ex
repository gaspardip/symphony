defmodule SymphonyElixir.EventInbox do
  @moduledoc false

  @default_recent_dedupe_limit 2_000

  @doc false
  @spec do_enqueue([struct()], Path.t(), Path.t(), map(), (struct() -> map())) ::
          {:ok, %{accepted: non_neg_integer(), duplicates: non_neg_integer(), event_ids: [String.t()]}}
          | {:error, term()}
  def do_enqueue(events, events_path, state_path, config, event_payload_fun) when is_list(events) do
    %{event_module: event_module, event_id_prefix: event_id_prefix} = config

    state = load_state(state_path)

    {records, next_state, duplicates} =
      Enum.reduce(events, {[], state, 0}, fn
        event, {acc, state_acc, duplicate_count} when is_struct(event, event_module) ->
          key = event_module.dedupe_key(event)

          if seen_dedupe_key?(state_acc, key) do
            {acc, state_acc, duplicate_count + 1}
          else
            record = %{
              id: event.event_id || generate_event_id(event_id_prefix),
              dedupe_key: key,
              enqueued_at: now_iso8601(),
              event: event_payload_fun.(event)
            }

            {[record | acc], remember_dedupe_key(state_acc, key), duplicate_count}
          end

        _other, acc_state ->
          acc_state
      end)

    ordered_records = Enum.reverse(records)
    :ok = File.mkdir_p(base_dir())

    if ordered_records != [] do
      File.write!(events_path, Enum.map_join(ordered_records, "", &(Jason.encode!(&1) <> "\n")), [
        :append
      ])
    end

    :ok = save_state(state_path, next_state)

    {:ok,
     %{
       accepted: length(ordered_records),
       duplicates: duplicates,
       event_ids: Enum.map(ordered_records, & &1.id)
     }}
  rescue
    error ->
      {:error, {Map.fetch!(config, :error_tag), error}}
  end

  @doc false
  @spec do_pending_events(Path.t(), Path.t(), pos_integer()) :: [map()]
  def do_pending_events(events_path, state_path, limit) when is_integer(limit) and limit > 0 do
    state = load_state(state_path)

    events_path
    |> read_lines()
    |> Enum.drop(Map.get(state, "acked_count", 0))
    |> Enum.take(limit)
    |> Enum.map(&decode_event_record/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  @spec do_ack(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def do_ack(state_path, count) when is_integer(count) and count >= 0 do
    state = load_state(state_path)
    save_state(state_path, Map.update(state, "acked_count", count, &(&1 + count)))
  end

  @doc false
  @spec do_stats(Path.t(), Path.t()) :: %{depth: non_neg_integer(), oldest_pending_event_at: String.t() | nil}
  def do_stats(events_path, state_path) do
    pending = do_pending_events(events_path, state_path, 10_000)

    %{
      depth: length(pending),
      oldest_pending_event_at:
        case List.first(pending) do
          %{"enqueued_at" => enqueued_at} -> enqueued_at
          %{enqueued_at: enqueued_at} -> enqueued_at
          _ -> nil
        end
    }
  end

  @doc false
  @spec do_reset(Path.t(), Path.t()) :: :ok
  def do_reset(events_path, state_path) do
    File.rm(events_path)
    File.rm(state_path)
    :ok
  end

  @doc false
  @spec base_dir() :: Path.t()
  def base_dir do
    SymphonyElixir.RunLedger.ledger_file_path()
    |> Path.dirname()
    |> Path.expand()
  end

  @doc false
  @spec timestamp(DateTime.t() | term()) :: String.t() | nil
  def timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def timestamp(_value), do: nil

  defp read_lines(path) do
    if File.exists?(path), do: File.stream!(path) |> Enum.to_list(), else: []
  rescue
    _error -> []
  end

  defp decode_event_record(line) when is_binary(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = record} -> record
      _ -> nil
    end
  end

  defp load_state(state_path) do
    if File.exists?(state_path) do
      case File.read(state_path) do
        {:ok, payload} ->
          case Jason.decode(payload) do
            {:ok, %{} = state} -> Map.merge(default_state(), state)
            _ -> default_state()
          end

        _ ->
          default_state()
      end
    else
      default_state()
    end
  end

  defp save_state(state_path, state) when is_map(state) do
    :ok = File.mkdir_p(base_dir())
    File.write(state_path, Jason.encode!(state), [:write])
  end

  defp default_state do
    %{"acked_count" => 0, "seen_dedupe_keys" => []}
  end

  defp seen_dedupe_key?(state, key) when is_map(state) and is_binary(key) do
    state
    |> Map.get("seen_dedupe_keys", [])
    |> Enum.member?(key)
  end

  defp remember_dedupe_key(state, key) when is_map(state) and is_binary(key) do
    keys =
      state
      |> Map.get("seen_dedupe_keys", [])
      |> Kernel.++([key])
      |> Enum.take(-@default_recent_dedupe_limit)

    Map.put(state, "seen_dedupe_keys", keys)
  end

  defp generate_event_id(prefix) do
    prefix <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defmacro __using__(opts) do
    event_module =
      opts
      |> Keyword.fetch!(:event_module)
      |> Macro.expand(__CALLER__)

    events_filename = Keyword.fetch!(opts, :events_filename)
    state_filename = Keyword.fetch!(opts, :state_filename)
    error_tag = Keyword.fetch!(opts, :error_tag)
    event_id_prefix = Keyword.fetch!(opts, :event_id_prefix)

    quote bind_quoted: [
            event_module: event_module,
            events_filename: events_filename,
            state_filename: state_filename,
            error_tag: error_tag,
            event_id_prefix: event_id_prefix
          ] do
      @events_filename events_filename
      @state_filename state_filename
      @error_tag error_tag
      @event_module event_module
      @event_id_prefix event_id_prefix
      @inbox_config %{event_module: @event_module, event_id_prefix: @event_id_prefix, error_tag: @error_tag}

      @type stored_event :: %{
              id: String.t(),
              dedupe_key: String.t(),
              enqueued_at: String.t(),
              event: map()
            }

      @spec enqueue([struct()]) ::
              {:ok, %{accepted: non_neg_integer(), duplicates: non_neg_integer(), event_ids: [String.t()]}}
              | {:error, term()}
      def enqueue(events) when is_list(events) do
        SymphonyElixir.EventInbox.do_enqueue(events, events_path(), state_path(), @inbox_config, &event_payload/1)
      end

      @spec pending_events() :: [stored_event()]
      @spec pending_events(pos_integer()) :: [stored_event()]
      def pending_events(limit \\ 100)

      @spec pending_events(pos_integer()) :: [stored_event()]
      def pending_events(limit) when is_integer(limit) and limit > 0 do
        SymphonyElixir.EventInbox.do_pending_events(events_path(), state_path(), limit)
      end

      def pending_events(_limit), do: []

      @spec ack(non_neg_integer()) :: :ok | {:error, term()}
      def ack(count) when is_integer(count) and count >= 0 do
        SymphonyElixir.EventInbox.do_ack(state_path(), count)
      end

      @spec stats() :: %{depth: non_neg_integer(), oldest_pending_event_at: String.t() | nil}
      def stats, do: SymphonyElixir.EventInbox.do_stats(events_path(), state_path())

      @spec reset() :: :ok
      def reset, do: SymphonyElixir.EventInbox.do_reset(events_path(), state_path())

      @spec events_path() :: Path.t()
      def events_path, do: Path.join(SymphonyElixir.EventInbox.base_dir(), @events_filename)

      @spec state_path() :: Path.t()
      def state_path, do: Path.join(SymphonyElixir.EventInbox.base_dir(), @state_filename)

      @spec base_dir() :: Path.t()
      def base_dir, do: SymphonyElixir.EventInbox.base_dir()

      defp timestamp(value), do: SymphonyElixir.EventInbox.timestamp(value)
    end
  end
end
