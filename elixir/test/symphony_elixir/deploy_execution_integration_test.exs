defmodule SymphonyElixir.DeployExecutionIntegrationTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureLog

  alias SymphonyElixir.{AgentExecution, AgentProvider, DeliveryEngine, DeployAudit, DispatchAudit, RunLedger, RunStateStore}
  alias SymphonyElixir.AgentProvider.Claude

  # Admission, DispatchGate, custody, owner RPC and DOWN delegate to production.
  # Explicit fault/stop-state controls below are fixtures, not public controls.
  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, Orchestrator, RunStateStore, Workspace}

    @impl true
    def init(observer) do
      runtime = %Orchestrator.State{
        lease_owner: "i2c-#{System.unique_integer([:positive])}",
        max_concurrent_agents: 1,
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
      }

      {:ok, %{runtime: runtime, observer: observer, before_confirm: nil, deny_ack: false, capture_next_usage: false}}
    end

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}
    def handle_call({:before_confirm, fun}, _from, state), do: {:reply, :ok, %{state | before_confirm: fun}}
    def handle_call(:deny_ack, _from, state), do: {:reply, :ok, %{state | deny_ack: true}}
    def handle_call(:capture_next_usage, _from, state), do: {:reply, :ok, %{state | capture_next_usage: true}}

    def handle_call({:fixture_stop_requested, id}, _from, state) do
      runtime = state.runtime
      runtime = update_in(runtime.running[id], &Map.put(&1, :execution_stop_requested, %{cleanup_workspace: false}))
      {:reply, :ok, %{state | runtime: runtime}}
    end

    def handle_call({:dispatch, issue}, _from, state) do
      owner = self()
      observer = state.observer

      start_child = fn supervisor, _job ->
        raw = issue |> Workspace.path_for_issue() |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

        Task.Supervisor.start_child(supervisor, fn ->
          receive do
            {:captured, context} ->
              result =
                DispatchGate.run(owner, context.ticket.dispatch_id, fn ->
                  DispatchAudit.with_authorization(context.ticket, fn ->
                    AgentExecution.with_context(context.ticket, context.lease_token, owner, raw, fn ->
                      send(observer, {:worker_ready, self()})
                      worker_loop()
                    end)
                  end)
                end)

              case result do
                {:stop, {:accounting_uncertain, reason}} -> exit({:accounting_uncertain, reason})
                {:stop, {:stale_execution, ids, reason}} -> exit({:stale_execution, ids, reason})
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
      previous_pid = get_in(state.runtime.running, [issue.id, :pid])
      if entry && entry.pid != previous_pid, do: send(entry.pid, {:captured, entry.agent_execution.context})
      {:reply, entry, %{state | runtime: runtime}}
    end

    def handle_call({:agent_execution, _, _, {:confirm, _, _}} = call, from, state) do
      state = if state.before_confirm && state.before_confirm.(), do: %{state | before_confirm: nil}, else: state
      delegate(call, from, state)
    end

    def handle_call({:agent_execution, _, _, {:confirm_own_terminal, _, _}} = call, from, %{deny_ack: true} = state) do
      {:reply, {:ok, :terminal_confirmed}, runtime} = Orchestrator.handle_call(call, from, state.runtime)
      # The real handler accepted the persisted CAS; this models a lost/rejected
      # response, not an owner that accepts arbitrary worker-provided material.
      {:reply, {:error, :fixture_ack_not_delivered}, %{state | runtime: runtime}}
    end

    def handle_call(call, from, state), do: delegate(call, from, state)

    defp delegate(call, from, state) do
      case Orchestrator.handle_call(call, from, state.runtime) do
        {:reply, reply, runtime} -> {:reply, reply, %{state | runtime: runtime}}
        {:noreply, runtime} -> {:noreply, %{state | runtime: runtime}}
      end
    end

    @impl true
    def handle_info({:agent_execution_usage, _, _, _} = message, %{capture_next_usage: true} = state) do
      # Delay the exact envelope emitted by A; no payload or identity is rebuilt.
      send(state.observer, {:captured_usage, message})
      {:noreply, %{state | capture_next_usage: false}}
    end

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

  defmodule TrackerClient do
    def graphql(query, vars) do
      fixture = Application.fetch_env!(:symphony_elixir, __MODULE__)

      cond do
        String.contains?(query, "SymphonyResolveStateId") ->
          {:ok, %{"data" => %{"issue" => %{"team" => %{"id" => "fixture-team", "states" => %{"nodes" => [%{"id" => vars.stateName}]}}}}}}

        String.contains?(query, "SymphonyUpdateIssueState") ->
          send(fixture.parent, {:tracker_done_effect, vars.issueId})
          fixture.effect.()
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "i2c-consumer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    issue = %Issue{
      id: "i2c-#{System.unique_integer([:positive])}",
      identifier: "I2C-1",
      title: "Deploy captured execution",
      state: "In Progress",
      source: :tracker,
      labels: [],
      description: "## Acceptance Criteria\n- preserve observed deploy"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: if(tags[:tracker], do: "linear", else: "memory"),
      workspace_root: root,
      runner_install_root: Path.join(root, "runner"),
      policy_require_verifier: false,
      policy_publish_required: false,
      policy_automerge_on_green: false,
      policy_post_merge_verification_required: false,
      observability_tracing_enabled: false,
      hook_before_run: if(tags[:workspace_barrier], do: "printf forbidden >> '#{root}/before-run'"),
      hook_after_run: "printf forbidden >> '#{root}/after-run'",
      hook_before_remove: if(tags[:workspace_barrier], do: "printf forbidden >> '#{root}/before-remove'")
    )

    :ok = WorkflowStore.force_reload()

    if tags[:tracker] do
      previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
      previous_fixture = Application.get_env(:symphony_elixir, TrackerClient)
      Application.put_env(:symphony_elixir, :linear_client_module, TrackerClient)

      on_exit(fn ->
        SymphonyElixir.TestSupport.restore_app_env(:symphony_elixir, :linear_client_module, previous_client)
        SymphonyElixir.TestSupport.restore_app_env(:symphony_elixir, TrackerClient, previous_fixture)
      end)
    end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    target = tags[:target] || "preview"
    command = "deploy-#{target}-fixture"
    deploy = %{target => %{command: command}}
    deploy = if tags[:verify], do: Map.put(deploy, "post_deploy_verify", %{command: "verify-fixture"}), else: deploy

    harness = %{
      version: 1,
      base_branch: "main",
      preflight: %{command: "true"},
      validation: %{command: "true"},
      smoke: %{command: "true"},
      artifacts: %{command: "true"},
      post_merge: %{command: "true"},
      pull_request: %{required_checks: ["fixture"]},
      deploy: deploy
    }

    File.write!(Path.join(workspace, ".symphony/harness.yml"), Jason.encode!(harness))
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/run_state.json\n.symphony/runtime/\n")
    File.write!(Path.join(workspace, "README.md"), "Local deploy fixture\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Fixture"],
          ["config", "user.email", "fixture@example.invalid"],
          ["add", "-A"],
          ["commit", "-qm", "fixture"],
          ["update-ref", "refs/remotes/origin/main", "HEAD"],
          ["checkout", "-q", "-b", SymphonyElixir.GitManager.issue_branch_name(issue)]
        ] do
      assert {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    assert {:ok, _} =
             RunStateStore.transition(workspace, "deploy_" <> target, %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: issue.source,
               effective_policy_class: "fully_autonomous",
               deploy_approved: true,
               current_deploy_target: target,
               branch: SymphonyElixir.GitManager.issue_branch_name(issue)
             })

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, owner} = GenServer.start(Driver, self())
    entry = GenServer.call(owner, {:dispatch, issue}, 10_000)
    assert is_map(entry)
    worker = entry.pid
    assert_receive {:worker_ready, ^worker}, 5_000

    on_exit(fn ->
      cleanup_driver!(owner)
      if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker)
    end)

    %{root: root, workspace: workspace, issue: issue, owner: owner, worker: worker, entry: entry, command: command, target: target}
  end

  for {target, destination} <- [{"preview", "post_deploy_verify"}, {"production", "done"}] do
    @tag target: target, verify: destination == "post_deploy_verify", destination: destination
    test "C01 public #{target} closes only its own #{destination} continuation", c do
      parent = self()

      assert in_worker(c, fn ->
               run(c, fn ->
                 send(parent, :command_effect)
                 {"original-result", 0}
               end)
             end) ==
               if(c.destination == "done", do: {:done, c.issue}, else: :ok)

      assert_received :command_effect
      refute_received :command_effect
      raw = raw!(c)
      assert raw["stage"] == c.destination
      assert :ok = DeployAudit.ensure_available(c.workspace)
      [requested] = events(c, "requested")
      [observed] = events(c, "observed")
      assert_execution(requested, c)
      assert_execution(observed, c)
      assert observed["metadata"]["intent_event_id"] == requested["event_id"]
      assert observed["metadata"]["result"] == result(c)
      assert {:ok, event} = RunLedger.fetch_entry_checked(raw["last_ledger_event_id"])
      assert event["metadata"]["deploy_result_event_id"] == observed["event_id"]
      assert_execution(event, c)
      runtime = GenServer.call(c.owner, :runtime)
      assert runtime.running[c.issue.id].agent_execution.expected == RunStateStore.material_projection(raw)

      if c.destination == "done" do
        assert runtime.running[c.issue.id].agent_execution.known_terminal.next == RunStateStore.material_projection(raw)
        assert {:stop, {:execution_stopped, %{stage: "done"}}} = in_worker(c, &AgentExecution.ensure_current/0)
        assert_receive {:memory_tracker_state_update, _, "Done"}
        send(c.worker, :finish)
        owner = c.owner
        worker = c.worker
        assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, :normal}, stopped}, 5_000
        assert {:ok, completed_at} = Map.fetch(stopped.completed, c.issue.id)
        assert is_integer(completed_at)
        assert stopped.running == %{} and stopped.retry_attempts == %{}
        refute Map.has_key?(stopped.lease_claims, c.issue.id)
        assert :ok = DispatchAudit.ensure_available(c.workspace)
      end

      refute File.exists?(Path.join(c.root, "after-run"))
    end
  end

  for change <- [:stop, :generation, :dispatch_marker] do
    @tag change: change
    test "C11 public command retains its original observation after #{change} changes", c do
      parent = self()

      outcome =
        in_worker(c, fn ->
          run(c, fn ->
            send(parent, :command_effect)
            change_authority!(c, c.change)
            send(parent, {:successor_bytes, authority_bytes(c)})
            {"original-result", 0}
          end)
        end)

      assert {:stop, {:stale_execution, ids, cause}} = outcome
      assert ids == ids(c)

      expected_cause =
        case c.change do
          :stop -> :material_state_changed
          :generation -> :lease_token_mismatch
          :dispatch_marker -> {:dispatch_audit_marker_unreadable, :invalid_dispatch_audit_marker}
        end

      assert cause == expected_cause

      assert_receive {:successor_bytes, before}
      assert authority_bytes(c) == before
      assert_received :command_effect
      refute_received :command_effect
      assert_observed_denial(c, "stale_execution")
      assert_no_continuation(c)
      assert in_worker(c, fn -> run(c, fn -> flunk("replayed command") end) end) == outcome
      assert authority_bytes(c) == before
      assert length(events(c, "observed")) == 1
      send(c.worker, :finish)
      owner = c.owner
      worker = c.worker
      assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, {:stale_execution, ^ids, ^cause}}, stopped}, 5_000
      assert stopped.running == %{}
      assert stopped.retry_attempts == %{}
      refute Map.has_key?(stopped.completed, c.issue.id)
      assert stopped.lease_claims[c.issue.id].token == c.entry.lease_token
      assert authority_bytes(c) == before
    end
  end

  test "a pending deploy rejects real readmission and preserves the live dispatch A", c do
    assert {:ok, ticket} = in_worker(c, fn -> AgentExecution.begin_deploy(c.workspace, attrs(c)) end)
    assert ticket.version == 2
    prior = GenServer.call(c.owner, :runtime)
    before = protected_deploy_bytes(c)
    rejected = GenServer.call(c.owner, {:dispatch, c.issue}, 10_000)
    current = GenServer.call(c.owner, :runtime)

    assert rejected == prior.running[c.issue.id]
    assert current.running == prior.running
    assert current.lease_claims == prior.lease_claims
    assert current.claimed == prior.claimed
    assert current.completed == prior.completed
    assert current.agent_totals == prior.agent_totals
    assert current.retry_attempts == %{}
    assert current.candidate_fetch_error == {:dispatch_audit_failed, c.issue.id, {:deploy_audit_pending, c.workspace}}
    assert Process.alive?(c.worker)
    refute_received {:worker_ready, _}
    refute_received {:worker_down, _, _, _}
    assert protected_deploy_bytes(c) == before
    assert marker!(c)["execution"]["dispatch_ticket"]["dispatch_id"] == c.entry.dispatch_ticket.dispatch_id
    assert events(c, "observed") == []
    refute File.exists?(Path.join(c.root, "deploy-effects"))
    refute File.exists?(Path.join(c.root, "after-run"))
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_comment, _, _}
  end

  test "a genuine same-run successor rejects A's exact delayed usage after public stop and real DOWN", c do
    assert :ok = GenServer.call(c.owner, :capture_next_usage)

    invocation =
      in_worker(c, fn ->
        assert {:ok, session} = Claude.start_session(c.workspace)
        assert {:ok, binding} = AgentExecution.register_session(Claude, session, :main)
        assert {:ok, invocation} = AgentExecution.begin_invocation(binding)
        assert :ok = AgentExecution.observe_usage(invocation, %{usage: %{input_tokens: 7, output_tokens: 3, total_tokens: 10}})
        invocation
      end)

    assert_receive {:captured_usage, {:agent_execution_usage, ^invocation, expected, {:ok, :invocation_absolute, usage}} = envelope}
    assert invocation.context == c.entry.agent_execution.context
    assert expected == c.entry.agent_execution.expected
    assert usage == %{input_tokens: 7, output_tokens: 3, total_tokens: 10}
    assert :ok = DeployAudit.ensure_available(c.workspace)
    assert events(c, "requested") == [] and events(c, "observed") == []
    assert %{ok: true, action: "stop"} = Orchestrator.stop_issue(c.owner, c.issue.identifier)
    owner = c.owner
    worker = c.worker
    assert_receive {:worker_down, ^owner, {:DOWN, ref, :process, ^worker, :shutdown}, stopped}, 5_000
    assert ref == c.entry.ref
    refute Process.alive?(worker)
    assert stopped.running == %{} and stopped.retry_attempts == %{}
    refute Map.has_key?(stopped.completed, c.issue.id)
    refute Map.has_key?(stopped.lease_claims, c.issue.id)
    assert_dispatch_finished(c, "{:exit, :shutdown}")
    assert :ok = DeployAudit.ensure_available(c.workspace)
    assert_receive {:memory_tracker_comment, _, comment}
    assert comment =~ "Rule ID: operator.stop"
    assert_receive {:memory_tracker_state_update, _, "Blocked"}
    assert :ok = SymphonyElixir.IssueSource.update_issue_state(c.issue, "In Progress")
    assert_receive {:memory_tracker_state_update, _, "In Progress"}

    successor = GenServer.call(c.owner, {:dispatch, c.issue}, 10_000)
    assert is_map(successor)
    next_worker = successor.pid

    on_exit(fn ->
      if Process.alive?(next_worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, next_worker)
    end)

    assert_receive {:worker_ready, ^next_worker}, 5_000
    assert next_worker != worker
    assert successor.dispatch_ticket.run_id == c.entry.dispatch_ticket.run_id
    assert successor.dispatch_ticket.dispatch_id != c.entry.dispatch_ticket.dispatch_id
    assert successor.lease_token.lease_generation != c.entry.lease_token.lease_generation
    next_context = %{c | worker: next_worker, entry: successor}
    assert {:ok, _} = in_worker(next_context, &AgentExecution.ensure_current/0)
    prior = GenServer.call(c.owner, :runtime)
    before = {authority_bytes(next_context), File.read!(successor.dispatch_ticket.ledger_path)}

    assert {:error, :dispatch_audit_ticket_mismatch} =
             DispatchAudit.with_authorization(c.entry.dispatch_ticket, fn -> flunk("old ticket authorized work against B") end)

    send(c.owner, envelope)
    current = GenServer.call(c.owner, :runtime)
    assert current.running[c.issue.id] == prior.running[c.issue.id]
    assert current.lease_claims == prior.lease_claims
    assert current.claimed == prior.claimed
    assert current.completed == prior.completed
    assert current.retry_attempts == prior.retry_attempts
    assert current.agent_totals == prior.agent_totals
    assert current.agent_totals.total_tokens == 0
    assert current.token_usage_errors == %{}
    assert current.stale_execution_errors == %{}
    assert {authority_bytes(next_context), File.read!(successor.dispatch_ticket.ledger_path)} == before
    assert :ok = DeployAudit.ensure_available(c.workspace)
    assert events(c, "requested") == [] and events(c, "observed") == []
    refute File.exists?(Path.join(c.root, "deploy-effects"))
    refute File.exists?(Path.join(c.root, "after-run"))
    refute_received {:memory_tracker_state_update, _, "Done"}
    refute_received {:memory_tracker_comment, _, _}
  end

  @tag workspace_barrier: true
  test "identified Workspace refuses pending deploy lifecycle and hooks without replacing the primary failure", c do
    sentinel = Path.join(c.workspace, "sentinel.txt")
    File.write!(sentinel, "preserve local work\n")
    assert {:ok, ticket} = in_worker(c, fn -> AgentExecution.begin_deploy(c.workspace, attrs(c)) end)
    assert ticket.version == 2
    assert ticket.execution.authority.ticket == c.entry.dispatch_ticket
    assert ticket.execution.authority.lease_token == c.entry.lease_token
    assert marker!(c)["status"] == "authorized"
    before = protected_deploy_bytes(c)

    assert {:error, {:deploy_audit_pending, _}} = Workspace.create_for_issue(c.issue)
    assert {:error, {:deploy_audit_pending, _}, ""} = Workspace.remove(c.workspace)

    log =
      capture_log(fn ->
        assert :ok =
                 in_worker(c, fn ->
                   assert {:error, {:deploy_audit_pending, _}} = Workspace.run_before_run_hook(c.workspace, c.issue)
                   assert {:error, {:deploy_audit_pending, _}} = Workspace.run_after_run_hook(c.workspace, c.issue)

                   assert_raise RuntimeError, "original worker failure", fn ->
                     try do
                       raise "original worker failure"
                     after
                       assert {:error, {:deploy_audit_pending, _}} = Workspace.run_after_run_hook(c.workspace, c.issue)
                     end
                   end

                   :ok
                 end)
      end)

    assert log =~ "Workspace hook refused"
    assert log =~ "deploy_audit_pending"
    assert protected_deploy_bytes(c) == before
    assert File.read!(sentinel) == "preserve local work\n"
    for file <- ["before-run", "after-run", "before-remove"], do: refute(File.exists?(Path.join(c.root, file)))
    refute File.exists?(Path.join(c.root, "deploy-effects"))
    assert events(c, "observed") == []
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_comment, _, _}
  end

  test "C12 fixture owner stop state denies continuation despite current storage", c do
    parent = self()

    outcome =
      in_worker(c, fn ->
        run(c, fn ->
          send(parent, :command_effect)
          :ok = GenServer.call(c.owner, {:fixture_stop_requested, c.issue.id})
          send(parent, {:successor_bytes, authority_bytes(c)})
          {"original-result", 0}
        end)
      end)

    assert outcome == {:stop, {:execution_stopped, %{stage: "deploy_preview"}}}
    assert_receive {:successor_bytes, before}
    assert authority_bytes(c) == before
    assert_observed_denial(c, "execution_stopped")
    assert_no_continuation(c)
    assert_received :command_effect
    refute_received :command_effect
    assert in_worker(c, fn -> run(c, fn -> flunk("replayed command") end) end) == outcome
    send(c.worker, :finish)
    owner = c.owner
    assert_receive {:worker_down, ^owner, _, stopped}, 5_000
    assert stopped.running == %{} and stopped.retry_attempts == %{}
    assert stopped.lease_claims[c.issue.id].token == c.entry.lease_token
    assert Map.delete(authority_bytes(c), :dispatch) == Map.delete(before, :dispatch)
    assert_dispatch_finished(c, ":normal")
  end

  test "C12 public stop kills the waiting command worker without fabricating a result", c do
    parent = self()
    ref = make_ref()

    send(
      c.worker,
      {:exercise, parent, ref,
       fn ->
         run(c, fn ->
           send(parent, {:command_waiting, self()})

           receive do
             :result_never_sent -> {"not observed", 0}
           end
         end)
       end}
    )

    worker = c.worker
    assert_receive {:command_waiting, ^worker}, 5_000
    authority_before = authority_bytes(c)
    before = marker_bytes(c)
    assert marker!(c)["status"] == "authorized"
    assert %{ok: true, action: "stop"} = Orchestrator.stop_issue(c.owner, c.issue.identifier)
    owner = c.owner
    assert_receive {:worker_down, ^owner, {:DOWN, _, :process, ^worker, _}, stopped}, 5_000
    refute Process.alive?(worker)
    assert Map.delete(authority_bytes(c), :dispatch) == Map.delete(authority_before, :dispatch)
    assert_dispatch_finished(c, "{:exit, :shutdown}")
    assert_receive {:memory_tracker_comment, _, comment}
    assert comment =~ "Rule ID: operator.stop"
    assert_receive {:memory_tracker_state_update, _, "Blocked"}
    refute_received {:memory_tracker_state_update, _, "Done"}
    assert marker_bytes(c) == before
    assert events(c, "observed") == []
    assert stopped.retry_attempts == %{}
    assert stopped.lease_claims[c.issue.id].token == c.entry.lease_token
    refute_received {:exercise_result, ^ref, _}
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(c.workspace)
    assert {:stop, {:deploy_audit_pending, _}} = DeliveryEngine.run(c.workspace, c.issue, nil, include_pr_details: false)
    assert marker_bytes(c) == before
    assert File.read!(Path.join(c.root, "deploy-effects")) == "effect\n"
    refute File.exists?(Path.join(c.root, "after-run"))
  end

  for fault <- [:ledger, :snapshot] do
    @tag fault: fault
    test "C13 public command result survives unreadable #{fault} before its postguard", c do
      parent = self()

      outcome =
        in_worker(c, fn ->
          run(c, fn ->
            send(parent, :command_effect)
            break_file!(fault_path(c, c.fault))
            {"original-result", 0}
          end)
        end)

      assert {:stop, {:stale_execution, ids, _}} = outcome
      assert ids == ids(c)
      assert_received :command_effect
      refute_received :command_effect
      marker = marker!(c)
      assert marker["result"]["metadata"]["result"] == result(c)
      assert marker["status"] == if(c.fault == :ledger, do: "result_pending", else: "result_confirmed")
      assert marker["continuation_denied"]["kind"] == "stale_execution"
      assert File.dir?(fault_path(c, c.fault))
      snapshot = File.read(RunStateStore.state_path(c.workspace))
      bytes = marker_bytes(c)
      assert in_worker(c, fn -> run(c, fn -> flunk("replayed command") end) end) == outcome
      assert marker_bytes(c) == bytes
      assert File.read(RunStateStore.state_path(c.workspace)) == snapshot
      refute_received {:memory_tracker_state_update, _, "Done"}
      refute File.exists?(Path.join(c.root, "after-run"))
    end
  end

  test "C15 stale remains first when observation then fails checked persistence", c do
    parent = self()

    log =
      capture_log(fn ->
        outcome =
          in_worker(c, fn ->
            run(c, fn ->
              change_authority!(c, :stop)
              assert {:stop, {:stale_execution, _, :material_state_changed}} = AgentExecution.ensure_current()
              break_file!(c.entry.dispatch_ticket.ledger_path)
              {"secret-output-sentinel", 0}
            end)
          end)

        send(parent, {:terminal, outcome})
      end)

    assert_received {:terminal, {:stop, {:stale_execution, _, :material_state_changed}}}
    assert log =~ "Deploy observation retained terminal="
    assert log =~ "secondary=" and log =~ "receipt="
    refute log =~ "secret-output-sentinel"
    assert marker!(c)["status"] == "result_pending"
    assert marker!(c)["result"]["metadata"]["result"]["output"] == "secret-output-sentinel"
    refute_received {:memory_tracker_state_update, _, "Done"}
  end

  for status <- ["failed", "unavailable"] do
    @tag command_status: status
    test "C14 public #{status} command remains ordinary failure with one confirmed observation", c do
      assert {:error, {:deploy_audit_result_uncertain, status}} =
               in_worker(c, fn ->
                 run(c, fn ->
                   if c.command_status == "failed", do: {"original-result", 23}, else: raise("local shell unavailable")
                 end)
               end)

      assert status == c.command_status
      assert marker!(c)["status"] == "result_confirmed"
      assert marker!(c)["result"]["metadata"]["result"]["status"] == status
      assert length(events(c, "observed")) == 1
      assert File.read!(Path.join(c.root, "deploy-effects")) == "effect\n"
      before = {marker_bytes(c), authority_bytes(c), File.read!(c.entry.dispatch_ticket.ledger_path)}
      assert {:stop, {:accounting_uncertain, {:deploy_audit_pending, _}}} = in_worker(c, fn -> run(c, fn -> flunk("non-passed command replay") end) end)
      assert {marker_bytes(c), authority_bytes(c), File.read!(c.entry.dispatch_ticket.ledger_path)} == before
      assert File.read!(Path.join(c.root, "deploy-effects")) == "effect\n"
      assert_no_continuation(c)
    end
  end

  test "C14 timeout observation at wrapper boundary is retained without inventing shell success", c do
    assert {:error, {:deploy_audit_result_uncertain, "timeout"}} =
             in_worker(c, fn ->
               assert {:ok, ticket} = AgentExecution.begin_deploy(c.workspace, attrs(c))
               AgentExecution.record_deploy_result(ticket, %{status: "timeout", command: c.command, output: "timeout observed"})
             end)

    assert marker!(c)["result"]["metadata"]["result"]["status"] == "timeout"
    assert marker!(c)["status"] == "result_confirmed"
    assert_no_continuation(c)
  end

  test "C10 control at owner confirmation after begin prevents the first command", c do
    :ok =
      GenServer.call(
        c.owner,
        {:before_confirm,
         fn ->
           if File.regular?(marker_path(c)) do
             change_authority!(c, :stop)
             true
           else
             false
           end
         end}
      )

    assert {:stop, {:stale_execution, _, :material_state_changed}} = in_worker(c, fn -> run(c, fn -> flunk("command after control") end) end)
    assert marker!(c)["status"] == "authorized"
    assert events(c, "observed") == []
    refute File.exists?(Path.join(c.root, "deploy-effects"))
    assert_no_continuation(c)
  end

  test "C20 own persisted done without delivered ACK cannot finish its journal", c do
    :ok = GenServer.call(c.owner, :deny_ack)
    assert {:stop, {:accounting_uncertain, :fixture_ack_not_delivered}} = in_worker(c, fn -> run(c, fn -> {"original-result", 0} end) end)
    assert raw!(c)["stage"] == "done"
    assert marker!(c)["status"] == "result_confirmed"
    assert GenServer.call(c.owner, :runtime).running[c.issue.id].agent_execution.known_terminal.stage == "done"
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(c.workspace)
  end

  test "C20 worker refuses a reconstructed next after its acknowledged CAS", c do
    assert {:stop, {:accounting_uncertain, :deploy_continuation_not_acknowledged}} =
             in_worker(c, fn ->
               assert {:ok, ticket} = AgentExecution.begin_deploy(c.workspace, attrs(c))
               assert {:ok, _receipt} = AgentExecution.record_deploy_result(ticket, atom_result(c))
               assert {:ok, _state, continuation} = AgentExecution.transition_deploy(ticket, "done", %{})
               change_authority!(c, :stop)
               forged = %{continuation | next: RunStateStore.material_projection(raw!(c))}
               AgentExecution.finish_deploy(ticket, forged)
             end)

    assert marker!(c)["status"] == "result_confirmed"
    assert raw!(c)["stop_reason"]["code"] == "operator_stop"
  end

  @tag target: "production"
  test "C20/C22 a closed local CLI port and retired session do not reopen after own done", c do
    bin = Path.join(c.root, "bin")
    File.mkdir!(bin)
    script = Path.join(bin, "claude")
    release = Path.join(c.root, "cli-release")

    File.write!(
      script,
      "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"result\",\"result\":\"local only\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}'\nwhile [ ! -f '#{release}' ]; do sleep 0.01; done\n"
    )

    File.chmod!(script, 0o755)
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    parent = self()

    assert {:done, _} =
             in_worker(c, fn ->
               assert {:ok, session, binding} = AgentProvider.open_session(Claude, c.workspace, c.issue, :main)
               prior_ports = Port.list()

               assert {:ok, _} =
                        AgentProvider.run_turn(
                          Claude,
                          session,
                          c.workspace,
                          "local",
                          c.issue,
                          [
                            execution_binding: binding,
                            on_message: fn
                              %{event: :notification} ->
                                [port] = Enum.filter(Port.list(), &(&1 not in prior_ports and Port.info(&1, :connected) == {:connected, self()}))
                                Process.put(:closed_cli_port, port)
                                File.write!(release, "release")
                                :ok

                              _ ->
                                :ok
                            end
                          ],
                          :verifier
                        )

               closed_port = Process.get(:closed_cli_port)
               assert is_port(closed_port)
               assert Port.info(closed_port) == nil
               assert {:ok, _} = AgentExecution.transition_current("post_merge", %{})
               assert {:ok, _} = AgentExecution.transition_current("deploy_production", %{deploy_approved: true})
               assert :ok = AgentProvider.close_session(Claude, session, binding)
               send(parent, {:closed_session, session.session_id})
               run(%{c | target: "production", command: "deploy-production-fixture"}, fn -> {"original-result", 0} end)
             end)

    assert_receive {:closed_session, session_id}
    assert raw!(c)["last_agent_session"]["agent_session"]["id"] == session_id
    [observed] = events(%{c | target: "production"}, "observed")
    execution = observed["metadata"]["execution"]
    assert execution["agent_session"] == nil
    assert execution["prior_agent_session"]["agent_session"]["id"] == session_id
    assert :ok = DeployAudit.ensure_available(c.workspace)
    assert {:stop, {:execution_stopped, %{stage: "done"}}} = in_worker(c, &AgentExecution.ensure_current/0)
  end

  for persistence <- [:confirmed, :marker_only, :unconfirmed] do
    @tag persistence: persistence
    test "C16 wrapper repeat preserves the consumed #{persistence} observation", c do
      parent = self()

      log =
        capture_log(fn ->
          assert :ok =
                   in_worker(c, fn ->
                     assert {:ok, ticket} = AgentExecution.begin_deploy(c.workspace, attrs(c))
                     before = marker_bytes(c)

                     case c.persistence do
                       :unconfirmed -> File.chmod!(DeployAudit.marker_directory(c.workspace), 0o555)
                       :marker_only -> break_file!(c.entry.dispatch_ticket.ledger_path)
                       :confirmed -> :ok
                     end

                     first =
                       try do
                         AgentExecution.record_deploy_result(ticket, atom_result(c))
                       after
                         if c.persistence == :unconfirmed, do: File.chmod!(DeployAudit.marker_directory(c.workspace), 0o755)
                       end

                     if c.persistence == :unconfirmed, do: assert(marker_bytes(c) == before)

                     if c.persistence == :marker_only do
                       File.rmdir!(c.entry.dispatch_ticket.ledger_path)
                       File.rename!(c.entry.dispatch_ticket.ledger_path <> ".before-fault", c.entry.dispatch_ticket.ledger_path)
                     end

                     bytes = {marker_bytes(c), File.read!(c.entry.dispatch_ticket.ledger_path), authority_bytes(c)}

                     assert {:error, {:deploy_audit_observation_already_attempted, %{phase: :settled, receipt: receipt}}} =
                              DeployAudit.record_result(ticket, %{status: "failed", command: c.command, output: "different"})

                     assert is_binary(receipt.result_event_id)
                     assert receipt.persistence == :confirmed or elem(receipt.persistence, 0) == c.persistence
                     assert receipt.command_status == "passed"
                     second = AgentExecution.record_deploy_result(ticket, atom_result(c))

                     case first do
                       {:ok, original} ->
                         assert c.persistence == :confirmed
                         assert receipt == original
                         assert {:stop, {:accounting_uncertain, {:deploy_audit_observation_already_attempted, %{receipt: ^receipt}}}} = second

                       {:stop, _} ->
                         assert second == first
                     end

                     assert {marker_bytes(c), File.read!(c.entry.dispatch_ticket.ledger_path), authority_bytes(c)} == bytes
                     send(parent, {:observed_receipt, receipt})
                     :ok
                   end)
        end)

      assert_receive {:observed_receipt, receipt}
      assert receipt.operation_id == marker!(c)["operation_id"]
      assert length(events(c, "observed")) == if(c.persistence == :confirmed, do: 1, else: 0)
      if c.persistence != :confirmed, do: assert(log =~ "Deploy observation retained terminal=")
      assert_no_continuation(c)
    end
  end

  test "C18 same token refresh and current usage remain intact through public deploy", c do
    assert {:done, _} =
             in_worker(c, fn ->
               run(c, fn ->
                 assert {:ok, refreshed} = SymphonyElixir.LeaseManager.refresh_token(c.entry.lease_token)
                 authority = %{ticket: c.entry.dispatch_ticket, lease_token: c.entry.lease_token}
                 expected = c.entry.agent_execution.expected
                 assert {:ok, _} = RunStateStore.record_token_usage_current(c.workspace, c.issue, %{input_tokens: 7, output_tokens: 3, total_tokens: 10}, authority, expected)
                 Process.put(:refreshed_lease, refreshed)
                 {"original-result", 0}
               end)
             end)

    assert raw!(c)["token_usage"] == %{"input_tokens" => 7, "output_tokens" => 3, "total_tokens" => 10}
    assert {:ok, refreshed} = SymphonyElixir.LeaseManager.read_at(c.entry.lease_token.storage)
    assert refreshed == in_worker(c, fn -> Process.get(:refreshed_lease) end)
    assert :ok = DeployAudit.ensure_available(c.workspace)
  end

  test "C17/C19 current result followed by control at owner preflight sends no tracker Done", c do
    :ok =
      GenServer.call(
        c.owner,
        {:before_confirm,
         fn ->
           if File.regular?(marker_path(c)) and marker!(c)["status"] == "result_confirmed" do
             change_authority!(c, :stop)
             true
           else
             false
           end
         end}
      )

    assert {:stop, {:stale_execution, _, :material_state_changed}} = in_worker(c, fn -> run(c, fn -> {"original-result", 0} end) end)
    assert marker!(c)["status"] == "result_confirmed"
    assert length(events(c, "observed")) == 1
    assert_no_continuation(c)
  end

  test "C20 exact acknowledged next changed by control cannot finish", c do
    assert {:stop, {:stale_execution, _, _}} =
             in_worker(c, fn ->
               assert {:ok, ticket} = AgentExecution.begin_deploy(c.workspace, attrs(c))
               assert {:ok, _} = AgentExecution.record_deploy_result(ticket, atom_result(c))
               assert {:ok, _, continuation} = AgentExecution.transition_deploy(ticket, "done", %{})
               change_authority!(c, :stop)
               before = {marker_bytes(c), authority_bytes(c), File.read!(ticket.ledger_path)}
               outcome = AgentExecution.finish_deploy(ticket, continuation)
               assert {marker_bytes(c), authority_bytes(c), File.read!(ticket.ledger_path)} == before
               outcome
             end)

    assert marker!(c)["status"] == "result_confirmed"
  end

  @tag tracker: true
  test "C19 control during sent tracker effect keeps the observation and rejects CAS without replay", c do
    parent = self()

    Application.put_env(:symphony_elixir, TrackerClient, %{
      parent: parent,
      effect: fn ->
        change_authority!(c, :stop)
        send(parent, {:controlled_bytes, authority_bytes(c)})
      end
    })

    outcome =
      in_worker(c, fn ->
        run(c, fn ->
          send(parent, :command_effect)
          {"original-result", 0}
        end)
      end)

    assert {:stop, {:stale_execution, _, :material_state_changed}} = outcome
    assert_receive {:tracker_done_effect, id}
    assert id == c.issue.id
    assert_receive {:controlled_bytes, before}
    assert authority_bytes(c) == before
    assert_received :command_effect
    refute_received :command_effect
    refute_received {:tracker_done_effect, _}
    assert length(events(c, "observed")) == 1
    assert marker!(c)["status"] == "result_confirmed"
    assert raw!(c)["stage"] == "deploy_preview"
    assert in_worker(c, fn -> run(c, fn -> flunk("command replay") end) end) == outcome
    assert authority_bytes(c) == before
    refute_received {:tracker_done_effect, _}
  end

  test "C22 transition rejects caller-supplied execution provenance before deploy intent", c do
    before = {authority_bytes(c), File.read!(c.entry.dispatch_ticket.ledger_path)}

    assert {:stop, {:accounting_uncertain, _}} =
             in_worker(c, fn ->
               AgentExecution.transition_current("post_merge", %{execution: %{run_id: "forged", dispatch_id: "forged"}})
             end)

    assert {authority_bytes(c), File.read!(c.entry.dispatch_ticket.ledger_path)} == before
    refute File.exists?(DeployAudit.marker_directory(c.workspace))
  end

  for corruption <- [:shape, :event] do
    @tag corruption: corruption
    test "C23 a present #{corruption} corruption never becomes a fabricated prior session", c do
      assert :ok =
               in_worker(c, fn ->
                 assert {:ok, session} = Claude.start_session(c.workspace)
                 assert {:ok, binding} = AgentExecution.register_session(Claude, session, :main)
                 assert {:ok, _} = AgentExecution.begin_invocation(binding)
                 assert {:ok, _} = AgentExecution.transition_current("post_merge", %{})
                 assert {:ok, _} = AgentExecution.transition_current("deploy_preview", %{})
                 AgentExecution.retire_session(binding)
               end)

      RunStateStore.with_workspace_lock(c.workspace, fn ->
        raw = raw!(c)
        prior = if c.corruption == :shape, do: nil, else: Map.put(raw["last_agent_session"], "event_id", "missing-checked-event")
        File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(Map.put(raw, "last_agent_session", prior)))
      end)

      before = {authority_bytes(c), File.read!(c.entry.dispatch_ticket.ledger_path)}
      assert {:stop, {:accounting_uncertain, _}} = in_worker(c, fn -> AgentExecution.begin_deploy(c.workspace, attrs(c)) end)
      assert {authority_bytes(c), File.read!(c.entry.dispatch_ticket.ledger_path)} == before
      refute File.exists?(DeployAudit.marker_directory(c.workspace))
    end
  end

  for terminal_first? <- [false, true] do
    @tag terminal_first: terminal_first?
    test "observed serialization exception preserves #{if terminal_first?, do: "first terminal and safe log", else: "original exception and stack"}", c do
      parent = self()
      sentinel = "private-result-sentinel"
      output = sentinel <> <<255>>

      log =
        capture_log(fn ->
          assert :ok =
                   in_worker(c, fn ->
                     assert {:ok, ticket} = AgentExecution.begin_deploy(c.workspace, attrs(c))

                     prior_terminal =
                       if c.terminal_first do
                         change_authority!(c, :stop)
                         assert {:stop, {:stale_execution, _, :material_state_changed}} = terminal = AgentExecution.ensure_current()
                         terminal
                       end

                     before = {marker_bytes(c), authority_bytes(c), File.read!(ticket.ledger_path)}

                     outcome =
                       try do
                         {:returned, AgentExecution.record_deploy_result(ticket, %{status: "passed", command: c.command, output: output})}
                       rescue
                         exception -> {:raised, exception, __STACKTRACE__}
                       end

                     if c.terminal_first do
                       assert outcome == {:returned, prior_terminal}
                     else
                       assert {:raised, %Jason.EncodeError{}, stack} = outcome

                       assert Enum.any?(stack, fn
                                {Jason, :encode!, _, _} -> true
                                _ -> false
                              end)

                       # Report only frame shapes, never their arguments or the exception's
                       # message (which legitimately contains the invalid original output).
                       send(
                         parent,
                         {:actual_stack_shapes,
                          Enum.map(stack, fn
                            {_module, _function, args, _location} when is_list(args) -> :mfa_args
                            {_module, _function, arity, _location} when is_integer(arity) -> :mfa_arity
                            {fun, args, _location} when is_function(fun) and is_list(args) -> :fun_args
                            {fun, arity, _location} when is_function(fun) and is_integer(arity) -> :fun_arity
                          end)}
                       )
                     end

                     assert {:error, {:deploy_audit_observation_already_attempted, %{phase: :recording, receipt: receipt}}} =
                              DeployAudit.record_result(ticket, atom_result(c))

                     assert is_binary(receipt.result_event_id)
                     assert receipt.command_status == "passed"
                     assert receipt.persistence == :not_attempted
                     assert {marker_bytes(c), authority_bytes(c), File.read!(ticket.ledger_path)} == before
                     :ok
                   end)
        end)

      if c.terminal_first do
        assert log =~ "Deploy observation retained terminal=" and log =~ "secondary=" and log =~ "stack="
        assert log =~ "Jason.EncodeError"
        assert log =~ "Jason.encode!/2"
      else
        refute log =~ "Deploy observation retained terminal="
        assert_receive {:actual_stack_shapes, shapes}
        assert Enum.all?(shapes, &(&1 in [:mfa_args, :mfa_arity, :fun_args, :fun_arity]))
      end

      refute log =~ sentinel
      assert events(c, "observed") == []
      assert marker!(c)["status"] == "authorized"
    end
  end

  defp run(c, effect) do
    DeliveryEngine.run(c.workspace, c.issue, nil,
      include_pr_details: false,
      command_runner: &inspect_command/3,
      shell_runner: fn workspace, command, _opts ->
        assert workspace == c.workspace and command == c.command
        File.write!(Path.join(c.root, "deploy-effects"), "effect\n", [:append])
        effect.()
      end
    )
  end

  defp inspect_command("git", args, opts), do: System.cmd("git", args, opts)
  defp inspect_command("gh", ["pr", "view", "--json", _], _opts), do: {Jason.encode!(%{url: nil, state: nil, reviewDecision: nil, statusCheckRollup: []}), 0}
  defp inspect_command(command, args, _opts), do: flunk("unexpected command #{inspect({command, args})}")

  defp in_worker(c, fun) do
    ref = make_ref()
    send(c.worker, {:exercise, self(), ref, fun})

    receive do
      {:exercise_result, ^ref, {:fixture_exception, error, stack}} -> reraise error, stack
      {:exercise_result, ^ref, {:fixture_caught, kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
      {:exercise_result, ^ref, result} -> result
    after
      10_000 -> flunk("admitted deploy worker did not return")
    end
  end

  defp change_authority!(c, change) do
    RunStateStore.with_workspace_lock(c.workspace, fn ->
      path = RunStateStore.state_path(c.workspace)
      raw = raw!(c)

      case change do
        :stop ->
          File.write!(path, Jason.encode!(Map.put(raw, "stop_reason", %{"code" => "operator_stop"})))

        :dispatch_marker ->
          marker_path = Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json")
          marker = marker_path |> File.read!() |> Jason.decode!()
          File.write!(marker_path, Jason.encode!(Map.put(marker, "dispatch_id", "corrupted-dispatch-id")))

        :generation ->
          token = c.entry.lease_token
          lease = token.storage.lease_path |> File.read!() |> Jason.decode!()
          File.write!(token.storage.lease_path, Jason.encode!(Map.put(lease, "lease_generation", "successor-generation")))
      end
    end)
  end

  defp authority_bytes(c),
    do: %{
      snapshot: File.read(RunStateStore.state_path(c.workspace)),
      lease: File.read(c.entry.lease_token.storage.lease_path),
      dispatch: File.read(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json"))
    }

  defp protected_deploy_bytes(c) do
    directory = DeployAudit.marker_directory(c.workspace)

    %{
      authority: authority_bytes(c),
      ledger: File.read!(c.entry.dispatch_ticket.ledger_path),
      journal: Map.new(File.ls!(directory), fn name -> {name, File.read!(Path.join(directory, name))} end)
    }
  end

  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp marker_path(c), do: Path.join(DeployAudit.marker_directory(c.workspace), "marker.json")
  defp marker_bytes(c), do: File.read!(marker_path(c))
  defp marker!(c), do: marker_bytes(c) |> Jason.decode!()
  defp ids(c), do: %{run_id: c.entry.dispatch_ticket.run_id, dispatch_id: c.entry.dispatch_ticket.dispatch_id}
  defp result(c), do: %{"status" => "passed", "command" => c.command, "output" => "original-result"}
  defp atom_result(c), do: %{status: "passed", command: c.command, output: "original-result"}
  defp attrs(c), do: %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: "deploy_" <> c.target, command: c.command}

  defp events(c, suffix),
    do: c.entry.dispatch_ticket.ledger_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.filter(&(&1["event_type"] == "deploy.#{c.target}.#{suffix}"))

  defp fault_path(c, :ledger), do: c.entry.dispatch_ticket.ledger_path
  defp fault_path(c, :snapshot), do: RunStateStore.state_path(c.workspace)

  defp break_file!(path) do
    File.rename!(path, path <> ".before-fault")
    File.mkdir!(path)
  end

  defp assert_dispatch_finished(c, outcome) do
    rows = c.entry.dispatch_ticket.ledger_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    [finished] = Enum.filter(rows, &(&1["event_type"] == "dispatch.finished"))
    assert finished["metadata"]["dispatch_id"] == c.entry.dispatch_ticket.dispatch_id
    assert finished["metadata"]["run_id"] == c.entry.dispatch_ticket.run_id
    assert finished["metadata"]["outcome"] == outcome
    assert {:error, :enoent} = File.read(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json"))
  end

  defp assert_execution(event, c) do
    execution = event["metadata"]["execution"]
    assert execution["version"] == 1
    assert execution["actor_role"] == "runtime"
    assert execution["run_id"] == c.entry.dispatch_ticket.run_id
    assert execution["dispatch_id"] == c.entry.dispatch_ticket.dispatch_id
    assert execution["lease_generation"] == c.entry.lease_token.lease_generation
  end

  defp assert_observed_denial(c, kind) do
    marker = marker!(c)
    [observed] = events(c, "observed")
    assert marker["status"] == "result_confirmed" and marker["version"] == 2
    assert marker["continuation_denied"]["kind"] == kind
    assert marker["continuation_denied"]["phase"] == "record_result"
    assert marker["result"] == observed
    assert File.read!(Path.join(c.root, "deploy-effects")) == "effect\n"
    assert marker["execution"]["dispatch_ticket"]["run_id"] == c.entry.dispatch_ticket.run_id
    assert marker["execution"]["dispatch_ticket"]["dispatch_id"] == c.entry.dispatch_ticket.dispatch_id
    assert observed["metadata"]["result"] == result(c)
    assert observed["metadata"]["deploy_operation_id"] == marker["operation_id"]
    assert_execution(observed, c)
  end

  defp assert_no_continuation(c) do
    assert raw!(c)["stage"] == "deploy_" <> c.target
    refute_received {:memory_tracker_state_update, _, "Done"}
    refute File.exists?(Path.join(c.root, "after-run"))
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(c.workspace)
  end

  defp cleanup_driver!(owner) do
    if Process.alive?(owner) do
      assert :ok = :sys.suspend(owner)
      runtime = :sys.get_state(owner).runtime
      readers = Enum.reject([runtime.tracker_poll_read, runtime.admission_read], &is_nil/1)
      workers = Enum.map(runtime.running, fn {_id, entry} -> entry.pid end)
      monitors = Enum.map(Enum.uniq(Enum.map(readers, & &1.pid) ++ workers), &{&1, Process.monitor(&1)})

      :sys.replace_state(owner, fn state ->
        Enum.each(readers, fn reader -> assert :ok = SymphonyElixir.TrackerReader.cancel(reader) end)
        Enum.each(state.runtime.retry_attempts, fn {_id, retry} -> if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref) end)
        Enum.each(state.runtime.lease_claims, fn {_id, claim} -> if is_reference(claim[:timer]), do: Process.cancel_timer(claim.timer) end)
        state
      end)

      GenServer.stop(owner)
      Enum.each(workers, fn worker -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
      Enum.each(monitors, fn {pid, ref} -> assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000 end)
    end
  end
end
