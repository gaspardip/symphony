defmodule SymphonyElixir.OrchestratorAccountedStopTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, ManualIssueStore, RunLedger, RunStateStore}

  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, Config, DispatchAudit, DispatchGate, Orchestrator, RunStateStore, Workspace}

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    @impl true
    def init(observer) do
      runtime = %Orchestrator.State{
        lease_owner: "accounted-stop-#{System.unique_integer([:positive])}",
        max_concurrent_agents: 1,
        poll_interval_ms: Config.poll_interval_ms(),
        healing_poll_interval_ms: Config.healing_poll_interval_ms(),
        poll_check_in_progress: false,
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
      }

      {:ok, %{runtime: runtime, observer: observer, held_down: nil, hold_down?: false}}
    end

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}
    def handle_call({:hold_down, value}, _from, state), do: {:reply, :ok, %{state | hold_down?: value}}

    def handle_call(:release_down, _from, %{held_down: message} = state) when not is_nil(message) do
      next = consume_down(message, %{state | held_down: nil, hold_down?: false})
      {:reply, :ok, next}
    end

    def handle_call({:dispatch, issue, :real}, _from, state) do
      runtime = Orchestrator.do_dispatch_issue_for_test(state.runtime, issue, nil)
      {:reply, Map.get(runtime.running, issue.id), %{state | runtime: runtime}}
    end

    def handle_call({:dispatch, issue, mode}, _from, state) do
      owner = self()
      observer = state.observer

      start_child = fn supervisor, _job ->
        raw = issue |> Workspace.path_for_issue() |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

        Task.Supervisor.start_child(supervisor, fn ->
          receive do
            {:captured, context, expected} ->
              true = RunStateStore.material_projection(raw) === expected

              result =
                DispatchGate.run(owner, context.ticket.dispatch_id, fn ->
                  DispatchAudit.with_authorization(context.ticket, fn ->
                    AgentExecution.with_context(context.ticket, context.lease_token, owner, raw, fn ->
                      Process.flag(:trap_exit, true)
                      send(observer, {:worker_ready, self(), context, expected})
                      worker_loop(observer, mode)
                    end)
                  end)
                end)

              case result do
                {:stop, {:accounting_uncertain, cause}} -> exit({:accounting_uncertain, cause})
                {:stop, {:stale_execution, ids, cause}} -> exit({:stale_execution, ids, cause})
                other -> other
              end
          end
        end)
      end

      spawn_worker = fn runtime, selected, attempt, recipient ->
        Orchestrator.do_spawn_issue_worker_for_test(runtime, selected, attempt, recipient, start_child_fun: start_child)
      end

      runtime = Orchestrator.do_dispatch_issue_for_test(state.runtime, issue, nil, spawn_fun: spawn_worker)
      entry = Map.get(runtime.running, issue.id)
      if entry, do: send(entry.pid, {:captured, entry.agent_execution.context, entry.agent_execution.expected})
      {:reply, entry, %{state | runtime: runtime}}
    end

    def handle_call({:request_stop, id}, _from, state) do
      runtime = Orchestrator.terminate_running_issue(state.runtime, id, false)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call({:stall_stop, id}, _from, state) do
      runtime = state.runtime
      runtime = put_in(runtime.running[id].started_at, DateTime.add(DateTime.utc_now(), -3_600, :second))
      runtime = Orchestrator.reconcile_stalled_running_issues_for_test(runtime)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call(message, from, state) do
      case Orchestrator.handle_call(message, from, state.runtime) do
        {:reply, reply, runtime} -> {:reply, reply, %{state | runtime: runtime}}
        {:noreply, runtime} -> {:noreply, %{state | runtime: runtime}}
      end
    end

    @impl true
    def handle_info({:DOWN, ref, :process, pid, _reason} = message, state) do
      own_worker? = Enum.any?(state.runtime.running, fn {_id, entry} -> entry.ref == ref and entry.pid == pid end)

      if state.hold_down? and own_worker? do
        send(state.observer, {:down_held, self(), message})
        {:noreply, %{state | held_down: message}}
      else
        {:noreply, consume_down(message, state)}
      end
    end

    def handle_info(
          {:agent_execution_usage, %{context: %{owner: owner, worker: worker, issue_id: issue_id} = context, binding: binding, ordinal: ordinal}, expected, _observation} = message,
          state
        ) do
      previous_total = get_in(state.runtime.running, [issue_id, :agent_total_tokens])
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)

      case Map.get(runtime.running, issue_id) do
        %{
          pid: ^worker,
          ref: ref,
          issue: %{id: ^issue_id},
          agent_total_tokens: 10,
          agent_execution: %{context: ^context, expected: ^expected, registry: %{current: ^binding, ordinal: ^ordinal}}
        }
        when owner == self() and previous_total != 10 ->
          send(state.observer, {:provider_usage_initialized, self(), worker, issue_id, ref, context, System.monotonic_time(:millisecond)})

        _ ->
          :ok
      end

      {:noreply, %{state | runtime: runtime}}
    end

    def handle_info(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end

    defp consume_down(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      send(state.observer, {:worker_down, self(), message, runtime})
      %{state | runtime: runtime}
    end

    defp worker_loop(observer, mode) do
      receive do
        {:exercise, from, ref, fun} ->
          result = fun.()
          send(from, {:exercise_result, ref, result})
          worker_loop(observer, mode)

        {:EXIT, sender, :shutdown} when is_pid(sender) ->
          send(observer, {:shutdown_received, self(), sender})

          if mode == :ignore_shutdown do
            worker_loop(observer, mode)
          else
            send(observer, {:stop_guard, self(), AgentExecution.ensure_current()})
            exit(:shutdown)
          end

        :finish ->
          :ok
      end
    end
  end

  setup do
    pause_default_scheduler!()
    root = Path.join(System.tmp_dir!(), "accounted-stop-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    eof = Path.join(root, "provider-eof")
    started = Path.join(root, "provider-started")
    pid_file = Path.join(root, "provider-pid")
    script = Path.join(bin, "codex")

    File.write!(script, """
    #!/bin/sh
    printf '%s\\n' "$$" > #{quote_shell(pid_file)}
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"stop-thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"stop-turn"}}}'
          printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"stop-thread","tokenUsage":{"total":{"inputTokens":7,"outputTokens":3,"totalTokens":10}}}}'
          printf '%s\\n' "$$" > #{quote_shell(started)}
          ;;
      esac
    done
    printf '%s\\n' "$$" > #{quote_shell(eof)}
    """)

    File.chmod!(script, 0o755)

    for executable <- ["gh", "curl", "ssh"] do
      path = Path.join(bin, executable)
      File.write!(path, "#!/bin/sh\nexit 1\n")
      File.chmod!(path, 0o755)
    end

    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    config = [
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: Path.join(root, "manual"),
      manual_enabled: true,
      runner_install_root: Path.join(root, "runner-install"),
      max_concurrent_agents: 1,
      max_turns: 2,
      poll_interval_ms: 60_000,
      observability_tracing_enabled: false,
      codex_command: quote_shell(script) <> " app-server",
      codex_approval_policy: "never"
    ]

    write_workflow_file!(Workflow.workflow_file_path(), config)
    File.write!(Workflow.workflow_file_path(), String.replace(File.read!(Workflow.workflow_file_path()), "agent:\n", "agent:\n  provider: codex\n"))
    :ok = WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    assert {:ok, issue} =
             ManualIssueStore.submit(%{
               "id" => "accounted-stop",
               "identifier" => "STOP-1",
               "title" => "Accounted stop",
               "acceptance_criteria" => ["close the admitted worker without blocking its owner"]
             })

    assert :ok = ManualIssueStore.update_issue_state(issue.id, "In Progress")
    assert {:ok, issue} = ManualIssueStore.fetch_issue_by_id(issue.id)
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "README.md"), "local stop fixture\n")
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/run_state.json\n")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command: ["/usr/bin/true"]
    validation:
      command: ["/usr/bin/true"]
    smoke:
      command: ["/usr/bin/true"]
    post_merge:
      command: ["/usr/bin/true"]
    artifacts:
      command: ["/usr/bin/true"]
    pull_request:
      required_checks: ["local-check"]
    verification:
      behavioral_proof:
        required: true
        mode: unit_first
        source_paths: ["lib"]
        test_paths: ["test"]
      ui_proof:
        required: false
        mode: local
        source_paths: []
        test_paths: []
        artifact_paths: []
        required_checks: []
        scenarios: []
    """)

    for args <- [["init", "-q", "-b", "main"], ["config", "user.name", "Stop Fixture"], ["config", "user.email", "stop@example.invalid"], ["add", "-A"], ["commit", "-qm", "fixture"]] do
      assert {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    origin = Path.join(root, "origin.git")
    assert {_, 0} = System.cmd("git", ["init", "--bare", "-q", origin], cd: root, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: workspace, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["push", "-q", "origin", "main"], cd: workspace, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["checkout", "-q", "-b", SymphonyElixir.GitManager.issue_branch_name(issue)], cd: workspace, stderr_to_stdout: true)

    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier, issue_source: :manual})
    assert {:ok, true, _} = SymphonyElixir.RepoCompatibility.compatible?(workspace, include_pr_details: false)
    {:ok, owner} = GenServer.start(Driver, self())

    on_exit(fn ->
      if Process.alive?(owner) do
        :ok = :sys.suspend(owner)
        runtime = :sys.get_state(owner)
        monitors = Enum.map(runtime.runtime.running, fn {_id, entry} -> {entry.pid, Process.monitor(entry.pid)} end)
        :ok = GenServer.stop(owner, :normal, 5_000)
        Enum.each(monitors, fn {pid, ref} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000 end)
      end

      if File.exists?(pid_file), do: await!(fn -> transport_absent?(%{pid_file: pid_file, script: script}) end)
      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, issue: issue, owner: owner, started: started, eof: eof, script: script, pid_file: pid_file}
  end

  for {action, public, target} <- [{:pause, :pause_issue, "Paused"}, {:stop, :stop_issue, "Blocked"}, {:hold, :hold_issue_for_human_review, nil}] do
    @tag action: action, public: public, target: target
    test "public #{action} closes a real AppServer without starving its retirement confirmation", c do
      initialization_deadline = System.monotonic_time(:millisecond) + Config.agent_read_timeout_ms()
      entry = dispatch!(c, :real)
      assert entry.agent_execution.expected["stage"] == "implement"
      owner = c.owner
      worker = entry.pid
      issue_id = c.issue.id
      ref = entry.ref
      context = entry.agent_execution.context
      remaining = max(initialization_deadline - System.monotonic_time(:millisecond), 0)
      assert_receive {:provider_usage_initialized, ^owner, ^worker, ^issue_id, ^ref, ^context, initialized_at}, remaining
      assert initialized_at <= initialization_deadline
      await!(fn -> File.exists?(c.started) and get_in(runtime(c).running, [c.issue.id, :agent_total_tokens]) == 10 end)
      assert :ok = GenServer.call(c.owner, {:hold_down, true})
      before_call = System.monotonic_time(:millisecond)
      assert %{ok: true} = reply = apply(Orchestrator, c.public, [c.owner, c.issue.identifier])
      assert System.monotonic_time(:millisecond) - before_call < 5_000
      if c.target, do: assert(reply.state == c.target)
      assert {:ok, issue} = ManualIssueStore.fetch_issue_by_id(c.issue.id)
      assert issue.state == reply.state
      worker = entry.pid
      owner = c.owner
      ref = entry.ref
      assert_receive {:down_held, ^owner, {:DOWN, ^ref, :process, ^worker, :shutdown}}, 5_000
      await!(fn -> File.exists?(c.eof) end)
      assert File.read!(c.eof) == File.read!(c.started)
      await!(fn -> transport_absent?(c) end)
      waiting = runtime(c)
      assert waiting.running[c.issue.id].pid == worker
      assert waiting.lease_claims[c.issue.id].token == entry.lease_token
      assert :ok = LeaseManager.ensure_current(entry.lease_token)
      assert events(c, "dispatch.finished") == []
      assert :ok = GenServer.call(c.owner, :release_down)
      stopped = runtime(c)
      assert stopped.running == %{}
      assert stopped.token_usage_errors == %{} and stopped.stale_execution_errors == %{}
      assert stopped.agent_totals.total_tokens == 10
      assert stopped.retry_attempts == %{}
      refute Map.has_key?(stopped.lease_claims, c.issue.id)
      assert {:error, :missing} = LeaseManager.read(c.issue.id)
      assert [finished] = events(c, "dispatch.finished")
      assert finished["metadata"]["dispatch_id"] == entry.dispatch_ticket.dispatch_id
      assert finished["metadata"]["outcome"] == inspect({:exit, :shutdown})
      assert [_released] = events(c, "lease.released")
    end
  end

  test "one grace deadline survives repeated stops; only real expiry kills its original worker", c do
    entry = dispatch!(c, :ignore_shutdown)
    before = System.monotonic_time(:millisecond)
    first = GenServer.call(c.owner, {:request_stop, c.issue.id}, 500)
    after_call = System.monotonic_time(:millisecond)
    shutdown = first.running[c.issue.id].execution_stop_requested.shutdown
    assert shutdown.deadline >= before + 5_000 and shutdown.deadline <= after_call + 5_000
    assert is_reference(shutdown.ref) and is_reference(shutdown.timer)
    worker = entry.pid
    owner = c.owner
    assert_receive {:shutdown_received, ^worker, ^owner}, 1_000
    assert :ok = GenServer.call(c.owner, {:hold_down, true})
    bytes = marker!(entry)
    send(c.owner, deadline_message(entry, shutdown))
    current = GenServer.call(c.owner, {:request_stop, c.issue.id}, 500)
    assert current.running[c.issue.id].execution_stop_requested.shutdown == shutdown
    assert Process.alive?(worker)
    assert marker!(entry) == bytes
    assert :ok = LeaseManager.ensure_current(entry.lease_token)
    refute_receive {:shutdown_received, ^worker, ^owner}, 20
    ref = entry.ref
    assert_receive {:down_held, ^owner, {:DOWN, ^ref, :process, ^worker, :killed}}, 6_000
    assert System.monotonic_time(:millisecond) >= shutdown.deadline
    assert runtime(c).running[c.issue.id].execution_stop_requested.shutdown.kill_sent?
    assert events(c, "dispatch.finished") == []
    assert :ok = LeaseManager.ensure_current(entry.lease_token)
    assert :ok = GenServer.call(c.owner, :release_down)
    assert [finished] = events(c, "dispatch.finished")
    assert finished["metadata"]["outcome"] == inspect({:exit, :killed})
    assert runtime(c).running == %{}
  end

  test "old deadline context, monitor and stop ref cannot signal a replacement", c do
    old = dispatch!(c, :cooperative)
    requested = GenServer.call(c.owner, {:request_stop, c.issue.id}, 500)
    old_shutdown = requested.running[c.issue.id].execution_stop_requested.shutdown
    await!(fn -> runtime(c).running == %{} end)
    assert Process.read_timer(old_shutdown.timer) == false
    fresh = dispatch!(c, :ignore_shutdown)
    fresh_state = runtime(c)
    bytes = marker!(fresh)
    send(c.owner, deadline_message(old, old_shutdown))
    send(c.owner, {:DOWN, old.ref, :process, old.pid, :shutdown})
    send(c.owner, {:accounted_worker_stop_deadline, fresh.agent_execution.context, old.ref, old_shutdown.ref})
    after_messages = runtime(c)
    assert after_messages.running[c.issue.id] == fresh_state.running[c.issue.id]
    assert after_messages.lease_claims[c.issue.id] == fresh_state.lease_claims[c.issue.id]
    assert Process.alive?(fresh.pid)
    assert marker!(fresh) == bytes
    assert :ok = LeaseManager.ensure_current(fresh.lease_token)
    fresh_pid = fresh.pid
    refute_received {:shutdown_received, ^fresh_pid, _}
  end

  test "closing audit failure retains the captured claim after the genuine DOWN", c do
    entry = dispatch!(c, :cooperative)
    assert :ok = GenServer.call(c.owner, {:hold_down, true})
    GenServer.call(c.owner, {:request_stop, c.issue.id}, 500)
    worker = entry.pid
    owner = c.owner
    assert_receive {:down_held, ^owner, {:DOWN, _, :process, ^worker, :shutdown}}, 1_000
    bytes = marker!(entry)
    unexpected = Path.join(DispatchAudit.marker_directory(c.workspace), "unexpected")
    File.write!(unexpected, "keep audit evidence")
    claim = runtime(c).lease_claims[c.issue.id]
    assert :ok = GenServer.call(c.owner, :release_down)
    held = runtime(c)
    assert held.running == %{}
    assert held.lease_claims[c.issue.id] == claim
    assert held.retry_attempts == %{}
    assert held.token_usage_errors[c.issue.id] == {:accounting_uncertain, %{context: entry.agent_execution.context, cause: :dispatch_audit_unexpected_files}}
    assert held.stale_execution_errors == %{}
    assert marker!(entry) == bytes
    assert File.read!(unexpected) == "keep audit evidence"
    assert events(c, "dispatch.finished") == []
    assert :ok = LeaseManager.ensure_current(entry.lease_token)
  end

  test "first accounting cause is retained during cooperative shutdown", c do
    entry = dispatch!(c, :cooperative)
    assert {:stop, {:accounting_uncertain, :original_stop_failure}} = in_worker(entry.pid, fn -> AgentExecution.fail(:original_stop_failure) end)
    await!(fn -> Map.has_key?(runtime(c).token_usage_errors, c.issue.id) end)
    before = runtime(c)
    bytes = marker!(entry)
    GenServer.call(c.owner, {:request_stop, c.issue.id}, 500)
    worker = entry.pid
    assert_receive {:stop_guard, ^worker, {:stop, {:accounting_uncertain, :original_stop_failure}}}, 1_000
    await!(fn -> runtime(c).running == %{} end)
    stopped = runtime(c)
    assert stopped.token_usage_errors == before.token_usage_errors
    assert stopped.lease_claims == before.lease_claims
    assert stopped.retry_attempts == %{}
    assert stopped.agent_totals.total_tokens == 0
    assert marker!(entry) == bytes
    assert events(c, "dispatch.finished") == []
  end

  test "stall retry stays deferred until DOWN and an explicit stop removes that retry without restarting grace", c do
    entry = dispatch!(c, :ignore_shutdown)
    first = GenServer.call(c.owner, {:stall_stop, c.issue.id}, 500)
    request = first.running[c.issue.id].execution_stop_requested
    assert request.retry.metadata.error =~ "stalled for "
    assert first.retry_attempts == %{}
    second = GenServer.call(c.owner, {:request_stop, c.issue.id}, 500)
    assert second.running[c.issue.id].execution_stop_requested.shutdown == request.shutdown
    refute Map.has_key?(second.running[c.issue.id].execution_stop_requested, :retry)
    assert second.retry_attempts == %{}
    assert :ok = LeaseManager.ensure_current(entry.lease_token)
    send(entry.pid, :finish)
    await!(fn -> runtime(c).running == %{} end)
    assert runtime(c).retry_attempts == %{}
    assert [_finished] = events(c, "dispatch.finished")
  end

  for stage <- ["blocked", "done"] do
    @tag terminal_stage: stage
    test "own #{stage} stays terminal when an explicit stop requests shutdown", c do
      entry = dispatch!(c, :cooperative)
      assert {:ok, _} = in_worker(entry.pid, fn -> AgentExecution.transition_current(c.terminal_stage, %{}) end)
      before = runtime(c)
      known = before.running[c.issue.id].agent_execution.known_terminal
      raw = File.read!(RunStateStore.state_path(c.workspace))
      assert known.stage == c.terminal_stage
      GenServer.call(c.owner, {:request_stop, c.issue.id}, 500)
      worker = entry.pid
      assert_receive {:stop_guard, ^worker, {:stop, {:execution_stopped, %{stage: stage}}}}, 1_000
      assert stage == c.terminal_stage
      await!(fn -> runtime(c).running == %{} end)
      stopped = runtime(c)
      assert stopped.token_usage_errors == %{} and stopped.stale_execution_errors == %{}
      assert stopped.retry_attempts == %{}
      refute Map.has_key?(stopped.completed, c.issue.id)
      assert File.read!(RunStateStore.state_path(c.workspace)) == raw
      assert [finished] = events(c, "dispatch.finished")
      assert finished["metadata"]["outcome"] == inspect({:exit, :shutdown})
      assert {:error, :missing} = LeaseManager.read(c.issue.id)
    end
  end

  test "a physical lease successor survives the old worker stop and DOWN", c do
    entry = dispatch!(c, :cooperative)
    assert :ok = GenServer.call(c.owner, {:hold_down, true})
    GenServer.call(c.owner, {:request_stop, c.issue.id}, 500)
    worker = entry.pid
    owner = c.owner
    assert_receive {:down_held, ^owner, {:DOWN, _, :process, ^worker, :shutdown}}, 1_000
    claim = runtime(c).lease_claims[c.issue.id]
    journal = marker!(entry)
    assert {:ok, :released} = LeaseManager.release_token(entry.lease_token)
    assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, entry.lease_token.owner)
    refute successor.token.lease_generation == entry.lease_token.lease_generation
    bytes = File.read!(successor.token.storage.lease_path)
    assert :ok = GenServer.call(c.owner, :release_down)
    stopped = runtime(c)
    assert stopped.running == %{} and stopped.retry_attempts == %{}
    assert stopped.lease_claims[c.issue.id] == claim
    ids = %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
    assert stopped.stale_execution_errors[c.issue.id] == %{context: entry.agent_execution.context, ids: ids, cause: :lease_token_mismatch}
    assert stopped.token_usage_errors == %{}
    assert marker!(entry) == journal
    assert File.read!(successor.token.storage.lease_path) == bytes
    assert :ok = LeaseManager.ensure_current(successor.token)
    assert events(c, "dispatch.finished") == []
  end

  test "caller death and its expired control ref do not revoke an accepted physical stop", c do
    entry = dispatch!(c, :ignore_shutdown)
    observer = self()
    request = %{ref: make_ref(), action: :pause, identifier: c.issue.identifier, args: [], deadline: System.monotonic_time(:millisecond) + 1_000}
    {caller, caller_ref} = spawn_monitor(fn -> send(observer, {:caller_reply, GenServer.call(c.owner, {:control, request}, 1_000)}) end)
    assert_receive {:caller_reply, %{ok: true, action: "pause"}}, 1_000
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 1_000
    accepted = runtime(c)
    shutdown = accepted.running[c.issue.id].execution_stop_requested.shutdown
    assert Process.alive?(entry.pid)
    wait = max(0, request.deadline - System.monotonic_time(:millisecond))

    receive do
      {:caller_reply, other} -> flunk("unexpected duplicate caller reply: #{inspect(other)}")
    after
      wait -> :ok
    end

    send(c.owner, {:control_timeout, request.ref})
    after_timeout = runtime(c)
    assert after_timeout.running[c.issue.id].execution_stop_requested.shutdown == shutdown
    assert after_timeout.lease_claims[c.issue.id] == accepted.lease_claims[c.issue.id]
    assert Process.alive?(entry.pid)
    assert events(c, "dispatch.finished") == []
    send(entry.pid, :finish)
    await!(fn -> runtime(c).running == %{} end)
    assert [_finished] = events(c, "dispatch.finished")
    assert {:error, :missing} = LeaseManager.read(c.issue.id)
    refute_received {:caller_reply, _}
  end

  defp dispatch!(c, mode) do
    entry = GenServer.call(c.owner, {:dispatch, c.issue, mode}, 10_000)
    assert is_map(entry)

    if mode != :real do
      worker = entry.pid
      assert_receive {:worker_ready, ^worker, context, expected}, 5_000
      assert context == entry.agent_execution.context
      assert expected === entry.agent_execution.expected
    end

    entry
  end

  defp in_worker(worker, fun) do
    ref = make_ref()
    send(worker, {:exercise, self(), ref, fun})
    assert_receive {:exercise_result, ^ref, result}, 1_000
    result
  end

  defp runtime(c), do: GenServer.call(c.owner, :runtime, 500)
  defp marker!(entry), do: File.read!(Path.join(DispatchAudit.marker_directory(entry.workspace_path), "marker.json"))
  defp events(c, type), do: Enum.filter(RunLedger.recent_entries(500), &(&1["issue_id"] == c.issue.id and &1["event_type"] == type))
  defp deadline_message(entry, shutdown), do: {:accounted_worker_stop_deadline, entry.agent_execution.context, entry.ref, shutdown.ref}
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp transport_absent?(c) do
    pid = c.pid_file |> File.read!() |> String.trim()

    case System.cmd("/bin/ps", ["-p", pid, "-o", "command="], stderr_to_stdout: true) do
      {"", 1} -> true
      {command, 0} -> not String.contains?(command, c.script)
      other -> flunk("unexpected own transport lookup: #{inspect(other)}")
    end
  end

  defp await!(predicate, attempts \\ 200)

  defp await!(predicate, attempts) when attempts > 0 do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await!(predicate, attempts - 1)
        )
  end

  defp await!(_predicate, 0), do: flunk("accounted stop observation did not settle")

  defp pause_default_scheduler! do
    if owner = Process.whereis(Orchestrator) do
      await!(fn ->
        state = :sys.get_state(owner, 500)

        state.running == %{} and is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and is_nil(state.admission_read) and state.tracker_poll_pending == [] and
          not state.poll_check_in_progress
      end)

      assert :ok = :sys.suspend(owner)
      on_exit(fn -> assert :ok = :sys.resume(owner) end)
    end
  end
end
