# Symphony Self-Development Harness v1

## Summary

- Extend `.symphony/harness.yml` into Symphony's single repo contract for long-running autonomous development.
- Add a runtime-owned `initialize_harness` stage before `implement`.
- Roll out the new harness for Symphony dogfood runs first, gated by `dogfood:symphony`.
- Store durable agent artifacts in the repo under `.symphony/`: knowledge docs, per-issue progress files, and structured feature state.
- Warn on first harness failure and gate publish on repeated failure or missing required artifacts.

## Key Changes

- Add `agent_harness` to `.symphony/harness.yml` with:
  - `scope: dogfood_only`
  - `initializer.enabled: true`
  - `initializer.max_turns`
  - `initializer.refresh`
  - `knowledge.root` and required files
  - `progress.root` with per-issue file pattern
  - `features.root` and format
  - `publish_gate` requirements for progress and feature updates on code changes
- Add a new runtime stage `initialize_harness` between `checkout` and `implement`.
- Add a structured tool `report_harness_init_result` for initializer turns.
- Extend `RunStateStore` with `last_harness_init`, `last_harness_check`, `harness_status`, and `harness_attempts`.
- Extend `RepoHarness` validation to parse and enforce `agent_harness`.
- Add a deterministic harness checker plus `mix harness.check`.
- Update `scripts/symphony-validate.sh` to run the harness check as part of validation.
- Add repo-tracked artifacts:
  - `.symphony/knowledge/product.md`
  - `.symphony/knowledge/architecture.md`
  - `.symphony/knowledge/codebase-map.md`
  - `.symphony/knowledge/delivery-loop.md`
  - `.symphony/knowledge/testing-and-ops.md`
  - `.symphony/progress/<issue-identifier>.md`
  - `.symphony/features/<feature-slug>.yaml`
- Require normal implementation turns to read the knowledge docs, update the issue progress file, and update affected feature YAMLs.
- Add a publish gate that checks:
  - required knowledge files exist
  - current issue progress file exists and is well-formed
  - code changes require a matching progress update
  - code changes require at least one related feature YAML update
  - changed feature YAMLs are valid and reference the current issue identifier
- Add dashboard/API/ledger support for initializer and harness health status.
- Add `docs/AGENT_HARNESS.md` and link it from the existing READMEs.

## Artifact Contracts

- Knowledge docs are short agent-facing summaries that point to canonical sources like `SPEC.md` and `docs/*`.
- Per-issue progress files are Markdown with sections:
  - `Goal`
  - `Acceptance`
  - `Plan`
  - `Work Log`
  - `Evidence`
  - `Next Step`
- Feature files are YAML with:
  - `id`
  - `title`
  - `status`
  - `summary`
  - `source_paths`
  - `acceptance_signals`
  - `dependencies`
  - `last_updated_by_issue`

## Test Plan

- Unit tests for `RepoHarness` `agent_harness` parsing and validation.
- Unit tests for progress-file structure validation.
- Unit tests for feature-YAML validation.
- Unit tests for publish-gate freshness rules.
- Delivery tests for `checkout -> initialize_harness -> implement`.
- Recovery tests for restart during `initialize_harness`.
- Publish-gate tests for:
  - missing progress file
  - malformed progress file
  - missing feature update on code change
  - malformed feature YAML
  - successful retry after fixing harness artifacts
  - repeated failure blocking the run
- Routing tests proving only dogfood Symphony runs enforce the new harness in v1.
- Dashboard/API tests for initializer and harness health fields.
- Repo acceptance tests proving Symphony's own `.symphony/` artifacts pass `mix harness.check`.

## Assumptions

- v1 enforces structure and freshness rules, not deep semantic correctness of docs.
- The per-issue progress file is the primary execution-plan artifact; no separate plans contract is added in v1.
- Non-dogfood repos are unchanged in v1 unless a later rollout explicitly opts them in.
