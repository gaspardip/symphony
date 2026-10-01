defmodule SymphonyElixir.Orchestrator.GitHubFollowUpTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubEvent
  alias SymphonyElixir.Orchestrator.GitHubFollowUp

  @pr "https://github.com/local/follow-up/pull/1"
  @details "https://github.com/local/follow-up/actions/runs/7"

  test "eligible manual CI produces the complete transition payload and preserves budget context" do
    fresh = %{
      issue_source: "manual",
      stage: "await_checks",
      resume_context: %{token_pressure: "high", turn_count: 7, next_objective: "previous"}
    }

    failure = %{
      event_name: "check_run",
      action: "completed",
      check_name: "unit",
      conclusion: "failure",
      details_url: @details,
      head_sha: "abc123",
      pr_url: @pr,
      summary: "unit (failure)"
    }

    assert GitHubFollowUp.plan(ci_event(), fresh, nil, true) == %{
             stage: "implement",
             attrs: %{
               issue_source: "manual",
               pr_url: @pr,
               stop_reason: nil,
               last_decision: nil,
               last_rule_id: nil,
               last_failure_class: nil,
               await_checks_polls: 0,
               last_ci_failure: failure,
               last_decision_summary: "GitHub CI failure detected on #{@pr}. Returning to implement to fix failing checks.",
               next_human_action: nil,
               resume_context: %{
                 token_pressure: "high",
                 turn_count: 7,
                 ci_failure_summary: "unit (failure)",
                 ci_failure_pr_url: @pr,
                 ci_failure_details_url: @details,
                 next_objective: "Investigate and fix the failing GitHub checks on #{@pr}. Focus first on unit (failure) and return the branch to runtime validation."
               }
             },
             event: "ci.failure_autonomous_follow_up",
             metadata: failure
           }
  end

  test "ineligible CI is only an observation and retains the current objective" do
    plan =
      GitHubFollowUp.plan(
        ci_event(),
        %{issue_source: "tracker", resume_context: %{next_objective: "operator objective", turn_count: 9}},
        nil,
        false
      )

    assert plan.stage == nil
    assert plan.event == "ci.failure_detected"

    assert Enum.sort(Map.keys(plan.attrs)) ==
             [:last_ci_failure, :last_decision_summary, :next_human_action, :resume_context]

    assert plan.attrs.last_decision_summary == "GitHub CI failure detected on #{@pr}: unit (failure)."

    assert plan.attrs.next_human_action ==
             "Inspect the failing GitHub checks and decide whether Symphony should reopen implementation."

    assert plan.attrs.resume_context == %{
             next_objective: "operator objective",
             turn_count: 9,
             ci_failure_summary: "unit (failure)",
             ci_failure_pr_url: @pr,
             ci_failure_details_url: @details
           }

    assert plan.metadata == plan.attrs.last_ci_failure
    refute Map.has_key?(plan.metadata, :next_objective)
  end

  test "sparse CI keeps nil evidence while the human summary uses the existing fallback" do
    event = %{ci_event() | check_name: nil, conclusion: nil, details_url: nil, head_sha: nil}
    plan = GitHubFollowUp.plan(event, %{}, nil, false)

    assert plan.stage == nil

    assert plan.metadata == %{
             event_name: "check_run",
             action: "completed",
             check_name: nil,
             conclusion: nil,
             details_url: nil,
             head_sha: nil,
             pr_url: @pr,
             summary: nil
           }

    assert plan.attrs.last_decision_summary ==
             "GitHub CI failure detected on #{@pr}: failing required checks."

    assert plan.attrs.resume_context == %{
             ci_failure_summary: "failing required checks",
             ci_failure_pr_url: @pr,
             ci_failure_details_url: nil
           }
  end

  test "manual review that the owner deems ineligible records feedback without clearing controls" do
    plan = GitHubFollowUp.plan(review_event(), %{issue_source: "manual"}, feedback(), false)

    assert plan.stage == nil
    assert plan.event == "review.feedback_detected"

    assert Enum.sort(Map.keys(plan.attrs)) ==
             [:last_decision_summary, :last_review_decision, :next_human_action, :resume_context, :review_claims, :review_threads]

    assert plan.attrs.last_review_decision == "CHANGES_REQUESTED"
    assert plan.attrs.last_decision_summary == "New PR review feedback detected on #{@pr}."

    assert plan.attrs.next_human_action ==
             "Review drafted replies and decide whether to address code changes or post a response."

    assert plan.metadata == %{pending_drafts_count: 1, review_decision: "CHANGES_REQUESTED", target_stage: nil}

    assert plan.attrs.review_threads["comment:7"] == %{
             "thread_key" => "comment:7",
             "id" => "7",
             "kind" => "comment",
             "author" => "reviewer",
             "body" => "  Check\n the guard.  ",
             "path" => "lib/guard.ex",
             "line" => 12,
             "state" => nil,
             "review_decision" => nil,
             "submitted_at" => nil,
             "draft_state" => "drafted",
             "draft_reply" => "I will check this.",
             "resolution_recommendation" => nil,
             "source_class" => "trusted_human",
             "claim_type" => "correctness_risk",
             "veracity_score" => nil,
             "reproducibility_score" => nil,
             "evidence_quality_score" => nil,
             "locality_score" => nil,
             "source_precision_score" => nil,
             "consensus_score" => nil,
             "consensus_state" => nil,
             "consensus_summary" => nil,
             "consensus_reasons" => [],
             "historical_precision_score" => nil,
             "stagnation_score" => nil,
             "stagnation_state" => nil,
             "repeated_feedback_count" => 1,
             "hard_proof" => false,
             "proof_sources" => [],
             "contradiction_sources" => [],
             "disposition" => "accepted",
             "actionable" => true,
             "adjudication_summary" => nil,
             "pr_url" => @pr
           }

    assert plan.attrs.resume_context == %{
             review_feedback_summary: "- comment lib/guard.ex:12: Check the guard.",
             review_claim_summary: "- correctness_risk lib/guard.ex:12: not_needed (accepted)",
             review_feedback_pr_url: @pr
           }
  end

  test "eligible review noise preserves an existing objective and never asks for a transition" do
    plan =
      GitHubFollowUp.plan(
        review_event(),
        %{stage: "blocked", resume_context: %{next_objective: "keep me", token_pressure: "high"}},
        %{items: [], actionable_items_count: 0},
        true
      )

    assert plan == %{
             stage: nil,
             attrs: %{
               review_threads: %{},
               review_claims: %{},
               last_review_decision: nil,
               last_decision_summary: "GitHub review feedback detected on #{@pr}, but the current adjudicator triaged it as non-actionable noise.",
               next_human_action: nil,
               resume_context: %{
                 next_objective: "keep me",
                 token_pressure: "high",
                 review_feedback_summary: nil,
                 review_claim_summary: nil,
                 review_feedback_pr_url: @pr
               }
             },
             event: "review.feedback_triaged",
             metadata: %{pending_drafts_count: 0, review_decision: nil, target_stage: nil}
           }
  end

  test "actionable review keeps source representation and the owner-supplied return stage" do
    fresh = %{issue_source: " MANUAL ", stage: "blocked", resume_context: %{turn_count: 3}}
    plan = GitHubFollowUp.plan(review_event(), fresh, feedback(), true)

    assert plan.stage == "implement"
    assert plan.event == "review.feedback_autonomous_follow_up"

    assert Map.take(plan.attrs, [:issue_source, :pr_url, :review_return_stage, :stop_reason, :last_decision, :last_rule_id, :last_failure_class]) == %{
             issue_source: " MANUAL ",
             pr_url: @pr,
             review_return_stage: "blocked",
             stop_reason: nil,
             last_decision: nil,
             last_rule_id: nil,
             last_failure_class: nil
           }

    assert plan.attrs.last_decision_summary ==
             "GitHub review feedback detected on #{@pr}. Returning to implement to address the requested changes."

    assert plan.attrs.next_human_action == nil
    assert plan.attrs.resume_context.turn_count == 3

    assert plan.attrs.resume_context.next_objective ==
             "Address the pending GitHub review feedback on #{@pr}, update the code, and return the branch to runtime validation."

    assert plan.metadata == %{pending_drafts_count: 1, review_decision: "CHANGES_REQUESTED", target_stage: "implement"}
  end

  test "verification retains attempts and evidence, resets a contradicted claim, and leaves other claims intact" do
    old_claim = %{"verification_status" => "contradicted", "verification_attempts" => 4, "evidence_refs" => ["proof:old"], "evidence_summary" => "previous inspection"}
    other_claim = %{"claim_type" => "scope", "verification_status" => "verified_scope", "disposition" => "accepted"}
    other_thread = %{"kind" => "review", "body" => "Existing note"}

    fresh = %{
      stage: "await_checks",
      issue_source: nil,
      resume_context: %{token_pressure: "high"},
      review_claims: %{"comment:7" => old_claim, "review:8" => other_claim},
      review_threads: %{"review:8" => other_thread}
    }

    feedback = %{feedback() | items: [%{item() | disposition: "needs_verification"}]}
    plan = GitHubFollowUp.plan(review_event(), fresh, feedback, true)

    assert plan.stage == "review_verification"
    assert plan.attrs.review_return_stage == "await_checks"
    assert plan.attrs.issue_source == nil

    assert Map.take(plan.attrs.review_claims["comment:7"], ["verification_status", "verification_attempts", "evidence_refs", "evidence_summary"]) == %{
             "verification_status" => "pending",
             "verification_attempts" => 4,
             "evidence_refs" => ["proof:old"],
             "evidence_summary" => "previous inspection"
           }

    assert plan.attrs.review_claims["review:8"] == other_claim
    assert plan.attrs.review_threads["review:8"] == other_thread
    assert plan.attrs.resume_context.token_pressure == "high"

    assert plan.attrs.resume_context.review_feedback_summary ==
             "- comment lib/guard.ex:12: Check the guard.\n- review: Existing note"

    assert plan.attrs.resume_context.review_claim_summary ==
             "- correctness_risk lib/guard.ex:12: pending (needs_verification)\n- scope review feedback: verified_scope (accepted)"

    assert plan.attrs.resume_context.next_objective ==
             "Verify the pending GitHub review feedback on #{@pr}, collect local evidence, and reopen implementation only for verified claims."

    assert plan.metadata.target_stage == "review_verification"
  end

  test "a later invocation uses its new eligibility and retains verified evidence without a cached decision" do
    feedback = %{feedback() | items: [%{item() | disposition: "needs_verification"}]}
    fresh = %{review_claims: %{"comment:7" => %{"verification_status" => "verified_scope", "verification_attempts" => 2}}}

    first = GitHubFollowUp.plan(review_event(), fresh, feedback, true)
    second = GitHubFollowUp.plan(review_event(), fresh, feedback, false)

    assert first.stage == "review_verification"
    assert second.stage == nil
    assert second.event == "review.feedback_detected"
    assert second.attrs.review_claims["comment:7"]["verification_status"] == "verified_scope"
    assert second.attrs.review_claims["comment:7"]["verification_attempts"] == 2
    refute Map.has_key?(second.attrs, :stop_reason)
    refute Map.has_key?(second.attrs.resume_context, :next_objective)
  end

  test "explicit nil review values remain nil while absent values keep the historical defaults" do
    item = Map.merge(item(), %{draft_state: nil, hard_proof: nil, proof_sources: nil, repeated_feedback_count: nil})
    feedback = %{feedback() | items: [item, %{thread_key: nil, body: "ignored unkeyed item"}]}
    fresh = %{resume_context: "legacy non-map", review_claims: %{"comment:7" => %{"verification_attempts" => nil, "evidence_refs" => nil}}}
    plan = GitHubFollowUp.plan(review_event(), fresh, feedback, false)

    assert Map.keys(plan.attrs.review_threads) == ["comment:7"]
    assert Map.keys(plan.attrs.review_claims) == ["comment:7"]
    assert plan.attrs.review_threads["comment:7"]["draft_state"] == nil
    assert plan.attrs.review_threads["comment:7"]["hard_proof"] == nil
    assert plan.attrs.review_threads["comment:7"]["proof_sources"] == nil
    assert plan.attrs.review_threads["comment:7"]["repeated_feedback_count"] == nil
    assert plan.attrs.review_threads["comment:7"]["consensus_reasons"] == []
    assert plan.attrs.review_claims["comment:7"]["verification_attempts"] == nil
    assert plan.attrs.review_claims["comment:7"]["evidence_refs"] == nil
    assert plan.attrs.review_claims["comment:7"]["verification_status"] == "not_needed"

    assert plan.attrs.resume_context == %{
             review_feedback_summary: "- comment lib/guard.ex:12: Check the guard.",
             review_claim_summary: "- correctness_risk lib/guard.ex:12: not_needed (accepted)",
             review_feedback_pr_url: @pr
           }
  end

  defp ci_event do
    %GitHubEvent{provider: "github", event_name: "check_run", action: "completed", raw: %{}, pr_url: @pr, check_name: "unit", conclusion: "failure", details_url: @details, head_sha: "abc123"}
  end

  defp review_event do
    %GitHubEvent{provider: "github", event_name: "pull_request_review_comment", action: "created", raw: %{}, pr_url: @pr}
  end

  defp feedback do
    %{items: [item()], actionable_items_count: 1, pending_drafts_count: 1, review_decision: "CHANGES_REQUESTED"}
  end

  defp item do
    %{
      thread_key: "comment:7",
      id: "7",
      kind: :comment,
      author: "reviewer",
      body: "  Check\n the guard.  ",
      path: "lib/guard.ex",
      line: 12,
      draft_reply: "I will check this.",
      source_class: "trusted_human",
      claim_type: "correctness_risk",
      disposition: "accepted",
      actionable: true
    }
  end
