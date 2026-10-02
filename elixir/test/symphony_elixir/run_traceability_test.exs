defmodule SymphonyElixir.RunTraceabilityTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest

  alias SymphonyElixir.{DispatchAudit, LeaseManager, RunIdentity, RunLedger, RunStateStore}
  alias SymphonyElixirWeb.{Endpoint, Presenter}
  @endpoint Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "traceability-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    assert Path.expand(Config.workspace_root()) == Path.expand(root)
    previous_endpoint = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(previous_endpoint, server: false, secret_key_base: String.duplicate("t", 64)))
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  # Storage fixtures use real admission, physical lease, checked CAS and ledger.
  # No worker is created; :not_started is the truthful dispatch finish reason.
  for {label, stage, reason} <- [
        {"success checkpoint", "await_checks", nil},
        {"blocked checkpoint", "blocked", %{code: "proof_failed", rule_id: "proof.failed", summary: "Proof failed"}},
        {"cancelled checkpoint", "blocked", %{code: "tracker_terminal_state", rule_id: "tracker.terminal_state", summary: "Tracker cancelled the issue"}}
      ] do
    @tag stage: stage, reason: reason
    test "all four selectors reconstruct the same #{label} without writes", c do
      f = admitted!("TRACE-1", c.stage, c.reason)
      before = bytes!(f)

      responses =
        for selector <- [%{"issue" => f.issue.id}, %{"issue" => f.issue.identifier}, %{"run" => f.ticket.run_id}, %{"workspace" => f.workspace}, %{"pr" => f.pr}] do
          get(build_conn(), "/api/v1/traceability?" <> URI.encode_query(selector)) |> json_response(200)
        end

      assert Enum.uniq(responses) |> length() == 1
      [payload | _] = responses
      assert payload["identity"] == %{"run_id" => f.ticket.run_id, "issue_id" => f.issue.id, "issue_identifier" => f.issue.identifier, "workspace" => f.workspace}
      assert payload["result"]["stage"] == c.stage
      assert payload["result"]["stop_reason"] == Jason.decode!(Jason.encode!(c.reason))
      assert payload["links"]["pr"] == f.pr
      assert payload["links"]["workspace"] == "/api/v1/traceability?" <> URI.encode_query(%{"workspace" => f.workspace})
      assert json_response(get(build_conn(), payload["links"]["workspace"]), 200) == payload
      assert payload["evidence"]["last_event"]["event_type"] == "stage.transition"
      assert payload["evidence"]["last_event"]["actor_type"] == "runtime"
      assert payload["evidence"]["last_event"]["stage"] == c.stage
      assert [%{"dispatch_id" => dispatch_id, "authorized" => authorization, "finished" => finished}] = payload["evidence"]["dispatches"]
      assert dispatch_id == f.ticket.dispatch_id
      assert authorization["event_id"] == f.ticket.entry_event_id
      assert finished["event_type"] == "dispatch.finished"
      assert bytes!(f) == before
      assert :ok = RunIdentity.verify(f.workspace, f.ticket.run_id, f.issue.id, f.issue.identifier)
    end
  end

  test "same run with two genuine admissions retains both distinct dispatch references" do
    f = admitted!("TRACE-RETRY", "await_checks", nil)
    assert {:ok, acquired} = LeaseManager.acquire(f.issue.id, f.issue.identifier, "traceability-successor")
    attrs = %{f.attrs | stage: "await_checks", metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}
    assert {:ok, source, _view} = RunStateStore.read_admission_source(f.workspace, f.issue)
    assert {:ok, second, _raw} = DispatchAudit.begin(f.workspace, attrs, source)
    assert second.run_id == f.ticket.run_id
    assert second.dispatch_id != f.ticket.dispatch_id
    assert :ok = DispatchAudit.finish(second, :not_started)
    assert {:ok, :released} = LeaseManager.release_token(acquired.token)
    assert {:ok, payload} = Presenter.traceability_payload(%{"run" => second.run_id})
    assert Enum.map(payload.evidence.dispatches, & &1.dispatch_id) |> Enum.sort() == Enum.sort([f.ticket.dispatch_id, second.dispatch_id])
  end

  test "historical run never adopts the state of an authentic replacement identity" do
    old = admitted!("TRACE-HISTORY", "await_checks", nil)
    File.rm_rf!(old.workspace)
    replacement = admitted!("TRACE-HISTORY", "blocked", %{code: "proof_failed"})
    refute replacement.ticket.run_id == old.ticket.run_id
    before = bytes!(replacement)
    assert {:error, 409, %{error: %{code: "identity_conflict", cause: "snapshot_binding_changed"}}} = Presenter.traceability_payload(%{"run" => old.ticket.run_id})
    assert {:ok, current} = Presenter.traceability_payload(%{"run" => replacement.ticket.run_id})
    assert current.identity.run_id == replacement.ticket.run_id
    assert current.result["stage"] == "blocked"
    assert bytes!(replacement) == before
  end

  test "a current run rejects the genuine dispatch finish of an earlier run of the same issue" do
    old = admitted!("TRACE-OLD-FINISH", "await_checks", nil)
    assert {:ok, rows, _digest} = RunLedger.CheckedStorage.entries_checked(RunLedger.ledger_file_path())
    [old_finish] = Enum.filter(rows, &(&1["event_type"] == "dispatch.finished" and &1["metadata"]["run_id"] == old.ticket.run_id))
    assert old_finish["metadata"]["authorization_event_id"] == old.ticket.entry_event_id
    refute Map.has_key?(old_finish["metadata"], "execution")

    File.rm_rf!(old.workspace)
    current = admitted!("TRACE-OLD-FINISH", "blocked", %{code: "proof_failed"})
    refute current.ticket.run_id == old.ticket.run_id
    assert current.issue == old.issue
    assert {:ok, payload} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert payload.identity.run_id == current.ticket.run_id
    assert payload.evidence.last_event["event_type"] == "stage.transition"

    path = RunStateStore.state_path(current.workspace)
    raw = path |> File.read!() |> Jason.decode!()
    File.write!(path, raw |> Map.put("last_ledger_event_id", old_finish["event_id"]) |> Jason.encode!())
    assert :ok = RunIdentity.verify(current.workspace, current.ticket.run_id, current.issue.id, current.issue.identifier)
    before = bytes!(current)

    assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_material_mismatch"}}} =
             Presenter.traceability_payload(%{"run" => current.ticket.run_id})

    assert bytes!(current) == before
  end

  test "a current run rejects the same-stage unannotated legacy transition from a previous run" do
    old = legacy_admitted!("TRACE-OLD-LEGACY")
    old_event = old.legacy_event
    assert old_event["event_type"] == "stage.transition"
    assert old_event["stage"] == "await_checks"
    refute Map.has_key?(old_event["metadata"], "execution")
    assert :ok = RunIdentity.verify(old.workspace, old.ticket.run_id, old.issue.id, old.issue.identifier)

    File.rm_rf!(old.workspace)
    current = admitted!("TRACE-OLD-LEGACY", "await_checks", nil)
    refute current.ticket.run_id == old.ticket.run_id
    assert current.issue == old.issue
    assert {:ok, original} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert original.evidence.last_event["event_id"] != old_event["event_id"]

    path = RunStateStore.state_path(current.workspace)
    original_raw = path |> File.read!() |> Jason.decode!()
    assert original_raw["stage"] == old_event["stage"]
    changed = Map.put(original_raw, "last_ledger_event_id", old_event["event_id"])
    assert Map.delete(changed, "last_ledger_event_id") == Map.delete(original_raw, "last_ledger_event_id")
    File.write!(path, Jason.encode!(changed))
    assert :ok = RunIdentity.verify(current.workspace, current.ticket.run_id, current.issue.id, current.issue.identifier)
    bytes = bytes!(current)

    assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_material_mismatch"}}} =
             Presenter.traceability_payload(%{"run" => current.ticket.run_id})

    assert bytes!(current) == bytes
  end

  test "legitimate legacy adoption retains its transition reference after fresh usage changes" do
    current = legacy_admitted!("TRACE-ADOPT-LEGACY")
    assert {:ok, before_update} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert before_update.evidence.last_event["event_id"] == current.legacy_event["event_id"]
    assert {:ok, updated} = RunStateStore.update(current.workspace, &Map.put(&1, :token_usage, %{input_tokens: 1, output_tokens: 2, total_tokens: 3}))
    assert updated.last_ledger_event_id == current.legacy_event["event_id"]
    assert :ok = RunIdentity.verify(current.workspace, current.ticket.run_id, current.issue.id, current.issue.identifier)
    assert {:ok, identity} = RunLedger.fetch_entry_checked(updated.run_identity_event_id)
    assert identity["event_type"] == "run.identity.adopted"
    assert identity["metadata"]["snapshot_digest"] != RunStateStore.snapshot_digest(updated)
    bytes = bytes!(current)

    assert {:ok, after_update} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert after_update.identity.run_id == current.ticket.run_id
    assert after_update.evidence.last_event["event_id"] == current.legacy_event["event_id"]
    assert after_update.result["stage"] == "await_checks"
    assert bytes!(current) == bytes
  end

  test "identified C5 coordinator transition carries binding without claiming worker execution" do
    current = admitted!("TRACE-COORDINATOR", "await_checks", nil)
    raw = current.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
    assert {:ok, acquired} = LeaseManager.acquire(current.issue.id, current.issue.identifier, "traceability-coordinator")
    binding = %{run_id: raw["run_id"], run_identity_event_id: raw["run_identity_event_id"], run_identity_ledger_path: raw["run_identity_ledger_path"]}

    authority = %{
      workspace: current.workspace,
      issue_id: current.issue.id,
      issue_identifier: current.issue.identifier,
      binding: {:identified, binding},
      lease_token: acquired.token,
      deadline: System.monotonic_time(:millisecond) + 30_000
    }

    attrs = %{
      last_ci_failure: %{event_name: "check_run", action: "completed", check_name: "tests", conclusion: "failure", details_url: nil, head_sha: "abc", pr_url: current.pr, summary: "tests (failure)"},
      last_decision_summary: "CI observation",
      next_human_action: nil,
      resume_context: Map.merge(raw["resume_context"] || %{}, %{ci_failure_summary: "tests (failure)", ci_failure_pr_url: current.pr, ci_failure_details_url: nil}),
      issue_source: raw["issue_source"],
      pr_url: current.pr,
      stop_reason: nil,
      last_decision: nil,
      last_rule_id: nil,
      last_failure_class: nil,
      await_checks_polls: 0
    }

    try do
      assert {:ok, updated} = RunStateStore.transition_coordinator_current(authority, RunStateStore.coordinator_projection(raw), "implement", attrs)
      assert {:ok, event} = RunLedger.fetch_entry_checked(updated.last_ledger_event_id)
      refute Map.has_key?(event["metadata"], "execution")
      expected = binding |> Map.put(:workspace, current.workspace) |> Map.put(:workspace_digest, workspace_digest(current.workspace)) |> Jason.encode!() |> Jason.decode!()
      assert event["metadata"]["run_binding"] == expected
      assert {:ok, payload} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
      assert payload.evidence.last_event["event_id"] == event["event_id"]
      assert payload.result["stage"] == "implement"
      assert :ok = DispatchAudit.ensure_available(current.workspace)
    after
      assert {:ok, :released} = LeaseManager.release_token(acquired.token)
    end
  end

  test "a prior own transition cannot replace a later bound transition at the same stage" do
    current = admitted!("TRACE-OLDER-OWN", "await_checks", nil)
    path = RunStateStore.state_path(current.workspace)
    first = path |> File.read!() |> Jason.decode!()
    assert {:ok, _} = RunStateStore.transition(current.workspace, "implement")
    assert {:ok, latest} = RunStateStore.transition(current.workspace, "await_checks")
    assert latest.last_ledger_event_id != first["last_ledger_event_id"]
    assert {:ok, original} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert original.evidence.last_event["event_id"] == latest.last_ledger_event_id
    File.write!(path, path |> File.read!() |> Jason.decode!() |> Map.put("last_ledger_event_id", first["last_ledger_event_id"]) |> Jason.encode!())
    bytes = bytes!(current)
    assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_material_mismatch"}}} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert bytes!(current) == bytes
  end

  test "an inherited reference cannot replace a later bound transition at the same stage" do
    current = legacy_admitted!("TRACE-OLDER-INHERITED")
    assert {:ok, _} = RunStateStore.transition(current.workspace, "implement")
    assert {:ok, latest} = RunStateStore.transition(current.workspace, "await_checks")
    assert latest.last_ledger_event_id != current.legacy_event["event_id"]
    path = RunStateStore.state_path(current.workspace)
    File.write!(path, path |> File.read!() |> Jason.decode!() |> Map.put("last_ledger_event_id", current.legacy_event["event_id"]) |> Jason.encode!())
    bytes = bytes!(current)
    assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_material_mismatch"}}} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert bytes!(current) == bytes
  end

  test "an unannotated historical reference without an admission witness stays incomplete" do
    current = legacy_admitted!("TRACE-MISSING-WITNESS")
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(RunLedger.ledger_file_path())

    rows =
      Enum.map(rows, fn row ->
        if row["event_type"] in ["run.identity.requested", "run.identity.adopted"] and row["metadata"]["run_id"] == current.ticket.run_id,
          do: update_in(row, ["metadata"], &Map.delete(&1, "inherited_stage_event_id")),
          else: row
      end)

    File.write!(RunLedger.ledger_file_path(), Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
    assert :ok = RunIdentity.verify(current.workspace, current.ticket.run_id, current.issue.id, current.issue.identifier)
    bytes = bytes!(current)
    assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_material_mismatch"}}} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert bytes!(current) == bytes
  end

  for {key, replacement} <- [{"run_id", "different"}, {"workspace", "different"}, {"run_identity_event_id", "different"}, {"run_identity_ledger_path", "different"}, {"extra", "not-a-binding-field"}] do
    @tag binding_change: {key, replacement}
    test "contradictory stage binding #{key} never falls back to execution provenance", c do
      current = admitted!("TRACE-BINDING-CHANGE", "await_checks", nil)
      {:ok, raw} = RunStateStore.load(current.workspace)
      {key, replacement} = c.binding_change
      assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(RunLedger.ledger_file_path())

      rows =
        Enum.map(rows, fn row ->
          if row["event_id"] == raw.last_ledger_event_id, do: update_in(row, ["metadata", "run_binding"], &Map.put(&1, key, replacement)), else: row
        end)

      File.write!(RunLedger.ledger_file_path(), Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
      bytes = bytes!(current)
      assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_material_mismatch"}}} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
      assert bytes!(current) == bytes
    end
  end

  test "a witnessed initial nil reference survives usage changes without inventing an event" do
    current = admitted!("TRACE-NIL-WITNESS", "implement", nil)
    assert {:ok, updated} = RunStateStore.update(current.workspace, &Map.put(&1, :token_usage, %{input_tokens: 3, output_tokens: 4, total_tokens: 7}))
    assert {:ok, identity} = RunLedger.fetch_entry_checked(updated.run_identity_event_id)
    assert Map.fetch(identity["metadata"], "inherited_stage_event_id") == {:ok, nil}
    bytes = bytes!(current)
    assert {:ok, payload} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert payload.evidence.last_event == nil
    assert payload.result["stage"] == "implement"
    assert bytes!(current) == bytes
  end

  test "historical worker provenance remains a witness without new metadata fields" do
    current = admitted!("TRACE-HISTORICAL-EXECUTION", "await_checks", nil)
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(RunLedger.ledger_file_path())

    rows =
      Enum.map(rows, fn row ->
        cond do
          row["event_type"] in ["stage.transition.requested", "stage.transition"] ->
            assert row["metadata"]["execution"]["run_id"] == current.ticket.run_id
            update_in(row, ["metadata"], &Map.delete(&1, "run_binding"))

          row["event_type"] in ["run.identity.requested", "run.identity.adopted"] ->
            update_in(row, ["metadata"], &Map.delete(&1, "inherited_stage_event_id"))

          true ->
            row
        end
      end)

    File.write!(RunLedger.ledger_file_path(), Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
    bytes = bytes!(current)
    assert {:ok, payload} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert payload.identity.run_id == current.ticket.run_id
    assert payload.evidence.last_event["event_type"] == "stage.transition"
    assert bytes!(current) == bytes
  end

  test "an initial nil reference without a captured admission witness is explicitly incomplete" do
    current = admitted!("TRACE-NIL-NO-WITNESS", "implement", nil)
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(RunLedger.ledger_file_path())

    rows =
      Enum.map(rows, fn row ->
        if row["event_type"] in ["run.identity.requested", "run.identity.adopted"], do: update_in(row, ["metadata"], &Map.delete(&1, "inherited_stage_event_id")), else: row
      end)

    File.write!(RunLedger.ledger_file_path(), Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
    assert :ok = RunIdentity.verify(current.workspace, current.ticket.run_id, current.issue.id, current.issue.identifier)
    bytes = bytes!(current)
    assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_witness_missing"}}} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert bytes!(current) == bytes
  end

  test "deleting an inherited reference is not mistaken for an initial nil reference" do
    current = legacy_admitted!("TRACE-DELETE-INHERITED")
    path = RunStateStore.state_path(current.workspace)
    File.write!(path, path |> File.read!() |> Jason.decode!() |> Map.put("last_ledger_event_id", nil) |> Jason.encode!())
    bytes = bytes!(current)
    assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_reference_missing"}}} = Presenter.traceability_payload(%{"run" => current.ticket.run_id})
    assert bytes!(current) == bytes
  end

  test "two genuine runs sharing a PR are ambiguous and neither is selected" do
    first = admitted!("TRACE-PR-A", "await_checks", nil, "https://example.invalid/pr/shared")
    second = admitted!("TRACE-PR-B", "blocked", %{code: "proof_failed"}, first.pr)
    before = {bytes!(first), bytes!(second)}
    assert {:error, 409, %{error: %{code: "ambiguous", cause: "multiple_matching_runs"}}} = Presenter.traceability_payload(%{"pr" => first.pr})
    assert {bytes!(first), bytes!(second)} == before
  end

  test "missing historical snapshot is explicit and cannot establish that a PR is absent" do
    f = admitted!("TRACE-MISSING", "await_checks", nil)
    File.rm!(RunStateStore.state_path(f.workspace))
    before = File.read!(RunLedger.ledger_file_path())
    assert {:error, 503, %{error: %{code: "workspace_unavailable", cause: "enoent"}}} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    assert {:error, 503, %{error: %{code: "workspace_unavailable"}}} = Presenter.traceability_payload(%{"pr" => "https://example.invalid/pr/absent"})
    refute File.exists?(RunStateStore.state_path(f.workspace))
    assert File.read!(RunLedger.ledger_file_path()) == before
  end

  test "alternate bootstrap is never substituted for missing canonical evidence", c do
    f = admitted!("TRACE-BOOTSTRAP", "await_checks", nil)
    alternate = Path.join(c.root, ".TRACE-BOOTSTRAP.bootstrap-held")
    File.mkdir_p!(alternate)
    File.rename!(RunStateStore.state_path(f.workspace), Path.join(alternate, "run_state.json"))
    assert {:ok, _historical_fallback} = RunStateStore.load(f.workspace)
    assert {:error, 503, %{error: %{code: "workspace_unavailable", cause: "enoent"}}} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    assert File.exists?(Path.join(alternate, "run_state.json"))
    refute File.exists?(RunStateStore.state_path(f.workspace))
  end

  test "legacy evidence without confirmed identity is not reported as an identified run" do
    RunLedger.record("legacy.event", %{issue_id: "legacy", issue_identifier: "TRACE-LEGACY"})
    before = File.read!(RunLedger.ledger_file_path())
    assert {:error, 409, %{error: %{code: "identity_incomplete", cause: "confirmed_identity_missing"}}} = Presenter.traceability_payload(%{"issue" => "legacy"})
    assert File.read!(RunLedger.ledger_file_path()) == before
  end

  for {name, change, expected, cause} <- [
        {"wrong issue", %{"issue_id" => "another"}, "identity_incomplete", "run_identity_issue_mismatch"},
        {"pending identity", %{"run_identity_pending" => nil}, "identity_incomplete", "run_identity_pending"},
        {"pending transition", %{"audit_pending" => %{}}, "snapshot_incomplete", "audit_pending"},
        {"missing event reference", %{"last_ledger_event_id" => "missing"}, "snapshot_incomplete", "last_ledger_reference_missing_or_mismatched"},
        {"absent transition reference", %{"last_ledger_event_id" => nil}, "snapshot_incomplete", "last_ledger_reference_missing"},
        {"material stage mismatch", %{"stage" => "done"}, "snapshot_incomplete", "last_ledger_material_mismatch"},
        {"invalid result shape", %{"stop_reason" => ["untrusted output"]}, "snapshot_incomplete", "invalid_result_shape"},
        {"blocked without a cause", %{"stage" => "blocked", "stop_reason" => nil}, "snapshot_incomplete", "invalid_result_shape"}
      ] do
    @tag change: change, expected: expected, cause: cause
    test "#{name} stays visible without repairing the snapshot", c do
      f = admitted!("TRACE-BROKEN", "await_checks", nil)
      path = RunStateStore.state_path(f.workspace)
      File.write!(path, File.read!(path) |> Jason.decode!() |> Map.merge(c.change) |> Jason.encode!())
      before = bytes!(f)
      assert {:error, 409, %{error: %{code: code, cause: cause}}} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
      assert {code, cause} == {c.expected, c.cause}
      assert bytes!(f) == before
    end
  end

  test "corrupt JSON preserves the diagnostic position without reflecting its content" do
    f = admitted!("TRACE-JSON", "await_checks", nil)
    sentinel = "PB14_RAW_SECRET_SENTINEL"
    File.write!(RunStateStore.state_path(f.workspace), "{\"secret\":\"#{sentinel}\",broken")
    before = bytes!(f)
    assert {:error, 503, %{error: %{cause: %{code: "invalid_json", position: position}}} = error} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    assert is_integer(position)
    refute Jason.encode!(error) =~ sentinel
    assert bytes!(f) == before
  end

  test "ledger truncation and occupied checked lock remain errors, never empty matches" do
    f = admitted!("TRACE-LEDGER", "await_checks", nil)
    path = RunLedger.ledger_file_path()
    before = File.read!(path)
    File.write!(path, "{unfinished", [:append])
    assert {:error, 503, %{error: %{code: "ledger_unavailable", cause: %{phase: :decode}}}} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    assert File.read!(path) == before <> "{unfinished"
    File.write!(path, before)
    File.mkdir!(path <> ".checked.lock")

    try do
      assert {:error, 503, %{error: %{code: "ledger_unavailable", cause: %{phase: :lock, reason: "eexist"}}}} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
      assert File.dir?(path <> ".checked.lock")
    after
      File.rmdir!(path <> ".checked.lock")
    end
  end

  for fault <- [:missing_authorization, :wrong_finish_reference] do
    @tag dispatch_fault: fault
    test "dispatch #{fault} is an explicit chain error", c do
      f = admitted!("TRACE-DISPATCH", "await_checks", nil)
      rows = RunLedger.ledger_file_path() |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      damaged =
        case c.dispatch_fault do
          :missing_authorization ->
            Enum.reject(rows, &(&1["event_id"] == f.ticket.entry_event_id))

          :wrong_finish_reference ->
            Enum.map(rows, fn row -> if row["event_type"] == "dispatch.finished", do: put_in(row, ["metadata", "authorization_event_id"], "another-authorization"), else: row end)
        end

      File.write!(RunLedger.ledger_file_path(), Enum.map(damaged, &(Jason.encode!(&1) <> "\n")))
      before = bytes!(f)
      assert {:error, 409, %{error: %{code: "dispatch_incomplete"}}} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
      assert bytes!(f) == before
    end
  end

  test "missing ledger remains a checked I/O error instead of not found" do
    f = admitted!("TRACE-NO-LEDGER", "await_checks", nil)
    path = RunLedger.ledger_file_path()
    original = File.read!(path)
    File.rm!(path)
    assert {:error, 503, %{error: %{code: "ledger_unavailable", cause: %{phase: :read, reason: "enoent"}}}} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    refute File.exists?(path)
    File.write!(path, original)
  end

  test "I/O and configured root drift do not disclose unrelated host paths", c do
    f = admitted!("TRACE-ROOT", "await_checks", nil)
    before = bytes!(f)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(c.root, "new-root"))
    assert {:error, 409, %{error: %{code: "source_changed", cause: "workspace_root_or_identity_path_changed"}} = error} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    refute Jason.encode!(error) =~ c.root
    assert bytes!(f) == before
  end

  test "ledger changed while waiting for the real workspace lock invalidates the read" do
    f = admitted!("TRACE-DRIFT", "await_checks", nil)
    lock = {{RunStateStore, Path.expand(f.workspace)}, self()}
    assert :global.set_lock(lock, [node()], 0)
    parent = self()

    {reader, monitor} =
      spawn_monitor(fn ->
        receive do
          :read -> send(parent, {:query_result, self(), Presenter.traceability_payload(%{"run" => f.ticket.run_id})})
        end
      end)

    :erlang.trace_pattern({RunStateStore, :with_workspace_lock, 2}, true, [:local])
    :erlang.trace(reader, true, [:call, {:tracer, self()}])

    try do
      send(reader, :read)
      assert_receive {:trace, ^reader, :call, {RunStateStore, :with_workspace_lock, [workspace, _fun]}}, 2_000
      assert workspace == f.workspace
      event = RunLedger.record("traceability.test.concurrent", %{issue_id: f.issue.id, issue_identifier: f.issue.identifier})
      assert is_binary(event.event_id)
      assert :global.del_lock(lock, [node()])
      assert_receive {:query_result, ^reader, {:error, 409, %{error: %{code: "source_changed", cause: "ledger_changed"}}}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, 2_000
    after
      :global.del_lock(lock, [node()])
      :erlang.trace_pattern({RunStateStore, :with_workspace_lock, 2}, false, [:local])
      if Process.alive?(reader), do: Process.exit(reader, :kill)
    end
  end

  test "projection excludes canaries in command, output, metadata and stop details" do
    sentinel = "PB14_UNPROJECTED_SECRET_SENTINEL"
    f = admitted!("TRACE-CANARY", "blocked", %{code: "proof_failed", details: sentinel, summary: "Proof failed"})
    assert {:ok, _} = RunStateStore.update(f.workspace, &Map.merge(&1, %{command: sentinel, output: sentinel, private_metadata: %{secret: sentinel}}))
    RunLedger.record("private.diagnostic", %{issue_id: f.issue.id, issue_identifier: f.issue.identifier, details: sentinel, metadata: %{output: sentinel, command: sentinel}})
    before = bytes!(f)
    payload = get(build_conn(), "/api/v1/traceability?" <> URI.encode_query(%{"run" => f.ticket.run_id})) |> json_response(200)
    refute Jason.encode!(payload) =~ sentinel
    assert payload["result"]["stop_reason"]["code"] == "proof_failed"
    assert payload["result"]["stop_reason"]["summary"] == "Proof failed"
    assert bytes!(f) == before
  end

  test "registered workspace symlinks are rejected without reading their targets", c do
    f = admitted!("TRACE-LINK", "await_checks", nil)
    target = Path.join(c.root, "held-canonical-state")
    path = RunStateStore.state_path(f.workspace)
    File.rename!(path, target)
    File.ln_s!(target, path)
    before = File.read!(target)
    assert {:error, 503, %{error: %{code: "workspace_unavailable", cause: "unexpected_path_type"}}} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    assert File.read!(target) == before
  end

  for selector <- [%{}, %{"run" => "", "issue" => "A"}, %{"run" => "x", "issue" => "A"}, %{"unknown" => "x"}, %{"workspace" => "relative"}, %{"pr" => "https://user:secret@example.invalid/pr/1"}] do
    @tag selector: selector
    test "invalid selector #{inspect(selector)} is rejected before any ledger read", c do
      refute File.exists?(RunLedger.ledger_file_path())
      assert {:error, 400, %{error: %{code: "invalid_selector"}}} = Presenter.traceability_payload(c.selector)
      refute File.exists?(RunLedger.ledger_file_path())
    end
  end

  test "a checked empty ledger returns absence and the literal route rejects mutations" do
    File.mkdir_p!(Path.dirname(RunLedger.ledger_file_path()))
    File.write!(RunLedger.ledger_file_path(), "")
    assert {:error, 404, %{error: %{code: "not_found"}}} = Presenter.traceability_payload(%{"run" => "run_absent"})
    assert json_response(post(build_conn(), "/api/v1/traceability", %{"run" => "run_absent"}), 405)["error"]["code"] == "method_not_allowed"
    assert File.read!(RunLedger.ledger_file_path()) == ""
  end

  test "redacted canonical workspace retains genuine admission, transition and finish evidence", c do
    root = Path.join(c.root, "token=traceability-workspace-sentinel")
    File.mkdir_p!(root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    assert Path.expand(Config.workspace_root()) == Path.expand(root)
    f = admitted!("TRACE-REDACTED", "await_checks", nil)
    display = SymphonyElixir.SecretRedactor.redact(f.workspace)
    refute display == f.workspace
    assert :ok = RunIdentity.verify(f.workspace, f.ticket.run_id, f.issue.id, f.issue.identifier)
    assert :ok = DispatchAudit.ensure_available(f.workspace)
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(f.ticket.ledger_path)
    dispatches = Enum.filter(rows, &(&1["metadata"]["dispatch_id"] == f.ticket.dispatch_id))
    assert Enum.map(dispatches, & &1["event_type"]) == ["dispatch.requested", "dispatch.started", "dispatch.finished"]

    for event <- dispatches do
      assert event["metadata"]["workspace"] == display
      assert event["metadata"]["workspace_digest"] == workspace_digest(f.workspace)
    end

    transitions = Enum.filter(rows, &(&1["event_type"] in ["stage.transition.requested", "stage.transition"]))
    assert length(transitions) == 2

    for event <- transitions do
      binding = event["metadata"]["run_binding"]
      assert Map.keys(binding) |> Enum.sort() == Enum.sort(~w(run_id run_identity_event_id run_identity_ledger_path workspace workspace_digest))
      assert binding["run_id"] == f.ticket.run_id
      assert binding["workspace"] == display
      assert binding["workspace_digest"] == workspace_digest(f.workspace)
    end

    before = bytes!(f)

    responses =
      for selector <- [%{"issue" => f.issue.id}, %{"run" => f.ticket.run_id}, %{"workspace" => f.workspace}, %{"pr" => f.pr}] do
        get(build_conn(), "/api/v1/traceability?" <> URI.encode_query(selector)) |> json_response(200)
      end

    assert length(Enum.uniq(responses)) == 1
    [payload | _] = responses
    assert payload["identity"]["run_id"] == f.ticket.run_id
    assert payload["identity"]["workspace"] == display
    assert payload["links"]["workspace"] == nil
    assert payload["links"]["run"] == "/api/v1/traceability?" <> URI.encode_query(%{"run" => f.ticket.run_id})
    assert json_response(get(build_conn(), payload["links"]["run"]), 200) == payload
    refute Jason.encode!(payload) =~ "traceability-workspace-sentinel"

    for url <- Map.values(payload["links"]), is_binary(url) do
      refute URI.decode(url) =~ "traceability-workspace-sentinel"
    end

    assert payload["result"]["stage"] == "await_checks"
    assert [%{"finished" => %{"event_type" => "dispatch.finished"}}] = payload["evidence"]["dispatches"]
    assert bytes!(f) == before
  end

  for {label, digest} <- [{"nil", nil}, {"empty", ""}, {"wrong", String.duplicate("0", 64)}] do
    @tag supplied_digest: digest
    test "present #{label} dispatch digest cannot fall back to matching literal display", c do
      f = admitted!("TRACE-DISPATCH-DIGEST", "await_checks", nil)
      assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(f.ticket.ledger_path)

      rows =
        Enum.map(rows, fn row ->
          if row["metadata"]["dispatch_id"] == f.ticket.dispatch_id do
            assert row["metadata"]["workspace"] == f.workspace
            put_in(row, ["metadata", "workspace_digest"], c.supplied_digest)
          else
            row
          end
        end)

      File.write!(f.ticket.ledger_path, Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
      before = bytes!(f)

      assert {:error, 409, %{error: %{code: "dispatch_incomplete", cause: "dispatch_reference_mismatch"}}} =
               Presenter.traceability_payload(%{"run" => f.ticket.run_id})

      assert bytes!(f) == before
    end
  end

  test "historical dispatch without digest still requires its exact literal workspace" do
    f = admitted!("TRACE-DISPATCH-LITERAL", "await_checks", nil)
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(f.ticket.ledger_path)

    rows =
      Enum.map(rows, fn row ->
        if row["metadata"]["dispatch_id"] == f.ticket.dispatch_id, do: update_in(row, ["metadata"], &Map.delete(&1, "workspace_digest")), else: row
      end)

    File.write!(f.ticket.ledger_path, Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
    before = bytes!(f)
    assert {:ok, payload} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    assert payload.identity.run_id == f.ticket.run_id
    assert bytes!(f) == before

    rows =
      Enum.map(rows, fn row ->
        if row["metadata"]["dispatch_id"] == f.ticket.dispatch_id, do: put_in(row, ["metadata", "workspace"], "different"), else: row
      end)

    File.write!(f.ticket.ledger_path, Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
    changed = bytes!(f)

    assert {:error, 409, %{error: %{code: "dispatch_incomplete", cause: "dispatch_reference_mismatch"}}} =
             Presenter.traceability_payload(%{"run" => f.ticket.run_id})

    assert bytes!(f) == changed
  end

  for {label, digest} <- [{"nil", nil}, {"empty", ""}, {"wrong", String.duplicate("0", 64)}] do
    @tag supplied_digest: digest
    test "present #{label} stage digest cannot fall back to literal or execution provenance", c do
      f = admitted!("TRACE-STAGE-DIGEST", "await_checks", nil)
      assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(f.ticket.ledger_path)

      rows =
        Enum.map(rows, fn row ->
          if row["event_type"] in ["stage.transition.requested", "stage.transition"] do
            assert row["metadata"]["run_binding"]["workspace"] == f.workspace
            assert row["metadata"]["execution"]["run_id"] == f.ticket.run_id
            put_in(row, ["metadata", "run_binding", "workspace_digest"], c.supplied_digest)
          else
            row
          end
        end)

      File.write!(f.ticket.ledger_path, Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
      before = bytes!(f)

      assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_material_mismatch"}}} =
               Presenter.traceability_payload(%{"run" => f.ticket.run_id})

      assert bytes!(f) == before
    end
  end

  test "historical four-field stage binding remains valid without a digest" do
    f = admitted!("TRACE-STAGE-LITERAL", "await_checks", nil)
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(f.ticket.ledger_path)

    rows =
      Enum.map(rows, fn row ->
        if row["event_type"] in ["stage.transition.requested", "stage.transition"], do: update_in(row, ["metadata", "run_binding"], &Map.delete(&1, "workspace_digest")), else: row
      end)

    File.write!(f.ticket.ledger_path, Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
    assert {:ok, persisted_rows, _} = RunLedger.CheckedStorage.entries_checked(f.ticket.ledger_path)
    [event] = Enum.filter(persisted_rows, &(&1["event_type"] == "stage.transition"))

    assert Map.keys(event["metadata"]["run_binding"]) |> Enum.sort() ==
             Enum.sort(~w(run_id run_identity_event_id run_identity_ledger_path workspace))

    before = bytes!(f)
    assert {:ok, payload} = Presenter.traceability_payload(%{"run" => f.ticket.run_id})
    assert payload.evidence.last_event["event_id"] == event["event_id"]
    assert payload.identity.run_id == f.ticket.run_id
    assert bytes!(f) == before
  end

  test "historical four-field stage binding rejects extra fields instead of using execution" do
    f = admitted!("TRACE-STAGE-EXTRA", "await_checks", nil)
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(f.ticket.ledger_path)

    rows =
      Enum.map(rows, fn row ->
        if row["event_type"] in ["stage.transition.requested", "stage.transition"],
          do: update_in(row, ["metadata", "run_binding"], &(&1 |> Map.delete("workspace_digest") |> Map.put("extra", "not-a-binding-field"))),
          else: row
      end)

    File.write!(f.ticket.ledger_path, Enum.map(rows, &(Jason.encode!(&1) <> "\n")))
    before = bytes!(f)

    assert {:error, 409, %{error: %{code: "snapshot_incomplete", cause: "last_ledger_material_mismatch"}}} =
             Presenter.traceability_payload(%{"run" => f.ticket.run_id})

    assert bytes!(f) == before
  end

  defp workspace_digest(workspace), do: :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)

  defp admitted!(identifier, stage, reason, pr \\ nil) do
    issue = %{id: "issue-" <> identifier, identifier: identifier}
    workspace = Workspace.path_for_issue(issue)
    assert :ok = RunStateStore.save(workspace, %{issue_id: issue.id, issue_identifier: identifier, stage: "implement"})
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, identifier, "traceability-owner")
    attrs = %{issue_id: issue.id, issue_identifier: identifier, stage: "implement", metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}
    assert {:ok, source, _} = RunStateStore.read_admission_source(workspace, issue)
    assert {:ok, ticket, raw} = DispatchAudit.begin(workspace, attrs, source)
    pr = pr || "https://example.invalid/pr/" <> identifier
    assert {:ok, _state} = RunStateStore.transition_current(%{ticket: ticket, lease_token: acquired.token}, RunStateStore.material_projection(raw), stage, %{pr_url: pr, stop_reason: reason})
    assert :ok = DispatchAudit.finish(ticket, :not_started)
    assert {:ok, :released} = LeaseManager.release_token(acquired.token)
    %{issue: issue, workspace: workspace, ticket: ticket, attrs: attrs, pr: pr}
  end

  defp legacy_admitted!(identifier) do
    issue = %{id: "issue-" <> identifier, identifier: identifier}
    workspace = Workspace.path_for_issue(issue)
    pr = "https://example.invalid/pr/" <> identifier
    assert :ok = RunStateStore.save(workspace, %{issue_id: issue.id, issue_identifier: identifier, stage: "implement"})
    assert {:ok, legacy} = RunStateStore.transition(workspace, "await_checks", %{pr_url: pr})
    assert {:ok, legacy_event} = RunLedger.fetch_entry_checked(legacy.last_ledger_event_id)
    refute Map.has_key?(legacy_event["metadata"], "execution")
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, identifier, "traceability-legacy-owner")
    attrs = %{issue_id: issue.id, issue_identifier: identifier, stage: "await_checks", metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}
    assert {:ok, source, _} = RunStateStore.read_admission_source(workspace, issue)
    assert {:ok, ticket, raw} = DispatchAudit.begin(workspace, attrs, source)
    assert raw["last_ledger_event_id"] == legacy_event["event_id"]
    assert :ok = DispatchAudit.finish(ticket, :not_started)
    assert {:ok, :released} = LeaseManager.release_token(acquired.token)
    %{issue: issue, workspace: workspace, ticket: ticket, attrs: attrs, pr: pr, legacy_event: legacy_event}
  end

  defp bytes!(f), do: {File.read!(RunStateStore.state_path(f.workspace)), File.read!(RunLedger.ledger_file_path())}
end
