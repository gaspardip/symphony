# Symphony PR Review Adjudication Plan

## Summary
Symphony should not treat PR review comments as binary truth signals.

Anyone can comment on a PR:

- humans
- GitHub Copilot
- repo bots
- external automation
- future AI reviewers

The runtime needs a review adjudication layer that filters noise, verifies claims, and decides whether feedback should be accepted, verified, deferred, replied to, or dismissed.

This plan defines a model-agnostic adjudication system for PR review comments that uses:

- source-aware trust baselines
- evidence-first verification
- multi-model consensus
- structured convergence checks
- explicit `defer` vs `dismiss` outcomes
- category-specific thresholds
- persistent learning from historical precision

## Implemented Slices
The runtime now includes the first routing and adjudication slices of this plan:

- source-aware review triage via `SymphonyElixir.ReviewAdjudicator`
- persisted `review_claims` state alongside drafted review threads
- a passive `review_verification` stage that collects cheap local proof before reopening `implement`
- a first local consensus layer plus evidence-based draft replies after review verification
- runner identity stamped into persisted `run_state`
- channel-aware GitHub webhook follow-up that skips workspaces owned by another runner channel or instance
- label-driven issue routing that keeps canary-targeted work off stable runners and keeps stable-targeted work off canary runners
- lease-backed ownership persisted into `run_state` so live dispatch leases, webhook follow-up, and runner routing can share the same ownership facts
- autonomous review follow-up that acquires a lease before reopening `review_verification` or `implement`, and skips same-channel work already owned by another orchestrator

The remaining phases below describe how to extend that foundation with stronger proof sources, independent consensus, stagnation detection, reply planning, and thread-resolution policy.

## Deployment Topology
The adjudication loop should not depend on whichever Symphony branch is currently under test.

The best operating model is:

- one stable webhook ingress for GitHub and tracker events
- one durable event log or inbox
- one scheduler that maps events to runs
- one or more isolated runner pools that execute issue work in per-issue workspaces
- explicit promotion of runner versions after dogfood validation

This avoids the unsafe pattern where a dogfood branch attempts to mutate the live process that is currently executing it.

### Control plane
The control plane should remain stable and own:

- webhook verification and normalization
- durable event persistence
- queueing and deduplication
- run registry and leases
- routing decisions
- operator visibility

### Runner plane
Runner instances should be versioned and disposable. Each runner should register:

- `instance_id`
- `runtime_version`
- `channel`
- `workspace_root`
- `logs_root`
- repo allowlist or routing scope
- capabilities

Runners should execute work only inside isolated per-issue workspaces and should never rewrite the checkout that is hosting the live control plane.

### Channels
Use explicit runner channels rather than binding webhooks directly to branches:

- `stable`
- `canary`
- `experimental`

Dogfood work for Symphony should route to `canary` runners by policy. Normal repo work should stay on `stable` unless explicitly opted into canary behavior.

### Routing policy
GitHub should send one webhook stream to the stable ingress. Internal routing should decide which runner pool handles the event based on:

- repo
- PR number
- labels
- issue metadata
- runtime feature flags
- current ownership lease
- target channel

Do not configure one GitHub webhook per branch. Keep GitHub configuration stable and move routing decisions inside Symphony.

### Promotion model
Dogfood changes should follow:

1. stable ingress receives webhook and records it
2. scheduler routes Symphony self-work to a canary runner pool
3. canary runner creates or resumes an isolated issue workspace
4. canary runner handles review adjudication and follow-up
5. merged changes pass post-merge verification
6. operator or promotion command upgrades the stable runner version

Merged dogfood PRs should not replace the live runtime automatically.

### Immediate rollout direction
For the current `CLZ-22` branch, implement the adjudication and webhook behavior in the active branch and merge it manually. Use the stable ingress plus isolated runner model as the target topology, but do not block the current branch on full control-plane extraction.

