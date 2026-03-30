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
runner:
  channel: canary
polling:
  interval_ms: 600000
  healing_interval_ms: 1800000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/gaspardip/symphony.git .
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

Ticket `{{ issue.identifier }}`.

{% if attempt %}Retry attempt #{{ attempt }}. Resume from the existing workspace.{% endif %}

- Title: {{ issue.title }}
- Status: {{ issue.state }}
- URL: {{ issue.url }}
- Labels: {{ issue.labels }}

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Symphony owns branching, commits, PRs, checks, merges, and tracker state.
Do not perform those steps yourself.
Use the repo harness as the source of truth for validation and proof.
Keep shell usage narrow and avoid large output.
End each implementation turn by calling `report_agent_turn_result` exactly once.
