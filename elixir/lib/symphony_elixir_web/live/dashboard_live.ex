defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:control_result, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket =
      case Presenter.refresh_payload(orchestrator()) do
        {:ok, payload} ->
          socket
          |> assign(:payload, load_payload())
          |> assign(:control_result, payload)
          |> put_flash(:info, "Refresh queued")

        {:error, _reason} ->
          put_flash(socket, :error, "Refresh failed")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("control", %{"issue_identifier" => issue_identifier, "action" => action} = params, socket) do
    socket =
      case Presenter.control_payload(action, issue_identifier, params, orchestrator()) do
        {:ok, %{ok: true} = payload} ->
          socket
          |> assign(:payload, load_payload())
          |> assign(:control_result, payload)
          |> put_flash(:info, "#{payload.action} applied to #{payload.issue_identifier}")

        {:ok, %{ok: false} = payload} ->
          socket
          |> assign(:payload, load_payload())
          |> assign(:control_result, payload)
          |> put_flash(:error, payload.error || "Control failed")

        {:error, _reason} ->
          put_flash(socket, :error, "Control failed")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Active agents, queue pressure, policy gates, and operator controls for the current Symphony runtime.
            </p>
            <div class="hero-meta">
              <span class="hero-meta-item">Snapshot <span class="mono numeric"><%= @payload.generated_at %></span></span>
              <span class="hero-meta-item">Poll every <span class="numeric"><%= format_millis((@payload[:polling] || %{})[:poll_interval_ms]) %></span></span>
              <span class="hero-meta-item">Runner <span class="mono"><%= Map.get(@payload.runner || %{}, :instance_name, "default") %></span></span>
              <span class="hero-meta-item">Mode <span class="mono"><%= Map.get(@payload.runner || %{}, :runner_mode, "stable") %></span></span>
              <span class="hero-meta-item">Version <span class="mono"><%= short_sha(Map.get(@payload.runner || %{}, :current_version_sha)) %></span></span>
              <span class="hero-meta-item">Promoted <span class="mono"><%= short_sha(Map.get(@payload.runner || %{}, :promoted_release_sha)) %></span></span>
            </div>
          </div>

          <div class="status-stack">
            <button type="button" class="subtle-button" phx-click="refresh">
              Refresh now
            </button>
            <%= if (@payload[:polling] || %{})[:checking?] do %>
              <span class="status-badge status-badge-warn">
                <span class="status-badge-dot"></span>
                Polling now
              </span>
            <% end %>
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Paused</p>
            <p class="metric-value numeric"><%= @payload.counts.paused %></p>
            <p class="metric-detail">Issues explicitly paused by an operator.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Queue</p>
            <p class="metric-value numeric"><%= @payload.counts.queue %></p>
            <p class="metric-detail numeric">
              Next poll in <%= format_millis((@payload[:polling] || %{})[:next_poll_in_ms]) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Skipped</p>
            <p class="metric-value numeric"><%= @payload.counts.skipped %></p>
            <p class="metric-detail">Active issues ignored by the configured label gate.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Runner lifecycle</h2>
              <p class="section-copy">Stable runner version, canary scope, and rollback posture for the current install root.</p>
            </div>
          </div>

          <div class="run-body">
            <section class="run-panel">
              <p class="panel-label">Identity</p>
              <div class="data-list">
                <div class="data-row">
                  <span class="data-key">Instance</span>
                  <span class="data-value mono"><%= Map.get(@payload.runner || %{}, :instance_name, "default") %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Mode</span>
                  <span class={tone_badge_class(runner_mode_tone(Map.get(@payload.runner || %{}, :runner_mode)))}>
                    <%= Map.get(@payload.runner || %{}, :runner_mode, "stable") %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Dispatch</span>
                  <span class={tone_badge_class(if(Map.get(@payload.runner || %{}, :dispatch_enabled, true), do: "good", else: "danger"))}>
                    <%= if Map.get(@payload.runner || %{}, :dispatch_enabled, true), do: "enabled", else: "disabled" %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Health</span>
                  <span class={tone_badge_class(runner_health_tone(Map.get(@payload.runner || %{}, :runner_health)))}>
                    <%= Map.get(@payload.runner || %{}, :runner_health, "healthy") %>
                  </span>
                </div>
                <%= if present?(Map.get(@payload.runner || %{}, :runner_health_rule_id)) do %>
                  <div class="data-row">
                    <span class="data-key">Health rule</span>
                    <span class="data-value mono"><%= Map.get(@payload.runner || %{}, :runner_health_rule_id) %></span>
                  </div>
                <% end %>
                <div class="data-row">
                  <span class="data-key">Install root</span>
                  <span class="data-value mono" title={Map.get(@payload.runner || %{}, :install_root) || "n/a"}>
                    <%= truncate_middle(Map.get(@payload.runner || %{}, :install_root), 64) %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Current link</span>
                  <span class="data-value mono" title={Map.get(@payload.runner || %{}, :current_link_target) || "n/a"}>
                    <%= truncate_middle(Map.get(@payload.runner || %{}, :current_link_target), 64) %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Current</span>
                  <span class="data-value mono"><%= short_sha(Map.get(@payload.runner || %{}, :current_version_sha)) %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Promoted</span>
                  <span class="data-value mono"><%= short_sha(Map.get(@payload.runner || %{}, :promoted_release_sha)) %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Previous</span>
                  <span class="data-value mono"><%= short_sha(Map.get(@payload.runner || %{}, :previous_release_sha)) %></span>
                </div>
              </div>
            </section>

            <section class="run-panel">
              <p class="panel-label">Canary routing</p>
              <div class="data-list">
                <div class="data-row">
                  <span class="data-key">Dogfood labels</span>
                  <span class="data-value mono"><%= join_labels(Map.get(@payload.runner || %{}, :effective_required_labels, [])) %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Canary labels</span>
                  <span class="data-value mono"><%= join_labels(Map.get(@payload.runner || %{}, :canary_required_labels, [])) %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Canary started</span>
                  <span class="data-value mono"><%= Map.get(@payload.runner || %{}, :canary_started_at) || "n/a" %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Canary result</span>
                  <span class="data-value"><%= Map.get(@payload.runner || %{}, :canary_result) || "pending" %></span>
                </div>
                <%= if present?(Map.get(@payload.runner || %{}, :canary_note)) do %>
                  <div class="data-row">
                    <span class="data-key">Canary note</span>
                    <span class="data-value"><%= Map.get(@payload.runner || %{}, :canary_note) %></span>
                  </div>
                <% end %>
                <%= if non_empty_list?(get_in(@payload.runner || %{}, [:canary_evidence, :issues])) do %>
                  <div class="data-row">
                    <span class="data-key">Evidence issues</span>
                    <span class="data-value mono"><%= join_labels(get_in(@payload.runner || %{}, [:canary_evidence, :issues])) %></span>
                  </div>
                <% end %>
                <%= if non_empty_list?(get_in(@payload.runner || %{}, [:canary_evidence, :prs])) do %>
                  <div class="data-row">
                    <span class="data-key">Evidence PRs</span>
                    <span class="data-value mono"><%= join_labels(get_in(@payload.runner || %{}, [:canary_evidence, :prs])) %></span>
                  </div>
                <% end %>
              </div>
            </section>

            <section class="run-panel">
              <p class="panel-label">Rollback posture</p>
              <div class="data-list">
                <div class="data-row">
                  <span class="data-key">Recommendation</span>
                  <span class={tone_badge_class(if(Map.get(@payload.runner || %{}, :rollback_recommended), do: "warn", else: "good"))}>
                    <%= if Map.get(@payload.runner || %{}, :rollback_recommended), do: "rollback recommended", else: "healthy" %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Rule</span>
                  <span class="data-value mono"><%= Map.get(@payload.runner || %{}, :rule_id) || Map.get(@payload.runner || %{}, :rollback_rule_id) || "n/a" %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Rollback target</span>
                  <span class="data-value mono"><%= short_sha(Map.get(@payload.runner || %{}, :previous_release_sha)) %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Target exists</span>
                  <span class={tone_badge_class(if(Map.get(@payload.runner || %{}, :rollback_target_exists), do: "good", else: "danger"))}>
                    <%= if Map.get(@payload.runner || %{}, :rollback_target_exists), do: "available", else: "missing" %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Promoted at</span>
                  <span class="data-value mono"><%= Map.get(@payload.runner || %{}, :promoted_at) || "n/a" %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Recorded at</span>
                  <span class="data-value mono"><%= Map.get(@payload.runner || %{}, :canary_recorded_at) || "n/a" %></span>
                </div>
              </div>
            </section>

            <section class="run-panel">
              <p class="panel-label">Provenance</p>
              <div class="data-list">
                <div class="data-row">
                  <span class="data-key">Repo</span>
                  <span class="data-value mono" title={Map.get(@payload.runner || %{}, :repo_url) || "n/a"}>
                    <%= truncate_middle(Map.get(@payload.runner || %{}, :repo_url), 48) %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Manifest</span>
                  <span class="data-value mono" title={Map.get(@payload.runner || %{}, :release_manifest_path) || "n/a"}>
                    <%= truncate_middle(Map.get(@payload.runner || %{}, :release_manifest_path), 56) %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Promoted by</span>
                  <span class="data-value mono">
                    <%= [Map.get(@payload.runner || %{}, :promotion_user), Map.get(@payload.runner || %{}, :promotion_host)] |> Enum.filter(&present?/1) |> Enum.join("@") |> case do "" -> "n/a"; value -> value end %>
                  </span>
                </div>
                <div class="data-row">
                  <span class="data-key">Preflight</span>
                  <span class="data-value mono"><%= Map.get(@payload.runner || %{}, :preflight_completed_at) || "n/a" %></span>
                </div>
                <div class="data-row">
                  <span class="data-key">Smoke</span>
                  <span class="data-value mono"><%= Map.get(@payload.runner || %{}, :smoke_completed_at) || "n/a" %></span>
                </div>
                <%= if is_map(Map.get(@payload.runner || %{}, :release_manifest)) do %>
                  <div class="data-row">
                    <span class="data-key">Manifest ref</span>
                    <span class="data-value mono"><%= manifest_value(Map.get(@payload.runner || %{}, :release_manifest), "promoted_ref") || "n/a" %></span>
                  </div>
                  <div class="data-row">
                    <span class="data-key">Manifest SHA</span>
                    <span class="data-value mono"><%= short_sha(manifest_value(Map.get(@payload.runner || %{}, :release_manifest), "commit_sha")) %></span>
                  </div>
                <% end %>
              </div>
            </section>
          </div>
          <%= if present?(Map.get(@payload.runner || %{}, :runner_health_summary)) do %>
            <p class="section-copy">
              <strong>Runner health:</strong> <%= Map.get(@payload.runner || %{}, :runner_health_summary) %>
              <%= if present?(Map.get(@payload.runner || %{}, :runner_health_human_action)) do %>
                <span> Next action: <%= Map.get(@payload.runner || %{}, :runner_health_human_action) %></span>
              <% end %>
            </p>
          <% end %>
        </section>

        <section class="insight-grid">
          <section class="section-card section-card-accent section-card-main">
            <div class="section-header">
              <div>
                <h2 class="section-title">Running agents</h2>
                <p class="section-copy">Live workspaces, policy gates, review state, and the most recent agent activity.</p>
              </div>
            </div>

            <%= if @payload.running == [] do %>
              <p class="empty-state">No active sessions.</p>
            <% else %>
              <div class="run-grid">
                <article class="run-card" :for={entry <- @payload.running}>
                  <header class="run-card-header">
                    <div class="run-heading">
                      <div class="run-heading-row">
                        <span class={state_badge_class(entry.state)}><%= entry.state %></span>
                        <span class={tone_badge_class(stage_tone(entry.stage))}><%= entry.stage || "unknown stage" %></span>
                        <span class="run-eyebrow mono"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></span>
                      </div>
                      <h3 class="run-title"><%= entry.issue_identifier %></h3>
                      <p class="run-copy" title={entry.last_message || to_string(entry.last_event || "n/a")}>
                        <%= entry.last_message || to_string(entry.last_event || "n/a") %>
                      </p>
                    </div>

                    <div class="run-actions">
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy session"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy session
                        </button>
                      <% end %>
                      <button type="button" class="subtle-button" phx-click="control" phx-value-action="pause" phx-value-issue_identifier={entry.issue_identifier}>Pause</button>
                      <button type="button" class="subtle-button" phx-click="control" phx-value-action="hold_for_human_review" phx-value-issue_identifier={entry.issue_identifier}>Hold</button>
                      <button type="button" class="subtle-button" phx-click="control" phx-value-action="stop" phx-value-issue_identifier={entry.issue_identifier}>Stop</button>
                      <button type="button" class="subtle-button" phx-click="control" phx-value-action="boost" phx-value-issue_identifier={entry.issue_identifier}>Boost</button>
                      <button type="button" class="subtle-button" phx-click="control" phx-value-action="set_policy_class" phx-value-policy_class="review_required" phx-value-issue_identifier={entry.issue_identifier}>Require review</button>
                      <button type="button" class="subtle-button" phx-click="control" phx-value-action="set_policy_class" phx-value-policy_class="never_automerge" phx-value-issue_identifier={entry.issue_identifier}>Never automerge</button>
                      <button type="button" class="subtle-button" phx-click="control" phx-value-action="clear_policy_override" phx-value-issue_identifier={entry.issue_identifier}>Clear policy</button>
                    </div>
                  </header>

                  <div class="run-pill-row">
                    <span class={tone_badge_class(entry.policy.checkout.tone)}><%= entry.policy.checkout.label %></span>
                    <span class={tone_badge_class(entry.policy.validation.tone)}><%= entry.policy.validation.label %></span>
                    <span class={tone_badge_class(entry.policy.pr_gate.tone)}><%= entry.policy.pr_gate.label %></span>
                    <span class={tone_badge_class(entry.policy.merge_gate.tone)}><%= entry.policy.merge_gate.label %></span>
                    <span class={tone_badge_class(if(entry.routing.eligible, do: "good", else: "warn"))}>
                      <%= if entry.routing.eligible, do: "Dogfood label matched", else: "Missing dogfood label" %>
                    </span>
                    <span class={tone_badge_class(if(entry.policy_source == "override", do: "warn", else: "info"))}>
                      Policy <%= entry.policy_class || "unknown" %> · <%= entry.policy_source || "n/a" %>
                    </span>
                  </div>

                  <div class="run-glance-grid">
                    <div class="glance-card">
                      <p class="glance-label">Current turn</p>
                      <p class="glance-value numeric"><%= format_budget(entry.tokens.current_turn_input_tokens, entry.policy.token_budget.per_turn_input.limit) %></p>
                      <div class="budget-meter">
                        <span style={"width: #{budget_width(entry.policy.token_budget.per_turn_input.current, entry.policy.token_budget.per_turn_input.limit)}%;"}></span>
                      </div>
                      <p class="glance-detail numeric">
                        Remaining <%= format_signed_int(entry.policy.token_budget.per_turn_input.remaining) %>
                      </p>
                    </div>

                    <div class="glance-card">
                      <p class="glance-label">Issue total</p>
                      <p class="glance-value numeric"><%= format_budget(entry.tokens.total_tokens, entry.policy.token_budget.per_issue_total.limit) %></p>
                      <div class="budget-meter">
                        <span style={"width: #{budget_width(entry.policy.token_budget.per_issue_total.current, entry.policy.token_budget.per_issue_total.limit)}%;"}></span>
                      </div>
                      <p class="glance-detail numeric">
                        Remaining <%= format_signed_int(entry.policy.token_budget.per_issue_total.remaining) %>
                      </p>
                    </div>

                    <div class="glance-card">
                      <p class="glance-label">Workspace</p>
                      <p class="glance-value mono"><%= entry.workspace.branch || "no-branch" %> @ <%= short_sha(entry.workspace.head_sha) %></p>
                      <p class="glance-detail">
                        <%= truncate_middle(entry.workspace.origin_url || "no remote", 40) %> · Base <%= entry.workspace.base_branch || "main" %>
                      </p>
                    </div>

                    <div class="glance-card">
                      <p class="glance-label">Review</p>
                      <p class="glance-value"><%= entry.review.review_decision || entry.review.pr_state || "No review yet" %></p>
                      <p class="glance-detail">
                        <%= if entry.review.pr_url do %>
                          <a class="issue-link" href={entry.review.pr_url} target="_blank">Open PR</a>
                        <% else %>
                          PR not attached
                        <% end %>
                      </p>
                    </div>
                  </div>

                  <div class="run-body">
                    <section class="run-panel">
                      <p class="panel-label">Workspace</p>
                      <div class="data-list">
                        <div class="data-row">
                          <span class="data-key">Path</span>
                          <span class="data-value mono" title={entry.workspace.path}><%= truncate_middle(entry.workspace.path, 58) %></span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Git</span>
                          <span class="data-value"><%= if entry.workspace.git?, do: "Checkout verified", else: "Missing .git" %></span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Origin</span>
                          <span class="data-value mono" title={entry.workspace.origin_url || "missing"}><%= truncate_middle(entry.workspace.origin_url || "missing", 52) %></span>
                        </div>
                        <%= if present?(entry.workspace.status_text) do %>
                          <div class="data-row">
                            <span class="data-key">Status</span>
                            <span class="data-value mono" title={entry.workspace.status_text}><%= truncate_middle(entry.workspace.status_text, 96) %></span>
                          </div>
                        <% end %>
                      </div>
                    </section>

                    <section class="run-panel">
                      <p class="panel-label">Harness</p>
                      <div class="data-list">
                        <div class="data-row">
                          <span class="data-key">Contract</span>
                          <span class="data-value mono" title={entry.harness.path || "missing"}><%= truncate_middle(entry.harness.path || "missing", 52) %></span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Preflight</span>
                          <span class="data-value mono" title={entry.harness.preflight_command || "missing"}><%= truncate_middle(entry.harness.preflight_command || "missing", 52) %></span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Validation</span>
                          <span class="data-value mono" title={entry.harness.validation_command || "missing"}><%= truncate_middle(entry.harness.validation_command || "missing", 52) %></span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Smoke</span>
                          <span class="data-value mono" title={entry.harness.smoke_command || "missing"}><%= truncate_middle(entry.harness.smoke_command || "missing", 52) %></span>
                        </div>
                      </div>
                    </section>

                    <section class="run-panel">
                      <p class="panel-label">Checks</p>
                      <%= if entry.review.required_checks == [] and entry.review.check_statuses == [] do %>
                        <p class="panel-copy">No required checks configured yet.</p>
                      <% else %>
                        <div class="check-list">
                          <div class="check-row" :for={check <- Enum.take(entry.review.check_statuses, 6)}>
                            <span class="check-name"><%= check.name || "unnamed check" %></span>
                            <span class={tone_badge_class(check_tone(check.conclusion || check.status))}>
                              <%= check.conclusion || check.status || "pending" %>
                            </span>
                          </div>
                          <div class="check-row" :for={required <- missing_required_checks(entry.review)}>
                            <span class="check-name"><%= required %></span>
                            <span class={tone_badge_class("warn")}>missing</span>
                          </div>
                        </div>
                      <% end %>
                    </section>

                    <section class="run-panel">
                      <p class="panel-label">Decision</p>
                      <div class="data-list">
                        <div class="data-row">
                          <span class="data-key">Rule</span>
                          <span class="data-value mono"><%= entry.last_rule_id || "n/a" %></span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Failure class</span>
                          <span class="data-value"><%= entry.last_failure_class || "n/a" %></span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Next action</span>
                          <span class="data-value"><%= entry.next_human_action || "No operator action required." %></span>
                        </div>
                        <%= if entry.last_ledger_event_id do %>
                          <div class="data-row">
                            <span class="data-key">Ledger</span>
                            <span class="data-value mono"><%= entry.last_ledger_event_id %></span>
                          </div>
                        <% end %>
                      </div>
                    </section>

                    <section class="run-panel">
                      <p class="panel-label">Publish</p>
                      <div class="data-list">
                        <div class="data-row">
                          <span class="data-key">PR body</span>
                          <span class={tone_badge_class(command_tone(entry.publish.pr_body_validation && entry.publish.pr_body_validation.status))}>
                            <%= command_label(entry.publish.pr_body_validation, "unknown") %>
                          </span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Validation</span>
                          <span class={tone_badge_class(command_tone(entry.publish.last_validation && entry.publish.last_validation.status))}>
                            <%= command_label(entry.publish.last_validation, "not-run") %>
                          </span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Verifier</span>
                          <span class={tone_badge_class(command_tone(entry.publish.last_verifier && entry.publish.last_verifier.status))}>
                            <%= command_label(entry.publish.last_verifier, "not-run") %>
                          </span>
                        </div>
                        <div class="data-row">
                          <span class="data-key">Post-merge</span>
                          <span class={tone_badge_class(command_tone(entry.publish.last_post_merge && entry.publish.last_post_merge.status))}>
                            <%= command_label(entry.publish.last_post_merge, "not-run") %>
                          </span>
                        </div>
                      </div>
                    </section>

                    <section class="run-panel run-panel-wide">
                      <div class="panel-header">
                        <p class="panel-label">Activity trail</p>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                      <%= if entry.recent_activity == [] do %>
                        <p class="panel-copy">No recent activity captured yet.</p>
                      <% else %>
                        <div class="activity-list">
                          <div class="activity-row" :for={activity <- entry.recent_activity}>
                            <span class={tone_badge_class(activity.tone)}><%= activity.source %></span>
                            <div class="activity-copy">
                              <p><%= activity.message %></p>
                              <span class="muted mono"><%= activity.event %> · <%= activity.at %></span>
                            </div>
                          </div>
                        </div>
                      <% end %>
                    </section>
                  </div>
                </article>
              </div>
            <% end %>
          </section>

          <div class="stack-column">
            <section class="section-card section-card-dark">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Global activity</h2>
                  <p class="section-copy">Latest operator and runtime events across the queue.</p>
                </div>
              </div>

              <%= if @payload.activity == [] do %>
                <p class="empty-state">No activity captured yet.</p>
              <% else %>
                <div class="activity-feed">
                  <div class="activity-feed-item" :for={activity <- @payload.activity}>
                    <div class="activity-feed-head">
                      <span class={tone_badge_class(activity.tone)}><%= activity.issue_identifier || activity.source %></span>
                      <span class="muted mono"><%= activity.at %></span>
                    </div>
                    <p class="activity-feed-copy"><%= activity.message %></p>
                    <p class="activity-feed-meta muted"><%= activity.event %> · <%= activity.source %></p>
                  </div>
                </div>
              <% end %>
            </section>

            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Rate limits</h2>
                  <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
                </div>
              </div>

              <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
            </section>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <div class="session-stack">
                          <button type="button" class="subtle-button" phx-click="control" phx-value-action="retry_now" phx-value-issue_identifier={entry.issue_identifier}>Retry now</button>
                          <button type="button" class="subtle-button" phx-click="control" phx-value-action="boost" phx-value-issue_identifier={entry.issue_identifier}>Boost</button>
                        </div>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %><%= if entry.priority_override != nil, do: " · override=#{entry.priority_override}" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Paused issues</h2>
              <p class="section-copy">Issues manually paused until an operator resumes them.</p>
            </div>
          </div>

          <%= if @payload.paused == [] do %>
            <p class="empty-state">No paused issues.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 640px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Resume state</th>
                    <th>Policy</th>
                    <th>Control</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.paused}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.resume_state %></td>
                    <td><%= entry.policy_class || "n/a" %></td>
                    <td>
                      <button type="button" class="subtle-button" phx-click="control" phx-value-action="resume" phx-value-issue_identifier={entry.issue_identifier}>Resume</button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Skipped issues</h2>
              <p class="section-copy">Active issues skipped because routing labels or policy labels make them ineligible.</p>
            </div>
          </div>

          <%= if @payload.skipped == [] do %>
            <p class="empty-state">No active issues are currently being skipped by label gating.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 720px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Required labels</th>
                    <th>Current labels</th>
                    <th>Reason</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.skipped}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><span class={state_badge_class(entry.state)}><%= entry.state %></span></td>
                    <td><span class="mono"><%= Enum.join(entry.required_labels, ", ") %></span></td>
                    <td><span class="mono"><%= Enum.join(entry.labels, ", ") %></span></td>
                    <td><span class="mono"><%= entry.reason %></span></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Ranked queue</h2>
              <p class="section-copy">Dispatch order after operator overrides, Linear priority, age, and retry penalty.</p>
            </div>
          </div>

          <%= if @payload.queue == [] do %>
            <p class="empty-state">No queued issues.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 720px;">
                <thead>
                  <tr>
                    <th>Rank</th>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Priority</th>
                    <th>Retry penalty</th>
                    <th>Policy</th>
                    <th>Controls</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.queue}>
                    <td class="numeric"><%= entry.rank %></td>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><span class={state_badge_class(entry.state)}><%= entry.state %></span></td>
                    <td>
                      <span class="numeric"><%= entry.operator_override || entry.linear_priority || "n/a" %></span>
                      <span class="muted"><%= if entry.operator_override != nil, do: "operator override", else: "linear priority" %></span>
                    </td>
                    <td class="numeric"><%= entry.retry_penalty %></td>
                    <td><span class="mono"><%= entry.policy_class || "n/a" %></span></td>
                    <td>
                      <div class="session-stack">
                        <button type="button" class="subtle-button" phx-click="control" phx-value-action="boost" phx-value-issue_identifier={entry.issue_identifier}>Boost</button>
                        <button type="button" class="subtle-button" phx-click="control" phx-value-action="reset_priority" phx-value-issue_identifier={entry.issue_identifier}>Reset</button>
                        <button type="button" class="subtle-button" phx-click="control" phx-value-action="set_policy_class" phx-value-policy_class="review_required" phx-value-issue_identifier={entry.issue_identifier}>Require review</button>
                        <button type="button" class="subtle-button" phx-click="control" phx-value-action="clear_policy_override" phx-value-issue_identifier={entry.issue_identifier}>Clear policy</button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    sign = if value < 0, do: "-", else: ""

    digits =
      value
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/.{3}(?=.)/, "\\0,")
      |> String.reverse()

    sign <> digits
  end

  defp format_int(_value), do: "n/a"

  defp format_signed_int(nil), do: "n/a"
  defp format_signed_int(value) when is_integer(value), do: format_int(value)
  defp format_signed_int(_value), do: "n/a"

  defp format_millis(nil), do: "n/a"

  defp format_millis(value) when is_integer(value) do
    value
    |> max(0)
    |> div(1_000)
    |> format_runtime_seconds()
  end

  defp format_millis(_value), do: "n/a"

  defp short_sha(nil), do: "n/a"

  defp short_sha(value) do
    value
    |> to_string()
    |> String.slice(0, 8)
  end

  defp truncate_middle(nil, _max), do: "n/a"

  defp truncate_middle(value, max) when is_binary(value) and is_integer(max) and max > 6 do
    if String.length(value) <= max do
      value
    else
      head = div(max - 1, 2)
      tail = max - head - 1
      String.slice(value, 0, head) <> "…" <> String.slice(value, -tail, tail)
    end
  end

  defp truncate_middle(value, _max), do: to_string(value)

  defp join_labels(labels) when is_list(labels) do
    case Enum.reject(labels, &is_nil/1) do
      [] -> "n/a"
      filtered -> Enum.join(filtered, ", ")
    end
  end

  defp join_labels(_labels), do: "n/a"

  defp runner_mode_tone("canary_active"), do: "warn"
  defp runner_mode_tone("canary_failed"), do: "danger"
  defp runner_mode_tone("stable"), do: "good"
  defp runner_mode_tone(_mode), do: "muted"

  defp runner_health_tone("healthy"), do: "good"
  defp runner_health_tone("not_required"), do: "muted"
  defp runner_health_tone("invalid"), do: "danger"
  defp runner_health_tone(_status), do: "muted"

  defp format_budget(current, nil), do: format_int(current)

  defp format_budget(current, limit) when is_integer(current) and is_integer(limit) do
    "#{format_int(current)} / #{format_int(limit)}"
  end

  defp format_budget(current, _limit), do: format_int(current)

  defp budget_width(_current, nil), do: 0

  defp budget_width(current, limit) when is_integer(current) and is_integer(limit) and limit > 0 do
    current
    |> Kernel./(limit)
    |> Kernel.*(100)
    |> min(100)
    |> max(0)
    |> trunc()
  end

  defp budget_width(_current, _limit), do: 0

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["review", "merge"]) -> "#{base} state-badge-info"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp tone_badge_class(tone) do
    "tone-badge " <>
      case tone do
        "good" -> "tone-badge-good"
        "warn" -> "tone-badge-warn"
        "danger" -> "tone-badge-danger"
        "info" -> "tone-badge-info"
        _ -> "tone-badge-muted"
      end
  end

  defp check_tone(value) when is_binary(value) do
    normalized = String.downcase(String.trim(value))

    cond do
      normalized in ["success", "approved", "completed"] -> "good"
      normalized in ["failure", "failed", "error", "cancelled", "canceled"] -> "danger"
      normalized in ["pending", "queued", "in_progress", "in progress", "action_required"] -> "warn"
      true -> "muted"
    end
  end

  defp check_tone(_value), do: "muted"

  defp stage_tone(nil), do: "muted"

  defp stage_tone(stage) do
    case stage |> to_string() |> String.trim() |> String.downcase() do
      value when value in ["implement", "validate", "verify", "publish"] -> "info"
      value when value in ["await_checks", "merge", "post_merge"] -> "warn"
      value when value in ["done"] -> "good"
      value when value in ["blocked"] -> "danger"
      _ -> "muted"
    end
  end

  defp command_tone(nil), do: "muted"

  defp command_tone(status) do
    case status |> to_string() |> String.trim() |> String.downcase() do
      "passed" -> "good"
      "skipped" -> "muted"
      "failed" -> "danger"
      "unavailable" -> "warn"
      _ -> "muted"
    end
  end

  defp command_label(nil, fallback), do: fallback

  defp command_label(result, fallback) when is_map(result) do
    case result.status do
      value when is_binary(value) and value != "" -> value
      _ -> fallback
    end
  end

  defp command_label(_result, fallback), do: fallback

  defp missing_required_checks(review) do
    required = review.required_checks || []

    existing =
      review.check_statuses
      |> Enum.map(&(&1.name || ""))
      |> MapSet.new()

    Enum.reject(required, &MapSet.member?(existing, &1))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp non_empty_list?(value) when is_list(value), do: value != []
  defp non_empty_list?(_value), do: false

  defp manifest_value(manifest, key) when is_map(manifest) do
    Map.get(manifest, key) ||
      try do
        Map.get(manifest, String.to_existing_atom(key))
      rescue
        _error -> nil
      end
  rescue
    _error -> nil
  end

  defp manifest_value(_manifest, _key), do: nil

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  @doc false
  def helper_for_test(:runtime_seconds_from_started_at, [started_at, now]),
    do: runtime_seconds_from_started_at(started_at, now)

  def helper_for_test(:format_int, [value]), do: format_int(value)
  def helper_for_test(:format_signed_int, [value]), do: format_signed_int(value)
  def helper_for_test(:format_millis, [value]), do: format_millis(value)
  def helper_for_test(:short_sha, [value]), do: short_sha(value)
  def helper_for_test(:truncate_middle, [value, max]), do: truncate_middle(value, max)
  def helper_for_test(:join_labels, [labels]), do: join_labels(labels)
  def helper_for_test(:runner_health_tone, [value]), do: runner_health_tone(value)
  def helper_for_test(:format_budget, [current, limit]), do: format_budget(current, limit)
  def helper_for_test(:budget_width, [current, limit]), do: budget_width(current, limit)
  def helper_for_test(:check_tone, [value]), do: check_tone(value)
  def helper_for_test(:stage_tone, [value]), do: stage_tone(value)
  def helper_for_test(:command_tone, [value]), do: command_tone(value)
  def helper_for_test(:command_label, [value, fallback]), do: command_label(value, fallback)
  def helper_for_test(:missing_required_checks, [review]), do: missing_required_checks(review)
  def helper_for_test(:present, [value]), do: present?(value)
  def helper_for_test(:non_empty_list, [value]), do: non_empty_list?(value)
  def helper_for_test(:manifest_value, [manifest, key]), do: manifest_value(manifest, key)
  def helper_for_test(:pretty_value, [value]), do: pretty_value(value)
end
