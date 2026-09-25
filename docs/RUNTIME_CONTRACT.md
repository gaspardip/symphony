# Current runtime contract

This document describes the Elixir fork's responsibility boundaries. `SPEC.md`
retains the upstream scheduler/runner design; its tracker-reader boundary and its
exclusion of PR business logic do not describe this fork's delivery engine.

## Delivery ownership

The orchestrator admits work, acquires leases, starts workers and reconciles state.
`DeliveryEngine` owns the delivery stages and coordinates Git, pull requests, required
checks, review, merge and tracker updates through the corresponding adapters. The
agent implements the requested changes and reports its result. An agent's success
message is not proof that required checks passed or that an external action completed.

The configured policy determines whether a run may publish, merge or stop for human
review. Contributor instructions are not credentials or approval to perform those
actions. A run must preserve its reason for stopping and the evidence needed to
explain the decision.

## Sources for a repository

| Question | Source |
|---|---|
| What change is requested? | The admitted issue and its acceptance criteria, interpreted with the target repository's product requirements. |
| What instructions govern changes? | The applicable `AGENTS.md` and referenced contributor instructions in the target checkout. |
| Which checks demonstrate acceptance? | The target repository's `.symphony/harness.yml`, its declared commands and proof requirements. |
| Which runtime configuration applies? | The workflow path selected at startup, its versioned contents, and the effective configuration read by `Config`/`WorkflowStore`. |
| What code was actually checked? | The source revision and content manifest recorded with the test or campaign results. |
| What happened outside the process? | The corresponding tracker, PR and CI evidence, correlated with that run. |

The harness in this repository has `scope: self_host_only`. It is not a validation
contract for every repository Symphony can work on. Its publication gate requires a
progress record; feature-file updates and UI proof are not currently mandatory gates.
`CLAUDE.md` separately asks self-host contributors to update affected feature files.
Passing the automated gate does not establish that every contributor obligation was
checked automatically.

Keep source revision, workflow/configuration, dependency versions, execution evidence
and external results together when reproducing a run. A task title, an existing branch
or a model's report cannot substitute for those records. The release selected by an
installation pointer also does not by itself prove which code a running process loaded.

## Current validation and limits

The executable coverage audit requires 79% overall and 70% for its configured core
modules. See `elixir/lib/symphony_elixir/coverage_audit.ex` for scope and exclusions.
Tests, acceptance campaigns, integration into `main`, remote CI and deployment remain
separate checks. Local uncommitted changes require a content manifest in addition to
the base commit if their results are retained as evidence.

Workspace state serialization coordinates mutations within one BEAM node. The shared
filesystem lease contract has separate limits described in
[lease-exclusion.md](lease-exclusion.md). Harness homes are runtime isolation aids,
not an OS sandbox; see [harness-runtime-env.md](harness-runtime-env.md). Secret
redaction and [publication preflight](publication-preflight.md) likewise have defined
scopes and do not establish general confinement or all external outcomes.

Changing a model or provider is a separate change to validate against these contracts.
It does not change the repository's acceptance criteria, permissions or required
proof unless those contracts are explicitly revised.

Worker admission and recovery follow [the audited dispatch contract](dispatch-audit.md).
A recorded authorization is distinct from execution, and a closed worker process is
distinct from acceptance of its task. Pending journals block retries and cleanup.

