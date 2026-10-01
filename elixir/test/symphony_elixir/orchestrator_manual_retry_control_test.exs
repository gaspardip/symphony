defmodule SymphonyElixir.OrchestratorManualRetryControlTest do
  use SymphonyElixir.TestSupport
  @moduletag timeout: 30_000

  alias SymphonyElixir.{DispatchAudit, LeaseManager, ManualIssueStore, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.RunLedger.CheckedStorage

  defmodule Driver do
    use GenServer
    def start_link(runtime, observer), do: GenServer.start_link(__MODULE__, {runtime, observer})
    @impl true
    def init({runtime, observer}), do: {:ok, %{runtime: runtime, observer: observer, gate: nil}}
    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

    def handle_call(:deliver_gate, _from, %{gate: gate} = state) when not is_nil(gate) do
      {:noreply, runtime} = Orchestrator.handle_info(gate, state.runtime)
      {:reply, :ok, %{state | runtime: runtime, gate: nil}}
    end

    def handle_call(message, from, state) do
      case Orchestrator.handle_call(message, from, state.runtime) do
        {:reply, reply, runtime} -> {:reply, reply, %{state | runtime: runtime}}
        {:noreply, runtime} -> {:noreply, %{state | runtime: runtime}}
      end
    end

    @impl true
    def handle_info({:authorize_dispatch, _, _, _} = message, state) do
      send(state.observer, {:held_gate, self(), message})
      {:noreply, %{state | gate: message}}
    end

    def handle_info(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end
  end

  setup do
    pause_default_scheduler!()
    root = Path.join(System.tmp_dir!(), "manual-retry-current-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\nprintf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n")
    File.chmod!(Path.join(bin, "gh"), 0o700)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)

    config = [
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      tracker_required_labels: [],
      manual_enabled: true,
      manual_store_root: Path.join(root, "manual"),
      workspace_root: Path.join(root, "workspaces"),
      runner_install_root: Path.join(root, "runner"),
      max_concurrent_agents: 1,
      company_author_profile_path: Path.join(root, "author.json"),
      company_credential_registry_path: Path.join(root, "credentials.json"),
      codex_command: "/usr/bin/false",
      hook_before_run: "/usr/bin/false",
      hook_timeout_ms: 5_000,
      observability_tracing_enabled: false
    ]

    write_workflow_file!(Workflow.workflow_file_path(), config)
    assert :ok = Config.validate!()

    assert {:ok, submitted} =
             ManualIssueStore.submit(%{
               "id" => "manual-retry",
               "identifier" => "MANUAL-RETRY",
               "title" => "Checked local resume",
               "acceptance_criteria" => ["Keep the confirmed resume and observed writer error"]
             })

    assert :ok = ManualIssueStore.update_issue_state(submitted.id, "Blocked")
    assert {:ok, %Issue{source: :manual, state: "Blocked"} = issue} = ManualIssueStore.fetch_issue_by_id(submitted.id)
    workspace = Workspace.path_for_issue(issue)
    resume = %{focus: "lib/retained.ex", already_learned: "Keep the current checkpoint"}
    assert {:ok, _} = RunStateStore.transition(workspace, "await_checks", %{issue_id: issue.id, issue_identifier: issue.identifier, issue_source: :manual, resume_context: resume})
    [record] = Path.wildcard(Path.join(config[:manual_store_root], "*.json"))
    original = File.read!(record)
    File.chmod!(record, 0o400)
    assert {:error, :eacces} = File.write(record, original)

    runtime = %State{
      lease_owner: "manual-retry-owner",
      max_concurrent_agents: 1,
      poll_interval_ms: 60_000,
      healing_poll_interval_ms: 60_000,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:ok, owner} = Driver.start_link(runtime, self())
    Process.unlink(owner)
    assert {:module, ManualIssueStore} = Code.ensure_loaded(ManualIssueStore)
    assert {:traced, false} = :erlang.trace_info({ManualIssueStore, :update_issue_state, 2}, :traced)
    assert 1 = :erlang.trace_pattern({ManualIssueStore, :update_issue_state, 2}, true, [:local])
    assert 1 = :erlang.trace(owner, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({ManualIssueStore, :update_issue_state, 2}, false, [:local])
      cleanup_owner!(owner)
      File.chmod!(Path.dirname(RunStateStore.state_path(workspace)), 0o700)
      if File.exists?(record), do: File.chmod!(record, 0o600)
      System.put_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    %{root: root, config: config, owner: owner, issue: issue, workspace: workspace, record: record, original: original, resume: resume, ledger: RunLedger.ledger_file_path()}
  end

  test "a real successful manual write keeps the historical response and operator metadata", c do
    File.chmod!(c.record, 0o600)
    assert :ok = File.write(c.record, c.original)
    task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, c.issue.identifier) end)
    owner = c.owner
    assert_receive {:held_gate, ^owner, {:authorize_dispatch, _, _, _}}, 2_000
    state = runtime(c)
    entry = Map.fetch!(state.running, c.issue.id)
    claim = Map.fetch!(state.lease_claims, c.issue.id)
    assert Process.alive?(entry.pid)
    assert entry.issue.state == "Merging"
    assert entry.custody_ref == claim.custody_ref
    assert entry.lease_token == claim.token
    assert :ok = LeaseManager.ensure_current(claim.token)
    assert {:ok, %Issue{state: "Merging"}} = ManualIssueStore.fetch_issue_by_id(c.issue.id)
    assert :ok = GenServer.call(owner, :deliver_gate)
    assert %{ok: true, dispatch_outcome: "dispatched", ledger_event_id: event_id} = reply = Task.await(task, 5_000)
    refute Map.has_key?(reply, :manual_resume)
    assert {:ok, rows, _} = CheckedStorage.entries_checked(c.ledger)
    assert [event] = Enum.filter(rows, &(&1["event_id"] == event_id))
    assert event["event_type"] == "operator.action"
    assert event["issue_id"] == c.issue.id
    assert event["metadata"]["action"] == "retry_now"
    assert event["metadata"]["dispatch_outcome"] == "dispatched"
    refute Map.has_key?(event["metadata"], "manual_resume")
    assert writes(c) == [[c.issue.id, "Merging"]]
  end

  test "a real denied manual write retains the confirmed resume through genuine admission and reports the error", c do
    task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, c.issue.identifier) end)
    owner = c.owner
    assert_receive {:held_gate, ^owner, {:authorize_dispatch, _, _, _}}, 2_000
    state = runtime(c)
    entry = Map.fetch!(state.running, c.issue.id)
    claim = Map.fetch!(state.lease_claims, c.issue.id)
    assert Process.alive?(entry.pid)
    assert entry.issue.state == "Merging"
    assert entry.custody_ref == claim.custody_ref
    assert entry.lease_token == claim.token
    assert :ok = LeaseManager.ensure_current(claim.token)
    assert {:ok, raw} = RunStateStore.load(c.workspace)
    assert raw.run_id == entry.dispatch_ticket.run_id
    assert raw.resume_context.focus == c.resume.focus
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(c.workspace)
    assert File.read!(c.record) == c.original
    assert :ok = GenServer.call(owner, :deliver_gate)
    assert %{ok: true, dispatch_outcome: "dispatched", manual_resume: evidence, ledger_event_id: event_id} = Task.await(task, 5_000)
    assert evidence == %{writer_error: "eacces", store_updated: false, stage: "await_checks", target_state: "Merging"}
    assert {:ok, rows, _} = CheckedStorage.entries_checked(c.ledger)
    assert [event] = Enum.filter(rows, &(&1["event_id"] == event_id))
    assert event["event_type"] == "operator.action"
    assert event["issue_id"] == c.issue.id
    assert event["metadata"]["manual_resume"] == Jason.decode!(Jason.encode!(evidence))
    assert writes(c) == [[c.issue.id, "Merging"]]
    assert File.read!(c.record) == c.original
  end

  for drift <- [:stage, :resume_context, :identity, :fingerprint, :manual_corrupt, :manual_missing, :manual_identity] do
    @tag drift: drift
    test "#{drift} during the real checked refresh cannot reuse the old manual resume", c do
      barrier = hold_manual_refresh!(c)
      task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, c.issue.identifier) end)
      owner = c.owner
      assert_receive {:manual_refresh_waiting, ^owner, ^barrier}, 2_000

      try do
        assert writes(c) == [[c.issue.id, "Merging"]]
        assert {:ok, before} = RunStateStore.load(c.workspace)
        assert before.stage == "await_checks"
        mutate_drift!(c, c.drift)
        bytes_after_mutation = File.read!(RunStateStore.state_path(c.workspace))
        send(owner, {:release_manual_refresh, barrier})
        assert %{ok: false, error: "control_invalidated", manual_resume: %{writer_error: "eacces", store_updated: false}} = Task.await(task, 5_000)
        assert File.read!(RunStateStore.state_path(c.workspace)) == bytes_after_mutation
        assert_no_admission(c)
        assert writes(c) == []
      after
        send(owner, {:release_manual_refresh, barrier})
      end
    end
  end

  test "a physical snapshot write failure cannot grant the local manual resume", c do
    dir = Path.dirname(RunStateStore.state_path(c.workspace))
    before = File.read!(RunStateStore.state_path(c.workspace))
    File.chmod!(dir, 0o500)

    try do
      assert {:error, :eacces} = File.write(Path.join(dir, "permission-probe"), "probe")
      assert %{ok: false} = Orchestrator.retry_issue_now(c.owner, c.issue.identifier)
      assert File.read!(RunStateStore.state_path(c.workspace)) == before
      assert File.read!(c.record) == c.original
      assert writes(c) == []
      assert_no_admission(c)
    after
      File.chmod!(dir, 0o700)
    end
  end

  test "caller DOWN during the checked refresh cannot continue a confirmed local resume", c do
    barrier = hold_manual_refresh!(c)
    {caller, monitor} = spawn_monitor(fn -> Orchestrator.retry_issue_now(c.owner, c.issue.identifier) end)
    owner = c.owner
    assert_receive {:manual_refresh_waiting, ^owner, ^barrier}, 2_000

    try do
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 2_000
      before = File.read!(RunStateStore.state_path(c.workspace))
      send(owner, {:release_manual_refresh, barrier})
      assert_no_admission(c)
      assert File.read!(RunStateStore.state_path(c.workspace)) == before
      assert writes(c) == [[c.issue.id, "Merging"]]
    after
      send(owner, {:release_manual_refresh, barrier})
    end
  end

  test "the original real deadline expires during checked refresh without admission or another write", c do
    barrier = hold_manual_refresh!(c)
    request = %{ref: make_ref(), deadline: System.monotonic_time(:millisecond) + 1_000, action: :retry_now, identifier: c.issue.identifier, args: []}
    task = Task.async(fn -> GenServer.call(c.owner, {:control, request}, 5_000) end)
    owner = c.owner
    assert_receive {:manual_refresh_waiting, ^owner, ^barrier}, 2_000

    try do
      remaining = request.deadline - System.monotonic_time(:millisecond)
      if remaining > 0, do: Process.sleep(remaining)
      assert System.monotonic_time(:millisecond) >= request.deadline
      before = File.read!(RunStateStore.state_path(c.workspace))
      send(owner, {:release_manual_refresh, barrier})
      assert %{ok: false, error: "control_deadline_exceeded", manual_resume: %{writer_error: "eacces"}} = Task.await(task, 5_000)
      assert File.read!(RunStateStore.state_path(c.workspace)) == before
      assert writes(c) == [[c.issue.id, "Merging"]]
      assert_no_admission(c)
    after
      send(owner, {:release_manual_refresh, barrier})
    end
  end

  defp hold_manual_refresh!(c) do
    barrier = make_ref()
    handler = {__MODULE__, barrier}

    assert :ok =
             :telemetry.attach(
               handler,
               [:symphony, :issue_source, :start],
               fn _, _, metadata, {observer, owner, ref} ->
                 if self() == owner and metadata.source == "manual" and metadata.operation == "lookup" do
                   key = {__MODULE__, ref}
                   count = Process.get(key, 0) + 1
                   Process.put(key, count)

                   if count == 1 do
                     send(observer, {:manual_refresh_waiting, self(), ref})

                     receive do
                       {:release_manual_refresh, ^ref} -> :ok
                     after
                       5_000 -> raise "manual refresh barrier was not released"
                     end
                   end
                 end
               end,
               {self(), c.owner, barrier}
             )

    on_exit(fn -> :telemetry.detach(handler) end)
    barrier
  end

  defp mutate_drift!(c, :stage), do: assert({:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :stage, "done")))
  defp mutate_drift!(c, :resume_context), do: assert({:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :resume_context, %{focus: "other"})))
  defp mutate_drift!(c, :identity), do: assert({:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :issue_identifier, "OTHER")))

  defp mutate_drift!(c, :fingerprint) do
    before = Config.tracker_read_context().fingerprint
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(c.config, :tracker_project_slug, "changed"))
    refute Config.tracker_read_context().fingerprint == before
  end

  defp mutate_drift!(c, :manual_corrupt) do
    File.chmod!(c.record, 0o600)
    File.write!(c.record, "{")
  end

  defp mutate_drift!(c, :manual_missing), do: File.rm!(c.record)

  defp mutate_drift!(c, :manual_identity) do
    record = Jason.decode!(c.original)
    File.chmod!(c.record, 0o600)
    File.write!(c.record, Jason.encode!(put_in(record, ["issue", "identifier"], "OTHER")))
  end

  defp assert_no_admission(c) do
    assert runtime(c).running == %{}
    refute_receive {:held_gate, _, _}, 30
    assert {:error, :missing} = LeaseManager.read(c.issue.id)
    assert {:ok, rows, _} = CheckedStorage.entries_checked(c.ledger)
    refute Enum.any?(rows, &(&1["event_type"] in ["dispatch.started", "operator.action"] and &1["issue_id"] == c.issue.id))
  end

  defp writes(c) do
    ref = :erlang.trace_delivered(c.owner)
    owner = c.owner
    assert_receive {:trace_delivered, ^owner, ^ref}, 1_000
    collect_writes(owner, [])
  end

  defp collect_writes(owner, calls) do
    receive do
      {:trace, ^owner, :call, {ManualIssueStore, :update_issue_state, args}} -> collect_writes(owner, [args | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp runtime(c), do: GenServer.call(c.owner, :runtime, 500)

  defp cleanup_owner!(owner) do
    if Process.alive?(owner) do
      :ok = :sys.suspend(owner)
      %{runtime: runtime} = :sys.get_state(owner)
      readers = Enum.reject([runtime.admission_read, runtime.tracker_poll_read], &is_nil/1)
      refs = Enum.map(readers, &{&1.pid, Process.monitor(&1.pid)})
      Enum.each(runtime.lease_claims, fn {_, claim} -> if is_reference(claim.timer), do: Process.cancel_timer(claim.timer) end)
      GenServer.stop(owner, :normal, 5_000)

      Enum.each(runtime.running, fn {_, entry} ->
        if Process.alive?(entry.pid), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid)
      end)

      Enum.each(refs, fn {pid, ref} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000 end)
    end
  end

  defp pause_default_scheduler! do
    if pid = Process.whereis(Orchestrator) do
      wait_default_idle!(pid, System.monotonic_time(:millisecond) + 2_000)
      assert :ok = :sys.suspend(pid)
      on_exit(fn -> assert :ok = :sys.resume(pid) end)
    end
  end

  defp wait_default_idle!(pid, deadline) do
    state = :sys.get_state(pid, 500)

    if state.running == %{} and is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and is_nil(state.admission_read) and state.tracker_poll_pending == [] and
         not state.poll_check_in_progress do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "default scheduler must be idle"
      Process.sleep(5)
      wait_default_idle!(pid, deadline)
    end
  end
end
