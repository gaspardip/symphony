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
  end

  defp temp_workspace(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
