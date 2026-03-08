defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  # credo:disable-for-this-file

  alias SymphonyElixir.{Config, Orchestrator, RunLedger, RunStateStore, StatusDashboard, Tracker}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    base_payload = base_payload(generated_at)

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        ledger_entries = RunLedger.recent_entries(200)
        ledger_by_issue = ledger_entries_by_issue(ledger_entries)
        runner_payload = Map.get(snapshot, :runner, %{})
        running = Enum.map(snapshot.running, &running_entry_payload(&1, ledger_by_issue))

        %{
          base_payload
          | generated_at: generated_at,
            counts: %{
              running: length(snapshot.running),
              retrying: length(snapshot.retrying),
              paused: length(Map.get(snapshot, :paused, [])),
              queue: length(Map.get(snapshot, :queue, [])),
              skipped: length(Map.get(snapshot, :skipped, []))
            },
            running: running,
            retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
            paused: Enum.map(Map.get(snapshot, :paused, []), &paused_entry_payload/1),
            skipped: Enum.map(Map.get(snapshot, :skipped, []), &skipped_entry_payload/1),
            queue: Enum.map(Map.get(snapshot, :queue, []), &queue_entry_payload/1),
            activity: global_activity_payload(running, ledger_entries, Map.get(runner_payload, :history, [])),
            priority_overrides: Map.get(snapshot, :priority_overrides, %{}),
            policy_overrides: Map.get(snapshot, :policy_overrides, %{}),
            codex_totals: snapshot.codex_totals,
            rate_limits: snapshot.rate_limits,
            runner: runner_payload,
            polling: Map.get(snapshot, :polling, %{})
        }

      :timeout ->
        Map.put(base_payload, :error, %{code: "snapshot_timeout", message: "Snapshot timed out"})

      :unavailable ->
        Map.put(base_payload, :error, %{code: "snapshot_unavailable", message: "Snapshot unavailable"})
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
        %{} = snapshot ->
          running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
          retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
          paused = Enum.find(Map.get(snapshot, :paused, []), &(&1.identifier == issue_identifier))
          queue = Enum.find(Map.get(snapshot, :queue, []), &(&1.issue_identifier == issue_identifier))
          ledger_entries = RunLedger.recent_entries(100)
          ledger_by_issue = ledger_entries_by_issue(ledger_entries)

        case issue_payload_body(issue_identifier, running, retry, paused, queue, ledger_by_issue) do
          nil -> {:error, :issue_not_found}
          payload -> {:ok, payload}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec control_payload(String.t(), String.t(), map(), GenServer.name()) :: {:ok, map()} | {:error, term()}
  def control_payload(action, issue_identifier, params, orchestrator)
      when is_binary(action) and is_binary(issue_identifier) and is_map(params) do
    result =
      case action do
        "pause" ->
          Orchestrator.pause_issue(orchestrator, issue_identifier)

        "resume" ->
          Orchestrator.resume_issue(orchestrator, issue_identifier)

        "stop" ->
          Orchestrator.stop_issue(orchestrator, issue_identifier)

        "hold_for_human_review" ->
          Orchestrator.hold_issue_for_human_review(orchestrator, issue_identifier)

        "retry_now" ->
          Orchestrator.retry_issue_now(orchestrator, issue_identifier)

        "approve_for_merge" ->
          Orchestrator.approve_issue_for_merge(orchestrator, issue_identifier)

        "reprioritize" ->
          Orchestrator.reprioritize_issue(
            orchestrator,
            issue_identifier,
            parse_override_rank(params["override_rank"])
          )

        "boost" ->
          Orchestrator.reprioritize_issue(orchestrator, issue_identifier, 0)

        "reset_priority" ->
          Orchestrator.reprioritize_issue(orchestrator, issue_identifier, nil)

        "set_policy_class" ->
          Orchestrator.set_policy_class(orchestrator, issue_identifier, to_string(params["policy_class"] || ""))

        "clear_policy_override" ->
          Orchestrator.clear_policy_override(orchestrator, issue_identifier)

        _ ->
          {:error, :unknown_action}
      end

    case result do
      :unavailable -> {:error, :unavailable}
      %{ok: _} = payload -> {:ok, payload}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unknown_action}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, paused, queue, ledger_by_issue) do
    running_payload = running && running_entry_payload(running, ledger_by_issue)
    decision_history = decision_history_payload(Map.get(ledger_by_issue, issue_identifier, []))
    workspace_path = Path.join(Config.workspace_root(), issue_identifier)
    run_state = load_issue_run_state(workspace_path)
    tracked_issue = tracked_issue_payload(issue_identifier)

    if is_nil(running) and is_nil(retry) and is_nil(paused) and is_nil(queue) and is_nil(run_state) and is_nil(tracked_issue) do
      nil
    else
      %{
        issue_identifier: issue_identifier,
        issue_id: issue_id_from_entries(running, retry, paused, queue) || entry_value(tracked_issue || %{}, "id") || Map.get(run_state || %{}, :issue_id),
        status: issue_status(running, retry, paused, queue, tracked_issue, run_state),
        workspace: %{
          path: workspace_path
        },
        attempts: %{
          restart_count: restart_count(retry),
          current_retry_attempt: retry_attempt(retry)
        },
        running: running_payload,
        retry: retry && retry_issue_payload(retry),
        paused: paused,
        queue: queue,
        logs: %{
          codex_session_logs: []
        },
        recent_events: (running_payload && running_payload.recent_activity) || [],
        decision_history: decision_history,
        last_error: retry && retry.error,
        tracked: tracked_issue || %{},
        last_decision: normalize_command_result(Map.get(run_state || %{}, :last_decision)),
        last_rule_id: Map.get(run_state || %{}, :last_rule_id),
        last_failure_class: Map.get(run_state || %{}, :last_failure_class),
        next_human_action: Map.get(run_state || %{}, :next_human_action)
      }
    end
  end

  defp issue_id_from_entries(running, retry, paused, queue),
    do:
      (running && running.issue_id) || (retry && retry.issue_id) || (paused && paused.issue_id) ||
        (queue && queue.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, _retry, paused, _queue, _tracked_issue, _run_state) when not is_nil(paused), do: "paused"
  defp issue_status(_running, nil, _paused, nil, nil, %{} = run_state), do: Map.get(run_state, :stage) || "tracked"
  defp issue_status(_running, nil, _paused, nil, %{} = tracked_issue, _run_state), do: entry_value(tracked_issue, "state") || "tracked"
  defp issue_status(_running, nil, _paused, nil, nil, nil), do: "running"
  defp issue_status(nil, _retry, _paused, nil, _tracked_issue, _run_state), do: "retrying"
  defp issue_status(nil, nil, _paused, _queue, _tracked_issue, _run_state), do: "queued"
  defp issue_status(_running, _retry, _paused, _queue, _tracked_issue, _run_state), do: "running"

  defp running_entry_payload(entry, ledger_by_issue) do
    workspace = workspace_payload(entry)
    harness = harness_payload(entry)
    review = review_payload(entry)
    policy = policy_payload(entry, workspace, harness, review)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      stage: Map.get(entry, :stage),
      stage_history: Map.get(entry, :stage_history, []),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      workspace: workspace,
      harness: harness,
      review: review,
      publish: publish_payload(entry),
      routing: routing_payload(entry),
      policy: policy,
      policy_class: Map.get(entry, :policy_class),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      next_human_action: Map.get(entry, :next_human_action),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id),
      last_decision: normalize_command_result(Map.get(entry, :last_decision)),
      recent_activity:
        recent_activity_payload(
          Map.get(entry, :recent_codex_updates, []),
          Map.get(ledger_by_issue, entry.identifier, [])
        ),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens,
        current_turn_input_tokens: Map.get(entry, :current_turn_input_tokens, 0)
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      attempt: Map.get(entry, :attempt),
      due_at: due_at_iso8601(Map.get(entry, :due_in_ms)),
      error: Map.get(entry, :error),
      priority_override: Map.get(entry, :priority_override),
      policy_class: Map.get(entry, :policy_class),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      next_human_action: Map.get(entry, :next_human_action),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id)
    }
  end

  defp paused_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      resume_state: entry.resume_state,
      policy_class: Map.get(entry, :policy_class),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      next_human_action: Map.get(entry, :next_human_action),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id)
    }
  end

  defp skipped_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :issue_identifier),
      state: Map.get(entry, :state),
      labels: Map.get(entry, :labels, []),
      required_labels: Map.get(entry, :required_labels, []),
      reason: Map.get(entry, :reason),
      policy_class: Map.get(entry, :policy_class),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      next_human_action: Map.get(entry, :next_human_action),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id)
    }
  end

  defp queue_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      state: entry.state,
      rank: entry.rank,
      linear_priority: entry.linear_priority,
      operator_override: entry.operator_override,
      retry_penalty: entry.retry_penalty,
      labels: Map.get(entry, :labels, []),
      required_labels: Map.get(entry, :required_labels, []),
      label_gate_eligible: Map.get(entry, :label_gate_eligible, true),
      policy_class: Map.get(entry, :policy_class),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      next_human_action: Map.get(entry, :next_human_action),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id)
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: Map.get(retry, :attempt),
      due_at: due_at_iso8601(Map.get(retry, :due_in_ms)),
      error: Map.get(retry, :error),
      priority_override: Map.get(retry, :priority_override)
    }
  end

  defp workspace_payload(entry) do
    %{
      path: Map.get(entry, :workspace),
      checkout?: Map.get(entry, :checkout?, false),
      git?: Map.get(entry, :git?, false),
      origin_url: Map.get(entry, :origin_url),
      branch: Map.get(entry, :branch),
      head_sha: Map.get(entry, :head_sha),
      dirty?: Map.get(entry, :dirty?, false),
      changed_files: Map.get(entry, :changed_files, 0),
      status_text: Map.get(entry, :status_text),
      base_branch: Map.get(entry, :base_branch)
    }
  end

  defp harness_payload(entry) do
    %{
      path: Map.get(entry, :harness_path),
      version: Map.get(entry, :harness_version),
      error: Map.get(entry, :harness_error),
      preflight_command: Map.get(entry, :preflight_command),
      validation_command: Map.get(entry, :validation_command),
      smoke_command: Map.get(entry, :smoke_command),
      post_merge_command: Map.get(entry, :post_merge_command),
      artifacts_command: Map.get(entry, :artifacts_command),
      required_checks: Map.get(entry, :required_checks, []),
      publish_required_checks: Map.get(entry, :publish_required_checks, []),
      ci_required_checks: Map.get(entry, :ci_required_checks, [])
    }
  end

  defp review_payload(entry) do
    required_checks =
      case Map.get(entry, :publish_required_checks, []) do
        [] -> Map.get(entry, :required_checks, [])
        checks -> checks
      end

    check_statuses = Map.get(entry, :check_statuses, [])

    %{
      pr_url: Map.get(entry, :pr_url),
      pr_state: Map.get(entry, :pr_state),
      review_decision: Map.get(entry, :review_decision),
      required_checks: required_checks,
      check_statuses: check_statuses,
      required_checks_passed: required_checks_passed?(required_checks, check_statuses),
      ready_for_merge: Map.get(entry, :ready_for_merge, false),
      missing_required_checks: missing_required_checks(required_checks, check_statuses)
    }
  end

  defp publish_payload(entry) do
    %{
      pr_body_validation: normalize_command_result(Map.get(entry, :last_pr_body_validation)),
      last_validation: normalize_command_result(Map.get(entry, :last_validation)),
      last_verifier: normalize_command_result(Map.get(entry, :last_verifier)),
      last_verifier_verdict: Map.get(entry, :last_verifier_verdict),
      acceptance_summary: Map.get(entry, :acceptance_summary),
      last_post_merge: normalize_command_result(Map.get(entry, :last_post_merge)),
      merge_sha: Map.get(entry, :merge_sha),
      stop_reason: Map.get(entry, :stop_reason)
    }
  end

  defp routing_payload(entry) do
    %{
      labels: Map.get(entry, :labels, []),
      required_labels: Map.get(entry, :required_labels, []),
      eligible: Map.get(entry, :label_gate_eligible, true)
    }
  end

  defp policy_payload(entry, workspace, harness, review) do
    %{
      class: Map.get(entry, :policy_class),
      source: Map.get(entry, :policy_source),
      override: Map.get(entry, :policy_override),
      checkout: policy_checkout_payload(workspace),
      validation: policy_validation_payload(harness),
      pr_gate: policy_pr_gate_payload(review, entry.state),
      merge_gate: policy_merge_gate_payload(review),
      noop_guard: %{
        enabled: Config.policy_stop_on_noop_turn?(),
        max_noop_turns: Config.policy_max_noop_turns()
      },
      token_budget: policy_token_budget_payload(entry),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      next_human_action: Map.get(entry, :next_human_action),
      rules: %{
        checkout: decision_rule_payload(workspace.checkout?, workspace.git?, "checkout"),
        validation: decision_rule_payload(is_binary(harness.validation_command), is_nil(harness.error), "validation"),
        pr_gate: decision_rule_payload(is_binary(review.pr_url), true, "publish"),
        merge_gate: decision_rule_payload(review.ready_for_merge, true, "merge")
      }
    }
  end

  defp base_payload(generated_at) do
    %{
      generated_at: generated_at,
      counts: %{running: 0, retrying: 0, paused: 0, queue: 0, skipped: 0},
      running: [],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [],
      activity: [],
      priority_overrides: %{},
      policy_overrides: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      runner: %{},
      polling: %{checking?: false, next_poll_in_ms: nil, poll_interval_ms: nil}
    }
  end

  defp policy_checkout_payload(workspace) do
    cond do
      not Config.policy_require_checkout?() ->
        %{label: "Checkout optional", tone: "muted"}

      workspace.git? ->
        %{label: "Checkout verified", tone: "good"}

      workspace.checkout? ->
        %{label: "Directory exists, git missing", tone: "danger"}

      true ->
        %{label: "No checkout", tone: "danger"}
    end
  end

  defp policy_validation_payload(harness) do
    cond do
      not Config.policy_require_validation?() ->
        %{label: "Validation optional", tone: "muted"}

      not is_nil(harness.error) ->
        %{label: "Harness invalid", tone: "danger"}

      is_binary(harness.validation_command) and String.trim(harness.validation_command) != "" ->
        %{label: "Validation contract loaded", tone: "good"}

      true ->
        %{label: "Validation command missing", tone: "danger"}
    end
  end

  defp policy_pr_gate_payload(review, state) do
    cond do
      not Config.policy_require_pr_before_review?() ->
        %{label: "PR gate disabled", tone: "muted"}

      is_binary(review.pr_url) and normalize_state(state) == "human review" ->
        %{label: "Review state has PR", tone: "good"}

      is_binary(review.pr_url) ->
        %{label: "PR attached", tone: "good"}

      normalize_state(state) == "human review" ->
        %{label: "Human Review blocked without PR", tone: "danger"}

      true ->
        %{label: "Awaiting PR", tone: "warn"}
    end
  end

  defp policy_merge_gate_payload(review) do
    cond do
      review.ready_for_merge ->
        %{label: "Approved and checks green", tone: "good"}

      is_nil(review.pr_url) ->
        %{label: "No PR to merge", tone: "muted"}

      review.review_decision in ["APPROVED", "approved"] and not review.required_checks_passed ->
        %{label: "Awaiting required checks", tone: "warn"}

      review.required_checks_passed ->
        %{label: "Awaiting approval", tone: "warn"}

      true ->
        %{label: "Awaiting review and checks", tone: "warn"}
    end
  end

  defp policy_token_budget_payload(entry) do
    %{
      per_turn_input:
        budget_status_payload(
          Map.get(entry, :current_turn_input_tokens, 0),
          Config.policy_per_turn_input_budget()
        ),
      per_issue_total:
        budget_status_payload(
          Map.get(entry, :codex_total_tokens, 0),
          Config.policy_per_issue_total_budget()
        ),
      per_issue_total_output:
        budget_status_payload(
          Map.get(entry, :codex_output_tokens, 0),
          Config.policy_per_issue_total_output_budget()
        )
    }
  end

  defp budget_status_payload(current, nil) do
    %{current: current, limit: nil, remaining: nil, tone: "muted"}
  end

  defp budget_status_payload(current, limit) when is_integer(limit) do
    remaining = limit - current
    ratio = if limit == 0, do: 0.0, else: current / limit

    tone =
      cond do
        current > limit -> "danger"
        ratio >= 0.8 -> "warn"
        true -> "good"
      end

    %{current: current, limit: limit, remaining: remaining, tone: tone}
  end

  defp recent_activity_payload(codex_updates, ledger_entries) do
    (codex_activity_payload(codex_updates) ++ ledger_activity_payload(ledger_entries))
    |> Enum.sort_by(&activity_sort_key/1, :desc)
    |> Enum.take(10)
  end

  defp codex_activity_payload(codex_updates) when is_list(codex_updates) do
    Enum.map(codex_updates, fn update ->
      %{
        source: "codex",
        at: iso8601(Map.get(update, :timestamp) || Map.get(update, "timestamp")),
        event:
          Map.get(update, :event)
          |> Kernel.||(Map.get(update, "event"))
          |> to_string(),
        message: summarize_message(update),
        tone: codex_activity_tone(update)
      }
    end)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp codex_activity_payload(_codex_updates), do: []

  defp ledger_activity_payload(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      event = entry_value(entry, "event") || entry_value(entry, "event_type")

      %{
        source: "ledger",
        at: entry_value(entry, "at"),
        event: event,
        message: ledger_message(entry),
        tone: ledger_activity_tone(event)
      }
    end)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp ledger_activity_payload(_entries), do: []

  defp runner_activity_payload(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      event = entry_value(entry, "event_type") || entry_value(entry, "event")

      %{
        source: "runner",
        issue_identifier: "runner",
        at: entry_value(entry, "at"),
        event: event,
        message: runner_history_message(entry),
        tone: runner_activity_tone(event)
      }
    end)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp runner_activity_payload(_entries), do: []

  defp global_activity_payload(_running, ledger_entries, runner_history) do
    ledger_activity =
      ledger_entries
      |> ledger_activity_payload()
      |> Enum.map(fn entry ->
        Map.put(entry, :issue_identifier, entry_value(entry, "issue_identifier"))
      end)

    runner_activity =
      runner_history
      |> runner_activity_payload()
      |> Enum.sort_by(&activity_sort_key/1, :desc)
      |> Enum.take(4)

    ledger_limit = max(14 - length(runner_activity), 0)

    (Enum.take(ledger_activity, ledger_limit) ++ runner_activity)
    |> Enum.sort_by(&activity_sort_key/1, :desc)
  end

  defp ledger_message(entry) do
    summary =
      cond do
        value = entry_value(entry, "summary") -> value
        value = entry_value(entry, "rule_id") -> value
        value = entry_value(entry, "resume_state") -> "resume to #{value}"
        value = entry_value(entry, "target_state") -> "target state #{value}"
        true -> entry_value(entry, "event_type") || entry_value(entry, "event") || "ledger event"
      end

    details = entry_value(entry, "details")

    if is_binary(details) and String.trim(details) != "" and summary != details do
      "#{summary}: #{truncate_text(details, 120)}"
    else
      summary
    end
  end

  defp ledger_entries_by_issue(entries) do
    Enum.group_by(entries, fn entry ->
      entry_value(entry, "issue_identifier")
    end)
  end

  defp runner_history_message(entry) do
    summary = entry_value(entry, "summary") || entry_value(entry, "event_type") || "runner event"
    metadata = entry_value(entry, "metadata") || %{}
    note = entry_value(metadata, "canary_note")

    cond do
      is_binary(note) and String.trim(note) != "" -> "#{summary}: #{truncate_text(note, 120)}"
      true -> summary
    end
  end

  defp runner_activity_tone("runner.rollback.completed"), do: "warn"
  defp runner_activity_tone("runner.canary.recorded"), do: "info"
  defp runner_activity_tone("runner.promoted"), do: "good"
  defp runner_activity_tone(_event), do: "muted"

  defp required_checks_passed?([], _check_statuses), do: true

  defp required_checks_passed?(required_checks, check_statuses) do
    Enum.all?(required_checks, fn required_check ->
      Enum.any?(check_statuses, fn
        %{name: ^required_check, conclusion: conclusion} ->
          normalize_state(conclusion) == "success"

        _ ->
          false
      end)
    end)
  end

  defp missing_required_checks(required_checks, check_statuses) do
    present_checks =
      check_statuses
      |> Enum.map(&Map.get(&1, :name))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    Enum.reject(required_checks, &MapSet.member?(present_checks, &1))
  end

  defp normalize_command_result(nil), do: nil

  defp normalize_command_result(result) when is_map(result) do
    %{
      status: entry_value(result, "status"),
      command: entry_value(result, "command"),
      verdict: entry_value(result, "verdict"),
      rule_id: entry_value(result, "rule_id"),
      failure_class: entry_value(result, "failure_class"),
      summary: entry_value(result, "summary"),
      details: entry_value(result, "details"),
      human_action: entry_value(result, "human_action"),
      acceptance_gaps: entry_value(result, "acceptance_gaps"),
      risky_areas: entry_value(result, "risky_areas"),
      evidence: entry_value(result, "evidence"),
      acceptance: entry_value(result, "acceptance"),
      ledger_event_id: entry_value(result, "ledger_event_id"),
      output:
        result
        |> entry_value("output")
        |> case do
          value when is_binary(value) -> truncate_text(value, 240)
          nil -> nil
          value -> truncate_text(to_string(value), 240)
        end
    }
  end

  defp normalize_command_result(result), do: %{status: nil, command: nil, output: truncate_text(result, 240)}

  defp activity_sort_key(entry), do: Map.get(entry, :at) || ""

  defp codex_activity_tone(update) do
    event =
      Map.get(update, :event)
      |> Kernel.||(Map.get(update, "event"))
      |> normalize_state()

    cond do
      String.contains?(event, "error") or String.contains?(event, "fail") -> "danger"
      String.contains?(event, "tool") or String.contains?(event, "mcp") -> "info"
      String.contains?(event, "session") or String.contains?(event, "turn") -> "good"
      true -> "muted"
    end
  end

  defp ledger_activity_tone(event) do
    event = normalize_state(event)

    cond do
      String.contains?(event, "policy_stop") or String.contains?(event, "stop") -> "danger"
      String.contains?(event, "pause") or String.contains?(event, "retry") -> "warn"
      String.contains?(event, "merge") or String.contains?(event, "approve") -> "good"
      true -> "info"
    end
  end

  defp entry_value(entry, key) when is_map(entry) and is_binary(key),
    do: Map.get(entry, key) || existing_atom_value(entry, key)

  defp entry_value(_entry, _key), do: nil

  defp existing_atom_value(entry, key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    if atom_key, do: Map.get(entry, atom_key), else: nil
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp truncate_text(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max - 1) <> "…"
    end
  end

  defp truncate_text(text, _max), do: to_string(text)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp normalize_state(nil), do: ""

  defp normalize_state(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp parse_override_rank(nil), do: nil
  defp parse_override_rank(value) when is_integer(value), do: value

  defp parse_override_rank(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp load_issue_run_state(workspace_path) do
    case RunStateStore.load(workspace_path) do
      {:ok, run_state} -> run_state
      _ -> nil
    end
  end

  defp tracked_issue_payload(issue_identifier) do
    case Tracker.fetch_issue_by_identifier(issue_identifier) do
      {:ok, nil} -> nil
      {:ok, issue} when is_map(issue) -> issue
      _ -> nil
    end
  end

  defp decision_history_payload(entries) do
    entries
    |> Enum.map(fn entry ->
      %{
        event_id: entry_value(entry, "event_id"),
        event_type: entry_value(entry, "event_type") || entry_value(entry, "event"),
        at: entry_value(entry, "at"),
        stage: entry_value(entry, "stage"),
        actor_type: entry_value(entry, "actor_type"),
        actor_id: entry_value(entry, "actor_id"),
        policy_class: entry_value(entry, "policy_class"),
        failure_class: entry_value(entry, "failure_class"),
        rule_id: entry_value(entry, "rule_id"),
        summary: entry_value(entry, "summary"),
        details: entry_value(entry, "details"),
        target_state: entry_value(entry, "target_state"),
        metadata: entry_value(entry, "metadata") || %{}
      }
    end)
  end

  defp decision_rule_payload(ok?, supported?, family) do
    %{
      rule_id: "#{family}.status",
      status: if(ok?, do: "good", else: if(supported?, do: "warn", else: "danger")),
      summary: family,
      details: nil,
      human_action: nil
    }
  end

  @doc false
  def helper_for_test(:issue_status, [running, retry, paused, queue, tracked_issue, run_state]),
    do: issue_status(running, retry, paused, queue, tracked_issue, run_state)
  def helper_for_test(:codex_activity_payload, [updates]), do: codex_activity_payload(updates)
  def helper_for_test(:ledger_activity_payload, [entries]), do: ledger_activity_payload(entries)
  def helper_for_test(:runner_activity_payload, [entries]), do: runner_activity_payload(entries)
  def helper_for_test(:ledger_message, [entry]), do: ledger_message(entry)
  def helper_for_test(:runner_history_message, [entry]), do: runner_history_message(entry)
  def helper_for_test(:required_checks_passed, [required_checks, check_statuses]), do: required_checks_passed?(required_checks, check_statuses)
  def helper_for_test(:normalize_command_result, [result]), do: normalize_command_result(result)
  def helper_for_test(:codex_activity_tone, [update]), do: codex_activity_tone(update)
  def helper_for_test(:ledger_activity_tone, [event]), do: ledger_activity_tone(event)
  def helper_for_test(:entry_value, [entry, key]), do: entry_value(entry, key)
  def helper_for_test(:truncate_text, [text, max]), do: truncate_text(text, max)
  def helper_for_test(:due_at_iso8601, [value]), do: due_at_iso8601(value)
  def helper_for_test(:normalize_state, [value]), do: normalize_state(value)
  def helper_for_test(:parse_override_rank, [value]), do: parse_override_rank(value)
end
