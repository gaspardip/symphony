defmodule SymphonyElixir.TrackerEvent do
  @moduledoc """
  Normalized tracker event used by webhook-backed intake.
  """

  @enforce_keys [:provider, :entity_type, :action, :raw]
  defstruct [
    :provider,
    :event_id,
    :entity_type,
    :entity_id,
    :issue_identifier,
    :project_slug,
    :action,
    :state_name,
    :assignee_id,
    :updated_at,
    :raw,
    label_names: []
  ]

  @type t :: %__MODULE__{
          provider: String.t(),
          event_id: String.t() | nil,
          entity_type: String.t(),
          entity_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          project_slug: String.t() | nil,
          action: String.t(),
          state_name: String.t() | nil,
          label_names: [String.t()],
          assignee_id: String.t() | nil,
          updated_at: DateTime.t() | nil,
          raw: map()
        }

  @spec dedupe_key(t()) :: String.t()
  def dedupe_key(%__MODULE__{} = event) do
    base =
      [
        event.provider,
        event.event_id,
        event.entity_type,
        event.entity_id,
        event.action,
        timestamp_fragment(event.updated_at)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")

    if base == "" do
      "tracker-event:" <>
        :crypto.hash(:sha256, Jason.encode!(event.raw))
        |> Base.encode16(case: :lower)
    else
      base
    end
  end

  @spec schedule_affecting?(t()) :: boolean()
  def schedule_affecting?(%__MODULE__{entity_type: entity_type, action: action})
      when is_binary(entity_type) and is_binary(action) do
    String.downcase(String.trim(entity_type)) == "issue" and
      String.downcase(String.trim(action)) in ["create", "update", "remove", "delete", "archive"]
  end

  def schedule_affecting?(_event), do: false

  @spec normalize_labels([term()]) :: [String.t()]
  def normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  def normalize_labels(_labels), do: []

  defp timestamp_fragment(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_fragment(_value), do: nil
end
