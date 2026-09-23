defmodule SymphonyElixir.WorkflowDispatchGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State

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
