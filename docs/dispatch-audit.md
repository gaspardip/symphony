# Audited dispatch

The orchestrator records admission before creating a worker that can execute work.
`dispatch.requested` records the request and its lease owner/epoch.
`dispatch.started` confirms authorization for a gated worker; it does not prove that
the worker has executed. These events carry the lease facts formerly recorded by
the separate legacy `lease.acquired` call at this dispatch boundary.

The worker waits while the orchestrator installs its running entry. A subsequent
callback checks the exact ticket, worker PID, current lease owner/epoch and recorded
authorization before opening the gate. There is no timeout that opens it. A guardian
cancels the worker when its orchestrator dies, including while the body is running.

## Pending admission

`DispatchAudit` reserves `.<workspace-name>.dispatch-audit` beside the workspace.
The journal survives snapshot changes, bootstrap and workspace removal. An empty,
invalid or incomplete journal blocks admission. The admitted worker receives scoped
local access to prepare its workspace; that access does not authorize cleanup or
preparation of a blocked/done snapshot.

Workspace lifecycle operations and admission hold the same local workspace lock.
An exclusive directory reservation also excludes competing admissions from other
cooperating VMs. Snapshot mutation and lifecycle serialization remain local to one
BEAM node; this is not a distributed transaction or a power-loss durability claim.

## Completion and cancellation

After observing worker exit, the owner records `dispatch.finished` before retiring
the journal or scheduling another attempt. Normal process exit is not task acceptance.
If authorization fails inside the worker, it exits with a distinct failure, preserves
the journal and receives no automatic retry, even if storage becomes readable again.

An operator stop terminates the worker before cleanup. A failed outcome write must
not prevent cancellation, but it preserves the journal and workspace and blocks
automatic retries. A known failure to create a worker closes as `not_started` only
after that outcome is recorded.

With the previous execution stopped, an operator may invoke
`DispatchAudit.reconcile_finished(workspace)` to retire a `finishing` journal whose
exact request, authorization and prepared final event already exist in its original
ledger. This never appends replacement events. Missing or mismatched evidence and
`prepared`/`authorized` journals remain blocked for investigation. Do not remove
the journal or change its status merely to unblock a retry.

Only the owning coordinator finishes its tickets. Reconciliation is an explicit
recovery operation after that execution has stopped; it must not race a live owner
or another VM performing reconciliation.

Local cancellation does not establish cancellation of a remote request or reverse
an external effect. Publication, merge, deployment and other legacy ledger callers
retain their separate validation and audit work.

## Durable logical run identity

Admission now binds each new `dispatch_id` to the snapshot's `run_id`. A retry or
new coordinator reuses that logical run; it receives a new dispatch identity.
Lease owner/epoch and the exact worker ticket still control authorization. Run
identity does not replace ownership or imply acceptance.

While holding the workspace lock and exclusive dispatch reservation, `RunIdentity`
records `run.identity.requested`, writes the identified snapshot with
`run_identity_pending`, records `run.identity.created` (no previous snapshot) or
`run.identity.adopted` (an existing snapshot without identity), and removes pending
through atomic file replacement. Only then can dispatch authorization be recorded.
The adoption is an explicit checked operation within authorized admission, never a
side effect of a read, default or render. Existing snapshots have unknown origin;
`adopted` does not claim when their historical execution began. Consumption, stage,
approvals and other snapshot fields are preserved, and old ledger bytes stay intact.

A new workspace contains only `.symphony/run_state.json` before worker creation.
The existing workspace bootstrap preserves that metadata while executing the
configured after-create hook, then restores it. The hook does not run during
identity creation. A failed write never yields a worker ticket. A failure after
identity persistence and before authorization retains the dispatch reservation;
it cannot silently start a second logical run.

The snapshot retains its identity confirmation event and original ledger path.
Admission and gated authorization check the exact issue, run, original ledger and
matching checked intent/confirmation. The confirmation records the initial and
previous snapshot digests; subsequent progress remains authoritative in the
snapshot, so that initial digest is not a checksum of later progress. Existing
snapshot writers preserve an omitted binding and reject a replacement binding or
contradictory issue. Missing, malformed or pending identity blocks authorization.
Finished/blocked snapshots retain the existing explicit-resume gate; starting a new
logical cycle for a finished issue is outside this contract.

There is no identity replay/reconciliation API in this unit. For future explicit
recovery, preserve the pending snapshot, dispatch reservation and original ledger.
Investigation needs the exact stored intent and confirmation, matching issue/run,
original ledger path, the identified snapshot digest (excluding pending), and
proof the previous owner/worker stopped. A missing confirmation must not be
manufactured; completing identity alone would not retire or authorize a pending
dispatch. This fail-closed boundary does not complete I3 recovery. Writes use local
atomic rename without directory fsync, and ordinary snapshot mutation is serialized
within one BEAM node; these are not a distributed transaction or a power-loss claim.

New dispatch journals use version 2, which requires the run identity binding.
Historical version 1 journals remain readable for exact completion/finishing
reconciliation against their original ledger, without adding run IDs to old events.
An authorized legacy journal cannot open a worker gate under the new runtime; its
missing run identity requires investigation, not implicit historical authorization.
