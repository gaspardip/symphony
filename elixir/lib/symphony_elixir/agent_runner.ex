defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in an isolated workspace with the configured agent provider.
  """

  require Logger
  alias SymphonyElixir.{DeliveryEngine, LeaseManager, Linear.Issue, RunPolicy, RunStateStore, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          Logger.info("Workspace ready for #{issue_context(issue)} workspace=#{workspace}")
          ensure_dispatch_run_state(workspace, issue)

          with :ok <- log_step("before_run_hook", issue, fn -> Workspace.run_before_run_hook(workspace, issue) end),
               :ok <- log_step("pre_run_policy", issue, fn -> RunPolicy.enforce_pre_run(issue, workspace) end),
               :ok <- log_step("delivery_engine", issue, fn -> run_agent_turns(workspace, issue, agent_update_recipient, opts) end) do
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

  defp run_agent_turns(workspace, issue, agent_update_recipient, opts) do
    DeliveryEngine.run(workspace, issue, agent_update_recipient, opts)
  end

  defp log_step(step, issue, fun) when is_binary(step) and is_function(fun, 0) do
    Logger.info("Starting #{step} for #{issue_context(issue)}")
    result = fun.()
    Logger.info("Finished #{step} for #{issue_context(issue)} result=#{inspect(result)}")
    result
  end

  defp ensure_dispatch_run_state(workspace, issue) when is_binary(workspace) and is_map(issue) do
    case RunStateStore.load(workspace) do
      {:ok, _run_state} ->
        :ok

      {:error, :missing} ->
        issue_id = Map.get(issue, :id) || Map.get(issue, "id")

        lease_result =
          if is_binary(issue_id) and issue_id != "" do
            with {:ok, lease} <- LeaseManager.read(issue_id) do
              RunStateStore.sync_lease(workspace, issue, lease_snapshot(lease))
            end
          else
            {:error, :missing}
          end

        case lease_result do
          {:ok, _run_state} ->
            :ok

          {:error, _reason} ->
            run_state = RunStateStore.load_or_default(workspace, issue)
            RunStateStore.save(workspace, run_state)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp lease_snapshot(lease) when is_map(lease) do
    %{
      lease_owner: lease["owner"] || lease[:owner],
      lease_owner_instance_id: SymphonyElixir.RunnerRuntime.instance_id(),
      lease_owner_channel: SymphonyElixir.Config.runner_channel(),
      lease_acquired_at: lease["acquired_at"] || lease[:acquired_at],
      lease_updated_at: lease["updated_at"] || lease[:updated_at],
      lease_status: "held",
      lease_epoch: lease["epoch"] || lease[:epoch]
    }
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
