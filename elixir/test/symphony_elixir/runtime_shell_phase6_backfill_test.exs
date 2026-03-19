defmodule SymphonyElixir.RuntimeShellPhase6BackfillTest do
  use SymphonyElixir.TestSupport

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  test "agent runner returns ok when policy stops and still runs after_run hook" do
    workspace_root = temp_dir("agent-runner-policy-stop")
    issue = sample_issue("MT-AR-STOP")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_run: "echo after_run > after_run.log",
      policy_require_checkout: true,
      policy_require_validation: false,
      policy_stop_on_noop_turn: false
    )

    assert :ok = AgentRunner.run(issue)

    workspace = Path.join(workspace_root, issue.identifier)
    assert File.read!(Path.join(workspace, "after_run.log")) =~ "after_run"
  end

  test "agent runner raises on before_run hook failures and still runs after_run" do
    workspace_root = temp_dir("agent-runner-before-run")
    issue = sample_issue("MT-AR-BEFORE")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_before_run: "echo nope && exit 7",
      hook_after_run: "echo after_run > after_run.log",
      policy_require_checkout: false,
      policy_require_validation: false,
      policy_stop_on_noop_turn: false
    )

    assert_raise RuntimeError, ~r/workspace_hook_failed/, fn ->
      AgentRunner.run(issue)
    end

    workspace = Path.join(workspace_root, issue.identifier)
    assert File.read!(Path.join(workspace, "after_run.log")) =~ "after_run"
  end

  test "agent runner raises when workspace creation fails" do
    workspace_root = temp_dir("agent-runner-create-failure")
    issue = sample_issue("MT-AR-CREATE")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: "echo nope && exit 17"
    )

    assert_raise RuntimeError, ~r/after_create/, fn ->
      AgentRunner.run(issue)
    end
  end

  test "app server surfaces turn start errors and emits startup_failed" do
    test_root = temp_dir("app-server-startup-failed")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-STARTUP")
    codex_binary = write_fake_codex!(test_root, :start_turn_error)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:error, {:response_error, %{"message" => "turn-start-failed"}}} =
             AppServer.run(workspace, "startup failed", sample_issue("MT-AS-STARTUP"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    assert_receive {:app_server_message, %{event: :startup_failed, reason: {:response_error, %{"message" => "turn-start-failed"}}}}
  end

  test "app server returns turn_failed errors and emits error lifecycle messages" do
    test_root = temp_dir("app-server-turn-failed")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-TURN-FAILED")
    codex_binary = write_fake_codex!(test_root, :turn_failed)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:error, {:turn_failed, %{"reason" => "verifier failed"}}} =
             AppServer.run(workspace, "turn failed", sample_issue("MT-AS-TURN-FAILED"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    assert_receive {:app_server_message, %{event: :turn_failed, details: %{"reason" => "verifier failed"}}}

    assert_receive {:app_server_message, %{event: :turn_ended_with_error, reason: {:turn_failed, %{"reason" => "verifier failed"}}}}
  end

  test "app server ignores non-json stream noise and still emits other_message before completing a turn" do
    test_root = temp_dir("app-server-malformed")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-MALFORMED")
    codex_binary = write_fake_codex!(test_root, :malformed_and_other_message)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:ok, %{result: :turn_completed}} =
             AppServer.run(workspace, "malformed stream", sample_issue("MT-AS-MALFORMED"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    assert_receive {:app_server_message, %{event: :other_message, payload: %{"note" => "keep-going"}, usage: %{"input_tokens" => 1}}}

    refute_receive {:app_server_message, %{event: :malformed, payload: "warn: noisy line"}}
  end

  test "app server still emits malformed for json-shaped undecodable payloads" do
    test_root = temp_dir("app-server-malformed-json")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-MALFORMED-JSON")
    codex_binary = write_fake_codex!(test_root, :json_shaped_malformed)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:ok, %{result: :turn_completed}} =
             AppServer.run(workspace, "malformed json stream", sample_issue("MT-AS-MALFORMED-JSON"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    assert_receive {:app_server_message, %{event: :malformed, payload: "{\"note\":\"broken\""}}
  end

  test "app server surfaces invalid thread payloads as startup failures" do
    test_root = temp_dir("app-server-invalid-thread")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-INVALID-THREAD")
    codex_binary = write_fake_codex!(test_root, :invalid_thread_payload)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:error, {:invalid_thread_payload, %{}}} =
             AppServer.run(workspace, "invalid thread", sample_issue("MT-AS-INVALID-THREAD"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    refute_receive {:app_server_message, _message}
  end

  test "app server returns turn_cancelled errors and emits error lifecycle messages" do
    test_root = temp_dir("app-server-turn-cancelled")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-TURN-CANCELLED")
    codex_binary = write_fake_codex!(test_root, :turn_cancelled)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:error, {:turn_cancelled, %{"reason" => "operator cancelled"}}} =
             AppServer.run(workspace, "turn cancelled", sample_issue("MT-AS-TURN-CANCELLED"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    assert_receive {:app_server_message, %{event: :turn_cancelled, details: %{"reason" => "operator cancelled"}}}

    assert_receive {:app_server_message, %{event: :turn_ended_with_error, reason: {:turn_cancelled, %{"reason" => "operator cancelled"}}}}
  end

  test "app server emits unsupported_tool_call when a tool name is missing" do
    test_root = temp_dir("app-server-unsupported-tool")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-UNSUPPORTED-TOOL")
    codex_binary = write_fake_codex!(test_root, :unsupported_tool_name)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:ok, %{result: :turn_completed}} =
             AppServer.run(workspace, "unsupported tool name", sample_issue("MT-AS-UNSUPPORTED-TOOL"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    assert_receive {:app_server_message, %{event: :unsupported_tool_call, payload: %{"params" => %{"arguments" => %{"note" => "missing tool"}}}}}
  end

  test "app server ignores noisy response startup lines and emits notifications" do
    test_root = temp_dir("app-server-startup-noise")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-NOTIFICATION")
    codex_binary = write_fake_codex!(test_root, :startup_noise_and_notification)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{result: :turn_completed}} =
                 AppServer.run(workspace, "startup noise", sample_issue("MT-AS-NOTIFICATION"), on_message: fn message -> send(parent, {:app_server_message, message}) end)
      end)

    assert log =~ "Codex response stream output: warning: response stream noise"

    assert_receive {:app_server_message,
                    %{
                      event: :notification,
                      payload: %{"method" => "turn/progress", "params" => %{"message" => "working"}},
                      usage: %{"output_tokens" => 2}
                    }}
  end

  test "app server surfaces malformed startup responses without results" do
    test_root = temp_dir("app-server-missing-result")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-MISSING-RESULT")
    codex_binary = write_fake_codex!(test_root, :missing_result_response)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:error, {:response_error, %{"id" => 3, "usage" => %{"input_tokens" => 1}}}} =
             AppServer.run(workspace, "missing result", sample_issue("MT-AS-MISSING-RESULT"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    assert_receive {:app_server_message,
                    %{
                      event: :startup_failed,
                      reason: {:response_error, %{"id" => 3, "usage" => %{"input_tokens" => 1}}}
                    }}
  end

  test "app server times out waiting for startup responses" do
    test_root = temp_dir("app-server-startup-timeout")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-STARTUP-TIMEOUT")
    codex_binary = write_fake_codex!(test_root, :startup_response_timeout)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      codex_read_timeout_ms: 25
    )

    assert {:error, :response_timeout} =
             AppServer.run(workspace, "startup timeout", sample_issue("MT-AS-STARTUP-TIMEOUT"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    refute_receive {:app_server_message, _message}
  end

  test "app server reports turn port exits after startup succeeds" do
    test_root = temp_dir("app-server-turn-port-exit")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-PORT-EXIT")
    codex_binary = write_fake_codex!(test_root, :turn_port_exit)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert {:error, {:port_exit, 17}} =
             AppServer.run(workspace, "turn port exit", sample_issue("MT-AS-PORT-EXIT"), on_message: fn message -> send(parent, {:app_server_message, message}) end)

    assert_receive {:app_server_message, %{event: :session_started}}

    assert_receive {:app_server_message, %{event: :turn_ended_with_error, reason: {:port_exit, 17}}}
  end

  test "app server trims tool names and defaults missing tool arguments" do
    test_root = temp_dir("app-server-trimmed-tool-name")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AS-TOOL-TRIM")
    codex_binary = write_fake_codex!(test_root, :trimmed_tool_name_without_arguments)
    parent = self()

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    tool_executor = fn tool, arguments ->
      send(parent, {:tool_call, tool, arguments})
      %{"success" => true, "contentItems" => [%{"type" => "inputText", "text" => "ok"}]}
    end

    assert {:ok, %{result: :turn_completed}} =
             AppServer.run(workspace, "trimmed tool", sample_issue("MT-AS-TOOL-TRIM"),
               on_message: fn message -> send(parent, {:app_server_message, message}) end,
               tool_executor: tool_executor
             )

    assert_receive {:tool_call, "linear_graphql", %{}}
    assert_receive {:app_server_message, %{event: :tool_call_completed}}
  end

  test "cli evaluate uses the last provided logs root" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok =
             CLI.evaluate(
               [
                 @ack_flag,
                 "--logs-root",
                 "tmp/one",
                 "--logs-root",
                 "tmp/two",
                 "WORKFLOW.md"
               ],
               deps
             )

    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/two")
  end

  @tag timeout: 300_000
  test "cli main exits nonzero when the supervisor stops abnormally" do
    workflow_path = temp_workflow_path("cli-main-abnormal")
    write_workflow_file!(workflow_path, tracker_kind: "memory")

    {_output, 1} =
      run_external_cli("""
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      spawn(fn ->
        wait_for_supervisor = fn wait_for_supervisor ->
          case Process.whereis(SymphonyElixir.Supervisor) do
            pid when is_pid(pid) ->
              Supervisor.stop(pid, :shutdown)

            _ ->
              Process.sleep(50)
              wait_for_supervisor.(wait_for_supervisor)
          end
        end

        wait_for_supervisor.(wait_for_supervisor)
      end)

      SymphonyElixir.CLI.main([#{inspect(@ack_flag)}, #{inspect(workflow_path)}])
      """)
  end

  test "http server accepts localhost hostnames and ignores negative ports" do
    assert :ignore = HttpServer.start_link(port: -1)

    snapshot = %{
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0},
      rate_limits: %{}
    }

    orchestrator_name = Module.concat(__MODULE__, :LocalhostOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: :unavailable})

    start_supervised!({HttpServer, host: "localhost", port: 0, orchestrator: orchestrator_name, snapshot_timeout_ms: 50})

    port = wait_for_bound_port()
    response = Req.get!("http://localhost:#{port}/api/v1/state")

    assert response.status == 200
    assert response.body["counts"]["running"] == 0
  end

  test "http server accepts tuple hosts" do
    snapshot = %{
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0},
      rate_limits: %{}
    }

    orchestrator_name = Module.concat(__MODULE__, :TupleHostOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: :unavailable})

    assert_raise Protocol.UndefinedError, fn ->
      HttpServer.start_link(host: {127, 0, 0, 1}, port: 0, orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    end
  end

  test "linear client short-circuits blank identifiers and missing workflow config" do
    assert {:ok, nil} = Client.fetch_issue_by_identifier("   ")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: nil)
    assert {:error, :missing_linear_api_token} = Client.fetch_candidate_issues()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Client.fetch_candidate_issues()
  end

  test "linear client fetch_candidate_issues resolves me assignee and paginates deterministically" do
    parent = self()

    endpoint =
      start_linear_server!(fn body ->
        payload = Jason.decode!(body)
        send(parent, {:linear_payload, payload})

        cond do
          String.contains?(payload["query"], "query SymphonyLinearViewer") ->
            %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}

          String.contains?(payload["query"], "query SymphonyLinearPoll") and payload["variables"]["after"] == nil ->
            %{
              "data" => %{
                "issues" => %{
                  "nodes" => [
                    linear_issue_payload("issue-1", "MT-LINEAR-1", "viewer-1"),
                    linear_issue_payload("issue-2", "MT-LINEAR-2", "other-user")
                  ],
                  "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-2"}
                }
              }
            }

          String.contains?(payload["query"], "query SymphonyLinearPoll") and payload["variables"]["after"] == "cursor-2" ->
            %{
              "data" => %{
                "issues" => %{
                  "nodes" => [linear_issue_payload("issue-3", "MT-LINEAR-3", "viewer-1")],
                  "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                }
              }
            }
        end
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_assignee: "me",
      tracker_active_states: ["Todo", "In Progress"]
    )

    assert {:ok, issues} = Client.fetch_candidate_issues()

    assert Enum.map(issues, &{&1.identifier, &1.assigned_to_worker}) == [
             {"MT-LINEAR-1", true},
             {"MT-LINEAR-2", false},
             {"MT-LINEAR-3", true}
           ]

    assert_receive {:linear_payload, %{"variables" => %{}, "query" => viewer_query}}
    assert viewer_query =~ "SymphonyLinearViewer"

    assert_receive {:linear_payload, %{"variables" => %{"after" => nil, "projectSlug" => "project", "stateNames" => ["Todo", "In Progress"]}}}
    assert_receive {:linear_payload, %{"variables" => %{"after" => "cursor-2"}}}
  end

  test "linear client fetch_candidate_issues treats blank assignees as no filter" do
    parent = self()

    endpoint =
      start_linear_server!(fn body ->
        payload = Jason.decode!(body)
        send(parent, {:linear_payload, payload})

        %{
          "data" => %{
            "issues" => %{
              "nodes" => [linear_issue_payload("issue-blank", "MT-LINEAR-BLANK", "someone-else")],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_assignee: "   ",
      tracker_active_states: ["Todo"]
    )

    assert {:ok, [%Issue{identifier: "MT-LINEAR-BLANK", assigned_to_worker: true}]} =
             Client.fetch_candidate_issues()

    assert_receive {:linear_payload, %{"variables" => %{"after" => nil, "projectSlug" => "project", "stateNames" => ["Todo"]}}}

    refute_receive {:linear_payload, _payload}
  end

  test "linear client fetch_issues_by_states normalizes and dedupes state names" do
    parent = self()

    endpoint =
      start_linear_server!(fn body ->
        payload = Jason.decode!(body)
        send(parent, {:linear_payload, payload})

        %{
          "data" => %{
            "issues" => %{
              "nodes" => [linear_issue_payload("issue-states", "MT-LINEAR-STATES", "outside-worker")],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project"
    )

    assert {:ok, [%Issue{identifier: "MT-LINEAR-STATES", assigned_to_worker: true}]} =
             Client.fetch_issues_by_states(["Todo", :Todo, "In Progress"])

    assert_receive {:linear_payload,
                    %{
                      "variables" => %{
                        "after" => nil,
                        "projectSlug" => "project",
                        "stateNames" => ["Todo", "In Progress"]
                      }
                    }}
  end

  test "linear client fetch_issue_states_by_ids dedupes ids and filters configured assignees" do
    parent = self()

    endpoint =
      start_linear_server!(fn body ->
        payload = Jason.decode!(body)
        send(parent, {:linear_payload, payload})

        %{
          "data" => %{
            "issues" => %{
              "nodes" => [
                linear_issue_payload("issue-1", "MT-LINEAR-1", "worker-1"),
                linear_issue_payload("issue-2", "MT-LINEAR-2", "worker-2")
              ]
            }
          }
        }
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_assignee: "worker-1"
    )

    assert {:ok, issues} = Client.fetch_issue_states_by_ids(["issue-1", "issue-1", "issue-2"])

    assert Enum.map(issues, &{&1.identifier, &1.assigned_to_worker}) == [
             {"MT-LINEAR-1", true},
             {"MT-LINEAR-2", false}
           ]

    assert_receive {:linear_payload, %{"variables" => %{"ids" => ["issue-1", "issue-2"]}}}
  end

  test "linear client fetch_issue_states_by_ids filters malformed nodes during normalization" do
    endpoint =
      start_linear_server!(fn _body ->
        %{
          "data" => %{
            "issues" => %{
              "nodes" => [
                "not-a-map",
                linear_issue_payload("issue-valid", "MT-LINEAR-VALID", "worker-1")
              ]
            }
          }
        }
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project"
    )

    assert {:ok, [%Issue{identifier: "MT-LINEAR-VALID"}]} =
             Client.fetch_issue_states_by_ids(["issue-valid"])
  end

  test "linear client fetch_issue_by_identifier returns issues and surfaces missing viewer identity for me routing" do
    success_endpoint =
      start_linear_server!(fn body ->
        payload = Jason.decode!(body)

        cond do
          String.contains?(payload["query"], "query SymphonyLinearIssueByIdentifier") ->
            assert payload["variables"]["teamKey"] == "MT"
            assert payload["variables"]["number"] == 9.0

            %{
              "data" => %{
                "issues" => %{
                  "nodes" => [linear_issue_payload("issue-9", "MT-9", "worker-9")]
                }
              }
            }

          true ->
            %{"data" => %{"viewer" => %{}}}
        end
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: success_endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project"
    )

    assert {:ok, %Issue{identifier: "MT-9"}} = Client.fetch_issue_by_identifier("MT-9")
    assert {:error, :invalid_linear_issue_identifier} = Client.fetch_issue_by_identifier("bad-identifier")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: success_endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_assignee: "worker-other"
    )

    assert {:ok, %Issue{identifier: "MT-9", assigned_to_worker: false}} =
             Client.fetch_issue_by_identifier("MT-9")

    missing_viewer_endpoint =
      start_linear_server!(fn _body ->
        %{"data" => %{"viewer" => %{}}}
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: missing_viewer_endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_assignee: "me"
    )

    assert {:error, :missing_linear_viewer_identity} = Client.fetch_candidate_issues()
  end

  test "linear client fetch_issue_by_identifier resolves me assignee routing before decoding issues" do
    parent = self()

    endpoint =
      start_linear_server!(fn body ->
        payload = Jason.decode!(body)
        send(parent, {:linear_payload, payload})

        cond do
          String.contains?(payload["query"], "query SymphonyLinearViewer") ->
            %{"data" => %{"viewer" => %{"id" => "viewer-7"}}}

          String.contains?(payload["query"], "query SymphonyLinearIssueByIdentifier") ->
            %{
              "data" => %{
                "issues" => %{
                  "nodes" => [linear_issue_payload("issue-7", "MT-7", "viewer-7")]
                }
              }
            }
        end
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_assignee: "me"
    )

    assert {:ok, %Issue{identifier: "MT-7", assigned_to_worker: true}} =
             Client.fetch_issue_by_identifier("MT-7")

    assert_receive {:linear_payload, %{"query" => viewer_query}}
    assert viewer_query =~ "SymphonyLinearViewer"

    assert_receive {:linear_payload,
                    %{
                      "query" => issue_query,
                      "variables" => %{"teamKey" => "MT", "number" => 7.0, "projectSlug" => "project"}
                    }}

    assert issue_query =~ "SymphonyLinearIssueByIdentifier"
  end

  test "linear client fetch_candidate_issues propagates viewer request status errors" do
    endpoint =
      start_linear_server!(fn body ->
        payload = Jason.decode!(body)

        if String.contains?(payload["query"], "query SymphonyLinearViewer") do
          {503, %{"errors" => [%{"message" => "viewer unavailable"}]}}
        else
          %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
        end
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_assignee: "me",
      tracker_active_states: ["Todo"]
    )

    assert {:error, {:linear_api_status, 503, %{retry_after_ms: nil}}} = Client.fetch_candidate_issues()
  end

  test "linear client fetch_candidate_issues surfaces poll graphql errors after viewer resolution" do
    endpoint =
      start_linear_server!(fn body ->
        payload = Jason.decode!(body)

        cond do
          String.contains?(payload["query"], "query SymphonyLinearViewer") ->
            %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}

          String.contains?(payload["query"], "query SymphonyLinearPoll") ->
            %{"errors" => [%{"message" => "poll denied"}]}
        end
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_assignee: "me",
      tracker_active_states: ["Todo"]
    )

    assert {:error, {:linear_graphql_errors, [%{"message" => "poll denied"}]}} =
             Client.fetch_candidate_issues()
  end

  test "linear client public fetches surface GraphQL and unknown payload errors" do
    graphql_error_endpoint =
      start_linear_server!(fn _body ->
        %{"errors" => [%{"message" => "linear denied"}]}
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: graphql_error_endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project"
    )

    assert {:error, {:linear_graphql_errors, [%{"message" => "linear denied"}]}} =
             Client.fetch_issue_by_identifier("MT-999")

    unknown_payload_endpoint =
      start_linear_server!(fn _body ->
        %{"data" => %{}}
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: unknown_payload_endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project"
    )

    assert {:error, :linear_unknown_payload} = Client.fetch_issue_by_identifier("MT-1000")
  end

  test "linear client fetch_candidate_issues surfaces missing end cursors through the public API" do
    endpoint =
      start_linear_server!(fn _body ->
        %{
          "data" => %{
            "issues" => %{
              "nodes" => [linear_issue_payload("issue-cursor", "MT-LINEAR-CURSOR", "worker-1")],
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}
            }
          }
        }
      end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_active_states: ["Todo"]
    )

    assert {:error, :linear_missing_end_cursor} = Client.fetch_candidate_issues()
  end

  test "linear client graphql trims operation names, preserves headers, and wraps failures" do
    parent = self()

    assert {:ok, %{"data" => %{}}} =
             Client.graphql("query Viewer { viewer { id } }", %{"includeTeams" => false},
               operation_name: " ViewerQuery ",
               request_fun: fn payload, headers ->
                 send(parent, {:linear_request, payload, headers})
                 {:ok, %{status: 200, body: %{"data" => %{}}}}
               end
             )

    assert_received {:linear_request,
                     %{
                       "query" => "query Viewer { viewer { id } }",
                       "variables" => %{"includeTeams" => false},
                       "operationName" => "ViewerQuery"
                     }, headers}

    assert {"Authorization", "token"} in headers
    assert {"Content-Type", "application/json"} in headers

    assert {:error, {:linear_api_status, 429, %{retry_after_ms: nil}}} =
             Client.graphql("query Viewer { viewer { id } }", %{},
               operation_name: "   ",
               request_fun: fn payload, _headers ->
                 send(parent, {:blank_operation_payload, payload})
                 {:ok, %{status: 429, body: "rate limited"}}
               end
             )

    assert_received {:blank_operation_payload, %{"query" => "query Viewer { viewer { id } }", "variables" => %{}}}

    assert {:error, {:linear_api_status, 500, %{retry_after_ms: nil}}} =
             Client.graphql("query Viewer { viewer { id } }", %{},
               operation_name: "StateLookup",
               request_fun: fn _payload, _headers ->
                 {:ok, %{status: 500, body: %{"errors" => [%{"message" => "boom"}]}}}
               end
             )

    assert {:error, {:linear_api_request, :timeout}} =
             Client.graphql("query Viewer { viewer { id } }", %{}, request_fun: fn _payload, _headers -> {:error, :timeout} end)
  end

  test "linear client helper APIs cover pagination and normalization edge cases" do
    raw_issue = %{
      "id" => "issue-linear",
      "identifier" => "MT-LINEAR",
      "title" => "Investigate",
      "description" => "Test normalization",
      "priority" => "high",
      "state" => %{"name" => "Todo"},
      "branchName" => "gaspar/test",
      "url" => "https://linear.app/test/issue/MT-LINEAR",
      "assignee" => %{"id" => "worker-2"},
      "labels" => %{"nodes" => [%{"name" => "Backend"}, %{}]},
      "inverseRelations" => %{
        "nodes" => [
          %{"type" => " blocks ", "issue" => %{"id" => "block-1", "identifier" => "BLK-1", "state" => %{"name" => "Todo"}}},
          %{"type" => "relates", "issue" => %{"id" => "ignored", "identifier" => "IGN", "state" => %{"name" => "Todo"}}},
          %{"type" => "blocks", "issue" => "bad"}
        ]
      },
      "createdAt" => "not-a-datetime",
      "updatedAt" => "2024-01-01T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "worker-1")

    assert issue.identifier == "MT-LINEAR"
    assert issue.priority == nil
    assert issue.labels == ["backend"]
    assert issue.assigned_to_worker == false
    assert issue.blocked_by == [%{id: "block-1", identifier: "BLK-1", state: "Todo"}]
    assert issue.created_at == nil
    assert %DateTime{} = issue.updated_at

    assert {:error, :linear_missing_end_cursor} = Client.next_page_cursor_for_test(%{has_next_page: true})
    assert :done = Client.next_page_cursor_for_test(%{has_next_page: false})

    merged = Client.merge_issue_pages_for_test([[issue], [%{issue | identifier: "MT-LINEAR-2"}]])
    assert Enum.map(merged, & &1.identifier) == ["MT-LINEAR", "MT-LINEAR-2"]
  end

  test "app server helper seams cover launch, input parsing, usage, and port cleanup branches" do
    assert AppServer.helper_for_test(:launch_command, ["codex app-server", "/bin/bash", "env", %{inherit_env: true, codex_home: nil}]) ==
             "codex app-server"

    assert AppServer.helper_for_test(:launch_command, ["codex app-server", "/bin/bash", "env", %{inherit_env: true, codex_home: "   "}]) ==
             "codex app-server"

    assert AppServer.helper_for_test(:launch_command, ["codex app-server", "/bin/bash", "env", %{inherit_env: true, codex_home: "/tmp/codex-home"}]) ==
             "export CODEX_HOME='/tmp/codex-home'; exec codex app-server"

    assert AppServer.helper_for_test(:launch_command, ["codex app-server", "/bin/bash", "env", %{inherit_env: true, codex_home: 123}]) ==
             "codex app-server"

    launch =
      AppServer.helper_for_test(:launch_command, [
        "codex app-server",
        "/bin/bash",
        "env",
        %{inherit_env: false, codex_home: "/tmp/codex-home", env_allowlist: ["SHOULD_NOT_EXIST"]}
      ])

    assert launch =~ "CODEX_HOME='/tmp/codex-home'"
    assert launch =~ "exec env -i"

    assert AppServer.helper_for_test(:tool_request_user_input_approval_answers, [%{"questions" => [%{"id" => "q1", "options" => [%{"label" => "Approve Once"}]}]}]) ==
             {:ok, %{"q1" => %{"answers" => ["Approve Once"]}}, "Approve this Session"}

    assert AppServer.helper_for_test(:tool_request_user_input_approval_answers, [%{"questions" => [%{"id" => "q1", "options" => nil}]}]) == :error
    assert AppServer.helper_for_test(:tool_request_user_input_approval_answers, [%{"questions" => []}]) == :error

    assert AppServer.helper_for_test(:tool_request_user_input_unavailable_answers, [%{"questions" => [%{"id" => "q1"}]}]) ==
             {:ok, %{"q1" => %{"answers" => ["This is a non-interactive session. Operator input is unavailable."]}}}

    assert AppServer.helper_for_test(:tool_request_user_input_unavailable_answers, [%{"questions" => [%{"header" => "missing id"}]}]) == :error
    assert AppServer.helper_for_test(:tool_request_user_input_unavailable_answers, [%{"questions" => []}]) == :error
    assert AppServer.helper_for_test(:tool_request_user_input_unavailable_answers, [%{}]) == :error

    assert AppServer.helper_for_test(:tool_request_user_input_approval_answer, [%{"id" => "q1", "options" => [%{"label" => "Deny"}, %{"label" => "Allow now"}]}]) ==
             {:ok, "q1", "Allow now"}

    assert AppServer.helper_for_test(:tool_request_user_input_approval_answer, [%{"id" => "q1", "options" => [%{"description" => "missing"}]}]) == :error
    assert AppServer.helper_for_test(:tool_request_user_input_approval_option_label, [[%{"label" => "Allow now"}]]) == "Allow now"
    assert AppServer.helper_for_test(:tool_request_user_input_option_label, [%{}]) == nil
    assert AppServer.helper_for_test(:tool_call_name, [%{"tool" => "   "}]) == nil
    assert AppServer.helper_for_test(:tool_call_name, [:oops]) == nil
    assert AppServer.helper_for_test(:tool_call_arguments, [:oops]) == %{}
    assert AppServer.helper_for_test(:maybe_set_usage, [%{}, %{"usage" => %{"input_tokens" => 1}}]) == %{usage: %{"input_tokens" => 1}}
    assert AppServer.helper_for_test(:maybe_set_usage, [%{}, "oops"]) == %{}
    assert AppServer.helper_for_test(:needs_input, ["turn/requires_input", %{"type" => "input_required"}])
    refute AppServer.helper_for_test(:needs_input, ["notification", %{}])
    refute AppServer.helper_for_test(:needs_input, [123, %{"requiresInput" => true}])

    assert ExUnit.CaptureLog.capture_log(fn ->
             AppServer.helper_for_test(:log_stream_output, ["response stream", "plain notice"])
           end) =~ "Codex response stream output: plain notice"

    assert AppServer.helper_for_test(:shell_escape, ["a'b"]) == "'a'\"'\"'b'"

    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("sh"))}, [
        :binary,
        :exit_status,
        args: [~c"-c", ~c"exit 0"]
      ])

    assert AppServer.helper_for_test(:port_metadata, [port]) |> is_map()
    assert :ok = AppServer.helper_for_test(:stop_port, [port])
    assert :ok = AppServer.helper_for_test(:stop_port, [port])
  end

  defp sample_issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Runtime shell coverage backfill",
      description: "## Acceptance Criteria\n- cover runtime shell branches",
      state: "In Progress",
      url: "https://example.test/issues/#{identifier}",
      labels: ["backend"]
    }
  end

  defp temp_workflow_path(prefix) do
    dir = temp_dir(prefix)
    Path.join(dir, "WORKFLOW.md")
  end

  defp temp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp start_linear_server!(handler) when is_function(handler, 1) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        accept_linear_connections(listener, handler)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)

      if Process.alive?(server) do
        Process.exit(server, :shutdown)
      end
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_linear_connections(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve_linear_request(socket, handler)
        accept_linear_connections(listener, handler)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_linear_request(socket, handler) do
    {:ok, headers, initial_body} = recv_until_headers(socket, "")
    content_length = http_content_length(headers)
    {:ok, body} = recv_exact(socket, content_length - byte_size(initial_body), initial_body)

    {status, response_body} =
      case handler.(body) do
        {status, payload} when is_integer(status) -> {status, encode_linear_response_body(payload)}
        payload -> {200, encode_linear_response_body(payload)}
      end

    response =
      [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " ",
        http_status_reason(status),
        "\r\n",
        "content-type: application/json\r\n",
        "content-length: ",
        Integer.to_string(byte_size(response_body)),
        "\r\n",
        "connection: close\r\n\r\n",
        response_body
      ]

    :ok = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp encode_linear_response_body(payload) when is_binary(payload), do: payload
  defp encode_linear_response_body(payload), do: Jason.encode!(payload)

  defp recv_until_headers(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, rest] ->
        {:ok, headers, rest}

      [_] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> recv_until_headers(socket, acc <> chunk)
          other -> other
        end
    end
  end

  defp recv_exact(_socket, 0, acc), do: {:ok, acc}

  defp recv_exact(socket, remaining, acc) do
    case :gen_tcp.recv(socket, remaining, 5_000) do
      {:ok, chunk} ->
        recv_exact(socket, remaining - byte_size(chunk), acc <> chunk)

      other ->
        other
    end
  end

  defp http_content_length(headers) do
    headers
    |> String.split("\r\n", trim: true)
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            value |> String.trim() |> String.to_integer()
          else
            false
          end

        _ ->
          false
      end
    end)
  end

  defp http_status_reason(200), do: "OK"
  defp http_status_reason(503), do: "Service Unavailable"
  defp http_status_reason(status) when is_integer(status), do: "Status"

  defp wait_for_bound_port(attempts \\ 20)

  defp wait_for_bound_port(attempts) when attempts > 0 do
    case HttpServer.bound_port() do
      port when is_integer(port) ->
        port

      _ ->
        Process.sleep(25)
        wait_for_bound_port(attempts - 1)
    end
  end

  defp wait_for_bound_port(0), do: flunk("http server never bound a port")

  defp run_external_cli(code) when is_binary(code) do
    mix_executable = System.find_executable("mix") || raise "mix executable not found"

    System.cmd(
      mix_executable,
      ["run", "--no-start", "--no-compile", "-e", code],
      cd: File.cwd!(),
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp write_fake_codex!(root, mode) do
    path = Path.join(root, "fake-codex-#{mode}")

    script =
      case mode do
        :start_turn_error ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-startup"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"error":{"message":"turn-start-failed"}}'
                exit 0
                ;;
            esac
          done
          """

        :turn_failed ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-turn-failed"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-turn-failed"}}}'
                ;;
              4)
                printf '%s\\n' '{"method":"turn/failed","params":{"reason":"verifier failed"}}'
                exit 0
                ;;
            esac
          done
          """

        :malformed_and_other_message ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-messages"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-messages"}}}'
                ;;
              4)
                printf '%s\\n' 'warn: noisy line'
                printf '%s\\n' '{"note":"keep-going","usage":{"input_tokens":1}}'
                printf '%s\\n' '{"method":"turn/completed"}'
                exit 0
                ;;
            esac
          done
          """

        :json_shaped_malformed ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-malformed-json"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-malformed-json"}}}'
                ;;
              4)
                printf '%s\\n' '{"note":"broken"'
                printf '%s\\n' '{"method":"turn/completed"}'
                exit 0
                ;;
            esac
          done
          """

        :invalid_thread_payload ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{}}}'
                exit 0
                ;;
            esac
          done
          """

        :turn_cancelled ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-turn-cancelled"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-turn-cancelled"}}}'
                ;;
              4)
                printf '%s\\n' '{"method":"turn/cancelled","params":{"reason":"operator cancelled"}}'
                exit 0
                ;;
            esac
          done
          """

        :unsupported_tool_name ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-unsupported-tool"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-unsupported-tool"}}}'
                ;;
              4)
                printf '%s\\n' '{"id":101,"method":"item/tool/call","params":{"arguments":{"note":"missing tool"}}}'
                ;;
              5)
                printf '%s\\n' '{"method":"turn/completed"}'
                exit 0
                ;;
            esac
          done
          """

        :startup_noise_and_notification ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' 'warning: response stream noise'
                printf '%s\\n' '{"id":99,"result":{"ignored":true}}'
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-notification"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-notification"}}}'
                ;;
              4)
                printf '%s\\n' '{"method":"turn/progress","params":{"message":"working"},"usage":{"output_tokens":2}}'
                printf '%s\\n' '{"method":"turn/completed"}'
                exit 0
                ;;
            esac
          done
          """

        :missing_result_response ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-missing-result"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"usage":{"input_tokens":1}}'
                sleep 0.1
                exit 0
                ;;
            esac
          done
          """

        :startup_response_timeout ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                sleep 1
                exit 0
                ;;
            esac
          done
          """

        :turn_port_exit ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-port-exit"}}}'
                ;;
              3)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-port-exit"}}}'
                sleep 0.1
                exit 17
                ;;
            esac
          done
          """

        :trimmed_tool_name_without_arguments ->
          """
          #!/bin/sh
          count=0
          while IFS= read -r _line; do
            count=$((count + 1))
            case "$count" in
              1)
                printf '%s\\n' '{"id":1,"result":{}}'
                ;;
              2)
                ;;
              3)
                printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-trimmed-tool"}}}'
                ;;
              4)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-trimmed-tool"}}}'
                printf '%s\\n' '{"id":104,"method":"item/tool/call","params":{"tool":"  linear_graphql  "}}'
                ;;
              5)
                printf '%s\\n' '{"method":"turn/completed"}'
                exit 0
                ;;
            esac
          done
          """
      end

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp linear_issue_payload(id, identifier, assignee_id) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => "Linear issue #{identifier}",
      "description" => "GraphQL payload",
      "priority" => 1,
      "state" => %{"name" => "Todo"},
      "branchName" => "gaspar/#{String.downcase(identifier)}",
      "url" => "https://linear.app/test/issue/#{identifier}",
      "assignee" => %{"id" => assignee_id},
      "labels" => %{"nodes" => [%{"name" => "backend"}]},
      "inverseRelations" => %{"nodes" => []},
      "createdAt" => "2024-01-01T00:00:00Z",
      "updatedAt" => "2024-01-01T00:00:00Z"
    }
  end
end
