# CLZ-43: Add @moduledoc to Codex AppServer module

## Goal
Add @moduledoc to Codex AppServer module

## Acceptance
- Add @moduledoc to Codex AppServer module The Codex.AppServer module at elixir/lib/symphony_elixir/codex/app_server.ex has a one-line @moduledoc. Expand it to document: what the module does (JSON-RPC 2.0 client over stdio for Codex app-server), the session lifecycle (start_session, run_turn, stop_session), how approval policies and sandbox policies work, and how dynamic tools are registered. Docs-o

## Plan
- Read `SymphonyElixir.Codex.AppServer` and adjacent config/tool modules to match
  the module doc to the actual JSON-RPC lifecycle and policy handling.
- Expand the `@moduledoc` to cover the stdio client role, session lifecycle,
  approval and sandbox policy behavior, and dynamic tool registration.
- Hand off the docs-only diff for runtime-owned validation.

## Work Log
- Expanded `@moduledoc` in `elixir/lib/symphony_elixir/codex/app_server.ex` to
  document the stdio JSON-RPC client role, `start_session/2` -> `run_turn/4` ->
  `stop_session/1` lifecycle, the split between thread sandbox and per-turn
  sandbox policy, approval policy reuse across thread and turn startup, and how
  `DynamicTool.tool_specs/0` / `DynamicTool.execute/2` integrate with dynamic
  tool calls.

## Evidence
- Verified against the implementation that:
  - `thread/start` sends `"approvalPolicy"`, `"sandbox"`, `"cwd"`, and
    `"dynamicTools"` from `DynamicTool.tool_specs/0`.
  - `turn/start` sends `"approvalPolicy"` and `"sandboxPolicy"` for each turn.
  - `approval_policy == "never"` enables auto-approval behavior and
    non-interactive answers for supported `requestUserInput` prompts.
- No validation commands were run in this turn because `implement` explicitly
  defers runtime validation.

## Next Step
Run runtime-owned validation on the docs-only diff and continue the ticket if a
follow-up turn is still required.
