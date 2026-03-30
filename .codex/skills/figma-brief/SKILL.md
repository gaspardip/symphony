---
name: figma-brief
description:
  Compile a Figma-native implementation brief before design-to-code work. Use
  when a request includes a Figma URL, selected node, or asks to implement a
  design from Figma with minimal ambiguity.
---

# Figma Brief

## Goal

Gather richer Figma-native context before implementation so the agent starts
from a normalized brief instead of a raw frame alone.

## When To Use

Use this skill whenever:

- the user provides a Figma URL or node ID
- the user asks to implement a design from Figma
- the user wants better first-pass fidelity from design to code

## Repo Entry Point

Always invoke the repo-owned wrapper first:

```bash
./scripts/figma-brief.sh "<figma-url>"
```

This wrapper bootstraps the standalone CLI in `~/src/figma-brief` and emits the
brief artifacts under `.artifacts/figma-brief/`.

## Required Flow

1. Run `./scripts/figma-brief.sh "<figma-url>"`.
2. Read the generated `brief.json` and `prompt.md`.
3. Run the official Figma MCP workflow:
   - `get_design_context`
   - `get_screenshot`
   - `get_code_connect_map`
   - `get_variable_defs` when useful
   - `get_metadata` only if the node is too large or truncated
4. Merge the brief with the official MCP outputs.
5. Implement using repo conventions and Code Connect mappings when available.
6. Validate visually against the Figma screenshot before marking the work
   complete.

## Priority Order

Treat inputs in this order:

1. Code Connect mappings and snippets
2. Existing repo components and conventions
3. Figma MCP design context, variables, layout, and screenshot
4. Structured intent from tagged text nodes
5. Relevant comments

## Fallback Rules

- If `figma-brief` fails, continue with direct MCP and mention the failure.
- If Code Connect is missing, do not block implementation.
- If no tagged text or useful comments are found, continue from design context
  alone.

## Notes

- `figma-brief` is an internal preprocessing step. Do not force the user to run
  it manually when the agent can run it itself.
- The wrapper bootstraps the standalone project at `~/src/figma-brief` and may
  install local package dependencies on first run.
- Keep the user-facing workflow simple: `implement this design <figma-url>`.
