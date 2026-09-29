defmodule SymphonyElixir.RetryBudgetTotalsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.RunStateStore

  setup do
    root = Path.join(System.tmp_dir!(), "retry-budget-totals-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      policy_token_budget: %{
        per_turn_input: 150_000,
        per_issue_total: 200_000,
        per_issue_total_output: 10_000,
        stages: %{implement: %{per_turn_input_soft: 110_000, per_turn_input_hard: 120_000}},
        broad_implement: %{enabled: true, auto_retry_limit: 2}
      }
    )

    issue = %Issue{id: "retry-totals", identifier: "RETRY-TOTALS", title: "Budget recovery", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)

    assert {:ok, _} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               resume_context: %{target_paths: ["lib/example.ex"]}
             })

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, issue: issue, workspace: workspace}
  end

  test "a fresh worker resumes accumulated totals and duplicate provider reports are idempotent", context do
    first = spawn_worker(context.issue)
    assert first.running[context.issue.id].issue_token_usage_base == %{}
    first = report_usage(first, context.issue.id, 100_000, 1_000)
    assert {:ok, %{token_usage: %{total_tokens: 101_000}}} = RunStateStore.load(context.workspace)

    duplicate = report_usage(first, context.issue.id, 100_000, 1_000)
    assert duplicate.running[context.issue.id].agent_total_tokens == 101_000
    assert {:ok, %{token_usage: %{total_tokens: 101_000}}} = RunStateStore.load(context.workspace)
    Orchestrator.terminate_running_issue(duplicate, context.issue.id, false)

    # The next worker gets no prior in-memory state, as on retry after a runtime restart.
    second = spawn_worker(context.issue, 2)
    assert second.running[context.issue.id].agent_total_tokens == 0
    assert second.running[context.issue.id].issue_token_usage_base.total_tokens == 101_000
    stopped = report_usage(second, context.issue.id, 100_000, 1_000)
    refute Map.has_key?(stopped.running, context.issue.id)
    refute Map.has_key?(stopped.retry_attempts, context.issue.id)

    assert {:ok, %{token_usage: %{total_tokens: 202_000}, stop_reason: %{rule_id: "budget.per_issue_total_exceeded"}}} =
             RunStateStore.load(context.workspace)
  end

  test "issue totals cannot be reset by a stale stage snapshot or a duplicate checkpoint", context do
    assert {:ok, old_snapshot} = RunStateStore.load(context.workspace)
    usage = %{input_tokens: 90_000, output_tokens: 1_000, total_tokens: 91_000}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
    assert :ok = RunStateStore.save(context.workspace, Map.put(old_snapshot, :stage, "validate"))
    assert {:ok, %{stage: "validate", token_usage: ^usage}} = RunStateStore.load(context.workspace)
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
    assert {:ok, %{token_usage: ^usage}} = RunStateStore.load(context.workspace)
  end

  test "another issue identity in the same workspace starts with zero prior usage", context do
    usage = %{input_tokens: 90_000, output_tokens: 1_000, total_tokens: 91_000}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
    replacement = %{context.issue | id: "replacement-issue"}
    refute Map.has_key?(RunStateStore.load_or_default(context.workspace, replacement), :token_usage)
    fresh_usage = %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, replacement, fresh_usage)
    assert {:ok, %{issue_id: "replacement-issue", token_usage: ^fresh_usage}} = RunStateStore.load(context.workspace)
  end

  test "broad narrowing cannot bypass totals spent by a previous worker", context do
    entry = %{
      workspace_path: context.workspace,
      dispatch_stage: "implement",
      last_agent_message: "The target is lib/example.ex.",
      agent_input_tokens: 130_000,
      agent_output_tokens: 0,
      agent_total_tokens: 130_000,
      issue_token_usage_base: %{total_tokens: 100_000}
    }

    assert {:stop, %RunPolicy.Violation{code: :per_issue_total_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, entry)
  end

  test "output usage is cumulative while the per-turn input allowance remains local to the worker", context do
    entry = %{
      workspace_path: context.workspace,
      dispatch_stage: "implement",
      agent_input_tokens: 10,
      agent_output_tokens: 600,
      agent_total_tokens: 610,
      issue_token_usage_base: %{input_tokens: 130_000, output_tokens: 9_500, total_tokens: 139_500}
    }

    assert {:stop, %RunPolicy.Violation{code: :per_issue_output_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, entry)
  end

  test "review-fix total exhaustion takes precedence over a simultaneous turn retry", context do
    entry = review_fix_entry(context.workspace)
    entry = Map.put(entry, :issue_token_usage_base, %{total_tokens: 100_000})

    assert {:stop, %RunPolicy.Violation{code: :per_issue_total_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, entry)

    assert {:ok, %{stage: "blocked", stop_reason: %{rule_id: "budget.per_issue_total_exceeded"}}} =
             RunStateStore.load(context.workspace)
  end

  test "review-fix output exhaustion takes precedence over a simultaneous turn retry", context do
    entry =
      context.workspace
      |> review_fix_entry()
      |> Map.put(:agent_output_tokens, 101)
      |> Map.put(:agent_total_tokens, 130_101)
      |> Map.put(:issue_token_usage_base, %{output_tokens: 9_900, total_tokens: 10_000})

    assert {:stop, %RunPolicy.Violation{code: :per_issue_output_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, entry)
  end

  test "exhausted persisted totals block active and passive dispatch before a worker starts", context do
    if is_nil(Process.whereis(WorkflowStore)), do: start_supervised!(WorkflowStore)
    assert :ok = WorkflowStore.force_reload()
    usage = %{input_tokens: 200_001, output_tokens: 0, total_tokens: 200_001}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)

    dispatch = fn state, _issue, _attempt ->
      send(self(), :unexpected_budget_dispatch)
      state
    end

    for stage <- ["implement", "await_checks"] do
      assert {:ok, _} = RunStateStore.transition(context.workspace, stage)

      assert %State{running: running, candidate_fetch_error: {:token_budget_exhausted, "budget.per_issue_total_exceeded"}} =
               Orchestrator.dispatch_runtime_issue_for_test(%State{max_concurrent_agents: 1}, context.issue, nil,
                 active_dispatch_fun: dispatch,
                 passive_dispatch_fun: dispatch
               )

      assert running == %{}
      refute_received :unexpected_budget_dispatch
      assert {:ok, %{stage: "blocked", token_usage: ^usage}} = RunStateStore.load(context.workspace)
    end
  end

  test "a corrupt snapshot during usage checkpoint stops the worker and blocks another dispatch", context do
    state = spawn_worker(context.issue)
    payload = "{broken-snapshot"
    File.write!(RunStateStore.state_path(context.workspace), payload)
    stopped = report_usage(state, context.issue.id, 10, 1)
    refute Map.has_key?(stopped.running, context.issue.id)
    assert {:run_state_unreadable, _} = stopped.token_usage_errors[context.issue.id]
    assert File.read!(RunStateStore.state_path(context.workspace)) == payload
    refute Map.has_key?(stopped.retry_attempts, context.issue.id)

    dispatch = fn returned, _issue, _attempt ->
      send(self(), :unexpected_worker)
      returned
    end

    assert %State{candidate_fetch_error: {:token_usage_persistence_failed, _}} =
             Orchestrator.dispatch_runtime_issue_for_test(stopped, context.issue, nil,
               active_dispatch_fun: dispatch,
               passive_dispatch_fun: dispatch
             )

    refute_received :unexpected_worker
  end

  test "filesystem errors retain their write API contract", context do
    path = RunStateStore.state_path(context.workspace)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :eisdir} = RunStateStore.save(context.workspace, %{})
    assert {:error, :eisdir} = RunStateStore.transition(context.workspace, "implement")
    assert {:error, :eisdir} = RunStateStore.update(context.workspace, & &1)
    assert {:error, :eisdir} = RunStateStore.sync_lease(context.workspace, context.issue, %{})
    assert {:error, {:run_state_unreadable, :eisdir}} = RunStateStore.ensure_readable(context.workspace)
  end

  defp review_fix_entry(workspace) do
    %{
      workspace_path: workspace,
      stage: "implement",
      turn_count: 1,
      agent_input_tokens: 130_000,
      agent_output_tokens: 0,
      agent_total_tokens: 130_000,
      turn_started_input_tokens: 0,
      resume_context: %{
        budget_mode: "review_fix",
        budget_scope_kind: "review_claim_batch",
        budget_scope_ids: ["comment:1", "comment:2"]
      }
    }
  end

  defp spawn_worker(issue, attempt \\ 1) do
    worker = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    state = %State{
      lease_owner: "budget-totals-owner",
      max_concurrent_agents: 1,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert {:ok, acquired} = SymphonyElixir.LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)

    state = %{
      state
      | lease_claims: %{
          issue.id => %{
            token: acquired.token,
            lease: acquired.lease,
            custody_ref: make_ref(),
            holder: :retry,
            workspace: Workspace.path_for_issue(issue),
            issue: issue,
            started_at_ms: System.monotonic_time(:millisecond),
            deadline: :not_pending,
            promotion_ref: nil,
            timer: nil
          }
        }
    }

    Orchestrator.do_spawn_issue_worker_for_test(state, issue, attempt, self(), start_child_fun: fn _supervisor, _fun -> {:ok, worker} end)
  end

  defp report_usage(state, issue_id, input, output) do
    assert {:noreply, next_state} =
             Orchestrator.handle_info(
               {:agent_worker_update, issue_id,
                %{
                  event: :notification,
                  timestamp: DateTime.utc_now(),
                  payload: %{
                    "method" => "thread/tokenUsage/updated",
                    "params" => %{
                      "tokenUsage" => %{
                        "total" => %{"inputTokens" => input, "outputTokens" => output, "totalTokens" => input + output}
                      }
                    }
                  }
                }},
               state
             )

    next_state
  end
end
