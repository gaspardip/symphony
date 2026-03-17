# Symphony Observability Runbook

## Goal

Give operators and agents one repo-owned place to inspect Symphony telemetry end to end during dogfood runs.

Use this runbook together with:

- [`.symphony/harness.yml`](/Users/gaspar/src/symphony/.symphony/harness.yml)
- [`docs/LOCAL_DOGFOOD_TOPOLOGY.md`](/Users/gaspar/src/symphony/docs/LOCAL_DOGFOOD_TOPOLOGY.md)
- [`docs/OBSERVABILITY_IMPLEMENTATION_PLAN.md`](/Users/gaspar/src/symphony/docs/OBSERVABILITY_IMPLEMENTATION_PLAN.md)

## Primary Surfaces

### Dashboard and API

- Dashboard: `GET /`
- State snapshot: `GET /api/v1/state`
- Delivery report: `GET /api/v1/reports/delivery`
- Issue detail: `GET /api/v1/<ISSUE_IDENTIFIER>`
- Metrics: `GET /metrics` or the configured `observability.metrics_path`

These routes are defined in:

- [`elixir/lib/symphony_elixir_web/router.ex`](/Users/gaspar/src/symphony/elixir/lib/symphony_elixir_web/router.ex)
- [`elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`](/Users/gaspar/src/symphony/elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex)
- [`elixir/lib/symphony_elixir_web/presenter.ex`](/Users/gaspar/src/symphony/elixir/lib/symphony_elixir_web/presenter.ex)

### Runtime State

Per-issue persisted state lives under the configured workspace root:

```text
<workspace.root>/<ISSUE_IDENTIFIER>/.symphony/run_state.json
```

This is the fastest place to inspect:

- current stage
- stop reason
- next human action
- review claims and thread state
- CI failure context
- last decision / resume context

The persistence layer lives in:

- [`elixir/lib/symphony_elixir/run_state_store.ex`](/Users/gaspar/src/symphony/elixir/lib/symphony_elixir/run_state_store.ex)

### Metrics and Traces

Telemetry helpers and metrics definitions live in:

- [`elixir/lib/symphony_elixir/observability.ex`](/Users/gaspar/src/symphony/elixir/lib/symphony_elixir/observability.ex)
- [`elixir/lib/symphony_elixir/observability/metrics.ex`](/Users/gaspar/src/symphony/elixir/lib/symphony_elixir/observability/metrics.ex)
- [`elixir/lib/symphony_elixir/observability/supervisor.ex`](/Users/gaspar/src/symphony/elixir/lib/symphony_elixir/observability/supervisor.ex)

Key emitted surfaces:

- stage start/stop counters and duration
- token counters and totals
- webhook intake counters
- repair/runtime-stop counters
- debug artifact counters

### Logs and Debug Artifacts

Structured logs are configured through workflow observability settings.

Debug artifacts are bounded local captures stored under:

- `observability.debug_artifacts.root` from workflow config
- default: `log/artifacts/` relative to the repo or active log root

Artifact storage lives in:

- [`elixir/lib/symphony_elixir/debug_artifacts.ex`](/Users/gaspar/src/symphony/elixir/lib/symphony_elixir/debug_artifacts.ex)

## Local Dogfood Checklist

1. Start the local topology from [`docs/LOCAL_DOGFOOD_TOPOLOGY.md`](/Users/gaspar/src/symphony/docs/LOCAL_DOGFOOD_TOPOLOGY.md).
2. Confirm `GET /api/v1/state` returns a healthy runner payload.
3. Confirm `GET /metrics` scrapes successfully.
4. Confirm the target issue workspace has `.symphony/run_state.json`.
5. If a run fails, inspect:
   - `run_state.json`
   - `/api/v1/<ISSUE_IDENTIFIER>`
   - `/api/v1/reports/delivery`
   - `log/` and `log/artifacts/`

## Repo-Owned Proof

Telemetry smoke is part of the repo-owned smoke contract through:

- [`elixir/test/symphony_elixir/telemetry_smoke_test.exs`](/Users/gaspar/src/symphony/elixir/test/symphony_elixir/telemetry_smoke_test.exs)
- [`scripts/symphony-smoke.sh`](/Users/gaspar/src/symphony/scripts/symphony-smoke.sh)

That smoke proves:

- telemetry events emit into Prometheus scrape output
- `/api/v1/state` remains a usable operator surface
- `/api/v1/reports/delivery` remains reachable
- bounded debug artifacts remain storable and discoverable
