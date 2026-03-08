defmodule SymphonyElixir.OrchestratorTotalPhase6BackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunStateStore

  test "activity timestamp helpers prefer codex updates and fall back to started_at" do
    started_at = DateTime.add(DateTime.utc_now(), -2, :second)
    last_codex_timestamp = DateTime.add(started_at, 1, :second)

    assert Orchestrator.last_activity_timestamp_for_test(%{
             started_at: started_at,
             last_codex_timestamp: last_codex_timestamp
           }) == last_codex_timestamp

    assert Orchestrator.stall_elapsed_ms_for_test(
             %{started_at: started_at, last_codex_timestamp: last_codex_timestamp},
             DateTime.add(last_codex_timestamp, 750, :millisecond)
           ) == 750

    assert Orchestrator.last_activity_timestamp_for_test(%{started_at: started_at}) == started_at

    assert Orchestrator.stall_elapsed_ms_for_test(
             %{started_at: started_at},
             DateTime.add(started_at, -100, :millisecond)
           ) == 0
  end

  test "reconcile_stalled_running_issues_for_test restarts stale entries using started_at fallback" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000
    )

    issue = %Issue{
      id: "issue-stall-fallback",
      identifier: "MT-STALL-FALLBACK",
      title: "Restart me",
      state: "In Progress"
    }

    worker_pid = spawn(fn -> Process.sleep(:infinity) end)
    worker_monitor = Process.monitor(worker_pid)
    lease_owner = "orchestrator-test-stall"
    claim_issue_lease!(issue.id, issue.identifier, lease_owner)

    state = %State{
      lease_owner: lease_owner,
      max_concurrent_agents: 1,
      codex_totals: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: 0
      },
      running: %{
        issue.id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          started_at: DateTime.add(DateTime.utc_now(), -5, :second)
        }
      },
      claimed: MapSet.new([issue.id])
    }

    updated_state = Orchestrator.reconcile_stalled_running_issues_for_test(state)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, :shutdown}, 1_000
    refute Map.has_key?(updated_state.running, issue.id)
    refute MapSet.member?(updated_state.claimed, issue.id)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-STALL-FALLBACK",
             error: "stalled for " <> _
           } = updated_state.retry_attempts[issue.id]

    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)
    assert remaining_ms >= 9_000
    assert remaining_ms <= 11_000
  end

  test "skipped_issue_entry_for_test enriches persisted override metadata" do
    workspace_root = unique_workspace_root!("skipped-entry")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{
      id: "issue-skipped-enriched",
      identifier: "MT-SKIPPED-ENRICHED",
      title: "Needs metadata",
      state: "Todo",
      labels: ["policy:review-required"]
    }

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(workspace)

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn run_state ->
               Map.merge(run_state, %{
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 policy_override: "never_automerge",
                 next_human_action: "Open the dashboard and review the policy override.",
                 last_rule_id: "policy.review_required",
                 last_failure_class: "policy",
                 last_decision_summary: "Review is required before merge.",
                 last_ledger_event_id: "evt-skipped-entry"
               })
             end)

    entry =
      Orchestrator.skipped_issue_entry_for_test(
        issue,
        "missing required labels",
        %State{}
      )

    assert entry.policy_class == "never_automerge"
    assert entry.policy_source == "override"
    assert entry.policy_override == "never_automerge"
    assert entry.next_human_action == "Open the dashboard and review the policy override."
    assert entry.last_rule_id == "policy.review_required"
    assert entry.last_failure_class == "policy"
    assert entry.last_decision_summary == "Review is required before merge."
    assert entry.last_ledger_event_id == "evt-skipped-entry"
  end

  test "skipped_issue_entry_for_test falls back to the policy-conflict human action" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-skipped-conflict",
      identifier: "MT-SKIPPED-CONFLICT",
      title: "Conflicting policy labels",
      state: "Todo",
      labels: ["policy:review-required", "policy:never-automerge"]
    }

    entry =
      Orchestrator.skipped_issue_entry_for_test(
        issue,
        RuleCatalog.rule_id(:policy_invalid_labels),
        %State{}
      )

    assert entry.reason == RuleCatalog.rule_id(:policy_invalid_labels)
    assert entry.next_human_action == RuleCatalog.human_action(:policy_invalid_labels)
    assert entry.policy_class == nil
    assert entry.policy_source == nil
    assert entry.policy_override == nil
  end

  test "snapshot retry entries include persisted retry metadata" do
    workspace_root = unique_workspace_root!("retry-snapshot")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue_identifier = "MT-RETRY-SNAPSHOT"
    workspace = Path.join(workspace_root, issue_identifier)
    File.mkdir_p!(workspace)

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn run_state ->
               Map.merge(run_state, %{
                 issue_identifier: issue_identifier,
                 effective_policy_class: "review_required",
                 effective_policy_source: "override",
                 policy_override: "review_required",
                 next_human_action: "Resume the issue after manual approval.",
                 last_rule_id: "policy.review_required",
                 last_failure_class: "policy",
                 last_decision_summary: "Manual approval is still required.",
                 last_ledger_event_id: "evt-retry-snapshot"
               })
             end)

    orchestrator_name = Module.concat(__MODULE__, :RetrySnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | retry_attempts: %{
            "issue-retry-snapshot" => %{
              attempt: 3,
              timer_ref: nil,
              due_at_ms: now_ms + 3_000,
              identifier: issue_identifier,
              error: "agent exited: :boom"
            }
          }
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

    assert [
             %{
               issue_id: "issue-retry-snapshot",
               attempt: 3,
               due_in_ms: due_in_ms,
               identifier: "MT-RETRY-SNAPSHOT",
               error: "agent exited: :boom",
               policy_class: "review_required",
               policy_source: "override",
               policy_override: "review_required",
               next_human_action: "Resume the issue after manual approval.",
               last_rule_id: "policy.review_required",
               last_failure_class: "policy",
               last_decision_summary: "Manual approval is still required.",
               last_ledger_event_id: "evt-retry-snapshot"
             }
           ] = snapshot.retrying

    assert due_in_ms >= 0
    assert due_in_ms <= 3_000
  end

  test "snapshot queue filters paused and running issues while surfacing policy queue reasons" do
    workspace_root = unique_workspace_root!("queue-snapshot")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    queued_issue = %Issue{
      id: "issue-queue-review",
      identifier: "MT-QUEUE-REVIEW",
      title: "Queue for human review",
      description: "queue me",
      priority: 2,
      state: "Todo",
      labels: ["policy:review-required"]
    }

    paused_issue = %Issue{
      id: "issue-queue-paused",
      identifier: "MT-QUEUE-PAUSED",
      title: "Paused queue issue",
      description: "pause me",
      priority: 1,
      state: "Todo",
      labels: []
    }

    running_issue = %Issue{
      id: "issue-queue-running",
      identifier: "MT-QUEUE-RUNNING",
      title: "Running queue issue",
      description: "already running",
      priority: 0,
      state: "Todo",
      labels: []
    }

    orchestrator_name = Module.concat(__MODULE__, :QueueSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)
    claim_issue_lease!(running_issue.id, running_issue.identifier, initial_state.lease_owner)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_candidate_issues: [paused_issue, running_issue, queued_issue],
          paused_issue_states: %{
            paused_issue.id => %{
              identifier: paused_issue.identifier,
              resume_state: "Todo"
            }
          },
          running: %{
            running_issue.id => %{
              pid: worker_pid,
              ref: make_ref(),
              identifier: running_issue.identifier,
              issue: running_issue,
              session_id: nil,
              codex_app_server_pid: nil,
              codex_input_tokens: 0,
              codex_output_tokens: 0,
              codex_total_tokens: 0,
              last_codex_timestamp: nil,
              last_codex_message: nil,
              last_codex_event: nil,
              started_at: DateTime.utc_now()
            }
          }
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

    assert [
             %{
               issue_identifier: "MT-QUEUE-REVIEW",
               policy_class: "review_required",
               policy_source: "label",
               policy_override: nil,
               label_gate_eligible: true,
               last_rule_id: review_required_rule_id,
               last_failure_class: review_required_failure_class,
               last_decision_summary: "Policy requires human review before merge.",
               next_human_action: review_required_human_action
             }
           ] = snapshot.queue

    assert review_required_rule_id == RuleCatalog.rule_id(:policy_review_required)

    assert review_required_failure_class ==
             RuleCatalog.failure_class(:policy_review_required)

    assert review_required_human_action ==
             RuleCatalog.human_action(:policy_review_required)
  end

  test "public control wrappers return unavailable when the orchestrator server is missing" do
    missing_server = Module.concat(__MODULE__, :MissingOrchestrator)

    assert Orchestrator.request_refresh(missing_server) == :unavailable
    assert Orchestrator.pause_issue(missing_server, "MT-MISSING") == :unavailable
    assert Orchestrator.resume_issue(missing_server, "MT-MISSING") == :unavailable
    assert Orchestrator.stop_issue(missing_server, "MT-MISSING") == :unavailable
    assert Orchestrator.hold_issue_for_human_review(missing_server, "MT-MISSING") == :unavailable
    assert Orchestrator.retry_issue_now(missing_server, "MT-MISSING") == :unavailable
    assert Orchestrator.reprioritize_issue(missing_server, "MT-MISSING", 1) == :unavailable
    assert Orchestrator.approve_issue_for_merge(missing_server, "MT-MISSING") == :unavailable
    assert Orchestrator.set_policy_class(missing_server, "MT-MISSING", "review_required") == :unavailable
    assert Orchestrator.clear_policy_override(missing_server, "MT-MISSING") == :unavailable
  end

  defp claim_issue_lease!(issue_id, identifier, owner) do
    assert :ok = LeaseManager.acquire(issue_id, identifier, owner)

    on_exit(fn ->
      LeaseManager.release(issue_id)
    end)
  end

  defp unique_workspace_root!(suffix) do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-phase6-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    workspace_root
  end
end
