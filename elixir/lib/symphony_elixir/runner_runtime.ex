defmodule SymphonyElixir.RunnerRuntime do
  @moduledoc """
  Runtime metadata and safety helpers for the Symphony runner install.
  """

  alias SymphonyElixir.Config

  @metadata_file "metadata.json"
  @history_file "history.jsonl"
  @manifest_file "manifest.json"
  @current_link "current"
  @default_canary_label "canary:symphony"
  @default_runner_mode "stable"
  @default_history_limit 20
  @valid_runner_modes ["stable", "canary_active", "canary_failed"]

  @spec info() :: map()
  def info do
    install_root = Config.runner_install_root()
    current_root = current_checkout_root()
    metadata_result = read_metadata(install_root)
    metadata = metadata_from_result(metadata_result)
    history = recent_history(install_root, @default_history_limit)
    runner_mode = runner_mode(metadata)
    canary_required_labels = canary_required_labels(metadata)
    current_link_target = current_link_target(install_root)
    runner_health = runner_health(Config.linear_required_labels(), install_root, metadata_result, current_link_target)
    release_manifest_path = release_manifest_path(metadata, current_link_target)
    rollback_target_path = rollback_target_path(metadata)
    canary_evidence = canary_evidence(metadata)

    %{
      instance_id: Config.runner_instance_id(),
      instance_name: Config.runner_instance_name(),
      channel: Config.runner_channel(),
      install_root: install_root,
      workspace_root: Config.workspace_root(),
      current_checkout_root: current_root,
      current_link_target: current_link_target,
      current_version_sha: current_version_sha(current_root) || Map.get(metadata, "current_version_sha"),
      runtime_version: current_version_sha(current_root) || Map.get(metadata, "current_version_sha"),
      promoted_release_sha: Map.get(metadata, "promoted_release_sha"),
      promoted_ref: Map.get(metadata, "promoted_ref"),
      promoted_at: Map.get(metadata, "promoted_at"),
      promoted_release_path: Map.get(metadata, "promoted_release_path"),
      previous_release_sha: Map.get(metadata, "previous_release_sha"),
      previous_release_path: Map.get(metadata, "previous_release_path"),
      runner_mode: runner_mode,
      canary_required_labels: canary_required_labels,
      canary_started_at: Map.get(metadata, "canary_started_at"),
      canary_recorded_at: Map.get(metadata, "canary_recorded_at"),
      canary_result: Map.get(metadata, "canary_result"),
      canary_note: Map.get(metadata, "canary_note"),
      canary_evidence: canary_evidence,
      rollback_recommended: Map.get(metadata, "rollback_recommended", false),
      rollback_target_path: rollback_target_path,
      rollback_target_exists: release_exists?(rollback_target_path),
      effective_required_labels: effective_required_labels(Config.linear_required_labels(), metadata),
      rule_id: runner_rule_id(metadata),
      rollback_rule_id: rollback_rule_id(metadata),
      repo_url: Map.get(metadata, "repo_url"),
      release_manifest_path: release_manifest_path,
      release_manifest: load_release_manifest(release_manifest_path),
      build_tool_versions: Map.get(metadata, "build_tool_versions"),
      preflight_completed_at: Map.get(metadata, "preflight_completed_at"),
      smoke_completed_at: Map.get(metadata, "smoke_completed_at"),
      promotion_host: Map.get(metadata, "promotion_host"),
      promotion_user: Map.get(metadata, "promotion_user"),
      runner_health: runner_health.status,
      runner_health_rule_id: runner_health.rule_id,
      runner_health_summary: runner_health.summary,
      runner_health_human_action: runner_health.human_action,
      dispatch_enabled: runner_health.dispatch_enabled,
      history: history
    }
  end

  @spec instance_id() :: String.t()
  def instance_id do
    Config.runner_instance_id()
  end

  @spec channel() :: String.t()
  def channel do
    Config.runner_channel()
  end

  @spec runtime_version() :: String.t() | nil
  def runtime_version do
    current_version_sha(current_checkout_root()) ||
      Map.get(load_metadata(Config.runner_install_root()), "current_version_sha")
  end

  @spec metadata_path(Path.t()) :: Path.t()
  def metadata_path(install_root) when is_binary(install_root) do
    Path.join(install_root, @metadata_file)
  end

  @spec history_path(Path.t()) :: Path.t()
  def history_path(install_root) when is_binary(install_root) do
    Path.join(install_root, @history_file)
  end

  @spec load_metadata(Path.t()) :: map()
  def load_metadata(install_root) when is_binary(install_root) do
    install_root
    |> read_metadata()
    |> metadata_from_result()
  end

  @spec runner_health([String.t()] | nil, Path.t() | nil) :: map()
  def runner_health(required_labels \\ Config.linear_required_labels(), install_root \\ Config.runner_install_root()) do
    metadata_result = read_metadata(install_root)
    current_link_target = current_link_target(install_root)
    runner_health(required_labels, install_root, metadata_result, current_link_target)
  end

  @spec recent_history(Path.t()) :: [map()]
  @spec recent_history(Path.t(), pos_integer()) :: [map()]
  def recent_history(install_root, limit \\ @default_history_limit)

  @spec recent_history(Path.t(), pos_integer()) :: [map()]
  def recent_history(install_root, limit)
      when is_binary(install_root) and is_integer(limit) and limit > 0 do
    install_root
    |> history_path()
    |> File.exists?()
    |> case do
      true ->
        install_root
        |> history_path()
        |> File.stream!()
        |> Enum.reduce([], fn line, acc ->
          case Jason.decode(String.trim(line)) do
            {:ok, %{} = entry} -> [entry | acc] |> Enum.take(limit)
            _ -> acc
          end
        end)
        |> Enum.reverse()

      false ->
        []
    end
  rescue
    _error ->
      []
  end

  def recent_history(_install_root, _limit), do: []

  @spec current_checkout_root() :: Path.t()
  def current_checkout_root do
    cwd = File.cwd!()

    case Path.basename(cwd) do
      "elixir" -> Path.expand("..", cwd)
      _ -> Path.expand(cwd)
    end
  end

  @spec protected_paths() :: [Path.t()]
  def protected_paths do
    [Config.runner_install_root(), current_checkout_root()]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  @spec overlaps_protected_path?(Path.t()) :: boolean()
  def overlaps_protected_path?(workspace) when is_binary(workspace) do
    workspace = Path.expand(workspace)

    Enum.any?(protected_paths(), fn protected ->
      path_overlap?(workspace, protected)
    end)
  end

  @spec current_version_sha(Path.t()) :: String.t() | nil
  def current_version_sha(root) when is_binary(root) do
    git_dir = Path.join(root, ".git")

    if File.exists?(git_dir) do
      case System.cmd("git", ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true) do
        {output, 0} -> output |> to_string() |> String.trim()
        _ -> nil
      end
    else
      nil
    end
  end

  @spec effective_required_labels() :: [String.t()]
  @spec effective_required_labels([String.t()] | nil) :: [String.t()]
  @spec effective_required_labels([String.t()] | nil, map() | nil) :: [String.t()]
  def effective_required_labels(workflow_required_labels \\ Config.linear_required_labels(), metadata \\ nil)

  @spec effective_required_labels([String.t()] | nil, map() | nil) :: [String.t()]
  def effective_required_labels(workflow_required_labels, nil) do
    effective_required_labels(workflow_required_labels, load_metadata(Config.runner_install_root()))
  end

  def effective_required_labels(workflow_required_labels, metadata) when is_map(metadata) do
    workflow_labels =
      workflow_required_labels
      |> List.wrap()
      |> normalize_labels()

    cond do
      Config.runner_self_host_project?() ->
        workflow_labels

      runner_mode(metadata) == "canary_active" ->
        workflow_labels
        |> Kernel.++(canary_required_labels(metadata))
        |> normalize_labels()

      true ->
        workflow_labels
    end
  end

  def effective_required_labels(workflow_required_labels, _metadata) do
    workflow_required_labels
    |> List.wrap()
    |> normalize_labels()
  end

  @spec runner_mode(map() | nil) :: String.t()
  def runner_mode(%{} = metadata) do
    metadata
    |> Map.get("runner_mode", @default_runner_mode)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @default_runner_mode
      mode -> mode
    end
  end

  def runner_mode(_metadata), do: @default_runner_mode

  @spec canary_required_labels(map() | nil) :: [String.t()]
  def canary_required_labels(%{} = metadata) do
    metadata
    |> Map.get("canary_required_labels", [])
    |> List.wrap()
    |> case do
      [] -> [@default_canary_label]
      labels -> labels
    end
    |> normalize_labels()
  end

  def canary_required_labels(_metadata), do: [@default_canary_label]

  @spec runner_rule_id(map() | nil) :: String.t() | nil
  def runner_rule_id(%{} = metadata) do
    case runner_mode(metadata) do
      "canary_active" -> "runner.canary_active"
      "canary_failed" -> "runner.canary_failed"
      _ -> nil
    end
  end

  def runner_rule_id(_metadata), do: nil

  @spec rollback_rule_id(map() | nil) :: String.t() | nil
  def rollback_rule_id(%{} = metadata) do
    if Map.get(metadata, "rollback_recommended", false), do: "runner.rollback_recommended", else: nil
  end

  def rollback_rule_id(_metadata), do: nil

  defp runner_health(required_labels, install_root, metadata_result, current_link_target) do
    if runner_validation_required?(required_labels) do
      validate_runner_install(install_root, metadata_result, current_link_target)
    else
      %{
        status: "not_required",
        rule_id: nil,
        summary: "Runner install validation is not required for this workflow.",
        human_action: nil,
        dispatch_enabled: true
      }
    end
  end

  defp validate_runner_install(install_root, metadata_result, current_link_target) do
    metadata = metadata_from_result(metadata_result)
    current_link_path = current_link_path(install_root)
    promoted_release_path = normalize_path(Map.get(metadata, "promoted_release_path"))
    promoted_release_sha = normalize_string(Map.get(metadata, "promoted_release_sha"))
    raw_runner_mode = normalize_string(Map.get(metadata, "runner_mode"))

    cond do
      not is_binary(install_root) or String.trim(install_root) == "" or not File.dir?(install_root) ->
        invalid_runner_health(
          "runner.install_missing",
          "Runner install root is missing or unreadable.",
          "Bootstrap or promote a runner release before dispatching dogfood issues."
        )

      match?({:error, _reason}, metadata_result) ->
        invalid_runner_health(
          "runner.metadata_invalid",
          "Runner metadata is missing or invalid.",
          "Repair `metadata.json` or promote a fresh runner release before dispatching dogfood issues."
        )

      not File.exists?(current_link_path) or is_nil(current_link_target) ->
        invalid_runner_health(
          "runner.current_missing",
          "Runner `current` symlink is missing or unreadable.",
          "Recreate the `current` symlink by promoting or rolling back a runner release."
        )

      not release_exists?(current_link_target) ->
        invalid_runner_health(
          "runner.release_missing",
          "Runner `current` symlink points to a release that is missing on disk.",
          "Restore the release directory or roll back to a healthy release."
        )

      raw_runner_mode not in @valid_runner_modes ->
        invalid_runner_health(
          "runner.metadata_invalid",
          "Runner metadata declares an invalid runner mode.",
          "Set `runner_mode` to `stable`, `canary_active`, or `canary_failed` in `metadata.json`."
        )

      promoted_release_path == nil or promoted_release_sha == nil ->
        invalid_runner_health(
          "runner.metadata_invalid",
          "Runner metadata is missing the promoted release path or SHA.",
          "Repair `metadata.json` or promote a fresh runner release."
        )

      not release_exists?(promoted_release_path) ->
        invalid_runner_health(
          "runner.release_missing",
          "The promoted release recorded in metadata is missing on disk.",
          "Restore the promoted release or roll back to an available release."
        )

      path_mismatch?(promoted_release_path, current_link_target) ->
        invalid_runner_health(
          "runner.current_mismatch",
          "Runner metadata does not match the `current` symlink target.",
          "Repair `metadata.json` or repoint `current` to the promoted release."
        )

      release_sha_from_path(current_link_target) != promoted_release_sha ->
        invalid_runner_health(
          "runner.current_mismatch",
          "Runner metadata SHA does not match the active release directory.",
          "Repair `metadata.json` or roll back to a consistent release."
        )

      true ->
        %{
          status: "healthy",
          rule_id: nil,
          summary: "Runner install is healthy and dispatch is enabled.",
          human_action: nil,
          dispatch_enabled: true
        }
    end
  end

  defp invalid_runner_health(rule_id, summary, human_action) do
    %{
      status: "invalid",
      rule_id: rule_id,
      summary: summary,
      human_action: human_action,
      dispatch_enabled: false
    }
  end

  defp runner_validation_required?(required_labels) do
    if Config.runner_self_host_project?() do
      true
    else
      required_labels
      |> List.wrap()
      |> normalize_labels()
      |> Enum.member?("dogfood:symphony")
    end
  end

  defp current_link_path(install_root) when is_binary(install_root) do
    Path.join(install_root, @current_link)
  end

  defp current_link_target(install_root) when is_binary(install_root) do
    install_root
    |> current_link_path()
    |> File.read_link()
    |> case do
      {:ok, target} -> Path.expand(target, install_root)
      _ -> nil
    end
  end

  defp current_link_target(_install_root), do: nil

  defp read_metadata(install_root) when is_binary(install_root) do
    install_root
    |> metadata_path()
    |> File.read()
    |> case do
      {:ok, payload} ->
        case Jason.decode(payload) do
          {:ok, %{} = metadata} -> {:ok, metadata}
          _ -> {:error, :invalid_json}
        end

      {:error, :enoent} ->
        {:error, :missing}

      {:error, _reason} ->
        {:error, :read_failed}
    end
  end

  defp read_metadata(_install_root), do: {:error, :invalid_path}

  defp metadata_from_result({:ok, %{} = metadata}), do: metadata
  defp metadata_from_result(_result), do: %{}

  defp release_manifest_path(%{} = metadata, current_link_target) do
    metadata
    |> Map.get("release_manifest_path")
    |> normalize_path()
    |> case do
      nil -> manifest_path_for_release(current_link_target)
      path -> path
    end
  end

  defp release_manifest_path(_metadata, current_link_target), do: manifest_path_for_release(current_link_target)

  defp manifest_path_for_release(path) when is_binary(path) do
    Path.join(path, @manifest_file)
  end

  defp manifest_path_for_release(_path), do: nil

  defp load_release_manifest(path) when is_binary(path) do
    case File.read(path) do
      {:ok, payload} ->
        case Jason.decode(payload) do
          {:ok, %{} = manifest} -> manifest
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp load_release_manifest(_path), do: nil

  defp rollback_target_path(%{} = metadata) do
    case normalize_path(Map.get(metadata, "previous_release_path")) do
      nil ->
        metadata
        |> Map.get("previous_release_sha")
        |> normalize_string()
        |> case do
          nil -> nil
          sha -> Path.join([Config.runner_install_root(), "releases", sha])
        end

      path ->
        path
    end
  end

  defp rollback_target_path(_metadata), do: nil

  defp canary_evidence(%{} = metadata) do
    evidence = Map.get(metadata, "canary_evidence") || %{}

    %{
      issues:
        evidence
        |> Map.get("issues", [])
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == "")),
      prs:
        evidence
        |> Map.get("prs", [])
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))
    }
  end

  defp canary_evidence(_metadata), do: %{issues: [], prs: []}

  defp path_mismatch?(left, right) when is_binary(left) and is_binary(right) do
    Path.expand(left) != Path.expand(right)
  end

  defp path_mismatch?(_left, _right), do: true

  defp release_sha_from_path(path) when is_binary(path) do
    path
    |> String.trim_trailing("/")
    |> Path.basename()
    |> normalize_string()
  end

  defp release_sha_from_path(_path), do: nil

  defp release_exists?(path) when is_binary(path), do: File.dir?(path)
  defp release_exists?(_path), do: false

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_path(value) when is_binary(value) do
    case normalize_string(value) do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  defp normalize_path(_value), do: nil

  defp path_overlap?(left, right) do
    String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/") or
      left == right
  end

  defp normalize_labels(labels) do
    labels
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end
