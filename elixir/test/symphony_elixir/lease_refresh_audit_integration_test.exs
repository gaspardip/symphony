defmodule SymphonyElixir.LeaseRefreshAuditIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, DispatchGate, LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.State

  setup do
    root = Path.join(System.tmp_dir!(), "lease-refresh-audit-#{System.unique_integer([:positive])}")
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

    assert {:ok, worker} =
             Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               DispatchGate.run(owner, ticket.dispatch_id, fn ->
                 DispatchAudit.with_authorization(ticket, fn ->
                   send(owner, {:body_entered, self()})

                   receive do
                     :finish -> :ok
                   end
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
        5_000 -> raise "owned test worker did not stop"
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

  for fault <- [:pending, :malformed_pending, :invalid_json, :non_map] do
    @tag lease_fault: fault
    test "#{fault} stops a real worker and preserves uncertain ownership without retry", c do
      payload = fault_payload(c.lease, c.lease_fault)
      File.write!(c.lease_path, payload)
      assert {:error, reason} = LeaseManager.refresh_token(c.state.lease_claims[c.issue.id].token)
      assert_fault_reason(c.lease_fault, reason)
      watch = Process.monitor(c.worker)

      stopped = Orchestrator.refresh_runtime_config(c.state)

      assert_receive {:DOWN, ^watch, :process, worker, _reason}, 5_000
      assert worker == c.worker
      refute Process.alive?(worker)
      assert stopped.running == %{}
      assert stopped.retry_attempts == %{}
      assert Process.read_timer(c.timer) == false
      assert stopped.completed == %{}
      assert stopped.claimed == c.state.claimed
      assert {:lease_ownership_uncertain, id, ^reason} = stopped.candidate_fetch_error
      assert id == c.issue.id
      assert File.read!(c.lease_path) == payload
      assert File.read!(c.marker_path) == c.marker_before
      assert File.read!(c.ledger_path) == c.ledger_before
      assert File.read!(c.snapshot_path) == c.snapshot_before
      assert File.read!(Path.join(c.workspace, "keep.txt")) == "preserve this workspace"
      assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(c.workspace)

      # A late original monitor message must not finish the journal or retry.
      assert {:noreply, ^stopped} =
               Orchestrator.handle_info(
                 {:DOWN, c.monitor, :process, c.worker, :normal},
                 stopped
               )

      blocked = Orchestrator.dispatch_runtime_issue(stopped, c.issue, nil)
      assert blocked.running == %{}
      assert blocked.retry_attempts == %{}
      assert File.read!(c.marker_path) == c.marker_before
      assert File.read!(c.lease_path) == payload
    end
  end

  test "healthy renewal keeps the same worker and synchronizes its lease", c do
    refreshed = Orchestrator.refresh_runtime_config(c.state)
    assert Process.alive?(c.worker)
    assert refreshed.running[c.issue.id].pid == c.worker
    assert refreshed.claimed == c.state.claimed
    assert refreshed.retry_attempts == c.state.retry_attempts
    assert refreshed.candidate_fetch_error == nil
    assert {:ok, lease} = LeaseManager.read(c.issue.id)
    assert lease["owner"] == c.state.lease_owner
    assert lease["epoch"] == c.lease["epoch"]
    assert {:ok, snapshot} = RunStateStore.load(c.workspace)
    assert snapshot.lease_updated_at == lease["updated_at"]
    assert File.read!(c.marker_path) == c.marker_before
  end

  test "filesystem refresh errors block the worker and preserve uncertain audit evidence", c do
    File.rename!(c.lease_path, c.lease_path <> ".healthy")
    File.mkdir!(c.lease_path)
    assert {:error, :eisdir} = LeaseManager.refresh_token(c.state.lease_claims[c.issue.id].token)
    watch = Process.monitor(c.worker)
    refreshed = Orchestrator.refresh_runtime_config(c.state)
    assert_receive {:DOWN, ^watch, :process, _, _}, 5_000
    refute Process.alive?(c.worker)
    assert refreshed.running == %{}
    assert refreshed.claimed == c.state.claimed
    assert refreshed.retry_attempts == %{}
    assert Process.read_timer(c.timer) == false
    assert refreshed.candidate_fetch_error == {:lease_ownership_uncertain, c.issue.id, :eisdir}
    assert File.dir?(c.lease_path)
    assert File.read!(c.marker_path) == c.marker_before
    assert File.read!(c.snapshot_path) == c.snapshot_before
  end

  defp fault_payload(lease, :pending),
    do: Jason.encode!(Map.put(lease, "audit_pending", %{"operation_id" => "lease_op_test_pending"}))

  defp fault_payload(lease, :malformed_pending), do: Jason.encode!(Map.put(lease, "audit_pending", []))
  defp fault_payload(_lease, :invalid_json), do: "{corrupt lease JSON"
  defp fault_payload(_lease, :non_map), do: "[]"

  defp assert_fault_reason(:pending, reason), do: assert(reason == {:lease_audit_pending, "lease_op_test_pending"})
  defp assert_fault_reason(:malformed_pending, reason), do: assert(reason == :invalid_lease_audit_pending)
  defp assert_fault_reason(:invalid_json, reason), do: assert(match?(%Jason.DecodeError{}, reason))
  defp assert_fault_reason(:non_map, reason), do: assert(reason == :invalid_lease)
end
