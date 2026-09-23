defmodule SymphonyElixir.DispatchAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, RunLedger, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "dispatch-audit-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
    File.mkdir_p!(root)
    previous = Application.fetch_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "runtime.log"))

    on_exit(fn ->
      File.rm_rf!(root)

      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :log_file, value)
        :error -> Application.delete_env(:symphony_elixir, :log_file)
      end
    end)

    %{
      root: root,
      workspace: Path.join(root, "DISPATCH-1"),
      attrs: %{issue_id: "dispatch-1", issue_identifier: "DISPATCH-1", metadata: %{owner: "owner-1", epoch: 1, attempt: 1}}
    }
  end

  test "checked admission precedes workspace access and survives workspace deletion", context do
    assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    refute File.exists?(context.workspace)
    assert {:ok, entry} = RunLedger.fetch_entry_checked(ticket.entry_event_id)
    assert entry["event_type"] == "dispatch.started"
    assert entry["metadata"]["dispatch_id"] == ticket.dispatch_id
    assert entry["summary"] =~ "execution has not yet been observed"
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
    assert {:error, :dispatch_audit_not_authorized} = DispatchAudit.ensure_workspace_access(context.workspace)

    assert :worked =
             DispatchAudit.with_authorization(ticket, fn ->
               assert :ok = DispatchAudit.ensure_workspace_access(context.workspace)
               assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
               File.mkdir_p!(context.workspace)
               File.write!(Path.join(context.workspace, "fixture"), "retained")
               :worked
             end)

    File.rm_rf!(context.workspace)
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
    assert {:error, :dispatch_audit_not_authorized} = DispatchAudit.ensure_workspace_access(context.workspace)
    assert :ok = DispatchAudit.finish(ticket, :normal)
    assert :ok = DispatchAudit.ensure_available(context.workspace)
    assert Enum.map(rows(), & &1["event_type"]) == ["dispatch.requested", "dispatch.started", "dispatch.finished"]
    assert List.last(rows())["metadata"]["authorization_event_id"] == ticket.entry_event_id
  end

  test "authorization is scoped across nested tickets, exceptions and processes", context do
    assert {:ok, first} = DispatchAudit.begin(context.workspace, context.attrs)
    other = Path.join(context.root, "DISPATCH-2")
    assert {:ok, second} = DispatchAudit.begin(other, %{context.attrs | issue_id: "dispatch-2", issue_identifier: "DISPATCH-2"})

    DispatchAudit.with_authorization(first, fn ->
      assert :ok = DispatchAudit.ensure_workspace_access(context.workspace)

      DispatchAudit.with_authorization(second, fn ->
        assert :ok = DispatchAudit.ensure_workspace_access(other)
        assert {:error, :dispatch_audit_not_authorized} = DispatchAudit.ensure_workspace_access(context.workspace)
      end)

      assert :ok = DispatchAudit.ensure_workspace_access(context.workspace)
      parent = self()
      spawn(fn -> send(parent, {:child_access, DispatchAudit.ensure_workspace_access(context.workspace)}) end)
      assert_receive {:child_access, {:error, :dispatch_audit_not_authorized}}
    end)

    assert_raise ArgumentError, "controlled", fn ->
      DispatchAudit.with_authorization(first, fn -> raise ArgumentError, "controlled" end)
    end

    assert {:error, :dispatch_audit_not_authorized} = DispatchAudit.ensure_workspace_access(context.workspace)
    assert :ok = DispatchAudit.finish(first, :not_started)
    assert :ok = DispatchAudit.finish(second, :not_started)
  end

  test "canonical workspace paths share the same admission", context do
    assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    equivalent = Path.join([context.root, "unused", "..", "DISPATCH-1"])
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.begin(equivalent, context.attrs)
    assert :ok = DispatchAudit.with_authorization(ticket, fn -> DispatchAudit.ensure_workspace_access(equivalent) end)
    assert :ok = DispatchAudit.finish(ticket, :not_started)
  end

  test "concurrent begin calls create exactly one admitted dispatch", context do
    results =
      1..6
      |> Task.async_stream(fn _ -> DispatchAudit.begin(context.workspace, context.attrs) end, max_concurrency: 6, timeout: 5_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, ticket}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, {:dispatch_audit_pending, _}}, &1)) == 5
    assert Enum.map(rows(), & &1["event_type"]) == ["dispatch.requested", "dispatch.started"]
    assert :ok = DispatchAudit.finish(ticket, :not_started)
  end

  test "request persistence failure leaves an exclusive blocking directory", context do
    non_directory = Path.join(context.root, "file")
    File.write!(non_directory, "preserve")
    Application.put_env(:symphony_elixir, :log_file, Path.join(non_directory, "runtime.log"))

    assert {:error, %RunLedger.PersistenceError{phase: :mkdir}} = DispatchAudit.begin(context.workspace, context.attrs)
    assert File.dir?(DispatchAudit.marker_directory(context.workspace))
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
    assert {:error, _} = DispatchAudit.ensure_workspace_access(context.workspace)
    assert File.read!(non_directory) == "preserve"
  end

  for kind <- [:empty, :corrupt, :file, :symlink] do
    @tag marker_kind: kind
    test "an existing #{kind} marker blocks without overwriting evidence", context do
      directory = DispatchAudit.marker_directory(context.workspace)
      prepare_broken_marker(directory, context.marker_kind, context.root)
      assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.begin(context.workspace, context.attrs)
      assert {:error, _} = DispatchAudit.ensure_workspace_access(context.workspace)
      refute File.exists?(RunLedger.ledger_file_path())
      assert {:ok, _} = File.lstat(directory)
    end
  end

  test "invalid owner or epoch does not create admission artifacts", context do
    for invalid <- [%{owner: "", epoch: 1}, %{owner: "owner-1", epoch: 0}, %{owner: "owner-1", epoch: "1"}] do
      assert {:error, :invalid_dispatch_audit_attrs} = DispatchAudit.begin(context.workspace, %{context.attrs | metadata: invalid})
      assert :ok = DispatchAudit.ensure_available(context.workspace)
    end
  end

  for fault <- [:corrupt_authorization_ledger, :marker_path_directory] do
    @tag boundary_fault: fault
    test "#{fault} after the intent never grants workspace access", context do
      handler = "dispatch-audit-fault-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      assert :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.boundary_fault/4, {self(), context.boundary_fault, context.workspace})
      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, _reason} = DispatchAudit.begin(context.workspace, context.attrs)
      assert_receive {:dispatch_fault_applied, fault}
      assert fault == context.boundary_fault
      assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
      assert {:error, _} = DispatchAudit.ensure_workspace_access(context.workspace)
      refute File.exists?(context.workspace)
    end
  end

  test "wrong ticket and changed ledger cannot authorize or finish another dispatch", context do
    assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    original = File.read!(marker_path(context.workspace))
    wrong = %{ticket | dispatch_id: "other-dispatch"}
    assert {:error, :dispatch_audit_ticket_mismatch} = DispatchAudit.with_authorization(wrong, fn -> flunk("wrong ticket executed") end)
    assert {:error, :dispatch_audit_ticket_mismatch} = DispatchAudit.finish(wrong, :normal)
    assert File.read!(marker_path(context.workspace)) == original

    Application.put_env(:symphony_elixir, :log_file, Path.join(context.root, "other/runtime.log"))
    assert {:error, :dispatch_audit_ledger_changed} = DispatchAudit.with_authorization(ticket, fn -> flunk("changed ledger executed") end)
    assert {:error, :dispatch_audit_ledger_changed} = DispatchAudit.finish(ticket, :normal)
    assert File.read!(marker_path(context.workspace)) == original
  end

  test "lost or corrupt ledger evidence prevents access and finish", context do
    assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    original = File.read!(marker_path(context.workspace))
    File.write!(RunLedger.ledger_file_path(), "{corrupt")
    assert {:error, _} = DispatchAudit.with_authorization(ticket, fn -> flunk("corrupt ledger executed") end)
    assert {:error, _} = DispatchAudit.finish(ticket, :normal)
    assert File.read!(marker_path(context.workspace)) == original
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
  end

  test "snapshot mutation or removal does not retire the journal", context do
    assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    assert {:ok, _} = RunStateStore.transition(context.workspace, "implement", %{issue_id: "dispatch-1", issue_identifier: "DISPATCH-1"})
    snapshot = RunStateStore.load_or_default(context.workspace, %{id: "dispatch-1", identifier: "DISPATCH-1"})
    assert :ok = RunStateStore.save(context.workspace, snapshot)
    RunStateStore.delete(context.workspace)
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
    assert :ok = DispatchAudit.finish(ticket, :not_started)
  end

  for stage <- ["blocked", "done"] do
    @tag terminal_stage: stage
    test "begin refuses #{stage} under the snapshot lock without creating a journal", context do
      assert {:ok, _} = RunStateStore.transition(context.workspace, context.terminal_stage, %{issue_id: "dispatch-1", issue_identifier: "DISPATCH-1"})
      previous = File.read!(RunStateStore.state_path(context.workspace))
      assert {:error, {:persisted_stage_requires_explicit_resume, stage}} = DispatchAudit.begin(context.workspace, context.attrs)
      assert stage == context.terminal_stage
      assert :ok = DispatchAudit.ensure_available(context.workspace)
      assert File.read!(RunStateStore.state_path(context.workspace)) == previous
      refute Enum.any?(rows(), &(&1["event_type"] == "dispatch.started"))
    end

    @tag terminal_stage: stage
    test "authorized worker cannot bootstrap a snapshot changed to #{stage} before its gate opens", context do
      assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
      assert {:ok, _} = RunStateStore.transition(context.workspace, context.terminal_stage, %{issue_id: "dispatch-1", issue_identifier: "DISPATCH-1"})
      previous = File.read!(RunStateStore.state_path(context.workspace))

      assert {:error, {:persisted_stage_requires_explicit_resume, stage}} =
               DispatchAudit.with_authorization(ticket, fn -> DispatchAudit.ensure_workspace_access(context.workspace) end)

      assert stage == context.terminal_stage
      assert File.read!(RunStateStore.state_path(context.workspace)) == previous
      assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
      assert :ok = DispatchAudit.finish(ticket, :not_started)
    end
  end

  test "unexpected files prevent cleanup and preserve both evidence and admission", context do
    assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    evidence = Path.join(DispatchAudit.marker_directory(context.workspace), "unexpected-evidence")
    File.write!(evidence, "preserve")
    assert {:error, :dispatch_audit_unexpected_files} = DispatchAudit.finish(ticket, :normal)
    assert File.read!(evidence) == "preserve"
    refute Enum.any?(rows(), &(&1["event_type"] == "dispatch.finished"))
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
  end

  for event <- ["dispatch.requested", "dispatch.started", "dispatch.finished"] do
    @tag barrier_event: event
    test "kill after #{event} keeps admission blocked with the recorded identity", context do
      handler = "dispatch-audit-barrier-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      assert :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.barrier/4, {self(), context.barrier_event})
      on_exit(fn -> :telemetry.detach(handler) end)

      operation =
        if context.barrier_event == "dispatch.finished" do
          {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
          fn -> DispatchAudit.finish(ticket, :normal) end
        else
          fn -> DispatchAudit.begin(context.workspace, context.attrs) end
        end

      {pid, ref} = spawn_monitor(operation)
      assert_receive {:dispatch_audit_boundary, ^pid, event_id}, 5_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
      assert {:ok, row} = RunLedger.fetch_entry_checked(event_id)
      assert row["event_type"] == context.barrier_event
      assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.begin(context.workspace, context.attrs)
      assert {:error, _} = DispatchAudit.ensure_workspace_access(context.workspace)
    end
  end

  test "finishing journal cannot regenerate a second terminal event after interruption", context do
    assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    handler = "dispatch-finish-failure-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    assert :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.barrier/4, {self(), "dispatch.finished"})
    on_exit(fn -> :telemetry.detach(handler) end)
    {pid, ref} = spawn_monitor(fn -> DispatchAudit.finish(ticket, :normal) end)
    assert_receive {:dispatch_audit_boundary, ^pid, event_id}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    before = File.read!(RunLedger.ledger_file_path())
    assert {:error, :dispatch_audit_finish_uncertain} = DispatchAudit.finish(ticket, :normal)
    assert File.read!(RunLedger.ledger_file_path()) == before
    assert Jason.decode!(File.read!(marker_path(context.workspace)))["finished"]["event_id"] == event_id
    assert :ok = DispatchAudit.reconcile_finished(context.workspace)
    assert File.read!(RunLedger.ledger_file_path()) == before
    assert :ok = DispatchAudit.ensure_available(context.workspace)
    assert {:ok, next_ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    refute next_ticket.dispatch_id == ticket.dispatch_id
    :telemetry.detach(handler)
    assert :ok = DispatchAudit.finish(next_ticket, :not_started)
  end

  test "reconciliation refuses authorized dispatches and finishing evidence with a missing or altered confirmation", context do
    assert {:ok, ticket} = DispatchAudit.begin(context.workspace, context.attrs)
    assert {:error, :dispatch_audit_not_finished} = DispatchAudit.reconcile_finished(context.workspace)
    handler = "dispatch-reconcile-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    assert :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.barrier/4, {self(), "dispatch.finished"})
    on_exit(fn -> :telemetry.detach(handler) end)
    {pid, ref} = spawn_monitor(fn -> DispatchAudit.finish(ticket, :normal) end)
    assert_receive {:dispatch_audit_boundary, ^pid, event_id}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    marker_bytes = File.read!(marker_path(context.workspace))
    ledger_bytes = File.read!(RunLedger.ledger_file_path())
    retained = Enum.reject(rows(), &(&1["event_id"] == event_id))
    File.write!(RunLedger.ledger_file_path(), Enum.map_join(retained, "\n", &Jason.encode!/1) <> "\n")
    assert {:error, :not_found} = DispatchAudit.reconcile_finished(context.workspace)
    assert File.read!(marker_path(context.workspace)) == marker_bytes
    File.write!(RunLedger.ledger_file_path(), ledger_bytes)
    altered = Jason.decode!(marker_bytes) |> put_in(["finished", "summary"], "altered")
    File.write!(marker_path(context.workspace), Jason.encode!(altered))
    assert {:error, :dispatch_audit_finish_mismatch} = DispatchAudit.reconcile_finished(context.workspace)
    assert File.read!(marker_path(context.workspace)) == Jason.encode!(altered)
    File.write!(marker_path(context.workspace), marker_bytes)
    assert :ok = DispatchAudit.reconcile_finished(context.workspace)
    assert File.read!(RunLedger.ledger_file_path()) == ledger_bytes
  end

  def barrier(_event, _measurements, metadata, {parent, event}) do
    if metadata[:event_type] == event and metadata[:issue_id] == "dispatch-1" do
      send(parent, {:dispatch_audit_boundary, self(), metadata[:event_id]})

      receive do
        :continue_dispatch_audit -> :ok
      after
        5_000 -> raise "Dispatch audit barrier was not released"
      end
    end
  end

  def boundary_fault(_event, _measurements, metadata, {parent, fault, workspace}) do
    if metadata[:event_type] == "dispatch.requested" and metadata[:issue_id] == "dispatch-1" do
      case fault do
        :corrupt_authorization_ledger -> File.write!(RunLedger.ledger_file_path(), "{torn", [:append])
        :marker_path_directory -> File.mkdir!(marker_path(workspace))
      end

      send(parent, {:dispatch_fault_applied, fault})
    end
  end

  defp rows do
    RunLedger.ledger_file_path() |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp marker_path(workspace), do: Path.join(DispatchAudit.marker_directory(workspace), "marker.json")

  defp prepare_broken_marker(directory, :empty, _root), do: File.mkdir!(directory)

  defp prepare_broken_marker(directory, :corrupt, _root) do
    File.mkdir!(directory)
    File.write!(Path.join(directory, "marker.json"), "{corrupt")
  end

  defp prepare_broken_marker(directory, :file, _root), do: File.write!(directory, "preserve")

  defp prepare_broken_marker(directory, :symlink, root) do
    target = Path.join(root, "preserved-target")
    File.mkdir!(target)
    File.ln_s!(target, directory)
  end
end
