# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root, with the delivery responsibilities
defined in the [current runtime contract](../docs/RUNTIME_CONTRACT.md).

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/gaspardip/symphony.git
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

Use the exact Git revision associated with your validation evidence. Cloning the
default branch does not include local recovery work that has not been published.
Select and review a workflow for the target repository before starting the service;
the checked-in workflow is configured for Symphony self-host operation.

## Configuration

The read-only verifier receives changed source and test content selected by the harness's
`verification.behavioral_proof.source_paths` and `test_paths` (or the existing behavioral-proof defaults),
before documentation content. Additional changed-file context is limited to four files and 2,400 characters per file, redacts
identified secrets, and explicitly marks binary, unreadable or unsafe paths as omitted. Symlinks are not
followed. The verifier still cannot use tools other than its result-reporting tool, and must block when
the supplied evidence is insufficient.

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.
The acknowledgement flag shown above is required for every runtime start, including
when no workflow path is passed.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.model` and `agent.models.<stage>` select the model requested on Codex `turn/start`.
  A model override applies to that turn and subsequent turns in the same thread. When a later
  turn omits the model, Codex inherits the previous selection; omission does not restore the
  initial model. A successful `turn/start` response does not confirm the model actually used.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- Delivery operations fetch the harness `base_branch` into `origin/<base_branch>` even
  when a single-branch clone does not track it. Reset creates or resets that local base
  explicitly, discards local code changes, and restores `.symphony/run_state.json`.
  The base must exist on the remote; a failed fetch stops the operation.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and new worker dispatch are halted until fixed.
  After a failed hot reload, reads and reconciliation can still use the last valid configuration;
  each new dispatch checks the current file before starting a worker. Restoring a valid file
  re-enables dispatch.
- An existing `workspace.root` must be a directory. A missing root may be created during
  workspace bootstrap; a file or an inaccessible path blocks configuration validation.
  Configuration rejected at dispatch records a `config_invalid` ledger event with the cause.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Selected process boundaries

Two optional top-level workflow selections have separate scopes:
`execution_boundary` covers configured harness commands run by `RunInspector`;
`provider_execution_boundary` covers the Codex app-server, Claude CLI and Codex CLI
child transports. Selecting one does not select the other. Both maps require
exactly these three fields:

| Field | Required value |
| --- | --- |
| `policy_file` | Absolute path to the external policy file; no `~` or environment expansion. |
| `sha256` | 64 lowercase hexadecimal characters matching the exact policy file bytes. |
| `timeout_ms` | Integer from 1 through 3,600,000; preparation and execution share this deadline. |

An absent selection preserves the historical execution path and does not establish
confinement. A present null, malformed selection, unreadable or changed policy,
unsupported platform or failed launch is an explicit error; it cannot fall back to
legacy execution. The checked-in workflow leaves both selections absent.

The policy is a JSON object with exactly six fields:

| Field | Required value |
| --- | --- |
| `version` | `1` |
| `backend` | `"macos_deny_default_v1"` |
| `workspace_root` | Existing canonical physical directory containing the issue workspace as a strict descendant. Broad system roots are rejected. |
| `shell` | Exact path of one executable listed below. |
| `executables` | 1–32 objects, each with exactly `path` and `sha256`; paths are physical executable files outside the candidate root, with matching content hashes. |
| `read_roots` | Up to 16 physical directories outside, and not containing, the candidate root. Broad system roots and the user's home directory are rejected. |

Keep the workflow and policy outside the entire candidate root. The policy,
executables and read roots must pass the ownership/write-mode checks; candidate
code must not supply these resources. The workspace must already have valid Git
metadata and a physical `.symphony` directory. The policy protects `.git`, its
resolved Git directories and `.symphony` from child writes.

The native launcher replaces the environment before candidate shell execution:
only the selected tools' `PATH`, private `HOME`/`TMPDIR`, and `LANG=C`/`LC_ALL=C`
are provided. Only standard input, output and error are inherited. The generated
macOS profile denies operations by default, permits the declared executables and
bounded read locations, and limits writes to the workspace outside protected
metadata and the private home/temp directories. It grants no network access.
The packaged native helper must match the running macOS platform and architecture.

This backend is offline. It does not establish working remote inference or
publication, and cannot inherit host credentials to make those paths work. Host
Git/`gh`, publication, lifecycle hooks and host tool callbacks remain outside this
selected child boundary. It is not a boundary against a malicious trustee process
with the same operating-system user, nor a guarantee of escaped-daemon cleanup.
Provider-native sandbox options are separate from this selection. Source, runtime
and packaged-executable verification remain separate evidence.

## Configuration captured for issue reads

Each logical issue read captures the validated workflow once. Linear pagination,
viewer lookup for `assignee: me`, request headers, endpoint and project use that
same capture. A manual read uses the store root and enabled flag captured with
it. A reload applies to the next read, so an in-flight read cannot switch projects,
credentials or manual stores halfway through.

Callers that need to retain this boundary can use `Config.tracker_read_context/0`
and pass its result as the last argument to the issue read functions on
`IssueSource` or `Tracker`. The context also retains the selected Linear client
module. Injected clients continue to receive their original callback arguments;
freezing their internal configuration remains the responsibility of that client.
The context's fingerprint covers all validated workflow options and the resolved
read settings. Its `Inspect` implementation omits the captured values, including
credentials. Do not serialize or log its fields.

This capture uses the existing workflow loader policy: after a rejected hot
reload, it may represent the last valid configuration. A fingerprint compares
applied configuration, not the validity of an unapplied file. Read context capture
is synchronous; it does not itself move tracker I/O out of the orchestrator,
change source error merging, or implement stale-result cancellation.

The `IssueSource.fetch_candidate_outcomes/1`, `fetch_issues_by_states_outcomes/2`
and `fetch_issue_states_by_ids_outcomes/2` APIs retain each source result in a map
with `tracker` and `manual` keys. A disabled tracker is `:disabled`; an enabled
tracker retains its success or error tuple, even when manual issues exist. A
disabled manual source returns `{:ok, []}`. These APIs let a coordinator handle
remote rate limits before combining source results; the existing merged APIs
retain their prior error behavior.

## Asynchronous startup and polling reads

Startup terminal cleanup and polling use a supervised `TrackerReader` with one
active read. The coordinator remains the sole owner of State and applies results
only after checking the operation reference, captured configuration, current worker
identity and newer backoff decisions. Stop, pause, hold, resume and policy changes
invalidate affected data from the current cycle; priority changes remain in current
State. The read context also captures the policy pack from the same options.

Notifications retain the scheduled cycle-message boundary and pending modes are
coalesced. Manual success does not erase a remote 429 or its diagnostic. Candidate
lists still refresh at zero capacity. Read errors preserve running workers, and
cleanup respects a lease acquired during the read.

Ordinary discovery/healing admission uses one additional reader before acquiring
its lease. A single sorted batch advances after missing or ineligible candidates;
new polls do not accumulate admission batches. Returning results must match the
issue ID and identifier and pass current configuration, controls, worker,
capacity, budget and audit checks. Stale data cannot clean newer work.

Retries now share that admission reader. Timers identify their generation, and
lookup/refresh preserve attempt and budget context until a current dispatch or
explicit reschedule. Ready retries rotate with poll admissions and ready Linear
inbox heads; ordinary retries
query candidates and passive continuations query their issue. Stale callbacks
cannot consume a newer retry, and refresh errors explicitly reschedule instead of
abandoning the entry. Current identity, capacity, ownership and audit checks still
apply before worker authorization.

This is a partial availability boundary. C3 promotion and C4b Linear inbox reads
use the shared readers described below, as do C5 GitHub issue-resolution reads. PR
inspection, immediate controls, their pre-dispatch reads, tracker writes and local
effects remain synchronous;
applying a result may still invoke those paths. See [the phase contract and
regressions](../docs/tracker-poll-async.md).

## Bounded retries during implementation

`policy.token_budget.broad_implement` lets the runtime retry an implementation turn
that exceeded its input budget using a smaller prompt and explicit file paths:

```yaml
policy:
  token_budget:
    per_turn_input: 150000
    per_issue_total: 500000
    broad_implement:
      enabled: true
      auto_retry_limit: 2
