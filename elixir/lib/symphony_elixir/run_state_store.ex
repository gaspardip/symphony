defmodule SymphonyElixir.RunStateStore do
  @moduledoc """
  Persists per-workspace runtime state so runs can resume from explicit stages.
  """

  alias SymphonyElixir.RunLedger

  @relative_dir ".symphony"
  @filename "run_state.json"
  @stage_history_limit 25

  @spec state_path(Path.t()) :: Path.t()
  def state_path(workspace) when is_binary(workspace) do
    Path.join([workspace, @relative_dir, @filename])
  end

  @spec load(Path.t()) :: {:ok, map()} | {:error, :missing | term()}
  def load(workspace) when is_binary(workspace) do
    path = state_path(workspace)

    with true <- File.exists?(path) or {:error, :missing},
         {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload),
         true <- is_map(decoded) or {:error, :invalid_state} do
      {:ok, atomize(decoded)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_or_default(Path.t(), map()) :: map()
  def load_or_default(workspace, issue) when is_binary(workspace) and is_map(issue) do
    case load(workspace) do
      {:ok, state} ->
        merge_defaults(state, issue)

      {:error, _reason} ->
        default_state(issue)
    end
  end

  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(workspace, state) when is_binary(workspace) and is_map(state) do
    path = state_path(workspace)
    :ok = File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(state), [:write])
  end

  @spec transition(Path.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transition(workspace, stage, attrs \\ %{})
      when is_binary(workspace) and is_binary(stage) and is_map(attrs) do
    state =
      workspace
      |> load_or_default(%{})
      |> Map.merge(attrs)
      |> Map.put(:stage, stage)
      |> bump_stage_transition_count(stage)
      |> update_stage_history(stage, Map.get(attrs, :reason))

    case save(workspace, state) do
      :ok ->
        ledger_event =
          RunLedger.record("stage.transition", %{
            issue_id: Map.get(state, :issue_id),
            issue_identifier: Map.get(state, :issue_identifier),
            stage: stage,
            actor_type: "runtime",
            actor_id: "run_state_store",
            policy_class: Map.get(state, :effective_policy_class),
            summary: "Transitioned to #{stage}",
            details: Map.get(attrs, :reason),
            metadata: %{
              stage_transition_count: get_in(state, [:stage_transition_counts, stage]),
              stage_history_size: length(Map.get(state, :stage_history, []))
            }
          })

        persisted_state = Map.put(state, :last_ledger_event_id, Map.get(ledger_event, :event_id))
        :ok = save(workspace, persisted_state)
        {:ok, persisted_state}

      {:error, reason} -> {:error, reason}
    end
  end

  @spec update(Path.t(), (map() -> map())) :: {:ok, map()} | {:error, term()}
  def update(workspace, fun) when is_binary(workspace) and is_function(fun, 1) do
    state =
      workspace
      |> load_or_default(%{})
      |> fun.()

    case save(workspace, state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete(Path.t()) :: :ok
  def delete(workspace) when is_binary(workspace) do
    File.rm(state_path(workspace))
    :ok
  end

  defp update_stage_history(state, stage, reason) do
    entry = %{
      stage: stage,
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      reason: reason
    }

    history =
      state
      |> Map.get(:stage_history, [])
      |> List.wrap()
      |> Kernel.++([entry])
      |> Enum.take(-@stage_history_limit)

    Map.put(state, :stage_history, history)
  end

  defp bump_stage_transition_count(state, stage) do
    stage_transition_counts =
      state
      |> Map.get(:stage_transition_counts, %{})
      |> Map.put(stage, Map.get(state |> Map.get(:stage_transition_counts, %{}), stage, 0) + 1)

    Map.put(state, :stage_transition_counts, stage_transition_counts)
  end

  defp default_state(issue) when is_map(issue) do
    %{
      issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      stage: "checkout",
      stage_history: [],
      stage_transition_counts: %{},
      implementation_turns: 0,
      validation_attempts: 0,
      verification_attempts: 0,
      publish_attempts: 0,
      await_checks_polls: 0,
      merge_attempts: 0,
      automerge_disabled: false,
      policy_override: nil,
      effective_policy_class: nil,
      effective_policy_source: nil,
      last_pr_state: nil,
      last_review_decision: nil,
      last_check_statuses: [],
      last_required_checks_state: nil,
      last_missing_required_checks: [],
      last_pending_required_checks: [],
      last_failing_required_checks: [],
      last_cancelled_required_checks: [],
      acceptance_summary: nil,
      last_verifier_verdict: nil,
      last_decision: nil,
      last_rule_id: nil,
      last_failure_class: nil,
      last_decision_summary: nil,
      next_human_action: nil,
      last_ledger_event_id: nil,
      last_merge: nil,
      stop_reason: nil,
      lease_epoch: nil
    }
  end

  defp merge_defaults(state, issue) when is_map(state) and is_map(issue) do
    defaults = default_state(issue)

    defaults
    |> Map.merge(state)
    |> Map.put(:issue_id, Map.get(state, :issue_id) || Map.get(defaults, :issue_id))
    |> Map.put(
      :issue_identifier,
      Map.get(state, :issue_identifier) || Map.get(defaults, :issue_identifier)
    )
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {atom_key(key), atomize_value(value)}
    end)
  end

  defp atomize_value(value) when is_map(value), do: atomize(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> String.to_atom(key)
  end
end
