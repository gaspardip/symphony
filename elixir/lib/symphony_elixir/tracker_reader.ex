defmodule SymphonyElixir.TrackerReader do
  @moduledoc """
  Owns the lifecycle of one callback without carrying coordinator state.

  start/2 is restricted to reads. start_operation/2 explicitly admits an audited
  mutation under the separate cancellation and uncertainty contract below.

  The caller owns the returned handle. A supervised guardian monitors that caller
  and runs the supplied function in a linked, monitored child. It sends one
  `{:tracker_read_result, ref, result}` only after the child has terminated, then
  terminates normally. The caller must handle this message before a generic DOWN
  handler, and demonitor with `[:flush]` after consuming a result.

  Cancellation is asynchronous. The caller must invalidate the operation reference
  immediately: cancellation cannot retract a result already sent to its mailbox.
  A guardian that observes cancellation or owner death kills its own read child
  and waits for its DOWN before terminating, without delivering a result.

  The function passed to `start/2` must perform only the intended read and return `{:ok, data}` or
  `{:error, reason}`. It must not enable `trap_exit` or spawn detached work. Those
  contracts make the child link effective if the guardian itself is killed. This
  module does not supervise arbitrary transport descendants or interrupt a blocking
  native function. It never retries, logs the closure, or applies business state.
  """

  @type result :: {:ok, term()} | {:error, term()}
  @type handle :: %{
          owner: pid(),
          pid: pid(),
          monitor: reference(),
          ref: reference()
        }

  @doc "Starts a guardian and installs the caller's monitor before allowing the read to run."
  @spec start((-> result()), keyword()) :: {:ok, handle()} | {:error, term()}
  def start(read_fun, opts \\ []) when is_function(read_fun, 0) do
    start_owned(read_fun, opts)
  end

  @doc """
  Starts one explicitly audited operation using the same owned guardian lifecycle.

  Unlike start/2, this entry permits a durable mutation with its own checked
  journal. The callback must return {:ok, data} or {:error, reason}; it must not
  trap exits or spawn detached work. This entry never retries or rolls back.
  Cancellation or owner death may leave committed effects, a pending journal or
  a physical lock. The owner must preserve the rejected admission and treat a
  missing result as uncertain, never as proof that the mutation was undone.
  Results and lifecycle failures retain the existing tracker_read_result protocol.
  """
  @spec start_operation((-> result()), keyword()) :: {:ok, handle()} | {:error, term()}
  def start_operation(operation_fun, opts \\ []) when is_function(operation_fun, 0) do
    start_owned(operation_fun, opts)
  end

  defp start_owned(read_fun, opts) do
    owner = self()
    ref = make_ref()
    supervisor = Keyword.get(opts, :supervisor, SymphonyElixir.TaskSupervisor)

    case Task.Supervisor.start_child(supervisor, fn -> guardian(owner, ref, read_fun) end, restart: :temporary) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        send(pid, {:tracker_reader_start, owner, ref})
        {:ok, %{owner: owner, pid: pid, monitor: monitor, ref: ref}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Requests cancellation without waiting for I/O or DOWN; only the owning caller may cancel."
  @spec cancel(handle()) :: :ok | {:error, :not_reader_owner}
  def cancel(%{owner: owner, pid: pid, ref: ref}) when owner == self() do
    send(pid, {:tracker_reader_cancel, owner, ref})
    :ok
  end

  def cancel(%{owner: _owner}), do: {:error, :not_reader_owner}

  defp guardian(owner, ref, read_fun) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)

    receive do
      {:tracker_reader_start, ^owner, ^ref} ->
        if Process.alive?(owner) do
          begin_read(owner, owner_monitor, ref, read_fun)
        end

      {:tracker_reader_cancel, ^owner, ^ref} ->
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :ok

      {:EXIT, _supervisor, reason} ->
        exit(reason)
    end
  end

  defp begin_read(owner, owner_monitor, ref, read_fun) do
    guardian = self()

    {child, child_monitor} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {:tracker_reader_execute, ^guardian, ^ref} ->
              send(guardian, {:tracker_reader_returned, self(), ref, invoke_read(read_fun)})
          end
        end,
        [:link, :monitor]
      )

    send(child, {:tracker_reader_execute, guardian, ref})
    await_read(owner, owner_monitor, ref, child, child_monitor, :pending)
  end

  defp invoke_read(read_fun) do
    case read_fun.() do
      {:ok, _data} = result -> result
      {:error, _reason} = result -> result
      _other -> {:error, :invalid_tracker_read_result}
    end
  catch
    kind, reason -> {:error, {:tracker_read_exception, kind, reason}}
  end

  defp await_read(owner, owner_monitor, ref, child, child_monitor, outcome) do
    receive do
      {:tracker_reader_returned, ^child, ^ref, result} ->
        await_read(owner, owner_monitor, ref, child, child_monitor, {:returned, result})

      {:DOWN, ^child_monitor, :process, ^child, reason} ->
        result =
          case {outcome, reason} do
            {{:returned, result}, :normal} -> result
            _other -> {:error, {:tracker_reader_exit, reason}}
          end

        Process.demonitor(owner_monitor, [:flush])
        send(owner, {:tracker_read_result, ref, result})

      {:tracker_reader_cancel, ^owner, ^ref} ->
        stop_read(child, child_monitor)

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        stop_read(child, child_monitor)

      {:EXIT, ^child, _reason} ->
        await_read(owner, owner_monitor, ref, child, child_monitor, outcome)

      {:EXIT, _supervisor, reason} ->
        stop_read(child, child_monitor)
        exit(reason)
    end
  end

  defp stop_read(child, child_monitor) do
    Process.exit(child, :kill)

    receive do
      {:DOWN, ^child_monitor, :process, ^child, _reason} -> :ok
    end
  end
end
