defmodule SymphonyElixir.LeaseRefreshLateDownTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, DispatchGate, LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.State

  setup do
    root = Path.join(System.tmp_dir!(), "lease-late-down-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)

    issue = %Issue{
      id: "lease-refresh-#{System.unique_integer([:positive])}",
      identifier: "LEASE-REFRESH-1",
      title: "Local ownership audit",
      state: "In Progress",
      source: :tracker
    }

    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "keep.txt"), "preserve this workspace")
    lease_owner = "lease-refresh-owner-#{System.unique_integer([:positive])}"
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, lease_owner)
    lease = acquired.lease
    custody_ref = make_ref()

    claim = %{
      token: acquired.token,
      lease: acquired.lease,
      custody_ref: custody_ref,
      holder: :running,
      workspace: workspace,
      issue: issue,
      started_at_ms: System.monotonic_time(:millisecond),
      deadline: :not_pending,
      promotion_ref: nil,
      timer: nil
    }

    assert {:ok, _snapshot} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    assert {:ok, _snapshot} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(lease))

    assert {:ok, ticket} =
             DispatchAudit.begin(workspace, %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               metadata: %{owner: lease_owner, epoch: lease["epoch"]}
             })

    owner = self()

    worker =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        DispatchGate.run(owner, ticket.dispatch_id, fn ->
          DispatchAudit.with_authorization(ticket, fn ->
            send(owner, {:body_entered, self()})

            await_finish(owner, false)
          end)
        end)
      end)

    assert :ok = DispatchGate.activate(worker, ticket.dispatch_id)
    assert_receive {:body_entered, ^worker}, 5_000

    monitor = Process.monitor(worker)
    retry_ref = make_ref()
    timer = Process.send_after(self(), {:retry_issue, issue.id, retry_ref}, 60_000)

    running = %{
      custody_ref: custody_ref,
      lease_token: acquired.token,
      pid: worker,
      ref: monitor,
      issue: issue,
      identifier: issue.identifier,
      workspace: workspace,
      workspace_path: workspace,
      dispatch_ticket: ticket,
      started_at: DateTime.utc_now()
    }

    state = %State{
      lease_owner: lease_owner,
      lease_claims: %{issue.id => claim},
      running: %{issue.id => running},
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{issue.id => %{retry_ref: retry_ref, status: :scheduled, due_at_ms: System.monotonic_time(:millisecond) + 60_000, timer_ref: timer, identifier: issue.identifier, attempt: 1}},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
    }

    lease_path = LeaseManager.lease_path(issue.id)
    marker_path = Path.join(DispatchAudit.marker_directory(workspace), "marker.json")
    ledger_path = RunLedger.ledger_file_path()
    snapshot_path = RunStateStore.state_path(workspace)

    on_exit(fn ->
      Process.cancel_timer(timer)
      ref = Process.monitor(worker)
      if Process.alive?(worker), do: Process.exit(worker, :kill)

      receive do
        {:DOWN, ^ref, :process, ^worker, _reason} -> :ok
      after
        1_000 -> raise "owned test worker did not stop"
      end

      File.rm_rf!(lease_path)
      File.rm_rf!(lease_path <> ".lock")
      File.rm_rf!(lease_path <> ".healthy")
      File.rm_rf!(root)
    end)

    %{
      issue: issue,
      workspace: workspace,
      worker: worker,
      monitor: monitor,
      timer: timer,
      state: state,
      lease: lease,
      lease_path: lease_path,
      marker_path: marker_path,
      marker_before: File.read!(marker_path),
      ledger_path: ledger_path,
      ledger_before: File.read!(ledger_path),
      snapshot_path: snapshot_path,
      snapshot_before: File.read!(snapshot_path)
    }
  end

  test "late DOWN after an unconfirmed stop preserves the uncertain dispatch", c do
    {blocked, pending_bytes, reason} = timeout_on_uncertain_lease(c)
    send(c.worker, :finish)
    assert_receive {:DOWN, ref, :process, worker, :normal} = down, 5_000
    assert ref == c.monitor
    assert worker == c.worker

    assert {:noreply, stopped} = Orchestrator.handle_info(down, blocked)
    assert_preserved(c, stopped, pending_bytes, reason)
    assert stopped.running == %{}
  end

  test "healthy refresh and repeated explicit stop cannot clear prior ownership uncertainty", c do
    {blocked, _pending_bytes, reason} = timeout_on_uncertain_lease(c)

    # Simulate an explicit repair of the lease bytes. This does not authorize
    # the old execution or resolve the independent dispatch journal.
    healthy_bytes = Jason.encode!(c.lease)
    File.write!(c.lease_path, healthy_bytes)
    refreshed = Orchestrator.refresh_runtime_config(blocked)
    assert Process.alive?(c.worker)
    assert File.read!(c.lease_path) == healthy_bytes
    assert File.read!(c.snapshot_path) == c.snapshot_before

    assert {:lease_ownership_uncertain, id, ^reason, :worker_termination_unconfirmed} =
             refreshed.candidate_fetch_error

    assert id == c.issue.id

    # A barrier lets the same unsupervised worker accept the next shutdown.
    send(c.worker, :accept_shutdown)
    assert_receive {:accepting_shutdown, worker}, 5_000
    assert worker == c.worker
    stopped = Orchestrator.terminate_running_issue(refreshed, c.issue.id, true)
    refute Process.alive?(c.worker)
    assert_preserved(c, stopped, healthy_bytes, reason)
    assert stopped.running == %{}
  end

  defp timeout_on_uncertain_lease(c) do
    pending = Jason.encode!(Map.put(c.lease, "audit_pending", %{"operation_id" => "lease_op_late_down"}))
    File.write!(c.lease_path, pending)
    reason = {:lease_audit_pending, "lease_op_late_down"}
    blocked = Orchestrator.refresh_runtime_config(c.state)
    assert_receive {:shutdown_ignored, worker}, 5_000
    assert worker == c.worker
    assert Process.alive?(worker)
    assert blocked.running[c.issue.id].pid == c.worker

    assert {:lease_ownership_uncertain, id, ^reason, :worker_termination_unconfirmed} =
             blocked.candidate_fetch_error

    assert id == c.issue.id
    assert blocked.retry_attempts == %{}
    assert Process.read_timer(c.timer) == false
    assert File.read!(c.marker_path) == c.marker_before
    assert File.read!(c.ledger_path) == c.ledger_before
    {blocked, pending, reason}
  end

  defp assert_preserved(c, stopped, lease_bytes, reason) do
    assert File.read!(c.ledger_path) == c.ledger_before
    assert File.read!(c.marker_path) == c.marker_before
    assert File.read!(c.snapshot_path) == c.snapshot_before
    assert File.read!(c.lease_path) == lease_bytes
    assert File.read!(Path.join(c.workspace, "keep.txt")) == "preserve this workspace"
    assert stopped.claimed == c.state.claimed
    assert stopped.retry_attempts == %{}
    assert stopped.completed == %{}
    assert {:lease_ownership_uncertain, id, ^reason} = stopped.candidate_fetch_error
    assert id == c.issue.id
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(c.workspace)
  end

  defp await_finish(owner, accept_shutdown?) do
    receive do
      {:EXIT, _sender, :shutdown} when accept_shutdown? ->
        :ok

      {:EXIT, _sender, :shutdown} ->
        send(owner, {:shutdown_ignored, self()})
        await_finish(owner, false)

      :accept_shutdown ->
        send(owner, {:accepting_shutdown, self()})
        await_finish(owner, true)

      :finish ->
        :ok
    end
  end
end
