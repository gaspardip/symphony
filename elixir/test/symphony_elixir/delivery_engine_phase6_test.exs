defmodule SymphonyElixir.DeliveryEnginePhase6Test.FakeGitHubClient do
  @behaviour SymphonyElixir.GitHubClient

  @impl true
  def existing_pull_request(_workspace, _opts), do: {:error, :missing_pr}

  @impl true
  def edit_pull_request(_workspace, _title, _body_file, _opts), do: {:error, :missing_pr}

  @impl true
  def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, _opts), do: {:error, :missing_pr}

  @impl true
  def merge_pull_request(_workspace, opts) do
    url = Keyword.get(opts, :merge_url, "https://github.com/example/repo/pull/15")
    {:ok, %{merged: true, url: url, output: "merged", status: :merged}}
  end

  @impl true
  def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}

  @impl true
  def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok
end

defmodule SymphonyElixir.DeliveryEnginePhase6Test.FakeMergeFailureGitHubClient do
  @behaviour SymphonyElixir.GitHubClient

  @impl true
  def existing_pull_request(_workspace, _opts), do: {:error, :missing_pr}

  @impl true
  def edit_pull_request(_workspace, _title, _body_file, _opts), do: {:error, :missing_pr}

  @impl true
  def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, _opts), do: {:error, :missing_pr}

  @impl true
  def merge_pull_request(_workspace, _opts), do: {:error, :merge_failed}

  @impl true
  def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}

  @impl true
  def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok
end

