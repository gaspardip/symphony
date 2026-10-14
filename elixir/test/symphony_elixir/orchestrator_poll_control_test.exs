defmodule SymphonyElixir.OrchestratorPollControlTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 30_000

  alias SymphonyElixir.{Config, LeaseManager, Orchestrator, RunLedger, Workflow, WorkflowStore, Workspace}
  alias SymphonyElixir.Linear.Issue

  defmodule HeldClient do
    def fetch_candidate_issues do
      fixture = fixture()
      {:ok, fixture.candidates}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(ids) do
      send(fixture().owner, {:poll_control_read, self(), ids})

      receive do
        {:answer, result} -> result
      after
        5_000 -> {:error, :fixture_barrier_timeout}
      end
    end

    def fetch_issue_by_identifier(identifier) do
      send(fixture().owner, {:poll_control_lookup, identifier})
      {:ok, nil}
    end

    def fetch_issue_by_id(id), do: {:error, {:unexpected_individual_read, id}}

    def graphql(query, variables) do
      kind =
        cond do
          String.contains?(query, "SymphonyCreateComment") -> :comment
          String.contains?(query, "SymphonyUpdateIssueState") -> :state
          String.contains?(query, "SymphonyResolveStateId") -> :state_lookup
          true -> :unexpected
        end

      if kind == :unexpected do
        {:error, :unexpected_graphql_operation}
      else
        if kind != :state_lookup, do: send(fixture().owner, {:poll_control_write, kind, Map.fetch!(variables, :issueId)})

        {:ok,
         %{
           "data" => %{
             "commentCreate" => %{"success" => true},
             "issueUpdate" => %{"success" => true},
             "issue" => %{"team" => %{"id" => "poll-control-team", "states" => %{"nodes" => [%{"id" => "poll-control-state"}]}}}
           }
         }}
      end
    end

    defp fixture, do: Application.fetch_env!(:symphony_elixir, :poll_control_fixture)
  end

  setup do
    pause_idle_scheduler!()
    root = Path.join(System.tmp_dir!(), "poll-control-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    root = File.cd!(root, &File.cwd!/0)
    previous = Enum.map([:workflow_file_path, :log_file, :linear_client_module, :poll_control_fixture], &{&1, Application.fetch_env(:symphony_elixir, &1)})

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
    Application.put_env(:symphony_elixir, :poll_control_fixture, %{owner: self(), candidates: [issue("A"), issue("B")]})
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "logs/symphony.log"))
    workflow = Path.join(root, "WORKFLOW.md")

    config = %{
      tracker: %{kind: "linear", api_key: "synthetic-local-token", project_slug: "poll-control", required_labels: [], active_states: ["Todo", "In Progress", "Merging"], terminal_states: ["Done"]},
      polling: %{interval_ms: 60_000, discovery_interval_ms: 60_000, healing_interval_ms: 60_000},
      workspace: %{root: Path.join(root, "workspaces")},
      runner: %{install_root: Path.join(root, "runner"), self_host_project: false},
      manual: %{enabled: false, store_root: Path.join(root, "manual")},
      company: %{policy_pack: "private_autopilot", author_profile_path: Path.join(root, "author.json"), credential_registry_path: Path.join(root, "credentials.json")},
      agent: %{max_concurrent_agents: 1, stall_timeout_ms: 0, codex: %{command: "/usr/bin/false", runtime_profile: %{inherit_env: false}}},
      policy: %{publish_required: false, automerge_on_green: false, token_budget: %{per_issue_total: 200_000}}
    }

    write_config!(workflow, config)
    assert :ok = Config.validate!()
    {:ok, root: root, workflow: workflow, config: config}
  end

  for action <- [:stop, :pause] do
    @tag control_action: action
    test "#{action} revokes a real poll admission without consuming its physical reader slot", context do
      {owner, reader, operation} = held_poll!()
      child_monitor = Process.monitor(reader)
      guardian_monitor = Process.monitor(operation.pid)

      assert %{ok: true} = control(owner, context.control_action, issue("A").identifier)
      assert_writes!(context.control_action, "A")
      state = :sys.get_state(owner, 5_000)
      assert state.admission_read == operation
      assert Process.alive?(reader)
      assert Process.alive?(operation.pid)
      assert MapSet.member?(state.admission_batch.invalidated, issue("A").identifier)
      refute_received {:poll_control_lookup, _}
      refute_receive {:poll_control_read, _, ["B"]}, 50
      assert_no_dispatch!(state, ["A", "B"])
      assert count_event("A", "operator.action") == 1

      send(reader, {:answer, {:ok, [issue("A")]}})
      assert_receive {:DOWN, ^child_monitor, :process, ^reader, :normal}, 5_000
      assert_receive {:DOWN, ^guardian_monitor, :process, guardian, :normal}, 5_000
      assert guardian == operation.pid
      assert_receive {:poll_control_read, reader_b, ["B"]}, 5_000
      next = :sys.get_state(owner, 5_000)
      assert next.admission_read.ref != operation.ref
      assert next.admission_read.issue.id == "B"
      watch_reader_cleanup!(next.admission_read.pid)
      assert_no_dispatch!(next, ["A", "B"])
      refute_received {:poll_control_write, _, _}
      assert count_event("A", "operator.action") == 1

      send(reader_b, {:answer, {:ok, []}})
      assert_no_dispatch!(idle!(owner), ["A", "B"])
    end
  end

  test "a late 429 still throttles B after the genuine poll issue was stopped" do
    {owner, reader, operation} = held_poll!()
    assert %{ok: true} = Orchestrator.stop_issue(owner, issue("A").identifier)
    assert_writes!(:stop, "A")
    assert :sys.get_state(owner, 5_000).admission_read == operation
    assert Process.alive?(reader)

    send(reader, {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 60_000}}}})
    state = idle!(owner)
    assert state.tracker_backoff_until_ms > System.monotonic_time(:millisecond)
    assert match?({:admission_read_failed, {:linear_rate_limited, _}}, state.candidate_fetch_error)
    assert_no_dispatch!(state, ["A", "B"])
    refute_receive {:poll_control_read, _, ["B"]}, 50
    refute_received {:poll_control_lookup, _}
    refute_received {:poll_control_write, _, _}
    assert count_event("A", "operator.action") == 1
  end

  for boundary <- [:identifier_mismatch, :unrelated_issue, :fingerprint_drift] do
    @tag control_boundary: boundary
    test "#{boundary} cannot borrow the pending poll identity for a control", context do
      {owner, reader, operation} = held_poll!()

      identifier =
        case context.control_boundary do
          :identifier_mismatch -> "ISSUE-NOT-A"
          :unrelated_issue -> issue("B").identifier
          :fingerprint_drift -> issue("A").identifier
        end

      if context.control_boundary == :fingerprint_drift do
        changed = put_in(context.config, [:tracker, :project_slug], "other-poll-control")
        write_config!(context.workflow, changed)
        assert Config.tracker_read_context().fingerprint != operation.fingerprint
      end

      task = Task.async(fn -> Orchestrator.stop_issue(owner, identifier) end)
      state = wait_state!(owner, &match?(%{operation: %{phase: :resolve}, read_ready: true}, &1.control_reservation))
      assert state.control_reservation.operation.identifier == identifier
      assert state.admission_read == operation
      assert Process.alive?(reader)
      assert_no_dispatch!(state, ["A", "B"])
      refute_received {:poll_control_lookup, _}
      refute_received {:poll_control_write, _, _}
      assert count_event("A", "operator.action") == 0
      assert count_event("B", "operator.action") == 0

      # Release the original physical reader; the queued public control must
      # now consult its own identifier and report that real lookup's absence.
      send(reader, {:answer, {:ok, []}})
      assert_receive {:poll_control_lookup, ^identifier}, 5_000
      assert %{ok: false, error: ":issue_not_found"} = Task.await(task, 5_000)
      refute_received {:poll_control_write, _, _}
      assert count_event("A", "operator.action") == 0
      assert count_event("B", "operator.action") == 0
      assert_no_dispatch!(:sys.get_state(owner, 5_000), ["A", "B"])

      if context.control_boundary == :identifier_mismatch do
        assert_receive {:poll_control_read, reader_b, ["B"]}, 5_000
        next = :sys.get_state(owner, 5_000)
        watch_reader_cleanup!(next.admission_read.pid)
        send(reader_b, {:answer, {:ok, []}})
      end

      assert_no_dispatch!(idle!(owner), ["A", "B"])
    end
  end

  test "an already invalidated poll issue cannot authorize a second control" do
    {owner, reader, operation} = held_poll!()
    assert %{ok: true} = Orchestrator.stop_issue(owner, issue("A").identifier)
    assert_writes!(:stop, "A")
    assert count_event("A", "operator.action") == 1

    task = Task.async(fn -> Orchestrator.pause_issue(owner, issue("A").identifier) end)
    state = wait_state!(owner, &match?(%{operation: %{phase: :resolve}, read_ready: true}, &1.control_reservation))
    assert state.admission_read == operation
    assert Process.alive?(reader)
    refute_received {:poll_control_lookup, _}
    refute_received {:poll_control_write, _, _}

    send(reader, {:answer, {:ok, []}})
    identifier = issue("A").identifier
    assert_receive {:poll_control_lookup, ^identifier}, 5_000
    assert %{ok: false, error: ":issue_not_found"} = Task.await(task, 5_000)
    assert count_event("A", "operator.action") == 1
    refute_received {:poll_control_write, _, _}
    assert_receive {:poll_control_read, reader_b, ["B"]}, 5_000
    state = :sys.get_state(owner, 5_000)
    watch_reader_cleanup!(state.admission_read.pid)
    send(reader_b, {:answer, {:ok, []}})
    assert_no_dispatch!(idle!(owner), ["A", "B"])
  end

  defp control(owner, :stop, identifier), do: Orchestrator.stop_issue(owner, identifier)
  defp control(owner, :pause, identifier), do: Orchestrator.pause_issue(owner, identifier)

  defp assert_writes!(action, id) do
    assert_receive {:poll_control_write, :state, ^id}, 5_000
    if action == :stop, do: assert_receive({:poll_control_write, :comment, ^id}, 5_000)
    refute_received {:poll_control_write, _, _}
  end

  defp assert_no_dispatch!(state, ids) do
    assert state.running == %{}

    for id <- ids do
      assert {:error, :missing} = LeaseManager.read(id)
      refute File.exists?(Workspace.path_for_issue(issue(id)))
      assert count_event(id, "dispatch.started") == 0
    end
  end

  defp count_event(id, event) do
    {:ok, path} = RunLedger.ledger_file_path_checked()

    rows =
      case File.read(path) do
        {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
        {:error, :enoent} -> []
      end

    Enum.count(rows, &(&1["issue_id"] == id and &1["event_type"] == event))
  end

  defp held_poll! do
    name = Module.concat(__MODULE__, "Owner#{System.unique_integer([:positive])}")
    owner = start_supervised!({Orchestrator, name: name})
    assert_receive {:poll_control_read, reader, ["A"]}, 5_000
    operation = :sys.get_state(owner, 5_000).admission_read
    assert operation.purpose == :poll
    assert operation.issue == issue("A")
    assert operation.fingerprint == Config.tracker_read_context().fingerprint
    watch_reader_cleanup!(operation.pid)
    {owner, reader, operation}
  end

  defp watch_reader_cleanup!(guardian) do
    on_exit(fn ->
      monitor = Process.monitor(guardian)
      assert_receive {:DOWN, ^monitor, :process, ^guardian, _reason}, 5_000
    end)
  end

  defp issue(id), do: %Issue{id: id, identifier: "ISSUE-" <> id, source: :tracker, title: "Poll control", description: "Local fixture", state: "Todo", labels: [], assigned_to_worker: true}

  defp write_config!(path, config) do
    File.write!(path, "---\n" <> Jason.encode!(config) <> "\n---\nPoll control fixture.\n")
    :ok = Workflow.set_workflow_file_path(path)
    :ok = WorkflowStore.force_reload()
  end

  defp idle?(state),
    do: is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and state.tracker_poll_pending == [] and not state.poll_check_in_progress and not state.github_webhook_check_in_progress

  defp idle!(owner), do: wait_state!(owner, &(idle?(&1) and &1.first_poll_completed and is_nil(&1.admission_read) and is_nil(&1.admission_batch)))
  defp wait_state!(owner, predicate), do: wait_state!(owner, predicate, System.monotonic_time(:millisecond) + 5_000)

  defp wait_state!(owner, predicate, deadline) do
    state = :sys.get_state(owner, 5_000)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "Expected poll control state was not observed"

      receive do
      after
        5 -> wait_state!(owner, predicate, deadline)
      end
    end
  end

  defp pause_idle_scheduler! do
    case Process.whereis(Orchestrator) do
      nil ->
        :ok

      owner ->
        supervisor = Process.whereis(SymphonyElixir.Supervisor)
        assert is_pid(supervisor)
        assert Enum.any?(Supervisor.which_children(supervisor), fn {id, child, _, _} -> id == Orchestrator and child == owner end)
        wait_state!(owner, &(idle?(&1) and &1.running == %{}))
        :ok = :sys.suspend(owner)
        on_exit(fn -> :ok = :sys.resume(owner) end)
    end
  end
end
