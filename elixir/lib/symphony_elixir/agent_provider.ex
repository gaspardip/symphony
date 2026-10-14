defmodule SymphonyElixir.AgentProvider do
  @moduledoc """
  Behaviour for agent providers. Implement this to add a new coding agent to Symphony.

  Accounted engine calls use the session wrappers below. Their callbacks run in
  the admitted worker, observe raw usage before adapter normalization, and confirm
  durable accounting before tools or turn effects. Direct adapter calls preserve
  the transport-only legacy contract and do not establish accounting authority.
  """

  alias SymphonyElixir.{AgentExecution, Config, DeliveryEngine.TurnEffects}

  @type session :: map()
  @type cli_observation :: %{
          profile: :claude_cli | :codex_cli,
          files_touched: [String.t()],
          result_text: String.t() | nil,
          error: term()
        }

  @type turn_result :: %{
          required(:result) => :turn_completed | :turn_failed | :turn_cancelled,
          required(:session_id) => String.t(),
          required(:usage) => %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          optional(:cli_observation) => cli_observation()
        }

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Execute transport and report stream callbacks synchronously in the caller process.

  Claude/CodexCLI return a required `cli_observation` for the engine to apply local
  policy. Direct callers receive no Git preparation, delivery synthesis or normal
  final CLI event. Other providers retain their own tool and event contracts.
  """
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, turn_result()} | {:error, term()} | AgentExecution.terminal()

  @callback stop_session(session()) :: :ok | {:error, term()}

  @doc false
  @spec open_session(module(), Path.t(), map(), :main | :verifier, keyword()) ::
          {:ok, session(), AgentExecution.binding() | :legacy} | {:error, term()} | AgentExecution.terminal()
  def open_session(provider, workspace, issue, purpose, opts \\ []) do
    with {:ok, context} <- AgentExecution.entry_context(workspace, issue),
         :ok <- session_capacity(context, provider),
         {:ok, session} <- provider.start_session(workspace, opts) do
      case register_session(context, provider, session, purpose) do
        {:ok, binding} ->
          {:ok, session, binding}

        {:stop, _} = terminal ->
          SymphonyElixir.ProviderTransport.with_cleanup(fn -> terminal end, fn -> provider.stop_session(session) end)
      end
    end
  end

  @doc false
  @spec close_session(module(), session(), AgentExecution.binding() | :legacy) :: :ok | {:error, term()} | AgentExecution.terminal()
  def close_session(provider, session, binding) do
    with :ok <- provider.stop_session(session) do
      if binding == :legacy, do: :ok, else: AgentExecution.retire_session(binding)
    end
  end

  @doc false
  @spec run_turn(module(), session(), Path.t(), String.t(), map(), keyword(), :delivery | :verifier) ::
          {:ok, map()} | {:error, term()} | AgentExecution.terminal()
  def run_turn(provider, session, workspace, prompt, issue, opts, purpose) do
    with {:ok, context} <- AgentExecution.entry_context(workspace, issue) do
      case context do
        :legacy ->
          result = provider.run_turn(session, prompt, issue, opts)
          TurnEffects.apply_result(provider, result, workspace, issue, opts, purpose)

        _context ->
          with {:ok, invocation} <- AgentExecution.begin_invocation(provider, session, Keyword.get(opts, :execution_binding)) do
            run_accounted_turn(provider, session, workspace, prompt, issue, opts, purpose, invocation)
          end
      end
    end
  end

  defp session_capacity(:legacy, _provider), do: :ok
  defp session_capacity(_context, provider), do: AgentExecution.ensure_session_capacity(provider)
  defp register_session(:legacy, _provider, _session, _purpose), do: {:ok, :legacy}
  defp register_session(_context, provider, session, purpose), do: AgentExecution.register_session(provider, session, purpose)

  defp run_accounted_turn(provider, session, workspace, prompt, issue, opts, purpose, invocation) do
    invocation = Map.put(invocation, :usage_metadata, usage_metadata(provider, session, opts))
    guarded_opts = accounting_callbacks(invocation, opts)

    try do
      result = provider.run_turn(session, prompt, issue, guarded_opts)

      with :ok <- confirm_result(invocation, result),
           :ok <- observe_result(provider, invocation, result) do
        case result do
          {:stop, _} = terminal ->
            terminal

          _ ->
            applied = TurnEffects.apply_result(provider, result, workspace, issue, guarded_opts, purpose)
            with :ok <- AgentExecution.confirm_invocation(invocation), do: applied
        end
      end
    catch
      :throw, {:agent_execution_halt, {:stop, _} = terminal} -> terminal
    end
  end

  # Capture the same model selection the adapter receives. This is descriptive
  # telemetry, never execution authority or a fresh read of global configuration.
  defp usage_metadata(SymphonyElixir.AgentProvider.Codex, _session, opts) do
    model =
      case Keyword.get(opts, :model) do
        model when is_binary(model) and model != "" -> model
        _omitted_model -> nil
      end

    %{provider: "codex", model: model}
  end

  defp usage_metadata(SymphonyElixir.AgentProvider.CodexCLI, session, opts),
    do: %{provider: "codex-cli", model: Keyword.get(opts, :model, session.model)}

  defp usage_metadata(SymphonyElixir.AgentProvider.Claude, session, opts),
    do: %{provider: "claude", model: Keyword.get(opts, :model, session.model)}

  defp confirm_result(invocation, {:ok, result}) when is_map(result), do: AgentExecution.confirm_invocation(invocation, result)
  defp confirm_result(invocation, _result), do: AgentExecution.confirm_invocation(invocation)

  defp observe_result(provider, invocation, {:ok, result}) when provider in [SymphonyElixir.AgentProvider.Claude, SymphonyElixir.AgentProvider.CodexCLI] and is_map(result),
    do: AgentExecution.observe_usage(invocation, result)

  defp observe_result(_provider, _invocation, _result), do: :ok

  defp accounting_callbacks(invocation, opts) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    tool_executor = Keyword.get(opts, :tool_executor)

    opts =
      opts
      |> Keyword.put(:on_usage, fn raw ->
        guarded_callback(invocation, fn -> AgentExecution.observe_usage(invocation, raw) end)
      end)
      |> Keyword.put(:effect_guard, fn -> effect_authority(invocation) end)
      |> Keyword.put(:on_message, fn message ->
        guarded_callback(invocation, fn ->
          require_accounting(AgentExecution.forward_update(invocation, message))
          on_message.(message)
        end)
      end)

    if is_function(tool_executor, 2) do
      Keyword.put(opts, :tool_executor, fn tool, arguments ->
        guarded_callback(invocation, fn ->
          require_accounting(AgentExecution.confirm_invocation(invocation))
          tool_executor.(tool, arguments)
        end)
      end)
    else
      opts
    end
  end

  # Local Git effects need the same owner-confirmed authority as tool calls.
  defp effect_authority(invocation) do
    case AgentExecution.confirm_invocation(invocation) do
      {:discard, reason} -> {:error, {:execution_discarded, reason}}
      authority -> authority
    end
  end

  defp guarded_callback(invocation, fun) do
    case AgentExecution.guard_invocation(invocation) do
      :ok -> require_accounting(fun.())
      {:discard, _} = discarded -> discarded
      {:stop, _} = terminal -> throw({:agent_execution_halt, terminal})
    end
  end

  defp require_accounting({:stop, {kind, _}} = terminal) when kind in [:accounting_uncertain, :execution_stopped], do: throw({:agent_execution_halt, terminal})
  defp require_accounting({:stop, {:stale_execution, _, _}} = terminal), do: throw({:agent_execution_halt, terminal})
  defp require_accounting(result), do: result

  @doc "Resolve the provider module from config or explicit option."
  @spec resolve(keyword()) :: module()
  def resolve(opts \\ []) do
    provider = Keyword.get(opts, :provider) || Config.agent_provider()
    resolve_module(provider)
  end

  @doc "Resolve provider for a specific stage (enables per-stage routing)."
  @spec resolve_for_stage(String.t() | atom(), keyword()) :: module()
  def resolve_for_stage(stage, opts \\ []) do
    case Config.agent_provider_for_stage(stage) do
      nil -> resolve(opts)
      provider -> resolve(provider: provider)
    end
  end

  @spec resolve_module(String.t() | atom()) :: module()
  defp resolve_module(provider) do
    case provider do
      "claude" -> SymphonyElixir.AgentProvider.Claude
      "codex-cli" -> SymphonyElixir.AgentProvider.CodexCLI
      "codex" -> SymphonyElixir.AgentProvider.Codex
      module when is_atom(module) -> module
      _ -> SymphonyElixir.AgentProvider.Codex
    end
  end
end
