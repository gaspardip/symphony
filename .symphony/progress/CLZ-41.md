# CLZ-41: Add Telemetry events for agent turn lifecycle

## Goal
Emit `:telemetry` events at the start and stop of each agent turn so Symphony can track turn durations, token usage, and outcomes.

## Acceptance
- `:telemetry.execute` is called at start and stop of each agent turn
- Duration and token usage are measured
- Test file covers both plan and implement events
- `mix compile` and `mix test` pass

## Plan

1. **`elixir/lib/symphony_elixir/delivery_engine.ex` — `handle_plan/9` (line 561)**
   - Before the `provider.run_turn(...)` call at line 579, emit `[:symphony, :agent_turn, :start]` with metadata `%{stage: "plan", provider: provider_name, model: model, issue_identifier: issue.identifier}` using `Observability.emit/3`.
   - Capture `start_time = System.monotonic_time(:millisecond)` before `provider.run_turn`.
   - After `provider.run_turn` returns (line 593), compute `duration_ms = System.monotonic_time(:millisecond) - start_time`.
   - Extract `input_tokens` and `output_tokens` from the turn result's `:usage` map (when `{:ok, turn_data}` is returned, `turn_data.usage` has the tokens).
   - Determine `result` from the pattern match: `"ok"` when `{:ok, _}`, `"error"` otherwise.
   - Emit `[:symphony, :agent_turn, :stop]` with measurements `%{duration_ms: duration_ms, input_tokens: input_tokens, output_tokens: output_tokens}` and metadata `%{stage: "plan", provider: provider_name, model: model, issue_identifier: issue.identifier, result: result}`.

2. **`elixir/lib/symphony_elixir/delivery_engine.ex` — `handle_implement/9` (line 657)**
   - Same pattern inside the `true ->` branch (line 750) where `provider.run_turn` is called (line 769).
   - Before the `provider.run_turn` call, emit `[:symphony, :agent_turn, :start]` with metadata `%{stage: "implement", provider: provider_name, model: model, issue_identifier: issue.identifier}`.
   - Capture `start_time = System.monotonic_time(:millisecond)` before the call.
   - After `provider.run_turn` completes, compute duration and extract token usage.
   - Emit `[:symphony, :agent_turn, :stop]` with measurements `%{duration_ms: duration_ms, input_tokens: input_tokens, output_tokens: output_tokens}` and metadata `%{stage: "implement", provider: provider_name, model: model, issue_identifier: issue.identifier, result: result}`.
   - To keep the `with` chain clean, wrap the `provider.run_turn` call in a helper or capture the timing around it. The simplest approach: assign the turn result to a variable before the `with`, then pattern-match inside the `with`.

3. **`elixir/lib/symphony_elixir/delivery_engine.ex` — Add private helper `emit_agent_turn_start/4` and `emit_agent_turn_stop/6`**
   - `emit_agent_turn_start(stage, provider, model, issue)` — calls `Observability.emit([:symphony, :agent_turn, :start], %{count: 1}, %{stage: stage, provider: inspect(provider), model: model, issue_identifier: issue.identifier})`.
   - `emit_agent_turn_stop(stage, provider, model, issue, start_time, turn_result)` — computes duration, extracts tokens from the result tuple, determines result string, and calls `Observability.emit([:symphony, :agent_turn, :stop], %{duration_ms: ..., input_tokens: ..., output_tokens: ...}, %{stage: ..., provider: ..., model: ..., issue_identifier: ..., result: ...})`.
   - This avoids duplicating the telemetry logic between `handle_plan` and `handle_implement`.

4. **`elixir/lib/symphony_elixir/agent_provider/claude.ex` — `run_turn/4` (line 48)**
   - Capture `start_time = System.monotonic_time(:millisecond)` at the top of `run_turn`.
   - On success, include `duration_ms` in the returned `{:ok, %{result: ..., session_id: ..., usage: ..., duration_ms: duration_ms}}` map.
   - On error, include `duration_ms` in the error path as well (or just in the ok path since `delivery_engine` computes its own timing).
   - This makes duration available to callers at the provider level too.

