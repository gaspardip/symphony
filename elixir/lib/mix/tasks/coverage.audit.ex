defmodule Mix.Tasks.Coverage.Audit do
  use Mix.Task

  alias SymphonyElixir.CoverageAudit

  @shortdoc "Run tests with coverage and enforce Symphony coverage thresholds"
  @preferred_cli_env :test
  @requirements ["app.config"]

  @moduledoc """
  Runs the test suite with coverage enabled and enforces Symphony's audited
  coverage thresholds:

    * 90% overall line coverage
    * 85% minimum line coverage on the core runtime modules
    * A watchlist of modules below 90% to focus next

  Usage:

      mix coverage.audit
      mix coverage.audit -- test/symphony_elixir/issue_policy_test.exs
  """

  @impl Mix.Task
  def run(args) do
    {test_args, invalid} = normalize_args(args)

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    previous = System.get_env("SYMPHONY_COVERAGE_AUDIT")
    export_name = "coverage_audit_#{System.unique_integer([:positive])}"
    export_path = Path.join("cover", "#{export_name}.coverdata")

    try do
      System.put_env("SYMPHONY_COVERAGE_AUDIT", "1")
      cleanup_cover_exports!()
      run_exported_test_suite!(export_name, test_args)
      coverage_output = run_coverage_report!()

      audit = CoverageAudit.audit_from_mix_output(coverage_output, "cover")

      Enum.each(CoverageAudit.format_summary(audit), fn line ->
        Mix.shell().info(line)
      end)

      if audit.failed_reasons == [] do
        Mix.shell().info("Coverage audit passed")
      else
        Mix.raise(CoverageAudit.failure_message(audit))
      end
    after
      File.rm(export_path)
      restore_env(previous)
    end
  end

  defp normalize_args(args) do
    args
    |> OptionParser.parse(strict: [], return_separator: true)
    |> case do
      {opts, rest, invalid} ->
        normalized =
          opts
          |> Enum.flat_map(fn
            {key, true} -> ["--#{key}"]
            {key, value} -> ["--#{key}", to_string(value)]
          end)
          |> Kernel.++(rest)
          |> Enum.reject(&(&1 == "--cover"))

        {normalized, invalid}
    end
  end

  defp run_exported_test_suite!(export_name, test_args) do
    {output, status} =
      System.cmd(
        "mix",
        ["test", "--cover", "--export-coverage", export_name | test_args],
        env: [{"MIX_ENV", "test"}, {"SYMPHONY_COVERAGE_AUDIT", "1"}],
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    IO.write(output)

    if status != 0 do
      Mix.raise("coverage audit test run failed with exit status #{status}")
    end
  end

  defp run_coverage_report! do
    {output, status} =
      System.cmd(
        "mix",
        ["test.coverage"],
        env: [{"MIX_ENV", "test"}, {"SYMPHONY_COVERAGE_AUDIT", "1"}],
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    IO.write(output)

    if status != 0 do
      Mix.raise("coverage report generation failed with exit status #{status}")
    end

    output
  end

  defp cleanup_cover_exports! do
    "cover/*.coverdata"
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  defp restore_env(nil), do: System.delete_env("SYMPHONY_COVERAGE_AUDIT")
  defp restore_env(value), do: System.put_env("SYMPHONY_COVERAGE_AUDIT", value)
end
