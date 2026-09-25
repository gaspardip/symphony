# Architecture I1: durable logical run identity

## Goal

Base: 73aa6ec. Scope: identity creation/adoption in checked dispatch admission;
no coordinator refactor, provider changes, new completed-issue cycle, or replay API.

## Acceptance

The snapshot owns run identity and progress. Dispatch journals bind each fresh
attempt to the same run; checked identity intent/confirmation binds issue, workspace,
run and original ledger. Pending identity writes block reads and subsequent effects.
Ordinary snapshot writes retain established identity and reject conflicting identity
or issue values. Legacy adoption records a new event without rewriting older events.

## Plan

Implement the bounded admission contract, then validate and independently review
before local integration.

## Work Log

Implementation adds numbered regression coverage I1-01 through I1-18 for read purity,
metadata bootstrap/real after-create hook, retry/new coordinator, legacy preservation,
concurrency, invalid/pending/mismatched evidence, write failure, interruption, stale
writers, tampering and terminal-cycle protection. Independent review found that requiring identity on version 1 journals would break
existing exact finishing reconciliation. New journals now use version 2; version 1
retains closure/reconciliation without authorizing new worker execution. Regressions
cover both versions and preserve historical ledger bytes.

Existing dispatch assertions only
change where admission now creates metadata or records identity events.

## Evidence

- `format-01`: explicit formatting of the seven changed source/test files passed.
- `lint-01`: the sandbox denied Mix's local TCP socket before code analysis. No
  product failure was inferred; the log remains preserved.
- `lint-02`: compilation of 109 files, public-spec validation and Credo over 228
  sources passed with no issues; source remained unchanged during the check.
- `focused-01`: 85 tests, one failure in the existing stale-lease dispatch fixture.
  The fixture reused the shared temporary workspace `MT-STALE-DISPATCH`, whose
  snapshot belonged to an earlier test's different issue ID. The new guard correctly
  refused to replace those bytes. The test cleans its lease but not that workspace.
  Diagnosis and the original failure remain in the validation record.
- `focused-02`: the same source and assertions passed 85 tests with zero failures,
  seed 0, 19.8 seconds, after the central runner gave each invocation its own short
  temporary root. Both source manifests are identical. No test or product change
  was used to resolve the fixture contamination.
- Independent static review I1-static-review-20260925-02 closed the legacy journal
  compatibility finding after rereading the corrected implementation and regressions.

Evidence lives under `trabajo/arquitectura/ejecucion/validation/i1` in the thesis
workspace, with source manifests and runner results. No callable LSP tool was
available (tool catalog checked). These are compiler/spec/lint/test results, not LSP
diagnostics. Full suite, coverage, Dialyzer, build and harness checks remain pending
on the composed P1+C1+I1 source before integration.

## Next Step

Complete isolated tests and repository quality gates, then independent review.

Recovery limits and future evidence requirements are documented in dispatch-audit.md.
I3, global PB10, remote CI, deployment and thesis acceptance remain separate.
