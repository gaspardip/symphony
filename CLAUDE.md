# Symphony

Autonomous ticket-to-merge orchestrator. Elixir app in `elixir/`.

## Commands

All commands run from `elixir/`:

```bash
cd elixir
mise trust                    # required once per checkout
make all                      # full CI: fmt → lint → coverage → dialyzer
mix test                      # all tests
mix test path/to/test.exs:42  # single test by line
mix format --check-formatted  # format check
mix credo --strict            # lint
mix coverage.audit            # tests + 84% overall / 76% core threshold
mix dialyzer --format short   # type check
mix build                     # escript → bin/symphony
```

## Commit conventions

`fix:`, `feat:`, `refactor:`, `chore:`, `test:` — one concern per commit. Include `(CLZ-XX)` when closing a Linear ticket.

## Testing

- Run `mise trust` before first test run in any new checkout or worktree
- Tests create temp workspaces in `System.tmp_dir!()` — no fixture directories
- Fake codex binaries are shell scripts generated per-test in `fake_codex_binary!/1`
- `TestSupport` (via `use SymphonyElixir.TestSupport`) provides `write_workflow_file!`, `git_stage_workspace!`, `capture_log`

### Known flaky tests (pre-existing, not regressions)

- `WebhookFirstIntakeTest` — intermittent, environment-dependent
- `CoverageCliPhase6BackfillTest "CLI main exits zero"` — timing-sensitive
- `OrchestratorControlsPhase6Test "default dispatch path"` — workspace race (`Could not cd to /tmp/...`)
- `DeliveryEnginePhase6Test "merge readiness refreshes PR body"` — mise trust / test ordering

If CI fails on one of these with all other tests passing: rerun.

## Dialyzer

Ignore file: `elixir/.dialyzer_ignore.exs`. Format is Elixir list of tuples:
- `{"file.ex", "error message substring"}` — string match
- `{"file.ex", :warning_type, {line, column}}` — exact line match

When your changes shift line numbers in orchestrator.ex or delivery_engine.ex, update the `{line, col}` entries. Find the new line with `mix dialyzer --format short`.

## Coverage

Thresholds in `elixir/lib/symphony_elixir/coverage_audit.ex`:
- Overall: 84%
- Core modules: 76% (DeliveryEngine, Orchestrator, RunPolicy, etc.)

If you add code to a core module without proportional tests, coverage audit will fail.

## Architecture (non-obvious)

- `orchestrator.ex` (7900 lines) is a single GenServer — poll ticks, dispatch, webhooks, operator API all share one process
- `delivery_engine.ex` (5200 lines) handles the full stage machine: checkout → plan → implement → validate → publish → merge
- Run state is an untyped `%{}` map (~50 keys) persisted as JSON — no struct, no compile-time safety
- Stage names are bare strings ("checkout", "plan", "implement", etc.) — no central constants
- `WORKFLOW.md` is runtime config (YAML frontmatter + Liquid template), NOT documentation
- `_for_test` public wrappers expose private functions to tests — don't add more, we're removing them

## WORKFLOW.md config

The daemon reads `elixir/WORKFLOW.md` at runtime. Key fields:
- `tracker.project_slug` — Linear `slugId` (just the hash, NOT the URL prefix)
- `runner.channel` — must match canary label system (`canary` or `stable`)
- `hooks.after_create` — runs in workspace dir after `mkdir`; must clone the repo
- Issues need `canary:symphony` label + assignee matching `LINEAR_ASSIGNEE` env var

## PR workflow

1. Branch from main: `fix/clz-XX-slug` or `feat/clz-XX-slug`
2. Push and create PR via `gh pr create`
3. CI runs `make all` — must pass format, lint, tests, coverage, dialyzer
4. Merge to main; main CI must stay green

## Agent knowledge

- Harness contract: `.symphony/harness.yml`
- Durable knowledge: `.symphony/knowledge/` (product, architecture, codebase-map, delivery-loop, testing-and-ops)
- Per-issue progress: `.symphony/progress/CLZ-XX.md`
- Feature definitions: `.symphony/features/*.yaml`

For Symphony self-host runs: update the progress file and affected feature YAMLs when changing code. Use repo-owned commands from the harness (preflight, validation, smoke, post-merge) — don't invent alternatives.
