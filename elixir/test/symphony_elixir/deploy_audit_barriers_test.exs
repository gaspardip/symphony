defmodule SymphonyElixir.DeployAuditBarriersTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DeployAudit, DispatchAudit, LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.Controls
  alias SymphonyElixir.Orchestrator.State

  setup context do
    root = Path.join(System.tmp_dir!(), "deploy-audit-barriers-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      runner_install_root: Path.join(root, "runner"),
      manual_store_root: Path.join(root, "manual"),
      company_author_profile_path: Path.join(root, "author.json"),
      company_credential_registry_path: Path.join(root, "credentials.json"),
      max_concurrent_agents: 0,
      codex_command: "false",
      hook_before_run: "printf before > before-hook-ran",
      hook_after_run: "printf after > after-hook-ran",
      hook_before_remove: "printf remove > remove-hook-ran"
    )

    issue = %Issue{id: "deploy-barrier", identifier: "DEPLOY-BARRIER", title: "Local pending deploy", state: "In Progress", source: :tracker, labels: []}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sentinel.txt"), "preserve local work\n")

    assert {:ok, _} =
             RunStateStore.transition(workspace, "deploy_preview", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: issue.source,
               pr_url: "https://example.invalid/pr/1",
               stop_reason: nil
             })

    owner = "deploy-barrier-owner"
    assert :ok = LeaseManager.acquire(issue.id, issue.identifier, owner)

    dispatch_ticket =
      if context[:dispatch_ticket] do
        assert {:ok, lease} = LeaseManager.read(issue.id)
        assert {:ok, ticket} = DispatchAudit.begin(workspace, %{issue_id: issue.id, issue_identifier: issue.identifier, metadata: %{owner: owner, epoch: lease["epoch"]}})
        ticket
      end

    if context[:incomplete] do
      File.mkdir!(DeployAudit.marker_directory(workspace))
    else
      assert {:ok, _ticket} =
               DeployAudit.begin(workspace, %{
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 stage: "deploy_preview",
                 command: "printf local-deploy"
               })
    end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    timer = Process.send_after(self(), :existing_retry_timer, 60_000)
    on_exit(fn -> Process.cancel_timer(timer) end)

    state = %State{
      lease_owner: owner,
      max_concurrent_agents: 1,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{issue.id => %{identifier: issue.identifier, attempt: 2, retry_ref: make_ref(), status: :scheduled, timer_ref: timer, due_at_ms: System.monotonic_time(:millisecond) + 60_000}}
    }

    {:ok, root: root, workspace: workspace, issue: issue, state: state, timer: timer, before: protected_bytes(workspace, issue), dispatch_ticket: dispatch_ticket}
  end

  for action <- [:retry, :resume, :refresh_merge, :approve_merge, :approve_deploy, :approve_drafts, :post_drafts] do
    @tag action: action
    test "#{action} refuses a pending deploy before tracker, timer, lease or snapshot changes", context do
      state = if context.action == :resume, do: paused_state(context), else: context.state
      {reply, returned} = control(context.action, state, context.issue.identifier)

      assert reply.ok == false
      assert reply.error =~ "deploy_audit_pending"
      assert returned == state
      assert is_integer(Process.read_timer(context.timer))
      assert protected_bytes(context.workspace, context.issue) == context.before
      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, _, _}
      refute_received :tick
      refute File.exists?(Path.join(context.workspace, "before-hook-ran"))
      refute File.exists?(Path.join(context.workspace, "after-hook-ran"))
    end
  end

  test "direct resume helper returns the pending error without its tracker fallback", context do
    assert {:error, {:deploy_audit_pending, _}} =
             Controls.maybe_resume_blocked_issue(context.state, %{context.issue | state: "Blocked"})

    assert protected_bytes(context.workspace, context.issue) == context.before
    assert is_integer(Process.read_timer(context.timer))
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_comment, _, _}
  end

  test "public admission and the lease acquisition entry refuse pending deploys", context do
    blocked = Orchestrator.dispatch_runtime_issue(context.state, context.issue, nil)
    assert {:deploy_audit_pending, _} = blocked.candidate_fetch_error
    assert blocked.running == %{}
    assert blocked.claimed == context.state.claimed
    assert protected_bytes(context.workspace, context.issue) == context.before

    acquire = fn _, _, _ ->
      send(self(), :unexpected_lease_acquisition)
      :ok
    end

    spawn_worker = fn state, _, _, _ ->
      send(self(), :unexpected_spawn)
      state
    end

    blocked = Orchestrator.do_dispatch_issue_for_test(context.state, context.issue, nil, acquire_fun: acquire, spawn_fun: spawn_worker)

    assert {:dispatch_audit_failed, "deploy-barrier", {:deploy_audit_pending, _}} = blocked.candidate_fetch_error
    refute_received :unexpected_lease_acquisition
    refute_received :unexpected_spawn
    assert protected_bytes(context.workspace, context.issue) == context.before
  end

  test "automatic retry halts without releasing the held lease or clearing deploy evidence", context do
    assert {:noreply, blocked} = Orchestrator.handle_info({:retry_issue, context.issue.id, context.state.retry_attempts[context.issue.id].retry_ref}, context.state)
    assert {:dispatch_audit_failed, "deploy-barrier", {:deploy_audit_pending, _}} = blocked.candidate_fetch_error
    assert blocked.running == %{}
    assert blocked.claimed == context.state.claimed
    refute Map.has_key?(blocked.retry_attempts, context.issue.id)
    assert Process.read_timer(context.timer) == false
    assert protected_bytes(context.workspace, context.issue) == context.before
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_comment, _, _}
  end

  for reason <- [:normal, :controlled_failure] do
    @tag dispatch_ticket: true, worker_exit: reason
    test "worker DOWN #{reason} retains the deploy journal and claim without completion or retry", context do
      {pid, ref} =
        spawn_monitor(fn ->
          receive do
            :finish -> exit(context.worker_exit)
          end
        end)

      send(pid, :finish)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason} = down
      assert reason == context.worker_exit

      entry = %{
        pid: pid,
        ref: ref,
        identifier: context.issue.identifier,
        issue: context.issue,
        started_at: DateTime.utc_now(),
        workspace_path: context.workspace,
        dispatch_ticket: context.dispatch_ticket
      }

      state = %{context.state | running: %{context.issue.id => entry}}

      assert {:noreply, halted} = Orchestrator.handle_info(down, state)
      assert {:dispatch_audit_failed, "deploy-barrier", {:deploy_audit_pending, _}} = halted.candidate_fetch_error
      assert halted.running == %{}
      assert halted.completed == %{}
      assert halted.claimed == context.state.claimed
      assert halted.retry_attempts == %{}
      assert Process.read_timer(context.timer) == false
      assert :ok = DispatchAudit.ensure_available(context.workspace)
      assert Map.drop(protected_bytes(context.workspace, context.issue), [:ledger]) == Map.drop(context.before, [:ledger])
      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, _, _}
    end
  end

  @tag dispatch_ticket: true
  test "failed dispatch finalization cannot release a pending deploy's lease or conceal either error", context do
    ledger = RunLedger.ledger_file_path()
    backup = Path.join(context.root, "ledger-before-fault.jsonl")
    File.rename!(ledger, backup)
    File.mkdir!(ledger)

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :finish -> :ok
        end
      end)

    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal} = down

    entry = %{
      pid: pid,
      ref: ref,
      identifier: context.issue.identifier,
      issue: context.issue,
      started_at: DateTime.utc_now(),
      workspace_path: context.workspace,
      dispatch_ticket: context.dispatch_ticket
    }

    state = %{context.state | running: %{context.issue.id => entry}}

    assert {:noreply, halted} = Orchestrator.handle_info(down, state)
    assert {:dispatch_audit_failed, "deploy-barrier", {:deploy_audit_pending, detail}} = halted.candidate_fetch_error
    assert detail.journal == Path.expand(context.workspace)
    assert %RunLedger.PersistenceError{} = detail.dispatch_finish_error
    assert halted.running == %{}
    assert halted.completed == %{}
    assert halted.claimed == context.state.claimed
    assert halted.retry_attempts == %{}
    assert Process.read_timer(context.timer) == false
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
    assert File.read!(RunStateStore.state_path(context.workspace)) == context.before.snapshot
    assert File.read!(LeaseManager.lease_path(context.issue.id)) == context.before.lease
    assert journal_bytes(context.workspace) == context.before.journal
    assert File.read!(backup) == context.before.ledger
    assert File.ls!(ledger) == []
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_comment, _, _}
  end

  test "Workspace refuses lifecycle and hooks while preserving the original worker failure", context do
    assert {:error, {:deploy_audit_pending, _}} = Workspace.create_for_issue(context.issue)
    assert {:error, {:deploy_audit_pending, _}, ""} = Workspace.remove(context.workspace)

    log =
      capture_log(fn ->
        assert {:error, {:deploy_audit_pending, _}} = Workspace.run_before_run_hook(context.workspace, context.issue)

        assert_raise RuntimeError, "original worker failure", fn ->
          try do
            raise "original worker failure"
          after
            assert :ok = Workspace.run_after_run_hook(context.workspace, context.issue)
          end
        end
      end)

    assert log =~ "Workspace hook refused"
    assert log =~ "deploy_audit_pending"
    assert protected_bytes(context.workspace, context.issue) == context.before
    assert File.read!(Path.join(context.workspace, "sentinel.txt")) == "preserve local work\n"
    for file <- ["before-hook-ran", "after-hook-ran", "remove-hook-ran"], do: refute(File.exists?(Path.join(context.workspace, file)))
  end

  @tag incomplete: true
  test "an incomplete deploy marker blocks retry and cleanup without repairing the marker", context do
    {reply, state} = Controls.retry_issue_now_runtime(context.state, context.issue.identifier)
    assert reply.ok == false
    assert reply.error =~ "deploy_audit_pending"
    assert state == context.state
    assert {:error, {:deploy_audit_pending, _}, ""} = Workspace.remove(context.workspace)
    assert File.ls!(DeployAudit.marker_directory(context.workspace)) == []
    assert protected_bytes(context.workspace, context.issue) == context.before
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "an unreadable journal parent reports its error before control side effects", context do
    parent = Path.join(context.root, "not-a-directory")
    File.write!(parent, "preserve filesystem failure")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(parent, "child"),
      runner_install_root: Path.join(context.root, "runner"),
      manual_store_root: Path.join(context.root, "manual"),
      company_author_profile_path: Path.join(context.root, "author.json"),
      company_credential_registry_path: Path.join(context.root, "credentials.json")
    )

    {reply, state} = Controls.retry_issue_now_runtime(context.state, context.issue.identifier)
    assert reply.ok == false
    assert reply.error =~ "deploy_audit_read_failed"
    assert reply.error =~ "enotdir"
    assert state == context.state
    assert is_integer(Process.read_timer(context.timer))
    assert File.read!(parent) == "preserve filesystem failure"
    assert protected_bytes(context.workspace, context.issue) == context.before
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "pause and stop remain available and retain the deploy journal", context do
    marker_before = journal_bytes(context.workspace)
    {paused_reply, paused} = Controls.pause_issue_runtime(context.state, context.issue.identifier)
    assert paused_reply.ok
    assert_received {:memory_tracker_state_update, "deploy-barrier", "Paused"}
    assert journal_bytes(context.workspace) == marker_before

    {stop_reply, _stopped} = Controls.stop_issue_runtime(paused, context.issue.identifier)
    assert stop_reply.ok
    assert_received {:memory_tracker_state_update, "deploy-barrier", "Blocked"}
    assert_received {:memory_tracker_comment, "deploy-barrier", _}
    assert journal_bytes(context.workspace) == marker_before
    assert {:ok, _state} = RunStateStore.load(context.workspace)
  end

  defp control(:retry, state, identifier), do: Controls.retry_issue_now_runtime(state, identifier)
  defp control(:resume, state, identifier), do: Controls.resume_issue_runtime(state, identifier)
  defp control(:refresh_merge, state, identifier), do: Controls.refresh_merge_readiness_runtime(state, identifier)
  defp control(:approve_merge, state, identifier), do: Controls.approve_issue_for_merge_runtime(state, identifier)
  defp control(:approve_deploy, state, identifier), do: Controls.approve_issue_for_deploy_runtime(state, identifier)
  defp control(:approve_drafts, state, identifier), do: Controls.review_thread_action_runtime(state, identifier, "approve_review_drafts")
  defp control(:post_drafts, state, identifier), do: Controls.post_review_drafts_runtime(state, identifier)

  defp paused_state(context) do
    %{
      context.state
      | paused_issue_states: %{
          context.issue.id => %{
            identifier: context.issue.identifier,
            resume_state: "In Progress",
            source: :tracker,
            external_id: context.issue.id,
            canonical_identifier: context.issue.identifier
          }
        }
    }
  end

  defp protected_bytes(workspace, issue) do
    %{
      snapshot: File.read!(RunStateStore.state_path(workspace)),
      lease: File.read!(LeaseManager.lease_path(issue.id)),
      ledger: File.read!(RunLedger.ledger_file_path()),
      journal: journal_bytes(workspace)
    }
  end

  defp journal_bytes(workspace) do
    directory = DeployAudit.marker_directory(workspace)
    Map.new(File.ls!(directory), fn name -> {name, File.read!(Path.join(directory, name))} end)
  end
end
