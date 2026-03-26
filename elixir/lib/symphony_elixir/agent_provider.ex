defmodule SymphonyElixir.AgentProvider do
  @moduledoc """
  Behaviour for agent providers. Implement this to add a new coding agent to Symphony.
  """

  alias SymphonyElixir.Config

  @type session :: map()
  @type turn_result :: %{
          result: :turn_completed | :turn_failed | :turn_cancelled,
          session_id: String.t(),
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
        }

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, turn_result()} | {:error, term()}

  @callback stop_session(session()) :: :ok

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
