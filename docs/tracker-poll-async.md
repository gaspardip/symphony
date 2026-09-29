# Tracker polling outside the coordinator

This change moves the reads used by startup cleanup and scheduled polling into `TrackerReader`. It does not make every tracker or GitHub operation asynchronous.

A cycle has one active read. Startup reads terminal issues. Discovery and healing read running issue IDs, approval states, and candidates in sequence. Tracker and GitHub notifications retain the existing notice → scheduled cycle-message boundary. Notices received while a read is held add a pending mode once; completing the cycle processes pending modes before scheduling the next interval for that mode.

The reader captures only read arguments and a `Config.TrackerReadContext`. The context includes the policy pack from the same validated options capture used for the tracker configuration. The coordinator keeps the operation reference, fingerprint, running-worker identities, backoff identity, and a set of issues invalidated during that cycle. It does not send State, claims, a state mutation, or credentials into an application continuation in the reader.

Results are applied by the coordinator against its current State:

- A result with another reference or configuration fingerprint is ignored or diagnosed, without applying its issues.
- Running issue data applies only if PID, monitor reference, lease owner and lease epoch still match the captured entry.
- Stop, pause, hold, resume and policy changes invalidate the affected issue for the active cycle. Priority changes stay in current State and do not hide the issue from candidates.
- A changed backoff identity discards the old remote component. Independent manual results remain usable. Manual success never clears tracker throttling; the current backoff diagnostic is retained at completion.
- A terminal cleanup result cannot remove a workspace with a current local worker, claim, retry, pause, or persisted lease. Workspace and audit guards still execute. This is not a new distributed cleanup reservation.
- Read errors and reader DOWN are diagnostic outcomes, not evidence that a worker has become terminal. They preserve current workers.

Configuration rejection retains the existing `config_invalid` audit event, actor, dispatch mode and error log. GitHub draining remains permitted when runner health blocks new dispatch, and its health diagnostic is retained. Candidate processing with zero capacity still updates the candidate list without starting a worker.

`TrackerReader` reports data only after its I/O child has terminated. Its guardian monitors the coordinator and terminates its own read child when the coordinator disappears. The closure must not trap exits or detach work; this is not a general guarantee for arbitrary transport descendants.

## Ordinary pre-dispatch admission (C1)

Discovery and healing candidate batches now keep one additional `TrackerReader`
for active pre-dispatch refresh, before acquiring any lease. This is a global
limit: one admission read plus the existing polling read, independent of issue
count. The coordinator retains the sorted remainder of one batch. Later polls
refresh the dashboard candidates but do not append, replace or restart that
cursor. Missing, ineligible, failed or obsolete issue A advances to issue B;
configuration changes discard the entire old batch. Exhausted capacity drops
remaining candidates until a subsequent poll.

The admission reader receives only the requested ID and fixed configuration
context. Its response must contain exactly that issue ID and identifier. The
coordinator checks the operation reference, context fingerprint, controls applied
during the batch, current worker/claim/retry, runner health, backoff, routing,
policy and capacity. Stop, pause, hold, resume and policy controls invalidate the
matching admission even after the polling cycle has completed. A newer successful
webhook lookup (including a missing issue) invalidates its older pending admission.
Worker admission
also invalidates older pending data for that issue. Obsolete replies cannot
acquire or release a lease, stop a newer worker or clean its workspace.

A current result re-enters the existing runtime admission guards, including
persisted token consumption, unreadable snapshots and pending dispatch/deploy
audits. Only then can it acquire a lease and authorize a gated worker. Read
errors and reader DOWN are diagnosed and advance the cursor; a remote 429 keeps
the tracker backoff and prevents further remote admission while it applies, even
if a stop or pause has made the refreshed issue obsolete. A changed backoff
identity still prevents an older transport response from replacing that decision.
Pending reads and discard reasons are logged with the issue ID.

`orchestrator_admission_async_test.exs` exercises the real coordinator using
message barriers, local leases and synthetic tracker callbacks. Availability is
limited to the held pre-lease read. No LSP tool was available for implementation;
compilation, specs, tests and Dialyzer remain separate verification gates.

## Retry admission (C2)

Retry timers carry a generation reference. Only the matching scheduled entry can
become ready; an old, duplicate or unversioned message has no effect. Entries stay
in `retry_attempts` through lookup and refresh, preserving attempt, issue envelope
and budget resume context. A successful worker consumes its entry; errors replace
only the current generation. Metadata cannot overwrite scheduler-owned fields.

Ready retries share C1's single admission reader. The coordinator alternates one
logical poll admission and one ready retry, ordered by due time and issue ID within
retries. An ordinary retry performs candidate lookup followed by active pre-lease
refresh in the same logical turn. A passive continuation uses an individual lookup.
The two phases are serial, and the existing B reader remains independent: at most
one admission/retry reader plus one polling reader. Waiting for this slot does not
increment attempts or accumulate another queue.

Responses must match the timer and reader references, issue ID and identifier,
configuration and observed lease identity. Controls and newer webhook observations
invalidate retries even when no C1 batch exists. Current state supplies running
workers, pauses, routing, capacity, token budgets and audit guards. The retry's own
metadata and claim remain present while these checks run. Review-budget continuation
keeps its second authorization check under the existing lease acquisition boundary.
I1 still validates persisted issue identity before lease synchronization.
Refresh identity is checked on the raw singleton response before merging optional
fields; missing IDs cannot inherit the requested identity. Timer selection and
current results refresh the cached global capacity from validated configuration
without renewing unrelated workers' leases. A timer arriving while the shared
reader is occupied marks readiness only, preserving that reader's batch even if
configuration is temporarily invalid.

