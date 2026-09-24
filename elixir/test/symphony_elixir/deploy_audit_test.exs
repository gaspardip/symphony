defmodule SymphonyElixir.DeployAuditTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{DeployAudit, RunLedger, RunStateStore, TestSupport, WorkflowStore}

  setup context do
    root = Path.join(System.tmp_dir!(), "deploy-audit-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
    File.mkdir_p!(root)
    previous = Map.new([:log_file, :workflow_file_path, :memory_tracker_issues], &{&1, Application.fetch_env(:symphony_elixir, &1)})
    workflow = Path.join(root, "WORKFLOW.md")

    TestSupport.write_workflow_file!(workflow,
      tracker_kind: "memory",
      manual_enabled: false,
      max_concurrent_agents: 0,
      codex_command: "false",
      workspace_root: Path.join(root, "workspaces"),
      runner_install_root: Path.join(root, "runner"),
      observability_enabled: false,
      observability_tracing_enabled: false
    )

    Application.put_env(:symphony_elixir, :workflow_file_path, workflow)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "runtime.log"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    reload_workflow()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
      end)

      reload_workflow()
      File.rm_rf!(root)
    end)

    workspace = Path.join(root, "workspaces/DEPLOY-1")
    stage = Map.get(context, :deploy_stage, "deploy_preview")
    issue = %{id: "deploy-1", identifier: "DEPLOY-1"}
    assert {:ok, _state} = RunStateStore.transition(workspace, stage, %{issue_id: issue.id, issue_identifier: issue.identifier})

    %{
      root: root,
      workspace: workspace,
      issue: issue,
      attrs: %{issue_id: issue.id, issue_identifier: issue.identifier, stage: stage, command: "controlled-deploy"},
      result: %{status: :passed, command: "controlled-deploy", output: "observed success"}
    }
  end

  for stage <- ["deploy_preview", "deploy_production"], destination <- ["post_deploy_verify", "done"] do
    @tag deploy_stage: stage, destination: destination
    test "#{stage} records one result and its own continuation to #{destination}", context do
      assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
      assert {:error, {:deploy_audit_pending, _}} = RunStateStore.ensure_readable(context.workspace)
      assert {:ok, before} = RunStateStore.load(context.workspace)
      assert before.stage == context.attrs.stage
      assert :ok = DeployAudit.record_result(ticket, context.result)
      assert :ok = RunStateStore.ensure_deploy_current(ticket)

      assert {:ok, state, continuation} = RunStateStore.transition_deploy(ticket, context.destination, %{last_decision_summary: "Deploy observed."})
      assert state.stage == context.destination
      assert state.last_deploy_operation_id == ticket.operation_id
      assert continuation.event["event_id"] == state.last_ledger_event_id
      assert continuation.event["metadata"]["deploy_operation_id"] == ticket.operation_id

      result_key = if context.attrs.stage == "deploy_preview", do: :last_deploy_preview, else: :last_deploy_production
      assert state[result_key] == %{status: "passed", command: "controlled-deploy", output: "observed success"}

      if context.attrs.stage == "deploy_production" do
        assert state.deploy_approved == false
        assert state.deploy_window_wait == nil
      end

      assert {:error, :deploy_audit_snapshot_conflict} = RunStateStore.transition_deploy(ticket, context.destination, %{})
      assert :ok = DeployAudit.finish(ticket, continuation)
      assert :ok = RunStateStore.ensure_readable(context.workspace)
      assert :ok = DeployAudit.ensure_available(context.workspace)
      assert Enum.map(deploy_rows(), & &1["event_type"]) == ["deploy.#{state.current_deploy_target}.requested", "deploy.#{state.current_deploy_target}.observed"]
    end
  end

  test "invalid inputs and identity or stage conflicts create no deploy journal", context do
    for attrs <- [%{context.attrs | command: ""}, %{context.attrs | stage: "implement"}, %{context.attrs | issue_id: ""}] do
      assert {:error, :invalid_deploy_audit_attrs} = DeployAudit.begin(context.workspace, attrs)
    end

    for attrs <- [%{context.attrs | issue_id: "different"}, %{context.attrs | issue_identifier: "DIFFERENT"}, %{context.attrs | stage: "deploy_production"}] do
      assert {:error, :deploy_audit_snapshot_conflict} = DeployAudit.begin(context.workspace, attrs)
    end

    assert :ok = DeployAudit.ensure_available(context.workspace)
    assert deploy_rows() == []
  end

  test "concurrent attempts and equivalent paths reserve one operation", context do
    equivalent = Path.join([context.root, "workspaces", "unused", "..", "DEPLOY-1"])

    results =
      1..6
      |> Task.async_stream(fn index -> DeployAudit.begin(if(index == 1, do: equivalent, else: context.workspace), context.attrs) end, max_concurrency: 6)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, _ticket}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, {:deploy_audit_pending, _}}, &1)) == 5
    assert length(deploy_rows()) == 1
  end

  for kind <- [:empty, :corrupt, :file, :symlink] do
    @tag marker_kind: kind
    test "an existing #{kind} journal blocks admission without rewriting evidence", context do
      directory = DeployAudit.marker_directory(context.workspace)
      prepare_broken_marker(directory, context.marker_kind, context.root)
      assert {:error, {:deploy_audit_pending, _}} = DeployAudit.begin(context.workspace, context.attrs)
      assert {:error, {:deploy_audit_pending, _}} = RunStateStore.ensure_readable(context.workspace)
      assert {:ok, _state} = RunStateStore.load(context.workspace)
      assert {:ok, _stat} = File.lstat(directory)
      assert deploy_rows() == []
    end
  end

  test "unreadable ledger refuses admission before any deploy reservation", context do
    ledger = RunLedger.ledger_file_path()
    backup = ledger <> ".before-fault"
    File.rename!(ledger, backup)
    File.mkdir!(ledger)
    assert {:error, %RunLedger.PersistenceError{}} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.ensure_available(context.workspace)
    File.rmdir!(ledger)
    File.rename!(backup, ledger)
    assert deploy_rows() == []
    assert {:ok, _ticket} = DeployAudit.begin(context.workspace, context.attrs)
  end

  test "an absent original ledger cannot be replaced by a new audit file", context do
    ledger = RunLedger.ledger_file_path()
    File.rename!(ledger, ledger <> ".retained")
    assert {:error, %RunLedger.PersistenceError{phase: :read, reason: :enoent}} = DeployAudit.begin(context.workspace, context.attrs)
    refute File.exists?(ledger)
    assert :ok = DeployAudit.ensure_available(context.workspace)
  end

  test "a snapshot without its stage entry cannot authorize a deployment", context do
    assert {:ok, _state} = RunStateStore.update(context.workspace, &Map.put(&1, :last_ledger_event_id, nil))
    assert {:error, :deploy_audit_entry_missing} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.ensure_available(context.workspace)
    assert deploy_rows() == []
  end

  test "failure to persist authorization after the intent returns no ticket", context do
    attach_fault(context, "deploy.preview.requested", :marker_directory)
    assert {:error, {:deploy_audit_marker_write_failed, :invalid_marker_type}} = DeployAudit.begin(context.workspace, context.attrs)
    assert_received {:deploy_fault_applied, :marker_directory}
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.begin(context.workspace, context.attrs)
    assert length(deploy_rows()) == 1
  end

  test "a command observation is retained when its ledger cannot confirm the result", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    effects = Path.join(context.root, "observed-effects")
    File.write!(effects, "one deploy\n")
    File.write!(RunLedger.ledger_file_path(), "{corrupt")
    assert {:error, _reason} = DeployAudit.record_result(ticket, context.result)
    assert marker(context.workspace)["status"] == "result_pending"
    assert marker(context.workspace)["result"]["metadata"]["result"]["output"] == "observed success"
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.begin(context.workspace, context.attrs)
    assert {:error, :deploy_audit_result_already_started} = DeployAudit.record_result(ticket, context.result)
    assert File.read!(effects) == "one deploy\n"
  end

  test "failed commands remain pending despite a confirmed audit and cannot be replaced by success", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    result = %{context.result | status: :failed, output: "effect may have happened"}
    assert {:error, {:deploy_audit_result_uncertain, "failed"}} = DeployAudit.record_result(ticket, result)
    assert {:error, {:deploy_audit_result_uncertain, "failed"}} = RunStateStore.transition_deploy(ticket, "done", %{})
    assert {:error, :deploy_audit_result_already_started} = DeployAudit.record_result(ticket, context.result)
    assert marker(context.workspace)["status"] == "result_confirmed"
    assert length(deploy_rows()) == 2
    assert {:ok, state} = RunStateStore.load(context.workspace)
    assert state.stage == "deploy_preview"
    refute Map.has_key?(state, :last_deploy_preview)
  end

  test "missing or mismatched result data cannot claim another command", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)

    for invalid <- [%{}, %{context.result | command: "other-command"}, %{context.result | output: nil}] do
      assert {:error, :invalid_deploy_audit_result} = DeployAudit.record_result(ticket, invalid)
    end

    assert marker(context.workspace)["status"] == "authorized"
    assert length(deploy_rows()) == 1
  end

  test "tickets cannot be mutated or transferred to another live process", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    original = File.read!(marker_path(context.workspace))
    assert {:error, :deploy_audit_ticket_mismatch} = DeployAudit.record_result(%{ticket | operation_id: "other"}, context.result)
    parent = self()
    spawn(fn -> send(parent, {:other_owner, DeployAudit.record_result(ticket, context.result)}) end)
    assert_receive {:other_owner, {:error, :deploy_audit_wrong_owner}}
    assert File.read!(marker_path(context.workspace)) == original
  end

  test "a confirmed intent alone cannot authorize a continuation", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert {:error, :deploy_audit_result_unconfirmed} = RunStateStore.ensure_deploy_current(ticket)
    assert {:error, :deploy_audit_result_unconfirmed} = RunStateStore.transition_deploy(ticket, "done", %{})
    assert {:ok, state} = RunStateStore.load(context.workspace)
    assert state.stage == "deploy_preview"
    assert length(deploy_rows()) == 1
  end

  test "a marker replaced by a symlink cannot record or close the operation", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    path = marker_path(context.workspace)
    retained = path <> ".retained"
    File.rename!(path, retained)
    File.ln_s!(retained, path)
    assert {:error, :invalid_deploy_audit_marker_type} = DeployAudit.record_result(ticket, context.result)
    assert {:error, :invalid_deploy_audit_marker_type} = RunStateStore.ensure_deploy_current(ticket)
    assert {:ok, %{type: :symlink}} = File.lstat(path)
    assert length(deploy_rows()) == 1
  end

  test "altered result evidence cannot authorize a continuation", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    result_id = marker(context.workspace)["result"]["event_id"]
    rewrite_row(result_id, &put_in(&1, ["metadata", "result", "output"], "altered"))
    assert {:error, :deploy_audit_result_mismatch} = RunStateStore.transition_deploy(ticket, "done", %{})
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(context.workspace)
  end

  test "changed ledger cannot confirm a result or continue it through another file", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    Application.put_env(:symphony_elixir, :log_file, Path.join(context.root, "different/runtime.log"))
    assert {:error, :deploy_audit_ledger_changed} = DeployAudit.record_result(ticket, context.result)
    assert marker(context.workspace)["status"] == "result_pending"
    refute File.exists?(RunLedger.ledger_file_path())
    assert {:error, :deploy_audit_result_unconfirmed} = RunStateStore.ensure_deploy_current(ticket)
  end

  test "snapshot observations, token usage and same-owner lease renewal remain available", context do
    assert {:ok, _} = RunStateStore.sync_lease(context.workspace, context.issue, %{owner: "runner", epoch: 3, updated_at: "before"})
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, %{input_tokens: 30, output_tokens: 12, total_tokens: 42})
    assert {:ok, _} = RunStateStore.sync_lease(context.workspace, context.issue, %{owner: "runner", epoch: 3, updated_at: "renewed"})
    assert {:ok, _state} = RunStateStore.load(context.workspace)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    assert {:ok, state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{})
    assert state.token_usage.total_tokens == 42
    assert state.lease_updated_at == "renewed"
    assert state.lease_epoch == 3
    assert :ok = DeployAudit.finish(ticket, continuation)
  end

  for conflict <- [:stop, :same_stage_stop_reason, :stage_roundtrip, :lease_takeover, :lease_cleared, :identity] do
    @tag snapshot_conflict: conflict
    test "#{conflict} prevents late continuation without overwriting the current snapshot", context do
      assert {:ok, _} = RunStateStore.sync_lease(context.workspace, context.issue, %{owner: "runner", epoch: 3})
      assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
      apply_conflict(context)
      snapshot = File.read!(RunStateStore.state_path(context.workspace))
      assert :ok = DeployAudit.record_result(ticket, context.result)
      assert {:error, :deploy_audit_snapshot_conflict} = RunStateStore.ensure_deploy_current(ticket)
      assert {:error, :deploy_audit_snapshot_conflict} = RunStateStore.transition_deploy(ticket, "done", %{})
      assert File.read!(RunStateStore.state_path(context.workspace)) == snapshot
      assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(context.workspace)
    end
  end

  test "continuation rejects supplied identity, lease or result overrides", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    before = File.read!(RunStateStore.state_path(context.workspace))

    for attrs <- [%{issue_id: "other"}, %{lease_owner: "other"}, %{last_deploy_preview: %{status: "passed"}}, %{stop_reason: %{code: "other"}}] do
      assert {:error, :invalid_deploy_transition_attrs} = RunStateStore.transition_deploy(ticket, "done", attrs)
    end

    assert File.read!(RunStateStore.state_path(context.workspace)) == before
  end

  test "an unrelated transition to the same destination cannot close the journal", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    assert {:ok, state} = RunStateStore.transition(context.workspace, "done", %{last_deploy_operation_id: ticket.operation_id})
    assert {:ok, event} = RunLedger.fetch_entry_checked(state.last_ledger_event_id)
    assert {:error, :deploy_audit_continuation_mismatch} = DeployAudit.finish(ticket, %{stage: "done", event: event})
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(context.workspace)
  end

  test "altered exact transition evidence cannot close a successfully continued operation", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{})
    rewrite_row(continuation.event["event_id"], &Map.put(&1, "summary", "altered after confirmation"))
    assert {:error, :deploy_audit_continuation_mismatch} = DeployAudit.finish(ticket, continuation)
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(context.workspace)
  end

  test "a stop after continuation still prevents journal closure", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{})
    assert {:ok, _state} = RunStateStore.transition(context.workspace, "blocked", %{stop_reason: %{code: "operator.stop"}})
    assert {:error, :deploy_audit_snapshot_conflict} = DeployAudit.finish(ticket, continuation)
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(context.workspace)
  end

  test "unreadable snapshot after a result preserves the operation", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    File.rename!(RunStateStore.state_path(context.workspace), Path.join(context.root, "retained-snapshot"))
    File.mkdir!(RunStateStore.state_path(context.workspace))
    assert {:error, :eisdir} = RunStateStore.transition_deploy(ticket, "done", %{})
    assert marker(context.workspace)["status"] == "result_confirmed"
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(context.workspace)
  end

  test "failure auditing the continuation preserves both pending snapshot and deploy evidence", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    attach_fault(context, "stage.transition.requested", :corrupt_ledger)
    assert {:error, %RunLedger.PersistenceError{}} = RunStateStore.transition_deploy(ticket, "done", %{})
    assert_received {:deploy_fault_applied, :corrupt_ledger}
    assert {:error, {:audit_pending, _}} = RunStateStore.load(context.workspace)
    assert marker(context.workspace)["status"] == "result_confirmed"
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.begin(context.workspace, context.attrs)
  end

  test "unexpected cleanup evidence is retained after the command and transition succeed", context do
    assert {:ok, ticket} = DeployAudit.begin(context.workspace, context.attrs)
    assert :ok = DeployAudit.record_result(ticket, context.result)
    assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{})
    evidence = Path.join(DeployAudit.marker_directory(context.workspace), "retained-evidence")
    File.write!(evidence, "do not discard")
    assert {:error, :deploy_audit_unexpected_files} = DeployAudit.finish(ticket, continuation)
    assert File.read!(evidence) == "do not discard"
    assert marker(context.workspace)["status"] == "result_confirmed"
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(context.workspace)
  end

  defp apply_conflict(%{snapshot_conflict: :stop} = context) do
    assert {:ok, _} = RunStateStore.transition(context.workspace, "blocked", %{stop_reason: %{code: "operator.stop"}})
  end

  defp apply_conflict(%{snapshot_conflict: :same_stage_stop_reason} = context) do
    assert {:ok, _} = RunStateStore.update(context.workspace, &Map.put(&1, :stop_reason, %{code: "operator.stop"}))
  end

  defp apply_conflict(%{snapshot_conflict: :stage_roundtrip} = context) do
    assert {:ok, _} = RunStateStore.transition(context.workspace, "blocked")
    assert {:ok, _} = RunStateStore.transition(context.workspace, "deploy_preview")
  end

  defp apply_conflict(%{snapshot_conflict: :lease_takeover} = context) do
    assert {:ok, _} = RunStateStore.sync_lease(context.workspace, context.issue, %{owner: "another-runner", epoch: 4})
  end

  defp apply_conflict(%{snapshot_conflict: :lease_cleared} = context) do
    assert {:ok, _} = RunStateStore.clear_lease(context.workspace)
  end

  defp apply_conflict(%{snapshot_conflict: :identity} = context) do
    assert {:ok, _} = RunStateStore.update(context.workspace, &Map.put(&1, :issue_identifier, "OTHER-ISSUE"))
  end

  defp marker_path(workspace), do: Path.join(DeployAudit.marker_directory(workspace), "marker.json")
  defp marker(workspace), do: workspace |> marker_path() |> File.read!() |> Jason.decode!()
  defp rows, do: RunLedger.ledger_file_path() |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp deploy_rows, do: Enum.filter(rows(), &String.starts_with?(&1["event_type"], "deploy."))

  defp rewrite_row(id, fun) do
    contents = rows() |> Enum.map(fn row -> if row["event_id"] == id, do: fun.(row), else: row end) |> Enum.map_join("\n", &Jason.encode!/1)
    File.write!(RunLedger.ledger_file_path(), contents <> "\n")
  end

  defp prepare_broken_marker(directory, :empty, _root), do: File.mkdir!(directory)
  defp prepare_broken_marker(directory, :file, _root), do: File.write!(directory, "retained")

  defp prepare_broken_marker(directory, :corrupt, _root) do
    File.mkdir!(directory)
    File.write!(Path.join(directory, "marker.json"), "{corrupt")
  end

  defp prepare_broken_marker(directory, :symlink, root) do
    target = Path.join(root, "symlink-target")
    File.mkdir!(target)
    File.ln_s!(target, directory)
  end

  defp attach_fault(context, event_type, fault) do
    handler = "deploy-fault-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    assert :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.boundary_fault/4, {self(), context.workspace, event_type, fault})
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def boundary_fault(_event, _measurements, metadata, {owner, workspace, event_type, fault}) do
    if self() == owner and metadata[:event_type] == event_type do
      case fault do
        :marker_directory ->
          File.rename!(marker_path(workspace), marker_path(workspace) <> ".retained")
          File.mkdir!(marker_path(workspace))

        :corrupt_ledger ->
          File.write!(RunLedger.ledger_file_path(), "{corrupt")
      end

      send(owner, {:deploy_fault_applied, fault})
    end
  end

  defp reload_workflow do
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()
  end
end
