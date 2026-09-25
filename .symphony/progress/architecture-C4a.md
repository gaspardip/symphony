# Architecture C4a: checked inbox storage

## Goal

Implement checked storage for Tracker and GitHub inboxes independently of C3 and
C4b. Preserve synchronous event policy while replacing numeric acknowledgement.

## Acceptance

Generation-bound physical cursors, a common filesystem lock for all new writers,
atomic state publication, explicit errors/migration, safe logical reset and bounded
capture. Applied prefixes retain pending acknowledgement without repeating effects
in the live owner. No payload leakage, automatic repair or exactly-once claim.

## Plan

Implement the shared storage boundary and migrate both synchronous drains. Preserve
existing webhook assertions, add storage/owner regressions, review the frozen diff,
then validate only in the coordinator-assigned isolated slot after composing C2.

## Work Log

The five approved source files contain the implementation. Numeric ack's production
callers and its direct existing assertion migrate to captured cursors. New suites
are event_inbox_checked_test.exs and orchestrator_inbox_ack_test.exs. IO faults use
five explicit stdlib callbacks per call, with defaults in real wrappers; no global
injection or test-only product wrapper. Exceptions preserve their cause while file,
temporary and lock cleanup still run. Controller error projection is sanitized at
the wrapper boundary. Cleanup details are projected as JSON-safe objects so a
secondary close/unlock failure cannot break the error response. The real sync/close
fault regression also encodes that public projection. No controller edit is needed.

## Evidence

The initial review was static; no callable LSP tool was available. After composing
B1, explicit formatting, format check, lint and the early harness passed. Storage
and owner tests passed 39/0, including the child VM; compatibility passed 185/0.
Both test runs ended without residual workers or registered test processes.
Full, coverage, Dialyzer and build remain pending at this freeze. Their final
results and source manifests are recorded externally under validation/c4a.

The coordinator approved the direct
isolated child Elixir command, with one scheduler, one async thread, only candidate
and Jason code paths, a fixed storage fixture and a 10-second watchdog. It ran
within the allocated validation slot. Its assertions record bytes, offset and
dedupe after each process phase; process exit alone is not storage verification.

## Next Step

Independent review and composition are complete. Freeze after this evidence note,
then execute full and the remaining repository gates. C4b async continuation, C3 leases, I2 accounting,
compaction, real inbox migration and automatic repair remain outside this patch.
