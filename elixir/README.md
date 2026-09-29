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
before documentation content. Evidence is limited to four files and 2,400 characters per file, redacts
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
explicit reschedule. Ready retries alternate with poll admissions; ordinary retries
query candidates and passive continuations query their issue. Stale callbacks
cannot consume a newer retry, and refresh errors explicitly reschedule instead of
abandoning the entry. Current identity, capacity, ownership and audit checks still
apply before worker authorization.

This is a partial availability boundary. Webhook/GitHub processing,
immediate controls, their pre-dispatch reads, promotion after lease acquisition
and tracker writes remain synchronous;
applying a result may still invoke those paths. The next phase must address them
before claiming general coordinator availability. See [the phase contract and
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
string-keyed boolean `success`. Execution-ownership checks remain I2 work. See
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
Errors expose sanitized phases/codes, not raw event payloads. Event draining remains
synchronous; this storage change does not provide C4b reader availability.

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
