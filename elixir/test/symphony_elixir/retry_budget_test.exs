defmodule SymphonyElixir.RetryBudgetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryBudget
  alias SymphonyElixir.RetryBudget.{Decision, PolicyView, Stop}

  test "scoped accumulated total has priority over output and hard input" do
    view = policy_view(%{}, %{current_turn_input: 101, issue_usage: %{total_tokens: 1_001, output_tokens: 101}})

    assert %Decision{resume_context: nil, result: {:stop, %Stop{kind: :per_issue_total, observed: 1_001}}} =
             RetryBudget.decide(view, view.initial_state)
  end

  test "scoped output has priority over hard input when total remains available" do
    view = policy_view(%{}, %{current_turn_input: 101, issue_usage: %{total_tokens: 500, output_tokens: 101}})

    assert %Decision{resume_context: nil, result: {:stop, %Stop{kind: :per_issue_total_output, observed: 101}}} =
             RetryBudget.decide(view, view.initial_state)
  end

  test "values exactly at all three limits do not stop the run" do
    view = policy_view(%{}, %{current_turn_input: 100, issue_usage: %{total_tokens: 1_000, output_tokens: 100}})
    assert %Decision{resume_context: nil, result: :ok} = RetryBudget.decide(view, view.initial_state)
  end

  test "scoped retry narrows claims without renewing the existing window" do
    resume = %{"custom" => "keep", budget_scope_ids: ["comment:1", "comment:2"], budget_window_base_turn: 4}
    view = policy_view(resume, %{entry: %{stage: "implement", turn_count: 5}, current_turn_input: 101})

    assert %Decision{resume_context: next, result: {:retry, %{retry_count: 1, resume_context: retry_resume}}} =
             RetryBudget.decide(view, view.initial_state)

    assert next == retry_resume
    assert next.budget_scope_ids == ["comment:1"]
    assert next.budget_window_base_turn == 4
    assert next["custom"] == "keep"
  end

  test "an exhausted scoped turn window stops even when narrowing is possible" do
    resume = %{budget_scope_ids: ["comment:1", "comment:2"], budget_window_base_turn: 4}
    view = policy_view(resume, %{entry: %{stage: "implement", turn_count: 9}, current_turn_input: 101})

    assert %Decision{resume_context: next, result: {:stop, %Stop{kind: :review_fix_turn_window_exhausted, metadata: metadata}}} =
             RetryBudget.decide(view, view.initial_state)

    assert next.budget_window_base_turn == 4
    assert next.budget_retry_count == 1
    assert metadata.turns_in_window == 6
  end

  test "the fourth scoped retry requires an actual reduction in scope" do
    resume = %{budget_retry_count: 3, budget_scope_ids: ["comment:1"]}
    view = policy_view(resume, %{current_turn_input: 101})

    assert %Decision{resume_context: next, result: {:stop, %Stop{kind: :review_fix_scope_exhausted}}} =
             RetryBudget.decide(view, view.initial_state)

    assert next.budget_retry_count == 4
    assert next.budget_scope_ids == ["comment:1"]
  end

  test "extension exhaustion retains pre-write metadata and prepares a separate critical resume" do
    resume = %{budget_total_extension_used: true, budget_progress_count: 1, budget_pressure_level: "soft"}
    view = policy_view(resume, %{issue_usage: %{total_tokens: 1_501, output_tokens: 0}})

    assert %Decision{resume_context: next, result: {:stop, %Stop{kind: :review_fix_total_extension_exhausted, metadata: metadata}}} =
             RetryBudget.decide(view, view.initial_state)

    assert metadata.pressure_level == "soft"
    assert metadata.base_budget == 1_000
    assert metadata.extension_budget == 500
    assert next.budget_pressure_level == "critical"
    assert next.budget_last_stop_code == "budget.review_fix_total_extension_exhausted"
  end

  test "checked decisions see progress and unknown metadata returned by the pressure write" do
    view = policy_view(%{}, %{issue_usage: %{total_tokens: 1_100, output_tokens: 0}})
    current = %{resume_context: %{"custom" => "fresh", budget_progress_count: 1}}

    assert %Decision{resume_context: next, result: :ok} = RetryBudget.decide(view, current)
    assert next.budget_total_extension_used == true
    assert next["custom"] == "fresh"
  end

  test "legacy scoped decisions retain the initial resume for this evaluation" do
    view = policy_view(%{}, %{source: :legacy, issue_usage: %{total_tokens: 1_100, output_tokens: 0}})
    current = %{resume_context: %{budget_progress_count: 1}}

    assert %Decision{resume_context: nil, result: {:stop, %Stop{kind: :per_issue_total}}} =
             RetryBudget.decide(view, current)
  end

  test "a focused-claim query does not enumerate malformed claims needed only by the turn-cap query" do
    state = %{review_claims: nil, resume_context: %{token_pressure: "high"}}
    assert RetryBudget.delivery_limits(state, :focused_claim_limit) == 1
    assert_raise Protocol.UndefinedError, fn -> RetryBudget.delivery_limits(state, {:max_turns, 3}) end
  end

  defp policy_view(resume, overrides) do
    values = %{
      source: :checked,
      mode: :scoped_review_fix,
      issue: %{id: "BUDGET-1", identifier: "BUDGET-1"},
      entry: %{stage: "implement", turn_count: 1},
      workspace: nil,
      initial_state: %{resume_context: resume},
      initial_resume: resume,
      stage: nil,
      stage_budget: %{},
      total_budget: 1_000,
      token_budget: %{per_issue_total: 1_000, per_issue_total_output: 100},
      review_fix_budget: %{auto_retry_limit: 4, per_issue_total_extension: 500},
      broad_budget: %{},
      current_turn_input: 50,
      issue_usage: %{total_tokens: 500, output_tokens: 0},
      adaptive_budget: %{per_turn_input_hard: 100, max_turns_in_window: 6, narrow_scope_batch_size: 1}
    }

    struct!(PolicyView, Map.merge(values, overrides))
  end
end
