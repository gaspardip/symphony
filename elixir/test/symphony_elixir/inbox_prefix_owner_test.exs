defmodule SymphonyElixir.InboxPrefixOwnerTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{Config, GitHubEvent, GitHubEventInbox, Orchestrator, TrackerEvent, TrackerEventInbox, Workflow, WorkflowStore}
  alias SymphonyElixir.Linear.Issue

  defmodule Client do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}

    def fetch_issue_by_id(id) do
      send(Application.fetch_env!(:symphony_elixir, :prefix_owner_fixture).owner, {:prefix_lookup, id})
      {:ok, %Issue{id: id, identifier: "ISSUE-#{id}", state: "Done", source: :tracker, title: "Prefix fixture", labels: [], assigned_to_worker: true}}
    end
  end

  defmodule Driver do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_info({kind, _cursor} = message, state) when kind in [:tracker_inbox_ack, :github_inbox_ack] do
      send(Application.fetch_env!(:symphony_elixir, :prefix_owner_fixture).owner, {:prefix_ack, message})
      {:noreply, state}
    end

    def handle_info({:deliver_confirmed_callback, message}, state), do: Orchestrator.handle_info(message, state)
    def handle_info(message, state), do: Orchestrator.handle_info(message, state)
    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}
    def handle_call(message, from, state), do: Orchestrator.handle_call(message, from, state)
  end

  setup do
    pause_scheduler!()
    root = Path.join(System.tmp_dir!(), "prefix-owner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Enum.map([:log_file, :workflow_file_path, :linear_client_module, :prefix_owner_fixture], &{&1, Application.fetch_env(:symphony_elixir, &1)})

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
    fixture = %{owner: self(), location: location}
    Application.put_env(:symphony_elixir, :prefix_owner_fixture, fixture)
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

  test "GitHub retains its original two-row horizon while an append waits behind a held ACK", ctx do
    assert {:ok, %{accepted: 2}} = GitHubEventInbox.enqueue([github_event("A"), github_event("B")])
    send(ctx.pid, :run_github_webhook_cycle)
    assert_receive {:prefix_ack, {:github_inbox_ack, cursor_a} = ack_a}, 5_000
    original = GenServer.call(ctx.pid, :state).github_inbox_batch
    assert length(original.rows) == 2
    assert original.head.event.event_id == "A"
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([github_event("C")])
    send(ctx.pid, {:deliver_confirmed_callback, ack_a})
    assert_receive {:prefix_ack, {:github_inbox_ack, cursor_b} = ack_b}, 5_000
    next = GenServer.call(ctx.pid, :state).github_inbox_batch
    assert next.ref == original.ref
    assert length(next.rows) == 1
    assert next.head.event.event_id == "B"
    assert cursor_b.start_offset == cursor_a.end_offset
    assert next.end_offset == original.end_offset
    assert Enum.map(GitHubEventInbox.pending_events(), & &1["event"]["event_id"]) == ["B", "C"]
    send(ctx.pid, {:deliver_confirmed_callback, ack_b})
    assert_receive {:prefix_ack, {:github_inbox_ack, cursor_c} = ack_c}, 5_000
    tail = GenServer.call(ctx.pid, :state).github_inbox_batch
    assert tail.ref != original.ref
    assert length(tail.rows) == 1
    assert tail.head.event.event_id == "C"
    assert cursor_c.start_offset == cursor_b.end_offset
    send(ctx.pid, {:deliver_confirmed_callback, ack_c})
    settled = wait_state!(ctx.pid, &(is_nil(&1.github_inbox_batch) and is_nil(&1.github_inbox_ack_pending)))
    assert settled.github_last_assignment.event_id == "C"
    assert GitHubEventInbox.pending_events() == []
    refute_receive {:prefix_ack, _}, 50
  end

  test "GitHub reset after completion preserves the obsolete pending ACK and the untouched replacement generation", ctx do
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([github_event("A")])
    send(ctx.pid, :run_github_webhook_cycle)
    assert_receive {:prefix_ack, {:github_inbox_ack, cursor} = ack}, 5_000
    before = GenServer.call(ctx.pid, :state)
    assert :ok = GitHubEventInbox.reset(cursor.location)
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([github_event("A")])
    send(ctx.pid, {:deliver_confirmed_callback, ack})
    failed = wait_state!(ctx.pid, &(&1.github_inbox_storage_error != nil))
    assert failed.github_inbox_ack_pending == cursor
    assert failed.github_inbox_storage_error.reason_code == :generation_changed
    assert failed.github_inbox_batch.head.ref == before.github_inbox_batch.head.ref
    assert failed.github_inbox_batch.rows == before.github_inbox_batch.rows
    assert failed.github_last_assignment == before.github_last_assignment
    assert [%{"event" => %{"event_id" => "A"}}] = GitHubEventInbox.pending_events()
    send(ctx.pid, :run_github_webhook_cycle)
    retried = wait_state!(ctx.pid, &(&1.github_inbox_storage_error != nil and &1.github_inbox_ack_pending == cursor))
    assert retried.github_inbox_batch.head.ref == before.github_inbox_batch.head.ref
    refute_receive {:prefix_ack, _}, 50
  end

  test "GitHub confirms the captured old location before capturing a newly configured log root", ctx do
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([github_event("A")])
    send(ctx.pid, :run_github_webhook_cycle)
    assert_receive {:prefix_ack, {:github_inbox_ack, old_cursor} = ack_a}, 5_000
    Application.put_env(:symphony_elixir, :log_file, Path.join(ctx.root, "new-log/symphony.log"))
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([github_event("B")])
    new_location = GitHubEventInbox.location()
    assert new_location != old_cursor.location
    send(ctx.pid, {:deliver_confirmed_callback, ack_a})
    assert_receive {:prefix_ack, {:github_inbox_ack, new_cursor} = ack_b}, 5_000
    assert new_cursor.location == new_location
    assert {:ok, %{rows: []}} = GitHubEventInbox.capture(old_cursor.location, %{max_rows: 100, max_bytes: 4 * 1024 * 1024})
    state = GenServer.call(ctx.pid, :state)
    assert state.github_last_assignment.event_id == "B"
    assert state.github_inbox_ack_pending == new_cursor
    send(ctx.pid, {:deliver_confirmed_callback, ack_b})
    wait_state!(ctx.pid, &(is_nil(&1.github_inbox_ack_pending) and is_nil(&1.github_inbox_batch)))
    assert GitHubEventInbox.pending_events() == []
    refute_receive {:prefix_ack, _}, 50
  end

  test "Tracker reset after application retires the old pending ACK without replaying its lookup", ctx do
    event = %TrackerEvent{provider: "linear", event_id: "A", entity_type: "Issue", entity_id: "A", issue_identifier: "ISSUE-A", action: "update", raw: %{}}
    assert {:ok, %{accepted: 1}} = TrackerEventInbox.enqueue([event])
    send(ctx.pid, :run_webhook_cycle)
    assert_receive {:prefix_lookup, "A"}, 5_000
    assert_receive {:prefix_ack, {:tracker_inbox_ack, cursor} = ack}, 5_000
    assert :ok = TrackerEventInbox.reset(cursor.location)
    assert {:ok, %{accepted: 1}} = TrackerEventInbox.enqueue([event])
    send(ctx.pid, {:deliver_confirmed_callback, ack})
    failed = wait_state!(ctx.pid, &(&1.inbox_storage_error != nil and is_nil(&1.inbox_ack_pending)))
    assert failed.inbox_storage_error.reason_code == :generation_changed
    assert is_nil(failed.tracker_inbox_batch)
    assert [%{"event" => %{"entity_id" => "A"}}] = TrackerEventInbox.pending_events()
    refute_receive {:prefix_lookup, _}, 50
    refute_receive {:prefix_ack, _}, 50
  end

  defp github_event(id), do: %GitHubEvent{provider: "github", event_id: id, event_name: "ping", action: "ping", received_runner_channel: "canary", received_runner_instance_id: "prefix:test", raw: %{}}

  defp idle?(state) do
    inbox_settled =
      case state.tracker_inbox_batch do
        nil -> true
        %{head: %{phase: :backoff}} -> is_nil(state.inbox_ack_pending)
        %{head: %{phase: :blocked}} -> true
        %{head: nil} -> not is_nil(state.inbox_ack_pending) and not is_nil(state.inbox_storage_error)
        _ -> false
      end

    is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and is_nil(state.admission_read) and
      is_nil(state.github_inbox_batch) and is_nil(state.github_inbox_ack_pending) and
      not state.poll_check_in_progress and inbox_settled
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
