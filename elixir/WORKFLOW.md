---
tracker:
  kind: linear
  project_slug: "symphony-0c79b11b75ea"
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
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
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
codex:
  command: codex --config model_reasoning_effort=high --model gpt-5.4 app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Retry attempt #{{ attempt }}. Resume from the existing workspace instead of restarting.
{% endif %}

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Status: {{ issue.state }}
- URL: {{ issue.url }}
- Labels: {{ issue.labels }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Runtime-owned delivery contract:

1. Work only inside the checked-out repository for this ticket.
2. Symphony owns branch setup, commits, pushes, PR publication, CI waiting, merges, and Linear state transitions.
3. Do not create commits, push branches, open or merge PRs, or move Linear issues yourself.
4. Use the repo harness commands as the only source of truth for validation expectations.
5. Keep shell usage tight: prefer targeted reads, avoid broad scans, and do not dump large files unless the result is directly needed.
6. End every implementation turn by calling `report_agent_turn_result` exactly once with:
   - `summary`
   - `files_touched`
   - `needs_another_turn`
   - `blocked`
   - `blocker_type`
7. Use `blocked=true` only for a true repo or local-environment blocker you cannot resolve from the checked-out code.
8. Use any prior validation or verifier output provided by Symphony to make the next change; do not recreate branch, PR, or state-management steps yourself.
