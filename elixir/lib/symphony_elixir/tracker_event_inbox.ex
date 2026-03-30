defmodule SymphonyElixir.TrackerEventInbox do
  @moduledoc """
  Durable file-backed inbox for tracker webhook events.
  """

  alias SymphonyElixir.TrackerEvent

  use SymphonyElixir.EventInbox,
    event_module: SymphonyElixir.TrackerEvent,
    events_filename: "tracker_events.jsonl",
    state_filename: "tracker_event_inbox_state.json",
    error_tag: :tracker_event_inbox_failed,
    event_id_prefix: "trk_"

  defp event_payload(%TrackerEvent{} = event) do
    %{
      "provider" => event.provider,
      "event_id" => event.event_id,
      "entity_type" => event.entity_type,
      "entity_id" => event.entity_id,
      "issue_identifier" => event.issue_identifier,
      "project_slug" => event.project_slug,
      "action" => event.action,
      "state_name" => event.state_name,
      "label_names" => event.label_names,
      "assignee_id" => event.assignee_id,
      "updated_at" => timestamp(event.updated_at),
      "raw" => event.raw
    }
  end
end