## Problem Statement
The current webhook-driven review loop can detect and surface PR comments, but it does not yet decide whether a comment is correct with enough rigor to safely automate the response.

That creates three risks:

1. false positives
   Symphony churns code to satisfy bad feedback.
2. false negatives
   Symphony dismisses real regressions because they are phrased poorly or come from a noisy source.
3. review thrash
   multiple AI or bot comments create overlapping noise that causes repeated re-entry into `implement` without real new evidence.

The goal is to turn review comments into structured claims that can be adjudicated with runtime evidence instead of opinion.

## Goals
- filter noisy review comments before they trigger code changes
- let fully autonomous runs address high-confidence valid feedback
- keep low-confidence or purely stylistic comments from causing unnecessary churn
- make decisions explainable to operators
- support comments from any source, not just Copilot
- learn which reviewers are precise in which areas over time

## Non-Goals
- do not assume a reviewer is correct because it is human
- do not assume a reviewer is incorrect because it is AI
- do not rely on pure majority vote between models
- do not require deterministic replay to judge all comments
- do not auto-resolve every thread immediately after posting a reply

## Runtime Position
The adjudication stage should run when a review webhook or explicit PR refresh surfaces new feedback.

```text
review webhook
-> normalize comment
-> classify source and claim type
-> cheap verification
-> consensus and convergence pass
-> disposition
-> optional implement follow-up
-> validation
-> draft or post reply
-> optional thread resolution
```

## Core Principle
Review comments are claims, not facts.

Symphony should convert each comment into a structured claim and then ask:

1. what is the reviewer asserting?
2. what kind of claim is it?
3. what evidence exists locally?
4. do independent reasoning passes converge on the same concrete claim?
5. is the claim strong enough to justify code changes?

## Review Sources

### Source classes
- `human`
- `first_party_bot`
- `ai_reviewer`
- `external_bot`
- `unknown`

### Example mappings
- GitHub user leaving line comments: `human`
- repository-owned workflow bot: `first_party_bot`
- GitHub Copilot review: `ai_reviewer`
- Dependabot or third-party app: `external_bot`
- unrecognized automation actor: `unknown`

### Source trust baseline
Each source starts with a prior trust band, not a final score.

Suggested defaults:

- `human`: `0.65`
- `first_party_bot`: `0.75`
- `ai_reviewer`: `0.50`
- `external_bot`: `0.45`
- `unknown`: `0.35`

These are not action thresholds. They are only priors before evidence and history are applied.

## Claim Taxonomy
Every comment should be normalized into one or more claim types:

- `critical_bug`
- `correctness_risk`
- `security_risk`
- `performance_risk`
- `failure_handling_risk`
- `maintainability`
- `style_or_nit`
- `policy_violation`
- `test_gap`
- `unclear`

If a comment mixes several concerns, split it into multiple claims and adjudicate them independently.

## Normalization
Each raw review comment should be transformed into a structured finding record:

- `review_comment_id`
- `thread_id`
- `pr_number`
- `source_class`
- `source_actor`
- `claim_type`
- `severity`
- `file`
- `line`
- `symbol`
- `raw_text`
- `normalized_claim`
- `requested_outcome`
- `related_diff_hunks`

Normalization should also extract:

- whether the comment targets changed lines
- whether it references real symbols or files
- whether it proposes a concrete failure mode
- whether it requests proof, code change, or explanation

## Scoring Model
The adjudication score should estimate veracity, not just relevance.

Suggested weighted score:

- `0.25` reproducibility
- `0.20` evidence quality
- `0.15` locality to changed code
- `0.15` source precision prior
- `0.15` independent consensus
- `0.10` historical precision in this repo/module

Total score range: `0.00` to `1.00`

### Reproducibility
How strongly can Symphony reproduce the concern?

Signals:

- failing focused test
- failing validation step
- static rule hit
- type or compiler error
- runtime trace anomaly
- explicit policy violation

Suggested scoring:

