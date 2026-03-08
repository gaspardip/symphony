defmodule SymphonyElixir.CoverageAudit do
  @moduledoc """
  Coverage thresholds and audit helpers for Symphony's runtime-owned delivery engine.
  """

  @compile {:no_warn_undefined, :cover}

  @overall_threshold 90.0
  @core_threshold 85.0
  @attention_threshold 90.0
  @core_modules [
    SymphonyElixir.DeliveryEngine,
    SymphonyElixir.Orchestrator,
    SymphonyElixir.RunPolicy,
    SymphonyElixir.PullRequestManager,
    SymphonyElixir.RunStateStore,
    SymphonyElixir.LeaseManager,
    SymphonyElixir.RepoHarness,
    SymphonyElixir.VerifierRunner,
    SymphonyElixir.RunInspector,
    SymphonyElixir.RunLedger,
    SymphonyElixir.RunnerRuntime,
    SymphonyElixir.GitManager,
    SymphonyElixir.PriorityEngine
  ]
  @ignore_modules [
    SymphonyElixirWeb.Endpoint,
    SymphonyElixirWeb.ErrorHTML,
    SymphonyElixirWeb.ErrorJSON,
    SymphonyElixirWeb.Layouts,
    SymphonyElixirWeb.StaticAssets,
    SymphonyElixirWeb.Router.Helpers
  ]

  @type module_report :: %{
          module: module(),
          percentage: float(),
          covered_lines: non_neg_integer(),
          total_lines: non_neg_integer(),
          uncovered_lines: [pos_integer()],
          uncovered_ranges: [String.t()],
          core?: boolean()
        }

  @type audit_result :: %{
          overall_percentage: float(),
          overall_threshold: float(),
          core_threshold: float(),
          attention_threshold: float(),
          reports: [module_report()],
          total_modules: non_neg_integer(),
          core_failures: [module_report()],
          attention_reports: [module_report()],
          failed_reasons: [String.t()]
        }

  @spec overall_threshold() :: float()
  def overall_threshold, do: @overall_threshold

  @spec core_threshold() :: float()
  def core_threshold, do: @core_threshold

  @spec attention_threshold() :: float()
  def attention_threshold, do: @attention_threshold

  @spec core_modules() :: [module()]
  def core_modules, do: @core_modules

  @spec ignore_modules() :: [module()]
  def ignore_modules, do: @ignore_modules

  @spec current_audit() :: audit_result()
  def current_audit do
    :cover.modules()
    |> Enum.reject(&(&1 in ignore_modules()))
    |> Enum.map(&module_report/1)
    |> build_audit_result()
  end

  @spec audit_from_mix_output(String.t(), Path.t()) :: audit_result()
  def audit_from_mix_output(output, cover_dir \\ "cover")
      when is_binary(output) and is_binary(cover_dir) do
    {reports, overall_percentage} =
      output
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {reports, overall_percentage} ->
        case parse_mix_summary_row(line, cover_dir) do
          nil ->
            {reports, overall_percentage}

          {:total, percentage} ->
            {reports, percentage}

          %{} = report ->
            {[report | reports], overall_percentage}
        end
      end)

    reports
    |> Enum.reverse()
    |> build_audit_result(overall_percentage)
  end

  @spec module_report(module()) :: module_report()
  def module_report(module) when is_atom(module) do
    with {:ok, coverage} <- :cover.analyse(module, :coverage, :line) do
      build_module_report(module, coverage)
    else
      _ ->
        %{
          module: module,
          percentage: 0.0,
          covered_lines: 0,
          total_lines: 0,
          uncovered_lines: [],
          uncovered_ranges: [],
          core?: module in @core_modules
        }
    end
  end

  @spec evaluate_reports([module_report()]) :: audit_result()
  def evaluate_reports(reports) when is_list(reports) do
    build_audit_result(reports)
  end

  @spec format_summary(audit_result()) :: [String.t()]
  def format_summary(audit_result) when is_map(audit_result) do
    [
      "Coverage audit",
      "  total coverage: #{format_percentage(audit_result.overall_percentage)} (threshold #{format_percentage(audit_result.overall_threshold)})",
      "  core modules at #{format_percentage(audit_result.core_threshold)}: #{length(audit_result.core_failures)} failing",
      "  modules below #{format_percentage(audit_result.attention_threshold)} to focus next: #{length(audit_result.attention_reports)}"
    ] ++
      Enum.map(audit_result.core_failures, &format_core_failure/1) ++
      Enum.map(Enum.take(audit_result.attention_reports, 10), &format_attention_report/1)
  end

  @spec failure_message(audit_result()) :: String.t()
  def failure_message(audit_result) when is_map(audit_result) do
    audit_result.failed_reasons
    |> Enum.join(", ")
    |> case do
      "" -> "coverage audit passed"
      reasons -> "coverage audit failed: #{reasons}"
    end
  end

  defp build_audit_result(reports, overall_override \\ nil) do
    total_lines = Enum.reduce(reports, 0, &(&1.total_lines + &2))
    covered_lines = Enum.reduce(reports, 0, &(&1.covered_lines + &2))
    overall_percentage = overall_override || coverage_percentage(covered_lines, total_lines)

    core_failures =
      reports
      |> Enum.filter(& &1.core?)
      |> Enum.filter(&(&1.percentage < @core_threshold))
      |> Enum.sort_by(fn report -> {report.percentage, Atom.to_string(report.module)} end)

    attention_reports =
      reports
      |> Enum.filter(&(&1.percentage < @attention_threshold))
      |> Enum.sort_by(fn report -> {report.percentage, Atom.to_string(report.module)} end)

    failed_reasons =
      []
      |> maybe_add_reason(overall_percentage < @overall_threshold, "overall_coverage_below_threshold")
      |> maybe_add_reason(core_failures != [], "core_module_below_threshold")

    %{
      overall_percentage: overall_percentage,
      overall_threshold: @overall_threshold,
      core_threshold: @core_threshold,
      attention_threshold: @attention_threshold,
      reports: Enum.sort_by(reports, &Atom.to_string(&1.module)),
      total_modules: length(reports),
      core_failures: core_failures,
      attention_reports: attention_reports,
      failed_reasons: failed_reasons
    }
  end

  defp parse_mix_summary_row(line, cover_dir) do
    case Regex.run(~r/^\|\s*([0-9]+\.[0-9]+)%\s*\|\s*(.*?)\s*\|$/, line, capture: :all_but_first) do
      [percentage, "Total"] ->
        {:total, String.to_float(percentage)}

      [percentage, module_name] ->
        build_mix_report(module_name, String.to_float(percentage), cover_dir)

      _ ->
        nil
    end
  end

  defp build_mix_report(module_name, percentage, cover_dir) do
    uncovered_lines = uncovered_lines_from_html(module_name, cover_dir)

    %{
      module: mix_output_module(module_name),
      percentage: percentage,
      covered_lines: 0,
      total_lines: 0,
      uncovered_lines: uncovered_lines,
      uncovered_ranges: uncovered_ranges(uncovered_lines),
      core?: mix_output_module(module_name) in @core_modules
    }
  end

  defp mix_output_module(module_name) do
    module_name
    |> String.trim()
    |> then(&String.to_atom("Elixir." <> &1))
  end

  defp uncovered_lines_from_html(module_name, cover_dir) do
    cover_dir
    |> Path.join("Elixir.#{module_name}.html")
    |> File.read()
    |> case do
      {:ok, html} ->
        Regex.scan(~r/<tr class="miss">.*?<td class="line" id="L(\d+)">/s, html, capture: :all_but_first)
        |> Enum.map(fn [line] -> String.to_integer(line) end)

      {:error, _reason} ->
        []
    end
  end

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons

  defp build_module_report(module, coverage) do
    executable_lines =
      coverage
      |> Enum.filter(fn
        {{^module, line}, {_covered, _not_covered}} -> line > 0
        _ -> false
      end)

    covered_lines =
      Enum.count(executable_lines, fn
        {{^module, _line}, {covered, _not_covered}} -> covered > 0
        _ -> false
      end)

    uncovered_lines =
      executable_lines
      |> Enum.filter(fn
        {{^module, _line}, {covered, not_covered}} -> covered == 0 and not_covered > 0
        _ -> false
      end)
      |> Enum.map(fn {{^module, line}, _counts} -> line end)

    total_lines = length(executable_lines)

    %{
      module: module,
      percentage: coverage_percentage(covered_lines, total_lines),
      covered_lines: covered_lines,
      total_lines: total_lines,
      uncovered_lines: uncovered_lines,
      uncovered_ranges: uncovered_ranges(uncovered_lines),
      core?: module in @core_modules
    }
  end

  defp uncovered_ranges([]), do: []

  defp uncovered_ranges(lines) do
    lines
    |> Enum.sort()
    |> Enum.uniq()
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

  defp coverage_percentage(_covered, 0), do: 100.0

  defp coverage_percentage(covered, total) do
    Float.round(covered / total * 100, 2)
  end

  defp format_percentage(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 2) <> "%"
  end

  defp format_percentage(value) when is_integer(value), do: format_percentage(value * 1.0)

  defp format_core_failure(report) do
    uncovered =
      case Enum.take(report.uncovered_ranges, 3) do
        [] -> "no uncovered ranges reported"
        ranges -> Enum.join(ranges, ", ")
      end

    "  #{inspect(report.module)}: #{format_percentage(report.percentage)} (uncovered #{uncovered})"
  end

  defp format_attention_report(report) do
    "    focus: #{inspect(report.module)} at #{format_percentage(report.percentage)}"
  end
end
