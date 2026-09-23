defmodule SymphonyElixir.SnapshotCorruptionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeliveryEngine
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.RunStateStore

  setup do
    root = Path.join(System.tmp_dir!(), "snapshot-corruption-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    marker = Path.join(root, "provider-started")
    script = Path.join(root, "fake-provider")
    File.write!(script, "#!/bin/sh\nprintf invoked > \"#{marker}\"\nexit 77\n")
    File.chmod!(script, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      codex_command: script
    )

    issue = %Issue{id: "snapshot-issue", identifier: "SNAPSHOT-ISSUE", title: "Resume work", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    path = RunStateStore.state_path(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, issue: issue, workspace: workspace, path: path, marker: marker}
  end

  test "a missing snapshot still starts at checkout and can be persisted", %{issue: issue, workspace: workspace} do
    assert {:error, :missing} = RunStateStore.load(workspace)
    assert :ok = RunStateStore.ensure_readable(workspace)
    assert %{stage: "checkout"} = RunStateStore.load_or_default(workspace, issue)
    assert {:ok, %{stage: "implement"}} = RunStateStore.transition(workspace, "implement")
  end

  test "unreadable snapshots produce a blocked view and cannot be overwritten", %{
    issue: issue,
    workspace: workspace,
    path: path
  } do
    for payload <- ["{invalid-json", "[]", "null", "123", "\"text\""] do
      File.write!(path, payload)
      assert {:error, _reason} = RunStateStore.load(workspace)

      assert %{stage: "blocked", last_rule_id: "runtime.snapshot_unreadable", stop_reason: reason} =
               view =
               RunStateStore.load_or_default(workspace, issue)

      assert reason.summary =~ "cannot be read"
      assert reason.human_action =~ "preserved"
      assert {:error, {:run_state_unreadable, _reason}} = RunStateStore.ensure_readable(workspace)
      assert {:error, {:run_state_unreadable, _reason}} = RunStateStore.transition(workspace, "checkout")

      assert {:error, {:run_state_unreadable, _reason}} =
               RunStateStore.update(workspace, fn state ->
                 send(self(), :update_called)
                 Map.put(state, :stage, "publish")
               end)

      refute_received :update_called
      assert {:error, {:run_state_unreadable, _reason}} = RunStateStore.sync_lease(workspace, issue, %{owner: "runner"})
      assert {:error, {:run_state_unreadable, _reason}} = RunStateStore.clear_lease(workspace)
      assert {:error, {:run_state_unreadable, _reason}} = RunStateStore.save(workspace, view)
      assert File.read!(path) == payload
    end
  end

  test "corrupt JSON diagnostics do not copy snapshot payload into the blocked view", %{
    issue: issue,
    workspace: workspace,
    path: path
  } do
    File.write!(path, "{invalid-json SYNTHETIC_PAYLOAD_DO_NOT_LOG")
    view = RunStateStore.load_or_default(workspace, issue)
    refute inspect(view) =~ "SYNTHETIC_PAYLOAD_DO_NOT_LOG"
    assert {:error, {:run_state_unreadable, {:invalid_json, _position}}} = RunStateStore.ensure_readable(workspace)
  end

  test "corruption blocks active and passive worker dispatch without changing the snapshot", %{
    issue: issue,
    workspace: workspace,
    path: path
  } do
    payload = "{invalid-json"
    File.write!(path, payload)
    state = %State{max_concurrent_agents: 1}

    dispatch = fn dispatch_state, _issue, _attempt ->
      send(self(), :worker_dispatched)
      dispatch_state
    end

    assert %State{running: running, candidate_fetch_error: {:run_state_unreadable, _reason}} =
             Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil,
               active_dispatch_fun: dispatch,
               passive_dispatch_fun: dispatch
             )

    assert running == %{}
    refute_received :worker_dispatched
    assert Orchestrator.normalize_dispatch_stage_for_test(issue) == "blocked"
    assert RunStateStore.load_or_default(workspace, issue).stage == "blocked"
    assert File.read!(path) == payload
  end

  test "delivery stops before provider bootstrap or publication on a corrupt snapshot", %{
    issue: issue,
    workspace: workspace,
    path: path,
    marker: marker
  } do
    payload = "{invalid-json"
    File.write!(path, payload)

    assert {:stop, {:run_state_unreadable, _reason}} = DeliveryEngine.run(workspace, issue, self())
    refute File.exists?(marker)
    assert File.read!(path) == payload
  end

  test "restoring a valid snapshot re-enables updates and retains its persisted stage", %{
    issue: issue,
    workspace: workspace,
    path: path
  } do
    valid = Jason.encode!(%{issue_id: issue.id, issue_identifier: issue.identifier, stage: "implement", implementation_turns: 2})
    File.write!(path, "{invalid-json")
    assert {:error, {:run_state_unreadable, _reason}} = RunStateStore.ensure_readable(workspace)
    File.write!(path, valid)

    assert :ok = RunStateStore.ensure_readable(workspace)
    assert %{stage: "implement", implementation_turns: 2} = RunStateStore.load_or_default(workspace, issue)

    assert {:ok, %{stage: "implement", implementation_turns: 3}} =
             RunStateStore.update(workspace, &Map.put(&1, :implementation_turns, 3))
  end

  test "corrupt staged bootstrap state cannot become a new checkout snapshot", %{
    root: root,
    issue: issue,
    workspace: workspace,
    path: path
  } do
    staged = Path.join(root, ".#{issue.identifier}.bootstrap-pb09")
    File.mkdir!(staged)
    staged_path = Path.join(staged, "run_state.json")
    File.write!(staged_path, "{invalid-json")

    assert %{stage: "blocked"} = RunStateStore.load_or_default(workspace, issue)
    assert {:error, {:run_state_unreadable, _reason}} = RunStateStore.transition(workspace, "checkout")
    refute File.exists?(path)
    assert File.read!(staged_path) == "{invalid-json"
  end
end
