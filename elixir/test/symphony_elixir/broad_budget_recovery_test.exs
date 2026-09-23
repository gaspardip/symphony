defmodule SymphonyElixir.BroadBudgetRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunStateStore

  setup do
    root = Path.join(System.tmp_dir!(), "broad-budget-recovery-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      policy_token_budget: %{
        per_turn_input: 150_000,
        per_issue_total: 500_000,
        per_issue_total_output: 10_000,
        stages: %{implement: %{per_turn_input_soft: 60_000, per_turn_input_hard: 120_000}},
        broad_implement: %{enabled: true, auto_retry_limit: 2}
      }
    )

    issue = %Issue{id: "broad-recovery", identifier: "BROAD-RECOVERY", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue.identifier)
    File.mkdir_p!(workspace)
    assert {:ok, _state} = RunStateStore.transition(workspace, "implement", %{resume_context: %{}})
    on_exit(fn -> File.rm_rf(root) end)

    entry = %{
      workspace_path: workspace,
      dispatch_stage: "implement",
      turn_count: 1,
      agent_input_tokens: 150_000,
      agent_output_tokens: 0,
      agent_total_tokens: 150_000,
      turn_started_input_tokens: 0,
      last_agent_message: "The change belongs in lib/example.ex."
    }

    %{issue: issue, workspace: workspace, entry: entry}
  end

  test "broad retry cannot extend the total issue budget", %{issue: issue, workspace: workspace, entry: entry} do
    File.write!(Path.join(workspace, "pending.ex"), "pending work")

    assert {:stop, %RunPolicy.Violation{code: :per_issue_total_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(issue, %{entry | agent_total_tokens: 500_001})

    assert %{stage: "blocked", stop_reason: %{rule_id: "budget.per_issue_total_exceeded"}} =
             RunStateStore.load_or_default(workspace, issue)
  end

  test "broad retry cannot extend the output budget", %{issue: issue, entry: entry} do
    assert {:stop, %RunPolicy.Violation{code: :per_issue_output_budget_exceeded}} =
             RunPolicy.maybe_stop_for_token_budget(issue, %{entry | agent_output_tokens: 10_001})
  end

  test "redispatch recovers focused paths and retry count without an in-memory resume context", %{
    issue: issue,
    workspace: workspace,
    entry: entry
  } do
    assert {:retry, %{retry_count: 1, resume_context: %{target_paths: ["lib/example.ex"]}}} =
             RunPolicy.maybe_stop_for_token_budget(issue, entry)

    resumed = %{
      entry
      | turn_count: 2,
        last_agent_message: "The one additional file required is lib/example_test.ex."
    }

    assert {:retry, %{kind: :broad_implement_budget_expansion_retry, retry_count: 2}} =
             RunPolicy.maybe_stop_for_token_budget(issue, resumed)

    assert %{resume_context: %{budget_retry_count: 2, budget_expansion_used: true, target_paths: paths}} =
             RunStateStore.load_or_default(workspace, issue)

    assert paths == ["lib/example.ex", "lib/example_test.ex"]

    assert %{mode: "broad_implement", retry_count: 2, target_paths: ^paths} =
             RunPolicy.budget_runtime(issue, resumed)
  end

  test "workflow can disable the broad retry lane", %{issue: issue, workspace: workspace, entry: entry} do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      policy_token_budget: %{
        per_turn_input: 120_000,
        broad_implement: %{enabled: false, auto_retry_limit: 0}
      }
    )

    assert %{enabled: false, auto_retry_limit: 0} = Config.policy_broad_implement_token_budget()

    assert {:stop, %RunPolicy.Violation{code: :per_turn_input_budget_exceeded, metadata: metadata}} =
             RunPolicy.maybe_stop_for_token_budget(issue, entry)

    assert metadata.budget_admission_reason == "broad_implement_disabled"
    assert %{stage: "blocked"} = RunStateStore.load_or_default(workspace, issue)
  end

  test "CI recovery takes precedence over a persisted broad retry", %{issue: issue} do
    for fingerprint <- ["test", "previous-workspace-fingerprint"] do
      prompt =
        SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
          issue,
          %{
            last_failing_required_checks: ["make-all"],
            implementation_turns: 2,
            resume_context: %{
              fingerprint: fingerprint,
              budget_mode: "broad_implement",
              budget_retry_count: 1,
              target_paths: ["lib/example.ex"]
            }
          },
          [],
          3,
          5
        )

      assert prompt =~ "Scoped review-fix lane: active"
      assert prompt =~ "Scope kind: ci_failure_batch"
      assert prompt =~ "Scope ids:\n- make-all"
      refute prompt =~ "Broad implement retry lane: active"
    end
  end
end
