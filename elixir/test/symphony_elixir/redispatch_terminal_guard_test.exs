# Proposed repository regression file. Not installed or executed as a repo test yet.
# Uses existing public APIs/seams; introduces no new *_for_test functions.
defmodule SymphonyElixir.RedispatchTerminalGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.{Controls, State}

  # The fixture owns this State in one real GenServer. Control continuations,
  # reader results and replies are handled by production callbacks.
  defmodule ControlDriver do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state, state}
    def handle_call(message, from, state), do: Orchestrator.handle_call(message, from, state)

    @impl true
    def handle_info(message, state), do: Orchestrator.handle_info(message, state)
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "redispatch-terminal-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner-install"),
      max_concurrent_agents: 1,
      codex_command: "printf invoked > .symphony/provider-invoked; exit 99",
      hook_before_run: "printf seen > .symphony/before-run-seen",
      policy_token_budget: %{
        per_turn_input: 150_000,
        per_issue_total: 500_000,
        per_issue_total_output: 10_000,
        stages: %{implement: %{per_turn_input_soft: 60_000, per_turn_input_hard: 120_000}},
        broad_implement: %{enabled: true, auto_retry_limit: 2}
      }
    )

    issue = %Issue{
      id: "terminal-redispatch",
      identifier: "TERMINAL-REDISPATCH",
      title: "Terminal redispatch",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    gh = Path.join(bin, "gh")

    File.write!(
      gh,
      "#!/bin/sh\nprintf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n"
    )

    File.chmod!(gh, 0o700)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)

    assert {:ok, _} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    lease_path = LeaseManager.lease_path(issue.id)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf!(lease_path)
      File.rm_rf!(lease_path <> ".lock")
      File.rm_rf!(root)
    end)

    %{
      root: root,
      bin: bin,
      issue: issue,
      workspace: workspace,
      state: %State{max_concurrent_agents: 1, lease_owner: "probe-owner", agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}}
    }
  end

  for terminal <- ["blocked", "done"] do
    test "automatic dispatch preserves #{terminal} even when tracker remains active", context do
      %{issue: issue, workspace: workspace, state: state} = context
      terminal = unquote(terminal)

      assert {:ok, _} =
               RunStateStore.transition(workspace, terminal, %{
                 stop_reason: %{code: "environment_blocker"}
               })

      before_bytes = File.read!(RunStateStore.state_path(workspace))
      next = Orchestrator.dispatch_runtime_issue(state, issue, nil)

      try do
        assert next.running == %{}
        assert next.candidate_fetch_error == {:persisted_stage_requires_explicit_resume, terminal}
        assert {:error, :missing} = LeaseManager.read(issue.id)
        assert File.read!(RunStateStore.state_path(workspace)) == before_bytes

        refute Enum.any?(
                 RunLedger.recent_entries(),
                 &(&1["event_type"] == "dispatch.started" and &1["issue_id"] == issue.id)
               )
      after
        # The expected red baseline may have spawned a worker. Stop only that
        # worker before the fixture teardown, including when an assertion fails.
        Enum.each(next.running, fn {_id, %{pid: pid}} ->
          result = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
          assert result in [:ok, {:error, :not_found}]
        end)
      end
    end

    test "acquired lease revalidates #{terminal} before the spawn boundary", context do
      %{issue: issue, workspace: workspace, state: state} = context
      terminal = unquote(terminal)
      assert {:ok, %{stage: "implement"}} = RunStateStore.load(workspace)

      acquire = fn id, identifier, owner ->
        # Deterministic interleaving: the old owner publishes terminal state
        # after the caller's eligible read but before this acquisition succeeds.
        assert {:ok, _} =
                 RunStateStore.transition(workspace, terminal, %{
                   stop_reason: %{code: "environment_blocker"}
                 })

        LeaseManager.acquire(id, identifier, owner)
      end

      next =
        Orchestrator.do_dispatch_issue_for_test(state, issue, nil,
          acquire_fun: acquire,
          spawn_fun: fn _, _, _, _ ->
            flunk("terminal checkpoint reached spawn after acquiring lease")
          end
        )

      assert next.running == %{}
      assert {:ok, %{stage: ^terminal}} = RunStateStore.load(workspace)
      assert {:error, :missing} = LeaseManager.read(issue.id)
    end

    test "passive dispatch releases an existing claim for #{terminal}", context do
      %{issue: issue, workspace: workspace, state: state} = context
      assert {:ok, _} = RunStateStore.transition(workspace, unquote(terminal), %{})
      assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)
      state = with_custody(state, issue, acquired)
      state = %{state | claimed: MapSet.new([issue.id])}

      next =
        Orchestrator.dispatch_passive_issue_for_test(state, issue,
          spawn_fun: fn _, _, _, _ ->
            flunk("claimed terminal checkpoint reached passive spawn")
          end
        )

      refute MapSet.member?(next.claimed, issue.id)
      assert next.retry_attempts == %{}
      assert {:error, :missing} = LeaseManager.read(issue.id)
    end
  end

  test "routing does not repair a missing checkout before lease ownership", context do
    %{issue: issue, workspace: workspace, state: state} = context
    before_bytes = File.read!(RunStateStore.state_path(workspace))

    boundary = fn state, _, _ ->
      assert {:error, :missing} = LeaseManager.read(issue.id)
      state
    end

    Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil,
      active_dispatch_fun: boundary,
      passive_dispatch_fun: boundary
    )

    assert File.read!(RunStateStore.state_path(workspace)) == before_bytes
  end

  for lane <- [:active, :passive] do
    @tag lane: lane
    test "#{lane} normalization stops before spawning when branch ambiguity creates blocked",
         context do
      %{issue: issue, workspace: workspace, state: state} = context
      lane = context.lane

      for args <- [["init", "-q"], ["checkout", "-q", "-b", "foreign-branch"]] do
        assert {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
      end

      File.write!(Path.join(workspace, "fixture.txt"), "committed fixture")

      assert {_, 0} =
               System.cmd("git", ["add", "fixture.txt"], cd: workspace, stderr_to_stdout: true)

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

      File.write!(Path.join(workspace, "fixture.txt"), "dirty fixture on wrong branch")
      if lane == :passive, do: RunStateStore.transition(workspace, "await_checks", %{})

      spawn_boundary = fn state, issue, attempt, recipient ->
        opts = [
          start_child_fun: fn _, _ ->
            flunk("normalization produced blocked but started a worker")
          end
        ]

        case lane do
          :active ->
            Orchestrator.do_spawn_issue_worker_for_test(state, issue, attempt, recipient, opts)

          :passive ->
            Orchestrator.do_spawn_passive_worker_for_test(state, issue, attempt, recipient, opts)
        end
      end

      next = Orchestrator.do_dispatch_issue_for_test(state, issue, nil, spawn_fun: spawn_boundary)
      assert next.running == %{}
      assert next.retry_attempts == %{}
      assert {:error, :missing} = LeaseManager.read(issue.id)

      assert {:ok, %{stage: "blocked", stop_reason: %{code: "branch_pr_mismatch"}}} =
               RunStateStore.load(workspace)
    end
  end

  test "operator resume clears terminal stage and admits a legitimate retry", context do
    %{issue: issue, workspace: workspace, state: state} = context

    assert {:ok, _} =
             RunStateStore.transition(workspace, "blocked", %{
               stop_reason: %{code: "environment_blocker"}
             })

    {state, issue} = Controls.maybe_resume_blocked_issue(state, %{issue | state: "Blocked"})
    assert {:ok, %{stage: "implement", stop_reason: nil}} = RunStateStore.load(workspace)
    admit_and_release(state, issue)
  end

  test "authorized broad implement retry remains admissible", context do
    %{issue: issue, workspace: workspace, state: state} = context

    entry = %{
      workspace_path: workspace,
      dispatch_stage: "implement",
      turn_count: 1,
      agent_input_tokens: 150_000,
      agent_output_tokens: 0,
      agent_total_tokens: 150_000,
      turn_started_input_tokens: 0,
      last_agent_message: "The change belongs in lib/example.ex."
    }

    assert {:retry, %{budget_mode: "broad_implement", retry_count: 1}} =
             RunPolicy.maybe_stop_for_token_budget(issue, entry)

    assert {:ok, %{stage: "implement", resume_context: %{budget_retry_count: 1}}} =
             RunStateStore.load(workspace)

    {state, issue} = Controls.maybe_resume_blocked_issue(state, issue)
    admit_and_release(state, issue)
  end

  for terminal <- ["blocked", "done"], ownership <- [:ours, :other] do
    @tag ownership: ownership
    test "public dispatch rejects #{terminal} and only releases #{ownership} ownership",
         context do
      %{issue: issue, workspace: workspace, state: state} = context
      terminal = unquote(terminal)
      ownership = context.ownership
      owner = if ownership == :ours, do: state.lease_owner, else: "another-owner"
      assert {:ok, _} = RunStateStore.transition(workspace, terminal, %{})
      assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)
      state = with_custody(state, issue, acquired)

      if ownership == :other do
        assert {:ok, :released} = LeaseManager.release_token(acquired.token)
        assert {:ok, _successor} = LeaseManager.acquire(issue.id, issue.identifier, owner)
      end

      lease_bytes = File.read!(LeaseManager.lease_path(issue.id))
      state = %{state | claimed: MapSet.new([issue.id])}

      next =
        Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil,
          active_dispatch_fun: fn _, _, _ -> flunk("terminal issue entered active dispatch") end,
          passive_dispatch_fun: fn _, _, _ -> flunk("terminal issue entered passive dispatch") end
        )

      refute MapSet.member?(next.claimed, issue.id)
      assert next.candidate_fetch_error == {:persisted_stage_requires_explicit_resume, terminal}
      assert next.running == %{}
      assert next.retry_attempts == %{}

      if ownership == :ours do
        assert {:error, :missing} = LeaseManager.read(issue.id)
      else
        assert File.read!(LeaseManager.lease_path(issue.id)) == lease_bytes
      end
    end
  end

  for kind <- [:generic, :false_budget_flag, :review_no_progress, :done] do
    @tag timer_kind: kind
    test "pending automatic timer preserves current #{kind} terminal checkpoint", context do
      %{issue: issue, workspace: workspace, state: state} = context
      kind = context.timer_kind

      stop =
        if kind == :review_no_progress,
          do: %{code: "per_turn_input_budget_exceeded", rule_id: "budget.per_turn_input_exceeded"},
          else: %{code: "missing_checkout", rule_id: "checkout.missing_git"}

      terminal = if kind == :done, do: "done", else: "blocked"
      claims = %{"comment:2" => %{"disposition" => "accepted", "actionable" => true}}

      assert {:ok, _} =
               RunStateStore.transition(workspace, terminal, %{
                 stop_reason: stop,
                 last_rule_id: stop.rule_id,
                 review_claims: claims
               })

      if kind == :review_no_progress do
        assert %{delay_type: :none} =
                 Orchestrator.continuation_metadata_for_running_entry_for_test(%{
                   identifier: issue.identifier
                 })
      end

      before_bytes = File.read!(RunStateStore.state_path(workspace))

      metadata = %{
        identifier: issue.identifier,
        delay_type: :continuation,
        error: "pending retry"
      }

      metadata =
        if kind == :false_budget_flag,
          do: Map.merge(metadata, %{budget_retry: true, budget_mode: "broad_implement"}),
          else: metadata

      state = with_pending_timer(%{state | max_concurrent_agents: 0}, issue, metadata)
      assert {:noreply, next} = SymphonyElixir.OrchestratorRetryDriver.run(state, issue.id)

      try do
        assert next.running == %{}
        assert next.retry_attempts == %{}
        assert next.candidate_fetch_error == {:persisted_stage_requires_explicit_resume, terminal}
        assert File.read!(RunStateStore.state_path(workspace)) == before_bytes
        refute_received {:memory_tracker_state_update, _, _}
        assert {:error, :missing} = LeaseManager.read(issue.id)
      after
        cancel_retries(next)
      end
    end
  end

  test "review fix continuation with current claim progress is still authorized", context do
    %{issue: issue, workspace: workspace, state: state} = context

    claims = %{
      "comment:1" => %{
        "disposition" => "accepted",
        "actionable" => false,
        "implementation_status" => "addressed"
      },
      "comment:2" => %{"disposition" => "accepted", "actionable" => true}
    }

    assert {:ok, _} =
             RunStateStore.transition(workspace, "blocked", %{
               stop_reason: %{
                 code: "per_turn_input_budget_exceeded",
                 rule_id: "budget.per_turn_input_exceeded"
               },
               last_rule_id: "budget.per_turn_input_exceeded",
               review_claims: claims
             })

    metadata =
      Orchestrator.continuation_metadata_for_running_entry_for_test(%{
        identifier: issue.identifier
      })

    assert metadata.delay_type == :continuation

    state =
      with_pending_timer(
        %{state | max_concurrent_agents: 0},
        issue,
        Map.put(metadata, :identifier, issue.identifier)
      )

    assert {:noreply, next} = SymphonyElixir.OrchestratorRetryDriver.run(state, issue.id)

    try do
      assert {:ok, %{stage: "implement", stop_reason: nil, review_claims: ^claims}} =
               RunStateStore.load(workspace)

      assert Map.has_key?(next.retry_attempts, issue.id)
      assert next.running == %{}
    after
      cancel_retries(next)
    end
  end

  test "broad implement continuation passes the actual pending timer callback", context do
    %{issue: issue, workspace: workspace, state: state} = context

    entry = %{
      workspace_path: workspace,
      dispatch_stage: "implement",
      turn_count: 1,
      agent_input_tokens: 150_000,
      agent_output_tokens: 0,
      agent_total_tokens: 150_000,
      turn_started_input_tokens: 0,
      last_agent_message: "The change belongs in lib/example.ex."
    }

    assert {:retry, metadata} = RunPolicy.maybe_stop_for_token_budget(issue, entry)
    assert metadata.budget_mode == "broad_implement"

    timer_metadata =
      Map.merge(metadata, %{
        identifier: issue.identifier,
        delay_type: :continuation,
        budget_retry: true
      })

    state = with_pending_timer(%{state | max_concurrent_agents: 0}, issue, timer_metadata)
    assert {:noreply, next} = SymphonyElixir.OrchestratorRetryDriver.run(state, issue.id)

    try do
      assert {:ok, %{stage: "implement", resume_context: %{budget_retry_count: 1}}} =
               RunStateStore.load(workspace)

      assert Map.has_key?(next.retry_attempts, issue.id)
      assert next.running == %{}
    after
      cancel_retries(next)
    end
  end

  test "retry_now remains an explicit authorization to resume blocked", context do
    %{issue: issue, workspace: workspace, state: state} = context

    assert {:ok, _} =
             RunStateStore.transition(workspace, "blocked", %{
               stop_reason: %{code: "environment_blocker"}
             })

    owner = start_control_owner!(%{state | max_concurrent_agents: 0})
    reply = Orchestrator.retry_issue_now(owner, issue.identifier)
    next = GenServer.call(owner, :runtime)

    try do
      assert reply.ok
      assert reply.action == "retry_now"
      assert reply.dispatch_outcome == "deferred"
      assert {:ok, %{stage: "implement", stop_reason: nil}} = RunStateStore.load(workspace)
      assert next.running == %{}
    after
      cancel_retries(next)
    end
  end

  test "passive checkpoint repaired to checkout uses AgentRunner hook and pre-run guard",
       context do
    %{issue: issue, workspace: workspace, state: state} = context
    assert {:ok, _} = RunStateStore.transition(workspace, "await_checks", %{})
    next = dispatch_through_real_starters(state, issue, &LeaseManager.acquire/3, true)

    try do
      assert %{dispatch_stage: "checkout", pid: pid, ref: ref} = next.running[issue.id]
      refute Map.has_key?(next.running[issue.id], :passive?)
      assert_receive {:authorize_dispatch, _, _, ^pid} = authorization
      assert {:noreply, authorized} = Orchestrator.handle_info(authorization, next)

      deadline = System.monotonic_time(:millisecond) + 5_000
      {down, before_down} = await_worker_down(authorized, pid, ref, deadline)
      assert {:DOWN, ^ref, :process, ^pid, :normal} = down
      assert {:noreply, finished} = Orchestrator.handle_info(down, before_down)
      cancel_retries(finished)
      assert File.exists?(Path.join(workspace, ".symphony/before-run-seen"))
      refute File.exists?(Path.join(workspace, ".symphony/provider-invoked"))

      assert {:ok, %{stage: "blocked", stop_reason: %{code: "missing_checkout"}}} =
               RunStateStore.load(workspace)
    after
      stop_workers(next)
    end
  end

  test "passive repair revalidates terminal tracker state before active starter", context do
    %{issue: issue, workspace: workspace, state: state} = context
    assert {:ok, _} = RunStateStore.transition(workspace, "await_checks", %{})

    acquire = fn id, identifier, owner ->
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Done"}])
      LeaseManager.acquire(id, identifier, owner)
    end

    next = dispatch_through_real_starters(state, issue, acquire, false)

    try do
      assert next.running == %{}
      assert next.retry_attempts == %{}
      assert next.candidate_fetch_error == {:dispatch_no_longer_eligible, issue.id}
      assert {:error, :missing} = LeaseManager.read(issue.id)
      refute File.exists?(Path.join(workspace, ".symphony/before-run-seen"))
    after
      stop_workers(next)
    end
  end

  test "active checkpoint recovered from merged PR uses the passive starter", context do
    %{issue: issue, workspace: workspace, state: state, bin: bin} = context

    for args <- [["init", "-q"], ["checkout", "-q", "-b", "fixture-main"]] do
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

    File.write!(
      Path.join(bin, "gh"),
      "#!/bin/sh\nprintf '%s\\n' '{\"url\":\"https://example.invalid/pr/1\",\"state\":\"MERGED\",\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n"
    )

    next = dispatch_through_real_starters(state, issue, &LeaseManager.acquire/3, false)

    try do
      assert %{passive?: true, dispatch_stage: "post_merge"} = next.running[issue.id]
    after
      stop_workers(next)
    end
  end

  test "review continuation does not mutate a checkpoint leased by another owner", context do
    %{issue: issue, workspace: workspace, state: state} = context
    state = review_timer_state(state, issue, workspace)
    assert {:ok, _foreign} = LeaseManager.acquire(issue.id, issue.identifier, "other-owner")
    snapshot_bytes = File.read!(RunStateStore.state_path(workspace))
    lease_bytes = File.read!(LeaseManager.lease_path(issue.id))
    assert {:noreply, next} = SymphonyElixir.OrchestratorRetryDriver.run(state, issue.id)

    try do
      assert File.read!(RunStateStore.state_path(workspace)) == snapshot_bytes
      assert File.read!(LeaseManager.lease_path(issue.id)) == lease_bytes
      assert next.candidate_fetch_error == {:retry_resume_lease_failed, issue.id, :claimed}
      assert next.running == %{}
      assert Map.has_key?(next.retry_attempts, issue.id)
      refute_received {:memory_tracker_state_update, _, _}
    after
      cancel_retries(next)
    end
  end

  test "review continuation rechecks authorization after waiting to acquire ownership", context do
    %{issue: issue, workspace: workspace, state: state} = context
    state = review_timer_state(state, issue, workspace)
    id = issue.id
    lock_path = LeaseManager.lease_path(id) <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))
    File.mkdir!(lock_path)
    parent = self()

    {:ok, worker} = SymphonyElixir.OrchestratorRetryDriver.start_link(state, id, parent)
    Process.unlink(worker)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    mfa = {LeaseManager, :acquire, 4}
    {:match_spec, previous_pattern} = :erlang.trace_info(mfa, :match_spec)
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(worker, true, [:call])

    try do
      send(worker, :run)
      # This is the real public callback, held at the existing file lock after
      # its initial eligible read. No test-specific product API is introduced.
      assert_receive {:trace, ^worker, :call, {LeaseManager, :acquire, [^id, _, _, _]}}, 5_000

      assert {:ok, _} =
               RunStateStore.transition(workspace, "blocked", %{
                 stop_reason: %{code: "missing_checkout", rule_id: "checkout.missing_git"},
                 last_rule_id: "checkout.missing_git"
               })

      snapshot_bytes = File.read!(RunStateStore.state_path(workspace))
      File.rmdir!(lock_path)
      assert_receive {:timer_result, ^worker, {:noreply, next}}, 5_000

      try do
        assert File.read!(RunStateStore.state_path(workspace)) == snapshot_bytes

        assert next.candidate_fetch_error ==
                 {:persisted_stage_requires_explicit_resume, "blocked"}

        assert next.running == %{}
        assert next.retry_attempts == %{}
        assert {:error, :missing} = LeaseManager.read(id)
        refute_received {:memory_tracker_state_update, _, _}
      after
        cancel_retries(next)
      end
    after
      :erlang.trace_pattern(mfa, previous_pattern, [:local])
      if Process.alive?(worker), do: Process.exit(worker, :kill)

      case File.rmdir(lock_path) do
        :ok ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          raise File.Error, reason: reason, action: "release test lease lock", path: lock_path
      end
    end
  end

  test "review continuation retains exact custody while waiting for capacity", context do
    %{issue: issue, workspace: workspace, state: state} = context
    state = review_timer_state(state, issue, workspace)
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)
    state = with_custody(state, issue, acquired)
    assert {:ok, lease} = LeaseManager.read(issue.id)

    assert {:ok, _} =
             RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(lease))

    state = %{state | claimed: MapSet.new([issue.id])}
    assert {:noreply, next} = SymphonyElixir.OrchestratorRetryDriver.run(state, issue.id)

    try do
      assert {:ok, %{stage: "implement", lease_owner: owner, lease_generation: generation}} = RunStateStore.load(workspace)
      assert owner == state.lease_owner
      assert generation == acquired.token.lease_generation
      assert {:ok, current} = LeaseManager.read_at(acquired.token.storage)
      assert current["lease_generation"] == generation
      assert next.lease_claims[issue.id].token == acquired.token
      assert next.lease_claims[issue.id].holder == :retry
      assert MapSet.member?(next.claimed, issue.id)
      assert Map.has_key?(next.retry_attempts, issue.id)
      assert next.running == %{}
    after
      cancel_retries(next)
    end
  end

  test "review retry after root change cannot resume a destination outside its captured custody", context do
    %{issue: issue, workspace: workspace, state: state, root: root} = context
    state = review_timer_state(state, issue, workspace)
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)
    state = with_custody(state, issue, acquired)
    old_snapshot = File.read!(RunStateStore.state_path(workspace))
    assert {:ok, workflow} = Workflow.current()
    config = put_in(workflow.config, ["workspace", "root"], Path.join(root, "other-root"))
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\n" <> workflow.prompt)
    assert :ok = WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "other-logs/symphony.log"))
    destination = Workspace.path_for_issue(issue)
    File.mkdir_p!(destination)
    assert {:ok, checkpoint} = RunStateStore.load(workspace)
    assert :ok = RunStateStore.save(destination, checkpoint)
    assert {:ok, successor} = LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)
    assert {:ok, _} = RunStateStore.sync_lease(destination, issue, LeaseManager.snapshot_for_state(successor.lease))
    snapshot = File.read!(RunStateStore.state_path(destination))
    lease = File.read!(successor.token.storage.lease_path)
    ledger = File.read(successor.token.storage.ledger_path)
    assert {:noreply, next} = SymphonyElixir.OrchestratorRetryDriver.run(state, issue.id)
    assert next.candidate_fetch_error == :lease_workspace_changed
    assert next.running == %{}
    assert next.retry_attempts == %{}
    assert next.lease_claims == %{}
    assert {:error, :missing} = LeaseManager.read_at(acquired.token.storage)
    assert File.read!(RunStateStore.state_path(workspace)) == old_snapshot
    assert File.read!(RunStateStore.state_path(destination)) == snapshot
    assert File.read!(successor.token.storage.lease_path) == lease
    assert File.read(successor.token.storage.ledger_path) == ledger
    assert File.read!(acquired.token.storage.ledger_path) =~ "lease.released"
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "review resume with one available slot does not count its own acquired reservation", context do
    %{issue: issue, workspace: workspace, state: state} = context
    state = review_timer_state(state, issue, workspace)
    state = with_pending_timer(%{state | max_concurrent_agents: 1}, issue, state.retry_attempts[issue.id])
    {:ok, driver} = SymphonyElixir.OrchestratorRetryDriver.start_link(state, issue.id)
    Process.unlink(driver)

    on_exit(fn ->
      if Process.alive?(driver) do
        current = GenServer.call(driver, :runtime)
        GenServer.stop(driver)
        stop_workers(current)
      end
    end)

    send(driver, :run)
    assert_receive {:timer_result, ^driver, {:noreply, admitted}}, 5_000
    assert %{pid: worker, dispatch_ticket: ticket} = admitted.running[issue.id]
    assert is_pid(worker)
    assert admitted.lease_claims[issue.id].holder == :gated
    refute Map.has_key?(admitted.retry_attempts, issue.id)
    assert Enum.any?(RunLedger.recent_entries(), &(&1["event_type"] == "dispatch.started" and get_in(&1, ["metadata", "dispatch_id"]) == ticket.dispatch_id))
    assert {:ok, snapshot} = RunStateStore.load(workspace)
    assert snapshot.lease_generation == admitted.lease_claims[issue.id].token.lease_generation
  end

  test "review resume retains custody and explicit retry cleanup reports a release failure",
       context do
    %{issue: issue, workspace: workspace, state: state} = context
    state = review_timer_state(state, issue, workspace)
    id = issue.id
    parent = self()
    # Hold the existing public update callback, not a private lock API.
    locker =
      spawn(fn ->
        result =
          RunStateStore.update(workspace, fn snapshot ->
            send(parent, {:snapshot_locked, self()})

            receive do
              :release -> snapshot
            end
          end)

        send(parent, {:snapshot_unlocked, self(), result})
      end)

    on_exit(fn -> if Process.alive?(locker), do: Process.exit(locker, :kill) end)
    assert_receive {:snapshot_locked, ^locker}, 5_000

    {:ok, worker} = SymphonyElixir.OrchestratorRetryDriver.start_link(state, id, parent)
    Process.unlink(worker)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    mfa = {LeaseManager, :acquire, 4}
    {:match_spec, previous_pattern} = :erlang.trace_info(mfa, :match_spec)
    :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(worker, true, [:call])
    lock_path = LeaseManager.lease_path(id) <> ".lock"

    try do
      send(worker, :run)
      assert_receive {:trace, ^worker, :return_from, ^mfa, {:ok, acquired}}, 5_000
      File.mkdir!(lock_path)
      send(locker, :release)
      assert_receive {:snapshot_unlocked, ^locker, {:ok, _}}, 5_000
      assert_receive {:timer_result, ^worker, {:noreply, resumed}}, 5_000
      assert resumed.lease_claims[id].token == acquired.token
      assert resumed.lease_claims[id].holder == :retry

      assert {:error, {:lease_release_failed, ^id, {:lease_lock_timeout, ^lock_path}}, next} =
               Orchestrator.prepare_retry_custody(resumed, id)

      try do
        assert MapSet.member?(next.claimed, id)

        assert next.candidate_fetch_error ==
                 {:lease_release_failed, id, {:lease_lock_timeout, lock_path}}

        assert next.running == %{}
        assert next.retry_attempts == %{}
        assert {:ok, %{"owner" => owner}} = LeaseManager.read(id)
        assert owner == state.lease_owner
      after
        cancel_retries(next)
      end
    after
      :erlang.trace_pattern(mfa, previous_pattern, [:local])
      send(locker, :release)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      if Process.alive?(locker), do: Process.exit(locker, :kill)

      case File.rmdir(lock_path) do
        :ok ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          raise File.Error, reason: reason, action: "release test lease lock", path: lock_path
      end
    end
  end

  defp review_timer_state(state, issue, workspace) do
    claims = %{
      "comment:1" => %{
        "disposition" => "accepted",
        "actionable" => false,
        "implementation_status" => "addressed"
      },
      "comment:2" => %{"disposition" => "accepted", "actionable" => true}
    }

    assert {:ok, _} =
             RunStateStore.transition(workspace, "blocked", %{
               stop_reason: %{
                 code: "per_turn_input_budget_exceeded",
                 rule_id: "budget.per_turn_input_exceeded"
               },
               last_rule_id: "budget.per_turn_input_exceeded",
               review_claims: claims
             })

    metadata =
      Orchestrator.continuation_metadata_for_running_entry_for_test(%{
        identifier: issue.identifier
      })

    assert metadata.delay_type == :continuation

    with_pending_timer(
      %{state | max_concurrent_agents: 0},
      issue,
      Map.put(metadata, :identifier, issue.identifier)
    )
  end

  defp with_pending_timer(state, issue, metadata) do
    # Timer admission reads real configuration; seed its capacity and cached State consistently.
    assert {:ok, workflow} = Workflow.current()
    config = put_in(workflow.config, ["agent", "max_concurrent_agents"], state.max_concurrent_agents)
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\n" <> workflow.prompt)
    assert :ok = WorkflowStore.force_reload()
    retry = Map.merge(metadata, %{attempt: 2, timer_ref: nil, due_at_ms: 0, retry_ref: make_ref(), status: :scheduled})
    %{state | retry_attempts: %{issue.id => retry}}
  end

  defp cancel_retries(state) do
    Enum.each(state.retry_attempts, fn {_id, retry} ->
      if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref)
    end)
  end

  defp stop_workers(state) do
    cancel_retries(state)

    Enum.each(state.running, fn {_id, %{pid: pid, ref: ref}} ->
      case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
        :ok -> :ok
        {:error, :not_found} -> if Process.alive?(pid), do: Process.exit(pid, :kill)
      end

      Process.demonitor(ref, [:flush])
    end)
  end

  defp await_worker_down(state, pid, ref, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: flunk("worker did not finish within 2000ms")

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} = down ->
        {down, state}

      {:"$gen_call", from, message} ->
        assert {:reply, reply, next} = Orchestrator.handle_call(message, from, state)
        GenServer.reply(from, reply)
        await_worker_down(next, pid, ref, deadline)

      message ->
        assert {:noreply, next} = Orchestrator.handle_info(message, state)
        await_worker_down(next, pid, ref, deadline)
    after
      remaining -> flunk("worker did not finish within 2000ms")
    end
  end

  defp dispatch_through_real_starters(state, issue, acquire, execute_job?) do
    start_child = fn supervisor, job ->
      if execute_job?,
        do: Task.Supervisor.start_child(supervisor, job),
        else:
          {:ok,
           spawn(fn ->
             receive do
               :finish -> :ok
             end
           end)}
    end

    starter = fn state, issue, attempt, recipient ->
      Orchestrator.do_spawn_issue_worker_for_test(state, issue, attempt, recipient, start_child_fun: start_child)
    end

    passive_starter = fn state, issue, attempt, recipient ->
      Orchestrator.do_spawn_passive_worker_for_test(state, issue, attempt, recipient, start_child_fun: start_child)
    end

    active = fn state, issue, attempt ->
      Orchestrator.dispatch_issue_for_test(state, issue,
        attempt: attempt,
        issue_fetcher: fn [_] -> {:ok, [issue]} end,
        dispatch_fun: fn state, issue, attempt ->
          Orchestrator.do_dispatch_issue_for_test(state, issue, attempt,
            acquire_fun: acquire,
            spawn_fun: starter
          )
        end
      )
    end

    passive = fn state, issue, attempt ->
      Orchestrator.dispatch_passive_issue_for_test(state, issue,
        attempt: attempt,
        acquire_fun: acquire,
        spawn_fun: passive_starter
      )
    end

    state =
      Orchestrator.dispatch_runtime_issue_for_test(state, issue, nil,
        active_dispatch_fun: active,
        passive_dispatch_fun: passive
      )

    await_promotion(state)
  end

  defp await_promotion(%{admission_read: %{purpose: :promotion, ref: ref, monitor: monitor}} = state) do
    receive do
      {:tracker_read_result, ^ref, _} = result ->
        assert {:noreply, next} = Orchestrator.handle_info(result, state)
        next

      {:DOWN, ^monitor, :process, _, _} = down ->
        assert {:noreply, next} = Orchestrator.handle_info(down, state)
        next
    after
      2_000 -> flunk("promotion reader did not settle")
    end
  end

  defp await_promotion(state), do: state

  defp with_custody(state, issue, acquired) do
    claim = %{
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

    %{state | lease_claims: %{issue.id => claim}, claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp admit_and_release(state, issue) do
    active = fn state, issue, attempt ->
      Orchestrator.do_dispatch_issue_for_test(state, issue, attempt,
        spawn_fun: fn state, _, _, _ ->
          send(self(), :authorized_spawn_boundary)
          state
        end
      )
    end

    admitted =
      Orchestrator.dispatch_runtime_issue_for_test(state, issue, 1,
        active_dispatch_fun: active,
        passive_dispatch_fun: fn _, _, _ -> flunk("unexpected passive branch") end
      )

    assert_received :authorized_spawn_boundary
    assert {:ok, :released} = LeaseManager.release_token(admitted.lease_claims[issue.id].token)
  end

  defp start_control_owner!(state) do
    {:ok, owner} = GenServer.start(ControlDriver, state)

    on_exit(fn ->
      if Process.alive?(owner) do
        assert :ok = :sys.suspend(owner)
        current = :sys.get_state(owner)
        readers = Enum.reject([current.tracker_poll_read, current.admission_read], &is_nil/1)
        workers = Enum.map(current.running, fn {_id, entry} -> entry.pid end)
        monitors = Enum.map(Enum.uniq(Enum.map(readers, & &1.pid) ++ workers), &{&1, Process.monitor(&1)})

        :sys.replace_state(owner, fn runtime ->
          Enum.each(readers, fn reader -> assert :ok = SymphonyElixir.TrackerReader.cancel(reader) end)
          Enum.each(runtime.retry_attempts, fn {_id, retry} -> if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref) end)
          Enum.each(runtime.lease_claims, fn {_id, claim} -> if is_reference(claim[:timer]), do: Process.cancel_timer(claim.timer) end)
          runtime
        end)

        GenServer.stop(owner)
        Enum.each(workers, fn worker -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
        Enum.each(monitors, fn {pid, ref} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000 end)
      end
    end)

    owner
  end
end
