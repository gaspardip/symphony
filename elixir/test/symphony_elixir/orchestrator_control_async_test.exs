defmodule SymphonyElixir.OrchestratorControlAsyncTest do
  use SymphonyElixir.TestSupport
  @moduletag timeout: 30_000

  alias SymphonyElixir.{DispatchAudit, LeaseManager, ManualIssueStore, RunLedger, RunStateStore, TrackerReader}
  alias SymphonyElixir.Orchestrator.State

  defmodule Client do
    def fetch_issue_by_identifier(identifier), do: read(:identifier, identifier)
    def fetch_issue_by_id(id), do: read(:refresh, id)
    def fetch_issue_states_by_ids(ids), do: read(:promotion, ids)
    def fetch_candidate_issues, do: read(:candidates, [])
    def fetch_issues_by_states(_states), do: {:ok, []}

    defp read(kind, argument) do
      fixture = Application.fetch_env!(:symphony_elixir, :control_async_fixture)

      if kind in fixture.hold do
        send(fixture.owner, {:control_read, kind, self(), argument})

        receive do
          {:answer, value} -> value
          :raise -> raise "controlled read failure"
        after
          6_000 -> raise "control reader was not released"
        end
      else
        if kind == :candidates, do: {:ok, []}, else: {:ok, fixture.issue}
      end
    end

    def graphql(query, variables) do
      fixture = Application.fetch_env!(:symphony_elixir, :control_async_fixture)

      kind =
        cond do
          String.contains?(query, "commentCreate") -> :comment
          String.contains?(query, "issueUpdate") -> :state
          true -> :state_lookup
        end

      if kind != :state_lookup, do: send(fixture.owner, {:control_write, kind, self(), variables})

      if kind in fixture.hold_writes do
        receive do
          {:writer_answer, result} -> result
        after
          6_000 -> raise "control writer was not released"
        end
      else
        {:ok,
         %{
           "data" => %{
             "commentCreate" => %{"success" => true},
             "issueUpdate" => %{"success" => true},
             "issue" => %{"team" => %{"id" => "team-#{fixture.issue.id}", "states" => %{"nodes" => [%{"id" => "state-#{Map.get(variables, :stateName)}"}]}}}
           }
         }}
      end
    end
  end

  defmodule Driver do
    use GenServer
    def start_link(runtime, observer), do: GenServer.start_link(__MODULE__, {runtime, observer})
    @impl true
    def init({runtime, observer}), do: {:ok, %{runtime: runtime, observer: observer, gate: nil, hold_gate: true}}
    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

    def handle_call(:deliver_gate, _from, %{gate: gate} = state) when not is_nil(gate) do
      {:noreply, runtime} = Orchestrator.handle_info(gate, state.runtime)
      {:reply, :ok, %{state | runtime: runtime, gate: nil}}
    end

    def handle_call(:cleanup, _from, state) do
      readers = Enum.reject([state.runtime.admission_read, state.runtime.tracker_poll_read], &is_nil/1)
      Enum.each(readers, fn reader -> :ok = TrackerReader.cancel(reader) end)
      runtime = Enum.reduce(Map.keys(state.runtime.running), state.runtime, &Orchestrator.terminate_running_issue(&2, &1, false))
      {:reply, readers, %{state | runtime: runtime}}
    end

    def handle_call(message, from, state) do
      case Orchestrator.handle_call(message, from, state.runtime) do
        {:reply, reply, runtime} -> {:reply, reply, %{state | runtime: runtime}}
        {:noreply, runtime} -> {:noreply, %{state | runtime: runtime}}
      end
    end

    @impl true
    def handle_info({:authorize_dispatch, _, _, _} = message, %{hold_gate: true} = state) do
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
    root = Path.join(System.tmp_dir!(), "c6-control-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Enum.map([:linear_client_module, :control_async_fixture], &{&1, Application.fetch_env(:symphony_elixir, &1)})
    Application.put_env(:symphony_elixir, :linear_client_module, Client)

    issue = %Issue{
      id: "control-#{System.unique_integer([:positive])}",
      identifier: "C6-1",
      title: "Controlled issue",
      state: "In Progress",
      source: :tracker,
      labels: ["policy:fully-autonomous"],
      assigned_to_worker: true
    }

    fixture = %{owner: self(), issue: issue, hold: [:identifier, :refresh], hold_writes: []}
    Application.put_env(:symphony_elixir, :control_async_fixture, fixture)

    config = [
      tracker_kind: "linear",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      workspace_root: Path.join(root, "workspaces"),
      manual_store_root: Path.join(root, "manual"),
      runner_install_root: Path.join(root, "runner"),
      company_author_profile_path: Path.join(root, "author.json"),
      company_credential_registry_path: Path.join(root, "credentials.json"),
      max_concurrent_agents: 0,
      codex_command: "/usr/bin/false",
      codex_runtime_profile_inherit_env: false
    ]

    write_workflow_file!(Workflow.workflow_file_path(), config)

    runtime = %State{
      lease_owner: "c6-owner-#{System.unique_integer([:positive])}",
      max_concurrent_agents: 0,
      poll_interval_ms: 60_000,
      healing_poll_interval_ms: 60_000,
      poll_check_in_progress: false,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:ok, owner} = Driver.start_link(runtime, self())

    on_exit(fn ->
      if Process.alive?(owner) do
        readers = GenServer.call(owner, :cleanup, 5_000)
        :ok = GenServer.stop(owner, :normal, 5_000)
        Enum.each(readers, fn reader -> await_dead!(reader.pid) end)
      end

      Enum.each(previous, fn
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, owner: owner, root: root, issue: issue, config: config, initial: runtime}
  end

  for action <- [:pause, :stop] do
    @tag control_action: action
    test "#{action} resolves a real tracker issue despite unreadable RAW without repairing it", c do
      workspace = Workspace.path_for_issue(c.issue)
      path = RunStateStore.state_path(workspace)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{")

      task =
        Task.async(fn ->
          case c.control_action do
            :pause -> Orchestrator.pause_issue(c.owner, c.issue.identifier)
            :stop -> Orchestrator.stop_issue(c.owner, c.issue.identifier)
          end
        end)

      assert_receive {:control_read, :identifier, reader, "C6-1"}, 1_000
      send(reader, {:answer, {:ok, c.issue}})
      assert %{ok: true} = Task.await(task, 1_000)
      assert_receive {:control_write, :state, _, _}, 1_000

      case c.control_action do
        :stop -> assert_receive {:control_write, :comment, _, _}, 1_000
        :pause -> refute_received {:control_write, :comment, _, _}
      end

      refute_received {:control_write, _, _, _}
      assert File.read!(path) == "{"
      assert runtime(c).running == %{}
      assert is_nil(runtime(c).control_reservation)
      assert {:error, :missing} = LeaseManager.read(c.issue.id)
      assert effect_count(c.issue.id, "dispatch.started") == 0
    end
  end

  test "unreadable RAW still rejects retry before any tracker lookup or effect", c do
    path = RunStateStore.state_path(Workspace.path_for_issue(c.issue))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{")

    assert %{ok: false, error: "control_read_failed", effect_status: "not_started"} = Orchestrator.retry_issue_now(c.owner, c.issue.identifier)
    assert runtime(c) == c.initial
    assert File.read!(path) == "{"
    refute_received {:control_read, _, _, _}
    refute_received {:control_write, _, _, _}
  end

  test "stop with unreadable RAW preserves a checked manual scan error without tracker fallback", c do
    path = RunStateStore.state_path(Workspace.path_for_issue(c.issue))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{")
    manual = Path.join([c.root, "manual", "broken.json"])
    File.mkdir_p!(Path.dirname(manual))
    File.write!(manual, "{")

    assert %{ok: false, error: "control_read_failed", effect_status: "not_started"} = Orchestrator.stop_issue(c.owner, c.issue.identifier)
    assert runtime(c) == c.initial
    assert File.read!(path) == "{"
    assert File.read!(manual) == "{"
    refute_received {:control_read, _, _, _}
    refute_received {:control_write, _, _, _}
  end

  test "mailbox time consumes the original deadline and performs no effect", c do
    assert :ok = :sys.suspend(c.owner)

    try do
      task = Task.async(fn -> Orchestrator.stop_issue(c.owner, c.issue.identifier) end)
      assert %{ok: false, error: "control_deadline_exceeded", effect_status: "unknown"} = Task.await(task, 6_000)
    after
      assert :ok = :sys.resume(c.owner)
    end

    assert GenServer.call(c.owner, :runtime, 500) == c.initial
    refute_received {:control_read, _, _, _}
    refute_received {:control_write, _, _, _}
  end

  test "owner expired request rejects not_started without a reader or invalidation", c do
    request = envelope(:stop, c.issue.identifier, System.monotonic_time(:millisecond) - 1)
    assert %{error: "control_deadline_exceeded", effect_status: "not_started"} = GenServer.call(c.owner, {:control, request})
    assert runtime(c) == c.initial
    refute_received {:control_read, _, _, _}
    refute_received {:control_write, _, _, _}
  end

  test "old control tuples cannot bypass the deadline envelope", c do
    assert %{ok: false, error: "control_envelope_required"} = GenServer.call(c.owner, {:stop_issue, c.issue.identifier})
    assert runtime(c) == c.initial
    refute_received {:control_read, _, _, _}
  end

  test "remote lookup leaves the owner responsive and a second remote call busy before effects", c do
    first = Task.async(fn -> Orchestrator.pause_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, "C6-1"}, 1_000
    state = GenServer.call(c.owner, :runtime, 500)
    assert state.admission_read.pid != reader
    assert %{error: "control_busy", effect_status: "not_started"} = Orchestrator.stop_issue(c.owner, "C6-2")
    refute_received {:control_write, _, _, _}
    send(reader, {:answer, {:ok, c.issue}})
    assert %{ok: true, action: "pause"} = Task.await(first, 1_000)
    assert_receive {:control_write, :state, _, _}, 1_000
    refute_receive {:control_write, :comment, _, _}, 50
    assert is_nil(runtime(c).control_reservation)
  end

  test "a local control invalidates a pending remote operation without replay", c do
    task = Task.async(fn -> Orchestrator.stop_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    guardian = runtime(c).admission_read.pid
    assert %{ok: true} = Orchestrator.reprioritize_issue(c.owner, c.issue.identifier, 0)
    assert %{ok: false, error: "control_invalidated", effect_status: "not_started"} = Task.await(task, 1_000)
    await_dead!(reader)
    await_dead!(guardian)
    refute_received {:control_write, _, _, _}
    assert runtime(c).priority_overrides[c.issue.identifier] == 0
  end

  test "caller death cancels its real reader before the slot is reused", c do
    observer = self()
    caller = spawn(fn -> send(observer, {:unused_control_result, Orchestrator.stop_issue(c.owner, c.issue.identifier)}) end)
    assert_receive {:control_read, :identifier, child, _}, 1_000
    guardian = runtime(c).admission_read.pid
    Process.exit(caller, :kill)
    await_dead!(caller)
    await_dead!(child)
    await_dead!(guardian)
    await_runtime!(c, &is_nil(&1.admission_read))
    assert is_nil(runtime(c).control_reservation)
    refute_received {:control_write, _, _, _}
    refute_received {:unused_control_result, _}
  end

  test "checked missing is a domain rejection while a reader exception is read_failed", c do
    missing = Task.async(fn -> Orchestrator.pause_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, first, _}, 1_000
    send(first, {:answer, {:ok, nil}})
    assert %{ok: false, error: ":issue_not_found"} = Task.await(missing, 1_000)
    failure = Task.async(fn -> Orchestrator.pause_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, second, _}, 1_000
    send(second, :raise)
    assert %{ok: false, error: "control_read_failed", effect_status: "not_started"} = Task.await(failure, 1_000)
    refute_received {:control_write, _, _, _}
  end

  for result <- [{:ok, :malformed}, {:error, {:tracker_reader_exit, :backend_tag}}, {:error, {:linear_rate_limited, :invalid_metadata}}] do
    test "malformed/backend result #{inspect(result)} cannot become absence or a write", c do
      task = Task.async(fn -> Orchestrator.stop_issue(c.owner, c.issue.identifier) end)
      assert_receive {:control_read, :identifier, reader, _}, 1_000
      send(reader, {:answer, unquote(Macro.escape(result))})
      assert %{ok: false, error: "control_read_failed", effect_status: "not_started"} = Task.await(task, 1_000)
      assert is_nil(runtime(c).tracker_backoff_until_ms)
      refute_received {:control_write, _, _, _}
    end
  end

  test "a genuine read 429 establishes backoff even though control cannot apply", c do
    task = Task.async(fn -> Orchestrator.pause_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:error, {:linear_rate_limited, %{retry_after_ms: 2_000}}}})
    assert %{ok: false, error: "control_read_failed", effect_status: "not_started"} = Task.await(task, 1_000)
    assert runtime(c).tracker_backoff_until_ms > System.monotonic_time(:millisecond)
    refute_received {:control_write, _, _, _}
  end

  test "context changed during lookup denies the old result", c do
    task = Task.async(fn -> Orchestrator.stop_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(c.config, :tracker_project_slug, "replacement"))
    send(reader, {:answer, {:ok, c.issue}})
    assert %{error: "control_invalidated", effect_status: "not_started"} = Task.await(task, 1_000)
    refute_received {:control_write, _, _, _}
  end

  test "manual scan corruption cannot fall through to tracker or seeded success", c do
    File.mkdir_p!(Path.join(c.root, "manual"))
    File.write!(Path.join([c.root, "manual", "broken.json"]), "{")
    assert %{ok: false, error: "control_read_failed", effect_status: "not_started"} = Orchestrator.stop_issue(c.owner, c.issue.identifier)
    assert runtime(c) == c.initial
    refute_received {:control_read, _, _, _}
    refute_received {:control_write, _, _, _}
  end

  test "stop records one comment and preserves the actual following writer failure", c do
    fixture!(hold_writes: [:state])
    task = Task.async(fn -> Orchestrator.stop_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, c.issue}})
    assert_receive {:control_write, :comment, _, _}, 1_000
    assert_receive {:control_write, :state, writer, _}, 1_000
    send(writer, {:writer_answer, {:error, :controlled_write_failure}})
    assert %{ok: false, error: ":controlled_write_failure"} = Task.await(task, 1_000)
    refute_receive {:control_write, :comment, _, _}, 50
    assert is_nil(runtime(c).control_reservation)
  end

  test "a context change while comment is executing prevents the following state writer", c do
    fixture!(hold_writes: [:comment])
    task = Task.async(fn -> Orchestrator.stop_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, c.issue}})
    assert_receive {:control_write, :comment, writer, _}, 1_000
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(c.config, :tracker_project_slug, "changed-after-comment"))
    send(writer, {:writer_answer, {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}})
    assert %{ok: false, error: "control_invalidated", effect_status: "unknown"} = Task.await(task, 1_000)
    refute_receive {:control_write, :state, _, _}, 50
    refute_receive {:control_write, :comment, _, _}, 50
    assert is_nil(runtime(c).control_reservation)
  end

  test "writer 429 establishes backoff after exactly one attempted mutation", c do
    fixture!(hold_writes: [:state])
    task = Task.async(fn -> Orchestrator.pause_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, c.issue}})
    assert_receive {:control_write, :state, writer, _}, 1_000
    send(writer, {:writer_answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 2_000}}}})
    assert %{ok: false} = Task.await(task, 1_000)
    assert runtime(c).tracker_backoff_until_ms > System.monotonic_time(:millisecond)
    refute_receive {:control_write, :state, _, _}, 50
  end

  test "approval writer is not repeated after a failed refresh", c do
    task = Task.async(fn -> Orchestrator.approve_issue_for_merge(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, c.issue}})
    assert_receive {:control_write, :state, _, _}, 1_000
    assert_receive {:control_read, :refresh, refresh, _}, 1_000
    send(refresh, {:answer, {:error, :refresh_failed}})
    assert %{ok: false, error: "control_read_failed", effect_status: "unknown"} = Task.await(task, 1_000)
    refute_receive {:control_write, :state, _, _}, 50
    assert runtime(c).running == %{}
    assert {:error, :missing} = RunStateStore.load(Workspace.path_for_issue(c.issue))
  end

  test "unreadable snapshot after a real refresh prevents approval", c do
    task = Task.async(fn -> Orchestrator.approve_issue_for_merge(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, c.issue}})
    assert_receive {:control_write, :state, _, _}, 1_000
    assert_receive {:control_read, :refresh, refresh, _}, 1_000
    workspace = Workspace.path_for_issue(c.issue)
    File.mkdir_p!(RunStateStore.state_path(workspace))
    send(refresh, {:answer, {:ok, %{c.issue | state: "Merging"}}})
    assert %{ok: false, error: "control_invalidated", effect_status: "unknown"} = Task.await(task, 1_000)
    assert File.dir?(RunStateStore.state_path(workspace))
    assert runtime(c).running == %{}
    refute_receive {:control_write, :state, _, _}, 50
  end

  test "material changed during refresh is retained and prevents approval update", c do
    workspace = Workspace.path_for_issue(c.issue)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, issue_source: :tracker})
    task = Task.async(fn -> Orchestrator.approve_issue_for_merge(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, c.issue}})
    assert_receive {:control_read, :refresh, refresh, _}, 1_000
    assert {:ok, _} = RunStateStore.transition(workspace, "blocked", %{stop_reason: %{code: "new_stop"}})
    snapshot = File.read!(RunStateStore.state_path(workspace))
    send(refresh, {:answer, {:ok, %{c.issue | state: "Merging"}}})
    assert %{error: "control_invalidated", effect_status: "unknown"} = Task.await(task, 1_000)
    assert File.read!(RunStateStore.state_path(workspace)) == snapshot
    assert runtime(c).running == %{}
  end

  test "duplicate physical-reader result never repeats a completed stop", c do
    task = Task.async(fn -> Orchestrator.stop_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, child, _}, 1_000
    reader = runtime(c).admission_read
    send(child, {:answer, {:ok, c.issue}})
    assert %{ok: true} = Task.await(task, 1_000)
    assert_receive {:control_write, :comment, _, _}, 1_000
    assert_receive {:control_write, :state, _, _}, 1_000
    send(c.owner, {:tracker_read_result, reader.ref, {:ok, {:issue, :tracker, c.issue}}})
    assert is_nil(runtime(c).control_reservation)
    refute_receive {:control_write, _, _, _}, 50
  end

  test "refresh timeout retains production approval and never dispatches", c do
    workspace = Workspace.path_for_issue(c.issue)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, issue_source: :tracker})
    task = Task.async(fn -> Orchestrator.approve_issue_for_deploy(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, c.issue}})
    assert_receive {:control_write, :state, _, _}, 1_000
    assert_receive {:control_read, :refresh, refresh, _}, 1_000
    snapshot = File.read!(RunStateStore.state_path(workspace))
    assert %{error: "control_deadline_exceeded", effect_status: "unknown"} = Task.await(task, 6_000)
    await_dead!(refresh)
    assert File.read!(RunStateStore.state_path(workspace)) == snapshot
    assert {:ok, %{stage: "deploy_production", deploy_approved: true}} = RunStateStore.load(workspace)
    assert runtime(c).running == %{}
    refute_receive {:control_write, :state, _, _}, 50
  end

  test "caller death during refresh cannot release another authentic custody", c do
    observer = self()
    caller = spawn(fn -> send(observer, {:unused_approval, Orchestrator.approve_issue_for_merge(c.owner, c.issue.identifier)}) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, c.issue}})
    assert_receive {:control_read, :refresh, child, _}, 1_000
    guardian = runtime(c).admission_read.pid
    lease_owner = runtime(c).lease_owner
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, lease_owner)

    claim = %{
      token: acquired.token,
      lease: acquired.lease,
      custody_ref: make_ref(),
      holder: :retry,
      workspace: Workspace.path_for_issue(c.issue),
      issue: c.issue,
      started_at_ms: System.monotonic_time(:millisecond),
      deadline: :not_pending,
      promotion_ref: nil,
      timer: nil
    }

    :sys.replace_state(c.owner, fn state -> %{state | runtime: %{state.runtime | lease_claims: %{c.issue.id => claim}, claimed: MapSet.new([c.issue.id])}} end)
    bytes = File.read!(acquired.token.storage.lease_path)
    Process.exit(caller, :kill)
    await_dead!(caller)
    await_dead!(child)
    await_dead!(guardian)
    await_runtime!(c, &is_nil(&1.control_reservation))
    assert runtime(c).lease_claims[c.issue.id] == claim
    assert File.read!(acquired.token.storage.lease_path) == bytes
    assert :ok = LeaseManager.ensure_current(acquired.token)
    refute_received {:unused_approval, _}
    refute_receive {:control_write, :comment, _, _}, 50
  end

  test "local manual resolution works while a remote reservation is occupied", c do
    {:ok, manual} = ManualIssueStore.submit(%{"id" => "manual-c6", "identifier" => "C6-MANUAL", "title" => "Manual", "description" => "local", "acceptance_criteria" => ["pause"]})
    remote = Task.async(fn -> Orchestrator.pause_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    reservation = runtime(c).control_reservation.operation.ref
    assert %{ok: true, state: "Paused"} = Orchestrator.pause_issue(c.owner, manual.identifier)
    assert runtime(c).control_reservation.operation.ref == reservation
    assert {:ok, %{state: "Paused"}} = ManualIssueStore.fetch_issue_by_id(manual.id)
    send(reader, {:answer, {:ok, c.issue}})
    assert %{ok: true} = Task.await(remote, 1_000)
  end

  for snapshot_mode <- [:missing, :mismatch] do
    test "healthy #{snapshot_mode} retry explicitly selects Todo before its single refresh", c do
      workspace = Workspace.path_for_issue(c.issue)

      if unquote(snapshot_mode) == :mismatch do
        assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: "old-run", issue_identifier: "OLD-RUN", issue_source: :tracker})
      end

      issue = %{c.issue | state: "Blocked"}
      task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, issue.identifier) end)
      assert_receive {:control_read, :identifier, reader, _}, 1_000
      send(reader, {:answer, {:ok, issue}})
      assert_receive {:control_write, :state, _, variables}, 1_000
      assert variables.stateId == "state-Todo"
      assert_receive {:control_read, :refresh, refresh, id}, 1_000
      assert id == issue.id
      send(refresh, {:answer, {:ok, %{issue | state: "Todo"}}})
      assert %{ok: true, dispatch_outcome: "deferred"} = Task.await(task, 1_000)
      refute_receive {:control_write, :state, _, _}, 50
      refute_receive {:control_read, :refresh, _, _}, 50
      assert runtime(c).running == %{}
    end
  end

  test "failed retry writer never refreshes or falls back to another Todo write", c do
    fixture!(hold_writes: [:state])
    issue = %{c.issue | state: "Blocked"}
    task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, issue.identifier) end)
    assert_receive {:control_read, :identifier, reader, _}, 1_000
    send(reader, {:answer, {:ok, issue}})
    assert_receive {:control_write, :state, writer, _}, 1_000
    send(writer, {:writer_answer, {:error, :retry_writer_failed}})
    assert %{ok: false, error: ":retry_writer_failed"} = Task.await(task, 1_000)
    refute_receive {:control_write, :state, _, _}, 50
    refute_receive {:control_read, :refresh, _, _}, 50
    assert runtime(c).running == %{}
  end

  for manual_record <- [:absent, :corrupt] do
    test "seeded manual retry requires checked absence, record #{manual_record}", c do
      id = "manual:seeded-c6"
      identifier = "C6-SEEDED"
      workspace = Workspace.path_for_issue(identifier)
      assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: id, issue_identifier: identifier, issue_source: :manual, effective_policy_class: "fully_autonomous"})
      assert {:ok, _} = RunStateStore.transition(workspace, "blocked", %{})
      snapshot = File.read!(RunStateStore.state_path(workspace))

      if unquote(manual_record) == :corrupt do
        File.mkdir_p!(Path.join(c.root, "manual"))
        File.write!(Path.join([c.root, "manual", Base.url_encode64(id, padding: false) <> ".json"]), "{")
      end

      result = Orchestrator.retry_issue_now(c.owner, identifier)

      if unquote(manual_record) == :absent do
        assert %{ok: true, dispatch_outcome: "deferred"} = result
        assert {:ok, %{stage: "implement", stop_reason: nil}} = RunStateStore.load(workspace)
        assert {:ok, nil} = ManualIssueStore.fetch_issue_by_id_checked(id, Path.join(c.root, "manual"))
      else
        assert %{ok: false, error: "control_read_failed", effect_status: "not_started"} = result
        assert File.read!(RunStateStore.state_path(workspace)) == snapshot
        assert runtime(c) == c.initial
      end

      refute_received {:control_read, _, _, _}
      refute_received {:control_write, _, _, _}
      assert runtime(c).running == %{}
    end
  end

  test "a real gated worker cannot be reported dispatched before authorization", c do
    {issue, workspace} = prepare_manual_dispatch!(c)
    task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, issue.identifier) end)
    assert_receive {:held_gate, owner, {:authorize_dispatch, id, _dispatch, worker}}, 2_000
    assert owner == c.owner and id == issue.id
    assert Process.alive?(worker)
    assert Task.yield(task, 0) == nil
    entry = runtime(c).running[id]
    refute Map.get(entry, :execution_started?, false)
    assert is_map(entry.control_guard)
    assert :ok = GenServer.call(c.owner, :deliver_gate)
    assert %{ok: true, dispatch_outcome: "dispatched"} = Task.await(task, 1_000)
    assert {:ok, raw} = RunStateStore.load(workspace)
    assert raw.issue_id == id
  end

  test "caller deadline at the held gate terminates the real child without authorization", c do
    {issue, workspace} = prepare_manual_dispatch!(c)
    task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, issue.identifier) end)
    assert_receive {:held_gate, _owner, {:authorize_dispatch, id, _dispatch, worker}}, 2_000
    assert %{error: "control_deadline_exceeded", effect_status: "unknown"} = Task.await(task, 6_000)
    await_dead!(worker)
    assert :ok = GenServer.call(c.owner, :deliver_gate)
    assert runtime(c).running == %{}
    assert {:error, :missing} = LeaseManager.read(id)
    assert :ok = DispatchAudit.ensure_available(workspace)
    assert Enum.count(RunLedger.recent_entries(100), &(&1["event_type"] == "dispatch.finished" and &1["issue_id"] == id)) == 1
  end

  test "a local invalidation removes gate permission without forgetting the gate guard", c do
    {issue, _workspace} = prepare_manual_dispatch!(c)
    task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, issue.identifier) end)
    assert_receive {:held_gate, _owner, {:authorize_dispatch, id, _dispatch, worker}}, 2_000
    assert %{ok: true} = Orchestrator.reprioritize_issue(c.owner, issue.identifier, 0)
    assert %{error: "control_invalidated", effect_status: "unknown"} = Task.await(task, 1_000)
    entry = runtime(c).running[id]
    assert is_nil(entry.control)
    assert is_map(entry.control_guard)
    refute Map.get(entry, :execution_started?, false)
    assert :ok = GenServer.call(c.owner, :deliver_gate)
    await_dead!(worker)
    assert runtime(c).running == %{}
  end

  test "control A and discovery B use exactly their existing physical slots", c do
    fixture!(hold: [:identifier, :refresh, :candidates])
    send(c.owner, :run_poll_cycle)
    assert_receive {:control_read, :candidates, background_child, []}, 1_000
    background = runtime(c).tracker_poll_read
    task = Task.async(fn -> Orchestrator.pause_issue(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, control_child, _}, 1_000
    admission = runtime(c).admission_read
    assert admission.pid != background.pid
    assert Enum.all?([background_child, control_child, background.pid, admission.pid], &Process.alive?/1)
    assert %{error: "control_busy", effect_status: "not_started"} = Orchestrator.pause_issue(c.owner, "C6-OTHER")
    refute_receive {:control_read, :identifier, _, "C6-OTHER"}, 50
    assert GenServer.call(c.owner, :runtime, 500).tracker_poll_read.ref == background.ref
    send(control_child, {:answer, {:ok, c.issue}})
    assert %{ok: true} = Task.await(task, 1_000)
    assert Process.alive?(background.pid)
    send(background_child, {:answer, {:ok, []}})
    await_dead!(background.pid)
  end

  test "a ready control gets the next free A turn after an authentic poll admission", c do
    control_issue = %{c.issue | id: "#{c.issue.id}-control", identifier: "C6-OTHER"}
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(c.config, :max_concurrent_agents, 1))
    fixture!(hold: [:identifier, :refresh, :candidates, :promotion])
    send(c.owner, :run_poll_cycle)
    assert_receive {:control_read, :candidates, background, []}, 1_000
    send(background, {:answer, {:ok, [c.issue]}})
    assert_receive {:control_read, :promotion, admission_child, ids}, 1_000
    assert ids == [c.issue.id]
    first = runtime(c).admission_read
    task = Task.async(fn -> Orchestrator.pause_issue(c.owner, control_issue.identifier) end)
    await_runtime!(c, &match?(%{read_ready: true}, &1.control_reservation))
    assert runtime(c).admission_read.ref == first.ref
    refute_receive {:control_read, :identifier, _, _}, 50
    send(admission_child, {:answer, {:ok, []}})
    assert_receive {:control_read, :identifier, control_child, _}, 1_000
    assert runtime(c).admission_read.purpose == :control
    assert runtime(c).next_admission_kind == :poll
    send(control_child, {:answer, {:ok, control_issue}})
    assert %{ok: true} = Task.await(task, 1_000)
    assert runtime(c).running == %{}
  end

  test "approval snapshot write failure remains an error after the checkpoint was readable", c do
    workspace = Workspace.path_for_issue(c.issue)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, issue_source: :tracker})
    original = File.read!(RunStateStore.state_path(workspace))
    task = Task.async(fn -> Orchestrator.approve_issue_for_merge(c.owner, c.issue.identifier) end)
    assert_receive {:control_read, :identifier, child, _}, 1_000
    send(child, {:answer, {:ok, c.issue}})
    assert_receive {:control_read, :refresh, refresh, _}, 1_000
    directory = Path.dirname(RunStateStore.state_path(workspace))
    assert :ok = File.chmod(directory, 0o555)

    result =
      try do
        send(refresh, {:answer, {:ok, %{c.issue | state: "Merging"}}})
        Task.await(task, 1_000)
      after
        assert :ok = File.chmod(directory, 0o755)
      end

    assert %{ok: false, error: ":eacces"} = result
    assert File.read!(RunStateStore.state_path(workspace)) == original
    assert runtime(c).running == %{}
  end

  for close_failure <- [false, true] do
    test "authentic no-child rejection closes or retains its own ticket, failure #{close_failure}", c do
      {issue, workspace} = prepare_manual_dispatch!(c)
      extra = Path.join(DispatchAudit.marker_directory(workspace), "unexpected-c6-close")
      handler = "c6-no-child-#{System.unique_integer([:positive])}"
      observer = self()
      owner = c.owner

      :ok =
        :telemetry.attach(
          handler,
          [:symphony, :ledger, :event],
          fn _event, _measurements, metadata, _config ->
            if self() == owner and metadata[:event_type] == "dispatch.started" and metadata[:issue_id] == issue.id do
              if unquote(close_failure), do: File.write!(extra, "preserve close failure")
              send(observer, :control_begin_confirmed)
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      original = Process.whereis(SymphonyElixir.TaskSupervisor)
      supervisor = Process.whereis(SymphonyElixir.Supervisor)
      child_id = Task.Supervisor.child_spec(name: SymphonyElixir.TaskSupervisor).id
      assert is_pid(original) and is_pid(supervisor)
      assert Task.Supervisor.children(original) == []
      assert :ok = Supervisor.terminate_child(supervisor, child_id)

      try do
        {:ok, constrained} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor, max_children: 0)

        try do
          result = Orchestrator.retry_issue_now(c.owner, issue.identifier)
          assert_receive :control_begin_confirmed, 1_000
          assert Task.Supervisor.children(constrained) == []
          assert runtime(c).running == %{}
          refute_receive {:held_gate, _, _}, 50

          if unquote(close_failure) do
            assert %{ok: false, error: "control_invalidated", effect_status: "unknown"} = result
            claim = runtime(c).lease_claims[issue.id]
            hold = claim.control_close
            assert hold.issue_id == issue.id
            refute Map.has_key?(hold.ticket, :issue_id)
            assert hold.ticket.workspace == workspace
            assert hold.token == claim.token
            assert hold.custody_ref == claim.custody_ref
            assert is_reference(hold.control_ref)
            assert hold.cause == {:dispatch_worker_start_failed, :max_children}
            assert hold.error == :dispatch_audit_unexpected_files
            assert is_integer(hold.deadline)
            assert :ok = LeaseManager.ensure_current(claim.token)
            marker_path = Path.join(DispatchAudit.marker_directory(workspace), "marker.json")
            marker = File.read!(marker_path)
            assert Jason.decode!(marker)["status"] == "authorized"

            for _ <- 1..2 do
              assert %{ok: true} = Orchestrator.pause_issue(c.owner, issue.identifier)
              assert %{ok: true} = Orchestrator.stop_issue(c.owner, issue.identifier)
              assert runtime(c).lease_claims[issue.id] == claim
              assert File.read!(marker_path) == marker
              assert :ok = LeaseManager.ensure_current(claim.token)
            end

            send(c.owner, {:control_timeout, hold.control_ref})
            assert runtime(c).lease_claims[issue.id] == claim
            assert File.read!(extra) == "preserve close failure"
            assert effect_count(issue.id, "dispatch.finished") == 0
          else
            assert %{ok: false, error: error} = result
            assert error =~ "dispatch_worker_start_failed" and error =~ "max_children"
            assert runtime(c).lease_claims == %{}
            assert :ok = DispatchAudit.ensure_available(workspace)
            assert effect_count(issue.id, "dispatch.finished") == 1
          end
        after
          assert Task.Supervisor.children(constrained) == []
          assert :ok = Supervisor.stop(constrained)
        end
      after
        case Supervisor.restart_child(supervisor, child_id) do
          {:ok, restored} -> assert Process.whereis(SymphonyElixir.TaskSupervisor) == restored
          {:ok, restored, _info} -> assert Process.whereis(SymphonyElixir.TaskSupervisor) == restored
        end
      end
    end
  end

  test "control admission keeps its own new run binding without adopting new material", c do
    {issue, workspace} = prepare_manual_dispatch!(c)
    before = Jason.decode!(File.read!(RunStateStore.state_path(workspace)))
    refute Map.has_key?(before, "run_id")
    task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, issue.identifier) end)
    assert_receive {:held_gate, _owner, {:authorize_dispatch, id, dispatch_id, worker}}, 2_000
    assert id == issue.id and Process.alive?(worker)
    entry = runtime(c).running[id]
    raw = Jason.decode!(File.read!(RunStateStore.state_path(workspace)))
    assert is_binary(raw["run_id"]) and raw["run_id"] != ""
    assert entry.dispatch_ticket.run_id == raw["run_id"]
    assert entry.dispatch_ticket.dispatch_id == dispatch_id
    assert entry.control_guard.admission.ticket == entry.dispatch_ticket
    assert entry.control_guard.admission.expected == RunStateStore.coordinator_projection(raw)
    assert entry.control_guard.admission.identity == Map.take(raw, ~w(issue_id issue_identifier run_id run_identity_event_id run_identity_ledger_path))
    assert :ok = GenServer.call(c.owner, :deliver_gate)
    assert %{ok: true, dispatch_outcome: "dispatched"} = Task.await(task, 1_000)
  end

  test "current material changed inside begin closes the genuine ticket before any child", c do
    {issue, workspace} = prepare_manual_dispatch!(c)
    handler = "c6-current-begin-#{System.unique_integer([:positive])}"
    owner = c.owner
    observer = self()
    path = RunStateStore.state_path(workspace)

    :ok =
      :telemetry.attach(
        handler,
        [:symphony, :ledger, :event],
        fn _event, _measurements, metadata, _config ->
          if self() == owner and metadata[:event_type] == "dispatch.started" and metadata[:issue_id] == issue.id do
            raw = Jason.decode!(File.read!(path))
            File.write!(path, Jason.encode!(Map.put(raw, "next_human_action", "concurrent operator decision during begin")))
            send(observer, :current_control_material_changed)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert %{ok: false, error: ":control_admission_material_changed"} = Orchestrator.retry_issue_now(c.owner, issue.identifier)
    assert_receive :current_control_material_changed, 1_000
    refute_receive {:held_gate, _, _}, 50
    assert runtime(c).running == %{}
    assert runtime(c).lease_claims == %{}
    assert :ok = DispatchAudit.ensure_available(workspace)
    assert {:error, :missing} = LeaseManager.read(issue.id)
    assert effect_count(issue.id, "dispatch.started") == 1
    assert effect_count(issue.id, "dispatch.finished") == 1
    finished = Enum.find(RunLedger.recent_entries(100), &(&1["event_type"] == "dispatch.finished" and &1["issue_id"] == issue.id))
    assert finished["metadata"]["outcome"] == ":not_started"
    assert Jason.decode!(File.read!(path))["next_human_action"] == "concurrent operator decision during begin"
  end

  test "held real gate rejects coordinator material drift outside worker projection", c do
    {issue, workspace} = prepare_manual_dispatch!(c)
    task = Task.async(fn -> Orchestrator.retry_issue_now(c.owner, issue.identifier) end)
    assert_receive {:held_gate, _owner, {:authorize_dispatch, id, _dispatch, worker}}, 2_000
    before = runtime(c).running[id]
    assert {:ok, changed} = RunStateStore.update(workspace, &Map.put(&1, :next_human_action, "operator changed the pending decision"))
    assert RunStateStore.material_projection(changed) == before.agent_execution.expected
    refute RunStateStore.coordinator_projection(changed) == before.control_guard.admission.expected
    refute Map.get(before, :execution_started?, false)
    assert :ok = GenServer.call(c.owner, :deliver_gate)
    assert %{ok: false, error: ":control_admission_material_changed"} = Task.await(task, 1_000)
    await_dead!(worker)
    assert runtime(c).running == %{}
    assert {:error, :missing} = LeaseManager.read(issue.id)
    assert :ok = DispatchAudit.ensure_available(workspace)
    assert effect_count(issue.id, "dispatch.finished") == 1
    assert {:ok, %{next_human_action: "operator changed the pending decision"}} = RunStateStore.load(workspace)
  end

  defp prepare_manual_dispatch!(c) do
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(c.config, :max_concurrent_agents, 1))
    :sys.replace_state(c.owner, fn state -> %{state | runtime: %{state.runtime | max_concurrent_agents: 1}} end)
    {:ok, issue} = ManualIssueStore.submit(%{"id" => "gate-c6", "identifier" => "C6-GATE", "title" => "Gate", "description" => "controlled gate", "acceptance_criteria" => ["authorize once"]})
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: workspace)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier, issue_source: :manual, effective_policy_class: "fully_autonomous"})
    {issue, workspace}
  end

  defp effect_count(id, event), do: Enum.count(RunLedger.recent_entries(100), &(&1["event_type"] == event and &1["issue_id"] == id))

  defp fixture!(attrs), do: Application.put_env(:symphony_elixir, :control_async_fixture, Map.merge(Application.fetch_env!(:symphony_elixir, :control_async_fixture), Map.new(attrs)))
  defp runtime(c), do: GenServer.call(c.owner, :runtime, 500)
  defp envelope(action, identifier, deadline), do: %{ref: make_ref(), action: action, identifier: identifier, args: [], deadline: deadline}

  defp await_runtime!(c, predicate, remaining \\ 100)

  defp await_runtime!(c, predicate, remaining) when remaining > 0 do
    if predicate.(runtime(c)),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await_runtime!(c, predicate, remaining - 1)
        )
  end

  defp await_runtime!(_c, _predicate, 0), do: flunk("owner state did not settle")

  defp await_dead!(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    refute Process.alive?(pid)
  end

  defp pause_default_scheduler! do
    if pid = Process.whereis(Orchestrator) do
      deadline = System.monotonic_time(:millisecond) + 2_000
      wait_default_idle!(pid, deadline)
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
      assert System.monotonic_time(:millisecond) < deadline, "default scheduler must be idle before control fixture"
      Process.sleep(5)
      wait_default_idle!(pid, deadline)
    end
  end
end
