# Updated State of the Art on Runtime‑Owned Autonomous Software Delivery and Ecosystem Overlap

## A. Executive summary

This update addresses your main objection: the previous overlap assessment was incomplete because it under-sampled the fast-moving wave of early‑2026 GitHub projects that implement *worktree isolation*, *multi-agent session management*, *operator UIs/control planes*, and *spec/proof gating*. A quick scan of just the projects you mentioned (plus nearby repos uncovered while verifying them) shows a dense cluster of systems that overlap **some** of Symphony’s core ideas—often strongly on *per-task isolation* and *operator experience*, and increasingly on *autopilot delivery loops* (CI feedback, review comment handling, retries). citeturn13view0turn18view4turn18view3turn16view0turn28view0turn36search0turn18view0turn18view2turn26view0

At the same time, when you apply the stricter lens you asked for (“the runtime owns execution, with explicit operational bounds and repo-owned policy/proof gates”), many of these emerging tools still fall into **adjacent categories**: (a) *local worktree + tmux orchestrators* (excellent at isolation and parallelism, weaker at tracker-driven delivery semantics), (b) *control-plane UIs* (excellent human orchestration, weaker at proving/validating and durable delivery semantics), or (c) *spec-first/proof-first front-ends* (excellent at tightening intent, weaker at end-to-end, CI-mediated autonomous merge). citeturn18view4turn18view3turn16view0turn28view0turn18view0turn18view2turn26view0turn36search0turn29search2

So the updated, “extremely critical” originality takeaway is:

**Observed:** Symphony’s individual primitives—issue/board intake, per-unit isolated workspaces, repo-owned workflow/policy, CI-driven proof gates, “control plane” visibility, and durable/long-running orchestration—are all present elsewhere in the ecosystem (often in more mature workflow engines, or in new agent-orchestrator projects). citeturn4view1turn5view1turn28view1turn36search0turn25view1turn24search1turn29search2turn30search0

**Interpretation:** What may still be *distinctive* about Symphony (especially in this fork) is the **specific combination** of (1) “scheduler/runner” semantics from the upstream SPEC, (2) **issue-driven** isolated runs, (3) **repo-owned harness + artifacts contract** enforcing traceability and proof-of-work structure, and (4) “operator surfaces” (dashboard/API/metrics) aimed at operating a delivery engine—not just running more terminals. This is a *composition claim* (a systems integration claim), not a novelty claim about any single technique. citeturn4view1turn35view1turn4view7turn4view5turn4view6turn35view2

**Recommendation:** For a thesis, the safest framing is to treat Symphony as a **reference implementation** of a **runtime model** (issue → run → gated delivery), and make the academic contribution about (a) formalizing/validating the runtime model (state machine, bounded execution semantics, recovery), or (b) quantifying the effect of explicit proof gates + repo-owned policy on reliability/operability—rather than claiming “novel autonomous software factory.” citeturn5view1turn30search2turn29search2turn31search6turn4view6

(Notation used below: **Observed** = directly grounded in repo/docs; **Interpretation** = my synthesis; **Recommendation** = thesis strategy.)

---

## B. Description of the Symphony system from the repo

### Observed system goals and shape

The fork’s README explicitly positions Symphony as a **“runtime-owned delivery engine”** that turns work intake into **isolated implementation runs** with **explicit proof gates**, **policy controls**, and **operator visibility**. citeturn35view0

The upstream SPEC (which this fork says it tracks) defines Symphony as a **long-running automation service** that continuously reads work from an issue tracker, creates an **isolated workspace per issue**, and runs a coding agent session inside that workspace. It stresses (i) bounded concurrency, (ii) an authoritative in-memory orchestrator state for dispatch/retries/reconciliation, (iii) deterministic workspaces preserved across runs, (iv) stop conditions when issue state changes, (v) exponential backoff recovery, and (vi) restart recovery **without requiring a durable orchestrator database**. citeturn4view1turn5view1turn36search2

### Intake, execution, and “delivery loop” stages

**Intake.** The fork claims multiple intake sources beyond upstream’s “Linear poller” baseline: Linear-backed intake plus manual issue submission, and GitHub webhook intake for PR review follow-up. citeturn35view1turn4view3

**Execution substrate.** The upstream Elixir reference implementation describes launching Codex in App Server mode inside the per-issue workspace. citeturn5view2turn33search7

**Runtime loop.** The fork’s repo-owned knowledge explicitly spells out a canonical loop: checkout → initialize_harness → implement → validate → verify → publish → await_checks → merge → post_merge → done/blocked, emphasizing that publish/merge are gated by **repo-owned proof and policy** and that late stages should minimize unnecessary model invocations. citeturn4view10

### Repo-owned policy, harness engineering, and proof gates

**Repo-owned workflow policy.** The upstream SPEC defines `WORKFLOW.md` as the repo-owned contract that teams version with code; it divides responsibilities into policy/config/coordination/execution layers, where the repo defines policy and the runtime orchestrator enforces coordination. citeturn5view1turn5view4

