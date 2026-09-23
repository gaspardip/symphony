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
mise exec -- ./bin/symphony ./WORKFLOW.md
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
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

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
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
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
