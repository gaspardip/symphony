defmodule SymphonyElixir.ManualIntakeTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.{IssueSource, ManualIssueStore, Orchestrator, Workflow}
  alias SymphonyElixirWeb.Presenter

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule ManualSubmitOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok, %{reply: Keyword.fetch!(opts, :reply), parent: Keyword.fetch!(opts, :parent)}}
    end

    @impl true
    def handle_call({:submit_manual_issue, spec}, _from, state) do
      send(state.parent, {:manual_submit, spec})
      {:reply, state.reply, state}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, %{running: [], retrying: [], paused: [], skipped: [], queue: []}, state}
    end
  end

  setup do
    store_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-manual-intake-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      manual_store_root: store_root,
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Done", "Blocked", "Closed", "Canceled", "Duplicate"]
    )

    on_exit(fn -> File.rm_rf(store_root) end)

    {:ok, store_root: store_root}
  end

  test "manual submit endpoint forwards specs to the orchestrator and returns the accepted payload" do
    orchestrator_name = Module.concat(__MODULE__, :ManualSubmitEndpointOrchestrator)

    {:ok, _pid} =
      ManualSubmitOrchestrator.start_link(
        name: orchestrator_name,
        parent: self(),
        reply: %{
          ok: true,
          accepted: true,
          source: "manual",
          issue_id: "manual:clz-14",
          issue_identifier: "CLZ-14",
          state: "Todo",
          ledger_event_id: "ledger-1"
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = %{
      "id" => "clz-14",
      "identifier" => "CLZ-14",
      "title" => "Manual pilot issue",
      "acceptance_criteria" => ["Build a PR", "Merge it"]
    }

    conn = post(build_conn(), "/api/v1/manual-runs", payload)

    assert json_response(conn, 202) == %{
             "accepted" => true,
             "issue_id" => "manual:clz-14",
             "issue_identifier" => "CLZ-14",
             "ledger_event_id" => "ledger-1",
             "ok" => true,
             "source" => "manual",
             "state" => "Todo"
           }

    assert_receive {:manual_submit, ^payload}
  end

  test "manual submit endpoint returns a validation failure when the orchestrator rejects the spec" do
    orchestrator_name = Module.concat(__MODULE__, :ManualSubmitRejectedOrchestrator)

    {:ok, _pid} =
      ManualSubmitOrchestrator.start_link(
        name: orchestrator_name,
        parent: self(),
        reply: %{ok: false, accepted: false, error: ":duplicate_manual_issue"}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn =
      post(build_conn(), "/api/v1/manual-runs", %{
        "id" => "dup",
        "identifier" => "CLZ-DUP",
        "title" => "Duplicate",
        "acceptance_criteria" => ["No duplicates"]
      })

    assert json_response(conn, 400) == %{
             "error" => %{
               "code" => "manual_issue_rejected",
               "message" => ":duplicate_manual_issue"
             }
           }
  end

  test "manual issues are persisted, exposed through issue source, and support source-aware controls" do
    orchestrator_name = Module.concat(__MODULE__, :ManualSourceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    payload = %{
      "id" => "clz-14",
      "identifier" => "CLZ-14",
      "title" => "Manual pilot issue",
      "acceptance_criteria" => ["Persist manual state", "Support operator actions"],
      "policy_class" => "review_required"
    }

    assert %{ok: true, accepted: true, source: "manual", issue_identifier: "CLZ-14"} =
             Orchestrator.submit_manual_issue(pid, payload)

    state = :sys.get_state(pid)

    assert Enum.any?(state.last_candidate_issues, fn
             %{identifier: "CLZ-14", source: :manual} -> true
             _ -> false
           end)

    assert {:ok, issue} = IssueSource.fetch_issue_by_identifier("CLZ-14")
    assert issue.source == :manual
    assert "policy:review-required" in issue.labels

    assert :ok = ManualIssueStore.update_issue_state(issue.id, "Human Review")

    assert %{ok: true, action: "approve_for_merge", state: "Merging"} =
             Orchestrator.approve_issue_for_merge(pid, "CLZ-14")

    assert {:ok, refreshed_issue} = IssueSource.fetch_issue_by_identifier("CLZ-14")
    assert refreshed_issue.state == "Merging"
  end

  test "manual submit scheduling uses the normal discovery cycle" do
    state =
      Orchestrator.manual_issue_refresh_state_for_test(%Orchestrator.State{
        poll_check_in_progress: false,
        current_poll_mode: nil
      })

    assert state.poll_check_in_progress == true
    assert state.current_poll_mode == :discovery
    assert is_nil(state.next_poll_due_at_ms)
  end

  test "manual tracked issue payload renders manual issues without leaking raw issue structs" do
    orchestrator_name = Module.concat(__MODULE__, :ManualIssueDetailOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{ok: true, accepted: true, source: "manual", issue_identifier: "CLZ-14-DETAIL"} =
             Orchestrator.submit_manual_issue(pid, %{
               "id" => "clz-14-detail",
               "identifier" => "CLZ-14-DETAIL",
               "title" => "Manual detail issue",
               "acceptance_criteria" => ["Expose manual issue detail payloads"],
               "description" => "Ensure the issue endpoint returns JSON for manual issues."
             })

    payload = Presenter.helper_for_test(:tracked_issue_payload, ["CLZ-14-DETAIL"])

    assert payload[:id] == "manual:clz-14-detail"
    assert payload[:external_id] == "clz-14-detail"
    assert payload[:canonical_identifier] == "CLZ-14-DETAIL"
    assert payload[:source] == "manual"
    assert payload[:identifier] == "CLZ-14-DETAIL"
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
end
