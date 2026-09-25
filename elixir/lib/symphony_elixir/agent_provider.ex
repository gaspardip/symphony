defmodule SymphonyElixir.AgentProvider do
  @moduledoc """
  Behaviour for agent providers. Implement this to add a new coding agent to Symphony.
  """

  alias SymphonyElixir.Config

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
