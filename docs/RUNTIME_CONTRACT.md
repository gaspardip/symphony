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

Command and executor failures return `{:error, {:turn_effect_failed, details}}`.
Details identify the runtime-owned step (`detect_changes`, `format`, `stage`,
`index_diff`, `commit`, or `report_turn_result`) and exact status/output or exception
kind/reason. Command diagnostics include executable, argv and cwd; they do not
capture environment or transport options. Detection failures are not empty diffs.
Missing `origin/main` for CodexCLI and missing HEAD for Claude are explicit errors,
without fetching, fallback refs or retry. Index diff exit 0 skips commit; exit 1
allows commit; every other exit status stops the chain. Only a successful commit
emits the auto-commit success log.

CLI delivery requires an arity-two report executor before preparing Git. Its
response must contain the string key `"success"` with a boolean: true accepts the
report, false is `tool_rejected`; other responses are `invalid_tool_response`.
Absent or wrong-arity executors are `missing_tool_executor`. Executor exceptions
retain kind/reason inside the same effect-failure tag. A failed transport still
skips preparation but its blocked report must be accepted by the executor.
Acceptance of a blocked report is not successful delivery.

The engine returns this tag from plan before reading an old report or transitioning
to implement, and from implement before its after-snapshot, review updates/replies,
next-stage transition or issue refresh. It does not retry the turn internally or
count it as a successful implementation. Previously accepted token usage remains.
Changes already made by the provider, formatter, index, commit hooks or executor
remain: there is no rollback or atomicity promise. The owner's later generic retry
is a separate policy and is unchanged.

The error callback is attempted once outside failure classification. If it fails,
its error escapes without recursive notification. Final-callback exceptions retain
B1 behavior: a normal callback that delivered before throwing may be followed by
an error event. Successful synthesis precedes a normal CLI final event; failed
preparation or report acceptance emits no normal final event.

Other historical plan behavior for transport errors/raw failed turns is unchanged.
I2a confirms admitted execution context and persisted usage before local turn
effects and dynamic tools. B2 does not authorize stale work or fence remote
provider effects. Material stage/review validity remains a separate I2b boundary.

## Delivery turn reports

`DeliveryEngine.TurnReport` owns the reported result and captured streaming errors
in the admitted worker's process dictionary. `reset/1` clears both channels before
a new plan or implement turn; implement's existing final cleanup also resets both.
A valid `TurnResult` has precedence over captured errors. A malformed report remains
an explicit invalid-result error; no report becomes missing-result or the collected
runtime-error list. The existing key atoms and per-issue identity are preserved.

The report executor normalizes `report_agent_turn_result` and returns the same
success/rejection acknowledgement. Other tools use `Codex.DynamicTool` unchanged.
The message callback captures terminal and notification failures synchronously in
the caller process. It checks execution context at message delivery, forwarding
worker updates itself only for legacy callers; admitted callbacks retain their
existing `AgentExecution` accounting and forwarding authority.

This extraction adds no process, persistence, retry or execution permission. The
engine retains guards, transitions, accounting, provider invocation and publication.
Historical `_for_test` entry points delegate to this module for compatibility; no
new test-only production entry point is introduced.

## Retry budgets and file focus

`RetryBudget` owns the calculations for pressure, turn windows, scoped review
progress, bounded total extensions and broad retry admission. RunPolicy prepares
an observation of usage, identity, durable state and text facts; execution
capabilities and complete provider messages stay with their owner. `pressure/1`
returns a view and optional soft-pressure data. RunPolicy completes that write and
its journal before calling `decide/2` with the appropriate fresh state. The decision
contains an optional resume write and an explicit result. The owner completes the
write before returning a retry or constructing the existing stop violation.

Checked and legacy persistence retain their distinct contracts. Scoped checked
calculations observe the pressure write; scoped legacy retains the initial resume.
Broad retry focus is persisted before accumulated totals can replace retry with a
stop. Generic hard-input stops add no separate resume write. Adaptive window keys
remain distinct from historical retry accounting; no retry renews consumed usage.

