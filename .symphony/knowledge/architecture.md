# Architecture

Symphony is split into:
- intake and routing
- delivery runtime stages
- proof and verification gates
- publish/check/merge/post-merge orchestration
- operator control plane and reports

The runtime owns workflow invariants. Model providers should be replaceable adapters, not the source of process logic.

