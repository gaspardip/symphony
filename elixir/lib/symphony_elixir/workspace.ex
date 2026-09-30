defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel agent execution.
  """

  require Logger
  alias SymphonyElixir.AgentExecution
  alias SymphonyElixir.Config
  alias SymphonyElixir.DeployAudit
  alias SymphonyElixir.DispatchAudit
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.RunnerRuntime

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])
  @bootstrap_metadata_entries MapSet.new([".symphony"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      workspace = workspace_path_for_issue(safe_id)

      with :ok <- validate_workspace_path(workspace) do
        RunStateStore.with_readable_snapshot(workspace, fn ->
          with :ok <- DispatchAudit.ensure_workspace_access(workspace),
               {:ok, lifecycle} <- ensure_workspace(workspace) do
            case maybe_run_after_create_hook(workspace, issue_context, lifecycle) do
              :ok ->
                :ok = restore_preserved_workspace_state(workspace, lifecycle)
                {:ok, workspace}

              {:error, _reason} = error ->
                :ok = restore_preserved_workspace_state(workspace, lifecycle)
                error
            end
          end
        end)
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  @spec path_for_issue(map() | String.t() | nil) :: Path.t()
  def path_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)
    safe_id = safe_identifier(issue_context.issue_identifier)
    workspace_path_for_issue(safe_id)
  end

  defp ensure_workspace(workspace) do
    cond do
      blocked_workspace?(workspace) ->
        Logger.info("Cleaning blocked workspace for re-dispatch workspace=#{workspace}")
        File.rm_rf!(workspace)
        create_workspace(workspace)

      bootstrap_only_workspace?(workspace) ->
        prepare_bootstrap_workspace(workspace)

      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, %{after_create?: false, preserved_metadata_dir: nil}}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, %{after_create?: true, preserved_metadata_dir: nil}}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    result =
      with :ok <- ensure_unprotected_workspace(workspace) do
        RunStateStore.with_readable_snapshot(workspace, fn ->
          with :ok <- DispatchAudit.ensure_available(workspace), do: remove_readable_workspace(workspace)
        end)
      end

    case result do
      {:error, reason} -> {:error, reason, ""}
      result -> result
    end
  end

  defp remove_readable_workspace(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok | {:error, term(), String.t()}
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    case remove(workspace) do
      {:ok, _paths} ->
        :ok

      {:error, reason, path} = error ->
        Logger.error("Workspace removal refused workspace=#{path} reason=#{inspect(reason)}")
        error
    end
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()} | AgentExecution.terminal()
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    with {:ok, _context} <- AgentExecution.entry_context(workspace, issue_or_identifier) do
      issue_context = issue_context(issue_or_identifier)

      case Config.workspace_hooks()[:before_run] do
        nil ->
          :ok

        command ->
          run_hook(command, workspace, issue_context, "before_run")
      end
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok | AgentExecution.terminal()
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    with {:ok, _context} <- AgentExecution.entry_context(workspace, issue_or_identifier) do
      issue_context = issue_context(issue_or_identifier)

      case Config.workspace_hooks()[:after_run] do
        nil ->
          :ok

        command ->
          run_hook(command, workspace, issue_context, "after_run")
          |> ignore_hook_failure()
      end
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Path.join(Config.workspace_root(), safe_id)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, %{after_create?: after_create?}) do
    case after_create? do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_after_create_hook(_workspace, _issue_context, _lifecycle), do: :ok

  defp restore_preserved_workspace_state(_workspace, %{preserved_metadata_dir: nil}), do: :ok

  defp restore_preserved_workspace_state(workspace, %{preserved_metadata_dir: preserved_dir})
       when is_binary(preserved_dir) do
    target = Path.join(workspace, ".symphony")

    cond do
      File.dir?(preserved_dir) ->
        merge_preserved_workspace_metadata!(preserved_dir, target)
        :ok

      true ->
        :ok
    end
  end

  defp restore_preserved_workspace_state(_workspace, _lifecycle), do: :ok

  defp merge_preserved_workspace_metadata!(source_dir, target_dir)
       when is_binary(source_dir) and is_binary(target_dir) do
    File.mkdir_p!(target_dir)

    Enum.each(File.ls!(source_dir), fn entry ->
      source = Path.join(source_dir, entry)
      target = Path.join(target_dir, entry)

      cond do
        File.dir?(source) ->
          merge_preserved_workspace_metadata!(source, target)

        true ->
          File.cp!(source, target)
      end
    end)

    File.rm_rf!(source_dir)
  end

  defp blocked_workspace?(workspace) when is_binary(workspace) do
    run_state_path = Path.join([workspace, ".symphony", "run_state.json"])

    with true <- File.dir?(workspace),
         {:ok, payload} <- File.read(run_state_path),
         {:ok, decoded} <- Jason.decode(payload),
         true <- is_map(decoded) do
      Map.get(decoded, "stage") == "blocked"
    else
      _ -> false
    end
  end

  defp bootstrap_only_workspace?(workspace) when is_binary(workspace) do
    case File.ls(workspace) do
      {:ok, entries} ->
        entries != [] and
          Enum.all?(entries, fn entry ->
            MapSet.member?(@bootstrap_metadata_entries, entry) or
              MapSet.member?(@excluded_entries, entry)
          end)

      _ ->
        false
    end
  end

  defp prepare_bootstrap_workspace(workspace) when is_binary(workspace) do
    preserved_dir = Path.join(workspace, ".symphony")

    temp_metadata_dir =
      Path.join(
        Path.dirname(workspace),
        ".#{Path.basename(workspace)}.bootstrap-#{System.unique_integer([:positive])}"
      )

    if File.dir?(preserved_dir) do
      File.rm_rf(temp_metadata_dir)
      File.rename!(preserved_dir, temp_metadata_dir)
    end

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    {:ok, %{after_create?: true, preserved_metadata_dir: if(File.dir?(temp_metadata_dir), do: temp_metadata_dir, else: nil)}}
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    with :ok <- validate_workspace_path(workspace),
         :ok <- DeployAudit.ensure_available(workspace) do
      run_validated_hook(command, workspace, issue_context, hook_name)
    else
      {:error, reason} = error ->
        Logger.error("Workspace hook refused hook=#{hook_name} workspace=#{workspace} reason=#{inspect(reason)}")
        error
    end
  end

  defp run_validated_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        with :ok <- ensure_no_symlink_components(expanded_workspace, root) do
          ensure_unprotected_workspace(expanded_workspace)
        end

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp ensure_unprotected_workspace(workspace) do
    install_root = Config.runner_install_root()

    # Resolve current itself: the informational selected-release path has already
    # normalized parent segments and is not a physical filesystem boundary.
    protected_paths = [install_root, RunnerRuntime.current_checkout_root(), Path.join(install_root, "current")]

    with {:ok, physical_workspace} <- physical_path(workspace),
         {:ok, workspace_ancestors} <- physical_ancestry(physical_workspace) do
      Enum.reduce_while(protected_paths, :ok, fn protected, :ok ->
        with {:ok, physical_protected} <- physical_path(protected),
             {:ok, protected_ancestors} <- physical_ancestry(physical_protected) do
          if paths_overlap?(workspace_ancestors, protected_ancestors) do
            {:halt, {:error, {:workspace_runner_overlap, Path.expand(workspace), physical_protected}}}
          else
            {:cont, :ok}
          end
        else
          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp paths_overlap?(left, right) do
    Enum.any?(left, fn {identity, remaining} ->
      Enum.any?(right, fn {other_identity, other_remaining} ->
        identity == other_identity and
          (Enum.take(remaining, length(other_remaining)) == other_remaining or
             Enum.take(other_remaining, length(remaining)) == remaining)
      end)
    end)
  end

  defp physical_ancestry(path, remaining \\ [], ancestors \\ []) do
    case File.stat(path) do
      {:ok, %File.Stat{major_device: device, inode: inode}}
      when is_integer(device) and is_integer(inode) and inode > 0 ->
        parent_ancestry(path, remaining, [{{device, inode}, remaining} | ancestors])

      {:ok, _stat} ->
        {:error, {:workspace_path_unreadable, path, :identity_unavailable}}

      {:error, :enoent} ->
        parent_ancestry(path, remaining, ancestors)

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp parent_ancestry(path, remaining, ancestors) do
    parent = Path.dirname(path)

    if parent == path do
      {:ok, ancestors}
    else
      physical_ancestry(parent, [Path.basename(path) | remaining], ancestors)
    end
  end

  # Resolve existing ancestors too: workspace.root and protected roots may be
  # aliases, and the workspace itself need not exist before this check.
  defp physical_path(path, links_remaining \\ 40) do
    [root | components] = path |> Path.absname() |> Path.split()
    physical_components(components, root, links_remaining)
  end

  defp physical_components([], resolved, _links_remaining), do: {:ok, resolved}

  defp physical_components([".." | rest], resolved, links_remaining) do
    physical_components(rest, Path.dirname(resolved), links_remaining)
  end

  defp physical_components(["." | rest], resolved, links_remaining) do
    physical_components(rest, resolved, links_remaining)
  end

  defp physical_components([component | rest], resolved, links_remaining) do
    next = Path.join(resolved, component)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} when links_remaining == 0 ->
        {:error, {:workspace_path_unreadable, next, :eloop}}

      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(next) do
          {:ok, target} ->
            physical_path(Path.join([Path.absname(target, Path.dirname(next)) | rest]), links_remaining - 1)

          {:error, reason} ->
            {:error, {:workspace_path_unreadable, next, reason}}
        end

      {:ok, _stat} ->
        physical_components(rest, next, links_remaining)

      {:error, :enoent} ->
        if ".." in rest do
          {:error, {:workspace_path_unreadable, next, :unresolved_parent}}
        else
          {:ok, Path.join([next | rest])}
        end

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, next, reason}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
