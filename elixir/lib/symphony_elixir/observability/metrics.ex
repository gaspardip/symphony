defmodule SymphonyElixir.Observability.Metrics do
  @moduledoc """
  Telemetry.Metrics definitions and Prometheus scrape access for Symphony.
  """

  import Telemetry.Metrics

  @prometheus_name :symphony_prometheus_metrics

  @spec prometheus_name() :: atom()
  def prometheus_name, do: @prometheus_name

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      counter("symphony.stage.starts.total",
        event_name: [:symphony, :stage, :start],
        measurement: :count,
        tags: [:stage, :issue_source, :policy_class, :workflow_profile]
      ),
      counter("symphony.stage.stops.total",
        event_name: [:symphony, :stage, :stop],
        measurement: :count,
        tags: [:stage, :outcome, :issue_source, :policy_class, :workflow_profile]
      ),
      distribution("symphony.stage.duration",
        event_name: [:symphony, :stage, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1_000, 5_000, 15_000, 60_000]],
        tags: [:stage, :outcome, :issue_source, :policy_class]
      ),
      counter("symphony.tokens.turns.total",
        event_name: [:symphony, :tokens, :turn],
        measurement: :count,
        tags: [:stage, :issue_source, :model_provider, :model_name]
      ),
      sum("symphony.tokens.input.total",
        event_name: [:symphony, :tokens, :turn],
        measurement: :input_tokens,
        tags: [:stage, :model_provider, :model_name]
      ),
      sum("symphony.tokens.output.total",
        event_name: [:symphony, :tokens, :turn],
        measurement: :output_tokens,
        tags: [:stage, :model_provider, :model_name]
      ),
      sum("symphony.tokens.total",
        event_name: [:symphony, :tokens, :turn],
        measurement: :total_tokens,
        tags: [:stage, :model_provider, :model_name]
      ),
      counter("symphony.intake.linear.webhooks.accepted.total",
        event_name: [:symphony, :intake, :tracker, :webhook, :accepted],
        measurement: :count
      ),
      counter("symphony.intake.linear.webhooks.ignored.total",
        event_name: [:symphony, :intake, :tracker, :webhook, :ignored],
        measurement: :count,
        tags: [:reason, :rule_id]
      ),
      counter("symphony.intake.linear.webhooks.rejected.total",
        event_name: [:symphony, :intake, :tracker, :webhook, :rejected],
        measurement: :count,
        tags: [:reason, :rule_id]
      ),
      counter("symphony.intake.github.webhooks.accepted.total",
        event_name: [:symphony, :intake, :github, :webhook, :accepted],
        measurement: :count
      ),
      counter("symphony.intake.github.webhooks.ignored.total",
        event_name: [:symphony, :intake, :github, :webhook, :ignored],
        measurement: :count,
        tags: [:reason, :rule_id]
      ),
      counter("symphony.intake.github.webhooks.rejected.total",
        event_name: [:symphony, :intake, :github, :webhook, :rejected],
        measurement: :count,
        tags: [:reason, :rule_id]
      ),
      counter("symphony.intake.linear.backoff.total",
        event_name: [:symphony, :intake, :tracker, :backoff, :entered],
        measurement: :count,
        tags: [:rule_id]
      ),
      distribution("symphony.intake.linear.backoff.delay",
        event_name: [:symphony, :intake, :tracker, :backoff, :entered],
        measurement: :retry_after_ms,
        reporter_options: [buckets: [1_000, 5_000, 15_000, 60_000, 300_000, 900_000, 1_800_000]],
        tags: [:rule_id]
      ),
      counter("symphony.operator.actions.total",
        event_name: [:symphony, :operator, :action],
        measurement: :count,
        tags: [:action, :policy_class]
      ),
      counter("symphony.runtime.stops.total",
        event_name: [:symphony, :runtime, :stopped],
        measurement: :count,
        tags: [:failure_class, :rule_id, :stage]
      ),
      counter("symphony.repairs.total",
        event_name: [:symphony, :repair, :applied],
        measurement: :count,
        tags: [:repair_stage]
      ),
      counter("symphony.debug.artifacts.total",
        event_name: [:symphony, :debug, :artifact, :stored],
        measurement: :count,
        tags: [:event_type, :artifact_truncated]
      ),
      sum("symphony.debug.artifacts.bytes",
        event_name: [:symphony, :debug, :artifact, :stored],
        measurement: :bytes,
        tags: [:event_type]
      ),
      counter("symphony.agent_turn.starts.total",
        event_name: [:symphony, :agent_turn, :start],
        measurement: :count,
        tags: [:stage, :provider, :model]
      ),
      counter("symphony.agent_turn.stops.total",
        event_name: [:symphony, :agent_turn, :stop],
        measurement: :count,
        tags: [:stage, :provider, :model, :result]
      ),
      distribution("symphony.agent_turn.duration",
        event_name: [:symphony, :agent_turn, :stop],
        measurement: :duration_ms,
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 15_000, 60_000, 300_000]],
        tags: [:stage, :result]
      ),
      sum("symphony.agent_turn.input_tokens.total",
        event_name: [:symphony, :agent_turn, :stop],
        measurement: :input_tokens,
        tags: [:stage, :model]
      ),
      sum("symphony.agent_turn.output_tokens.total",
        event_name: [:symphony, :agent_turn, :stop],
        measurement: :output_tokens,
        tags: [:stage, :model]
      )
    ]
  end

  @spec scrape() :: iodata()
  def scrape do
    TelemetryMetricsPrometheus.Core.scrape(@prometheus_name)
  end
end
