defmodule SymphonyElixir.RunPolicy do
  @moduledoc """
  Enforces hard runtime rules around checkout, validation, PR readiness, and noop turns.
  """

  # credo:disable-for-this-file

  require Logger

  alias SymphonyElixir.{
    AgentExecution,
    Config,
    IssueSource,
    RepoCompatibility,
    RetryBudget,
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

  @spec enforce_pre_run(map(), Path.t(), keyword()) :: :ok | {:stop, violation()} | AgentExecution.terminal()
  def enforce_pre_run(issue, workspace, opts \\ []) do
    with {:ok, _entry} <- AgentExecution.entry_context(workspace, issue) do
      do_enforce_pre_run(issue, workspace, opts)
    end
  end

  defp do_enforce_pre_run(issue, workspace, opts) do
    inspection = RunInspector.inspect(workspace, opts)

    cond do
      RunnerRuntime.overlaps_protected_path?(workspace) ->
        stop_issue(issue, runner_overlap_violation(workspace), workspace)

      Config.policy_require_checkout?() and not inspection.git? ->
        stop_issue(issue, missing_checkout_violation(workspace), workspace)

      Config.policy_require_validation?() and inspection.harness_error not in [nil, :missing] ->
        stop_harness_error(issue, workspace, inspection.harness_error, opts)

      Config.policy_require_validation?() and is_nil(inspection.harness) ->
        stop_issue(issue, missing_harness_violation(workspace), workspace)

      repo_boundary_mismatch?(inspection.origin_url) ->
        stop_issue(issue, repo_boundary_mismatch_violation(inspection.origin_url), workspace)

      true ->
        case workload_violation(issue) do
          nil ->
            with {:ok, _entry} <- AgentExecution.entry_context(workspace, issue) do
              case RepoCompatibility.compatible?(workspace, opts) do
                {:ok, true, _report} ->
                  run_preflight_or_promote(issue, workspace, inspection, opts)

                {:ok, false, report} ->
                  stop_issue(issue, repo_not_compatible_violation(report), workspace)
              end
            end

          %Violation{} = violation ->
            stop_issue(issue, violation, workspace)
        end
    end
  end

  defp run_preflight_or_promote(issue, workspace, inspection, opts) do
    with {:ok, result, ledger} <- run_policy_gate(issue, workspace, inspection.harness, :preflight, opts) do
      case result.status do
        status when status in [:failed, :unavailable] ->
          stop_gate_issue(issue, with_gate(preflight_failed_violation(result.output), result), workspace, ledger)

        :passed ->
          promote_todo_issue(issue, workspace)
      end
    end
  end

  defp stop_harness_error(issue, workspace, {:missing_harness_command, kind} = reason, opts)
       when kind in ["preflight", "validation", "smoke", "artifacts"] do
    gate =
      case kind do
        "preflight" -> :preflight
        "validation" -> :validation
        "smoke" -> :smoke
        "artifacts" -> :artifacts
      end

    with {:ok, result, ledger} <- run_policy_gate(issue, workspace, nil, gate, opts) do
      stop_gate_issue(issue, with_gate(harness_validation_violation(workspace, reason), result), workspace, ledger)
    end
  end

  defp stop_harness_error(issue, workspace, reason, _opts),
    do: stop_issue(issue, harness_validation_violation(workspace, reason), workspace)

  defp run_policy_gate(issue, workspace, harness, kind, opts) do
    with {:ok, context} <- AgentExecution.entry_context(workspace, issue) do
      ledger = capture_gate_ledger(context)

      result =
        case kind do
          :preflight -> RunInspector.run_preflight(workspace, harness, opts)
          :validation -> RunInspector.run_validation(workspace, harness, opts)
          :smoke -> RunInspector.run_smoke(workspace, harness, opts)
          :artifacts -> RunInspector.run_artifacts(workspace, harness, opts)
        end

      with {:ok, _current} <- AgentExecution.entry_context(workspace, issue) do
        record_gate_event!(ledger, "#{kind}.completed", %{
          issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
          issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
          actor_type: "runtime",
          actor_id: "run_policy",
          stage: to_string(kind),
          summary: "#{kind} #{result.status}",
          metadata: %{workspace: workspace, gate_id: result.gate_id, gate: gate_result(result)}
        })

        {:ok, result, ledger}
      end
    end
  end

  defp with_gate(violation, result),
    do: %{violation | metadata: Map.merge(violation.metadata, %{gate_id: result.gate_id, gate: gate_result(result)})}

  defp gate_result(result) do
    result
    |> Map.take([:status, :command, :exit_code, :gate_id, :gate_kind, :started_at, :finished_at, :duration_us, :environment])
    |> Map.put(:output, String.slice(to_string(result.output || ""), 0, 2_000))
  end

  defp stop_gate_issue(issue, violation, workspace, ledger) do
    case AgentExecution.entry_context(workspace, issue) do
      {:ok, :legacy} -> stop_issue_legacy(issue, violation, workspace, ledger)
      {:ok, _context} -> stop_issue_worker(issue, violation, ledger)
      {:stop, _} = terminal -> terminal
    end
  end

  defp stop_after_turn_gate(issue, violation, workspace, ledger) do
    case AgentExecution.entry_context(workspace, issue) do
      {:ok, :legacy} -> stop_issue_legacy(issue, violation, nil, ledger)
      {:ok, _context} -> stop_issue_worker(issue, violation, ledger)
      {:stop, _} = terminal -> terminal
    end
  end

  defp capture_gate_ledger(:legacy) do
    case RunLedger.ledger_file_path_checked() do
      {:ok, path} -> %{ledger_path: path}
      {:error, error} -> raise error
    end
  end

  defp capture_gate_ledger(%{ticket: ticket}),
    do: %{ledger_path: ticket.ledger_path, run_id: ticket.run_id, dispatch_id: ticket.dispatch_id}

  defp record_gate_event!(ledger, type, attrs) do
    attrs = if Map.has_key?(ledger, :run_id), do: Map.put(attrs, :run_id, ledger.run_id), else: attrs
    attrs = if Map.has_key?(ledger, :dispatch_id), do: Map.update(attrs, :metadata, %{dispatch_id: ledger.dispatch_id}, &Map.put(&1, :dispatch_id, ledger.dispatch_id)), else: attrs

    with {:ok, prepared} <- RunLedger.prepare_entry(type, attrs),
         {:ok, event} <- RunLedger.CheckedStorage.persist(prepared, ledger.ledger_path) do
      event
    else
      {:error, error} -> raise error
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
          {:ok, non_neg_integer()} | {:stop, violation()} | AgentExecution.terminal()
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
        with {:ok, result, ledger} <- run_policy_gate(issue, after_snapshot.workspace, after_snapshot.harness, :validation, opts) do
          case result.status do
            :passed -> evaluate_noop(issue, before_snapshot, after_snapshot, noop_turns)
            :failed -> stop_after_turn_gate(issue, with_gate(validation_failed_violation(result.output), result), after_snapshot.workspace, ledger)
            :unavailable -> stop_after_turn_gate(issue, with_gate(validation_unavailable_violation(result.output), result), after_snapshot.workspace, ledger)
          end
        end

      true ->
        evaluate_noop(issue, before_snapshot, after_snapshot, noop_turns)
    end
  end

  @spec budget_runtime(map(), map()) :: map()
  def budget_runtime(issue, running_entry) do
    token_budget = Config.policy_token_budget()
    review_fix_budget = Config.policy_review_fix_token_budget()
    broad_budget = Config.policy_broad_implement_token_budget()
    workspace = workspace_for_issue(issue, running_entry)
    state = RunStateStore.load_or_default(workspace, issue)

    issue
    |> budget_observation(running_entry, state, workspace, :legacy, token_budget, review_fix_budget, broad_budget, nil)
    |> RetryBudget.runtime()
  end

  @spec issue_token_usage(map()) :: map()
  def issue_token_usage(running_entry) do
    base = Map.get(running_entry, :issue_token_usage_base, %{})

    Map.new(
      [input_tokens: :agent_input_tokens, output_tokens: :agent_output_tokens, total_tokens: :agent_total_tokens],
      fn {key, worker_key} ->
        {key, Map.get(base, key, 0) + Map.get(running_entry, worker_key, 0)}
      end
    )
  end

  @spec maybe_stop_for_token_budget(map(), map()) :: :ok | {:retry, map()} | {:stop, violation()}
  def maybe_stop_for_token_budget(issue, running_entry) do
    {:ok, result, :legacy} = evaluate_token_budget(issue, running_entry, :legacy)
    result
  end

  @spec maybe_stop_for_token_budget(map(), map(), %{authority: RunStateStore.authority(), expected: map()}) ::
          {:ok, :ok | {:retry, map()} | {:stop, violation()}, map()} | {:error, term()}
  def maybe_stop_for_token_budget(issue, running_entry, %{authority: authority, expected: expected} = precondition) do
    with {:ok, state} <- RunStateStore.ensure_current(authority, expected),
         :ok <- matching_policy_issue(issue, state),
         {:ok, result, checked} <- evaluate_token_budget(issue, running_entry, %{precondition: precondition, state: state}) do
      {:ok, result, checked.state}
    end
  end

  defp evaluate_token_budget(issue, running_entry, policy) do
    token_budget = Config.policy_token_budget()
    review_fix_budget = Config.policy_review_fix_token_budget()
    broad_budget = Config.policy_broad_implement_token_budget()
    workspace = policy_workspace(issue, running_entry, policy)
    run_state = policy_run_state(workspace, issue, policy)

    observation = budget_observation(issue, running_entry, run_state, workspace, policy, token_budget, review_fix_budget, broad_budget, issue_token_usage(running_entry))
    view = RetryBudget.pressure(observation)

    with {:ok, policy} <- apply_budget_pressure(issue, running_entry, view, policy),
         state <- budget_decision_state(workspace, issue, run_state, view, policy),
         decision <- RetryBudget.decide(view, state),
         {:ok, policy} <- persist_budget_decision(issue, running_entry, decision, policy) do
      apply_budget_decision(issue, workspace, decision, policy)
    end
  end

  defp budget_decision_state(workspace, issue, _initial, %RetryBudget.PolicyView{mode: :generic}, policy),
    do: policy_run_state(workspace, issue, policy)

  defp budget_decision_state(_workspace, _issue, initial, _view, :legacy), do: initial
  defp budget_decision_state(_workspace, _issue, _initial, _view, %{state: state}), do: state

  defp apply_budget_pressure(_issue, _entry, %RetryBudget.PolicyView{soft_pressure: nil}, policy),
    do: {:ok, policy}

  defp apply_budget_pressure(issue, entry, %RetryBudget.PolicyView{mode: :scoped_review_fix, soft_pressure: soft}, policy) do
    with {:ok, policy} <- persist_resume_context(issue, entry, soft.resume_context, policy) do
      _ =
        RunLedger.record("policy.decided", %{
          issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
          issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
          actor_type: "runtime",
          actor_id: "run_policy",
          summary: "Scoped review-fix turn entered soft token pressure.",
          details: "Observed input tokens #{soft.observed} above scoped soft budget #{soft.soft_budget}.",
          metadata: %{stage: soft.stage, observed: soft.observed, soft_budget: soft.soft_budget, budget_mode: "review_fix"}
        })

      {:ok, policy}
    end
  end

  defp apply_budget_pressure(_issue, _entry, %RetryBudget.PolicyView{mode: :generic, soft_pressure: soft} = view, policy) do
    with {:ok, policy} <- persist_soft_resume_context(view.workspace, view.initial_state, soft.resume_context, policy) do
      _ =
        RunLedger.record("policy.decided", %{
          issue_id: Map.get(view.issue, :id) || Map.get(view.issue, "id"),
          issue_identifier: soft.issue_identifier,
          actor_type: "runtime",
          actor_id: "run_policy",
          summary: "Turn entered soft token pressure.",
          details: "Observed implement/verify input tokens #{soft.observed} above soft budget #{soft.soft_budget}.",
          metadata: %{stage: soft.stage, observed: soft.observed, soft_budget: soft.soft_budget, review_fix_budget_retry_count: soft.review_fix_budget_retry_count}
        })

      {:ok, policy}
    end
  end

  defp persist_budget_decision(_issue, _entry, %RetryBudget.Decision{resume_context: nil}, policy),
    do: {:ok, policy}

  defp persist_budget_decision(issue, entry, %RetryBudget.Decision{resume_context: resume}, policy),
    do: persist_resume_context(issue, entry, resume, policy)

  defp apply_budget_decision(issue, workspace, %RetryBudget.Decision{result: {:stop, stop}}, policy),
    do: stop_issue(issue, budget_stop_violation(stop), workspace, policy)

  defp apply_budget_decision(_issue, _workspace, %RetryBudget.Decision{result: result}, policy),
    do: {:ok, result, policy}

  defp budget_stop_violation(%RetryBudget.Stop{kind: kind, observed: observed, metadata: metadata})
       when kind in [:per_turn_input, :per_issue_total, :per_issue_total_output],
       do: token_budget_violation(kind, observed, metadata)

  defp budget_stop_violation(%RetryBudget.Stop{kind: :review_fix_scope_exhausted, observed: observed, metadata: metadata}),
    do: review_fix_exhaustion_violation(:scope_exhausted, observed, metadata)

  defp budget_stop_violation(%RetryBudget.Stop{kind: :review_fix_turn_window_exhausted, observed: observed, metadata: metadata}),
    do: review_fix_exhaustion_violation(:turn_window_exhausted, observed, metadata)

  defp budget_stop_violation(%RetryBudget.Stop{kind: :review_fix_total_extension_exhausted, observed: observed, metadata: metadata}),
    do: review_fix_exhaustion_violation(:total_extension_exhausted, observed, metadata)

  defp budget_stop_violation(%RetryBudget.Stop{kind: :broad_implement_scope_exhausted, observed: observed, metadata: metadata}),
    do: broad_implement_exhaustion_violation(observed, metadata)

  defp budget_stop_violation(%RetryBudget.Stop{kind: :broad_implement_focus_insufficient, observed: observed, metadata: metadata}),
    do: broad_implement_focus_insufficient_violation(observed, metadata, Map.get(metadata, :next_required_path))

  defp budget_stop_violation(%RetryBudget.Stop{kind: :broad_implement_expansion_exhausted, observed: observed, metadata: metadata}),
    do: broad_implement_expansion_exhaustion_violation(observed, metadata)

  defp budget_observation(issue, entry, state, workspace, policy, token_budget, review_budget, broad_budget, usage) do
    projected_entry =
      entry
      |> Map.take([:identifier, :workspace, :workspace_path, :stage, :dispatch_stage, :resume_context, :turn_count, :agent_input_tokens, :turn_started_input_tokens])
      |> Map.put(:issue, budget_issue_observation(Map.get(entry, :issue, %{})))
      |> Map.put(:last_agent_message_text, RetryBudget.Observation.text_facts(Map.get(entry, :last_agent_message)))
      |> Map.put(:recent_agent_updates_text, RetryBudget.Observation.text_facts(Map.get(entry, :recent_agent_updates, [])))

    %RetryBudget.Observation{
      source: if(policy == :legacy, do: :legacy, else: :checked),
      issue: budget_issue_observation(issue),
      entry: projected_entry,
      state: state,
      workspace: workspace,
      issue_usage: usage,
      token_budget: token_budget,
      review_fix_budget: review_budget,
      broad_budget: broad_budget
    }
  end

  defp budget_issue_observation(nil), do: nil

  defp budget_issue_observation(issue) when is_map(issue) do
    text = RetryBudget.Observation.text_facts(issue)

    issue
    |> Map.take([:id, "id", :identifier, "identifier", :state, "state", :source, "source"])
    |> Map.put(:text, text.fragments)
  end

  defp matching_policy_issue(issue, state) do
    if (Map.get(issue, :id) || Map.get(issue, "id")) == state[:issue_id] and
         (Map.get(issue, :identifier) || Map.get(issue, "identifier")) == state[:issue_identifier],
       do: :ok,
       else: {:error, {:stale_execution, :execution_issue_mismatch}}
  end

  defp policy_workspace(issue, entry, :legacy), do: workspace_for_issue(issue, entry)
  defp policy_workspace(_issue, _entry, %{precondition: %{authority: authority}}), do: authority.ticket.workspace
  defp policy_run_state(workspace, issue, :legacy), do: RunStateStore.load_or_default(workspace, issue)
  defp policy_run_state(_workspace, _issue, %{state: state}), do: state

  defp persist_resume_context(issue, entry, resume, :legacy) do
    :ok = persist_resume_context(issue, entry, resume)
    {:ok, :legacy}
  end

  defp persist_resume_context(_issue, _entry, resume, %{precondition: precondition} = policy) do
    with {:ok, state} <- RunStateStore.update_current(precondition.authority, precondition.expected, %{resume_context: resume}) do
      {:ok, %{policy | state: state}}
    end
  end

  defp persist_soft_resume_context(workspace, state, resume, :legacy) do
    _ = RunStateStore.transition(workspace, Map.get(state, :stage, "checkout"), %{resume_context: resume})
    {:ok, :legacy}
  end

  defp persist_soft_resume_context(_workspace, _state, resume, policy),
    do: persist_resume_context(nil, nil, resume, policy)

  defp stop_issue(issue, violation, workspace, :legacy),
    do: {:ok, stop_issue_legacy(issue, violation, workspace), :legacy}

  defp stop_issue(issue, violation, _workspace, %{precondition: precondition} = policy) do
    with {:ok, current} <- RunStateStore.ensure_current(precondition.authority, precondition.expected) do
      {identifier, comment, event} = policy_stop_details(issue, violation)
      attrs = policy_stop_attrs(violation, event, current_resume_context(violation, current))

      with {:ok, blocked} <- RunStateStore.transition_current(precondition.authority, precondition.expected, "blocked", attrs),
           next = RunStateStore.material_projection(blocked),
           :ok <- RunStateStore.confirm_terminal_current(precondition.authority, next),
           :ok <- notify_policy_comment(issue, identifier, comment),
           :ok <- RunStateStore.confirm_terminal_current(precondition.authority, next),
           :ok <- notify_policy_state(issue, identifier, violation.target_state) do
        {:ok, {:stop, violation}, %{policy | state: blocked}}
      end
    end
  end

  defp promote_todo_issue(%{id: issue_id, state: state} = issue, workspace)
       when is_binary(issue_id) and is_binary(state) do
    if SymphonyElixir.Util.normalize_state(state) == SymphonyElixir.Util.normalize_state(@in_progress_state) do
      :ok
    else
      if SymphonyElixir.Util.normalize_state(state) == "todo" do
        with {:ok, _entry} <- AgentExecution.entry_context(workspace, issue) do
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
                issue,
                preflight_failed_violation("Unable to move issue to In Progress: #{inspect(reason)}"),
                workspace
              )
          end
        end
      else
        :ok
      end
    end
  end

  defp promote_todo_issue(_issue, _workspace), do: :ok

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

  defp stop_issue(issue, violation, workspace \\ nil)
  defp stop_issue(issue, violation, nil), do: stop_issue_legacy(issue, violation, nil)

  defp stop_issue(issue, violation, workspace) do
    case AgentExecution.entry_context(workspace, issue) do
      {:ok, :legacy} -> stop_issue_legacy(issue, violation, workspace)
      {:ok, _context} -> stop_issue_worker(issue, violation)
      {:stop, _} = terminal -> terminal
    end
  end

  defp stop_issue_worker(issue, violation, ledger \\ nil) do
    with {:ok, current} <- AgentExecution.ensure_current() do
      {identifier, comment, event} = policy_stop_details(issue, violation, ledger)
      attrs = policy_stop_attrs(violation, event, current_resume_context(violation, current))

      with {:ok, _blocked} <- AgentExecution.transition_current("blocked", attrs),
           :ok <- AgentExecution.confirm_stop_notification(),
           :ok <- notify_policy_comment(issue, identifier, comment),
           :ok <- AgentExecution.confirm_stop_notification(),
           :ok <- notify_policy_state(issue, identifier, violation.target_state) do
        {:stop, violation}
      end
    end
  end

  defp stop_issue_legacy(issue, violation, workspace, ledger \\ nil) do
    {identifier, comment, event} = policy_stop_details(issue, violation, ledger)

    if is_binary(workspace) do
      resume = persisted_resume_context_from_violation(violation, workspace)
      _ = RunStateStore.transition(workspace, "blocked", policy_stop_attrs(violation, event, resume))
    end

    if is_binary(Map.get(issue, :id) || Map.get(issue, "id")) do
      :ok = notify_policy_comment(issue, identifier, comment)
      :ok = notify_policy_state(issue, identifier, violation.target_state)
    end

    {:stop, violation}
  end

  defp policy_stop_details(issue, violation, ledger \\ nil) do
    issue_id = Map.get(issue, :id) || Map.get(issue, "id")
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || issue_id || "unknown"

    event =
      record_policy_stop(ledger, %{
        issue_id: issue_id,
        issue_identifier: identifier,
        actor_type: "runtime",
        actor_id: "run_policy",
        failure_class: violation.failure_class,
        rule_id: violation.rule_id,
        summary: violation.summary,
        details: violation.details,
        target_state: violation.target_state,
        metadata:
          %{
            code: Atom.to_string(violation.code),
            human_action: violation.human_action,
            violation_metadata: violation.metadata
          }
          |> Map.merge(Map.take(violation.metadata, [:gate_id, :gate]))
      })

    {identifier, violation_comment(identifier, violation), event}
  end

  defp policy_stop_attrs(violation, event, resume) do
    %{
      resume_context: resume,
      stop_reason:
        %{
          code: Atom.to_string(violation.code),
          rule_id: violation.rule_id,
          failure_class: violation.failure_class,
          summary: violation.summary,
          details: violation.details,
          human_action: violation.human_action
        }
        |> Map.merge(Map.take(violation.metadata, [:gate_id, :gate])),
      last_decision: %{
        rule_id: violation.rule_id,
        failure_class: violation.failure_class,
        summary: violation.summary,
        details: violation.details,
        human_action: violation.human_action,
        target_state: violation.target_state,
        ledger_event_id: Map.get(event, :event_id),
        metadata: violation.metadata
      },
      last_rule_id: violation.rule_id,
      last_failure_class: violation.failure_class,
      last_decision_summary: violation.summary,
      next_human_action: violation.human_action
    }
  end

  defp record_policy_stop(nil, attrs), do: RunLedger.record("runtime.stopped", attrs)
  defp record_policy_stop(ledger, attrs), do: record_gate_event!(ledger, "runtime.stopped", attrs)

  defp current_resume_context(%Violation{metadata: metadata}, state) do
    case Map.get(metadata, :resume_context) || Map.get(metadata, "resume_context") do
      resume when is_map(resume) -> resume
      _ -> Map.get(state, :resume_context, %{})
    end
  end

  defp notify_policy_comment(issue, identifier, comment) do
    case IssueSource.create_comment(issue, comment) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to create policy comment for #{identifier}: #{inspect(reason)}")
    end

    :ok
  end

  defp notify_policy_state(issue, identifier, target) do
    case IssueSource.update_issue_state(issue, target) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to move #{identifier} to #{target}: #{inspect(reason)}")
    end

    :ok
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

  defp token_budget_violation(kind, observed, metadata) do
    code =
      case kind do
        :per_turn_input -> :per_turn_input_budget_exceeded
        :per_issue_total -> :per_issue_total_budget_exceeded
        :per_issue_total_output -> :per_issue_output_budget_exceeded
      end

    admission_reason =
      Map.get(metadata, :budget_admission_reason) || Map.get(metadata, "budget_admission_reason")

    {summary, details} = token_budget_violation_message(kind, observed, admission_reason)

    violation(code,
      summary: summary,
      details: details,
      metadata: metadata
    )
  end

  defp token_budget_violation_message(:per_turn_input, observed, reason)
       when is_binary(reason) and reason not in ["", "missing_workspace"] do
    {
      "The run exceeded the per-turn input budget and could not enter the adaptive retry lane.",
      "Budget per_turn_input exceeded with observed value #{observed}. Broad-implement admission reason: #{reason}."
    }
  end

  defp token_budget_violation_message(kind, observed, _reason) do
    {
      "The run exceeded a configured token budget and was stopped.",
      "Budget #{kind} exceeded with observed value #{observed}."
    }
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

  defp persist_resume_context(issue, running_entry, resume_context) do
    workspace = workspace_for_issue(issue, running_entry)

    if is_binary(workspace) do
      stage =
        Map.get(running_entry, :stage) || "implement"

      _ =
        RunStateStore.transition(workspace, stage, %{
          resume_context: resume_context
        })
    end

    :ok
  end

  defp workspace_for_issue(issue, running_entry) do
    Map.get(running_entry, :workspace_path) ||
      Map.get(running_entry, :workspace) ||
      Workspace.path_for_issue(Map.get(issue, :identifier) || Map.get(issue, "identifier"))
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