**Harness contract.** This fork adds a concrete “agent harness” contract in `.symphony/harness.yml` plus documentation describing required directories (`.symphony/knowledge/`, `.symphony/progress/`, `.symphony/features/`), required knowledge files, a per-issue progress-markdown format, and feature YAML schemas. citeturn4view5turn4view7turn4view8turn4view9

**Publish gate mechanics.** The harness YAML encodes a `publish_gate` that requires progress artifacts and requires feature updates “on code change,” plus preflight/validation/smoke/post-merge workflows as commands. citeturn4view7turn35view2

### Observability surfaces and durable state

The fork lists a Phoenix dashboard, JSON control API, and Prometheus metrics endpoint as first-class operator surfaces. citeturn35view1turn4view6

The repo’s observability runbook describes endpoints like `/api/v1/state`, `/api/v1/reports/delivery`, `/metrics`, and identifies a per-issue persisted state file `run_state.json` as the fast path to inspect the current stage, stop reason, next human action, review claims, and CI failure context. citeturn4view6turn4view5

### Security posture and bounded execution in practice

The upstream SPEC explicitly does **not** mandate a single sandbox/approval posture; implementers must document their safety posture, and may target trusted environments or stricter confirmation/sandboxing. In other words: boundaries are a core concern, but the spec is intentionally permissive. citeturn5view1turn4view1

In the upstream Elixir README, there are explicit configuration fields for Codex approval policy and sandbox settings (thread sandbox and turn sandbox policy) with defaults that restrict the agent to the workspace. citeturn5view2turn33search2turn33search5

**Interpretation:** Symphony’s *architectural claim* is “runtime-owned” and “bounded,” but the hard security boundary depends heavily on the underlying agent execution environment (e.g., Codex sandboxing) and your host OS / container posture—exactly the same dependency most peer systems have. That makes “bounded execution” a *design intent*, but not automatically a *strong isolation guarantee* unless you add sandboxing beyond directory discipline. citeturn5view1turn33search5turn33search2

---

## C. Taxonomy of the current landscape and D. Comparative map of representative projects

### Taxonomy aligned to Symphony’s problem statement

Below is a state-of-the-art taxonomy tuned to the “runtime-owned delivery engine” framing. The main point is not to force everything into “agent runtimes” (too generic), but to distinguish systems by **who owns execution**, **what is the unit of work**, **where policy lives**, and **what enforces proof and isolation**.

**Category: Runtime-owned, issue/board-driven delivery engines.** These systems read a tracker/issue source of truth and run a delivery loop with retries/reconciliation; the runtime, not the human, is the primary controller. Symphony’s upstream SPEC is explicitly in this category. citeturn5view1turn35view0

**Category: Local orchestration shells (worktrees/tmux) and multi-agent “session managers.”** These optimize parallelism and context isolation locally (often “one branch/worktree per task”), but are frequently *not* full tracker-driven delivery engines. citeturn18view4turn18view3turn16view0turn28view1

**Category: Operator/control-plane UIs.** These centralize supervision (approval queues, dashboards, diff/PR status visibility) across many agents/sessions; they often improve human oversight more than they enforce runtime-owned delivery semantics. citeturn13view0turn16view0turn28view0turn29search4

**Category: Workflow/policy-as-code orchestration engines.** These encode processes as graphs/state machines and orchestrate agents + tools + human decisions; they overlap with Symphony on “runtime owns invariants,” but are frequently more general-purpose and not specifically “issue tracker daemon.” citeturn25view1turn30search0turn30search2turn30search1turn29search2

**Category: Spec/proof systems (spec-first, proof-first).** These aim to reduce underspecification and improve correctness via typed specs, scenario-based verification, ambiguity gating, structured “proof of work,” etc. They overlap with Symphony’s “proof gate” direction, but often sit upstream of delivery execution. citeturn18view0turn18view2turn26view0turn24search1

**Category: Observability and evaluation stacks for agentic systems.** These mainly focus on tracing model/tool calls, evaluation, and runtime metrics—often at a different layer than delivery orchestration. citeturn31search9turn31search3turn31search6turn30search9turn4view6

### Comparative map (condensed, but explicit)

The table below is intentionally compact. It focuses on the axes you care about: *execution ownership, unit isolation, bounded execution, policy/proof gates, provider coupling*. “Yes/Partial/No” values are grounded in the cited docs; any inference is marked.

