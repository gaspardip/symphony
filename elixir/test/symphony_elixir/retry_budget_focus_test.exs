defmodule SymphonyElixir.RetryBudgetFocusTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryBudget.{Focus, Observation}

  test "an explicit primary path does not discover unrelated messages" do
    assert Focus.primary_path(%{}, %{target_paths: ["lib/accepted.ex"]}) == "lib/accepted.ex"
  end

  test "an explicit expansion path does not query malformed candidate data" do
    assert Focus.next_path(%{}, %{target_paths: [fn -> :invalid end], next_required_path: "lib/required.ex"}, "lib/primary.ex") ==
             "lib/required.ex"
  end

  test "issue paths precede agent paths and blank preferred text suppresses fallback" do
    entry = entry(%{text: "lib/issue.ex"}, %{text: "", other: "lib/hidden.ex"}, "lib/agent.ex")
    assert Focus.primary_path(entry, %{}) == "lib/issue.ex"
    assert Focus.next_path(entry, %{}, "lib/issue.ex") == "lib/agent.ex"
  end

  test "paired diff markers normalize without rewriting a genuine a-prefixed path" do
    assert Focus.normalize_paths(["a/lib/change.ex", "b/lib/change.ex", "change.ex", "lib/change.ex"]) ==
             ["lib/change.ex"]

    assert Focus.normalize_paths(["a/real.ex"]) == ["a/real.ex"]
  end

  test "retry overrides preserve eager candidate validation" do
    assert_raise Protocol.UndefinedError, fn ->
      Focus.retry_fields(entry(nil, nil, nil), %{target_paths: [fn -> :invalid end]}, %{target_paths: ["lib/accepted.ex"]})
    end
  end

  test "all summaries are consumed even with an explicit focus and an earlier valid summary" do
    error =
      assert_raise Protocol.UndefinedError, fn ->
        Focus.retry_fields(entry(nil, "valid summary", fn -> :must_not_execute end), %{target_paths: ["lib/accepted.ex"], last_turn_summary: "first summary"}, %{})
      end

    assert error.protocol == String.Chars
    assert error.value == {:unsupported_budget_summary}
  end

  test "scalar summaries remain available without path inference" do
    assert %{target_paths: [], already_learned: "42"} =
             Focus.retry_fields(entry(nil, nil, nil), %{last_turn_summary: 42}, %{})
  end

  test "learning is bounded without dropping the explicit focus" do
    assert %{target_paths: ["lib/accepted.ex"], already_learned: learned} =
             Focus.retry_fields(entry(nil, String.duplicate("x", 300), nil), %{target_paths: ["lib/accepted.ex"]}, %{})

    assert learned == "Stay inside lib/accepted.ex and avoid unrelated reads or repo-wide rediscovery."

    assert %{target_paths: [], already_learned: compact} =
             Focus.retry_fields(entry(nil, String.duplicate("x", 300), nil), %{}, %{})

    assert String.length(compact) == 220
    assert String.ends_with?(compact, "...")
  end

  defp entry(issue, message, updates) do
    %{
      issue: issue,
      last_agent_message_text: Observation.text_facts(message),
      recent_agent_updates_text: Observation.text_facts(updates)
    }
  end
end
