defmodule SymphonyElixir.OrchestratorAdmissionAsyncTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{Config, DeployAudit, LeaseManager, Orchestrator, RunLedger, RunStateStore, TrackerEvent, TrackerEventInbox, Workflow, WorkflowStore, Workspace}
  alias SymphonyElixir.Linear.Issue

  defmodule HeldClient do
    def fetch_candidate_issues do
      fixture = Application.fetch_env!(:symphony_elixir, :admission_fixture)
      send(fixture.owner, {:candidates_read, self()})
      {:ok, fixture.candidates}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(ids) do
      fixture = Application.fetch_env!(:symphony_elixir, :admission_fixture)
      send(fixture.owner, {:admission_read, self(), ids})

      receive do
        {:answer, result} -> result
      after
        5_000 -> {:error, :fixture_barrier_timeout}
      end
    end

    def fetch_issue_by_identifier(identifier) do
      fixture = Application.fetch_env!(:symphony_elixir, :admission_fixture)
      {:ok, Enum.find(fixture.candidates, &(&1.identifier == identifier))}
    end

    def fetch_issue_by_id(id) do
      fixture = Application.fetch_env!(:symphony_elixir, :admission_fixture)
      {:ok, Enum.find(fixture.candidates, &(&1.id == id))}
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
  end

  setup do
    pause_idle_scheduler!()
    root = Path.join(System.tmp_dir!(), "symphony-admission-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    root = File.cd!(root, &File.cwd!/0)
    previous = Enum.map([:workflow_file_path, :log_file, :linear_client_module, :admission_fixture], &{&1, Application.fetch_env(:symphony_elixir, &1)})

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
    Application.put_env(:symphony_elixir, :admission_fixture, %{owner: self(), candidates: [issue("A")]})
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "logs/symphony.log"))
    workflow = Path.join(root, "WORKFLOW.md")

    config = %{
      tracker: %{kind: "linear", api_key: "synthetic-local-token", project_slug: "local-poll", required_labels: [], active_states: ["Todo", "In Progress", "Merging"], terminal_states: ["Done"]},
      polling: %{interval_ms: 60_000, discovery_interval_ms: 60_000, healing_interval_ms: 60_000},
      workspace: %{root: Path.join(root, "workspaces")},
      runner: %{install_root: Path.join(root, "runner"), self_host_project: false},
      manual: %{enabled: true, store_root: Path.join(root, "manual")},
      company: %{policy_pack: "private_autopilot", author_profile_path: Path.join(root, "author.json"), credential_registry_path: Path.join(root, "credentials.json")},
      agent: %{max_concurrent_agents: 1, stall_timeout_ms: 0, codex: %{command: "/usr/bin/false", runtime_profile: %{inherit_env: false}}},
      policy: %{publish_required: false, automerge_on_green: false, token_budget: %{per_issue_total: 200_000}}
    }

    write_config!(workflow, config)
    assert :ok = Config.validate!()
    {:ok, root: root, workflow: workflow, config: config}
  end

  test "a held admission has no lease and serves snapshots and worker messages", ctx do
    write_config!(ctx.workflow, put_in(ctx.config, [:agent, :max_concurrent_agents], 2))
    pid = scheduler!()
    assert_receive {:admission_read, reader, ["A"]}, 5_000
    assert {:error, :missing} = LeaseManager.read("A")
    refute File.exists?(Workspace.path_for_issue(issue("A")))
    assert is_map(Orchestrator.snapshot(pid, 500))

    worker_issue = issue("WORKER")
    worker = install_running!(pid, worker_issue)
    send(pid, {:agent_worker_update, worker_issue.id, %{event: :notification, timestamp: DateTime.utc_now(), message: "progress while reading"}})
    state = wait_state!(pid, &(get_in(&1.running, [worker_issue.id, :last_agent_event]) == :notification))
    assert state.running[worker_issue.id].pid == worker
    assert Process.alive?(reader)
    send(reader, {:answer, {:ok, []}})
    idle!(pid)
  end

  test "one pending admission survives later polls without accumulating batches or starving B", ctx do
    ready = Path.join(ctx.root, "worker-ready")
    release = Path.join(ctx.root, "worker-release")
    exited = Path.join(ctx.root, "worker-exited")

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

    hooks = %{before_run: hook, timeout_ms: 5_000}
    write_config!(ctx.workflow, Map.put(ctx.config, :hooks, hooks))
    candidates = [issue("A"), issue("B")]
    fixture(candidates)
    pid = scheduler!()
    assert_receive {:admission_read, reader_a, ["A"]}, 5_000
    operation_a = :sys.get_state(pid).admission_read
    fixture([issue("A"), issue("C")])
    assert_receive {:candidates_read, _}, 5_000
    send(pid, :run_poll_cycle)
    assert_receive {:candidates_read, _}, 5_000
    state = wait_state!(pid, &(Enum.map(&1.last_candidate_issues, fn issue -> issue.id end) == ["A", "C"]))
    assert state.admission_read.ref == operation_a.ref
    assert Enum.map(state.admission_batch.issues, & &1.id) == ["B"]
    refute_receive {:admission_read, _, _}, 50

    send(reader_a, {:answer, {:ok, []}})
    assert_receive {:admission_read, reader_b, ["B"]}, 5_000
    operation_b = :sys.get_state(pid).admission_read
    send(pid, {:tracker_read_result, operation_a.ref, {:ok, [issue("A")]}})
    assert :sys.get_state(pid).admission_read.ref == operation_b.ref
    assert {:error, :missing} = LeaseManager.read("A")
    fixture(candidates)
    # Keep the admitted worker at a real hook barrier. Its signal proves the
    # dispatch gate opened; do not race post-read synchronous effects or retries.
    try do
      send(reader_b, {:answer, {:ok, [issue("B")]}})
      wait_file!(ready, System.monotonic_time(:millisecond) + 5_000)
      state = :sys.get_state(pid, 5_000)
      assert is_nil(state.admission_batch)
      assert Process.alive?(state.running["B"].pid)
      assert {:ok, lease} = LeaseManager.read("B")
      assert lease["owner"] == state.lease_owner
      assert Enum.any?(ledger_events!(), &(&1["event_type"] == "dispatch.started" and &1["issue_id"] == "B"))
      refute Enum.any?(ledger_events!(), &(&1["event_type"] == "dispatch.started" and &1["issue_id"] == "A"))
    after
      # Persistent release also covers an assertion failing before the hook starts.
      # The hook is independently bounded; timeout must never enable the provider.
      File.write!(release, "continue")
      wait_file!(exited, System.monotonic_time(:millisecond) + 5_000)
      assert File.read!(exited) == "released"
    end

    assert %{ok: true} = Orchestrator.stop_issue(pid, issue("B").identifier)
  end

  for action <- [:stop_issue, :pause_issue] do
    test "#{action} completes during the read and suppresses the late answer" do
      pid = scheduler!()
      assert_receive {:admission_read, reader, ["A"]}, 5_000
      assert %{ok: true} = apply(Orchestrator, unquote(action), [pid, issue("A").identifier])
      assert Process.alive?(reader)
      send(reader, {:answer, {:ok, [issue("A")]}})
      state = idle!(pid)
      assert state.running == %{}
      assert {:error, :missing} = LeaseManager.read("A")
      refute File.exists?(Workspace.path_for_issue(issue("A")))
    end
  end

  for change <- [:configuration, :capacity] do
    test "a #{change} change invalidates the entire old batch", ctx do
      fixture([issue("A"), issue("B")])
      pid = scheduler!()
      assert_receive {:admission_read, reader, ["A"]}, 5_000

      config =
        case unquote(change) do
          :configuration -> put_in(ctx.config, [:tracker, :project_slug], "new-project")
          :capacity -> put_in(ctx.config, [:agent, :max_concurrent_agents], 0)
        end

      write_config!(ctx.workflow, config)
      send(reader, {:answer, {:ok, [issue("A")]}})
      state = idle!(pid)
      assert state.candidate_fetch_error == :admission_context_changed
      assert state.running == %{}
      assert {:error, :missing} = LeaseManager.read("A")
      refute_receive {:admission_read, _, ["B"]}, 50
    end
  end

  for outcome <- [:terminal, :different_id, :different_identifier, :missing, :error] do
    test "#{outcome} response cannot acquire a lease and advances the cursor" do
      fixture([issue("A"), issue("B")])
      pid = scheduler!()
      assert_receive {:admission_read, reader, ["A"]}, 5_000

      result =
        case unquote(outcome) do
          :terminal -> {:ok, [%{issue("A") | state: "Done"}]}
          :different_id -> {:ok, [%{issue("A") | id: "OTHER"}]}
          :different_identifier -> {:ok, [%{issue("A") | identifier: "OTHER"}]}
          :missing -> {:ok, []}
          :error -> {:error, :synthetic_read_failure}
        end

      send(reader, {:answer, result})
      assert_receive {:admission_read, reader_b, ["B"]}, 5_000
      assert {:error, :missing} = LeaseManager.read("A")
      send(reader_b, {:answer, {:ok, []}})
      assert idle!(pid).running == %{}
    end
  end

  test "a current worker keeps its lease and workspace when old admission returns" do
    pid = scheduler!()
    assert_receive {:admission_read, reader, ["A"]}, 5_000
    worker = install_running!(pid, issue("A"))
    workspace = Workspace.path_for_issue(issue("A"))
    sentinel = Path.join(workspace, "current.txt")
    File.write!(sentinel, "current work")
    assert {:ok, lease} = LeaseManager.read("A")
    send(reader, {:answer, {:ok, [%{issue("A") | state: "Done"}]}})
    state = idle!(pid)
    assert state.running["A"].pid == worker
    assert {:ok, current_lease} = LeaseManager.read("A")
    assert current_lease["epoch"] == lease["epoch"]
    assert File.read!(sentinel) == "current work"
  end

  test "reader DOWN is diagnosed and advances to the next issue" do
    fixture([issue("A"), issue("B")])
    pid = scheduler!()
    assert_receive {:admission_read, child, ["A"]}, 5_000
    operation = :sys.get_state(pid).admission_read
    monitor = Process.monitor(child)
    Process.exit(operation.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 5_000
    assert_receive {:admission_read, reader_b, ["B"]}, 5_000
    assert :sys.get_state(pid).candidate_fetch_error == {:admission_read_failed, {:tracker_reader_down, :killed}}
    send(reader_b, {:answer, {:ok, []}})
    idle!(pid)
  end

  test "429 from admission keeps tracker backoff and does not start B" do
    fixture([issue("A"), issue("B")])
    pid = scheduler!()
    assert_receive {:admission_read, reader, ["A"]}, 5_000
    send(reader, {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 60_000}}}})
    state = idle!(pid)
    assert state.tracker_backoff_until_ms > System.monotonic_time(:millisecond)
    assert state.running == %{}
    refute_receive {:admission_read, _, ["B"]}, 50
  end

  test "a 429 still throttles B after a stop invalidates the pending issue" do
    fixture([issue("A"), issue("B")])
    pid = scheduler!()
    assert_receive {:admission_read, reader, ["A"]}, 5_000
    assert %{ok: true} = Orchestrator.stop_issue(pid, issue("A").identifier)
    send(reader, {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 60_000}}}})
    state = idle!(pid)
    assert state.tracker_backoff_until_ms > System.monotonic_time(:millisecond)
    assert match?({:admission_read_failed, {:linear_rate_limited, _}}, state.candidate_fetch_error)
    assert state.running == %{}
    refute_receive {:admission_read, _, ["B"]}, 50
  end

  for observation <- [:terminal, :missing, :reassigned] do
    test "a newer webhook #{observation} observation invalidates the held admission" do
      fixture([issue("A"), issue("B")])
      pid = scheduler!()
      assert_receive {:admission_read, reader, ["A"]}, 5_000

      candidates =
        case unquote(observation) do
          :terminal -> [%{issue("A") | state: "Done"}]
          :missing -> []
          :reassigned -> [%{issue("A") | assigned_to_worker: false}]
        end

      fixture(candidates)

      event = %TrackerEvent{
        provider: "linear",
        event_id: "newer-a",
        entity_type: "Issue",
        entity_id: "A",
        issue_identifier: issue("A").identifier,
        action: "update",
        updated_at: DateTime.utc_now(),
        raw: %{}
      }

      assert {:ok, %{accepted: 1}} = TrackerEventInbox.enqueue([event])
      send(pid, :run_webhook_cycle)
      wait_state!(pid, &match?(%DateTime{}, &1.inbox_last_drained_at))
      assert TrackerEventInbox.pending_events(10) == []
      assert Process.alive?(reader)
      send(reader, {:answer, {:ok, [issue("A")]}})
      assert_receive {:admission_read, reader_b, ["B"]}, 5_000
      assert {:error, :missing} = LeaseManager.read("A")
      refute File.exists?(Workspace.path_for_issue(issue("A")))
      send(reader_b, {:answer, {:ok, []}})
      assert idle!(pid).running == %{}
    end
  end

  test "newer backoff cannot be cleared by an old successful admission" do
    pid = scheduler!()
    assert_receive {:admission_read, reader, ["A"]}, 5_000
    until_ms = System.monotonic_time(:millisecond) + 60_000
    :sys.replace_state(pid, &%{&1 | tracker_backoff_until_ms: until_ms, tracker_backoff_reason: "new backoff"})
    send(reader, {:answer, {:ok, [issue("A")]}})
    state = idle!(pid)
    assert state.tracker_backoff_until_ms == until_ms
    assert {:error, :missing} = LeaseManager.read("A")
  end

  test "capacity consumed during the read prevents admission" do
    pid = scheduler!()
    assert_receive {:admission_read, reader, ["A"]}, 5_000
    worker = install_running!(pid, issue("OTHER"))
    send(reader, {:answer, {:ok, [issue("A")]}})
    state = idle!(pid)
    assert state.running["OTHER"].pid == worker
    assert map_size(state.running) == 1
    assert {:error, :missing} = LeaseManager.read("A")
  end

  test "budget accumulated while reading is checked before acquiring the lease" do
    pid = scheduler!()
    assert_receive {:admission_read, reader, ["A"]}, 5_000
    issue = issue("A")
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    assert :ok = RunStateStore.save(workspace, RunStateStore.load_or_default(workspace, issue))
    usage = %{input_tokens: 200_000, output_tokens: 1_000, total_tokens: 201_000}
    assert {:ok, _} = RunStateStore.record_token_usage(workspace, issue, usage)
    send(reader, {:answer, {:ok, [issue]}})
    state = idle!(pid)
    assert state.candidate_fetch_error == {:token_budget_exhausted, "budget.per_issue_total_exceeded"}
    assert {:error, :missing} = LeaseManager.read(issue.id)
    assert {:ok, %{token_usage: ^usage}} = RunStateStore.load(workspace)
  end

  test "a deploy journal created during reading blocks admission and stays intact" do
    pid = scheduler!()
    assert_receive {:admission_read, reader, ["A"]}, 5_000
    workspace = Workspace.path_for_issue(issue("A"))
    marker = DeployAudit.marker_directory(workspace)
    File.mkdir_p!(marker)
    File.write!(Path.join(marker, "marker.json"), "pending sentinel")
    send(reader, {:answer, {:ok, [issue("A")]}})
    state = idle!(pid)
    assert state.candidate_fetch_error == {:deploy_audit_pending, workspace}
    assert {:error, :missing} = LeaseManager.read("A")
    assert File.read!(Path.join(marker, "marker.json")) == "pending sentinel"
  end

  defp wait_file!(path, deadline) do
    unless File.exists?(path) do
      assert System.monotonic_time(:millisecond) < deadline, "Expected hook signal #{Path.basename(path)} was not observed"

      receive do
      after
        5 -> wait_file!(path, deadline)
      end
    end
  end

  defp issue(id), do: %Issue{id: id, identifier: "ISSUE-" <> id, source: :tracker, title: "Controlled admission", description: "Local fixture", state: "Todo", labels: [], assigned_to_worker: true}
  defp fixture(candidates), do: Application.put_env(:symphony_elixir, :admission_fixture, %{owner: self(), candidates: candidates})

  defp install_running!(pid, issue) do
    worker = held_worker!()
    owner = :sys.get_state(pid).lease_owner
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    assert :ok = RunStateStore.save(workspace, RunStateStore.load_or_default(workspace, issue))
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, owner)
    lease = acquired.lease
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

    :sys.replace_state(pid, fn state ->
      entry = %{
        session_id: nil,
        pid: worker,
        ref: Process.monitor(worker),
        identifier: issue.identifier,
        issue: issue,
        custody_ref: custody_ref,
        lease_token: acquired.token,
        lease_owner: owner,
        lease_epoch: lease["epoch"],
        started_at: DateTime.utc_now(),
        last_event_at: DateTime.utc_now()
      }

      %{state | lease_claims: Map.put(state.lease_claims, issue.id, claim), running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
    end)

    worker
  end

  defp scheduler! do
    name = Module.concat(__MODULE__, "Scheduler#{System.unique_integer([:positive])}")
    start_supervised!({Orchestrator, name: name})
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

    case File.read(path) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp idle?(state),
    do: is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and state.tracker_poll_pending == [] and not state.poll_check_in_progress and not state.github_webhook_check_in_progress

  defp idle!(pid), do: wait_state!(pid, fn state -> idle?(state) and state.first_poll_completed and is_nil(state.admission_read) and is_nil(state.admission_batch) end)
  defp wait_state!(pid, predicate), do: wait_state!(pid, predicate, System.monotonic_time(:millisecond) + 5_000)

  defp wait_state!(pid, predicate, deadline) do
    state =
      try do
        :sys.get_state(pid, 5_000)
      catch
        :exit, reason ->
          IO.puts("Admission fixture coordinator timeout: #{inspect(Process.info(pid, [:current_stacktrace, :messages]))}")
          exit(reason)
      end

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
