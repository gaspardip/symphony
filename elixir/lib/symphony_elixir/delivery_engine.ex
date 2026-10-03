defmodule SymphonyElixir.DeliveryEngine do
  @moduledoc """
  Runtime-owned delivery engine for checkout, implementation, validation, publish, merge, post-merge closure, and optional preview deployment.
  """

  # credo:disable-for-this-file

  require Logger

  alias SymphonyElixir.AgentExecution
  alias SymphonyElixir.AgentProvider
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.AgentHarness
  alias SymphonyElixir.Config
  alias SymphonyElixir.DeployAudit
  alias SymphonyElixir.EvidenceAcceptance
  alias SymphonyElixir.GitManager
  alias SymphonyElixir.IssueAcceptance
  alias SymphonyElixir.IssueSource
  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.ManualIssueSpec
  alias SymphonyElixir.Observability
  alias SymphonyElixir.PolicyPack
  alias SymphonyElixir.PullRequestManager
  alias SymphonyElixir.ReviewEvidenceCollector
  alias SymphonyElixir.RepoMap
  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.DeliveryEngine.ReviewClaims
  alias SymphonyElixir.TurnResult
  alias SymphonyElixir.VerifierRunner
  alias SymphonyElixir.WorkflowProfile

  @blocked_state "Blocked"
  @in_progress_state "In Progress"
  @merging_state "Merging"
  @done_state "Done"
  @rework_state "Rework"
  @report_turn_result_tool "report_agent_turn_result"
  @turn_result_key_prefix :symphony_turn_result
  @turn_runtime_error_key_prefix :symphony_turn_runtime_error
  @await_checks_missing_limit 6
  @publish_followup_stage "merge_readiness"
  @agent_turn_error_methods ["codex/event/stream_error", "codex/event/error", "error"]
  @review_fix_max_turns 6
  @passive_stages [
    "merge_readiness",
    "await_checks",
    "review_verification",
    "merge",
    "post_merge",
    "deploy_preview",
    "deploy_production",
    "post_deploy_verify"
  ]

  @spec run(Path.t(), Issue.t(), pid() | nil, keyword()) ::
          :ok | {:done, Issue.t()} | {:stop, term()} | {:error, term()}
  def run(workspace, %Issue{} = issue, agent_update_recipient, opts \\ [])
      when is_binary(workspace) do
    with :ok <- ensure_delivery_entry_readable(workspace, issue) do
      run_with_readable_snapshot(workspace, issue, agent_update_recipient, opts)
    else
      {:stop, _} = terminal ->
        terminal

      {:error, reason} ->
        Logger.error("Delivery blocked by unreadable snapshot issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
        {:stop, reason}
    end
  end

  defp ensure_delivery_entry_readable(workspace, issue) do
    case AgentExecution.current_context() do
      {:ok, _captured_context} ->
        execution_guard(workspace, issue)

      {:error, :execution_context_missing} ->
        with :ok <- RunStateStore.ensure_readable(workspace), :ok <- execution_guard(workspace, issue), do: :ok
    end
  end

  defp execution_guard(workspace, issue \\ nil) do
    case unscoped_snapshot_readable(workspace) do
      :ok ->
        with {:ok, _context} <- AgentExecution.entry_context(workspace, issue), do: :ok

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp unscoped_snapshot_readable(workspace) do
    case AgentExecution.current_context() do
      {:ok, _context} ->
        :ok

      {:error, :execution_context_missing} ->
        # A live deploy owns a pending journal. Its ticket APIs check custody;
        # this preflight only preserves the snapshot read error for legacy callers.
        case RunStateStore.load(workspace) do
          {:ok, _snapshot} -> :ok
          {:error, :missing} -> :ok
          {:error, %Jason.DecodeError{position: position}} -> {:error, {:run_state_unreadable, {:invalid_json, position}}}
          {:error, reason} -> {:error, {:run_state_unreadable, reason}}
        end
    end
  end

  defp delivery_state(workspace, issue) do
    case AgentExecution.entry_context(workspace, issue) do
      {:ok, :legacy} -> {:ok, RunStateStore.load_or_default(workspace, issue)}
      {:ok, _context} -> AgentExecution.ensure_current()
      {:stop, _} = terminal -> terminal
    end
  end

  defp update_state(workspace, attrs) do
    case AgentExecution.entry_context(workspace, nil) do
      {:ok, :legacy} -> RunStateStore.update(workspace, &Map.merge(&1, attrs))
      {:ok, _context} -> AgentExecution.update_current(attrs)
      {:stop, _} = terminal -> terminal
    end
  end

  defp transition_state(workspace, stage, attrs) do
    with :ok <- unscoped_snapshot_readable(workspace) do
      case AgentExecution.entry_context(workspace, nil) do
        {:ok, :legacy} -> RunStateStore.transition(workspace, stage, attrs)
        {:ok, _context} -> AgentExecution.transition_current(stage, attrs)
        {:stop, _} = terminal -> terminal
      end
    end
  end

  defp transition_deploy_state(ticket, stage, attrs) do
    case AgentExecution.entry_context(ticket.workspace, nil) do
      {:ok, :legacy} -> RunStateStore.transition_deploy(ticket, stage, attrs)
      {:ok, _context} -> AgentExecution.transition_deploy(ticket, stage, attrs)
      {:stop, _} = terminal -> terminal
    end
  end

  defp confirm_block_notification do
    case AgentExecution.current_context() do
      {:ok, _context} -> AgentExecution.confirm_stop_notification()
      {:error, :execution_context_missing} -> :ok
    end
  end

  defp run_with_readable_snapshot(workspace, issue, agent_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &IssueSource.fetch_issue_states_by_ids/1)

    with {:ok, initial_state} <- delivery_state(workspace, issue),
         state when is_map(state) <- maybe_sync_policy_override(initial_state, workspace, opts) do
      stage = Map.get(state, :stage, "checkout")

      if passive_stage?(stage) do
        Logger.info("Skipping agent session bootstrap for passive stage #{stage} issue=#{issue.identifier} workspace=#{workspace}")

        do_run(nil, workspace, issue, agent_update_recipient, issue_state_fetcher, max_turns, opts)
      else
        provider = AgentProvider.resolve_for_stage(stage)
        Logger.info("Starting agent session bootstrap for #{issue.identifier} provider=#{inspect(provider)} workspace=#{workspace}")

        with {:ok, app_session, binding} <- AgentProvider.open_session(provider, workspace, issue, :main) do
          session_id = Map.get(app_session, :thread_id) || Map.get(app_session, :session_id, "unknown")
          Logger.info("Agent session bootstrap succeeded for #{issue.identifier} session_id=#{session_id}")

          SymphonyElixir.ProviderTransport.with_cleanup(
            fn ->
              do_run(
                app_session,
                workspace,
                issue,
                agent_update_recipient,
                issue_state_fetcher,
                max_turns,
                opts |> Keyword.put(:agent_provider, provider) |> Keyword.put(:execution_binding, binding)
              )
            end,
            fn -> AgentProvider.close_session(provider, app_session, binding) end
          )
        else
          {:stop, _} = terminal ->
            terminal

          {:error, reason} = error ->
            Logger.error("Agent session bootstrap failed for #{issue.identifier}: #{inspect(reason)}")

            error
        end
      end
    end
  end

  @doc false
  @spec fetch_turn_result_for_test(term()) :: term()
  def fetch_turn_result_for_test(issue), do: fetch_turn_result(issue)

  @doc false
  @spec execute_tool_for_test(term(), term(), term(), keyword()) :: term()
  def execute_tool_for_test(issue, tool, arguments, opts \\ []) do
    tool_executor(issue, opts).(tool, arguments)
  end

  @doc false
  @spec implementation_turn_error_summary_for_test(term()) :: term()
  def implementation_turn_error_summary_for_test(reason),
    do: implementation_turn_error_summary(reason)

  @doc false
  @spec retryable_implementation_error_for_test(term()) :: boolean()
  def retryable_implementation_error_for_test(reason), do: retryable_implementation_error?(reason)

  @doc false
  @spec non_retryable_implementation_error_for_test(term()) :: boolean()
  def non_retryable_implementation_error_for_test(reason),
    do: non_retryable_implementation_error?(reason)

  @doc false
  @spec implementation_error_code_for_test(term()) :: term()
  def implementation_error_code_for_test(reason), do: implementation_error_code(reason)

  @doc false
  @spec maybe_move_issue_for_test(term(), term()) :: term()
  def maybe_move_issue_for_test(issue, target_state), do: maybe_move_issue(issue, target_state)

  @doc false
  @spec agent_message_handler_for_test(pid() | nil, term()) :: term()
  def agent_message_handler_for_test(recipient, issue),
    do: agent_message_handler(recipient, issue)

  @doc false
  @spec normalize_state_for_test(term()) :: term()
  def normalize_state_for_test(state), do: SymphonyElixir.Util.normalize_state(state)

  @doc false
  @spec active_issue_state_for_test(term()) :: boolean()
  def active_issue_state_for_test(state_name), do: active_issue_state?(state_name)

  @doc false
  @spec branch_has_publishable_changes_for_test(Path.t(), map(), keyword()) :: term()
  def branch_has_publishable_changes_for_test(workspace, state, opts \\ []) do
    branch_has_publishable_changes?(workspace, state, opts)
  end

  @doc false
  @spec normalize_pr_state_for_test(term()) :: term()
  def normalize_pr_state_for_test(pr_state), do: normalize_pr_state(pr_state)

  @doc false
  @spec maybe_sync_policy_override_for_test(map(), Path.t(), keyword()) :: map() | {:error, term()} | AgentExecution.terminal()
  def maybe_sync_policy_override_for_test(state, workspace, opts) do
    maybe_sync_policy_override(state, workspace, opts)
  end

  @doc false
  @spec detail_summary_for_test(term(), term()) :: term()
  def detail_summary_for_test(code, detail), do: detail_summary(code, detail)

  @doc false
  @spec human_review_summary_for_test(term()) :: String.t()
  def human_review_summary_for_test(code),
    do: approval_gate_summary(code, WorkflowProfile.approval_gate_state("review_required"))

  @doc false
  @spec publish_followup_stage_for_test() :: String.t()
  def publish_followup_stage_for_test, do: @publish_followup_stage

  @doc false
  @spec implement_prompt_for_test(term(), map(), keyword(), non_neg_integer(), pos_integer()) ::
          String.t() | AgentExecution.terminal()
  def implement_prompt_for_test(issue, state, opts, turn_number, max_turns),
    do:
      implement_prompt(
        issue,
        state,
        Keyword.get(opts, :workspace, System.tmp_dir!()),
        Keyword.get(
          opts,
          :inspection,
          %RunInspector.Snapshot{
            fingerprint: "test",
            dirty?: false,
            changed_files: 0,
            pr_url: nil
          }
        ),
        opts,
        turn_number,
        max_turns
      )

  @doc false
  @spec implement_command_output_budget_for_test(map()) :: map()
  def implement_command_output_budget_for_test(state), do: implement_command_output_budget(state)

  @spec advance_review_claims_after_turn_for_test(map(), list(), TurnResult.t()) :: map()
  def advance_review_claims_after_turn_for_test(
        review_claims,
        focused_claims,
        %TurnResult{} = turn_result
      ),
      do: ReviewClaims.advance_review_claims_after_turn(review_claims, focused_claims, turn_result)

  @doc false
  @spec finalize_published_review_threads_for_test(map()) :: map()
  def finalize_published_review_threads_for_test(review_threads),
    do: ReviewClaims.finalize_published_review_threads(review_threads)

  @doc false
  @spec maintain_merge_readiness_for_test(Path.t(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | AgentExecution.terminal()
  def maintain_merge_readiness_for_test(workspace, issue, state, inspection, opts \\ [])
      when is_binary(workspace) and is_map(issue) and is_map(state) and is_map(inspection) do
    ReviewClaims.maybe_maintain_merge_readiness(workspace, issue, state, inspection, opts)
  end

  @doc false
  @spec maybe_resolve_autonomous_review_threads_for_test(
          map(),
          Path.t(),
          String.t(),
          map(),
          keyword()
        ) :: map() | AgentExecution.terminal()
  def maybe_resolve_autonomous_review_threads_for_test(
        review_threads,
        workspace,
        pr_url,
        state,
        opts \\ []
      ),
      do: ReviewClaims.maybe_resolve_autonomous_review_threads(review_threads, workspace, pr_url, state, opts)

  @doc false
  @spec ensure_turn_progress_for_test(term(), term(), term()) :: term()
  def ensure_turn_progress_for_test(turn_result, before_snapshot, after_snapshot),
    do: ensure_turn_progress(turn_result, before_snapshot, after_snapshot)

  @doc false
  @spec implement_next_stage_for_test(term(), term(), term()) :: term()
  def implement_next_stage_for_test(turn_result, before_snapshot, after_snapshot),
    do: implement_next_stage(turn_result, before_snapshot, after_snapshot)

  @doc false
  @spec handle_checkout_error_for_test(Path.t(), term(), term()) :: term()
  def handle_checkout_error_for_test(workspace, issue, reason),
    do: handle_checkout_error(workspace, issue, reason)

  @doc false
  @spec should_resume_validation_from_retained_changes_for_test(map(), list(), term()) ::
          boolean()
  def should_resume_validation_from_retained_changes_for_test(
        state,
        focused_claims,
        before_snapshot
      ),
      do: should_resume_validation_from_retained_changes?(state, focused_claims, before_snapshot)

  defp do_run(
         app_session,
         workspace,
         issue,
         agent_update_recipient,
         issue_state_fetcher,
         max_turns,
         opts
       ) do
    with :ok <- ensure_delivery_entry_readable(workspace, issue) do
      do_run_with_readable_snapshot(
        app_session,
        workspace,
        issue,
        agent_update_recipient,
        issue_state_fetcher,
        max_turns,
        opts
      )
    else
      {:stop, _} = terminal ->
        terminal

      {:error, reason} ->
        Logger.error("Delivery blocked by unreadable snapshot issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
        {:stop, reason}
    end
  end

  defp do_run_with_readable_snapshot(
         app_session,
         workspace,
         issue,
         agent_update_recipient,
         issue_state_fetcher,
         max_turns,
         opts
       ) do
    with {:ok, state} <- delivery_state(workspace, issue) do
      workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))
      max_turns = effective_max_turns(workflow_profile.max_turns_override || max_turns, state)

      stage = Map.get(state, :stage, "checkout")

      if is_nil(app_session) and not passive_stage?(stage) do
        bootstrap_session_and_run(
          workspace,
          issue,
          agent_update_recipient,
          issue_state_fetcher,
          max_turns,
          stage,
          opts
        )
      else
        do_run_dispatched(
          app_session,
          workspace,
          issue,
          agent_update_recipient,
          issue_state_fetcher,
          max_turns,
          state,
          stage,
          opts
        )
      end
    end
  end

  defp bootstrap_session_and_run(
         workspace,
         issue,
         agent_update_recipient,
         issue_state_fetcher,
         max_turns,
         stage,
         opts
       ) do
    provider = Keyword.get(opts, :agent_provider) || AgentProvider.resolve_for_stage(stage)

    Logger.info("Late session bootstrap for active stage #{stage} issue=#{issue.identifier} provider=#{inspect(provider)}")

    with {:ok, app_session, binding} <- AgentProvider.open_session(provider, workspace, issue, :main) do
      SymphonyElixir.ProviderTransport.with_cleanup(
        fn ->
          do_run(
            app_session,
            workspace,
            issue,
            agent_update_recipient,
            issue_state_fetcher,
            max_turns,
            opts |> Keyword.put(:agent_provider, provider) |> Keyword.put(:execution_binding, binding)
          )
        end,
        fn -> AgentProvider.close_session(provider, app_session, binding) end
      )
    else
      {:stop, _} = terminal ->
        terminal

      {:error, reason} = error ->
        Logger.error("Late session bootstrap failed for #{issue.identifier}: #{inspect(reason)}")

        error
    end
  end

  defp do_run_dispatched(
         app_session,
         workspace,
         issue,
         agent_update_recipient,
         issue_state_fetcher,
         max_turns,
         state,
         stage,
         opts
       ) do
    with :ok <- execution_guard(workspace, issue),
         inspection <- RunInspector.inspect(workspace, opts),
         :ok <- execution_guard(workspace, issue) do
      Observability.with_stage(stage, issue_observability_metadata(issue, state), fn ->
        case stage do
          "checkout" ->
            handle_checkout(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "plan" ->
            handle_plan(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "implement" ->
            handle_implement(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "initialize_harness" ->
            handle_initialize_harness(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "validate" ->
            handle_validate(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "review_verification" ->
            handle_review_verification(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "verify" ->
            handle_verify(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "publish" ->
            handle_publish(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "merge_readiness" ->
            handle_merge_readiness(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "await_checks" ->
            handle_await_checks(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "merge" ->
            handle_merge(
              app_session,
              workspace,
              issue,
              agent_update_recipient,
              issue_state_fetcher,
              max_turns,
              state,
              inspection,
              opts
            )

          "post_merge" ->
            handle_post_merge(workspace, issue, state, inspection, opts)

          "deploy_preview" ->
            handle_deploy_preview(workspace, issue, state, inspection, opts)

          "deploy_production" ->
            handle_deploy_production(workspace, issue, state, inspection, opts)

          "post_deploy_verify" ->
            handle_post_deploy_verify(workspace, issue, state, inspection, opts)

          "done" ->
            {:done, issue}

          "blocked" ->
            {:stop, :blocked}

          _ ->
            {:error, {:unknown_stage, stage}}
        end
      end)
    end
  end

  defp issue_observability_metadata(issue, state) do
    Observability.issue_metadata(issue, state, %{
      workflow_profile: Map.get(state, :effective_policy_class),
      operating_mode: Config.company_mode()
    })
  end

  defp passive_stage?(stage) when stage in @passive_stages, do: true
  defp passive_stage?(_stage), do: false

  defp handle_checkout(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    with :ok <- execution_guard(workspace, issue),
         branch_result <- GitManager.prepare_issue_branch(workspace, issue, inspection.harness, opts),
         :ok <- execution_guard(workspace, issue),
         {:ok, branch_info} <- branch_result,
         {:ok, harness} <- RepoHarness.load(workspace),
         {:ok, _policy_resolution, policy_state} <- resolve_policy(issue, state, workspace),
         next_stage <- checkout_next_stage(harness),
         {:ok, _state} <-
           transition_state(workspace, next_stage, %{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             branch: branch_info.branch,
             base_branch: branch_info.base_branch,
             harness_version: harness.version,
             effective_policy_class: Map.get(policy_state, :effective_policy_class),
             effective_policy_source: Map.get(policy_state, :effective_policy_source)
           }),
         :ok <- execution_guard(workspace, issue),
         :ok <- maybe_move_issue(issue, @in_progress_state),
         :ok <- execution_guard(workspace, issue) do
      do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
    else
      {:stop, _} = terminal -> terminal
      error -> handle_checkout_error(workspace, issue, error)
    end
  end

  defp plan_already_exists?(workspace, issue) do
    case AgentHarness.progress_file_path(workspace, issue) do
      {:ok, path} ->
        case File.read(path) do
          {:ok, content} -> has_real_plan?(content)
          _ -> false
        end

      _ ->
        false
    end
  end

  # A real plan has a ## Plan section with specific file paths — not just template placeholders
  defp has_real_plan?(content) do
    case Regex.run(~r/## Plan\s*\n([\s\S]*?)(?=\n## |\z)/, content) do
      [_, body] ->
        trimmed = String.trim(body)
        # Must have actual content AND reference at least one file path
        trimmed != "" and
          not String.contains?(trimmed, "Outline") and
          not String.contains?(trimmed, "implementation steps here") and
          (String.contains?(trimmed, ".ex") or String.contains?(trimmed, ".exs") or
             String.contains?(trimmed, "/lib/") or String.contains?(trimmed, "/test/"))

      _ ->
        false
    end
  end

  defp checkout_next_stage(harness) do
    if AgentHarness.enabled?(harness), do: "initialize_harness", else: "plan"
  end

  defp handle_initialize_harness(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    harness = inspection.harness

    with :ok <- execution_guard(workspace, issue),
         result <- AgentHarness.initialize(workspace, issue, harness),
         :ok <- execution_guard(workspace, issue) do
      case result do
        {:ok, attrs} ->
          with {:ok, _persisted_state} <-
                 transition_state(
                   workspace,
                   "plan",
                   Map.merge(
                     %{
                       last_harness_init: Map.merge(attrs, %{status: "passed"}),
                       last_harness_check: %{
                         status: "passed",
                         checked_at: SymphonyElixir.Util.now_iso8601()
                       },
                       harness_status: "ready",
                       harness_attempts: Map.get(state, :harness_attempts, 0) + 1
                     },
                     Map.take(attrs, [:progress_path, :harness_status, :last_harness_init, :harness_attempts])
                   )
                 ),
               :ok <- execution_guard(workspace, issue) do
            do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
          end

        {:error, reason} ->
          block_issue(
            workspace,
            issue,
            :harness_initialize_failed,
            inspect(reason),
            @blocked_state
          )
      end
    end
  end

  defp handle_plan(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         _inspection,
         opts
       ) do
    provider = Keyword.get(opts, :agent_provider, AgentProvider.resolve_for_stage("plan"))
    model = Config.agent_model_for_stage("plan") || Config.agent_model()

    with :ok <- execution_guard(workspace, issue),
         plan_exists <- plan_already_exists?(workspace, issue),
         :ok <- execution_guard(workspace, issue) do
      if plan_exists do
        log_agent_turn_lifecycle(
          agent_turn_log_context("plan", provider, model, issue, 0, default_turn_tokens()),
          "provider=skipped,turn=skipped,plan_completed=false"
        )

        progress_path = progress_path_for_issue(workspace, issue)

        with {:ok, _persisted_state} <-
               transition_state(workspace, "implement", %{
                 plan_completed: true,
                 resume_context: %{next_objective: "Follow the implementation plan in #{progress_path}. Read it first, then implement each step."}
               }),
             :ok <- execution_guard(workspace, issue) do
          do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
        end
      else
        do_plan_turn(
          app_session,
          workspace,
          issue,
          recipient,
          fetcher,
          max_turns,
          state,
          Keyword.put(opts, :agent_provider, provider)
        )
      end
    end
  end

  defp do_plan_turn(app_session, workspace, issue, recipient, fetcher, max_turns, state, opts) do
    prompt = plan_prompt(issue, state, workspace)

    clear_turn_result(issue)
    clear_turn_runtime_errors(issue)

    provider = Keyword.get(opts, :agent_provider, AgentProvider.resolve_for_stage("plan"))
    model = Config.agent_model_for_stage("plan") || Config.agent_model()

    turn_opts =
      Keyword.merge(
        opts,
        stage: "plan",
        effort: Config.agent_turn_effort("plan"),
        model: model,
        on_message: agent_message_handler(recipient, issue),
        tool_executor: tool_executor(issue, opts)
      )

    {provider_turn_result, turn_log_context} =
      run_logged_agent_turn(provider, app_session, workspace, prompt, issue, turn_opts)

    case provider_turn_result do
      {:stop, _} = terminal ->
        terminal

      {:error, {:turn_effect_failed, _details}} = error ->
        log_agent_turn_lifecycle(turn_log_context, plan_turn_log_result(error, error, false))
        error

      _ ->
        with :ok <- execution_guard(workspace, issue) do
          reported_turn_result = fetch_turn_result(issue)
          plan_completed = match?({:ok, _}, provider_turn_result) and match?({:ok, _}, reported_turn_result)

          log_agent_turn_lifecycle(
            turn_log_context,
            plan_turn_log_result(provider_turn_result, reported_turn_result, plan_completed)
          )

          progress_path = progress_path_for_issue(workspace, issue)

          with {:ok, _persisted_state} <-
                 transition_state(workspace, "implement", %{
                   plan_completed: plan_completed,
                   resume_context: %{next_objective: "Follow the implementation plan in #{progress_path}. Read it first, then implement each step."}
                 }),
               :ok <- execution_guard(workspace, issue) do
            do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
          end
        end
    end
  end

  defp progress_path_for_issue(workspace, issue) do
    case AgentHarness.progress_file_path(workspace, issue) do
      {:ok, path} -> Path.relative_to(path, workspace)
      _ -> ".symphony/progress/#{issue.identifier}.md"
    end
  end

  defp plan_prompt(issue, _state, workspace) do
    acceptance = IssueAcceptance.from_issue(issue)

    acceptance_text =
      case acceptance.criteria do
        [] -> "- #{acceptance.summary}"
        criteria -> Enum.map_join(criteria, "\n", &"- #{&1}")
      end

    progress_path =
      case AgentHarness.progress_file_path(workspace, issue) do
        {:ok, path} -> Path.relative_to(path, workspace)
        _ -> ".symphony/progress/#{issue.identifier}.md"
      end

    """
    #{SymphonyElixir.PromptBuilder.build_prompt(issue)}

    You are running a PLANNING turn. You must:

    1. READ the issue description above carefully — it specifies exactly which files to change and what to do.
    2. READ every source file mentioned in the issue description. If the description mentions `delivery_engine.ex`, open it and read the relevant functions. Do the same for every file referenced.
    3. WRITE a progress file at `#{progress_path}` with a DETAILED implementation plan.

    The progress file MUST contain these exact Markdown H2 sections with REAL content (not placeholders):

    ## Goal
    One sentence: what this ticket achieves.

    ## Acceptance
    #{acceptance_text}

    ## Plan
    A numbered list where EACH step names:
    - The exact file path (e.g., `elixir/lib/symphony_elixir/delivery_engine.ex`)
    - The exact function to modify or add
    - What the change does, with enough detail that another developer could implement it

    ## Work Log
    - Read the codebase and wrote the implementation plan.

    ## Evidence
    - List the files you read and what you learned from each.

    ## Next Step
    The first specific action: which file to open, which function to edit, what to add.

    IMPORTANT:
    - Do NOT write placeholder text like "Outline steps here" — write the ACTUAL plan.
    - Do NOT modify source code in this turn — only write the progress file.
    - You MUST read the relevant source files before writing the plan. A plan without reading code is useless.
    - Spend most of your turn reading files. The plan should reflect what you actually found in the code.
    """
  end

  defp handle_implement(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         _inspection,
         opts
       ) do
    with :ok <- execution_guard(workspace, issue),
         state when is_map(state) <- ReviewClaims.maybe_persist_reconciled_review_feedback(state, workspace, opts),
         preflight_review_claims when is_map(preflight_review_claims) <-
           ReviewClaims.maybe_refresh_preflight_review_claims(Map.get(state, :review_claims, %{}), workspace),
         preflight_review_threads when is_map(preflight_review_threads) <-
           ReviewClaims.sync_review_claims_into_threads(Map.get(state, :review_threads, %{}), preflight_review_claims)
           |> ReviewClaims.maybe_post_autonomous_review_replies(workspace, Map.get(state, :pr_url), Map.put(state, :review_claims, preflight_review_claims), opts),
         {:ok, state} <- persist_preflight_review(workspace, state, preflight_review_claims, preflight_review_threads),
         :ok <- execution_guard(workspace, issue),
         before_snapshot <- RunInspector.inspect(workspace, opts),
         :ok <- execution_guard(workspace, issue) do
      implementation_turns = Map.get(state, :implementation_turns, 0)
      effective_implementation_turns = effective_implementation_turns(state)

      focused_claims =
        ReviewClaims.focused_review_claims(
          preflight_review_claims,
          focused_review_claim_limit(state)
        )

      cond do
        should_resume_validation_from_retained_changes?(state, focused_claims, before_snapshot) ->
          with resume_attrs when is_map(resume_attrs) <-
                 resume_context_attrs(
                   workspace,
                   issue,
                   state,
                   before_snapshot,
                   %{
                     next_objective: "Stop editing and let Symphony run the official validation contract."
                   },
                   opts
                 ),
               {:ok, _persisted_state} <-
                 transition_state(
                   workspace,
                   "validate",
                   Map.merge(
                     %{
                       review_claims: preflight_review_claims,
                       review_threads: preflight_review_threads,
                       branch: before_snapshot.branch || Map.get(state, :branch),
                       pr_url: before_snapshot.pr_url || Map.get(state, :pr_url)
                     },
                     resume_attrs
                   )
                 ),
               :ok <- execution_guard(workspace, issue) do
            do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
          end

        effective_implementation_turns >= max_turns ->
          block_issue(
            workspace,
            issue,
            :turn_budget_exhausted,
            "Reached #{max_turns} implementation turns without a mergeable result.",
            @blocked_state
          )

        true ->
          with prompt when is_binary(prompt) <-
                 implement_prompt(
                   issue,
                   state,
                   workspace,
                   before_snapshot,
                   opts,
                   effective_implementation_turns + 1,
                   max_turns
                 ) do
            clear_turn_result(issue)
            clear_turn_runtime_errors(issue)

            try do
              provider = Keyword.get(opts, :agent_provider, AgentProvider.resolve_for_stage("implement"))
              model = Config.agent_model_for_stage("implement") || Config.agent_model()

              turn_opts =
                Keyword.merge(
                  opts,
                  stage: "implement",
                  effort: implement_effort(state),
                  model: model,
                  forbidden_commands: implement_forbidden_commands(before_snapshot.harness),
                  command_output_budget: implement_command_output_budget(state),
                  on_message: agent_message_handler(recipient, issue),
                  tool_executor: tool_executor(issue, opts)
                )

              {provider_turn_result, turn_log_context} =
                run_logged_agent_turn(provider, app_session, workspace, prompt, issue, turn_opts)

              with {:ok, _turn_session} <- provider_turn_result,
                   :ok <- execution_guard(workspace, issue),
                   {:ok, turn_result} <- fetch_turn_result(issue) do
                log_agent_turn_lifecycle(
                  turn_log_context,
                  implement_turn_log_result(provider_turn_result, {:ok, turn_result})
                )

                with :ok <- execution_guard(workspace, issue),
                     after_snapshot <- RunInspector.inspect(workspace, opts),
                     :ok <- execution_guard(workspace, issue),
                     {:ok, next_stage} <-
                       implement_next_stage(turn_result, before_snapshot, after_snapshot),
                     updated_review_claims =
                       ReviewClaims.advance_review_claims_after_turn(
                         preflight_review_claims,
                         focused_claims,
                         turn_result
                       ),
                     updated_review_threads when is_map(updated_review_threads) <-
                       ReviewClaims.sync_review_claims_into_threads(
                         Map.get(state, :review_threads, %{}),
                         updated_review_claims
                       )
                       |> ReviewClaims.maybe_post_autonomous_review_replies(
                         workspace,
                         after_snapshot.pr_url || Map.get(state, :pr_url),
                         state,
                         opts
                       ),
                     resume_attrs when is_map(resume_attrs) <-
                       resume_context_attrs(
                         workspace,
                         issue,
                         state,
                         after_snapshot,
                         %{
                           last_turn_summary: turn_result.summary,
                           next_objective:
                             next_objective_for_stage(
                               next_stage,
                               turn_result,
                               updated_review_claims
                             )
                         },
                         opts
                       ),
                     {:ok, _persisted_state} <-
                       transition_state(
                         workspace,
                         next_stage,
                         Map.merge(
                           %{
                             implementation_turns: implementation_turns + 1,
                             review_claims: updated_review_claims,
                             review_threads: updated_review_threads,
                             last_turn_result: TurnResult.to_map(turn_result),
                             branch: after_snapshot.branch || Map.get(state, :branch),
                             pr_url: after_snapshot.pr_url || Map.get(state, :pr_url)
                           },
                           resume_attrs
                         )
                       ),
                     :ok <- execution_guard(workspace, issue),
                     refresh_result <- refresh_issue(issue, fetcher),
                     :ok <- execution_guard(workspace, issue),
                     {:ok, refreshed_issue} <- refresh_result,
                     :ok <- ensure_issue_still_active(refreshed_issue) do
                  do_run(app_session, workspace, refreshed_issue, recipient, fetcher, max_turns, opts)
                else
                  {:stop, _} = terminal ->
                    terminal

                  {:error, {:noop_turn, _summary}} ->
                    block_issue(
                      workspace,
                      issue,
                      :noop_turn,
                      "The turn produced no code change and no PR.",
                      @blocked_state
                    )

                  {:error, {:agent_blocked, %TurnResult{} = turn_result}} ->
                    block_issue(
                      workspace,
                      issue,
                      turn_result.blocker_type,
                      turn_result.summary,
                      @blocked_state
                    )

                  {:done, finished_issue} ->
                    {:done, finished_issue}

                  {:skip, finished_issue} ->
                    {:done, finished_issue}

                  {:error, reason} ->
                    cond do
                      retryable_implementation_error?(reason) ->
                        handle_implementation_turn_error(
                          app_session,
                          workspace,
                          issue,
                          recipient,
                          fetcher,
                          max_turns,
                          state,
                          opts,
                          reason
                        )

                      non_retryable_implementation_error?(reason) ->
                        block_issue(
                          workspace,
                          issue,
                          implementation_error_code(reason),
                          implementation_turn_error_summary(reason),
                          @blocked_state
                        )

                      true ->
                        {:error, reason}
                    end
                end
              else
                {:stop, _} = terminal ->
                  terminal

                error ->
                  log_agent_turn_lifecycle(
                    turn_log_context,
                    implement_turn_log_result(provider_turn_result, error)
                  )

                  case error do
                    {:error, {:turn_effect_failed, _details}} ->
                      error

                    {:error, {:turn_runtime_error, reason}} ->
                      handle_implementation_turn_error(
                        app_session,
                        workspace,
                        issue,
                        recipient,
                        fetcher,
                        max_turns,
                        state,
                        opts,
                        reason
                      )

                    {:error, {:invalid_turn_result, reason}} ->
                      block_issue(workspace, issue, :invalid_turn_result, inspect(reason), @blocked_state)

                    {:error, :missing_turn_result} ->
                      block_issue(
                        workspace,
                        issue,
                        :missing_turn_result,
                        "The agent did not report `report_agent_turn_result` before the turn ended.",
                        @blocked_state
                      )

                    {:error, {:noop_turn, _summary}} ->
                      block_issue(
                        workspace,
                        issue,
                        :noop_turn,
                        "The turn produced no code change and no PR.",
                        @blocked_state
                      )

                    {:error, {:agent_blocked, %TurnResult{} = turn_result}} ->
                      block_issue(
                        workspace,
                        issue,
                        turn_result.blocker_type,
                        turn_result.summary,
                        @blocked_state
                      )

                    {:error, reason} ->
                      cond do
                        retryable_implementation_error?(reason) ->
                          handle_implementation_turn_error(
                            app_session,
                            workspace,
                            issue,
                            recipient,
                            fetcher,
                            max_turns,
                            state,
                            opts,
                            reason
                          )

                        non_retryable_implementation_error?(reason) ->
                          block_issue(
                            workspace,
                            issue,
                            implementation_error_code(reason),
                            implementation_turn_error_summary(reason),
                            @blocked_state
                          )

                        true ->
                          {:error, reason}
                      end
                  end
              end
            after
              clear_turn_result(issue)
              clear_turn_runtime_errors(issue)
            end
          end
      end
    end
  end

  defp persist_preflight_review(workspace, state, claims, threads) do
    with :ok <- execution_guard(workspace) do
      if claims != Map.get(state, :review_claims, %{}) or threads != Map.get(state, :review_threads, %{}) do
        update_state(workspace, %{review_claims: claims, review_threads: threads})
      else
        {:ok, state}
      end
    end
  end

  defp handle_validate(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    with :ok <- execution_guard(workspace, issue),
         :ok <- validation_attempt_available(workspace, issue, state),
         state when is_map(state) <- ReviewClaims.maybe_persist_reconciled_review_feedback(state, workspace, opts),
         :ok <- execution_guard(workspace, issue),
         {:ok, gate_context} <- AgentExecution.entry_context(workspace, issue),
         gate_ledger = capture_gate_ledger(gate_context),
         {:ok, state} <- update_state(workspace, %{validation_attempts: Map.get(state, :validation_attempts, 0) + 1}),
         validation_result <- RunInspector.run_validation(workspace, inspection.harness, opts),
         :ok <- retain_validation_observation(workspace, validation_result),
         :ok <- execution_guard(workspace, issue),
         result when is_map(result) <- validation_result do
      validation_attempts = Map.get(state, :validation_attempts, 0)

      record_gate_event!(gate_ledger, "validation.completed", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        stage: "validate",
        actor_type: "runtime",
        actor_id: "delivery_engine",
        policy_class: Map.get(state, :effective_policy_class),
        summary: "Validation #{result.status}",
        details: String.slice(to_string(result.output || ""), 0, 500),
        metadata: %{
          command: result.command,
          status: result.status,
          exit_code: result.exit_code,
          attempt: validation_attempts,
          workspace: workspace,
          gate_id: result.gate_id,
          gate: gate_result_to_map(result)
        }
      })

      case result.status do
        :passed ->
          with {:ok, artifacts} <-
                 run_validation_artifacts(workspace, issue, state, inspection.harness, validation_attempts, opts),
               resume_attrs when is_map(resume_attrs) <-
                 resume_context_attrs(
                   workspace,
                   issue,
                   state,
                   inspection,
                   %{
                     last_validation_summary: summarized_command_output(result.output, 800),
                     next_objective: "Review validation output and confirm behavior against acceptance criteria."
                   },
                   opts
                 ),
               {:ok, _persisted_state} <-
                 transition_state(
                   workspace,
                   "verify",
                   Map.merge(
                     %{
                       validation_attempts: validation_attempts,
                       last_validation:
                         result
                         |> gate_result_to_map()
                         |> Map.put(:exit_code, result.exit_code)
                         |> Map.put(:artifacts, artifacts)
                     },
                     resume_attrs
                   )
                 ),
               :ok <- execution_guard(workspace, issue) do
            do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
          end

        :failed ->
          if Config.policy_retry_validation_failures_within_run?() and
               validation_attempts < Config.policy_max_validation_attempts_per_run() and
               Map.get(state, :implementation_turns, 0) < max_turns do
            with resume_attrs when is_map(resume_attrs) <-
                   resume_context_attrs(
                     workspace,
                     issue,
                     state,
                     inspection,
                     %{
                       last_validation_summary: summarized_command_output(result.output, 800),
                       next_objective: "Address the latest validation failure without rerunning the full repo validation in implement."
                     },
                     opts
                   ),
                 {:ok, _persisted_state} <-
                   transition_state(
                     workspace,
                     "implement",
                     Map.merge(
                       %{
                         validation_attempts: validation_attempts,
                         last_validation: gate_result_to_map(result)
                       },
                       resume_attrs
                     )
                   ),
                 :ok <- execution_guard(workspace, issue) do
              do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
            end
          else
            block_issue(workspace, issue, :validation_failed, result.output, @blocked_state, %{ledger: gate_ledger, result: result})
          end

        :unavailable ->
          block_issue(workspace, issue, :validation_unavailable, result.output, @blocked_state, %{ledger: gate_ledger, result: result})
      end
    end
  end

  defp run_validation_artifacts(workspace, issue, state, harness, attempt, opts) do
    with :ok <- execution_guard(workspace, issue),
         {:ok, gate_context} <- AgentExecution.entry_context(workspace, issue),
         gate_ledger = capture_gate_ledger(gate_context),
         result <- RunInspector.run_artifacts(workspace, harness, opts),
         :ok <- execution_guard(workspace, issue) do
      event =
        record_gate_event!(gate_ledger, "artifacts.completed", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          stage: "validate",
          actor_type: "runtime",
          actor_id: "delivery_engine",
          policy_class: Map.get(state, :effective_policy_class),
          summary: "Artifacts #{result.status}",
          details: String.slice(to_string(result.output || ""), 0, 500),
          metadata: %{
            run_id: Map.get(state, :run_id),
            workspace: workspace,
            command: result.command,
            status: result.status,
            exit_code: result.exit_code,
            attempt: attempt,
            gate_id: result.gate_id,
            gate: gate_result_to_map(result)
          }
        })

      case result.status do
        :passed ->
          {:ok,
           result
           |> gate_result_to_map()
           |> Map.put(:exit_code, result.exit_code)
           |> Map.put(:ledger_event_id, event.event_id)}

        :failed ->
          block_issue(workspace, issue, :artifacts_failed, result.output, @blocked_state, %{ledger: gate_ledger, result: result})

        :unavailable ->
          block_issue(workspace, issue, :artifacts_unavailable, result.output, @blocked_state, %{ledger: gate_ledger, result: result})
      end
    end
  end

  defp handle_review_verification(
         _app_session,
         workspace,
         issue,
         _recipient,
         _fetcher,
         _max_turns,
         state,
         inspection,
         opts
       ) do
    with :ok <- execution_guard(workspace, issue),
         state when is_map(state) <- ReviewClaims.maybe_persist_reconciled_review_feedback(state, workspace, opts),
         :ok <- execution_guard(workspace, issue),
         collection <- ReviewEvidenceCollector.collect(Map.get(state, :review_claims, %{}), workspace),
         :ok <- execution_guard(workspace, issue),
         {updated_claims, stats} when is_map(updated_claims) and is_map(stats) <- collection,
         updated_threads when is_map(updated_threads) <-
           ReviewClaims.sync_review_claims_into_threads(Map.get(state, :review_threads, %{}), updated_claims)
           |> ReviewClaims.maybe_post_autonomous_review_replies(
             workspace,
             Map.get(state, :pr_url),
             state,
             opts
           ),
         :ok <- execution_guard(workspace, issue) do
      return_stage = Map.get(state, :review_return_stage) || "await_checks"

      {target_stage, summary, next_objective} =
        cond do
          stats.accepted_count > 0 ->
            {
              "implement",
              "Focused review verification confirmed #{stats.accepted_count} actionable PR review claim(s). Returning to implement.",
              ReviewClaims.accepted_review_next_objective(updated_claims)
            }

          stats.pending_count > 0 ->
            {
              return_stage,
              "Focused review verification found #{stats.pending_count} plausible PR review claim(s), but not enough hard proof to reopen implementation automatically. Returning to #{return_stage}.",
              "Wait for stronger proof, a narrower reproducer, or new review evidence before reopening implementation."
            }

          stats.insufficient_count > 0 or stats.contradicted_count > 0 ->
            {
              return_stage,
              "Focused review verification did not find enough evidence to reopen implementation. Returning to #{return_stage}.",
              "Wait for new review evidence or status changes before reopening implementation."
            }

          true ->
            {
              return_stage,
              "No pending PR review claims required focused verification. Returning to #{return_stage}.",
              "Continue the passive review/check state unless new review feedback arrives."
            }
        end

      RunLedger.record("review.verification_completed", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        stage: "review_verification",
        actor_type: "runtime",
        actor_id: "delivery_engine",
        policy_class: Map.get(state, :effective_policy_class),
        summary: summary,
        details: ReviewEvidenceCollector.summary(updated_claims),
        metadata: %{
          accepted_count: stats.accepted_count,
          contradicted_count: stats.contradicted_count,
          insufficient_count: stats.insufficient_count,
          return_stage: return_stage,
          target_stage: target_stage
        }
      })

      with resume_attrs when is_map(resume_attrs) <-
             resume_context_attrs(
               workspace,
               issue,
               state,
               inspection,
               %{
                 review_feedback_summary: ReviewClaims.actionable_review_claim_summary(updated_claims),
                 review_claim_summary: ReviewClaims.actionable_review_claim_summary(updated_claims),
                 next_objective: next_objective,
                 token_pressure: if(stats.accepted_count > 0, do: "high", else: nil)
               },
               opts
             ),
           {:ok, _persisted_state} <-
             transition_state(
               workspace,
               target_stage,
               Map.merge(
                 %{
                   review_claims: updated_claims,
                   review_threads: updated_threads,
                   last_decision_summary: summary,
                   next_human_action: nil
                 },
                 resume_attrs
               )
             ),
           :ok <- execution_guard(workspace, issue) do
        {:stop, :review_verification_completed}
      end
    end
  end

  defp handle_verify(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    verifier_runner =
      if Config.policy_require_verifier?(),
        do: Keyword.get(opts, :verifier_runner, &VerifierRunner.verify/5),
        else: &VerifierRunner.verify_without_agent/5

    with :ok <- execution_guard(workspace, issue),
         :ok <- verification_attempt_available(workspace, issue, state),
         {:ok, state} <- validation_for_verification(workspace, issue, state, inspection, opts),
         {:ok, gate_context} <- AgentExecution.entry_context(workspace, issue),
         gate_ledger = capture_gate_ledger(gate_context),
         verifier_result <- verifier_runner.(workspace, issue, state, inspection, opts),
         :ok <- execution_guard(workspace, issue),
         result when is_map(result) <- verifier_result do
      result = consistent_verifier_result(result)
      verification_attempts = Map.get(state, :verification_attempts, 0) + 1

      verifier_summary =
        Map.get(result, :summary) || Map.get(result, "summary") || inspect(result)

      record_gate_event!(gate_ledger, "verification.completed", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        stage: "verify",
        actor_type: "runtime",
        actor_id: "delivery_engine",
        policy_class: Map.get(state, :effective_policy_class),
        summary: verifier_summary,
        details: verifier_summary,
        metadata: %{
          verdict: Map.get(result, :verdict) || Map.get(result, "verdict"),
          attempt: verification_attempts,
          gate: Map.get(result, :smoke) || Map.get(result, "smoke")
        }
      })

      case Map.get(result, :verdict) || Map.get(result, "verdict") do
        "pass" ->
          verifier_map = verifier_result_to_map(result)

          with :ok <- require_current_evidence(workspace, issue, :publish),
               resume_attrs when is_map(resume_attrs) <-
                 resume_context_attrs(
                   workspace,
                   issue,
                   state,
                   inspection,
                   %{
                     last_verifier_summary: summarized_text(verifier_summary, 800),
                     next_objective: "Publish the verified branch and attach the PR."
                   },
                   opts
                 ),
               {:ok, _persisted_state} <-
                 transition_state(
                   workspace,
                   "publish",
                   Map.merge(
                     %{
                       verification_attempts: verification_attempts,
                       last_verifier: verifier_map,
                       last_verifier_verdict: "pass",
                       acceptance_summary:
                         get_in(result, [:acceptance, :summary]) ||
                           get_in(result, ["acceptance", "summary"]),
                       ui_proof_required_checks: ui_proof_required_checks(verifier_map)
                     },
                     resume_attrs
                   )
                 ),
               :ok <- execution_guard(workspace, issue) do
            do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
          end

        "needs_more_work" ->
          reason_code = Map.get(result, :reason_code) || Map.get(result, "reason_code")

          if should_retry_verification?(reason_code, verification_attempts, state, max_turns) do
            with resume_attrs when is_map(resume_attrs) <-
                   resume_context_attrs(
                     workspace,
                     issue,
                     state,
                     inspection,
                     %{
                       last_verifier_summary: summarized_text(verifier_summary, 800),
                       next_objective: verifier_retry_objective(result)
                     },
                     opts
                   ),
                 {:ok, _persisted_state} <-
                   transition_state(
                     workspace,
                     "implement",
                     Map.merge(
                       %{
                         verification_attempts: verification_attempts,
                         last_verifier: verifier_result_to_map(result),
                         last_verifier_verdict: "needs_more_work",
                         acceptance_summary:
                           get_in(result, [:acceptance, :summary]) ||
                             get_in(result, ["acceptance", "summary"])
                       },
                       resume_attrs
                     )
                   ),
                 :ok <- execution_guard(workspace, issue) do
              do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
            end
          else
            stop_reason =
              cond do
                reason_code == "behavior_proof_missing" -> :behavior_proof_missing
                reason_code == "ui_proof_missing" -> :ui_proof_missing
                true -> :verifier_failed
              end

            block_issue(
              workspace,
              issue,
              stop_reason,
              get_in(result, [:summary]) || get_in(result, ["summary"]) || inspect(result),
              @blocked_state,
              verification_gate_observation(result, gate_ledger)
            )
          end

        "blocked" ->
          block_issue(
            workspace,
            issue,
            :verifier_blocked,
            get_in(result, [:summary]) || get_in(result, ["summary"]) || inspect(result),
            @blocked_state,
            verification_gate_observation(result, gate_ledger)
          )

        "unsafe_to_merge" ->
          block_issue(
            workspace,
            issue,
            :unsafe_to_merge,
            get_in(result, [:summary]) || get_in(result, ["summary"]) || inspect(result),
            @blocked_state,
            verification_gate_observation(result, gate_ledger)
          )

        other ->
          block_issue(
            workspace,
            issue,
            :verifier_failed,
            "Verifier returned an unknown verdict: #{inspect(other)}",
            @blocked_state,
            verification_gate_observation(result, gate_ledger)
          )
      end
    end
  end

  defp validation_attempt_available(workspace, issue, state) do
    if Map.get(state, :validation_attempts, 0) < Config.policy_max_validation_attempts_per_run(),
      do: :ok,
      else: block_issue(workspace, issue, :validation_failed, "The existing validation attempt budget is exhausted.", @blocked_state)
  end

  defp retain_validation_observation(workspace, result) do
    case AgentExecution.current_context() do
      {:ok, _context} -> AgentExecution.observe_validation(workspace, result)
      {:error, :execution_context_missing} -> :ok
    end
  end

  defp verification_attempt_available(workspace, issue, state) do
    case AgentExecution.current_context() do
      {:error, :execution_context_missing} ->
        :ok

      {:ok, _context} ->
        if Map.get(state, :verification_attempts, 0) < Config.policy_max_validation_attempts_per_run(),
          do: :ok,
          else: block_issue(workspace, issue, :verifier_blocked, "The existing verification attempt budget is exhausted.", @blocked_state)
    end
  end

  defp validation_for_verification(workspace, issue, state, inspection, opts) do
    case AgentExecution.current_context() do
      {:error, :execution_context_missing} -> {:ok, state}
      {:ok, _context} -> current_worker_validation(workspace, issue, state, inspection, opts)
    end
  end

  defp current_worker_validation(workspace, issue, state, inspection, opts) do
    with {:ok, observed} <- AgentExecution.validation_observation() do
      cond do
        not Config.policy_require_validation?() ->
          {:ok, state}

        match?(%{status: :passed}, observed) ->
          {:ok, state}

        Map.get(state, :validation_attempts, 0) >= Config.policy_max_validation_attempts_per_run() ->
          block_issue(workspace, issue, :validation_failed, "Current-worker validation is required, but its existing attempt budget is exhausted.", @blocked_state)

        true ->
          with {:ok, gate_context} <- AgentExecution.entry_context(workspace, issue),
               gate_ledger = capture_gate_ledger(gate_context),
               result = RunInspector.run_validation(workspace, inspection.harness, opts),
               :ok <- AgentExecution.observe_validation(workspace, result),
               {:ok, persisted} <- update_state(workspace, %{validation_attempts: Map.get(state, :validation_attempts, 0) + 1, last_validation: gate_result_to_map(result)}) do
            record_gate_event!(gate_ledger, "validation.completed", %{
              issue_id: issue.id,
              issue_identifier: issue.identifier,
              stage: "validate",
              actor_type: "runtime",
              actor_id: "delivery_engine",
              summary: "Validation #{result.status}",
              metadata: %{workspace: workspace, attempt: persisted.validation_attempts, consumer: "reverification", gate_id: result.gate_id, gate: gate_result_to_map(result)}
            })

            case result.status do
              :passed ->
                with {:ok, artifacts} <-
                       run_validation_artifacts(workspace, issue, persisted, inspection.harness, persisted.validation_attempts, opts),
                     {:ok, persisted} <-
                       update_state(workspace, %{
                         last_validation:
                           result
                           |> gate_result_to_map()
                           |> Map.put(:exit_code, result.exit_code)
                           |> Map.put(:artifacts, artifacts)
                       }) do
                  {:ok, persisted}
                end

              :failed ->
                block_issue(workspace, issue, :validation_failed, "Current-worker validation failed during explicit reverification.", @blocked_state, %{ledger: gate_ledger, result: result})

              :unavailable ->
                block_issue(workspace, issue, :validation_unavailable, "Current-worker validation is unavailable during explicit reverification.", @blocked_state, %{
                  ledger: gate_ledger,
                  result: result
                })
            end
          end
      end
    end
  end

  defp consistent_verifier_result(result) do
    if (Map.get(result, :verdict) || Map.get(result, "verdict")) == "pass" and
         (Map.get(result, :acceptance_gaps) || Map.get(result, "acceptance_gaps") || []) != [] do
      %{
        verdict: "blocked",
        reason_code: "verifier_pass_with_acceptance_gaps",
        summary: "Verifier reported pass with unresolved acceptance gaps.",
        acceptance_gaps: [],
        risky_areas: [],
        evidence: [],
        raw_output: nil,
        smoke: Map.get(result, :smoke) || Map.get(result, "smoke")
      }
    else
      result
    end
  end

  defp require_current_evidence(workspace, issue, effect) do
    case EvidenceAcceptance.current(workspace) do
      {:ok, handle} -> guard_evidence_effect(workspace, issue, handle, effect)
      {:error, reason} -> block_evidence(workspace, issue, reason)
      {:stop, _} = terminal -> terminal
    end
  end

  defp evidence_for_effect(workspace, issue, state, inspection, opts, effect) do
    case EvidenceAcceptance.current(workspace) do
      {:ok, handle} -> {:ok, state, handle}
      {:error, :evidence_reverification_required} -> reverify_for_effect(workspace, issue, state, inspection, opts, effect)
      {:error, reason} -> block_evidence(workspace, issue, reason)
      {:stop, _} = terminal -> terminal
    end
  end

  defp guard_evidence_effect(workspace, issue, handle, effect) do
    case EvidenceAcceptance.before_effect(workspace, handle, effect) do
      :ok -> :ok
      {:error, reason} -> block_evidence(workspace, issue, reason)
      {:stop, _} = terminal -> terminal
    end
  end

  defp block_evidence(workspace, issue, reason) do
    block_issue(workspace, issue, :verifier_blocked, "Current verification evidence denied a positive effect: #{EvidenceAcceptance.failure_code(reason)}.", @blocked_state)
  end

  defp block_publication_error(workspace, issue, {:evidence_rejected, reason}), do: block_evidence(workspace, issue, reason)
  defp block_publication_error(workspace, issue, reason), do: block_issue(workspace, issue, :publish_failed, inspect(reason), @blocked_state)

  defp reverify_for_effect(workspace, issue, state, inspection, opts, effect) do
    if Map.get(state, :verification_attempts, 0) >= Config.policy_max_validation_attempts_per_run() do
      block_issue(workspace, issue, :verifier_blocked, "Current-worker reverification is required, but its existing attempt budget is exhausted.", @blocked_state)
    else
      with {:ok, state} <- current_worker_validation(workspace, issue, state, inspection, opts),
           {:ok, gate_context} <- AgentExecution.entry_context(workspace, issue),
           gate_ledger = capture_gate_ledger(gate_context),
           result when is_map(result) <- run_current_verification(workspace, issue, state, inspection, opts),
           result = consistent_verifier_result(result),
           {:ok, persisted} <-
             update_state(workspace, %{
               verification_attempts: Map.get(state, :verification_attempts, 0) + 1,
               last_verifier: verifier_result_to_map(result),
               last_verifier_verdict: result.verdict
             }) do
        record_gate_event!(gate_ledger, "verification.completed", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          stage: state.stage,
          actor_type: "runtime",
          actor_id: "delivery_engine",
          summary: result.summary,
          metadata: %{verdict: result.verdict, attempt: persisted.verification_attempts, consumer: effect, gate: Map.get(result, :smoke)}
        })

        case result.verdict do
          "pass" ->
            with :ok <- require_current_evidence(workspace, issue, effect), {:ok, handle} <- EvidenceAcceptance.current(workspace), do: {:ok, persisted, handle}

          _negative ->
            cause =
              case result[:reason_code] do
                "behavior_proof_missing" -> :behavior_proof_missing
                "ui_proof_missing" -> :ui_proof_missing
                _other -> if(result.verdict == "unsafe_to_merge", do: :unsafe_to_merge, else: :verifier_blocked)
              end

            block_issue(workspace, issue, cause, result.summary, @blocked_state, verification_gate_observation(result, gate_ledger))
        end
      end
    end
  end

  defp run_current_verification(workspace, issue, state, inspection, opts) do
    opts = Keyword.put(opts, :evidence_reentry, true)

    if Config.policy_require_verifier?(),
      do: VerifierRunner.verify(workspace, issue, state, inspection, opts),
      else: VerifierRunner.verify_without_agent(workspace, issue, state, inspection, opts)
  end

  defp should_retry_verification?(reason_code, verification_attempts, state, max_turns) do
    Config.policy_retry_validation_failures_within_run?() and
      verification_attempts < Config.policy_max_validation_attempts_per_run() and
      Map.get(state, :implementation_turns, 0) < max_turns and
      (reason_code not in ["behavior_proof_missing", "ui_proof_missing"] or
         verification_attempts < 2)
  end

  defp handle_publish(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    with :ok <- execution_guard(workspace, issue),
         state when is_map(state) <- ReviewClaims.maybe_persist_reconciled_review_feedback(state, workspace, opts) do
      if Config.policy_publish_required?() do
        with {:publication_snapshot, :ok} <- {:publication_snapshot, ensure_delivery_entry_readable(workspace, issue)},
             gate_result <- maybe_enforce_agent_harness_publish_gate(workspace, issue, inspection.harness, opts),
             :ok <- execution_guard(workspace, issue),
             :ok <- gate_result,
             publication_result <- PullRequestManager.validate_publication(workspace, issue, state, opts),
             :ok <- execution_guard(workspace, issue),
             {:publication_preflight, {:ok, _validation}} <- {:publication_preflight, publication_result},
             {:ok, state, evidence_handle} <- evidence_for_effect(workspace, issue, state, inspection, opts, :publish),
             opts = Keyword.put(opts, :evidence_handle, evidence_handle),
             commit_result <-
               GitManager.commit_all(
                 workspace,
                 issue,
                 get_in(state, [:last_turn_result, :summary]) || issue.title || "Automated update",
                 opts
               ),
             :ok <- execution_guard(workspace, issue) do
          case commit_result do
            {:stop, _} = terminal ->
              terminal

            {:ok, :noop} ->
              with :ok <- execution_guard(workspace, issue),
                   missing_changes <- is_nil(inspection.pr_url) and not branch_has_publishable_changes?(workspace, state, opts),
                   :ok <- execution_guard(workspace, issue) do
                if missing_changes do
                  block_issue(
                    workspace,
                    issue,
                    :noop_turn,
                    "No commit and no PR were produced for publish.",
                    @blocked_state
                  )
                else
                  publish_after_commit(
                    app_session,
                    workspace,
                    issue,
                    recipient,
                    fetcher,
                    max_turns,
                    state,
                    opts
                  )
                end
              end

            {:ok, %{sha: sha}} ->
              with :ok <- execution_guard(workspace, issue),
                   branch when is_binary(branch) <- Map.get(state, :branch) || inspection.branch,
                   push_result <- GitManager.push_branch(workspace, branch, opts),
                   :ok <- execution_guard(workspace, issue),
                   :ok <- push_result,
                   {:ok, state} <-
                     update_state(workspace, %{last_commit_sha: sha}) do
                publish_after_commit(
                  app_session,
                  workspace,
                  issue,
                  recipient,
                  fetcher,
                  max_turns,
                  state,
                  opts
                )
              else
                {:stop, _} = terminal ->
                  terminal

                {:error, reason} ->
                  block_publication_error(workspace, issue, reason)

                _ ->
                  block_issue(
                    workspace,
                    issue,
                    :publish_failed,
                    "Unable to determine branch for publish.",
                    @blocked_state
                  )
              end

            {:error, reason} ->
              block_publication_error(workspace, issue, reason)
          end
        else
          {:stop, _} = terminal ->
            terminal

          {:publication_snapshot, {:stop, _} = terminal} ->
            terminal

          {:publication_snapshot, {:error, reason}} ->
            Logger.error("Publication blocked by unreadable snapshot issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
            {:stop, reason}

          {:publication_preflight, {:error, reason}} ->
            block_publication_error(workspace, issue, reason)

          {:error, reason} ->
            block_issue(
              workspace,
              issue,
              :harness_publish_gate_failed,
              inspect(reason),
              @blocked_state
            )
        end
      else
        with {:ok, _state, _evidence_handle} <- evidence_for_effect(workspace, issue, state, inspection, opts, :publish),
             {:ok, _persisted_state} <- transition_state(workspace, @publish_followup_stage, %{}),
             :ok <- execution_guard(workspace, issue) do
          do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
        end
      end
    end
  end

  defp publish_after_commit(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         opts
       ) do
    prepared_review_threads =
      Map.get(state, :review_threads, %{})
      |> ReviewClaims.finalize_published_review_threads()

    with :ok <- execution_guard(workspace, issue),
         pr_result <- PullRequestManager.ensure_pull_request(workspace, issue, state, opts),
         :ok <- execution_guard(workspace, issue),
         {:ok, pr} <- pr_result,
         :ok <- require_current_evidence(workspace, issue, :publish),
         posted_review_threads when is_map(posted_review_threads) <-
           prepared_review_threads
           |> ReviewClaims.maybe_post_autonomous_review_replies(
             workspace,
             pr.url,
             state,
             opts
           ),
         :ok <- require_current_evidence(workspace, issue, :publish),
         finalized_review_threads when is_map(finalized_review_threads) <-
           ReviewClaims.maybe_resolve_autonomous_review_threads(
             posted_review_threads,
             workspace,
             pr.url,
             state,
             opts
           ),
         :ok <- execution_guard(workspace, issue),
         :ok <- require_current_evidence(workspace, issue, :publish),
         move_result <- maybe_move_issue(issue, @merging_state),
         :ok <- execution_guard(workspace, issue),
         :ok <- move_result,
         {:ok, state} <-
           transition_state(workspace, @publish_followup_stage, %{
             pr_url: pr.url,
             review_threads: finalized_review_threads,
             publish_attempts: Map.get(state, :publish_attempts, 0) + 1,
             await_checks_polls: 0,
             last_pr_body_validation: Map.get(pr, :body_validation)
           }),
         :ok <- execution_guard(workspace, issue) do
      RunLedger.record("publish.completed", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        stage: "publish",
        actor_type: "runtime",
        actor_id: "delivery_engine",
        policy_class: Map.get(state, :effective_policy_class),
        summary: "Published PR #{pr.url}",
        details: "PR is open and attached to the issue.",
        metadata: %{
          pr_url: pr.url,
          pr_state: Map.get(pr, :state)
        }
      })

      do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
    else
      {:stop, _} = terminal ->
        terminal

      {:error, reason} ->
        block_publication_error(workspace, issue, reason)
    end
  end

  defp handle_await_checks(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    if ReviewClaims.merge_readiness_maintenance_needed?(state, inspection) do
      with {:ok, _persisted_state} <-
             transition_state(workspace, @publish_followup_stage, %{
               pr_url: Map.get(state, :pr_url) || Map.get(inspection, :pr_url),
               review_threads: Map.get(state, :review_threads, %{}),
               last_pr_body_validation: Map.get(state, :last_pr_body_validation),
               last_ci_failure: Map.get(state, :last_ci_failure),
               await_checks_polls: Map.get(state, :await_checks_polls, 0)
             }),
           :ok <- execution_guard(workspace, issue) do
        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
      end
    else
      poll_await_checks(app_session, workspace, issue, recipient, fetcher, max_turns, state, inspection, opts)
    end
  end

  defp poll_await_checks(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    await_checks_polls = Map.get(state, :await_checks_polls, 0) + 1
    required_checks = effective_required_checks(inspection, state)

    check_rollup =
      RunInspector.required_checks_rollup(required_checks, inspection.check_statuses)

    await_checks_attrs = await_checks_state_attrs(inspection, check_rollup, await_checks_polls)

    with {:ok, policy_resolution, state} <- resolve_policy(issue, state, workspace),
         :ok <- execution_guard(workspace, issue) do
      effective_policy_class = IssuePolicy.class_to_string(policy_resolution.class)

      workflow_profile =
        WorkflowProfile.resolve(
          effective_policy_class,
          policy_pack: Map.get(state, :policy_pack)
        )

      RunLedger.record("checks.polled", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        stage: "await_checks",
        actor_type: "runtime",
        actor_id: "delivery_engine",
        policy_class: effective_policy_class,
        summary: "Checks state #{check_rollup.state}",
        details: inspection.pr_url || "No PR URL",
        metadata: %{
          poll_count: await_checks_polls,
          pr_url: inspection.pr_url,
          required_state: check_rollup.state,
          missing: check_rollup.missing,
          pending: check_rollup.pending,
          failed: check_rollup.failed,
          cancelled: check_rollup.cancelled
        }
      })

      risk_result =
        if RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :automerge do
          risk_review_required?(workspace, inspection, workflow_profile, state)
        else
          false
        end

      with risk_review_required when is_boolean(risk_review_required) <- risk_result do
        cond do
          is_nil(inspection.pr_url) ->
            block_issue(
              workspace,
              issue,
              :publish_missing_pr,
              "No PR is attached for the current branch.",
              @blocked_state
            )

          merged_pull_request?(inspection) ->
            with {:ok, _persisted_state} <-
                   transition_state(
                     workspace,
                     "post_merge",
                     Map.merge(await_checks_attrs, %{
                       last_merge: %{status: :already_merged, url: inspection.pr_url}
                     })
                   ),
                 :ok <- execution_guard(workspace, issue) do
              do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
            end

          closed_pull_request?(inspection) ->
            block_issue(
              workspace,
              issue,
              :pr_closed,
              "The PR closed before Symphony could merge it.",
              @blocked_state
            )

          check_rollup.state == :failed and ui_proof_checks_active?(state) and
              ui_proof_checks_failed?(state, check_rollup) ->
            block_issue(
              workspace,
              issue,
              :ui_proof_checks_failed,
              "Required UI proof checks failed on the PR: #{Enum.join(ui_proof_failed_checks(state, check_rollup), ", ")}",
              @blocked_state
            )

          check_rollup.state == :failed ->
            ci_fix_attempts = Map.get(state, :ci_fix_attempts, 0)

            if ci_fix_attempts < 2 do
              Logger.info("CI checks failed for #{issue.identifier}, retrying implement (attempt #{ci_fix_attempts + 1})")

              with {:ok, _persisted_state} <-
                     transition_state(
                       workspace,
                       "implement",
                       Map.merge(await_checks_attrs, %{
                         ci_fix_attempts: ci_fix_attempts + 1,
                         last_ci_failure: %{
                           failed_checks: check_rollup.failed,
                           pr_url: inspection.pr_url
                         },
                         resume_context: %{
                           next_objective:
                             "Fix the failing CI checks: #{Enum.join(check_rollup.failed, ", ")}. " <>
                               "Read the CI output, identify the errors, and fix them. " <>
                               "Common issues: mix format, missing @spec, dialyzer type errors, test failures."
                         }
                       })
                     ),
                   :ok <- execution_guard(workspace, issue) do
                do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
              end
            else
              block_issue(
                workspace,
                issue,
                :required_checks_failed,
                "Required checks failed after #{ci_fix_attempts} fix attempts: #{Enum.join(check_rollup.failed, ", ")}",
                @blocked_state
              )
            end

          check_rollup.state == :cancelled ->
            block_issue(
              workspace,
              issue,
              :required_checks_cancelled,
              "Required checks were cancelled on the PR: #{Enum.join(check_rollup.cancelled, ", ")}",
              @blocked_state
            )

          check_rollup.state == :missing and ui_proof_checks_active?(state) and
            ui_proof_checks_missing?(state, check_rollup) and
              await_checks_polls >= @await_checks_missing_limit ->
            block_issue(
              workspace,
              issue,
              :ui_proof_checks_missing,
              "Required UI proof checks never appeared on the PR: #{Enum.join(ui_proof_missing_checks(state, check_rollup), ", ")}",
              @blocked_state
            )

          check_rollup.state == :missing and await_checks_polls >= @await_checks_missing_limit ->
            block_issue(
              workspace,
              issue,
              :required_checks_missing,
              "Required checks never appeared on the PR: #{Enum.join(check_rollup.missing, ", ")}",
              @blocked_state
            )

          RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :automerge and
            risk_review_required and
              Map.get(state, :review_approved, false) == false ->
            hold_for_policy_review(
              workspace,
              issue,
              state,
              await_checks_attrs,
              :risk_review_required,
              inspection,
              opts
            )

          RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :automerge and
            Config.policy_automerge_on_green?() and
            Map.get(state, :automerge_disabled, false) == false and
              merge_window_deferred?(state) ->
            defer_for_merge_window(workspace, issue, await_checks_attrs, state)

          RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :automerge and
            Config.policy_automerge_on_green?() and
              Map.get(state, :automerge_disabled, false) == false ->
            with {:ok, _persisted_state} <- transition_state(workspace, "merge", await_checks_attrs),
                 :ok <- execution_guard(workspace, issue) do
              do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
            end

          RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :review_gate and
              Map.get(state, :review_approved, false) == true ->
            with {:ok, _persisted_state} <- transition_state(workspace, "merge", await_checks_attrs),
                 :ok <- execution_guard(workspace, issue) do
              do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
            end

          RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :review_gate ->
            hold_for_policy_review(
              workspace,
              issue,
              state,
              await_checks_attrs,
              :policy_review_required,
              inspection,
              opts
            )

          RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :manual_only ->
            hold_for_policy_review(
              workspace,
              issue,
              state,
              await_checks_attrs,
              :policy_never_automerge,
              inspection,
              opts
            )

          RunInspector.ready_for_merge?(inspection) ->
            hold_for_policy_review(
              workspace,
              issue,
              state,
              await_checks_attrs,
              :policy_review_required,
              inspection,
              opts
            )

          true ->
            with {:ok, _persisted_state} <- transition_state(workspace, "await_checks", await_checks_attrs),
                 :ok <- execution_guard(workspace, issue) do
              :ok
            end
        end
      end
    else
      {:stop, _} = terminal ->
        terminal

      {:error, %{code: code, labels: labels}} ->
        block_issue(workspace, issue, code, Enum.join(labels, ", "), @blocked_state)

      {:error, _} = error ->
        error
    end
  end

  defp handle_merge_readiness(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    case ReviewClaims.maybe_maintain_merge_readiness(workspace, issue, state, inspection, opts) do
      {:stop, _} = terminal ->
        terminal

      {:error, reason} ->
        block_issue(
          workspace,
          issue,
          :merge_readiness_failed,
          "Merge readiness maintenance failed: #{inspect(reason)}",
          @blocked_state
        )

      {:ok, updated_state} ->
        with {:ok, persisted_state} <-
               transition_state(workspace, "await_checks", %{
                 pr_url: Map.get(updated_state, :pr_url),
                 review_threads: Map.get(updated_state, :review_threads, %{}),
                 last_pr_body_validation: Map.get(updated_state, :last_pr_body_validation),
                 last_merge_readiness: Map.get(updated_state, :last_merge_readiness),
                 resume_context: Map.get(updated_state, :resume_context, %{}),
                 await_checks_polls: Map.get(updated_state, :await_checks_polls, 0)
               }),
             :ok <- execution_guard(workspace, issue),
             inspection <- RunInspector.inspect(workspace, opts),
             :ok <- execution_guard(workspace, issue) do
          Observability.with_stage("await_checks", issue_observability_metadata(issue, persisted_state), fn ->
            poll_await_checks(app_session, workspace, issue, recipient, fetcher, max_turns, persisted_state, inspection, opts)
          end)
        end
    end
  end

  @dialyzer {:nowarn_function, handle_merge: 9}
  defp handle_merge(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         inspection,
         opts
       ) do
    if merge_limit_reached?(state) do
      block_issue(
        workspace,
        issue,
        :max_merges_per_day_exceeded,
        "The configured daily merge cap for this repo has been reached.",
        @blocked_state
      )
    else
      cond do
        merged_pull_request?(inspection) ->
          with {:ok, _persisted_state} <-
                 transition_state(workspace, "post_merge", %{
                   pr_url: inspection.pr_url,
                   last_pr_state: inspection.pr_state,
                   last_merge: %{status: :already_merged, url: inspection.pr_url},
                   merge_attempts: Map.get(state, :merge_attempts, 0)
                 }),
               :ok <- execution_guard(workspace, issue) do
            do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
          end

        closed_pull_request?(inspection) ->
          block_issue(
            workspace,
            issue,
            :pr_closed,
            "The PR closed before Symphony could merge it.",
            @blocked_state
          )

        RunInspector.ready_for_merge?(inspection) ->
          with :ok <- execution_guard(workspace, issue),
               merge_result <- PullRequestManager.merge_pull_request(workspace, opts),
               :ok <- execution_guard(workspace, issue) do
            case merge_result do
              {:stop, _} = terminal ->
                terminal

              {:ok, %{url: url, status: merge_status} = merge_result} ->
                with {:ok, state} <-
                       transition_state(workspace, "post_merge", %{
                         pr_url: url,
                         merge_attempts: Map.get(state, :merge_attempts, 0) + 1,
                         last_pr_state: inspection.pr_state,
                         last_merge: %{
                           status: merge_status,
                           url: url,
                           output: String.slice(to_string(Map.get(merge_result, :output, "")), 0, 2_000)
                         }
                       }),
                     :ok <- execution_guard(workspace, issue) do
                  RunLedger.record("merge.completed", %{
                    issue_id: issue.id,
                    issue_identifier: issue.identifier,
                    stage: "merge",
                    actor_type: "runtime",
                    actor_id: "delivery_engine",
                    policy_class: Map.get(state, :effective_policy_class),
                    summary: "Merge status #{merge_status}",
                    details: url || "No PR URL",
                    metadata: %{
                      url: url,
                      status: merge_status
                    }
                  })

                  do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
                end

              {:error, reason} ->
                block_issue(workspace, issue, :merge_failed, inspect(reason), @blocked_state)
            end
          end

        true ->
          with {:ok, _persisted_state} <-
                 transition_state(
                   workspace,
                   "await_checks",
                   await_checks_state_attrs(
                     inspection,
                     RunInspector.required_checks_rollup(inspection),
                     Map.get(state, :await_checks_polls, 0)
                   )
                 ),
               :ok <- execution_guard(workspace, issue) do
            :ok
          end
      end
    end
  end

  defp handle_post_merge(workspace, issue, state, inspection, opts) do
    workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))

    with :ok <- execution_guard(workspace, issue),
         reset_result <- GitManager.reset_to_base(workspace, inspection.harness, opts),
         :ok <- execution_guard(workspace, issue),
         :ok <- reset_result,
         {:ok, state} <-
           maybe_post_merge_verify(
             workspace,
             issue,
             state,
             inspection.harness,
             Keyword.put(opts, :workflow_profile, workflow_profile)
           ),
         {:ok, state, result} <-
           maybe_begin_preview_deploy(
             workspace,
             issue,
             state,
             inspection.harness,
             workflow_profile,
             opts
           ) do
      case result do
        :continue ->
          finalize_done(workspace, issue, state)

        {:transitioned, "deploy_preview"} ->
          :ok
      end
    else
      {:stop, _} = terminal ->
        terminal

      {:error, :missing_preview_deploy} ->
        block_issue(
          workspace,
          issue,
          :deploy_preview_missing,
          "Preview deploy is enabled for this workflow profile but the repo harness does not declare `deploy.preview.command`.",
          @blocked_state
        )

      {:error, {:post_merge_rework, reason}} ->
        block_issue(workspace, issue, :post_merge_failed, inspect(reason), @rework_state)

      {:error, reason} ->
        block_issue(workspace, issue, :post_merge_failed, inspect(reason), @blocked_state)
    end
  end

  defp handle_deploy_preview(workspace, issue, state, inspection, opts) do
    case inspection.harness && inspection.harness.deploy_preview_command do
      nil ->
        block_issue(
          workspace,
          issue,
          :deploy_preview_missing,
          "Preview deploy is enabled for this workflow profile but the repo harness does not declare `deploy.preview.command`.",
          @blocked_state
        )

      command ->
        run_audited_deploy(workspace, issue, state, inspection.harness, "preview", command, opts)
    end
  end

  defp handle_deploy_production(workspace, issue, state, inspection, opts) do
    case inspection.harness && inspection.harness.deploy_production_command do
      nil ->
        block_issue(
          workspace,
          issue,
          :deploy_production_missing,
          "Production deploy is enabled for this workflow profile but the repo harness does not declare `deploy.production.command`.",
          @blocked_state
        )

      command ->
        if production_deploy_window_deferred?(state) do
          defer_for_production_deploy_window(workspace, issue, state)
        else
          run_audited_deploy(workspace, issue, state, inspection.harness, "production", command, opts)
        end
    end
  end

  defp run_audited_deploy(workspace, issue, state, harness, target, command, opts) do
    with {:ok, execution_context} <- AgentExecution.entry_context(workspace, issue),
         begin_result <-
           begin_deploy(execution_context, workspace, %{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             stage: "deploy_" <> target,
             command: command
           }),
         :ok <- execution_guard(workspace, issue),
         {:ok, ticket} <- begin_result,
         command_result <- run_deploy_command(target, workspace, harness, opts),
         :ok <- record_deploy_result(execution_context, ticket, issue, command_result),
         {:ok, _persisted_state, continuation, reply} <- continue_audited_deploy(ticket, issue, state, harness, target),
         :ok <- finish_deploy(execution_context, ticket, continuation) do
      reply
    else
      {:stop, _} = terminal ->
        terminal

      {:error, reason} = error ->
        Logger.error("Deployment remains unresolved issue_identifier=#{issue.identifier} target=#{target} reason=#{inspect(reason)}")

        error
    end
  end

  defp record_deploy_result(:legacy, ticket, issue, command_result) do
    with result when is_map(result) <- command_result,
         :ok <- DeployAudit.record_result(ticket, command_result_to_map(result)),
         :ok <- RunStateStore.ensure_deploy_current(ticket),
         :ok <- execution_guard(ticket.workspace, issue) do
      :ok
    end
  end

  defp record_deploy_result(execution_context, ticket, _issue, command_result) when is_map(execution_context) do
    with result when is_map(result) <- command_result,
         {:ok, _receipt} <- AgentExecution.record_deploy_result(ticket, command_result_to_map(result)) do
      :ok
    end
  end

  defp begin_deploy(:legacy, workspace, attrs), do: DeployAudit.begin(workspace, attrs)
  defp begin_deploy(context, workspace, attrs) when is_map(context), do: AgentExecution.begin_deploy(workspace, attrs)
  defp finish_deploy(:legacy, ticket, continuation), do: DeployAudit.finish(ticket, continuation)
  defp finish_deploy(context, ticket, continuation) when is_map(context), do: AgentExecution.finish_deploy(ticket, continuation)

  defp run_deploy_command("preview", workspace, harness, opts),
    do: RunInspector.run_deploy_preview(workspace, harness, opts)

  defp run_deploy_command("production", workspace, harness, opts),
    do: RunInspector.run_deploy_production(workspace, harness, opts)

  defp continue_audited_deploy(ticket, issue, state, harness, target) do
    if post_deploy_verification_required?(harness, WorkflowProfile.resolve(Map.get(state, :effective_policy_class))) do
      summary = String.capitalize(target) <> " deployment completed. Running post-deploy verification."

      with {:ok, persisted_state, continuation} <-
             transition_deploy_state(ticket, "post_deploy_verify", %{
               issue_source: issue.source,
               last_decision_summary: summary
             }) do
        {:ok, persisted_state, continuation, :ok}
      end
    else
      with :ok <- execution_guard(ticket.workspace, issue),
           :ok <- RunStateStore.ensure_deploy_current(ticket),
           move_result <- maybe_move_issue(issue, @done_state),
           :ok <- execution_guard(ticket.workspace, issue),
           :ok <- move_result,
           {:ok, persisted_state, continuation} <-
             transition_deploy_state(ticket, "done", %{
               issue_source: issue.source,
               last_decision_summary: finalization_summary(state),
               next_human_action: nil,
               stop_reason: nil
             }) do
        {:ok, persisted_state, continuation, {:done, issue}}
      end
    end
  end

  defp handle_post_deploy_verify(workspace, issue, state, inspection, opts) do
    with :ok <- execution_guard(workspace, issue),
         command_result <- RunInspector.run_post_deploy_verify(workspace, inspection.harness, opts),
         :ok <- execution_guard(workspace, issue),
         result when is_map(result) <- command_result do
      deploy_target = Map.get(state, :current_deploy_target, "preview")
      workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))

      case result.status do
        :passed ->
          with {:ok, state} <- update_state(workspace, %{last_post_deploy_verify: command_result_to_map(result), last_decision: nil}),
               :ok <- execution_guard(workspace, issue) do
            RunLedger.record("deploy.post_deploy.completed", %{
              issue_id: issue.id,
              issue_identifier: issue.identifier,
              stage: "post_deploy_verify",
              actor_type: "runtime",
              actor_id: "delivery_engine",
              summary: "Post-deploy verification passed",
              details: String.slice(to_string(result.output || ""), 0, 500),
              metadata: %{command: result.command, deploy_target: deploy_target}
            })

            case maybe_begin_production_deploy(
                   workspace,
                   issue,
                   state,
                   inspection.harness,
                   workflow_profile
                 ) do
              {:ok, persisted_state, :continue} ->
                finalize_done(workspace, issue, persisted_state)

              {:ok, _persisted_state, {:transitioned, "deploy_production"}} ->
                :ok

              {:ok, _persisted_state, {:waiting_for_approval, approval_state}} ->
                with {:ok, _persisted_state} <- update_state(workspace, %{deploy_approved: false, last_decision_summary: "Waiting in #{approval_state} before production deployment."}),
                     :ok <- execution_guard(workspace, issue) do
                  :ok
                end

              {:stop, _} = terminal ->
                terminal

              {:error, :missing_production_deploy} ->
                block_issue(
                  workspace,
                  issue,
                  :deploy_production_missing,
                  "Production deployment is enabled for this workflow profile but the repo harness does not declare `deploy.production.command`.",
                  @blocked_state
                )

              {:error, _} = error ->
                error
            end
          end

        _ ->
          block_issue(
            workspace,
            issue,
            :post_deploy_failed,
            to_string(result.output || ""),
            @blocked_state
          )
      end
    end
  end

  defp maybe_post_merge_verify(workspace, issue, state, harness, opts) do
    workflow_profile = Keyword.get(opts, :workflow_profile, WorkflowProfile.resolve(nil))

    if Config.policy_post_merge_verification_required?() and
         workflow_profile.post_merge_verification_required do
      with :ok <- execution_guard(workspace, issue),
           command_result <- VerifierRunner.post_merge_verify(workspace, harness, opts),
           :ok <- execution_guard(workspace, issue),
           %{status: status} = result <- command_result do
        case status do
          :passed ->
            with {:ok, state} <- update_state(workspace, %{last_post_merge: command_result_to_map(result), last_decision: nil}),
                 :ok <- execution_guard(workspace, issue) do
              RunLedger.record("post_merge.completed", %{
                issue_id: issue.id,
                issue_identifier: issue.identifier,
                stage: "post_merge",
                actor_type: "runtime",
                actor_id: "delivery_engine",
                summary: "Post-merge verification passed",
                details: String.slice(to_string(result.output || ""), 0, 500),
                metadata: %{command: result.command}
              })

              {:ok, state}
            end

          :failed ->
            {:error, {:post_merge_rework, result.output}}

          :unavailable ->
            {:error, {:post_merge_unavailable, result.output}}
        end
      end
    else
      with :ok <- execution_guard(workspace, issue), do: {:ok, state}
    end
  end

  defp finalization_summary(state) when is_map(state) do
    merge_url = get_in(state, [:last_merge, :url])
    post_merge_status = get_in(state, [:last_post_merge, :status])
    preview_status = get_in(state, [:last_deploy_preview, :status])
    production_status = get_in(state, [:last_deploy_production, :status])
    post_deploy_status = get_in(state, [:last_post_deploy_verify, :status])

    cond do
      is_binary(merge_url) and merge_url != "" and production_status == :passed and
          post_deploy_status == :passed ->
        "Autonomously finalized after merge, preview deployment, production deployment, and post-deploy verification passed (#{merge_url})."

      is_binary(merge_url) and merge_url != "" and preview_status == :passed and
          post_deploy_status == :passed ->
        "Autonomously finalized after merge, preview deployment, and post-deploy verification passed (#{merge_url})."

      is_binary(merge_url) and merge_url != "" and preview_status == :passed ->
        "Autonomously finalized after merge and preview deployment completed (#{merge_url})."

      is_binary(merge_url) and merge_url != "" and post_merge_status == :passed ->
        "Autonomously finalized after merge and post-merge verification passed (#{merge_url})."

      is_binary(merge_url) and merge_url != "" ->
        "Autonomously finalized after merge completed (#{merge_url})."

      post_merge_status == :passed ->
        "Autonomously finalized after post-merge verification passed."

      true ->
        "Autonomously finalized after merge and post-merge verification."
    end
  end

  defp maybe_begin_preview_deploy(workspace, issue, state, harness, workflow_profile, _opts) do
    cond do
      workflow_profile.preview_deploy_mode != :after_merge ->
        {:ok, state, :continue}

      is_nil(harness) or is_nil(harness.deploy_preview_command) ->
        {:error, :missing_preview_deploy}

      true ->
        with {:ok, state} <-
               transition_state(workspace, "deploy_preview", %{
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 issue_source: issue.source,
                 last_decision_summary: "Post-merge verification passed. Starting preview deployment.",
                 effective_policy_class: Map.get(state, :effective_policy_class)
               }),
             :ok <- execution_guard(workspace, issue) do
          {:ok, state, {:transitioned, "deploy_preview"}}
        end
    end
  end

  defp maybe_begin_production_deploy(workspace, issue, state, harness, workflow_profile) do
    cond do
      Map.get(state, :current_deploy_target) == "production" ->
        {:ok, state, :continue}

      workflow_profile.production_deploy_mode != :after_preview ->
        {:ok, state, :continue}

      is_nil(harness) or is_nil(harness.deploy_production_command) ->
        {:error, :missing_production_deploy}

      deploy_approval_required?(workflow_profile) and not Map.get(state, :deploy_approved, false) ->
        approval_state = workflow_profile.deploy_approval_gate_state

        with :ok <- execution_guard(workspace, issue),
             move_result <- maybe_move_issue(issue, approval_state),
             :ok <- execution_guard(workspace, issue),
             :ok <- move_result do
          RunLedger.record("deploy.production.awaiting_approval", %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            stage: "post_deploy_verify",
            actor_type: "runtime",
            actor_id: "delivery_engine",
            policy_class: Map.get(state, :effective_policy_class),
            summary: "Waiting in #{approval_state} before production deployment.",
            target_state: approval_state,
            metadata: %{approval_gate_state: approval_state}
          })

          {:ok, state, {:waiting_for_approval, approval_state}}
        end

      true ->
        with {:ok, state} <-
               transition_state(workspace, "deploy_production", %{
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 issue_source: issue.source,
                 last_decision_summary: "Post-deploy verification passed. Starting production deployment.",
                 effective_policy_class: Map.get(state, :effective_policy_class),
                 current_deploy_target: "production"
               }),
             :ok <- execution_guard(workspace, issue) do
          {:ok, state, {:transitioned, "deploy_production"}}
        end
    end
  end

  defp finalize_done(workspace, issue, state) do
    finalization_summary = finalization_summary(state)

    with :ok <- execution_guard(workspace, issue),
         move_result <- maybe_move_issue(issue, @done_state),
         :ok <- execution_guard(workspace, issue),
         :ok <- move_result,
         {:ok, _state} <-
           transition_state(workspace, "done", %{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             issue_source: issue.source,
             last_decision_summary: finalization_summary,
             next_human_action: nil,
             stop_reason: nil
           }) do
      {:done, issue}
    end
  end

  defp post_deploy_verification_required?(harness, workflow_profile) do
    workflow_profile.post_deploy_verification_required &&
      is_map(harness) &&
      is_binary(harness.post_deploy_verify_command) &&
      harness.post_deploy_verify_command != ""
  end

  defp maybe_enforce_agent_harness_publish_gate(workspace, issue, harness, opts) do
    if AgentHarness.enabled?(harness) do
      AgentHarness.publish_gate(workspace, issue, harness, opts)
    else
      :ok
    end
  end

  defp deploy_approval_required?(workflow_profile) do
    case workflow_profile.deploy_approval_gate_state do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp implement_prompt(issue, state, workspace, inspection, _opts, turn_number, max_turns) do
    acceptance = IssueAcceptance.from_issue(issue)

    with resume_context when is_map(resume_context) <- resume_context_for_prompt(workspace, issue, state, inspection) do
      token_pressure = token_pressure_note(resume_context)
      repo_map = RepoMap.from_harness(inspection.harness)
      workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))

      focused_review_claims =
        ReviewClaims.focused_review_claims(
          Map.get(state, :review_claims, %{}),
          focused_review_claim_limit(state)
        )

      prompt_lines =
        cond do
          review_fix_budget_mode?(resume_context) ->
            [
              "You are implementing ticket `#{issue.identifier}`.",
              "",
              "Title: #{to_string(issue.title || "Untitled issue")}",
              repo_platform_note(inspection),
              "Current implementation turn: #{turn_number} of #{max_turns}.",
              "",
              "This is a scoped review-fix turn. Do not rediscover the issue or rescan the repo.",
              "Resolved workflow profile: #{WorkflowProfile.name_string(workflow_profile)} (merge mode #{workflow_profile.merge_mode}).",
              maybe_named_line("PR under review", Map.get(state, :pr_url), 200),
              "",
              "Review-fix rules:",
              "- Touch only the files directly related to the current scope ids unless a directly adjacent helper must change to make the fix compile.",
              "- Do not rescan unrelated files, docs, or tests.",
              "- Do not run full validation, smoke, build, or test commands during `implement`.",
              "- Limit shell usage to narrow reads of the target files and minimal diff/status checks.",
              "- Keep command output small. Do not stream long logs or dump large files into the turn.",
              "- If you complete this scope but additional verified review claims or failed checks remain, set `needs_another_turn=true`.",
              "- Focus on writing code. Symphony will track your changes automatically.",
              "",
              "Resume context:",
              resume_context_block(resume_context),
              token_pressure,
              "",
              "Exact next objective:",
              review_fix_next_objective(resume_context) ||
                resume_context[:next_objective] ||
                "Advance the current diff toward validation with the smallest complete code change set possible."
            ]

          broad_implement_budget_mode?(resume_context) ->
            [
              "You are implementing ticket `#{issue.identifier}`.",
              "",
              "Title: #{to_string(issue.title || "Untitled issue")}",
              repo_platform_note(inspection),
              "Current implementation turn: #{turn_number} of #{max_turns}.",
              "",
              "This is a narrow broad-implement retry. Do not rediscover the whole repo or restate the full issue.",
              "Resolved workflow profile: #{WorkflowProfile.name_string(workflow_profile)} (merge mode #{workflow_profile.merge_mode}).",
              maybe_broad_retry_issue_brief(issue, resume_context),
              "",
              "Broad-budget retry rules:",
              "- First identify the smallest code path that can advance the ticket and limit the turn to that exact file.",
              "- If that file is insufficient, name one exact next file instead of broadening the retry heuristically.",
              "- Do not rescan the full repo, reread long docs, or dump broad diffs.",
              "- Prefer 1 to 3 targeted file reads before editing.",
              "- Do not run full validation, smoke, build, or test commands during `implement`.",
              "- Keep command output small. Do not stream long logs or dump large files into the turn.",
              "- At the end of the turn, call `#{@report_turn_result_tool}` exactly once.",
              "",
              "Execution hint:",
              broad_retry_execution_hint(repo_map, resume_context),
              "",
              "Resume context:",
              broad_resume_context_block(resume_context),
              token_pressure,
              "",
              "Exact next objective:",
              broad_retry_next_objective(resume_context)
            ]

          focused_review_claims == [] ->
            [
              "You are implementing ticket `#{issue.identifier}`.",
              "",
              "Title: #{to_string(issue.title || "Untitled issue")}",
              repo_platform_note(inspection),
              "Current implementation turn: #{turn_number} of #{max_turns}.",
              "",
              "Issue brief:",
              summarized_text(issue.description || "No description provided.", 1_500),
              "",
              "Resolved workflow profile: #{WorkflowProfile.name_string(workflow_profile)} (merge mode #{workflow_profile.merge_mode}).",
              "",
              RepoMap.prompt_block(repo_map),
              "",
              "Acceptance summary:",
              summarized_text(acceptance.summary, 800),
              maybe_acceptance_criteria_block(acceptance.criteria, resume_context),
              "",
              "Runtime-owned delivery rules:",
              "- Symphony owns git branch creation, commit, push, PR publication, CI waiting, merge, and post-merge closure.",
              "- Your job is limited to code changes in the checked out repo and reporting the structured turn result.",
              "- Do not create commits, push branches, open PRs, merge PRs, or change issue states yourself.",
              "- Do not run full validation, smoke, build, or test commands during `implement`.",
              "- Do not run heavyweight commands such as `xcodebuild`, `make all`, full test suites, or repo-wide validation scripts from this turn.",
              "- Do not inventory the entire repo or dump full diffs during `implement`: avoid `rg --files`, `fd`, `find .`, and full `git diff`; use targeted file reads and `git diff --stat` only.",
              "- Limit shell usage to targeted inspection and editing support only: prefer `rg`, `sed -n`, narrow file reads, and small `git status` or `git diff --stat` commands.",
              "- Keep command output small. Do not stream long logs or dump large files into the turn.",
              "- Focus on writing code. Symphony will track your changes automatically.",
              "- `files_touched` must list every path you changed this turn.",
              "- Set `blocked=true` only for a true blocker you cannot resolve from the repo or local environment.",
              "- Set `needs_another_turn=true` only when more implementation work is still required after this turn.",
              "",
              "Resume context:",
              resume_context_block(resume_context),
              token_pressure,
              "",
              "Exact next objective:",
              resume_context[:next_objective] ||
                "Advance the current diff toward validation with the smallest complete code change set possible."
            ]

          true ->
            [
              "You are implementing ticket `#{issue.identifier}`.",
              "",
              "Title: #{to_string(issue.title || "Untitled issue")}",
              repo_platform_note(inspection),
              "Current implementation turn: #{turn_number} of #{max_turns}.",
              "",
              "This is a scoped review-fix turn. Do not rediscover the issue or rescan the repo.",
              "Resolved workflow profile: #{WorkflowProfile.name_string(workflow_profile)} (merge mode #{workflow_profile.merge_mode}).",
              maybe_named_line("PR under review", Map.get(state, :pr_url), 200),
              "",
              "Scoped review claims for this turn:",
              ReviewClaims.focused_review_claim_block(focused_review_claims, Map.get(state, :review_claims, %{})),
              token_pressure,
              "",
              "Review-fix rules:",
              "- Touch only the files named in the scoped review claims unless a directly adjacent helper must change to make the fix compile.",
              "- Do not rescan unrelated files, docs, or tests.",
              "- Do not run full validation, smoke, build, or test commands during `implement`.",
              "- Limit shell usage to narrow reads of the listed files and minimal diff/status checks.",
              "- Keep command output small. Do not stream long logs or dump large files into the turn.",
              "- If you complete this claim batch but additional verified review claims remain, set `needs_another_turn=true`.",
              "- Focus on writing code. Symphony will track your changes automatically.",
              "",
              "Resume context:",
              focused_resume_context_block(resume_context),
              "",
              "Exact next objective:",
              ReviewClaims.focused_review_next_objective(
                focused_review_claims,
                Map.get(state, :review_claims, %{})
              )
            ]
        end

      prompt_lines
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.trim()
    end
  end

  defp maybe_acceptance_criteria_block([], _resume_context), do: nil

  defp maybe_acceptance_criteria_block(criteria, resume_context) when is_list(criteria) do
    criteria =
      criteria
      |> Enum.take(8)
      |> Enum.map(&("- " <> summarized_text(&1, 200)))

    diff_hint =
      case Map.get(resume_context, :dirty_files, []) do
        [] ->
          nil

        files ->
          "Current dirty files:\n" <> Enum.map_join(Enum.take(files, 20), "\n", &("- " <> &1))
      end

    [Enum.join(criteria, "\n"), diff_hint]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp resume_context_for_prompt(workspace, issue, state, inspection) do
    stored =
      case Map.get(state, :resume_context) do
        context when is_map(context) -> normalize_resume_context(context)
        _ -> %{}
      end

    target_stage = Map.get(state, :stage) || "implement"
    stored = Map.merge(stored, review_fix_resume_context(state, stored, target_stage))
    state = Map.put(state, :resume_context, stored)

    with fresh when is_map(fresh) <- fresh_resume_context(workspace, issue, state, inspection, %{}) do
      if resume_context_stale?(stored, inspection) do
        Map.merge(
          fresh,
          preserved_resume_context(stored)
          |> Map.merge(carry_forward_review_fix_budget_context(stored))
        )
      else
        Map.merge(fresh, stored)
      end
    end
  end

  defp resume_context_stale?(context, inspection) when is_map(context) do
    Map.get(context, :fingerprint) != inspection.fingerprint
  end

  defp fresh_resume_context(workspace, issue, state, inspection, overrides) do
    with :ok <- execution_guard(workspace, issue),
         changed_paths <- RunInspector.changed_paths(workspace),
         :ok <- execution_guard(workspace, issue),
         diff_summary <- RunInspector.diff_summary(workspace),
         :ok <- execution_guard(workspace, issue) do
      target_stage = Map.get(overrides, :target_stage) || Map.get(state, :stage) || "implement"
      stored_resume_context = normalize_resume_context(Map.get(state, :resume_context, %{}))

      focused_review_claims =
        ReviewClaims.focused_review_claims(
          Map.get(state, :review_claims, %{}),
          focused_review_claim_limit(state)
        )

      review_fix_context = review_fix_resume_context(state, stored_resume_context, target_stage)

      broad_retry_context =
        if review_fix_budget_mode?(review_fix_context) do
          %{}
        else
          broad_retry_resume_context(stored_resume_context, target_stage)
        end

      review_fix_progress_delta = Map.get(overrides, :review_fix_progress_delta, 0)

      %{
        issue_identifier: issue.identifier,
        fingerprint: inspection.fingerprint,
        last_turn_summary: get_in(state, [:last_turn_result, :summary]),
        last_validation_summary: summarized_command_output(get_in(state, [:last_validation, :output]), 800),
        last_verifier_summary:
          summarized_text(
            get_in(state, [:last_verifier, :summary]) || get_in(state, [:last_verifier, :output]),
            800
          ),
        dirty_files: Enum.take(changed_paths, 20),
        diff_summary: summarized_diff_summary(diff_summary, 30),
        last_blocking_rule: get_in(state, [:stop_reason, :code]) || Map.get(state, :last_rule_id),
        review_feedback_summary:
          Map.get(overrides, :review_feedback_summary) ||
            ReviewClaims.default_review_feedback_summary(state, focused_review_claims),
        review_claim_summary:
          Map.get(overrides, :review_claim_summary) ||
            ReviewClaims.default_review_claim_summary(state, focused_review_claims),
        next_objective:
          Map.get(overrides, :next_objective) ||
            ReviewClaims.default_next_objective(state, focused_review_claims)
      }
      |> Map.merge(review_fix_context)
      |> Map.merge(broad_retry_context)
      |> maybe_increment_review_fix_progress(review_fix_progress_delta)
      |> Map.merge(Enum.into(overrides, %{}))
      |> Map.drop([:target_stage, :review_fix_progress_delta])
    end
  end

  defp preserved_resume_context(context) when is_map(context) do
    context
    |> Map.take([
      :next_objective,
      :review_feedback_summary,
      :review_claim_summary,
      :review_feedback_pr_url,
      :token_pressure,
      :review_fix_budget_retry_count,
      :implementation_turn_window_base
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp repo_platform_note(%{harness: %{project: %{type: type}}}) when is_binary(type) do
    normalized = String.trim(type)

    cond do
      normalized == "" ->
        nil

      normalized == "ios-app" ->
        "Repo platform: iOS app (SwiftUI/Xcode). Ignore unrelated web or JavaScript framework guidance such as Vue, React, or Next.js."

      true ->
        "Repo platform: #{normalized}. Ignore unrelated framework guidance that does not match this repo."
    end
  end

  defp repo_platform_note(_inspection), do: nil

  defp resume_context_attrs(workspace, issue, state, inspection, overrides, _opts) do
    with {:ok, carrier} <- resume_context_carrier(workspace, issue, state),
         context when is_map(context) <- refreshed_resume_context(workspace, issue, carrier, inspection, overrides) do
      %{resume_context: context}
    end
  end

  defp resume_context_carrier(workspace, issue, state) do
    case AgentExecution.entry_context(workspace, issue) do
      {:ok, :legacy} ->
        {:ok, state}

      {:ok, _context} ->
        with {:ok, current} <- AgentExecution.ensure_current() do
          {:ok, Map.put(state, :resume_context, Map.get(current, :resume_context, %{}))}
        end

      {:stop, _} = terminal ->
        terminal
    end
  end

  defp refreshed_resume_context(workspace, issue, state, inspection, overrides) do
    preserved =
      state
      |> Map.get(:resume_context, %{})
      |> preserved_resume_context()

    with fresh when is_map(fresh) <- fresh_resume_context(workspace, issue, state, inspection, overrides) do
      Map.merge(fresh, preserved)
    end
  end

  defp resume_context_block(resume_context) when is_map(resume_context) do
    lines =
      if review_fix_budget_mode?(resume_context) do
        [
          "Scoped review-fix lane: active",
          maybe_named_line("Budget pressure", resume_context[:budget_pressure_level], 40),
          maybe_named_line("Budget retry count", resume_context[:budget_retry_count], 20),
          maybe_named_line("Scope kind", resume_context[:budget_scope_kind], 60),
          maybe_named_list("Scope ids", resume_context[:budget_scope_ids], 8),
          maybe_named_line(
            "Last implementation summary",
            resume_context[:last_turn_summary],
            280
          ),
          maybe_named_line(
            "Latest validation summary",
            resume_context[:last_validation_summary],
            400
          ),
          maybe_named_line(
            "Latest verifier summary",
            resume_context[:last_verifier_summary],
            400
          ),
          maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200),
          maybe_named_list(
            "Dirty files",
            Enum.take(Map.get(resume_context, :dirty_files, []), 8),
            8
          )
        ]
      else
        [
          maybe_named_line(
            "Last implementation summary",
            resume_context[:last_turn_summary],
            400
          ),
          maybe_named_line(
            "Latest validation summary",
            resume_context[:last_validation_summary],
            800
          ),
          maybe_named_line(
            "Latest verifier summary",
            resume_context[:last_verifier_summary],
            800
          ),
          maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200),
          maybe_named_multiline(
            "Pending PR review feedback",
            resume_context[:review_feedback_summary]
          ),
          maybe_named_multiline(
            "Pending PR review claims",
            resume_context[:review_claim_summary]
          ),
          maybe_named_list("Dirty files", resume_context[:dirty_files], 20),
          maybe_named_multiline("Diff stat", resume_context[:diff_summary])
        ]
      end

    lines
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No prior resume context recorded."
      lines -> Enum.join(lines, "\n")
    end
  end

  defp focused_resume_context_block(resume_context) when is_map(resume_context) do
    lines =
      if review_fix_budget_mode?(resume_context) do
        [
          "Scoped review-fix lane: active",
          maybe_named_line("Budget pressure", resume_context[:budget_pressure_level], 40),
          maybe_named_line("Budget retry count", resume_context[:budget_retry_count], 20),
          maybe_named_line("Scope kind", resume_context[:budget_scope_kind], 60),
          maybe_named_list("Scope ids", resume_context[:budget_scope_ids], 8),
          maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200)
        ]
      else
        [
          maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200)
        ]
      end

    lines
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No focused review context recorded."
      lines -> Enum.join(lines, "\n")
    end
  end

  defp broad_resume_context_block(resume_context) when is_map(resume_context) do
    target_paths = Map.get(resume_context, :target_paths, [])
    next_required_path = Map.get(resume_context, :next_required_path)

    [
      "Broad implement retry lane: active",
      maybe_named_line("Admission reason", resume_context[:budget_admission_reason], 80),
      maybe_named_line("Budget pressure", resume_context[:budget_pressure_level], 40),
      maybe_named_line("Budget retry count", resume_context[:budget_retry_count], 20),
      maybe_named_list("Target paths", target_paths, 6),
      maybe_named_line("Next required path", next_required_path, 200),
      maybe_named_multiline("Already learned", resume_context[:already_learned]),
      maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200),
      maybe_broad_retry_summary_line(resume_context, target_paths),
      maybe_broad_retry_dirty_files_line(resume_context, target_paths)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No broad retry context recorded."
      lines -> Enum.join(lines, "\n")
    end
  end

  defp token_pressure_note(resume_context) when is_map(resume_context) do
    cond do
      review_fix_budget_mode?(resume_context) and
          Map.get(resume_context, :budget_pressure_level) in ["soft", "high", "critical"] ->
        "\nScoped review-fix token pressure is active. Keep the turn limited to the current scope ids, avoid diff summaries, and do not restate old evidence."

      broad_implement_budget_mode?(resume_context) and
          Map.get(resume_context, :budget_pressure_level) in ["high", "critical"] ->
        "\nBroad implement token pressure is active. Narrow the turn to the smallest plausible code path, avoid repeated repo context, and do not restate prior evidence."

      Map.get(resume_context, :token_pressure) == "high" ->
        "\nToken pressure is high. Keep reads narrow, avoid repeated scans, and do not reprint prior evidence."

      true ->
        nil
    end
  end

  defp review_fix_next_objective(resume_context) when is_map(resume_context) do
    if review_fix_budget_mode?(resume_context) do
      scope_kind = Map.get(resume_context, :budget_scope_kind, "review_claim_batch")
      scope_ids = Map.get(resume_context, :budget_scope_ids, []) |> Enum.map(&to_string/1)

      if scope_ids == [] do
        nil
      else
        "Address the scoped #{scope_kind} items only: #{Enum.join(scope_ids, ", ")}."
      end
    end
  end

  defp broad_retry_next_objective(resume_context) when is_map(resume_context) do
    case Map.get(resume_context, :target_paths, []) do
      [path] ->
        "Advance the ticket by working only in `#{path}`. If one additional file is strictly required, name the exact path and stop instead of broadening the retry."

      [primary_path, expansion_path] ->
        "Advance the ticket by working only in `#{primary_path}` and `#{expansion_path}`. Do not read or edit any other repo paths in this retry."

      paths when is_list(paths) and paths != [] ->
        joined = Enum.map_join(Enum.take(paths, 2), ", ", &"`#{&1}`")
        "Advance the ticket by working only in the explicitly approved paths: #{joined}."

      _ ->
        Map.get(resume_context, :next_objective) ||
          "Identify the smallest concrete code path that advances the ticket, touch only that path, and leave broader follow-up for a later turn if needed."
    end
  end

  defp review_fix_resume_context(state, stored_resume_context, "implement") do
    cond do
      review_fix_budget_mode?(stored_resume_context) ->
        carry_forward_review_fix_budget_context(stored_resume_context)

      review_fix_scope_ids(state, "review_claim_batch") != [] ->
        initial_review_fix_resume_context(
          state,
          "review_claim_batch",
          review_fix_scope_ids(state, "review_claim_batch")
        )

      review_fix_scope_ids(state, "ci_failure_batch") != [] ->
        initial_review_fix_resume_context(
          state,
          "ci_failure_batch",
          review_fix_scope_ids(state, "ci_failure_batch")
        )

      true ->
        %{}
    end
  end

  defp review_fix_resume_context(_state, _stored_resume_context, _target_stage), do: %{}

  defp broad_retry_resume_context(stored_resume_context, "implement") do
    if broad_implement_budget_mode?(stored_resume_context) do
      Map.take(stored_resume_context, [
        :budget_mode,
        :budget_pressure_level,
        :budget_retry_count,
        :budget_window_base_turn,
        :budget_last_stop_code,
        :budget_last_observed_input_tokens,
        :budget_auto_narrowed,
        :target_paths,
        :already_learned,
        :next_required_path,
        :budget_expansion_used,
        :budget_admission_reason,
        :token_pressure
      ])
    else
      %{}
    end
  end

  defp broad_retry_resume_context(_stored_resume_context, _target_stage), do: %{}

  defp initial_review_fix_resume_context(state, scope_kind, scope_ids) do
    %{
      budget_mode: "review_fix",
      budget_pressure_level: "normal",
      budget_retry_count: 0,
      budget_window_base_turn: Map.get(state, :implementation_turns, 0) + 1,
      budget_last_stop_code: nil,
      budget_last_observed_input_tokens: nil,
      budget_scope_kind: scope_kind,
      budget_scope_ids: scope_ids,
      budget_progress_count: 0,
      budget_total_extension_used: false,
      budget_auto_narrowed: false
    }
  end

  defp carry_forward_review_fix_budget_context(resume_context) do
    Map.take(resume_context, [
      :budget_mode,
      :budget_pressure_level,
      :budget_retry_count,
      :budget_window_base_turn,
      :budget_last_stop_code,
      :budget_last_observed_input_tokens,
      :budget_scope_kind,
      :budget_scope_ids,
      :budget_progress_count,
      :budget_total_extension_used,
      :budget_auto_narrowed,
      :token_pressure
    ])
  end

  defp review_fix_scope_ids(state, "review_claim_batch") do
    state
    |> Map.get(:review_claims, %{})
    |> Enum.filter(fn {_thread_key, claim} -> ReviewClaims.claim_pending_review_fix?(claim) end)
    |> Enum.map(fn {thread_key, _claim} -> to_string(thread_key) end)
    |> Enum.sort()
  end

  defp review_fix_scope_ids(state, "ci_failure_batch") do
    state
    |> Map.get(:last_failing_required_checks, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp review_fix_scope_ids(_state, _scope_kind), do: []

  defp review_fix_budget_mode?(resume_context) when is_map(resume_context),
    do: Map.get(resume_context, :budget_mode) == "review_fix"

  defp review_fix_budget_mode?(_resume_context), do: false

  defp broad_implement_budget_mode?(resume_context) when is_map(resume_context),
    do: Map.get(resume_context, :budget_mode) == "broad_implement"

  defp broad_implement_budget_mode?(_resume_context), do: false

  defp maybe_increment_review_fix_progress(resume_context, delta)
       when is_map(resume_context) and is_integer(delta) and delta > 0 do
    if review_fix_budget_mode?(resume_context) do
      Map.update(resume_context, :budget_progress_count, delta, &(&1 + delta))
    else
      resume_context
    end
  end

  defp maybe_increment_review_fix_progress(resume_context, _delta), do: resume_context

  defp normalize_resume_context(context) when is_map(context) do
    context
    |> Enum.into(%{}, fn
      {key, value} when is_binary(key) ->
        case normalize_resume_context_key(key) do
          nil -> {key, value}
          atom_key -> {atom_key, value}
        end

      {key, value} ->
        {key, value}
    end)
  end

  defp normalize_resume_context(_context), do: %{}

  defp normalize_resume_context_key("budget_mode"), do: :budget_mode
  defp normalize_resume_context_key("budget_pressure_level"), do: :budget_pressure_level
  defp normalize_resume_context_key("budget_retry_count"), do: :budget_retry_count
  defp normalize_resume_context_key("budget_window_base_turn"), do: :budget_window_base_turn
  defp normalize_resume_context_key("budget_last_stop_code"), do: :budget_last_stop_code

  defp normalize_resume_context_key("budget_last_observed_input_tokens"),
    do: :budget_last_observed_input_tokens

  defp normalize_resume_context_key("budget_scope_kind"), do: :budget_scope_kind
  defp normalize_resume_context_key("budget_scope_ids"), do: :budget_scope_ids
  defp normalize_resume_context_key("budget_progress_count"), do: :budget_progress_count

  defp normalize_resume_context_key("budget_total_extension_used"),
    do: :budget_total_extension_used

  defp normalize_resume_context_key("budget_auto_narrowed"), do: :budget_auto_narrowed
  defp normalize_resume_context_key("target_paths"), do: :target_paths
  defp normalize_resume_context_key("already_learned"), do: :already_learned
  defp normalize_resume_context_key("next_required_path"), do: :next_required_path
  defp normalize_resume_context_key("budget_expansion_used"), do: :budget_expansion_used
  defp normalize_resume_context_key("budget_admission_reason"), do: :budget_admission_reason
  defp normalize_resume_context_key("token_pressure"), do: :token_pressure
  defp normalize_resume_context_key(_key), do: nil

  defp maybe_broad_retry_issue_brief(issue, resume_context) when is_map(resume_context) do
    case Map.get(resume_context, :target_paths, []) do
      paths when is_list(paths) and paths != [] ->
        nil

      _ ->
        [
          "",
          "Issue brief:",
          summarized_text(issue.description || "No description provided.", 1_200)
        ]
        |> Enum.join("\n")
    end
  end

  defp broad_retry_execution_hint(repo_map, resume_context) when is_map(resume_context) do
    target_paths = Map.get(resume_context, :target_paths, []) |> Enum.take(2)
    already_learned = summarized_text(Map.get(resume_context, :already_learned), 220)

    [
      broad_retry_focus_line(target_paths),
      broad_retry_learned_line(already_learned),
      broad_retry_repo_hint_line(repo_map, target_paths)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Keep the retry narrow and choose one concrete subsystem before reading more files."
      lines -> Enum.join(lines, "\n")
    end
  end

  defp broad_retry_focus_line([]),
    do: "Focus path: choose one concrete file or subsystem before continuing."

  defp broad_retry_focus_line([path]),
    do: "Focus path: `#{path}`. Stay inside this file. If one more file is strictly required, name the exact path instead of expanding heuristically."

  defp broad_retry_focus_line([primary_path, expansion_path]),
    do: "Focus path: `#{primary_path}` plus approved expansion `#{expansion_path}`. Do not read outside these two files in this retry."

  defp broad_retry_focus_line(paths),
    do: "Focus path: #{Enum.map_join(paths, ", ", &"`#{&1}`")}. Keep the retry limited to these explicit files."

  defp broad_retry_learned_line(nil), do: nil
  defp broad_retry_learned_line(text), do: "Already learned: #{text}"

  defp maybe_broad_retry_summary_line(resume_context, []) when is_map(resume_context) do
    maybe_named_line("Last implementation summary", resume_context[:last_turn_summary], 220)
  end

  defp maybe_broad_retry_summary_line(_resume_context, _target_paths), do: nil

  defp maybe_broad_retry_dirty_files_line(resume_context, []) when is_map(resume_context) do
    maybe_named_list("Dirty files", Enum.take(Map.get(resume_context, :dirty_files, []), 6), 6)
  end

  defp maybe_broad_retry_dirty_files_line(_resume_context, _target_paths), do: nil

  defp broad_retry_repo_hint_line(nil, [path]),
    do: "Execution hint: make progress inside `#{path}`; if that file is insufficient, report one exact next file."

  defp broad_retry_repo_hint_line(nil, [primary_path, expansion_path]),
    do: "Execution hint: work only in `#{primary_path}` and `#{expansion_path}`; avoid any other repo reads."

  defp broad_retry_repo_hint_line(nil, paths) when paths != [],
    do: "Execution hint: stay inside the explicit focus paths and avoid broad discovery."

  defp broad_retry_repo_hint_line(nil, _paths),
    do: "Execution hint: stay inside the first concrete path you confirm and avoid broad discovery."

  defp broad_retry_repo_hint_line(repo_map, paths) do
    platform =
      case Map.get(repo_map, :platform) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    proof =
      case Map.get(repo_map, :behavioral_proof) do
        %{test_paths: tests} when is_list(tests) and tests != [] ->
          "behavioral proof lives under #{Enum.join(Enum.take(tests, 2), ", ")}"

        _ ->
          nil
      end

    cond do
      platform && proof ->
        "Execution hint: platform=#{platform}; #{proof}."

      platform && paths != [] ->
        "Execution hint: platform=#{platform}; stay inside the explicit focus path list for this retry."

      proof ->
        "Execution hint: #{proof}."

      true ->
        "Execution hint: stay inside the explicit focus path list for this retry."
    end
  end

  defp maybe_named_line(_label, nil, _limit), do: nil

  defp maybe_named_line(label, value, limit) do
    "#{label}: #{summarized_text(value, limit)}"
  end

  defp maybe_named_multiline(_label, nil), do: nil
  defp maybe_named_multiline(label, value), do: "#{label}:\n#{value}"

  defp maybe_named_list(_label, [], _limit), do: nil

  defp maybe_named_list(label, values, limit) when is_list(values) do
    trimmed =
      values
      |> Enum.take(limit)
      |> Enum.map(&to_string/1)

    "#{label}:\n" <> Enum.map_join(trimmed, "\n", &("- " <> &1))
  end

  defp summarized_text(nil, _limit), do: nil

  defp summarized_text(value, limit) when is_integer(limit) and limit > 0 do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.slice(text, 0, limit)
    end
  end

  defp summarized_command_output(nil, _limit), do: nil

  defp summarized_command_output(output, limit) do
    output
    |> to_string()
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(12)
    |> Enum.join("\n")
    |> summarized_text(limit)
  end

  defp summarized_diff_summary(nil, _line_limit), do: nil

  defp summarized_diff_summary(summary, line_limit) do
    summary
    |> to_string()
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.take(line_limit)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp next_objective_for_stage("implement", %TurnResult{} = turn_result, review_claims)
       when is_map(review_claims) do
    case ReviewClaims.accepted_actionable_claim_count(review_claims) do
      count when count > 0 -> ReviewClaims.accepted_review_next_objective(review_claims)
      _ -> next_objective_for_stage("implement", turn_result)
    end
  end

  defp next_objective_for_stage(stage, turn_result, _review_claims) when is_binary(stage),
    do: next_objective_for_stage(stage, turn_result)

  defp next_objective_for_stage("implement", %TurnResult{summary: summary})
       when is_binary(summary) do
    "Continue implementation from the existing diff. Last turn summary: #{summarized_text(summary, 240)}"
  end

  defp next_objective_for_stage("validate", _turn_result),
    do: "Stop editing and let Symphony run the official validation contract."

  defp next_objective_for_stage(stage, _turn_result) when is_binary(stage),
    do: "Advance the issue to #{stage}."

  defp verifier_retry_objective(result) do
    summary =
      get_in(result, [:summary]) || get_in(result, ["summary"]) || "Verifier requested more work."

    "Address the latest verifier feedback: #{summarized_text(summary, 280)}"
  end

  defp implement_forbidden_commands(harness) do
    harness_commands =
      [
        harness && harness.validation_command,
        harness && harness.smoke_command,
        harness && harness.post_merge_command
      ]
      |> Enum.reject(&is_nil/1)

    [
      "xcodebuild",
      "make all",
      "npm test",
      "pnpm test",
      "yarn test",
      "pytest",
      "cargo test",
      "./scripts/symphony-validate.sh",
      "./scripts/symphony-smoke.sh"
      | harness_commands
    ]
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp implement_effort(state) do
    if ReviewClaims.focused_review_claims(Map.get(state, :review_claims, %{})) == [] do
      Config.agent_turn_effort("implement")
    else
      "low"
    end
  end

  defp implement_command_output_budget(state) do
    cond do
      ReviewClaims.focused_review_claims(Map.get(state, :review_claims, %{})) == [] ->
        %{
          stage: "implement",
          per_command_bytes: 8_192,
          per_turn_bytes: 32_768,
          max_command_count: 12
        }

      get_in(state, [:resume_context, :token_pressure]) == "high" ->
        %{
          stage: "implement",
          per_command_bytes: 4_096,
          per_turn_bytes: 12_288,
          max_command_count: 4
        }

      true ->
        %{
          stage: "implement",
          per_command_bytes: 6_144,
          per_turn_bytes: 24_576,
          max_command_count: 6
        }
    end
  end

  @doc false
  @spec focused_review_claim_limit(map()) :: non_neg_integer()
  def focused_review_claim_limit(state) do
    case get_in(state, [:resume_context, :token_pressure]) do
      "high" -> 1
      _ -> 2
    end
  end

  # -- Delegations to ReviewClaims (called cross-module after extraction) ------

  @doc false
  @spec focused_review_claims(map(), non_neg_integer()) :: list()
  defdelegate focused_review_claims(review_claims, limit \\ 2), to: SymphonyElixir.DeliveryEngine.ReviewClaims

  @doc false
  @spec focused_review_claim_block(list(), map()) :: String.t()
  defdelegate focused_review_claim_block(focused_claims, all_review_claims), to: SymphonyElixir.DeliveryEngine.ReviewClaims

  @doc false
  @spec focused_review_next_objective(list(), map()) :: String.t()
  defdelegate focused_review_next_objective(focused_claims, all_review_claims), to: SymphonyElixir.DeliveryEngine.ReviewClaims

  @doc false
  @spec default_review_feedback_summary(map(), list()) :: String.t() | nil
  defdelegate default_review_feedback_summary(state, focused_claims), to: SymphonyElixir.DeliveryEngine.ReviewClaims

  @doc false
  @spec default_review_claim_summary(map(), list()) :: String.t() | nil
  defdelegate default_review_claim_summary(state, focused_claims), to: SymphonyElixir.DeliveryEngine.ReviewClaims

  @doc false
  @spec default_next_objective(map(), list()) :: String.t()
  defdelegate default_next_objective(state, focused_claims), to: SymphonyElixir.DeliveryEngine.ReviewClaims

  @doc false
  @spec claim_pending_review_fix?(map()) :: boolean()
  defdelegate claim_pending_review_fix?(claim), to: SymphonyElixir.DeliveryEngine.ReviewClaims

  defp effective_implementation_turns(state) when is_map(state) do
    implementation_turns = Map.get(state, :implementation_turns, 0)
    window_base = get_in(state, [:resume_context, :implementation_turn_window_base]) || 0

    cond do
      not is_integer(implementation_turns) ->
        0

      not is_integer(window_base) ->
        implementation_turns

      implementation_turns >= window_base ->
        implementation_turns - window_base

      true ->
        implementation_turns
    end
  end

  defp effective_max_turns(max_turns, state) when is_integer(max_turns) and is_map(state) do
    if review_fix_turn_budget_candidate?(state) do
      max(max_turns, @review_fix_max_turns)
    else
      max_turns
    end
  end

  defp review_fix_turn_budget_candidate?(state) when is_map(state) do
    get_in(state, [:resume_context, :token_pressure]) == "high" and
      Enum.any?(Map.get(state, :review_claims, %{}), fn {_thread_key, claim} ->
        claim_value(claim, :disposition) == "accepted" and claim_value(claim, :actionable, false)
      end)
  end

  defp claim_value(claim, key, default \\ nil) when is_map(claim) and is_atom(key) do
    Map.get(claim, key, Map.get(claim, Atom.to_string(key), default))
  end

  defp ensure_turn_progress(
         %TurnResult{blocked: true} = turn_result,
         _before_snapshot,
         _after_snapshot
       ) do
    {:error, {:agent_blocked, turn_result}}
  end

  defp ensure_turn_progress(%TurnResult{} = turn_result, before_snapshot, after_snapshot) do
    if RunInspector.code_changed?(before_snapshot, after_snapshot) or
         is_binary(after_snapshot.pr_url) do
      :ok
    else
      if retained_workspace_changes_ready_for_validation?(
           turn_result,
           before_snapshot,
           after_snapshot
         ) do
        :ok
      else
        if Config.policy_stop_on_noop_turn?() do
          {:error, {:noop_turn, "No code change and no PR"}}
        else
          :ok
        end
      end
    end
  end

  defp implement_next_stage(
         %TurnResult{needs_another_turn: true} = turn_result,
         before_snapshot,
         after_snapshot
       ) do
    case ensure_turn_progress(turn_result, before_snapshot, after_snapshot) do
      :ok ->
        {:ok, "implement"}

      {:error, {:noop_turn, _summary}} ->
        if retained_workspace_changes_present?(after_snapshot) do
          {:ok, "implement"}
        else
          {:error, {:noop_turn, "No code change and no PR"}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp implement_next_stage(%TurnResult{} = turn_result, before_snapshot, after_snapshot) do
    case ensure_turn_progress(turn_result, before_snapshot, after_snapshot) do
      :ok ->
        if Config.policy_require_validation?(), do: {:ok, "validate"}, else: {:ok, "publish"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retained_workspace_changes_ready_for_validation?(
         %TurnResult{needs_another_turn: false},
         _before_snapshot,
         %RunInspector.Snapshot{dirty?: true, changed_files: changed_files, pr_url: nil}
       )
       when is_integer(changed_files) and changed_files > 0 do
    true
  end

  defp retained_workspace_changes_ready_for_validation?(
         _turn_result,
         _before_snapshot,
         _after_snapshot
       ),
       do: false

  defp retained_workspace_changes_present?(%RunInspector.Snapshot{
         dirty?: true,
         changed_files: changed_files,
         pr_url: nil
       })
       when is_integer(changed_files) and changed_files > 0,
       do: true

  defp retained_workspace_changes_present?(_snapshot), do: false

  defp should_resume_validation_from_retained_changes?(state, focused_claims, before_snapshot)
       when is_map(state) and is_list(focused_claims) do
    focused_claims == [] and
      retained_workspace_changes_present?(before_snapshot) and
      last_turn_completed_without_follow_up?(Map.get(state, :last_turn_result))
  end

  defp should_resume_validation_from_retained_changes?(_state, _focused_claims, _before_snapshot),
    do: false

  defp last_turn_completed_without_follow_up?(%TurnResult{} = turn_result) do
    turn_result.blocked == false and turn_result.needs_another_turn == false
  end

  defp last_turn_completed_without_follow_up?(turn_result) when is_map(turn_result) do
    claim_value(turn_result, :blocked, false) == false and
      claim_value(turn_result, :needs_another_turn, false) == false
  end

  defp last_turn_completed_without_follow_up?(_turn_result), do: false

  defp ensure_issue_still_active(%Issue{} = issue) do
    if active_issue_state?(issue.state) do
      :ok
    else
      {:skip, issue}
    end
  end

  defp fetch_turn_result(issue) do
    case Process.get(turn_result_key(issue)) do
      %TurnResult{} = turn_result ->
        {:ok, turn_result}

      nil ->
        case fetch_turn_runtime_errors(issue) do
          {:ok, reason} -> {:error, {:turn_runtime_error, reason}}
          :error -> {:error, :missing_turn_result}
        end

      {:error, reason} ->
        {:error, {:invalid_turn_result, reason}}

      other ->
        {:error, {:invalid_turn_result, other}}
    end
  end

  defp run_logged_agent_turn(provider, app_session, workspace, prompt, issue, opts) do
    started_at = System.monotonic_time()

    with :ok <- execution_guard(workspace, issue),
         turn_result <- AgentProvider.run_turn(provider, app_session, workspace, prompt, issue, opts, :delivery),
         :ok <- execution_guard(workspace, issue) do
      case turn_result do
        {:stop, _} = terminal -> {terminal, nil}
        _ -> logged_agent_turn_result(turn_result, provider, issue, opts, started_at)
      end
    else
      {:stop, _} = terminal -> {terminal, nil}
    end
  end

  defp logged_agent_turn_result(turn_result, provider, issue, opts, started_at) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    log_context =
      agent_turn_log_context(
        Keyword.get(opts, :stage),
        provider,
        Keyword.get(opts, :model),
        issue,
        duration_ms,
        normalize_turn_tokens(turn_result)
      )

    {turn_result, log_context}
  end

  defp log_agent_turn_lifecycle(log_context, result) do
    Logger.info(
      "event=delivery_engine.agent_turn stage=#{log_context.stage} provider=#{log_context.provider} model=#{inspect(log_context.model)} issue=#{log_context.issue} duration_ms=#{log_context.duration_ms} tokens=#{inspect(log_context.tokens)} result=#{result}",
      event: "delivery_engine.agent_turn",
      stage: log_context.stage,
      provider: log_context.provider,
      model: log_context.model,
      issue: log_context.issue,
      issue_identifier: log_context.issue_identifier,
      duration_ms: log_context.duration_ms,
      tokens: log_context.tokens,
      result: result
    )
  end

  defp agent_turn_log_context(stage, provider, model, issue, duration_ms, tokens) do
    %{
      stage: stage,
      provider: normalize_turn_provider(provider),
      model: model,
      issue: normalize_issue_log_value(issue),
      issue_identifier: Map.get(issue, :identifier),
      duration_ms: duration_ms,
      tokens: tokens
    }
  end

  defp plan_turn_log_result(provider_turn_result, reported_turn_result, plan_completed) do
    "provider=#{normalize_provider_turn_outcome(provider_turn_result)},turn=#{normalize_reported_turn_outcome(reported_turn_result)},plan_completed=#{plan_completed}"
  end

  defp implement_turn_log_result(provider_turn_result, reported_turn_result) do
    "provider=#{normalize_provider_turn_outcome(provider_turn_result)},turn=#{normalize_reported_turn_outcome(reported_turn_result)}"
  end

  defp normalize_turn_provider(SymphonyElixir.AgentProvider.Codex), do: "codex"
  defp normalize_turn_provider(SymphonyElixir.AgentProvider.CodexCLI), do: "codex-cli"
  defp normalize_turn_provider(SymphonyElixir.AgentProvider.Claude), do: "claude"
  defp normalize_turn_provider(provider) when is_binary(provider), do: provider
  defp normalize_turn_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_turn_provider(provider), do: inspect(provider)

  defp normalize_issue_log_value(%Issue{identifier: identifier, id: issue_id}) do
    identifier || issue_id || "unknown"
  end

  defp normalize_issue_log_value(issue) when is_map(issue) do
    Map.get(issue, :identifier) || Map.get(issue, :id) || "unknown"
  end

  defp normalize_issue_log_value(_issue), do: "unknown"

  defp normalize_turn_tokens({:ok, response}) when is_map(response) do
    usage = Map.get(response, :usage) || Map.get(response, "usage")

    case usage do
      usage when is_map(usage) ->
        input_tokens = normalize_token_count(Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens"))
        output_tokens = normalize_token_count(Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens"))
        total_tokens = normalize_token_count(Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens"))

        %{
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: if(total_tokens > 0, do: total_tokens, else: input_tokens + output_tokens)
        }

      _ ->
        default_turn_tokens()
    end
  end

  defp normalize_turn_tokens(_turn_result), do: default_turn_tokens()

  defp default_turn_tokens do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  defp normalize_token_count(nil), do: 0
  defp normalize_token_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_token_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp normalize_token_count(_value), do: 0

  defp normalize_provider_turn_outcome({:ok, response}) when is_map(response) do
    response
    |> Map.get(:result, Map.get(response, "result"))
    |> normalize_turn_outcome_value("completed")
  end

  defp normalize_provider_turn_outcome({:error, reason}) do
    normalize_turn_outcome_value(reason, "error")
  end

  defp normalize_provider_turn_outcome(_result), do: "unknown"

  defp normalize_reported_turn_outcome({:ok, %TurnResult{blocked: true, blocker_type: blocker_type}}) do
    "blocked:#{blocker_type || "unknown"}"
  end

  defp normalize_reported_turn_outcome({:ok, %TurnResult{needs_another_turn: true}}),
    do: "needs_another_turn"

  defp normalize_reported_turn_outcome({:ok, %TurnResult{}}), do: "completed"

  defp normalize_reported_turn_outcome({:error, reason}) do
    normalize_turn_outcome_value(reason, "missing")
  end

  defp normalize_turn_outcome_value({tag, _details}, _default) when is_atom(tag),
    do: Atom.to_string(tag)

  defp normalize_turn_outcome_value(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp normalize_turn_outcome_value(value, _default) when is_binary(value), do: value
  defp normalize_turn_outcome_value(_value, default), do: default

  defp tool_executor(issue, opts) do
    fn tool, arguments ->
      case tool do
        @report_turn_result_tool ->
          case TurnResult.normalize(arguments) do
            {:ok, turn_result} ->
              Process.put(turn_result_key(issue), turn_result)

              %{
                "success" => true,
                "contentItems" => [%{"type" => "inputText", "text" => "turn result recorded"}]
              }

            {:error, reason} ->
              Process.put(turn_result_key(issue), {:error, reason})

              %{
                "success" => false,
                "contentItems" => [%{"type" => "inputText", "text" => inspect(reason)}]
              }
          end

        _ ->
          DynamicTool.execute(tool, arguments, opts)
      end
    end
  end

  defp clear_turn_result(issue) do
    Process.delete(turn_result_key(issue))
    :ok
  end

  defp turn_result_key(%Issue{id: issue_id}), do: {@turn_result_key_prefix, issue_id}

  defp record_turn_runtime_error(issue, reason) do
    key = turn_runtime_error_key(issue)
    existing = Process.get(key, [])
    Process.put(key, existing ++ [reason])
    :ok
  end

  defp fetch_turn_runtime_errors(issue) do
    case Process.get(turn_runtime_error_key(issue)) do
      errors when is_list(errors) and errors != [] -> {:ok, errors}
      _ -> :error
    end
  end

  defp clear_turn_runtime_errors(issue) do
    Process.delete(turn_runtime_error_key(issue))
    :ok
  end

  defp turn_runtime_error_key(%Issue{id: issue_id}),
    do: {@turn_runtime_error_key_prefix, issue_id}

  defp maybe_move_issue(%Issue{id: issue_id, state: current_state} = issue, target_state)
       when is_binary(issue_id) and is_binary(target_state) do
    if SymphonyElixir.Util.normalize_state(current_state) == SymphonyElixir.Util.normalize_state(target_state) do
      :ok
    else
      IssueSource.update_issue_state(issue, target_state)
    end
  end

  defp maybe_move_issue(_issue, _target_state), do: :ok

  defp handle_implementation_turn_error(
         app_session,
         workspace,
         issue,
         recipient,
         fetcher,
         max_turns,
         state,
         opts,
         reason
       ) do
    attempts = effective_implementation_turns(state) + 1
    total_implementation_turns = Map.get(state, :implementation_turns, 0) + 1
    summary = implementation_turn_error_summary(reason)

    with :ok <- execution_guard(workspace, issue),
         refresh_result <- refresh_issue(issue, fetcher),
         :ok <- execution_guard(workspace, issue),
         {:ok, refreshed_issue} <- refresh_result,
         :ok <- ensure_issue_still_active(refreshed_issue) do
      if attempts >= max_turns do
        block_issue(
          workspace,
          refreshed_issue,
          implementation_error_code(reason),
          summary,
          @blocked_state
        )
      else
        with {:ok, _persisted_state} <-
               transition_state(workspace, "implement", %{
                 implementation_turns: total_implementation_turns,
                 last_implementation_error: %{
                   summary: summary,
                   reason: implementation_error_to_map(reason)
                 },
                 reason: "Retrying implementation after agent turn error: #{summary}"
               }),
             :ok <- execution_guard(workspace, issue) do
          do_run(app_session, workspace, refreshed_issue, recipient, fetcher, max_turns, opts)
        end
      end
    else
      {:stop, _} = terminal ->
        terminal

      {:done, finished_issue} ->
        {:done, finished_issue}

      {:skip, finished_issue} ->
        {:done, finished_issue}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp implementation_turn_error_summary(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(&implementation_turn_error_summary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" | ")
  end

  defp implementation_turn_error_summary({:turn_failed, details}) do
    case turn_failed_reason_code(details) do
      "implementation.command_output_budget_exceeded" ->
        "Implement turn exceeded the command output budget: #{safe_detail_text(details)}"

      "implementation.command_count_exceeded" ->
        "Implement turn issued too many shell commands: #{safe_detail_text(details)}"

      "implementation.broad_read_violation" ->
        "Implement turn attempted a broad repository read instead of targeted inspection: #{safe_detail_text(details)}"

      "implementation.stage_command_violation" ->
        "Implement turn attempted a runtime-owned validation command: #{safe_detail_text(details)}"

      _ ->
        "Agent turn failed: #{safe_detail_text(details)}"
    end
  end

  defp implementation_turn_error_summary({:port_exit, status}),
    do: "Agent process exited during the turn with status #{status}."

  defp implementation_turn_error_summary(:turn_timeout),
    do: "Agent turn timed out before completing."

  defp implementation_turn_error_summary({:agent_notification_error, method, details}),
    do: "Agent reported #{method}: #{safe_detail_text(details)}"

  defp implementation_turn_error_summary({:turn_cancelled, details}),
    do: "Agent turn was cancelled: #{safe_detail_text(details)}"

  defp implementation_turn_error_summary({:approval_required, details}),
    do: "Agent requested approval unexpectedly: #{safe_detail_text(details)}"

  defp implementation_turn_error_summary({:turn_input_required, details}),
    do: "Agent requested operator input unexpectedly: #{safe_detail_text(details)}"

  defp implementation_turn_error_summary(reason), do: safe_detail_text(reason)

  defp implementation_error_to_map(reasons) when is_list(reasons),
    do: Enum.map(reasons, &implementation_error_to_map/1)

  defp implementation_error_to_map({:agent_notification_error, method, details}),
    do: %{type: "agent_notification_error", method: method, details: safe_detail_text(details)}

  defp implementation_error_to_map({tag, details}) when is_atom(tag),
    do: %{type: Atom.to_string(tag), details: safe_detail_text(details)}

  defp implementation_error_to_map(reason),
    do: %{type: "unknown", details: safe_detail_text(reason)}

  defp retryable_implementation_error?({:turn_failed, details}) do
    case turn_failed_reason_code(details) do
      "implementation.command_output_budget_exceeded" -> false
      "implementation.command_count_exceeded" -> false
      "implementation.broad_read_violation" -> false
      "implementation.stage_command_violation" -> false
      _ -> true
    end
  end

  defp retryable_implementation_error?({:port_exit, _status}), do: true
  defp retryable_implementation_error?(:turn_timeout), do: true
  defp retryable_implementation_error?(_reason), do: false

  defp non_retryable_implementation_error?({:turn_failed, details}) do
    case turn_failed_reason_code(details) do
      "implementation.command_output_budget_exceeded" -> true
      "implementation.command_count_exceeded" -> true
      "implementation.broad_read_violation" -> true
      "implementation.stage_command_violation" -> true
      _ -> false
    end
  end

  defp non_retryable_implementation_error?({:turn_cancelled, _details}), do: true
  defp non_retryable_implementation_error?({:approval_required, _details}), do: true
  defp non_retryable_implementation_error?({:turn_input_required, _details}), do: true
  defp non_retryable_implementation_error?(_reason), do: false

  defp implementation_error_code({:turn_failed, details}) do
    case turn_failed_reason_code(details) do
      "implementation.command_output_budget_exceeded" -> :command_output_budget_exceeded
      "implementation.command_count_exceeded" -> :command_count_exceeded
      "implementation.broad_read_violation" -> :broad_read_violation
      "implementation.stage_command_violation" -> :stage_command_violation
      _ -> :turn_failed
    end
  end

  defp implementation_error_code(_reason), do: :turn_failed

  defp turn_failed_reason_code(details) when is_map(details) do
    Map.get(details, :reason) || Map.get(details, "reason")
  end

  defp turn_failed_reason_code(_details), do: nil

  defp handle_checkout_error(workspace, issue, {:error, reason})
       when reason in [:missing_harness_version, :missing_required_checks] do
    block_issue(
      workspace,
      issue,
      reason,
      "The repo harness contract is incomplete.",
      @blocked_state
    )
  end

  defp handle_checkout_error(workspace, issue, {:error, {:missing_harness_command, stage}})
       when stage in ["preflight", "validation", "smoke", "artifacts"] do
    with {:ok, context} <- AgentExecution.entry_context(workspace, issue) do
      ledger = capture_gate_ledger(context)

      result =
        case stage do
          "preflight" -> RunInspector.run_preflight(workspace, nil)
          "validation" -> RunInspector.run_validation(workspace, nil)
          "smoke" -> RunInspector.run_smoke(workspace, nil)
          "artifacts" -> RunInspector.run_artifacts(workspace, nil)
        end

      with :ok <- execution_guard(workspace, issue) do
        record_gate_event!(ledger, "#{stage}.completed", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          stage: "checkout",
          actor_type: "runtime",
          actor_id: "delivery_engine",
          summary: "#{stage} unavailable",
          metadata: %{workspace: workspace, gate_id: result.gate_id, gate: gate_result_to_map(result)}
        })

        block_issue(workspace, issue, :missing_harness_command, "The repo harness is missing the required `#{stage}.command` entry.", @blocked_state, %{ledger: ledger, result: result})
      end
    end
  end

  defp handle_checkout_error(workspace, issue, {:error, {:missing_harness_command, stage}}) do
    block_issue(
      workspace,
      issue,
      :missing_harness_command,
      "The repo harness is missing the required `#{stage}.command` entry.",
      @blocked_state
    )
  end

  defp handle_checkout_error(workspace, issue, {:error, {:unknown_harness_keys, path, keys}}) do
    block_issue(
      workspace,
      issue,
      :invalid_harness,
      "Unknown harness keys under #{Enum.join(path, ".")}: #{Enum.join(keys, ", ")}",
      @blocked_state
    )
  end

  defp handle_checkout_error(workspace, issue, {:error, :missing}) do
    block_issue(
      workspace,
      issue,
      :missing_harness,
      "The repo harness contract is missing after checkout.",
      @blocked_state
    )
  end

  defp handle_checkout_error(workspace, issue, {:error, :invalid_harness_root}) do
    block_issue(
      workspace,
      issue,
      :invalid_harness,
      inspect(:invalid_harness_root),
      @blocked_state
    )
  end

  defp handle_checkout_error(
         workspace,
         issue,
         {:error, %{code: :policy_pack_disallows_class} = conflict}
       ) do
    block_issue(
      workspace,
      issue,
      :policy_pack_disallows_class,
      Map.get(conflict, :details) || Map.get(conflict, :summary) || inspect(conflict),
      @blocked_state
    )
  end

  defp handle_checkout_error(workspace, issue, {:error, %{code: :invalid_labels} = conflict}) do
    block_issue(
      workspace,
      issue,
      :policy_invalid_labels,
      Map.get(conflict, :details) || Map.get(conflict, :summary) || inspect(conflict),
      @blocked_state
    )
  end

  defp handle_checkout_error(workspace, issue, {:error, reason}) do
    block_issue(workspace, issue, :checkout_failed, reason, @blocked_state)
  end

  defp refresh_issue(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        {:ok, refreshed_issue}

      {:ok, []} ->
        if ManualIssueSpec.runtime_issue_id?(issue_id) do
          {:ok, issue}
        else
          {:done, :missing}
        end

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp block_issue(workspace, issue, code, details, target_state, gate_observation \\ nil) do
    issue_id = issue.id
    issue_identifier = issue.identifier || issue.id || "unknown"
    detail_text = safe_detail_text(details)
    rule = RuleCatalog.rule(code)
    gate_metadata = gate_block_metadata(gate_observation)

    with {:ok, run_state} <- delivery_state(workspace, issue),
         :ok <- execution_guard(workspace, issue) do
      ledger_event =
        record_gate_stop!(gate_observation, %{
          issue_id: issue_id,
          issue_identifier: issue_identifier,
          stage: Map.get(run_state, :stage),
          actor_type: "runtime",
          actor_id: "delivery_engine",
          policy_class: Map.get(run_state, :effective_policy_class),
          failure_class: rule.failure_class,
          rule_id: rule.rule_id,
          summary: detail_summary(code, detail_text),
          details: detail_text,
          target_state: target_state,
          metadata:
            %{
              code: Atom.to_string(code),
              human_action: rule.human_action
            }
            |> Map.merge(gate_metadata)
        })

      transition_result =
        transition_state(workspace, "blocked", %{
          stop_reason:
            %{
              code: to_string(code),
              rule_id: rule.rule_id,
              failure_class: rule.failure_class,
              details: detail_text
            }
            |> Map.merge(gate_metadata),
          last_decision:
            %{
              rule_id: rule.rule_id,
              failure_class: rule.failure_class,
              summary: detail_summary(code, detail_text),
              details: detail_text,
              human_action: rule.human_action,
              target_state: target_state,
              ledger_event_id: Map.get(ledger_event, :event_id)
            }
            |> Map.merge(gate_metadata),
          last_rule_id: rule.rule_id,
          last_failure_class: rule.failure_class,
          last_decision_summary: detail_summary(code, detail_text),
          next_human_action: rule.human_action
        })

      case transition_result do
        {:stop, _} = terminal ->
          terminal

        {:ok, _state} ->
          if is_binary(issue_id) do
            with :ok <- confirm_block_notification(),
                 comment_result <-
                   IssueSource.create_comment(
                     issue,
                     """
                     ## Symphony runtime stop

                     Issue: #{issue_identifier}
                     Rule ID: #{rule.rule_id}
                     Failure class: #{rule.failure_class}

                     #{detail_text}

                     Unblock action: #{rule.human_action}
                     """
                     |> String.trim()
                   ),
                 :ok <- report_block_notification(comment_result, issue, :comment),
                 :ok <- confirm_block_notification(),
                 move_result <- IssueSource.update_issue_state(issue, target_state),
                 :ok <- report_block_notification(move_result, issue, :move) do
              {:stop, code}
            end
          else
            {:stop, code}
          end

        {:error, reason} ->
          Logger.error("Failed to persist blocked state issue_identifier=#{issue_identifier} reason=#{inspect(reason)}")
          {:error, {:blocked_state_persist_failed, reason}}
      end
    end
  end

  defp report_block_notification(:ok, _issue, _action), do: :ok

  defp report_block_notification({:error, reason}, issue, action) do
    Logger.error("Blocked notification failed issue_id=#{issue.id} issue_identifier=#{issue.identifier} action=#{action} cause=#{inspect(reason, limit: 5, printable_limit: 160)}")

    :ok
  end

  defp safe_detail_text(details) when is_binary(details) do
    details
    |> String.trim()
    |> String.slice(0, 2_000)
  end

  defp safe_detail_text(details) do
    details
    |> inspect()
    |> String.trim()
    |> String.slice(0, 2_000)
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

  defp gate_result_to_map(result) do
    command_result_to_map(result)
    |> Map.merge(result |> Map.take([:gate_id, :gate_kind, :exit_code, :started_at, :finished_at, :duration_us, :environment]) |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new())
  end

  defp verification_gate_observation(result, ledger) do
    case Map.get(result, :smoke) || Map.get(result, "smoke") do
      %{gate_id: id} = smoke when is_binary(id) -> %{result: smoke, ledger: ledger}
      _historical -> nil
    end
  end

  defp gate_block_metadata(nil), do: %{}
  defp gate_block_metadata(%{result: result}), do: %{gate_id: result.gate_id, gate: gate_result_to_map(result)}
  defp record_gate_stop!(nil, attrs), do: RunLedger.record("runtime.stopped", attrs)
  defp record_gate_stop!(%{ledger: ledger}, attrs), do: record_gate_event!(ledger, "runtime.stopped", attrs)

  defp command_result_to_map(result) do
    %{
      status: result.status,
      command: result.command,
      output: String.slice(to_string(result.output || ""), 0, 2_000)
    }
  end

  defp verifier_result_to_map(result) when is_map(result) do
    %{
      verdict: Map.get(result, :verdict) || Map.get(result, "verdict"),
      summary: Map.get(result, :summary) || Map.get(result, "summary"),
      acceptance_gaps: Map.get(result, :acceptance_gaps) || Map.get(result, "acceptance_gaps") || [],
      risky_areas: Map.get(result, :risky_areas) || Map.get(result, "risky_areas") || [],
      evidence: Map.get(result, :evidence) || Map.get(result, "evidence") || [],
      output: Map.get(result, :raw_output) || Map.get(result, "raw_output"),
      reason_code: Map.get(result, :reason_code) || Map.get(result, "reason_code"),
      smoke: Map.get(result, :smoke) || Map.get(result, "smoke"),
      acceptance: Map.get(result, :acceptance) || Map.get(result, "acceptance"),
      behavioral_proof: Map.get(result, :behavioral_proof) || Map.get(result, "behavioral_proof"),
      ui_proof: Map.get(result, :ui_proof) || Map.get(result, "ui_proof")
    }
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      maybe_capture_turn_runtime_error(issue, message)

      if match?({:error, :execution_context_missing}, AgentExecution.current_context()) and is_pid(recipient) and is_binary(issue.id) do
        send(recipient, {:agent_worker_update, issue.id, message})
      end

      :ok
    end
  end

  defp maybe_capture_turn_runtime_error(issue, %{event: :turn_ended_with_error, reason: reason}) do
    record_turn_runtime_error(issue, reason)
  end

  defp maybe_capture_turn_runtime_error(issue, %{
         event: :notification,
         payload: %{"method" => method} = payload
       })
       when method in @agent_turn_error_methods do
    record_turn_runtime_error(
      issue,
      {:agent_notification_error, method, Map.get(payload, "params", %{})}
    )
  end

  defp maybe_capture_turn_runtime_error(_issue, _message), do: :ok

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = SymphonyElixir.Util.normalize_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> SymphonyElixir.Util.normalize_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp branch_has_publishable_changes?(workspace, state, opts) do
    base_branch = Map.get(state, :base_branch, "main")
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case command_runner.("git", ["rev-list", "--count", "origin/#{base_branch}..HEAD"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {count, _rest} -> count > 0
          _ -> false
        end

      _ ->
        false
    end
  end

  defp merged_pull_request?(inspection) do
    normalize_pr_state(inspection.pr_state) == "MERGED"
  end

  defp closed_pull_request?(inspection) do
    normalize_pr_state(inspection.pr_state) == "CLOSED"
  end

  defp normalize_pr_state(nil), do: nil

  defp normalize_pr_state(pr_state) do
    pr_state
    |> to_string()
    |> String.trim()
    |> String.upcase()
  end

  defp await_checks_state_attrs(inspection, check_rollup, await_checks_polls) do
    %{
      pr_url: inspection.pr_url,
      await_checks_polls: await_checks_polls,
      merge_window_wait: nil,
      last_pr_state: inspection.pr_state,
      last_review_decision: inspection.review_decision,
      last_check_statuses: inspection.check_statuses,
      last_required_checks_state: check_rollup.state,
      last_missing_required_checks: check_rollup.missing,
      last_pending_required_checks: check_rollup.pending,
      last_failing_required_checks: check_rollup.failed,
      last_cancelled_required_checks: check_rollup.cancelled
    }
  end

  defp merge_window_deferred?(state) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack))

    match?({:deferred, _}, PolicyPack.automerge_window_status(pack, DateTime.utc_now()))
  end

  defp production_deploy_window_deferred?(state) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack))

    match?({:deferred, _}, PolicyPack.production_deploy_window_status(pack, DateTime.utc_now()))
  end

  defp defer_for_merge_window(workspace, issue, await_checks_attrs, state) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack))

    case PolicyPack.automerge_window_status(pack, DateTime.utc_now()) do
      {:deferred, wait} ->
        next_allowed_at = Map.get(wait, :next_allowed_at) || Map.get(wait, "next_allowed_at")

        summary =
          "Automerge is deferred until the next allowed merge window at #{next_allowed_at}."

        attrs =
          await_checks_attrs
          |> Map.put(:merge_window_wait, wait)
          |> Map.put(:last_rule_id, RuleCatalog.rule_id(:policy_merge_window_wait))
          |> Map.put(:last_failure_class, RuleCatalog.failure_class(:policy_merge_window_wait))
          |> Map.put(:last_decision_summary, summary)
          |> Map.put(:next_human_action, RuleCatalog.human_action(:policy_merge_window_wait))

        with {:ok, state} <- transition_state(workspace, "await_checks", attrs),
             :ok <- execution_guard(workspace, issue) do
          RunLedger.record("policy.decided", %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            stage: "await_checks",
            actor_type: "runtime",
            actor_id: "delivery_engine",
            policy_class: Map.get(state, :effective_policy_class),
            failure_class: RuleCatalog.failure_class(:policy_merge_window_wait),
            rule_id: RuleCatalog.rule_id(:policy_merge_window_wait),
            summary: summary,
            details: "Merge window deferred.",
            metadata: wait
          })

          :ok
        end

      :allowed ->
        :ok
    end
  end

  defp defer_for_production_deploy_window(workspace, issue, state) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack))

    case PolicyPack.production_deploy_window_status(pack, DateTime.utc_now()) do
      {:deferred, wait} ->
        next_allowed_at = Map.get(wait, :next_allowed_at) || Map.get(wait, "next_allowed_at")

        summary =
          "Production deploy is deferred until the next allowed deploy window at #{next_allowed_at}."

        attrs =
          %{deploy_window_wait: wait}
          |> Map.put(:last_rule_id, RuleCatalog.rule_id(:policy_deploy_window_wait))
          |> Map.put(:last_failure_class, RuleCatalog.failure_class(:policy_deploy_window_wait))
          |> Map.put(:last_decision_summary, summary)
          |> Map.put(:next_human_action, RuleCatalog.human_action(:policy_deploy_window_wait))

        with {:ok, _persisted_state} <- transition_state(workspace, "deploy_production", attrs),
             :ok <- execution_guard(workspace, issue) do
          RunLedger.record("policy.decided", %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            stage: "deploy_production",
            actor_type: "runtime",
            actor_id: "delivery_engine",
            summary: summary,
            target_state: "deploy_production",
            failure_class: RuleCatalog.failure_class(:policy_deploy_window_wait),
            rule_id: RuleCatalog.rule_id(:policy_deploy_window_wait),
            metadata: %{deploy_window_wait: wait}
          })

          :ok
        end

      :allowed ->
        :ok
    end
  end

  defp effective_required_checks(inspection, state) do
    base_checks =
      case inspection.harness do
        nil ->
          []

        harness ->
          Map.get(harness, :publish_required_checks, [])
          |> Kernel.++(Map.get(harness, :required_checks, []))
      end

    (base_checks ++ ui_proof_required_checks_from_state(state))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp ui_proof_required_checks_from_state(state) do
    Map.get(state, :ui_proof_required_checks, [])
  end

  defp ui_proof_required_checks(verifier_map) when is_map(verifier_map) do
    ui_proof = Map.get(verifier_map, :ui_proof, %{}) || %{}

    if SymphonyElixir.Util.truthy?(Map.get(ui_proof, :merge_required)) do
      Map.get(ui_proof, :required_checks, []) || []
    else
      []
    end
  end

  defp ui_proof_checks_active?(state), do: ui_proof_required_checks_from_state(state) != []

  defp ui_proof_checks_missing?(state, check_rollup) do
    ui_proof_missing_checks(state, check_rollup) != []
  end

  defp ui_proof_checks_failed?(state, check_rollup) do
    ui_proof_failed_checks(state, check_rollup) != []
  end

  defp ui_proof_missing_checks(state, check_rollup) do
    MapSet.intersection(
      MapSet.new(ui_proof_required_checks_from_state(state)),
      MapSet.new(check_rollup.missing)
    )
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp ui_proof_failed_checks(state, check_rollup) do
    MapSet.intersection(
      MapSet.new(ui_proof_required_checks_from_state(state)),
      MapSet.new(check_rollup.failed)
    )
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp maybe_sync_policy_override(state, workspace, opts) do
    with :ok <- execution_guard(workspace) do
      if Keyword.has_key?(opts, :policy_override) do
        override = opts |> Keyword.get(:policy_override) |> IssuePolicy.normalize_class() |> IssuePolicy.class_to_string()

        if Map.get(state, :policy_override) == override do
          state
        else
          with {:ok, persisted} <- update_state(workspace, %{policy_override: override}), do: persisted
        end
      else
        state
      end
    end
  end

  defp resolve_policy(issue, state, workspace) do
    with :ok <- execution_guard(workspace, issue) do
      pack = PolicyPack.resolve(Map.get(state, :policy_pack))

      with {:ok, resolution} <-
             IssuePolicy.resolve(issue,
               override: Map.get(state, :policy_override),
               default: Map.get(state, :effective_policy_class) || pack.default_issue_class,
               allowed_classes: pack.allowed_policy_classes,
               policy_pack: PolicyPack.name_string(pack)
             ),
           {:ok, persisted} <-
             update_state(workspace, %{
               effective_policy_class: IssuePolicy.class_to_string(resolution.class),
               effective_policy_source: Atom.to_string(resolution.source)
             }) do
        {:ok, resolution, persisted}
      end
    end
  end

  defp hold_for_policy_review(workspace, issue, state, await_checks_attrs, code, inspection, opts) do
    rule = RuleCatalog.rule(code)

    workflow_profile =
      WorkflowProfile.resolve(
        Map.get(state, :effective_policy_class),
        policy_pack: Map.get(state, :policy_pack)
      )

    approval_gate_state = workflow_profile.approval_gate_state

    with :ok <- execution_guard(workspace, issue),
         {:ok, state, evidence_handle} <- evidence_for_effect(workspace, issue, state, inspection, opts, :handoff),
         :ok <- guard_evidence_effect(workspace, issue, evidence_handle, :handoff),
         move_result <- maybe_move_issue(issue, approval_gate_state),
         :ok <- execution_guard(workspace, issue),
         :ok <- move_result,
         :ok <- guard_evidence_effect(workspace, issue, evidence_handle, :handoff),
         comment_result <-
           IssueSource.create_comment(
             issue,
             """
             ## Symphony policy hold

             Issue: #{issue.identifier}
             Rule ID: #{rule.rule_id}
             Failure class: #{rule.failure_class}

             #{approval_gate_summary(code, approval_gate_state)}

             #{rule.human_action}

             Unblock action: #{rule.human_action}
             """
             |> String.trim()
           ),
         :ok <- execution_guard(workspace, issue),
         :ok <- comment_result do
      ledger_event =
        RunLedger.record("policy.decided", %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          stage: "await_checks",
          actor_type: "runtime",
          actor_id: "delivery_engine",
          policy_class: Map.get(state, :effective_policy_class),
          failure_class: rule.failure_class,
          rule_id: rule.rule_id,
          summary: approval_gate_summary(code, approval_gate_state),
          details: rule.human_action,
          target_state: approval_gate_state
        })

      with {:ok, _persisted_state} <-
             transition_state(
               workspace,
               "await_checks",
               Map.merge(await_checks_attrs, %{
                 last_decision: %{
                   rule_id: rule.rule_id,
                   failure_class: rule.failure_class,
                   summary: approval_gate_summary(code, approval_gate_state),
                   details: rule.human_action,
                   human_action: rule.human_action,
                   target_state: approval_gate_state,
                   ledger_event_id: Map.get(ledger_event, :event_id)
                 },
                 last_rule_id: rule.rule_id,
                 last_failure_class: rule.failure_class,
                 last_decision_summary: approval_gate_summary(code, approval_gate_state),
                 next_human_action: rule.human_action
               })
             ),
           :ok <- execution_guard(workspace, issue) do
        :ok
      end
    end
  end

  defp detail_summary(:publish_missing_pr, _detail),
    do: "No PR is attached for the current branch."

  defp detail_summary(:policy_invalid_labels, _detail),
    do: "The issue has conflicting policy labels."

  defp detail_summary(code, detail), do: "#{code}: #{String.slice(detail, 0, 160)}"

  defp approval_gate_summary(:policy_review_required, approval_gate_state),
    do: "Policy requires #{approval_gate_state} before merge."

  defp approval_gate_summary(:policy_never_automerge, approval_gate_state),
    do: "Policy routes this issue to #{approval_gate_state} instead of automerge."

  defp approval_gate_summary(:risk_review_required, approval_gate_state),
    do: "High-risk contractor work requires #{approval_gate_state} before merge."

  defp approval_gate_summary(_code, approval_gate_state),
    do: "Waiting in #{approval_gate_state}."

  defp risk_review_required?(workspace, inspection, workflow_profile, state) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack) || Config.policy_pack_name())

    if PolicyPack.contractor_mode?(pack) do
      with :ok <- execution_guard(workspace),
           changed_paths <- RunInspector.changed_paths(workspace),
           :ok <- execution_guard(workspace) do
        harness =
          if inspection.harness,
            do: Map.get(inspection.harness, :raw) || inspection.harness,
            else: nil

        risk =
          SymphonyElixir.RiskClassifier.classify(
            %{changed_paths: changed_paths},
            %{workspace: workspace},
            harness,
            workflow_profile
          )

        risk.risk_level == "high"
      end
    else
      false
    end
  end

  defp merge_limit_reached?(state) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack) || Config.policy_pack_name())

    case pack.max_merges_per_day_per_repo do
      limit when is_integer(limit) and limit > 0 ->
        today = Date.utc_today() |> Date.to_iso8601()

        RunLedger.recent_entries(500)
        |> Enum.count(fn entry ->
          (Map.get(entry, "event_type") || Map.get(entry, :event_type) || Map.get(entry, "event")) ==
            "merge.completed" and
            String.starts_with?(
              to_string(Map.get(entry, "at") || Map.get(entry, :at) || ""),
              today
            )
        end) >= limit

      _ ->
        false
    end
  end
end
