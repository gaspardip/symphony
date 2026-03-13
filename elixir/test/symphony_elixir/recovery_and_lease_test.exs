defmodule SymphonyElixir.RecoveryAndLeaseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LeaseManager, Orchestrator, RunStateStore, Workspace}

  test "run state store merges new defaults into older persisted state files" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-state-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        RunStateStore.state_path(workspace),
        Jason.encode!(%{
          "issue_id" => "issue-legacy",
          "issue_identifier" => "MT-401",
          "stage" => "await_checks",
          "last_check_statuses" => [%{"name" => "ci / validate", "status" => "IN_PROGRESS"}]
        })
      )

      state =
        RunStateStore.load_or_default(workspace, %Issue{id: "issue-legacy", identifier: "MT-401"})

      assert state.stage == "await_checks"
      assert state.issue_id == "issue-legacy"
      assert state.await_checks_polls == 0
      assert state.merge_attempts == 0
      assert state.stage_transition_counts == %{}
      assert state.last_check_statuses == [%{name: "ci / validate", status: "IN_PROGRESS"}]
      assert state.last_required_checks_state == nil
    after
      File.rm_rf(workspace)
    end
  end

  test "run state store ignores persisted state from a different issue" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-state-mismatch-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        RunStateStore.state_path(workspace),
        Jason.encode!(%{
          "issue_id" => "issue-old",
          "issue_identifier" => "CLZ-14",
          "stage" => "publish",
          "last_rule_id" => "noop.max_turns_exceeded",
          "last_decision_summary" => "stale state"
        })
      )

      state =
        RunStateStore.load_or_default(workspace, %Issue{
          id: "manual:events-map-filters",
          identifier: "EVT-PILOT-01",
          source: :manual
        })

      assert state.issue_id == "manual:events-map-filters"
      assert state.issue_identifier == "EVT-PILOT-01"
      assert state.issue_source == :manual
      assert state.stage == "checkout"
      assert state.last_rule_id == nil
      assert state.last_decision_summary == nil
    after
      File.rm_rf(workspace)
    end
  end

  test "run state store transition preserves existing issue-scoped state when no issue context is passed" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-state-transition-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      :ok =
        RunStateStore.save(workspace, %{
          issue_id: "issue-existing",
          issue_identifier: "MT-402",
          stage: "implement",
          branch: "symphony/mt-402",
          base_branch: "main"
        })

      assert {:ok, state} = RunStateStore.transition(workspace, "blocked", %{last_rule_id: "noop.max_turns_exceeded"})
      assert state.issue_id == "issue-existing"
      assert state.issue_identifier == "MT-402"
      assert state.branch == "symphony/mt-402"
      assert state.base_branch == "main"
      assert state.last_rule_id == "noop.max_turns_exceeded"
    after
      File.rm_rf(workspace)
    end
  end

  test "run state store syncs and clears lease ownership metadata without losing issue context" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-state-lease-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{id: "issue-lease-sync", identifier: "MT-LEASE-SYNC", source: :manual}

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      assert {:ok, synced_state} =
               RunStateStore.sync_lease(workspace, issue, %{
                 "owner" => "orchestrator-owner",
                 "epoch" => 4,
                 "acquired_at" => "2026-03-13T01:02:03Z",
                 "updated_at" => "2026-03-13T01:03:04Z",
                 "lease_status" => "held",
                 "lease_owner_instance_id" => "canary:dogfood-runner",
                 "lease_owner_channel" => "canary"
               })

      assert synced_state.issue_id == issue.id
      assert synced_state.issue_identifier == issue.identifier
      assert synced_state.issue_source == :manual
      assert synced_state.lease_owner == "orchestrator-owner"
      assert synced_state.lease_owner_instance_id == "canary:dogfood-runner"
      assert synced_state.lease_owner_channel == "canary"
      assert synced_state.lease_acquired_at == "2026-03-13T01:02:03Z"
      assert synced_state.lease_updated_at == "2026-03-13T01:03:04Z"
      assert synced_state.lease_status == "held"
      assert synced_state.lease_epoch == 4

      assert {:ok, cleared_state} = RunStateStore.clear_lease(workspace)
      assert cleared_state.issue_id == issue.id
      assert cleared_state.issue_identifier == issue.identifier
      assert cleared_state.issue_source == "manual"
      assert cleared_state.lease_owner == nil
      assert cleared_state.lease_owner_instance_id == nil
      assert cleared_state.lease_owner_channel == nil
      assert cleared_state.lease_acquired_at == nil
      assert cleared_state.lease_updated_at == nil
      assert cleared_state.lease_status == nil
      assert cleared_state.lease_epoch == nil
    after
      File.rm_rf(workspace)
    end
  end

  test "passive await_checks delay honors merge window next allowed time" do
    next_allowed_at =
      DateTime.utc_now()
      |> DateTime.add(90, :second)
      |> DateTime.to_iso8601()

    delay_ms =
      Orchestrator.passive_delay_ms_for_await_checks_for_test(%{
        stage: "await_checks",
        merge_window_wait: %{next_allowed_at: next_allowed_at}
      })

    assert delay_ms >= 80_000
    assert delay_ms <= 120_000
  end

  test "lease takeover increments epoch and stale owners cannot refresh" do
    issue_id = "issue-lease-#{System.unique_integer([:positive])}"
    path = LeaseManager.lease_path(issue_id)
    old_timestamp = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    try do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: "MT-402",
          owner: "owner-a",
          lease_version: 1,
          epoch: 2,
          acquired_at: old_timestamp,
          updated_at: old_timestamp
        })
      )

      assert :ok = LeaseManager.acquire(issue_id, "MT-402", "owner-b", ttl_ms: 1)
      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert lease["owner"] == "owner-b"
      assert lease["epoch"] == 3
      assert LeaseManager.refresh(issue_id, "owner-a") == {:error, :claimed}
      assert :ok = LeaseManager.refresh(issue_id, "owner-b")
    after
      File.rm(path)
    end
  end

  test "review follow-up lease helpers acquire, classify, and release owner state" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-follow-up-lease-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      runner_instance_name: "stable-runner",
      runner_channel: "stable"
    )

    issue = %Issue{id: "manual:review-lease", identifier: "MT-REVIEW-LEASE", source: :manual}
    workspace = Workspace.path_for_issue(issue)

    try do
      File.mkdir_p!(workspace)

      :ok =
        RunStateStore.save(workspace, %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          issue_source: issue.source,
          stage: "await_checks"
        })

      state = %Orchestrator.State{lease_owner: "review-owner"}

      run_state = %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_source: issue.source
      }

      assert :ok = Orchestrator.review_follow_up_lease_status_for_test(state, run_state)

      assert {:ok, lease_attrs, true} =
               Orchestrator.ensure_review_follow_up_lease_for_test(state, run_state)

      assert lease_attrs.lease_owner == "review-owner"
      assert lease_attrs.lease_owner_instance_id == "stable:stable-runner"
      assert lease_attrs.lease_owner_channel == "stable"
      assert lease_attrs.lease_status == "held"
      assert :ok = Orchestrator.review_follow_up_lease_status_for_test(state, run_state)
      assert Orchestrator.workspace_for_issue_id_for_test(state, issue.id) == workspace

      assert {:ok, _synced_state} = RunStateStore.sync_lease(workspace, issue, lease_attrs)
      assert :ok = Orchestrator.release_review_follow_up_lease_for_test(state, run_state, workspace)
      assert {:error, :missing} = LeaseManager.read(issue.id)

      assert {:ok, cleared_state} = RunStateStore.load(workspace)
      assert cleared_state.lease_owner == nil
      assert cleared_state.lease_status == nil
      assert Orchestrator.workspace_for_issue_id_for_test(state, issue.id) == nil
    after
      File.rm_rf(workspace_root)
    end
  end

  test "persisted lease helpers sync and clear run-state ownership from live leases" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-persist-live-lease-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      runner_instance_name: "stable-runner",
      runner_channel: "stable"
    )

    issue = %Issue{id: "issue-persist-live-lease", identifier: "MT-PERSIST-LIVE-LEASE"}
    workspace = Workspace.path_for_issue(issue)

    try do
      File.mkdir_p!(workspace)
      assert :ok = LeaseManager.acquire(issue.id, issue.identifier, "persist-owner")

      state = %Orchestrator.State{
        lease_owner: "persist-owner",
        running: %{
          issue.id => %{
            issue: issue,
            identifier: issue.identifier
          }
        }
      }

      assert {:ok, persisted_state} =
               Orchestrator.persist_live_issue_lease_for_test(state, workspace, issue)

      assert persisted_state.lease_owner == "persist-owner"
      assert persisted_state.lease_owner_instance_id == "stable:stable-runner"
      assert persisted_state.lease_owner_channel == "stable"
      assert persisted_state.lease_status == "held"

      Process.sleep(5)
      assert :ok = LeaseManager.refresh(issue.id, "persist-owner")
      assert :ok = Orchestrator.maybe_sync_running_issue_lease_for_test(state, issue.id)

      assert {:ok, refreshed_state} = RunStateStore.load(workspace)
      assert refreshed_state.lease_owner == "persist-owner"
      assert refreshed_state.lease_updated_at != nil

      assert :ok = Orchestrator.maybe_clear_persisted_lease_for_test(workspace)
      assert {:ok, cleared_state} = RunStateStore.load(workspace)
      assert cleared_state.lease_owner == nil
      assert cleared_state.lease_epoch == nil
    after
      LeaseManager.release(issue.id)
      File.rm_rf(workspace_root)
    end
  end

  test "run state store load_checked returns mismatch for a different issue" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-state-load-checked-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        RunStateStore.state_path(workspace),
        Jason.encode!(%{
          "issue_id" => "issue-old",
          "issue_identifier" => "CLZ-14",
          "stage" => "publish"
        })
      )

      assert {:mismatch, state} =
               RunStateStore.load_checked(workspace, %Issue{
                 id: "manual:events-map-filters",
                 identifier: "EVT-PILOT-01",
                 source: :manual
               })

      assert state.issue_id == "issue-old"
      assert state.issue_identifier == "CLZ-14"
      assert state.stage == "publish"
    after
      File.rm_rf(workspace)
    end
  end

  test "normalize dispatch stage repairs stale run state back to checkout" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repair-stale-state-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: "manual:evt-repair", identifier: "EVT-REPAIR-01", source: :manual}
    workspace = Workspace.path_for_issue(issue)

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        RunStateStore.state_path(workspace),
        Jason.encode!(%{
          "issue_id" => "manual:clz-14",
          "issue_identifier" => "CLZ-14",
          "stage" => "verify"
        })
      )

      assert "checkout" == Orchestrator.normalize_dispatch_stage_for_test(issue)
      assert {:ok, state} = RunStateStore.load(workspace)
      assert state.issue_id == issue.id
      assert state.issue_identifier == issue.identifier
      assert state.stage == "checkout"
      assert state.last_decision_summary =~ "stale run state"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "normalize dispatch stage repairs clean wrong-branch workspaces back to checkout" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repair-branch-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: "manual:evt-branch", identifier: "EVT-BRANCH-01", source: :manual}
    workspace = Workspace.path_for_issue(issue)

    try do
      init_git_workspace!(workspace)

      {:ok, _state} =
        RunStateStore.transition(workspace, "implement", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier
        })

      assert "checkout" == Orchestrator.normalize_dispatch_stage_for_test(issue)
      assert {:ok, state} = RunStateStore.load(workspace)
      assert state.stage == "checkout"
      assert state.last_decision_summary =~ "wrong branch"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "normalize dispatch stage blocks dirty wrong-branch workspaces with attached pr state" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-block-branch-pr-mismatch-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: "manual:evt-branch-pr", identifier: "EVT-BRANCH-PR-01", source: :manual}
    workspace = Workspace.path_for_issue(issue)
    original_path = System.get_env("PATH")

    try do
      init_git_workspace!(workspace)
      File.write!(Path.join(workspace, "README.md"), "dirty mismatch\n")
      fake_bin = write_fake_gh_bin!(workspace_root, "gh", open_pr_payload())
      System.put_env("PATH", "#{fake_bin}:#{original_path}")

      {:ok, _state} =
        RunStateStore.transition(workspace, "await_checks", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          branch: "symphony/evt-branch-pr-01",
          pr_url: "https://github.com/gaspardip/events/pull/1",
          last_pr_state: "OPEN"
        })

      assert "blocked" == Orchestrator.normalize_dispatch_stage_for_test(issue)
      assert {:ok, state} = RunStateStore.load(workspace)
      assert state.stage == "blocked"
      assert state.last_rule_id == "checkout.branch_pr_mismatch"
      assert state.last_decision_summary =~ "does not belong to this issue"
      assert state.next_human_action =~ "issue branch and attached PR match"
    after
      restore_env("PATH", original_path)
      File.rm_rf(workspace_root)
    end
  end

  test "normalize dispatch stage repairs merged prs to post_merge" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repair-merged-pr-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: "manual:evt-merged", identifier: "EVT-MERGED-01", source: :manual}
    workspace = Workspace.path_for_issue(issue)
    original_path = System.get_env("PATH")

    try do
      init_git_workspace!(workspace, branch: "symphony/evt-merged-01")
      fake_bin = write_fake_gh_bin!(workspace_root, "gh", merged_pr_payload())
      System.put_env("PATH", "#{fake_bin}:#{original_path}")

      {:ok, _state} =
        RunStateStore.transition(workspace, "publish", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier
        })

      assert "post_merge" == Orchestrator.normalize_dispatch_stage_for_test(issue)
      assert {:ok, state} = RunStateStore.load(workspace)
      assert state.stage == "post_merge"
      assert state.pr_url == "https://github.com/gaspardip/events/pull/99"
      assert state.last_pr_state == "MERGED"
      assert state.last_decision_summary =~ "merged PR"
    after
      restore_env("PATH", original_path)
      File.rm_rf(workspace_root)
    end
  end

  test "normalize dispatch stage repairs stale pr metadata in place" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repair-pr-metadata-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: "manual:evt-pr-meta", identifier: "EVT-PR-META-01", source: :manual}
    workspace = Workspace.path_for_issue(issue)
    original_path = System.get_env("PATH")

    try do
      init_git_workspace!(workspace, branch: "symphony/evt-pr-meta-01")
      fake_bin = write_fake_gh_bin!(workspace_root, "gh", open_pr_payload())
      System.put_env("PATH", "#{fake_bin}:#{original_path}")

      {:ok, _state} =
        RunStateStore.transition(workspace, "await_checks", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          pr_url: "https://github.com/gaspardip/events/pull/1",
          last_pr_state: "OPEN"
        })

      assert "await_checks" == Orchestrator.normalize_dispatch_stage_for_test(issue)
      assert {:ok, state} = RunStateStore.load(workspace)
      assert state.stage == "await_checks"
      assert state.pr_url == "https://github.com/gaspardip/events/pull/101"
      assert state.last_pr_state == "OPEN"
      assert state.last_decision_summary =~ "stale PR metadata"
    after
      restore_env("PATH", original_path)
      File.rm_rf(workspace_root)
    end
  end

  test "normalize dispatch stage repairs missing checkouts back to checkout" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repair-missing-checkout-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    issue = %Issue{id: "manual:evt-missing", identifier: "EVT-MISSING-01", source: :manual}
    workspace = Workspace.path_for_issue(issue)

    try do
      File.mkdir_p!(workspace)

      {:ok, _state} =
        RunStateStore.transition(workspace, "implement", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier
        })

      assert "checkout" == Orchestrator.normalize_dispatch_stage_for_test(issue)
      assert {:ok, state} = RunStateStore.load(workspace)
      assert state.stage == "checkout"
      assert state.last_decision_summary =~ "valid Git checkout"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "dispatch takes over a stale persisted lease through the real dispatch path" do
    issue_id = "issue-stale-dispatch-#{System.unique_integer([:positive])}"
    identifier = "MT-STALE-DISPATCH"
    owner = "owner-fresh"
    path = LeaseManager.lease_path(issue_id)
    old_timestamp = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    issue = %Issue{id: issue_id, identifier: identifier, state: "Todo"}
    state = %Orchestrator.State{lease_owner: owner, retry_attempts: %{}, claimed: MapSet.new(), running: %{}}

    try do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: identifier,
          owner: "owner-stale",
          lease_version: 1,
          epoch: 4,
          acquired_at: old_timestamp,
          updated_at: old_timestamp
        })
      )

      returned_state =
        Orchestrator.do_dispatch_issue_for_test(
          state,
          issue,
          2,
          spawn_fun: fn dispatch_state, dispatch_issue, attempt, _recipient ->
            send(self(), {:spawned, dispatch_issue.id, attempt})
            dispatch_state
          end
        )

      assert_receive {:spawned, ^issue_id, 2}
      assert returned_state == state

      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert lease["owner"] == owner
      assert lease["epoch"] == 5
    after
      File.rm(path)
    end
  end

  test "run policy blocks repos that fail compatibility before implement" do
    workspace = temp_workspace("repo-compat-policy-stop")

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
        """
        version: 1
        base_branch: main
        preflight:
          command:
            - ./scripts/preflight.sh
        validation:
          command:
            - ./scripts/validate.sh
        smoke:
          command:
            - ./scripts/smoke.sh
        post_merge:
          command:
            - ./scripts/post-merge.sh
        artifacts:
          command:
            - ./scripts/artifacts.sh
        pull_request:
          required_checks:
            - validate
        """
      )

      issue = %Issue{id: "issue-compat-stop", identifier: "MT-COMPAT-STOP", title: "Compat stop", state: "Todo"}

      assert {:stop, violation} = RunPolicy.enforce_pre_run(issue, workspace)
      assert violation.code == :repo_not_compatible
      assert violation.rule_id == "compatibility.not_certified"
    after
      File.rm_rf(workspace)
    end
  end

  defp init_git_workspace!(workspace, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    File.mkdir_p!(workspace)
    assert {_, 0} = System.cmd("git", ["init", "-b", branch], cd: workspace)
    assert {_, 0} = System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["config", "user.email", "symfony@example.com"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "# test\n")
    assert {_, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: workspace)
  end

  defp temp_workspace(prefix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-#{prefix}-#{System.unique_integer([:positive])}"
    )
  end

  defp write_fake_gh_bin!(root, name, payload) do
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    path = Path.join(bin_dir, name)

    File.write!(
      path,
      """
      #!/bin/sh
      printf '%s' '#{payload}'
      """
    )

    File.chmod!(path, 0o755)
    bin_dir
  end

  defp merged_pr_payload do
    Jason.encode!(%{
      "url" => "https://github.com/gaspardip/events/pull/99",
      "state" => "MERGED",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => []
    })
  end

  defp open_pr_payload do
    Jason.encode!(%{
      "url" => "https://github.com/gaspardip/events/pull/101",
      "state" => "OPEN",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => []
    })
  end
end
