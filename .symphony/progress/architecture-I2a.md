## Goal

Bind admitted workers, provider sessions and accepted consumption to the captured
dispatch authority, and stop controlled continuation when accounting is uncertain.

## Acceptance

Foreign or obsolete callbacks cannot affect another execution. CLI invocation and
AppServer thread totals preserve accumulated usage, including A-verifier-B-A
session changes. Checkpoint failure survives every caller through DOWN without
ordinary success, automatic retry, journal finish or successor cleanup.

## Plan

Implement the reviewed D1-D5 contracts in the shared execution module, checkpoint
boundary, coordinator and consumers. Preserve legacy transport behaviour where
valid. Exercise real local provider protocols and owned callback barriers, review
the combined source, then run focused and complete repository checks.

## Work Log

The independent module preparation was preserved and composed on integrated C4b
92b7fe0b2794fc8c9d06884490695a9e9607c877 without changing its five source files.
Consumer implementation and the end-to-end suite are in progress. The runtime
entry guard precedes workspace hooks; the verifier shares the outer context.
Root owns documentation and reviewed existing fixture migrations, with separate
writers for coordinator and consumers and an independent reviewer/validator.

## Evidence

Prepared source, the exact composition and API decisions are recorded externally
under validation/i2a. The first preparation contains 28 authored cases, not test
results. No I2a compilation, focused suite or full validation is claimed here.
No callable LSP was available; source, specs and callers are the inspection basis.
The prior C4b integration has its own completed validation and is not evidence of
the subsequent I2a edits. No real provider or external tracker is exercised.

## Next Step

Complete consumers and the indivisible uncertainty lifecycle, review the combined
cut and validate it in the single isolated runtime slot. Preserve failed results
and exact source. Integrate only after all required checks pass. I2b/I2c, recovery,
remote publication and final thesis acceptance remain separate.
