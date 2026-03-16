defmodule SymphonyElixir.PRWatcher do
  @moduledoc """
  Policy-derived PR watcher posture.

  This module owns live GitHub review/comment ingestion posture and feedback
  synthesis so the runtime can decide whether to draft operator replies or
  automatically return a fully autonomous run to implementation.
  """

  alias SymphonyElixir.{
    AuthorProfile,
    Config,
    CredentialRegistry,
    GitHubCLIClient,
    Observability,
    PolicyPack,
    ReviewAdjudicator
  }

  @dialyzer {:nowarn_function, build_feedback_items: 3}
  @dialyzer {:nowarn_function, review_item: 4}
  @dialyzer {:nowarn_function, comment_item: 4}
  @dialyzer {:nowarn_function, merge_adjudication: 3}
  @dialyzer {:nowarn_function, draft_reply: 3}
  @dialyzer {:nowarn_function, resolution_recommendation: 3}
  @dialyzer {:nowarn_function, review_history: 2}
  @dialyzer {:nowarn_function, reconcile_posted_reply: 3}
  @dialyzer {:nowarn_function, matched_live_reply: 2}
  @dialyzer {:nowarn_function, same_feedback_claim?: 2}
  @dialyzer {:nowarn_function, normalize_feedback_signature: 1}
  @dialyzer {:nowarn_function, historical_precision_score: 1}

  @type t :: %{
          enabled: boolean(),
          mode: String.t(),
          posting_allowed: boolean(),
          draft_first_required: boolean(),
          thread_resolution_allowed: boolean(),
          external_comment_mode: String.t(),
          allowed_channels: [String.t()]
        }

  @type feedback_item :: %{
          thread_key: String.t(),
          id: String.t(),
          kind: :comment | :review,
          author: String.t() | nil,
          body: String.t() | nil,
          path: String.t() | nil,
          line: integer() | nil,
          state: String.t() | nil,
          review_decision: String.t() | nil,
          submitted_at: String.t() | nil,
          draft_state: String.t(),
          draft_reply: String.t(),
          resolution_recommendation: String.t(),
          source_class: String.t(),
          claim_type: String.t(),
          veracity_score: float(),
          reproducibility_score: float(),
          evidence_quality_score: float(),
          locality_score: float(),
          source_precision_score: float(),
          consensus_score: float(),
          consensus_state: String.t(),
          consensus_summary: String.t() | nil,
          consensus_reasons: [String.t()],
          historical_precision_score: float(),
          stagnation_score: float(),
          stagnation_state: String.t(),
          repeated_feedback_count: non_neg_integer(),
          hard_proof: boolean(),
          proof_sources: [String.t()],
          contradiction_sources: [String.t()],
          disposition: String.t(),
          actionable: boolean(),
          adjudication_summary: String.t()
        }

  @spec status(PolicyPack.t() | String.t() | atom() | nil) :: t()
  def status(pack_or_name \\ nil) do
    pack = PolicyPack.resolve(pack_or_name)
    channels = Map.get(pack, :allowed_external_channels, [])
    pr_channel? = "pull_request" in channels
    posting_allowed = PolicyPack.pr_posting_allowed?(pack)
    draft_first_required = Map.get(pack, :draft_first_required, true)
    thread_resolution_allowed = PolicyPack.thread_resolution_allowed?(pack)
    external_comment_mode = Map.get(pack, :external_comment_mode, "forbidden")

    %{
      enabled: pr_channel? or posting_allowed or external_comment_mode == "draft_only",
      mode: watcher_mode(pack, pr_channel?, posting_allowed, external_comment_mode),
      posting_allowed: posting_allowed,
      draft_first_required: draft_first_required,
      thread_resolution_allowed: thread_resolution_allowed,
      external_comment_mode: external_comment_mode,
      allowed_channels: channels
    }
  end

  @spec review_feedback(Path.t(), keyword()) :: map()
  def review_feedback(workspace, opts \\ []) when is_binary(workspace) do
    pack = PolicyPack.resolve(Keyword.get(opts, :policy_pack))
    watcher = status(pack)
    thread_states = normalize_thread_states(Keyword.get(opts, :thread_states, %{}))
    pr_url = Keyword.get(opts, :pr_url)
    prefer_cached? = Keyword.get(opts, :prefer_cached, false)

    if watcher.enabled do
      if prefer_cached? and map_size(thread_states) > 0 do
        cached_feedback(thread_states, pr_url, :preferred_cached)
      else
        github_client = Keyword.get(opts, :github_client, configured_github_client())

        github_opts =
          Keyword.merge(
            configured_github_client_opts(),
            Keyword.get(opts, :github_client_opts, [])
          )

        case review_feedback_for_source(github_client, workspace, pr_url, github_opts) do
          {:ok, feedback} ->
            items = build_feedback_items(feedback, thread_states, workspace)
            review_count = Enum.count(items, &(&1.kind == :review))
            comment_count = Enum.count(items, &(&1.kind == :comment))
            actionable_items_count = Enum.count(items, &ReviewAdjudicator.actionable_feedback?/1)
            dismissed_items_count = Enum.count(items, &(Map.get(&1, :disposition) == "dismissed"))

            Observability.emit(
              [:symphony, :review, :feedback_detected],
              %{count: length(items)},
              %{
                pr_url: Map.get(feedback, :pr_url) || Map.get(feedback, "pr_url"),
                review_count: review_count,
                comment_count: comment_count,
                actionable_items_count: actionable_items_count,
                dismissed_items_count: dismissed_items_count
              }
            )

            %{
              status: "ok",
              pr_url: Map.get(feedback, :pr_url) || Map.get(feedback, "pr_url"),
              review_decision: Map.get(feedback, :review_decision) || Map.get(feedback, "review_decision"),
              pending_drafts_count: length(items),
              actionable_items_count: actionable_items_count,
              items: items
            }

          {:error, reason} ->
            Observability.emit([:symphony, :review, :feedback_detected], %{count: 0}, %{
              pr_url: pr_url,
              outcome: "error",
              reason: inspect(reason)
            })

            cached_feedback(thread_states, pr_url, reason)
        end
      end
    else
      %{status: "disabled", pending_drafts_count: 0, items: []}
    end
  end

  defp watcher_mode(_pack, false, false, "forbidden"), do: "disabled"
  defp watcher_mode(_pack, _pr_channel?, false, "draft_only"), do: "draft_only"

  defp watcher_mode(pack, _pr_channel?, true, _external_comment_mode) do
    if Map.get(pack, :draft_first_required, true), do: "draft_first", else: "active"
  end

  @spec actionable_feedback?(map()) :: boolean()
  def actionable_feedback?(feedback) when is_map(feedback) do
    Map.get(feedback, :actionable_items_count, 0) > 0 or
      Map.get(feedback, "actionable_items_count", 0) > 0
  end

  @spec follow_up_stage(map()) :: String.t()
  def follow_up_stage(feedback) when is_map(feedback) do
    items = Map.get(feedback, :items) || Map.get(feedback, "items") || []

    if Enum.any?(items, &(Map.get(&1, :disposition) == "needs_verification")) do
      "review_verification"
    else
      "implement"
    end
  end

  defp build_feedback_items(feedback, thread_states, workspace) do
    review_decision = Map.get(feedback, :review_decision) || Map.get(feedback, "review_decision")

    review_items =
      feedback
      |> Map.get(:reviews, [])
      |> Enum.filter(&(present?(Map.get(&1, :body)) or present?(Map.get(&1, "body"))))
      |> Enum.map(&review_item(&1, thread_states, review_decision, workspace))

    comment_items =
      feedback
      |> Map.get(:comments, [])
      |> Enum.filter(&(present?(Map.get(&1, :body)) or present?(Map.get(&1, "body"))))
      |> Enum.map(&comment_item(&1, thread_states, review_decision, workspace))

    review_items ++ comment_items
  end

  defp cached_feedback(thread_states, pr_url, reason) when map_size(thread_states) > 0 do
    items =
      thread_states
      |> Enum.map(&cached_item/1)
      |> Enum.sort_by(& &1.thread_key)

    %{
      status: "cached",
      reason: inspect(reason),
      pr_url: normalize_cached_pr_url(pr_url, thread_states),
      pending_drafts_count: length(items),
      actionable_items_count: Enum.count(items, &ReviewAdjudicator.actionable_feedback?/1),
      items: items
    }
  end

  defp cached_feedback(_thread_states, _pr_url, reason) do
    %{
      status: "unavailable",
      reason: inspect(reason),
      pending_drafts_count: 0,
      actionable_items_count: 0,
      items: []
    }
  end

  defp cached_item({thread_key, persisted}) do
    kind =
      case String.split(to_string(thread_key), ":", parts: 2) do
        ["review", _] -> :review
        ["comment", _] -> :comment
        _ -> :comment
      end

    id =
      thread_key
      |> to_string()
      |> String.split(":", parts: 2)
      |> List.last()

    %{
      thread_key: to_string(thread_key),
      id: id,
      kind: kind,
      author: nil,
      body: nil,
      path: nil,
      line: nil,
      state: nil,
      review_decision: Map.get(persisted, "review_decision"),
      submitted_at: nil,
      draft_state: Map.get(persisted, "draft_state", "drafted"),
      draft_reply: Map.get(persisted, "draft_reply"),
      resolution_recommendation: Map.get(persisted, "resolution_recommendation", "keep_open_until_confirmed"),
      source_class: Map.get(persisted, "source_class", "unknown"),
      claim_type: Map.get(persisted, "claim_type", "unclear"),
      veracity_score: Map.get(persisted, "veracity_score", 0.0),
      reproducibility_score: Map.get(persisted, "reproducibility_score", 0.0),
      evidence_quality_score: Map.get(persisted, "evidence_quality_score", 0.0),
      locality_score: Map.get(persisted, "locality_score", 0.0),
      source_precision_score: Map.get(persisted, "source_precision_score", 0.0),
      consensus_score: Map.get(persisted, "consensus_score", 0.0),
      consensus_state: Map.get(persisted, "consensus_state", "unclear"),
      consensus_summary: Map.get(persisted, "consensus_summary"),
      consensus_reasons: Map.get(persisted, "consensus_reasons", []),
      historical_precision_score: Map.get(persisted, "historical_precision_score", 0.0),
      stagnation_score: Map.get(persisted, "stagnation_score", 0.0),
      stagnation_state: Map.get(persisted, "stagnation_state", "fresh"),
      repeated_feedback_count: Map.get(persisted, "repeated_feedback_count", 1),
      hard_proof: Map.get(persisted, "hard_proof", false),
      proof_sources: Map.get(persisted, "proof_sources", []),
      contradiction_sources: Map.get(persisted, "contradiction_sources", []),
      disposition: Map.get(persisted, "disposition", "dismissed"),
      actionable: Map.get(persisted, "actionable", false),
      adjudication_summary: Map.get(persisted, "adjudication_summary", "Cached review feedback.")
    }
  end

  defp review_item(review, thread_states, review_decision, workspace) do
    body = Map.get(review, :body) || Map.get(review, "body")
    state = Map.get(review, :state) || Map.get(review, "state")
    id = to_string(Map.get(review, :id) || Map.get(review, "id"))
    thread_key = "review:#{id}"
    persisted = Map.get(thread_states, thread_key, %{})

    base_item = %{
      thread_key: thread_key,
      id: id,
      kind: :review,
      author: Map.get(review, :author) || Map.get(review, "author"),
      body: body,
      path: nil,
      line: nil,
      state: state,
      review_decision: review_decision,
      submitted_at: Map.get(review, :submitted_at) || Map.get(review, "submitted_at"),
      draft_state: Map.get(persisted, "draft_state", "drafted")
    }

    merge_adjudication(base_item, persisted, workspace)
  end

  defp comment_item(comment, thread_states, review_decision, workspace) do
    body = Map.get(comment, :body) || Map.get(comment, "body")
    id = to_string(Map.get(comment, :id) || Map.get(comment, "id"))
    thread_key = "comment:#{id}"
    persisted = Map.get(thread_states, thread_key, %{})

    base_item = %{
      thread_key: thread_key,
      id: id,
      kind: :comment,
      author: Map.get(comment, :author) || Map.get(comment, "author"),
      body: body,
      path: Map.get(comment, :path) || Map.get(comment, "path"),
      line: Map.get(comment, :line) || Map.get(comment, "line"),
      state: nil,
      review_decision: review_decision,
      submitted_at: Map.get(comment, :created_at) || Map.get(comment, "created_at"),
      draft_state: Map.get(persisted, "draft_state", "drafted"),
      replies: Map.get(comment, :replies) || Map.get(comment, "replies") || []
    }

    merge_adjudication(base_item, persisted, workspace)
  end

  defp merge_adjudication(base_item, persisted, workspace) do
    history = review_history(persisted, base_item)

    adjudication =
      ReviewAdjudicator.adjudicate(
        base_item,
        workspace: workspace,
        historical_precision_score: history.historical_precision_score,
        stagnation_score: history.stagnation_score,
        stagnation_state: history.stagnation_state,
        repeated_feedback_count: history.repeated_feedback_count
      )

    base_item
    |> Map.merge(adjudication)
    |> Map.put(
      :draft_reply,
      Map.get(persisted, "draft_reply", draft_reply(base_item, adjudication, persisted))
    )
    |> Map.put(
      :resolution_recommendation,
      Map.get(
        persisted,
        "resolution_recommendation",
        resolution_recommendation(base_item, adjudication, persisted)
      )
    )
    |> reconcile_posted_reply(base_item, persisted)
  end

  defp reconcile_posted_reply(item, base_item, persisted)
       when is_map(item) and is_map(base_item) and is_map(persisted) do
    case matched_live_reply(base_item, persisted) do
      nil ->
        item

      reply ->
        item
        |> Map.put(:draft_state, "posted")
        |> Map.put(:draft_reply, Map.get(reply, :body) || Map.get(item, :draft_reply))
        |> Map.put(:posted_reply_id, Map.get(reply, :id))
        |> Map.put(:posted_reply_url, Map.get(reply, :url))
        |> Map.put(:posted_at, Map.get(reply, :updated_at) || Map.get(reply, :created_at))
        |> Map.put(:reply_refresh_needed, false)
    end
  end

  defp reconcile_posted_reply(item, _base_item, _persisted), do: item

  defp matched_live_reply(base_item, persisted) when is_map(base_item) and is_map(persisted) do
    replies = Map.get(base_item, :replies, [])
    persisted_reply_id = Map.get(persisted, "posted_reply_id")
    persisted_reply_url = normalize_pr_url(Map.get(persisted, "posted_reply_url"))

    Enum.find(replies, fn reply ->
      reply_id = Map.get(reply, :id) || Map.get(reply, "id")
      reply_url = normalize_pr_url(Map.get(reply, :url) || Map.get(reply, "url"))

      (is_binary(persisted_reply_id) and persisted_reply_id != "" and reply_id == persisted_reply_id) or
        (is_binary(persisted_reply_url) and persisted_reply_url != "" and reply_url == persisted_reply_url)
    end)
  end

  defp matched_live_reply(_base_item, _persisted), do: nil

  defp review_history(persisted, item) when is_map(persisted) and is_map(item) do
    repeated_feedback_count =
      if same_feedback_claim?(persisted, item) do
        Map.get(persisted, "repeated_feedback_count", 0) + 1
      else
        1
      end

    verification_status = Map.get(persisted, "verification_status")
    disposition = Map.get(persisted, "disposition")

    stagnation_state =
      if repeated_feedback_count >= 3 and
           verification_status in [
             "pending",
             "insufficient_evidence",
             "consensus_supported",
             "stagnant_feedback"
           ] and
           disposition in ["needs_verification", "dismissed", "deferred"] do
        "stagnant_feedback"
      else
        "fresh"
      end

    %{
      historical_precision_score: historical_precision_score(persisted),
      stagnation_score: if(stagnation_state == "stagnant_feedback", do: 0.8, else: 0.0),
      stagnation_state: stagnation_state,
      repeated_feedback_count: repeated_feedback_count
    }
  end

  defp review_history(_persisted, _item) do
    %{
      historical_precision_score: 0.5,
      stagnation_score: 0.0,
      stagnation_state: "fresh",
      repeated_feedback_count: 1
    }
  end

  defp same_feedback_claim?(persisted, item) when is_map(persisted) and is_map(item) do
    normalize_feedback_signature(persisted) == normalize_feedback_signature(item)
  end

  defp same_feedback_claim?(_persisted, _item), do: false

  defp normalize_feedback_signature(item) when is_map(item) do
    %{
      kind: Map.get(item, :kind) || Map.get(item, "kind"),
      path: Map.get(item, :path) || Map.get(item, "path"),
      line: Map.get(item, :line) || Map.get(item, "line"),
      body:
        item
        |> Map.get(:body, Map.get(item, "body"))
        |> to_string()
        |> String.trim()
    }
  end

  defp historical_precision_score(persisted) when is_map(persisted) do
    case Map.get(persisted, "verification_status") do
      status
      when status in ["verified_review_decision", "verified_scope", "verified_symbol_scope"] ->
        0.85

      "contradicted" ->
        0.20

      "stagnant_feedback" ->
        0.30

      _ ->
        case Map.get(persisted, "disposition") do
          "dismissed" -> 0.35
          "deferred" -> 0.45
          _ -> 0.50
        end
    end
  end

  defp historical_precision_score(_persisted), do: 0.50

  defp draft_reply(item, adjudication, persisted) do
    body = Map.get(item, :body)
    state = Map.get(item, :state)
    disposition = Map.get(adjudication, :disposition)
    claim_type = Map.get(adjudication, :claim_type)
    verification_status = Map.get(persisted, "verification_status")
    evidence_summary = Map.get(persisted, "evidence_summary")
    consensus_state = Map.get(adjudication, :consensus_state)

    base =
      cond do
        verification_status in [
          "verified_review_decision",
          "verified_scope",
          "verified_symbol_scope"
        ] ->
          "I verified this concern locally and it is actionable. #{to_string(evidence_summary)} I will address it in the follow-up change."

        verification_status == "contradicted" ->
          "I checked this locally and could not confirm the claim. #{to_string(evidence_summary)} If you have a narrower reproducer, I can revisit it."

        verification_status == "consensus_supported" ->
          "I found this concern plausible after a focused pass, but I still do not have hard proof to justify a code change. #{to_string(evidence_summary)}"

        disposition == "dismissed" ->
          "I reviewed this feedback and did not find enough evidence to reopen implementation yet. I can revisit it with a more specific reproducer or stronger proof."

        disposition == "deferred" ->
          "I agree the suggestion may be worthwhile, but I am deferring it for now to avoid churn on the current PR unless stronger proof or a narrower change lands."

        normalized_state(state) == "changes_requested" ->
          "I agree this needs a follow-up change. I will address it before treating the review as resolved."

        contains_nit?(body) ->
          "I agree with the nit and will adjust it in the follow-up update."

        consensus_state in ["strong_positive", "mixed_positive"] ->
          "I reviewed this feedback and it looks plausible, so I will verify it with focused checks before deciding whether to change code."

        claim_type in ["correctness_risk", "failure_handling_risk", "policy_violation"] ->
          "I reviewed this feedback and will verify the claim with focused checks before deciding whether to change code."

        true ->
          "I reviewed this feedback and will either address it in code or reply with context before resolving it."
      end

    AuthorProfile.summarize(base, :comment)
  end

  defp resolution_recommendation(item, adjudication, persisted) do
    body = Map.get(item, :body)
    state = Map.get(item, :state)
    disposition = Map.get(adjudication, :disposition)
    verification_status = Map.get(persisted, "verification_status")

    cond do
      verification_status in [
        "verified_review_decision",
        "verified_scope",
        "verified_symbol_scope"
      ] ->
        "keep_open_until_change"

      disposition == "dismissed" ->
        "keep_open_until_confirmed"

      disposition == "deferred" ->
        "keep_open_until_confirmed"

      normalized_state(state) == "changes_requested" ->
        "keep_open_until_change"

      contains_nit?(body) ->
        "resolve_after_change"

      true ->
        "keep_open_until_confirmed"
    end
  end

  defp contains_nit?(body) when is_binary(body) do
    body
    |> String.downcase()
    |> String.contains?("nit")
  end

  defp contains_nit?(_), do: false

  defp normalized_state(nil), do: nil
  defp normalized_state(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp configured_github_client do
    Application.get_env(:symphony_elixir, :pr_watcher_github_client, GitHubCLIClient)
  end

  defp configured_github_client_opts do
    Application.get_env(:symphony_elixir, :pr_watcher_github_client_opts, [])
  end

  defp review_feedback_for_source(github_client, workspace, pr_url, github_opts) do
    case github_client.review_feedback(workspace, github_opts) do
      {:ok, feedback} ->
        {:ok, feedback}

      {:error, _reason} = error ->
        if is_binary(pr_url) and pr_url != "" and
             function_exported?(github_client, :review_feedback_by_pr_url, 2) do
          github_client.review_feedback_by_pr_url(pr_url, github_opts)
        else
          error
        end
    end
  end

  defp normalize_thread_states(states) when is_map(states), do: states
  defp normalize_thread_states(_), do: %{}

  defp normalize_cached_pr_url(pr_url, thread_states) do
    normalize_pr_url(pr_url) ||
      thread_states
      |> Enum.find_value(fn {_thread_key, state} ->
        state
        |> Map.get("posted_reply_url")
        |> normalize_pr_url()
      end)
  end

  defp normalize_pr_url(nil), do: nil

  defp normalize_pr_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed |> String.split("#", parts: 2) |> hd()
    end
  end

  defp normalize_pr_url(_), do: nil

  @spec post_approved_drafts(Path.t(), String.t(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, term()}
  def post_approved_drafts(workspace, pr_url, thread_states, opts \\ [])
      when is_binary(workspace) and is_binary(pr_url) and is_map(thread_states) do
    pack = PolicyPack.resolve(Keyword.get(opts, :policy_pack))

    cond do
      not PolicyPack.external_comment_posting_allowed?(pack) ->
        {:error, {:external_comment_posting_forbidden, PolicyPack.name_string(pack)}}

      true ->
        with :ok <- ensure_comment_post_scope(opts),
             {updated_threads, posted_count, skipped_count} <-
               do_post_approved_drafts(
                 workspace,
                 pr_url,
                 thread_states,
                 Keyword.get(opts, :github_client, configured_github_client()),
                 Keyword.merge(
                   configured_github_client_opts(),
                   Keyword.get(opts, :github_client_opts, [])
                 )
               ),
             true <- posted_count > 0 do
          {:ok, updated_threads, %{posted_count: posted_count, skipped_count: skipped_count}}
        else
          false -> {:error, :no_postable_review_threads}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp do_post_approved_drafts(_workspace, pr_url, thread_states, github_client, github_opts) do
    Enum.reduce(thread_states, {thread_states, 0, 0}, fn {thread_key, thread_state}, {acc, posted, skipped} ->
      draft_state = thread_state |> Map.get("draft_state", "drafted") |> to_string()
      draft_reply = Map.get(thread_state, "draft_reply")

      cond do
        draft_state not in ["approved_to_post", "approved_to_update"] or not present?(draft_reply) ->
          {acc, posted, skipped}

        String.starts_with?(to_string(thread_key), "comment:") ->
          target_comment_id =
            if draft_state == "approved_to_update" do
              Map.get(thread_state, "posted_reply_id")
            else
              thread_key
              |> to_string()
              |> String.split(":", parts: 2)
              |> List.last()
            end

          post_result =
            if draft_state == "approved_to_update" do
              if function_exported?(github_client, :edit_review_comment_reply, 4) do
                github_client.edit_review_comment_reply(
                  pr_url,
                  target_comment_id,
                  draft_reply,
                  github_opts
                )
              else
                {:error, :review_reply_update_unsupported}
              end
            else
              github_client.post_review_comment_reply(
                pr_url,
                target_comment_id,
                draft_reply,
                github_opts
              )
            end

          case post_result do
            {:ok, reply} ->
              updated =
                thread_state
                |> Map.put("draft_state", "posted")
                |> Map.put(
                  "posted_at",
                  DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
                )
                |> Map.put("posted_reply_id", Map.get(reply, :id))
                |> Map.put("posted_reply_url", Map.get(reply, :url))
                |> Map.put("reply_refresh_needed", false)

              {Map.put(acc, thread_key, updated), posted + 1, skipped}

            {:error, _reason} ->
              {acc, posted, skipped + 1}
          end

        true ->
          {acc, posted, skipped + 1}
      end
    end)
  end

  defp ensure_comment_post_scope(opts) do
    CredentialRegistry.allow?(
      "github",
      "comment_post",
      policy_pack: Keyword.get(opts, :policy_pack),
      company_name: Keyword.get(opts, :company_name) || Config.company_name(),
      repo_url: Keyword.get(opts, :repo_url) || Config.company_repo_url()
    )
  end
end
