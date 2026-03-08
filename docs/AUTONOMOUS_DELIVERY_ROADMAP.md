# Autonomous Delivery Roadmap

## Summary

This roadmap starts after the eight phases in
[`AUTONOMOUS_PIPELINE_PLAN.md`](./AUTONOMOUS_PIPELINE_PLAN.md) are complete. At that point,
Symphony is assumed to have a stable v1 control plane:

- runtime-owned delivery stages
- harness enforcement and startup validation
- verifier gating and post-merge verification
- restart-safe recovery and lease coordination
- typed audit trail and rule catalog
- dashboard/API controls and policy overrides
- dogfood promotion flow
- high test coverage on the delivery core

The post-v1 goal is to turn Symphony from a reliable Codex-backed autonomous pipeline into an
executor-independent delivery runtime for harness-compatible repos. Linear and GitHub remain the
first-class product surfaces in this roadmap, but they stop being the places where delivery logic
actually lives. Symphony owns delivery policy, verification, routing, recovery, and evidence.

Four decisions define this roadmap:

1. Symphony owns the delivery contract. Executors are replaceable workers, not the source of truth.
2. Harness compatibility is the admission boundary for full autonomy.
3. Control-plane correctness stays local-first and restart-safe; deeper analytics are derived and
   non-blocking.
4. Multi-executor support comes after telemetry, auditability, and runtime semantics are stable.

## Product Thesis

Symphony turns a harness-compatible repo into an autonomous delivery system.

The durable wedge is not issue tracking, chat UX, or a model marketplace. The wedge is a
CI/CD-grade control plane for software delivery that can:

- accept work from a tracker
- decide whether the repo is ready for autonomy
- choose the right executor for each stage
- verify the work against deterministic repo-owned contracts
- publish and merge safely
- recover cleanly from partial failure
- explain every material decision without reading raw logs

### First-class surfaces

- Linear is the intake, delegation, approval, and operator-routing surface.
- GitHub is the publication, checks, merge, and post-merge evidence surface.
- Symphony runtime is the orchestration, policy, verification, routing, recovery, and audit
  surface.

### Non-goals

- building a tracker product to compete with Linear
- building an IDE or chat shell
- making user-authored arbitrary agent graphs the primary UX
- broadening to Jira/GitLab before executor-independent autonomy is proven
- letting prompt craftsmanship replace harness engineering or runtime policy

## Strategic Principles

### 1. Harness-first, prompt-second

Every major roadmap decision should reduce executor guessing and increase deterministic
repo-supplied contracts. If a capability can live in `.symphony/harness.yml`, rule catalogs,
runtime policy, or the verifier contract, it should not live only in prompts.

### 2. Control plane over worker identity

Symphony should be described and built as a delivery runtime, not as "a way to run Codex from
Linear." Executors are pluggable. The runtime decides:

- whether work is admissible
- which stage runs next
- what proof is required
- which executor is appropriate
- what to do after failure or disagreement

### 3. Local-first correctness, derived intelligence

The runtime must stay correct even if no analytics sink is available. Historical reporting,
insights, scorecards, and cost analytics should be derived from append-only events and snapshots.

### 4. Narrow role composition over arbitrary multi-agent graphs

Multi-agent support should begin with narrow, runtime-owned roles:

- implementer
- verifier
- reproducer
- summarizer
- release/post-merge checker

Symphony should not start with user-authored DAGs or graph editors.

### 5. Explainability is a product feature

Every blocked run, fallback decision, manual intervention, and merge should be explainable from
typed records. The dashboard should answer:

- What is happening?
- Why did the runtime choose this path?
- What changed from the last decision?
- What human action, if any, is required?

## Baseline After Phase 8

This roadmap assumes the following v1 surfaces already exist and are stable:

- `DeliveryEngine` owns runtime stages and publish/merge flow.
- `RunStateStore` persists per-workspace stage state and restart recovery data.
- `RunLedger` records typed operational decisions.
- `RepoHarness` validates `.symphony/harness.yml`.
- `VerifierRunner` owns smoke + read-only verifier gating.
- `RuleCatalog` maps failure classes, rule IDs, and human actions.
- `Orchestrator`, `Presenter`, and the observability API expose queue, retry, token, stage, policy,
  and runtime status.

Post-v1 work should extend these surfaces rather than replace them.

## Phase 9: Analytics And Run Intelligence Foundation

### Goal

Add a derived analytics plane for historical analysis, operational intelligence, and planning
without introducing a runtime dependency on a database or external metrics backend.

### Key outcomes

- historical run records are queryable
- stage and queue timing are reconstructable
- per-state and per-stage throughput/latency are measurable
- the dashboard can show fleet trends, not just current snapshots

