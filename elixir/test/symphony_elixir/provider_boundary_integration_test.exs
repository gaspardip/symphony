defmodule SymphonyElixir.ProviderBoundaryIntegrationTest do
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
    root = "/private/tmp/provider-owned-integration-#{System.unique_integer([:positive])}"
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

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      runner_install_root: Path.join(root, "install"),
      max_concurrent_agents: 1,
      observability_tracing_enabled: false,
      codex_command: quote_shell(transport) <> " app-server",
      codex_approval_policy: "never",
      hook_after_run: "printf unexpected > after-run",
      policy_require_checkout: true,
      policy_require_verifier: true
    )

    workspace = Workspace.path_for_issue(issue)
    transcript = Path.join(workspace, "transport.jsonl")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "candidate.txt"), "answer=41\n")
    File.mkdir_p!(Path.join(workspace, ".symphony/progress"))
    File.write!(Path.join(workspace, ".symphony/progress/BOUNDARY-1.md"), "## Work Log\n\n## Evidence\n\n")
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
      required_checks: ["local-validation"]
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

    for args <- [["init", "-q", "-b", "main"], ["config", "user.name", "Boundary Fixture"], ["config", "user.email", "boundary@example.invalid"], ["add", "-A"], ["commit", "-qm", "fixture"]] do
      assert {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
    end

    origin = Path.join(root, "origin.git")
    assert {_, 0} = System.cmd(git, ["clone", "--bare", workspace, origin], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(git, ["remote", "add", "origin", origin], cd: workspace)
    assert {_, 0} = System.cmd(git, ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)
    assert {_, 0} = System.cmd(git, ["checkout", "-qb", SymphonyElixir.GitManager.issue_branch_name(issue)], cd: workspace)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})

    app_server!(transport, transcript)

    policy = %{
      "version" => 1,
      "backend" => "macos_deny_default_v1",
      "workspace_root" => workspace_root,
      "shell" => "/bin/bash",
      "executables" => Enum.map(["/bin/bash", "/bin/sleep", "/usr/bin/true", transport], &tool/1),
      "read_roots" => []
    }

    policy_path = Path.join(root, "policy.json")
    bytes = Jason.encode!(policy)
    File.write!(policy_path, bytes)
    File.chmod!(policy_path, 0o400)
    selected = %{"policy_file" => policy_path, "sha256" => digest(bytes), "timeout_ms" => 5000}
    workflow = Workflow.workflow_file_path()
    text = File.read!(workflow) |> String.replace("agent:\n", "agent:\n  provider: codex\n")
    File.write!(workflow, String.replace(text, "---\n", "---\nprovider_execution_boundary: #{Jason.encode!(selected)}\n", global: false))
    :ok = WorkflowStore.force_reload()

    on_exit(fn ->
      cleanup_uncertain!(root)

      for receipt <- ["provider.pid"] do
        case File.read(Path.join(workspace, receipt)) do
          {:ok, bytes} -> assert_absent!(String.to_integer(String.trim(bytes)))
          {:error, :enoent} -> :ok
          {:error, reason} -> flunk("physical receipt unavailable: #{inspect(reason)}")
        end
      end

      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, issue: issue, transcript: transcript, transport: transport, policy_path: policy_path}
  end

  test "real admission and accounted AppServer retain correlated lifecycle receipts", c do
    {owner, worker, entry} = start_worker(c)

    assert {:ok, _} =
             in_worker(worker, fn ->
               assert {:ok, session, binding} = AgentProvider.open_session(Codex, c.workspace, c.issue, :main)

               SymphonyElixir.ProviderTransport.with_cleanup(
                 fn ->
                   AgentProvider.run_turn(Codex, session, c.workspace, "local work", c.issue, [execution_binding: binding, tool_executor: fn _, _ -> flunk("unexpected tool") end], :delivery)
                 end,
                 fn -> AgentProvider.close_session(Codex, session, binding) end
               )
             end)

    assert File.read!(Path.join(c.workspace, "candidate.txt")) == "answer=42\n"
    assert_physical_closed!(c)
    assert_receipts!(c, entry, 1)
    runtime = GenServer.call(owner, :runtime)
    assert runtime.agent_totals.total_tokens == 10
    assert runtime.running[c.issue.id].agent_execution.registry.uncertain == nil
    assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current("blocked", %{stop_reason: "fixture complete"}) end)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, :normal}, stopped}, 5000
    refute Map.has_key?(stopped.running, c.issue.id)
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
  end

  test "admitted AppServer finish stays in its authentic ticket ledger across configuration drift", c do
    {owner, worker, entry} = start_worker(c)
    original = entry.dispatch_ticket.ledger_path
    replacement = Path.join(c.root, "replacement/run_ledger.jsonl")
    File.mkdir_p!(Path.dirname(replacement))
    File.write!(replacement, "")

    assert :ok =
             in_worker(worker, fn ->
               assert {:ok, session, binding} = AgentProvider.open_session(Codex, c.workspace, c.issue, :main)
               [started] = boundary_events()
               assert {:ok, ^started} = RunLedger.CheckedStorage.fetch(original, started["event_id"])
               old_config = Application.get_env(:symphony_elixir, :log_file)

               try do
                 Application.put_env(:symphony_elixir, :log_file, Path.join(Path.dirname(replacement), "runtime.log"))
                 assert {:ok, ^replacement} = RunLedger.ledger_file_path_checked()
                 # Closing is still required after drift; it grants no new turn or execution.
                 assert :ok = Codex.stop_session(session)

                 events =
                   File.read!(original)
                   |> String.split("\n", trim: true)
                   |> Enum.map(&Jason.decode!/1)
                   |> Enum.filter(&String.starts_with?(&1["event_type"], "execution.boundary."))

                 assert [^started, finished] = events
                 assert finished["metadata"]["started_event_id"] == started["event_id"]
                 assert finished["metadata"]["run_id"] == entry.dispatch_ticket.run_id
                 assert finished["metadata"]["dispatch_id"] == entry.dispatch_ticket.dispatch_id
                 assert finished["metadata"]["certain"] == 1
                 assert {:ok, ^finished} = RunLedger.CheckedStorage.fetch(original, finished["event_id"])
                 assert File.read!(replacement) == ""
               after
                 if old_config == nil, do: Application.delete_env(:symphony_elixir, :log_file), else: Application.put_env(:symphony_elixir, :log_file, old_config)
               end

               # Retirement uses its normal current-authority checks, after restoring the
               # fixture configuration. Cached physical close cannot append again.
               assert :ok = AgentProvider.close_session(Codex, session, binding)
             end)

    assert File.read!(replacement) == ""
    assert_receipts!(c, entry, 1)
    assert_physical_closed!(c)
    assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current("blocked", %{stop_reason: "fixture complete"}) end)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, :normal}, stopped}, 5000
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
  end

  test "actual AgentRunner and Delivery preserve first accounting terminal while closing selected provider", c do
    # Change only controlled transport bytes before admission and repin that executable.
    text = File.read!(c.transport) |> String.replace("\"inputTokens\":7", "\"inputTokens\":null")
    assert text != File.read!(c.transport)
    File.chmod!(c.transport, 0o700)
    File.write!(c.transport, text)
    File.chmod!(c.transport, 0o500)
    repin_policy!(c)
    assert {:ok, true, _} = SymphonyElixir.RepoCompatibility.compatible?(c.workspace, include_pr_details: false)
    {owner, worker, entry} = start_worker(c)
    before = File.read!(RunStateStore.state_path(c.workspace))

    assert {:stop, {:accounting_uncertain, :invalid_usage_dimension}} =
             in_worker(worker, fn -> SymphonyElixir.AgentRunner.run(c.issue, self(), include_pr_details: false) end)

    assert_physical_closed!(c)
    assert_receipts!(c, entry, 1)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    refute File.exists?(Path.join(c.workspace, "after-run"))
    runtime = GenServer.call(owner, :runtime)
    assert runtime.agent_totals.total_tokens == 0
    assert runtime.running[c.issue.id].agent_execution.registry.uncertain == :invalid_usage_dimension
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, {:accounting_uncertain, :invalid_usage_dimension}}, stopped}, 5000
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    refute Map.has_key?(stopped.completed, c.issue.id)
  end

  test "public AppServer cleanup retains an exact callback exception and logs a separate physical failure safely", c do
    # The callback is a host tool boundary, explicitly outside candidate confinement.
    # It kills only the recorded helper while still owned, to create a real second failure.
    marker = "callback-secret-sentinel"

    text =
      File.read!(c.transport)
      |> String.replace(~s|printf '%s\\n' '{"method":"turn/completed"}'|, ~s|printf '%s\\n' '{"id":72,"method":"item/tool/call","params":{"tool":"fixture","arguments":{}}}'|)

    assert text != File.read!(c.transport)
    File.chmod!(c.transport, 0o700)
    File.write!(c.transport, text)
    File.chmod!(c.transport, 0o500)
    repin_policy!(c)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        error =
          assert_raise ArgumentError, marker, fn ->
            AppServer.run(c.workspace, "local callback", c.issue,
              tool_executor: fn _, _ ->
                kill_recorded_helper!(c)
                raise ArgumentError, marker
              end
            )
          end

        assert error.message == marker
      end)

    assert log =~ "Provider cleanup failed"
    assert log =~ "ArgumentError"
    refute log =~ marker
    # Cleanup is a separate test-owned action after recording the uncertain product outcome.
    cleanup_uncertain!(c.root)
    assert_physical_closed!(c)
    [_, finished] = boundary_events()
    assert finished["metadata"]["certain"] == 0
    # The product did not turn test cleanup into a certain finish receipt.
  end

  test "AgentRunner preserves its exception and denies after_run after a failed real session close", c do
    {owner, worker, entry} = start_worker(c)
    before = File.read!(RunStateStore.state_path(c.workspace))
    marker = "runner-primary-sentinel"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert_raise ArgumentError, marker, fn ->
          in_worker(worker, fn ->
            SymphonyElixir.AgentRunner.run(c.issue, self(),
              include_pr_details: false,
              command_runner: fn executable, args, opts ->
                # Existing RunInspector transport seam, after the real session opened.
                # Execute the actual Git read; only the following host failure is injected.
                {_output, 0} = System.cmd(executable, args, opts)
                kill_recorded_helper!(c)

                stacktrace = [
                  {SymphonyElixir.AgentRunner, :run, [marker], [file: String.to_charlist(Path.join(marker, "agent_runner.ex")), line: 777]}
                ]

                :erlang.raise(:error, %ArgumentError{message: marker}, stacktrace)
              end
            )
          end)
        end
      end)

    assert log =~ "Provider cleanup failed"
    assert log =~ "provider_cleanup_uncertain"
    assert log =~ "agent_runner.ex:777"
    refute log =~ marker
    refute File.exists?(Path.join(c.workspace, "after-run"))
    refute File.exists?(c.transcript)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before

    assert {:stop, {:accounting_uncertain, {:provider_close_failed, {:provider_cleanup_uncertain, _}}}} =
             in_worker(worker, fn -> AgentExecution.ensure_current() end)

    runtime = GenServer.call(owner, :runtime)
    assert {:provider_close_failed, {:provider_cleanup_uncertain, _}} = runtime.running[c.issue.id].agent_execution.registry.uncertain
    assert_receipts!(c, entry, 0)
    cleanup_uncertain!(c.root)
    assert_physical_closed!(c)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, {:accounting_uncertain, {:provider_close_failed, _}}}, stopped}, 5000
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
  end

  for {adapter, name, provider} <- [{SymphonyElixir.AgentProvider.Claude, "claude", "claude"}, {SymphonyElixir.AgentProvider.CodexCLI, "codex", "codex-cli"}] do
    @tag adapter: adapter, binary_name: name, provider_name: provider
    test "#{name} run_turn latches physical uncertainty before TurnEffects or after_run", c do
      install_cli!(c)
      {owner, worker, entry} = start_worker(c)
      observer = self()

      assert {:stop, {:accounting_uncertain, {:provider_close_failed, {:provider_cleanup_uncertain, _}}}} =
               terminal =
               in_worker(worker, fn ->
                 assert {:ok, session, binding} = AgentProvider.open_session(c.adapter, c.workspace, c.issue, :main)

                 result =
                   AgentProvider.run_turn(
                     c.adapter,
                     session,
                     c.workspace,
                     "local CLI",
                     c.issue,
                     [
                       execution_binding: binding,
                       on_message: fn event ->
                         if event.event == :notification do
                           kill_recorded_helper!(c)
                           send(observer, :physical_failure_injected)
                         else
                           send(observer, {:unexpected_after_failure, event.event})
                         end

                         :ok
                       end,
                       tool_executor: fn _, _ ->
                         send(observer, :late_tool)
                         %{success: true}
                       end
                     ],
                     :delivery
                   )

                 assert {:stop, _} = result
                 assert AgentProvider.close_session(c.adapter, session, binding) == result
                 assert Workspace.run_after_run_hook(c.workspace, c.issue) == result
                 result
               end)

      assert_received :physical_failure_injected
      refute_received :late_tool
      refute_received {:unexpected_after_failure, _}
      refute File.exists?(Path.join(c.workspace, "after-run"))
      assert File.read!(Path.join(c.workspace, "candidate.txt")) == "answer=41\n"
      assert in_worker(worker, fn -> AgentExecution.ensure_current() end) == terminal
      runtime = GenServer.call(owner, :runtime)
      assert runtime.agent_totals.total_tokens == 10
      assert {:provider_close_failed, _} = runtime.running[c.issue.id].agent_execution.registry.uncertain
      assert_receipts!(c, entry, 0)
      cleanup_uncertain!(c.root)
      assert_physical_closed!(c)
      send(worker, :finish)
      assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, {:accounting_uncertain, {:provider_close_failed, _}}}, stopped}, 5000
      refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    end
  end

  test "a known blocked terminal survives a later uncertain close without becoming accounting", c do
    {owner, worker, entry} = start_worker(c)

    assert {{:error, {:provider_cleanup_uncertain, _}}, {:stop, {:execution_stopped, %{stage: "blocked"}}}} =
             in_worker(worker, fn ->
               assert {:ok, session, binding} = AgentProvider.open_session(Codex, c.workspace, c.issue, :main)
               assert {:ok, _} = AgentExecution.transition_current("blocked", %{stop_reason: "first terminal"})
               before = File.read!(RunStateStore.state_path(c.workspace))
               kill_recorded_helper!(c)
               assert {:error, {:provider_cleanup_uncertain, _}} = physical = AgentProvider.close_session(Codex, session, binding)
               assert File.read!(RunStateStore.state_path(c.workspace)) == before
               assert {:stop, {:execution_stopped, %{stage: "blocked"}}} = terminal = AgentExecution.ensure_current()
               assert Workspace.run_after_run_hook(c.workspace, c.issue) == terminal
               {physical, terminal}
             end)

    refute File.exists?(Path.join(c.workspace, "after-run"))
    runtime = GenServer.call(owner, :runtime)
    assert runtime.running[c.issue.id].agent_execution.registry.uncertain == nil
    assert_receipts!(c, entry, 0)
    cleanup_uncertain!(c.root)
    assert_physical_closed!(c)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, :normal}, stopped}, 5000
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
  end

  defp kill_recorded_helper!(c) do
    [started] = boundary_events()
    helper = started["metadata"]["helper_pid"]
    port = Enum.find(Port.list(), &(Port.info(&1, :os_pid) == {:os_pid, helper}))
    assert is_port(port)
    child = started["metadata"]["child_pid"]
    assert {identity, 0} = System.cmd("/bin/ps", ["-p", to_string(child), "-o", "pid=,pgid=,lstart="])
    [home, _tmp] = File.read!(Path.join(c.workspace, "private-roots")) |> String.split("\n", trim: true)
    {:name, artifact} = Port.info(port, :name)
    File.write!(Path.join(c.root, "uncertain.json"), Jason.encode!(%{child: child, identity: identity, artifact: to_string(artifact), resource: Path.dirname(home)}))
    assert {_, 0} = System.cmd("/bin/kill", ["-s", "KILL", to_string(helper)])
    :ok
  end

  defp install_cli!(c) do
    path = Path.join(c.root, c.binary_name)

    usage =
      if c.binary_name == "claude",
        do: ~s({"type":"result","result":"local result","usage":{"input_tokens":7,"output_tokens":3}}),
        else: ~s({"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}})

    File.write!(path, """
    #!/bin/bash
    set -eu
    printf '%s\\n' "$$" > provider.pid
    printf '%s\\n%s\\n' "$HOME" "$TMPDIR" > private-roots
    printf '%s\\n' #{quote_shell(usage)}
    while :; do /bin/sleep 0.01; done
    """)

    File.chmod!(path, 0o500)
    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", c.root <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)
    policy = File.read!(c.policy_path) |> Jason.decode!() |> Map.update!("executables", &(&1 ++ [tool(path)]))
    File.chmod!(c.policy_path, 0o600)
    File.write!(c.policy_path, Jason.encode!(policy))
    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "  provider: codex\n", "  provider: #{c.provider_name}\n"))
    repin_policy!(c)
  end

  defp cleanup_uncertain!(root) do
    receipt = Path.join(root, "uncertain.json")

    case File.read(receipt) do
      {:ok, bytes} ->
        data = Jason.decode!(bytes)
        child = data["child"]

        case System.cmd("/bin/ps", ["-p", to_string(child), "-o", "pid=,pgid=,lstart="]) do
          {current, 0} ->
            assert current == data["identity"]
            assert {_, 0} = System.cmd("/bin/kill", ["-s", "KILL", "--", "-#{child}"])

          {text, 1} ->
            assert String.trim(text) == ""
        end

        await_absent!(child, System.monotonic_time(:millisecond) + 5_000)
        {groups, 0} = System.cmd("/bin/ps", ["-axo", "pgid="])
        refute to_string(child) in String.split(groups)
        resource = data["resource"]
        artifact = data["artifact"]
        assert Path.dirname(resource) == "/private/tmp" and String.starts_with?(Path.basename(resource), "symphony-boundary-")
        assert Path.dirname(Path.dirname(artifact)) == Path.expand(System.tmp_dir!())
        assert Path.basename(artifact) == "owner" and String.starts_with?(Path.basename(Path.dirname(artifact)), "symphony-owned-hook-")
        for file <- ["boundary", "policy.sb"], do: File.rm!(Path.join(resource, file))
        for directory <- ["home", "tmp"], do: File.rmdir!(Path.join(resource, directory))
        File.rmdir!(resource)
        File.rm!(artifact)
        File.rmdir!(Path.dirname(artifact))
        File.rm!(receipt)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        flunk("uncertainty receipt unavailable: #{inspect(reason)}")
    end
  end

  defp repin_policy!(c) do
    policy = File.read!(c.policy_path) |> Jason.decode!()
    policy = Map.put(policy, "executables", Enum.map(policy["executables"], &tool(&1["path"])))
    bytes = Jason.encode!(policy)
    File.chmod!(c.policy_path, 0o600)
    File.write!(c.policy_path, bytes)
    File.chmod!(c.policy_path, 0o400)
    workflow = Workflow.workflow_file_path()
    selected = %{"policy_file" => c.policy_path, "sha256" => digest(bytes), "timeout_ms" => 5000}
    text = String.replace(File.read!(workflow), ~r/^provider_execution_boundary: .+$/m, "provider_execution_boundary: " <> Jason.encode!(selected))
    File.write!(workflow, text)
    :ok = WorkflowStore.force_reload()
  end

  defp assert_receipts!(c, entry, certain) do
    assert [started, finished] = boundary_events()

    for event <- [started, finished] do
      assert event["issue_id"] == c.issue.id
      assert event["metadata"]["run_id"] == entry.dispatch_ticket.run_id
      assert event["metadata"]["dispatch_id"] == entry.dispatch_ticket.dispatch_id
      assert {:ok, ^event} = RunLedger.fetch_entry_checked(event["event_id"])
    end

    assert finished["metadata"]["started_event_id"] == started["event_id"]
    assert finished["metadata"]["certain"] == certain
  end

  defp boundary_events, do: Enum.filter(RunLedger.recent_entries(), &String.starts_with?(&1["event_type"], "execution.boundary."))

  defp assert_physical_closed!(c) do
    [started | _] = boundary_events()
    child = started["metadata"]["child_pid"]
    helper = started["metadata"]["helper_pid"]
    provider = Path.join(c.workspace, "provider.pid") |> File.read!() |> String.trim() |> String.to_integer()
    for pid <- Enum.uniq([child, helper, provider]), do: assert_absent!(pid)
    {groups, 0} = System.cmd("/bin/ps", ["-axo", "pgid="])
    refute to_string(started["metadata"]["process_group"]) in String.split(groups)
  end

  defp assert_absent!(pid) do
    assert {text, 1} = System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "pid="])
    assert String.trim(text) == ""
  end

  defp await_absent!(pid, deadline) do
    case System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "pid="]) do
      {text, 1} ->
        assert String.trim(text) == ""

      {_text, 0} ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(10)
        await_absent!(pid, deadline)
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
    assert expected["stage"] == "implement"
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
    printf '%s\\n' "$$" > provider.pid
    printf '%s\\n%s\\n' "$HOME" "$TMPDIR" > private-roots
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
