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
- Persisted concrete `target_paths` and a compact `already_learned` summary into broad retry `resume_context` so the next turn can continue from a file-level target instead of rediscovering the whole repo.
- Tightened the broad retry prompt to drop the issue brief entirely once target paths exist, replace the repo map with a short execution hint, and make the next objective path-specific.
- Live replay showed the first cut still dropped `target_paths` and `already_learned` because broad budget stops often only have structured Codex commentary payloads, not a plain `last_turn_summary`.
- Extended broad retry mining in `RunPolicy` to extract paths and compact continuity from structured `last_codex_message` payloads, including real `response.output_text.done` commentary.
- Found the follow-up live seam: the useful commentary often sits in `recent_codex_updates` because the final update at stop time may just be a noisy tool event.
- Extended broad retry mining again so it scans `recent_codex_updates` as well as `last_codex_message`, matching the real CLZ-32 worker transcript shape from the isolated Codex log store.
- Found the remaining live handoff seam: the orchestrator was storing computed `budget_resume_context` in retry metadata but not reusing it on redispatch, so broad retry focus fields could disappear between the stop decision and the next worker startup.
- Fixed that handoff by persisting retry-time `budget_resume_context` back into the workspace run state and merging it into the next dispatch's loaded `resume_context`, so `target_paths` and `already_learned` survive the live retry boundary.
- Generalized orchestrator retry metadata so broad-mode retries reuse the same automatic continuation path as review-fix retries without being mislabeled as review-fix work.
- Added direct regression coverage for the new broad retry lane, the CI-recovery exclusion, the new stop rule, and the narrowed prompt text.
- Found the live completion seam: worker shutdown was still falling through to the generic budget stop because the broad retry gate required persisted `run_state.stage == "implement"` even when the live `dispatch_stage` was already `implement`.
- Relaxed that gate to trust the live implement dispatch stage and added a regression for a stale persisted blocked state on retry.

## Evidence
- Live dogfood failure proof:
  `/Users/gaspar/code/symphony-workspaces-dogfood/CLZ-30/.symphony/run_state.json` stopped with `budget.per_turn_input_exceeded` after observed input `185018` on March 18, 2026.
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/rule_catalog_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/orchestrator_controls_phase6_test.exs:2269 test/symphony_elixir/orchestrator_controls_phase6_test.exs:2323 test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix harness.check`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix escript.build`
- Live dogfood replay on `http://127.0.0.1:4046` for `CLZ-32` auto-retried the first broad implement overrun into `budget_mode = "broad_implement"` with `retry_count = 1`, `budget_auto_narrowed = true`, and `budget_last_observed_input_tokens = 146909`.
- The narrowed retry then stopped on the broad-specific exhaustion rule instead of the generic budget stop:
  `/Users/gaspar/code/symphony-workspaces-dogfood/CLZ-32/.symphony/run_state.json` ended with `budget.broad_implement_scope_exhausted`, `budget_retry_count = 2`, and observed narrowed-turn input `135797`.
- Runtime Codex logs in `/Users/gaspar/src/symphony-local/.codex-runtime-dogfood/logs_1.sqlite` confirmed the live worker emitted file-level commentary such as ``maybe_stop_for_token_budget/2`` and ``implement_prompt/...`` before the budget stop, which is the continuity source now mined into broad retry state.

## Next Step
Restart the dogfood runner on the committed CLZ-32 head and replay `CLZ-32` so the patched retry handoff can be measured live.
