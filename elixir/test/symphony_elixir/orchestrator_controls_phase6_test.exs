defmodule SymphonyElixir.OrchestratorControlsPhase6Test do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Orchestrator.State

  test "invalid dogfood runner install disables dispatch while keeping snapshots available" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-invalid-dispatch-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"],
      runner_install_root: runner_root
    )

    issue = %Issue{
      id: "issue-dogfood-runner-invalid",
      identifier: "MT-DOGFOOD-RUNNER-INVALID",
      title: "Dogfood invalid runner",
      description: "runner install should disable dispatch",
      state: "Todo",
      labels: ["dogfood:symphony"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :InvalidRunnerOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(runner_root)
    end)

    snapshot =
      Enum.reduce_while(1..20, nil, fn _, _acc ->
        Process.sleep(20)
        snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

        if get_in(snapshot, [:runner, :dispatch_enabled]) == false do
          {:halt, snapshot}
        else
          {:cont, snapshot}
        end
      end)

    assert snapshot.runner.dispatch_enabled == false
    assert snapshot.runner.runner_health == "invalid"
    assert snapshot.runner.runner_health_rule_id == "runner.install_missing"
    assert snapshot.running == []
    assert [%{error: "{:runner_health, \"runner.install_missing\"}"}] = snapshot.queue
  end

  test "request refresh, snapshot, and queue payloads expose paused skipped and queued issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_max_concurrent_agents: 2
    )

    orchestrator_name = Module.concat(__MODULE__, :SnapshotControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    queue_issue = %Issue{
      id: "issue-queue",
      identifier: "MT-QUEUE",
      title: "Queued issue",
      description: "queue me",
      priority: 3,
      state: "Todo",
      labels: ["dogfood:symphony"]
    }

    paused_entry = %{
      identifier: "MT-PAUSED",
      resume_state: "In Progress",
      policy_class: "review_required",
      policy_source: "override",
      policy_override: "review_required",
      next_human_action: "Resume it",
      last_rule_id: "operator.pause",
      last_failure_class: "policy",
      last_decision_summary: "Paused manually",
      last_ledger_event_id: "evt-pause"
    }

    skipped_entry = %{
      issue_id: "issue-skip",
      issue_identifier: "MT-SKIP",
      state: "Todo",
      labels: ["dogfood:symphony"],
      required_labels: ["dogfood:symphony", "canary:symphony"],
      reason: "missing canary labels",
      policy_class: "fully_autonomous",
      policy_source: "label",
      policy_override: nil,
      next_human_action: "Add the canary label",
      last_rule_id: "runner.canary_active",
      last_failure_class: "policy"
    }

    state =
      :sys.get_state(pid)
      |> Map.put(:paused_issue_states, %{"issue-paused" => paused_entry})
      |> Map.put(:skipped_issues, [skipped_entry])
      |> Map.put(:last_candidate_issues, [queue_issue])
      |> Map.put(:priority_overrides, %{"MT-QUEUE" => 0})
      |> Map.put(:retry_attempts, %{"issue-queue" => %{attempt: 2, due_at_ms: now_ms + 5_000, identifier: "MT-QUEUE"}})
      |> Map.put(:candidate_fetch_error, nil)
      |> Map.put(:next_poll_due_at_ms, now_ms - 1)

    :sys.replace_state(pid, fn _ -> state end)

    refresh = Orchestrator.request_refresh(orchestrator_name)
    assert refresh.queued == true
    assert refresh.coalesced == true
    assert refresh.operations == ["poll", "reconcile"]

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert [%{identifier: "MT-PAUSED", resume_state: "In Progress"}] = snapshot.paused

    assert [%{issue_identifier: "MT-SKIP", reason: "missing canary labels"}] =
             snapshot.skipped

    assert [
             %{
               issue_identifier: "MT-QUEUE",
               operator_override: 0,
               retry_penalty: 2,
               label_gate_eligible: true
             }
           ] = snapshot.queue
  end

  test "pause and resume controls mutate orchestrator runtime state" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-pause-runtime",
      identifier: "MT-PAUSE",
      title: "Pause me",
      description: "control plane pause test",
      state: "In Progress",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :PauseResumeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    claim_issue_lease!(issue.id, issue.identifier, initial_state.lease_owner)
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      started_at: DateTime.utc_now()
    }

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
    end)

    pause_payload = Orchestrator.pause_issue(orchestrator_name, issue.identifier)
    assert pause_payload.ok == true
    assert pause_payload.action == "pause"
    assert pause_payload.state == "Paused"
    assert is_binary(pause_payload.ledger_event_id)

    paused_state = :sys.get_state(pid)
    assert paused_state.running == %{}
    assert get_in(paused_state.paused_issue_states, [issue.id, :resume_state]) == "In Progress"

    resume_payload = Orchestrator.resume_issue(orchestrator_name, issue.identifier)
    assert resume_payload.ok == true
    assert resume_payload.action == "resume"
    assert resume_payload.state == "In Progress"
    assert is_binary(resume_payload.ledger_event_id)

    resumed_state = :sys.get_state(pid)
    assert resumed_state.paused_issue_states == %{}
  end

  test "policy override, approve for merge, retry now, and reprioritize controls return structured payloads" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-policy-runtime",
      identifier: "MT-POLICY-RUNTIME",
      title: "Policy runtime",
      description: "exercise operator controls",
      state: "Human Review",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :PolicyControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    set_payload = Orchestrator.set_policy_class(orchestrator_name, issue.identifier, "never_automerge")
    assert set_payload.ok == true
    assert set_payload.policy_class == "never_automerge"
    assert set_payload.policy_source == "override"

    approve_payload = Orchestrator.approve_issue_for_merge(orchestrator_name, issue.identifier)
    assert approve_payload.ok == false
    assert approve_payload.error == "policy forbids automerge"

    clear_payload = Orchestrator.clear_policy_override(orchestrator_name, issue.identifier)
    assert clear_payload.ok == true
    assert clear_payload.policy_class == nil
    assert clear_payload.policy_source == "label_or_default"

    approve_payload = Orchestrator.approve_issue_for_merge(orchestrator_name, issue.identifier)
    assert approve_payload.ok == true
    assert approve_payload.state == "Merging"

    retry_payload = Orchestrator.retry_issue_now(orchestrator_name, issue.identifier)
    assert retry_payload.ok == true
    assert retry_payload.action == "retry_now"

    reprioritize_payload = Orchestrator.reprioritize_issue(orchestrator_name, issue.identifier, 1)
    assert reprioritize_payload.ok == true
    assert reprioritize_payload.override_rank == 1

    reset_payload = Orchestrator.reprioritize_issue(orchestrator_name, issue.identifier, nil)
    assert reset_payload.ok == true
    assert reset_payload.override_rank == nil
  end

  test "dispatch helper functions cover label gates blockers and revalidation outcomes" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"],
      agent_max_concurrent_agents: 1
    )

    eligible_issue = %Issue{
      id: "issue-eligible",
      identifier: "MT-ELIGIBLE",
      title: "Eligible",
      description: "can dispatch",
      state: "Todo",
      labels: ["dogfood:symphony"],
      assigned_to_worker: true
    }

    blocked_todo =
      Map.put(eligible_issue, :blocked_by, [%{state: "In Progress"}])

    missing_label_issue =
      %{eligible_issue | id: "issue-missing-label", identifier: "MT-MISSING-LABEL", labels: ["ops"]}

    claimed_state = %State{
      max_concurrent_agents: 1,
      claimed: MapSet.new(["issue-eligible"])
    }

    assert Orchestrator.should_dispatch_issue_for_test(eligible_issue, claimed_state) == false
    assert Orchestrator.should_dispatch_issue_for_test(blocked_todo, %State{max_concurrent_agents: 1}) == false
    assert Orchestrator.should_dispatch_issue_for_test(missing_label_issue, %State{max_concurrent_agents: 1}) == false
    assert Orchestrator.should_dispatch_issue_for_test(eligible_issue, %State{max_concurrent_agents: 1}) == true

    second_issue = %{eligible_issue | id: "issue-second", identifier: "MT-SECOND", priority: 4}
    third_issue = %{eligible_issue | id: "issue-third", identifier: "MT-THIRD", priority: 0}

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test(
        [second_issue, eligible_issue, third_issue],
        %State{priority_overrides: %{"MT-SECOND" => 0}, retry_attempts: %{"issue-third" => 3}}
      )

    assert Enum.map(sorted, & &1.identifier) == ["MT-SECOND", "MT-ELIGIBLE", "MT-THIRD"]

    assert {:skip, :missing} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(eligible_issue, fn [_id] -> {:ok, []} end)

    assert {:skip, %Issue{state: "Done"}} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(eligible_issue, fn [_id] ->
               {:ok, [%{eligible_issue | state: "Done"}]}
             end)

    assert {:error, :boom} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(eligible_issue, fn [_id] ->
               {:error, :boom}
             end)
  end

  test "dispatch helper wrappers cover success skip and refresh-error branches" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    terminal_states = MapSet.new(["done"])
    refute Orchestrator.terminal_issue_state_for_test(%{}, terminal_states)

    issue = %Issue{
      id: "issue-dispatch-skip",
      identifier: "MT-DISPATCH-SKIP",
      title: "Dispatch skip",
      description: "cover skip logging",
      state: "Todo",
      labels: ["ops"]
    }

    dispatched_state =
      Orchestrator.dispatch_issue_for_test(%State{}, issue,
        attempt: 3,
        issue_fetcher: fn [_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
        dispatch_fun: fn state, refreshed_issue, attempt ->
          send(self(), {:dispatch_fun_called, refreshed_issue.identifier, refreshed_issue.state, attempt})
          %{state | candidate_fetch_error: refreshed_issue.state}
        end
      )

    assert_receive {:dispatch_fun_called, "MT-DISPATCH-SKIP", "In Progress", 3}
    assert %State{candidate_fetch_error: "In Progress"} = dispatched_state

    missing_log =
      capture_log(fn ->
        assert %State{} =
                 Orchestrator.dispatch_issue_for_test(%State{}, issue,
                   issue_fetcher: fn [_id] -> {:ok, []} end
                 )
      end)

    assert missing_log =~
             "Skipping dispatch; issue no longer active or visible: issue_id=issue-dispatch-skip issue_identifier=MT-DISPATCH-SKIP"

    stale_log =
      capture_log(fn ->
        assert %State{} =
                 Orchestrator.dispatch_issue_for_test(%State{}, issue,
                   issue_fetcher: fn [_id] -> {:ok, [%{issue | state: "Done"}]} end
                 )
      end)

    assert stale_log =~
             "Skipping stale dispatch after issue refresh: issue_id=issue-dispatch-skip issue_identifier=MT-DISPATCH-SKIP"

    assert stale_log =~ "state=\"Done\""
    assert stale_log =~ "blocked_by=0"

    error_log =
      capture_log(fn ->
        assert %State{} =
                 Orchestrator.dispatch_issue_for_test(%State{}, issue,
                   issue_fetcher: fn [_id] -> {:error, :boom} end
                 )
      end)

    assert error_log =~
             "Skipping dispatch; issue refresh failed for issue_id=issue-dispatch-skip issue_identifier=MT-DISPATCH-SKIP: :boom"
  end

  test "default dispatch path and direct worker dispatch helpers cover the real spawn path" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-default-dispatch-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: nil
    )

    issue = %Issue{
      id: "issue-default-dispatch",
      identifier: "MT-DEFAULT-DISPATCH",
      title: "Default dispatch",
      description: "cover real dispatch path",
      state: "Todo",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    owner = "dispatch-owner-#{System.unique_integer([:positive])}"

    assert %State{} =
             Orchestrator.dispatch_issue_for_test(
               %State{lease_owner: owner, max_concurrent_agents: 1},
               issue
             )

    spawned_issue = %{
      issue
      | id: "issue-direct-dispatch",
        identifier: "MT-DIRECT-DISPATCH",
        title: "Direct dispatch"
    }

    state =
      Orchestrator.do_dispatch_issue_for_test(
        %State{lease_owner: owner, max_concurrent_agents: 1},
        spawned_issue
      )

    refute state.running == %{} and state.retry_attempts == %{}

    pid =
      case Map.get(state.running, spawned_issue.id) do
        %{pid: running_pid} when is_pid(running_pid) -> running_pid
        _ -> nil
      end

    on_exit(fn ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      LeaseManager.release(issue.id, owner)
      LeaseManager.release(spawned_issue.id, owner)
      File.rm_rf(workspace_root)
    end)
  end

  test "dispatch helpers cover lease acquisition and worker spawn failures" do
    owner = "dispatch-owner-#{System.unique_integer([:positive])}"

    issue = %Issue{
      id: "issue-dispatch-errors",
      identifier: "MT-DISPATCH-ERRORS",
      title: "Dispatch errors",
      description: "cover orchestrator error paths",
      state: "Todo",
      labels: ["ops"]
    }

    lease_log =
      capture_log(fn ->
        returned_state =
          Orchestrator.do_dispatch_issue_for_test(
            %State{lease_owner: owner},
            issue,
            nil,
            acquire_fun: fn _, _, _ -> {:error, :disk_full} end
          )

        assert returned_state == %State{lease_owner: owner}
      end)

    assert lease_log =~
             "Skipping dispatch; failed to acquire lease for issue_id=issue-dispatch-errors issue_identifier=MT-DISPATCH-ERRORS: :disk_full"

    spawned_state =
      Orchestrator.do_spawn_issue_worker_for_test(
        %State{lease_owner: owner},
        %{issue | id: "issue-spawn-errors", identifier: "MT-SPAWN-ERRORS"},
        4,
        self(),
        start_child_fun: fn _supervisor, _fun -> {:error, :noproc} end
      )

    retry_entry = Map.fetch!(spawned_state.retry_attempts, "issue-spawn-errors")
    assert retry_entry.attempt == 5
    assert retry_entry.identifier == "MT-SPAWN-ERRORS"
    assert retry_entry.error =~ "failed to spawn agent: :noproc"
  end

  test "dispatch default wrappers cover claimed leases and default worker spawning" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-wrapper-dispatch-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: nil
    )

    issue = %Issue{
      id: "issue-wrapper-dispatch",
      identifier: "MT-WRAPPER-DISPATCH",
      title: "Wrapper dispatch",
      description: "cover wrapper branches",
      state: "Todo",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    missing_log =
      capture_log(fn ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

        assert %State{} =
                 Orchestrator.dispatch_issue_default_for_test(
                   %State{lease_owner: "wrapper-owner-1"},
                   issue,
                   7
                 )
      end)

    assert missing_log =~
             "Skipping dispatch; issue no longer active or visible: issue_id=issue-wrapper-dispatch issue_identifier=MT-WRAPPER-DISPATCH"

    claimed_log =
      capture_log(fn ->
        returned_state =
          Orchestrator.do_dispatch_issue_for_test(
            %State{lease_owner: "wrapper-owner-2"},
            issue,
            nil,
            acquire_fun: fn _, _, _ -> {:error, :claimed} end
          )

        assert returned_state == %State{lease_owner: "wrapper-owner-2"}
      end)

    assert claimed_log =~
             "Skipping dispatch; lease already held for issue_id=issue-wrapper-dispatch issue_identifier=MT-WRAPPER-DISPATCH"

    spawned_issue = %{issue | id: "issue-wrapper-spawn", identifier: "MT-WRAPPER-SPAWN"}

    state =
      Orchestrator.do_spawn_issue_worker_default_for_test(
        %State{lease_owner: "wrapper-owner-3"},
        spawned_issue,
        nil,
        self()
      )

    pid =
      case Map.get(state.running, spawned_issue.id) do
        %{pid: running_pid} when is_pid(running_pid) -> running_pid
        _ -> nil
      end

    assert is_pid(pid)

    on_exit(fn ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      LeaseManager.release(spawned_issue.id, "wrapper-owner-3")
      File.rm_rf(workspace_root)
    end)
  end

  test "dispatch wrapper default arities cover omitted optional arguments" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-wrapper-default-arity-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: nil
    )

    issue = %Issue{
      id: "issue-wrapper-default-arity",
      identifier: "MT-WRAPPER-DEFAULT-ARITY",
      title: "Wrapper defaults",
      description: "cover omitted optional args",
      state: "Todo",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert %State{} =
             Orchestrator.dispatch_issue_default_for_test(
               %State{lease_owner: "wrapper-owner-4", max_concurrent_agents: 1},
               issue
             )

    assert %State{} =
             Orchestrator.dispatch_issue_private_head_for_test(
               %State{lease_owner: "wrapper-owner-4b", max_concurrent_agents: 1},
               issue,
               nil
             )

    spawned_issue = %{issue | id: "issue-wrapper-default-spawn", identifier: "MT-WRAPPER-DEFAULT-SPAWN"}

    state =
      Orchestrator.do_spawn_issue_worker_for_test(
        %State{lease_owner: "wrapper-owner-5"},
        spawned_issue,
        nil,
        self()
      )

    pid =
      case Map.get(state.running, spawned_issue.id) do
        %{pid: running_pid} when is_pid(running_pid) -> running_pid
        _ -> nil
      end

    assert is_pid(pid)

    on_exit(fn ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      LeaseManager.release(issue.id, "wrapper-owner-4")
      LeaseManager.release(issue.id, "wrapper-owner-4b")
      LeaseManager.release(spawned_issue.id, "wrapper-owner-5")
      File.rm_rf(workspace_root)
    end)
  end

  test "revalidate passthrough and retry scheduling helpers cover fallback and timer cancellation branches" do
    assert {:ok, %{id: "passthrough"}} =
             Orchestrator.revalidate_issue_passthrough_for_test(%{id: "passthrough"})

    old_timer = Process.send_after(self(), :stale_retry, 10_000)

    state =
      Orchestrator.schedule_issue_retry_for_test(
        %State{
          retry_attempts: %{
            "issue-retry-cancel" => %{
              attempt: 2,
              timer_ref: old_timer,
              identifier: "MT-RETRY-CANCEL",
              error: "old error"
            }
          }
        },
        "issue-retry-cancel",
        nil,
        %{identifier: "MT-RETRY-CANCEL", error: "new error"}
      )

    retry_entry = Map.fetch!(state.retry_attempts, "issue-retry-cancel")
    assert retry_entry.attempt == 3
    assert retry_entry.identifier == "MT-RETRY-CANCEL"
    assert retry_entry.error == "new error"
    assert is_reference(retry_entry.timer_ref)
    assert retry_entry.timer_ref != old_timer
    assert Process.read_timer(old_timer) == false

    on_exit(fn ->
      Process.cancel_timer(retry_entry.timer_ref)
    end)
  end

  test "stop hold and validation error branches on operator controls return structured failures" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issues = [
      %Issue{
        id: "issue-stop-runtime",
        identifier: "MT-STOP-RUNTIME",
        title: "Stop runtime",
        description: "stop control",
        state: "In Progress",
        labels: ["ops"]
      },
      %Issue{
        id: "issue-hold-runtime",
        identifier: "MT-HOLD-RUNTIME",
        title: "Hold runtime",
        description: "hold control",
        state: "In Progress",
        labels: ["ops"]
      }
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    orchestrator_name = Module.concat(__MODULE__, :StopHoldControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    stop_payload = Orchestrator.stop_issue(orchestrator_name, "MT-STOP-RUNTIME")
    assert stop_payload.ok == true
    assert stop_payload.state == "Blocked"
    assert stop_payload.action == "stop"

    hold_payload = Orchestrator.hold_issue_for_human_review(orchestrator_name, "MT-HOLD-RUNTIME")
    assert hold_payload.ok == true
    assert hold_payload.state == "Human Review"
    assert hold_payload.action == "hold_for_human_review"

    assert %{ok: false, error: "blank issue identifier"} =
             Orchestrator.reprioritize_issue(orchestrator_name, "   ", 1)

    assert %{ok: false, error: "blank issue identifier"} =
             Orchestrator.set_policy_class(orchestrator_name, "   ", "review_required")

    assert %{ok: false, error: "invalid policy class"} =
             Orchestrator.set_policy_class(orchestrator_name, "MT-HOLD-RUNTIME", "bogus")

    assert %{ok: false, error: "blank issue identifier"} =
             Orchestrator.clear_policy_override(orchestrator_name, "   ")
  end

  test "snapshot surfaces queue fetch errors when no dispatchable issues remain" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :QueueErrorOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_candidate_issues: [],
          candidate_fetch_error: :linear_timeout
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert [%{error: ":linear_timeout"}] = snapshot.queue
  end

  defp claim_issue_lease!(issue_id, identifier, owner) do
    assert :ok = LeaseManager.acquire(issue_id, identifier, owner)

    on_exit(fn ->
      LeaseManager.release(issue_id)
    end)
  end
end
