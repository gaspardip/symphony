#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command git
require_command gh
require_command mise
require_command make

git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null
gh auth status >/dev/null 2>&1

cd "$ROOT_DIR/elixir"
mise trust
mise exec -- make setup
