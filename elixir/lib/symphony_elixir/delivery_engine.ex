defmodule SymphonyElixir.DeliveryEngine do
  @moduledoc """
  Runtime-owned delivery engine for checkout, implementation, validation, publish, merge, and post-merge closure.
  """

  # credo:disable-for-this-file

  require Logger

  alias SymphonyElixir.Codex.{AppServer, DynamicTool}
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitManager
  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.PullRequestManager
  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RuleCatalog
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.TurnResult
  alias SymphonyElixir.VerifierRunner

  @blocked_state "Blocked"
  @in_progress_state "In Progress"
  @merging_state "Merging"
  @human_review_state "Human Review"
  @done_state "Done"
  @rework_state "Rework"
  @report_turn_result_tool "report_agent_turn_result"
  @turn_result_key_prefix :symphony_turn_result
  @turn_runtime_error_key_prefix :symphony_turn_runtime_error
  @await_checks_missing_limit 6
  @codex_turn_error_methods ["codex/event/stream_error", "codex/event/error", "error"]

  @spec run(Path.t(), Issue.t(), pid() | nil, keyword()) ::
          :ok | {:done, Issue.t()} | {:stop, term()} | {:error, term()}
  def run(workspace, %Issue{} = issue, codex_update_recipient, opts \\ []) when is_binary(workspace) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, app_session} <- AppServer.start_session(workspace) do
      try do
        do_run(app_session, workspace, issue, codex_update_recipient, issue_state_fetcher, max_turns, opts)
      after
        AppServer.stop_session(app_session)
      end
    end
  end

  @doc false
  def fetch_turn_result_for_test(issue), do: fetch_turn_result(issue)

  @doc false
  def execute_tool_for_test(issue, tool, arguments, opts \\ []) do
    tool_executor(issue, opts).(tool, arguments)
  end

  @doc false
  def implementation_turn_error_summary_for_test(reason), do: implementation_turn_error_summary(reason)

  @doc false
  def retryable_implementation_error_for_test(reason), do: retryable_implementation_error?(reason)

  @doc false
  def maybe_move_issue_for_test(issue, target_state), do: maybe_move_issue(issue, target_state)

  @doc false
  def codex_message_handler_for_test(recipient, issue), do: codex_message_handler(recipient, issue)

  @doc false
  def normalize_state_for_test(state), do: normalize_state(state)

  @doc false
  def active_issue_state_for_test(state_name), do: active_issue_state?(state_name)

  @doc false
  def branch_has_publishable_changes_for_test(workspace, state, opts \\ []) do
    branch_has_publishable_changes?(workspace, state, opts)
  end

  @doc false
  def normalize_pr_state_for_test(pr_state), do: normalize_pr_state(pr_state)

  @doc false
  def maybe_sync_policy_override_for_test(state, workspace, opts) do
    maybe_sync_policy_override(state, workspace, opts)
  end

  @doc false
  def detail_summary_for_test(code, detail), do: detail_summary(code, detail)

  @doc false
  def human_review_summary_for_test(code), do: human_review_summary(code)

  @doc false
  def handle_checkout_error_for_test(workspace, issue, reason),
    do: handle_checkout_error(workspace, issue, reason)

  defp do_run(app_session, workspace, issue, codex_update_recipient, issue_state_fetcher, max_turns, opts) do
    state =
      workspace
      |> RunStateStore.load_or_default(issue)
      |> maybe_sync_policy_override(workspace, opts)

    stage = Map.get(state, :stage, "checkout")
    inspection = RunInspector.inspect(workspace, opts)

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

      "done" ->
        {:done, issue}

      "blocked" ->
        {:stop, :blocked}

      _ ->
        {:error, {:unknown_stage, stage}}
    end
  end

  defp handle_checkout(app_session, workspace, issue, recipient, fetcher, max_turns, state, inspection, opts) do
    with {:ok, branch_info} <- GitManager.prepare_issue_branch(workspace, issue, inspection.harness, opts),
         {:ok, harness} <- RepoHarness.load(workspace),
         {:ok, policy_resolution} <- resolve_policy(issue, state, workspace),
         {:ok, _state} <-
           RunStateStore.transition(workspace, "implement", %{
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

  defp handle_implement(app_session, workspace, issue, recipient, fetcher, max_turns, state, _inspection, opts) do
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
      prompt = implement_prompt(issue, state, opts, implementation_turns + 1, max_turns)
      before_snapshot = RunInspector.inspect(workspace, opts)
      clear_turn_result(issue)
      clear_turn_runtime_errors(issue)

      try do
        with {:ok, _turn_session} <-
               AppServer.run_turn(
                 app_session,
                 prompt,
                 issue,
                 on_message: codex_message_handler(recipient, issue),
                 tool_executor: tool_executor(issue, opts)
               ),
             {:ok, turn_result} <- fetch_turn_result(issue),
             after_snapshot <- RunInspector.inspect(workspace, opts),
             {:ok, refreshed_issue} <- refresh_issue(issue, fetcher),
             :ok <- ensure_issue_still_active(refreshed_issue),
             :ok <- ensure_turn_progress(turn_result, before_snapshot, after_snapshot),
             {:ok, _state} <-
               RunStateStore.transition(workspace, "validate", %{
                 implementation_turns: implementation_turns + 1,
                 last_turn_result: TurnResult.to_map(turn_result),
                 branch: after_snapshot.branch || Map.get(state, :branch),
                 pr_url: after_snapshot.pr_url || Map.get(state, :pr_url)
               }) do
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
            block_issue(workspace, issue, :noop_turn, "The turn produced no code change and no PR.", @blocked_state)

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
                  :turn_failed,
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

  defp handle_validate(app_session, workspace, issue, recipient, fetcher, max_turns, state, inspection, opts) do
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
          RunStateStore.transition(workspace, "verify", %{
            validation_attempts: validation_attempts,
            last_validation: command_result_to_map(result)
          })

        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

      :failed ->
        if Config.policy_retry_validation_failures_within_run?() and
             validation_attempts < Config.policy_max_validation_attempts_per_run() and
             Map.get(state, :implementation_turns, 0) < max_turns do
          {:ok, _state} =
            RunStateStore.transition(workspace, "implement", %{
              validation_attempts: validation_attempts,
              last_validation: command_result_to_map(result)
            })

          do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
        else
          block_issue(workspace, issue, :validation_failed, result.output, @blocked_state)
        end

      :unavailable ->
        block_issue(workspace, issue, :validation_unavailable, result.output, @blocked_state)
    end
  end

  defp handle_verify(app_session, workspace, issue, recipient, fetcher, max_turns, state, inspection, opts) do
    if Config.policy_require_verifier?() do
      verifier_runner = Keyword.get(opts, :verifier_runner, &VerifierRunner.verify/5)
      result = verifier_runner.(workspace, issue, state, inspection, opts)
      verification_attempts = Map.get(state, :verification_attempts, 0) + 1
      verifier_summary = Map.get(result, :summary) || Map.get(result, "summary") || inspect(result)

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
          {:ok, _state} =
            RunStateStore.transition(workspace, "publish", %{
              verification_attempts: verification_attempts,
              last_verifier: verifier_result_to_map(result),
              last_verifier_verdict: "pass",
              acceptance_summary: get_in(result, [:acceptance, :summary]) || get_in(result, ["acceptance", "summary"])
            })

          do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

        "needs_more_work" ->
          if Config.policy_retry_validation_failures_within_run?() and
               verification_attempts < Config.policy_max_validation_attempts_per_run() and
               Map.get(state, :implementation_turns, 0) < max_turns do
            {:ok, _state} =
              RunStateStore.transition(workspace, "implement", %{
                verification_attempts: verification_attempts,
                last_verifier: verifier_result_to_map(result),
                last_verifier_verdict: "needs_more_work",
                acceptance_summary: get_in(result, [:acceptance, :summary]) || get_in(result, ["acceptance", "summary"])
              })

            do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
          else
            block_issue(
              workspace,
              issue,
              :verifier_failed,
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

  defp handle_publish(app_session, workspace, issue, recipient, fetcher, max_turns, state, inspection, opts) do
    if Config.policy_publish_required?() do
      case GitManager.commit_all(
             workspace,
             issue,
             get_in(state, [:last_turn_result, :summary]) || issue.title || "Automated update",
             opts
           ) do
        {:ok, :noop} ->
          if is_nil(inspection.pr_url) and not branch_has_publishable_changes?(workspace, state, opts) do
            block_issue(workspace, issue, :noop_turn, "No commit and no PR were produced for publish.", @blocked_state)
          else
            publish_after_commit(app_session, workspace, issue, recipient, fetcher, max_turns, state, opts)
          end

        {:ok, %{sha: sha}} ->
          with branch when is_binary(branch) <- Map.get(state, :branch) || inspection.branch,
               :ok <- GitManager.push_branch(workspace, branch, opts),
               {:ok, _state} <- RunStateStore.update(workspace, &Map.put(&1, :last_commit_sha, sha)) do
            publish_after_commit(app_session, workspace, issue, recipient, fetcher, max_turns, state, opts)
          else
            {:error, reason} ->
              block_issue(workspace, issue, :publish_failed, inspect(reason), @blocked_state)

            _ ->
              block_issue(workspace, issue, :publish_failed, "Unable to determine branch for publish.", @blocked_state)
          end

        {:error, reason} ->
          block_issue(workspace, issue, :publish_failed, inspect(reason), @blocked_state)
      end
    else
      {:ok, _state} = RunStateStore.transition(workspace, "await_checks", %{})
      do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)
    end
  end

  defp publish_after_commit(app_session, workspace, issue, recipient, fetcher, max_turns, state, opts) do
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

  defp handle_await_checks(app_session, workspace, issue, recipient, fetcher, max_turns, state, inspection, opts) do
    await_checks_polls = Map.get(state, :await_checks_polls, 0) + 1
    check_rollup = RunInspector.required_checks_rollup(inspection)
    await_checks_attrs = await_checks_state_attrs(inspection, check_rollup, await_checks_polls)
    policy_resolution = resolve_policy(issue, state, workspace)

    RunLedger.record("checks.polled", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      stage: "await_checks",
      actor_type: "runtime",
      actor_id: "delivery_engine",
      policy_class: Map.get(state, :effective_policy_class),
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
        block_issue(workspace, issue, policy_reason.code, Enum.join(policy_reason.labels, ", "), @blocked_state)

      is_nil(inspection.pr_url) ->
        block_issue(workspace, issue, :publish_missing_pr, "No PR is attached for the current branch.", @blocked_state)

      merged_pull_request?(inspection) ->
        {:ok, _state} =
          RunStateStore.transition(workspace, "post_merge", Map.merge(await_checks_attrs, %{last_merge: %{status: :already_merged, url: inspection.pr_url}}))

        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

      closed_pull_request?(inspection) ->
        block_issue(workspace, issue, :pr_closed, "The PR closed before Symphony could merge it.", @blocked_state)

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

      check_rollup.state == :missing and await_checks_polls >= @await_checks_missing_limit ->
        block_issue(
          workspace,
          issue,
          :required_checks_missing,
          "Required checks never appeared on the PR: #{Enum.join(check_rollup.missing, ", ")}",
          @blocked_state
        )

      RunInspector.ready_for_merge?(inspection) and Config.policy_automerge_on_green?() and
        Map.get(state, :automerge_disabled, false) == false and
          match?({:ok, %{class: :fully_autonomous}}, policy_resolution) ->
        {:ok, _state} =
          RunStateStore.transition(workspace, "merge", await_checks_attrs)

        do_run(app_session, workspace, issue, recipient, fetcher, max_turns, opts)

      RunInspector.ready_for_merge?(inspection) and
          match?({:ok, %{class: :review_required}}, policy_resolution) ->
        hold_for_policy_review(workspace, issue, state, await_checks_attrs, :policy_review_required)

      RunInspector.ready_for_merge?(inspection) and
          match?({:ok, %{class: :never_automerge}}, policy_resolution) ->
        hold_for_policy_review(workspace, issue, state, await_checks_attrs, :policy_never_automerge)

      RunInspector.ready_for_merge?(inspection) ->
        hold_for_policy_review(workspace, issue, state, await_checks_attrs, :policy_review_required)

      true ->
        {:ok, _state} = RunStateStore.transition(workspace, "await_checks", await_checks_attrs)

        :ok
    end
  end

  @dialyzer {:nowarn_function, handle_merge: 9}
  defp handle_merge(app_session, workspace, issue, recipient, fetcher, max_turns, state, inspection, opts) do
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
        block_issue(workspace, issue, :pr_closed, "The PR closed before Symphony could merge it.", @blocked_state)

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
          RunStateStore.transition(workspace, "await_checks", await_checks_state_attrs(inspection, RunInspector.required_checks_rollup(inspection), Map.get(state, :await_checks_polls, 0)))

        :ok
    end
  end

  defp handle_post_merge(workspace, issue, _state, inspection, opts) do
    with :ok <- GitManager.reset_to_base(workspace, inspection.harness, opts),
         :ok <- maybe_post_merge_verify(workspace, issue, inspection.harness, opts),
         :ok <- maybe_move_issue(issue, @done_state),
         {:ok, _state} <- RunStateStore.transition(workspace, "done", %{}) do
      {:done, issue}
    else
      {:error, {:post_merge_rework, reason}} ->
        block_issue(workspace, issue, :post_merge_failed, inspect(reason), @rework_state)

      {:error, reason} ->
        block_issue(workspace, issue, :post_merge_failed, inspect(reason), @blocked_state)
    end
  end

  defp maybe_post_merge_verify(workspace, _issue, harness, opts) do
    if Config.policy_post_merge_verification_required?() do
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
            issue_id: nil,
            issue_identifier: nil,
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

  defp implement_prompt(issue, state, opts, turn_number, max_turns) do
    base = PromptBuilder.build_prompt(issue, opts)

    feedback =
      []
      |> maybe_add_feedback("Previous validation output", get_in(state, [:last_validation, :output]))
      |> maybe_add_feedback("Previous verifier output", get_in(state, [:last_verifier, :output]))
      |> Enum.join("\n\n")

    """
    #{base}

    Runtime-owned delivery instructions:

    - Symphony owns git branch creation, commit, push, PR publication, CI waiting, merge, and post-merge closure.
    - Your job is limited to code changes in the checked out repo and reporting the structured turn result.
    - Do not create commits, push branches, open PRs, merge PRs, or change Linear states yourself.
    - Current implementation turn: #{turn_number} of #{max_turns}.
    - At the end of the turn, call the `#{@report_turn_result_tool}` tool exactly once.
    - `files_touched` must list every path you changed this turn.
    - Set `blocked=true` only for a true blocker you cannot resolve from the repo or local environment.
    - If you can continue in a later turn after local verification feedback, set `needs_another_turn=true`.

    #{feedback}
    """
    |> String.trim()
  end

  defp maybe_add_feedback(acc, _label, nil), do: acc

  defp maybe_add_feedback(acc, label, value) do
    [acc, "#{label}:\n#{String.slice(to_string(value), 0, 2_000)}"]
    |> List.flatten()
  end

  defp ensure_turn_progress(%TurnResult{blocked: true} = turn_result, _before_snapshot, _after_snapshot) do
    {:error, {:agent_blocked, turn_result}}
  end

  defp ensure_turn_progress(_turn_result, before_snapshot, after_snapshot) do
    if RunInspector.code_changed?(before_snapshot, after_snapshot) or is_binary(after_snapshot.pr_url) do
      :ok
    else
      if Config.policy_stop_on_noop_turn?() do
        {:error, {:noop_turn, "No code change and no PR"}}
      else
        :ok
      end
    end
  end

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
              %{"success" => true, "contentItems" => [%{"type" => "inputText", "text" => "turn result recorded"}]}

            {:error, reason} ->
              Process.put(turn_result_key(issue), {:error, reason})
              %{"success" => false, "contentItems" => [%{"type" => "inputText", "text" => inspect(reason)}]}
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

  defp turn_runtime_error_key(%Issue{id: issue_id}), do: {@turn_runtime_error_key_prefix, issue_id}

  defp maybe_move_issue(%Issue{id: issue_id, state: current_state}, target_state)
       when is_binary(issue_id) and is_binary(target_state) do
    if normalize_state(current_state) == normalize_state(target_state) do
      :ok
    else
      Tracker.update_issue_state(issue_id, target_state)
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
        block_issue(workspace, refreshed_issue, :turn_failed, summary, @blocked_state)
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

  defp implementation_turn_error_summary({:turn_failed, details}),
    do: "Codex turn failed: #{safe_detail_text(details)}"

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

  defp implementation_error_to_map(reason), do: %{type: "unknown", details: safe_detail_text(reason)}

  defp retryable_implementation_error?({:turn_failed, _details}), do: true
  defp retryable_implementation_error?({:port_exit, _status}), do: true
  defp retryable_implementation_error?(:turn_timeout), do: true
  defp retryable_implementation_error?(_reason), do: false

  defp non_retryable_implementation_error?({:turn_cancelled, _details}), do: true
  defp non_retryable_implementation_error?({:approval_required, _details}), do: true
  defp non_retryable_implementation_error?({:turn_input_required, _details}), do: true
  defp non_retryable_implementation_error?(_reason), do: false

  defp handle_checkout_error(workspace, issue, {:error, reason})
       when reason in [:missing_harness_version, :missing_required_checks] do
    block_issue(workspace, issue, reason, "The repo harness contract is incomplete.", @blocked_state)
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
    block_issue(workspace, issue, :invalid_harness, inspect(:invalid_harness_root), @blocked_state)
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
      Tracker.create_comment(
        issue_id,
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

      Tracker.update_issue_state(issue_id, target_state)
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
      raw_output: Map.get(result, :raw_output) || Map.get(result, "raw_output"),
      smoke: Map.get(result, :smoke) || Map.get(result, "smoke"),
      acceptance: Map.get(result, :acceptance) || Map.get(result, "acceptance")
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

  defp maybe_capture_turn_runtime_error(issue, %{event: :notification, payload: %{"method" => method} = payload})
       when method in @codex_turn_error_methods do
    record_turn_runtime_error(issue, {:codex_notification_error, method, Map.get(payload, "params", %{})})
  end

  defp maybe_capture_turn_runtime_error(_issue, _message), do: :ok

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp branch_has_publishable_changes?(workspace, state, opts) do
    base_branch = Map.get(state, :base_branch, "main")
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case command_runner.("git", ["rev-list", "--count", "origin/#{base_branch}..HEAD"], cd: workspace, stderr_to_stdout: true) do
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
    case IssuePolicy.resolve(issue,
           override: Map.get(state, :policy_override),
           default: Config.policy_default_issue_class()
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

    :ok = maybe_move_issue(issue, @human_review_state)

    :ok =
      Tracker.create_comment(
        issue.id,
        """
        ## Symphony policy hold

        Issue: #{issue.identifier}
        Rule ID: #{rule.rule_id}
        Failure class: #{rule.failure_class}

        #{human_review_summary(code)}

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
        summary: human_review_summary(code),
        details: rule.human_action,
        target_state: @human_review_state
      })

    {:ok, _state} =
      RunStateStore.transition(
        workspace,
        "await_checks",
        Map.merge(await_checks_attrs, %{
          last_decision: %{
            rule_id: rule.rule_id,
            failure_class: rule.failure_class,
            summary: human_review_summary(code),
            details: rule.human_action,
            human_action: rule.human_action,
            target_state: @human_review_state,
            ledger_event_id: Map.get(ledger_event, :event_id)
          },
          last_rule_id: rule.rule_id,
          last_failure_class: rule.failure_class,
          last_decision_summary: human_review_summary(code),
          next_human_action: rule.human_action
        })
      )

    :ok
  end

  defp detail_summary(:publish_missing_pr, _detail), do: "No PR is attached for the current branch."
  defp detail_summary(:policy_invalid_labels, _detail), do: "The issue has conflicting policy labels."
  defp detail_summary(code, detail), do: "#{code}: #{String.slice(detail, 0, 160)}"

  defp human_review_summary(:policy_review_required), do: "Policy requires human review before merge."
  defp human_review_summary(:policy_never_automerge), do: "Policy forbids automerge for this issue."
  defp human_review_summary(_code), do: "Waiting in Human Review."
end
