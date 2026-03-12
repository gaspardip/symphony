# Agent Harness

Symphony self-host runs use a repo-tracked `agent_harness` contract in `.symphony/harness.yml`.

The goals are:
- keep durable repo facts in version control
- require per-issue progress artifacts
- require feature-level updates when code changes
- make self-hosting fail fast before publish if the repo state is structurally incomplete

## Required directories

- `.symphony/knowledge/`
- `.symphony/progress/`
- `.symphony/features/`

## Required knowledge files

- `product.md`
- `architecture.md`
- `codebase-map.md`
- `delivery-loop.md`
- `testing-and-ops.md`

## Per-issue progress contract

Progress files live at `.symphony/progress/<issue-identifier>.md` and must include:

- `Goal`
- `Acceptance`
- `Plan`
- `Work Log`
- `Evidence`
- `Next Step`

## Feature contract

Feature files live at `.symphony/features/*.yaml` and must include:

- `id`
- `title`
- `status`
- `summary`
- `source_paths`
- `acceptance_signals`
- `dependencies`
- `last_updated_by_issue`

## Validation

Run:

```bash
cd elixir
mise exec -- mix harness.check
```

This is also part of Symphony’s self-host validation path.
