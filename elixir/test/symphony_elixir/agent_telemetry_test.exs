defmodule SymphonyElixir.AgentTelemetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeliveryEngine

  @handler_id "agent_telemetry_test_#{:erlang.unique_integer([:positive])}"

  setup do
    test_pid = self()

    :telemetry.attach_many(
      @handler_id,
      [
        [:symphony, :agent_turn, :start],
        [:symphony, :agent_turn, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(@handler_id) end)
    :ok
  end

  defp fake_issue(identifier \\ "CLZ-99") do
    %{identifier: identifier}
  end

  describe "agent turn telemetry" do
    test "emits :start and :stop events for plan turn" do
      issue = fake_issue("CLZ-1")
      start_time = System.monotonic_time(:millisecond)
      turn_result = {:ok, %{usage: %{input_tokens: 100, output_tokens: 50}}}

      DeliveryEngine.emit_agent_turn_start("plan", "TestProvider", "claude-test", issue)
      DeliveryEngine.emit_agent_turn_stop("plan", "TestProvider", "claude-test", issue, start_time, turn_result)

      assert_received {:telemetry, [:symphony, :agent_turn, :start], _measurements, start_meta}
      assert start_meta.stage == "plan"
      assert start_meta.provider == "TestProvider"
      assert start_meta.model == "claude-test"
      assert start_meta.issue_identifier == "CLZ-1"

      assert_received {:telemetry, [:symphony, :agent_turn, :stop], stop_measurements, stop_meta}
      assert stop_meta.stage == "plan"
      assert stop_meta.result == "ok"
      assert stop_measurements.duration_ms >= 0
      assert stop_measurements.input_tokens == 100
      assert stop_measurements.output_tokens == 50
    end

    test "emits :start and :stop events for implement turn" do
      issue = fake_issue("CLZ-2")
      start_time = System.monotonic_time(:millisecond)
      turn_result = {:ok, %{usage: %{input_tokens: 200, output_tokens: 75}}}

      DeliveryEngine.emit_agent_turn_start("implement", "TestProvider", "claude-test", issue)
      DeliveryEngine.emit_agent_turn_stop("implement", "TestProvider", "claude-test", issue, start_time, turn_result)

      assert_received {:telemetry, [:symphony, :agent_turn, :start], _measurements, start_meta}
      assert start_meta.stage == "implement"
      assert start_meta.issue_identifier == "CLZ-2"

      assert_received {:telemetry, [:symphony, :agent_turn, :stop], stop_measurements, stop_meta}
      assert stop_meta.stage == "implement"
      assert stop_meta.result == "ok"
      assert stop_measurements.duration_ms >= 0
      assert stop_measurements.input_tokens == 200
      assert stop_measurements.output_tokens == 75
    end

    test "emits :stop with error result and zero tokens on failed turn" do
      issue = fake_issue("CLZ-3")
      start_time = System.monotonic_time(:millisecond)
      turn_result = {:error, :timeout}

      DeliveryEngine.emit_agent_turn_start("plan", "TestProvider", "claude-test", issue)
      DeliveryEngine.emit_agent_turn_stop("plan", "TestProvider", "claude-test", issue, start_time, turn_result)

      assert_received {:telemetry, [:symphony, :agent_turn, :start], _measurements, _start_meta}

      assert_received {:telemetry, [:symphony, :agent_turn, :stop], stop_measurements, stop_meta}
      assert stop_meta.result == "error"
      assert stop_measurements.duration_ms >= 0
      assert stop_measurements.input_tokens == 0
      assert stop_measurements.output_tokens == 0
    end
  end
end
