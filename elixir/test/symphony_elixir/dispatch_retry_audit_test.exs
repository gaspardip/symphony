defmodule SymphonyElixir.DispatchRetryAuditTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{DispatchAudit, LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.State

  setup do
    root = Path.join(System.tmp_dir!(), "dispatch-retry-audit-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner-install"),
      max_concurrent_agents: 1,
      codex_command: "printf invoked > .symphony/provider-invoked; exit 99",
      hook_before_run: "printf seen > .symphony/before-run-seen",
      policy_token_budget: %{
        per_turn_input: 150_000,
        per_issue_total: 500_000,
        per_issue_total_output: 10_000,
        stages: %{implement: %{per_turn_input_soft: 60_000, per_turn_input_hard: 120_000}},
        broad_implement: %{enabled: true, auto_retry_limit: 2}
      }
    )

    issue = %Issue{id: "pending-review-timer", identifier: "PENDING-REVIEW-TIMER", title: "Audited retry fixture", state: "In Progress", source: :tracker, labels: []}
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    gh = Path.join(bin, "gh")
    File.write!(gh, "#!/bin/sh\nprintf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n")
    File.chmod!(gh, 0o700)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    %{
      issue: issue,
      workspace: workspace,
      state: %State{max_concurrent_agents: 1, lease_owner: "retry-owner", agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}}
    }
  end

  test "automatic review retry preserves snapshot and tracker while a dispatch journal is pending", c do
    # Real journal, created while implement is dispatchable; then the old run stops.
    assert {:ok, _ticket} = DispatchAudit.begin(c.workspace, %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, metadata: %{owner: "previous-dispatch-owner", epoch: 1, attempt: 1}})

    claims = %{
      "comment:1" => %{"disposition" => "accepted", "actionable" => false, "implementation_status" => "addressed"},
      "comment:2" => %{"disposition" => "accepted", "actionable" => true}
    }

    assert {:ok, _} =
             RunStateStore.transition(c.workspace, "blocked", %{
               stop_reason: %{code: "per_turn_input_budget_exceeded", rule_id: "budget.per_turn_input_exceeded"},
               last_rule_id: "budget.per_turn_input_exceeded",
               review_claims: claims
             })

    metadata = Orchestrator.continuation_metadata_for_running_entry_for_test(%{identifier: c.issue.identifier})
    assert metadata.delay_type == :continuation
    retry = metadata |> Map.put(:identifier, c.issue.identifier) |> Map.merge(%{attempt: 2, timer_ref: nil, due_at_ms: 0})
    state = %{c.state | retry_attempts: %{c.issue.id => retry}}
    snapshot_path = RunStateStore.state_path(c.workspace)
    marker_path = Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json")
    snapshot_before = File.read!(snapshot_path)
    marker_before = File.read!(marker_path)
    ledger_before = File.read!(RunLedger.ledger_file_path())
    workers_before = MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor))
    assert {:noreply, next} = Orchestrator.handle_info({:retry_issue, c.issue.id}, state)

    try do
      mutations = self() |> Process.info(:messages) |> elem(1) |> Enum.filter(&tracker_mutation?/1)

      observation = %{
        snapshot_before: Jason.decode!(snapshot_before),
        snapshot_after: Jason.decode!(File.read!(snapshot_path)),
        snapshot_unchanged: File.read!(snapshot_path) == snapshot_before,
        marker_unchanged: File.read!(marker_path) == marker_before,
        ledger_unchanged: File.read!(RunLedger.ledger_file_path()) == ledger_before,
        tracker_mutations: Enum.map(mutations, &inspect/1),
        running_count: map_size(next.running),
        retry_count: map_size(next.retry_attempts),
        error: inspect(next.candidate_fetch_error),
        lease: inspect(LeaseManager.read(c.issue.id))
      }

      if root = System.get_env("PB10_RETRY_AUDIT_ROOT"), do: File.write!(Path.join(root, "observation.json"), Jason.encode!(observation, pretty: true))
      assert File.read!(snapshot_path) == snapshot_before
      assert File.read!(marker_path) == marker_before
      assert File.read!(RunLedger.ledger_file_path()) == ledger_before
      assert mutations == []
      assert next.running == %{}
      assert next.retry_attempts == %{}
      assert next.candidate_fetch_error == {:dispatch_audit_failed, c.issue.id, {:dispatch_audit_pending, Path.expand(c.workspace)}}
      assert MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor)) == workers_before
      assert {:error, :missing} = LeaseManager.read(c.issue.id)
      refute File.exists?(Path.join(c.workspace, ".symphony/before-run-seen"))
      refute File.exists?(Path.join(c.workspace, ".symphony/provider-invoked"))
    after
      # Stop only children created by this invocation, even on the red baseline.
      Enum.each(next.retry_attempts, fn {_id, retry} ->
        if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref)
      end)

      Task.Supervisor.children(SymphonyElixir.TaskSupervisor)
      |> Enum.reject(&MapSet.member?(workers_before, &1))
      |> Enum.each(fn pid ->
        result = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
        assert result in [:ok, {:error, :not_found}]
      end)
    end
  end

  defp tracker_mutation?({:memory_tracker_state_update, _, _}), do: true
  defp tracker_mutation?({:memory_tracker_comment, _, _}), do: true
  defp tracker_mutation?({:memory_tracker_attach_link, _, _, _}), do: true
  defp tracker_mutation?(_), do: false
end
