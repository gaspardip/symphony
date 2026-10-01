defmodule SymphonyElixir.RunStateConcurrencyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RunLedger, RunStateStore}

  setup do
    workspace = Path.join(System.tmp_dir!(), "run-state-concurrency-#{System.unique_integer([:positive])}")
    issue = %Issue{id: "concurrent-state", identifier: "CONCURRENT-STATE", state: "In Progress"}

    assert {:ok, _} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace, issue: issue}
  end

  for identity_mode <- [:legacy, :identified] do
    @tag identity_mode: identity_mode
    test "lease generation roundtrip preserves #{identity_mode} identity and consumption", context do
      identity_fields = [:run_id, :run_identity_event_id, :run_identity_ledger_path]

      execution =
        if context.identity_mode == :identified do
          assert {:ok, acquired} = SymphonyElixir.LeaseManager.acquire(context.issue.id, context.issue.identifier, "roundtrip-owner")
          on_exit(fn -> assert {:ok, :released} = SymphonyElixir.LeaseManager.release_token(acquired.token) end)

          assert {:ok, ticket} =
                   SymphonyElixir.DispatchAudit.begin(context.workspace, %{
                     issue_id: context.issue.id,
                     issue_identifier: context.issue.identifier,
                     metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}
                   })

          %{ticket: ticket, lease_token: acquired.token}
        end

      assert {:ok, before} = RunStateStore.load(context.workspace)
      identity = Map.take(before, identity_fields)

      case context.identity_mode do
        :legacy ->
          assert identity == %{}

        :identified ->
          assert map_size(identity) == 3
          assert Enum.all?(identity, fn {_key, value} -> is_binary(value) and value != "" end)
      end

      usage = %{input_tokens: 17, output_tokens: 3, total_tokens: 20}

      consumed =
        case execution do
          nil ->
            assert {:ok, consumed} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
            consumed

          %{ticket: ticket} ->
            assert {:ok, consumed} = RunStateStore.record_token_usage(context.workspace, context.issue, usage, execution)
            assert :ok = SymphonyElixir.DispatchAudit.finish(ticket, :not_started)
            consumed
        end

      assert Map.take(consumed, identity_fields) == identity
      attrs = %{lease_owner: "owner", lease_epoch: 2, lease_version: 2, lease_generation: "generation", lease_updated_at: DateTime.to_iso8601(DateTime.utc_now())}
      assert {:ok, synced} = RunStateStore.sync_lease(context.workspace, context.issue, attrs)
      assert Map.take(synced, identity_fields) == identity
      assert synced.token_usage == consumed.token_usage
      assert {:ok, loaded} = RunStateStore.load(context.workspace)
      assert loaded.lease_version == 2
      assert loaded.lease_generation == "generation"
      assert Map.take(loaded, identity_fields) == identity
      assert loaded.token_usage == consumed.token_usage
      assert {:ok, cleared} = RunStateStore.clear_lease(context.workspace)
      assert cleared.lease_generation == nil
      assert cleared.lease_version == nil
      assert cleared.token_usage == consumed.token_usage
      assert Map.take(cleared, identity_fields) == identity
    end
  end

  test "a blocked transition waits for the complete update and preserves both changes", %{workspace: workspace} do
    updater = paused_update(workspace, &Map.put(&1, :last_validation, %{status: "passed"}))
    assert_update_holds_lock(workspace)
    parent = self()

    transition =
      Task.async(fn ->
        send(parent, :transition_started)

        RunStateStore.transition(workspace, "blocked", %{
          last_rule_id: "runtime.environment",
          last_decision_summary: "Explicit fixture blocker",
          next_human_action: "Repair the fixture environment"
        })
      end)

    assert_receive :transition_started
    assert Task.yield(transition, 0) == nil
    send(updater.pid, :continue_update)
    assert {:ok, _} = Task.await(updater)
    assert {:ok, _} = Task.await(transition)
    assert {:ok, persisted} = RunStateStore.load(workspace)
    assert persisted.stage == "blocked"
    assert persisted.last_rule_id == "runtime.environment"
    assert persisted.next_human_action == "Repair the fixture environment"
    assert persisted.last_validation.status == "passed"
    assert Enum.any?(RunLedger.recent_entries(), &(&1["event"] == "stage.transition" and &1["stage"] == "blocked"))
    assert is_binary(persisted.last_ledger_event_id)
  end

  for operation <- [:sync_lease, :clear_lease, :record_token_usage] do
    test "#{operation} preserves a diagnostic committed by a concurrent update", context do
      updater =
        paused_update(context.workspace, fn state ->
          Map.merge(state, %{
            stage: "blocked",
            last_rule_id: "runtime.environment",
            last_decision_summary: "Explicit fixture blocker",
            next_human_action: "Repair the fixture environment"
          })
        end)

      assert_update_holds_lock(context.workspace)
      parent = self()

      contender =
        Task.async(fn ->
          send(parent, :operation_started)
          mutate(unquote(operation), context)
        end)

      assert_receive :operation_started
      assert Task.yield(contender, 0) == nil
      send(updater.pid, :continue_update)
      assert {:ok, _} = Task.await(updater)
      assert {:ok, _} = Task.await(contender)
      assert {:ok, persisted} = RunStateStore.load(context.workspace)
      assert persisted.stage == "blocked"
      assert persisted.last_rule_id == "runtime.environment"
      assert persisted.last_decision_summary == "Explicit fixture blocker"
      assert persisted.next_human_action == "Repair the fixture environment"
    end
  end

  for identity_mode <- [:legacy, :identified] do
    @tag lease_sync_identity_mode: identity_mode
    test "lease synchronization preserves absent material fields for #{identity_mode} RAW", context do
      assert {:ok, previous} = RunStateStore.load(context.workspace)
      absent = [:implementation_turns, :policy_override, :review_return_stage]
      sparse = previous |> Map.drop(absent) |> Map.put(:resume_context, %{retained: "lease-sync"})
      path = RunStateStore.state_path(context.workspace)
      File.write!(path, Jason.encode!(sparse))

      authority =
        if context.lease_sync_identity_mode == :identified do
          assert {:ok, acquired} = SymphonyElixir.LeaseManager.acquire(context.issue.id, context.issue.identifier, "sparse-sync-owner")
          assert {:ok, source, _view} = RunStateStore.read_admission_source(context.workspace, context.issue)

          assert {:ok, ticket, _admitted} =
                   SymphonyElixir.DispatchAudit.begin(
                     context.workspace,
                     %{issue_id: context.issue.id, issue_identifier: context.issue.identifier, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}},
                     source
                   )

          on_exit(fn ->
            assert :ok = SymphonyElixir.DispatchAudit.finish(ticket, :not_started)
            assert {:ok, :released} = SymphonyElixir.LeaseManager.release_token(acquired.token)
          end)

          %{ticket: ticket, lease_token: acquired.token}
        end

      before = path |> File.read!() |> Jason.decode!()
      expected = RunStateStore.material_projection(before)
      Enum.each(absent, fn field -> refute Map.has_key?(before, Atom.to_string(field)) end)
      ledger = File.read!(RunLedger.ledger_file_path())

      attrs =
        if authority do
          assert {:ok, _} = RunStateStore.ensure_current(authority, expected)
          assert {:ok, refreshed} = SymphonyElixir.LeaseManager.refresh_token(authority.lease_token)
          SymphonyElixir.LeaseManager.snapshot_for_state(refreshed)
        else
          %{lease_owner: "sparse-sync-owner", lease_epoch: 2, lease_updated_at: "renewed"}
        end

      assert {:ok, synced} = RunStateStore.sync_lease(context.workspace, context.issue, attrs)
      after_sync = path |> File.read!() |> Jason.decode!()
      assert RunStateStore.material_projection(synced) == expected
      assert RunStateStore.material_projection(after_sync) == expected
      Enum.each(absent, fn field -> refute Map.has_key?(synced, field) end)
      Enum.each(absent, fn field -> refute Map.has_key?(after_sync, Atom.to_string(field)) end)
      assert synced.resume_context == %{retained: "lease-sync"}
      assert after_sync["resume_context"] == before["resume_context"]
      assert synced.lease_updated_at == attrs.lease_updated_at
      assert File.read!(RunLedger.ledger_file_path()) == ledger
      if authority, do: assert({:ok, _} = RunStateStore.ensure_current(authority, expected))
    end
  end

  test "lease synchronization keeps explicit matching material values", context do
    assert {:ok, _} = RunStateStore.update(context.workspace, &Map.merge(&1, %{implementation_turns: 7, policy_override: nil, review_return_stage: "await_checks"}))
    assert {:ok, before} = RunStateStore.load(context.workspace)
    expected = RunStateStore.material_projection(before)
    assert {:ok, synced} = RunStateStore.sync_lease(context.workspace, context.issue, %{lease_owner: "matching-owner", lease_updated_at: "renewed"})
    assert synced.implementation_turns == 7
    assert Map.has_key?(synced, :policy_override)
    assert synced.policy_override == nil
    assert synced.review_return_stage == "await_checks"
    assert RunStateStore.material_projection(synced) == expected
    assert {:ok, persisted} = RunStateStore.load(context.workspace)
    assert RunStateStore.material_projection(persisted) == expected
  end

  test "lease synchronization still initializes a missing snapshot", context do
    workspace = Path.join(context.workspace, "new-snapshot")
    assert {:error, :missing} = RunStateStore.load(workspace)
    expected = workspace |> RunStateStore.load_or_default(context.issue) |> RunStateStore.material_projection()
    assert {:ok, synced} = RunStateStore.sync_lease(workspace, context.issue, %{lease_owner: "new-owner", lease_epoch: 1})
    assert synced.issue_id == context.issue.id
    assert synced.issue_identifier == context.issue.identifier
    assert synced.stage == "checkout"
    assert synced.lease_owner == "new-owner"
    assert synced.lease_epoch == 1
    assert RunStateStore.material_projection(synced) == expected
    assert {:ok, ^synced} = RunStateStore.load(workspace)
  end

  test "lease synchronization preserves legacy mismatched-issue initialization", context do
    other = %{context.issue | id: "other-sync-issue", identifier: "OTHER-SYNC-ISSUE"}
    assert {:ok, before} = RunStateStore.load(context.workspace)
    assert before.issue_id != other.id
    refute Map.has_key?(before, :run_id)
    ledger = File.read!(RunLedger.ledger_file_path())
    assert {:ok, synced} = RunStateStore.sync_lease(context.workspace, other, %{lease_owner: "other-owner", lease_epoch: 1})
    assert synced.issue_id == other.id
    assert synced.issue_identifier == other.identifier
    assert synced.stage == "checkout"
    assert synced.implementation_turns == 0
    assert synced.policy_override == nil
    assert synced.review_return_stage == nil
    assert synced.lease_owner == "other-owner"
    assert {:ok, ^synced} = RunStateStore.load(context.workspace)
    assert File.read!(RunLedger.ledger_file_path()) == ledger
  end

  for {kind, payload, expected} <- [
        {:json, "{invalid-json", {:run_state_unreadable, {:invalid_json, 1}}},
        {:shape, "[]", {:run_state_unreadable, :invalid_state}},
        {:pending, ~s({"audit_pending":{"operation_id":"pending-sync"}}), {:run_state_unreadable, {:audit_pending, "pending-sync"}}},
        {:identity, ~s({"run_id":"partial-sync"}), :invalid_run_identity}
      ] do
    @tag lease_sync_error: {payload, expected}
    test "lease synchronization preserves the #{kind} read error and bytes", context do
      {payload, expected} = context.lease_sync_error
      path = RunStateStore.state_path(context.workspace)
      File.write!(path, payload)
      ledger = File.read!(RunLedger.ledger_file_path())
      assert {:error, ^expected} = RunStateStore.sync_lease(context.workspace, context.issue, %{lease_owner: "must-not-write"})
      assert File.read!(path) == payload
      assert File.read!(RunLedger.ledger_file_path()) == ledger
    end
  end

  test "lease synchronization preserves the snapshot directory error", context do
    path = RunStateStore.state_path(context.workspace)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :eisdir} = RunStateStore.sync_lease(context.workspace, context.issue, %{})
    assert File.dir?(path)
  end

  defp paused_update(workspace, fun) do
    parent = self()

    task =
      Task.async(fn ->
        RunStateStore.update(workspace, fn state ->
          send(parent, :update_entered)

          receive do
            :continue_update -> fun.(state)
          end
        end)
      end)

    assert_receive :update_entered, 5_000
    task
  end

  defp assert_update_holds_lock(workspace) do
    lock = {{RunStateStore, Path.expand(workspace)}, self()}
    acquired = :global.set_lock(lock, [node()], 0)
    if acquired, do: :global.del_lock(lock, [node()])
    refute acquired, "The update callback ran before acquiring the workspace mutation lock"
  end

  defp mutate(:sync_lease, context) do
    RunStateStore.sync_lease(context.workspace, context.issue, %{lease_owner: "owner", lease_epoch: 1})
  end

  defp mutate(:clear_lease, context), do: RunStateStore.clear_lease(context.workspace)

  defp mutate(:record_token_usage, context) do
    RunStateStore.record_token_usage(context.workspace, context.issue, %{input_tokens: 3, output_tokens: 2, total_tokens: 5})
  end
end
