defmodule SymphonyElixir.OwnedProviderTransportTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ProviderTransport
  alias SymphonyElixir.RunLedger

  setup do
    root = "/private/tmp/provider-transport-#{System.unique_integer([:positive])}"
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "STREAM-1")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    assert {_, 0} = System.cmd(System.find_executable("git"), ["init", "-q", "-b", "main"], cd: workspace, stderr_to_stdout: true)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)

    policy = %{
      "version" => 1,
      "backend" => "macos_deny_default_v1",
      "workspace_root" => workspace_root,
      "shell" => "/bin/bash",
      "executables" => Enum.map(["/bin/bash", "/bin/sleep"], &tool/1),
      "read_roots" => []
    }

    path = Path.join(root, "policy.json")
    bytes = Jason.encode!(policy)
    File.write!(path, bytes)
    File.chmod!(path, 0o400)

    on_exit(fn ->
      cleanup_registered!(root)
      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, selection: %{policy_file: path, sha256: digest(bytes), timeout_ms: 5000, workflow_file: Workflow.workflow_file_path()}}
  end

  test "stream v2 preserves input fragments, independent stderr and real child status", c do
    {:ok, handle, _identity} = open(c, "printf 'diagnostic\\n' >&2; IFS= read -r value; printf '%s\\n' \"$value\"; exit 17")
    payload = String.duplicate("a", 40_000)

    try do
      assert :ok = ProviderTransport.command(handle, payload <> "\n")
      events = drain(handle, [])
      assert {:data, {:eol, ^payload}} = Enum.find(events, &match?({:data, _}, &1))
      assert {:stderr, "diagnostic\n"} in events
      assert List.last(events) == {:exit_status, 17}
      assert :ok = ProviderTransport.close(handle)
      assert :ok = ProviderTransport.close(handle)
      [started, finished] = boundary_events()
      assert started["event_type"] == "execution.boundary.started"
      assert finished["metadata"]["started_event_id"] == started["event_id"]
      assert finished["metadata"]["certain"] == 1
      assert finished["metadata"]["exit_status"] == 17
    after
      assert :ok = ProviderTransport.close(handle)
    end
  end

  for {suffix, accepted} <- [{"xyz\n", true}, {"xyz-too-large\n", false}] do
    @tag line_suffix: suffix, accepted_line: accepted
    test "fragmented line #{inspect(suffix)} respects the absolute 1 MiB frame limit", c do
      # The first write ends below the limit. The final write contains LF and
      # either ends exactly at the limit or crosses it in the same native chunk.
      prefix_size = 1_048_576 - 4

      command =
        "printf '%#{prefix_size}s' x; printf 'prefix-written\\n' >&2; " <>
          "IFS= read -r release; printf '%s' " <> quote_shell(c.line_suffix)

      {:ok, handle, _} = open(c, command)
      deadline = elem(handle, 4)

      try do
        assert {:stderr, "prefix-written\n"} = ProviderTransport.recv(handle, 4000)
        # Drain the already-written stdout tail while the child waits on stdin.
        # A public receive timeout does not grant another lifetime to that child.
        assert :timeout = ProviderTransport.recv(handle, 250)
        assert elem(handle, 4) == deadline
        assert :ok = ProviderTransport.command(handle, "release\n")

        if c.accepted_line do
          assert {:data, {:eol, line}} = ProviderTransport.recv(handle, 4000)
          assert byte_size(line) == 1_048_575
          assert line == String.duplicate(" ", prefix_size - 1) <> "xxyz"
          assert {:exit_status, 0} = ProviderTransport.recv(handle, 4000)
        else
          assert {:data, {:noeol, fragment}} = ProviderTransport.recv(handle, 4000)
          assert byte_size(fragment) == 1_048_576
          assert fragment == String.duplicate(" ", prefix_size - 1) <> "xxyz-"
        end
      after
        assert :ok = ProviderTransport.close(handle)
      end

      [started, finished] = boundary_events()
      assert finished["metadata"]["started_event_id"] == started["event_id"]
      assert finished["metadata"]["certain"] == 1
      assert elem(handle, 4) == deadline
    end
  end

  test "child protocol-looking output is ordinary data, never a native receipt", c do
    {:ok, handle, _} = open(c, "printf 'R2 1 2\\nF2 0 0 1 0 0 1\\n'; exit 19")
    assert drain(handle, []) == [{:data, {:eol, "R2 1 2"}}, {:data, {:eol, "F2 0 0 1 0 0 1"}}, {:exit_status, 19}]
    assert :ok = ProviderTransport.close(handle)
    assert List.last(boundary_events())["metadata"]["exit_status"] == 19
  end

  test "an expired start cannot execute or append a started receipt", c do
    launch = %{provider: "codex", command: {:shell, "printf wrong > late"}, started_at: now() - 10_000}
    assert {:error, :timeout} = ProviderTransport.open(c.workspace, launch, c.selection)
    refute File.exists?(Path.join(c.workspace, "late"))
    assert boundary_events() == []
  end

  test "ledger rejection precedes the native start gate", c do
    path = RunLedger.ledger_file_path()
    File.mkdir_p!(Path.dirname(path))
    original = File.read(path)
    if match?({:ok, _}, original), do: File.rm!(path)
    File.mkdir!(path)

    try do
      assert {:error, %RunLedger.PersistenceError{}} = open(c, "printf wrong > effect")
      refute File.exists?(Path.join(c.workspace, "effect"))
    after
      File.rmdir!(path)

      case original do
        {:ok, bytes} -> File.write!(path, bytes)
        {:error, :enoent} -> :ok
      end
    end
  end

  test "failed finish persistence preserves the physical receipt and is never retried", c do
    {:ok, handle, _} = open(c, "IFS= read -r value; printf done")
    path = RunLedger.ledger_file_path()
    original = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)

    failure =
      try do
        assert :ok = ProviderTransport.command(handle, "finish\n")
        assert {:data, {:noeol, "done"}} = ProviderTransport.recv(handle, 4000)
        assert {:transport_error, {:provider_audit_failed, {:ok, %{receipt: %{certain: 1}}}, %RunLedger.PersistenceError{}} = reason} = ProviderTransport.recv(handle, 4000)
        assert {:error, ^reason} = ProviderTransport.close(handle)
        reason
      after
        File.rmdir!(path)
        File.write!(path, original)
      end

    assert {:error, ^failure} = ProviderTransport.close(handle)
    assert [started] = boundary_events()
    assert started["event_type"] == "execution.boundary.started"
    assert File.read!(path) == original
  end

  test "direct transport retains one ledger path when configuration changes before close", c do
    original_config = Application.get_env(:symphony_elixir, :log_file)
    assert {:ok, original_path} = RunLedger.ledger_file_path_checked()
    replacement = Path.join(c.root, "replacement/run_ledger.jsonl")
    File.mkdir_p!(Path.dirname(replacement))
    File.write!(replacement, "")
    {:ok, handle, _} = open(c, "IFS= read -r value; printf '%s\\n' \"$value\"")

    try do
      Application.put_env(:symphony_elixir, :log_file, Path.join(Path.dirname(replacement), "runtime.log"))
      assert {:ok, ^replacement} = RunLedger.ledger_file_path_checked()
      assert :ok = ProviderTransport.command(handle, "close\n")
      assert [{:data, {:eol, "close"}}, {:exit_status, 0}] = drain(handle, [])
      assert :ok = ProviderTransport.close(handle)
      [started, finished] = File.read!(original_path) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      assert started["event_type"] == "execution.boundary.started"
      assert finished["event_type"] == "execution.boundary.finished"
      assert finished["metadata"]["started_event_id"] == started["event_id"]
      assert finished["metadata"]["certain"] == 1
      for event <- [started, finished], do: assert({:ok, ^event} = RunLedger.CheckedStorage.fetch(original_path, event["event_id"]))
      assert File.read!(replacement) == ""
    after
      if original_config == nil, do: Application.delete_env(:symphony_elixir, :log_file), else: Application.put_env(:symphony_elixir, :log_file, original_config)
      assert :ok = ProviderTransport.close(handle)
    end

    assert File.read!(replacement) == ""
  end

  test "input is bounded before it is sent and another process has no write or close authority", c do
    {:ok, handle, _} = open(c, "IFS= read -r value; printf '%s\\n' \"$value\"")

    try do
      assert {:error, :provider_input_limit} = ProviderTransport.command(handle, String.duplicate("x", 1_048_577))
      task = Task.async(fn -> {ProviderTransport.command(handle, "wrong\n"), ProviderTransport.close(handle)} end)
      assert {{:error, :foreign_stream_owner}, {:error, :foreign_stream_owner}} = Task.await(task)
      assert :ok = ProviderTransport.command(handle, "right\n")
      assert [{:data, {:eol, "right"}}, {:exit_status, 0}] = drain(handle, [])
    after
      assert :ok = ProviderTransport.close(handle)
    end
  end

  test "paused caller receives at most one credited output chunk and can still close", c do
    {:ok, handle, _} = open(c, "printf ready > producing; while :; do printf 'bounded-output-chunk'; done")
    await!(fn -> File.exists?(Path.join(c.workspace, "producing")) end, 5_000)
    Process.sleep(100)
    {:messages, messages} = Process.info(self(), :messages)
    chunks = Enum.filter(messages, &match?({^handle, {:chunk, _, _}}, &1))
    assert length(chunks) == 1
    assert byte_size(elem(elem(hd(chunks), 1), 2)) <= 16_384
    assert :ok = ProviderTransport.close(handle)
    assert List.last(boundary_events())["metadata"]["certain"] == 1
  end

  test "blocked stdin cannot extend the original lifetime or replay a partial request", c do
    c = put_in(c.selection.timeout_ms, 1000)
    {:ok, handle, identity} = open(c, tree_command() <> "; wait")
    tree = register_tree!(c, handle, identity)
    assert {:error, :receive_timeout} = ProviderTransport.command(handle, String.duplicate("x", 1_048_576))
    assert {:error, :provider_deadline} = ProviderTransport.command(handle, "replay")
    assert :ok = ProviderTransport.close(handle)
    assert_tree_absent!(tree)
    [_, finished] = boundary_events()
    assert finished["metadata"]["trigger"] == 1
  end

  test "absolute deadline closes the real process group despite activity", c do
    c = put_in(c.selection.timeout_ms, 1200)
    {:ok, handle, identity} = open(c, tree_command() <> "; while IFS= read -r value; do printf '%s\\n' \"$value\"; done")
    tree = register_tree!(c, handle, identity)
    assert :ok = ProviderTransport.command(handle, "first\n")
    assert {:data, {:eol, "first"}} = ProviderTransport.recv(handle, 1000)
    assert {:transport_error, :provider_deadline} = ProviderTransport.recv(handle, 3000)
    assert :ok = ProviderTransport.close(handle)
    assert_tree_absent!(tree)
    assert List.last(boundary_events())["metadata"]["trigger"] == 1
  end

  test "caller death is independently witnessed as OS absence and resource cleanup", c do
    observer = self()

    caller =
      spawn(fn ->
        {:ok, handle, identity} = open(c, tree_command() <> "; wait")
        send(observer, {:opened, self(), handle, identity})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:opened, ^caller, handle, identity}, 5_000
    tree = register_tree!(c, handle, identity)
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 5_000
    # Custodian cleanup of the boundary root and artifact can trail the process tree's exit.
    await!(fn -> tree_absent?(tree) and not File.exists?(tree.boundary_root) and not File.exists?(tree.artifact) end, 5_000)
    # The dead caller cannot persist a finish event; do not fabricate one.
    assert Enum.map(boundary_events(), & &1["event_type"]) == ["execution.boundary.started"]
  end

  for signal <- ["TERM", "HUP"] do
    @tag signal: signal
    test "native #{signal} performs cleanup before a certain receipt", c do
      {:ok, handle, identity} = open(c, tree_command() <> "; wait")
      tree = register_tree!(c, handle, identity)
      signal_exact!(tree.processes.helper, c.signal)
      assert {:transport_error, {:provider_interrupted, nil, 3}} = ProviderTransport.recv(handle, 4000)
      assert :ok = ProviderTransport.close(handle)
      assert_tree_absent!(tree)
      assert List.last(boundary_events())["metadata"]["certain"] == 1
    end
  end

  test "custodian death closes its OS channel without claiming a received finish", c do
    {:ok, handle, identity} = open(c, tree_command() <> "; wait")
    tree = register_tree!(c, handle, identity)
    Process.exit(elem(handle, 1), :kill)
    assert {:transport_error, {:provider_cleanup_uncertain, :custodian_down}} = ProviderTransport.recv(handle, 4000)
    await!(fn -> tree_absent?(tree) end, 5_000)
    assert {:error, {:provider_cleanup_uncertain, :custodian_down}} = ProviderTransport.close(handle)
    assert List.last(boundary_events())["metadata"]["certain"] == 0
  end

  test "helper SIGKILL stays uncertain and retains physical evidence until independent cleanup", c do
    {:ok, handle, identity} = open(c, tree_command() <> "; wait")
    tree = register_tree!(c, handle, identity)
    signal_exact!(tree.processes.helper, "KILL")
    assert {:transport_error, {:provider_cleanup_uncertain, _}} = ProviderTransport.recv(handle, 4000)
    assert {:error, {:provider_cleanup_uncertain, _}} = ProviderTransport.close(handle)
    assert File.exists?(tree.boundary_root)
    assert File.exists?(tree.artifact)
    assert List.last(boundary_events())["metadata"]["certain"] == 0
    # on_exit uses captured PID/start identity, not Task DOWN or Port.close.
  end

  defp open(c, command) do
    ProviderTransport.open(c.workspace, %{provider: "codex", command: {:shell, command}, started_at: now()}, c.selection)
  end

  defp drain(handle, events) do
    case ProviderTransport.recv(handle, 4000) do
      {:exit_status, _} = event -> Enum.reverse([event | events])
      {:data, _} = event -> drain(handle, [event | events])
      {:stderr, _} = event -> drain(handle, [event | events])
      other -> flunk("unexpected transport event: #{inspect(other)}")
    end
  end

  defp boundary_events, do: RunLedger.recent_entries() |> Enum.filter(&String.starts_with?(&1["event_type"], "execution.boundary."))

  defp tree_command do
    ~s|trap '' TERM; printf '%s\\n%s\\n' "$HOME" "$TMPDIR" > roots; | <>
      ~s|/bin/bash -c 'trap "" TERM; printf "%s\\n" "$$" > descendant.pid; exec /bin/sleep 30' & | <>
      "while [ ! -s descendant.pid ]; do /bin/sleep 0.01; done"
  end

  defp register_tree!(c, handle, identity) do
    await!(fn -> File.exists?(Path.join(c.workspace, "descendant.pid")) and File.exists?(Path.join(c.workspace, "roots")) end, 5_000)
    descendant = Path.join(c.workspace, "descendant.pid") |> File.read!() |> String.trim() |> String.to_integer()
    [home, _tmp] = File.read!(Path.join(c.workspace, "roots")) |> String.split("\n", trim: true)
    processes = %{child: process_identity(identity.child), helper: process_identity(identity.helper), descendant: process_identity(descendant)}
    assert Enum.all?(processes, fn {_role, value} -> is_map(value) end)
    assert processes.child.pgid == identity.pgid and processes.descendant.pgid == identity.pgid
    assert processes.child.ppid == identity.helper
    port = Enum.find(Port.list(), &(Port.info(&1, :os_pid) == {:os_pid, identity.helper}))
    assert is_port(port)
    {:name, artifact} = Port.info(port, :name)
    tree = %{processes: processes, boundary_root: Path.dirname(home), artifact: to_string(artifact)}
    File.write!(Path.join(c.root, "identities.json"), Jason.encode!(tree))
    assert elem(handle, 1) == elem(Port.info(port, :connected), 1)
    tree
  end

  defp process_identity(pid) do
    case System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "lstart=", "-o", "command="], stderr_to_stdout: true) do
      {text, 0} ->
        [pid, parent, group, fingerprint] = String.split(String.trim(text), ~r/\s+/, parts: 4)
        %{pid: String.to_integer(pid), ppid: String.to_integer(parent), pgid: String.to_integer(group), fingerprint: fingerprint}

      {text, 1} ->
        assert String.trim(text) == ""
        nil

      {_text, status} ->
        flunk("ps failed: #{status}")
    end
  end

  defp same_identity?(expected, actual), do: actual != nil and Map.take(expected, [:pid, :pgid, :fingerprint]) == Map.take(actual, [:pid, :pgid, :fingerprint])

  defp signal_exact!(identity, signal) do
    assert same_identity?(identity, process_identity(identity.pid))
    assert {_, 0} = System.cmd("/bin/kill", ["-s", signal, to_string(identity.pid)], stderr_to_stdout: true)
  end

  defp tree_absent?(tree) do
    {rows, 0} = System.cmd("/bin/ps", ["-axo", "pid=,pgid="])
    group = tree.processes.child.pgid

    group_absent =
      Enum.all?(String.split(rows, "\n", trim: true), fn row ->
        [_pid, pgid] = String.split(String.trim(row), ~r/\s+/)
        String.to_integer(pgid) != group
      end)

    group_absent and Enum.all?(tree.processes, fn {_role, identity} -> process_identity(identity.pid) == nil end)
  end

  defp assert_tree_absent!(tree), do: assert(tree_absent?(tree))

  defp cleanup_registered!(root) do
    case File.read(Path.join(root, "identities.json")) do
      {:ok, bytes} ->
        data = Jason.decode!(bytes)

        processes =
          Map.new(data["processes"], fn {key, value} ->
            {String.to_existing_atom(key), Map.new(value, fn {field, v} -> {String.to_existing_atom(field), v} end)}
          end)

        tree = %{processes: processes, artifact: data["artifact"], boundary_root: data["boundary_root"]}
        if same_identity?(processes.helper, process_identity(processes.helper.pid)), do: signal_exact!(processes.helper, "TERM")

        if same_identity?(processes.child, process_identity(processes.child.pid)) do
          assert {_, 0} = System.cmd("/bin/kill", ["-s", "KILL", "--", "-#{processes.child.pgid}"], stderr_to_stdout: true)
        end

        await!(fn -> tree_absent?(tree) end, 5_000)
        assert Path.dirname(tree.boundary_root) == "/private/tmp"
        assert String.starts_with?(Path.basename(tree.boundary_root), "symphony-boundary-")
        assert Path.basename(tree.artifact) == "owner"
        assert Path.dirname(Path.dirname(tree.artifact)) == Path.expand(System.tmp_dir!())
        assert String.starts_with?(Path.basename(Path.dirname(tree.artifact)), "symphony-owned-hook-")
        File.rm_rf!(tree.boundary_root)
        assert File.rm(tree.artifact) in [:ok, {:error, :enoent}]
        assert File.rmdir(Path.dirname(tree.artifact)) in [:ok, {:error, :enoent}]

      {:error, :enoent} ->
        refute File.exists?(Path.join(root, "workspaces/STREAM-1/descendant.pid")), "Partial PID receipt retained for diagnosis"

      {:error, reason} ->
        flunk("identity receipt failed: #{inspect(reason)}")
    end
  end

  defp await!(fun, budget), do: await_until!(fun, now() + budget)

  defp await_until!(fun, limit) do
    unless fun.() do
      assert now() < limit
      Process.sleep(10)
      await_until!(fun, limit)
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp tool(path), do: %{"path" => path, "sha256" => digest(File.read!(path))}
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp now, do: System.monotonic_time(:millisecond)
end
