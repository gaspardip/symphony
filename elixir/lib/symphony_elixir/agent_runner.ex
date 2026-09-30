defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in an isolated workspace with the configured agent provider.
  """

  require Logger
  alias SymphonyElixir.{AgentExecution, DeliveryEngine, LeaseManager, Linear.Issue, RunPolicy, RunStateStore, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | {:error, term()} | {:stop, term()} | {:done, map()} | AgentExecution.terminal() | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    with {:ok, context} <- AgentExecution.entry_context(Workspace.path_for_issue(issue), issue) do
      run_with_context(issue, agent_update_recipient, opts, context)
    end
  end

  defp run_with_context(issue, agent_update_recipient, opts, context) do
    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        primary = capture_outcome(fn -> run_in_workspace(workspace, issue, agent_update_recipient, opts, context) end)
        cleanup = capture_outcome(fn -> Workspace.run_after_run_hook(workspace, issue) end)
        finish_with_cleanup(primary, cleanup)

      {:stop, _} = terminal ->
        terminal

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_in_workspace(workspace, issue, agent_update_recipient, opts, context) do
    Logger.info("Workspace ready for #{issue_context(issue)} workspace=#{workspace}")
    if context == :legacy, do: ensure_dispatch_run_state(workspace, issue)

    with {:ok, _context} <- AgentExecution.entry_context(workspace, issue),
         :ok <- log_step("before_run_hook", issue, fn -> Workspace.run_before_run_hook(workspace, issue) end),
         :ok <- log_step("pre_run_policy", issue, fn -> RunPolicy.enforce_pre_run(issue, workspace) end),
         {:ok, _context} <- AgentExecution.entry_context(workspace, issue),
         :ok <- log_step("delivery_engine", issue, fn -> run_agent_turns(workspace, issue, agent_update_recipient, opts) end) do
      :ok
    else
      {:stop, {kind, _}} = terminal when kind in [:accounting_uncertain, :execution_stopped] ->
        terminal

      {:stop, {:stale_execution, _, _}} = terminal ->
        terminal

      {:stop, reason} = stopped ->
        Logger.warning("Agent run stopped by policy for #{issue_context(issue)}: #{inspect(reason)}")
        if context == :legacy, do: :ok, else: stopped

      {:done, _issue} = done ->
        if context == :legacy, do: :ok, else: done

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  # Capture only to run cleanup and then return/re-raise the exact selected outcome.
  defp capture_outcome(fun) do
    {:returned, fun.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp finish_with_cleanup(primary, cleanup) do
    cond do
      cleanup == {:returned, :ok} or cleanup == primary ->
        restore_outcome(primary)

      stopped_cleanup?(cleanup) and retained_primary?(primary) ->
        restore_outcome(primary)

      retained_primary?(primary) ->
        Logger.error(
          "AgentRunner cleanup failed primary=" <>
            outcome_diagnostic(primary) <>
            " cleanup=" <> outcome_diagnostic(cleanup)
        )

        restore_outcome(primary)

      true ->
        restore_outcome(cleanup)
    end
  end

  defp stopped_cleanup?({:returned, {:stop, {:execution_stopped, _}}}), do: true
  defp stopped_cleanup?(_outcome), do: false
  defp retained_primary?({:raised, _, _, _}), do: true
  defp retained_primary?({:returned, {:stop, _}}), do: true
  defp retained_primary?({:returned, {:error, _}}), do: true
  defp retained_primary?({:returned, {:done, _}}), do: true
  defp retained_primary?(_outcome), do: false
  defp restore_outcome({:returned, value}), do: value
  defp restore_outcome({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  defp outcome_diagnostic({:raised, kind, reason, stacktrace}), do: Exception.format(kind, reason, stacktrace)

  defp outcome_diagnostic({:returned, {:stop, {:stale_execution, _ids, cause}}}),
    do: "stale_execution: " <> inspect(cause, limit: 8, printable_limit: 512)

  defp outcome_diagnostic({:returned, {:stop, {tag, cause}}}) when tag in [:accounting_uncertain, :execution_stopped],
    do: Atom.to_string(tag) <> ": " <> inspect(cause, limit: 8, printable_limit: 512)

  defp outcome_diagnostic({:returned, {:stop, %RunPolicy.Violation{code: code}}}), do: "policy_stop: " <> Atom.to_string(code)
  defp outcome_diagnostic({:returned, {:stop, reason}}) when is_atom(reason), do: "stop: " <> Atom.to_string(reason)
  defp outcome_diagnostic({:returned, {:stop, reason}}), do: "stop: " <> inspect(reason, limit: 8, printable_limit: 512)

  defp outcome_diagnostic({:returned, {:error, {:workspace_hook_failed, hook, status, _output}}}),
    do: "workspace_hook_failed: hook=#{hook} status=#{status}"

  defp outcome_diagnostic({:returned, {:error, reason}}), do: "error: " <> inspect(reason, limit: 8, printable_limit: 512)
  defp outcome_diagnostic({:returned, {:done, _issue}}), do: "done"
  defp outcome_diagnostic({:returned, _value}), do: "returned"

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
              RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(lease))
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

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
