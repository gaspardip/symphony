# Symphony Daemon and Operator CLI Plan

## Summary

Symphony should evolve from a repo-local orchestration runtime into an always-on, cross-repo control plane.

The target shape is:

- `symphonyd` as the long-running daemon
- a first-class operator CLI as the primary human interface
- Phoenix UI/API as the visual and integration surface
- model providers as pluggable execution backends
- repo harnesses as the durable source of truth for how work is validated, proved, deployed, and finalized

This plan exists because the Codex app is repo-centric while Symphony is becoming portfolio-centric. The long-term answer is not better thread discipline. The long-term answer is that Symphony itself becomes the cross-repo operator surface and runtime.

Default posture:

- Codex app threads remain useful for architecture, debugging, and manual intervention
- CLI-backed workers remain the primary autonomous execution path
- the daemon owns queueing, routing, supervision, policy enforcement, observability, and recovery
- `symphony` self-hosting and `events` consumer validation continue in parallel

## Why This Is The Right Move

Autonomous software delivery is no longer bottlenecked by code generation quality alone. The real bottleneck is governance:

- what gets picked up
- what may be changed
- what must be proved
- what may be published
- what may be merged
- what may be deployed
- what happens when anything fails

That is daemon/control-plane work, not chat-thread work.

This architecture also aligns with the contractor-autopilot direction:

- personal repos can run in `private_autopilot`
- contractor repos can run in `client_safe_shadow`
- the same runtime can manage both without leaking workflow assumptions across companies

## Product Goal

Symphony should become:

1. a local/autonomous software delivery daemon
2. a cross-repo portfolio control plane
3. a policy-driven execution runtime
4. a provider-agnostic worker orchestrator
5. a human-override system where operator input is needed only at explicit gates

## Non-Goals

- Replace GitHub, Linear, or CI as systems of record for their own domains
- Make the desktop app the primary cross-repo control plane
- Move core runtime behavior into a thin wrapper around chat sessions
- Let workers infer workflow policy on their own

## Core Architecture

### 1. Daemon

Introduce `symphonyd` as the always-on local process that owns:

- intake and routing
- issue normalization
- policy resolution
- workspace lifecycle
- worker spawning
- passive-stage control
- review/deploy watchers
- observability
- persistence

The daemon should run as a supervised OTP application and remain the single source of orchestration truth.

### 2. Operator CLI

Add a first-class operator CLI as the preferred human interface for cross-repo control.

The CLI should be:

- thin over the daemon/control API
- scriptable
- human-readable by default
- machine-readable with `--json`
- stable in exit codes and selectors

Representative commands:

```bash
symphony daemon start
symphony daemon health
symphony status
symphony portfolio
symphony issues list
symphony issue show CLZ-16
symphony issue approve CLZ-18
symphony review list
symphony review show review:123
symphony review approve review:123
symphony review post review:123
symphony repo compat /path/to/repo
symphony metrics show
symphony logs tail CLZ-16
symphony replay issue CLZ-19
```

### 3. Web UI / API

Keep Phoenix as:

- webhook ingress
- dashboard
- delivery reports
- portfolio reports
- machine API for operator and future integrations

The UI becomes one operator surface among several, not the only one.

### 4. Execution Backends

Workers should remain external execution backends under runtime control.

Initial backends:

- Codex CLI
- existing verifier path

Planned backends:

- Anthropic CLI or API-backed execution
- provider-specific verifier backends
- deploy/proof providers

The runtime should decide per stage:

- which backend to use
- what reasoning tier to map
- what policy applies
- what proof/deploy contract must be satisfied

## Runtime Boundaries

### The Daemon Owns

- intake
- normalization
- queueing
- policy packs
- operating mode
- workspace creation/resume
- stage transitions
- validation/proof/deploy orchestration
- PR/check/merge lifecycle
- circuit breakers
- observability and metrics

### Workers Own

- code edits
- lightweight targeted inspection
- structured turn results
- verifier judgments where a model-backed verifier is used
- draft replies in review workflows

### Harness Owns

- repo map
- validation commands
- proof contracts
- deploy commands
- artifact declarations
- self-development structure for Symphony itself

## Storage Model

### Global daemon state

Global daemon state should live outside repos, under a dedicated Symphony home.

Suggested shape:

```text
~/.symphony/
  daemon/
    state/
    runs/
    leases/
    metrics/
    replay/
    reviews/
    portfolio/
  companies/
    personal/
      policy.toml
      credentials.toml
    client-a/
      policy.toml
      credentials.toml
  runner/
    releases/
    current
```

### Repo-local state

Repos continue to own only their contract and repo-scoped artifacts:

```text
repo/.symphony/
  harness.yml
  knowledge/
  features/
  progress/
  artifacts/
```

This keeps global orchestration state separate from repo-owned validation/proof state.

## OTP / Process Model

Use Elixir’s normal strengths instead of inventing a custom daemon framework.

### Recommended components

- `SymphonyElixir.Application`
- `Supervisor`
- `DynamicSupervisor`
- `Task.Supervisor`
- `Registry`
- `Phoenix.PubSub`
- `Telemetry`
- `OpenTelemetry`

### Candidate supervised services

- `IssueIntake`
- `Scheduler`
- `PassiveStageController`
- `ReviewWatcher`
- `DeployWatcher`
- `RunStateStore`
- `LeaseManager`
- `MetricsCollector`
- `ReplayStore`
- `PortfolioAggregator`

### Optional heavier infrastructure

If durable scheduled/retry work becomes awkward with custom scheduling, consider `Oban` later.

Do not start there unless the current runtime model becomes the bottleneck.

## CLI Design Principles

### Why Elixir first

