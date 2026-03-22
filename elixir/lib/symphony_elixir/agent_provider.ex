defmodule SymphonyElixir.AgentProvider do
  @moduledoc """
  Behaviour for agent providers. Implement this to add a new coding agent to Symphony.

  ## Callbacks

  The behaviour defines three callbacks that every provider must implement:

  - `c:start_session/2` — initialise a provider session in a given workspace directory and
    return an opaque `t:session/0` map used by subsequent calls.
  - `c:run_turn/4` — execute one prompt turn within an existing session and return a
    `t:turn_result/0` describing the outcome and token usage.
  - `c:stop_session/1` — tear down the session and release any associated resources.

  ## Adding a new provider

  1. Create a module that `@behaviour SymphonyElixir.AgentProvider`.
  2. Implement all three callbacks: `start_session/2`, `run_turn/4`, and `stop_session/1`.
  3. Register the provider string in the application config and add a matching clause to the
     private `resolve_module/1` function in this module (e.g. `"myprovider" -> MyApp.AgentProvider.MyProvider`).

  ## Provider resolution

  - `resolve/1` — reads the provider from the `:provider` option or, when absent, from the
    application configuration via `SymphonyElixir.Config.agent_provider/0`. Use this as the
    default resolution path.
  - `resolve_for_stage/2` — looks up a stage-specific override via
    `SymphonyElixir.Config.agent_provider_for_stage/1` before falling back to `resolve/1`.
    Use this when different pipeline stages (e.g. `implement` vs `review`) should be handled
    by different providers.
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
      "codex" -> SymphonyElixir.AgentProvider.Codex
      module when is_atom(module) -> module
      _ -> SymphonyElixir.AgentProvider.Codex
    end
  end
end
