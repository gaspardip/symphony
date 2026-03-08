defmodule SymphonyElixir.RepoHarness do
  @moduledoc """
  Loads and validates the repo-side execution contract from `.symphony/harness.yml`.
  """

  alias SymphonyElixir.RunnerRuntime

  @relative_path Path.join(".symphony", "harness.yml")
  @supported_version 1
  @top_level_keys ~w(
    version
    base_branch
    preflight
    validation
    smoke
    post_merge
    artifacts
    project
    runtime
    ci
    pull_request
  )
  @stage_keys ~w(description command outputs success)
  @outputs_keys ~w(format)
  @success_keys ~w(exit_code)
  @project_keys ~w(type xcodeproj scheme)
  @ci_keys ~w(provider workflow env required_checks)
  @pull_request_keys ~w(required_checks template review_ready merge_safe)
  @boolean_rule_groups ~w(all)
  @rule_item_keys ~w(checkbox github_check)

  defstruct [
    :path,
    :version,
    :base_branch,
    :preflight_command,
    :validation_command,
    :smoke_command,
    :post_merge_command,
    :artifacts_command,
    :project,
    :runtime,
    :ci,
    :pull_request,
    :raw,
    required_checks: [],
    publish_required_checks: [],
    ci_required_checks: []
  ]

  @type t :: %__MODULE__{
          path: Path.t(),
          version: pos_integer(),
          base_branch: String.t(),
          preflight_command: String.t(),
          validation_command: String.t(),
          smoke_command: String.t(),
          post_merge_command: String.t(),
          artifacts_command: String.t(),
          project: map(),
          runtime: map(),
          ci: map(),
          pull_request: map(),
          raw: map(),
          required_checks: [String.t()],
          publish_required_checks: [String.t()],
          ci_required_checks: [String.t()]
        }

  @spec relative_path() :: String.t()
  def relative_path, do: @relative_path

  @spec harness_file_path(Path.t()) :: Path.t()
  def harness_file_path(workspace) when is_binary(workspace) do
    Path.join(workspace, @relative_path)
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(workspace) when is_binary(workspace) do
    path = harness_file_path(workspace)

    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- YamlElixir.read_from_string(content),
         true <- is_map(decoded) or {:error, :invalid_harness_root},
         {:ok, normalized} <- validate(decoded) do
      {:ok, build_harness(path, normalized)}
    else
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(decoded) when is_map(decoded) do
    config = stringify_keys(decoded)

    with :ok <- ensure_allowed_keys(config, @top_level_keys, []),
         {:ok, version} <- validate_version(config),
         {:ok, base_branch} <- validate_base_branch(config),
         {:ok, preflight} <- validate_stage(config, "preflight", true),
         {:ok, validation} <- validate_stage(config, "validation", true),
         {:ok, smoke} <- validate_stage(config, "smoke", true),
         {:ok, post_merge} <- validate_stage(config, "post_merge", true),
         {:ok, artifacts} <- validate_stage(config, "artifacts", true),
         {:ok, project} <- validate_project(Map.get(config, "project")),
         {:ok, runtime} <- validate_runtime(Map.get(config, "runtime")),
         {:ok, ci} <- validate_ci(Map.get(config, "ci")),
         {:ok, pull_request} <- validate_pull_request(Map.get(config, "pull_request")),
         :ok <- require_publish_required_checks(pull_request) do
      {:ok,
       %{
         version: version,
         base_branch: base_branch,
         preflight: preflight,
         validation: validation,
         smoke: smoke,
         post_merge: post_merge,
         artifacts: artifacts,
         project: project,
         runtime: runtime,
         ci: ci,
         pull_request: pull_request
       }}
    end
  end

  def validate(_decoded), do: {:error, :invalid_harness_root}

  @spec validate_runner_checkout([String.t()], Path.t()) :: :ok | {:error, term()}
  def validate_runner_checkout(required_labels, checkout_root \\ RunnerRuntime.current_checkout_root())
      when is_list(required_labels) and is_binary(checkout_root) do
    if requires_dogfood_harness_validation?(required_labels) do
      case load(checkout_root) do
        {:ok, _harness} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp build_harness(path, normalized) do
    pull_request_checks = get_in(normalized, [:pull_request, :required_checks]) || []
    ci_checks = get_in(normalized, [:ci, :required_checks]) || []

    %__MODULE__{
      path: path,
      version: normalized.version,
      base_branch: normalized.base_branch,
      preflight_command: get_in(normalized, [:preflight, :command]),
      validation_command: get_in(normalized, [:validation, :command]),
      smoke_command: get_in(normalized, [:smoke, :command]),
      post_merge_command: get_in(normalized, [:post_merge, :command]),
      artifacts_command: get_in(normalized, [:artifacts, :command]),
      project: normalized.project,
      runtime: normalized.runtime,
      ci: normalized.ci,
      pull_request: normalized.pull_request,
      raw: normalized,
      publish_required_checks: pull_request_checks,
      ci_required_checks: ci_checks,
      required_checks: normalize_required_checks(pull_request_checks ++ ci_checks)
    }
  end

  defp validate_version(config) do
    case Map.fetch(config, "version") do
      :error ->
        {:error, :missing_harness_version}

      {:ok, @supported_version} ->
        {:ok, @supported_version}

      {:ok, value} when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {@supported_version, ""} -> {:ok, @supported_version}
          _ -> {:error, {:invalid_harness_version, value}}
        end

      {:ok, value} ->
        {:error, {:invalid_harness_version, value}}
    end
  end

  defp validate_base_branch(config) do
    case Map.get(config, "base_branch") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_harness_value, ["base_branch"]}}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:error, {:invalid_harness_value, ["base_branch"]}}

      value ->
        {:error, {:invalid_harness_value, ["base_branch"], value}}
    end
  end

  defp validate_stage(config, stage_name, _required?) do
    case Map.get(config, stage_name) do
      nil ->
        {:error, {:missing_harness_command, stage_name}}

      section when is_map(section) ->
        with :ok <- ensure_allowed_keys(section, @stage_keys, [stage_name]),
             {:ok, command} <- validate_command(section, stage_name),
             {:ok, outputs} <- validate_outputs(Map.get(section, "outputs"), [stage_name, "outputs"]),
             {:ok, success} <- validate_success(Map.get(section, "success"), [stage_name, "success"]) do
          {:ok,
           %{
             description: normalize_optional_string(Map.get(section, "description")),
             command: command,
             outputs: outputs,
             success: success
           }}
        end

      _ ->
        {:error, {:invalid_harness_section, [stage_name]}}
    end
  end

  defp validate_outputs(nil, _path), do: {:ok, %{}}

  defp validate_outputs(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @outputs_keys, path),
         {:ok, format} <- validate_optional_string(section, "format", path) do
      {:ok, %{format: format}}
    end
  end

  defp validate_outputs(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_success(nil, _path), do: {:ok, %{}}

  defp validate_success(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @success_keys, path),
         {:ok, exit_code} <- validate_optional_integer(section, "exit_code", path) do
      {:ok, %{exit_code: exit_code}}
    end
  end

  defp validate_success(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_project(nil), do: {:ok, %{}}

  defp validate_project(section) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @project_keys, ["project"]) do
      {:ok,
       %{
         type: normalize_optional_string(Map.get(section, "type")),
         xcodeproj: normalize_optional_string(Map.get(section, "xcodeproj")),
         scheme: normalize_optional_string(Map.get(section, "scheme"))
       }}
    end
  end

  defp validate_project(_section), do: {:error, {:invalid_harness_section, ["project"]}}

  defp validate_runtime(nil), do: {:ok, %{}}
  defp validate_runtime(section) when is_map(section), do: {:ok, normalize_runtime(section)}
  defp validate_runtime(_section), do: {:error, {:invalid_harness_section, ["runtime"]}}

  defp validate_ci(nil), do: {:ok, %{}}

  defp validate_ci(section) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @ci_keys, ["ci"]),
         {:ok, provider} <- validate_optional_string(section, "provider", ["ci", "provider"]),
         {:ok, workflow} <- validate_optional_string(section, "workflow", ["ci", "workflow"]),
         {:ok, env} <- validate_optional_string_map(Map.get(section, "env"), ["ci", "env"]) do
      {:ok,
       %{
         provider: provider,
         workflow: workflow,
         env: env,
         required_checks: normalize_required_checks(Map.get(section, "required_checks"))
       }}
    end
  end

  defp validate_ci(_section), do: {:error, {:invalid_harness_section, ["ci"]}}

  defp validate_pull_request(nil), do: {:error, {:invalid_harness_section, ["pull_request"]}}

  defp validate_pull_request(section) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @pull_request_keys, ["pull_request"]),
         {:ok, template} <- validate_optional_string(section, "template", ["pull_request", "template"]),
         {:ok, review_ready} <- validate_rule_group(Map.get(section, "review_ready"), ["pull_request", "review_ready"]),
         {:ok, merge_safe} <- validate_rule_group(Map.get(section, "merge_safe"), ["pull_request", "merge_safe"]) do
      {:ok,
       %{
         template: template,
         required_checks: normalize_required_checks(Map.get(section, "required_checks")),
         review_ready: review_ready,
         merge_safe: merge_safe
       }}
    end
  end

  defp validate_pull_request(_section), do: {:error, {:invalid_harness_section, ["pull_request"]}}

  defp validate_rule_group(nil, _path), do: {:ok, %{}}

  defp validate_rule_group(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @boolean_rule_groups, path),
         {:ok, all_rules} <- validate_rule_items(Map.get(section, "all"), path ++ ["all"]) do
      {:ok, %{all: all_rules}}
    end
  end

  defp validate_rule_group(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_rule_items(nil, _path), do: {:ok, []}

  defp validate_rule_items(items, path) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case validate_rule_item(item, path ++ [to_string(index)]) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_rule_items(_items, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_rule_item(item, path) when is_map(item) do
    with :ok <- ensure_allowed_keys(item, @rule_item_keys, path) do
      cond do
        value = normalize_optional_string(Map.get(item, "checkbox")) ->
          {:ok, %{checkbox: value}}

        value = normalize_optional_string(Map.get(item, "github_check")) ->
          {:ok, %{github_check: value}}

        true ->
          {:error, {:invalid_harness_value, path}}
      end
    end
  end

  defp validate_rule_item(_item, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_command(section, stage_name) do
    section
    |> Map.get("command")
    |> normalize_command()
    |> case do
      nil -> {:error, {:missing_harness_command, stage_name}}
      command -> {:ok, command}
    end
  end

  defp validate_optional_string(section, key, path) do
    case Map.get(section, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, normalize_optional_string(value)}
      value -> {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_optional_integer(section, key, path) do
    case Map.get(section, key) do
      nil ->
        {:ok, nil}

      value when is_integer(value) ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> {:ok, parsed}
          _ -> {:error, {:invalid_harness_value, path, value}}
        end

      value ->
        {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_optional_string_map(nil, _path), do: {:ok, %{}}

  defp validate_optional_string_map(section, path) when is_map(section) do
    section
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      case normalize_optional_string(value) do
        nil ->
          {:halt, {:error, {:invalid_harness_value, path ++ [key], value}}}

        normalized ->
          {:cont, {:ok, Map.put(acc, key, normalized)}}
      end
    end)
  end

  defp validate_optional_string_map(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp ensure_allowed_keys(section, allowed_keys, path) when is_map(section) do
    unknown =
      section
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_keys))
      |> Enum.sort()

    case unknown do
      [] -> :ok
      _ -> {:error, {:unknown_harness_keys, path, unknown}}
    end
  end

  defp require_publish_required_checks(%{required_checks: checks}) when is_list(checks) do
    case normalize_required_checks(checks) do
      [] -> {:error, :missing_required_checks}
      _ -> :ok
    end
  end

  defp normalize_command(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.trim_trailing(trimmed)
    end
  end

  defp normalize_command(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      [single] -> single
      parts -> Enum.map_join(parts, " ", &shell_escape/1)
    end
  end

  defp normalize_command(_value), do: nil

  defp normalize_required_checks(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_required_checks(_values), do: []

  defp normalize_runtime(section) do
    Map.new(section, fn {key, value} ->
      {to_string(key), normalize_runtime_value(value)}
    end)
  end

  defp normalize_runtime_value(value) when is_map(value), do: normalize_runtime(value)
  defp normalize_runtime_value(value) when is_list(value), do: Enum.map(value, &normalize_runtime_value/1)
  defp normalize_runtime_value(value), do: value

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp shell_escape(value) do
    escaped = String.replace(value, "'", "'\"'\"'")
    "'#{escaped}'"
  end

  defp requires_dogfood_harness_validation?(required_labels) do
    required_labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(String.downcase(&1) == "dogfood:symphony"))
  end
end
