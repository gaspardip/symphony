defmodule SymphonyElixir.IssueAcceptance do
  @moduledoc """
  Extracts acceptance criteria from a Linear issue description.
  """

  alias SymphonyElixir.Linear.Issue

  @section_patterns [
    ~r/^\s*[#]{1,6}\s+acceptance criteria\s*:?$/i,
    ~r/^\s*[#]{1,6}\s+acceptance\s*:?$/i,
    ~r/^\s*[#]{1,6}\s+validation\s*:?$/i,
    ~r/^\s*[#]{1,6}\s+done when\s*:?$/i,
    ~r/^\s*\*\*acceptance criteria\*\*\s*:?$/i,
    ~r/^\s*\*\*acceptance\*\*\s*:?$/i,
    ~r/^\s*\*\*validation\*\*\s*:?$/i,
    ~r/^\s*\*\*done when\*\*\s*:?$/i
  ]
  @heading_pattern ~r/^\s*[#]{1,6}\s+.+$/
  @bullet_pattern ~r/^\s*[-*+]\s+(?!\[[ xX]\])(.+?)\s*$/
  @checkbox_pattern ~r/^\s*[-*+]\s+\[[ xX]\]\s+(.+?)\s*$/

  defstruct [
    :implicit?,
    :summary,
    :source_sections,
    criteria: []
  ]

  @type t :: %__MODULE__{
          implicit?: boolean(),
          summary: String.t(),
          source_sections: [String.t()],
          criteria: [String.t()]
        }

  @spec from_issue(Issue.t() | map()) :: t()
  def from_issue(%Issue{} = issue), do: from_issue(Map.from_struct(issue))

  def from_issue(issue) when is_map(issue) do
    title =
      issue
      |> Map.get(:title, Map.get(issue, "title"))
      |> normalize_text()

    description = Map.get(issue, :description, Map.get(issue, "description"))

    case extract_sections(description) do
      {[], []} ->
        fallback_acceptance(title, normalize_text(description))

      {sections, criteria} ->
        %__MODULE__{
          implicit?: false,
          summary: build_summary(title, criteria),
          source_sections: sections,
          criteria: criteria
        }
    end
  end

  def from_issue(_issue), do: fallback_acceptance(nil, nil)

  @spec to_prompt_map(t()) :: map()
  def to_prompt_map(%__MODULE__{} = acceptance) do
    %{
      implicit_acceptance: acceptance.implicit?,
      summary: acceptance.summary,
      source_sections: acceptance.source_sections,
      criteria: acceptance.criteria
    }
  end

  defp extract_sections(nil), do: {[], []}

  defp extract_sections(description) when is_binary(description) do
    {sections, criteria, _active?} =
      description
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], [], false}, fn line, {sections, criteria, active?} ->
        criterion = if active?, do: extract_criterion(line), else: nil

        cond do
          acceptance_heading?(line) ->
            {sections ++ [normalize_heading(line)], criteria, true}

          active? and new_section_heading?(line) ->
            {sections, criteria, false}

          active? and not is_nil(criterion) ->
            {sections, criteria ++ [criterion], true}

          true ->
            {sections, criteria, active?}
        end
      end)

    dedupe = fn values ->
      values
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end

    {dedupe.(sections), dedupe.(criteria)}
  end

  defp acceptance_heading?(line) when is_binary(line) do
    Enum.any?(@section_patterns, &Regex.match?(&1, line))
  end

  defp new_section_heading?(line) when is_binary(line) do
    Regex.match?(@heading_pattern, line) and not acceptance_heading?(line)
  end

  defp extract_criterion(line) when is_binary(line) do
    cond do
      captures = Regex.run(@checkbox_pattern, line) ->
        captures |> List.last() |> normalize_text()

      captures = Regex.run(@bullet_pattern, line) ->
        captures |> List.last() |> normalize_text()

      true ->
        nil
    end
  end

  defp normalize_heading(line) do
    line
    |> String.replace(~r/^\s*[#]{1,6}\s+/, "")
    |> String.replace(~r/^\s*\*\*|\*\*\s*:?\s*$/, "")
    |> normalize_text()
  end

  defp fallback_acceptance(title, description) do
    summary =
      [title, description]
      |> Enum.map(&normalize_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> case do
        "" -> "No explicit acceptance criteria were provided."
        text -> String.slice(text, 0, 400)
      end

    %__MODULE__{
      implicit?: true,
      summary: summary,
      source_sections: [],
      criteria: []
    }
  end

  defp build_summary(nil, criteria), do: Enum.join(criteria, " ")

  defp build_summary(title, criteria) do
    [normalize_text(title) | criteria]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> String.slice(0, 400)
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end
end
