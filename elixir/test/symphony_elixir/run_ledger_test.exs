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

    %{log_root: log_root, ledger_path: RunLedger.ledger_file_path()}
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

  test "record returns exactly the checked durable entry and emits only once", %{ledger_path: path} do
    observe_ledger_events!()
    entry = RunLedger.record("operator.action", %{issue_id: "bridge-success", metadata: %{action: "inspect"}})

    assert File.read!(path) == Jason.encode!(entry) <> "\n"
    assert {:ok, row} = RunLedger.fetch_entry_checked(entry.event_id)
    assert row == Jason.decode!(Jason.encode!(entry))
    assert_receive {:record_ledger_event, %{event_id: id, event_type: "operator.action"}}
    assert id == entry.event_id
    refute_received {:record_ledger_event, _}
    refute File.exists?(path <> ".checked.lock")
  end

  test "record raises the original ENOTDIR error without returning a fabricated event", %{log_root: root} do
    observe_ledger_events!()
    blocked = Path.join(root, "not-a-directory")
    File.mkdir_p!(root)
    File.write!(blocked, "preserve-original-bytes")
    Application.put_env(:symphony_elixir, :log_file, Path.join(blocked, "runtime.log"))

    error =
      assert_raise RunLedger.PersistenceError, "Run ledger persistence failed.", fn ->
        RunLedger.record("operator.action", %{summary: "controlled ENOTDIR"})
      end

    assert error.phase == :mkdir
    assert error.confirmation == :not_confirmed
    assert error.reason == :enotdir
    assert is_binary(error.event_id)
    assert error.event_id != ""
    assert error.cleanup_errors == []
    assert File.read!(blocked) == "preserve-original-bytes"
    refute File.exists?(Path.join(blocked, "run_ledger.jsonl"))
    refute_received {:record_ledger_event, _}
  end

  test "record invalid configuration remains an error with its prepared identity", %{ledger_path: path} do
    observe_ledger_events!()
    Application.put_env(:symphony_elixir, :log_file, self())

    error = assert_raise RunLedger.PersistenceError, fn -> RunLedger.record("operator.action", %{}) end

    assert error.phase == :configuration
    assert error.reason == :invalid_log_file
    assert error.confirmation == :not_confirmed
    assert is_binary(error.event_id)
    refute File.exists?(path)
    refute_received {:record_ledger_event, _}
  end

  test "record keeps encode failure typed and its exception message contains no input", %{ledger_path: path} do
    observe_ledger_events!()
    sentinel = "PB10-private-payload-not-for-exception-message"

    error =
      assert_raise RunLedger.PersistenceError, fn ->
        RunLedger.record("operator.action", %{metadata: %{unsupported: self(), payload: sentinel}})
      end

    assert error.phase == :encode
    assert error.reason == Protocol.UndefinedError
    assert error.confirmation == :not_confirmed
    assert is_binary(error.event_id)
    assert Exception.message(error) == "Run ledger persistence failed."
    refute String.contains?(Exception.message(error), sentinel)
    refute File.exists?(path)
    refute_received {:record_ledger_event, _}
  end

  test "record refuses a truncated ledger without appending or retrying", %{log_root: root, ledger_path: path} do
    observe_ledger_events!()
    File.mkdir_p!(root)
    before = "{\"event_id\":\"unfinished"
    File.write!(path, before)

    error = assert_raise RunLedger.PersistenceError, fn -> RunLedger.record("operator.action", %{}) end

    assert error.phase == :preflight
    assert error.confirmation == :uncertain
    assert error.reason == :unterminated_record
    assert is_binary(error.event_id)
    assert File.read!(path) == before
    refute File.exists?(path <> ".checked.lock")
    refute_received {:record_ledger_event, _}
  end

  test "record leaves another writer's occupied physical lock untouched", %{log_root: root, ledger_path: path} do
    observe_ledger_events!()
    File.mkdir_p!(root)
    lock = path <> ".checked.lock"
    File.mkdir!(lock)
    owner = Path.join(lock, "owner-evidence")
    File.write!(owner, "preserve-other-owner")

    error = assert_raise RunLedger.PersistenceError, fn -> RunLedger.record("operator.action", %{}) end

    assert error.phase == :lock
    assert error.confirmation == :not_confirmed
    assert error.reason == :eexist
    assert is_binary(error.event_id)
    assert File.read!(owner) == "preserve-other-owner"
    refute File.exists?(path)
    refute_received {:record_ledger_event, _}
  end

  test "record validates the full existing ledger beyond the recent-entry window", %{ledger_path: path} do
    entries =
      for n <- 1..61 do
        assert {:ok, entry} = RunLedger.record_checked("existing.event", %{metadata: %{number: n}})
        entry
      end

    before = File.read!(path)
    entry = RunLedger.record("operator.action", %{metadata: %{action: "bridge"}})

    assert File.read!(path) == before <> Jason.encode!(entry) <> "\n"
    assert {:ok, first} = RunLedger.fetch_entry_checked(hd(entries).event_id)
    assert first["metadata"]["number"] == 1
    assert {:ok, last} = RunLedger.fetch_entry_checked(entry.event_id)
    assert last == Jason.decode!(Jason.encode!(entry))
    assert length(String.split(File.read!(path), "\n", trim: true)) == 62
  end

  defp observe_ledger_events! do
    observer = self()
    id = "record-bridge-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:symphony, :ledger, :event],
        fn _event, _measurements, metadata, _config ->
          send(observer, {:record_ledger_event, metadata})
        end,
        nil
      )

    on_exit(fn -> :ok = :telemetry.detach(id) end)
    :ok
  end
end
