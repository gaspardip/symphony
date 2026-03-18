# CLZ-32: Shape broad implement context under token pressure instead of escalating blindly

## Goal
Keep broad implement runs bounded under token pressure by narrowing context on retry instead of simply increasing the per-turn budget.

## Acceptance
- Broad implement runs keep the existing hard budget on the first turn.
- A real persisted broad implement run can take one bounded narrow retry after `budget.per_turn_input_exceeded`.
- The broad retry uses a leaner implement prompt than the default broad implement path.
- Broad retry logic does not steal scoped review-fix or explicit CI-failure recovery work.
- Exhausted broad retries stop with a broad-mode-specific rule instead of the generic budget rule.

## Plan
- Detect true broad implement runs from persisted run state instead of treating all implement-stage budget stops the same.
- Persist a bounded broad-mode retry state in `resume_context`.
- Build a narrower broad implement retry prompt in `DeliveryEngine`.
- Auto-reschedule the first broad retry without increasing the cap.
- Stop on a specific broad-mode exhaustion rule if the narrowed retry still overruns the budget.

## Work Log
- Created `CLZ-32` from the live dogfood failure on `CLZ-30`, where the first real self-host implement turn stopped at `budget.per_turn_input_exceeded` with observed input `185018`.
- Added repo-owned `broad_implement` token-budget policy defaults in `Config`.
- Added a bounded broad implement retry lane in `RunPolicy` that persists `budget_mode = "broad_implement"` and auto-narrow metadata, but only for real persisted implement workspaces.
- Kept the broad retry lane out of review-fix and explicit CI-failure recovery paths by gating it against persisted `review_claims`, `budget_scope_kind`, `budget_mode`, and `last_ci_failure`.
- Added a lean broad retry prompt path in `DeliveryEngine` that trims issue context and avoids duplicated review-oriented sections.
- Generalized orchestrator retry metadata so broad-mode retries reuse the same automatic continuation path as review-fix retries without being mislabeled as review-fix work.
- Added direct regression coverage for the new broad retry lane, the CI-recovery exclusion, the new stop rule, and the narrowed prompt text.
- Found the live completion seam: worker shutdown was still falling through to the generic budget stop because the broad retry gate required persisted `run_state.stage == "implement"` even when the live `dispatch_stage` was already `implement`.
- Relaxed that gate to trust the live implement dispatch stage and added a regression for a stale persisted blocked state on retry.

## Evidence
- Live dogfood failure proof:
  `/Users/gaspar/code/symphony-workspaces-dogfood/CLZ-30/.symphony/run_state.json` stopped with `budget.per_turn_input_exceeded` after observed input `185018` on March 18, 2026.
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/rule_catalog_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs`

## Next Step
Run the focused policy tests and rebuild the escript, then replay `CLZ-32` live to confirm the broad lane auto-retries instead of stopping generically at worker completion.
