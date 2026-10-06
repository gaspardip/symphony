defmodule SymphonyElixir.DeliveryEngine.TurnReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DeliveryEngine.TurnReport
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TurnResult

  setup do
    issue = %Issue{id: "turn-report-#{System.unique_integer([:positive])}", identifier: "REPORT-1"}
    :ok = TurnReport.reset(issue)
    %{issue: issue}
  end

  test "missing report remains explicit without inventing progress", %{issue: issue} do
    assert {:error, :missing_turn_result} = TurnReport.fetch(issue)
  end

  test "valid report takes precedence over earlier stream errors", %{issue: issue} do
    handler = TurnReport.message_handler(nil, issue)
    assert :ok = handler.(%{event: :turn_ended_with_error, reason: :turn_timeout})
    assert {:error, {:turn_runtime_error, [:turn_timeout]}} = TurnReport.fetch(issue)

    executor = TurnReport.tool_executor(issue, [])
    assert %{"success" => true} = executor.("report_agent_turn_result", report("Implemented"))
    assert {:ok, %TurnResult{summary: "Implemented", blocked: false}} = TurnReport.fetch(issue)
  end

  test "reset clears both channels for the next turn and preserves another issue", %{issue: issue} do
    other = %Issue{id: issue.id <> "-other", identifier: "REPORT-2"}
    executor = TurnReport.tool_executor(other, [])
    assert %{"success" => true} = executor.("report_agent_turn_result", report("Other issue"))
    assert :ok = TurnReport.message_handler(nil, issue).(%{event: :turn_ended_with_error, reason: :turn_timeout})
    assert %{"success" => true} = TurnReport.tool_executor(issue, []).("report_agent_turn_result", report("Old turn"))

    assert :ok = TurnReport.reset(issue)
    assert {:error, :missing_turn_result} = TurnReport.fetch(issue)
    assert {:ok, %TurnResult{summary: "Other issue"}} = TurnReport.fetch(other)
  end

  test "invalid report is rejected even when a runtime error was captured", %{issue: issue} do
    handler = TurnReport.message_handler(nil, issue)
    assert :ok = handler.(%{event: :turn_ended_with_error, reason: :turn_timeout})

    assert %{"success" => false} =
             TurnReport.tool_executor(issue, []).("report_agent_turn_result", report(""))

    assert {:error, {:invalid_turn_result, :empty_summary}} = TurnReport.fetch(issue)
  end

  test "failure formats preserve their order and ignore unrelated notifications", %{issue: issue} do
    handler = TurnReport.message_handler(nil, issue)
    assert :ok = handler.(%{event: :notification, payload: %{"method" => "thread/started"}})
    assert {:error, :missing_turn_result} = TurnReport.fetch(issue)
    assert :ok = handler.(%{event: :turn_ended_with_error, reason: {:port_exit, 7}})
    assert :ok = handler.(%{event: :notification, payload: %{"method" => "codex/event/stream_error", "params" => %{"message" => "stream lost"}}})

    assert {:error, {:turn_runtime_error, [{:port_exit, 7}, {:agent_notification_error, "codex/event/stream_error", %{"message" => "stream lost"}}]}} =
             TurnReport.fetch(issue)
  end

  test "legacy callback records and forwards the same message once", %{issue: issue} do
    handler = TurnReport.message_handler(self(), issue)
    message = %{event: :turn_ended_with_error, reason: :turn_timeout}
    issue_id = issue.id
    assert :ok = handler.(message)
    assert_receive {:agent_worker_update, ^issue_id, ^message}
    refute_receive {:agent_worker_update, ^issue_id, _}, 0
    assert {:error, {:turn_runtime_error, [:turn_timeout]}} = TurnReport.fetch(issue)
  end

  test "a worker report remains in the callback process", %{issue: issue} do
    executor = TurnReport.tool_executor(issue, [])

    task =
      Task.async(fn ->
        assert %{"success" => true} = executor.("report_agent_turn_result", report("Worker result"))
        TurnReport.fetch(issue)
      end)

    assert {:ok, %TurnResult{summary: "Worker result"}} = Task.await(task)
    assert {:error, :missing_turn_result} = TurnReport.fetch(issue)
  end

  test "unrecognized tools retain their explicit dynamic tool rejection", %{issue: issue} do
    assert %{"success" => false, "contentItems" => [%{"text" => text}]} =
             TurnReport.tool_executor(issue, []).("unknown_turn_report_tool", %{})

    assert text =~ "Unsupported dynamic tool"
    assert {:error, :missing_turn_result} = TurnReport.fetch(issue)
  end

  defp report(summary) do
    %{
      "summary" => summary,
      "files_touched" => [],
      "needs_another_turn" => false,
      "blocked" => false,
      "blocker_type" => "none"
    }
  end
end
