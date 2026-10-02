defmodule SymphonyElixir.ProviderBoundaryTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.AgentProvider.{Claude, CodexCLI}
  alias SymphonyElixir.ProviderTransport
  alias SymphonyElixir.RunLedger

  setup do
    root = "/private/tmp/provider-boundary-#{System.unique_integer([:positive])}"
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "PROVIDER-1")
    bin = Path.join(root, "bin")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    assert {_, 0} = System.cmd(System.find_executable("git"), ["init", "-q", "-b", "main"], cd: workspace, stderr_to_stdout: true)
    File.mkdir_p!(bin)
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      codex_command: quote_shell(Path.join(bin, "app-server")),
      codex_approval_policy: "never"
    )

    on_exit(fn ->
      # This suite always closes through the public adapter, including terminal cases.
      # A surviving PID prevents deletion of the fixture and its OS witness.
      for name <- ["claude", "codex", "app-server"] do
        path = Path.join(workspace, name <> ".pid")

        case File.read(path) do
          {:ok, bytes} -> assert_absent!(String.to_integer(String.trim(bytes)))
          {:error, :enoent} -> :ok
          {:error, cause} -> flunk("PID witness unavailable: #{inspect(cause)}")
        end
      end

      File.rm_rf!(root)
    end)

    %{
      root: root,
      workspace_root: workspace_root,
      workspace: workspace,
      bin: bin,
      policy_path: Path.join(root, "policy.json"),
      base_workflow: File.read!(Workflow.workflow_file_path()),
      issue: %{id: "provider-issue", identifier: "PROVIDER-1", title: "Exercise selected transport"}
    }
  end

  test "selection is explicit: absent is legacy and invalid is never legacy", c do
    assert {:ok, :legacy} = Config.provider_execution_boundary()
    assert {:ok, %{provider_boundary: :legacy}} = Claude.start_session(c.workspace)
    assert {:ok, %{provider_boundary: :legacy}} = CodexCLI.start_session(c.workspace)
    select!(c, nil)
    assert {:error, :invalid_execution_boundary_selection} = Claude.start_session(c.workspace)
    assert {:error, :invalid_execution_boundary_selection} = CodexCLI.start_session(c.workspace)
    assert {:error, :invalid_execution_boundary_selection} = AppServer.start_session(c.workspace)
    refute File.exists?(Path.join(c.workspace, "started"))
  end

  for {adapter, name} <- [{Claude, "claude"}, {CodexCLI, "codex"}, {AppServer, "app-server"}] do
    @tag adapter: adapter, binary_name: name
    test "#{name} selected public adapter retains usage and output before confirmed physical close", c do
      transport!(c, :success)
      policy!(c)
      seen = self()
      assert {:ok, session} = c.adapter.start_session(c.workspace)

      try do
        result =
          c.adapter.run_turn(session, "perform local work", c.issue,
            on_usage: fn raw ->
              if usage?(raw) do
                pid = pid!(c)
                assert_alive!(pid)
                send(seen, {:usage, raw})
                File.write!(Path.join(c.workspace, "release"), "released")
              end

              :ok
            end
          )

        assert {:ok, %{result: :turn_completed}} = result
        assert_received {:usage, _raw}
        assert File.read!(Path.join(c.workspace, "candidate.txt")) == "candidate result\n"
      after
        assert :ok = c.adapter.stop_session(session)
      end

      assert_absent!(pid!(c))
      [start, finish] = boundary_events()
      assert finish["metadata"]["started_event_id"] == start["event_id"]
      assert finish["metadata"]["certain"] == 1
      refute Jason.encode!([start, finish]) =~ "perform local work"
    end
  end

  for {adapter, name} <- [{Claude, "claude"}, {CodexCLI, "codex"}, {AppServer, "app-server"}], terminal_kind <- [:stale_execution, :execution_stopped], mode <- [:return, :throw] do
    @tag adapter: adapter, binary_name: name, terminal_kind: terminal_kind, callback_mode: mode
    test "#{name} retains #{terminal_kind} #{mode} while closing the actual provider", c do
      transport!(c, :terminal)
      policy!(c)

      terminal =
        case c.terminal_kind do
          :stale_execution -> {:stop, {:stale_execution, %{run_id: "prior-run", dispatch_id: "prior-dispatch"}, :material_state_changed}}
          :execution_stopped -> {:stop, {:execution_stopped, %{stage: "blocked"}}}
        end

      assert {:ok, session} = c.adapter.start_session(c.workspace)
      observer = self()

      opts = [
        on_usage: fn raw ->
          if usage?(raw) do
            assert_alive!(pid!(c))
            send(observer, :terminal_callback)
            if c.callback_mode == :return, do: terminal, else: throw({:agent_execution_halt, terminal})
          else
            :ok
          end
        end,
        tool_executor: fn _, _ ->
          send(observer, :late_tool)
          %{success: true}
        end,
        on_message: fn event -> send(observer, {:event, event.event}) end
      ]

      try do
        if c.adapter == AppServer do
          assert catch_throw(AppServer.run_turn(session, "terminal", c.issue, opts)) == {:agent_execution_halt, terminal}
        else
          assert c.adapter.run_turn(session, "terminal", c.issue, opts) == terminal
        end

        assert_received :terminal_callback
        refute_received :late_tool
        refute_received {:event, :turn_ended_with_error}
        refute_received {:event, :turn_completed}
      after
        assert :ok = c.adapter.stop_session(session)
      end

      assert_absent!(pid!(c))
      assert List.last(boundary_events())["metadata"]["certain"] == 1
    end
  end

  for {adapter, name} <- [{Claude, "claude"}, {CodexCLI, "codex"}, {AppServer, "app-server"}],
      attempt <- [:outside_write, :forbidden_exec] do
    @tag adapter: adapter, binary_name: name, attempt: attempt
    test "#{name} makes a real #{attempt} attempt without its forbidden effect", c do
      outside = Path.join(c.root, "outside-witness")
      File.write!(outside, "unchanged")
      forbidden_root = Path.join(c.root, "forbidden-tools")
      File.mkdir!(forbidden_root)
      forbidden = Path.join(forbidden_root, "forbidden")
      marker = Path.join(c.workspace, "forbidden-ran")
      File.write!(forbidden, "#!/bin/bash\nprintf witness > #{quote_shell(marker)}\n")
      File.chmod!(forbidden, 0o500)
      assert {_, 0} = System.cmd(forbidden, [])
      assert File.read!(marker) == "witness"
      File.rm!(marker)
      File.chmod!(forbidden_root, 0o500)
      on_exit(fn -> File.chmod!(forbidden_root, 0o700) end)

      command =
        case c.attempt do
          :outside_write -> "printf changed > #{quote_shell(outside)}"
          :forbidden_exec -> "IFS= read -r header < #{quote_shell(forbidden)} && printf readable > read-confirmed && #{quote_shell(forbidden)}"
        end

      transport!(c, :success)
      bytes = File.read!(Path.join(c.bin, c.binary_name))
      prefix = "printf attempted > negative-attempt; if #{command}; then exit 0; else exit 77; fi"
      target = "printf 'candidate result\\n' > candidate.txt"
      assert bytes =~ target
      File.chmod!(Path.join(c.bin, c.binary_name), 0o700)
      File.write!(Path.join(c.bin, c.binary_name), String.replace(bytes, target, prefix))
      File.chmod!(Path.join(c.bin, c.binary_name), 0o500)
      policy!(c, 5000, [], [forbidden_root])
      assert {:ok, session} = c.adapter.start_session(c.workspace)

      try do
        result = c.adapter.run_turn(session, "negative attempt", c.issue)

        if c.adapter == AppServer do
          assert {:error, {:port_exit, 77}} = result
        else
          assert {:ok, %{result: :turn_failed, cli_observation: %{error: "exit_status_77"}}} = result
        end
      after
        assert :ok = c.adapter.stop_session(session)
      end

      assert File.read!(Path.join(c.workspace, "negative-attempt")) == "attempted"
      assert File.read!(outside) == "unchanged"
      refute File.exists?(marker)
      if c.attempt == :forbidden_exec, do: assert(File.read!(Path.join(c.workspace, "read-confirmed")) == "readable")
      refute File.exists?(Path.join(c.workspace, "candidate.txt"))
      assert_absent!(pid!(c))
      assert List.last(boundary_events())["metadata"]["exit_status"] == 77
      # This proves the selected attempt's effect oracle, not a universal denial classifier.
    end
  end

  test "AppServer keeps one interactive process across turns and its original deadline", c do
    c = Map.merge(c, %{adapter: AppServer, binary_name: "app-server"})
    transport!(c, :success)
    policy!(c, 1600)
    assert {:ok, session} = AppServer.start_session(c.workspace)

    try do
      handle = session.port
      deadline = elem(handle, 4)
      File.write!(Path.join(c.workspace, "release"), "released")
      assert {:ok, _} = AppServer.run_turn(session, "one", c.issue)
      assert {:ok, _} = AppServer.run_turn(session, "two", c.issue)
      assert elem(session.port, 4) == deadline
      assert length(boundary_events()) == 1
      Process.sleep(max(deadline - System.monotonic_time(:millisecond) + 20, 0))
      assert {:error, :provider_deadline} = ProviderTransport.command(handle, "{}\n")
    after
      assert :ok = AppServer.stop_session(session)
    end

    assert_absent!(pid!(c))
    assert List.last(boundary_events())["metadata"]["trigger"] == 1
  end

  test "an overlong AppServer line fails visibly and closes before returning", c do
    path = Path.join(c.bin, "app-server")

    File.write!(
      path,
      "#!/bin/bash\nprintf '%s\\n' \"$$\" > app-server.pid\nprintf '%s' " <>
        quote_shell(String.duplicate("x", 1_048_576)) <> "\nwhile :; do /bin/sleep 0.01; done\n"
    )

    File.chmod!(path, 0o500)
    policy!(c)
    assert {:error, :provider_line_limit} = AppServer.start_session(c.workspace)
    assert_absent!(pid!(Map.put(c, :binary_name, "app-server")))
    assert List.last(boundary_events())["metadata"]["certain"] == 1
  end

  test "selected command overrides and a changed captured policy fail before launch", c do
    c = Map.merge(c, %{adapter: AppServer, binary_name: "app-server"})
    transport!(c, :success)
    policy!(c)
    assert {:error, :provider_command_override_forbidden} = AppServer.start_session(c.workspace, codex_command: "/usr/bin/true")
    assert {:ok, session} = Claude.start_session(c.workspace)
    File.chmod!(c.policy_path, 0o600)
    File.write!(c.policy_path, "{}")
    File.chmod!(c.policy_path, 0o400)
    assert {:error, :policy_digest_mismatch} = Claude.run_turn(session, "unused", c.issue)
    refute File.exists?(Path.join(c.workspace, "started"))
    assert boundary_events() == []
  end

  test "selected child cannot read trustee canary, inherit secret, or alter protected metadata", c do
    canary = Path.join(c.root, "trustee-secret")
    File.write!(canary, "fixture-secret-not-a-real-credential")
    File.mkdir_p!(Path.join(c.workspace, ".symphony"))
    snapshot = Path.join(c.workspace, ".symphony/run_state.json")
    File.write!(snapshot, "protected")
    old = System.get_env("PROVIDER_SECRET_CANARY")
    System.put_env("PROVIDER_SECRET_CANARY", "secret-env-fixture")
    on_exit(fn -> if old, do: System.put_env("PROVIDER_SECRET_CANARY", old), else: System.delete_env("PROVIDER_SECRET_CANARY") end)
    policy!(c)

    for command <- ["IFS= read -r secret < #{quote_shell(canary)} && printf '%s' \"$secret\"", "printf corrupted > .symphony/run_state.json"] do
      launch = %{provider: "codex", started_at: System.monotonic_time(:millisecond), command: {:shell, "printf attempted > attempt; " <> command}}
      assert {:ok, selection} = Config.provider_execution_boundary()
      assert {:ok, handle, _} = ProviderTransport.open(c.workspace, launch, selection)
      {data, status} = transport_output(handle, "")
      assert status != 0
      assert File.read!(Path.join(c.workspace, "attempt")) == "attempted"
      assert File.read!(canary) == "fixture-secret-not-a-real-credential"
      assert File.read!(snapshot) == "protected"
      refute data =~ "fixture-secret-not-a-real-credential"
      assert :ok = ProviderTransport.close(handle)
    end

    assert {:ok, selection} = Config.provider_execution_boundary()
    launch = %{provider: "codex", started_at: System.monotonic_time(:millisecond), command: {:shell, "test -z \"${PROVIDER_SECRET_CANARY+x}\" && printf clean"}}
    assert {:ok, handle, _} = ProviderTransport.open(c.workspace, launch, selection)
    assert {"clean", 0} = transport_output(handle, "")
    assert :ok = ProviderTransport.close(handle)
  end

  test "native socket attempt has an independent loopback witness and no selected connection", c do
    source = Path.join(c.root, "socket.c")
    exe = Path.join(c.bin, "socket-probe")

    File.write!(source, """
    #include <arpa/inet.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <sys/socket.h>
    #include <unistd.h>
    int main(int argc, char **argv) {
      if (argc != 2) return 64;
      FILE *w = fopen("socket-attempt", "w"); if (!w) return 65;
      fputs("connect-loopback", w); if (fclose(w)) return 66;
      int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) return 77;
      struct sockaddr_in a = {0}; a.sin_family = AF_INET;
      a.sin_port = htons((unsigned short)atoi(argv[1])); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      int result = connect(fd, (struct sockaddr *)&a, sizeof(a)); close(fd);
      return result == 0 ? 0 : 78;
    }
    """)

    cc = System.find_executable("cc") || flunk("the native build compiler is unavailable")
    assert {_, 0} = System.cmd(cc, ["-Wall", "-Wextra", "-Werror", source, "-o", exe], stderr_to_stdout: true)
    File.chmod!(exe, 0o500)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)

    try do
      assert {_, 0} = System.cmd(exe, [to_string(port)], cd: c.workspace)
      assert {:ok, connection} = :gen_tcp.accept(listener, 1000)
      :ok = :gen_tcp.close(connection)

      for {adapter, name} <- [{Claude, "claude"}, {CodexCLI, "codex"}, {AppServer, "app-server"}] do
        File.rm!(Path.join(c.workspace, "socket-attempt"))
        local = Map.merge(c, %{adapter: adapter, binary_name: name})
        transport!(local, :success)
        path = Path.join(c.bin, name)
        bytes = File.read!(path)
        target = "printf 'candidate result\\n' > candidate.txt"
        assert bytes =~ target
        File.chmod!(path, 0o700)
        File.write!(path, String.replace(bytes, target, "#{quote_shell(exe)} #{port}; exit $?"))
        File.chmod!(path, 0o500)
        policy!(c, 5000, [exe])
        assert {:ok, session} = adapter.start_session(c.workspace)

        try do
          result = adapter.run_turn(session, "attempt loopback", c.issue)

          if adapter == AppServer do
            assert {:error, {:port_exit, status}} = result
            assert status in [77, 78]
          else
            assert {:ok, %{result: :turn_failed, cli_observation: %{error: error}}} = result
            assert error in ["exit_status_77", "exit_status_78"]
          end
        after
          assert :ok = adapter.stop_session(session)
        end

        assert File.read!(Path.join(c.workspace, "socket-attempt")) == "connect-loopback"
        assert {:error, :timeout} = :gen_tcp.accept(listener, 200)
        assert_absent!(pid!(local))
      end
    after
      :ok = :gen_tcp.close(listener)
    end
  end

  defp transport!(c, mode) do
    usage =
      if c.adapter == AppServer,
        do: ~s({"method":"thread/tokenUsage/updated","params":{"threadId":"boundary-thread","tokenUsage":{"total":{"inputTokens":7,"outputTokens":3,"totalTokens":10}}}}),
        else:
          if(c.adapter == Claude,
            do: ~s({"type":"result","result":"local result","usage":{"input_tokens":7,"output_tokens":3}}),
            else: ~s({"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}})
          )

    wait = if mode == :success, do: "while [ ! -f release ]; do /bin/sleep 0.01; done", else: "while :; do /bin/sleep 0.01; done"
    body = "printf '%s\\n' \"$$\" > #{c.binary_name}.pid\nprintf started > started\n"

    body =
      body <>
        if c.adapter == AppServer do
          """
          while IFS= read -r line; do
            case "$line" in
              *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
              *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"boundary-thread"}}}' ;;
              *'"method":"turn/start"'*)
                printf '%s\\n' '{"id":3,"result":{"turn":{"id":"boundary-turn"}}}'
                printf 'candidate result\\n' > candidate.txt
                printf '%s\\n' #{quote_shell(usage)}
                #{wait}
                printf '%s\\n' '{"method":"turn/completed"}' ;;
            esac
          done
          """
        else
          "printf 'candidate result\\n' > candidate.txt\nprintf '%s\\n' #{quote_shell(usage)}\n#{wait}\n"
        end

    path = Path.join(c.bin, c.binary_name)
    File.write!(path, "#!/bin/bash\nset -eu\n" <> body)
    File.chmod!(path, 0o500)
  end

  defp policy!(c, timeout \\ 5000, extra \\ [], reads \\ []) do
    scripts = File.ls!(c.bin) |> Enum.map(&Path.join(c.bin, &1))

    policy = %{
      "version" => 1,
      "backend" => "macos_deny_default_v1",
      "workspace_root" => c.workspace_root,
      "shell" => "/bin/bash",
      "executables" => Enum.map(Enum.uniq(["/bin/bash", "/bin/sleep" | scripts ++ extra]), &tool/1),
      "read_roots" => reads
    }

    bytes = Jason.encode!(policy)
    if File.exists?(c.policy_path), do: File.chmod!(c.policy_path, 0o600)
    File.write!(c.policy_path, bytes)
    File.chmod!(c.policy_path, 0o400)
    select!(c, %{"policy_file" => c.policy_path, "sha256" => digest(bytes), "timeout_ms" => timeout})
  end

  defp select!(c, selection) do
    File.write!(Workflow.workflow_file_path(), String.replace(c.base_workflow, "---\n", "---\nprovider_execution_boundary: #{Jason.encode!(selection)}\n", global: false))
    :ok = WorkflowStore.force_reload()
  end

  defp transport_output(handle, acc) do
    case ProviderTransport.recv(handle, 4000) do
      {:data, {:eol, bytes}} -> transport_output(handle, acc <> bytes <> "\n")
      {:data, {:noeol, bytes}} -> transport_output(handle, acc <> bytes)
      {:stderr, _bytes} -> transport_output(handle, acc)
      {:exit_status, status} -> {acc, status}
      other -> flunk("unexpected output #{inspect(other)}")
    end
  end

  defp usage?(raw), do: Map.has_key?(raw, "usage") or raw["method"] == "thread/tokenUsage/updated"
  defp pid!(c), do: Path.join(c.workspace, c.binary_name <> ".pid") |> File.read!() |> String.trim() |> String.to_integer()

  defp assert_alive!(pid) do
    assert {text, 0} = System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "pid="])
    assert String.trim(text) == to_string(pid)
  end

  defp assert_absent!(pid) do
    assert {text, 1} = System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "pid="])
    assert String.trim(text) == ""
  end

  defp boundary_events, do: Enum.filter(RunLedger.recent_entries(), &String.starts_with?(&1["event_type"], "execution.boundary."))
  defp tool(path), do: %{"path" => path, "sha256" => digest(File.read!(path))}
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
