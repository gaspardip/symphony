defmodule SymphonyElixir.GitHub.Webhook do
  @moduledoc """
  Verifies and decodes GitHub webhook payloads into normalized GitHub events.
  """

  alias SymphonyElixir.{Config, GitHubEvent}

  @supported_events ~w[pull_request_review pull_request_review_comment check_run workflow_run]

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

    entity = payload_entity(event_name, payload)
    pr_url = payload_pr_url(event_name, payload, pull_request, entity)

    updated_at =
      entity["updated_at"] ||
        entity["completed_at"] ||
        entity["run_started_at"] ||
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
      conclusion: blank_to_nil(entity["conclusion"]),
      check_name: blank_to_nil(entity["name"]),
      details_url: blank_to_nil(entity["details_url"] || entity["html_url"]),
      head_sha: blank_to_nil(entity["head_sha"]),
      raw: payload
    }

    if GitHubEvent.review_affecting?(event) or GitHubEvent.ci_affecting?(event) do
      {:ok, event}
    else
      {:ignore, :non_pr_affecting_event}
    end
  end

  defp entity_type("pull_request_review"), do: "PullRequestReview"
  defp entity_type("pull_request_review_comment"), do: "PullRequestReviewComment"
  defp entity_type("check_run"), do: "CheckRun"
  defp entity_type("workflow_run"), do: "WorkflowRun"

  defp payload_entity("pull_request_review", payload), do: payload["review"] || %{}
  defp payload_entity("pull_request_review_comment", payload), do: payload["comment"] || %{}
  defp payload_entity("check_run", payload), do: payload["check_run"] || %{}
  defp payload_entity("workflow_run", payload), do: payload["workflow_run"] || %{}
  defp payload_entity(_event_name, _payload), do: %{}

  defp payload_pr_url("pull_request_review", _payload, pull_request, _entity),
    do: blank_to_nil(pull_request["html_url"])

  defp payload_pr_url("pull_request_review_comment", _payload, pull_request, _entity),
    do: blank_to_nil(pull_request["html_url"])

  defp payload_pr_url(_event_name, _payload, pull_request, entity) do
    pull_request["html_url"] ||
      first_pull_request_html_url(entity["pull_requests"]) ||
      derive_pr_url_from_reference(entity["pull_requests"], pull_request)
  end

  defp first_pull_request_html_url(value) when is_list(value) do
    value
    |> Enum.find_value(fn
      %{"html_url" => html_url} when is_binary(html_url) and html_url != "" -> html_url
      _ -> nil
    end)
    |> blank_to_nil()
  end

  defp first_pull_request_html_url(_value), do: nil

  defp derive_pr_url_from_reference(pull_requests, pull_request) when is_list(pull_requests) do
    case List.first(pull_requests) do
      %{"number" => number} when is_integer(number) ->
        with %{"base" => %{"repo" => %{"html_url" => repo_url}}} <- pull_request,
             repo_url when is_binary(repo_url) and repo_url != "" <- repo_url do
          "#{repo_url}/pull/#{number}"
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp derive_pr_url_from_reference(_pull_requests, _pull_request), do: nil

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

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

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
