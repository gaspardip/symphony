#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELIXIR_DIR="$ROOT_DIR/elixir"
OBSERVABILITY_STACK="$ROOT_DIR/ops/observability/docker-compose.yml"
LOCAL_ROOT="${SYMPHONY_LOCAL_TOPOLOGY_ROOT:-$HOME/.local/state/symphony-local-topology}"
LOG_ROOT="${SYMPHONY_LOCAL_LOG_ROOT:-$ROOT_DIR/log/local-topology}"
OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}"
SERVER_HOST="${SYMPHONY_LOCAL_SERVER_HOST:-127.0.0.1}"
STABLE_PORT="${SYMPHONY_LOCAL_STABLE_PORT:-4040}"
CANARY_PORT="${SYMPHONY_LOCAL_CANARY_PORT:-4041}"
REQUIRED_LABELS="${SYMPHONY_LOCAL_REQUIRED_LABELS:-dogfood:symphony}"
TRACKER_KIND_OVERRIDE="${SYMPHONY_LOCAL_TRACKER_KIND:-}"
LINEAR_ENDPOINT="${SYMPHONY_LOCAL_LINEAR_ENDPOINT:-${LINEAR_ENDPOINT:-https://api.linear.app/graphql}}"
LINEAR_API_KEY_VALUE="${SYMPHONY_LOCAL_LINEAR_API_KEY:-${LINEAR_API_KEY:-}}"
LINEAR_PROJECT_SLUG_VALUE="${SYMPHONY_LOCAL_LINEAR_PROJECT_SLUG:-${LINEAR_PROJECT_SLUG:-}}"
LINEAR_WEBHOOK_SECRET_VALUE="${SYMPHONY_LOCAL_LINEAR_WEBHOOK_SECRET:-${LINEAR_WEBHOOK_SECRET:-}}"
LINEAR_ASSIGNEE_VALUE="${SYMPHONY_LOCAL_LINEAR_ASSIGNEE:-${LINEAR_ASSIGNEE:-}}"
GITHUB_WEBHOOK_SECRET_VALUE="${GITHUB_WEBHOOK_SECRET:-}"

STABLE_DIR="$LOCAL_ROOT/stable"
CANARY_DIR="$LOCAL_ROOT/canary"
STABLE_WORKFLOW="$STABLE_DIR/WORKFLOW.md"
CANARY_WORKFLOW="$CANARY_DIR/WORKFLOW.md"
STABLE_WORKSPACES="$LOCAL_ROOT/workspaces/stable"
CANARY_WORKSPACES="$LOCAL_ROOT/workspaces/canary"
STABLE_RUNNER_ROOT="$LOCAL_ROOT/runner/stable"
CANARY_RUNNER_ROOT="$LOCAL_ROOT/runner/canary"
STABLE_ARTIFACTS="$LOCAL_ROOT/artifacts/stable"
CANARY_ARTIFACTS="$LOCAL_ROOT/artifacts/canary"
STABLE_LOGS="$LOG_ROOT/stable"
CANARY_LOGS="$LOG_ROOT/canary"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") prepare
  $(basename "$0") show
  $(basename "$0") start-observability
  $(basename "$0") stop-observability
  $(basename "$0") start-stable
  $(basename "$0") start-canary

Environment:
  SYMPHONY_LOCAL_TRACKER_KIND=memory|linear
  SYMPHONY_LOCAL_LINEAR_API_KEY / LINEAR_API_KEY
  SYMPHONY_LOCAL_LINEAR_PROJECT_SLUG / LINEAR_PROJECT_SLUG
  SYMPHONY_LOCAL_LINEAR_WEBHOOK_SECRET / LINEAR_WEBHOOK_SECRET
  GITHUB_WEBHOOK_SECRET
  SYMPHONY_LOCAL_REQUIRED_LABELS=dogfood:symphony
  SYMPHONY_LOCAL_STABLE_PORT=4040
  SYMPHONY_LOCAL_CANARY_PORT=4041
EOF
}

resolve_tracker_kind() {
  if [[ -n "$TRACKER_KIND_OVERRIDE" ]]; then
    printf '%s\n' "$TRACKER_KIND_OVERRIDE"
    return
  fi

  if [[ -n "$LINEAR_API_KEY_VALUE" && -n "$LINEAR_PROJECT_SLUG_VALUE" ]]; then
    printf 'linear\n'
  else
    printf 'memory\n'
  fi
}

