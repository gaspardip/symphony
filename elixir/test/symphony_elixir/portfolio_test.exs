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
end
