# Architecture E1: disabled behavioral proof diagnostic

## Goal

Return a structured result when the harness sets behavioral proof to required:false
and Git reports behavior-changing files. Base: 3e82c2a. This correction does not
change proof requirements, verifier policy or the E1 acceptance contract.

## Acceptance

Disabled proof retains its changed source paths and absence of tests/artifacts.
The diagnostic names the disabled requirement instead of raising FunctionClauseError.
A passing smoke still reaches the verifier and preserves its rejection; a failed
smoke returns needs_more_work without invoking the verifier. Existing required-proof
and verifier-disabled policy regressions remain unchanged.

## Plan

Add the missing reason/7 clause, one evaluator regression and two public
VerifierRunner.verify/5 regressions. Review the small patch before using the shared
validation environment, then compose and validate before local integration.

## Work Log

- Preserved the no-behavior-change diagnostic and all proof evaluation decisions.
- Added the explicit disabled-harness diagnostic for remaining required:false cases.
- Added temporary Git workspace tests with real passing/failing smoke commands.
  The existing verifier-session seam supplies a rejection and checks invocation;
  these cases do not invoke a remote model or claim semantic acceptance.
- Existing tests and policy paths were not modified. No new API or dependency.

## Evidence

Static inspection only. The missing reason/7 branch was previously observed in the
P3b.1 focused run and remains present on the base above. No callable LSP is available.
No formatter, compiler, tests, coverage, Dialyzer, build or harness checks have run
for this patch. Product verification and local integration remain pending.

## Next Step

Independent review, explicit formatting, focused proof/verifier and disabled-policy
compatibility tests, then the repository gates on the composed tree. Preserve all
failed attempts and their source manifests. Broader E1 acceptance remains separate.
