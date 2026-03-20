#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/scripts/symphony-runtime-env.sh"

cd "$ROOT_DIR/elixir"
mise trust
mise exec -- mix harness.check
mise exec -- make all
