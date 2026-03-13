defmodule SymphonyElixir.ReviewAdjudicator do
  @moduledoc """
  Source-aware heuristic adjudication for PR review feedback.

  This is the first runtime slice of the broader review adjudication plan. It
  classifies review feedback into coarse claim types, scores likely veracity
  from cheap local signals, and returns a triage disposition that the runtime
  can use to suppress obvious noise before reopening implementation.
  """

  alias SymphonyElixir.ReviewConsensus

  @neutral_score 0.5

  @type disposition :: :accepted | :needs_verification | :deferred | :dismissed
  @type claim_type ::
          :critical_bug
          | :correctness_risk
          | :security_risk
          | :performance_risk
          | :failure_handling_risk
          | :maintainability
          | :style_or_nit
          | :policy_violation
          | :test_gap
          | :unclear

  @spec adjudicate(map(), keyword()) :: map()
  def adjudicate(item, opts \\ []) when is_map(item) do
    workspace = Keyword.get(opts, :workspace)
    source_class = source_class(Map.get(item, :author))
    claim_type = claim_type(item)
    contradictions = contradiction_sources(item, workspace)
    hard_proof_sources = hard_proof_sources(item, workspace, claim_type)
    reproducibility_score = reproducibility_score(claim_type, contradictions, hard_proof_sources)
    evidence_quality_score = evidence_quality_score(item, claim_type)
    locality_score = locality_score(item, workspace)
    source_precision_score = source_precision_score(source_class)
    consensus = ReviewConsensus.assess(item, claim_type: claim_type)
    consensus_score = Map.get(consensus, :consensus_score, @neutral_score)
    historical_precision_score = @neutral_score

    veracity_score =
      [
        reproducibility_score * 0.25,
        evidence_quality_score * 0.20,
        locality_score * 0.15,
        source_precision_score * 0.15,
        consensus_score * 0.15,
        historical_precision_score * 0.10
      ]
      |> Enum.sum()
      |> maybe_adjust_for_review_decision(item)
      |> clamp_score()
      |> round_score()

    disposition =
      disposition(
        claim_type,
        veracity_score,
        hard_proof_sources != [],
        contradictions != []
      )

    %{
      source_class: Atom.to_string(source_class),
      claim_type: Atom.to_string(claim_type),
      veracity_score: veracity_score,
      reproducibility_score: round_score(reproducibility_score),
      evidence_quality_score: round_score(evidence_quality_score),
      locality_score: round_score(locality_score),
      source_precision_score: round_score(source_precision_score),
      consensus_score: round_score(consensus_score),
      consensus_state: Map.get(consensus, :consensus_state, "unclear"),
      consensus_summary: Map.get(consensus, :consensus_summary),
      consensus_reasons: Map.get(consensus, :consensus_reasons, []),
      historical_precision_score: round_score(historical_precision_score),
      hard_proof: hard_proof_sources != [],
      proof_sources: Enum.map(hard_proof_sources, &to_string/1),
      contradiction_sources: Enum.map(contradictions, &to_string/1),
      disposition: Atom.to_string(disposition),
      actionable: disposition in [:accepted, :needs_verification],
      adjudication_summary: summary(source_class, claim_type, disposition, item)
    }
  end

  @spec actionable_feedback?(map()) :: boolean()
  def actionable_feedback?(%{actionable: value}) when is_boolean(value), do: value
  def actionable_feedback?(%{"actionable" => value}) when is_boolean(value), do: value
  def actionable_feedback?(_item), do: false

  @spec source_class(String.t() | nil) :: :human | :first_party_bot | :ai_reviewer | :external_bot | :unknown
  def source_class(author) when is_binary(author) do
    normalized = String.downcase(String.trim(author))

    cond do
      normalized == "" ->
        :unknown

      String.contains?(normalized, "copilot") ->
        :ai_reviewer

      normalized in ["github-actions[bot]", "codeql[bot]"] ->
        :first_party_bot

      String.ends_with?(normalized, "[bot]") ->
        :external_bot

      true ->
        :human
    end
  end

  def source_class(_author), do: :unknown

  @spec claim_type(map()) :: claim_type()
  def claim_type(item) when is_map(item) do
    body = normalized_body(item)

    cond do
      nit_comment?(body) ->
        :style_or_nit

      contains_any?(body, ["security", "unsafe", "xss", "csrf", "leak", "secret", "injection"]) ->
        :security_risk

      contains_any?(body, ["performance", "slow", "n+1", "inefficient", "allocation", "latency"]) ->
        :performance_risk

      contains_any?(body, ["exception", "crash", "retry", "timeout", "fallback", "error handling"]) ->
        :failure_handling_risk

      contains_any?(body, ["policy", "contract", "forbidden", "required", "allowlist", "denylist"]) ->
        :policy_violation

      contains_any?(body, ["test", "coverage", "missing spec", "assertion", "regression test"]) ->
        :test_gap

      review_change_requested?(item) ->
        :correctness_risk

      contains_any?(body, ["bug", "wrong", "ignored", "incorrect", "broken", "regression", "edge case"]) ->
        :correctness_risk

      contains_any?(body, ["duplicate", "reuse", "shared helper", "extract", "refactor", "simplify"]) ->
        :maintainability

      contains_any?(body, ["rename", "wording", "copy", "typo", "spelling", "format"]) ->
        :style_or_nit

      body != "" ->
        :unclear

      true ->
        :unclear
    end
  end

  defp summary(source_class, claim_type, disposition, item) do
    scope =
      case {Map.get(item, :path), Map.get(item, :line)} do
        {path, line} when is_binary(path) and is_integer(line) -> "#{path}:#{line}"
        {path, _line} when is_binary(path) -> path
        _ -> "PR feedback"
      end

    "#{humanize_disposition(disposition)} #{Atom.to_string(claim_type)} from #{Atom.to_string(source_class)} on #{scope}."
  end

  defp humanize_disposition(:accepted), do: "Accepted"
  defp humanize_disposition(:needs_verification), do: "Needs verification for"
  defp humanize_disposition(:deferred), do: "Deferred"
  defp humanize_disposition(:dismissed), do: "Dismissed"

  defp evidence_quality_score(item, claim_type) do
    body = normalized_body(item)
    has_scope? = is_binary(Map.get(item, :path)) or is_integer(Map.get(item, :line))

    cond do
      claim_type == :style_or_nit ->
        0.10

      contains_any?(body, ["because", "break", "ignored", "wrong", "missing", "before merge", "regression"]) and has_scope? ->
        0.90

      contains_any?(body, ["break", "ignored", "wrong", "missing", "bug", "edge case", "regression"]) ->
        0.75

      review_change_requested?(item) and String.length(body) >= 20 ->
        0.70

      claim_type in [:maintainability, :test_gap, :policy_violation] and has_scope? ->
        0.55

      String.length(body) >= 20 ->
        0.45

      true ->
        0.20
    end
  end

  defp locality_score(item, workspace) do
    path = Map.get(item, :path)
    line = Map.get(item, :line)

    cond do
      is_binary(path) and is_integer(line) and scope_exists?(workspace, path, line) ->
        1.00

      is_binary(path) and file_exists?(workspace, path) ->
        0.80

      review_change_requested?(item) ->
        0.55

      Map.get(item, :kind) == :review ->
        0.30

      true ->
        0.00
    end
  end

  defp source_precision_score(:human), do: 0.65
  defp source_precision_score(:first_party_bot), do: 0.75
  defp source_precision_score(:ai_reviewer), do: 0.50
  defp source_precision_score(:external_bot), do: 0.45
  defp source_precision_score(:unknown), do: 0.35

  defp reproducibility_score(_claim_type, _contradictions, hard_proof_sources)
       when hard_proof_sources != [] do
    1.00
  end

  defp reproducibility_score(_claim_type, contradictions, _hard_proof_sources)
       when contradictions != [] do
    0.00
  end

  defp reproducibility_score(_claim_type, _contradictions, _hard_proof_sources), do: @neutral_score

  defp contradiction_sources(item, workspace) do
    path = Map.get(item, :path)
    line = Map.get(item, :line)

    cond do
      not is_binary(path) ->
        []

      not file_exists?(workspace, path) ->
        [:missing_path]

      is_integer(line) and not scope_exists?(workspace, path, line) ->
        [:line_out_of_range]

      true ->
        []
    end
  end

  defp hard_proof_sources(item, workspace, :policy_violation) do
    body = normalized_body(item)

    if contains_any?(body, ["metrics_path", "config is ignored"]) and is_binary(Map.get(item, :path)) and
         file_exists?(workspace, Map.get(item, :path)) do
      [:repo_config_reference]
    else
      []
    end
  end

  defp hard_proof_sources(_item, _workspace, _claim_type), do: []

  defp maybe_adjust_for_review_decision(score, item) do
    if review_change_requested?(item), do: score + 0.10, else: score
  end

  defp disposition(_claim_type, _score, _hard_proof?, true), do: :dismissed

  defp disposition(claim_type, score, hard_proof?, false) do
    case claim_type do
      type when type in [:critical_bug, :security_risk] ->
        cond do
          score >= 0.85 and hard_proof? -> :accepted
          score >= 0.65 -> :needs_verification
          true -> :dismissed
        end

      type when type in [:correctness_risk, :failure_handling_risk, :performance_risk, :policy_violation, :test_gap, :unclear] ->
        cond do
          score >= 0.80 and hard_proof? -> :accepted
          score >= 0.60 -> :needs_verification
          true -> :dismissed
        end

      :maintainability ->
        if score >= 0.50, do: :deferred, else: :dismissed

      :style_or_nit ->
        if score >= 0.70, do: :deferred, else: :dismissed
    end
  end

  defp normalized_body(item) do
    item
    |> Map.get(:body, "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp nit_comment?(body) when is_binary(body) do
    String.starts_with?(body, "nit") or String.contains?(body, " nit:")
  end

  defp review_change_requested?(item) when is_map(item) do
    state =
      item
      |> Map.get(:state)
      |> to_string()
      |> String.trim()
      |> String.upcase()

    decision =
      item
      |> Map.get(:review_decision)
      |> to_string()
      |> String.trim()
      |> String.upcase()

    state == "CHANGES_REQUESTED" or decision == "CHANGES_REQUESTED"
  end

  defp contains_any?(body, needles) when is_binary(body) do
    Enum.any?(needles, &String.contains?(body, &1))
  end

  defp file_exists?(workspace, relative_path)
       when is_binary(workspace) and is_binary(relative_path) do
    workspace
    |> Path.join(relative_path)
    |> File.exists?()
  end

  defp file_exists?(_workspace, _relative_path), do: false

  defp scope_exists?(workspace, relative_path, line)
       when is_binary(workspace) and is_binary(relative_path) and is_integer(line) and line > 0 do
    file_path = Path.join(workspace, relative_path)

    case File.read(file_path) do
      {:ok, contents} ->
        length(String.split(contents, "\n")) >= line

      _ ->
        false
    end
  end

  defp scope_exists?(_workspace, _relative_path, _line), do: false

  defp clamp_score(score) when score < 0.0, do: 0.0
  defp clamp_score(score) when score > 1.0, do: 1.0
  defp clamp_score(score), do: score

  defp round_score(score) do
    Float.round(score, 2)
  end
end
