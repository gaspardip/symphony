defmodule SymphonyElixir.SecretRedactionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DebugArtifacts, JsonLogFormatter, Observability, RunLedger, SecretRedactor}

  @canary "SYNTHETIC_NOT_A_REAL_SECRET_PB12_TEST_20260922"
  @second_canary "SYNTHETIC_NOT_A_REAL_PASSWORD_PB12_TEST"
  @marker "[REDACTED]"

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-pb12-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_debug_artifacts_enabled: true,
      observability_debug_capture_on_failure: true,
      observability_debug_artifact_root: root
    )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "sensitive keys redact duplicate values without changing correlation or token counters" do
    timestamp = ~U[2026-09-22 20:00:00Z]

    input = %{
      "API-Key" => @canary,
      "PASSWORD" => @second_canary,
      issue_identifier: "PB12-DEMO",
      event_id: "evt_pb12",
      rule_id: "permission.denied",
      trace_id: "trace_pb12",
      input_tokens: 12,
      output_tokens: 34,
      total_tokens: 46,
      token_count: 46,
      token_budget: %{limit: 200},
      observed_at: timestamp,
      nested: %{authorization: "Bearer #{@canary}", empty: [], absent: nil},
      message: "first #{@canary} second #{@second_canary}",
      pairs: [access_token: @second_canary],
      report: {:string, String.to_charlist("copy #{@canary}")}
    }

    result = SecretRedactor.redact(input)

    refute inspect(result) =~ @canary
    refute inspect(result) =~ @second_canary
    assert result["API-Key"] == @marker
    assert result["PASSWORD"] == @marker
    assert result.nested == %{authorization: @marker, empty: [], absent: nil}
    assert result.pairs == [access_token: @marker]
    assert result.report == {:string, String.to_charlist("copy #{@marker}")}
    assert result.observed_at == timestamp

    for key <- [:issue_identifier, :event_id, :rule_id, :trace_id, :input_tokens, :output_tokens, :total_tokens, :token_count, :token_budget] do
      assert result[key] == input[key]
    end

    assert SecretRedactor.redact(result) == result
  end

  test "Unicode charlist secrets redact binary and charlist copies in structured evidence" do
    secret = "SYNTHETIC_NOT_A_REAL_SECRET_PB12_sëcret_漢字_🔒"
    charlist = String.to_charlist(secret)

    redacted =
      SecretRedactor.redact(%{
        password: charlist,
        message: "copy #{secret}",
        duplicate: String.to_charlist("copy #{secret}"),
        token_count: 42,
        invalid_codepoint_list: [0xD800]
      })

    assert redacted.password == String.to_charlist(@marker)
    assert redacted.message == "copy #{@marker}"
    assert redacted.duplicate == String.to_charlist("copy #{@marker}")
    assert redacted.invalid_codepoint_list == [0xD800]
    assert redacted.token_count == 42

    json =
      JsonLogFormatter.format(
        %{level: :info, msg: {:string, String.to_charlist("copy #{secret}")}, meta: %{password: charlist, event: "pb12.unicode"}},
        %{}
      )
      |> IO.iodata_to_binary()

    refute json =~ secret
    assert Jason.decode!(json)["message"] == "copy #{@marker}"
  end

  test "raw Bearer and key=value values are redacted across the full envelope" do
    input = %{
      raw: "Authorization: Bearer #{@canary}\nOPENAI_API_KEY='#{@second_canary}'\ninput_tokens=12",
      message: "copies #{@canary} #{@second_canary}",
      metadata: %{issue_identifier: "PB12-DEMO", input_tokens: 12}
    }

    result = SecretRedactor.redact(input)

    refute Jason.encode!(result) =~ @canary
    refute Jason.encode!(result) =~ @second_canary
    assert result.raw =~ "input_tokens=12"
    assert result.metadata == input.metadata
    assert result.message == "copies #{@marker} #{@marker}"
    assert SecretRedactor.redact(result) == result
  end

  test "debug gzip and manifest share redaction and hash the bytes actually stored" do
    payload = %{api_key: @canary, message: "synthetic payload #{@canary}", input_tokens: 17}
    metadata = %{authorization: "Bearer #{@canary}", message: "copy #{@canary}", event_id: "evt_pb12", rule_id: "permission.denied"}

    assert {:ok, artifact} = DebugArtifacts.store("pb12-synthetic-canary", payload, metadata)
    bytes = artifact.path |> File.read!() |> :zlib.gunzip()
    manifest_json = File.read!(artifact.manifest_path)
    manifest = Jason.decode!(manifest_json)
    decoded = Jason.decode!(bytes)

    refute bytes =~ @canary
    refute manifest_json =~ @canary
    assert decoded["api_key"] == @marker
    assert decoded["message"] == "synthetic payload #{@marker}"
    assert decoded["input_tokens"] == 17
    assert manifest["metadata"]["authorization"] == @marker
    assert manifest["metadata"]["event_id"] == "evt_pb12"
    assert manifest["metadata"]["rule_id"] == "permission.denied"
    assert manifest["artifact_id"] == artifact.artifact_id
    assert manifest["sha256"] == artifact.sha256
    assert artifact.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert manifest["bytes"] == artifact.bytes
    assert artifact.bytes == byte_size(bytes)
  end

  test "metadata-only secrets redact split iodata payload before truncation", %{root: root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      observability_debug_artifact_root: root,
      observability_debug_artifact_max_bytes: 80,
      observability_debug_artifact_tail_bytes: 60
    )

    payload = [String.duplicate("safe ", 40), "copy ", String.slice(@canary, 0, 10), String.slice(@canary, 10..-1//1)]

    assert {:ok, artifact} = DebugArtifacts.store_failure("pb12", payload, %{api_key: @canary, issue_identifier: "PB12-DEMO"})
    bytes = artifact.path |> File.read!() |> :zlib.gunzip()
    manifest_json = File.read!(artifact.manifest_path)

    assert artifact.truncated
    refute bytes =~ @canary
    refute manifest_json =~ @canary
    assert bytes =~ "copy #{@marker}"
    assert artifact.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  test "JSON logger redacts metadata and duplicated message while preserving event and trace" do
    json =
      JsonLogFormatter.format(
        %{
          level: :info,
          msg: {:string, "synthetic message #{@canary}"},
          meta: %{
            event: "pb12.synthetic_canary",
            api_key: @canary,
            issue_identifier: "PB12-DEMO",
            rule_id: "permission.denied",
            trace_id: "trace_pb12",
            span_id: "span_pb12",
            input_tokens: 19
          }
        },
        %{}
      )
      |> IO.iodata_to_binary()

    payload = Jason.decode!(json)
    refute json =~ @canary
    assert payload["message"] == "synthetic message #{@marker}"
    assert payload["metadata"]["api_key"] == @marker
    assert payload["metadata"]["input_tokens"] == 19
    assert payload["event"] == "pb12.synthetic_canary"
    assert payload["issue_identifier"] == "PB12-DEMO"
    assert payload["rule_id"] == "permission.denied"
    assert payload["trace_id"] == "trace_pb12"
    assert payload["span_id"] == "span_pb12"
  end

  test "structured logger reports are redacted before inspection" do
    json =
      JsonLogFormatter.format(
        %{level: :error, msg: {:report, %{client_secret: @canary, message: "copy #{@canary}"}}, meta: %{event: "pb12.report"}},
        %{}
      )
      |> IO.iodata_to_binary()

    refute json =~ @canary
    assert Jason.decode!(json)["message"] =~ @marker
  end

  test "logger redacts raw authentication text split across chardata chunks" do
    chunks = [~c"Authorization: Bearer ", String.slice(@canary, 0, 10), String.slice(@canary, 10..-1//1)]

    json =
      JsonLogFormatter.format(%{level: :info, msg: {:string, chunks}, meta: %{event: "pb12.chardata"}}, %{})
      |> IO.iodata_to_binary()

    refute json =~ @canary
    assert Jason.decode!(json)["message"] =~ @marker
    assert Jason.decode!(json)["event"] == "pb12.chardata"
  end

  test "legacy and typed ledger writes remove canary and retain disk and artifact correlation" do
    assert :ok =
             RunLedger.append("pb12.synthetic_canary", %{
               issue_id: "pb12-diagnostic",
               payload: %{api_key: @canary, message: "copy #{@canary}"},
               metadata: %{authorization: "Bearer #{@canary}", synthetic_fixture: true}
             })

    entry =
      RunLedger.record("policy.decided", %{
        issue_id: "pb12-diagnostic",
        issue_identifier: "PB12-DEMO",
        rule_id: "permission.denied",
        summary: "denied #{@canary}",
        details: "copy #{@canary}",
        metadata: %{api_key: @canary, trace_id: "trace_pb12", total_tokens: 21}
      })

    jsonl = File.read!(RunLedger.ledger_file_path())
    rows = jsonl |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    legacy = Enum.find(rows, &(&1["event"] == "pb12.synthetic_canary"))
    typed = Enum.find(rows, &(&1["event_id"] == entry.event_id))

    refute jsonl =~ @canary
    refute Jason.encode!(entry) =~ @canary
    assert legacy["payload"]["api_key"] == @marker
    assert legacy["payload"]["message"] == "copy #{@marker}"
    assert legacy["metadata"]["authorization"] == @marker
    assert typed == entry |> Jason.encode!() |> Jason.decode!()
    assert typed["event"] == "policy.decided"
    assert typed["rule_id"] == "permission.denied"
    assert typed["metadata"]["trace_id"] == "trace_pb12"
    assert typed["metadata"]["total_tokens"] == 21
    assert typed["summary"] == "denied #{@marker}"

    assert {:ok, artifact} = DebugArtifacts.store("pb12-correlated", entry, %{event_id: entry.event_id, rule_id: entry.rule_id})
    manifest = artifact.manifest_path |> File.read!() |> Jason.decode!()
    assert manifest["metadata"]["event_id"] == typed["event_id"]
    assert manifest["metadata"]["rule_id"] == typed["rule_id"]
  end

  test "OTP task crash reports preserve improper elixir_translation chardata" do
    stacktrace = [{SymphonyElixir.RunStateStore, :transition_from_state, 4, [file: ~c"lib/symphony_elixir/run_state_store.ex", line: 258]}]
    reason = {{:badmatch, {:error, :enoent}}, stacktrace}

    report = %{
      label: {Task.Supervisor, :terminating},
      report: %{args: [], function: fn -> :ok end, name: self(), reason: reason, process_label: :undefined, starter: self()},
      elixir_translation: [
        "Task terminating",
        [
          [10 | "** (MatchError) no match of right hand side value: {:error, :enoent}\n"],
          ["\n    " | "lib/symphony_elixir/run_state_store.ex:258: SymphonyElixir.RunStateStore.transition_from_state/4"]
        ],
        "\nFunction: anonymous function",
        "\n    Args: []"
      ]
    }

    event = %{
      level: :error,
      msg: {:report, report},
      meta: %{error_logger: %{tag: :error_msg}, pid: self(), domain: [:otp, :elixir], crash_reason: {%MatchError{term: {:error, :enoent}}, stacktrace}}
    }

    assert SecretRedactor.redact(event) == event
    json = JsonLogFormatter.format(event, %{}) |> IO.iodata_to_binary()
    payload = Jason.decode!(json)
    assert payload["level"] == "error"
    assert payload["message"] == inspect(report, pretty: false, limit: 50)
    assert payload["message"] =~ "MatchError"
    assert payload["message"] =~ "enoent"
    assert payload["metadata"]["error_logger"] == "%{tag: :error_msg}"
  end

  test "secret collection and replacement traverse improper list tails without changing their shape" do
    input = %{
      api_key: [@canary | @second_canary],
      message: [10 | "copies #{@canary} #{@second_canary}"],
      nested: [["safe prefix" | "copy #{@canary}"]],
      input_tokens: 42
    }

    result = SecretRedactor.redact(input)

    assert result.api_key == [@marker | @marker]
    assert result.message == [10 | "copies #{@marker} #{@marker}"]
    assert result.nested == [["safe prefix" | "copy #{@marker}"]]
    assert result.input_tokens == 42
    assert SecretRedactor.redact(result) == result
    refute inspect(result) =~ @canary
    refute inspect(result) =~ @second_canary
  end

  test "JSON logger handles binary-tailed strings and redacts improper metadata before serialization" do
    event = %{
      level: :error,
      msg: {:string, ["Authorization: Bearer " | @canary]},
      meta: %{event: "pb12.improper_chardata", api_key: @canary, diagnostic: [10 | "copy #{@canary}"], trace_id: "trace_pb12"}
    }

    json = JsonLogFormatter.format(event, %{}) |> IO.iodata_to_binary()
    payload = Jason.decode!(json)

    refute json =~ @canary
    assert payload["message"] == "Authorization: Bearer #{@marker}"
    assert payload["metadata"]["diagnostic"] == inspect([10 | "copy #{@marker}"])
    assert payload["event"] == "pb12.improper_chardata"
    assert payload["trace_id"] == "trace_pb12"
  end

  test "telemetry redacts before truncating values and preserves numeric measurements" do
    handler_id = "pb12-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:symphony, :pb12, :redaction],
        fn event, measurements, metadata, _config -> send(parent, {event, measurements, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             Observability.emit(
               [:symphony, :pb12, :redaction],
               %{input_tokens: 12, output_tokens: 34, total_tokens: 46},
               %{api_key: @canary, message: String.duplicate("x", 980) <> @canary, event_id: "evt_pb12", rule_id: "permission.denied"}
             )

    assert_receive {[:symphony, :pb12, :redaction], measurements, metadata}
    assert measurements == %{input_tokens: 12, output_tokens: 34, total_tokens: 46}
    refute inspect(metadata) =~ @canary
    assert metadata.api_key == @marker
    assert metadata.message == String.duplicate("x", 980) <> @marker
    assert metadata.event_id == "evt_pb12"
    assert metadata.rule_id == "permission.denied"
  end
end
