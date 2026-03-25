# CLZ-41: Add Telemetry events for agent turn lifecycle

## Goal
Add Telemetry events for agent turn lifecycle

## Acceptance
- Add Telemetry events for agent turn lifecycle Add Telemetry events to the agent turn lifecycle so Symphony can track turn durations, token usage, and outcomes through the standard Erlang telemetry system. Changes needed: 1. In delivery_engine.ex handle_plan/9 and handle_implement/9: emit telemetry events at the start and end of each agent turn: - [:symphony, :agent_turn, :start] with metadata: sta

## Plan
- Outline the implementation steps here.

## Work Log
- No work recorded yet.

## Evidence
- Add validation, proof, and review evidence here.

## Next Step
Decide the immediate next action for this issue.