`RetryBudget.Focus` owns path inference, diff-marker normalization and compact
learning. Explicit resume focus precedes issue paths, changed files and agent
updates. Primary and expansion queries retain their selective reads. Retry-field
preparation retains eager candidate discovery and eager summary validation.
`Observation.text_facts/1` is the shared text decoder; it retains preferred-key
ordering and preferred empty text. Unsupported execution-bearing scalar messages
remain explicit errors when consumed as summaries, without retaining the original
capability in the observation.

DeliveryEngine owns prompt guards, general resume merges and progress writes. Its
limit queries evaluate only the requested calculation. Orchestrator delegates the
budget continuation predicate while retaining admission, accounting, persistence
and scheduling. This extraction adds no provider, process or execution authority.

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

C4a defines storage, not business scheduling. C5 supplies the GitHub read continuation
described below. After applying a prefix, the coordinator
retains an unconfirmed cursor on storage failure and retries only that ack at the
next drain opportunity. The cursor keeps its original location across configuration
changes. A reset invalidates it; other mismatches remain blocked and visible.
Owner restart can replay effects: delivery is at least once, not exactly once.
The storage layer introduces no autonomous wakeup or reader. The Linear and GitHub continuations
below supply those coordinator behaviors without changing the cursor contract.


## Snapshot metadata reads

RunStateStore resolves runner metadata only for missing, nil or empty-string
fields. Existing values survive reads and writes without consulting Git to
recompute a value that would be discarded. Creating a snapshot and filling legacy
metadata still use the current getters; no cross-operation cache is introduced.
This metadata remains historical context, not proof of the code currently loaded.
Workspace locking, run identity guards and monotonic token usage are unchanged.

## Build provenance and loaded code (E1-build)

`mix build` evaluates `scripts/build-with-identity.exs` from source in a new Mix
process without starting Symphony. It refuses an already loaded Symphony runtime,
forces compilation once, and compares source captures before/after compilation and
packaging. Only Elixir/Mix 1.19.5 and OTP 28 are supported by this identity format.
The trusted bootstrap includes MixProject evaluation and the source driver before
capture. The evaluated Mix project must be inside the Git root and match the working
project directory. Exclusions are derived from that project: its `_build/`, `deps/`,
`bin/` and exact generated `priv/build_identity.json`, recorded verbatim relative to
Git root. A similarly named tree elsewhere remains source. Build/app/consolidation
outputs must stay under that project's `_build`, dependencies under its `deps`, and
the escript at its `bin/symphony`; unbounded paths or output ancestor symlinks are
rejected. A file still listed by Git but absent from disk (for example an unstaged deletion)
makes source unavailable. Dirty support requires readable listed inputs; the driver
does not synthesize missing-file tombstones. No Symphony BEAM helper, including BuildIdentity, participates in building.

Source content is hashed incrementally in 64 KiB blocks, with a 64 MiB aggregate
budget per capture across all source files (at most 192 MiB over the three captures).
The budget counts actual bytes read as well as checking declared sizes; one extra
byte may be read to detect growth beyond the remaining budget. Source files are not
subject to the separate 16 MiB BEAM/ZIP decode limit. The runtime validates both
individual source sizes and their aggregate against the same source budget. No
large tracked media is silently excluded. Each source read compares its open handle
and path metadata before/after, excluding access time, and checks the observed byte
count; read/close errors and changes fail the build. This bounds source buffer memory,
not total build memory or filesystem latency, and is not an atomic filesystem snapshot.

The three dependency JavaScript inputs embedded by StaticAssets are declared explicitly
as app/priv-path pairs in Mix's `build_identity_resources`. The `mix build` alias runs
`deps.compile` before invoking the source driver, so dependency resources and application
paths exist before source capture even in a fresh checkout after `mix setup`. This
preparation does not compile Symphony or start the application. The driver neither downloads dependencies nor fabricates
missing build aliases. It resolves each declared app through `Mix.Project.deps_paths`,
requires its source under the project's `deps/<app>/priv`, and checks Application.app_dir
against the expected `_build/.../lib/<app>/priv` alias. Only that priv symlink to the exact
declared dependency is allowed. Both paths must identify the same physical file; copied
priv trees, other destinations and arbitrary symlink chains are unsupported and rejected.

