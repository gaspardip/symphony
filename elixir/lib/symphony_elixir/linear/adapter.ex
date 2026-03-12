defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Webhook

  @state_cache_table :symphony_linear_state_ids

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @attachment_create_mutation """
  mutation SymphonyAttachmentCreate($issueId: String!, $title: String!, $url: String!) {
    attachmentCreate(input: {issueId: $issueId, title: $title, url: $url}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        id
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, term() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier),
    do: client_module().fetch_issue_by_identifier(issue_identifier)

  @spec fetch_issue_by_id(String.t()) :: {:ok, term() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id), do: client_module().fetch_issue_by_id(issue_id)

  @spec decode_webhook([{binary(), binary()}], binary()) ::
          {:ok, [map()]} | {:ignore, term()} | {:error, term()}
  def decode_webhook(headers, raw_body), do: Webhook.decode(headers, raw_body)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec attach_link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def attach_link(issue_id, title, url)
      when is_binary(issue_id) and is_binary(title) and is_binary(url) do
    with {:ok, response} <-
           client_module().graphql(@attachment_create_mutation, %{
             issueId: issue_id,
             title: title,
             url: url
           }),
         true <- get_in(response, ["data", "attachmentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :attachment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :attachment_create_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, team_id} <- resolve_issue_team_id(issue_id),
         {:ok, state_id} <- resolve_cached_state_id(team_id, issue_id, state_name) do
      {:ok, state_id}
    end
  end

  defp resolve_issue_team_id(issue_id) do
    ensure_state_cache_table!()

    case :ets.lookup(@state_cache_table, {:issue_team, issue_id}) do
      [{{:issue_team, ^issue_id}, team_id}] when is_binary(team_id) ->
        {:ok, team_id}

      _ ->
        with {:ok, response} <-
               client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: "__unused__"}),
             team_id when is_binary(team_id) <- get_in(response, ["data", "issue", "team", "id"]) do
          true = :ets.insert(@state_cache_table, {{:issue_team, issue_id}, team_id})
          {:ok, team_id}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :state_not_found}
        end
    end
  end

  defp resolve_cached_state_id(team_id, issue_id, state_name)
       when is_binary(team_id) and is_binary(issue_id) and is_binary(state_name) do
    ensure_state_cache_table!()
    cache_key = {:team_state, team_id, normalize_state_name(state_name)}

    case :ets.lookup(@state_cache_table, cache_key) do
      [{^cache_key, state_id}] when is_binary(state_id) ->
        {:ok, state_id}

      _ ->
        with {:ok, response} <-
               client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
             state_id when is_binary(state_id) <-
               get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
          true = :ets.insert(@state_cache_table, {cache_key, state_id})
          {:ok, state_id}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :state_not_found}
        end
    end
  end

  defp ensure_state_cache_table! do
    case :ets.whereis(@state_cache_table) do
      :undefined ->
        :ets.new(@state_cache_table, [:named_table, :public, read_concurrency: true])

      _tid ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp normalize_state_name(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end
end
