defmodule SymphonyElixir.ReviewEvidenceCollectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewEvidenceCollector

  test "collect upgrades change-requested review claims into accepted claims" do
    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "review:91" => %{
            "thread_key" => "review:91",
            "kind" => "review",
            "review_decision" => "CHANGES_REQUESTED",
            "claim_type" => "correctness_risk",
            "disposition" => "needs_verification",
            "actionable" => true,
            "verification_status" => "pending"
          }
        },
        System.tmp_dir!()
      )

    claim = updated_claims["review:91"]

    assert claim["verification_status"] == "verified_review_decision"
    assert claim["disposition"] == "accepted"
    assert claim["hard_proof"] == true
    assert "github_review_decision" in claim["proof_sources"]
    assert stats.accepted_count == 1
  end

  test "collect dismisses contradictory scoped claims" do
    workspace = Path.join(System.tmp_dir!(), "review-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:92" => %{
            "thread_key" => "comment:92",
            "kind" => "comment",
            "path" => "lib/missing.ex",
            "line" => 7,
            "claim_type" => "correctness_risk",
            "disposition" => "needs_verification",
            "actionable" => true,
            "verification_status" => "pending"
          }
        },
        workspace
      )

    claim = updated_claims["comment:92"]

    assert claim["verification_status"] == "contradicted"
    assert claim["disposition"] == "dismissed"
    assert claim["actionable"] == false
    assert stats.contradicted_count == 1
  end

  test "collect upgrades scoped claims when the referenced file scope exists" do
    workspace = Path.join(System.tmp_dir!(), "review-evidence-scope-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/example.ex"), "one\ntwo\nthree\n")

    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:99" => %{
            "thread_key" => "comment:99",
            "kind" => "comment",
            "path" => "lib/example.ex",
            "line" => 2,
            "claim_type" => "correctness_risk",
            "disposition" => "needs_verification",
            "actionable" => true,
            "verification_status" => "pending"
          }
        },
        workspace
      )

    claim = updated_claims["comment:99"]

    assert claim["verification_status"] == "verified_scope"
    assert claim["disposition"] == "accepted"
    assert "workspace_scope_verified" in claim["proof_sources"]
    assert stats.accepted_count == 1
  end

  test "collect preserves non-verification claims and renders summaries" do
    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:12" => %{
            "thread_key" => "comment:12",
            "kind" => "comment",
            "claim_type" => "maintainability",
            "disposition" => "deferred",
            "actionable" => false
          }
        },
        System.tmp_dir!()
      )

    claim = updated_claims["comment:12"]

    assert claim["verification_status"] == "not_needed"
    assert claim["verification_attempts"] == 1
    assert stats.accepted_count == 0
    assert ReviewEvidenceCollector.summary(updated_claims) =~ "maintainability review feedback: not_needed (deferred)"
    assert ReviewEvidenceCollector.summary(%{}) == nil
  end
end
