defmodule Mix.Tasks.Harness.Check do
  use Mix.Task

  @shortdoc "Validate the self-development harness artifacts for the current repo"

  alias SymphonyElixir.AgentHarness
  alias SymphonyElixir.RepoHarness

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    repo_root = AgentHarness.repo_root!(File.cwd!())

    case RepoHarness.load(repo_root) do
      {:ok, harness} ->
        case AgentHarness.check(repo_root, harness) do
          :ok ->
            Mix.shell().info("harness.check: self-development harness is valid")
            :ok

          {:error, reason} ->
            Mix.raise("harness.check failed: #{format_reason(reason)}")
        end

      {:error, :missing} ->
        Mix.shell().info("harness.check: no .symphony/harness.yml found; skipping")
        :ok

      {:error, reason} ->
        Mix.raise("harness.check failed: #{format_reason(reason)}")
    end
  end

  defp format_reason({tag, details}) when is_list(details), do: "#{tag}: #{Enum.join(details, ", ")}"
  defp format_reason(reason), do: inspect(reason)
end
