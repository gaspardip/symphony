defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_by_id(String.t()) :: {:ok, term() | nil} | {:error, term()}
  @callback fetch_issue_by_identifier(String.t()) :: {:ok, term() | nil} | {:error, term()}
  @callback decode_webhook([{binary(), binary()}], binary()) ::
              {:ok, [term()]} | {:ignore, term()} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback attach_link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, term() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier) do
    adapter().fetch_issue_by_identifier(issue_identifier)
  end

  @spec fetch_issue_by_id(String.t()) :: {:ok, term() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id) do
    adapter().fetch_issue_by_id(issue_id)
  end

  @spec decode_webhook([{binary(), binary()}], binary()) ::
          {:ok, [term()]} | {:ignore, term()} | {:error, term()}
  def decode_webhook(headers, raw_body) when is_list(headers) and is_binary(raw_body) do
    adapter().decode_webhook(headers, raw_body)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec attach_link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def attach_link(issue_id, title, url) do
    adapter().attach_link(issue_id, title, url)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.tracker_kind() do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
