defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @query_by_identifier """
  query SymphonyLinearIssueByIdentifier($projectSlug: String!, $teamKey: String!, $number: Float!, $relationFirst: Int!) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, team: {key: {eq: $teamKey}}, number: {eq: $number}}, first: 1) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    project_slug = Config.linear_project_slug()

    cond do
      is_nil(Config.linear_api_token()) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          state_names = Config.linear_active_states()
          assignee_desc = format_assignee_filter(assignee_filter)

          Logger.info("[dispatch] query project_slug=#{project_slug} states=#{inspect(state_names)} assignee=#{assignee_desc}")

          case do_fetch_by_states(project_slug, state_names, assignee_filter) do
            {:ok, issues} = result ->
              if issues == [] do
                Logger.warning("[dispatch] 0 candidates returned — project_slug=#{project_slug} states=#{inspect(state_names)} assignee=#{assignee_desc}")
              else
                Logger.info("[dispatch] query returned #{length(issues)} candidate(s)")
              end

              result

            error ->
              error
          end
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      project_slug = Config.linear_project_slug()

      cond do
        is_nil(Config.linear_api_token()) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_identifier(issue_identifier) when is_binary(issue_identifier) do
    identifier = String.trim(issue_identifier)
    project_slug = Config.linear_project_slug()

    cond do
      identifier == "" ->
        {:ok, nil}

      is_nil(Config.linear_api_token()) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, team_key, issue_number} <- parse_issue_identifier(identifier),
             {:ok, body} <-
               graphql(@query_by_identifier, %{
                 projectSlug: project_slug,
                 teamKey: team_key,
                 number: issue_number,
                 relationFirst: @issue_page_size
               }),
             {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          {:ok, List.first(issues)}
        end
    end
  end

  @spec fetch_issue_by_id(String.t()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_id(issue_id) when is_binary(issue_id) do
    trimmed_id = String.trim(issue_id)

    cond do
      trimmed_id == "" ->
        {:ok, nil}

      is_nil(Config.linear_api_token()) ->
        {:error, :missing_linear_api_token}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, issues} <- do_fetch_issue_states([trimmed_id], assignee_filter) do
          {:ok, List.first(issues)}
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status, %{retry_after_ms: retry_after_ms(response), body: Map.get(response, :body)}}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec helper_for_test(atom(), list()) :: term()
  def helper_for_test(:build_assignee_filter, [assignee]), do: build_assignee_filter(assignee)
  def helper_for_test(:assigned_to_worker, [assignee, assignee_filter]), do: assigned_to_worker?(assignee, assignee_filter)
  def helper_for_test(:truncate_error_body, [body]), do: truncate_error_body(body)
  def helper_for_test(:normalize_assignee_match_value, [value]), do: normalize_assignee_match_value(value)
  def helper_for_test(:graphql_headers, []), do: graphql_headers()
  def helper_for_test(:routing_assignee_filter, []), do: routing_assignee_filter()

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    case graphql(@query_by_ids, %{
           ids: ids,
           first: Enum.min([length(ids), @issue_page_size]),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        decode_linear_response(body, assignee_filter)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_issue_identifier(identifier) when is_binary(identifier) do
    case Regex.run(~r/^([A-Za-z][A-Za-z0-9_]*)-(\d+)$/, identifier) do
      [_, team_key, issue_number] ->
        {:ok, String.upcase(team_key), String.to_integer(issue_number) * 1.0}

      _ ->
        {:error, :invalid_linear_issue_identifier}
    end
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.linear_api_token() do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.linear_endpoint(),
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    if rate_limited_errors?(errors) do
      {:error, {:linear_rate_limited, %{errors: errors}}}
    else
      {:error, {:linear_graphql_errors, errors}}
    end
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      external_id: issue["id"],
      canonical_identifier: issue["identifier"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      source: :tracker,
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.tracker_handoff_mode() do
      "labels" ->
        {:ok, nil}

      _ ->
        routing_assignee_filter_from_config()
    end
  end

  defp routing_assignee_filter_from_config do
    case Config.linear_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil

  defp retry_after_ms(%{headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "retry-after" do
          case Integer.parse(String.trim(value)) do
            {seconds, ""} when seconds >= 0 -> seconds * 1_000
            _ -> nil
          end
        end

      _ ->
        nil
    end)
  end

  defp retry_after_ms(_response), do: nil

  defp rate_limited_errors?(errors) when is_list(errors) do
    Enum.any?(errors, fn
      %{"extensions" => %{"code" => code}} when is_binary(code) ->
        String.upcase(String.trim(code)) == "RATELIMITED"

      %{"message" => message} when is_binary(message) ->
        message
        |> String.downcase()
        |> String.contains?("rate limit")

      _ ->
        false
    end)
  end

  defp rate_limited_errors?(_errors), do: false

  defp format_assignee_filter(nil), do: "any"
  defp format_assignee_filter(%{configured_assignee: assignee}), do: inspect(assignee)
  defp format_assignee_filter(_), do: "unknown"
end
