defmodule SymphonyElixir.GitHubEvent do
  @moduledoc """
  Normalized GitHub webhook event used for PR/review feedback ingestion.
  """

  @enforce_keys [:provider, :event_name, :action, :raw]
  defstruct [
    :provider,
    :event_id,
    :event_name,
    :action,
    :entity_type,
    :entity_id,
    :pr_url,
    :repo_full_name,
    :updated_at,
    :raw
  ]

  @type t :: %__MODULE__{
          provider: String.t(),
          event_id: String.t() | nil,
          event_name: String.t(),
          action: String.t(),
          entity_type: String.t() | nil,
          entity_id: String.t() | nil,
          pr_url: String.t() | nil,
          repo_full_name: String.t() | nil,
          updated_at: DateTime.t() | nil,
          raw: map()
        }

  @review_events ["pull_request_review", "pull_request_review_comment"]

  @spec dedupe_key(t()) :: String.t()
  def dedupe_key(%__MODULE__{} = event) do
    base =
      [
        event.provider,
        event.event_id,
        event.event_name,
        event.action,
        event.entity_id,
        event.pr_url,
        timestamp_fragment(event.updated_at)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")

    if base == "" do
      ("github-event:" <>
         :crypto.hash(:sha256, Jason.encode!(event.raw)))
      |> Base.encode16(case: :lower)
    else
      base
    end
  end

  @spec review_affecting?(t()) :: boolean()
  def review_affecting?(%__MODULE__{event_name: event_name, pr_url: pr_url})
      when is_binary(event_name) do
    event_name in @review_events and is_binary(pr_url) and String.trim(pr_url) != ""
  end

  def review_affecting?(_event), do: false

  defp timestamp_fragment(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_fragment(_value), do: nil
end
