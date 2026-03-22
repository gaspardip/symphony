# CLZ-39: Add provider config example comments to WORKFLOW.md

## Goal
Document the new provider-agnostic agent config options in WORKFLOW.md as YAML comments.

## Acceptance
- WORKFLOW.md has commented examples of provider, model, and per-stage providers config
- No functional config values changed
- mix compile passes

## Plan
- Read current WORKFLOW.md codex: section
- Add commented YAML examples for provider, model, and providers options
- Verify no functional values changed

## Work Log
- Added 19 lines of YAML comments documenting provider, model, and per-stage provider/model routing options

## Evidence
- `git diff --stat` shows only `elixir/WORKFLOW.md | 19 +++++++++++++++++++`
- Only comment lines added (all prefixed with `#`)

## Next Step
- Merge PR
