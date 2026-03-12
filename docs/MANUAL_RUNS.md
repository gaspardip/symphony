# Manual Runs

Use manual runs when you want Symphony to execute the full delivery pipeline without waiting on a tracker like Linear.

Manual intake is useful for:

- proving the delivery engine end to end
- replaying the same issue deterministically
- testing a repo while tracker APIs are rate-limited or unavailable

Manual issues use the same runtime after intake:

- checkout
- implement
- validate
- verify
- publish
- await checks
- merge
- post-merge verification

The only difference is the intake path.

## Requirements

- a running Symphony server
- a repo with a valid `.symphony/harness.yml`
- a JSON issue spec

## Issue Spec Format

Required fields:

- `id`
- `identifier`
- `title`
- `acceptance_criteria`

Optional fields:

- `description`
- `validation`
- `out_of_scope`
- `policy_class`
- `labels`
- `priority`
- `url`
- `branch_name`

`policy_class` may be one of:

- `fully_autonomous`
- `review_required`
- `never_automerge`

## Submit A Manual Issue

Start Symphony normally, then submit a spec file:

```bash
cd /Users/gaspar/src/symphony/elixir
./bin/symphony manual submit /absolute/path/to/issue.json --server http://127.0.0.1:4040
```

If `--server` is omitted, Symphony uses `http://127.0.0.1:4040`.

## Example: `events` Simple Pilot

Example spec based on `CLZ-14`:

```json
{
  "id": "clz-14-manual",
  "identifier": "CLZ-14",
  "title": "Unify onboarding and settings persistence so first-run state stays consistent across relaunches",
  "description": "Move onboarding completion into a single persisted source of truth so relaunch behavior stays consistent.",
  "acceptance_criteria": [
    "Onboarding completion is driven by a single persisted source of truth.",
    "Relaunching the app after completing onboarding does not return the user to onboarding unexpectedly.",
    "Reset-related behavior is explicit and consistent with other persisted preferences."
  ],
  "validation": [
    "Complete onboarding, terminate the app, relaunch, and confirm the main tab experience opens directly.",
    "Clear or reset relevant persisted state and confirm onboarding behavior follows the intended reset path."
  ],
  "policy_class": "fully_autonomous",
  "labels": [
    "symphony:events"
  ]
}
```

This is the recommended first manual pilot because it is deterministic and does not depend on location, calendar, or notification permissions.

## Review-Gated Manual Runs

To force a manual review hold before merge, set:

```json
{
  "policy_class": "review_required"
}
```

That run will still publish the PR and wait for checks, but it will stop at `Human Review`. Finish it from the dashboard or API with `approve_for_merge`.

## Runtime Behavior

Manual issues keep local Symphony states:

- `Todo`
- `In Progress`
- `Human Review`
- `Rework`
- `Merging`
- `Blocked`
- `Done`

Because manual issues are tracker-free:

- state changes are stored locally
- comments are stored locally
- attached links are stored locally
- recovery works from persisted runtime state and the manual issue store

## Notes

- Manual intake is an alternate intake path, not a second orchestration model.
- Tracker-backed and manual-backed issues share the same runtime once accepted.
- Manual issues appear in the dashboard and API with `source = manual`.