5. **`elixir/lib/symphony_elixir/observability/metrics.ex` — `metrics/0` (line 14)**
   - Add metric definitions for the new agent turn events:
     - `counter("symphony.agent_turn.starts.total", event_name: [:symphony, :agent_turn, :start], measurement: :count, tags: [:stage, :provider, :model])`
     - `counter("symphony.agent_turn.stops.total", event_name: [:symphony, :agent_turn, :stop], measurement: :count, tags: [:stage, :provider, :model, :result])`
     - `distribution("symphony.agent_turn.duration", event_name: [:symphony, :agent_turn, :stop], measurement: :duration_ms, reporter_options: [buckets: [100, 500, 1_000, 5_000, 15_000, 60_000, 300_000]], tags: [:stage, :result])`
     - `sum("symphony.agent_turn.input_tokens.total", event_name: [:symphony, :agent_turn, :stop], measurement: :input_tokens, tags: [:stage, :model])`
     - `sum("symphony.agent_turn.output_tokens.total", event_name: [:symphony, :agent_turn, :stop], measurement: :output_tokens, tags: [:stage, :model])`

6. **`elixir/test/symphony_elixir/agent_telemetry_test.exs` — New test file**
   - Use `:telemetry.attach/4` in `setup` to capture events into the test process mailbox.
   - **Test "emits :start and :stop telemetry for plan turn"**: Call `handle_plan` (or invoke the delivery engine code path that triggers it) with a mock provider that returns `{:ok, %{usage: %{input_tokens: 100, output_tokens: 50}}}`. Assert that `[:symphony, :agent_turn, :start]` was received with `metadata.stage == "plan"`. Assert that `[:symphony, :agent_turn, :stop]` was received with `measurements.duration_ms >= 0`, `measurements.input_tokens == 100`, `measurements.output_tokens == 50`, and `metadata.result == "ok"`.
   - **Test "emits :start and :stop telemetry for implement turn"**: Same pattern but for implement stage. Assert `metadata.stage == "implement"`.
   - **Test "emits :stop with error result on failed turn"**: Mock provider returns `{:error, :timeout}`. Assert `:stop` event has `metadata.result == "error"` and `measurements.duration_ms >= 0`.
   - Since `handle_plan/9` and `handle_implement/9` are private, the tests should either:
     - Call the helper functions directly if we extract them as `@doc false` public test helpers, or
     - Test at the `Observability.emit` level by directly calling the new private helpers via test-exposed wrappers (following the existing `_for_test` pattern in the codebase).
   - Attach telemetry handlers in `setup`, detach in `on_exit`.

## Work Log
- Read the codebase and wrote the implementation plan.

## Evidence
- `elixir/lib/symphony_elixir/delivery_engine.ex`: `handle_plan/9` (line 561) calls `provider.run_turn` at line 579-592 and receives `turn_result`. `handle_implement/9` (line 657) calls `provider.run_turn` at line 769-783 inside a `with` chain. Both extract the provider from `opts` and the model from `Config.agent_model_for_stage`.
- `elixir/lib/symphony_elixir/agent_provider/claude.ex`: `run_turn/4` (line 48) returns `{:ok, %{result: exit_result, session_id: session.session_id, usage: stream_state.usage}}` on success; `{:error, {kind, reason}}` on failure. The `usage` map has `input_tokens` and `output_tokens` keys. No `duration_ms` is currently captured.
- `elixir/lib/symphony_elixir/observability.ex`: Provides `emit/3` which wraps `:telemetry.execute/3` with sanitization. Also has `with_stage/3` as a pattern for start/stop event pairs — our implementation follows this same pattern.
- `elixir/lib/symphony_elixir/observability/metrics.ex`: Defines Prometheus metric registrations. Existing patterns use `counter`, `distribution`, and `sum` with `event_name`, `measurement`, and `tags` options.
- `elixir/test/symphony_elixir/telemetry_smoke_test.exs`: Existing telemetry test uses `Observability.emit` directly to fire events and then checks Prometheus scrape output. Our test will use `:telemetry.attach` to capture events directly.
- `elixir/test/symphony_elixir/agent_provider_claude_test.exs`: Shows the existing `_for_test` pattern for exposing private functions for testing.
- `elixir/lib/symphony_elixir/agent_provider.ex`: Defines the `@callback run_turn/4` returning `{:ok, turn_result()} | {:error, term()}`.

## Next Step
Open `elixir/lib/symphony_elixir/delivery_engine.ex` and add the two private helper functions `emit_agent_turn_start/4` and `emit_agent_turn_stop/6` near the bottom of the module, then wire them into `handle_plan/9` around the `provider.run_turn` call.