defmodule SymphonyElixir.DeliveryEnginePhase6Test do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeliveryEngine
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.Workflow

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  test "done stage returns done immediately" do
    {workspace, issue} = stage_workspace!("done")
    issue_id = issue.id

    RunStateStore.transition(workspace, "done", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("done")
    )

    assert {:done, %Issue{id: ^issue_id}} = DeliveryEngine.run(workspace, issue, nil)
  end

  test "checkout blocks when the harness is missing its version" do
    {workspace, issue} = git_stage_workspace!("checkout-missing-version")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    base_branch: main
    preflight:
      command:
        - ./scripts/preflight.sh
    validation:
      command:
        - ./scripts/validate.sh
    smoke:
      command:
        - ./scripts/smoke.sh
    post_merge:
      command:
        - ./scripts/post-merge.sh
    artifacts:
      command:
        - ./scripts/artifacts.sh
    pull_request:
      required_checks:
        - make-all
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("checkout-missing-version")
    )

    assert result =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &checkout_command_runner/3)

    assert result in [{:stop, :missing_harness_version}, {:stop, :blocked}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "missing_harness_version"
  end

  test "checkout blocks when the harness is missing required checks" do
    {workspace, issue} = git_stage_workspace!("checkout-missing-required-checks")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command:
        - ./scripts/preflight.sh
    validation:
      command:
        - ./scripts/validate.sh
    smoke:
      command:
        - ./scripts/smoke.sh
    post_merge:
      command:
        - ./scripts/post-merge.sh
    artifacts:
      command:
        - ./scripts/artifacts.sh
    pull_request:
      template: .github/pull_request_template.md
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("checkout-missing-required-checks")
    )

    assert result =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &checkout_command_runner/3)

    assert result in [{:stop, :missing_required_checks}, {:stop, :blocked}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "missing_required_checks"
  end

  test "checkout blocks when the harness is missing a required command" do
    {workspace, issue} = git_stage_workspace!("checkout-missing-command")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command:
        - ./scripts/preflight.sh
    validation:
      command:
        - ./scripts/validate.sh
    post_merge:
      command:
        - ./scripts/post-merge.sh
    artifacts:
      command:
        - ./scripts/artifacts.sh
    pull_request:
      required_checks:
        - make-all
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("checkout-missing-command")
    )

    assert result =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &checkout_command_runner/3)

    assert result in [{:stop, :missing_harness_command}, {:stop, :blocked}]
    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "missing_harness_command"
  end

  test "checkout blocks invalid harness keys" do
    {workspace, issue} = git_stage_workspace!("checkout-unknown-keys")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command:
        - ./scripts/preflight.sh
    validation:
      command:
        - ./scripts/validate.sh
    smoke:
      command:
        - ./scripts/smoke.sh
    post_merge:
      command:
        - ./scripts/post-merge.sh
    artifacts:
      command:
        - ./scripts/artifacts.sh
    pull_request:
      required_checks:
        - make-all
    mystery:
      enabled: true
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("checkout-unknown-keys")
    )

    assert result =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &checkout_command_runner/3)

    assert result in [{:stop, :invalid_harness}, {:stop, :blocked}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "invalid_harness"
  end

  test "checkout blocks when the harness root is not a map" do
    {workspace, issue} = git_stage_workspace!("checkout-invalid-root")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    - ./scripts/preflight.sh
    - ./scripts/validate.sh
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("checkout-invalid-root")
    )

    assert result =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &checkout_command_runner/3)

    assert result in [{:stop, :invalid_harness}, {:stop, :blocked}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "invalid_harness"
  end

  test "checkout blocks when the harness file is missing after branch prep" do
    {workspace, issue} = git_stage_workspace!("checkout-missing-harness")
    File.rm!(Path.join(workspace, ".symphony/harness.yml"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("checkout-missing-harness")
    )

    assert DeliveryEngine.run(workspace, issue, nil, command_runner: &checkout_command_runner/3) in [{:stop, :missing_harness}, {:stop, :blocked}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "missing_harness"
  end

  test "checkout blocks generic git failures" do
    {workspace, issue} = git_stage_workspace!("checkout-git-failed")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("checkout-git-failed")
    )

    assert result =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: fn
                 "git", ["fetch", "origin", "--prune", "main"], _opts -> {"boom", 1}
                 command, args, opts -> checkout_command_runner(command, args, opts)
               end
             )

    assert result in [{:stop, :checkout_failed}, {:stop, :blocked}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "checkout_failed"
  end

  test "blocked stage stops immediately" do
    {workspace, issue} = stage_workspace!("blocked")

    RunStateStore.transition(workspace, "blocked", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("blocked")
    )

    assert {:stop, :blocked} = DeliveryEngine.run(workspace, issue, nil)
  end

  test "implement stage blocks when the implementation turn budget is exhausted" do
    {workspace, issue} = git_stage_workspace!("implement-turn-budget")
    issue_id = issue.id

    RunStateStore.transition(workspace, "implement", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      implementation_turns: 1
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("implement-turn-budget")
    )

    assert {:stop, :turn_budget_exhausted} =
             DeliveryEngine.run(workspace, issue, nil,
               max_turns: 1,
               command_runner: &checkout_command_runner/3
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  test "unknown stage returns an error" do
    {workspace, issue} = stage_workspace!("unknown")

    RunStateStore.transition(workspace, "mystery", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("unknown")
    )

    assert {:error, {:unknown_stage, "mystery"}} = DeliveryEngine.run(workspace, issue, nil)
  end

  test "fetch_turn_result_for_test reports malformed stored values as invalid turn results" do
    {_workspace, issue} = stage_workspace!("malformed-turn-result")
    Process.put({:symphony_turn_result, issue.id}, :malformed)

    on_exit(fn ->
      Process.delete({:symphony_turn_result, issue.id})
    end)

    assert {:error, {:invalid_turn_result, :malformed}} =
             DeliveryEngine.fetch_turn_result_for_test(issue)
  end

  test "execute_tool_for_test falls back to dynamic tool execution for unsupported tools" do
    {_workspace, issue} = stage_workspace!("unsupported-dynamic-tool")

    assert %{
             "success" => false,
             "contentItems" => [%{"text" => text}]
           } =
             DeliveryEngine.execute_tool_for_test(issue, "unsupported_tool", %{})

    assert text =~ "Unsupported dynamic tool"
  end

  test "maybe_move_issue_for_test ignores malformed issues" do
    assert :ok = DeliveryEngine.maybe_move_issue_for_test(%{}, "Done")
  end

  test "codex_message_handler_for_test forwards worker updates to the recipient" do
    {_workspace, issue} = stage_workspace!("codex-handler")
    handler = DeliveryEngine.codex_message_handler_for_test(self(), issue)
    payload = %{event: :notification, payload: %{"summaryText" => "updated"}}
    issue_id = issue.id

    assert :ok = handler.(payload)
    assert_receive {:codex_worker_update, ^issue_id, ^payload}, 100
  end

  test "normalize_state_for_test falls back to an empty string for non-binary values" do
    assert DeliveryEngine.normalize_state_for_test(:todo) == ""
  end

  test "active_issue_state_for_test rejects non-binary states" do
    assert DeliveryEngine.active_issue_state_for_test("Todo")
    refute DeliveryEngine.active_issue_state_for_test(:todo)
  end

  test "branch_has_publishable_changes_for_test returns false when git rev-list output is malformed" do
    {workspace, _issue} = git_stage_workspace!("publishable-parse-failure")

    refute DeliveryEngine.branch_has_publishable_changes_for_test(
             workspace,
             %{base_branch: "main"},
             command_runner: fn
               "git", ["rev-list", "--count", "origin/main..HEAD"], _opts -> {"not-a-number", 0}
             end
           )
  end

  test "branch_has_publishable_changes_for_test uses the default opts and returns true for positive counts" do
    {workspace, _issue} = git_stage_workspace!("publishable-positive-count")

    assert DeliveryEngine.branch_has_publishable_changes_for_test(
             workspace,
             %{base_branch: "main"},
             command_runner: fn
               "git", ["rev-list", "--count", "origin/main..HEAD"], _opts -> {"2", 0}
             end
           )

    refute DeliveryEngine.branch_has_publishable_changes_for_test(workspace, %{base_branch: "main"})
  end

  test "normalize_pr_state_for_test handles nil and uppercases values" do
    assert DeliveryEngine.normalize_pr_state_for_test(nil) == nil
    assert DeliveryEngine.normalize_pr_state_for_test(" merged ") == "MERGED"
  end

  test "maybe_sync_policy_override_for_test keeps state unchanged when override is already persisted" do
    {workspace, issue} = stage_workspace!("policy-override-noop")

    RunStateStore.transition(workspace, "implement", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      policy_override: "review_required"
    })

    state = RunStateStore.load_or_default(workspace, issue)

    assert DeliveryEngine.maybe_sync_policy_override_for_test(
             state,
             workspace,
             policy_override: "review_required"
           ) == state
  end

  test "maybe_sync_policy_override_for_test persists a changed override" do
    {workspace, issue} = stage_workspace!("policy-override-update")

    RunStateStore.transition(workspace, "implement", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    state = RunStateStore.load_or_default(workspace, issue)

    updated_state =
      DeliveryEngine.maybe_sync_policy_override_for_test(
        state,
        workspace,
        policy_override: "never_automerge"
      )

    assert updated_state.policy_override == "never_automerge"
    assert {:ok, persisted_state} = RunStateStore.load(workspace)
    assert persisted_state.policy_override == "never_automerge"
  end

  test "detail_summary_for_test uses the policy-invalid-labels summary" do
    assert DeliveryEngine.detail_summary_for_test(:policy_invalid_labels, "ignored") ==
             "The issue has conflicting policy labels."
  end

  test "detail_summary_for_test covers missing pull requests and risk review summaries" do
    assert DeliveryEngine.detail_summary_for_test(:publish_missing_pr, "ignored") ==
             "No PR is attached for the current branch."

    assert DeliveryEngine.human_review_summary_for_test(:risk_review_required) ==
             "High-risk contractor work requires Human Review before merge."
  end

  test "human_review_summary_for_test falls back to the generic summary" do
    assert DeliveryEngine.human_review_summary_for_test(:other) == "Waiting in Human Review."
  end

  test "handle_checkout_error_for_test treats invalid harness roots as invalid harness errors" do
    {workspace, issue} = git_stage_workspace!("checkout-invalid-root-helper")

    assert {:stop, :invalid_harness} =
             DeliveryEngine.handle_checkout_error_for_test(
               workspace,
               issue,
               {:error, :invalid_harness_root}
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "invalid_harness"
  end

  test "handle_checkout_error_for_test treats unknown harness keys as invalid harness errors" do
    {workspace, issue} = git_stage_workspace!("checkout-unknown-harness-keys-helper")

    assert {:stop, :invalid_harness} =
             DeliveryEngine.handle_checkout_error_for_test(
               workspace,
               issue,
               {:error, {:unknown_harness_keys, ["validation"], ["mystery"]}}
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:stop_reason, :code]) == "invalid_harness"
    assert get_in(state, [:stop_reason, :details]) =~ "Unknown harness keys under validation: mystery"
  end

  test "merge stage falls back to await_checks when PR is not merge-ready" do
    {workspace, issue} = git_stage_workspace!("merge-pending")

    RunStateStore.transition(workspace, "merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/7"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("merge-pending")
    )

    assert :ok =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &pending_merge_command_runner/3)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "await_checks"
    assert state.last_required_checks_state == "pending"
  end

  test "await_checks blocks when required checks fail" do
    {workspace, issue} = git_stage_workspace!("await-failed")
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/10"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-failed")
    )

    assert {:stop, :required_checks_failed} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &failed_checks_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  test "await_checks bypasses codex bootstrap for passive polling" do
    {workspace, issue} = git_stage_workspace!("await-passive-no-codex")

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/30"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: "/definitely/missing/codex"
    )

    assert :ok =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &pending_merge_command_runner/3)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "await_checks"
    assert state.last_required_checks_state == "pending"
  end

  test "await_checks blocks when required checks are cancelled" do
    {workspace, issue} = git_stage_workspace!("await-cancelled")
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/11"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-cancelled")
    )

    assert {:stop, :required_checks_cancelled} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &cancelled_checks_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  test "await_checks blocks after required checks never appear" do
    {workspace, issue} = git_stage_workspace!("await-missing")
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/12",
      await_checks_polls: 5
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-missing")
    )

    assert {:stop, :required_checks_missing} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &missing_checks_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  test "await_checks blocks when the PR closes before merge" do
    {workspace, issue} = git_stage_workspace!("await-closed")
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/13"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-closed")
    )

    assert {:stop, :pr_closed} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &closed_pr_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  test "await_checks blocks when policy labels conflict" do
    {workspace, issue} = git_stage_workspace!("await-policy-conflict")
    issue = %{issue | labels: ["policy:review-required", "policy:never-automerge"]}
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/13"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-policy-conflict")
    )

    assert {:stop, :invalid_labels} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &pending_merge_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.last_rule_id == "runtime.invalid_labels"
  end

  test "await_checks advances to merge for fully autonomous ready PRs" do
    {workspace, issue} = git_stage_workspace!("await-automerge")
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/15"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-automerge"),
      policy_post_merge_verification_required: false,
      policy_automerge_on_green: true
    )

    assert {:done, %Issue{id: ^issue_id}} =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: &ready_merge_command_runner/3,
               github_client: SymphonyElixir.DeliveryEnginePhase6Test.FakeGitHubClient,
               github_client_opts: [merge_url: "https://github.com/example/repo/pull/15"]
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert Enum.any?(state.stage_history, &(&1.stage == "merge"))
    assert get_in(state, [:last_merge, :status]) == "merged"
  end

  test "await_checks defers automerge until the next allowed merge window" do
    {workspace, issue} = git_stage_workspace!("await-merge-window")
    now = DateTime.utc_now()
    window_day = Date.day_of_week(Date.add(DateTime.to_date(now), 1))
    start_hour = 9
    end_hour = 10

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/115",
      effective_policy_class: "fully_autonomous",
      policy_pack: %{
        name: "client_safe",
        default_issue_class: "review_required",
        allowed_policy_classes: ["fully_autonomous", "review_required", "never_automerge"],
        merge_window: %{
          timezone: "Etc/UTC",
          days: [window_day],
          start_hour: start_hour,
          end_hour: end_hour
        }
      }
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-merge-window"),
      policy_post_merge_verification_required: false,
      policy_automerge_on_green: true
    )

    assert :ok =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &ready_merge_command_runner/3)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "await_checks"
    assert state.last_rule_id == "policy.merge_window_wait"
    assert is_map(state.merge_window_wait)
    assert is_binary(Map.get(state.merge_window_wait, :next_allowed_at))
  end

  test "await_checks routes an already merged PR through post_merge to done" do
    {workspace, issue} = git_stage_workspace!("await-merged")
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/14"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-merged"),
      policy_post_merge_verification_required: false
    )

    assert {:done, %Issue{id: ^issue_id}} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &already_merged_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "done"
    assert get_in(state, [:last_merge, :status]) == "already_merged"
  end

  test "merge stage routes an already merged PR through post_merge to done" do
    {workspace, issue} = git_stage_workspace!("merge-complete")
    issue_id = issue.id

    RunStateStore.transition(workspace, "merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/8"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("merge-complete"),
      policy_post_merge_verification_required: false
    )

    assert {:done, %Issue{id: ^issue_id}} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &already_merged_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "done"
    assert get_in(state, [:last_merge, :status]) == "already_merged"
  end

  test "merge and post_merge bypass codex bootstrap for passive completion" do
    {workspace, issue} = git_stage_workspace!("merge-passive-no-codex")
    issue_id = issue.id

    RunStateStore.transition(workspace, "merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/31"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: "/definitely/missing/codex",
      policy_post_merge_verification_required: false
    )

    assert {:done, %Issue{id: ^issue_id}} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &already_merged_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "done"
  end

  test "await_checks holds a ready PR for review when automerge is disabled" do
    {workspace, issue} = git_stage_workspace!("await-review-hold")
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/16"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-review-hold"),
      policy_automerge_on_green: false
    )

    assert :ok =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &ready_merge_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.last_rule_id == "policy.review_required"
  end

  test "await_checks advances a review_required issue after operator approval" do
    {workspace, issue} = git_stage_workspace!("await-review-approved")
    issue_id = issue.id
    approved_issue = %{issue | labels: ["policy:review-required"]}

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: approved_issue.id,
      issue_identifier: approved_issue.identifier,
      pr_url: "https://github.com/example/repo/pull/17",
      review_approved: true
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("await-review-approved"),
      policy_post_merge_verification_required: false,
      policy_automerge_on_green: true
    )

    assert {:done, %Issue{id: ^issue_id}} =
             DeliveryEngine.run(workspace, approved_issue, nil,
               command_runner: &ready_merge_command_runner/3,
               github_client: SymphonyElixir.DeliveryEnginePhase6Test.FakeGitHubClient,
               github_client_opts: [merge_url: "https://github.com/example/repo/pull/17"]
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert Enum.any?(state.stage_history, &(&1.stage == "merge"))
    assert get_in(state, [:last_merge, :status]) == "merged"
  end

  test "post_merge verification failures move the issue to Rework" do
    {workspace, issue} = git_stage_workspace!("post-merge-rework")
    issue_id = issue.id

    RunStateStore.transition(workspace, "post_merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/9"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("post-merge-rework"),
      policy_post_merge_verification_required: true
    )

    assert {:stop, :post_merge_failed} =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: &post_merge_command_runner/3,
               shell_runner: fn _workspace, _command, _opts -> {"post merge failed", 1} end
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Rework"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "post_merge.failed"
    assert state.next_human_action =~ "post-merge verification failure"
  end

  test "post_merge blocks when verification is required but the post-merge command is unavailable" do
    {workspace, issue} = git_stage_workspace!("post-merge-unavailable")
    issue_id = issue.id

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command:
        - ./scripts/preflight.sh
    validation:
      command:
        - ./scripts/validate.sh
    smoke:
      command:
        - ./scripts/smoke.sh
    artifacts:
      command:
        - ./scripts/artifacts.sh
    pull_request:
      required_checks:
        - make-all
    """)

    RunStateStore.transition(workspace, "post_merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/21"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("post-merge-unavailable"),
      policy_post_merge_verification_required: true
    )

    assert {:stop, :post_merge_failed} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &post_merge_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "post_merge.failed"
  end

  test "post_merge verification success records the verification result and completes the issue" do
    {workspace, issue} = git_stage_workspace!("post-merge-verified")
    issue_id = issue.id

    RunStateStore.transition(workspace, "post_merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/19"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("post-merge-verified"),
      policy_post_merge_verification_required: true
    )

    assert {:done, %Issue{id: ^issue_id}} =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: &post_merge_command_runner/3,
               shell_runner: fn _workspace, _command, _opts -> {"all good", 0} end
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "done"
    assert to_string(get_in(state, [:last_post_merge, :status])) == "passed"
  end

  test "post_merge blocks when resetting the workspace to base fails" do
    {workspace, issue} = git_stage_workspace!("post-merge-reset-failed")
    issue_id = issue.id

    RunStateStore.transition(workspace, "post_merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/20"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("post-merge-reset-failed"),
      policy_post_merge_verification_required: false
    )

    assert {:stop, :post_merge_failed} =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: fn
                 "git", ["fetch", "origin", "--prune", "main"], _opts -> {"boom", 1}
                 command, args, opts -> post_merge_command_runner(command, args, opts)
               end
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "post_merge.failed"
  end

  test "merge stage blocks when the PR closes before merge" do
    {workspace, issue} = git_stage_workspace!("merge-closed")
    issue_id = issue.id

    RunStateStore.transition(workspace, "merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/17"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("merge-closed")
    )

    assert {:stop, :pr_closed} =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &closed_pr_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  test "merge stage blocks when PR merge fails" do
    {workspace, issue} = git_stage_workspace!("merge-failed")
    issue_id = issue.id

    RunStateStore.transition(workspace, "merge", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      pr_url: "https://github.com/example/repo/pull/18"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("merge-failed")
    )

    failing_client = SymphonyElixir.DeliveryEnginePhase6Test.FakeMergeFailureGitHubClient

    assert {:stop, :merge_failed} =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: &ready_merge_command_runner/3,
               github_client: failing_client
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  defp stage_workspace!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-delivery-engine-phase6-#{suffix}-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "MT-PHASE6")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command:
        - ./scripts/preflight.sh
    validation:
      command:
        - ./scripts/validate.sh
    smoke:
      command:
        - ./scripts/smoke.sh
    post_merge:
      command:
        - ./scripts/post-merge.sh
    artifacts:
      command:
        - ./scripts/artifacts.sh
    pull_request:
      required_checks:
        - make-all
    """)

    issue = %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-PHASE6",
      title: "Phase 6 stage coverage",
      description: "## Acceptance Criteria\n- cover stage branches",
      state: "In Progress"
    }

    {workspace, issue}
  end

  defp git_stage_workspace!(suffix) do
    {workspace, issue} = stage_workspace!(suffix)
    File.mkdir_p!(Path.join(workspace, ".git"))
    {workspace, issue}
  end

  defp checkout_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp checkout_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"gaspar/mt-phase6\n", 0}

  defp checkout_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"abc123\n", 0}
  defp checkout_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}
  defp checkout_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts), do: {"", 1}
  defp checkout_command_runner("git", ["fetch", "origin", "--prune", "main"], _opts), do: {"", 0}
  defp checkout_command_runner("git", ["checkout", "symphony/mt-phase6"], _opts), do: {"", 1}
  defp checkout_command_runner("git", ["checkout", "-B", "symphony/mt-phase6", "origin/main"], _opts), do: {"", 0}

  defp checkout_command_runner("git", ["config", "branch.symphony/mt-phase6.symphony-base-branch", "main"], _opts),
    do: {"", 0}

  defp pending_merge_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp pending_merge_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"gaspar/mt-phase6\n", 0}

  defp pending_merge_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"abc123\n", 0}
  defp pending_merge_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}

  defp pending_merge_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/7",
      "state" => "OPEN",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => [
        %{"name" => "make-all", "status" => "IN_PROGRESS", "conclusion" => nil}
      ]
    }

    {Jason.encode!(payload), 0}
  end

  defp pending_merge_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp already_merged_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp already_merged_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"gaspar/mt-phase6\n", 0}

  defp already_merged_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"def456\n", 0}
  defp already_merged_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}
  defp already_merged_command_runner("git", ["fetch", "origin", "--prune", "main"], _opts), do: {"", 0}
  defp already_merged_command_runner("git", ["checkout", "-f", "main"], _opts), do: {"", 0}
  defp already_merged_command_runner("git", ["reset", "--hard", "origin/main"], _opts), do: {"", 0}

  defp already_merged_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/8",
      "state" => "MERGED",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => [
        %{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
      ]
    }

    {Jason.encode!(payload), 0}
  end

  defp already_merged_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp post_merge_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp post_merge_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"main\n", 0}

  defp post_merge_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"ghi789\n", 0}
  defp post_merge_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}
  defp post_merge_command_runner("git", ["fetch", "origin", "--prune", "main"], _opts), do: {"", 0}
  defp post_merge_command_runner("git", ["checkout", "-f", "main"], _opts), do: {"", 0}
  defp post_merge_command_runner("git", ["reset", "--hard", "origin/main"], _opts), do: {"", 0}
  defp post_merge_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp failed_checks_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp failed_checks_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"gaspar/mt-phase6\n", 0}

  defp failed_checks_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"jkl012\n", 0}
  defp failed_checks_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}

  defp failed_checks_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/10",
      "state" => "OPEN",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => [
        %{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "FAILURE"}
      ]
    }

    {Jason.encode!(payload), 0}
  end

  defp failed_checks_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp closed_pr_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp closed_pr_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"gaspar/mt-phase6\n", 0}

  defp closed_pr_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"pqr678\n", 0}
  defp closed_pr_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}

  defp closed_pr_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/13",
      "state" => "CLOSED",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => [
        %{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
      ]
    }

    {Jason.encode!(payload), 0}
  end

  defp closed_pr_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp ready_merge_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp ready_merge_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"gaspar/mt-phase6\n", 0}

  defp ready_merge_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"stu901\n", 0}
  defp ready_merge_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}
  defp ready_merge_command_runner("git", ["fetch", "origin", "--prune", "main"], _opts), do: {"", 0}
  defp ready_merge_command_runner("git", ["checkout", "-f", "main"], _opts), do: {"", 0}
  defp ready_merge_command_runner("git", ["reset", "--hard", "origin/main"], _opts), do: {"", 0}

  defp ready_merge_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/15",
      "state" => "OPEN",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => [
        %{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
      ]
    }

    {Jason.encode!(payload), 0}
  end

  defp ready_merge_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp cancelled_checks_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp cancelled_checks_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"gaspar/mt-phase6\n", 0}

  defp cancelled_checks_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"mno345\n", 0}
  defp cancelled_checks_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}

  defp cancelled_checks_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/11",
      "state" => "OPEN",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => [
        %{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "CANCELLED"}
      ]
    }

    {Jason.encode!(payload), 0}
  end

  defp cancelled_checks_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp missing_checks_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp missing_checks_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"gaspar/mt-phase6\n", 0}

  defp missing_checks_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"pqr678\n", 0}
  defp missing_checks_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}

  defp missing_checks_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/12",
      "state" => "OPEN",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => []
    }

    {Jason.encode!(payload), 0}
  end

  defp missing_checks_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp fake_codex_binary!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-phase6-fake-codex-#{suffix}-#{System.unique_integer([:positive])}"
      )

    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(root)

    File.write!(binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-phase6"}}}'
          ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)
    "#{binary} app-server"
  end
end
