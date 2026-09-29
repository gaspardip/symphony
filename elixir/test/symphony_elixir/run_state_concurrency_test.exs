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

      if context.identity_mode == :identified do
        assert {:ok, ticket} =
                 SymphonyElixir.DispatchAudit.begin(context.workspace, %{
                   issue_id: context.issue.id,
                   issue_identifier: context.issue.identifier,
                   metadata: %{owner: "roundtrip-owner", epoch: 1}
                 })

        assert :ok = SymphonyElixir.DispatchAudit.finish(ticket, :not_started)
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

      assert {:ok, consumed} = RunStateStore.record_token_usage(context.workspace, context.issue, %{input_tokens: 17, output_tokens: 3, total_tokens: 20})
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
