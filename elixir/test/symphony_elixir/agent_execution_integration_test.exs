defmodule SymphonyElixir.AgentExecutionIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, AgentProvider, DispatchAudit, GitManager, LeaseManager, RunStateStore}
  alias SymphonyElixir.AgentProvider.{Claude, Codex, CodexCLI}

  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, Orchestrator, RunStateStore, Workspace}

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    @impl true
    def init(observer) do
      runtime = %Orchestrator.State{
        lease_owner: "i2-owner-#{System.unique_integer([:positive])}",
        max_concurrent_agents: 2,
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
      }

      {:ok, %{runtime: runtime, observer: observer, hold_usage?: false, usage: nil, confirmation: nil}}
    end

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}
    def handle_call({:hold_usage, hold?}, _from, state), do: {:reply, :ok, %{state | hold_usage?: hold?}}

    def handle_call({:stop, id}, _from, state) do
      runtime = Orchestrator.terminate_running_issue(state.runtime, id, false)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call({:stop_and_retry, id, attempt, metadata}, _from, state) do
      runtime = state.runtime |> Orchestrator.terminate_running_issue(id, false) |> Orchestrator.schedule_issue_retry_for_test(id, attempt, metadata)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call({:restart_stalled, id}, _from, state) do
      runtime = state.runtime
      runtime = put_in(runtime.running[id].started_at, DateTime.add(DateTime.utc_now(), -3_600, :second))
      runtime = Orchestrator.reconcile_stalled_running_issues_for_test(runtime)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call({:dispatch, issue, mode}, _from, state) do
      observer = state.observer
      owner = self()

      runtime =
        if mode == :real do
          Orchestrator.dispatch_runtime_issue(state.runtime, issue, nil)
        else
          start_child = fn supervisor, job ->
            # Capture before returning the child; never recapture after a test control.
            admitted_raw = issue |> Workspace.path_for_issue() |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

            Task.Supervisor.start_child(supervisor, fn ->
              case mode do
                :held ->
                  receive do
                    :release_worker -> job.()
                  end

                :controlled ->
                  receive do
                    {:captured, context, expected} ->
                      true = RunStateStore.material_projection(admitted_raw) === expected

                      result =
                        DispatchGate.run(owner, context.ticket.dispatch_id, fn ->
                          DispatchAudit.with_authorization(context.ticket, fn ->
                            AgentExecution.with_context(context.ticket, context.lease_token, owner, admitted_raw, fn ->
                              send(observer, {:worker_ready, self(), context, RunStateStore.material_projection(admitted_raw)})
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
              end
            end)
          end

          spawn_worker = fn runtime, issue, attempt, recipient ->
            Orchestrator.do_spawn_issue_worker_for_test(runtime, issue, attempt, recipient, start_child_fun: start_child)
          end

          Orchestrator.do_dispatch_issue_for_test(state.runtime, issue, nil, spawn_fun: spawn_worker)
        end

      entry = Map.get(runtime.running, issue.id)
      if mode == :controlled and entry, do: send(entry.pid, {:captured, entry.agent_execution.context, entry.agent_execution.expected})
      {:reply, entry, %{state | runtime: runtime}}
    end

    def handle_call(:release_usage, _from, %{usage: message} = state) when not is_nil(message) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      state = %{state | runtime: runtime, usage: nil, hold_usage?: false}

      state =
        case state.confirmation do
          nil ->
            state

          {call, from} ->
            {:reply, result, runtime} = Orchestrator.handle_call(call, from, state.runtime)
            GenServer.reply(from, result)
            %{state | runtime: runtime, confirmation: nil}
        end

      {:reply, :ok, state}
    end

    def handle_call({:agent_execution, _invocation, _expected, {:confirm, _, _}} = message, from, %{usage: usage} = state) when not is_nil(usage),
      do: {:noreply, %{state | confirmation: {message, from}}}

    def handle_call(message, from, state) do
      {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      {:reply, reply, %{state | runtime: runtime}}
    end

    @impl true
    def handle_info({:agent_execution_usage, invocation, _expected, observation} = message, %{hold_usage?: true} = state) do
      send(state.observer, {:usage_held, self(), invocation, observation})
      {:noreply, %{state | usage: message}}
    end

    def handle_info({:authorize_dispatch, id, _dispatch, pid} = message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      send(state.observer, {:authorized, self(), id, pid})
      {:noreply, %{state | runtime: runtime}}
    end

    def handle_info({:DOWN, _ref, :process, _pid, _reason} = message, state) do
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
    root = Path.join(System.tmp_dir!(), "i2-integration-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    issue = %Issue{
      id: "i2-#{System.unique_integer([:positive])}",
      identifier: "I2-1",
      title: "Account local work",
      description: "## Acceptance Criteria\n- preserve accounting evidence",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner-install"),
      observability_tracing_enabled: false,
      policy_require_verifier: false,
      hook_after_run: "printf 'after-run\\n' >> '#{root}/commands'",
      max_turns: 1
    )

    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "agent:\n", "agent:\n  provider: claude\n"))
    WorkflowStore.force_reload()
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(Path.join(workspace, ".symphony/progress"))
    git = System.find_executable("git")

    for args <- [["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] do
      assert {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, ".gitignore"), ".symphony/run_state.json\n")
    File.write!(Path.join(workspace, "existing.txt"), "initial\n")
    File.write!(Path.join(workspace, ".symphony/progress/I2-1.md"), "## Work Log\n\n## Evidence\n\n")
    assert {_, 0} = System.cmd(git, ["add", "-A"], cd: workspace)
    assert {_, 0} = System.cmd(git, ["commit", "-qm", "fixture"], cd: workspace)
    assert {_, 0} = System.cmd(git, ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: workspace)
    assert {_, 0} = System.cmd(git, ["checkout", "-q", "-b", GitManager.issue_branch_name(issue)], cd: workspace)
    commands = Path.join(root, "commands")
    File.write!(commands, "")
    write_script!(Path.join(bin, "git"), "printf 'git %s\\n' \"$*\" >> '#{commands}'\nexec '#{git}' \"$@\"\n")
    write_script!(Path.join(bin, "gh"), "printf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n")
    write_script!(Path.join(bin, "mix"), "printf 'mix %s\\n' \"$*\" >> '#{commands}'\n")
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, bin: bin, commands: commands, git: git}
  end

  test "I2a-01 captured context is installed after real admission and cannot relocate authority", c do
    {owner, worker, entry} = start_controlled(c)

    assert entry.agent_execution.context ==
             in_worker(worker, fn ->
               {:ok, context} = AgentExecution.current_context()
               context
             end)

    assert entry.lease_token == entry.agent_execution.context.lease_token
    assert entry.dispatch_ticket == entry.agent_execution.context.ticket
    original_log = Application.fetch_env!(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(c.root, "relocated/runtime.log"))

    try do
      assert :ok = LeaseManager.ensure_current(entry.lease_token)
      assert in_worker(worker, fn -> AgentExecution.current_context() end) == {:ok, entry.agent_execution.context}
      assert GenServer.call(owner, :runtime).lease_claims[c.issue.id].token == entry.lease_token
      refute File.exists?(Path.join(c.root, "relocated"))
    after
      Application.put_env(:symphony_elixir, :log_file, original_log)
    end
  end

  test "I2a-02 foreign context payload and sender are discarded before counters rates and snapshot", c do
    {owner, worker, entry} = start_controlled(c)
    invocation = register_invocation(worker, Claude, c.workspace, :main)
    before = GenServer.call(owner, :runtime)
    bytes = File.read!(RunStateStore.state_path(c.workspace))

    for key <- [:worker, :owner, :issue_id, :ticket, :lease_token] do
      forged = put_in(invocation, [:context, key], :forged)
      send(owner, {:agent_execution_usage, forged, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(100)}})
      send(owner, {:agent_worker_update, forged, entry.agent_execution.expected, %{event: :notification, timestamp: DateTime.utc_now(), usage: counters(100), rate_limits: %{remaining: 0}}})
    end

    send(owner, {:agent_worker_update, c.issue.id, %{event: :notification, timestamp: DateTime.utc_now(), usage: counters(100)}})

    assert {:stop, {:accounting_uncertain, :execution_sender_mismatch}} =
             GenServer.call(owner, {:agent_execution, invocation, entry.agent_execution.expected, {:confirm, invocation.binding, invocation.ordinal}})

    after_state = GenServer.call(owner, :runtime)
    assert after_state.running == before.running
    assert after_state.agent_totals == before.agent_totals
    assert after_state.agent_rate_limits == before.agent_rate_limits
    assert after_state.token_usage_errors == %{}
    assert File.read!(RunStateStore.state_path(c.workspace)) == bytes
  end

  test "I2a-03 callback from another PID and a retired ordinal produce no effects", c do
    {owner, worker, _entry} = start_controlled(c)
    invocation = register_invocation(worker, Claude, c.workspace, :main)
    assert {:discard, :foreign_worker} = AgentExecution.observe_usage(invocation, %{usage: counters(99)})
    assert :ok = in_worker(worker, fn -> AgentExecution.retire_session(invocation.binding) end)
    assert {:discard, :obsolete_invocation} = in_worker(worker, fn -> AgentExecution.forward_update(invocation, %{event: :notification, timestamp: DateTime.utc_now(), usage: counters(99)}) end)
    runtime = GenServer.call(owner, :runtime)
    assert runtime.agent_totals.total_tokens == 0
    assert runtime.running[c.issue.id].last_agent_message == nil
    assert runtime.token_usage_errors == %{}
  end

  test "I2a-04 CLI invocation totals survive duplicate callbacks with durable baseline500", c do
    assert {:ok, _} = RunStateStore.record_token_usage(c.workspace, c.issue, counters(500))
    {owner, worker, _entry} = start_controlled(c)
    first = register_invocation(worker, Claude, c.workspace, :main)
    assert :ok = in_worker(worker, fn -> AgentExecution.observe_usage(first, %{usage: counters(100)}) end)
    assert {:ok, %{token_usage: %{total_tokens: 600}}} = RunStateStore.load(c.workspace)

    second =
      in_worker(worker, fn ->
        {:ok, invocation} = AgentExecution.begin_invocation(first.binding)
        invocation
      end)

    for {usage, expected} <- [{20, 620}, {20, 620}, {35, 635}] do
      assert :ok = in_worker(worker, fn -> AgentExecution.observe_usage(second, %{session_id: "external", usage: counters(usage)}) end)
      assert {:ok, %{token_usage: %{total_tokens: ^expected}}} = RunStateStore.load(c.workspace)
    end

    assert GenServer.call(owner, :runtime).agent_totals.total_tokens == 135
  end

  test "I2a-05 thread absolute100 then20 then35 never decreases or adds old totals", c do
    {owner, worker, _entry} = start_controlled(c)

    invocation =
      in_worker(worker, fn ->
        {:ok, binding} = AgentExecution.register_session(Codex, %{thread_id: "A"}, :main)
        {:ok, invocation} = AgentExecution.begin_invocation(binding)
        invocation
      end)

    for value <- [100, 20, 20, 35] do
      assert :ok = in_worker(worker, fn -> AgentExecution.observe_usage(invocation, %{thread_id: "A", tokenUsage: %{total: counters(value)}}) end)
      assert {:ok, %{token_usage: %{total_tokens: 100}}} = RunStateStore.load(c.workspace)
    end

    assert GenServer.call(owner, :runtime).agent_totals.total_tokens == 100
  end

  test "I2a-06 main A verifier B main A contributes130 with independent live handles", c do
    {owner, worker, _entry} = start_controlled(c)

    {a, b} =
      in_worker(worker, fn ->
        {:ok, a} = AgentExecution.register_session(Codex, %{thread_id: "A"}, :main)
        {:ok, ai} = AgentExecution.begin_invocation(a)
        :ok = AgentExecution.observe_usage(ai, %{tokenUsage: %{total: counters(100)}})
        {:ok, b} = AgentExecution.register_session(Codex, %{thread_id: "B"}, :verifier)
        {:ok, bi} = AgentExecution.begin_invocation(b)
        :ok = AgentExecution.observe_usage(bi, %{tokenUsage: %{total: counters(20)}})
        :ok = AgentExecution.retire_session(b)
        {:ok, ai} = AgentExecution.begin_invocation(a)
        :ok = AgentExecution.observe_usage(ai, %{tokenUsage: %{total: counters(110)}})
        {ai, bi}
      end)

    assert {:discard, :obsolete_invocation} = in_worker(worker, fn -> AgentExecution.observe_usage(b, %{tokenUsage: %{total: counters(40)}}) end)
    runtime = GenServer.call(owner, :runtime)
    assert runtime.running[c.issue.id].agent_execution.registry.current == a.binding
    assert runtime.agent_totals.total_tokens == 130
    assert {:ok, %{token_usage: %{total_tokens: 130}}} = RunStateStore.load(c.workspace)
  end

  test "I2a-07 exhausted registration capacity rejects before a transport can open", c do
    {owner, worker, _entry} = start_controlled(c)

    result =
      in_worker(worker, fn ->
        for i <- 1..64 do
          :ok = AgentExecution.ensure_session_capacity()
          {:ok, binding} = AgentExecution.register_session(Claude, %{session_id: "local-#{i}"}, :main)
          :ok = AgentExecution.retire_session(binding)
        end

        AgentProvider.open_session(Claude, c.workspace, c.issue, :main)
      end)

    assert {:stop, {:accounting_uncertain, :dispatch_binding_limit}} = result
    registry = GenServer.call(owner, :runtime).running[c.issue.id].agent_execution.registry
    assert map_size(registry.retired) == 64
    assert registry.live == %{}
    assert GenServer.call(owner, :runtime).agent_totals.total_tokens == 0
  end

  test "I2a-08 malformed raw observation stays sticky even if caller returns success", c do
    {owner, worker, entry} = start_controlled(c)
    invocation = register_invocation(worker, Claude, c.workspace, :main)
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    journal = journal_bytes(entry)

    assert :ignored =
             in_worker(worker, fn ->
               assert {:stop, {:accounting_uncertain, :missing_usage_dimension}} = AgentExecution.observe_usage(invocation, %{usage: %{input_tokens: 1}})
               assert {:stop, {:accounting_uncertain, :missing_usage_dimension}} = AgentExecution.observe_usage(invocation, %{usage: counters(10)})
               :ignored
             end)

    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, {:accounting_uncertain, :missing_usage_dimension}}, runtime}, 5_000
    assert runtime.running == %{}
    assert runtime.retry_attempts == %{}
    assert runtime.lease_claims[c.issue.id].token == entry.lease_token
    assert runtime.agent_totals.total_tokens == 0
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    assert journal_bytes(entry) == journal
  end

  test "I2a-12 checkpoint rejection is acknowledged before owner installs any proposed counters", c do
    {owner, worker, entry} = start_controlled(c)
    invocation = register_invocation(worker, Claude, c.workspace, :main)
    before = GenServer.call(owner, :runtime)
    journal = journal_bytes(entry)
    path = RunStateStore.state_path(c.workspace)
    File.write!(path, "unreadable-snapshot")
    ids = execution_ids(entry)
    assert {:error, %Jason.DecodeError{} = cause} = Jason.decode("unreadable-snapshot")
    assert {:stop, {:stale_execution, ^ids, ^cause}} = in_worker(worker, fn -> AgentExecution.observe_usage(invocation, %{usage: counters(100)}) end)
    after_state = GenServer.call(owner, :runtime)
    assert after_state.agent_totals == before.agent_totals
    assert after_state.running[c.issue.id].agent_input_tokens == 0
    assert AgentExecution.total_usage(after_state.running[c.issue.id].agent_execution.registry) == counters(0)
    assert after_state.running[c.issue.id].agent_execution.registry.uncertain == nil
    assert after_state.running[c.issue.id].agent_execution.terminal == {:stale_execution, ids, cause}
    assert after_state.stale_execution_errors[c.issue.id] == %{context: entry.agent_execution.context, ids: ids, cause: cause}
    assert after_state.token_usage_errors == %{}
    assert after_state.lease_claims[c.issue.id] == before.lease_claims[c.issue.id]
    refute Map.has_key?(after_state.retry_attempts, c.issue.id)
    assert File.read!(path) == "unreadable-snapshot"
    assert journal_bytes(entry) == journal
  end

  test "I2a-13 physical ABA rejects old token and forged successor envelope cannot adopt it", c do
    {owner, worker, entry} = start_controlled(c)
    invocation = register_invocation(worker, Claude, c.workspace, :main)
    assert {:ok, :released} = LeaseManager.release_token(entry.lease_token)
    assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, entry.lease_token.owner, storage: entry.lease_token.storage)
    assert successor.token.epoch == entry.lease_token.epoch
    bytes = File.read!(successor.token.storage.lease_path)
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    forged = put_in(invocation, [:context, :lease_token], successor.token)
    send(owner, {:agent_execution_usage, forged, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(99)}})
    assert GenServer.call(owner, :runtime).agent_totals.total_tokens == 0
    ids = execution_ids(entry)
    journal = journal_bytes(entry)
    assert {:stop, {:stale_execution, ^ids, :lease_token_mismatch}} = in_worker(worker, fn -> AgentExecution.observe_usage(invocation, %{usage: counters(100)}) end)
    held = GenServer.call(owner, :runtime)
    assert held.agent_totals.total_tokens == 0
    assert AgentExecution.total_usage(held.running[c.issue.id].agent_execution.registry) == counters(0)
    assert held.running[c.issue.id].agent_execution.registry.uncertain == nil
    assert held.stale_execution_errors[c.issue.id] == %{context: entry.agent_execution.context, ids: ids, cause: :lease_token_mismatch}
    assert held.token_usage_errors == %{}
    assert File.read!(successor.token.storage.lease_path) == bytes
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, {:stale_execution, ^ids, :lease_token_mismatch}}, runtime}, 5_000
    assert ref == entry.ref
    assert runtime.lease_claims[c.issue.id].token == entry.lease_token
    assert runtime.lease_claims[c.issue.id] == held.lease_claims[c.issue.id]
    assert runtime.stale_execution_errors == held.stale_execution_errors
    assert runtime.token_usage_errors == %{}
    assert runtime.agent_totals.total_tokens == 0
    refute Map.has_key?(runtime.retry_attempts, c.issue.id)
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    assert journal_bytes(entry) == journal
    assert File.read!(successor.token.storage.lease_path) == bytes
  end

  test "I2a-16 old DOWN and usage cannot pop a new admitted worker", c do
    {owner, worker, old} = start_controlled(c)
    invocation = register_invocation(worker, Claude, c.workspace, :main)
    GenServer.call(owner, {:stop, c.issue.id})
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert stopped.running == %{}
    replacement = controlled_dispatch(owner, c.issue)
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    send(owner, {:DOWN, old.ref, :process, worker, {:accounting_uncertain, :old}})
    send(owner, {:agent_execution_usage, invocation, old.agent_execution.expected, {:ok, :invocation_absolute, counters(99)}})
    send(owner, {:agent_execution_uncertain, old.agent_execution.context, :old})
    runtime = GenServer.call(owner, :runtime)
    assert runtime.running[c.issue.id].pid == replacement.pid
    assert runtime.running[c.issue.id].dispatch_ticket == replacement.dispatch_ticket
    assert runtime.token_usage_errors == %{}
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
  end

  for {name, provider} <- [{"claude", Claude}, {"codex-cli", CodexCLI}] do
    @callback_provider provider
    @callback_name name
    test "I2a-03 #{@callback_name} callbacks and synthesized tool execute in the admitted worker", c do
      consumer_fixture!(c, @callback_name, "implement")
      consumer_cli!(c, @callback_name, %{"input_tokens" => 7, "output_tokens" => 3})
      {owner, worker, _entry} = start_controlled(c)
      observer = self()

      assert {:ok, _result} =
               in_worker(worker, fn ->
                 {:ok, session, binding} = AgentProvider.open_session(@callback_provider, c.workspace, c.issue, :main)

                 result =
                   AgentProvider.run_turn(
                     @callback_provider,
                     session,
                     c.workspace,
                     "local PID proof",
                     c.issue,
                     [
                       execution_binding: binding,
                       on_message: fn update ->
                         send(observer, {:callback_pid, self(), update.event})
                         :ok
                       end,
                       tool_executor: fn tool, _args ->
                         send(observer, {:tool_pid, self(), tool})
                         %{"success" => true}
                       end
                     ],
                     :delivery
                   )

                 assert :ok = AgentProvider.close_session(@callback_provider, session, binding)
                 result
               end)

      assert_receive {:callback_pid, ^worker, :notification}, 1_000
      assert_receive {:callback_pid, ^worker, :turn_completed}, 1_000
      assert_receive {:tool_pid, ^worker, "report_agent_turn_result"}, 1_000
      assert GenServer.call(owner, :runtime).agent_totals.total_tokens == 10
    end
  end

  test "I2a-10 a successful CLI return cannot clear uncertainty caught by its callback", c do
    consumer_fixture!(c, "claude", "implement")
    consumer_cli!(c, "claude", %{"input_tokens" => 7, "output_tokens" => 3})
    {owner, worker, entry} = start_controlled(c)

    assert {:stop, {:accounting_uncertain, :callback_first_failure}} =
             in_worker(worker, fn ->
               {:ok, session, binding} = AgentProvider.open_session(Claude, c.workspace, c.issue, :main)

               AgentProvider.run_turn(
                 Claude,
                 session,
                 c.workspace,
                 "callback catch",
                 c.issue,
                 [
                   execution_binding: binding,
                   on_message: fn _update ->
                     File.write!(c.commands, "accounting-fault-boundary\n", [:append])
                     assert {:stop, {:accounting_uncertain, :callback_first_failure}} = AgentExecution.fail(:callback_first_failure)
                     assert {:stop, {:accounting_uncertain, :callback_first_failure}} = AgentExecution.fail(:ignored_second_failure)
                     :ok
                   end,
                   tool_executor: fn _, _ -> flunk("tool after caught accounting failure") end
                 ],
                 :delivery
               )
             end)

    commands = consumer_commands_after_transport(c)
    assert Enum.count(commands, &(&1 == "accounting-fault-boundary")) == 1
    ["accounting-fault-boundary" | after_fault] = Enum.drop_while(commands, &(&1 != "accounting-fault-boundary"))
    assert after_fault == []
    before = consumer_evidence(c)
    consumer_assert_uncertain_down!(c, owner, worker, entry, before)
  end

  test "I2a-11 returned CLI usage is checked before TurnEffects when storage fails after its last callback", c do
    consumer_fixture!(c, "claude", "implement")
    consumer_cli!(c, "claude", %{"input_tokens" => 7, "output_tokens" => 3})
    {owner, worker, entry} = start_controlled(c)
    snapshot_path = RunStateStore.state_path(c.workspace)
    ids = execution_ids(entry)
    assert {:error, %Jason.DecodeError{} = cause} = Jason.decode("corrupt-before-return")

    assert {:stop, {:stale_execution, ^ids, ^cause}} =
             in_worker(worker, fn ->
               {:ok, session, binding} = AgentProvider.open_session(Claude, c.workspace, c.issue, :main)

               AgentProvider.run_turn(
                 Claude,
                 session,
                 c.workspace,
                 "return barrier",
                 c.issue,
                 [
                   execution_binding: binding,
                   on_message: fn %{event: :notification} ->
                     File.write!(c.commands, "accounting-fault-boundary\n", [:append])
                     File.write!(snapshot_path, "corrupt-before-return")
                     :ok
                   end,
                   tool_executor: fn _, _ -> flunk("tool before validating returned usage") end
                 ],
                 :delivery
               )
             end)

    commands = consumer_commands_after_transport(c)
    assert Enum.count(commands, &(&1 == "accounting-fault-boundary")) == 1
    ["accounting-fault-boundary" | after_fault] = Enum.drop_while(commands, &(&1 != "accounting-fault-boundary"))
    assert after_fault == []
    assert File.read!(snapshot_path) == "corrupt-before-return"
    assert GenServer.call(owner, :runtime).agent_totals.total_tokens == 10
    before = consumer_evidence(c)
    consumer_assert_stale_down!(c, owner, worker, entry, before, cause)
  end

  test "I2a-17 owner death stops its admitted worker before another continuation", c do
    {owner, worker, entry} = start_controlled(c)
    ref = Process.monitor(worker)
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    journal = journal_bytes(entry)
    lease = File.read!(entry.lease_token.storage.lease_path)
    GenServer.stop(owner)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 5_000
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    assert journal_bytes(entry) == journal
    assert File.read!(entry.lease_token.storage.lease_path) == lease
    refute File.read!(c.commands) =~ "transport"
    refute File.read!(c.commands) =~ "after-run"
  end

  test "delivery keeps the first accounting uncertainty when a deploy journal and unreadable snapshot coexist", c do
    {owner, worker, entry} = start_controlled(c)

    deploy_ticket =
      in_worker(worker, fn ->
        assert {:ok, _state} = AgentExecution.transition_current("deploy_preview", %{})

        assert {:ok, ticket} =
                 AgentExecution.begin_deploy(c.workspace, %{
                   issue_id: c.issue.id,
                   issue_identifier: c.issue.identifier,
                   stage: "deploy_preview",
                   command: "/usr/bin/true"
                 })

        ticket
      end)

    snapshot_path = RunStateStore.state_path(c.workspace)
    snapshot_backup = Path.join(c.root, "snapshot-before-unreadable.json")
    snapshot_before = File.read!(snapshot_path)
    deploy_marker_path = Path.join(SymphonyElixir.DeployAudit.marker_directory(c.workspace), "marker.json")
    deploy_marker_before = File.read!(deploy_marker_path)
    dispatch_marker_before = journal_bytes(entry)
    ledger_before = File.read!(deploy_ticket.ledger_path)
    lease_before = File.read!(entry.lease_token.storage.lease_path)
    commands_before = File.read!(c.commands)
    File.rename!(snapshot_path, snapshot_backup)
    File.mkdir!(snapshot_path)
    assert {:error, :eisdir} = RunStateStore.load(c.workspace)
    assert {:error, {:deploy_audit_pending, _}} = SymphonyElixir.DeployAudit.ensure_available(c.workspace)

    assert {:stop, {:accounting_uncertain, :first_accounting_failure}} =
             in_worker(worker, fn ->
               assert {:stop, {:accounting_uncertain, :first_accounting_failure}} = AgentExecution.fail(:first_accounting_failure)
               assert {:ok, captured} = AgentExecution.current_context()
               assert captured == entry.agent_execution.context
               SymphonyElixir.DeliveryEngine.run(c.workspace, c.issue, nil, include_pr_details: false)
             end)

    runtime = GenServer.call(owner, :runtime)
    assert runtime.running[c.issue.id].agent_execution.registry.uncertain == :first_accounting_failure
    assert runtime.agent_totals.total_tokens == 0
    assert runtime.retry_attempts == %{}
    assert runtime.lease_claims[c.issue.id].token == entry.lease_token
    assert File.read!(c.commands) == commands_before
    assert File.read!(deploy_marker_path) == deploy_marker_before
    assert journal_bytes(entry) == dispatch_marker_before
    assert File.read!(deploy_ticket.ledger_path) == ledger_before
    assert File.read!(snapshot_backup) == snapshot_before
    assert File.dir?(snapshot_path)

    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, {:accounting_uncertain, :first_accounting_failure}}, stopped}, 5_000
    assert ref == entry.ref
    assert stopped.running == %{}
    assert stopped.retry_attempts == %{}
    assert stopped.lease_claims[c.issue.id] == runtime.lease_claims[c.issue.id]
    assert stopped.token_usage_errors[c.issue.id] == runtime.token_usage_errors[c.issue.id]
    assert File.read!(deploy_marker_path) == deploy_marker_before
    assert journal_bytes(entry) == dispatch_marker_before
    assert File.read!(deploy_ticket.ledger_path) == ledger_before
    assert File.read!(entry.lease_token.storage.lease_path) == lease_before
    assert File.read!(snapshot_backup) == snapshot_before
    assert File.dir?(snapshot_path)
    assert File.read!(c.commands) == commands_before
  end

  test "delivery readability checks do not admit an identified snapshot without execution context", c do
    {owner, _worker, entry} = start_controlled(c)
    snapshot_before = File.read!(RunStateStore.state_path(c.workspace))
    marker_before = journal_bytes(entry)
    lease_before = File.read!(entry.lease_token.storage.lease_path)
    commands_before = File.read!(c.commands)
    runtime_before = GenServer.call(owner, :runtime)
    assert {:error, :execution_context_missing} = AgentExecution.current_context()

    assert {:stop, {:accounting_uncertain, :execution_context_missing}} =
             SymphonyElixir.DeliveryEngine.run(c.workspace, c.issue, nil, include_pr_details: false)

    assert GenServer.call(owner, :runtime) == runtime_before
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot_before
    assert journal_bytes(entry) == marker_before
    assert File.read!(entry.lease_token.storage.lease_path) == lease_before
    assert File.read!(c.commands) == commands_before
  end

  test "I2a-18 identified entry without scoped context rejects before provider or hook", c do
    {_owner, _worker, _entry} = start_controlled(c)
    assert {:stop, {:accounting_uncertain, :execution_context_missing}} = AgentProvider.open_session(Claude, c.workspace, c.issue, :main)
    assert {:stop, {:accounting_uncertain, :execution_context_missing}} = Workspace.run_after_run_hook(c.workspace, c.issue)
    refute File.read!(c.commands) =~ "after-run"
    legacy = Path.join(c.root, "LEGACY")
    File.mkdir_p!(legacy)
    assert {:ok, :legacy} = AgentExecution.entry_context(legacy, nil)
    assert {:ok, session, :legacy} = AgentProvider.open_session(Claude, legacy, c.issue, :main)
    assert :ok = AgentProvider.close_session(Claude, session, :legacy)
  end

  test "stop queued before local uncertainty waits for original DOWN and preserves journal", c do
    {owner, worker, entry} = start_controlled(c)
    journal = journal_bytes(entry)
    token_bytes = File.read!(entry.lease_token.storage.lease_path)
    :ok = :sys.suspend(owner)
    stopper = Task.async(fn -> GenServer.call(owner, {:stop, c.issue.id}, 10_000) end)

    try do
      assert_mailbox_contains(owner, fn message -> match?({:"$gen_call", _, {:stop, _}}, message) end)
      assert {:stop, {:accounting_uncertain, :fixture_checkpoint_failed}} = in_worker(worker, fn -> AgentExecution.fail(:fixture_checkpoint_failed) end)
      send(worker, :finish)
    after
      :ok = :sys.resume(owner)
    end

    Task.await(stopper, 10_000)
    assert_receive {:worker_down, ^owner, _, runtime}, 5_000
    assert runtime.running == %{}
    assert runtime.retry_attempts == %{}
    assert {:accounting_uncertain, c.issue.id, :fixture_checkpoint_failed} == runtime.candidate_fetch_error
    assert runtime.lease_claims[c.issue.id].token == entry.lease_token
    assert journal_bytes(entry) == journal
    assert File.read!(entry.lease_token.storage.lease_path) == token_bytes
  end

  for stage <- ["implement", "await_checks"] do
    @held_dispatch_stage stage
    test "I2a-15 #{@held_dispatch_stage} snapshot corruption after gate preserves admission and claim", c do
      assert {:ok, _} = RunStateStore.transition(c.workspace, @held_dispatch_stage)
      owner = start_driver()
      entry = GenServer.call(owner, {:dispatch, c.issue, :held}, 10_000)
      assert is_map(entry)
      assert entry.dispatch_stage == @held_dispatch_stage
      assert_receive {:authorized, ^owner, _, pid}, 5_000
      assert pid == entry.pid
      journal = journal_bytes(entry)
      path = RunStateStore.state_path(c.workspace)
      File.write!(path, "corrupt-after-gate")
      send(entry.pid, :release_worker)
      assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^pid, {:accounting_uncertain, {:dispatch_authorization_failed, _}}}, runtime}, 5_000
      assert runtime.running == %{}
      assert runtime.retry_attempts == %{}
      assert runtime.lease_claims[c.issue.id].token == entry.lease_token
      assert journal_bytes(entry) == journal
      assert File.read!(path) == "corrupt-after-gate"
      refute File.read!(c.commands) =~ "after-run"
    end
  end

  test "healthy stalled worker defers one backoff retry until its original DOWN closes the journal", c do
    {owner, worker, entry} = start_controlled(c)
    requested = GenServer.call(owner, {:restart_stalled, c.issue.id}, 10_000)
    assert requested.running[c.issue.id].pid == worker
    assert requested.retry_attempts == %{}
    intent = requested.running[c.issue.id].execution_stop_requested.retry
    assert intent.attempt == nil
    assert intent.metadata.identifier == c.issue.identifier
    assert intent.metadata.error =~ "stalled for "
    assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, _}, stopped}, 5_000
    assert ref == entry.ref
    assert stopped.running == %{}
    assert stopped.token_usage_errors == %{}
    assert map_size(stopped.retry_attempts) == 1
    retry = stopped.retry_attempts[c.issue.id]
    assert retry.attempt == 1
    assert retry.error == intent.metadata.error
    assert retry.identifier == c.issue.identifier
    assert retry.status == :scheduled
    assert retry.lease_token == entry.lease_token
    assert stopped.lease_claims[c.issue.id].holder == :retry
    assert :ok = DispatchAudit.ensure_available(c.workspace)
  end

  for order <- [:policy_then_control, :control_then_policy] do
    @stop_order order
    test "#{@stop_order} preserves explicit stop over a queued stall retry until DOWN", c do
      {owner, worker, entry} = start_controlled(c)
      policy = {:restart_stalled, c.issue.id}
      control = {:stop_issue, c.issue.identifier}
      [first, second] = if @stop_order == :policy_then_control, do: [policy, control], else: [control, policy]
      :ok = :sys.suspend(owner)
      first_call = Task.async(fn -> GenServer.call(owner, first, 10_000) end)

      second_call =
        try do
          assert_mailbox_contains(owner, fn message -> match?({:"$gen_call", _, ^first}, message) end)
          task = Task.async(fn -> GenServer.call(owner, second, 10_000) end)
          assert_mailbox_contains(owner, fn message -> match?({:"$gen_call", _, ^second}, message) end)
          task
        after
          :ok = :sys.resume(owner)
        end

      results = [Task.await(first_call, 10_000), Task.await(second_call, 10_000)]
      assert Enum.any?(results, &match?(%{ok: true}, &1))
      assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, _}, stopped}, 5_000
      assert ref == entry.ref
      assert stopped.running == %{}
      assert stopped.retry_attempts == %{}
      assert stopped.token_usage_errors == %{}
      assert :ok = DispatchAudit.ensure_available(c.workspace)
    end
  end

  for delay_type <- [:continuation, :passive_continuation] do
    @retry_delay_type delay_type
    test "healthy #{@retry_delay_type} preserves the complete deferred retry metadata", c do
      {owner, worker, entry} = start_controlled(c)

      metadata = %{
        identifier: c.issue.identifier,
        issue: c.issue,
        delay_type: @retry_delay_type,
        budget_retry: true,
        budget_mode: "broad_implement",
        budget_retry_count: 2,
        budget_resume_context: %{target_paths: ["existing.txt"], budget_retry_count: 2},
        error: "adaptive fixture"
      }

      requested = GenServer.call(owner, {:stop_and_retry, c.issue.id, 3, metadata}, 10_000)
      assert requested.running[c.issue.id].execution_stop_requested.retry == %{attempt: 3, metadata: metadata}
      assert requested.retry_attempts == %{}
      assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, _}, stopped}, 5_000
      assert ref == entry.ref
      retry = stopped.retry_attempts[c.issue.id]
      assert Map.take(retry, Map.keys(metadata)) == metadata
      assert retry.attempt == 3
      assert retry.status == :scheduled
      assert retry.lease_token == entry.lease_token
      assert stopped.lease_claims[c.issue.id].holder == :retry
      assert stopped.token_usage_errors == %{}
      assert :ok = DispatchAudit.ensure_available(c.workspace)
    end
  end

  for stage <- ["plan", "implement", "verify"] do
    @consumer_stage stage
    test "I2a-14 public #{@consumer_stage} stops invalid CLI usage before effects and verification completion", c do
      consumer_fixture!(c, "claude", @consumer_stage)
      consumer_cli!(c, "claude", %{"input_tokens" => 7})
      {owner, worker, entry} = start_controlled(c)
      before = consumer_evidence(c)

      assert {:stop, {:accounting_uncertain, :missing_usage_dimension}} =
               in_worker(worker, fn ->
                 SymphonyElixir.DeliveryEngine.run(c.workspace, c.issue, self(),
                   include_pr_details: false,
                   issue_state_fetcher: fn _ -> flunk("refresh after invalid usage") end
                 )
               end)

      # The verify variant invokes public VerifierRunner.verify/5 from the engine
      # and opens B while the initial A handle remains registered.
      assert consumer_commands_after_transport(c) == []
      assert File.read!(before.snapshot_path) == before.snapshot
      assert File.read!(before.marker_path) == before.marker
      assert File.read!(Path.join(c.workspace, "existing.txt")) == before.source
      assert consumer_head(c) == before.head
      refute File.exists?(Path.join(c.root, "after-run"))
      refute Enum.any?(SymphonyElixir.RunLedger.recent_entries(), &(&1["event"] == "verification.completed"))
      assert {:ok, snapshot} = SymphonyElixir.RunStateStore.load(c.workspace)
      assert snapshot.stage == @consumer_stage
      refute snapshot.stage == "blocked"
      assert snapshot.implementation_turns == 0
      consumer_assert_uncertain_down!(c, owner, worker, entry, before)
    end
  end

  for position <- [:before_response, :after_response] do
    @consumer_usage_position position
    test "I2a-09 AppServer #{@consumer_usage_position} checkpoint failure rejects queued approval and tool before reply or after_run", c do
      consumer_fixture!(c, "codex", "implement")
      queued = consumer_app_server!(c, @consumer_usage_position)
      {owner, worker, entry} = start_controlled(c)
      :ok = GenServer.call(owner, {:hold_usage, true})

      task =
        Task.async(fn ->
          in_worker(worker, fn ->
            SymphonyElixir.DeliveryEngine.run(c.workspace, c.issue, self(),
              include_pr_details: false,
              issue_state_fetcher: fn _ -> flunk("refresh after checkpoint failure") end
            )
          end)
        end)

      assert_receive {:usage_held, ^owner, invocation, {:ok, :thread_absolute, %{total_tokens: 10}}}, 2_000
      assert invocation.context.worker == worker
      consumer_await_file!(queued, System.monotonic_time(:millisecond) + 2_000)
      before = consumer_evidence(c)
      ledger = entry.dispatch_ticket.ledger_path
      backup = ledger <> ".consumer-before-fault"
      File.rename!(ledger, backup)
      File.mkdir!(ledger)
      ids = execution_ids(entry)
      requested_event_id = before.marker |> Jason.decode!() |> get_in(["requested", "event_id"])

      try do
        :ok = GenServer.call(owner, :release_usage)

        assert {:stop, {:stale_execution, ^ids, %SymphonyElixir.RunLedger.PersistenceError{phase: :read, reason: :eisdir, confirmation: :uncertain, event_id: ^requested_event_id} = cause}} =
                 Task.await(task, 7_000)

        assert consumer_commands_after_transport(c) == []
        assert File.read!(before.snapshot_path) == before.snapshot
        assert File.read!(before.marker_path) == before.marker
        assert consumer_head(c) == before.head
        refute File.exists?(Path.join(c.root, "after-run"))
        assert GenServer.call(owner, :runtime).agent_totals.total_tokens == 0
        consumer_assert_stale_down!(c, owner, worker, entry, before, cause)
      after
        if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker)
        File.rmdir!(ledger)
        File.rename!(backup, ledger)
      end
    end
  end

  test "I2a-15 AgentRunner preserves accounting uncertainty through after_run and real DOWN", c do
    consumer_fixture!(c, "codex-cli", "implement")
    consumer_cli!(c, "codex-cli", %{"input_tokens" => 7, "output_tokens" => nil})
    assert SymphonyElixir.Workspace.path_for_issue(c.issue) == c.workspace
    assert {:ok, true, _report} = SymphonyElixir.RepoCompatibility.compatible?(c.workspace, include_pr_details: false)
    {owner, worker, entry} = start_controlled(c)
    before = consumer_evidence(c)

    assert {:stop, {:accounting_uncertain, :invalid_usage_dimension}} =
             in_worker(worker, fn ->
               SymphonyElixir.AgentRunner.run(c.issue, self(), include_pr_details: false)
             end)

    assert File.exists?(Path.join(c.root, "before-run"))
    refute File.exists?(Path.join(c.root, "after-run"))
    assert consumer_commands_after_transport(c) == []
    assert File.read!(before.snapshot_path) == before.snapshot
    assert File.read!(before.marker_path) == before.marker
    assert consumer_head(c) == before.head
    consumer_assert_uncertain_down!(c, owner, worker, entry, before)
  end

  defmodule ConsumerUnsupportedProvider do
    def start_session(workspace, opts) do
      send(Keyword.fetch!(opts, :observer), {:unsupported_provider_opened, self()})
      {:ok, %{workspace: workspace, session_id: "unsupported-session"}}
    end

    def stop_session(_session), do: :ok
  end

  test "unsupported accounted provider fails before start_session", c do
    consumer_fixture!(c, "claude", "implement")
    {owner, worker, entry} = start_controlled(c)
    before = consumer_evidence(c)
    observer = self()

    assert {:stop, {:accounting_uncertain, :unsupported_accounting_provider}} =
             in_worker(worker, fn ->
               SymphonyElixir.AgentProvider.open_session(ConsumerUnsupportedProvider, c.workspace, c.issue, :main, observer: observer)
             end)

    refute_received {:unsupported_provider_opened, ^worker}
    assert File.read!(before.snapshot_path) == before.snapshot
    assert File.read!(before.marker_path) == before.marker
    consumer_assert_uncertain_down!(c, owner, worker, entry, before)
  end

  test "invalid AppServer usage before turn/start response prevents session_started and approval", c do
    consumer_fixture!(c, "codex", "implement")
    queued = consumer_app_server!(c, :before_response, %{"inputTokens" => 7})
    {owner, worker, entry} = start_controlled(c)
    before = consumer_evidence(c)

    assert {:stop, {:accounting_uncertain, :missing_usage_dimension}} =
             in_worker(worker, fn ->
               SymphonyElixir.DeliveryEngine.run(c.workspace, c.issue, self(), include_pr_details: false)
             end)

    consumer_await_file!(queued, System.monotonic_time(:millisecond) + 2_000)
    runtime = GenServer.call(owner, :runtime)
    assert runtime.running[c.issue.id].turn_count == 0
    assert runtime.running[c.issue.id].last_agent_event == nil
    assert consumer_commands_after_transport(c) == []
    assert File.read!(before.snapshot_path) == before.snapshot
    consumer_assert_uncertain_down!(c, owner, worker, entry, before)
  end

  defp consumer_fixture!(c, provider, stage) do
    # c.git is the captured real git executable, before the bin shim is installed.
    File.mkdir_p!(c.bin)
    File.mkdir_p!(Path.join(c.workspace, ".symphony/progress"))
    File.write!(Path.join(c.workspace, "existing.txt"), "initial\n")
    File.write!(Path.join(c.workspace, ".gitignore"), ".symphony/run_state.json\n")
    File.write!(Path.join(c.workspace, ".symphony/progress/#{c.issue.identifier}.md"), "## Work Log\n\n## Evidence\n\n")

    File.write!(Path.join(c.workspace, ".symphony/harness.yml"), """
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

    for args <- [
          ["init", "-b", "main"],
          ["config", "user.name", "I2a Fixture"],
          ["config", "user.email", "i2a@example.invalid"],
          ["add", "-A"],
          ["commit", "-qm", "consumer fixture"],
          ["update-ref", "refs/remotes/origin/main", "HEAD"]
        ] do
      assert {_output, 0} = System.cmd(c.git, args, cd: c.workspace, stderr_to_stdout: true)
    end

    File.write!(c.commands, "")
    write_script!(Path.join(c.bin, "git"), "printf 'git %s\\n' \"$*\" >> #{consumer_quote(c.commands)}\nexec #{consumer_quote(c.git)} \"$@\"\n")
    write_script!(Path.join(c.bin, "mix"), "printf 'mix %s\\n' \"$*\" >> #{consumer_quote(c.commands)}\nexit 0\n")
    write_script!(Path.join(c.bin, "gh"), "exit 1\n")
    System.put_env("PATH", c.bin <> ":" <> System.fetch_env!("PATH"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(c.workspace),
      runner_install_root: Path.join(c.root, "runner-install"),
      max_concurrent_agents: 1,
      max_turns: 2,
      codex_command: consumer_quote(Path.join(c.bin, "codex")) <> " app-server",
      codex_approval_policy: "never",
      policy_require_verifier: true,
      policy_require_checkout: true,
      hook_before_run: "touch #{consumer_quote(Path.join(c.root, "before-run"))}",
      hook_after_run: "touch #{consumer_quote(Path.join(c.root, "after-run"))}"
    )

    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "agent:\n", "agent:\n  provider: #{provider}\n"))
    :ok = WorkflowStore.force_reload()
    assert {:ok, _} = SymphonyElixir.RepoHarness.load(c.workspace)
    assert {:ok, _} = SymphonyElixir.RunStateStore.transition(c.workspace, stage, %{issue_id: c.issue.id, issue_identifier: c.issue.identifier})
  end

  defp consumer_cli!(c, provider, usage) do
    event =
      if provider == "claude",
        do: %{"type" => "result", "result" => "consumer result", "usage" => usage},
        else: %{"type" => "turn.completed", "usage" => usage}

    binary = if provider == "claude", do: "claude", else: "codex"

    write_script!(
      Path.join(c.bin, binary),
      "printf 'transport\\n' >> #{consumer_quote(c.commands)}\n" <>
        "printf '%s\\n' #{consumer_quote(Jason.encode!(event))}\n"
    )
  end

  defp consumer_app_server!(c, usage_position, usage \\ %{"inputTokens" => 7, "outputTokens" => 3, "totalTokens" => 10}) do
    queued = Path.join(c.root, "approval-and-tool-queued")
    response = %{"id" => 3, "result" => %{"turn" => %{"id" => "i2a-turn"}}}
    observation = %{"method" => "thread/tokenUsage/updated", "params" => %{"threadId" => "i2a-thread", "tokenUsage" => %{"total" => usage}}}
    messages = if usage_position == :before_response, do: [observation, response], else: [response, observation]
    startup_lines = Enum.map_join(messages, "\n", fn message -> "printf '%s\\n' " <> consumer_quote(Jason.encode!(message)) end)

    write_script!(Path.join(c.bin, "codex"), """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"i2a-thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf 'transport\\n' >> #{consumer_quote(c.commands)}
          #{startup_lines}
          printf '%s\\n' '{"id":71,"method":"item/commandExecution/requestApproval","params":{"command":"printf forbidden"}}'
          printf '%s\\n' '{"id":72,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"must not be recorded","files_touched":[],"blocked":false,"blocker_type":"none","needs_another_turn":false}}}'
          touch #{consumer_quote(queued)}
          ;;
        *'"id":71'*) printf 'approval-reply\\n' >> #{consumer_quote(c.commands)} ;;
        *'"id":72'*) printf 'tool-reply\\n' >> #{consumer_quote(c.commands)} ;;
      esac
    done
    """)

    queued
  end

  defp consumer_evidence(c) do
    snapshot_path = SymphonyElixir.RunStateStore.state_path(c.workspace)
    marker_path = Path.join(SymphonyElixir.DispatchAudit.marker_directory(c.workspace), "marker.json")

    %{
      snapshot_path: snapshot_path,
      snapshot: File.read!(snapshot_path),
      marker_path: marker_path,
      marker: File.read!(marker_path),
      source: File.read!(Path.join(c.workspace, "existing.txt")),
      head: consumer_head(c)
    }
  end

  defp consumer_head(c) do
    assert {head, 0} = System.cmd(c.git, ["rev-parse", "HEAD"], cd: c.workspace)
    head
  end

  defp consumer_commands_after_transport(c) do
    commands = c.commands |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(commands, &(&1 == "transport")) == 1
    ["transport" | after_transport] = Enum.drop_while(commands, &(&1 != "transport"))
    after_transport
  end

  defp consumer_assert_uncertain_down!(c, owner, worker, entry, before) do
    runtime = GenServer.call(owner, :runtime)
    assert runtime.running[c.issue.id].pid == worker
    assert runtime.running[c.issue.id].agent_execution.registry.uncertain != nil
    assert {:accounting_uncertain, %{context: captured}} = runtime.token_usage_errors[c.issue.id]
    assert captured.ticket == entry.dispatch_ticket
    assert runtime.running[c.issue.id].dispatch_ticket == entry.dispatch_ticket
    claim = runtime.lease_claims[c.issue.id]
    assert claim.holder == :running
    assert claim.token == entry.lease_token
    refute Map.has_key?(runtime.retry_attempts, c.issue.id)
    lease = File.read!(entry.lease_token.storage.lease_path)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, {:accounting_uncertain, _}}, stopped}, 2_000
    assert ref == entry.ref
    refute Map.has_key?(stopped.running, c.issue.id)
    assert stopped.lease_claims[c.issue.id] == claim
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    refute Map.has_key?(stopped.completed, c.issue.id)
    assert File.read!(entry.lease_token.storage.lease_path) == lease
    assert File.read!(before.snapshot_path) == before.snapshot
    assert File.read!(before.marker_path) == before.marker
  end

  defp consumer_assert_stale_down!(c, owner, worker, entry, before, cause) do
    ids = execution_ids(entry)
    runtime = GenServer.call(owner, :runtime)
    assert runtime.running[c.issue.id].pid == worker
    assert runtime.running[c.issue.id].agent_execution.registry.uncertain == nil
    assert runtime.running[c.issue.id].agent_execution.terminal == {:stale_execution, ids, cause}
    assert runtime.stale_execution_errors[c.issue.id] == %{context: entry.agent_execution.context, ids: ids, cause: cause}
    assert runtime.token_usage_errors == %{}
    assert runtime.running[c.issue.id].dispatch_ticket == entry.dispatch_ticket
    claim = runtime.lease_claims[c.issue.id]
    assert claim.holder == :running
    assert claim.token == entry.lease_token
    refute Map.has_key?(runtime.retry_attempts, c.issue.id)
    totals = Map.take(runtime.agent_totals, [:input_tokens, :output_tokens, :total_tokens])
    lease = File.read!(entry.lease_token.storage.lease_path)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, {:stale_execution, ^ids, ^cause}}, stopped}, 2_000
    assert ref == entry.ref
    refute Map.has_key?(stopped.running, c.issue.id)
    assert stopped.lease_claims[c.issue.id] == claim
    assert stopped.stale_execution_errors == runtime.stale_execution_errors
    assert stopped.token_usage_errors == %{}
    assert Map.take(stopped.agent_totals, [:input_tokens, :output_tokens, :total_tokens]) == totals
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    refute Map.has_key?(stopped.completed, c.issue.id)
    assert File.read!(entry.lease_token.storage.lease_path) == lease
    assert File.read!(before.snapshot_path) == before.snapshot
    assert File.read!(before.marker_path) == before.marker
  end

  defp consumer_await_file!(path, deadline) do
    unless File.exists?(path) do
      assert System.monotonic_time(:millisecond) < deadline, "AppServer did not queue approval/tool"

      receive do
      after
        5 -> consumer_await_file!(path, deadline)
      end
    end
  end

  defp consumer_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  test "F3 real accounted usage schedules adaptive retry only after healthy DOWN", c do
    f3_budget_fixture!(c)
    {owner, worker, entry} = start_controlled(c)
    invocation = register_invocation(worker, Claude, c.workspace, :main)
    exercise_ref = make_ref()

    # The admitted worker sends its real authenticated observation and blocks in
    # confirmation. RunPolicy deliberately terminates it at the budget boundary;
    # no exercise return is required from a worker that has been stopped.
    send(
      worker,
      {:exercise, self(), exercise_ref,
       fn ->
         AgentExecution.observe_usage(invocation, %{usage: counters(150_000)})
       end}
    )

    assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, reason}, stopped}, 5_000
    assert ref == entry.ref
    refute match?({:accounting_uncertain, _}, reason)
    assert stopped.running == %{}
    assert stopped.token_usage_errors == %{}
    assert stopped.agent_totals.total_tokens == 150_000
    assert map_size(stopped.retry_attempts) == 1
    retry = Map.fetch!(stopped.retry_attempts, c.issue.id)
    assert retry.attempt == 1
    assert retry.status == :scheduled
    assert retry.delay_type == :continuation
    assert retry.issue == c.issue
    assert retry.identifier == c.issue.identifier
    assert retry.budget_retry == true
    assert retry.budget_mode == "broad_implement"
    assert retry.budget_retry_count == 1
    assert retry.error == "Adaptive broad-implement retry scheduled with one focused file."
    assert retry.budget_resume_context.target_paths == ["lib/example.ex"]
    assert retry.budget_resume_context.budget_retry_count == 1
    assert retry.budget_resume_context.budget_last_observed_input_tokens == 150_000
    assert retry.lease_token == entry.lease_token
    assert stopped.lease_claims[c.issue.id].holder == :retry
    assert :ok = DispatchAudit.ensure_available(c.workspace)
    assert {:ok, snapshot} = RunStateStore.load(c.workspace)
    assert snapshot.stage == "implement"
    assert snapshot.token_usage == counters(150_000)
    assert snapshot.resume_context == retry.budget_resume_context
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "F3 public stop before queued accounted usage cannot reactivate budget policy before DOWN", c do
    f3_budget_fixture!(c)
    {owner, worker, entry} = start_controlled(c)
    invocation = register_invocation(worker, Claude, c.workspace, :main)
    control = {:stop_issue, c.issue.identifier}
    :ok = :sys.suspend(owner)
    stopper = Task.async(fn -> GenServer.call(owner, control, 10_000) end)

    try do
      assert_mailbox_contains(owner, fn message -> match?({:"$gen_call", _, ^control}, message) end)

      send(
        worker,
        {:exercise, self(), make_ref(),
         fn ->
           AgentExecution.observe_usage(invocation, %{usage: counters(150_000)})
         end}
      )

      assert_mailbox_contains(owner, fn message ->
        match?({:agent_execution_usage, ^invocation, _, {:ok, :invocation_absolute, _}}, message)
      end)

      assert_mailbox_contains(owner, fn message ->
        match?({:"$gen_call", _, {:agent_execution, _, _, {:confirm, _, _}}}, message)
      end)
    after
      :ok = :sys.resume(owner)
    end

    assert %{ok: true, action: "stop", state: "Blocked"} = Task.await(stopper, 10_000)
    assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, reason}, stopped}, 5_000
    assert ref == entry.ref
    refute match?({:accounting_uncertain, _}, reason)
    assert stopped.running == %{}
    assert stopped.retry_attempts == %{}
    assert stopped.token_usage_errors == %{}
    assert stopped.agent_totals.total_tokens == 150_000
    assert :ok = DispatchAudit.ensure_available(c.workspace)
    assert {:ok, snapshot} = RunStateStore.load(c.workspace)
    assert snapshot.token_usage == counters(150_000)
    assert snapshot.resume_context == %{target_paths: ["lib/example.ex"]}
    assert snapshot.stage == "implement"

    # Public stop intentionally comments and updates the tracker. Require those
    # exact control effects once; the later usage must add no budget effects.
    issue_id = c.issue.id
    assert_receive {:memory_tracker_comment, ^issue_id, comment}, 1_000
    assert comment =~ "Rule ID: operator.stop"
    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 1_000
    refute_received {:memory_tracker_comment, ^issue_id, _}
    refute_received {:memory_tracker_state_update, ^issue_id, _}

    refute Enum.any?(SymphonyElixir.RunLedger.recent_entries(), fn event ->
             event["issue_id"] == issue_id and event["actor_id"] == "run_policy"
           end)
  end

  defp f3_budget_fixture!(c) do
    # Exact broad budget from BroadBudgetRecoveryTest; target selection is
    # captured before admission as in RetryBudgetTotalsTest.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: c.root,
      runner_install_root: Path.join(c.root, "runner-install"),
      observability_tracing_enabled: false,
      policy_token_budget: %{
        per_turn_input: 150_000,
        per_issue_total: 500_000,
        per_issue_total_output: 10_000,
        stages: %{implement: %{per_turn_input_soft: 60_000, per_turn_input_hard: 120_000}},
        broad_implement: %{enabled: true, auto_retry_limit: 2}
      }
    )

    :ok = WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    assert {:ok, _} = RunStateStore.transition(c.workspace, "implement", %{resume_context: %{target_paths: ["lib/example.ex"]}})
  end

  test "healthy AppServer checkpoints pre-response usage before its tool executes in the admitted worker", c do
    consumer_fixture!(c, "codex", "implement")

    replies =
      positive_app_server!(c, "report_agent_turn_result", %{
        "summary" => "local callback proof",
        "files_touched" => [],
        "blocked" => false,
        "blocker_type" => "none",
        "needs_another_turn" => false
      })

    {owner, worker, _entry} = start_controlled(c)
    observer = self()
    before = consumer_evidence(c)
    usage = %{input_tokens: 7, output_tokens: 3, total_tokens: 10}

    assert {:ok, %{result: :turn_completed, thread_id: "i2-positive-thread"}} =
             in_worker(worker, fn ->
               {:ok, session, binding} = AgentProvider.open_session(Codex, c.workspace, c.issue, :main)

               try do
                 AgentProvider.run_turn(
                   Codex,
                   session,
                   c.workspace,
                   "prove callback custody",
                   c.issue,
                   [
                     execution_binding: binding,
                     on_message: fn update ->
                       if update.event == :session_started do
                         assert {:ok, %{token_usage: ^usage}} = RunStateStore.load(c.workspace)
                       end

                       send(observer, {:positive_callback, self(), update.event})
                       :ok
                     end,
                     tool_executor: fn tool, _arguments ->
                       assert {:ok, %{token_usage: ^usage}} = RunStateStore.load(c.workspace)
                       assert {:ok, context} = AgentExecution.current_context()
                       send(observer, {:positive_tool, self(), tool, context.worker})
                       %{"success" => true, "contentItems" => [%{"type" => "inputText", "text" => "recorded"}]}
                     end
                   ],
                   :delivery
                 )
               after
                 assert :ok = AgentProvider.close_session(Codex, session, binding)
               end
             end)

    assert_receive {:positive_callback, ^worker, :session_started}, 1_000
    assert_receive {:positive_tool, ^worker, "report_agent_turn_result", ^worker}, 1_000
    assert_receive {:positive_callback, ^worker, :tool_call_completed}, 1_000
    assert_receive {:positive_callback, ^worker, :turn_completed}, 1_000
    [reply] = replies |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert %{"id" => 72, "result" => %{"success" => true}} = reply
    runtime = GenServer.call(owner, :runtime)
    assert runtime.agent_totals.total_tokens == 10
    assert runtime.running[c.issue.id].agent_execution.registry.uncertain == nil
    assert runtime.running[c.issue.id].agent_execution.registry.current == nil
    assert runtime.token_usage_errors == %{}
    assert {:ok, %{token_usage: ^usage}} = RunStateStore.load(c.workspace)
    assert File.read!(Path.join(c.workspace, "existing.txt")) == before.source
    assert consumer_head(c) == before.head
  end

  test "audited public verifier reports its real tool result and completes without mutating code", c do
    consumer_fixture!(c, "codex", "verify")

    replies =
      positive_app_server!(c, "report_verifier_result", %{
        "verdict" => "pass",
        "summary" => "Reviewed by the real verifier report tool",
        "acceptance_gaps" => [],
        "risky_areas" => [],
        "evidence" => ["Local smoke passed"],
        "raw_output" => "pass"
      })

    {owner, worker, _entry} = start_controlled(c)
    observer = self()
    before = consumer_evidence(c)
    usage = %{input_tokens: 7, output_tokens: 3, total_tokens: 10}

    result =
      in_worker(worker, fn ->
        assert {:ok, snapshot} = RunStateStore.load(c.workspace)
        inspection = SymphonyElixir.RunInspector.inspect(c.workspace, include_pr_details: false)

        SymphonyElixir.VerifierRunner.verify(c.workspace, c.issue, snapshot, inspection,
          include_pr_details: false,
          on_message: fn update ->
            if update.event == :tool_call_completed do
              assert get_in(update, [:payload, "params", "tool"]) == "report_verifier_result"
              assert {:ok, %{token_usage: ^usage}} = RunStateStore.load(c.workspace)
            end

            send(observer, {:positive_verifier_callback, self(), update.event})
            :ok
          end
        )
      end)

    assert result.verdict == "pass"
    assert result.summary == "Reviewed by the real verifier report tool"
    assert result.smoke.status == :passed
    assert result.raw_output == "pass"
    assert_receive {:positive_verifier_callback, ^worker, :session_started}, 1_000
    assert_receive {:positive_verifier_callback, ^worker, :tool_call_completed}, 1_000
    assert_receive {:positive_verifier_callback, ^worker, :turn_completed}, 1_000
    [reply] = replies |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert %{"id" => 72, "result" => %{"success" => true, "contentItems" => [%{"text" => "verifier result recorded"}]}} = reply
    runtime = GenServer.call(owner, :runtime)
    registry = runtime.running[c.issue.id].agent_execution.registry
    assert Map.has_key?(registry.retired, {Codex, :thread, "i2-positive-thread"})
    assert registry.current == nil
    assert registry.uncertain == nil
    assert runtime.agent_totals.total_tokens == 10
    assert runtime.token_usage_errors == %{}
    assert {:ok, %{token_usage: ^usage}} = RunStateStore.load(c.workspace)
    assert File.read!(Path.join(c.workspace, "existing.txt")) == before.source
    assert consumer_head(c) == before.head
  end

  defp positive_app_server!(c, tool, arguments) do
    replies = Path.join(c.root, "positive-app-server-replies.jsonl")
    File.write!(replies, "")

    observation = %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{
        "threadId" => "i2-positive-thread",
        "tokenUsage" => %{"total" => %{"inputTokens" => 7, "outputTokens" => 3, "totalTokens" => 10}}
      }
    }

    request = %{
      "id" => 72,
      "method" => "item/tool/call",
      "params" => %{
        "tool" => tool,
        "arguments" => arguments,
        "callId" => "i2-positive-call",
        "threadId" => "i2-positive-thread",
        "turnId" => "i2-positive-turn"
      }
    }

    write_script!(Path.join(c.bin, "codex"), """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"i2-positive-thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf 'transport\\n' >> #{consumer_quote(c.commands)}
          printf '%s\\n' #{consumer_quote(Jason.encode!(observation))}
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"i2-positive-turn"}}}'
          printf '%s\\n' #{consumer_quote(Jason.encode!(request))}
          ;;
        *'"id":72'*)
          printf '%s\\n' "$line" >> #{consumer_quote(replies)}
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    replies
  end

  defp start_driver do
    {:ok, owner} = GenServer.start(Driver, self())

    on_exit(fn ->
      if Process.alive?(owner) do
        runtime = GenServer.call(owner, :runtime)
        Enum.each(runtime.running, fn {_id, entry} -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid) end)
        GenServer.stop(owner)
      end
    end)

    owner
  end

  defp start_controlled(c) do
    owner = start_driver()
    entry = controlled_dispatch(owner, c.issue)
    {owner, entry.pid, entry}
  end

  defp controlled_dispatch(owner, issue) do
    entry = GenServer.call(owner, {:dispatch, issue, :controlled}, 10_000)
    assert is_map(entry)
    worker = entry.pid
    assert_receive {:worker_ready, ^worker, context, expected}, 5_000
    assert context == entry.agent_execution.context
    assert expected === entry.agent_execution.expected
    on_exit(fn -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
    entry
  end

  defp in_worker(worker, fun) do
    ref = make_ref()
    send(worker, {:exercise, self(), ref, fun})

    receive do
      {:exercise_result, ^ref, {:fixture_exception, exception, stack}} -> reraise exception, stack
      {:exercise_result, ^ref, {:fixture_caught, kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
      {:exercise_result, ^ref, result} -> result
    after
      10_000 -> flunk("admitted worker did not return fixture operation")
    end
  end

  defp register_invocation(worker, provider, workspace, purpose) do
    in_worker(worker, fn ->
      {:ok, session} = provider.start_session(workspace)
      {:ok, binding} = AgentExecution.register_session(provider, session, purpose)
      {:ok, invocation} = AgentExecution.begin_invocation(binding)
      invocation
    end)
  end

  defp assert_mailbox_contains(pid, predicate, attempts \\ 100)
  defp assert_mailbox_contains(_pid, _predicate, 0), do: flunk("expected fixture message was not queued")

  defp assert_mailbox_contains(pid, predicate, attempts) do
    {:messages, messages} = Process.info(pid, :messages)

    if Enum.any?(messages, predicate),
      do: :ok,
      else:
        (
          Process.sleep(5)
          assert_mailbox_contains(pid, predicate, attempts - 1)
        )
  end

  defp execution_ids(entry), do: %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
  defp journal_bytes(entry), do: File.read!(Path.join(DispatchAudit.marker_directory(entry.workspace_path), "marker.json"))
  defp counters(value), do: %{input_tokens: value, output_tokens: 0, total_tokens: value}

  defp write_script!(path, body),
    do:
      (
        File.write!(path, "#!/bin/sh\n" <> body)
        File.chmod!(path, 0o755)
      )
end
