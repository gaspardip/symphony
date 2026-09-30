defmodule SymphonyElixir.AgentProvider.CodexCLI do
  @moduledoc """
  Agent provider that spawns `codex exec` CLI processes for each turn.

  Uses `codex exec --json` for JSONL streaming, same pattern as the Claude adapter
  but with Codex CLI's event format (thread.started, turn.started, item.completed,
  turn.completed). Returns a transport observation; DeliveryEngine owns local Git
  preparation, delivery synthesis and the final normal callback.
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

    effort = Keyword.get(opts, :effort)

    args =
      [
        "exec",
        "--json",
        "--dangerously-bypass-approvals-and-sandbox",
        "-m",
        model,
        "-C",
        session.workspace
      ]
      |> maybe_add_effort(effort)
      |> Kernel.++([prompt])

    Logger.info("Codex CLI turn starting issue=#{issue_identifier(issue)} model=#{model} workspace=#{session.workspace}")

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
    on_usage = Keyword.get(opts, :on_usage)

    try do
      {exit_result, stream_state} = receive_stream(port, on_message, on_usage, %StreamState{})

      {:ok,
       %{
         result: exit_result,
         session_id: session.session_id,
         usage: stream_state.usage,
         cli_observation: %{
           profile: :codex_cli,
           files_touched: stream_state.files_touched,
           result_text: stream_state.result_text,
           error: stream_state.error
         }
       }}
    catch
      :throw, {:agent_execution_halt, {:stop, {:accounting_uncertain, _}} = terminal} ->
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

  @impl true
  def stop_session(_session), do: :ok

  # -- Stream processing --

  defp receive_stream(port, on_message, on_usage, %StreamState{} = state) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        observe_raw_line(line, on_usage)
        {updated_state, event} = parse_stream_line(line, state)
        if event, do: on_message.(event)
        receive_stream(port, on_message, on_usage, updated_state)

      {^port, {:data, {:noeol, _partial}}} ->
        receive_stream(port, on_message, on_usage, state)

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

  defp observe_raw_line(_line, nil), do: :ok

  defp observe_raw_line(line, on_usage) when is_function(on_usage, 1) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        case on_usage.(payload) do
          {:stop, {:accounting_uncertain, _}} = terminal -> throw({:agent_execution_halt, terminal})
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

  # -- Helpers --

  defp maybe_add_effort(args, effort) when is_binary(effort) and effort != "" do
    args ++ ["-c", "model_reasoning_effort=" <> Jason.encode!(effort)]
  end

  defp maybe_add_effort(args, _effort), do: args

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
