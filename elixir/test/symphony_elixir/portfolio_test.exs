defmodule SymphonyElixir.PortfolioTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Portfolio

  test "summary aggregates healthy and unhealthy instances" do
    previous_fetcher = Application.get_env(:symphony_elixir, :portfolio_fetcher)

    Application.put_env(:symphony_elixir, :portfolio_fetcher, fn
      "https://stable.example" ->
        {:ok,
         %{
           "company" => %{"name" => "Stable Co"},
           "counts" => %{"running" => 2, "retrying" => 1, "paused" => 0, "queue" => 3, "skipped" => 4},
           "triage" => %{"summary" => %{"attention_now" => 5}}
         }}

      "https://canary.example" ->
        {:error, :timeout}
    end)

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_app_env(
        :symphony_elixir,
        :portfolio_fetcher,
        previous_fetcher
      )
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      portfolio_instances: [
        %{name: "stable", url: "https://stable.example"},
        %{name: "canary", url: "https://canary.example"}
      ]
    )

    summary = Portfolio.summary()

    assert summary.totals.instances == 2
    assert summary.totals.healthy_instances == 1
    assert summary.totals.running == 2
    assert summary.totals.attention_now == 5

    assert [
             %{
               name: "stable",
               healthy: true,
               company: %{"name" => "Stable Co"},
               counts: %{running: 2, retrying: 1, paused: 0, queue: 3, skipped: 4},
               error: nil
             },
             %{
               name: "canary",
               healthy: false,
               company: nil,
               counts: %{running: 0, retrying: 0, paused: 0, queue: 0, skipped: 0},
               error: "timeout"
             }
           ] = summary.instances
  end

  test "summary normalizes malformed counts and missing triage values" do
    previous_fetcher = Application.get_env(:symphony_elixir, :portfolio_fetcher)

    Application.put_env(:symphony_elixir, :portfolio_fetcher, fn _url ->
      {:ok,
       %{
         "company" => %{"name" => "Portfolio Co"},
         "counts" => ["unexpected"],
         "triage" => %{"summary" => %{"attention_now" => "unknown"}}
       }}
    end)

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_app_env(
        :symphony_elixir,
        :portfolio_fetcher,
        previous_fetcher
      )
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      portfolio_instances: [%{name: "portfolio", url: "https://portfolio.example"}]
    )

    summary = Portfolio.summary()
    [instance] = summary.instances

    assert instance.healthy
    assert instance.counts == %{running: 0, retrying: 0, paused: 0, queue: 0, skipped: 0}
    assert summary.totals.attention_now == 0
  end

  test "summary uses the default fetcher for live portfolio endpoints" do
    previous_fetcher = Application.get_env(:symphony_elixir, :portfolio_fetcher)
    Application.delete_env(:symphony_elixir, :portfolio_fetcher)

    ok_url =
      start_portfolio_server!(fn ->
        {200,
         %{
           "company" => %{"name" => "Live Stable"},
           "counts" => %{"running" => 1, "retrying" => 2, "paused" => 3, "queue" => 4, "skipped" => 5},
           "triage" => %{"summary" => %{"attention_now" => 6}}
         }}
      end)

    error_url = start_portfolio_server!(fn -> {503, %{"error" => "unavailable"}} end)

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_app_env(
        :symphony_elixir,
        :portfolio_fetcher,
        previous_fetcher
      )
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      portfolio_instances: [
        %{name: "live-stable", url: ok_url},
        %{name: "live-error", url: error_url},
        %{name: "missing-url"}
      ]
    )

    summary = Portfolio.summary()

    assert summary.totals.instances == 3
    assert summary.totals.healthy_instances == 1
    assert summary.totals.running == 1
    assert summary.totals.attention_now == 6

    assert Enum.any?(summary.instances, fn instance ->
             instance.name == "live-stable" and instance.healthy and instance.company == %{"name" => "Live Stable"}
           end)

    assert Enum.any?(summary.instances, fn instance ->
             instance.name == "live-error" and instance.error == "http_503"
           end)

    assert Enum.any?(summary.instances, fn instance ->
             instance.name == "missing-url" and instance.error == "missing_url"
           end)
  end

  defp start_portfolio_server!(response_fun) when is_function(response_fun, 0) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        accept_portfolio_connections(listener, response_fun)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)

      if Process.alive?(server) do
        Process.exit(server, :shutdown)
      end
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_portfolio_connections(listener, response_fun) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve_portfolio_request(socket, response_fun)
        accept_portfolio_connections(listener, response_fun)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_portfolio_request(socket, response_fun) do
    {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
    {status, payload} = response_fun.()
    body = Jason.encode!(payload)

    response = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      http_status_reason(status),
      "\r\n",
      "content-type: application/json\r\n",
      "content-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "connection: close\r\n\r\n",
      body
    ]

    :ok = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp http_status_reason(200), do: "OK"
  defp http_status_reason(503), do: "Service Unavailable"
  defp http_status_reason(_status), do: "OK"
end
