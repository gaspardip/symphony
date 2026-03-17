defmodule SymphonyElixir.Portfolio do
  @moduledoc """
  Aggregates multiple Symphony instances into a simple operator portfolio view.
  """

  alias SymphonyElixir.Config

  @type instance_summary :: %{
          name: String.t() | nil,
          url: String.t(),
          healthy: boolean(),
          company: map() | nil,
          counts: map(),
          triage: map() | nil,
          error: String.t() | nil
        }

  @spec summary() :: %{instances: [instance_summary()], totals: map()}
  def summary do
    instances =
      Config.portfolio_instances()
      |> Enum.map(&fetch_instance_summary/1)

    %{
      instances: instances,
      totals: %{
        instances: length(instances),
        healthy_instances: Enum.count(instances, & &1.healthy),
        running: Enum.reduce(instances, 0, &(&1.counts.running + &2)),
        attention_now:
          Enum.reduce(instances, 0, fn instance, acc ->
            acc + normalize_int(get_in(instance, [:triage, "summary", "attention_now"]))
          end)
      }
    }
  end

  defp fetch_instance_summary(%{} = instance) do
    name = Map.get(instance, :name) || Map.get(instance, "name")
    url = Map.get(instance, :url) || Map.get(instance, "url")

    case fetcher().(url) do
      {:ok, %{"company" => company, "counts" => counts} = payload} ->
        %{
          name: name,
          url: url,
          healthy: true,
          company: company,
          counts: normalize_counts(counts),
          triage: Map.get(payload, "triage"),
          error: nil
        }

      {:error, reason} ->
        %{
          name: name,
          url: url,
          healthy: false,
          company: nil,
          counts: %{running: 0, retrying: 0, paused: 0, queue: 0, skipped: 0},
          triage: nil,
          error: to_string(reason)
        }
    end
  end

  defp fetcher do
    Application.get_env(:symphony_elixir, :portfolio_fetcher, &default_fetch/1)
  end

  defp default_fetch(nil), do: {:error, "missing_url"}

  defp default_fetch(url) when is_binary(url) do
    report_url = String.trim_trailing(url, "/") <> "/api/v1/state"

    case Req.get(report_url) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, "http_#{status}"}
      {:error, error} -> {:error, inspect(error)}
    end
  end

  defp normalize_counts(counts) when is_map(counts) do
    %{
      running: normalize_int(Map.get(counts, "running") || Map.get(counts, :running)),
      retrying: normalize_int(Map.get(counts, "retrying") || Map.get(counts, :retrying)),
      paused: normalize_int(Map.get(counts, "paused") || Map.get(counts, :paused)),
      queue: normalize_int(Map.get(counts, "queue") || Map.get(counts, :queue)),
      skipped: normalize_int(Map.get(counts, "skipped") || Map.get(counts, :skipped))
    }
  end

  defp normalize_counts(_counts), do: %{running: 0, retrying: 0, paused: 0, queue: 0, skipped: 0}

  defp normalize_int(value) when is_integer(value), do: value
  defp normalize_int(_value), do: 0
end
