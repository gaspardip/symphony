defmodule SymphonyElixir.VerifierResult do
  @moduledoc """
  Normalizes the machine-readable verification result reported by the verifier.
  """

  @required_keys ~w(verdict summary acceptance_gaps risky_areas evidence raw_output)a
  @allowed_verdicts ~w(pass needs_more_work blocked unsafe_to_merge)a

  defstruct verdict: :blocked,
            summary: nil,
            acceptance_gaps: [],
            risky_areas: [],
            evidence: [],
            raw_output: nil

  @type verdict :: :pass | :needs_more_work | :blocked | :unsafe_to_merge

  @type t :: %__MODULE__{
          verdict: verdict(),
          summary: String.t(),
          acceptance_gaps: [String.t()],
          risky_areas: [String.t()],
          evidence: [String.t()],
          raw_output: String.t()
        }

  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(arguments) when is_map(arguments) do
    with :ok <- require_keys(arguments),
         {:ok, verdict} <- normalize_verdict(arguments),
         {:ok, summary} <- normalize_summary(arguments),
         {:ok, acceptance_gaps} <- normalize_string_list(arguments, :acceptance_gaps),
         {:ok, risky_areas} <- normalize_string_list(arguments, :risky_areas),
         {:ok, evidence} <- normalize_string_list(arguments, :evidence),
         {:ok, raw_output} <- normalize_raw_output(arguments) do
      {:ok,
       %__MODULE__{
         verdict: verdict,
         summary: summary,
         acceptance_gaps: acceptance_gaps,
         risky_areas: risky_areas,
         evidence: evidence,
         raw_output: raw_output
       }}
    end
  end

  def normalize(_arguments), do: {:error, :invalid_verifier_result}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      verdict: Atom.to_string(result.verdict),
      summary: result.summary,
      acceptance_gaps: result.acceptance_gaps,
      risky_areas: result.risky_areas,
      evidence: result.evidence,
      raw_output: result.raw_output
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

  defp normalize_verdict(arguments) do
    case fetch(arguments, :verdict) do
      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> String.downcase()
          |> String.replace("-", "_")

        case Enum.find(@allowed_verdicts, &(Atom.to_string(&1) == normalized)) do
          nil -> {:error, :invalid_verdict}
          verdict -> {:ok, verdict}
        end

      _ ->
        {:error, :invalid_verdict}
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

  defp normalize_string_list(arguments, key) do
    case fetch(arguments, key) do
      values when is_list(values) ->
        {:ok,
         values
         |> Enum.map(&to_string/1)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))}

      _ ->
        {:error, {:invalid_string_list, key}}
    end
  end

  defp normalize_raw_output(arguments) do
    case fetch(arguments, :raw_output) do
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, :invalid_raw_output}
    end
  end

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
