defmodule SymphonyElixir.RunPolicyCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunLedger, RunStateStore}

  # Real checked storage, with only the tracker transport and command runners replaced.
  # This fixture is not evidence for Orchestrator custody, DOWN handling or providers.
  defmodule Owner do
    use GenServer
    alias SymphonyElixir.{RunPolicy, RunStateStore}

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      context = %{ticket: opts.ticket, lease_token: opts.token, owner: self(), worker: opts.worker, issue_id: opts.issue.id}

      {:ok,
       %{context: context, issue: opts.issue, authority: %{ticket: opts.ticket, lease_token: opts.token}, expected: RunStateStore.material_projection(opts.raw), known: nil, calls: [], terminal: nil}}
    end

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}

    def handle_call({:budget, entry}, _from, state) do
      result = RunPolicy.maybe_stop_for_token_budget(state.issue, entry, %{authority: state.authority, expected: state.expected})
      {:reply, result, state}
    end

    def handle_call({:agent_execution, invocation, expected, action}, {pid, _tag}, state) do
      true = pid == state.context.worker
      true = invocation == %{context: state.context, binding: nil, ordinal: 0}
      true = expected == state.expected
      state = %{state | calls: state.calls ++ [action]}
      {reply, state} = reply_to(action, state)
      {:reply, reply, state}
    end

    defp reply_to({:confirm, nil, 0}, state) do
      case RunStateStore.ensure_current(state.authority, state.expected) do
        {:ok, _current} -> {:ok, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    end

    defp reply_to({:confirm_own_terminal, previous, next}, state) do
      true = previous == state.expected

      case RunStateStore.confirm_terminal_current(state.authority, next) do
        :ok -> {{:ok, :terminal_confirmed}, %{state | expected: next, known: next}}
        {:error, reason} -> {{:error, reason}, state}
      end
    end

    defp reply_to(:confirm_stop_notification, %{known: next, expected: next} = state) when is_map(next) do
      {RunStateStore.confirm_terminal_current(state.authority, next), state}
    end

    @impl true
    def handle_info({:agent_execution_stale, context, ids, cause}, state) do
      true = context == state.context
      true = ids == %{run_id: context.ticket.run_id, dispatch_id: context.ticket.dispatch_id}
      {:noreply, %{state | terminal: {:stale_execution, ids, cause}}}
    end

    def handle_info({:agent_execution_uncertain, context, cause}, state) do
      true = context == state.context
      {:noreply, %{state | terminal: {:accounting_uncertain, cause}}}
    end
  end

  defmodule TrackerClient do
    alias SymphonyElixir.RunStateStore

    def graphql(query, vars) do
      fixture = Application.fetch_env!(:symphony_elixir, __MODULE__)
      raw = fixture.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

      cond do
        String.contains?(query, "SymphonyCreateComment") ->
          send(fixture.test, {:policy_comment, vars.issueId, vars.body, raw})

          if fixture.control_after_comment do
            {:ok, _} = RunStateStore.update(fixture.workspace, &Map.put(&1, :policy_override, "control-after-comment"))
          end

          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

        String.contains?(query, "SymphonyResolveStateId") ->
          {:ok, %{"data" => %{"issue" => %{"team" => %{"id" => "team-" <> vars.issueId, "states" => %{"nodes" => [%{"id" => vars.stateName}]}}}}}}

        String.contains?(query, "SymphonyUpdateIssueState") ->
          send(fixture.test, {:policy_move, vars.issueId, vars.stateId, raw})

          if fixture.fail_promotion and vars.stateId == "In Progress" do
            {:error, :promotion_failed}
          else
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
          end
      end
    end
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "policy-current-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "POLICY-1")

    issue = %Issue{
      id: "policy-#{System.unique_integer([:positive])}",
      identifier: "POLICY-1",
      title: "A small runtime change",
      state: if(tags[:todo], do: "Todo", else: "In Progress"),
      source: :tracker
    }

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, policy_token_budget: budget())
    resume = Map.merge(%{already_learned: "fresh", target_paths: ["Sources/a.ex"], next_required_path: "Sources/b.ex"}, tags[:resume] || %{})
    raw = %{"issue_id" => issue.id, "issue_identifier" => issue.identifier, "resume_context" => resume}
    raw = if tags[:raw_stage] == :absent, do: raw, else: Map.put(raw, "stage", tags[:raw_stage] || "implement")
    File.write!(RunStateStore.state_path(workspace), Jason.encode!(raw))
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_fixture = Application.get_env(:symphony_elixir, TrackerClient)
    Application.put_env(:symphony_elixir, :linear_client_module, TrackerClient)
    Application.put_env(:symphony_elixir, TrackerClient, %{test: self(), workspace: workspace, control_after_comment: tags[:control_after_comment] == true, fail_promotion: tags[:todo] == true})

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_app_env(:symphony_elixir, :linear_client_module, previous_client)
      SymphonyElixir.TestSupport.restore_app_env(:symphony_elixir, TrackerClient, previous_fixture)
      File.rm_rf!(root)
    end)

    base = %{root: root, workspace: workspace, issue: issue}

    if tags[:legacy] do
      base
    else
      assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "policy-current-owner")
      assert {:ok, source, view} = RunStateStore.read_admission_source(workspace, issue)

      assert {:ok, ticket, admitted} =
               DispatchAudit.begin(
                 workspace,
                 %{issue_id: issue.id, issue_identifier: issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}},
                 source
               )

      owner = start_supervised!({Owner, %{issue: issue, ticket: ticket, token: acquired.token, raw: admitted, worker: self()}})
      on_exit(fn -> assert {:ok, :released} = LeaseManager.release_token(acquired.token) end)

      Map.merge(base, %{
        ticket: ticket,
        token: acquired.token,
        raw: admitted,
        owner: owner,
        precondition: %{authority: %{ticket: ticket, lease_token: acquired.token}, expected: RunStateStore.material_projection(admitted)}
      })
    end
  end

  for stage <- [:absent, "validate"] do
    @tag raw_stage: stage
    test "checked soft pressure preserves RAW stage #{inspect(stage)} and fresh diagnostics", c do
      assert {:ok, _} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage(75), c.precondition.authority, c.precondition.expected)
      before = raw!(c)
      stage_events = stage_events()
      entry = Map.put(entry(c, 65_000), :resume_context, %{already_learned: "obsolete"})
      assert {:ok, :ok, persisted} = RunPolicy.maybe_stop_for_token_budget(c.issue, entry, c.precondition)
      assert persisted.resume_context.already_learned == "fresh"
      assert persisted.resume_context.token_pressure == "high"
      assert persisted.token_usage == usage(75)
      assert RunStateStore.material_projection(persisted) == c.precondition.expected
      assert Map.fetch(raw!(c), "stage") == Map.fetch(before, "stage")
      assert stage_events() == stage_events
      refute_received {:policy_comment, _, _, _}
      refute_received {:policy_move, _, _, _}
    end
  end

  @tag raw_stage: "validate", resume: %{budget_mode: "review_fix", budget_scope_kind: "review_claim_batch", budget_scope_ids: ["comment:1", "comment:2"]}
  test "checked review retry threads the pressure write without taking entry stage", c do
    configure_budget!(c, %{review_fix: review_budget()})
    before_events = stage_events()

    assert {:ok, {:retry, %{kind: :review_fix_budget_retry, retry_count: 1}}, persisted} =
             RunPolicy.maybe_stop_for_token_budget(c.issue, entry(c, 130_000), c.precondition)

    assert persisted.resume_context.budget_pressure_level == "soft"
    assert persisted.resume_context.budget_retry_count == 1
    assert persisted.resume_context.budget_scope_ids == ["comment:1"]
    assert persisted.stage == "validate"
    assert RunStateStore.material_projection(persisted) == c.precondition.expected
    assert stage_events() == before_events
  end

  @tag raw_stage: :absent
  test "checked broad retry uses the latest resume delta without creating a stage", c do
    configure_budget!(c, %{broad_implement: %{enabled: true, auto_retry_limit: 2}})
    before_events = stage_events()

    assert {:ok, {:retry, %{kind: :broad_implement_budget_retry, retry_count: 1}}, persisted} =
             RunPolicy.maybe_stop_for_token_budget(c.issue, entry(c, 130_000), c.precondition)

    assert persisted.resume_context.token_pressure == "high"
    assert persisted.resume_context.budget_retry_count == 1
    refute Map.has_key?(persisted, :stage)
    assert RunStateStore.material_projection(persisted) == c.precondition.expected
    assert stage_events() == before_events
  end

  @tag resume: %{budget_mode: "review_fix", budget_progress_count: 1}
  test "checked total extension returns the successful resume-only persistence", c do
    configure_budget!(c, %{per_issue_total: 100_000, review_fix: review_budget()})
    running = Map.put(entry(c, 10_000), :issue_token_usage_base, usage(100_000))
    assert {:ok, :ok, persisted} = RunPolicy.maybe_stop_for_token_budget(c.issue, running, c.precondition)
    assert persisted.resume_context.budget_total_extension_used == true
    assert RunStateStore.material_projection(persisted) == c.precondition.expected
  end

  test "a failed checked soft-pressure write is returned before any later decision", c do
    before = evidence(c)
    directory = Path.dirname(RunStateStore.state_path(c.workspace))
    File.chmod!(directory, 0o500)

    try do
      assert {:error, :eacces} = RunPolicy.maybe_stop_for_token_budget(c.issue, entry(c, 65_000), c.precondition)
    after
      File.chmod!(directory, 0o700)
    end

    assert evidence(c) == before
    refute_received {:policy_comment, _, _, _}
    refute_received {:policy_move, _, _, _}
  end

  @tag resume: %{budget_mode: "review_fix", budget_pressure_level: "high", budget_scope_kind: "review_claim_batch", budget_scope_ids: ["comment:1"]}
  test "a failed checked retry write never returns a retry or sends stop effects", c do
    configure_budget!(c, %{review_fix: review_budget()})
    before = evidence(c)
    directory = Path.dirname(RunStateStore.state_path(c.workspace))
    File.chmod!(directory, 0o500)

    try do
      assert {:error, :eacces} = RunPolicy.maybe_stop_for_token_budget(c.issue, entry(c, 130_000), c.precondition)
    after
      File.chmod!(directory, 0o700)
    end

    assert evidence(c) == before
    refute_received {:policy_comment, _, _, _}
    refute_received {:policy_move, _, _, _}
  end

  test "a material control rejects the captured policy precondition before effects", c do
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "control"))
    before = evidence(c)

    assert {:error, {:stale_execution, :material_state_changed}} =
             RunPolicy.maybe_stop_for_token_budget(c.issue, entry(c, 130_000), c.precondition)

    assert evidence(c) == before
    refute_received {:policy_comment, _, _, _}
    refute_received {:policy_move, _, _, _}
  end

  test "checked policy rejects a different issue even with a valid ticket", c do
    before = evidence(c)
    issue = %{c.issue | identifier: "OTHER-1"}

    assert {:error, {:stale_execution, :execution_issue_mismatch}} =
             RunPolicy.maybe_stop_for_token_budget(issue, entry(c, 130_000), c.precondition)

    assert evidence(c) == before
  end

  test "owner budget stop persists and confirms blocked without calling itself through AgentExecution", c do
    assert {:ok, {:stop, %RunPolicy.Violation{code: :per_turn_input_budget_exceeded}}, persisted} =
             GenServer.call(c.owner, {:budget, entry(c, 130_000)})

    assert persisted.stage == "blocked"
    assert {:error, {:stale_execution, _}} = RunStateStore.ensure_current(c.precondition.authority, c.precondition.expected)
    assert :ok = RunStateStore.confirm_terminal_current(c.precondition.authority, RunStateStore.material_projection(persisted))
    assert_received {:policy_comment, id, body, %{"stage" => "blocked"}}
    assert id == c.issue.id
    assert body =~ c.issue.identifier
    assert_received {:policy_move, ^id, "Blocked", %{"stage" => "blocked"}}
    assert GenServer.call(c.owner, :state).calls == []
  end

  @tag control_after_comment: true
  test "owner control after a confirmed stop comment prevents the second notification", c do
    assert {:error, {:stale_execution, :material_state_changed}} =
             GenServer.call(c.owner, {:budget, entry(c, 130_000)})

    assert_received {:policy_comment, _, _, %{"stage" => "blocked"}}
    refute_received {:policy_move, _, _, _}
    assert raw!(c)["policy_override"] == "control-after-comment"
    assert raw!(c)["stage"] == "blocked"
  end

  @tag todo: true
  test "audited Todo promotion failure retains the full issue and workspace for own terminal closure", c do
    opts = preflight_opts!(c)

    assert {:stop, %RunPolicy.Violation{code: :preflight_failed}} =
             in_worker(c, fn ->
               result = RunPolicy.enforce_pre_run(c.issue, c.workspace, opts)
               assert {:stop, {:execution_stopped, %{stage: "blocked"}}} = AgentExecution.ensure_current()
               result
             end)

    assert_received :preflight_ran
    assert_received {:policy_move, id, "In Progress", %{"stage" => "implement"}}
    assert id == c.issue.id
    assert_received {:policy_comment, ^id, body, %{"stage" => "blocked", "issue_identifier" => "POLICY-1"}}
    assert body =~ c.issue.identifier
    assert_received {:policy_move, ^id, "Blocked", %{"stage" => "blocked"}}
    actions = GenServer.call(c.owner, :state).calls
    assert Enum.count(actions, &match?({:confirm_own_terminal, _, _}, &1)) == 1
    assert Enum.count(actions, &(&1 == :confirm_stop_notification)) == 2
    assert raw!(c)["stop_reason"]["code"] == "preflight_failed"
  end

  @tag todo: true, control_after_comment: true
  test "worker stop preserves a later stale cause and prevents the second closure notification", c do
    opts = preflight_opts!(c)

    assert {:stop, {:stale_execution, _, :material_state_changed}} =
             in_worker(c, fn ->
               RunPolicy.enforce_pre_run(c.issue, c.workspace, opts)
             end)

    assert_received {:policy_move, _, "In Progress", _}
    assert_received {:policy_comment, _, _, %{"stage" => "blocked"}}
    refute_received {:policy_move, _, "Blocked", _}
    assert raw!(c)["stage"] == "blocked"
    assert raw!(c)["policy_override"] == "control-after-comment"
  end

  @tag todo: true, legacy: true
  test "legacy Todo promotion failure still records the correct workspace and full issue", c do
    opts = preflight_opts!(c)
    assert {:stop, %RunPolicy.Violation{code: :preflight_failed}} = RunPolicy.enforce_pre_run(c.issue, c.workspace, opts)
    assert_received {:policy_comment, id, body, %{"stage" => "blocked"}}
    assert id == c.issue.id
    assert body =~ c.issue.identifier
    assert raw!(c)["issue_identifier"] == c.issue.identifier
  end

  test "an identified workspace without execution context cannot inspect or run preflight", c do
    opts = preflight_opts!(c)
    assert {:stop, {:accounting_uncertain, :execution_context_missing}} = RunPolicy.enforce_pre_run(c.issue, c.workspace, opts)
    refute_received :command_ran
    refute_received :preflight_ran
    refute_received {:policy_move, _, _, _}
  end

  @tag todo: true
  test "material control during preflight prevents Todo promotion", c do
    opts =
      preflight_opts!(c, fn ->
        assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "preflight-control"))
      end)

    assert {:stop, {:stale_execution, _, :material_state_changed}} =
             in_worker(c, fn ->
               RunPolicy.enforce_pre_run(c.issue, c.workspace, opts)
             end)

    assert_received :preflight_ran
    refute_received {:policy_move, _, _, _}
    refute_received {:policy_comment, _, _, _}
    assert raw!(c)["policy_override"] == "preflight-control"
  end

  defp in_worker(c, fun) do
    DispatchAudit.with_authorization(c.ticket, fn ->
      AgentExecution.with_context(c.ticket, c.token, c.owner, c.raw, fun)
    end)
  end

  defp entry(c, tokens),
    do: %{
      issue: c.issue,
      workspace_path: c.workspace,
      stage: "implement",
      dispatch_stage: "implement",
      turn_count: 1,
      agent_input_tokens: tokens,
      agent_output_tokens: 0,
      agent_total_tokens: tokens,
      turn_started_input_tokens: 0
    }

  defp usage(tokens), do: %{input_tokens: tokens, output_tokens: 0, total_tokens: tokens}
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp evidence(c), do: {File.read!(RunStateStore.state_path(c.workspace)), File.read!(c.ticket.ledger_path)}

  defp stage_events do
    {:ok, path} = RunLedger.ledger_file_path_checked()

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["event_type"] == "stage.transition"))
  end

  defp budget do
    %{
      per_turn_input: 500_000,
      per_issue_total: 1_000_000,
      per_issue_total_output: 500_000,
      stages: %{implement: %{per_turn_input_soft: 60_000, per_turn_input_hard: 120_000}},
      broad_implement: %{enabled: false},
      review_fix: %{enabled: false}
    }
  end

  defp review_budget do
    %{
      enabled: true,
      per_turn_input_soft: 60_000,
      per_turn_input_hard: 120_000,
      retry_2_per_turn_input_hard: 150_000,
      retry_3_per_turn_input_hard: 220_000,
      max_turns_in_window: 3,
      retry_2_max_turns_in_window: 5,
      retry_3_max_turns_in_window: 7,
      auto_retry_limit: 3,
      narrow_scope_batch_size: 1,
      per_issue_total_extension: 150_000
    }
  end

  defp configure_budget!(c, attrs) do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: c.root, policy_token_budget: Map.merge(budget(), attrs))
  end

  defp preflight_opts!(c, after_preflight \\ fn -> :ok end) do
    File.mkdir_p!(Path.join(c.workspace, ".git"))

    File.write!(Path.join(c.workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command: ./scripts/preflight.sh
    validation:
      command: ./scripts/validate.sh
    smoke:
      command: ./scripts/smoke.sh
    post_merge:
      command: ./scripts/post-merge.sh
    artifacts:
      command: ./scripts/artifacts.sh
    verification:
      behavioral_proof:
        required: true
        mode: unit_first
        source_paths: [Sources]
        test_paths: [Tests]
    pull_request:
      required_checks: [ci / validate]
    """)

    parent = self()

    command_runner = fn "git", args, _opts ->
      send(parent, :command_ran)

      case args do
        ["config", "--get", "remote.origin.url"] -> {"https://example.test/repo.git\n", 0}
        ["rev-parse", "--abbrev-ref", "HEAD"] -> {"main\n", 0}
        ["rev-parse", "HEAD"] -> {"abc123\n", 0}
        ["rev-parse", "--verify", "--quiet", _ref] -> {"abc123\n", 0}
        ["status", "--porcelain"] -> {"", 0}
      end
    end

    shell_runner = fn workspace, _command, _opts ->
      true = workspace == c.workspace
      send(parent, :preflight_ran)
      after_preflight.()
      {"ok\n", 0}
    end

    [command_runner: command_runner, shell_runner: shell_runner, include_pr_details: false]
  end
end
