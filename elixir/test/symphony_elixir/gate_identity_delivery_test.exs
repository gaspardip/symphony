defmodule SymphonyElixir.GateIdentityDeliveryTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{DeliveryEngine, RunLedger, RunStateStore}

  defmodule GitHub do
    def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}
    def existing_pull_request(_, _), do: raise("negative gate reached publication")
    def create_pull_request(_, _, _, _, _, _), do: raise("negative gate reached publication")
    def edit_pull_request(_, _, _, _), do: raise("negative gate reached publication")
    def persist_pr_url(_, _, _, _), do: raise("negative gate reached publication")
  end

  setup do
    root = Path.join(System.tmp_dir!(), "gate-caller-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "GATE-2")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/\n")
    File.write!(Path.join(workspace, "README.md"), "fixture\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Gate Fixture"],
          ["config", "user.email", "gate@example.invalid"],
          ["add", "-A"],
          ["-c", "commit.gpgsign=false", "commit", "-qm", "fixture"]
        ] do
      assert {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, "lib/feature.ex"), "changed\n")
    File.write!(Path.join(workspace, "proof.json"), "{\"criterion\":true}\n")

    issue = %Issue{
      id: "gate-#{System.unique_integer([:positive])}",
      identifier: "GATE-2",
      source: :tracker,
      state: "In Progress",
      title: "Gate identity",
      description: "## Acceptance Criteria\n- Verify fixture criterion",
      labels: []
    }

    assert {_, 0} = System.cmd("git", ["checkout", "-q", "-b", SymphonyElixir.GitManager.issue_branch_name(issue)], cd: workspace)

    provider = Path.join(root, "provider")
    File.write!(provider, provider_script())
    File.chmod!(provider, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_command: "'" <> String.replace(provider, "'", "'\\''") <> "' app-server",
      codex_approval_policy: "never",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner"),
      policy_retry_validation_failures_within_run: false,
      policy_max_validation_attempts_per_run: 1,
      policy_require_verifier: true,
      policy_automerge_on_green: false
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    c = %{root: root, workspace: workspace, issue: issue}
    harness!(c, %{})
    assert {:ok, _} = RunStateStore.transition(workspace, "validate", %{issue_id: issue.id, issue_identifier: issue.identifier, issue_source: :tracker})
    on_exit(fn -> File.rm_rf!(root) end)
    c
  end

  for {kind, code, order} <- [
        {"preflight", :preflight_failed, ["preflight"]},
        {"validation", :validation_failed, ["validation"]},
        {"artifacts", :artifacts_failed, ["validation", "artifacts"]},
        {"smoke", :verifier_failed, ["validation", "artifacts", "smoke"]}
      ] do
    @kind kind
    @code code
    @order order
    test "#{kind} failure correlates the physical gate, checked completion and blocked decision", c do
      harness!(c, %{@kind => %{"command" => "printf '#{@kind}\\n' >> .symphony/order; exit 17"}})

      admitted(c.workspace, c.issue, fn execution ->
        result = if @kind == "preflight", do: RunPolicy.enforce_pre_run(c.issue, c.workspace, opts()), else: DeliveryEngine.run(c.workspace, c.issue, nil, opts())

        case result do
          {:stop, %RunPolicy.Violation{code: code}} -> assert code == @code
          {:stop, code} -> assert code == @code
        end

        assert order(c) == @order
        rows = rows(execution.ticket.ledger_path)
        completed = event(rows, @kind <> ".completed")
        stopped = event(rows, "runtime.stopped")
        id = completed["metadata"]["gate_id"]
        assert is_binary(id) and String.starts_with?(id, "gate_")
        assert completed["metadata"]["gate"]["gate_id"] == id
        assert completed["metadata"]["gate"]["exit_code"] == 17
        assert completed["metadata"]["gate"]["status"] == "failed"
        assert completed["metadata"]["run_id"] == execution.ticket.run_id
        assert completed["metadata"]["dispatch_id"] == execution.ticket.dispatch_id
        assert stopped["metadata"]["gate_id"] == id
        assert raw(c)["stop_reason"]["gate_id"] == id
        decision = raw(c)["last_decision"]
        assert (decision["gate_id"] || decision["metadata"]["gate_id"]) == id
        refute Enum.any?(rows, &(&1["event"] == "proof.integrity_verified"))
      end)
    end
  end

  for kind <- ["preflight", "validation", "smoke", "artifacts"] do
    @kind kind
    test "genuine missing #{kind} identifies an unavailable evaluation while preserving the parser cause", c do
      path = Path.join(c.workspace, ".symphony/harness.yml")
      File.write!(path, Jason.encode!(Map.delete(Jason.decode!(File.read!(path)), @kind)))
      assert {:error, {:missing_harness_command, @kind}} = RepoHarness.load(c.workspace)

      admitted(c.workspace, c.issue, fn execution ->
        assert {:stop, %RunPolicy.Violation{code: :missing_harness_command} = violation} = RunPolicy.enforce_pre_run(c.issue, c.workspace, opts())
        assert violation.details =~ @kind <> ".command"
        completed = event(rows(execution.ticket.ledger_path), @kind <> ".completed")
        gate = completed["metadata"]["gate"]
        assert gate["status"] == "unavailable"
        assert gate["exit_code"] == nil
        assert gate["environment"]["executor"] == "not_started"
        assert gate["gate_id"] == violation.metadata.gate_id
        assert raw(c)["stop_reason"]["code"] == "missing_harness_command"
        assert order(c) == []
      end)
    end
  end

  test "a contradictory adapter verdict preserves the actual smoke ID in the blocked decision", c do
    admitted(c.workspace, c.issue, fn execution ->
      runner = fn workspace, issue, state, inspection, opts ->
        # Supported adapter seam supplies a contradictory verdict. The smoke and
        # checked completion are still produced by the actual VerifierRunner.
        contradiction = fn _w, _i, _s, _o ->
          {:ok, %SymphonyElixir.VerifierResult{verdict: :pass, summary: "contradiction", acceptance_gaps: ["missing"], risky_areas: [], evidence: [], raw_output: "pass"}}
        end

        result = SymphonyElixir.VerifierRunner.verify(workspace, issue, state, inspection, Keyword.put(opts, :verifier_session_runner, contradiction))
        assert result.verdict == "blocked"
        result |> Map.put(:verdict, "pass") |> Map.put(:acceptance_gaps, ["missing"])
      end

      assert {:stop, :verifier_blocked} = DeliveryEngine.run(c.workspace, c.issue, nil, Keyword.put(opts(), :verifier_runner, runner))
      rows = rows(execution.ticket.ledger_path)
      smoke = event(rows, "smoke.completed")
      assert raw(c)["stop_reason"]["gate_id"] == smoke["metadata"]["gate_id"]
      assert raw(c)["stop_reason"]["code"] == "verifier_blocked"
      assert raw(c)["stop_reason"]["details"] == "Verifier reported pass with unresolved acceptance gaps."
      refute Enum.any?(rows, &(&1["event"] == "proof.integrity_verified"))
      assert {:stop, {:execution_stopped, _}} = SymphonyElixir.EvidenceAcceptance.current(c.workspace)
      assert order(c) == ["validation", "artifacts", "smoke"]
    end)
  end

  test "malformed harness JSON does not guess a gate or execute any command", c do
    File.write!(Path.join(c.workspace, ".symphony/harness.yml"), "{invalid")

    admitted(c.workspace, c.issue, fn execution ->
      assert {:stop, %RunPolicy.Violation{code: :invalid_harness}} = RunPolicy.enforce_pre_run(c.issue, c.workspace, opts())
      rows = rows(execution.ticket.ledger_path)
      stopped = event(rows, "runtime.stopped")
      refute Map.has_key?(stopped["metadata"], "gate_id")
      refute Enum.any?(rows, &(&1["event"] in ["preflight.completed", "validation.completed", "smoke.completed", "artifacts.completed"]))
      assert order(c) == []
    end)
  end

  test "resumed publish executes a new validation ID instead of adopting last_validation", c do
    harness!(c, %{"artifacts" => %{"command" => "printf 'artifacts\\n' >> .symphony/order; exit 17"}})
    assert {:ok, _} = RunStateStore.transition(c.workspace, "publish", %{last_validation: %{status: "passed", gate_id: "gate_historical"}})

    admitted(c.workspace, c.issue, fn execution ->
      assert {:stop, :artifacts_failed} = DeliveryEngine.run(c.workspace, c.issue, nil, opts())
      assert order(c) == ["validation", "artifacts"]
      rows = rows(execution.ticket.ledger_path)
      validation = event(rows, "validation.completed")
      artifacts = event(rows, "artifacts.completed")
      assert validation["metadata"]["consumer"] == "reverification"
      assert validation["metadata"]["attempt"] == 1
      assert validation["metadata"]["gate_id"] != "gate_historical"
      assert raw(c)["last_validation"]["gate_id"] == validation["metadata"]["gate_id"]
      assert raw(c)["stop_reason"]["gate_id"] == artifacts["metadata"]["gate_id"]
      refute Enum.any?(rows, &(&1["event"] in ["verification.completed", "proof.integrity_verified"]))
    end)
  end

  test "positive legacy preflight has one durable completion without manufacturing a stop", c do
    assert :ok = RunPolicy.enforce_pre_run(c.issue, c.workspace, opts())
    assert {:ok, path} = RunLedger.ledger_file_path_checked()
    rows = rows(path)
    completed = event(rows, "preflight.completed")
    assert completed["metadata"]["gate"]["status"] == "passed"
    assert completed["metadata"]["gate"]["exit_code"] == 0
    assert is_binary(completed["metadata"]["gate_id"])
    refute Enum.any?(rows, &(&1["event"] == "runtime.stopped"))
    assert raw(c)["stage"] == "validate"
    assert order(c) == ["preflight"]
  end

  test "legacy ledger configuration changes after a physical command cannot relocate completion or stop", c do
    harness!(c, %{"preflight" => %{"command" => "printf preflight >> .symphony/order; exit 17"}})
    {:ok, original_path} = RunLedger.ledger_file_path_checked()
    original_log = Application.get_env(:symphony_elixir, :log_file)
    alternate_log = Path.join(c.root, "alternate/runtime.log")

    shell = fn workspace, command, command_opts ->
      result = System.cmd("sh", ["-lc", command], Keyword.put(command_opts, :cd, workspace))
      Application.put_env(:symphony_elixir, :log_file, alternate_log)
      result
    end

    try do
      assert {:stop, %RunPolicy.Violation{code: :preflight_failed}} = RunPolicy.enforce_pre_run(c.issue, c.workspace, Keyword.put(opts(), :shell_runner, shell))
      completed = event(rows(original_path), "preflight.completed")
      stopped = event(rows(original_path), "runtime.stopped")
      assert completed["metadata"]["gate_id"] == stopped["metadata"]["gate_id"]
      assert order(c) == ["preflight"]
      {:ok, alternate_path} = RunLedger.ledger_file_path_checked()

      if File.exists?(alternate_path) do
        refute Enum.any?(rows(alternate_path), &(&1["event"] in ["preflight.completed", "runtime.stopped"]))
      end

      assert alternate_path != original_path
    after
      Application.put_env(:symphony_elixir, :log_file, original_log)
    end
  end

  test "checked IO failure after a physical preflight is visible and does not rerun the command", c do
    {:ok, ledger_path} = RunLedger.ledger_file_path_checked()
    original = File.read!(ledger_path)
    backup = ledger_path <> ".gate-test-backup"

    shell = fn workspace, command, command_opts ->
      result = System.cmd("sh", ["-lc", command], Keyword.put(command_opts, :cd, workspace))
      File.rename!(ledger_path, backup)
      File.mkdir!(ledger_path)
      result
    end

    try do
      error = assert_raise RunLedger.PersistenceError, fn -> RunPolicy.enforce_pre_run(c.issue, c.workspace, Keyword.put(opts(), :shell_runner, shell)) end
      assert error.phase == :preflight
      assert error.reason == :eisdir
      assert error.confirmation == :uncertain
      assert is_binary(error.event_id)
      assert File.dir?(ledger_path)
      assert File.read!(backup) == original
      assert order(c) == ["preflight"]
      assert raw(c)["stage"] == "validate"
    after
      if File.exists?(backup) do
        File.rmdir!(ledger_path)
        File.rename!(backup, ledger_path)
      end
    end
  end

  for mode <- [:admitted, :legacy] do
    @budget_entry_mode mode
    test "#{mode} exhausted validation budget stops before commands or gate IDs", c do
      assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :validation_attempts, 1))

      run = fn ledger_path ->
        assert {:stop, :validation_failed} = DeliveryEngine.run(c.workspace, c.issue, nil, opts())
        assert order(c) == []
        assert raw(c)["validation_attempts"] == 1
        assert raw(c)["verification_attempts"] == 0
        assert raw(c)["stage"] == "blocked"
        assert raw(c)["stop_reason"]["code"] == "validation_failed"
        assert raw(c)["stop_reason"]["details"] == "The existing validation attempt budget is exhausted."
        events = rows(ledger_path)
        stopped = event(events, "runtime.stopped")
        refute Map.has_key?(stopped["metadata"], "gate_id")
        refute Enum.any?(events, &(&1["event"] in ["validation.completed", "artifacts.completed", "smoke.completed", "verification.completed", "proof.integrity_verified", "publish.completed"]))
      end

      case @budget_entry_mode do
        :admitted ->
          admitted(c.workspace, c.issue, fn execution -> run.(execution.ticket.ledger_path) end)

        :legacy ->
          assert {:ok, ledger_path} = RunLedger.ledger_file_path_checked()
          run.(ledger_path)
      end
    end
  end

  defp harness!(c, overrides) do
    harness = %{
      "version" => 1,
      "base_branch" => "main",
      "pull_request" => %{"required_checks" => ["make-all"]},
      "verification" => %{"behavioral_proof" => %{"required" => true, "mode" => "harness_artifact_only", "source_paths" => ["lib"], "test_paths" => ["test"], "artifact_path" => "proof.json"}}
    }

    harness =
      Enum.reduce(["preflight", "validation", "smoke", "post_merge", "artifacts"], harness, fn kind, acc ->
        Map.put(acc, kind, %{"command" => "printf '#{kind}\\n' >> .symphony/order; test -s README.md"})
      end)

    harness = Map.merge(harness, overrides)
    File.write!(Path.join(c.workspace, ".symphony/harness.yml"), Jason.encode!(harness))
    :ok
  end

  # Local bootstrap transport only. Unexpected turns fail explicitly instead
  # of invoking the installed executable or producing a synthetic model verdict.
  defp provider_script do
    """
    #!/bin/sh
    set -eu
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"gate-bootstrap-thread"}}}' ;;
        *'"method":"initialized"'*) : ;;
        *) exit 91 ;;
      esac
    done
    """
  end

  defp opts, do: [include_pr_details: false, github_client: GitHub, verifier_session_runner: fn _, _, _, _ -> flunk("negative gate reached model verifier") end]

  defp rows(path) do
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(path)
    rows
  end

  defp event(rows, name) do
    [event] = Enum.filter(rows, &(&1["event"] == name))
    event
  end

  defp order(c) do
    case File.read(Path.join(c.workspace, ".symphony/order")) do
      {:ok, bytes} -> String.split(bytes, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp raw(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

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
end
