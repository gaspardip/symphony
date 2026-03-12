#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${SYMPHONY_RUNNER_REPO_URL:-git@github.com:gaspardip/symphony.git}"
INSTALL_ROOT="${SYMPHONY_RUNNER_INSTALL_ROOT:-$HOME/.local/share/symphony-runner}"
DEFAULT_CANARY_LABEL="${SYMPHONY_RUNNER_DEFAULT_CANARY_LABEL:-canary:symphony}"
RELEASES_DIR="$INSTALL_ROOT/releases"
CURRENT_LINK="$INSTALL_ROOT/current"
METADATA_PATH="$INSTALL_ROOT/metadata.json"
HISTORY_PATH="$INSTALL_ROOT/history.jsonl"

usage() {
  cat <<'EOF' >&2
Usage:
  promote-runner.sh promote <git-ref> [--canary-label <label> ...]
  promote-runner.sh inspect
  promote-runner.sh record-canary <pass|fail> [--issue <LINEAR-ID> ...] [--pr <URL> ...] [--note <text>]
  promote-runner.sh rollback [<release-sha>]
EOF
  exit 1
}

require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for runner metadata management" >&2
    exit 1
  fi
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_install_root() {
  mkdir -p "$INSTALL_ROOT" "$RELEASES_DIR"
}

current_link_target() {
  python3 - "$CURRENT_LINK" <<'PY'
import os
import sys

path = sys.argv[1]
if os.path.islink(path):
    print(os.path.realpath(path))
PY
}

json_array() {
  python3 - "$@" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:]))
PY
}

build_tool_versions_json() {
  python3 <<'PY'
import json
import shutil
import subprocess

def capture(args):
    try:
        completed = subprocess.run(args, check=False, capture_output=True, text=True)
    except Exception:
        return None
    output = (completed.stdout or completed.stderr or "").strip()
    if not output:
        return None
    return output.splitlines()[0]

commands = {
    "gh": ["gh", "--version"],
    "mise": ["mise", "--version"],
    "elixir": ["elixir", "--version"],
    "git": ["git", "--version"],
    "erlang": ["erl", "-noshell", "-eval", "io:format(\"~s\", [erlang:system_info(otp_release)]), halt()."],
}

payload = {}
for name, args in commands.items():
    path = shutil.which(args[0])
    payload[name] = {
        "path": path,
        "version": capture(args) if path else None,
    }

print(json.dumps(payload, separators=(",", ":")))
PY
}

metadata_json() {
  python3 - "$METADATA_PATH" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as handle:
        try:
            payload = json.load(handle)
        except Exception:
            payload = {}
else:
    payload = {}

print(json.dumps(payload, separators=(",", ":")))
PY
}

write_metadata_json() {
  local payload="$1"
  printf '%s\n' "$payload" >"$METADATA_PATH"
}

append_history_event() {
  local event_type="$1"
  local summary="$2"
  local metadata_payload="$3"
  local event_at
  event_at="$(now_utc)"

  python3 - "$HISTORY_PATH" "$event_type" "$summary" "$event_at" "$metadata_payload" <<'PY'
import json
import os
import sys
import uuid

path, event_type, summary, event_at, metadata_raw = sys.argv[1:6]
metadata = json.loads(metadata_raw)
entry = {
    "event_id": f"runner_{uuid.uuid4().hex[:12]}",
    "event_type": event_type,
    "at": event_at,
    "summary": summary,
    "metadata": metadata,
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(entry, separators=(",", ":")) + "\n")
PY
}

