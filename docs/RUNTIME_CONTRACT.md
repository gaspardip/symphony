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

GitHub business processing remains synchronous. After applying a prefix, the coordinator
retains an unconfirmed cursor on storage failure and retries only that ack at the
next drain opportunity. The cursor keeps its original location across configuration
changes. A reset invalidates it; other mismatches remain blocked and visible.
Owner restart can replay effects: delivery is at least once, not exactly once.
The storage layer introduces no autonomous wakeup or reader. The Linear continuation
below supplies those coordinator behaviors without changing the cursor contract.


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
restart, or move webhook/GitHub/control business I/O to background readers.
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
after owner restart. GitHub, controls, tracker writes and local business effects
retain their existing availability limits. This change does not establish I2
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
Deploy uses the checked state/continuation bridge; versioned operation binding is
I2c work. Sessions, uncertain-run inspection/reconciliation and final thesis
acceptance remain P2/I3/E1 requirements. Test and integration results belong to
the frozen validation records, not this description of the implemented contract.
