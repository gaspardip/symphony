defmodule SymphonyElixir.DispatchGate do
  @moduledoc """
  Runs a worker body only after its owner authorizes this dispatch.

  A linked guardian cancels the worker if the owner dies, including while the
  body is running. Authorization has no timeout fallback. Persistence and
  installation of the owner's running entry remain the caller's responsibility.
  """

  @spec run(pid(), String.t(), (-> result)) :: result | {:error, :owner_down} when result: term()
  def run(owner, dispatch_id, fun)
      when is_pid(owner) and is_binary(dispatch_id) and is_function(fun, 0) do
    if Process.alive?(owner) do
      worker = self()
      owner_ref = Process.monitor(owner)

      {guardian, guardian_ref} =
        :erlang.spawn_opt(fn -> guard(owner, worker) end, [:link, :monitor])

      try do
        await_guardian(guardian, guardian_ref, owner, owner_ref)
        await_authorization(owner, owner_ref, guardian, guardian_ref, dispatch_id)
        fun.()
      after
        stop_guardian(guardian, guardian_ref)
        Process.demonitor(owner_ref, [:flush])
      end
    else
      {:error, :owner_down}
    end
  end

  @spec activate(pid(), String.t()) :: :ok
  def activate(worker, dispatch_id) when is_pid(worker) and is_binary(dispatch_id) do
    send(worker, {:dispatch_gate_authorize, self(), dispatch_id})
    :ok
  end

  defp await_guardian(guardian, guardian_ref, owner, owner_ref) do
    receive do
      {:dispatch_gate_ready, ^guardian} ->
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        exit({:shutdown, :dispatch_owner_down})

      {:DOWN, ^guardian_ref, :process, ^guardian, reason} ->
        exit({:dispatch_guardian_down, reason})
    end
  end

  defp await_authorization(owner, owner_ref, guardian, guardian_ref, dispatch_id) do
    receive do
      {:dispatch_gate_authorize, ^owner, ^dispatch_id} ->
        if Process.alive?(owner), do: :ok, else: exit({:shutdown, :dispatch_owner_down})

      {:dispatch_gate_authorize, _other_owner, _other_dispatch} ->
        await_authorization(owner, owner_ref, guardian, guardian_ref, dispatch_id)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        exit({:shutdown, :dispatch_owner_down})

      {:DOWN, ^guardian_ref, :process, ^guardian, reason} ->
        exit({:dispatch_guardian_down, reason})
    end
  end

  defp guard(owner, worker) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)
    send(worker, {:dispatch_gate_ready, self()})

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
      {:dispatch_gate_stop, ^worker} -> :ok
    end
  end

  defp stop_guardian(guardian, guardian_ref) do
    if Process.alive?(guardian) do
      send(guardian, {:dispatch_gate_stop, self()})

      receive do
        {:DOWN, ^guardian_ref, :process, ^guardian, _reason} -> :ok
      end
    else
      Process.demonitor(guardian_ref, [:flush])
    end
  end
end