The manifest keeps Git entries and `source.external_resources` distinct; their combined
canonical fingerprint and build_id cover app, source/compile paths, sizes and hashes.
Declarations are captured before the single forced project compilation and compared after
compilation and final packaging. Every external_resource attribute in newly compiled own
modules must belong to the Git inventory or an explicit declaration. Unknown inputs fail.
Git entries and declared resources share the 64 MiB/50,000-file capture budget. Alias/target
metadata is checked before/after, but content is hashed once from their verified common
file, with the same open-handle checks. No extra resource read escapes the 192 MiB bound.
These observations still do not provide an atomic snapshot or confinement against a
concurrent process with write access. Dependency compilation is a prerequisite, not a
claim that this driver rebuilt dependency sources under that capture.

Two invocations of the existing Mix escript packer produce a temporary probe and
final archive. The probe supplies the actual module inventory, including consolidated
protocols and the generated launcher. The final must preserve code MD5 for every
module and packaged SHA-256 except launcher metadata. Raw compiled input SHA-256,
packaged SHA-256, code MD5 and full archive SHA-256 are distinct fields. The generated
`priv/build_identity.json` is embedded via `include_priv_for`; `bin/symphony.build.json`
binds it to the archive. The final archive and receipt use two renames, not an atomic
pair: missing/mismatched pairs are visible failures. Interrupted builds do not turn
an earlier receipt into evidence for newer source. Dirty builds retain a fingerprint;
promotion requires the expected clean commit and checks the pair before/after copy.
Legacy inspect/rollback never fabricate a receipt.

Application startup explicitly captures local provenance before starting children.
That baseline remains immutable across application restarts in the same VM. RunnerRuntime
`loaded_build` and dispatch `metadata.runtime_build` contain only a precomputed summary
(up to 2 KiB), `basis=startup_capture` and capture time. Their getter does not read,
hash, enumerate modules, write or initialize missing identity. Metadata is runtime-owned;
caller payloads cannot override it. Missing identity is diagnostic and does not change
existing dispatch/lease authorization. Existing events/snapshots remain unchanged.
Legacy `runtime_version` and `runner_runtime_version` describe disk-derived context,
not loaded-code authority.

Fresh `BuildIdentity.inspect_loaded(required_modules)` and `inspect_artifact()` are
explicit worker/local inspection operations outside the coordinator. The former accepts
at most 256 distinct known module atoms, never interns names from JSON or loads/purges
code. It compares memory code MD5, reports not_loaded/old_code/mismatch/unstable states,
and cannot establish which old code a process is still executing. The latter revisits
the captured resolved artifact location and receipt, without adopting a moved `current`
link or new disk bytes. A file location or `code.get_object_code` alone does not prove
memory identity. BEAM mode is distinct from escript mode and has no invented escript hash.

Archive checks are bounded at 64 MiB compressed, 128 MiB expanded, 16 MiB per entry,
4 MiB per manifest/receipt, 10,000 modules and 4,096 bytes per path. Duplicate JSON keys,
paths/modules, invalid types, unsupported versions and inconsistent receipts are rejected.
Limits are failures, never silent truncation. Startup may perform this work once;
ordinary control/snapshot/dispatch reads do not.

This is unsigned local provenance under operator control. Source before/after equality
is not an atomic snapshot or anti-ABA proof, and module samples do not catch every
transient reload. No diagnostic says current_verified. E1 acceptance still requires an
authorized independent checker, an explicit module scope, fresh observations bound to
I2 run/dispatch validity, and a common publication gate. E1-build alone accepts no task,
promotes no release and reconciles no deployment.

## Lease custody and passive promotion (C3)

New acquisitions return a generation token and the exact payload persisted under
its captured lease lock. The coordinator retains that token in independent local
custody across pending admission, gated/running workers and retries. Reading a
lease or a historical snapshot never creates authority. Owner-only legacy APIs
reject generation-bearing leases. Renewal, release and final gate activation
compare the full token under the original physical lock, including when the
configured root has changed.

A passive checkpoint repaired to active work reserves the shared C1/C2 admission
reader and one capacity slot. Its promotion deadline starts before acquisition
and remains bounded by half the captured TTL through the final gate lock.
Cancellation invalidates the operation immediately but retains the reader monitor
and capacity until termination is observed. Transfer to running retires the
promotion timer; stale timeout and reader callbacks cannot release new custody.
The independent B polling reader and C4a inbox cursors retain their contracts.

