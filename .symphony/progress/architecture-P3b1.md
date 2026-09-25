# Architecture P3b.1: transport and delivery effects

## Goal

Move CLI local policy into the actual engine callers, preserve opaque sessions and
make verification independent of delivery preparation. Base 6d2250a (composed with integrated C2).

## Acceptance

Both CLI adapters return observations without runtime Git preparation, synthetic
delivery reports or normal final events. Engine delivery applies effects once,
with an explicit workspace. Verification does not synthesize delivery results or
prepare files. No progress evidence is fabricated. Failed transport skips preparation.

## Plan

Implement the approved 14-file contract, migrate P3a characterizations for deliberate
behavior changes, add real engine/verifier regressions, review the candidate, then
format and run focal/full gates in the assigned exclusive validation slot.

## Work Log

- Added the common result boundary with required delivery/verifier purpose and
  module-selected CLI observation validation. It keeps the synchronous callback
  process and moves the effect catch without recatching errors from error callbacks.
- DeliveryEngine passes workspace through both plan and implement callers.
  VerifierRunner retains its session cleanup. ErrorHandler /5 remains transport/log.
- Removed the concrete progress fallback and its private helpers. Preserved Git
  profile differences and existing command/executor rejection behavior for B2.
- Migrated P3a A01/A03/A04/A05 to their B1 contracts: effects are called after
  transport, empty sections stay empty, failed transport cannot prepare/commit,
  and executor failures are caught at the moved boundary. Existing exact order,
  byte/result, default, profile and command-error assertions remain.
- Added numbered B1 cases for direct transport, real engine plan/implement,
  verifier missing-report and mutation paths, callback failures, invalid
  observations, opaque/custom passthrough, ErrorHandler and repeated usage events.
  Plan's historical advance after failed transport is characterized, not fixed.
- Strengthened B1-12 after independent review: two actual usage notifications per
  stream, lower fresh totals on the second invocation of the same handle, and
  exactly one engine terminal per invocation. The parsers are unchanged.

## Evidence

Source and call sites inspected; no callable LSP tool is available. No BEAM,
formatting or tests have run yet. Independent static review found no blocking
defects; the B1-12 test delta awaits reinspection. Runtime gates are pending. The implementation does not claim
B2 error propagation, I2 authorization or remote-write prevention.

## Next Step

Run authorized format/lint and focal regressions, then freeze for reinspection
before the separately authorized full coverage/Dialyzer/build/harness gates.
Keep the final source fixed and report later gate results externally.
