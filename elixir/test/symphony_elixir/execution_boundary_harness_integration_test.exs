defmodule SymphonyElixir.ExecutionBoundaryHarnessIntegrationTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{AgentExecution, AgentProvider, DispatchAudit, RunLedger, RunStateStore}
  alias SymphonyElixir.AgentProvider.Codex

  # Existing controlled-worker fixture, real admission/gate/owner/session/usage.
  # Only the AppServer transport is local; provider identity is never substituted.
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

  setup do
    root = "/private/tmp/boundary-vertical-#{System.unique_integer([:positive])}"
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(workspace_root)

    issue = %Issue{
      id: "boundary-#{System.unique_integer([:positive])}",
      identifier: "BOUNDARY-1",
      title: "Validate local candidate",
      description: "## Acceptance Criteria\n- validate answer=42",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    transport = Path.join(root, "app-server")
    transcript = Path.join(root, "transport.jsonl")
    File.write!(transcript, "")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      runner_install_root: Path.join(root, "install"),
      max_concurrent_agents: 1,
      observability_tracing_enabled: false,
      codex_command: quote_shell(transport) <> " app-server",
      codex_approval_policy: "never"
    )

    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "candidate.txt"), "answer=41\n")
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/run_state.json\n")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command: ["/usr/bin/true"]
    validation:
      command: >-
        IFS= read -r value < candidate.txt; test "$value" = answer=42 && /usr/bin/true && printf verified > evidence.txt
    smoke:
      command: ["/usr/bin/true"]
    post_merge:
      command: ["/usr/bin/true"]
    artifacts:
      command: ["/usr/bin/true"]
    pull_request:
      required_checks: ["local-validation"]
    """)

    git = System.find_executable("git")

    for args <- [["init", "-q", "-b", "main"], ["config", "user.name", "Boundary Fixture"], ["config", "user.email", "boundary@example.invalid"], ["add", "-A"], ["commit", "-qm", "fixture"]] do
      assert {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
    end

    origin = Path.join(root, "origin.git")
    assert {_, 0} = System.cmd(git, ["clone", "--bare", workspace, origin], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(git, ["remote", "add", "origin", origin], cd: workspace)
    assert {_, 0} = System.cmd(git, ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})

    policy = %{
      "version" => 1,
      "backend" => "macos_deny_default_v1",
      "workspace_root" => workspace_root,
      "shell" => "/bin/bash",
      "executables" => Enum.map(["/bin/bash", "/usr/bin/true"], &tool/1),
      "read_roots" => []
    }

    policy_path = Path.join(root, "policy.json")
    bytes = Jason.encode!(policy)
    File.write!(policy_path, bytes)
    File.chmod!(policy_path, 0o400)
    selected = %{"policy_file" => policy_path, "sha256" => digest(bytes), "timeout_ms" => 5000}
    workflow = Workflow.workflow_file_path()
    text = File.read!(workflow) |> String.replace("agent:\n", "agent:\n  provider: codex\n")
    File.write!(workflow, String.replace(text, "---\n", "---\nexecution_boundary: #{Jason.encode!(selected)}\n", global: false))
    :ok = WorkflowStore.force_reload()
    app_server!(transport, transcript)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, transcript: transcript}
  end

  for result <- [:validated, :metadata_denied] do
    @tag outcome: result
    test "real admitted provider turn reaches offline harness #{result}", c do
      {owner, worker, entry} = start_worker(c)
      observer = self()

      {validation, port} =
        in_worker(worker, fn ->
          assert {:ok, session, binding} = AgentProvider.open_session(Codex, c.workspace, c.issue, :main)
          send(observer, {:provider_port, session.port})

          try do
            assert {:ok, %{result: :turn_completed}} = AgentProvider.run_turn(Codex, session, c.workspace, "Update the candidate then validate it", c.issue, [execution_binding: binding], :delivery)
            assert {:ok, _} = AgentExecution.transition_current("validate", %{})
            assert {:ok, harness} = RepoHarness.load(c.workspace)
            harness = if c.outcome == :metadata_denied, do: %{harness | validation_command: "printf corrupt > .symphony/run_state.json"}, else: harness
            before = File.read!(RunStateStore.state_path(c.workspace))
            assert {:ok, _} = AgentExecution.ensure_current()
            validation = RunInspector.run_validation(c.workspace, harness)
            assert {:ok, _} = AgentExecution.ensure_current()
            assert File.read!(RunStateStore.state_path(c.workspace)) == before
            {validation, session.port}
          after
            assert :ok = AgentProvider.close_session(Codex, session, binding)
          end
        end)

      assert_receive {:provider_port, ^port}, 5_000
      assert Port.info(port) == nil
      assert File.read!(Path.join(c.workspace, "candidate.txt")) == "answer=42\n"

      case c.outcome do
        :validated ->
          assert validation.status == :passed
          assert validation.error == nil
          assert File.read!(Path.join(c.workspace, "evidence.txt")) == "verified"

        :metadata_denied ->
          assert validation.status == :failed
          assert validation.error == nil
          refute File.exists?(Path.join(c.workspace, "evidence.txt"))
      end

      transcript = File.read!(c.transcript)
      assert length(String.split(transcript, "\n", trim: true)) == 1
      runtime = GenServer.call(owner, :runtime)
      registry = runtime.running[c.issue.id].agent_execution.registry
      assert registry.uncertain == nil and registry.current == nil
      assert Map.has_key?(registry.retired, {Codex, :thread, "boundary-thread"})
      assert runtime.agent_totals.input_tokens == 7
      assert runtime.agent_totals.output_tokens == 3
      assert runtime.agent_totals.total_tokens == 10
      target = if c.outcome == :validated, do: "done", else: "blocked"
      assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current(target, %{}) end)
      send(worker, :finish)
      ref = entry.ref
      assert_receive {:worker_down, ^owner, {:DOWN, ^ref, :process, ^worker, :normal}, stopped}, 5000
      assert stopped.token_usage_errors == %{} and stopped.stale_execution_errors == %{}
      refute Map.has_key?(stopped.lease_claims, c.issue.id)
      refute Map.has_key?(stopped.retry_attempts, c.issue.id)
      assert Map.has_key?(stopped.completed, c.issue.id) == (c.outcome == :validated)
      assert [event] = Enum.filter(RunLedger.recent_entries(), &(&1["issue_id"] == c.issue.id and &1["event_type"] == "dispatch.finished"))
      assert event["metadata"]["dispatch_id"] == entry.dispatch_ticket.dispatch_id
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

  defp app_server!(path, transcript) do
    usage =
      Jason.encode!(%{
        "method" => "thread/tokenUsage/updated",
        "params" => %{"threadId" => "boundary-thread", "tokenUsage" => %{"total" => %{"inputTokens" => 7, "outputTokens" => 3, "totalTokens" => 10}}}
      })

    File.write!(path, """
    #!/bin/bash
    set -eu
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"boundary-thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' "$line" >> #{quote_shell(transcript)}
          printf 'answer=42\\n' > candidate.txt
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"boundary-turn"}}}'
          printf '%s\\n' #{quote_shell(usage)}
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o500)
  end

  defp tool(path), do: %{"path" => path, "sha256" => digest(File.read!(path))}
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
