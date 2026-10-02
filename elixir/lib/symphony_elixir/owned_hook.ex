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

  @doc false
  @spec run_boundary(String.t(), Path.t(), map(), integer()) :: {:ok, {binary(), non_neg_integer()}} | {:error, term()}
  def run_boundary(command, workspace, selection, deadline) do
    caller = self()
    ref = make_ref()

    case spawn_owner(caller, ref, {:boundary, selection, command}, workspace, deadline) do
      {pid, monitor} when is_pid(pid) -> await_owner(pid, monitor, ref, deadline)
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  @doc false
  @spec prepare_stream(Path.t(), map(), tuple(), integer()) :: {:ok, tuple(), map()} | {:error, term()}
  def prepare_stream(workspace, selection, launch, deadline) do
    caller = self()
    ref = make_ref()
    {owner, monitor} = spawn_monitor(fn -> supervise_stream(caller, ref, workspace, selection, launch, deadline) end)
    handle = {:owned_provider, owner, caller, ref, deadline}

    receive do
      {^handle, {:ready, identity}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, handle, identity}

      {^handle, {:closed, result}} ->
        Process.demonitor(monitor, [:flush])

        case result do
          {:ok, receipt} -> {:error, {:provider_start_interrupted, receipt}}
          {:error, _} = error -> error
        end

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, {:provider_cleanup_uncertain, :custodian_down}}
    after
      max(deadline - now(), 0) + @cleanup_budget ->
        stream_control(handle, "C")
        Process.demonitor(monitor, [:flush])
        {:error, {:provider_cleanup_uncertain, :startup_deadline}}
    end
  end

  @doc false
  @spec stream_control({:owned_provider, pid(), pid(), reference(), integer()}, binary()) :: :ok | {:error, :foreign_stream_owner}
  def stream_control({:owned_provider, owner, caller, ref, _deadline}, packet) when caller == self() and is_binary(packet) do
    send(owner, {:stream_control, ref, caller, packet})
    :ok
  end

  def stream_control(_handle, _packet), do: {:error, :foreign_stream_owner}

  defp supervise_stream(caller, ref, workspace, selection, launch, deadline) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(caller)
    handle = {:owned_provider, self(), caller, ref, deadline}

    result =
      with :ok <- platform_current(),
           :ok <- startup_current(caller, deadline),
           {:ok, artifact} <- materialize(workspace) do
        result =
          case SymphonyElixir.ExecutionBoundary.prepare_argv(selection, launch, workspace, deadline) do
            {:ok, resource} ->
              primary = open_stream_native(artifact.path, resource, handle, monitor)

              case primary do
                {:error, {:provider_cleanup_uncertain, _}} -> primary
                _ -> SymphonyElixir.ExecutionBoundary.finish(resource, primary)
              end

            error ->
              error
          end

        case result do
          {:error, {:provider_cleanup_uncertain, _}} -> result
          _ -> combine(result, remove_artifact(artifact))
        end
      end

    Process.demonitor(monitor, [:flush])
    send(caller, {handle, {:closed, result}})
  end

  defp open_stream_native(path, resource, {:owned_provider, _owner, caller, ref, deadline} = handle, monitor) do
    with :ok <- startup_current(caller, deadline) do
      port =
        Port.open({:spawn_executable, path}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:packet, 4},
          {:args, [Integer.to_string(deadline - now()), "--stream" | resource.argv]}
        ])

      state = %{
        port: port,
        handle: handle,
        caller: caller,
        ref: ref,
        monitor: monitor,
        deadline: deadline,
        limit: deadline + @cleanup_budget - 250,
        ready: nil,
        receipt: nil,
        started: false,
        cancelled: false,
        failure: nil
      }

      try do
        receive_stream_native(state)
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    end
  rescue
    error -> {:error, {:provider_cleanup_uncertain, {:native_exception, error.__struct__}}}
  end

  defp receive_stream_native(state) do
    %{port: port, caller: caller, monitor: monitor, handle: handle, ref: ref} = state
    wait_until = if state.cancelled, do: state.limit, else: state.deadline

    receive do
      {^port, {:data, <<"R", payload::binary>>}} ->
        case {state.ready, integers(payload)} do
          {nil, [2, child, helper]} when child > 1 and helper > 1 ->
            next = %{state | ready: %{child: child, pgid: child, helper: helper}}

            if Port.info(port, :os_pid) == {:os_pid, helper} and Process.alive?(caller) and now() < state.deadline do
              send(caller, {handle, {:ready, next.ready}})
              receive_stream_native(next)
            else
              receive_stream_native(stream_cancel(next, :invalid_ready))
            end

          _ ->
            receive_stream_native(stream_cancel(state, :invalid_ready))
        end

      {^port, {:data, "B"}} when not state.started and not state.cancelled ->
        send(caller, {handle, :started})
        receive_stream_native(%{state | started: true})

      {^port, {:data, <<kind, data::binary>>}} when kind in [?D, ?S] and state.receipt == nil ->
        send(caller, {handle, {:chunk, if(kind == ?D, do: :stdout, else: :stderr), data}})
        receive_stream_native(state)

      {^port, {:data, <<"W", id::unsigned-big-32>>}} when state.receipt == nil ->
        send(caller, {handle, {:written, id}})
        receive_stream_native(state)

      {^port, {:data, <<"F", payload::binary>>}} ->
        case {state.ready, state.receipt, integers(payload)} do
          {%{child: child}, nil, [2, trigger, status, certain, phase, reason, child]}
          when trigger in 0..4 and status >= -1 and certain in [0, 1] and phase in 0..10 and reason >= 0 ->
            receipt = %{trigger: trigger, status: status, certain: certain, phase: phase, reason: reason}
            receive_stream_native(%{state | receipt: receipt, cancelled: true})

          _ ->
            receive_stream_native(stream_cancel(state, :invalid_receipt))
        end

      {^port, {:data, _invalid}} ->
        receive_stream_native(stream_cancel(state, :invalid_packet))

      {:stream_control, ^ref, ^caller, packet} ->
        next =
          cond do
            state.receipt != nil -> state
            packet in ["C", "T"] -> stream_cancel(state, nil, packet)
            state.cancelled -> state
            now() >= state.deadline -> stream_cancel(state, :timeout, "T")
            true -> stream_native_command(state, packet)
          end

        receive_stream_native(next)

      {^port, {:exit_status, status}} ->
        stream_result(state, status)

      {:EXIT, ^port, :normal} ->
        receive_stream_native(state)

      {:EXIT, ^port, _reason} ->
        {:error, {:provider_cleanup_uncertain, %{reason: :port_exit, identity: state.ready, receipt: state.receipt}}}

      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        receive_stream_native(stream_cancel(state, nil))
    after
      max(wait_until - now(), 0) ->
        if now() >= state.limit,
          do: {:error, {:provider_cleanup_uncertain, %{reason: :native_deadline, identity: state.ready, receipt: state.receipt}}},
          else: receive_stream_native(stream_cancel(state, :timeout, "T"))
    end
  end

  defp stream_cancel(state, reason, packet \\ "C") do
    next = %{state | cancelled: true, failure: state.failure || reason, limit: min(state.limit, now() + @cleanup_budget - 250)}
    if state.cancelled, do: next, else: stream_native_command(next, packet)
  end

  defp stream_native_command(state, packet) do
    case Port.command(state.port, packet, [:nosuspend]) do
      true ->
        state

      false ->
        Port.close(state.port)
        %{state | cancelled: true, failure: state.failure || :native_input_backpressure, limit: min(state.limit, now() + @cleanup_budget - 250)}
    end
  rescue
    ArgumentError -> %{state | cancelled: true, failure: state.failure || :native_channel_closed, limit: min(state.limit, now() + @cleanup_budget - 250)}
  catch
    :exit, _reason -> %{state | cancelled: true, failure: state.failure || :native_channel_closed, limit: min(state.limit, now() + @cleanup_budget - 250)}
  end

  defp stream_result(%{receipt: %{certain: 1, phase: phase} = receipt} = state, 0) when phase in [0, 5, 7] do
    if phase != 0, do: Logger.warning("Provider physical closure diagnostic phase=#{phase} errno=#{receipt.reason}")
    {:ok, %{identity: state.ready, receipt: receipt, failure: state.failure}}
  end

  defp stream_result(state, status),
    do: {:error, {:provider_cleanup_uncertain, %{exit_status: status, failure: state.failure, identity: state.ready, receipt: state.receipt}}}

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

  defp run_materialized(artifact, caller, monitor, {:boundary, selection, command}, workspace, deadline) do
    with :ok <- startup_current(caller, deadline),
         {:ok, resource} <- SymphonyElixir.ExecutionBoundary.prepare(selection, command, workspace, deadline) do
      primary = open_native(artifact.path, ["--argv" | resource.argv], workspace, caller, monitor, deadline)
      SymphonyElixir.ExecutionBoundary.finish(resource, primary)
    end
  end

  defp run_materialized(artifact, caller, monitor, command, workspace, deadline) do
    case System.find_executable("sh") do
      nil -> {:error, {:start_failed, :shell_not_found}}
      shell -> open_native(artifact.path, [shell, command], workspace, caller, monitor, deadline)
    end
  end

  defp open_native(path, arguments, workspace, caller, monitor, deadline) do
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
            {:args, [Integer.to_string(remaining) | arguments]}
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
