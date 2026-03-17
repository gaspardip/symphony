defmodule SymphonyElixir.TurnResult do
  @moduledoc """
  Normalizes the machine-readable end-of-turn contract reported by the agent.
  """

  # credo:disable-for-this-file

  @required_keys ~w(summary files_touched needs_another_turn blocked blocker_type)a
  @implementation_blockers ~w(implementation validation verifier)a
  @runtime_owned_blocker_markers [
    "commit could not be created",
    "could not create commit",
    "couldn't create commit",
    "unable to create commit",
    "git metadata for this worktree",
    "git index access",
    "outside the writable sandbox",
    "escalation is disallowed",
    "could not stage",
    "couldn't stage",
    "unable to stage",
    "could not push",
    "couldn't push",
    "unable to push",
    "could not open pr",
    "couldn't open pr",
    "unable to open pr",
    "could not create pr",
    "couldn't create pr",
    "unable to create pr",
    "could not create pull request",
    "couldn't create pull request",
    "unable to create pull request"
  ]
  @runtime_owned_more_work_markers [
    "additional verified review claim remains",
    "another verified review claim remains",
    "remaining verified review claim",
    "for a subsequent turn",
    "needs another turn",
    "remaining review claim"
  ]
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
       }
       |> normalize_runtime_owned_blocker()}
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
          blocked == false and blocker_type == :invalid ->
            {:ok, :none}

          blocker_type in @allowed_blockers ->
            if blocked == false and blocker_type != :none do
              {:ok, :none}
            else
              {:ok, blocker_type}
            end

          blocked == false ->
            {:ok, :none}

          true ->
            {:ok, :implementation}
        end

      _ ->
        if blocked == false do
          {:ok, :none}
        else
          {:ok, :implementation}
        end
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

  defp normalize_runtime_owned_blocker(%__MODULE__{blocked: true, blocker_type: blocker_type, summary: summary} = turn_result)
       when blocker_type in [:implementation, :publish, :merge, :review] and is_binary(summary) do
    if runtime_owned_blocker_summary?(summary) do
      %{
        turn_result
        | blocked: false,
          blocker_type: :none,
          needs_another_turn: turn_result.needs_another_turn || runtime_owned_more_work?(summary)
      }
    else
      turn_result
    end
  end

  defp normalize_runtime_owned_blocker(%__MODULE__{} = turn_result), do: turn_result

  defp runtime_owned_blocker_summary?(summary) when is_binary(summary) do
    normalized_summary = String.downcase(summary)
    Enum.any?(@runtime_owned_blocker_markers, &String.contains?(normalized_summary, &1))
  end

  defp runtime_owned_more_work?(summary) when is_binary(summary) do
    normalized_summary = String.downcase(summary)
    Enum.any?(@runtime_owned_more_work_markers, &String.contains?(normalized_summary, &1))
  end
end
