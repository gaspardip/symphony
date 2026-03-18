defmodule SymphonyElixir.ReviewConsensusTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewConsensus

  test "assess strongly supports scoped changes-requested correctness feedback" do
    assessment =
      ReviewConsensus.assess(
        %{
          body: "Please fix this edge case because the fallback is ignored before merge.",
          path: "lib/example.ex",
          line: 12,
          state: "CHANGES_REQUESTED",
          review_decision: "CHANGES_REQUESTED"
        },
        claim_type: :correctness_risk
      )

    assert assessment.consensus_state == "strong_positive"
    assert assessment.consensus_score >= 0.90
    assert assessment.consensus_support_count >= 2
    assert assessment.consensus_summary =~ "correctness_risk"
  end

  test "assess rejects nit-level feedback as negative consensus" do
    assessment =
      ReviewConsensus.assess(
        %{
          body: "nit: rename this local for clarity",
          path: "lib/example.ex",
          line: 2
        },
        claim_type: :style_or_nit
      )

    assert assessment.consensus_state == "negative"
    assert assessment.consensus_score <= 0.10
    assert assessment.consensus_oppose_count >= 2
  end

  test "assess reports mixed positive consensus for scoped maintainability feedback" do
    assessment =
      ReviewConsensus.assess(
        %{
          body: "Could we extract this into a shared helper because the behavior is duplicated in this file?",
          path: "lib/example.ex",
          line: 8
        },
        claim_type: :maintainability
      )

    assert assessment.consensus_state == "mixed"
    assert assessment.consensus_score >= 0.40
    assert assessment.consensus_support_count >= 1
    assert assessment.consensus_oppose_count >= 1
  end

  test "assess reports weak positive consensus for a scoped correctness clue without changes requested" do
    assessment =
      ReviewConsensus.assess(
        %{
          body: "The regression is scoped here.",
          path: "lib/example.ex",
          line: 3
        },
        claim_type: :correctness_risk
      )

    assert assessment.consensus_state == "strong_positive"
    assert assessment.consensus_score >= 0.60
    assert assessment.consensus_support_count >= 2
  end

  test "assess falls back to unclear claim type when the provided claim type is unknown text" do
    assessment =
      ReviewConsensus.assess(
        %{
          body: "This seems odd.",
          path: nil,
          line: nil
        },
        claim_type: "definitely_unknown"
      )

    assert assessment.consensus_state in ["negative", "unclear"]
    assert is_binary(assessment.consensus_summary)
  end
end
