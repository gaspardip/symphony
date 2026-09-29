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
    await_initial_poll(pid, 150)
    %{pid: pid}
  end

  for stage <- ["blocked", "done"] do
    test "normal worker exit releases the persisted lease for #{stage} without continuation", %{pid: pid} do
      %{issue: issue, workspace: workspace, worker: worker} = running_worker(pid, unquote(stage))
      before = File.read!(RunStateStore.state_path(workspace))
      state = finish_worker(pid, worker, issue.id)

      assert state.running == %{}
      assert state.claimed == MapSet.new()
      assert state.retry_attempts == %{}
      assert Map.has_key?(state.completed, issue.id)
      assert {:error, :missing} = LeaseManager.read(issue.id)
      assert File.read!(RunStateStore.state_path(workspace)) == before
      assert {:ok, %{lease_version: 2}} = RunStateStore.load(workspace)

      assert Enum.count(RunLedger.recent_entries(), fn entry ->
               entry["event"] == "lease.released" and entry["issue_id"] == issue.id
             end) == 1
    end
  end

  test "normal worker exit retains ownership when an active continuation is queued", %{pid: pid} do
    %{issue: issue, worker: worker, owner: owner} = running_worker(pid, "implement")
    original = :sys.get_state(pid).lease_claims[issue.id]
    state = finish_worker(pid, worker, issue.id)

    assert state.running == %{}
    assert MapSet.member?(state.claimed, issue.id)
    assert %{attempt: 1, delay_type: :continuation} = state.retry_attempts[issue.id]
    assert state.lease_claims[issue.id].holder == :retry
    assert state.lease_claims[issue.id].token == original.token
    refute state.lease_claims[issue.id].custody_ref == original.custody_ref
    assert state.retry_attempts[issue.id].custody_ref == state.lease_claims[issue.id].custody_ref
    assert state.retry_attempts[issue.id].lease_token == original.token
    assert {:ok, %{"owner" => ^owner}} = LeaseManager.read(issue.id)
    refute Enum.any?(RunLedger.recent_entries(), &(&1["event"] == "lease.released" and &1["issue_id"] == issue.id))
  end

  test "abnormal worker DOWN transfers the same lease token to the next retry", %{pid: pid} do
    %{issue: issue, worker: worker} = running_worker(pid, "implement")
    original = :sys.get_state(pid).lease_claims[issue.id]
    ref = Process.monitor(worker)
    Process.exit(worker, :killed_fixture)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed_fixture}
    state = await_retry(pid, issue.id, 150)
    assert state.running == %{}
    assert %{attempt: 1, error: "agent exited: :killed_fixture"} = state.retry_attempts[issue.id]
    assert state.lease_claims[issue.id].holder == :retry
    assert state.lease_claims[issue.id].token == original.token
    refute state.lease_claims[issue.id].custody_ref == original.custody_ref
    assert state.retry_attempts[issue.id].custody_ref == state.lease_claims[issue.id].custody_ref
    assert state.retry_attempts[issue.id].lease_token == original.token
    assert {:ok, lease} = LeaseManager.read_at(original.token.storage)
    assert lease["lease_generation"] == original.token.lease_generation
  end

  test "budget retry after a real DOWN persists context only in the captured workspace", %{pid: pid} do
    %{issue: issue, workspace: workspace, worker: worker} = running_worker(pid, "implement")
    original = :sys.get_state(pid).lease_claims[issue.id]

    :sys.replace_state(pid, fn state ->
      update_in(
        state.running[issue.id],
        &Map.merge(&1, %{
          workspace_path: workspace,
          dispatch_stage: "implement",
          turn_count: 1,
          agent_input_tokens: 130_000,
          agent_output_tokens: 0,
          agent_total_tokens: 130_000,
          turn_started_input_tokens: 0,
          resume_context: %{budget_mode: "review_fix", budget_scope_kind: "review_claim_batch", budget_scope_ids: ["comment:1", "comment:2"]}
        })
      )
    end)

    other_root = Path.join(System.tmp_dir!(), "retry-budget-other-root-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(other_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: other_root, max_concurrent_agents: 0)
    other_workspace = Workspace.path_for_issue(issue)
    assert {:ok, _} = RunStateStore.transition(other_workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier, resume_context: %{target_paths: ["untouched.ex"]}})
    other_bytes = File.read!(RunStateStore.state_path(other_workspace))
    before_ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^before_ref, :process, ^worker, :normal}
    state = await_retry(pid, issue.id, 150)
    assert %{attempt: 1, budget_retry: true, budget_resume_context: context} = state.retry_attempts[issue.id]
    assert is_map(context)
    assert context.budget_retry_count == 1
    assert state.lease_claims[issue.id].token == original.token
    assert state.lease_claims[issue.id].holder == :retry
    assert {:ok, persisted} = RunStateStore.load(workspace)
    assert persisted.resume_context.budget_retry_count == context.budget_retry_count
    assert File.read!(RunStateStore.state_path(other_workspace)) == other_bytes
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

  test "borrowed follow-up preserves a running worker custody through refresh and DOWN", %{pid: pid} do
    %{issue: issue, workspace: workspace, worker: worker} = running_worker(pid, "blocked")
    before = :sys.get_state(pid)
    claim = before.lease_claims[issue.id]
    assert {:ok, run_state} = RunStateStore.load(workspace)

    :sys.replace_state(pid, fn state ->
      assert {:ok, borrowed, _attrs, false} = Orchestrator.ensure_review_follow_up_lease_for_test(state, run_state)
      assert borrowed.lease_claims[issue.id].custody_ref == claim.custody_ref
      assert borrowed.lease_claims[issue.id].holder == :running
      assert borrowed.lease_claims[issue.id].token == claim.token
      Orchestrator.refresh_runtime_config(borrowed)
    end)

    assert Process.alive?(worker)
    assert :sys.get_state(pid).running[issue.id].custody_ref == claim.custody_ref
    finished = finish_worker(pid, worker, issue.id)
    assert finished.lease_claims == %{}
    assert finished.retry_attempts == %{}
    assert {:error, :missing} = LeaseManager.read_at(claim.token.storage)
  end

  test "terminal running reconciliation preserves both captured v2 and new-root legacy workspaces", %{pid: pid} do
    %{issue: issue, workspace: workspace} = running_worker(pid, "implement")
    before = :sys.get_state(pid)
    claim = before.lease_claims[issue.id]
    old_snapshot = File.read!(RunStateStore.state_path(workspace))
    other_root = Path.join(System.tmp_dir!(), "terminal-new-root-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(other_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(other_root, "workspaces"), max_concurrent_agents: 0)
    Application.put_env(:symphony_elixir, :log_file, Path.join(other_root, "logs/symphony.log"))
    other_workspace = Workspace.path_for_issue(issue)
    assert {:ok, _} = RunStateStore.transition(other_workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    header = Path.join(other_workspace, "AGENTS.md")
    File.write!(header, "successor legacy header")
    assert {:ok, location} = LeaseManager.capture_storage(issue.id)
    File.mkdir_p!(Path.dirname(location.lease_path))
    legacy = Map.delete(claim.lease, "lease_generation") |> Map.put("lease_version", 1)
    File.write!(location.lease_path, Jason.encode!(legacy))
    other_snapshot = File.read!(RunStateStore.state_path(other_workspace))
    other_lease = File.read!(location.lease_path)
    other_ledger = File.read(location.ledger_path)

    :sys.replace_state(pid, fn state ->
      Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Done"}], state)
    end)

    assert :sys.get_state(pid).running == %{}
    assert {:error, :missing} = LeaseManager.read_at(claim.token.storage)
    assert File.read!(RunStateStore.state_path(workspace)) == old_snapshot
    assert File.read!(RunStateStore.state_path(other_workspace)) == other_snapshot
    assert File.read!(location.lease_path) == other_lease
    assert File.read(location.ledger_path) == other_ledger
    assert File.read!(claim.token.storage.ledger_path) =~ "lease.released"
    assert File.read!(header) == "successor legacy header"
  end

  defp await_initial_poll(_pid, 0), do: flunk("Orchestrator did not finish its initial poll before fixture injection")

  defp await_initial_poll(pid, remaining) do
    state = :sys.get_state(pid)

    if state.first_poll_completed and is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and
         state.tracker_poll_pending == [] and not state.poll_check_in_progress and not state.github_webhook_check_in_progress and
         is_nil(state.admission_read) and is_nil(state.admission_batch) do
      assert state.running == %{}
      :ok
    else
      Process.sleep(10)
      await_initial_poll(pid, remaining - 1)
    end
  end

  defp running_worker(pid, stage) do
    issue = %Issue{id: "terminal-lease-#{stage}", identifier: "TERMINAL-#{String.upcase(stage)}", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    owner = :sys.get_state(pid).lease_owner
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, owner)
    lease = acquired.lease
    custody_ref = make_ref()
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
        custody_ref: custody_ref,
        lease_token: acquired.token,
        started_at: DateTime.utc_now()
      }

      claim = %{
        token: acquired.token,
        lease: lease,
        custody_ref: custody_ref,
        holder: :running,
        workspace: workspace,
        issue: issue,
        started_at_ms: System.monotonic_time(:millisecond),
        deadline: :not_pending,
        promotion_ref: nil,
        timer: nil
      }

      %{state | running: %{issue.id => entry}, lease_claims: %{issue.id => claim}, claimed: MapSet.new([issue.id]), retry_attempts: %{}}
    end)

    %{issue: issue, workspace: workspace, worker: worker, owner: owner}
  end

  defp finish_worker(pid, worker, issue_id) do
    ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    await_completion(pid, issue_id, 150)
  end

  defp await_retry(_pid, _id, 0), do: flunk("Orchestrator did not schedule after the real DOWN")

  defp await_retry(pid, id, remaining) do
    state = :sys.get_state(pid)

    if Map.has_key?(state.retry_attempts, id) do
      state
    else
      Process.sleep(10)
      await_retry(pid, id, remaining - 1)
    end
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