| System (representative) | Primary category | Unit of work + isolation | Execution ownership | Policy/workflow-as-code | Proof gates + validation loop | Provider coupling | Distinct strength | Key limitation vs Symphony framing |
|---|---|---|---|---|---|---|---|---|
| **Upstream Symphony SPEC** | Runtime-owned delivery engine | Per-issue workspace; deterministic workspaces; bounded concurrency | Runtime-owned orchestrator with retries/reconciliation and restart recovery “no DB” | Repo-owned `WORKFLOW.md` (policy in repo) | Workflow-defined gates/hand-off; structured logs minimum | Agent runner abstracted; examples use Codex app-server | Formalizes “scheduler/runner + tracker reader” contract | Spec intentionally avoids mandating strong sandbox/UI; implementer burden citeturn5view1turn36search2 |
| **This Symphony fork** | Runtime-owned delivery engine (self-host) | Per-issue workspaces + persisted state; harness imposes artifact structure | Runtime-owned; adds operator dashboard/API/metrics | Repo-owned harness YAML + repo-owned commands/scripts | Explicit publish gate requiring progress + feature updates; validate/smoke/post-merge hooks | “Replaceable adapters” stated; current runtime uses Codex-style “agent runner” | Turns the spec into an operable self-host path with repo-owned ops/runbooks | Prototype/high-trust warning; hard sandbox depends on underlying agent/runtime citeturn35view1turn4view7turn4view6turn4view5turn4view1 |
| GitHub Copilot coding agent | Issue-driven agent in a CI platform | Task/issue → PR; (no explicit per-task local worktree isolation in doc) | Mixed: runtime executes, but key steps require human approval (example: manual approval to run workflows) | Mostly platform-configured; not “repo-owned workflow language” in the Symphony sense | CI exists but may require human “approve and run workflows”; known limitations around conflicts/commits reported by community | Strong platform coupling to GitHub | Deep native integration with Issues/PR flow | Not a general runtime-owned daemon; control is shared with platform/human approvers citeturn29search20turn29search7turn29search0 |
| OpenHands GitHub Action / platform | Runtime/governance platform + issue automation | Action-triggered runs; supports sandboxed/ephemeral workspaces (Agent Server) | Often workflow-owned (GitHub Actions) rather than a single long-running scheduler | Configurable, but not centered on repo-owned delivery “contract” like Symphony SPEC | Can be used in CI; depends on user’s workflow | Model-agnostic positioning | Strong sandbox + platform support for deploying agents | Not primarily an issue-tracker daemon with reconciliation semantics citeturn22search2turn22search10turn22search3 |
| Composio agent-orchestrator | Runtime-owned (but local/CLI-centric) delivery orchestrator | Each agent gets its own git worktree/branch/PR; reacts to CI + review comments | Runtime-owned reactions; human pulled in for judgment | (Inference) configuration-driven; repo policy less central than orchestration | Explicit loops: fix CI failures; address review comments | Agent-agnostic (Claude Code/Codex/Aider) and tracker-agnostic claim | Strong “delivery loop” alignment with PR + CI + review | Typically not “repo-owned policy baseline” for org-level governance; depends on user conventions citeturn36search0turn36search15 |
| StrongDM Attractor (NLSpecs) | Spec/proof + software factory blueprint | Specs (Markdown) as source; implementation delegated to external agent loop | Not a runtime (it’s a spec set); execution depends on your toolchain | Specs-as-artifacts; encourages controlling the stack | “Software factory” narrative—specs and loop design; not a turnkey runner | Multi-LLM client spec suggests provider abstraction | Clear articulation of a no-human-code/no-human-review “factory” vision | Not a runnable delivery engine; it’s a blueprint to build one citeturn24search1turn24search6turn24search13 |
| Fabro | Workflow/policy-as-code engine | Workflow graphs; can run in cloud sandboxes; supports long-horizon runs | Runtime-owned workflow execution (queue/runs) | Version-controlled workflow graphs | Deterministic validations (tests/linters) + LLM-as-judge gates described | Multi-model routing emphasized | Strong explicit “workflow graph” abstraction for gates, sandboxes, scaling | More general than “issue tracker daemon”; needs integration work to be issue-driven citeturn25view1turn36search1 |
| OctopusGarden | Spec/proof “dark factory” | Specs + scenarios → agents iterate until “converges” | Runtime-owned autonomous convergence loop | Specs/scenarios drive behavior | Scenario-based verification loop, no human review | (Likely) model/tool specific in implementation; conceptually portable | Hard commitment to “no human code review” + scenario-driven verification | Less about real-world tracker/repo handoffs and operational governance surfaces citeturn18view0 |
| OpenSpec | Spec/proof/front-end tooling | Spec-driven dev framework; integrates workflows/commands/CLI | Human-driven toolchain (generally) | Workflows + commands + tool integrations | “Spec-driven development” to reduce underspecification (front-end) | “Works across different coding agents/models/use cases” emphasized | Ecosystem-scale standardization of specs/workflows/commands | Not a delivery runtime; needs a separate orchestrator for issue-driven autonomy citeturn26view0turn26view3 |
| Ouroboros | Spec/proof gate | Ambiguity gating (“no code until ambiguity ≤ threshold”) | Gatekeeper before execution | Encodes a spec interview + scoring math | Prevents underspecified starts; convergence criteria described | Tool/plugin oriented; not a full runtime | Concrete mechanism to block “wrong problem” builds | Doesn’t by itself deliver a CI-mediated PR/merge pipeline citeturn18view2turn17search1 |
| Codex app worktrees | Execution substrate + parallelism (product) | Worktrees as parallel isolated environments; “automations” run on background worktrees | Product-managed (local app) | Product config; not repo-owned policy language | Handoff + review flows; not CI-proof-gated delivery by default | OpenAI ecosystem coupling | First-class worktree UX; “automations” model | Not an issue-driven delivery engine; isolation is task/thread-level, not tracker-run-level citeturn33search4turn28view1 |
| LangGraph durable execution | Orchestration framework | Durable step persistence to resume after delay | Framework-owned; user-defined flows | Workflow-as-code | Supports HITL interrupts and resumption | Framework-level, model/provider pluggable | Durable execution is explicit, with persistence semantics | Not specialized to code-delivery; needs repo+CI integration to become Symphony-like citeturn29search2turn29search10turn29search6 |

