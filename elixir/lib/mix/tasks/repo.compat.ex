defmodule Mix.Tasks.Repo.Compat do
  use Mix.Task

  alias SymphonyElixir.RepoCompatibility

  @moduledoc """
  Validates whether a repo is autonomous-compatible for Symphony.
  """
  @shortdoc "Checks Symphony repo compatibility and prints a report"

  @switches [json: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, argv, _invalid} = OptionParser.parse(args, strict: @switches)
    workspace = argv |> List.first() |> Kernel.||(File.cwd!()) |> Path.expand()

    {:ok, report} = RepoCompatibility.report(workspace)

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(Jason.encode!(report))
    else
      Mix.shell().info(render_report(report))
    end
  end

  defp render_report(report) do
    status = if report.compatible, do: "compatible", else: "incompatible"

    lines =
      [
        "repo.compat: #{status}",
        "workspace: #{report.workspace}",
        "checked_at: #{report.checked_at}",
        "failing_checks: #{Enum.join(report.failing_checks, ", ")}"
      ] ++
        Enum.map(report.checks, fn check ->
          prefix =
            case check.status do
              :passed -> "[pass]"
              :warning -> "[warn]"
              :failed -> "[fail]"
            end

          "#{prefix} #{check.id}: #{check.summary} #{check.details}"
        end)

    Enum.join(lines, "\n")
  end
end
