defmodule SymphonyElixir.DispatchInterruptedBlockTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, LeaseManager, RuleCatalog, RunIdentity, RunLedger, RunStateStore}
  alias SymphonyElixirWeb.Presenter

  setup do
    root = Path.join(System.tmp_dir!(), "dispatch-interruption-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root, observability_tracing_enabled: false)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for stage <- ["implement", "validate"] do
    @tag stage: stage
    test "#{stage} blocks with audited disposition and unchanged dispatch custody", c do
      f = admitted!(c.root, c.stage)
      before = physical!(f)
      raw_before = Jason.decode!(before.snapshot)
      assert {:ok, stopped} = DispatchAudit.block_interrupted(f.workspace, f.issue)
      assert stopped.stage == "blocked"
      assert stopped.resume_stage == c.stage
      assert stopped.run_id == f.ticket.run_id
      assert stopped.stop_reason.code == "dispatch_audit_pending"
      assert stopped.next_human_action == RuleCatalog.human_action(:dispatch_audit_pending)
      refute stopped.next_human_action =~ "PR"
      after_bytes = physical!(f)
      assert after_bytes.marker == before.marker
      assert after_bytes.lease == before.lease
      assert after_bytes.sentinel == before.sentinel
      assert String.starts_with?(after_bytes.ledger, before.ledger)
      raw = Jason.decode!(after_bytes.snapshot)
      evidence = raw["resume_context"]["dispatch_interruption"]
      assert evidence["checkpoint"]["snapshot_sha256"] == digest(before.snapshot)
      assert evidence["checkpoint"]["previous_fields"]["stage"] == c.stage
      assert evidence["checkpoint"]["previous_fields"]["last_decision_summary"] == "Retained pre-crash decision"
      assert evidence["dispatch_id"] == f.ticket.dispatch_id
      assert evidence["authorization_event_id"] == f.ticket.entry_event_id
      assert evidence["marker_sha256"] == digest(before.marker)
      assert evidence["lease"]["status"] == "expired"
      assert evidence["lease"]["sha256"] == digest(before.lease)
      assert evidence["lease"]["identity"] == Map.take(Jason.decode!(before.lease), ~w(issue_id issue_identifier owner epoch lease_version lease_generation acquired_at updated_at))
      assert raw["resume_context"]["retained_context"] == "checkpoint-context"

      overwritten =
        ~w(stage resume_stage resume_context stop_reason last_decision last_rule_id last_failure_class last_decision_summary next_human_action reason last_ledger_event_id stage_history stage_transition_counts)

      assert Map.drop(raw, overwritten) == Map.drop(raw_before, overwritten)
      assert List.last(raw["stage_history"])["stage"] == "blocked"
      assert :ok = RunIdentity.verify(f.workspace, f.ticket.run_id, f.issue.id, f.issue.identifier)
      assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(f.workspace)
      assert {:ok, trace} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
      assert trace.result["stage"] == "blocked"
      assert trace.result["stop_reason"]["code"] == "dispatch_audit_pending"
      assert trace.evidence.last_event["event_type"] == "stage.transition"
      assert Enum.all?(trace.evidence.dispatches, &is_nil(&1.finished))
      new_events = Enum.drop(rows!(f), length(String.split(before.ledger, "\n", trim: true)))
      assert Enum.map(new_events, & &1["event_type"]) == ["stage.transition.requested", "stage.transition"]
      assert List.last(new_events)["metadata"]["run_binding"]["run_id"] == f.ticket.run_id
    end
  end

  test "repeated calls preserve the original checkpoint and append no events", c do
    f = admitted!(c.root, "implement")
    assert {:ok, first} = DispatchAudit.block_interrupted(f.workspace, f.issue)
    before = physical!(f)
    assert {:ok, reloaded} = RunStateStore.load(f.workspace)
    assert canonical(reloaded) == canonical(first)

    for _ <- 1..3 do
      assert {:ok, repeated} = DispatchAudit.block_interrupted(f.workspace, f.issue)
      assert canonical(repeated) == canonical(first)
      assert physical!(f) == before
    end
  end

  test "exact physical lease absence is diagnostic without creating a new lease", c do
    f = admitted!(c.root, "validate")
    assert {:ok, :released} = LeaseManager.release_token(f.acquired.token)
    marker = File.read!(f.marker_path)
    assert {:ok, stopped} = DispatchAudit.block_interrupted(f.workspace, f.issue)
    assert stopped.resume_context.dispatch_interruption.lease.status == "missing"
    refute File.exists?(f.storage.lease_path)
    assert File.read!(f.marker_path) == marker
    refute Enum.any?(rows!(f), &(&1["event_type"] in ["dispatch.finished", "lease.taken_over"]))
  end

  test "a renewed live lease refuses diagnosis without changing any artifact", c do
    f = admitted!(c.root, "implement")
    assert {:ok, _lease} = LeaseManager.refresh_token(f.acquired.token)
    before = physical!(f)
    assert {:error, :lease_still_active} = DispatchAudit.block_interrupted(f.workspace, f.issue)
    assert physical!(f) == before
  end

  for fault <- [:issue, :run, :marker, :marker_prepared, :lease, :lease_pending, :owner, :snapshot, :snapshot_shape, :blocked, :finished, :symlink, :deploy] do
    @tag fault: fault
    test "#{fault} rejects without losing or replacing physical evidence", c do
      f = admitted!(c.root, "implement")
      fault!(f, c.fault)
      before = physical!(f)
      issue = if c.fault == :issue, do: %{f.issue | id: "another-issue"}, else: f.issue
      assert {:error, _reason} = DispatchAudit.block_interrupted(f.workspace, issue)
      assert physical!(f) == before
      if c.fault == :symlink, do: assert({:ok, %{type: :symlink}} = File.lstat(f.state_path))
    end
  end

  test "a blocked decision with tampered checkpoint is never accepted as idempotent", c do
    f = admitted!(c.root, "implement")
    assert {:ok, _} = DispatchAudit.block_interrupted(f.workspace, f.issue)
    raw = Jason.decode!(File.read!(f.state_path))
    File.write!(f.state_path, Jason.encode!(put_in(raw, ["resume_context", "dispatch_interruption", "checkpoint", "snapshot_sha256"], "tampered")))
    before = physical!(f)
    assert {:error, :dispatch_audit_diagnostic_unconfirmed} = DispatchAudit.block_interrupted(f.workspace, f.issue)
    assert physical!(f) == before
  end

  test "an occupied physical ledger lock rejects before any diagnostic write", c do
    f = admitted!(c.root, "implement")
    lock = f.ticket.ledger_path <> ".checked.lock"
    File.mkdir!(lock)
    on_exit(fn -> if File.dir?(lock), do: File.rmdir!(lock) end)
    before = physical!(f)
    assert {:error, %RunLedger.PersistenceError{phase: :lock}} = DispatchAudit.block_interrupted(f.workspace, f.issue)
    assert physical!(f) == before
    assert File.dir?(lock)
  end

  test "real ledger lock failure after block intent remains an explicit pending transition", c do
    f = admitted!(c.root, "validate")
    handler = "interrupted-block-fault-#{System.unique_integer([:positive])}"
    lock = f.ticket.ledger_path <> ".checked.lock"
    assert :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.lock_after_intent/4, {self(), f.issue.id, lock})

    on_exit(fn ->
      :telemetry.detach(handler)
      if File.dir?(lock), do: File.rmdir!(lock)
    end)

    before = physical!(f)
    assert {:error, %RunLedger.PersistenceError{phase: :lock}} = DispatchAudit.block_interrupted(f.workspace, f.issue)
    assert_receive {:block_intent_locked, event_id}
    assert {:error, {:audit_pending, _}} = RunStateStore.load(f.workspace)
    raw = Jason.decode!(File.read!(f.state_path))
    assert raw["stage"] == "blocked"
    assert raw["audit_pending"]["intent_event_id"] == event_id
    assert File.read!(f.marker_path) == before.marker
    assert File.read!(f.storage.lease_path) == before.lease
    assert File.read!(f.sentinel_path) == before.sentinel
    File.rmdir!(lock)
    :telemetry.detach(handler)
    assert {:error, :not_found} = RunStateStore.reconcile_pending_transition(f.workspace)
    assert {:error, {:audit_pending, _}} = RunStateStore.load(f.workspace)
    refute Enum.any?(rows!(f), &(&1["event_type"] == "dispatch.finished"))
    assert {:error, 409, _} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
  end

  test "the inactive callback holds the actual lease lock until it returns", c do
    f = admitted!(c.root, "implement")
    parent = self()

    task =
      Task.async(fn ->
        LeaseManager.with_inactive(f.storage, fn {:expired, _lease, _bytes} ->
          send(parent, {:inactive_guard_entered, self()})

          receive do
            :finish_diagnosis -> :diagnosed
          after
            5_000 -> raise "controlled inactive-guard test did not finish"
          end
        end)
      end)

    assert_receive {:inactive_guard_entered, guarded}
    assert File.dir?(f.storage.lease_path <> ".lock")
    assert {:error, {:lease_lock_timeout, _}} = LeaseManager.refresh_token(f.acquired.token)
    send(guarded, :finish_diagnosis)
    assert :diagnosed = Task.await(task)
    refute File.exists?(f.storage.lease_path <> ".lock")
  end

  test "automatic dispatch with no retained lease preserves bytes and starts no guardian", c do
    f = admitted!(c.root, "implement")
    issue = runtime_issue(f)
    before = physical!(f)
    File.rm!(f.storage.lease_path)
    workers = MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor))
    observed = SymphonyElixir.Orchestrator.dispatch_runtime_issue(runtime_state(issue), issue, nil)
    assert observed.admission_read == nil and observed.running == %{} and observed.lease_claims == %{}
    assert observed.candidate_fetch_error == {:dispatch_audit_pending, f.workspace}
    assert MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor)) == workers
    assert {:ok, {:skipped, :lease_missing}} = DispatchAudit.block_interrupted_if_expired(f.workspace, f.issue)
    assert File.read!(f.state_path) == before.snapshot
    assert File.read!(f.marker_path) == before.marker
    assert File.read!(f.ticket.ledger_path) == before.ledger
    refute File.exists?(f.storage.lease_path)
    refute_receive {:tracker_read_result, _, _}
  end

  test "automatic dispatch with a live lease preserves the original rejection without a guardian", c do
    f = admitted!(c.root, "implement")
    issue = runtime_issue(f)
    assert {:ok, _lease} = LeaseManager.refresh_token(f.acquired.token)
    before = physical!(f)
    workers = MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor))
    observed = SymphonyElixir.Orchestrator.dispatch_runtime_issue(runtime_state(issue), issue, nil)
    assert observed.admission_read == nil and observed.running == %{} and observed.lease_claims == %{}
    assert observed.candidate_fetch_error == {:dispatch_audit_pending, f.workspace}
    assert MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor)) == workers
    assert {:ok, {:skipped, :lease_still_active}} = DispatchAudit.block_interrupted_if_expired(f.workspace, f.issue)
    assert physical!(f) == before
    refute_receive {:tracker_read_result, _, _}
  end

  test "an expired lease cannot authorize automatic attribution to colliding candidate identities", c do
    f = admitted!(c.root, "validate")
    issue = runtime_issue(f)
    other = %{issue | id: issue.id <> "-other"}
    assert Workspace.path_for_issue(issue) == Workspace.path_for_issue(other)
    runtime = %{runtime_state(issue) | last_candidate_issues: [issue, other]}
    before = physical!(f)
    observed = SymphonyElixir.Orchestrator.dispatch_runtime_issue(runtime, issue, nil)
    assert observed.admission_read == nil and observed.running == %{} and observed.lease_claims == %{}
    assert observed.candidate_fetch_error == {:dispatch_audit_pending, f.workspace}
    assert physical!(f) == before
    refute_receive {:tracker_read_result, _, _}
  end

  test "a lease removed after the automatic precheck is skipped under the actual lease mutex", c do
    f = admitted!(c.root, "implement")
    issue = runtime_issue(f)
    before = physical!(f)

    pending =
      LeaseManager.with_inactive(f.storage, fn {:expired, _lease, _bytes} ->
        pending = SymphonyElixir.Orchestrator.dispatch_runtime_issue(runtime_state(issue), issue, nil)
        assert %{purpose: :interrupted_dispatch} = pending.admission_read
        assert File.dir?(f.storage.lease_path <> ".lock")
        File.rm!(f.storage.lease_path)
        pending
      end)

    ref = pending.admission_read.ref
    assert_receive {:tracker_read_result, ^ref, {:ok, {:skipped, :lease_missing}} = result}, 5_000
    assert {:noreply, observed} = SymphonyElixir.Orchestrator.handle_info({:tracker_read_result, ref, result}, pending)
    assert observed.admission_read == nil and observed.running == %{} and observed.lease_claims == %{}
    assert observed.candidate_fetch_error == {:dispatch_audit_pending, f.workspace}
    assert File.read!(f.state_path) == before.snapshot
    assert File.read!(f.marker_path) == before.marker
    assert File.read!(f.ticket.ledger_path) == before.ledger
    refute File.exists?(f.storage.lease_path)
  end

  test "rejected dispatch diagnoses in an owned supervised operation without acquiring custody", c do
    f = admitted!(c.root, "implement")
    issue = runtime_issue(f)
    before = physical!(f)
    runtime = runtime_state(issue)
    pending = SymphonyElixir.Orchestrator.dispatch_runtime_issue(runtime, issue, nil)
    assert %{purpose: :interrupted_dispatch, issue: ^issue, workspace: workspace} = pending.admission_read
    assert workspace == f.workspace
    assert pending.running == %{}
    assert pending.lease_claims == %{}
    ref = pending.admission_read.ref
    assert_receive {:tracker_read_result, ^ref, {:ok, %{stage: "blocked"}} = result}, 5_000
    monitor = pending.admission_read.monitor
    guardian = pending.admission_read.pid
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}
    assert {:noreply, observed} = SymphonyElixir.Orchestrator.handle_info({:tracker_read_result, ref, result}, pending)
    assert observed.admission_read == nil
    assert observed.running == %{}
    assert observed.lease_claims == %{}
    assert {:dispatch_audit_failed, id, {:dispatch_audit_pending, workspace}} = observed.candidate_fetch_error
    assert id == issue.id and workspace == f.workspace
    after_bytes = physical!(f)
    assert after_bytes.marker == before.marker and after_bytes.lease == before.lease
    assert {:ok, %{stage: "blocked", resume_stage: "implement"}} = RunStateStore.load(f.workspace)
    refute Enum.any?(rows!(f), &(&1["event_type"] in ["dispatch.finished", "lease.taken_over"]))
  end

  test "a supervised diagnostic persistence failure remains explicit and grants no custody", c do
    f = admitted!(c.root, "validate")
    issue = runtime_issue(f)
    lock = f.ticket.ledger_path <> ".checked.lock"
    File.mkdir!(lock)
    on_exit(fn -> if File.dir?(lock), do: File.rmdir!(lock) end)
    before = physical!(f)
    pending = SymphonyElixir.Orchestrator.dispatch_runtime_issue(runtime_state(issue), issue, nil)
    assert %{purpose: :interrupted_dispatch} = pending.admission_read
    ref = pending.admission_read.ref
    assert_receive {:tracker_read_result, ^ref, {:error, %RunLedger.PersistenceError{phase: :lock}} = result}, 5_000
    assert {:noreply, observed} = SymphonyElixir.Orchestrator.handle_info({:tracker_read_result, ref, result}, pending)
    assert {:dispatch_audit_failed, id, {:interrupted_dispatch_diagnostic_failed, {:dispatch_audit_pending, workspace}, %RunLedger.PersistenceError{phase: :lock}}} = observed.candidate_fetch_error
    assert id == issue.id and workspace == f.workspace
    assert observed.admission_read == nil and observed.running == %{} and observed.lease_claims == %{}
    assert physical!(f) == before
  end

  test "pending diagnosis never replaces an existing reader or an active worker", c do
    f = admitted!(c.root, "implement")
    issue = runtime_issue(f)
    before = physical!(f)
    reader = %{purpose: :poll, ref: make_ref(), pid: self()}
    runtime = %{runtime_state(issue) | admission_read: reader}
    observed = SymphonyElixir.Orchestrator.dispatch_runtime_issue(runtime, issue, nil)
    assert observed.admission_read == reader
    assert observed.running == %{} and observed.lease_claims == %{}
    assert physical!(f) == before
    running = %{issue.id => %{pid: self(), workspace_path: f.workspace, identifier: issue.identifier}}
    runtime = %{runtime_state(issue) | running: running}
    observed = SymphonyElixir.Orchestrator.dispatch_runtime_issue(runtime, issue, nil)
    assert observed.running == running
    assert observed.admission_read == nil and observed.lease_claims == %{}
    assert physical!(f) == before
    refute_receive {:tracker_read_result, _, _}
  end

  test "retry controls cannot clear a retained pending diagnostic or mutate its tracker", c do
    f = admitted!(c.root, "validate")
    issue = runtime_issue(f)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert {:ok, _} = DispatchAudit.block_interrupted(f.workspace, issue)
    before = physical!(f)
    runtime = runtime_state(issue)
    assert {:error, {:dispatch_audit_pending, workspace}} = SymphonyElixir.Orchestrator.Controls.maybe_resume_blocked_issue(runtime, issue)
    assert workspace == f.workspace

    operation = %{
      ref: make_ref(),
      deadline: System.monotonic_time(:millisecond) + 5_000,
      action: :retry_now,
      identifier: issue.identifier,
      args: [],
      phase: :ready,
      issue: issue,
      workspace: f.workspace,
      context: Config.tracker_read_context(),
      effect?: false
    }

    assert {:rejected, ^operation, payload, observed} = SymphonyElixir.Orchestrator.Controls.advance(runtime, operation, :start)
    assert payload.ok == false
    assert payload.dispatch_outcome == "deferred"
    assert inspect(payload.error) =~ "dispatch_audit_pending"
    assert observed.running == %{} and observed.lease_claims == %{}
    assert physical!(f) == before
    assert Application.fetch_env!(:symphony_elixir, :memory_tracker_issues) == [issue]
  end

  test "retry access permits only the exact current owned worker and leaves evidence unchanged", c do
    f = admitted!(c.root, "validate")
    issue = runtime_issue(f)
    token = f.acquired.token
    assert {:ok, _} = LeaseManager.refresh_token(token)
    custody_ref = make_ref()
    context = %{owner: self(), worker: self(), issue_id: issue.id, ticket: f.ticket, lease_token: token}

    entry = %{
      issue: issue,
      pid: self(),
      ref: make_ref(),
      workspace_path: f.workspace,
      custody_ref: custody_ref,
      dispatch_ticket: f.ticket,
      lease_token: token,
      agent_execution: %{context: context, terminal: nil}
    }

    claim = %{workspace: f.workspace, token: token, custody_ref: custody_ref, holder: :running}
    runtime = %{runtime_state(issue) | lease_owner: token.owner, running: %{issue.id => entry}, lease_claims: %{issue.id => claim}}
    before = physical!(f)
    assert :ok = SymphonyElixir.Orchestrator.ensure_retry_dispatch_access(runtime, issue, f.workspace)
    assert physical!(f) == before

    foreign = put_in(runtime.running[issue.id].agent_execution.context.owner, nil)
    assert {:error, {:dispatch_audit_pending, _}} = SymphonyElixir.Orchestrator.ensure_retry_dispatch_access(foreign, issue, f.workspace)
    assert physical!(f) == before

    stopped = put_in(runtime.running[issue.id].agent_execution.terminal, :cancelled)
    assert {:error, {:retry_execution_stopped, :cancelled}} = SymphonyElixir.Orchestrator.ensure_retry_dispatch_access(stopped, issue, f.workspace)
    assert physical!(f) == before

    expired = Jason.decode!(before.lease) |> Map.put("updated_at", token.acquired_at)
    File.write!(f.storage.lease_path, Jason.encode!(expired))
    expired_bytes = physical!(f)
    assert {:error, :lease_expired} = SymphonyElixir.Orchestrator.ensure_retry_dispatch_access(runtime, issue, f.workspace)
    assert physical!(f) == expired_bytes
  end

  defp runtime_issue(f), do: %SymphonyElixir.Linear.Issue{id: f.issue.id, identifier: f.issue.identifier, title: "Retained interrupted dispatch", state: "In Progress", source: :tracker}

  defp runtime_state(issue),
    do: %SymphonyElixir.Orchestrator.State{
      lease_owner: "diagnosis-owner",
      max_concurrent_agents: 1,
      last_candidate_issues: [issue],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
    }

  def lock_after_intent(_event, _measurements, metadata, {parent, issue_id, lock}) do
    if metadata[:event_type] == "stage.transition.requested" and metadata[:issue_id] == issue_id do
      File.mkdir!(lock)
      send(parent, {:block_intent_locked, metadata[:event_id]})
    end
  end

  defp admitted!(root, stage) do
    identifier = "INTERRUPTED-#{System.unique_integer([:positive])}"
    issue = %{id: String.downcase(identifier), identifier: identifier}
    workspace = Workspace.path_for_issue(identifier)
    assert Path.dirname(workspace) == root
    assert {:ok, storage} = LeaseManager.capture_storage(issue.id)
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, identifier, "interrupted-owner", storage: storage)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, stage, %{
               issue_id: issue.id,
               issue_identifier: identifier,
               resume_context: %{retained_context: "checkpoint-context"},
               last_decision_summary: "Retained pre-crash decision",
               last_commit_sha: "retained-commit",
               last_validation: %{status: "retained-validation"}
             })

    assert {:ok, _state} = RunStateStore.record_token_usage(workspace, issue, %{input_tokens: 13, output_tokens: 7, total_tokens: 20})
    assert {:ok, ticket} = DispatchAudit.begin(workspace, %{issue_id: issue.id, issue_identifier: identifier, stage: stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}})
    sentinel_path = Path.join(workspace, "checkpoint-sentinel")
    File.write!(sentinel_path, "unpublished checkpoint evidence")
    at = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
    expired = acquired.lease |> Map.put("acquired_at", at) |> Map.put("updated_at", at)
    File.write!(storage.lease_path, Jason.encode!(expired))
    assert {:ok, ^expired} = LeaseManager.read_at(storage)
    assert LeaseManager.reclaimable?(expired)

    %{
      workspace: workspace,
      issue: issue,
      storage: storage,
      acquired: %{acquired | token: %{acquired.token | acquired_at: at}},
      ticket: ticket,
      marker_path: Path.join(DispatchAudit.marker_directory(workspace), "marker.json"),
      state_path: RunStateStore.state_path(workspace),
      sentinel_path: sentinel_path
    }
  end

  defp physical!(f),
    do: %{
      snapshot: File.read!(f.state_path),
      marker: File.read!(f.marker_path),
      lease: File.read!(f.storage.lease_path),
      ledger: File.read!(f.ticket.ledger_path),
      sentinel: File.read!(f.sentinel_path)
    }

  defp rows!(f), do: f.ticket.ledger_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp canonical(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp fault!(f, :issue), do: f
  defp fault!(f, :run), do: rewrite!(f.state_path, &Map.put(&1, "run_id", "run_other"))
  defp fault!(f, :marker), do: File.write!(f.marker_path, "{corrupt")
  defp fault!(f, :marker_prepared), do: rewrite!(f.marker_path, &Map.put(&1, "status", "prepared"))
  defp fault!(f, :lease), do: File.write!(f.storage.lease_path, "{corrupt")
  defp fault!(f, :lease_pending), do: rewrite!(f.storage.lease_path, &Map.put(&1, "audit_pending", %{operation_id: "pending-custody"}))
  defp fault!(f, :owner), do: rewrite!(f.storage.lease_path, &Map.put(&1, "owner", "different-owner"))
  defp fault!(f, :snapshot), do: File.write!(f.state_path, "{corrupt")
  defp fault!(f, :snapshot_shape), do: File.write!(f.state_path, "[]")
  defp fault!(f, :blocked), do: rewrite!(f.state_path, &(&1 |> Map.put("stage", "blocked") |> Map.put("stop_reason", %{code: "proof_failed"})))
  defp fault!(f, :deploy), do: File.mkdir!(SymphonyElixir.DeployAudit.marker_directory(f.workspace))

  defp fault!(f, :symlink) do
    retained = f.state_path <> ".retained"
    File.rename!(f.state_path, retained)
    File.ln_s!(retained, f.state_path)
  end

  defp fault!(f, :finished) do
    assert {:ok, _} =
             RunLedger.record_checked("dispatch.finished", %{issue_id: f.issue.id, issue_identifier: f.issue.identifier, metadata: %{dispatch_id: f.ticket.dispatch_id, run_id: f.ticket.run_id}})
  end

  defp rewrite!(path, fun), do: File.write!(path, Jason.encode!(fun.(Jason.decode!(File.read!(path)))))
end
