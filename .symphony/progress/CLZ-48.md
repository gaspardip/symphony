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
- Added `SymphonyElixir.AgentProvider.CommitHelper` and moved shared changed-file detection, progress patching, auto-commit, and turn-result synthesis into it.
- Updated both CLI adapters to delegate the shared post-stream flow to `CommitHelper` and removed their duplicated private implementations.
- Added focused helper coverage for changed-file detection, progress patching, turn-result synthesis, and auto-commit behavior with a generic test state struct.

## Evidence
- `elixir/lib/symphony_elixir/agent_provider/commit_helper.ex`: centralizes the shared post-turn helper logic and normalizes changed-file detection on tracked diff-from-HEAD plus untracked files.
- `elixir/lib/symphony_elixir/agent_provider/claude.ex`: now delegates the shared post-turn flow and keeps the existing public test wrappers pointed at the extracted helper.
- `elixir/lib/symphony_elixir/agent_provider/codex_cli.ex`: now delegates the same shared post-turn flow and no longer carries its local copy of the helper logic.
- `elixir/test/symphony_elixir/commit_helper_test.exs`: covers turn-result synthesis, git-based changed-file collection, progress patching, and auto-commit behavior directly against the shared helper.
- `mix test test/symphony_elixir/commit_helper_test.exs`: passed with 7 tests and 0 failures after tightening the fixture expectations to match the helper contract.
- `mix test test/symphony_elixir/agent_provider_claude_test.exs`: passed with 24 tests and 0 failures after the extraction.

## Next Step
- Hand the branch back to the runtime for repo-owned validation and the remaining autonomous delivery steps.
