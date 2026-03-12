# Symphony Self-Dogfood Execution Plan

## Summary

Use the Linear project [Symphony](https://linear.app/cylize/project/symphony-7262055276bc) as the single source of truth for Symphony developing itself.

Default self-host model:

- repo: `gaspardip/symphony`
- tracker: the Symphony Linear project
- handoff: assignee-first
- operating mode: `private_autopilot`
- eligibility: any Symphony-project issue assigned to Symphony and in an active state
- release safety: keep runner promotion/canary/rollback from [DOGFOOD_OPERATIONS.md](/Users/gaspar/src/symphony/docs/DOGFOOD_OPERATIONS.md)
- repo discipline: make [SELF_DEVELOPMENT_HARNESS_PLAN.md](/Users/gaspar/src/symphony/docs/SELF_DEVELOPMENT_HARNESS_PLAN.md) the mandatory self-host contract

## Implementation Order

### 1. Self-host queue and routing

- Remove `dogfood:symphony` as the issue gate for Symphony’s own project.
- Keep active states:
  - `Todo`
  - `In Progress`
  - `Rework`
  - `Merging`
- Keep waiting states:
  - `Human Review`
  - `Blocked`
- Keep terminal states:
  - `Done`
  - `Canceled`
  - `Duplicate`
- Keep `policy:*` labels for autonomy:
  - `policy:fully-autonomous`
  - `policy:review-required`
  - `policy:never-automerge`
- Add organizational labels:
  - `phase:1` … `phase:6`
  - `area:harness`
  - `area:dogfood`
  - `area:deploy`
  - `area:portfolio`
  - `area:review`
  - `provider:codex`
  - `provider:anthropic`
  - `proof:ui`
  - `proof:deploy`

### 2. Mandatory self-development harness

- Extend `.symphony/harness.yml` with `agent_harness`.
- Add runtime stage `initialize_harness` between `checkout` and `implement`.
- Require repo-tracked artifacts:
  - `.symphony/knowledge/product.md`
  - `.symphony/knowledge/architecture.md`
  - `.symphony/knowledge/codebase-map.md`
  - `.symphony/knowledge/delivery-loop.md`
  - `.symphony/knowledge/testing-and-ops.md`
  - `.symphony/progress/<issue>.md`
  - `.symphony/features/<feature>.yaml`
- Add `mix harness.check`.
- Publish gate must require:
  - current issue progress file exists and is updated
  - affected feature files are updated for code changes
  - required knowledge files exist and are structurally valid

### 3. Self-host execution model

- Default to `private_autopilot`.
- Allow Symphony on its own repo to:
  - open/update PRs
  - merge on green when policy allows
  - auto-post low-risk review replies when policy allows
  - auto-resolve threads only when policy and proof allow it
- Keep runtime-owned gates mandatory:
  - repo compatibility
  - initialize_harness
  - behavioral/UI proof
  - validate/verify
  - publish/await_checks/merge/post_merge

### 4. Observability

- Add issue/project reporting for:
  - current phase
  - current runtime stage
  - missing proof
  - next automatic action
  - block reason
- Track self-host metrics:
  - per-stage time
  - per-stage token usage
  - provider/model by stage
  - verifier retries
  - repair count
  - passive wait count
  - review comment count
  - merge/post-merge results

### 5. Backlog creation

Create Symphony issues in this order:

1. `phase:1 area:harness`
2. `phase:1 area:dogfood`
3. `phase:2 area:review`
4. `phase:3 area:deploy`
5. `phase:4 area:portfolio`
6. `phase:5` and `phase:6`

Each issue must include:

- `Acceptance Criteria`
- `Proof`
- `Policy impact`
- `Operator impact`
- `Out of scope`

## Assumptions

- The Symphony Linear project is the only tracker for Symphony self-work.
- Whole-project eligibility applies only to Symphony’s own project.
- Runner canary/promotion remains the release-safety mechanism.
- `events` remains the external proof-heavy baseline while Symphony self-hosting hardens.
