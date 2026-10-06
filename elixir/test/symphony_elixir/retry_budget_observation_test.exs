defmodule SymphonyElixir.RetryBudgetObservationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryBudget.Observation

  test "blank preferred text prevents fallback from discovering an unrelated path" do
    facts = Observation.text_facts(%{text: "", other: "lib/unrelated.ex"})
    assert facts.fragments == [""]
    refute "lib/unrelated.ex" in facts.fragments
  end

  test "atom and string preferred keys retain their source precedence" do
    facts = Observation.text_facts(%{"text" => "lib/second.ex", text: "lib/first.ex", other: "lib/ignored.ex"})
    assert facts.fragments == ["lib/first.ex", "lib/second.ex"]
  end

  test "structured callbacks and execution capabilities are not retained in text facts" do
    message = %{
      message: %{text: "lib/focused.ex"},
      payload: %{lease_token: make_ref(), owner: self(), callback: fn -> :must_not_run end}
    }

    assert %{fragments: ["lib/focused.ex"], summary: {:structured, ["lib/focused.ex"]}} =
             Observation.text_facts(message)

    assert %{fragments: [], summary: :unsupported} = Observation.text_facts(fn -> :must_not_run end)
  end
end
