defmodule SymphonyElixir.IssueSource do
  @moduledoc """
  Source-aware issue reads and writes across tracker-backed and manual issues.
  """

  alias SymphonyElixir.{Config, CredentialRegistry, ManualIssueSpec, ManualIssueStore, PolicyPack, Tracker}
  alias SymphonyElixir.Linear.Issue

  @type issue_ref :: %{
          required(:source) => :manual | :tracker | nil,
          optional(:id) => String.t() | nil,
          optional(:external_id) => String.t() | nil,
          optional(:identifier) => String.t() | nil,
          optional(:canonical_identifier) => String.t() | nil
        }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    merge_issue_lists(tracker_fetch(&Tracker.fetch_candidate_issues/0), manual_fetch(&ManualIssueStore.fetch_candidate_issues/0))
  end

  @spec fetch_manual_candidate_issues() :: {:ok, [Issue.t()]}
  def fetch_manual_candidate_issues do
    manual_fetch(&ManualIssueStore.fetch_candidate_issues/0)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    merge_issue_lists(
      tracker_fetch(fn -> Tracker.fetch_issues_by_states(states) end),
      manual_fetch(fn -> ManualIssueStore.fetch_issues_by_states(states) end)
    )
  end

  @spec fetch_manual_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_manual_issues_by_states(states) when is_list(states) do
    manual_fetch(fn -> ManualIssueStore.fetch_issues_by_states(states) end)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    {manual_ids, tracker_ids} = Enum.split_with(issue_ids, &ManualIssueSpec.runtime_issue_id?/1)

    with {:ok, manual_issues} <- manual_fetch(fn -> ManualIssueStore.fetch_issue_states_by_ids(manual_ids) end),
         {:ok, tracker_issues} <- tracker_fetch(fn -> Tracker.fetch_issue_states_by_ids(tracker_ids) end) do
      {:ok, manual_issues ++ tracker_issues}
    end
  end

  @spec fetch_manual_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_manual_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.filter(&ManualIssueSpec.runtime_issue_id?/1)
    |> ManualIssueStore.fetch_issue_states_by_ids()
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier) when is_binary(issue_identifier) do
    case manual_lookup(fn -> ManualIssueStore.fetch_issue_by_identifier(issue_identifier) end) do
      {:ok, %Issue{} = issue} ->
        {:ok, issue}

      {:ok, nil} ->
        tracker_lookup(fn -> Tracker.fetch_issue_by_identifier(issue_identifier) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_issue_by_id(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id) when is_binary(issue_id) do
    if ManualIssueSpec.runtime_issue_id?(issue_id) do
      manual_lookup(fn -> ManualIssueStore.fetch_issue_by_id(issue_id) end)
    else
      tracker_lookup(fn -> Tracker.fetch_issue_by_id(issue_id) end)
    end
  end

  @spec refresh_issue(Issue.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def refresh_issue(%Issue{} = issue), do: fetch_issue(issue_ref(issue))
  def refresh_issue(%{} = issue), do: fetch_issue(issue_ref(issue))
  def refresh_issue(_issue), do: {:ok, nil}

  @spec fetch_issue(Issue.t() | issue_ref()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue(%Issue{} = issue), do: fetch_issue(issue_ref(issue))

  def fetch_issue(%{} = ref) do
    case issue_ref(ref) do
      %{source: :manual, id: issue_id} when is_binary(issue_id) ->
        manual_lookup(fn -> ManualIssueStore.fetch_issue_by_id(issue_id) end)

      %{source: :tracker, id: issue_id} when is_binary(issue_id) ->
        tracker_lookup(fn -> Tracker.fetch_issue_by_id(issue_id) end)

      %{id: issue_id} when is_binary(issue_id) ->
        fetch_issue_by_id(issue_id)

      %{canonical_identifier: identifier} when is_binary(identifier) ->
        fetch_issue_by_identifier(identifier)

      %{identifier: identifier} when is_binary(identifier) ->
        fetch_issue_by_identifier(identifier)

      _ ->
        {:ok, nil}
    end
  end

  @spec create_comment(Issue.t() | String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(%Issue{} = issue, body), do: create_comment(issue_ref(issue), body)
  def create_comment(%{} = issue_ref, body), do: create_comment_ref(issue_ref(issue_ref), body)

  def create_comment(issue_id, body)
      when is_binary(issue_id) and is_binary(body) do
    create_comment_ref(%{id: issue_id}, body)
  end

  @spec update_issue_state(Issue.t() | String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(%Issue{} = issue, state_name), do: update_issue_state(issue_ref(issue), state_name)
  def update_issue_state(%{} = issue_ref, state_name), do: update_issue_state_ref(issue_ref(issue_ref), state_name)

  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    update_issue_state_ref(%{id: issue_id}, state_name)
  end

  @spec attach_link(Issue.t() | String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def attach_link(%Issue{} = issue, title, url), do: attach_link(issue_ref(issue), title, url)
  def attach_link(%{} = issue_ref, title, url), do: attach_link_ref(issue_ref(issue_ref), title, url)

  def attach_link(issue_id, title, url)
      when is_binary(issue_id) and is_binary(title) and is_binary(url) do
    attach_link_ref(%{id: issue_id}, title, url)
  end

  @spec issue_ref(Issue.t() | map()) :: issue_ref()
  def issue_ref(%Issue{} = issue) do
    %{
      source: normalize_source(issue.source) || infer_source(issue.id),
      id: issue.id,
      external_id: issue.external_id || issue.id,
      identifier: issue.identifier,
      canonical_identifier: issue.canonical_identifier || issue.identifier
    }
  end

  def issue_ref(%{} = issue) do
    id = Map.get(issue, :id) || Map.get(issue, "id")
    source =
      issue
      |> Map.get(:source)
      |> Kernel.||(Map.get(issue, "source"))
      |> normalize_source()
      |> Kernel.||(infer_source(id))

    %{
      source: source,
      id: id,
      external_id: Map.get(issue, :external_id) || Map.get(issue, "external_id") || id,
      identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      canonical_identifier:
        Map.get(issue, :canonical_identifier) || Map.get(issue, "canonical_identifier") ||
          Map.get(issue, :identifier) || Map.get(issue, "identifier")
    }
  end

  defp tracker_fetch(fun) when is_function(fun, 0) do
    if tracker_enabled?() do
      fun.()
    else
      {:ok, []}
    end
  end

  defp tracker_lookup(fun) when is_function(fun, 0) do
    if tracker_enabled?() do
      fun.()
    else
      {:ok, nil}
    end
  end

  defp manual_fetch(fun) when is_function(fun, 0) do
    if Config.manual_enabled?() do
      fun.()
    else
      {:ok, []}
    end
  end

  defp manual_lookup(fun) when is_function(fun, 0) do
    if Config.manual_enabled?() do
      fun.()
    else
      {:ok, nil}
    end
  end

  defp merge_issue_lists({:ok, tracker_issues}, {:ok, manual_issues}) do
    {:ok, manual_issues ++ tracker_issues}
  end

  defp merge_issue_lists({:error, _reason}, {:ok, manual_issues}) when manual_issues != [] do
    {:ok, manual_issues}
  end

  defp merge_issue_lists({:ok, tracker_issues}, {:error, _reason}) do
    {:ok, tracker_issues}
  end

  defp merge_issue_lists({:error, reason}, {:ok, []}), do: {:error, reason}
  defp merge_issue_lists({:error, reason}, {:error, _other_reason}), do: {:error, reason}

  defp tracker_enabled? do
    case Config.tracker_kind() do
      value when is_binary(value) -> value != ""
      _ -> false
    end
  end

  defp create_comment_ref(%{source: :manual, id: issue_id}, body) when is_binary(issue_id),
    do: ManualIssueStore.create_comment(issue_id, body)

  defp create_comment_ref(%{source: :tracker, id: issue_id}, body) when is_binary(issue_id),
    do: maybe_tracker_mutation(fn -> Tracker.create_comment(issue_id, body) end)

  defp create_comment_ref(%{id: issue_id}, body) when is_binary(issue_id) do
    if ManualIssueSpec.runtime_issue_id?(issue_id),
      do: ManualIssueStore.create_comment(issue_id, body),
      else: maybe_tracker_mutation(fn -> Tracker.create_comment(issue_id, body) end)
  end

  defp update_issue_state_ref(%{source: :manual, id: issue_id}, state_name) when is_binary(issue_id),
    do: ManualIssueStore.update_issue_state(issue_id, state_name)

  defp update_issue_state_ref(%{source: :tracker, id: issue_id}, state_name) when is_binary(issue_id),
    do: maybe_tracker_mutation(fn -> Tracker.update_issue_state(issue_id, state_name) end)

  defp update_issue_state_ref(%{id: issue_id}, state_name) when is_binary(issue_id) do
    if ManualIssueSpec.runtime_issue_id?(issue_id),
      do: ManualIssueStore.update_issue_state(issue_id, state_name),
      else: maybe_tracker_mutation(fn -> Tracker.update_issue_state(issue_id, state_name) end)
  end

  defp attach_link_ref(%{source: :manual, id: issue_id}, title, url) when is_binary(issue_id),
    do: ManualIssueStore.attach_link(issue_id, title, url)

  defp attach_link_ref(%{source: :tracker, id: issue_id}, title, url) when is_binary(issue_id),
    do: maybe_tracker_mutation(fn -> Tracker.attach_link(issue_id, title, url) end)

  defp attach_link_ref(%{id: issue_id}, title, url) when is_binary(issue_id) do
    if ManualIssueSpec.runtime_issue_id?(issue_id),
      do: ManualIssueStore.attach_link(issue_id, title, url),
      else: maybe_tracker_mutation(fn -> Tracker.attach_link(issue_id, title, url) end)
  end

  defp maybe_tracker_mutation(fun) when is_function(fun, 0) do
    pack = PolicyPack.resolve(Config.policy_pack_name())

    cond do
      not PolicyPack.tracker_mutation_allowed?(pack) ->
        {:error, {:tracker_mutation_forbidden, PolicyPack.name_string(pack)}}

      match?({:error, _},
        CredentialRegistry.allow?("tracker", "write",
          policy_pack: pack,
          company_name: Config.company_name(),
          repo_url: Config.company_repo_url()
        )
      ) ->
        CredentialRegistry.allow?("tracker", "write",
          policy_pack: pack,
          company_name: Config.company_name(),
          repo_url: Config.company_repo_url()
        )

      true ->
        fun.()
    end
  end

  defp infer_source(value) when is_binary(value) do
    if ManualIssueSpec.runtime_issue_id?(value), do: :manual, else: :tracker
  end

  defp infer_source(_value), do: nil

  defp normalize_source(:manual), do: :manual
  defp normalize_source(:tracker), do: :tracker
  defp normalize_source("manual"), do: :manual
  defp normalize_source("tracker"), do: :tracker
  defp normalize_source(_value), do: nil
end
