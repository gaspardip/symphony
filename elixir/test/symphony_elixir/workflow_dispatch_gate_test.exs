defmodule SymphonyElixir.WorkflowDispatchGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.RunLedger

  test "scheduler poll rejects a file workspace root and records config_invalid before starting workers" do
    fixture_root = Path.join(System.tmp_dir!(), "workflow-scheduler-root-#{System.unique_integer([:positive])}")
    root = Path.join(fixture_root, "not-a-directory")
    File.mkdir_p!(fixture_root)
    File.write!(root, "not a directory")
    on_exit(fn -> File.rm_rf(fixture_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(fixture_root, "runner-install"),
      runner_channel: "stable",
      max_concurrent_agents: 1
    )

    issue = %Issue{
      id: "scheduler-invalid-root",
      identifier: "SCHEDULER-INVALID-ROOT",
      title: "Eligible scheduler work",
      state: "Todo",
      source: :tracker,
      labels: []
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, %State{max_concurrent_agents: 1})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    workers_before = Task.Supervisor.children(SymphonyElixir.TaskSupervisor)
    pid = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, :InvalidRootScheduler)})

    send(pid, :run_poll_cycle)
    state = :sys.get_state(pid)

    assert state.candidate_fetch_error == {:invalid_workspace_root, root, :enotdir}
    assert state.running == %{}
    assert state.claimed == MapSet.new()
    assert Task.Supervisor.children(SymphonyElixir.TaskSupervisor) == workers_before
    assert File.read!(root) == "not a directory"

    entries = RunLedger.recent_entries()

    assert Enum.any?(entries, fn entry ->
             entry["event"] == "config_invalid" and entry["actor_id"] == state.lease_owner and
               entry["metadata"]["dispatch_mode"] == "discovery" and
               entry["metadata"]["workflow_path"] == Workflow.workflow_file_path()
           end)

    refute Enum.any?(entries, &(&1["event"] == "dispatch.started" and &1["issue_id"] == issue.id))
  end

  test "a workspace root that is a file blocks dispatch and records config_invalid" do
    root = Path.join(System.tmp_dir!(), "workflow-root-file-#{System.unique_integer([:positive])}")
    File.write!(root, "not a directory")
    on_exit(fn -> File.rm!(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)

    issue = %Issue{id: "invalid-root", identifier: "INVALID-ROOT", title: "Eligible work", state: "Todo"}

    dispatch = fn state, _issue, _attempt ->
      send(self(), :unexpected_dispatch)
      state
    end

    assert {:error, {:invalid_workspace_root, ^root, :enotdir}} = Config.validate!()

    assert %State{running: running, candidate_fetch_error: {:invalid_workspace_root, ^root, :enotdir}} =
             Orchestrator.dispatch_runtime_issue_for_test(%State{max_concurrent_agents: 1}, issue, nil,
               active_dispatch_fun: dispatch,
               passive_dispatch_fun: dispatch
             )

    assert running == %{}
    refute_received :unexpected_dispatch
    assert File.read!(root) == "not a directory"
    assert Enum.any?(RunLedger.recent_entries(), &(&1["event"] == "config_invalid" and &1["issue_id"] == issue.id))
  end

  test "workspace validation permits an absent root and rejects an ancestor that is a file" do
    root = Path.join(System.tmp_dir!(), "workflow-root-ancestor-#{System.unique_integer([:positive])}")
    nested = Path.join(root, "workspaces")
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: nested)
    assert :ok = Config.validate!()
    refute File.exists?(root)
    File.write!(root, "blocked parent")
    assert {:error, {:invalid_workspace_root, ^nested, :enotdir}} = Config.validate!()
  end

  test "invalid hot reload blocks new dispatch while cached configuration remains available" do
    root = Path.join(System.tmp_dir!(), "workflow-dispatch-gate-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      max_concurrent_agents: 3,
      prompt: "Valid dispatch workflow"
    )

    on_exit(fn -> File.rm_rf(root) end)
    if is_nil(Process.whereis(WorkflowStore)), do: start_supervised!(WorkflowStore)
    assert :ok = WorkflowStore.force_reload()

    issue = %Issue{id: "workflow-gate", identifier: "WORKFLOW-GATE", title: "Eligible work", state: "Todo", labels: []}
    state = %State{max_concurrent_agents: 3}
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)

    dispatch = fn dispatch_state, dispatch_issue, _attempt ->
      send(self(), {:new_dispatch, dispatch_issue.id})
      dispatch_state
    end

    options = [active_dispatch_fun: dispatch, passive_dispatch_fun: dispatch]

    assert %State{} = Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil, options)
    assert_received {:new_dispatch, "workflow-gate"}

    valid_workflow = File.read!(Workflow.workflow_file_path())
    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken workflow\n")
    assert {:error, {:workflow_parse_error, _}} = WorkflowStore.force_reload()

    assert {:ok, %{prompt: "Valid dispatch workflow"}} = Workflow.current()
    assert Config.max_concurrent_agents() == 3
    assert :ok = Config.validate!()

    assert %State{running: running, candidate_fetch_error: {:workflow_parse_error, _}} =
             Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil, options)

    assert running == %{}
    refute_received {:new_dispatch, _issue_id}
    assert Enum.any?(RunLedger.recent_entries(), &(&1["event"] == "config_invalid" and &1["issue_id"] == issue.id))

    File.write!(Workflow.workflow_file_path(), valid_workflow)
    assert :ok = WorkflowStore.force_reload()
    assert %State{} = Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil, options)
    assert_received {:new_dispatch, "workflow-gate"}
  end

  test "dispatch validates changed fields even when the YAML remains parseable with the same file stamp" do
    root = Path.join(System.tmp_dir!(), "workflow-dispatch-fields-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)
    on_exit(fn -> File.rm_rf(root) end)
    if is_nil(Process.whereis(WorkflowStore)), do: start_supervised!(WorkflowStore)
    assert :ok = WorkflowStore.force_reload()
    assert Config.tracker_kind() == "memory"

    path = Workflow.workflow_file_path()
    valid = File.read!(path)
    stamp = File.stat!(path)
    invalid = String.replace(valid, "kind: \"memory\"", "kind: \"absurd\"")
    assert invalid != valid
    assert byte_size(invalid) == byte_size(valid)
    File.write!(path, invalid)
    File.touch!(path, stamp.mtime)
    assert File.stat!(path).mtime == stamp.mtime
    assert File.stat!(path).size == stamp.size

    issue = %Issue{id: "workflow-fields", identifier: "WORKFLOW-FIELDS", title: "Eligible work", state: "Todo", labels: []}
    state = %State{max_concurrent_agents: 1}

    dispatch = fn dispatch_state, _issue, _attempt ->
      send(self(), :field_validated_dispatch)
      dispatch_state
    end

    options = [active_dispatch_fun: dispatch, passive_dispatch_fun: dispatch]

    assert %State{running: running, candidate_fetch_error: {:unsupported_tracker_kind, "absurd"}} =
             Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil, options)

    assert running == %{}
    refute_received :field_validated_dispatch

    File.write!(path, valid)
    assert %State{} = Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil, options)
    assert_received :field_validated_dispatch
  end
end
