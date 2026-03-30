defmodule SymphonyElixir.EventInbox do
  @moduledoc false

  alias SymphonyElixir.RunLedger

  @default_recent_dedupe_limit 2_000

  defmacro __using__(opts) do
    event_module = Keyword.fetch!(opts, :event_module)
    events_filename = Keyword.fetch!(opts, :events_filename)
    state_filename = Keyword.fetch!(opts, :state_filename)
    error_tag = Keyword.fetch!(opts, :error_tag)
    event_id_prefix = Keyword.fetch!(opts, :event_id_prefix)
    default_recent_dedupe_limit = @default_recent_dedupe_limit

    quote bind_quoted: [
            event_module: event_module,
            events_filename: events_filename,
            state_filename: state_filename,
            error_tag: error_tag,
            event_id_prefix: event_id_prefix,
            default_recent_dedupe_limit: default_recent_dedupe_limit
          ] do
      @events_filename events_filename
      @state_filename state_filename
      @error_tag error_tag
      @event_module event_module
      @event_id_prefix event_id_prefix
      @default_recent_dedupe_limit default_recent_dedupe_limit

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
        state = load_state()

        {records, next_state, duplicates} =
          Enum.reduce(events, {[], state, 0}, fn
            event, {acc, state_acc, duplicate_count} when is_struct(event, @event_module) ->
              key = @event_module.dedupe_key(event)

              if seen_dedupe_key?(state_acc, key) do
                {acc, state_acc, duplicate_count + 1}
              else
                record = %{
                  id: event.event_id || generate_event_id(),
                  dedupe_key: key,
                  enqueued_at: now_iso8601(),
                  event: event_payload(event)
                }

                {[record | acc], remember_dedupe_key(state_acc, key), duplicate_count}
              end

            _other, acc_state ->
              acc_state
          end)

        ordered_records = Enum.reverse(records)
        :ok = File.mkdir_p(base_dir())

        if ordered_records != [] do
          File.write!(events_path(), Enum.map_join(ordered_records, "", &(Jason.encode!(&1) <> "\n")), [
            :append
          ])
        end

        :ok = save_state(next_state)

        {:ok,
         %{
           accepted: length(ordered_records),
           duplicates: duplicates,
           event_ids: Enum.map(ordered_records, & &1.id)
         }}
      rescue
        error ->
          {:error, {@error_tag, error}}
      end

      @spec pending_events() :: [stored_event()]
      @spec pending_events(pos_integer()) :: [stored_event()]
      def pending_events(limit \\ 100)

      @spec pending_events(pos_integer()) :: [stored_event()]
      def pending_events(limit) when is_integer(limit) and limit > 0 do
        state = load_state()

        events_path()
        |> read_lines()
        |> Enum.drop(Map.get(state, "acked_count", 0))
        |> Enum.take(limit)
        |> Enum.map(&decode_event_record/1)
        |> Enum.reject(&is_nil/1)
      end

      def pending_events(_limit), do: []

      @spec ack(non_neg_integer()) :: :ok | {:error, term()}
      def ack(count) when is_integer(count) and count >= 0 do
        state = load_state()
        save_state(Map.update(state, "acked_count", count, &(&1 + count)))
      end

      @spec stats() :: %{depth: non_neg_integer(), oldest_pending_event_at: String.t() | nil}
      def stats do
        pending = pending_events(10_000)

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

      @spec reset() :: :ok
      def reset do
        File.rm(events_path())
        File.rm(state_path())
        :ok
      end

      @spec events_path() :: Path.t()
      def events_path, do: Path.join(base_dir(), @events_filename)

      @spec state_path() :: Path.t()
      def state_path, do: Path.join(base_dir(), @state_filename)

      @spec base_dir() :: Path.t()
      def base_dir do
        RunLedger.ledger_file_path()
        |> Path.dirname()
        |> Path.expand()
      end

      defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
      defp timestamp(_value), do: nil

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

      defp load_state do
        if File.exists?(state_path()) do
          case File.read(state_path()) do
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

      defp save_state(state) when is_map(state) do
        :ok = File.mkdir_p(base_dir())
        File.write(state_path(), Jason.encode!(state), [:write])
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

      defp generate_event_id do
        @event_id_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      end

      defp now_iso8601 do
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      end
    end
  end
end
