defmodule SymphonyElixir.RuleCatalog do
  @moduledoc """
  Stable rule identifiers, failure classes, and default human actions for
  runtime and operator decisions.
  """

  @rules %{
    runner_install_missing: %{
      rule_id: "runner.install_missing",
      failure_class: "environment",
      human_action: "Bootstrap or promote a runner release before dispatching dogfood issues."
    },
    runner_current_missing: %{
      rule_id: "runner.current_missing",
      failure_class: "environment",
      human_action: "Repair the `current` symlink so it points at a real release directory."
    },
    runner_current_mismatch: %{
      rule_id: "runner.current_mismatch",
      failure_class: "environment",
      human_action: "Make `metadata.json` and the `current` symlink agree on the active runner release."
    },
    runner_metadata_invalid: %{
      rule_id: "runner.metadata_invalid",
      failure_class: "environment",
      human_action: "Repair `metadata.json` or promote a fresh runner release."
    },
    runner_release_missing: %{
      rule_id: "runner.release_missing",
      failure_class: "environment",
      human_action: "Restore the missing release directory or roll back to an available release."
    },
    missing_checkout: %{
      rule_id: "checkout.missing_git",
      failure_class: "environment",
      human_action: "Ensure the workspace contains a valid Git checkout and retry the issue."
    },
    runner_overlap: %{
      rule_id: "checkout.runner_overlap",
      failure_class: "environment",
      human_action: "Move the runner install or workspace so they no longer overlap, then retry."
    },
    missing_harness: %{
      rule_id: "harness.missing",
      failure_class: "environment",
      human_action: "Add `.symphony/harness.yml` to the target repo before retrying."
    },
    missing_harness_version: %{
      rule_id: "harness.missing_version",
      failure_class: "environment",
      human_action: "Set `version: 1` in `.symphony/harness.yml` and retry."
    },
    missing_harness_command: %{
      rule_id: "harness.missing_command",
      failure_class: "environment",
      human_action: "Add the missing harness command entry and retry."
    },
    missing_required_checks: %{
      rule_id: "harness.missing_required_checks",
      failure_class: "environment",
      human_action: "Declare `pull_request.required_checks` in `.symphony/harness.yml` and retry."
    },
    invalid_harness: %{
      rule_id: "harness.invalid_schema",
      failure_class: "environment",
      human_action: "Fix the harness schema errors and retry the issue."
    },
    preflight_failed: %{
      rule_id: "preflight.failed",
      failure_class: "environment",
      human_action: "Fix the repo preflight failure and retry the issue."
    },
    validation_failed: %{
      rule_id: "validation.failed",
      failure_class: "validation",
      human_action: "Inspect the validation failure, fix it, and move the issue back into the active flow."
    },
    validation_unavailable: %{
      rule_id: "validation.unavailable",
      failure_class: "validation",
      human_action: "Restore the validation command or environment, then retry."
    },
    publish_missing_pr: %{
      rule_id: "publish.missing_pr",
      failure_class: "publish",
      human_action: "Create or reattach the PR before moving the issue back into review."
    },
    noop_turn: %{
      rule_id: "noop.max_turns_exceeded",
      failure_class: "implementation",
      human_action: "Review the issue scope or prompt because the agent is not producing changes."
    },
    per_turn_input_budget_exceeded: %{
      rule_id: "budget.per_turn_input_exceeded",
      failure_class: "budget",
      human_action: "Reduce prompt or exploration overhead before retrying."
    },
    per_issue_total_budget_exceeded: %{
      rule_id: "budget.per_issue_total_exceeded",
      failure_class: "budget",
      human_action: "Trim the workflow or split the issue into smaller work before retrying."
    },
    per_issue_output_budget_exceeded: %{
      rule_id: "budget.per_issue_output_exceeded",
      failure_class: "budget",
      human_action: "Reduce agent verbosity or split the work into smaller issues."
    },
    checkout_failed: %{
      rule_id: "checkout.failed",
      failure_class: "environment",
      human_action: "Fix the checkout/bootstrap error and retry the issue."
    },
    turn_budget_exhausted: %{
      rule_id: "implementation.turn_budget_exhausted",
      failure_class: "implementation",
      human_action: "Split the issue or increase the turn budget only after inspecting the prior attempts."
    },
    turn_failed: %{
      rule_id: "implementation.turn_failed",
      failure_class: "implementation",
      human_action: "Inspect the Codex session or app-server failure details and retry the issue after the underlying runtime problem is resolved."
    },
    missing_turn_result: %{
      rule_id: "implementation.missing_turn_result",
      failure_class: "implementation",
      human_action: "Inspect the implementation prompt or tool wiring so the agent reports its turn result."
    },
    invalid_turn_result: %{
      rule_id: "implementation.invalid_turn_result",
      failure_class: "implementation",
      human_action: "Fix the turn result contract emitted by the agent and retry."
    },
    verifier_failed: %{
      rule_id: "verification.needs_more_work",
      failure_class: "verification",
      human_action: "Review the verifier feedback, then move the issue back into active work."
    },
    verifier_blocked: %{
      rule_id: "verification.blocked",
      failure_class: "verification",
      human_action: "Resolve the verification blocker before retrying."
    },
    unsafe_to_merge: %{
      rule_id: "verification.unsafe_to_merge",
      failure_class: "verification",
      human_action: "Address the unsafe verifier findings before another publish attempt."
    },
    publish_failed: %{
      rule_id: "publish.failed",
      failure_class: "publish",
      human_action: "Fix the publish failure, then retry or republish from the dashboard."
    },
    pr_closed: %{
      rule_id: "publish.closed_pr",
      failure_class: "publish",
      human_action: "Reopen or recreate the PR before retrying merge."
    },
    required_checks_missing: %{
      rule_id: "checks.missing",
      failure_class: "review",
      human_action: "Ensure the required checks are configured and visible on the PR."
    },
    required_checks_pending: %{
      rule_id: "checks.pending",
      failure_class: "review",
      human_action: "Wait for the required checks to finish."
    },
    required_checks_failed: %{
      rule_id: "checks.failed",
      failure_class: "review",
      human_action: "Fix the failing required checks before retrying merge."
    },
    required_checks_cancelled: %{
      rule_id: "checks.cancelled",
      failure_class: "review",
      human_action: "Re-run the cancelled required checks before retrying merge."
    },
    merge_failed: %{
      rule_id: "merge.failed",
      failure_class: "merge",
      human_action: "Inspect the merge failure, correct it, and retry merge."
    },
    post_merge_failed: %{
      rule_id: "post_merge.failed",
      failure_class: "post_merge",
      human_action: "Inspect the post-merge verification failure and move the issue to rework if needed."
    },
    policy_invalid_labels: %{
      rule_id: "policy.invalid_labels",
      failure_class: "policy",
      human_action: "Keep exactly one policy label on the issue before retrying."
    },
    policy_review_required: %{
      rule_id: "policy.review_required",
      failure_class: "policy",
      human_action: "Review the published PR manually, then approve it for merge from the dashboard."
    },
    policy_never_automerge: %{
      rule_id: "policy.never_automerge",
      failure_class: "policy",
      human_action: "A human must decide whether this PR should merge; Symphony will not automerge it."
    },
    lease_lost: %{
      rule_id: "coordination.lease_lost",
      failure_class: "coordination",
      human_action: "Check for another active Symphony instance holding the issue lease."
    }
  }

  @spec rule(atom() | nil) :: map()
  def rule(code) when is_atom(code), do: Map.get(@rules, code, fallback_rule(code))
  def rule(_code), do: fallback_rule(:unknown)

  @spec rule_id(atom() | nil) :: String.t()
  def rule_id(code), do: rule(code).rule_id

  @spec failure_class(atom() | nil) :: String.t()
  def failure_class(code), do: rule(code).failure_class

  @spec human_action(atom() | nil) :: String.t()
  def human_action(code), do: rule(code).human_action

  defp fallback_rule(code) do
    %{
      rule_id: "runtime.#{code}",
      failure_class: "policy",
      human_action: "Inspect the runtime decision and correct the underlying condition before retrying."
    }
  end
end
