# Dogfood Operations

This runbook covers the self-hosted Symphony dogfood workflow for `gaspardip/symphony`.

## Preconditions

- `LINEAR_API_KEY` is set.
- The dogfood Linear workflow uses the `dogfood:symphony` label gate.
- The canary narrowing label is `canary:symphony`.
- `SYMPHONY_RUNNER_INSTALL_ROOT` points to the promoted runner install root.
- The local Symphony checkout has a valid [.symphony/harness.yml](/Users/gaspar/src/symphony/.symphony/harness.yml).

## Bootstrap A Stable Runner

1. Pick the ref you want to promote.
2. Promote it into canary mode:

```bash
cd /Users/gaspar/src/symphony
SYMPHONY_RUNNER_INSTALL_ROOT="$HOME/.local/share/symphony-runner" \
  ./ops/promote-runner.sh promote <git-ref>
```

3. Inspect the promoted runner:

```bash
SYMPHONY_RUNNER_INSTALL_ROOT="$HOME/.local/share/symphony-runner" \
  ./ops/promote-runner.sh inspect
```

Expected result:
- `runner_mode` is `canary_active`
- `current` points at `releases/<sha>`
- `metadata.json` and `releases/<sha>/manifest.json` agree on the release SHA

## Launch The Dogfood Runner

Use the dedicated dogfood wrapper:

```bash
cd /Users/gaspar/src/symphony-local
SYMPHONY_RUNNER_INSTALL_ROOT="$HOME/.local/share/symphony-runner" \
  ./run-symphony-dogfood.sh --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

The wrapper prints the active runner mode and SHA before launch.

## Confirm Canary Routing

While the runner is in `canary_active`:

- issues with only `dogfood:symphony` should be skipped
- issues with both `dogfood:symphony` and `canary:symphony` should be dispatchable

Use the dashboard or API:

```bash
curl -s http://127.0.0.1:4040/api/v1/state | jq '.runner, .skipped, .queue'
```

Expected result:
- `runner.runner_mode == "canary_active"`
- `runner.dispatch_enabled == true`
- `runner.effective_required_labels` includes both `dogfood:symphony` and `canary:symphony`

## Record A Canary Pass

Record a successful canary explicitly. This is the only supported way to leave `canary_active`.

```bash
cd /Users/gaspar/src/symphony
SYMPHONY_RUNNER_INSTALL_ROOT="$HOME/.local/share/symphony-runner" \
  ./ops/promote-runner.sh record-canary pass \
    --issue CLZ-123 \
    --pr https://github.com/gaspardip/symphony/pull/123 \
    --note "Canary merge and smoke checks were healthy."
```

Expected result:
- `runner_mode` becomes `stable`
- routing broadens back to issues labeled only `dogfood:symphony`

## Record A Canary Failure

If the canary is unhealthy, record it explicitly and attach evidence.

```bash
cd /Users/gaspar/src/symphony
SYMPHONY_RUNNER_INSTALL_ROOT="$HOME/.local/share/symphony-runner" \
  ./ops/promote-runner.sh record-canary fail \
    --issue CLZ-456 \
    --pr https://github.com/gaspardip/symphony/pull/456 \
    --note "Regression in await_checks recovery."
```

Expected result:
- `runner_mode` becomes `canary_failed`
- `rollback_recommended` becomes `true`
- the dashboard shows the rollback target and the recorded issue/PR evidence

## Roll Back To The Previous Release

Default rollback target is `previous_release_sha` from `metadata.json`.

```bash
cd /Users/gaspar/src/symphony
SYMPHONY_RUNNER_INSTALL_ROOT="$HOME/.local/share/symphony-runner" \
  ./ops/promote-runner.sh rollback
```

To roll back to a specific release:

```bash
cd /Users/gaspar/src/symphony
SYMPHONY_RUNNER_INSTALL_ROOT="$HOME/.local/share/symphony-runner" \
  ./ops/promote-runner.sh rollback <release-sha>
```

Expected result:
- `current` points at the chosen release
- `runner_mode` returns to `stable`
- canary evidence is cleared from the active metadata
- `history.jsonl` records `runner.rollback.completed`

## Recover From Invalid Metadata Or A Broken Current Symlink

If the dashboard shows dispatch disabled with a runner health rule:

- `runner.install_missing`
  - create or restore the install root, then promote a runner
- `runner.metadata_invalid`
  - repair `metadata.json` or promote a fresh runner
- `runner.current_missing`
  - recreate the `current` symlink by promoting or rolling back
- `runner.current_mismatch`
  - make `metadata.json` match the `current` symlink target, or run rollback
- `runner.release_missing`
  - restore the missing release directory or roll back to an available one

Recommended recovery sequence:

1. Inspect the current metadata:

```bash
cd /Users/gaspar/src/symphony
SYMPHONY_RUNNER_INSTALL_ROOT="$HOME/.local/share/symphony-runner" \
  ./ops/promote-runner.sh inspect
```

2. If the install is inconsistent but a previous release still exists, run rollback.
3. If there is no safe rollback target, promote a known-good ref again.

## Operational Notes

- Promotion and rollback remain CLI-only on purpose.
- Dogfood issues never mutate the live executing checkout; they always run in isolated workspaces.
- A merged dogfood PR does not replace the live runner until you run `promote`.
