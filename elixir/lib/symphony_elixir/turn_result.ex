defmodule SymphonyElixir.TurnResult do
  @moduledoc """
  Normalizes the machine-readable end-of-turn contract reported by the agent.
  """

  # credo:disable-for-this-file

  @required_keys ~w(summary files_touched needs_another_turn blocked blocker_type)a
  @implementation_blockers ~w(implementation validation verifier)a
  @allowed_blockers [
    :none,
    :environment,
    :implementation,
    :validation,
    :verifier,
    :publish,
    :review,
    :merge,
    :post_merge
  ]

  defstruct summary: nil,
            files_touched: [],
            needs_another_turn: false,
            blocked: false,
            blocker_type: :none

  @type blocker_type ::
          :none
          | :environment
          | :implementation
          | :validation
          | :verifier
          | :publish
          | :review
          | :merge
          | :post_merge

  @type t :: %__MODULE__{
          summary: String.t(),
          files_touched: [String.t()],
          needs_another_turn: boolean(),
          blocked: boolean(),
          blocker_type: blocker_type()
        }

  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(arguments) when is_map(arguments) do
    with :ok <- require_keys(arguments),
         {:ok, summary} <- normalize_summary(arguments),
         {:ok, files_touched} <- normalize_files_touched(arguments),
         {:ok, needs_another_turn} <- normalize_boolean(arguments, :needs_another_turn),
         {:ok, blocked} <- normalize_boolean(arguments, :blocked),
         {:ok, blocker_type} <- normalize_blocker_type(arguments, blocked) do
      {:ok,
       %__MODULE__{
         summary: summary,
         files_touched: files_touched,
         needs_another_turn: needs_another_turn,
         blocked: blocked,
         blocker_type: blocker_type
       }}
    end
  end

  def normalize(_arguments), do: {:error, :invalid_turn_result}

  @spec implementation_blocker?(t()) :: boolean()
  def implementation_blocker?(%__MODULE__{blocker_type: blocker_type}) do
    blocker_type in @implementation_blockers
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = turn_result) do
    %{
      summary: turn_result.summary,
      files_touched: turn_result.files_touched,
      needs_another_turn: turn_result.needs_another_turn,
      blocked: turn_result.blocked,
      blocker_type: Atom.to_string(turn_result.blocker_type)
    }
  end

  defp require_keys(arguments) do
    missing =
      Enum.reject(@required_keys, fn key ->
        Map.has_key?(arguments, key) or Map.has_key?(arguments, Atom.to_string(key))
      end)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_keys, missing}}
    end
  end

  defp normalize_summary(arguments) do
    case fetch(arguments, :summary) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :empty_summary}
          summary -> {:ok, summary}
        end

      _ ->
        {:error, :invalid_summary}
    end
  end

  defp normalize_files_touched(arguments) do
    case fetch(arguments, :files_touched) do
      values when is_list(values) ->
        files =
          values
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, files}

      _ ->
        {:error, :invalid_files_touched}
    end
  end

  defp normalize_boolean(arguments, key) do
    case fetch(arguments, key) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_boolean, key}}
    end
  end

  defp normalize_blocker_type(arguments, blocked) do
    case fetch(arguments, :blocker_type) do
      nil when blocked == false ->
        {:ok, :none}

      value when is_binary(value) ->
        blocker_type = parse_blocker_type(value)

        cond do
          blocker_type == :invalid ->
            {:error, :invalid_blocker_type}

          blocker_type in @allowed_blockers ->
            if blocked == false and blocker_type != :none do
              {:error, :unexpected_blocker_type}
            else
              {:ok, blocker_type}
            end

          true ->
            {:error, :invalid_blocker_type}
        end

      _ ->
        {:error, :invalid_blocker_type}
    end
  end

  defp parse_blocker_type(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    case normalized do
      "" ->
        :none

      normalized ->
        try do
          String.to_existing_atom(normalized)
        rescue
          ArgumentError -> :invalid
        end
    end
  end

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
