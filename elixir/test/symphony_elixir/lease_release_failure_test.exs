defmodule SymphonyElixir.LeaseReleaseFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.State

  setup do
    root = Path.join(System.tmp_dir!(), "lease-release-failure-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)
    issue = %Issue{id: "lease-release-failure", identifier: "LEASE-RELEASE", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    owner = "lease-release-owner"
    assert :ok = LeaseManager.acquire(issue.id, issue.identifier, owner)
    assert {:ok, lease} = LeaseManager.read(issue.id)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    assert {:ok, snapshot} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(lease))
    lock_path = LeaseManager.lease_path(issue.id) <> ".lock"
    File.mkdir!(lock_path)
    on_exit(fn -> File.rm_rf(root) end)
    %{issue: issue, workspace: workspace, owner: owner, lock_path: lock_path, lease: lease, snapshot: snapshot}
  end

  test "failed release preserves ownership and audit history until a later successful release", context do
    state = %State{lease_owner: context.owner, claimed: MapSet.new([context.issue.id])}
    snapshot_bytes = File.read!(RunStateStore.state_path(context.workspace))

    log =
      capture_log(fn ->
        next_state = Orchestrator.terminate_running_issue(state, context.issue.id, false)
        send(self(), {:release_state, next_state})
      end)

    assert_received {:release_state, blocked}
    assert {:lease_release_failed, issue_id, {:lease_lock_timeout, lock_path}} = blocked.candidate_fetch_error
    assert issue_id == context.issue.id
    assert lock_path == context.lock_path
    assert MapSet.member?(blocked.claimed, context.issue.id)
    assert log =~ "Lease release failed"
    assert log =~ "lease_lock_timeout"
    assert File.read!(RunStateStore.state_path(context.workspace)) == snapshot_bytes
    assert {:ok, lease} = LeaseManager.read(context.issue.id)
    assert lease == context.lease
    assert File.dir?(context.lock_path)
    refute Enum.any?(RunLedger.recent_entries(100), &(&1["event_type"] == "lease.released"))

    # Remove only this test's foreign lock to represent an explicit, completed recovery.
    File.rmdir!(context.lock_path)
    released = Orchestrator.terminate_running_issue(blocked, context.issue.id, false)
    refute MapSet.member?(released.claimed, context.issue.id)
    assert released.candidate_fetch_error == nil
    assert {:error, :missing} = LeaseManager.read(context.issue.id)
    assert {:ok, %{lease_owner: nil, lease_status: nil}} = RunStateStore.load(context.workspace)
    assert Enum.count(RunLedger.recent_entries(100), &(&1["event_type"] == "lease.released")) == 1
  end

  test "startup failure does not erase persisted ownership when lease release fails", context do
    capture_log(fn ->
      next_state =
        Orchestrator.do_spawn_issue_worker_for_test(
          %State{lease_owner: context.owner},
          context.issue,
          1,
          self(),
          start_child_fun: fn _supervisor, _fun -> {:error, :noproc} end
        )

      retry = Map.fetch!(next_state.retry_attempts, context.issue.id)
      Process.cancel_timer(retry.timer_ref)
      assert retry.error =~ "failed to spawn agent"
    end)

    assert {:ok, %{lease_owner: owner, lease_status: "held"}} = RunStateStore.load(context.workspace)
    assert owner == context.owner
    assert {:ok, lease} = LeaseManager.read(context.issue.id)
    assert lease == context.lease
    refute Enum.any?(RunLedger.recent_entries(100), &(&1["event_type"] == "lease.released"))
  end

  test "review follow-up release returns the lock error and preserves its snapshot", context do
    capture_log(fn ->
      assert {:error, {:lease_lock_timeout, lock_path}} =
               Orchestrator.release_review_follow_up_lease_for_test(
                 %State{lease_owner: context.owner},
                 context.snapshot,
                 context.workspace
               )

      assert lock_path == context.lock_path
    end)

    assert {:ok, snapshot} = RunStateStore.load(context.workspace)
    assert snapshot.lease_owner == context.owner
    assert snapshot.lease_status == "held"
  end
end
