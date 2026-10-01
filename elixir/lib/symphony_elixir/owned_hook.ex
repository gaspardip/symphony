defmodule SymphonyElixir.OwnedHook do
  @moduledoc false
  require Logger

  @source Path.expand("../../c_src/owned_hook.c", __DIR__)
  @external_resource @source
  @build_path Path.join(Mix.Project.build_path(), "native/symphony-owned-hook")
  @native File.read!(@build_path)
  @digest :crypto.hash(:sha256, @native)
  @platform {:os.type(), :erlang.system_info(:system_architecture)}
  @cleanup_budget 3_000

  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__? do
    case File.read(@build_path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) != @digest
      {:error, _reason} -> true
    end
  end

  @spec run(String.t(), Path.t(), pos_integer()) :: {:ok, {binary(), non_neg_integer()}} | {:error, term()}
  def run(command, workspace, timeout_ms)
      when is_binary(command) and is_binary(workspace) and is_integer(timeout_ms) and timeout_ms > 0 do
    caller = self()
    ref = make_ref()
    deadline = now() + timeout_ms

    case spawn_owner(caller, ref, command, workspace, deadline) do
      {pid, monitor} when is_pid(pid) -> await_owner(pid, monitor, ref, deadline)
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp spawn_owner(caller, ref, command, workspace, deadline) do
    spawn_monitor(fn -> supervise(caller, ref, command, workspace, deadline) end)
  rescue
    error in [SystemLimitError] -> {:error, error}
  end

  defp await_owner(pid, monitor, ref, deadline) do
    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:cleanup_uncertain, {:owner_down, reason}}}
    after
      max(deadline - now(), 0) + @cleanup_budget ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, {:cleanup_uncertain, :owner_deadline}}
    end
  end

  defp supervise(caller, ref, command, workspace, deadline) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(caller)

    result =
      with :ok <- platform_current(),
           :ok <- startup_current(caller, deadline),
           {:ok, artifact} <- materialize(workspace) do
        primary = run_materialized(artifact, caller, monitor, command, workspace, deadline)
        combine(primary, remove_artifact(artifact))
      end

    Process.demonitor(monitor, [:flush])
    send(caller, {ref, result})
  end

  defp startup_current(caller, deadline) do
    cond do
      now() >= deadline -> {:error, :timeout}
      not Process.alive?(caller) -> {:error, {:start_failed, :caller_down}}
      true -> :ok
    end
  end

  defp platform_current do
    if {:os.type(), :erlang.system_info(:system_architecture)} == @platform,
      do: :ok,
      else: {:error, {:start_failed, :native_platform_mismatch}}
  end

  defp materialize(workspace) do
    tmp = Path.expand(System.tmp_dir!())
    workspace = Path.expand(workspace)

    if tmp == workspace or String.starts_with?(tmp, workspace <> "/") do
      {:error, {:start_failed, :temporary_root_inside_workspace}}
    else
      root = Path.join(tmp, "symphony-owned-hook-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))

      case File.mkdir(root) do
        :ok -> write_artifact(%{root: root, path: Path.join(root, "owner")})
        {:error, reason} -> {:error, {:start_failed, {:temporary_directory, reason}}}
      end
    end
  end

  defp write_artifact(artifact) do
    result =
      with :ok <- File.chmod(artifact.root, 0o700),
           :ok <- File.write(artifact.path, @native, [:binary, :exclusive]),
           :ok <- File.chmod(artifact.path, 0o700),
           {:ok, bytes} <- File.read(artifact.path),
           true <- :crypto.hash(:sha256, bytes) == @digest do
        {:ok, artifact}
      else
        false -> {:error, {:start_failed, :native_hash_mismatch}}
        {:error, reason} -> {:error, {:start_failed, {:native_materialization, reason}}}
      end

    case result do
      {:ok, _artifact} -> result
      {:error, _reason} -> combine(result, remove_artifact(artifact))
    end
  end

  defp run_materialized(artifact, caller, monitor, command, workspace, deadline) do
    case System.find_executable("sh") do
      nil -> {:error, {:start_failed, :shell_not_found}}
      shell -> open_native(artifact.path, shell, command, workspace, caller, monitor, deadline)
    end
  end

  defp open_native(path, shell, command, workspace, caller, monitor, deadline) do
    remaining = deadline - now()

    cond do
      remaining <= 0 ->
        {:error, :timeout}

      not Process.alive?(caller) ->
        {:error, {:start_failed, :caller_down}}

      true ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:packet, 4},
            {:cd, workspace},
            {:args, [Integer.to_string(remaining), shell, command]}
          ])

        state = %{
          port: port,
          caller: caller,
          monitor: monitor,
          deadline: deadline,
          limit: deadline + @cleanup_budget - 250,
          ready: nil,
          receipt: nil,
          output: [],
          cancelled: false,
          failure: nil,
          cause: nil
        }

        try do
          receive_native(state)
        after
          if Port.info(port) != nil, do: Port.close(port)
        end
    end
  rescue
    error -> {:error, {:cleanup_uncertain, {:native_exception, error}}}
  end

  defp receive_native(state) do
    wait_until = if state.cancelled, do: state.limit, else: min(state.deadline, state.limit)
    port = state.port
    monitor = state.monitor
    caller = state.caller

    receive do
      {^port, {:data, <<"R", payload::binary>>}} ->
        case {state.ready, integers(payload)} do
          {nil, [1, child, helper]} when child > 0 and helper > 0 ->
            next = %{state | ready: %{child: child, pgid: child, helper: helper}}

            cond do
              Port.info(port, :os_pid) != {:os_pid, helper} ->
                receive_native(cancel(next, :invalid_ready))

              not Process.alive?(caller) ->
                receive_native(cancel(%{next | cause: next.cause || :caller_down}, nil))

              state.cancelled ->
                receive_native(next)

              now() >= state.deadline ->
                receive_native(cancel(next, nil))

              true ->
                true = Port.command(port, "G" <> Integer.to_string(state.deadline - now()))
                receive_native(next)
            end

          _ ->
            receive_native(cancel(state, :invalid_ready))
        end

      {^port, {:data, <<"D", data::binary>>}} ->
        if state.receipt == nil,
          do: receive_native(%{state | output: [data | state.output]}),
          else: receive_native(cancel(state, :output_after_receipt))

      {^port, {:data, <<"F", payload::binary>>}} ->
        case {state.receipt, state.ready, integers(payload)} do
          {nil, %{child: child}, [1, trigger, status, certain, phase, reason, child]}
          when trigger in 0..4 and status >= -1 and certain in [0, 1] and phase in 0..10 and reason >= 0 ->
            receipt = %{trigger: trigger, status: status, certain: certain, phase: phase, reason: reason}
            receive_native(%{state | receipt: receipt, cancelled: true})

          _ ->
            receive_native(cancel(state, :invalid_receipt))
        end

      {^port, {:data, _payload}} ->
        receive_native(cancel(state, :invalid_packet))

      {^port, {:exit_status, status}} ->
        native_result(state, status)

      {:EXIT, ^port, :normal} ->
        receive_native(state)

      {:EXIT, ^port, reason} ->
        {:error, {:cleanup_uncertain, {:port_exit, reason, state.ready, state.receipt}}}

      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        receive_native(cancel(%{state | cause: state.cause || :caller_down}, nil))
    after
      max(wait_until - now(), 0) ->
        if now() >= state.limit do
          {:error, {:cleanup_uncertain, {:native_deadline, state.ready, state.receipt}}}
        else
          receive_native(cancel(state, nil))
        end
    end
  end

  defp cancel(state, failure) do
    cause = state.cause || failure || :timeout
    if not state.cancelled, do: Port.command(state.port, if(cause == :timeout, do: "T", else: "C"))
    %{state | cancelled: true, failure: state.failure || failure, cause: cause, limit: min(state.limit, now() + @cleanup_budget - 250)}
  end

  defp native_result(%{failure: nil, receipt: %{certain: 1, phase: phase} = receipt} = state, 0)
       when phase in [0, 5, 7] do
    if phase != 0 do
      diagnostic = if phase == 5, do: :send_signal, else: :group_probe
      Logger.warning("Owned hook diagnostic after confirmed closure phase=#{diagnostic} errno=#{receipt.reason}")
    end

    case receipt do
      %{trigger: 0, status: status} when status >= 0 -> {:ok, {state.output |> Enum.reverse() |> IO.iodata_to_binary(), status}}
      %{trigger: 1} -> {:error, :timeout}
      %{trigger: 2} -> {:error, :timeout}
      _ -> {:error, {:native_interrupted, receipt, state.ready}}
    end
  end

  defp native_result(state, status),
    do:
      {:error,
       {:cleanup_uncertain,
        %{exit_status: status, failure: state.failure, cause: state.cause, identity: state.ready, receipt: state.receipt, output: state.output |> Enum.reverse() |> IO.iodata_to_binary()}}}

  defp integers(payload) do
    Enum.reduce_while(String.split(payload, " "), [], fn part, acc ->
      case Integer.parse(part) do
        {value, ""} -> {:cont, [value | acc]}
        _ -> {:halt, :invalid}
      end
    end)
    |> case do
      :invalid -> :invalid
      values -> Enum.reverse(values)
    end
  end

  defp remove_artifact(artifact) do
    errors =
      for {operation, result} <- [{:file, File.rm(artifact.path)}, {:directory, File.rmdir(artifact.root)}], result not in [:ok, {:error, :enoent}], do: {operation, result}

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp combine(primary, :ok), do: primary
  defp combine(primary, {:error, cleanup}), do: {:error, {:artifact_cleanup_failed, primary, cleanup}}
  defp now, do: System.monotonic_time(:millisecond)
end
