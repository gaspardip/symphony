defmodule SymphonyElixir.OrchestratorTrackerInboxAsyncTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, LeaseManager, Orchestrator, RunLedger, RunStateStore, TrackerEvent, TrackerEventInbox, TrackerReader, Workflow, WorkflowStore, Workspace}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

  @event_time ~U[2026-03-08 07:05:00Z]

  defmodule Client do
    def fetch_issue_by_id(id), do: read(:lookup, [id])
    def fetch_issue_states_by_ids(ids), do: read(:refresh, ids)
    def fetch_candidate_issues, do: read(:candidates, [])
    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_by_identifier(identifier) do
      {:ok, %Issue{id: String.replace_prefix(identifier, "ISSUE-", ""), identifier: identifier, state: "Todo", source: :tracker, title: "Inbox fixture", labels: [], assigned_to_worker: true}}
    end

    def graphql(_query, _variables) do
      {:ok,
       %{
         "data" => %{
           "commentCreate" => %{"success" => true},
           "issueUpdate" => %{"success" => true},
           "issue" => %{"team" => %{"id" => "local-team", "states" => %{"nodes" => [%{"id" => "local-state"}]}}}
         }
       }}
    end

    defp read(kind, args) do
      fixture = Application.fetch_env!(:symphony_elixir, :tracker_inbox_async_fixture)

      if MapSet.member?(fixture.held_reads, kind) do
        send(fixture.owner, {:inbox_read, kind, self(), args})

        receive do
          {:answer, result} -> result
          :raise -> raise "controlled inbox reader exception"
        after
          5_000 -> raise "inbox fixture reader barrier expired"
        end
      else
        {:ok, []}
      end
    end
  end

  defmodule Driver do
    use GenServer

    def start_link(runtime, owner), do: GenServer.start_link(__MODULE__, {runtime, owner})

    @impl true
    def init({runtime, owner}), do: {:ok, %{runtime: runtime, owner: owner, hold: MapSet.new([:ack, :gate]), held: [], read_results: %{}}}

    @impl true
    def handle_info({:tracker_inbox_ack, _cursor} = message, state), do: intercept(:ack, message, state)
    def handle_info({:authorize_dispatch, _, _, _} = message, state), do: intercept(:gate, message, state)
    def handle_info({:tracker_inbox_continue, _ref} = message, state), do: intercept(:continue, message, state)

    def handle_info({:tracker_inbox_wakeup, _, _, _} = message, state), do: intercept(:wakeup, message, state)

    def handle_info({:tracker_read_result, ref, _result} = message, state) do
      operation = Enum.find([state.runtime.tracker_poll_read, state.runtime.admission_read], &(is_map(&1) and &1.ref == ref))

      if MapSet.member?(state.hold, :read_result) and operation do
        pending = %{message: message, monitor: operation.monitor, down: nil}
        {:noreply, %{state | read_results: Map.put(state.read_results, ref, pending)}}
      else
        dispatch(message, state)
      end
    end

    def handle_info({:DOWN, monitor, :process, _pid, _reason} = message, state) do
      case Enum.find(state.read_results, fn {_ref, pending} -> pending.monitor == monitor end) do
        {ref, pending} ->
          send(state.owner, {:inbox_callback, :read_result, self(), pending.message})
          {:noreply, %{state | read_results: Map.put(state.read_results, ref, %{pending | down: message})}}

        nil ->
          dispatch(message, state)
      end
    end

    def handle_info(message, state), do: dispatch(message, state)

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

    def handle_call({:hold, kind, enabled}, _from, state) do
      hold = if enabled, do: MapSet.put(state.hold, kind), else: MapSet.delete(state.hold, kind)
      {:reply, :ok, %{state | hold: hold}}
    end

    def handle_call({:deliver, message}, _from, state) do
      {pending, read_results} =
        case message do
          {:tracker_read_result, ref, _} -> Map.pop(state.read_results, ref)
          _ -> {nil, state.read_results}
        end

      {:noreply, next} = dispatch(message, %{state | held: List.delete(state.held, message), read_results: read_results})

      next =
        case pending do
          nil ->
            next

          %{down: {:DOWN, _, :process, _, _} = down} ->
            {:noreply, after_down} = dispatch(down, next)
            after_down
        end

      {:reply, :ok, next}
    end

    def handle_call({:dispatch, issue}, _from, state) do
      {:reply, :ok, %{state | runtime: Orchestrator.dispatch_runtime_issue(state.runtime, issue, 1)}}
    end

    def handle_call(message, from, state) do
      case Orchestrator.handle_call(message, from, state.runtime) do
        {:reply, reply, runtime} -> {:reply, reply, %{state | runtime: runtime}}
        {:noreply, runtime} -> {:noreply, %{state | runtime: runtime}}
      end
    end

    defp intercept(kind, message, state) do
      if MapSet.member?(state.hold, kind) do
        send(state.owner, {:inbox_callback, kind, self(), message})
        {:noreply, %{state | held: state.held ++ [message]}}
      else
        dispatch(message, state)
      end
    end

    defp dispatch(message, state) do
      case message do
        {:tracker_inbox_wakeup, ref, _location, _generation} -> send(state.owner, {:inbox_wakeup_delivered, self(), ref})
        _ -> :ok
      end

      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end
  end

  setup do
    pause_default_scheduler!()
    root = Path.join(System.tmp_dir!(), "tracker-inbox-async-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    root = File.cd!(root, &File.cwd!/0)
    keys = [:workflow_file_path, :log_file, :linear_client_module, :tracker_inbox_async_fixture]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})
    previous_path = System.fetch_env!("PATH")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
      end)

      System.put_env("PATH", previous_path)
      if Process.whereis(WorkflowStore), do: :ok = WorkflowStore.force_reload()
      File.rm_rf!(root)
    end)

    if is_nil(Process.whereis(SymphonyElixir.TaskSupervisor)), do: start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
    if is_nil(Process.whereis(WorkflowStore)), do: start_supervised!(WorkflowStore)
    bin = Path.join(root, "bin")
    File.mkdir!(bin)
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\nprintf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n")
    File.chmod!(Path.join(bin, "gh"), 0o700)
    System.put_env("PATH", bin <> ":" <> previous_path)
    Application.put_env(:symphony_elixir, :linear_client_module, Client)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "logs/symphony.log"))
    hold_reads([:lookup, :refresh])
    ready = Path.join(root, "worker-ready")
    release = Path.join(root, "worker-release")
    exited = Path.join(root, "worker-exited")

    hook = """
    printf ready > '#{ready}'
    attempts=0
    while [ ! -f '#{release}' ]; do
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 500 ]; then
        printf timeout > '#{exited}.tmp'
        mv '#{exited}.tmp' '#{exited}'
        exit 1
      fi
      sleep 0.01
    done
    printf released > '#{exited}.tmp'
    mv '#{exited}.tmp' '#{exited}'
    exit 1
    """

    config = %{
      tracker: %{kind: "linear", api_key: "synthetic-local-token", project_slug: "local-inbox", required_labels: [], active_states: ["Todo", "In Progress", "Merging"], terminal_states: ["Done"]},
      polling: %{interval_ms: 60_000, discovery_interval_ms: 60_000, healing_interval_ms: 60_000},
      workspace: %{root: Path.join(root, "workspaces")},
      runner: %{install_root: Path.join(root, "runner"), self_host_project: false},
      manual: %{enabled: true, store_root: Path.join(root, "manual")},
      company: %{policy_pack: "private_autopilot", author_profile_path: Path.join(root, "author.json"), credential_registry_path: Path.join(root, "credentials.json")},
      agent: %{max_concurrent_agents: 3, stall_timeout_ms: 0, codex: %{command: "/usr/bin/false", runtime_profile: %{inherit_env: false}}},
      hooks: %{before_run: hook, timeout_ms: 10_000},
      policy: %{publish_required: false, automerge_on_green: false, token_budget: %{per_issue_total: 200_000}}
    }

    workflow = Path.join(root, "WORKFLOW.md")
    write_config!(workflow, config)
    now = System.monotonic_time(:millisecond)

    state = %State{
      lease_owner: "inbox-async-#{System.unique_integer([:positive])}",
      max_concurrent_agents: 3,
      poll_interval_ms: 60_000,
      healing_poll_interval_ms: 60_000,
      next_poll_due_at_ms: now + 60_000,
      next_healing_poll_due_at_ms: now + 60_000,
      first_poll_completed: true,
      poll_check_in_progress: false,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:ok, pid} = Driver.start_link(state, self())
    Process.unlink(pid)

    on_exit(fn ->
      File.write!(release, "continue")
      cleanup_driver!(pid)
    end)

    %{pid: pid, root: root, config: config, workflow: workflow, ready: ready, release: release, exited: exited, location: TrackerEventInbox.location()}
  end

  test "held first lookup serves snapshots and worker updates without acknowledging A or reading B", c do
    hold_reads([:lookup])
    worker = install_worker!(c.pid, issue("WORKER"))
    enqueue!(c.pid, [event("A"), event("B")])
    reader = read!(:lookup, ["A"])
    assert is_map(Orchestrator.snapshot(c.pid, 5_000))
    timestamp = DateTime.utc_now()
    send(c.pid, {:agent_worker_update, "WORKER", %{event: :notification, timestamp: timestamp, message: "inbox lookup pending"}})
    state = await!(c.pid, &(&1.running["WORKER"].last_agent_timestamp == timestamp))
    assert state.running["WORKER"].pid == worker
    assert Process.alive?(reader)
    assert state.tracker_poll_read.purpose == :inbox_lookup
    assert state.inbox_ack_pending == nil
    assert pending_ids() == ["A", "B"]
    refute_received {:inbox_read, :lookup, _, ["B"]}
    answer(reader, {:ok, nil})
    second = read!(:lookup, ["B"])
    assert pending_ids() == ["A", "B"]
    answer(second, {:ok, nil})
    ack!(c.pid)
    assert pending_ids() == []
  end

  test "held second lookup frees B for discovery and retains one unacknowledged head", c do
    reader = held_head!(c.pid, :admission)
    before = runtime(c.pid)
    hold_reads([:lookup, :refresh, :candidates])
    send(c.pid, :run_poll_cycle)
    discovery = read!(:candidates, [])
    state = runtime(c.pid)
    assert state.admission_read.ref == before.admission_read.ref
    assert state.admission_read.purpose == :inbox_admission
    assert state.tracker_inbox_batch.head.ref == before.tracker_inbox_batch.head.ref
    assert state.inbox_ack_pending == nil
    assert is_map(Orchestrator.snapshot(c.pid, 5_000))
    assert pending_ids() == ["A"]
    answer(discovery, {:ok, []})
    await!(c.pid, &is_nil(&1.tracker_poll_read))
    assert Process.alive?(reader)
    answer(reader, {:ok, []})
    ack!(c.pid)
  end

  test "poll, retry and inbox rotate logical decisions while each retained reference stays current", c do
    hold_reads([:lookup, :refresh, :candidates])
    enqueue!(c.pid, [event("A")])
    inbox = read!(:lookup, ["A"])
    retry_r = retry_entry("R")
    retry_s = retry_entry("S")
    batch = %{issues: [issue("P"), issue("Q")], invalidated: MapSet.new()}
    replace_runtime(c.pid, &%{&1 | admission_batch: batch, retry_attempts: %{"R" => retry_r, "S" => retry_s}, next_admission_kind: :poll})
    send(c.pid, {:retry_issue, "R", retry_r.retry_ref})
    poll_p = read!(:refresh, ["P"])
    send(c.pid, {:retry_issue, "S", retry_s.retry_ref})
    answer(inbox, {:ok, issue("A")})
    state = await!(c.pid, &head_phase?(&1, :admission_ready))
    assert state.retry_attempts["R"].retry_ref == retry_r.retry_ref
    assert state.retry_attempts["S"].retry_ref == retry_s.retry_ref
    assert Enum.map(state.admission_batch.issues, & &1.id) == ["Q"]
    assert state.inbox_ack_pending == nil
    answer(poll_p, {:ok, []})
    retry_reader = read!(:candidates, [])
    assert runtime(c.pid).admission_read.issue.id == "R"
    answer(retry_reader, {:ok, []})
    inbox_admission = read!(:refresh, ["A"])
    assert runtime(c.pid).admission_read.purpose == :inbox_admission
    answer(inbox_admission, {:ok, []})
    poll_q = read!(:refresh, ["Q"])
    answer(poll_q, {:ok, []})
    retry_reader = read!(:candidates, [])
    assert runtime(c.pid).admission_read.issue.id == "S"
    answer(retry_reader, {:ok, []})
    ack!(c.pid)
    state = await!(c.pid, &(is_nil(&1.admission_read) and &1.retry_attempts == %{}))
    assert state.running == %{}
    assert pending_ids() == []
  end

  test "active admission acknowledges only after the real gate while its worker is still running", c do
    reader = held_head!(c.pid, :admission)
    answer(reader, {:ok, [issue("A")]})
    gate = callback!(:gate, c.pid)
    gated = runtime(c.pid)
    assert head_phase?(gated, :gate)
    assert gated.lease_claims["A"].holder == :gated
    assert gated.running["A"].custody_ref == gated.lease_claims["A"].custody_ref
    assert gated.inbox_ack_pending == nil
    refute Map.has_key?(gated.issue_routing_cache, "A")
    refute File.exists?(c.ready)
    assert pending_ids() == ["A"]
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    state = runtime(c.pid)
    assert state.lease_claims["A"].holder == :running
    assert Process.alive?(state.running["A"].pid)
    assert state.running["A"].lease_token == state.lease_claims["A"].token
    assert {:ok, snapshot} = RunStateStore.load_checked(Workspace.path_for_issue(issue("A")), issue("A"))
    assert snapshot.run_id == state.running["A"].dispatch_ticket.run_id
    assert dispatch_count("A") == 1
    ack!(c.pid)
    assert pending_ids() == []
    assert Process.alive?(runtime(c.pid).running["A"].pid)
    release_hook!(c)
  end

  test "inbox promotion retains its original reservation and deadline until gate authorization", c do
    promoted = promotion_issue!("A")
    enqueue!(c.pid, [event("A")])
    answer(read!(:lookup, ["A"]), {:ok, promoted})
    promotion_reader = read!(:refresh, ["A"])
    pending = runtime(c.pid)
    assert pending.admission_read.purpose == :promotion
    assert pending.admission_read.completion.purpose == :tracker_inbox
    claim = pending.lease_claims["A"]
    ref = pending.admission_read.ref
    assert is_integer(claim.deadline)
    assert head_phase?(pending, :promotion)
    assert pending.inbox_ack_pending == nil
    assert pending_ids() == ["A"]
    retry = retry_entry("R")
    replace_runtime(c.pid, &%{&1 | retry_attempts: %{"R" => retry}})
    send(c.pid, {:retry_issue, "R", retry.retry_ref})
    state = runtime(c.pid)
    assert state.admission_read.ref == ref
    assert state.lease_claims["A"].deadline == claim.deadline
    assert state.retry_attempts["R"].status == :ready
    assert is_map(Orchestrator.snapshot(c.pid, 5_000))
    answer(promotion_reader, {:ok, [promoted]})
    gate = callback!(:gate, c.pid)
    assert runtime(c.pid).lease_claims["A"].deadline == claim.deadline
    assert runtime(c.pid).inbox_ack_pending == nil
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    ack!(c.pid)
    assert pending_ids() == []
    deliver!(c.pid, gate)
    send(c.pid, {:promotion_timeout, "A", claim.promotion_ref})
    assert runtime(c.pid).lease_claims["A"].holder == :running
    assert dispatch_count("A") == 1
    release_hook!(c)
  end

  for phase <- [:lookup, :admission], failure <- [:child_down, :guardian_down, :exception] do
    test "#{failure} during #{phase} retains the head until another drain without an automatic retry", c do
      reader = held_head!(c.pid, unquote(phase))
      state = runtime(c.pid)
      operation = read_operation(state, unquote(phase))
      head_ref = state.tracker_inbox_batch.head.ref

      case unquote(failure) do
        :child_down -> Process.exit(reader, :kill)
        :guardian_down -> Process.exit(operation.pid, :kill)
        :exception -> send(reader, :raise)
      end

      blocked = await!(c.pid, &head_phase?(&1, :blocked))
      assert blocked.tracker_inbox_batch.head.ref == head_ref
      assert blocked.inbox_storage_error != nil
      assert blocked.inbox_ack_pending == nil
      assert blocked.tracker_inbox_wakeup == nil
      refute Map.has_key?(blocked.issue_routing_cache, "A")
      assert pending_ids() == ["A"]
      refute_receive {:inbox_read, _, _, _}, 30
      refute_receive {:inbox_callback, :ack, _, _}, 30
      send(c.pid, :run_webhook_cycle)
      replacement = read!(:lookup, ["A"])
      assert replacement != reader
      answer(replacement, {:ok, nil})
      ack!(c.pid)
      assert pending_ids() == []
    end
  end

  test "stop uses the current admission head Issue while its real guardian remains suspended", c do
    reader = held_head!(c.pid, :admission)
    operation = runtime(c.pid).admission_read
    assert :erlang.suspend_process(operation.pid)

    try do
      assert %{ok: true} = Orchestrator.stop_issue(c.pid, "ISSUE-A")
      state = runtime(c.pid)
      assert state.admission_read.ref == operation.ref
      assert state.admission_read.monitor == operation.monitor
      assert state.admission_read.invalidated
      assert Process.alive?(operation.pid)
      assert state.inbox_ack_pending == nil
      assert pending_ids() == ["A"]
      answer(reader, {:ok, [issue("A")]})
      refute_receive {:inbox_read, _, _, _}, 30
      refute_receive {:inbox_callback, :gate, _, _}, 30
    after
      assert :erlang.resume_process(operation.pid)
    end

    fresh = read!(:lookup, ["A"])
    assert is_nil(runtime(c.pid).admission_read)
    answer(fresh, {:ok, nil})
    ack!(c.pid)
    assert pending_ids() == []
    assert runtime(c.pid).running == %{}
    assert {:error, :missing} = LeaseManager.read("A")
  end

  test "expired stop cannot revoke a genuine held admission or consume its physical slot", c do
    reader = held_head!(c.pid, :admission)
    before = runtime(c.pid)
    operation = before.admission_read
    assert :erlang.suspend_process(operation.pid)

    try do
      request = %{ref: make_ref(), deadline: System.monotonic_time(:millisecond) - 1, action: :stop, identifier: "ISSUE-A", args: []}
      assert %{ok: false, error: "control_deadline_exceeded", effect_status: "not_started"} = GenServer.call(c.pid, {:control, request})
      assert runtime(c.pid) == before
      assert Process.alive?(operation.pid)
      refute_receive {:inbox_read, _, _, _}, 30
      refute_receive {:inbox_callback, :ack, _, _}, 30

      assert %{ok: true} = Orchestrator.pause_issue(c.pid, "ISSUE-A")
      assert runtime(c.pid).admission_read.ref == operation.ref
      assert runtime(c.pid).admission_read.invalidated
      answer(reader, {:ok, [issue("A")]})
    after
      assert :erlang.resume_process(operation.pid)
    end

    fresh = read!(:lookup, ["A"])
    assert is_nil(runtime(c.pid).admission_read)
    answer(fresh, {:ok, nil})
    ack!(c.pid)
    assert pending_ids() == []
    assert runtime(c.pid).running == %{}
    assert {:error, :missing} = LeaseManager.read("A")
  end

  test "cancelling a suspended guardian retains the physical reader slot until DOWN", c do
    reader = held_head!(c.pid, :admission)
    operation = runtime(c.pid).admission_read
    assert :erlang.suspend_process(operation.pid)

    try do
      assert %{ok: true} = Orchestrator.pause_issue(c.pid, "ISSUE-A")
      state = runtime(c.pid)
      assert state.admission_read.ref == operation.ref
      assert state.admission_read.monitor == operation.monitor
      assert state.admission_read.invalidated
      assert state.inbox_ack_pending == nil
      assert Process.alive?(operation.pid)
      assert pending_ids() == ["A"]
      answer(reader, {:ok, [issue("A")]})
      refute_receive {:inbox_read, _, _, _}, 30
      refute_receive {:inbox_callback, :gate, _, _}, 30
    after
      assert :erlang.resume_process(operation.pid)
    end

    fresh = read!(:lookup, ["A"])
    current = runtime(c.pid)
    assert is_nil(current.admission_read)
    answer(fresh, {:ok, issue("A")})
    ack!(c.pid)
    assert runtime(c.pid).running == %{}
    deliver!(c.pid, {:tracker_read_result, operation.ref, {:ok, [issue("A")]}})
    assert runtime(c.pid).running == %{}
    assert {:error, :missing} = LeaseManager.read("A")
  end

  for phase <- [:lookup, :admission, :promotion] do
    test "real task capacity rejects #{phase} reader start without applying or acknowledging its head", c do
      current_issue = if unquote(phase) == :promotion, do: promotion_issue!("A"), else: issue("A")

      message =
        if unquote(phase) == :lookup do
          assert :ok = GenServer.call(c.pid, {:hold, :read_result, true})
          enqueue!(c.pid, [event("A")])
          message = callback!(:read_result, c.pid)
          assert runtime(c.pid).tracker_poll_read.phase == :approval
          message
        else
          reader = held_head!(c.pid, :lookup)
          assert :ok = GenServer.call(c.pid, {:hold, :read_result, true})
          answer(reader, {:ok, current_issue})
          callback!(:read_result, c.pid)
        end

      assert :ok = GenServer.call(c.pid, {:hold, :read_result, false})
      original = Process.whereis(SymphonyElixir.TaskSupervisor)
      assert is_pid(original)
      parent = Process.whereis(SymphonyElixir.Supervisor)
      assert is_pid(parent)
      child_id = Task.Supervisor.child_spec(name: SymphonyElixir.TaskSupervisor).id
      assert Enum.any?(Supervisor.which_children(parent), fn {id, child, _, _} -> id == child_id and child == original end)
      assert Task.Supervisor.children(original) == []
      assert :ok = Supervisor.terminate_child(parent, child_id)

      try do
        assert {:ok, constrained} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor, max_children: 0)

        try do
          deliver!(c.pid, message)
          state = runtime(c.pid)
          assert head_phase?(state, :blocked)
          assert state.tracker_inbox_batch.head.retryable
          assert state.inbox_ack_pending == nil
          assert state.tracker_inbox_wakeup == nil
          assert state.running == %{}
          refute Map.has_key?(state.issue_routing_cache, "A")
          assert pending_ids() == ["A"]
          assert inspect(state.candidate_fetch_error) =~ "max_children"
          assert Task.Supervisor.children(constrained) == []
          refute_received {:inbox_read, _, _, _}
          refute_received {:inbox_callback, :ack, _, _}
        after
          assert Task.Supervisor.children(constrained) == []
          assert :ok = Supervisor.stop(constrained)
        end
      after
        case Supervisor.restart_child(parent, child_id) do
          {:ok, restored} -> assert Process.whereis(SymphonyElixir.TaskSupervisor) == restored
          {:ok, restored, _info} -> assert Process.whereis(SymphonyElixir.TaskSupervisor) == restored
        end
      end

      send(c.pid, :run_webhook_cycle)
      reader = read!(:lookup, ["A"])
      answer(reader, {:ok, nil})
      ack!(c.pid)
      assert pending_ids() == []
    end
  end

  test "promotion timeout after physical token replacement preserves its successor and reevaluates the cursor", c do
    current_issue = promotion_issue!("A")
    enqueue!(c.pid, [event("A")])
    answer(read!(:lookup, ["A"]), {:ok, current_issue})
    _reader = read!(:refresh, ["A"])
    state = runtime(c.pid)
    operation = state.admission_read
    claim = state.lease_claims["A"]
    assert operation.purpose == :promotion
    assert :erlang.suspend_process(operation.pid)

    try do
      assert {:ok, :released} = LeaseManager.release_token(claim.token)
      assert {:ok, successor} = LeaseManager.acquire("A", "ISSUE-A", "successor-owner", storage: claim.token.storage)
      bytes = File.read!(successor.token.storage.lease_path)
      assert successor.token.lease_generation != claim.token.lease_generation
      Process.cancel_timer(claim.timer)
      expired = System.monotonic_time(:millisecond) - 1

      # Exercise the real timeout callback at an elapsed deadline without
      # waiting half the default lease TTL. The token and journal remain real.
      replace_runtime(c.pid, fn current ->
        current
        |> put_in([Access.key(:lease_claims), "A", :deadline], expired)
        |> put_in([Access.key(:admission_read), :deadline], expired)
      end)

      deliver!(c.pid, {:promotion_timeout, "A", claim.promotion_ref})
      timed_out = runtime(c.pid)
      assert timed_out.inbox_ack_pending == nil
      refute Map.has_key?(timed_out.issue_routing_cache, "A")
      assert pending_ids() == ["A"]
      assert File.read!(successor.token.storage.lease_path) == bytes
      assert timed_out.admission_read.ref == operation.ref
      assert timed_out.admission_read.invalidated
      refute_received {:inbox_callback, :ack, _, _}
    after
      assert :erlang.resume_process(operation.pid)
    end

    fresh = read!(:lookup, ["A"])
    assert {:ok, successor} = LeaseManager.read_at(claim.token.storage)
    assert successor["owner"] == "successor-owner"
    bytes = File.read!(claim.token.storage.lease_path)
    answer(fresh, {:ok, nil})
    ack!(c.pid)
    assert File.read!(claim.token.storage.lease_path) == bytes
  end

  for cleanup <- [:ok, :lease_lock, :release_audit] do
    test "promotion reader exception with #{cleanup} cleanup has the corresponding retry policy", c do
      current_issue = promotion_issue!("A")
      enqueue!(c.pid, [event("A")])
      answer(read!(:lookup, ["A"]), {:ok, current_issue})
      reader = read!(:refresh, ["A"])
      claim = runtime(c.pid).lease_claims["A"]
      ledger = claim.token.storage.ledger_path
      backup = ledger <> ".before-promotion-exception"
      lock = claim.token.storage.lease_path <> ".lock"

      case unquote(cleanup) do
        :ok ->
          :ok

        :lease_lock ->
          File.mkdir!(lock)

        :release_audit ->
          File.rename!(ledger, backup)
          File.mkdir!(ledger)
      end

      blocked =
        try do
          send(reader, :raise)
          state = await!(c.pid, &head_phase?(&1, :blocked))
          assert state.inbox_ack_pending == nil
          assert state.tracker_inbox_wakeup == nil
          assert state.running == %{}
          refute Map.has_key?(state.issue_routing_cache, "A")
          assert state.tracker_inbox_batch.head.retryable == (unquote(cleanup) == :ok)
          assert pending_ids() == ["A"]
          state
        after
          case unquote(cleanup) do
            :ok ->
              :ok

            :lease_lock ->
              File.rmdir!(lock)

            :release_audit ->
              File.rmdir!(ledger)
              File.rename!(backup, ledger)
          end
        end

      deliver!(c.pid, :run_webhook_cycle)

      if unquote(cleanup) == :ok do
        assert blocked.tracker_inbox_batch.head.errors == []
        assert {:error, :missing} = LeaseManager.read_at(claim.token.storage)
        answer(read!(:lookup, ["A"]), {:ok, nil})
        ack!(c.pid)
        assert pending_ids() == []
      else
        state = runtime(c.pid)
        assert head_phase?(state, :blocked)
        assert state.tracker_inbox_batch.head.errors == blocked.tracker_inbox_batch.head.errors
        assert state.tracker_inbox_batch.head.errors != []
        assert state.inbox_ack_pending == nil
        assert pending_ids() == ["A"]
        refute_receive {:inbox_read, _, _, _}, 30
        refute_receive {:inbox_callback, :ack, _, _}, 30
      end
    end
  end

  test "ack failure after an authorized gate retries only the captured cursor after root changes", c do
    reader = held_head!(c.pid, :admission)
    answer(reader, {:ok, [issue("A")]})
    deliver!(c.pid, callback!(:gate, c.pid))
    wait_file!(c.ready)
    ack = {:tracker_inbox_ack, cursor} = callback!(:ack, c.pid)
    before = runtime(c.pid)
    worker = before.running["A"].pid
    ledger_path = before.lease_claims["A"].token.storage.ledger_path
    assert cursor.location == c.location
    assert before.issue_routing_cache["A"].state == "Todo"
    assert dispatch_count("A") == 1
    File.mkdir!(c.location.lock_path)

    try do
      deliver!(c.pid, ack)
      failed = runtime(c.pid)
      assert failed.inbox_ack_pending == cursor
      assert failed.inbox_storage_error.phase == :lock
      assert failed.inbox_last_drained_at == nil
      assert failed.running["A"].pid == worker
      refute_receive {:inbox_callback, :ack, _, _}, 30
    after
      File.rmdir!(c.location.lock_path)
    end

    Application.put_env(:symphony_elixir, :log_file, Path.join(c.root, "other/symphony.log"))
    assert {:ok, _} = TrackerEventInbox.enqueue([event("B")])
    next_location = TrackerEventInbox.location()
    next_bytes = File.read!(next_location.events_path)
    send(c.pid, :run_webhook_cycle)
    answer(read!(:refresh, ["A"]), {:ok, []})
    await!(c.pid, &is_nil(&1.inbox_ack_pending))
    assert {:ok, %{rows: []}} = TrackerEventInbox.capture(c.location, inbox_limits())
    assert File.read!(next_location.events_path) == next_bytes
    assert pending_ids() == ["B"]
    assert runtime(c.pid).running["A"].pid == worker
    assert dispatch_count_at(ledger_path, "A") == 1
    refute_received {:inbox_read, _, _, _}
    deliver!(c.pid, ack)
    assert pending_ids() == ["B"]
    release_hook!(c)
  end

  test "one drain after failed prefix confirmation admits the retained B without repeating its lookup", c do
    assert :ok = TrackerEventInbox.initialize(c.location)
    File.write!(c.location.events_path, "invalid\n")
    enqueue!(c.pid, [event("A"), event("B")])
    answer(read!(:lookup, ["A"]), {:ok, %{issue("A") | state: "Done"}})
    answer(read!(:lookup, ["B"]), {:ok, issue("B")})
    ack = {:tracker_inbox_ack, cursor} = callback!(:ack, c.pid)
    assert head_phase?(runtime(c.pid), :admission_ready)
    File.mkdir!(c.location.lock_path)

    try do
      deliver!(c.pid, ack)
      state = runtime(c.pid)
      assert state.inbox_ack_pending == cursor
      assert state.inbox_storage_error.phase == :lock
      assert state.issue_routing_cache["A"].state == "Done"
      assert head_phase?(state, :admission_ready)
      assert state.tracker_inbox_batch.head.event.entity_id == "B"
      refute_received {:inbox_read, :refresh, _, ["B"]}
    after
      File.rmdir!(c.location.lock_path)
    end

    send(c.pid, :run_webhook_cycle)
    admission = read!(:refresh, ["B"])
    assert pending_ids() == ["B"]
    refute_received {:inbox_read, :lookup, _, ["B"]}
    answer(admission, {:ok, []})
    ack!(c.pid)
    assert pending_ids() == []
  end

  for result <- [:missing, :eligible], failure <- [:lease_lock, :release_audit] do
    test "#{result} inbox lookup preserves #{failure} failure from invalidating an older promotion", c do
      {_old_reader, operation, current_issue} = preceding_admission!(c, :promotion)
      claim = runtime(c.pid).lease_claims["A"]
      lease_bytes = File.read!(claim.token.storage.lease_path)
      ledger = claim.token.storage.ledger_path
      ledger_bytes = File.read!(ledger)
      backup = ledger <> ".before-inbox-release"
      lock = claim.token.storage.lease_path <> ".lock"
      enqueue!(c.pid, [event("A")])
      reader = read!(:lookup, ["A"])
      assert :erlang.suspend_process(operation.pid)

      case unquote(failure) do
        :lease_lock ->
          File.mkdir!(lock)

        :release_audit ->
          File.rename!(ledger, backup)
          File.mkdir!(ledger)
      end

      blocked =
        try do
          answer(reader, {:ok, if(unquote(result) == :missing, do: nil, else: current_issue)})
          # Release may wait one second on its real filesystem lock. This observes
          # that cleanup; it is separate from the 500 ms tracker-read snapshot gate.
          state = await!(c.pid, &head_phase?(&1, :blocked))
          assert head_phase?(state, :blocked)
          assert state.inbox_ack_pending == nil
          assert state.inbox_storage_error.reason_code == :tracker_inbox_cleanup_failed
          assert state.tracker_inbox_batch.head.retryable == false
          refute Map.has_key?(state.issue_routing_cache, "A")
          assert state.admission_read.ref == operation.ref
          assert state.admission_read.invalidated
          assert pending_ids() == ["A"]

          case unquote(failure) do
            :lease_lock ->
              assert Enum.any?(state.tracker_inbox_batch.head.errors, &match?({:lease_release_failed, _}, &1))
              assert state.lease_claims["A"].token == claim.token
              assert File.read!(claim.token.storage.lease_path) == lease_bytes

            :release_audit ->
              assert Enum.any?(state.tracker_inbox_batch.head.errors, &match?({:lease_release_audit_failed, _}, &1))
              refute Map.has_key?(state.lease_claims, "A")
              assert {:error, :enoent} = File.read(claim.token.storage.lease_path)
              assert File.read!(backup) == ledger_bytes
          end

          state
        after
          case unquote(failure) do
            :lease_lock ->
              File.rmdir!(lock)

            :release_audit ->
              File.rmdir!(ledger)
              File.rename!(backup, ledger)
          end

          assert :erlang.resume_process(operation.pid)
        end

      current = await!(c.pid, &is_nil(&1.admission_read))
      assert current.tracker_inbox_batch.head.errors == blocked.tracker_inbox_batch.head.errors
      assert head_phase?(current, :blocked)
      deliver!(c.pid, :run_webhook_cycle)
      current = runtime(c.pid)
      assert head_phase?(current, :blocked)
      assert current.tracker_inbox_batch.head.errors == blocked.tracker_inbox_batch.head.errors
      assert current.inbox_ack_pending == nil
      refute Map.has_key?(current.issue_routing_cache, "A")
      assert pending_ids() == ["A"]
      refute_receive {:inbox_read, _, _, _}, 30
      refute_receive {:inbox_callback, :ack, _, _}, 30
    end
  end

  for phase <- [:lookup, :admission], boundary <- [:root, :fingerprint] do
    test "#{boundary} R1 to R2 to R1 during #{phase} requires a new head with the same timestamps", c do
      reader = held_head!(c.pid, unquote(phase))
      original = runtime(c.pid)
      original_ref = original.tracker_inbox_batch.head.ref
      old_operation = read_operation(original, unquote(phase))
      original_bytes = File.read!(c.location.events_path)
      original_log = Application.fetch_env!(:symphony_elixir, :log_file)

      case unquote(boundary) do
        :root -> Application.put_env(:symphony_elixir, :log_file, Path.join(c.root, "other/symphony.log"))
        :fingerprint -> write_config!(c.workflow, put_in(c.config, [:tracker, :project_slug], "other-project"))
      end

      other_location = TrackerEventInbox.location()
      if unquote(boundary) == :root, do: assert(:ok == TrackerEventInbox.initialize(other_location))
      other_bytes = File.read!(other_location.events_path)
      answer(reader, phase_answer(unquote(phase), issue("A")))
      retired = await!(c.pid, &is_nil(&1.tracker_inbox_batch))
      refute Map.has_key?(retired.issue_routing_cache, "A")
      assert retired.running == %{}
      assert retired.inbox_ack_pending == nil
      assert File.read!(c.location.events_path) == original_bytes
      assert File.read!(other_location.events_path) == other_bytes
      assert {:ok, %{rows: [_]}} = TrackerEventInbox.capture(c.location, inbox_limits())
      Application.put_env(:symphony_elixir, :log_file, original_log)
      write_config!(c.workflow, c.config)
      send(c.pid, :run_webhook_cycle)
      fresh = read!(:lookup, ["A"])
      assert runtime(c.pid).tracker_inbox_batch.head.ref != original_ref
      assert runtime(c.pid).tracker_inbox_batch.head.event.updated_at == @event_time
      refute Map.has_key?(runtime(c.pid).issue_routing_cache, "A")
      deliver!(c.pid, {:tracker_read_result, old_operation.ref, phase_answer(unquote(phase), issue("A"))})
      assert Process.alive?(fresh)
      answer(fresh, {:ok, issue("A")})
      admission = read!(:refresh, ["A"])
      refute Map.has_key?(runtime(c.pid).issue_routing_cache, "A")
      answer(admission, {:ok, [issue("A")]})
      gate = callback!(:gate, c.pid)
      assert pending_ids() == ["A"]
      refute Map.has_key?(runtime(c.pid).issue_routing_cache, "A")
      deliver!(c.pid, gate)
      wait_file!(c.ready)
      ack!(c.pid)
      assert pending_ids() == []
      assert dispatch_count("A") == 1
      release_hook!(c)
    end
  end

  for previous <- [:poll, :retry, :promotion] do
    test "inbox invalidates #{previous} before publishing its own cache and completes without self invalidation", c do
      {old_reader, old_operation, current_issue} = preceding_admission!(c, unquote(previous))
      prior_cache = runtime(c.pid).issue_routing_cache
      assert :erlang.suspend_process(old_operation.pid)

      try do
        enqueue!(c.pid, [event("A")])
        lookup = read!(:lookup, ["A"])
        answer(lookup, {:ok, current_issue})

        state =
          await!(c.pid, fn state ->
            head_phase?(state, :admission_ready) and previous_invalidated?(state, unquote(previous))
          end)

        assert state.admission_read.ref == old_operation.ref
        assert state.admission_read.monitor == old_operation.monitor
        assert Process.alive?(old_operation.pid)
        assert state.issue_routing_cache == prior_cache
        assert state.inbox_ack_pending == nil
        assert pending_ids() == ["A"]
        answer(old_reader, {:ok, [current_issue]})
      after
        assert :erlang.resume_process(old_operation.pid)
      end

      if unquote(previous) == :retry do
        ack!(c.pid)
        current = runtime(c.pid)
        assert current.retry_attempts["A"].status == :scheduled
        assert current.retry_attempts["A"].attempt == 2
        assert current.running == %{}
        assert pending_ids() == []
        refute_received {:inbox_callback, :gate, _, _}
      else
        reader = read!(:refresh, ["A"])
        current = runtime(c.pid)
        assert current.admission_read.ref != old_operation.ref
        assert current.admission_read.purpose in [:inbox_admission, :promotion]
        assert current.issue_routing_cache == prior_cache
        answer(reader, {:ok, [current_issue]})
        gate = callback!(:gate, c.pid)
        deliver!(c.pid, gate)
        wait_file!(c.ready)
        ack!(c.pid)
        assert pending_ids() == []
        assert dispatch_count("A") == 1
        release_hook!(c)
      end
    end
  end

  for phase <- [:lookup, :admission] do
    test "reset during #{phase} does not apply an old answer to a new generation with the same event id", c do
      reader = held_head!(c.pid, unquote(phase))
      old = runtime(c.pid).tracker_inbox_batch
      assert :ok = TrackerEventInbox.reset(c.location)
      assert {:ok, _} = TrackerEventInbox.enqueue([event("A")])
      assert {:ok, captured} = TrackerEventInbox.capture(c.location, inbox_limits())
      refute captured.generation == old.generation
      bytes = File.read!(c.location.events_path)
      answer(reader, phase_answer(unquote(phase), issue("A")))
      state = await!(c.pid, &is_nil(&1.tracker_inbox_batch))
      assert state.running == %{}
      assert state.inbox_ack_pending == nil
      refute Map.has_key?(state.issue_routing_cache, "A")
      assert File.read!(c.location.events_path) == bytes
      assert pending_ids() == ["A"]
      refute_received {:inbox_callback, :gate, _, _}
    end
  end

  test "malformed prefix and A are acknowledged before one autonomous 429 wakeup retries the head", c do
    assert :ok = TrackerEventInbox.initialize(c.location)
    File.write!(c.location.events_path, "invalid\n")
    enqueue!(c.pid, [event("A"), event("RATE"), event("B")])
    answer(read!(:lookup, ["A"]), {:ok, nil})
    rate = read!(:lookup, ["RATE"])
    answer(rate, {:error, {:linear_rate_limited, %{retry_after_ms: 500}}})
    ack!(c.pid)
    state = runtime(c.pid)
    assert head_phase?(state, :backoff)
    assert state.tracker_inbox_wakeup != nil
    assert pending_ids() == ["RATE", "B"]
    retried = read!(:lookup, ["RATE"])
    refute retried == rate
    answer(retried, {:ok, nil})
    answer(read!(:lookup, ["B"]), {:ok, nil})
    ack!(c.pid)
    assert pending_ids() == []
  end

  test "second-read 429 retains an unpublished head and retries it without treating itself as stale", c do
    reader = held_head!(c.pid, :admission)
    answer(reader, {:error, {:linear_rate_limited, %{retry_after_ms: 500}}})
    state = await!(c.pid, &head_phase?(&1, :backoff))
    refute Map.has_key?(state.issue_routing_cache, "A")
    assert state.inbox_ack_pending == nil
    assert pending_ids() == ["A"]
    answer(read!(:lookup, ["A"]), {:ok, issue("A")})
    answer(read!(:refresh, ["A"]), {:ok, [issue("A")]})
    deliver!(c.pid, callback!(:gate, c.pid))
    wait_file!(c.ready)
    ack!(c.pid)
    assert dispatch_count("A") == 1
    assert pending_ids() == []
    release_hook!(c)
  end

  test "a queued inbox admission survives C1 returning 429 and resumes from its single wakeup", c do
    hold_reads([:lookup, :refresh, :candidates])
    send(c.pid, :run_poll_cycle)
    answer(read!(:candidates, []), {:ok, [issue("P")]})
    poll = read!(:refresh, ["P"])
    poll_ref = runtime(c.pid).admission_read.ref
    enqueue!(c.pid, [event("A")])
    first = read!(:lookup, ["A"])
    answer(first, {:ok, issue("A")})
    waiting = await!(c.pid, &head_phase?(&1, :admission_ready))
    head_ref = waiting.tracker_inbox_batch.head.ref
    assert waiting.admission_read.ref == poll_ref
    assert waiting.inbox_ack_pending == nil
    answer(poll, {:error, {:linear_rate_limited, %{retry_after_ms: 500}}})
    backed_off = await!(c.pid, &head_phase?(&1, :backoff))
    assert backed_off.tracker_inbox_batch.head.ref == head_ref
    assert backed_off.inbox_ack_pending == nil
    assert backed_off.tracker_inbox_wakeup != nil
    wakeup_ref = backed_off.tracker_inbox_wakeup.ref
    assert runtime(c.pid).tracker_inbox_wakeup.ref == wakeup_ref
    refute Map.has_key?(backed_off.issue_routing_cache, "A")
    assert pending_ids() == ["A"]
    refute_receive {:inbox_callback, :ack, _, _}, 30
    fresh = read!(:lookup, ["A"])
    assert_receive {:inbox_wakeup_delivered, _, ^wakeup_ref}, 5_000
    assert fresh != first
    answer(fresh, {:ok, issue("A")})
    answer(read!(:refresh, ["A"]), {:ok, [issue("A")]})
    deliver!(c.pid, callback!(:gate, c.pid))
    wait_file!(c.ready)
    ack!(c.pid)
    assert pending_ids() == []
    assert dispatch_count("A") == 1
    refute_receive {:inbox_wakeup_delivered, _, _}, 30
    release_hook!(c)
  end

  test "a held wakeup for A cannot affect B after an explicit drain advances the head", c do
    assert :ok = GenServer.call(c.pid, {:hold, :wakeup, true})
    enqueue!(c.pid, [event("A"), event("B")])
    answer(read!(:lookup, ["A"]), {:error, {:linear_rate_limited, %{retry_after_ms: 500}}})
    backed_off = await!(c.pid, &head_phase?(&1, :backoff))
    wakeup = backed_off.tracker_inbox_wakeup
    assert wakeup.head_ref == backed_off.tracker_inbox_batch.head.ref
    message = {:tracker_inbox_wakeup, ref, _, _} = callback!(:wakeup, c.pid)
    assert ref == wakeup.ref
    assert Process.read_timer(wakeup.timer) == false
    send(c.pid, :run_webhook_cycle)
    answer(read!(:lookup, ["A"]), {:ok, nil})
    reader = read!(:lookup, ["B"])
    before = runtime(c.pid)
    assert before.tracker_inbox_wakeup == nil
    assert before.tracker_inbox_batch.head.event.entity_id == "B"
    refute before.tracker_inbox_batch.head.ref == wakeup.head_ref
    deliver!(c.pid, message)
    after_wakeup = runtime(c.pid)
    assert after_wakeup.tracker_inbox_batch == before.tracker_inbox_batch
    assert after_wakeup.tracker_poll_read.ref == before.tracker_poll_read.ref
    assert after_wakeup.tracker_inbox_wakeup == nil
    assert after_wakeup.inbox_ack_pending == nil
    assert after_wakeup.issue_routing_cache == %{}
    assert Process.alive?(reader)
    refute_receive {:inbox_read, _, _, _}, 30
    refute_receive {:inbox_callback, :ack, _, _}, 30
    answer(reader, {:ok, nil})
    ack!(c.pid)
    assert pending_ids() == []
  end

  test "an extended backoff replaces its expired wakeup once and ignores the old callback", c do
    assert :ok = GenServer.call(c.pid, {:hold, :wakeup, true})
    reader = held_head!(c.pid, :lookup)
    answer(reader, {:error, {:linear_rate_limited, %{retry_after_ms: 500}}})
    backed_off = await!(c.pid, &head_phase?(&1, :backoff))
    old = backed_off.tracker_inbox_wakeup
    message = callback!(:wakeup, c.pid)
    assert Process.read_timer(old.timer) == false
    # The real timer has expired. Move only the owner's backoff deadline forward
    # before delivering its held callback, as a later transport observation would.
    extended_until = System.monotonic_time(:millisecond) + 500
    replace_runtime(c.pid, &%{&1 | tracker_backoff_until_ms: extended_until})
    deliver!(c.pid, message)
    extended = runtime(c.pid)
    next = extended.tracker_inbox_wakeup
    refute next.ref == old.ref
    assert next.head_ref == old.head_ref
    assert next.head_ref == extended.tracker_inbox_batch.head.ref
    assert next.backoff == {extended_until, extended.tracker_backoff_reason, extended.tracker_backoff_rule_id}
    refute next.backoff == old.backoff
    assert is_integer(Process.read_timer(next.timer))
    assert head_phase?(extended, :backoff)
    assert extended.inbox_ack_pending == nil
    deliver!(c.pid, message)
    assert runtime(c.pid).tracker_inbox_wakeup == next
    refute_receive {:inbox_read, _, _, _}, 30
    refute_receive {:inbox_callback, :ack, _, _}, 30
    next_message = {:tracker_inbox_wakeup, next_ref, _, _} = callback!(:wakeup, c.pid)
    assert next_ref == next.ref
    assert Process.read_timer(next.timer) == false
    deliver!(c.pid, next_message)
    fresh = read!(:lookup, ["A"])
    assert fresh != reader
    assert runtime(c.pid).tracker_inbox_wakeup == nil
    answer(fresh, {:ok, nil})
    ack!(c.pid)
    assert pending_ids() == []
    refute_receive {:inbox_callback, :wakeup, _, _}, 30
  end

  test "an appended row is not included in the captured batch's confirmation", c do
    enqueue!(c.pid, [event("A")])
    reader = read!(:lookup, ["A"])
    original = runtime(c.pid).tracker_inbox_batch
    assert {:ok, _} = TrackerEventInbox.enqueue([event("B")])
    answer(reader, {:ok, nil})
    ack = {:tracker_inbox_ack, cursor} = callback!(:ack, c.pid)
    assert cursor.end_offset == List.last(original.rows).cursor.end_offset
    assert pending_ids() == ["A", "B"]
    refute_received {:inbox_read, :lookup, _, ["B"]}
    deliver!(c.pid, ack)
    second = read!(:lookup, ["B"])
    assert pending_ids() == ["B"]
    assert runtime(c.pid).tracker_inbox_batch.ref != original.ref
    answer(second, {:ok, nil})
    ack!(c.pid)
  end

  test "a terminal answer observed for W1 cannot terminate W2 or alter its snapshot", c do
    hold_reads([:lookup])
    current_issue = %{issue("A") | state: "In Progress"}
    old_worker = install_worker!(c.pid, current_issue)
    enqueue!(c.pid, [event("A")])
    reader = read!(:lookup, ["A"])
    old_operation = runtime(c.pid).tracker_poll_read
    replacement = fixture_worker!(c.pid)
    workspace = Workspace.path_for_issue(current_issue)
    bytes = File.read!(RunStateStore.state_path(workspace))

    replace_runtime(c.pid, fn state ->
      entry = state.running["A"]
      Process.demonitor(entry.ref, [:flush])
      %{state | running: Map.put(state.running, "A", %{entry | pid: replacement, ref: Process.monitor(replacement)})}
    end)

    assert :ok = GenServer.call(c.pid, {:hold, :continue, true})
    answer(reader, {:ok, %{current_issue | state: "Done"}})
    continuation = callback!(:continue, c.pid)
    assert runtime(c.pid).running["A"].pid == replacement
    assert Process.alive?(replacement)
    assert Process.alive?(old_worker)
    assert File.read!(RunStateStore.state_path(workspace)) == bytes
    assert pending_ids() == ["A"]
    assert :ok = GenServer.call(c.pid, {:hold, :continue, false})
    deliver!(c.pid, continuation)
    fresh = read!(:lookup, ["A"])
    deliver!(c.pid, {:tracker_read_result, old_operation.ref, {:ok, %{current_issue | state: "Done"}}})
    assert Process.alive?(fresh)
    answer(fresh, {:ok, current_issue})
    ack!(c.pid)
    assert runtime(c.pid).running["A"].pid == replacement
    assert pending_ids() == []
  end

  test "a cache change without a timestamp discards the held observation and rereads its head", c do
    reader = held_head!(c.pid, :lookup)
    cache = %{state: "In Progress", assignee_id: "replacement-assignee", labels: ["changed"], updated_at: nil}
    replace_runtime(c.pid, &%{&1 | issue_routing_cache: Map.put(&1.issue_routing_cache, "A", cache)})
    answer(reader, {:ok, issue("A")})
    fresh = read!(:lookup, ["A"])
    assert runtime(c.pid).issue_routing_cache["A"] == cache
    assert runtime(c.pid).inbox_ack_pending == nil
    assert pending_ids() == ["A"]
    answer(fresh, {:ok, nil})
    ack!(c.pid)
    assert runtime(c.pid).issue_routing_cache["A"] == cache
  end

  test "reset after an applied decision rejects its old ack and preserves the new generation", c do
    reader = held_head!(c.pid, :lookup)
    answer(reader, {:ok, nil})
    ack = {:tracker_inbox_ack, old_cursor} = callback!(:ack, c.pid)
    assert :ok = TrackerEventInbox.reset(c.location)
    assert {:ok, _} = TrackerEventInbox.enqueue([event("A")])
    assert {:ok, captured} = TrackerEventInbox.capture(c.location, inbox_limits())
    refute captured.generation == old_cursor.generation
    new_state_bytes = File.read!(c.location.state_path)
    new_events_bytes = File.read!(c.location.events_path)
    deliver!(c.pid, ack)
    state = runtime(c.pid)
    assert state.inbox_ack_pending == nil
    assert state.inbox_storage_error.reason_code == :generation_changed
    assert pending_ids() == ["A"]
    assert File.read!(c.location.state_path) == new_state_bytes
    assert File.read!(c.location.events_path) == new_events_bytes
    refute_receive {:inbox_callback, :ack, _, _}, 30
    send(c.pid, :run_webhook_cycle)
    reader = read!(:lookup, ["A"])
    ref = runtime(c.pid).tracker_inbox_batch.head.ref
    deliver!(c.pid, ack)
    assert runtime(c.pid).tracker_inbox_batch.head.ref == ref
    assert Process.alive?(reader)
    answer(reader, {:ok, nil})
    ack!(c.pid)
  end

  test "a reset rejects an applied prefix once while an older promotion cleanup error stays blocked", c do
    {_old_reader, operation, _current_issue} = preceding_admission!(c, :promotion)
    claim = runtime(c.pid).lease_claims["A"]
    lease_bytes = File.read!(claim.token.storage.lease_path)
    lock = claim.token.storage.lease_path <> ".lock"
    assert :ok = TrackerEventInbox.initialize(c.location)
    File.write!(c.location.events_path, "invalid\n")
    enqueue!(c.pid, [event("A")])
    reader = read!(:lookup, ["A"])
    assert :erlang.suspend_process(operation.pid)
    File.mkdir!(lock)

    {blocked, state_bytes, events_bytes} =
      try do
        answer(reader, {:ok, nil})
        blocked = await!(c.pid, &head_phase?(&1, :blocked))
        assert blocked.tracker_inbox_batch.head.retryable == false
        assert Enum.any?(blocked.tracker_inbox_batch.head.errors, &match?({:lease_release_failed, _}, &1))
        ack = {:tracker_inbox_ack, cursor} = callback!(:ack, c.pid)
        assert blocked.inbox_ack_pending == cursor
        assert blocked.tracker_inbox_batch.applied_cursor == cursor
        assert :ok = TrackerEventInbox.reset(c.location)
        assert {:ok, _} = TrackerEventInbox.enqueue([event("NEW")])
        assert {:ok, captured} = TrackerEventInbox.capture(c.location, inbox_limits())
        refute captured.generation == cursor.generation
        state_bytes = File.read!(c.location.state_path)
        events_bytes = File.read!(c.location.events_path)
        deliver!(c.pid, ack)
        rejected = runtime(c.pid)
        assert rejected.inbox_ack_pending == nil
        assert rejected.tracker_inbox_batch.applied_cursor == nil
        assert rejected.inbox_storage_error.reason_code == :generation_changed
        assert rejected.tracker_inbox_batch.head.errors == blocked.tracker_inbox_batch.head.errors
        assert rejected.tracker_inbox_batch.head.retryable == false
        assert File.read!(claim.token.storage.lease_path) == lease_bytes
        assert rejected.issue_routing_cache == %{}
        assert pending_ids() == ["NEW"]
        assert File.read!(c.location.state_path) == state_bytes
        assert File.read!(c.location.events_path) == events_bytes
        refute_receive {:inbox_callback, :ack, _, _}, 30
        {blocked, state_bytes, events_bytes}
      after
        File.rmdir!(lock)
        assert :erlang.resume_process(operation.pid)
      end

    await!(c.pid, &is_nil(&1.admission_read))
    deliver!(c.pid, :run_webhook_cycle)
    current = runtime(c.pid)
    assert head_phase?(current, :blocked)
    assert current.tracker_inbox_batch.head.retryable == false
    assert current.tracker_inbox_batch.head.errors == blocked.tracker_inbox_batch.head.errors
    assert current.tracker_inbox_batch.applied_cursor == nil
    assert current.inbox_ack_pending == nil
    assert current.issue_routing_cache == %{}
    assert File.read!(claim.token.storage.lease_path) == lease_bytes
    assert File.read!(c.location.state_path) == state_bytes
    assert File.read!(c.location.events_path) == events_bytes
    assert pending_ids() == ["NEW"]
    refute_receive {:inbox_read, _, _, _}, 30
    refute_receive {:inbox_callback, :ack, _, _}, 30
  end

  for invalid <- [17, %{"id" => "A"}] do
    @tag invalid_entity: invalid
    test "raw non-string entity #{inspect(invalid)} is discarded without a tracker call", c do
      assert {:ok, _} = TrackerEventInbox.enqueue([event("RAW")])
      record = c.location.events_path |> File.read!() |> String.trim_trailing("\n") |> Jason.decode!()
      record = put_in(record, ["event", "entity_id"], c.invalid_entity)
      File.write!(c.location.events_path, Jason.encode!(record) <> "\n")
      assert {:ok, _} = TrackerEventInbox.enqueue([event("B")])
      send(c.pid, :run_webhook_cycle)
      answer(read!(:lookup, ["B"]), {:ok, nil})
      ack!(c.pid)
      assert pending_ids() == []
      assert runtime(c.pid).issue_routing_cache == %{}
      invalid = c.invalid_entity
      refute_received {:inbox_read, :lookup, _, [^invalid]}
    end
  end

  test "a full 100-row capture yields before its existing tail and does not absorb a later append", c do
    assert {:ok, _} = TrackerEventInbox.enqueue([event("A")])
    File.write!(c.location.events_path, String.duplicate("invalid\n", 99), [:append])
    assert {:ok, _} = TrackerEventInbox.enqueue([event("TAIL")])
    hold_reads([:lookup, :candidates])
    send(c.pid, :run_webhook_cycle)
    reader = read!(:lookup, ["A"])
    original = runtime(c.pid).tracker_inbox_batch
    assert length(original.rows) == 100
    assert original.limit_reached
    assert {:ok, _} = TrackerEventInbox.enqueue([event("APPEND")])
    send(c.pid, :run_poll_cycle)
    answer(reader, {:ok, nil})
    discovery = read!(:candidates, [])
    answer(discovery, {:ok, []})
    ack = {:tracker_inbox_ack, cursor} = callback!(:ack, c.pid)
    assert cursor.end_offset == List.last(original.rows).cursor.end_offset
    refute_received {:inbox_read, :lookup, _, ["TAIL"]}
    refute_received {:inbox_read, :lookup, _, ["APPEND"]}
    deliver!(c.pid, ack)
    tail = read!(:lookup, ["TAIL"])
    assert pending_ids() == ["TAIL", "APPEND"]
    assert runtime(c.pid).tracker_inbox_batch.ref != original.ref
    answer(tail, {:ok, nil})
    answer(read!(:lookup, ["APPEND"]), {:ok, nil})
    ack!(c.pid)
    assert pending_ids() == []
  end

  test "discardable prefixes reach one valid head while valid decisions still yield", c do
    assert :ok = TrackerEventInbox.initialize(c.location)

    prefix = [
      "invalid",
      Jason.encode!(%{"unexpected" => "record"}),
      Jason.encode!(%{"event" => %{"entity_type" => "Comment", "entity_id" => "IGNORED", "action" => "update"}}),
      Jason.encode!(%{"event" => %{"entity_id" => 17}}),
      Jason.encode!(%{"event" => %{"entity_id" => ""}})
    ]

    File.write!(c.location.events_path, Enum.join(prefix, "\n") <> "\n")
    assert {:ok, _} = TrackerEventInbox.enqueue([event("A")])
    File.write!(c.location.events_path, "invalid\n", [:append])
    assert {:ok, _} = TrackerEventInbox.enqueue([event("B")])
    assert {:ok, captured} = TrackerEventInbox.capture(c.location, inbox_limits())
    state_bytes = File.read!(c.location.state_path)
    assert :ok = GenServer.call(c.pid, {:hold, :continue, true})
    send(c.pid, :run_webhook_cycle)

    first = read!(:lookup, ["A"])
    state = runtime(c.pid)
    batch_ref = state.tracker_inbox_batch.ref
    assert state.tracker_inbox_batch.head.event.entity_id == "A"
    assert length(state.tracker_inbox_batch.rows) == 3
    assert state.tracker_inbox_batch.end_offset == List.last(captured.rows).cursor.end_offset
    assert state.tracker_inbox_batch.applied_cursor == Enum.at(captured.rows, 4).cursor
    assert state.issue_routing_cache == %{}
    assert File.read!(c.location.state_path) == state_bytes
    refute_received {:inbox_callback, :continue, _, _}
    refute_received {:inbox_callback, :ack, _, _}

    answer(first, {:ok, nil})
    continuation = callback!(:continue, c.pid)
    assert length(runtime(c.pid).tracker_inbox_batch.rows) == 2
    refute_received {:inbox_read, :lookup, _, ["B"]}
    deliver!(c.pid, continuation)

    second = read!(:lookup, ["B"])
    state = runtime(c.pid)
    assert state.tracker_inbox_batch.ref == batch_ref
    assert state.tracker_inbox_batch.end_offset == List.last(captured.rows).cursor.end_offset
    assert state.tracker_inbox_batch.head.event.entity_id == "B"
    assert length(state.tracker_inbox_batch.rows) == 1
    assert state.tracker_inbox_batch.applied_cursor == Enum.at(captured.rows, 6).cursor
    assert File.read!(c.location.state_path) == state_bytes
    refute_received {:inbox_callback, :continue, _, _}
    answer(second, {:ok, nil})
    deliver!(c.pid, callback!(:continue, c.pid))
    assert {:tracker_inbox_ack, cursor} = ack!(c.pid)
    assert cursor == List.last(captured.rows).cursor
    assert pending_ids() == []
  end

  for mutation <- [:bytes, :generation] do
    @tag prefix_mutation: mutation
    test "a discard-only bounded prefix keeps checked acknowledgment after #{mutation} changes", c do
      assert :ok = TrackerEventInbox.initialize(c.location)
      File.write!(c.location.events_path, String.duplicate("invalid\n", 100))
      assert {:ok, _} = TrackerEventInbox.enqueue([event("TAIL")])
      assert {:ok, captured} = TrackerEventInbox.capture(c.location, inbox_limits())
      assert captured.limit_reached
      assert :ok = GenServer.call(c.pid, {:hold, :continue, true})
      send(c.pid, :run_webhook_cycle)
      ack = {:tracker_inbox_ack, cursor} = callback!(:ack, c.pid)
      assert cursor == List.last(captured.rows).cursor
      assert runtime(c.pid).tracker_inbox_batch.rows == []
      refute_received {:inbox_callback, :continue, _, _}
      assert {:ok, _} = TrackerEventInbox.enqueue([event("APPEND")])

      case c.prefix_mutation do
        :bytes ->
          bytes = File.read!(c.location.events_path)
          File.write!(c.location.events_path, String.replace(bytes, "invalid\n", "changed\n", global: false))

        :generation ->
          assert :ok = TrackerEventInbox.reset(c.location)
          assert {:ok, _} = TrackerEventInbox.enqueue([event("NEW")])
      end

      state_bytes = File.read!(c.location.state_path)
      events_bytes = File.read!(c.location.events_path)
      deliver!(c.pid, ack)
      state = runtime(c.pid)

      case c.prefix_mutation do
        :bytes ->
          assert state.inbox_storage_error.reason_code == :prefix_changed
          assert state.inbox_ack_pending == cursor

        :generation ->
          assert state.inbox_storage_error.reason_code == :generation_changed
          assert state.inbox_ack_pending == nil
      end

      assert File.read!(c.location.state_path) == state_bytes
      assert File.read!(c.location.events_path) == events_bytes
      assert state.issue_routing_cache == %{}
      assert state.running == %{}
      refute_received {:inbox_read, :lookup, _, _}
    end
  end

  test "equivalent JSON with different physical bytes cannot renew a blocked head's cursor", c do
    reader = held_head!(c.pid, :lookup)
    original = runtime(c.pid).tracker_inbox_batch
    bytes = File.read!(c.location.events_path)
    record = Jason.decode!(String.trim_trailing(bytes, "\n"))
    state_bytes = File.read!(c.location.state_path)
    send(reader, :raise)
    await!(c.pid, &head_phase?(&1, :blocked))
    keys = Enum.sort(Map.keys(record))

    changed =
      [keys, Enum.reverse(keys)]
      |> Enum.map(fn order ->
        "{" <> Enum.map_join(order, ",", fn key -> Jason.encode!(key) <> ":" <> Jason.encode!(Map.fetch!(record, key)) end) <> "}\n"
      end)
      |> Enum.find(&(&1 != bytes))

    assert is_binary(changed)
    assert byte_size(changed) == byte_size(bytes)
    assert Jason.decode!(changed) == record
    File.write!(c.location.events_path, changed)
    deliver!(c.pid, :run_webhook_cycle)
    state = await!(c.pid, &(&1.inbox_storage_error.reason_code == :tracker_inbox_prefix_changed))
    assert head_phase?(state, :blocked)
    assert state.tracker_inbox_batch.head.row.cursor == original.head.row.cursor
    assert state.inbox_ack_pending == nil
    assert state.issue_routing_cache == %{}
    assert state.running == %{}
    assert File.read!(c.location.state_path) == state_bytes
    assert File.read!(c.location.events_path) == changed
    assert pending_ids() == ["A"]
    refute_receive {:inbox_read, _, _, _}, 30
    refute_receive {:inbox_callback, :ack, _, _}, 30
  end

  test "two actual discovery writes invalidate an admission across timestamp-free cache A to B to A", c do
    baseline = %{state: "Todo", assignee_id: nil, labels: [], updated_at: nil}
    replace_runtime(c.pid, &%{&1 | issue_routing_cache: %{"A" => baseline}})
    reader = held_head!(c.pid, :admission)
    operation = runtime(c.pid).admission_read
    hold_reads([:lookup, :refresh, :candidates])
    assert :erlang.suspend_process(operation.pid)

    try do
      for state_name <- ["In Progress", "Todo"] do
        send(c.pid, :run_poll_cycle)
        discovery = read!(:candidates, [])
        candidate = %{issue("A") | state: state_name, assigned_to_worker: false, updated_at: nil}
        answer(discovery, {:ok, [candidate]})
        await!(c.pid, fn state -> is_nil(state.tracker_poll_read) and state.issue_routing_cache["A"].state == state_name end)
      end

      state = runtime(c.pid)
      assert state.issue_routing_cache["A"] == baseline
      assert state.admission_read.ref == operation.ref
      assert state.admission_read.invalidated
      assert state.inbox_ack_pending == nil
      assert pending_ids() == ["A"]
      answer(reader, {:ok, [issue("A")]})
    after
      assert :erlang.resume_process(operation.pid)
    end

    fresh = read!(:lookup, ["A"])
    deliver!(c.pid, {:tracker_read_result, operation.ref, {:ok, [issue("A")]}})
    assert Process.alive?(fresh)
    assert runtime(c.pid).issue_routing_cache["A"] == baseline
    answer(fresh, {:ok, issue("A")})
    answer(read!(:refresh, ["A"]), {:ok, [issue("A")]})
    deliver!(c.pid, callback!(:gate, c.pid))
    wait_file!(c.ready)
    ack!(c.pid)
    assert pending_ids() == []
    assert dispatch_count("A") == 1
    release_hook!(c)
  end

  test "an incomplete physical tail remains pending without a false completed drain", c do
    assert :ok = TrackerEventInbox.initialize(c.location)
    bytes = "{\"event\":{\"entity_id\":\"private-partial\""
    File.write!(c.location.events_path, bytes)
    deliver!(c.pid, :run_webhook_cycle)
    await!(c.pid, &(is_nil(&1.tracker_poll_cycle) and is_nil(&1.tracker_poll_read) and not &1.poll_check_in_progress))
    state = runtime(c.pid)
    assert state.inbox_last_drained_at == nil
    assert state.inbox_ack_pending == nil
    assert File.read!(c.location.events_path) == bytes
    refute inspect(Orchestrator.snapshot(c.pid, 5_000).tracker_inbox) =~ "private-partial"
    refute_received {:inbox_read, _, _, _}
    refute_received {:inbox_callback, :ack, _, _}
  end

  test "a discordant first lookup cannot update either routing cache or acquire another issue's lease", c do
    reader = held_head!(c.pid, :lookup)
    answer(reader, {:ok, issue("OTHER")})
    ack!(c.pid)
    state = runtime(c.pid)
    assert state.issue_routing_cache == %{}
    assert state.running == %{}
    assert {:error, :missing} = LeaseManager.read("A")
    assert {:error, :missing} = LeaseManager.read("OTHER")
    refute_received {:inbox_read, :refresh, _, _}
  end

  for invalid <- [:wrong_id, :missing_identifier, :multiple] do
    test "second lookup rejects #{invalid} before merge, cache publication or lease acquisition", c do
      reader = held_head!(c.pid, :admission)

      result =
        case unquote(invalid) do
          :wrong_id -> [issue("OTHER")]
          :missing_identifier -> [%{issue("A") | identifier: nil}]
          :multiple -> [issue("A"), issue("OTHER")]
        end

      answer(reader, {:ok, result})
      ack!(c.pid)
      state = runtime(c.pid)
      assert state.running == %{}
      refute Map.has_key?(state.issue_routing_cache, "OTHER")
      assert {:error, :missing} = LeaseManager.read("A")
      assert {:error, :missing} = LeaseManager.read("OTHER")
      assert pending_ids() == []
      refute_received {:inbox_callback, :gate, _, _}
    end
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: "ISSUE-" <> id,
      title: "Controlled inbox issue",
      description: "Local fixture",
      state: "Todo",
      labels: [],
      source: :tracker,
      assigned_to_worker: true,
      updated_at: @event_time
    }
  end

  defp event(id) do
    %TrackerEvent{provider: "linear", event_id: "event-" <> id, entity_type: "Issue", entity_id: id, issue_identifier: "ISSUE-" <> id, action: "update", updated_at: @event_time, raw: %{}}
  end

  defp enqueue!(pid, events) do
    assert {:ok, %{accepted: count}} = TrackerEventInbox.enqueue(events)
    assert count == length(events)
    send(pid, :run_webhook_cycle)
  end

  defp hold_reads(kinds), do: Application.put_env(:symphony_elixir, :tracker_inbox_async_fixture, %{owner: self(), held_reads: MapSet.new(kinds)})
  defp runtime(pid), do: GenServer.call(pid, :runtime, 5_000)
  defp answer(reader, result), do: send(reader, {:answer, result})
  defp deliver!(pid, message), do: assert(:ok == GenServer.call(pid, {:deliver, message}))
  defp replace_runtime(pid, fun), do: :sys.replace_state(pid, fn state -> %{state | runtime: fun.(state.runtime)} end)
  defp head_phase?(%{tracker_inbox_batch: %{head: %{phase: phase}}}, phase), do: true
  defp head_phase?(_state, _phase), do: false
  defp previous_invalidated?(state, :poll), do: MapSet.member?(state.admission_batch.invalidated, "A")
  defp previous_invalidated?(state, _previous), do: state.admission_read.invalidated
  defp read_operation(state, :lookup), do: state.tracker_poll_read
  defp read_operation(state, :admission), do: state.admission_read
  defp phase_answer(:lookup, issue), do: {:ok, issue}
  defp phase_answer(:admission, issue), do: {:ok, [issue]}
  defp inbox_limits, do: %{max_rows: 100, max_bytes: 4 * 1024 * 1024}
  defp pending_ids, do: Enum.map(TrackerEventInbox.pending_events(100), & &1["event"]["entity_id"])

  defp read!(kind, ids) do
    assert_receive {:inbox_read, ^kind, reader, ^ids}, 5_000
    reader
  end

  defp callback!(kind, pid) do
    assert_receive {:inbox_callback, ^kind, ^pid, message}, 5_000
    message
  end

  defp ack!(pid) do
    message = callback!(:ack, pid)
    deliver!(pid, message)
    await!(pid, &is_nil(&1.inbox_ack_pending))
    message
  end

  defp held_head!(pid, phase) do
    enqueue!(pid, [event("A")])
    reader = read!(:lookup, ["A"])

    if phase == :lookup do
      reader
    else
      answer(reader, {:ok, issue("A")})
      reader = read!(:refresh, ["A"])
      assert runtime(pid).admission_read.purpose == :inbox_admission
      reader
    end
  end

  defp retry_entry(id) do
    %{attempt: 2, retry_ref: make_ref(), status: :scheduled, timer_ref: nil, due_at_ms: 0, identifier: "ISSUE-" <> id, delay_type: :continuation}
  end

  defp promotion_issue!(id) do
    issue = %{issue(id) | state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    assert {:ok, _} = RunStateStore.transition(workspace, "await_checks", %{issue_id: issue.id, issue_identifier: issue.identifier})
    issue
  end

  defp preceding_admission!(c, :promotion) do
    issue = %{promotion_issue!("A") | updated_at: nil}
    assert :ok = GenServer.call(c.pid, {:dispatch, issue})
    reader = read!(:refresh, ["A"])
    assert runtime(c.pid).admission_read.purpose == :promotion
    {reader, runtime(c.pid).admission_read, %{issue | updated_at: @event_time}}
  end

  defp preceding_admission!(c, :retry) do
    hold_reads([:lookup, :refresh, :candidates])
    retry = retry_entry("A")
    replace_runtime(c.pid, &%{&1 | retry_attempts: %{"A" => retry}})
    send(c.pid, {:retry_issue, "A", retry.retry_ref})
    answer(read!(:candidates, []), {:ok, [%{issue("A") | updated_at: nil}]})
    reader = read!(:refresh, ["A"])
    {reader, runtime(c.pid).admission_read, issue("A")}
  end

  defp preceding_admission!(c, :poll) do
    hold_reads([:lookup, :refresh, :candidates])
    send(c.pid, :run_poll_cycle)
    answer(read!(:candidates, []), {:ok, [%{issue("A") | updated_at: nil}]})
    reader = read!(:refresh, ["A"])
    {reader, runtime(c.pid).admission_read, issue("A")}
  end

  defp install_worker!(pid, issue) do
    worker = fixture_worker!(pid)
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    assert :ok = RunStateStore.save(workspace, RunStateStore.load_or_default(workspace, issue))
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, runtime(pid).lease_owner)
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

    replace_runtime(pid, fn state ->
      entry = %{
        session_id: nil,
        pid: worker,
        ref: Process.monitor(worker),
        identifier: issue.identifier,
        issue: issue,
        custody_ref: custody_ref,
        lease_token: acquired.token,
        lease_owner: acquired.token.owner,
        lease_epoch: acquired.token.epoch,
        started_at: DateTime.utc_now(),
        last_event_at: DateTime.utc_now(),
        last_agent_timestamp: nil,
        last_agent_message: nil,
        last_agent_event: nil,
        agent_process_id: nil,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        issue_token_usage_base: %{},
        recent_agent_updates: [],
        turn_count: 0
      }

      %{state | running: Map.put(state.running, issue.id, entry), lease_claims: Map.put(state.lease_claims, issue.id, claim), claimed: MapSet.put(state.claimed, issue.id)}
    end)

    worker
  end

  defp fixture_worker!(pid) do
    {:ok, worker} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn ->
      cleanup_driver!(pid)

      if Process.alive?(worker) do
        ref = Process.monitor(worker)
        assert :ok = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker)
        assert_receive {:DOWN, ^ref, :process, ^worker, _}, 5_000
      end
    end)

    worker
  end

  defp dispatch_count(id) do
    RunLedger.recent_entries() |> Enum.count(&(&1["event_type"] == "dispatch.started" and &1["issue_id"] == id))
  end

  defp dispatch_count_at(path, id) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.count(&(&1["event_type"] == "dispatch.started" and &1["issue_id"] == id))
  end

  defp write_config!(path, config) do
    File.write!(path, "---\n" <> Jason.encode!(config) <> "\n---\nControlled inbox fixture.\n")
    assert :ok = Workflow.set_workflow_file_path(path)
    assert :ok = WorkflowStore.force_reload()
    assert :ok = Config.validate!()
  end

  defp release_hook!(c) do
    File.write!(c.release, "continue")
    wait_file!(c.exited)
    assert File.read!(c.exited) == "released"
  end

  defp wait_file!(path), do: wait_file!(path, System.monotonic_time(:millisecond) + 5_000)

  defp wait_file!(path, deadline) do
    unless File.exists?(path) do
      assert System.monotonic_time(:millisecond) < deadline, "hook did not reach #{Path.basename(path)}"

      receive do
      after
        5 -> wait_file!(path, deadline)
      end
    end
  end

  defp await!(pid, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000
    state = GenServer.call(pid, :runtime, 5_000)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "inbox state did not settle: #{inspect(state, limit: 8)}"

      receive do
      after
        5 -> await!(pid, predicate, deadline)
      end
    end
  end

  defp cleanup_driver!(pid) do
    if Process.alive?(pid) do
      assert :ok = :sys.suspend(pid)
      state = :sys.get_state(pid).runtime
      operations = Enum.reject([state.tracker_poll_read, state.admission_read], &is_nil/1)
      workers = Enum.map(state.running, fn {_id, entry} -> entry.pid end)
      refs = Enum.map(Enum.uniq(Enum.map(operations, & &1.pid) ++ workers), &{&1, Process.monitor(&1)})

      :sys.replace_state(pid, fn wrapper ->
        Enum.each(operations, fn operation -> assert :ok = TrackerReader.cancel(operation) end)
        Enum.each(wrapper.runtime.retry_attempts, fn {_id, retry} -> if is_reference(retry.timer_ref), do: Process.cancel_timer(retry.timer_ref) end)
        Enum.each(wrapper.runtime.lease_claims, fn {_id, claim} -> if is_reference(claim.timer), do: Process.cancel_timer(claim.timer) end)
        if wrapper.runtime.tracker_inbox_wakeup, do: Process.cancel_timer(wrapper.runtime.tracker_inbox_wakeup.timer)
        wrapper
      end)

      GenServer.stop(pid)
      Enum.each(workers, fn worker -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
      Enum.each(refs, fn {worker, ref} -> assert_receive {:DOWN, ^ref, :process, ^worker, _}, 5_000 end)
    end
  end

  defp pause_default_scheduler! do
    if pid = Process.whereis(Orchestrator) do
      deadline = System.monotonic_time(:millisecond) + 5_000
      wait_default_idle!(pid, deadline)
      assert :ok = :sys.suspend(pid)
      on_exit(fn -> assert :ok = :sys.resume(pid) end)
    end
  end

  defp wait_default_idle!(pid, deadline) do
    state = :sys.get_state(pid, 5_000)

    if state.running == %{} and is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and is_nil(state.admission_read) and state.tracker_poll_pending == [] and
         not state.poll_check_in_progress do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "default scheduler must be idle before inbox fixture"

      receive do
      after
        5 -> wait_default_idle!(pid, deadline)
      end
    end
  end
end