- deterministic reproduction: `1.00`
- strong indirect proof: `0.75`
- partial supporting evidence: `0.50`
- no reproduction: `0.00`

### Evidence quality
How concrete is the review comment itself?

Signals:

- names real file and symbol
- describes a concrete failure mode
- points at an invariant or policy breach
- explains why current behavior is wrong

Suggested scoring:

- precise failure mode and invariant: `1.00`
- concrete but incomplete: `0.70`
- vague risk statement: `0.35`
- style-only or hand-wavy: `0.10`

### Locality
How close is the claim to the actual diff?

Suggested scoring:

- directly on changed lines: `1.00`
- same changed symbol: `0.80`
- same file, unrelated hunk: `0.50`
- cross-file inference: `0.30`
- unrelated area: `0.00`

### Source precision prior
Use the source class baseline and later calibrate per actor.

### Independent consensus
Consensus should come from independent reasoning passes, not repeated paraphrases of the same prompt.

Suggested scoring:

- two independent passes agree on the same structured claim: `0.80`
- three agree: `1.00`
- mixed or partial agreement: `0.40`
- disagreement: `0.00`

### Historical precision
Track whether this reviewer, reviewer class, or reviewer-plus-claim-type has been right in the past.

Suggested inputs:

- accepted and validated comments
- dismissed comments later proven correct
- comments that caused revert churn
- module-specific precision

## Evidence Sources
Hard evidence Symphony can collect:

- focused tests
- full validation failures
- compiler or type errors
- static analysis and policy checks
- runtime traces
- metrics anomalies
- proof gate failures
- deploy or verifier failures
- config contract violations

Soft evidence:

- second-model agreement
- third-model agreement
- repeated independent comments on the same claim
- historical reviewer precision

Hard evidence should dominate final disposition. Soft evidence can upgrade confidence, but it cannot replace hard proof for autonomous correctness-changing code updates.

## Multi-Model Consensus
Consensus is useful, but it should increase confidence rather than create confidence from nothing.

### Requirements
- each pass must be independent
- prompts should differ by role, not just wording
- at least one pass should be evidence-first instead of comment-first
- models should come from different families when possible

### Recommended adjudication passes
- `claim_interpreter`
  Extracts the concrete claim from the comment.
- `evidence_reviewer`
  Looks at diff, tests, logs, and policy data without starting from the reviewer's conclusion.
- `counterexample_reviewer`
  Tries to falsify the claim or prove it is a false positive.

Optional later pass:

- `fix_planner`
  Proposes the narrowest safe change only after the claim is accepted.

### Consensus output
Each model pass should return:

- `claim_summary`
- `claim_type`
- `affected_scope`
- `evidence_for`
- `evidence_against`
- `confidence`
- `disposition_recommendation`

The orchestrator should compare the structured outputs, not the prose.

## Convergence
Convergence is valuable only when it is concrete and evidence-backed.

### Valid convergence
Count convergence when reviewers agree on:

- the same file or symbol
- the same failure mode
- the same invariant or policy breach
- the same narrow remediation direction

### Invalid convergence
Do not count convergence when reviewers only agree that:

- the code is "complex"
- the code "might be risky"
- the pattern "feels wrong"
- something "should maybe be refactored"

### Convergence score
Suggested approach:

- semantic overlap on file, symbol, and claim type
- overlap on failure mode or invariant
- overlap on evidence references

If the overlap is high but evidence is absent, mark the comment as `consensus_without_proof` and keep it in `needs_verification`, not `accept`.

## Disposition States
Each normalized claim should end in one of:

- `accepted`
- `needs_verification`
- `deferred`
- `dismissed`
- `replied_explained`
- `fixed_pending_validation`
- `fixed_validated`
- `resolved`

### Meaning
- `accepted`
  enough evidence exists to act
- `needs_verification`
  plausible claim, insufficient proof
- `deferred`
  real issue, but not appropriate for this PR or pass
- `dismissed`
  insufficient evidence or contradicted by stronger evidence
