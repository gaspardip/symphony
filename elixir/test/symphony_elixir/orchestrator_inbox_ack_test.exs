defmodule SymphonyElixir.OrchestratorInboxAckTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{Config, GitHubEvent, GitHubEventInbox, Orchestrator, TrackerEvent, TrackerEventInbox, Workflow, WorkflowStore}
  alias SymphonyElixir.Linear.Issue

  defmodule Client do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}

    def fetch_issue_by_id(id) do
      fixture = Application.fetch_env!(:symphony_elixir, :inbox_ack_fixture)
      send(fixture.owner, {:lookup, id})

      if id == "RATE" do
        {:error, {:linear_rate_limited, %{retry_after_ms: 60_000}}}
      else
        {:ok, %Issue{id: id, identifier: "ISSUE-#{id}", state: "Done", source: :tracker, title: "Inbox fixture", labels: [], assigned_to_worker: true}}
      end
    end
  end

  defmodule Driver do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_info({:tracker_inbox_ack, _cursor} = message, state) do
      fixture = Application.fetch_env!(:symphony_elixir, :inbox_ack_fixture)
      # The actual ack continuation runs after the decision/cache mutation.
      if fixture.block_ack, do: File.mkdir!(fixture.location.lock_path)
      Orchestrator.handle_info(message, state)
    end

    def handle_info(message, state), do: Orchestrator.handle_info(message, state)
    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}
    def handle_call(:github_pending_events, _from, state), do: {:reply, GitHubEventInbox.pending_events(), state}
    def handle_call(message, from, state), do: Orchestrator.handle_call(message, from, state)
  end

  setup do
    pause_scheduler!()
    root = Path.join(System.tmp_dir!(), "inbox-owner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Enum.map([:log_file, :workflow_file_path, :linear_client_module, :inbox_ack_fixture], &{&1, Application.fetch_env(:symphony_elixir, &1)})

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

    config = %{
      tracker: %{kind: "linear", api_key: "synthetic-local-token", project_slug: "local-poll", required_labels: [], active_states: ["Todo", "In Progress"], terminal_states: ["Done"]},
      polling: %{interval_ms: 60_000, discovery_interval_ms: 60_000, healing_interval_ms: 60_000},
      workspace: %{root: Path.join(root, "workspaces")},
      runner: %{install_root: Path.join(root, "runner"), self_host_project: false},
      manual: %{enabled: true, store_root: Path.join(root, "manual")},
      company: %{policy_pack: "private_autopilot", author_profile_path: Path.join(root, "author.json"), credential_registry_path: Path.join(root, "credentials.json")},
      agent: %{max_concurrent_agents: 0, stall_timeout_ms: 0, codex: %{command: "/usr/bin/false", runtime_profile: %{inherit_env: false}}},
      policy: %{publish_required: false, automerge_on_green: false}
    }

    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nInbox fixture.\n")
    :ok = Workflow.set_workflow_file_path(workflow)
    :ok = WorkflowStore.force_reload()
    assert :ok = Config.validate!()
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "logs/symphony.log"))
    Application.put_env(:symphony_elixir, :linear_client_module, Client)
    location = TrackerEventInbox.location()
    fixture = %{owner: self(), location: location, block_ack: true}
    Application.put_env(:symphony_elixir, :inbox_ack_fixture, fixture)
    now = System.monotonic_time(:millisecond)

    state = %Orchestrator.State{
      poll_interval_ms: 60_000,
      healing_poll_interval_ms: 60_000,
      next_poll_due_at_ms: now + 60_000,
      next_healing_poll_due_at_ms: now + 60_000,
      max_concurrent_agents: 0,
      poll_check_in_progress: false,
      lease_owner: "inbox-fixture",
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    pid = start_supervised!({Driver, state})
    {:ok, root: root, pid: pid, location: location, fixture: fixture}
  end

  test "a failed ack retries only confirmation even after the configured root changes", ctx do
    assert {:ok, _} = TrackerEventInbox.enqueue([event("A")])
    send(ctx.pid, :run_webhook_cycle)
    assert_receive {:lookup, "A"}, 5_000
    state = wait_state!(ctx.pid, &(&1.inbox_ack_pending != nil and &1.inbox_storage_error != nil and idle?(&1)))
    assert state.issue_routing_cache["A"].state == "Done"
    assert state.inbox_storage_error.phase == :lock
    assert state.inbox_last_drained_at == nil
    cursor = state.inbox_ack_pending
    assert cursor.location == ctx.location
    File.rmdir!(ctx.location.lock_path)
    Application.put_env(:symphony_elixir, :inbox_ack_fixture, %{ctx.fixture | block_ack: false})
    Application.put_env(:symphony_elixir, :log_file, Path.join(ctx.root, "new-root/symphony.log"))
    assert {:ok, _} = TrackerEventInbox.enqueue([event("B")])
    send(ctx.pid, :run_webhook_cycle)
    state = wait_state!(ctx.pid, &(&1.inbox_ack_pending == nil and is_struct(&1.inbox_last_drained_at, DateTime) and idle?(&1)))
    assert state.inbox_storage_error == nil
    refute_receive {:lookup, _}, 50
    assert [%{"event" => %{"entity_id" => "B"}}] = TrackerEventInbox.pending_events()
    assert {:ok, %{rows: []}} = TrackerEventInbox.capture(ctx.location, %{max_rows: 100, max_bytes: 4 * 1024 * 1024})
    send(ctx.pid, :run_webhook_cycle)
    assert_receive {:lookup, "B"}, 5_000
    wait_state!(ctx.pid, &(idle?(&1) and Map.has_key?(&1.issue_routing_cache, "B")))
    assert [] == TrackerEventInbox.pending_events()
  end

  test "reset retires the pending cursor without confirming the next generation", ctx do
    assert {:ok, _} = TrackerEventInbox.enqueue([event("A")])
    send(ctx.pid, :run_webhook_cycle)
    assert_receive {:lookup, "A"}, 5_000
    wait_state!(ctx.pid, &(&1.inbox_ack_pending != nil and &1.inbox_storage_error != nil and idle?(&1)))
    File.rmdir!(ctx.location.lock_path)
    assert :ok = TrackerEventInbox.reset(ctx.location)
    assert {:ok, _} = TrackerEventInbox.enqueue([event("A")])
    Application.put_env(:symphony_elixir, :inbox_ack_fixture, %{ctx.fixture | block_ack: false})
    send(ctx.pid, :run_webhook_cycle)
    state = wait_state!(ctx.pid, &(&1.inbox_ack_pending == nil and &1.inbox_storage_error != nil and idle?(&1)))
    assert state.inbox_storage_error.reason_code == :generation_changed
    assert [%{"event" => %{"entity_id" => "A"}}] = TrackerEventInbox.pending_events()
    refute_receive {:lookup, _}, 50
  end

  test "malformed physical prefix is discarded and GitHub routing metadata remains intact", ctx do
    location = GitHubEventInbox.location()
    assert :ok = GitHubEventInbox.initialize(location)
    File.write!(location.events_path, "invalid\n")

    assert {:ok, _} =
             GitHubEventInbox.enqueue([
               %GitHubEvent{provider: "github", event_id: "github-A", event_name: "ping", action: "ping", received_runner_channel: "canary", received_runner_instance_id: "canary:test", raw: %{}}
             ])

    send(ctx.pid, :run_github_webhook_cycle)
    state = wait_state!(ctx.pid, &(is_struct(&1.github_inbox_last_drained_at, DateTime) and idle?(&1) and is_nil(&1.github_inbox_batch) and is_nil(&1.github_inbox_ack_pending)))
    assert state.github_last_assignment.event_id == "github-A"
    assert state.github_last_assignment.received_runner_channel == "canary"
    assert state.github_last_assignment.received_runner_instance_id == "canary:test"
    assert state.github_last_assignment.assignment_reason == "non_review_affecting_event"
    assert [] == GenServer.call(ctx.pid, :github_pending_events, 5_000)
    assert state.github_inbox_ack_pending == nil
  end

  test "a 429 preserves its head after confirming malformed and applied physical rows", ctx do
    Application.put_env(:symphony_elixir, :inbox_ack_fixture, %{ctx.fixture | block_ack: false})
    assert :ok = TrackerEventInbox.initialize(ctx.location)
    File.write!(ctx.location.events_path, "invalid\n")
    assert {:ok, _} = TrackerEventInbox.enqueue([event("A"), event("RATE"), event("B")])
    send(ctx.pid, :run_webhook_cycle)
    assert_receive {:lookup, "A"}, 5_000
    assert_receive {:lookup, "RATE"}, 5_000
    state = wait_state!(ctx.pid, &(&1.tracker_backoff_rule_id == "tracker.rate_limited" and idle?(&1)))
    assert state.issue_routing_cache["A"].state == "Done"
    assert state.inbox_ack_pending == nil
    assert is_struct(state.inbox_last_drained_at, DateTime)
    assert Enum.map(TrackerEventInbox.pending_events(), & &1["event"]["entity_id"]) == ["RATE", "B"]
    refute_receive {:lookup, "B"}, 50
  end

  test "storage failure is visible in snapshot without a false empty depth", ctx do
    assert :ok = TrackerEventInbox.initialize(ctx.location)
    File.write!(ctx.location.state_path, "private-broken-payload")
    send(ctx.pid, :run_webhook_cycle)
    wait_state!(ctx.pid, &(&1.inbox_storage_error != nil and idle?(&1)))
    snapshot = Orchestrator.snapshot(ctx.pid, 5_000)
    assert snapshot.tracker_inbox.status == :error
    assert snapshot.tracker_inbox.depth == nil
    assert snapshot.tracker_inbox.last_storage_error.reason_code == :invalid_schema
    refute inspect(snapshot.tracker_inbox) =~ "private-broken-payload"
    refute_receive {:lookup, _}, 50
  end

  defp event(id), do: %TrackerEvent{provider: "linear", event_id: id, entity_type: "Issue", entity_id: id, issue_identifier: "ISSUE-#{id}", action: "update", raw: %{}}

  defp idle?(state) do
    inbox_settled =
      case state.tracker_inbox_batch do
        nil -> true
        %{head: %{phase: :backoff}} -> is_nil(state.inbox_ack_pending)
        %{head: %{phase: :blocked}} -> true
        %{head: nil} -> not is_nil(state.inbox_ack_pending) and not is_nil(state.inbox_storage_error)
        _ -> false
      end

    is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and not state.poll_check_in_progress and inbox_settled
  end

  defp wait_state!(pid, predicate), do: wait_state!(pid, predicate, System.monotonic_time(:millisecond) + 5_000)

  defp wait_state!(pid, predicate, deadline) do
    state = GenServer.call(pid, :state, 5_000)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "Inbox owner did not reach expected state"

      receive do
      after
        5 -> wait_state!(pid, predicate, deadline)
      end
    end
  end

  defp pause_scheduler! do
    if pid = Process.whereis(Orchestrator) do
      state = wait_default_idle!(pid, System.monotonic_time(:millisecond) + 5_000)
      assert state.running == %{}
      assert idle?(state)
      :ok = :sys.suspend(pid)
      on_exit(fn -> :ok = :sys.resume(pid) end)
    end
  end

  defp wait_default_idle!(pid, deadline) do
    state = :sys.get_state(pid, 5_000)

    if state.running == %{} and idle?(state) and state.tracker_poll_pending == [] do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "Default scheduler must be idle before inbox fixture"

      receive do
      after
        5 -> wait_default_idle!(pid, deadline)
      end
    end
  end
end
