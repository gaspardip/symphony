defmodule SymphonyElixir.GitManager do
  @moduledoc """
  Owns branch preparation, commits, pushes, and base-branch resets for delivery runs.
  """

  alias SymphonyElixir.{AuthorProfile, DebugArtifacts, Linear.Issue, Observability}
  alias SymphonyElixir.{AgentExecution, EvidenceAcceptance, RunStateStore}

  @spec prepare_issue_branch(Path.t(), Issue.t() | map(), map() | nil, keyword()) ::
          {:ok, %{branch: String.t(), base_branch: String.t()}} | {:error, term()}
  def prepare_issue_branch(workspace, issue, harness, opts \\ []) when is_binary(workspace) do
    branch = issue_branch_name(issue)
    base_branch = harness_base_branch(harness)
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    with :ok <- ensure_git_checkout(workspace),
         :ok <- git_ok(command_runner, workspace, ["fetch", "origin", "--prune", "refs/heads/#{base_branch}:refs/remotes/origin/#{base_branch}"]),
         :ok <- checkout_branch(command_runner, workspace, branch, base_branch),
         :ok <- git_ok(command_runner, workspace, ["config", "branch.#{branch}.symphony-base-branch", base_branch]) do
      {:ok, %{branch: branch, base_branch: base_branch}}
    end
  end

  @spec commit_all(Path.t(), Issue.t() | map(), String.t(), keyword()) ::
          {:ok, :noop | %{sha: String.t(), message: String.t()}} | {:error, term()} | AgentExecution.terminal()
  def commit_all(workspace, issue, summary, opts \\ [])
      when is_binary(workspace) and is_binary(summary) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    with :ok <- ensure_git_checkout(workspace),
         {:ok, dirty?} <- commit_dirty(command_runner, workspace, opts),
         :ok <- evidence_guard(workspace, opts, :commit),
         {:dirty?, true} <- {:dirty?, dirty?},
         :ok <- git_ok(command_runner, workspace, ["add", "-A"], {opts, :commit}),
         message <- commit_message(issue, summary),
         :ok <- git_ok(command_runner, workspace, ["commit", "-m", message], {opts, :commit}),
         {:ok, sha} <- git_output(command_runner, workspace, ["rev-parse", "HEAD"]) do
      {:ok, %{sha: sha, message: message}}
    else
      {:dirty?, false} -> {:ok, :noop}
      {:error, reason} -> {:error, reason}
      {:stop, _} = terminal -> terminal
    end
  end

  @spec push_branch(Path.t(), String.t(), keyword()) :: :ok | {:error, term()} | AgentExecution.terminal()
  def push_branch(workspace, branch, opts \\ []) when is_binary(workspace) and is_binary(branch) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    git_ok(command_runner, workspace, ["push", "-u", "origin", branch], {opts, :push})
  end

  @spec reset_to_base(Path.t(), map() | nil, keyword()) :: :ok | {:error, term()}
  def reset_to_base(workspace, harness, opts \\ []) when is_binary(workspace) do
    base_branch = harness_base_branch(harness)
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    preserved_state = preserve_runtime_state(workspace)
    remove_runtime_state_from_worktree(preserved_state)

    result =
      with :ok <- ensure_git_checkout(workspace),
           :ok <- git_ok(command_runner, workspace, ["fetch", "origin", "--prune", "refs/heads/#{base_branch}:refs/remotes/origin/#{base_branch}"]),
           :ok <- git_ok(command_runner, workspace, ["checkout", "-f", "-B", base_branch, "origin/#{base_branch}"]),
           :ok <- git_ok(command_runner, workspace, ["reset", "--hard", "origin/#{base_branch}"]) do
        :ok
      end

    case restore_runtime_state(workspace, preserved_state) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec issue_branch_name(Issue.t() | map()) :: String.t()
  def issue_branch_name(%Issue{} = issue), do: issue_branch_name(Map.from_struct(issue))

  def issue_branch_name(issue) when is_map(issue) do
    preferred =
      issue[:branch_name] || issue["branch_name"] || issue[:branchName] || issue["branchName"]

    case preferred do
      value when is_binary(value) and value != "" ->
        sanitize_branch(value)

      _ ->
        identifier = issue[:identifier] || issue["identifier"] || "issue"
        "symphony/#{sanitize_branch(identifier)}"
    end
  end

  defp checkout_branch(command_runner, workspace, branch, base_branch) do
    case command_runner.("git", ["checkout", branch], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} ->
        git_ok(command_runner, workspace, ["reset", "--hard", "origin/#{base_branch}"])

      {_output, _status} ->
        git_ok(command_runner, workspace, ["checkout", "-B", branch, "origin/#{base_branch}"])
    end
  end

  defp ensure_git_checkout(workspace) do
    if File.exists?(Path.join(workspace, ".git")) do
      :ok
    else
      {:error, :missing_checkout}
    end
  end

  defp dirty?(command_runner, workspace) do
    case command_runner.("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp git_output(command_runner, workspace, args) do
    case run_git_command(command_runner, workspace, args) do
      {output, 0} -> {:ok, output |> to_string() |> String.trim()}
      {output, status} -> {:error, {:git_failed, Enum.join(args, " "), status, output}}
    end
  end

  defp git_ok(command_runner, workspace, args, guard \\ nil) do
    case run_git_command(command_runner, workspace, args, guard) do
      {_output, 0} -> :ok
      {:error, _} = error -> error
      {:stop, _} = terminal -> terminal
      {output, status} -> {:error, {:git_failed, Enum.join(args, " "), status, output}}
    end
  end

  defp commit_dirty(command_runner, workspace, opts) do
    if Keyword.has_key?(opts, :evidence_handle) do
      case command_runner.("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output) != ""}
        {_output, status} -> {:error, {:publication_status_failed, status}}
      end
    else
      {:ok, dirty?(command_runner, workspace)}
    end
  end

  defp evidence_guard(workspace, opts, effect) do
    case Keyword.fetch(opts, :evidence_handle) do
      {:ok, handle} ->
        case EvidenceAcceptance.before_effect(workspace, handle, effect) do
          {:error, reason} -> {:error, {:evidence_rejected, reason}}
          outcome -> outcome
        end

      :error ->
        case AgentExecution.current_context() do
          {:error, :execution_context_missing} ->
            :ok

          {:ok, _context} ->
            with {:ok, _current} <- AgentExecution.ensure_current(),
                 do: {:error, {:evidence_rejected, :evidence_handle_required}}
        end
    end
  end

  defp guarded_command(command_runner, workspace, args, nil),
    do: command_runner.("git", args, cd: workspace, stderr_to_stdout: true)

  defp guarded_command(command_runner, workspace, args, {opts, effect}) do
    with :ok <- evidence_guard(workspace, opts, effect),
         do: command_runner.("git", args, cd: workspace, stderr_to_stdout: true)
  end

  defp run_git_command(command_runner, workspace, args, guard \\ nil) do
    metadata = %{
      workspace: workspace,
      command: Enum.join(args, " "),
      stage: current_stage(workspace)
    }

    Observability.with_span("symphony.git.command", metadata, fn ->
      start_time = System.monotonic_time()
      Observability.emit([:symphony, :git, :command, :start], %{count: 1}, metadata)

      result =
        case guarded_command(command_runner, workspace, args, guard) do
          {:error, _} = error ->
            error

          {:stop, _} = terminal ->
            terminal

          {_output, status} = result when status == 0 ->
            result

          {output, _status} = result ->
            case maybe_recover_stale_index_lock(workspace, output) do
              :recovered -> guarded_command(command_runner, workspace, args, guard)
              :no_recovery -> result
            end
        end

      emit_git_command_stop(result, metadata, start_time)
      result
    end)
  end

  defp emit_git_command_stop({:error, _}, metadata, start_time), do: emit_guard_denial(metadata, start_time)
  defp emit_git_command_stop({:stop, _}, metadata, start_time), do: emit_guard_denial(metadata, start_time)

  defp emit_git_command_stop({output, status}, metadata, start_time)
       when is_integer(status) do
    artifact =
      if status != 0 do
        case DebugArtifacts.store_failure("git_command_failure", output, metadata) do
          {:ok, artifact_ref} ->
            Observability.emit_debug_artifact_reference("git_command_failure", artifact_ref, metadata)
            artifact_ref

          _ ->
            nil
        end
      else
        nil
      end

    Observability.emit(
      [:symphony, :git, :command, :stop],
      %{count: 1, duration: System.monotonic_time() - start_time, status: status},
      metadata
      |> Map.put(:outcome, if(status == 0, do: "ok", else: "error"))
      |> Map.put(:artifact_id, artifact && artifact.artifact_id)
    )
  end

  defp emit_guard_denial(metadata, start_time) do
    Observability.emit([:symphony, :git, :command, :stop], %{count: 1, duration: System.monotonic_time() - start_time}, Map.put(metadata, :outcome, "evidence_denied"))
  end

  defp current_stage(workspace) when is_binary(workspace) do
    case RunStateStore.load(workspace) do
      {:ok, %{stage: stage}} when is_binary(stage) -> stage
      _ -> nil
    end
  end

  defp maybe_recover_stale_index_lock(workspace, output) do
    output_text = to_string(output)
    lock_path = Path.join([workspace, ".git", "index.lock"])

    cond do
      not String.contains?(output_text, "index.lock") ->
        :no_recovery

      not File.exists?(lock_path) ->
        :no_recovery

      true ->
        File.rm(lock_path)
        :recovered
    end
  end

  defp preserve_runtime_state(workspace) do
    path = RunStateStore.state_path(workspace)

    if File.exists?(path) do
      %{path: path, contents: File.read!(path)}
    else
      nil
    end
  end

  defp remove_runtime_state_from_worktree(nil), do: :ok

  defp remove_runtime_state_from_worktree(%{path: path}) do
    File.rm(path)
    :ok
  end

  defp restore_runtime_state(_workspace, nil), do: :ok

  defp restore_runtime_state(_workspace, %{path: path, contents: contents}) do
    :ok = File.mkdir_p(Path.dirname(path))
    File.write(path, contents)
  end

  defp commit_message(issue, summary) do
    AuthorProfile.commit_message(issue, sanitized_summary(summary))
  end

  defp sanitized_summary(summary) do
    summary
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 72)
  end

  defp sanitize_branch(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._\/-]+/, "-")
    |> String.trim("-")
  end

  defp harness_base_branch(%{base_branch: value}) when is_binary(value) and value != "", do: value
  defp harness_base_branch(_harness), do: "main"
end
