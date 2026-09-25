# Architecture P3a: mechanical CLI turn-effect extraction

## Goal

Base f7abd24. Extract existing Claude/CodexCLI helpers without changing behavior.

## Acceptance

Both adapters retain their stream structs, Git profiles, call order, caller-process
executor, try/catch boundary, defaults and error behavior. No new test-only wrapper,
transport contract or lifecycle change. P3b and I2 remain separate.

## Plan

Extract four concrete helpers to DeliveryEngine.TurnEffects. Characterize both
adapter paths using local CLI fixtures and real Git workspaces. Review independently,
then run focal checks and the repository gates in an exclusive validation slot.

## Work Log

Adapters call the extracted helpers where they previously called private functions.
Existing Claude test wrappers delegate to the shared production helpers. Numbered
regressions cover order and exactly-once effects, process-local synthesis, Git profile
differences, structs, clean-workspace progress fallback, failed CLI exits, executor
throws/rejections, false error values, ignored format/add/commit errors and existing
MatchError/CaseClauseError paths. The fixture CLI never calls an external provider.

## Evidence

- Definitions and call sites inspected on the stated base; no callable LSP tools were
  available. Static inspection is not reported as compiler or LSP validation.
- `format-write-01` and `format-01` passed. `lint-01` compiled 110 files and
  passed public specs and Credo over 231 sources with no issues.
- `focused-01` ran 48 tests with six failures in new byte expectations: both
  profiles preserve a blank line after each progress heading, but two expected
  strings omitted it. The extracted section helper matches the original bytes.
  Only those two exact expected strings were corrected; no product behavior or
  assertion was removed. The original log, diagnosis and before/after hashes are
  retained under `trabajo/arquitectura/ejecucion/validation/p3a` in the thesis
  workspace. The repeat and full repository gates are pending on this snapshot.
- Independent source review `P3a-root-review-20260925-01` found no open concrete
  product issue; final integration still requires passing tests and gate manifests.
- Runtime contract explicitly retains P3a's limitations: adapter calls still mutate
  local files/HEAD, fill empty progress sections and ignore some command failures.

## Next Step

Format, focal tests, independent review and full local gates before integration.
Keep source fixed across final gates and record final results outside the repository.
