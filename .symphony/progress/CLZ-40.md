# CLZ-40: Add @moduledoc to AgentProvider behaviour module

## Goal
Expand the one-line `@moduledoc` in `SymphonyElixir.AgentProvider` to fully document the behaviour's callbacks, how to implement a new provider, and how provider resolution works.

## Acceptance
- Add @moduledoc to AgentProvider behaviour module The AgentProvider module at elixir/lib/symphony_elixir/agent_provider.ex has a one-line @moduledoc. Expand it to document: what the behaviour defines (start_session, run_turn, stop_session), how to add a new provider (implement the 3 callbacks), and how provider resolution works (resolve/1 reads config, resolve_for_stage/2 enables per-stage routing)

## Plan
1. **Edit `elixir/lib/symphony_elixir/agent_provider.ex`** — Replace the existing one-line `@moduledoc` (line 2-4) with an expanded version covering three sections:
   - **What the behaviour defines**: Describe the three callbacks (`start_session/2`, `run_turn/4`, `stop_session/1`), their purposes, arguments, and return types. Reference the existing `@type session` and `@type turn_result` typespecs.
   - **How to add a new provider**: Explain that a module must `@behaviour SymphonyElixir.AgentProvider` and implement all three callbacks. Mention the existing providers (`AgentProvider.Claude`, `AgentProvider.Codex`) as examples. Note that the new provider string key must be added to `resolve_module/1`.
   - **How provider resolution works**: Document `resolve/1` (reads `:provider` from opts or falls back to `Config.agent_provider()`, default `"codex"`) and `resolve_for_stage/2` (checks `Config.agent_provider_for_stage/1` for per-stage overrides, falls back to `resolve/1`).

No other files need modification — this is a docs-only change.

## Work Log
- Planning turn completed.

## Evidence
- Read `elixir/lib/symphony_elixir/agent_provider.ex` (48 lines): confirmed one-line `@moduledoc`, three `@callback`s, two public functions (`resolve/1`, `resolve_for_stage/2`), one private (`resolve_module/1`).
- Read `elixir/lib/symphony_elixir/config.ex` lines 880-895: confirmed `agent_provider/0` defaults to `"codex"`, `agent_provider_for_stage/1` returns `nil` or a provider string.
- Confirmed two existing provider implementations: `agent_provider/claude.ex`, `agent_provider/codex.ex`.

## Next Step
Edit the `@moduledoc` string in `elixir/lib/symphony_elixir/agent_provider.ex` (lines 2-4) with the expanded documentation described in step 1 of the plan.
