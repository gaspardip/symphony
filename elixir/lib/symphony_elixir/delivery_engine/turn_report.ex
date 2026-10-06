defmodule SymphonyElixir.DeliveryEngine.TurnReport do
  @moduledoc """
  Owns the delivery turn's reported result and captured runtime errors in the caller process.

  Reset starts the next turn without retaining either channel. A valid report has
  precedence over captured stream errors; invalid reports remain explicit errors.
  Callbacks stay synchronous and preserve the legacy-only worker forwarding rule.
  Execution authority, accounting and delivery transitions remain with their owners.
  """

  alias SymphonyElixir.AgentExecution
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TurnResult

  @report_turn_result_tool "report_agent_turn_result"
  @turn_result_key_prefix :symphony_turn_result
  @turn_runtime_error_key_prefix :symphony_turn_runtime_error
  @agent_turn_error_methods ["codex/event/stream_error", "codex/event/error", "error"]

  @spec reset(Issue.t()) :: :ok
  def reset(issue) do
    Process.delete(turn_result_key(issue))
    Process.delete(turn_runtime_error_key(issue))
    :ok
  end

  @spec fetch(Issue.t()) :: {:ok, TurnResult.t()} | {:error, term()}
  def fetch(issue) do
    case Process.get(turn_result_key(issue)) do
      %TurnResult{} = turn_result ->
        {:ok, turn_result}

      nil ->
        case fetch_turn_runtime_errors(issue) do
          {:ok, reason} -> {:error, {:turn_runtime_error, reason}}
          :error -> {:error, :missing_turn_result}
        end

      {:error, reason} ->
        {:error, {:invalid_turn_result, reason}}

      other ->
        {:error, {:invalid_turn_result, other}}
    end
  end

  @spec tool_executor(Issue.t(), keyword()) :: (String.t() | nil, term() -> map())
  def tool_executor(issue, opts) do
    fn tool, arguments ->
      case tool do
        @report_turn_result_tool ->
          case TurnResult.normalize(arguments) do
            {:ok, turn_result} ->
              Process.put(turn_result_key(issue), turn_result)

              %{
                "success" => true,
                "contentItems" => [%{"type" => "inputText", "text" => "turn result recorded"}]
              }

            {:error, reason} ->
              Process.put(turn_result_key(issue), {:error, reason})

              %{
                "success" => false,
                "contentItems" => [%{"type" => "inputText", "text" => inspect(reason)}]
              }
          end

        _ ->
          DynamicTool.execute(tool, arguments, opts)
      end
    end
  end

  defp turn_result_key(%Issue{id: issue_id}), do: {@turn_result_key_prefix, issue_id}

  defp record_turn_runtime_error(issue, reason) do
    key = turn_runtime_error_key(issue)
    existing = Process.get(key, [])
    Process.put(key, existing ++ [reason])
    :ok
  end

  defp fetch_turn_runtime_errors(issue) do
    case Process.get(turn_runtime_error_key(issue)) do
      errors when is_list(errors) and errors != [] -> {:ok, errors}
      _ -> :error
    end
  end

  defp turn_runtime_error_key(%Issue{id: issue_id}),
    do: {@turn_runtime_error_key_prefix, issue_id}

  @spec message_handler(pid() | nil, Issue.t()) :: (term() -> :ok)
  def message_handler(recipient, issue) do
    fn message ->
      maybe_capture_turn_runtime_error(issue, message)

      if match?({:error, :execution_context_missing}, AgentExecution.current_context()) and is_pid(recipient) and is_binary(issue.id) do
        send(recipient, {:agent_worker_update, issue.id, message})
      end

      :ok
    end
  end

  defp maybe_capture_turn_runtime_error(issue, %{event: :turn_ended_with_error, reason: reason}) do
    record_turn_runtime_error(issue, reason)
  end

  defp maybe_capture_turn_runtime_error(issue, %{
         event: :notification,
         payload: %{"method" => method} = payload
       })
       when method in @agent_turn_error_methods do
    record_turn_runtime_error(
      issue,
      {:agent_notification_error, method, Map.get(payload, "params", %{})}
    )
  end

  defp maybe_capture_turn_runtime_error(_issue, _message), do: :ok
end
