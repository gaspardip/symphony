# Codebase Map

High-value areas:
- `elixir/lib/symphony_elixir/orchestrator.ex`: queueing, dispatch, recovery
- `elixir/lib/symphony_elixir/delivery_engine.ex`: stage execution and runtime policy
- `elixir/lib/symphony_elixir/repo_harness.ex`: repo contract parsing and validation
- `elixir/lib/symphony_elixir_web/*`: control plane, reports, operator payloads
- `scripts/*`: repo-owned harness commands

Self-development harness artifacts live under `.symphony/`.

