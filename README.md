# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## This fork

This checkout extends Symphony with a runtime-owned delivery loop. The runtime
manages branches, commits, pull requests, checks and tracker transitions under the
configured policy. See [the current runtime contract](docs/RUNTIME_CONTRACT.md) and
[the Elixir guide](elixir/README.md) for this implementation. The upstream demo and
specification below describe its starting point, not acceptance evidence for this fork.

The [selected runner release contract](docs/selected-runner-release.md) distinguishes
the configured release from execution identity and defines its pre-run path protection.

Delivery branch preparation and resets fetch the configured base explicitly, including
workspaces cloned for a different single branch. Reset selects the local base at its
remote revision and preserves the runtime snapshot; local code changes are discarded.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/gaspardip/symphony/blob/main/elixir/README.md

Workspace lifecycle operations refuse paths that overlap the runner install,
current checkout, or selected release before creation, reset, cleanup, or hooks.
Symbolic links are resolved, and existing directory identities are compared
before this check.

Codex app-server workers honor cooperative shutdown during startup and streaming.
They close their protocol port before propagating shutdown to the caller.

GitHub review and CI follow-up use only the canonical workspace for an issue.
Archived copies with the same pull request URL are left unchanged.

New worker dispatch validates the current workflow and workspace root. Invalid configuration
blocks the worker and records a `config_invalid` event for diagnosis.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
