# CLZ-39: Add provider config example comments to WORKFLOW.md

## Goal
Add YAML comments at the end of the `codex:` section in `elixir/WORKFLOW.md` documenting the new provider-agnostic agent config options supported by the `agent:` section.

## Acceptance
- Add provider config example comments to WORKFLOW.md Add YAML comments at the end of the codex: section in elixir/WORKFLOW.md documenting the new provider-agnostic agent config options.

## Plan
1. Modify `elixir/WORKFLOW.md`: append YAML comment block at the end of the `codex:` section (after line 60, before the closing `---`). The comments should document the new provider-agnostic `agent:` section options that were introduced alongside the legacy `codex:` top-level section:
   - `agent.provider`: selects the provider (`codex` default, or `claude`)
   - `agent.model`: model override (e.g., `claude-sonnet-4-6` for the Claude provider)
   - `agent.providers`: per-stage provider routing (map of stage name to provider string)
   - `agent.reasoning.stages`: per-stage reasoning overrides (implement, verify, verifier)
   - `agent.reasoning.providers`: per-provider reasoning_map overrides
   - `agent.turn_timeout_ms`, `agent.read_timeout_ms`, `agent.stall_timeout_ms`: timeout tuning
   - `agent.codex.command`: codex-specific command (nested under `agent:` as alternative to legacy `codex:` top-level)
   - `agent.codex.runtime_profile`: codex-specific runtime profile (codex_home, inherit_env, env_allowlist)

   The comments should be valid YAML block comments (lines starting with `#`) placed after the last line of the `codex:` section (line 60, `    type: dangerFullAccess`) and before the closing `---`. They should show example usage of the new `agent:` section.

## Work Log
- Planning turn completed.

## Evidence
- Plan written based on analysis of `elixir/WORKFLOW.md` (current `codex:` section at lines 49-60), `elixir/lib/symphony_elixir/config.ex` (agent section schema at lines 199-249 and extraction logic at lines 1710-1814), and `elixir/lib/symphony_elixir/agent_provider.ex` (provider resolution logic).

## Next Step
Edit `elixir/WORKFLOW.md` to append YAML comment examples after line 60 (`    type: dangerFullAccess`) and before the closing `---`, documenting the `agent:` section's provider-agnostic config options.
