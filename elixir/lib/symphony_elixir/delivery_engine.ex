defmodule SymphonyElixir.DeliveryEngine do
  @moduledoc """
  Runtime-owned delivery engine for checkout, implementation, validation, publish, merge, post-merge closure, and optional preview deployment.
  """

  # credo:disable-for-this-file

  require Logger

  alias SymphonyElixir.Codex.{AppServer, DynamicTool}
  alias SymphonyElixir.AgentHarness
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitManager
  alias SymphonyElixir.IssueAcceptance
  alias SymphonyElixir.IssueSource
  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.Observability
  alias SymphonyElixir.PolicyPack
  alias SymphonyElixir.PullRequestManager
  alias SymphonyElixir.RepoMap
  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStateStore
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
  @codex_turn_error_methods ["codex/event/stream_error", "codex/event/error", "error"]
  @passive_stages [
    "await_checks",
    "merge",
    "post_merge",
    "deploy_preview",
    "deploy_production",
    "post_deploy_verify"
  ]

  @spec run(Path.t(), Issue.t(), pid() | nil, keyword()) ::
          :ok | {:done, Issue.t()} | {:stop, term()} | {:error, term()}
  def run(workspace, %Issue{} = issue, codex_update_recipient, opts \\ [])
      when is_binary(workspace) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &IssueSource.fetch_issue_states_by_ids/1)

    stage = current_stage(workspace, issue)

    if passive_stage?(stage) do
      Logger.info("Skipping Codex session bootstrap for passive stage #{stage} issue=#{issue.identifier} workspace=#{workspace}")

      do_run(nil, workspace, issue, codex_update_recipient, issue_state_fetcher, max_turns, opts)
    else
      Logger.info("Starting Codex session bootstrap for #{issue.identifier} workspace=#{workspace}")

      with {:ok, app_session} <- AppServer.start_session(workspace) do
        Logger.info("Codex session bootstrap succeeded for #{issue.identifier} thread_id=#{app_session.thread_id}")

        try do
          do_run(
            app_session,
            workspace,
            issue,
            codex_update_recipient,
            issue_state_fetcher,
            max_turns,
            opts
          )
        after
          AppServer.stop_session(app_session)
        end
      else
        {:error, reason} = error ->
          Logger.error("Codex session bootstrap failed for #{issue.identifier}: #{inspect(reason)}")

          error
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
  @spec codex_message_handler_for_test(pid() | nil, term()) :: term()
  def codex_message_handler_for_test(recipient, issue),
    do: codex_message_handler(recipient, issue)

  @doc false
  @spec normalize_state_for_test(term()) :: term()
  def normalize_state_for_test(state), do: normalize_state(state)

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
  @spec maybe_sync_policy_override_for_test(map(), Path.t(), keyword()) :: map()
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
  @spec implement_prompt_for_test(term(), map(), keyword(), non_neg_integer(), pos_integer()) ::
          String.t()
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

  defp do_run(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         issue_state_fetcher,
         max_turns,
         opts
       ) do
    state =
      workspace
      |> RunStateStore.load_or_default(issue)
      |> maybe_sync_policy_override(workspace, opts)

    workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))
    max_turns = workflow_profile.max_turns_override || max_turns

    stage = Map.get(state, :stage, "checkout")
    inspection = RunInspector.inspect(workspace, opts)

    Observability.with_stage(stage, issue_observability_metadata(issue, state), fn ->
      case stage do
        "checkout" ->
          handle_checkout(
            app_session,
            workspace,
            issue,
            codex_update_recipient,
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
            codex_update_recipient,
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
            codex_update_recipient,
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
            codex_update_recipient,
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
            codex_update_recipient,
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
            codex_update_recipient,
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
            codex_update_recipient,
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
            codex_update_recipient,
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

  defp issue_observability_metadata(issue, state) do
    Observability.issue_metadata(issue, state, %{
      workflow_profile: Map.get(state, :effective_policy_class),
      operating_mode: Config.company_mode()
    })
  end

  defp current_stage(workspace, issue) do
    case RunStateStore.load_or_default(workspace, issue) do
      %{stage: stage} when is_binary(stage) -> stage
      _ -> "checkout"
    end
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
    with {:ok, branch_info} <-
           GitManager.prepare_issue_branch(workspace, issue, inspection.harness, opts),
         {:ok, harness} <- RepoHarness.load(workspace),
         {:ok, policy_resolution} <- resolve_policy(issue, state, workspace),
         next_stage <-
           if(AgentHarness.enabled?(harness), do: "initialize_harness", else: "implement"),
         {:ok, _state} <-
           RunStateStore.transition(workspace, next_stage, %{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             branch: branch_info.branch,
             base_branch: branch_info.base_branch,
             harness_version: harness.version,
             effective_policy_class: IssuePolicy.class_to_string(policy_resolution.class),
             effective_policy_source: Atom.to_string(policy_resolution.source)
           }),
         :ok <- maybe_move_issue(issue, @in_progress_state) do
      do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
    else
      error -> handle_checkout_error(workspace, issue, error)
    end
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

    case AgentHarness.initialize(workspace, issue, harness) do
      {:ok, attrs} ->
        {:ok, _state} =
          RunStateStore.transition(
            workspace,
            "implement",
            Map.merge(
              %{
                last_harness_init: Map.merge(attrs, %{status: "passed"}),
                last_harness_check: %{
                  status: "passed",
                  checked_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
                },
                harness_status: "ready",
                harness_attempts: Map.get(state, :harness_attempts, 0) + 1
              },
              attrs
            )
          )

        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

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
    implementation_turns = Map.get(state, :implementation_turns, 0)

    if implementation_turns >= max_turns do
      block_issue(
        workspace,
        issue,
        :turn_budget_exhausted,
        "Reached #{max_turns} implementation turns without a mergeable result.",
        @blocked_state
      )
    else
      before_snapshot = RunInspector.inspect(workspace, opts)

      prompt =
        implement_prompt(
          issue,
          state,
          workspace,
          before_snapshot,
          opts,
          implementation_turns + 1,
          max_turns
        )

      clear_turn_result(issue)
      clear_turn_runtime_errors(issue)

      try do
        with {:ok, _turn_session} <-
               AppServer.run_turn(
                 app_session,
                 prompt,
                 issue,
                 Keyword.merge(
                   opts,
                   stage: "implement",
                   effort: Config.codex_turn_effort("implement"),
                   forbidden_commands: implement_forbidden_commands(before_snapshot.harness),
                   command_output_budget: implement_command_output_budget(),
                   on_message: codex_message_handler(recipient, issue),
                   tool_executor: tool_executor(issue, opts)
                 )
               ),
             {:ok, turn_result} <- fetch_turn_result(issue),
             after_snapshot <- RunInspector.inspect(workspace, opts),
             {:ok, refreshed_issue} <- refresh_issue(issue, fetcher),
             :ok <- ensure_issue_still_active(refreshed_issue),
             {:ok, next_stage} <-
               implement_next_stage(turn_result, before_snapshot, after_snapshot),
             {:ok, _state} <-
               RunStateStore.transition(
                 workspace,
                 next_stage,
                 Map.merge(
                   %{
                     implementation_turns: implementation_turns + 1,
                     last_turn_result: TurnResult.to_map(turn_result),
                     branch: after_snapshot.branch || Map.get(state, :branch),
                     pr_url: after_snapshot.pr_url || Map.get(state, :pr_url)
                   },
                   resume_context_attrs(
                     workspace,
                     refreshed_issue,
                     state,
                     after_snapshot,
                     %{
                       last_turn_summary: turn_result.summary,
                       next_objective: next_objective_for_stage(next_stage, turn_result)
                     },
                     opts
                   )
                 )
               ) do
          do_run(app_session, workspace, refreshed_issue, recipient, fetcher, max_turns, opts)
        else
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
      after
        clear_turn_result(issue)
        clear_turn_runtime_errors(issue)
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
    result = RunInspector.run_validation(workspace, inspection.harness, opts)
    validation_attempts = Map.get(state, :validation_attempts, 0) + 1

    RunLedger.record("validation.completed", %{
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
        attempt: validation_attempts
      }
    })

    case result.status do
      :passed ->
        {:ok, _state} =
          RunStateStore.transition(
            workspace,
            "verify",
            Map.merge(
              %{
                validation_attempts: validation_attempts,
                last_validation: command_result_to_map(result)
              },
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
              )
            )
          )

        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

      :failed ->
        if Config.policy_retry_validation_failures_within_run?() and
             validation_attempts < Config.policy_max_validation_attempts_per_run() and
             Map.get(state, :implementation_turns, 0) < max_turns do
          {:ok, _state} =
            RunStateStore.transition(
              workspace,
              "implement",
              Map.merge(
                %{
                  validation_attempts: validation_attempts,
                  last_validation: command_result_to_map(result)
                },
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
                )
              )
            )

          do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
        else
          block_issue(workspace, issue, :validation_failed, result.output, @blocked_state)
        end

      :unavailable ->
        block_issue(workspace, issue, :validation_unavailable, result.output, @blocked_state)
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
    if Config.policy_require_verifier?() do
      verifier_runner = Keyword.get(opts, :verifier_runner, &VerifierRunner.verify/5)
      result = verifier_runner.(workspace, issue, state, inspection, opts)
      verification_attempts = Map.get(state, :verification_attempts, 0) + 1

      verifier_summary =
        Map.get(result, :summary) || Map.get(result, "summary") || inspect(result)

      RunLedger.record("verification.completed", %{
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
          attempt: verification_attempts
        }
      })

      case Map.get(result, :verdict) || Map.get(result, "verdict") do
        "pass" ->
          verifier_map = verifier_result_to_map(result)

          {:ok, _state} =
            RunStateStore.transition(
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
                )
              )
            )

          do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

        "needs_more_work" ->
          reason_code = Map.get(result, :reason_code) || Map.get(result, "reason_code")

          if should_retry_verification?(reason_code, verification_attempts, state, max_turns) do
            {:ok, _state} =
              RunStateStore.transition(
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
                  )
                )
              )

            do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
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
              @blocked_state
            )
          end

        "blocked" ->
          block_issue(
            workspace,
            issue,
            :verifier_blocked,
            get_in(result, [:summary]) || get_in(result, ["summary"]) || inspect(result),
            @blocked_state
          )

        "unsafe_to_merge" ->
          block_issue(
            workspace,
            issue,
            :unsafe_to_merge,
            get_in(result, [:summary]) || get_in(result, ["summary"]) || inspect(result),
            @blocked_state
          )

        other ->
          block_issue(
            workspace,
            issue,
            :verifier_failed,
            "Verifier returned an unknown verdict: #{inspect(other)}",
            @blocked_state
          )
      end
    else
      {:ok, _state} = RunStateStore.transition(workspace, "publish", %{})
      do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
    end
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
    if Config.policy_publish_required?() do
      with :ok <-
             maybe_enforce_agent_harness_publish_gate(workspace, issue, inspection.harness, opts) do
        case GitManager.commit_all(
               workspace,
               issue,
               get_in(state, [:last_turn_result, :summary]) || issue.title || "Automated update",
               opts
             ) do
          {:ok, :noop} ->
            if is_nil(inspection.pr_url) and
                 not branch_has_publishable_changes?(workspace, state, opts) do
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

          {:ok, %{sha: sha}} ->
            with branch when is_binary(branch) <- Map.get(state, :branch) || inspection.branch,
                 :ok <- GitManager.push_branch(workspace, branch, opts),
                 {:ok, _state} <-
                   RunStateStore.update(workspace, &Map.put(&1, :last_commit_sha, sha)) do
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
              {:error, reason} ->
                block_issue(workspace, issue, :publish_failed, inspect(reason), @blocked_state)

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
            block_issue(workspace, issue, :publish_failed, inspect(reason), @blocked_state)
        end
      else
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
      {:ok, _state} = RunStateStore.transition(workspace, "await_checks", %{})
      do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
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
    with {:ok, pr} <- PullRequestManager.ensure_pull_request(workspace, issue, state, opts),
         :ok <- maybe_move_issue(issue, @merging_state),
         {:ok, _state} <-
           RunStateStore.transition(workspace, "await_checks", %{
             pr_url: pr.url,
             publish_attempts: Map.get(state, :publish_attempts, 0) + 1,
             await_checks_polls: 0,
             last_pr_body_validation: Map.get(pr, :body_validation)
           }) do
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
      {:error, reason} ->
        block_issue(workspace, issue, :publish_failed, inspect(reason), @blocked_state)
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
    await_checks_polls = Map.get(state, :await_checks_polls, 0) + 1
    required_checks = effective_required_checks(inspection, state)
    check_rollup = RunInspector.required_checks_rollup(required_checks, inspection.check_statuses)
    await_checks_attrs = await_checks_state_attrs(inspection, check_rollup, await_checks_polls)
    policy_resolution = resolve_policy(issue, state, workspace)

    effective_policy_class =
      case policy_resolution do
        {:ok, resolution} -> IssuePolicy.class_to_string(resolution.class)
        _ -> Map.get(state, :effective_policy_class)
      end

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

    cond do
      match?({:error, _}, policy_resolution) ->
        {:error, policy_reason} = policy_resolution

        block_issue(
          workspace,
          issue,
          policy_reason.code,
          Enum.join(policy_reason.labels, ", "),
          @blocked_state
        )

      is_nil(inspection.pr_url) ->
        block_issue(
          workspace,
          issue,
          :publish_missing_pr,
          "No PR is attached for the current branch.",
          @blocked_state
        )

      merged_pull_request?(inspection) ->
        {:ok, _state} =
          RunStateStore.transition(
            workspace,
            "post_merge",
            Map.merge(await_checks_attrs, %{
              last_merge: %{status: :already_merged, url: inspection.pr_url}
            })
          )

        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

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
        block_issue(
          workspace,
          issue,
          :required_checks_failed,
          "Required checks failed on the PR: #{Enum.join(check_rollup.failed, ", ")}",
          @blocked_state
        )

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
        risk_review_required?(workspace, inspection, workflow_profile, state) and
          Map.get(state, :review_approved, false) == false ->
        hold_for_policy_review(workspace, issue, state, await_checks_attrs, :risk_review_required)

      RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :automerge and
        Config.policy_automerge_on_green?() and
        Map.get(state, :automerge_disabled, false) == false and
          merge_window_deferred?(state) ->
        defer_for_merge_window(workspace, issue, await_checks_attrs, state)

      RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :automerge and
        Config.policy_automerge_on_green?() and
          Map.get(state, :automerge_disabled, false) == false ->
        {:ok, _state} =
          RunStateStore.transition(workspace, "merge", await_checks_attrs)

        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

      RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :review_gate and
          Map.get(state, :review_approved, false) == true ->
        {:ok, _state} =
          RunStateStore.transition(workspace, "merge", await_checks_attrs)

        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

      RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :review_gate ->
        hold_for_policy_review(
          workspace,
          issue,
          state,
          await_checks_attrs,
          :policy_review_required
        )

      RunInspector.ready_for_merge?(inspection) and workflow_profile.merge_mode == :manual_only ->
        hold_for_policy_review(
          workspace,
          issue,
          state,
          await_checks_attrs,
          :policy_never_automerge
        )

      RunInspector.ready_for_merge?(inspection) ->
        hold_for_policy_review(
          workspace,
          issue,
          state,
          await_checks_attrs,
          :policy_review_required
        )

      true ->
        {:ok, _state} = RunStateStore.transition(workspace, "await_checks", await_checks_attrs)

        :ok
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
          {:ok, _state} =
            RunStateStore.transition(workspace, "post_merge", %{
              pr_url: inspection.pr_url,
              last_pr_state: inspection.pr_state,
              last_merge: %{status: :already_merged, url: inspection.pr_url},
              merge_attempts: Map.get(state, :merge_attempts, 0)
            })

          do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

        closed_pull_request?(inspection) ->
          block_issue(
            workspace,
            issue,
            :pr_closed,
            "The PR closed before Symphony could merge it.",
            @blocked_state
          )

        RunInspector.ready_for_merge?(inspection) ->
          case PullRequestManager.merge_pull_request(workspace, opts) do
            {:ok, %{url: url, status: merge_status} = merge_result} ->
              {:ok, _state} =
                RunStateStore.transition(workspace, "post_merge", %{
                  pr_url: url,
                  merge_attempts: Map.get(state, :merge_attempts, 0) + 1,
                  last_pr_state: inspection.pr_state,
                  last_merge: %{
                    status: merge_status,
                    url: url,
                    output: String.slice(to_string(Map.get(merge_result, :output, "")), 0, 2_000)
                  }
                })

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

            {:error, reason} ->
              block_issue(workspace, issue, :merge_failed, inspect(reason), @blocked_state)
          end

        true ->
          {:ok, _state} =
            RunStateStore.transition(
              workspace,
              "await_checks",
              await_checks_state_attrs(
                inspection,
                RunInspector.required_checks_rollup(inspection),
                Map.get(state, :await_checks_polls, 0)
              )
            )

          :ok
      end
    end
  end

  defp handle_post_merge(workspace, issue, state, inspection, opts) do
    workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))

    with :ok <- GitManager.reset_to_base(workspace, inspection.harness, opts),
         :ok <-
           maybe_post_merge_verify(
             workspace,
             issue,
             inspection.harness,
             Keyword.put(opts, :workflow_profile, workflow_profile)
           ),
         result <-
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

      _command ->
        result = RunInspector.run_deploy_preview(workspace, inspection.harness, opts)

        case result.status do
          :passed ->
            {:ok, _state} =
              RunStateStore.update(workspace, fn current ->
                current
                |> Map.put(:last_deploy_preview, command_result_to_map(result))
                |> Map.put(:last_decision, nil)
              end)

            RunLedger.record("deploy.preview.completed", %{
              issue_id: issue.id,
              issue_identifier: issue.identifier,
              stage: "deploy_preview",
              actor_type: "runtime",
              actor_id: "delivery_engine",
              summary: "Preview deploy completed",
              details: String.slice(to_string(result.output || ""), 0, 500),
              metadata: %{command: result.command}
            })

            if post_deploy_verification_required?(
                 inspection.harness,
                 WorkflowProfile.resolve(Map.get(state, :effective_policy_class))
               ) do
              {:ok, _state} =
                RunStateStore.transition(workspace, "post_deploy_verify", %{
                  issue_id: issue.id,
                  issue_identifier: issue.identifier,
                  issue_source: issue.source,
                  current_deploy_target: "preview",
                  last_decision_summary: "Preview deployment completed. Running post-deploy verification."
                })

              :ok
            else
              finalize_done(workspace, issue, state)
            end

          _ ->
            block_issue(
              workspace,
              issue,
              :deploy_preview_failed,
              to_string(result.output || ""),
              @blocked_state
            )
        end
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

      _command ->
        if production_deploy_window_deferred?(state) do
          defer_for_production_deploy_window(workspace, issue, state)
        else
          result = RunInspector.run_deploy_production(workspace, inspection.harness, opts)

          case result.status do
            :passed ->
              {:ok, _state} =
                RunStateStore.update(workspace, fn current ->
                  current
                  |> Map.put(:last_deploy_production, command_result_to_map(result))
                  |> Map.put(:current_deploy_target, "production")
                  |> Map.put(:deploy_window_wait, nil)
                  |> Map.put(:deploy_approved, false)
                  |> Map.put(:last_decision, nil)
                end)

              RunLedger.record("deploy.production.completed", %{
                issue_id: issue.id,
                issue_identifier: issue.identifier,
                stage: "deploy_production",
                actor_type: "runtime",
                actor_id: "delivery_engine",
                summary: "Production deploy completed",
                details: String.slice(to_string(result.output || ""), 0, 500),
                metadata: %{command: result.command}
              })

              if post_deploy_verification_required?(
                   inspection.harness,
                   WorkflowProfile.resolve(Map.get(state, :effective_policy_class))
                 ) do
                {:ok, _state} =
                  RunStateStore.transition(workspace, "post_deploy_verify", %{
                    issue_id: issue.id,
                    issue_identifier: issue.identifier,
                    issue_source: issue.source,
                    current_deploy_target: "production",
                    last_decision_summary: "Production deployment completed. Running post-deploy verification."
                  })

                :ok
              else
                finalize_done(workspace, issue, state)
              end

            _ ->
              block_issue(
                workspace,
                issue,
                :deploy_production_failed,
                to_string(result.output || ""),
                @blocked_state
              )
          end
        end
    end
  end

  defp handle_post_deploy_verify(workspace, issue, state, inspection, opts) do
    result = RunInspector.run_post_deploy_verify(workspace, inspection.harness, opts)
    deploy_target = Map.get(state, :current_deploy_target, "preview")
    workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))

    case result.status do
      :passed ->
        {:ok, _state} =
          RunStateStore.update(workspace, fn current ->
            current
            |> Map.put(:last_post_deploy_verify, command_result_to_map(result))
            |> Map.put(:last_decision, nil)
          end)

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
          :continue ->
            finalize_done(workspace, issue, state)

          {:transitioned, "deploy_production"} ->
            :ok

          {:waiting_for_approval, approval_state} ->
            {:ok, _state} =
              RunStateStore.update(workspace, fn current ->
                current
                |> Map.put(:deploy_approved, false)
                |> Map.put(
                  :last_decision_summary,
                  "Waiting in #{approval_state} before production deployment."
                )
              end)

            :ok

          {:error, :missing_production_deploy} ->
            block_issue(
              workspace,
              issue,
              :deploy_production_missing,
              "Production deployment is enabled for this workflow profile but the repo harness does not declare `deploy.production.command`.",
              @blocked_state
            )
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

  defp maybe_post_merge_verify(workspace, issue, harness, opts) do
    workflow_profile = Keyword.get(opts, :workflow_profile, WorkflowProfile.resolve(nil))

    if Config.policy_post_merge_verification_required?() and
         workflow_profile.post_merge_verification_required do
      result = VerifierRunner.post_merge_verify(workspace, harness, opts)

      case result.status do
        :passed ->
          {:ok, _state} =
            RunStateStore.update(workspace, fn state ->
              state
              |> Map.put(:last_post_merge, command_result_to_map(result))
              |> Map.put(:last_decision, nil)
            end)

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

          :ok

        :failed ->
          {:error, {:post_merge_rework, result.output}}

        :unavailable ->
          {:error, {:post_merge_unavailable, result.output}}
      end
    else
      :ok
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
        :continue

      is_nil(harness) or is_nil(harness.deploy_preview_command) ->
        {:error, :missing_preview_deploy}

      true ->
        {:ok, _state} =
          RunStateStore.transition(workspace, "deploy_preview", %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            issue_source: issue.source,
            last_decision_summary: "Post-merge verification passed. Starting preview deployment.",
            effective_policy_class: Map.get(state, :effective_policy_class)
          })

        {:transitioned, "deploy_preview"}
    end
  end

  defp maybe_begin_production_deploy(workspace, issue, state, harness, workflow_profile) do
    cond do
      Map.get(state, :current_deploy_target) == "production" ->
        :continue

      workflow_profile.production_deploy_mode != :after_preview ->
        :continue

      is_nil(harness) or is_nil(harness.deploy_production_command) ->
        {:error, :missing_production_deploy}

      deploy_approval_required?(workflow_profile) and not Map.get(state, :deploy_approved, false) ->
        approval_state = workflow_profile.deploy_approval_gate_state
        :ok = maybe_move_issue(issue, approval_state)

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

        {:waiting_for_approval, approval_state}

      true ->
        {:ok, _state} =
          RunStateStore.transition(workspace, "deploy_production", %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            issue_source: issue.source,
            last_decision_summary: "Post-deploy verification passed. Starting production deployment.",
            effective_policy_class: Map.get(state, :effective_policy_class),
            current_deploy_target: "production"
          })

        {:transitioned, "deploy_production"}
    end
  end

  defp finalize_done(workspace, issue, state) do
    finalization_summary = finalization_summary(state)

    with :ok <- maybe_move_issue(issue, @done_state),
         {:ok, _state} <-
           RunStateStore.transition(workspace, "done", %{
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
    resume_context = resume_context_for_prompt(workspace, issue, state, inspection)
    token_pressure = token_pressure_note(state)
    repo_map = RepoMap.from_harness(inspection.harness)
    workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))

    [
      "You are implementing ticket `#{issue.identifier}`.",
      "",
      "Title: #{to_string(issue.title || "Untitled issue")}",
      repo_platform_note(inspection),
      "Current implementation turn: #{turn_number} of #{max_turns}.",
      "",
      "Issue brief:",
      summarized_text(issue.description || "No description provided.", 2_500),
      "",
      "Resolved workflow profile: #{WorkflowProfile.name_string(workflow_profile)} (merge mode #{workflow_profile.merge_mode}).",
      "",
      RepoMap.prompt_block(repo_map),
      "",
      "Acceptance summary:",
      summarized_text(acceptance.summary, 1_200),
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
      "- At the end of the turn, call `#{@report_turn_result_tool}` exactly once.",
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
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
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
        context when is_map(context) -> context
        _ -> %{}
      end

    if resume_context_stale?(stored, inspection) do
      Map.merge(
        fresh_resume_context(workspace, issue, state, inspection, %{}),
        preserved_resume_context(stored)
      )
    else
      Map.merge(fresh_resume_context(workspace, issue, state, inspection, %{}), stored)
    end
  end

  defp resume_context_stale?(context, inspection) when is_map(context) do
    Map.get(context, :fingerprint) != inspection.fingerprint
  end

  defp fresh_resume_context(workspace, issue, state, inspection, overrides) do
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
      dirty_files: RunInspector.changed_paths(workspace) |> Enum.take(20),
      diff_summary: summarized_diff_summary(RunInspector.diff_summary(workspace), 30),
      last_blocking_rule: get_in(state, [:stop_reason, :code]) || Map.get(state, :last_rule_id),
      review_feedback_summary:
        Map.get(overrides, :review_feedback_summary) ||
          review_feedback_summary(Map.get(state, :review_threads, %{})),
      next_objective:
        Map.get(overrides, :next_objective) ||
          "Advance the diff so it is ready for runtime validation without running the repo contract yourself."
    }
    |> Map.merge(Enum.into(overrides, %{}))
  end

  defp preserved_resume_context(context) when is_map(context) do
    context
    |> Map.take([:next_objective, :review_feedback_summary, :review_feedback_pr_url])
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
    %{resume_context: fresh_resume_context(workspace, issue, state, inspection, overrides)}
  end

  defp resume_context_block(resume_context) when is_map(resume_context) do
    [
      maybe_named_line("Last implementation summary", resume_context[:last_turn_summary], 400),
      maybe_named_line(
        "Latest validation summary",
        resume_context[:last_validation_summary],
        800
      ),
      maybe_named_line("Latest verifier summary", resume_context[:last_verifier_summary], 800),
      maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200),
      maybe_named_multiline(
        "Pending PR review feedback",
        resume_context[:review_feedback_summary]
      ),
      maybe_named_list("Dirty files", resume_context[:dirty_files], 20),
      maybe_named_multiline("Diff stat", resume_context[:diff_summary])
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No prior resume context recorded."
      lines -> Enum.join(lines, "\n")
    end
  end

  defp token_pressure_note(state) do
    case get_in(state, [:resume_context, :token_pressure]) do
      "high" ->
        "\nToken pressure is high. Keep reads narrow, avoid repeated scans, and do not reprint prior evidence."

      _ ->
        nil
    end
  end

  defp maybe_named_line(_label, nil, _limit), do: nil

  defp maybe_named_line(label, value, limit) do
    "#{label}: #{summarized_text(value, limit)}"
  end

  defp maybe_named_multiline(_label, nil), do: nil
  defp maybe_named_multiline(label, value), do: "#{label}:\n#{value}"

  defp review_feedback_summary(review_threads) when is_map(review_threads) do
    review_threads
    |> Enum.sort_by(fn {thread_key, _thread_state} -> thread_key end)
    |> Enum.take(8)
    |> Enum.map(fn {_thread_key, thread_state} ->
      kind = Map.get(thread_state, "kind") || "comment"

      location =
        case {Map.get(thread_state, "path"), Map.get(thread_state, "line")} do
          {path, line} when is_binary(path) and is_integer(line) -> " #{path}:#{line}"
          {path, _line} when is_binary(path) -> " #{path}"
          _ -> ""
        end

      body =
        thread_state
        |> Map.get("body")
        |> to_string()
        |> String.trim()
        |> String.replace(~r/\s+/, " ")
        |> summarized_text(280)

      "- #{kind}#{location}: #{body}"
    end)
    |> Enum.reject(&String.ends_with?(&1, ": "))
    |> Enum.join("\n")
    |> case do
      "" -> nil
      summary -> summary
    end
  end

  defp review_feedback_summary(_review_threads), do: nil

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

  defp implement_command_output_budget do
    %{
      stage: "implement",
      per_command_bytes: 8_192,
      per_turn_bytes: 32_768,
      max_command_count: 12
    }
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
      :ok -> {:ok, "validate"}
      {:error, reason} -> {:error, reason}
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
    if normalize_state(current_state) == normalize_state(target_state) do
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
    attempts = Map.get(state, :implementation_turns, 0) + 1
    summary = implementation_turn_error_summary(reason)

    with {:ok, refreshed_issue} <- refresh_issue(issue, fetcher),
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
        {:ok, _state} =
          RunStateStore.transition(workspace, "implement", %{
            implementation_turns: attempts,
            last_implementation_error: %{
              summary: summary,
              reason: implementation_error_to_map(reason)
            },
            reason: "Retrying implementation after Codex turn error: #{summary}"
          })

        do_run(app_session, workspace, refreshed_issue, recipient, fetcher, max_turns, opts)
      end
    else
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
        "Codex turn failed: #{safe_detail_text(details)}"
    end
  end

  defp implementation_turn_error_summary({:port_exit, status}),
    do: "Codex app-server exited during the turn with status #{status}."

  defp implementation_turn_error_summary(:turn_timeout),
    do: "Codex turn timed out before completing."

  defp implementation_turn_error_summary({:codex_notification_error, method, details}),
    do: "Codex reported #{method}: #{safe_detail_text(details)}"

  defp implementation_turn_error_summary({:turn_cancelled, details}),
    do: "Codex turn was cancelled: #{safe_detail_text(details)}"

  defp implementation_turn_error_summary({:approval_required, details}),
    do: "Codex requested approval unexpectedly: #{safe_detail_text(details)}"

  defp implementation_turn_error_summary({:turn_input_required, details}),
    do: "Codex requested operator input unexpectedly: #{safe_detail_text(details)}"

  defp implementation_turn_error_summary(reason), do: safe_detail_text(reason)

  defp implementation_error_to_map(reasons) when is_list(reasons),
    do: Enum.map(reasons, &implementation_error_to_map/1)

  defp implementation_error_to_map({:codex_notification_error, method, details}),
    do: %{type: "codex_notification_error", method: method, details: safe_detail_text(details)}

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

  defp refresh_issue(%Issue{id: issue_id}, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} -> {:ok, refreshed_issue}
      {:ok, []} -> {:done, :missing}
      {:error, reason} -> {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp block_issue(workspace, issue, code, details, target_state) do
    issue_id = issue.id
    issue_identifier = issue.identifier || issue.id || "unknown"
    detail_text = safe_detail_text(details)
    rule = RuleCatalog.rule(code)
    run_state = RunStateStore.load_or_default(workspace, issue)

    ledger_event =
      RunLedger.record("runtime.stopped", %{
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
        metadata: %{
          code: Atom.to_string(code),
          human_action: rule.human_action
        }
      })

    if is_binary(issue_id) do
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
      )

      IssueSource.update_issue_state(issue, target_state)
    end

    RunStateStore.transition(workspace, "blocked", %{
      stop_reason: %{
        code: to_string(code),
        rule_id: rule.rule_id,
        failure_class: rule.failure_class,
        details: detail_text
      },
      last_decision: %{
        rule_id: rule.rule_id,
        failure_class: rule.failure_class,
        summary: detail_summary(code, detail_text),
        details: detail_text,
        human_action: rule.human_action,
        target_state: target_state,
        ledger_event_id: Map.get(ledger_event, :event_id)
      },
      last_rule_id: rule.rule_id,
      last_failure_class: rule.failure_class,
      last_decision_summary: detail_summary(code, detail_text),
      next_human_action: rule.human_action
    })

    {:stop, code}
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

  defp codex_message_handler(recipient, issue) do
    fn message ->
      maybe_capture_turn_runtime_error(issue, message)

      if is_pid(recipient) and is_binary(issue.id) do
        send(recipient, {:codex_worker_update, issue.id, message})
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
       when method in @codex_turn_error_methods do
    record_turn_runtime_error(
      issue,
      {:codex_notification_error, method, Map.get(payload, "params", %{})}
    )
  end

  defp maybe_capture_turn_runtime_error(_issue, _message), do: :ok

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp truthy?(value), do: value in [true, "true", true, 1, "1"]

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_state(active_state) == normalized_state end)
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

        {:ok, _state} = RunStateStore.transition(workspace, "await_checks", attrs)

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
          state
          |> Map.put(:deploy_window_wait, wait)
          |> Map.put(:last_rule_id, RuleCatalog.rule_id(:policy_deploy_window_wait))
          |> Map.put(:last_failure_class, RuleCatalog.failure_class(:policy_deploy_window_wait))
          |> Map.put(:last_decision_summary, summary)
          |> Map.put(:next_human_action, RuleCatalog.human_action(:policy_deploy_window_wait))

        {:ok, _state} = RunStateStore.transition(workspace, "deploy_production", attrs)

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

    if truthy?(Map.get(ui_proof, :merge_required)) do
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
    if Keyword.has_key?(opts, :policy_override) do
      override =
        opts
        |> Keyword.get(:policy_override)
        |> IssuePolicy.normalize_class()
        |> IssuePolicy.class_to_string()

      if Map.get(state, :policy_override) == override do
        state
      else
        {:ok, updated_state} =
          RunStateStore.update(workspace, fn persisted_state ->
            Map.put(persisted_state, :policy_override, override)
          end)

        updated_state
      end
    else
      state
    end
  end

  defp resolve_policy(issue, state, workspace) do
    pack = PolicyPack.resolve(Map.get(state, :policy_pack))
    persisted_policy_class = Map.get(state, :effective_policy_class)

    case IssuePolicy.resolve(issue,
           override: Map.get(state, :policy_override),
           default: persisted_policy_class || pack.default_issue_class,
           allowed_classes: pack.allowed_policy_classes,
           policy_pack: PolicyPack.name_string(pack)
         ) do
      {:ok, resolution} ->
        {:ok, _state} =
          RunStateStore.update(workspace, fn persisted_state ->
            persisted_state
            |> Map.put(:effective_policy_class, IssuePolicy.class_to_string(resolution.class))
            |> Map.put(:effective_policy_source, Atom.to_string(resolution.source))
          end)

        {:ok, resolution}

      {:error, conflict} ->
        {:error, conflict}
    end
  end

  defp hold_for_policy_review(workspace, issue, state, await_checks_attrs, code) do
    rule = RuleCatalog.rule(code)

    workflow_profile =
      WorkflowProfile.resolve(
        Map.get(state, :effective_policy_class),
        policy_pack: Map.get(state, :policy_pack)
      )

    approval_gate_state = workflow_profile.approval_gate_state

    :ok = maybe_move_issue(issue, approval_gate_state)

    :ok =
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
      )

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

    {:ok, _state} =
      RunStateStore.transition(
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
      )

    :ok
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
      changed_paths = RunInspector.changed_paths(workspace)

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
