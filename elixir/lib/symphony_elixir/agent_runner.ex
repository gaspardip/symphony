defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{DeliveryEngine, Linear.Issue, RunPolicy, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- RunPolicy.enforce_pre_run(issue, workspace),
               :ok <- run_codex_turns(workspace, issue, codex_update_recipient, opts) do
            :ok
          else
            {:stop, reason} ->
              Logger.warning("Agent run stopped by policy for #{issue_context(issue)}: #{inspect(reason)}")
              :ok

            {:done, _issue} ->
              :ok

            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
    DeliveryEngine.run(workspace, issue, codex_update_recipient, opts)
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
