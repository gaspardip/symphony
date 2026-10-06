# Architecture

Symphony is split into:
- intake and routing
- delivery runtime stages
- proof and verification gates
- publish/check/merge/post-merge orchestration
- operator control plane and reports

The runtime owns workflow invariants. Model providers should be replaceable adapters, not the source of process logic.


DeliveryEngine.TurnReport owns the synchronous reported-result/error channels for a
turn. RetryBudget owns pressure, windows, progress, extensions and retry decisions.
RetryBudget.Focus owns file inference and compact learning. RunPolicy remains the
owner of budget persistence and stop effects. DeliveryEngine owns prompt guards and
general resume merges; Orchestrator remains the single owner of scheduling and custody.
None of these calculation modules grants execution authority.

InboxPrefix owns finite physical capture, applied cursor, confirmed boundary and
rebind geometry. Orchestrator projects only those fields and keeps the single
persistent batch representation; it owns heads, contexts, admission, custody,
callbacks and effects. EventInbox owns storage locking, byte verification and
durable ACK. Tracker head membership and GitHub whole-prefix currency remain
distinct, as do their generation-retirement policies.

Config preserves the workflow's normalized string-key stage provider mapping.
AgentProvider resolves each selection through the existing adapters and fallback.
This configuration seam owns no session lifecycle, capacity, execution authority
or usage accounting; resolving a different provider alone does not replace an
already-open session in DeliveryEngine.
