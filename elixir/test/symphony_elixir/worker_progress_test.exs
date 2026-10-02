defmodule SymphonyElixir.Orchestrator.WorkerProgressTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.WorkerProgress

  @timestamp ~U[2026-10-01 00:00:00Z]
  @progress_fields ~w(last_agent_timestamp last_agent_message session_id last_agent_event agent_process_id agent_input_tokens agent_output_tokens agent_total_tokens agent_last_reported_input_tokens agent_last_reported_output_tokens agent_last_reported_total_tokens turn_started_input_tokens turn_count recent_agent_updates)a

  test "explicit progress_only preserves authority and accounting despite payload counters" do
    original =
      entry()
      |> Map.merge(%{
        dispatch_ticket: %{run_id: "run", dispatch_id: "dispatch"},
        lease_token: %{epoch: 7},
        ref: make_ref(),
        custody_ref: make_ref(),
        agent_execution: %{live: %{binding: %{total_tokens: 120}}, stopped: :unchanged},
        issue_token_usage_base: %{total_tokens: 900},
        provider: "captured-provider",
        model: "captured-model",
        custom_field: %{keep: [1, 2, 3]},
        agent_input_tokens: 10,
        agent_output_tokens: 4,
        agent_total_tokens: 14,
        agent_last_reported_input_tokens: 10,
        agent_last_reported_output_tokens: 4,
        agent_last_reported_total_tokens: 14
      })

    update = Map.merge(update(%{input_tokens: 9_000, output_tokens: 8_000, total_tokens: 17_000}), %{session_id: "session", agent_process_id: 42})
    result = WorkerProgress.reduce(original, update, :progress_only)
    assert result.token_delta == delta(0, 0, 0, 0, 0, 0)
    assert counters(result.entry) == counters(original)
    assert Map.drop(result.entry, @progress_fields) == Map.drop(original, @progress_fields)
    assert result.entry.session_id == "session"
    assert result.entry.agent_process_id == "42"
    assert result.rate_limits == nil
  end

  test "mode is required and is not inferred from a ticket field" do
    sample = update(%{input_tokens: 2, output_tokens: 3, total_tokens: 5})
    assert WorkerProgress.reduce(entry(), sample, :progress_only).token_delta == delta(0, 0, 0, 0, 0, 0)
    assert WorkerProgress.reduce(Map.put(entry(), :dispatch_ticket, :opaque), sample, :legacy_usage).token_delta == delta(2, 3, 5, 2, 3, 5)
    assert_raise FunctionClauseError, fn -> WorkerProgress.reduce(entry(), sample, :automatic) end
    assert_raise KeyError, fn -> WorkerProgress.reduce(%{}, sample, :progress_only) end
    assert_raise FunctionClauseError, fn -> WorkerProgress.reduce(entry(), %{event: :notification}, :progress_only) end
  end

  test "legacy repeated and decreasing totals retain high water marks across a sequence" do
    first = WorkerProgress.reduce(entry(), update(%{input_tokens: 10, output_tokens: 4, total_tokens: 14}), :legacy_usage)
    repeated = WorkerProgress.reduce(first.entry, update(%{input_tokens: 10, output_tokens: 4, total_tokens: 14}), :legacy_usage)
    decreased = WorkerProgress.reduce(repeated.entry, update(%{input_tokens: 7, output_tokens: 3, total_tokens: 10}), :legacy_usage)
    next = WorkerProgress.reduce(decreased.entry, update(%{input_tokens: 15, output_tokens: 8, total_tokens: 23}), :legacy_usage)

    assert first.token_delta == delta(10, 4, 14, 10, 4, 14)
    assert repeated.token_delta == delta(0, 0, 0, 10, 4, 14)
    assert decreased.token_delta == delta(0, 0, 0, 7, 3, 10)
    assert counters(decreased.entry) == counters(first.entry)
    assert next.token_delta == delta(5, 4, 9, 15, 8, 23)
    assert next.entry.agent_total_tokens == 23
  end

  test "partial counters retain independent reported totals and missing usage adds nothing" do
    first = WorkerProgress.reduce(entry(), update(%{input_tokens: 10, output_tokens: 4, total_tokens: 14}), :legacy_usage)
    second = WorkerProgress.reduce(first.entry, update(%{output_tokens: 7}), :legacy_usage)
    missing = WorkerProgress.reduce(second.entry, update(%{}), :legacy_usage)
    assert second.token_delta == delta(0, 3, 0, 10, 7, 14)
    assert missing.token_delta == delta(0, 0, 0, 10, 7, 14)
    assert counters(missing.entry) == counters(second.entry)
  end

  for shape <- [:direct, :completed_string, :completed_atom] do
    test "legacy #{shape} usage retains its historical classification" do
      usage = %{input_tokens: 6, output_tokens: 2, total_tokens: 8}

      payload =
        case unquote(shape) do
          :direct -> usage
          :completed_string -> %{"method" => "turn/completed", "params" => %{"usage" => usage}}
          :completed_atom -> %{method: :turn_completed, usage: usage}
        end

      assert WorkerProgress.reduce(entry(), update(payload), :legacy_usage).token_delta == delta(6, 2, 8, 6, 2, 8)
    end
  end

  test "absolute payload paths outrank direct usage and preserve string before atom precedence" do
    sample = %{
      event: :notification,
      timestamp: @timestamp,
      usage: %{input_tokens: 100, output_tokens: 200, total_tokens: 300},
      payload: %{
        "params" => %{"tokenUsage" => %{"total" => %{input_tokens: 4, output_tokens: 6, total_tokens: 10}}},
        :params => %{tokenUsage: %{total: %{input_tokens: 70, output_tokens: 80, total_tokens: 150}}}
      }
    }

    assert WorkerProgress.reduce(entry(), sample, :legacy_usage).token_delta == delta(4, 6, 10, 4, 6, 10)
  end

  test "legacy numeric strings retain suffix parsing and field fallback without accepting floats" do
    payload = %{"input_tokens" => " 12tokens ", :input_tokens => 99, "output_tokens" => -2, "completion_tokens" => "3 trailing", "total_tokens" => 15.0, "totalTokens" => " 15.9 "}
    assert WorkerProgress.reduce(entry(), update(payload), :legacy_usage).token_delta == delta(12, 3, 15, 12, 3, 15)
    invalid = update(%{input_tokens: -1, output_tokens: 2.5, total_tokens: "invalid"})
    assert WorkerProgress.reduce(entry(), invalid, :legacy_usage).token_delta == delta(0, 0, 0, 0, 0, 0)
  end

  test "sessions preserve turn counts and refresh the input baseline on repeated starts" do
    start = %{update(%{input_tokens: 5, total_tokens: 5}) | event: :session_started} |> Map.put(:session_id, "first")
    first = WorkerProgress.reduce(entry(), start, :legacy_usage)
    repeated = WorkerProgress.reduce(first.entry, %{start | payload: %{input_tokens: 7, total_tokens: 7}}, :legacy_usage)
    second = WorkerProgress.reduce(repeated.entry, %{start | session_id: "second", payload: %{input_tokens: 10, total_tokens: 10}}, :legacy_usage)
    other = WorkerProgress.reduce(second.entry, update(%{input_tokens: 12, total_tokens: 12}), :legacy_usage)

    assert {first.entry.turn_count, first.entry.turn_started_input_tokens} == {1, 5}
    assert {repeated.entry.turn_count, repeated.entry.turn_started_input_tokens} == {1, 7}
    assert {second.entry.turn_count, second.entry.turn_started_input_tokens} == {2, 10}
    assert {other.entry.turn_count, other.entry.turn_started_input_tokens, other.entry.session_id} == {2, 10, "second"}
  end

  for {process_id, expected} <- [{"72", "72"}, {73, "73"}, {~c"74", "74"}, {%{}, "old"}] do
    test "agent process representation #{inspect(process_id)} preserves its existing conversion" do
      sample = Map.put(update(nil), :agent_process_id, unquote(Macro.escape(process_id)))
      result = WorkerProgress.reduce(%{entry() | agent_process_id: "old"}, sample, :progress_only)
      assert result.entry.agent_process_id == unquote(expected)
    end
  end

  test "history keeps the last twelve summaries and preserves raw fallback" do
    final = Enum.reduce(1..15, entry(), fn index, current -> WorkerProgress.reduce(current, update(%{index: index}), :progress_only).entry end)
    assert Enum.map(final.recent_agent_updates, & &1.message.index) == Enum.to_list(4..15)
    assert final.last_agent_message == %{event: :notification, message: %{index: 15}, timestamp: @timestamp}

    sample = Map.put(update(false), :raw, "fallback")
    malformed = %{entry() | recent_agent_updates: :unknown, turn_count: nil, turn_started_input_tokens: nil}
    result = WorkerProgress.reduce(malformed, sample, :progress_only)
    assert result.entry.recent_agent_updates == [%{event: :notification, message: "fallback", timestamp: @timestamp}]
    assert result.entry.turn_count == 0
    assert result.entry.turn_started_input_tokens == 0
  end

  test "rate limits prefer explicit valid fields and find nested maps in list order" do
    first = %{"limit_id" => "first", "primary" => %{"remaining" => 4}}
    second = %{limit_name: "second", credits: %{remaining: 2}}
    sample = Map.put(update([%{nested: second}]), :rate_limits, first)
    assert WorkerProgress.reduce(entry(), sample, :progress_only).rate_limits == first

    nested = update([%{rate_limits: %{limit_id: "incomplete"}}, %{nested: [second, first]}])
    assert WorkerProgress.reduce(entry(), nested, :legacy_usage).rate_limits == second
    assert WorkerProgress.reduce(entry(), update(%{rate_limits: %{limit_id: "incomplete"}}), :progress_only).rate_limits == nil
    assert WorkerProgress.reduce(entry(), update(%{limit_id: "", primary: nil}), :progress_only).rate_limits == %{limit_id: "", primary: nil}
  end

  defp entry do
    %{
      session_id: nil,
      agent_process_id: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      agent_last_reported_input_tokens: 0,
      agent_last_reported_output_tokens: 0,
      agent_last_reported_total_tokens: 0,
      turn_count: 0,
      turn_started_input_tokens: 0,
      recent_agent_updates: []
    }
  end

  defp update(payload), do: %{event: :notification, timestamp: @timestamp, payload: payload}

  defp delta(input, output, total, input_reported, output_reported, total_reported),
    do: %{input_tokens: input, output_tokens: output, total_tokens: total, input_reported: input_reported, output_reported: output_reported, total_reported: total_reported}

  defp counters(entry),
    do: Map.take(entry, [:agent_input_tokens, :agent_output_tokens, :agent_total_tokens, :agent_last_reported_input_tokens, :agent_last_reported_output_tokens, :agent_last_reported_total_tokens])
end
