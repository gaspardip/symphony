defmodule SymphonyElixir.RunIdentityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, RunIdentity, RunLedger, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "run-identity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.fetch_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "runtime.log"))
    issue = %{id: "identity-1", identifier: "IDENTITY-1"}

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_create: "printf 'created\\n' >> hook-count; mkdir -p .git"
    )

    on_exit(fn ->
      File.rm_rf!(root)

      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :log_file, value)
        :error -> Application.delete_env(:symphony_elixir, :log_file)
      end
    end)

    %{root: root, issue: issue, workspace: Workspace.path_for_issue(issue), attrs: %{issue_id: issue.id, issue_identifier: issue.identifier, metadata: %{owner: "identity-owner", epoch: 1}}}
  end

  test "I1-01 defaults and legacy reads create no identity or writes", c do
    state = RunStateStore.load_or_default(c.workspace, c.issue)
    refute Map.has_key?(state, :run_id)
    refute File.exists?(c.workspace)
    assert :ok = RunStateStore.save(c.workspace, state)
    before = File.read!(RunStateStore.state_path(c.workspace))
    assert {:ok, ^state} = RunStateStore.load(c.workspace)
    refute Map.has_key?(RunStateStore.load_or_default(c.workspace, c.issue), :run_id)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    refute File.exists?(RunLedger.ledger_file_path())
  end

  test "I1-02 admission persists identity before bootstrap and executes after-create exactly once", c do
    assert {:ok, ticket} = DispatchAudit.begin(c.workspace, c.attrs)
    assert {:ok, snapshot} = RunStateStore.load(c.workspace)
    assert snapshot.run_id == ticket.run_id
    assert {:ok, identity_event} = RunLedger.fetch_entry_checked(snapshot.run_identity_event_id)
    raw_snapshot = File.read!(RunStateStore.state_path(c.workspace)) |> Jason.decode!()
    assert identity_event["metadata"]["snapshot_digest"] == RunStateStore.snapshot_digest(raw_snapshot)
    assert :ok = RunIdentity.verify(c.workspace, ticket.run_id, c.issue.id, c.issue.identifier)
    refute File.exists?(Path.join(c.workspace, "hook-count"))

    assert {:ok, workspace} = DispatchAudit.with_authorization(ticket, fn -> Workspace.create_for_issue(c.issue) end)
    assert workspace == c.workspace
    assert {:ok, ^workspace} = DispatchAudit.with_authorization(ticket, fn -> Workspace.create_for_issue(c.issue) end)
    assert File.read!(Path.join(workspace, "hook-count")) == "created\n"
    assert {:ok, restored} = RunStateStore.load(workspace)
    assert restored == snapshot
    assert :ok = DispatchAudit.finish(ticket, :normal)
  end

  test "I1-03 retry from a new coordinator preserves run and creates another dispatch", c do
    assert {:ok, first} = DispatchAudit.begin(c.workspace, c.attrs)
    assert :ok = DispatchAudit.finish(first, :normal)
    assert {:ok, second} = Task.async(fn -> DispatchAudit.begin(c.workspace, c.attrs) end) |> Task.await()
    assert first.run_id == second.run_id
    refute first.dispatch_id == second.dispatch_id
    assert Enum.count(rows(), &(&1["event_type"] == "run.identity.created")) == 1
    assert Enum.all?(Enum.filter(rows(), &String.starts_with?(&1["event_type"], "dispatch.")), &(&1["metadata"]["run_id"] == first.run_id))
    assert :ok = DispatchAudit.finish(second, :not_started)
  end

  test "I1-04 explicit adoption preserves legacy progress, consumption, approvals and old events", c do
    legacy = %{
      issue_id: c.issue.id,
      issue_identifier: c.issue.identifier,
      stage: "implement",
      implementation_turns: 9,
      review_approved: true,
      deploy_approved: true,
      token_usage: %{input_tokens: 90, output_tokens: 10, total_tokens: 100},
      custom_evidence: "retained"
    }

    assert :ok = RunStateStore.save(c.workspace, legacy)
    assert {:ok, previous} = RunStateStore.load(c.workspace)
    assert :ok = RunLedger.append("legacy.event", %{issue_id: c.issue.id})
    old_ledger = File.read!(RunLedger.ledger_file_path())
    assert {:ok, ticket} = DispatchAudit.begin(c.workspace, c.attrs)
    assert {:ok, adopted} = RunStateStore.load(c.workspace)
    assert Map.drop(adopted, [:run_id, :run_identity_event_id, :run_identity_ledger_path]) == previous
    assert String.starts_with?(File.read!(RunLedger.ledger_file_path()), old_ledger)
    assert Enum.any?(rows(), &(&1["event_type"] == "run.identity.adopted"))
    assert :ok = DispatchAudit.finish(ticket, :normal)
  end

  test "I1-05 concurrent admissions establish one effective identity", c do
    results = 1..5 |> Task.async_stream(fn _ -> DispatchAudit.begin(c.workspace, c.attrs) end) |> Enum.map(fn {:ok, result} -> result end)
    assert [{:ok, ticket}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, {:dispatch_audit_pending, _}}, &1)) == 4
    assert Enum.count(rows(), &(&1["event_type"] == "run.identity.created")) == 1
    assert :ok = DispatchAudit.finish(ticket, :not_started)
  end

  for {label, payload} <- [
        {"corrupt", "{broken"},
        {"pending", ~s({"run_identity_pending":{}})},
        {"invalid identity", ~s({"run_id":42})},
        {"contradictory issue", ~s({"issue_id":"other","issue_identifier":"IDENTITY-1","stage":"implement"})},
        {"contradictory identifier", ~s({"issue_id":"identity-1","issue_identifier":"OTHER","stage":"implement"})}
      ] do
    @tag snapshot_payload: payload
    test "I1-06 #{label} preserves bytes and blocks adoption and hooks", c do
      path = RunStateStore.state_path(c.workspace)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, c.snapshot_payload)
      assert {:error, _} = DispatchAudit.begin(c.workspace, c.attrs)
      assert File.read!(path) == c.snapshot_payload
      refute File.exists?(Path.join(c.workspace, "hook-count"))
      refute File.exists?(RunLedger.ledger_file_path())
    end
  end

  for event <- ["run.identity.requested", "run.identity.created", "dispatch.requested"] do
    @tag fault_event: event
    test "I1-07 ledger failure after #{event} prevents worker body and hooks", c do
      attach_fault(c.fault_event, :corrupt_ledger)
      assert {:error, _} = DispatchAudit.begin(c.workspace, c.attrs)
      assert {:error, _} = Workspace.create_for_issue(c.issue)
      assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.begin(c.workspace, c.attrs)
      refute File.exists?(Path.join(c.workspace, "hook-count"))
      refute Enum.any?(complete_rows(), &(&1["event_type"] == "dispatch.started"))
    end
  end

  test "I1-08 snapshot persistence failure leaves reservation and never authorizes", c do
    attach_fault("run.identity.requested", {:obstruct_snapshot, c.workspace})
    assert {:error, {:run_identity_write_failed, _}} = DispatchAudit.begin(c.workspace, c.attrs)
    assert {:error, _} = Workspace.create_for_issue(c.issue)
    assert File.read!(Path.join(c.workspace, ".symphony")) == "preserve-obstruction"
    refute Enum.any?(rows(), &(&1["event_type"] == "dispatch.started"))
  end

  test "I1-09 interruption after identity persistence leaves unreadable pending evidence", c do
    attach_fault("run.identity.created", {:kill, self()})
    {pid, ref} = spawn_monitor(fn -> DispatchAudit.begin(c.workspace, c.attrs) end)
    assert_receive {:identity_persisted, ^pid}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    path = RunStateStore.state_path(c.workspace)
    bytes = File.read!(path)
    assert {:error, :run_identity_pending} = RunStateStore.load(c.workspace)
    assert {:error, _} = DispatchAudit.begin(c.workspace, c.attrs)
    assert {:error, _} = Workspace.create_for_issue(c.issue)
    assert File.read!(path) == bytes
    refute File.exists?(Path.join(c.workspace, "hook-count"))
  end

  test "I1-10 stale writes preserve identity and replacements fail without changing bytes", c do
    assert {:ok, first} = DispatchAudit.begin(c.workspace, c.attrs)
    assert {:ok, state} = RunStateStore.load(c.workspace)
    assert :ok = RunStateStore.save(c.workspace, Map.drop(state, [:run_id, :run_identity_event_id, :run_identity_ledger_path]))
    assert {:ok, saved} = RunStateStore.load(c.workspace)
    assert saved.run_id == first.run_id
    before = File.read!(RunStateStore.state_path(c.workspace))
    assert {:error, :run_identity_conflict} = RunStateStore.save(c.workspace, %{state | run_id: "run_replacement"})
    assert {:error, :run_identity_conflict} = RunStateStore.save(c.workspace, %{state | issue_id: "different"})
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    assert :ok = DispatchAudit.finish(first, :normal)
  end

  test "I1-11 identity tampering before gate denies worker body", c do
    assert {:ok, ticket} = DispatchAudit.begin(c.workspace, c.attrs)
    path = RunStateStore.state_path(c.workspace)
    tampered = File.read!(path) |> Jason.decode!() |> Map.put("run_id", "run_different") |> Jason.encode!()
    File.write!(path, tampered)
    assert {:error, :run_identity_mismatch} = DispatchAudit.with_authorization(ticket, fn -> flunk("worker body executed") end)
    assert File.read!(path) == tampered
    refute File.exists?(Path.join(c.workspace, "hook-count"))
  end

  test "I1-12 a finished cycle remains closed and its identity unchanged", c do
    assert {:ok, ticket} = DispatchAudit.begin(c.workspace, c.attrs)
    assert :ok = DispatchAudit.finish(ticket, :normal)
    assert {:ok, _} = RunStateStore.transition(c.workspace, "done")
    before = File.read!(RunStateStore.state_path(c.workspace))
    assert {:error, {:persisted_stage_requires_explicit_resume, "done"}} = DispatchAudit.begin(c.workspace, c.attrs)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
  end

  for corruption <- [:missing_confirmation, :confirmation_issue, :intent_run, :changed_ledger] do
    @tag evidence_corruption: corruption
    test "I1-15 #{corruption} denies readmission without rewriting identity or ledger", c do
      assert {:ok, ticket} = DispatchAudit.begin(c.workspace, c.attrs)
      assert :ok = DispatchAudit.finish(ticket, :normal)
      snapshot = File.read!(RunStateStore.state_path(c.workspace))
      corrupt_identity_evidence(c.evidence_corruption, c.root)
      ledger = File.read!(RunLedger.ledger_file_path())
      assert {:error, _} = DispatchAudit.begin(c.workspace, c.attrs)
      assert File.read!(RunStateStore.state_path(c.workspace)) == snapshot
      assert File.read!(RunLedger.ledger_file_path()) == ledger
      refute File.exists?(Path.join(c.workspace, "hook-count"))
    end
  end

  test "I1-16 legacy finishing journal reconciles exact historical evidence without adding identity", c do
    marker = legacy_journal(c, "finishing")
    ledger = File.read!(RunLedger.ledger_file_path())
    assert :ok = DispatchAudit.reconcile_finished(c.workspace)
    assert :ok = DispatchAudit.ensure_available(c.workspace)
    assert File.read!(RunLedger.ledger_file_path()) == ledger
    assert {:ok, recorded} = RunLedger.fetch_entry_checked(marker["finished"]["event_id"])
    refute Map.has_key?(recorded["metadata"], "run_id")
    refute File.exists?(RunStateStore.state_path(c.workspace))
  end

  test "I1-17 legacy authorized journal cannot open a worker body or manufacture identity", c do
    marker = legacy_journal(c, "authorized")

    ticket = %{
      workspace: c.workspace,
      dispatch_id: marker["dispatch_id"],
      entry_event_id: marker["authorized"]["event_id"],
      owner: marker["owner"],
      epoch: marker["epoch"],
      ledger_path: marker["ledger_path"]
    }

    path = Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json")
    before = File.read!(path)
    ledger = File.read!(RunLedger.ledger_file_path())
    assert {:error, _} = DispatchAudit.with_authorization(ticket, fn -> flunk("legacy ticket executed") end)
    assert {:error, :dispatch_audit_not_finished} = DispatchAudit.reconcile_finished(c.workspace)
    assert File.read!(path) == before
    assert File.read!(RunLedger.ledger_file_path()) == ledger
    refute File.exists?(RunStateStore.state_path(c.workspace))
  end

  for mutation <- [:missing, :mismatched] do
    @tag journal_identity_mutation: mutation
    test "I1-18 v2 #{mutation} identity blocks authorization and reconciliation with bytes preserved", c do
      assert {:ok, ticket} = DispatchAudit.begin(c.workspace, c.attrs)
      path = Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json")
      marker = Jason.decode!(File.read!(path))
      assert marker["version"] == 2

      altered =
        case c.journal_identity_mutation do
          :missing -> Map.delete(marker, "run_id")
          :mismatched -> Map.put(marker, "run_id", "run_unrelated")
        end

      File.write!(path, Jason.encode!(altered))
      before = File.read!(path)
      ledger = File.read!(RunLedger.ledger_file_path())
      assert {:error, _} = DispatchAudit.with_authorization(ticket, fn -> flunk("invalid v2 ticket executed") end)
      assert {:error, _} = DispatchAudit.reconcile_finished(c.workspace)
      assert File.read!(path) == before
      assert File.read!(RunLedger.ledger_file_path()) == ledger
    end
  end

  defp legacy_journal(c, status) do
    metadata = %{dispatch_id: "dispatch_legacy", workspace: c.workspace, owner: "legacy-owner", epoch: 1}
    attrs = %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, metadata: metadata}
    {:ok, requested} = RunLedger.prepare_entry("dispatch.requested", attrs)
    {:ok, authorized} = RunLedger.prepare_entry("dispatch.started", attrs)
    {:ok, ^requested} = RunLedger.persist_prepared(requested)
    {:ok, ^authorized} = RunLedger.persist_prepared(authorized)

    marker = %{
      "version" => 1,
      "workspace" => c.workspace,
      "dispatch_id" => metadata.dispatch_id,
      "owner" => metadata.owner,
      "epoch" => 1,
      "ledger_path" => RunLedger.ledger_file_path(),
      "status" => status,
      "requested" => requested,
      "authorized" => authorized
    }

    marker =
      if status == "finishing" do
        finish_attrs = %{attrs | metadata: Map.merge(metadata, %{authorization_event_id: authorized.event_id, outcome: ":normal"})}
        {:ok, finished} = RunLedger.prepare_entry("dispatch.finished", finish_attrs)
        {:ok, ^finished} = RunLedger.persist_prepared(finished)
        Map.put(marker, "finished", finished)
      else
        marker
      end

    directory = DispatchAudit.marker_directory(c.workspace)
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "marker.json"), Jason.encode!(marker))
    Jason.decode!(Jason.encode!(marker))
  end

  defp corrupt_identity_evidence(:changed_ledger, root) do
    ledger = File.read!(RunLedger.ledger_file_path())
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "other/runtime.log"))
    File.mkdir_p!(Path.dirname(RunLedger.ledger_file_path()))
    File.write!(RunLedger.ledger_file_path(), ledger)
  end

  defp corrupt_identity_evidence(kind, _root) do
    altered =
      Enum.flat_map(rows(), fn event ->
        case {kind, event["event_type"]} do
          {:missing_confirmation, "run.identity.created"} -> []
          {:confirmation_issue, "run.identity.created"} -> [Map.put(event, "issue_id", "different-issue")]
          {:intent_run, "run.identity.requested"} -> [put_in(event, ["metadata", "run_id"], "run_other")]
          _ -> [event]
        end
      end)

    File.write!(RunLedger.ledger_file_path(), Enum.map_join(altered, "\n", &Jason.encode!/1) <> "\n")
  end

  def fault(_event, _measurements, metadata, {target, action}) do
    if metadata[:issue_id] == "identity-1" and metadata[:event_type] == target do
      case action do
        :corrupt_ledger ->
          File.write!(RunLedger.ledger_file_path(), "{torn", [:append])

        {:obstruct_snapshot, workspace} ->
          File.mkdir_p!(workspace)
          File.write!(Path.join(workspace, ".symphony"), "preserve-obstruction")

        {:kill, parent} ->
          send(parent, {:identity_persisted, self()})
          Process.exit(self(), :kill)
      end
    end
  end

  defp attach_fault(event, action) do
    id = "identity-fault-#{System.unique_integer([:positive])}"
    assert :ok = :telemetry.attach(id, [:symphony, :ledger, :event], &__MODULE__.fault/4, {event, action})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp rows, do: RunLedger.ledger_file_path() |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp complete_rows,
    do:
      RunLedger.ledger_file_path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, row} -> [row]
          {:error, _} -> []
        end
      end)
end
