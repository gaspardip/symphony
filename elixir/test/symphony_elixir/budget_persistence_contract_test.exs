defmodule SymphonyElixir.BudgetPersistenceContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunStateStore

  setup do
    root = Path.join(System.tmp_dir!(), "budget-contracts-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      policy_token_budget: %{
        per_turn_input: 150_000,
        per_issue_total: 1_000_000,
        per_issue_total_output: 1_000_000,
        stages: %{
          verify: %{per_turn_input_soft: 110_000, per_turn_input_hard: 120_000},
          implement: %{per_turn_input_soft: 110_000, per_turn_input_hard: 120_000}
        },
        broad_implement: %{enabled: true, auto_retry_limit: 2}
      }
    )

    issue = %Issue{id: "budget-contract", identifier: "BUDGET-CONTRACT", state: "In Progress"}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    on_exit(fn -> File.rm_rf(root) end)
    %{issue: issue, workspace: workspace}
  end

  test "concurrent usage checkpoints and stale stage saves cannot reduce issue totals", context do
    assert {:ok, stale_snapshot} = RunStateStore.load(context.workspace)

    1..16
    |> Task.async_stream(
      fn number ->
        usage = %{input_tokens: number * 1_000, output_tokens: number * 100, total_tokens: number * 1_100}
        assert :ok = RunStateStore.save(context.workspace, Map.put(stale_snapshot, :stage, "implement"))
        assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
        assert :ok = RunStateStore.save(context.workspace, Map.put(stale_snapshot, :stage, "validate"))
      end,
      max_concurrency: 8,
      timeout: 15_000
    )
    |> Enum.each(fn result -> assert {:ok, :ok} = result end)

    assert {:ok, %{issue_id: "budget-contract", token_usage: %{input_tokens: 16_000, output_tokens: 1_600, total_tokens: 17_600}}} =
             RunStateStore.load(context.workspace)

    assert %{"token_usage" => %{"total_tokens" => 17_600}} =
             context.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  end

  test "a leftover default workspace and a non-implement stage cannot admit broad retries", context do
    for {entry, reason} <- [
          {Map.delete(entry(context.workspace), :workspace_path), "missing_workspace"},
          {Map.put(entry(context.workspace), :dispatch_stage, "verify"), "stage_not_implement"}
        ] do
      assert {:ok, _} = RunStateStore.transition(context.workspace, "implement", %{resume_context: %{}})
      assert %{admission_reason: ^reason} = RunPolicy.budget_runtime(context.issue, entry)

      assert {:stop, %RunPolicy.Violation{code: :per_turn_input_budget_exceeded, metadata: metadata}} =
               RunPolicy.maybe_stop_for_token_budget(context.issue, entry)

      assert metadata.budget_admission_reason == reason
      assert {:ok, %{stage: "blocked", resume_context: %{budget_admission_reason: ^reason}}} = RunStateStore.load(context.workspace)
    end
  end

  test "restart preserves explicit expansion and unrelated resume metadata despite noisy new updates", context do
    resume_context = %{
      budget_mode: "broad_implement",
      budget_retry_count: 1,
      budget_expansion_used: false,
      target_paths: ["lib/primary.ex"],
      next_required_path: "lib/required.ex",
      operator_note: "Keep the accepted implementation contract.",
      fingerprint: "saved-workspace"
    }

    assert {:ok, _} = RunStateStore.transition(context.workspace, "implement", %{resume_context: resume_context})
    decoded = context.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
    assert decoded["resume_context"]["operator_note"] == resume_context.operator_note

    running_entry = Map.put(entry(context.workspace), :last_agent_message, "An unrelated update mentions lib/noisy.ex.")
    refute Map.has_key?(running_entry, :resume_context)

    assert {:retry, %{kind: :broad_implement_budget_expansion_retry, retry_count: 2, resume_context: recovered}} =
             RunPolicy.maybe_stop_for_token_budget(context.issue, running_entry)

    assert recovered.target_paths == ["lib/primary.ex", "lib/required.ex"]
    assert recovered.operator_note == resume_context.operator_note
    assert recovered.fingerprint == "saved-workspace"
    assert recovered.budget_expansion_used
    assert {:ok, %{resume_context: ^recovered}} = RunStateStore.load(context.workspace)

    assert %{retry_count: 2, expansion_used: true, target_paths: ["lib/primary.ex", "lib/required.ex"]} =
             RunPolicy.budget_runtime(context.issue, running_entry)
  end

  test "the issue's explicit target takes priority over unrelated agent output", context do
    issue = %{context.issue | description: "Implement the change in `lib/from_issue.ex`."}
    running_entry = Map.put(entry(context.workspace), :last_agent_message, "The diagnostic mentioned lib/unrelated.ex.")

    assert {:retry, %{retry_count: 1, resume_context: recovered}} =
             RunPolicy.maybe_stop_for_token_budget(issue, running_entry)

    assert recovered.target_paths == ["lib/from_issue.ex"]
    refute "lib/unrelated.ex" in recovered.target_paths
    assert {:ok, %{resume_context: %{target_paths: ["lib/from_issue.ex"]}}} = RunStateStore.load(context.workspace)
  end

  defp entry(workspace) do
    %{
      workspace_path: workspace,
      dispatch_stage: "implement",
      turn_count: 1,
      agent_input_tokens: 130_000,
      agent_output_tokens: 0,
      agent_total_tokens: 130_000,
      turn_started_input_tokens: 0,
      last_agent_message: "The target is lib/example.ex."
    }
  end
end
