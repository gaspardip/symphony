defmodule SymphonyElixir.TestSupport.StageSessionFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias SymphonyElixir.{AgentProvider, DispatchAudit, RunStateStore, Workflow, WorkflowStore, Workspace}
  alias SymphonyElixir.AgentProvider.{Claude, Codex, CodexCLI}

  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, Orchestrator, RunStateStore, Workspace}

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    @impl true
    def init(observer) do
      runtime = %Orchestrator.State{
        lease_owner: "boundary-#{System.unique_integer([:positive])}",
        max_concurrent_agents: 1,
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
      }

      {:ok, %{runtime: runtime, observer: observer}}
    end

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

    def handle_call({:dispatch, issue}, _from, state) do
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
                      send(observer, {:worker_ready, self(), context, expected})
                      worker_loop()
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

    def handle_call(message, from, state) do
      case Orchestrator.handle_call(message, from, state.runtime) do
        {:reply, reply, runtime} -> {:reply, reply, %{state | runtime: runtime}}
        {:noreply, runtime} -> {:noreply, %{state | runtime: runtime}}
      end
    end

    @impl true
    def handle_info({:DOWN, _, :process, _, _} = message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      send(state.observer, {:worker_down, self(), message, runtime})
      {:noreply, %{state | runtime: runtime}}
    end

    def handle_info(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end

    defp worker_loop do
      receive do
        {:exercise, caller, ref, fun} ->
          result =
            try do
              fun.()
            rescue
              error -> {:fixture_exception, error, __STACKTRACE__}
            catch
              kind, reason -> {:fixture_caught, kind, reason, __STACKTRACE__}
            end

          send(caller, {:exercise_result, ref, result})
          worker_loop()

        :finish ->
          :ok
      end
    end
  end

  def cli_fixture!(plan, implement) do
    root = Path.join(System.tmp_dir!(), "stage-admitted-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    issue = %SymphonyElixir.Linear.Issue{
      id: "stage-#{System.unique_integer([:positive])}",
      identifier: "STAGE-1",
      title: "Account local stage handoff",
      description: "## Acceptance Criteria\n- preserve accounting and effects",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    SymphonyElixir.TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      runner_install_root: Path.join(root, "install"),
      max_concurrent_agents: 1,
      max_turns: 2,
      observability_tracing_enabled: false,
      policy_require_verifier: false,
      hook_after_run: "printf after-run >> '#{root}/hooks'"
    )

    configure!(plan, implement)
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(Path.join(workspace, ".symphony/progress"))
    git = System.find_executable("git")
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/run_state.json\n")
    File.write!(Path.join(workspace, "existing.txt"), "initial\n")
    File.write!(Path.join(workspace, ".symphony/progress/STAGE-1.md"), "## Work Log\n\n## Evidence\n\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Test"],
          ["config", "user.email", "test@example.invalid"],
          ["add", "-A"],
          ["commit", "-qm", "fixture"],
          ["update-ref", "refs/remotes/origin/main", "HEAD"],
          ["checkout", "-qb", SymphonyElixir.GitManager.issue_branch_name(issue)]
        ] do
      assert {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
    end

    commands = Path.join(root, "commands")
    File.write!(commands, "")
    c = %{root: root, workspace: workspace, issue: issue, bin: bin, commands: commands, git: git}
    install_cli!(c, "claude", %{input_tokens: 7, output_tokens: 3})
    install_cli!(c, "codex-cli", %{input_tokens: 21, output_tokens: 9})
    write_script!(Path.join(bin, "gh"), "exit 1\n")
    write_script!(Path.join(bin, "mix"), "exit 0\n")
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert {:ok, _} = RunStateStore.transition(workspace, "plan", %{issue_id: issue.id, issue_identifier: issue.identifier})
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    c
  end

  def start_worker!(c) do
    {:ok, owner} = GenServer.start(Driver, self())
    ExUnit.Callbacks.on_exit(fn -> cleanup_driver!(owner) end)
    entry = GenServer.call(owner, {:dispatch, c.issue}, 10_000)
    assert is_map(entry)
    worker = entry.pid
    assert_receive {:worker_ready, ^worker, context, expected}, 5_000
    assert context == entry.agent_execution.context and expected === entry.agent_execution.expected
    {owner, worker, entry}
  end

  def in_worker(worker, work) do
    ref = make_ref()
    send(worker, {:exercise, self(), ref, work})

    receive do
      {:exercise_result, ^ref, {:fixture_exception, error, stack}} -> reraise error, stack
      {:exercise_result, ^ref, {:fixture_caught, kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
      {:exercise_result, ^ref, result} -> result
    after
      10_000 -> flunk("admitted stage worker did not complete fixture work")
    end
  end

  def runtime(owner), do: GenServer.call(owner, :runtime)
  def registry(owner, c), do: runtime(owner).running[c.issue.id].agent_execution.registry
  def journal_bytes(entry), do: File.read!(Path.join(DispatchAudit.marker_directory(entry.workspace_path), "marker.json"))

  def finish_worker!(owner, worker) do
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, reason}, runtime}, 5_000
    {reason, runtime}
  end

  def trace_sessions(work) do
    patterns = [{AgentProvider, :open_session, 5}, {AgentProvider, :close_session, 3}, {Claude, :stop_session, 1}, {CodexCLI, :stop_session, 1}, {Codex, :stop_session, 1}]
    for {module, _, _} <- patterns, do: Code.ensure_loaded!(module)
    {tracer, monitor} = spawn_monitor(fn -> collect_calls([]) end)

    try do
      for pattern <- patterns, do: assert(:erlang.trace_pattern(pattern, true, [:local]) == 1)
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      result = work.()
      barrier = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^barrier}, 5_000
      send(tracer, {:calls, self()})
      assert_receive {:calls, calls}, 5_000
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
      send(tracer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^tracer, :normal}, 5_000
    end
  end

  def configure!(plan, implement) do
    workflow = Workflow.workflow_file_path()
    current = File.read!(workflow)
    agent = "agent:\n  provider: #{plan}\n  max_concurrent_agents: 1\n  max_turns: 2\n  providers:\n    plan: #{plan}\n    implement: #{implement}\n"
    File.write!(workflow, Regex.replace(~r/agent:\n(?:[ ]+[^\n]*\n)*/, current, agent))
    :ok = WorkflowStore.force_reload()
  end

  defp install_cli!(c, provider, usage) do
    events =
      if provider == "claude",
        do: [%{type: "result", result: "#{provider} change", usage: usage}],
        else: [%{type: "item.completed", item: %{type: "agent_message", text: "#{provider} change"}}, %{type: "turn.completed", usage: usage}]

    body =
      "printf '%s\\n' '#{provider}' >> #{quote_shell(c.commands)}\n" <>
        "printf '%s\\n' '#{provider} change' >> existing.txt\n" <> Enum.map_join(events, "\n", &("printf '%s\\n' " <> quote_shell(Jason.encode!(&1)))) <> "\nexit 0\n"

    write_script!(Path.join(c.bin, if(provider == "claude", do: "claude", else: "codex")), body)
  end

  defp write_script!(path, body) do
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _, :call, call} ->
        collect_calls([call | calls])

      {:calls, owner} ->
        send(owner, {:calls, Enum.reverse(calls)})
        collect_calls(calls)

      :stop ->
        :ok
    end
  end

  defp cleanup_driver!(owner) do
    if Process.alive?(owner) do
      assert :ok = :sys.suspend(owner)
      runtime = :sys.get_state(owner).runtime
      readers = Enum.reject([runtime.tracker_poll_read, runtime.admission_read], &is_nil/1)
      workers = Enum.map(runtime.running, fn {_, entry} -> entry.pid end)
      monitors = Enum.map(Enum.uniq(Enum.map(readers, & &1.pid) ++ workers), &{&1, Process.monitor(&1)})

      :sys.replace_state(owner, fn state ->
        Enum.each(readers, fn reader -> assert :ok = SymphonyElixir.TrackerReader.cancel(reader) end)
        Enum.each(state.runtime.retry_attempts, fn {_, retry} -> if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref) end)
        Enum.each(state.runtime.lease_claims, fn {_, claim} -> if is_reference(claim[:timer]), do: Process.cancel_timer(claim.timer) end)
        state
      end)

      GenServer.stop(owner)
      Enum.each(workers, fn worker -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
      Enum.each(monitors, fn {pid, ref} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000 end)
    end
  end

  def quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
