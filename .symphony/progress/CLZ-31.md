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
- Normalized Linear identifier lookups so `fetch_issue_by_identifier/1` now honors the same routing assignee filter as `fetch_issue_by_id/1` and `fetch_issue_states_by_ids/1`, eliminating the live mismatch where `/api/v1/CLZ-31` looked assigned while `retry_now` correctly deferred it as unroutable.
- Fixed the dogfood checkout bootstrap seam: if the orchestrator has already created a metadata-only workspace with `.symphony/run_state.json`, `Workspace.create_for_issue/1` now preserves `.symphony`, reruns the `after_create` hook against an empty directory, and restores the runtime state afterward so checkout hooks can still materialize the Git repo.
- Refined that bootstrap repair so restoring preserved `.symphony` state now merges runtime files back into the checked-out repo tree instead of replacing it, which keeps tracked repo files like `.symphony/harness.yml` available for pre-run policy enforcement.
- Removed the last live observability stall: issue detail and snapshot payloads now use a lightweight `RunInspector` mode that skips live `gh pr view` calls and falls back to persisted PR/check state from `run_state.json`, so active runs no longer wedge the operator API while rendering review metadata.
- Made `RunStateStore.load/1` resilient during metadata-only workspace bootstrap by reading staged `.bootstrap-*` runtime state when `.symphony/run_state.json` is temporarily parked outside the workspace, which keeps dispatch helpers and live issue reads from seeing a false `:missing` state mid-checkout.
- Relaxed direct spawn-path run-state seeding so orchestrator worker helpers can synthesize a minimal persisted run state when no lease-backed state exists yet, preserving test-only spawn coverage and claimed passive dispatch without forcing a lease round-trip.

## Validation
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/orchestrator_controls_phase6_test.exs test/symphony_elixir/web_phase6_backfill_test.exs test/symphony_elixir/rule_catalog_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/policy_runtime_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/phase6_coverage_backfill_test.exs test/symphony_elixir/web_phase6_backfill_test.exs test/symphony_elixir/recovery_and_lease_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/runtime_shell_phase6_backfill_test.exs test/symphony_elixir/orchestrator_controls_phase6_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix harness.check`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix escript.build`

## Evidence
- Local focused control/presenter coverage is green after the telemetry and revalidation fixes.
- Live replay on `http://127.0.0.1:4046/api/v1/CLZ-31` now surfaces `coordination.retry_dispatch_deferred` with a concrete `why_here` and `human_action_required` instead of an empty `Todo` shell.
- An isolated probe under the live workflow confirmed `CLZ-31` is dispatchable when evaluated against the full tracker issue, which narrowed the remaining bug to partial revalidation data rather than labels, routing, or concurrency.
- Focused Linear client coverage now proves identifier-based issue fetches carry `assigned_to_worker: false` when the configured routing assignee does not match, keeping issue detail payloads aligned with `retry_now` dispatch gating.
- Focused workspace coverage now proves a metadata-only workspace reruns `after_create` and preserves `.symphony/run_state.json`, matching the live self-host retry path after a `retry_now` dispatch.
- The workspace bootstrap regression now also proves checked-out `.symphony/harness.yml` survives the metadata restore, matching the live canary path that previously advanced from `checkout.missing_git` to `harness.missing`.
- Focused observability coverage now proves lightweight `RunInspector` reads skip `gh pr view`, and presenter issue payloads can rebuild review/check details from persisted run-state fields instead of shelling out live during API rendering.
- Focused recovery coverage now proves `RunStateStore.load/1` can read staged bootstrap metadata while a workspace rebuild is in progress, matching the dispatch-time bootstrap race from live dogfood.
- Live replay on `http://127.0.0.1:4046/api/v1/state` and `http://127.0.0.1:4046/api/v1/CLZ-31` now responds again while `CLZ-31` is blocked, and the issue detail payload renders a full operator summary instead of timing out in the controller.

## Next Step
- Use the restored live operator API on `CLZ-31` to continue the next end-to-end dogfood slice instead of debugging the HTTP controller path again.
