#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_HOME="${ROOT_DIR}/.symphony/runtime"

mkdir -p \
  "${RUNTIME_HOME}/mix_home" \
  "${RUNTIME_HOME}/hex_home" \
  "${RUNTIME_HOME}/mix_archives"

export MIX_HOME="${RUNTIME_HOME}/mix_home"
export HEX_HOME="${RUNTIME_HOME}/hex_home"
export MIX_ARCHIVES="${RUNTIME_HOME}/mix_archives"
