defmodule SymphonyElixir.OrchestratorTrackerPollAsyncTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias SymphonyElixir.{Config, LeaseManager, ManualIssueStore, Orchestrator, RunLedger, RunnerRuntime, RunStateStore, Workflow, WorkflowStore, Workspace}
  alias SymphonyElixir.Linear.Issue

  defmodule HeldClient do
    def fetch_candidate_issues, do: read(:candidates, [])
    def fetch_issues_by_states(["Done"] = states), do: read(:startup, states)
    def fetch_issues_by_states(states), do: read(:approval, states)
    def fetch_issue_states_by_ids(ids), do: read(:running, ids)

    defp read(phase, args) do
      fixture = Application.fetch_env!(:symphony_elixir, :tracker_poll_fixture)
      send(fixture.owner, {:tracker_called, phase, self(), args})

      if phase == fixture.hold do
        receive do
          {:answer, result} -> result
        after
          5_000 -> {:error, {:fixture_barrier_timeout, phase}}
        end
      else
        {:ok, []}
      end
    end
  end

  setup do
    pause_idle_scheduler!()
    root = Path.join(System.tmp_dir!(), "symphony-tracker-poll-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    root = File.cd!(root, &File.cwd!/0)
    previous = Enum.map([:workflow_file_path, :log_file, :linear_client_module, :tracker_poll_fixture], &{&1, Application.fetch_env(:symphony_elixir, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
      end)

      if Process.whereis(WorkflowStore), do: :ok = WorkflowStore.force_reload()
      File.rm_rf!(root)
    end)

    if is_nil(Process.whereis(SymphonyElixir.TaskSupervisor)), do: start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
    if is_nil(Process.whereis(WorkflowStore)), do: start_supervised!(WorkflowStore)
    Application.put_env(:symphony_elixir, :linear_client_module, HeldClient)
    Application.put_env(:symphony_elixir, :tracker_poll_fixture, %{owner: self(), hold: :none})
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "logs/symphony.log"))
    workflow = Path.join(root, "WORKFLOW.md")

    config = %{
      tracker: %{kind: "linear", api_key: "synthetic-local-token", project_slug: "local-poll", required_labels: [], active_states: ["Todo", "In Progress", "Merging"], terminal_states: ["Done"]},
      polling: %{interval_ms: 60_000, discovery_interval_ms: 60_000, healing_interval_ms: 60_000},
      workspace: %{root: Path.join(root, "workspaces")},
      runner: %{install_root: Path.join(root, "runner"), self_host_project: false},
      manual: %{enabled: true, store_root: Path.join(root, "manual")},
      company: %{policy_pack: "private_autopilot", author_profile_path: Path.join(root, "author.json"), credential_registry_path: Path.join(root, "credentials.json")},
      agent: %{max_concurrent_agents: 0, stall_timeout_ms: 0, codex: %{command: "/usr/bin/false", runtime_profile: %{inherit_env: false}}},
      policy: %{publish_required: false, automerge_on_green: false}
    }

    write_config!(workflow, config)
    assert :ok = Config.validate!()
    {:ok, root: root, workflow: workflow, config: config}
  end

  test "startup cleanup can be held while the owner serves snapshots" do
    hold(:startup)
    pid = scheduler!()
    assert_receive {:tracker_called, :startup, reader, ["Done"]}, 2_000
    assert is_map(Orchestrator.snapshot(pid, 500))
    state = :sys.get_state(pid)
    assert state.tracker_poll_cycle.mode == :startup_cleanup
    assert state.running == %{}
    send(reader, {:answer, {:ok, []}})
    idle!(pid)
  end

  test "stop completes before a held candidate read and the old issue cannot reappear" do
    issue = manual_issue!("STOP-1")
    hold(:candidates)
    pid = scheduler!()
    assert_receive {:tracker_called, :candidates, reader, []}, 2_000
    assert is_map(Orchestrator.snapshot(pid, 500))
    assert %{ok: true} = Orchestrator.stop_issue(pid, issue.identifier)
    assert {:ok, [%Issue{state: "Blocked"}]} = ManualIssueStore.fetch_issue_states_by_ids([issue.id])
    assert Process.alive?(reader)
    send(reader, {:answer, {:ok, [issue]}})
    state = idle!(pid)
    refute Enum.any?(state.last_candidate_issues, &(&1.id == issue.id))
    assert state.running == %{}
    assert state.retry_attempts == %{}
    assert MapSet.size(state.claimed) == 0
  end

  test "a valid configuration change discards the held result", ctx do
    hold(:candidates)
    pid = scheduler!()
    assert_receive {:tracker_called, :candidates, reader, []}, 2_000
    write_config!(ctx.workflow, put_in(ctx.config, [:tracker, :project_slug], "replacement-project"))
    send(reader, {:answer, {:ok, [remote_issue()]}})
    state = wait_state!(pid, fn state -> idle?(state) and state.candidate_fetch_error == :tracker_read_context_changed end)
    assert state.candidate_fetch_error == :tracker_read_context_changed
    assert state.last_candidate_issues == []
    assert state.running == %{}
  end

  test "policy pack is retained from the same read context capture", ctx do
    context = Config.tracker_read_context()
    assert context.policy_pack_name == "private_autopilot"
    write_config!(ctx.workflow, put_in(ctx.config, [:company, :policy_pack], "client_safe_shadow"))
    assert context.policy_pack_name == "private_autopilot"
    refute Config.tracker_read_context().fingerprint == context.fingerprint
  end

  test "zero capacity still records a successful candidate read without a worker" do
    hold(:candidates)
    pid = scheduler!()
    assert_receive {:tracker_called, :candidates, reader, []}, 2_000
    issue = remote_issue()
    assert %{ok: true} = Orchestrator.reprioritize_issue(pid, issue.identifier, 7)
    send(reader, {:answer, {:ok, [issue]}})
    state = idle!(pid)
    assert state.priority_overrides[issue.identifier] == 7
    assert Enum.map(state.last_candidate_issues, & &1.id) == [issue.id]
    assert state.max_concurrent_agents == 0
    assert state.running == %{}
    assert MapSet.size(state.claimed) == 0
    wait_state!(pid, fn state -> idle?(state) and Task.Supervisor.children(SymphonyElixir.TaskSupervisor) == [] end)
  end

  test "remote throttling remains visible when manual candidates succeed" do
    manual = manual_issue!("MANUAL-1")
    hold(:candidates)
    pid = scheduler!()
    assert_receive {:tracker_called, :candidates, reader, []}, 2_000
    send(reader, {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 60_000}}}})
    first = idle!(pid)
    assert Enum.any?(first.last_candidate_issues, &(&1.id == manual.id))
    assert first.tracker_backoff_until_ms > System.monotonic_time(:millisecond)
    assert first.candidate_fetch_error == {:tracker_backoff, "tracker.rate_limited"}
    send(pid, :run_poll_cycle)
    second = idle!(pid)
    assert second.tracker_backoff_until_ms == first.tracker_backoff_until_ms
    assert second.candidate_fetch_error == {:tracker_backoff, "tracker.rate_limited"}
    assert Enum.any?(second.last_candidate_issues, &(&1.id == manual.id))
    refute_receive {:tracker_called, :candidates, _, _}, 50
  end

  test "an error refreshing running issues keeps the current worker" do
    pid = scheduler!()
    idle!(pid)
    {issue, worker} = install_running!(pid)
    hold(:running)
    send(pid, :run_poll_cycle)
    assert_receive {:tracker_called, :running, reader, [id]}, 2_000
    assert id == issue.id
    send(reader, {:answer, {:error, :synthetic_read_failure}})
    state = idle!(pid)
    assert state.running[issue.id].pid == worker
    assert Process.alive?(worker)
    assert state.candidate_fetch_error == :synthetic_read_failure
  end

  test "terminal data from the old worker cannot terminate its replacement" do
    pid = scheduler!()
    idle!(pid)
    {issue, old_worker} = install_running!(pid)
    hold(:running)
    send(pid, :run_poll_cycle)
    assert_receive {:tracker_called, :running, reader, [id]}, 2_000
    assert id == issue.id
    replacement = held_worker!()

    :sys.replace_state(pid, fn state ->
      entry = Map.fetch!(state.running, id)
      Process.demonitor(entry.ref, [:flush])
      %{state | running: Map.put(state.running, id, %{entry | pid: replacement, ref: Process.monitor(replacement)})}
    end)

    send(reader, {:answer, {:ok, [%{issue | state: "Done"}]}})
    state = idle!(pid)
    assert state.running[id].pid == replacement
    assert state.running[id].issue.state == "In Progress"
    assert Process.alive?(replacement)
    assert Process.alive?(old_worker)
  end

  test "refreshes during a held read preserve both inbox drain requests" do
    hold(:candidates)
    pid = scheduler!()
    assert_receive {:tracker_called, :candidates, reader, []}, 2_000
    assert %{queued: true} = Orchestrator.request_refresh(pid)
    assert %{queued: true} = Orchestrator.request_refresh(pid)
    state = :sys.get_state(pid)
    assert Enum.count(state.tracker_poll_pending, &(&1 == :webhook)) == 1
    # GitHub may still be represented by its already scheduled cycle message.
    assert state.github_webhook_check_in_progress
    send(reader, {:answer, {:ok, []}})
    state = wait_state!(pid, fn state -> idle?(state) and match?(%DateTime{}, state.inbox_last_drained_at) and match?(%DateTime{}, state.github_inbox_last_drained_at) end)
    assert state.tracker_poll_pending == []
  end

  test "a manual submission during a held webhook read triggers discovery immediately" do
    pid = scheduler!()
    initial = idle!(pid)
    assert initial.poll_interval_ms == 60_000
    assert_receive {:tracker_called, :approval, _initial_approval, _states}, 2_000
    assert_receive {:tracker_called, :candidates, _initial_candidates, []}, 2_000

    hold(:approval)
    send(pid, :run_webhook_cycle)
    assert_receive {:tracker_called, :approval, reader, _states}, 2_000
    assert :sys.get_state(pid).tracker_poll_cycle.mode == :webhook

    spec = %{
      "id" => "MANUAL-DURING-WEBHOOK",
      "identifier" => "MANUAL-DURING-WEBHOOK",
      "title" => "Accepted during a held webhook read",
      "acceptance_criteria" => ["Discover immediately after the current cycle"],
      "labels" => []
    }

    assert %{ok: true, accepted: true, issue_id: issue_id} = Orchestrator.submit_manual_issue(pid, spec)
    assert Process.alive?(reader)
    hold(:none)
    send(reader, {:answer, {:ok, []}})

    assert_receive {:tracker_called, :candidates, _refresh_candidates, []}, 2_000
    state = wait_state!(pid, fn state -> idle?(state) and Enum.any?(state.last_candidate_issues, &(&1.id == issue_id)) end)
    assert match?(%DateTime{}, state.inbox_last_drained_at)
    assert state.running == %{}
    assert MapSet.size(state.claimed) == 0
  end

  test "a successful remote result cannot bypass a newer backoff decision", ctx do
    write_config!(ctx.workflow, put_in(ctx.config, [:agent, :max_concurrent_agents], 1))
    hold(:candidates)
    pid = scheduler!()
    assert_receive {:tracker_called, :candidates, reader, []}, 2_000
    until_ms = System.monotonic_time(:millisecond) + 60_000

    :sys.replace_state(pid, fn state ->
      %{state | tracker_backoff_until_ms: until_ms, tracker_backoff_reason: "new throttle", tracker_backoff_rule_id: "tracker.rate_limited"}
    end)

    send(reader, {:answer, {:ok, [remote_issue()]}})
    state = idle!(pid)
    assert state.max_concurrent_agents == 1
    assert state.last_candidate_issues == []
    assert state.running == %{}
    assert MapSet.size(state.claimed) == 0
    assert state.tracker_backoff_until_ms == until_ms
    assert state.tracker_backoff_reason == "new throttle"
    assert state.candidate_fetch_error == {:tracker_backoff, "tracker.rate_limited"}
    # The legacy admission path revalidates via this exact callback before spawn.
    refute_receive {:tracker_called, :running, _, _}, 50
    refute File.exists?(Workspace.path_for_issue(remote_issue()))
  end

  test "a workspace leased while startup cleanup waits is preserved" do
    hold(:startup)
    pid = scheduler!()
    assert_receive {:tracker_called, :startup, reader, ["Done"]}, 2_000
    issue = %{remote_issue() | state: "Done"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    sentinel = Path.join(workspace, "preserved.txt")
    File.write!(sentinel, "new private workspace")
    assert :ok = LeaseManager.acquire(issue.id, issue.identifier, "other-current-owner")
    assert {:ok, lease} = LeaseManager.read(issue.id)
    send(reader, {:answer, {:ok, [issue]}})
    idle!(pid)
    assert File.read!(sentinel) == "new private workspace"
    assert {:ok, ^lease} = LeaseManager.read(issue.id)
  end

  test "reader DOWN is diagnostic and never interpreted as a terminal worker state" do
    pid = scheduler!()
    idle!(pid)
    {issue, worker} = install_running!(pid)
    hold(:running)
    send(pid, :run_poll_cycle)
    assert_receive {:tracker_called, :running, child, [id]}, 2_000
    assert id == issue.id
    operation = :sys.get_state(pid).tracker_poll_read
    child_monitor = Process.monitor(child)
    true = Process.exit(operation.pid, :kill)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :killed}, 2_000
    state = idle!(pid)
    assert state.running[issue.id].pid == worker
    assert Process.alive?(worker)
    assert state.candidate_fetch_error == {:tracker_read_failed, {:tracker_reader_down, :killed}}
  end

  test "invalid configuration keeps its audit event and immediate diagnostic", ctx do
    pid = scheduler!()
    state = idle!(pid)
    write_config!(ctx.workflow, put_in(ctx.config, [:tracker, :handoff_mode], "not-a-mode"))

    log =
      capture_log(fn ->
        assert {:noreply, rejected} = Orchestrator.handle_info(:run_poll_cycle, state)
        assert rejected.candidate_fetch_error == {:invalid_tracker_handoff_mode, "not-a-mode"}
        assert rejected.tracker_poll_read == nil
      end)

    assert log =~ "Dispatch blocked by config validation"
    events = ledger_events!()
    assert Enum.any?(events, fn row -> row["event_type"] == "config_invalid" and row["actor_id"] == state.lease_owner and row["metadata"]["dispatch_mode"] == "discovery" end)
  end

  test "GitHub drain retains runner health even with no remote tracker request", ctx do
    pid = scheduler!()
    idle!(pid)
    File.mkdir_p!(ctx.config.runner.install_root)
    File.write!(RunnerRuntime.metadata_path(ctx.config.runner.install_root), "{invalid")
    write_config!(ctx.workflow, put_in(ctx.config, [:tracker, :required_labels], ["dogfood:symphony"]))
    assert RunnerRuntime.info().dispatch_enabled == false
    send(pid, :run_github_webhook_cycle)
    state = wait_state!(pid, fn state -> idle?(state) and match?(%DateTime{}, state.github_inbox_last_drained_at) end)
    assert state.candidate_fetch_error == {:runner_health, "runner.metadata_invalid"}
    assert state.running == %{}
  end

  defp scheduler! do
    name = Module.concat(__MODULE__, "Scheduler#{System.unique_integer([:positive])}")
    start_supervised!({Orchestrator, name: name})
  end

  defp hold(phase), do: Application.put_env(:symphony_elixir, :tracker_poll_fixture, %{owner: self(), hold: phase})

  defp remote_issue do
    %Issue{id: "remote-1", identifier: "REMOTE-1", source: :tracker, title: "Controlled candidate", description: "Local fixture", state: "Todo", labels: [], assigned_to_worker: true}
  end

  defp manual_issue!(identifier) do
    {:ok, issue} = ManualIssueStore.submit(%{"id" => identifier, "identifier" => identifier, "title" => "Controlled manual issue", "acceptance_criteria" => ["Remain observable"], "labels" => []})
    issue
  end

  defp install_running!(pid) do
    issue = %{remote_issue() | state: "In Progress"}
    worker = held_worker!()
    owner = :sys.get_state(pid).lease_owner
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    assert :ok = RunStateStore.save(workspace, RunStateStore.load_or_default(workspace, issue))
    assert :ok = LeaseManager.acquire(issue.id, issue.identifier, owner)
    assert {:ok, lease} = LeaseManager.read(issue.id)

    :sys.replace_state(pid, fn state ->
      entry = %{
        pid: worker,
        ref: Process.monitor(worker),
        identifier: issue.identifier,
        issue: issue,
        lease_owner: owner,
        lease_epoch: lease["epoch"],
        started_at: DateTime.utc_now(),
        last_event_at: DateTime.utc_now()
      }

      %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    end)

    {issue, worker}
  end

  defp held_worker! do
    {:ok, worker} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker), do: :ok = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker)
    end)

    worker
  end

  defp write_config!(path, config) do
    File.write!(path, "---\n" <> Jason.encode!(config) <> "\n---\nControlled tracker fixture.\n")
    :ok = Workflow.set_workflow_file_path(path)
    :ok = WorkflowStore.force_reload()
  end

  defp ledger_events! do
    {:ok, path} = RunLedger.ledger_file_path_checked()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp idle?(state),
    do: is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and state.tracker_poll_pending == [] and not state.poll_check_in_progress and not state.github_webhook_check_in_progress

  defp idle!(pid), do: wait_state!(pid, fn state -> idle?(state) and state.first_poll_completed end)
  defp wait_state!(pid, predicate), do: wait_state!(pid, predicate, System.monotonic_time(:millisecond) + 2_000)

  defp wait_state!(pid, predicate, deadline) do
    state = :sys.get_state(pid, 500)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "Expected state was not observed: #{inspect(state, limit: 5)}"

      receive do
      after
        5 -> wait_state!(pid, predicate, deadline)
      end
    end
  end

  defp pause_idle_scheduler! do
    case Process.whereis(Orchestrator) do
      nil ->
        :ok

      pid ->
        supervisor = Process.whereis(SymphonyElixir.Supervisor)
        assert is_pid(supervisor)
        assert Enum.any?(Supervisor.which_children(supervisor), fn {id, child, _, _} -> id == Orchestrator and child == pid end)
        wait_state!(pid, fn state -> state.running == %{} and idle?(state) end)
        :ok = :sys.suspend(pid)
        on_exit(fn -> :ok = :sys.resume(pid) end)
        assert :sys.get_state(pid).running == %{}
        assert Task.Supervisor.children(SymphonyElixir.TaskSupervisor) == []
    end
  end
end
