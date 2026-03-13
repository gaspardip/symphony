defmodule SymphonyElixir.ReviewEvidenceCollector do
  @moduledoc """
  Cheap local proof collection for persisted PR review claims.

  This module intentionally stays lightweight. It verifies review metadata
  against the local workspace, confirms obvious contradictions, and upgrades
  some `needs_verification` claims when the review decision or scoped file
  references provide enough evidence to justify an implementation follow-up.
  """

  @type claim :: map()

  @spec collect(map(), Path.t()) :: {map(), map()}
  def collect(review_claims, workspace) when is_map(review_claims) and is_binary(workspace) do
    Enum.reduce(review_claims, {%{}, stats_template()}, fn {thread_key, claim}, {acc, stats} ->
      updated_claim = collect_claim(Map.put_new(claim, "thread_key", to_string(thread_key)), workspace)

      {
        Map.put(acc, to_string(thread_key), updated_claim),
        accumulate_stats(stats, updated_claim)
      }
    end)
  end

  @spec summary(map()) :: String.t() | nil
  def summary(review_claims) when is_map(review_claims) do
    review_claims
    |> Enum.sort_by(fn {thread_key, _claim} -> thread_key end)
    |> Enum.take(8)
    |> Enum.map(fn {_thread_key, claim} ->
      disposition = Map.get(claim, "disposition") || "unknown"
      verification_status = Map.get(claim, "verification_status") || "not_checked"
      claim_type = Map.get(claim, "claim_type") || "unclear"

      location =
        case {Map.get(claim, "path"), Map.get(claim, "line")} do
          {path, line} when is_binary(path) and is_integer(line) -> "#{path}:#{line}"
          {path, _line} when is_binary(path) -> path
          _ -> "review feedback"
        end

      "- #{claim_type} #{location}: #{verification_status} (#{disposition})"
    end)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  def summary(_review_claims), do: nil

  @spec reply_plan(claim()) :: %{draft_reply: String.t(), resolution_recommendation: String.t()}
  def reply_plan(claim) when is_map(claim) do
    verification_status = Map.get(claim, "verification_status")
    evidence_summary = Map.get(claim, "evidence_summary") |> to_string() |> String.trim()
    consensus_summary = Map.get(claim, "consensus_summary") |> to_string() |> String.trim()
    disposition = Map.get(claim, "disposition")

    draft_reply =
      cond do
        verification_status in ["verified_review_decision", "verified_scope", "verified_symbol_scope"] ->
          "I verified this concern locally and it is actionable. #{evidence_summary} I will address it in the next change."

        verification_status == "contradicted" ->
          "I checked this locally and could not confirm the claim. #{evidence_summary} If you have a narrower reproducer, I can revisit it."

        verification_status == "consensus_supported" ->
          "I found this concern plausible after a focused pass, but I still do not have hard proof to justify a change. #{consensus_summary}"

        verification_status == "stagnant_feedback" ->
          "I have seen this feedback repeatedly, but focused verification still has not produced new concrete evidence. #{evidence_summary}"

        verification_status == "insufficient_evidence" ->
          "I reviewed this feedback and did not find enough concrete evidence to reopen implementation yet. #{consensus_summary}"

        disposition == "deferred" ->
          "I agree this may be worthwhile, but I am deferring it for now to avoid churn on the current PR."

        true ->
          "I reviewed this feedback and will either address it in code or reply with stronger evidence before resolving it."
      end
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    resolution_recommendation =
      cond do
        verification_status in ["verified_review_decision", "verified_scope", "verified_symbol_scope"] ->
          "keep_open_until_change"

        verification_status in ["contradicted", "consensus_supported", "insufficient_evidence"] ->
          "keep_open_until_confirmed"

        verification_status == "stagnant_feedback" ->
          "keep_open_until_confirmed"

        disposition == "deferred" ->
          "keep_open_until_confirmed"

        true ->
          "keep_open_until_confirmed"
      end

    %{draft_reply: draft_reply, resolution_recommendation: resolution_recommendation}
  end

  defp collect_claim(claim, workspace) when is_map(claim) do
    disposition = Map.get(claim, "disposition") || "dismissed"
    verification_attempts = Map.get(claim, "verification_attempts", 0) + 1

    cond do
      disposition != "needs_verification" ->
        claim
        |> Map.put("verification_attempts", verification_attempts)
        |> Map.put_new("verification_status", "not_needed")

      stagnant_feedback?(claim, verification_attempts) ->
        claim
        |> Map.put("verification_attempts", verification_attempts)
        |> Map.put("verification_status", "stagnant_feedback")
        |> Map.put("disposition", "deferred")
        |> Map.put("actionable", false)
        |> Map.put("evidence_refs", Map.get(claim, "evidence_refs", []))
        |> Map.put(
          "evidence_summary",
          "Repeated low-signal review feedback has not produced new local proof. Waiting for stronger evidence before reopening implementation."
        )
        |> ensure_contradiction_sources()

      contradiction?(claim, workspace) ->
        claim
        |> Map.put("verification_attempts", verification_attempts)
        |> Map.put("verification_status", "contradicted")
        |> Map.put("disposition", "dismissed")
        |> Map.put("actionable", false)
        |> Map.put("evidence_refs", contradiction_evidence_refs(claim, workspace))
        |> Map.put("evidence_summary", "Focused review verification contradicted the claim in the local workspace.")
        |> append_proof_source("focused_review_verification")

      symbol_scope_verified?(claim, workspace) ->
        claim
        |> Map.put("verification_attempts", verification_attempts)
        |> Map.put("verification_status", "verified_symbol_scope")
        |> Map.put("disposition", "accepted")
        |> Map.put("actionable", true)
        |> Map.put("hard_proof", true)
        |> Map.put("evidence_refs", symbol_evidence_refs(claim))
        |> Map.put("evidence_summary", "Focused review verification confirmed the referenced symbol exists in the scoped file.")
        |> append_proof_source("workspace_symbol_verified")
        |> ensure_contradiction_sources()

      review_decision_confirmed?(claim) ->
        claim
        |> Map.put("verification_attempts", verification_attempts)
        |> Map.put("verification_status", "verified_review_decision")
        |> Map.put("disposition", "accepted")
        |> Map.put("actionable", true)
        |> Map.put("hard_proof", true)
        |> Map.put("evidence_refs", ["review_decision:changes_requested"])
        |> Map.put("evidence_summary", "Focused review verification confirmed the GitHub review decision still requests changes.")
        |> append_proof_source("github_review_decision")
        |> ensure_contradiction_sources()

      scoped_claim_verified?(claim, workspace) ->
        claim
        |> Map.put("verification_attempts", verification_attempts)
        |> Map.put("verification_status", "verified_scope")
        |> Map.put("disposition", "accepted")
        |> Map.put("actionable", true)
        |> Map.put("hard_proof", true)
        |> Map.put("evidence_refs", scoped_evidence_refs(claim))
        |> Map.put("evidence_summary", "Focused review verification confirmed the referenced file scope exists locally.")
        |> append_proof_source("workspace_scope_verified")
        |> ensure_contradiction_sources()

      consensus_supported?(claim, workspace) ->
        claim
        |> Map.put("verification_attempts", verification_attempts)
        |> Map.put("verification_status", "consensus_supported")
        |> Map.put("evidence_refs", consensus_evidence_refs(claim))
        |> Map.put(
          "evidence_summary",
          "Focused review verification found scoped support and strong consensus, but not enough hard proof to reopen implementation automatically."
        )
        |> ensure_contradiction_sources()

      true ->
        claim
        |> Map.put("verification_attempts", verification_attempts)
        |> Map.put("verification_status", "insufficient_evidence")
        |> Map.put("evidence_refs", [])
        |> Map.put(
          "evidence_summary",
          "Focused review verification did not collect enough concrete local evidence to reopen implementation."
        )
        |> ensure_contradiction_sources()
    end
  end

  defp contradiction?(claim, workspace) do
    path = Map.get(claim, "path")
    line = Map.get(claim, "line")

    cond do
      not is_binary(path) ->
        false

      not file_exists?(workspace, path) ->
        true

      is_integer(line) and not line_exists?(workspace, path, line) ->
        true

      true ->
        false
    end
  end

  defp review_decision_confirmed?(claim) do
    Map.get(claim, "kind") == "review" and normalized_review_decision(claim) == "changes_requested"
  end

  defp symbol_scope_verified?(claim, workspace) do
    path = Map.get(claim, "path")
    symbol = referenced_symbol(claim)

    is_binary(path) and is_binary(symbol) and symbol != "" and file_exists?(workspace, path) and
      file_contains_symbol?(workspace, path, symbol)
  end

  defp scoped_claim_verified?(claim, workspace) do
    claim_type = Map.get(claim, "claim_type")
    path = Map.get(claim, "path")
    line = Map.get(claim, "line")

    claim_type in ["correctness_risk", "failure_handling_risk", "policy_violation", "test_gap"] and
      is_binary(path) and file_exists?(workspace, path) and
      (is_nil(line) or line_exists?(workspace, path, line))
  end

  defp consensus_supported?(claim, workspace) do
    consensus_score = Map.get(claim, "consensus_score", 0.0)
    evidence_quality_score = Map.get(claim, "evidence_quality_score", 0.0)
    locality_score = Map.get(claim, "locality_score", 0.0)
    path = Map.get(claim, "path")
    line = Map.get(claim, "line")

    consensus_score >= 0.70 and evidence_quality_score >= 0.70 and locality_score >= 0.80 and
      is_binary(path) and file_exists?(workspace, path) and (is_nil(line) or line_exists?(workspace, path, line))
  end

  defp stagnant_feedback?(claim, verification_attempts) do
    verification_attempts >= 2 and
      Map.get(claim, "stagnation_state") == "stagnant_feedback" and
      not Map.get(claim, "hard_proof", false)
  end

  defp file_exists?(workspace, path) do
    Enum.any?(candidate_paths(workspace, path), &File.exists?/1)
  end

  defp file_contains_symbol?(workspace, path, symbol) do
    Enum.any?(candidate_paths(workspace, path), fn file_path ->
      case File.read(file_path) do
        {:ok, contents} ->
          String.contains?(contents, symbol)

        _ ->
          false
      end
    end)
  end

  defp line_exists?(workspace, path, line)
       when is_binary(workspace) and is_binary(path) and is_integer(line) and line > 0 do
    Enum.any?(candidate_paths(workspace, path), fn file_path ->
      case File.read(file_path) do
        {:ok, contents} -> length(String.split(contents, "\n")) >= line
        _ -> false
      end
    end)
  end

  defp line_exists?(_workspace, _path, _line), do: false

  defp candidate_paths(workspace, path) do
    [workspace, SymphonyElixir.RunnerRuntime.current_checkout_root()]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.join(&1, path))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp normalized_review_decision(claim) do
    claim
    |> Map.get("review_decision")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp contradiction_evidence_refs(claim, workspace) do
    path = Map.get(claim, "path")
    line = Map.get(claim, "line")

    cond do
      is_binary(path) and not file_exists?(workspace, path) ->
        ["missing_file:#{path}"]

      is_binary(path) and is_integer(line) and not line_exists?(workspace, path, line) ->
        ["missing_line:#{path}:#{line}"]

      true ->
        []
    end
  end

  defp scoped_evidence_refs(claim) do
    case {Map.get(claim, "path"), Map.get(claim, "line")} do
      {path, line} when is_binary(path) and is_integer(line) -> ["file_scope:#{path}:#{line}"]
      {path, _line} when is_binary(path) -> ["file_scope:#{path}"]
      _ -> []
    end
  end

  defp symbol_evidence_refs(claim) do
    case {Map.get(claim, "path"), referenced_symbol(claim)} do
      {path, symbol} when is_binary(path) and is_binary(symbol) and symbol != "" ->
        ["file_symbol:#{path}:#{symbol}"]

      _ ->
        scoped_evidence_refs(claim)
    end
  end

  defp consensus_evidence_refs(claim) do
    refs = scoped_evidence_refs(claim)

    case Map.get(claim, "consensus_state") do
      state when is_binary(state) and state != "" -> refs ++ ["consensus:#{state}"]
      _ -> refs
    end
  end

  defp referenced_symbol(claim) do
    claim
    |> Map.get("body")
    |> to_string()
    |> case do
      text ->
        case Regex.run(~r/`([A-Za-z_][A-Za-z0-9_!?]*)`/, text, capture: :all_but_first) do
          [symbol] -> symbol
          _ -> nil
        end
    end
  end

  defp append_proof_source(claim, proof_source) when is_binary(proof_source) do
    proof_sources =
      claim
      |> Map.get("proof_sources", [])
      |> List.wrap()
      |> Kernel.++([proof_source])
      |> Enum.uniq()

    Map.put(claim, "proof_sources", proof_sources)
  end

  defp ensure_contradiction_sources(claim) do
    Map.put_new(claim, "contradiction_sources", [])
  end

  defp stats_template do
    %{
      accepted_count: 0,
      contradicted_count: 0,
      insufficient_count: 0,
      pending_count: 0
    }
  end

  defp accumulate_stats(stats, claim) do
    verification_status = Map.get(claim, "verification_status")
    disposition = Map.get(claim, "disposition")

    stats
    |> bump_stat(if(disposition == "accepted", do: :accepted_count, else: nil))
    |> bump_stat(if(verification_status == "contradicted", do: :contradicted_count, else: nil))
    |> bump_stat(if(verification_status == "insufficient_evidence", do: :insufficient_count, else: nil))
    |> bump_stat(if(disposition == "needs_verification", do: :pending_count, else: nil))
  end

  defp bump_stat(stats, nil), do: stats
  defp bump_stat(stats, key), do: Map.update!(stats, key, &(&1 + 1))
end
