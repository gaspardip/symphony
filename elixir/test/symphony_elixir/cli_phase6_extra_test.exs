defmodule SymphonyElixir.CLIPhase6ExtraTest do
  use SymphonyElixir.TestSupport

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "evaluate rejects parse errors before runtime deps are invoked" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port_set, port})
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, usage} =
             CLI.evaluate([@ack_flag, "--port", "bogus", "WORKFLOW.md"], deps)

    assert usage =~ "Usage: symphony"

    assert {:error, usage} = CLI.evaluate([@ack_flag, "--port"], deps)
    assert usage =~ "Usage: symphony"

    assert {:error, usage} = CLI.evaluate([@ack_flag, "--logs-root"], deps)
    assert usage =~ "Usage: symphony"

    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received {:port_set, _port}
    refute_received :started
  end

  test "evaluate with default deps uses the cwd workflow and applies the last logs root and zero port" do
    workflow_dir = temp_dir("cli-default-cwd")
    workflow_path = Path.join(workflow_dir, "WORKFLOW.md")
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    File.mkdir_p!(workflow_dir)
    write_workflow_file!(workflow_path, tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      restore_app_env(:symphony_elixir, :log_file, previous_log_file)
      restore_app_env(:symphony_elixir, :server_port_override, previous_port_override)
      restore_app_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)
      File.rm_rf(workflow_dir)
    end)

    expected_logs_root =
      File.cd!(workflow_dir, fn ->
        assert :ok =
                 CLI.evaluate([
                   @ack_flag,
                   "--logs-root",
                   "logs-one",
                   "--logs-root",
                   "logs-two",
                   "--port",
                   "9",
                   "--port",
                   "0"
                 ])

        Path.expand("logs-two")
      end)

    assert Application.get_env(:symphony_elixir, :log_file) ==
             SymphonyElixir.LogFile.default_log_file(expected_logs_root)

    assert Application.get_env(:symphony_elixir, :server_port_override) == 0
  end

  test "evaluate uses an explicit workflow path and honors interleaved option precedence" do
    parent = self()
    workflow_path = "tmp/explicit/../explicit/WORKFLOW.md"
    expanded_workflow_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_workflow_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port_set, port})
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert :ok =
             CLI.evaluate(
               [
                 @ack_flag,
                 "--logs-root",
                 "tmp/logs-one",
                 workflow_path,
                 "--port",
                 "9",
                 "--logs-root",
                 "tmp/logs-two",
                 "--port",
                 "2"
               ],
               deps
             )

    assert_received {:logs_root, logs_root}
    assert logs_root == Path.expand("tmp/logs-two")
    assert_received {:port_set, 2}
    assert_received {:workflow_checked, ^expanded_workflow_path}
    assert_received {:workflow_set, ^expanded_workflow_path}
    assert_received :started
  end

  test "run expands workflow paths and skips startup when the file is missing" do
    parent = self()
    workflow_path = "tmp/missing/../missing/WORKFLOW.md"
    expanded_workflow_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        false
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port_set, port})
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, "Workflow file not found: " <> ^expanded_workflow_path} =
             CLI.run(workflow_path, deps)

    assert_received {:workflow_checked, ^expanded_workflow_path}
    refute_received {:workflow_set, _path}
    refute_received :logs_root_set
    refute_received {:port_set, _port}
    refute_received :started
  end

  test "main exits with workflow not found errors" do
    missing_workflow = Path.join(temp_dir("cli-missing-workflow"), "WORKFLOW.md")

    {output, 1} =
      run_external_cli("""
      SymphonyElixir.CLI.main([
        #{inspect(@ack_flag)},
        #{inspect(missing_workflow)}
      ])
      """)

    assert output =~ "Workflow file not found: #{Path.expand(missing_workflow)}"
  end

  test "main exits nonzero when the supervisor name is unavailable after startup" do
    workflow_path = temp_workflow_path("cli-main-missing-supervisor")
    write_workflow_file!(workflow_path, tracker_kind: "memory")

    {output, 1} =
      run_external_cli("""
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      {:ok, _started_apps} = Application.ensure_all_started(:symphony_elixir)
      true = Process.unregister(SymphonyElixir.Supervisor)

      SymphonyElixir.CLI.main([
        #{inspect(@ack_flag)},
        #{inspect(workflow_path)}
      ])
      """)

    assert output =~ "Symphony supervisor is not running"
  end

  @tag timeout: 300_000
  test "main exits zero when the supervisor stops normally" do
    workflow_path = temp_workflow_path("cli-main-normal-extra")
    write_workflow_file!(workflow_path, tracker_kind: "memory")

    {_output, 0} =
      run_external_cli("""
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      spawn(fn ->
        wait_for_supervisor = fn wait_for_supervisor ->
          case Process.whereis(SymphonyElixir.Supervisor) do
            pid when is_pid(pid) ->
              Supervisor.stop(pid, :normal)

            _ ->
              Process.sleep(50)
              wait_for_supervisor.(wait_for_supervisor)
          end
        end

        wait_for_supervisor.(wait_for_supervisor)
      end)

      SymphonyElixir.CLI.main([
        #{inspect(@ack_flag)},
        #{inspect(workflow_path)}
      ])
      """)
  end

  @tag timeout: 300_000
  test "main exits nonzero when the supervisor stops abnormally" do
    workflow_path = temp_workflow_path("cli-main-abnormal-extra")
    write_workflow_file!(workflow_path, tracker_kind: "memory")

    {_output, 1} =
      run_external_cli("""
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      spawn(fn ->
        wait_for_supervisor = fn wait_for_supervisor ->
          case Process.whereis(SymphonyElixir.Supervisor) do
            pid when is_pid(pid) ->
              Supervisor.stop(pid, :shutdown)

            _ ->
              Process.sleep(50)
              wait_for_supervisor.(wait_for_supervisor)
          end
        end

        wait_for_supervisor.(wait_for_supervisor)
      end)

      SymphonyElixir.CLI.main([
        #{inspect(@ack_flag)},
        #{inspect(workflow_path)}
      ])
      """)
  end

  test "main_result_for_test covers success and error branches without halting" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :waited =
             CLI.main_result_for_test([@ack_flag, "WORKFLOW.md"], deps, fn ->
               send(parent, :wait_called)
               :waited
             end)

    assert_received :wait_called

    missing_deps = %{deps | file_regular?: fn _path -> false end}

    assert {:error, "Workflow file not found: " <> _} =
             CLI.main_result_for_test([@ack_flag, "WORKFLOW.md"], missing_deps)
  end

  test "manual submit with default deps posts json payloads to the requested server" do
    spec_dir = temp_dir("cli-manual-submit-ok")
    File.mkdir_p!(spec_dir)
    spec_path = Path.join(spec_dir, "issue.json")
    File.write!(spec_path, Jason.encode!(%{"identifier" => "CLZ-31"}))

    server_url =
      start_http_server!(fn request ->
        assert request =~ "\"identifier\":\"CLZ-31\""
        {200, %{"ok" => true, "source" => "manual"}}
      end)

    assert {:ok, %{"ok" => true, "source" => "manual"}} =
             CLI.evaluate(["manual", "submit", spec_path, "--server", server_url])
  end

  test "manual submit with default deps surfaces invalid payloads and server-side errors" do
    invalid_spec_dir = temp_dir("cli-manual-submit-invalid")
    File.mkdir_p!(invalid_spec_dir)
    invalid_spec_path = Path.join(invalid_spec_dir, "issue.json")
    File.write!(invalid_spec_path, Jason.encode!(["not", "a", "map"]))

    assert {:error, "Manual submission failed: :invalid_json_payload"} =
             CLI.evaluate(["manual", "submit", invalid_spec_path])

    api_error_spec_dir = temp_dir("cli-manual-submit-api-error")
    File.mkdir_p!(api_error_spec_dir)
    api_error_spec_path = Path.join(api_error_spec_dir, "issue.json")
    File.write!(api_error_spec_path, Jason.encode!(%{"identifier" => "CLZ-32"}))

    api_error_url =
      start_http_server!(fn _request ->
        {422, %{"error" => %{"message" => "manual submission rejected"}}}
      end)

    assert {:error, "manual submission rejected"} =
             CLI.evaluate(["manual", "submit", api_error_spec_path, "--server", api_error_url])

    status_error_url =
      start_http_server!(fn _request ->
        {418, %{"status" => "teapot"}}
      end)

    assert {:error, "Manual submission failed: {:unexpected_status, 418}"} =
             CLI.evaluate(["manual", "submit", api_error_spec_path, "--server", status_error_url])
  end

  test "wait_for_shutdown_result_for_test reports missing, normal, and abnormal supervisor exits" do
    parent = self()
    missing_name = Module.concat(__MODULE__, :MissingSupervisor)
    assert {:error, :not_running} = CLI.wait_for_shutdown_result_for_test(missing_name)

    normal_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    abnormal_pid = spawn(fn -> Process.sleep(:infinity) end)

    normal_task =
      Task.async(fn ->
        CLI.wait_for_shutdown_result_for_test(normal_pid, fn _pid ->
          send(parent, :normal_monitored)
        end)
      end)

    abnormal_task =
      Task.async(fn ->
        CLI.wait_for_shutdown_result_for_test(abnormal_pid, fn _pid ->
          send(parent, :abnormal_monitored)
        end)
      end)

    assert_receive :normal_monitored, 1_000
    assert_receive :abnormal_monitored, 1_000
    send(normal_pid, :stop)
    Process.exit(abnormal_pid, :shutdown)

    assert Task.await(normal_task, 1_000) == {:ok, :normal}
    assert Task.await(abnormal_task, 1_000) == {:error, :shutdown}
  end

  defp run_external_cli(code) when is_binary(code) do
    mix_executable = System.find_executable("mix") || raise "mix executable not found"

    System.cmd(
      mix_executable,
      ["run", "--no-start", "--no-compile", "-e", code],
      cd: File.cwd!(),
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp temp_workflow_path(prefix) do
    dir = temp_dir(prefix)
    File.mkdir_p!(dir)
    Path.join(dir, "WORKFLOW.md")
  end

  defp temp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp start_http_server!(handler) when is_function(handler, 1) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        accept_http_connections(listener, handler)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)

      if Process.alive?(server) do
        Process.exit(server, :shutdown)
      end
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_http_connections(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve_http_request(socket, handler)
        accept_http_connections(listener, handler)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_http_request(socket, handler) do
    {:ok, headers, initial_body} = recv_until_headers(socket, "")
    content_length = http_content_length(headers)
    {:ok, body} = recv_exact(socket, content_length - byte_size(initial_body), initial_body)
    {status, payload} = handler.(body)
    response_body = Jason.encode!(payload)

    response = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      http_status_reason(status),
      "\r\n",
      "content-type: application/json\r\n",
      "content-length: ",
      Integer.to_string(byte_size(response_body)),
      "\r\n",
      "connection: close\r\n\r\n",
      response_body
    ]

    :ok = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp recv_until_headers(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, rest] ->
        {:ok, headers, rest}

      [_] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> recv_until_headers(socket, acc <> chunk)
          other -> other
        end
    end
  end

  defp recv_exact(_socket, 0, acc), do: {:ok, acc}

  defp recv_exact(socket, remaining, acc) do
    case :gen_tcp.recv(socket, remaining, 5_000) do
      {:ok, chunk} ->
        recv_exact(socket, remaining - byte_size(chunk), acc <> chunk)

      other ->
        other
    end
  end

  defp http_content_length(headers) do
    headers
    |> String.split("\r\n", trim: true)
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            value |> String.trim() |> String.to_integer()
          else
            false
          end

        _ ->
          false
      end
    end)
  end

  defp http_status_reason(200), do: "OK"
  defp http_status_reason(418), do: "I'm a teapot"
  defp http_status_reason(422), do: "Unprocessable Entity"
  defp http_status_reason(_status), do: "OK"

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
