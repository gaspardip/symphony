# Figma Brief Spec

## Goal

Create a low-friction, agent-friendly preprocessing step for Figma implementation requests.

When an engineer says `implement this design <figma-url>`, the agent should gather richer Figma-native context before writing code, then hand the implementation stage a normalized brief instead of relying on a raw frame alone.

This spec deliberately avoids backend requirements. The first version is a local CLI plus skill orchestration.

## Non-Goals

- Replacing Builder, Figma MCP, or Code Connect
- Building a queue, webhook service, or team-wide automation backend
- Forcing designers into a heavy new process before the workflow proves value
- Solving arbitrary design discussion threads with perfect accuracy

## Desired UX

The default path should feel close to zero-friction:

1. User says `implement this design <figma-url>`.
2. The agent recognizes a Figma implementation request and uses the Figma implementation skill.
3. The skill runs `figma-brief <figma-url>`.
4. `figma-brief` gathers structure, intent, and code-grounding context from Figma-native sources.
5. The skill calls the official Figma MCP tools for design context and screenshots.
6. The agent implements using the merged brief, then validates visually.

Fallback behavior:

- If `figma-brief` is unavailable, continue with direct MCP.
- If Code Connect is absent for a node, continue without blocking.
- If comments or text nodes are noisy, lower confidence rather than stopping.

## System Shape

The workflow has two layers.

### Layer 1: Context Compiler

Local CLI: `figma-brief`

Responsibilities:

- Parse a Figma URL into `fileKey` and `nodeId`
- Gather context from Figma-native sources
- Rank and normalize the inputs
- Emit both machine-readable and agent-friendly artifacts

Outputs:

- `brief.json`
- `prompt.md`

### Layer 2: Implementation Orchestrator

Primary entry point: existing Figma implementation skill

Responsibilities:

- Invoke `figma-brief`
- Call official MCP tools
- Merge MCP output with `brief.json`
- Generate code using project conventions
- Validate the result against the Figma screenshot

## Figma-Native Inputs

Version 1 should prefer sources that Figma already provides.

### Required

- Figma MCP `get_design_context`
- Figma MCP `get_screenshot`
- Figma REST file/node data
- Figma REST comments
- Figma MCP `get_variable_defs` when useful
- Figma MCP `get_code_connect_map` when available

### Optional

- Figma MCP `get_metadata` for large nodes
- Figma Dev Resources attached to nodes
- Figma plugin-based annotations, if we add a private plugin later

## Source Priority

The brief compiler should resolve conflicts using this priority order:

1. Code Connect mappings and snippets
2. Project-native component conventions
3. Figma MCP design context and variables
4. Explicit structured intent from annotations
5. Tagged text nodes inside the frame
6. Relevant comments
7. Untagged freeform text nodes

Rationale:

- Code Connect is the strongest signal for component identity and props.
- MCP is the strongest signal for layout, sizing, and visual structure.
- Comments are useful, but they are a weak durable contract.

## CLI Contract

### Command

```bash
figma-brief <figma-url>
```

### Optional Flags

```bash
figma-brief <figma-url> \
  --format json|markdown|both \
  --out-dir ./.artifacts/figma-brief \
  --max-comments 20 \
  --include-metadata \
  --include-variables \
  --include-code-connect \
  --strict-tags
```

### Exit Behavior

- Exit `0` when a brief was produced, even if some optional sources failed
- Exit non-zero only when the target URL cannot be parsed or required Figma context cannot be fetched

### Artifacts

Given a node named `Checkout Summary`, the CLI should produce:

```text
.artifacts/figma-brief/checkout-summary/
  brief.json
  prompt.md
  screenshot.png
  raw-node.json
  raw-comments.json
  raw-code-connect.json
```

Raw files are useful for debugging prompt quality and ranking behavior.

## `brief.json` Schema

```json
{
  "target": {
    "figmaUrl": "https://www.figma.com/design/FILE/Name?node-id=12-345",
    "fileKey": "FILE",
    "nodeId": "12:345",
    "nodeName": "Checkout Summary"
  },
  "visual": {
    "screenshotPath": ".artifacts/figma-brief/checkout-summary/screenshot.png",
    "designContextSummary": [],
    "layoutSummary": []
  },
  "structure": {
    "components": [],
    "instances": [],
    "variables": [],
    "assets": []
  },
  "intent": {
    "annotations": [],
    "taggedTextNodes": [],
    "relevantComments": [],
    "inferredNotes": []
  },
  "codegrounding": {
    "codeConnectComponents": [],
    "devResources": [],
    "repoHints": []
  },
  "openQuestions": [],
  "confidence": {
    "overall": 0.0,
    "visual": 0.0,
    "structure": 0.0,
    "behavior": 0.0,
    "content": 0.0
  }
}
```

## `prompt.md` Template

The CLI should compile a concise prompt wrapper around the brief.

