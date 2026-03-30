#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="${HOME}/src/figma-brief"

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to run figma-brief" >&2
  exit 1
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm is required to bootstrap figma-brief" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "figma-brief project not found at $PROJECT_DIR" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_DIR/node_modules/commander" ]]; then
  pnpm install --dir "$PROJECT_DIR" --frozen-lockfile
fi

exec node "$PROJECT_DIR/bin/figma-brief.js" "$@"
