defmodule SymphonyElixir.DeliveryEnginePhase3Test.FakeGitHubClient do
  @behaviour SymphonyElixir.GitHubClient

  @impl true
  def existing_pull_request(_workspace, opts) do
    case opts[:existing_pr] do
      nil -> {:error, :missing_pr}
      pr -> {:ok, pr}
    end
  end

  @impl true
  def edit_pull_request(_workspace, _title, _body_file, opts) do
    {:ok, %{url: opts[:pr_url] || "https://github.com/example/repo/pull/77", state: "OPEN"}}
  end

  @impl true
  def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, opts) do
    case opts[:create_error] do
      nil -> {:ok, %{url: opts[:pr_url] || "https://github.com/example/repo/pull/88", state: "OPEN"}}
      reason -> {:error, reason}
    end
  end

  @impl true
  def merge_pull_request(_workspace, _opts), do: raise("merge should not be called in this test")

  @impl true
  def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}

  @impl true
  def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok
end

defmodule SymphonyElixir.DeliveryEnginePhase3Test do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeliveryEngine
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.Workflow

  test "verify stage loops back to implement on needs_more_work" do
    {workspace, issue} = verify_workspace!("verify-needs-more-work")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      max_turns: 0,
      codex_command: fake_codex_binary!("verify-needs-more-work"),
      policy_publish_required: false,
      policy_retry_validation_failures_within_run: true,
      policy_max_validation_attempts_per_run: 2
    )

    result =
      DeliveryEngine.run(workspace, issue, nil,
        max_turns: 1,
        issue_state_fetcher: fn [_issue_id] ->
          {:ok, [issue]}
        end,
        verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
          %{
            verdict: "needs_more_work",
            summary: "Verifier found implementation gaps",
            acceptance_gaps: ["Gap"],
            risky_areas: [],
            evidence: [],
            raw_output: "needs more work",
            acceptance: %{summary: "Verifier summary"}
          }
        end
      )

    assert result in [{:stop, :verifier_failed}, {:stop, :noop_turn}, {:stop, :behavior_proof_missing}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert Enum.any?(state.stage_history, &(&1.stage == "implement"))
    assert state.last_verifier_verdict == "needs_more_work"
  end

  test "verify stage gives one retry for missing behavioral proof" do
    {workspace, issue} = verify_workspace!("verify-behavior-proof-retry")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      max_turns: 0,
      codex_command: fake_codex_binary!("verify-behavior-proof-retry"),
      policy_publish_required: false,
      policy_retry_validation_failures_within_run: true,
      policy_max_validation_attempts_per_run: 3
    )

    result =
      DeliveryEngine.run(workspace, issue, nil,
        max_turns: 1,
        issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
        verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
          %{
            verdict: "needs_more_work",
            reason_code: "behavior_proof_missing",
            summary: "Add or update repo-owned behavioral proof before publish.",
            acceptance_gaps: ["Add tests"],
            risky_areas: [],
            evidence: [],
            raw_output: "missing proof",
            acceptance: %{summary: "Verifier summary"},
            behavioral_proof: %{required: true, satisfied: false, mode: "unit_first"}
          }
        end
      )

    assert result in [{:stop, :verifier_failed}, {:stop, :noop_turn}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert Enum.any?(state.stage_history, &(&1.stage == "implement"))
    assert state.last_verifier_verdict == "needs_more_work"
  end

  test "verify stage blocks unsafe_to_merge" do
    {workspace, issue} = verify_workspace!("verify-unsafe")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("verify-unsafe"),
      policy_publish_required: false
    )

    assert {:stop, :unsafe_to_merge} =
             DeliveryEngine.run(workspace, issue, nil,
               verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
                 %{
                   verdict: "unsafe_to_merge",
                   summary: "Verifier found risky behavior",
                   acceptance_gaps: [],
                   risky_areas: ["Risk"],
                   evidence: [],
                   raw_output: "unsafe",
                   acceptance: %{summary: "Verifier summary"}
                 }
               end
             )
  end

  test "verify stage blocks needs_more_work when retry budget is exhausted" do
    {workspace, issue} = verify_workspace!("verify-needs-more-work-exhausted")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      implementation_turns: 1
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("verify-needs-more-work-exhausted"),
      policy_publish_required: false,
      policy_retry_validation_failures_within_run: true,
      policy_max_validation_attempts_per_run: 2
    )

    assert {:stop, :verifier_failed} =
             DeliveryEngine.run(workspace, issue, nil,
               max_turns: 1,
               verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
                 %{
                   verdict: "needs_more_work",
                   summary: "Verifier found remaining gaps",
                   acceptance_gaps: ["Gap"],
                   risky_areas: [],
                   evidence: [],
                   raw_output: "needs more work",
                   acceptance: %{summary: "Verifier summary"}
                 }
               end
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "verification.needs_more_work"
  end

  test "verify stage blocks repeated missing behavioral proof" do
    {workspace, issue} = verify_workspace!("verify-behavior-proof-blocked")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      verification_attempts: 1
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("verify-behavior-proof-blocked"),
      policy_publish_required: false,
      policy_retry_validation_failures_within_run: true,
      policy_max_validation_attempts_per_run: 3
    )

    assert {:stop, :behavior_proof_missing} =
             DeliveryEngine.run(workspace, issue, nil,
               max_turns: 2,
               verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
                 %{
                   verdict: "needs_more_work",
                   reason_code: "behavior_proof_missing",
                   summary: "Add or update repo-owned behavioral proof before publish.",
                   acceptance_gaps: ["Add tests"],
                   risky_areas: [],
                   evidence: [],
                   raw_output: "missing proof",
                   acceptance: %{summary: "Verifier summary"},
                   behavioral_proof: %{required: true, satisfied: false, mode: "unit_first"}
                 }
               end
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "verification.behavior_proof_missing"
  end

  test "verify stage blocks repeated missing ui proof" do
    {workspace, issue} = verify_workspace!("verify-ui-proof-blocked")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      verification_attempts: 1
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("verify-ui-proof-blocked"),
      policy_publish_required: false,
      policy_retry_validation_failures_within_run: true,
      policy_max_validation_attempts_per_run: 3
    )

    assert {:stop, :ui_proof_missing} =
             DeliveryEngine.run(workspace, issue, nil,
               max_turns: 2,
               verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
                 %{
                   verdict: "needs_more_work",
                   reason_code: "ui_proof_missing",
                   summary: "Add UI proof before publish.",
                   acceptance_gaps: ["Add UI proof"],
                   risky_areas: [],
                   evidence: [],
                   raw_output: "missing ui proof",
                   acceptance: %{summary: "Verifier summary"},
                   ui_proof: %{required: true, verify_required: true, verify_satisfied: false, mode: "local"}
                 }
               end
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "verification.ui_proof_missing"
  end

  test "verify stage blocks unknown verifier verdicts" do
    {workspace, issue} = verify_workspace!("verify-unknown")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("verify-unknown"),
      policy_publish_required: false
    )

    assert {:stop, :verifier_failed} =
             DeliveryEngine.run(workspace, issue, nil,
               verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
                 %{
                   verdict: "mystery",
                   summary: "Unexpected verifier result",
                   acceptance_gaps: [],
                   risky_areas: [],
                   evidence: [],
                   raw_output: "mystery",
                   acceptance: %{summary: "Verifier summary"}
                 }
               end
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "verification.needs_more_work"
  end

  test "publish is only reached after verifier pass" do
    {workspace, issue} = verify_workspace!("verify-pass")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("verify-pass"),
      policy_publish_required: false
    )

    assert {:stop, :publish_missing_pr} =
             DeliveryEngine.run(workspace, issue, nil,
               verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
                 %{
                   verdict: "pass",
                   summary: "Verifier passed",
                   acceptance_gaps: [],
                   risky_areas: [],
                   evidence: [],
                   raw_output: "pass",
                   acceptance: %{summary: "Verifier summary"}
                 }
               end
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.last_verifier_verdict == "pass"
    assert Enum.any?(state.stage_history, &(&1.stage == "publish"))
  end

  test "verify stage skips the verifier and advances directly to publish when disabled" do
    {workspace, issue} = verify_workspace!("verify-disabled")

    RunStateStore.transition(workspace, "verify", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("verify-disabled"),
      policy_require_verifier: false,
      policy_publish_required: false
    )

    assert {:stop, :publish_missing_pr} = DeliveryEngine.run(workspace, issue, nil)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert Enum.any?(state.stage_history, &(&1.stage == "publish"))
  end

  test "publish stage commits using the issue title when no turn summary is present" do
    {workspace, issue} = verify_workspace!("publish-issue-title")
    File.write!(Path.join(workspace, "README.md"), "changed\n")

    RunStateStore.transition(workspace, "publish", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      branch: "main"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("publish-issue-title"),
      policy_publish_required: true
    )

    assert {:stop, :publish_failed} = DeliveryEngine.run(workspace, issue, nil)

    {message, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: workspace)
    assert String.trim(message) == "MT-VERIFY: Verify"
  end

  test "publish stage blocks noop turns when no commit and no PR exist" do
    {workspace, issue} = verify_workspace!("publish-noop-no-pr")

    RunStateStore.transition(workspace, "publish", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      branch: "main"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("publish-noop-no-pr"),
      policy_publish_required: true
    )

    command_runner = fn
      "git", ["status", "--porcelain"], _opts -> {"", 0}
      "git", ["diff", "--stat", "--no-ext-diff", "HEAD"], _opts -> {"", 0}
      "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts -> {"", 1}
      command, args, opts -> System.cmd(command, args, opts)
    end

    assert {:stop, :noop_turn} = DeliveryEngine.run(workspace, issue, nil, command_runner: command_runner)
  end

  test "publish stage republishes a clean branch when a PR already exists" do
    {workspace, issue} = verify_workspace!("publish-noop-existing-pr")

    RunStateStore.transition(workspace, "publish", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      branch: "main",
      pr_url: "https://github.com/example/repo/pull/77"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("publish-noop-existing-pr"),
      policy_publish_required: true
    )

    command_runner = fn
      "git", ["status", "--porcelain"], _opts -> {"", 0}
      "git", ["diff", "--stat", "--no-ext-diff", "HEAD"], _opts -> {"", 0}
      "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts ->
        {Jason.encode!(%{
           "url" => "https://github.com/example/repo/pull/77",
           "state" => "OPEN",
           "reviewDecision" => "CHANGES_REQUESTED",
           "statusCheckRollup" => []
         }), 0}

      command, args, opts -> System.cmd(command, args, opts)
    end

    assert :ok =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: command_runner,
               github_client: SymphonyElixir.DeliveryEnginePhase3Test.FakeGitHubClient,
               github_client_opts: [
                  existing_pr: %{url: "https://github.com/example/repo/pull/77", state: "OPEN"},
                 pr_url: "https://github.com/example/repo/pull/77"
               ]
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert Enum.any?(state.stage_history, &(&1.stage == "await_checks"))
  end

  test "publish stage creates a commit and records the pushed sha before waiting on checks" do
    {workspace, issue} = verify_workspace!("publish-commit-success")
    File.write!(Path.join(workspace, "README.md"), "changed for publish\n")

    RunStateStore.transition(workspace, "publish", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      branch: "main"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("publish-commit-success"),
      policy_publish_required: true
    )

    command_runner = fn
      "git", ["push", "-u", "origin", "main"], _opts -> {"", 0}

      "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts ->
        {Jason.encode!(%{
           "url" => "https://github.com/example/repo/pull/88",
           "state" => "OPEN",
           "reviewDecision" => "CHANGES_REQUESTED",
           "statusCheckRollup" => []
         }), 0}

      command, args, opts ->
        System.cmd(command, args, opts)
    end

    assert :ok =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: command_runner,
               github_client: SymphonyElixir.DeliveryEnginePhase3Test.FakeGitHubClient,
               github_client_opts: [pr_url: "https://github.com/example/repo/pull/88"]
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert is_binary(state.last_commit_sha)
    assert Enum.any?(state.stage_history, &(&1.stage == "await_checks"))
  end

  test "publish stage blocks when it cannot determine a branch for a fresh commit" do
    {workspace, issue} = verify_workspace!("publish-missing-branch")
    File.write!(Path.join(workspace, "README.md"), "changed without branch\n")

    RunStateStore.transition(workspace, "publish", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("publish-missing-branch"),
      policy_publish_required: true
    )

    command_runner = fn
      "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts -> {"", 1}
      command, args, opts -> System.cmd(command, args, opts)
    end

    assert {:stop, :publish_failed} = DeliveryEngine.run(workspace, issue, nil, command_runner: command_runner)
  end

  test "publish stage blocks when commit creation fails" do
    {workspace, issue} = verify_workspace!("publish-commit-error")
    File.write!(Path.join(workspace, "README.md"), "changed for failed commit\n")

    RunStateStore.transition(workspace, "publish", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      branch: "main"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("publish-commit-error"),
      policy_publish_required: true
    )

    command_runner = fn
      "git", ["commit", "-m", _message], _opts -> {"commit failed", 1}
      command, args, opts -> System.cmd(command, args, opts)
    end

    assert {:stop, :publish_failed} = DeliveryEngine.run(workspace, issue, nil, command_runner: command_runner)
  end

  test "publish stage blocks when PR creation fails after a successful push" do
    {workspace, issue} = verify_workspace!("publish-pr-error")
    File.write!(Path.join(workspace, "README.md"), "changed for failing pr\n")

    RunStateStore.transition(workspace, "publish", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      branch: "main"
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("publish-pr-error"),
      policy_publish_required: true
    )

    command_runner = fn
      "git", ["push", "-u", "origin", "main"], _opts -> {"", 0}
      command, args, opts -> System.cmd(command, args, opts)
    end

    assert {:stop, :publish_failed} =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: command_runner,
               github_client: SymphonyElixir.DeliveryEnginePhase3Test.FakeGitHubClient,
               github_client_opts: [create_error: :pr_create_failed]
             )
  end

  defp verify_workspace!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-delivery-engine-#{suffix}-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "MT-VERIFY")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "README.md"), "initial\n")

    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["add", "README.md"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)

    issue = %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-VERIFY",
      title: "Verify",
      description: "## Acceptance Criteria\n- pass",
      state: "In Progress"
    }

    {workspace, issue}
  end

  defp fake_codex_binary!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-fake-codex-#{suffix}-#{System.unique_integer([:positive])}"
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
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-phase3"}}}'
          ;;
        *)
          case "$line" in
            *'"method":"turn/start"'*)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-phase3"}}}'
              printf '%s\\n' '{"id":99,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"Follow-up implementation","files_touched":[],"needs_another_turn":false,"blocked":false,"blocker_type":"none"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
              ;;
          esac
          ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)
    "#{binary} app-server"
  end
end
