# Stage provider configuration

## Goal

Make the existing per-stage provider configuration usable through the actual
workflow validation and resolution route, before changing session ownership.

## Acceptance

YAML, JSON and legacy mappings use normalized string keys. Preserve precedence,
empty/missing controls, existing-stage atom safety and provider fallback. Keep
model/reasoning behavior and existing tests intact. Session handoff is separate.

## Plan

Fix the schema key type and lookup only. Add eight public configuration
regressions. Run targeted and existing integrations, then the repository gates.

## Work Log

The original public probe reproduced three ValidationError failures for nonempty
mappings and two successful controls. The reviewed patch changes two lines;
the new regressions open no provider sessions and weaken no existing assertions.

## Evidence

Immutable external validation receipts bind the exact source, command results
and physical process closure. Original reproduction is kept separately from
patched routing validation. Full architecture closure additionally requires
the session-lifecycle work, joint audit and a fresh-source 26-case campaign.
The frozen video reference remains independently preserved.

## Next Step

Close the configuration gates on the corrected source, then reproduce the
original live-session retention and implement the separately reviewed
stage-session lifecycle. Preserve original failed and successful receipts.
