defmodule SymphonyElixir.WebPhase6BackfillTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Config, RunLedger, RunStateStore, StatusDashboard}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.Presenter

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule BackfillOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def put_snapshot(name, snapshot), do: GenServer.call(name, {:put_snapshot, snapshot})
    def put_refresh(name, refresh), do: GenServer.call(name, {:put_refresh, refresh})
    def put_responses(name, responses), do: GenServer.call(name, {:put_responses, responses})

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.get(state, :snapshot, empty_snapshot()), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call({:put_snapshot, snapshot}, _from, state) do
      {:reply, :ok, Keyword.put(state, :snapshot, snapshot)}
    end

    def handle_call({:put_refresh, refresh}, _from, state) do
      {:reply, :ok, Keyword.put(state, :refresh, refresh)}
    end

    def handle_call({:put_responses, responses}, _from, state) do
      merged =
        state
        |> Keyword.get(:responses, %{})
        |> Map.merge(responses)

      {:reply, :ok, Keyword.put(state, :responses, merged)}
    end

    def handle_call(message, _from, state) do
      send(Keyword.fetch!(state, :test_pid), {:orchestrator_call, message})
      {:reply, Map.get(Keyword.get(state, :responses, %{}), message, :unavailable), state}
    end

    defp empty_snapshot do
      %{
        running: [],
        retrying: [],
        paused: [],
        skipped: [],
        queue: [],
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: nil,
        polling: %{}
      }
    end
  end

  defmodule ReviewFeedbackGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def existing_pull_request(_workspace, _opts), do: {:error, :missing_pr}

    @impl true
    def edit_pull_request(_workspace, _title, _body_file, _opts), do: {:error, :unsupported}

    @impl true
    def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, _opts),
      do: {:error, :unsupported}

    @impl true
    def merge_pull_request(_workspace, _opts), do: {:error, :unsupported}

    @impl true
    def review_feedback(_workspace, _opts) do
      {:ok,
       %{
         pr_url: "https://github.com/example/repo/pull/99",
         review_decision: "CHANGES_REQUESTED",
         reviews: [
           %{id: 101, body: "Please cover the empty state too.", state: "CHANGES_REQUESTED", author: "reviewer"}
         ],
         comments: [
           %{id: 102, body: "nit: keep the copy consistent", path: "lib/example.ex", line: 12, author: "reviewer"}
         ]
       }}
    end

    @impl true
    def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok

    @impl true
    def post_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    previous_pr_watcher_github_client = Application.get_env(:symphony_elixir, :pr_watcher_github_client)
    log_root = Path.join(System.tmp_dir!(), "symphony-elixir-web-#{System.unique_integer([:positive])}")

    File.mkdir_p!(log_root)
    Application.put_env(:symphony_elixir, :log_file, Path.join(log_root, "app.log"))

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      if is_nil(previous_pr_watcher_github_client) do
        Application.delete_env(:symphony_elixir, :pr_watcher_github_client)
      else
        Application.put_env(:symphony_elixir, :pr_watcher_github_client, previous_pr_watcher_github_client)
      end

      File.rm_rf(log_root)
    end)

    :ok
  end

  test "dashboard live renders refresh and control error flashes" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardLiveErrors)

    start_supervised!(
      {BackfillOrchestrator,
       name: orchestrator_name,
       test_pid: self(),
       snapshot: base_snapshot(),
       refresh: :unavailable,
       responses: %{
         {:pause_issue, "MT-WEB"} => %{
           ok: false,
           action: "pause",
           issue_identifier: "MT-WEB",
           error: "already paused"
         },
         {:stop_issue, "MT-WEB"} => :unavailable
       }}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-WEB"

    assert render_click(view, "refresh", %{}) =~ "Operations Dashboard"

    pause_html =
      render_click(view, "control", %{
        "issue_identifier" => "MT-WEB",
        "action" => "pause"
      })

    assert pause_html =~ "Operations Dashboard"
    assert_receive {:orchestrator_call, {:pause_issue, "MT-WEB"}}

    stop_html =
      render_click(view, "control", %{
        "issue_identifier" => "MT-WEB",
        "action" => "stop"
      })

    assert stop_html =~ "Operations Dashboard"
    assert_receive {:orchestrator_call, {:stop_issue, "MT-WEB"}}
  end

  test "presenter issue payload falls back to tracked issue and persisted run state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_name: "Client Boundary",
      company_internal_project_name: "Symphony Internal",
      company_internal_project_url: "https://linear.app/internal/project/symphony",
      company_mode: "client_safe",
      company_policy_pack: "client_safe"
    )

    issue = %Issue{
      id: "issue-web-fallback",
      identifier: "MT-WEB-FALLBACK",
      title: "Fallback payload",
      description: "Tracked only",
      state: "Human Review"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    workspace = Path.join(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)

    long_output = String.duplicate("validation output ", 30)

    compatibility_report = %{
      compatible: false,
      failing_checks: ["behavioral_proof"],
      checks: [
        %{
          id: "behavioral_proof",
          required: true,
          status: "failed",
          summary: "Behavioral proof missing.",
          details: "The harness must declare `verification.behavioral_proof`."
        }
      ]
    }

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "blocked", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               pr_url: "https://example.test/pr/fallback",
               last_pr_state: "OPEN",
               last_review_decision: "APPROVED",
               last_check_statuses: [
                 %{name: "ci / publish", status: "COMPLETED", conclusion: "SUCCESS"}
               ],
               last_required_checks_state: "passed",
               last_rule_id: "policy.review_required",
               last_failure_class: "policy",
               last_merge_readiness: %{
                 checked_at: "2026-03-17T08:30:00Z",
                 pr_body_validation_status: "passed",
                 posted_review_threads: 2,
                 pending_reply_refreshes: 1,
                 resolved_review_threads: 1
               },
               last_decision_summary: "Blocked due to policy.review_required.",
               next_human_action: "Ask for human review.",
               last_decision: %{
                 status: "failed",
                 command: "./scripts/validate.sh",
                 output: long_output,
                 metadata: %{
                   compatibility_report: compatibility_report
                 }
               }
             })

    orchestrator_name = Module.concat(__MODULE__, :PresenterFallbackOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: empty_snapshot()})

    assert {:ok, payload} = Presenter.issue_payload(issue.identifier, orchestrator_name, 50)
    assert payload.issue_identifier == issue.identifier
    assert payload.issue_id == issue.id
    assert payload.status == "Human Review"
    assert payload.company.name == "Client Boundary"
    assert payload.company.mode == "client_safe"
    assert payload.company.policy_pack == "client_safe"
    assert payload.review.pr_url == "https://example.test/pr/fallback"
    assert payload.review.pr_state == "OPEN"
    assert payload.review.review_decision == "APPROVED"

    assert payload.review.check_statuses == [
             %{name: "ci / publish", status: "COMPLETED", conclusion: "SUCCESS"}
           ]

    assert payload.review.required_checks_passed == true
    assert payload.running == nil
    assert payload.retry == nil
    assert payload.paused == nil
    assert payload.queue == nil
    assert payload.tracked.identifier == issue.identifier
    assert payload.last_rule_id == "policy.review_required"
    assert payload.last_failure_class == "policy"
    assert payload.next_human_action == "Ask for human review."
    assert payload.policy_class == "review_required"
    assert payload.workflow_profile.name == "review_required"
    assert payload.workflow_profile.approval_gate_kind == "client_approval"
    assert payload.workflow_profile.merge_mode == :review_gate
    assert payload.operator_summary.current_stage == "blocked"
    assert payload.operator_summary.human_action_required == "Ask for human review."
    assert payload.runtime_health.proof.compatibility_report_present
    assert payload.runtime_health.intake.company_mode == "client_safe"
    assert payload.runtime_health.summary == "Blocked due to policy.review_required."
    assert payload.runtime_health.passive_stage.last_merge_readiness

    assert payload.runtime_health.passive_stage.last_merge_readiness.pr_body_validation_status ==
             "passed"

    assert payload.runtime_health.passive_stage.last_merge_readiness.posted_review_threads == 2
    assert payload.last_decision.status == "failed"
    assert payload.last_decision.command == "./scripts/validate.sh"
    assert String.ends_with?(payload.last_decision.output, "…")
    assert payload.compatibility_report == compatibility_report
    assert payload.last_decision.compatibility_report == compatibility_report
  end

  test "presenter refresh and control payloads normalize timestamps and unexpected results" do
    requested_at = DateTime.utc_now()
    orchestrator_name = Module.concat(__MODULE__, :PresenterControlOrchestrator)

    start_supervised!(
      {BackfillOrchestrator,
       name: orchestrator_name,
       test_pid: self(),
       refresh: %{queued: true, requested_at: requested_at},
       responses: %{
         {:reprioritize_issue, "MT-WEB", nil} => %{
           ok: true,
           action: "reprioritize",
           issue_identifier: "MT-WEB",
           override_rank: nil
         },
         {:resume_issue, "MT-WEB"} => :unexpected
       }}
    )

    assert {:ok, refresh_payload} = Presenter.refresh_payload(orchestrator_name)
    assert refresh_payload.requested_at == DateTime.to_iso8601(requested_at)

    assert {:ok, control_payload} =
             Presenter.control_payload(
               "reprioritize",
               "MT-WEB",
               %{"override_rank" => "not-a-number"},
               orchestrator_name
             )

    assert control_payload.override_rank == nil
    assert_receive {:orchestrator_call, {:reprioritize_issue, "MT-WEB", nil}}

    assert {:error, :unknown_action} =
             Presenter.control_payload("resume", "MT-WEB", %{}, orchestrator_name)

    assert_receive {:orchestrator_call, {:resume_issue, "MT-WEB"}}

    assert {:error, :unknown_action} =
             Presenter.control_payload("bogus", "MT-WEB", %{}, orchestrator_name)
  end

  test "presenter runner control payload validates params and executes runner commands" do
    previous_cmd_fun = Application.get_env(:symphony_elixir, :runner_runtime_cmd_fun)

    Application.put_env(
      :symphony_elixir,
      :runner_runtime_cmd_fun,
      fn command, args, opts ->
        send(self(), {:runner_runtime_cmd, command, args, opts})
        {"runner ok\n", 0}
      end
    )

    on_exit(fn ->
      if is_nil(previous_cmd_fun) do
        Application.delete_env(:symphony_elixir, :runner_runtime_cmd_fun)
      else
        Application.put_env(:symphony_elixir, :runner_runtime_cmd_fun, previous_cmd_fun)
      end
    end)

    assert {:error, {:invalid_params, "git ref is required"}} =
             Presenter.runner_control_payload("promote", %{})

    assert {:ok, inspect_payload} = Presenter.runner_control_payload("inspect", %{})
    assert inspect_payload.ok == true
    assert is_map(inspect_payload.runner)
    assert inspect_payload.commands.promote =~ "promote <git-ref>"

    assert {:ok, promote_payload} =
             Presenter.runner_control_payload("promote", %{
               "ref" => "main",
               "canary_labels" => ["canary:symphony"]
             })

    assert promote_payload.ok == true
    assert promote_payload.action == "promote"
    assert_receive {:runner_runtime_cmd, "bash", [_script, "promote", "main", "--canary-label", "canary:symphony"], _opts}

    assert {:ok, rollback_payload} =
             Presenter.runner_control_payload("rollback", %{"release_sha" => "deadbeef"})

    assert rollback_payload.action == "rollback"
    assert_receive {:runner_runtime_cmd, "bash", [_script, "rollback", "deadbeef"], _opts}
  end

  test "observability api control returns 400 for unknown actions and 503 for unavailable orchestrators" do
    orchestrator_name = Module.concat(__MODULE__, :ApiControlOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: base_snapshot(), responses: %{{:pause_issue, "MT-WEB"} => :unavailable}})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(post(build_conn(), "/api/v1/MT-WEB/actions/unknown", %{}), 400) ==
             %{"error" => %{"code" => "unknown_action", "message" => "Unknown control action"}}

    assert json_response(post(build_conn(), "/api/v1/MT-WEB/actions/pause", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "observability api runner control returns validation and command payloads" do
    previous_cmd_fun = Application.get_env(:symphony_elixir, :runner_runtime_cmd_fun)

    Application.put_env(
      :symphony_elixir,
      :runner_runtime_cmd_fun,
      fn _command, args, _opts ->
        send(self(), {:runner_api_cmd, args})
        {"runner api ok\n", 0}
      end
    )

    on_exit(fn ->
      if is_nil(previous_cmd_fun) do
        Application.delete_env(:symphony_elixir, :runner_runtime_cmd_fun)
      else
        Application.put_env(:symphony_elixir, :runner_runtime_cmd_fun, previous_cmd_fun)
      end
    end)

    orchestrator_name = Module.concat(__MODULE__, :ApiRunnerControlOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: base_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(post(build_conn(), "/api/v1/runner/actions/promote", %{}), 400) ==
             %{
               "error" => %{
                 "code" => "invalid_params",
                 "message" => "git ref is required"
               }
             }

    response =
      post(build_conn(), "/api/v1/runner/actions/promote", %{
        "ref" => "main",
        "canary_labels" => ["canary:symphony"]
      })
      |> json_response(200)

    assert response["ok"] == true
    assert response["action"] == "promote"
    assert_receive {:runner_api_cmd, [_script, "promote", "main", "--canary-label", "canary:symphony"]}
  end

  test "observability api runner control maps inspect record_canary and command failures" do
    previous_cmd_fun = Application.get_env(:symphony_elixir, :runner_runtime_cmd_fun)

    Application.put_env(
      :symphony_elixir,
      :runner_runtime_cmd_fun,
      fn _command, args, _opts ->
        send(self(), {:runner_api_cmd, args})

        case args do
          [_script, "record-canary", "fail" | _rest] ->
            {"runner command failed\n", 9}

          _ ->
            {"runner api ok\n", 0}
        end
      end
    )

    on_exit(fn ->
      if is_nil(previous_cmd_fun) do
        Application.delete_env(:symphony_elixir, :runner_runtime_cmd_fun)
      else
        Application.put_env(:symphony_elixir, :runner_runtime_cmd_fun, previous_cmd_fun)
      end
    end)

    orchestrator_name = Module.concat(__MODULE__, :ApiRunnerControlFailureOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: base_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    inspect_response =
      post(build_conn(), "/api/v1/runner/actions/inspect", %{})
      |> json_response(200)

    assert inspect_response["ok"] == true
    assert inspect_response["action"] == "inspect"
    assert is_map(inspect_response["runner"])

    error_response =
      post(build_conn(), "/api/v1/runner/actions/record_canary", %{
        "result" => "fail",
        "issue" => "CLZ-22",
        "pr" => "https://github.com/gaspardip/symphony/pull/1"
      })
      |> json_response(409)

    assert error_response["error"]["code"] == "runner_command_failed"
    assert error_response["action"] == "record_canary"
    assert error_response["exit_status"] == 9
    assert_receive {:runner_api_cmd, [_script, "record-canary", "fail", "--issue", "CLZ-22", "--pr", "https://github.com/gaspardip/symphony/pull/1"]}
  end

  test "delivery report summarizes completed work in client-readable form" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_name: "Client Boundary",
      company_mode: "client_safe",
      company_policy_pack: "client_safe"
    )

    issue = %Issue{
      id: "issue-report-1",
      identifier: "MT-REPORT-1",
      title: "Delivery report item",
      description: "Tracked delivery",
      state: "Done"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    workspace = Path.join(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "done", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: "tracker",
               effective_policy_class: "review_required",
               last_decision_summary: "Autonomously finalized after merge completed.",
               last_validation: %{status: "passed"},
               last_verifier: %{status: "passed"},
               last_merge: %{url: "https://github.com/example/repo/pull/12"},
               last_post_merge: %{status: "passed"}
             })

    RunLedger.record("merge.completed", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      stage: "merge",
      actor_type: "runtime",
      summary: "Merged PR.",
      metadata: %{url: "https://github.com/example/repo/pull/12"}
    })

    RunLedger.record("post_merge.completed", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      stage: "post_merge",
      actor_type: "runtime",
      summary: "Post-merge verification passed."
    })

    orchestrator_name = Module.concat(__MODULE__, :DeliveryReportOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: empty_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/reports/delivery"), 200)

    assert payload["company"]["name"] == "Client Boundary"
    assert payload["company"]["mode"] == "client_safe"
    assert payload["summary"]["recent_deliveries"] >= 1

    report_item =
      Enum.find(payload["deliveries"], fn delivery ->
        delivery["issue_identifier"] == issue.identifier
      end)

    assert report_item["title"] == "Delivery report item"
    assert report_item["status"] == "Done"
    assert report_item["workflow_profile"]["name"] == "review_required"
    assert report_item["evidence"]["pr_url"] == "https://github.com/example/repo/pull/12"
    assert report_item["evidence"]["validation_status"] == "passed"
    assert report_item["evidence"]["verifier_status"] == "passed"
    assert report_item["proof"]["validation_status"] == "passed"
    assert report_item["proof"]["verifier_status"] == "passed"
    assert report_item["review_feedback"]["watcher_mode"] == "draft_only"
    assert report_item["review_feedback"]["thread_state_counts"] == %{}
    assert report_item["traceability"]["pr_url"] == "https://github.com/example/repo/pull/12"
    assert report_item["summary"]["why_here"] =~ "Autonomously finalized"
    assert report_item["explanation"]["ready_reason"] =~ "Autonomously completed"
    assert report_item["explanation"]["proof_used"]["behavioral"] == "unknown"
    assert report_item["explanation"]["proof_used"]["validation_status"] == "passed"
    assert report_item["explanation"]["approval_used"]["review_required"] == true
    assert report_item["explanation"]["still_needs_human_input"] == nil
    assert report_item["explanation"]["review_follow_up"] == "No tracked PR review feedback."
  end

  test "issue payload exposes traceability links for internal and external references" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_name: "Client Boundary",
      company_internal_project_name: "Symphony Internal",
      company_internal_project_url: "https://linear.app/internal/project/symphony",
      company_mode: "client_safe",
      company_policy_pack: "client_safe"
    )

    issue = %Issue{
      id: "issue-traceability-1",
      identifier: "MT-TRACE-1",
      title: "Traceability issue",
      description: "Tracked issue",
      state: "Human Review",
      url: "https://linear.app/client/issue/MT-TRACE-1",
      internal_identifier: "SYM-TRACE-1",
      internal_url: "https://linear.app/internal/issue/SYM-TRACE-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    workspace = Path.join(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "human_review", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: "tracker",
               last_merge: %{url: "https://github.com/example/repo/pull/77"}
             })

    orchestrator_name = Module.concat(__MODULE__, :TraceabilityIssueOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: empty_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/MT-TRACE-1"), 200)

    assert payload["traceability"]["source_issue_url"] == "https://linear.app/client/issue/MT-TRACE-1"
    assert payload["traceability"]["pr_url"] == "https://github.com/example/repo/pull/77"
    assert payload["traceability"]["internal_issue"]["identifier"] == "SYM-TRACE-1"
    assert payload["traceability"]["internal_issue"]["url"] == "https://linear.app/internal/issue/SYM-TRACE-1"
    assert payload["traceability"]["internal_project"]["name"] == "Symphony Internal"
    assert payload["traceability"]["internal_project"]["url"] == "https://linear.app/internal/project/symphony"
  end

  test "issue payload derives PR URL from review feedback history when persisted threads are cached" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_name: "Client Boundary",
      company_mode: "client_safe",
      company_policy_pack: "client_safe"
    )

    issue = %Issue{
      id: "issue-traceability-review-1",
      identifier: "MT-TRACE-REVIEW-1",
      title: "Review feedback traceability",
      description: "Tracked review feedback",
      state: "Human Review"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    workspace = Path.join(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "human_review", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: "tracker",
               review_threads: %{
                 "comment:1" => %{
                   "draft_state" => "drafted",
                   "draft_reply" => "Will address.",
                   "resolution_recommendation" => "keep_open_until_confirmed"
                 }
               },
               last_decision_summary: "New PR review feedback detected on https://github.com/example/repo/pull/88."
             })

    RunLedger.record("review.feedback_detected", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      stage: "human_review",
      actor_type: "runtime",
      summary: "Detected PR review feedback.",
      details: "New PR review feedback detected on https://github.com/example/repo/pull/88."
    })

    orchestrator_name = Module.concat(__MODULE__, :TraceabilityReviewIssueOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: empty_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/MT-TRACE-REVIEW-1"), 200)

    assert payload["traceability"]["pr_url"] == "https://github.com/example/repo/pull/88"
    assert payload["pr_watcher"]["review_feedback"]["status"] == "cached"
    assert payload["pr_watcher"]["review_feedback"]["pr_url"] == "https://github.com/example/repo/pull/88"
  end

  test "issue payload derives traceability pr_url from posted review thread replies when summaries are absent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_name: "Client Boundary",
      company_mode: "private_autopilot",
      company_policy_pack: "private_autopilot"
    )

    issue = %Issue{
      id: "issue-traceability-review-2",
      identifier: "MT-TRACE-REVIEW-2",
      title: "Review feedback traceability from threads",
      description: "Tracked review feedback",
      state: "Human Review"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    workspace = Path.join(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "human_review", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: "manual",
               review_threads: %{
                 "comment:1" => %{
                   "draft_state" => "posted",
                   "draft_reply" => "Already handled.",
                   "posted_reply_url" => "https://github.com/example/repo/pull/91#discussion_r1"
                 }
               }
             })

    orchestrator_name = Module.concat(__MODULE__, :TraceabilityReviewIssueFromThreadsOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: empty_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/MT-TRACE-REVIEW-2"), 200)

    assert payload["traceability"]["pr_url"] == "https://github.com/example/repo/pull/91"
    assert payload["pr_watcher"]["review_feedback"]["pr_url"] == "https://github.com/example/repo/pull/91"
  end

  test "delivery report includes review thread state counts and follow-up summary" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_name: "Client Boundary",
      company_mode: "private_autopilot",
      company_policy_pack: "private_autopilot"
    )

    issue = %Issue{
      id: "issue-delivery-review-report-1",
      identifier: "MT-DELIVERY-REVIEW-1",
      title: "Delivery review report item",
      description: "Tracked issue",
      state: "Human Review"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    workspace = Path.join(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "human_review", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: "manual",
               review_threads: %{
                 "comment:1" => %{
                   "draft_state" => "approved_to_post",
                   "draft_reply" => "Looks good to post.",
                   "posted_reply_url" => "https://github.com/example/repo/pull/90#discussion_r1"
                 },
                 "comment:2" => %{
                   "draft_state" => "posted",
                   "draft_reply" => "Already posted.",
                   "posted_reply_url" => "https://github.com/example/repo/pull/90#discussion_r2"
                 }
               },
               last_merge: %{url: "https://github.com/example/repo/pull/90"},
               last_decision_summary: "New PR review feedback detected on https://github.com/example/repo/pull/90."
             })

    RunLedger.record("review.feedback_detected", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      stage: "human_review",
      actor_type: "runtime",
      summary: "Detected PR review feedback.",
      details: "New PR review feedback detected on https://github.com/example/repo/pull/90."
    })

    RunLedger.record("merge.completed", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      stage: "merge",
      actor_type: "runtime",
      summary: "Merged PR.",
      metadata: %{url: "https://github.com/example/repo/pull/90"}
    })

    orchestrator_name = Module.concat(__MODULE__, :DeliveryReviewReportOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: empty_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/reports/delivery"), 200)

    report_item =
      Enum.find(payload["deliveries"], fn delivery ->
        delivery["issue_identifier"] == issue.identifier
      end)

    assert report_item["review_feedback"]["thread_state_counts"] == %{
             "approved_to_post" => 1,
             "posted" => 1
           }

    assert report_item["explanation"]["review_follow_up"] == "1 review thread(s) approved to post."
    assert report_item["traceability"]["pr_url"] == "https://github.com/example/repo/pull/90"
  end

  test "portfolio endpoint aggregates configured Symphony instances" do
    previous_fetcher = Application.get_env(:symphony_elixir, :portfolio_fetcher)

    Application.put_env(:symphony_elixir, :portfolio_fetcher, fn
      "http://runner-a.test" ->
        {:ok,
         %{
           "company" => %{"name" => "Alpha", "mode" => "private_autopilot"},
           "counts" => %{"running" => 1, "retrying" => 0, "paused" => 0, "queue" => 2, "skipped" => 0},
           "triage" => %{"summary" => %{"attention_now" => 1}}
         }}

      "http://runner-b.test" ->
        {:ok,
         %{
           "company" => %{"name" => "Beta", "mode" => "client_safe"},
           "counts" => %{"running" => 0, "retrying" => 1, "paused" => 0, "queue" => 1, "skipped" => 1},
           "triage" => %{"summary" => %{"attention_now" => 2}}
         }}
    end)

    on_exit(fn ->
      if is_nil(previous_fetcher) do
        Application.delete_env(:symphony_elixir, :portfolio_fetcher)
      else
        Application.put_env(:symphony_elixir, :portfolio_fetcher, previous_fetcher)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      portfolio_instances: [
        %{"name" => "Alpha Runner", "url" => "http://runner-a.test"},
        %{"name" => "Beta Runner", "url" => "http://runner-b.test"}
      ]
    )

    orchestrator_name = Module.concat(__MODULE__, :PortfolioOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: empty_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/portfolio"), 200)

    assert payload["totals"]["instances"] == 2
    assert payload["totals"]["healthy_instances"] == 2
    assert payload["totals"]["running"] == 1
    assert payload["totals"]["attention_now"] == 3

    assert Enum.any?(payload["instances"], fn instance ->
             instance["name"] == "Alpha Runner" and instance["company"]["name"] == "Alpha"
           end)

    assert Enum.any?(payload["instances"], fn instance ->
             instance["name"] == "Beta Runner" and instance["company"]["mode"] == "client_safe"
           end)
  end

  test "status dashboard notify_update is harmless without a server and disabled dashboards ignore refreshes" do
    missing_dashboard = Module.concat(__MODULE__, :MissingDashboard)
    assert :ok = StatusDashboard.notify_update(missing_dashboard)

    dashboard_name = Module.concat(__MODULE__, :DisabledDashboard)
    parent = self()

    start_supervised!({StatusDashboard, name: dashboard_name, enabled: false, refresh_ms: 5, render_interval_ms: 5, render_fun: fn content -> send(parent, {:render, content}) end})

    assert :ok = StatusDashboard.notify_update(dashboard_name)
    refute_receive {:render, _content}, 50

    send(Process.whereis(dashboard_name), :tick)
    refute_receive {:render, _content}, 50
  end

  test "dashboard live covers success branches, rerenders on update, and shows timeout payloads" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardLiveSecondWave)

    start_supervised!(
      {BackfillOrchestrator,
       name: orchestrator_name,
       test_pid: self(),
       snapshot: rich_snapshot(),
       refresh: %{queued: true, requested_at: ~U[2026-03-07 16:00:00Z]},
       responses: %{
         {:reprioritize_issue, "MT-QUEUE", 0} => %{
           ok: true,
           action: "boost",
           issue_identifier: "MT-QUEUE",
           override_rank: 0
         }
       }}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Retry queue"
    assert html =~ "Paused issues"
    assert html =~ "Skipped issues"
    assert html =~ "Ranked queue"
    assert html =~ "Polling now"
    assert html =~ "Directory exists, git missing"
    assert html =~ "Harness invalid"
    assert html =~ "Human Review blocked without PR"
    assert html =~ "No PR to merge"
    assert html =~ "Preview deploy"
    assert html =~ "Production deploy"
    assert html =~ "Post-deploy verify"
    assert html =~ "Deploy approval"
    assert html =~ "MT-QUEUE"

    assert :ok = BackfillOrchestrator.put_refresh(orchestrator_name, %{queued: true, requested_at: ~U[2026-03-07 16:05:00Z]})
    assert :ok = BackfillOrchestrator.put_snapshot(orchestrator_name, refreshed_snapshot())

    refresh_html = render_click(view, "refresh", %{})
    assert refresh_html =~ "MT-REFRESHED"
    refute refresh_html =~ "Polling now"

    assert :ok = BackfillOrchestrator.put_snapshot(orchestrator_name, boosted_snapshot())

    boost_html =
      render_click(view, "control", %{
        "issue_identifier" => "MT-QUEUE",
        "action" => "boost"
      })

    assert boost_html =~ "operator override"
    assert_receive {:orchestrator_call, {:reprioritize_issue, "MT-QUEUE", 0}}

    assert :ok = BackfillOrchestrator.put_snapshot(orchestrator_name, :timeout)
    send(view.pid, :observability_updated)

    error_html = render(view)
    assert error_html =~ "Snapshot unavailable"
    assert error_html =~ "snapshot_timeout"
  end

  test "presenter state and issue payloads cover policy, activity, retry, paused, queue, and run-state branches" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      policy_token_budget: %{per_turn_input: 10, per_issue_total: 20, per_issue_total_output: 15}
    )

    RunLedger.record("policy.decided", %{
      issue_id: "issue-paused",
      issue_identifier: "MT-PAUSED",
      stage: "review",
      actor_type: "operator",
      actor_id: "alice",
      rule_id: "policy.pause",
      summary: "Paused for review",
      details: "Operator requested review",
      target_state: "paused"
    })

    orchestrator_name = Module.concat(__MODULE__, :PresenterStateOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: rich_snapshot()})

    state_payload = Presenter.state_payload(orchestrator_name, 50)

    assert state_payload.counts == %{running: 1, retrying: 1, paused: 1, queue: 1, skipped: 1}
    assert state_payload.priority_overrides == %{"MT-QUEUE" => 7}
    assert state_payload.policy_overrides == %{"MT-QUEUE" => "review_required"}
    assert state_payload.polling.dispatch_mode == "manual_only_degraded"
    assert state_payload.polling.tracker_reads_paused == true
    assert state_payload.polling.manual_dispatch_enabled == true
    assert state_payload.polling.dispatch_summary =~ "manual issues continue to dispatch"
    assert state_payload.pr_watcher.enabled == true
    assert state_payload.pr_watcher.mode == "draft_first"
    assert state_payload.github_webhooks.health == "healthy"
    assert state_payload.github_inbox.last_assignment.assignment_state == "processed"
    assert state_payload.triage.summary.attention_now >= 3
    assert state_payload.triage.summary.autonomous_now == 0
    assert state_payload.triage.summary.recently_finished == 0

    [running] = state_payload.running
    assert running.last_message == "turn completed (completed) (in 11, out 4, total 15)"
    assert running.policy.checkout.label == "Directory exists, git missing"
    assert running.policy.validation.label == "Harness invalid"
    assert running.policy.pr_gate.label == "Human Review blocked without PR"
    assert running.policy.merge_gate.label == "No PR to merge"
    assert running.review.required_checks_passed == false
    assert running.review.missing_required_checks == ["lint"]
    assert running.policy.token_budget.per_turn_input.tone == "warn"
    assert running.policy.token_budget.per_issue_total.tone == "danger"
    assert running.policy.token_budget.per_issue_total_output.tone == "good"
    assert running.lease.owner == "orchestrator-rich"
    assert running.lease.status == "reclaimable"
    assert running.lease.reclaimable == true
    assert running.last_decision.output == String.duplicate("x", 239) <> "…"
    assert Enum.any?(running.recent_activity, &(&1.message == "turn failed: compiler boom"))
    assert Enum.any?(state_payload.activity, &(&1.issue_identifier == "runner" and &1.message =~ "rollback suggested"))

    [retrying] = state_payload.retrying
    assert retrying.issue_identifier == "MT-RETRY"
    assert retrying.priority_override == 4
    assert is_binary(retrying.due_at)
    assert retrying.operator_summary.automatic_next == "Issue is waiting for the retry window to expire."

    [paused] = state_payload.paused
    assert paused.resume_state == "in_progress"
    assert paused.operator_summary.human_action_required == "Resume the issue when work should continue."

    [skipped] = state_payload.skipped
    assert skipped.reason == "missing labels"
    assert skipped.lease.owner_channel == "canary"
    assert skipped.operator_summary.why_here == "Skipped"

    [queue] = state_payload.queue
    assert queue.label_gate_eligible == false
    assert queue.rank == 7
    assert queue.lease.owner == "queue-owner"
    assert queue.operator_summary.why_here == "Queued"
    assert queue.operator_summary.automatic_next == "Wait for the required operator action before dispatch."
    assert Enum.any?(state_payload.triage.attention_now, &(&1.issue_identifier == "MT-PAUSED"))
    assert Enum.any?(state_payload.triage.attention_now, &(&1.issue_identifier == "MT-SKIP"))

    assert {:ok, paused_payload} = Presenter.issue_payload("MT-PAUSED", orchestrator_name, 50)
    assert paused_payload.status == "paused"
    assert paused_payload.paused.resume_state == "in_progress"
    assert hd(paused_payload.decision_history).summary == "Paused for review"

    assert {:ok, retry_payload} = Presenter.issue_payload("MT-RETRY", orchestrator_name, 50)
    assert retry_payload.status == "retrying"
    assert retry_payload.retry.attempt == 2
    assert retry_payload.last_error == "API timeout"

    assert {:ok, queue_payload} = Presenter.issue_payload("MT-QUEUE", orchestrator_name, 50)
    assert queue_payload.status == "queued"
    assert queue_payload.queue.rank == 7

    workspace = Path.join(Config.workspace_root(), "MT-RUNSTATE")
    File.mkdir_p!(workspace)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "validate", %{
               issue_id: "issue-runstate",
               issue_identifier: "MT-RUNSTATE",
               last_decision: "plain-text validation output",
               stop_reason: %{
                 code: "review_fix_scope_exhausted",
                 rule_id: "budget.review_fix_scope_exhausted",
                 failure_class: "budget",
                 summary: "Scoped review-fix retries exhausted the narrowest available scope."
               }
             })

    assert {:ok, run_state_payload} = Presenter.issue_payload("MT-RUNSTATE", orchestrator_name, 50)
    assert run_state_payload.status == "validate"

    assert run_state_payload.last_decision == %{
             status: nil,
             command: nil,
             output: "plain-text validation output"
           }

    assert run_state_payload.stop_reason == %{
             code: "review_fix_scope_exhausted",
             rule_id: "budget.review_fix_scope_exhausted",
             failure_class: "budget",
             summary: "Scoped review-fix retries exhausted the narrowest available scope."
           }

    assert run_state_payload.tracked == %{}

    assert {:error, :issue_not_found} = Presenter.issue_payload("MT-MISSING", orchestrator_name, 50)

    assert :ok = BackfillOrchestrator.put_snapshot(orchestrator_name, :timeout)
    assert Presenter.state_payload(orchestrator_name, 50).error.code == "snapshot_timeout"

    assert :ok = BackfillOrchestrator.put_snapshot(orchestrator_name, :unavailable)
    assert Presenter.state_payload(orchestrator_name, 50).error.code == "snapshot_unavailable"
  end

  test "issue payload falls back to the latest ledger decision when no run state exists" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-ledger-fallback",
      identifier: "MT-LEDGER-FALLBACK",
      title: "Ledger fallback",
      description: "Use retry decision history when no run state exists yet",
      state: "Todo",
      labels: ["dogfood:symphony"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :LedgerFallbackOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: %{running: [], retrying: [], paused: [], skipped: [], queue: []}})

    RunLedger.record("operator.action", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      actor_type: "operator",
      actor_id: "dashboard",
      failure_class: "coordination",
      rule_id: "coordination.dispatch_slots_unavailable",
      summary: "Immediate retry deferred because no orchestrator dispatch slots are available.",
      metadata: %{
        action: "retry_now",
        dispatch_outcome: "deferred",
        human_action: "Wait for a free dispatch slot or raise the configured concurrency limit before retrying."
      }
    })

    assert {:ok, payload} = Presenter.issue_payload(issue.identifier, orchestrator_name, 50)
    assert payload.status == "Todo"
    assert payload.operator_summary.why_here =~ "no orchestrator dispatch slots"
    assert payload.operator_summary.human_action_required =~ "Wait for a free dispatch slot"
    assert payload.operator_summary.rule_id == "coordination.dispatch_slots_unavailable"
    assert payload.operator_summary.failure_class == "coordination"
  end

  test "presenter control payload covers remaining actions and tuple errors" do
    orchestrator_name = Module.concat(__MODULE__, :PresenterControlActionsOrchestrator)

    start_supervised!(
      {BackfillOrchestrator,
       name: orchestrator_name,
       test_pid: self(),
       responses: %{
         {:pause_issue, "MT-ACTION"} => %{ok: true, action: "pause", issue_identifier: "MT-ACTION"},
         {:stop_issue, "MT-ACTION"} => %{ok: true, action: "stop", issue_identifier: "MT-ACTION"},
         {:hold_issue_for_human_review, "MT-ACTION"} => %{
           ok: true,
           action: "hold_for_human_review",
           issue_identifier: "MT-ACTION"
         },
         {:retry_issue_now, "MT-ACTION"} => %{ok: true, action: "retry_now", issue_identifier: "MT-ACTION"},
         {:refresh_merge_readiness, "MT-ACTION"} => %{
           ok: true,
           action: "refresh_merge_readiness",
           issue_identifier: "MT-ACTION",
           stage: "merge_readiness"
         },
         {:approve_issue_for_merge, "MT-ACTION"} => {:error, :not_ready},
         {:reprioritize_issue, "MT-ACTION", 0} => %{
           ok: true,
           action: "boost",
           issue_identifier: "MT-ACTION",
           override_rank: 0
         },
         {:reprioritize_issue, "MT-ACTION", nil} => %{
           ok: true,
           action: "reset_priority",
           issue_identifier: "MT-ACTION",
           override_rank: nil
         },
         {:set_policy_class, "MT-ACTION", "review_required"} => %{
           ok: true,
           action: "set_policy_class",
           issue_identifier: "MT-ACTION",
           policy_class: "review_required"
         },
         {:clear_policy_override, "MT-ACTION"} => :unavailable
       }}
    )

    assert {:ok, %{action: "pause"}} =
             Presenter.control_payload("pause", "MT-ACTION", %{}, orchestrator_name)

    assert {:ok, %{action: "stop"}} =
             Presenter.control_payload("stop", "MT-ACTION", %{}, orchestrator_name)

    assert {:ok, %{action: "hold_for_human_review"}} =
             Presenter.control_payload("hold_for_human_review", "MT-ACTION", %{}, orchestrator_name)

    assert {:ok, %{action: "hold_for_human_review"}} =
             Presenter.control_payload("hold_for_approval", "MT-ACTION", %{}, orchestrator_name)

    assert {:ok, %{action: "retry_now"}} =
             Presenter.control_payload("retry_now", "MT-ACTION", %{}, orchestrator_name)

    assert {:ok, %{action: "refresh_merge_readiness", stage: "merge_readiness"}} =
             Presenter.control_payload("refresh_merge_readiness", "MT-ACTION", %{}, orchestrator_name)

    assert {:error, :not_ready} =
             Presenter.control_payload("approve_for_merge", "MT-ACTION", %{}, orchestrator_name)

    assert {:ok, %{override_rank: 0}} =
             Presenter.control_payload("boost", "MT-ACTION", %{}, orchestrator_name)

    assert {:ok, %{override_rank: nil}} =
             Presenter.control_payload("reset_priority", "MT-ACTION", %{}, orchestrator_name)

    assert {:ok, %{policy_class: "review_required"}} =
             Presenter.control_payload(
               "set_policy_class",
               "MT-ACTION",
               %{"policy_class" => "review_required"},
               orchestrator_name
             )

    assert {:error, :unavailable} =
             Presenter.control_payload("clear_policy_override", "MT-ACTION", %{}, orchestrator_name)

    assert_receive {:orchestrator_call, {:pause_issue, "MT-ACTION"}}
    assert_receive {:orchestrator_call, {:stop_issue, "MT-ACTION"}}
    assert_receive {:orchestrator_call, {:hold_issue_for_human_review, "MT-ACTION"}}
    assert_receive {:orchestrator_call, {:retry_issue_now, "MT-ACTION"}}
    assert_receive {:orchestrator_call, {:refresh_merge_readiness, "MT-ACTION"}}
    assert_receive {:orchestrator_call, {:approve_issue_for_merge, "MT-ACTION"}}
    assert_receive {:orchestrator_call, {:reprioritize_issue, "MT-ACTION", 0}}
    assert_receive {:orchestrator_call, {:reprioritize_issue, "MT-ACTION", nil}}
    assert_receive {:orchestrator_call, {:set_policy_class, "MT-ACTION", "review_required"}}
    assert_receive {:orchestrator_call, {:clear_policy_override, "MT-ACTION"}}
  end

  test "dashboard live handles runtime ticks, unknown controls, and unavailable snapshot updates" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardLiveUnavailable)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: base_snapshot(), refresh: :unavailable})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "MT-WEB"

    send(view.pid, :runtime_tick)

    tick_html = render(view)
    assert tick_html =~ "Operations Dashboard"
    assert tick_html =~ "MT-WEB"

    bogus_html =
      render_click(view, "control", %{
        "issue_identifier" => "MT-WEB",
        "action" => "bogus"
      })

    assert bogus_html =~ "Operations Dashboard"
    refute_receive {:orchestrator_call, _message}, 50

    assert :ok = BackfillOrchestrator.put_snapshot(orchestrator_name, :unavailable)
    send(view.pid, :observability_updated)

    unavailable_html = render(view)
    assert unavailable_html =~ "Snapshot unavailable"
    assert unavailable_html =~ "snapshot_unavailable"
  end

  test "dashboard live renders empty sections and runner canary details" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardLiveRunnerDetails)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: runner_canary_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "No active sessions."
    assert html =~ "No activity captured yet."
    assert html =~ "No issues are currently backing off."
    assert html =~ "No paused issues."
    assert html =~ "No active issues are currently being skipped by label gating."
    assert html =~ "No queued issues."
    assert html =~ "runner-canary"
    assert html =~ "canary_failed"
    assert html =~ "disabled"
    assert html =~ "invalid"
    assert html =~ "runner.current_mismatch"
    assert html =~ "dogfood, canary"
    assert html =~ "release-candidate"
    assert html =~ "Rollback suggested after smoke test"
    assert html =~ "CLZ-11"
    assert html =~ "gaspar/autonomous-pipeline"
    assert html =~ "rollback recommended"
    assert html =~ "gpt-5"
  end

  test "dashboard live renders policy matrix states and queue overrides" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardLivePolicyMatrix)

    start_supervised!(
      {BackfillOrchestrator,
       name: orchestrator_name,
       test_pid: self(),
       snapshot: policy_matrix_snapshot(),
       responses: %{
         {:set_policy_class, "MT-QUEUE-POLICY", "review_required"} => %{
           ok: true,
           action: "set_policy_class",
           issue_identifier: "MT-QUEUE-POLICY",
           policy_class: "review_required"
         }
       }}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Review state has PR"
    assert html =~ "Awaiting approval"
    assert html =~ "PR attached"
    assert html =~ "Awaiting review and checks"
    assert html =~ "Awaiting required checks"
    assert html =~ "No required checks configured yet."
    assert html =~ "No recent activity captured yet."
    assert html =~ "No checkout"
    assert html =~ "Validation command missing"
    assert html =~ "Open PR"
    assert html =~ "Missing dogfood label"
    assert html =~ "Policy review_required"
    assert html =~ "operator override"
    assert html =~ "Passive runtime"
    assert html =~ "Review approved"
    assert html =~ "Token pressure high"
    assert html =~ "Review approval"

    queue_html =
      render_click(view, "control", %{
        "issue_identifier" => "MT-QUEUE-POLICY",
        "action" => "set_policy_class",
        "policy_class" => "review_required"
      })

    assert queue_html =~ "Ranked queue"
    assert_receive {:orchestrator_call, {:set_policy_class, "MT-QUEUE-POLICY", "review_required"}}
  end

  test "presenter state payload covers optional policies, merge ready branches, and running issue payloads" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      policy_require_checkout: false,
      policy_require_validation: false,
      policy_require_pr_before_review: false,
      policy_token_budget: %{per_turn_input: nil, per_issue_total: nil, per_issue_total_output: nil}
    )

    orchestrator_name = Module.concat(__MODULE__, :PresenterGreenStateOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: green_snapshot()})

    state_payload = Presenter.state_payload(orchestrator_name, 50)

    assert state_payload.counts == %{running: 1, retrying: 0, paused: 0, queue: 0, skipped: 0}

    [running] = state_payload.running
    assert running.last_message == "thread started (thread-green)"
    assert running.started_at == "2026-03-07T16:00:00Z"
    assert running.last_event_at == "2026-03-07T16:01:00Z"
    assert running.policy.checkout.label == "Checkout optional"
    assert running.policy.validation.label == "Validation optional"
    assert running.policy.pr_gate.label == "PR gate disabled"
    assert running.policy.merge_gate.label == "Approved and checks green"
    assert running.review.required_checks == ["ci"]
    assert running.review.required_checks_passed == true
    assert running.review.missing_required_checks == []
    assert running.publish.pr_body_validation.status == "ok"
    assert running.publish.pr_body_validation.output == "123"
    assert running.publish.last_validation == %{status: nil, command: nil, output: "validation ok"}
    assert running.publish.last_verifier.status == "passed"
    assert running.publish.last_verifier.output == "456"
    assert running.publish.last_post_merge.output == "789"
    assert running.publish.last_deploy_preview.output == "preview ok"
    assert running.publish.last_deploy_production.output == "production ok"
    assert running.publish.deploy_approved == true
    assert running.publish.last_verifier_verdict == "safe"
    assert running.publish.acceptance_summary == "all green"
    assert running.publish.merge_sha == "abc123"
    assert running.publish.stop_reason == "merged"
    assert running.routing.eligible == true
    assert running.policy.token_budget.per_turn_input.tone == "good"
    assert running.policy.token_budget.per_issue_total.tone == "good"
    assert running.policy.token_budget.per_issue_total_output.tone == "muted"
    assert running.harness.deploy_preview_command == "./scripts/deploy-preview.sh"
    assert running.harness.deploy_production_command == "./scripts/deploy-production.sh"
    assert running.harness.deploy_rollback_command == "./scripts/deploy-rollback.sh"
    assert running.harness.post_deploy_verify_command == "./scripts/post-deploy-verify.sh"
    assert running.runtime_health.passive_stage.deploy_approved == true
    assert running.runtime_health.pr_watcher.mode == "draft_first"
    assert running.runtime_health.pr_watcher.posting_allowed == true
    assert running.runtime_health.deploy.preview_status == :passed
    assert running.runtime_health.deploy.production_status == :passed
    assert running.runtime_health.deploy.post_deploy_status == :passed
    assert running.runtime_health.risk.change_type
    assert running.runtime_health.risk.risk_level
    assert running.runtime_health.proof.proof_class
    assert running.operator_summary.risk_level
    assert running.operator_summary.proof_class
    assert running.operator_summary.pr_watcher.mode == "draft_first"

    workspace = Path.join(Config.workspace_root(), "MT-GREEN")
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    Application.put_env(:symphony_elixir, :pr_watcher_github_client, ReviewFeedbackGitHubClient)

    assert {:ok, issue_payload} = Presenter.issue_payload("MT-GREEN", orchestrator_name, 50)
    assert issue_payload.status == "running"
    assert issue_payload.pr_watcher.mode == "draft_first"
    assert issue_payload.pr_watcher.review_feedback.status == "ok"
    assert issue_payload.pr_watcher.review_feedback.pending_drafts_count == 2
    assert Enum.any?(issue_payload.pr_watcher.review_feedback.items, &(&1.kind == :review))
    assert Enum.any?(issue_payload.pr_watcher.review_feedback.items, &(&1.kind == :comment))
    assert issue_payload.review_thread_states == %{}
    assert issue_payload.issue_id == "issue-green"
    assert issue_payload.running.issue_identifier == "MT-GREEN"
    assert issue_payload.attempts.restart_count == 0
    assert issue_payload.attempts.current_retry_attempt == 0
    assert issue_payload.recent_events == []
  end

  test "issue payload hydrates persisted review thread state into review feedback drafts" do
    orchestrator_name = Module.concat(__MODULE__, :PresenterReviewThreadStateOrchestrator)

    review_running =
      green_running_entry()
      |> Map.put(:identifier, "MT-REVIEWSTATE")
      |> Map.put(:issue_id, "issue-reviewstate")
      |> Map.put(:workspace, "/tmp/MT-REVIEWSTATE")

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: %{base_snapshot() | running: [review_running]}})

    workspace = Path.join(Config.workspace_root(), "MT-REVIEWSTATE")
    File.mkdir_p!(workspace)
    Application.put_env(:symphony_elixir, :pr_watcher_github_client, ReviewFeedbackGitHubClient)

    {:ok, _state} =
      RunStateStore.transition(workspace, "publish", %{
        issue_id: "issue-reviewstate",
        issue_identifier: "MT-REVIEWSTATE",
        issue_source: "tracker",
        review_threads: %{
          "review:101" => %{
            "draft_state" => "approved_to_post",
            "draft_reply" => "Ready to send.",
            "resolution_recommendation" => "resolve_after_change"
          }
        }
      })

    assert {:ok, issue_payload} = Presenter.issue_payload("MT-REVIEWSTATE", orchestrator_name, 50)

    review_item =
      Enum.find(issue_payload.pr_watcher.review_feedback.items, &(&1.thread_key == "review:101"))

    assert issue_payload.review_thread_states["review:101"]["draft_state"] == "approved_to_post"
    assert review_item.draft_state == "approved_to_post"
    assert review_item.draft_reply == "Ready to send."
    assert review_item.resolution_recommendation == "resolve_after_change"
  end

  test "presenter tracked fallback without state and integer reprioritization succeed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        identifier: "MT-TRACKED",
        title: "Tracked only"
      }
    ])

    orchestrator_name = Module.concat(__MODULE__, :PresenterTrackedFallbackOrchestrator)

    start_supervised!(
      {BackfillOrchestrator,
       name: orchestrator_name,
       test_pid: self(),
       snapshot: empty_snapshot(),
       responses: %{
         {:resume_issue, "MT-CONTROL"} => %{ok: true, action: "resume", issue_identifier: "MT-CONTROL"},
         {:reprioritize_issue, "MT-CONTROL", 5} => %{
           ok: true,
           action: "reprioritize",
           issue_identifier: "MT-CONTROL",
           override_rank: 5
         }
       }}
    )

    assert {:ok, tracked_payload} = Presenter.issue_payload("MT-TRACKED", orchestrator_name, 50)
    assert tracked_payload.status == "tracked"
    assert tracked_payload.issue_id == nil
    assert tracked_payload.tracked.identifier == "MT-TRACKED"
    assert tracked_payload.last_decision == nil

    assert :ok = BackfillOrchestrator.put_snapshot(orchestrator_name, :unavailable)
    assert {:error, :issue_not_found} = Presenter.issue_payload("MT-TRACKED", orchestrator_name, 50)

    assert {:ok, %{action: "resume"}} =
             Presenter.control_payload("resume", "MT-CONTROL", %{}, orchestrator_name)

    assert {:ok, %{override_rank: 5}} =
             Presenter.control_payload(
               "reprioritize",
               "MT-CONTROL",
               %{"override_rank" => "5"},
               orchestrator_name
             )

    assert_receive {:orchestrator_call, {:resume_issue, "MT-CONTROL"}}
    assert_receive {:orchestrator_call, {:reprioritize_issue, "MT-CONTROL", 5}}
  end

  test "issue payload keeps harness and publish detail for waiting deploy-approval issues" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-deploy-waiting-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    issue_identifier = "MT-DEPLOY-WAIT"
    workspace = Path.join(workspace_root, issue_identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Path.join(workspace, ".symphony/harness.yml"),
      """
      version: 1
      base_branch: main
      preflight:
        command: ./scripts/preflight.sh
      validation:
        command: ./scripts/validate.sh
      smoke:
        command: ./scripts/smoke.sh
      post_merge:
        command: ./scripts/post-merge.sh
      artifacts:
        command: ./scripts/artifacts.sh
      deploy:
        preview:
          command: ./scripts/deploy-preview.sh
        production:
          command: ./scripts/deploy-production.sh
        post_deploy_verify:
          command: ./scripts/post-deploy-verify.sh
        rollback:
          command: ./scripts/deploy-rollback.sh
      pull_request:
        required_checks:
          - validate
      """
    )

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "Deploy Approval", %{
               issue_id: "issue-deploy-wait",
               issue_identifier: issue_identifier,
               issue_source: "manual",
               policy_class: "fully_autonomous",
               last_deploy_preview: %{status: "passed", output: "preview ok"},
               last_post_deploy_verify: %{status: "passed", output: "post deploy ok"},
               deploy_approved: false,
               merge_sha: "abc123",
               stop_reason: "deploy approval required"
             })

    orchestrator_name = Module.concat(__MODULE__, :DeployWaitingIssueOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: base_snapshot()})

    assert {:ok, payload} = Presenter.issue_payload(issue_identifier, orchestrator_name, 50)
    assert payload.status == "Deploy Approval"
    assert payload.harness.deploy_production_command == "./scripts/deploy-production.sh"
    assert payload.harness.post_deploy_verify_command == "./scripts/post-deploy-verify.sh"
    assert payload.publish.last_deploy_preview.output == "preview ok"
    assert payload.publish.last_post_deploy_verify.output == "post deploy ok"
    assert payload.publish.deploy_approved == false
  end

  test "presenter state payload tolerates queue error entries" do
    orchestrator_name = Module.concat(__MODULE__, :PresenterQueueErrorOrchestrator)

    start_supervised!(
      {BackfillOrchestrator,
       name: orchestrator_name,
       test_pid: self(),
       snapshot:
         empty_snapshot()
         |> Map.put(:queue, [
           %{
             error: "{:linear_api_status, 400, %{body: %{errors: [%{message: \"rate limited\"}]}}}"
           }
         ])}
    )

    state_payload = Presenter.state_payload(orchestrator_name, 50)

    assert state_payload.counts == %{running: 0, retrying: 0, paused: 0, queue: 1, skipped: 0}
    assert [%{error: error, issue_id: nil, issue_identifier: nil}] = state_payload.queue
    assert error =~ "linear_api_status"

    assert {:error, :issue_not_found} = Presenter.issue_payload("MT-NONE", orchestrator_name, 50)
  end

  test "presenter state payload covers review gate matrix and ledger derived activity messages" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    RunLedger.append("operator.resume", %{
      issue_identifier: "MT-REVIEW-PR",
      resume_state: "validate"
    })

    RunLedger.record("policy.decided", %{
      issue_identifier: "MT-ATTACHED",
      rule_id: "policy.pr_gate"
    })

    RunLedger.record("dispatch.prepared", %{
      issue_identifier: "MT-AWAIT-CHECKS",
      target_state: "review"
    })

    orchestrator_name = Module.concat(__MODULE__, :PresenterPolicyMatrixOrchestrator)

    start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: policy_matrix_snapshot()})

    state_payload = Presenter.state_payload(orchestrator_name, 50)
    entries = Map.new(state_payload.running, &{&1.issue_identifier, &1})

    review_pr = Map.fetch!(entries, "MT-REVIEW-PR")
    assert review_pr.policy.checkout.label == "No checkout"
    assert review_pr.policy.validation.label == "Validation command missing"
    assert review_pr.policy.pr_gate.label == "Review state has PR"
    assert review_pr.policy.merge_gate.label == "Awaiting approval"
    assert review_pr.review.required_checks == []
    assert review_pr.review.required_checks_passed == true
    assert review_pr.review.missing_required_checks == []
    assert Enum.any?(review_pr.recent_activity, &(&1.message == "resume to validate"))

    attached = Map.fetch!(entries, "MT-ATTACHED")
    assert attached.policy.pr_gate.label == "PR attached"
    assert attached.policy.merge_gate.label == "Awaiting review and checks"
    assert Enum.any?(attached.recent_activity, &(&1.message == "policy.pr_gate"))

    merge_readiness = Map.fetch!(entries, "MT-MERGE-READINESS")
    assert merge_readiness.runtime_mode.label == "Passive runtime"
    assert merge_readiness.merge_readiness.active == true
    assert merge_readiness.merge_readiness.pr_body_validation_status == "passed"
    assert merge_readiness.runtime_health.passive_stage.merge_readiness == true
    assert merge_readiness.status_summary.tone == "info"

    assert merge_readiness.status_summary.automatic_next ==
             "Refresh PR hygiene and posted review thread state before passive check polling continues."

    assert merge_readiness.status_summary.summary ==
             "Refreshing 1 posted review reply and 2 resolved threads before check polling resumes."

    assert merge_readiness.policy.next_human_action ==
             "No human action is required unless the passive runtime reports a failure."

    await_checks = Map.fetch!(entries, "MT-AWAIT-CHECKS")
    assert await_checks.policy.pr_gate.label == "PR attached"
    assert await_checks.policy.merge_gate.label == "Awaiting required checks"
    assert await_checks.review.missing_required_checks == ["test"]
    assert await_checks.runtime_mode.label == "Passive runtime"
    assert await_checks.review_approved == true
    assert await_checks.token_pressure == "high"
    assert await_checks.status_summary.tone == "warn"
    assert await_checks.status_summary.automatic_next == "Merge the PR without starting another agent turn."
    assert await_checks.policy.next_human_action == "No human action is required unless the passive runtime reports a failure."
    assert await_checks.last_decision.verdict == "needs_review"
    assert await_checks.last_decision.rule_id == "policy.await_checks"
    assert await_checks.last_decision.failure_class == "checks"
    assert await_checks.last_decision.human_action == "Wait for CI"
    assert await_checks.last_decision.ledger_event_id == "evt-await"
    assert Enum.any?(await_checks.recent_activity, &(&1.message == "target state review"))

    merge_window =
      await_checks
      |> Map.put(:stage, "await_checks")
      |> Map.put(:merge_window_wait, %{
        next_allowed_at: "2026-03-16T09:00:00Z",
        timezone: "Etc/UTC"
      })
      |> Map.put(:review_approved, false)
      |> Map.put(:token_pressure, nil)
      |> Map.put(:ready_for_merge, true)

    merge_window_summary =
      Presenter.helper_for_test(:status_summary_payload, [merge_window, merge_window.review])

    assert merge_window_summary.automatic_next ==
             "Wait for the next allowed merge window before automerge continues."

    assert merge_window_summary.summary =~
             "Automerge is deferred until 2026-03-16T09:00:00Z"

    merge_window_health =
      Presenter.helper_for_test(
        :runtime_health_summary,
        [
          merge_window,
          %{checkout?: true, git?: true},
          %{error: nil},
          merge_window.review
        ]
      )

    assert merge_window_health =~
             "Automerge is deferred until 2026-03-16T09:00:00Z"

    assert {:ok, review_payload} = Presenter.issue_payload("MT-REVIEW-PR", orchestrator_name, 50)
    assert review_payload.status == "running"
    assert review_payload.running.review.pr_url == "https://example.com/pr/review"
    assert review_payload.recent_events == review_pr.recent_activity
  end

  test "decision history and ledger helpers expose repair and finalization messages clearly" do
    repair_entry = %{
      "event_type" => "runtime.repaired",
      "summary" => "Recovered from a workspace without a valid Git checkout.",
      "metadata" => %{"repair_stage" => "checkout"}
    }

    post_merge_entry = %{
      "event_type" => "post_merge.completed",
      "summary" => "Post-merge verification passed."
    }

    merge_entry = %{
      "event_type" => "merge.completed",
      "summary" => "Merged pull request #9."
    }

    assert Presenter.helper_for_test(:ledger_message, [repair_entry]) ==
             "auto-healed to checkout: Recovered from a workspace without a valid Git checkout."

    assert Presenter.helper_for_test(:ledger_message, [post_merge_entry]) ==
             "Post-merge verification passed."

    assert Presenter.helper_for_test(:ledger_message, [merge_entry]) ==
             "Merged pull request #9."

    assert Presenter.helper_for_test(:ledger_activity_tone, ["runtime.repaired"]) == "good"
    assert Presenter.helper_for_test(:ledger_activity_tone, ["post_merge.completed"]) == "good"
  end

  test "done issue payload explains autonomous finalization from run state" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-web-done-summary-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      issue_identifier = "MT-DONE-SUMMARY"
      workspace = Path.join(workspace_root, issue_identifier)
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      :ok =
        RunStateStore.save(workspace, %{
          issue_id: "manual:mt-done-summary",
          issue_identifier: issue_identifier,
          issue_source: :manual,
          stage: "done",
          last_merge: %{
            status: :merged,
            url: "https://example.com/pr/42"
          },
          last_post_merge: %{
            status: :passed
          }
        })

      orchestrator_name = Module.concat(__MODULE__, :DoneSummaryOrchestrator)

      start_supervised!({BackfillOrchestrator, name: orchestrator_name, test_pid: self(), snapshot: base_snapshot()})

      assert {:ok, payload} = Presenter.issue_payload(issue_identifier, orchestrator_name, 50)
      assert payload.status == "done"
      assert payload.operator_summary.current_stage == "done"

      assert payload.operator_summary.why_here ==
               "Autonomously finalized after merge and post-merge verification passed (https://example.com/pr/42)."

      assert payload.operator_summary.automatic_next == "No further runtime action is required."
      assert payload.runtime_health.summary == payload.operator_summary.why_here
    after
      File.rm_rf(workspace_root)
    end
  end

  test "status dashboard helper formatters cover unavailable rendering, dedupe, urls, and codex messages" do
    dashboard_name = Module.concat(__MODULE__, :EnabledDashboard)
    parent = self()

    start_supervised!({StatusDashboard, name: dashboard_name, enabled: true, refresh_ms: 10_000, render_interval_ms: 50, render_fun: fn content -> send(parent, {:render, content}) end})

    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:render, content}, 1_000
    assert content =~ "No active agents"

    StatusDashboard.notify_update(dashboard_name)

    assert StatusDashboard.dashboard_url_for_test("0.0.0.0", 4000, nil) ==
             "http://127.0.0.1:4000/"

    assert StatusDashboard.dashboard_url_for_test("2001:db8::1", 4000, nil) ==
             "http://[2001:db8::1]:4000/"

    assert StatusDashboard.dashboard_url_for_test("127.0.0.1", nil, nil) == nil

    assert StatusDashboard.format_snapshot_content_for_test(:error, 1200.7, 96) =~
             "Orchestrator snapshot unavailable"

    assert StatusDashboard.format_snapshot_content_for_test(:error, 1200.7, 96) =~ "1,200 tps"

    assert StatusDashboard.format_running_summary_for_test(
             %{
               identifier: "MT-SUMMARY",
               state: "Human Review",
               session_id: "thread-abcdef1234567890",
               codex_app_server_pid: nil,
               codex_total_tokens: 12_345,
               runtime_seconds: 65,
               turn_count: 2,
               last_codex_event: "turn_completed",
               last_codex_message: %{event: :session_started, message: %{"session_id" => "sess-1"}}
             },
             100
           ) =~ "thre...567890"

    assert StatusDashboard.format_running_summary_for_test(
             %{
               identifier: "MT-SUMMARY",
               state: "Human Review",
               session_id: "thread-abcdef1234567890",
               codex_app_server_pid: nil,
               codex_total_tokens: 12_345,
               runtime_seconds: 65,
               turn_count: 2,
               last_codex_event: "turn_completed",
               last_codex_message: %{event: :session_started, message: %{"session_id" => "sess-1"}}
             },
             100
           ) =~ "12,345"

    assert StatusDashboard.format_running_summary_for_test(
             %{
               identifier: "MT-SUMMARY",
               state: "Human Review",
               session_id: "thread-abcdef1234567890",
               codex_app_server_pid: nil,
               codex_total_tokens: 12_345,
               runtime_seconds: 65,
               turn_count: 2,
               last_codex_event: "turn_completed",
               last_codex_message: %{event: :session_started, message: %{"session_id" => "sess-1"}}
             },
             100
           ) =~ "1m 5s / 2"

    assert StatusDashboard.rolling_tps([{1_000, 10}], 2_000, 25) == 15.0
    assert StatusDashboard.throttled_tps(2, 9.0, 2_500, [{1_000, 10}], 25) == {2, 9.0}
    assert StatusDashboard.throttled_tps(nil, nil, 2_500, [{1_000, 10}], 25) == {2, 10.0}
    assert StatusDashboard.format_tps_for_test(1200.7) == "1,200"
    assert String.length(StatusDashboard.tps_graph_for_test([{580_000, 90}, {560_000, 30}], 600_000, 120)) == 24
    assert StatusDashboard.format_timestamp_for_test(~U[2026-03-07 17:00:00.999Z]) == "2026-03-07 17:00:00Z"

    assert StatusDashboard.humanize_codex_message(%{
             event: :turn_input_required,
             message: %{}
           }) == "turn blocked: waiting for user input"

    assert StatusDashboard.humanize_codex_message(%{
             event: :session_started,
             message: %{"session_id" => "sess-1"}
           }) == "session started (sess-1)"

    assert StatusDashboard.humanize_codex_message(%{
             message: %{"error" => %{"message" => "boom"}}
           }) == "error: boom"

    offline_io =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = StatusDashboard.render_offline_status()
      end)

    assert offline_io =~ "app_status=offline"
  end

  test "dashboard live and presenter helper seams cover low-coverage fallback branches" do
    now = ~U[2026-03-07 20:00:00Z]

    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:runtime_seconds_from_started_at, ["not-iso", now]) == 0
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:runtime_seconds_from_started_at, [123, now]) == 0
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:format_int, ["oops"]) == "n/a"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:format_signed_int, [nil]) == "n/a"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:format_signed_int, ["oops"]) == "n/a"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:format_millis, ["oops"]) == "n/a"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:short_sha, [nil]) == "n/a"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:truncate_middle, [nil, 12]) == "n/a"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:truncate_middle, [123, 4]) == "123"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:join_labels, ["oops"]) == "n/a"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:format_budget, [12, nil]) == "12"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:format_budget, ["oops", 10]) == "n/a"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:budget_width, ["oops", 10]) == 0
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:check_tone, ["action_required"]) == "warn"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:check_tone, [nil]) == "muted"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:stage_tone, ["blocked"]) == "danger"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:stage_tone, ["mystery"]) == "muted"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:command_tone, ["unavailable"]) == "warn"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:command_label, [%{status: ""}, "fallback"]) == "fallback"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:command_label, ["oops", "fallback"]) == "fallback"
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:missing_required_checks, [%{required_checks: ["lint"], check_statuses: [%{name: "test"}]}]) == ["lint"]
    refute SymphonyElixirWeb.DashboardLive.helper_for_test(:present, ["   "])
    refute SymphonyElixirWeb.DashboardLive.helper_for_test(:present, [nil])
    assert SymphonyElixirWeb.DashboardLive.helper_for_test(:pretty_value, [nil]) == "n/a"

    assert Presenter.helper_for_test(:issue_status, [%{}, %{}, nil, nil, nil, nil]) == "running"
    assert Presenter.helper_for_test(:codex_activity_payload, [:oops]) == []
    assert Presenter.helper_for_test(:ledger_activity_payload, [:oops]) == []
    assert Presenter.helper_for_test(:runner_activity_payload, [:oops]) == []
    assert Presenter.helper_for_test(:ledger_message, [%{"event_type" => "dispatch.started"}]) == "dispatch.started"
    assert Presenter.helper_for_test(:runner_history_message, [%{"summary" => "runner.promoted", "metadata" => %{}}]) == "runner.promoted"
    assert Presenter.helper_for_test(:required_checks_passed, [[], [%{name: "build", conclusion: "success"}]])
    assert Presenter.helper_for_test(:normalize_command_result, [123]) == %{status: nil, command: nil, output: "123"}
    assert Presenter.helper_for_test(:codex_activity_tone, [%{event: "agent_message"}]) == "muted"
    assert Presenter.helper_for_test(:ledger_activity_tone, ["dispatch.started"]) == "info"
    assert Presenter.helper_for_test(:entry_value, [:oops, "event"]) == nil
    assert Presenter.helper_for_test(:truncate_text, [123, 5]) == "123"
    assert Presenter.helper_for_test(:due_at_iso8601, ["oops"]) == nil
    assert Presenter.helper_for_test(:normalize_state, [nil]) == ""
    assert Presenter.helper_for_test(:parse_override_rank, ["oops"]) == nil
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp base_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-web",
          identifier: "MT-WEB",
          state: "In Progress",
          session_id: "thread-web",
          turn_count: 3,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 2,
          codex_output_tokens: 3,
          codex_total_tokens: 5,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [],
      codex_totals: %{input_tokens: 2, output_tokens: 3, total_tokens: 5, seconds_running: 12.5},
      rate_limits: nil,
      polling: %{poll_interval_ms: 1_000, next_poll_in_ms: 500, checking?: false},
      runner: %{instance_name: "test-runner", runner_mode: "stable"}
    }
  end

  defp empty_snapshot do
    %{
      running: [],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      polling: %{},
      runner: %{}
    }
  end

  defp rich_snapshot do
    %{
      running: [rich_running_entry()],
      retrying: [rich_retry_entry()],
      paused: [rich_paused_entry()],
      skipped: [rich_skipped_entry()],
      queue: [rich_queue_entry()],
      codex_totals: %{input_tokens: 44, output_tokens: 13, total_tokens: 57, seconds_running: 65},
      rate_limits: %{
        limit_id: "gpt-5",
        primary: %{remaining: 10, limit: 20},
        secondary: %{remaining: 3, limit: 5},
        credits: %{has_credits: true, balance: 12.5}
      },
      polling: %{
        poll_interval_ms: 1_000,
        next_poll_in_ms: 0,
        checking?: true,
        dispatch_mode: "manual_only_degraded",
        dispatch_summary: "Tracker reads are paused due to rate limiting; manual issues continue to dispatch.",
        tracker_reads_paused: true,
        manual_dispatch_enabled: true
      },
      github_webhooks: %{health: "healthy"},
      github_inbox: %{
        depth: 1,
        oldest_pending_event_at: "2026-03-07T15:14:00Z",
        last_drained_at: "2026-03-07T15:14:30Z",
        last_assignment: %{
          event_id: "delivery-rich",
          assignment_state: "processed",
          assignment_reason: "review_feedback_persisted",
          assigned_runner_channel: "stable"
        }
      },
      runner: %{
        instance_name: "test-runner",
        runner_mode: "stable",
        history: [
          %{
            event_type: "runner.rollback.completed",
            at: "2026-03-07T15:12:00Z",
            summary: "Rollback prepared",
            metadata: %{"canary_note" => "rollback suggested"}
          }
        ]
      },
      priority_overrides: %{"MT-QUEUE" => 7},
      policy_overrides: %{"MT-QUEUE" => "review_required"}
    }
  end

  defp refreshed_snapshot do
    %{
      rich_snapshot()
      | running: [
          %{
            rich_running_entry()
            | issue_id: "issue-refreshed",
              identifier: "MT-REFRESHED",
              state: "In Progress",
              checkout?: true,
              git?: true,
              harness_error: nil,
              validation_command: "./scripts/validate.sh",
              required_checks: ["build"],
              check_statuses: [%{name: "build", conclusion: "success"}],
              labels: ["dogfood"],
              label_gate_eligible: true
          }
        ],
        polling: %{poll_interval_ms: 2_000, next_poll_in_ms: 250, checking?: false}
    }
  end

  defp boosted_snapshot do
    %{
      refreshed_snapshot()
      | queue: [
          %{
            rich_queue_entry()
            | rank: 1,
              operator_override: 0
          }
        ]
    }
  end

  defp green_snapshot do
    %{
      running: [green_running_entry()],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [],
      codex_totals: %{input_tokens: 3, output_tokens: 2, total_tokens: 5, seconds_running: 5},
      rate_limits: nil,
      polling: %{poll_interval_ms: nil, next_poll_in_ms: nil, checking?: false},
      runner: %{},
      priority_overrides: %{},
      policy_overrides: %{}
    }
  end

  defp runner_canary_snapshot do
    %{
      running: [],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [],
      codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 4},
      rate_limits: %{
        limit_id: "gpt-5",
        primary: %{remaining: 10, limit: 20},
        secondary: %{remaining: 3, limit: 5}
      },
      polling: %{poll_interval_ms: 2_000, next_poll_in_ms: 1_000, checking?: false},
      runner: %{
        instance_name: "runner-canary",
        runner_mode: "canary_failed",
        runner_health: "invalid",
        runner_health_rule_id: "runner.current_mismatch",
        runner_health_summary: "Runner metadata does not match the current symlink target.",
        runner_health_human_action: "Repair metadata.json or repoint current to the promoted release.",
        dispatch_enabled: false,
        install_root: "/tmp/symphony/runner-canary",
        current_link_target: "/tmp/symphony/runner-canary/releases/abcdef1234567890",
        current_version_sha: "abcdef1234567890",
        promoted_release_sha: "12345678deadbeef",
        previous_release_sha: "deadbeef12345678",
        previous_release_path: "/tmp/symphony/runner-canary/releases/deadbeef12345678",
        effective_required_labels: ["dogfood", "canary"],
        canary_required_labels: ["release-candidate"],
        canary_started_at: "2026-03-07T17:00:00Z",
        canary_result: "failed",
        canary_note: "Rollback suggested after smoke test",
        canary_evidence: %{
          issues: ["CLZ-11"],
          prs: ["https://github.com/gaspardip/symphony/pull/11"]
        },
        rollback_recommended: true,
        rollback_rule_id: "runner.rollback",
        rollback_target_exists: true,
        promoted_at: "2026-03-07T16:55:00Z",
        canary_recorded_at: "2026-03-07T17:01:00Z",
        repo_url: "git@github.com:gaspardip/symphony.git",
        release_manifest_path: "/tmp/symphony/runner-canary/releases/12345678deadbeef/manifest.json",
        promotion_host: "dogfood-host",
        promotion_user: "gaspar",
        preflight_completed_at: "2026-03-07T16:50:00Z",
        smoke_completed_at: "2026-03-07T16:54:00Z",
        release_manifest: %{
          "commit_sha" => "12345678deadbeef",
          "promoted_ref" => "gaspar/autonomous-pipeline"
        }
      }
    }
  end

  defp policy_matrix_snapshot do
    %{
      running: [
        review_pr_entry(),
        attached_pr_entry(),
        merge_readiness_entry(),
        await_checks_entry()
      ],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [queue_policy_entry()],
      codex_totals: %{input_tokens: 12, output_tokens: 8, total_tokens: 20, seconds_running: 15},
      rate_limits: nil,
      polling: %{poll_interval_ms: 1_000, next_poll_in_ms: 250, checking?: false},
      runner: %{instance_name: "runner-matrix", runner_mode: "stable"},
      priority_overrides: %{"MT-QUEUE-POLICY" => 0},
      policy_overrides: %{"MT-QUEUE-POLICY" => "review_required"}
    }
  end

  defp rich_running_entry do
    %{
      issue_id: "issue-running",
      identifier: "MT-RUN",
      state: "Human Review",
      stage: "validate",
      session_id: "thread-abcdef1234567890",
      turn_count: 2,
      codex_app_server_pid: nil,
      last_codex_message: turn_completed_message("completed", 11, 4, 15),
      last_codex_timestamp: ~U[2026-03-07 15:10:00Z],
      last_codex_event: "turn_completed",
      recent_codex_updates: [
        %{
          timestamp: ~U[2026-03-07 15:09:30Z],
          event: :turn_failed,
          message: %{"params" => %{"error" => %{"message" => "compiler boom"}}}
        }
      ],
      codex_input_tokens: 16,
      codex_output_tokens: 8,
      codex_total_tokens: 24,
      current_turn_input_tokens: 9,
      runtime_seconds: 65,
      started_at: ~U[2026-03-07 15:00:00Z],
      workspace: "/tmp/MT-RUN",
      checkout?: true,
      git?: false,
      origin_url: "git@example.com/org/repo.git",
      branch: "mt-run",
      head_sha: "abcdef1234567890",
      dirty?: true,
      changed_files: 3,
      status_text: " M lib/example.ex",
      base_branch: "main",
      harness_path: ".symphony/harness.yml",
      harness_version: "1",
      harness_error: "invalid yaml",
      preflight_command: "./scripts/preflight.sh",
      validation_command: nil,
      smoke_command: "./scripts/smoke.sh",
      post_merge_command: "./scripts/post-merge.sh",
      deploy_preview_command: "./scripts/deploy-preview.sh",
      deploy_production_command: "./scripts/deploy-production.sh",
      deploy_rollback_command: "./scripts/deploy-rollback.sh",
      post_deploy_verify_command: "./scripts/post-deploy-verify.sh",
      required_checks: ["build", "lint"],
      publish_required_checks: [],
      ci_required_checks: [],
      pr_url: nil,
      pr_state: "OPEN",
      review_decision: "APPROVED",
      check_statuses: [%{name: "build", conclusion: "success"}],
      ready_for_merge: false,
      policy_class: "review_required",
      policy_source: "rule",
      policy_override: nil,
      labels: ["bug"],
      required_labels: ["dogfood"],
      label_gate_eligible: false,
      deploy_approved: true,
      last_rule_id: "policy.review_required",
      last_failure_class: "policy",
      last_decision_summary: "Need review",
      next_human_action: "Attach a PR.",
      last_ledger_event_id: "evt-run",
      lease: %{
        lease_owner: "orchestrator-rich",
        lease_owner_instance_id: "stable:test-runner",
        lease_owner_channel: "stable",
        lease_acquired_at: "2026-03-07T15:00:00Z",
        lease_updated_at: "2026-03-07T15:12:30Z",
        lease_status: "reclaimable",
        lease_epoch: 4,
        lease_age_ms: 150_000,
        lease_ttl_ms: 60_000,
        lease_reclaimable: true,
        lease_source: "live"
      },
      last_decision: %{status: "failed", command: "mix test", output: String.duplicate("x", 260)},
      last_deploy_preview: %{status: "passed", command: "./scripts/deploy-preview.sh", output: "preview ok"},
      last_deploy_production: %{status: "passed", command: "./scripts/deploy-production.sh", output: "production ok"},
      last_post_deploy_verify: %{status: "passed", command: "./scripts/post-deploy-verify.sh", output: "post deploy ok"}
    }
  end

  defp rich_retry_entry do
    %{
      issue_id: "issue-retry",
      identifier: "MT-RETRY",
      attempt: 2,
      due_in_ms: 1_500,
      error: "API timeout",
      priority_override: 4,
      policy_class: "review_required",
      policy_source: "rule",
      policy_override: nil,
      next_human_action: "Retry after cooldown.",
      last_rule_id: "policy.retry",
      last_failure_class: "transient",
      last_decision_summary: "Retry scheduled",
      last_ledger_event_id: "evt-retry"
    }
  end

  defp rich_paused_entry do
    %{
      issue_id: "issue-paused",
      identifier: "MT-PAUSED",
      resume_state: "in_progress",
      policy_class: "review_required",
      policy_source: "operator",
      policy_override: "review_required",
      next_human_action: "Resume when ready.",
      last_rule_id: "policy.pause",
      last_failure_class: "operator",
      last_decision_summary: "Paused",
      last_ledger_event_id: "evt-paused"
    }
  end

  defp rich_skipped_entry do
    %{
      issue_id: "issue-skipped",
      issue_identifier: "MT-SKIP",
      state: "Todo",
      labels: ["bug"],
      required_labels: ["dogfood"],
      reason: "missing labels",
      policy_class: "fully_autonomous",
      policy_source: "rule",
      policy_override: nil,
      next_human_action: "Add dogfood label.",
      last_rule_id: "routing.labels",
      last_failure_class: "routing",
      last_decision_summary: "Skipped",
      last_ledger_event_id: "evt-skip",
      lease: %{
        lease_owner: "skip-owner",
        lease_owner_instance_id: "canary:dogfood-runner",
        lease_owner_channel: "canary",
        lease_status: "held",
        lease_epoch: 2,
        lease_reclaimable: false
      }
    }
  end

  defp rich_queue_entry do
    %{
      issue_id: "issue-queue",
      issue_identifier: "MT-QUEUE",
      state: "Todo",
      rank: 7,
      linear_priority: 2,
      operator_override: nil,
      retry_penalty: 1,
      labels: ["triage"],
      required_labels: ["dogfood"],
      label_gate_eligible: false,
      policy_class: "never_automerge",
      policy_source: "rule",
      policy_override: nil,
      next_human_action: "Boost when ready.",
      last_rule_id: "priority.rank",
      last_failure_class: "priority",
      last_decision_summary: "Queued",
      last_ledger_event_id: "evt-queue",
      lease: %{
        lease_owner: "queue-owner",
        lease_owner_instance_id: "stable:test-runner",
        lease_owner_channel: "stable",
        lease_status: "held",
        lease_epoch: 1,
        lease_reclaimable: false
      }
    }
  end

  defp green_running_entry do
    %{
      issue_id: "issue-green",
      identifier: "MT-GREEN",
      state: "In Progress",
      stage: "publish",
      session_id: "thread-green",
      turn_count: 1,
      codex_app_server_pid: "4242",
      last_codex_message: thread_started_message("thread-green"),
      last_codex_timestamp: ~U[2026-03-07 16:01:00Z],
      last_codex_event: "session_started",
      recent_codex_updates: [],
      codex_input_tokens: 3,
      codex_output_tokens: 2,
      codex_total_tokens: 5,
      current_turn_input_tokens: 1,
      runtime_seconds: 5,
      started_at: ~U[2026-03-07 16:00:00Z],
      workspace: "/tmp/MT-GREEN",
      checkout?: false,
      git?: true,
      origin_url: "git@example.com/org/repo.git",
      branch: "mt-green",
      head_sha: "1234567890abcdef",
      dirty?: false,
      changed_files: 0,
      status_text: "",
      base_branch: "main",
      harness_path: ".symphony/harness.yml",
      harness_version: "1",
      harness_error: nil,
      preflight_command: "./scripts/preflight.sh",
      validation_command: "./scripts/validate.sh",
      smoke_command: "./scripts/smoke.sh",
      post_merge_command: "./scripts/post-merge.sh",
      deploy_preview_command: "./scripts/deploy-preview.sh",
      deploy_production_command: "./scripts/deploy-production.sh",
      deploy_rollback_command: "./scripts/deploy-rollback.sh",
      post_deploy_verify_command: "./scripts/post-deploy-verify.sh",
      required_checks: ["build"],
      publish_required_checks: ["ci"],
      ci_required_checks: ["ci"],
      pr_url: "https://example.com/pr/1",
      pr_state: "OPEN",
      review_decision: "APPROVED",
      check_statuses: [%{name: "ci", conclusion: "success"}],
      ready_for_merge: true,
      policy_class: "fully_autonomous",
      policy_source: "rule",
      policy_override: nil,
      labels: ["dogfood"],
      required_labels: ["dogfood"],
      label_gate_eligible: true,
      last_rule_id: "publish.ready",
      last_failure_class: nil,
      last_decision_summary: "Ready to merge",
      next_human_action: nil,
      last_ledger_event_id: "evt-green",
      last_pr_body_validation: %{status: "ok", output: 123},
      last_validation: "validation ok",
      last_verifier: %{status: "passed", output: 456},
      last_verifier_verdict: "safe",
      acceptance_summary: "all green",
      last_post_merge: %{status: "done", output: 789},
      last_deploy_preview: %{status: "passed", output: "preview ok"},
      last_deploy_production: %{status: "passed", output: "production ok"},
      last_post_deploy_verify: %{status: "passed", output: "post deploy ok"},
      deploy_approved: true,
      merge_sha: "abc123",
      stop_reason: "merged",
      last_decision: nil
    }
  end

  defp review_pr_entry do
    %{
      issue_id: "issue-review-pr",
      identifier: "MT-REVIEW-PR",
      state: "Human Review",
      stage: "await_checks",
      session_id: nil,
      turn_count: 0,
      codex_app_server_pid: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: :notification,
      recent_codex_updates: [],
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      current_turn_input_tokens: 0,
      runtime_seconds: 0,
      started_at: ~U[2026-03-07 17:10:00Z],
      workspace: "/tmp/MT-REVIEW-PR",
      checkout?: false,
      git?: false,
      origin_url: nil,
      branch: "mt-review-pr",
      head_sha: "aaaabbbbccccdddd",
      dirty?: false,
      changed_files: 0,
      status_text: nil,
      base_branch: "main",
      harness_path: ".symphony/harness.yml",
      harness_version: "1",
      harness_error: nil,
      preflight_command: "./scripts/preflight.sh",
      validation_command: nil,
      smoke_command: "./scripts/smoke.sh",
      post_merge_command: nil,
      required_checks: [],
      publish_required_checks: [],
      ci_required_checks: [],
      pr_url: "https://example.com/pr/review",
      pr_state: "OPEN",
      review_decision: nil,
      check_statuses: [],
      ready_for_merge: false,
      policy_class: "review_required",
      policy_source: "rule",
      policy_override: nil,
      labels: ["dogfood"],
      required_labels: ["dogfood"],
      label_gate_eligible: true,
      last_rule_id: "policy.review",
      last_failure_class: nil,
      last_decision_summary: nil,
      next_human_action: nil,
      last_ledger_event_id: nil,
      last_decision: nil
    }
  end

  defp attached_pr_entry do
    %{
      issue_id: "issue-attached",
      identifier: "MT-ATTACHED",
      state: "In Progress",
      stage: "publish",
      session_id: "thread-attached",
      turn_count: 1,
      codex_app_server_pid: "4242",
      last_codex_message: thread_started_message("thread-attached"),
      last_codex_timestamp: ~U[2026-03-07 17:11:00Z],
      last_codex_event: "thread_started",
      recent_codex_updates: [],
      codex_input_tokens: 2,
      codex_output_tokens: 1,
      codex_total_tokens: 3,
      current_turn_input_tokens: 2,
      runtime_seconds: 8,
      started_at: ~U[2026-03-07 17:10:30Z],
      workspace: "/tmp/MT-ATTACHED",
      checkout?: true,
      git?: true,
      origin_url: "git@example.com/org/repo.git",
      branch: "mt-attached",
      head_sha: "bbbbccccddddeeee",
      dirty?: false,
      changed_files: 0,
      status_text: "clean",
      base_branch: "main",
      harness_path: ".symphony/harness.yml",
      harness_version: "1",
      harness_error: nil,
      preflight_command: "./scripts/preflight.sh",
      validation_command: "./scripts/validate.sh",
      smoke_command: "./scripts/smoke.sh",
      post_merge_command: nil,
      required_checks: ["build"],
      publish_required_checks: [],
      ci_required_checks: [],
      pr_url: "https://example.com/pr/attached",
      pr_state: "OPEN",
      review_decision: nil,
      check_statuses: [],
      ready_for_merge: false,
      policy_class: "fully_autonomous",
      policy_source: "rule",
      policy_override: nil,
      labels: ["dogfood"],
      required_labels: ["dogfood"],
      label_gate_eligible: true,
      last_rule_id: "policy.pr_gate",
      last_failure_class: nil,
      last_decision_summary: nil,
      next_human_action: nil,
      last_ledger_event_id: nil,
      last_decision: nil
    }
  end

  defp await_checks_entry do
    %{
      issue_id: "issue-await-checks",
      identifier: "MT-AWAIT-CHECKS",
      state: "In Progress",
      stage: "merge",
      passive?: true,
      review_approved: true,
      token_pressure: "high",
      session_id: "thread-await-checks",
      turn_count: 2,
      codex_app_server_pid: "4343",
      last_codex_message: turn_completed_message("completed", 5, 2, 7),
      last_codex_timestamp: ~U[2026-03-07 17:12:00Z],
      last_codex_event: "turn_completed",
      recent_codex_updates: [],
      codex_input_tokens: 5,
      codex_output_tokens: 2,
      codex_total_tokens: 7,
      current_turn_input_tokens: 5,
      runtime_seconds: 12,
      started_at: ~U[2026-03-07 17:09:30Z],
      workspace: "/tmp/MT-AWAIT-CHECKS",
      checkout?: true,
      git?: true,
      origin_url: "git@example.com/org/repo.git",
      branch: "mt-await-checks",
      head_sha: "ccccddddeeeeffff",
      dirty?: false,
      changed_files: 0,
      status_text: nil,
      base_branch: "main",
      harness_path: ".symphony/harness.yml",
      harness_version: "1",
      harness_error: nil,
      preflight_command: "./scripts/preflight.sh",
      validation_command: "./scripts/validate.sh",
      smoke_command: "./scripts/smoke.sh",
      post_merge_command: nil,
      required_checks: ["test"],
      publish_required_checks: [],
      ci_required_checks: [],
      pr_url: "https://example.com/pr/await-checks",
      pr_state: "OPEN",
      review_decision: "APPROVED",
      check_statuses: [%{name: "lint", conclusion: nil, status: "queued"}],
      ready_for_merge: false,
      policy_class: "review_required",
      policy_source: "override",
      policy_override: "review_required",
      labels: ["triage"],
      required_labels: ["dogfood"],
      label_gate_eligible: false,
      last_rule_id: "policy.await_checks",
      last_failure_class: "checks",
      last_decision_summary: "Checks pending",
      next_human_action: "Wait for CI",
      last_ledger_event_id: "evt-await",
      last_decision: %{
        status: "failed",
        command: "mix test",
        verdict: "needs_review",
        rule_id: "policy.await_checks",
        failure_class: "checks",
        summary: "Checks pending",
        details: "Required test check is still missing",
        human_action: "Wait for CI",
        acceptance_gaps: ["test"],
        risky_areas: ["merge"],
        evidence: ["lint queued"],
        acceptance: %{"checks" => false},
        ledger_event_id: "evt-await",
        output: "test check missing"
      }
    }
  end

  defp merge_readiness_entry do
    %{
      issue_id: "issue-merge-readiness",
      identifier: "MT-MERGE-READINESS",
      state: "Merging",
      stage: "merge_readiness",
      passive?: true,
      review_approved: false,
      token_pressure: nil,
      session_id: nil,
      turn_count: 0,
      codex_app_server_pid: nil,
      last_codex_message: nil,
      last_codex_timestamp: ~U[2026-03-07 17:11:00Z],
      last_codex_event: "stage_transition",
      recent_codex_updates: [],
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      current_turn_input_tokens: 0,
      runtime_seconds: 6,
      started_at: ~U[2026-03-07 17:10:30Z],
      workspace: "/tmp/MT-MERGE-READINESS",
      checkout?: true,
      git?: true,
      origin_url: "git@example.com/org/repo.git",
      branch: "mt-merge-readiness",
      head_sha: "aaaabbbbccccdddd",
      dirty?: false,
      changed_files: 0,
      status_text: nil,
      base_branch: "main",
      harness_path: ".symphony/harness.yml",
      harness_version: "1",
      harness_error: nil,
      preflight_command: "./scripts/preflight.sh",
      validation_command: "./scripts/validate.sh",
      smoke_command: "./scripts/smoke.sh",
      post_merge_command: nil,
      required_checks: ["test"],
      publish_required_checks: [],
      ci_required_checks: [],
      pr_url: "https://example.com/pr/merge-readiness",
      pr_state: "OPEN",
      review_decision: "COMMENTED",
      check_statuses: [%{name: "test", conclusion: nil, status: "queued"}],
      ready_for_merge: false,
      policy_class: "fully_autonomous",
      policy_source: "workflow",
      policy_override: nil,
      labels: ["dogfood"],
      required_labels: ["dogfood"],
      label_gate_eligible: true,
      last_rule_id: "policy.merge_readiness",
      last_failure_class: "pr_hygiene",
      last_decision_summary: "Refreshing PR hygiene",
      next_human_action: nil,
      last_ledger_event_id: "evt-merge-readiness",
      last_decision: %{
        status: "running",
        command: nil,
        verdict: "continue",
        rule_id: "policy.merge_readiness",
        failure_class: "pr_hygiene",
        summary: "Refreshing PR hygiene",
        details: "Posted review replies and PR body are being reconciled before passive check polling.",
        human_action: nil,
        acceptance_gaps: [],
        risky_areas: ["publish"],
        evidence: ["1 posted reply refresh", "2 resolved threads"],
        acceptance: %{"pr_hygiene" => true},
        ledger_event_id: "evt-merge-readiness",
        output: ""
      },
      last_merge_readiness: %{
        checked_at: "2026-03-07T17:10:45Z",
        pr_body_validation_status: "passed",
        posted_review_threads: 3,
        pending_reply_refreshes: 1,
        resolved_review_threads: 2
      }
    }
  end

  defp queue_policy_entry do
    %{
      issue_id: "issue-queue-policy",
      issue_identifier: "MT-QUEUE-POLICY",
      state: "Todo",
      rank: 1,
      linear_priority: 2,
      operator_override: 0,
      retry_penalty: 1,
      labels: ["triage"],
      required_labels: ["dogfood"],
      label_gate_eligible: false,
      policy_class: "review_required",
      policy_source: "override",
      policy_override: "review_required",
      next_human_action: "Review queue priority.",
      last_rule_id: "priority.override",
      last_failure_class: nil,
      last_decision_summary: "Operator override",
      last_ledger_event_id: "evt-queue-policy"
    }
  end

  defp turn_completed_message(status, input_tokens, output_tokens, total_tokens) do
    %{
      event: :notification,
      message: %{
        "method" => "turn/completed",
        "params" => %{
          "turn" => %{"status" => status},
          "usage" => %{
            "input_tokens" => input_tokens,
            "output_tokens" => output_tokens,
            "total_tokens" => total_tokens
          }
        }
      }
    }
  end

  defp thread_started_message(thread_id) do
    %{
      message: %{
        "method" => "thread/started",
        "params" => %{
          "thread" => %{"id" => thread_id}
        }
      }
    }
  end
end
