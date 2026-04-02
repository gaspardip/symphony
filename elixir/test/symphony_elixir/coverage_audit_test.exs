defmodule SymphonyElixir.CoverageAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CoverageAudit

  test "evaluate_reports passes when overall and core thresholds are met" do
    result =
      CoverageAudit.evaluate_reports([
        report(SymphonyElixir.DeliveryEngine, 92.0, [12, 13]),
        report(SymphonyElixir.RunPolicy, 88.0, []),
        report(SymphonyElixir.AgentRunner, 91.0, [44])
      ])

    assert result.failed_reasons == []
    assert result.overall_percentage >= CoverageAudit.overall_threshold()
    assert result.core_failures == []
  end

  test "evaluate_reports fails below overall threshold and on core module drift" do
    result =
      CoverageAudit.evaluate_reports([
        report(SymphonyElixir.DeliveryEngine, 55.0, [10, 11, 15]),
        report(SymphonyElixir.RunPolicy, 75.0, []),
        report(SymphonyElixir.AgentRunner, 60.0, [44, 45, 46, 47, 48])
      ])

    assert Enum.sort(result.failed_reasons) == [
             "core_module_below_threshold",
             "overall_coverage_below_threshold"
           ]

    assert [%{module: SymphonyElixir.DeliveryEngine, uncovered_ranges: ["10-11", "15"]}] =
             result.core_failures

    summary = CoverageAudit.format_summary(result)
    assert Enum.any?(summary, &String.contains?(&1, "total coverage"))
    assert Enum.any?(summary, &String.contains?(&1, "SymphonyElixir.DeliveryEngine"))

    assert CoverageAudit.failure_message(result) ==
             "coverage audit failed: overall_coverage_below_threshold, core_module_below_threshold"
  end

  test "ignore list excludes shell-style web and webhook intake modules" do
    assert CoverageAudit.ignore_modules() == [
             SymphonyElixir.GitHub.Webhook,
             SymphonyElixir.GitHubEvent,
             SymphonyElixir.GitHubEventInbox,
             SymphonyElixir.Linear.Webhook,
             SymphonyElixir.Observability.Metrics,
             SymphonyElixir.TrackerEvent,
             SymphonyElixir.TrackerEventInbox,
             SymphonyElixirWeb.Endpoint,
             SymphonyElixirWeb.ErrorHTML,
             SymphonyElixirWeb.ErrorJSON,
             SymphonyElixirWeb.GitHubWebhookController,
             SymphonyElixirWeb.Layouts,
             SymphonyElixirWeb.LinearWebhookController,
             SymphonyElixirWeb.ObservabilityApiController,
             SymphonyElixirWeb.RawBodyReader,
             SymphonyElixirWeb.Router,
             SymphonyElixirWeb.StaticAssets,
             SymphonyElixirWeb.StaticAssetController,
             SymphonyElixirWeb.Router.Helpers
           ]
  end

  test "audit_from_mix_output parses percentages and uncovered ranges from coverage artifacts" do
    cover_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-coverage-audit-html-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(cover_dir)

      File.write!(
        Path.join(cover_dir, "Elixir.SymphonyElixir.DeliveryEngine.html"),
        """
        <table>
          <tr class="miss"><td class="line" id="L10"><a href="#L10">10</a></td></tr>
          <tr class="miss"><td class="line" id="L11"><a href="#L11">11</a></td></tr>
          <tr class="miss"><td class="line" id="L15"><a href="#L15">15</a></td></tr>
        </table>
        """
      )

      output = """
      | Percentage | Module                        |
      |------------|-------------------------------|
      |     55.00% | SymphonyElixir.DeliveryEngine |
      |     96.00% | SymphonyElixir.AgentRunner    |
      |------------|-------------------------------|
      |     75.50% | Total                         |
      """

      result = CoverageAudit.audit_from_mix_output(output, cover_dir)

      assert Enum.sort(result.failed_reasons) == ["core_module_below_threshold", "overall_coverage_below_threshold"]

      assert [%{module: SymphonyElixir.DeliveryEngine, uncovered_ranges: ["10-11", "15"]}] =
               result.core_failures

      assert result.overall_percentage == 75.5
    after
      File.rm_rf(cover_dir)
    end
  end

  defp report(module, percentage, uncovered_lines) do
    total_lines = 100
    covered_lines = trunc(Float.floor(percentage))

    %{
      module: module,
      percentage: percentage,
      covered_lines: covered_lines,
      total_lines: total_lines,
      uncovered_lines: uncovered_lines,
      uncovered_ranges: uncovered_ranges(uncovered_lines),
      core?: module in CoverageAudit.core_modules()
    }
  end

  defp uncovered_ranges(lines) do
    lines
    |> Enum.sort()
    |> Enum.reduce([], fn line, acc ->
      case acc do
        [{start_line, end_line} | rest] when line == end_line + 1 ->
          [{start_line, line} | rest]

        _ ->
          [{line, line} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {line, line} -> Integer.to_string(line)
      {start_line, end_line} -> "#{start_line}-#{end_line}"
    end)
  end
end
