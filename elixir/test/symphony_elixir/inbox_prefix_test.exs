defmodule SymphonyElixir.InboxPrefixTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.EventInbox.{Cursor, Location}
  alias SymphonyElixir.InboxPrefix

  test "several applied rows accumulate a captured cursor before one confirmation" do
    captured = capture([row(10, "a"), row(20, "b"), row(30, "c")])
    initial = InboxPrefix.new(captured, :consume_before_ack)
    first = InboxPrefix.applied(initial)
    second = InboxPrefix.applied(first.prefix)

    assert first.cursor == hd(captured.rows).cursor
    assert second.cursor == Enum.at(captured.rows, 1).cursor
    assert second.prefix.rows == [List.last(captured.rows)]
    assert second.prefix.applied_cursor == second.cursor
    assert second.prefix.start_offset == 0
    assert second.prefix.end_offset == 30

    %{prefix: waiting, continuation: {:recapture, boundary}} = InboxPrefix.acknowledged(second.prefix, second.cursor)
    assert waiting.applied_cursor == nil
    assert waiting.rows == second.prefix.rows
    recaptured = capture([row(30, "c", 20, "new-prefix-digest"), row(40, "later", 20)], 20)
    assert {:ok, resumed} = InboxPrefix.rebind(waiting, recaptured, boundary)
    assert resumed.rows == [hd(recaptured.rows)]
    assert resumed.start_offset == 20
    assert resumed.end_offset == 30
  end

  test "after-confirmation consumption retains the completed physical row until successful recapture" do
    captured = capture([row(10, "a"), row(20, "b")])
    prefix = InboxPrefix.new(captured, :consume_after_ack)
    applied = InboxPrefix.applied(prefix)
    assert applied.prefix.rows == captured.rows
    assert applied.prefix.start_offset == 0
    assert applied.prefix.applied_cursor == applied.cursor

    %{prefix: waiting, continuation: {:recapture, boundary}} = InboxPrefix.acknowledged(applied.prefix, applied.cursor)
    assert waiting == applied.prefix
    assert boundary.rows == [List.last(captured.rows)]
    recaptured = capture([row(20, "b", 10, "new-digest"), row(30, "append", 10)], 10)
    assert {:ok, resumed} = InboxPrefix.rebind(waiting, recaptured, boundary)
    assert resumed.rows == [hd(recaptured.rows)]
    assert resumed.applied_cursor == nil
    assert resumed.start_offset == 10
    assert resumed.end_offset == 20
    assert waiting.rows == captured.rows
  end

  test "different physical bytes with the same decoded record cannot renew an unconfirmed cursor" do
    original = row(10, "same-record")
    changed = put_in(original.cursor.digest, "different-bytes")
    prefix = InboxPrefix.new(capture([original]), :consume_before_ack)
    assert {:error, :prefix_changed} = InboxPrefix.rebind(prefix, capture([changed]), :unconfirmed)
    assert {:error, :prefix_changed} = InboxPrefix.check(prefix, capture([changed]), {:row, original})
  end

  test "head membership and the entire retained prefix remain distinct checks" do
    a = row(10, "a")
    b = row(20, "b")
    prefix = InboxPrefix.new(capture([a, b]), :consume_after_ack)
    changed_tail = capture([a, row(20, "replacement-b")])
    assert :ok = InboxPrefix.check(prefix, changed_tail, {:row, a})
    assert {:error, :prefix_changed} = InboxPrefix.check(prefix, changed_tail, :retained)
  end

  test "an append stays outside the original horizon while already applied rows remain unconfirmed" do
    captured = capture([row(10, "a"), row(20, "b")])
    applied = captured |> InboxPrefix.new(:consume_before_ack) |> InboxPrefix.applied()
    with_append = %{captured | rows: captured.rows ++ [row(30, "later")]}
    assert {:ok, rebound} = InboxPrefix.rebind(applied.prefix, with_append, :unconfirmed)
    assert rebound.rows == [Enum.at(captured.rows, 1)]
    assert rebound.applied_cursor == applied.cursor
    assert rebound.end_offset == 20
  end

  test "confirmation accepts regenerated start and digest but still rejects replacement record or offset" do
    captured = capture([row(10, "a"), row(20, "b")])
    applied = captured |> InboxPrefix.new(:consume_before_ack) |> InboxPrefix.applied()
    %{prefix: waiting, continuation: {:recapture, boundary}} = InboxPrefix.acknowledged(applied.prefix, applied.cursor)
    recaptured = capture([row(20, "b", 10, "regenerated")], 10)
    assert {:ok, _} = InboxPrefix.rebind(waiting, recaptured, boundary)
    assert {:error, :prefix_changed} = InboxPrefix.rebind(waiting, capture([row(20, "other", 10)], 10), boundary)
    assert {:error, :prefix_changed} = InboxPrefix.rebind(waiting, capture([row(21, "b", 10)], 10), boundary)
  end

  test "generation retirement clears the applied candidate while retaining diagnostic geometry" do
    captured = capture([row(10, "same-id"), row(20, "b")])
    applied = captured |> InboxPrefix.new(:consume_before_ack) |> InboxPrefix.applied()
    replacement = %{capture([row(10, "same-id")]) | generation: "new-generation"}
    assert {:error, :generation_changed} = InboxPrefix.rebind(applied.prefix, replacement, :unconfirmed)
    retired = InboxPrefix.retire_generation(applied.prefix)
    assert retired.applied_cursor == nil
    assert retired.rows == applied.prefix.rows
    assert retired.location == applied.prefix.location
    assert retired.generation == applied.prefix.generation
    assert retired.start_offset == applied.prefix.start_offset
    assert retired.end_offset == applied.prefix.end_offset
  end

  test "location and physical start mismatches cannot become a valid continuation" do
    captured = capture([row(10, "a")])
    prefix = InboxPrefix.new(captured, :consume_after_ack)
    elsewhere = %{captured | location: %{captured.location | events_path: "/another/events"}}
    assert {:error, :location_changed} = InboxPrefix.check(prefix, elsewhere, :retained)
    assert {:error, :cursor_changed} = InboxPrefix.check(prefix, %{captured | start_offset: 1}, :retained)
    assert {:error, :cursor_changed} = InboxPrefix.rebind(prefix, %{captured | start_offset: 1}, :unconfirmed)
  end

  test "a failed post-confirmation recapture does not consume the retained after-confirmation head" do
    captured = capture([row(10, "a"), row(20, "b")])
    applied = captured |> InboxPrefix.new(:consume_after_ack) |> InboxPrefix.applied()
    %{prefix: waiting, continuation: {:recapture, boundary}} = InboxPrefix.acknowledged(applied.prefix, applied.cursor)
    assert {:error, :prefix_changed} = InboxPrefix.rebind(waiting, capture([row(20, "different", 10)], 10), boundary)
    assert waiting.rows == captured.rows
    assert waiting.applied_cursor == applied.cursor
    assert waiting.start_offset == 0
  end

  test "opaque invalid records retain their exact physical cursor and can drain after application" do
    invalid = %{row(10, "unused") | record: {:invalid, :invalid_json}}
    captured = capture([invalid])
    applied = captured |> InboxPrefix.new(:consume_before_ack) |> InboxPrefix.applied()
    assert applied.cursor == invalid.cursor
    assert applied.prefix.rows == []
    assert %{prefix: cleared, continuation: :drained} = InboxPrefix.acknowledged(applied.prefix, applied.cursor)
    assert cleared.applied_cursor == nil
  end

  test "the last after-confirmation row drains only after actual confirmation was declared" do
    captured = capture([row(10, "a")])
    applied = captured |> InboxPrefix.new(:consume_after_ack) |> InboxPrefix.applied()
    assert applied.prefix.rows == captured.rows
    assert %{continuation: :drained} = InboxPrefix.acknowledged(applied.prefix, applied.cursor)
  end

  test "empty captures stay an owner decision rather than manufacturing a physical prefix" do
    assert_raise FunctionClauseError, fn -> InboxPrefix.new(capture([]), :consume_before_ack) end
  end

  defp location do
    %Location{kind: :physical_test, events_path: "/physical/events", state_path: "/physical/state", lock_path: "/physical/lock"}
  end

  defp row(ending, record, start \\ 0, digest \\ "original-digest") do
    %{cursor: %Cursor{location: location(), generation: "generation", start_offset: start, end_offset: ending, digest: digest}, record: {:ok, %{"record" => record}}}
  end

  defp capture(rows, start \\ 0), do: %{location: location(), generation: "generation", start_offset: start, rows: rows, tail: :none, limit_reached: false}
end
