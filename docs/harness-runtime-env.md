# Harness runtime environment

`RunInspector` prepares a child-process environment before executing configured
preflight, validation, smoke, post-merge, deployment and verification commands.
`run_shell_command/3` uses the same contract. It does not change the daemon's
environment or the arguments of the configured command.

## Directory contract

- An explicit `MIX_HOME`, `HEX_HOME` or `MIX_ARCHIVES` is preserved.
- Otherwise, Mix and Hex use `.symphony/runtime/mix_home` and
  `.symphony/runtime/hex_home` under the workspace.
- When `MIX_HOME` is explicit and `MIX_ARCHIVES` is absent, archives retain Mix's
  normal location under `MIX_HOME/archives`.
- When both are absent, archives use `.symphony/runtime/mix_archives`.
  Installed archives, including Hex, are copied from the default Mix home.
  The installed rebar3 binary for the current Elixir/OTP version is copied to
  the local Mix home. Default Mix-home lookup honors `MIX_XDG`.
- Existing local files win over seed copies. Repeated commands reuse those
  directories; inherited overrides also prevent nested harness calls from
  creating another layer of runtime directories.
- Other environment variables, including explicit Hex cache/config paths,
  `MIX_REBAR3`, `MIX_DEPS_PATH`, `MIX_BUILD_PATH` and authentication supplied
  to the command, remain inherited.

Only installed archives and the versioned rebar3 binary are seeded. Global Mix
configuration and Hex credentials/configuration are not copied. The project's
`deps/` and `_build/` directories are neither moved nor cleared.

Repositories using these defaults must ignore `.symphony/runtime/` so local
archives and cache files cannot enter a `git add -A` commit. Inspector status
filtering alone does not change Git staging.

Hex's workspace home starts empty. This prepares writable local state; it does
not download missing tools or packages, replicate the user's package cache, or
make a fresh checkout usable offline without its dependencies. Private registry
configuration must be supplied explicitly. A tool absent from the default Mix
home remains absent and the configured command reports its normal failure.

Explicit overrides can point outside the workspace. Thus this is isolation of
default Mix/Hex state, not a filesystem sandbox or an isolation guarantee for
every tool used by a harness. Shell commands can also override their own
environment.

## Failure and validation

A nonzero child exit returns `:failed` with combined stdout/stderr. An error
creating runtime directories or reading/copying an available seed returns
`:unavailable` with the filesystem error; the harness is not started.
An unconfigured command creates no directories. Injected shell runners receive
the environment options but retain responsibility for their own execution and
filesystem preparation; local directory creation belongs to the default runner.

Focused regression coverage is in
`elixir/test/symphony_elixir/run_inspector_runtime_env_test.exs`. It checks real
shell commands with spaces in workspace paths, preserved overrides, child-only
scope, repeat execution, tool seeding, failure propagation and an offline
`mix hex.info` using the installed Hex archive. The test toolchain must already
have Hex installed.

Run from `elixir/`:

```sh
mise exec -- mix test test/symphony_elixir/run_inspector_runtime_env_test.exs test/symphony_elixir/run_inspector_test.exs
```

Direct invocations of repository shell scripts retain their existing environment;
the defaults above apply when commands are launched through `RunInspector`.
