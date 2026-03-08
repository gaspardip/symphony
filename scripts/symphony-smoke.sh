#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR/elixir"
mise trust
mise exec -- mix build
mise exec -- mix test \
  test/symphony_elixir/policy_runtime_test.exs \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/core_test.exs \
  test/symphony_elixir/extensions_test.exs \
  test/symphony_elixir/dynamic_tool_test.exs \
  test/symphony_elixir/pull_request_manager_test.exs
