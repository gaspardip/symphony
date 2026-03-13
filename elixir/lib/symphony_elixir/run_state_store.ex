defmodule SymphonyElixir.RunStateStore do
  @moduledoc """
  Persists per-workspace runtime state so runs can resume from explicit stages.
  """

  alias SymphonyElixir.Observability
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.RunnerRuntime
  alias SymphonyElixir.Config

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

  @spec load_checked(Path.t(), map()) :: {:ok, map()} | {:mismatch, map()} | {:error, :missing | term()}
  def load_checked(workspace, issue) when is_binary(workspace) and is_map(issue) do
    case load(workspace) do
      {:ok, state} ->
        if run_state_matches_issue?(state, issue) do
          {:ok, merge_defaults(state, issue)}
        else
          {:mismatch, state}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec load_or_default(Path.t(), map()) :: map()
  def load_or_default(workspace, issue) when is_binary(workspace) and is_map(issue) do
    case load(workspace) do
      {:ok, state} ->
        if run_state_matches_issue?(state, issue) do
          merge_defaults(state, issue)
        else
          default_state(issue)
        end

      {:error, _reason} ->
        default_state(issue)
    end
  end

  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(workspace, state) when is_binary(workspace) and is_map(state) do
    path = state_path(workspace)
    state = ensure_runner_metadata(state)
    :ok = File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(state), [:write])
  end

  @spec transition(Path.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transition(workspace, stage, attrs \\ %{})
      when is_binary(workspace) and is_binary(stage) and is_map(attrs) do
    previous_state = load_or_default(workspace, %{})
    same_stage? = Map.get(previous_state, :stage) == stage

    state =
      previous_state
      |> Map.merge(attrs)
      |> Map.put(:stage, stage)
      |> maybe_record_stage_transition(stage, Map.get(attrs, :reason), same_stage?)

    case save(workspace, state) do
      :ok ->
        if same_stage? do
          {:ok, state}
        else
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

          Observability.emit(
            [:symphony, :stage, :transition],
            %{count: 1},
            %{
              issue_id: Map.get(state, :issue_id),
              issue_identifier: Map.get(state, :issue_identifier),
              issue_source: Map.get(state, :issue_source),
              stage: stage,
              policy_class: Map.get(state, :effective_policy_class),
              stage_transition_count: get_in(state, [:stage_transition_counts, stage]),
              stage_history_size: length(Map.get(state, :stage_history, []))
            }
          )

          persisted_state = Map.put(state, :last_ledger_event_id, Map.get(ledger_event, :event_id))
          :ok = save(workspace, persisted_state)
          {:ok, persisted_state}
        end

      {:error, reason} ->
        {:error, reason}
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

  defp maybe_record_stage_transition(state, stage, reason, false) do
    state
    |> bump_stage_transition_count(stage)
    |> update_stage_history(stage, reason)
  end

  defp maybe_record_stage_transition(state, _stage, _reason, true), do: state

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
      issue_source: Map.get(issue, :source) || Map.get(issue, "source"),
      runner_instance_id: Config.runner_instance_id(),
      runner_instance_name: Config.runner_instance_name(),
      runner_channel: Config.runner_channel(),
      runner_runtime_version: RunnerRuntime.runtime_version(),
      runner_workspace_root: Config.workspace_root(),
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
      review_approved: false,
      merge_window_wait: nil,
      policy_override: nil,
      effective_policy_class: nil,
      effective_policy_source: nil,
      last_pr_state: nil,
      review_threads: %{},
      review_claims: %{},
      review_return_stage: nil,
      last_review_decision: nil,
      last_check_statuses: [],
      last_required_checks_state: nil,
      last_missing_required_checks: [],
      last_pending_required_checks: [],
      last_failing_required_checks: [],
      last_cancelled_required_checks: [],
      acceptance_summary: nil,
      last_verifier_verdict: nil,
      last_harness_init: nil,
      last_harness_check: nil,
      harness_status: nil,
      harness_attempts: 0,
      resume_context: %{},
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
    |> Map.put(
      :issue_source,
      Map.get(state, :issue_source) || Map.get(defaults, :issue_source)
    )
    |> ensure_runner_metadata()
  end

  defp ensure_runner_metadata(state) when is_map(state) do
    state
    |> put_missing(:runner_instance_id, Config.runner_instance_id())
    |> put_missing(:runner_instance_name, Config.runner_instance_name())
    |> put_missing(:runner_channel, Config.runner_channel())
    |> put_missing(:runner_runtime_version, RunnerRuntime.runtime_version())
    |> put_missing(:runner_workspace_root, Config.workspace_root())
  end

  defp put_missing(state, key, value) when is_map(state) do
    case Map.get(state, key) do
      existing when existing in [nil, ""] -> Map.put(state, key, value)
      _existing -> state
    end
  end

  defp run_state_matches_issue?(state, issue) when is_map(state) and is_map(issue) do
    state_id = Map.get(state, :issue_id)
    state_identifier = Map.get(state, :issue_identifier)
    issue_id = Map.get(issue, :id) || Map.get(issue, "id")
    issue_identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")

    cond do
      not present?(issue_id) and not present?(issue_identifier) ->
        true

      present?(state_id) ->
        state_id == issue_id

      present?(state_identifier) ->
        state_identifier == issue_identifier

      true ->
        true
    end
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value)

  defp atomize(map) when is_map(map) do
    if preserve_string_keys_map?(map) do
      Map.new(map, fn {key, value} ->
        {key, preserve_string_keys_value(value)}
      end)
    else
      Map.new(map, fn {key, value} ->
        {atom_key(key), atomize_value(value)}
      end)
    end
  end

  defp atomize_value(value) when is_map(value), do: atomize(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value

  defp preserve_string_keys_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {key, preserve_string_keys_value(nested_value)}
    end)
  end

  defp preserve_string_keys_value(value) when is_list(value),
    do: Enum.map(value, &preserve_string_keys_value/1)

  defp preserve_string_keys_value(value), do: value

  defp atom_key(key) when is_binary(key) do
    if atomizable_key?(key) do
      String.to_existing_atom(key)
    else
      key
    end
  rescue
    ArgumentError ->
      if atomizable_key?(key) do
        String.to_atom(key)
      else
        key
      end
  end

  defp atomizable_key?(key) when is_binary(key) do
    String.match?(key, ~r/^[a-z_][a-zA-Z0-9_]*[!?]?$/)
  end

  defp preserve_string_keys_map?(map) when is_map(map) do
    Enum.any?(Map.keys(map), fn
      key when is_binary(key) -> not atomizable_key?(key)
      _ -> false
    end)
  end
end
