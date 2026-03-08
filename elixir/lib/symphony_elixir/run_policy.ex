defmodule SymphonyElixir.RunPolicy do
  @moduledoc """
  Enforces hard runtime rules around checkout, validation, PR readiness, and noop turns.
  """

  # credo:disable-for-this-file

  require Logger

  alias SymphonyElixir.{Config, RuleCatalog, RunInspector, RunLedger, RunStateStore, RunnerRuntime, Tracker}

  defmodule Violation do
    @moduledoc false

    defstruct [:code, :rule_id, :failure_class, :summary, :details, :human_action, :target_state]
  end

  @blocked_state "Blocked"
  @in_progress_state "In Progress"
  @human_review_state "Human Review"

  @type violation :: %Violation{
          code: atom(),
          summary: String.t(),
          details: String.t(),
          target_state: String.t()
        }

  @spec enforce_pre_run(map(), Path.t(), keyword()) :: :ok | {:stop, violation()}
  def enforce_pre_run(issue, workspace, opts \\ []) do
    inspection = RunInspector.inspect(workspace, opts)

    cond do
      RunnerRuntime.overlaps_protected_path?(workspace) ->
        stop_issue(issue, runner_overlap_violation(workspace), workspace)

      Config.policy_require_checkout?() and not inspection.git? ->
        stop_issue(issue, missing_checkout_violation(workspace), workspace)

      Config.policy_require_validation?() and inspection.harness_error not in [nil, :missing] ->
        stop_issue(issue, harness_validation_violation(workspace, inspection.harness_error), workspace)

      Config.policy_require_validation?() and is_nil(inspection.harness) ->
        stop_issue(issue, missing_harness_violation(workspace), workspace)

      true ->
        case RunInspector.run_preflight(workspace, inspection.harness, opts) do
          %{status: :failed, output: output} ->
            stop_issue(issue, preflight_failed_violation(output), workspace)

          %{status: :unavailable, output: output} ->
            stop_issue(issue, preflight_failed_violation(output), workspace)

          _ ->
            promote_todo_issue(issue)
        end
    end
  end

  @spec evaluate_after_turn(
          map(),
          map(),
          RunInspector.snapshot(),
          RunInspector.snapshot(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, non_neg_integer()} | {:stop, violation()}
  def evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, noop_turns, opts \\ []) do
    cond do
      require_pr_before_review_violation?(refreshed_issue, after_snapshot) ->
        stop_issue(issue, missing_pr_for_review_violation())

      validation_required?(refreshed_issue, before_snapshot, after_snapshot) ->
        case RunInspector.run_validation(after_snapshot.workspace, after_snapshot.harness, opts) do
          %{status: :passed} ->
            evaluate_noop(issue, before_snapshot, after_snapshot, noop_turns)

          %{status: :failed, output: output} ->
            stop_issue(issue, validation_failed_violation(output))

          %{status: :unavailable, output: output} ->
            stop_issue(issue, validation_unavailable_violation(output))
        end

      true ->
        evaluate_noop(issue, before_snapshot, after_snapshot, noop_turns)
    end
  end

  @spec maybe_stop_for_token_budget(map(), map()) :: :ok | {:stop, violation()}
  def maybe_stop_for_token_budget(issue, running_entry) do
    token_budget = Config.policy_token_budget()
    input_total = Map.get(running_entry, :codex_input_tokens, 0)
    output_total = Map.get(running_entry, :codex_output_tokens, 0)
    total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    turn_started_input = Map.get(running_entry, :turn_started_input_tokens, 0)
    current_turn_input = max(0, input_total - turn_started_input)

    cond do
      budget_exceeded?(token_budget[:per_turn_input], current_turn_input) ->
      stop_issue(issue, token_budget_violation(:per_turn_input, current_turn_input))

      budget_exceeded?(token_budget[:per_issue_total], total_tokens) ->
        stop_issue(issue, token_budget_violation(:per_issue_total, total_tokens))

      budget_exceeded?(token_budget[:per_issue_total_output], output_total) ->
        stop_issue(issue, token_budget_violation(:per_issue_total_output, output_total))

      true ->
        :ok
    end
  end

  defp promote_todo_issue(%{id: issue_id, state: state})
       when is_binary(issue_id) and is_binary(state) do
    if normalize_state(state) == normalize_state(@in_progress_state) do
      :ok
    else
      if normalize_state(state) == "todo" do
        case Tracker.update_issue_state(issue_id, @in_progress_state) do
          :ok ->
            :ok

          {:error, reason} ->
            stop_issue(
              %{id: issue_id},
              preflight_failed_violation("Unable to move issue to In Progress: #{inspect(reason)}")
            )
        end
      else
        :ok
      end
    end
  end

  defp promote_todo_issue(_issue), do: :ok

  defp evaluate_noop(issue, before_snapshot, after_snapshot, noop_turns) do
    noop_turns =
      if noop_turn?(before_snapshot, after_snapshot) do
        noop_turns + 1
      else
        0
      end

    if Config.policy_stop_on_noop_turn?() and noop_turns >= Config.policy_max_noop_turns() do
      stop_issue(issue, noop_turn_violation(noop_turns))
    else
      {:ok, noop_turns}
    end
  end

  defp validation_required?(refreshed_issue, before_snapshot, after_snapshot) do
    Config.policy_require_validation?() and
      (RunInspector.code_changed?(before_snapshot, after_snapshot) or
         not is_nil(after_snapshot.pr_url) or
         human_review_state?(refreshed_issue))
  end

  defp require_pr_before_review_violation?(refreshed_issue, after_snapshot) do
    Config.policy_require_pr_before_review?() and
      human_review_state?(refreshed_issue) and
      is_nil(after_snapshot.pr_url)
  end

  defp human_review_state?(%{state: state}) when is_binary(state) do
    normalize_state(state) == normalize_state(@human_review_state)
  end

  defp human_review_state?(_issue), do: false

  defp noop_turn?(before_snapshot, after_snapshot) do
    not RunInspector.code_changed?(before_snapshot, after_snapshot) and is_nil(after_snapshot.pr_url)
  end

  defp stop_issue(issue, %Violation{} = violation, workspace \\ nil) do
    issue_id = Map.get(issue, :id) || Map.get(issue, "id")

    issue_identifier =
      Map.get(issue, :identifier) || Map.get(issue, "identifier") || issue_id || "unknown"

    comment = violation_comment(issue_identifier, violation)

    ledger_event =
      RunLedger.record("runtime.stopped", %{
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      actor_type: "runtime",
      actor_id: "run_policy",
      failure_class: violation.failure_class,
      rule_id: violation.rule_id,
      summary: violation.summary,
      details: violation.details,
      target_state: violation.target_state,
      metadata: %{
        code: Atom.to_string(violation.code),
        human_action: violation.human_action
      }
    })

    if is_binary(workspace) do
      _ =
        RunStateStore.transition(workspace, "blocked", %{
          stop_reason: %{
            code: Atom.to_string(violation.code),
            rule_id: violation.rule_id,
            failure_class: violation.failure_class,
            summary: violation.summary,
            details: violation.details,
            human_action: violation.human_action
          },
          last_decision: %{
            rule_id: violation.rule_id,
            failure_class: violation.failure_class,
            summary: violation.summary,
            details: violation.details,
            human_action: violation.human_action,
            target_state: violation.target_state,
            ledger_event_id: Map.get(ledger_event, :event_id)
          },
          last_rule_id: violation.rule_id,
          last_failure_class: violation.failure_class,
          last_decision_summary: violation.summary,
          next_human_action: violation.human_action
        })
    end

    if is_binary(issue_id) do
      case Tracker.create_comment(issue_id, comment) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to create policy comment for #{issue_identifier}: #{inspect(reason)}")
      end

      case Tracker.update_issue_state(issue_id, violation.target_state) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to move #{issue_identifier} to #{violation.target_state}: #{inspect(reason)}")
      end
    end

    {:stop, violation}
  end

  defp violation_comment(issue_identifier, %Violation{} = violation) do
    """
    ## Symphony policy stop

    Issue: #{issue_identifier}
    Rule ID: #{violation.rule_id}
    Failure class: #{violation.failure_class}

    #{violation.summary}

    #{violation.details}

    Unblock action: #{violation.human_action}
    """
    |> String.trim()
  end

  defp missing_checkout_violation(workspace) do
    violation(:missing_checkout,
      summary: "No repository checkout was found in the workspace, so the run stopped before turn 1.",
      details: "Expected a Git checkout under `#{workspace}`, but `.git` was missing."
    )
  end

  defp preflight_failed_violation(output) do
    violation(:preflight_failed,
      summary: "The repo preflight failed, so Symphony stopped before continuing.",
      details: truncate_output(output)
    )
  end

  defp missing_harness_violation(workspace) do
    violation(:missing_harness,
      summary: "The repo harness contract is missing, so Symphony cannot validate this run autonomously.",
      details: "Expected `#{Path.join(workspace, ".symphony/harness.yml")}` to exist before dispatch."
    )
  end

  defp harness_validation_violation(_workspace, :missing_harness_version) do
    violation(:missing_harness_version,
      summary: "The repo harness contract is missing `version: 1`.",
      details: "Add `version: 1` to `.symphony/harness.yml` before dispatching this issue again."
    )
  end

  defp harness_validation_violation(_workspace, :missing_required_checks) do
    violation(:missing_required_checks,
      summary: "The repo harness does not declare `pull_request.required_checks`.",
      details: "Define the publish gate checks in `.symphony/harness.yml`."
    )
  end

  defp harness_validation_violation(_workspace, {:missing_harness_command, stage}) do
    violation(:missing_harness_command,
      summary: "The repo harness is missing a required command entry.",
      details: "Expected `#{stage}.command` in `.symphony/harness.yml`."
    )
  end

  defp harness_validation_violation(_workspace, {:unknown_harness_keys, path, keys}) do
    violation(:invalid_harness,
      summary: "The repo harness contains unsupported keys.",
      details: "Unknown keys under #{Enum.join(path, ".")}: #{Enum.join(keys, ", ")}."
    )
  end

  defp harness_validation_violation(_workspace, reason) do
    violation(:invalid_harness,
      summary: "The repo harness contract is invalid.",
      details: truncate_output(inspect(reason))
    )
  end

  defp runner_overlap_violation(workspace) do
    violation(:runner_overlap,
      summary: "The target workspace overlaps the protected Symphony runner install or current checkout.",
      details: "Workspace `#{workspace}` overlaps one of: #{Enum.join(RunnerRuntime.protected_paths(), ", ")}."
    )
  end

  defp validation_unavailable_violation(output) do
    violation(:validation_unavailable,
      summary: "Required validation could not run, so the issue was blocked.",
      details: truncate_output(output)
    )
  end

  defp validation_failed_violation(output) do
    violation(:validation_failed,
      summary: "Required validation failed, so the issue was blocked for follow-up.",
      details: truncate_output(output)
    )
  end

  defp missing_pr_for_review_violation do
    violation(:publish_missing_pr,
      summary: "The issue moved to Human Review without an open PR, so Symphony blocked it.",
      details: "Create or attach a PR before moving the issue back into the review flow."
    )
  end

  defp noop_turn_violation(noop_turns) do
    violation(:noop_turn,
      summary: "The last turn produced no code change and no PR, so Symphony stopped the run.",
      details: "Noop turns observed: #{noop_turns}."
    )
  end

  defp token_budget_violation(kind, observed) do
    code =
      case kind do
        :per_turn_input -> :per_turn_input_budget_exceeded
        :per_issue_total -> :per_issue_total_budget_exceeded
        :per_issue_total_output -> :per_issue_output_budget_exceeded
      end

    violation(code,
      summary: "The run exceeded a configured token budget and was stopped.",
      details: "Budget #{kind} exceeded with observed value #{observed}."
    )
  end

  defp budget_exceeded?(nil, _observed), do: false
  defp budget_exceeded?(budget, observed) when is_integer(budget), do: observed > budget

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp truncate_output(nil), do: "No additional output was captured."

  defp truncate_output(output) do
    output
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "No additional output was captured."
      trimmed -> String.slice(trimmed, 0, 1_000)
    end
  end

  defp violation(code, attrs) do
    rule = RuleCatalog.rule(code)

    %Violation{
      code: code,
      rule_id: rule.rule_id,
      failure_class: rule.failure_class,
      summary: Keyword.fetch!(attrs, :summary),
      details: Keyword.fetch!(attrs, :details),
      human_action: Keyword.get(attrs, :human_action, rule.human_action),
      target_state: Keyword.get(attrs, :target_state, @blocked_state)
    }
  end
end