### What changed in the overlap picture due to the “new wave” projects

If you restrict focus to the names you listed, you already cover most of the missing overlap region:

- **Operator/control-plane UIs**: Mozzie, AgentBase, TUICommander, Automaker all present “one window” orchestration and review/approval patterns, often with worktree isolation and dependency graphs or command centers. citeturn13view0turn28view0turn16view0turn18view9  
- **Execution substrates/worktree managers**: Rover, agtx, agentree, ccswarm (and Codex’s own worktrees) show broader commoditization of “one task → one worktree” isolation and parallel agent session management. citeturn18view3turn18view4turn18view7turn18view8turn28view1  
- **Spec/proof systems**: OpenSpec and Ouroboros are explicit about “spec-first” and “anti-underspecification gating”; OctopusGarden is explicit about scenario-driven convergence with no human review. citeturn26view0turn18view2turn18view0

**Interpretation:** This materially weakens any claim that Symphony’s originality lies in (a) worktree isolation, (b) multi-agent orchestration UX, or (c) “spec-first” correctness philosophy—those are now a crowded space.

---

## E. Vacancies and gaps that still look real

### Gap: rigorous **runtime model** for autonomous delivery (state + recovery) that is reusable across ecosystems

**Observed:** The upstream SPEC is unusually explicit that Symphony’s orchestrator should have one authoritative state, reconcile before dispatch, and support restart recovery driven by tracker + filesystem state—no durable DB required. citeturn36search2turn5view1

**Observed:** Mature workflow/orchestration systems (Azure Durable Functions, Temporal, Step Functions, LangGraph) emphasize durable execution, replay/determinism constraints, and retry/catch semantics as first-class features. citeturn30search2turn30search0turn30search1turn29search2

**Interpretation (gap):** There is still a missing *standardized*, academically clear mapping from “issue-driven coding delivery” to “durable workflow semantics.” Many 2026-era toolchains implement *ad-hoc* run state (JSON logs, SQLite, local metadata) rather than a formally specified state machine with proven idempotency/restart invariants. Symphony is closer to that “contract-first” stance than most local orchestrators, but the broader field lacks a shared runtime formalism and reference correctness criteria.

### Gap: proof gates are widespread, but **what counts as proof** is not stable or comparable

**Observed:** Symphony’s fork hard-codes an artifact contract (knowledge base files, per-issue progress, feature YAML, publish gate checks) as a form of “proof-of-work structure.” citeturn4view5turn4view7turn4view8

**Observed:** “Dark factory” approaches emphasize specs/scenarios and deterministic validations (tests/linters) plus sometimes “LLM-as-judge” layers. citeturn25view1turn18view0turn24search9

**Observed:** Many agent observability tools focus on tracing and evaluation (token/cost/latency, LLM-as-judge) but not on “delivery proof” semantics tied to CI/CD and release readiness. citeturn31search0turn31search3turn31search2

**Interpretation (gap):** The field lacks a cohesive, falsifiable definition of “proof gates” for autonomous delivery that covers: (i) tests/CI, (ii) artifact completeness/traceability, (iii) policy compliance, and (iv) operational readiness. This is a strong thesis gap because it is both practically important and measurable.

### Gap: control vs autonomy boundary remains ad-hoc, even in major platforms

**Observed:** GitHub’s Copilot coding agent flow can require manual approval for GitHub Actions workflows to run when Copilot pushes changes, which is an explicit “human approval gate” imposed by the platform. citeturn29search7

**Observed:** GitHub simultaneously positions an “agent control plane” for enterprise governance and auditability—suggesting that the hard part at scale is control, not just agent capability. citeturn29search4turn7search11

**Interpretation (gap):** “Who owns execution” is still inconsistent across systems. Many tools are either (a) powerful but not governable, or (b) governable but not truly runtime-owned (because approvals, CI triggers, or merges remain human- or platform-mediated). A thesis can contribute by making this boundary explicit, implementable, and evaluable.

### Gap: multi-agent engineering is fast-moving and fragile, with coordination and infra issues

A 2026 large-scale empirical study of open-source multi-agent systems reports frequent issues in bugs, infrastructure, and coordination challenges, and argues for improved testing infrastructure, documentation, and maintenance practices to ensure reliability. citeturn29search1

