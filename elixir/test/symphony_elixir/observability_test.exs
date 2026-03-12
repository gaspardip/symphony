defmodule SymphonyElixir.ObservabilityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, DebugArtifacts, JsonLogFormatter, RunLedger, Workflow}

  test "config exposes observability settings and debug artifact overrides" do
    debug_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-observability-config-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_enabled: true,
      observability_metrics_enabled: true,
      observability_metrics_path: "/internal/metrics",
      observability_tracing_enabled: false,
      observability_structured_logs: true,
      observability_debug_artifacts_enabled: true,
      observability_debug_capture_on_failure: false,
      observability_debug_artifact_root: debug_root,
      observability_debug_artifact_max_bytes: 2048,
      observability_debug_artifact_tail_bytes: 256
    )

    settings = Config.observability()

    assert settings.metrics_enabled == true
    assert settings.metrics_path == "/internal/metrics"
    assert settings.tracing_enabled == false
    assert settings.structured_logs == true
    assert settings.debug_artifacts.capture_on_failure == false
    assert settings.debug_artifacts.root == debug_root
    assert settings.debug_artifacts.max_bytes == 2048
    assert settings.debug_artifacts.tail_bytes == 256
  end

  test "debug artifacts store bounded local payloads" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-debug-artifacts-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        observability_debug_artifact_root: root,
        observability_debug_artifact_max_bytes: 64,
        observability_debug_artifact_tail_bytes: 32
      )

      payload = String.duplicate("abcdef", 20)

      assert {:ok, artifact} =
               DebugArtifacts.store_failure("test_failure", payload, %{issue_identifier: "CLZ-22"})

      assert artifact.truncated == true
      assert File.exists?(artifact.path)
      assert File.exists?(artifact.manifest_path)

      assert {:ok, manifest_body} = File.read(artifact.manifest_path)
      assert {:ok, manifest} = Jason.decode(manifest_body)
      assert manifest["artifact_id"] == artifact.artifact_id
      assert manifest["kind"] == "test_failure"
      assert manifest["truncated"] == true
    after
      File.rm_rf(root)
    end
  end

  test "json log formatter emits stable structured fields" do
    formatted =
      JsonLogFormatter.format(
        :info,
        {:string, ~c"hello world"},
        {{2026, 3, 12}, {18, 30, 45}, 123_456},
        event: "stage.start",
        issue_identifier: "CLZ-22",
        source: "tracker",
        stage: "implement",
        rule_id: "policy.ok",
        policy_class: "fully_autonomous",
        trace_id: "abc123",
        span_id: "def456",
        custom: "value"
      )
      |> IO.iodata_to_binary()

    assert {:ok, payload} = Jason.decode(formatted)
    assert payload["event"] == "stage.start"
    assert payload["issue_identifier"] == "CLZ-22"
    assert payload["stage"] == "implement"
    assert payload["trace_id"] == "abc123"
    assert payload["metadata"]["custom"] == "value"
  end

  test "run ledger emits mapped telemetry events" do
    test_pid = self()
    handler_id = "observability-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:symphony, :ledger, :event], [:symphony, :operator, :action]],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

    try do
      _ =
        RunLedger.record("operator.action", %{
          issue_identifier: "CLZ-22",
          metadata: %{action: "pause"}
        })

      assert_receive {:telemetry_event, [:symphony, :ledger, :event], %{count: 1}, %{event_type: "operator.action"}}, 1_000

      assert_receive {:telemetry_event, [:symphony, :operator, :action], %{count: 1}, metadata}, 1_000
      assert metadata.action == "pause"
      assert metadata.issue_identifier == "CLZ-22"
    after
      :telemetry.detach(handler_id)
    end
  end
end
