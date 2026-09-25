## Goal

Move retry lookup and active pre-lease refresh outside the coordinator while retaining timer identity, retry context, admission bounds and the integrated I1 guard.

## Acceptance

- Snapshot and worker messages progress during both held reads.
- Old or duplicated timers and callbacks cannot consume a newer retry.
- C1 and retries alternate through one shared reader beside B; metadata stays attached to the current generation.
- Current read errors and 429 reschedule once; obsolete configuration and backoff waits preserve attempt.
- Real worker admission preserves run identity, accumulated usage and focus while creating a new dispatch; contradictory/pending snapshots block without rewriting evidence.

## Plan

Implement the shared admission continuation, migrate existing fixtures to a persistent test owner, add integration regressions, then complete independent review and repository gates before integration.

## Work Log

- Replaced unversioned timers with scheduled/ready/reading entries and conditional generation handling.
- Preserved candidate versus individual lookup policy, review continuation checks and manual fallback identity checks.
- Removed obsolete synchronous retry wrappers; test helpers delegate real public callbacks and retain the reader owner.
- Kept config-obsolete timer rearming free of persistence into a changed workspace root.
- Integrated I1 base before checks. Passive-to-active promotion under lease, inbox, GitHub and direct controls remain outside C2.
- Independent review identified stale cached capacity, identity inherited by refresh merging, and a queued timer discarding an active C1 batch during invalid configuration. Corrections use current capacity without global lease renewal, raw response identity checks and an occupied-slot guard before scheduler configuration handling; regression cases retain the original deadlines and assertions.

- Capacity fixtures now configure the real workflow limit, retaining their prior assertions. The existing worker-start failure seam verifies a new retry generation retains resume context and survives old completion/timer messages; this composes production boundaries and is not claimed as an end-to-end timer-to-failed-spawn run.

## Evidence

The external architecture runner records source manifests, commands and results under `trabajo/arquitectura/ejecucion/validation/c2` in the project mirror. Initial focused run reached 27/0 after fixing two new-fixture protocol mistakes; retained diagnosis explains the prior seven failures. Compatibility with C1, controls, leases, audits and I1 reached 188/0 before the final additional edge cases. An incorrectly named B test argument was omitted by the runner; that result does not establish B compatibility, which requires the verified orchestrator_tracker_poll_async_test.exs path. Final candidate review and gate outcomes belong to the external immutable validation records; this progress file does not claim they have passed in advance. No LSP tool was available; compiler, specs, lint, tests and Dialyzer provide separate checks.

## Next Step

Freeze the candidate for independent review, complete all required gates on that source, and integrate only after the coordinator verifies their evidence. No remote publication is part of C2.
