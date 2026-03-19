# CLZ-33: Stabilize budget lane admission and continuity on main

## Goal
Make every over-budget implement turn on remote `main` end in one explainable budget state: `review_fix`, `broad_implement`, or a generic `budget.per_turn_input_exceeded` stop with a concrete, operator-visible admission reason.

## Acceptance
- Broad-implement admission is a first-class runtime decision instead of an implicit fallthrough.
- First-turn broad implement runs can mine one focus path from issue text when no prior summary exists.
- First-turn implement overruns with no focusable path stop as `budget.broad_implement_scope_exhausted`, not the generic budget rule.
- Generic per-turn stops remain legal only when a concrete `budget_admission_reason` is persisted and visible.
- Active dispatch, blocked persistence, and operator payloads all surface the same broad retry metadata.

## Plan
- Merge persisted `run_state.resume_context` into live budget decisions so admission and retry continuity do not depend only on the running entry shell.
- Promote the branch-proven target-path fixes into `main`: issue/body/title path extraction, string-key normalization, and blocked-budget dispatch rewind.
- Extend operator payloads so issue/state reads expose the exact budget lane or ineligibility reason from persisted state only.
- Rebuild the isolated proof runner from merged `main` and require unattended docs-first then code-change proofs.

## Work Log
- Started from a clean worktree on remote `main` (`9250f9bd2602ef3269dc04072c5366a2b4e62c4d`) instead of the stale local `codex/clz-31-operator-api-reads` branch.
- Confirmed the live `CLZ-33` proof runner still stopped generically on `budget.per_turn_input_exceeded` with an empty `resume_context`, which narrowed the remaining gap to admission and continuity instead of the raw token cap.
- Promoted first-turn broad target-path extraction from issue metadata into `RunPolicy`, so broad implement admission can mine focus paths directly from the issue title/body when no prior turn summary exists.
- Made broad-implement admission explicit in `RunPolicy.budget_runtime/2` and `maybe_stop_for_token_budget/2`, with concrete non-entry reasons such as `stage_not_implement`, `review_fix_candidate`, `ci_failure_present`, `missing_workspace`, `no_target_path`, and `budget_not_exceeded`.
- Fixed the continuity seam where generic budget stops rebuilt `resume_context` only from the live running entry and silently dropped persisted retry state that had just been written to `run_state.json`.
- Tightened the workspace-admission check so `missing_workspace` means the real workspace directory is absent, instead of merely requiring `running_entry.workspace` to be populated.
- Added dispatch-stage rewind coverage in `Orchestrator` for blocked budget-stopped workspaces so normal active redispatch resumes the persisted blocked stage with the existing retry metadata intact.
- Exposed `budget_runtime` directly in presenter issue payloads using persisted run-state fields, including `budget_mode`, `budget_admission_reason`, `target_paths`, `next_required_path`, and `budget_expansion_used`.
- Added the zero-arg promoted-label helper in `RunnerRuntime` so issue routing uses the installed runner metadata during clean-main proof replays.
- Fixed the last operator surface gap so generic broad-mode payloads also expose persisted `budget_last_stop_code` and `budget_last_observed_input_tokens` instead of dropping them to `nil`.

## Validation
- `cd /tmp/symphony-budget-stabilize/elixir && mix test test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs test/symphony_elixir/orchestrator_controls_phase6_test.exs test/symphony_elixir/policy_runtime_test.exs test/symphony_elixir/web_phase6_backfill_test.exs`
- `cd /tmp/symphony-budget-stabilize/elixir && mix harness.check`
- `cd /tmp/symphony-budget-stabilize/elixir && mix escript.build`

## Evidence
- The pre-fix isolated proof runner stopped generically on `CLZ-33` with an empty `resume_context`, matching the remaining gap described in the implementation plan:
  - `/tmp/symphony-workspaces-mainproof/CLZ-33/.symphony/run_state.json`
  - `/tmp/symphony-dogfood-mainproof-logs/log/symphony.log.1`
- Focused budget-policy, orchestrator, routing, and presenter coverage is green on the clean-main worktree after the admission/continuity fixes:
  - `189 tests, 0 failures`
- The focused matrix now proves the planned behavior changes directly:
  - first-turn broad implement overruns with no focusable path stop as `budget.broad_implement_scope_exhausted`
  - generic per-turn stops persist `budget_admission_reason`
  - blocked budget-stopped workspaces rewind back into active dispatch with preserved retry metadata
  - presenter issue payloads expose persisted `budget_runtime` fields instead of collapsing to a generic empty shell

## Next Step
- Commit the stabilization slice, rebuild the isolated proof runner from merged `main` only, and rerun unattended proof ticket 1 (docs/operator) followed by proof ticket 2 (small code change) without manual rescue.
