---
tracker:
  kind: linear
  project_slug: "7262055276bc"
  handoff_mode: assignee
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 30000
  healing_interval_ms: 120000
workspace:
  root: /tmp/symphony-workspaces-mainproof-20260319
hooks:
  after_create: |
    git clone --no-single-branch https://github.com/gaspardip/symphony .
    git fetch origin main:refs/remotes/origin/main
    git branch --set-upstream-to=origin/main main
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 3
policy:
  require_checkout: true
  require_pr_before_review: true
  require_validation: true
  require_verifier: true
  retry_validation_failures_within_run: true
  max_validation_attempts_per_run: 2
  publish_required: true
  post_merge_verification_required: true
  automerge_on_green: true
  default_issue_class: fully_autonomous
  stop_on_noop_turn: true
  max_noop_turns: 1
  token_budget:
    per_turn_input: 150000
    per_issue_total: 500000
runner:
  instance_name: symphony-mainproof
  channel: canary
  self_host_project: true
codex:
  stall_timeout_ms: 900000
  command: codex --model gpt-5.4 app-server
  reasoning:
    stages:
      implement: balanced
      verify: deep
      verifier: rigorous
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---
