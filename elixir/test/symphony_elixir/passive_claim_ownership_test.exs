# Follow-up regressions against the frozen e220 C1 candidate; not installed yet.
defmodule SymphonyElixir.PassiveClaimOwnershipTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{GitManager, LeaseManager, RunStateStore}
  alias SymphonyElixir.Orchestrator.State

  setup do
    root = Path.join(System.tmp_dir!(), "passive-ownership-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner-install"),
      codex_command: "false",
      max_concurrent_agents: 1
    )

    issue = %Issue{
      id: "passive-owner",
      identifier: "PASSIVE-OWNER",
      title: "Passive ownership",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)

    for args <- [["init", "-q"], ["checkout", "-q", "-b", GitManager.issue_branch_name(issue)]] do
      assert {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, ".gitignore"), ".symphony/\n")

    assert {_, 0} =
             System.cmd("git", ["add", ".gitignore"], cd: workspace, stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-c",
                 "user.name=Local Probe",
                 "-c",
                 "user.email=probe@invalid",
                 "-c",
                 "core.hooksPath=/dev/null",
                 "commit",
                 "-q",
                 "-m",
                 "fixture"
               ],
               cd: workspace,
               stderr_to_stdout: true
             )

    assert {:ok, _} =
             RunStateStore.transition(workspace, "await_checks", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    File.write!(
      Path.join(bin, "gh"),
      "#!/bin/sh\nprintf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n"
    )

    File.chmod!(Path.join(bin, "gh"), 0o700)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    lease_path = LeaseManager.lease_path(issue.id)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf!(lease_path)
      File.rm_rf!(lease_path <> ".lock")
      File.rm_rf!(root)
    end)

    Process.put(:passive_acquires, 0)
    Process.put(:passive_starts, 0)

    %{
      issue: issue,
      workspace: workspace,
      state: %State{
        lease_owner: "local-owner",
        max_concurrent_agents: 1,
        claimed: MapSet.new([issue.id])
      }
    }
  end

  test "stale local passive claim cannot mutate or start under a foreign lease", context do
    %{issue: issue, workspace: workspace, state: state} = context
    assert {:ok, _foreign} = LeaseManager.acquire(issue.id, issue.identifier, "foreign-owner")
    assert {:ok, lease} = LeaseManager.read(issue.id)

    assert {:ok, _} =
             RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(lease))

    state_bytes = File.read!(RunStateStore.state_path(workspace))
    lease_bytes = File.read!(LeaseManager.lease_path(issue.id))
    next = dispatch(state, issue)
    assert Process.get(:passive_acquires) == 1
    assert Process.get(:passive_starts) == 0
    assert next.running == %{}
    assert File.read!(RunStateStore.state_path(workspace)) == state_bytes
    assert File.read!(LeaseManager.lease_path(issue.id)) == lease_bytes
  end

  test "valid own passive claim reacquires once and cannot start a duplicate worker", context do
    %{issue: issue, workspace: workspace, state: state} = context
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)

    state = %{
      state
      | lease_claims: %{
          issue.id => %{
            token: acquired.token,
            lease: acquired.lease,
            custody_ref: make_ref(),
            holder: :retry,
            workspace: Workspace.path_for_issue(issue),
            issue: issue,
            started_at_ms: System.monotonic_time(:millisecond),
            deadline: :not_pending,
            promotion_ref: nil,
            timer: nil
          }
        }
    }

    assert {:ok, lease} = LeaseManager.read(issue.id)

    assert {:ok, _} =
             RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(lease))

    next = dispatch(state, issue)
    assert %{passive?: true, dispatch_stage: "await_checks", pid: worker} = next.running[issue.id]
    final = dispatch(next, issue)
    assert final.running[issue.id].pid == worker
    assert map_size(final.running) == 1
    assert Process.get(:passive_acquires) == 1
    assert Process.get(:passive_starts) == 1
    assert {:ok, current} = LeaseManager.read(issue.id)
    assert current["owner"] == state.lease_owner
    assert current["epoch"] == lease["epoch"]
    assert current["acquired_at"] == lease["acquired_at"]
  end

  defp dispatch(state, issue) do
    acquire = fn id, identifier, owner ->
      Process.put(:passive_acquires, Process.get(:passive_acquires) + 1)

      case Map.get(state.lease_claims, id) do
        nil -> LeaseManager.acquire(id, identifier, owner)
        claim -> LeaseManager.acquire(id, identifier, owner, storage: claim.token.storage, expected_token: claim.token)
      end
    end

    starter = fn _, _ ->
      Process.put(:passive_starts, Process.get(:passive_starts) + 1)

      worker =
        spawn(fn ->
          receive do
            :finish -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      {:ok, worker}
    end

    passive = fn current, issue, attempt ->
      Orchestrator.dispatch_passive_issue_for_test(current, issue,
        attempt: attempt,
        acquire_fun: acquire,
        spawn_fun: fn current, issue, attempt, recipient ->
          Orchestrator.do_spawn_passive_worker_for_test(current, issue, attempt, recipient, start_child_fun: starter)
        end
      )
    end

    Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil,
      active_dispatch_fun: fn _, _, _ -> flunk("await_checks unexpectedly routed active") end,
      passive_dispatch_fun: passive
    )
  end
end
