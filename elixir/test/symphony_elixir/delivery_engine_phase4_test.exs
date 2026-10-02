defmodule SymphonyElixir.DeliveryEnginePhase4Test do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.Workflow

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  test "review_required issues publish successfully but stop at Human Review" do
    {workspace, issue} = await_checks_workspace!("review-required", ["policy:review-required"])
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("review-required")
    )

    assert :ok =
             run_with_evidence(workspace, issue, nil, command_runner: &review_ready_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "Rule ID: policy.review_required"
    assert body =~ "Failure class: policy"
    assert body =~ "Unblock action:"

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.last_rule_id == "policy.review_required"
    assert state.last_failure_class == "policy"
    assert state.next_human_action =~ "approve it for merge"
  end

  test "never_automerge issues stay in Human Review even when checks are green" do
    {workspace, issue} = await_checks_workspace!("never-automerge", ["policy:never-automerge"])
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("never-automerge")
    )

    assert :ok =
             run_with_evidence(workspace, issue, nil, command_runner: &review_ready_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "Rule ID: policy.never_automerge"
    assert body =~ "Failure class: policy"
    assert body =~ "Unblock action:"

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.last_rule_id == "policy.never_automerge"
    assert state.last_failure_class == "policy"
    assert state.next_human_action =~ "will not automerge"
  end

  defp await_checks_workspace!(suffix, labels) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-delivery-engine-phase4-#{suffix}-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "MT-AWAIT")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    File.mkdir_p!(Path.join(workspace, "scripts"))

    for gate <- ["validate", "smoke", "artifacts"] do
      path = Path.join(workspace, "scripts/#{gate}.sh")
      File.write!(path, "#!/bin/sh\ntest -s README.md\n")
      File.chmod!(path, 0o755)
    end

    File.write!(Path.join(workspace, ".gitignore"), ".symphony/\n")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command:
        - ./scripts/preflight.sh
    validation:
      command:
        - ./scripts/validate.sh
    smoke:
      command:
        - ./scripts/smoke.sh
    post_merge:
      command:
        - ./scripts/post-merge.sh
    artifacts:
      command:
        - ./scripts/artifacts.sh
    pull_request:
      required_checks:
        - make-all
    """)

    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["add", "README.md", ".gitignore", "scripts"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)

    issue = %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-AWAIT",
      title: "Policy gated merge",
      description: "## Acceptance Criteria\n- wait for policy routing",
      state: "In Progress",
      labels: labels
    }

    {workspace, issue}
  end

  defp review_ready_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/42",
      "state" => "OPEN",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => [
        %{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
      ]
    }

    {Jason.encode!(payload), 0}
  end

  defp review_ready_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp fake_codex_binary!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-phase4-fake-codex-#{suffix}-#{System.unique_integer([:positive])}"
      )

    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(root)

    File.write!(binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-phase4"}}}'
          ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)
    "#{binary} app-server"
  end

  # Genuine lease/admission/AE and checked storage; the fixture owner models
  # the worker RPC protocol. It does not claim Orchestrator scheduling or DOWN.
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

  defp admitted(workspace, issue, fun) do
    alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunStateStore}
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "evidence-owner-#{System.unique_integer([:positive])}")
    assert {:ok, _} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(acquired.lease))
    assert {:ok, source, view} = RunStateStore.read_admission_source(workspace, issue)

    assert {:ok, ticket, raw} =
             DispatchAudit.begin(workspace, %{issue_id: issue.id, issue_identifier: issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}, source)

    assert {:ok, owner} = Owner.start_link(%{ticket: ticket, token: acquired.token, raw: raw, issue: issue, worker: self()})

    try do
      DispatchAudit.with_authorization(ticket, fn ->
        AgentExecution.with_context(ticket, acquired.token, owner, raw, fn -> fun.(%{ticket: ticket, token: acquired.token, owner: owner, raw: raw}) end)
      end)
    after
      if Process.alive?(owner), do: GenServer.stop(owner)
      assert :ok = DispatchAudit.finish(ticket, :normal)
      assert {:ok, release} = LeaseManager.release_token(acquired.token)
      assert release in [:released, :missing]
    end
  end

  defp verifier_pass(_workspace, _issue, _state, _opts) do
    {:ok, %SymphonyElixir.VerifierResult{verdict: :pass, summary: "Fixture criterion passed", acceptance_gaps: [], risky_areas: [], evidence: ["Runtime fixture"], raw_output: "pass"}}
  end

  defp run_with_evidence(workspace, issue, recipient, opts) do
    admitted(workspace, issue, fn _execution ->
      SymphonyElixir.DeliveryEngine.run(workspace, issue, recipient, Keyword.put_new(opts, :verifier_session_runner, &verifier_pass/4))
    end)
  end
end
