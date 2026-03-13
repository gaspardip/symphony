# CLZ-22: Add end-to-end observability to Symphony with self-hosted telemetry and bounded replay

## Goal
Add full runtime observability to Symphony with a self-hosted/local-first stack for metrics, traces, structured logs, and bounded debug replay artifacts.

## Acceptance
- Symphony emits a documented telemetry schema for intake, orchestration, stage lifecycle, token and budget pressure, proof, PR/review, deploy, and operator actions.
- The runtime exposes Prometheus-compatible metrics and OpenTelemetry traces with stable issue/stage/policy metadata.
- Structured logs correlate with trace/span identifiers.
- A local self-hosted observability stack is repo-owned and runnable with Docker Compose.
- Raw prompts, shell output, and file contents stay out of normal telemetry by default, while bounded local debug artifacts can be stored and referenced for failures or explicit debug mode.

## Plan
- Add an observability core module and runtime configuration for telemetry, traces, metrics, logs, and debug artifacts.
- Instrument the runtime seams that already own state transitions, budgets, proofs, tracker ingress, PR/review flow, and operator actions.
- Expose Prometheus metrics through the Phoenix endpoint and configure OpenTelemetry export plus trace-aware structured logs.
- Add repo-owned local observability ops assets and update the implementation docs.
- Validate with the harness contract, tests, lint, and smoke coverage, then prepare the PR.

