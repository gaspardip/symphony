# CLZ-16: Make the self-development harness mandatory for Symphony self-host runs

## Goal
Make the self-development harness the required contract for Symphony self-host runs in the Symphony project.

## Acceptance
- `initialize_harness` is a required runtime stage for Symphony self-runs before `implement`.
- `.symphony/harness.yml` includes a valid `agent_harness` section for the Symphony repo.
- `mix harness.check` is part of the official Symphony validation contract.
- Publish is blocked when required knowledge, progress, or feature artifacts are missing or stale.
- A self-host issue can be blocked with a concrete harness report before publish.

## Plan
- Add a strict `agent_harness` contract to the Symphony repo harness.
- Add the `initialize_harness` runtime stage ahead of `implement`.
- Add repo-tracked knowledge, progress, and feature artifacts for self-host runs.
- Add `mix harness.check` and make it part of the official validation contract.
- Enforce a publish gate that requires current progress and feature updates.
- Prove the path with targeted tests and a live self-host issue.

## Work Log
- Added `agent_harness` to `/.symphony/harness.yml` and validated it through `RepoHarness`.
- Added `SymphonyElixir.AgentHarness` plus runtime wiring so self-host runs execute `initialize_harness` before `implement`.
- Added `mix harness.check` and wired it into `./scripts/symphony-validate.sh` and the Elixir `Makefile`.
- Added required knowledge files under `/.symphony/knowledge`.
- Added repo-tracked feature metadata under `/.symphony/features`.
- Added publish-gate enforcement so self-host publishes fail when progress or feature artifacts are missing or stale.
- Added the thin root `AGENTS.md` index so the repo map stays discoverable without bloating the root instructions.
- Verified the full Symphony Elixir suite passes on the baseline branch before merge.
- Added a persisted review-fix token-budget state machine in `resume_context` so scoped PR-comment and CI-failure follow-up no longer rely only on `token_pressure: "high"`.
- Added adaptive review-fix caps, bounded per-issue total extension, and review-fix-specific stop rules in `RunPolicy` and `RuleCatalog`.
- Added automatic scoped retry scheduling in the orchestrator so review-fix budget stops can narrow and continue without an operator retry for the first recovery steps.
- Narrowed `implement` prompts for review-fix lanes to one scope batch with reduced resume context and operator-visible budget state in presenter payloads.
- Fixed the live worker-exit seam so review-fix budget enforcement still persists or auto-retries when the decisive token overrun is only visible at process completion.
- Fixed the live running-entry metadata seam by carrying `stage` and `workspace` into orchestrator running entries and falling back to persisted stage state in `RunPolicy`, so seeded review-fix retries are classified as `review_fix` in the real dogfood runtime instead of silently falling back to broad implement budgets.
- Fixed the issue API operator surface so top-level `stop_reason` mirrors the persisted blocked run state for review-fix exhaustion, instead of forcing operators to dig into nested publish/runtime fields.
- Added direct coverage for `WorkflowProfile`, `AuthorProfile`, and `Portfolio` normalization/aggregation paths so the adaptive-budget branch clears the repo coverage audit without changing runtime behavior again.
- Added direct `Portfolio` default-fetch coverage with live `200`, `503`, and `missing_url` branches so operator portfolio telemetry is exercised without a stubbed fetcher.
- Added a concrete `mix harness.check` malformed-base-branch regression so the task's list-formatted validation errors stay covered while lifting the repo audit floor.
- Added direct `CLI` manual-submit runtime coverage for real JSON loading, HTTP success, explicit API error messages, and unexpected status handling so the audit floor rises without touching adaptive-budget behavior.

## Evidence
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix harness.check`
- `cd /Users/gaspar/src/symphony && ./scripts/symphony-smoke.sh`
- Live self-host routing proof: the dogfood runner on `:4046` picked up `CLZ-16` from the Symphony Linear project with assignee-first routing.
- Live self-host failure proof: `CLZ-16` blocked on `budget.per_turn_input_exceeded`, proving the issue entered the self-host execution path with the new harness contract loaded.
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/rule_catalog_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_controls_phase6_test.exs test/symphony_elixir/web_phase6_backfill_test.exs test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix harness.check`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/policy_pr_verifier_phase6_backfill_test.exs test/symphony_elixir/orchestrator_controls_phase6_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix dialyzer --format short` still exits nonzero on the repo's existing warning baseline; this slice did not attempt to clear unrelated warnings.
- Live dogfood adaptive-budget proof on `http://127.0.0.1:4046`: after rebuilding `elixir/bin/symphony` with `mise exec -- mix escript.build`, seeded `CLZ-22` retries entered `budget_runtime.mode = "review_fix"` with the expected `120k` base cap, then auto-continued twice without manual intervention. The running issue payload advanced from `retry_count = 0` to `retry_count = 1` and then `retry_count = 2`, and the second live retry picked up the bounded `150k` hard cap / `5`-turn window (`budget_runtime.per_turn_input_hard = 150000`, `max_turns_in_window = 5`) instead of stopping immediately on the old generic `budget.per_turn_input_exceeded` path.
- Live dogfood exhaustion proof on `http://127.0.0.1:4046`: `CLZ-22` ultimately blocked with `budget.review_fix_scope_exhausted`, and the canonical workspace state plus the issue API now both expose the same structured stop reason (`review_fix_scope_exhausted`, `retry_count = 4`, `budget_last_observed_input_tokens = 242954`) instead of returning a top-level `null`.
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/portfolio_test.exs test/symphony_elixir/workflow_profile_test.exs test/symphony_elixir/author_profile_test.exs test/symphony_elixir/harness_check_task_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/harness_check_task_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/cli_phase6_extra_test.exs`

## Next Step
Publish the adaptive review-fix budget branch and let CI/review validate the live-proven retry and exhaustion behavior.
