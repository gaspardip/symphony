defmodule SymphonyElixir.RunLedger do
  @moduledoc """
  Appends typed audit events to a local JSONL ledger while preserving
  compatibility with legacy entries.
  """

  # credo:disable-for-this-file

  alias SymphonyElixir.Observability

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
      |> Map.put_new(:at, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())

    path = ledger_file_path()
    :ok = File.mkdir_p(Path.dirname(path))
    File.write!(path, Jason.encode!(entry) <> "\n", [:append])
    :ok
  rescue
    _error ->
      :ok
  end

  @spec record(String.t(), map()) :: map()
  def record(event_type, attrs \\ %{}) when is_binary(event_type) and is_map(attrs) do
    entry =
      attrs
      |> typed_entry(event_type)
      |> persist_entry()

    Observability.emit_ledger_event(event_type, entry)
    entry
  rescue
    _error ->
      typed_entry(attrs, event_type)
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
    metadata =
      attrs
      |> Map.get(:metadata, %{})
      |> Map.merge(extra_metadata(attrs))

    %{
      schema_version: @schema_version,
      event: event_type,
      event_type: event_type,
      event_id: generate_event_id(),
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
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
  end

  defp persist_entry(entry) do
    path = ledger_file_path()
    :ok = File.mkdir_p(Path.dirname(path))
    File.write!(path, Jason.encode!(entry) <> "\n", [:append])
    entry
  end

  defp extra_metadata(attrs) do
    attrs
    |> Enum.reject(fn {key, _value} -> key in @reserved_keys end)
    |> Map.new()
  end

  defp generate_event_id do
    "evt_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
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