ensure_dirs() {
  mkdir -p \
    "$STABLE_DIR" \
    "$CANARY_DIR" \
    "$STABLE_WORKSPACES" \
    "$CANARY_WORKSPACES" \
    "$STABLE_RUNNER_ROOT" \
    "$CANARY_RUNNER_ROOT" \
    "$STABLE_ARTIFACTS" \
    "$CANARY_ARTIFACTS" \
    "$STABLE_LOGS" \
    "$CANARY_LOGS"
}

render_workflow() {
  local workflow_path="$1"
  local instance_name="$2"
  local channel="$3"
  local workspace_root="$4"
  local runner_root="$5"
  local artifact_root="$6"
  local server_port="$7"
  local tracker_kind="$8"

  TRACKER_KIND="$tracker_kind" \
  INSTANCE_NAME="$instance_name" \
  CHANNEL="$channel" \
  WORKSPACE_ROOT="$workspace_root" \
  RUNNER_ROOT="$runner_root" \
  ARTIFACT_ROOT="$artifact_root" \
  SERVER_PORT_VALUE="$server_port" \
  REQUIRED_LABELS_VALUE="$REQUIRED_LABELS" \
  LINEAR_ENDPOINT_VALUE="$LINEAR_ENDPOINT" \
  LINEAR_API_KEY_RENDERED="$LINEAR_API_KEY_VALUE" \
  LINEAR_PROJECT_SLUG_RENDERED="$LINEAR_PROJECT_SLUG_VALUE" \
  LINEAR_WEBHOOK_SECRET_RENDERED="$LINEAR_WEBHOOK_SECRET_VALUE" \
  LINEAR_ASSIGNEE_RENDERED="$LINEAR_ASSIGNEE_VALUE" \
  python3 - "$workflow_path" <<'PY'
import os
import sys

path = sys.argv[1]

def yaml_scalar(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)

    text = str(value).strip()
    if text == "":
        return "null"
    return "'" + text.replace("'", "''") + "'"

def yaml_list_csv(value):
    items = [item.strip() for item in (value or "").split(",") if item.strip()]
    if not items:
        return "[]"
    return "[" + ", ".join(yaml_scalar(item) for item in items) + "]"

tracker_kind = os.environ["TRACKER_KIND"]
instance_name = os.environ["INSTANCE_NAME"]
channel = os.environ["CHANNEL"]
workspace_root = os.environ["WORKSPACE_ROOT"]
runner_root = os.environ["RUNNER_ROOT"]
artifact_root = os.environ["ARTIFACT_ROOT"]
server_port = int(os.environ["SERVER_PORT_VALUE"])
required_labels = os.environ.get("REQUIRED_LABELS_VALUE", "")
linear_endpoint = os.environ.get("LINEAR_ENDPOINT_VALUE", "")
linear_api_key = os.environ.get("LINEAR_API_KEY_RENDERED", "")
linear_project_slug = os.environ.get("LINEAR_PROJECT_SLUG_RENDERED", "")
linear_webhook_secret = os.environ.get("LINEAR_WEBHOOK_SECRET_RENDERED", "")
linear_assignee = os.environ.get("LINEAR_ASSIGNEE_RENDERED", "")

tracker_endpoint = linear_endpoint if tracker_kind == "linear" else None
tracker_api_key = linear_api_key if tracker_kind == "linear" else None
tracker_project_slug = linear_project_slug if tracker_kind == "linear" else None
tracker_webhook_secret_value = linear_webhook_secret if tracker_kind == "linear" else None
tracker_assignee = linear_assignee if tracker_kind == "linear" else None

content = f"""---
tracker:
  kind: {yaml_scalar(tracker_kind)}
  endpoint: {yaml_scalar(tracker_endpoint)}
  api_key: {yaml_scalar(tracker_api_key)}
  webhook_secret: {yaml_scalar(tracker_webhook_secret_value)}
  project_slug: {yaml_scalar(tracker_project_slug)}
  assignee: {yaml_scalar(tracker_assignee)}
  handoff_mode: 'assignee'
  required_labels: {yaml_list_csv(required_labels)}
polling:
  interval_ms: 600000
  discovery_interval_ms: 600000
  healing_interval_ms: 1800000
workspace:
  root: {yaml_scalar(workspace_root)}
manual:
  enabled: true
runner:
  install_root: {yaml_scalar(runner_root)}
  instance_name: {yaml_scalar(instance_name)}
  channel: {yaml_scalar(channel)}
  self_host_project: true
company:
  repo_url: 'https://github.com/gaspardip/symphony'
  internal_project_name: 'Symphony'
  policy_pack: 'private_autopilot'
policy:
  default_issue_class: 'fully_autonomous'
  require_checkout: true
  require_pr_before_review: true
  require_validation: true
  require_verifier: true
  publish_required: true
  post_merge_verification_required: true
  automerge_on_green: true
observability:
  dashboard_enabled: true
  metrics_enabled: true
  metrics_path: '/metrics'
  tracing_enabled: true
  structured_logs: true
  debug_artifacts:
    enabled: true
    capture_on_failure: true
    root: {yaml_scalar(artifact_root)}
server:
  host: '127.0.0.1'
  port: {server_port}
---
You are the Symphony local {channel} runner.

Operate only within the configured workspace root and preserve the self-host workflow.
"""

with open(path, "w", encoding="utf-8") as handle:
    handle.write(content)
PY
}

