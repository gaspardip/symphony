defmodule SymphonyElixir.UiProof do
  @moduledoc """
  Evaluates repo-declared UI proof requirements for UI-affecting diffs.

  The runtime decides whether UI proof is required from changed paths and harness
  configuration. Local proof is enforced during verification; CI/external proof
  can be deferred to the PR-check stage when it depends on post-publish checks.
  """

  alias SymphonyElixir.RunInspector

  defmodule Result do
    @moduledoc false

    defstruct [
      :mode,
      :reason,
      :provider,
      :command,
      :command_result,
      :check_state,
      :external_result_url,
      required?: false,
      verify_required?: false,
      verify_satisfied?: true,
      merge_required?: false,
      merge_satisfied?: true,
      deferred?: false,
      changed_ui_paths: [],
      proof_paths: [],
      artifact_paths: [],
      artifact_matches: %{},
      required_checks: [],
      missing_checks: [],
      pending_checks: [],
      failed_checks: [],
      cancelled_checks: []
    ]
  end

  @doc_extensions ~w(.md .markdown .rst .adoc .txt)
  @config_extensions ~w(.json .yaml .yml .toml .ini .cfg .xcconfig .plist .pbxproj .xcscheme .gitignore)
  @config_filenames ~w(Dockerfile Makefile Podfile Podfile.lock Package.swift package.json package-lock.json yarn.lock pnpm-lock.yaml)
  @default_ui_source_markers [
    "/views/",
    "/view/",
    "/components/",
    "/component/",
    "/screens/",
    "/pages/",
    "/ui/",
    "/widgets/"
  ]
  @default_ui_test_markers ["/uitests/", "/ui-tests/", "/e2e/", "__snapshots__/"]

  @spec evaluate(Path.t(), map() | nil, [String.t()], RunInspector.snapshot(), keyword()) :: Result.t()
  def evaluate(workspace, harness, changed_paths, inspection, opts \\ [])
      when is_binary(workspace) and is_list(changed_paths) do
    config = proof_config(harness)
    mode = Map.get(config, :mode) || "local"
    changed_paths = Enum.map(changed_paths, &normalize_path/1) |> Enum.reject(&(&1 == ""))
    changed_ui_paths = Enum.filter(changed_paths, &ui_source_path?(&1, config))
    proof_paths = Enum.filter(changed_paths, &ui_test_path?(&1, config))
    required? = Map.get(config, :required, true) and changed_ui_paths != []

    local_result =
      if required? and mode in ["local", "hybrid"] do
        run_local_proof(workspace, config, proof_paths, opts)
      else
        %{command_result: nil, local_satisfied?: proof_paths != []}
      end

    required_checks = Map.get(config, :required_checks, [])
    check_rollup = ui_check_rollup(required_checks, inspection)
    merge_required? = required? and mode in ["ci_check", "external_service", "hybrid"] and required_checks != []
    merge_satisfied? = not merge_required? or check_rollup.state == :passed
    verify_required? = required? and mode in ["local", "hybrid"]
    verify_satisfied? = not verify_required? or local_result.local_satisfied?
    deferred? = required? and merge_required? and is_nil(inspection.pr_url)

    artifact_matches = artifact_matches(workspace, Map.get(config, :artifact_paths, []))

    %Result{
      required?: required?,
      verify_required?: verify_required?,
      verify_satisfied?: verify_satisfied?,
      merge_required?: merge_required?,
      merge_satisfied?: merge_satisfied?,
      deferred?: deferred?,
      mode: mode,
      reason:
        reason(
          required?,
          verify_required?,
          verify_satisfied?,
          merge_required?,
          merge_satisfied?,
          deferred?,
          changed_ui_paths,
          proof_paths,
          config,
          check_rollup
        ),
      provider: Map.get(config, :provider),
      command: Map.get(config, :command),
      command_result: local_result.command_result,
      check_state: check_rollup.state,
      external_result_url: build_result_url(inspection.pr_url, config),
      changed_ui_paths: changed_ui_paths,
      proof_paths: proof_paths,
      artifact_paths: Map.get(config, :artifact_paths, []),
      artifact_matches: artifact_matches,
      required_checks: required_checks,
      missing_checks: check_rollup.missing,
      pending_checks: check_rollup.pending,
      failed_checks: check_rollup.failed,
      cancelled_checks: check_rollup.cancelled
    }
  end

  @spec to_map(Result.t()) :: map()
  def to_map(%Result{} = result) do
    %{
      required: result.required?,
      verify_required: result.verify_required?,
      verify_satisfied: result.verify_satisfied?,
      merge_required: result.merge_required?,
      merge_satisfied: result.merge_satisfied?,
      deferred: result.deferred?,
      mode: result.mode,
      reason: result.reason,
      provider: result.provider,
      command: result.command,
      command_result: command_result_to_map(result.command_result),
      check_state: result.check_state,
      external_result_url: result.external_result_url,
      changed_ui_paths: result.changed_ui_paths,
      proof_paths: result.proof_paths,
      artifact_paths: result.artifact_paths,
      artifact_matches: result.artifact_matches,
      required_checks: result.required_checks,
      missing_checks: result.missing_checks,
      pending_checks: result.pending_checks,
      failed_checks: result.failed_checks,
      cancelled_checks: result.cancelled_checks
    }
  end

  defp proof_config(%{ui_proof: %{} = config}), do: config

  defp proof_config(_harness) do
    %{
      required: true,
      mode: "local",
      source_paths: [],
      test_paths: [],
      artifact_paths: [],
      required_checks: [],
      command: nil,
      provider: nil,
      result_url_pattern: nil,
      scenarios: []
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

  defp ui_source_path?(path, config) do
    not docs_or_config_path?(path) and
      not ui_test_path?(path, config) and
      source_path_match?(path, Map.get(config, :source_paths, []))
  end

  defp ui_test_path?(path, config) do
    test_paths = Map.get(config, :test_paths, [])

    if test_paths == [] do
      default_ui_test_path?(path)
    else
      path_matches_any_prefix?(path, test_paths)
    end
  end

  defp source_path_match?(path, []), do: default_ui_source_path?(path)
  defp source_path_match?(path, source_paths), do: path_matches_any_prefix?(path, source_paths)

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

  defp default_ui_source_path?(path) do
    downcased = "/" <> String.downcase(path)

    Enum.any?(@default_ui_source_markers, &String.contains?(downcased, &1)) or
      String.ends_with?(downcased, ".storyboard") or
      String.ends_with?(downcased, ".xib") or
      String.ends_with?(downcased, ".tsx") or
      String.ends_with?(downcased, ".jsx")
  end

  defp default_ui_test_path?(path) do
    downcased = "/" <> String.downcase(path)
    Enum.any?(@default_ui_test_markers, &String.contains?(downcased, &1))
  end

  defp path_matches_any_prefix?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      normalized = normalize_path(prefix)
      path == normalized or String.starts_with?(path, normalized <> "/")
    end)
  end

  defp run_local_proof(workspace, config, proof_paths, opts) do
    artifact_ok? = artifacts_satisfied?(workspace, Map.get(config, :artifact_paths, []))
    command = Map.get(config, :command)

    command_result =
      if is_binary(command) do
        RunInspector.run_shell_command(workspace, command, opts)
      else
        nil
      end

    command_ok? =
      case command_result do
        nil -> false
        %{status: :passed} -> true
        _ -> false
      end

    local_satisfied? =
      proof_paths != [] or
        artifact_ok? or
        (command_ok? and Map.get(config, :artifact_paths, []) == [])

    %{command_result: command_result, local_satisfied?: local_satisfied?}
  end

  defp artifacts_satisfied?(_workspace, []), do: false

  defp artifacts_satisfied?(workspace, artifact_paths) do
    Enum.all?(artifact_paths, fn artifact_path ->
      workspace
      |> Path.join(artifact_path)
      |> wildcard_or_exists?()
    end)
  end

  defp artifact_matches(_workspace, []), do: %{}

  defp artifact_matches(workspace, artifact_paths) do
    Map.new(artifact_paths, fn artifact_path ->
      full = Path.join(workspace, artifact_path)

      matches =
        if String.contains?(artifact_path, "*") or String.contains?(artifact_path, "?") do
          Path.wildcard(full)
        else
          if File.exists?(full), do: [full], else: []
        end

      {artifact_path, matches}
    end)
  end

  defp wildcard_or_exists?(full_path) do
    if String.contains?(full_path, "*") or String.contains?(full_path, "?") do
      Path.wildcard(full_path) != []
    else
      File.exists?(full_path)
    end
  end

  defp ui_check_rollup([], _inspection) do
    %{state: :passed, missing: [], pending: [], failed: [], cancelled: []}
  end

  defp ui_check_rollup(required_checks, inspection) do
    RunInspector.required_checks_rollup(required_checks, Map.get(inspection, :check_statuses, []))
  end

  defp build_result_url(nil, _config), do: nil
  defp build_result_url(_pr_url, %{result_url_pattern: nil}), do: nil

  defp build_result_url(pr_url, config) do
    result_url_pattern = Map.get(config, :result_url_pattern)
    provider = Map.get(config, :provider)

    result_url_pattern
    |> to_string()
    |> String.replace("{pr_url}", pr_url)
    |> String.replace("{provider}", to_string(provider || ""))
  end

  defp reason(false, _verify_required?, _verify_satisfied?, _merge_required?, _merge_satisfied?, _deferred?, [], _proof_paths, _config, _check_rollup) do
    "No UI-affecting source files were modified, so UI proof is not required."
  end

  defp reason(true, true, false, _merge_required?, _merge_satisfied?, _deferred?, changed_ui_paths, _proof_paths, config, _check_rollup) do
    command_hint =
      case Map.get(config, :command) do
        nil -> ""
        command -> " Run the configured UI proof command `#{command}` or add UI tests/artifacts."
      end

    "UI proof is required before publish for changes in #{Enum.join(changed_ui_paths, ", ")}.#{command_hint}"
  end

  defp reason(true, false, true, true, false, true, _changed_ui_paths, _proof_paths, config, _check_rollup) do
    "UI proof is deferred until PR checks are available. Symphony will require #{Enum.join(Map.get(config, :required_checks, []), ", ")} before merge."
  end

  defp reason(true, _verify_required?, true, true, false, false, _changed_ui_paths, _proof_paths, config, check_rollup) do
    cond do
      check_rollup.failed != [] ->
        "UI proof checks failed: #{Enum.join(check_rollup.failed, ", ")}."

      check_rollup.cancelled != [] ->
        "UI proof checks were cancelled: #{Enum.join(check_rollup.cancelled, ", ")}."

      check_rollup.missing != [] ->
        "UI proof checks are missing: #{Enum.join(check_rollup.missing, ", ")}."

      check_rollup.pending != [] ->
        "UI proof checks are still pending: #{Enum.join(check_rollup.pending, ", ")}."

      true ->
        "UI proof is waiting on the configured PR checks: #{Enum.join(Map.get(config, :required_checks, []), ", ")}."
    end
  end

  defp reason(true, _verify_required?, true, merge_required?, merge_satisfied?, _deferred?, _changed_ui_paths, proof_paths, config, _check_rollup) do
    local_part =
      cond do
        proof_paths != [] ->
          "UI proof is satisfied by changed proof files: #{Enum.join(proof_paths, ", ")}."

        Map.get(config, :artifact_paths, []) != [] ->
          "UI proof artifacts were produced successfully."

        is_binary(Map.get(config, :command)) ->
          "UI proof command completed successfully."

        true ->
          "UI proof is satisfied."
      end

    if merge_required? and merge_satisfied? do
      local_part <> " Required UI checks are green."
    else
      local_part
    end
  end

  defp command_result_to_map(nil), do: nil

  defp command_result_to_map(result) when is_map(result) do
    %{
      status: Map.get(result, :status),
      command: Map.get(result, :command),
      output: String.slice(to_string(Map.get(result, :output, "")), 0, 1_000)
    }
  end
end
