defmodule SymphonyElixir.EventInboxCheckedTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{EventInbox, GitHubEvent, GitHubEventInbox, TrackerEvent, TrackerEventInbox}
  alias SymphonyElixir.EventInbox.Error

  @limits %{max_rows: 100, max_bytes: 4 * 1024 * 1024}

  setup do
    root = Path.join(System.tmp_dir!(), "inbox-checked-#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "symphony.log"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :log_file, value)
        :error -> Application.delete_env(:symphony_elixir, :log_file)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  for inbox <- [TrackerEventInbox, GitHubEventInbox] do
    @inbox inbox
    describe "#{inspect(inbox)}" do
      test "initializes on enqueue, dedupes and confirms a physical cursor" do
        inbox = @inbox
        location = inbox.location()
        assert {:ok, %{status: :uninitialized, rows: []}} = inbox.capture(location, @limits)
        refute File.exists?(location.events_path)
        refute File.exists?(location.state_path)
        assert {:ok, %{accepted: 1, duplicates: 0}} = inbox.enqueue([event(inbox, "one")])
        assert {:ok, %{accepted: 0, duplicates: 1}} = inbox.enqueue([event(inbox, "one")])
        assert {:ok, %{rows: [%{cursor: cursor, record: {:ok, record}}]}} = inbox.capture(location, @limits)
        assert record["id"] == "one"
        assert {:ok, :advanced} = inbox.ack(cursor)
        assert {:ok, :already_acked} = inbox.ack(cursor)
        assert [] == inbox.pending_events()
        assert %{depth: 0, status: :ready, complete: true} = inbox.stats()
      end

      test "invalid complete rows and UTF-8 preserve physical prefix boundaries" do
        inbox = @inbox
        location = inbox.location()
        assert :ok = inbox.initialize(location)
        prefix = "bad\n\n[]\n"
        record = Jason.encode!(%{"event" => %{"title" => "á漢字"}}) <> "\n"
        File.write!(location.events_path, prefix <> record)
        assert {:ok, %{rows: [bad, blank, array, valid]}} = inbox.capture(location, @limits)
        assert bad.record == {:invalid, :invalid_json}
        assert blank.record == {:invalid, :invalid_json}
        assert array.record == {:invalid, :non_object}
        assert valid.end_offset == byte_size(prefix <> record)
        assert {:ok, :advanced} = inbox.ack(array.cursor)
        assert [%{"event" => %{"title" => "á漢字"}}] = inbox.pending_events()
        assert {:error, %Error{reason_code: :offset_changed}} = inbox.ack(valid.cursor)
        assert {:ok, %{rows: [remaining]}} = inbox.capture(location, @limits)
        assert {:ok, :advanced} = inbox.ack(remaining.cursor)
        assert [] == inbox.pending_events()
      end

      test "partial JSON is retained and blocks even duplicate enqueue and reset" do
        inbox = @inbox
        location = inbox.location()
        assert {:ok, _} = inbox.enqueue([event(inbox, "one")])
        partial = "{\"event\":{}}"
        File.write!(location.events_path, partial, [:append])
        before = File.read!(location.events_path)
        state = File.read!(location.state_path)
        assert {:ok, %{rows: [_], tail: :partial}} = inbox.capture(location, @limits)
        assert {:error, {_, %{reason_code: :partial_tail}}} = inbox.enqueue([event(inbox, "one")])
        assert {:error, %Error{reason_code: :partial_tail}} = inbox.reset(location)
        assert File.read!(location.events_path) == before
        assert File.read!(location.state_path) == state
        # Explicit fixture repair, never a product repair path.
        File.write!(location.events_path, "\n", [:append])
        assert {:ok, %{rows: [_, _], tail: :none}} = inbox.capture(location, @limits)
      end

      test "row and byte bounds preserve an unconsumed head" do
        inbox = @inbox
        location = inbox.location()
        assert :ok = inbox.initialize(location)
        File.write!(location.events_path, "{}\n{}\n")
        assert {:ok, %{rows: [_], limit_reached: true, tail: :not_inspected}} = inbox.capture(location, %{max_rows: 1, max_bytes: 100})
        assert {:ok, %{rows: [_], limit_reached: true}} = inbox.capture(location, %{max_rows: 100, max_bytes: 3})
        assert {:error, %Error{reason_code: :row_too_large}} = inbox.capture(location, %{max_rows: 100, max_bytes: 2})
        assert read_state(location)["acked_offset"] == 0
        assert {:ok, %{rows: [_, _], limit_reached: false}} = inbox.capture(location, @limits)
      end

      test "oversize records are rejected before initialization or append" do
        inbox = @inbox
        location = inbox.location()
        huge = %{event(inbox, "large") | raw: %{"secret" => String.duplicate("x", 4 * 1024 * 1024)}}
        assert {:error, {_, error}} = inbox.enqueue([huge])
        assert error.reason_code == :row_too_large
        refute inspect(error) =~ "secret"
        refute File.exists?(location.events_path)
        refute File.exists?(location.state_path)
      end

      test "append between capture and ack retains the writer's dedupe state" do
        inbox = @inbox
        location = inbox.location()
        assert {:ok, _} = inbox.enqueue([event(inbox, "one")])
        assert {:ok, %{rows: [one]}} = inbox.capture(location, @limits)
        assert {:ok, _} = inbox.enqueue([event(inbox, "two")])
        assert {:ok, :advanced} = inbox.ack(one.cursor)
        assert {:ok, %{accepted: 0, duplicates: 1}} = inbox.enqueue([event(inbox, "two")])
        assert {:ok, %{accepted: 1}} = inbox.enqueue([event(inbox, "three")])
        assert Enum.map(inbox.pending_events(), & &1["id"]) == ["two", "three"]
        assert read_state(location)["acked_offset"] == one.end_offset
      end

      test "reset retains history and makes an old cursor unusable with repeated IDs" do
        inbox = @inbox
        location = inbox.location()
        assert {:ok, _} = inbox.enqueue([event(inbox, "same")])
        assert {:ok, %{rows: [old]}} = inbox.capture(location, @limits)
        bytes = File.read!(location.events_path)
        assert :ok = inbox.reset(location)
        assert File.read!(location.events_path) == bytes
        assert [] == inbox.pending_events()
        assert {:ok, %{accepted: 1}} = inbox.enqueue([event(inbox, "same")])
        assert {:error, %Error{reason_code: :generation_changed}} = inbox.ack(old.cursor)
        assert [%{"id" => "same"}] = inbox.pending_events()
      end

      test "captured location cannot acknowledge a newly configured root", %{root: root} do
        inbox = @inbox
        old_location = inbox.location()
        assert {:ok, _} = inbox.enqueue([event(inbox, "same")])
        assert {:ok, %{rows: [old]}} = inbox.capture(old_location, @limits)
        Application.put_env(:symphony_elixir, :log_file, Path.join(root, "other/symphony.log"))
        assert {:ok, _} = inbox.enqueue([event(inbox, "same")])
        assert {:ok, :advanced} = inbox.ack(old.cursor)
        assert [%{"id" => "same"}] = inbox.pending_events()
        assert {:ok, %{rows: []}} = inbox.capture(old_location, @limits)
      end

      test "explicit migration preserves physical legacy count and dedupe" do
        inbox = @inbox
        location = inbox.location()
        File.mkdir_p!(Path.dirname(location.state_path))
        bytes = "broken\n{}\n{\"partial\":"
        File.write!(location.events_path, bytes)
        File.write!(location.state_path, Jason.encode!(%{acked_count: 1, seen_dedupe_keys: ["remembered"]}))
        original = File.read!(location.state_path)
        assert {:error, %Error{reason_code: :migration_required}} = inbox.capture(location, @limits)
        assert File.read!(location.state_path) == original
        assert_raise Error, fn -> inbox.pending_events() end
        assert :ok = inbox.migrate_legacy(location)
        state = read_state(location)
        assert state["acked_offset"] == byte_size("broken\n")
        assert state["seen_dedupe_keys"] == ["remembered"]
        assert File.read!(location.events_path) == bytes
        assert {:ok, %{rows: [_], tail: :partial}} = inbox.capture(location, @limits)
        assert :ok = inbox.migrate_legacy(location)
        assert read_state(location) == state
      end

      test "legacy count beyond complete EOF is rejected without rewriting" do
        inbox = @inbox
        location = inbox.location()
        File.mkdir_p!(Path.dirname(location.state_path))
        File.write!(location.events_path, "{}\n{}")
        File.write!(location.state_path, Jason.encode!(%{acked_count: 2, seen_dedupe_keys: []}))
        original = File.read!(location.state_path)
        assert {:error, %Error{reason_code: :count_beyond_eof}} = inbox.migrate_legacy(location)
        assert File.read!(location.state_path) == original
      end

      test "corrupt state and missing pairs remain visible instead of resetting" do
        inbox = @inbox
        location = inbox.location()
        assert :ok = inbox.initialize(location)

        for payload <- ["not-json", "{}", "[]", Jason.encode!(%{schema_version: 3}), Jason.encode!(%{acked_count: 0})] do
          File.write!(location.state_path, payload)
          assert {:error, %Error{reason_code: :invalid_schema}} = inbox.capture(location, @limits)
          assert {:error, _} = inbox.reset(location)
          assert %{depth: nil, status: :error} = inbox.stats()
          assert File.read!(location.state_path) == payload
        end

        File.rm!(location.state_path)
        assert {:error, %Error{reason_code: :missing_state}} = inbox.initialize(location)
        File.write!(location.state_path, "{}")
        File.rm!(location.events_path)
        assert {:error, %Error{reason_code: :missing_events}} = inbox.capture(location, @limits)
      end

      test "cursor beyond EOF, within a row, and altered prefix cannot be confirmed" do
        inbox = @inbox
        location = inbox.location()
        assert :ok = inbox.initialize(location)
        File.write!(location.events_path, "{\"a\":1}\n")
        state = read_state(location)

        for {offset, reason} <- [{50, :offset_beyond_eof}, {2, :offset_not_boundary}] do
          File.write!(location.state_path, Jason.encode!(%{state | "acked_offset" => offset}))
          assert {:error, %Error{reason_code: ^reason}} = inbox.capture(location, @limits)
        end

        File.write!(location.state_path, Jason.encode!(state))
        assert {:ok, %{rows: [row]}} = inbox.capture(location, @limits)
        File.write!(location.events_path, "{\"a\":2}\n")
        assert {:error, %Error{reason_code: :prefix_changed}} = inbox.ack(row.cursor)
        assert read_state(location)["acked_offset"] == 0
      end

      test "an occupied filesystem lock blocks all operations without deleting it" do
        inbox = @inbox
        location = inbox.location()
        assert :ok = inbox.initialize(location)
        File.mkdir!(location.lock_path)
        on_exit(fn -> File.rmdir(location.lock_path) end)
        assert {:error, %Error{phase: :lock}} = inbox.capture(location, @limits)
        assert {:error, %Error{phase: :lock}} = inbox.reset(location)
        assert {:error, %Error{phase: :lock}} = inbox.migrate_legacy(location)
        assert {:error, {_, %{phase: :lock}}} = inbox.enqueue([event(inbox, "one")])
        assert File.dir?(location.lock_path)
        assert read_state(location)["acked_offset"] == 0
      end
    end
  end

  test "a partial append failure preserves bytes and reports uncertainty" do
    location = TrackerEventInbox.location()
    assert :ok = TrackerEventInbox.initialize(location)
    before = File.read!(location.state_path)
    real = EventInbox.filesystem()

    io = %{
      real
      | write: fn device, bytes ->
          bytes = IO.iodata_to_binary(bytes)
          assert :ok = real.write.(device, binary_part(bytes, 0, 5))
          {:error, :enospc}
        end
    }

    assert {:error, %Error{phase: :append, confirmation: :uncertain}} = enqueue_with_io(location, "partial", io)
    assert byte_size(File.read!(location.events_path)) == 5
    assert File.read!(location.state_path) == before
    assert {:error, {_, %{reason_code: :partial_tail}}} = TrackerEventInbox.enqueue([event(TrackerEventInbox, "next")])
    refute File.exists?(location.lock_path)
  end

  test "a state publication failure after append exposes possible redelivery" do
    location = TrackerEventInbox.location()
    assert :ok = TrackerEventInbox.initialize(location)
    before = File.read!(location.state_path)
    io = %{EventInbox.filesystem() | rename: fn _source, _target -> {:error, :eacces} end}
    assert {:error, %Error{phase: :state_publish, confirmation: :uncertain}} = enqueue_with_io(location, "one", io)
    assert File.read!(location.state_path) == before
    assert [%{"id" => "one"}] = TrackerEventInbox.pending_events()
    assert {:ok, %{accepted: 1}} = TrackerEventInbox.enqueue([event(TrackerEventInbox, "one")])
    assert Enum.map(TrackerEventInbox.pending_events(), & &1["id"]) == ["one", "one"]
    assert Path.wildcard(location.state_path <> ".tmp-*") == []
  end

  test "rename applied before its error can be confirmed by retrying the exact cursor" do
    location = TrackerEventInbox.location()
    assert {:ok, _} = TrackerEventInbox.enqueue([event(TrackerEventInbox, "one")])
    assert {:ok, %{rows: [row]}} = TrackerEventInbox.capture(location, @limits)
    real = EventInbox.filesystem()

    io = %{
      real
      | rename: fn source, target ->
          assert :ok = real.rename.(source, target)
          {:error, :eio}
        end
    }

    assert {:error, %Error{phase: :state_publish, confirmation: :uncertain}} = EventInbox.ack(row.cursor, io)
    assert read_state(location)["acked_offset"] == row.end_offset
    assert {:ok, :already_acked} = TrackerEventInbox.ack(row.cursor)
    assert [] == TrackerEventInbox.pending_events()
  end

  test "sync and close failures do not replace the original I/O failure" do
    location = TrackerEventInbox.location()
    assert {:ok, _} = TrackerEventInbox.enqueue([event(TrackerEventInbox, "one")])
    assert {:ok, %{rows: [row]}} = TrackerEventInbox.capture(location, @limits)
    state = File.read!(location.state_path)
    real = EventInbox.filesystem()

    io = %{
      real
      | sync: fn device ->
          assert :ok = real.sync.(device)
          {:error, :eio}
        end,
        close: fn device ->
          assert :ok = real.close.(device)
          {:error, :ebadf}
        end
    }

    assert {:error, %Error{phase: :sync, reason_code: :eio, cleanup_errors: [close: :ebadf]} = error} = EventInbox.ack(row.cursor, io)
    assert {:ok, encoded} = Jason.encode(EventInbox.error_summary(error))

    assert Jason.decode!(encoded) == %{
             "phase" => "sync",
             "reason_code" => "eio",
             "confirmation" => "uncertain",
             "cleanup_errors" => [%{"phase" => "close", "reason_code" => "ebadf"}]
           }

    assert File.read!(location.state_path) == state
    assert Path.wildcard(location.state_path <> ".tmp-*") == []
    refute File.exists?(location.lock_path)
  end

  for operation <- [:write, :sync] do
    test "#{operation} exception closes the file and cleans temporary and lock" do
      location = TrackerEventInbox.location()
      assert {:ok, _} = TrackerEventInbox.enqueue([event(TrackerEventInbox, "one")])
      assert {:ok, %{rows: [row]}} = TrackerEventInbox.capture(location, @limits)
      state = File.read!(location.state_path)
      owner = self()
      real = EventInbox.filesystem()

      failure =
        case unquote(operation) do
          :write ->
            fn device, bytes ->
              assert :ok = real.write.(device, bytes)
              throw(:write_original)
            end

          :sync ->
            fn device ->
              assert :ok = real.sync.(device)
              throw(:sync_original)
            end
        end

      io = Map.put(real, unquote(operation), failure)

      io = %{
        io
        | close: fn device ->
            assert :ok = real.close.(device)
            send(owner, :closed)
            :ok
          end
      }

      assert catch_throw(EventInbox.ack(row.cursor, io)) == unquote(if operation == :write, do: :write_original, else: :sync_original)
      assert_receive :closed
      assert File.read!(location.state_path) == state
      assert Path.wildcard(location.state_path <> ".tmp-*") == []
      refute File.exists?(location.lock_path)
    end
  end

  test "rename exception preserves its cause and cleans the owned temporary" do
    location = TrackerEventInbox.location()
    assert {:ok, _} = TrackerEventInbox.enqueue([event(TrackerEventInbox, "one")])
    assert {:ok, %{rows: [row]}} = TrackerEventInbox.capture(location, @limits)
    state = File.read!(location.state_path)
    io = %{EventInbox.filesystem() | rename: fn _source, _target -> raise ArgumentError, "fixture rename failure" end}
    assert_raise ArgumentError, "fixture rename failure", fn -> EventInbox.ack(row.cursor, io) end
    assert File.read!(location.state_path) == state
    assert Path.wildcard(location.state_path <> ".tmp-*") == []
    refute File.exists?(location.lock_path)
  end

  @tag :inbox_cross_vm
  test "independent VMs honor the lock and preserve append/ack ordering", %{root: root} do
    location = TrackerEventInbox.location()
    assert {:ok, _} = TrackerEventInbox.enqueue([event(TrackerEventInbox, "A")])
    assert {:ok, %{rows: [a]}} = TrackerEventInbox.capture(location, @limits)
    before = process_observation(location, :before_lock)
    File.mkdir!(location.lock_path)

    try do
      assert {"checked\n", 0} = child_storage(root, "locked")
      assert process_observation(location, :after_locked_child) == before
      assert File.dir?(location.lock_path)
    after
      File.rmdir!(location.lock_path)
    end

    assert {"checked\n", 0} = child_storage(root, "B")
    after_b = process_observation(location, :after_child_b)
    assert after_b.offset == 0
    assert after_b.bytes > before.bytes
    assert length(after_b.dedupe) == 2
    assert {:ok, :advanced} = TrackerEventInbox.ack(a.cursor)
    after_ack = process_observation(location, :after_parent_ack)
    assert after_ack.offset == a.end_offset
    assert after_ack.bytes == after_b.bytes
    assert after_ack.dedupe == after_b.dedupe
    assert {"checked\n", 0} = child_storage(root, "C")
    after_c = process_observation(location, :after_child_c)
    assert after_c.bytes > after_ack.bytes
    assert after_c.offset == a.end_offset
    assert length(after_c.dedupe) == 3
    assert read_state(location)["acked_offset"] == a.end_offset
    assert Enum.map(TrackerEventInbox.pending_events(), & &1["id"]) == ["B", "C"]
    assert {:ok, %{accepted: 0, duplicates: 2}} = TrackerEventInbox.enqueue([event(TrackerEventInbox, "B"), event(TrackerEventInbox, "C")])
  end

  defp process_observation(location, phase) do
    state = read_state(location)
    observed = %{bytes: File.stat!(location.events_path).size, offset: state["acked_offset"], dedupe: state["seen_dedupe_keys"]}
    IO.puts("Inbox cross-VM #{phase}: #{inspect(observed)}")
    observed
  end

  defp child_storage(root, phase) do
    executable = System.find_executable("elixir") || flunk("Elixir executable is required for the approved isolated child VM")
    build_path = Mix.Project.build_path() |> Path.expand()
    application_ebin = Mix.Project.compile_path() |> Path.expand()
    assert application_ebin == Path.join(build_path, "lib/symphony_elixir/ebin")
    jason_ebin = Path.join(build_path, "lib/jason/ebin")
    application_beam = Path.join(application_ebin, "Elixir.SymphonyElixir.EventInbox.beam")
    jason_beam = Path.join(jason_ebin, "Elixir.Jason.beam")
    assert {:ok, {EventInbox, [compile_info: compile_info]}} = :beam_lib.chunks(String.to_charlist(application_beam), [:compile_info])
    compiled_source = compile_info |> Keyword.fetch!(:source) |> to_string() |> Path.expand()
    assert compiled_source == Path.expand("lib/symphony_elixir/event_inbox.ex")
    assert {:ok, {Jason, _chunks}} = :beam_lib.chunks(String.to_charlist(jason_beam), [:compile_info])
    application_hash = artifact_hash(application_beam)
    jason_hash = artifact_hash(jason_beam)
    IO.puts("Inbox child artifacts: #{inspect(%{source: artifact_hash(compiled_source), application: application_hash, jason: jason_hash})}")

    script = ~S'''
    spawn(fn -> Process.sleep(10_000); System.halt(90) end)
    [log, phase, application_hash, jason_hash] = System.argv()
    for {module, expected} <- [{SymphonyElixir.EventInbox, application_hash}, {Jason, jason_hash}] do
      {:module, ^module} = Code.ensure_loaded(module)
      path = module |> :code.which() |> List.to_string()
      bytes = File.read!(path)
      actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      if actual != expected, do: raise("Child storage artifact differs from the captured build")
      {:ok, {^module, artifact_md5}} = :beam_lib.md5(bytes)
      if :erlang.get_module_info(module, :md5) != artifact_md5, do: raise("Child loaded code differs from its storage artifact")
    end
    Application.put_env(:symphony_elixir, :log_file, log)
    alias SymphonyElixir.{TrackerEvent, TrackerEventInbox}
    location = TrackerEventInbox.location()
    event = %TrackerEvent{provider: "linear", event_id: phase, entity_type: "Issue", entity_id: phase, action: "update", raw: %{}}
    if phase == "locked" do
      {:error, %{phase: :lock}} = TrackerEventInbox.capture(location, %{max_rows: 100, max_bytes: 4 * 1024 * 1024})
      {:error, {_, %{phase: :lock}}} = TrackerEventInbox.enqueue([event])
      {:error, %{phase: :lock}} = TrackerEventInbox.reset(location)
    else
      {:ok, %{accepted: 1}} = TrackerEventInbox.enqueue([event])
    end
    IO.puts("checked")
    '''

    System.cmd(executable, ["--erl", "+S 1:1 +A 1", "-pa", application_ebin, "-pa", jason_ebin, "-e", script, "--", Path.join(root, "symphony.log"), phase, application_hash, jason_hash],
      stderr_to_stdout: true
    )
  end

  defp artifact_hash(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp enqueue_with_io(location, id, io) do
    EventInbox.enqueue([event(TrackerEventInbox, id)], location, %{event_module: TrackerEvent, event_id_prefix: "trk_"}, fn event -> %{entity_id: event.entity_id} end, io)
  end

  defp event(TrackerEventInbox, id), do: %TrackerEvent{provider: "linear", event_id: id, entity_type: "Issue", entity_id: id, action: "update", raw: %{}}
  defp event(GitHubEventInbox, id), do: %GitHubEvent{provider: "github", event_id: id, event_name: "ping", action: "ping", raw: %{}}
  defp read_state(location), do: location.state_path |> File.read!() |> Jason.decode!()
end
