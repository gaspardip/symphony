## Goal

Preserve exact lease ownership across asynchronous passive promotion, local custody transfers and conditional cleanup.

## Acceptance

Generation tokens reject same-owner/same-epoch ABA; physical locks serialize mutation across OS processes. Promotion shares the admission reader and preserves its original deadline until the final gate lock. Retired callbacks cannot release successor custody or erase its workspace/snapshot.

## Plan

Complete storage and all runtime consumers, migrate existing fixtures without weakening their assertions, add promotion/lifecycle regressions, freeze for independent review, then run the authorized validation gates.

## Work Log

- Storage APIs return the acquired token and payload from the same captured lock, retain exact legacy reconciliation and reject owner-only v2 mutation.
- Custody lives independently of running/retry maps. Gate and DOWN transitions change custody reference without inventing a token from a read.
- Passive repair uses the existing TrackerReader slot and a deadline starting before lease acquisition. Cancelled readers retain capacity until their monitor completes.
- Controls and follow-up transport custody; snapshot metadata stores generation but never becomes an executable token.
- Terminal retry, terminal running reconciliation and startup cleanup preserve v2 historical workspaces. This explicitly changes cleanup behavior to prevent erasing a successor snapshot/header. Legacy physical checks retain their narrower existing guarantee.
- Review R1–R5: borrowed follow-up retains the running reference; review resume transfers to retry before its capacity check; duplicate promotion and gate messages preserve the current attempt; cleanup never classifies a captured v2 claim from a new root.
- Existing runtime fixtures retain acquired tokens. Legacy refresh keeps timestamp normalization; malformed legacy acquisition fixtures now assert rejection and unchanged bytes, separately retaining takeover coverage for valid expired records. New cases cover real DOWN custody transfer, max-1 review resume, cancelled physical reader capacity, deadline, config-root change, backoff and historical/error diagnostics.
- Review R6: GitHub follow-up checks an explicit destination against captured custody before effects; new acquisition fixes storage/workspace before its lock. Two-root inbox cases cover missing and same-owner destination leases, preserving both snapshots, lease bytes and an unrelated worker.
- Review R7: budget retry persistence uses captured custody workspace; retry resume rejects a different root before acquisition or writes. Release events use the captured ledger, with a distinct explicit audit failure after physical removal and no restored custody.
- Four capacity cases isolate state/company limits for pending and gated reservations, checking one-slot accounting through the existing public admission predicate.
- Diagnostic reclaimability now handles DateTime legacy timestamps and complete known atom/string v2 fields without interpreting a partial v2 as legacy.

## Evidence

Static storage, runtime cut05 and fixture migrations received independent review. The composed source includes the current main metadata and P3b.2 changes. Early format, force compilation, harness and lint passed. Compiler warnings exposed an incorrect reclaimability arity and separated function clauses; the call is corrected with the captured TTL and a real GitHub inbox regression, and the clauses are grouped without changing their bodies. The first focal attempt stopped while compiling two generated test names longer than the VM atom limit; short case labels preserve both payloads and assertions. Failed attempts remain recorded alongside later gates in the external validation/c3 directory.

The new lease OS tests compare child artifact paths/hashes and loaded module MD5. They cover lease mutation, not the broader E1 build-identity contract. Callable LSP is unavailable. Runtime results, coverage, independent review and exact source manifests must be read from the validation records; static review or a compiler exit alone is not proof of acceptance.

Compatibility attempt `compat-01` completed 403 tests with 9 failures on unchanged source. The grouped corrections preserve its evidence: the new identity roundtrip now distinguishes legacy snapshots from admission-backed identity; malformed legacy takeover fixtures assert the approved rejection contract; owner-only legacy refresh regains acquired_at normalization; and DOWN fixtures carry their actual acquired token and custody reference. Earlier focal attempts and their diagnostics remain retained.

Promotion preserves the pre-existing manual empty-result and Blocked-resume rules only after exact raw identity validation. Two regressions use the real manual store, including the public retry control with an actual write-permission failure, and prove gate authorization through a bounded before_run hook plus running custody. Tracker absence/terminal diagnostics and cleanup/audit failure precedence remain covered. Focal attempt `focal-06` completed 88 tests with 2 failures: both new manual fixtures used a missing tracker kind, and their hook cleanup masked the earlier rejection. The fixture now uses the isolated memory tracker and validates configuration before submission. `focal-07` then passed 88 tests. Compatibility `compat-02` completed 404 tests with 3 fixture failures: the two new DOWN constructors updated the context root instead of the orchestrator state. Only those setup roots were corrected, and the complete `deploy-audit-focal-01` suite passed 17 tests. The 404-test attempt remains failed; it was not rerun or relabeled as green. Product bytes remained identical across that fixture correction. Earlier timeouts remain unattributed. Full repository validation, exact-export coverage and final gates are still pending on this frozen cut. Callable LSP remains unavailable.

## Next Step

Freeze after the targeted audit suite, then run format, lint, harness, the full repository suite, coverage of that exact export, Dialyzer, build and the final harness. Stop on a new failure and preserve its evidence; integrate only the exact validated tree locally with its recorded commit. Preserve historical branches, stashes and failed validation attempts. Remote publication and final thesis acceptance remain separate requirements.

Composition checkpoint: cut05 source was preserved in stash `1908b123e7b77b8756f4691613b492c54d9d5e10` and composed onto local main `3e82c2aa29a97f0042a02458410fa01b680c5f58`. The runtime contract retains both metadata and custody sections; RunStateStore combines lazy metadata with v2 lease fields. Runtime validation records identify their exact composition and source hashes.

The subsequent full attempt completed 1,632 tests with 10 failures: eight CoreTest
fixtures lacked running custody and two TerminalLeaseRelease cases interfered with
initial poll maintenance. Their failed output and diagnostics are preserved. On
2026-09-29 the independently reviewed Core02 proposal was applied exactly: nine
running fixtures use tokens from real acquisition, and five wait for initial discovery
before injecting their state. Its terminal case explicitly adopts v2 workspace
preservation, checking snapshot/sentinel bytes, stopped worker and released custody.
TerminalLeaseRelease also waits for the initial poll before injecting locks or taking
snapshots. Existing behavioral wait limits remain unchanged. Neither correction is
declared passing before its focused execution and the later combined full suite.

The composition on E1-build passed 1,655 tests and 83.40% coverage, then stopped
at four Dialyzer findings. The reviewed correction removes private branches with
no reachable callers and projects the promotion operation to TrackerReader's
four-field handle before cancellation. It preserves owner validation, reader
identity and runtime decisions; tests and ignore rules are unchanged. The failed
type-check result remains recorded. Validation of the corrected cut is pending.

That corrected cut subsequently passed 1,655 tests and 83.43% coverage. An
unfiltered comparison against E1-build exposed two further warnings covered by
existing broad exclusions: an unreachable workspace fallback and a refresh
predicate that always returned true. Both branches are removed without changing
their callers or the ownership-uncertainty policy. Other changed diagnostic bodies
refer to pre-existing callsites and inferred state shapes; those existing warnings
are not claimed resolved. The final simplified cut requires its own validation.
