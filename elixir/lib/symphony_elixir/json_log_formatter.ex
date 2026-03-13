defmodule SymphonyElixir.JsonLogFormatter do
  @moduledoc """
  Formats OTP logger events as newline-delimited JSON.
  """

  @reserved_metadata [
    :erl_level,
    :domain,
    :file,
    :line,
    :mfa,
    :pid,
    :gl,
    :crash_reason,
    :time,
    :report_cb,
    :logger_formatter
  ]

  @spec format(map(), map()) :: iodata()
  def format(%{level: level, msg: message, meta: metadata} = event, _config) do
    metadata_map = Map.new(metadata)
    timestamp = Map.get(metadata_map, :time) || Map.get(event, :time)

    payload =
      %{
        timestamp: format_timestamp(timestamp),
        level: to_string(level),
        event: metadata_map[:event] || "log",
        message: render_message(message),
        issue_identifier: metadata_map[:issue_identifier],
        source: metadata_map[:source],
        repo: metadata_map[:repo],
        company: metadata_map[:company],
        stage: metadata_map[:stage],
        rule_id: metadata_map[:rule_id],
        failure_class: metadata_map[:failure_class],
        policy_class: metadata_map[:policy_class],
        workflow_profile: metadata_map[:workflow_profile],
        trace_id: metadata_map[:trace_id],
        span_id: metadata_map[:span_id],
        metadata: extra_metadata(metadata_map)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
      |> Map.new()

    [Jason.encode!(payload), "\n"]
  end

  @spec format(:logger.level(), :logger.message(), :logger.time(), :logger.metadata()) :: iodata()
  def format(level, message, timestamp, metadata) do
    format(%{level: level, msg: message, meta: metadata, time: timestamp}, %{})
  end

  defp render_message({:string, message}), do: IO.chardata_to_string(message)
  defp render_message({:report, report}), do: inspect(report, pretty: false, limit: 50)
  defp render_message(message) when is_binary(message), do: message
  defp render_message(message), do: inspect(message, pretty: false, limit: 50)

  defp format_timestamp({date, time, microsecond}) do
    {year, month, day} = date
    {hour, minute, second} = time
    {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second, {microsecond, 6})
    NaiveDateTime.to_iso8601(naive) <> "Z"
  rescue
    _error -> DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp format_timestamp(_timestamp), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp extra_metadata(metadata_map) do
    metadata_map
    |> Map.drop(@reserved_metadata ++ [:event, :issue_identifier, :source, :repo, :company, :stage, :rule_id, :failure_class, :policy_class, :workflow_profile, :trace_id, :span_id])
    |> Map.new(fn {key, value} -> {key, normalize_value(value)} end)
  end

  defp normalize_value(value) when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: inspect(value, pretty: false, limit: 20)
end
