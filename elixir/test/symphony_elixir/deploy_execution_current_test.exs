defmodule SymphonyElixir.DeployExecutionCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DeployAudit, DispatchAudit, LeaseManager, RunLedger, RunStateStore}

  setup context do
    root = Path.join(System.tmp_dir!(), "deploy-current-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "DEPLOY-CURRENT")
    issue = %{id: "deploy-current-#{System.unique_integer([:positive])}", identifier: "DEPLOY-CURRENT"}
    stage = context[:deploy_stage] || "deploy_preview"
    assert {:ok, _} = RunStateStore.transition(workspace, stage, %{issue_id: issue.id, issue_identifier: issue.identifier})
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "deploy-current-owner")
    assert {:ok, source, _view} = RunStateStore.read_admission_source(workspace, issue)

    assert {:ok, dispatch, raw} =
             DispatchAudit.begin(workspace, %{issue_id: issue.id, issue_identifier: issue.identifier, stage: stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}, source)

    authority = %{ticket: dispatch, lease_token: acquired.token}
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      workspace: workspace,
      issue: issue,
      authority: authority,
      expected: RunStateStore.material_projection(raw),
      attrs: %{issue_id: issue.id, issue_identifier: issue.identifier, stage: stage, command: "controlled-command"},
      result: %{status: :passed, command: "controlled-command", output: "one observed effect"}
    }
  end

  for {stage, destination} <- [{"deploy_preview", "post_deploy_verify"}, {"deploy_production", "done"}] do
    @tag deploy_stage: stage, destination: destination
    test "v2 #{stage} owns exactly one continuation to #{destination}", c do
      ticket = begin!(c)
      marker = marker!(c)
      assert marker["version"] == 2
      assert marker["execution"]["dispatch_ticket"] == json(c.authority.ticket)
      assert marker["execution"]["lease_token"] == json(c.authority.lease_token)
      assert marker["execution"]["expected"] == c.expected
      assert marker["execution"]["provenance"] == json(provenance(c))
      assert {:ok, %{authority: :current, persistence: :confirmed, command_status: "passed"} = receipt} = DeployAudit.record_result(ticket, c.result)
      assert receipt.result_event_id == marker!(c)["result"]["event_id"]
      assert :ok = RunStateStore.ensure_deploy_current(ticket)
      assert {:ok, state, continuation} = RunStateStore.transition_deploy(ticket, c.destination, %{}, precondition(c))
      assert continuation == %{version: 2, stage: c.destination, event: checked!(state.last_ledger_event_id), previous: c.expected, next: RunStateStore.material_projection(state)}
      assert continuation.event["metadata"]["execution"] == json(provenance(c))
      refute Map.has_key?(state, :last_agent_session)
      assert {:error, :deploy_audit_continuation_already_anchored} = DeployAudit.anchor_continuation_locked(ticket, continuation)
      assert :ok = DeployAudit.assert_continuation_locked(ticket, continuation)
      if c.destination == "done", do: assert({:error, {:stale_execution, _}} = RunStateStore.ensure_current(c.authority, continuation.next))
      assert :ok = DeployAudit.finish(ticket, continuation)
      assert :ok = DeployAudit.ensure_available(c.workspace)
      assert {:ok, :none} = DeployAudit.inspect_pending(c.workspace)
      assert {:error, :deploy_audit_ticket_mismatch} = DeployAudit.finish(ticket, continuation)
      assert Enum.map(deploy_rows(c), & &1["event_type"]) == ["deploy.#{marker["target"]}.requested", "deploy.#{marker["target"]}.observed"]
      assert raw!(c)["stage"] == c.destination
    end
  end

  for mutation <- [:run, :dispatch, :expected, :generation, :path] do
    @tag mutation: mutation
    test "begin rejects captured #{mutation} mismatch without reservation or writes", c do
      execution = execution(c)

      altered =
        case c.mutation do
          :run -> put_in(execution, [:authority, :ticket, :run_id], "foreign-run")
          :dispatch -> put_in(execution, [:authority, :ticket, :dispatch_id], "foreign-dispatch")
          :expected -> put_in(execution, [:expected, "review_claims"], %{"C1" => "foreign"})
          :generation -> put_in(execution, [:authority, :lease_token, :lease_generation], "foreign-generation")
          :path -> put_in(execution, [:authority, :lease_token, :storage, :lease_path], Path.join(c.root, "foreign-lease.json"))
        end

      before = evidence(c)
      assert {:error, _reason} = DeployAudit.begin(c.workspace, c.attrs, altered)
      assert evidence(c) == before
      assert :ok = DeployAudit.ensure_available(c.workspace)
      assert deploy_rows(c) == []
    end
  end

  test "capture A cannot begin against a real same-owner same-epoch successor B", c do
    captured = c.authority.lease_token
    assert {:ok, :released} = LeaseManager.release_token(captured)
    assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, captured.owner)
    assert successor.token.owner == captured.owner
    assert successor.token.epoch == captured.epoch
    assert successor.token.storage == captured.storage
    refute successor.token.lease_generation == captured.lease_generation
    before = evidence(c)
    assert {:error, {:stale_execution, :lease_token_mismatch}} = DeployAudit.begin(c.workspace, c.attrs, execution(c))
    assert evidence(c) == before
    assert {:ok, physical} = LeaseManager.read_at(successor.token.storage)
    assert physical == successor.lease
    assert :ok = DeployAudit.ensure_available(c.workspace)
    assert deploy_rows(c) == []
  end

  for mutation <- [:operation, :run, :dispatch, :token, :ref, :version, :execution] do
    @tag mutation: mutation
    test "mutated live ticket #{mutation} cannot observe, continue or finish", c do
      ticket = begin!(c)

      altered =
        case c.mutation do
          :operation -> %{ticket | operation_id: "foreign"}
          :run -> put_in(ticket, [:execution, :authority, :ticket, :run_id], "foreign")
          :dispatch -> put_in(ticket, [:execution, :authority, :ticket, :dispatch_id], "foreign")
          :token -> put_in(ticket, [:execution, :authority, :lease_token, :lease_generation], "foreign")
          :ref -> %{ticket | live_ref: make_ref()}
          :version -> %{ticket | version: 99}
          :execution -> Map.delete(ticket, :execution)
        end

      before = evidence(c)
      assert {:error, _} = DeployAudit.record_result(altered, c.result)
      assert {:error, _} = DeployAudit.continuation_context(altered)
      assert {:error, _} = RunStateStore.transition_deploy(altered, "done", %{}, precondition(c))
      assert {:error, _} = DeployAudit.finish(altered, %{version: 2, stage: "done", event: %{}, previous: c.expected, next: %{}})
      assert evidence(c) == before
      assert marker!(c)["status"] == "authorized"
      assert {:ok, %{authority: :current, persistence: :confirmed}} = DeployAudit.record_result(ticket, c.result)
    end
  end

  test "another process and an unregistered reconstructed ticket cannot import custody", c do
    ticket = begin!(c)
    before = evidence(c)
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:foreign, DeployAudit.record_result(ticket, c.result), DeployAudit.record_result(%{ticket | owner_pid: self()}, c.result)})
      end)

    assert_receive {:foreign, {:error, :deploy_audit_wrong_owner}, {:error, :deploy_audit_ticket_mismatch}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert evidence(c) == before
  end

  test "owner death leaves a checked pending marker without importing the dead ticket", c do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:owned, begin!(c)}) end)
    assert_receive {:owned, ticket}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    before = evidence(c)
    assert {:error, :deploy_audit_ticket_mismatch} = DeployAudit.record_result(%{ticket | owner_pid: self()}, c.result)
    assert {:ok, %{status: "authorized", chain: :confirmed}} = DeployAudit.inspect_pending(c.workspace)
    assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(c.workspace)
    assert evidence(c) == before
  end

  for {version, execution} <- [{99, :keep}, {1, :keep}, {2, :remove}] do
    @tag marker_version: version, marker_execution: execution
    test "marker version #{version} with execution #{execution} cannot downgrade or import", c do
      ticket = begin!(c)
      marker = Map.put(marker!(c), "version", c.marker_version)
      marker = if c.marker_execution == :remove, do: Map.delete(marker, "execution"), else: marker
      File.write!(marker_path(c), Jason.encode!(marker))
      before = evidence(c)
      assert {:error, _} = DeployAudit.record_result(ticket, c.result)
      assert {:error, {:deploy_diagnostic_unconfirmed, _}} = DeployAudit.inspect_pending(c.workspace)
      assert evidence(c) == before
    end
  end

  test "legacy entry and arity cannot downgrade an identified dispatch", c do
    before = evidence(c)
    assert {:error, :deploy_audit_execution_context_required} = DeployAudit.begin(c.workspace, c.attrs)
    assert evidence(c) == before
    ticket = begin!(c)
    assert {:ok, _} = DeployAudit.record_result(ticket, c.result)
    before = evidence(c)
    assert {:error, :invalid_deploy_transition} = RunStateStore.transition_deploy(ticket, "done", %{})
    assert evidence(c) == before
  end

  for change <- [:material, :generation, :snapshot] do
    @tag change: change
    test "observation retains original result after #{change} authority loss", c do
      ticket = begin!(c)

      case c.change do
        :material ->
          assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :review_threads, %{"T1" => %{status: "control"}}))

        :generation ->
          lease = c.authority.lease_token.storage.lease_path
          File.write!(lease, Jason.encode!(Map.put(Jason.decode!(File.read!(lease)), "lease_generation", "successor-generation")))

        :snapshot ->
          File.rename!(RunStateStore.state_path(c.workspace), Path.join(c.root, "snapshot-retained"))
          File.mkdir!(RunStateStore.state_path(c.workspace))
      end

      controlled = Map.take(evidence(c), [:snapshot, :lease, :dispatch])
      assert {:ok, %{authority: {:rejected, {:stale_execution, reason}}, persistence: :confirmed} = receipt} = DeployAudit.record_result(ticket, c.result)
      assert reason == %{material: :material_state_changed, generation: :lease_token_mismatch, snapshot: :eisdir}[c.change]
      marker = marker!(c)
      assert marker["status"] == "result_confirmed"
      assert marker["result"]["metadata"]["result"] == json(c.result)
      assert marker["continuation_denied"]["kind"] == "stale_execution"
      assert marker["execution"]["dispatch_ticket"] == json(c.authority.ticket)
      assert checked!(receipt.result_event_id) == marker["result"]
      after_observation = evidence(c)
      assert Map.take(after_observation, [:snapshot, :lease, :dispatch]) == controlled
      assert {:error, {:stale_execution, ^reason}} = DeployAudit.continuation_context(ticket)
      assert {:error, {:stale_execution, ^reason}} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
      assert evidence(c) == after_observation
      assert length(deploy_rows(c)) == 2
    end
  end

  test "an explicit owner denial remains primary although material is still current", c do
    ticket = begin!(c)
    terminal = {:stop, {:execution_stopped, %{reason: :operator_stop}}}
    assert {:ok, _} = RunStateStore.ensure_current(c.authority, c.expected)
    assert {:ok, %{authority: {:rejected, ^terminal}, persistence: :confirmed}} = DeployAudit.record_result(ticket, c.result, {:denied, terminal})
    assert {:ok, _} = RunStateStore.ensure_current(c.authority, c.expected)
    assert {:error, ^terminal} = DeployAudit.continuation_context(ticket)
    assert marker!(c)["continuation_denied"] == %{"phase" => "record_result", "kind" => "execution_stopped", "reason_tag" => "owner_stop"}
  end

  test "broken ledger retains result_pending and denial without rewriting the broken ledger", c do
    ticket = begin!(c)
    File.write!(c.authority.ticket.ledger_path, "{broken")
    assert {:ok, %{authority: {:rejected, {:stale_execution, _}}, persistence: {:marker_only, %RunLedger.PersistenceError{}}} = receipt} = DeployAudit.record_result(ticket, c.result)
    assert File.read!(c.authority.ticket.ledger_path) == "{broken"
    assert marker!(c)["status"] == "result_pending"
    assert marker!(c)["result"]["event_id"] == receipt.result_event_id
    assert marker!(c)["result"]["metadata"]["result"] == json(c.result)
    assert {:error, {:deploy_diagnostic_unconfirmed, _}} = DeployAudit.inspect_pending(c.workspace)
    before = evidence(c)
    assert {:error, {:deploy_audit_observation_already_attempted, %{phase: :settled, receipt: ^receipt}}} = DeployAudit.record_result(ticket, c.result)
    assert evidence(c) == before
  end

  for status <- [:failed, :timeout] do
    @tag result_status: status
    test "#{status} is one observed result and never authorizes continuation", c do
      ticket = begin!(c)
      result = %{c.result | status: c.result_status}
      assert {:ok, %{authority: :current, persistence: :confirmed} = receipt} = DeployAudit.record_result(ticket, result)
      assert receipt.command_status == Atom.to_string(c.result_status)
      assert {:error, {:deploy_audit_result_uncertain, status}} = DeployAudit.continuation_context(ticket)
      assert status == receipt.command_status
      before = evidence(c)
      assert {:error, {:deploy_audit_observation_already_attempted, %{receipt: ^receipt}}} = DeployAudit.record_result(ticket, c.result)
      assert evidence(c) == before
    end
  end

  test "invalid command digest does not consume the authentic observation", c do
    ticket = begin!(c)
    before = evidence(c)
    assert {:error, :invalid_deploy_audit_result} = DeployAudit.record_result(ticket, %{c.result | command: "different"})
    assert evidence(c) == before
    assert {:ok, %{persistence: :confirmed}} = DeployAudit.record_result(ticket, c.result)
  end

  test "an encoding exception retains the prepared event identity and never permits another attempt", c do
    ticket = begin!(c)
    before = evidence(c)
    assert_raise Jason.EncodeError, fn -> DeployAudit.record_result(ticket, %{c.result | output: <<255>>}) end
    assert {:error, {:deploy_audit_observation_already_attempted, %{phase: :recording, receipt: receipt}}} = DeployAudit.record_result(ticket, c.result)
    assert is_binary(receipt.result_event_id)
    assert receipt.persistence == :not_attempted

    assert [] ==
             trace_writers(fn ->
               assert {:error, {:deploy_audit_observation_already_attempted, %{phase: :recording, receipt: ^receipt}}} = DeployAudit.record_result(ticket, c.result, :current)
             end)

    assert evidence(c) == before
  end

  for persistence <- [:unconfirmed, :marker_only, :confirmed] do
    @tag persistence: persistence
    test "#{persistence} observation cannot prepare or write again after obstruction is removed", c do
      ticket = begin!(c)
      directory = DeployAudit.marker_directory(c.workspace)
      authorized = File.read!(marker_path(c))
      ledger_before = File.read!(c.authority.ticket.ledger_path)

      case c.persistence do
        :unconfirmed -> File.chmod!(directory, 0o500)
        :marker_only -> File.write!(c.authority.ticket.ledger_path, "{broken")
        :confirmed -> :ok
      end

      receipt =
        try do
          assert {:ok, receipt} = DeployAudit.record_result(ticket, c.result)
          receipt
        after
          File.chmod!(directory, 0o700)
        end

      case c.persistence do
        :unconfirmed ->
          assert {:unconfirmed, {:deploy_audit_marker_write_failed, :eacces}} = receipt.persistence
          assert File.read!(marker_path(c)) == authorized

        :marker_only ->
          assert {:marker_only, %RunLedger.PersistenceError{}} = receipt.persistence
          File.write!(c.authority.ticket.ledger_path, ledger_before)

        :confirmed ->
          assert receipt.persistence == :confirmed
      end

      assert is_binary(receipt.result_event_id)
      before = evidence(c)

      assert [] ==
               trace_writers(fn ->
                 for result <- [c.result, %{c.result | output: "replacement"}] do
                   assert {:error, {:deploy_audit_observation_already_attempted, %{phase: :settled, receipt: ^receipt}}} = DeployAudit.record_result(ticket, result)
                   assert {:error, {:deploy_audit_observation_already_attempted, %{phase: :settled, receipt: ^receipt}}} = DeployAudit.record_result(ticket, result, :current)
                 end
               end)

      assert evidence(c) == before
      assert Enum.count(deploy_rows(c), &String.ends_with?(&1["event_type"], ".observed")) == if(c.persistence == :confirmed, do: 1, else: 0)
    end
  end

  for boundary <- [:context, :cas] do
    @tag boundary: boundary
    test "#{boundary} retains a material rejection even after original bytes are restored", c do
      ticket = begin!(c)
      assert {:ok, _} = DeployAudit.record_result(ticket, c.result)
      original = File.read!(RunStateStore.state_path(c.workspace))
      assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :review_claims, %{"C1" => "control"}))
      rejected = if c.boundary == :context, do: DeployAudit.continuation_context(ticket), else: RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
      assert rejected == {:error, {:stale_execution, :material_state_changed}}
      File.write!(RunStateStore.state_path(c.workspace), original)
      before = evidence(c)
      assert {:error, {:stale_execution, :material_state_changed}} = DeployAudit.continuation_context(ticket)
      assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
      assert evidence(c) == before
    end
  end

  for boundary <- [:context, :cas], corruption <- [:ledger, :marker] do
    @tag rejected_boundary: boundary, corrupted_evidence: corruption
    test "#{boundary} retains a checked #{corruption} error after the original bytes return", c do
      ticket = begin!(c)
      assert {:ok, %{persistence: :confirmed}} = DeployAudit.record_result(ticket, c.result)
      path = if c.corrupted_evidence == :ledger, do: c.authority.ticket.ledger_path, else: marker_path(c)
      original = File.read!(path)
      File.write!(path, "{broken")
      rejected = if c.rejected_boundary == :context, do: DeployAudit.continuation_context(ticket), else: RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
      assert {:error, reason} = rejected

      case c.corrupted_evidence do
        :ledger -> assert %RunLedger.PersistenceError{} = reason
        :marker -> assert {:deploy_audit_marker_unreadable, %Jason.DecodeError{}} = reason
      end

      File.write!(path, original)
      before = evidence(c)
      assert {:error, ^reason} = DeployAudit.continuation_context(ticket)
      assert {:error, ^reason} = RunStateStore.ensure_deploy_current(ticket)
      assert {:error, ^reason} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
      assert evidence(c) == before
      assert marker!(c)["status"] == "result_confirmed"
    end
  end

  test "a premature context request and invalid attrs do not poison a real operation", c do
    ticket = begin!(c)
    assert {:error, :deploy_audit_result_unconfirmed} = DeployAudit.continuation_context(ticket)
    assert {:ok, %{authority: :current, persistence: :confirmed}} = DeployAudit.record_result(ticket, c.result)
    before = evidence(c)
    assert {:error, :invalid_deploy_transition_attrs} = RunStateStore.transition_deploy(ticket, "done", %{run_id: "forged"}, precondition(c))
    assert evidence(c) == before
    assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
    assert :ok = DeployAudit.finish(ticket, continuation)
  end

  test "accepted usage and same-token refresh survive a deploy CAS", c do
    ticket = begin!(c)
    assert {:ok, _} = DeployAudit.record_result(ticket, c.result)
    usage = %{input_tokens: 125, output_tokens: 25, total_tokens: 150}
    assert {:ok, _} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage, c.authority, c.expected)
    assert {:ok, lease} = LeaseManager.refresh_token(c.authority.lease_token)
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(lease))
    assert {:ok, state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
    assert state.token_usage == usage
    assert state.lease_updated_at == lease["updated_at"]
    assert state.lease_generation == c.authority.lease_token.lease_generation
    assert :ok = DeployAudit.finish(ticket, continuation)
  end

  test "a reconstructed next equal to controlled snapshot cannot replace the actual CAS receipt", c do
    ticket = begin!(c)
    assert {:ok, _} = DeployAudit.record_result(ticket, c.result)
    assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
    assert {:ok, controlled} = RunStateStore.update(c.workspace, &Map.put(&1, :review_threads, %{"T1" => "later"}))
    forged = %{continuation | next: RunStateStore.material_projection(controlled)}
    before = evidence(c)
    assert {:error, :deploy_audit_continuation_mismatch} = DeployAudit.finish(ticket, forged)
    assert {:error, :deploy_audit_continuation_mismatch} = RunStateStore.confirm_deploy_continuation_locked(ticket, c.authority, forged)
    assert evidence(c) == before
    assert {:error, {:stale_execution, :material_state_changed}} = DeployAudit.finish(ticket, continuation)
    assert evidence(c) == before
  end

  test "an altered continuation row cannot close the exact anchored receipt", c do
    ticket = begin!(c)
    assert {:ok, _} = DeployAudit.record_result(ticket, c.result)
    assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
    rows = rows(c) |> Enum.map(fn row -> if row["event_id"] == continuation.event["event_id"], do: Map.put(row, "summary", "altered"), else: row end)
    File.write!(c.authority.ticket.ledger_path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
    before = evidence(c)
    assert {:error, :deploy_audit_continuation_mismatch} = DeployAudit.finish(ticket, continuation)
    assert evidence(c) == before
  end

  test "a checked event for another operation at the same destination cannot replace the receipt", c do
    ticket = begin!(c)
    assert {:ok, _} = DeployAudit.record_result(ticket, c.result)
    assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
    assert {:ok, other} = RunStateStore.transition(Path.join(c.root, "OTHER"), "done", %{issue_id: "other", issue_identifier: "OTHER"})
    forged = %{continuation | event: checked!(other.last_ledger_event_id)}
    assert forged.event["stage"] == continuation.stage
    before = evidence(c)
    assert {:error, :deploy_audit_continuation_mismatch} = DeployAudit.finish(ticket, forged)
    assert evidence(c) == before
    assert :ok = DeployAudit.finish(ticket, continuation)
  end

  for obstruction <- [:extra_file, :symlink] do
    @tag obstruction: obstruction
    test "v2 finish preserves #{obstruction} evidence", c do
      ticket = begin!(c)
      assert {:ok, _} = DeployAudit.record_result(ticket, c.result)
      assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))

      case c.obstruction do
        :extra_file ->
          File.write!(Path.join(DeployAudit.marker_directory(c.workspace), "retained"), "evidence")

        :symlink ->
          File.rename!(marker_path(c), marker_path(c) <> ".retained")
          File.ln_s!(marker_path(c) <> ".retained", marker_path(c))
      end

      before = evidence(c)
      assert {:error, reason} = DeployAudit.finish(ticket, continuation)
      assert reason == if(c.obstruction == :extra_file, do: :deploy_audit_unexpected_files, else: :invalid_deploy_audit_marker_type)
      assert evidence(c) == before
      assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(c.workspace)
    end
  end

  test "checked session provenance and last session share the actual confirmation and digest", c do
    session = %{provider: "app_server", kind: "thread", id: "confirmed-thread", invocation: 1}
    provenance = %{provenance(c) | agent_session: session}
    assert {:ok, state} = RunStateStore.transition_current(c.authority, c.expected, "validate", %{}, provenance)
    event = checked!(state.last_ledger_event_id)
    assert event["metadata"]["execution"] == json(provenance)
    assert state.last_agent_session == %{version: 1, event_id: event["event_id"], run_id: c.authority.ticket.run_id, dispatch_id: c.authority.ticket.dispatch_id, agent_session: session}
    request = Enum.find(rows(c), &(&1["event_type"] == "stage.transition.requested" and &1["metadata"]["operation_id"] == event["metadata"]["operation_id"]))
    assert request["metadata"]["execution"] == json(provenance)
    assert request["metadata"]["snapshot_digest"] == event["metadata"]["snapshot_digest"]
    assert event["metadata"]["snapshot_digest"] == RunStateStore.snapshot_digest(%{state | last_ledger_event_id: c.expected["last_ledger_event_id"]})
    expected = RunStateStore.material_projection(state)
    assert {:ok, passive} = RunStateStore.transition_current(c.authority, expected, "deploy_preview", %{})
    passive_event = checked!(passive.last_ledger_event_id)
    assert passive_event["metadata"]["execution"]["agent_session"] == nil
    assert passive_event["metadata"]["execution"]["prior_agent_session"] == json(Map.drop(state.last_agent_session, [:version]))
    assert passive.last_agent_session == state.last_agent_session
  end

  test "same-stage session metadata cannot manufacture a last session or another transition", c do
    before = rows(c)
    provenance = %{provenance(c) | agent_session: %{provider: "claude_cli", kind: "session", id: "session", invocation: 1}}
    assert {:ok, state} = RunStateStore.transition_current(c.authority, c.expected, c.attrs.stage, %{last_decision_summary: "same stage"}, provenance)
    refute Map.has_key?(state, :last_agent_session)
    assert rows(c) == before
  end

  test "forged provenance and public last-session attrs fail before any intent", c do
    before = evidence(c)
    assert {:error, :execution_provenance_mismatch} = RunStateStore.transition_current(c.authority, c.expected, "validate", %{}, %{provenance(c) | dispatch_id: "foreign"})
    assert {:error, :invalid_current_attrs} = RunStateStore.transition_current(c.authority, c.expected, "validate", %{last_agent_session: %{event_id: "fake"}})
    assert {:error, :execution_provenance_mismatch} = DeployAudit.begin(c.workspace, c.attrs, %{execution(c) | provenance: %{provenance(c) | run_id: "foreign"}})
    assert evidence(c) == before
  end

  test "present but corrupt prior session is visible and cannot invent a historical binding", c do
    assert {:ok, _} =
             RunStateStore.update(
               c.workspace,
               &Map.put(&1, :last_agent_session, %{
                 version: 1,
                 event_id: "missing",
                 run_id: c.authority.ticket.run_id,
                 dispatch_id: c.authority.ticket.dispatch_id,
                 agent_session: %{provider: "app_server", kind: "thread", id: "fake", invocation: 1}
               })
             )

    before = evidence(c)
    assert {:error, {:invalid_prior_agent_session, :not_found}} = RunStateStore.transition_current(c.authority, c.expected, "validate", %{})
    assert evidence(c) == before
  end

  test "diagnostic projection is checked and contains no command, output or capability", c do
    ticket = begin!(c)
    assert {:ok, %{status: "authorized", version: 2, chain: :confirmed} = requested} = DeployAudit.inspect_pending(c.workspace)
    assert requested.run_id == c.authority.ticket.run_id
    assert requested.dispatch_id == c.authority.ticket.dispatch_id
    refute Map.has_key?(requested, :result_status)
    assert {:ok, receipt} = DeployAudit.record_result(ticket, c.result)
    before = evidence(c)
    assert {:ok, diagnostic} = DeployAudit.inspect_pending(c.workspace)
    assert diagnostic.result_status == "passed"
    assert diagnostic.event_ids.result == receipt.result_event_id
    encoded = Jason.encode!(diagnostic)
    for value <- [c.result.command, c.result.output, c.authority.lease_token.lease_generation, "live_ref", "lease_token"], do: refute(String.contains?(encoded, value))
    assert evidence(c) == before
    File.write!(c.authority.ticket.ledger_path, File.read!(c.authority.ticket.ledger_path) <> Jason.encode!(checked!(receipt.result_event_id)) <> "\n")
    before = evidence(c)
    assert {:error, {:deploy_diagnostic_unconfirmed, %RunLedger.PersistenceError{}}} = DeployAudit.inspect_pending(c.workspace)
    assert evidence(c) == before
  end

  for boundary <- [:begin, :cas] do
    @tag barrier_boundary: boundary
    test "public #{boundary} retains exclusion until its checked writer returns", c do
      handler = "deploy-current-lock-#{System.unique_integer([:positive])}"
      event_type = if c.barrier_boundary == :begin, do: "deploy.preview.requested", else: "stage.transition.requested"
      assert :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.writer_barrier/4, {self(), event_type})
      on_exit(fn -> :telemetry.detach(handler) end)

      worker =
        Task.async(fn ->
          ticket = begin!(c)
          assert {:ok, _} = DeployAudit.record_result(ticket, c.result)
          assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
          assert :ok = DeployAudit.finish(ticket, continuation)
        end)

      assert_receive {:writer_barrier, writer}, 5_000
      parent = self()

      competitor =
        Task.async(fn ->
          send(parent, :competitor_entering)
          result = RunStateStore.update(c.workspace, &Map.put(&1, :last_decision_summary, "competitor"))
          send(parent, :competitor_completed)
          result
        end)

      assert_receive :competitor_entering, 5_000
      refute_receive :competitor_completed, 100
      send(writer, :continue_writer)
      assert :ok = Task.await(worker, 5_000)
      assert {:ok, _} = Task.await(competitor, 5_000)
      assert_receive :competitor_completed, 5_000
      assert :ok = DeployAudit.ensure_available(c.workspace)
    end
  end

  for boundary <- [:context, :finish] do
    @tag physical_barrier_boundary: boundary
    test "public #{boundary} holds its workspace lock during the physical lease check", c do
      parent = self()

      worker =
        Task.async(fn ->
          ticket = begin!(c)
          assert {:ok, _} = DeployAudit.record_result(ticket, c.result)

          continuation =
            if c.physical_barrier_boundary == :finish do
              assert {:ok, _state, receipt} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))
              receipt
            end

          send(parent, {:physical_boundary_ready, self()})

          receive do
            :run_public_boundary ->
              if c.physical_barrier_boundary == :context, do: DeployAudit.continuation_context(ticket), else: DeployAudit.finish(ticket, continuation)
          after
            5_000 -> raise "public deploy boundary was not started"
          end
        end)

      on_exit(fn -> if Process.alive?(worker.pid), do: Process.exit(worker.pid, :kill) end)
      worker_pid = worker.pid
      assert_receive {:physical_boundary_ready, ^worker_pid}, 5_000
      lock_path = c.authority.lease_token.storage.lease_path <> ".lock"
      pattern = {File, :mkdir, 1}
      assert :erlang.trace_pattern(pattern, [{[lock_path], [], []}], [:local]) == 1
      :erlang.trace(worker.pid, true, [:call, {:tracer, self()}])

      try do
        File.mkdir!(lock_path)

        competitor =
          try do
            send(worker.pid, :run_public_boundary)
            # The trace is emitted from LM.ensure_current inside the public workspace lock.
            # Release this test-owned directory well before LM's unchanged 1000ms deadline.
            assert_receive {:trace, ^worker_pid, :call, {File, :mkdir, [^lock_path]}}, 5_000

            competitor =
              Task.async(fn ->
                send(parent, :physical_competitor_entering)
                result = RunStateStore.update(c.workspace, &Map.put(&1, :last_decision_summary, "public competitor"))
                send(parent, :physical_competitor_completed)
                result
              end)

            on_exit(fn -> if Process.alive?(competitor.pid), do: Process.exit(competitor.pid, :kill) end)
            assert_receive :physical_competitor_entering, 5_000
            refute_receive :physical_competitor_completed, 100
            competitor
          after
            File.rmdir!(lock_path)
          end

        result = Task.await(worker, 5_000)

        case c.physical_barrier_boundary do
          :context ->
            assert {:ok, %{operation_id: _}} = result
            assert {:error, {:deploy_audit_pending, _}} = DeployAudit.ensure_available(c.workspace)

          :finish ->
            assert result == :ok
            assert :ok = DeployAudit.ensure_available(c.workspace)
        end

        assert {:ok, state} = Task.await(competitor, 5_000)
        assert state.last_decision_summary == "public competitor"
        assert_receive :physical_competitor_completed, 5_000
        refute File.exists?(lock_path)
      after
        if Process.alive?(worker.pid), do: :erlang.trace(worker.pid, false, [:call])
        :erlang.trace_pattern(pattern, false, [:local])
      end
    end
  end

  def writer_barrier(_event, _measurements, metadata, {parent, event_type}) do
    if metadata[:event_type] == event_type do
      send(parent, {:writer_barrier, self()})

      receive do
        :continue_writer -> :ok
      after
        5_000 -> raise "deploy writer barrier was not released"
      end
    end
  end

  test "locked context and finish validators do not release the caller's workspace lock", c do
    ticket = begin!(c)
    assert {:ok, _} = DeployAudit.record_result(ticket, c.result)

    assert_exclusion(c, fn ->
      assert {:ok, _} = DeployAudit.continuation_context_locked(ticket)
      assert {:ok, _} = RunStateStore.check_deploy_current_locked(c.authority, c.expected)
    end)

    assert {:ok, _state, continuation} = RunStateStore.transition_deploy(ticket, "done", %{}, precondition(c))

    assert_exclusion(c, fn ->
      assert :ok = DeployAudit.assert_continuation_locked(ticket, continuation)
      assert :ok = RunStateStore.confirm_deploy_continuation_locked(ticket, c.authority, continuation)
    end)

    assert :ok = DeployAudit.finish(ticket, continuation)
  end

  defp assert_exclusion(c, fun) do
    parent = self()
    ref = make_ref()

    RunStateStore.with_workspace_lock(c.workspace, fn ->
      fun.()

      Task.start(fn ->
        send(parent, {:competitor_started, ref})
        result = RunStateStore.update(c.workspace, &Map.put(&1, :last_decision_summary, inspect(ref)))
        send(parent, {:competitor_finished, ref, result})
      end)

      assert_receive {:competitor_started, ^ref}, 5_000
      refute_receive {:competitor_finished, ^ref, _}, 100
      assert raw!(c)["last_decision_summary"] != inspect(ref)
    end)

    assert_receive {:competitor_finished, ^ref, {:ok, state}}, 5_000
    assert state.last_decision_summary == inspect(ref)
  end

  defp trace_writers(fun) do
    {tracer, monitor} = spawn_monitor(fn -> collect_calls([]) end)
    patterns = [{RunLedger, :prepare_entry, 2}, {RunLedger, :persist_prepared, 1}, {RunStateStore, :with_workspace_lock, 2}, {File, :write, 3}, {File, :rename, 2}, {File, :mkdir, 1}, {File, :rm, 1}]

    try do
      for pattern <- patterns, do: assert(:erlang.trace_pattern(pattern, true, [:local]) == 1)
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      fun.()
      barrier = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^barrier}, 5_000
      send(tracer, {:calls, self()})
      assert_receive {:calls, calls}, 5_000
      calls
    after
      :erlang.trace(self(), false, [:call])
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
      send(tracer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^tracer, :normal}, 5_000
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        collect_calls([{module, function, length(args)} | calls])

      {:calls, owner} ->
        send(owner, {:calls, Enum.reverse(calls)})
        collect_calls(calls)

      :stop ->
        :ok
    end
  end

  defp begin!(c) do
    assert {:ok, ticket} = DeployAudit.begin(c.workspace, c.attrs, execution(c))
    ticket
  end

  defp execution(c), do: Map.put(precondition(c), :provenance, provenance(c))
  defp precondition(c), do: %{authority: c.authority, expected: c.expected}

  defp provenance(c),
    do: %{
      version: 1,
      actor_role: "runtime",
      run_id: c.authority.ticket.run_id,
      dispatch_id: c.authority.ticket.dispatch_id,
      lease_generation: c.authority.lease_token.lease_generation,
      agent_session: nil,
      prior_agent_session: nil
    }

  defp marker_path(c), do: Path.join(DeployAudit.marker_directory(c.workspace), "marker.json")
  defp marker!(c), do: c |> marker_path() |> File.read!() |> Jason.decode!()
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp rows(c), do: c.authority.ticket.ledger_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp deploy_rows(c), do: Enum.filter(rows(c), &String.starts_with?(&1["event_type"], "deploy."))

  defp checked!(event_id) do
    assert {:ok, event} = RunLedger.fetch_entry_checked(event_id)
    event
  end

  defp evidence(c),
    do: %{
      snapshot: File.read(RunStateStore.state_path(c.workspace)),
      lease: File.read(c.authority.lease_token.storage.lease_path),
      dispatch: File.read(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json")),
      ledger: File.read(c.authority.ticket.ledger_path),
      deploy: File.read(marker_path(c))
    }
end
