defmodule SymphonyElixir.Observability.Supervisor do
  @moduledoc """
  Starts observability sinks and attaches OpenTelemetry integrations.
  """

  use Supervisor

  alias SymphonyElixir.Config
  alias SymphonyElixir.Observability.Metrics

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    setup_tracing()

    children =
      if Config.observability_metrics_enabled?() do
        [
          {TelemetryMetricsPrometheus.Core, metrics: Metrics.metrics(), name: Metrics.prometheus_name()}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp setup_tracing do
    maybe_setup_module(OpentelemetryLoggerMetadata)

    if Config.observability_tracing_enabled?() do
      maybe_setup_module(OpentelemetryPhoenix)
      maybe_setup_module(OpentelemetryBandit)
    end
  end

  defp maybe_setup_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :setup, 0) do
      module.setup()
    else
      :ok
    end
  rescue
    _error -> :ok
  end
end
