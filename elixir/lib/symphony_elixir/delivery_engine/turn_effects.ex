defmodule SymphonyElixir.DeliveryEngine.TurnEffects do
  @moduledoc """
  Applies local CLI delivery policy after transport returns.

  Delivery prepares successful CLI turns and synthesizes their structured report.
  Verification emits the terminal callback without preparing or synthesizing a
  delivery result. Neither purpose fills progress evidence. Failed commands or report
  executors stop delivery with a structured error; prior effects are not rolled back.

  Accounted callers pass `:effect_guard`, which re-checks execution authority before
  each local Git write. A lost authority stops the remaining effects and is returned
  unchanged. Terminal transport results pass through without local effects.
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
      {_profile, {:stop, _reason}} -> transport_result
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
        outcome =
          try do
            with :ok <- apply_effects(profile, result, observation, workspace, opts, purpose) do
              on_message.(%{
                event: :turn_completed,
                timestamp: DateTime.utc_now(),
                payload: %{},
                usage: result.usage
              })

              transport_result
            end
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        case outcome do
          {:error, reason} -> report_error(on_message, reason)
          result -> result
        end

      {:error, reason} ->
        report_error(on_message, reason)
    end
  end

  defp apply_effects(_profile, _result, _observation, _workspace, _opts, :verifier), do: :ok

  defp apply_effects(profile, result, observation, workspace, opts, :delivery) do
    executor = Keyword.get(opts, :tool_executor)
    guard = Keyword.get(opts, :effect_guard, &unguarded/0)

    with :ok <- validate_executor(executor),
         {:ok, prepared} <- prepare_turn(result.result, observation, workspace, profile, guard),
         {:ok, _report} <- synthesize_turn_result(prepared, executor) do
      :ok
    end
  end

  defp prepare_turn(:turn_failed, observation, _workspace, _profile, _guard), do: {:ok, observation}

  defp prepare_turn(:turn_completed, observation, workspace, profile, guard) do
    with {:ok, observed} <- detect_changed_files(observation, workspace, profile) do
      maybe_auto_commit(observed, workspace, guard)
    end
  end

  # Legacy callers hold no execution authority to re-check.
  defp unguarded, do: :ok

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

  @doc "Observe changed files with the selected CLI profile, preserving command failures."
  @spec detect_changed_files(map(), Path.t(), :claude_cli | :codex_cli) :: {:ok, map()} | {:error, {:turn_effect_failed, map()}}
  def detect_changed_files(%{} = state, workspace, :claude_cli) do
    with {:ok, {output, 0}} <- run_command(:detect_changes, "git", ["diff", "--name-only", "HEAD"], workspace),
         {:ok, {untracked, 0}} <- run_command(:detect_changes, "git", ["ls-files", "--others", "--exclude-standard"], workspace) do
      git_files = String.split(output, "\n", trim: true)
      new_files = String.split(untracked, "\n", trim: true)
      {:ok, %{state | files_touched: Enum.uniq(state.files_touched ++ git_files ++ new_files)}}
    end
  end

  def detect_changed_files(%{} = state, workspace, :codex_cli) do
    with {:ok, {output, 0}} <- run_command(:detect_changes, "git", ["status", "--porcelain"], workspace),
         {:ok, {branch_output, 0}} <- run_command(:detect_changes, "git", ["diff", "origin/main", "--name-only"], workspace) do
      uncommitted =
        output
        |> String.split(~r/\r?\n/, trim: true)
        |> Enum.map(fn line -> String.slice(line, 3..-1//1) |> String.trim() end)
        |> Enum.reject(&(&1 == ""))

      branch_diff = String.split(branch_output, ~r/\r?\n/, trim: true)
      {:ok, %{state | files_touched: Enum.uniq(state.files_touched ++ uncommitted ++ branch_diff)}}
    end
  end

  @doc """
  Format, stage and commit in order; stop on failure without undoing partial effects.

  `guard` runs before each write and must return `:ok`; anything else stops the
  remaining effects and is returned as is.
  """
  def maybe_auto_commit(state, workspace, guard \\ &unguarded/0)

  @spec maybe_auto_commit(map(), Path.t(), (-> :ok | {:discard, atom()} | {:stop, term()})) ::
          {:ok, map()} | {:error, {:turn_effect_failed, map()}} | {:discard, atom()} | {:stop, term()}
  def maybe_auto_commit(%{files_touched: []} = state, _workspace, _guard), do: {:ok, state}

  def maybe_auto_commit(%{} = state, workspace, guard) do
    with :ok <- guard.(),
         :ok <- format_workspace(workspace),
         :ok <- guard.(),
         {:ok, _} <- run_command(:stage, "git", ["add", "-A"], workspace),
         {:ok, {_, status}} <- run_command(:index_diff, "git", ["diff", "--cached", "--quiet"], workspace, [0, 1]),
         :ok <- guard.(),
         :ok <- commit_changes(status, state, workspace) do
      {:ok, state}
    end
  end

  defp format_workspace(workspace) do
    elixir_dir = Path.join(workspace, "elixir")

    if File.dir?(elixir_dir) do
      with {:ok, _} <- run_command(:format, "mix", ["format"], elixir_dir), do: :ok
    else
      :ok
    end
  end

  defp commit_changes(0, _state, _workspace), do: :ok

  defp commit_changes(1, state, workspace) do
    message = state.result_text || "Agent turn completed"

    with {:ok, _} <- run_command(:commit, "git", ["commit", "-m", message], workspace) do
      Logger.info("Auto-committed agent changes in #{workspace}")
      :ok
    end
  end

  defp run_command(step, executable, argv, cwd, accepted_statuses \\ [0]) do
    details = %{step: step, executable: executable, argv: argv, cwd: cwd}

    result =
      try do
        {:ok, System.cmd(executable, argv, cd: cwd, stderr_to_stdout: true)}
      catch
        kind, reason -> {:error, {:command_exception, kind, reason}}
      end

    case result do
      {:ok, {output, status}} ->
        if status in accepted_statuses do
          {:ok, {output, status}}
        else
          effect_error(Map.merge(details, %{reason: {:exit_status, status}, output: output}))
        end

      {:error, reason} ->
        effect_error(Map.put(details, :reason, reason))
    end
  end

  @doc "Synthesize the existing CLI delivery result and invoke its executor synchronously."
  @spec synthesize_turn_result(map(), term()) :: {:ok, map()} | {:error, {:turn_effect_failed, map()}}
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

    with :ok <- validate_executor(tool_executor),
         :ok <- execute_report(tool_executor, turn_result_data) do
      {:ok, turn_result_data}
    end
  end

  defp validate_executor(executor) when is_function(executor, 2), do: :ok
  defp validate_executor(_executor), do: effect_error(%{step: :report_turn_result, reason: :missing_tool_executor})

  defp execute_report(executor, report) do
    result =
      try do
        {:ok, executor.("report_agent_turn_result", report)}
      catch
        kind, reason -> {:error, {:executor_exception, kind, reason}}
      end

    case result do
      {:ok, %{"success" => true}} -> :ok
      {:ok, %{"success" => false} = response} -> effect_error(%{step: :report_turn_result, reason: :tool_rejected, response: response})
      {:ok, response} -> effect_error(%{step: :report_turn_result, reason: :invalid_tool_response, response: response})
      {:error, reason} -> effect_error(%{step: :report_turn_result, reason: reason})
    end
  end

  defp effect_error(details), do: {:error, {:turn_effect_failed, details}}
end
