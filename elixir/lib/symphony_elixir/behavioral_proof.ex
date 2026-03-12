defmodule SymphonyElixir.BehavioralProof do
  @moduledoc """
  Evaluates whether a diff includes repo-owned behavioral proof such as test deltas
  or an explicit proof artifact declared in the repo harness.
  """

  defmodule Result do
    @moduledoc false

    defstruct [
      :mode,
      :reason,
      :artifact_path,
      required?: false,
      satisfied?: true,
      artifact_present?: false,
      behavior_paths: [],
      proof_paths: []
    ]
  end

  @doc_extensions ~w(.md .markdown .rst .adoc .txt)
  @config_extensions ~w(.json .yaml .yml .toml .ini .cfg .xcconfig .plist .pbxproj .xcscheme .gitignore)
  @config_filenames ~w(Dockerfile Makefile Podfile Podfile.lock Package.swift package.json package-lock.json yarn.lock pnpm-lock.yaml)
  @default_test_markers ["/test/", "/tests/", "__tests__/", "/uitests/"]

  @spec evaluate(Path.t(), map() | nil, [String.t()]) :: Result.t()
  def evaluate(workspace, harness, changed_paths) when is_binary(workspace) and is_list(changed_paths) do
    proof_config = proof_config(harness)
    mode = Map.get(proof_config, :mode) || "unit_first"
    source_paths = Map.get(proof_config, :source_paths, [])
    test_paths = Map.get(proof_config, :test_paths, [])
    artifact_path = Map.get(proof_config, :artifact_path)

    normalized_paths =
      changed_paths
      |> Enum.map(&normalize_path/1)
      |> Enum.reject(&(&1 == ""))

    behavior_paths = Enum.filter(normalized_paths, &behavior_path?(&1, source_paths, test_paths))
    proof_paths = Enum.filter(normalized_paths, &proof_path?(&1, test_paths))
    artifact_present? = artifact_present?(workspace, artifact_path)
    required? = Map.get(proof_config, :required, true) and behavior_paths != []
    satisfied? = proof_satisfied?(mode, proof_paths, artifact_present?)

    %Result{
      required?: required?,
      satisfied?: if(required?, do: satisfied?, else: true),
      mode: mode,
      reason: reason(required?, satisfied?, mode, behavior_paths, proof_paths, artifact_path, artifact_present?),
      artifact_path: artifact_path,
      artifact_present?: artifact_present?,
      behavior_paths: behavior_paths,
      proof_paths: proof_paths
    }
  end

  @spec to_map(Result.t()) :: map()
  def to_map(%Result{} = result) do
    %{
      required: result.required?,
      satisfied: result.satisfied?,
      mode: result.mode,
      reason: result.reason,
      artifact_path: result.artifact_path,
      artifact_present: result.artifact_present?,
      behavior_paths: result.behavior_paths,
      proof_paths: result.proof_paths
    }
  end

  defp proof_config(%{behavioral_proof: %{} = config}), do: config

  defp proof_config(_harness) do
    %{
      required: true,
      mode: "unit_first",
      source_paths: [],
      test_paths: [],
      artifact_path: nil
    }
  end

  defp normalize_path(path) do
    path
    |> to_string()
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
    |> String.trim_trailing("/")
  end

  defp behavior_path?(path, source_paths, test_paths) do
    source_path?(path, source_paths) and not proof_path?(path, test_paths)
  end

  defp source_path?(path, []), do: not docs_or_config_path?(path) and not default_test_path?(path)
  defp source_path?(path, source_paths), do: path_matches_any_prefix?(path, source_paths)

  defp proof_path?(path, []), do: default_test_path?(path)
  defp proof_path?(path, test_paths), do: path_matches_any_prefix?(path, test_paths)

  defp docs_or_config_path?(path) do
    downcased = String.downcase(path)
    basename = Path.basename(path)
    extension = String.downcase(Path.extname(path))

    String.starts_with?(downcased, ".github/") or
      String.starts_with?(downcased, "docs/") or
      extension in @doc_extensions or
      extension in @config_extensions or
      basename in @config_filenames
  end

  defp default_test_path?(path) do
    downcased = "/" <> String.downcase(path)
    basename = String.downcase(Path.basename(path))

    Enum.any?(@default_test_markers, &String.contains?(downcased, &1)) or
      Regex.match?(~r/(^|[^a-z])(test|tests)([^a-z]|$)/, basename)
  end

  defp path_matches_any_prefix?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      normalized = normalize_path(prefix)
      path == normalized or String.starts_with?(path, normalized <> "/")
    end)
  end

  defp artifact_present?(_workspace, nil), do: false

  defp artifact_present?(workspace, artifact_path) do
    workspace
    |> Path.join(artifact_path)
    |> File.exists?()
  end

  defp proof_satisfied?("harness_artifact_only", _proof_paths, artifact_present?), do: artifact_present?
  defp proof_satisfied?(_mode, proof_paths, _artifact_present?) when proof_paths != [], do: true
  defp proof_satisfied?(_mode, _proof_paths, artifact_present?), do: artifact_present?

  defp reason(false, _satisfied, _mode, [], _proof_paths, _artifact_path, _artifact_present?) do
    "No behavior-changing source files were modified, so behavioral proof is not required."
  end

  defp reason(true, true, "harness_artifact_only", _behavior_paths, _proof_paths, artifact_path, true) do
    "Behavioral proof is satisfied by the configured artifact at `#{artifact_path}`."
  end

  defp reason(true, true, _mode, _behavior_paths, proof_paths, _artifact_path, _artifact_present?) when proof_paths != [] do
    "Behavioral proof is satisfied by changed proof files: #{Enum.join(proof_paths, ", ")}."
  end

  defp reason(true, true, _mode, _behavior_paths, _proof_paths, artifact_path, true) do
    "Behavioral proof is satisfied by the configured artifact at `#{artifact_path}`."
  end

  defp reason(true, false, "harness_artifact_only", _behavior_paths, _proof_paths, artifact_path, _artifact_present?) do
    "Behavioral proof is required before publish; add the configured proof artifact at `#{artifact_path}`."
  end

  defp reason(true, false, _mode, behavior_paths, _proof_paths, artifact_path, _artifact_present?) do
    base =
      "Behavioral proof is required before publish for changes in #{Enum.join(behavior_paths, ", ")}; add or update repo-owned tests."

    if artifact_path do
      base <> " You can also emit the configured proof artifact at `#{artifact_path}`."
    else
      base
    end
  end
end
