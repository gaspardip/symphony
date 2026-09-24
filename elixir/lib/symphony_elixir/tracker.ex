defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.TrackerReadContext

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
  def fetch_candidate_issues, do: fetch_candidate_issues(Config.tracker_read_context())

  @spec fetch_candidate_issues(TrackerReadContext.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(%TrackerReadContext{} = context) do
    case context.tracker_kind do
      "memory" -> SymphonyElixir.Tracker.Memory.fetch_candidate_issues()
      _ -> SymphonyElixir.Linear.Adapter.fetch_candidate_issues(context)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: fetch_issues_by_states(states, Config.tracker_read_context())

  @spec fetch_issues_by_states([String.t()], TrackerReadContext.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, %TrackerReadContext{} = context) do
    case context.tracker_kind do
      "memory" -> SymphonyElixir.Tracker.Memory.fetch_issues_by_states(states)
      _ -> SymphonyElixir.Linear.Adapter.fetch_issues_by_states(states, context)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: fetch_issue_states_by_ids(issue_ids, Config.tracker_read_context())

  @spec fetch_issue_states_by_ids([String.t()], TrackerReadContext.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, %TrackerReadContext{} = context) do
    case context.tracker_kind do
      "memory" -> SymphonyElixir.Tracker.Memory.fetch_issue_states_by_ids(issue_ids)
      _ -> SymphonyElixir.Linear.Adapter.fetch_issue_states_by_ids(issue_ids, context)
    end
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, term() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier), do: fetch_issue_by_identifier(issue_identifier, Config.tracker_read_context())

  @spec fetch_issue_by_identifier(String.t(), TrackerReadContext.t()) :: {:ok, term() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier, %TrackerReadContext{} = context) do
    case context.tracker_kind do
      "memory" -> SymphonyElixir.Tracker.Memory.fetch_issue_by_identifier(issue_identifier)
      _ -> SymphonyElixir.Linear.Adapter.fetch_issue_by_identifier(issue_identifier, context)
    end
  end

  @spec fetch_issue_by_id(String.t()) :: {:ok, term() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id), do: fetch_issue_by_id(issue_id, Config.tracker_read_context())

  @spec fetch_issue_by_id(String.t(), TrackerReadContext.t()) :: {:ok, term() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id, %TrackerReadContext{} = context) do
    case context.tracker_kind do
      "memory" -> SymphonyElixir.Tracker.Memory.fetch_issue_by_id(issue_id)
      _ -> SymphonyElixir.Linear.Adapter.fetch_issue_by_id(issue_id, context)
    end
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
