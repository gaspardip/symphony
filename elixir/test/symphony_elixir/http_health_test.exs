defmodule SymphonyElixir.HttpHealthTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "GET /api/v1/health returns 200 with status, timestamp, and version fields" do
    orchestrator_name = Module.concat(__MODULE__, :HealthOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: empty_snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    response = json_response(get(build_conn(), "/api/v1/health"), 200)

    assert response["status"] == "ok"
    assert is_binary(response["timestamp"])
    assert Map.has_key?(response, "version")
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp empty_snapshot do
    %{
      running: [],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      polling: %{}
    }
  end
end
