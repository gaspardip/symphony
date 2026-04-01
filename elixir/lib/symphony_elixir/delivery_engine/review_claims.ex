defmodule SymphonyElixir.DeliveryEngine.ReviewClaims do
  @moduledoc """
  Review claim/thread management extracted from DeliveryEngine.

  Handles claim syncing, autonomous review posting, and merge readiness feedback.
  """

  # credo:disable-for-this-file

  alias SymphonyElixir.Config
  alias SymphonyElixir.PolicyPack
  alias SymphonyElixir.PRWatcher
  alias SymphonyElixir.PullRequestManager
  alias SymphonyElixir.ReviewEvidenceCollector
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.TurnResult

  @publish_followup_stage "merge_readiness"

  # ---------------------------------------------------------------------------
  # Claim sync cluster
  # ---------------------------------------------------------------------------

  @spec sync_review_claims_into_threads(map(), map()) :: map()
  def sync_review_claims_into_threads(review_threads, review_claims)
      when is_map(review_threads) and is_map(review_claims) do
    Enum.reduce(review_claims, review_threads, fn {thread_key, claim}, acc ->
      reply_plan = ReviewEvidenceCollector.reply_plan(claim)

      Map.update(acc, thread_key, %{}, fn thread_state ->
        draft_state = Map.get(thread_state, "draft_state", "drafted")

        thread_state
        |> Map.put("disposition", Map.get(claim, "disposition"))
        |> Map.put("actionable", Map.get(claim, "actionable", false))
        |> Map.put("hard_proof", Map.get(claim, "hard_proof", false))
        |> Map.put("proof_sources", Map.get(claim, "proof_sources", []))
        |> Map.put("contradiction_sources", Map.get(claim, "contradiction_sources", []))
        |> Map.put("consensus_score", Map.get(claim, "consensus_score"))
        |> Map.put("consensus_state", Map.get(claim, "consensus_state"))
        |> Map.put("consensus_summary", Map.get(claim, "consensus_summary"))
        |> Map.put("consensus_reasons", Map.get(claim, "consensus_reasons", []))
        |> Map.put("historical_precision_score", Map.get(claim, "historical_precision_score"))
        |> Map.put("stagnation_score", Map.get(claim, "stagnation_score"))
        |> Map.put("stagnation_state", Map.get(claim, "stagnation_state"))
        |> Map.put("repeated_feedback_count", Map.get(claim, "repeated_feedback_count", 1))
        |> Map.put("verification_status", Map.get(claim, "verification_status"))
        |> Map.put("implementation_status", Map.get(claim, "implementation_status"))
        |> Map.put("addressed_summary", Map.get(claim, "addressed_summary"))
        |> Map.put("verification_attempts", Map.get(claim, "verification_attempts", 0))
        |> Map.put("evidence_refs", Map.get(claim, "evidence_refs", []))
        |> Map.put("evidence_summary", Map.get(claim, "evidence_summary"))
        |> maybe_put_reply_plan(draft_state, reply_plan)
      end)
    end)
  end

  def sync_review_claims_into_threads(review_threads, _review_claims), do: review_threads

  @spec claim_pending_review_fix?(map()) :: boolean()
  def claim_pending_review_fix?(claim) when is_map(claim) do
    claim_value(claim, :disposition) == "accepted" and
      claim_value(claim, :actionable, false) and
      claim_value(claim, :implementation_status) != "addressed"
  end

  @spec advance_review_claims_after_turn(map(), list(), TurnResult.t()) :: map()
  def advance_review_claims_after_turn(
        review_claims,
        focused_claims,
        %TurnResult{} = turn_result
      )
      when is_map(review_claims) and is_list(focused_claims) do
    touched_paths =
      turn_result.files_touched
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_review_claim_path/1)
      |> MapSet.new()

    resolved_without_edit? =
      MapSet.size(touched_paths) == 0 and resolved_review_claim_summary?(turn_result.summary)

    if MapSet.size(touched_paths) == 0 and not resolved_without_edit? do
      review_claims
    else
      Enum.reduce(focused_claims, review_claims, fn {thread_key, claim}, acc ->
        claim_path = claim_value(claim, :path)

        if (is_binary(claim_path) and review_claim_touched?(claim_path, touched_paths)) or
             resolved_without_edit? do
          Map.update(acc, thread_key, claim, fn existing ->
            existing
            |> Map.put("implementation_status", "addressed")
            |> Map.put("actionable", false)
            |> Map.put("addressed_summary", turn_result.summary)
          end)
        else
          acc
        end
      end)
    end
  end

  @spec resolved_review_claim_summary?(term()) :: boolean()
  def resolved_review_claim_summary?(summary) when is_binary(summary) do
    normalized = String.downcase(summary)

    String.contains?(normalized, "already resolved") or
      String.contains?(normalized, "verified and retained") or
      String.contains?(normalized, "verified the scoped review claim")
  end

  def resolved_review_claim_summary?(_summary), do: false

  @spec review_claim_touched?(term(), list()) :: boolean()
  def review_claim_touched?(claim_path, touched_paths)
      when is_binary(claim_path) and is_struct(touched_paths, MapSet) do
    normalized_claim_path = normalize_review_claim_path(claim_path)

    Enum.any?(touched_paths, fn touched_path ->
      touched_path == normalized_claim_path or
        String.ends_with?(touched_path, "/" <> normalized_claim_path) or
        String.ends_with?(normalized_claim_path, "/" <> touched_path)
    end)
  end

  def review_claim_touched?(_claim_path, _touched_paths), do: false

  @spec normalize_review_claim_path(term()) :: term()
  def normalize_review_claim_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
    |> case do
      "" = blank ->
        blank

      normalized ->
        workspace_root = Config.workspace_root() |> String.replace("\\", "/")

        cond do
          String.starts_with?(normalized, workspace_root <> "/") ->
            String.replace_prefix(normalized, workspace_root <> "/", "")

          true ->
            normalized
        end
    end
  end

  def normalize_review_claim_path(path), do: path

  @spec maybe_put_reply_plan(map(), String.t(), term()) :: map()
  def maybe_put_reply_plan(thread_state, draft_state, _reply_plan)
      when draft_state == "approved_to_post" do
    thread_state
  end

  def maybe_put_reply_plan(thread_state, "posted", reply_plan) do
    next_reply = Map.get(reply_plan, :draft_reply)
    existing_reply = Map.get(thread_state, "draft_reply")

    if present_review_thread_reply?(next_reply) and
         String.trim(to_string(next_reply)) != String.trim(to_string(existing_reply)) do
      thread_state
      |> Map.put("draft_reply", next_reply)
      |> Map.put("resolution_recommendation", Map.get(reply_plan, :resolution_recommendation))
      |> Map.put("reply_refresh_needed", true)
    else
      thread_state
      |> Map.put("resolution_recommendation", Map.get(reply_plan, :resolution_recommendation))
    end
  end

  def maybe_put_reply_plan(thread_state, _draft_state, reply_plan) do
    thread_state
    |> Map.put("draft_reply", Map.get(reply_plan, :draft_reply))
    |> Map.put("resolution_recommendation", Map.get(reply_plan, :resolution_recommendation))
  end

  # ---------------------------------------------------------------------------
  # Autonomous review posting
  # ---------------------------------------------------------------------------

  @spec maybe_post_autonomous_review_replies(map(), String.t(), String.t() | nil, map(), keyword()) :: map()
  def maybe_post_autonomous_review_replies(review_threads, workspace, pr_url, state, opts)
      when is_map(review_threads) and is_binary(workspace) and is_map(state) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack) || Config.policy_pack_name())
    prepared_threads = promote_autonomous_review_drafts(review_threads, pack)

    cond do
      not PolicyPack.external_comment_posting_allowed?(pack) ->
        prepared_threads

      not is_binary(pr_url) or String.trim(pr_url) == "" ->
        prepared_threads

      not has_postable_review_drafts?(prepared_threads) ->
        prepared_threads

      true ->
        watcher_opts =
          [policy_pack: pack, repo_url: Map.get(state, :repo_url)]
          |> maybe_put_opt(:github_client, Keyword.get(opts, :github_client))
          |> maybe_put_opt(:github_client_opts, Keyword.get(opts, :github_client_opts))

        case PRWatcher.post_approved_drafts(workspace, pr_url, prepared_threads, watcher_opts) do
          {:ok, updated_threads, _stats} -> updated_threads
          {:error, :no_postable_review_threads} -> prepared_threads
          {:error, _reason} -> prepared_threads
        end
    end
  end

  def maybe_post_autonomous_review_replies(review_threads, _workspace, _pr_url, _state, _opts),
    do: review_threads

  @spec promote_autonomous_review_drafts(map(), term()) :: map()
  def promote_autonomous_review_drafts(review_threads, %PolicyPack{})
      when is_map(review_threads) do
    Enum.reduce(review_threads, review_threads, fn {thread_key, thread_state}, acc ->
      cond do
        autonomous_review_postable_thread?(thread_key, thread_state) ->
          Map.update!(acc, thread_key, &Map.put(&1, "draft_state", "approved_to_post"))

        autonomous_review_refreshable_thread?(thread_key, thread_state) ->
          Map.update!(acc, thread_key, &Map.put(&1, "draft_state", "approved_to_update"))

        true ->
          acc
      end
    end)
  end

  @spec autonomous_review_postable_thread?(term(), map()) :: boolean()
  def autonomous_review_postable_thread?(thread_key, thread_state)
      when is_map(thread_state) do
    draft_state = Map.get(thread_state, "draft_state", "drafted")
    disposition = Map.get(thread_state, "disposition")
    implementation_status = Map.get(thread_state, "implementation_status")
    verification_status = Map.get(thread_state, "verification_status")

    draft_state == "drafted" and
      present_review_thread_reply?(Map.get(thread_state, "draft_reply")) and
      String.starts_with?(to_string(thread_key), "comment:") and
      (implementation_status == "addressed" or
         (disposition == "dismissed" and verification_status == "contradicted"))
  end

  def autonomous_review_postable_thread?(_thread_key, _thread_state), do: false

  @spec autonomous_review_refreshable_thread?(term(), map()) :: boolean()
  def autonomous_review_refreshable_thread?(thread_key, thread_state)
      when is_map(thread_state) do
    Map.get(thread_state, "draft_state") == "posted" and
      Map.get(thread_state, "reply_refresh_needed") == true and
      is_binary(Map.get(thread_state, "posted_reply_id")) and
      present_review_thread_reply?(Map.get(thread_state, "draft_reply")) and
      String.starts_with?(to_string(thread_key), "comment:")
  end

  def autonomous_review_refreshable_thread?(_thread_key, _thread_state), do: false

  @spec has_postable_review_drafts?(term()) :: boolean()
  def has_postable_review_drafts?(review_threads) when is_map(review_threads) do
    Enum.any?(review_threads, fn {thread_key, thread_state} ->
      String.starts_with?(to_string(thread_key), "comment:") and
        Map.get(thread_state, "draft_state") in ["approved_to_post", "approved_to_update"] and
        present_review_thread_reply?(Map.get(thread_state, "draft_reply"))
    end)
  end

  def has_postable_review_drafts?(_review_threads), do: false

  @spec finalize_published_review_threads(term()) :: map()
  def finalize_published_review_threads(review_threads) when is_map(review_threads) do
    Enum.reduce(review_threads, review_threads, fn {thread_key, thread_state}, acc ->
      updated = finalize_published_review_thread(thread_state)

      if String.starts_with?(to_string(thread_key), "comment:") and updated != thread_state do
        Map.put(acc, thread_key, updated)
      else
        acc
      end
    end)
  end

  def finalize_published_review_threads(review_threads), do: review_threads

  @spec finalize_published_review_thread(term()) :: map()
  def finalize_published_review_thread(thread_state) when is_map(thread_state) do
    draft_reply = Map.get(thread_state, "draft_reply")

    cond do
      Map.get(thread_state, "implementation_status") != "addressed" ->
        thread_state

      not is_binary(draft_reply) ->
        thread_state

      true ->
        updated_reply =
          String.replace(
            draft_reply,
            "I addressed this concern locally and will include it in the next branch update.",
            "I addressed this concern locally and it is now included on the branch."
          )

        cond do
          updated_reply == draft_reply ->
            thread_state

          Map.get(thread_state, "draft_state") == "posted" ->
            thread_state
            |> Map.put("draft_reply", updated_reply)
            |> Map.put("reply_refresh_needed", true)
            |> Map.put("resolution_recommendation", "resolve_after_change")

          true ->
            thread_state
            |> Map.put("draft_reply", updated_reply)
            |> Map.put("resolution_recommendation", "resolve_after_change")
        end
    end
  end

  def finalize_published_review_thread(thread_state), do: thread_state

  @spec maybe_resolve_autonomous_review_threads(map(), String.t(), String.t() | nil, map(), keyword()) :: map()
  def maybe_resolve_autonomous_review_threads(review_threads, workspace, pr_url, state, opts)
      when is_map(review_threads) and is_binary(workspace) and is_map(state) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack) || Config.policy_pack_name())

    cond do
      not PolicyPack.thread_resolution_allowed?(pack) ->
        review_threads

      not is_binary(pr_url) or String.trim(pr_url) == "" ->
        review_threads

      not has_resolvable_review_threads?(review_threads) ->
        review_threads

      true ->
        watcher_opts =
          [policy_pack: pack, repo_url: Map.get(state, :repo_url)]
          |> maybe_put_opt(:github_client, Keyword.get(opts, :github_client))
          |> maybe_put_opt(:github_client_opts, Keyword.get(opts, :github_client_opts))

        case PRWatcher.resolve_posted_threads(pr_url, review_threads, watcher_opts) do
          {:ok, updated_threads, _stats} -> updated_threads
          {:error, :no_resolvable_review_threads} -> review_threads
          {:error, _reason} -> review_threads
        end
    end
  end

  def maybe_resolve_autonomous_review_threads(
        review_threads,
        _workspace,
        _pr_url,
        _state,
        _opts
      ),
      do: review_threads

  @spec has_resolvable_review_threads?(term()) :: boolean()
  def has_resolvable_review_threads?(review_threads) when is_map(review_threads) do
    Enum.any?(review_threads, fn {thread_key, thread_state} ->
      String.starts_with?(to_string(thread_key), "comment:") and
        Map.get(thread_state, "draft_state") == "posted" and
        resolvable_review_thread_state?(thread_state) and
        Map.get(thread_state, "resolution_state") != "resolved"
    end)
  end

  @spec resolvable_review_thread_state?(term()) :: boolean()
  def resolvable_review_thread_state?(thread_state) when is_map(thread_state) do
    case {
      Map.get(thread_state, "resolution_recommendation"),
      Map.get(thread_state, "implementation_status"),
      Map.get(thread_state, "verification_status")
    } do
      {"resolve_after_change", "addressed", _} -> true
      {"resolve_after_contradiction", _, "contradicted"} -> true
      _ -> false
    end
  end

  def resolvable_review_thread_state?(_thread_state), do: false

  @spec present_review_thread_reply?(term()) :: boolean()
  def present_review_thread_reply?(value) when is_binary(value), do: String.trim(value) != ""
  def present_review_thread_reply?(_value), do: false

  # ---------------------------------------------------------------------------
  # Merge readiness feedback
  # ---------------------------------------------------------------------------

  @spec maybe_refresh_preflight_review_claims(map(), String.t()) :: map()
  def maybe_refresh_preflight_review_claims(review_claims, workspace)
      when is_map(review_claims) and is_binary(workspace) do
    pending_verification_claims =
      review_claims
      |> Enum.filter(fn {_thread_key, claim} ->
        claim_value(claim, :implementation_status) != "addressed" and
          claim_value(claim, :disposition) == "needs_verification"
      end)
      |> Map.new()

    if map_size(pending_verification_claims) == 0 do
      review_claims
    else
      {refreshed_claims, _stats} =
        ReviewEvidenceCollector.collect(pending_verification_claims, workspace)

      Map.merge(review_claims, refreshed_claims)
    end
  end

  def maybe_refresh_preflight_review_claims(review_claims, _workspace), do: review_claims

  @spec maybe_maintain_merge_readiness(String.t(), map(), map(), map(), keyword()) :: map()
  def maybe_maintain_merge_readiness(workspace, issue, state, inspection, opts)
      when is_binary(workspace) and is_map(issue) and is_map(state) and is_map(inspection) do
    if merge_readiness_maintenance_needed?(state, inspection) do
      reconciled_state = maybe_reconcile_live_review_feedback(state, workspace, opts)

      with {:ok, pr_url, pr_body_validation} <-
             maybe_refresh_merge_readiness_pr_body(
               workspace,
               issue,
               reconciled_state,
               inspection,
               opts
             ) do
        updated_review_threads =
          reconciled_state
          |> Map.get(:review_threads, %{})
          |> finalize_published_review_threads()
          |> maybe_post_autonomous_review_replies(workspace, pr_url, reconciled_state, opts)
          |> maybe_resolve_autonomous_review_threads(workspace, pr_url, reconciled_state, opts)

        updated_state =
          reconciled_state
          |> Map.put(:pr_url, pr_url || Map.get(reconciled_state, :pr_url))
          |> Map.put(:review_threads, updated_review_threads)
          |> Map.put(
            :last_merge_readiness,
            merge_readiness_summary(pr_body_validation, updated_review_threads)
          )
          |> maybe_put_pr_body_validation(pr_body_validation)
          |> Map.update(:resume_context, %{}, fn context ->
            context
            |> Map.put(:review_feedback_summary, review_feedback_summary(updated_review_threads))
            |> maybe_put_review_feedback_pr_url(pr_url)
          end)

        if updated_state != state and Keyword.get(opts, :persist_merge_readiness, true) do
          {:ok, persisted_state} =
            RunStateStore.update(workspace, fn _persisted -> updated_state end)

          {:ok, persisted_state}
        else
          {:ok, updated_state}
        end
      end
    else
      {:ok, state}
    end
  end

  def maybe_maintain_merge_readiness(_workspace, _issue, state, _inspection, _opts),
    do: {:ok, state}

  @spec merge_readiness_maintenance_needed?(map(), map()) :: boolean()
  def merge_readiness_maintenance_needed?(state, inspection)
      when is_map(state) and is_map(inspection) do
    pr_url = Map.get(state, :pr_url) || Map.get(inspection, :pr_url)
    review_threads = Map.get(state, :review_threads, %{})

    is_binary(pr_url) and String.trim(pr_url) != "" and
      (map_size(review_threads) > 0 or pr_body_refresh_needed?(state))
  end

  def merge_readiness_maintenance_needed?(_state, _inspection), do: false

  @spec pr_body_refresh_needed?(map()) :: boolean()
  def pr_body_refresh_needed?(state) when is_map(state) do
    validation = Map.get(state, :last_pr_body_validation) || %{}
    stage = Map.get(state, :stage)

    validation_status =
      validation
      |> then(fn
        %{} = value -> Map.get(value, :status) || Map.get(value, "status")
        _ -> nil
      end)
      |> to_string()

    check_name =
      state
      |> Map.get(:last_ci_failure)
      |> Kernel.||(%{})
      |> Map.get(:check_name)
      |> to_string()

    (stage == @publish_followup_stage and validation_status == "") or
      validation_status in ["failed", "error"] or
      check_name in ["validate-pr-description", "pr-description-lint"]
  end

  @spec maybe_refresh_merge_readiness_pr_body(String.t(), map(), map(), map(), keyword()) :: map()
  def maybe_refresh_merge_readiness_pr_body(workspace, issue, state, inspection, opts)
      when is_binary(workspace) and is_map(state) and is_map(inspection) do
    pr_url = Map.get(state, :pr_url) || Map.get(inspection, :pr_url)

    if pr_body_refresh_needed?(state) and merge_readiness_pr_body_supported?(workspace) do
      case PullRequestManager.ensure_pull_request(workspace, issue, state, opts) do
        {:ok, pr} ->
          {:ok, Map.get(pr, :url) || pr_url, Map.get(pr, :body_validation)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, pr_url, Map.get(state, :last_pr_body_validation)}
    end
  end

  def maybe_refresh_merge_readiness_pr_body(_workspace, _issue, state, inspection, _opts) do
    {:ok, Map.get(state, :pr_url) || Map.get(inspection, :pr_url), Map.get(state, :last_pr_body_validation)}
  end

  @spec maybe_put_pr_body_validation(map(), term()) :: map()
  def maybe_put_pr_body_validation(state, nil), do: state
  def maybe_put_pr_body_validation(state, validation), do: Map.put(state, :last_pr_body_validation, validation)

  @spec merge_readiness_pr_body_supported?(String.t()) :: boolean()
  def merge_readiness_pr_body_supported?(workspace) when is_binary(workspace) do
    File.exists?(Path.join(workspace, ".github/pull_request_template.md")) and
      File.exists?(Path.join([workspace, "elixir", "lib", "mix", "tasks", "pr_body.check.ex"]))
  end

  @spec maybe_put_review_feedback_pr_url(map(), term()) :: map()
  def maybe_put_review_feedback_pr_url(context, pr_url) when is_map(context) and is_binary(pr_url),
    do: Map.put(context, :review_feedback_pr_url, pr_url)

  def maybe_put_review_feedback_pr_url(context, _pr_url), do: context

  @spec merge_readiness_summary(term(), map()) :: String.t()
  def merge_readiness_summary(pr_body_validation, review_threads) do
    %{
      checked_at: SymphonyElixir.Util.now_iso8601(),
      pr_body_validation_status: merge_readiness_validation_status(pr_body_validation),
      posted_review_threads:
        Enum.count(review_threads, fn {_thread_key, thread_state} ->
          Map.get(thread_state, "draft_state") == "posted"
        end),
      pending_reply_refreshes:
        Enum.count(review_threads, fn {_thread_key, thread_state} ->
          Map.get(thread_state, "reply_refresh_needed") == true
        end),
      resolved_review_threads:
        Enum.count(review_threads, fn {_thread_key, thread_state} ->
          Map.get(thread_state, "resolution_state") == "resolved"
        end)
    }
  end

  @spec merge_readiness_validation_status(term()) :: String.t()
  def merge_readiness_validation_status(nil), do: "unchanged"
  def merge_readiness_validation_status(%{status: status}) when is_binary(status), do: status
  def merge_readiness_validation_status(%{"status" => status}) when is_binary(status), do: status
  def merge_readiness_validation_status(_validation), do: "unknown"

  @spec maybe_persist_reconciled_review_feedback(map(), String.t(), keyword()) :: map()
  def maybe_persist_reconciled_review_feedback(state, workspace, opts)
      when is_map(state) and is_binary(workspace) do
    reconciled_state = maybe_reconcile_live_review_feedback(state, workspace, opts)

    if review_feedback_state_changed?(state, reconciled_state) do
      {:ok, persisted_state} =
        RunStateStore.update(workspace, fn persisted ->
          persisted
          |> Map.put(:review_claims, Map.get(reconciled_state, :review_claims, %{}))
          |> Map.put(:review_threads, Map.get(reconciled_state, :review_threads, %{}))
          |> Map.put(:last_review_decision, Map.get(reconciled_state, :last_review_decision))
          |> Map.update(:resume_context, %{}, fn context ->
            context
            |> Map.put(
              :review_feedback_summary,
              review_feedback_summary(Map.get(reconciled_state, :review_threads, %{}))
            )
            |> Map.put(
              :review_claim_summary,
              ReviewEvidenceCollector.summary(Map.get(reconciled_state, :review_claims, %{}))
            )
            |> Map.put(:review_feedback_pr_url, Map.get(reconciled_state, :pr_url))
          end)
        end)

      persisted_state
    else
      state
    end
  end

  def maybe_persist_reconciled_review_feedback(state, _workspace, _opts), do: state

  @spec review_feedback_state_changed?(map(), map()) :: boolean()
  def review_feedback_state_changed?(state, reconciled_state)
      when is_map(state) and is_map(reconciled_state) do
    Map.get(state, :review_threads, %{}) != Map.get(reconciled_state, :review_threads, %{}) or
      Map.get(state, :review_claims, %{}) != Map.get(reconciled_state, :review_claims, %{}) or
      Map.get(state, :last_review_decision) != Map.get(reconciled_state, :last_review_decision)
  end

  def review_feedback_state_changed?(_state, _reconciled_state), do: false

  @spec maybe_reconcile_live_review_feedback(map(), String.t(), keyword()) :: map()
  def maybe_reconcile_live_review_feedback(state, workspace, opts)
      when is_map(state) and is_binary(workspace) do
    pr_url = Map.get(state, :pr_url)
    review_threads = Map.get(state, :review_threads, %{})
    review_claims = Map.get(state, :review_claims, %{})

    cond do
      not is_binary(pr_url) or String.trim(pr_url) == "" ->
        state

      map_size(review_threads) == 0 and map_size(review_claims) == 0 ->
        state

      true ->
        watcher_opts =
          [
            policy_pack: Map.get(state, :policy_pack) || Config.policy_pack_name(),
            pr_url: pr_url,
            thread_states: review_threads
          ]
          |> maybe_put_opt(:github_client, Keyword.get(opts, :github_client))
          |> maybe_put_opt(:github_client_opts, Keyword.get(opts, :github_client_opts))

        case PRWatcher.review_feedback(workspace, watcher_opts) do
          %{status: "ok", items: items} = feedback when is_list(items) ->
            if items == [] do
              state
            else
              state
              |> Map.put(:review_claims, refreshed_review_claims(items, review_claims, pr_url))
              |> Map.put(:review_threads, refreshed_review_threads(items, review_threads, pr_url))
              |> Map.put(:last_review_decision, Map.get(feedback, :review_decision))
            end

          _ ->
            state
        end
    end
  end

  def maybe_reconcile_live_review_feedback(state, _workspace, _opts), do: state

  @spec refreshed_review_claims(term(), map(), String.t() | nil) :: map()
  def refreshed_review_claims(items, persisted_claims, pr_url)
      when is_list(items) and is_map(persisted_claims) do
    Enum.reduce(items, persisted_claims, fn item, acc ->
      case Map.get(item, :thread_key) do
        thread_key when is_binary(thread_key) ->
          persisted = Map.get(acc, thread_key, %{})

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
            "verification_status" => refreshed_review_claim_verification_status(persisted, item),
            "verification_attempts" => Map.get(persisted, "verification_attempts", 0),
            "evidence_refs" => Map.get(persisted, "evidence_refs", []),
            "evidence_summary" => Map.get(persisted, "evidence_summary"),
            "implementation_status" => Map.get(persisted, "implementation_status"),
            "addressed_summary" => Map.get(persisted, "addressed_summary"),
            "pr_url" => pr_url
          }

          Map.put(acc, thread_key, claim_state)

        _ ->
          acc
      end
    end)
  end

  def refreshed_review_claims(_items, persisted_claims, _pr_url), do: persisted_claims

  @spec refreshed_review_threads(term(), map(), String.t() | nil) :: map()
  def refreshed_review_threads(items, persisted_threads, pr_url)
      when is_list(items) and is_map(persisted_threads) do
    Enum.reduce(items, persisted_threads, fn item, acc ->
      case Map.get(item, :thread_key) do
        thread_key when is_binary(thread_key) ->
          Map.put(
            acc,
            thread_key,
            refreshed_review_thread_state(item, Map.get(persisted_threads, thread_key, %{}), pr_url)
          )

        _ ->
          acc
      end
    end)
  end

  def refreshed_review_threads(_items, persisted_threads, _pr_url), do: persisted_threads

  @spec refreshed_review_thread_state(map(), map(), String.t() | nil) :: map()
  def refreshed_review_thread_state(item, persisted_thread, pr_url)
      when is_map(item) and is_map(persisted_thread) do
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
      "verification_status" => Map.get(item, :verification_status),
      "implementation_status" => Map.get(item, :implementation_status),
      "addressed_summary" => Map.get(item, :addressed_summary),
      "posted_reply_id" => Map.get(item, :posted_reply_id),
      "posted_reply_url" => Map.get(item, :posted_reply_url),
      "posted_at" => Map.get(item, :posted_at),
      "reply_refresh_needed" => Map.get(item, :reply_refresh_needed, false),
      "resolution_state" => Map.get(persisted_thread, "resolution_state"),
      "resolved_at" => Map.get(persisted_thread, "resolved_at"),
      "pr_url" => pr_url
    }
  end

  @spec refreshed_review_claim_verification_status(term(), map()) :: String.t()
  def refreshed_review_claim_verification_status(persisted, item)
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

  def refreshed_review_claim_verification_status(_persisted, _item), do: "not_needed"

  @spec claim_priority_bucket(term()) :: non_neg_integer()
  def claim_priority_bucket("security_risk"), do: 0
  def claim_priority_bucket("critical_bug"), do: 0
  def claim_priority_bucket("correctness_risk"), do: 1
  def claim_priority_bucket("failure_handling_risk"), do: 2
  def claim_priority_bucket("maintainability"), do: 3
  def claim_priority_bucket(_claim_type), do: 4

  @spec focused_review_claim_block(list(), map()) :: String.t()
  def focused_review_claim_block(focused_claims, all_review_claims)
      when is_list(focused_claims) and is_map(all_review_claims) do
    remaining_count =
      max(0, accepted_actionable_claim_count(all_review_claims) - length(focused_claims))

    block =
      focused_claims
      |> Enum.map(fn {_thread_key, claim} ->
        location =
          case {Map.get(claim, "path"), Map.get(claim, "line")} do
            {path, line} when is_binary(path) and is_integer(line) -> "#{path}:#{line}"
            {path, _line} when is_binary(path) -> path
            _ -> "review feedback"
          end

        detail =
          claim
          |> Map.get("body")
          |> summarized_text(90)

        "- #{Map.get(claim, "claim_type") || "review_claim"} #{location}: #{detail}"
      end)
      |> Enum.join("\n")

    if remaining_count > 0 do
      block <> "\n- Additional verified claims remain after this batch: #{remaining_count}"
    else
      block
    end
  end

  def focused_review_claims(review_claims, limit \\ 2)

  @spec focused_review_claims(map(), non_neg_integer()) :: list()
  def focused_review_claims(review_claims, limit)
      when is_map(review_claims) and is_integer(limit) and limit > 0 do
    review_claims
    |> Enum.sort_by(fn {thread_key, claim} ->
      {claim_priority_bucket(Map.get(claim, "claim_type")), Map.get(claim, "path") || "", Map.get(claim, "line") || 0, thread_key}
    end)
    |> Enum.filter(fn {_thread_key, claim} -> claim_pending_review_fix?(claim) end)
    |> Enum.take(limit)
  end

  @spec accepted_actionable_claim_count(map()) :: non_neg_integer()
  def accepted_actionable_claim_count(review_claims) when is_map(review_claims) do
    review_claims
    |> Enum.count(fn {_thread_key, claim} -> claim_pending_review_fix?(claim) end)
  end

  @spec review_feedback_summary(term()) :: String.t() | nil
  def review_feedback_summary(review_threads) when is_map(review_threads) do
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
        |> summarized_text(280)

      "- #{kind}#{location}: #{body}"
    end)
    |> Enum.reject(&String.ends_with?(&1, ": "))
    |> Enum.join("\n")
    |> case do
      "" -> nil
      summary -> summary
    end
  end

  def review_feedback_summary(_review_threads), do: nil

  @spec default_review_feedback_summary(map(), list()) :: String.t() | nil
  def default_review_feedback_summary(state, []),
    do: review_feedback_summary(Map.get(state, :review_threads, %{}))

  def default_review_feedback_summary(_state, _focused_claims), do: nil

  @spec default_review_claim_summary(map(), list()) :: String.t() | nil
  def default_review_claim_summary(state, []),
    do: ReviewEvidenceCollector.summary(Map.get(state, :review_claims, %{}))

  def default_review_claim_summary(_state, focused_claims) do
    actionable_review_claim_summary_from_entries(focused_claims)
  end

  @spec default_next_objective(map(), list()) :: String.t()
  def default_next_objective(_state, []),
    do: "Advance the diff so it is ready for runtime validation without running the repo contract yourself."

  def default_next_objective(state, focused_claims) do
    focused_review_next_objective(focused_claims, Map.get(state, :review_claims, %{}))
  end

  @spec actionable_review_claim_summary(map()) :: String.t() | nil
  def actionable_review_claim_summary(review_claims) when is_map(review_claims) do
    entries = focused_review_claims(review_claims, 6)

    case actionable_review_claim_summary_from_entries(entries) do
      nil -> ReviewEvidenceCollector.summary(review_claims)
      text -> text
    end
  end

  @spec actionable_review_claim_summary_from_entries(list()) :: String.t() | nil
  def actionable_review_claim_summary_from_entries(entries) when is_list(entries) do
    entries
    |> Enum.map(fn {_thread_key, claim} ->
      claim_type = Map.get(claim, "claim_type") || "review_claim"
      verification_status = Map.get(claim, "verification_status") || "verified"

      location =
        case {Map.get(claim, "path"), Map.get(claim, "line")} do
          {path, line} when is_binary(path) and is_integer(line) -> "#{path}:#{line}"
          {path, _line} when is_binary(path) -> path
          _ -> "review feedback"
        end

      "- #{claim_type} #{location}: #{verification_status}"
    end)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  @spec accepted_review_next_objective(map()) :: String.t()
  def accepted_review_next_objective(review_claims) when is_map(review_claims) do
    focused_review_next_objective(focused_review_claims(review_claims), review_claims)
  end

  @spec focused_review_next_objective(list(), map()) :: String.t()
  def focused_review_next_objective(focused_claims, all_review_claims)
      when is_list(focused_claims) and is_map(all_review_claims) do
    files =
      focused_claims
      |> Enum.reduce([], fn {_thread_key, claim}, acc ->
        case Map.get(claim, "path") do
          path when is_binary(path) and path != "" -> [path | acc]
          _ -> acc
        end
      end)
      |> Enum.uniq()
      |> Enum.reverse()

    remaining_count =
      max(0, accepted_actionable_claim_count(all_review_claims) - length(focused_claims))

    case files do
      [] ->
        "Address the verified PR review claims without rerunning the full repo validation in implement."

      _ ->
        suffix =
          if remaining_count > 0 do
            " If you finish this batch, report `needs_another_turn=true` so Symphony can continue with the remaining #{remaining_count} verified claim(s)."
          else
            ""
          end

        "Address only the verified PR review claims in #{Enum.join(files, ", ")}. Do not rescan unrelated files or docs, and stop once those scoped fixes are in place." <>
          suffix
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers (duplicated from DeliveryEngine to avoid circular deps)
  # ---------------------------------------------------------------------------

  defp claim_value(claim, key, default \\ nil) when is_map(claim) and is_atom(key) do
    Map.get(claim, key, Map.get(claim, Atom.to_string(key), default))
  end

  defp summarized_text(nil, _limit), do: nil

  defp summarized_text(value, limit) when is_integer(limit) and limit > 0 do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.slice(text, 0, limit)
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
