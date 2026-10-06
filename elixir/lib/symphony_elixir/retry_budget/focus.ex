defmodule SymphonyElixir.RetryBudget.Focus do
  @moduledoc """
  Infers the bounded file focus and compact learning for a broad retry.

  Explicit resume paths precede issue text, changed files and agent updates.
  Queries preserve their existing selective reads; this module does not decide
  retry admission, consume token budgets, persist resume data or schedule work.
  """

  alias SymphonyElixir.RetryBudget.Observation
  alias SymphonyElixir.RunInspector

  @type retry_fields :: %{target_paths: [String.t()], already_learned: String.t() | nil}

  @spec retry_fields(map(), map(), map()) :: retry_fields()
  def retry_fields(entry, resume, overrides) do
    # The original Map.get default is eager even when overrides supply paths.
    paths = Map.get(overrides, :target_paths, broad_implement_candidate_paths(entry, resume))
    learned = broad_implement_already_learned(entry, resume, paths)
    %{target_paths: paths, already_learned: learned}
  end

  @spec primary_path(map(), map()) :: String.t() | nil
  def primary_path(running_entry, resume_context)
      when is_map(running_entry) and is_map(resume_context) do
    resume_context
    |> Map.get(:target_paths, [])
    |> normalize_paths()
    |> case do
      [path | _rest] ->
        path

      [] ->
        running_entry
        |> broad_implement_candidate_paths(resume_context)
        |> List.first()
    end
  end

  def primary_path(_running_entry, _resume_context), do: nil

  @spec next_path(map(), map(), String.t() | nil) :: String.t() | nil
  def next_path(running_entry, resume_context, primary_target_path)
      when is_map(running_entry) and is_map(resume_context) and is_binary(primary_target_path) do
    existing =
      case Map.get(resume_context, :next_required_path) do
        path when is_binary(path) and path != "" and path != primary_target_path -> path
        _ -> nil
      end

    existing ||
      running_entry
      |> broad_implement_candidate_paths(resume_context)
      |> Enum.reject(&(&1 == primary_target_path))
      |> List.first()
  end

  def next_path(_running_entry, _resume_context, _primary_target_path),
    do: nil

  @spec normalize_paths(term()) :: [String.t()]
  def normalize_paths(paths) when is_list(paths) do
    normalized =
      paths
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> normalize_diff_marker_paths()
      |> Enum.uniq()

    full_path_basenames =
      normalized
      |> Enum.filter(&String.contains?(&1, "/"))
      |> Enum.map(&Path.basename/1)
      |> MapSet.new()

    normalized
    |> Enum.reject(fn path ->
      not String.contains?(path, "/") and MapSet.member?(full_path_basenames, path)
    end)
  end

  def normalize_paths(_paths), do: []

  defp broad_implement_already_learned(running_entry, resume_context, target_paths)
       when is_map(running_entry) and is_map(resume_context) do
    existing =
      case Map.get(resume_context, :already_learned) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    summary =
      [
        Observation.text_facts(Map.get(resume_context, :last_turn_summary)),
        Map.fetch!(running_entry, :last_agent_message_text),
        Map.fetch!(running_entry, :recent_agent_updates_text)
      ]
      |> Enum.map(&summary_fact/1)
      |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))

    cond do
      target_paths != [] ->
        "Stay inside #{Enum.join(target_paths, ", ")} and avoid unrelated reads or repo-wide rediscovery."

      is_binary(existing) ->
        existing

      is_binary(summary) ->
        summarized_text(summary, 220)

      true ->
        nil
    end
  end

  defp broad_implement_already_learned(_running_entry, _resume_context, _target_paths), do: nil

  defp broad_implement_candidate_paths(running_entry, resume_context)
       when is_map(running_entry) and is_map(resume_context) do
    existing_paths =
      resume_context
      |> Map.get(:target_paths, [])
      |> normalize_paths()

    issue_paths =
      running_entry
      |> Map.get(:issue, %{})
      |> extract_candidate_paths()

    dirty_paths =
      running_entry
      |> broad_implement_workspace_paths()
      |> Enum.take(6)

    summary_paths =
      [
        Map.get(resume_context, :last_turn_summary),
        Map.get(resume_context, :next_objective),
        Map.fetch!(running_entry, :last_agent_message_text).fragments,
        Map.fetch!(running_entry, :recent_agent_updates_text).fragments
      ]
      |> Enum.flat_map(&extract_candidate_paths/1)

    existing_paths
    |> Kernel.++(issue_paths)
    |> Kernel.++(dirty_paths)
    |> Kernel.++(summary_paths)
    |> normalize_paths()
    |> Enum.take(4)
  end

  defp broad_implement_candidate_paths(_running_entry, _resume_context), do: []

  defp normalize_diff_marker_paths(paths) do
    bare_paths = MapSet.new(paths)

    diff_prefixed_tails =
      paths
      |> Enum.reduce(MapSet.new(), fn path, acc ->
        case diff_marker_tail(path) do
          {:ok, tail} ->
            sibling_a = "a/" <> tail
            sibling_b = "b/" <> tail

            if MapSet.member?(bare_paths, tail) or
                 (Enum.member?(paths, sibling_a) and Enum.member?(paths, sibling_b)) do
              MapSet.put(acc, tail)
            else
              acc
            end

          :error ->
            acc
        end
      end)

    Enum.map(paths, fn path ->
      case diff_marker_tail(path) do
        {:ok, tail} ->
          if MapSet.member?(diff_prefixed_tails, tail), do: tail, else: path

        :error ->
          path
      end
    end)
  end

  defp broad_implement_workspace_paths(running_entry) do
    workspace = Map.get(running_entry, :workspace) || Map.get(running_entry, :workspace_path)

    if is_binary(workspace) do
      workspace
      |> RunInspector.changed_paths()
      |> normalize_paths()
    else
      []
    end
  end

  defp diff_marker_tail(<<"a/", rest::binary>>) when rest != "",
    do: validate_diff_marker_tail(rest)

  defp diff_marker_tail(<<"b/", rest::binary>>) when rest != "",
    do: validate_diff_marker_tail(rest)

  defp diff_marker_tail(_path), do: :error

  defp extract_candidate_paths(nil), do: []

  defp extract_candidate_paths(text) when is_binary(text) do
    Regex.scan(
      ~r{(?:^|[\s`'"])((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:ex|exs|md|yaml|yml|json|sh))(?=$|[\s`'".,;:])},
      text,
      capture: :all_but_first
    )
    |> List.flatten()
    |> normalize_paths()
  end

  defp extract_candidate_paths(value) when is_map(value) or is_list(value) do
    value
    |> Observation.text_facts()
    |> Map.fetch!(:fragments)
    |> Enum.flat_map(&extract_candidate_paths/1)
    |> normalize_paths()
  end

  defp extract_candidate_paths(_text), do: []

  defp summary_fact(%{summary: :empty}), do: nil
  defp summary_fact(%{summary: {:binary, value}}), do: nonempty(String.trim(value))

  defp summary_fact(%{summary: {:structured, fragments}}) do
    fragments
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> nonempty()
  end

  defp summary_fact(%{summary: {:scalar, value}}), do: to_string(value)

  defp summary_fact(%{summary: :unsupported}) do
    raise Protocol.UndefinedError, protocol: String.Chars, value: {:unsupported_budget_summary}
  end

  defp nonempty(""), do: nil
  defp nonempty(value), do: value

  defp summarizable_text(value), do: value |> Observation.text_facts() |> summary_fact()

  defp summarized_text(nil, _limit), do: nil

  defp summarized_text(value, limit) when is_integer(limit) and limit > 0 do
    value
    |> summarizable_text()
    |> case do
      nil ->
        nil

      text ->
        text
        |> String.trim()
        |> case do
          "" ->
            nil

          trimmed ->
            if String.length(trimmed) <= limit do
              trimmed
            else
              String.slice(trimmed, 0, max(limit - 3, 0)) <> "..."
            end
        end
    end
  end

  defp validate_diff_marker_tail(rest) do
    if String.contains?(rest, "/") and
         Regex.match?(~r/\.(?:ex|exs|md|yaml|yml|json|sh)\z/, rest) do
      {:ok, rest}
    else
      :error
    end
  end
end
