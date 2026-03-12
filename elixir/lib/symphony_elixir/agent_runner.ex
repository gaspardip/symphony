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
          Logger.info("Workspace ready for #{issue_context(issue)} workspace=#{workspace}")

          with :ok <- log_step("before_run_hook", issue, fn -> Workspace.run_before_run_hook(workspace, issue) end),
               :ok <- log_step("pre_run_policy", issue, fn -> RunPolicy.enforce_pre_run(issue, workspace) end),
               :ok <- log_step("delivery_engine", issue, fn -> run_codex_turns(workspace, issue, codex_update_recipient, opts) end) do
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

  defp log_step(step, issue, fun) when is_binary(step) and is_function(fun, 0) do
    Logger.info("Starting #{step} for #{issue_context(issue)}")
    result = fun.()
    Logger.info("Finished #{step} for #{issue_context(issue)} result=#{inspect(result)}")
    result
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
