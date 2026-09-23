defmodule SymphonyElixir.DispatchGateTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.DispatchGate

  test "body waits for explicit owner authorization" do
    owner = self()

    {worker, ref} =
      spawn_monitor(fn ->
        DispatchGate.run(owner, "dispatch-1", fn -> send(owner, {:body, self()}) end)
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    refute_receive {:body, ^worker}, 50
    assert :ok = DispatchGate.activate(worker, "dispatch-1")
    assert_receive {:body, ^worker}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
  end

  test "stale dispatch ids and a different sender cannot authorize the body" do
    owner = self()

    {worker, ref} =
      spawn_monitor(fn ->
        DispatchGate.run(owner, "current", fn -> send(owner, {:body, self()}) end)
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    DispatchGate.activate(worker, "stale")

    other =
      spawn(fn ->
        DispatchGate.activate(worker, "current")
        send(owner, :foreign_sent)
      end)

    assert is_pid(other)
    assert_receive :foreign_sent
    refute_receive {:body, ^worker}, 50
    DispatchGate.activate(worker, "current")
    DispatchGate.activate(worker, "current")
    assert_receive {:body, ^worker}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    refute_received {:body, ^worker}
  end

  test "an owner already dead before run never executes the body" do
    parent = self()
    {owner, owner_ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    {worker, ref} =
      spawn_monitor(fn ->
        result = DispatchGate.run(owner, "dead", fn -> send(parent, :forbidden_body) end)
        send(parent, {:gate_result, result})
      end)

    assert_receive {:gate_result, {:error, :owner_down}}
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    refute_received :forbidden_body
  end

  test "owner death while waiting cancels worker and guardian without running body" do
    parent = self()
    owner = owner_process()

    {worker, ref, guardian, guardian_ref} =
      traced_worker(owner, "waiting", fn -> send(parent, :forbidden_body) end)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, _reason}, 1_000
    refute_received :forbidden_body
  end

  test "owner death during a blocked body terminates worker and guardian" do
    parent = self()
    owner = owner_process()

    {worker, ref, guardian, guardian_ref} =
      traced_worker(owner, "running", fn ->
        send(parent, {:body_entered, self()})

        receive do
          :unblock -> send(parent, :body_continued)
        end
      end)

    send(owner, {:activate, worker, "running"})
    assert_receive {:body_entered, ^worker}, 1_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, _reason}, 1_000
    refute_received :body_continued
  end

  test "aborting a waiting worker leaves no guardian behind" do
    owner = owner_process()

    {worker, ref, guardian, guardian_ref} =
      traced_worker(owner, "abort", fn -> flunk("unauthorized body") end)

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, _reason}, 1_000
  end

  test "authorization queued early still waits for a fully monitoring guardian" do
    owner = self()

    {worker, ref} =
      spawn_monitor(fn ->
        receive do
          :start ->
            result =
              DispatchGate.run(owner, "early", fn ->
                {:links, [guardian]} = Process.info(self(), :links)
                {:monitors, monitors} = Process.info(guardian, :monitors)
                send(owner, {:guardian_monitors, guardian, monitors})
                :body_result
              end)

            send(owner, {:gate_result, result})
        end
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    DispatchGate.activate(worker, "early")
    send(worker, :start)
    assert_receive {:guardian_monitors, guardian, monitors}, 1_000
    assert {:process, owner} in monitors
    assert {:process, worker} in monitors
    assert_receive {:gate_result, :body_result}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    refute Process.alive?(guardian)
  end

  test "body failure propagates and still terminates its guardian" do
    owner = owner_process()

    {worker, ref, guardian, guardian_ref} =
      traced_worker(owner, "failure", fn -> exit(:controlled_body_failure) end)

    send(owner, {:activate, worker, "failure"})
    assert_receive {:DOWN, ^ref, :process, ^worker, :controlled_body_failure}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, _reason}, 1_000
  end

  defp owner_process do
    owner = spawn(fn -> owner_loop() end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    owner
  end

  defp owner_loop do
    receive do
      {:activate, worker, id} ->
        DispatchGate.activate(worker, id)
        owner_loop()
    end
  end

  defp traced_worker(owner, id, fun) do
    {worker, ref} =
      spawn_monitor(fn ->
        receive do
          :start -> DispatchGate.run(owner, id, fun)
        end
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    :erlang.trace(worker, true, [:procs])
    send(worker, :start)
    assert_receive {:trace, ^worker, :spawn, guardian, _entry}, 1_000
    guardian_ref = Process.monitor(guardian)
    :erlang.trace(worker, false, [:procs])
    {worker, ref, guardian, guardian_ref}
  end
end
