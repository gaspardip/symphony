defmodule SymphonyElixir.ExecutionBoundary do
  @moduledoc """
  Explicit macOS boundary for selected harness and provider processes.
  Host callbacks and publication remain outside the selected child process boundary.
  A missing selection preserves historical execution; every selected-policy failure is explicit.
  """
  import Bitwise
  alias SymphonyElixir.{Config, OwnedHook}

  @source Path.expand("../../c_src/execution_boundary.c", __DIR__)
  @external_resource @source
  @build_path Path.join(Mix.Project.build_path(), "native/symphony-execution-boundary")
  @native File.read!(@build_path)
  @digest :crypto.hash(:sha256, @native)
  @platform {:os.type(), :erlang.system_info(:system_architecture)}
  @system_reads ["/usr/lib", "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld"]
  @broad_roots ["/", "/Users", "/private", "/private/tmp", "/tmp", "/var", "/usr", "/bin", "/usr/bin", "/System", "/Volumes"]

  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__? do
    case File.read(@build_path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) != @digest
      {:error, _reason} -> true
    end
  end

  @spec run(Path.t(), String.t(), keyword()) :: :legacy | {:ok, {binary(), non_neg_integer()}} | {:error, term()}
  def run(workspace, command, opts \\ []) when is_binary(workspace) and is_binary(command) do
    started = now()

    case Config.execution_boundary() do
      {:ok, :legacy} ->
        :legacy

      {:error, reason} ->
        {:error, reason}

      {:ok, selection} ->
        if Keyword.has_key?(opts, :shell_runner) or Keyword.has_key?(opts, :env) do
          {:error, :execution_boundary_override_forbidden}
        else
          if String.valid?(command) and not String.contains?(command, <<0>>),
            do: OwnedHook.run_boundary(command, workspace, selection, started + selection.timeout_ms),
            else: {:error, :invalid_boundary_command}
        end
    end
  end

  # Called only by the existing hook custodian, so preparation and teardown have
  # the same owner and deadline as the process group. No caller callback is run.
  @doc false
  @spec prepare(map(), String.t(), Path.t(), integer()) :: {:ok, map()} | {:error, term()}
  def prepare(selection, command, workspace, deadline) do
    with :ok <- platform(),
         :ok <- current(deadline),
         {:ok, workspace} <- physical(workspace),
         {:ok, policy_path} <- physical(selection.policy_file),
         :ok <- regular(policy_path),
         {:ok, bytes} <- read(policy_path, :policy_read),
         true <- hash(bytes) == selection.sha256 or {:error, :policy_digest_mismatch},
         {:ok, policy} <- decode_policy(bytes),
         {:ok, policy} <- validate_policy(policy, policy_path, selection.workflow_file, workspace),
         {:ok, protected} <- protected_paths(workspace),
         :ok <- current(deadline) do
      materialize(policy, policy_path, workspace, protected, command, deadline)
    end
  end

  @doc false
  @spec prepare_argv(map(), {:exec, Path.t(), [String.t()]} | {:shell, String.t()}, Path.t(), integer()) :: {:ok, map()} | {:error, term()}
  def prepare_argv(selection, launch, workspace, deadline) do
    # The same validator/materializer owns policy, protected paths, and resources.
    with {:ok, resource} <- prepare(selection, "", workspace, deadline) do
      result =
        case launch do
          {:shell, command} when is_binary(command) ->
            if byte_size(command) <= 1_048_576 and String.valid?(command) and not String.contains?(command, <<0>>),
              do: {:ok, %{resource | argv: Enum.take(resource.argv, 10) ++ ["-c", command]}},
              else: {:error, :invalid_boundary_command}

          {:exec, executable, arguments} when is_binary(executable) and is_list(arguments) ->
            with {:ok, physical} <- physical(executable),
                 true <- physical in resource.tools or {:error, :executable_not_in_policy},
                 true <- (length(arguments) <= 240 and Enum.all?(arguments, &(is_binary(&1) and String.valid?(&1) and not String.contains?(&1, <<0>>)))) or {:error, :invalid_boundary_arguments},
                 true <- Enum.reduce(arguments, 0, &(byte_size(&1) + &2)) <= 1_048_576 or {:error, :boundary_arguments_limit} do
              {:ok, %{resource | argv: List.replace_at(Enum.take(resource.argv, 10), 7, physical) ++ arguments}}
            end

          _invalid ->
            {:error, :invalid_boundary_launch}
        end

      case result do
        {:ok, _} = success -> success
        {:error, _} = error -> finish(resource, error)
      end
    end
  end

  @doc false
  @spec finish(map(), {:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def finish(resource, {:error, {:cleanup_uncertain, _}} = primary),
    do: {:error, {:boundary_resources_retained, primary, resource.root}}

  def finish(resource, primary) do
    case File.rm_rf(resource.root) do
      {:ok, _removed} -> primary
      {:error, reason, _path} -> {:error, {:boundary_cleanup_failed, primary, reason}}
    end
  end

  defp platform do
    if :os.type() == {:unix, :darwin} and {:os.type(), :erlang.system_info(:system_architecture)} == @platform,
      do: :ok,
      else: {:error, :execution_boundary_platform_unsupported}
  end

  defp decode_policy(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"version" => 1, "backend" => "macos_deny_default_v1", "workspace_root" => root, "shell" => shell, "executables" => tools, "read_roots" => reads} = policy}
      when map_size(policy) == 6 and is_binary(root) and is_binary(shell) and is_list(tools) and is_list(reads) ->
        if length(tools) in 1..32 and length(reads) <= 16,
          do: {:ok, %{workspace_root: root, shell: shell, tools: tools, reads: reads}},
          else: {:error, :invalid_execution_boundary_policy}

      {:error, %Jason.DecodeError{position: position}} ->
        {:error, {:invalid_policy_json, position}}

      _invalid ->
        {:error, :invalid_execution_boundary_policy}
    end
  end

  defp validate_policy(policy, policy_path, workflow, workspace) do
    with {:ok, root} <- exact_physical(policy.workspace_root),
         :ok <- directory(root),
         {:ok, workflow} <- physical(workflow),
         true <- (within?(workspace, root) and workspace != root) or {:error, :workspace_outside_policy},
         true <- (not within?(policy_path, root) and not within?(workflow, root)) or {:error, :policy_inside_candidate_root},
         true <- root not in @broad_roots or {:error, :overbroad_workspace_root},
         {:ok, tools} <- tools(policy.tools, root),
         true <- policy.shell in tools or {:error, :shell_not_in_policy},
         {:ok, reads} <- read_roots(policy.reads, root),
         :ok <- immutable(policy_path) do
      {:ok, %{policy | workspace_root: root, tools: tools, reads: reads}}
    end
  end

  defp tools(items, root) do
    Enum.reduce_while(items, {:ok, []}, fn
      %{"path" => path, "sha256" => digest} = item, {:ok, paths}
      when map_size(item) == 2 and is_binary(path) and is_binary(digest) ->
        result =
          with {:ok, ^path} <- exact_physical(path),
               true <- not within?(path, root) or {:error, :tool_inside_candidate_root},
               :ok <- regular(path),
               :ok <- immutable(path),
               {:ok, stat} <- File.stat(path),
               true <- band(stat.mode, 0o111) != 0 or {:error, :tool_not_executable},
               {:ok, bytes} <- read(path, :tool_read),
               true <- hash(bytes) == digest or {:error, :tool_digest_mismatch} do
            {:ok, [path | paths]}
          end

        case result do
          {:ok, _} -> {:cont, result}
          {:error, _} -> {:halt, result}
        end

      _item, _acc ->
        {:halt, {:error, :invalid_tool_policy}}
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(Enum.uniq(paths))}
      error -> error
    end
  end

  defp read_roots(items, root) do
    Enum.reduce_while(items, {:ok, []}, fn path, {:ok, paths} ->
      result =
        with {:ok, path} <- exact_physical(path),
             :ok <- directory(path),
             true <- (path not in @broad_roots and path != System.user_home!()) or {:error, :overbroad_read_root},
             true <- (not within?(path, root) and not within?(root, path)) or {:error, :read_root_overlaps_candidates},
             :ok <- immutable(path) do
          {:ok, [path | paths]}
        end

      case result do
        {:ok, _} -> {:cont, result}
        {:error, _} -> {:halt, result}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(Enum.uniq(paths))}
      error -> error
    end
  end

  defp protected_paths(workspace) do
    git = Path.join(workspace, ".git")
    metadata = Path.join(workspace, ".symphony")

    with :ok <- directory(metadata),
         {:ok, stat} <- File.lstat(git),
         {:ok, gitdir} <- git_directory(git, stat.type),
         {:ok, common} <- common_directory(gitdir) do
      {:ok, Enum.uniq([git, metadata, gitdir, common])}
    else
      {:error, reason} -> {:error, {:protected_metadata, reason}}
    end
  end

  defp git_directory(path, :directory), do: exact_physical(path)

  defp git_directory(path, :regular) do
    with {:ok, bytes} <- File.read(path),
         [_, target] <- Regex.run(~r/\Agitdir: ([^\r\n]+)\r?\n?\z/, bytes),
         {:ok, target} <- physical(Path.expand(target, Path.dirname(path))),
         :ok <- directory(target) do
      {:ok, target}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_gitdir_file}
    end
  end

  defp git_directory(_path, _type), do: {:error, :invalid_git_metadata}

  defp common_directory(gitdir) do
    case File.read(Path.join(gitdir, "commondir")) do
      {:error, :enoent} ->
        {:ok, gitdir}

      {:error, reason} ->
        {:error, reason}

      {:ok, bytes} ->
        case String.split(String.trim_trailing(bytes, "\n"), "\n") do
          [path] when path != "" ->
            with {:ok, path} <- physical(Path.expand(path, gitdir)), :ok <- directory(path), do: {:ok, path}

          _invalid ->
            {:error, :invalid_commondir_file}
        end
    end
  end

  defp materialize(policy, policy_path, workspace, protected, command, deadline) do
    root = "/private/tmp/symphony-boundary-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    resource = %{root: root, home: Path.join(root, "home"), tmp: Path.join(root, "tmp"), profile: Path.join(root, "policy.sb"), executable: Path.join(root, "boundary")}

    case File.mkdir(root) do
      :ok ->
        result =
          with :ok <- File.chmod(root, 0o700),
               :ok <- File.mkdir(resource.home),
               :ok <- File.mkdir(resource.tmp),
               :ok <- File.write(resource.executable, @native, [:binary, :exclusive]),
               :ok <- File.chmod(resource.executable, 0o500),
               {:ok, native} <- File.read(resource.executable),
               true <- :crypto.hash(:sha256, native) == @digest or {:error, :boundary_native_digest_mismatch},
               :ok <- File.write(resource.profile, profile(policy, workspace, protected, resource), [:binary, :exclusive]),
               :ok <- File.chmod(resource.profile, 0o400),
               :ok <- current(deadline) do
            path = policy.tools |> Enum.map(&Path.dirname/1) |> Enum.uniq() |> Enum.join(":")
            argv = [resource.executable, policy.workspace_root, workspace, resource.home, resource.tmp, resource.profile, policy_path, policy.shell, path, "--", "-c", command]
            {:ok, resource |> Map.put(:argv, argv) |> Map.put(:tools, policy.tools)}
          end

        case result do
          {:ok, _resource} -> result
          {:error, reason} -> finish(resource, {:error, {:boundary_preparation_failed, reason}})
        end

      {:error, reason} ->
        {:error, {:boundary_preparation_failed, reason}}
    end
  end

  defp profile(policy, workspace, protected, resource) do
    reads = [workspace, resource.home, resource.tmp | policy.reads] ++ @system_reads
    ancestors = [resource.root, policy.workspace_root | policy.tools ++ reads ++ protected] |> Enum.flat_map(&ancestors/1) |> Enum.uniq()

    [
      "(version 1)\n(deny default)\n",
      "(allow file-read* file-test-existence (literal \"/\"))\n",
      allow("file-read*", Enum.map(reads, &subpath/1) ++ Enum.map(policy.tools, &literal/1)),
      allow("file-read-metadata", Enum.map(ancestors, &literal/1)),
      allow("file-map-executable", Enum.map(policy.tools, &literal/1) ++ Enum.map(@system_reads, &subpath/1)),
      "(allow process-fork)\n",
      allow("process-exec", Enum.map(policy.tools, &literal/1)),
      "(allow file-read* file-write* (literal \"/dev/null\"))\n",
      "(allow file-write* (require-all ",
      subpath(workspace),
      Enum.map(protected, fn path -> [" (require-not ", subpath(path), ")"] end),
      ") ",
      subpath(resource.home),
      " ",
      subpath(resource.tmp),
      ")\n"
    ]
  end

  defp ancestors("/"), do: ["/"]
  defp ancestors(path), do: [path | ancestors(Path.dirname(path))]
  defp allow(operation, paths), do: ["(allow ", operation, " ", Enum.intersperse(paths, " "), ")\n"]
  defp literal(path), do: ["(literal ", quote_path(path), ")"]
  defp subpath(path), do: ["(subpath ", quote_path(path), ")"]
  defp quote_path(path), do: ["\"", path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\""), "\""]

  defp exact_physical(path) do
    with {:ok, resolved} <- physical(path) do
      if path == resolved, do: {:ok, path}, else: {:error, :nonphysical_policy_path}
    end
  end

  defp physical(path) when is_binary(path) do
    if Path.type(path) == :absolute and String.valid?(path) and not Regex.match?(~r/[\x00-\x1f\x7f:]/, path),
      do: physical_components(Path.split(Path.expand(path)), "/", 40),
      else: {:error, :invalid_boundary_path}
  end

  defp physical(_path), do: {:error, :invalid_boundary_path}

  defp physical_components([], current, _left), do: {:ok, current}
  defp physical_components(["/" | rest], current, left), do: physical_components(rest, current, left)
  defp physical_components(_parts, _current, 0), do: {:error, :eloop}

  defp physical_components([part | rest], current, left) do
    path = Path.join(current, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(path),
             {:ok, target} <- physical_components(Path.split(Path.expand(target, current)), "/", left - 1) do
          physical_components(rest, target, left - 1)
        end

      {:ok, _stat} ->
        physical_components(rest, path, left)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp directory(path), do: file_type(path, :directory)
  defp regular(path), do: file_type(path, :regular)

  defp file_type(path, type) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^type}} -> :ok
      {:ok, _stat} -> {:error, :unexpected_boundary_file_type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp immutable(path) do
    case File.stat(path) do
      {:ok, stat} ->
        if band(stat.mode, 0o022) == 0 and (stat.uid == 0 or band(stat.mode, 0o222) == 0), do: :ok, else: {:error, :writable_trustee_resource}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read(path, phase) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {phase, reason}}
    end
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp current(deadline), do: if(now() < deadline, do: :ok, else: {:error, :timeout})
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp now, do: System.monotonic_time(:millisecond)
end
