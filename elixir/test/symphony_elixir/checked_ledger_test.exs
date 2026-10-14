defmodule SymphonyElixir.CheckedLedgerFaultIO do
  def callbacks(phase) do
    %{
      open: &:file.open/2,
      write: fn device, payload ->
        case phase do
          value when value in [:write, :write_and_close] -> {:error, :eio}
          :programming_bug -> raise ArgumentError, "controlled writer bug"
          _ -> :file.write(device, payload)
        end
      end,
      sync: fn device -> if phase == :sync, do: {:error, :eio}, else: :file.sync(device) end,
      close: fn device ->
        result = :file.close(device)
        send(self(), {:closed_real_descriptor, result})
        if phase in [:close, :write_and_close], do: {:error, :eio}, else: result
      end
    }
  end
end

defmodule SymphonyElixir.CheckedLedgerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias SymphonyElixir.RunLedger, as: L
  alias SymphonyElixir.RunLedger.PersistenceError
  alias SymphonyElixir.RunLedger.CheckedStorage, as: Storage

  setup do
    root =
      Path.join(System.tmp_dir!(), "checked-ledger-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.fetch_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "symphony.log"))

    on_exit(fn ->
      File.rm_rf!(root)

      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :log_file, value)
        :error -> Application.delete_env(:symphony_elixir, :log_file)
      end
    end)

    %{root: root, path: L.ledger_file_path()}
  end

  test "prepared identity is retained and persisted row equals returned entry", %{path: path} do
    {:ok, entry} =
      L.prepare_entry("stage.transition.intended", %{
        issue_id: "PB10",
        metadata: %{operation_id: "op-1"}
      })

    refute File.exists?(path)
    assert {:ok, ^entry} = L.persist_prepared(entry)
    assert File.read!(path) == Jason.encode!(entry) <> "\n"
    assert {:ok, row} = L.fetch_entry_checked(entry.event_id)
    assert row == Jason.decode!(Jason.encode!(entry))
  end

  test "real ENOTDIR is explicit and no fabricated row is returned", %{root: root} do
    blocked = Path.join(root, "file-is-not-a-directory")
    File.write!(blocked, "preserve")
    Application.put_env(:symphony_elixir, :log_file, Path.join(blocked, "symphony.log"))
    {:ok, entry} = L.prepare_entry("operator.action", %{})

    assert {:error, %PersistenceError{phase: :mkdir, event_id: id, confirmation: :not_confirmed}} =
             L.persist_prepared(entry)

    assert id == entry.event_id
    assert File.read!(blocked) == "preserve"
    refute File.exists?(Path.join(blocked, "run_ledger.jsonl"))
  end

  test "invalid log_file configuration is explicit", %{} do
    Application.put_env(:symphony_elixir, :log_file, self())

    assert {:error, %PersistenceError{phase: :configuration, confirmation: :not_confirmed}} =
             L.record_checked("operator.action", %{})
  end

  test "non-map metadata fails preparation without assigning an event identity" do
    assert {:error, %PersistenceError{phase: :prepare, event_id: nil}} =
             L.prepare_entry("event", %{metadata: []})
  end

  test "encode failure does not create a ledger", %{path: path} do
    {:ok, entry} = L.prepare_entry("event", %{metadata: %{unsupported: self()}})

    assert {:error, %PersistenceError{phase: :encode, event_id: id, confirmation: :not_confirmed}} =
             L.persist_prepared(entry)

    assert id == entry.event_id
    refute File.exists?(path)
  end

  test "real directory at ledger path blocks preflight and releases our lock", %{path: path} do
    File.mkdir!(path)

    assert {:error, %PersistenceError{phase: :preflight, confirmation: :uncertain}} =
             L.record_checked("event", %{})

    refute File.exists?(path <> ".checked.lock")
  end

  for phase <- [:write, :sync, :close] do
    test "#{phase} error cannot return success and preserves identity", %{path: path} do
      phase = unquote(phase)
      {:ok, entry} = L.prepare_entry("event", %{})

      assert {:error, %PersistenceError{phase: ^phase, event_id: id, confirmation: :uncertain}} =
               Storage.persist(entry, path, SymphonyElixir.CheckedLedgerFaultIO.callbacks(phase))

      assert id == entry.event_id
      assert_receive {:closed_real_descriptor, :ok}
      refute File.exists?(path <> ".checked.lock")
    end
  end

  test "primary write and secondary close errors both survive", %{path: path} do
    {:ok, entry} = L.prepare_entry("event", %{})

    assert {:error, %PersistenceError{phase: :write, cleanup_errors: [close: :eio]}} =
             Storage.persist(entry, path, SymphonyElixir.CheckedLedgerFaultIO.callbacks(:write_and_close))

    refute File.exists?(path <> ".checked.lock")
  end

  test "unexpected writer bug is reraised after descriptor and lock cleanup", %{path: path} do
    {:ok, entry} = L.prepare_entry("event", %{})

    assert_raise ArgumentError, "controlled writer bug", fn ->
      Storage.persist(entry, path, SymphonyElixir.CheckedLedgerFaultIO.callbacks(:programming_bug))
    end

    assert_receive {:closed_real_descriptor, :ok}
    refute File.exists?(path <> ".checked.lock")
  end

  test "observer exception is visible but does not replace a confirmed event", %{path: path} do
    observer = fn _, _ -> raise RuntimeError, "observer failure" end
    {:ok, entry} = L.prepare_entry("event", %{})

    log =
      capture_log(fn ->
        assert {:ok, ^entry} = Storage.persist(entry, path, Storage.filesystem(), observer)
      end)

    assert log =~ "Ledger entry confirmed but telemetry failed"
    assert log =~ entry.event_id
    assert File.read!(path) == Jason.encode!(entry) <> "\n"
  end

  test "redaction is preserved throughout the prepared entry and disk payload", %{path: path} do
    canary = "PB10_fake_secret_canary"

    {:ok, entry} =
      L.record_checked("event", %{summary: canary, metadata: %{token: canary, copied: canary}})

    refute Jason.encode!(entry) =~ canary
    refute File.read!(path) =~ canary
    assert entry.metadata.token == "[REDACTED]"
  end

  test "occupied or orphaned lock is not removed", %{path: path} do
    lock = path <> ".checked.lock"
    File.mkdir!(lock)
    File.write!(Path.join(lock, "owner-evidence"), "foreign-owner")

    assert {:error, %PersistenceError{phase: :lock, confirmation: :not_confirmed}} =
             L.record_checked("event", %{})

    assert File.read!(Path.join(lock, "owner-evidence")) == "foreign-owner"
    refute File.exists?(path)
  end

  test "reader finds entries beyond the recent fifty and accepts legacy rows", %{path: path} do
    entries =
      for n <- 1..61 do
        {:ok, entry} = L.record_checked("event", %{metadata: %{number: n}})
        entry
      end

    :ok = L.append("legacy.row", %{summary: "legacy"})
    assert {:ok, found} = L.fetch_entry_checked(hd(entries).event_id)
    assert found["metadata"]["number"] == 1
    assert length(String.split(File.read!(path), "\n", trim: true)) == 62
    assert {:error, :not_found} = L.fetch_entry_checked("evt-not-present")
  end

  test "reader returns not_found only after a valid empty file", %{path: path} do
    assert {:error, %PersistenceError{phase: :read, confirmation: :uncertain, reason: :enoent}} =
             L.fetch_entry_checked("evt-missing")

    File.write!(path, "")
    assert {:error, :not_found} = L.fetch_entry_checked("evt-missing")
  end

  test "reader reports an illegal file rather than absence", %{path: path} do
    File.mkdir!(path)

    assert {:error, %PersistenceError{phase: :read, confirmation: :uncertain}} =
             L.fetch_entry_checked("evt-missing")
  end

  test "reader scans corruption after the matching row", %{path: path} do
    {:ok, entry} = L.record_checked("event", %{})
    File.write!(path, "{invalid\n", [:append])

    assert {:error, %PersistenceError{phase: :decode, confirmation: :uncertain}} =
             L.fetch_entry_checked(entry.event_id)
  end

  test "reader rejects a valid JSON non-map and an incomplete final frame", %{path: path} do
    File.write!(path, "42\n")
    assert {:error, %PersistenceError{phase: :decode}} = L.fetch_entry_checked("evt")
    File.write!(path, "{}")

    assert {:error, %PersistenceError{phase: :decode, reason: :unterminated_record}} =
             L.fetch_entry_checked("evt")
  end

  test "reader detects duplicated unrelated IDs too", %{path: path} do
    {:ok, target} = L.record_checked("event", %{})
    {:ok, other} = L.record_checked("event", %{})
    File.write!(path, Jason.encode!(other) <> "\n", [:append])

    assert {:error, %PersistenceError{phase: :duplicate, confirmation: :uncertain}} =
             L.fetch_entry_checked(target.event_id)
  end

  test "reader does not remove an occupied lock", %{path: path} do
    File.write!(path, "")
    File.mkdir!(path <> ".checked.lock")

    assert {:error, %PersistenceError{phase: :lock, confirmation: :uncertain}} =
             L.fetch_entry_checked("evt")

    assert File.dir?(path <> ".checked.lock")
  end

  test "JSON snapshot roundtrip preserves ID, payload and returned string-key map", %{path: path} do
    {:ok, original} =
      L.prepare_entry("stage.transition.confirmed", %{metadata: %{operation_id: "op-json"}})

    decoded = original |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^decoded} = L.persist_prepared(decoded)
    assert File.read!(path) == Jason.encode!(decoded) <> "\n"
    assert {:ok, ^decoded} = L.fetch_entry_checked(original.event_id)
  end

  test "conflicting atom and string schemas are rejected", %{path: path} do
    {:ok, original} = L.prepare_entry("event", %{})
    ambiguous = Map.put(original, "event_id", "other-id")
    assert {:error, %PersistenceError{phase: :prepare}} = L.persist_prepared(ambiguous)
    refute File.exists?(path)
  end

  test "checked path resolves configuration to absolute path", %{path: path} do
    assert {:ok, ^path} = L.ledger_file_path_checked()
    Application.put_env(:symphony_elixir, :log_file, "relative-log/symphony.log")
    assert {:ok, resolved} = L.ledger_file_path_checked()
    assert resolved == Path.expand("relative-log/run_ledger.jsonl")
    Application.put_env(:symphony_elixir, :log_file, "")

    assert {:error, %PersistenceError{phase: :configuration, event_id: nil}} =
             L.ledger_file_path_checked()
  end

  test "concurrent checked writers in one VM all confirm whole unique rows", %{path: path} do
    parent = self()

    tasks =
      for n <- 1..20 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> L.record_checked("concurrent.event", %{metadata: %{number: n}})
          end
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _}, 2_000
    end

    Enum.each(tasks, fn task -> send(task.pid, :go) end)

    entries =
      Enum.map(tasks, fn task ->
        assert {:ok, entry} = Task.await(task, 15_000)
        entry
      end)

    # The ledger path is VM-global, so unrelated writers may land here; duplicates of ours still fail.
    rows = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.filter(&(&1["event_type"] == "concurrent.event"))
    assert length(rows) == 20

    assert MapSet.new(Enum.map(rows, & &1["event_id"])) ==
             MapSet.new(Enum.map(entries, & &1.event_id))

    assert MapSet.new(Enum.map(rows, & &1["metadata"]["number"])) == MapSet.new(1..20)
    refute File.exists?(path <> ".checked.lock")
  end

  for {label, bytes} <- [
        {"truncated tail", "{\"event_id\":\"partial"},
        {"valid JSON without LF", "{}"},
        {"corrupt complete line", "{broken\n"}
      ] do
    test "preflight preserves #{label} without false confirmation", %{path: path} do
      bytes = unquote(bytes)
      File.write!(path, bytes)
      {:ok, prepared} = L.prepare_entry("stage.transition.confirmed", %{})
      assert {:error, %PersistenceError{phase: :preflight, event_id: id, confirmation: :uncertain}} = L.persist_prepared(prepared)
      assert id == prepared.event_id
      assert File.read!(path) == bytes
      refute File.exists?(path <> ".checked.lock")
    end
  end

  test "preflight never appends the same prepared identity twice", %{path: path} do
    {:ok, prepared} = L.prepare_entry("event", %{})
    assert {:ok, ^prepared} = L.persist_prepared(prepared)
    before = File.read!(path)
    assert {:error, %PersistenceError{phase: :preflight, event_id: id, reason: :event_id_already_present}} = L.persist_prepared(prepared)
    assert id == prepared.event_id
    assert File.read!(path) == before
  end

  test "preflight blocks existing duplicate IDs even unrelated to the new entry", %{path: path} do
    {:ok, old} = L.record_checked("old.event", %{})
    File.write!(path, Jason.encode!(old) <> "\n", [:append])
    before = File.read!(path)
    assert {:error, %PersistenceError{phase: :preflight, reason: {:duplicate_event_id, 2}}} = L.record_checked("new.event", %{})
    assert File.read!(path) == before
  end

  test "actual open EACCES cannot confirm a readable but nonwritable ledger", %{path: path} do
    File.write!(path, "")
    File.chmod!(path, 0o400)
    on_exit(fn -> File.chmod!(path, 0o600) end)
    assert {:error, %PersistenceError{phase: :open, confirmation: :not_confirmed, reason: :eacces}} = L.record_checked("event", %{})
    assert File.read!(path) == ""
    refute File.exists?(path <> ".checked.lock")
  end
end
