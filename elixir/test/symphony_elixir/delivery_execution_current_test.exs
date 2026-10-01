defmodule SymphonyElixir.DeliveryExecutionCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DeliveryEngine, DeployAudit, DispatchAudit, LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.AgentProvider.Codex

  # Delivery, admission, leases, checked storage and deploy journals are real.
  # This owner models the worker protocol, not Orchestrator custody or DOWN.
  defmodule Owner do
    use GenServer
    alias SymphonyElixir.{AgentExecution, RunStateStore}

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      context = %{ticket: opts.ticket, lease_token: opts.token, owner: self(), worker: opts.worker, issue_id: opts.issue.id}

      {:ok,
       %{
         context: context,
         authority: %{ticket: opts.ticket, lease_token: opts.token},
         issue: opts.issue,
         expected: RunStateStore.material_projection(opts.raw),
         registry: AgentExecution.new_registry(),
         known: nil,
         terminal: nil,
         calls: [],
         before_advance: nil
       }}
    end

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}
    def handle_call({:before_advance, fun}, _from, state), do: {:reply, :ok, %{state | before_advance: fun}}

    def handle_call({:agent_execution, invocation, expected, action}, {pid, _}, state) do
      true = pid == state.context.worker
      :ok = authenticate(state, invocation)
      state = %{state | calls: state.calls ++ [{expected, action}]}
      {reply, state} = perform(state, expected, action)
      {:reply, reply, state}
    end

    defp perform(%{terminal: terminal} = state, _, _) when not is_nil(terminal), do: {{:stop, terminal}, state}
    defp perform(state, expected, _) when expected != state.expected, do: terminal(state, {:stale_execution, :owner_expected_changed})

    defp perform(state, _, {kind, previous, next}) when kind in [:advance_current, :confirm_own_terminal] do
      true = previous == state.expected
      if state.before_advance, do: state.before_advance.()
      state = %{state | before_advance: nil}

      result =
        if kind == :confirm_own_terminal,
          do: RunStateStore.confirm_terminal_current(state.authority, next),
          else: RunStateStore.ensure_current(state.authority, next)

      case result do
        :ok -> {{:ok, :terminal_confirmed}, %{state | expected: next, known: next}}
        {:ok, _current} -> {:ok, %{state | expected: next}}
        {:error, reason} -> terminal(state, reason)
      end
    end

    defp perform(%{known: %{"stage" => "blocked"} = next} = state, _, :confirm_stop_notification) do
      case RunStateStore.confirm_terminal_current(state.authority, next) do
        :ok -> {:ok, state}
        {:error, reason} -> terminal(state, reason)
      end
    end

    defp perform(%{known: %{"stage" => stage}} = state, _, _),
      do: {{:stop, {:execution_stopped, %{stage: stage}}}, state}

    defp perform(state, _, action) do
      with {:ok, _current} <- RunStateStore.ensure_current(state.authority, state.expected),
           {:ok, registry} <- registry_action(state.registry, action) do
        {:ok, %{state | registry: registry}}
      else
        {:error, reason} -> terminal(state, reason)
      end
    end

    defp registry_action(registry, {:register, binding, purpose}), do: AgentExecution.register_binding(registry, binding, purpose)
    defp registry_action(registry, {:begin, binding, ordinal}), do: AgentExecution.begin_binding(registry, binding, ordinal)

    defp registry_action(registry, {:retire, binding, ordinal}) when ordinal == registry.ordinal,
      do: AgentExecution.retire_binding(registry, binding)

    defp registry_action(registry, {:confirm, binding, ordinal}) when binding == registry.current and ordinal == registry.ordinal,
      do: {:ok, registry}

    @impl true
    def handle_info({:agent_execution_usage, invocation, expected, observation}, state) do
      :ok = authenticate(state, invocation)
      true = expected == state.expected
      {:ok, registry, _delta} = AgentExecution.apply_usage(state.registry, invocation.binding, invocation.ordinal, observation)

      case RunStateStore.record_token_usage_current(state.context.ticket.workspace, state.issue, AgentExecution.total_usage(registry), state.authority, expected) do
        {:ok, _current} ->
          {:noreply, %{state | registry: registry}}

        {:error, reason} ->
          {_reply, next} = terminal(state, reason)
          {:noreply, next}
      end
    end

    def handle_info({:agent_worker_update, invocation, expected, _update}, state) do
      :ok = authenticate(state, invocation)
      true = expected == state.expected

      case RunStateStore.ensure_current(state.authority, expected) do
        {:ok, _current} ->
          {:noreply, state}

        {:error, reason} ->
          {_reply, next} = terminal(state, reason)
          {:noreply, next}
      end
    end

    def handle_info({:agent_execution_stale, context, ids, cause}, state) do
      true = context == state.context
      true = ids == ids(state)
      {_reply, next} = terminal(state, {:stale_execution, cause})
      {:noreply, next}
    end

    def handle_info({:agent_execution_uncertain, context, cause}, state) do
      true = context == state.context
      {_reply, next} = terminal(state, cause)
      {:noreply, next}
    end

    defp authenticate(state, %{context: context, binding: binding, ordinal: ordinal}) do
      true = context == state.context
      true = binding == state.registry.current and ordinal == state.registry.ordinal
      :ok
    end

    defp terminal(%{terminal: cause} = state, _) when not is_nil(cause), do: {{:stop, cause}, state}

    defp terminal(state, {:stale_execution, cause}) do
      terminal = {:stale_execution, ids(state), cause}
      {{:stop, terminal}, %{state | terminal: terminal}}
    end

    defp terminal(state, cause) do
      terminal = {:accounting_uncertain, cause}
      {{:stop, terminal}, %{state | terminal: terminal}}
    end

    defp ids(state), do: %{run_id: state.context.ticket.run_id, dispatch_id: state.context.ticket.dispatch_id}
  end

  # The soft-pressure composition case delegates admission, usage, policy and
  # DOWN to Orchestrator. Only the admitted task's job closure is captured here.
  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, Orchestrator, RunStateStore}

    @impl true
    def init(observer) do
      runtime = %Orchestrator.State{
        lease_owner: "delivery-policy-#{System.unique_integer([:positive])}",
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
        raw = issue |> SymphonyElixir.Workspace.path_for_issue() |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

        Task.Supervisor.start_child(supervisor, fn ->
          receive do
            {:captured, context} ->
              result =
                DispatchGate.run(owner, context.ticket.dispatch_id, fn ->
                  DispatchAudit.with_authorization(context.ticket, fn ->
                    AgentExecution.with_context(context.ticket, context.lease_token, owner, raw, fn ->
                      send(observer, {:worker_ready, self(), context, raw})
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
        String.contains?(query, "SymphonyCreateComment") ->
          send(fixture.parent, {:tracker_effect, :comment})
          fixture.effect.(:comment)

          if fixture.comment_error,
            do: {:error, :fixture_comment_failure},
            else: {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

        String.contains?(query, "SymphonyResolveStateId") ->
          {:ok, %{"data" => %{"issue" => %{"team" => %{"id" => "fixture-team", "states" => %{"nodes" => [%{"id" => vars.stateName}]}}}}}}

        String.contains?(query, "SymphonyUpdateIssueState") ->
          send(fixture.parent, {:tracker_effect, :move, vars.stateId})
          fixture.effect.(:move)

          if fixture.move_error,
            do: {:error, :fixture_move_failure},
            else: {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end
  end

  defmodule GitHub do
    def review_feedback(_workspace, opts) do
      effect(opts, :feedback)
      {:ok, %{pr_url: opts[:pr_url], review_decision: "APPROVED", reviews: [], comments: []}}
    end

    def post_review_comment_reply(pr_url, comment_id, _body, opts) do
      effect(opts, :post)
      {:ok, %{id: "reply-#{comment_id}", url: pr_url <> "#reply"}}
    end

    def resolve_review_comment_thread(_pr_url, comment_id, opts) do
      effect(opts, :resolve)
      {:ok, %{thread_id: "thread-#{comment_id}", resolved: true}}
    end

    def merge_pull_request(_workspace, opts) do
      effect(opts, :merge)
      {:ok, %{url: opts[:pr_url], status: :merged, output: "merged"}}
    end

    defp effect(opts, phase) do
      Process.put(:delivery_github_count, Process.get(:delivery_github_count, 0) + 1)
      send(opts[:test], {:github_effect, phase})
      Keyword.get(opts, :github_effect, fn _ -> :ok end).(phase)
    end
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "delivery-current-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "DELIVERY-1")

    issue = %Issue{
      id: "delivery-current-#{System.unique_integer([:positive])}",
      identifier: "DELIVERY-1",
      title: "Delivery boundaries",
      state: "In Progress",
      source: :tracker,
      labels: [],
      description: "private-payload-sentinel"
    }

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    unless tags[:real_owner], do: File.mkdir_p!(Path.join(workspace, ".git"))

    workflow_opts = [
      workspace_root: root,
      runner_install_root: Path.join(root, "runner"),
      company_policy_pack: "private_autopilot",
      policy_post_merge_verification_required: true,
      policy_automerge_on_green: false,
      max_concurrent_agents: if(tags[:real_owner], do: 1, else: 0),
      codex_command: quote_shell(Path.join(root, "codex")) <> " app-server"
    ]

    workflow_opts =
      if tags[:real_owner],
        do:
          Keyword.put(workflow_opts, :policy_token_budget, %{
            per_turn_input: 500_000,
            per_issue_total: 1_000_000,
            per_issue_total_output: 500_000,
            stages: %{implement: %{per_turn_input_soft: 60_000, per_turn_input_hard: 120_000}},
            broad_implement: %{enabled: false},
            review_fix: %{enabled: false}
          }),
        else: workflow_opts

    write_workflow_file!(Workflow.workflow_file_path(), workflow_opts)

    harness = %{
      version: 1,
      base_branch: "main",
      validation: %{command: "validate-fixture"},
      preflight: %{command: "preflight-fixture"},
      smoke: %{command: "smoke-fixture"},
      artifacts: %{command: "artifact-fixture"},
      post_merge: %{command: "post-merge-fixture"},
      pull_request: %{required_checks: ["fixture-check"]}
    }

    harness = if tags[:deploy], do: Map.put(harness, :deploy, %{preview: %{command: "deploy-fixture"}}), else: harness
    harness = if tags[:deploy_verify], do: put_in(harness, [:deploy, :post_deploy_verify], %{command: "verify-deploy-fixture"}), else: harness
    File.write!(Path.join(workspace, ".symphony/harness.yml"), Jason.encode!(harness))
    pr_url = "https://github.com/example/repo/pull/1"
    stage = tags[:stage] || "post_merge"

    threads =
      if tags[:review],
        do: %{
          "comment:1" => %{
            "id" => "1",
            "draft_state" => "drafted",
            "draft_reply" => "Addressed on the branch.",
            "implementation_status" => "addressed",
            "resolution_recommendation" => "resolve_after_change"
          }
        },
        else: %{}

    assert {:ok, _state} =
             RunStateStore.transition(workspace, stage, %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               effective_policy_class: "fully_autonomous",
               policy_pack: "private_autopilot",
               pr_url: pr_url,
               branch: if(tags[:real_owner], do: SymphonyElixir.GitManager.issue_branch_name(issue), else: "main"),
               review_threads: threads,
               last_pr_body_validation: %{status: "passed"},
               resume_context: %{already_learned: "retained", target_paths: ["lib/example.ex"]}
             })

    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_fixture = Application.get_env(:symphony_elixir, TrackerClient)
    Application.put_env(:symphony_elixir, :linear_client_module, TrackerClient)
    tracker = %{parent: self(), effect: fn _ -> :ok end, comment_error: false, move_error: false}
    Application.put_env(:symphony_elixir, TrackerClient, tracker)

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_app_env(:symphony_elixir, :linear_client_module, previous_client)
      SymphonyElixir.TestSupport.restore_app_env(:symphony_elixir, TrackerClient, previous_fixture)
      File.rm_rf!(root)
    end)

    base = %{root: root, workspace: workspace, issue: issue, pr_url: pr_url, tracker: tracker}

    if tags[:real_owner] do
      git = System.find_executable("git")
      assert is_binary(git)
      File.write!(Path.join(workspace, ".gitignore"), ".symphony/\n")
      File.write!(Path.join(workspace, "keep.txt"), "Delivery admission fixture\n")

      for args <- [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "Delivery Fixture"],
            ["config", "user.email", "delivery@example.invalid"],
            ["add", "-A"],
            ["-c", "commit.gpgsign=false", "commit", "-qm", "fixture"],
            ["checkout", "-q", "-b", SymphonyElixir.GitManager.issue_branch_name(issue)]
          ] do
        assert {_, 0} = System.cmd(git, args, cd: workspace, stderr_to_stdout: true)
      end

      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "gh"), "#!/bin/sh\nexit 1\n")
      File.chmod!(Path.join(bin, "gh"), 0o755)
      System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
      {:ok, owner} = GenServer.start(Driver, self())

      on_exit(fn ->
        if Process.alive?(owner) do
          runtime = GenServer.call(owner, :runtime)
          Enum.each(runtime.running, fn {_id, entry} -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid) end)
          GenServer.stop(owner)
        end
      end)

      entry = GenServer.call(owner, {:dispatch, issue}, 10_000)
      worker = entry.pid
      assert_receive {:worker_ready, ^worker, context, raw}, 5_000
      assert context == entry.agent_execution.context
      assert entry.stage == "implement"
      assert entry.dispatch_stage == "implement"
      assert raw["stage"] == "implement"
      assert raw!(base)["stage"] == "implement"
      Map.merge(base, %{owner: owner, worker: worker, entry: entry, raw: raw, ticket: entry.dispatch_ticket, token: entry.lease_token})
    else
      assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "delivery-current-owner")
      assert {:ok, _state} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(acquired.lease))
      assert {:ok, source, view} = RunStateStore.read_admission_source(workspace, issue)

      assert {:ok, ticket, raw} =
               DispatchAudit.begin(
                 workspace,
                 %{issue_id: issue.id, issue_identifier: issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}},
                 source
               )

      owner = start_supervised!({Owner, %{ticket: ticket, token: acquired.token, raw: raw, issue: issue, worker: self()}})

      on_exit(fn ->
        assert {:ok, outcome} = LeaseManager.release_token(acquired.token)
        assert outcome in [:released, :missing]
      end)

      %{root: root, workspace: workspace, issue: issue, ticket: ticket, raw: raw, token: acquired.token, owner: owner, pr_url: pr_url, tracker: tracker}
    end
  end

  for field <- ["policy_override", "review_claims", "review_threads", "review_return_stage"] do
    @tag field: field
    test "#{field} control before public entry prevents inspection and writes", c do
      control!(c, c.field)
      before = evidence(c)
      assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c) end)
      assert evidence(c) == before
      refute_received {:command_effect, _, _}
      refute_received {:tracker_effect, _}
      refute_received {:tracker_effect, _, _}
    end
  end

  test "post-merge success carries its CAS state into own done and preserves fresh nonmaterial fields", c do
    shell = fn _, "post-merge-fixture", _ ->
      assert {:ok, precondition} = AgentExecution.workspace_precondition(c.workspace, c.issue)
      assert {:ok, _} = RunStateStore.record_token_usage_current(c.workspace, c.issue, %{input_tokens: 70, output_tokens: 3, total_tokens: 73}, precondition.authority, precondition.expected)
      assert {:ok, refreshed} = LeaseManager.refresh_token(c.token)
      assert {:ok, state} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(refreshed))
      send(self(), {:refreshed_lease, state.lease_updated_at})
      {"verified locally", 0}
    end

    assert {:done, issue} =
             within(c, fn ->
               result = run(c, shell_runner: shell)
               assert result == {:done, c.issue}
               assert {:stop, {:execution_stopped, %{stage: "done"}}} = AgentExecution.ensure_current()
               result
             end)

    assert issue == c.issue
    raw = raw!(c)
    assert raw["last_decision_summary"] =~ "post-merge verification passed"
    assert raw["last_post_merge"]["output"] == "verified locally"
    assert raw["token_usage"]["total_tokens"] == 73
    assert raw["resume_context"] == c.raw["resume_context"]
    assert_received {:refreshed_lease, updated_at}
    assert raw["lease_updated_at"] == updated_at
    assert_received {:tracker_effect, :move, "Done"}
    refute_received {:tracker_effect, :move, _}
  end

  for field <- ["review_claims", "review_threads", "review_return_stage"] do
    @tag field: field
    test "#{field} control during post-merge result prevents checkpoint, event and done", c do
      shell = fn _, "post-merge-fixture", _ ->
        control!(c, c.field)
        send(self(), {:control_evidence, evidence(c)})
        {"observed command", 0}
      end

      assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c, shell_runner: shell) end)
      assert_received {:control_evidence, before}
      assert evidence(c) == before
      refute_received {:tracker_effect, _, _}
      refute Enum.any?(rows(), &(&1["event_type"] == "post_merge.completed"))
    end
  end

  @tag stage: "deploy_preview"
  test "own blocked preserves domain outcome and makes both ordinary notification failures visible", c do
    Application.put_env(:symphony_elixir, TrackerClient, %{c.tracker | comment_error: true, move_error: true})

    log =
      capture_log(fn ->
        assert {:stop, :deploy_preview_missing} = within(c, fn -> run(c) end)
      end)

    assert log =~ "action=comment"
    assert log =~ "action=move"
    assert log =~ "fixture_comment_failure"
    assert log =~ "fixture_move_failure"
    refute log =~ c.issue.description
    assert raw!(c)["stage"] == "blocked"
    assert_received {:tracker_effect, :comment}
    refute_received {:tracker_effect, :comment}
    assert_received {:tracker_effect, :move, "Blocked"}
    refute_received {:tracker_effect, :move, _}
    assert Enum.count(owner_state(c).calls, fn {_, action} -> action == :confirm_stop_notification end) == 2
  end

  @tag stage: "deploy_preview"
  test "control between own blocked comment and move stops the second notification without replay", c do
    Application.put_env(:symphony_elixir, TrackerClient, %{
      c.tracker
      | effect: fn
          :comment ->
            control!(c, "review_threads")
            send(self(), {:control_evidence, evidence(c)})

          :move ->
            flunk("move must be denied")
        end
    })

    assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c) end)
    assert_received {:tracker_effect, :comment}
    refute_received {:tracker_effect, :comment}
    refute_received {:tracker_effect, :move, _}
    assert_received {:control_evidence, before}
    assert evidence(c) == before
  end

  @tag stage: "merge_readiness", review: true
  test "control after a public review reply prevents resolution and readiness CAS", c do
    effect = fn
      :post ->
        control!(c, "review_return_stage")
        send(self(), {:control_evidence, evidence(c)})

      _ ->
        :ok
    end

    assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c, github_effect: effect) end)
    assert_received {:github_effect, :post}
    refute_received {:github_effect, :post}
    refute_received {:github_effect, :resolve}
    assert_received {:control_evidence, before}
    after_observation = evidence(c)
    assert Map.delete(after_observation, :ledger) == Map.delete(before, :ledger)
    assert String.starts_with?(after_observation.ledger, before.ledger)
    suffix = binary_part(after_observation.ledger, byte_size(before.ledger), byte_size(after_observation.ledger) - byte_size(before.ledger))
    assert [observed_line, ""] = String.split(suffix, "\n")
    observed = Jason.decode!(observed_line)
    prefix_rows = before.ledger |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert rows() == prefix_rows ++ [observed]
    refute Enum.any?(prefix_rows, &(&1["event_type"] == "review.publication.observed"))
    assert [location] = Enum.filter(prefix_rows, &(&1["event_type"] == "review.publication.location"))
    assert [intent] = Enum.filter(prefix_rows, &(&1["event_type"] == "review.publication.intent"))
    assert location["issue_id"] == c.issue.id
    assert location["issue_identifier"] == c.issue.identifier
    assert intent["issue_id"] == c.issue.id
    assert intent["issue_identifier"] == c.issue.identifier
    assert observed["schema_version"] == 1
    assert observed["event"] == "review.publication.observed"
    assert observed["event_type"] == "review.publication.observed"
    assert observed["issue_id"] == c.issue.id
    assert observed["issue_identifier"] == c.issue.identifier
    assert observed["event_id"] == intent["metadata"]["observation_event_id"]
    assert {:ok, _, _} = DateTime.from_iso8601(observed["at"])

    common = %{
      "publication_version" => 1,
      "location_event_id" => location["event_id"],
      "workspace" => c.workspace,
      "pr_url" => c.pr_url,
      "pr_identity" => %{"host" => "github.com", "owner" => "example", "repo" => "repo", "number" => 1},
      "pr_source" => "caller_result",
      "raw_pr" => Map.take(c.raw, ["pr_url"]),
      "thread_key" => "comment:1",
      "operation" => "post",
      "reply_target" => "1",
      "draft_sha256" => :crypto.hash(:sha256, c.raw["review_threads"]["comment:1"]["draft_reply"]) |> Base.encode16(case: :lower),
      "binding" => Map.take(c.raw, ~w(run_id run_identity_event_id run_identity_ledger_path)),
      "dispatch_id" => c.ticket.dispatch_id
    }

    assert intent["metadata"] == Map.put(common, "observation_event_id", observed["event_id"])

    assert observed["metadata"] ==
             Map.merge(common, %{
               "intent_event_id" => intent["event_id"],
               "outcome" => "returned_success",
               "cause" => nil,
               "posted_reply_id" => "reply-1",
               "posted_reply_url" => c.pr_url <> "#reply",
               "posted_at" => observed["at"]
             })

    assert {:ok, ^observed} = RunLedger.CheckedStorage.fetch(c.ticket.ledger_path, observed["event_id"])
    assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c, github_effect: effect) end)
    assert evidence(c) == after_observation
    refute_received {:github_effect, :post}
    refute_received {:github_effect, :resolve}
    refute_received {:tracker_effect, _, _}
  end

  @tag stage: "merge"
  test "control after a remote merge leaves that effect observed and rejects the following CAS", c do
    effect = fn :merge ->
      control!(c, "policy_override")
      send(self(), {:control_evidence, evidence(c)})
    end

    assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c, github_effect: effect, checks: :passed) end)
    assert_received {:github_effect, :merge}
    refute_received {:github_effect, :merge}
    assert_received {:control_evidence, before}
    assert evidence(c) == before
    refute_received {:tracker_effect, _, _}
    refute Enum.any?(rows(), &(&1["event_type"] == "merge.completed"))
  end

  @tag stage: "deploy_preview"
  test "control after blocked persistence but before its confirmation prevents both notifications", c do
    assert :ok = GenServer.call(c.owner, {:before_advance, fn -> control!(c, "review_claims") end})
    assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c) end)
    assert raw!(c)["stage"] == "blocked"
    assert raw!(c)["review_claims"] == %{"operator" => %{"value" => "controlled"}}
    refute_received {:tracker_effect, :comment}
    refute_received {:tracker_effect, :move, _}
  end

  @tag stage: "merge_readiness", review: true
  test "public review maintenance posts and resolves once then returns its checked state to await checks", c do
    assert :ok =
             within(c, fn ->
               Enum.each(1..2, fn poll_count ->
                 assert :ok = run(c)
                 assert_received {:github_effect, :feedback}
                 refute_received {:github_effect, :feedback}

                 if poll_count == 1 do
                   assert_received {:github_effect, :post}
                   assert_received {:github_effect, :resolve}
                 end

                 refute_received {:github_effect, :post}
                 refute_received {:github_effect, :resolve}
                 raw = raw!(c)
                 assert raw["stage"] == "await_checks"
                 assert raw["await_checks_polls"] == poll_count
                 assert raw["review_threads"]["comment:1"]["resolution_state"] == "resolved"
                 assert raw["resume_context"]["already_learned"] == "retained"
                 assert owner_state(c).expected == RunStateStore.material_projection(raw)

                 polls = Enum.filter(rows(), &(&1["issue_id"] == c.issue.id and &1["event_type"] == "checks.polled"))
                 assert Enum.map(polls, & &1["metadata"]["poll_count"]) == Enum.to_list(1..poll_count)
               end)
             end)
  end

  test "a control accompanying an ordinary command failure wins before block or tracker effects", c do
    shell = fn _, "post-merge-fixture", _ ->
      control!(c, "policy_override")
      send(self(), {:control_evidence, evidence(c)})
      {"ordinary command failure", 17}
    end

    assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c, shell_runner: shell) end)
    assert_received {:control_evidence, before}
    assert evidence(c) == before
    refute_received {:tracker_effect, :comment}
    refute_received {:tracker_effect, :move, _}
  end

  test "an identified snapshot without the captured scope cannot enter a legacy route", c do
    before = evidence(c)
    assert {:stop, {:accounting_uncertain, :execution_context_missing}} = run(c)
    assert evidence(c) == before
    refute_received {:command_effect, _, _}
    refute_received {:tracker_effect, :move, _}
  end

  @tag stage: "await_checks"
  test "late bootstrap retains one provider, advances checked policy once and preserves usage plus lease refresh", c do
    transport = app_server!(c, [provider_turn(1, 10, needs_another_turn: true), provider_turn(2, 20, blocked: true, blocker_type: "environment")])

    checkpoint = fn "query DeliveryCheckpoint { viewer { id } }", %{"turn" => count}, [] ->
      assert count in [1, 2]
      assert {:ok, refreshed} = LeaseManager.refresh_token(c.token)
      assert {:ok, lease_state} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(refreshed))
      send(self(), {:provider_lease, count, lease_state.lease_updated_at})
      send(self(), {:provider_live_port, live_provider_port!()})

      if count == 1 do
        assert raw!(c)["policy_override"] == "fully_autonomous"
        assert {:ok, _} = AgentExecution.update_current(%{policy_override: "review_required"})
      else
        assert raw!(c)["policy_override"] == "review_required"
      end

      {:ok, %{"data" => %{"viewer" => %{"id" => "local-fixture"}}}}
    end

    {result, [closed_port]} =
      trace_provider_stops(self(), fn ->
        within(c, fn -> run(c, agent_provider: Codex, linear_client: checkpoint, policy_override: "fully_autonomous", checks: :failed) end)
      end)

    assert result == {:stop, :environment}
    assert String.split(File.read!(transport.starts), "\n", trim: true) == ["started"]
    assert_received {:provider_live_port, ^closed_port}
    assert_received {:provider_live_port, ^closed_port}
    refute_received {:provider_live_port, _}
    assert Port.info(closed_port) == nil
    assert_report_replies(transport, 2)
    assert raw!(c)["implementation_turns"] == 1
    assert raw!(c)["policy_override"] == "review_required"
    assert raw!(c)["token_usage"]["total_tokens"] == 22
    assert_received {:provider_lease, 2, updated_at}
    assert raw!(c)["lease_updated_at"] == updated_at
    advances = for {_, {:advance_current, previous, next}} <- owner_state(c).calls, do: {previous, next}
    assert Enum.count(advances, fn {previous, next} -> previous["policy_override"] != next["policy_override"] end) == 2
  end

  for control <- [:material, :authority] do
    @tag stage: "await_checks", control: control
    test "#{control} control while the provider retains its result prevents later Delivery effects", c do
      transport = app_server!(c, [provider_turn(1, 0, needs_another_turn: true)])

      checkpoint = fn "query DeliveryCheckpoint { viewer { id } }", %{"turn" => 1}, [] ->
        send(self(), :provider_result_retained)
        send(self(), {:provider_live_port, live_provider_port!()})

        case c.control do
          :material ->
            control!(c, "review_claims")

          :authority ->
            assert {:ok, :released} = LeaseManager.release_token(c.token)
            assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "successor-owner")
            on_exit(fn -> assert {:ok, :released} = LeaseManager.release_token(successor.token) end)
        end

        send(self(), {:control_evidence, evidence(c)})
        {:ok, %{"data" => %{"viewer" => %{"id" => "local-fixture"}}}}
      end

      {result, [closed_port]} =
        trace_provider_stops(self(), fn ->
          within(c, fn -> run(c, agent_provider: Codex, linear_client: checkpoint, checks: :failed) end)
        end)

      assert {:stop, {:stale_execution, ids, _cause}} = result
      assert ids == %{run_id: c.ticket.run_id, dispatch_id: c.ticket.dispatch_id}
      assert_received :provider_result_retained
      refute_received :provider_result_retained
      assert_received {:control_evidence, before}
      assert evidence(c) == before
      assert String.split(File.read!(transport.starts), "\n", trim: true) == ["started"]
      assert_received {:provider_live_port, ^closed_port}
      refute_received {:provider_live_port, _}
      assert Port.info(closed_port) == nil
      assert_report_replies(transport, 1)
      refute_received {:tracker_effect, :comment}
      refute_received {:tracker_effect, :move, _}
      assert raw!(c)["stage"] == "implement"
      assert raw!(c)["implementation_turns"] == 0
    end
  end

  @tag stage: "implement", real_owner: true
  test "real owner soft pressure survives the next Delivery checkpoint with its summary and lease", c do
    transport = app_server!(c, [provider_turn(1, 65_000, needs_another_turn: true), provider_turn(2, 65_000, blocked: true, blocker_type: "environment")])
    observer = self()

    checkpoint = fn "query DeliveryCheckpoint { viewer { id } }", %{"turn" => count}, [] ->
      current = raw!(c)
      runtime = GenServer.call(c.owner, :runtime)
      expected = runtime.running[c.issue.id].agent_execution.expected
      assert current["resume_context"]["token_pressure"] == "high"
      assert current["token_usage"]["total_tokens"] == 71_500
      assert expected === RunStateStore.material_projection(current)
      assert runtime.agent_totals.total_tokens == 71_500
      assert {:ok, checked} = AgentExecution.ensure_current()
      assert checked.resume_context.token_pressure == "high"
      assert GenServer.call(c.owner, :runtime).running[c.issue.id].agent_execution.expected === expected

      if count == 1 do
        assert current["implementation_turns"] == 0
        assert {:ok, refreshed} = LeaseManager.refresh_token(c.token)
        assert {:ok, lease_state} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(refreshed))
        send(observer, {:policy_lease, lease_state.lease_updated_at})
      else
        assert count == 2
        assert current["implementation_turns"] == 1
        assert current["resume_context"]["last_turn_summary"] == "Fixture turn 1"
        assert current["resume_context"]["next_objective"] == "Continue implementation from the existing diff. Last turn summary: Fixture turn 1"
      end

      send(observer, {:pressure_checkpoint, count, live_provider_port!()})
      {:ok, %{"data" => %{"viewer" => %{"id" => "local-fixture"}}}}
    end

    {result, [closed_port]} =
      trace_provider_stops(c.worker, fn ->
        in_worker(c.worker, fn -> run(c, agent_provider: Codex, linear_client: checkpoint) end)
      end)

    assert result == {:stop, :environment}
    assert_received {:pressure_checkpoint, 1, ^closed_port}
    assert_received {:pressure_checkpoint, 2, ^closed_port}
    refute_received {:pressure_checkpoint, _, _}
    assert String.split(File.read!(transport.starts), "\n", trim: true) == ["started"]
    assert Port.info(closed_port) == nil
    assert_report_replies(transport, 2)
    assert_received {:policy_lease, updated_at}
    final = raw!(c)
    assert final["resume_context"]["token_pressure"] == "high"
    assert final["resume_context"]["last_turn_summary"] == "Fixture turn 1"
    assert final["token_usage"]["total_tokens"] == 71_500
    assert final["lease_updated_at"] == updated_at
    assert final["implementation_turns"] == 1
    runtime = GenServer.call(c.owner, :runtime)
    assert runtime.running[c.issue.id].agent_execution.expected === RunStateStore.material_projection(final)
    assert runtime.token_usage_errors == %{} and runtime.stale_execution_errors == %{}
    assert runtime.lease_claims[c.issue.id].token == c.token
    assert Enum.any?(rows(), &(&1["event_type"] == "policy.decided" and &1["summary"] == "Turn entered soft token pressure."))
    send(c.worker, :finish)
    worker = c.worker
    owner = c.owner
    ref = c.entry.ref
    assert_receive {:worker_down, ^owner, {:DOWN, ^ref, :process, ^worker, :normal}, stopped}, 5_000
    assert stopped.running == %{} and stopped.lease_claims == %{}
    assert stopped.token_usage_errors == %{} and stopped.stale_execution_errors == %{}
    assert {:error, :missing} = LeaseManager.read(c.issue.id)
  end

  for destination <- ["done", "post_deploy_verify"] do
    @tag stage: "deploy_preview", deploy: true, deploy_verify: destination == "post_deploy_verify", destination: destination
    test "public deploy retains its checked state and exact continuation to #{destination}", c do
      shell = fn _, "deploy-fixture", _ ->
        send(self(), :deploy_effect)
        {"deployment observed once", 0}
      end

      result = within(c, fn -> run(c, shell_runner: shell) end)
      assert result == if(c.destination == "done", do: {:done, c.issue}, else: :ok)
      assert_received :deploy_effect
      refute_received :deploy_effect
      raw = raw!(c)
      assert raw["stage"] == c.destination
      assert raw["last_deploy_preview"]["output"] == "deployment observed once"
      assert owner_state(c).expected == RunStateStore.material_projection(raw)
      assert :ok = DeployAudit.ensure_available(c.workspace)
      refute File.exists?(DeployAudit.marker_directory(c.workspace))
      assert {:ok, transition} = RunLedger.fetch_entry_checked(raw["last_ledger_event_id"])
      assert transition["metadata"]["deploy_operation_id"] == raw["last_deploy_operation_id"]
      assert transition["stage"] == c.destination
      assert Enum.count(rows(), &(&1["event_type"] == "deploy.preview.requested")) == 1
      assert Enum.count(rows(), &(&1["event_type"] == "deploy.preview.observed")) == 1
    end
  end

  @tag stage: "deploy_preview", deploy: true
  test "material control during deployment leaves the journal unresolved and never replays the effect", c do
    shell = fn _, "deploy-fixture", _ ->
      send(self(), :deploy_effect)
      control!(c, "review_threads")
      send(self(), {:control_evidence, evidence(c)})
      {"deployment already happened", 0}
    end

    assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c, shell_runner: shell) end)
    assert_received :deploy_effect
    refute_received :deploy_effect
    assert_received {:control_evidence, before}
    assert Map.delete(evidence(c), :ledger) == Map.delete(before, :ledger)
    assert File.exists?(DeployAudit.marker_directory(c.workspace))
    assert raw!(c)["stage"] == "deploy_preview"
    refute_received {:tracker_effect, :move, _}
    assert Enum.count(rows(), &(&1["event_type"] == "deploy.preview.requested")) == 1
    [observed] = Enum.filter(rows(), &(&1["event_type"] == "deploy.preview.observed"))
    marker = c.workspace |> DeployAudit.marker_directory() |> Path.join("marker.json") |> File.read!() |> Jason.decode!()
    assert marker["version"] == 2
    assert marker["status"] == "result_confirmed"
    assert marker["continuation_denied"] == %{"phase" => "record_result", "kind" => "stale_execution", "reason_tag" => "material_state_changed"}
    assert marker["execution"]["dispatch_ticket"]["run_id"] == c.ticket.run_id
    assert marker["execution"]["dispatch_ticket"]["dispatch_id"] == c.ticket.dispatch_id
    assert marker["result"] == observed
    assert observed["metadata"]["deploy_operation_id"] == marker["operation_id"]
    assert observed["metadata"]["execution"]["run_id"] == c.ticket.run_id
    assert observed["metadata"]["execution"]["dispatch_id"] == c.ticket.dispatch_id
    assert observed["metadata"]["result"] == %{"status" => "passed", "command" => "deploy-fixture", "output" => "deployment already happened"}
    prefix_rows = before.ledger |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert rows() == prefix_rows ++ [observed]
    after_observation = evidence(c)
    assert {:stop, {:stale_execution, _, :material_state_changed}} = within(c, fn -> run(c, shell_runner: shell) end)
    assert evidence(c) == after_observation
    refute_received :deploy_effect
    refute_received {:tracker_effect, :move, _}
  end

  defp within(c, fun),
    do:
      DispatchAudit.with_authorization(c.ticket, fn ->
        AgentExecution.with_context(c.ticket, c.token, c.owner, c.raw, fun)
      end)

  defp run(c, extra \\ []) do
    checks = Keyword.get(extra, :checks, :pending)
    github_opts = [test: self(), pr_url: c.pr_url, github_effect: Keyword.get(extra, :github_effect, fn _ -> :ok end)]

    opts = [
      command_runner: fn command, args, options ->
        Process.put(:delivery_command_count, Process.get(:delivery_command_count, 0) + 1)
        send(self(), {:command_effect, command, args})
        command(c, checks, command, args, options)
      end,
      shell_runner: fn _, shell, _ -> flunk("Unexpected shell: #{shell}") end,
      github_client: GitHub,
      github_client_opts: github_opts,
      issue_state_fetcher: fn [_] -> {:ok, [c.issue]} end
    ]

    DeliveryEngine.run(c.workspace, c.issue, nil, Keyword.merge(opts, extra))
  end

  defp command(_c, _checks, "git", ["config", "--get", "remote.origin.url"], _), do: {"git@example.com:repo.git\n", 0}
  defp command(_c, _checks, "git", ["rev-parse", "--abbrev-ref", "HEAD"], _), do: {"main\n", 0}
  defp command(_c, _checks, "git", ["rev-parse", "HEAD"], _), do: {"fixture-head\n", 0}
  defp command(_c, _checks, "git", ["status", "--porcelain"], _), do: {"", 0}

  defp command(_c, _checks, "git", ["fetch", "origin", "--prune", "refs/heads/main:refs/remotes/origin/main"], _) do
    {"", 0}
  end

  defp command(_c, _checks, "git", ["checkout", "-f", "-B", "main", "origin/main"], _), do: {"", 0}
  defp command(_c, _checks, "git", ["reset", "--hard", "origin/main"], _), do: {"", 0}

  defp command(c, checks, "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _) do
    {status, conclusion} =
      case checks do
        :pending -> {"IN_PROGRESS", nil}
        :passed -> {"COMPLETED", "SUCCESS"}
        :failed -> {"COMPLETED", "FAILURE"}
      end

    {Jason.encode!(%{url: c.pr_url, state: "OPEN", reviewDecision: "APPROVED", statusCheckRollup: [%{name: "fixture-check", status: status, conclusion: conclusion}]}), 0}
  end

  defp command(_c, _checks, executable, args, _opts), do: flunk("Unexpected command: #{inspect({executable, args})}")

  defp in_worker(worker, fun) do
    ref = make_ref()
    send(worker, {:exercise, self(), ref, fun})

    receive do
      {:exercise_result, ^ref, {:fixture_exception, exception, stack}} -> reraise exception, stack
      {:exercise_result, ^ref, {:fixture_caught, kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
      {:exercise_result, ^ref, result} -> result
    after
      10_000 -> flunk("admitted Delivery worker did not finish")
    end
  end

  defp provider_turn(index, input, report_attrs) do
    %{
      index: index,
      input: input,
      output: div(input, 10),
      report:
        Map.merge(
          %{
            summary: "Fixture turn #{index}",
            files_touched: [],
            needs_another_turn: false,
            blocked: false,
            blocker_type: "none"
          },
          Map.new(report_attrs)
        )
    }
  end

  defp app_server!(c, turns) do
    starts = Path.join(c.root, "provider-starts")
    replies = Path.join(c.root, "provider-report-replies")
    File.write!(starts, "")
    File.write!(replies, "")

    cases =
      Enum.map_join(turns, "\n", fn turn ->
        usage = %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{"threadId" => "delivery-thread", "tokenUsage" => %{"total" => %{"inputTokens" => turn.input, "outputTokens" => turn.output, "totalTokens" => turn.input + turn.output}}}
        }

        started = %{"id" => 3, "result" => %{"turn" => %{"id" => "delivery-turn-#{turn.index}"}}}
        report = provider_request(72, "report_agent_turn_result", turn.report, turn.index)
        "#{turn.index})\n" <> Enum.map_join([usage, started, report], "\n", &("printf '%s\\n' " <> quote_shell(Jason.encode!(&1)))) <> "\n;;"
      end)

    checkpoints =
      Enum.map_join(turns, "\n", fn turn ->
        request = provider_request(73, "linear_graphql", %{query: "query DeliveryCheckpoint { viewer { id } }", variables: %{turn: turn.index}}, turn.index)
        "#{turn.index}) printf '%s\\n' #{quote_shell(Jason.encode!(request))} ;;"
      end)

    path = Path.join(c.root, "codex")

    File.write!(path, """
    #!/bin/sh
    set -eu
    turn=0
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf 'started\\n' >> #{quote_shell(starts)}
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"delivery-thread"}}}' ;;
        *'"method":"turn/start"'*)
          turn=$((turn + 1))
          case "$turn" in
            #{cases}
            *) exit 91 ;;
          esac
          ;;
        *'"id":72'*)
          printf '%s\\n' "$line" >> #{quote_shell(replies)}
          case "$turn" in
            #{checkpoints}
            *) exit 92 ;;
          esac
          ;;
        *'"id":73'*) printf '%s\\n' '{"method":"turn/completed"}' ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
    %{starts: starts, replies: replies}
  end

  defp provider_request(id, tool, arguments, index) do
    %{
      "id" => id,
      "method" => "item/tool/call",
      "params" => %{"tool" => tool, "callId" => "delivery-call-#{id}-#{index}", "threadId" => "delivery-thread", "turnId" => "delivery-turn-#{index}", "arguments" => arguments}
    }
  end

  defp assert_report_replies(transport, count) do
    replies = transport.replies |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(replies) == count

    Enum.each(replies, fn reply ->
      assert %{"id" => 72, "result" => %{"success" => true, "contentItems" => [%{"text" => "turn result recorded"}]}} = reply
    end)
  end

  defp live_provider_port! do
    {:links, links} = Process.info(self(), :links)
    [port] = Enum.filter(links, &is_port/1)
    refute is_nil(Port.info(port))
    port
  end

  defp trace_provider_stops(worker, fun) do
    Code.ensure_loaded!(Codex)
    observer = self()
    {tracer, monitor} = spawn_monitor(fn -> collect_provider_stops(observer, worker, []) end)
    :erlang.trace_pattern({Codex, :stop_session, 1}, true, [])
    :erlang.trace(worker, true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      ref = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, _, ^ref}, 1_000
      send(tracer, :flush)
      assert_receive {:provider_stops, ports}, 1_000
      {result, ports}
    after
      :erlang.trace(worker, false, [:call])
      :erlang.trace_pattern({Codex, :stop_session, 1}, false, [])
      send(tracer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^tracer, :normal}, 1_000
    end
  end

  defp collect_provider_stops(observer, worker, ports) do
    receive do
      {:trace, ^worker, :call, {Codex, :stop_session, [%{port: port}]}} ->
        collect_provider_stops(observer, worker, ports ++ [port])

      :flush ->
        send(observer, {:provider_stops, ports})
        collect_provider_stops(observer, worker, ports)

      :stop ->
        :ok
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp control!(c, field) do
    value = if field in ["review_claims", "review_threads"], do: %{"operator" => %{"value" => "controlled"}}, else: "operator-control"

    :global.trans({{RunStateStore, c.workspace}, self()}, fn ->
      raw = raw!(c)
      File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(Map.put(raw, field, value)))
    end)
  end

  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp rows, do: RunLedger.ledger_file_path() |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp owner_state(c), do: GenServer.call(c.owner, :state)

  defp evidence(c),
    do: %{
      commands: Process.get(:delivery_command_count, 0),
      github: Process.get(:delivery_github_count, 0),
      snapshot: File.read!(RunStateStore.state_path(c.workspace)),
      ledger: File.read!(RunLedger.ledger_file_path()),
      lease: File.read(c.token.storage.lease_path),
      dispatch: File.read(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json"))
    }
end