A logical delivery cycle has a durable `run_id` established by checked dispatch
admission. The existing `dispatch_id` identifies each worker admission within that
cycle. Reading historical snapshots does not manufacture identity; their explicit
adoption at admission preserves progress, accumulated consumption and approvals.
The snapshot and checked identity evidence must agree before opening the worker
gate. See [durable identity and interruption limits](dispatch-audit.md#durable-logical-run-identity).

## CLI transport and local turn effects

Claude and CodexCLI return a `cli_observation` built by their Elixir wrapper from
stream paths, summary and transport error. Direct `run_turn` calls perform no
runtime Git observation, formatting, staging, commit, progress patch or delivery
report synthesis. Stream notifications and transport-error callbacks remain in
transport; its normal final callback moves to the caller's effect boundary.

DeliveryEngine passes its explicit workspace and required `:delivery` purpose to
`DeliveryEngine.TurnEffects.apply_result/6` after transport returns. Successful CLI
turns retain Claude's HEAD/untracked and CodexCLI's status/origin-main observations,
then format/stage/commit and synthesize `report_agent_turn_result` in the same
process. Failed CLI turns skip preparation and synthesize only a blocked report
from the stream. Both retain the inherited `:turn_completed` terminal notification,
whose name is not proof that the raw turn result or delivery succeeded.

VerifierRunner supplies `:verifier`: no local Git preparation or delivery synthesis.
It still requires a real `report_verifier_result`; a CLI without that capability
returns missing verifier result. Its existing mutation checks remain responsible
for changes made by the provider itself. No runtime path fills empty or missing
progress evidence; the real publish harness continues to reject missing sections.

Known CLI modules require a valid matching observation; missing fields, wrong
profile or invalid paths fail before effects. AppServer/custom returns pass through
without extra callbacks or policy selected by arbitrary payload fields. Sessions
remain opaque. ErrorHandler.run_logged_agent_turn/5 is transport plus logging,
not a second delivery entry point, and does not infer workspace from a session.

Exceptions in local effects, synthesis or the final callback retain the moved
catch boundary. An error callback that itself fails escapes without recursive
notification. A normal callback that delivered before throwing may be followed by
an error event: callback delivery is not exactly once. No local effect is retried.

This is P3b.1. Nonzero format/add/commit and executor rejection retain their previous
handling until P3b.2. Planning still advances through its historical error path;
B1 does not guarantee that a failed transport or preparation blocks plan. I2 will
validate execution ownership between transport and effects and at dynamic tool
entry points; this boundary alone does not authorize stale work or fence remote
provider effects. CLI usage remains scoped to each invocation until I2.

## Checked inbox storage (C4a)

Tracker and GitHub inboxes share a checked storage contract. State version 2 binds
an absolute byte offset to a queue generation. Each captured physical row carries
a cursor for its observed prefix, including malformed complete rows. A repeated
ack is idempotent only for that exact prefix and generation. Append preserves the
current offset and ack preserves current dedupe keys under the same filesystem
lock. All cooperating processes must use the same absolute configured path;
symlink aliases and older binaries do not participate in this guarantee.

A missing pair is an uninitialized inbox; a missing single file, corrupt state,
invalid offset or unknown version is an error. Reads never invent a generation or
replace corruption with empty defaults. Legacy state requires explicit migration
while older writers are stopped. Migration maps the recorded physical line count
to bytes and preserves dedupe, without reconstructing past effects.

State publication uses a same-directory temporary, sync, close and rename. Append
and state publication are separate operations: partial or uncertain failure is
visible and may permit redelivery. A persistent tail without newline blocks append
and reset; no automatic truncation or repair occurs. Records and capture batches
are limited to 4 MiB; ordinary drains also stop at 100 physical rows. Oversize input
is rejected before append. Logical reset preserves history and changes generation,
sets the offset to EOF and clears dedupe. It is not corruption repair or compaction.

Both event drains remain synchronous. After applying a prefix, the coordinator
retains an unconfirmed cursor on storage failure and retries only that ack at the
next drain opportunity. The cursor keeps its original location across configuration
changes. A reset invalidates it; other mismatches remain blocked and visible.
Owner restart can replay effects: delivery is at least once, not exactly once.
No autonomous wakeup, reader slot or async admission routing is introduced here.
Those remain C4b work after C3.


## Snapshot metadata reads

RunStateStore resolves runner metadata only for missing, nil or empty-string
fields. Existing values survive reads and writes without consulting Git to
recompute a value that would be discarded. Creating a snapshot and filling legacy
metadata still use the current getters; no cross-operation cache is introduced.
This metadata remains historical context, not proof of the code currently loaded.
Workspace locking, run identity guards and monotonic token usage are unchanged.
