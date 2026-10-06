defmodule SymphonyElixir.InboxPrefix do
  @moduledoc """
  Continuity of a finite physical inbox capture across application and confirmation.

  This value never reads storage, acknowledges a cursor or authorizes an effect.
  The owner declares application and supplies the actual confirmed cursor. Before
  confirmation, physical cursors must match exactly; after confirmation, retained
  records and their end offsets must match the original captured horizon.
  """

  alias SymphonyElixir.EventInbox.Cursor

  @enforce_keys [:location, :generation, :start_offset, :end_offset, :rows, :consumption]
  defstruct @enforce_keys ++ [applied_cursor: nil]

  @type row :: %{cursor: Cursor.t(), record: term()}
  @type consumption :: :consume_before_ack | :consume_after_ack
  @type mismatch :: :location_changed | :generation_changed | :cursor_changed | :prefix_changed
  @type t :: %__MODULE__{
          location: SymphonyElixir.EventInbox.Location.t(),
          generation: term(),
          start_offset: non_neg_integer(),
          end_offset: non_neg_integer(),
          rows: [row()],
          applied_cursor: Cursor.t() | nil,
          consumption: consumption()
        }

  defmodule Boundary do
    @moduledoc "The confirmed physical cursor and the original rows still expected."
    @enforce_keys [:cursor, :rows]
    defstruct @enforce_keys
    @type t :: %__MODULE__{cursor: SymphonyElixir.EventInbox.Cursor.t(), rows: [SymphonyElixir.InboxPrefix.row()]}
  end

  @spec new(map(), consumption()) :: t()
  def new(%{location: location, generation: generation, start_offset: start_offset, rows: [_ | _] = rows}, consumption)
      when consumption in [:consume_before_ack, :consume_after_ack] do
    %__MODULE__{
      location: location,
      generation: generation,
      start_offset: start_offset,
      end_offset: List.last(rows).cursor.end_offset,
      rows: rows,
      consumption: consumption
    }
  end

  @spec check(t(), map(), :retained | {:row, row()}) :: :ok | {:error, mismatch()}
  def check(%__MODULE__{} = prefix, captured, scope) do
    with :ok <- same_origin(prefix, captured, prefix.start_offset) do
      same =
        case scope do
          :retained -> Enum.take(captured.rows, length(prefix.rows)) == prefix.rows
          {:row, row} -> Enum.any?(captured.rows, &(&1 == row))
        end

      if same, do: :ok, else: {:error, :prefix_changed}
    end
  end

  @spec applied(t()) :: %{prefix: t(), cursor: Cursor.t()}
  def applied(%__MODULE__{consumption: :consume_before_ack, rows: [row | remaining]} = prefix) do
    %{prefix: %{prefix | rows: remaining, applied_cursor: row.cursor}, cursor: row.cursor}
  end

  def applied(%__MODULE__{consumption: :consume_after_ack, rows: [row | _]} = prefix) do
    %{prefix: %{prefix | applied_cursor: row.cursor}, cursor: row.cursor}
  end

  @spec acknowledged(t(), Cursor.t()) :: %{prefix: t(), continuation: :drained | {:recapture, Boundary.t()}}
  def acknowledged(%__MODULE__{consumption: :consume_before_ack} = prefix, %Cursor{} = cursor) do
    after_confirmation(%{prefix | applied_cursor: nil}, prefix.rows, cursor)
  end

  def acknowledged(%__MODULE__{consumption: :consume_after_ack, rows: [_ | remaining]} = prefix, %Cursor{} = cursor) do
    # The owner retains the completed row/head until recapture succeeds. Clearing
    # pending ACK or confirming custody does not publish a replacement prefix.
    after_confirmation(prefix, remaining, cursor)
  end

  @spec rebind(t(), map(), :unconfirmed | Boundary.t()) :: {:ok, t()} | {:error, mismatch()}
  def rebind(%__MODULE__{} = prefix, captured, :unconfirmed) do
    with :ok <- same_origin(prefix, captured, prefix.start_offset) do
      rows = retained_rows(prefix, captured, prefix.rows)

      if rows == prefix.rows,
        do: {:ok, %{prefix | rows: rows, start_offset: captured.start_offset}},
        else: {:error, :prefix_changed}
    end
  end

  def rebind(%__MODULE__{} = prefix, captured, %Boundary{cursor: cursor, rows: expected}) do
    with :ok <- same_origin(prefix, captured, cursor.end_offset) do
      rows = retained_rows(%{prefix | applied_cursor: nil}, captured, expected)

      if row_identity(rows) == row_identity(expected),
        do: {:ok, %{prefix | rows: rows, start_offset: captured.start_offset, applied_cursor: nil}},
        else: {:error, :prefix_changed}
    end
  end

  @spec retire_generation(t()) :: t()
  def retire_generation(%__MODULE__{} = prefix), do: %{prefix | applied_cursor: nil}

  defp after_confirmation(prefix, [], _cursor), do: %{prefix: prefix, continuation: :drained}

  defp after_confirmation(prefix, rows, cursor),
    do: %{prefix: prefix, continuation: {:recapture, %Boundary{cursor: cursor, rows: rows}}}

  defp same_origin(prefix, captured, expected_start) do
    cond do
      captured.generation != prefix.generation -> {:error, :generation_changed}
      captured.location != prefix.location -> {:error, :location_changed}
      captured.start_offset != expected_start -> {:error, :cursor_changed}
      true -> :ok
    end
  end

  defp retained_rows(%__MODULE__{consumption: :consume_before_ack} = prefix, captured, _expected) do
    applied_end = if prefix.applied_cursor, do: prefix.applied_cursor.end_offset, else: captured.start_offset
    Enum.filter(captured.rows, &(&1.cursor.end_offset <= prefix.end_offset and &1.cursor.end_offset > applied_end))
  end

  defp retained_rows(%__MODULE__{consumption: :consume_after_ack}, captured, expected),
    do: Enum.take(captured.rows, length(expected))

  defp row_identity(rows), do: Enum.map(rows, &{&1.cursor.end_offset, &1.record})
end
