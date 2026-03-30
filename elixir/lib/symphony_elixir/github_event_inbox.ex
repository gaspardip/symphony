defmodule SymphonyElixir.GitHubEventInbox do
  @moduledoc """
  Durable file-backed inbox for GitHub webhook events.
  """

  alias SymphonyElixir.GitHubEvent

  use SymphonyElixir.EventInbox,
    event_module: SymphonyElixir.GitHubEvent,
    events_filename: "github_events.jsonl",
    state_filename: "github_event_inbox_state.json",
    error_tag: :github_event_inbox_failed,
    event_id_prefix: "gh_"

  defp event_payload(%GitHubEvent{} = event) do
    %{
      "provider" => event.provider,
      "event_id" => event.event_id,
      "event_name" => event.event_name,
      "action" => event.action,
      "entity_type" => event.entity_type,
      "entity_id" => event.entity_id,
      "pr_url" => event.pr_url,
      "repo_full_name" => event.repo_full_name,
      "updated_at" => timestamp(event.updated_at),
      "conclusion" => event.conclusion,
      "check_name" => event.check_name,
      "details_url" => event.details_url,
      "head_sha" => event.head_sha,
      "received_runner_channel" => event.received_runner_channel,
      "received_runner_instance_id" => event.received_runner_instance_id,
      "target_runner_channel" => event.target_runner_channel,
      "assigned_runner_channel" => event.assigned_runner_channel,
      "assigned_runner_instance_id" => event.assigned_runner_instance_id,
      "assignment_state" => event.assignment_state,
      "assignment_reason" => event.assignment_reason,
      "raw" => event.raw
    }
  end
end