Current lookup errors, reader DOWN and pre-lease refresh errors reschedule once with
attempt + 1 and retained metadata. Rescheduling refresh errors explicitly fixes the
previous path that could abandon a retry after removing its entry. Changed context,
invalidation or newer backoff rearms a surviving generation without increasing its
attempt. This timer-only rearm does not persist old resume context into a newly
configured workspace. Configuration changes also discard any waiting C1 cursor.
Stop or a replacement retry makes the old callback unable to remove the new entry.

Remote and manual candidate outcomes remain separate. A remote 429 updates backoff
even when the issue was stopped; manual success never clears that throttle. Ready
remote retries wait until backoff permits reading, without counting another attempt.
Manual retries can use their existing validated seeded-issue fallback. Terminal or
missing replies cannot clean a workspace with a newer worker or observed lease.
Atomic lease generation fencing and passive-to-active reads after acquisition remain
C3, so this check is not a distributed reservation across cleanup operations.

`orchestrator_retry_async_test.exs` covers held lookup and refresh, timer races,
arbitration with C1/B, current versus obsolete errors, webhook/control invalidation,
capacity, ownership and I1 composition. Existing retry fixtures now retain a test
coordinator until its real callbacks complete; production has no synchronous retry
compatibility path or unversioned-message executor.

## Remaining synchronous work

Webhook/GitHub event processing, immediate controls, pre-dispatch revalidation from those entry points, tracker mutations and local business effects still use their existing paths. Applying read results can call those paths. An injected slow operation there can still occupy the coordinator. Configuration lookup remains a WorkflowStore call; an invalid file that WorkflowStore has not adopted is not a new active configuration. This phase establishes availability during the selected reads only.

The new tests use closed tracker callbacks, local manual issues, real leases and controlled TaskSupervisor children. No external tracker, provider, Git operation or publication is needed. The backoff status test observes the real coordinator with its existing assertions and deadline. Manual submissions accepted during a held cycle queue discovery so that the accepted task is not delayed until the next polling interval.

## Inbox storage and synchronous confirmation (C4a)

The shared Tracker/GitHub storage now captures bounded physical prefixes and
acknowledges a cursor, replacing the numeric ack API. It fixes append/ack cursor
races without moving the event lookup or GitHub effects outside the coordinator.
Complete invalid rows have physical positions; a partial tail is retained and
blocks further append. State corruption and storage failures remain visible in
snapshot and dashboard instead of appearing as an empty queue.

A failed ack retains one applied-prefix cursor per inbox. A subsequent drain
attempts only that confirmation and returns, even if the configured root changed.
The retained location prevents confirming another root. Reset changes generation
and retires the old cursor without touching the new queue. After restart this
volatile evidence is absent, so processing remains at least once.

No C4b availability claim follows from this storage change. Webhook tracker lookup,
its second pre-dispatch validation, GitHub work and local effects remain synchronous;
429 retry wakeups and shared reader arbitration still require C4b after C3.


## Lease custody and passive promotion (C3)

New acquisitions return a generation token and the exact payload persisted under
its captured lease lock. The coordinator retains that token in independent local
custody across pending admission, gated/running workers and retries. Reading a
lease or a historical snapshot never creates authority. Owner-only legacy APIs
reject generation-bearing leases. Renewal, release and final gate activation
compare the full token under the original physical lock, including when the
configured root has changed.

A passive checkpoint repaired to active work reserves the shared C1/C2 admission
reader and one capacity slot. Its promotion deadline starts before acquisition
and remains bounded by half the captured TTL through the final gate lock.
Cancellation invalidates the operation immediately but retains the reader monitor
and capacity until termination is observed. Transfer to running retires the
promotion timer; stale timeout and reader callbacks cannot release new custody.
The independent B polling reader and C4a inbox cursors retain their contracts.

V2 release preserves the historical workspace and snapshot instead of clearing
lease metadata or deleting the workspace. This applies to terminal retry cleanup,
terminal running reconciliation and later startup cleanup of v2 snapshots. The
operator projection distinguishes live, historical, missing and unverified
ownership; historical metadata is never held/reclaimable authority. Legacy cleanup
retains its existing physical-lease checks without claiming a cross-process
transaction over workspace deletion. Pending audit/corrupt/IO outcomes remain
visible rather than being treated as missing.

C3 does not fence all effects after the gate, recover volatile custody after a
restart, or move webhook/GitHub/control business I/O to background readers.
Validation of this candidate remains pending until the recorded repository gates.

GitHub follow-up custody is bound to the explicit destination workspace. A local
claim from another root is rejected before its payload is lent or renewed; new
acquisitions capture their lease location and destination before waiting on the
lock. A rejected location does not fall back to a manual snapshot write.

Retry budget context follows the captured custody workspace after worker `DOWN`.
A retry/resume or gated dispatch rejects a current workspace/storage location that
conflicts with that custody before starting new work. `lease.released` is written
to the captured ledger path. Physical lease removal and ledger persistence are not
one transaction: if the latter fails, local custody is retired and
`lease_release_audit_failed` remains explicit; operator retry does not report
success or recreate the lease. Generic runtime events and post-gate provider effects
are not covered by this storage guarantee.
