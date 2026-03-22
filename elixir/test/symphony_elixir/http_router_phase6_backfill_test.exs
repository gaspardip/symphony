defmodule SymphonyElixir.HttpRouterPhase6BackfillTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixirWeb.StaticAssetController

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

  test "router returns 405 for non-post action requests" do
    orchestrator_name = Module.concat(__MODULE__, :ActionRouteOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: empty_snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/MT-HTTP/actions/pause"), 405) == %{
             "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
           }
  end

  test "router exposes metrics routes at the configured path and rejects non-get methods" do
    metrics_routes =
      SymphonyElixirWeb.Router.__routes__()
      |> Enum.filter(&(&1.path == "/metrics"))

    assert Enum.any?(metrics_routes, &(&1.verb == :get and &1.plug_opts == :metrics))
    assert Enum.any?(metrics_routes, &(&1.verb == :* and &1.plug_opts == :method_not_allowed))

    orchestrator_name = Module.concat(__MODULE__, :MetricsRouteOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: empty_snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(post(build_conn(), "/metrics", %{}), 405) == %{
             "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
           }
  end

  test "http server bound_port is nil when the endpoint has no running server" do
    orchestrator_name = Module.concat(__MODULE__, :BoundPortNilOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: empty_snapshot()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert HttpServer.bound_port() == nil
  end

  test "http server currently raises for tuple hosts during URL host normalization" do
    assert_raise Protocol.UndefinedError, fn ->
      HttpServer.start_link(host: {127, 0, 0, 1}, port: 0, orchestrator: StaticOrchestrator)
    end

    assert_raise Protocol.UndefinedError, fn ->
      HttpServer.start_link(
        host: {0, 0, 0, 0, 0, 0, 0, 1},
        port: 0,
        orchestrator: StaticOrchestrator
      )
    end
  end

  test "http server resolves localhost through inet lookup and serves the API" do
    orchestrator_name = Module.concat(__MODULE__, :LocalhostOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: empty_snapshot()})

    start_supervised!({HttpServer, host: "localhost", port: 0, orchestrator: orchestrator_name, snapshot_timeout_ms: 50})

    port = wait_for_bound_port()
    response = Req.get!("http://localhost:#{port}/api/v1/state")

    assert response.status == 200
    assert response.body["generated_at"]

    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    assert endpoint_config[:url][:host] == "localhost"
    assert endpoint_config[:http][:ip] == {127, 0, 0, 1}
  end

  test "static asset controller returns 404 for missing embedded assets" do
    conn = StaticAssetController.serve_for_test(build_conn(), "/missing-asset.js")
    assert conn.status == 404
    assert conn.resp_body == "Not Found"
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

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

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
