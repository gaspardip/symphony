# PB10-C: audited dispatch

## Goal

Prevent an active or passive worker from executing before its authorization is durably recorded and its owner can track it. Preserve uncertain dispatches across cancellation and restart.

## Acceptance

- Failed admission creates no executable worker and schedules no automatic retry.
- The gate opens only after the running entry is installed and the recorded ticket and lease still match.
- Owner death cancels the local worker; incomplete journals survive bootstrap, retry and cleanup.
- Observed termination is recorded before retiring a journal. Explicit recovery recognizes an existing exact final event without replaying it.

## Plan

Add checked admission and a process gate; integrate both worker lanes and termination paths; protect lifecycle and automatic retry; verify failures with real processes and filesystem faults.

## Work Log

The original public dispatch path executed a real local hook despite an unreadable ledger in three isolated repetitions. The implementation introduces an external per-workspace journal and a guardian-backed gate. Review found and fixed a transient-authorization error reported as normal process exit and an automatic review retry that mutated a blocked snapshot before checking its journal. Malformed journal metadata now returns a typed error and preserves evidence.

Existing starter fixtures now acquire their real leases, and the direct worker fixture processes the queued authorization callback. Their assertions remain intact.

## Evidence

- 137 targeted and regression tests passed, including the 42 new process, persistence, integration, schema and retry cases.
- Independent restart probes passed six scenarios across twelve distinct BEAM processes, three repetitions each: uncertain admission remains blocked, and confirmed completion reconciles without any ledger append.
- Lint and public specs passed. Dialyzer passed with the unchanged existing exclusions (179 skipped warnings, 12 unnecessary skips).
- Full integrated suite: 1,201 tests, zero failures (seed 0), 382.9 seconds. Native coverage is 81.21%, above the unchanged 79% global and 70% core thresholds. Format, build and isolated harness passed. All 209 source/test hashes match the tested worktree; no test workers or registered test processes remained.
- The first full run exposed two compatibility regressions (shutdown signal and configuration-diagnostic ordering), both fixed in source. Its third failure came from overriding TMPDIR against a compile-time default; the final isolated run uses the normal temporary-directory setting. No assertions were weakened. Logs are retained in the thesis workspace under trabajo/cierre-actual/PB10/unidad-C, including full-2.log and coverage-final.log.

## Next Step

Migrate the remaining legacy audit boundaries after this locally validated checkpoint. This block does not establish task acceptance, remote effect cancellation, distributed closure, power-loss durability or full PB10 acceptance. See [the contract](../../docs/dispatch-audit.md).