```

The defaults are `enabled: true` and `auto_retry_limit: 2`. Set `enabled: false`
to retain a hard stop when the per-turn budget is exceeded. Admission requires the
active execution's workspace and the `implement` stage. Review fixes and CI
repair retain their separate budget behavior.

The first retry focuses on one exact file found in the issue, agent updates, or
persisted progress. A subsequent retry can add one exact required file, once;
it cannot keep expanding the scope. The runtime persists the focused paths,
retry count, pressure and stop reason so redispatch can resume the same scope.
Without a usable path or after the bounded scope is exhausted, the issue becomes
blocked with a budget rule explaining the next action. The total issue and output
budgets still apply, including when the workspace contains pending changes.

Issue token totals survive worker retries and runtime restarts. Each worker keeps an
immutable baseline from the persisted snapshot and adds only its own provider usage.
Usage updates checkpoint absolute totals, so repeated cumulative provider reports
are not counted twice. Snapshot writes preserve the highest totals for the same
issue, including when a stage writes an older snapshot. A new issue identity starts
at zero. This adds one snapshot write per update that reports additional tokens.
If checkpointing fails, the worker stops, the tracker is asked to block the issue,
and new dispatch for that issue remains blocked in the current runtime with an
explicit persistence error; repair storage and reconcile the unrecorded usage before
restarting. Usage the provider has not reported cannot be checkpointed.

## Codex app-server shutdown

A PID-origin `:shutdown` received during app-server startup or turn streaming closes
the protocol port and preserves the worker's `:shutdown` exit reason. AgentRunner's
`after_run` hook can then run after port closure. This also covers callers that catch
an exit from `start_session`; the prior `trap_exit` flag is restored. Port errors and
read/turn timeouts keep their existing behavior.

This cooperative path does not guarantee cleanup after an abrupt BEAM termination
or completion of arbitrary operating-system descendants. The regression fixture
uses a local Python 3 JSONL provider and a local Git repository, with no remote
provider, tracker, or publication calls.

## Pending deployment results

Preview and production deploy commands require a checked stage-entry event and a
durable intent before execution. A sibling `.deploy-audit` journal retains the
operation until the observed successful result and its own continuation are
confirmed. A failed command can have partial effects and leaves the journal pending.

Pending journals reject new dispatch, retry, approvals, workspace cleanup and hooks.
Status reads, lease/token updates and stop remain available. There is no automatic
retry, expiry-based cleanup or recovery command that deletes this evidence. Inspect
the original ledger and deployment outcome before planning reconciliation. See
[deployment audit](../docs/deploy-audit.md) for guarantees and limits.

## GitHub events and archived workspaces

Review and CI events match a snapshot only when its directory is the canonical
path derived from `issue_identifier` under `workspace.root`. Copies such as
`ISSUE-1.base-branch-blocked` are excluded before feedback lookup, lease handling
or snapshot updates, even if they contain the same pull request URL. Existing
runner routing and lease checks still apply to the canonical workspace.

## Unreadable run snapshots

A missing `.symphony/run_state.json` starts a new run at `checkout`. Invalid JSON
or a non-object snapshot instead produces a blocked state with rule
`runtime.snapshot_unreadable`. New worker dispatch and delivery bootstrap stop
before starting an agent. Normal save, transition, update and lease synchronization
operations return an error and preserve the unreadable bytes, including snapshots
staged during workspace bootstrap.

Within one BEAM node, snapshot updates, stage transitions, token checkpoints and
lease changes serialize their complete read-modify-write operation per workspace.
Lease refreshes therefore preserve a concurrently recorded stage and diagnostic.
This lock does not coordinate independent BEAM nodes or separate checkouts.

Stage transition counters retain string stage keys across snapshot reloads. Returning
to a stage increments its stored count; updating the current stage does not increment
it or append a history entry. Existing stored counts are preserved, but counts lost
before this correction cannot be reconstructed automatically.

Restore a valid snapshot from a trusted backup to resume. The runtime does not
replace a corrupt snapshot with a fresh checkout automatically. Older valid
snapshots still receive new default fields, and the existing handling of snapshots
belonging to another issue is unchanged.

## Terminal checkpoints and passive continuations

Automatic dispatch does not resume a persisted `blocked` or `done` checkpoint just
because the tracker still reports the issue as active. Eligibility is checked again
after acquiring the lease, and checkout repair occurs under that ownership. The
resulting stage determines whether an active agent or a passive worker is needed.
A passive checkpoint repaired to an active stage refreshes tracker eligibility and
uses the normal agent hooks and pre-run checks.

An old retry timer cannot clear a newer blocker. Explicit operator retries remain
available, and the existing review-fix continuation requires current progress proof
and ownership before resuming. Passive continuations reacquire their lease even
when the local claim remains cached, and an already running issue is not spawned
a second time. A failed lease release remains visible and does not authorize work.

## Audited stage transitions

A stage change records its intent before writing the candidate snapshot. The
candidate carries `audit_pending` until the exact `stage.transition` confirmation
has been persisted and synchronized. A failed intent leaves the previous snapshot
unchanged. An interruption after writing the candidate blocks normal reads,
mutations, worker bootstrap and workspace cleanup with `runtime.audit_pending`.
Workspace creation and removal retain the local snapshot lock throughout hooks
and cleanup, including when the workspace did not initially exist.

Workspace lifecycle checks also refuse overlap with the runner install, current
checkout, or selected release before creation, reset, temporary-file cleanup,
removal, or a configured hook. The check resolves symbolic links in existing path
components and compares filesystem identities of existing ancestors, so case
variants of the same directory are protected even when the workspace is new.
Unreadable paths, unavailable filesystem identities, symlink loops, and parent
traversals after a missing path component return explicit errors. A rejected
hook is logged. The best-effort return contract of `after_run` is unchanged, but
it cannot run in a protected path. These checks do not make hooks a sandbox or
protect against concurrent filesystem changes by another operating-system
process. Case variants of path components that do not yet exist are not
identified as aliases by this check.

`RunStateStore.reconcile_pending_transition(workspace)` is an explicit local
reconciliation operation. It only finalizes a pending snapshot whose digest,
intent and exact confirmation match the original, fully readable ledger. It does
not append a missing confirmation, retry an uncertain write or increment counters.
An absent confirmation, changed ledger path, corrupt ledger or altered snapshot
keeps the evidence blocked for investigation. Preserve both files; clearing the
marker manually is not reconciliation.

The checked ledger API preserves event identity and reports persistence errors.
It validates the complete JSONL ledger before append, so each append costs O(n)
in the current ledger size. Cooperating checked operations serialize locally and
use a filesystem lock across processes; abandoned locks require investigation.
Legacy `record`/`append` callers remain outside this contract. This change covers
stage transitions, not atomicity of worker dispatch, publication, merge or deploy.
Snapshot coordination is within one BEAM node; power-loss durability is not claimed.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).

Logical run identity is established during audited admission, before workspace
hooks or provider work. Retries reuse `run_id` and create a new `dispatch_id`.
Legacy snapshots remain readable and are explicitly adopted with checked audit
evidence at admission, preserving their budget usage, stage and approvals.
A `run_identity_pending` snapshot requires investigation with its original ledger
and dispatch reservation; restarting does not clear it. See
[the dispatch identity contract](../docs/dispatch-audit.md#durable-logical-run-identity).


Claude/CodexCLI return transport observations. DeliveryEngine applies local Git
preparation and delivery reporting after transport; VerifierRunner applies no
local delivery effects and still requires its own structured verifier report.
Failed CLI transport skips preparation. Empty progress evidence is never filled
by the runtime. Direct adapter and ErrorHandler transport calls no longer commit
or synthesize delivery reports. Failed Git detection, formatting, staging, commit
or report acceptance now returns `turn_effect_failed` and stops plan/implement
before the next stage; prior local effects remain. Missing Git base references
are errors without fallback, and delivery requires an executor returning a
string-keyed boolean `success`. I2a checks admitted context and persisted usage
before controlled continuation; material stage/review validity remains I2b work. See
[the runtime contract](../docs/RUNTIME_CONTRACT.md#cli-transport-and-local-turn-effects).

### Inbox state migration and recovery

Tracker and GitHub inbox state version 2 uses queue generations and physical byte
cursors. New empty inboxes initialize on enqueue. Existing legacy inboxes stop with
`migration_required`; reads do not migrate or replace missing/corrupt state.

Stop all older writers before upgrading an existing inbox. In a local runtime
configured with the intended `:log_file`, capture each module's `location()` and
call `TrackerEventInbox.migrate_legacy(location)` or
`GitHubEventInbox.migrate_legacy(location)` respectively. Check `:ok` and inspect
`stats()` before restarting intake. Do this separately for every configured root.
Migration preserves JSONL bytes, dedupe and the physical meaning of the old count;
it cannot infer which effects an older malformed-row cursor already applied.
Do not run an older binary concurrently with the new writer protocol.

`capture(location, %{max_rows: 100, max_bytes: 4 * 1024 * 1024})` returns physical
rows with cursors. Use `ack(row.cursor)` for a completed prefix; numeric ack is
removed. The inspection helper `pending_events/1` still returns maps, but raises a
specific inbox error on storage failure. Stats expose unknown depth as nil and
mark bounded counts incomplete. A record, including its newline, may not exceed
4 MiB; oversized enqueue is rejected before writing.

All operations share a filesystem lock for the same absolute configured location.
An occupied/orphaned lock is a visible error; the runtime does not steal it. A
partial tail blocks append/reset and is never repaired implicitly. Investigate
and preserve the files before any manual recovery. Reset is now logical: it keeps
JSONL history, changes generation, advances to complete EOF and clears dedupe.
It refuses corrupt or partial queues and is not a repair or compaction command.

State uses atomic rename; append and state publication are not a single transaction.
An uncertain failure can redeliver events. The live coordinator retries a retained
ack without replaying its already applied prefix, while restart remains at-least-once.
Errors expose sanitized phases/codes, not raw event payloads. Storage checks alone
do not establish availability; C4b supplies the Linear read continuation below.

### Build identity diagnostics

`mix build` first compiles dependencies, then runs the source driver in the same fresh
Mix process, forces compilation of Symphony and
creates `bin/symphony` plus `bin/symphony.build.json`. It also generates the ignored
`priv/build_identity.json` embedded in the escript. Do not use a long-lived development
VM or call `escript.build` directly when a provenance receipt is required. The driver
uses the pinned Elixir/Mix 1.19.5 and OTP 28 APIs; it neither starts Symphony nor calls
compiled Symphony helpers. Readable dirty inputs are identified as dirty; a file still listed by Git but missing
from disk, such as an unstaged deletion, is rejected as source unavailable. Exclusions are confined to the actual Mix project
and recorded in the manifest; similarly named folders elsewhere in Git remain inputs.
Custom outputs outside the project's bounded `_build`, `deps` and `bin/symphony`
layout, or symlinked output ancestors, are rejected. Release promotion requires the expected clean source and checks both copied files before switching current.

Tracked source inputs, including media larger than 16 MiB, are hashed in 64 KiB
blocks without retaining full file contents. A 64 MiB aggregate budget per capture
bounds source IO (three captures per build); exceeding it fails explicitly. Path and
open-handle metadata plus actual byte counts are checked before/after reads. The
16 MiB limit for decoded BEAM/ZIP entries remains separate and unchanged.

After `mix setup` fetches dependencies, the `mix build` alias materializes them with
`deps.compile` before the driver captures source. The explicit
`build_identity_resources` list in mix.exs declares the three dependency JS files
embedded by StaticAssets. Their inputs are captured before compilation and compared
after compilation and packaging, alongside the Git source inventory. Both inventories
share the 64 MiB limit; the fingerprint includes the declaration, paths and bytes.
An undeclared external_resource attribute blocks the build.

This initial layout supports dependency resources in `deps/<app>/priv` with Mix's
`_build/.../lib/<app>/priv` symlink to that exact directory. The compiler alias and
source must identify the same physical file, checked before/after its single hash.
Missing prerequisites, copied priv directories, paths outside this layout or other
symlinks fail explicitly. The driver does not prepare/download deps or repair aliases.

`SymphonyElixir.BuildIdentity.summary()` is a small immutable startup diagnostic, also
available as RunnerRuntime `loaded_build`. It performs no IO and does not claim current
verification. For an explicit inspection in a worker/local process, use
`inspect_loaded([SymphonyElixir.BuildIdentity, SymphonyElixir.Application])` and
`inspect_artifact()`. These report incomplete/missing/changed evidence without updating
the baseline, loading code or changing dispatch eligibility. The module scope is bounded
at 256 and must be chosen by the authorized checker, not untrusted payloads.

See `../docs/RUNTIME_CONTRACT.md` for file/module limits, local trust assumptions,
MD5 versus artifact SHA-256, and the separate E1 acceptance requirements. Integration
fixtures use real temporary Mix builds and escripts without network/dependencies;
watchdogs terminate their process groups. Test fixture receipts used by the promotion
shell tests are only orchestration evidence, not loaded-code identity evidence.

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

Promotion validates the raw issue identity before applying the existing manual
refresh rules: an empty manual result may retain the captured eligible issue,
and a locally resumed manual issue may override its stored Blocked state. The
revalidation consumes the asynchronous result without another tracker request;
current controls, capacity, snapshot identity and the gate still apply. Terminal
or missing tracker issues retain the `dispatch_no_longer_eligible` diagnostic.
Cleanup and release-audit failures keep their own error instead of that rejection.

Legacy renewal by its existing owner still normalizes an invalid acquired_at.
Acquisition does not adopt malformed legacy timestamps: takeover requires a valid
expired legacy record, and invalid records remain byte-identical after rejection.

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

Linear lookup uses the polling reader, and active revalidation shares one admission
reader with poll candidates, retries and existing C3 promotion. One bounded batch
and one head preserve physical order. The inbox phase is visible in snapshots;
held remote reads do not occupy the coordinator. Synchronous local effects and
PR inspection and control operations retain their existing limits; C5 GitHub
issue-resolution reads share B as described below.

The head completes at a local reconciliation/rejection or real gate authorization,
not when a worker is merely queued. Its cache projection stays private until that
decision. One correlated continuation then confirms the captured prefix. Failed
ack retries only confirmation on the next drain; current 429 schedules one wakeup.
Failed release/audit remains explicit and cannot become success by observing a
missing lease. Restart retains at-least-once delivery without recovering volatile
custody. See [the full contract](../docs/RUNTIME_CONTRACT.md#linear-inbox-continuation-c4b)
and [reader lifecycle](../docs/tracker-poll-async.md#linear-inbox-reads-and-completion-c4b).

## Admitted execution and token accounting (I2a)

Workers retain their original dispatch ticket, complete physical lease token and
owner PID. Provider callbacks cannot replace that context. The runtime registers
session handles and invocation ordinals, with at most two live sessions and 64
bindings per dispatch, including retired identities. The verifier can use B while
the main session A remains live; returning to A preserves its accepted totals.

Usage is classified before CLI normalization. Per-invocation CLI totals and
AppServer thread totals have different scopes; duplicate reports do not double
count, and a retry starts from the persisted issue baseline. Missing, malformed
or unknown-scope observations are not silently converted to zero.

The owner checkpoints accepted usage with the captured ticket/token before
committing its in-memory counters. The worker confirms before controlled tools,
turn effects, the next invocation and `after_run`. Confirmation is a single
5,000 ms call. On timeout or failed persistence, `accounting_uncertain` remains
terminal even if the provider subsequently returns success. Cleanup may close
transports, but automatic finish, retry and journal removal remain blocked.

Identified snapshots require execution context; direct legacy transport calls
retain their narrower contract. These checks do not roll back remote effects,
provide distributed atomicity or implement uncertain-run recovery. See
[the admitted execution contract](../docs/RUNTIME_CONTRACT.md#admitted-execution-and-usage-i2a).

## Current material state during execution (I2b)

Audited admission captures the canonical raw snapshot once. Each controlled
operation must still match that admitted material state and the original
dispatch/lease authority. A checked write changes only its declared attributes;
its successful return and owner acknowledgment establish the next witness.
Concurrent review, stage or policy changes cannot be adopted by a later read.

A precondition conflict retains `stale_execution` with the captured run/dispatch
IDs; persistence or confirmation uncertainty retains `accounting_uncertain`.
Either stops continuation and keeps the claim/journal available for explicit
inspection. Own blocked/done writes retain their domain result, deny later hooks
and turns, and close through the real worker DOWN without an automatic retry.
Audited cleanup errors stay visible. Legacy transport behavior retains its
existing contract.

The material projection, stop notifications, final-usage receipt and lifecycle lock
order are specified in [the runtime contract](../docs/RUNTIME_CONTRACT.md#current-execution-and-material-state-i2b).
These are cooperating local checks; remote effects are not transactional and
restarting does not authorize uncertain work to replay. The I2c operation binding
below, P2/I3 and academic acceptance require their own evidence.


## Bound deployment observations (I2c)

Audited deployment binds its reservation to the captured dispatch, physical lease
and material state. The creating process retains one live ticket. One original
observation remains possible after a guard denies continuation, but cannot authorize
another effect. The attempt is consumed before preparation and IO; failures and a
still-authorized marker never permit observation replay.

Only current, passed, confirmed evidence can reach continuation. Its own checked CAS
and owner ACK establish the exact successor receipt; unrelated same-stage events or
restored files after a denial cannot close the operation. Own done permits this
specific close without reopening tools or turns. A public stop that kills the worker
before a result leaves the deployment outcome unknown and its reservation retained.
Dispatch termination is recorded separately from deployment success.

Checked stage transitions may persist last_agent_session as historical diagnostic
evidence. It is not a live session handle or an input to the material permission guard.
DeployAudit.inspect_pending returns checked diagnostics without command/output/token
payloads and never repairs or removes journals. The public shell path still maps
passed/failed/unavailable; this block adds no distinct public timeout detection.
See [the operation contract](../docs/RUNTIME_CONTRACT.md#deployment-operation-binding-i2c)
and [deployment audit](../docs/deploy-audit.md). Source checks, loaded release and thesis
acceptance remain separate evidence.


## GitHub issue-resolution continuation (C5)

Review and failing-check events retain a bounded physical inbox head while initial
issue lookup and the refresh after confirmed effects share polling reader B. Active
admission shares A with poll, retries and C3. A retained read leaves the coordinator
available; PR inspection, local effects and tracker writers keep synchronous limits.

A live worker delays all changes by that head. Its confirmed normal close triggers
fresh state/source/routing/feedback evaluation without losing retry budget/context.
Pending or uncertain closure remains blocked. Current review feedback can eliminate
obsolete work; this does not add semantic deduplication of still-eligible CI events.

A manual seed requires an enabled explicit manual source and actual absence of the
exact checked record. Corruption, IO, remote lookup failure and disappearance during
refresh cannot supply a seed or stale issue for dispatch. Remote absence/error can
record an allowed observation and human action without autonomous reopening.

Transitions, tracker writes and follow-up outcomes are not repeated when refresh or
ack is retried. Current tracker 429 updates shared backoff: initial lookup retries
fresh resolution; after effects only refresh may resume within original custody.
Neither renewal nor backoff extends the acquisition deadline. Expiration preserves
actual effects and blocks a late gate. Cleanup cannot release transferred or successor
ownership. Failed no-child admission closure retains its own ticket and claim even
through control/retry cleanup; inspection does not authorize recovery.

The coordinator uses its own 19-field material comparison while preserving worker
checks and fresh usage. Controls invalidate pending continuations even without a
persisted stop marker. Source integration, loaded release, external providers and
thesis acceptance need separate evidence. See [the full phase and error contract](../docs/RUNTIME_CONTRACT.md#github-event-continuation-c5).


## Current evidence before publication

After successful validation, Symphony runs the harness artifacts command before
verification. A failed or unavailable command blocks publication. Resuming a worker
requires fresh observation; persisted validation and verifier results do not grant
a later worker permission to publish.

The runtime observes the selected proof files before the verifier runs. Only regular
text files below the workspace are accepted, with a maximum of 1 MiB per file; symlinks
and unsafe paths are rejected. The verifier receives redacted, bounded excerpts from
the same buffers that were hashed. A `pass` with unresolved acceptance gaps is blocked.
In `harness_artifact_only` mode the selected file is the configured artifact,
including an artifact under `.symphony/`; changed tests cannot substitute for it.
Its accepted bytes must remain current until the effect is authorized.

Acceptance belongs to the current worker and its checked ledger entry. Before
commit, push, PR changes and handoff, the runtime checks that the selected files,
material scope and accepted entry remain current. Changed or replaced evidence
blocks the effect. File hashes establish integrity of the observed bytes; they do
not establish the truth of arbitrary claims in those files.

## Persisted run traceability

`GET /api/v1/traceability` accepts exactly one nonempty query parameter: `issue`
(issue ID or identifier), `run` (run ID), `workspace` (canonical absolute path), or
`pr` (PR URL). It reads the checked local ledger and the canonical snapshot without
contacting Git, a tracker or a provider, or rewriting the evidence.

A successful response binds the snapshot to a confirmed run identity and its
dispatch and stage events, and returns snapshot and ledger digests. Dispatch
authorization does not establish that a worker executed or that a domain result
succeeded. Invalid selectors return HTTP 400, absence 404, contradictory, ambiguous
or changing evidence 409, and unavailable storage 503. No latest-run guess is made.

Returned links use exact selectors. If redaction changes a canonical workspace
path, the workspace link is null and the genuine run link remains available.
Snapshots and ledger bytes are rechecked before returning the response; concurrent
changes require another read and are never repaired by the query.

## Gate invocation identity

Each call to `run_preflight`, `run_validation`, `run_smoke` or `run_artifacts` creates
one `gate_id` before evaluation, including a missing command that returns
`unavailable`. The result carries its kind, UTC start and finish timestamps,
monotonic duration in microseconds, and OS family/name plus the actual executor
branch. An unobserved exit code stays null; the environment does not include
process environment variables or configuration values.

Executing callers capture the checked ledger path before the command. Completion
and gate-related blocking records retain the producer ID and are written to that
path without rerunning the command or retrying an uncertain write. Current-worker
checks still apply before invocation and after its return; lost authority can
prevent a late result from being recorded or promoted.

Evidence receipts retain the gate references alongside command/output hashes.
IDs support reconstruction and do not grant publication authority. Reading a
historical result does not mint an ID or fill an unknown exit code. Post-merge,
preview and other non-gate command wrappers keep their existing result contract.

## Live review claim continuity

A live review item retains its addressed status only when the PR URL, item ID,
kind, thread key, author, body, path, line, review state and decision match the
persisted claim. Integer and string representations of the same item ID are
compared explicitly. Unrelated timestamp changes do not reopen an identical claim.

Missing or changed identity fields clear the old implementation status and summary
and use the fresh adjudication result. The current status flows through subsequent
webhook plans and persistence without restoring a cleared historical status.
Posted reply receipts remain intact; retaining a receipt does not itself establish
that the current claim is addressed.

Legacy snapshots without a run identity keep their existing posted-reply reconciliation semantics only when `AgentExecution.entry_context/2` explicitly returns `:legacy`. Identified executions and direct PRWatcher reads use strict complete live-claim identity by default; sparse historical reply metadata cannot close an identified claim.

### Background Git inspection

RunInspector disables Git optional index refreshes for read-only status and metadata queries. These reads still report worktree changes, but do not rewrite the index or compete with delivery checkout and commit commands for an optional index lock. Required write locks remain enabled for Git mutations.

GitHub feedback received while a completed worker retains retry custody stays in
the durable inbox without ACK or effects. Custody retirement or transfer wakes the
existing owner, which rereads the workspace and rechecks routing, worker closure,
policy and admission before applying the event. The pending event does not reserve
the retry lane or borrow its lease.

Queue snapshots and `/api/v1/state` show `Blocked` and the saved failure/action
when a run is blocked. `tracker_state` retains the cached tracker observation
separately. The issue policy remains visible, but its general merge requirement
does not replace the current validation or snapshot failure. Reading the queue
does not update tracker state or persisted run state.