### Architecture

- Keep the orchestrator, delivery engine, and run-state recovery DB-free for correctness.
- Introduce a separate append-only analytics sink fed by:
  - `RunLedger`
  - `RunStateStore` snapshots
  - orchestrator snapshots
  - dashboard control events
- Implement analytics ingestion as best-effort and asynchronous.
- If the sink is unavailable:
  - no delivery behavior changes
  - no retries are skipped
  - no operator actions are blocked
  - analytics gaps are marked explicitly

### Canonical identifiers

Introduce stable identifiers and timestamps for all post-v1 historical analysis:

- `run_id`: one end-to-end delivery run for one issue
- `stage_id`: one stage attempt within a run
- `turn_id`: one executor turn inside a stage
- `executor_assignment_id`: one executor-role binding to a stage or turn
- `policy_decision_id`: one typed policy/routing/operator decision
- `queue_entry_id`: one queue admission episode for one issue

### Canonical event families

Add normalized event families that can be derived from runtime behavior without changing control
logic:

- `run.lifecycle`
  - created
  - resumed
  - completed
  - blocked
  - cancelled
- `stage.lifecycle`
  - entered
  - exited
  - resumed
  - failed
- `turn.lifecycle`
  - started
  - reported
  - completed
  - aborted
- `verification`
  - smoke verdict
  - verifier verdict
  - verifier disagreement
- `publication`
  - commit result
  - push result
  - PR create/update result
  - check rollup update
  - merge result
  - post-merge result
- `coordination`
  - queue admitted
  - queue dispatched
  - retry scheduled
  - lease acquired/refreshed/lost/taken-over
  - pause/resume/stop/operator override
- `routing`
  - executor chosen
  - executor rejected
  - executor fallback

### Derived metrics

The first analytics release should define clear metric formulas, not just labels.

#### Run metrics

- lead time per issue
  - from first queue admission to terminal `done` or `blocked`
- active runtime per issue
  - sum of active stage wall-clock time excluding queue wait
- autonomous merge rate
  - merged runs with no required manual intervention / total merged runs
- human intervention rate
  - runs with pause, resume, approve-for-merge, policy override, or manual hold / total runs

#### Queue metrics

- queue wait time
  - `queue_exited_at - queue_entered_at`
- dispatch latency
  - time from issue eligibility to worker dispatch
- aged queue count
  - number of eligible issues over threshold buckets: 5m, 30m, 2h, 1d

#### Stage metrics

- stage duration by stage
  - `stage_finished_at - stage_started_at`
- stage duration by repo and policy class
- p50/p95/p99 stage duration
- stage retry rate
  - count of repeated stage entries / count of runs entering that stage
- stage failure distribution
  - grouped by rule ID and failure class

#### Turn metrics

- turn duration by stage
- turns per issue
- turns per stage
- turns per ticket state
- time-to-first-code-change
  - first turn with diff or touched files minus first implement stage start
- noop-turn rate
  - turns with no meaningful progress / total turns

#### Review and merge metrics

- review wait time
  - time from PR ready-for-review to `Merging` or merge
- merge wait time
  - time from checks green + approval to actual merge
- required-check volatility
  - count of state transitions in required check rollups
- post-merge failure rate
  - post-merge failures / merged runs

### Insights API

Extend the observability API with read-only derived endpoints.

- `GET /api/v1/insights/overview`
  - fleet-wide summary for a window
- `GET /api/v1/insights/runs`
  - historical run list with filtering
- `GET /api/v1/insights/stages`
  - stage timing and retry breakdowns
- `GET /api/v1/insights/failures`
  - top rule IDs, failure classes, and repo breakdowns

Recommended filter params for all insights endpoints:

- `window`
- `repo`
- `policy_class`
- `state`
- `stage`
- `executor`
- `outcome`

### Dashboard additions

- stage funnel
  - queued -> implement -> validate -> verify -> publish -> await_checks -> merge -> post_merge -> done
- queue aging view
  - current aged queue buckets and oldest waiting issues
- blocked reason leaderboard
  - by rule ID and failure class
- retry heatmap
  - retries by stage and hour/day
- review wait distribution
  - p50/p95 by repo and policy class

### Acceptance

- every merged or blocked run is queryable historically
- insights endpoints do not affect runtime correctness
- dashboard can show p50/p95 stage timing and top failure classes for a configurable time window
- analytics ingestion failure does not block dispatch, merge, or operator controls

## Phase 10: Executor Abstraction And Registry

### Goal

Make the runtime executor-independent without changing the delivery semantics.

