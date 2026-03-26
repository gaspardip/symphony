defmodule SymphonyElixir.AgentProvider.CodexCLI do
  @moduledoc """
  Agent provider that spawns `codex exec` CLI processes for each turn.

  Uses `codex exec --json` for JSONL streaming, same pattern as the Claude adapter
  but with Codex CLI's event format (thread.started, turn.started, item.completed,
  turn.completed).
  """

  @behaviour SymphonyElixir.AgentProvider

  require Logger

  alias SymphonyElixir.Config

  @default_model "gpt-5.4"
  @default_max_turns 30
  @line_buffer_bytes 1_048_576

  defmodule StreamState do
    @moduledoc false
    defstruct usage: %{input_tokens: 0, output_tokens: 0},
              files_touched: [],
              result_text: nil,
              error: nil
  end

  @impl true
  def start_session(workspace, opts \\ []) do
    model = Keyword.get(opts, :model) || Config.agent_model() || @default_model

    {:ok,
     %{
       workspace: Path.expand(workspace),
       model: model,
       max_turns: Keyword.get(opts, :max_turns, @default_max_turns),
       session_id: generate_session_id()
     }}
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    model = Keyword.get(opts, :model, session.model)
    executable = codex_executable()

    args = [
      "exec",
      "--json",
      "--dangerously-bypass-approvals-and-sandbox",
      "-m",
      model,
      "-C",
      session.workspace,
      prompt
    ]

    Logger.info(
      "Codex CLI turn starting issue=#{issue_identifier(issue)} model=#{model} workspace=#{session.workspace}"
    )

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          {:args, args},
          {:cd, session.workspace},
          {:line, @line_buffer_bytes}
        ]
      )

    send(port, {self(), {:command, ""}})

    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    tool_executor = Keyword.get(opts, :tool_executor)

    try do
      {exit_result, stream_state} = receive_stream(port, on_message, %StreamState{})

      stream_state = detect_changed_files(stream_state, session.workspace)
      maybe_patch_progress_file(session.workspace, stream_state)
      stream_state = maybe_auto_commit(stream_state, session.workspace)

      synthesize_turn_result(stream_state, tool_executor)

      on_message.(%{
        event: :turn_completed,
        timestamp: DateTime.utc_now(),
        payload: %{},
        usage: stream_state.usage
      })

      {:ok,
       %{
         result: exit_result,
         session_id: session.session_id,
         usage: stream_state.usage
       }}
    catch
      kind, reason ->
        safe_close_port(port)

        on_message.(%{
          event: :turn_ended_with_error,
          timestamp: DateTime.utc_now(),
          payload: %{error: inspect({kind, reason})}
        })

        {:error, {kind, reason}}
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  # -- Stream processing --

  defp receive_stream(port, on_message, %StreamState{} = state) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {updated_state, event} = parse_stream_line(line, state)
        if event, do: on_message.(event)
        receive_stream(port, on_message, updated_state)

      {^port, {:data, {:noeol, _partial}}} ->
        receive_stream(port, on_message, state)

      {^port, {:exit_status, 0}} ->
        {:turn_completed, state}

      {^port, {:exit_status, status}} ->
        Logger.warning("Codex CLI exited with status #{status}")
        {:turn_failed, %{state | error: "exit_status_#{status}"}}
    after
      Config.agent_turn_timeout_ms() ->
        safe_close_port(port)
        Logger.error("Codex CLI turn timed out")
        {:turn_failed, %{state | error: "timeout"}}
    end
  end

  defp parse_stream_line(line, %StreamState{} = state) do
    case Jason.decode(line) do
      {:ok, %{"type" => "item.completed", "item" => item}} ->
        state = extract_files_from_item(state, item)

        text =
          case item do
            %{"type" => "agent_message", "text" => text} -> text
            _ -> nil
          end

        state = if text, do: %{state | result_text: text}, else: state
        {state, nil}

      {:ok, %{"type" => "turn.completed", "usage" => usage}} ->
        updated = %{
          state
          | usage: %{
              input_tokens: max(state.usage.input_tokens, Map.get(usage, "input_tokens", 0)),
              output_tokens: max(state.usage.output_tokens, Map.get(usage, "output_tokens", 0))
            }
        }

        {updated,
         %{
           event: :notification,
           timestamp: DateTime.utc_now(),
           payload: %{type: "turn.completed"},
           usage: updated.usage
         }}

      {:ok, %{"type" => _type}} ->
        {state, nil}

      {:ok, _} ->
        {state, nil}

      {:error, _} ->
        {state, nil}
    end
  end

  defp extract_files_from_item(%StreamState{} = state, %{"type" => "tool_use"} = item) do
    name = Map.get(item, "name", "")
    input = Map.get(item, "input", %{})

    if name in ["write_file", "edit_file", "Write", "Edit"] do
      path = Map.get(input, "file_path") || Map.get(input, "path", "")

      if path != "" do
        %{state | files_touched: Enum.uniq(state.files_touched ++ [path])}
      else
        state
      end
    else
      state
    end
  end

  defp extract_files_from_item(state, _item), do: state

  # -- Shared helpers (same as Claude adapter) --

  defp detect_changed_files(%StreamState{} = state, workspace) do
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

  defp maybe_auto_commit(%StreamState{files_touched: []} = state, _workspace), do: state

  defp maybe_auto_commit(%StreamState{} = state, workspace) do
    message = state.result_text || "Agent turn completed"

    elixir_dir = Path.join(workspace, "elixir")
    if File.dir?(elixir_dir), do: System.cmd("mix", ["format"], cd: elixir_dir, stderr_to_stdout: true)

    case System.cmd("git", ["add", "-A"], cd: workspace, stderr_to_stdout: true) do
      {_, 0} ->
        case System.cmd("git", ["diff", "--cached", "--quiet"],
               cd: workspace,
               stderr_to_stdout: true
             ) do
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

  defp maybe_patch_progress_file(workspace, %StreamState{} = state) do
    progress_dir = Path.join(workspace, ".symphony/progress")

    case File.ls(progress_dir) do
      {:ok, files} ->
        Enum.each(files, fn file ->
          if String.ends_with?(file, ".md") do
            path = Path.join(progress_dir, file)
            content = File.read!(path)
            patched = patch_empty_sections(content, state)
            if patched != content, do: File.write!(path, patched)
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
    regex = ~r/(## #{Regex.escape(section)}\s*\n)((?:\s*\n)*?)(?=## |\z)/

    case Regex.run(regex, content) do
      [full, header, body] ->
        if String.trim(body) == "",
          do: String.replace(content, full, header <> fallback <> "\n\n", global: false),
          else: content

      _ ->
        content
    end
  end

  defp files_evidence([]), do: "- Changes applied."
  defp files_evidence(files), do: Enum.map_join(files, "\n", &"- `#{&1}`")

  defp synthesize_turn_result(%StreamState{} = state, tool_executor) do
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

  # -- Helpers --

  defp codex_executable, do: System.find_executable("codex") || "codex"

  defp generate_session_id do
    "codex-cli-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp issue_identifier(issue) when is_map(issue) do
    Map.get(issue, :identifier) || Map.get(issue, "identifier") || "unknown"
  end

  defp default_on_message(_message), do: :ok

  defp safe_close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  rescue
    _ -> :ok
  end
end
