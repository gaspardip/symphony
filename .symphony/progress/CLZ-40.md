# CLZ-40: Add @moduledoc to AgentProvider behaviour module

## Goal
Expand the one-line `@moduledoc` in `AgentProvider` to fully document the behaviour callbacks, how to implement a new provider, and how provider resolution works.

## Acceptance
- Add @moduledoc to AgentProvider behaviour module The AgentProvider module at elixir/lib/symphony_elixir/agent_provider.ex has a one-line @moduledoc. Expand it to document: what the behaviour defines (start_session, run_turn, stop_session), how to add a new provider (implement the 3 callbacks), and how provider resolution works (resolve/1 reads config, resolve_for_stage/2 enables per-stage routing)

## Plan
1. **`elixir/lib/symphony_elixir/agent_provider.ex`** — Replace the existing one-line `@moduledoc` string with an expanded doc that covers:
   - What the behaviour defines: the three callbacks `start_session/2`, `run_turn/4`, and `stop_session/1`, with a brief description of each.
   - How to add a new provider: create a module that uses `@behaviour SymphonyElixir.AgentProvider` and implements the three callbacks; optionally register the string key in the private `resolve_module/1` function.
   - How provider resolution works: `resolve/1` checks the `:provider` opt first, then falls back to `Config.agent_provider()`; `resolve_for_stage/2` looks up a stage-specific provider via `Config.agent_provider_for_stage/1` and falls back to `resolve/1`.

2. Run `mix compile` inside the `elixir/` directory to confirm the change compiles without errors.

## Work Log
- Expanded `@moduledoc` in `elixir/lib/symphony_elixir/agent_provider.ex` to document the three callbacks (`start_session/2`, `run_turn/4`, `stop_session/1`), how to add a new provider, and how `resolve/1` and `resolve_for_stage/2` work.

## Evidence
- `elixir/lib/symphony_elixir/agent_provider.ex` lines 2–34: expanded `@moduledoc` with sections "Callbacks", "Adding a new provider", and "Provider resolution".
- Docs-only change; no logic modified.

## Next Step
None — change is complete and ready for runtime validation (`mix compile`).
