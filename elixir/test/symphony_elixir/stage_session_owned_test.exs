Code.require_file("../support/stage_session_owned_fixture.exs", __DIR__)

defmodule SymphonyElixir.DeliveryEngine.StageSessionOwnedTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{AgentExecution, AgentProvider, RunStateStore}
  alias SymphonyElixir.DeliveryEngine.StageSession
  alias SymphonyElixir.AgentProvider.{Claude, Codex}
  alias SymphonyElixir.TestSupport.StageSessionFixture, as: Fixture
  alias SymphonyElixir.TestSupport.StageSessionOwnedFixture, as: Owned

  test "real uncertain close is cached without a successor or second close" do
    c = Owned.create!()
    {owner, worker, entry} = Fixture.start_worker!(c)
    before = File.read!(RunStateStore.state_path(c.workspace))

    {{error, tree}, calls} =
      Fixture.in_worker(worker, fn ->
        Fixture.trace_sessions(fn ->
          captured =
            StageSession.with_scope(c.workspace, c.issue, fn scope ->
              assert {:ok, live} = StageSession.ensure(scope, :plan)
              assert live.provider == Codex
              tree = Owned.capture!(c, live.session)
              :ok = Owned.kill_custodian!(live.session)
              assert {:error, {:provider_cleanup_uncertain, :custodian_down}} = error = StageSession.ensure(scope, :implement)
              assert StageSession.current(scope) == error
              assert StageSession.ensure(scope, :implement) == error
              Owned.assert_tree_absent!(tree)
              {error, tree}
            end)

          assert {:error, {:provider_cleanup_uncertain, :custodian_down}} = captured
          # A healthy tuple from work is replaced by the original cleanup error.
          {captured, Jason.decode!(File.read!(Path.join(c.root, "captured-owned.json")), keys: :atoms)}
        end)
      end)

    assert {:error, {:provider_cleanup_uncertain, :custodian_down}} = error
    Owned.cleanup_uncertain!(tree)
    assert session_calls(calls) == [{:open_session, Codex}, {:close_session, Codex}]
    assert Enum.count(calls, &match?({Codex, :stop_session, [_]}, &1)) == 1
    registry = Fixture.registry(owner, c)
    assert map_size(registry.live) == 1 and registry.retired == %{} and registry.ordinal == 0
    assert registry.uncertain == {:provider_close_failed, {:provider_cleanup_uncertain, :custodian_down}}
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    assert File.read!(c.commands) == ""
    Owned.assert_receipts!(entry, 0)
    assert {{:accounting_uncertain, {:provider_close_failed, {:provider_cleanup_uncertain, :custodian_down}}}, stopped} = Fixture.finish_worker!(owner, worker)
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    Owned.assert_receipts!(entry, 0)
  end

  for kind <- [:error, :throw] do
    @kind kind
    test "#{kind} primary retains its exact stack through actual uncertain cleanup" do
      c = Owned.create!()
      {owner, worker, entry} = Fixture.start_worker!(c)
      reason = if @kind == :error, do: %ArgumentError{message: "stage-owned-primary"}, else: :stage_owned_throw

      {{caught, original, calls}, log} =
        Fixture.in_worker(worker, fn ->
          observed =
            capture_log(fn ->
              {caught, calls} =
                Fixture.trace_sessions(fn ->
                  try do
                    StageSession.with_scope(c.workspace, c.issue, fn scope ->
                      assert {:ok, live} = StageSession.ensure(scope, :plan)
                      tree = Owned.capture!(c, live.session)
                      :ok = Owned.kill_custodian!(live.session)
                      Owned.assert_tree_absent!(tree)

                      try do
                        primary_failure(@kind, reason)
                      catch
                        kind, value ->
                          original_stack = __STACKTRACE__
                          send(self(), {:original_primary, {kind, value, original_stack}})
                          :erlang.raise(kind, value, original_stack)
                      end
                    end)
                  catch
                    kind, value -> {kind, value, __STACKTRACE__}
                  end
                end)

              send(self(), {:observed_primary, caught, calls})
            end)

          assert_receive {:observed_primary, caught, calls}, 5_000
          assert_receive {:original_primary, original}, 5_000
          {{caught, original, calls}, observed}
        end)

      assert {@kind, ^reason, stack} = original
      assert caught == original
      assert Enum.any?(stack, fn {module, function, _, _} -> module == __MODULE__ and function == :primary_failure end)
      assert session_calls(calls) == [{:open_session, Codex}, {:close_session, Codex}]
      assert Enum.count(calls, &match?({Codex, :stop_session, [_]}, &1)) == 1
      assert log =~ "Provider cleanup failed"
      tree = Jason.decode!(File.read!(Path.join(c.root, "captured-owned.json")), keys: :atoms)
      Owned.cleanup_uncertain!(tree)
      Owned.assert_receipts!(entry, 0)
      assert {{:accounting_uncertain, {:provider_close_failed, {:provider_cleanup_uncertain, :custodian_down}}}, _} = Fixture.finish_worker!(owner, worker)
      Owned.assert_receipts!(entry, 0)
    end
  end

  test "successful owned close physically ends before the replacement is borrowed" do
    c = Owned.create!()
    {owner, worker, entry} = Fixture.start_worker!(c)

    assert {:complete, calls} =
             Fixture.in_worker(worker, fn ->
               Fixture.trace_sessions(fn ->
                 StageSession.with_scope(c.workspace, c.issue, fn scope ->
                   assert {:ok, old} = StageSession.ensure(scope, :plan)
                   tree = Owned.capture!(c, old.session)
                   assert {:ok, next} = StageSession.ensure(scope, :implement)
                   assert next.provider == Claude
                   Owned.assert_closed!(tree)
                   registry = Fixture.registry(owner, c)
                   assert Map.keys(registry.live) == [next.binding] and registry.retired[old.binding] == true
                   assert registry.uncertain == nil
                   :complete
                 end)
               end)
             end)

    assert session_calls(calls) == [{:open_session, Codex}, {:close_session, Codex}, {:open_session, Claude}, {:close_session, Claude}]
    Owned.assert_receipts!(entry, 1)
    assert {:normal, _} = Fixture.finish_worker!(owner, worker)
  end

  test "verifier resource survives main replacement without losing purpose or capacity" do
    c = Fixture.cli_fixture!("claude", "codex-cli")
    {owner, worker, _entry} = Fixture.start_worker!(c)

    assert :complete =
             Fixture.in_worker(worker, fn ->
               StageSession.with_scope(c.workspace, c.issue, fn scope ->
                 assert {:ok, main} = StageSession.ensure(scope, :plan)
                 assert {:ok, verifier, binding} = AgentProvider.open_session(Claude, c.workspace, c.issue, :verifier)
                 assert Fixture.registry(owner, c).live[binding].purpose == :verifier
                 assert {:ok, next} = StageSession.ensure(scope, :implement)
                 registry = Fixture.registry(owner, c)
                 assert map_size(registry.live) == 2
                 assert registry.live[binding].purpose == :verifier and registry.live[next.binding].purpose == :main
                 assert registry.retired[main.binding] == true
                 assert :ok = AgentProvider.close_session(Claude, verifier, binding)
                 assert :ok = AgentExecution.ensure_session_capacity(next.provider)
                 :complete
               end)
             end)

    assert Fixture.registry(owner, c).live == %{}
    assert {:normal, _} = Fixture.finish_worker!(owner, worker)
  end

  defp primary_failure(:error, reason), do: raise(reason)
  defp primary_failure(:throw, reason), do: throw(reason)

  defp session_calls(calls), do: for({AgentProvider, name, [provider | _]} <- calls, do: {name, provider})
end
