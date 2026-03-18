# CLZ-31: Add a repo-owned self-debug telemetry proof for live Symphony runs

## Goal
Prove that a live Symphony run can explain its own dispatch and retry control decisions end to end through repo-owned operator surfaces.

## Acceptance
- `retry_now` must stop collapsing to a generic success when dispatch never starts.
- The issue detail API must show the latest deferred-dispatch reason even when no `run_state.json` exists yet.
- Live dogfood replay on `CLZ-31` must either dispatch or explain the exact runtime gate that prevented dispatch.

## Plan
- Instrument `retry_issue_now_runtime/2` with explicit dispatch outcomes and reason metadata.
- Surface the latest control-path ledger decision in the presenter as a fallback when workspace state is absent.
- Replay `CLZ-31` on the canary runner and use the surfaced reason to continue the live diagnosis.

## Work Log
- On March 18, 2026, traced a live canary no-op on `POST /api/v1/CLZ-31/actions/retry_now`: the runner could see `CLZ-31` and the control returned `ok`, but no running entry, queue entry, retry entry, or stop reason appeared.
- Tightened `SymphonyElixir.Orchestrator.retry_issue_now_runtime/2` so `retry_now` now reports structured dispatch outcomes instead of always recording a generic success. Deferred retries now carry `dispatch_outcome`, `rule_id`, `failure_class`, `error`, and `human_action` in the control response and ledger event.
- Added concrete no-dispatch diagnostics for two common live control gaps:
  - `coordination.dispatch_slots_unavailable`
  - `coordination.retry_dispatch_deferred`
- Updated `SymphonyElixirWeb.Presenter` so issue detail payloads can fall back to the latest ledger decision when no workspace `run_state.json` exists yet, avoiding the old empty `Todo` shell after a deferred `retry_now`.
- Fixed the underlying live dispatch bug after the new telemetry exposed it: `revalidate_issue_for_dispatch/3` now merges state-only tracker refreshes back onto the original issue envelope before checking dispatch eligibility, so a partial refresh cannot strip required issue fields like `title` and incorrectly mark a valid `Todo` issue as ineligible.

## Validation
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/orchestrator_controls_phase6_test.exs test/symphony_elixir/web_phase6_backfill_test.exs test/symphony_elixir/rule_catalog_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix harness.check`

## Evidence
- Local focused control/presenter coverage is green after the telemetry and revalidation fixes.
- Live replay on `http://127.0.0.1:4046/api/v1/CLZ-31` now surfaces `coordination.retry_dispatch_deferred` with a concrete `why_here` and `human_action_required` instead of an empty `Todo` shell.
- An isolated probe under the live workflow confirmed `CLZ-31` is dispatchable when evaluated against the full tracker issue, which narrowed the remaining bug to partial revalidation data rather than labels, routing, or concurrency.

## Next Step
- Restart the runner on the latest local commit and replay `CLZ-31` again to verify that the merged revalidation envelope actually starts the live dispatch path instead of deferring it.
