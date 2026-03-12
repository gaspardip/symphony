defmodule SymphonyElixir.Linear.Webhook do
  @moduledoc """
  Linear webhook verification and normalization.
  """

  alias SymphonyElixir.{Config, TrackerEvent}

  @max_timestamp_skew_seconds 300
  @signature_headers ["linear-signature", "x-linear-signature"]
  @delivery_headers ["linear-delivery", "x-linear-delivery"]
  @timestamp_headers ["linear-timestamp", "x-linear-timestamp"]

  @spec decode([{binary(), binary()}], binary()) ::
          {:ok, [TrackerEvent.t()]} | {:ignore, term()} | {:error, term()}
  def decode(headers, raw_body) when is_list(headers) and is_binary(raw_body) do
    with {:ok, secret} <- webhook_secret(),
         {:ok, signature} <- fetch_header(headers, @signature_headers, :missing_linear_signature),
         :ok <- verify_signature(secret, raw_body, signature),
         {:ok, payload} <- decode_payload(raw_body),
         :ok <- verify_timestamp(headers, payload) do
      normalize_payload(headers, payload)
    end
  end

  defp webhook_secret do
    case Config.linear_webhook_secret() do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :missing_linear_webhook_secret}
    end
  end

  defp decode_payload(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = payload} -> {:ok, payload}
      _ -> {:error, :invalid_webhook_payload}
    end
  end

  defp verify_signature(secret, raw_body, signature) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, String.downcase(String.trim(signature))) do
      :ok
    else
      {:error, :invalid_linear_signature}
    end
  rescue
    _error ->
      {:error, :invalid_linear_signature}
  end

  defp verify_timestamp(headers, payload) do
    timestamp_value =
      Enum.find_value(@timestamp_headers, &header_value(headers, &1)) ||
        Map.get(payload, "webhookTimestamp") ||
        Map.get(payload, "timestamp")

    case parse_timestamp(timestamp_value) do
      nil ->
        :ok

      %DateTime{} = timestamp ->
        if abs(DateTime.diff(DateTime.utc_now(), timestamp, :second)) <= @max_timestamp_skew_seconds do
          :ok
        else
          {:error, :stale_linear_webhook_timestamp}
        end
    end
  end

  defp normalize_payload(headers, %{"type" => type, "action" => action, "data" => %{} = data} = payload)
       when is_binary(type) and is_binary(action) do
    normalized_type = String.downcase(String.trim(type))
    normalized_action = String.downcase(String.trim(action))

    event =
      %TrackerEvent{
        provider: "linear",
        event_id: Enum.find_value(@delivery_headers, &header_value(headers, &1)),
        entity_type: type,
        entity_id: data["id"],
        issue_identifier: data["identifier"],
        project_slug: project_slug(data),
        action: normalized_action,
        state_name: state_name(data),
        label_names: label_names(data),
        assignee_id: assignee_id(data),
        updated_at: parse_timestamp(data["updatedAt"] || payload["updatedAt"]),
        raw: payload
      }

    cond do
      normalized_type != "issue" ->
        {:ignore, :non_issue_event}

      not schedule_affecting_payload?(normalized_action, payload) ->
        {:ignore, :non_schedule_affecting_event}

      true ->
        {:ok, [event]}
    end
  end

  defp normalize_payload(_headers, _payload), do: {:error, :invalid_webhook_payload}

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) when is_integer(value) do
    unit =
      if value > 99_999_999_999 do
        :millisecond
      else
        :second
      end

    value
    |> DateTime.from_unix(unit)
    |> case do
      {:ok, timestamp} -> timestamp
      _ -> nil
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      match?({_, ""}, Integer.parse(trimmed)) ->
        {unix, ""} = Integer.parse(trimmed)
        parse_timestamp(unix)

      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, timestamp, _offset} -> timestamp
          _ -> nil
        end
    end
  end

  defp parse_timestamp(_value), do: nil

  defp project_slug(%{"project" => %{"slugId" => slug_id}}) when is_binary(slug_id), do: slug_id
  defp project_slug(%{"project" => %{"slug" => slug}}) when is_binary(slug), do: slug
  defp project_slug(%{"projectSlugId" => slug_id}) when is_binary(slug_id), do: slug_id
  defp project_slug(_data), do: nil

  defp state_name(%{"state" => %{"name" => name}}) when is_binary(name), do: name
  defp state_name(%{"stateName" => name}) when is_binary(name), do: name
  defp state_name(_data), do: nil

  defp assignee_id(%{"assignee" => %{"id" => assignee_id}}) when is_binary(assignee_id), do: assignee_id
  defp assignee_id(%{"assigneeId" => assignee_id}) when is_binary(assignee_id), do: assignee_id
  defp assignee_id(_data), do: nil

  defp label_names(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> TrackerEvent.normalize_labels()
  end

  defp label_names(%{"labelIds" => labels}) when is_list(labels), do: TrackerEvent.normalize_labels(labels)
  defp label_names(_data), do: []

  defp schedule_affecting_payload?(action, _payload)
       when action in ["create", "remove", "delete", "archive"],
       do: true

  defp schedule_affecting_payload?("update", %{"updatedFrom" => %{} = updated_from}) do
    updated_from
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(&(&1 in schedule_affecting_update_keys()))
  end

  defp schedule_affecting_payload?("update", _payload), do: true
  defp schedule_affecting_payload?(_action, _payload), do: false

  defp schedule_affecting_update_keys do
    [
      "state",
      "stateid",
      "assignee",
      "assigneeid",
      "labels",
      "labelids",
      "title",
      "description",
      "project",
      "projectid"
    ]
  end

  defp fetch_header(headers, candidates, error) do
    case Enum.find_value(candidates, &header_value(headers, &1)) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp header_value(headers, wanted_name) when is_list(headers) and is_binary(wanted_name) do
    Enum.find_value(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == wanted_name, do: value

      _ ->
        nil
    end)
  end
end
