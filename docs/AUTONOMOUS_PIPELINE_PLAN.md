# Autonomous Pipeline Hardening Plan

## Summary

Goal: take the current `gaspardip/symphony` fork from "runtime-owned delivery engine with working primitives" to a boringly reliable autonomous dev pipeline. The remaining work is operational hardening across eight areas: publish/merge reliability, crash recovery, prompt/runtime minimization, stronger verification, repo contract standardization, audit/policy rigor, dogfood operations, and test/coverage discipline.

Execution order:

1. Runtime profile and workflow slimming
2. Publish/CI/merge reliability
3. Restart-safe recovery
4. Verifier and acceptance enforcement
5. Repo contract standardization
6. Audit, policy, and dashboard reason codes
7. Dogfood promotion and canary operations
8. Coverage expansion and merge gates

## Key Changes

### 1. Runtime Profile And Workflow Minimization

- Replace the remaining legacy prompt-heavy workflows in `elixir/WORKFLOW.md` and `../symphony-local/WORKFLOW.template.md` with a compact runtime-owned prompt contract:
  - issue context
  - repo scope
  - harness-only validation rule
  - required `report_agent_turn_result`
  - explicit prohibition on git/PR/state mutations by the agent
- Add a dedicated Symphony runtime profile in config:
  - minimal `CODEX_HOME`
  - explicit env allowlist
  - no inherited skills catalog
  - no host-wide shell env inheritance by default
- Introduce stage-aware token budgets:
  - global per-turn and per-issue caps remain
  - add per-stage ceilings for `implement`, `verify`, and `await_checks`
- Acceptance:
  - turn-1 prompt size is materially smaller than current default workflows
  - runtime config is isolated from the desktop-agent environment

### 2. Publish / CI / Merge Reliability

- Harden `PullRequestManager` behind a deterministic GitHub adapter with typed outcomes:
  - `created`
  - `updated`
  - `already_exists`
  - `merge_ready`
  - `checks_missing`
  - `checks_pending`
  - `checks_failed`
  - `merge_failed`
- Treat publish and merge as idempotent stages:
  - same branch + same diff should update the existing PR, not create a new one
  - merge retries must not duplicate comments or state transitions
- Add stronger required-check handling:
  - distinguish "missing check name", "pending", "failed", and "cancelled"
  - enforce branch-protection mismatch as a typed block reason
  - add bounded polling with jitter/backoff
- Add GitHub fallback strategy:
  - primary path can remain `gh`
  - add a direct API fallback for PR/check polling and merge when CLI output is unavailable or malformed
- Acceptance:
  - publish and merge stages are repeatable and safe after partial failure
  - missing or stale checks block with a specific reason, not a generic failure

### 3. Restart-Safe Recovery

- Extend `RunStateStore` so every stage checkpoint stores:
  - stage
  - stage attempt count
  - validation attempt count
  - PR number and URL
  - last commit SHA
  - merge SHA
  - last known review/check snapshot
  - last stop reason and failure class
- Make `DeliveryEngine` resume from persisted stage instead of re-deriving from scratch:
  - `await_checks` resumes polling
  - `merge` resumes merge completion
  - `post_merge` resumes verification on default branch
- Strengthen `LeaseManager`:
  - explicit lease epoch/version
  - safe stale-lease takeover rules
  - split-brain detection when two orchestrators claim the same issue
- Acceptance:
  - killing Symphony mid-run and restarting preserves stage intent exactly
  - no duplicate PRs, merges, or re-dispatches after recovery

### 4. Verifier And Acceptance Enforcement

- Promote `VerifierRunner` from command wrapper to independent acceptance gate.
- Add a typed verifier verdict:
  - `pass`
  - `needs_more_work`
  - `blocked`
  - `unsafe_to_merge`
- Define a simple acceptance contract for each run:
  - parse issue acceptance criteria when present
  - otherwise fall back to harness-backed behavioral proof
- Require verifier approval before publish when `policy.require_verifier` is enabled.
- On validation failure, continue implementation within budget.
- On verifier failure, return to `implement` with a compact failure summary until retry budget is exhausted.
- Acceptance:
  - passing validation alone is not enough to publish
  - verifier failures are first-class and restart-safe

### 5. Repo Contract Standardization

- Freeze `.symphony/harness.yml` as the only repo execution contract.
- Standardize required keys:
  - `base_branch`
  - `preflight.command`
  - `validation.command`
  - `smoke.command`
  - `post_merge.command`
  - `artifacts.command`
  - `pull_request.required_checks`
- Add a repo-contract validator in Symphony startup:
  - fail fast if the target repo has no harness
  - fail fast if required commands or checks are missing
- Add a documented harness template and validation checklist for new repos.
- Keep `events` and `symphony` as the reference implementations.
- Acceptance:
  - no prompt-driven guessing of commands remains
  - unsupported repos fail early with exact unblock steps

### 6. Audit, Policy, And Operator Control

- Expand `RunLedger` into a typed audit trail for every material decision:
  - dispatch
  - lease acquire/release
  - stage transition
  - validation result
  - verifier verdict
  - publish result
  - check poll result
  - merge result
  - post-merge result
  - operator action
  - stop/block decision with rule ID