**Interpretation (gap):** A “delivery engine” thesis can legitimately claim to address this by shifting effort from “better prompting” to “operational control systems”: bounded concurrency, deterministic workspaces, explicit gates, and observable state.

---

## F. Positioning of Symphony against the newly surfaced overlap

### Against the upstream Symphony concept

**Observed:** The fork explicitly positions itself as tracking the upstream SPEC while extending the self-hosted Elixir implementation and adding a repo-owned harness used to run Symphony on itself (“dogfooding”). citeturn35view0turn35view2

**Observed:** The fork lists concrete additions: manual intake, PR review follow-up intake via webhooks, persisted runtime state, dashboard/API/metrics, and harness enforcement. citeturn35view1turn4view5turn4view6turn4view7

**Interpretation:** The upstream project’s “original concept” is primarily **the contract** (a long-running tracker reader + scheduler/runner with bounded concurrency, reconciliation, retries, restart recovery, repo-owned policy). The fork’s differentiation is primarily **operationalization**: repo-owned harness enforcement, dogfood workflows, and explicit observability surfaces.

### Against issue/board-driven autonomous delivery systems

- **Versus GitHub Copilot coding agent.** Copilot is deeply integrated into GitHub’s workflow but is constrained by platform gates (e.g., workflow approvals) and is not framed as a self-hostable daemon with explicit orchestration semantics. Symphony’s value proposition is closer to “owning the runtime semantics yourself” (daemon loop, reconciliation, persisted stage state), while Copilot positions “assign issue → get PR.” citeturn29search20turn29search7turn5view1turn4view6

- **Versus Composio agent-orchestrator.** This is *much closer overlap* than Copilot in spirit: per-agent worktrees/PRs, CI fail fixing, review-comment loops, and tracker-agnostic claims mirror Symphony’s “delivery loop” story strongly. citeturn36search0turn36search15turn4view10  
  **Critical originality note:** This substantially erodes any uniqueness claim around “CI-mediated autonomous delivery” as a concept—at least at the PR loop level.

### Against “dark software factory” patterns (specs/scenarios in, code out)

- **Versus OctopusGarden.** OctopusGarden explicitly claims scenario-driven convergence without human code review. That overlaps with Symphony’s “proof gate” motivation but differs in the unit of work and operational contract: Symphony anchor is the tracker issue and repo policy/harness; OctopusGarden anchor is spec + scenario convergence. citeturn18view0turn5view1turn4view7

- **Versus StrongDM Attractor.** Attractor is a spec set (NLSpecs) describing how to build a non-interactive coding agent and a unified LLM client; it’s a blueprint for a software factory, not the factory runtime itself. Symphony is the opposite: a runtime contract and (in this fork) a working daemon. citeturn24search1turn24search6turn5view1turn35view1

- **Versus Fabro.** Fabro is explicitly “workflow graphs orchestrating agents, commands, and human decisions,” with sandboxes and long-horizon runs. This overlaps with Symphony’s “runtime owns invariants + proof gates,” but Fabro’s abstraction is a generic workflow engine rather than a tracker-driven issue daemon. citeturn25view1turn36search1turn5view1

**Interpretation:** If you want to claim “Symphony is in the dark factory neighborhood,” the academically honest claim is: Symphony is a *tracker-driven delivery runtime* that could be one instantiation of “dark factory” practices (if configured to minimize human review), but “dark factory” itself is not unique to Symphony and is now a widely discussed pattern with multiple implementations/blueprints. citeturn25view1turn24search9turn18view0turn23search12

### Against operator UIs / control planes

Here the overlap is strongest—and most important to admit bluntly:

- Mozzie explicitly positions itself as a local-first orchestrator that breaks work into work items, spawns isolated git worktrees, manages dependencies, and queues work for review/merge. citeturn13view0turn12view0  
- AgentBase is a visual canvas/control center for parallel agents with centralized approvals and edit isolation. citeturn28view0  
- TUICommander is a unified window with terminals/diffs/PRs/CI status and worktree automation plus agent-awareness (rate limits, Y/N prompts, etc.). citeturn16view0turn15view0  
- GitHub is explicitly moving toward an enterprise agent control plane for governance/audit. citeturn29search4turn7search11

**Critical originality note:** If the earlier report implied Symphony was uncommon in having an “operator view/control plane,” that is no longer accurate in March 2026. There is now a clear and active category of “agent control planes,” ranging from desktop orchestration to enterprise governance. citeturn13view0turn28view0turn16view0turn29search4

### Against execution substrates and worktree managers

Per-task isolation via git worktrees is now commoditized:

- The Codex app itself formalizes worktrees and background automations on dedicated worktrees. citeturn28view1turn33search4  
- Rover explicitly markets multiple background agents in isolated environments and supports multiple agent CLIs. citeturn18view3turn9search9  
- agtx, agentree, ccswarm all explicitly package “parallel agents + worktree isolation (+ sometimes tmux)” patterns. citeturn18view4turn18view7turn18view8

