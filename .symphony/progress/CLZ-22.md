# CLZ-22: Add end-to-end observability to Symphony with self-hosted telemetry and bounded replay

## Goal
Add full runtime observability to Symphony with a self-hosted/local-first stack for metrics, traces, structured logs, and bounded debug replay artifacts.

## Acceptance
- Symphony emits a documented telemetry schema for intake, orchestration, stage lifecycle, token and budget pressure, proof, PR/review, deploy, and operator actions.
- The runtime exposes Prometheus-compatible metrics and OpenTelemetry traces with stable issue/stage/policy metadata.
- Structured logs correlate with trace/span identifiers.
- A local self-hosted observability stack is repo-owned and runnable with Docker Compose.
- Raw prompts, shell output, and file contents stay out of normal telemetry by default, while bounded local debug artifacts can be stored and referenced for failures or explicit debug mode.

## Plan
- Add an observability core module and runtime configuration for telemetry, traces, metrics, logs, and debug artifacts.
- Instrument the runtime seams that already own state transitions, budgets, proofs, tracker ingress, PR/review flow, and operator actions.
- Expose Prometheus metrics through the Phoenix endpoint and configure OpenTelemetry export plus trace-aware structured logs.
- Add repo-owned local observability ops assets and update the implementation docs.
- Validate with the harness contract, tests, lint, and smoke coverage, then prepare the PR.

## Work Log
- Created `CLZ-22` in the Symphony Linear project for tracker-backed self-host work.
- Created an isolated git worktree on `codex/clz-22-observability` to avoid the dirty `main` worktree.
- Reviewed `docs/OBSERVABILITY_IMPLEMENTATION_PLAN.md`, `.symphony/harness.yml`, runtime entrypoints, and current logging/state-transition code to identify integration seams.

## Evidence
- Linear issue: `CLZ-22`
- Worktree: `/Users/gaspar/src/symphony-clz-22`
- Branch: `codex/clz-22-observability`

## Next Step
Add the observability core modules and dependency wiring, then instrument stage and tracker/runtime lifecycle events before wiring the metrics endpoint and local Compose stack.
