# Deployment audit

Preview and production stages reserve a deployment before invoking the repository
command. A sibling directory, `.<workspace-name>.deploy-audit`, survives workspace
changes. Any remaining reservation, including unreadable or incomplete evidence,
blocks another deployment. Opening confirms a checked intent in the original ledger.

## Captured authority and legacy operations

An admitted execution opens a version 2 operation bound to its exact dispatch ticket,
complete physical lease token, canonical material witness and checked stage-entry
event. The worker derives execution provenance from its confirmed private invocation;
command output and caller attributes cannot supply authority or session identity.

A version 1 operation is permitted only with checked raw absence of run identity and
C3 ownership. Partial identity, pending evidence and read errors cannot become legacy.
New version 1 tickets retain the public legacy return shapes and marker format. Both
versions require the exact ticket, live reference and creating process. Tickets from
an earlier implementation or a dead process cannot be reconstructed or imported.

## One observation, then a separate continuation

The command runs outside the workspace lock. The first valid result consumes the
live ticket's observation attempt before event preparation, locking or writer IO.
The prepared event and its ID remain retained even if encoding or persistence fails.
A repeated call never prepares or writes another observation, even when an obstruction
is removed or the disk marker still says authorized. Death loses the live capability;
it does not make the durable reservation available for replay.

Custody permits one original result of the already authorized command to be recorded
when a later guard denies continuation. It does not permit another command, tracker
update or state transition. Version 2 receipts distinguish authority from persistence:
current, rejected or not checked; confirmed, marker-only, unconfirmed or not attempted.
A receipt is diagnostic evidence, never permission to continue. A failed result can
have partial effects and remains pending. Legacy observation preserves its existing
ordering before the subsequent raw-state check.

Context and continuation revalidate the original authority under one workspace lock.
A proven denial is retained as the first cause for that live operation; restoring
files does not restore permission. Invalid foreign tickets cannot poison its custody.
Checked CAS preserves fresh accounting and lease fields. Its version 2 receipt contains
the exact previous and persisted next material state and its own checked event, anchored
once in the same private operation entry. The worker retains it only after owner ACK.

Finish requires that exact own continuation and current successor, including the
captured physical lease. An unrelated event at the same destination is insufficient.
Own done uses terminal confirmation to close its journal; it never reopens execution.
Owner RPC occurs outside the workspace lock, and locked validators do not reacquire it.

## Pending evidence and inspection

Pending evidence blocks dispatch, retry, approvals, workspace hooks and cleanup.
A public stop may terminate the worker before it returns a command result; no observed
result is fabricated after its death. The dispatch journal may record legitimate
worker termination separately while the deployment reservation remains pending.

`DeployAudit.inspect_pending/1` checks the original marker and ledger and returns a
finite projection, without commands, output, full tokens or live capabilities.
Confirmed absence returns none. Corruption or uncertainty returns an explicit error.
Inspection does not repair files, recover ownership or remove a reservation.

Runtime stage transitions can record a checked `last_agent_session` reference in their
own confirmation and snapshot. It is historical diagnostic evidence, excluded from
the material permission witness; it cannot revive a retired session. Secondary error
logs retain causes and safe stack locations without formatting result or ticket args.

## Limits

The ledger records local observations. Shell, tracker and storage effects are not a
transaction, and a successful exit is not independent proof of a remote deployment.
A control can invalidate continuation after an already sent tracker update. No
compensation, retry, timeout cleanup or automatic reconciliation is introduced.

The public shell result maps success, failure and unavailability. A distinct observed
timeout is supported at the observation boundary; this change adds no shell deadline
or public timeout detection. If a worker dies before producing a result, effects may
remain unknown. Preserve the reservation and original ledger while investigating.

Exclusive directory creation reserves the operation across VMs; later mutations use
cooperating local locks. Arbitrary filesystem writers, concurrent live coordinators,
power-loss durability and global exactly-once effects require separate guarantees.
Test results, loaded builds and thesis acceptance require their own evidence.
