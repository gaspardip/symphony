defmodule SymphonyElixir.LeaseReleaseFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.State

  # The fixture owns this State in one real GenServer. Control continuations,
  # reader results and replies are handled by production callbacks.
  defmodule ControlDriver do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state, state}
    def handle_call(message, from, state), do: Orchestrator.handle_call(message, from, state)

    @impl true
    def handle_info(message, state), do: Orchestrator.handle_info(message, state)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "lease-release-failure-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)
    issue = %Issue{id: "lease-release-failure", identifier: "LEASE-RELEASE", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    owner = "lease-release-owner"
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, owner)
    lease = acquired.lease
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    assert {:ok, snapshot} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(lease))
    lock_path = LeaseManager.lease_path(issue.id) <> ".lock"
    File.mkdir!(lock_path)
    on_exit(fn -> File.rm_rf(root) end)

    claim = %{
      token: acquired.token,
      lease: lease,
      custody_ref: make_ref(),
      holder: :retry,
      workspace: workspace,
      issue: issue,
      started_at_ms: System.monotonic_time(:millisecond),
      deadline: :not_pending,
      promotion_ref: nil,
      timer: nil
    }

    state = %State{lease_owner: owner, claimed: MapSet.new([issue.id]), lease_claims: %{issue.id => claim}}
    %{issue: issue, workspace: workspace, owner: owner, lock_path: lock_path, lease: lease, snapshot: snapshot, state: state}
  end

  test "failed release preserves ownership and audit history until a later successful release", context do
    state = context.state
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
    assert File.read!(RunStateStore.state_path(context.workspace)) == snapshot_bytes
    assert {:ok, %{lease_version: 2}} = RunStateStore.load(context.workspace)
    assert Enum.count(RunLedger.recent_entries(100), &(&1["event_type"] == "lease.released")) == 1
  end

  test "a failed release audit removes lost custody and keeps explicit retry unsuccessful", c do
    File.rmdir!(c.lock_path)
    claim = c.state.lease_claims[c.issue.id]
    ledger = claim.token.storage.ledger_path
    original_ledger = File.read(ledger)
    if match?({:ok, _}, original_ledger), do: File.rename!(ledger, ledger <> ".before-release")
    File.mkdir!(ledger)

    on_exit(fn ->
      File.rmdir!(ledger)
      if match?({:ok, _}, original_ledger), do: File.rename!(ledger <> ".before-release", ledger)
    end)

    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [c.issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    owner = start_control_owner!(c.state)
    reply = Orchestrator.retry_issue_now(owner, c.issue.identifier)
    released = GenServer.call(owner, :runtime)
    refute reply.ok
    assert reply.error =~ "lease_release_audit_failed"
    assert {:lease_release_audit_failed, id, %RunLedger.PersistenceError{}} = released.candidate_fetch_error
    assert id == c.issue.id
    assert released.lease_claims == %{}
    refute MapSet.member?(released.claimed, c.issue.id)
    assert released.running == %{}
    assert released.retry_attempts == %{}
    assert {:error, :missing} = LeaseManager.read_at(claim.token.storage)
    assert File.dir?(ledger)
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_comment, _, _}
    assert {:error, {:lease_release_audit_failed, ^id, _}, _} = Orchestrator.prepare_retry_custody(released, id)
  end

  test "startup failure does not erase persisted ownership when lease release fails", context do
    capture_log(fn ->
      next_state =
        Orchestrator.do_spawn_issue_worker_for_test(
          context.state,
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
      retained =
        Orchestrator.release_review_follow_up_lease_for_test(
          context.state,
          context.snapshot,
          context.workspace
        )

      assert {:lease_release_failed, _, {:lease_lock_timeout, lock_path}} = retained.candidate_fetch_error
      assert lock_path == context.lock_path
      assert retained.lease_claims == context.state.lease_claims
    end)

    assert {:ok, snapshot} = RunStateStore.load(context.workspace)
    assert snapshot.lease_owner == context.owner
    assert snapshot.lease_status == "held"
  end

  defp start_control_owner!(state) do
    {:ok, owner} = GenServer.start(ControlDriver, state)

    on_exit(fn ->
      if Process.alive?(owner) do
        assert :ok = :sys.suspend(owner)
        current = :sys.get_state(owner)
        readers = Enum.reject([current.tracker_poll_read, current.admission_read], &is_nil/1)
        workers = Enum.map(current.running, fn {_id, entry} -> entry.pid end)
        monitors = Enum.map(Enum.uniq(Enum.map(readers, & &1.pid) ++ workers), &{&1, Process.monitor(&1)})

        :sys.replace_state(owner, fn runtime ->
          Enum.each(readers, fn reader -> assert :ok = SymphonyElixir.TrackerReader.cancel(reader) end)
          Enum.each(runtime.retry_attempts, fn {_id, retry} -> if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref) end)
          Enum.each(runtime.lease_claims, fn {_id, claim} -> if is_reference(claim[:timer]), do: Process.cancel_timer(claim.timer) end)
          runtime
        end)

        GenServer.stop(owner)
        Enum.each(workers, fn worker -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
        Enum.each(monitors, fn {pid, ref} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000 end)
      end
    end)

    owner
  end
end
