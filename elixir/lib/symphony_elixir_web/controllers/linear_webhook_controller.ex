defmodule SymphonyElixirWeb.LinearWebhookController do
  @moduledoc """
  Linear webhook ingress for webhook-first tracker intake.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Tracker, TrackerEventInbox}
  alias SymphonyElixirWeb.Endpoint

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""

    case Tracker.decode_webhook(conn.req_headers, raw_body) do
      {:ok, events} ->
        case TrackerEventInbox.enqueue(events) do
          {:ok, result} ->
            _ =
              orchestrator()
              |> SymphonyElixir.Orchestrator.notify_tracker_events(%{
                accepted_at: DateTime.utc_now(),
                accepted: result.accepted,
                duplicates: result.duplicates,
                event_ids: result.event_ids
              })

            conn
            |> put_status(200)
            |> json(%{accepted: result.accepted, duplicates: result.duplicates})

          {:error, reason} ->
            notify_rejected("Failed to enqueue verified webhook event.", "webhook.enqueue_failed")

            conn
            |> put_status(503)
            |> json(%{error: %{code: "webhook_enqueue_failed", message: inspect(reason)}})
        end

      {:ignore, reason} ->
        _ =
          orchestrator()
          |> SymphonyElixir.Orchestrator.notify_tracker_webhook_ignored(%{
            ignored_at: DateTime.utc_now(),
            reason: to_string(reason),
            rule_id: "webhook.event_ignored"
          })

        conn
        |> put_status(200)
        |> json(%{accepted: 0, ignored: true, reason: to_string(reason)})

      {:error, :missing_linear_webhook_secret} ->
        notify_rejected("Linear webhook secret is not configured.", "webhook.payload_invalid")

        conn
        |> put_status(503)
        |> json(%{error: %{code: "missing_webhook_secret", message: "Webhook secret not configured"}})

      {:error, :invalid_linear_signature} ->
        notify_rejected("Linear webhook signature verification failed.", "webhook.signature_invalid")

        conn
        |> put_status(401)
        |> json(%{error: %{code: "invalid_signature", message: "Invalid webhook signature"}})

      {:error, reason} ->
        notify_rejected("Linear webhook payload could not be decoded.", "webhook.payload_invalid")

        conn
        |> put_status(400)
        |> json(%{error: %{code: "invalid_webhook_payload", message: inspect(reason)}})
    end
  end

  defp notify_rejected(summary, rule_id) do
    orchestrator()
    |> SymphonyElixir.Orchestrator.notify_tracker_webhook_rejected(%{
      rejected_at: DateTime.utc_now(),
      reason: summary,
      rule_id: rule_id
    })
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end
end
