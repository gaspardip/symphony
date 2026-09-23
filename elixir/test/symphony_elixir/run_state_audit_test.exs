defmodule SymphonyElixir.RunStateAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RunLedger, RunStateStore, Workspace}

  setup do
    root = Path.join(System.tmp_dir!(), "run-state-audit-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "AUDIT-1")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace}
  end

  test "an unrecorded transition returns an error and preserves the previous snapshot", context do
    assert {:ok, _} = RunStateStore.transition(context.workspace, "implement", %{issue_id: "audit-1", issue_identifier: "AUDIT-1"})
    previous = File.read!(RunStateStore.state_path(context.workspace))
    non_directory = Path.join(context.root, "not-a-directory")
    File.write!(non_directory, "fixture")
    Application.put_env(:symphony_elixir, :log_file, Path.join(non_directory, "runtime.log"))

    assert {:error, _} = RunStateStore.transition(context.workspace, "verify")
    assert File.read!(RunStateStore.state_path(context.workspace)) == previous
    assert {:ok, state} = RunStateStore.load(context.workspace)
    assert state.stage == "implement"
    assert state.stage_transition_counts == %{"implement" => 1}
  end

  test "stale transition attributes cannot reduce accumulated token usage", context do
    issue = %{id: "audit-1", identifier: "AUDIT-1"}
    assert {:ok, _} = RunStateStore.transition(context.workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    usage = %{input_tokens: 300, output_tokens: 200, total_tokens: 500}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, issue, usage)
    assert {:ok, state} = RunStateStore.transition(context.workspace, "verify", %{token_usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}})
    assert state.token_usage == usage
    assert {:ok, persisted} = RunStateStore.load(context.workspace)
    assert persisted.token_usage == usage
  end

  test "an interrupted confirmation blocks reads, mutations and workspace cleanup until explicit reconciliation", context do
    %{before: before_state, final: final_state, pending: pending} = interrupted_confirmation(context)
    original = File.read!(RunStateStore.state_path(context.workspace))
    ledger = File.read!(RunLedger.ledger_file_path())

    assert {:error, {:audit_pending, operation_id}} = RunStateStore.load(context.workspace)
    assert operation_id == pending["operation_id"]
    assert {:error, _} = RunStateStore.ensure_readable(context.workspace)
    assert RunStateStore.load_or_default(context.workspace, %{id: "audit-1"}).last_rule_id == "runtime.audit_pending"
    assert {:error, _} = RunStateStore.transition(context.workspace, "verify")
    assert {:error, _} = RunStateStore.save(context.workspace, before_state)
    assert {:error, _} = RunStateStore.update(context.workspace, fn _ -> flunk("pending transition allowed mutation") end)
    assert {:error, _} = RunStateStore.sync_lease(context.workspace, %{id: "audit-1"}, %{lease_owner: "owner"})
    assert {:error, _} = RunStateStore.record_token_usage(context.workspace, %{id: "audit-1"}, %{input_tokens: 0, output_tokens: 0, total_tokens: 0})
    assert {:error, _} = RunStateStore.clear_lease(context.workspace)

    marker = Path.join(context.root, "hook-must-not-run")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: context.root, hook_before_remove: "touch #{marker}", hook_after_create: "touch #{marker}")
    assert {:error, _} = Workspace.create_for_issue("AUDIT-1")
    assert {:error, _, _} = Workspace.remove(context.workspace)
    assert {:error, _, _} = Workspace.remove_issue_workspaces("AUDIT-1")
    refute File.exists?(marker)
    assert File.read!(RunStateStore.state_path(context.workspace)) == original

    assert {:ok, reconciled} = RunStateStore.reconcile_pending_transition(context.workspace)
    assert reconciled == final_state
    assert reconciled.stage_transition_counts == %{"implement" => 1, "blocked" => 1}
    assert File.read!(RunLedger.ledger_file_path()) == ledger
    assert {:error, :no_audit_pending} = RunStateStore.reconcile_pending_transition(context.workspace)
  end

  for scenario <- [:missing_confirmation, :different_ledger, :changed_snapshot, :corrupt_ledger, :duplicate_confirmation] do
    test "#{scenario} preserves the unresolved snapshot", context do
      data = interrupted_confirmation(context)
      scenario = unquote(scenario)
      ledger_path = RunLedger.ledger_file_path()
      rows = ledger_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      alter_evidence(scenario, data, context, ledger_path, rows)

      original = File.read!(RunStateStore.state_path(context.workspace))
      assert {:error, _} = RunStateStore.reconcile_pending_transition(context.workspace)
      assert File.read!(RunStateStore.state_path(context.workspace)) == original
      assert {:error, {:audit_pending, _}} = RunStateStore.load(context.workspace)
    end
  end

  for boundary <- ["stage.transition.requested", "stage.transition"] do
    test "a process killed after #{boundary} cannot silently advance execution", context do
      assert {:ok, before_state} = RunStateStore.transition(context.workspace, "implement", %{issue_id: "audit-1", issue_identifier: "AUDIT-1"})
      before_bytes = File.read!(RunStateStore.state_path(context.workspace))
      boundary = unquote(boundary)
      task = pause_transition(context, boundary)
      Process.exit(task.pid, :kill)
      assert {:exit, :killed} = Task.yield(task, 5_000)
      assert_killed_transition(boundary, context, before_state, before_bytes)
    end
  end

  test "reconciliation after a crash retains usage when transition attributes were stale", context do
    issue = %{id: "audit-1", identifier: "AUDIT-1"}
    assert {:ok, _} = RunStateStore.transition(context.workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    usage = %{input_tokens: 300, output_tokens: 200, total_tokens: 500}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, issue, usage)
    task = pause_transition(context, "stage.transition", %{token_usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}})
    Process.exit(task.pid, :kill)
    assert {:exit, :killed} = Task.yield(task, 5_000)
    assert {:error, {:audit_pending, _}} = RunStateStore.load(context.workspace)
    assert {:ok, reconciled} = RunStateStore.reconcile_pending_transition(context.workspace)
    assert reconciled.token_usage == usage
    assert reconciled.stage_transition_counts == %{"implement" => 1, "verify" => 1}
  end

  test "failure after the intent leaves a pending snapshot and cannot fabricate confirmation", context do
    assert {:ok, _} = RunStateStore.transition(context.workspace, "implement", %{issue_id: "audit-1", issue_identifier: "AUDIT-1"})
    task = pause_transition(context, "stage.transition.requested")
    path = RunLedger.ledger_file_path()
    backup = path <> ".saved"
    File.rename!(path, backup)
    File.mkdir!(path)
    send(task.pid, :continue_audit)
    assert {:ok, {:error, %RunLedger.PersistenceError{phase: :preflight, reason: :eisdir}}} = Task.yield(task, 5_000)
    assert {:error, {:audit_pending, _}} = RunStateStore.load(context.workspace)
    snapshot = File.read!(RunStateStore.state_path(context.workspace))
    File.rmdir!(path)
    File.rename!(backup, path)
    assert {:error, :not_found} = RunStateStore.reconcile_pending_transition(context.workspace)
    assert File.read!(RunStateStore.state_path(context.workspace)) == snapshot
  end

  defp pause_transition(context, event_type, attrs \\ %{}) do
    handler = "audit-boundary-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.audit_barrier/4, {self(), event_type})
    on_exit(fn -> :telemetry.detach(handler) end)
    task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> RunStateStore.transition(context.workspace, "verify", attrs) end)
    assert_receive {:audit_boundary, pid}, 5_000
    assert pid == task.pid
    task
  end

  def audit_barrier(_event, _measurements, metadata, {owner, event_type}) do
    if metadata[:event_type] == event_type and metadata[:issue_id] == "audit-1" and metadata[:stage] == "verify" do
      send(owner, {:audit_boundary, self()})

      receive do
        :continue_audit -> :ok
      after
        5_000 -> raise "Audit test barrier was not released"
      end
    end
  end

  defp assert_killed_transition("stage.transition.requested", context, before_state, before_bytes) do
    assert File.read!(RunStateStore.state_path(context.workspace)) == before_bytes
    assert {:ok, ^before_state} = RunStateStore.load(context.workspace)
  end

  defp assert_killed_transition("stage.transition", context, _before_state, _before_bytes) do
    assert {:error, {:audit_pending, _}} = RunStateStore.load(context.workspace)
    assert {:ok, reconciled} = RunStateStore.reconcile_pending_transition(context.workspace)
    assert reconciled.stage == "verify"
    assert reconciled.stage_transition_counts == %{"implement" => 1, "verify" => 1}
    assert {:ok, row} = RunLedger.fetch_entry_checked(reconciled.last_ledger_event_id)
    assert row["event_type"] == "stage.transition"
  end

  defp alter_evidence(scenario, data, context, ledger_path, rows) do
    case scenario do
      :missing_confirmation ->
        rows = Enum.reject(rows, &(&1["event_id"] == data.pending["confirmation"]["event_id"]))
        File.write!(ledger_path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")

      :different_ledger ->
        Application.put_env(:symphony_elixir, :log_file, Path.join(context.root, "different/runtime.log"))

      :changed_snapshot ->
        raw = context.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
        File.write!(RunStateStore.state_path(context.workspace), Jason.encode!(Map.put(raw, "stage", "verify")))

      :corrupt_ledger ->
        File.write!(ledger_path, "{broken\n", [:append])

      :duplicate_confirmation ->
        File.write!(ledger_path, Jason.encode!(data.pending["confirmation"]) <> "\n", [:append])
    end
  end

  defp interrupted_confirmation(context) do
    assert {:ok, before_state} = RunStateStore.transition(context.workspace, "implement", %{issue_id: "audit-1", issue_identifier: "AUDIT-1"})
    assert {:ok, final} = RunStateStore.transition(context.workspace, "blocked")
    rows = RunLedger.recent_entries(100)
    confirmation = Enum.find(rows, &(&1["event_id"] == final.last_ledger_event_id))
    operation_id = confirmation["metadata"]["operation_id"]
    assert is_binary(operation_id)
    intent = Enum.find(rows, &(&1["event_type"] == "stage.transition.requested" and &1["metadata"]["operation_id"] == operation_id))
    pending = %{"operation_id" => operation_id, "ledger_path" => RunLedger.ledger_file_path(), "intent_event_id" => intent["event_id"], "confirmation" => confirmation}
    candidate = final |> Map.put(:last_ledger_event_id, before_state.last_ledger_event_id) |> Map.put(:audit_pending, pending)
    File.write!(RunStateStore.state_path(context.workspace), Jason.encode!(candidate))
    %{before: before_state, final: final, pending: pending}
  end
end
