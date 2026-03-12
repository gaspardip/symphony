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
    deploy
    verification
    project
    runtime
    ci
    pull_request
    agent_harness
  )
  @deploy_keys ~w(preview production post_deploy_verify rollback)
  @stage_keys ~w(description command outputs success)
  @outputs_keys ~w(format)
  @success_keys ~w(exit_code)
  @project_keys ~w(type xcodeproj scheme)
  @ci_keys ~w(provider workflow env required_checks)
  @pull_request_keys ~w(required_checks template review_ready merge_safe)
  @verification_keys ~w(behavioral_proof ui_proof)
  @behavioral_proof_keys ~w(required mode source_paths test_paths artifact_path)
  @ui_proof_keys ~w(required mode source_paths test_paths artifact_paths required_checks command provider result_url_pattern scenarios)
  @agent_harness_keys ~w(scope initializer knowledge progress features publish_gate)
  @agent_initializer_keys ~w(enabled max_turns refresh)
  @agent_knowledge_keys ~w(root required_files)
  @agent_progress_keys ~w(root pattern required_sections)
  @agent_features_keys ~w(root format required_fields)
  @agent_publish_gate_keys ~w(require_progress require_feature_update_on_code_change)
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
    :deploy,
    :deploy_preview_command,
    :deploy_production_command,
    :post_deploy_verify_command,
    :deploy_rollback_command,
    :verification,
    :behavioral_proof,
    :ui_proof,
    :project,
    :runtime,
    :ci,
    :pull_request,
    :agent_harness,
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
          deploy: map(),
          deploy_preview_command: String.t() | nil,
          deploy_production_command: String.t() | nil,
          post_deploy_verify_command: String.t() | nil,
          deploy_rollback_command: String.t() | nil,
          verification: map(),
          behavioral_proof: map() | nil,
          ui_proof: map() | nil,
          project: map(),
          runtime: map(),
          ci: map(),
          pull_request: map(),
          agent_harness: map() | nil,
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
         {:ok, deploy} <- validate_deploy(Map.get(config, "deploy")),
         {:ok, verification} <- validate_verification(Map.get(config, "verification")),
         {:ok, project} <- validate_project(Map.get(config, "project")),
         {:ok, runtime} <- validate_runtime(Map.get(config, "runtime")),
         {:ok, ci} <- validate_ci(Map.get(config, "ci")),
         {:ok, pull_request} <- validate_pull_request(Map.get(config, "pull_request")),
         {:ok, agent_harness} <- validate_agent_harness(Map.get(config, "agent_harness")),
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
         deploy: deploy,
         verification: verification,
         project: project,
         runtime: runtime,
         ci: ci,
         pull_request: pull_request,
         agent_harness: agent_harness
       }}
    end
  end

  def validate(_decoded), do: {:error, :invalid_harness_root}

  @spec validate_runner_checkout(boolean() | [String.t()], Path.t()) :: :ok | {:error, term()}
  def validate_runner_checkout(validation_required_or_labels, checkout_root \\ RunnerRuntime.current_checkout_root())
      when is_binary(checkout_root) do
    if runner_harness_validation_required?(validation_required_or_labels) do
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
      deploy: normalized.deploy,
      deploy_preview_command: get_in(normalized, [:deploy, :preview, :command]),
      deploy_production_command: get_in(normalized, [:deploy, :production, :command]),
      post_deploy_verify_command: get_in(normalized, [:deploy, :post_deploy_verify, :command]),
      deploy_rollback_command: get_in(normalized, [:deploy, :rollback, :command]),
      verification: normalized.verification,
      behavioral_proof: get_in(normalized, [:verification, :behavioral_proof]),
      ui_proof: get_in(normalized, [:verification, :ui_proof]),
      project: normalized.project,
      runtime: normalized.runtime,
      ci: normalized.ci,
      pull_request: normalized.pull_request,
      agent_harness: normalized.agent_harness,
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

  defp validate_deploy(nil), do: {:ok, %{}}

  defp validate_deploy(section) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @deploy_keys, ["deploy"]),
         {:ok, preview} <- validate_optional_stage(section, "preview", ["deploy", "preview"]),
         {:ok, production} <- validate_optional_stage(section, "production", ["deploy", "production"]),
         {:ok, post_deploy_verify} <- validate_optional_stage(section, "post_deploy_verify", ["deploy", "post_deploy_verify"]),
         {:ok, rollback} <- validate_optional_stage(section, "rollback", ["deploy", "rollback"]) do
      {:ok,
       %{}
       |> put_if_present(:preview, preview)
       |> put_if_present(:production, production)
       |> put_if_present(:post_deploy_verify, post_deploy_verify)
       |> put_if_present(:rollback, rollback)}
    end
  end

  defp validate_deploy(_section), do: {:error, {:invalid_harness_section, ["deploy"]}}

  defp validate_optional_stage(section, stage_name, path) when is_map(section) do
    case Map.get(section, stage_name) do
      nil ->
        {:ok, nil}

      stage when is_map(stage) ->
        with :ok <- ensure_allowed_keys(stage, @stage_keys, path),
             {:ok, command} <- validate_command(stage, Enum.join(path, ".")),
             {:ok, outputs} <- validate_outputs(Map.get(stage, "outputs"), path ++ ["outputs"]),
             {:ok, success} <- validate_success(Map.get(stage, "success"), path ++ ["success"]) do
          {:ok,
           %{
             description: normalize_optional_string(Map.get(stage, "description")),
             command: command,
             outputs: outputs,
             success: success
           }}
        end

      _ ->
        {:error, {:invalid_harness_section, path}}
    end
  end

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

  defp validate_verification(nil), do: {:ok, %{}}

  defp validate_verification(section) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @verification_keys, ["verification"]),
         {:ok, behavioral_proof} <-
           validate_behavioral_proof(
             Map.get(section, "behavioral_proof"),
             ["verification", "behavioral_proof"]
           ),
         {:ok, ui_proof} <-
           validate_ui_proof(
             Map.get(section, "ui_proof"),
             ["verification", "ui_proof"]
           ) do
      {:ok, %{behavioral_proof: behavioral_proof, ui_proof: ui_proof}}
    end
  end

  defp validate_verification(_section), do: {:error, {:invalid_harness_section, ["verification"]}}

  defp validate_behavioral_proof(nil, _path), do: {:ok, nil}

  defp validate_behavioral_proof(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @behavioral_proof_keys, path),
         {:ok, required} <- validate_required_boolean(section, "required", path ++ ["required"]),
         {:ok, mode} <- validate_behavioral_proof_mode(section, path ++ ["mode"]),
         {:ok, source_paths} <- validate_string_list(Map.get(section, "source_paths"), path ++ ["source_paths"]),
         {:ok, test_paths} <- validate_string_list(Map.get(section, "test_paths"), path ++ ["test_paths"]),
         {:ok, artifact_path} <- validate_optional_string(section, "artifact_path", path ++ ["artifact_path"]) do
      {:ok,
       %{
         required: required,
         mode: mode,
         source_paths: source_paths,
         test_paths: test_paths,
         artifact_path: artifact_path
       }}
    end
  end

  defp validate_behavioral_proof(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_ui_proof(nil, _path), do: {:ok, nil}

  defp validate_ui_proof(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @ui_proof_keys, path),
         {:ok, required} <- validate_required_boolean(section, "required", path ++ ["required"]),
         {:ok, mode} <- validate_ui_proof_mode(section, path ++ ["mode"]),
         {:ok, source_paths} <- validate_string_list(Map.get(section, "source_paths"), path ++ ["source_paths"]),
         {:ok, test_paths} <- validate_string_list(Map.get(section, "test_paths"), path ++ ["test_paths"]),
         {:ok, artifact_paths} <- validate_string_list(Map.get(section, "artifact_paths"), path ++ ["artifact_paths"]),
         {:ok, required_checks} <- validate_string_list(Map.get(section, "required_checks"), path ++ ["required_checks"]),
         {:ok, command} <- validate_optional_command(section, path ++ ["command"]),
         {:ok, provider} <- validate_optional_string(section, "provider", path ++ ["provider"]),
         {:ok, result_url_pattern} <-
           validate_optional_string(section, "result_url_pattern", path ++ ["result_url_pattern"]),
         {:ok, scenarios} <- validate_string_list(Map.get(section, "scenarios"), path ++ ["scenarios"]) do
      {:ok,
       %{
         required: required,
         mode: mode,
         source_paths: source_paths,
         test_paths: test_paths,
         artifact_paths: artifact_paths,
         required_checks: normalize_required_checks(required_checks),
         command: command,
         provider: provider,
         result_url_pattern: result_url_pattern,
         scenarios: scenarios
       }}
    end
  end

  defp validate_ui_proof(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_runtime(nil), do: {:ok, %{}}
  defp validate_runtime(section) when is_map(section), do: {:ok, normalize_runtime(section)}
  defp validate_runtime(_section), do: {:error, {:invalid_harness_section, ["runtime"]}}

  defp validate_agent_harness(nil), do: {:ok, nil}

  defp validate_agent_harness(section) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @agent_harness_keys, ["agent_harness"]),
         {:ok, scope} <- validate_agent_harness_scope(section, ["agent_harness", "scope"]),
         {:ok, initializer} <- validate_agent_initializer(Map.get(section, "initializer"), ["agent_harness", "initializer"]),
         {:ok, knowledge} <- validate_agent_knowledge(Map.get(section, "knowledge"), ["agent_harness", "knowledge"]),
         {:ok, progress} <- validate_agent_progress(Map.get(section, "progress"), ["agent_harness", "progress"]),
         {:ok, features} <- validate_agent_features(Map.get(section, "features"), ["agent_harness", "features"]),
         {:ok, publish_gate} <- validate_agent_publish_gate(Map.get(section, "publish_gate"), ["agent_harness", "publish_gate"]) do
      {:ok,
       %{
         scope: scope,
         initializer: initializer,
         knowledge: knowledge,
         progress: progress,
         features: features,
         publish_gate: publish_gate
       }}
    end
  end

  defp validate_agent_harness(_section), do: {:error, {:invalid_harness_section, ["agent_harness"]}}

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

  defp validate_agent_harness_scope(section, path) do
    case normalize_optional_string(Map.get(section, "scope")) do
      "self_host_only" -> {:ok, "self_host_only"}
      nil -> {:error, {:invalid_harness_value, path}}
      value -> {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_agent_initializer(nil, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_initializer(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @agent_initializer_keys, path),
         {:ok, enabled} <- validate_required_boolean(section, "enabled", path ++ ["enabled"]),
         {:ok, max_turns} <- validate_positive_integer(section, "max_turns", path ++ ["max_turns"]),
         {:ok, refresh} <- validate_agent_initializer_refresh(section, path ++ ["refresh"]) do
      {:ok, %{enabled: enabled, max_turns: max_turns, refresh: refresh}}
    end
  end

  defp validate_agent_initializer(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_knowledge(nil, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_knowledge(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @agent_knowledge_keys, path),
         {:ok, root} <- validate_required_string(section, "root", path ++ ["root"]),
         {:ok, required_files} <- validate_non_empty_string_list(Map.get(section, "required_files"), path ++ ["required_files"]) do
      {:ok, %{root: root, required_files: required_files}}
    end
  end

  defp validate_agent_knowledge(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_progress(nil, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_progress(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @agent_progress_keys, path),
         {:ok, root} <- validate_required_string(section, "root", path ++ ["root"]),
         {:ok, pattern} <- validate_required_string(section, "pattern", path ++ ["pattern"]),
         {:ok, required_sections} <- validate_non_empty_string_list(Map.get(section, "required_sections"), path ++ ["required_sections"]) do
      {:ok, %{root: root, pattern: pattern, required_sections: required_sections}}
    end
  end

  defp validate_agent_progress(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_features(nil, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_features(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @agent_features_keys, path),
         {:ok, root} <- validate_required_string(section, "root", path ++ ["root"]),
         {:ok, format} <- validate_agent_features_format(section, path ++ ["format"]),
         {:ok, required_fields} <- validate_non_empty_string_list(Map.get(section, "required_fields"), path ++ ["required_fields"]) do
      {:ok, %{root: root, format: format, required_fields: required_fields}}
    end
  end

  defp validate_agent_features(_section, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_publish_gate(nil, path), do: {:error, {:invalid_harness_section, path}}

  defp validate_agent_publish_gate(section, path) when is_map(section) do
    with :ok <- ensure_allowed_keys(section, @agent_publish_gate_keys, path),
         {:ok, require_progress} <- validate_required_boolean(section, "require_progress", path ++ ["require_progress"]),
         {:ok, require_feature_update_on_code_change} <-
           validate_required_boolean(
             section,
             "require_feature_update_on_code_change",
             path ++ ["require_feature_update_on_code_change"]
           ) do
      {:ok,
       %{
         require_progress: require_progress,
         require_feature_update_on_code_change: require_feature_update_on_code_change
       }}
    end
  end

  defp validate_agent_publish_gate(_section, path), do: {:error, {:invalid_harness_section, path}}

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

  defp validate_required_boolean(section, key, path) do
    case Map.fetch(section, key) do
      :error -> {:error, {:invalid_harness_value, path}}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_positive_integer(section, key, path) do
    case Map.fetch(section, key) do
      :error ->
        {:error, {:invalid_harness_value, path}}

      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, value} when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, {:invalid_harness_value, path, value}}
        end

      {:ok, value} ->
        {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_required_string(section, key, path) do
    case normalize_optional_string(Map.get(section, key)) do
      nil -> {:error, {:invalid_harness_value, path}}
      value -> {:ok, value}
    end
  end

  defp validate_behavioral_proof_mode(section, path) do
    case normalize_optional_string(Map.get(section, "mode")) do
      "unit_first" -> {:ok, "unit_first"}
      "test_delta_required" -> {:ok, "test_delta_required"}
      "harness_artifact_only" -> {:ok, "harness_artifact_only"}
      nil -> {:error, {:invalid_harness_value, path}}
      value -> {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_ui_proof_mode(section, path) do
    case normalize_optional_string(Map.get(section, "mode")) do
      "local" -> {:ok, "local"}
      "ci_check" -> {:ok, "ci_check"}
      "external_service" -> {:ok, "external_service"}
      "hybrid" -> {:ok, "hybrid"}
      nil -> {:error, {:invalid_harness_value, path}}
      value -> {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_agent_initializer_refresh(section, path) do
    case normalize_optional_string(Map.get(section, "refresh")) do
      "missing" -> {:ok, "missing"}
      "always" -> {:ok, "always"}
      nil -> {:error, {:invalid_harness_value, path}}
      value -> {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_agent_features_format(section, path) do
    case normalize_optional_string(Map.get(section, "format")) do
      "yaml" -> {:ok, "yaml"}
      nil -> {:error, {:invalid_harness_value, path}}
      value -> {:error, {:invalid_harness_value, path, value}}
    end
  end

  defp validate_optional_command(section, path) do
    case Map.get(section, "command") do
      nil -> {:ok, nil}
      value ->
        case normalize_command(value) do
          nil -> {:error, {:invalid_harness_value, path, value}}
          command -> {:ok, command}
        end
    end
  end

  defp validate_string_list(nil, _path), do: {:ok, []}

  defp validate_string_list(values, path) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_optional_string(value) do
        nil -> {:halt, {:error, {:invalid_harness_value, path, value}}}
        normalized -> {:cont, {:ok, acc ++ [normalized]}}
      end
    end)
  end

  defp validate_string_list(_values, path), do: {:error, {:invalid_harness_value, path}}

  defp validate_non_empty_string_list(values, path) do
    with {:ok, normalized} <- validate_string_list(values, path),
         false <- normalized == [] do
      {:ok, normalized}
    else
      true -> {:error, {:invalid_harness_value, path, values}}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

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

  defp runner_harness_validation_required?(true), do: true
  defp runner_harness_validation_required?(false), do: false

  defp runner_harness_validation_required?(required_labels) when is_list(required_labels) do
    required_labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(String.downcase(&1) == "dogfood:symphony"))
  end

  defp runner_harness_validation_required?(_other), do: false
end
