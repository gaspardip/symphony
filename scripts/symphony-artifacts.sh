#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${SYMPHONY_ARTIFACT_ROOT:-$HOME/.local/state/symphony-artifacts/symphony}"
SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
STAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TARGET_DIR="$ARTIFACT_ROOT/$SHA"

mkdir -p "$TARGET_DIR"

cat >"$TARGET_DIR/summary.txt" <<EOF
repo_root=$ROOT_DIR
commit_sha=$SHA
generated_at=$STAMP
branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
EOF

echo "$TARGET_DIR"
