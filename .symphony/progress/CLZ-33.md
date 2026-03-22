# CLZ-33: Document runner control endpoints in dogfood runbooks

## Goal
Prove that merged `main` can run an unattended Symphony ticket-to-merge lane without requiring manual babysitting, using a small docs-scoped proof ticket.

## Plan
- Promote a merged-main canary runner and observe it claiming a proof ticket.
- Verify live operator surfaces (`/api/v1/state`) remain healthy during the run.
- Fix any presenter crashes discovered during the proof run.

## Acceptance
- A fresh merged-main dogfood runner can claim a proof ticket from Linear and expose healthy operator state while it works.
- The live operator surfaces stay readable during the proof run.
- The proof ticket can proceed through normal autonomous repo work once the runner is healthy.

## Work Log
- On March 19, 2026, promoted an isolated merged-main canary from commit `9250f9bd2602ef3269dc04072c5366a2b4e62c4d` into `/tmp/symphony-runner-mainproof` with the canary label `canary:mainproof`.
- Launched a separate dogfood runner on `http://127.0.0.1:4047` using the merged-main temp clone, isolated workspaces under `/tmp/symphony-workspaces-mainproof`, and an isolated Codex home under `/tmp/symphony-codex-home-mainproof`.
- The fresh runner immediately claimed `CLZ-30` instead of the new proof ticket `CLZ-33`, which showed that the proof lane still needs tighter routing isolation, but it also gave a real merged-main run to observe.
- Live `GET /api/v1/state` on the merged-main runner failed with `500 Internal Server Error`. The runner log in `/tmp/symphony-dogfood-mainproof-logs/log/symphony.log.1` showed a `BadMapError` in `SymphonyElixirWeb.Presenter.lease_payload/1` because a skipped entry carried `lease: nil`.
- Fixed `Presenter.lease_payload/1` to tolerate `lease: nil` and added focused presenter coverage so skipped entries without lease metadata no longer crash the state payload.

## Validation
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test test/symphony_elixir/web_phase6_backfill_test.exs`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix harness.check`

## Evidence
- Merged-main proof runner inspect payload shows `runner_mode = "canary_active"` and `current_version_sha = "9250f9bd2602ef3269dc04072c5366a2b4e62c4d"` under `/tmp/symphony-runner-mainproof`.
- Live runner log captured the exact `/api/v1/state` crash:
  - `BadMapError expected a map, got nil`
  - `SymphonyElixirWeb.Presenter.lease_payload/1`
  - request path `/api/v1/state`
- Focused presenter coverage now proves a skipped entry with `lease: nil` still renders through `Presenter.state_payload/2`.

## Next Step
- Rebuild the merged-main runner from the patched repo and replay the isolated proof lane so `CLZ-33` can be claimed and observed through a healthy `/api/v1/state` surface.
