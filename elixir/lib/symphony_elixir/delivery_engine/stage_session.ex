defmodule SymphonyElixir.DeliveryEngine.StageSession do
  @moduledoc """
  Owns the current main transport for one delivery execution in its worker.

  A stage resolves through AgentProvider. The same provider retains its exact
  session and binding; replacement closes the old transport before opening the
  next. Cleanup observes the current resource, including a failed close whose
  original result or exception is retained without another close attempt.

  Registration, invocation, authority and usage remain in AgentExecution.
  This scope does not select stages, read durable delivery state or admit work.
  """

  alias SymphonyElixir.{AgentExecution, AgentProvider, ProviderTransport}

  @opaque scope :: {:delivery_stage_session, pid(), reference()}
  @type live :: %{
          provider: module(),
          session: AgentProvider.session(),
          binding: AgentExecution.binding() | :legacy
        }
  @type failure :: {:error, term()} | AgentExecution.terminal()
  @type close_outcome ::
          {:returned, :ok | failure()}
          | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  @spec with_scope(Path.t(), map(), (scope() -> term())) :: term()
  def with_scope(workspace, issue, work) when is_binary(workspace) and is_map(issue) and is_function(work, 1) do
    scope = {:delivery_stage_session, self(), make_ref()}
    put(scope, %{workspace: workspace, issue: issue, current: :empty})

    try do
      ProviderTransport.with_cleanup(fn -> work.(scope) end, fn -> cleanup(scope) end)
    after
      Process.delete(key(scope))
    end
  end

  @spec current(scope()) :: :empty | {:ok, live()} | failure()
  def current(scope) do
    case get(scope).current do
      :empty -> :empty
      {:live, live} -> {:ok, live}
      {:blocked, outcome} -> restore(outcome)
      {:closing, _live} -> raise ArgumentError, "Stage session close is already in progress"
    end
  end

  @spec ensure(scope(), String.t() | atom()) :: {:ok, live()} | failure()
  def ensure(scope, stage) do
    state = get(scope)

    case state.current do
      {:blocked, outcome} -> restore(outcome)
      {:closing, _live} -> raise ArgumentError, "Stage session close is already in progress"
      _available -> ensure_provider(scope, state, AgentProvider.resolve_for_stage(stage))
    end
  end

  defp ensure_provider(scope, %{current: :empty} = state, provider), do: open(scope, state, provider)

  defp ensure_provider(_scope, %{current: {:live, %{provider: provider} = live}}, provider), do: {:ok, live}

  defp ensure_provider(scope, %{current: {:live, _live}} = state, provider) do
    case close_once(scope, state) do
      :ok -> open(scope, get(scope), provider)
      {:error, _} = error -> error
      {:stop, _} = terminal -> terminal
    end
  end

  defp open(scope, state, provider) do
    case AgentProvider.open_session(provider, state.workspace, state.issue, :main) do
      {:ok, session, binding} ->
        live = %{provider: provider, session: session, binding: binding}
        put(scope, %{state | current: {:live, live}})
        {:ok, live}

      {:error, _} = error ->
        error

      {:stop, _} = terminal ->
        terminal
    end
  end

  defp cleanup(scope) do
    state = get(scope)

    case state.current do
      :empty -> :ok
      {:live, _live} -> close_once(scope, state)
      {:blocked, outcome} -> restore(outcome)
      {:closing, _live} -> raise ArgumentError, "Stage session cleanup interrupted an active close"
    end
  end

  defp close_once(scope, %{current: {:live, live}} = state) do
    # Publish the attempted close before invoking transport code. Reentrant use
    # cannot borrow or close this resource, even when stop_session raises.
    put(scope, %{state | current: {:closing, live}})

    outcome =
      capture(fn ->
        case AgentProvider.close_session(live.provider, live.session, live.binding) do
          :ok -> :ok
          {:error, _} = error -> error
          {:stop, _} = terminal -> terminal
        end
      end)

    case outcome do
      {:returned, :ok} ->
        put(scope, %{state | current: :empty})
        :ok

      failed ->
        put(scope, %{state | current: {:blocked, failed}})
        restore(failed)
    end
  end

  defp capture(work) do
    {:returned, work.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp restore({:returned, value}), do: value
  defp restore({:raised, kind, reason, stack}), do: :erlang.raise(kind, reason, stack)

  defp get(scope) do
    case Process.get(key(scope)) do
      %{workspace: _workspace, issue: _issue, current: _current} = state -> state
      nil -> raise ArgumentError, "Stage session scope is no longer active"
    end
  end

  defp put(scope, state), do: Process.put(key(scope), state)

  defp key({:delivery_stage_session, caller, ref}) when caller == self() and is_reference(ref), do: {__MODULE__, ref}
  defp key(_foreign), do: raise(ArgumentError, "Stage session scope belongs to another worker")
end
