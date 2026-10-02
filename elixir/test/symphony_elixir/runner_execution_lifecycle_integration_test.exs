defmodule SymphonyElixir.RunnerExecutionLifecycleIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunLedger, RunStateStore, VerifierRunner}
  alias SymphonyElixir.AgentProvider.Codex

  # Real Orchestrator admission/handlers. The only worker substitution is the
  # existing controlled-worker pattern, so public runners execute in its scope.
  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, Orchestrator, RunStateStore, Workspace}

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    @impl true
    def init(observer) do
      runtime = %Orchestrator.State{
        lease_owner: "lifecycle-#{System.unique_integer([:positive])}",
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
      {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      {:reply, reply, %{state | runtime: runtime}}
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

  setup do
    root = Path.join(System.tmp_dir!(), "public-lifecycle-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    issue = %Issue{
      id: "lifecycle-#{System.unique_integer([:positive])}",
      identifier: "LIFE-1",
      title: "Public lifecycle",
      description: "## Acceptance Criteria\n- preserve the accepted result",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    after_marker = Path.join(root, "after-run")
    before_marker = Path.join(root, "before-run")
    commands = Path.join(root, "commands")
    replies = Path.join(root, "replies.jsonl")
    File.write!(commands, "")
    File.write!(replies, "")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      runner_install_root: Path.join(root, "runner-install"),
      max_concurrent_agents: 1,
      max_turns: 2,
      observability_tracing_enabled: false,
      codex_command: quote_shell(Path.join(bin, "codex")) <> " app-server",
      codex_approval_policy: "never",
      hook_before_run: "touch #{quote_shell(before_marker)}",
      hook_after_run: "touch #{quote_shell(after_marker)}; exit 17"
    )

    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "agent:\n", "agent:\n  provider: codex\n"))
    :ok = WorkflowStore.force_reload()
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "README.md"), "local fixture\n")
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

    git = System.find_executable("git")

    for args <- [["init", "-q", "-b", "main"], ["config", "user.name", "Lifecycle Fixture"], ["config", "user.email", "lifecycle@example.invalid"], ["add", "-A"], ["commit", "-qm", "fixture"]] do
      assert {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
    end

    origin = Path.join(root, "origin.git")
    assert {_, 0} = System.cmd(git, ["clone", "--bare", workspace, origin], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(git, ["remote", "add", "origin", origin], cd: workspace)
    assert {_, 0} = System.cmd(git, ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)
    script!(Path.join(bin, "git"), "printf 'git %s\\n' \"$*\" >> #{quote_shell(commands)}\nexec #{quote_shell(git)} \"$@\"\n")
    script!(Path.join(bin, "gh"), "exit 1\n")
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    assert {:ok, true, _} = SymphonyElixir.RepoCompatibility.compatible?(workspace, include_pr_details: false)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, bin: bin, commands: commands, replies: replies, after_marker: after_marker, before_marker: before_marker}
  end

  test "public AgentRunner keeps real Delivery done and suppresses the failing after_run hook", c do
    {owner, worker, entry} = start_worker(c)
    issue = c.issue
    issue_id = issue.id

    assert {:done, ^issue} =
             in_worker(worker, fn ->
               assert {:ok, _} = AgentExecution.transition_current("post_merge", %{})
               AgentRunner.run(issue, nil, include_pr_details: false)
             end)

    assert File.exists?(c.before_marker)
    refute File.exists?(c.after_marker)
    assert_received {:memory_tracker_state_update, ^issue_id, "Done"}
    refute_received {:memory_tracker_state_update, ^issue_id, "Done"}
    runtime = GenServer.call(owner, :runtime)
    assert runtime.running[issue.id].agent_execution.known_terminal.stage == "done"
    assert raw!(c)["stage"] == "done"
    assert :ok = LeaseManager.ensure_current(entry.lease_token)
    assert finish_events(c) == []
    send(worker, :finish)
    ref = entry.ref
    assert_receive {:worker_down, ^owner, {:DOWN, ^ref, :process, ^worker, :normal}, stopped}, 5_000
    assert Map.has_key?(stopped.completed, issue.id)
    assert stopped.token_usage_errors == %{} and stopped.stale_execution_errors == %{}
    refute Map.has_key?(stopped.lease_claims, issue.id)
    refute Map.has_key?(stopped.retry_attempts, issue.id)
    assert [event] = finish_events(c)
    assert event["metadata"]["dispatch_id"] == entry.dispatch_ticket.dispatch_id
    assert event["metadata"]["outcome"] == inspect(:normal)
    refute File.exists?(c.after_marker)
    refute File.read!(c.commands) =~ "transport"
  end

  for mode <- [:healthy, :control_after_report] do
    @tag verifier_mode: mode
    test "public audited verifier #{mode} closes its real AppServer port exactly once", c do
      app_server!(c)
      {owner, worker, entry} = start_worker(c)
      observer = self()
      telemetry_id = {__MODULE__, make_ref()}

      assert :ok =
               :telemetry.attach(
                 telemetry_id,
                 [:symphony, :verifier, :completed],
                 fn _event, _, metadata, pid ->
                   send(pid, {:verifier_completed, metadata})
                 end,
                 observer
               )

      on_exit(fn -> :telemetry.detach(telemetry_id) end)

      {result, [closed_port]} =
        trace_stops(worker, fn ->
          in_worker(worker, fn ->
            assert {:ok, state} = AgentExecution.ensure_current()
            inspection = RunInspector.inspect(c.workspace, include_pr_details: false)
            validation = RunInspector.run_validation(c.workspace, inspection.harness)
            assert validation.status == :passed
            assert :ok = AgentExecution.observe_validation(c.workspace, validation)

            result =
              VerifierRunner.verify(c.workspace, c.issue, state, inspection,
                include_pr_details: false,
                on_message: fn update ->
                  send(observer, {:verifier_callback, self(), update.event})

                  if update.event == :tool_call_completed do
                    assert get_in(update, [:payload, "params", "tool"]) == "report_verifier_result"
                    assert %SymphonyElixir.VerifierResult{verdict: :pass} = Process.get({:symphony_verifier_result, c.issue.id})
                    {:links, links} = Process.info(self(), :links)
                    [port] = Enum.filter(links, &is_port/1)
                    refute is_nil(Port.info(port))
                    send(observer, {:live_provider_port, port})

                    if c.verifier_mode == :control_after_report do
                      assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "operator-control"))
                      send(observer, {:control_evidence, evidence(c, entry)})
                    end
                  end

                  :ok
                end
              )

            assert Process.get({:symphony_verifier_result, c.issue.id}) == nil
            result
          end)
        end)

      assert_receive {:live_provider_port, ^closed_port}, 1_000
      assert Port.info(closed_port) == nil
      assert_receive {:verifier_callback, ^worker, :tool_call_completed}, 1_000
      [reply] = c.replies |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      assert %{"id" => 72, "result" => %{"success" => true, "contentItems" => [%{"text" => "verifier result recorded"}]}} = reply
      assert {:ok, %{token_usage: %{input_tokens: 7, output_tokens: 3, total_tokens: 10}}} = RunStateStore.load(c.workspace)
      runtime = GenServer.call(owner, :runtime)
      registry = runtime.running[c.issue.id].agent_execution.registry
      assert runtime.agent_totals.total_tokens == 10
      assert registry.uncertain == nil
      assert runtime.token_usage_errors == %{}
      refute File.exists?(c.after_marker)

      case c.verifier_mode do
        :healthy ->
          assert result.verdict == "pass"
          assert result.summary == "real local verifier report"
          assert_receive {:verifier_callback, ^worker, :turn_completed}, 1_000
          assert_receive {:verifier_completed, %{issue_identifier: "LIFE-1", verdict: "pass"}}, 1_000
          refute_received {:verifier_completed, _}
          assert registry.current == nil
          assert Map.has_key?(registry.retired, {Codex, :thread, "lifecycle-thread"})
          assert runtime.stale_execution_errors == %{}

        :control_after_report ->
          ids = %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
          assert result == {:stop, {:stale_execution, ids, :material_state_changed}}
          refute_received {:verifier_callback, ^worker, :turn_completed}
          refute_received {:verifier_completed, _}
          assert_receive {:control_evidence, before}, 1_000
          assert evidence(c, entry) == before
          assert runtime.stale_execution_errors[c.issue.id].cause == :material_state_changed
          assert runtime.lease_claims[c.issue.id].token == entry.lease_token
          assert registry.current == {Codex, :thread, "lifecycle-thread"}
          refute Map.has_key?(registry.retired, registry.current)
          send(worker, :finish)
          ref = entry.ref
          assert_receive {:worker_down, ^owner, {:DOWN, ^ref, :process, ^worker, {:stale_execution, ^ids, :material_state_changed}}, held}, 5_000
          assert held.lease_claims[c.issue.id].token == entry.lease_token
          refute Map.has_key?(held.retry_attempts, c.issue.id)
          refute Map.has_key?(held.completed, c.issue.id)
          assert held.agent_totals.total_tokens == 10
          assert finish_events(c) == []
          assert evidence(c, entry) == before
      end
    end
  end

  defp start_worker(c) do
    {:ok, owner} = GenServer.start(Driver, self())

    on_exit(fn ->
      if Process.alive?(owner) do
        runtime = GenServer.call(owner, :runtime)
        Enum.each(runtime.running, fn {_id, entry} -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid) end)
        GenServer.stop(owner)
      end
    end)

    entry = GenServer.call(owner, {:dispatch, c.issue}, 10_000)
    assert is_map(entry)
    worker = entry.pid
    assert_receive {:worker_ready, ^worker, context, expected}, 5_000
    assert context == entry.agent_execution.context
    assert expected === entry.agent_execution.expected
    {owner, worker, entry}
  end

  defp in_worker(worker, fun) do
    ref = make_ref()
    send(worker, {:exercise, self(), ref, fun})

    receive do
      {:exercise_result, ^ref, {:fixture_exception, error, stack}} -> reraise error, stack
      {:exercise_result, ^ref, {:fixture_caught, kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
      {:exercise_result, ^ref, result} -> result
    after
      10_000 -> flunk("admitted worker did not complete the public runner call")
    end
  end

  defp app_server!(c) do
    observation = %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{"threadId" => "lifecycle-thread", "tokenUsage" => %{"total" => %{"inputTokens" => 7, "outputTokens" => 3, "totalTokens" => 10}}}
    }

    request = %{
      "id" => 72,
      "method" => "item/tool/call",
      "params" => %{
        "tool" => "report_verifier_result",
        "callId" => "lifecycle-call",
        "threadId" => "lifecycle-thread",
        "turnId" => "lifecycle-turn",
        "arguments" => %{"verdict" => "pass", "summary" => "real local verifier report", "acceptance_gaps" => [], "risky_areas" => [], "evidence" => ["Local smoke passed"], "raw_output" => "pass"}
      }
    }

    script!(Path.join(c.bin, "codex"), """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"lifecycle-thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf 'transport\\n' >> #{quote_shell(c.commands)}
          printf '%s\\n' #{quote_shell(Jason.encode!(observation))}
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"lifecycle-turn"}}}'
          printf '%s\\n' #{quote_shell(Jason.encode!(request))}
          ;;
        *'"id":72'*)
          printf '%s\\n' "$line" >> #{quote_shell(c.replies)}
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)
  end

  defp trace_stops(worker, fun) do
    Code.ensure_loaded!(Codex)
    observer = self()
    tracer = spawn(fn -> collect_stops(observer, worker, []) end)
    :erlang.trace_pattern({Codex, :stop_session, 1}, true, [])
    :erlang.trace(worker, true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      ref = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, _, ^ref}, 1_000
      send(tracer, :flush)
      assert_receive {:closed_ports, ports}, 1_000
      {result, ports}
    after
      :erlang.trace(worker, false, [:call])
      :erlang.trace_pattern({Codex, :stop_session, 1}, false, [])
      send(tracer, :stop)
    end
  end

  defp collect_stops(observer, worker, ports) do
    receive do
      {:trace, ^worker, :call, {Codex, :stop_session, [%{port: port}]}} ->
        collect_stops(observer, worker, ports ++ [port])

      :flush ->
        send(observer, {:closed_ports, ports})
        collect_stops(observer, worker, ports)

      :stop ->
        :ok
    end
  end

  defp evidence(c, entry),
    do: %{
      state: File.read!(RunStateStore.state_path(c.workspace)),
      lease: File.read!(entry.lease_token.storage.lease_path),
      ledger: File.read!(entry.dispatch_ticket.ledger_path),
      marker: File.read!(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json")),
      commands: File.read!(c.commands)
    }

  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp finish_events(c), do: Enum.filter(RunLedger.recent_entries(), &(&1["issue_id"] == c.issue.id and &1["event_type"] == "dispatch.finished"))

  defp script!(path, body) do
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
