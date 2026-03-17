defmodule SymphonyElixir.RunPolicy do
  @moduledoc """
  Enforces hard runtime rules around checkout, validation, PR readiness, and noop turns.
  """

  # credo:disable-for-this-file

  require Logger

  alias SymphonyElixir.{
    Config,
    IssueSource,
    RepoCompatibility,
    RuleCatalog,
    RunInspector,
    RunLedger,
    RunStateStore,
    RunnerRuntime,
    WorkflowProfile,
    Workspace
  }

  defmodule Violation do
    @moduledoc false

    defstruct [
      :code,
      :rule_id,
      :failure_class,
      :summary,
      :details,
      :human_action,
      :target_state,
      metadata: %{}
    ]
  end

  @blocked_state "Blocked"
  @in_progress_state "In Progress"

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
        stop_issue(
          issue,
          harness_validation_violation(workspace, inspection.harness_error),
          workspace
        )

      Config.policy_require_validation?() and is_nil(inspection.harness) ->
        stop_issue(issue, missing_harness_violation(workspace), workspace)

      repo_boundary_mismatch?(inspection.origin_url) ->
        stop_issue(issue, repo_boundary_mismatch_violation(inspection.origin_url), workspace)

      true ->
        case workload_violation(issue) do
          nil ->
            case RepoCompatibility.compatible?(workspace, opts) do
              {:ok, true, _report} ->
                run_preflight_or_promote(issue, workspace, inspection, opts)

              {:ok, false, report} ->
                stop_issue(issue, repo_not_compatible_violation(report), workspace)
            end

          %Violation{} = violation ->
            stop_issue(issue, violation, workspace)
        end
    end
  end

  defp run_preflight_or_promote(issue, workspace, inspection, opts) do
    case RunInspector.run_preflight(workspace, inspection.harness, opts) do
      %{status: :failed, output: output} ->
        stop_issue(issue, preflight_failed_violation(output), workspace)

      %{status: :unavailable, output: output} ->
        stop_issue(issue, preflight_failed_violation(output), workspace)

      _ ->
        promote_todo_issue(issue)
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
  def evaluate_after_turn(
        issue,
        refreshed_issue,
        before_snapshot,
        after_snapshot,
        noop_turns,
        opts \\ []
      ) do
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

    workspace =
      Map.get(running_entry, :workspace_path) ||
        Workspace.path_for_issue(Map.get(issue, :identifier) || Map.get(issue, "identifier"))

    run_state = RunStateStore.load_or_default(workspace, issue)
    stage_budget = current_stage_token_budget(issue, running_entry, workspace, run_state)
    total_budget = current_total_token_budget(token_budget, issue, running_entry, run_state)
    input_total = Map.get(running_entry, :codex_input_tokens, 0)
    output_total = Map.get(running_entry, :codex_output_tokens, 0)
    total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    turn_started_input = Map.get(running_entry, :turn_started_input_tokens, 0)
    current_turn_input = max(0, input_total - turn_started_input)

    maybe_record_soft_budget_pressure(
      issue,
      running_entry,
      current_turn_input,
      stage_budget,
      workspace,
      run_state
    )

    cond do
      budget_exceeded?(
        stage_budget[:per_turn_input_hard] || token_budget[:per_turn_input],
        current_turn_input
      ) ->
        stop_issue(issue, token_budget_violation(:per_turn_input, current_turn_input), workspace)

      budget_exceeded?(total_budget, total_tokens) ->
        stop_issue(issue, token_budget_violation(:per_issue_total, total_tokens), workspace)

      budget_exceeded?(token_budget[:per_issue_total_output], output_total) ->
        stop_issue(
          issue,
          token_budget_violation(:per_issue_total_output, output_total),
          workspace
        )

      true ->
        :ok
    end
  end

  defp promote_todo_issue(%{id: issue_id, state: state} = issue)
       when is_binary(issue_id) and is_binary(state) do
    if normalize_state(state) == normalize_state(@in_progress_state) do
      :ok
    else
      if normalize_state(state) == "todo" do
        case IssueSource.update_issue_state(
               %{id: issue_id, source: Map.get(issue, :source)},
               @in_progress_state
             ) do
          :ok ->
            :ok

          {:error, {:tracker_mutation_forbidden, _pack}} ->
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
         approval_gate_state?(refreshed_issue))
  end

  defp require_pr_before_review_violation?(refreshed_issue, after_snapshot) do
    Config.policy_require_pr_before_review?() and
      approval_gate_state?(refreshed_issue) and
      is_nil(after_snapshot.pr_url)
  end

  defp approval_gate_state?(%{state: state}) when is_binary(state),
    do: WorkflowProfile.approval_gate_state?(state, policy_pack: Config.policy_pack_name())

  defp approval_gate_state?(_issue), do: false

  defp noop_turn?(before_snapshot, after_snapshot) do
    not RunInspector.code_changed?(before_snapshot, after_snapshot) and
      is_nil(after_snapshot.pr_url)
  end

  defp workload_violation(issue) do
    pack = SymphonyElixir.PolicyPack.resolve(Config.policy_pack_name())

    cond do
      pack.company_frozen ->
        freeze_violation(
          :company_frozen,
          "Company policy pack `#{SymphonyElixir.PolicyPack.name_string(pack)}` is frozen for new autonomous work.",
          "Disable the company freeze in the active policy pack before retrying this issue."
        )

      pack.repo_frozen ->
        freeze_violation(
          :repo_frozen,
          "Repo policy pack `#{SymphonyElixir.PolicyPack.name_string(pack)}` is frozen for new autonomous work.",
          "Disable the repo freeze in the active policy pack before retrying this issue."
        )

      true ->
        case SymphonyElixir.PolicyPack.workload_label_status(pack, Map.get(issue, :labels, [])) do
          :allowed ->
            nil

          {:missing_required_any, labels} ->
            workload_restricted_violation(
              "Issue does not match the active workload filter for #{SymphonyElixir.PolicyPack.name_string(pack)}.",
              "Allowed workload labels: #{Enum.join(labels, ", ")}.",
              "Add one of the allowed workload labels or switch the company policy pack."
            )

          {:forbidden_present, labels} ->
            workload_restricted_violation(
              "Issue is blocked by the active workload filter for #{SymphonyElixir.PolicyPack.name_string(pack)}.",
              "Forbidden workload labels present: #{Enum.join(labels, ", ")}.",
              "Remove the forbidden workload labels or switch the company policy pack."
            )
        end
    end
  end

  defp repo_boundary_mismatch?(origin_url) do
    expected = Config.company_repo_url()

    is_binary(expected) and expected != "" and is_binary(origin_url) and
      normalize_repo_url(expected) != normalize_repo_url(origin_url)
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
          human_action: violation.human_action,
          violation_metadata: violation.metadata
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
            ledger_event_id: Map.get(ledger_event, :event_id),
            metadata: violation.metadata
          },
          last_rule_id: violation.rule_id,
          last_failure_class: violation.failure_class,
          last_decision_summary: violation.summary,
          next_human_action: violation.human_action
        })
    end

    if is_binary(issue_id) do
      case IssueSource.create_comment(issue, comment) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to create policy comment for #{issue_identifier}: #{inspect(reason)}")
      end

      case IssueSource.update_issue_state(issue, violation.target_state) do
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

  defp repo_not_compatible_violation(report) do
    failing =
      report
      |> Map.get(:checks, [])
      |> Enum.filter(&(&1.required and &1.status == :failed))

    details =
      failing
      |> Enum.map(fn check -> "#{check.id}: #{check.summary} #{check.details}" end)
      |> Enum.join("\n")
      |> case do
        "" -> truncate_output(inspect(report))
        value -> value
      end

    violation(:repo_not_compatible,
      summary: "The repo failed Symphony compatibility checks before execution.",
      details: details,
      metadata: %{compatibility_report: report}
    )
  end

  defp runner_overlap_violation(workspace) do
    violation(:runner_overlap,
      summary: "The target workspace overlaps the protected Symphony runner install or current checkout.",
      details: "Workspace `#{workspace}` overlaps one of: #{Enum.join(RunnerRuntime.protected_paths(), ", ")}."
    )
  end

  defp repo_boundary_mismatch_violation(origin_url) do
    expected = Config.company_repo_url() || "unknown"

    violation(:repo_boundary_mismatch,
      summary: "The workspace checkout does not belong to the configured company/repo boundary.",
      details: "Expected origin `#{expected}`, but found `#{origin_url || "unknown"}`.",
      human_action: "Repair the checkout remote or discard the workspace so it points at the configured repo before retrying."
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

  defp workload_restricted_violation(summary, details, human_action) do
    violation(:policy_workload_restricted,
      summary: summary,
      details: details,
      human_action: human_action
    )
  end

  defp freeze_violation(code, summary, details) do
    violation(code,
      summary: summary,
      details: details
    )
  end

  defp budget_exceeded?(nil, _observed), do: false
  defp budget_exceeded?(budget, observed) when is_integer(budget), do: observed > budget

  defp current_stage_token_budget(issue, running_entry, workspace, run_state) do
    stage =
      Map.get(running_entry, :dispatch_stage) ||
        Map.get(running_entry, :stage) ||
        current_stage(issue, workspace, run_state)

    stage_budget =
      case Config.policy_stage_token_budget(stage) do
        budget when is_map(budget) -> budget
        _ -> %{}
      end

    maybe_relax_review_fix_budget(stage_budget, issue, stage, workspace, run_state)
  end

  defp current_total_token_budget(token_budget, issue, running_entry, run_state)
       when is_map(token_budget) and is_map(run_state) do
    total_budget = Map.get(token_budget, :per_issue_total)
    stage = Map.get(running_entry, :dispatch_stage) || Map.get(running_entry, :stage)

    maybe_relax_review_fix_total_budget(total_budget, issue, stage, run_state)
  end

  defp current_total_token_budget(token_budget, _issue, _running_entry, _run_state)
       when is_map(token_budget) do
    Map.get(token_budget, :per_issue_total)
  end

  defp current_stage(issue, workspace, run_state)
       when is_binary(workspace) and is_map(run_state) do
    case run_state do
      %{stage: stage} when is_binary(stage) -> stage
      _ -> current_stage(issue, workspace)
    end
  end

  defp current_stage(issue, workspace) when is_binary(workspace) do
    case RunStateStore.load_or_default(workspace, issue) do
      %{stage: stage} when is_binary(stage) -> stage
      _ -> nil
    end
  end

  defp maybe_record_soft_budget_pressure(
         issue,
         running_entry,
         current_turn_input,
         stage_budget,
         workspace,
         run_state
       ) do
    soft_budget = stage_budget[:per_turn_input_soft]

    if budget_exceeded?(soft_budget, current_turn_input) do
      case run_state do
        state when is_map(state) ->
          stage = Map.get(running_entry, :stage) || Map.get(state, :stage)
          issue_identifier = issue_identifier_for(issue, state)
          existing_retry_count = review_fix_budget_retry_count(state, issue_identifier)
          retry_tracking? = review_fix_retry_tracking_candidate?(state, stage)
          needs_retry_count? = retry_tracking? and existing_retry_count == 0

          if review_token_pressure_high?(state) and not needs_retry_count? do
            :ok
          else
            review_fix_retry_count =
              cond do
                not retry_tracking? -> nil
                needs_retry_count? -> 1
                true -> min(existing_retry_count + 1, 2)
              end

            resume_context =
              state
              |> Map.get(:resume_context, %{})
              |> Enum.into(%{})
              |> Map.put(:token_pressure, "high")
              |> maybe_put_review_fix_retry_count(review_fix_retry_count)

            _ =
              RunStateStore.transition(workspace, Map.get(state, :stage, "checkout"), %{
                resume_context: resume_context
              })

            _ =
              RunLedger.record("policy.decided", %{
                issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
                issue_identifier: issue_identifier,
                actor_type: "runtime",
                actor_id: "run_policy",
                summary: "Turn entered soft token pressure.",
                details: "Observed implement/verify input tokens #{current_turn_input} above soft budget #{soft_budget}.",
                metadata: %{
                  stage: stage,
                  observed: current_turn_input,
                  soft_budget: soft_budget,
                  review_fix_budget_retry_count: review_fix_retry_count
                }
              })

            :ok
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_relax_review_fix_budget(stage_budget, issue, stage, _workspace, state)
       when is_map(stage_budget) and is_map(state) do
    issue_identifier = issue_identifier_for(issue, state)
    retry_count = review_fix_budget_retry_count(state, issue_identifier)

    if review_fix_budget_candidate?(state, stage) and retry_count > 0 do
      review_fix_relaxed_stage_budget(stage_budget, retry_count, state)
    else
      stage_budget
    end
  end

  defp review_fix_relaxed_stage_budget(stage_budget, retry_count, state)
       when is_map(stage_budget) and is_integer(retry_count) do
    cond do
      retry_count >= 2 and review_fix_turn_window_active?(state) ->
        stage_budget
        |> Map.put(
          :per_turn_input_soft,
          relaxed_budget_value(stage_budget[:per_turn_input_soft], 110_000)
        )
        |> Map.put(
          :per_turn_input_hard,
          relaxed_budget_value(stage_budget[:per_turn_input_hard], 220_000)
        )

      true ->
        stage_budget
        |> Map.put(
          :per_turn_input_soft,
          relaxed_budget_value(stage_budget[:per_turn_input_soft], 85_000)
        )
        |> Map.put(
          :per_turn_input_hard,
          relaxed_budget_value(stage_budget[:per_turn_input_hard], 150_000)
        )
    end
  end

  defp review_fix_budget_candidate?(state, stage) do
    stage == "implement" and
      review_token_pressure_high?(state) and
      accepted_review_claim_count(state) > 0
  end

  defp maybe_relax_review_fix_total_budget(total_budget, issue, stage, state)
       when is_integer(total_budget) and is_map(state) do
    issue_identifier = issue_identifier_for(issue, state)
    retry_count = review_fix_budget_retry_count(state, issue_identifier)

    if review_fix_total_budget_candidate?(state, stage) and retry_count > 0 do
      total_budget + review_fix_total_budget_extension(state, retry_count)
    else
      total_budget
    end
  end

  defp maybe_relax_review_fix_total_budget(total_budget, _issue, _stage, _state), do: total_budget

  defp review_fix_total_budget_candidate?(state, stage) do
    review_fix_budget_candidate?(state, stage) and
      addressed_review_claim_count(state) > 0
  end

  defp review_fix_total_budget_extension(state, retry_count)
       when is_map(state) and is_integer(retry_count) do
    actionable_count = accepted_review_claim_count(state)

    per_claim_extension =
      cond do
        retry_count >= 2 and review_fix_turn_window_active?(state) -> 110_000
        true -> 80_000
      end

    actionable_count
    |> Kernel.*(per_claim_extension)
    |> min(320_000)
  end

  defp review_fix_turn_window_active?(state) when is_map(state) do
    case get_in(state, [:resume_context, :implementation_turn_window_base]) do
      value when is_integer(value) and value >= 0 -> true
      _ -> false
    end
  end

  defp review_fix_retry_tracking_candidate?(state, stage) do
    stage == "implement" and accepted_review_claim_count(state) > 0
  end

  defp review_token_pressure_high?(%{resume_context: %{"token_pressure" => "high"}}), do: true
  defp review_token_pressure_high?(%{resume_context: %{token_pressure: "high"}}), do: true
  defp review_token_pressure_high?(_state), do: false

  defp review_fix_budget_retry_count(state, issue_identifier) when is_map(state) do
    context =
      state
      |> Map.get(:resume_context, %{})
      |> Enum.into(%{})

    case Map.get(context, :review_fix_budget_retry_count) ||
           Map.get(context, "review_fix_budget_retry_count") do
      count when is_integer(count) and count >= 0 -> count
      _ -> legacy_review_fix_retry_count(state, issue_identifier)
    end
  end

  defp maybe_put_review_fix_retry_count(resume_context, nil), do: resume_context

  defp maybe_put_review_fix_retry_count(resume_context, count) when is_map(resume_context) do
    Map.put(resume_context, :review_fix_budget_retry_count, count)
  end

  defp accepted_review_claim_count(state) when is_map(state) do
    state
    |> Map.get(:review_claims, %{})
    |> Enum.count(fn {_thread_key, claim} ->
      Map.get(claim, "disposition") == "accepted" and Map.get(claim, "actionable", false)
    end)
  end

  defp addressed_review_claim_count(state) when is_map(state) do
    state
    |> Map.get(:review_claims, %{})
    |> Enum.count(fn {_thread_key, claim} ->
      Map.get(claim, "implementation_status") == "addressed"
    end)
  end

  defp relaxed_budget_value(nil, fallback), do: fallback
  defp relaxed_budget_value(value, fallback) when is_integer(value), do: max(value, fallback)

  defp legacy_review_fix_retry_count(state, issue_identifier) do
    if prior_review_fix_budget_stop?(state, issue_identifier) do
      1
    else
      0
    end
  end

  defp prior_review_fix_budget_stop?(state, issue_identifier) do
    review_fix_budget_stop_reason?(state) or
      prior_review_fix_budget_stop_in_ledger?(issue_identifier)
  end

  defp review_fix_budget_stop_reason?(state) when is_map(state) do
    last_rule_id = Map.get(state, :last_rule_id) || Map.get(state, "last_rule_id")

    stop_reason =
      state
      |> Map.get(:stop_reason)
      |> mapish()

    resume_context =
      state
      |> Map.get(:resume_context)
      |> mapish()

    last_rule_id == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, :rule_id) == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, "rule_id") == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, :code) == "per_turn_input_budget_exceeded" or
      Map.get(stop_reason, "code") == "per_turn_input_budget_exceeded" or
      Map.get(resume_context, :last_blocking_rule) == "budget.per_turn_input_exceeded" or
      Map.get(resume_context, "last_blocking_rule") == "budget.per_turn_input_exceeded"
  end

  defp prior_review_fix_budget_stop_in_ledger?(issue_identifier)
       when is_binary(issue_identifier) do
    RunLedger.recent_entries(200)
    |> Enum.reverse()
    |> Enum.any?(fn entry ->
      Map.get(entry, "issue_identifier") == issue_identifier and
        Map.get(entry, "event") == "runtime.stopped" and
        Map.get(entry, "rule_id") == "budget.per_turn_input_exceeded"
    end)
  end

  defp prior_review_fix_budget_stop_in_ledger?(_issue_identifier), do: false

  defp issue_identifier_for(issue, state) do
    Map.get(issue, :identifier) ||
      Map.get(issue, "identifier") ||
      Map.get(state, :issue_identifier) ||
      Map.get(state, "issue_identifier")
  end

  defp mapish(value) when is_map(value), do: Enum.into(value, %{})
  defp mapish(_value), do: %{}

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

  defp normalize_repo_url(nil), do: nil

  defp normalize_repo_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing(".git")
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.replace_prefix("git@", "")
    |> String.replace(":", "/")
    |> String.downcase()
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
      target_state: Keyword.get(attrs, :target_state, @blocked_state),
      metadata: Keyword.get(attrs, :metadata, %{})
    }
  end
end
