defmodule SymphonyElixir.CoverageCliPhase6BackfillTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Coverage.Audit, as: CoverageAuditTask
  alias SymphonyElixir.{CLI, CoverageAudit, LogFile}

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "CoverageAudit exposes thresholds, pass messages, and ignores unrelated output" do
    cover_dir = temp_dir("coverage-audit-missing-html")

    try do
      File.mkdir_p!(cover_dir)

      output = """
      ignored line
      | Percentage | Module                     |
      |------------|----------------------------|
      |    100.00% | SymphonyElixir.AgentRunner |
      """

      result = CoverageAudit.audit_from_mix_output(output, cover_dir)

      assert CoverageAudit.overall_threshold() == 86.5
      assert CoverageAudit.core_threshold() == 77.0
      assert CoverageAudit.attention_threshold() == 90.0
      assert CoverageAudit.failure_message(%{failed_reasons: []}) == "coverage audit passed"
      assert result.overall_percentage == 100.0
      assert result.total_modules == 1
      assert result.failed_reasons == []

      assert [%{module: SymphonyElixir.AgentRunner, uncovered_lines: [], uncovered_ranges: []}] =
               result.reports
    after
      File.rm_rf(cover_dir)
    end
  end

  test "CoverageAudit supports default cover_dir and integer summary fields" do
    cover_dir = temp_dir("coverage-audit-default-dir")

    output = """
    | Percentage | Module                     |
    |------------|----------------------------|
    |    100.00% | SymphonyElixir.AgentRunner |
    |    100.00% | Total                      |
    """

    try do
      File.mkdir_p!(Path.join(cover_dir, "cover"))

      result =
        File.cd!(cover_dir, fn ->
          CoverageAudit.audit_from_mix_output(output)
        end)

      summary =
        CoverageAudit.format_summary(%{
          overall_percentage: 100,
          overall_threshold: CoverageAudit.overall_threshold(),
          core_threshold: CoverageAudit.core_threshold(),
          attention_threshold: 90,
          core_failures: [],
          attention_reports: []
        })

      assert result.overall_percentage == 100.0
      assert Enum.any?(summary, &String.contains?(&1, "100.00%"))
      assert Enum.any?(summary, &String.contains?(&1, "86.50%"))
    after
      File.rm_rf(cover_dir)
    end
  end

  test "CoverageAudit current_audit and module_report work when cover is available" do
    if function_exported?(:cover, :modules, 0) and function_exported?(:cover, :analyse, 3) do
      audit = CoverageAudit.current_audit()
      missing = CoverageAudit.module_report(:"Elixir.SymphonyElixir.MissingCoverageModule")

      assert audit.total_modules > 0
      assert Enum.any?(audit.reports, &(&1.module == SymphonyElixir.CLI))
      assert is_list(audit.core_failures)

      assert missing == %{
               module: :"Elixir.SymphonyElixir.MissingCoverageModule",
               percentage: 0.0,
               covered_lines: 0,
               total_lines: 0,
               uncovered_lines: [],
               uncovered_ranges: [],
               core?: false
             }
    else
      assert true
    end
  end

  test "coverage audit task rejects invalid switches" do
    Mix.Task.reenable("coverage.audit")

    assert_raise Mix.Error, ~r/Invalid option\(s\): \[\{"--trace", nil\}\]/, fn ->
      CoverageAuditTask.run(["--trace"])
    end
  end

  test "coverage audit task runs successfully, strips extra cover flags, and restores env" do
    previous = System.get_env("SYMPHONY_COVERAGE_AUDIT")
    System.put_env("SYMPHONY_COVERAGE_AUDIT", "before")

    on_exit(fn ->
      restore_env("SYMPHONY_COVERAGE_AUDIT", previous)
    end)

    output =
      with_fake_mix(
        %{
          test_output: "fake test run\n",
          coverage_output: """
          | Percentage | Module                        |
          |------------|-------------------------------|
          |    100.00% | SymphonyElixir.DeliveryEngine |
          |    100.00% | Total                         |
          """
        },
        fn tmp_dir, log_path ->
          stale_export = Path.join(tmp_dir, "cover/stale.coverdata")
          File.write!(stale_export, "stale")

          task_output =
            capture_io(fn ->
              Mix.Task.reenable("coverage.audit")

              File.cd!(tmp_dir, fn ->
                CoverageAuditTask.run(["--", "test/symphony_elixir/cli_test.exs", "--cover"])
              end)
            end)

          log_lines = File.read!(log_path) |> String.split("\n", trim: true)
          [test_invocation, coverage_invocation] = log_lines

          assert test_invocation =~ "test --cover --export-coverage"
          assert Enum.count(String.split(test_invocation, " "), &(&1 == "--cover")) == 1
          assert test_invocation =~ "-- test/symphony_elixir/cli_test.exs"
          assert coverage_invocation == "test.coverage"
          refute File.exists?(stale_export)
          assert System.get_env("SYMPHONY_COVERAGE_AUDIT") == "before"

          task_output
        end
      )

    assert output =~ "Coverage audit passed"
  end

  test "coverage audit task raises when the audit summary fails thresholds" do
    previous = System.get_env("SYMPHONY_COVERAGE_AUDIT")
    System.put_env("SYMPHONY_COVERAGE_AUDIT", "before")

    on_exit(fn ->
      restore_env("SYMPHONY_COVERAGE_AUDIT", previous)
    end)

    with_fake_mix(
      %{
        test_output: "fake test run\n",
        coverage_output: """
        | Percentage | Module                        |
        |------------|-------------------------------|
        |     70.00% | SymphonyElixir.DeliveryEngine |
        |    100.00% | Total                         |
        """
      },
      fn tmp_dir, _log_path ->
        assert_raise Mix.Error, ~r/coverage audit failed: core_module_below_threshold/, fn ->
          Mix.Task.reenable("coverage.audit")

          File.cd!(tmp_dir, fn ->
            CoverageAuditTask.run([])
          end)
        end

        assert System.get_env("SYMPHONY_COVERAGE_AUDIT") == "before"
      end
    )
  end

  test "coverage audit task raises when the exported test suite fails" do
    previous = System.get_env("SYMPHONY_COVERAGE_AUDIT")
    System.put_env("SYMPHONY_COVERAGE_AUDIT", "before")

    on_exit(fn ->
      restore_env("SYMPHONY_COVERAGE_AUDIT", previous)
    end)

    with_fake_mix(
      %{
        test_output: "fake test run failed\n",
        test_status: 3,
        coverage_output: ""
      },
      fn tmp_dir, log_path ->
        assert_raise Mix.Error, ~r/coverage audit test run failed with exit status 3/, fn ->
          Mix.Task.reenable("coverage.audit")

          File.cd!(tmp_dir, fn ->
            CoverageAuditTask.run([])
          end)
        end

        assert File.read!(log_path) =~ "test --cover --export-coverage"
        assert System.get_env("SYMPHONY_COVERAGE_AUDIT") == "before"
      end
    )
  end

  test "coverage audit task raises when the coverage report command fails" do
    previous = System.get_env("SYMPHONY_COVERAGE_AUDIT")
    System.put_env("SYMPHONY_COVERAGE_AUDIT", "before")

    on_exit(fn ->
      restore_env("SYMPHONY_COVERAGE_AUDIT", previous)
    end)

    with_fake_mix(
      %{
        test_output: "fake test run\n",
        coverage_output: "fake coverage report failed\n",
        coverage_status: 4
      },
      fn tmp_dir, _log_path ->
        assert_raise Mix.Error, ~r/coverage report generation failed with exit status 4/, fn ->
          Mix.Task.reenable("coverage.audit")

          File.cd!(tmp_dir, fn ->
            CoverageAuditTask.run([])
          end)
        end

        assert System.get_env("SYMPHONY_COVERAGE_AUDIT") == "before"
      end
    )
  end

  test "coverage audit task restores an unset audit env after success" do
    previous = System.get_env("SYMPHONY_COVERAGE_AUDIT")
    System.delete_env("SYMPHONY_COVERAGE_AUDIT")

    on_exit(fn ->
      restore_env("SYMPHONY_COVERAGE_AUDIT", previous)
    end)

    with_fake_mix(
      %{
        test_output: "fake test run\n",
        coverage_output: """
        | Percentage | Module                        |
        |------------|-------------------------------|
        |    100.00% | SymphonyElixir.DeliveryEngine |
        |    100.00% | Total                         |
        """
      },
      fn tmp_dir, _log_path ->
        Mix.Task.reenable("coverage.audit")

        File.cd!(tmp_dir, fn ->
          CoverageAuditTask.run([])
        end)

        assert System.get_env("SYMPHONY_COVERAGE_AUDIT") == nil
      end
    )
  end

  test "CLI evaluate rejects invalid argv, blank logs root, and invalid ports" do
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

    assert {:error, usage} = CLI.evaluate([@ack_flag, "one", "two"], deps)
    assert usage =~ "Usage: symphony"

    assert {:error, usage} = CLI.evaluate([@ack_flag, "--logs-root", "   ", "WORKFLOW.md"], deps)
    assert usage =~ "Usage: symphony"

    assert {:error, usage} = CLI.evaluate([@ack_flag, "--port", "-1", "WORKFLOW.md"], deps)
    assert usage =~ "Usage: symphony"

    refute_received :workflow_set
    refute_received :started
  end

  test "CLI evaluate uses the last provided port override when deps are injected" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn port ->
        send(parent, {:port_set, port})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--port", "1", "--port", "4321", "WORKFLOW.md"], deps)
    assert_received {:port_set, 4321}
  end

  test "CLI evaluate with default deps applies runtime env updates in-process" do
    workflow_path = temp_workflow_path("cli-evaluate-in-process")
    logs_root = temp_dir("cli-in-process-logs")
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    write_workflow_file!(workflow_path, tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      if previous_log_file == nil do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      if previous_port_override == nil do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end

      if previous_memory_issues == nil do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)
      end
    end)

    assert :ok =
             CLI.evaluate([
               @ack_flag,
               "--logs-root",
               logs_root,
               "--port",
               "4311",
               workflow_path
             ])

    assert Application.get_env(:symphony_elixir, :log_file) ==
             LogFile.default_log_file(Path.expand(logs_root))

    assert Application.get_env(:symphony_elixir, :server_port_override) == 4311
  end

  test "CLI default deps apply logs root and port in an external runtime" do
    workflow_path = temp_workflow_path("cli-evaluate-default")
    logs_root = temp_dir("cli-runtime-logs")
    write_workflow_file!(workflow_path, tracker_kind: "memory")

    {output, 0} =
      run_external_cli("""
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      case SymphonyElixir.CLI.evaluate([
             #{inspect(@ack_flag)},
             "--logs-root",
             #{inspect(logs_root)},
             "--port",
             "4321",
             #{inspect(workflow_path)}
           ]) do
        :ok ->
          IO.puts("LOG_FILE=" <> to_string(Application.get_env(:symphony_elixir, :log_file)))
          IO.puts("PORT=" <> Integer.to_string(Application.get_env(:symphony_elixir, :server_port_override)))
          Application.stop(:symphony_elixir)
          System.halt(0)

        {:error, message} ->
          IO.puts(:stderr, message)
          System.halt(1)
      end
      """)

    assert output =~ "LOG_FILE=#{LogFile.default_log_file(Path.expand(logs_root))}"
    assert output =~ "PORT=4321"
  end

  test "CLI main exits with usage on evaluation errors" do
    {output, 1} =
      run_external_cli("""
      SymphonyElixir.CLI.main(["--bogus"])
      """)

    assert output =~ "Usage: symphony"
  end

  @tag timeout: 300_000
  test "CLI main exits zero when the supervisor stops normally" do
    workflow_path = temp_workflow_path("cli-main-normal")
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

      SymphonyElixir.CLI.main([#{inspect(@ack_flag)}, #{inspect(workflow_path)}])
      """)
  end

  defp with_fake_mix(config, fun) when is_map(config) and is_function(fun, 2) do
    tmp_dir = temp_dir("coverage-audit-task")
    bin_dir = Path.join(tmp_dir, "bin")
    cover_dir = Path.join(tmp_dir, "cover")
    log_path = Path.join(tmp_dir, "fake_mix.log")
    previous_path = System.get_env("PATH")
    previous_log = System.get_env("FAKE_MIX_LOG")
    previous_test_output = System.get_env("FAKE_MIX_TEST_OUTPUT")
    previous_test_status = System.get_env("FAKE_MIX_TEST_STATUS")
    previous_coverage_output = System.get_env("FAKE_MIX_COVERAGE_OUTPUT")
    previous_coverage_status = System.get_env("FAKE_MIX_COVERAGE_STATUS")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(cover_dir)
    write_fake_mix!(bin_dir)

    System.put_env("PATH", Enum.join([bin_dir, previous_path || ""], ":"))
    System.put_env("FAKE_MIX_LOG", log_path)
    System.put_env("FAKE_MIX_TEST_OUTPUT", Map.get(config, :test_output, ""))
    System.put_env("FAKE_MIX_TEST_STATUS", to_string(Map.get(config, :test_status, 0)))
    System.put_env("FAKE_MIX_COVERAGE_OUTPUT", Map.get(config, :coverage_output, ""))
    System.put_env("FAKE_MIX_COVERAGE_STATUS", to_string(Map.get(config, :coverage_status, 0)))

    try do
      fun.(tmp_dir, log_path)
    after
      restore_env("PATH", previous_path)
      restore_env("FAKE_MIX_LOG", previous_log)
      restore_env("FAKE_MIX_TEST_OUTPUT", previous_test_output)
      restore_env("FAKE_MIX_TEST_STATUS", previous_test_status)
      restore_env("FAKE_MIX_COVERAGE_OUTPUT", previous_coverage_output)
      restore_env("FAKE_MIX_COVERAGE_STATUS", previous_coverage_status)
      File.rm_rf(tmp_dir)
    end
  end

  defp write_fake_mix!(bin_dir) do
    script_path = Path.join(bin_dir, "mix")

    File.write!(
      script_path,
      """
      #!/bin/sh
      echo "$@" >> "$FAKE_MIX_LOG"

      case "$1" in
        test)
          printf "%s" "$FAKE_MIX_TEST_OUTPUT"
          exit "${FAKE_MIX_TEST_STATUS:-0}"
          ;;
        test.coverage)
          printf "%s" "$FAKE_MIX_COVERAGE_OUTPUT"
          exit "${FAKE_MIX_COVERAGE_STATUS:-0}"
          ;;
        *)
          echo "unexpected fake mix invocation: $@" >&2
          exit 99
          ;;
      esac
      """
    )

    File.chmod!(script_path, 0o755)
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
end
