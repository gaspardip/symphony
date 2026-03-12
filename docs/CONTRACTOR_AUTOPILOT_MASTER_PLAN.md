# Contractor Autopilot Master Plan

## Summary

This document is the single source of truth for Symphony's contractor-stealth operating model, autonomous delivery runtime, deployment/proof direction, and portfolio/operator features.

It consolidates the autonomous delivery work that has already been proven, the contractor/client-safe operating model, and the remaining roadmap needed to make Symphony practical for long-term contractor use and personal autopilot.

Default operating model going forward:

- personal repos: `private_autopilot`
- contractor repos: `client_safe_shadow`
- review automation: `draft replies first`
- author profile source: `manual profile file`
- user-facing handoff: assignee-first when a tracker exists, manual intake always available

## Baseline Capabilities Already Achieved

These are treated as the locked baseline going forward:

- autonomous checkout/implement/validate/verify/publish/await-checks/merge/post-merge
- manual intake
- webhook-first tracker intake
- workflow profiles and policy classes
- passive late-stage runtime control
- repo compatibility gate
- behavioral proof and UI-proof engine support
- portfolio/report endpoints in current limited form

Operational and still-pending docs that remain active:

- [DOGFOOD_OPERATIONS.md](/Users/gaspar/src/symphony/docs/DOGFOOD_OPERATIONS.md)
- [SELF_DEVELOPMENT_HARNESS_PLAN.md](/Users/gaspar/src/symphony/docs/SELF_DEVELOPMENT_HARNESS_PLAN.md)
- [MANUAL_RUNS.md](/Users/gaspar/src/symphony/docs/MANUAL_RUNS.md)
- [EVENTS_PILOT_OPERATIONS.md](/Users/gaspar/src/symphony/docs/EVENTS_PILOT_OPERATIONS.md)

## Ranked Backlog

| Rank | Feature | Score | Current status | Target phase |
|---|---|---:|---|---|
| 1 | Company policy packs and operating modes | 10.0 | Partial | Phase 1 |
| 2 | Identity safety / “act as me” policy layer | 10.0 | Missing | Phase 1 |
| 3 | Credential and secret compartmentalization | 10.0 | Missing | Phase 1 |
| 4 | PR watcher with draft-first review handling | 9.5 | Missing | Phase 2 |
| 5 | Blast-radius controls and circuit breakers | 9.5 | Missing | Phase 1 |
| 6 | Deployment runtime with preview/prod/post-deploy/rollback | 9.0 | Partial | Phase 3 |
| 7 | Change/risk classification engine | 9.0 | Missing | Phase 1 |
| 8 | Manual author profile / voice contract | 8.5 | Missing | Phase 1 |
| 9 | Repo compatibility certification | 8.5 | Implemented/needs productization | Phase 0 wrap-up |
| 10 | Artifact-centric proof for UI/deploy work | 8.5 | Partial | Phase 3 |
| 11 | Portfolio mode / cross-company console | 8.0 | Partial | Phase 4 |
| 12 | Replay / simulation / shadow execution mode | 8.0 | Missing | Phase 5 |
| 13 | Internal Symphony traceability project | 8.0 | Partial | Phase 2 |
| 14 | Provider/model analytics and agent pressure metrics | 7.5 | Partial | Phase 4 |
| 15 | Business-readable delivery reports | 7.5 | Partial | Phase 2 |
| 16 | Workload shaping / portfolio-level batching | 7.0 | Missing | Phase 4 |
| 17 | Multi-ingestion support beyond current tracker/manual paths | 6.5 | Partial | Phase 5 |
| 18 | Post-run learning and recommendation loop | 6.5 | Missing | Phase 6 |
| 19 | Multi-repo issue orchestration | 6.0 | Missing | Phase 6 |
| 20 | Direct external provider integrations | 5.5 | Deferred | Phase 6 |

## Implementation Phases

### Phase 0: Consolidate and lock the baseline

- Write and maintain this master plan as the single source of truth.
- Treat the baseline capabilities above as complete platform primitives.
- Keep only the still-operational runbooks and pending dogfood/self-development docs active.
- Delete superseded planning docs once their remaining value has been folded into this document.

### Phase 1: Safety-first contractor mode

- Add first-class operating modes:
  - `private_autopilot`
  - `client_safe_shadow`
  - `client_safe_pr_active`
  - `full_runtime`
- Extend policy packs so they explicitly decide:
  - tracker mutation allowed or forbidden
  - PR posting allowed or forbidden
  - thread resolution allowed or forbidden
  - preview deploy allowed or forbidden
  - production deploy allowed or forbidden
  - external comment posting allowed or forbidden
  - working-hours/deploy-window restrictions
- Add an identity-safety contract distinct from style:
  - can Symphony post as the operator?
  - must it draft first?
  - may it resolve comments?
  - what confidence language is allowed?
  - what channels are allowed?
- Add a credential registry with per-company/per-repo scopes:
  - allowed providers
  - allowed tokens
  - allowed environments
  - allowed operations
  - allowed deploy targets
