# Snapshot metadata lookup cost

## Goal

Avoid repeated runtime metadata reads whose results are discarded when a snapshot
already has those fields, including inside the workspace mutation lock.

## Acceptance

Populated metadata performs no Git version lookup during reads or usage-preserving
writes. Missing, nil and empty-string fields use the existing getters. Other values
retain the prior fill predicate. Initial defaults, run identity and token totals
keep their contracts. Existing availability tests retain their original limits.

## Plan

Separate unevaluated state defaults from metadata completion and call getters only
for missing values. Add local Git invocation-count regressions, independently review
the diff, then run targeted checks and the complete repository gates.

## Work Log

The preceding full B2 run reported budget-lock and retry-snapshot timeouts. An
unchanged covered diagnostic focus passed43 cases while observing repeated Git
lookups and long lock waits. That observation supports removing discarded work;
it does not establish the cause of either original timeout. This unit does not
change the lock, test deadlines, provider behavior or build identity authority.

## Evidence

The initial candidate had no executed checks. Independent static review closed
without findings. Explicit formatting left both Elixir files unchanged; format,
lint and the early harness passed. The metadata, concurrency and identity focus
passed 39 cases. The original budget and retry suites passed 43 cases with coverage
and the same external observer used before this change. The 16 budget tasks made
zero runtime-version calls instead of 176; snapshot callbacks made zero instead of
13 each. Lock waits and snapshot times also decreased in this observation, which
does not establish the cause of either earlier full-suite timeout.

The new suite uses an actual Git executable wrapped only to record rev-parse
invocations, restoring PATH at teardown. Source is frozen after this historical
note; full suite, exact-export coverage, Dialyzer, build and final harness remain
pending at this cut. Final results are stored externally under validation/metadata;
earlier failures remain in validation/p3b2. A harness attempt made before lint
finished was refused by the validation lock before starting a VM, then executed
successfully after lint exited. No test deadlines or assertions changed.
No callable LSP tool is available in this session.

## Next Step

Complete the remaining gates on the frozen source, then hand the evidence to the
coordinator for a separate local commit. Compose B2 and C3 before their remaining
validations; the earlier B2 full is not superseded by these focal runs.
