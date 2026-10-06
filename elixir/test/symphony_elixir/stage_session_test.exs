defmodule SymphonyElixir.DeliveryEngine.StageSessionTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{AgentProvider, DeliveryEngine.StageSession}
  alias SymphonyElixir.AgentProvider.{Claude, CodexCLI}

  setup do
    root = Path.join(System.tmp_dir!(), "stage-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.dirname(root))
    configure!("claude", "codex-cli")
    on_exit(fn -> File.rm_rf!(root) end)
    %{workspace: root, issue: %Issue{id: "stage-session", identifier: "STAGE", title: "Local session scope", state: "In Progress"}}
  end

  test "empty scope opens and closes no provider", c do
    {result, calls} =
      trace_sessions(fn ->
        StageSession.with_scope(c.workspace, c.issue, fn scope ->
          assert StageSession.current(scope) == :empty
          :passive_complete
        end)
      end)

    assert result == :passive_complete
    assert calls == []
  end

  test "same provider retains exact resource and closes once", c do
    configure!("claude", "claude")

    {result, calls} =
      trace_sessions(fn ->
        StageSession.with_scope(c.workspace, c.issue, fn scope ->
          assert {:ok, first} = StageSession.ensure(scope, :plan)
          assert first.provider == Claude and first.binding == :legacy
          assert {:ok, ^first} = StageSession.ensure(scope, "implement")
          assert {:ok, ^first} = StageSession.current(scope)
          :complete
        end)
      end)

    assert result == :complete
    assert Enum.map(calls, &operation/1) == [{:open_session, Claude}, {:close_session, Claude}]
    [{_, _, _, _, _, _}, {:close_session, _, session, :legacy}] = calls
    assert session.workspace == c.workspace
  end

  for {initial, next, initial_module, next_module} <- [{"claude", "codex-cli", Claude, CodexCLI}, {"codex-cli", "claude", CodexCLI, Claude}] do
    @initial initial
    @next next
    @initial_module initial_module
    @next_module next_module
    test "#{initial} to #{next} closes the exact old session before opening the successor", c do
      configure!(@initial, @next)

      {result, calls} =
        trace_sessions(fn ->
          StageSession.with_scope(c.workspace, c.issue, fn scope ->
            assert {:ok, first} = StageSession.ensure(scope, :plan)
            assert first.provider == @initial_module
            assert {:ok, second} = StageSession.ensure(scope, :implement)
            assert second.provider == @next_module
            refute first.session.session_id == second.session.session_id
            assert {:ok, ^second} = StageSession.current(scope)
            {first, second}
          end)
        end)

      {first, second} = result
      assert Enum.map(calls, &operation/1) == [{:open_session, @initial_module}, {:close_session, @initial_module}, {:open_session, @next_module}, {:close_session, @next_module}]
      [_, {:close_session, _, old, :legacy}, _, {:close_session, _, current, :legacy}] = calls
      assert old == first.session and current == second.session
    end
  end

  test "nested scopes retain separate resources and close inner before outer", c do
    {result, calls} =
      trace_sessions(fn ->
        StageSession.with_scope(c.workspace, c.issue, fn outer ->
          {:ok, first} = StageSession.ensure(outer, :plan)

          second =
            StageSession.with_scope(c.workspace, c.issue, fn inner ->
              {:ok, second} = StageSession.ensure(inner, :plan)
              refute first.session.session_id == second.session.session_id
              assert {:ok, ^first} = StageSession.current(outer)
              second
            end)

          assert {:ok, ^first} = StageSession.current(outer)
          {first, second}
        end)
      end)

    {first, second} = result
    [_, _, {:close_session, Claude, inner, :legacy}, {:close_session, Claude, outer, :legacy}] = calls
    assert inner == second.session and outer == first.session
  end

  test "expired and foreign scopes fail without opening a resource", c do
    {expired, calls} =
      trace_sessions(fn ->
        scope =
          StageSession.with_scope(c.workspace, c.issue, fn scope ->
            task =
              Task.async(fn ->
                assert_raise ArgumentError, "Stage session scope belongs to another worker", fn -> StageSession.ensure(scope, :plan) end
              end)

            assert %ArgumentError{} = Task.await(task)
            scope
          end)

        assert_raise ArgumentError, "Stage session scope is no longer active", fn -> StageSession.current(scope) end
        assert_raise ArgumentError, "Stage session scope is no longer active", fn -> StageSession.ensure(scope, :plan) end
        scope
      end)

    assert {:delivery_stage_session, caller, ref} = expired
    assert caller == self() and is_reference(ref)
    assert calls == []
  end

  for {kind, outcome} <- [{:returned_error, {:error, :work_failed}}, {:terminal, {:stop, %{stage: "blocked"}}}, {:throw, :work_throw}, {:exit, :work_exit}, {:raise, "work raised"}] do
    @kind kind
    @outcome outcome
    test "#{kind} work outcome survives one successful resource cleanup", c do
      {result, calls} =
        trace_sessions(fn ->
          work = fn ->
            StageSession.with_scope(c.workspace, c.issue, fn scope ->
              assert {:ok, _} = StageSession.ensure(scope, :plan)

              case @kind do
                :throw -> throw(@outcome)
                :exit -> exit(@outcome)
                :raise -> raise RuntimeError, message: @outcome
                _ -> @outcome
              end
            end)
          end

          case @kind do
            :throw -> assert catch_throw(work.()) == @outcome
            :exit -> assert catch_exit(work.()) == @outcome
            :raise -> assert_raise RuntimeError, @outcome, work
            _ -> assert work.() == @outcome
          end

          :checked
        end)

      assert result == :checked
      assert Enum.map(calls, &operation/1) == [{:open_session, Claude}, {:close_session, Claude}]
    end
  end

  defp configure!(plan, implement) do
    path = Workflow.workflow_file_path()
    current = File.read!(path)
    # Each test starts with TestSupport's workflow; replace only this fixture's agent section.
    agent = "agent:\n  provider: claude\n  providers:\n    plan: #{plan}\n    implement: #{implement}\n"
    current = Regex.replace(~r/agent:\n(?:[ ]+[^\n]*\n)*/, current, agent)
    File.write!(path, current)
    :ok = WorkflowStore.force_reload()
  end

  defp operation({name, provider, _, _, _, _}), do: {name, provider}
  defp operation({name, provider, _, _}), do: {name, provider}

  defp trace_sessions(work) do
    Code.ensure_loaded!(AgentProvider)
    {tracer, monitor} = spawn_monitor(fn -> collect_calls([]) end)
    patterns = [{AgentProvider, :open_session, 5}, {AgentProvider, :close_session, 3}]

    try do
      for pattern <- patterns, do: assert(:erlang.trace_pattern(pattern, true, [:local]) == 1)
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      result = work.()
      barrier = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^barrier}, 5_000
      send(tracer, {:calls, self()})
      assert_receive {:calls, calls}, 5_000
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
      send(tracer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^tracer, :normal}, 5_000
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _, :call, {AgentProvider, name, args}} ->
        collect_calls([List.to_tuple([name | args]) | calls])

      {:calls, owner} ->
        send(owner, {:calls, Enum.reverse(calls)})
        collect_calls(calls)

      :stop ->
        :ok
    end
  end
end
