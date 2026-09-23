defmodule SymphonyElixir.TerminalLeaseReleaseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LeaseManager, RunLedger, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "terminal-lease-release-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner-install"),
      max_concurrent_agents: 0
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    pid = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, :Scheduler)})
    on_exit(fn -> File.rm_rf(root) end)
    %{pid: pid}
  end

  for stage <- ["blocked", "done"] do
    test "normal worker exit releases the persisted lease for #{stage} without continuation", %{pid: pid} do
      %{issue: issue, workspace: workspace, worker: worker} = running_worker(pid, unquote(stage))
      state = finish_worker(pid, worker, issue.id)

      assert state.running == %{}
      assert state.claimed == MapSet.new()
      assert state.retry_attempts == %{}
      assert Map.has_key?(state.completed, issue.id)
      assert {:error, :missing} = LeaseManager.read(issue.id)
      assert {:ok, %{lease_owner: nil, lease_status: nil}} = RunStateStore.load(workspace)

      assert Enum.count(RunLedger.recent_entries(), fn entry ->
               entry["event"] == "lease.released" and entry["issue_id"] == issue.id
             end) == 1
    end
  end

  test "normal worker exit retains ownership when an active continuation is queued", %{pid: pid} do
    %{issue: issue, worker: worker, owner: owner} = running_worker(pid, "implement")
    state = finish_worker(pid, worker, issue.id)

    assert state.running == %{}
    assert MapSet.member?(state.claimed, issue.id)
    assert %{attempt: 1, delay_type: :continuation} = state.retry_attempts[issue.id]
    assert {:ok, %{"owner" => ^owner}} = LeaseManager.read(issue.id)
    refute Enum.any?(RunLedger.recent_entries(), &(&1["event"] == "lease.released" and &1["issue_id"] == issue.id))
  end

  test "terminal worker exit preserves ownership and surfaces a failed lease release", %{pid: pid} do
    %{issue: issue, workspace: workspace, worker: worker, owner: owner} = running_worker(pid, "blocked")
    lock_path = LeaseManager.lease_path(issue.id) <> ".lock"
    File.mkdir!(lock_path)

    capture_log(fn ->
      state = finish_worker(pid, worker, issue.id)
      assert state.running == %{}
      assert state.retry_attempts == %{}
      assert MapSet.member?(state.claimed, issue.id)
      assert state.candidate_fetch_error == {:lease_release_failed, issue.id, {:lease_lock_timeout, lock_path}}
    end)

    assert {:ok, %{"owner" => ^owner}} = LeaseManager.read(issue.id)
    assert {:ok, %{lease_owner: ^owner, lease_status: "held"}} = RunStateStore.load(workspace)
    refute Enum.any?(RunLedger.recent_entries(), &(&1["event"] == "lease.released" and &1["issue_id"] == issue.id))
  end

  defp running_worker(pid, stage) do
    issue = %Issue{id: "terminal-lease-#{stage}", identifier: "TERMINAL-#{String.upcase(stage)}", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    owner = :sys.get_state(pid).lease_owner
    assert :ok = LeaseManager.acquire(issue.id, issue.identifier, owner)
    assert {:ok, lease} = LeaseManager.read(issue.id)
    assert {:ok, _} = RunStateStore.transition(workspace, stage, %{issue_id: issue.id, issue_identifier: issue.identifier})
    assert {:ok, _} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(lease))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    worker =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> send(worker, :finish) end)

    :sys.replace_state(pid, fn state ->
      entry = %{
        pid: worker,
        ref: Process.monitor(worker),
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now()
      }

      %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), retry_attempts: %{}}
    end)

    %{issue: issue, workspace: workspace, worker: worker, owner: owner}
  end

  defp finish_worker(pid, worker, issue_id) do
    ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    await_completion(pid, issue_id, 150)
  end

  defp await_completion(_pid, _issue_id, 0), do: flunk("Orchestrator did not handle the real worker DOWN")

  defp await_completion(pid, issue_id, remaining) do
    state = :sys.get_state(pid)

    if Map.has_key?(state.completed, issue_id) do
      state
    else
      Process.sleep(10)
      await_completion(pid, issue_id, remaining - 1)
    end
  end
end