V2 release preserves the historical workspace and snapshot instead of clearing
lease metadata or deleting the workspace. This applies to terminal retry cleanup,
terminal running reconciliation and later startup cleanup of v2 snapshots. The
operator projection distinguishes live, historical, missing and unverified
ownership; historical metadata is never held/reclaimable authority. Legacy cleanup
retains its existing physical-lease checks without claiming a cross-process
transaction over workspace deletion. Pending audit/corrupt/IO outcomes remain
visible rather than being treated as missing.

C3 does not fence all effects after the gate, recover volatile custody after a
restart. C4b and C5 separately move their issue-resolution reads to shared readers;
PR inspection, controls and business writers retain their synchronous limits.
Validation of this candidate remains pending until the recorded repository gates.

GitHub follow-up custody is bound to the explicit destination workspace. A local
claim from another root is rejected before its payload is lent or renewed; new
acquisitions capture their lease location and destination before waiting on the
lock. A rejected location does not fall back to a manual snapshot write.

Retry budget context follows the captured custody workspace after worker `DOWN`.
A retry/resume or gated dispatch rejects a current workspace/storage location that
conflicts with that custody before starting new work. `lease.released` is written
to the captured ledger path. Physical lease removal and ledger persistence are not
one transaction: if the latter fails, local custody is retired and
`lease_release_audit_failed` remains explicit; operator retry does not report
success or recreate the lease. Generic runtime events and post-gate provider effects
are not covered by this storage guarantee.


## Linear inbox continuation (C4b)

The coordinator retains one captured physical batch (100 rows, 4 MiB) and one
head. Tracker lookup uses B; active revalidation shares the admission reader with
poll candidates and ready retries, rotating poll → retry → inbox over ready
classes. An existing C3 promotion keeps its physical slot and acquisition deadline.
Waiting for admission or backoff releases B. Appends do not extend the original
batch. A cancelled reader keeps its physical slot until guardian DOWN.

After checking context and rebinding that captured prefix, consecutive rows with
no decodable scheduling event or usable entity ID are discarded locally. This
bounded step stops at the first valid event, an existing head or an active inbox
reader. It preserves the captured cursor for checked acknowledgment and does not
start another approval read for each discarded row. Valid decisions still yield
through their ordinary continuation before processing the next event.

The head is bound to physical location, generation, cursor, configuration,
worker/custody identity and observed routing cache. The coordinator recaptures the
prefix before applying a retained result or authorizing its gate. This check does
not hold an inbox lock across tracker, lease, audit or workspace I/O and is not a
transaction with reset. Invalid raw identities cannot update another issue.

Accepted lookup knowledge immediately invalidates older C1/C2/C3 decisions. Its
own Issue projection stays private until the local decision completes. Correlated
completion follows actual custody through promotion and the gated worker. Only
successful gate authorization completes an accepted dispatch; queueing a reader or
worker does not. Local reconciliation or a definitive rejection can complete the
row without a provider run. The worker's eventual outcome is a separate concern.

Applied rows accumulate a captured cursor. One correlated local callback confirms
that prefix after application. Ack failure retains the cursor and subsequent drain
opportunities retry only confirmation, including across a root change. An obsolete
ack cannot confirm a new generation. A current 429 preserves the unprocessed head
and schedules one correlated wakeup; it confirms only the preceding applied prefix.
Old transport success cannot clear newer backoff. Reader/storage failures have no
new autonomous retry loop. Explicit release or release-audit debt remains blocked
for that owner, even if a later observation sees a missing lease; no repair of that
audit is implied. No incomplete head publishes its own cache projection.

The contract assumes one consuming coordinator and retains at-least-once delivery
after owner restart. C5 separately moves GitHub issue-resolution reads to B. PR
inspection, controls, tracker writes and local business effects retain their existing
availability limits. This change does not establish I2
post-gate validity, I3 recovery, distributed exactly-once processing or acceptance
against an external provider. Verification results belong to the frozen validation
record, not the existence of these test cases.

## Admitted execution and usage (I2a)