- Introduce stable failure classes:
  - `environment`
  - `implementation`
  - `validation`
  - `verification`
  - `publish`
  - `review`
  - `merge`
  - `post_merge`
  - `coordination`
  - `budget`
- Add policy classes for issues:
  - `fully_autonomous`
  - `review_required`
  - `never_automerge`
- Surface exact decision reasons in the dashboard/API:
  - which rule fired
  - what data triggered it
  - what human action is needed, if any
- Acceptance:
  - every blocked or merged run is explainable from the ledger without reading logs
  - dashboard control actions map one-to-one to ledger events

### 7. Dogfood Operations And Stable Runner Promotion

- Keep dogfooding gated to issues labeled `dogfood:symphony`.
- Operationalize `ops/promote-runner.sh` with a full runner lifecycle:
  - promote
  - inspect current release
  - rollback to previous release
  - record canary outcome
- Add canary policy for dogfood:
  - new promoted runner first handles a small allowlisted set of issues
  - require healthy smoke/post-merge results before broader use
- Add a protected runner-boundary check:
  - never allow target workspace overlap with install root or executing checkout
- Keep promotion manual in v1 even if issue execution is autonomous.
- Acceptance:
  - merged dogfood changes do not affect the live runner until manual promotion
  - rollback is one command and preserves the last known-good release

### 8. Tests And Coverage As Merge Gates

- Expand tests around the new orchestration core:
  - `DeliveryEngine`
  - `PullRequestManager`
  - `RunStateStore`
  - `LeaseManager`
  - `RepoHarness`
  - `VerifierRunner`
  - `PriorityEngine`
  - `Orchestrator`
- Add deterministic test doubles for:
  - GitHub adapter
  - Linear adapter
  - Codex turn-result reporting
  - harness command runner
  - clock/timer for polling and lease expiry
- Add crash-recovery integration tests:
  - restart during `implement`
  - restart during `await_checks`
  - restart during `merge`
  - restart during `post_merge`
- Add dogfood-specific integration tests:
  - label-gated dispatch
  - protected runner overlap refusal
  - promotion metadata load
  - post-merge rework/block behavior
- Keep coverage as a hard CI gate.
- Current repo state:
  - `mix test` is green
  - `make coverage` is green
  - overall Elixir app coverage is `94.51%`
  - core runtime modules satisfy the current hard floor
- Default coverage targets:
  - core runtime modules: 85% minimum line coverage as a hard floor
  - overall Elixir app: 90% minimum line coverage
  - any module below 90% goes on the watchlist for the next coverage pass
- Current watchlist after the latest Phase 8 verification:
  - `SymphonyElixir.CLI` at `87.14%`
  - `SymphonyElixir.Orchestrator` at `88.03%`
  - `SymphonyElixir.SpecsCheck` at `88.14%`
  - `SymphonyElixir.Config` at `88.49%`
- Remaining phase-8 work is now watchlist-driven:
  - backfill real tests for those modules only
  - prefer meaningful operator/runtime scenarios over synthetic branch chasing
  - keep the hard gate green after each test wave
- Acceptance:
  - no core runtime change merges without green integration tests and coverage gate satisfaction
  - every phase-8 follow-up keeps `mix test` and `make coverage` green

## Implementation Sequence

- Phase 1: slim workflows, add minimal runtime profile, add GitHub adapter abstraction, add stage-aware budget types, add test scaffolding.
- Phase 2: harden publish/check/merge logic and restart-safe recovery, including lease/version semantics.
- Phase 3: strengthen verifier and acceptance enforcement, freeze harness schema, add startup contract validation.
- Phase 4: expand audit/policy ledger and dashboard reason codes.
- Phase 5: operationalize dogfood promotion, rollback, and canary flow.
- Phase 6: raise coverage gates to a sensible floor, backfill real tests for low-coverage modules, and use the watchlist to drive follow-up work.
- Phase 8 follow-up: keep the gate in place, then iteratively burn down the watchlist with real scenarios instead of synthetic coverage padding.

## Test Plan

- Unit:
  - publish idempotency
  - check-state classification
  - lease conflict and stale takeover rules
  - persisted stage resume semantics
  - verifier retry-to-implement loop
  - harness schema validation
  - policy-class routing
- Integration:
  - `Todo -> In Progress -> publish -> await_checks -> merge -> post_merge -> Done`
  - validation failure retries within run
  - verifier failure returns to `implement`
  - missing required checks blocks cleanly
  - restart resumes `await_checks`, `merge`, and `post_merge`
  - dogfood label gate ignores unlabeled issues
  - protected install overlap refuses dispatch
- Acceptance:
  - `events` repo completes an autonomous run with deterministic harness commands
  - `symphony` dogfood issue completes via stable runner without touching the live install
  - rollback to a previous promoted runner works after a bad dogfood merge

## Assumptions And Defaults

- GitHub remains the only supported PR/check provider for this phase.
- Manual promotion remains required even after autonomous merge.
- `Human Review` remains an operator override, not the normal happy path.
- Coverage is treated as a reliability requirement, not a nice-to-have.
