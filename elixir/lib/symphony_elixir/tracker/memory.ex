defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&SymphonyElixir.Util.normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, SymphonyElixir.Util.normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier) when is_binary(issue_identifier) do
    {:ok,
     Enum.find(issue_entries(), fn
       %Issue{identifier: ^issue_identifier} -> true
       _ -> false
     end)}
  end

  @spec fetch_issue_by_id(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id) when is_binary(issue_id) do
    {:ok,
     Enum.find(issue_entries(), fn
       %Issue{id: ^issue_id} -> true
       _ -> false
     end)}
  end

  @spec decode_webhook([{binary(), binary()}], binary()) ::
          {:ok, [map()]} | {:ignore, term()} | {:error, term()}
  def decode_webhook(_headers, _raw_body), do: {:error, :unsupported_webhook}

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec attach_link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def attach_link(issue_id, title, url) do
    send_event({:memory_tracker_attach_link, issue_id, title, url})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