**Critical originality note:** Symphony cannot credibly claim novelty on “worktree isolation” (or even “multi-agent parallelism”) anymore; the defendable uniqueness needs to move to the **runtime semantics + policy/proof integration + observability** level. citeturn18view3turn18view4turn28view1turn5view1turn4view7turn4view6

### What Symphony still combines in a potentially valuable way

This is the “if it’s not new, what’s the interesting combination?” answer you asked for.

**Observed pieces that already exist elsewhere (not novel on their own):**
- Issue/board → PR automation exists in major platforms and tools. citeturn29search20turn22search2turn36search0  
- Per-task worktree isolation exists broadly. citeturn28view1turn18view3turn18view4  
- Workflow/policy-as-code exists in general workflow engines and agent-oriented workflow graph systems. citeturn25view1turn30search0turn29search2  
- Spec/proof gating exists in OpenSpec, Ouroboros, scenario-based systems, etc. citeturn26view0turn18view2turn18view0  
- Observability for LLM apps exists via tracing/evals platforms (Langfuse, Phoenix, LangSmith) and standard telemetry stacks (Prometheus, OpenTelemetry). citeturn31search9turn31search3turn31search6turn30search9

**Observed combination that Symphony (esp. this fork) emphasizes:**
- A *scheduler/runner* daemon semantics (bounded concurrency, reconciliation, retries, restart recovery without a DB) + tracker reader contract from the SPEC, citeturn5view1turn36search2  
- coupled with a **repo-owned harness** that forces durable, version-controlled “facts” and progress artifacts, plus publish gates that fail fast if the repo state is incomplete, citeturn4view5turn4view7turn4view8  
- plus explicit operator surfaces (/state API, delivery reports, metrics, run_state.json) intended to support operations and debugging of multiple concurrent runs. citeturn4view6turn4view5turn35view1

**Interpretation (why this combination could be valuable):** A large fraction of the new projects optimize either “more agents locally” or “better specs,” but they don’t standardize the *delivery runtime contract* in a way that is easy to defend academically: what exactly is a run, what are the stages, what invariants hold, what is the restart behavior, what constitutes proof at each gate, what is the audit trail, and where do policy decisions live. Symphony is unusually explicit about being a *runner/scheduler* with a repo-owned policy contract, and this fork makes that more concrete by adding a repo-owned harness contract and operational surfaces. citeturn5view1turn4view7turn4view6turn4view10

---

## G. Possible thesis contribution formulations

Each option is designed to be defensible *even if Symphony is “just a fork”*, by making the contribution about **formalization + evaluation + engineered guarantees** rather than about originating the concept.

### Thesis option: Formal runtime model and recovery semantics for issue-driven agent delivery

**Tentative title:** “A Formal Runtime Model for Issue‑Driven Autonomous Software Delivery with Deterministic Recovery”

**Problem:** Systems that run coding agents over long horizons often lack explicitly specified recovery semantics and idempotency rules, making retries, restarts, and reconciliation ad-hoc and hard to validate. citeturn5view1turn29search2turn30search2turn29search1

**Hypothesis / central idea:** If you formalize Symphony’s delivery engine as a finite-state machine with explicit invariants (eligibility, workspace determinism, idempotent transitions, stop reasons), you can provide measurable improvements in robustness (fewer stuck runs, clearer failure classification, reproducible restart behavior) without relying on strong sandbox assumptions.

**Realistic scope:** Implement a “runtime spec layer” in the fork: state machine definitions, transition guards, persistence schema, and deterministic replay tests; add property-based tests for critical invariants; compare behavior under fault injection (timeouts, webhook duplication, workspace corruption). citeturn4view6turn5view1turn36search2turn30search2

**What you would implement:**  
- A formal stage/transition model (e.g., typed state machine) aligned to the documented delivery loop. citeturn4view10turn4view6  
- Crash/restart replay tests using persisted run state. citeturn4view6turn36search2  
- Explicit reconciliation logic tests: tracker state changes stop runs deterministically. citeturn5view1turn5view2

**Validation:**  
- Controlled experiments: inject failures and measure “time to safe stop,” “time to resume,” “rate of duplicated work,” “rate of unreconciled stale workspaces.”  
- Qualitative operator evaluation: compare debuggability before/after via run_state and delivery reports. citeturn4view6turn31search6

**State of the art vs contribution:**  
- SoTA: durable execution engines define recovery and determinism constraints. citeturn30search0turn30search2turn29search2  
- Contribution: mapping those semantics concretely to issue-driven coding delivery and validating them in an open implementation.

**Risk:** Medium. Main risk is writing a rigorous evaluation harness and creating realistic failure workloads. The technical depth is solid and thesis-defensible.

---

### Thesis option: Repo-owned policy + proof gates as a programmable contract for autonomous delivery

**Tentative title:** “Policy‑as‑Code and Proof‑Gated Pipelines for Autonomous Software Delivery”

**Problem:** “Agentic delivery” systems often blur the line between prompt instructions and enforceable policy, leading to unpredictable process behavior and weak auditability.

