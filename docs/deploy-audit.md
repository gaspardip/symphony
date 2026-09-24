# Deployment audit

This fork's optional preview and production deployment stages reserve an operation
before invoking the repository command. The reservation is a sibling directory,
`.<workspace-name>.deploy-audit`, outside the mutable workspace. Its identity binds
the workspace, issue, stage, base stage-entry event, command digest and original
ledger path. A reservation, even incomplete or unreadable, prevents another attempt.

The runtime confirms the intent with the checked ledger writer before executing the
command. The command runs without holding the snapshot lock, so status, lease
maintenance and token accounting remain available. Its observed result is persisted
under the same operation identity before continuation. A nonzero or unavailable
result does not establish that the command had no effects; it remains pending.

Successful continuation compares the fresh issue, stage, stage-entry event and lease
identity under one snapshot lock. It records the deploy result and stage transition
together, preserving concurrent accounting. The journal closes only after checking
the exact result and the operation's own continuation event in the original ledger.
A later unrelated transition to the same stage is insufficient proof.

A pending journal blocks dispatch, direct delivery entry, retry, approvals and
workspace hooks or cleanup. Stop and status remain available. An after-run hook is
omitted with an explicit diagnostic when running it could disturb pending evidence.
A second process or VM sees the reservation even after the first process exits.

No timeout removes the reservation. A storage error, changed ledger, command failure,
conflicting stop or failed final removal is returned explicitly and preserves the
remaining evidence. A legacy snapshot lacking its checked stage-entry event cannot
open a deployment. Missing commands and deferred production windows retain their
existing behavior before a reservation is opened.

The journal records local observations; it does not make shell, tracker and storage
atomic. A successful exit is not independent proof of the remote deployment. The
tracker's final Done update occurs outside the snapshot lock and can fail or race
with an operator action; a conflicting continuation remains pending. Opening uses
exclusive directory creation across VMs; later ticket operations belong to the
creating process and use local coordination, not a distributed transaction.

There is no automatic reconciliation or journal-deletion command in this change.
Preserve the directory and original ledger while investigating the actual outcome.
This unit does not establish crash-proof global exactly-once delivery, storage
survival after power loss, or audited publication and merge. Those contracts require
separate evidence.
