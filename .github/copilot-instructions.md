When reviewing code, prioritize defects, regressions, missing tests, and contract drift over style.

Treat `elixir/Makefile`, `scripts/symphony-validate.sh`, `.symphony/harness.yml`, and `.github/pull_request_template.md` as runtime contracts. Flag changes that alter required checks, validation steps, or PR requirements in only one place.

If a change affects runtime behavior or configuration described to operators or repo adopters, ask whether the matching docs also need updates in `README.md`, `elixir/README.md`, `docs/AGENT_HARNESS.md`, or `WORKFLOW.md`.

Prefer comments that point out missing regression coverage in the existing focused suites over generic “add tests” advice. The important gates here are `mix harness.check`, `make -C elixir all`, and the targeted ExUnit suites that protect the changed runtime path.
