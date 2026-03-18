---
applyTo: "elixir/lib/symphony_elixir/{orchestrator,delivery_engine,run_state_store,repo_harness,pull_request_manager,verifier_runner,run_inspector,workflow,config}.ex,elixir/lib/mix/tasks/{harness.check,pr_body.check,specs.check}.ex,.symphony/harness.yml,scripts/symphony-validate.sh,elixir/Makefile"
---

Review these changes as runtime-contract changes.

- Protect stage semantics. Flag edits that can skip, collapse, or silently repurpose `checkout`, `implement`, `validate`, `verify`, `publish`, `await_checks`, `merge`, `post_merge`, `blocked`, or `done` without matching recovery/test updates.
- Protect persisted state compatibility. New `RunStateStore` fields must merge into old state files, stay issue-scoped, and avoid resuming stale state for a different issue or workspace.
- Protect verifier isolation. In `VerifierRunner` and related delivery paths, flag any route that lets verification mutate files, git state, PR metadata, or tracker state; verification is intended to be read-only.
- Protect publish/merge gates. Flag changes that weaken required-check handling, PR-body validation, credential/policy checks, or merge readiness without corresponding contract updates in `.symphony/harness.yml`, `scripts/symphony-validate.sh`, `elixir/Makefile`, and `.github/pull_request_template.md`.
- Ask for focused regression tests when these areas change. The high-value suites are `recovery_and_lease_test.exs`, `delivery_engine_phase3_test.exs`, `delivery_runtime_phase6_backfill_test.exs`, `repo_harness_test.exs`, `pull_request_manager_test.exs`, and `policy_runtime_test.exs`.
