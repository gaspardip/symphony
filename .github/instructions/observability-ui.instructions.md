---
applyTo: "elixir/lib/symphony_elixir/status_dashboard.ex,elixir/lib/symphony_elixir_web/{presenter,endpoint,router,observability_pubsub}.ex,elixir/lib/symphony_elixir_web/controllers/{observability_api_controller,static_asset_controller}.ex,elixir/lib/symphony_elixir_web/live/dashboard_live.ex"
---

Review these files as operator-facing control-plane surfaces.

- Flag payload drift. `Orchestrator.snapshot`, `Presenter`, the observability API, and `DashboardLive` share a de facto schema; renamed, removed, or retyped fields can break the dashboard and API even when compilation passes.
- Flag changes that hide runtime state. Paused, blocked, retrying, polling, required-check, and rate-limit signals must stay distinguishable to operators; avoid comments about visuals unless they affect that operational meaning.
- Ask for snapshot or endpoint coverage when rendering/output changes. Dashboard text layout is protected by `status_dashboard_snapshot_test.exs` and fixtures under `elixir/test/fixtures/status_dashboard_snapshots/`; API/presenter changes should keep the relevant HTTP or presenter tests in sync.
