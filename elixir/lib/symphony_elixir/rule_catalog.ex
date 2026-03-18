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
    webhook_signature_invalid: %{
      rule_id: "webhook.signature_invalid",
      failure_class: "coordination",
      human_action: "Check the Linear webhook secret and signature configuration, then resend the event."
    },
    webhook_payload_invalid: %{
      rule_id: "webhook.payload_invalid",
      failure_class: "coordination",
      human_action: "Fix the webhook payload or secret configuration so Symphony can decode it."
    },
    webhook_event_ignored: %{
      rule_id: "webhook.event_ignored",
      failure_class: "coordination",
      human_action: "No action is required unless this event should have been schedule-affecting."
    },
    webhook_enqueue_failed: %{
      rule_id: "webhook.enqueue_failed",
      failure_class: "coordination",
      human_action: "Repair the tracker inbox storage path so Symphony can enqueue webhook events."
    },
    missing_checkout: %{
      rule_id: "checkout.missing_git",
      failure_class: "environment",
      human_action: "Ensure the workspace contains a valid Git checkout and retry the issue."
    },
    branch_pr_mismatch: %{
      rule_id: "checkout.branch_pr_mismatch",
      failure_class: "environment",
      human_action: "Repair or discard the workspace so the issue branch and attached PR match this issue before retrying."
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
    harness_initialize_failed: %{
      rule_id: "harness.initialize_failed",
      failure_class: "environment",
      human_action: "Fix the self-development harness artifacts or initializer contract before retrying."
    },
    harness_publish_gate_failed: %{
      rule_id: "harness.publish_gate_failed",
      failure_class: "verification",
      human_action: "Update the required progress and feature artifacts before publishing this self-host change."
    },
    harness_check_failed: %{
      rule_id: "harness.check_failed",
      failure_class: "environment",
      human_action: "Fix the self-development harness check failures and rerun validation."
    },
    repo_not_compatible: %{
      rule_id: "compatibility.not_certified",
      failure_class: "environment",
      human_action: "Fix the reported repo compatibility failures before dispatching autonomous work."
    },
    tracker_mutation_forbidden: %{
      rule_id: "policy.tracker_mutation_forbidden",
      failure_class: "policy",
      human_action: "Switch to a more permissive operating mode or keep this repo in tracker-read-only mode."
    },
    pr_posting_forbidden: %{
      rule_id: "policy.pr_posting_forbidden",
      failure_class: "policy",
      human_action: "Use a policy pack that allows PR publication or keep this repo in local-only draft mode."
    },
    credential_scope_forbidden: %{
      rule_id: "policy.credential_scope_forbidden",
      failure_class: "policy",
      human_action: "Expand the local credential registry for this company/repo operation before retrying."
    },
    repo_frozen: %{
      rule_id: "policy.repo_frozen",
      failure_class: "policy",
      human_action: "Unfreeze the repo in the company policy pack before dispatching new work."
    },
    company_frozen: %{
      rule_id: "policy.company_frozen",
      failure_class: "policy",
      human_action: "Unfreeze the company policy pack before dispatching new work."
    },
    max_concurrent_runs_exceeded: %{
      rule_id: "policy.max_concurrent_runs_exceeded",
      failure_class: "policy",
      human_action: "Reduce concurrent runs for this company or raise the configured company concurrency limit."
    },
    max_merges_per_day_exceeded: %{
      rule_id: "policy.max_merges_per_day_exceeded",
      failure_class: "policy",
      human_action: "Wait for the daily merge window to reset or raise the repo merge cap before merging more work."
    },
    risk_review_required: %{
      rule_id: "policy.risk_review_required",
      failure_class: "policy",
      human_action: "Approve this high-risk contractor run in the configured approval gate before merge."
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
    review_fix_scope_exhausted: %{
      rule_id: "budget.review_fix_scope_exhausted",
      failure_class: "budget",
      human_action: "Split the scoped review-fix work further or intervene manually because Symphony cannot narrow it any more."
    },
    review_fix_turn_window_exhausted: %{
      rule_id: "budget.review_fix_turn_window_exhausted",
      failure_class: "budget",
      human_action: "Inspect the repeated scoped retry attempts and either reduce the scope further or intervene manually."
    },
    review_fix_total_extension_exhausted: %{
      rule_id: "budget.review_fix_total_extension_exhausted",
      failure_class: "budget",
      human_action: "The bounded review-fix extension is exhausted; split the remaining work or intervene manually."
    },
    broad_implement_scope_exhausted: %{
      rule_id: "budget.broad_implement_scope_exhausted",
      failure_class: "budget",
      human_action: "The narrowed broad-implement retry is exhausted; trim the issue context further or intervene manually."
    },
    tracker_rate_limited: %{
      rule_id: "tracker.rate_limited",
      failure_class: "coordination",
      human_action: "Wait for the Linear API rate limit window to reset or reduce tracker read traffic."
    },
    tracker_backoff_active: %{
      rule_id: "tracker.backoff_active",
      failure_class: "coordination",
      human_action: "Wait for Symphony's Linear backoff window to expire before expecting new dispatches."
    },
    tracker_event_replayed: %{
      rule_id: "tracker.event_replayed",
      failure_class: "coordination",
      human_action: "No action is required unless a tracker event was unexpectedly skipped."
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
    command_output_budget_exceeded: %{
      rule_id: "implementation.command_output_budget_exceeded",
      failure_class: "implementation",
      human_action: "Reduce command output and keep implement turns focused on narrow inspection instead of long logs."
    },
    command_count_exceeded: %{
      rule_id: "implementation.command_count_exceeded",
      failure_class: "implementation",
      human_action: "Reduce implement-turn command count and use fewer, more targeted inspection commands."
    },
    broad_read_violation: %{
      rule_id: "implementation.broad_read_violation",
      failure_class: "implementation",
      human_action: "Avoid broad repository inventory and full diff commands during implement. Use targeted reads and `git diff --stat` only."
    },
    stage_command_violation: %{
      rule_id: "implementation.stage_command_violation",
      failure_class: "implementation",
      human_action: "Move heavyweight validation or verification commands out of implement and let Symphony run the repo contract in later stages."
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
    behavior_proof_missing: %{
      rule_id: "verification.behavior_proof_missing",
      failure_class: "verification",
      human_action: "Add or update repo-owned behavioral proof such as changed tests or the configured proof artifact, then retry."
    },
    ui_proof_missing: %{
      rule_id: "verification.ui_proof_missing",
      failure_class: "verification",
      human_action: "Add the repo-declared UI proof, such as UI tests, proof artifacts, or required UI checks, then retry."
    },
    ui_proof_command_failed: %{
      rule_id: "verification.ui_proof_command_failed",
      failure_class: "verification",
      human_action: "Fix the configured UI proof command or its environment, then retry."
    },
    ui_proof_artifact_missing: %{
      rule_id: "verification.ui_proof_artifact_missing",
      failure_class: "verification",
      human_action: "Generate the declared UI proof artifacts before another publish attempt."
    },
    ui_proof_checks_missing: %{
      rule_id: "verification.ui_proof_checks_missing",
      failure_class: "verification",
      human_action: "Ensure the required UI proof checks are configured and appear on the PR."
    },
    ui_proof_checks_failed: %{
      rule_id: "verification.ui_proof_checks_failed",
      failure_class: "verification",
      human_action: "Fix the failing UI proof checks before merge."
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
    merge_readiness_failed: %{
      rule_id: "merge_readiness.failed",
      failure_class: "pr_hygiene",
      human_action: "Fix the PR hygiene maintenance failure, then refresh merge readiness from the dashboard."
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
    deploy_preview_missing: %{
      rule_id: "deploy.preview_missing",
      failure_class: "deploy",
      human_action: "Declare a preview deploy command in the repo harness or disable automatic preview deploy for this profile."
    },
    deploy_preview_failed: %{
      rule_id: "deploy.preview_failed",
      failure_class: "deploy",
      human_action: "Inspect the preview deployment failure, correct it, and retry deployment."
    },
    deploy_production_missing: %{
      rule_id: "deploy.production_missing",
      failure_class: "deploy",
      human_action: "Declare a production deploy command in the repo harness or disable automatic production deploy for this profile."
    },
    deploy_production_failed: %{
      rule_id: "deploy.production_failed",
      failure_class: "deploy",
      human_action: "Inspect the production deployment failure, correct it, and retry deployment."
    },
    post_deploy_failed: %{
      rule_id: "deploy.post_deploy_failed",
      failure_class: "deploy",
      human_action: "Inspect the post-deploy verification failure and fix or roll back the affected deployment."
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
    policy_pack_disallows_class: %{
      rule_id: "policy.pack_disallows_class",
      failure_class: "policy",
      human_action: "Remove the disallowed policy label or override, or switch the repo/company policy pack before retrying."
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
    policy_workload_restricted: %{
      rule_id: "policy.workload_restricted",
      failure_class: "policy",
      human_action: "Adjust the issue labels or change the company policy pack before retrying this workload."
    },
    repo_boundary_mismatch: %{
      rule_id: "checkout.repo_boundary_mismatch",
      failure_class: "environment",
      human_action: "Repair the checkout remote or discard the workspace so it points at the configured repo before retrying."
    },
    policy_merge_window_wait: %{
      rule_id: "policy.merge_window_wait",
      failure_class: "policy",
      human_action: "Wait for the next allowed merge window, or change the company policy pack if this merge must happen now."
    },
    policy_deploy_window_wait: %{
      rule_id: "policy.deploy_window_wait",
      failure_class: "policy",
      human_action: "Wait for the next allowed production deploy window, or change the company policy pack if this deployment must happen now."
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
