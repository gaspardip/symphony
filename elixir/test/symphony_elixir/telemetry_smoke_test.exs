defmodule SymphonyElixir.TelemetrySmokeTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.{DebugArtifacts, Observability, Workflow}

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
      {:reply, Keyword.get(state, :refresh, %{ok: true}), state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "smoke proves operator telemetry surfaces expose state, metrics, and debug artifacts" do
    debug_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-telemetry-smoke-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(debug_root) end)

    orchestrator_name = :"telemetry-smoke-#{System.unique_integer([:positive])}"

    snapshot = %{
      running: [],
      retrying: [],
      paused: [],
      skipped: [],
      queue: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      rate_limits: %{},
      runner: %{
        instance_name: "stable-smoke",
        channel: "stable",
        dispatch_enabled: true,
        current_version_sha: "smoke-sha"
      },
      webhooks: %{health: "healthy", mode: "webhook_first"},
      github_webhooks: %{health: "healthy", mode: "webhook_first"},
      tracker_inbox: %{depth: 0, last_drained_at: nil},
      github_inbox: %{depth: 0, last_drained_at: nil},
      polling: %{dispatch_mode: "webhook_first", tracker_reads_paused: false}
    }

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    write_workflow_file!(Workflow.workflow_file_path(),
      company_name: "Symphony",
      company_repo_url: "https://github.com/gaspardip/symphony",
      observability_debug_artifact_root: debug_root
    )

    metadata = %{
      issue_identifier: "CLZ-22",
      issue_source: "linear",
      policy_class: "fully_autonomous",
      workflow_profile: "private_autopilot"
    }

    Observability.with_stage("implement", metadata, fn -> :ok end)

    Observability.emit(
      [:symphony, :tokens, :turn],
      %{count: 1, input_tokens: 11, output_tokens: 7, total_tokens: 18},
      %{
        stage: "implement",
        issue_source: "linear",
        model_provider: "openai",
        model_name: "gpt-5.4"
      }
    )

    assert {:ok, artifact} =
             DebugArtifacts.store_failure(
               "telemetry_smoke",
               %{error: "boom", stage: "validate"},
               %{issue_identifier: "CLZ-22", stage: "validate"}
             )

    assert File.exists?(artifact.path)
    assert File.exists?(artifact.manifest_path)

    :ok =
      Observability.emit_debug_artifact_reference(
        "validate.failure",
        artifact,
        %{issue_identifier: "CLZ-22", stage: "validate"}
      )

    metrics_body =
      build_conn()
      |> get("/metrics")
      |> response(200)

    assert metrics_body =~ "symphony_stage_starts_total"
    assert metrics_body =~ "symphony_stage_stops_total"
    assert metrics_body =~ "symphony_tokens_total"
    assert metrics_body =~ "symphony_debug_artifacts_total"

    state_payload =
      build_conn()
      |> get("/api/v1/state")
      |> json_response(200)

    assert is_binary(state_payload["generated_at"])

    assert state_payload["counts"] == %{
             "paused" => 0,
             "queue" => 0,
             "retrying" => 0,
             "running" => 0,
             "skipped" => 0
           }

    assert state_payload["runner"]["instance_name"] == "stable-smoke"
    assert state_payload["runner"]["current_version_sha"] == "smoke-sha"
    assert state_payload["webhooks"]["health"] == "healthy"
    assert state_payload["github_inbox"]["depth"] == 0

    report_payload =
      build_conn()
      |> get("/api/v1/reports/delivery")
      |> json_response(200)

    assert is_binary(report_payload["generated_at"])
    assert report_payload["summary"]["recent_deliveries"] == 0
  end

  test "token metrics preserve legacy labels and explicitly export missing labels" do
    start_supervised!({TelemetryMetricsPrometheus.Core, metrics: SymphonyElixir.Observability.Metrics.metrics(), name: :legacy_usage_metrics, start_async: false})
    entry = %{issue: %{id: "metric-legacy", identifier: "METRIC-1", source: :tracker}, stage: "implement"}
    delta = %{input_tokens: 11, output_tokens: 7, total_tokens: 18}
    assert :ok = Observability.emit_token_delta(entry, delta, %{event: :turn_completed, usage: %{"provider" => "openai", "model" => "reported-model"}})
    assert :ok = Observability.emit_token_delta(entry, delta, %{event: :usage_observed})
    assert :ok = Observability.emit_token_delta(entry, %{input_tokens: 0, output_tokens: 0, total_tokens: 0}, %{event: :usage_observed})
    body = TelemetryMetricsPrometheus.Core.scrape(:legacy_usage_metrics) |> IO.iodata_to_binary()

    for {name, value} <- [{"symphony_tokens_input_total", 11}, {"symphony_tokens_output_total", 7}, {"symphony_tokens_total", 18}, {"symphony_tokens_turns_total", 1}] do
      lines = body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, name <> "{"))
      assert length(lines) == 2
      assert Enum.any?(lines, &(&1 =~ "model_provider=\"openai\"" and &1 =~ "model_name=\"reported-model\"" and String.ends_with?(&1, " #{value}")))
      assert Enum.any?(lines, &(&1 =~ "model_provider=\"unreported\"" and &1 =~ "model_name=\"unreported\"" and String.ends_with?(&1, " #{value}")))
    end
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
end