**Hypothesis / central idea:** A repo-owned harness/policy contract (like Symphony’s harness.yml + structured artifacts) can enforce traceability and “proof-of-work completeness” better than prompt-only rules, and can be evaluated with measurable compliance outcomes (missing artifacts, missing evidence, incorrect feature registry updates). citeturn4view5turn4view7turn4view8turn33search0

**Realistic scope:** Evolve `.symphony/harness.yml` into a small DSL with typed checks, stage-scoped requirements, and CI integration; implement validators; run on a set of tasks and measure compliance and defect rates.

**What you would implement:**  
- Extend the harness schema: stage-specific requirements (“before publish: must have evidence; before merge: CI green; before post_merge: smoke rerun”), drawing on the existing gate structure. citeturn4view7turn4view10  
- A proof artifact index + checker that maps each gate to required evidence. citeturn4view5turn4view7turn4view6  
- Optional integration with LLM-as-judge evaluation tools (careful: treat as an additional signal, not proof). citeturn31search0turn31search3turn25view1

**Validation:**  
- Quantitative: number of runs blocked by missing artifacts, reduction over time, correlation with CI failures/rework.  
- Comparative: run the same tasks with “prompt-only policies” vs “harness-enforced policies” and compare predictability and operator effort.

**State of the art vs contribution:**  
- SoTA: harness engineering as an industry practice; workflow graphs as explicit orchestration; spec-first systems. citeturn33search0turn25view1turn26view0  
- Contribution: a concrete, testable, repo-owned “proof gate contract” for autonomous delivery and an evaluation on real tasks.

**Risk:** Medium-low. Most risk is designing the contract to be general enough but still evaluable.

---

### Thesis option: Observability and control-plane model for autonomous coding runs (bridging LLM traces with delivery stages)

**Tentative title:** “Operational Observability for Autonomous Coding Pipelines: Correlating Agent Traces with Delivery Runtime State”

**Problem:** LLM observability tools focus on traces/evals, while delivery engines need stage-level operational telemetry (run state, retries, CI gate outcomes). The layers are often poorly correlated.

**Hypothesis / central idea:** If you define a unified telemetry model (OpenTelemetry-compatible) that correlates (a) runtime stage transitions, (b) tool/model events, and (c) CI/proof gate outcomes, you improve debuggability and reduce mean time to restore (MTTR) for stuck/failed agent runs. citeturn4view6turn30search9turn31search6turn31search0turn31search3

**Realistic scope:** Add OpenTelemetry spans/events around stage transitions and gate checks; export metrics; optionally emit traces to Phoenix/Langfuse; produce dashboards; evaluate via incident-style exercises.

**What you would implement:**  
- Stage spans: checkout/implement/validate/verify/publish/await_checks/merge/post_merge tied to run identifiers and issue identifiers. citeturn4view10turn4view6  
- Metrics hygiene: counters and durations already suggested; formalize and enforce cardinality constraints. citeturn4view6turn31search6turn31search8  
- Trace export: integrate with an LLM tracing system (Phoenix/Langfuse/LangSmith) for model/tool-level detail. citeturn31search3turn31search0turn31search2

**Validation:**  
- Measure MTTR on scripted failure scenarios (rate limit, CI failure, merge conflict, missing artifact) with and without correlation. citeturn4view6turn33search2turn30search1

**State of the art vs contribution:**  
- SoTA: LLM observability platforms + OpenTelemetry signals. citeturn31search9turn31search3turn30search9turn30search3  
- Contribution: a delivery-runtime-specific semantic convention and evaluation methodology for autonomous coding operations.

**Risk:** Medium. The main risk is scoping: keep it to 1–2 backends and a small set of metrics/traces that actually help.

---

### Thesis option: Bounded execution and permissioning for repo-aware autonomous delivery

**Tentative title:** “Bounded Execution for Repo‑Aware Coding Agents: A Permission Model for Autonomous Delivery Runtimes”

**Problem:** Many systems claim “bounded execution” but rely on social conventions (“stay in workspace directory”) rather than enforceable capabilities. This is especially risky for unattended delivery.

**Hypothesis / central idea:** A capability-based permission model (filesystem/network/tool restrictions) integrated into the runtime’s stage machine reduces dangerous actions and improves predictability—without falling back to excessive human-in-the-loop gating.

**Realistic scope:** Build a “sandbox adapter” layer that can target one or two execution backends (e.g., Codex sandbox settings vs containerized sandbox); formally specify allowed operations per stage; implement enforcement and auditing.

**What you would implement:**  
- Stage-scoped capability rules: e.g., implement stage can write workspace, publish can push git, merge requires CI green, etc. (aligning with the “sandbox vs approval policy” separation). citeturn33search5turn33search2turn4view10  
- Audit logs for boundary crossings, tied to run_state. citeturn4view6turn30search9

**Validation:**  
- Safety regression tests: attempt out-of-policy commands and confirm deny; measure false positives/negatives.  
- Operator burden: ensure the system doesn’t become “approval spam.”