- Add blast-radius controls:
  - max concurrent runs per company
  - max merges/day per repo
  - no production deploy outside allowed windows
  - circuit-breaker after repeated failures
  - repo freeze / company freeze modes
- Add a change/risk classifier that computes:
  - `change_type`
  - `risk_level`
  - `proof_class`
  - `approval_class`
- Add a local author profile file outside client repos and route commit/PR/comment rendering through it.
- Surface all of the above in policy payloads and issue-level runtime summaries.

### Phase 2: Stealth review operations

- Add a PR watcher that ingests:
  - review comments
  - review decisions
  - requested changes
  - check changes
- Default contractor behavior:
  - classify new comments
  - draft a reply in your style
  - draft a resolution recommendation
  - never post automatically in `client_safe_shadow`
- Add review-comment state tracking:
  - `unreviewed`
  - `drafted`
  - `approved_to_post`
  - `posted`
  - `resolved`
  - `rejected`
- Add internal Symphony traceability links:
  - internal Symphony issue
  - external client issue/manual source
  - PR
  - proof artifact
  - deploy artifact
- Upgrade business-readable delivery reports so they can explain:
  - what changed
  - why Symphony thought it was ready
  - what proof/approval was used
  - what still needs human input

### Phase 3: Deployment and proof hardening

- Productize the existing deployment runtime into a supported contract:
  - `deploy_preview`
  - `post_deploy_verify`
  - `deploy_production`
  - `rollback`
- Bind deploy behavior to policy packs so client repos can stay PR-only while personal repos can go further.
- Extend proof policy so UI/deploy-sensitive work can require:
  - local proof
  - artifact proof
  - CI proof
  - external-service proof through declared checks/artifacts
- Make `events` the baseline repo for:
  - mandatory UI proof on real user-facing paths
  - first preview/post-deploy verification path if feasible
- Require deployment evidence to be surfaced in the same operator-facing style as merge/finalization.

### Phase 4: Portfolio operator console

- Expand portfolio mode from aggregation into a real operator surface:
  - group by company
  - group by repo
  - group by operating mode
  - group by approval needed
  - group by blocked reason
  - group by deploy state
- Add workload-shaping controls:
  - prioritize company/repo groups
  - batch approvals
  - batch “needs operator review”
  - “safe to ignore until” windows
  - no-deploy / low-activity windows
- Add provider/model analytics and agent-pressure reporting:
  - per-provider completion rate
  - time-to-PR
  - time-to-merge
  - review wait time
  - proof failure rate
  - deploy success rate
  - attention backlog
  - passive wait saturation
- Keep analytics local-first and optional.

### Phase 5: Replay and broader intake

- Add replay/simulation/shadow execution mode:
  - no external mutations
  - “would have done” report
  - provider/profile comparison on the same issue
- Use this as the onboarding path for contractor repos before enabling active modes.
- Expand ingestion only after replay exists:
  - stronger API submission
  - GitHub Issues
  - Jira or other tracker adapters
- Keep assignee-first as the preferred human-facing workflow where a tracker exists.
- Manual intake remains permanent, not a debug path.

### Phase 6: Advanced autonomy

- Add post-run learning that is advisory, not self-mutating:
  - outcome analysis
  - verifier disagreement analysis
  - provider effectiveness by repo/profile
  - suggested policy/proof changes
- Add multi-repo issue orchestration for issues spanning multiple repos.
- Add direct external provider integrations only after the contract-based approach is insufficient.
- Keep every expansion behind company/repo policy packs and credential boundaries.

## Test Plan

### Phase 1 tests

- contractor shadow mode forbids tracker mutation and external posting
- credential scope violations block before action
- risk classification changes proof/approval behavior correctly
- circuit breakers freeze the right repos/companies
- author profile rendering is deterministic

### Phase 2 tests

- new PR comments generate drafts, not posts, in shadow mode
- requested-changes reviews reopen the right work path
- internal traceability links are created without touching client trackers
- business-readable reports explain proof and approvals clearly

### Phase 3 tests

- preview deploy and post-deploy verification succeed on a live or simulated repo path
- deploy approvals gate production correctly
- mandatory UI/deploy proof blocks merge when evidence is missing

### Phase 4 tests

- portfolio grouping, batching, and backlog summaries are correct
- metrics remain accurate across multiple runners and providers

### Phase 5 tests

- replay mode produces no external mutations
- the same issue can be evaluated under multiple provider/profile combinations
- tracker outages do not break manual/replay operation

### Phase 6 tests

- recommendations are generated from outcomes but never mutate policy automatically
- multi-repo orchestration maintains repo/company boundaries

## Assumptions

- Dogfood and self-development plans remain active and are not deleted.
- Git history is sufficient archive for deleted superseded planning docs.
- `events` remains the active proof-heavy baseline repo.
- The pet match mobile app becomes the next repo-onboarding target after Phase 1 or Phase 2.
- `private_autopilot` and `client_safe_shadow` remain the default product modes unless later evidence proves otherwise.
