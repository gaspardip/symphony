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

  @spec budget_runtime(map(), map()) :: map()
  def budget_runtime(issue, running_entry) do
    token_budget = Config.policy_token_budget()
    review_fix_budget = Config.policy_review_fix_token_budget()
    broad_implement_budget = Config.policy_broad_implement_token_budget()
    resume_context = normalize_resume_context(Map.get(running_entry, :resume_context, %{}))

    if review_fix_budget_mode?(running_entry, resume_context, review_fix_budget) do
      adaptive_budget = adaptive_review_fix_budget(review_fix_budget, resume_context)

      %{
        mode: "review_fix",
        pressure_level: Map.get(resume_context, :budget_pressure_level, "normal"),
        retry_count: review_fix_retry_count(resume_context),
        window_base_turn: Map.get(resume_context, :budget_window_base_turn),
        last_stop_code: Map.get(resume_context, :budget_last_stop_code),
        last_observed_input_tokens: Map.get(resume_context, :budget_last_observed_input_tokens),
        scope_kind: Map.get(resume_context, :budget_scope_kind),
        scope_ids: normalize_scope_ids(Map.get(resume_context, :budget_scope_ids)),
        auto_narrowed: truthy?(Map.get(resume_context, :budget_auto_narrowed)),
        total_extension_used: truthy?(Map.get(resume_context, :budget_total_extension_used)),
        per_turn_input_soft: adaptive_budget.per_turn_input_soft,
        per_turn_input_hard: adaptive_budget.per_turn_input_hard,
        max_turns_in_window: adaptive_budget.max_turns_in_window,
        per_issue_total_limit:
          effective_review_fix_total_budget(
            token_budget,
            review_fix_budget,
            resume_context
          ),
        per_issue_total_extension: review_fix_budget[:per_issue_total_extension]
      }
    else
      stage_budget = current_stage_token_budget(issue, running_entry)

      if broad_implement_budget_mode?(resume_context, broad_implement_budget) do
        %{
          mode: "broad_implement",
          pressure_level: Map.get(resume_context, :budget_pressure_level, "normal"),
          retry_count: broad_implement_retry_count(resume_context),
          window_base_turn: Map.get(resume_context, :budget_window_base_turn),
          last_stop_code: Map.get(resume_context, :budget_last_stop_code),
          last_observed_input_tokens: Map.get(resume_context, :budget_last_observed_input_tokens),
          scope_kind: nil,
          scope_ids: [],
          auto_narrowed: truthy?(Map.get(resume_context, :budget_auto_narrowed)),
          total_extension_used: false,
          per_turn_input_soft: stage_budget[:per_turn_input_soft],
          per_turn_input_hard: stage_budget[:per_turn_input_hard] || token_budget[:per_turn_input],
          max_turns_in_window: nil,
          per_issue_total_limit: token_budget[:per_issue_total],
          per_issue_total_extension: nil
        }
      else
        %{
          mode: "broad",
          pressure_level: if(Map.get(resume_context, :token_pressure) == "high", do: "high", else: "normal"),
          retry_count: 0,
          window_base_turn: nil,
          last_stop_code: nil,
          last_observed_input_tokens: nil,
          scope_kind: nil,
          scope_ids: [],
          auto_narrowed: false,
          total_extension_used: false,
          per_turn_input_soft: stage_budget[:per_turn_input_soft],
          per_turn_input_hard: stage_budget[:per_turn_input_hard] || token_budget[:per_turn_input],
          max_turns_in_window: nil,
          per_issue_total_limit: token_budget[:per_issue_total],
          per_issue_total_extension: nil
        }
      end
    end
  end

  @spec maybe_stop_for_token_budget(map(), map()) :: :ok | {:retry, map()} | {:stop, violation()}
  def maybe_stop_for_token_budget(issue, running_entry) do
    token_budget = Config.policy_token_budget()
    review_fix_budget = Config.policy_review_fix_token_budget()
    broad_implement_budget = Config.policy_broad_implement_token_budget()

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
    resume_context = normalize_resume_context(Map.get(running_entry, :resume_context, %{}))

    if review_fix_budget_mode?(running_entry, resume_context, review_fix_budget) do
      maybe_enforce_review_fix_token_budget(
        issue,
        running_entry,
        workspace,
        resume_context,
        review_fix_budget,
        token_budget,
        current_turn_input,
        total_tokens,
        output_total
      )
    else
      stage =
        Map.get(running_entry, :dispatch_stage) ||
          Map.get(running_entry, :stage) ||
          current_stage(issue, workspace, run_state)

      maybe_record_soft_budget_pressure(
        issue,
        running_entry,
        current_turn_input,
        stage_budget,
        workspace,
        run_state
      )

      case maybe_enforce_broad_implement_token_budget(
             issue,
             running_entry,
             workspace,
             resume_context,
             broad_implement_budget,
             stage,
             stage_budget,
             current_turn_input,
             run_state
           ) do
        :pass_through ->
          cond do
            budget_exceeded?(
              stage_budget[:per_turn_input_hard] || token_budget[:per_turn_input],
              current_turn_input
            ) ->
              stop_issue(issue, token_budget_violation(:per_turn_input, current_turn_input), workspace)

            budget_exceeded?(total_budget, total_tokens) ->
              stop_issue(issue, token_budget_violation(:per_issue_total, total_tokens), workspace)

            budget_exceeded?(token_budget[:per_issue_total_output], output_total) ->
              stop_issue(issue, token_budget_violation(:per_issue_total_output, output_total), workspace)

            true ->
              :ok
          end

        result ->
          result
      end
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
      persisted_resume_context = persisted_resume_context_from_violation(violation, workspace)

      _ =
        RunStateStore.transition(workspace, "blocked", %{
          resume_context: persisted_resume_context,
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

  defp persisted_resume_context_from_violation(%Violation{metadata: metadata}, workspace)
       when is_map(metadata) and is_binary(workspace) do
    case Map.get(metadata, :resume_context) || Map.get(metadata, "resume_context") do
      resume_context when is_map(resume_context) -> resume_context
      _ -> persisted_resume_context_from_workspace(workspace)
    end
  end

  defp persisted_resume_context_from_violation(_violation, workspace) when is_binary(workspace),
    do: persisted_resume_context_from_workspace(workspace)

  defp persisted_resume_context_from_workspace(workspace) when is_binary(workspace) do
    case RunStateStore.load(workspace) do
      {:ok, %{resume_context: resume_context}} when is_map(resume_context) -> resume_context
      _ -> %{}
    end
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

  defp review_fix_exhaustion_violation(:scope_exhausted, observed, metadata) do
    violation(:review_fix_scope_exhausted,
      summary: "Scoped review-fix retries exhausted the narrowest available scope.",
      details: "Observed per-turn input #{observed} with no smaller review-fix scope left to try.",
      metadata: metadata
    )
  end

  defp review_fix_exhaustion_violation(:turn_window_exhausted, observed, metadata) do
    violation(:review_fix_turn_window_exhausted,
      summary: "Scoped review-fix retries exhausted the configured turn window.",
      details: "Observed per-turn input #{observed} after consuming the adaptive review-fix retry window.",
      metadata: metadata
    )
  end

  defp review_fix_exhaustion_violation(:total_extension_exhausted, observed, metadata) do
    violation(:review_fix_total_extension_exhausted,
      summary: "Scoped review-fix retries exhausted the bounded total-budget extension.",
      details: "Observed total tokens #{observed} after consuming the review-fix total-budget extension.",
      metadata: metadata
    )
  end

  defp broad_implement_exhaustion_violation(observed, metadata) do
    violation(:broad_implement_scope_exhausted,
      summary: "Broad implement retries exhausted the narrow retry lane.",
      details: "Observed per-turn input #{observed} after Symphony retried with a narrower broad-implement context and no smaller safe retry remained.",
      metadata: metadata
    )
  end

  defp broad_implement_focus_insufficient_violation(observed, metadata, next_required_path) do
    details =
      case next_required_path do
        path when is_binary(path) and path != "" ->
          "Observed per-turn input #{observed} after a file-only retry. Symphony needs one additional exact path before it can continue: #{path}."

        _ ->
          "Observed per-turn input #{observed} after a file-only retry, but no exact next file was surfaced for a bounded expansion."
      end

    violation(:broad_implement_focus_insufficient,
      summary: "The file-only broad retry was too narrow to finish the work.",
      details: details,
      metadata: metadata
    )
  end

  defp broad_implement_expansion_exhaustion_violation(observed, metadata) do
    violation(:broad_implement_expansion_exhausted,
      summary: "The bounded broad-implement expansion retry was exhausted.",
      details: "Observed per-turn input #{observed} after Symphony retried with the focused file plus one explicit expansion path.",
      metadata: metadata
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

  defp review_fix_budget_mode?(running_entry, resume_context, review_fix_budget) do
    issue = Map.get(running_entry, :issue, %{})

    workspace =
      Map.get(running_entry, :workspace) ||
        Map.get(running_entry, :workspace_path) ||
        Workspace.path_for_issue(Map.get(issue, :identifier) || Map.get(issue, "identifier") || Map.get(running_entry, :identifier))

    run_state = if is_binary(workspace), do: RunStateStore.load_or_default(workspace, issue), else: %{}

    stage =
      Map.get(running_entry, :stage) ||
        Map.get(running_entry, :dispatch_stage) ||
        current_stage(issue, workspace, run_state)

    Map.get(review_fix_budget, :enabled, true) and
      stage == "implement" and
      Map.get(resume_context, :budget_mode) == "review_fix"
  end

  defp broad_implement_budget_candidate?(stage, broad_implement_budget, run_state)
       when is_binary(stage) and is_map(broad_implement_budget) and is_map(run_state) do
    resume_context = normalize_resume_context(Map.get(run_state, :resume_context, %{}))

    Map.get(broad_implement_budget, :enabled, true) and
      stage == "implement" and
      not review_fix_budget_candidate?(run_state, stage) and
      Map.get(resume_context, :budget_mode) != "review_fix" and
      Map.get(resume_context, :budget_scope_kind) not in ["review_claim_batch", "ci_failure_batch"] and
      is_nil(Map.get(run_state, :last_ci_failure))
  end

  defp broad_implement_budget_mode?(resume_context, broad_implement_budget)
       when is_map(resume_context) and is_map(broad_implement_budget) do
    Map.get(broad_implement_budget, :enabled, true) and
      Map.get(resume_context, :budget_mode) == "broad_implement"
  end

  defp broad_implement_budget_mode?(_resume_context, _broad_implement_budget), do: false

  defp maybe_enforce_review_fix_token_budget(
         issue,
         running_entry,
         workspace,
         resume_context,
         review_fix_budget,
         token_budget,
         current_turn_input,
         total_tokens,
         output_total
       ) do
    adaptive_budget = adaptive_review_fix_budget(review_fix_budget, resume_context)

    maybe_record_review_fix_budget_pressure(issue, running_entry, resume_context, current_turn_input, adaptive_budget)

    cond do
      budget_exceeded?(adaptive_budget.per_turn_input_hard, current_turn_input) ->
        handle_review_fix_turn_budget_stop(
          issue,
          running_entry,
          workspace,
          resume_context,
          review_fix_budget,
          current_turn_input,
          adaptive_budget
        )

      review_fix_total_budget_exceeded?(token_budget, review_fix_budget, resume_context, total_tokens) ->
        handle_review_fix_total_budget_stop(
          issue,
          running_entry,
          workspace,
          resume_context,
          review_fix_budget,
          token_budget,
          total_tokens
        )

      budget_exceeded?(token_budget[:per_issue_total_output], output_total) ->
        stop_issue(issue, token_budget_violation(:per_issue_total_output, output_total), workspace)

      true ->
        maybe_activate_review_fix_total_extension(
          issue,
          running_entry,
          workspace,
          resume_context,
          review_fix_budget,
          token_budget,
          total_tokens
        )
    end
  end

  defp adaptive_review_fix_budget(review_fix_budget, resume_context) do
    retry_count = review_fix_retry_count(resume_context)

    hard_budget =
      cond do
        retry_count >= 3 -> review_fix_budget[:retry_3_per_turn_input_hard] || review_fix_budget[:per_turn_input_hard]
        retry_count >= 2 -> review_fix_budget[:retry_2_per_turn_input_hard] || review_fix_budget[:per_turn_input_hard]
        true -> review_fix_budget[:per_turn_input_hard]
      end

    max_turns_in_window =
      cond do
        retry_count >= 3 -> review_fix_budget[:retry_3_max_turns_in_window] || review_fix_budget[:max_turns_in_window]
        retry_count >= 2 -> review_fix_budget[:retry_2_max_turns_in_window] || review_fix_budget[:max_turns_in_window]
        true -> review_fix_budget[:max_turns_in_window]
      end

    %{
      per_turn_input_soft: review_fix_budget[:per_turn_input_soft],
      per_turn_input_hard: hard_budget,
      max_turns_in_window: max_turns_in_window,
      narrow_scope_batch_size: review_fix_budget[:narrow_scope_batch_size] || 1,
      auto_retry_limit: review_fix_budget[:auto_retry_limit] || 0
    }
  end

  defp review_fix_total_budget_exceeded?(token_budget, review_fix_budget, resume_context, total_tokens) do
    budget_exceeded?(effective_review_fix_total_budget(token_budget, review_fix_budget, resume_context), total_tokens)
  end

  defp maybe_activate_review_fix_total_extension(
         issue,
         running_entry,
         workspace,
         resume_context,
         review_fix_budget,
         token_budget,
         total_tokens
       ) do
    base_budget = token_budget[:per_issue_total]
    extension_budget = review_fix_budget[:per_issue_total_extension]

    cond do
      not is_integer(base_budget) ->
        :ok

      not is_integer(extension_budget) ->
        :ok

      total_tokens <= base_budget ->
        :ok

      truthy?(Map.get(resume_context, :budget_total_extension_used)) ->
        :ok

      not review_fix_total_extension_eligible?(resume_context, extension_budget) ->
        stop_issue(issue, token_budget_violation(:per_issue_total, total_tokens), workspace)

      true ->
        persisted_resume_context =
          review_fix_resume_context_for_budget_retry(
            resume_context,
            running_entry,
            "budget.review_fix_total_extension_activated",
            total_tokens,
            %{
              budget_total_extension_used: true,
              budget_pressure_level: "critical"
            }
          )

        persist_resume_context(issue, running_entry, persisted_resume_context)
        :ok
    end
  end

  defp maybe_enforce_broad_implement_token_budget(
         issue,
         running_entry,
         workspace,
         resume_context,
         broad_implement_budget,
         stage,
         stage_budget,
         current_turn_input,
         run_state
       ) do
    hard_budget = stage_budget[:per_turn_input_hard] || Config.policy_per_turn_input_budget()

    cond do
      not broad_implement_workspace_candidate?(running_entry) ->
        :pass_through

      not broad_implement_budget_candidate?(stage, broad_implement_budget, run_state) ->
        :pass_through

      not budget_exceeded?(hard_budget, current_turn_input) ->
        :pass_through

      true ->
        handle_broad_implement_turn_budget_stop(
          issue,
          running_entry,
          workspace,
          resume_context,
          broad_implement_budget,
          current_turn_input
        )
    end
  end

  defp broad_implement_workspace_candidate?(running_entry) when is_map(running_entry) do
    is_binary(Map.get(running_entry, :workspace) || Map.get(running_entry, :workspace_path))
  end

  defp broad_implement_workspace_candidate?(_running_entry), do: false

  defp handle_broad_implement_turn_budget_stop(
         issue,
         running_entry,
         workspace,
         resume_context,
         broad_implement_budget,
         current_turn_input
       ) do
    retry_count = broad_implement_retry_count(resume_context)
    can_retry? = retry_count < (broad_implement_budget[:auto_retry_limit] || 0)

    primary_target_path = broad_implement_primary_target_path(running_entry, resume_context)
    expansion_used? = truthy?(Map.get(resume_context, :budget_expansion_used))
    next_required_path = broad_implement_next_required_path(running_entry, resume_context, primary_target_path)

    cond do
      retry_count == 0 and can_retry? and is_binary(primary_target_path) ->
        persisted_resume_context =
          broad_implement_resume_context_for_budget_retry(
            resume_context,
            running_entry,
            "budget.per_turn_input_exceeded",
            current_turn_input,
            %{
              budget_retry_count: retry_count + 1,
              budget_pressure_level: broad_implement_pressure_level_for_retry(retry_count + 1),
              budget_auto_narrowed: true,
              target_paths: [primary_target_path],
              next_required_path: nil,
              budget_expansion_used: false
            }
          )

        persist_resume_context(issue, running_entry, persisted_resume_context)

        {:retry,
         %{
           kind: :broad_implement_budget_retry,
           summary: "Adaptive broad-implement retry scheduled with one focused file.",
           budget_mode: "broad_implement",
           resume_context: persisted_resume_context,
           observed_input_tokens: current_turn_input,
           retry_count: retry_count + 1
         }}

      retry_count >= 1 and can_retry? and not expansion_used? and is_binary(primary_target_path) and
          is_binary(next_required_path) ->
        persisted_resume_context =
          broad_implement_resume_context_for_budget_retry(
            resume_context,
            running_entry,
            "budget.per_turn_input_exceeded",
            current_turn_input,
            %{
              budget_retry_count: retry_count + 1,
              budget_pressure_level: broad_implement_pressure_level_for_retry(retry_count + 1),
              budget_auto_narrowed: true,
              target_paths: [primary_target_path, next_required_path],
              next_required_path: next_required_path,
              budget_expansion_used: true
            }
          )

        persist_resume_context(issue, running_entry, persisted_resume_context)

        {:retry,
         %{
           kind: :broad_implement_budget_expansion_retry,
           summary: "Adaptive broad-implement retry scheduled with one explicit expansion file.",
           budget_mode: "broad_implement",
           resume_context: persisted_resume_context,
           observed_input_tokens: current_turn_input,
           retry_count: retry_count + 1
         }}

      retry_count >= 1 and not expansion_used? and is_binary(primary_target_path) ->
        persisted_resume_context =
          broad_implement_resume_context_for_budget_retry(
            resume_context,
            running_entry,
            "budget.broad_implement_focus_insufficient",
            current_turn_input,
            %{
              budget_pressure_level: "critical",
              target_paths: [primary_target_path],
              next_required_path: next_required_path,
              budget_expansion_used: false
            }
          )

        persist_resume_context(issue, running_entry, persisted_resume_context)

        metadata =
          broad_implement_budget_metadata(running_entry, persisted_resume_context)
          |> Map.put(:resume_context, persisted_resume_context)

        stop_issue(
          issue,
          broad_implement_focus_insufficient_violation(
            current_turn_input,
            metadata,
            next_required_path
          ),
          workspace
        )

      expansion_used? ->
        persisted_resume_context =
          broad_implement_resume_context_for_budget_retry(
            resume_context,
            running_entry,
            "budget.broad_implement_expansion_exhausted",
            current_turn_input,
            %{
              budget_pressure_level: "critical",
              next_required_path: next_required_path
            }
          )

        persist_resume_context(issue, running_entry, persisted_resume_context)

        metadata =
          broad_implement_budget_metadata(running_entry, persisted_resume_context)
          |> Map.put(:resume_context, persisted_resume_context)

        stop_issue(
          issue,
          broad_implement_expansion_exhaustion_violation(current_turn_input, metadata),
          workspace
        )

      true ->
        persisted_resume_context =
          broad_implement_resume_context_for_budget_retry(
            resume_context,
            running_entry,
            "budget.broad_implement_scope_exhausted",
            current_turn_input,
            %{budget_pressure_level: "critical"}
          )

        persist_resume_context(issue, running_entry, persisted_resume_context)

        metadata =
          broad_implement_budget_metadata(running_entry, persisted_resume_context)
          |> Map.put(:resume_context, persisted_resume_context)

        stop_issue(issue, broad_implement_exhaustion_violation(current_turn_input, metadata), workspace)
    end
  end

  defp review_fix_total_extension_eligible?(resume_context, extension_budget) do
    is_integer(extension_budget) and review_fix_progress_count(resume_context) >= 1
  end

  defp effective_review_fix_total_budget(token_budget, review_fix_budget, resume_context) do
    base_budget = token_budget[:per_issue_total]
    extension_budget = review_fix_budget[:per_issue_total_extension]
    extension_eligible? = review_fix_total_extension_eligible?(resume_context, extension_budget)

    extension_used_or_eligible? =
      truthy?(Map.get(resume_context, :budget_total_extension_used)) or extension_eligible?

    cond do
      not is_integer(base_budget) -> nil
      extension_used_or_eligible? and is_integer(extension_budget) -> base_budget + extension_budget
      true -> base_budget
    end
  end

  defp handle_review_fix_total_budget_stop(
         issue,
         running_entry,
         workspace,
         resume_context,
         review_fix_budget,
         token_budget,
         total_tokens
       ) do
    base_budget = token_budget[:per_issue_total]
    extension_budget = review_fix_budget[:per_issue_total_extension]

    if truthy?(Map.get(resume_context, :budget_total_extension_used)) and is_integer(base_budget) and is_integer(extension_budget) do
      metadata =
        review_fix_budget_metadata(
          running_entry,
          resume_context,
          %{base_budget: base_budget, extension_budget: extension_budget}
        )

      persisted_resume_context =
        review_fix_resume_context_for_budget_retry(
          resume_context,
          running_entry,
          "budget.review_fix_total_extension_exhausted",
          total_tokens,
          %{budget_pressure_level: "critical"}
        )

      persist_resume_context(issue, running_entry, persisted_resume_context)
      stop_issue(issue, review_fix_exhaustion_violation(:total_extension_exhausted, total_tokens, metadata), workspace)
    else
      stop_issue(issue, token_budget_violation(:per_issue_total, total_tokens), workspace)
    end
  end

  defp handle_review_fix_turn_budget_stop(
         issue,
         running_entry,
         workspace,
         resume_context,
         review_fix_budget,
         current_turn_input,
         adaptive_budget
       ) do
    retry_count = review_fix_retry_count(resume_context)
    can_retry? = retry_count < (review_fix_budget[:auto_retry_limit] || 0)
    turns_in_window = review_fix_turns_in_window(running_entry, resume_context)
    current_scope_ids = normalize_scope_ids(Map.get(resume_context, :budget_scope_ids))
    narrowed_scope_ids = narrow_review_fix_scope_ids(resume_context, adaptive_budget.narrow_scope_batch_size)
    can_narrow_scope? = narrowed_scope_ids != current_scope_ids

    persisted_resume_context =
      review_fix_resume_context_for_budget_retry(
        resume_context,
        running_entry,
        "budget.per_turn_input_exceeded",
        current_turn_input,
        %{
          budget_retry_count: retry_count + 1,
          budget_pressure_level: review_fix_pressure_level_for_retry(retry_count + 1),
          budget_scope_ids: narrowed_scope_ids,
          budget_auto_narrowed: narrowed_scope_ids != current_scope_ids
        }
      )

    persist_resume_context(issue, running_entry, persisted_resume_context)

    cond do
      can_retry? and turns_in_window < adaptive_budget.max_turns_in_window and
          review_fix_retry_continues?(retry_count, can_narrow_scope?) ->
        {:retry,
         %{
           kind: :review_fix_budget_retry,
           summary: "Adaptive review-fix retry scheduled after token budget pressure.",
           resume_context: persisted_resume_context,
           observed_input_tokens: current_turn_input,
           retry_count: retry_count + 1,
           max_turns_in_window: adaptive_budget.max_turns_in_window
         }}

      turns_in_window >= adaptive_budget.max_turns_in_window ->
        metadata = review_fix_budget_metadata(running_entry, persisted_resume_context, %{turns_in_window: turns_in_window})
        stop_issue(issue, review_fix_exhaustion_violation(:turn_window_exhausted, current_turn_input, metadata), workspace)

      true ->
        metadata = review_fix_budget_metadata(running_entry, persisted_resume_context, %{})
        stop_issue(issue, review_fix_exhaustion_violation(:scope_exhausted, current_turn_input, metadata), workspace)
    end
  end

  defp review_fix_retry_continues?(retry_count, _can_narrow_scope?) when retry_count < 3, do: true
  defp review_fix_retry_continues?(_retry_count, can_narrow_scope?), do: can_narrow_scope?

  defp maybe_record_review_fix_budget_pressure(
         issue,
         running_entry,
         resume_context,
         current_turn_input,
         adaptive_budget
       ) do
    soft_budget = adaptive_budget.per_turn_input_soft

    if budget_exceeded?(soft_budget, current_turn_input) and Map.get(resume_context, :budget_pressure_level, "normal") == "normal" do
      persisted_resume_context =
        review_fix_resume_context_for_budget_retry(
          resume_context,
          running_entry,
          "budget.review_fix_soft_pressure",
          current_turn_input,
          %{
            budget_pressure_level: "soft",
            token_pressure: "high"
          }
        )

      persist_resume_context(issue, running_entry, persisted_resume_context)

      _ =
        RunLedger.record("policy.decided", %{
          issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
          issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
          actor_type: "runtime",
          actor_id: "run_policy",
          summary: "Scoped review-fix turn entered soft token pressure.",
          details: "Observed input tokens #{current_turn_input} above scoped soft budget #{soft_budget}.",
          metadata: %{
            stage: Map.get(running_entry, :stage),
            observed: current_turn_input,
            soft_budget: soft_budget,
            budget_mode: "review_fix"
          }
        })

      :ok
    else
      :ok
    end
  end

  defp persist_resume_context(issue, running_entry, resume_context) do
    workspace = workspace_for_issue(issue, running_entry)

    if is_binary(workspace) do
      stage = Map.get(running_entry, :stage) || current_stage(issue, workspace, nil) || "implement"

      _ =
        RunStateStore.transition(workspace, stage, %{
          resume_context: resume_context
        })
    end

    :ok
  end

  defp workspace_for_issue(issue, running_entry) do
    Map.get(running_entry, :workspace) ||
      Workspace.path_for_issue(Map.get(issue, :identifier) || Map.get(issue, "identifier"))
  end

  defp current_stage_token_budget(issue, running_entry) do
    workspace = workspace_for_issue(issue, running_entry)
    run_state = if is_binary(workspace), do: RunStateStore.load_or_default(workspace, issue), else: %{}
    current_stage_token_budget(issue, running_entry, workspace, run_state)
  end

  defp normalize_resume_context(context) when is_map(context) do
    context
    |> Enum.into(%{}, fn
      {key, value} when is_binary(key) ->
        case review_fix_resume_context_key(key) do
          nil -> {key, value}
          atom_key -> {atom_key, value}
        end

      {key, value} ->
        {key, value}
    end)
  end

  defp normalize_resume_context(_context), do: %{}

  defp review_fix_resume_context_key("budget_mode"), do: :budget_mode
  defp review_fix_resume_context_key("budget_pressure_level"), do: :budget_pressure_level
  defp review_fix_resume_context_key("budget_retry_count"), do: :budget_retry_count
  defp review_fix_resume_context_key("budget_window_base_turn"), do: :budget_window_base_turn
  defp review_fix_resume_context_key("budget_last_stop_code"), do: :budget_last_stop_code
  defp review_fix_resume_context_key("budget_last_observed_input_tokens"), do: :budget_last_observed_input_tokens
  defp review_fix_resume_context_key("budget_scope_kind"), do: :budget_scope_kind
  defp review_fix_resume_context_key("budget_scope_ids"), do: :budget_scope_ids
  defp review_fix_resume_context_key("budget_progress_count"), do: :budget_progress_count
  defp review_fix_resume_context_key("budget_total_extension_used"), do: :budget_total_extension_used
  defp review_fix_resume_context_key("budget_auto_narrowed"), do: :budget_auto_narrowed
  defp review_fix_resume_context_key("target_paths"), do: :target_paths
  defp review_fix_resume_context_key("already_learned"), do: :already_learned
  defp review_fix_resume_context_key("next_required_path"), do: :next_required_path
  defp review_fix_resume_context_key("budget_expansion_used"), do: :budget_expansion_used
  defp review_fix_resume_context_key("token_pressure"), do: :token_pressure
  defp review_fix_resume_context_key(_key), do: nil

  defp review_fix_resume_context_for_budget_retry(resume_context, running_entry, stop_code, observed_tokens, overrides) do
    default_scope_kind = Map.get(resume_context, :budget_scope_kind) || "review_claim_batch"
    turn_count = Map.get(running_entry, :turn_count, 0)

    resume_context
    |> Map.put_new(:budget_mode, "review_fix")
    |> Map.put_new(:budget_pressure_level, "normal")
    |> Map.put_new(:budget_retry_count, 0)
    |> Map.put_new(:budget_window_base_turn, turn_count)
    |> Map.put_new(:budget_scope_kind, default_scope_kind)
    |> Map.put_new(:budget_scope_ids, normalize_scope_ids(Map.get(resume_context, :budget_scope_ids)))
    |> Map.put(:budget_last_stop_code, stop_code)
    |> Map.put(:budget_last_observed_input_tokens, observed_tokens)
    |> Map.put(:token_pressure, "high")
    |> Map.merge(Enum.into(overrides, %{}))
  end

  defp review_fix_retry_count(resume_context) do
    case Map.get(resume_context, :budget_retry_count, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp review_fix_turns_in_window(running_entry, resume_context) do
    turn_count = Map.get(running_entry, :turn_count, 0)
    base_turn = Map.get(resume_context, :budget_window_base_turn, turn_count)
    max(turn_count - base_turn + 1, 1)
  end

  defp review_fix_progress_count(resume_context) do
    case Map.get(resume_context, :budget_progress_count, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp review_fix_pressure_level_for_retry(retry_count) when retry_count >= 3, do: "critical"
  defp review_fix_pressure_level_for_retry(retry_count) when retry_count >= 2, do: "high"
  defp review_fix_pressure_level_for_retry(_retry_count), do: "soft"

  defp review_fix_budget_metadata(running_entry, resume_context, extras) do
    %{
      stage: Map.get(running_entry, :stage),
      retry_count: review_fix_retry_count(resume_context),
      pressure_level: Map.get(resume_context, :budget_pressure_level),
      scope_kind: Map.get(resume_context, :budget_scope_kind),
      scope_ids: normalize_scope_ids(Map.get(resume_context, :budget_scope_ids)),
      total_extension_used: truthy?(Map.get(resume_context, :budget_total_extension_used))
    }
    |> Map.merge(extras)
  end

  defp broad_implement_resume_context_for_budget_retry(
         resume_context,
         running_entry,
         stop_code,
         observed_tokens,
         overrides
       ) do
    turn_count = Map.get(running_entry, :turn_count, 0)
    override_map = Enum.into(overrides, %{})
    target_paths = Map.get(override_map, :target_paths, broad_implement_target_paths(running_entry, resume_context))
    already_learned = broad_implement_already_learned(running_entry, resume_context, target_paths)

    resume_context
    |> Map.put(:budget_mode, "broad_implement")
    |> Map.put_new(:budget_pressure_level, "normal")
    |> Map.put_new(:budget_retry_count, 0)
    |> Map.put_new(:budget_window_base_turn, turn_count)
    |> Map.put(:budget_last_stop_code, stop_code)
    |> Map.put(:budget_last_observed_input_tokens, observed_tokens)
    |> maybe_put_broad_retry_target_paths(target_paths)
    |> maybe_put_broad_retry_learned(already_learned)
    |> maybe_put_broad_retry_next_required_path(Map.get(override_map, :next_required_path))
    |> Map.put(:token_pressure, "high")
    |> Map.merge(override_map)
  end

  defp broad_implement_retry_count(resume_context) do
    case Map.get(resume_context, :budget_retry_count, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp broad_implement_pressure_level_for_retry(retry_count) when retry_count >= 1,
    do: "high"

  defp broad_implement_pressure_level_for_retry(_retry_count), do: "normal"

  defp broad_implement_budget_metadata(running_entry, resume_context) do
    %{
      stage: Map.get(running_entry, :stage),
      retry_count: broad_implement_retry_count(resume_context),
      pressure_level: Map.get(resume_context, :budget_pressure_level),
      auto_narrowed: truthy?(Map.get(resume_context, :budget_auto_narrowed)),
      target_paths: Map.get(resume_context, :target_paths, []),
      next_required_path: Map.get(resume_context, :next_required_path),
      expansion_used: truthy?(Map.get(resume_context, :budget_expansion_used))
    }
  end

  defp broad_implement_primary_target_path(running_entry, resume_context)
       when is_map(running_entry) and is_map(resume_context) do
    resume_context
    |> Map.get(:target_paths, [])
    |> normalize_candidate_paths()
    |> case do
      [path | _rest] ->
        path

      [] ->
        running_entry
        |> broad_implement_candidate_paths(resume_context)
        |> List.first()
    end
  end

  defp broad_implement_primary_target_path(_running_entry, _resume_context), do: nil

  defp broad_implement_next_required_path(running_entry, resume_context, primary_target_path)
       when is_map(running_entry) and is_map(resume_context) and is_binary(primary_target_path) do
    existing =
      case Map.get(resume_context, :next_required_path) do
        path when is_binary(path) and path != "" and path != primary_target_path -> path
        _ -> nil
      end

    existing ||
      running_entry
      |> broad_implement_candidate_paths(resume_context)
      |> Enum.reject(&(&1 == primary_target_path))
      |> List.first()
  end

  defp broad_implement_next_required_path(_running_entry, _resume_context, _primary_target_path), do: nil

  defp broad_implement_candidate_paths(running_entry, resume_context)
       when is_map(running_entry) and is_map(resume_context) do
    existing_paths =
      resume_context
      |> Map.get(:target_paths, [])
      |> normalize_candidate_paths()

    dirty_paths =
      running_entry
      |> broad_implement_workspace_paths()
      |> Enum.take(6)

    summary_paths =
      [
        Map.get(resume_context, :last_turn_summary),
        Map.get(resume_context, :next_objective),
        Map.get(running_entry, :last_codex_message),
        Map.get(running_entry, :recent_codex_updates, [])
      ]
      |> Enum.flat_map(&extract_candidate_paths/1)

    existing_paths
    |> Kernel.++(dirty_paths)
    |> Kernel.++(summary_paths)
    |> normalize_candidate_paths()
    |> Enum.take(4)
  end

  defp broad_implement_candidate_paths(_running_entry, _resume_context), do: []

  defp broad_implement_target_paths(running_entry, resume_context)
       when is_map(running_entry) and is_map(resume_context) do
    broad_implement_candidate_paths(running_entry, resume_context)
  end

  defp broad_implement_target_paths(_running_entry, _resume_context), do: []

  defp broad_implement_workspace_paths(running_entry) when is_map(running_entry) do
    workspace =
      Map.get(running_entry, :workspace) ||
        Map.get(running_entry, :workspace_path)

    if is_binary(workspace) do
      workspace
      |> RunInspector.changed_paths()
      |> normalize_candidate_paths()
    else
      []
    end
  end

  defp broad_implement_workspace_paths(_running_entry), do: []

  defp broad_implement_already_learned(running_entry, resume_context, target_paths)
       when is_map(running_entry) and is_map(resume_context) do
    existing =
      case Map.get(resume_context, :already_learned) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    summary =
      [
        Map.get(resume_context, :last_turn_summary),
        Map.get(running_entry, :last_codex_message),
        Map.get(running_entry, :recent_codex_updates, [])
      ]
      |> Enum.map(&summarizable_text/1)
      |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))

    cond do
      target_paths != [] ->
        "Stay inside #{Enum.join(target_paths, ", ")} and avoid unrelated reads or repo-wide rediscovery."

      is_binary(existing) ->
        existing

      is_binary(summary) ->
        summarized_text(summary, 220)

      true ->
        nil
    end
  end

  defp broad_implement_already_learned(_running_entry, _resume_context, _target_paths), do: nil

  defp maybe_put_broad_retry_target_paths(resume_context, []), do: resume_context
  defp maybe_put_broad_retry_target_paths(resume_context, target_paths), do: Map.put(resume_context, :target_paths, target_paths)

  defp maybe_put_broad_retry_learned(resume_context, nil), do: resume_context
  defp maybe_put_broad_retry_learned(resume_context, text), do: Map.put(resume_context, :already_learned, text)

  defp maybe_put_broad_retry_next_required_path(resume_context, nil), do: Map.delete(resume_context, :next_required_path)

  defp maybe_put_broad_retry_next_required_path(resume_context, path),
    do: Map.put(resume_context, :next_required_path, path)

  defp normalize_candidate_paths(paths) when is_list(paths) do
    normalized =
      paths
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    full_path_basenames =
      normalized
      |> Enum.filter(&String.contains?(&1, "/"))
      |> Enum.map(&Path.basename/1)
      |> MapSet.new()

    normalized
    |> Enum.reject(fn path ->
      not String.contains?(path, "/") and MapSet.member?(full_path_basenames, path)
    end)
  end

  defp normalize_candidate_paths(_paths), do: []

  defp extract_candidate_paths(nil), do: []

  defp extract_candidate_paths(text) when is_binary(text) do
    Regex.scan(~r{(?:^|[\s`'"])((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:ex|exs|md|yaml|yml|json|sh))(?=$|[\s`'".,;:])}, text, capture: :all_but_first)
    |> List.flatten()
    |> normalize_candidate_paths()
  end

  defp extract_candidate_paths(value) when is_map(value) or is_list(value) do
    value
    |> extract_text_fragments()
    |> Enum.flat_map(&extract_candidate_paths/1)
    |> normalize_candidate_paths()
  end

  defp extract_candidate_paths(_text), do: []

  defp narrow_review_fix_scope_ids(resume_context, batch_size) do
    resume_context
    |> Map.get(:budget_scope_ids, [])
    |> normalize_scope_ids()
    |> Enum.take(max(batch_size || 1, 1))
  end

  defp normalize_scope_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_scope_ids(_ids), do: []

  defp truthy?(value), do: value in [true, "true", 1, "1"]

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

  defp current_stage(%{state: issue_state}, _workspace, run_state) when is_binary(issue_state) and is_map(run_state) do
    Map.get(run_state, :stage) || fallback_stage_from_issue_state(issue_state)
  end

  defp current_stage(_issue, _workspace, _run_state), do: nil

  defp current_stage(issue, workspace) when is_binary(workspace) do
    case RunStateStore.load_or_default(workspace, issue) do
      %{stage: stage} when is_binary(stage) -> stage
      _ -> nil
    end
  end

  defp fallback_stage_from_issue_state(issue_state) when is_binary(issue_state) do
    case String.downcase(String.trim(issue_state)) do
      "todo" -> "checkout"
      "in progress" -> "implement"
      "review" -> "review"
      "merging" -> "await_checks"
      "done" -> "done"
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

  defp summarized_text(nil, _limit), do: nil

  defp summarized_text(value, limit) when is_integer(limit) and limit > 0 do
    value
    |> summarizable_text()
    |> case do
      nil ->
        nil

      text ->
        text
        |> String.trim()
        |> case do
          "" ->
            nil

          trimmed ->
            if String.length(trimmed) <= limit do
              trimmed
            else
              String.slice(trimmed, 0, max(limit - 3, 0)) <> "..."
            end
        end
    end
  end

  defp summarizable_text(nil), do: nil

  defp summarizable_text(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      text ->
        text
    end
  end

  defp summarizable_text(value) when is_list(value) or is_map(value) do
    value
    |> extract_text_fragments()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp summarizable_text(value), do: to_string(value)

  defp extract_text_fragments(value) when is_binary(value), do: [value]

  defp extract_text_fragments(value) when is_list(value) do
    Enum.flat_map(value, &extract_text_fragments/1)
  end

  defp extract_text_fragments(value) when is_map(value) do
    preferred =
      [:text, "text", :message, "message", :payload, "payload", :raw, "raw", :content, "content"]
      |> Enum.flat_map(fn key ->
        case Map.fetch(value, key) do
          {:ok, nested} -> extract_text_fragments(nested)
          :error -> []
        end
      end)

    if preferred != [] do
      preferred
    else
      value
      |> Map.values()
      |> Enum.flat_map(&extract_text_fragments/1)
    end
  end

  defp extract_text_fragments(_value), do: []

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
