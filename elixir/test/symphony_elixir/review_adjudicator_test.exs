defmodule SymphonyElixir.ReviewAdjudicatorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewAdjudicator

  test "dismisses Copilot nit feedback as non-actionable noise" do
    workspace = temp_workspace("review-adjudicator-nit")
    file_path = Path.join(workspace, "lib/example.ex")
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, "line1\nline2\nline3\n")

    adjudication =
      ReviewAdjudicator.adjudicate(
        %{
          kind: :comment,
          author: "copilot-pull-request-reviewer",
          body: "nit: rename this local for clarity",
          path: "lib/example.ex",
          line: 2,
          state: nil,
          review_decision: "COMMENTED"
        },
        workspace: workspace
      )

    assert adjudication.source_class == "ai_reviewer"
    assert adjudication.claim_type == "style_or_nit"
    assert adjudication.disposition == "dismissed"
    assert adjudication.actionable == false
    assert adjudication.consensus_state == "negative"
    assert adjudication.consensus_score <= 0.10
  end

  test "treats change-requested review feedback as needs verification" do
    adjudication =
      ReviewAdjudicator.adjudicate(%{
        kind: :review,
        author: "copilot-pull-request-reviewer",
        body: "Please fix this edge case before merge.",
        state: "COMMENTED",
        review_decision: "CHANGES_REQUESTED"
      })

    assert adjudication.source_class == "ai_reviewer"
    assert adjudication.claim_type == "correctness_risk"
    assert adjudication.disposition == "needs_verification"
    assert adjudication.actionable == true
    assert adjudication.veracity_score >= 0.60
    assert adjudication.consensus_state in ["strong_positive", "mixed_positive"]
    assert adjudication.consensus_summary =~ "correctness_risk"
  end

  test "uses the current checkout as a fallback code root for seeded workspaces" do
    workspace = temp_workspace("review-adjudicator-seeded")

    adjudication =
      ReviewAdjudicator.adjudicate(
        %{
          kind: :comment,
          author: "Copilot",
          body: "The metrics endpoint route is hard-coded and the config is ignored, which can break runtime behavior.",
          path: "elixir/lib/symphony_elixir_web/router.ex",
          line: 36,
          state: nil,
          review_decision: "COMMENTED"
        },
        workspace: workspace
      )

    assert adjudication.locality_score == 1.0
    assert adjudication.contradiction_sources == []
    assert adjudication.disposition == "needs_verification"
    assert adjudication.actionable == true
  end

  test "treats hard-coded config mismatch comments as correctness risks" do
    workspace = temp_workspace("review-adjudicator-config")

    adjudication =
      ReviewAdjudicator.adjudicate(
        %{
          kind: :comment,
          author: "Copilot",
          body: "The metrics endpoint route is hard-coded to `/metrics`, and changing `metrics_path` in config will not affect routing.",
          path: "elixir/lib/symphony_elixir_web/router.ex",
          line: 36,
          state: nil,
          review_decision: "COMMENTED"
        },
        workspace: workspace
      )

    assert adjudication.claim_type == "correctness_risk"
    assert adjudication.evidence_quality_score >= 0.75
    assert adjudication.disposition == "needs_verification"
  end

  test "treats parser-breakage comments as correctness risks" do
    workspace = temp_workspace("review-adjudicator-parser")

    adjudication =
      ReviewAdjudicator.adjudicate(
        %{
          kind: :comment,
          author: "Copilot",
          body: "`max_block_bytes: 1_000_000` uses invalid numeric literal syntax in YAML and may be parsed as a string or cause parsing errors.",
          path: "ops/observability/tempo/config.yml",
          line: 16,
          state: nil,
          review_decision: "COMMENTED"
        },
        workspace: workspace
      )

    assert adjudication.claim_type == "correctness_risk"
    assert adjudication.evidence_quality_score >= 0.75
    assert adjudication.disposition == "needs_verification"
  end

  defp temp_workspace(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