- `replied_explained`
  Symphony has explained why it did not act
- `fixed_pending_validation`
  patch exists but proof is not complete
- `fixed_validated`
  patch passed required validation
- `resolved`
  thread can be resolved under policy

## Threshold Policy
Suggested default thresholds by claim type:

### `critical_bug`
- `>= 0.85`: `accepted`
- `0.65 - 0.84`: `needs_verification`
- `< 0.65`: `dismissed`

### `security_risk`
- `>= 0.85`: `accepted`
- `0.65 - 0.84`: `needs_verification`
- `< 0.65`: `dismissed`

### `correctness_risk`
- `>= 0.80`: `accepted`
- `0.60 - 0.79`: `needs_verification`
- `< 0.60`: `dismissed`

### `failure_handling_risk`
- `>= 0.80`: `accepted`
- `0.60 - 0.79`: `needs_verification`
- `< 0.60`: `dismissed`

### `performance_risk`
- `>= 0.80`: `accepted` only with concrete evidence
- `0.60 - 0.79`: `needs_verification`
- `< 0.60`: `dismissed`

### `policy_violation`
- `>= 0.75`: `accepted`
- `0.55 - 0.74`: `needs_verification`
- `< 0.55`: `dismissed`

### `maintainability`
- `>= 0.75`: `deferred` or `accepted` if low-cost
- `0.50 - 0.74`: `deferred`
- `< 0.50`: `dismissed`

### `style_or_nit`
- default: `deferred` or `dismissed`
- never auto-trigger implementation by itself

## Hard Rules
Regardless of score:

- a `style_or_nit` claim cannot reopen implementation by itself
- a claim with no concrete file or symbol cannot be auto-accepted
- a claim contradicted by deterministic local evidence should be dismissed
- a claim outside touched scope should need stronger evidence than one on changed lines
- no single AI reviewer comment should force code changes without hard proof or corroboration
- no soft-consensus-only claim should be auto-fixed

## Reviewer Precision Tracking
The system should keep rolling precision data for:

- actor
- source class
- claim type
- repo
- module or directory

Metrics to track:

- accepted comments that validated successfully
- accepted comments that caused revert churn
- dismissed comments later proven true
- verification requests that turned into fixes
- repeated duplicate comments

Use this to adjust source priors over time.

## Stagnation Detection
Borrow the useful part of Ouroboros: repeated overlap without new evidence should stop the loop.

Mark feedback as `stagnant` when:

- the same claim reappears across pushes
- overlap exceeds a configured threshold
- no new failing proof or new evidence appears

Suggested default:

- overlap over `0.70` across two or more cycles with no new evidence

When stagnant:

- do not reopen implementation automatically
- reply with the current proof summary
- ask for a stronger reproducer or specific failure mode if policy allows posting replies

## Noise Filtering
Before spending model budget, discard or down-rank:

- duplicate comments on the same file, symbol, and claim type
- low-content comments with no concrete claim
- comments from actors already marked low precision in this module
- comments on unchanged code with no supporting evidence
- stylistic disagreements that conflict with repo conventions

Examples:

- "This could be cleaner" with no target: discard
- "This should use helper X" on a changed line: keep as `maintainability`
- "metrics_path config is ignored by router" with code path reference: keep as `correctness_risk`

## Runtime Components

### `ReviewNormalizer`
Responsibilities:

- parse raw PR review payloads
- split mixed comments into claims
- map sources into source classes
- extract file, line, and symbol scope

### `ReviewEvidenceCollector`
Responsibilities:

- run cheap targeted verification
- collect local code, test, trace, and policy evidence
- attach reproducibility signals

### `ReviewConsensusEngine`
Responsibilities:

- run independent reasoning passes
- compare structured outputs
- compute consensus and convergence

### `ReviewAdjudicator`
Responsibilities:

- compute veracity score
- apply claim-type thresholds
- assign disposition
- decide whether to reopen implementation

### `ReviewReplyPlanner`
Responsibilities:

