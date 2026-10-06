# Retry budget and file focus extraction

## Goal

Concentrate retry calculations and file-focus inference without moving persistence,
scheduling or execution authority out of their existing owners.

## Acceptance

Preserve scoped and broad priorities, consumed usage, retry window bases, checked
fresh RAW state, legacy persistence differences, selective limit queries and
continuation rules. Keep existing assertions and thresholds. Validate the new
contracts and existing integrations, then all repository gates before integration.

## Plan

Adapt RunPolicy, DeliveryEngine and Orchestrator through RetryBudget. Separate
bounded file inference and compact learning in RetryBudget.Focus. Project message
facts once through Observation while keeping execution capabilities in the owner.

## Work Log

The external draft and independent static reviews established owner write order,
stale/fresh merges and the selective Focus reads. Twenty-four new regression cases
cover scoped decisions, Observation, Focus and the public RunPolicy adapter.
They are authored, not yet executed at this preparation cut.

## Evidence

External source pins, review06 and review07 live under validation/sota. Review is
static evidence only; no compilation or runtime acceptance is claimed here.
TurnReport was independently validated and integrated at d545d5c. The historical
26-case video reference stays at 2e05dea; its acceptance is not transferred.

## Next Step

Run formatting, compiler/lint, the public contract and existing integration suites,
then full suite, coverage, Dialyzer, build and harness. Integrate only this validated
logical change locally. Inbox-prefix and stage-provider units and the complete
new-source 26-case campaign still remain before the architecture goal closes.