**State of the art vs contribution:**  
- SoTA: Codex sandboxing/approvals; orchestration engines’ determinism constraints; platform governance trends. citeturn33search5turn33search2turn30search2turn29search4  
- Contribution: a delivery-runtime-specific permission model tied to stages and proof gates, with evaluation.

**Risk:** Higher. Security claims are hard to prove; be careful to position this as “constrained execution semantics” rather than “secure sandbox.”

---

## H. Recommendation on the most defensible thesis framing and I. Bibliography and sources

### Recommended framing (honest, thesis-defensible)

**Best way to “sell” the problem:**  
Engineering organizations are moving from “agents that can write code” to “systems that can reliably deliver software with minimal supervision.” The hard part is the **control system**: determinism, recovery, gates, evidence, and observability—not the model. This is consistent with both major vendor narratives around harness engineering and with the emergence of agent control planes. citeturn33search0turn29search4turn25view1turn5view1

**Best way to define the contribution (what you can actually prove):**  
Position your work as an *engineered runtime contract and its validation*:  
- a precise runtime model (state machine + invariants),  
- repo-owned policy/proof gates as enforceable contracts,  
- durable run state and observability,  
- and evaluation on real tasks + failure injection. citeturn5view1turn4view7turn4view6turn30search2turn29search2

**Claims to avoid (sound grandiose / hard to prove):**  
- “Fully autonomous software factory” (too broad, and now crowded by multiple “dark factory” projects and narratives). citeturn18view0turn25view1turn24search9turn23search12  
- “Secure sandboxed execution” unless you truly implement and evaluate security boundaries (and even then, limit claims). citeturn5view1turn33search5turn22search7  
- “Model-agnostic” as a blanket claim unless you demonstrate multi-provider operation end-to-end (tooling and permissions diverge by platform). citeturn5view2turn33search7turn18view9turn18view3

**Claims you *can* likely sustain with an implementation like this fork:**  
- “A runtime-owned, issue-driven orchestration model that makes the delivery pipeline explicit and observable,” grounded in the SPEC and implemented surfaces (run_state, dashboard/API/metrics, deterministic stage loop). citeturn5view1turn4view6turn4view10turn35view1  
- “Repo-owned proof gates and artifact contracts reduce ambiguity and increase traceability,” grounded in the harness contract, required artifacts, and publish gate rules. citeturn4view5turn4view7turn4view8  
- “Operational debuggability improves when state and gates are first-class” (validate with experiments). citeturn4view6turn31search6turn31search0

**How to avoid sounding like a fork/clone:**  
Treat the fork as a *baseline implementation* of the upstream contract, and define your thesis contribution as a **measurable extension** (runtime formalization, proof gate DSL, observability correlation, or bounded execution semantics). Explicitly separate: “upstream contract” vs “fork operationalization” vs “my thesis contribution.” citeturn35view2turn5view1turn35view1

### Compact bibliography and primary sources (selection)

(These are the most load-bearing sources used throughout the analysis; citations above point to them in-context.)

- entity["company","OpenAI","ai company, us"] Symphony SPEC and Elixir reference implementation; harness engineering; Codex sandboxing and worktrees. citeturn5view1turn5view2turn33search0turn33search5turn28view1  
- entity["company","Anthropic","ai company, us"] Effective harnesses for long-running agents; Claude Agent SDK context management. citeturn32search0turn32search1  
- entity["company","GitHub","code hosting, us"] Copilot coding agent workflow constraints and enterprise agent control-plane governance. citeturn29search20turn29search7turn29search4turn7search11  
- entity["company","StrongDM","access mgmt company, us"] Attractor NLSpecs and software factory narrative. citeturn24search1turn24search5  
- entity["company","Temporal","workflow engine company, us"] Durable execution concept grounding. citeturn30search0  
- entity["company","Amazon Web Services","cloud provider, us"] Step Functions error handling/retry model (for workflow-engine comparison). citeturn30search1  
- entity["company","Microsoft","software company, us"] Azure Durable Functions determinism/replay constraints grounding. citeturn30search2  
- entity["organization","OpenTelemetry","observability project"] Telemetry signals and correlation primitives (traces/metrics/logs) grounding. citeturn30search9turn30search3  
- entity["organization","Prometheus","monitoring system"] Metrics scraping model grounding. citeturn31search6turn31search14  
- entity["company","Arize AI","ai observability company, us"] Phoenix open-source LLM tracing/eval. citeturn31search3turn31search1  
- entity["company","LangChain","ai devtools company, us"] LangGraph durable execution + HITL concepts (framework comparison). citeturn29search2turn29search6  
- Multi-agent engineering empirical study (fragility/coordination issues). citeturn29search1  
- entity["organization","Product Hunt","product discovery site"] Evidence of Mozzie as a current emerging product linked to its GitHub repo. citeturn12view1turn13view0  
- entity["organization","Hacker News","tech news site"] Evidence of “dark factory”/agent-orchestration discourse intensity and project discovery. citeturn17search18turn23search6