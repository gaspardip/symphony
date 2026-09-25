defmodule SymphonyElixir.DeliveryEngine.TurnEffects do
  @moduledoc """
  Applies local CLI delivery policy after transport returns.

  Delivery prepares successful CLI turns and synthesizes their structured report.
  Verification emits the terminal callback without preparing or synthesizing a
  delivery result. Neither purpose fills progress evidence. Command failure
  propagation remains the existing policy until the separate error-handling change.
  """

  require Logger

  alias SymphonyElixir.AgentProvider.Claude
  alias SymphonyElixir.AgentProvider.CodexCLI

  @doc "Apply the caller's delivery or verifier policy to a completed transport call."
  @spec apply_result(module(), term(), Path.t(), map(), keyword(), :delivery | :verifier) :: term()
  def apply_result(provider, transport_result, workspace, _issue, opts, purpose)
      when is_binary(workspace) and purpose in [:delivery, :verifier] do
    case {cli_profile(provider), transport_result} do
      {nil, _} -> transport_result
      {_profile, {:error, _reason}} -> transport_result
      {profile, result} -> apply_cli_result(profile, result, workspace, opts, purpose)
    end
  end

  defp cli_profile(Claude), do: :claude_cli
  defp cli_profile(CodexCLI), do: :codex_cli
  defp cli_profile(_provider), do: nil

  defp apply_cli_result(profile, transport_result, workspace, opts, purpose) do
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)

    case validate_observation(profile, transport_result) do
      {:ok, result, observation} ->
        try do
          if purpose == :delivery do
            observation =
              if result.result == :turn_completed do
                observation
                |> detect_changed_files(workspace, profile)
                |> maybe_auto_commit(workspace)
              else
                observation
              end

            synthesize_turn_result(observation, Keyword.get(opts, :tool_executor))
          end

          on_message.(%{
            event: :turn_completed,
            timestamp: DateTime.utc_now(),
            payload: %{},
            usage: result.usage
          })

          transport_result
        catch
          kind, reason -> report_error(on_message, {kind, reason})
        end

      {:error, reason} ->
        report_error(on_message, reason)
    end
  end

  defp validate_observation(profile, {:ok, %{result: status, usage: %{}, cli_observation: %{profile: profile, files_touched: paths, result_text: summary, error: _error} = observation} = result})
       when status in [:turn_completed, :turn_failed] and is_list(paths) and
              (is_binary(summary) or is_nil(summary)) do
    if Enum.all?(paths, &is_binary/1), do: {:ok, result, observation}, else: {:error, {:invalid_cli_observation, profile}}
  end

  defp validate_observation(profile, _result), do: {:error, {:invalid_cli_observation, profile}}

  defp report_error(on_message, reason) do
    on_message.(%{
      event: :turn_ended_with_error,
      timestamp: DateTime.utc_now(),
      payload: %{error: inspect(reason)}
    })

    {:error, reason}
  end

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
