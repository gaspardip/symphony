Code.require_file("../support/stage_session_fixture.exs", __DIR__)

defmodule SymphonyElixir.DeliveryEngine.StageSessionAdmittedTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{AgentExecution, AgentProvider, DeliveryEngine, LeaseManager, RunStateStore}
  alias SymphonyElixir.DeliveryEngine.{StageSession, TurnReport}
  alias SymphonyElixir.AgentProvider.{Claude, CodexCLI}
  alias SymphonyElixir.TestSupport.StageSessionFixture, as: Fixture

  test "handoff preserves captured authority, accumulated usage and invocation ordinal" do
    c = Fixture.cli_fixture!("claude", "codex-cli")
    assert {:ok, _} = RunStateStore.record_token_usage(c.workspace, c.issue, %{input_tokens: 100, output_tokens: 0, total_tokens: 100})
    {owner, worker, entry} = Fixture.start_worker!(c)

    {snapshots, calls} =
      Fixture.in_worker(worker, fn ->
        Fixture.trace_sessions(fn ->
          StageSession.with_scope(c.workspace, c.issue, fn scope ->
            assert {:ok, context} = AgentExecution.current_context()
            assert context == entry.agent_execution.context
            assert {:ok, first} = StageSession.ensure(scope, :plan)
            assert first.provider == Claude
            assert {:ok, ^first} = StageSession.ensure(scope, :plan)
            assert {:ok, _} = turn!(first, c, :plan)
            assert {:ok, %{summary: "claude change"}} = TurnReport.fetch(c.issue)
            first_registry = Fixture.registry(owner, c)
            assert first_registry.ordinal == 1 and first_registry.current == first.binding
            assert first_registry.live[first.binding].purpose == :main
            assert {:ok, first_state} = RunStateStore.load(c.workspace)
            assert first_state.token_usage == %{input_tokens: 107, output_tokens: 3, total_tokens: 110}
            assert {:ok, _} = AgentExecution.transition_current("implement", %{plan_completed: true})
            assert {:ok, second} = StageSession.ensure(scope, :implement)
            assert second.provider == CodexCLI and first.binding != second.binding
            handoff_registry = Fixture.registry(owner, c)
            assert handoff_registry.retired[first.binding] == true
            assert handoff_registry.retired_usage == %{input_tokens: 7, output_tokens: 3, total_tokens: 10}
            refute Map.has_key?(handoff_registry.live, first.binding)
            assert Map.keys(handoff_registry.live) == [second.binding]
            assert {:ok, _} = turn!(second, c, :implement)
            assert {:ok, %{summary: "codex-cli change"}} = TurnReport.fetch(c.issue)
            second_registry = Fixture.registry(owner, c)
            assert second_registry.ordinal == 2 and second_registry.current == second.binding
            assert AgentExecution.total_usage(second_registry) == %{input_tokens: 28, output_tokens: 12, total_tokens: 40}
            assert {:ok, ^context} = AgentExecution.current_context()
            assert {:ok, final_state} = RunStateStore.load(c.workspace)
            assert final_state.token_usage == %{input_tokens: 128, output_tokens: 12, total_tokens: 140}
            {first.binding, second.binding}
          end)
        end)
      end)

    {first, second} = snapshots
    final_registry = Fixture.registry(owner, c)
    assert final_registry.live == %{} and final_registry.current == nil and final_registry.ordinal == 2
    assert final_registry.retired == %{first => true, second => true}
    assert final_registry.retired_usage == %{input_tokens: 28, output_tokens: 12, total_tokens: 40}
    assert Fixture.runtime(owner).agent_totals.total_tokens == 40
    assert actual_session_calls(calls) == [{:open_session, Claude}, {:close_session, Claude}, {:open_session, CodexCLI}, {:close_session, CodexCLI}]
    assert File.read!(c.commands) == "claude\ncodex-cli\n"
    assert :ok = LeaseManager.ensure_current(entry.lease_token)
    assert {:normal, _} = Fixture.finish_worker!(owner, worker)
  end

  test "public admitted delivery plans and implements with the actual configured adapters" do
    c = Fixture.cli_fixture!("claude", "codex-cli")
    {owner, worker, entry} = Fixture.start_worker!(c)

    assert {{:done, %Issue{state: "Done"}}, calls} =
             Fixture.in_worker(worker, fn ->
               Fixture.trace_sessions(fn ->
                 DeliveryEngine.run(c.workspace, c.issue, self(), issue_state_fetcher: fn _ -> {:ok, [%{c.issue | state: "Done"}]} end, include_pr_details: false)
               end)
             end)

    assert File.read!(c.commands) == "claude\ncodex-cli\n"
    assert actual_session_calls(calls) == [{:open_session, Claude}, {:close_session, Claude}, {:open_session, CodexCLI}, {:close_session, CodexCLI}]
    assert {:ok, state} = RunStateStore.load(c.workspace)
    assert state.stage == "validate" and state.implementation_turns == 1
    assert state.last_turn_result.summary == "codex-cli change"
    assert state.token_usage == %{input_tokens: 28, output_tokens: 12, total_tokens: 40}
    assert File.read!(Path.join(c.workspace, "existing.txt")) == "initial\nclaude change\ncodex-cli change\n"
    registry = Fixture.registry(owner, c)
    assert registry.ordinal == 2 and registry.live == %{} and map_size(registry.retired) == 2
    assert :ok = LeaseManager.ensure_current(entry.lease_token)
    assert {:normal, _} = Fixture.finish_worker!(owner, worker)
  end

  test "public admitted delivery routes CodexCLI plan to Claude implementation" do
    c = Fixture.cli_fixture!("codex-cli", "claude")
    {owner, worker, entry} = Fixture.start_worker!(c)

    assert {{:done, %Issue{state: "Done"}}, calls} =
             Fixture.in_worker(worker, fn ->
               Fixture.trace_sessions(fn ->
                 DeliveryEngine.run(c.workspace, c.issue, self(), issue_state_fetcher: fn _ -> {:ok, [%{c.issue | state: "Done"}]} end, include_pr_details: false)
               end)
             end)

    assert File.read!(c.commands) == "codex-cli\nclaude\n"
    assert actual_session_calls(calls) == [{:open_session, CodexCLI}, {:close_session, CodexCLI}, {:open_session, Claude}, {:close_session, Claude}]
    assert {:ok, state} = RunStateStore.load(c.workspace)
    assert state.stage == "validate" and state.implementation_turns == 1
    assert state.last_turn_result.summary == "claude change"
    assert state.token_usage == %{input_tokens: 28, output_tokens: 12, total_tokens: 40}
    assert File.read!(Path.join(c.workspace, "existing.txt")) == "initial\ncodex-cli change\nclaude change\n"
    registry = Fixture.registry(owner, c)
    assert registry.ordinal == 2 and registry.live == %{} and map_size(registry.retired) == 2
    assert :ok = LeaseManager.ensure_current(entry.lease_token)
    assert {:normal, _} = Fixture.finish_worker!(owner, worker)
  end

  test "public delivery aborts a real successor initialization error without an implementation turn" do
    c = Fixture.cli_fixture!("claude", "codex")
    app_server = Path.join(c.bin, "failing-app-server")

    File.write!(app_server, """
    #!/bin/sh
    printf '%s\\n' 'app-server-open' >> #{Fixture.quote_shell(c.commands)}
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"error":{"code":-32000,"message":"fixture initialization rejected"}}' ;;
      esac
    done
    """)

    File.chmod!(app_server, 0o500)
    workflow = Workflow.workflow_file_path()
    text = String.replace(File.read!(workflow), ~r/^  command: .+$/m, "  command: " <> Jason.encode!(Fixture.quote_shell(app_server) <> " app-server"))
    File.write!(workflow, text)
    :ok = WorkflowStore.force_reload()
    {owner, worker, _entry} = Fixture.start_worker!(c)

    assert {:error, {:response_error, %{"code" => -32_000, "message" => "fixture initialization rejected"}}} =
             Fixture.in_worker(worker, fn ->
               DeliveryEngine.run(c.workspace, c.issue, self(), include_pr_details: false)
             end)

    assert File.read!(c.commands) == "claude\napp-server-open\n"
    assert File.read!(Path.join(c.workspace, "existing.txt")) == "initial\nclaude change\n"
    assert {:ok, state} = RunStateStore.load(c.workspace)
    assert state.stage == "implement" and state.implementation_turns == 0
    registry = Fixture.registry(owner, c)
    assert registry.ordinal == 1 and registry.live == %{} and map_size(registry.retired) == 1
    assert registry.uncertain == nil
    assert {:normal, _} = Fixture.finish_worker!(owner, worker)
  end

  test "authority invalidation during handoff closes once and cannot adopt the successor lease" do
    c = Fixture.cli_fixture!("claude", "codex-cli")
    {owner, worker, entry} = Fixture.start_worker!(c)
    observer = self()
    ref = make_ref()

    send(
      worker,
      {:exercise, observer, ref,
       fn ->
         Fixture.trace_sessions(fn ->
           StageSession.with_scope(c.workspace, c.issue, fn scope ->
             assert {:ok, _} = StageSession.ensure(scope, :plan)
             send(observer, {:scope_ready, self()})

             receive do
               :replace_provider ->
                 assert {:stop, {:stale_execution, ids, :lease_token_mismatch}} = first = StageSession.ensure(scope, :implement)
                 assert ids == %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
                 assert StageSession.current(scope) == first
                 assert StageSession.ensure(scope, :implement) == first
                 first
             after
               5_000 -> flunk("test control did not reach admitted scope")
             end
           end)
         end)
       end}
    )

    assert_receive {:scope_ready, ^worker}, 5_000
    assert {:ok, :released} = LeaseManager.release_token(entry.lease_token)
    assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, entry.lease_token.owner, storage: entry.lease_token.storage)
    before = File.read!(successor.token.storage.lease_path)
    journal = Fixture.journal_bytes(entry)
    send(worker, :replace_provider)
    assert_receive {:exercise_result, ^ref, {{:stop, {:stale_execution, ids, :lease_token_mismatch}}, calls}}, 5_000
    assert ids == %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
    assert actual_session_calls(calls) == [{:open_session, Claude}, {:close_session, Claude}]
    assert File.read!(c.commands) == ""
    assert File.read!(successor.token.storage.lease_path) == before
    assert Fixture.journal_bytes(entry) == journal
    assert {{:stale_execution, ^ids, :lease_token_mismatch}, stopped} = Fixture.finish_worker!(owner, worker)
    refute Map.has_key?(stopped.retry_attempts, c.issue.id)
    assert File.read!(successor.token.storage.lease_path) == before
    assert Fixture.journal_bytes(entry) == journal
    assert {:ok, :released} = LeaseManager.release_token(successor.token)
  end

  defp turn!(live, c, stage) do
    :ok = TurnReport.reset(c.issue)

    AgentProvider.run_turn(
      live.provider,
      live.session,
      c.workspace,
      "local #{stage} work",
      c.issue,
      [execution_binding: live.binding, stage: stage, tool_executor: TurnReport.tool_executor(c.issue, []), on_message: TurnReport.message_handler(self(), c.issue)],
      :delivery
    )
  end

  defp actual_session_calls(calls) do
    for {AgentProvider, function, [provider | _]} <- calls, do: {function, provider}
  end
end