### Key outcomes

- orchestration logic no longer branches on Codex details
- current Codex path becomes a concrete executor implementation
- second executor support becomes additive, not invasive

### Executor model

Define an explicit `Executor` behavior. The runtime deals in capabilities and roles, not model
names.

Recommended behavior surface:

```elixir
defmodule SymphonyElixir.Executor do
  @callback name() :: String.t()
  @callback capabilities() :: map()
  @callback start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback run_stage(map(), String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback cancel(map(), keyword()) :: :ok | {:error, term()}
  @callback healthcheck(keyword()) :: {:ok, map()} | {:error, term()}
end
```

### Capability model

Capabilities should remain stable across providers:

- `implementation_turn`
- `read_only_verification_turn`
- `tool_calling`
- `structured_result_contracts`
- `patch_edit_fidelity`
- `long_context`
- `shell_access_profile`
- `latency_class`
- `cost_class`
- `supports_resumable_session`
- `supports_streaming_events`

Use normalized enums for the last four:

- `patch_edit_fidelity`: `high`, `medium`, `low`
- `shell_access_profile`: `none`, `read_only`, `workspace_write`
- `latency_class`: `fast`, `balanced`, `slow`
- `cost_class`: `cheap`, `standard`, `premium`

### Concrete executor implementations

- `CodexExecutor`
  - wraps the current app-server path
  - remains the only production executor initially
- `VerifierCodexExecutor`
  - optional wrapper or separate config profile for read-only verifier sessions
- future executors
  - should conform without changing delivery semantics

### Executor registry

Add a runtime-owned registry with:

- executor name
- executor module
- enabled/disabled status
- health status
- capability map
- concurrency limits
- cost and latency class
- stage allowlist/denylist
- repo allowlist/denylist

The registry should support:

- process-local bootstrap from config
- hot refresh without restart where possible
- health snapshots for dashboard display

### Stage-to-capability mapping

- `implement`
  - requires `implementation_turn`, `tool_calling`, `structured_result_contracts`
- `verify`
  - requires `read_only_verification_turn`, `structured_result_contracts`
- `summarize`
  - requires lightweight summarization only
- `publish`
  - remains runtime-owned and does not require an executor, except optional PR summarization

### Config additions

Keep config runtime-level, not user-facing model selection sprawl.

- executor registry entries
- default executor by role
- stage routing defaults
- per-executor repo constraints
- verifier-specific executor override

### Acceptance

- `DeliveryEngine` and `VerifierRunner` depend on executor interfaces, not Codex-specific calls
- Codex remains the default executor with no user-visible behavior regression
- adding a second executor requires only:
  - implementing the behavior
  - registering it
  - updating routing rules

## Phase 11: Policy-Based Routing And Narrow Multi-Agent Composition

### Goal

Make executor selection a runtime policy decision and allow a run to use different executors for
different roles without breaking run identity, recovery, or auditability.

### Key outcomes

- runtime chooses executor by policy
- routing is reproducible and auditable
- fallback is safe and bounded
- multi-executor runs remain one delivery run

### Routing policy

Default posture:

- runtime chooses automatically
- repo owners constrain what is allowed
- operator can override for a run or issue
- users do not manually pick a model in the common path

### Roles

Start with narrow roles:

- implementer
- verifier
- PR summarizer
- reproducer

Do not introduce free-form user-authored graphs or unbounded agent swarms.

### Routing signals

Use runtime-available signals only:

- repo language mix
- repo size and diff size
- issue priority
- issue policy class
- stage type
- harness complexity
- acceptance complexity
- recent failure classes
- retry count
- wall-clock budget remaining
- token budget remaining
- historical executor success rate for matching repo/stage pairs

### Fallback rules

- retry on the same executor first for transient failures
- fallback to secondary executor only for typed failure reasons
- cap executor hops per run and per stage
- never allow fallback to bypass verifier or publish gates
- record all rejected candidates and fallback reasons

### Routing decision record

Every routing decision should record:

- selected executor
- requested role
- stage
- capability requirements
- candidate set
- rejected candidates with reasons
- selected-candidate rationale
- fallback ancestry

### Acceptance

- executor selection is reproducible from recorded inputs
- fallback does not create duplicate PRs, duplicate merges, or duplicate state transitions
- one run can mix implementer and verifier executors while retaining one `run_id`

## Phase 12: Harness Engineering As Product Boundary

### Goal

Turn "Symphony-compatible repo" into a formal runtime contract and product surface.

### Key outcomes

- repo readiness becomes measurable
- unsupported repos fail early with precise remediation
- full autonomy becomes a certification boundary, not a vague aspiration

