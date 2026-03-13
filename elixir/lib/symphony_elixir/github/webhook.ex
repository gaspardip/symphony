defmodule SymphonyElixir.GitHub.Webhook do
  @moduledoc """
  Verifies and decodes GitHub webhook payloads into normalized GitHub events.
  """

  alias SymphonyElixir.{Config, GitHubEvent}

  @supported_events ~w[pull_request_review pull_request_review_comment]

  @spec decode([{binary(), binary()}], binary()) ::
          {:ok, [GitHubEvent.t()]} | {:ignore, atom()} | {:error, term()}
  def decode(headers, raw_body) when is_list(headers) and is_binary(raw_body) do
    with secret when is_binary(secret) and secret != "" <- Config.github_webhook_secret() || :missing_secret,
         :ok <- verify_signature(secret, headers, raw_body),
         event_name when is_binary(event_name) <- header(headers, "x-github-event"),
         delivery_id <- header(headers, "x-github-delivery"),
         true <- event_name in @supported_events or {:ignore, :unsupported_event},
         {:ok, payload} <- Jason.decode(raw_body),
         {:ok, event} <- decode_event(event_name, delivery_id, payload) do
      {:ok, [event]}
    else
      :missing_secret -> {:error, :missing_github_webhook_secret}
      {:ignore, reason} -> {:ignore, reason}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_github_payload}
      nil -> {:error, :missing_github_headers}
    end
  end

  defp decode_event(event_name, delivery_id, payload) when event_name in @supported_events do
    action = payload["action"] |> to_string()
    pull_request = payload["pull_request"] || %{}
    repository = payload["repository"] || %{}

    pr_url = pull_request["html_url"]

    entity =
      case event_name do
        "pull_request_review" -> payload["review"] || %{}
        "pull_request_review_comment" -> payload["comment"] || %{}
      end

    updated_at =
      entity["updated_at"] ||
        entity["submitted_at"] ||
        entity["created_at"] ||
        pull_request["updated_at"]

    event = %GitHubEvent{
      provider: "github",
      event_id: delivery_id,
      event_name: event_name,
      action: action,
      entity_type: entity_type(event_name),
      entity_id: to_string(entity["id"] || ""),
      pr_url: pr_url,
      repo_full_name: repository["full_name"],
      updated_at: parse_datetime(updated_at),
      raw: payload
    }

    if GitHubEvent.review_affecting?(event) do
      {:ok, event}
    else
      {:ignore, :non_review_affecting_event}
    end
  end

  defp entity_type("pull_request_review"), do: "PullRequestReview"
  defp entity_type("pull_request_review_comment"), do: "PullRequestReviewComment"

  defp verify_signature(secret, headers, raw_body) do
    signature = header(headers, "x-hub-signature-256")

    with value when is_binary(value) and value != "" <- signature,
         "sha256=" <> their_hex <- value do
      ours =
        :crypto.mac(:hmac, :sha256, secret, raw_body)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(ours, String.downcase(their_hex)) do
        :ok
      else
        {:error, :invalid_github_signature}
      end
    else
      _ -> {:error, :invalid_github_signature}
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp header(headers, key) do
    headers
    |> Enum.find_value(fn
      {^key, value} ->
        value

      {other, value} when is_binary(other) and is_binary(value) ->
        if String.downcase(other) == key, do: value, else: nil

      _ ->
        nil
    end)
  end
end
