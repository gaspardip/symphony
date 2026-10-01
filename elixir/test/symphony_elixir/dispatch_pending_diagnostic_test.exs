defmodule SymphonyElixir.DispatchPendingDiagnosticTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, LeaseManager, RunIdentity, RunLedger, RunStateStore, SecretRedactor}
  alias SymphonyElixirWeb.Presenter

  setup do
    root = Path.join(System.tmp_dir!(), "dispatch-pending-diagnostic-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for suffix <- ["plain", "token=diagnostic-path-sentinel"] do
    @tag workspace_suffix: suffix
    test "public poll exposes the authentic pending cause only on its issue (#{suffix})", context do
      configure!(Path.join(context.root, context.workspace_suffix))
      issue = issue("pending-a", "PENDING-A")
      other = %{issue("queued-b", "QUEUED-B") | state: "Todo", blocked_by: [%{state: "In Progress"}]}
      pending = begin_pending!(issue)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, other])
      owner = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, Owner)})
      send(owner, :run_poll_cycle)

      snapshot =
        await_snapshot!(owner, fn snapshot ->
          Enum.any?(snapshot.queue, &(&1.issue_id == issue.id and is_binary(Map.get(&1, :error))))
        end)

      expected = {:dispatch_audit_pending, pending.workspace} |> inspect() |> SecretRedactor.redact()
      rows = Map.new(snapshot.queue, &{&1.issue_id, &1})
      assert map_size(rows) == 2
      assert rows[issue.id].issue_identifier == issue.identifier
      assert rows[issue.id].error == expected
      refute Map.has_key?(rows[other.id], :error)
      assert snapshot.running == []
      assert snapshot.retrying == []

      api = Presenter.state_payload(owner, 5_000)
      refute Map.has_key?(api, :error)
      api_rows = Map.new(api.queue, &{&1.issue_id, &1})
      assert api_rows[issue.id].error == expected
      assert api_rows[other.id].error == nil
      assert {:ok, detail} = Presenter.issue_payload(issue.identifier, owner, 5_000)
      assert detail.issue_id == issue.id
      assert detail.issue_identifier == issue.identifier
      assert detail.workspace.path == pending.workspace
      assert detail.queue.error == expected
      refute expected =~ "diagnostic-path-sentinel"
      refute expected =~ "private-owner-sentinel"
      assert_preserved!(pending, issue, snapshot)
      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, _, _}
    end
  end

  test "a real pending workspace shared by two candidate identities is not attributed to either", context do
    configure!(context.root)
    issue = issue("pending-a", "COLLISION/A")
    other = issue("pending-b", "COLLISION_A")
    assert Workspace.path_for_issue(issue) == Workspace.path_for_issue(other)
    pending = begin_pending!(issue)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, other])

    log =
      capture_log(fn ->
        owner = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, Owner)})
        send(owner, :run_poll_cycle)
        snapshot = await_snapshot!(owner, &(length(&1.queue) == 2))
        assert Enum.sort(Enum.map(snapshot.queue, & &1.issue_id)) == Enum.sort([issue.id, other.id])
        assert Enum.all?(snapshot.queue, &(not Map.has_key?(&1, :error)))
        api = Presenter.state_payload(owner, 5_000)
        refute Map.has_key?(api, :error)
        assert length(api.queue) == 2
        assert Enum.all?(api.queue, &is_nil(&1.error))
        assert_preserved!(pending, issue, snapshot)
      end)

    assert log =~ "Dispatch blocked by runtime validation issue_identifier=#{issue.identifier}"
    assert log =~ "Dispatch blocked by runtime validation issue_identifier=#{other.identifier}"
    assert log =~ "dispatch_audit_pending"
  end

  defp configure!(root) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: [],
      manual_enabled: false,
      workspace_root: Path.join(root, "workspaces"),
      runner_install_root: Path.join(root, "runner"),
      max_concurrent_agents: 1,
      poll_interval_ms: 600_000,
      discovery_poll_interval_ms: 600_000,
      healing_poll_interval_ms: 1_800_000,
      codex_command: "printf invoked > .symphony/provider-invoked; exit 99",
      hook_before_run: "printf invoked > .symphony/hook-invoked; exit 27"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
  end

  defp issue(id, identifier),
    do: %Issue{id: id, identifier: identifier, title: "Pending dispatch diagnosis", state: "In Progress", source: :tracker, labels: []}

  defp begin_pending!(issue) do
    workspace = Workspace.path_for_issue(issue)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    assert {:ok, source, _view} = RunStateStore.read_admission_source(workspace, issue)

    # A genuine checked admission with no child created. Its pending journal is
    # the recovery input; the new owner must neither replay nor finish it.
    assert {:ok, ticket, _raw} =
             DispatchAudit.begin(
               workspace,
               %{
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 stage: "implement",
                 metadata: %{owner: "private-owner-sentinel", epoch: 1, attempt: 1}
               },
               source
             )

    assert {:error, {:dispatch_audit_pending, ^workspace}} = DispatchAudit.ensure_available(workspace)
    assert {:error, :missing} = LeaseManager.read(issue.id)
    marker = Path.join(DispatchAudit.marker_directory(workspace), "marker.json")
    assert {:ok, authorization} = RunLedger.fetch_entry_checked(ticket.entry_event_id)
    assert authorization["issue_id"] == issue.id
    assert authorization["metadata"]["run_id"] == ticket.run_id
    assert authorization["metadata"]["workspace"] == SecretRedactor.redact(workspace)
    assert authorization["metadata"]["workspace_digest"] == Base.encode16(:crypto.hash(:sha256, workspace), case: :lower)
    assert :ok = RunIdentity.verify(workspace, ticket.run_id, issue.id, issue.identifier)

    assert :ok =
             DispatchAudit.with_authorization(ticket, fn ->
               assert {:ok, ^ticket} = DispatchAudit.current_ticket()
               DispatchAudit.ensure_workspace_access(workspace)
             end)

    %{
      workspace: workspace,
      ticket: ticket,
      marker: marker,
      marker_bytes: File.read!(marker),
      state_bytes: File.read!(RunStateStore.state_path(workspace)),
      authorization: authorization,
      workers: MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor))
    }
  end

  defp assert_preserved!(pending, issue, snapshot) do
    assert snapshot.running == []
    assert snapshot.retrying == []
    assert File.read!(pending.marker) == pending.marker_bytes
    assert File.read!(RunStateStore.state_path(pending.workspace)) == pending.state_bytes
    assert {:ok, authorization} = RunLedger.fetch_entry_checked(pending.ticket.entry_event_id)
    assert authorization == pending.authorization
    assert {:error, {:dispatch_audit_pending, workspace}} = DispatchAudit.ensure_available(pending.workspace)
    assert workspace == pending.workspace
    assert {:error, :missing} = LeaseManager.read(issue.id)
    assert MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor)) == pending.workers
    refute File.exists?(Path.join(pending.workspace, ".symphony/provider-invoked"))
    refute File.exists?(Path.join(pending.workspace, ".symphony/hook-invoked"))

    events = RunLedger.ledger_file_path() |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    dispatch = Enum.filter(events, &(&1["issue_id"] == issue.id and &1["event_type"] in ["dispatch.started", "dispatch.finished"]))
    assert Enum.map(dispatch, & &1["event_id"]) == [pending.ticket.entry_event_id]
  end

  defp await_snapshot!(owner, predicate),
    do: await_snapshot!(owner, predicate, System.monotonic_time(:millisecond) + 5_000)

  defp await_snapshot!(owner, predicate, deadline) do
    snapshot = Orchestrator.snapshot(owner, 5_000)
    assert is_map(snapshot)

    if snapshot.polling.checking? == false and predicate.(snapshot) do
      snapshot
    else
      assert System.monotonic_time(:millisecond) < deadline, "public poll did not reach the required observation"
      Process.sleep(10)
      await_snapshot!(owner, predicate, deadline)
    end
  end
end