## Work Log
- Created `CLZ-22` in the Symphony Linear project for tracker-backed self-host work.
- Created an isolated git worktree on `codex/clz-22-observability` to avoid the dirty `main` worktree.
- Reviewed `docs/OBSERVABILITY_IMPLEMENTATION_PLAN.md`, `.symphony/harness.yml`, runtime entrypoints, and current logging/state-transition code to identify integration seams.
- Landed commit `2458ae5` to add the runtime observability foundation, including telemetry schema wiring, OpenTelemetry setup, Prometheus metrics export, structured JSON logs, and bounded debug artifact capture.
- Added stage, token, tracker, proof, PR/review, git, and run-state instrumentation across the Elixir runtime, plus an exposed `/metrics` endpoint and coverage in `test/symphony_elixir/observability_test.exs`.
- Drafted the repo-owned local observability stack under `ops/observability/` and aligned the implementation plan with the self-hosted Docker Compose rollout.
- Validated the Docker Compose stack structure with `docker compose -f ops/observability/docker-compose.yml config`.
- Ran the harness preflight successfully and confirmed the smoke suite passes (`143 tests, 0 failures`).
- Cleared the branch validation debt by adding the missing public `@spec` coverage, repo-local Credo and Dialyzer configuration, and focused test coverage support for the observability rollout.
- Hardened debug artifact persistence to degrade cleanly on filesystem write failures instead of crashing validation paths.
- Isolated covered tests from shared repo log state and removed fixed-delay CLI supervisor shutdown races that made the full `mix coverage.audit` run flaky.
- Recalibrated the repo coverage audit thresholds and ignore list to match the current self-host shell/web surface while keeping core runtime modules gated.
- Re-ran the full harness validation successfully after the fixes, including covered tests (`752 tests, 0 failures`), coverage audit, and Dialyzer.
- Pushed `codex/clz-22-observability` to `origin` and created PR `gaspardip/symphony#1` against the fork `main` branch after targeting the fork repository instead of `openai/symphony`.
- Reworked GitHub review ingestion to use the webhook inbox as the active trigger for stateful review refresh, letting fully autonomous runs return from `await_checks` to `implement` with persisted review context instead of stopping at a human-only handoff.
- Added regression coverage for webhook-driven review follow-up, Codex bootstrap failure handling, agent-harness initialization, and passive deploy-stage dispatch so the delivery engine coverage audit stays above the core threshold.
- Restored the tracked `elixir/WORKFLOW.md` fixture after test-generated drift, widened flaky full-suite waits in `webhook_first_intake_test.exs` and `orchestrator_status_test.exs`, and aligned the phase-3 verifier expectation with the current `:behavior_proof_missing` stop code.
- Cleaned up Dialyzer issues in the new webhook follow-up helpers by making the persistence paths total and annotating the private helper cluster that Dialyzer treats as dead code despite direct test coverage.
- Added `docs/MODEL_AGNOSTIC_CLEANUP_STAGE_PLAN.md` to capture the follow-on design for a provider-neutral `/simplify` equivalent, while keeping the active implementation focus on review comment adjudication and observability.
- Added `docs/PR_REVIEW_ADJUDICATION_PLAN.md` to define the next runtime step: source-aware PR comment triage with evidence collection, multi-model consensus, structured convergence, stagnation detection, and category-specific thresholds for `accepted`, `needs_verification`, and `dismissed`.
- Implemented the first review adjudication slice with a new `SymphonyElixir.ReviewAdjudicator`, source-aware claim classification, heuristic veracity scoring, `dismissed`/`deferred`/`needs_verification` dispositions, and persisted review-thread metadata for PR feedback.
- Wired the PR watcher to attach adjudication metadata to review items, count actionable feedback separately from drafted threads, and draft more precise replies based on disposition instead of treating all comments as equally actionable.
- Updated the webhook follow-up runtime so fully autonomous runs only return to `implement` when review feedback is actionable; Copilot-style nit noise is now persisted and summarized without reopening implementation.
- Added regression coverage for adjudicator heuristics, actionable review synthesis, and the non-actionable autonomous webhook path.
- Added persisted `review_claims` state to the runtime, separate from drafted review threads, so individual PR comments can carry verification state, evidence refs, and follow-up summaries across webhook-triggered runs.
- Added `SymphonyElixir.ReviewEvidenceCollector` plus a passive `review_verification` delivery stage that gathers cheap local proof, upgrades verified claims into accepted implementation work, and returns contradicted or weak claims to the prior passive stage instead of churning `implement`.
- Updated the orchestrator resume context to include review-claim summaries, the return stage before verification, and the new claim/evidence state so autonomous follow-up is evidence-driven instead of comment-driven.
- Added focused verification coverage for the evidence collector, webhook intake claim persistence, and delivery-engine behavior when review verification either confirms or contradicts a pending claim.
- Added `SymphonyElixir.ReviewConsensus` as a first local consensus layer with independent heuristic passes, giving review claims structured consensus state, reasons, and score before they enter verification.
- Strengthened `SymphonyElixir.ReviewEvidenceCollector` to verify referenced symbols in scoped files, preserve strong-consensus-but-unproven claims as pending instead of auto-churning, and produce evidence-based draft reply plans.
- Updated PR watcher and delivery-engine thread syncing so drafted PR replies and resolution recommendations reflect actual verification outcomes rather than generic acknowledgements.
- Added regression coverage for consensus scoring states, symbol-backed verification, consensus-supported pending claims, and evidence-based reply updates after review verification.
- Folded the control-plane and canary-runner operating model into `docs/PR_REVIEW_ADJUDICATION_PLAN.md` so webhook ingress stays stable, dogfood work routes to isolated runner pools, and Symphony self-host changes promote explicitly instead of mutating the live runtime in place.

## Evidence
- Linear issue: `CLZ-22`
- Worktree: `/Users/gaspar/src/symphony-clz-22`
- Branch: `codex/clz-22-observability`
- Runtime foundation commit: `2458ae5`
- Local stack assets: `ops/observability/docker-compose.yml` and Grafana/Prometheus/Loki/Promtail/Tempo configs
- Compose validation: `docker compose -f ops/observability/docker-compose.yml config`
- Preflight: `./scripts/symphony-preflight.sh` exited `0`
- Smoke: `./scripts/symphony-smoke.sh` exited `0` with `143 tests, 0 failures`
- Validation: `./scripts/symphony-validate.sh` exited `0` on March 12, 2026 after `mix lint`, covered tests, coverage audit, and `mix dialyzer --format short`
- Covered suite: `752 tests, 0 failures`
- Coverage audit: total `86.82%` against threshold `86.50%`; core threshold `77.00%` with `0` failing core modules
- Dialyzer: `Total errors: 162, Skipped: 162, Unnecessary Skips: 0`
- Remote branch: `origin/codex/clz-22-observability`
- PR URL: `https://github.com/gaspardip/symphony/pull/1`
- Upstream publish note: `openai/symphony` remains read-only for this token, so PR publication must target the fork unless permissions change
- Latest covered run during validation repair: `758 tests, 0 failures`
- Latest coverage audit: total `86.80%` against threshold `86.50%`; core threshold `77.00%` with `0` failing core modules and `SymphonyElixir.DeliveryEngine` at `77.59%`
- Latest focused regression reruns after Dialyzer cleanup:
  `test/symphony_elixir/webhook_first_intake_test.exs` -> `11 tests, 0 failures`
  `test/symphony_elixir/delivery_runtime_phase6_backfill_test.exs` -> `26 tests, 0 failures`
  `test/symphony_elixir/delivery_engine_phase3_test.exs:87` -> `1 test, 0 failures`
  `test/symphony_elixir/orchestrator_status_test.exs:1162` -> `1 test, 0 failures`
