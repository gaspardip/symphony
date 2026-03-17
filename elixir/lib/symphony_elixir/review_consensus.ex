defmodule SymphonyElixir.ReviewConsensus do
  @moduledoc """
  Lightweight independent-pass consensus for PR review claims.

  This module does not call external models yet. Instead it runs three
  deliberately different local passes over the review comment so the runtime
  can distinguish between strong support, mixed evidence, and obvious noise
  before paying for heavier verification.
  """

  @type outcome :: :support | :oppose | :unclear

  @spec assess(map(), keyword()) :: map()
  def assess(item, opts \\ []) when is_map(item) do
    claim_type = Keyword.get(opts, :claim_type, Map.get(item, :claim_type))
    normalized_claim_type = normalize_claim_type(claim_type)
    body = normalized_body(item)
    scoped? = is_binary(Map.get(item, :path)) or is_integer(Map.get(item, :line))
    change_requested? = review_change_requested?(item)

    passes = [
      claim_interpreter(body, normalized_claim_type, scoped?, change_requested?),
      evidence_reviewer(body, normalized_claim_type, scoped?, change_requested?),
      counterexample_reviewer(body, normalized_claim_type, scoped?, change_requested?)
    ]

    support_count = Enum.count(passes, &(&1.outcome == :support))
    oppose_count = Enum.count(passes, &(&1.outcome == :oppose))

    {consensus_state, consensus_score} =
      cond do
        support_count >= 2 and oppose_count == 0 -> {:strong_positive, 0.90}
        support_count >= 2 -> {:mixed_positive, 0.70}
        support_count == 1 and oppose_count == 0 -> {:weak_positive, 0.60}
        oppose_count >= 2 and support_count == 0 -> {:negative, 0.10}
        oppose_count >= 1 and support_count >= 1 -> {:mixed, 0.40}
        true -> {:unclear, 0.50}
      end

    reasons =
      passes
      |> Enum.map(& &1.reason)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      consensus_score: round_score(consensus_score),
      consensus_state: Atom.to_string(consensus_state),
      consensus_support_count: support_count,
      consensus_oppose_count: oppose_count,
      consensus_reasons: reasons,
      consensus_summary: summary(consensus_state, normalized_claim_type, support_count, oppose_count, reasons)
    }
  end

  defp claim_interpreter(_body, :style_or_nit, _scoped?, _change_requested?) do
    %{outcome: :oppose, reason: "claim_interpreter rejected a style-only or nit-level concern"}
  end

  defp claim_interpreter(body, claim_type, scoped?, change_requested?) do
    cond do
      change_requested? ->
        %{outcome: :support, reason: "claim_interpreter saw an explicit changes-requested review"}

      claim_type in [:correctness_risk, :failure_handling_risk, :policy_violation, :test_gap] and scoped? and
          String.length(body) >= 20 ->
        %{outcome: :support, reason: "claim_interpreter found a scoped implementation-level concern"}

      claim_type == :maintainability and scoped? ->
        %{outcome: :unclear, reason: "claim_interpreter found maintainability feedback but not a correctness claim"}

      true ->
        %{outcome: :unclear, reason: "claim_interpreter could not confirm a concrete implementation claim"}
    end
  end

  defp evidence_reviewer(body, _claim_type, scoped?, change_requested?) do
    cond do
      contains_any?(body, ["nit", "rename", "copy", "typo", "format"]) ->
        %{outcome: :oppose, reason: "evidence_reviewer found only low-risk stylistic guidance"}

      change_requested? and scoped? ->
        %{outcome: :support, reason: "evidence_reviewer found a scoped changes-requested review"}

      scoped? and
          contains_any?(body, ["because", "wrong", "missing", "ignored", "regression", "before merge", "break"]) ->
        %{outcome: :support, reason: "evidence_reviewer found a concrete failure-mode explanation"}

      scoped? and String.length(body) >= 30 ->
        %{outcome: :support, reason: "evidence_reviewer found a scoped and specific review comment"}

      true ->
        %{outcome: :unclear, reason: "evidence_reviewer did not find concrete supporting evidence in the comment"}
    end
  end

  defp counterexample_reviewer(body, claim_type, scoped?, change_requested?) do
    cond do
      claim_type == :style_or_nit ->
        %{outcome: :oppose, reason: "counterexample_reviewer found a nit-level comment that should not churn implementation"}

      contains_any?(body, ["maybe", "could", "perhaps", "consider", "might"]) and not change_requested? ->
        %{outcome: :oppose, reason: "counterexample_reviewer found speculative language without a hard request"}

      not scoped? and not change_requested? ->
        %{outcome: :oppose, reason: "counterexample_reviewer found no concrete file, line, or changes-requested review"}

      change_requested? or contains_any?(body, ["regression", "edge case", "broken", "wrong", "crash"]) ->
        %{outcome: :support, reason: "counterexample_reviewer did not find a strong counterexample to the claim"}

      true ->
        %{outcome: :unclear, reason: "counterexample_reviewer could not rule the claim in or out"}
    end
  end

  defp summary(consensus_state, claim_type, support_count, oppose_count, reasons) do
    reason =
      case reasons do
        [first | _rest] -> first
        _ -> "no clear reason recorded"
      end

    "Consensus #{Atom.to_string(consensus_state)} for #{Atom.to_string(claim_type)} (support=#{support_count}, oppose=#{oppose_count}): #{reason}."
  end

  defp normalize_claim_type(value) when is_atom(value), do: value

  defp normalize_claim_type(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        :unclear

      raw ->
        try do
          String.to_existing_atom(raw)
        rescue
          ArgumentError -> :unclear
        end
    end
  end

  defp normalize_claim_type(_value), do: :unclear

  defp normalized_body(item) do
    item
    |> Map.get(:body, "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
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

  defp round_score(score), do: Float.round(score, 2)
end