prepare() {
  local tracker_kind
  tracker_kind="$(resolve_tracker_kind)"

  ensure_dirs
  render_workflow "$STABLE_WORKFLOW" "stable-local" "stable" "$STABLE_WORKSPACES" "$STABLE_RUNNER_ROOT" "$STABLE_ARTIFACTS" "$STABLE_PORT" "$tracker_kind"
  render_workflow "$CANARY_WORKFLOW" "canary-local" "canary" "$CANARY_WORKSPACES" "$CANARY_RUNNER_ROOT" "$CANARY_ARTIFACTS" "$CANARY_PORT" "$tracker_kind"
}

ensure_cli() {
  (
    cd "$ELIXIR_DIR"
    mise exec -- mix build
  )
}

show() {
  local tracker_kind
  tracker_kind="$(resolve_tracker_kind)"
  prepare

  cat <<EOF
Local topology prepared.

Tracker kind: $tracker_kind
Stable workflow: $STABLE_WORKFLOW
Canary workflow: $CANARY_WORKFLOW
Stable logs: $STABLE_LOGS
Canary logs: $CANARY_LOGS
Stable workspaces: $STABLE_WORKSPACES
Canary workspaces: $CANARY_WORKSPACES
Stable URL: http://127.0.0.1:$STABLE_PORT
Canary URL: http://127.0.0.1:$CANARY_PORT
Stable metrics: http://127.0.0.1:$STABLE_PORT/metrics
Canary metrics: http://127.0.0.1:$CANARY_PORT/metrics
GitHub webhook secret present: $( [[ -n "$GITHUB_WEBHOOK_SECRET_VALUE" ]] && printf yes || printf no )

Current limitation:
  Direct live PR review dogfooding should target the canary instance until the stable-ingress scheduler can forward events across processes.
EOF
}

start_observability() {
  docker compose -f "$OBSERVABILITY_STACK" up -d
}

stop_observability() {
  docker compose -f "$OBSERVABILITY_STACK" down
}

run_instance() {
  local instance="$1"
  local workflow_path logs_root port service_name

  prepare
  ensure_cli

  case "$instance" in
    stable)
      workflow_path="$STABLE_WORKFLOW"
      logs_root="$STABLE_LOGS"
      port="$STABLE_PORT"
      service_name="symphony-stable"
      ;;
    canary)
      workflow_path="$CANARY_WORKFLOW"
      logs_root="$CANARY_LOGS"
      port="$CANARY_PORT"
      service_name="symphony-canary"
      ;;
    *)
      echo "Unknown instance: $instance" >&2
      exit 1
      ;;
  esac

  cd "$ELIXIR_DIR"
  export OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_ENDPOINT"
  export OTEL_SERVICE_NAME="$service_name"
  export OTEL_SERVICE_NAMESPACE="symphony"
  export OTEL_DEPLOYMENT_ENVIRONMENT="local"
  export GITHUB_WEBHOOK_SECRET="${GITHUB_WEBHOOK_SECRET_VALUE:-}"

  exec mise exec -- bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --logs-root "$logs_root" \
    --port "$port" \
    "$workflow_path"
}

main() {
  local command="${1:-}"

  case "$command" in
    prepare)
      prepare
      show
      ;;
    show)
      show
      ;;
    start-observability)
      start_observability
      ;;
    stop-observability)
      stop_observability
      ;;
    start-stable)
      run_instance stable
      ;;
    start-canary)
      run_instance canary
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: $command" >&2
      usage
      ;;
  esac
}

main "$@"
