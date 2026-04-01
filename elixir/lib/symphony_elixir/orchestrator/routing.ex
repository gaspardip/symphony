defmodule SymphonyElixir.Orchestrator.Routing do
  @moduledoc """
  Label-gate eligibility and dispatch-skip routing logic extracted from the Orchestrator.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunnerRuntime

  @merging_state "Merging"

  # ---------------------------------------------------------------------------
  # Label gate cluster
  # ---------------------------------------------------------------------------

  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  def issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  def issue_labels(_issue), do: []

  def issue_matches_required_labels?(%Issue{} = issue) do
    label_gate_status(issue).eligible?
  end

  def issue_matches_required_labels?(_issue), do: true

  def label_gate_status(%Issue{source: :manual}) do
    %{eligible?: true, required_labels: [], reason: nil}
  end

  def label_gate_status(%Issue{} = issue) do
    required_labels = routing_required_labels()
    required_label_set = normalize_labels(required_labels)

    if MapSet.size(required_label_set) == 0 do
      %{eligible?: true, required_labels: required_labels, reason: nil}
    else
      issue_label_set = issue |> Issue.label_names() |> normalize_labels()

      cond do
        MapSet.subset?(required_label_set, issue_label_set) ->
          %{eligible?: true, required_labels: required_labels, reason: nil}

        missing_canary_labels?(issue_label_set, required_label_set) ->
          %{eligible?: false, required_labels: required_labels, reason: "missing canary labels"}

        true ->
          %{eligible?: false, required_labels: required_labels, reason: "missing required labels"}
      end
    end
  end

  def label_gate_status(_issue),
    do: %{eligible?: true, required_labels: routing_required_labels(), reason: nil}

  def todo_issue_blocked_by_non_terminal?(
        %Issue{state: issue_state, blocked_by: blockers},
        terminal_states
      )
      when is_binary(issue_state) and is_list(blockers) do
    SymphonyElixir.Util.normalize_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  def todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, SymphonyElixir.Util.normalize_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, SymphonyElixir.Util.normalize_state(state_name))
  end

  def terminal_state_set do
    Config.linear_terminal_states()
    |> Enum.map(&SymphonyElixir.Util.normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  def active_state_set do
    Config.linear_active_states()
    |> Enum.map(&SymphonyElixir.Util.normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
    |> MapSet.put(SymphonyElixir.Util.normalize_state(@merging_state))
  end

  # ---------------------------------------------------------------------------
  # Dispatch skip cluster
  # ---------------------------------------------------------------------------

  def dispatch_skip_reason(%Issue{} = issue, %SymphonyElixir.Orchestrator.State{} = state) do
    label_gate = label_gate_status(issue)
    policy_result = SymphonyElixir.Orchestrator.resolve_policy(issue, state)

    cond do
      not issue_routed_to_current_runner_channel?(issue) ->
        "wrong runner channel"

      match?(%{eligible?: false}, label_gate) ->
        label_gate.reason

      match?({:error, _}, policy_result) ->
        {:error, conflict} = policy_result
        Map.get(conflict, :rule_id) || RuleCatalog.rule_id(:policy_invalid_labels)

      true ->
        nil
    end
  end

  def queue_policy_reason(
        %Issue{} = issue,
        %SymphonyElixir.Orchestrator.State{} = state,
        run_state
      ) do
    run_state = run_state || %{}

    last_decision =
      case Map.get(run_state, :last_decision) do
        %{} = decision -> decision
        _ -> %{}
      end

    case SymphonyElixir.Orchestrator.resolve_policy(issue, state) do
      {:error, conflict} ->
        {conflict.rule_id, conflict.failure_class, conflict.summary, conflict.human_action}

      {:ok, %{class: :review_required}} ->
        {
          RuleCatalog.rule_id(:policy_review_required),
          RuleCatalog.failure_class(:policy_review_required),
          "Policy requires human review before merge.",
          RuleCatalog.human_action(:policy_review_required)
        }

      {:ok, %{class: :never_automerge}} ->
        {
          RuleCatalog.rule_id(:policy_never_automerge),
          RuleCatalog.failure_class(:policy_never_automerge),
          "Policy forbids automerge for this issue.",
          RuleCatalog.human_action(:policy_never_automerge)
        }

      _ ->
        {
          Map.get(run_state, :last_rule_id) || Map.get(last_decision, :rule_id),
          Map.get(run_state, :last_failure_class) || Map.get(last_decision, :failure_class),
          Map.get(run_state, :last_decision_summary) || Map.get(last_decision, :summary),
          Map.get(run_state, :next_human_action) || Map.get(last_decision, :human_action)
        }
    end
  end

  def issue_routed_to_current_runner_channel?(%Issue{} = issue) do
    issue_target_runner_channel(issue) == Config.runner_channel()
  end

  def issue_target_runner_channel(%Issue{} = issue) do
    canary_labels =
      RunnerRuntime.canary_required_labels(%{})
      |> normalize_labels()

    issue_labels =
      issue
      |> Issue.label_names()
      |> normalize_labels()

    if MapSet.size(canary_labels) > 0 and MapSet.subset?(canary_labels, issue_labels) do
      "canary"
    else
      "stable"
    end
  end

  def next_human_action_for_skip("missing required labels"),
    do: "Add the required routing labels before Symphony can dispatch this issue."

  def next_human_action_for_skip("missing canary labels"),
    do: "Add the canary routing labels before Symphony can dispatch this issue during canary mode."

  def next_human_action_for_skip("wrong runner channel"),
    do: "Route this issue to a runner on the matching channel before Symphony can dispatch it."

  def next_human_action_for_skip(reason) when is_binary(reason) do
    cond do
      reason == RuleCatalog.rule_id(:policy_invalid_labels) ->
        RuleCatalog.human_action(:policy_invalid_labels)

      true ->
        nil
    end
  end

  def next_human_action_for_skip(_reason), do: nil

  def routing_required_labels do
    RunnerRuntime.effective_required_labels(Config.linear_required_labels())
  end

  def missing_canary_labels?(issue_label_set, required_label_set)
      when is_struct(issue_label_set, MapSet) and is_struct(required_label_set, MapSet) do
    workflow_required = normalize_labels(Config.linear_required_labels())
    canary_required = MapSet.difference(required_label_set, workflow_required)

    MapSet.size(canary_required) > 0 and not MapSet.subset?(canary_required, issue_label_set)
  end

  def missing_canary_labels?(_issue_label_set, _required_label_set), do: false

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  def normalize_labels(labels) do
    labels
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end
end
