## Goal

Bind each deployment observation and continuation to the execution that authorized
it, preserving the first denial and uncertainty without replay or ownership adoption.

## Acceptance

Only captured current authority opens version 2. New version 1 requires proven legacy
absence. The original result is observed at most once, including after a denied guard.
The exact checked CAS receipt and owner ACK permit only its own finish. Pending or
corrupt evidence remains blocked; inspection is read-only and cannot import custody.

## Plan

Bind deploy admission, observation and continuation to captured execution authority.
Review the exact composed source, run the required gates, then assess local integration.

## Work Log

DeployAudit owns versioned live custody, the consumed observation and the exact
continuation anchor. RunStateStore checks original/next material under one workspace
lock and commits checked session provenance with the transition. AgentExecution keeps
captured tickets and recognizes continuations only after owner ACK; DeliveryEngine
uses those boundaries while preserving the legacy observation order.

## Evidence

Regression suites cover storage, public delivery/owner, original results, successor
conflicts, persistence failures, legacy repetition, physical lease successors and
competing workspace writers. Authored assertions do not establish passing results.
Exact-source gate and integration receipts remain in the coordinator's external
validation records; this file embeds no mutable result or acceptance claim.

No callable LSP is available in this session. Source/spec review, compilation,
Dialyzer and runtime checks are separate evidence.

## Next Step

Public owner-stop termination is separate from a live-worker denial. No observation
is fabricated after death, and dispatch termination is distinct from deployment
success. Explicit timeout observation is wrapper evidence; public shell timeout
detection is not added. Safe stack projection is reviewed structurally; runtime
frame shapes and process teardown require execution evidence.

C5/C6, P2/I3, criteria authority, the complete thesis campaign, loaded-release proof
and model comparison remain independent work. No automatic journal recovery,
remote transaction, push, deployment or real-provider acceptance is claimed.