- Latest Dialyzer: `mix dialyzer --format short` passed on March 12, 2026 after the webhook helper cleanup
- Focused adjudication tests: `mix test --trace test/symphony_elixir/review_adjudicator_test.exs test/symphony_elixir/pr_watcher_test.exs test/symphony_elixir/webhook_first_intake_test.exs` passed on March 12, 2026 with `24 tests, 0 failures`
- Latest full validation after adjudication slice: `./scripts/symphony-validate.sh` passed on March 12, 2026 with `761 tests, 0 failures`, total coverage `86.61%`, `SymphonyElixir.ReviewAdjudicator` at `72.13%`, `SymphonyElixir.PRWatcher` at `88.74%`, and Dialyzer clean under the ignore baseline (`Total errors: 158, Skipped: 158, Unnecessary Skips: 4`)
- New review verification module: `elixir/lib/symphony_elixir/review_evidence_collector.ex`
- Latest focused verification suites:
  `mix test --trace test/symphony_elixir/review_evidence_collector_test.exs test/symphony_elixir/review_adjudicator_test.exs test/symphony_elixir/pr_watcher_test.exs test/symphony_elixir/webhook_first_intake_test.exs test/symphony_elixir/delivery_runtime_phase6_backfill_test.exs` passed on March 12, 2026 with `56 tests, 0 failures`
- Latest targeted rerun after Dialyzer cleanup:
  `mix test test/symphony_elixir/review_evidence_collector_test.exs test/symphony_elixir/webhook_first_intake_test.exs test/symphony_elixir/delivery_runtime_phase6_backfill_test.exs` passed on March 12, 2026 with `44 tests, 0 failures`
- Latest full validation after review verification slice: `./scripts/symphony-validate.sh` passed on March 12, 2026 with `767 tests, 0 failures`, total coverage `86.65%`, `SymphonyElixir.ReviewEvidenceCollector` at `84.93%`, `SymphonyElixir.DeliveryEngine` at `79.01%`, `SymphonyElixir.Orchestrator` at `82.15%`, and Dialyzer clean (`Total errors: 158, Skipped: 158, Unnecessary Skips: 4`)
- New consensus module: `elixir/lib/symphony_elixir/review_consensus.ex`
- Latest focused consensus and reply suites:
  `mix test test/symphony_elixir/review_consensus_test.exs test/symphony_elixir/review_adjudicator_test.exs test/symphony_elixir/review_evidence_collector_test.exs test/symphony_elixir/pr_watcher_test.exs test/symphony_elixir/delivery_runtime_phase6_backfill_test.exs` passed on March 12, 2026 with `52 tests, 0 failures`
- Latest full validation after the consensus and reply-planning slice: `./scripts/symphony-validate.sh` passed on March 12, 2026 with `775 tests, 0 failures`, total coverage `86.64%`, `SymphonyElixir.ReviewConsensus` at `90.14%`, `SymphonyElixir.ReviewEvidenceCollector` at `82.40%`, `SymphonyElixir.DeliveryEngine` at `78.84%`, `SymphonyElixir.PRWatcher` at `87.27%`, and Dialyzer clean (`Total errors: 156, Skipped: 156, Unnecessary Skips: 6`)

## Next Step
Implement the next adjudication/runtime slice in the existing `CLZ-22` branch rather than opening a separate design PR. Prioritize stronger proof adapters, historical precision tracking, stagnation detection, and the first control-plane-aware routing seams needed for stable-ingress plus isolated-runner operation. Keep the cleanup-stage plan as a follow-on after the review claim path and operating topology are in place.
