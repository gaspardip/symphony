# CLZ-42: Add a health check endpoint at GET /api/v1/health

## Goal
Add a GET /api/v1/health endpoint to the Symphony HTTP server that returns 200 OK with JSON containing status, timestamp (ISO 8601), and version (git SHA).

## Acceptance
- GET /api/v1/health returns 200 with JSON body
- Response includes `status` ("ok"), `timestamp` (ISO 8601), and `version` (git SHA) fields
- Test file `test/symphony_elixir/http_health_test.exs` covers the happy path
- `mix compile` and `mix test` pass

## Plan
1. **Add route in `elixir/lib/symphony_elixir_web/router.ex`** — Add `get("/api/v1/health", ObservabilityApiController, :health)` in the third scope block (line 32–58). Must be placed *before* the wildcard `get("/api/v1/:issue_identifier", ...)` on line 55, because Phoenix matches routes top-to-bottom and `:issue_identifier` would swallow "health". Insert it after the delivery report routes (~line 46) and before the catch-all `match(:*, "/", ...)` on line 48. Also add `match(:*, "/api/v1/health", ObservabilityApiController, :method_not_allowed)` immediately after the GET route, consistent with the pattern used by every other endpoint in this router.

2. **Add `health/2` action in `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`** — New public function:
   ```elixir
   @spec health(Conn.t(), map()) :: Conn.t()
   def health(conn, _params) do
     json(conn, %{
       status: "ok",
       timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
       version: runner_version()
     })
   end
   ```
   Add a private helper `runner_version/0` that calls `SymphonyElixir.RunnerRuntime.runtime_version()` and falls back to `"unknown"` when nil. This avoids a null `version` field in the JSON response. Place the function near the top of the controller (after `state/2`) since it's a simple read-only endpoint. The health endpoint does NOT need the orchestrator or snapshot_timeout_ms — it's a pure status check.

3. **Create test file `elixir/test/symphony_elixir/http_health_test.exs`** — Follow the pattern from `http_router_phase6_backfill_test.exs`:
   - `use SymphonyElixir.TestSupport`
   - `import Phoenix.ConnTest`
   - `@endpoint SymphonyElixirWeb.Endpoint`
   - Reuse the `StaticOrchestrator` GenServer pattern (needed to start the endpoint, even though health doesn't use it)
   - `start_test_endpoint/1` helper with `server: false` and a static secret key
   - `empty_snapshot/0` helper for the orchestrator
   - Test: start endpoint → `get(build_conn(), "/api/v1/health")` → assert 200 → assert `"status" => "ok"` → assert `"timestamp"` is a non-empty string → assert `"version"` key is a string
   - Save/restore endpoint config in setup/on_exit to avoid test pollution

## Work Log
- Read the codebase and wrote the implementation plan.
- Re-read all source files and verified the plan is accurate and ready for implementation.
- Added `get("/api/v1/health", ...)` and `match(:*, "/api/v1/health", ...)` to `router.ex`, placed before the `get("/api/v1/:issue_identifier", ...)` catch-all.
- Added `health/2` action to `ObservabilityApiController` returning `%{status: "ok", timestamp: ..., version: RunnerRuntime.runtime_version()}`.
- Created `elixir/test/symphony_elixir/http_health_test.exs` with a happy-path test that starts the endpoint and asserts 200 with the expected JSON structure.

## Evidence
- **`elixir/lib/symphony_elixir_web/router.ex`** (59 lines): Phoenix router with three scope blocks. The third scope (lines 32–58) contains all API routes. Key ordering concern: `get("/api/v1/:issue_identifier", ...)` at line 55 is a wildcard that would match "health" if the health route isn't placed before it. The catch-all `match(:*, "/*path", ...)` at line 57 handles all unmatched routes.
- **`elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`** (149 lines): All JSON API actions live here. Uses `use Phoenix.Controller, formats: [:json]`. Private helpers: `orchestrator/0` (reads from Endpoint config), `snapshot_timeout_ms/0`, `error_response/4`. The `json/2` function is available from Phoenix.Controller for returning JSON responses.
- **`elixir/lib/symphony_elixir/runner_runtime.ex`** (lines 115–118, 264–276): `runtime_version/0` returns the current git SHA as a string or nil. Internally calls `current_version_sha/1` which runs `git rev-parse HEAD` in the checkout root. May return nil if not in a git repo.
- **`elixir/lib/symphony_elixir/http_server.ex`** (88 lines): Compatibility facade that starts the Phoenix endpoint (`SymphonyElixirWeb.Endpoint`). No routing logic here — routes are in `router.ex`. The ticket mentions this file but the actual route addition goes in the router.
- **`elixir/test/symphony_elixir/http_router_phase6_backfill_test.exs`** (155 lines): Reference test pattern. Uses `Phoenix.ConnTest`, a `StaticOrchestrator` GenServer stub (handles `:snapshot` and `:request_refresh` calls), `start_test_endpoint/1` (merges config with `server: false` and starts the endpoint as supervised), and `empty_snapshot/0`. Saves/restores endpoint config in setup block.
- **`elixir/test/support/test_support.exs`** (645 lines): `SymphonyElixir.TestSupport` macro module. Provides shared aliases, setup that creates temp directories, writes workflow files, stops the default HTTP server, and cleans up on exit. Exports `stop_default_http_server/0` which is called in setup.
- **`elixir/lib/symphony_elixir_web/endpoint.ex`** (33 lines): Standard Phoenix endpoint with Bandit adapter. Plugs: RequestId, Telemetry, Parsers (JSON via Jason), MethodOverride, Head, Session, then Router.

## Next Step
Implementation complete. Ready for runtime validation (`mix compile && mix test`).
