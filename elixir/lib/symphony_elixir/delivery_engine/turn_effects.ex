defmodule SymphonyElixir.DeliveryEngine.TurnEffects do
  @moduledoc """
  Existing local CLI turn effects, extracted without changing their policy.

  Claude and CodexCLI still invoke these functions inside their turn catch boundary,
  in the caller process. Their stream structs are retained, as are their distinct
  Git observations, progress fallbacks and currently ignored command failures.
  Moving authorization and effect policy to the engine is a separate change.
  """

  require Logger

  @doc "Observe changed files with the selected CLI adapter's existing Git rules."
  @spec detect_changed_files(map(), Path.t(), :claude_cli | :codex_cli) :: map()
  def detect_changed_files(%{} = state, workspace, :claude_cli) do
    case System.cmd("git", ["diff", "--name-only", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        git_files = output |> String.split("\n", trim: true)

        {untracked, 0} =
          System.cmd("git", ["ls-files", "--others", "--exclude-standard"],
            cd: workspace,
            stderr_to_stdout: true
          )

        new_files = untracked |> String.split("\n", trim: true)
        all_files = Enum.uniq(state.files_touched ++ git_files ++ new_files)
        %{state | files_touched: all_files}

      _ ->
        state
    end
  end

  def detect_changed_files(%{} = state, workspace, :codex_cli) do
    uncommitted =
      case System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.map(fn line -> String.slice(line, 3..-1//1) |> String.trim() end)
          |> Enum.reject(&(&1 == ""))

        _ ->
          []
      end

    branch_diff =
      case System.cmd("git", ["diff", "origin/main", "--name-only"],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.split(output, ~r/\r?\n/, trim: true)
        _ -> []
      end

    Enum.uniq(state.files_touched ++ uncommitted ++ branch_diff)
    |> then(&%{state | files_touched: &1})
  end

  @doc "Apply the existing CLI progress-section fallbacks."
  @spec maybe_patch_progress_file(Path.t(), map()) :: :ok
  def maybe_patch_progress_file(workspace, %{} = state) do
    progress_dir = Path.join(workspace, ".symphony/progress")

    case File.ls(progress_dir) do
      {:ok, files} ->
        Enum.each(files, fn file ->
          if String.ends_with?(file, ".md") do
            path = Path.join(progress_dir, file)
            content = File.read!(path)
            patched = patch_empty_sections(content, state)

            if patched != content do
              File.write!(path, patched)
            end
          end
        end)

      _ ->
        :ok
    end
  end

  defp patch_empty_sections(content, state) do
    summary = state.result_text || "Turn completed."
    files = state.files_touched |> Enum.reject(&(&1 == "")) |> Enum.take(10)

    content
    |> ensure_section_content("Work Log", "- #{summary}")
    |> ensure_section_content("Evidence", files_evidence(files))
  end

  defp ensure_section_content(content, section, fallback) do
    # Match ## Section\n followed by empty lines or next section
    regex = ~r/(## #{Regex.escape(section)}\s*\n)((?:\s*\n)*?)(?=## |\z)/

    case Regex.run(regex, content) do
      [full, header, body] ->
        if String.trim(body) == "" do
          String.replace(content, full, header <> fallback <> "\n\n", global: false)
        else
          content
        end

      _ ->
        content
    end
  end

  defp files_evidence([]), do: "- Changes applied."
  defp files_evidence(files), do: Enum.map_join(files, "\n", &"- `#{&1}`")

  @doc "Apply the existing CLI format and auto-commit sequence."
  @spec maybe_auto_commit(map(), Path.t()) :: map()
  def maybe_auto_commit(%{files_touched: []} = state, _workspace), do: state

  def maybe_auto_commit(%{} = state, workspace) do
    message = state.result_text || "Agent turn completed"

    # Run mix format before committing if elixir dir exists
    elixir_dir = Path.join(workspace, "elixir")

    if File.dir?(elixir_dir) do
      System.cmd("mix", ["format"], cd: elixir_dir, stderr_to_stdout: true)
    end

    case System.cmd("git", ["add", "-A"], cd: workspace, stderr_to_stdout: true) do
      {_, 0} ->
        case System.cmd("git", ["diff", "--cached", "--quiet"], cd: workspace, stderr_to_stdout: true) do
          {_, 0} ->
            state

          {_, 1} ->
            System.cmd("git", ["commit", "-m", message], cd: workspace, stderr_to_stdout: true)
            Logger.info("Auto-committed agent changes in #{workspace}")
            state
        end

      _ ->
        state
    end
  end

  @doc "Synthesize the existing CLI delivery result and invoke its executor synchronously."
  @spec synthesize_turn_result(map(), (String.t(), map() -> term()) | nil) :: map()
  def synthesize_turn_result(%{} = state, tool_executor) do
    summary = state.result_text || "Turn completed."

    files =
      state.files_touched
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    turn_result_data = %{
      "summary" => summary,
      "files_touched" => files,
      "needs_another_turn" => false,
      "blocked" => state.error != nil,
      "blocker_type" => if(state.error, do: "implementation", else: "none")
    }

    if is_function(tool_executor, 2) do
      tool_executor.("report_agent_turn_result", turn_result_data)
    end

    turn_result_data
  end
end
