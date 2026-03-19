defmodule SymphonyElixir.ManualIssueStore do
  @moduledoc """
  File-backed persistence for manual tracker-free issues.
  """

  alias SymphonyElixir.{Config, ManualIssueSpec}
  alias SymphonyElixir.Linear.Issue

  @type record :: %{
          issue: Issue.t(),
          spec: map(),
          comments: [map()],
          links: [map()],
          source_metadata: map(),
          submitted_at: String.t(),
          updated_at: String.t(),
          last_decision_summary: String.t() | nil
        }

  @spec enabled?() :: boolean()
  def enabled? do
    Config.manual_enabled?()
  end

  @spec root() :: Path.t()
  def root do
    Config.manual_store_root()
  end

  @spec submit(map()) :: {:ok, Issue.t()} | {:error, term()}
  def submit(payload) when is_map(payload) do
    with true <- enabled?() or {:error, :manual_intake_disabled},
         {:ok, spec} <- ManualIssueSpec.validate(payload),
         :ok <- ensure_unique(spec),
         %Issue{} = issue <- ManualIssueSpec.to_issue(spec),
         :ok <- write_record(issue.id, build_record(spec, issue)) do
      {:ok, issue}
    end
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]}
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.linear_active_states())
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_issues_by_states(states) when is_list(states) do
    normalized_states =
      states
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     list_issues()
     |> Enum.filter(fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)
    {:ok, Enum.filter(list_issues(), &MapSet.member?(wanted_ids, &1.id))}
  end

  @spec fetch_issue_by_id(String.t()) :: {:ok, Issue.t() | nil}
  def fetch_issue_by_id(issue_id) when is_binary(issue_id) do
    {:ok,
     Enum.find(list_issues(), fn
       %Issue{id: ^issue_id} -> true
       _ -> false
     end)}
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t() | nil}
  def fetch_issue_by_identifier(issue_identifier) when is_binary(issue_identifier) do
    {:ok,
     Enum.find(list_issues(), fn
       %Issue{identifier: ^issue_identifier} -> true
       _ -> false
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    update_record(issue_id, fn record ->
      now = timestamp()

      record
      |> Map.update(:comments, [%{body: body, at: now}], fn comments ->
        comments ++ [%{body: body, at: now}]
      end)
      |> put_issue_updated_at(now)
      |> Map.put(:updated_at, now)
      |> Map.put(:last_decision_summary, summarize_text(body))
    end)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    update_record(issue_id, fn record ->
      now = timestamp()

      record
      |> update_issue(fn issue -> %{issue | state: state_name, updated_at: parse_timestamp!(now)} end)
      |> Map.put(:updated_at, now)
      |> Map.put(:last_decision_summary, "Moved to #{state_name}")
    end)
  end

  @spec attach_link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def attach_link(issue_id, title, url)
      when is_binary(issue_id) and is_binary(title) and is_binary(url) do
    update_record(issue_id, fn record ->
      now = timestamp()

      record
      |> Map.update(:links, [%{title: title, url: url, at: now}], fn links ->
        links ++ [%{title: title, url: url, at: now}]
      end)
      |> put_issue_updated_at(now)
      |> Map.put(:updated_at, now)
      |> Map.put(:last_decision_summary, "Attached #{title}")
    end)
  end

  @spec load_record_by_identifier(String.t()) :: {:ok, record() | nil}
  def load_record_by_identifier(issue_identifier) when is_binary(issue_identifier) do
    {:ok,
     Enum.find(list_records(), fn record ->
       case Map.get(record, :issue) do
         %Issue{identifier: ^issue_identifier} -> true
         _ -> false
       end
     end)}
  end

  @spec list_records() :: [record()]
  def list_records do
    root()
    |> record_files()
    |> Enum.map(&read_record/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec list_issues() :: [Issue.t()]
  def list_issues do
    list_records()
    |> Enum.map(&Map.get(&1, :issue))
    |> Enum.filter(&match?(%Issue{}, &1))
  end

  defp ensure_unique(spec) do
    runtime_id = ManualIssueSpec.runtime_issue_id(Map.fetch!(spec, :id))
    identifier = Map.fetch!(spec, :identifier)

    if Enum.any?(list_records(), fn record ->
         issue = Map.get(record, :issue)
         match?(%Issue{id: ^runtime_id}, issue) or match?(%Issue{identifier: ^identifier}, issue)
       end) do
      {:error, :duplicate_manual_issue}
    else
      :ok
    end
  end

  defp build_record(spec, %Issue{} = issue) do
    now = timestamp()

    %{
      issue: issue,
      spec: spec,
      comments: [],
      links: [],
      source_metadata: %{
        "source" => "manual",
        "runtime_issue_id" => issue.id,
        "submitted_via" => "manual"
      },
      submitted_at: now,
      updated_at: now,
      last_decision_summary: nil
    }
  end

  defp update_record(issue_id, updater) when is_binary(issue_id) and is_function(updater, 1) do
    with {:ok, %{} = record} <- load_record(issue_id),
         updated_record <- updater.(record),
         :ok <- write_record(issue_id, updated_record) do
      :ok
    end
  end

  defp load_record(issue_id) when is_binary(issue_id) do
    path = record_path(issue_id)

    with true <- File.exists?(path) or {:error, :missing},
         {:ok, payload} <- File.read(path),
         true <- String.trim(payload) != "" or {:error, :missing},
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, record} <- decode_record(decoded) do
      {:ok, record}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :missing}
    end
  end

  defp write_record(issue_id, record) when is_binary(issue_id) and is_map(record) do
    path = record_path(issue_id)
    :ok = File.mkdir_p(Path.dirname(path))
    atomic_write(path, Jason.encode!(encode_record(record)))
  end

  defp record_path(issue_id) when is_binary(issue_id) do
    Path.join(root(), Base.url_encode64(issue_id, padding: false) <> ".json")
  end

  defp record_files(root_path) when is_binary(root_path) do
    if File.dir?(root_path) do
      Path.wildcard(Path.join(root_path, "*.json"))
    else
      []
    end
  end

  defp read_record(path) when is_binary(path) do
    with {:ok, payload} <- File.read(path),
         true <- String.trim(payload) != "" or {:error, :missing},
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, record} <- decode_record(decoded) do
      record
    else
      _ -> nil
    end
  end

  defp decode_record(%{"issue" => issue_payload} = record) when is_map(issue_payload) do
    {:ok,
     %{
       issue: decode_issue(issue_payload),
       spec: map_value(record, "spec", %{}),
       comments: list_value(record, "comments"),
       links: list_value(record, "links"),
       source_metadata: map_value(record, "source_metadata", %{}),
       submitted_at: Map.get(record, "submitted_at"),
       updated_at: Map.get(record, "updated_at"),
       last_decision_summary: Map.get(record, "last_decision_summary")
     }}
  end

  defp decode_record(_record), do: {:error, :invalid_manual_issue_record}

  defp encode_record(record) when is_map(record) do
    %{
      "issue" => encode_issue(Map.get(record, :issue)),
      "spec" => Map.get(record, :spec, %{}),
      "comments" => Map.get(record, :comments, []),
      "links" => Map.get(record, :links, []),
      "source_metadata" => Map.get(record, :source_metadata, %{}),
      "submitted_at" => Map.get(record, :submitted_at),
      "updated_at" => Map.get(record, :updated_at),
      "last_decision_summary" => Map.get(record, :last_decision_summary)
    }
  end

  defp decode_issue(payload) when is_map(payload) do
    %Issue{
      id: Map.get(payload, "id"),
      external_id: Map.get(payload, "external_id"),
      canonical_identifier: Map.get(payload, "canonical_identifier"),
      identifier: Map.get(payload, "identifier"),
      title: Map.get(payload, "title"),
      description: Map.get(payload, "description"),
      priority: Map.get(payload, "priority"),
      state: Map.get(payload, "state"),
      branch_name: Map.get(payload, "branch_name"),
      url: Map.get(payload, "url"),
      internal_identifier: Map.get(payload, "internal_identifier"),
      internal_url: Map.get(payload, "internal_url"),
      assignee_id: Map.get(payload, "assignee_id"),
      source: decode_source(Map.get(payload, "source")),
      blocked_by: Map.get(payload, "blocked_by", []),
      labels: Map.get(payload, "labels", []),
      assigned_to_worker: Map.get(payload, "assigned_to_worker", true),
      created_at: parse_timestamp(Map.get(payload, "created_at")),
      updated_at: parse_timestamp(Map.get(payload, "updated_at"))
    }
  end

  defp encode_issue(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "external_id" => issue.external_id,
      "canonical_identifier" => issue.canonical_identifier,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "priority" => issue.priority,
      "state" => issue.state,
      "branch_name" => issue.branch_name,
      "url" => issue.url,
      "internal_identifier" => issue.internal_identifier,
      "internal_url" => issue.internal_url,
      "assignee_id" => issue.assignee_id,
      "source" => encode_source(issue.source),
      "blocked_by" => issue.blocked_by,
      "labels" => issue.labels,
      "assigned_to_worker" => issue.assigned_to_worker,
      "created_at" => datetime_to_iso8601(issue.created_at),
      "updated_at" => datetime_to_iso8601(issue.updated_at)
    }
  end

  defp encode_issue(_value), do: %{}

  defp update_issue(record, fun) when is_map(record) and is_function(fun, 1) do
    Map.update!(record, :issue, fn
      %Issue{} = issue -> fun.(issue)
      other -> other
    end)
  end

  defp put_issue_updated_at(record, now) when is_map(record) do
    update_issue(record, fn issue -> %{issue | updated_at: parse_timestamp!(now)} end)
  end

  defp decode_source("manual"), do: :manual
  defp decode_source("tracker"), do: :tracker
  defp decode_source(:manual), do: :manual
  defp decode_source(:tracker), do: :tracker
  defp decode_source(_value), do: :manual

  defp encode_source(:manual), do: "manual"
  defp encode_source(:tracker), do: "tracker"
  defp encode_source(value) when is_binary(value), do: value
  defp encode_source(_value), do: "manual"

  defp map_value(record, key, default) do
    case Map.get(record, key) do
      value when is_map(value) -> value
      _ -> default
    end
  end

  defp list_value(record, key) do
    case Map.get(record, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_timestamp(_value), do: nil

  defp parse_timestamp!(value) when is_binary(value) do
    case parse_timestamp(value) do
      %DateTime{} = datetime -> datetime
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp datetime_to_iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp datetime_to_iso8601(_datetime), do: nil

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp summarize_text(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> List.first()
    |> case do
      nil -> nil
      line -> String.slice(String.trim(line), 0, 200)
    end
  end

  defp summarize_text(_text), do: nil

  defp normalize_state(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp atomic_write(path, payload) when is_binary(path) and is_binary(payload) do
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, payload, [:write]),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end
end
