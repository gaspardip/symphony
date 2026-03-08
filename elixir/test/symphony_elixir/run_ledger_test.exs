defmodule SymphonyElixir.RunLedgerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunLedger

  setup do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    log_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-ledger-test-#{System.unique_integer([:positive])}"
      )

    log_file = Path.join(log_root, "symphony.log")
    Application.put_env(:symphony_elixir, :log_file, log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    :ok
  end

  test "record writes a typed ledger envelope and recent_entries keeps legacy compatibility" do
    entry =
      RunLedger.record("operator.action", %{
        issue_id: "issue-typed",
        issue_identifier: "MT-TYPED",
        stage: "await_checks",
        actor_type: "operator",
        actor_id: "dashboard",
        policy_class: "review_required",
        failure_class: "policy",
        rule_id: "policy.review_required",
        summary: "Placed issue in Human Review.",
        details: "Operator requested manual review.",
        target_state: "Human Review",
        metadata: %{action: "hold_for_human_review"},
        extra_note: "persisted"
      })

    assert entry.schema_version == 1
    assert entry.event_type == "operator.action"
    assert is_binary(entry.event_id)
    assert entry.issue_identifier == "MT-TYPED"
    assert entry.policy_class == "review_required"
    assert entry.metadata == %{action: "hold_for_human_review", extra_note: "persisted"}

    :ok =
      RunLedger.append("legacy.event", %{
        issue_identifier: "MT-LEGACY",
        summary: "legacy row"
      })

    entries = RunLedger.recent_entries(10)

    assert Enum.any?(entries, &(&1["event_type"] == "operator.action"))
    assert Enum.any?(entries, &(&1["event"] == "legacy.event"))
  end
end