### Compatibility model

Introduce:

- compatibility score
- autonomy class
- remediation checklist

Recommended autonomy classes:

- `not_compatible`
- `compatible_review_required`
- `fully_autonomous`

### Admission validator dimensions

Score at least the following:

- harness completeness
- validation determinism
- smoke fidelity
- post-merge verification quality
- required check hygiene
- issue acceptance quality
- secrets/tooling readiness
- test scope fit
- policy-label hygiene

### Harness evolution

Keep `.symphony/harness.yml` backward compatible until a second executor is production-ready.

Add optional blocks only:

- routing constraints
- risk profile
- artifact expectations
- repo metadata
- cost/latency preferences

Do not change the required `version: 1` contract in a breaking way during this phase.

### Repo recommendations

Generate historical recommendations from run outcomes:

- add explicit acceptance sections
- narrow over-broad validation commands
- stabilize flaky checks
- improve smoke coverage
- add missing post-merge coverage
- reduce review bottlenecks

### Auto-remediation surfaces

- compatibility report endpoint
- dashboard repo scorecards
- suggested harness patch output
- missing-check guidance

### Acceptance

- Symphony can explain exactly why a repo is not autonomy-ready
- repo maintainers can see which harness improvements would improve autonomous merge rate
- compatibility scoring remains derived from explicit criteria, not opaque heuristics

## Phase 13: Fleet Insights, Operational Intelligence, And Cost Controls

### Goal

Move from current-state observability to fleet intelligence and cost-aware operations.

### Fleet metrics

- merged runs per day
- autonomous merge rate
- human intervention rate
- verifier disagreement rate
- cost per merged issue
- tokens per merged issue
- executor success by repo and stage
- time-to-first-code-change
- time from publish to merge
- post-merge rollback/rework rate

### Issue-state intelligence

Add explicit reporting by ticket state:

- turns per ticket state
- runtime minutes per ticket state
- wait time per ticket state
- transition frequency by state pair
- bottleneck detection by team/project/repo

State analysis should minimally cover:

- `Todo`
- `In Progress`
- `Human Review`
- `Merging`
- `Rework`

### Operator intelligence

- pause/resume frequency
- approve-for-merge frequency
- operator override frequency
- top manual actions by rule ID
- incidents caused by runner promotions

### Cost and budget controls

Introduce new derived and configurable budget classes:

- per-run wall-clock budget
- per-stage token budget
- per-stage cost budget
- repo-level monthly budget
- team-level monthly budget

Routing should be able to:

- downgrade executor cost class when confidence is high and scope is narrow
- upgrade executor class when retries or verifier signals indicate risk
- refuse expensive fallback paths when budgets are exhausted

### Dashboard additions

- executor comparison cards
- repo autonomy scorecards
- daily failure digest
- policy intervention trend charts
- cost/latency distribution widgets

### Acceptance

- operators can answer where time is going, where cost is going, and why runs are failing without
  reading raw logs
- routing policy can use historical cost and success signals without becoming nondeterministic

## Phase 14: Orchestrating Real Delivery Systems, Not Single Tickets

### Goal

Extend Symphony from isolated issue delivery to delivery-system orchestration.

### Dependency-aware execution

- blocked issue graph awareness
- linked-issue sequencing
- branch-stack awareness when needed
- monorepo path ownership hints
- batching constraints for coupled changes

### Release-aware behavior

- canary class for risky repos or executors
- deploy-gate integration after merge
- rollback recommendation when post-merge verification regresses
- protected change windows and freeze windows

### Queue and backpressure controls

- concurrency by repo
- concurrency by team
- concurrency by service area
- protected branch limits
- review-bandwidth-aware throttling

### Incident-oriented views

- runs impacted by a failing check name
- runs impacted by a runner promotion
- runs stuck in one stage or state too long
- runs sharing the same failure signature

### Acceptance

- Symphony can safely operate a queue of interdependent work, not just isolated tickets
- repo and team-level backpressure is visible, enforceable, and auditable

## Phase 15+: Adaptive Autonomy And Self-Improving Runtime

### Goal

Use historical data to improve repo readiness, routing policy, and operator effectiveness without
allowing silent runtime behavior drift.

### Replay and evaluation

- replay historical tickets across routing policies
- compare executors on matched harness-compatible tasks
- simulate stricter budgets
- simulate verifier policy changes

### Recommendation loops

Produce recommendations, not silent self-modification:

- suggested routing policy updates
- suggested harness improvements
- suggested policy-class defaults
- suggested verifier threshold changes

### Quality intelligence

