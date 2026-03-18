defmodule SymphonyElixir.RuleCatalogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuleCatalog

  @known_rules [
    :runner_install_missing,
    :runner_current_missing,
    :runner_current_mismatch,
    :runner_metadata_invalid,
    :runner_release_missing,
    :missing_checkout,
    :runner_overlap,
    :missing_harness,
    :missing_harness_version,
    :missing_harness_command,
    :missing_required_checks,
    :invalid_harness,
    :preflight_failed,
    :validation_failed,
    :validation_unavailable,
    :publish_missing_pr,
    :noop_turn,
    :per_turn_input_budget_exceeded,
    :per_issue_total_budget_exceeded,
    :per_issue_output_budget_exceeded,
    :review_fix_scope_exhausted,
    :review_fix_turn_window_exhausted,
    :review_fix_total_extension_exhausted,
    :checkout_failed,
    :turn_budget_exhausted,
    :turn_failed,
    :missing_turn_result,
    :invalid_turn_result,
    :verifier_failed,
    :behavior_proof_missing,
    :verifier_blocked,
    :unsafe_to_merge,
    :publish_failed,
    :pr_closed,
    :required_checks_missing,
    :required_checks_pending,
    :required_checks_failed,
    :required_checks_cancelled,
    :merge_failed,
    :post_merge_failed,
    :policy_invalid_labels,
    :policy_review_required,
    :policy_never_automerge,
    :lease_lost
  ]

  test "known rules expose stable ids failure classes and human actions" do
    Enum.each(@known_rules, fn code ->
      rule = RuleCatalog.rule(code)
      assert is_binary(rule.rule_id)
      assert String.contains?(rule.rule_id, ".")
      assert is_binary(rule.failure_class)
      assert is_binary(rule.human_action)
      assert RuleCatalog.rule_id(code) == rule.rule_id
      assert RuleCatalog.failure_class(code) == rule.failure_class
      assert RuleCatalog.human_action(code) == rule.human_action
    end)
  end

  test "unknown rules fall back deterministically" do
    fallback = RuleCatalog.rule(:some_new_rule)
    assert fallback.rule_id == "runtime.some_new_rule"
    assert fallback.failure_class == "policy"
    assert fallback.human_action =~ "Inspect the runtime decision"

    nil_rule = RuleCatalog.rule(nil)
    assert nil_rule.rule_id == "runtime."

    string_rule = RuleCatalog.rule("string_rule")
    assert string_rule.rule_id == "runtime.unknown"
  end
end
