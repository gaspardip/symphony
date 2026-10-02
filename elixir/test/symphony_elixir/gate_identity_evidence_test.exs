defmodule SymphonyElixir.GateIdentityEvidenceTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{AgentExecution, EvidenceAcceptance, RepoHarness, RunInspector, RunLedger, RunStateStore, VerifierRunner}

  setup do
    root = Path.join(System.tmp_dir!(), "evidence-integrity-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "PROOF-1")
    File.mkdir_p!(workspace)
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["config", "user.name", "Evidence Test"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "fixture\n")
    assert {_, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "fixture"], cd: workspace)
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/feature.ex"), "defmodule Feature do\nend\n")
    File.write!(Path.join(workspace, "proof.json"), "{\"criterion\":true}\n")

    issue = %Issue{
      id: "proof-#{System.unique_integer([:positive])}",
      identifier: "PROOF-1",
      title: "Evidence",
      state: "In Progress",
      source: :tracker,
      description: "## Acceptance Criteria\n- fixture criterion"
    }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root, runner_install_root: Path.join(root, "runner"))
    assert {:ok, _} = RunStateStore.transition(workspace, "verify", %{issue_id: issue.id, issue_identifier: issue.identifier, issue_source: :tracker})

    harness = %RepoHarness{
      validation_command: "test -s proof.json",
      smoke_command: "test -s proof.json",
      behavioral_proof: %{required: true, mode: "harness_artifact_only", source_paths: ["lib"], test_paths: ["test"], artifact_path: "proof.json"}
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, inspection: inspection, proof: Path.join(workspace, "proof.json")}
  end

  test "private validation, smoke completion and integrity receipt retain the same physical gate identities", c do
    admitted(c.workspace, c.issue, fn execution ->
      validation = RunInspector.run_validation(c.workspace, c.inspection.harness)
      assert validation.status == :passed
      assert :ok = AgentExecution.observe_validation(c.workspace, validation)
      assert {:ok, observed} = AgentExecution.validation_observation()
      assert observed.gate_id == validation.gate_id
      assert observed.exit_code == 0
      assert %{verdict: "pass"} = result = verify(c)
      assert result.smoke.gate_id != validation.gate_id
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      assert :ok = EvidenceAcceptance.before_effect(c.workspace, handle, :handoff)
      assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [completed] = Enum.filter(rows, &(&1["event"] == "smoke.completed"))
      [receipt] = Enum.filter(rows, &(&1["event"] == "proof.integrity_verified"))
      assert completed["metadata"]["gate_id"] == result.smoke.gate_id
      assert completed["metadata"]["run_id"] == execution.ticket.run_id
      assert completed["metadata"]["dispatch_id"] == execution.ticket.dispatch_id
      gate = receipt["metadata"]["gate"]
      assert gate["validation"]["result"]["gate_id"] == validation.gate_id
      assert gate["smoke"]["gate_id"] == result.smoke.gate_id
      assert gate["smoke"]["exit_code"] == 0
      assert gate["smoke"]["started_at"] == result.smoke.started_at
      assert gate["smoke"]["duration_us"] == result.smoke.duration_us
      assert gate["smoke"]["environment"]["executor"] == "legacy_shell"
    end)
  end

  test "contradictory pass with gaps keeps the real smoke reference but cannot install acceptance", c do
    admitted(c.workspace, c.issue, fn execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))

      runner = fn _w, _i, _s, _o ->
        {:ok, %SymphonyElixir.VerifierResult{verdict: :pass, summary: "contradiction", acceptance_gaps: ["criterion missing"], risky_areas: [], evidence: [], raw_output: "pass"}}
      end

      assert %{verdict: "blocked", integrity_error: :verifier_pass_with_acceptance_gaps} = result = verify(c, verifier_session_runner: runner)
      assert result.smoke.status == :passed
      assert {:error, _} = EvidenceAcceptance.current(c.workspace)
      assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [completed] = Enum.filter(rows, &(&1["event"] == "smoke.completed"))
      assert completed["metadata"]["gate_id"] == result.smoke.gate_id
      refute Enum.any?(rows, &(&1["event"] == "proof.integrity_verified"))
      assert {:error, {:evidence_rejected, :evidence_handle_required}} = SymphonyElixir.GitManager.commit_all(c.workspace, c.issue, "contradiction")
    end)
  end

  test "a later admitted worker must execute new gates instead of adopting the saved gate IDs", c do
    {old_validation, old_smoke, old_dispatch, old_handle} =
      admitted(c.workspace, c.issue, fn execution ->
        validation = RunInspector.run_validation(c.workspace, c.inspection.harness)
        assert :ok = AgentExecution.observe_validation(c.workspace, validation)
        assert %{verdict: "pass"} = result = verify(c)
        assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
        {validation.gate_id, result.smoke.gate_id, execution.ticket.dispatch_id, handle}
      end)

    admitted(c.workspace, c.issue, fn execution ->
      refute execution.ticket.dispatch_id == old_dispatch
      assert {:ok, nil} = AgentExecution.validation_observation()
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.before_effect(c.workspace, old_handle, :publish)
      validation = RunInspector.run_validation(c.workspace, c.inspection.harness)
      assert validation.gate_id != old_validation
      assert :ok = AgentExecution.observe_validation(c.workspace, validation)
      assert %{verdict: "pass"} = result = verify(c)
      assert result.smoke.gate_id != old_smoke
      assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [receipt] = Enum.filter(rows, &(&1["event"] == "proof.integrity_verified" and &1["metadata"]["dispatch_id"] == execution.ticket.dispatch_id))
      assert receipt["metadata"]["gate"]["smoke"]["gate_id"] == result.smoke.gate_id
      assert receipt["metadata"]["gate"]["validation"]["result"]["gate_id"] == validation.gate_id
    end)
  end

  test "changing only a checked receipt gate ID denies handoff and commit even after restoring the ledger", c do
    admitted(c.workspace, c.issue, fn execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      assert %{verdict: "pass"} = verify(c)
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      path = execution.ticket.ledger_path
      original = File.read!(path)
      before = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)
      rows = original |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      altered =
        Enum.map(rows, fn row ->
          if row["event"] == "proof.integrity_verified", do: put_in(row, ["metadata", "gate", "smoke", "gate_id"], "gate_forged_observability"), else: row
        end)

      File.write!(path, Enum.map_join(altered, "\n", &Jason.encode!/1) <> "\n")

      try do
        assert {:error, :evidence_event_changed} = EvidenceAcceptance.before_effect(c.workspace, handle, :handoff)

        assert {:error, {:evidence_rejected, :evidence_event_changed}} =
                 SymphonyElixir.GitManager.commit_all(c.workspace, c.issue, "denied", evidence_handle: handle)

        assert System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace) == before
      after
        File.write!(path, original)
      end

      assert {:error, :evidence_event_changed} = EvidenceAcceptance.before_effect(c.workspace, handle, :handoff)
    end)
  end

  test "ledger drift during physical smoke stops the admitted worker before durable completion or proof", c do
    original_log = Application.get_env(:symphony_elixir, :log_file)
    alternate_log = Path.join(c.root, "alternate/runtime.log")

    admitted(c.workspace, c.issue, fn execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      before = File.read!(execution.ticket.ledger_path)
      ids = %{run_id: execution.ticket.run_id, dispatch_id: execution.ticket.dispatch_id}
      ref = make_ref()

      shell = fn workspace, command, opts ->
        actual = System.cmd("sh", ["-lc", command], Keyword.put(opts, :cd, workspace))
        send(self(), {:physical_smoke, ref, command, actual})
        Application.put_env(:symphony_elixir, :log_file, alternate_log)
        actual
      end

      try do
        assert {:stop, {:stale_execution, ^ids, :dispatch_audit_ledger_changed}} = terminal = verify(c, shell_runner: shell)
        assert_received {:physical_smoke, ^ref, command, {_output, 0}}
        assert command == c.inspection.harness.smoke_command
        refute_received {:physical_smoke, ^ref, _, _}
        assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
        refute Enum.any?(rows, &(&1["event"] in ["smoke.completed", "proof.integrity_verified"]))
        assert File.read!(execution.ticket.ledger_path) == before
        assert EvidenceAcceptance.current(c.workspace) == terminal
        assert {:ok, alternate_path} = RunLedger.ledger_file_path_checked()
        assert alternate_path != execution.ticket.ledger_path
        refute File.exists?(alternate_path)

        # Restoring configuration cannot erase retained loss of authority.
        Application.put_env(:symphony_elixir, :log_file, original_log)
        assert EvidenceAcceptance.current(c.workspace) == terminal
        assert AgentExecution.entry_context(c.workspace, c.issue) == terminal
        assert File.read!(execution.ticket.ledger_path) == before
      after
        Application.put_env(:symphony_elixir, :log_file, original_log)
      end
    end)
  end

  test "historical completion and fabricated IDs do not install a current acceptance", c do
    {:ok, event} = RunLedger.record_checked("validation.completed", %{issue_id: c.issue.id, metadata: %{status: "passed"}})
    assert {:ok, path} = RunLedger.ledger_file_path_checked()
    before = File.read!(path)
    assert {:ok, row} = RunLedger.CheckedStorage.fetch(path, event.event_id)
    refute Map.has_key?(row["metadata"], "gate_id")
    assert File.read!(path) == before
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :last_validation, %{status: "passed", gate_id: "gate_caller"}))

    admitted(c.workspace, c.issue, fn _execution ->
      assert {:ok, nil} = AgentExecution.validation_observation()
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
      assert {:error, {:evidence_rejected, :evidence_handle_required}} = SymphonyElixir.GitManager.commit_all(c.workspace, c.issue, "not accepted")
    end)
  end

  test "a passing digest does not turn a physical failed smoke into an accepted gate", c do
    admitted(c.workspace, c.issue, fn execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      c = %{c | inspection: %{c.inspection | harness: %{c.inspection.harness | smoke_command: "printf smoke-failed; exit 17"}}}
      assert %{verdict: "needs_more_work", smoke: smoke} = verify(c, verifier_session_runner: fn _, _, _, _ -> flunk("failed smoke reached verifier") end)
      assert smoke.exit_code == 17
      assert smoke.status == :failed
      assert is_binary(smoke.gate_id)
      assert {:error, _} = EvidenceAcceptance.current(c.workspace)
      assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      refute Enum.any?(rows, &(&1["event"] == "proof.integrity_verified"))
      [completed] = Enum.filter(rows, &(&1["event"] == "smoke.completed"))
      assert completed["metadata"]["gate_id"] == smoke.gate_id
    end)
  end

  defp verify(c, extra \\ []) do
    VerifierRunner.verify(c.workspace, c.issue, %{}, c.inspection, Keyword.merge([include_pr_details: false, verifier_session_runner: &verifier_pass/4], extra))
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
end