- recurring acceptance gaps
- flaky-check detection
- verifier false-positive/false-negative analysis
- repos with high noop-turn or retry rates
- repos with poor time-to-first-code-change

### Org-scale controls

- audit export
- retention settings
- policy packs by repo tier
- incident review templates generated from ledger history

### Acceptance

- Symphony improves operator policy and repo readiness over time
- changes to routing or autonomy posture remain explainable, reviewable, and reversible

## Insights And Observability Spec

This roadmap should explicitly define the metrics and views expected from the post-v1 control
plane. The goal is to avoid vague "add observability" work items.

### Core runtime metrics

- active runs
- queued issues
- retry backlog
- paused issues
- dispatch rate
- completion rate
- blocked rate
- merge rate
- post-merge regression rate

### Turn-level metrics

- turn duration
- turn duration by stage
- turn duration by executor
- turns per issue
- turns per stage
- turns per ticket state
- current turn input tokens
- cumulative run input/output/total tokens
- token burn per merged issue

### Stage-level metrics

- stage start count
- stage completion count
- stage retry count
- stage failure count
- stage duration p50/p95/p99
- stage duration by repo/policy class/executor

### Queue and wait metrics

- queue wait p50/p95
- review wait p50/p95
- merge wait p50/p95
- wait time by policy class
- wait time by repo

### Policy and intervention metrics

- policy-class distribution
- blocked reason leaderboard
- rule ID frequency
- last failure class distribution
- operator override count
- manual-approval count

### Cost and executor metrics

- executor assignment count
- executor fallback count
- executor success by stage
- executor failure by failure class
- executor cost per merged issue
- executor latency distribution

### Repo readiness metrics

- compatibility score distribution
- autonomy class distribution
- top missing harness requirements
- weakest repos by verifier disagreement or flaky validation

### Dashboard views

- fleet overview
- queue and backlog aging
- stage funnel
- policy intervention trends
- executor comparison
- repo scorecards
- failure drilldown
- issue historical timeline

## Public Interfaces And Type Changes

### Runtime types

Extend run and state records with:

- `run_id`
- `stage_id`
- `executor_name`
- `executor_role`
- `executor_assignment_reason`
- `stage_started_at`
- `stage_finished_at`
- `queue_entered_at`
- `queue_exited_at`
- `wall_clock_ms`
- `estimated_cost_usd`

### API payloads

Extend presenter/API payloads with:

- historical insights
- stage timing breakdowns
- issue-state timing and turn counts
- executor assignment details
- compatibility status and score
- top rule IDs and failure classes for filtered windows

### Compatibility guidance

Keep `.symphony/harness.yml` backward compatible while post-v1 features land. Any new routing or
observability blocks should be optional until multiple executors are production-ready.

## Testing Strategy

### Unit tests

- executor capability matching
- routing determinism
- fallback eligibility
- analytics event normalization
- queue/stage/ticket-state timing rollups
- compatibility scoring
- cost aggregation logic

### Integration tests

- same run across multiple executors by stage
- verifier on one executor and implementer on another
- analytics sink outage with runtime continuing normally
- repo admission failing with exact remediation guidance
- routing fallback after typed executor failure
- queue and state timing rollups matching actual run behavior

### Acceptance scenarios

- one repo merges autonomously with default routing
- one repo is forced into `review_required` due to compatibility score
- one run falls back from primary to secondary executor without duplicating publish/merge
- insights endpoints show p50/p95 stage latency, turns per state, and autonomous merge rate
  accurately

## Delivery Sequence

The recommended implementation sequence after phase 8 is:

1. Phase 9 analytics foundation
2. Phase 10 executor abstraction
3. Phase 11 routing and narrow multi-executor composition
4. Phase 12 compatibility scoring and repo certification
5. Phase 13 fleet intelligence and cost controls
6. Phase 14 delivery-system orchestration
7. Phase 15+ replay, recommendations, and adaptive autonomy

This order matters:

- analytics should land before multi-executor routing so the runtime can measure outcomes
- executor abstraction should land before routing so routing targets stable interfaces
- compatibility scoring should land before broader autonomy so unsafe repos do not silently enter
  full autonomy

## Assumptions And Defaults

- This document is an internal roadmap, not a public positioning page.
- The existing eight-phase plan is complete and is treated as baseline, not future work.
- Linear and GitHub remain the only first-class tracker/publication surfaces in this roadmap.
- Executor independence is the next major platform axis; non-Linear/non-GitHub expansion is
  intentionally deferred.
- Routing is runtime-owned by default; users do not manually pick models in the common path.
- Control-plane correctness must not depend on a database; analytics and intelligence systems are
  derived, asynchronous, and non-blocking.
