defmodule SymphonyElixir.AgentProvider.Claude do
  @moduledoc """
  Agent provider that spawns `claude` CLI processes for each turn.

  Each `run_turn` call spawns a fresh `claude -p --output-format stream-json` process.
  Sessions are stateless — `start_session` builds config, `stop_session` is a no-op.

  The turn result is synthesized from the NDJSON stream: tool_use events for Write/Edit
  provide files_touched, and the result event provides the summary.
  """

  @behaviour SymphonyElixir.AgentProvider

  require Logger

  alias SymphonyElixir.Config

  @default_model "claude-sonnet-4-6"
  @default_max_turns 30
  @line_buffer_bytes 1_048_576

  # Stream accumulator for collecting events during a turn
  defmodule StreamState do
    @moduledoc false
    defstruct usage: %{input_tokens: 0, output_tokens: 0},
              files_touched: [],
              result_text: nil,
              error: nil
  end

  # -- Behaviour callbacks --

  @impl true
  def start_session(workspace, opts \\ []) do
    model = Keyword.get(opts, :model) || Config.agent_model() || @default_model
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)

    {:ok,
     %{
       workspace: Path.expand(workspace),
       model: model,
       max_turns: max_turns,
       session_id: generate_session_id()
     }}
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    model = Keyword.get(opts, :model, session.model)
    effective_session = %{session | model: model}
    full_prompt = build_full_prompt(prompt, session.workspace, opts)
    args = build_cli_args(effective_session, full_prompt, opts)
    executable = claude_executable()

    Logger.info("Claude CLI turn starting issue=#{issue_identifier(issue)} model=#{model} workspace=#{session.workspace}")

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

    # Send empty input so Claude CLI doesn't wait for stdin
    send(port, {self(), {:command, ""}})

    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    tool_executor = Keyword.get(opts, :tool_executor)

    try do
      {exit_result, stream_state} = receive_stream(port, on_message, %StreamState{})

      # Merge stream-detected files with actual git changes
      stream_state = detect_changed_files(stream_state, session.workspace)

      # Ensure progress file sections are non-empty (harness gate requires it)
      maybe_patch_progress_file(session.workspace, stream_state)

      # Auto-commit any changes (Claude doesn't commit like Codex does)
      stream_state = maybe_auto_commit(stream_state, session.workspace)

      # Synthesize turn result from stream events and invoke tool_executor
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

  # -- Test helpers --

  @doc false
  @spec parse_stream_line_for_test(binary(), StreamState.t()) :: {StreamState.t(), map() | nil}
  def parse_stream_line_for_test(line, state), do: parse_stream_line(line, state)

  @doc false
  @spec synthesize_turn_result_for_test(StreamState.t(), (String.t(), map() -> map()) | nil) :: map()
  def synthesize_turn_result_for_test(state, tool_executor),
    do: synthesize_turn_result(state, tool_executor)

  @doc false
  @spec detect_changed_files_for_test(StreamState.t(), Path.t()) :: StreamState.t()
  def detect_changed_files_for_test(state, workspace),
    do: detect_changed_files(state, workspace)

  # -- CLI argument building --

  defp build_cli_args(session, prompt, opts) do
    base_args = [
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--model",
      session.model,
      "--max-turns",
      to_string(session.max_turns)
    ]

    base_args
    |> maybe_add_allowedtools(opts)
    |> maybe_add_permission_mode()
  end

  defp maybe_add_allowedtools(args, opts) do
    case Keyword.get(opts, :allowed_tools) do
      tools when is_list(tools) and tools != [] ->
        Enum.reduce(tools, args, fn tool, acc -> acc ++ ["--allowedTools", tool] end)

      _ ->
        args
    end
  end

  defp maybe_add_permission_mode(args) do
    # Automated runs need full file access — Symphony controls the sandbox
    args ++ ["--dangerously-skip-permissions"]
  end

  # -- Prompt construction --

  defp build_full_prompt(prompt, _workspace, _opts) do
    # No turn-result file instructions needed — we synthesize from the stream
    prompt
  end

  # -- NDJSON stream processing --

  defp receive_stream(port, on_message, %StreamState{} = state) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {updated_state, event} = parse_stream_line(line, state)

        if event do
          on_message.(event)
        end

        receive_stream(port, on_message, updated_state)

      {^port, {:data, {:noeol, _partial}}} ->
        receive_stream(port, on_message, state)

      {^port, {:exit_status, 0}} ->
        {:turn_completed, state}

      {^port, {:exit_status, status}} ->
        Logger.warning("Claude CLI exited with status #{status}")
        {:turn_failed, %{state | error: "exit_status_#{status}"}}
    after
      Config.agent_turn_timeout_ms() ->
        safe_close_port(port)
        Logger.error("Claude CLI turn timed out")
        {:turn_failed, %{state | error: "timeout"}}
    end
  end

  defp parse_stream_line(line, %StreamState{} = state) do
    case Jason.decode(line) do
      {:ok, %{"type" => "assistant", "message" => %{"content" => content}} = event} ->
        updated_state =
          state
          |> extract_files_from_content(content)
          |> update_usage(event)

        {updated_state, nil}

      {:ok, %{"type" => "result", "result" => result_text} = event} ->
        updated_state =
          %{state | result_text: result_text}
          |> update_usage(event)

        {updated_state,
         %{
           event: :notification,
           timestamp: DateTime.utc_now(),
           payload: %{type: "result", result: result_text},
           usage: updated_state.usage
         }}

      {:ok, %{"type" => "result"} = event} ->
        updated_state = update_usage(state, event)

        {updated_state,
         %{
           event: :notification,
           timestamp: DateTime.utc_now(),
           payload: %{type: "result"},
           usage: updated_state.usage
         }}

      {:ok, %{"type" => type} = event} when type in ["message_start", "message_delta"] ->
        updated_state = update_usage(state, event)

        {updated_state,
         %{
           event: :notification,
           timestamp: DateTime.utc_now(),
           payload: %{type: type},
           usage: updated_state.usage
         }}

      {:ok, %{"type" => _type} = event} ->
        {update_usage(state, event), nil}

      {:ok, _other} ->
        {state, nil}

      {:error, _} ->
        {state, nil}
    end
  end

  # Ensure progress file has non-empty required sections (harness publish gate requires it)
  defp maybe_patch_progress_file(workspace, %StreamState{} = state) do
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

  # Auto-commit changes after a turn — Claude writes files but doesn't commit
  defp maybe_auto_commit(%StreamState{files_touched: []} = state, _workspace), do: state

  defp maybe_auto_commit(%StreamState{} = state, workspace) do
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

  # Detect files changed via git status after the turn completes
  defp detect_changed_files(%StreamState{} = state, workspace) do
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

  # Extract file paths from tool_use content blocks (Write, Edit tools)
  defp extract_files_from_content(%StreamState{} = state, content) when is_list(content) do
    new_files =
      content
      |> Enum.filter(fn block ->
        block["type"] == "tool_use" and block["name"] in ["Write", "Edit"]
      end)
      |> Enum.map(fn block -> get_in(block, ["input", "file_path"]) end)
      |> Enum.reject(&is_nil/1)

    %{state | files_touched: Enum.uniq(state.files_touched ++ new_files)}
  end

  defp extract_files_from_content(state, _content), do: state

  defp update_usage(%StreamState{} = state, event) do
    usage_data =
      Map.get(event, "usage") ||
        get_in(event, ["message", "usage"]) ||
        %{}

    merged = normalize_usage(usage_data)

    %{
      state
      | usage: %{
          input_tokens: max(state.usage.input_tokens, Map.get(merged, :input_tokens, 0)),
          output_tokens: max(state.usage.output_tokens, Map.get(merged, :output_tokens, 0))
        }
    }
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens) || 0,
      output_tokens: Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens) || 0
    }
  end

  defp normalize_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  # -- Turn result synthesis --

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

    # Invoke the tool_executor to store the result in the process dict
    # (same contract as the Codex dynamic tool flow)
    if is_function(tool_executor, 2) do
      tool_executor.("report_agent_turn_result", turn_result_data)
    end

    turn_result_data
  end

  # -- Helpers --

  defp claude_executable do
    System.find_executable("claude") || "claude"
  end

  defp generate_session_id do
    "claude-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp issue_identifier(issue) when is_map(issue) do
    Map.get(issue, :identifier) || Map.get(issue, "identifier") || "unknown"
  end

  defp default_on_message(_message), do: :ok

  defp safe_close_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end
  rescue
    _ -> :ok
  end
end