An admitted worker captures its complete dispatch ticket, physical lease token and
owner PID before starting. `AgentExecution` scopes that context to the worker;
it does not reconstruct authority from a provider payload, current configuration
or a mutable lease projection. An identified or partially identified snapshot
cannot enter delivery as legacy because its execution context is missing.
Nested execution contexts are rejected without resetting consumption or replacing
the first failure. The verifier uses the existing context with its own session.

Session bindings come from supported provider handles: the local session ID for
Claude/CodexCLI and thread ID for AppServer. A CLI process's raw session ID is a
different namespace and never replaces the runtime binding. Canonical runtime IDs
must match. Two sessions may be live and at most 64 bindings, including retired
ones, may exist per dispatch. Capacity and supported accounting capability are
checked before opening a transport; retired identities are neither reused nor
evicted. Before a turn starts, its provider and exact handle must match the
registered binding. Returning from verifier B to the still-live handle A selects
A's existing record.

Each invocation has a monotonic ordinal. Callbacks check worker PID, captured
context, binding and ordinal before sending an update or running a tool. The
owner checks the actual caller of each confirmation against its running entry
and custody. Provider data is separate from this envelope. A single confirmation
call waits up to 5,000 ms, including mailbox and checkpoint time, without retry.
Timeout does not cancel an in-flight checkpoint: persistence may finish, but the
worker must not continue controlled effects.

CLI usage is observed before normalization as an absolute total for the current
invocation. Supported AppServer total-token-usage shapes are absolute for the
thread; explicit turn-completed usage is scoped to the invocation. Unknown scope,
last-only reports and malformed dimensions are errors, not zero usage. Input and
output must be explicit nonnegative integers; absent total may be derived from
those two valid dimensions. An explicit valid thread total takes precedence over
an accompanying last report. Complete absence of usage is distinct from null or
partial usage. AppServer observations are checked while awaiting the turn-start
response as well as during the turn, before replies or tools can continue.

For each binding and dimension, let S be its accepted contribution, T its maximum
thread total, C its contribution at invocation start, and U the maximum reported
for that invocation. New contribution is `max(S, T, C + U)`; only the difference
is added to the durable issue baseline. Duplicate reports do not add consumption,
and another session or retry does not reset prior accepted totals.

The owner installs deltas, totals and related telemetry only after the audited
checkpoint succeeds. `record_token_usage/4` receives already authenticated captured
context, checks the exact physical token and admission, and writes monotonic usage
to the matching existing snapshot. It neither creates nor adopts a snapshot.
The legacy `/3` path rejects complete or partial identity inside the snapshot lock
before applying defaults. Lock order is snapshot, physical lease verification,
then admission/ledger verification. These cooperating local checks are not a
distributed transaction between lease and snapshot. A mutable snapshot lease
header is not an additional authority for binding a ticket to a token.

The first `accounting_uncertain` cause persists in worker and owner. Successful
later callbacks or a provider that catches the callback error cannot clear it.
Confirmation precedes controlled tools, approval continuation, turn effects,
another invocation and `after_run`; transport cleanup may still run. Plan,
implementation, verification and active/passive wrappers preserve this terminal
reason instead of converting it into ordinary blocked output or success.

The owner retains the worker monitor until DOWN. It compares monitor, PID and
captured admission before removing that worker, and retains the uncertain claim
and journal without finish, retry, tracker transition or successor cleanup.
An explicit healthy stop retains any intended retry until the original DOWN and
successful dispatch close; later accounting or custody uncertainty prevents it.
Previously persisted deltas are not counted again at termination. Recovery of
this uncertainty requires a separate explicit reconciliation contract; restarting
or a later healthy refresh does not grant replay authority.

Direct legacy adapter calls remain transports without these admitted-execution
guarantees. Audited custom providers require an explicit accounting contract;
implementing the transport behaviour alone is insufficient. I2a cannot prevent
effects a remote provider already performed before reporting usage. I2b material
validity, I2c operation binding, I3 recovery and final acceptance remain separate.

## Current execution and material state (I2b)

