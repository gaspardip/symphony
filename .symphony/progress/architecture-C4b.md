## Goal

Move Linear webhook lookup and active revalidation into the existing two reader
slots while retaining checked physical order, C3 custody and explicit completion.

## Acceptance

A retained lookup does not block coordinator snapshots or worker messages. One
bounded head shares admission fairly with poll/retry, preserves promotion custody
and waits for actual gate authorization before acknowledgment. Obsolete callbacks
cannot apply to a successor; cleanup debt remains visible and unacknowledged.

## Plan

Implement only the approved Orchestrator continuation, author callback-based
regressions, migrate existing asynchronous waits without weakening assertions,
review the static cut, compose current main and validate the exact combined tree.

## Work Log

Product changes are confined to Orchestrator. One bounded batch/head carries its
location, cursor, observation and decision reference through shared admission,
promotion and the real gate. Poll/retry/inbox rotation preserves C1/C2 cursors and
C3 deadlines. Cache publication follows the completed decision; prefix confirmation
is a separate correlated callback. Only 429 adds an autonomous wakeup, correlated
with its head and backoff identity and retired before a fresh lookup.

Release and audit outcomes are retained independently of candidate_fetch_error.
Known cleanup debt blocks that head even after physical lease removal. Primary
reader errors wait for another drain. New tests use actual callback barriers,
physical lease/inbox failures and real TaskSupervisor capacity rejection. Existing
inbox fixtures move their ack obstruction after application and wait for the
actual confirmation boundary.

## Evidence

Implementation base: 56d0073421a9c3656614be3ea5611b8100cf02a5. Composition
incorporated E1-proof main 4a328491e2ca255e573b56a48c2d26ebe5327cbf without
conflicts or changing the ten candidate files.
No callable LSP tool was available; source, specs and callers were inspected.
Product snapshots, independent static reviews and the requirement-to-test map
are external under validation/c4b. The first formatted cut passed compilation,
format and lint, then completed 96 focused tests with two failures. Its exact
source and failed output remain preserved. The ack fixture retained a running
refresh without answering it; it now answers that real prerequisite before
waiting for acknowledgment. The successor fixture compared snapshot bytes after
a subsequent poll legitimately refreshed lease metadata; it now holds the real
continuation, checks unchanged bytes and workers, then permits the fresh read.
Assertions and deadlines are preserved. These corrections require validation;
the failed run is not reclassified. Root owns composition/integration and the
validator owns the VM.

The corrected fixtures then passed all 96 focused cases. Dialyzer stopped at an
unreachable rate_limited clause: the generic drain now serves only GitHub, whose
row processor returns ok or drop. The obsolete clause was removed and its unused
accumulator marked accordingly. Linear backoff stays in the separate continuation;
tests, assertions and Dialyzer exclusions are unchanged. The type failure is
preserved, and this final source still requires validation.

That source passed 121 compatibility cases and 96 focused cases; the full suite
then completed 1,712 tests with one failure in an existing status test. Its isolated
46-test suite reproduced a checked-lock conflict: the test's pending_events read
contended with asynchronous acknowledgment. The fixture now waits for explicit
completed acknowledgment state while retaining the cache/flag assertions and
200 ms deadline, stops its own coordinator, then checks the same persisted empty
queue. This additional migration received independent review. Failed full and
diagnostic results remain preserved; the revised cut still requires all gates.

EventInbox, IssueSource, TrackerReader, Config and Controls are unchanged. No test
API, new dependency or external service is introduced. Local synchronous effects,
post-gate validity (I2), volatile-custody recovery (I3) and at-least-once replay after
restart retain their stated limits. Physical prefix validation is a boundary check,
not a distributed transaction with reset.

## Next Step

Validate the corrected fixtures, then complete compatibility and all repository
gates in the assigned isolated slot.
Preserve any failure and its exact source manifest; integrate only the validated
combined tree. Remote publication and final thesis acceptance remain separate.
