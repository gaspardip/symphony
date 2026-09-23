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
