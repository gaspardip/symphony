# Symphony Model-Agnostic Cleanup Stage Plan

## Summary
Symphony should add a model-agnostic cleanup stage that copies the useful behavior of Claude Code's `/simplify` workflow without depending on a Claude-specific command or provider runtime.

This is a follow-on stage, not a replacement for review comment adjudication. The active runtime direction remains:

1. webhook-driven review intake
2. review comment adjudication with evidence, consensus, and thresholds
3. optional cleanup over accepted code changes

## Goal
Add a portable post-implementation cleanup stage that improves code quality, reuse, and efficiency while preserving behavior and respecting repo policy.

## Non-Goals
- do not make correctness decisions based on cleanup reviewers alone
- do not tie the workflow to Anthropic, OpenAI, or any single provider
- do not allow speculative semantic rewrites without proof
- do not replace final validation, proof gates, or review adjudication

## Position In The Runtime
The cleanup stage should run after implementation and targeted verification, and before final validation and PR update.

```text
implement
-> targeted verification
-> cleanup stage
-> full validation
-> PR update / publish
```

Cleanup findings should never bypass the normal validation and proof gates.

## Runtime Shape

### Provider-neutral reviewer roles
Symphony should define reviewer roles as runtime contracts rather than provider-specific prompts:

- `quality_reviewer`
- `reuse_reviewer`
- `efficiency_reviewer`

Possible later roles:

- `failure_handling_reviewer`
- `security_reviewer`

Each role should declare:

- allowed scope
- allowed finding types
- forbidden rewrite classes
- required output schema
- acceptable evidence sources

### Model adapters
Each reviewer role should execute through the existing provider abstraction layer:

- OpenAI-backed
- Anthropic-backed
- local/self-hosted model-backed
- future providers

The runtime should pick models by config and policy, not by embedding provider-specific logic in orchestration.

## Reviewer Contracts

### `quality_reviewer`
Focus:

- naming clarity
- control-flow simplification
- dead branches
- duplicated local logic
- readability regressions in changed files

Should not:

- redesign public APIs
- move behavior across subsystems without proof

### `reuse_reviewer`
Focus:

- missed use of existing helpers
- duplicated logic across touched modules
- obvious extraction opportunities limited to the changed surface
- consistency with existing repo patterns

Should not:

- perform broad refactors unrelated to the current diff
- introduce abstractions that increase indirection without measurable gain

### `efficiency_reviewer`
Focus:

- unnecessary repeated work
- avoidable allocations or repeated shell / git / provider calls
- obvious N+1 or repeated traversal patterns
- telemetry or logging paths that create unnecessary churn

Should not:

- invent micro-optimizations without evidence
- trade clarity for speculative performance wins

## Structured Output Schema
Each reviewer should return structured findings, not free-form prose. The minimum schema should include:

- `role`
- `finding_type`
- `severity`
- `confidence`
- `files`
- `symbols`
- `claim`
- `evidence`
- `risk_level`
- `suggested_change`
- `needs_validation`
- `patch_allowed`

The orchestrator should treat prose as supporting explanation only. Adjudication should run on structured claims.

## Adjudication Rules
Cleanup findings should be scored separately from review-comment truth adjudication.

Suggested acceptance rules:

- auto-apply only when:
  - `risk_level = low`
  - `confidence >= 0.80`
  - finding stays inside touched files or touched symbols
  - no public API change
  - targeted validation exists or can be run cheaply
- queue for manual or later review when:
  - confidence is moderate
  - benefit is real but cross-cutting
  - change would increase abstraction surface
- dismiss when:
  - claim is stylistic only
  - evidence is weak
  - change conflicts with existing repo conventions

## Consensus And Convergence
The cleanup stage can use multiple reviewer roles in parallel, but convergence should not be treated as truth by itself.

Use convergence only when:

- reviewers point at the same file or symbol
- reviewers describe the same failure mode or cleanup opportunity
- at least one reviewer provides concrete evidence from the diff or runtime behavior

Do not count convergence when:

- reviewers only agree that code is "complex"
- findings are vague or purely stylistic
- no concrete symbol, path, or invariant is identified

Recommended orchestrator behavior:

1. gather findings from all cleanup reviewers
2. dedupe by file, symbol, and claim type
3. merge only evidence-backed overlap
4. reject broad agreement without hard local evidence

## Safety Rails
- scope cleanup to touched files by default
- allow touched-symbol expansion only when the dependency chain is explicit
- forbid new production dependencies
- forbid large refactors during cleanup
- emit a separate cleanup commit when changes are material
- run targeted tests before applying non-trivial fixes
- run full validation after accepted cleanup changes

## Relationship To Review Adjudication
Cleanup is a finishing pass. It should not decide whether Copilot, a human reviewer, or another model is correct about a bug or regression.

The correct order is:

1. adjudicate review comments with evidence, thresholds, and multi-model consensus
2. apply correctness fixes
3. optionally run cleanup reviewers on the resulting diff
4. validate again

This keeps truth-finding separate from code polish.

## Telemetry And Learning
Symphony should record:

- which cleanup roles ran
- finding counts by role and disposition
- acceptance rate
- revert rate
- validation pass/fail after cleanup
- review churn before and after cleanup

Over time, Symphony can lower or raise role confidence thresholds by module based on:

- historical precision
- validation fallout
- revert frequency
- repeated false-positive patterns

## Rollout Plan

### Phase 1
- define reviewer role contracts
- define the structured finding schema
- add an orchestrator stage that can dispatch cleanup reviewers without applying fixes
- record findings in runtime state and telemetry

### Phase 2
- enable low-risk auto-apply for `quality_reviewer` and `reuse_reviewer`
- keep `efficiency_reviewer` verify-first unless evidence is explicit
- run targeted validation before patch acceptance

### Phase 3
- add historical precision tracking by role, module, and provider
- add adaptive thresholds
- optionally add `failure_handling_reviewer`

## Open Questions
- whether cleanup reviewers should run on every autonomous implement pass or only after review-driven fixes
- whether low-risk cleanup should be folded into the implementation commit or kept as a separate commit by policy
- whether a repo can opt out of `efficiency_reviewer` for readability-first code paths

## Recommended Default
Start with three provider-neutral roles:

- `quality_reviewer`
- `reuse_reviewer`
- `efficiency_reviewer`

Run them in parallel, treat them as advisory, and allow only low-risk accepted findings to auto-apply after targeted verification.
