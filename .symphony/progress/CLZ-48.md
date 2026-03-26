# CLZ-48: Extract shared auto-commit logic into AgentProvider.CommitHelper

## Goal
Extract the duplicated post-turn commit/progress/result logic out of the Claude and CodexCLI adapters into a shared `SymphonyElixir.AgentProvider.CommitHelper` module.

## Acceptance
- Extract shared auto-commit logic into AgentProvider.CommitHelper The Claude and CodexCLI adapters both duplicate the same auto-commit logic: detect_changed_files, maybe_auto_commit (with mix format), maybe_patch_progress_file, and synthesize_turn_result. Extract these into a shared module at elixir/lib/symphony_elixir/agent_provider/commit_helper.ex that both adapters call. Changes: 1. Create elix
- `elixir/lib/symphony_elixir/agent_provider/claude.ex` and `elixir/lib/symphony_elixir/agent_provider/codex_cli.ex` should both delegate changed-file detection, progress-file patching, auto-commit, and turn-result synthesis to the shared helper and delete their duplicated private implementations.
- `elixir/test/symphony_elixir/commit_helper_test.exs` should cover the shared helper behavior directly, including the git-based changed-file collection and the `report_agent_turn_result` payload synthesis.

## Plan
1. `elixir/lib/symphony_elixir/agent_provider/commit_helper.ex` — add `SymphonyElixir.AgentProvider.CommitHelper` with public `detect_changed_files/2`, `maybe_patch_progress_file/2`, `maybe_auto_commit/2`, and `synthesize_turn_result/2` functions plus private `patch_empty_sections/2`, `ensure_section_content/3`, and `files_evidence/1` helpers; make the functions operate on any struct/map that already has `:files_touched`, `:result_text`, and `:error` so both adapter `StreamState` structs can be passed through unchanged.
2. `elixir/lib/symphony_elixir/agent_provider/commit_helper.ex` — choose and codify one `detect_changed_files/2` implementation instead of copying the current drift; preserve the current Claude-tested behavior of merging stream-detected paths with tracked changes from git and untracked files, while keeping the returned `files_touched` de-duplicated and stable for both adapters.
3. `elixir/lib/symphony_elixir/agent_provider/claude.ex` — add an alias for `CommitHelper`, change `run_turn/4` to call `CommitHelper.detect_changed_files/2`, `CommitHelper.maybe_patch_progress_file/2`, `CommitHelper.maybe_auto_commit/2`, and `CommitHelper.synthesize_turn_result/2`, keep the existing public test helpers but redirect them to the shared helper, and delete the now-duplicated private functions from the bottom half of the module.
4. `elixir/lib/symphony_elixir/agent_provider/codex_cli.ex` — add an alias for `CommitHelper`, replace the four post-stream private calls inside `run_turn/4` with the shared helper calls, and remove the duplicated private implementations for changed-file detection, progress patching, auto-commit, and turn-result synthesis.
5. `elixir/test/symphony_elixir/commit_helper_test.exs` — add direct unit coverage for `CommitHelper.synthesize_turn_result/2`, `CommitHelper.detect_changed_files/2`, `CommitHelper.maybe_patch_progress_file/2`, and the no-op/commit paths in `CommitHelper.maybe_auto_commit/2`; use a small test-only struct that mirrors the adapter stream-state keys so the tests verify the helper works with generic state structs rather than only Claude-specific wrappers.
6. `elixir/test/symphony_elixir/agent_provider_claude_test.exs` — only trim or update this file if the helper extraction breaks the existing wrapper-based assertions; otherwise keep the current Claude parsing coverage intact and let the new helper test own the shared post-turn behavior.
7. `.symphony/progress/CLZ-48.md` — after implementation, replace this planning note with the completed work log, validation evidence from the repo harness, and the concrete next follow-up if any behavior drift is discovered during extraction.

## Work Log
- Read the codebase and wrote the implementation plan.

## Evidence
- `.symphony/harness.yml`: confirmed the required progress-file sections and that repo-owned validation commands are `./scripts/symphony-preflight.sh`, `./scripts/symphony-validate.sh`, `./scripts/symphony-smoke.sh`, `./scripts/symphony-post-merge.sh`, `./scripts/symphony-artifacts.sh`, plus `mix harness.check`.
- `.symphony/knowledge/codebase-map.md`: confirmed the agent-provider code lives under `elixir/lib/symphony_elixir/agent_provider` and that this ticket stays inside the Elixir runtime boundary.
- `.symphony/knowledge/testing-and-ops.md`: confirmed validation should use the harness scripts and `mix harness.check` rather than ad hoc commands.
- `elixir/lib/symphony_elixir/agent_provider/claude.ex`: found the current `run_turn/4` flow and the duplicated private `detect_changed_files/2`, `maybe_patch_progress_file/2`, `maybe_auto_commit/2`, and `synthesize_turn_result/2` functions; also found public test wrappers already exposed for `detect_changed_files/2` and `synthesize_turn_result/2`.
- `elixir/lib/symphony_elixir/agent_provider/codex_cli.ex`: found the same four responsibilities duplicated privately in `run_turn/4`, with a different `detect_changed_files/2` implementation that uses `git status --porcelain` plus `git diff origin/main --name-only` instead of Claude’s `git diff --name-only HEAD` plus untracked-file scan.
- `elixir/lib/symphony_elixir/agent_provider.ex`: confirmed the provider behaviour does not need new callbacks for this extraction.
- `elixir/lib/symphony_elixir/agent_provider/codex.ex`: confirmed the AppServer-backed provider is unrelated to this extraction and should remain unchanged.
- `elixir/test/symphony_elixir/agent_provider_claude_test.exs`: found existing coverage for Claude stream parsing, synthesized turn-result payloads, and git-based changed-file detection, which gives a baseline for the shared helper semantics.
- `elixir/test/symphony_elixir/agent_provider_test.exs`: confirmed current provider tests only exercise provider resolution, so the new shared helper needs its own dedicated test file.
- `.symphony/progress/CLZ-48.md`: found an existing placeholder progress entry and replaced it with a concrete implementation plan for this planning turn.

## Next Step
Open `elixir/lib/symphony_elixir/agent_provider/commit_helper.ex`, add the new `SymphonyElixir.AgentProvider.CommitHelper` module, and implement `detect_changed_files/2` first so both adapters can be switched to the shared helper without guessing at the canonical git-based file-detection behavior.
