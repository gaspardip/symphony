defmodule SymphonyElixir.AgentProvider.Claude do
  @moduledoc """
  Agent provider that spawns `claude` CLI processes for each turn.

  Each `run_turn` call spawns a fresh `claude -p --output-format stream-json` process.
  Sessions are stateless — `start_session` builds config, `stop_session` is a no-op.

  The returned observation comes from the NDJSON stream: Write/Edit events provide
  files_touched and the result event provides the summary. DeliveryEngine owns local
  Git preparation, delivery synthesis and the final normal callback.
  """

  @behaviour SymphonyElixir.AgentProvider

  require Logger

  alias SymphonyElixir.{Config, ProviderTransport}
  alias SymphonyElixir.DeliveryEngine.TurnEffects

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
    with {:ok, boundary} <- Config.provider_execution_boundary() do
      model = Keyword.get(opts, :model) || Config.agent_model() || @default_model
      max_turns = Keyword.get(opts, :max_turns, @default_max_turns)

      {:ok,
       %{
         workspace: Path.expand(workspace),
         provider_boundary: boundary,
         model: model,
         max_turns: max_turns,
         session_id: generate_session_id()
       }}
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    case session.provider_boundary do
      :legacy -> legacy_run_turn(session, prompt, issue, opts)
      selection -> selected_run_turn(session, prompt, issue, opts, selection)
    end
  end

  defp legacy_run_turn(session, prompt, issue, opts) do
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
    on_usage = Keyword.get(opts, :on_usage)

    try do
      {exit_result, stream_state} = receive_stream(port, on_message, on_usage, %StreamState{})

      {:ok,
       %{
         result: exit_result,
         session_id: session.session_id,
         usage: stream_state.usage,
         cli_observation: %{
           profile: :claude_cli,
           files_touched: stream_state.files_touched,
           result_text: stream_state.result_text,
           error: stream_state.error
         }
       }}
    catch
      :throw, {:agent_execution_halt, {:stop, _} = terminal} ->
        safe_close_port(port)
        terminal

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

  defp selected_run_turn(session, prompt, _issue, opts, selection) do
    started_at = System.monotonic_time(:millisecond)
    model = Keyword.get(opts, :model, session.model)
    prompt = build_full_prompt(prompt, session.workspace, opts)
    args = build_cli_args(%{session | model: model}, prompt, opts)
    executable = claude_executable()
    launch = %{provider: "claude", command: {:exec, executable, args}, started_at: started_at}

    with {:ok, handle, _identity} <- ProviderTransport.open(session.workspace, launch, selection) do
      on_message = Keyword.get(opts, :on_message, &default_on_message/1)
      on_usage = Keyword.get(opts, :on_usage)

      ProviderTransport.with_cleanup(
        fn ->
          try do
            case receive_selected(handle, on_message, on_usage, %StreamState{}) do
              {:error, _} = error ->
                error

              {result, state} ->
                {:ok,
                 %{
                   result: result,
                   session_id: session.session_id,
                   usage: state.usage,
                   cli_observation: %{profile: :claude_cli, files_touched: state.files_touched, result_text: state.result_text, error: state.error}
                 }}
            end
          catch
            :throw, {:agent_execution_halt, {:stop, _} = terminal} ->
              terminal

            kind, reason ->
              on_message.(%{event: :turn_ended_with_error, timestamp: DateTime.utc_now(), payload: %{error: "selected_provider_turn_failed"}})
              {:error, {kind, reason}}
          end
        end,
        fn -> ProviderTransport.close(handle) end
      )
    end
  end

  defp receive_selected(handle, on_message, on_usage, state) do
    case ProviderTransport.recv(handle, Config.agent_turn_timeout_ms()) do
      {:data, {:eol, line}} ->
        observe_raw_line(line, on_usage)
        {state, event} = parse_stream_line(line, state)
        if event, do: on_message.(event)
        receive_selected(handle, on_message, on_usage, state)

      {:data, {:noeol, _partial}} ->
        {:error, :provider_line_limit}

      {:stderr, bytes} ->
        Logger.debug("Selected provider stderr bytes=#{byte_size(bytes)}")
        receive_selected(handle, on_message, on_usage, state)

      {:exit_status, 0} ->
        {:turn_completed, state}

      {:exit_status, status} ->
        {:turn_failed, %{state | error: "exit_status_#{status}"}}

      {:transport_error, reason} ->
        {:error, {:provider_transport_error, reason}}

      :timeout ->
        {:error, :provider_turn_timeout}
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  # -- Test helpers --

  @doc false
  @spec parse_stream_line_for_test(binary(), StreamState.t()) :: {StreamState.t(), map() | nil}
  def parse_stream_line_for_test(line, state), do: parse_stream_line(line, state)

  @doc false
  @spec synthesize_turn_result_for_test(StreamState.t(), term()) :: {:ok, map()} | {:error, {:turn_effect_failed, map()}}
  def synthesize_turn_result_for_test(state, tool_executor),
    do: TurnEffects.synthesize_turn_result(state, tool_executor)

  @doc false
  @spec detect_changed_files_for_test(StreamState.t(), Path.t()) :: {:ok, StreamState.t()} | {:error, {:turn_effect_failed, map()}}
  def detect_changed_files_for_test(state, workspace),
    do: TurnEffects.detect_changed_files(state, workspace, :claude_cli)

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

  defp receive_stream(port, on_message, on_usage, %StreamState{} = state) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        observe_raw_line(line, on_usage)
        {updated_state, event} = parse_stream_line(line, state)

        if event do
          on_message.(event)
        end

        receive_stream(port, on_message, on_usage, updated_state)

      {^port, {:data, {:noeol, _partial}}} ->
        receive_stream(port, on_message, on_usage, state)

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

  defp observe_raw_line(_line, nil), do: :ok

  defp observe_raw_line(line, on_usage) when is_function(on_usage, 1) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        case on_usage.(payload) do
          {:stop, {kind, _}} = terminal when kind in [:accounting_uncertain, :execution_stopped] -> throw({:agent_execution_halt, terminal})
          {:stop, {:stale_execution, _, _}} = terminal -> throw({:agent_execution_halt, terminal})
          result -> result
        end

      {:ok, _payload} ->
        :ok

      {:error, _reason} ->
        :ok
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
