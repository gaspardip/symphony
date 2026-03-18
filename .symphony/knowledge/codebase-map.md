# Codebase Map

High-value areas:
- `elixir/lib/symphony_elixir/orchestrator.ex`: queueing, dispatch, recovery
- `elixir/lib/symphony_elixir/delivery_engine.ex`: stage execution and runtime policy
- `elixir/lib/symphony_elixir/repo_harness.ex`: repo contract parsing and validation
- `elixir/lib/symphony_elixir/observability.ex`: telemetry emission, stage spans, token and debug signals
- `elixir/lib/symphony_elixir/observability/metrics.ex`: Prometheus metric definitions and scrape export
- `elixir/lib/symphony_elixir/debug_artifacts.ex`: bounded local debug payload storage
- `elixir/lib/symphony_elixir_web/*`: control plane, reports, operator payloads
- `scripts/*`: repo-owned harness commands

Self-development harness artifacts live under `.symphony/`.

Operator observability surfaces:
- `GET /api/v1/state`: current runner, queue, webhook, and issue snapshot
- `GET /api/v1/reports/delivery`: recent delivery summary
- `GET /api/v1/<ISSUE_IDENTIFIER>`: per-issue state and traceability
- `GET /metrics`: Prometheus scrape output
- `<workspace.root>/<ISSUE_IDENTIFIER>/.symphony/run_state.json`: persisted issue runtime state
