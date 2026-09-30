defmodule SymphonyElixir.RunStateCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DeployAudit, DispatchAudit, LeaseManager, RunLedger, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "run-state-current-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "CURRENT-1")
    issue = %{id: "current-#{System.unique_integer([:positive])}", identifier: "CURRENT-1"}
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    raw = %{"issue_id" => issue.id, "issue_identifier" => issue.identifier, "stage" => "implement"}
    File.write!(RunStateStore.state_path(workspace), Jason.encode!(raw))
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "current-owner")
    attrs = %{issue_id: issue.id, issue_identifier: issue.identifier, stage: "implement", metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, raw: raw, token: acquired.token, attrs: attrs}
  end

  test "admission keeps raw field absence while deriving a view from that same read", c do
    before = File.read!(RunStateStore.state_path(c.workspace))
    assert {:ok, {:present, raw}, view} = RunStateStore.read_admission_source(c.workspace, c.issue)
    assert raw == c.raw
    refute Map.has_key?(raw, "policy_override")
    assert Map.has_key?(view, :policy_override)
    assert RunStateStore.material_projection(raw) == %{"stage" => "implement"}
    refute RunStateStore.material_projection(raw) == RunStateStore.material_projection(view)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before

    assert {:ok, ticket, admitted} = DispatchAudit.begin(c.workspace, c.attrs, {:present, raw})
    assert admitted == raw!(c.workspace)
    assert RunStateStore.material_projection(admitted) == RunStateStore.material_projection(raw)
    assert admitted["run_id"] == ticket.run_id
    refute Map.has_key?(admitted, "policy_override")
    refute Map.has_key?(admitted, "last_ledger_event_id")
    assert ticket.entry_event_id != admitted["last_ledger_event_id"]
    authority = %{ticket: ticket, lease_token: c.token}
    assert {:ok, same_stage} = RunStateStore.transition_current(authority, RunStateStore.material_projection(admitted), "implement", %{policy_override: "accepted"})
    assert Jason.decode!(Jason.encode!(same_stage)) == raw!(c.workspace)
    refute Map.has_key?(same_stage, :last_ledger_event_id)
  end

  test "missing admission stays missing until I1 creates its canonical snapshot", c do
    File.rm!(RunStateStore.state_path(c.workspace))
    assert {:ok, :missing, view} = RunStateStore.read_admission_source(c.workspace, c.issue)
    assert view.stage == "checkout"
    refute File.exists?(RunStateStore.state_path(c.workspace))
    assert {:ok, ticket, raw} = DispatchAudit.begin(c.workspace, %{c.attrs | stage: "checkout"}, :missing)
    assert raw == raw!(c.workspace)
    assert raw["stage"] == "checkout"
    assert raw["run_id"] == ticket.run_id
    assert raw["lease_owner"] == nil
    authority = %{ticket: ticket, lease_token: c.token}
    assert {:ok, _state} = RunStateStore.ensure_current(authority, RunStateStore.material_projection(raw))
  end

  test "missing admission never adopts an alternate bootstrap snapshot", c do
    staged = Path.join(c.root, ".CURRENT-1.bootstrap-kept")
    File.mkdir_p!(staged)
    File.rename!(RunStateStore.state_path(c.workspace), Path.join(staged, "run_state.json"))
    assert {:ok, _legacy_state} = RunStateStore.load(c.workspace)
    assert {:error, :admission_bootstrap_present} = RunStateStore.read_admission_source(c.workspace, c.issue)
    assert {:error, :admission_bootstrap_present} = DispatchAudit.begin(c.workspace, %{c.attrs | stage: "checkout"}, :missing)
    assert :ok = DispatchAudit.ensure_available(c.workspace)
    refute File.exists?(RunStateStore.state_path(c.workspace))
  end

  for {field, value} <- [
        stage: "validate",
        last_ledger_event_id: "changed-event",
        review_claims: %{"C-1" => %{status: "accepted"}},
        review_threads: %{"T-1" => %{status: "resolved"}},
        pr_url: "https://example.invalid/pull/1",
        repo_url: "https://example.invalid/repo",
        policy_pack: "changed",
        effective_policy_class: "changed",
        stop_reason: %{code: "control"},
        implementation_turns: 1,
        policy_override: "changed",
        review_return_stage: "validate"
      ] do
    @tag material_change: {field, value}
    test "admission rejects changed #{field} before reserving a marker", c do
      assert {:ok, _} = RunStateStore.update(c.workspace, & &1)
      assert {:ok, source, _view} = RunStateStore.read_admission_source(c.workspace, c.issue)
      {field, value} = c.material_change
      assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, field, value))
      before = evidence(c)
      assert {:error, {:stale_execution, :admission_source_changed}} = DispatchAudit.begin(c.workspace, c.attrs, source)
      assert evidence(c) == before
      assert :ok = DispatchAudit.ensure_available(c.workspace)
    end
  end

  test "admission preserves intervening usage, lease refresh metadata and diagnostics", c do
    assert {:ok, _} = RunStateStore.update(c.workspace, & &1)
    assert {:ok, source, _view} = RunStateStore.read_admission_source(c.workspace, c.issue)
    assert {:ok, _} = RunStateStore.record_token_usage(c.workspace, c.issue, usage(50))
    assert {:ok, refreshed} = LeaseManager.refresh_token(c.token)
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(refreshed))
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :last_decision_summary, "fresh diagnostic"))
    current = raw!(c.workspace)
    assert {:ok, ticket, admitted} = DispatchAudit.begin(c.workspace, c.attrs, source)
    assert Map.drop(admitted, ~w(run_id run_identity_event_id run_identity_ledger_path)) == current
    assert admitted["token_usage"]["total_tokens"] == 50
    assert admitted["lease_updated_at"] == refreshed["updated_at"]
    assert admitted["run_id"] == ticket.run_id
  end

  test "admission rejects changed existence or identity and a different effective dispatch stage", c do
    assert {:ok, source, _view} = RunStateStore.read_admission_source(c.workspace, c.issue)
    assert {:error, {:stale_execution, :admission_stage_changed}} = DispatchAudit.begin(c.workspace, %{c.attrs | stage: "checkout"}, source)
    File.rm!(RunStateStore.state_path(c.workspace))
    assert {:error, {:stale_execution, :admission_source_changed}} = DispatchAudit.begin(c.workspace, c.attrs, source)
    assert {:ok, :missing, _view} = RunStateStore.read_admission_source(c.workspace, c.issue)
    File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(c.raw))
    assert {:error, {:stale_execution, :admission_source_changed}} = DispatchAudit.begin(c.workspace, c.attrs, :missing)
    File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(%{c.raw | "issue_identifier" => "OTHER"}))
    assert {:error, :run_identity_issue_mismatch} = DispatchAudit.begin(c.workspace, c.attrs, source)
    assert :ok = DispatchAudit.ensure_available(c.workspace)
  end

  test "a checked delta preserves accepted usage and current lease metadata", c do
    {authority, expected} = admit!(c)
    assert {:ok, consumed} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage(90), authority, expected)
    assert consumed.token_usage == usage(90)
    assert {:ok, refreshed} = LeaseManager.refresh_token(c.token)
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(refreshed))
    assert {:ok, state} = RunStateStore.update_current(authority, expected, %{review_claims: %{"C-1" => %{status: "accepted"}}})
    assert state.token_usage == usage(90)
    assert state.lease_updated_at == refreshed["updated_at"]
    assert state.lease_generation == c.token.lease_generation
    next = RunStateStore.material_projection(state)
    assert {:ok, transition} = RunStateStore.transition_current(authority, next, "validate", %{reason: "checked continuation"})
    assert transition.token_usage == usage(90)
    assert transition.lease_updated_at == refreshed["updated_at"]
    assert transition.stage == "validate"
    assert {:ok, _} = RunStateStore.ensure_current(authority, RunStateStore.material_projection(transition))
    assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.ensure_current(authority, expected)
  end

  for {field, value} <- [review_claims: %{"C-1" => %{status: "accepted"}}, review_threads: %{"T-1" => %{status: "resolved"}}, policy_override: "changed", review_return_stage: "validate"] do
    @tag material_change: {field, value}
    test "same-stage #{field} control rejects every checked writer before audit or checkpoint", c do
      {authority, expected} = admit!(c)
      {field, value} = c.material_change
      assert {:ok, controlled} = RunStateStore.update(c.workspace, &Map.put(&1, field, value))
      assert controlled.stage == "implement"
      assert controlled.last_ledger_event_id == nil
      before = evidence(c)
      assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.ensure_current(authority, expected)
      assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.update_current(authority, expected, %{last_decision_summary: "old"})
      assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.transition_current(authority, expected, "validate", %{})
      assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage(200), authority, expected)
      assert evidence(c) == before
    end
  end

  test "protected or whole-state attrs cannot replace authority, stage, event or consumption", c do
    {authority, expected} = admit!(c)
    assert {:ok, state} = RunStateStore.ensure_current(authority, expected)
    before = evidence(c)

    for attrs <- [
          %{stage: "blocked"},
          %{last_ledger_event_id: "replacement"},
          %{token_usage: usage(7)},
          %{run_id: "foreign"},
          %{lease_owner: "foreign"},
          %{lease_generation: "foreign"},
          %{lease_token: c.token},
          %{audit_pending: %{}},
          %{dispatch_id: "foreign"},
          %{issue_id: "foreign"},
          %{"review_threads" => %{}},
          %{implementation_turns: -1},
          %{review_claims: nil},
          state
        ] do
      assert {:error, :invalid_current_attrs} = RunStateStore.update_current(authority, expected, attrs)
      assert {:error, :invalid_current_attrs} = RunStateStore.transition_current(authority, expected, "validate", attrs)
      assert evidence(c) == before
    end

    assert {:error, :invalid_current_stage} = RunStateStore.transition_current(authority, expected, "invented", %{})
    assert {:ok, updated} = RunStateStore.update_current(authority, expected, %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, last_decision_summary: "valid delta"})
    assert updated.issue_id == c.issue.id
    assert updated.last_decision_summary == "valid delta"
  end

  test "two cooperating transitions from one expected state admit exactly one audit operation", c do
    {authority, expected} = admit!(c)
    before_count = length(RunLedger.recent_entries())
    parent = self()

    tasks =
      for stage <- ["validate", "review_verification"] do
        Task.async(fn ->
          send(parent, {:writer_ready, self()})

          receive do
            :write -> RunStateStore.transition_current(authority, expected, stage, %{})
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:writer_ready, ^pid}, 5_000
    end

    Enum.each(tasks, &send(&1.pid, :write))
    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:stale_execution, :material_state_changed}}, &1)) == 1
    assert length(RunLedger.recent_entries()) == before_count + 2
    assert {:ok, state} = RunStateStore.load(c.workspace)
    assert state.stage in ["validate", "review_verification"]
    refute Map.has_key?(state, :audit_pending)
  end

  for mutation <- [:missing, :corrupt, :pending, :partial_identity] do
    @tag snapshot_mutation: mutation
    test "#{mutation} canonical snapshot rejects continuation without default or staging adoption", c do
      {authority, expected} = admit!(c)
      path = RunStateStore.state_path(c.workspace)

      case c.snapshot_mutation do
        :missing ->
          staged = Path.join(c.root, ".CURRENT-1.bootstrap-evidence")
          File.mkdir_p!(staged)
          File.rename!(path, Path.join(staged, "run_state.json"))
          assert {:ok, _} = RunStateStore.load(c.workspace)

        :corrupt ->
          File.write!(path, "{invalid")

        :pending ->
          File.write!(path, Jason.encode!(Map.put(raw!(c.workspace), "audit_pending", %{"operation_id" => "pending-operation"})))

        :partial_identity ->
          File.write!(path, Jason.encode!(Map.delete(raw!(c.workspace), "run_identity_event_id")))
      end

      before = evidence(c)
      assert {:error, {:stale_execution, _}} = RunStateStore.ensure_current(authority, expected)
      assert {:error, {:stale_execution, _}} = RunStateStore.transition_current(authority, expected, "validate", %{})
      assert {:error, {:stale_execution, _}} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage(200), authority, expected)
      assert evidence(c) == before
    end
  end

  test "foreign token, ticket and issue inputs cannot use a current material projection", c do
    {authority, expected} = admit!(c)
    before = evidence(c)
    foreign_token = %{c.token | lease_generation: "foreign-generation"}
    foreign_ticket = %{authority.ticket | dispatch_id: "foreign-dispatch"}
    assert {:error, {:stale_execution, _}} = RunStateStore.ensure_current(%{authority | lease_token: foreign_token}, expected)
    assert {:error, {:stale_execution, _}} = RunStateStore.ensure_current(%{authority | ticket: foreign_ticket}, expected)
    assert {:error, {:stale_execution, _}} = RunStateStore.record_token_usage_current(c.workspace, %{c.issue | identifier: "FOREIGN"}, usage(200), authority, expected)
    assert evidence(c) == before
  end

  test "a known own-stop receipt permits only final monotonic usage on its exact blocked state", c do
    {authority, expected} = admit!(c)
    assert {:ok, _} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage(100), authority, expected)
    assert {:ok, stopped} = RunStateStore.transition_current(authority, expected, "blocked", %{stop_reason: %{code: "token_budget", summary: "own stop"}})
    receipt = receipt(expected, stopped)
    before = evidence(c)
    assert {:error, {:stale_execution, {:persisted_stage_requires_explicit_resume, "blocked"}}} = RunStateStore.ensure_current(authority, receipt.next)
    assert {:error, {:stale_execution, _}} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage(120), authority, receipt.next)
    assert evidence(c) == before
    assert {:ok, final} = RunStateStore.record_final_token_usage_current(c.workspace, c.issue, usage(120), authority, receipt)
    assert final.stage == "blocked"
    assert final.stop_reason == stopped.stop_reason
    assert final.token_usage == usage(120)
    assert RunStateStore.material_projection(final) == receipt.next
    after_usage = evidence(c)
    assert Map.drop(after_usage, [:snapshot]) == Map.drop(before, [:snapshot])
    assert {:ok, duplicate} = RunStateStore.record_final_token_usage_current(c.workspace, c.issue, usage(90), authority, receipt)
    assert duplicate.token_usage == usage(120)
    assert evidence(c) == after_usage
  end

  for stage <- ["blocked", "done"] do
    @tag terminal_stage: stage
    test "confirming a known #{stage} CAS is read-only and cannot reopen execution", c do
      {authority, expected} = admit!(c)
      assert {:error, {:stale_execution, :invalid_terminal_precondition}} = RunStateStore.confirm_terminal_current(authority, expected)
      assert {:ok, stopped} = RunStateStore.transition_current(authority, expected, c.terminal_stage, %{stop_reason: if(c.terminal_stage == "blocked", do: %{code: "own_stop"})})
      next = RunStateStore.material_projection(stopped)
      before = evidence(c)
      assert {:error, :dispatch_context_missing} = DispatchAudit.current_ticket()
      assert :ok = RunStateStore.confirm_terminal_current(authority, next)
      assert {:error, :dispatch_context_missing} = DispatchAudit.current_ticket()
      assert {:error, {:stale_execution, {:persisted_stage_requires_explicit_resume, stage}}} = RunStateStore.ensure_current(authority, next)
      assert stage == c.terminal_stage
      assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.confirm_terminal_current(authority, Map.put(next, "policy_override", "foreign"))
      assert {:error, {:stale_execution, _}} = RunStateStore.confirm_terminal_current(%{authority | lease_token: %{c.token | lease_generation: "foreign"}}, next)
      assert evidence(c) == before
    end
  end

  test "changed next material and malformed receipts cannot authorize final usage", c do
    {authority, expected} = admit!(c)
    assert {:ok, stopped} = RunStateStore.transition_current(authority, expected, "blocked", %{stop_reason: %{code: "token_budget"}})
    receipt = receipt(expected, stopped)
    before = evidence(c)

    for invalid <- [nil, Map.delete(receipt, :previous), %{receipt | ordinal: 0}, %{receipt | next: expected}, %{receipt | outcome: :ok}] do
      assert {:error, :invalid_stop_receipt} = RunStateStore.record_final_token_usage_current(c.workspace, c.issue, usage(120), authority, invalid)
      assert evidence(c) == before
    end

    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "control"))
    controlled = evidence(c)
    assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.record_final_token_usage_current(c.workspace, c.issue, usage(120), authority, receipt)
    assert evidence(c) == controlled
  end

  test "checkpoint validation and write failures remain accounting errors rather than material conflicts", c do
    {authority, expected} = admit!(c)
    before = evidence(c)
    assert {:error, :invalid_token_usage} = RunStateStore.record_token_usage_current(c.workspace, c.issue, %{total_tokens: 2}, authority, expected)
    directory = Path.dirname(RunStateStore.state_path(c.workspace))
    File.chmod!(directory, 0o500)

    try do
      assert {:error, :eacces} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage(20), authority, expected)
    after
      File.chmod!(directory, 0o700)
    end

    assert evidence(c) == before
  end

  test "checked lifecycle keeps the one workspace lock across movement, shell hook and restore", c do
    {authority, expected} = admit!(c)
    precondition = %{authority: authority, expected: expected}
    staged = Path.join(c.root, ".CURRENT-1.bootstrap-lifecycle")
    hook = Path.join(c.workspace, "hook-ran")
    before = raw!(c.workspace)

    assert {:ok, :restored} =
             RunStateStore.with_readable_snapshot(c.workspace, precondition, fn ->
               contender =
                 Task.async(fn ->
                   lock = {{RunStateStore, Path.expand(c.workspace)}, self()}
                   acquired = :global.set_lock(lock, [node()], 0)
                   if acquired, do: :global.del_lock(lock, [node()])
                   acquired
                 end)

               refute Task.await(contender)
               File.rename!(Path.dirname(RunStateStore.state_path(c.workspace)), staged)
               refute File.exists?(RunStateStore.state_path(c.workspace))
               assert {"", 0} = System.cmd("/bin/sh", ["-c", "printf hook > hook-ran"], cd: c.workspace)
               File.rename!(staged, Path.dirname(RunStateStore.state_path(c.workspace)))
               {:ok, :restored}
             end)

    assert File.read!(hook) == "hook"
    assert raw!(c.workspace) == before
    refute File.exists?(staged)
  end

  test "lifecycle rejects a changed entry before its callback and preserves hook failure on postcheck conflict", c do
    {authority, expected} = admit!(c)
    assert {:ok, changed} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "control"))
    parent = self()

    assert {:error, {:stale_execution, :material_state_changed}} =
             RunStateStore.with_readable_snapshot(c.workspace, %{authority: authority, expected: expected}, fn -> send(parent, :unexpected_hook) end)

    refute_received :unexpected_hook
    current = RunStateStore.material_projection(changed)

    assert {:error, {:stale_execution, {:lifecycle_result, {:error, :hook_failed}, :material_state_changed}}} =
             RunStateStore.with_readable_snapshot(c.workspace, %{authority: authority, expected: current}, fn ->
               File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(Map.put(raw!(c.workspace), "review_return_stage", "validate")))
               {:error, :hook_failed}
             end)

    assert raw!(c.workspace)["review_return_stage"] == "validate"
  end

  for conflict <- [false, true] do
    @tag deploy_conflict: conflict
    test "checked deploy bridge #{if conflict, do: "rejects changed material", else: "retains its state and continuation"}", c do
      assert {:ok, _} = RunStateStore.transition(c.workspace, "deploy_preview", %{})
      {authority, expected} = admit!(%{c | attrs: %{c.attrs | stage: "deploy_preview"}})
      assert {:ok, deploy} = DeployAudit.begin(c.workspace, %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: "deploy_preview", command: "test-only"})
      assert :ok = DeployAudit.record_result(deploy, %{status: :passed, command: "test-only", output: "observed"})

      if c.deploy_conflict do
        assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :review_threads, %{"T-1" => %{status: "control"}}))
        before = evidence(c)
        deploy_before = File.read!(Path.join(DeployAudit.marker_directory(c.workspace), "marker.json"))
        assert {:error, {:stale_execution, :material_state_changed}} = RunStateStore.transition_deploy(deploy, "post_deploy_verify", %{}, %{authority: authority, expected: expected})
        assert evidence(c) == before
        assert File.read!(Path.join(DeployAudit.marker_directory(c.workspace), "marker.json")) == deploy_before
      else
        assert {:ok, state, continuation} = RunStateStore.transition_deploy(deploy, "post_deploy_verify", %{last_decision_summary: "confirmed"}, %{authority: authority, expected: expected})
        assert state.stage == "post_deploy_verify"
        assert continuation.event["event_id"] == state.last_ledger_event_id
        assert continuation.event["metadata"]["deploy_operation_id"] == deploy.operation_id
        assert :ok = DeployAudit.finish(deploy, continuation)
        assert {:ok, _} = RunStateStore.ensure_current(authority, RunStateStore.material_projection(state))
      end
    end
  end

  defp admit!(c) do
    assert {:ok, _} = RunStateStore.update(c.workspace, & &1)
    assert {:ok, source, _view} = RunStateStore.read_admission_source(c.workspace, c.issue)
    assert {:ok, ticket, raw} = DispatchAudit.begin(c.workspace, c.attrs, source)
    {%{ticket: ticket, lease_token: c.token}, RunStateStore.material_projection(raw)}
  end

  defp raw!(workspace), do: workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp usage(total), do: %{input_tokens: total, output_tokens: 0, total_tokens: total}

  # Storage trusts the owner's authenticated receipt; worker/owner provenance is tested at that boundary.
  defp receipt(previous, state),
    do: %{previous: previous, next: RunStateStore.material_projection(state), binding: {SymphonyElixir.AgentProvider.Claude, :session, "captured-session"}, ordinal: 1, outcome: {:stop, :token_budget}}

  defp evidence(c) do
    %{
      snapshot: File.read(RunStateStore.state_path(c.workspace)),
      ledger: File.read(c.token.storage.ledger_path),
      lease: File.read(c.token.storage.lease_path),
      dispatch: File.read(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json"))
    }
  end
end