The initial operator CLI should be written in Elixir because:

- it can share runtime schemas directly
- it avoids duplicating business logic
- it keeps daemon and CLI in lockstep
- it is the fastest way to get a stable control client

Other client languages can come later once the daemon API and object model stabilize.

### CLI responsibilities

The CLI should handle:

- selection and filtering
- output formatting
- daemon/API dispatch
- a few local convenience operations

The CLI should not duplicate:

- policy logic
- orchestration logic
- proof logic
- deploy logic

### Output standards

The CLI should support:

- human-readable output by default
- `--json` for automation
- stable exit codes
- shell completion
- concise filters/selectors

## Operator Modes

The control plane should work in these modes from day one:

- `private_autopilot`
- `client_safe_shadow`
- `client_safe_pr_active`
- `full_runtime`

The daemon and CLI should surface the effective mode everywhere so the operator always knows:

- what Symphony may do automatically
- what it may only draft
- what still requires approval

## Portfolio Model

The daemon should become the cross-repo operator surface that the desktop app cannot be.

Portfolio grouping must support:

- company
- repo
- operating mode
- proof state
- blocked reason
- review queue
- deploy queue
- approval queue
- pressure metrics

This is what makes Symphony viable for long-term contractor use across multiple companies.

## Review and Comment Automation

The daemon should watch PR review events and model them as first-class review work:

- `unreviewed`
- `drafted`
- `approved_to_post`
- `posted`
- `resolved`
- `rejected`

The CLI and UI should both support:

- listing pending drafted replies
- approving or rejecting drafts
- posting approved replies
- resolving threads when policy allows

This is one of the most valuable contractor features and belongs in the control plane, not in ad hoc thread work.

## Deployment Model

Deployment is the next major runtime milestone after merge.

The daemon should orchestrate:

- preview deploy
- post-deploy verify
- production approval
- production deploy
- rollback

All of this must remain harness-declared and policy-controlled.

For client work:

- PR-only or preview-only should remain valid operating modes

For personal work:

- wider autonomous deploy modes should be allowed

## Observability Model

The daemon should emit observability data as a core feature, not an afterthought.

Primary approach:

- `:telemetry` for internal event emission
- OpenTelemetry for traces
- Prometheus-compatible metrics export
- structured logs
- Grafana/LGTM stack for dashboards

PostHog or similar can be layered later for product/operator analytics, but should not be the primary runtime observability backend.

Key metrics:

- per-stage time
- token usage
- provider/model by stage
- proof failures
- review backlog
- passive waits
- deploy outcomes
- repair counts
- operator attention backlog
- portfolio pressure

## Relation To Existing Plans

This document does not replace the master roadmap or dogfood/self-development runbooks.

It is the architectural layer that explains how those plans converge into a daemon/control-plane product.

Relevant companion docs:

- [CONTRACTOR_AUTOPILOT_MASTER_PLAN.md](/Users/gaspar/src/symphony/docs/CONTRACTOR_AUTOPILOT_MASTER_PLAN.md)
- [SYMPHONY_SELF_DOGFOOD_EXECUTION_PLAN.md](/Users/gaspar/src/symphony/docs/SYMPHONY_SELF_DOGFOOD_EXECUTION_PLAN.md)
- [SELF_DEVELOPMENT_HARNESS_PLAN.md](/Users/gaspar/src/symphony/docs/SELF_DEVELOPMENT_HARNESS_PLAN.md)
- [OBSERVABILITY_IMPLEMENTATION_PLAN.md](/Users/gaspar/src/symphony/docs/OBSERVABILITY_IMPLEMENTATION_PLAN.md)

## Implementation Phases

### Phase A: Formalize the daemon

- define the daemon service boundary
- define the supervised component tree
- separate daemon responsibilities from worker responsibilities
- add `symphony daemon start|stop|health`

### Phase B: Build the operator CLI

- add core read-only commands first:
  - `status`
  - `portfolio`
  - `issues`
  - `issue show`
  - `review list`
  - `repo compat`
  - `metrics`
- add `--json` support
- stabilize selectors and exit codes

### Phase C: Move cross-repo operations into the daemon

- make portfolio mode daemon-native
- move grouped approvals/reviews/blockers into daemon state
- use the CLI and UI as views onto the same runtime

### Phase D: Make Symphony self-host through the daemon

- use the Symphony project as the self-host queue
- use the mandatory self-development harness
- keep `events` as the consumer validation baseline

### Phase E: Expand into contractor-grade operations

- finish stealth review workflows
- add deploy automation
- add replay/shadow mode
- add provider analytics and workload shaping

## Test Plan

### Architecture tests

- daemon boot initializes all required supervised services
- CLI commands hit the daemon and return stable text/JSON output
- daemon state survives restarts without losing issue/run truth

### Control-plane tests

- portfolio queries aggregate multiple runners/repos correctly
- review and deploy queues remain consistent across UI and CLI
- passive late stages stay runtime-only

### Self-host tests

- Symphony project issues route through the daemon correctly
- self-development harness gates publish
- `events` continues to validate the runtime externally

### Operator tests

- approvals and draft-review workflows behave the same through CLI and UI
- company/repo policy packs are honored in all control paths

## Open Questions

- Whether `Oban` should be added later for durable queued work, or whether the current runtime scheduling should stay custom for longer
- Whether to expose the daemon over HTTP only, or add a local Unix-socket/RPC path for the CLI
- Whether to build a second-language CLI later for broader distribution, after the Elixir CLI stabilizes

## Assumptions

- CLI-backed execution remains the primary autonomous execution path
- the desktop app remains a human control/debug surface, not the main automation substrate
- Symphony’s true product direction is control plane + daemon, not just “better prompts for workers”
