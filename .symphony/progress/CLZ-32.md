# CLZ-32: Shape broad implement context under token pressure instead of escalating blindly

## Goal
Keep broad implement runs bounded under token pressure by narrowing context on retry instead of simply increasing the per-turn budget.

## Acceptance
- Broad implement runs keep the existing hard budget on the first turn.
- A real persisted broad implement run can take one bounded file-only retry after `budget.per_turn_input_exceeded`.
- If the file-only retry proves one more file is required, Symphony can take one bounded second retry with exactly one explicit expansion path.
- Broad retry logic does not steal scoped review-fix or explicit CI-failure recovery work.
- Exhausted broad retries stop with a broad-mode-specific rule instead of the generic budget rule.

## Plan
- Detect true broad implement runs from persisted run state instead of treating all implement-stage budget stops the same.
- Persist a bounded broad-mode retry state in `resume_context`.
- Build a narrower broad implement retry prompt in `DeliveryEngine`.
- Auto-reschedule the first broad retry without increasing the cap.
- Allow one explicit bounded second retry when the first focused file surfaces one exact next required path.
- Stop on a specific broad-mode rule if the file-only retry is insufficient or the bounded expansion retry still overruns the budget.

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
- Tightened the broad retry prompt again so a retry with `target_paths` no longer repeats the last implementation summary or dirty-file list, and the focus line now explicitly tells the model to stay inside the chosen file unless a directly adjacent helper is required.
- Tightened persisted broad continuity so `already_learned` becomes a compact execution rule once `target_paths` exist, instead of repeating a long natural-language summary that the retry turn does not need to rediscover.
- Normalized retry target paths so basename duplicates such as `delivery_engine.ex` are dropped once the full repo path is already known, keeping the broad retry state smaller and less ambiguous.
- Added direct regression coverage for the new broad retry lane, the CI-recovery exclusion, the new stop rule, and the narrowed prompt text.
- Found the live completion seam: worker shutdown was still falling through to the generic budget stop because the broad retry gate required persisted `run_state.stage == "implement"` even when the live `dispatch_stage` was already `implement`.
- Relaxed that gate to trust the live implement dispatch stage and added a regression for a stale persisted blocked state on retry.
- Replaced the old “smallest path cluster” retry contract with a stricter two-step lane: the first broad retry now collapses to one exact target file, and only a later retry that surfaces one exact `next_required_path` can expand to two files.
- Added two new broad-mode stop rules so operators can distinguish “one file was not enough” from “the one-file expansion retry was still exhausted.”
- Tightened the broad retry prompt to remove the old “adjacent helper” guidance and instead tell the model to stay inside one file, or two explicitly approved files, with no heuristic expansion language.
- Fixed the blocked-state persistence seam in `RunPolicy.stop_issue/3` so budget stops preserve the already-persisted retry `resume_context` at the top level instead of dropping it while transitioning the workspace to `blocked`.
- Preserved `next_required_path` through bounded broad-expansion exhaustion so a blocked workspace can resume with the same exact second-file request instead of losing it to the generic blocked-state shell.
- Fixed the stale broad retry counter seam so an operator-driven replay with an already-known `next_required_path` can still take the bounded second-file expansion instead of being trapped forever in repeated file-only `focus_insufficient` stops.
- Normalized diff-style `a/...` and `b/...` file markers out of broad retry target extraction when the same repo path is already known, so live `target_paths` no longer re-inflate from patch-format noise.
- Removed the last broad-retry fallback wording about heuristic helper expansion and kept the runtime hint aligned to the explicit file list for the bounded retry lane.

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
- After restarting the canary on committed head `26c2586`, the live `CLZ-32` retry preserved `target_paths = ["elixir/lib/symphony_elixir/delivery_engine.ex", "delivery_engine.ex"]` and a non-empty `already_learned` block across the stop/redispatch boundary instead of dropping them back to `null`.
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/orchestrator_controls_phase6_test.exs:2269 test/symphony_elixir/orchestrator_controls_phase6_test.exs:2323 test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs`
- Tightened prompt-shaping follow-up:
  `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs`
- Live replay after the prompt-tightening follow-up reduced the narrowed broad retry to observed input `130231` while still stopping on `budget.broad_implement_scope_exhausted`; the remaining gap is now the last ~10k of broad retry overhead, not missing retry continuity.
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/rule_catalog_test.exs`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix harness.check`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix escript.build`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/rule_catalog_test.exs`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix harness.check`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix escript.build`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/rule_catalog_test.exs`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix harness.check`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix escript.build`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix test test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/rule_catalog_test.exs`
- `cd /Users/gaspar/src/symphony-clz-32/elixir && mise exec -- mix harness.check`
- Live replay on the restarted `http://127.0.0.1:4046` canary at committed head `d5ee432` ended with:
  - `rule_id = budget.broad_implement_expansion_exhausted`
  - `budget_last_observed_input_tokens = 126182`
  - `target_paths = ["elixir/lib/symphony_elixir/delivery_engine.ex", ".github/pull_request_template.md"]`
  - `already_learned = "Stay inside elixir/lib/symphony_elixir/delivery_engine.ex, .github/pull_request_template.md and avoid unrelated reads or repo-wide rediscovery."`
- That live blocked state proves the diff-marker pollution is gone after restarting the runner on the new code; the remaining gap is now only the last ~6k above the bounded two-file hard cap.

## Next Step
Trim the remaining two-file expansion overhead so the bounded `delivery_engine.ex` plus `.github/pull_request_template.md` retry can finish under the `120k` hard cap instead of stopping at `126182`.