end

defmodule SymphonyElixir.Orchestrator.GitHubFollowUpPersistenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{GitHubEvent, LeaseManager, RunStateStore}
  alias SymphonyElixir.Orchestrator.GitHubFollowUp

  @pr "https://github.com/local/follow-up/pull/1"

  setup do
    root = Path.join(System.tmp_dir!(), "github-follow-up-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "C5-PLAN")
    issue_id = "manual:plan-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    on_exit(fn -> File.rm_rf!(root) end)

    raw = %{
      "issue_id" => issue_id,
      "issue_identifier" => "C5-PLAN",
      "stage" => "await_checks",
      "pr_url" => @pr,
      "resume_context" => %{"token_pressure" => "high", "turn_count" => 7},
      "token_usage" => %{"input_tokens" => 11, "output_tokens" => 3, "total_tokens" => 14}
    }

    File.write!(RunStateStore.state_path(workspace), Jason.encode!(raw))
    assert {:ok, acquired} = LeaseManager.acquire(issue_id, "C5-PLAN", "plan-owner")
    on_exit(fn -> assert {:ok, :released} = LeaseManager.release_token(acquired.token) end)
    authority = %{workspace: workspace, issue_id: issue_id, issue_identifier: "C5-PLAN", binding: :legacy_absent, lease_token: acquired.token, deadline: System.monotonic_time(:millisecond) + 30_000}
    %{workspace: workspace, raw: raw, authority: authority}
  end

  for source <- [:absent, nil, "manual"] do
    @tag source: source
    test "CI plan persists through the real coordinator CAS preserving source #{inspect(source)}", c do
      raw = if c.source == :absent, do: c.raw, else: Map.put(c.raw, "issue_source", c.source)
      File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(raw))
      expected = RunStateStore.coordinator_projection(raw)
      assert {:ok, fresh} = RunStateStore.ensure_coordinator_current(c.authority, expected)
      event = %GitHubEvent{provider: "github", event_name: "check_run", action: "completed", raw: %{}, pr_url: @pr, check_name: "unit", conclusion: "failure"}
      plan = GitHubFollowUp.plan(event, fields(fresh), nil, true)

      assert plan.stage == "implement"
      assert {:ok, persisted} = RunStateStore.transition_coordinator_current(c.authority, expected, plan.stage, plan.attrs)
      written = raw!(c)
      assert Map.fetch(written, "issue_source") == Map.fetch(raw, "issue_source")
      assert written["stage"] == "implement"
      assert written["await_checks_polls"] == 0
      assert written["token_usage"] == raw["token_usage"]
      assert written["resume_context"]["token_pressure"] == "high"
      assert written["resume_context"]["turn_count"] == 7
      assert written["resume_context"]["ci_failure_summary"] == "unit (failure)"
      assert written["last_ci_failure"]["summary"] == "unit (failure)"
      refute Map.has_key?(written, "run_id")
      assert written == persisted |> Jason.encode!() |> Jason.decode!()
      before = File.read!(RunStateStore.state_path(c.workspace))

      assert {:error, {:coordinator_precondition_failed, :coordinator_material_changed}} =
               RunStateStore.transition_coordinator_current(c.authority, expected, plan.stage, plan.attrs)

      assert File.read!(RunStateStore.state_path(c.workspace)) == before
    end
  end

  test "review observation then verification transition carries durable attempts and fresh resume fields", c do
    raw =
      Map.merge(c.raw, %{
        "issue_source" => "manual",
        "stop_reason" => nil,
        "review_claims" => %{"comment:9" => %{"verification_status" => "contradicted", "verification_attempts" => 3, "evidence_refs" => ["proof:9"], "evidence_summary" => "retained evidence"}}
      })

    File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(raw))
    expected = RunStateStore.coordinator_projection(raw)
    assert {:ok, fresh} = RunStateStore.ensure_coordinator_current(c.authority, expected)
    event = %GitHubEvent{provider: "github", event_name: "pull_request_review_comment", action: "created", raw: %{}, pr_url: @pr}

    feedback = %{
      items: [%{thread_key: "comment:9", kind: :comment, body: "Confirm the guard", disposition: "needs_verification", actionable: true}],
      actionable_items_count: 1,
      pending_drafts_count: 1,
      review_decision: "CHANGES_REQUESTED"
    }

    observation = GitHubFollowUp.plan(event, fields(fresh), feedback, false)
    assert observation.stage == nil
    assert {:ok, observed} = RunStateStore.update_coordinator_current(c.authority, expected, observation.attrs)
    assert Map.fetch(raw!(c), "stop_reason") == {:ok, nil}
    assert raw!(c)["review_claims"]["comment:9"]["verification_attempts"] == 3
    assert raw!(c)["resume_context"]["token_pressure"] == "high"

    # Eligibility is a new owner input. This integration checks the plan/CAS
    # contract, not whether an actual owner would approve this controlled state.
    plan = GitHubFollowUp.plan(event, fields(observed), feedback, true)
    assert plan.stage == "review_verification"
    assert {:ok, _} = RunStateStore.transition_coordinator_current(c.authority, RunStateStore.coordinator_projection(observed), plan.stage, plan.attrs)
    written = raw!(c)
    assert written["stage"] == "review_verification"
    assert written["review_return_stage"] == "await_checks"
    assert written["stop_reason"] == nil
    assert written["review_claims"]["comment:9"]["verification_status"] == "pending"
    assert written["review_claims"]["comment:9"]["verification_attempts"] == 3
    assert written["review_claims"]["comment:9"]["evidence_refs"] == ["proof:9"]
    assert written["review_claims"]["comment:9"]["evidence_summary"] == "retained evidence"
    assert written["resume_context"]["turn_count"] == 7
    assert written["resume_context"]["review_claim_summary"] == "- unclear review feedback: pending (needs_verification)"
    assert written["token_usage"] == raw["token_usage"]
  end

  defp fields(fresh), do: Map.take(fresh, [:issue_source, :stage, :resume_context, :review_threads, :review_claims])
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
end
