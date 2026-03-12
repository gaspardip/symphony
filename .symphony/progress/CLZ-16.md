# CLZ-16: Make the self-development harness mandatory for Symphony self-host runs

## Goal
Make the self-development harness the required contract for Symphony self-host runs in the Symphony project.

## Acceptance
- `initialize_harness` is a required runtime stage for Symphony self-runs before `implement`.
- `.symphony/harness.yml` includes a valid `agent_harness` section for the Symphony repo.
- `mix harness.check` is part of the official Symphony validation contract.
- Publish is blocked when required knowledge, progress, or feature artifacts are missing or stale.
- A self-host issue can be blocked with a concrete harness report before publish.

## Plan
- Add a strict `agent_harness` contract to the Symphony repo harness.
- Add the `initialize_harness` runtime stage ahead of `implement`.
- Add repo-tracked knowledge, progress, and feature artifacts for self-host runs.
- Add `mix harness.check` and make it part of the official validation contract.
- Enforce a publish gate that requires current progress and feature updates.
- Prove the path with targeted tests and a live self-host issue.

## Work Log
- Added `agent_harness` to `/.symphony/harness.yml` and validated it through `RepoHarness`.
- Added `SymphonyElixir.AgentHarness` plus runtime wiring so self-host runs execute `initialize_harness` before `implement`.
- Added `mix harness.check` and wired it into `./scripts/symphony-validate.sh` and the Elixir `Makefile`.
- Added required knowledge files under `/.symphony/knowledge`.
- Added repo-tracked feature metadata under `/.symphony/features`.
- Added publish-gate enforcement so self-host publishes fail when progress or feature artifacts are missing or stale.
- Added the thin root `AGENTS.md` index so the repo map stays discoverable without bloating the root instructions.
- Verified the full Symphony Elixir suite passes on the baseline branch before merge.

## Evidence
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix test`
- `cd /Users/gaspar/src/symphony/elixir && mise exec -- mix harness.check`
- `cd /Users/gaspar/src/symphony && ./scripts/symphony-smoke.sh`
- Live self-host routing proof: the dogfood runner on `:4046` picked up `CLZ-16` from the Symphony Linear project with assignee-first routing.
- Live self-host failure proof: `CLZ-16` blocked on `budget.per_turn_input_exceeded`, proving the issue entered the self-host execution path with the new harness contract loaded.

## Next Step
Merge the current baseline branch into `main`, rotate the dogfood runner to the merged default branch, and re-run the next Symphony self-host issues from a fresh base branch instead of the long-running baseline branch.
