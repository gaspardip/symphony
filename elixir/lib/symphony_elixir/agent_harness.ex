defmodule SymphonyElixir.AgentHarness do
  @moduledoc """
  Repo-tracked self-development harness helpers for Symphony self-host runs.
  """

  alias SymphonyElixir.IssueAcceptance
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepoHarness
  alias YamlElixir

  @required_progress_sections ~w(Goal Acceptance Plan Work\ Log Evidence Next\ Step)
  @code_change_prefixes ["elixir/", "scripts/", "ops/", ".github/"]
  @non_code_prefixes [".symphony/", "docs/"]

  @type check_result :: :ok | {:error, term()}

  @spec enabled?(RepoHarness.t() | nil) :: boolean()
  def enabled?(%RepoHarness{agent_harness: agent_harness}) when is_map(agent_harness), do: true
  def enabled?(_), do: false

  @spec initialize(Path.t(), Issue.t() | map(), RepoHarness.t()) :: {:ok, map()} | {:error, term()}
  def initialize(workspace, issue, %RepoHarness{} = harness) when is_binary(workspace) and is_map(issue) do
    with true <- enabled?(harness) or {:error, :disabled},
         {:ok, config} <- fetch_agent_harness(harness),
         :ok <- ensure_directories(workspace, config),
         :ok <- ensure_knowledge_files(workspace, config),
         {:ok, progress_path} <- ensure_progress_file(workspace, issue, config),
         :ok <- check(workspace, harness) do
      {:ok,
       %{
         progress_path: progress_path,
         harness_status: "initialized",
         last_harness_init: timestamp(),
         harness_attempts: 1
       }}
    end
  end

  @spec check(Path.t(), RepoHarness.t()) :: check_result()
  def check(workspace, %RepoHarness{} = harness) when is_binary(workspace) do
    with {:ok, config} <- fetch_agent_harness(harness),
         :ok <- validate_knowledge_files(workspace, config),
         :ok <- validate_feature_files(workspace, config),
         :ok <- validate_progress_files(workspace, config) do
      :ok
    end
  end

  @spec publish_gate(Path.t(), Issue.t() | map(), RepoHarness.t(), keyword()) :: check_result()
  def publish_gate(workspace, issue, %RepoHarness{} = harness, opts \\ [])
      when is_binary(workspace) and is_map(issue) do
    with {:ok, config} <- fetch_agent_harness(harness),
         :ok <- check(workspace, harness),
         {:ok, progress_rel_path} <- progress_relative_path(issue, config),
         progress_path = Path.join(workspace, progress_rel_path),
         true <- File.exists?(progress_path) or {:error, {:missing_progress_file, progress_rel_path}},
         changed_paths <- Keyword.get(opts, :changed_paths, harness_changed_paths(workspace)),
         :ok <- ensure_progress_update(changed_paths, progress_rel_path, config),
         :ok <- ensure_feature_updates(workspace, issue, changed_paths, config) do
      :ok
    end
  end

  @spec repo_root!(Path.t()) :: Path.t()
  def repo_root!(cwd) when is_binary(cwd) do
    case find_repo_root(cwd) do
      nil -> raise "Unable to locate repo root for harness check from #{cwd}"
      root -> root
    end
  end

  defp fetch_agent_harness(%RepoHarness{agent_harness: agent_harness}) when is_map(agent_harness),
    do: {:ok, agent_harness}

  defp fetch_agent_harness(_harness), do: {:error, :disabled}

  defp ensure_directories(workspace, config) do
    [
      Path.join(workspace, get_in(config, [:knowledge, :root])),
      Path.join(workspace, get_in(config, [:progress, :root])),
      Path.join(workspace, get_in(config, [:features, :root]))
    ]
    |> Enum.each(&File.mkdir_p!/1)

    :ok
  end

  defp ensure_knowledge_files(workspace, config) do
    knowledge_root = Path.join(workspace, get_in(config, [:knowledge, :root]))

    config
    |> get_in([:knowledge, :required_files])
    |> Enum.each(fn file ->
      path = Path.join(knowledge_root, file)

      unless File.exists?(path) do
        File.write!(path, knowledge_template(file))
      end
    end)

    :ok
  end

  defp ensure_progress_file(workspace, issue, config) do
    with {:ok, progress_rel_path} <- progress_relative_path(issue, config) do
      progress_path = Path.join(workspace, progress_rel_path)
      File.mkdir_p!(Path.dirname(progress_path))

      unless File.exists?(progress_path) do
        File.write!(progress_path, progress_template(issue))
      end

      {:ok, progress_path}
    end
  end

  defp validate_knowledge_files(workspace, config) do
    knowledge_root = Path.join(workspace, get_in(config, [:knowledge, :root]))

    Enum.reduce_while(get_in(config, [:knowledge, :required_files]), :ok, fn file, :ok ->
      path = Path.join(knowledge_root, file)

      cond do
        not File.exists?(path) ->
          {:halt, {:error, {:missing_knowledge_file, file}}}

        blank_file?(path) ->
          {:halt, {:error, {:blank_knowledge_file, file}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_feature_files(workspace, config) do
    features_root = Path.join(workspace, get_in(config, [:features, :root]))
    required_fields = get_in(config, [:features, :required_fields])

    case File.ls(features_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, [".yml", ".yaml"]))
        |> Enum.reduce_while(:ok, fn entry, :ok ->
          path = Path.join(features_root, entry)

          case load_feature_yaml(path, required_fields) do
            {:ok, _feature} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:invalid_feature_file, entry, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:feature_dir_unreadable, reason}}
    end
  end

  defp validate_progress_files(workspace, config) do
    progress_root = Path.join(workspace, get_in(config, [:progress, :root]))
    required_sections = get_in(config, [:progress, :required_sections]) || @required_progress_sections

    case File.ls(progress_root) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reduce_while(:ok, fn entry, :ok ->
          path = Path.join(progress_root, entry)

          case validate_progress_file(path, required_sections) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:invalid_progress_file, entry, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:progress_dir_unreadable, reason}}
    end
  end

  defp ensure_progress_update(changed_paths, progress_rel_path, config) do
    if get_in(config, [:publish_gate, :require_progress]) do
      if progress_rel_path in changed_paths do
        :ok
      else
        {:error, {:progress_not_updated, progress_rel_path}}
      end
    else
      :ok
    end
  end

  defp ensure_feature_updates(workspace, issue, changed_paths, config) do
    if get_in(config, [:publish_gate, :require_feature_update_on_code_change]) &&
         code_changes?(changed_paths) do
      features_root = get_in(config, [:features, :root])

      changed_feature_paths =
        changed_paths
        |> Enum.filter(&String.starts_with?(&1, ensure_trailing_slash(features_root)))
        |> Enum.filter(&String.ends_with?(&1, [".yaml", ".yml"]))

      cond do
        changed_feature_paths == [] ->
          {:error, :feature_update_missing}

        true ->
          Enum.reduce_while(changed_feature_paths, :ok, fn rel_path, :ok ->
            full_path = Path.join(workspace, rel_path)
            required_fields = get_in(config, [:features, :required_fields])

            case load_feature_yaml(full_path, required_fields) do
              {:ok, feature} ->
                if normalize_string(feature["last_updated_by_issue"]) == issue_identifier(issue) do
                  {:cont, :ok}
                else
                  {:halt, {:error, {:feature_issue_mismatch, rel_path, feature["last_updated_by_issue"]}}}
                end

              {:error, reason} ->
                {:halt, {:error, {:invalid_feature_file, rel_path, reason}}}
            end
          end)
      end
    else
      :ok
    end
  end

  defp load_feature_yaml(path, required_fields) do
    with {:ok, payload} <- File.read(path),
         {:ok, decoded} <- YamlElixir.read_from_string(payload),
         true <- is_map(decoded) or {:error, :invalid_yaml_root},
         normalized <- normalize_yaml_map(decoded),
         :ok <- ensure_feature_fields(normalized, required_fields) do
      {:ok, normalized}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_yaml_root}
    end
  end

  defp ensure_feature_fields(feature, required_fields) do
    missing =
      required_fields
      |> Enum.reject(fn field ->
        feature
        |> Map.get(field)
        |> normalize_string()
        |> present_value?()
      end)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_fields, missing}}
    end
  end

  defp validate_progress_file(path, required_sections) do
    content = File.read!(path)

    missing =
      required_sections
      |> Enum.reject(&section_present?(content, &1))

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_sections, missing}}
    end
  end

  defp section_present?(content, section) do
    case Regex.run(~r/^##\s+#{Regex.escape(section)}\s*$([\s\S]*?)(?=^##\s+|\z)/m, content) do
      [_, body] -> String.trim(body) != ""
      _ -> false
    end
  end

  defp progress_relative_path(issue, config) do
    pattern = get_in(config, [:progress, :pattern])
    identifier = issue_identifier(issue)

    case normalize_string(identifier) do
      nil -> {:error, :missing_issue_identifier}
      value ->
        path =
          pattern
          |> String.replace("{{ issue.identifier }}", value)
          |> String.replace("{{issue.identifier}}", value)

        {:ok, Path.join(get_in(config, [:progress, :root]), path)}
      end
  end

  defp harness_changed_paths(workspace) do
    case System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(~r/\r?\n/, trim: true)
        |> Enum.flat_map(&expand_status_paths(workspace, &1))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp expand_status_paths(workspace, line) do
    case status_path(line) do
      nil ->
        []

      path ->
        absolute_path = Path.join(workspace, path)

        cond do
          String.ends_with?(path, "/") and File.dir?(absolute_path) ->
            Path.wildcard(Path.join(absolute_path, "**/*"))
            |> Enum.filter(&File.regular?/1)
            |> Enum.map(&Path.relative_to(&1, workspace))

          true ->
            [path]
        end
    end
  end

  defp status_path(line) when is_binary(line) do
    line
    |> String.slice(3..-1//1)
    |> String.split(" -> ")
    |> List.last()
    |> normalize_string()
  end

  defp progress_template(issue) do
    acceptance = IssueAcceptance.from_issue(issue)

    acceptance_lines =
      case acceptance.criteria do
        [] -> ["- " <> acceptance.summary]
        criteria -> Enum.map(criteria, &"- #{&1}")
      end

    [
      "# #{issue_identifier(issue)}: #{Map.get(issue, :title) || Map.get(issue, "title")}",
      "",
      "## Goal",
      normalize_string(Map.get(issue, :title) || Map.get(issue, "title")) || "TBD",
      "",
      "## Acceptance",
      Enum.join(acceptance_lines, "\n"),
      "",
      "## Plan",
      "- Outline the implementation steps here.",
      "",
      "## Work Log",
      "- No work recorded yet.",
      "",
      "## Evidence",
      "- Add validation, proof, and review evidence here.",
      "",
      "## Next Step",
      "Decide the immediate next action for this issue."
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp knowledge_template(file) do
    title =
      file
      |> String.trim_trailing(".md")
      |> String.replace("-", " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)

    """
    # #{title}

    Update this knowledge document with concise, repo-tracked facts that a self-hosting Symphony run should not rediscover from scratch.
    """
  end

  defp code_changes?(changed_paths) do
    Enum.any?(changed_paths, fn path ->
      Enum.any?(@code_change_prefixes, &String.starts_with?(path, &1)) and
        not Enum.any?(@non_code_prefixes, &String.starts_with?(path, &1))
    end)
  end

  defp blank_file?(path) do
    path
    |> File.read!()
    |> String.trim()
    |> Kernel.==("")
  end

  defp find_repo_root(path) do
    current = Path.expand(path)
    harness_path = Path.join(current, RepoHarness.relative_path())
    parent = Path.dirname(current)

    cond do
      File.exists?(harness_path) -> current
      parent != current -> find_repo_root(parent)
      true -> nil
    end
  end

  defp normalize_yaml_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_yaml_value(value)}
    end)
  end

  defp normalize_yaml_value(value) when is_map(value), do: normalize_yaml_map(value)
  defp normalize_yaml_value(value) when is_list(value), do: Enum.map(value, &normalize_yaml_value/1)
  defp normalize_yaml_value(value), do: value

  defp normalize_string(value) do
    value
    |> case do
      nil -> nil
      other -> to_string(other) |> String.trim()
    end
    |> case do
      "" -> nil
      other -> other
    end
  end

  defp issue_identifier(issue) do
    Map.get(issue, :identifier) || Map.get(issue, "identifier")
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp present_value?(nil), do: false
  defp present_value?(""), do: false
  defp present_value?([]), do: false
  defp present_value?(_value), do: true
end
