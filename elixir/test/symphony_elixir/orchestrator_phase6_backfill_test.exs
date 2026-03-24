defmodule SymphonyElixir.OrchestratorPhase6BackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Linear.Issue

  test "start_link without opts exercises the default-name path" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    case Orchestrator.start_link() do
      {:ok, pid} ->
        assert Process.whereis(Orchestrator) == pid
        assert is_map(:sys.get_state(pid))
        GenServer.stop(pid)

      {:error, {:already_started, pid}} ->
        assert Process.whereis(Orchestrator) == pid
    end
  end

  test "malformed codex worker updates fall through to the no-op clause" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :MalformedCodexUpdateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    before_state = :sys.get_state(pid)

    send(
      pid,
      {:agent_worker_update, "issue-malformed", %{event: :notification, payload: %{"summaryText" => "missing timestamp"}}}
    )

    Process.sleep(20)
    after_state = :sys.get_state(pid)

    assert after_state.running == before_state.running
    assert after_state.agent_totals == before_state.agent_totals
    assert after_state.retry_attempts == before_state.retry_attempts
  end

  test "retry_issue with a queued retry entry fetches candidates and releases missing claims" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    issue_id = "issue-retry-backfill"
    orchestrator_name = Module.concat(__MODULE__, :RetryLookupBackfillOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:lease_owner, "retry-owner")
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: make_ref(),
          identifier: "MT-RETRY",
          error: "previous failure"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.retry_attempts, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    assert state.running == initial_state.running
  end

  test "run poll cycle keeps state unchanged when no dispatch slots are available" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 0
    )

    issue = %Issue{id: "issue-no-slots", identifier: "MT-NO-SLOTS", state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :NoDispatchSlotsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert state.running == %{}
    assert state.last_candidate_issues == [issue]
  end

  test "run poll cycle covers missing project slug and tracker kind validation errors" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    missing_project_name = Module.concat(__MODULE__, :MissingProjectSlugOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: nil
    )

    {:ok, project_pid} = Orchestrator.start_link(name: missing_project_name)

    on_exit(fn ->
      if Process.alive?(project_pid) do
        Process.exit(project_pid, :normal)
      end
    end)

    send(project_pid, :run_poll_cycle)
    Process.sleep(50)
    assert :sys.get_state(project_pid).running == %{}

    missing_kind_name = Module.concat(__MODULE__, :MissingTrackerKindOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: nil
    )

    {:ok, kind_pid} = Orchestrator.start_link(name: missing_kind_name)

    on_exit(fn ->
      if Process.alive?(kind_pid) do
        Process.exit(kind_pid, :normal)
      end
    end)

    send(kind_pid, :run_poll_cycle)
    Process.sleep(50)
    assert :sys.get_state(kind_pid).running == %{}
  end

  test "run poll cycle covers unsupported tracker kinds and runtime config validation errors" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    unsupported_name = Module.concat(__MODULE__, :UnsupportedTrackerKindOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "unsupported"
    )

    {:ok, unsupported_pid} = Orchestrator.start_link(name: unsupported_name)

    on_exit(fn ->
      if Process.alive?(unsupported_pid) do
        Process.exit(unsupported_pid, :normal)
      end
    end)

    send(unsupported_pid, :run_poll_cycle)
    Process.sleep(50)
    assert :sys.get_state(unsupported_pid).running == %{}

    invalid_approval_name = Module.concat(__MODULE__, :InvalidApprovalPolicyOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_command: "codex app-server",
      codex_approval_policy: "   "
    )

    {:ok, invalid_approval_pid} = Orchestrator.start_link(name: invalid_approval_name)

    on_exit(fn ->
      if Process.alive?(invalid_approval_pid) do
        Process.exit(invalid_approval_pid, :normal)
      end
    end)

    send(invalid_approval_pid, :run_poll_cycle)
    Process.sleep(50)
    assert :sys.get_state(invalid_approval_pid).running == %{}

    invalid_sandbox_name = Module.concat(__MODULE__, :InvalidThreadSandboxOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_command: "codex app-server",
      codex_thread_sandbox: "   "
    )

    {:ok, invalid_sandbox_pid} = Orchestrator.start_link(name: invalid_sandbox_name)

    on_exit(fn ->
      if Process.alive?(invalid_sandbox_pid) do
        Process.exit(invalid_sandbox_pid, :normal)
      end
    end)

    send(invalid_sandbox_pid, :run_poll_cycle)
    Process.sleep(50)
    assert :sys.get_state(invalid_sandbox_pid).running == %{}

    invalid_turn_sandbox_name = Module.concat(__MODULE__, :InvalidTurnSandboxPolicyOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_command: "codex app-server",
      codex_turn_sandbox_policy: "   "
    )

    {:ok, invalid_turn_sandbox_pid} = Orchestrator.start_link(name: invalid_turn_sandbox_name)

    on_exit(fn ->
      if Process.alive?(invalid_turn_sandbox_pid) do
        Process.exit(invalid_turn_sandbox_pid, :normal)
      end
    end)

    send(invalid_turn_sandbox_pid, :run_poll_cycle)
    Process.sleep(50)
    assert :sys.get_state(invalid_turn_sandbox_pid).running == %{}

    workflow_store_pid = Process.whereis(WorkflowStore)

    on_exit(fn ->
      if is_pid(workflow_store_pid) and is_nil(Process.whereis(WorkflowStore)) do
        _ = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    missing_workflow_name = Module.concat(__MODULE__, :MissingWorkflowFileOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory"
    )

    {:ok, missing_workflow_pid} = Orchestrator.start_link(name: missing_workflow_name)

    on_exit(fn ->
      if Process.alive?(missing_workflow_pid) do
        Process.exit(missing_workflow_pid, :normal)
      end
    end)

    File.rm!(Workflow.workflow_file_path())
    send(missing_workflow_pid, :run_poll_cycle)
    Process.sleep(50)
    assert :sys.get_state(missing_workflow_pid).running == %{}
  end

  test "direct run_poll_cycle handling logs workflow parse configuration errors" do
    orchestrator_name = Module.concat(__MODULE__, :DirectPollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    state = :sys.get_state(pid)
    workflow_store_pid = Process.whereis(WorkflowStore)

    on_exit(fn ->
      if is_pid(workflow_store_pid) and is_nil(Process.whereis(WorkflowStore)) do
        _ = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      end
    end)

    log =
      capture_log(fn ->
        assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

        File.write!(Workflow.workflow_file_path(), """
        ---
        - not-a-map
        ---
        Prompt
        """)

        assert {:noreply, _} = Orchestrator.handle_info(:run_poll_cycle, state)

        File.write!(Workflow.workflow_file_path(), """
        ---
        tracker:
          kind: [oops
        ---
        Prompt
        """)

        assert {:noreply, _} = Orchestrator.handle_info(:run_poll_cycle, state)

        File.rm!(Workflow.workflow_file_path())
        assert {:noreply, _} = Orchestrator.handle_info(:run_poll_cycle, state)
      end)

    assert log =~ "Dispatch blocked by config validation"
    assert log =~ "workflow_front_matter_not_a_map"
    assert log =~ "missing_workflow_file"
  end

  test "sort_issues_for_dispatch_for_test falls back to an empty orchestrator state" do
    issues = [
      %Issue{id: "issue-sort-1", identifier: "MT-SORT-1", title: "One", state: "Todo"},
      %Issue{id: "issue-sort-2", identifier: "MT-SORT-2", title: "Two", state: "Todo"}
    ]

    assert Orchestrator.sort_issues_for_dispatch_for_test(issues, %{}) == issues
  end

  test "reconcile_stalled_running_issues_for_test returns the state unchanged when stall detection is disabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 0
    )

    orchestrator_name = Module.concat(__MODULE__, :DisabledStallDetectionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    state = :sys.get_state(pid)
    assert Orchestrator.reconcile_stalled_running_issues_for_test(state) == state
  end

  test "stall_elapsed_ms_for_test returns nil when no activity timestamp is available" do
    assert Orchestrator.stall_elapsed_ms_for_test(%{}, DateTime.utc_now()) == nil
  end

  test "last_activity_timestamp_for_test returns nil for non-map entries" do
    assert Orchestrator.last_activity_timestamp_for_test(:invalid) == nil
  end

  test "terminate_task_for_test returns :ok for non-pid values and task children" do
    assert :ok = Orchestrator.terminate_task_for_test(:not_a_pid)

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        Process.sleep(:infinity)
      end)

    assert :ok = Orchestrator.terminate_task_for_test(task.pid)
  end

  test "partition_issues_by_label_gate_for_test marks skipped issues when required labels are missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"]
    )

    orchestrator_name = Module.concat(__MODULE__, :PartitionLabelGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    state = :sys.get_state(pid)

    issue = %Issue{
      id: "issue-partition-label-gate",
      identifier: "MT-PARTITION-LABEL",
      title: "Partition label gate",
      state: "Todo",
      labels: []
    }

    {eligible, skipped} = Orchestrator.partition_issues_by_label_gate_for_test([issue], state)

    assert eligible == []
    assert [%{issue_identifier: "MT-PARTITION-LABEL", reason: "missing required labels"}] = skipped
  end

  test "partition_issues_by_label_gate_for_test falls back to empty buckets for non-state values" do
    assert {[], []} = Orchestrator.partition_issues_by_label_gate_for_test([:anything], %{})
  end

  test "skipped_issue_entry_for_test falls back to a minimal payload for malformed issues" do
    assert %{reason: "missing required labels"} =
             Orchestrator.skipped_issue_entry_for_test(%{}, "missing required labels", %{})
  end

  test "choose_issues_for_test leaves state unchanged when an issue is not dispatchable" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :ChooseIssuesNoDispatchOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    state = :sys.get_state(pid)

    issue = %Issue{
      id: "issue-no-dispatch",
      identifier: "MT-NO-DISPATCH",
      title: "No dispatch",
      state: "Todo",
      assigned_to_worker: false
    }

    assert Orchestrator.choose_issues_for_test([issue], state) == state
  end

  test "choose_issues_for_test dispatches an eligible issue" do
    issue = %Issue{
      id: "issue-dispatchable",
      identifier: "MT-DISPATCHABLE",
      title: "Dispatchable",
      state: "Todo",
      labels: []
    }

    state = %Orchestrator.State{max_concurrent_agents: 1}

    assert %{dispatched: "MT-DISPATCHABLE"} =
             Orchestrator.choose_issues_for_test([issue], state, fn _state, dispatched_issue ->
               %{dispatched: dispatched_issue.identifier}
             end)
  end

  test "should_dispatch_issue_for_test returns false for malformed state values" do
    issue = %Issue{id: "issue-malformed-state", identifier: "MT-MALFORMED-STATE", title: "Malformed", state: "Todo"}
    refute Orchestrator.should_dispatch_issue_for_test(issue, %{})
  end

  test "should_dispatch_issue_for_test returns false for malformed issue values" do
    refute Orchestrator.should_dispatch_issue_for_test(%{}, %Orchestrator.State{})
  end

  test "state_slots_available_for_test returns false when running is not a map" do
    issue = %Issue{id: "issue-non-map", identifier: "MT-NON-MAP", title: "Non map", state: "Todo"}
    refute Orchestrator.state_slots_available_for_test(issue, :not_a_map)
  end

  test "running_issue_count_for_state_for_test ignores malformed running entries" do
    running = %{
      "issue-1" => %{issue: %Issue{state: "Todo"}},
      "issue-2" => %{identifier: "MT-NO-ISSUE"}
    }

    assert Orchestrator.running_issue_count_for_state_for_test(running, "Todo") == 1
  end

  test "issue_routable_to_worker_for_test defaults to true for malformed values" do
    assert Orchestrator.issue_routable_to_worker_for_test(%{}) == true
  end

  test "issue_labels_for_test defaults to an empty list for malformed values" do
    assert Orchestrator.issue_labels_for_test(%{}) == []
  end

  test "issue_matches_required_labels_for_test defaults to true for malformed values" do
    assert Orchestrator.issue_matches_required_labels_for_test(%{}) == true
  end

  test "label_gate_status_for_test defaults to an eligible empty status for malformed values" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"]
    )

    assert %{
             eligible?: true,
             required_labels: ["dogfood:symphony"],
             reason: nil
           } = Orchestrator.label_gate_status_for_test(%{})
  end

  test "todo_issue_blocked_by_non_terminal_for_test treats malformed blockers as blocking" do
    terminal_states = MapSet.new(["done", "closed"])

    issue = %Issue{
      id: "issue-malformed-blocker",
      identifier: "MT-MALFORMED-BLOCKER",
      title: "Malformed blocker",
      state: "Todo",
      blocked_by: [%{identifier: "missing-state"}]
    }

    assert Orchestrator.todo_issue_blocked_by_non_terminal_for_test(issue, terminal_states)
  end

  test "todo_issue_blocked_by_non_terminal_for_test returns false for malformed issues" do
    refute Orchestrator.todo_issue_blocked_by_non_terminal_for_test(%{}, MapSet.new())
  end

  test "reconcile_issue_states_for_test ignores non-issue entries for state structs" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :NonIssueReconcileOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    state = :sys.get_state(pid)
    assert Orchestrator.reconcile_issue_states_for_test([:not_an_issue], state) == state
  end

  test "run poll cycle refreshes currently running issues when state fetch succeeds" do
    issue = %Issue{id: "issue-running-refresh", identifier: "MT-RUNNING", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :RunningRefreshOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    claim_issue_lease!(issue.id, issue.identifier, initial_state.lease_owner)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: %{issue | title: "stale"},
      session_id: nil,
      turn_count: 0,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      last_agent_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
    end)

    send(pid, :run_poll_cycle)
    Process.sleep(50)

    refreshed_state = :sys.get_state(pid)
    assert refreshed_state.running[issue.id].issue == issue
  end

  test "reconcile_issue_states_for_test blocks running issues with conflicting policy labels" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-policy-conflict",
      identifier: "MT-POLICY-CONFLICT",
      title: "Policy conflict",
      state: "In Progress",
      labels: ["policy:review-required", "policy:never-automerge"]
    }

    state = running_state_with_issue!(issue)
    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue.id)

    assert {:ok, run_state} =
             SymphonyElixir.RunStateStore.load(Path.join(Config.workspace_root(), issue.identifier))

    assert run_state.last_rule_id == "policy.invalid_labels"
  end

  test "reconcile_issue_states_for_test keeps state unchanged when an active issue has no running entry" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-missing-running-entry",
      identifier: "MT-MISSING-RUNNING",
      title: "Missing running entry",
      state: "In Progress",
      labels: []
    }

    orchestrator_name = Module.concat(__MODULE__, :MissingRunningEntryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    state = :sys.get_state(pid)

    assert Orchestrator.reconcile_issue_states_for_test([issue], state) ==
             %{
               state
               | issue_routing_cache: %{
                   issue.id => %{
                     state: issue.state,
                     assignee_id: issue.assignee_id,
                     labels: [],
                     updated_at: issue.updated_at
                   }
                 }
             }
  end

  test "reconcile_issue_states_for_test stops running issues that lose the required label gate" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"]
    )

    issue = %Issue{
      id: "issue-missing-label",
      identifier: "MT-MISSING-LABEL",
      title: "Missing label",
      state: "In Progress",
      labels: []
    }

    state = running_state_with_issue!(issue)
    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue.id)
    refute MapSet.member?(updated_state.claimed, issue.id)
  end

  test "reconcile_issue_states_for_test releases claims for malformed running entries" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-malformed-running-entry",
      identifier: "MT-MALFORMED-RUNNING",
      title: "Malformed running entry",
      state: "Done",
      labels: []
    }

    state = running_state_with_issue!(issue, %{identifier: issue.identifier})
    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert Map.has_key?(updated_state.running, issue.id)
    refute MapSet.member?(updated_state.claimed, issue.id)
  end

  test "reconcile_issue_states_for_test accepts non-struct state values" do
    state = %{marker: :ok}
    assert %{marker: :ok} = Orchestrator.reconcile_issue_states_for_test([], state)
  end

  defp running_state_with_issue!(issue, running_entry \\ nil) do
    orchestrator_name =
      Module.concat(__MODULE__, :"RunningState#{System.unique_integer([:positive])}")

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    claim_issue_lease!(issue.id, issue.identifier, initial_state.lease_owner)
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    %{
      initial_state
      | running: %{
          issue.id =>
            running_entry ||
              %{
                pid: worker_pid,
                ref: make_ref(),
                identifier: issue.identifier,
                issue: issue,
                session_id: nil,
                turn_count: 0,
                last_agent_message: nil,
                last_agent_timestamp: nil,
                last_agent_event: nil,
                started_at: DateTime.utc_now()
              }
        },
        claimed: MapSet.put(initial_state.claimed, issue.id)
    }
  end

  defp claim_issue_lease!(issue_id, identifier, owner) do
    assert :ok = LeaseManager.acquire(issue_id, identifier, owner)

    on_exit(fn ->
      LeaseManager.release(issue_id)
    end)
  end
end