write_release_manifest() {
  local manifest_path="$1"
  local commit_sha="$2"
  local git_ref="$3"
  local promoted_at="$4"
  local install_root="$5"
  local preflight_command="$6"
  local smoke_command="$7"
  local preflight_completed_at="$8"
  local smoke_completed_at="$9"
  local build_tool_versions="${10}"

  python3 - "$manifest_path" "$commit_sha" "$git_ref" "$REPO_URL" "$promoted_at" "$install_root" "$preflight_command" "$smoke_command" "$preflight_completed_at" "$smoke_completed_at" "$build_tool_versions" <<'PY'
import json
import os
import sys

(manifest_path, commit_sha, git_ref, repo_url, promoted_at, install_root, preflight_command, smoke_command,
 preflight_completed_at, smoke_completed_at, build_tool_versions_raw) = sys.argv[1:12]

payload = {
    "commit_sha": commit_sha,
    "promoted_ref": git_ref,
    "repo_url": repo_url,
    "promotion_timestamp": promoted_at,
    "install_root": install_root,
    "preflight_command": preflight_command,
    "smoke_command": smoke_command,
    "preflight_completed_at": preflight_completed_at,
    "smoke_completed_at": smoke_completed_at,
    "tool_versions": json.loads(build_tool_versions_raw),
}

os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

atomic_update_current_link() {
  local target="$1"
  local temp_link="$INSTALL_ROOT/.current.tmp.$$"

  rm -f "$temp_link"
  ln -s "$target" "$temp_link"

  python3 - "$temp_link" "$CURRENT_LINK" <<'PY'
import os
import sys

temp_link, current_link = sys.argv[1:3]
os.replace(temp_link, current_link)
PY
}

promote_runner() {
  if [[ $# -lt 1 ]]; then
    usage
  fi

  local git_ref="$1"
  shift
  local canary_labels=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --canary-label)
        [[ $# -ge 2 ]] || usage
        canary_labels+=("$2")
        shift 2
        ;;
      *)
        echo "Unknown promote option: $1" >&2
        usage
        ;;
    esac
  done

  if [[ ${#canary_labels[@]} -eq 0 ]]; then
    canary_labels=("$DEFAULT_CANARY_LABEL")
  fi

  ensure_install_root
  require_python

  local tmp_root
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/symphony-runner-promote.XXXXXX")"
  trap 'rm -rf "'"$tmp_root"'"' RETURN

  git clone --depth 1 "$REPO_URL" "$tmp_root/repo"
  git -C "$tmp_root/repo" fetch --depth 1 origin "$git_ref"
  git -C "$tmp_root/repo" checkout --detach FETCH_HEAD

  local commit_sha promoted_at release_dir release_manifest_path current_target previous_metadata
  local preflight_command smoke_command preflight_completed_at smoke_completed_at build_tool_versions
  local promotion_host promotion_user metadata_payload history_metadata

  commit_sha="$(git -C "$tmp_root/repo" rev-parse HEAD)"
  promoted_at="$(now_utc)"
  release_dir="$RELEASES_DIR/$commit_sha"
  release_manifest_path="$release_dir/manifest.json"
  current_target="$(current_link_target || true)"
  previous_metadata="$(metadata_json)"
  preflight_command="./scripts/symphony-preflight.sh"
  smoke_command="./scripts/symphony-smoke.sh"

  "$tmp_root/repo/scripts/symphony-preflight.sh"
  preflight_completed_at="$(now_utc)"

  "$tmp_root/repo/scripts/symphony-smoke.sh"
  smoke_completed_at="$(now_utc)"

  build_tool_versions="$(build_tool_versions_json)"
  promotion_host="$(hostname 2>/dev/null || uname -n)"
  promotion_user="$(id -un)"

  rm -rf "$release_dir"
  mkdir -p "$release_dir"
  rsync -a --delete --exclude '.git' "$tmp_root/repo/" "$release_dir/"
  write_release_manifest \
    "$release_manifest_path" \
    "$commit_sha" \
    "$git_ref" \
    "$promoted_at" \
    "$INSTALL_ROOT" \
    "$preflight_command" \
    "$smoke_command" \
    "$preflight_completed_at" \
    "$smoke_completed_at" \
    "$build_tool_versions"
  atomic_update_current_link "$release_dir"

  metadata_payload="$(
    python3 - "$METADATA_PATH" "$commit_sha" "$git_ref" "$promoted_at" "$release_dir" "$release_manifest_path" "$current_target" "$REPO_URL" "$build_tool_versions" "$preflight_completed_at" "$smoke_completed_at" "$promotion_host" "$promotion_user" "${canary_labels[@]}" <<'PY'
import json
import os
import sys

metadata_path = sys.argv[1]
commit_sha = sys.argv[2]
git_ref = sys.argv[3]
promoted_at = sys.argv[4]
release_dir = sys.argv[5]
release_manifest_path = sys.argv[6]
current_target = sys.argv[7]
repo_url = sys.argv[8]
build_tool_versions = json.loads(sys.argv[9])
preflight_completed_at = sys.argv[10]
smoke_completed_at = sys.argv[11]
promotion_host = sys.argv[12]
promotion_user = sys.argv[13]
canary_labels = sys.argv[14:]

if os.path.exists(metadata_path):
    with open(metadata_path, "r", encoding="utf-8") as handle:
        try:
            existing = json.load(handle)
        except Exception:
            existing = {}
else:
    existing = {}

previous_release_path = current_target or existing.get("promoted_release_path")
previous_release_sha = os.path.basename(previous_release_path.rstrip("/")) if previous_release_path else existing.get("promoted_release_sha")

payload = {
    "current_version_sha": commit_sha,
    "promoted_release_sha": commit_sha,
    "promoted_ref": git_ref,
    "promoted_at": promoted_at,
    "promoted_release_path": release_dir,
    "previous_release_sha": previous_release_sha,
    "previous_release_path": previous_release_path,
    "runner_mode": "canary_active",
    "canary_required_labels": canary_labels,
    "canary_started_at": promoted_at,
    "canary_recorded_at": None,
    "canary_result": None,
    "canary_note": None,
    "canary_evidence": {"issues": [], "prs": []},
    "rollback_recommended": False,
    "repo_url": repo_url,
    "release_manifest_path": release_manifest_path,
    "build_tool_versions": build_tool_versions,
    "preflight_completed_at": preflight_completed_at,
    "smoke_completed_at": smoke_completed_at,
    "promotion_host": promotion_host,
    "promotion_user": promotion_user,
}

print(json.dumps(payload, indent=2, sort_keys=True))
PY
  )"

  write_metadata_json "$metadata_payload"

  history_metadata="$(
    python3 - "$commit_sha" "$git_ref" "$release_dir" "$release_manifest_path" "$preflight_completed_at" "$smoke_completed_at" "$build_tool_versions" "${canary_labels[@]}" <<'PY'
import json
import sys

commit_sha = sys.argv[1]
git_ref = sys.argv[2]
release_dir = sys.argv[3]
release_manifest_path = sys.argv[4]
preflight_completed_at = sys.argv[5]
smoke_completed_at = sys.argv[6]
build_tool_versions = json.loads(sys.argv[7])
canary_labels = sys.argv[8:]

print(json.dumps({
    "current_version_sha": commit_sha,
    "promoted_release_sha": commit_sha,
    "promoted_ref": git_ref,
    "promoted_release_path": release_dir,
    "release_manifest_path": release_manifest_path,
    "runner_mode": "canary_active",
    "canary_required_labels": canary_labels,
    "preflight_completed_at": preflight_completed_at,
    "smoke_completed_at": smoke_completed_at,
    "build_tool_versions": build_tool_versions,
}))
PY
  )"

  append_history_event \
    "runner.promoted" \
    "Promoted runner ${commit_sha} from ${git_ref} in canary mode." \
    "$history_metadata"

  echo "Promoted Symphony runner $commit_sha from $git_ref"
}

inspect_runner() {
  ensure_install_root
  require_python

  python3 - "$METADATA_PATH" "$CURRENT_LINK" "$HISTORY_PATH" <<'PY'
import json
import os
import sys

metadata_path, current_link, history_path = sys.argv[1:4]

if os.path.exists(metadata_path):
    with open(metadata_path, "r", encoding="utf-8") as handle:
        try:
            metadata = json.load(handle)
        except Exception:
            metadata = {}
else:
    metadata = {}

history = []
if os.path.exists(history_path):
    with open(history_path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                history.append(json.loads(line))
            except Exception:
                continue
    history = history[-10:]

current_link_target = os.path.realpath(current_link) if os.path.islink(current_link) else None
release_manifest_path = metadata.get("release_manifest_path") or (os.path.join(current_link_target, "manifest.json") if current_link_target else None)
release_manifest = None
if release_manifest_path and os.path.exists(release_manifest_path):
    try:
        with open(release_manifest_path, "r", encoding="utf-8") as handle:
            release_manifest = json.load(handle)
    except Exception:
        release_manifest = None

payload = dict(metadata)
payload["current_link_target"] = current_link_target
payload["release_manifest"] = release_manifest
payload["history"] = history

print(json.dumps(payload, indent=2, sort_keys=True))
PY
}

record_canary() {
  [[ $# -ge 1 ]] || usage

  local result="$1"
  shift
  local note=""
  local issues=()
  local prs=()

  case "$result" in
    pass|fail) ;;
    *)
      echo "record-canary requires pass or fail" >&2
      exit 1
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note)
        [[ $# -ge 2 ]] || usage
        note="$2"
        shift 2
        ;;
      --issue)
        [[ $# -ge 2 ]] || usage
        issues+=("$2")
        shift 2
        ;;
      --pr)
        [[ $# -ge 2 ]] || usage
        prs+=("$2")
        shift 2
        ;;
      *)
        echo "Unknown record-canary option: $1" >&2
        usage
        ;;
    esac
  done

  ensure_install_root
  require_python

  if [[ ! -f "$METADATA_PATH" ]]; then
    echo "No runner metadata found at $METADATA_PATH" >&2
    exit 1
  fi

  local recorded_at metadata_payload history_metadata runner_mode rollback_recommended summary issues_json prs_json
  recorded_at="$(now_utc)"
  issues_json="$(json_array "${issues[@]-}")"
  prs_json="$(json_array "${prs[@]-}")"

  if [[ "$result" == "pass" ]]; then
    runner_mode="stable"
    rollback_recommended="false"
    summary="Recorded canary pass for the current runner."
  else
    runner_mode="canary_failed"
    rollback_recommended="true"
    summary="Recorded canary failure for the current runner."
  fi

  metadata_payload="$(
    python3 - "$METADATA_PATH" "$result" "$recorded_at" "$runner_mode" "$rollback_recommended" "$note" "$issues_json" "$prs_json" <<'PY'
import json
import sys

metadata_path, result, recorded_at, runner_mode, rollback_recommended, note, issues_raw, prs_raw = sys.argv[1:9]
with open(metadata_path, "r", encoding="utf-8") as handle:
    metadata = json.load(handle)

metadata["runner_mode"] = runner_mode
metadata["canary_recorded_at"] = recorded_at
metadata["canary_result"] = result
metadata["canary_note"] = note or None
metadata["canary_evidence"] = {
    "issues": json.loads(issues_raw),
    "prs": json.loads(prs_raw),
}
metadata["rollback_recommended"] = rollback_recommended == "true"

print(json.dumps(metadata, indent=2, sort_keys=True))
PY
  )"

  write_metadata_json "$metadata_payload"

  history_metadata="$(
    python3 - "$result" "$note" "$runner_mode" "$rollback_recommended" "$issues_json" "$prs_json" <<'PY'
import json
import sys

result, note, runner_mode, rollback_recommended, issues_raw, prs_raw = sys.argv[1:7]
print(json.dumps({
    "canary_result": result,
    "canary_note": note or None,
    "runner_mode": runner_mode,
    "rollback_recommended": rollback_recommended == "true",
    "canary_evidence": {
        "issues": json.loads(issues_raw),
        "prs": json.loads(prs_raw),
    },
}))
PY
  )"

  append_history_event "runner.canary.recorded" "$summary" "$history_metadata"
  echo "$summary"
}

rollback_runner() {
  local target_sha="${1:-}"

  ensure_install_root
  require_python

  if [[ ! -f "$METADATA_PATH" ]]; then
    echo "No runner metadata found at $METADATA_PATH" >&2
    exit 1
  fi

  local current_target current_sha
  current_target="$(current_link_target || true)"

  if [[ -z "$target_sha" ]]; then
    target_sha="$(
      python3 - "$METADATA_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    metadata = json.load(handle)

print(metadata.get("previous_release_sha") or "")
PY
    )"
  fi

  if [[ -z "$target_sha" ]]; then
    echo "No previous release is available for rollback" >&2
    exit 1
  fi

  local target_dir="$RELEASES_DIR/$target_sha"
  if [[ ! -d "$target_dir" ]]; then
    echo "Rollback target release does not exist: $target_dir" >&2
    exit 1
  fi

  current_sha=""
  if [[ -n "$current_target" ]]; then
    current_sha="$(basename "$current_target")"
  fi

  atomic_update_current_link "$target_dir"

  local rolled_back_at metadata_payload history_metadata
  rolled_back_at="$(now_utc)"

  metadata_payload="$(
    python3 - "$METADATA_PATH" "$target_sha" "$target_dir" "$current_sha" "$current_target" "$rolled_back_at" "$DEFAULT_CANARY_LABEL" <<'PY'
import json
import os
import sys

metadata_path, target_sha, target_dir, current_sha, current_target, rolled_back_at, default_canary_label = sys.argv[1:8]
with open(metadata_path, "r", encoding="utf-8") as handle:
    metadata = json.load(handle)

manifest_path = os.path.join(target_dir, "manifest.json")
manifest = {}
if os.path.exists(manifest_path):
    try:
        with open(manifest_path, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
    except Exception:
        manifest = {}

metadata["current_version_sha"] = target_sha
metadata["promoted_release_sha"] = target_sha
metadata["promoted_ref"] = manifest.get("promoted_ref") or target_sha
metadata["promoted_at"] = rolled_back_at
metadata["promoted_release_path"] = target_dir
metadata["previous_release_sha"] = current_sha or metadata.get("previous_release_sha")
metadata["previous_release_path"] = current_target or metadata.get("previous_release_path")
metadata["runner_mode"] = "stable"
metadata["canary_required_labels"] = metadata.get("canary_required_labels") or [default_canary_label]
metadata["canary_started_at"] = None
metadata["canary_recorded_at"] = None
metadata["canary_result"] = None
metadata["canary_note"] = None
metadata["canary_evidence"] = {"issues": [], "prs": []}
metadata["rollback_recommended"] = False
metadata["repo_url"] = manifest.get("repo_url") or metadata.get("repo_url")
metadata["release_manifest_path"] = manifest_path
metadata["build_tool_versions"] = manifest.get("tool_versions") or metadata.get("build_tool_versions")
metadata["preflight_completed_at"] = manifest.get("preflight_completed_at") or metadata.get("preflight_completed_at")
metadata["smoke_completed_at"] = manifest.get("smoke_completed_at") or metadata.get("smoke_completed_at")

print(json.dumps(metadata, indent=2, sort_keys=True))
PY
  )"

  write_metadata_json "$metadata_payload"

  history_metadata="$(
    python3 - "$target_sha" "$target_dir" "$current_sha" "$current_target" <<'PY'
import json
import os
import sys

target_sha, target_dir, previous_sha, previous_target = sys.argv[1:5]
print(json.dumps({
    "rolled_back_to_sha": target_sha,
    "rolled_back_to_path": target_dir,
    "rolled_back_to_manifest": os.path.join(target_dir, "manifest.json"),
    "replaced_release_sha": previous_sha or None,
    "replaced_release_path": previous_target or None,
}))
PY
  )"

  append_history_event \
    "runner.rollback.completed" \
    "Rolled back runner to ${target_sha}." \
    "$history_metadata"

  echo "Rolled back Symphony runner to $target_sha"
}

main() {
  [[ $# -ge 1 ]] || usage

  local command="$1"
  shift

  case "$command" in
    promote)
      promote_runner "$@"
      ;;
    inspect)
      inspect_runner
      ;;
    record-canary)
      record_canary "$@"
      ;;
    rollback)
      rollback_runner "$@"
      ;;
    *)
      echo "Unknown command: $command" >&2
      usage
      ;;
  esac
}

main "$@"
