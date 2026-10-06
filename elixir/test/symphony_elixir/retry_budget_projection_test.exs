defmodule SymphonyElixir.RetryBudgetProjectionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, LeaseManager, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "retry-projection-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "PROJECTION-1")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      policy_token_budget: %{
        per_turn_input: 500_000,
        per_issue_total: 1_000_000,
        per_issue_total_output: 500_000,
        stages: %{implement: %{per_turn_input_soft: 60_000, per_turn_input_hard: 120_000}},
        broad_implement: %{enabled: true, auto_retry_limit: 2},
        review_fix: %{enabled: false}
      }
    )

    issue = %Issue{id: "projection-#{System.unique_integer([:positive])}", identifier: "PROJECTION-1", state: "In Progress"}
    File.mkdir_p!(Path.dirname(RunStateStore.state_path(workspace)))
    File.write!(RunStateStore.state_path(workspace), Jason.encode!(%{issue_id: issue.id, issue_identifier: issue.identifier, resume_context: %{}}))
    on_exit(fn -> File.rm_rf!(root) end)
    %{workspace: workspace, issue: issue}
  end

  test "checked broad retry projects the explicit issue separately and preserves RAW stage absence", c do
    issue = %{c.issue | description: "Implement `lib/explicit.ex`."}
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "projection-owner")
    assert {:ok, source, view} = RunStateStore.read_admission_source(c.workspace, issue)

    assert {:ok, ticket, admitted} =
             DispatchAudit.begin(
               c.workspace,
               %{issue_id: issue.id, issue_identifier: issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}},
               source
             )

    on_exit(fn -> assert {:ok, :released} = LeaseManager.release_token(acquired.token) end)
    precondition = %{authority: %{ticket: ticket, lease_token: acquired.token}, expected: RunStateStore.material_projection(admitted)}

    running =
      entry(c.workspace)
      |> Map.put(:issue, %{c.issue | description: "Unrelated `lib/embedded.ex`."})
      |> Map.put(:last_agent_message, %{message: %{text: "lib/agent.ex"}, payload: %{callback: fn -> flunk("executed message callback") end}})
      |> Map.put(:agent_execution, %{owner: self(), lease_token: acquired.token, callback: fn -> flunk("executed authority callback") end})

    assert {:ok, {:retry, %{resume_context: resume}}, persisted} =
             RunPolicy.maybe_stop_for_token_budget(issue, running, precondition)

    assert resume.target_paths == ["lib/explicit.ex"]
    assert persisted.resume_context == resume
    assert RunStateStore.material_projection(persisted) == precondition.expected
    refute Map.has_key?(persisted, :stage)
    raw = c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
    assert raw["resume_context"]["target_paths"] == ["lib/explicit.ex"]
    refute Map.has_key?(raw, "stage")
    refute Map.has_key?(raw["resume_context"], "agent_execution")
    assert :ok = DispatchAudit.finish(ticket, :normal)
  end

  test "legacy retry retains preferred empty text and discovers a structured update", c do
    assert {:ok, _} = RunStateStore.transition(c.workspace, "implement", %{issue_id: c.issue.id, issue_identifier: c.issue.identifier})

    running =
      entry(c.workspace)
      |> Map.put(:last_agent_message, %{text: "", other: "lib/hidden.ex"})
      |> Map.put(:recent_agent_updates, [%{payload: %{content: "Work on lib/update.ex."}}])

    assert {:retry, %{resume_context: resume}} = RunPolicy.maybe_stop_for_token_budget(c.issue, running)
    assert resume.target_paths == ["lib/update.ex"]
    assert {:ok, %{resume_context: ^resume}} = RunStateStore.load(c.workspace)
    assert %{mode: "broad_implement", target_paths: ["lib/update.ex"]} = RunPolicy.budget_runtime(c.issue, running)
  end

  test "checked low-input evaluation accepts an explicitly absent embedded issue", c do
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "projection-owner")
    assert {:ok, source, view} = RunStateStore.read_admission_source(c.workspace, c.issue)

    assert {:ok, ticket, admitted} =
             DispatchAudit.begin(
               c.workspace,
               %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}},
               source
             )

    on_exit(fn -> assert {:ok, :released} = LeaseManager.release_token(acquired.token) end)
    precondition = %{authority: %{ticket: ticket, lease_token: acquired.token}, expected: RunStateStore.material_projection(admitted)}
    running = entry(c.workspace) |> Map.put(:issue, nil) |> Map.put(:agent_input_tokens, 10_000)
    assert {:ok, before} = RunStateStore.ensure_current(precondition.authority, precondition.expected)
    assert {:ok, :ok, persisted} = RunPolicy.maybe_stop_for_token_budget(c.issue, running, precondition)
    assert persisted == before
    assert :ok = DispatchAudit.finish(ticket, :normal)
  end

  defp entry(workspace) do
    %{
      workspace_path: workspace,
      stage: "implement",
      dispatch_stage: "implement",
      turn_count: 1,
      agent_input_tokens: 130_000,
      agent_output_tokens: 0,
      agent_total_tokens: 130_000,
      turn_started_input_tokens: 0
    }
  end
end
