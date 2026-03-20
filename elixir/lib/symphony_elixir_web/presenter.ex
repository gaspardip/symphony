defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  # credo:disable-for-this-file

  alias SymphonyElixir.{
    Config,
    IssuePolicy,
    IssueSource,
    Orchestrator,
    PRWatcher,
    PolicyPack,
    Portfolio,
    RiskClassifier,
    RunInspector,
    RunLedger,
    RunPolicy,
    RunStateStore,
    RunnerRuntime,
    StatusDashboard,
    WorkflowProfile
  }

  alias SymphonyElixir.Linear.Issue
  @dialyzer {:nowarn_function, pr_watcher_payload: 4}

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
        retrying = Enum.map(snapshot.retrying, &retry_entry_payload/1)
        paused = Enum.map(Map.get(snapshot, :paused, []), &paused_entry_payload/1)
        skipped = Enum.map(Map.get(snapshot, :skipped, []), &skipped_entry_payload/1)
        queue = Enum.map(Map.get(snapshot, :queue, []), &queue_entry_payload/1)

        %{
          base_payload
          | generated_at: generated_at,
            company: company_payload(),
            counts: %{
              running: length(snapshot.running),
              retrying: length(snapshot.retrying),
              paused: length(Map.get(snapshot, :paused, [])),
              queue: length(Map.get(snapshot, :queue, [])),
              skipped: length(Map.get(snapshot, :skipped, []))
            },
            running: running,
            retrying: retrying,
            paused: paused,
            skipped: skipped,
            queue: queue,
            triage: triage_payload(running, retrying, paused, skipped, queue, ledger_entries),
            activity: global_activity_payload(running, ledger_entries, Map.get(runner_payload, :history, [])),
            priority_overrides: Map.get(snapshot, :priority_overrides, %{}),
            policy_overrides: Map.get(snapshot, :policy_overrides, %{}),
            pr_watcher: pr_watcher_payload(),
            codex_totals: snapshot.codex_totals,
            rate_limits: snapshot.rate_limits,
            runner: runner_payload,
            webhooks: Map.get(snapshot, :webhooks, %{}),
            github_webhooks: Map.get(snapshot, :github_webhooks, %{}),
            tracker_inbox: Map.get(snapshot, :tracker_inbox, %{}),
            github_inbox: Map.get(snapshot, :github_inbox, %{}),
            polling: Map.get(snapshot, :polling, %{})
        }

      :timeout ->
        Map.put(base_payload, :error, %{code: "snapshot_timeout", message: "Snapshot timed out"})

      :unavailable ->
        Map.put(base_payload, :error, %{code: "snapshot_unavailable", message: "Snapshot unavailable"})
    end
  end

  @spec delivery_report_payload(GenServer.name(), timeout()) :: map()
  def delivery_report_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        ledger_entries = RunLedger.recent_entries(300)
        ledger_by_issue = ledger_entries_by_issue(ledger_entries)

        deliveries =
          ledger_entries
          |> recent_delivery_issue_identifiers()
          |> Enum.map(&delivery_report_entry(&1, snapshot, ledger_by_issue))
          |> Enum.reject(&is_nil/1)

        %{
          generated_at: generated_at,
          company: company_payload(),
          summary: %{
            recent_deliveries: length(deliveries),
            deploys_involved: Enum.count(deliveries, &delivery_involved?(&1, :deploy)),
            approvals_involved: Enum.count(deliveries, &delivery_involved?(&1, :approval)),
            autonomous_finishes: Enum.count(deliveries, &(&1.status == "Done"))
          },
          deliveries: deliveries
        }

      _ ->
        %{
          generated_at: generated_at,
          company: company_payload(),
          summary: %{
            recent_deliveries: 0,
            deploys_involved: 0,
            approvals_involved: 0,
            autonomous_finishes: 0
          },
          deliveries: []
        }
    end
  end

  @spec portfolio_payload() :: map()
  def portfolio_payload do
    Map.put(Portfolio.summary(), :generated_at, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        paused = Enum.find(Map.get(snapshot, :paused, []), &(&1.identifier == issue_identifier))

        queue =
          Enum.find(Map.get(snapshot, :queue, []), fn entry ->
            Map.get(entry, :issue_identifier) == issue_identifier
          end)

        ledger_entries = RunLedger.recent_entries(100)
        ledger_by_issue = ledger_entries_by_issue(ledger_entries)

        case issue_payload_body(issue_identifier, running, retry, paused, queue, ledger_by_issue) do
          nil ->
            {:error, :issue_not_found}

          payload ->
            workspace_path = get_in(payload, [:workspace, :path])

            pr_url =
              normalize_pr_url(
                get_in(payload, [:review, :pr_url]) ||
                  get_in(payload, [:runner, :pr_url]) ||
                  delivery_pr_url_from_history(Map.get(payload, :decision_history, [])) ||
                  delivery_pr_url_from_summary(get_in(payload, [:operator_summary, :why_here]))
              )

            {:ok,
             Map.merge(payload, %{
               runner: Map.get(snapshot, :runner, %{}),
               webhooks: Map.get(snapshot, :webhooks, %{}),
               github_webhooks: Map.get(snapshot, :github_webhooks, %{}),
               tracker_inbox: Map.get(snapshot, :tracker_inbox, %{}),
               github_inbox: Map.get(snapshot, :github_inbox, %{}),
               polling: Map.get(snapshot, :polling, %{}),
               pr_watcher:
                 pr_watcher_payload(
                   nil,
                   workspace_path,
                   Map.get(payload, :review_thread_states, %{}),
                   pr_url,
                   prefer_cached: true
                 )
             })}
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
        {:ok, Map.update(payload, :requested_at, nil, &normalize_timestamp/1)}
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

        "hold_for_approval" ->
          Orchestrator.hold_issue_for_human_review(orchestrator, issue_identifier)

        "retry_now" ->
          Orchestrator.retry_issue_now(orchestrator, issue_identifier)

        "refresh_merge_readiness" ->
          Orchestrator.refresh_merge_readiness(orchestrator, issue_identifier)

        "approve_for_merge" ->
          Orchestrator.approve_issue_for_merge(orchestrator, issue_identifier)

        "approve_for_deploy" ->
          Orchestrator.approve_issue_for_deploy(orchestrator, issue_identifier)

        "approve_review_drafts" ->
          Orchestrator.approve_review_drafts(orchestrator, issue_identifier)

        "reject_review_drafts" ->
          Orchestrator.reject_review_drafts(orchestrator, issue_identifier)

        "mark_review_threads_posted" ->
          Orchestrator.mark_review_threads_posted(orchestrator, issue_identifier)

        "post_review_drafts" ->
          Orchestrator.post_review_drafts(orchestrator, issue_identifier)

        "resolve_review_threads" ->
          Orchestrator.resolve_review_threads(orchestrator, issue_identifier)

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

  @spec runner_control_payload(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def runner_control_payload(action, params) when is_binary(action) and is_map(params) do
    case action do
      "inspect" ->
        {:ok,
         %{
           ok: true,
           action: "inspect",
           requested_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
           runner: RunnerRuntime.info(),
           commands: RunnerRuntime.commands()
         }}

      "promote" ->
        with {:ok, ref} <- fetch_required_param(params, ["ref", "git_ref"], "git ref is required") do
          RunnerRuntime.promote(ref, canary_labels: normalize_string_list(params["canary_labels"] || params["canary_label"]))
        end

      "record_canary" ->
        with {:ok, result} <- fetch_required_param(params, ["result"], "canary result is required") do
          RunnerRuntime.record_canary(result,
            issues: normalize_string_list(params["issues"] || params["issue"]),
            prs: normalize_string_list(params["prs"] || params["pr"]),
            note: normalize_optional_string(params["note"])
          )
        end

      "rollback" ->
        target_sha = normalize_optional_string(params["release_sha"] || params["target_sha"])
        RunnerRuntime.rollback(target_sha)

      _ ->
        {:error, :unknown_action}
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
      effective_policy_class =
        (running_payload && running_payload.policy_class) ||
          tracked_issue_policy_class(tracked_issue) ||
          Map.get(run_state || %{}, :effective_policy_class) ||
          run_state_policy_class(run_state)

      detail_entry =
        running ||
          issue_detail_entry(workspace_path, run_state, tracked_issue, effective_policy_class)

      %{
        issue_identifier: issue_identifier,
        issue_id: issue_id_from_entries(running, retry, paused, queue) || entry_value(tracked_issue || %{}, "id") || Map.get(run_state || %{}, :issue_id),
        status: issue_status(running, retry, paused, queue, tracked_issue, run_state),
        policy_class: effective_policy_class,
        company: company_payload(),
        policy_pack: policy_pack_payload(),
        workflow_profile: workflow_profile_payload(%{policy_class: effective_policy_class}),
        source:
          (running_payload && running_payload.source) ||
            entry_value(tracked_issue || %{}, "source") ||
            Map.get(run_state || %{}, :issue_source),
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
        review_thread_states: normalize_review_thread_states(Map.get(run_state || %{}, :review_threads, %{})),
        harness: detail_entry && harness_payload(detail_entry),
        review: detail_entry && review_payload(detail_entry),
        publish: detail_entry && publish_payload(detail_entry),
        routing: detail_entry && routing_payload(detail_entry),
        runtime_health: issue_runtime_health_payload(running_payload, run_state, tracked_issue, decision_history),
        traceability:
          traceability_payload(
            tracked_issue,
            run_state,
            running_payload,
            detail_entry,
            decision_history
          ),
        budget_runtime: normalize_budget_runtime(Map.get(detail_entry || %{}, :budget_runtime)),
        last_decision: normalize_command_result(Map.get(run_state || %{}, :last_decision)),
        stop_reason: Map.get(run_state || %{}, :stop_reason),
        compatibility_report: compatibility_report_from(run_state),
        last_rule_id: Map.get(run_state || %{}, :last_rule_id),
        last_failure_class: Map.get(run_state || %{}, :last_failure_class),
        next_human_action: Map.get(run_state || %{}, :next_human_action),
        operator_summary:
          issue_operator_summary_payload(
            issue_status(running, retry, paused, queue, tracked_issue, run_state),
            running_payload,
            run_state,
            tracked_issue,
            decision_history
          )
      }
    end
  end

  defp delivery_report_entry(issue_identifier, snapshot, ledger_by_issue) do
    running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
    retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
    paused = Enum.find(Map.get(snapshot, :paused, []), &(&1.identifier == issue_identifier))

    queue =
      Enum.find(Map.get(snapshot, :queue, []), fn entry ->
        Map.get(entry, :issue_identifier) == issue_identifier
      end)

    workspace_path = Path.join(Config.workspace_root(), issue_identifier)
    run_state = load_issue_run_state(workspace_path)
    payload = issue_payload_body(issue_identifier, running, retry, paused, queue, ledger_by_issue)

    review_feedback =
      pr_watcher_payload(
        get_in(payload || %{}, [:company, :policy_pack]) ||
          get_in(payload || %{}, [:policy_pack, :name]) ||
          Config.policy_pack_name(),
        workspace_path,
        Map.get(payload || %{}, :review_thread_states, %{}),
        get_in(payload || %{}, [:traceability, :pr_url]) ||
          get_in(payload || %{}, [:review, :pr_url]) ||
          get_in(payload || %{}, [:runner, :pr_url]) ||
          get_in(run_state || %{}, [:last_merge, :url]) ||
          delivery_pr_url_from_history(Map.get(payload || %{}, :decision_history, [])) ||
          delivery_pr_url_from_summary(get_in(payload || %{}, [:operator_summary, :why_here]))
      )

    if payload do
      %{
        issue_identifier: payload.issue_identifier,
        issue_id: payload.issue_id,
        title: entry_value(payload.tracked, "title"),
        status: payload.status,
        source: payload.source,
        company: payload.company,
        policy_class: payload.policy_class,
        workflow_profile: %{
          name: get_in(payload, [:workflow_profile, :name]),
          merge_mode: normalize_atom_string(get_in(payload, [:workflow_profile, :merge_mode])),
          approval_gate_kind: get_in(payload, [:workflow_profile, :approval_gate_kind]),
          deploy_approval_gate_kind: get_in(payload, [:workflow_profile, :deploy_approval_gate_kind]),
          production_deploy_mode: normalize_atom_string(get_in(payload, [:workflow_profile, :production_deploy_mode]))
        },
        summary: payload.operator_summary,
        evidence: %{
          pr_url:
            get_in(payload, [:review, :pr_url]) ||
              get_in(payload, [:runner, :pr_url]) ||
              get_in(run_state || %{}, [:last_merge, :url]) ||
              delivery_pr_url_from_history(payload.decision_history) ||
              delivery_pr_url_from_summary(get_in(payload, [:operator_summary, :why_here])),
          validation_status: get_in(payload, [:runtime_health, :proof, :validation_status]),
          verifier_status: get_in(payload, [:runtime_health, :proof, :verifier_status]),
          preview_deploy_status: get_in(payload, [:runtime_health, :deploy, :preview_status]),
          production_deploy_status: get_in(payload, [:runtime_health, :deploy, :production_status]),
          post_deploy_status: get_in(payload, [:runtime_health, :deploy, :post_deploy_status])
        },
        proof: %{
          behavioral_required: get_in(payload, [:runtime_health, :proof, :behavioral_proof, :required]),
          behavioral_satisfied: get_in(payload, [:runtime_health, :proof, :behavioral_proof, :satisfied]),
          ui_required: get_in(payload, [:runtime_health, :proof, :ui_proof, :required]),
          ui_satisfied: get_in(payload, [:runtime_health, :proof, :ui_proof, :satisfied]),
          validation_status: get_in(payload, [:runtime_health, :proof, :validation_status]),
          verifier_status: get_in(payload, [:runtime_health, :proof, :verifier_status])
        },
        review_feedback: %{
          status: get_in(review_feedback, [:review_feedback, :status]),
          pending_drafts_count: get_in(review_feedback, [:review_feedback, :pending_drafts_count]),
          thread_state_counts: review_thread_state_counts(Map.get(payload, :review_thread_states, %{})),
          watcher_mode:
            Map.get(review_feedback, :mode) ||
              Map.get(
                PRWatcher.status(
                  get_in(payload, [:company, :policy_pack]) ||
                    get_in(payload, [:policy_pack, :name]) ||
                    Config.policy_pack_name()
                ),
                :mode
              )
        },
        traceability: Map.get(payload, :traceability, %{}),
        approvals: %{
          review_required:
            get_in(payload, [:workflow_profile, :merge_mode]) == :review_gate ||
              get_in(payload, [:workflow_profile, :merge_mode]) == "review_gate",
          deploy_required:
            get_in(payload, [:workflow_profile, :production_deploy_mode]) not in [nil, :disabled, "disabled"] ||
              delivery_involved?(
                %{
                  evidence: %{
                    preview_deploy_status: get_in(payload, [:runtime_health, :deploy, :preview_status]),
                    production_deploy_status: get_in(payload, [:runtime_health, :deploy, :production_status]),
                    post_deploy_status: get_in(payload, [:runtime_health, :deploy, :post_deploy_status])
                  }
                },
                :deploy
              ) ||
              decision_history_contains?(payload.decision_history, "deploy.approval.recorded")
        },
        explanation:
          delivery_explanation_payload(
            payload,
            run_state,
            %{
              pr_url:
                get_in(payload, [:review, :pr_url]) ||
                  get_in(payload, [:runner, :pr_url]) ||
                  get_in(run_state || %{}, [:last_merge, :url]) ||
                  delivery_pr_url_from_history(payload.decision_history) ||
                  delivery_pr_url_from_summary(get_in(payload, [:operator_summary, :why_here]))
            }
          ),
        latest_decision:
          payload.decision_history
          |> List.last()
          |> case do
            nil -> nil
            entry -> %{event_type: Map.get(entry, :event_type), message: Map.get(entry, :message)}
          end
      }
    end
  end

  defp delivery_explanation_payload(payload, _run_state, refs) do
    pr_url = normalize_pr_url(Map.get(refs, :pr_url))
    proof = get_in(payload, [:runtime_health, :proof]) || %{}
    deploy = get_in(payload, [:runtime_health, :deploy]) || %{}

    review_required? =
      get_in(payload, [:workflow_profile, :merge_mode]) in [:review_gate, "review_gate"]

    %{
      ready_reason:
        cond do
          payload.status == "Done" and is_binary(pr_url) and pr_url != "" ->
            "Autonomously completed after verification, merge, and finalization (#{pr_url})."

          payload.status == "Human Review" and review_required? ->
            "Awaiting operator review approval before Symphony can continue."

          true ->
            Map.get(payload.operator_summary || %{}, :why_here)
        end,
      proof_used: %{
        behavioral:
          proof_summary(
            get_in(proof, [:behavioral_proof, :required]),
            get_in(proof, [:behavioral_proof, :satisfied]),
            "behavioral"
          ),
        ui:
          proof_summary(
            get_in(proof, [:ui_proof, :required]),
            get_in(proof, [:ui_proof, :satisfied]),
            "ui"
          ),
        validation_status: Map.get(proof, :validation_status),
        verifier_status: Map.get(proof, :verifier_status)
      },
      approval_used: %{
        review_required: review_required?,
        review_approved: get_in(payload, [:review, :approved]) || false,
        deploy_approval_required: get_in(payload, [:workflow_profile, :production_deploy_mode]) not in [nil, :disabled, "disabled"],
        deploy_approved: get_in(payload, [:deploy, :approved]) || false
      },
      still_needs_human_input:
        Map.get(payload.operator_summary || %{}, :human_action_required) ||
          Map.get(payload, :next_human_action),
      review_follow_up: review_follow_up_summary(Map.get(payload, :review_thread_states, %{})),
      deploy_evidence: %{
        preview_status: Map.get(deploy, :preview_status),
        production_status: Map.get(deploy, :production_status),
        post_deploy_status: Map.get(deploy, :post_deploy_status)
      }
    }
  end

  defp proof_summary(true, true, label), do: "#{label}_proof_satisfied"
  defp proof_summary(true, false, label), do: "#{label}_proof_missing"
  defp proof_summary(true, nil, label), do: "#{label}_proof_pending"
  defp proof_summary(false, _satisfied, _label), do: "not_required"
  defp proof_summary(nil, _satisfied, _label), do: "unknown"

  defp issue_id_from_entries(running, retry, paused, queue),
    do:
      (running && running.issue_id) || (retry && retry.issue_id) || (paused && paused.issue_id) ||
        (queue && queue.issue_id)

  defp issue_detail_entry(workspace_path, run_state, tracked_issue, effective_policy_class) do
    if File.dir?(workspace_path) do
      inspection =
        workspace_path
        |> RunInspector.inspect(include_pr_details: false)
        |> then(fn inspection ->
          if is_map(run_state) do
            check_statuses =
              case Map.get(run_state, :last_check_statuses) do
                statuses when is_list(statuses) and statuses != [] -> statuses
                _ -> inspection.check_statuses
              end

            persisted_check_list = fn key, fallback ->
              case Map.get(run_state, key) do
                values when is_list(values) and values != [] -> values
                _ -> fallback
              end
            end

            inspection
            |> Map.put(:pr_url, Map.get(run_state, :pr_url) || inspection.pr_url)
            |> Map.put(:pr_state, Map.get(run_state, :last_pr_state) || inspection.pr_state)
            |> Map.put(
              :review_decision,
              Map.get(run_state, :last_review_decision) || inspection.review_decision
            )
            |> Map.put(:check_statuses, check_statuses)
            |> Map.put(
              :required_checks_state,
              Map.get(run_state, :last_required_checks_state) ||
                inspection.required_checks_state
            )
            |> Map.put(
              :missing_required_checks,
              persisted_check_list.(
                :last_missing_required_checks,
                inspection.missing_required_checks
              )
            )
            |> Map.put(
              :pending_required_checks,
              persisted_check_list.(
                :last_pending_required_checks,
                inspection.pending_required_checks
              )
            )
            |> Map.put(
              :failing_required_checks,
              persisted_check_list.(
                :last_failing_required_checks,
                inspection.failing_required_checks
              )
            )
            |> Map.put(
              :cancelled_required_checks,
              persisted_check_list.(
                :last_cancelled_required_checks,
                inspection.cancelled_required_checks
              )
            )
          else
            inspection
          end
        end)

      %{
        issue_id: Map.get(run_state || %{}, :issue_id) || entry_value(tracked_issue || %{}, "id"),
        identifier: Map.get(run_state || %{}, :issue_identifier) || entry_value(tracked_issue || %{}, "identifier"),
        source: Map.get(run_state || %{}, :issue_source) || entry_value(tracked_issue || %{}, "source"),
        state: entry_value(tracked_issue || %{}, "state"),
        stage: Map.get(run_state || %{}, :stage),
        workspace: workspace_path,
        checkout?: inspection.checkout?,
        git?: inspection.git?,
        origin_url: inspection.origin_url,
        branch: inspection.branch,
        head_sha: inspection.head_sha,
        dirty?: inspection.dirty?,
        changed_files: inspection.changed_files,
        status_text: inspection.status_text,
        base_branch: inspection.harness && inspection.harness.base_branch,
        harness_path: if(inspection.harness, do: ".symphony/harness.yml", else: nil),
        harness_version: inspection.harness && inspection.harness.version,
        harness_error: inspection.harness_error,
        preflight_command: inspection.harness && inspection.harness.preflight_command,
        validation_command: inspection.harness && inspection.harness.validation_command,
        smoke_command: inspection.harness && inspection.harness.smoke_command,
        post_merge_command: inspection.harness && inspection.harness.post_merge_command,
        deploy_preview_command: inspection.harness && inspection.harness.deploy_preview_command,
        deploy_production_command: inspection.harness && inspection.harness.deploy_production_command,
        post_deploy_verify_command: inspection.harness && inspection.harness.post_deploy_verify_command,
        deploy_rollback_command: inspection.harness && inspection.harness.deploy_rollback_command,
        artifacts_command: inspection.harness && inspection.harness.artifacts_command,
        required_checks: (inspection.harness && inspection.harness.required_checks) || [],
        publish_required_checks: (inspection.harness && inspection.harness.publish_required_checks) || [],
        ci_required_checks: (inspection.harness && inspection.harness.ci_required_checks) || [],
        pr_url: inspection.pr_url,
        pr_state: inspection.pr_state,
        review_decision: inspection.review_decision,
        check_statuses: inspection.check_statuses,
        ready_for_merge: RunInspector.ready_for_merge?(inspection),
        policy_class: effective_policy_class,
        labels: entry_value(tracked_issue || %{}, "labels") || [],
        required_labels: [],
        label_gate_eligible: nil,
        last_pr_body_validation: Map.get(run_state || %{}, :last_pr_body_validation),
        last_validation: Map.get(run_state || %{}, :last_validation),
        last_verifier: Map.get(run_state || %{}, :last_verifier),
        last_verifier_verdict: Map.get(run_state || %{}, :last_verifier_verdict),
        acceptance_summary: Map.get(run_state || %{}, :acceptance_summary),
        last_post_merge: Map.get(run_state || %{}, :last_post_merge),
        last_merge_readiness: Map.get(run_state || %{}, :last_merge_readiness),
        last_deploy_preview: Map.get(run_state || %{}, :last_deploy_preview),
        last_deploy_production: Map.get(run_state || %{}, :last_deploy_production),
        last_post_deploy_verify: Map.get(run_state || %{}, :last_post_deploy_verify),
        merge_sha: Map.get(run_state || %{}, :merge_sha),
        deploy_approved: Map.get(run_state || %{}, :deploy_approved, false),
        stop_reason: Map.get(run_state || %{}, :stop_reason),
        budget_runtime:
          RunPolicy.budget_runtime(
            budget_runtime_issue(tracked_issue, run_state),
            %{
              stage: Map.get(run_state || %{}, :stage),
              workspace: workspace_path,
              workspace_path: workspace_path,
              turn_count: Map.get(run_state || %{}, :implementation_turns, 0),
              codex_input_tokens: 0,
              codex_output_tokens: 0,
              codex_total_tokens: 0,
              turn_started_input_tokens: 0,
              resume_context: Map.get(run_state || %{}, :resume_context, %{})
            }
          )
      }
    end
  end

  defp normalize_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_timestamp(value) when is_binary(value), do: value
  defp normalize_timestamp(value), do: value

  defp fetch_required_param(params, keys, message) when is_map(params) and is_list(keys) do
    keys
    |> Enum.find_value(fn key -> normalize_optional_string(Map.get(params, key)) end)
    |> case do
      nil -> {:error, {:invalid_params, message}}
      value -> {:ok, value}
    end
  end

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) when is_binary(value) do
    case normalize_optional_string(value) do
      nil -> []
      normalized -> [normalized]
    end
  end

  defp normalize_string_list(_value), do: []

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, _retry, paused, _queue, _tracked_issue, _run_state) when not is_nil(paused), do: "paused"
  defp issue_status(_running, nil, _paused, nil, nil, %{} = run_state), do: Map.get(run_state, :stage) || "tracked"
  defp issue_status(nil, nil, _paused, _queue, %{} = tracked_issue, _run_state), do: entry_value(tracked_issue, "state") || "tracked"
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
      source: Map.get(entry, :source),
      state: entry.state,
      stage: Map.get(entry, :stage),
      runtime_mode: runtime_mode_payload(entry),
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
      merge_readiness: merge_readiness_payload(entry),
      routing: routing_payload(entry),
      lease: lease_payload(entry),
      policy: policy,
      company: company_payload(),
      policy_pack: policy_pack_payload(),
      workflow_profile: workflow_profile_payload(entry),
      runtime_health: runtime_health_payload(entry, workspace, harness, review),
      review_approved: Map.get(entry, :review_approved, false),
      token_pressure: Map.get(entry, :token_pressure),
      budget_runtime: normalize_budget_runtime(Map.get(entry, :budget_runtime)),
      status_summary: status_summary_payload(entry, review),
      operator_summary: operator_summary_payload(entry, review),
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
      source: Map.get(entry, :source),
      attempt: Map.get(entry, :attempt),
      due_at: due_at_iso8601(Map.get(entry, :due_in_ms)),
      error: Map.get(entry, :error),
      priority_override: Map.get(entry, :priority_override),
      policy_class: Map.get(entry, :policy_class),
      lease: lease_payload(entry),
      company: company_payload(),
      policy_pack: policy_pack_payload(),
      workflow_profile: workflow_profile_payload(entry),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      next_human_action: Map.get(entry, :next_human_action),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id),
      operator_summary: waiting_operator_summary_payload(entry, "Issue is waiting for the retry window to expire.")
    }
  end

  defp paused_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      source: Map.get(entry, :source),
      resume_state: entry.resume_state,
      policy_class: Map.get(entry, :policy_class),
      lease: lease_payload(entry),
      company: company_payload(),
      policy_pack: policy_pack_payload(),
      workflow_profile: workflow_profile_payload(entry),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      next_human_action: Map.get(entry, :next_human_action),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id),
      operator_summary: paused_operator_summary_payload(entry)
    }
  end

  defp skipped_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :issue_identifier),
      source: Map.get(entry, :source),
      state: Map.get(entry, :state),
      labels: Map.get(entry, :labels, []),
      required_labels: Map.get(entry, :required_labels, []),
      reason: Map.get(entry, :reason),
      policy_class: Map.get(entry, :policy_class),
      lease: lease_payload(entry),
      company: company_payload(),
      policy_pack: policy_pack_payload(),
      workflow_profile: workflow_profile_payload(entry),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      next_human_action: Map.get(entry, :next_human_action),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id),
      operator_summary: skipped_operator_summary_payload(entry)
    }
  end

  defp queue_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :issue_identifier),
      source: Map.get(entry, :source),
      state: Map.get(entry, :state),
      rank: Map.get(entry, :rank),
      linear_priority: Map.get(entry, :linear_priority),
      operator_override: Map.get(entry, :operator_override),
      retry_penalty: Map.get(entry, :retry_penalty),
      labels: Map.get(entry, :labels, []),
      required_labels: Map.get(entry, :required_labels, []),
      label_gate_eligible: Map.get(entry, :label_gate_eligible, true),
      error: Map.get(entry, :error),
      policy_class: Map.get(entry, :policy_class),
      lease: lease_payload(entry),
      policy_pack: policy_pack_payload(),
      workflow_profile: workflow_profile_payload(entry),
      policy_source: Map.get(entry, :policy_source),
      policy_override: Map.get(entry, :policy_override),
      next_human_action: Map.get(entry, :next_human_action),
      last_rule_id: Map.get(entry, :last_rule_id),
      last_failure_class: Map.get(entry, :last_failure_class),
      last_decision_summary: Map.get(entry, :last_decision_summary),
      last_ledger_event_id: Map.get(entry, :last_ledger_event_id),
      operator_summary: queue_operator_summary_payload(entry)
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

  defp triage_payload(running, retrying, paused, skipped, queue, ledger_entries) do
    attention_now =
      Enum.concat([
        Enum.filter(running, &human_attention_entry?/1) |> Enum.map(&triage_entry_payload(&1, "attention_now")),
        Enum.map(paused, &triage_entry_payload(&1, "attention_now")),
        Enum.map(skipped, &triage_entry_payload(&1, "attention_now")),
        recent_attention_entries_from_ledger(ledger_entries, running, retrying, paused, skipped, queue)
      ])
      |> uniq_triage_entries()

    autonomous_now =
      running
      |> Enum.reject(&human_attention_entry?/1)
      |> Enum.map(&triage_entry_payload(&1, "autonomous_now"))
      |> uniq_triage_entries()

    waiting_safe =
      Enum.concat([
        Enum.filter(running, &passive_waiting_entry?/1) |> Enum.map(&triage_entry_payload(&1, "waiting_safe")),
        Enum.reject(retrying, &human_attention_entry?/1) |> Enum.map(&triage_entry_payload(&1, "waiting_safe")),
        Enum.reject(queue, &queue_attention_entry?/1) |> Enum.map(&triage_entry_payload(&1, "waiting_safe"))
      ])
      |> uniq_triage_entries()

    recently_finished =
      recent_finished_entries_from_ledger(ledger_entries)
      |> uniq_triage_entries()

    %{
      summary: %{
        attention_now: length(attention_now),
        autonomous_now: length(autonomous_now),
        waiting_safe: length(waiting_safe),
        recently_finished: length(recently_finished)
      },
      attention_now: attention_now,
      autonomous_now: autonomous_now,
      waiting_safe: waiting_safe,
      recently_finished: recently_finished
    }
  end

  defp triage_entry_payload(entry, bucket) do
    operator_summary = Map.get(entry, :operator_summary, %{})

    %{
      issue_identifier: Map.get(entry, :issue_identifier),
      issue_id: Map.get(entry, :issue_id),
      source: Map.get(entry, :source),
      bucket: bucket,
      stage: Map.get(entry, :stage) || Map.get(operator_summary, :current_stage),
      status: Map.get(entry, :status) || Map.get(entry, :state) || Map.get(operator_summary, :current_stage),
      tone: triage_tone(bucket, entry),
      why_here: Map.get(operator_summary, :why_here) || Map.get(entry, :last_decision_summary) || Map.get(entry, :reason),
      automatic_next: Map.get(operator_summary, :automatic_next),
      human_action_required: Map.get(operator_summary, :human_action_required) || Map.get(entry, :next_human_action),
      rule_id: Map.get(operator_summary, :rule_id) || Map.get(entry, :last_rule_id),
      failure_class: Map.get(operator_summary, :failure_class) || Map.get(entry, :last_failure_class),
      policy_class: Map.get(entry, :policy_class)
    }
  end

  defp triage_entry_payload_from_ledger(entry, bucket) do
    %{
      issue_identifier: entry_value(entry, "issue_identifier"),
      issue_id: entry_value(entry, "issue_id"),
      source: entry_value(entry, "source") || "ledger",
      bucket: bucket,
      stage: entry_value(entry, "stage"),
      status: entry_value(entry, "target_state"),
      tone: triage_tone(bucket, %{}),
      why_here: ledger_message(entry),
      automatic_next: ledger_next_action(entry, bucket),
      human_action_required: entry_value(entry, "human_action"),
      rule_id: entry_value(entry, "rule_id"),
      failure_class: entry_value(entry, "failure_class"),
      policy_class: entry_value(entry, "policy_class")
    }
  end

  defp waiting_operator_summary_payload(entry, summary) do
    %{
      current_stage: Map.get(entry, :state) || "retrying",
      why_here: Map.get(entry, :last_decision_summary) || summary,
      automatic_next: summary,
      human_action_required: Map.get(entry, :next_human_action),
      rule_id: Map.get(entry, :last_rule_id),
      failure_class: Map.get(entry, :last_failure_class)
    }
  end

  defp paused_operator_summary_payload(entry) do
    %{
      current_stage: Map.get(entry, :resume_state) || "paused",
      why_here: Map.get(entry, :last_decision_summary) || "Issue is paused until an operator resumes it.",
      automatic_next: "No automatic action until this issue is resumed.",
      human_action_required: "Resume the issue when work should continue.",
      rule_id: Map.get(entry, :last_rule_id),
      failure_class: Map.get(entry, :last_failure_class)
    }
  end

  defp skipped_operator_summary_payload(entry) do
    %{
      current_stage: Map.get(entry, :state) || "skipped",
      why_here: Map.get(entry, :last_decision_summary) || skipped_reason_summary(entry),
      automatic_next: "Wait for routing conditions to change before the runtime retries this issue.",
      human_action_required: Map.get(entry, :next_human_action),
      rule_id: Map.get(entry, :last_rule_id),
      failure_class: Map.get(entry, :last_failure_class)
    }
  end

  defp queue_operator_summary_payload(entry) do
    %{
      current_stage: Map.get(entry, :state) || "queued",
      why_here: Map.get(entry, :last_decision_summary) || queued_reason_summary(entry),
      automatic_next: queued_next_step(entry),
      human_action_required: Map.get(entry, :next_human_action),
      rule_id: Map.get(entry, :last_rule_id),
      failure_class: Map.get(entry, :last_failure_class)
    }
  end

  defp review_thread_state_counts(thread_states) when is_map(thread_states) do
    Enum.reduce(thread_states, %{}, fn {_thread_key, state}, acc ->
      draft_state = state |> Map.get("draft_state", "drafted") |> to_string()
      Map.update(acc, draft_state, 1, &(&1 + 1))
    end)
  end

  defp review_thread_state_counts(_), do: %{}

  defp review_follow_up_summary(thread_states) when is_map(thread_states) do
    counts = review_thread_state_counts(thread_states)

    cond do
      map_size(counts) == 0 ->
        "No tracked PR review feedback."

      Map.get(counts, "approved_to_post", 0) > 0 ->
        "#{Map.get(counts, "approved_to_post")} review thread(s) approved to post."

      Map.get(counts, "drafted", 0) > 0 ->
        "#{Map.get(counts, "drafted")} review thread(s) still need operator approval before posting."

      Map.get(counts, "posted", 0) > 0 or Map.get(counts, "resolved", 0) > 0 ->
        "Tracked review feedback has been addressed or posted."

      true ->
        "Tracked review feedback is present."
    end
  end

  defp review_follow_up_summary(_), do: "No tracked PR review feedback."

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
      deploy_preview_command: Map.get(entry, :deploy_preview_command),
      deploy_production_command: Map.get(entry, :deploy_production_command),
      post_deploy_verify_command: Map.get(entry, :post_deploy_verify_command),
      deploy_rollback_command: Map.get(entry, :deploy_rollback_command),
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
    last_verifier = normalize_command_result(Map.get(entry, :last_verifier))

    %{
      pr_body_validation: normalize_command_result(Map.get(entry, :last_pr_body_validation)),
      last_validation: normalize_command_result(Map.get(entry, :last_validation)),
      last_verifier: last_verifier,
      last_verifier_verdict: Map.get(entry, :last_verifier_verdict),
      acceptance_summary: Map.get(entry, :acceptance_summary),
      behavioral_proof: Map.get(last_verifier || %{}, :behavioral_proof),
      ui_proof: Map.get(last_verifier || %{}, :ui_proof),
      last_post_merge: normalize_command_result(Map.get(entry, :last_post_merge)),
      last_deploy_preview: normalize_command_result(Map.get(entry, :last_deploy_preview)),
      last_deploy_production: normalize_command_result(Map.get(entry, :last_deploy_production)),
      last_post_deploy_verify: normalize_command_result(Map.get(entry, :last_post_deploy_verify)),
      merge_sha: Map.get(entry, :merge_sha),
      deploy_approved: Map.get(entry, :deploy_approved, false),
      stop_reason: Map.get(entry, :stop_reason)
    }
  end

  defp routing_payload(entry) do
    %{
      labels: Map.get(entry, :labels, []),
      required_labels: Map.get(entry, :required_labels, []),
      eligible: Map.get(entry, :label_gate_eligible, true),
      runner_channel: Map.get(entry, :runner_channel),
      target_runner_channel: Map.get(entry, :target_runner_channel)
    }
  end

  defp lease_payload(entry) when is_map(entry) do
    raw_lease = Map.get(entry, :lease, %{})

    %{
      owner: Map.get(raw_lease, :lease_owner) || Map.get(entry, :lease_owner),
      owner_instance_id: Map.get(raw_lease, :lease_owner_instance_id) || Map.get(entry, :lease_owner_instance_id),
      owner_channel: Map.get(raw_lease, :lease_owner_channel) || Map.get(entry, :lease_owner_channel),
      acquired_at: normalize_timestamp(Map.get(raw_lease, :lease_acquired_at) || Map.get(entry, :lease_acquired_at)),
      updated_at: normalize_timestamp(Map.get(raw_lease, :lease_updated_at) || Map.get(entry, :lease_updated_at)),
      status: Map.get(raw_lease, :lease_status) || Map.get(entry, :lease_status),
      epoch: Map.get(raw_lease, :lease_epoch) || Map.get(entry, :lease_epoch),
      age_ms: Map.get(raw_lease, :lease_age_ms) || Map.get(entry, :lease_age_ms),
      ttl_ms: Map.get(raw_lease, :lease_ttl_ms) || Map.get(entry, :lease_ttl_ms),
      reclaimable: Map.get(raw_lease, :lease_reclaimable) || Map.get(entry, :lease_reclaimable, false),
      source: Map.get(raw_lease, :lease_source)
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
      next_human_action: policy_next_human_action(entry, review),
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
      company: company_payload(),
      counts: %{running: 0, retrying: 0, paused: 0, queue: 0, skipped: 0},
      running: [],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [],
      triage: %{
        summary: %{attention_now: 0, autonomous_now: 0, waiting_safe: 0, recently_finished: 0},
        attention_now: [],
        autonomous_now: [],
        waiting_safe: [],
        recently_finished: []
      },
      activity: [],
      priority_overrides: %{},
      policy_overrides: %{},
      pr_watcher: pr_watcher_payload(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      runner: %{},
      webhooks: %{},
      github_webhooks: %{},
      tracker_inbox: %{depth: 0, oldest_pending_event_at: nil, last_drained_at: nil},
      github_inbox: %{depth: 0, oldest_pending_event_at: nil, last_drained_at: nil},
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

  defp workflow_profile_payload(entry) do
    profile =
      WorkflowProfile.resolve(
        Map.get(entry, :policy_class),
        policy_pack: Map.get(entry, :policy_pack) || Config.policy_pack_name()
      )

    %{
      name: WorkflowProfile.name_string(profile),
      merge_mode: profile.merge_mode,
      approval_gate_kind: profile.approval_gate_kind,
      approval_gate_state: profile.approval_gate_state,
      deploy_approval_gate_kind: profile.deploy_approval_gate_kind,
      deploy_approval_gate_state: profile.deploy_approval_gate_state,
      post_merge_verification_required: profile.post_merge_verification_required,
      preview_deploy_mode: profile.preview_deploy_mode,
      production_deploy_mode: profile.production_deploy_mode,
      post_deploy_verification_required: profile.post_deploy_verification_required,
      max_turns_override: profile.max_turns_override
    }
  end

  defp policy_pack_payload do
    pack = PolicyPack.resolve()

    %{
      name: PolicyPack.name_string(pack),
      description: pack.description,
      operating_mode: pack.operating_mode,
      default_issue_class: pack.default_issue_class,
      allowed_policy_classes: pack.allowed_policy_classes,
      required_any_issue_labels: Map.get(pack, :required_any_issue_labels, []),
      forbidden_issue_labels: Map.get(pack, :forbidden_issue_labels, []),
      tracker_mutation_mode: pack.tracker_mutation_mode,
      pr_posting_mode: pack.pr_posting_mode,
      thread_resolution_mode: pack.thread_resolution_mode,
      external_comment_mode: pack.external_comment_mode,
      draft_first_required: pack.draft_first_required,
      confidence_language: pack.confidence_language,
      allowed_external_channels: pack.allowed_external_channels,
      preview_deploy_allowed: pack.preview_deploy_allowed,
      production_deploy_allowed: pack.production_deploy_allowed,
      max_concurrent_runs_per_company: pack.max_concurrent_runs_per_company,
      max_merges_per_day_per_repo: pack.max_merges_per_day_per_repo,
      repo_frozen: pack.repo_frozen,
      company_frozen: pack.company_frozen,
      outward_actions: %{
        tracker_mutation_mode: pack.tracker_mutation_mode,
        pr_posting_mode: pack.pr_posting_mode,
        thread_resolution_mode: pack.thread_resolution_mode,
        external_comment_mode: pack.external_comment_mode
      },
      pr_watcher: pr_watcher_payload(pack)
    }
  end

  defp company_payload do
    %{
      name: Config.company_name(),
      repo_url: Config.company_repo_url(),
      internal_project_name: Config.company_internal_project_name(),
      internal_project_url: Config.company_internal_project_url(),
      mode: Config.company_mode(),
      policy_pack: Config.policy_pack_name(),
      author_profile_path: Config.author_profile_path(),
      credential_registry_path: Config.credential_registry_path()
    }
  end

  defp runtime_health_payload(entry, workspace, harness, review) do
    pack = PolicyPack.resolve()

    workflow_profile =
      WorkflowProfile.resolve(
        Map.get(entry, :policy_class),
        policy_pack: Map.get(entry, :policy_pack) || Config.policy_pack_name()
      )

    risk =
      RiskClassifier.classify(
        entry,
        workspace,
        Map.get(harness, :raw) || Map.get(harness, "raw") || harness,
        workflow_profile
      )

    %{
      intake: %{
        source: Map.get(entry, :source),
        routing_eligible: get_in(entry, [:routing, :eligible]) || false,
        policy_class: Map.get(entry, :policy_class),
        policy_source: Map.get(entry, :policy_source),
        company_mode: Config.company_mode(),
        policy_pack: PolicyPack.name_string(pack),
        company_name: Config.company_name(),
        expected_repo_url: Config.company_repo_url()
      },
      workspace: %{
        checkout: workspace.checkout?,
        git: workspace.git?,
        dirty: workspace.dirty?,
        branch: workspace.branch,
        head_sha: workspace.head_sha
      },
      proof: %{
        compatibility_report_present: compatibility_report_from_result(Map.get(entry, :last_decision)) != nil,
        verifier_status: get_in(entry, [:publish, :last_verifier, :status]),
        validation_status: get_in(entry, [:publish, :last_validation, :status]),
        proof_class: risk.proof_class,
        ui_proof_required: risk.ui_proof_required,
        behavioral_proof_required: risk.behavioral_proof_required
      },
      risk: %{
        change_type: risk.change_type,
        risk_level: risk.risk_level,
        approval_class: risk.approval_class,
        reason: risk.reason
      },
      passive_stage: %{
        passive: Map.get(entry, :passive?, false),
        merge_readiness: Map.get(entry, :stage) == "merge_readiness",
        waiting_on_checks: Map.get(entry, :stage) == "await_checks",
        review_approved: Map.get(entry, :review_approved, false),
        deploy_approved: Map.get(entry, :deploy_approved, false),
        merge_window_wait: Map.get(entry, :merge_window_wait),
        deploy_window_wait: Map.get(entry, :deploy_window_wait),
        last_merge_readiness: merge_readiness_payload(entry)
      },
      tracker: %{
        source: Map.get(entry, :source),
        required_labels: get_in(entry, [:routing, :required_labels]) || []
      },
      policy_posture: %{
        operating_mode: Config.company_mode(),
        draft_first_required: pack.draft_first_required,
        tracker_mutation_mode: pack.tracker_mutation_mode,
        pr_posting_mode: pack.pr_posting_mode,
        thread_resolution_mode: pack.thread_resolution_mode,
        external_comment_mode: pack.external_comment_mode
      },
      pr_watcher: pr_watcher_payload(pack),
      runner: %{
        pr_url: review.pr_url,
        ready_for_merge: review.ready_for_merge
      },
      deploy: %{
        preview_status: normalize_result_status(Map.get(entry, :last_deploy_preview, %{})[:status]),
        production_status: normalize_result_status(Map.get(entry, :last_deploy_production, %{})[:status]),
        post_deploy_status: normalize_result_status(Map.get(entry, :last_post_deploy_verify, %{})[:status])
      },
      summary: runtime_health_summary(entry, workspace, harness, review, risk)
    }
  end

  defp traceability_payload(tracked_issue, run_state, running_payload, detail_entry, decision_history) do
    review_threads = Map.get(run_state || %{}, :review_threads, %{})

    pr_url =
      normalize_pr_url(
        (detail_entry && entry_value(detail_entry, "pr_url")) ||
          get_in(running_payload || %{}, [:review, :pr_url]) ||
          get_in(run_state || %{}, [:last_merge, :url]) ||
          review_thread_pr_url(review_threads) ||
          delivery_pr_url_from_history(decision_history) ||
          delivery_pr_url_from_summary(Map.get(run_state || %{}, :last_decision_summary)) ||
          delivery_pr_url_from_summary(get_in(running_payload || %{}, [:operator_summary, :why_here]))
      )

    %{
      source_issue_url: entry_value(tracked_issue || %{}, "url"),
      pr_url: pr_url,
      internal_issue: %{
        identifier: entry_value(tracked_issue || %{}, "internal_identifier"),
        url: entry_value(tracked_issue || %{}, "internal_url")
      },
      internal_project: %{
        name: Config.company_internal_project_name(),
        url: Config.company_internal_project_url()
      },
      proof_artifacts: proof_artifacts_payload(run_state, running_payload),
      deploy_artifacts: deploy_artifacts_payload(run_state)
    }
  end

  defp review_thread_pr_url(review_threads) when is_map(review_threads) do
    Enum.find_value(review_threads, fn {_thread_key, state} ->
      normalize_pr_url(Map.get(state, "posted_reply_url"))
    end)
  end

  defp review_thread_pr_url(_), do: nil

  defp merge_readiness_payload(entry) when is_map(entry) do
    merge_readiness = Map.get(entry, :last_merge_readiness)

    if is_map(merge_readiness) do
      %{
        active: Map.get(entry, :stage) == "merge_readiness",
        checked_at: Map.get(merge_readiness, :checked_at) || Map.get(merge_readiness, "checked_at"),
        pr_body_validation_status:
          Map.get(merge_readiness, :pr_body_validation_status) ||
            Map.get(merge_readiness, "pr_body_validation_status"),
        posted_review_threads:
          Map.get(merge_readiness, :posted_review_threads) ||
            Map.get(merge_readiness, "posted_review_threads") || 0,
        pending_reply_refreshes:
          Map.get(merge_readiness, :pending_reply_refreshes) ||
            Map.get(merge_readiness, "pending_reply_refreshes") || 0,
        resolved_review_threads:
          Map.get(merge_readiness, :resolved_review_threads) ||
            Map.get(merge_readiness, "resolved_review_threads") || 0
      }
    else
      nil
    end
  end

  defp proof_artifacts_payload(run_state, running_payload) do
    proof = get_in(running_payload || %{}, [:runtime_health, :proof]) || %{}
    ui_proof = get_in(proof, [:ui_proof]) || %{}

    %{
      behavioral_artifact_path: get_in(run_state || %{}, [:compatibility_report, :behavioral_proof, :artifact_path]),
      ui_artifact_paths: Map.get(ui_proof, :artifact_paths) || Map.get(ui_proof, "artifact_paths") || [],
      ui_artifact_matches: Map.get(ui_proof, :artifact_matches) || Map.get(ui_proof, "artifact_matches") || %{}
    }
  end

  defp deploy_artifacts_payload(run_state) do
    %{
      preview_url: get_in(run_state || %{}, [:last_preview_deploy, :url]),
      production_url: get_in(run_state || %{}, [:last_production_deploy, :url]),
      rollback_target: get_in(run_state || %{}, [:last_rollback, :target])
    }
  end

  defp runtime_health_summary(entry, workspace, harness, review, risk) do
    workflow_profile =
      WorkflowProfile.resolve(
        Map.get(entry, :policy_class),
        policy_pack: Map.get(entry, :policy_pack) || Config.policy_pack_name()
      )

    cond do
      not workspace.checkout? or not workspace.git? ->
        "Workspace is not a valid checkout yet."

      is_binary(harness.error) and String.trim(harness.error) != "" ->
        "Harness contract is invalid or missing."

      Map.get(entry, :stage) == "await_checks" and merge_window_waiting?(entry) ->
        merge_window_wait_summary(entry)

      Map.get(entry, :stage) == "deploy_production" and deploy_window_waiting?(entry) ->
        deploy_window_wait_summary(entry)

      Map.get(entry, :stage) == "await_checks" and not review.ready_for_merge ->
        "Waiting for required checks or review state to become merge-ready."

      Map.get(entry, :stage) == "merge" ->
        "Runtime is attempting merge using the configured workflow profile."

      Map.get(entry, :stage) == "post_merge" ->
        "Runtime is performing post-merge verification and finalization."

      Map.get(entry, :stage) == "deploy_preview" ->
        "Runtime is deploying the merged change to a preview target."

      Map.get(entry, :stage) == "post_deploy_verify" ->
        "Runtime is performing post-deploy verification before finalization."

      Map.get(entry, :stage) == "deploy_production" ->
        "Runtime is deploying the merged change to the production target."

      WorkflowProfile.approval_gate_state?(Map.get(entry, :state)) and
          normalize_state(Map.get(entry, :state)) ==
            normalize_state(workflow_profile.deploy_approval_gate_state) ->
        "Runtime is waiting for explicit deploy approval before production deployment."

      risk.risk_level == "high" ->
        "Runtime health is nominal for the current stage, but this run is classified as #{risk.change_type} with #{risk.proof_class} proof requirements."

      true ->
        "Runtime health is nominal for the current stage."
    end
  end

  defp operator_summary_payload(entry, review) do
    summary = status_summary_payload(entry, review)

    workflow_profile =
      WorkflowProfile.resolve(
        Map.get(entry, :policy_class),
        policy_pack: Map.get(entry, :policy_pack) || Config.policy_pack_name()
      )

    risk = RiskClassifier.classify(entry, %{}, nil, workflow_profile)
    pack = PolicyPack.resolve()

    %{
      current_stage: Map.get(entry, :stage),
      why_here: summary.summary,
      automatic_next: summary.automatic_next,
      human_action_required: Map.get(entry, :next_human_action),
      rule_id: Map.get(entry, :last_rule_id),
      failure_class: Map.get(entry, :last_failure_class),
      risk_level: risk.risk_level,
      proof_class: risk.proof_class,
      operating_mode: pack.operating_mode,
      outward_actions: %{
        tracker_mutation_mode: pack.tracker_mutation_mode,
        pr_posting_mode: pack.pr_posting_mode,
        thread_resolution_mode: pack.thread_resolution_mode,
        external_comment_mode: pack.external_comment_mode,
        draft_first_required: pack.draft_first_required
      },
      pr_watcher: pr_watcher_payload(pack)
    }
  end

  defp pr_watcher_payload(pack \\ nil, workspace_path \\ nil, thread_states \\ %{}, pr_url \\ nil, opts \\ []) do
    base = PRWatcher.status(pack)

    if is_binary(workspace_path) and File.dir?(workspace_path) do
      Map.put(
        base,
        :review_feedback,
        PRWatcher.review_feedback(
          workspace_path,
          policy_pack: pack,
          thread_states: thread_states,
          pr_url: pr_url,
          prefer_cached: Keyword.get(opts, :prefer_cached, false)
        )
      )
    else
      base
    end
  end

  defp normalize_review_thread_states(states) when is_map(states) do
    Map.new(states, fn {key, value} ->
      {to_string(key), normalize_review_thread_state_value(value)}
    end)
  end

  defp normalize_review_thread_states(_), do: %{}

  defp normalize_review_thread_state_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {to_string(key), normalize_review_thread_state_value(nested)}
    end)
  end

  defp normalize_review_thread_state_value(value), do: value

  defp issue_operator_summary_payload(status, running_payload, run_state, tracked_issue, decision_history) do
    if running_payload do
      Map.get(running_payload, :operator_summary)
    else
      done_summary = done_operator_summary(run_state, decision_history)

      history_signal =
        if is_list(decision_history) do
          decision_history
          |> Enum.reverse()
          |> Enum.find_value(fn entry ->
            summary = Map.get(entry, :summary)
            metadata = Map.get(entry, :metadata) || %{}
            human_action = Map.get(metadata, :human_action) || Map.get(metadata, "human_action")
            rule_id = Map.get(entry, :rule_id)
            failure_class = Map.get(entry, :failure_class)

            if present_value?(summary) or present_value?(human_action) or present_value?(rule_id) do
              %{
                summary: summary,
                human_action: human_action,
                rule_id: rule_id,
                failure_class: failure_class
              }
            else
              nil
            end
          end)
        end

      normalized_status = status |> to_string() |> String.downcase()

      %{
        current_stage: Map.get(run_state || %{}, :stage) || status,
        why_here:
          done_summary ||
            Map.get(run_state || %{}, :last_decision_summary) ||
            Map.get(history_signal || %{}, :summary) ||
            entry_value(tracked_issue || %{}, "state") ||
            "Issue is not currently running.",
        automatic_next:
          cond do
            normalized_status == "queued" ->
              "Wait for runtime dispatch."

            normalized_status == "retrying" ->
              "Wait for retry backoff to expire."

            normalized_status == "paused" ->
              "No automatic action until resumed."

            normalize_state(status) ==
                normalize_state(Map.get(run_state || %{}, :deploy_approval_gate_state)) ->
              "Await deploy approval in #{status}."

            normalized_status == "human review" ->
              "Await human review or operator approval."

            WorkflowProfile.approval_gate_state?(status) ->
              "Await approval in #{status}."

            normalized_status == "done" ->
              "No further runtime action is required."

            true ->
              "No automatic next step available."
          end,
        human_action_required:
          Map.get(run_state || %{}, :next_human_action) ||
            Map.get(history_signal || %{}, :human_action),
        rule_id: Map.get(run_state || %{}, :last_rule_id) || Map.get(history_signal || %{}, :rule_id),
        failure_class:
          Map.get(run_state || %{}, :last_failure_class) ||
            Map.get(history_signal || %{}, :failure_class)
      }
    end
  end

  defp issue_runtime_health_payload(running_payload, run_state, tracked_issue, decision_history) do
    if running_payload do
      Map.get(running_payload, :runtime_health)
    else
      %{
        intake: %{
          source:
            entry_value(tracked_issue || %{}, "source") ||
              Map.get(run_state || %{}, :issue_source),
          routing_eligible: nil,
          policy_class:
            entry_value(tracked_issue || %{}, "policy_class") ||
              Map.get(run_state || %{}, :effective_policy_class),
          policy_source: nil,
          company_mode: Config.company_mode(),
          policy_pack: PolicyPack.name_string(PolicyPack.resolve())
        },
        workspace: %{
          checkout: nil,
          git: nil,
          dirty: nil,
          branch: nil,
          head_sha: nil
        },
        proof: %{
          compatibility_report_present: compatibility_report_from(run_state) != nil,
          verifier_status: get_in(run_state || %{}, [:last_verifier, :status]),
          validation_status: get_in(run_state || %{}, [:last_validation, :status])
        },
        passive_stage: %{
          passive: false,
          waiting_on_checks: Map.get(run_state || %{}, :stage) == "await_checks",
          review_approved: Map.get(run_state || %{}, :review_approved, false),
          deploy_approved: Map.get(run_state || %{}, :deploy_approved, false),
          merge_window_wait: Map.get(run_state || %{}, :merge_window_wait),
          deploy_window_wait: Map.get(run_state || %{}, :deploy_window_wait),
          last_merge_readiness:
            merge_readiness_payload(%{
              last_merge_readiness: Map.get(run_state || %{}, :last_merge_readiness),
              stage: Map.get(run_state || %{}, :stage)
            })
        },
        tracker: %{
          source:
            entry_value(tracked_issue || %{}, "source") ||
              Map.get(run_state || %{}, :issue_source),
          required_labels: []
        },
        runner: %{
          pr_url: Map.get(run_state || %{}, :pr_url),
          ready_for_merge: false
        },
        deploy: %{
          preview_status: normalize_result_status(get_in(run_state || %{}, [:last_deploy_preview, :status])),
          production_status: normalize_result_status(get_in(run_state || %{}, [:last_deploy_production, :status])),
          post_deploy_status: normalize_result_status(get_in(run_state || %{}, [:last_post_deploy_verify, :status]))
        },
        summary:
          done_operator_summary(run_state, decision_history) ||
            Map.get(run_state || %{}, :last_decision_summary) ||
            "Runtime health is only available while the issue is active."
      }
    end
  end

  defp done_operator_summary(nil, decision_history), do: done_summary_from_history(decision_history)

  defp done_operator_summary(run_state, decision_history) when is_map(run_state) do
    stage = Map.get(run_state, :stage)
    merge_url = get_in(run_state, [:last_merge, :url])
    post_merge_status = normalize_result_status(get_in(run_state, [:last_post_merge, :status]))
    preview_status = normalize_result_status(get_in(run_state, [:last_deploy_preview, :status]))
    post_deploy_status = normalize_result_status(get_in(run_state, [:last_post_deploy_verify, :status]))

    cond do
      stage != "done" ->
        done_summary_from_history(decision_history)

      is_binary(merge_url) and merge_url != "" and preview_status == :passed and post_deploy_status == :passed ->
        "Autonomously finalized after merge, preview deployment, and post-deploy verification passed (#{merge_url})."

      is_binary(merge_url) and merge_url != "" and preview_status == :passed ->
        "Autonomously finalized after merge and preview deployment completed (#{merge_url})."

      is_binary(merge_url) and merge_url != "" and post_merge_status == :passed ->
        "Autonomously finalized after merge and post-merge verification passed (#{merge_url})."

      is_binary(merge_url) and merge_url != "" ->
        "Autonomously finalized after merge completed (#{merge_url})."

      post_merge_status == :passed ->
        "Autonomously finalized after post-merge verification passed."

      true ->
        done_summary_from_history(decision_history)
    end
  end

  defp done_summary_from_history(history) when is_list(history) do
    post_merge =
      Enum.find(history, fn entry -> Map.get(entry, :event_type) == "post_merge.completed" end) ||
        Enum.find(history, fn entry -> Map.get(entry, "event_type") == "post_merge.completed" end)

    preview =
      Enum.find(history, fn entry -> Map.get(entry, :event_type) == "deploy.preview.completed" end) ||
        Enum.find(history, fn entry -> Map.get(entry, "event_type") == "deploy.preview.completed" end)

    post_deploy =
      Enum.find(history, fn entry -> Map.get(entry, :event_type) == "deploy.post_deploy.completed" end) ||
        Enum.find(history, fn entry -> Map.get(entry, "event_type") == "deploy.post_deploy.completed" end)

    merge =
      Enum.find(history, fn entry -> Map.get(entry, :event_type) == "merge.completed" end) ||
        Enum.find(history, fn entry -> Map.get(entry, "event_type") == "merge.completed" end)

    merge_url =
      cond do
        is_map(merge) ->
          Map.get(merge, :details) || Map.get(merge, "details") ||
            get_in(merge, [:metadata, :url]) || get_in(merge, ["metadata", "url"])

        true ->
          nil
      end

    cond do
      is_map(preview) and is_map(post_deploy) and is_binary(merge_url) and merge_url != "" ->
        "Autonomously finalized after merge, preview deployment, and post-deploy verification passed (#{merge_url})."

      is_map(preview) and is_binary(merge_url) and merge_url != "" ->
        "Autonomously finalized after merge and preview deployment completed (#{merge_url})."

      is_map(post_merge) and is_binary(merge_url) and merge_url != "" ->
        "Autonomously finalized after merge and post-merge verification passed (#{merge_url})."

      is_map(post_merge) ->
        "Autonomously finalized after post-merge verification passed."

      is_binary(merge_url) and merge_url != "" ->
        "Autonomously finalized after merge completed (#{merge_url})."

      true ->
        nil
    end
  end

  defp tracked_issue_policy_class(nil), do: nil

  defp tracked_issue_policy_class(tracked_issue) when is_map(tracked_issue) do
    case entry_value(tracked_issue, "policy_class") do
      nil ->
        labels = Map.get(tracked_issue, "labels") || Map.get(tracked_issue, :labels) || []
        policy_labels = IssuePolicy.policy_labels(%{labels: labels})

        case policy_labels do
          [] ->
            nil

          _ ->
            case IssuePolicy.resolve(%{labels: labels}) do
              {:ok, resolution} -> IssuePolicy.class_to_string(resolution.class)
              _ -> nil
            end
        end

      value ->
        value
    end
  end

  defp normalize_result_status(value) when value in [:passed, :failed, :unavailable], do: value
  defp normalize_result_status("passed"), do: :passed
  defp normalize_result_status("failed"), do: :failed
  defp normalize_result_status("unavailable"), do: :unavailable
  defp normalize_result_status(_value), do: nil

  defp merge_window_waiting?(entry) when is_map(entry) do
    wait = Map.get(entry, :merge_window_wait)
    is_map(wait) and is_binary(Map.get(wait, :next_allowed_at) || Map.get(wait, "next_allowed_at"))
  end

  defp merge_window_wait_summary(entry) do
    wait = Map.get(entry, :merge_window_wait, %{})
    next_allowed_at = Map.get(wait, :next_allowed_at) || Map.get(wait, "next_allowed_at")
    timezone = Map.get(wait, :timezone) || Map.get(wait, "timezone") || "configured timezone"

    "Checks are green. Automerge is deferred until #{next_allowed_at} (#{timezone})."
  end

  defp deploy_window_waiting?(entry) when is_map(entry) do
    wait = Map.get(entry, :deploy_window_wait)
    is_map(wait) and is_binary(Map.get(wait, :next_allowed_at) || Map.get(wait, "next_allowed_at"))
  end

  defp deploy_window_wait_summary(entry) do
    wait = Map.get(entry, :deploy_window_wait, %{})
    next_allowed_at = Map.get(wait, :next_allowed_at) || Map.get(wait, "next_allowed_at")
    timezone = Map.get(wait, :timezone) || Map.get(wait, "timezone") || "configured timezone"

    "Production deploy is deferred until #{next_allowed_at} (#{timezone})."
  end

  defp run_state_policy_class(nil), do: nil

  defp run_state_policy_class(run_state) when is_map(run_state) do
    case Map.get(run_state, :last_rule_id) do
      "policy.review_required" -> "review_required"
      "policy.never_automerge" -> "never_automerge"
      _ -> nil
    end
  end

  defp runtime_mode_payload(entry) do
    stage = Map.get(entry, :stage)
    passive? = Map.get(entry, :passive?, false)

    cond do
      passive? and stage in ["merge_readiness", "await_checks", "merge", "post_merge", "deploy_preview", "deploy_production", "post_deploy_verify"] ->
        %{label: "Passive runtime", tone: "info"}

      stage in ["merge_readiness", "await_checks", "merge", "post_merge", "deploy_preview", "deploy_production", "post_deploy_verify"] ->
        %{label: "Passive handoff", tone: "warn"}

      true ->
        %{label: "Active agent", tone: "good"}
    end
  end

  defp status_summary_payload(entry, review) do
    stage = Map.get(entry, :stage)
    next_human_action = Map.get(entry, :next_human_action)
    review_approved? = Map.get(entry, :review_approved, false)
    token_pressure = Map.get(entry, :token_pressure)

    automatic_next =
      cond do
        stage == "implement" ->
          "Continue editing until the runtime can validate the diff."

        stage == "validate" ->
          "Run the repo validation contract and either continue or return to implement."

        stage == "verify" ->
          "Run smoke plus verifier proof checks before publish."

        stage == "publish" ->
          "Create or update the PR and attach publish metadata."

        stage == "merge_readiness" ->
          "Refresh PR hygiene and posted review thread state before passive check polling continues."

        stage == "await_checks" and merge_window_waiting?(entry) ->
          "Wait for the next allowed merge window before automerge continues."

        stage == "await_checks" and review_approved? ->
          "Wait for required checks to pass, then merge automatically."

        stage == "await_checks" and review.ready_for_merge ->
          "Checks and approvals are satisfied; the runtime can merge as soon as policy allows."

        stage == "await_checks" ->
          "Wait for required checks or approval changes without spawning a coding turn."

        stage == "merge" ->
          "Merge the PR without starting another agent turn."

        stage == "post_merge" ->
          "Run post-merge verification and finalize the issue."

        stage == "deploy_preview" ->
          "Run the preview deployment command."

        stage == "deploy_production" and deploy_window_waiting?(entry) ->
          "Wait for the next allowed production deploy window before deploying."

        stage == "deploy_production" ->
          "Run the production deployment command."

        stage == "post_deploy_verify" ->
          "Verify the preview deployment and finalize the issue."

        true ->
          "Continue the current stage until the next runtime gate is satisfied."
      end

    tone =
      cond do
        token_pressure == "high" -> "warn"
        stage in ["merge_readiness", "await_checks", "merge", "post_merge", "deploy_preview", "post_deploy_verify"] -> "info"
        true -> "muted"
      end

    summary =
      cond do
        token_pressure == "high" ->
          "Retry context is compressed because the previous agent turn ran hot on input tokens."

        stage == "merge_readiness" ->
          merge_readiness_status_summary(entry)

        stage == "await_checks" and review_approved? ->
          "Approval is already recorded. This issue is waiting only on passive merge readiness."

        stage == "await_checks" and merge_window_waiting?(entry) ->
          merge_window_wait_summary(entry)

        stage == "await_checks" and Map.get(review, :required_checks_passed) ->
          "Checks are green. The next state depends on review policy or operator approval."

        stage == "post_merge" ->
          "The coding and merge path is complete. Only post-merge verification and finalization remain."

        stage == "deploy_preview" ->
          "The merge path is complete. The runtime is now creating the preview deployment."

        stage == "deploy_production" and deploy_window_waiting?(entry) ->
          deploy_window_wait_summary(entry)

        stage == "deploy_production" ->
          "Preview deployment is complete. The runtime is now promoting the change to production."

        stage == "post_deploy_verify" ->
          "The preview deployment completed. Only post-deploy verification and finalization remain."

        is_binary(next_human_action) and next_human_action != "" ->
          next_human_action

        true ->
          automatic_next
      end

    %{
      tone: tone,
      summary: summary,
      automatic_next: automatic_next
    }
  end

  defp policy_next_human_action(entry, review) do
    cond do
      Map.get(entry, :stage) == "merge_readiness" ->
        "No human action is required unless the passive runtime reports a failure."

      Map.get(entry, :stage) == "await_checks" and Map.get(entry, :review_approved, false) ->
        "No human action is required unless checks fail."

      Map.get(entry, :stage) in ["merge", "post_merge"] ->
        "No human action is required unless the passive runtime reports a failure."

      Map.get(entry, :stage) == "await_checks" and review.ready_for_merge ->
        "Approve for merge if the policy requires explicit operator approval."

      is_binary(Map.get(entry, :next_human_action)) and String.trim(Map.get(entry, :next_human_action)) != "" ->
        Map.get(entry, :next_human_action)

      true ->
        nil
    end
  end

  defp merge_readiness_status_summary(entry) do
    merge_readiness = merge_readiness_payload(entry)

    cond do
      is_nil(merge_readiness) ->
        "The runtime is refreshing PR hygiene before passive check polling resumes."

      merge_readiness.pending_reply_refreshes > 0 ->
        "Refreshing #{merge_readiness.pending_reply_refreshes} posted review #{reply_word(merge_readiness.pending_reply_refreshes)} and #{merge_readiness.resolved_review_threads} resolved #{thread_word(merge_readiness.resolved_review_threads)} before check polling resumes."

      merge_readiness.pr_body_validation_status in ["passed", "updated"] ->
        "PR hygiene is up to date. Passive check polling will resume after this merge-readiness pass."

      true ->
        "The runtime is reconciling PR body and review-thread state before passive check polling resumes."
    end
  end

  defp reply_word(1), do: "reply"
  defp reply_word(_count), do: "replies"

  defp thread_word(1), do: "thread"
  defp thread_word(_count), do: "threads"

  defp human_attention_entry?(entry) do
    summary = Map.get(entry, :operator_summary, %{})

    present_value?(Map.get(summary, :human_action_required)) or
      normalize_state(Map.get(entry, :state)) in ["human review", "await approval"] or
      normalize_state(Map.get(summary, :current_stage)) in ["human review", "await approval"]
  end

  defp passive_waiting_entry?(entry) do
    stage = Map.get(entry, :stage)
    passive? = get_in(entry, [:runtime_mode, :label]) == "Passive runtime"

    passive? or
      stage in ["merge_readiness", "await_checks", "merge", "post_merge", "deploy_preview", "deploy_production", "post_deploy_verify"]
  end

  defp queue_attention_entry?(entry) do
    present_value?(Map.get(entry, :next_human_action)) or
      present_value?(Map.get(entry, :last_rule_id)) or
      present_value?(Map.get(entry, :error))
  end

  defp recent_attention_entries_from_ledger(ledger_entries, running, retrying, paused, skipped, queue) do
    active_ids =
      Enum.concat([running, retrying, paused, skipped, queue])
      |> Enum.map(&Map.get(&1, :issue_identifier))
      |> MapSet.new()

    ledger_entries
    |> Enum.filter(fn entry ->
      event = entry_value(entry, "event_type") || entry_value(entry, "event")
      event == "runtime.stopped" and not MapSet.member?(active_ids, entry_value(entry, "issue_identifier"))
    end)
    |> Enum.take(5)
    |> Enum.map(&triage_entry_payload_from_ledger(&1, "attention_now"))
  end

  defp recent_finished_entries_from_ledger(ledger_entries) do
    terminal_events = MapSet.new(["post_merge.completed", "deploy.post_deploy.completed", "merge.completed"])

    ledger_entries
    |> Enum.filter(fn entry ->
      MapSet.member?(terminal_events, entry_value(entry, "event_type") || entry_value(entry, "event"))
    end)
    |> Enum.uniq_by(&entry_value(&1, "issue_identifier"))
    |> Enum.take(5)
    |> Enum.map(&triage_entry_payload_from_ledger(&1, "recently_finished"))
  end

  defp uniq_triage_entries(entries) do
    entries
    |> Enum.reject(&is_nil(Map.get(&1, :issue_identifier)))
    |> Enum.uniq_by(&{Map.get(&1, :bucket), Map.get(&1, :issue_identifier)})
  end

  defp triage_tone("attention_now", _entry), do: "danger"
  defp triage_tone("autonomous_now", _entry), do: "good"
  defp triage_tone("waiting_safe", _entry), do: "info"
  defp triage_tone("recently_finished", _entry), do: "muted"
  defp triage_tone(_, _entry), do: "muted"

  defp queued_reason_summary(entry) do
    cond do
      present_value?(Map.get(entry, :error)) ->
        Map.get(entry, :error)

      not Map.get(entry, :label_gate_eligible, true) ->
        "Issue is queued but currently not eligible for routing under the active label gate."

      true ->
        "Issue is eligible and waiting for runtime dispatch."
    end
  end

  defp queued_next_step(entry) do
    cond do
      present_value?(Map.get(entry, :next_human_action)) ->
        "Wait for the required operator action before dispatch."

      present_value?(Map.get(entry, :error)) ->
        "Resolve the queue error or refresh the runtime before dispatch can continue."

      true ->
        "Wait for runtime dispatch."
    end
  end

  defp skipped_reason_summary(entry) do
    Map.get(entry, :last_decision_summary) ||
      Map.get(entry, :reason) ||
      "Issue is currently ineligible under the active routing or policy rules."
  end

  defp ledger_next_action(entry, "attention_now") do
    entry_value(entry, "human_action") || "Inspect the blocked issue details before retrying."
  end

  defp ledger_next_action(_entry, "recently_finished"), do: "No immediate action is required."
  defp ledger_next_action(_entry, _bucket), do: nil

  defp present_value?(nil), do: false
  defp present_value?(""), do: false
  defp present_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_value?(value) when is_list(value), do: value != []
  defp present_value?(value), do: not is_nil(value)

  defp policy_token_budget_payload(entry) do
    budget_runtime = normalize_budget_runtime(Map.get(entry, :budget_runtime))

    %{
      per_turn_input:
        budget_status_payload(
          Map.get(entry, :current_turn_input_tokens, 0),
          Map.get(budget_runtime, :per_turn_input_hard) || Config.policy_per_turn_input_budget()
        ),
      per_issue_total:
        budget_status_payload(
          Map.get(entry, :codex_total_tokens, 0),
          Map.get(budget_runtime, :per_issue_total_limit) || Config.policy_per_issue_total_budget()
        ),
      per_issue_total_output:
        budget_status_payload(
          Map.get(entry, :codex_output_tokens, 0),
          Config.policy_per_issue_total_output_budget()
        ),
      review_fix: budget_runtime
    }
  end

  defp normalize_budget_runtime(runtime) when is_map(runtime) do
    %{
      mode: Map.get(runtime, :mode) || Map.get(runtime, "mode") || "broad",
      admission_reason: Map.get(runtime, :admission_reason) || Map.get(runtime, "admission_reason"),
      pressure_level: Map.get(runtime, :pressure_level) || Map.get(runtime, "pressure_level") || "normal",
      retry_count: Map.get(runtime, :retry_count) || Map.get(runtime, "retry_count") || 0,
      window_base_turn: Map.get(runtime, :window_base_turn) || Map.get(runtime, "window_base_turn"),
      last_stop_code: Map.get(runtime, :last_stop_code) || Map.get(runtime, "last_stop_code"),
      last_observed_input_tokens:
        Map.get(runtime, :last_observed_input_tokens) ||
          Map.get(runtime, "last_observed_input_tokens"),
      scope_kind: Map.get(runtime, :scope_kind) || Map.get(runtime, "scope_kind"),
      scope_ids: Map.get(runtime, :scope_ids) || Map.get(runtime, "scope_ids") || [],
      auto_narrowed: Map.get(runtime, :auto_narrowed) || Map.get(runtime, "auto_narrowed") || false,
      total_extension_used:
        Map.get(runtime, :total_extension_used) ||
          Map.get(runtime, "total_extension_used") ||
          false,
      target_paths: Map.get(runtime, :target_paths) || Map.get(runtime, "target_paths") || [],
      next_required_path: Map.get(runtime, :next_required_path) || Map.get(runtime, "next_required_path"),
      expansion_used:
        Map.get(runtime, :expansion_used) ||
          Map.get(runtime, "expansion_used") ||
          false,
      per_turn_input_soft: Map.get(runtime, :per_turn_input_soft) || Map.get(runtime, "per_turn_input_soft"),
      per_turn_input_hard: Map.get(runtime, :per_turn_input_hard) || Map.get(runtime, "per_turn_input_hard"),
      max_turns_in_window: Map.get(runtime, :max_turns_in_window) || Map.get(runtime, "max_turns_in_window"),
      per_issue_total_limit: Map.get(runtime, :per_issue_total_limit) || Map.get(runtime, "per_issue_total_limit"),
      per_issue_total_extension:
        Map.get(runtime, :per_issue_total_extension) ||
          Map.get(runtime, "per_issue_total_extension")
    }
  end

  defp normalize_budget_runtime(_runtime) do
    %{
      mode: "broad",
      admission_reason: nil,
      pressure_level: "normal",
      retry_count: 0,
      window_base_turn: nil,
      last_stop_code: nil,
      last_observed_input_tokens: nil,
      scope_kind: nil,
      scope_ids: [],
      auto_narrowed: false,
      total_extension_used: false,
      target_paths: [],
      next_required_path: nil,
      expansion_used: false,
      per_turn_input_soft: nil,
      per_turn_input_hard: nil,
      max_turns_in_window: nil,
      per_issue_total_limit: nil,
      per_issue_total_extension: nil
    }
  end

  defp budget_runtime_issue(%{} = tracked_issue, run_state) do
    %{
      id: entry_value(tracked_issue, "id") || Map.get(run_state || %{}, :issue_id),
      identifier:
        entry_value(tracked_issue, "identifier") ||
          Map.get(run_state || %{}, :issue_identifier),
      title: entry_value(tracked_issue, "title"),
      description: entry_value(tracked_issue, "description"),
      labels: entry_value(tracked_issue, "labels") || []
    }
  end

  defp budget_runtime_issue(_tracked_issue, run_state) when is_map(run_state) do
    %{
      id: Map.get(run_state, :issue_id),
      identifier: Map.get(run_state, :issue_identifier)
    }
  end

  defp budget_runtime_issue(_tracked_issue, _run_state), do: %{}

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
    event = entry_value(entry, "event_type") || entry_value(entry, "event")

    summary =
      cond do
        event == "runtime.repaired" ->
          repair_stage = get_in(entry, ["metadata", "repair_stage"]) || entry_value(entry_value(entry, "metadata") || %{}, "repair_stage")
          reason = entry_value(entry, "summary") || "Automatic repair completed."

          if is_binary(repair_stage) and String.trim(repair_stage) != "" do
            "auto-healed to #{repair_stage}: #{truncate_text(reason, 120)}"
          else
            "auto-healed: #{truncate_text(reason, 120)}"
          end

        event == "merge.completed" ->
          entry_value(entry, "summary") || "merge completed"

        event == "post_merge.completed" ->
          entry_value(entry, "summary") || "post-merge verification completed"

        event == "deploy.preview.completed" ->
          entry_value(entry, "summary") || "preview deployment completed"

        event == "deploy.post_deploy.completed" ->
          entry_value(entry, "summary") || "post-deploy verification completed"

        value = entry_value(entry, "summary") ->
          value

        value = entry_value(entry, "rule_id") ->
          value

        value = entry_value(entry, "resume_state") ->
          "resume to #{value}"

        value = entry_value(entry, "target_state") ->
          "target state #{value}"

        true ->
          event || "ledger event"
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
      behavioral_proof: entry_value(result, "behavioral_proof"),
      ui_proof: entry_value(result, "ui_proof"),
      metadata: entry_value(result, "metadata"),
      compatibility_report: compatibility_report_from_result(result),
      reason_code: entry_value(result, "reason_code"),
      ledger_event_id: entry_value(result, "ledger_event_id"),
      output:
        result
        |> entry_value("output")
        |> Kernel.||(entry_value(result, "raw_output"))
        |> case do
          value when is_binary(value) -> truncate_text(value, 240)
          nil -> nil
          value -> truncate_text(to_string(value), 240)
        end
    }
  end

  defp normalize_command_result(result), do: %{status: nil, command: nil, output: truncate_text(result, 240)}

  defp compatibility_report_from(nil), do: nil

  defp compatibility_report_from(run_state) when is_map(run_state) do
    run_state
    |> Map.get(:last_decision)
    |> compatibility_report_from_result()
  end

  defp compatibility_report_from_result(nil), do: nil

  defp compatibility_report_from_result(result) when is_map(result) do
    case entry_value(result, "metadata") do
      %{} = metadata -> entry_value(metadata, "compatibility_report")
      _ -> nil
    end
  end

  defp compatibility_report_from_result(_result), do: nil

  defp recent_delivery_issue_identifiers(entries) when is_list(entries) do
    entries
    |> Enum.filter(fn entry ->
      Map.get(entry, "event_type") in [
        "merge.completed",
        "post_merge.completed",
        "deploy.preview.completed",
        "deploy.production.completed",
        "deploy.post_deploy.completed"
      ]
    end)
    |> Enum.map(&Map.get(&1, "issue_identifier"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp delivery_involved?(delivery, :deploy) do
    Enum.any?(
      [
        get_in(delivery, [:evidence, :preview_deploy_status]),
        get_in(delivery, [:evidence, :production_deploy_status]),
        get_in(delivery, [:evidence, :post_deploy_status])
      ],
      &(&1 in [:passed, "passed", :failed, "failed", :pending, "pending"])
    )
  end

  defp delivery_involved?(delivery, :approval) do
    get_in(delivery, [:approvals, :review_required]) || get_in(delivery, [:approvals, :deploy_required])
  end

  defp delivery_pr_url_from_history(history) when is_list(history) do
    history
    |> Enum.find_value(fn entry ->
      normalize_pr_url(get_in(entry, [:metadata, :url]) || get_in(entry, ["metadata", "url"])) ||
        delivery_pr_url_from_summary(Map.get(entry, :message) || Map.get(entry, "message")) ||
        delivery_pr_url_from_summary(Map.get(entry, :summary) || Map.get(entry, "summary")) ||
        delivery_pr_url_from_summary(Map.get(entry, :details) || Map.get(entry, "details"))
    end)
  end

  defp delivery_pr_url_from_summary(summary) when is_binary(summary) do
    case Regex.run(~r/https:\/\/github\.com\/[^\s)]+/u, summary) do
      [url | _] -> normalize_pr_url(url)
      _ -> nil
    end
  end

  defp delivery_pr_url_from_summary(_summary), do: nil

  defp normalize_pr_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.split("#", parts: 2)
    |> hd()
    |> String.replace(~r/[.,;:]+$/u, "")
  end

  defp normalize_pr_url(_url), do: nil

  defp decision_history_contains?(history, event_type) when is_list(history) do
    Enum.any?(history, fn entry ->
      Map.get(entry, :event_type) == event_type or Map.get(entry, "event_type") == event_type
    end)
  end

  defp normalize_atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_atom_string(value), do: value

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
      String.contains?(event, "runtime.repaired") -> "good"
      String.contains?(event, "post_merge.completed") -> "good"
      String.contains?(event, "deploy.preview.completed") -> "good"
      String.contains?(event, "deploy.post_deploy.completed") -> "good"
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
    case IssueSource.fetch_issue(%{canonical_identifier: issue_identifier}) do
      {:ok, nil} -> nil
      {:ok, issue} when is_map(issue) -> normalize_tracked_issue_payload(issue)
      _ -> nil
    end
  end

  defp normalize_tracked_issue_payload(%Issue{} = issue) do
    issue
    |> Map.from_struct()
    |> Map.update(:source, nil, &normalize_issue_source/1)
    |> Map.update(:created_at, nil, &normalize_timestamp/1)
    |> Map.update(:updated_at, nil, &normalize_timestamp/1)
  end

  defp normalize_tracked_issue_payload(issue) when is_map(issue), do: issue

  defp normalize_issue_source(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_issue_source(value), do: value

  defp decision_history_payload(entries) do
    entries
    |> Enum.map(fn entry ->
      event = entry_value(entry, "event_type") || entry_value(entry, "event")

      %{
        event_id: entry_value(entry, "event_id"),
        event_type: event,
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
        metadata: entry_value(entry, "metadata") || %{},
        message: ledger_message(entry),
        tone: ledger_activity_tone(event)
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
  @spec helper_for_test(atom(), list()) :: term()
  def helper_for_test(:issue_status, [running, retry, paused, queue, tracked_issue, run_state]),
    do: issue_status(running, retry, paused, queue, tracked_issue, run_state)

  def helper_for_test(:tracked_issue_payload, [issue_identifier]),
    do: tracked_issue_payload(issue_identifier)

  def helper_for_test(:running_entry_payload, [entry, ledger_by_issue]),
    do: running_entry_payload(entry, ledger_by_issue)

  def helper_for_test(:status_summary_payload, [entry, review]), do: status_summary_payload(entry, review)

  def helper_for_test(:runtime_health_summary, [entry, workspace, harness, review]),
    do:
      runtime_health_summary(
        entry,
        workspace,
        harness,
        review,
        RiskClassifier.classify(
          entry,
          workspace,
          Map.get(harness, :raw),
          WorkflowProfile.resolve(
            Map.get(entry, :policy_class),
            policy_pack: Map.get(entry, :policy_pack) || Config.policy_pack_name()
          )
        )
      )

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