```md
Implement the Figma node at this URL:
<figma-url>

Use the following priority order:
1. Code Connect mappings and snippets
2. Existing project components and tokens
3. Figma design context, variables, and screenshot
4. Designer intent from annotations, tagged text nodes, and comments

Constraints:
- Reuse existing components where possible
- Match the Figma screenshot closely
- Preserve semantic HTML and accessibility
- Do not invent interactions not supported by the gathered context

Structured brief:
```json
{...}
```

If anything is ambiguous, list the ambiguity briefly and choose the safest implementation.
```

## Intent Extraction Rules

### Tagged Text Nodes

Version 1 should support a minimal convention inside the target frame:

- `STATE:`
- `A11Y:`
- `DATA:`
- `COPY:`
- `DO:`
- `DONT:`

Rules:

- Only parse descendant text nodes within the target subtree
- Ignore tiny decorative labels and obviously visible UI copy
- Prefer text nodes placed outside the main content flow or grouped in a note area
- Keep the raw text and a normalized category

Example:

```json
{
  "kind": "STATE",
  "text": "Hover state darkens background and shows arrow icon",
  "nodeId": "22:19",
  "confidence": 0.93
}
```

### Comments

Comments should be treated as supporting context, not canonical truth.

Rules:

- Include only comments that can be linked to the selected frame or nearby coordinates
- Deduplicate resolved discussion threads when possible
- Prefer the latest designer-authored comment when comments conflict
- Penalize comments with broad discussion and no implementation signal

Example extracted comment:

```json
{
  "author": "Designer Name",
  "text": "Use the compact card treatment here, same behavior as mobile checkout",
  "confidence": 0.68
}
```

### Inferred Notes

The compiler may infer notes when several weak signals align, but should mark them clearly.

Example:

```json
{
  "kind": "behavior",
  "text": "Likely reuses the existing compact checkout card pattern",
  "derivedFrom": ["comment", "instance name", "code connect map"],
  "confidence": 0.44
}
```

Low-confidence inference should never override a stronger explicit source.

## Code Connect Role

Code Connect is not the note collector. It is the code-grounding layer.

It should answer three questions:

1. Which code component does this Figma component correspond to?
2. How do Figma properties map to component props?
3. What does correct usage look like in this repo?

Example normalized Code Connect entry:

```json
{
  "figmaComponent": "Button",
  "codeComponent": "Button",
  "source": "src/components/ui/Button.tsx",
  "props": {
    "Size=Large": {
      "size": "lg"
    },
    "Kind=Primary": {
      "variant": "primary"
    },
    "Disabled=true": {
      "disabled": true
    }
  },
  "snippet": "<Button variant=\"primary\" size=\"lg\" disabled={false}>Pay now</Button>"
}
```

Implementation impact:

- If Code Connect maps a node to an existing repo component, the agent should prefer that component over hand-rolled markup.
- If no mapping exists, the agent falls back to project conventions and MCP structure.
- If the mapping exists but conflicts with visible design intent, the agent should note the conflict and choose the safer path.

## Confidence Model

The compiler should expose confidence instead of pretending certainty.

Suggested interpretation:

- `0.85-1.00`: strong signal, safe to apply automatically
- `0.60-0.84`: usable, but should be treated as secondary evidence
- `0.35-0.59`: weak inference, include with caution
- `<0.35`: ignore unless no better signal exists

Low confidence should produce `openQuestions` rather than hard failures.

## Skill Flow

The Figma implementation skill should be extended conceptually to this order:

1. Detect Figma URL or selected node
2. Run `figma-brief`
3. Run `get_design_context`
4. Run `get_screenshot`
5. Run `get_code_connect_map`
6. Run `get_variable_defs` when tokens matter
7. Run `get_metadata` only if the node is too large or truncated
8. Merge all context into a final implementation brief
9. Implement using project conventions
10. Validate visually against the screenshot

Fallback rules:

- If `figma-brief` fails, continue with MCP only
- If Code Connect is missing, do not block
- If comments and text notes are absent, proceed from design context alone

## Minimal Implementation Plan

### Phase 1

- Implement `figma-brief` as a local CLI
- Support URL parsing, raw Figma reads, MCP context capture, and artifact emission
- Generate `brief.json` and `prompt.md`
- Keep note extraction simple and deterministic

### Phase 2

- Add better comment-to-node relevance scoring
- Improve text-node filtering to distinguish visible copy from implementation notes
- Add optional repo hints from known component paths

### Phase 3

- Add a private Figma plugin for annotations and manual export
- Normalize text notes into annotations when useful
- Optionally attach generated brief artifacts back to nodes via Dev Resources

## Success Criteria

The workflow is successful when:

- `implement this design <figma-url>` automatically gathers context before coding
- First-pass implementations reuse existing repo components more often
- The agent asks fewer clarification questions for obvious design-intent details
- The visual delta between Figma and implementation drops
- The process adds little or no manual overhead for the designer

## Recommendation

Build Phase 1 first.

Do not build a backend yet.

The highest-leverage change is a local context compiler that enriches the agent prompt with:

- structured design context
- screenshot-backed visual reference
- code-grounding from Code Connect
- lightweight intent extraction from comments and text nodes

That is enough to prove whether the workflow materially improves one-shot design implementation before adding more surface area.
