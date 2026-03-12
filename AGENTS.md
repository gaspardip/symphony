# Symphony Agent Index

This file is intentionally short. It points agents to the durable repo map and self-development contract instead of duplicating them in the repository root.

## Start Here

- Self-host contract: [`.symphony/harness.yml`](/Users/gaspar/src/symphony/.symphony/harness.yml)
- Repo map: [`.symphony/knowledge/codebase-map.md`](/Users/gaspar/src/symphony/.symphony/knowledge/codebase-map.md)
- Harness guide: [`docs/AGENT_HARNESS.md`](/Users/gaspar/src/symphony/docs/AGENT_HARNESS.md)
- Self-dogfood plan: [`docs/SYMPHONY_SELF_DOGFOOD_EXECUTION_PLAN.md`](/Users/gaspar/src/symphony/docs/SYMPHONY_SELF_DOGFOOD_EXECUTION_PLAN.md)

## Durable Knowledge

All stable repo facts live under [`.symphony/knowledge/`](/Users/gaspar/src/symphony/.symphony/knowledge):

- [`product.md`](/Users/gaspar/src/symphony/.symphony/knowledge/product.md)
- [`architecture.md`](/Users/gaspar/src/symphony/.symphony/knowledge/architecture.md)
- [`codebase-map.md`](/Users/gaspar/src/symphony/.symphony/knowledge/codebase-map.md)
- [`delivery-loop.md`](/Users/gaspar/src/symphony/.symphony/knowledge/delivery-loop.md)
- [`testing-and-ops.md`](/Users/gaspar/src/symphony/.symphony/knowledge/testing-and-ops.md)

Read only the files needed for the current task.

## Self-Development Artifacts

- Per-issue progress: [`.symphony/progress/`](/Users/gaspar/src/symphony/.symphony/progress)
- Feature definitions: [`.symphony/features/`](/Users/gaspar/src/symphony/.symphony/features)

If you change code during Symphony self-host work:

- update the current issue progress file
- update affected feature YAML files when the change touches their source paths
- keep evidence and next steps current

## Runtime Contract

Use repo-owned commands from the harness. Do not invent alternatives when the harness already declares the source of truth:

- preflight
- validation
- smoke
- post-merge
- artifacts

For Symphony self-host runs, `mix harness.check` is part of the validation gate.

## Root Rule

Keep this file as an index only. Put detailed guidance in:

- [`.symphony/harness.yml`](/Users/gaspar/src/symphony/.symphony/harness.yml)
- [`.symphony/knowledge/`](/Users/gaspar/src/symphony/.symphony/knowledge)
- [`docs/AGENT_HARNESS.md`](/Users/gaspar/src/symphony/docs/AGENT_HARNESS.md)
