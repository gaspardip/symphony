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

## Remaining synchronous work

Webhook/GitHub event processing, retries, immediate controls, pre-dispatch revalidation, tracker mutations and local business effects still use their existing paths. Applying read results can call those paths. An injected slow operation there can still occupy the coordinator. Configuration lookup remains a WorkflowStore call; an invalid file that WorkflowStore has not adopted is not a new active configuration. This phase establishes availability during the selected reads only.

The new tests use closed tracker callbacks, local manual issues, real leases and controlled TaskSupervisor children. No external tracker, provider, Git operation or publication is needed. The backoff status test observes the real coordinator with its existing assertions and deadline. Manual submissions accepted during a held cycle queue discovery so that the accepted task is not delayed until the next polling interval.
