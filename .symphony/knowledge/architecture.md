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
