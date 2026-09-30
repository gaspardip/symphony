defmodule SymphonyElixir.ExecutionCurrentBoundaryIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, AgentProvider, DispatchAudit, LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.AgentProvider.Claude

  # Every protocol message is delegated unchanged to the real owner handlers.
  # Holds below delay delivery only; they do not manufacture an owner response,
  # registry entry, receipt, terminal reason, or DOWN.
  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, Orchestrator, RunStateStore}

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    @impl true
    def init(observer) do
      runtime = %Orchestrator.State{
        lease_owner: "boundary-owner-#{System.unique_integer([:positive])}",
        max_concurrent_agents: 2,
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
      }

      {:ok, %{runtime: runtime, observer: observer, hold_usage: false, usage: [], hold_down: false, down: nil, hold_stale: false, stale: nil, hold_confirm: false, confirm: nil}}
    end

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}
    def handle_call({:hold_usage, value}, _from, state), do: {:reply, :ok, %{state | hold_usage: value}}
    def handle_call({:hold_down, value}, _from, state), do: {:reply, :ok, %{state | hold_down: value}}
    def handle_call({:hold_stale, value}, _from, state), do: {:reply, :ok, %{state | hold_stale: value}}
    def handle_call(:hold_next_confirm, _from, state), do: {:reply, :ok, %{state | hold_confirm: true}}

    def handle_call({:dispatch, issue}, _from, state) do
      owner = self()
      observer = state.observer

      start_child = fn supervisor, _job ->
        # Same captured-worker fixture as OwnerCurrent: capture before the child
        # is returned, then enter only through the actual dispatch gate.
        raw = issue |> SymphonyElixir.Workspace.path_for_issue() |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

        Task.Supervisor.start_child(supervisor, fn ->
          receive do
            {:captured, context} ->
              result =
                DispatchGate.run(owner, context.ticket.dispatch_id, fn ->
                  DispatchAudit.with_authorization(context.ticket, fn ->
                    AgentExecution.with_context(context.ticket, context.lease_token, owner, raw, fn ->
                      send(observer, {:worker_ready, self(), context})
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
      entry = Map.fetch!(runtime.running, issue.id)
      send(entry.pid, {:captured, entry.agent_execution.context})
      {:reply, entry, %{state | runtime: runtime}}
    end

    def handle_call({:stop, id}, _from, state) do
      runtime = Orchestrator.terminate_running_issue(state.runtime, id, false)
      {:reply, :ok, %{state | runtime: runtime}}
    end

    def handle_call(:release_usage, _from, state) do
      runtime =
        Enum.reduce(state.usage, state.runtime, fn message, runtime ->
          {:noreply, next} = Orchestrator.handle_info(message, runtime)
          next
        end)

      {:reply, :ok, %{state | runtime: runtime, usage: [], hold_usage: false}}
    end

    def handle_call(:release_first_usage, _from, %{usage: [message | rest]} = state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:reply, :ok, %{state | runtime: runtime, usage: rest}}
    end

    def handle_call(:release_stale, _from, %{stale: message} = state) when not is_nil(message) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:reply, :ok, %{state | runtime: runtime, stale: nil, hold_stale: false}}
    end

    def handle_call(:release_down, _from, %{down: message} = state) when not is_nil(message) do
      {:reply, :ok, consume_down(message, %{state | hold_down: false, down: nil})}
    end

    def handle_call(:release_confirm, _from, %{confirm: {from, reply}} = state) do
      GenServer.reply(from, reply)
      {:reply, :ok, %{state | confirm: nil}}
    end

    def handle_call({:agent_execution, _invocation, _expected, {:confirm, _, _}} = message, from, %{hold_confirm: true} = state) do
      {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      send(state.observer, {:owner_confirmed, self(), reply})
      {:noreply, %{state | runtime: runtime, hold_confirm: false, confirm: {from, reply}}}
    end

    def handle_call(message, from, state) do
      {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      {:reply, reply, %{state | runtime: runtime}}
    end

    @impl true
    def handle_info({:agent_execution_usage, _, _, _} = message, %{hold_usage: true} = state) do
      send(state.observer, {:usage_held, self(), message})
      {:noreply, %{state | usage: state.usage ++ [message]}}
    end

    def handle_info({:agent_execution_stale, _, _, _} = message, %{hold_stale: true, stale: nil} = state) do
      send(state.observer, {:stale_held, self(), message})
      {:noreply, %{state | stale: message}}
    end

    def handle_info({:DOWN, _, :process, _, _} = message, %{hold_down: true, down: nil} = state) do
      send(state.observer, {:down_held, self(), message})
      {:noreply, %{state | down: message}}
    end

    def handle_info({:DOWN, _, :process, _, _} = message, state), do: {:noreply, consume_down(message, state)}

    def handle_info(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end

    defp consume_down(message, state) do
      send(state.observer, {:before_worker_down, self(), message, state.runtime})
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      send(state.observer, {:worker_down, self(), message, runtime})
      %{state | runtime: runtime}
    end

    defp worker_loop do
      receive do
        {:exercise, caller, ref, fun} ->
          result =
            try do
              fun.()
            rescue
              exception -> {:fixture_exception, exception, __STACKTRACE__}
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
    root = Path.join(System.tmp_dir!(), "execution-boundary-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    commands = Path.join(root, "commands")

    issue = %Issue{
      id: "boundary-#{System.unique_integer([:positive])}",
      identifier: "BOUNDARY-1",
      title: "Current boundary",
      description: "## Acceptance Criteria\n- preserve current state",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    configure!(root, 500_000)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    File.mkdir_p!(bin)
    git = System.find_executable("git")
    File.write!(Path.join(workspace, "keep.txt"), "preserve workspace")
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Boundary Fixture"],
          ["config", "user.email", "boundary@example.invalid"],
          ["add", "-A"],
          ["commit", "-qm", "fixture"],
          ["update-ref", "refs/remotes/origin/main", "HEAD"],
          ["checkout", "-q", "-b", SymphonyElixir.GitManager.issue_branch_name(issue)]
        ] do
      assert {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
    end

    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    File.write!(commands, "")
    write_script!(Path.join(bin, "git"), "printf 'git %s\\n' \"$*\" >> #{quote_shell(commands)}\nexec #{quote_shell(git)} \"$@\"\n")
    write_script!(Path.join(bin, "gh"), "exit 1\n")
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, bin: bin, commands: commands, git: git}
  end

  test "G04 swallowed stale callback cannot turn a healthy CLI return into TurnEffects", c do
    cli!(c)
    {owner, worker, entry} = start_worker(c)
    observer = self()
    ids = ids(entry)

    assert {:stop, {:stale_execution, ^ids, :material_state_changed}} =
             in_worker(worker, fn ->
               {:ok, session, binding} = AgentProvider.open_session(Claude, c.workspace, c.issue, :main)

               AgentProvider.run_turn(
                 Claude,
                 session,
                 c.workspace,
                 "caught stale",
                 c.issue,
                 [
                   execution_binding: binding,
                   on_message: fn update ->
                     send(observer, {:callback, self(), update.event})
                     assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "operator"))
                     assert {:stop, {:stale_execution, ^ids, :material_state_changed}} = AgentExecution.ensure_current()
                     File.write!(c.commands, "stale-boundary\n", [:append])
                     :ok
                   end,
                   tool_executor: fn tool, _ ->
                     send(observer, {:tool, tool})
                     %{"success" => true}
                   end
                 ],
                 :delivery
               )
             end)

    assert_receive {:callback, ^worker, :notification}, 2_000
    refute_received {:callback, ^worker, _}
    refute_received {:tool, _}
    assert after_marker(c, "stale-boundary") == []
    assert raw!(c)["policy_override"] == "operator"
    assert runtime(owner).stale_execution_errors[c.issue.id].cause == :material_state_changed
    before = evidence(c, entry)
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_stale_hold(c, entry, stopped, :material_state_changed)
    assert evidence(c, entry) == before
  end

  test "G04 own terminal denies retained callbacks and final effects through AgentProvider", c do
    cli!(c, 2)
    {owner, worker, _entry} = start_worker(c)
    observer = self()

    assert {:stop, {:execution_stopped, %{stage: "done"}}} =
             in_worker(worker, fn ->
               {:ok, session, binding} = AgentProvider.open_session(Claude, c.workspace, c.issue, :main)

               AgentProvider.run_turn(
                 Claude,
                 session,
                 c.workspace,
                 "own done",
                 c.issue,
                 [
                   execution_binding: binding,
                   on_message: fn update ->
                     send(observer, {:callback, self(), update.event})
                     assert {:ok, _} = AgentExecution.transition_current("done", %{})
                     File.write!(c.commands, "done-boundary\n", [:append])
                     :ok
                   end,
                   tool_executor: fn tool, _ ->
                     send(observer, {:tool, tool})
                     %{"success" => true}
                   end
                 ],
                 :delivery
               )
             end)

    assert_receive {:callback, ^worker, :notification}, 2_000
    refute_received {:callback, ^worker, _}
    refute_received {:tool, _}
    assert after_marker(c, "done-boundary") == []
    current = runtime(owner)
    assert current.running[c.issue.id].agent_execution.known_terminal.stage == "done"
    assert current.agent_totals.total_tokens == 10
    assert current.token_usage_errors == %{} and current.stale_execution_errors == %{}
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert Map.has_key?(stopped.completed, c.issue.id)
    assert stopped.lease_claims == %{} and stopped.retry_attempts == %{}
  end

  test "G04 ordinary tool stop remains an invalid tool result and cannot become authority", c do
    cli!(c)
    {owner, worker, _entry} = start_worker(c)
    observer = self()

    assert {:error, {:turn_effect_failed, %{step: :report_turn_result, reason: :invalid_tool_response, response: {:stop, :ordinary_tool_result}}}} =
             in_worker(worker, fn ->
               {:ok, session, binding} = AgentProvider.open_session(Claude, c.workspace, c.issue, :main)

               opts = [
                 execution_binding: binding,
                 on_message: fn update ->
                   send(observer, {:callback, self(), update.event})
                   :ok
                 end,
                 tool_executor: fn tool, _ ->
                   send(observer, {:tool, tool})
                   {:stop, :ordinary_tool_result}
                 end
               ]

               result = AgentProvider.run_turn(Claude, session, c.workspace, "ordinary tool result", c.issue, opts, :delivery)
               assert {:ok, _} = AgentExecution.ensure_current()

               succeeding =
                 Keyword.put(opts, :tool_executor, fn _, _ ->
                   send(observer, :next_tool)
                   %{"success" => true}
                 end)

               assert {:ok, %{result: :turn_completed}} = AgentProvider.run_turn(Claude, session, c.workspace, "still current", c.issue, succeeding, :delivery)
               assert :ok = AgentProvider.close_session(Claude, session, binding)
               result
             end)

    assert_receive {:tool, "report_agent_turn_result"}, 2_000
    assert_receive {:callback, ^worker, :turn_ended_with_error}, 2_000
    assert_receive :next_tool, 2_000
    assert_receive {:callback, ^worker, :turn_completed}, 2_000
    current = runtime(owner)
    assert current.token_usage_errors == %{} and current.stale_execution_errors == %{}
    assert current.running[c.issue.id].agent_execution.terminal == nil
    assert current.running[c.issue.id].agent_execution.known_terminal == nil
    assert current.agent_totals.total_tokens == 20
  end

  test "G04 ordinary adapter error remains exact while the wrapper is current", c do
    cli!(c)
    {owner, worker, _entry} = start_worker(c)
    observer = self()

    assert {:error, {:throw, :ordinary_callback_failure}} =
             in_worker(worker, fn ->
               {:ok, session, binding} = AgentProvider.open_session(Claude, c.workspace, c.issue, :main)

               result =
                 AgentProvider.run_turn(
                   Claude,
                   session,
                   c.workspace,
                   "ordinary error",
                   c.issue,
                   [
                     execution_binding: binding,
                     on_message: fn
                       %{event: :notification} ->
                         throw(:ordinary_callback_failure)

                       update ->
                         send(observer, {:callback, self(), update.event})
                         :ok
                     end,
                     tool_executor: fn tool, _ ->
                       send(observer, {:tool, tool})
                       %{"success" => true}
                     end
                   ],
                   :delivery
                 )

               assert {:ok, _} = AgentExecution.ensure_current()
               assert :ok = AgentProvider.close_session(Claude, session, binding)
               result
             end)

    assert_receive {:callback, ^worker, :turn_ended_with_error}, 2_000
    refute_received {:callback, ^worker, _}
    refute_received {:tool, _}
    current = runtime(owner)
    assert current.token_usage_errors == %{} and current.stale_execution_errors == %{}
    assert current.running[c.issue.id].agent_execution.terminal == nil
    assert raw!(c)["stage"] == "implement"
  end

  test "G07 control after owner confirmation rejects the worker precheck before lifecycle", c do
    {owner, worker, entry} = start_worker(c)
    before = evidence(c, entry)
    control = raw!(c) |> Map.put("stage", "blocked") |> Map.put("policy_override", "operator-between-guards") |> Jason.encode!()
    assert :ok = GenServer.call(owner, :hold_next_confirm)
    ref = request_worker(worker, fn -> Workspace.create_for_issue(c.issue) end)
    assert_receive {:owner_confirmed, ^owner, :ok}, 2_000
    observer = self()

    controller =
      spawn_link(fn ->
        lock = {{RunStateStore, Path.expand(c.workspace)}, self()}
        true = :global.set_lock(lock, [node()], 0)

        try do
          File.write!(RunStateStore.state_path(c.workspace), control)
          send(observer, {:control_written, self()})

          receive do
            :release -> :ok
          end
        after
          true = :global.del_lock(lock, [node()])
        end
      end)

    assert_receive {:control_written, ^controller}, 2_000
    assert :ok = GenServer.call(owner, :release_confirm)
    send(controller, :release)
    ids = ids(entry)
    cause = {:persisted_stage_requires_explicit_resume, "blocked"}
    assert {:stop, {:stale_execution, ^ids, ^cause}} = worker_result(ref)
    assert evidence(c, entry) == %{before | snapshot: control}
    assert File.dir?(Path.join(c.workspace, ".git"))
    assert File.read!(Path.join(c.workspace, "keep.txt")) == "preserve workspace"
    refute File.exists?(Path.join(c.root, "after-create"))
    assert Path.wildcard(Path.join(Path.dirname(c.workspace), ".BOUNDARY-1.bootstrap-*"), match_dot: true) == []
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_stale_hold(c, entry, stopped, cause)
    assert evidence(c, entry) == %{before | snapshot: control}
  end

  test "G08 own done cannot authorize a blocked stop notification", c do
    {owner, worker, entry} = start_worker(c)
    assert {:ok, _} = in_worker(worker, fn -> AgentExecution.transition_current("done", %{}) end)
    before = evidence(c, entry)
    assert {:stop, {:accounting_uncertain, :stop_notification_not_authorized}} = in_worker(worker, &AgentExecution.confirm_stop_notification/0)
    assert {:accounting_uncertain, %{cause: :stop_notification_not_authorized}} = runtime(owner).token_usage_errors[c.issue.id]
    assert evidence(c, entry) == before
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
    send(worker, :finish)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert {:accounting_uncertain, %{cause: :stop_notification_not_authorized}} = stopped.token_usage_errors[c.issue.id]
    assert stopped.stale_execution_errors == %{}
    assert stopped.lease_claims[c.issue.id].token == entry.lease_token
    refute Map.has_key?(stopped.completed, c.issue.id)
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    assert evidence(c, entry) == before
  end

  test "G08 final usage with an authentic receipt has no effect after the real DOWN", c do
    configure!(c.root, 100_000)
    {owner, worker, entry} = start_worker(c)
    inv = invocation(worker)
    assert :ok = GenServer.call(owner, {:hold_usage, true})
    assert :ok = GenServer.call(owner, {:hold_down, true})

    request_worker(worker, fn ->
      send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(120_000)}})
      send(owner, {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(150_000)}})
      AgentExecution.confirm_invocation(inv)
    end)

    assert_receive {:usage_held, ^owner, first_usage}, 5_000
    assert_receive {:usage_held, ^owner, usage}, 5_000
    assert first_usage == {:agent_execution_usage, inv, entry.agent_execution.expected, {:ok, :invocation_absolute, counters(120_000)}}
    assert :ok = GenServer.call(owner, :release_first_usage)
    assert_receive {:down_held, ^owner, _}, 5_000
    receipt = runtime(owner).running[c.issue.id].agent_execution.final_usage_receipt
    assert receipt.previous == entry.agent_execution.expected
    assert receipt.next == RunStateStore.material_projection(raw!(c))
    assert receipt.binding == inv.binding and receipt.ordinal == inv.ordinal
    assert {:stop, %SymphonyElixir.RunPolicy.Violation{}} = receipt.outcome
    assert usage == {:agent_execution_usage, inv, receipt.previous, {:ok, :invocation_absolute, counters(150_000)}}
    assert :ok = GenServer.call(owner, :release_down)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert stopped.running == %{} and stopped.lease_claims == %{} and stopped.retry_attempts == %{}
    assert stopped.agent_totals.total_tokens == 120_000
    assert raw!(c)["token_usage"]["total_tokens"] == 120_000
    snapshot = File.read!(RunStateStore.state_path(c.workspace))
    ledger = File.read!(entry.lease_token.storage.ledger_path)
    assert length(finish_events(c)) == 1
    id = c.issue.id
    assert_receive {:memory_tracker_comment, ^id, _}, 2_000
    assert_receive {:memory_tracker_state_update, ^id, "Blocked"}, 2_000
    assert :ok = GenServer.call(owner, :release_usage)
    assert runtime(owner) == stopped
    assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
    assert File.read!(entry.lease_token.storage.ledger_path) == ledger
    assert length(finish_events(c)) == 1
    assert {:error, :missing} = LeaseManager.read(c.issue.id)
    refute File.exists?(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json"))
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "G08 owner stop before the retained stale message preserves first cause through DOWN", c do
    {owner, worker, entry} = start_worker(c)
    assert :ok = GenServer.call(owner, {:hold_stale, true})
    assert :ok = GenServer.call(owner, {:hold_down, true})
    ids = ids(entry)

    assert {:stop, {:stale_execution, ^ids, :worker_first_cause}} =
             in_worker(worker, fn ->
               assert {:stop, {:stale_execution, ^ids, :worker_first_cause}} = AgentExecution.stale(:worker_first_cause)
               AgentExecution.fail(:later_accounting_cause)
             end)

    assert_receive {:stale_held, ^owner, {:agent_execution_stale, context, ^ids, :worker_first_cause}}, 2_000
    assert context == entry.agent_execution.context
    assert runtime(owner).running[c.issue.id].agent_execution.terminal == nil
    before = evidence(c, entry)
    assert :ok = GenServer.call(owner, {:stop, c.issue.id})
    assert_receive {:down_held, ^owner, {:DOWN, ref, :process, ^worker, _reason}}, 5_000
    assert ref == entry.ref
    requested = runtime(owner).running[c.issue.id]
    assert Map.has_key?(requested, :execution_stop_requested)
    assert requested.agent_execution.terminal == nil
    assert :ok = GenServer.call(owner, :release_stale)
    assert runtime(owner).running[c.issue.id].agent_execution.terminal == {:stale_execution, ids, :worker_first_cause}
    assert :ok = GenServer.call(owner, :release_down)
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert_stale_hold(c, entry, stopped, :worker_first_cause)
    assert stopped.token_usage_errors == %{}
    assert evidence(c, entry) == before
    assert finish_events(c) == []
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
  end

  defp configure!(root, total) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      runner_install_root: Path.join(root, "runner-install"),
      observability_tracing_enabled: false,
      hook_after_create: "touch #{quote_shell(Path.join(root, "after-create"))}",
      policy_token_budget: %{
        per_turn_input: 1_000_000,
        per_issue_total: total,
        per_issue_total_output: 500_000,
        stages: %{implement: %{per_turn_input_soft: 800_000, per_turn_input_hard: 1_000_000}},
        broad_implement: %{enabled: false}
      }
    )

    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "agent:\n", "agent:\n  provider: claude\n"))
    assert :ok = WorkflowStore.force_reload()
  end

  defp cli!(c, count \\ 1) do
    lines =
      Enum.map_join(1..count, "", fn index ->
        event = Jason.encode!(%{"type" => "result", "result" => "boundary result", "usage" => %{"input_tokens" => 7 * index, "output_tokens" => 3 * index}})
        "printf '%s\\n' #{quote_shell(event)}\n"
      end)

    write_script!(Path.join(c.bin, "claude"), "printf 'transport\\n' >> #{quote_shell(c.commands)}\n" <> lines)
  end

  defp start_worker(c) do
    {:ok, owner} = Driver.start_link(self())

    on_exit(fn ->
      if Process.alive?(owner) do
        Enum.each(runtime(owner).running, fn {_id, entry} -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid) end)
        GenServer.stop(owner)
      end
    end)

    entry = GenServer.call(owner, {:dispatch, c.issue}, 10_000)
    worker = entry.pid
    # Worker cleanup also runs if its linked Driver has already exited with the test.
    on_exit(fn -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
    assert_receive {:worker_ready, ^worker, context}, 5_000
    assert context == entry.agent_execution.context
    {owner, worker, entry}
  end

  defp request_worker(worker, fun) do
    ref = make_ref()
    send(worker, {:exercise, self(), ref, fun})
    ref
  end

  defp in_worker(worker, fun), do: worker |> request_worker(fun) |> worker_result()

  defp worker_result(ref) do
    receive do
      {:exercise_result, ^ref, {:fixture_exception, exception, stack}} -> reraise exception, stack
      {:exercise_result, ^ref, {:fixture_caught, kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
      {:exercise_result, ^ref, result} -> result
    after
      10_000 -> flunk("worker fixture did not return")
    end
  end

  defp invocation(worker) do
    in_worker(worker, fn ->
      {:ok, binding} = AgentExecution.register_session(Claude, %{session_id: "boundary-session"}, :main)
      {:ok, invocation} = AgentExecution.begin_invocation(binding)
      invocation
    end)
  end

  defp assert_stale_hold(c, entry, stopped, cause) do
    refute Map.has_key?(stopped.running, c.issue.id)
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    refute Map.has_key?(stopped.completed, c.issue.id)
    assert stopped.lease_claims[c.issue.id].token == entry.lease_token
    assert {:ok, _lease} = LeaseManager.read(c.issue.id)
    assert stopped.stale_execution_errors[c.issue.id].cause == cause
    assert stopped.token_usage_errors == %{}
  end

  defp after_marker(c, marker) do
    commands = c.commands |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(commands, &(&1 == marker)) == 1
    [_marker | rest] = Enum.drop_while(commands, &(&1 != marker))
    rest
  end

  defp evidence(c, entry),
    do: %{
      snapshot: File.read!(RunStateStore.state_path(c.workspace)),
      marker: File.read!(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json")),
      lease: File.read!(entry.lease_token.storage.lease_path),
      ledger: File.read!(entry.lease_token.storage.ledger_path)
    }

  defp runtime(owner), do: GenServer.call(owner, :runtime)
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp counters(total), do: %{input_tokens: total, output_tokens: 0, total_tokens: total}
  defp ids(entry), do: %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
  defp finish_events(c), do: Enum.filter(RunLedger.recent_entries(), &(&1["issue_id"] == c.issue.id and &1["event_type"] == "dispatch.finished"))

  defp write_script!(path, body) do
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
