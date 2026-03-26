defmodule SymphonyElixir.AgentProvider.CommitHelper do
  @moduledoc false

  require Logger

  @type state_like :: %{
          optional(:files_touched) => [String.t()],
          optional(:result_text) => String.t() | nil,
          optional(:error) => term()
        }

  @spec detect_changed_files(state_like(), Path.t()) :: state_like()
  def detect_changed_files(%{} = state, workspace) do
    case System.cmd("git", ["diff", "--name-only", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        git_files = String.split(output, "\n", trim: true)
        new_files = untracked_files(workspace)
        put_files_touched(state, Enum.uniq(files_touched(state) ++ git_files ++ new_files))

      _ ->
        state
    end
  end

  @spec maybe_patch_progress_file(Path.t(), state_like()) :: :ok
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

    :ok
  end

  @spec maybe_auto_commit(state_like(), Path.t()) :: state_like()
  def maybe_auto_commit(%{files_touched: []} = state, _workspace), do: state

  def maybe_auto_commit(%{} = state, workspace) do
    message = Map.get(state, :result_text) || "Agent turn completed"
    maybe_format_elixir_workspace(workspace)

    case System.cmd("git", ["add", "-A"], cd: workspace, stderr_to_stdout: true) do
      {_, 0} ->
        case System.cmd("git", ["diff", "--cached", "--quiet"], cd: workspace, stderr_to_stdout: true) do
          {_, 0} ->
            state

          {_, 1} ->
            case System.cmd("git", ["commit", "-m", message], cd: workspace, stderr_to_stdout: true) do
              {_, 0} ->
                Logger.info("Auto-committed agent changes in #{workspace}")

              _ ->
                :ok
            end

            state

          _ ->
            state
        end

      _ ->
        state
    end
  end

  @spec synthesize_turn_result(state_like(), (String.t(), map() -> map()) | nil) :: map()
  def synthesize_turn_result(%{} = state, tool_executor) do
    turn_result_data = %{
      "summary" => Map.get(state, :result_text) || "Turn completed.",
      "files_touched" => files_touched(state) |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
      "needs_another_turn" => false,
      "blocked" => Map.get(state, :error) != nil,
      "blocker_type" => if(Map.get(state, :error), do: "implementation", else: "none")
    }

    if is_function(tool_executor, 2) do
      tool_executor.("report_agent_turn_result", turn_result_data)
    end

    turn_result_data
  end

  defp maybe_format_elixir_workspace(workspace) do
    elixir_dir = Path.join(workspace, "elixir")

    if File.dir?(elixir_dir) do
      System.cmd("mix", ["format"], cd: elixir_dir, stderr_to_stdout: true)
    end
  end

  defp untracked_files(workspace) do
    case System.cmd("git", ["ls-files", "--others", "--exclude-standard"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  end

  defp patch_empty_sections(content, state) do
    summary = Map.get(state, :result_text) || "Turn completed."
    files = files_touched(state) |> Enum.reject(&(&1 == "")) |> Enum.take(10)

    content
    |> ensure_section_content("Work Log", "- #{summary}")
    |> ensure_section_content("Evidence", files_evidence(files))
  end

  defp ensure_section_content(content, section, fallback) do
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

  defp files_touched(state), do: Map.get(state, :files_touched, [])

  defp put_files_touched(state, files), do: Map.put(state, :files_touched, files)
end
