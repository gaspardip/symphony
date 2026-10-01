defmodule SymphonyElixir.IssueSource do
  @moduledoc """
  Source-aware issue reads and writes across tracker-backed and manual issues.
  """

  alias SymphonyElixir.{Config, CredentialRegistry, ManualIssueSpec, ManualIssueStore, Observability, PolicyPack, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Config.TrackerReadContext

  @type issue_ref :: %{
          required(:source) => :manual | :tracker | nil,
          optional(:id) => String.t() | nil,
          optional(:external_id) => String.t() | nil,
          optional(:identifier) => String.t() | nil,
          optional(:canonical_identifier) => String.t() | nil
        }

  @type read_outcomes :: %{
          tracker: {:ok, [Issue.t()]} | {:error, term()} | :disabled,
          manual: {:ok, [Issue.t()]} | {:error, term()}
        }

  @type checked_outcome ::
          {:issue, :manual | :tracker, Issue.t()}
          | {:missing, :manual | :tracker}
          | {:disabled, :manual | :tracker}
          | {:read_error, :manual | :tracker, term()}
          | {:rate_limited, term()}
          | {:invalid, :reference | :issue | :response, term()}

  @spec fetch_candidate_outcomes(TrackerReadContext.t()) :: read_outcomes()
  def fetch_candidate_outcomes(%TrackerReadContext{} = context) do
    %{
      tracker: tracker_outcome(context, fn -> Tracker.fetch_candidate_issues(context) end),
      manual: fetch_manual_candidate_issues(context)
    }
  end

  @spec fetch_issues_by_states_outcomes([String.t()], TrackerReadContext.t()) :: read_outcomes()
  def fetch_issues_by_states_outcomes(states, %TrackerReadContext{} = context) when is_list(states) do
    %{
      tracker: tracker_outcome(context, fn -> Tracker.fetch_issues_by_states(states, context) end),
      manual: fetch_manual_issues_by_states(states, context)
    }
  end

  @spec fetch_issue_states_by_ids_outcomes([String.t()], TrackerReadContext.t()) :: read_outcomes()
  def fetch_issue_states_by_ids_outcomes(issue_ids, %TrackerReadContext{} = context) when is_list(issue_ids) do
    {manual_ids, tracker_ids} = Enum.split_with(issue_ids, &ManualIssueSpec.runtime_issue_id?/1)
    manual = manual_fetch(context, fn -> ManualIssueStore.fetch_issue_states_by_ids(manual_ids, context.manual_store_root) end)
    tracker = tracker_outcome(context, fn -> Tracker.fetch_issue_states_by_ids(tracker_ids, context) end)
    %{tracker: tracker, manual: manual}
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: fetch_candidate_issues(Config.tracker_read_context())

  @spec fetch_candidate_issues(TrackerReadContext.t()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(%TrackerReadContext{} = context) do
    merge_issue_lists(
      tracker_fetch(context, fn -> Tracker.fetch_candidate_issues(context) end),
      fetch_manual_candidate_issues(context)
    )
  end

  @spec fetch_manual_candidate_issues() :: {:ok, [Issue.t()]}
  def fetch_manual_candidate_issues, do: fetch_manual_candidate_issues(Config.tracker_read_context())

  @spec fetch_manual_candidate_issues(TrackerReadContext.t()) :: {:ok, [Issue.t()]}
  def fetch_manual_candidate_issues(%TrackerReadContext{} = context) do
    manual_fetch(context, fn -> ManualIssueStore.fetch_issues_by_states(context.linear_active_states, context.manual_store_root) end)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states), do: fetch_issues_by_states(states, Config.tracker_read_context())

  @spec fetch_issues_by_states([String.t()], TrackerReadContext.t()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states, %TrackerReadContext{} = context) when is_list(states) do
    merge_issue_lists(
      tracker_fetch(context, fn -> Tracker.fetch_issues_by_states(states, context) end),
      fetch_manual_issues_by_states(states, context)
    )
  end

  @spec fetch_manual_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_manual_issues_by_states(states) when is_list(states), do: fetch_manual_issues_by_states(states, Config.tracker_read_context())

  @spec fetch_manual_issues_by_states([String.t()], TrackerReadContext.t()) :: {:ok, [Issue.t()]}
  def fetch_manual_issues_by_states(states, %TrackerReadContext{} = context) when is_list(states) do
    manual_fetch(context, fn -> ManualIssueStore.fetch_issues_by_states(states, context.manual_store_root) end)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids), do: fetch_issue_states_by_ids(issue_ids, Config.tracker_read_context())

  @spec fetch_issue_states_by_ids([String.t()], TrackerReadContext.t()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, %TrackerReadContext{} = context) when is_list(issue_ids) do
    {manual_ids, tracker_ids} = Enum.split_with(issue_ids, &ManualIssueSpec.runtime_issue_id?/1)

    with {:ok, manual_issues} <- manual_fetch(context, fn -> ManualIssueStore.fetch_issue_states_by_ids(manual_ids, context.manual_store_root) end),
         {:ok, tracker_issues} <- tracker_fetch(context, fn -> Tracker.fetch_issue_states_by_ids(tracker_ids, context) end) do
      {:ok, manual_issues ++ tracker_issues}
    end
  end

  @spec fetch_manual_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_manual_issue_states_by_ids(issue_ids) when is_list(issue_ids),
    do: fetch_manual_issue_states_by_ids(issue_ids, Config.tracker_read_context())

  @spec fetch_manual_issue_states_by_ids([String.t()], TrackerReadContext.t()) :: {:ok, [Issue.t()]}
  def fetch_manual_issue_states_by_ids(issue_ids, %TrackerReadContext{} = context) when is_list(issue_ids) do
    issue_ids
    |> Enum.filter(&ManualIssueSpec.runtime_issue_id?/1)
    |> ManualIssueStore.fetch_issue_states_by_ids(context.manual_store_root)
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier) when is_binary(issue_identifier),
    do: fetch_issue_by_identifier(issue_identifier, Config.tracker_read_context())

  @spec fetch_issue_by_identifier(String.t(), TrackerReadContext.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier, %TrackerReadContext{} = context) when is_binary(issue_identifier) do
    case manual_lookup(context, fn -> ManualIssueStore.fetch_issue_by_identifier(issue_identifier, context.manual_store_root) end) do
      {:ok, %Issue{} = issue} ->
        {:ok, issue}

      {:ok, nil} ->
        tracker_lookup(context, fn -> Tracker.fetch_issue_by_identifier(issue_identifier, context) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Resolves an exact identifier on one explicit source without fallback or a fabricated id."
  @spec fetch_issue_by_identifier_checked(term(), term(), TrackerReadContext.t()) :: {:ok, checked_outcome()}
  def fetch_issue_by_identifier_checked(identifier, source, %TrackerReadContext{} = context) do
    cond do
      not is_binary(identifier) or identifier == "" ->
        {:ok, {:invalid, :reference, {:invalid_issue_ref, :identifier}}}

      source not in [:manual, :tracker] ->
        {:ok, {:invalid, :reference, {:invalid_issue_ref, :source}}}

      source == :manual and not context.manual_enabled ->
        {:ok, {:disabled, :manual}}

      source == :tracker and not tracker_enabled?(context) ->
        {:ok, {:disabled, :tracker}}

      true ->
        outcome =
          observe_checked_outcome(source, "lookup_by_identifier", fn ->
            source
            |> read_checked_identifier(identifier, context)
            |> checked_identifier_result(source, identifier)
          end)

        {:ok, outcome}
    end
  end

  @spec fetch_issue_by_id(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id) when is_binary(issue_id), do: fetch_issue_by_id(issue_id, Config.tracker_read_context())

  @spec fetch_issue_by_id(String.t(), TrackerReadContext.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id, %TrackerReadContext{} = context) when is_binary(issue_id) do
    if ManualIssueSpec.runtime_issue_id?(issue_id) do
      manual_lookup(context, fn -> ManualIssueStore.fetch_issue_by_id(issue_id, context.manual_store_root) end)
    else
      tracker_lookup(context, fn -> Tracker.fetch_issue_by_id(issue_id, context) end)
    end
  end

  @spec refresh_issue(Issue.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def refresh_issue(%Issue{} = issue), do: refresh_issue(issue, Config.tracker_read_context())
  def refresh_issue(%{} = issue), do: refresh_issue(issue, Config.tracker_read_context())
  def refresh_issue(_issue), do: {:ok, nil}

  @spec refresh_issue(Issue.t() | map(), TrackerReadContext.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def refresh_issue(%{} = issue, %TrackerReadContext{} = context), do: fetch_issue(issue_ref(issue), context)
  def refresh_issue(_issue, %TrackerReadContext{}), do: {:ok, nil}

  @spec fetch_issue(Issue.t() | issue_ref()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue(%{} = ref), do: fetch_issue(ref, Config.tracker_read_context())

  @spec fetch_issue(Issue.t() | issue_ref(), TrackerReadContext.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue(%{} = ref, %TrackerReadContext{} = context) do
    case issue_ref(ref) do
      %{source: :manual, id: issue_id} when is_binary(issue_id) ->
        manual_lookup(context, fn -> ManualIssueStore.fetch_issue_by_id(issue_id, context.manual_store_root) end)

      %{source: :tracker, id: issue_id} when is_binary(issue_id) ->
        tracker_lookup(context, fn -> Tracker.fetch_issue_by_id(issue_id, context) end)

      %{id: issue_id} when is_binary(issue_id) ->
        fetch_issue_by_id(issue_id, context)

      %{canonical_identifier: identifier} when is_binary(identifier) ->
        fetch_issue_by_identifier(identifier, context)

      %{identifier: identifier} when is_binary(identifier) ->
        fetch_issue_by_identifier(identifier, context)

      _ ->
        {:ok, nil}
    end
  end

  @doc "Reads a captured reference without conflating semantic outcomes with reader failures."
  @spec fetch_issue_checked(term(), TrackerReadContext.t()) :: {:ok, checked_outcome()}
  def fetch_issue_checked(ref, %TrackerReadContext{} = context) do
    case checked_reference(ref) do
      {:ok, source, id, identifier} ->
        enabled = if source == :manual, do: context.manual_enabled, else: tracker_enabled?(context)

        if enabled do
          outcome =
            observe_checked_lookup(source, id, identifier, fn ->
              read_checked_source(source, id, context)
            end)

          {:ok, outcome}
        else
          {:ok, {:disabled, source}}
        end

      {:error, reason} ->
        {:ok, {:invalid, :reference, reason}}
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

  defp checked_reference(%{} = ref) do
    id = Map.get(ref, :id)
    identifier = Map.get(ref, :identifier)
    source = Map.get(ref, :source)

    cond do
      not is_binary(id) or id == "" ->
        {:error, {:invalid_issue_ref, :id}}

      not is_binary(identifier) or identifier == "" ->
        {:error, {:invalid_issue_ref, :identifier}}

      not Map.has_key?(ref, :source) or source not in [nil, :manual, :tracker, "manual", "tracker"] ->
        {:error, {:invalid_issue_ref, :source}}

      true ->
        route = if is_nil(source), do: infer_source(id), else: normalize_source(source)
        {:ok, route, id, identifier}
    end
  end

  defp checked_reference(_ref), do: {:error, {:invalid_issue_ref, :id}}

  defp read_checked_source(:manual, id, context),
    do: ManualIssueStore.fetch_issue_by_id_checked(id, context.manual_store_root)

  defp read_checked_source(:tracker, id, %TrackerReadContext{tracker_kind: "memory"}),
    do: SymphonyElixir.Tracker.Memory.fetch_issue_by_id(id)

  defp read_checked_source(:tracker, id, %TrackerReadContext{linear_client_module: SymphonyElixir.Linear.Client} = context),
    do: SymphonyElixir.Linear.Client.fetch_issue_by_id(id, context)

  defp read_checked_source(:tracker, id, %TrackerReadContext{linear_client_module: client}),
    do: client.fetch_issue_by_id(id)

  defp read_checked_identifier(:manual, identifier, context),
    do: ManualIssueStore.fetch_issue_by_identifier_checked(identifier, context.manual_store_root)

  defp read_checked_identifier(:tracker, identifier, %TrackerReadContext{tracker_kind: "memory"}),
    do: SymphonyElixir.Tracker.Memory.fetch_issue_by_identifier(identifier)

  defp read_checked_identifier(:tracker, identifier, %TrackerReadContext{linear_client_module: SymphonyElixir.Linear.Client} = context),
    do: SymphonyElixir.Linear.Client.fetch_issue_by_identifier(identifier, context)

  defp read_checked_identifier(:tracker, identifier, %TrackerReadContext{linear_client_module: client}),
    do: client.fetch_issue_by_identifier(identifier)

  defp checked_identifier_result({:ok, %Issue{} = issue} = result, source, identifier) do
    if is_binary(issue.id) and issue.id != "",
      do: checked_source_result(result, source, issue.id, identifier),
      else: checked_identity_error(source, :id)
  end

  defp checked_identifier_result(result, source, _identifier),
    do: checked_non_issue_result(result, source)

  defp checked_source_result({:ok, %Issue{} = issue}, source, id, identifier) do
    cond do
      issue.id != id -> checked_identity_error(source, :id)
      issue.identifier != identifier -> checked_identity_error(source, :identifier)
      not checked_issue_source?(source, issue.source) -> checked_identity_error(source, :source)
      true -> {:issue, source, issue}
    end
  end

  defp checked_source_result(result, source, _id, _identifier), do: checked_non_issue_result(result, source)

  defp checked_non_issue_result({:ok, nil}, source), do: {:missing, source}

  defp checked_non_issue_result({:error, {:linear_rate_limited, metadata} = reason}, :tracker),
    do: checked_rate_limit(reason, metadata)

  defp checked_non_issue_result({:error, {:linear_api_status, 429, metadata} = reason}, :tracker),
    do: checked_rate_limit(reason, metadata)

  defp checked_non_issue_result({:error, reason}, source), do: {:read_error, source, reason}
  defp checked_non_issue_result({:ok, _value}, _source), do: {:invalid, :issue, :invalid_issue}
  defp checked_non_issue_result(_result, _source), do: {:invalid, :response, :invalid_source_result}

  defp checked_issue_source?(:manual, :manual), do: true
  defp checked_issue_source?(:tracker, source) when source in [nil, :tracker], do: true
  defp checked_issue_source?(_route, _source), do: false

  defp checked_identity_error(:manual, field), do: {:read_error, :manual, {:manual_issue_identity_mismatch, field}}
  defp checked_identity_error(:tracker, field), do: {:invalid, :issue, {:issue_identity_mismatch, field}}

  defp checked_rate_limit(reason, metadata) when is_map(metadata), do: {:rate_limited, reason}
  defp checked_rate_limit(_reason, _metadata), do: {:invalid, :response, :invalid_rate_limit_metadata}

  @spec observe_checked_lookup(:manual | :tracker, String.t(), String.t(), (-> term())) :: checked_outcome()
  defp observe_checked_lookup(source, id, identifier, fun) do
    observe_checked_outcome(source, "lookup", fn -> checked_source_result(fun.(), source, id, identifier) end)
  end

  defp observe_checked_outcome(source, operation, fun) do
    metadata = %{source: Atom.to_string(source), operation: operation}
    start_time = System.monotonic_time()
    Observability.emit([:symphony, :issue_source, :start], %{count: 1}, metadata)
    outcome = fun.()

    label =
      case outcome do
        {:issue, _, _} -> "ok"
        {:missing, _} -> "missing"
        {:read_error, _, _} -> "error"
        {:rate_limited, _} -> "rate_limited"
        {:invalid, _, _} -> "invalid"
      end

    Observability.emit(
      [:symphony, :issue_source, :stop],
      %{count: 1, duration: System.monotonic_time() - start_time},
      Map.put(metadata, :outcome, label)
    )

    outcome
  end

  defp tracker_outcome(context, fun) when is_function(fun, 0) do
    if tracker_enabled?(context) do
      observe_source_operation(:tracker, :fetch, fun)
    else
      :disabled
    end
  end

  defp tracker_fetch(context, fun) when is_function(fun, 0) do
    if tracker_enabled?(context) do
      observe_source_operation(:tracker, :fetch, fun)
    else
      {:ok, []}
    end
  end

  defp tracker_lookup(context, fun) when is_function(fun, 0) do
    if tracker_enabled?(context) do
      observe_source_operation(:tracker, :lookup, fun)
    else
      {:ok, nil}
    end
  end

  defp manual_fetch(context, fun) when is_function(fun, 0) do
    if context.manual_enabled do
      observe_source_operation(:manual, :fetch, fun)
    else
      {:ok, []}
    end
  end

  defp manual_lookup(context, fun) when is_function(fun, 0) do
    if context.manual_enabled do
      observe_source_operation(:manual, :lookup, fun)
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

  defp merge_issue_lists({:error, reason}, {:ok, []}), do: {:error, reason}

  defp tracker_enabled?(%TrackerReadContext{tracker_kind: kind}) do
    is_binary(kind) and kind != ""
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

      match?(
        {:error, _},
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
        observe_source_operation(:tracker, :mutation, fun)
    end
  end

  defp observe_source_operation(source, operation, fun)
       when source in [:manual, :tracker] and is_atom(operation) and is_function(fun, 0) do
    metadata = %{source: Atom.to_string(source), operation: Atom.to_string(operation)}
    start_time = System.monotonic_time()

    Observability.emit([:symphony, :issue_source, :start], %{count: 1}, metadata)
    result = fun.()

    outcome =
      case result do
        {:ok, _value} -> "ok"
        :ok -> "ok"
        {:error, _reason} -> "error"
      end

    Observability.emit(
      [:symphony, :issue_source, :stop],
      %{count: 1, duration: System.monotonic_time() - start_time},
      Map.put(metadata, :outcome, outcome)
    )

    result
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
