## Goal
Add structured, stage-aware lifecycle logging around delivery-engine agent turns so plan and implement runs emit consistent provider, model, duration, token, and result metadata.

## Acceptance
- Add structured logging for agent turn lifecycle in delivery engine Convert unstructured Logger.info calls in handle_plan and handle_implement to structured log events with metadata (stage, provider, model, issue, duration_ms, tokens, result). Add timing around provider.run_turn calls. Add test with capture_log.

## Plan
1. `elixir/lib/symphony_elixir/delivery_engine.ex` in `handle_plan/9` and `do_plan_turn/8`: replace the current interpolated `Logger.info` messages for the plan path with structured lifecycle logs, keeping the existing plan-skip and plan-complete behavior intact while capturing the selected provider, the resolved plan model, the issue identifier, and whether the plan turn actually completed.
2. `elixir/lib/symphony_elixir/delivery_engine.ex` in a new private helper near the turn-result utilities, such as `run_logged_agent_turn/6` plus small normalization helpers: wrap `provider.run_turn/4` with monotonic timing, compute `duration_ms`, normalize the provider module into a stable log value, and normalize `tokens` from the provider response into a consistent map that can handle providers like `SymphonyElixir.Codex.AppServer` which currently return no `usage` payload.
3. `elixir/lib/symphony_elixir/delivery_engine.ex` in `handle_implement/9`: route the existing `provider.run_turn/4` call through the new timed logging helper, preserve the current `with` flow and runtime-error handling, and emit a structured implement lifecycle event whose `result` reflects the provider outcome and the fetched `TurnResult` state instead of the current unstructured completion log.
4. `elixir/test/symphony_elixir/delivery_engine_phase6_test.exs` by adding a new `capture_log` regression test and, if needed, a small fake Codex binary helper or helper variant: start the run state directly in `"plan"` and `"implement"` so checkout is bypassed, drive one successful turn through the default Codex provider path, and assert the captured lifecycle log includes the structured event name and the expected `stage`, `provider`, `model`, `result`, and token-related content.
5. `elixir/test/symphony_elixir/delivery_engine_phase6_test.exs` in the existing workspace helpers such as `stage_workspace!/1` or `fake_codex_binary!/1`: extend the fake app-server script only as far as needed to produce deterministic `report_agent_turn_result` and turn-complete output for the new logging assertions without changing unrelated stage coverage.

## Work Log
- Read the codebase and wrote the implementation plan.

## Evidence
- `elixir/lib/symphony_elixir/delivery_engine.ex`: `handle_plan/9` skips when a progress file already exists, `do_plan_turn/8` calls `provider.run_turn/4` and only logs `plan_completed` as plain text, and `handle_implement/9` runs `provider.run_turn/4` inside a large `with` before fetching a normalized `TurnResult`.
- `elixir/lib/symphony_elixir/delivery_engine.ex`: `fetch_turn_result/1`, `clear_turn_result/1`, and `maybe_capture_turn_runtime_error/2` already centralize turn-result and runtime-error state, so a shared logging helper can sit close to those functions without changing stage logic.
- `elixir/test/symphony_elixir/delivery_engine_phase6_test.exs`: the phase-6 test module already imports `capture_log`, has `stage_workspace!/1` and `git_stage_workspace!/1` helpers, and is the natural place for a delivery-engine logging regression test.
- `elixir/test/symphony_elixir/delivery_engine_phase3_test.exs`: `fake_codex_binary!/1` shows the repo already simulates Codex app-server turns by printing `report_agent_turn_result` tool calls and `turn/completed`, which is the safest pattern to reuse for plan and implement logging coverage.
- `elixir/lib/symphony_elixir/agent_provider.ex`: the provider behaviour expects `run_turn/4` to return `result`, `session_id`, and `usage`, which is the contract the delivery-engine logging helper should normalize.
- `elixir/lib/symphony_elixir/agent_provider/codex.ex`: the default provider for delivery-engine stages is just a thin wrapper around `SymphonyElixir.Codex.AppServer`, so delivery-engine logging must not assume provider-specific internals.
- `elixir/lib/symphony_elixir/codex/app_server.ex`: `run_turn/4` returns `result`, `session_id`, `thread_id`, and `turn_id` but no `usage`, which means the new `tokens` metadata needs a nil-safe or zero-safe normalization path for Codex app-server turns.
- `elixir/lib/symphony_elixir/agent_provider/claude.ex`: `run_turn/4` already returns a `usage` map with `input_tokens` and `output_tokens`, so the new delivery-engine helper should preserve those values instead of recomputing them later.
- `elixir/lib/symphony_elixir/agent_provider/codex_cli.ex`: the Codex CLI provider also returns `usage`, confirming the helper should normalize multiple provider result shapes rather than special-casing only one implementation.
- `elixir/lib/symphony_elixir/turn_result.ex`: the normalized `TurnResult` contains `summary`, `needs_another_turn`, `blocked`, and `blocker_type`, which gives the implement log path a repo-native source for result metadata after `fetch_turn_result/1`.
- `elixir/lib/symphony_elixir/config.ex`: `agent_provider_for_stage/1` and `agent_model_for_stage/1` are the existing sources of truth for stage-specific provider and model selection, so the structured logs should use the same resolution path.
- `elixir/lib/symphony_elixir/observability.ex`: issue metadata is already sanitized into scalar logger metadata where possible, which is a useful pattern when deciding how much issue context to attach to the new lifecycle events.
- `elixir/test/support/test_support.exs`: test support already wires temporary workflow files and imports `capture_log`, but it does not expose an `agent.provider` workflow override, so the test plan should stay on the default Codex provider path or add only minimal repo-native scaffolding.
- `.symphony/progress/CLZ-49.md`: the existing progress file was a placeholder and did not reflect the current code paths, so it needed a real implementation plan based on the files above.

## Next Step
Open `elixir/lib/symphony_elixir/delivery_engine.ex`, add a private helper that wraps `provider.run_turn/4` with timing and metadata normalization, and then switch `do_plan_turn/8` to call that helper for the `"plan"` stage before updating `handle_implement/9`.
