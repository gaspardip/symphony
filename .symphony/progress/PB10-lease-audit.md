# PB10: audited lease takeover and uncertain-worker stop

## Goal

Prevent a stale-lease takeover from authorizing a worker before its audit is confirmed. Stop a running local worker when renewal reports pending or malformed ownership evidence, preserving that evidence for explicit diagnosis.

## Acceptance

Takeover records a checked intent, writes a pending candidate lease, records its prepared confirmation and only then finalizes acquisition. IDs are generated once. Pending prevents read, acquire, refresh, release and TTL reclamation. Explicit reconciliation recognizes only exact existing intent/confirmation records in the original ledger; it never replays a missing event.

Renewal distinguishes four ownership errors from the unchanged transient filesystem/lock behavior. For pending, malformed pending, corrupt JSON or a JSON non-object, it cancels retry and waits for local task DOWN. Confirmed stop removes running but retains the claim, lease, snapshot, workspace and dispatch journal. It neither closes the dispatch audit nor releases ownership. An unconfirmed stop retains running with an explicit diagnostic.

The legacy invalid-JSON fixtures now require `%Jason.DecodeError{}` for malformed JSON and `:invalid_lease` for valid JSON non-objects. Byte preservation and lock cleanup remain asserted. The backfill fixture restores a valid lease before verifying the unchanged ownerless release behavior. This implements the approved fail-closed release contract rather than removing or relaxing a failing assertion.

## Plan

Add checked takeover admission and exact reconciliation; route uncertain refresh errors through confirmed local termination; test failure boundaries and delayed termination before running the full repository gates and the existing PB05 protocol.

## Work Log

Integrated the audited lease protocol and the four explicit uncertainty classes. Review then found that an unconfirmed stop could enter normal completion through a late DOWN. The running entry now retains its uncertainty reason; late DOWN, repeated stop and a later healthy lease read cannot finish its journal, release ownership or retry. Two real-process regressions fail against the previous source and pass with the correction. The literal 86400 in one new test was formatted as 86_400 to satisfy lint without changing its value or assertions.

## Evidence

- Takeover candidate: 13 tests passed in `run-20260923T145225768558Z`; a separate ordering regression fails against the original code and passes against the candidate. Two independent-BEAM campaigns produce one winning takeover and preserve a pending lease against competing acquire/release. Four processes exit normally.
- Refresh candidate: `run-20260923T151621868333Z` has six tests. The original renewal behavior fails the four expected DOWN checks; the candidate passes all six, including the two compatibility cases. Tests use real local modules and controlled worker processes, with no external provider or running Orchestrator scheduler.
- Independent review found the late-DOWN defect described above; its two regressions passed after correction. Candidate red/green runs used isolated evidence directories.
- Integrated targeted selection: 34 tests passed, including takeover, concurrent lease operations, six renewal cases, two delayed-termination regressions and dispatch interactions. Format, lint/specs, Dialyzer (179 existing exclusions; 12 unnecessary skips) and dev build passed. The isolated repository harness also passed.

- Final full suite: 1,222 tests, zero failures, seed 0, 434.9 seconds. Native coverage: 81.38%, above unchanged 79% global and 70% core thresholds. All 212 source/test hashes match the tested worktree; no owned test workers or registered test processes remained.
- PB05 E2 repeated on frozen final source/BEAMs: 60/60 checks, three two-VM repetitions, six normal VM exits and twelve owned processes confirmed absent. Bundle: `trabajo/cierre-actual/PB05/run-20260923T124152-40684` in the thesis workspace. No external tracker or provider was used.
- The prior full run had two failures: an old corrupt-release expectation corrected to the approved contract, and a missing concurrency signal within 100 ms. The latter's exact cause remains unconfirmed. Its source, timeout and assertions were unchanged; the focused five tests and final full suite passed. Both runs remain in `PB10/lease-audit/full-final.log` and `full-final-2.log` in the thesis workspace.

## Next Step

Continue the remaining legacy audit and external-effect boundaries, stable execution identity and formal case campaigns. This local checkpoint does not close global PB10 or the thesis.

## Limits

An orphaned filesystem lock blocks reconciliation and is never cleared automatically. Atomic lease replacement and checked ledger sync do not form a multi-file transaction or prove directory durability after power loss. This does not fence an old remote provider, cancel an external side effect, establish distributed exactly-once execution or migrate all remaining legacy ledger callers. Global PB10 acceptance remains separate. See [the lease contract](../../docs/lease-exclusion.md).