Admission captures one canonical raw source before reserving its dispatch marker.
The source distinguishes a present snapshot from an absent one; a derived view
may supply legacy defaults for policy decisions, but those defaults never become
the admitted material witness. Active admission may create a legitimate missing
snapshot through the existing path; passive admission cannot bootstrap one. The
admitted raw snapshot returned by checked admission initializes both owner and
worker. Neither a provider result nor a later read replaces that witness.

Material comparison preserves field presence as well as value. Its finite set is
`stage`, `last_ledger_event_id`, `review_claims`, `review_threads`, `pr_url`,
`repo_url`, `policy_pack`, `effective_policy_class`, `stop_reason`,
`implementation_turns`, `policy_override` and `review_return_stage`. Usage, lease
renewal timestamps, diagnostics and resume context are excluded. Raw absence is
therefore different from a stored default. An ordinary check reads current state
while requiring the captured ticket, complete lease token and unchanged material
projection; it does not adopt a control change or infer authority from a header.

Workers send their material witness separately from the immutable invocation
envelope. The owner authenticates PID, monitor/custody, context, binding and ordinal
before interpreting that witness. Foreign or obsolete callbacks cannot mark or
write the successor. A proven precondition failure becomes `stale_execution` with
the captured run/dispatch IDs and original cause, including a conflict proved
during a checkpoint or owner confirmation. A persistence failure or uncertain
confirmation becomes `accounting_uncertain`. The first retained cause survives later
callbacks and DOWN; a later success cannot clear it. Both hold the captured claim
and pending journal without ordinary finish, automatic retry or workspace cleanup.

Checked writes apply finite attribute deltas to fresh state inside the existing
snapshot lock. They preserve current usage, lease and unrelated fields. Only a
successful own compare-and-set followed by owner acknowledgment advances the
worker's material witness. Reading a newer snapshot never grants that advance.
Usage validates current authority before proposing its arithmetic and again in
the checkpoint; counters and telemetry are installed only after persistence.

Own `blocked` or `done` transitions have a separate terminal acknowledgment. They
retain the caller's domain stop or done result and immediately deny new tools,
turns, writes and hooks. The existing blocked-stop comment and tracker movement
use a specific confirmation before each notification, preserving their order
after the successful blocked write. That confirmation grants no other execution.
Done retains the existing tracker movement before its terminal write. DOWN checks
that exact terminal state under captured custody before finishing once with the
actual exit reason; it does not run policy or schedule a retry again.

A policy stop performed by the owner may retain a narrowly bound final-usage
receipt for observations already belonging to its captured invocation. The receipt
is bound to previous/next material state, binding, ordinal and stop outcome. It
does not permit another invocation, repeat policy or authorize a different run.

Workspace confirmation finishes before the lifecycle acquires the snapshot lock.
The checked lifecycle validates before metadata relocation/hooks and again after
restoration, without calling the owner under that lock. Restoration is attempted
even if the hook failed; both failures remain visible. An audited `after_run`
shell failure is an error, while legacy callers retain their existing warning
behavior. Runner cleanup preserves the primary stop, done result or exception.
It logs an unexpected secondary cleanup failure; expected `execution_stopped`
cleanup denial after an acknowledged terminal does not become a second failure.
After ordinary nonterminal success, cleanup failure is propagated. Closing a local
transport remains possible after execution stops.

Delivery, review reconciliation and verifier consumers check before controlled
operations and after waits before consuming results or continuing. They propagate
execution terminals before ordinary network fallback, retry or verdict handling.
Review persistence uses finite deltas rather than replacing the complete snapshot.
Initial policy override is applied once at entry; recursive continuation cannot
reimpose an old override over an operator control.

These checks coordinate cooperating local code. A check followed by a remote call
is not a distributed transaction: an observed reply, publication or deploy command
is not rolled back after a subsequent conflict, and no automatic replay is
authorized. Existing bulk GitHub calls are guarded at their consumer boundary.
Deploy uses the versioned operation binding described below. Session lifecycle,
uncertain-run reconciliation and final thesis acceptance remain P2/I3/E1 requirements. Test and integration results belong to
the frozen validation records, not this description of the implemented contract.


## Deployment operation binding (I2c)

Version 2 opening requires the worker's captured dispatch, complete physical token,
raw material witness and owner-confirmed invocation provenance. New version 1
operations require genuine raw absence of run identity and C3 ownership. Partial,
pending or unreadable state cannot downgrade to legacy. Only the process that opened
a confirmed operation retains its exact ticket/live reference; no restart import or
reconstruction is supported.

