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

## CLI turn effects: mechanical extraction

Claude and CodexCLI share the concrete helpers in `DeliveryEngine.TurnEffects`.
Each adapter still calls them synchronously inside its existing turn error boundary:
Git observation, progress-section fallback, format/auto-commit, then result synthesis.
The executor runs in the caller process and the final event follows synthesis.
Claude observes HEAD and untracked files; CodexCLI observes status and origin/main.
Their stream structs, defaults, callback results and command-error behavior remain
unchanged, including postprocessing after a failed CLI turn.

This is P3a only. These helpers still fill empty progress sections and some command
failures are still ignored. Their output is not validation evidence. Direct adapter
calls can still alter the workspace and HEAD. Moving effects behind the engine's
execution-validity check, removing artificial evidence, protecting verifier calls from these
local effects and reporting preparation/commit failures remain P3b/I2 work.
