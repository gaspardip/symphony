defmodule SymphonyElixir.OrchestratorRetryAsyncTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{Config, DispatchAudit, LeaseManager, Orchestrator, OrchestratorRetryDriver, RunLedger, RunStateStore, TrackerEvent, TrackerEventInbox, Workflow, WorkflowStore, Workspace}
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Linear.Issue

  defmodule HeldClient do
    def fetch_candidate_issues, do: held(:candidates, [])
    def fetch_issue_states_by_ids(ids), do: held(:refresh, ids)

    def fetch_issue_by_id(id) do
      case Application.fetch_env!(:symphony_elixir, :retry_fixture) do
        %{webhook: result} -> result
        _ -> held(:individual, [id])
      end
    end

    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_by_identifier(identifier),
      do: {:ok, %Issue{id: String.replace_prefix(identifier, "ISSUE-", ""), identifier: identifier, state: "Todo", title: "Retry", labels: [], assigned_to_worker: true}}

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

    defp held(kind, ids) do
      %{owner: owner} = Application.fetch_env!(:symphony_elixir, :retry_fixture)
      send(owner, {:retry_read, kind, self(), ids})

      receive do
        {:answer, result} -> result
      after
        5_000 -> {:error, :fixture_barrier_timeout}
      end
    end
  end

  setup do
    pause_idle_scheduler!()
    root = Path.join(System.tmp_dir!(), "symphony-retry-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    root = File.cd!(root, &File.cwd!/0)
    previous = Enum.map([:workflow_file_path, :log_file, :linear_client_module, :retry_fixture], &{&1, Application.fetch_env(:symphony_elixir, &1)})

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
    Application.put_env(:symphony_elixir, :retry_fixture, %{owner: self()})
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "logs/symphony.log"))
    workflow = Path.join(root, "WORKFLOW.md")

    config = %{
      tracker: %{kind: "linear", api_key: "synthetic-local-token", project_slug: "local-poll", required_labels: [], active_states: ["Todo", "In Progress", "Merging"], terminal_states: ["Done"]},
      polling: %{interval_ms: 60_000, discovery_interval_ms: 60_000, healing_interval_ms: 60_000},
      workspace: %{root: Path.join(root, "workspaces")},
      runner: %{install_root: Path.join(root, "runner"), self_host_project: false},
      manual: %{enabled: true, store_root: Path.join(root, "manual")},
      company: %{policy_pack: "private_autopilot", author_profile_path: Path.join(root, "author.json"), credential_registry_path: Path.join(root, "credentials.json")},
      agent: %{max_concurrent_agents: 2, stall_timeout_ms: 0, codex: %{command: "/usr/bin/false", runtime_profile: %{inherit_env: false}}},
      policy: %{publish_required: false, automerge_on_green: false, token_budget: %{per_issue_total: 200_000}}
    }

    write_config!(workflow, config)
    assert :ok = Config.validate!()
    {:ok, root: root, workflow: workflow, config: config}
  end

  test "scheduler owns generation fields and an actual timer starts the async retry" do
    pid = driver!(%{})
    injected = make_ref()

    entry =
      GenServer.call(pid, {:schedule, "A", 1, %{identifier: "ISSUE-A", delay_type: :passive_continuation, passive_delay_ms: 1, retry_ref: injected, status: :reading, attempt: 99, due_at_ms: -1}})

    assert entry.retry_ref != injected
    assert entry.attempt == 1
    assert entry.status == :scheduled
    assert_receive {:retry_read, :individual, reader, ["A"]}, 2_000
    assert runtime(pid).retry_attempts["A"].retry_ref == entry.retry_ref
    send(reader, {:answer, {:ok, nil}})
    assert settled!(pid).retry_attempts == %{}
  end

  test "old, duplicate and unversioned timers do not consume a newer retry" do
    entry = retry_entry("A")
    pid = driver!(%{"A" => entry})
    before = runtime(pid)
    send(pid, {:retry_issue, "A"})
    send(pid, {:retry_issue, "A", make_ref()})
    assert runtime(pid) == before
    refute_receive {:retry_read, _, _, _}, 30
    fire(pid, "A")
    assert_receive {:retry_read, :candidates, reader, []}, 2_000
    reading = runtime(pid)
    send(pid, {:retry_issue, "A", entry.retry_ref})
    assert runtime(pid) == reading
    refute_receive {:retry_read, _, _, _}, 30
    send(reader, {:answer, {:ok, []}})
    assert settled!(pid).retry_attempts == %{}
  end

  test "lookup and active refresh retain metadata and serve snapshots and worker messages" do
    entry = retry_entry("A", %{budget_resume_context: %{focus: "retain me"}, attempt: 4})
    pid = driver!(%{"A" => entry})
    worker = install_worker!(pid)
    fire(pid, "A")
    assert_receive {:retry_read, :candidates, lookup, []}, 2_000
    assert_pending_available(pid, worker, entry, "lookup")
    send(lookup, {:answer, {:ok, [issue("A")]}})
    assert_receive {:retry_read, :refresh, refresh, ["A"]}, 2_000
    assert_pending_available(pid, worker, entry, "refresh")
    assert {:error, :missing} = LeaseManager.read("A")
    send(refresh, {:answer, {:ok, []}})
    assert settled!(pid).running["WORKER"].pid == worker
  end

  test "passive retry queries only its issue and rejects a different identity without cleanup", ctx do
    sentinel = Path.join(Workspace.path_for_issue("ISSUE-A"), "keep")
    File.mkdir_p!(Path.dirname(sentinel))
    File.write!(sentinel, "current")
    pid = driver!(%{"A" => retry_entry("A", %{delay_type: :passive_continuation})})
    fire(pid, "A")
    assert_receive {:retry_read, :individual, reader, ["A"]}, 2_000
    send(reader, {:answer, {:ok, %{issue("OTHER") | state: "Done"}}})
    state = settled!(pid)
    assert state.candidate_fetch_error == :admission_identity_mismatch
    assert File.read!(sentinel) == "current"
    assert state.running == %{}
    refute_receive {:retry_read, :candidates, _, _}, 30
    assert File.dir?(ctx.root)
  end

  for phase <- [:lookup, :refresh], change <- [:new_retry, :stop, :pause, :configuration] do
    test "#{change} during #{phase} cannot consume a new retry or dispatch old data", ctx do
      pid = driver!(%{"A" => retry_entry("A", %{attempt: 3})})
      reader = held_phase(pid, unquote(phase))

      expected =
        case unquote(change) do
          :new_retry ->
            GenServer.call(pid, {:schedule, "A", 7, %{identifier: "ISSUE-A", error: "new generation", budget_resume_context: %{focus: "new"}}})

          :stop ->
            assert %{ok: true} = Orchestrator.stop_issue(pid, "ISSUE-A")
            nil

          :pause ->
            assert %{ok: true} = Orchestrator.pause_issue(pid, "ISSUE-A")
            nil

          :configuration ->
            write_config!(ctx.workflow, put_in(ctx.config, [:tracker, :project_slug], "changed"))
            :rearmed
        end

      old = runtime(pid).admission_read
      send(reader, {:answer, {:ok, [issue("A")]}})
      state = settled!(pid)
      assert state.running == %{}
      assert {:error, :missing} = LeaseManager.read("A")
      refute File.exists?(Workspace.path_for_issue("ISSUE-A"))

      case expected do
        :rearmed ->
          assert state.retry_attempts["A"].attempt == 3
          assert state.retry_attempts["A"].retry_ref != old.retry_ref
          assert state.retry_attempts["A"].status == :scheduled

        nil ->
          refute Map.has_key?(state.retry_attempts, "A")

        entry ->
          assert state.retry_attempts["A"] == entry
      end

      refute_receive {:retry_read, _, _, _}, 30
    end
  end

  for phase <- [:lookup, :refresh], error <- [:failure, :rate_limit, :down] do
    test "#{error} during #{phase} reprograms exactly once with metadata" do
      pid = driver!(%{"A" => retry_entry("A", %{attempt: 3, budget_resume_context: %{focus: "saved"}})})
      reader = held_phase(pid, unquote(phase))
      operation = runtime(pid).admission_read

      case unquote(error) do
        :failure -> send(reader, {:answer, {:error, :read_failed}})
        :rate_limit -> send(reader, {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 60_000}}}})
        :down -> Process.exit(operation.pid, :kill)
      end

      state = settled!(pid)
      entry = state.retry_attempts["A"]
      assert entry.attempt == 4
      assert entry.budget_resume_context == %{focus: "saved"}
      assert entry.retry_ref != operation.retry_ref
      assert entry.status == :scheduled
      assert entry.error =~ if(unquote(phase) == :lookup, do: "retry poll failed", else: "retry refresh failed")
      send(pid, {:tracker_read_result, operation.ref, {:ok, [issue("A")]}})
      assert runtime(pid).retry_attempts["A"] == entry
      if unquote(error) == :rate_limit, do: assert(state.tracker_backoff_until_ms > System.monotonic_time(:millisecond))
      assert state.running == %{}
    end
  end

  test "backoff waiting preserves attempts and an older success cannot clear a newer throttle" do
    pid = driver!(%{"A" => retry_entry("A", %{attempt: 3})})
    reader = held_phase(pid, :lookup)
    deadline = System.monotonic_time(:millisecond) + 60_000
    replace_runtime(pid, fn state -> %{state | tracker_backoff_until_ms: deadline, tracker_backoff_reason: "new throttle"} end)
    send(reader, {:answer, {:ok, [issue("A")]}})
    state = settled!(pid)
    assert state.tracker_backoff_until_ms == deadline
    assert state.retry_attempts["A"].attempt == 3
    first_ref = state.retry_attempts["A"].retry_ref
    fire(pid, "A")
    state = runtime(pid)
    assert state.retry_attempts["A"].attempt == 3
    assert state.retry_attempts["A"].retry_ref != first_ref
    refute_receive {:retry_read, _, _, _}, 30
  end

  test "a 429 remains transport evidence after stop invalidates the retry" do
    pid = driver!(%{"A" => retry_entry("A")})
    reader = held_phase(pid, :lookup)
    assert %{ok: true} = Orchestrator.stop_issue(pid, "ISSUE-A")
    send(reader, {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 60_000}}}})
    state = settled!(pid)
    assert state.retry_attempts == %{}
    assert state.tracker_backoff_until_ms > System.monotonic_time(:millisecond)
  end

  test "C1 and ready retries alternate logical attempts while B retains its own reader" do
    pid = driver!(%{"A" => retry_entry("A"), "B" => retry_entry("B")})
    replace_runtime(pid, fn state -> %{state | admission_batch: %{issues: [issue("P"), issue("Q")], invalidated: MapSet.new()}} end)
    fire(pid, "A")
    assert_receive {:retry_read, :refresh, poll_p, ["P"]}, 2_000
    fire(pid, "B")
    assert runtime(pid).retry_attempts["A"].status == :ready
    assert runtime(pid).retry_attempts["B"].status == :ready
    send(pid, :run_poll_cycle)
    assert_receive {:retry_read, :candidates, poll_b, []}, 2_000
    state = runtime(pid)
    assert is_map(state.admission_read)
    assert is_map(state.tracker_poll_read)
    refute_receive {:retry_read, _, _, _}, 30
    send(poll_b, {:answer, {:ok, []}})
    send(poll_p, {:answer, {:ok, []}})
    assert_receive {:retry_read, :candidates, retry_a, []}, 2_000
    assert runtime(pid).admission_read.issue.id == "A"
    send(retry_a, {:answer, {:ok, []}})
    assert_receive {:retry_read, :refresh, poll_q, ["Q"]}, 2_000
    send(poll_q, {:answer, {:ok, []}})
    assert_receive {:retry_read, :candidates, retry_b, []}, 2_000
    assert runtime(pid).admission_read.issue.id == "B"
    send(retry_b, {:answer, {:ok, []}})
    assert settled!(pid).retry_attempts == %{}
  end

  test "a newer lease prevents late terminal cleanup" do
    pid = driver!(%{"A" => retry_entry("A")})
    reader = held_phase(pid, :lookup)
    workspace = Workspace.path_for_issue("ISSUE-A")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sentinel"), "successor")
    assert :ok = LeaseManager.acquire("A", "ISSUE-A", "successor")
    before = File.read!(LeaseManager.lease_path("A"))
    send(reader, {:answer, {:ok, [%{issue("A") | state: "Done"}]}})
    state = settled!(pid)
    assert state.retry_attempts["A"].attempt == 2
    assert File.read!(LeaseManager.lease_path("A")) == before
    assert File.read!(Path.join(workspace, "sentinel")) == "successor"
    assert state.running == %{}
  end

  test "changed root discards waiting C1 candidates and rearming cannot write their new workspace", ctx do
    metadata = %{budget_resume_context: %{focus: "old context"}}
    pid = driver!(%{"A" => retry_entry("A", metadata)})
    reader = held_phase(pid, :lookup)
    replace_runtime(pid, fn state -> %{state | admission_batch: %{issues: [issue("P")], invalidated: MapSet.new()}} end)
    new_root = Path.join(ctx.root, "new-workspaces")
    write_config!(ctx.workflow, put_in(ctx.config, [:workspace, :root], new_root))
    workspace = Workspace.path_for_issue("ISSUE-A")
    assert :ok = RunStateStore.save(workspace, RunStateStore.load_or_default(workspace, issue("A")))
    before = File.read!(RunStateStore.state_path(workspace))
    send(reader, {:answer, {:ok, [issue("A")]}})
    state = settled!(pid)
    assert is_nil(state.admission_batch)
    assert state.retry_attempts["A"].attempt == 2
    assert state.retry_attempts["A"].budget_resume_context == metadata.budget_resume_context
    assert File.read!(RunStateStore.state_path(workspace)) == before
    refute_receive {:retry_read, _, _, _}, 30
    assert {:error, :missing} = LeaseManager.read("A")
  end

  test "capacity consumed during refresh reprograms once and retains context" do
    pid = driver!(%{"A" => retry_entry("A", %{budget_resume_context: %{focus: "saved"}})})
    reader = held_phase(pid, :refresh)
    install_worker!(pid, "WORKER")
    install_worker!(pid, "OTHER")
    send(reader, {:answer, {:ok, [issue("A")]}})
    state = settled!(pid)
    assert state.retry_attempts["A"].attempt == 3
    assert state.retry_attempts["A"].error == "no available orchestrator slots"
    assert state.retry_attempts["A"].budget_resume_context == %{focus: "saved"}
    assert {:error, :missing} = LeaseManager.read("A")
  end

  test "manual fallback does not erase the separate remote 429 or start remote reads during backoff", ctx do
    write_config!(ctx.workflow, put_in(ctx.config, [:agent, :max_concurrent_agents], 0))
    issue = %{issue("A") | id: "manual:A", source: :manual}
    entry = retry_entry("A", %{issue: issue})
    pid = driver!(%{issue.id => entry})
    replace_runtime(pid, fn state -> %{state | max_concurrent_agents: 0} end)
    fire(pid, issue.id)
    assert_receive {:retry_read, :candidates, reader, []}, 2_000
    send(reader, {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 60_000}}}})
    state = settled!(pid)
    deadline = state.tracker_backoff_until_ms
    assert deadline > System.monotonic_time(:millisecond)
    assert state.retry_attempts[issue.id].issue == issue
    assert state.retry_attempts[issue.id].attempt == 3
    assert state.retry_attempts[issue.id].error == "no available orchestrator slots"
    fire(pid, issue.id)
    state = settled!(pid)
    assert state.tracker_backoff_until_ms == deadline
    assert state.retry_attempts[issue.id].attempt == 4
    refute_receive {:retry_read, _, _, _}, 30
  end

  test "refresh with multiple identities never acquires a lease" do
    pid = driver!(%{"A" => retry_entry("A")})
    reader = held_phase(pid, :refresh)
    send(reader, {:answer, {:ok, [issue("A"), issue("OTHER")]}})
    state = settled!(pid)
    assert state.candidate_fetch_error == :admission_identity_mismatch
    assert state.running == %{}
    assert {:error, :missing} = LeaseManager.read("A")
  end

  for absent <- [:id, :identifier, :both] do
    test "R2 refresh rejects missing raw #{absent} before merging the issue" do
      pid = driver!(%{"A" => retry_entry("A")})
      reader = held_phase(pid, :refresh)
      issue = issue("A")
      issue = if unquote(absent) in [:id, :both], do: %{issue | id: nil}, else: issue
      issue = if unquote(absent) in [:identifier, :both], do: %{issue | identifier: nil}, else: issue
      send(reader, {:answer, {:ok, [issue]}})
      state = settled!(pid)
      assert state.candidate_fetch_error == :admission_identity_mismatch
      assert state.running == %{}
      assert {:error, :missing} = LeaseManager.read("A")
      refute File.exists?(Workspace.path_for_issue("ISSUE-A"))
    end
  end

  test "R1 capacity changed before a timer is enforced without polling", ctx do
    pid = driver!(%{"A" => retry_entry("A")})
    assert runtime(pid).max_concurrent_agents == 2
    write_config!(ctx.workflow, put_in(ctx.config, [:agent, :max_concurrent_agents], 0))
    fire(pid, "A")
    assert_receive {:retry_read, :candidates, reader, []}, 2_000
    send(reader, {:answer, {:ok, [issue("A")]}})
    state = settled!(pid)
    assert state.max_concurrent_agents == 0
    assert state.retry_attempts["A"].attempt == 3
    assert state.retry_attempts["A"].error == "no available orchestrator slots"
    assert state.running == %{}
    assert {:error, :missing} = LeaseManager.read("A")
    refute_receive {:retry_read, :refresh, _, _}, 30
  end

  test "R1 retry rearmed after capacity change enforces the new limit before another poll", ctx do
    pid = driver!(%{"A" => retry_entry("A")})
    reader = held_phase(pid, :lookup)
    old_ref = runtime(pid).retry_attempts["A"].retry_ref
    write_config!(ctx.workflow, put_in(ctx.config, [:agent, :max_concurrent_agents], 0))
    send(reader, {:answer, {:ok, [issue("A")]}})
    state = settled!(pid)
    assert state.retry_attempts["A"].attempt == 2
    assert state.retry_attempts["A"].retry_ref != old_ref
    fire(pid, "A")
    assert_receive {:retry_read, :candidates, next_reader, []}, 2_000
    send(next_reader, {:answer, {:ok, [issue("A")]}})
    state = settled!(pid)
    assert state.max_concurrent_agents == 0
    assert state.retry_attempts["A"].attempt == 3
    assert state.running == %{}
    assert {:error, :missing} = LeaseManager.read("A")
    refute_receive {:retry_read, :refresh, _, _}, 30
  end

  test "R3 invalid config during a queued retry preserves the active C1 batch", ctx do
    pid = driver!(%{"A" => retry_entry("A"), "B" => retry_entry("B")})
    replace_runtime(pid, fn state -> %{state | admission_batch: %{issues: [issue("P"), issue("Q")], invalidated: MapSet.new()}} end)
    fire(pid, "A")
    assert_receive {:retry_read, :refresh, poll_p, ["P"]}, 2_000
    before = runtime(pid)
    write_config!(ctx.workflow, put_in(ctx.config, [:tracker, :kind], "unsupported"))
    assert {:error, _} = Config.validate!()
    fire(pid, "B")
    state = runtime(pid)
    assert state.admission_read.ref == before.admission_read.ref
    assert state.admission_batch == before.admission_batch
    assert state.retry_attempts["B"].status == :ready
    write_config!(ctx.workflow, ctx.config)
    send(poll_p, {:answer, {:ok, []}})
    assert_receive {:retry_read, :candidates, retry_a, []}, 2_000
    assert Process.alive?(pid)
    send(retry_a, {:answer, {:ok, []}})
    assert_receive {:retry_read, :refresh, poll_q, ["Q"]}, 2_000
    send(poll_q, {:answer, {:ok, []}})
    assert_receive {:retry_read, :candidates, retry_b, []}, 2_000
    send(retry_b, {:answer, {:ok, []}})
    assert settled!(pid).retry_attempts == %{}
  end

  for phase <- [:lookup, :refresh] do
    test "a newer webhook invalidates retry #{phase} without a C1 batch" do
      pid = driver!(%{"A" => retry_entry("A")})
      reader = held_phase(pid, unquote(phase))
      assert is_nil(runtime(pid).admission_batch)
      Application.put_env(:symphony_elixir, :retry_fixture, %{owner: self(), webhook: {:ok, nil}})
      event = %TrackerEvent{provider: "linear", event_id: "newer-retry", entity_type: "Issue", entity_id: "A", issue_identifier: "ISSUE-A", action: "update", updated_at: DateTime.utc_now(), raw: %{}}
      assert {:ok, %{accepted: 1}} = TrackerEventInbox.enqueue([event])
      send(pid, :run_webhook_cycle)
      await_state!(pid, &match?(%DateTime{}, &1.inbox_last_drained_at))
      assert runtime(pid).admission_read.invalidated
      assert TrackerEventInbox.pending_events(10) == []
      send(reader, {:answer, {:ok, [issue("A")]}})
      state = settled!(pid)
      assert state.retry_attempts["A"].attempt == 2
      assert state.running == %{}
      assert {:error, :missing} = LeaseManager.read("A")
    end
  end

  for result <- [:terminal, :missing] do
    test "a contradictory snapshot during lookup prevents #{result} cleanup" do
      pid = driver!(%{"A" => retry_entry("A")})
      reader = held_phase(pid, :lookup)
      workspace = Workspace.path_for_issue("ISSUE-A")
      path = RunStateStore.state_path(workspace)
      File.mkdir_p!(Path.dirname(path))
      bytes = Jason.encode!(%{issue_id: "OTHER", issue_identifier: "ISSUE-A", stage: "implement", token_usage: %{total_tokens: 456}})
      File.write!(path, bytes)
      sentinel = Path.join(workspace, "successor-work")
      File.write!(sentinel, "keep")
      issues = if unquote(result) == :terminal, do: [%{issue("A") | state: "Done"}], else: []
      send(reader, {:answer, {:ok, issues}})
      state = settled!(pid)
      assert state.running == %{}
      assert state.retry_attempts == %{}
      assert state.candidate_fetch_error == {:dispatch_audit_failed, "A", :run_identity_issue_mismatch}
      assert File.read!(path) == bytes
      assert File.read!(sentinel) == "keep"
      assert {:error, :missing} = LeaseManager.read("A")
    end
  end

  for payload <- [:contradictory, :pending] do
    test "I1 #{payload} snapshot arriving during refresh blocks before lease synchronization" do
      pid = driver!(%{"A" => retry_entry("A")})
      reader = held_phase(pid, :refresh)
      path = RunStateStore.state_path(Workspace.path_for_issue("ISSUE-A"))
      File.mkdir_p!(Path.dirname(path))
      snapshot = %{issue_id: "OTHER", issue_identifier: "ISSUE-A", stage: "implement", token_usage: %{total_tokens: 123}}
      snapshot = if unquote(payload) == :pending, do: Map.put(snapshot, :run_identity_pending, %{}), else: snapshot
      bytes = Jason.encode!(snapshot)
      File.write!(path, bytes)
      send(reader, {:answer, {:ok, [issue("A")]}})
      state = settled!(pid)
      assert state.running == %{}
      assert state.retry_attempts == %{}
      assert File.read!(path) == bytes
      assert {:error, :missing} = LeaseManager.read("A")
      refute File.exists?(Path.join(DispatchAudit.marker_directory(Path.dirname(Path.dirname(path))), "marker.json"))
    end
  end

  test "timer to real worker preserves I1 run, accumulated tokens, focus and attempt", ctx do
    ready = Path.join(ctx.root, "retry-worker-ready")
    release = Path.join(ctx.root, "retry-worker-release")
    exited = Path.join(ctx.root, "retry-worker-exited")

    hook = """
    printf ready > '#{ready}'
    n=0
    while [ ! -f '#{release}' ]; do
      n=$((n + 1))
      if [ "$n" -ge 1000 ]; then exit 1; fi
      sleep 0.01
    done
    printf released > '#{exited}.tmp'
    mv '#{exited}.tmp' '#{exited}'
    """

    write_config!(ctx.workflow, Map.put(ctx.config, :hooks, %{before_run: hook, timeout_ms: 15_000}))
    issue = issue("A")
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(Path.join(workspace, ".git"))
    usage = %{input_tokens: 123, output_tokens: 7, total_tokens: 130}
    original = RunStateStore.load_or_default(workspace, issue) |> Map.merge(%{stage: "implement", token_usage: usage})
    assert :ok = RunStateStore.save(workspace, original)
    assert {:ok, first} = DispatchAudit.begin(workspace, %{issue_id: issue.id, issue_identifier: issue.identifier, metadata: %{owner: "previous", epoch: 1}})
    assert :ok = DispatchAudit.finish(first, :normal)
    identity_events_before = identity_events()
    pid = driver!(%{})
    context = %{focus: "lib/retry.ex", target_paths: ["lib/retry.ex"], already_learned: "Keep established invariants"}
    entry = GenServer.call(pid, {:schedule, "A", 1, %{identifier: "ISSUE-A", delay_type: :continuation, budget_resume_context: context}})
    assert_receive {:retry_read, :candidates, lookup, []}, 2_000
    assert runtime(pid).retry_attempts["A"].retry_ref == entry.retry_ref
    send(lookup, {:answer, {:ok, [issue]}})
    assert_receive {:retry_read, :refresh, refresh, ["A"]}, 2_000

    try do
      send(refresh, {:answer, {:ok, [issue]}})
      wait_file!(ready)
      running = runtime(pid).running["A"]
      assert Process.alive?(running.pid)
      assert running.retry_attempt == 1
      assert running.issue_token_usage_base == usage
      assert running.resume_context.focus == context.focus
      assert running.resume_context.target_paths == context.target_paths
      assert running.dispatch_ticket.run_id == first.run_id
      refute running.dispatch_ticket.dispatch_id == first.dispatch_id
      assert {:ok, persisted} = RunStateStore.load(workspace)
      assert persisted.run_id == first.run_id
      assert persisted.token_usage == usage
      assert identity_events() == identity_events_before
      assert runtime(pid).retry_attempts == %{}
    after
      File.write!(release, "release")
      wait_file!(exited)
      assert File.read!(exited) == "released"
    end

    assert %{ok: true} = Orchestrator.stop_issue(pid, "ISSUE-A")
  end

  defp identity_events do
    RunLedger.ledger_file_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&String.starts_with?(&1["event_type"], "run.identity."))
  end

  defp wait_file!(path), do: wait_file!(path, System.monotonic_time(:millisecond) + 2_000)

  defp wait_file!(path, deadline) do
    unless File.exists?(path) do
      assert System.monotonic_time(:millisecond) < deadline, "Missing hook marker #{path}"

      receive do
      after
        5 -> wait_file!(path, deadline)
      end
    end
  end

  defp issue(id), do: %Issue{id: id, identifier: "ISSUE-" <> id, title: "Retry", description: "Local fixture", state: "Todo", labels: [], assigned_to_worker: true, source: :tracker}

  defp retry_entry(id, metadata \\ %{}) do
    Map.merge(%{attempt: 2, retry_ref: make_ref(), status: :scheduled, timer_ref: nil, due_at_ms: 0, identifier: "ISSUE-" <> id, delay_type: :continuation}, metadata)
  end

  defp driver!(entries) do
    state = %State{
      lease_owner: "retry-#{System.unique_integer([:positive])}",
      max_concurrent_agents: 2,
      poll_interval_ms: 60_000,
      healing_poll_interval_ms: 60_000,
      retry_attempts: entries,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
    }

    {:ok, pid} = OrchestratorRetryDriver.start_link(state, "A")
    Process.unlink(pid)
    on_exit(fn -> cleanup_driver!(pid) end)
    pid
  end

  defp cleanup_driver!(pid) do
    if Process.alive?(pid) do
      :ok = :sys.suspend(pid)
      %{runtime: state} = :sys.get_state(pid)
      readers = Enum.reject([state.admission_read, state.tracker_poll_read], &is_nil/1)
      monitors = Enum.map(readers, &{&1.pid, Process.monitor(&1.pid)})

      Enum.each(state.retry_attempts, fn {_id, entry} ->
        if is_reference(entry[:timer_ref]), do: Process.cancel_timer(entry.timer_ref)
      end)

      # Cancellation must run in the reader owner; suspension keeps queued
      # results and worker DOWN messages from starting another continuation.
      :sys.replace_state(pid, fn wrapper ->
        Enum.each(readers, fn reader -> :ok = SymphonyElixir.TrackerReader.cancel(reader) end)
        wrapper
      end)

      GenServer.stop(pid)
      Enum.each(state.running, fn {_id, entry} -> stop_fixture_worker!(entry.pid) end)

      Enum.each(monitors, fn {reader, monitor} ->
        assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 500
      end)
    end
  end

  defp stop_fixture_worker!(worker) do
    monitor = Process.monitor(worker)
    if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 500
  end

  defp runtime(pid), do: GenServer.call(pid, :runtime, 500)
  defp fire(pid, id), do: send(pid, {:retry_issue, id, runtime(pid).retry_attempts[id].retry_ref})
  defp replace_runtime(pid, fun), do: :sys.replace_state(pid, fn wrapper -> %{wrapper | runtime: fun.(wrapper.runtime)} end)

  defp settled!(pid), do: await_state!(pid, &(is_nil(&1.admission_read) and Enum.all?(&1.retry_attempts, fn {_id, entry} -> entry.status == :scheduled end)))
  defp await_state!(pid, predicate), do: await_state!(pid, predicate, System.monotonic_time(:millisecond) + 2_000)

  defp await_state!(pid, predicate, deadline) do
    state = runtime(pid)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "State did not settle: #{inspect(state)}"

      receive do
      after
        5 -> await_state!(pid, predicate, deadline)
      end
    end
  end

  defp held_phase(pid, phase) do
    fire(pid, "A")
    assert_receive {:retry_read, :candidates, reader, []}, 2_000

    if phase == :refresh do
      send(reader, {:answer, {:ok, [issue("A")]}})
      assert_receive {:retry_read, :refresh, refresh, ["A"]}, 2_000
      refresh
    else
      reader
    end
  end

  defp assert_pending_available(pid, worker, entry, message) do
    assert is_map(Orchestrator.snapshot(pid, 500))
    state = runtime(pid)
    assert state.retry_attempts["A"].retry_ref == entry.retry_ref
    assert state.retry_attempts["A"].attempt == entry.attempt
    assert state.retry_attempts["A"].budget_resume_context == entry.budget_resume_context
    timestamp = DateTime.utc_now()
    send(pid, {:agent_worker_update, "WORKER", %{event: :notification, timestamp: timestamp, payload: message}})
    expected = %{event: :notification, timestamp: timestamp, message: message}
    state = await_state!(pid, &(get_in(&1.running, ["WORKER", :last_agent_message]) == expected))
    assert state.running["WORKER"].pid == worker
  end

  defp install_worker!(pid, id \\ "WORKER") do
    {:ok, worker} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    # Register immediately so failure before insertion into running cannot leak
    # this exact fixture worker. Stop its owner first to prevent retry-on-DOWN.
    on_exit(fn ->
      try do
        cleanup_driver!(pid)
      after
        stop_fixture_worker!(worker)
      end
    end)

    issue = issue(id)
    state = runtime(pid)
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    assert :ok = RunStateStore.save(workspace, RunStateStore.load_or_default(workspace, issue))
    assert :ok = LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)

    entry = %{
      pid: worker,
      ref: Process.monitor(worker),
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.utc_now(),
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      issue_token_usage_base: %{},
      recent_agent_updates: [],
      turn_count: 0,
      last_agent_timestamp: nil,
      last_agent_message: nil,
      last_agent_event: nil,
      session_id: nil,
      agent_process_id: nil
    }

    replace_runtime(pid, fn state -> %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)} end)
    worker
  end

  defp write_config!(path, config) do
    File.write!(path, "---\n" <> Jason.encode!(config) <> "\n---\nControlled retry fixture.\n")
    :ok = Workflow.set_workflow_file_path(path)
    :ok = WorkflowStore.force_reload()
  end

  defp wait_state!(pid, predicate), do: wait_state!(pid, predicate, System.monotonic_time(:millisecond) + 2_000)

  defp wait_state!(pid, predicate, deadline) do
    state =
      try do
        :sys.get_state(pid, 500)
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
        wait_state!(pid, fn state -> state.running == %{} and is_nil(state.tracker_poll_read) and is_nil(state.tracker_poll_cycle) and not state.poll_check_in_progress end)
        :ok = :sys.suspend(pid)
        on_exit(fn -> :ok = :sys.resume(pid) end)
        assert :sys.get_state(pid).running == %{}
        assert Task.Supervisor.children(SymphonyElixir.TaskSupervisor) == []
    end
  end
end
