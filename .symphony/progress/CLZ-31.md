# CLZ-31: Add a repo-owned self-debug telemetry proof for live Symphony runs

## Goal
Prove that a live Symphony run can explain its own dispatch and retry control decisions end to end through repo-owned operator surfaces.

## Work Log
- On March 18, 2026, traced a live canary no-op on `POST /api/v1/CLZ-31/actions/retry_now`: the runner could see `CLZ-31` and the control returned `ok`, but no running entry, queue entry, retry entry, or stop reason appeared.
- Tightened `SymphonyElixir.Orchestrator.retry_issue_now_runtime/2` so `retry_now` now reports structured dispatch outcomes instead of always recording a generic success. Deferred retries now carry `dispatch_outcome`, `rule_id`, `failure_class`, `error`, and `human_action` in the control response and ledger event.
- Added concrete no-dispatch diagnostics for two common live control gaps:
  - `coordination.dispatch_slots_unavailable`
  - `coordination.retry_dispatch_deferred`
- Updated `SymphonyElixirWeb.Presenter` so issue detail payloads can fall back to the latest ledger decision when no workspace `run_state.json` exists yet, avoiding the old empty `Todo` shell after a deferred `retry_now`.

## Validation
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/orchestrator_controls_phase6_test.exs test/symphony_elixir/web_phase6_backfill_test.exs test/symphony_elixir/rule_catalog_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix harness.check`

## Next
- Rebuild the escript, restart the main dogfood runner on `:4046`, replay `CLZ-31`, and confirm the issue API now shows the concrete deferred-dispatch reason when the retry path cannot start a worker immediately.
