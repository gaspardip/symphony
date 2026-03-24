defmodule SymphonyElixir.AgentProvider do
  @moduledoc """
  Behaviour for agent providers. Implement this to add a new coding agent to Symphony.

  ## Callbacks

  - `start_session/2` — initialise a new agent session for a given workspace path and
    options. Returns `{:ok, session}` on success or `{:error, reason}` on failure.
  - `run_turn/4` — execute one prompt turn inside an existing session. Receives the
    session, the prompt string, the issue map, and options. Returns
    `{:ok, turn_result}` or `{:error, reason}`.
  - `stop_session/1` — cleanly shut down a session and release any resources it holds.
    Always returns `:ok`.

  ## Adding a new provider

  1. Create a module that `@behaviour SymphonyElixir.AgentProvider`.
  2. Implement all three callbacks: `start_session/2`, `run_turn/4`, and `stop_session/1`.
  3. Register a string key for the provider in `resolve_module/1` (e.g. `"myprovider"`).
  4. Set `config :symphony_elixir, :agent_provider, "myprovider"` (or the equivalent
     runtime config) to activate it.

  ## Provider resolution

  - `resolve/1` reads the `:provider` option, falling back to the application config
    value returned by `Config.agent_provider/0`. It returns the provider module.
  - `resolve_for_stage/2` checks whether a stage-specific override exists via
    `Config.agent_provider_for_stage/1`. If one is configured it takes precedence;
    otherwise it falls back to `resolve/1`. This allows different pipeline stages to use
    different providers without global config changes.
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
