defmodule SymphonyElixir.OwnedHookTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.OwnedHook

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-owned-hook-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/OWNED-1")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "preserve"), "owned fixture bytes")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))

    on_exit(fn ->
      cleanup_registered!(root)
      File.rm_rf!(root)
    end)

    {:ok, root: root, workspace: workspace}
  end

  test "preserves combined bytes and exit status after physical group closure", c do
    assert {:ok, {"stdoutstderr" <> <<255, 0>>, 17}} =
             OwnedHook.run("printf stdout; printf stderr >&2; printf '\\377\\000'; exit 17", c.workspace, 2_000)

    assert {:ok, {"ok", 0}} = OwnedHook.run("printf ok", c.workspace, 2_000)
  end

  test "timeout closes the shell, child and owned process group before returning", c do
    command = tree_command(c.root, false)
    task = Task.async(fn -> OwnedHook.run(command, c.workspace, 2_000) end)
    identities = register_tree!(c.root)
    assert {:error, :timeout} = Task.await(task, 5_500)
    assert_tree_absent!(identities)
  end

  test "TERM-ignoring shell and child are escalated and physically absent", c do
    task = Task.async(fn -> OwnedHook.run(tree_command(c.root, true), c.workspace, 2_000) end)
    identities = register_tree!(c.root)
    assert {:error, :timeout} = Task.await(task, 5_500)
    assert_tree_absent!(identities)
  end

  test "normal shell completion closes its still-running background child", c do
    command = tree_command(c.root, false, "while [ ! -f '#{c.root}/finish' ]; do sleep 0.01; done; exit 0")
    task = Task.async(fn -> OwnedHook.run(command, c.workspace, 5_000) end)
    identities = register_tree!(c.root)
    File.write!(Path.join(c.root, "finish"), "go")
    assert {:ok, {_output, 0}} = Task.await(task, 4_000)
    assert_tree_absent!(identities)
  end

  test "caller death does not orphan the native group", c do
    caller = spawn(fn -> OwnedHook.run(tree_command(c.root, true), c.workspace, 10_000) end)
    identities = register_tree!(c.root)
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 1_000
    await!(fn -> tree_absent?(identities) end, 4_000)
    assert_tree_absent!(identities)
  end

  test "custodian death closes its Port and native EOF cleans the physical group", c do
    task = Task.async(fn -> OwnedHook.run(tree_command(c.root, true), c.workspace, 10_000) end)
    identities = register_tree!(c.root)
    port = native_port!(identities.helper.pid)
    {:connected, custodian} = Port.info(port, :connected)
    Process.exit(custodian, :kill)
    assert {:error, {:cleanup_uncertain, {:owner_down, :killed}}} = Task.await(task, 2_000)
    await!(fn -> tree_absent?(identities) end, 4_000)
    assert_tree_absent!(identities)
  end

  for signal <- ["TERM", "HUP"] do
    @signal signal
    test "helper #{@signal} initiates group cleanup instead of exiting early", c do
      task = Task.async(fn -> OwnedHook.run(tree_command(c.root, true), c.workspace, 10_000) end)
      identities = register_tree!(c.root)
      signal_exact!(identities.helper, @signal)
      assert {:error, {:native_interrupted, %{trigger: 3, certain: 1}, _identity}} = Task.await(task, 4_000)
      assert_tree_absent!(identities)
    end
  end

  test "fatal helper death remains uncertain and before_remove preserves workspace", c do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(c.workspace), hook_before_remove: tree_command(c.root, true), hook_timeout_ms: 10_000)
    task = Task.async(fn -> Workspace.remove(c.workspace) end)
    identities = register_tree!(c.root)
    signal_exact!(identities.helper, "KILL")

    assert {:error, {:workspace_hook_owned_execution, "before_remove", {:cleanup_uncertain, _evidence}}, ""} =
             Task.await(task, 4_000)

    assert File.read!(Path.join(c.workspace, "preserve")) == "owned fixture bytes"
    # A fatal helper is outside the guarantee. Teardown uses captured OS identities,
    # never the BEAM DOWN or the error return as proof that descendants stopped.
    cleanup_registered!(c.root)
    assert_tree_absent!(identities)
  end

  test "legacy before_remove timeout deletes only after confirmed physical closure", c do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(c.workspace), hook_before_remove: tree_command(c.root, true), hook_timeout_ms: 2_000)
    task = Task.async(fn -> Workspace.remove(c.workspace) end)
    identities = register_tree!(c.root)
    assert {:ok, _paths} = Task.await(task, 5_500)
    assert_tree_absent!(identities)
    refute File.exists?(c.workspace)
  end

  test "missing shell returns a visible startup error and performs no hook effect", c do
    original = System.get_env("PATH")

    try do
      System.put_env("PATH", "")

      assert {:error, {:start_failed, :shell_not_found}} =
               OwnedHook.run("touch '#{c.workspace}/unexpected'", c.workspace, 2_000)
    after
      restore_env("PATH", original)
    end

    refute File.exists?(Path.join(c.workspace, "unexpected"))
    assert File.read!(Path.join(c.workspace, "preserve")) == "owned fixture bytes"
  end

  for status <- [0, 17] do
    @status status
    test "artifact cleanup failure retains the confirmed primary exit #{@status}", c do
      ending = "while [ ! -f '#{c.root}/finish' ]; do sleep 0.01; done; printf primary; exit #{@status}"
      task = Task.async(fn -> OwnedHook.run(tree_command(c.root, false, ending), c.workspace, 5_000) end)
      identities = register_tree!(c.root)
      {:name, path} = Port.info(native_port!(identities.helper.pid), :name)
      blocker = Path.join(Path.dirname(to_string(path)), "cleanup-blocker")
      File.write!(blocker, "owned cleanup evidence")

      try do
        File.write!(Path.join(c.root, "finish"), "go")

        assert {:error, {:artifact_cleanup_failed, {:ok, {"primary", @status}}, [{:directory, {:error, cleanup_errno}}]}} =
                 Task.await(task, 4_000)

        assert cleanup_errno in [:eexist, :enotempty]
        assert_tree_absent!(identities)
      after
        File.rm!(blocker)
      end
    end
  end

  test "suspended TaskSupervisor cannot block the caller-owned hook", c do
    supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)
    assert is_pid(supervisor)
    assert Task.Supervisor.children(supervisor) == []
    :ok = :sys.suspend(supervisor)

    try do
      started = System.monotonic_time(:millisecond)
      assert {:ok, {"independent", 0}} = OwnedHook.run("printf independent", c.workspace, 1_500)
      assert System.monotonic_time(:millisecond) - started < 4_500
      assert Process.alive?(supervisor)
      assert File.read!(Path.join(c.workspace, "preserve")) == "owned fixture bytes"
    after
      :ok = :sys.resume(supervisor)
    end
  end

  test "stopped TaskSupervisor is not a new hook admission dependency", c do
    supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)
    assert is_pid(supervisor)
    assert Task.Supervisor.children(supervisor) == []
    monitor = Process.monitor(supervisor)
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)

    try do
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}, 1_000
      assert Process.whereis(SymphonyElixir.TaskSupervisor) == nil
      started = System.monotonic_time(:millisecond)
      assert {:ok, {"independent", 17}} = OwnedHook.run("printf independent; exit 17", c.workspace, 1_500)
      assert System.monotonic_time(:millisecond) - started < 4_500
      assert Process.whereis(SymphonyElixir.TaskSupervisor) == nil
      assert File.read!(Path.join(c.workspace, "preserve")) == "owned fixture bytes"
    after
      assert {:ok, restarted} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)
      assert is_pid(restarted)
      assert Process.whereis(SymphonyElixir.TaskSupervisor) == restarted
      Process.demonitor(monitor, [:flush])
    end
  end

  test "native final receipt keeps signal diagnostics alongside physically proven closure", c do
    ending = "while [ ! -f '#{c.root}/finish' ]; do sleep 0.01; done; printf primary; exit 17"
    task = Task.async(fn -> OwnedHook.run(tree_command(c.root, false, ending), c.workspace, 5_000) end)
    identities = register_tree!(c.root)
    port = native_port!(identities.helper.pid)
    {:connected, custodian} = Port.info(port, :connected)
    custodian_monitor = Process.monitor(custodian)
    assert 1 == :erlang.trace(custodian, true, [:receive, {:tracer, self()}])

    try do
      File.write!(Path.join(c.root, "finish"), "go")
      assert {:ok, {"primary", 17}} = Task.await(task, 4_000)
      assert_receive {:trace, ^custodian, :receive, {^port, {:data, <<"F", receipt::binary>>}}}, 1_000
      child = identities.shell.pid
      assert [1, 0, 17, 1, phase, reason, ^child] = Enum.map(String.split(receipt, " "), &String.to_integer/1)
      assert phase in [0, 5, 7]
      if phase == 0, do: assert(reason == 0), else: assert(reason > 0)
      assert_tree_absent!(identities)
    after
      assert_receive {:DOWN, ^custodian_monitor, :process, ^custodian, :normal}, 1_000
    end
  end

  test "deadline receipt needs final physical absence even after intermediate signal or probe errors", c do
    task = Task.async(fn -> OwnedHook.run(tree_command(c.root, true), c.workspace, 2_000) end)
    identities = register_tree!(c.root)
    port = native_port!(identities.helper.pid)
    {:connected, custodian} = Port.info(port, :connected)
    custodian_monitor = Process.monitor(custodian)
    assert 1 == :erlang.trace(custodian, true, [:receive, {:tracer, self()}])

    try do
      assert {:error, :timeout} = Task.await(task, 5_500)
      assert_receive {:trace, ^custodian, :receive, {^port, {:data, <<"F", receipt::binary>>}}}, 1_000
      child = identities.shell.pid
      assert [1, 1, 137, 1, phase, reason, ^child] = Enum.map(String.split(receipt, " "), &String.to_integer/1)
      assert phase in [0, 5, 7]
      if phase == 0, do: assert(reason == 0), else: assert(reason > 0)
      assert_tree_absent!(identities)
    after
      assert_receive {:DOWN, ^custodian_monitor, :process, ^custodian, :normal}, 1_000
    end
  end

  defp tree_command(root, ignore_term, ending \\ "wait") do
    trap = if ignore_term, do: "trap '' TERM; ", else: ""
    child = "#{trap}printf '%s\\n' \"$$\" > '#{root}/child.pid'; exec sleep 30"

    "#{trap}printf '%s\\n' \"$$\" > '#{root}/shell.pid'; " <>
      "printf '%s\\n' \"$PPID\" > '#{root}/helper.pid'; " <>
      "sh -c #{shell_quote(child)} & " <>
      "while [ ! -s '#{root}/child.pid' ]; do sleep 0.01; done; #{ending}"
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp register_tree!(root) do
    await!(
      fn ->
        Enum.all?(["shell", "helper", "child"], fn role ->
          case File.read(Path.join(root, role <> ".pid")) do
            {:ok, text} -> String.trim(text) != ""
            {:error, :enoent} -> false
            other -> flunk("PID receipt read failed: #{inspect(other)}")
          end
        end)
      end,
      1_500
    )

    identities =
      Map.new([:shell, :helper, :child], fn role ->
        pid = Path.join(root, "#{role}.pid") |> File.read!() |> String.trim() |> String.to_integer()
        identity = process_identity(pid)
        assert identity != nil
        {role, identity}
      end)

    assert identities.shell.pid == identities.shell.pgid
    assert identities.child.pgid == identities.shell.pgid
    assert identities.shell.ppid == identities.helper.pid
    assert identities.helper.pgid != identities.shell.pgid
    port = native_port!(identities.helper.pid)
    {:name, path} = Port.info(port, :name)
    identity_file = %{processes: identities, artifact: to_string(path)}
    File.write!(Path.join(root, "identities.json"), Jason.encode!(identity_file))
    identities
  end

  defp native_port!(helper_pid) do
    port = Enum.find(Port.list(), &(Port.info(&1, :os_pid) == {:os_pid, helper_pid}))
    assert is_port(port)
    port
  end

  defp process_identity(pid) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "lstart=", "-o", "command="], stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(String.trim(output), ~r/\s+/, parts: 4) do
          [pid, parent, group, fingerprint] -> %{pid: String.to_integer(pid), ppid: String.to_integer(parent), pgid: String.to_integer(group), fingerprint: fingerprint}
          other -> flunk("Unexpected ps identity response: #{inspect(other)}")
        end

      {output, 1} ->
        assert String.trim(output) == ""
        nil

      {_output, status} ->
        flunk("ps identity failed with status #{status}")
    end
  end

  defp same_identity?(expected, actual),
    do: actual != nil and Map.take(actual, [:pid, :pgid, :fingerprint]) == Map.take(expected, [:pid, :pgid, :fingerprint])

  defp signal_exact!(identity, signal) do
    assert same_identity?(identity, process_identity(identity.pid))
    {_output, 0} = System.cmd("/bin/kill", ["-s", signal, Integer.to_string(identity.pid)], stderr_to_stdout: true)
  end

  defp group_members(group) do
    {output, 0} = System.cmd("/bin/ps", ["-axo", "pid=,pgid="], stderr_to_stdout: true)

    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/\s+/) do
        [pid, pgid] -> if String.to_integer(pgid) == group, do: [String.to_integer(pid)], else: []
        other -> flunk("Unexpected ps group response: #{inspect(other)}")
      end
    end)
  end

  defp tree_absent?(identities),
    do: Enum.all?(identities, fn {_role, identity} -> process_identity(identity.pid) == nil end) and group_members(identities.shell.pgid) == []

  defp assert_tree_absent!(identities) do
    assert tree_absent?(identities)
  end

  defp cleanup_registered!(root) do
    file = Path.join(root, "identities.json")

    if File.exists?(file) do
      data = file |> File.read!() |> Jason.decode!()

      identities =
        Map.new(data["processes"], fn {role, value} ->
          {String.to_existing_atom(role), %{pid: value["pid"], ppid: value["ppid"], pgid: value["pgid"], fingerprint: value["fingerprint"]}}
        end)

      if same_identity?(identities.helper, process_identity(identities.helper.pid)) do
        signal_exact!(identities.helper, "TERM")
        await!(fn -> process_identity(identities.helper.pid) == nil end, 4_000)
      end

      if same_identity?(identities.shell, process_identity(identities.shell.pid)) do
        {_output, 0} = System.cmd("/bin/kill", ["-s", "KILL", "--", "-#{identities.shell.pgid}"], stderr_to_stdout: true)
      end

      await!(fn -> tree_absent?(identities) end, 4_000)
      artifact = data["artifact"]
      assert Path.basename(artifact) == "owner"
      assert String.starts_with?(Path.basename(Path.dirname(artifact)), "symphony-owned-hook-")
      assert Path.dirname(Path.dirname(artifact)) == Path.expand(System.tmp_dir!())
      # A killed BEAM custodian cannot remove its temp executable; only remove the
      # exact captured artifact after independent OS absence, without recursive rm.
      assert File.rm(artifact) in [:ok, {:error, :enoent}]
      assert File.rmdir(Path.dirname(artifact)) in [:ok, {:error, :enoent}]
    else
      # A partial startup receipt is a failed teardown, not proof of no process.
      # Preserve the fixture for root instead of recursively deleting its evidence.
      refute Enum.any?(["shell", "helper", "child"], &File.exists?(Path.join(root, &1 <> ".pid"))),
             "Incomplete native identity receipt; owned fixture retained for diagnosis"
    end
  end

  defp await!(predicate, budget) do
    deadline = System.monotonic_time(:millisecond) + budget
    await_until!(predicate, deadline)
  end

  defp await_until!(predicate, deadline) do
    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_until!(predicate, deadline)
    end
  end
end
