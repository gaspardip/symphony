defmodule SymphonyElixir.AuthorProfile do
  @moduledoc """
  Loads a local operator author profile used to render commits, PR bodies, and
  external-facing summaries in the operator's preferred style.
  """

  alias SymphonyElixir.Config

  defstruct [
    :commit_tone,
    :pr_tone,
    :comment_tone,
    :certainty_language,
    :terse_by_default,
    :draft_replies_first
  ]

  @type t :: %__MODULE__{
          commit_tone: String.t(),
          pr_tone: String.t(),
          comment_tone: String.t(),
          certainty_language: String.t(),
          terse_by_default: boolean(),
          draft_replies_first: boolean()
        }

  @spec load() :: t()
  def load do
    case Config.author_profile_path() do
      nil ->
        default_profile()

      path ->
        with {:ok, payload} <- File.read(path),
             {:ok, decoded} <- Jason.decode(payload) do
          decoded
          |> normalize_profile()
        else
          _ -> default_profile()
        end
    end
  end

  @spec commit_message(map(), String.t()) :: String.t()
  def commit_message(issue, summary) when is_binary(summary) do
    profile = load()
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || "issue"
    body = sanitize_summary(summary)

    subject =
      case profile.commit_tone do
        "descriptive" -> "#{identifier}: #{body}"
        _ -> "#{identifier}: #{body}"
      end

    String.slice(subject, 0, 72)
  end

  @spec summarize(String.t(), :pr | :comment | :general) :: String.t()
  def summarize(text, kind \\ :general) when is_binary(text) do
    profile = load()

    max_length =
      case {kind, profile.terse_by_default} do
        {:comment, true} -> 120
        {:pr, true} -> 160
        _ -> 220
      end

    text
    |> sanitize_summary()
    |> maybe_adjust_certainty(profile.certainty_language)
    |> String.slice(0, max_length)
  end

  defp normalize_profile(decoded) when is_map(decoded) do
    %__MODULE__{
      commit_tone: normalize_string(Map.get(decoded, "commit_tone"), "concise"),
      pr_tone: normalize_string(Map.get(decoded, "pr_tone"), "clear"),
      comment_tone: normalize_string(Map.get(decoded, "comment_tone"), "measured"),
      certainty_language: normalize_string(Map.get(decoded, "certainty_language"), "measured"),
      terse_by_default: normalize_boolean(Map.get(decoded, "terse_by_default"), true),
      draft_replies_first: normalize_boolean(Map.get(decoded, "draft_replies_first"), true)
    }
  end

  defp normalize_profile(_decoded), do: default_profile()

  defp normalize_string(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      normalized -> normalized
    end
  end

  defp normalize_string(_value, fallback), do: fallback

  defp normalize_boolean(value, _fallback) when value in [true, false], do: value
  defp normalize_boolean(_value, fallback), do: fallback

  defp sanitize_summary(summary) do
    summary
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp maybe_adjust_certainty(text, "measured") do
    text
    |> String.replace("must ", "should ")
    |> String.replace("definitely ", "")
  end

  defp maybe_adjust_certainty(text, _mode), do: text

  defp default_profile do
    %__MODULE__{
      commit_tone: "concise",
      pr_tone: "clear",
      comment_tone: "measured",
      certainty_language: "measured",
      terse_by_default: true,
      draft_replies_first: true
    }
  end
end
