defmodule SymphonyElixir.EvidenceIntegrityTest do
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

  test "actual gate and model observation produce one checked dispatch-bound receipt", c do
    admitted(c.workspace, c.issue, fn execution ->
      assert %{status: :passed} = validation = RunInspector.run_validation(c.workspace, c.inspection.harness)
      assert :ok = AgentExecution.observe_validation(c.workspace, validation)
      assert %{verdict: "pass"} = verify(c)
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      assert :ok = EvidenceAcceptance.before_effect(c.workspace, handle, :publish)
      assert {:ok, entries, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [receipt] = Enum.filter(entries, &(&1["event"] == "proof.integrity_verified"))
      assert receipt["metadata"]["dispatch_id"] == execution.ticket.dispatch_id
      assert receipt["metadata"]["run_id"] == execution.ticket.run_id

      assert receipt["metadata"]["files"] == [
               %{"path" => "proof.json", "size" => byte_size(File.read!(c.proof)), "sha256" => :crypto.hash(:sha256, File.read!(c.proof)) |> Base.encode16(case: :lower)}
             ]

      assert receipt["metadata"]["gate"]["smoke"]["status"] == "passed"
      assert {:error, :evidence_observation_not_current} = EvidenceAcceptance.accept(handle, %{verdict: "pass", acceptance_gaps: [], verification_mode: :agent})
      assert {:ok, ^entries, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
    end)
  end

  test "already-modified proof bytes changed by the verifier are denied", c do
    admitted(c.workspace, c.issue, fn execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))

      runner = fn w, i, s, opts ->
        [observed] = Enum.filter(Keyword.fetch!(opts, :verification_context).content_evidence, &(&1.path == "proof.json"))
        assert observed.excerpt =~ "criterion"
        File.write!(c.proof, "{\"criterion\":false}\n")
        verifier_pass(w, i, s, opts)
      end

      assert %{verdict: "blocked", reason_code: "evidence_integrity_failed"} = verify(c, verifier_session_runner: runner)
      assert {:error, :evidence_changed} = EvidenceAcceptance.current(c.workspace)
      assert {:ok, entries, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      refute Enum.any?(entries, &(&1["event"] == "proof.integrity_verified"))
    end)
  end

  for fault <- [:missing, :symlink, :oversized] do
    @fault fault
    test "#{fault} selected proof cannot authorize an effect", c do
      admitted(c.workspace, c.issue, fn _execution ->
        assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))

        case @fault do
          :missing ->
            File.rm!(c.proof)

          :symlink ->
            File.rm!(c.proof)
            File.ln_s!(Path.join(c.workspace, "README.md"), c.proof)

          :oversized ->
            File.write!(c.proof, String.duplicate("x", 1_048_577))
        end

        result = verify(c)
        refute result.verdict == "pass"
        assert {:error, _} = EvidenceAcceptance.current(c.workspace)
      end)
    end
  end

  test "pass with gaps is not accepted despite a passing physical gate", c do
    admitted(c.workspace, c.issue, fn execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))

      runner = fn _w, _i, _s, _o ->
        {:ok, %SymphonyElixir.VerifierResult{verdict: :pass, summary: "contradiction", acceptance_gaps: ["criterion missing"], risky_areas: [], evidence: [], raw_output: "pass"}}
      end

      assert %{verdict: "blocked"} = verify(c, verifier_session_runner: runner)
      assert {:ok, entries, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      refute Enum.any?(entries, &(&1["event"] == "proof.integrity_verified"))
    end)
  end

  test "deletion after acceptance is sticky even after restoring the original bytes", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      assert %{verdict: "pass"} = verify(c)
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      original = File.read!(c.proof)
      File.rm!(c.proof)
      assert {:error, {:evidence_read_failed, :enoent}} = EvidenceAcceptance.before_effect(c.workspace, handle, :commit)
      File.write!(c.proof, original)
      assert {:error, {:evidence_read_failed, :enoent}} = EvidenceAcceptance.before_effect(c.workspace, handle, :commit)
    end)
  end

  test "ledger is captured from admission and a receipt cannot be adopted by a later dispatch", c do
    original_log = Application.get_env(:symphony_elixir, :log_file)
    alternate = Path.join(c.root, "other/runtime.log")

    first =
      admitted(c.workspace, c.issue, fn execution ->
        assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))

        try do
          assert %{verdict: "pass"} = verify(c)
          assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
          Application.put_env(:symphony_elixir, :log_file, alternate)
          assert {:error, :run_identity_ledger_changed} = SymphonyElixir.DispatchAudit.ensure_workspace_access(c.workspace)
          assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
          assert Enum.any?(rows, &(&1["event"] == "proof.integrity_verified"))
          {handle, execution.ticket.dispatch_id}
        after
          if is_nil(original_log), do: Application.delete_env(:symphony_elixir, :log_file), else: Application.put_env(:symphony_elixir, :log_file, original_log)
        end
      end)

    admitted(c.workspace, c.issue, fn execution ->
      assert execution.ticket.dispatch_id != elem(first, 1)
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.before_effect(c.workspace, elem(first, 0), :publish)
    end)
  end

  test "checked selection failure remains visible and never starts the verifier", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))

      runner = fn
        "git", ["status", "--porcelain", "--untracked-files=all"], _ -> {"private-selection-error", 17}
        _command, _args, _opts -> flunk("selection failure reached another command")
      end

      result = verify(c, command_runner: runner, verifier_session_runner: fn _, _, _, _ -> flunk("selection failure reached verifier") end)
      assert result.verdict == "blocked"
      assert result.integrity_error == {:evidence_file_selection_failed, 17}
      refute result.summary =~ "private-selection-error"
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
    end)
  end

  test "policy-disabled validation and model are explicit, while smoke remains real", c do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: c.root,
      runner_install_root: Path.join(c.root, "runner"),
      policy_require_validation: false,
      policy_require_verifier: false
    )

    admitted(c.workspace, c.issue, fn execution ->
      assert {:ok, nil} = AgentExecution.validation_observation()

      assert %{verdict: "pass", raw_output: nil} =
               VerifierRunner.verify_without_agent(c.workspace, c.issue, %{}, c.inspection, include_pr_details: false, verifier_session_runner: fn _, _, _, _ -> flunk("disabled model ran") end)

      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      assert :ok = EvidenceAcceptance.before_effect(c.workspace, handle, :publish)
      assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [receipt] = Enum.filter(rows, &(&1["event"] == "proof.integrity_verified"))
      assert receipt["metadata"]["verification"] == %{"mode" => "policy_disabled", "verdict" => "pass", "acceptance_gaps" => []}
      assert receipt["metadata"]["gate"]["validation"] == %{"required" => false, "observed" => false}
      assert receipt["metadata"]["gate"]["smoke"]["status"] == "passed"
    end)
  end

  test "a caller cannot select gate-only verification while policy requires a model", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert %{verdict: "blocked", integrity_error: :evidence_verifier_required} =
               VerifierRunner.verify_without_agent(c.workspace, c.issue, %{}, c.inspection)

      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
    end)
  end

  test "an altered receipt never becomes permission again after ledger restoration", c do
    admitted(c.workspace, c.issue, fn execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      assert %{verdict: "pass"} = verify(c)
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      path = execution.ticket.ledger_path
      original = File.read!(path)
      rows = original |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      altered =
        Enum.map(rows, fn row ->
          if row["event"] == "proof.integrity_verified", do: put_in(row, ["metadata", "integrity_only"], false), else: row
        end)

      File.write!(path, Enum.map_join(altered, "\n", &Jason.encode!/1) <> "\n")

      try do
        assert {:error, :evidence_event_changed} = EvidenceAcceptance.before_effect(c.workspace, handle, :push)
      after
        File.write!(path, original)
      end

      assert {:error, :evidence_event_changed} = EvidenceAcceptance.before_effect(c.workspace, handle, :push)
      assert File.read!(path) == original
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
