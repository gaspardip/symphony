defmodule SymphonyElixir.Orchestrator.GitHubFollowUp do
  @moduledoc """
  Derives GitHub feedback updates from a checked snapshot and the owner's
  current eligibility decision. A plan contains no authority to persist or
  dispatch; the orchestrator retains those checks and effects.
  """

  alias SymphonyElixir.GitHubEvent
  alias SymphonyElixir.PRWatcher
  alias SymphonyElixir.ReviewEvidenceCollector

  @type snapshot_fields :: %{
          optional(:issue_source) => String.t() | nil,
          optional(:stage) => String.t() | nil,
          optional(:resume_context) => term(),
          optional(:review_threads) => map(),
          optional(:review_claims) => map()
        }

  @type plan :: %{
          stage: String.t() | nil,
          attrs: map(),
          event: String.t(),
          metadata: map()
        }

  @doc """
  Returns an observation or an implementation/review-verification transition.

  `fresh` preserves the five snapshot fields without adding defaults. Review
  events require the feedback map already read by the owner; CI accepts nil.
  `eligible` is evaluated by the owner for this invocation, never cached here.
  """
  @spec plan(GitHubEvent.t(), snapshot_fields(), map() | nil, boolean()) :: plan()
  def plan(event, fresh, feedback, autonomous) do
    if GitHubEvent.review_affecting?(event) do
      github_review_decision(feedback, fresh, event.pr_url, autonomous)
    else
      failure = ci_failure_payload(event, event.pr_url)
      stage = if autonomous, do: "implement", else: nil

      summary =
        if autonomous,
          do: "GitHub CI failure detected on #{event.pr_url}. Returning to implement to fix failing checks.",
          else: "GitHub CI failure detected on #{event.pr_url}: #{ci_failure_summary(failure)}."

      objective = "Investigate and fix the failing GitHub checks on #{event.pr_url}. Focus first on #{ci_failure_summary(failure)} and return the branch to runtime validation."
      failure_context = if autonomous, do: Map.put(failure, :next_objective, objective), else: failure

      attrs = %{
        last_ci_failure: failure,
        last_decision_summary: summary,
        next_human_action: if(autonomous, do: nil, else: "Inspect the failing GitHub checks and decide whether Symphony should reopen implementation."),
        resume_context: ci_resume_context(Map.get(fresh, :resume_context), event.pr_url, failure_context)
      }

      attrs =
        if autonomous,
          do: Map.merge(attrs, %{issue_source: fresh[:issue_source], pr_url: event.pr_url, stop_reason: nil, last_decision: nil, last_rule_id: nil, last_failure_class: nil, await_checks_polls: 0}),
          else: attrs

      %{stage: stage, attrs: attrs, event: if(autonomous, do: "ci.failure_autonomous_follow_up", else: "ci.failure_detected"), metadata: failure}
    end
  end

  defp github_review_decision(feedback, fresh, pr_url, eligible) do
    {review_threads, review_claims} = github_review_maps(fresh, feedback, pr_url)
    autonomous = eligible and PRWatcher.actionable_feedback?(feedback)
    noise = eligible and not PRWatcher.actionable_feedback?(feedback)
    stage = if autonomous, do: PRWatcher.follow_up_stage(feedback), else: nil

    summary =
      cond do
        stage == "review_verification" -> "GitHub review feedback detected on #{pr_url}. Returning to review_verification before reopening implementation."
        autonomous -> "GitHub review feedback detected on #{pr_url}. Returning to implement to address the requested changes."
        noise -> "GitHub review feedback detected on #{pr_url}, but the current adjudicator triaged it as non-actionable noise."
        true -> "New PR review feedback detected on #{pr_url}."
      end

    objective =
      case stage do
        "review_verification" -> "Verify the pending GitHub review feedback on #{pr_url}, collect local evidence, and reopen implementation only for verified claims."
        "implement" -> "Address the pending GitHub review feedback on #{pr_url}, update the code, and return the branch to runtime validation."
        nil -> nil
      end

    attrs = %{
      review_threads: review_threads,
      review_claims: review_claims,
      last_review_decision: Map.get(feedback, :review_decision),
      last_decision_summary: summary,
      next_human_action: if(autonomous or noise, do: nil, else: "Review drafted replies and decide whether to address code changes or post a response."),
      resume_context: review_resume_context(Map.get(fresh, :resume_context), pr_url, review_threads, review_claims, objective)
    }

    attrs =
      if autonomous,
        do:
          Map.merge(attrs, %{issue_source: fresh[:issue_source], pr_url: pr_url, review_return_stage: fresh[:stage], stop_reason: nil, last_decision: nil, last_rule_id: nil, last_failure_class: nil}),
        else: attrs

    type =
      cond do
        autonomous -> "review.feedback_autonomous_follow_up"
        noise -> "review.feedback_triaged"
        true -> "review.feedback_detected"
      end

    %{
      stage: stage,
      attrs: attrs,
      event: type,
      metadata: %{pending_drafts_count: Map.get(feedback, :pending_drafts_count, 0), review_decision: Map.get(feedback, :review_decision), target_stage: stage}
    }
  end

  defp github_review_maps(fresh, feedback, pr_url) do
    review_claims =
      feedback
      |> Map.get(:items, [])
      |> Enum.reduce(Map.get(fresh, :review_claims, %{}), fn item, acc ->
        case Map.get(item, :thread_key) do
          thread_key when is_binary(thread_key) ->
            persisted = Map.get(acc, thread_key, %{})

            verification_status = review_claim_verification_status(persisted, item)

            claim_state = %{
              "thread_key" => Map.get(item, :thread_key),
              "id" => Map.get(item, :id),
              "kind" => Map.get(item, :kind) |> to_string(),
              "author" => Map.get(item, :author),
              "body" => Map.get(item, :body),
              "path" => Map.get(item, :path),
              "line" => Map.get(item, :line),
              "state" => Map.get(item, :state),
              "review_decision" => Map.get(item, :review_decision),
              "submitted_at" => Map.get(item, :submitted_at),
              "source_class" => Map.get(item, :source_class),
              "claim_type" => Map.get(item, :claim_type),
              "veracity_score" => Map.get(item, :veracity_score),
              "reproducibility_score" => Map.get(item, :reproducibility_score),
              "evidence_quality_score" => Map.get(item, :evidence_quality_score),
              "locality_score" => Map.get(item, :locality_score),
              "source_precision_score" => Map.get(item, :source_precision_score),
              "consensus_score" => Map.get(item, :consensus_score),
              "consensus_state" => Map.get(item, :consensus_state),
              "consensus_summary" => Map.get(item, :consensus_summary),
              "consensus_reasons" => Map.get(item, :consensus_reasons, []),
              "historical_precision_score" => Map.get(item, :historical_precision_score),
              "stagnation_score" => Map.get(item, :stagnation_score),
              "stagnation_state" => Map.get(item, :stagnation_state),
              "repeated_feedback_count" => Map.get(item, :repeated_feedback_count, 1),
              "hard_proof" => Map.get(item, :hard_proof, false),
              "proof_sources" => Map.get(item, :proof_sources, []),
              "contradiction_sources" => Map.get(item, :contradiction_sources, []),
              "disposition" => Map.get(item, :disposition),
              "actionable" => Map.get(item, :actionable, false),
              "adjudication_summary" => Map.get(item, :adjudication_summary),
              "verification_status" => verification_status,
              "verification_attempts" => Map.get(persisted, "verification_attempts", 0),
              "evidence_refs" => Map.get(persisted, "evidence_refs", []),
              "evidence_summary" => Map.get(persisted, "evidence_summary"),
              "pr_url" => pr_url
            }

            Map.put(acc, thread_key, claim_state)

          _ ->
            acc
        end
      end)

    review_threads =
      feedback
      |> Map.get(:items, [])
      |> Enum.reduce(Map.get(fresh, :review_threads, %{}), fn item, acc ->
        case Map.get(item, :thread_key) do
          thread_key when is_binary(thread_key) ->
            Map.put(acc, thread_key, review_thread_state(item, pr_url))

          _ ->
            acc
        end
      end)

    {review_threads, review_claims}
  end

  defp ci_failure_payload(%GitHubEvent{} = event, pr_url) do
    %{
      event_name: Map.get(event, :event_name),
      action: Map.get(event, :action),
      check_name: Map.get(event, :check_name),
      conclusion: Map.get(event, :conclusion),
      details_url: Map.get(event, :details_url),
      head_sha: Map.get(event, :head_sha),
      pr_url: pr_url,
      summary: GitHubEvent.failure_summary(event)
    }
  end

  defp ci_resume_context(current_context, pr_url, ci_failure) when is_map(ci_failure) do
    context =
      case current_context do
        value when is_map(value) -> value
        _ -> %{}
      end

    context
    |> Map.put(:ci_failure_summary, ci_failure_summary(ci_failure))
    |> Map.put(:ci_failure_pr_url, pr_url)
    |> Map.put(:ci_failure_details_url, Map.get(ci_failure, :details_url))
    |> maybe_put_context_value(:next_objective, Map.get(ci_failure, :next_objective))
  end

  defp ci_failure_summary(ci_failure) when is_map(ci_failure) do
    Map.get(ci_failure, :summary) ||
      GitHubEvent.failure_summary(%GitHubEvent{
        provider: "github",
        event_name: to_string(Map.get(ci_failure, :event_name) || ""),
        action: to_string(Map.get(ci_failure, :action) || ""),
        raw: %{},
        conclusion: Map.get(ci_failure, :conclusion),
        check_name: Map.get(ci_failure, :check_name)
      }) ||
      "failing required checks"
  end

  defp maybe_put_context_value(context, _key, value) when value in [nil, ""], do: context
  defp maybe_put_context_value(context, key, value), do: Map.put(context, key, value)

  defp review_thread_state(item, pr_url) when is_map(item) do
    %{
      "thread_key" => Map.get(item, :thread_key),
      "id" => Map.get(item, :id),
      "kind" => Map.get(item, :kind) |> to_string(),
      "author" => Map.get(item, :author),
      "body" => Map.get(item, :body),
      "path" => Map.get(item, :path),
      "line" => Map.get(item, :line),
      "state" => Map.get(item, :state),
      "review_decision" => Map.get(item, :review_decision),
      "submitted_at" => Map.get(item, :submitted_at),
      "draft_state" => Map.get(item, :draft_state, "drafted"),
      "draft_reply" => Map.get(item, :draft_reply),
      "resolution_recommendation" => Map.get(item, :resolution_recommendation),
      "source_class" => Map.get(item, :source_class),
      "claim_type" => Map.get(item, :claim_type),
      "veracity_score" => Map.get(item, :veracity_score),
      "reproducibility_score" => Map.get(item, :reproducibility_score),
      "evidence_quality_score" => Map.get(item, :evidence_quality_score),
      "locality_score" => Map.get(item, :locality_score),
      "source_precision_score" => Map.get(item, :source_precision_score),
      "consensus_score" => Map.get(item, :consensus_score),
      "consensus_state" => Map.get(item, :consensus_state),
      "consensus_summary" => Map.get(item, :consensus_summary),
      "consensus_reasons" => Map.get(item, :consensus_reasons, []),
      "historical_precision_score" => Map.get(item, :historical_precision_score),
      "stagnation_score" => Map.get(item, :stagnation_score),
      "stagnation_state" => Map.get(item, :stagnation_state),
      "repeated_feedback_count" => Map.get(item, :repeated_feedback_count, 1),
      "hard_proof" => Map.get(item, :hard_proof, false),
      "proof_sources" => Map.get(item, :proof_sources, []),
      "contradiction_sources" => Map.get(item, :contradiction_sources, []),
      "disposition" => Map.get(item, :disposition),
      "actionable" => Map.get(item, :actionable, false),
      "adjudication_summary" => Map.get(item, :adjudication_summary),
      "pr_url" => pr_url
    }
  end

  defp review_claim_verification_status(persisted, item)
       when is_map(persisted) and is_map(item) do
    persisted_status = Map.get(persisted, "verification_status")
    disposition = Map.get(item, :disposition)

    cond do
      disposition == "needs_verification" and
          persisted_status in [nil, "", "not_needed", "contradicted"] ->
        "pending"

      is_binary(persisted_status) and persisted_status != "" ->
        persisted_status

      disposition == "needs_verification" ->
        "pending"

      true ->
        "not_needed"
    end
  end

  defp review_resume_context(
         current_context,
         pr_url,
         review_threads,
         review_claims,
         next_objective
       ) do
    context =
      case current_context do
        value when is_map(value) -> value
        _ -> %{}
      end

    context =
      context
      |> Map.put(:review_feedback_summary, review_feedback_summary(review_threads))
      |> Map.put(:review_claim_summary, ReviewEvidenceCollector.summary(review_claims))
      |> Map.put(:review_feedback_pr_url, pr_url)

    if is_binary(next_objective) and String.trim(next_objective) != "" do
      Map.put(context, :next_objective, next_objective)
    else
      context
    end
  end

  defp review_feedback_summary(review_threads) when is_map(review_threads) do
    review_threads
    |> Enum.sort_by(fn {thread_key, _thread_state} -> thread_key end)
    |> Enum.take(8)
    |> Enum.map(fn {_thread_key, thread_state} ->
      kind = Map.get(thread_state, "kind") || "comment"

      location =
        case {Map.get(thread_state, "path"), Map.get(thread_state, "line")} do
          {path, line} when is_binary(path) and is_integer(line) -> " #{path}:#{line}"
          {path, _line} when is_binary(path) -> " #{path}"
          _ -> ""
        end

      body =
        thread_state
        |> Map.get("body")
        |> to_string()
        |> String.trim()
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 280)

      "- #{kind}#{location}: #{body}"
    end)
    |> Enum.reject(&String.ends_with?(&1, ": "))
    |> Enum.join("\n")
    |> case do
      "" -> nil
      summary -> summary
    end
  end

  defp review_feedback_summary(_review_threads), do: nil
end
