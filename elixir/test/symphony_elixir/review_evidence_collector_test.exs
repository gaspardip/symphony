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
    workspace =
      Path.join(System.tmp_dir!(), "review-evidence-#{System.unique_integer([:positive])}")

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
    workspace =
      Path.join(System.tmp_dir!(), "review-evidence-scope-#{System.unique_integer([:positive])}")

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

  test "collect verifies scoped claims against the current checkout for seeded workspaces" do
    workspace =
      Path.join(System.tmp_dir!(), "review-evidence-seeded-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:201" => %{
            "thread_key" => "comment:201",
            "kind" => "comment",
            "path" => "elixir/lib/symphony_elixir_web/router.ex",
            "line" => 36,
            "claim_type" => "correctness_risk",
            "disposition" => "needs_verification",
            "actionable" => true,
            "verification_status" => "pending"
          }
        },
        workspace
      )

    claim = updated_claims["comment:201"]

    assert claim["verification_status"] == "verified_scope"
    assert claim["disposition"] == "accepted"
    assert "workspace_scope_verified" in claim["proof_sources"]
    assert stats.accepted_count == 1
  end

  test "collect upgrades scoped claims when the referenced symbol exists in the file" do
    workspace =
      Path.join(System.tmp_dir!(), "review-evidence-symbol-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "lib"))

    File.write!(
      Path.join(workspace, "lib/example.ex"),
      "def handle_review_verification(state), do: state\n"
    )

    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:111" => %{
            "thread_key" => "comment:111",
            "kind" => "comment",
            "body" => "`handle_review_verification` can ignore the new verification status.",
            "path" => "lib/example.ex",
            "line" => 1,
            "claim_type" => "correctness_risk",
            "disposition" => "needs_verification",
            "actionable" => true,
            "verification_status" => "pending"
          }
        },
        workspace
      )

    claim = updated_claims["comment:111"]

    assert claim["verification_status"] == "verified_symbol_scope"
    assert claim["disposition"] == "accepted"
    assert "workspace_symbol_verified" in claim["proof_sources"]
    assert stats.accepted_count == 1
  end

  test "collect keeps strong-consensus claims pending when hard proof is still missing" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "review-evidence-consensus-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/example.ex"), "one\ntwo\nthree\n")

    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:120" => %{
            "thread_key" => "comment:120",
            "kind" => "comment",
            "body" => "This is wrong because the fallback is ignored before merge.",
            "path" => "lib/example.ex",
            "line" => 2,
            "claim_type" => "performance_risk",
            "disposition" => "needs_verification",
            "actionable" => true,
            "verification_status" => "pending",
            "consensus_score" => 0.9,
            "consensus_state" => "strong_positive",
            "consensus_summary" => "Consensus strongly supports this claim.",
            "evidence_quality_score" => 0.9,
            "locality_score" => 1.0
          }
        },
        workspace
      )

    claim = updated_claims["comment:120"]

    assert claim["verification_status"] == "consensus_supported"
    assert claim["disposition"] == "needs_verification"
    assert "consensus:strong_positive" in claim["evidence_refs"]
    assert stats.pending_count == 1
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

    assert ReviewEvidenceCollector.summary(updated_claims) =~
             "maintainability review feedback: not_needed (deferred)"

    assert ReviewEvidenceCollector.summary(%{}) == nil
  end

  test "collect upgrades tracker dedupe regressions from local code patterns" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "review-evidence-tracker-pattern-#{System.unique_integer([:positive])}"
      )

    file_path = Path.join(workspace, "elixir/lib/symphony_elixir/tracker_event.ex")
    File.mkdir_p!(Path.dirname(file_path))

    File.write!(
      file_path,
      """
      defmodule Example do
        def dedupe_key(hash) do
          ("tracker-event:" <> hash)
          |> Base.encode16(case: :lower)
        end
      end
      """
    )

    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:140" => %{
            "thread_key" => "comment:140",
            "kind" => "comment",
            "body" => "`dedupe_key/1` now produces a completely different key and may break deduplication/backfill logic.",
            "path" => "elixir/lib/symphony_elixir/tracker_event.ex",
            "line" => 3,
            "claim_type" => "unclear",
            "disposition" => "needs_verification",
            "actionable" => true,
            "verification_status" => "pending"
          }
        },
        workspace
      )

    claim = updated_claims["comment:140"]

    assert claim["verification_status"] == "verified_local_pattern"
    assert claim["disposition"] == "accepted"
    assert claim["hard_proof"] == true
    assert "pattern:dedupe_prefix_hex_encoded" in claim["evidence_refs"]
    assert "workspace_pattern_verified" in claim["proof_sources"]
    assert stats.accepted_count == 1
  end

  test "collect contradicts truthy atom-support feedback as an Elixir boolean alias false positive" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "review-evidence-truthy-pattern-#{System.unique_integer([:positive])}"
      )

    file_path = Path.join(workspace, "elixir/lib/symphony_elixir/delivery_engine.ex")
    File.mkdir_p!(Path.dirname(file_path))

    File.write!(
      file_path,
      """
      defmodule Example do
        defp truthy?(value), do: value in [true, "true", true, 1, "1"]
      end
      """
    )

    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:141" => %{
            "thread_key" => "comment:141",
            "kind" => "comment",
            "body" => "`truthy?/1` appears to have accidentally dropped support for the atom `:true`, which can change runtime behavior.",
            "path" => "elixir/lib/symphony_elixir/delivery_engine.ex",
            "line" => 2,
            "claim_type" => "maintainability",
            "disposition" => "deferred",
            "actionable" => false,
            "verification_status" => "not_needed"
          }
        },
        workspace
      )

    claim = updated_claims["comment:141"]

    assert claim["verification_status"] == "contradicted"
    assert claim["disposition"] == "dismissed"
    assert claim["actionable"] == false
    assert "semantic_contradiction:elixir_boolean_atom_alias" in claim["evidence_refs"]
    assert stats.contradicted_count == 1
  end

  test "collect upgrades deferred low-cost hard-proof claims into accepted work" do
    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:150" => %{
            "thread_key" => "comment:150",
            "kind" => "comment",
            "body" => "Grafana is exposed with anonymous admin access.",
            "path" => "ops/observability/docker-compose.yml",
            "line" => 4,
            "claim_type" => "security_risk",
            "disposition" => "deferred",
            "actionable" => false,
            "verification_status" => "not_needed",
            "hard_proof" => true,
            "proof_sources" => ["grafana_anonymous_admin_exposed"],
            "change_cost" => "low",
            "semantic_risk" => "low"
          }
        },
        System.tmp_dir!()
      )

    claim = updated_claims["comment:150"]

    assert claim["verification_status"] == "verified_existing_proof"
    assert claim["disposition"] == "accepted"
    assert claim["actionable"] == true
    assert "proof:grafana_anonymous_admin_exposed" in claim["evidence_refs"]
    assert "existing_proof_override" in claim["proof_sources"]
    assert stats.accepted_count == 1
  end

  test "collect defers repeated stagnant feedback without reopening implementation" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "review-evidence-stagnant-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/example.ex"), "def useful_fun(), do: :ok\n")

    {updated_claims, stats} =
      ReviewEvidenceCollector.collect(
        %{
          "comment:131" => %{
            "thread_key" => "comment:131",
            "kind" => "comment",
            "body" => "Maybe this is risky.",
            "path" => "lib/example.ex",
            "line" => 1,
            "claim_type" => "performance_risk",
            "disposition" => "needs_verification",
            "actionable" => true,
            "verification_status" => "pending",
            "verification_attempts" => 1,
            "stagnation_state" => "stagnant_feedback"
          }
        },
        workspace
      )

    claim = updated_claims["comment:131"]

    assert claim["verification_status"] == "stagnant_feedback"
    assert claim["disposition"] == "deferred"
    assert claim["actionable"] == false
    assert stats.pending_count == 0
  end

  test "reply_plan explains contradicted claims with evidence" do
    reply_plan =
      ReviewEvidenceCollector.reply_plan(%{
        "verification_status" => "contradicted",
        "evidence_summary" => "Focused review verification contradicted the claim in the local workspace."
      })

    assert reply_plan.draft_reply =~ "could not confirm the claim"
    assert reply_plan.draft_reply =~ "contradicted the claim"
    assert reply_plan.resolution_recommendation == "keep_open_until_confirmed"
  end

  test "reply_plan explains stagnant feedback" do
    reply_plan =
      ReviewEvidenceCollector.reply_plan(%{
        "verification_status" => "stagnant_feedback",
        "evidence_summary" => "Repeated low-signal review feedback has not produced new local proof."
      })

    assert reply_plan.draft_reply =~ "seen this feedback repeatedly"
    assert reply_plan.resolution_recommendation == "keep_open_until_confirmed"
  end

  test "reply_plan marks addressed claims for post-change resolution" do
    reply_plan =
      ReviewEvidenceCollector.reply_plan(%{
        "implementation_status" => "addressed",
        "addressed_summary" => "Normalized the metrics route to honor the configured path."
      })

    assert reply_plan.draft_reply =~ "addressed this concern locally"
    assert reply_plan.draft_reply =~ "next branch update"
    assert reply_plan.draft_reply =~ "Normalized the metrics route"
    assert reply_plan.resolution_recommendation == "resolve_after_change"
  end

  test "reply_plan explains dismissed non-actionable claims" do
    reply_plan =
      ReviewEvidenceCollector.reply_plan(%{
        "disposition" => "dismissed",
        "consensus_summary" => "Consensus mixed and no concrete local proof was found."
      })

    assert reply_plan.draft_reply =~ "not making a change"
    assert reply_plan.draft_reply =~ "no concrete local proof"
    assert reply_plan.resolution_recommendation == "keep_open_until_confirmed"
  end
end