- draft replies for accepted, deferred, and dismissed comments
- explain evidence briefly
- avoid overclaiming certainty

### `ThreadResolutionPolicy`
Responsibilities:

- decide whether a thread can be resolved
- require validated fixes for auto-resolution
- respect repo policy and operating mode

## Suggested Runtime Flow

### Step 1: Intake
- receive webhook
- dedupe comment payload
- persist normalized claim records

### Step 2: Cheap verification
- run comment-local checks first
- inspect changed files and symbols
- run focused tests or static checks when available

### Step 3: Consensus
- dispatch `claim_interpreter`
- dispatch `evidence_reviewer`
- dispatch `counterexample_reviewer`

### Step 4: Adjudication
- compute score
- classify disposition
- determine whether implementation should resume

### Step 5: Action
- `accepted` -> reopen `implement`
- `needs_verification` -> queue a focused verification step
- `deferred` -> draft explanation or backlog note
- `dismissed` -> draft explanation with proof summary

### Step 6: Validate and reply
- if code changed, validate
- draft or post response
- resolve thread only when policy and proof allow it

## Reply Policy
Replies should be evidence-oriented and short.

### For accepted claims
- acknowledge the issue
- summarize the fix
- mention validation result

### For `needs_verification`
- say the claim is plausible
- mention what proof is missing
- note the queued verification step

### For dismissed claims
- explain the strongest contradictory evidence
- avoid saying the reviewer is wrong in absolute terms
- invite a more specific reproducer when appropriate

## Telemetry
Record:

- comment intake count
- normalized claim count
- source-class distribution
- claim-type distribution
- disposition counts
- verification pass rate
- consensus rate
- convergence-with-proof rate
- convergence-without-proof rate
- false-positive rate by reviewer
- revert churn caused by accepted comments
- time from comment to disposition

These metrics should feed the observability stack and operator dashboards.

## Data Model Additions
Suggested persisted fields on review claims:

- `source_class`
- `claim_type`
- `veracity_score`
- `reproducibility_score`
- `consensus_score`
- `historical_precision_score`
- `disposition`
- `stagnation_state`
- `evidence_refs`
- `reply_status`
- `resolution_status`

## Policy Controls
Repos or operating modes should be able to configure:

- whether AI comments can auto-reopen implementation
- minimum threshold for auto-fix
- whether dismissed comments can be auto-replied to
- whether auto-resolution is allowed
- whether external bots are ignored by default
- whether maintainability comments can trigger cleanup follow-up

Suggested default for Symphony self-host:

- AI comments may reopen implementation only with hard proof or evidence-backed consensus
- low-risk dismissed comments may receive auto-drafted replies
- auto-resolution requires validated fix or strong contradictory evidence plus policy allowlist

## Rollout Plan

### Phase 1: Claim normalization and scoring
- add normalization
- add source classes and claim taxonomy
- add cheap verification
- persist adjudication records
- no auto-fix yet

### Phase 2: Consensus and convergence
- add independent review passes
- add convergence scoring
- add stagnation detection
- allow `accepted` comments to reopen implementation in fully autonomous mode

### Phase 3: Reply and resolution automation
- add reply planner
- allow policy-controlled auto-post for low-risk cases
- allow policy-controlled auto-resolution after validated fixes

### Phase 4: Historical learning
- track reviewer precision and drift
- calibrate thresholds by module and source class
- tune noise filters from observed false-positive rates

## Open Questions
- whether to use two or three consensus passes by default
- whether maintainability comments should feed the later cleanup stage automatically
- how much model budget to spend on low-severity comments during heavy PR traffic
- whether external bots should be ignored unless repo-allowlisted

## Recommended Default
Use a triage layer with three primary outcomes:

- `accepted`
- `needs_verification`
- `dismissed`

Treat review comments as claims, require evidence before autonomous code changes, use multi-model consensus only to upgrade confidence, and use convergence only when it is concrete and evidence-backed.
