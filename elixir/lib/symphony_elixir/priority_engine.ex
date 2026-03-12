defmodule SymphonyElixir.PriorityEngine do
  @moduledoc """
  Deterministic queue ranking for dispatch order and dashboard presentation.
  """

  alias SymphonyElixir.Linear.Issue

  @default_override_rank 100
  @missing_created_at_sort_key 9_223_372_036_854_775_807

  @type queue_entry :: %{
          issue: Issue.t(),
          identifier: String.t() | nil,
          issue_id: String.t() | nil,
          rank: pos_integer(),
          score: {integer(), integer(), integer(), integer(), String.t()},
          reasons: map()
        }

  @spec rank_issues([Issue.t()], keyword()) :: [queue_entry()]
  def rank_issues(issues, opts \\ []) when is_list(issues) do
    overrides = Keyword.get(opts, :priority_overrides, %{})
    retry_attempts = Keyword.get(opts, :retry_attempts, %{})

    issues
    |> Enum.map(fn
      %Issue{} = issue ->
        score = score(issue, overrides, retry_attempts)

        %{
          issue: issue,
          identifier: issue.identifier,
          issue_id: issue.id,
          score: score,
          reasons: %{
            operator_override: Map.get(overrides, issue.identifier),
            linear_priority: issue.priority,
            retry_penalty: retry_penalty(issue, retry_attempts),
            created_at: issue.created_at
          }
        }
    end)
    |> Enum.sort_by(& &1.score)
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, rank} -> Map.put(entry, :rank, rank) end)
  end

  @spec score(Issue.t(), map(), map()) :: {integer(), integer(), integer(), integer(), String.t()}
  def score(%Issue{} = issue, overrides, retry_attempts)
      when is_map(overrides) and is_map(retry_attempts) do
    {
      override_rank(issue, overrides),
      linear_priority_rank(issue.priority),
      retry_penalty(issue, retry_attempts),
      created_at_sort_key(issue),
      issue.identifier || issue.id || ""
    }
  end

  defp override_rank(%Issue{identifier: identifier}, overrides) when is_binary(identifier) do
    case Map.get(overrides, identifier) do
      value when is_integer(value) -> value
      _ -> @default_override_rank
    end
  end

  defp override_rank(_issue, _overrides), do: @default_override_rank

  defp linear_priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp linear_priority_rank(_priority), do: 5

  defp retry_penalty(%Issue{id: issue_id, identifier: identifier}, retry_attempts)
       when is_map(retry_attempts) do
    retry_entry =
      Map.get(retry_attempts, issue_id) ||
        if(is_binary(identifier), do: Map.get(retry_attempts, identifier), else: nil)

    case retry_entry do
      %{attempt: attempt} when is_integer(attempt) and attempt > 0 -> attempt
      attempt when is_integer(attempt) and attempt > 0 -> attempt
      _ -> 0
    end
  end

  defp created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp created_at_sort_key(%Issue{}), do: @missing_created_at_sort_key
end
