# Physical inbox prefix continuation

## Goal

Concentrate finite physical-prefix continuity without moving storage, custody,
head lifecycle, execution authority or coordinator effects.

## Acceptance

Preserve before/after ACK consumption, the captured horizon, exact cursor checks
before ACK, retained row projection after ACK, detached pending confirmation,
generation retirement and distinct head/whole-prefix checks. Keep existing tests.

## Plan

Introduce InboxPrefix and adapt only physical calculations in Orchestrator.
Exercise the public seam and owner callbacks with real temporary storage, then
existing inbox integrations and the full repository gates before integration.

## Work Log

The reviewed design identified two physical consumption modes and keeps the
coordinator as the sole owner of callbacks and effects. Twelve seam regressions
and four owner regressions are prepared outside the checked source at this cut.
They have not been compiled or executed, and the owner adapters are not applied.

## Evidence

External design review01 and exact draft pins are recorded under validation/sota.
Static preparation is not runtime acceptance. The frozen 26-case video source
remains 2e05dea; architectural source acceptance requires its own final campaign.

## Next Step

Review the draft and owner effect order, apply only after the preceding budget
unit is closed, and run all required checks. Stage/provider sessions, joint
architecture review and the new-source 26-case campaign remain in the full plan.
