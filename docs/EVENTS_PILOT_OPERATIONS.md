# Events Pilot Operations

This runbook covers the first end-to-end pilot of the runtime-owned Symphony fork against
[`events`](/Users/gaspar/src/events).

## Pilot Model

- One Linear project: `Events`
- Project slugId: `fb8998440d1d`
- Two routing lanes:
  - `events-simple`: fully autonomous, auto-merge on green
  - `events-complex`: publish and verify, then stop at `Human Review`
- Ticket routing labels:
  - `symphony:events`
  - `lane:simple`
  - `lane:complex`
- Optional policy labels:
  - `policy:fully-autonomous`
  - `policy:review-required`
  - `policy:never-automerge`

Current status:

- all required routing and policy labels have been created in Linear for the `CYLIZE` team

## Required Linear Workflow

Current `CYLIZE` team states already present:

- `Backlog`
- `Todo`
- `In Progress`
- `Human Review`
- `Rework`
- `Merging`
- `Done`
- `Canceled`
- `Duplicate`

Pilot requirement:

- `Blocked`

Current status:

- `Blocked` has been created in Linear for the `CYLIZE` team.

Symphony active states for the pilot:

- `Todo`
- `In Progress`
- `Rework`
- `Merging`

Waiting states:

- `Human Review`
- `Blocked`

## Current Compatibility Findings

The host-side Xcode blocker has been cleared:

- `xcodebuild -list` now succeeds on the host
- the Symphony preflight script passes

The pilot harness now uses a dedicated shared Symphony scheme so validation avoids the UI test
bundle:

- project: `LocalEventsExplorer.xcodeproj`
- scheme: `LocalEventsExplorerSymphony`
- pilot base branch: `gaspar/harness-engineering`
- validation action: `build-for-testing`
- required GitHub check: `validate`

## Lane Launchers

Simple lane:

```bash
cd /Users/gaspar/src/symphony-local
./run-symphony-events-simple.sh --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Complex lane:

```bash
cd /Users/gaspar/src/symphony-local
./run-symphony-events-complex.sh --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Default lane ports and roots:

- simple:
  - port `4042`
  - workspace root `/Users/gaspar/code/symphony-workspaces-events-simple`
  - logs root `/Users/gaspar/.local/state/symphony-events-simple`
  - poll interval `15s`
- complex:
  - port `4043`
  - workspace root `/Users/gaspar/code/symphony-workspaces-events-complex`
  - logs root `/Users/gaspar/.local/state/symphony-events-complex`
  - poll interval `15s`

## Ticket Contract

A ticket is linked to Symphony only if all are true:

- it is in the `Events` Linear project
- it is in an active Symphony state
- it has `symphony:events`
- it has exactly one lane label: `lane:simple` or `lane:complex`

Write pilot tickets with:

- title
- clear description
- `Acceptance Criteria`
- optional `Validation`
- optional out-of-scope note

Use `lane:simple` only for deterministic, repo-local work. Avoid permissions-heavy tickets like
location/calendar/notifications for the first autonomous proof.

## Legacy Reset-Clean Inventory

Legacy issues previously touched by upstream-style Symphony and still in non-terminal states:

- `CLZ-10`
- `CLZ-11`
- `CLZ-12`
- `CLZ-13`
- `CLZ-14`

Current status:

- all five have been moved to `Backlog`
- no matching GitHub PRs were found for those issue identifiers
- their old local workspaces were archived to:
  - `/Users/gaspar/code/symphony-workspaces-archive/events-pilot-reset-20260307-223118`

Reset-clean rule for the pilot:

- do not salvage these runs in place
- archive the old workspaces out of the active workspace root
- move the issues out of waiting states before requeueing them
- only add lane labels when the ticket is ready for a fresh run

## Operator Actions During The Pilot

Use these runtime controls only:

- `retry_now`
- `pause`
- `resume`
- `hold_for_human_review`
- `approve_for_merge`
- `set_policy_class`
- `clear_policy_override`

Complex lane normal path:

- `Todo -> In Progress -> Merging -> Human Review`
- then `approve_for_merge`
- then Symphony completes merge and post-merge verification

## What To Confirm In The Dashboard

For both lanes, confirm:

- current runtime stage is progressing
- branch and workspace are correct
- PR URL is attached
- required checks are detected
- verifier result is present
- final state becomes:
  - simple lane: `Done`
  - complex lane after approval: `Done`

For restart recovery, restart during `await_checks` and confirm:

- the same PR is reused
- no duplicate merge happens
- the run resumes from persisted state instead of starting from `checkout`