A valid original result consumes its observation attempt before preparation or IO.
The event identity is retained before encoding. Preparation, encoding, marker or
ledger failure cannot restore unused status; repetition returns the existing attempt
without another preparation, lock or writer action. A still-authorized disk marker
cannot override that private consumed state. Legacy return shapes remain unchanged.

The original result can be observed under live custody after a guard rejects further
execution. The receipt separates authority and persistence and does not authorize a
command, tracker effect, transition or finish. First worker terminal remains exact;
secondary failure is logged with safe causes and stack locations, without formatting
arguments or command output. Without an earlier terminal, an unexpected exception is
reraised with its original stack.

Continuation checks the original authority and material state inside one workspace
lock. A proven denial of its own evidence stays retained even if files are restored;
foreign tickets and malformed caller inputs cannot install that denial. The checked
CAS returns and privately anchors its exact previous/next/event receipt. Owner ACK
must succeed before the worker recognizes that receipt. Finish compares it with the
current successor and original chain; it does not use the pre-CAS material context.
Own done uses a terminal-specific confirmation, never generic execution permission.

Only an authorized checked runtime stage transition can derive last_agent_session.
The diagnostic is committed with its own event reference and snapshot digest, without
a separate write. Fresh authenticated session provenance and checked historical prior
session evidence remain distinct; neither public attrs nor a retired handle can forge
a current binding. The diagnostic is excluded from the worker material projection.

Public stop can terminate a worker before a result arrives. In that case no observed
map is fabricated. Its authentic DOWN may close DispatchAudit as worker termination
while DeployAudit stays pending; that event is not successful deploy continuation.
Shell exit maps passed/failed, and exceptions map unavailable. A distinct timeout
observation is tested at the observation API only; no public shell timeout detection
or deadline is introduced by this block.

DeployAudit.inspect_pending returns only checked finite diagnostic fields. It never
imports a ticket, writes, reconciles or removes evidence. All absent/corrupt/pending
states stay distinguishable. A later release must establish its loaded build and
acceptance separately from source integration and local test results. See
[deployment audit](deploy-audit.md) for the persistence and remote-effect limits.


## GitHub event continuation (C5)

One captured physical inbox batch, bounded to 100 rows and 4 MiB, retains its cursor,
generation and sorted workspace index. Resolving and refreshing after effects use
the existing B polling reader; admission shares A with poll, retries and C3. No third
reader or new queue service is introduced. Local callbacks retain operation identity;
a stale result cannot acknowledge a replacement queue or repeat completed workspaces.
An ack failure retries only confirmation. Restart retains at-least-once delivery,
not durable exactly-once effects or a scan of workspaces created after capture.

A live worker defers every C5 material effect, including local observations. B is
free while the head waits. Only a confirmed normal audit close wakes fresh resolution
of RAW, source, routing and review feedback. The worker's retry metadata and budget
remain conserved until a real admission decision; stale or uncertain closure stays
blocked. Fresh feedback may make review work unnecessary, and current stage/policy
may make CI ineligible. This is not semantic deduplication of CI events whose current
state remains eligible.

Checked resolution captures id, identifier, source and context before lookup. Backend
errors are semantic outcomes inside a reader envelope; a reader crash remains a reader
failure. Manual lookup reads only the exact target record. Only its actual enoent,
explicit manual source, enabled context and valid current binding/policy can authorize
a seeded local continuation. Corruption, IO failure, disabled source or a record that
disappears during refresh cannot become a seed. Remote missing/error may record the
permitted local observation or human action, but cannot reopen or dispatch work.
Invalid reference or returned identity authorizes no business effect.

Coordinator writes compare a distinct 19-field projection: the worker's 12 material
fields plus resume_context, last_ci_failure, issue_source, runner_channel,
runner_instance_id, last_review_decision and next_human_action. Missing and explicit
null differ. Four closed delta shapes cover review/CI observations and their existing
autonomous transitions; unrelated attrs are rejected. Fresh usage and physical lease
renewal are preserved. Identity/binding journals, workspace, physical token, local
custody reference, controls and the original expected material remain checked.
This does not broaden the worker projection or authorize adopting concurrent state.

