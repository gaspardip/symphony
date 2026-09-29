defmodule SymphonyElixir.OrchestratorPromotionAsyncTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{LeaseManager, RunLedger, RunStateStore, TrackerReader}
  alias SymphonyElixir.Orchestrator.State

  defmodule HeldClient do
    def fetch_issue_states_by_ids(ids) do
      owner = Application.fetch_env!(:symphony_elixir, :promotion_test_owner)
      send(owner, {:promotion_read, self(), ids})

      receive do
        {:answer, result} -> result
      after
        5_000 -> {:error, :promotion_fixture_timeout}
      end
    end
  end

  defmodule Driver do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:dispatch, issue}, _from, state),
      do: {:reply, :ok, SymphonyElixir.Orchestrator.dispatch_runtime_issue(state, issue, 1)}

    def handle_call(:state, _from, state), do: {:reply, state, state}
    def handle_call(request, from, state), do: SymphonyElixir.Orchestrator.handle_call(request, from, state)
    @impl true
    def handle_info(message, state), do: SymphonyElixir.Orchestrator.handle_info(message, state)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "promotion-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\nprintf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n")
    File.chmod!(Path.join(bin, "gh"), 0o700)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    previous = Application.fetch_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, HeldClient)
    Application.put_env(:symphony_elixir, :promotion_test_owner, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "fixture",
      tracker_project_slug: "fixture",
      tracker_required_labels: [],
      workspace_root: Path.join(root, "workspaces"),
      runner_install_root: Path.join(root, "runner"),
      max_concurrent_agents: 1,
      codex_command: "/usr/bin/false",
      observability_tracing_enabled: false
    )

    issue = %Issue{id: "promotion", identifier: "PROMOTION-1", title: "Promotion", state: "In Progress", source: :tracker, labels: []}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    assert {:ok, _} = RunStateStore.transition(workspace, "await_checks", %{issue_id: issue.id, issue_identifier: issue.identifier})
    state = %State{lease_owner: "promotion-owner", max_concurrent_agents: 1, agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}}
    {:ok, driver} = Driver.start_link(state)
    Process.unlink(driver)

    on_exit(fn ->
      if Process.alive?(driver) do
        current = GenServer.call(driver, :state)
        operations = Enum.reject([current.admission_read, current.tracker_poll_read], &is_nil/1)

        :sys.replace_state(driver, fn state ->
          Enum.each(operations, fn operation -> :ok = TrackerReader.cancel(operation) end)
          Enum.each(state.lease_claims, fn {_id, claim} -> if is_reference(claim.timer), do: Process.cancel_timer(claim.timer) end)
          state
        end)

        readers = Enum.map(operations, & &1.pid)
        workers = Enum.map(current.running, fn {_id, entry} -> entry.pid end)
        refs = Enum.map(readers ++ workers, &{&1, Process.monitor(&1)})
        GenServer.stop(driver)
        Enum.each(workers, fn pid -> if Process.alive?(pid), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) end)
        Enum.each(refs, fn {pid, ref} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000 end)
      end

      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :linear_client_module, value)
        :error -> Application.delete_env(:symphony_elixir, :linear_client_module)
      end

      System.put_env("PATH", previous_path)
      Application.delete_env(:symphony_elixir, :promotion_test_owner)
      File.rm_rf!(root)
    end)

    %{driver: driver, issue: issue, workspace: workspace, root: root}
  end

  test "passive repair retains a single lease reservation while serving snapshots", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    state = GenServer.call(c.driver, :state, 500)
    assert is_map(Orchestrator.snapshot(c.driver, 500))
    assert %{purpose: :promotion, initial_stage: "await_checks", stage: "checkout"} = state.admission_read
    assert state.running == %{}
    assert Orchestrator.available_slots(state) == 0
    claim = state.lease_claims[c.issue.id]
    assert {:ok, lease} = LeaseManager.read_at(claim.token.storage)
    assert lease["lease_generation"] == claim.token.lease_generation
    assert claim.deadline == claim.started_at_ms + div(claim.token.storage.ttl_ms, 2)
    send(reader, {:answer, {:ok, [%{c.issue | state: "Done"}]}})
    finished = wait_state!(c.driver, &is_nil(&1.admission_read))
    assert finished.candidate_fetch_error == {:dispatch_no_longer_eligible, c.issue.id}
    assert finished.running == %{}
    assert finished.lease_claims == %{}
    assert {:error, :missing} = LeaseManager.read_at(claim.token.storage)
    assert File.exists?(RunStateStore.state_path(c.workspace))
    refute Enum.any?(RunLedger.recent_entries(), &(&1["event_type"] == "dispatch.started"))
  end

  test "promotion reports a missing tracker issue as no longer eligible", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    pending = GenServer.call(c.driver, :state)
    claim = pending.lease_claims[c.issue.id]
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    send(reader, {:answer, {:ok, []}})
    finished = wait_state!(c.driver, &is_nil(&1.admission_read))
    assert finished.candidate_fetch_error == {:dispatch_no_longer_eligible, c.issue.id}
    assert finished.running == %{}
    assert finished.retry_attempts == %{}
    assert finished.lease_claims == %{}
    refute MapSet.member?(finished.claimed, c.issue.id)
    assert {:error, :missing} = LeaseManager.read_at(claim.token.storage)
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    refute Enum.any?(RunLedger.recent_entries(), &(&1["event_type"] == "dispatch.started"))
  end

  test "manual promotion preserves a real empty-store refresh through the dispatch gate", c do
    manual = manual_promotion_fixture!(c, "In Progress")
    backup = manual.record <> ".saved"
    File.rename!(manual.record, backup)

    try do
      assert {:ok, []} = SymphonyElixir.IssueSource.fetch_issue_states_by_ids([manual.issue.id], Config.tracker_read_context())
      observe_manual_promotion_reads!(c.driver)

      try do
        assert :ok = GenServer.call(c.driver, {:dispatch, manual.issue})
        assert_manual_promotion_gate!(c.driver, manual, "In Progress")
      after
        release_manual_promotion_hook!(manual)
      end
    after
      File.rename!(backup, manual.record)
    end
  end

  test "public retry preserves a manual blocked-store resume through the dispatch gate", c do
    manual = manual_promotion_fixture!(c, "Blocked")
    original = File.read!(manual.record)
    mode = File.stat!(manual.record).mode
    File.chmod!(manual.record, 0o400)

    try do
      # Use the same bytes even if the environment unexpectedly permits writes.
      # This must be a real failure, not a mocked ManualIssueStore result.
      assert {:error, :eacces} = File.write(manual.record, original)
      assert {:ok, [%Issue{state: "Blocked"}]} = SymphonyElixir.IssueSource.fetch_issue_states_by_ids([manual.issue.id], Config.tracker_read_context())
      observe_manual_promotion_reads!(c.driver)

      try do
        assert %{ok: true, action: "retry_now"} = Orchestrator.retry_issue_now(c.driver, manual.issue.identifier)
        assert_manual_promotion_gate!(c.driver, manual, "Merging")
        assert File.read!(manual.record) == original
      after
        release_manual_promotion_hook!(manual)
      end
    after
      File.chmod!(manual.record, Bitwise.band(mode, 0o7777))
      File.write!(manual.record, original)
    end
  end

  for holder <- [:pending, :gated], boundary <- [:state, :company] do
    @tag capacity_holder: holder, capacity_boundary: boundary
    test "#{holder} reserves exactly one #{boundary} slot", c do
      write_capacity_workflow!(c, c.capacity_boundary, 1)
      :sys.replace_state(c.driver, &%{&1 | max_concurrent_agents: 3})

      case c.capacity_holder do
        :pending ->
          assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
          assert_receive {:promotion_read, _reader, ["promotion"]}, 2_000

        :gated ->
          seed_gated_reservation!(c)
      end

      reserved = GenServer.call(c.driver, :state)
      assert reserved.lease_claims[c.issue.id].holder == c.capacity_holder
      assert Orchestrator.available_slots(reserved) == 2
      candidate = %{c.issue | id: "capacity-other", identifier: "CAPACITY-2"}
      refute Orchestrator.should_dispatch_issue_for_test(candidate, reserved)

      if c.capacity_boundary == :state do
        assert Orchestrator.should_dispatch_issue_for_test(%{candidate | state: "Todo"}, reserved)
      end

      # Raising only the isolated limit proves that the same claim plus reader
      # (pending) or running entry (gated) consumes one slot, not two.
      write_capacity_workflow!(c, c.capacity_boundary, 2)
      assert Orchestrator.should_dispatch_issue_for_test(candidate, reserved)
      assert GenServer.call(c.driver, :state).lease_claims == reserved.lease_claims
    end
  end

  test "promotion rejects a legacy snapshot identified while its read was pending", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    pending = GenServer.call(c.driver, :state)
    assert pending.admission_read.run_identity == %{}
    claim = pending.lease_claims[c.issue.id]
    assert {:ok, legacy} = RunStateStore.load_checked(c.workspace, c.issue)
    refute Map.has_key?(legacy, :run_id)

    # Establish a valid I1 binding through a separate, explicitly closed
    # admission. No worker is created by this fixture admission.
    assert {:ok, ticket} =
             SymphonyElixir.DispatchAudit.begin(c.workspace, %{
               issue_id: c.issue.id,
               issue_identifier: c.issue.identifier,
               metadata: %{owner: claim.token.owner, epoch: claim.token.epoch}
             })

    assert :ok = SymphonyElixir.DispatchAudit.finish(ticket, :not_started)
    assert {:ok, identified} = RunStateStore.load_checked(c.workspace, c.issue)
    assert identified.run_id == ticket.run_id
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    starts = Enum.filter(RunLedger.recent_entries(), &(&1["event_type"] == "dispatch.started"))
    assert length(starts) == 1
    send(reader, {:answer, {:ok, [c.issue]}})
    finished = wait_state!(c.driver, &is_nil(&1.admission_read))
    assert finished.candidate_fetch_error == {:promotion_failed, :promotion_run_changed}
    assert finished.running == %{}
    assert finished.lease_claims == %{}
    assert {:error, :missing} = LeaseManager.read_at(claim.token.storage)
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    assert Enum.filter(RunLedger.recent_entries(), &(&1["event_type"] == "dispatch.started")) == starts
  end

  for {label, fields, expected} <- [
        {"partial", %{"run_id" => "run_partial"}, :invalid_run_identity},
        {"pending", %{"run_identity_pending" => %{}}, :run_identity_pending}
      ] do
    @tag identity_fields: fields, identity_error: expected
    test "promotion denies #{label} identity introduced during its read", c do
      assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
      assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
      pending = GenServer.call(c.driver, :state)
      assert pending.admission_read.run_identity == %{}
      claim = pending.lease_claims[c.issue.id]
      path = RunStateStore.state_path(c.workspace)
      changed = path |> File.read!() |> Jason.decode!() |> Map.merge(c.identity_fields) |> Jason.encode!()
      File.write!(path, changed)
      assert {:error, reason} = RunStateStore.load_checked(c.workspace, c.issue)
      assert reason == c.identity_error
      send(reader, {:answer, {:ok, [c.issue]}})
      finished = wait_state!(c.driver, &is_nil(&1.admission_read))
      assert finished.candidate_fetch_error == {:promotion_failed, c.identity_error}
      assert finished.running == %{}
      assert finished.lease_claims == %{}
      assert {:error, :missing} = LeaseManager.read_at(claim.token.storage)
      assert File.read!(path) == changed
      refute Enum.any?(RunLedger.recent_entries(), &(&1["event_type"] == "dispatch.started"))
      refute Enum.any?(RunLedger.recent_entries(), &String.starts_with?(&1["event_type"], "run.identity."))
    end
  end

  test "cancelled old promotion preserves same-owner successor lease snapshot and header", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, _reader, ["promotion"]}, 2_000
    before = GenServer.call(c.driver, :state)
    claim = before.lease_claims[c.issue.id]
    assert {:ok, :released} = LeaseManager.release_token(claim.token)
    assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, claim.token.owner, storage: claim.token.storage)
    assert successor.token.epoch == claim.token.epoch
    refute successor.token.lease_generation == claim.token.lease_generation
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(successor.lease))
    header = Path.join(c.workspace, "AGENTS.md")
    File.write!(header, "successor header")
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    lease_bytes = File.read!(claim.token.storage.lease_path)
    :sys.replace_state(c.driver, &Orchestrator.terminate_running_issue(&1, c.issue.id, false))
    after_cancel = wait_state!(c.driver, &(is_nil(&1.admission_read) and &1.lease_claims == %{}))
    assert after_cancel.running == %{}
    assert File.read!(claim.token.storage.lease_path) == lease_bytes
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    assert File.read!(header) == "successor header"
    refute Enum.any?(RunLedger.recent_entries(), &(&1["event_type"] == "lease.released"))
  end

  test "duplicate dispatch preserves the same promotion reader custody and deadline", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    before = GenServer.call(c.driver, :state)
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    after_duplicate = GenServer.call(c.driver, :state)
    assert after_duplicate.admission_read == before.admission_read
    assert after_duplicate.lease_claims == before.lease_claims
    assert after_duplicate.retry_attempts == before.retry_attempts
    assert Process.alive?(reader)
    send(reader, {:answer, {:ok, []}})
    assert wait_state!(c.driver, &is_nil(&1.admission_read)).running == %{}
  end

  test "duplicate authorization after the original deadline keeps an authorized worker alive", c do
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "promotion-owner", ttl_ms: 4_000)
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(acquired.lease))

    assert {:ok, ticket} =
             SymphonyElixir.DispatchAudit.begin(c.workspace, %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}})

    parent = self()
    driver = c.driver

    assert {:ok, worker} =
             Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               SymphonyElixir.DispatchGate.run(driver, ticket.dispatch_id, fn ->
                 send(parent, {:authorized_body, self()})

                 receive do
                   :finish -> :ok
                 end
               end)
             end)

    on_exit(fn -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
    deadline = System.monotonic_time(:millisecond) + 2_000
    custody_ref = make_ref()
    promotion_ref = make_ref()
    timer = Process.send_after(driver, {:promotion_timeout, c.issue.id, promotion_ref}, 2_000)

    claim = %{
      token: acquired.token,
      lease: acquired.lease,
      custody_ref: custody_ref,
      holder: :gated,
      workspace: c.workspace,
      issue: c.issue,
      started_at_ms: deadline - 2_000,
      deadline: deadline,
      promotion_ref: promotion_ref,
      timer: timer
    }

    :sys.replace_state(driver, fn state ->
      entry = %{
        pid: worker,
        ref: Process.monitor(worker),
        issue: c.issue,
        identifier: c.issue.identifier,
        started_at: DateTime.utc_now(),
        dispatch_ticket: ticket,
        custody_ref: custody_ref,
        lease_token: acquired.token,
        promotion_deadline: deadline,
        workspace_path: c.workspace
      }

      %{state | running: %{c.issue.id => entry}, lease_claims: %{c.issue.id => claim}, claimed: MapSet.new([c.issue.id])}
    end)

    authorization = {:authorize_dispatch, c.issue.id, ticket.dispatch_id, worker}
    send(driver, authorization)
    assert_receive {:authorized_body, ^worker}, 1_000
    authorized = GenServer.call(driver, :state)
    assert authorized.lease_claims[c.issue.id].holder == :running
    assert authorized.lease_claims[c.issue.id].promotion_ref == nil
    lease_bytes = File.read!(acquired.token.storage.lease_path)
    ledger_bytes = File.read!(RunLedger.ledger_file_path())
    Process.sleep(max(0, deadline - System.monotonic_time(:millisecond)) + 1)
    send(driver, {:promotion_timeout, c.issue.id, promotion_ref})
    send(driver, authorization)
    assert GenServer.call(driver, :state).running[c.issue.id].pid == worker
    assert Process.alive?(worker)
    assert File.read!(acquired.token.storage.lease_path) == lease_bytes
    assert File.read!(RunLedger.ledger_file_path()) == ledger_bytes
  end

  test "an old promotion timeout cannot remove a newer local custody reference", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    state = GenServer.call(c.driver, :state)
    original = state.lease_claims[c.issue.id]
    send(c.driver, {:promotion_timeout, c.issue.id, make_ref()})
    assert GenServer.call(c.driver, :state).lease_claims[c.issue.id] == original
    assert Process.alive?(reader)
    send(reader, {:answer, {:ok, []}})
    assert wait_state!(c.driver, &is_nil(&1.admission_read)).running == %{}
  end

  for {label, response} <- [
        {"missing_id", [%Issue{id: nil, identifier: "PROMOTION-1", state: "In Progress"}]},
        {"missing_identifier", [%Issue{id: "promotion", identifier: nil, state: "In Progress"}]}
      ] do
    test "promotion rejects raw incomplete identity #{label}", c do
      assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
      assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
      send(reader, {:answer, {:ok, unquote(Macro.escape(response))}})
      state = wait_state!(c.driver, &is_nil(&1.admission_read))
      assert state.running == %{}
      assert state.lease_claims == %{}
      assert {:error, :missing} = LeaseManager.read(c.issue.id)
    end
  end

  test "cancelled promotion retains its physical slot through a late result until guardian DOWN", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, _read_child, ["promotion"]}, 2_000
    original = GenServer.call(c.driver, :state)
    operation = original.admission_read
    assert :erlang.suspend_process(operation.pid)

    try do
      :sys.replace_state(c.driver, &Orchestrator.terminate_running_issue(&1, c.issue.id, false))
      cancelled = GenServer.call(c.driver, :state)
      assert cancelled.admission_read.invalidated
      assert cancelled.lease_claims == %{}
      assert Process.alive?(operation.pid)
      assert Orchestrator.available_slots(cancelled) == 0
      # A transport result already in flight cannot prove physical termination.
      send(c.driver, {:tracker_read_result, operation.ref, {:ok, [c.issue]}})
      retained = GenServer.call(c.driver, :state)
      assert retained.admission_read.monitor == operation.monitor
      assert retained.running == %{}
      assert Orchestrator.available_slots(retained) == 0
    after
      assert :erlang.resume_process(operation.pid)
    end

    finished = wait_state!(c.driver, &is_nil(&1.admission_read))
    assert Orchestrator.available_slots(finished) == 1
    refute Process.alive?(operation.pid)
  end

  test "promotion deadline is measured from acquisition and cancels the held reader", c do
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "promotion-owner", ttl_ms: 6_000)

    claim = %{
      token: acquired.token,
      lease: acquired.lease,
      custody_ref: make_ref(),
      holder: :retry,
      workspace: c.workspace,
      issue: c.issue,
      started_at_ms: System.monotonic_time(:millisecond),
      deadline: :not_pending,
      promotion_ref: nil,
      timer: nil
    }

    :sys.replace_state(c.driver, &%{&1 | lease_claims: %{c.issue.id => claim}, claimed: MapSet.new([c.issue.id])})
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    pending = GenServer.call(c.driver, :state)
    current = pending.lease_claims[c.issue.id]
    assert current.deadline == current.started_at_ms + 3_000
    finished = wait_state!(c.driver, &is_nil(&1.admission_read), current.deadline + 1_000)
    assert finished.candidate_fetch_error == {:promotion_deadline_expired, c.issue.id}
    assert finished.running == %{}
    assert finished.lease_claims == %{}
    assert {:error, :missing} = LeaseManager.read_at(acquired.token.storage)
    refute Process.alive?(reader)
  end

  test "promotion deadline preserves a failed audit after physical lease release", c do
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "promotion-owner", ttl_ms: 6_000)

    claim = %{
      token: acquired.token,
      lease: acquired.lease,
      custody_ref: make_ref(),
      holder: :retry,
      workspace: c.workspace,
      issue: c.issue,
      started_at_ms: System.monotonic_time(:millisecond),
      deadline: :not_pending,
      promotion_ref: nil,
      timer: nil
    }

    :sys.replace_state(c.driver, &%{&1 | lease_claims: %{c.issue.id => claim}, claimed: MapSet.new([c.issue.id])})
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    pending = GenServer.call(c.driver, :state)
    current = pending.lease_claims[c.issue.id]
    assert current.deadline == current.started_at_ms + 3_000
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    ledger = current.token.storage.ledger_path
    ledger_bytes = File.read!(ledger)
    backup = ledger <> ".before-deadline"
    File.rename!(ledger, backup)
    File.mkdir!(ledger)

    on_exit(fn ->
      File.rmdir!(ledger)
      File.rename!(backup, ledger)
    end)

    finished = wait_state!(c.driver, &is_nil(&1.admission_read), current.deadline + 1_000)
    assert {:lease_release_audit_failed, id, %RunLedger.PersistenceError{}} = finished.candidate_fetch_error
    assert id == c.issue.id
    assert finished.running == %{}
    assert finished.lease_claims == %{}
    refute MapSet.member?(finished.claimed, c.issue.id)
    assert {:error, :missing} = LeaseManager.read_at(current.token.storage)
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    assert File.read!(backup) == ledger_bytes
    assert File.ls!(ledger) == []
    refute Process.alive?(reader)
  end

  test "changed root discards promotion and releases only its captured lease", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    before = GenServer.call(c.driver, :state)
    old = before.lease_claims[c.issue.id]
    assert {:ok, workflow} = Workflow.current()
    config = put_in(workflow.config, ["workspace", "root"], Path.join(c.root, "successor-root"))
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\n" <> workflow.prompt)
    assert :ok = WorkflowStore.force_reload()
    successor_workspace = Workspace.path_for_issue(c.issue)
    File.mkdir_p!(successor_workspace)
    assert {:ok, _} = RunStateStore.transition(successor_workspace, "implement", %{issue_id: c.issue.id, issue_identifier: c.issue.identifier})
    bytes = File.read!(RunStateStore.state_path(successor_workspace))
    send(reader, {:answer, {:ok, [c.issue]}})
    finished = wait_state!(c.driver, &is_nil(&1.admission_read))
    assert finished.running == %{}
    assert finished.lease_claims == %{}
    assert {:error, :missing} = LeaseManager.read_at(old.token.storage)
    assert File.read!(RunStateStore.state_path(successor_workspace)) == bytes
  end

  test "promotion observes a remote 429 before discarding the attempt", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    send(reader, {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 60_000}}}})
    throttled = wait_state!(c.driver, &is_nil(&1.admission_read))
    assert throttled.tracker_backoff_until_ms > System.monotonic_time(:millisecond)
    assert throttled.running == %{}
    assert throttled.lease_claims == %{}
  end

  test "an old successful promotion cannot clear a newer transport backoff", c do
    assert :ok = GenServer.call(c.driver, {:dispatch, c.issue})
    assert_receive {:promotion_read, reader, ["promotion"]}, 2_000
    until_ms = System.monotonic_time(:millisecond) + 60_000
    :sys.replace_state(c.driver, &%{&1 | tracker_backoff_until_ms: until_ms, tracker_backoff_reason: "newer transport 429"})
    send(reader, {:answer, {:ok, [c.issue]}})
    finished = wait_state!(c.driver, &is_nil(&1.admission_read))
    assert finished.tracker_backoff_until_ms == until_ms
    assert finished.running == %{}
    assert finished.lease_claims == %{}
  end

  test "GitHub CI follow-up preserves a live foreign lease without local custody", c do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: [],
      workspace_root: Path.join(c.root, "workspaces"),
      runner_install_root: Path.join(c.root, "runner"),
      max_concurrent_agents: 0
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [c.issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    pr_url = "https://example.invalid/c3/pull/foreign-live"

    assert {:ok, _} =
             RunStateStore.transition(c.workspace, "await_checks", %{
               issue_id: c.issue.id,
               issue_identifier: c.issue.identifier,
               issue_source: :tracker,
               effective_policy_class: "fully_autonomous",
               pr_url: pr_url
             })

    assert {:ok, foreign} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "foreign-follow-up-owner")
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(foreign.lease))
    before = GenServer.call(c.driver, :state)
    assert before.lease_claims == %{}
    assert before.running == %{}
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    lease = File.read!(foreign.token.storage.lease_path)

    event = %SymphonyElixir.GitHubEvent{
      provider: "github",
      event_id: "c3-foreign-live-ci",
      event_name: "check_run",
      action: "completed",
      conclusion: "failure",
      check_name: "local-check",
      entity_type: "check_run",
      entity_id: "foreign-live",
      pr_url: pr_url,
      raw: %{}
    }

    assert {:ok, _} = SymphonyElixir.GitHubEventInbox.enqueue([event])
    send(c.driver, {:github_events_available, %{event_id: event.event_id}})
    finished = wait_state!(c.driver, &(not is_nil(&1.github_last_assignment)))
    assert Process.alive?(c.driver)
    assert finished.github_last_assignment.assignment_state == "leased_elsewhere"
    assert finished.github_last_assignment.assignment_reason == "issue_lease_owned_by_other_runner"
    assert finished.github_last_assignment.lease_owner == inspect(foreign.token.owner)
    assert finished.running == %{}
    assert finished.lease_claims == %{}
    assert finished.retry_attempts == %{}
    assert File.read!(foreign.token.storage.lease_path) == lease
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_comment, _, _}
  end

  for destination_lease <- [:missing, :same_owner] do
    @tag destination_lease: destination_lease
    test "GitHub CI inbox cannot lend captured custody into a new root with #{destination_lease} lease", c do
      assert {:ok, first} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "promotion-owner")
      assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(first.lease))

      claim = %{
        token: first.token,
        lease: first.lease,
        custody_ref: make_ref(),
        holder: :retry,
        workspace: c.workspace,
        issue: c.issue,
        started_at_ms: System.monotonic_time(:millisecond),
        deadline: :not_pending,
        promotion_ref: nil,
        timer: nil
      }

      :sys.replace_state(c.driver, &%{&1 | lease_claims: %{c.issue.id => claim}, claimed: MapSet.new([c.issue.id])})
      old_lease = File.read!(first.token.storage.lease_path)
      old_snapshot = File.read!(RunStateStore.state_path(c.workspace))

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_required_labels: [],
        workspace_root: Path.join(c.root, "other-workspaces"),
        runner_install_root: Path.join(c.root, "runner"),
        max_concurrent_agents: 0
      )

      Application.put_env(:symphony_elixir, :log_file, Path.join(c.root, "other-logs/symphony.log"))
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [c.issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      destination = Workspace.path_for_issue(c.issue)
      File.mkdir_p!(destination)
      pr_url = "https://example.invalid/c3/pull/1"

      assert {:ok, _} =
               RunStateStore.transition(destination, "await_checks", %{
                 issue_id: c.issue.id,
                 issue_identifier: c.issue.identifier,
                 issue_source: :tracker,
                 effective_policy_class: "fully_autonomous",
                 pr_url: pr_url
               })

      header = Path.join(destination, "AGENTS.md")
      File.write!(header, "unrelated destination worker header")

      other_worker =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(other_worker), do: Process.exit(other_worker, :kill) end)

      destination_lease =
        case c.destination_lease do
          :missing ->
            nil

          :same_owner ->
            assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "promotion-owner")
            assert {:ok, _} = RunStateStore.sync_lease(destination, c.issue, LeaseManager.snapshot_for_state(successor.lease))
            {successor.token.storage.lease_path, File.read!(successor.token.storage.lease_path)}
        end

      snapshot = File.read!(RunStateStore.state_path(destination))

      event = %SymphonyElixir.GitHubEvent{
        provider: "github",
        event_id: "c3-root-ci",
        event_name: "check_run",
        action: "completed",
        conclusion: "failure",
        check_name: "local-check",
        entity_type: "check_run",
        entity_id: "1",
        pr_url: pr_url,
        raw: %{}
      }

      assert {:ok, _} = SymphonyElixir.GitHubEventInbox.enqueue([event])
      send(c.driver, {:github_events_available, %{event_id: event.event_id}})
      finished = wait_state!(c.driver, &(not is_nil(&1.github_last_assignment)))
      assert finished.github_last_assignment.assignment_state == "lease_lookup_error"
      assert finished.github_last_assignment.assignment_reason == ":lease_workspace_changed"
      assert finished.lease_claims[c.issue.id] == claim
      assert Process.alive?(other_worker)
      assert File.read!(first.token.storage.lease_path) == old_lease
      assert File.read!(RunStateStore.state_path(c.workspace)) == old_snapshot
      assert File.read!(RunStateStore.state_path(destination)) == snapshot
      assert File.read!(header) == "unrelated destination worker header"

      case destination_lease do
        nil -> assert {:error, :missing} = LeaseManager.read(c.issue.id)
        {path, bytes} -> assert File.read!(path) == bytes
      end

      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, _, _}
    end
  end

  defp manual_promotion_fixture!(c, state) do
    ready = Path.join(c.root, "manual-hook-ready")
    release = Path.join(c.root, "manual-hook-release")
    exited = Path.join(c.root, "manual-hook-exited")
    manual_root = Path.join(c.root, "manual-store")

    hook = """
    printf ready > '#{ready}'
    attempts=0
    while [ ! -f '#{release}' ]; do
      if [ "$attempts" -ge 100 ]; then
        printf timeout > '#{exited}.tmp'
        mv '#{exited}.tmp' '#{exited}'
        exit 1
      fi
      attempts=$((attempts + 1))
      sleep 0.02
    done
    printf released > '#{exited}.tmp'
    mv '#{exited}.tmp' '#{exited}'
    """

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      tracker_required_labels: [],
      manual_enabled: true,
      manual_store_root: manual_root,
      workspace_root: Path.join(c.root, "workspaces"),
      runner_install_root: Path.join(c.root, "runner"),
      max_concurrent_agents: 1,
      codex_command: "/usr/bin/false",
      hook_before_run: hook,
      hook_timeout_ms: 5_000,
      observability_tracing_enabled: false
    )

    assert :ok = Config.validate!()

    assert {:ok, submitted} =
             SymphonyElixir.ManualIssueStore.submit(%{
               "id" => "manual-promotion",
               "identifier" => "MANUAL-PROMOTION",
               "title" => "Manual promotion compatibility",
               "acceptance_criteria" => ["Preserve the existing manual refresh rules"]
             })

    assert :ok = SymphonyElixir.ManualIssueStore.update_issue_state(submitted.id, state)
    assert {:ok, issue} = SymphonyElixir.ManualIssueStore.fetch_issue_by_id(submitted.id)
    assert %Issue{source: :manual, state: ^state} = issue
    [record] = Path.wildcard(Path.join(manual_root, "*.json"))
    workspace = Workspace.path_for_issue(issue)

    assert {:ok, snapshot} =
             RunStateStore.transition(workspace, "await_checks", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: :manual
             })

    assert Map.take(snapshot, [:run_id, :run_identity_event_id, :run_identity_ledger_path]) == %{}
    %{issue: issue, workspace: workspace, record: record, ready: ready, release: release, exited: exited}
  end

  defp observe_manual_promotion_reads!(driver) do
    id = {__MODULE__, :manual_read, make_ref()}

    assert :ok =
             :telemetry.attach(
               id,
               [:symphony, :issue_source, :stop],
               fn _event, _measurements, metadata, {owner, owner_driver} ->
                 if metadata.source == "manual" and metadata.operation == "fetch" and self() != owner and self() != owner_driver do
                   send(owner, {:manual_promotion_fetch, self()})
                 end
               end,
               {self(), driver}
             )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp assert_manual_promotion_gate!(driver, manual, expected_state) do
    assert_receive {:manual_promotion_fetch, reader}, 2_000
    refute reader == driver
    wait_manual_hook_file!(manual.ready, System.monotonic_time(:millisecond) + 2_000)
    state = GenServer.call(driver, :state, 500)
    entry = Map.fetch!(state.running, manual.issue.id)
    claim = Map.fetch!(state.lease_claims, manual.issue.id)
    assert claim.holder == :running
    assert entry.custody_ref == claim.custody_ref
    assert entry.lease_token == claim.token
    assert entry.issue.state == expected_state
    assert Process.alive?(entry.pid)
    assert {:ok, snapshot} = RunStateStore.load_checked(manual.workspace, manual.issue)
    assert snapshot.run_id == entry.dispatch_ticket.run_id
    assert is_binary(snapshot.run_identity_event_id)
    assert is_binary(snapshot.run_identity_ledger_path)
    assert Enum.any?(RunLedger.recent_entries(), &(&1["event_type"] == "dispatch.started" and &1["issue_id"] == manual.issue.id))
  end

  defp release_manual_promotion_hook!(manual) do
    File.write!(manual.release, "continue")
    wait_manual_hook_file!(manual.exited, System.monotonic_time(:millisecond) + 2_000)
    assert File.read!(manual.exited) == "released"
  end

  defp wait_manual_hook_file!(path, deadline) do
    unless File.exists?(path) do
      assert System.monotonic_time(:millisecond) < deadline, "Expected manual hook signal #{Path.basename(path)} was not observed"

      receive do
      after
        5 -> wait_manual_hook_file!(path, deadline)
      end
    end
  end

  defp write_capacity_workflow!(c, boundary, limit) do
    limits = if boundary == :state, do: %{"In Progress" => limit}, else: %{}
    company_limit = if boundary == :company, do: limit, else: 3

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "fixture",
      tracker_project_slug: "fixture",
      tracker_required_labels: [],
      workspace_root: Path.join(c.root, "workspaces"),
      runner_install_root: Path.join(c.root, "runner"),
      max_concurrent_agents: 3,
      max_concurrent_agents_by_state: limits,
      policy_packs: %{"private_autopilot" => %{"max_concurrent_runs_per_company" => company_limit}},
      codex_command: "/usr/bin/false",
      observability_tracing_enabled: false
    )
  end

  defp seed_gated_reservation!(c) do
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "promotion-owner")
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(acquired.lease))

    assert {:ok, ticket} =
             SymphonyElixir.DispatchAudit.begin(c.workspace, %{
               issue_id: c.issue.id,
               issue_identifier: c.issue.identifier,
               metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}
             })

    # A real worker remains behind the same gate used by runtime. Authorization
    # is deliberately not sent while the public admission predicate is checked.
    driver = c.driver

    assert {:ok, worker} =
             Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               SymphonyElixir.DispatchGate.run(driver, ticket.dispatch_id, fn -> flunk("capacity fixture unexpectedly activated") end)
             end)

    on_exit(fn -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
    ref = make_ref()

    claim = %{
      token: acquired.token,
      lease: acquired.lease,
      custody_ref: ref,
      holder: :gated,
      workspace: c.workspace,
      issue: c.issue,
      started_at_ms: System.monotonic_time(:millisecond),
      deadline: :not_pending,
      promotion_ref: nil,
      timer: nil
    }

    :sys.replace_state(driver, fn state ->
      entry = %{
        pid: worker,
        ref: Process.monitor(worker),
        issue: c.issue,
        identifier: c.issue.identifier,
        started_at: DateTime.utc_now(),
        dispatch_ticket: ticket,
        custody_ref: ref,
        lease_token: acquired.token,
        promotion_deadline: :not_pending,
        workspace_path: c.workspace
      }

      %{state | running: %{c.issue.id => entry}, lease_claims: %{c.issue.id => claim}, claimed: MapSet.new([c.issue.id])}
    end)
  end

  defp wait_state!(driver, predicate), do: wait_state!(driver, predicate, System.monotonic_time(:millisecond) + 2_000)

  defp wait_state!(driver, predicate, deadline) do
    state = GenServer.call(driver, :state, 500)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "promotion did not settle: #{inspect(state)}"
      Process.sleep(5)
      wait_state!(driver, predicate, deadline)
    end
  end
end
