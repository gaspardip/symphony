defmodule SymphonyElixir.GitHubEvent do
  @moduledoc """
  Normalized GitHub webhook event used for PR/review and CI feedback ingestion.
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
    :conclusion,
    :check_name,
    :details_url,
    :head_sha,
    :received_runner_channel,
    :received_runner_instance_id,
    :target_runner_channel,
    :assigned_runner_channel,
    :assigned_runner_instance_id,
    :assignment_state,
    :assignment_reason,
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
          conclusion: String.t() | nil,
          check_name: String.t() | nil,
          details_url: String.t() | nil,
          head_sha: String.t() | nil,
          received_runner_channel: String.t() | nil,
          received_runner_instance_id: String.t() | nil,
          target_runner_channel: String.t() | nil,
          assigned_runner_channel: String.t() | nil,
          assigned_runner_instance_id: String.t() | nil,
          assignment_state: String.t() | nil,
          assignment_reason: String.t() | nil,
          raw: map()
        }

  @review_events ["pull_request_review", "pull_request_review_comment"]
  @ci_events ["check_run", "workflow_run"]
  @failing_ci_conclusions ["action_required", "cancelled", "failure", "startup_failure", "timed_out"]

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
      "github-event:" <>
        (:crypto.hash(:sha256, Jason.encode!(event.raw))
         |> Base.encode16(case: :lower))
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

  @spec ci_affecting?(t()) :: boolean()
  def ci_affecting?(%__MODULE__{event_name: event_name, pr_url: pr_url})
      when is_binary(event_name) do
    event_name in @ci_events and is_binary(pr_url) and String.trim(pr_url) != ""
  end

  def ci_affecting?(_event), do: false

  @spec ci_failure_affecting?(t()) :: boolean()
  def ci_failure_affecting?(%__MODULE__{} = event) do
    ci_affecting?(event) and ci_failure?(event)
  end

  @spec ci_failure?(t()) :: boolean()
  def ci_failure?(%__MODULE__{conclusion: conclusion}) when is_binary(conclusion) do
    String.downcase(String.trim(conclusion)) in @failing_ci_conclusions
  end

  def ci_failure?(_event), do: false

  @spec failure_summary(t()) :: String.t() | nil
  def failure_summary(%__MODULE__{} = event) do
    check_name =
      event.check_name
      |> to_string()
      |> String.trim()

    conclusion =
      event.conclusion
      |> to_string()
      |> String.trim()

    cond do
      check_name != "" and conclusion != "" -> "#{check_name} (#{conclusion})"
      check_name != "" -> check_name
      conclusion != "" -> conclusion
      true -> nil
    end
  end

  defp timestamp_fragment(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_fragment(_value), do: nil
end