Applying records the checked local change, then its tracker outcome and follow-up
result once. Only a confirmed writer outcome can proceed to fresh issue resolution;
seeded local work has no fictitious successful tracker call. Failed or uncertain
writers retain the real partial outcome without refresh, replay or successful ack.
Current tracker 429 observations update shared backoff against the captured context.
An initial-read 429 resumes fresh resolving; a post-effect 429 resumes only refresh.
Backoff does not erase authenticated worker-close/retry lineage, grant ownership,
repeat effects or allow old success to clear a newer transport observation.

Custody starts at actual acquisition with the C3 monotonic deadline. Lock waits,
writers and admission count toward that same deadline; phase changes, 429, renewal
and transfer cannot extend it. Checks follow blocking validation and precede each
new business writer or gate. An already-started writer completes its real outcome
or uncertainty even if the deadline crosses; expiration cannot claim zero effects.
Canceled reads retain their physical slot until DOWN. Cleanup releases only the
still-owned token and local reference, never a successor or transferred custody.

Admission retains the original coordinator projection across DispatchAudit.begin,
checks its own admitted RAW and current RAW against it before creating a child, and
uses the actual DispatchGate. Rejection before child creation closes only its own
ticket as not_started. A real failed close retains that exact ticket, error and owned
claim; stop, pause, retry and deadline cleanup cannot silently release that uncertain
claim. No journal reconstruction, second finish attempt or automatic recovery is
provided. Once a child exists, its real worker/audit lifecycle owns termination.

Controls invalidate the pending continuation before later effects, including controls
that leave no durable stop marker. Original retry context and downstream budget guards
remain in force; an eligible preexisting blocked run is not universally vetoed by C5.
PRWatcher, tracker mutations and local writers remain synchronous. Availability during
held issue reads does not prove prompt stop during these effects, distributed atomicity,
loaded-release correctness or thesis acceptance. Verification belongs to the frozen
composed source and its external validation receipts.


## Physical inbox prefix continuation

InboxPrefix owns the captured horizon, retained physical rows, applied cursor and
post-confirmation boundary for both intake adapters. Its six operations calculate
continuity without IO, execution authority, callback effects or coordinator state.
The owner projects only physical fields and merges returned geometry into the
existing batch; no second persistent copy of the prefix is introduced.

Tracker consumes applied or discarded rows before ACK and can accumulate one
applied cursor across several rows. It checks exact membership of its current
head. GitHub retains the completed row, workspace outcomes and custody until ACK
succeeds, and checks the whole retained prefix before effects. Pending ACK remains
in the coordinator because confirmation can outlive a batch retired by context.

Before confirmation, row equality includes the original physical cursor and
digest. After confirmation, rebind checks the confirmed end offset, generation,
original retained records and their end offsets while allowing storage to supply
new start offsets/digests. Later appends never enter the captured continuation.
A mismatch does not manufacture a replacement cursor or authorization.

The owner retains confirmation order: GitHub confirms disabled custody before
recapturing its remainder and publishes a successor head only after successful
rebind. A failed recapture retains the old head and blocks it. Tracker clears its
applied candidate before rebind and clears obsolete generation cursors before
cleanup, including a retained head with release debt. GitHub generation errors
keep the pending ACK/head under its existing error policy. Neither adapter treats
these calculations as durable exactly-once delivery or new-source acceptance.

## Stage provider configuration

Config normalizes workflow configuration dictionaries to string keys and validates
agent.providers as a string-key map with the existing unrestricted value contract
and reads the string form of an existing stage atom. YAML, JSON frontmatter and
the legacy codex section follow the same route. No stage atoms are created.

The agent mapping retains precedence over the legacy mapping, including an
explicit empty agent map masking legacy selections. Missing mappings preserve
the existing global or explicit provider fallback. Unknown provider names retain
the existing Codex fallback. Model and reasoning selection are unchanged.

These guarantees cover configuration and module resolution only. DeliveryEngine
currently captures its initial session; live provider handoff requires the
separate session-lifecycle change and public execution evidence. Configuration
regressions do not prove handoff, custody, accounting or new-source acceptance.
