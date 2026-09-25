defmodule SymphonyElixir.TrackerReaderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TrackerReader

  @receive_timeout 1_000

  setup do
    %{supervisor: start_supervised!(Task.Supervisor)}
  end

  test "held I/O leaves the owner responsive and starts only after its reader monitor exists", context do
    {reader, child, monitors_at_start} = held_reader(context.supervisor)
    ref = reader.ref
    monitor = reader.monitor
    pid = reader.pid

    assert {:process, pid} in monitors_at_start
    send(self(), :owner_mailbox_available)
    assert_receive :owner_mailbox_available
    assert Process.alive?(child)
    refute_receive {:tracker_read_result, ^ref, _result}, 0

    send(child, {:release_read, {:ok, [:candidate]}})

    first =
      receive do
        {:tracker_read_result, ^ref, result} -> {:result, result}
        {:DOWN, ^monitor, :process, ^pid, reason} -> {:down_before_result, reason}
      after
        @receive_timeout -> flunk("reader produced neither result nor DOWN")
      end

    assert first == {:result, {:ok, [:candidate]}}
    refute Process.alive?(child)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @receive_timeout
    refute_receive {:tracker_read_result, ^ref, _duplicate}, 0
  end

  test "read errors retain their data instead of becoming an empty success", context do
    expected = {:error, {:rate_limited, %{retry_after_ms: 12_000}}}
    assert {:ok, reader} = TrackerReader.start(fn -> expected end, supervisor: context.supervisor)
    assert_result_and_down(reader, expected)
  end

  test "read exceptions become an explicit failure without a silent retry", context do
    owner = self()

    assert {:ok, reader} =
             TrackerReader.start(
               fn ->
                 send(owner, :read_called)
                 raise ArgumentError, "synthetic read failure"
               end,
               supervisor: context.supervisor
             )

    ref = reader.ref
    assert_receive :read_called, @receive_timeout

    assert_receive {:tracker_read_result, ^ref, {:error, {:tracker_read_exception, :error, %ArgumentError{message: "synthetic read failure"}}}},
                   @receive_timeout

    assert_down(reader, :normal)
    refute_receive :read_called, 0
  end

  test "an invalid return cannot masquerade as read success", context do
    assert {:ok, reader} = TrackerReader.start(fn -> :invalid end, supervisor: context.supervisor)
    assert_result_and_down(reader, {:error, :invalid_tracker_read_result})
  end

  test "cancellation returns while the guardian is suspended and suppresses the later queued result", context do
    {reader, child, _monitors} = held_reader(context.supervisor)
    child_monitor = Process.monitor(child)
    ref = reader.ref
    assert :erlang.suspend_process(reader.pid)

    try do
      assert :ok = TrackerReader.cancel(reader)
      assert Process.alive?(reader.pid)
      assert Process.alive?(child)
      send(child, {:release_read, {:ok, :late_result}})
      assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, @receive_timeout
    after
      if Process.alive?(reader.pid), do: :erlang.resume_process(reader.pid)
    end

    assert_down(reader, :normal)
    refute Process.alive?(child)
    refute_receive {:tracker_read_result, ^ref, _cancelled_result}, 0
  end

  test "cancellation of retained I/O confirms child termination before guardian DOWN", context do
    {reader, child, _monitors} = held_reader(context.supervisor)
    ref = reader.ref
    assert :ok = TrackerReader.cancel(reader)
    assert_down(reader, :normal)
    refute Process.alive?(child)
    refute_receive {:tracker_read_result, ^ref, _cancelled_result}, 0
  end

  for owner_exit <- [:normal, :killed] do
    @owner_exit owner_exit
    test "owner #{@owner_exit} termination removes a retained read and its guardian", context do
      observer = self()
      supervisor = context.supervisor

      {owner, owner_monitor} =
        spawn_monitor(fn ->
          {:ok, reader} =
            TrackerReader.start(
              fn ->
                send(observer, {:owned_read_started, self()})

                receive do
                  :release_unexpectedly -> send(observer, :unexpected_read_effect)
                end

                {:ok, :unexpected}
              end,
              supervisor: supervisor
            )

          send(observer, {:owned_reader, reader})

          receive do
            :exit_normally -> :ok
          end
        end)

      on_exit(fn ->
        if Process.alive?(owner), do: Process.exit(owner, :kill)
      end)

      assert_receive {:owned_reader, reader}, @receive_timeout
      assert_receive {:owned_read_started, child}, @receive_timeout
      guardian_monitor = Process.monitor(reader.pid)
      guardian = reader.pid

      if @owner_exit == :normal,
        do: send(owner, :exit_normally),
        else: Process.exit(owner, :kill)

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, @owner_exit}, @receive_timeout
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, @receive_timeout
      refute Process.alive?(child)
      send(child, :release_unexpectedly)
      refute_receive :unexpected_read_effect, 0
    end
  end

  test "guardian death propagates to its linked read without a supervisor restart", context do
    {reader, child, _monitors} = held_reader(context.supervisor)
    child_monitor = Process.monitor(child)
    ref = reader.ref
    Process.exit(reader.pid, :kill)
    assert_down(reader, :killed)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :killed}, @receive_timeout
    refute Process.alive?(child)
    refute_receive {:tracker_read_result, ^ref, _result}, 0
    refute_receive {:read_started, _pid, _monitors}, 0
    refute Enum.any?(Task.Supervisor.children(context.supervisor), &Process.alive?/1)
  end

  test "read child death returns an explicit error and does not prevent another independent read", context do
    {reader, child, _monitors} = held_reader(context.supervisor)
    Process.exit(child, :kill)
    assert_result_and_down(reader, {:error, {:tracker_reader_exit, :killed}})

    assert {:ok, next} = TrackerReader.start(fn -> {:ok, :fresh} end, supervisor: context.supervisor)
    assert next.ref != reader.ref
    assert_result_and_down(next, {:ok, :fresh})
  end

  test "only the handle owner can request cancellation", context do
    {reader, child, _monitors} = held_reader(context.supervisor)
    owner = self()

    {other, other_monitor} =
      spawn_monitor(fn -> send(owner, {:foreign_cancel, TrackerReader.cancel(reader)}) end)

    assert_receive {:foreign_cancel, {:error, :not_reader_owner}}, @receive_timeout
    assert_receive {:DOWN, ^other_monitor, :process, ^other, :normal}, @receive_timeout
    assert Process.alive?(child)
    send(child, {:release_read, {:ok, :not_cancelled}})
    assert_result_and_down(reader, {:ok, :not_cancelled})
  end

  test "supervisor shutdown terminates the read before its guardian exits", context do
    {reader, child, _monitors} = held_reader(context.supervisor)
    ref = reader.ref
    assert :ok = stop_supervised(Task.Supervisor)
    assert_down(reader, :shutdown)
    refute Process.alive?(child)
    refute_receive {:tracker_read_result, ^ref, _result}, 0
  end

  defp held_reader(supervisor) do
    owner = self()

    {:ok, reader} =
      TrackerReader.start(
        fn ->
          {:monitors, monitors} = Process.info(owner, :monitors)
          send(owner, {:read_started, self(), monitors})

          receive do
            {:release_read, result} -> result
          end
        end,
        supervisor: supervisor
      )

    assert_receive {:read_started, child, monitors}, @receive_timeout
    {reader, child, monitors}
  end

  defp assert_result_and_down(reader, expected) do
    ref = reader.ref
    assert_receive {:tracker_read_result, ^ref, ^expected}, @receive_timeout
    assert_down(reader, :normal)
    refute_receive {:tracker_read_result, ^ref, _duplicate}, 0
  end

  defp assert_down(reader, expected) do
    monitor = reader.monitor
    pid = reader.pid
    assert_receive {:DOWN, ^monitor, :process, ^pid, ^expected}, @receive_timeout
    refute Process.alive?(pid)
  end
end
