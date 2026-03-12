defmodule SymphonyElixir.PolicyPrVerifierPhase6BackfillTest.VerifierIssuePayload do
  defstruct [:id, :identifier, :title, :description]
end

defmodule SymphonyElixir.PolicyPrVerifierPhase6BackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PullRequestManager
  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunPolicy
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.VerifierResult
  alias SymphonyElixir.VerifierRunner
  alias SymphonyElixir.Workspace

  test "run policy blocks preflight failures before promotion" do
    workspace = temp_workspace!("preflight-failure")
    issue = %Issue{id: "issue-preflight", identifier: "MT-906", state: "Todo"}

    configure_memory_tracker!()
    init_checkout!(workspace)
    write_script!(workspace, "scripts/preflight.sh", "echo preflight failed\nexit 1\n")
    write_valid_harness!(workspace)

    assert {:stop, %RunPolicy.Violation{code: :preflight_failed, details: details}} =
             RunPolicy.enforce_pre_run(issue, workspace)

    assert details == "preflight failed"
    assert_receive {:memory_tracker_comment, "issue-preflight", body}
    assert body =~ "preflight failed"
    assert_receive {:memory_tracker_state_update, "issue-preflight", "Blocked"}
  end

  test "run policy surfaces missing publish checks in the harness" do
    workspace = temp_workspace!("missing-required-checks")
    issue = %Issue{id: "issue-missing-checks", identifier: "MT-907", state: "Todo"}

    configure_memory_tracker!()
    init_checkout!(workspace)

    write_harness!(
      workspace,
      """
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
      verification:
        behavioral_proof:
          required: true
          mode: unit_first
          source_paths:
            - Sources
          test_paths:
            - Tests
      pull_request: {}
      """
    )

    assert {:stop, %RunPolicy.Violation{code: :missing_required_checks}} =
             RunPolicy.enforce_pre_run(issue, workspace)

    assert_receive {:memory_tracker_comment, "issue-missing-checks", body}
    assert body =~ "pull_request.required_checks"
    assert_receive {:memory_tracker_state_update, "issue-missing-checks", "Blocked"}
  end

  test "run policy surfaces unsupported harness keys" do
    workspace = temp_workspace!("unknown-harness-key")
    issue = %Issue{id: "issue-unknown-harness", identifier: "MT-908", state: "Todo"}

    configure_memory_tracker!()
    init_checkout!(workspace)

    write_harness!(
      workspace,
      """
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
      verification:
        behavioral_proof:
          required: true
          mode: unit_first
          source_paths:
            - Sources
          test_paths:
            - Tests
      pull_request:
        required_checks:
          - ci / validate
        unsupported: true
      """
    )

    assert {:stop, %RunPolicy.Violation{code: :invalid_harness, details: details}} =
             RunPolicy.enforce_pre_run(issue, workspace)

    assert details =~ "pull_request"
    assert details =~ "unsupported"
    assert_receive {:memory_tracker_state_update, "issue-unknown-harness", "Blocked"}
  end

  test "run policy surfaces missing harness command entries" do
    workspace = temp_workspace!("missing-harness-command")
    issue = %Issue{id: "issue-missing-command", identifier: "MT-908B", state: "Todo"}

    configure_memory_tracker!()
    init_checkout!(workspace)

    write_harness!(
      workspace,
      """
      version: 1
      base_branch: main
      preflight:
        command:
          - ./scripts/preflight.sh
      smoke:
        command:
          - ./scripts/smoke.sh
      post_merge:
        command:
          - ./scripts/post-merge.sh
      artifacts:
        command:
          - ./scripts/artifacts.sh
      verification:
        behavioral_proof:
          required: true
          mode: unit_first
          source_paths:
            - Sources
          test_paths:
            - Tests
      pull_request:
        required_checks:
          - ci / validate
      """
    )

    assert {:stop, %RunPolicy.Violation{code: :missing_harness_command, details: details}} =
             RunPolicy.enforce_pre_run(issue, workspace)

    assert details =~ "validation.command"
    assert_receive {:memory_tracker_state_update, "issue-missing-command", "Blocked"}
  end

  test "run policy surfaces generic invalid harness contract errors" do
    workspace = temp_workspace!("invalid-harness-contract")
    issue = %Issue{id: "issue-invalid-harness", identifier: "MT-908C", state: "Todo"}

    configure_memory_tracker!()
    init_checkout!(workspace)

    write_harness!(
      workspace,
      """
      version: 1
      base_branch: 123
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
      verification:
        behavioral_proof:
          required: true
          mode: unit_first
          source_paths:
            - Sources
          test_paths:
            - Tests
      pull_request:
        required_checks:
          - ci / validate
      """
    )

    assert {:stop, %RunPolicy.Violation{code: :invalid_harness, details: details}} =
             RunPolicy.enforce_pre_run(issue, workspace)

    assert details =~ "invalid_harness_value"
    assert_receive {:memory_tracker_state_update, "issue-invalid-harness", "Blocked"}
  end

  test "run policy blocks unavailable validation after code changes" do
    configure_memory_tracker!()

    issue = %Issue{id: "issue-validation-unavailable", identifier: "MT-909", state: "In Progress"}
    refreshed_issue = %Issue{id: "issue-validation-unavailable", identifier: "MT-909", state: "In Progress"}

    before_snapshot = %RunInspector.Snapshot{workspace: "/tmp/phase6-policy", fingerprint: 10, pr_url: nil}
    after_snapshot = %RunInspector.Snapshot{workspace: "/tmp/phase6-policy", fingerprint: 11, pr_url: nil, harness: nil}

    assert {:stop, %RunPolicy.Violation{code: :validation_unavailable, details: details}} =
             RunPolicy.evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, 0)

    assert details == "No harness command configured."
    assert_receive {:memory_tracker_comment, "issue-validation-unavailable", body}
    assert body =~ "validation could not run"
    assert_receive {:memory_tracker_state_update, "issue-validation-unavailable", "Blocked"}
  end

  test "run policy normalizes nil and blank validation failure output" do
    configure_memory_tracker!()

    issue = %Issue{id: "issue-validation-output-normalized", identifier: "MT-909B", state: "In Progress"}
    refreshed_issue = %Issue{id: "issue-validation-output-normalized", identifier: "MT-909B", state: "In Progress"}

    before_snapshot = %RunInspector.Snapshot{workspace: "/tmp/phase6-policy-output", fingerprint: 10, pr_url: nil}

    after_snapshot = %RunInspector.Snapshot{
      workspace: "/tmp/phase6-policy-output",
      fingerprint: 11,
      pr_url: nil,
      harness: %RepoHarness{validation_command: "./scripts/validate.sh"}
    }

    assert {:stop, %RunPolicy.Violation{code: :validation_failed, details: details}} =
             RunPolicy.evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, 0, shell_runner: fn _workspace, "./scripts/validate.sh", _opts -> {nil, 1} end)

    assert details == "No additional output was captured."

    assert {:stop, %RunPolicy.Violation{code: :validation_failed, details: blank_details}} =
             RunPolicy.evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, 0, shell_runner: fn _workspace, "./scripts/validate.sh", _opts -> {"   \n", 1} end)

    assert blank_details == "No additional output was captured."
  end

  test "run policy stops once noop turns reach the configured limit" do
    configure_memory_tracker!(policy_require_validation: false, policy_max_noop_turns: 2)

    issue = %Issue{id: "issue-noop-stop", identifier: "MT-910", state: "In Progress"}
    refreshed_issue = %Issue{id: "issue-noop-stop", identifier: "MT-910", state: "In Progress"}

    snapshot = %RunInspector.Snapshot{workspace: "/tmp/phase6-noop", fingerprint: 10, pr_url: nil}

    assert {:stop, %RunPolicy.Violation{code: :noop_turn, details: details}} =
             RunPolicy.evaluate_after_turn(issue, refreshed_issue, snapshot, snapshot, 1)

    assert details == "Noop turns observed: 2."
    assert_receive {:memory_tracker_comment, "issue-noop-stop", body}
    assert body =~ "Noop turns observed: 2."
    assert_receive {:memory_tracker_state_update, "issue-noop-stop", "Blocked"}
  end

  test "run policy resets noop tracking when the turn changed code" do
    configure_memory_tracker!(policy_require_validation: false)

    issue = %Issue{id: "issue-noop-reset", identifier: "MT-911", state: "In Progress"}
    refreshed_issue = %Issue{id: "issue-noop-reset", identifier: "MT-911", state: "In Progress"}

    before_snapshot = %RunInspector.Snapshot{workspace: "/tmp/phase6-noop-reset", fingerprint: 10, pr_url: nil}
    after_snapshot = %RunInspector.Snapshot{workspace: "/tmp/phase6-noop-reset", fingerprint: 11, pr_url: nil}

    assert {:ok, 0} = RunPolicy.evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, 4)
    refute_receive {:memory_tracker_comment, "issue-noop-reset", _body}
  end

  test "run policy resumes noop evaluation after successful validation" do
    workspace = temp_workspace!("validation-passed")
    issue = %Issue{id: "issue-validation-passed", identifier: "MT-915", state: "In Progress"}
    refreshed_issue = %Issue{id: "issue-validation-passed", identifier: "MT-915", state: "In Progress"}

    write_script!(workspace, "scripts/validate.sh", "echo validation passed\nexit 0\n")

    before_snapshot = %RunInspector.Snapshot{workspace: workspace, fingerprint: 10, pr_url: nil}

    after_snapshot = %RunInspector.Snapshot{
      workspace: workspace,
      fingerprint: 11,
      pr_url: nil,
      harness: %RepoHarness{validation_command: "./scripts/validate.sh"}
    }

    assert {:ok, 0} = RunPolicy.evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, 3)
  end

  test "run policy stops when promoting a todo issue fails in the tracker" do
    workspace = git_workspace!("promotion-failure")
    issue = %Issue{id: "issue-promotion-failure", identifier: "MT-916", state: "Todo"}

    configure_linear_tracker_failure!()
    write_script!(workspace, "scripts/preflight.sh", "echo preflight ok\nexit 0\n")
    write_valid_harness!(workspace)
    write_behavioral_proof!(workspace)

    capture_log(fn ->
      assert {:stop, %RunPolicy.Violation{code: :preflight_failed, details: details}} =
               RunPolicy.enforce_pre_run(issue, workspace)

      assert details == "Unable to move issue to In Progress: :state_lookup_down"
    end)
  end

  test "run policy skips todo promotion when issue identity fields are missing" do
    workspace = temp_workspace!("promotion-skipped")

    configure_memory_tracker!()
    init_checkout!(workspace)
    write_script!(workspace, "scripts/preflight.sh", "echo preflight ok\nexit 0\n")
    write_valid_harness!(workspace)

    assert :ok = RunPolicy.enforce_pre_run(%{identifier: "MT-917"}, workspace)
    refute_receive {:memory_tracker_comment, _, _}
    refute_receive {:memory_tracker_state_update, _, _}
  end

  test "run policy treats unavailable preflight execution as a stop condition" do
    workspace = temp_workspace!("preflight-unavailable")
    issue = %Issue{id: "issue-preflight-unavailable", identifier: "MT-918", state: "Todo"}

    configure_memory_tracker!()
    init_checkout!(workspace)
    write_valid_harness!(workspace)

    assert {:stop, %RunPolicy.Violation{code: :preflight_failed, details: details}} =
             RunPolicy.enforce_pre_run(issue, workspace,
               shell_runner: fn
                 _workspace, "./scripts/preflight.sh", _opts -> raise "shell offline"
                 _workspace, _command, _opts -> {"", 1}
               end
             )

    assert details == "shell offline"
  end

  test "run policy validates human review issues even when fingerprints match" do
    workspace = temp_workspace!("human-review-validation")
    issue = %Issue{id: "issue-human-review-validation", identifier: "MT-919", state: "Human Review"}
    refreshed_issue = %Issue{id: "issue-human-review-validation", identifier: "MT-919", state: "Human Review"}

    write_script!(workspace, "scripts/validate.sh", "echo validation passed\nexit 0\n")

    before_snapshot = %RunInspector.Snapshot{workspace: workspace, fingerprint: 10, pr_url: "https://github.com/g/s/pull/919"}

    after_snapshot = %RunInspector.Snapshot{
      workspace: workspace,
      fingerprint: 10,
      pr_url: "https://github.com/g/s/pull/919",
      harness: %RepoHarness{validation_command: "./scripts/validate.sh"}
    }

    assert {:ok, 0} = RunPolicy.evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, 2)
  end

  test "run policy validates human review issues without a PR when review gating is disabled" do
    configure_memory_tracker!(policy_require_pr_before_review: false, policy_stop_on_noop_turn: false)

    workspace = temp_workspace!("human-review-validation-no-pr")
    issue = %Issue{id: "issue-human-review-validation-no-pr", identifier: "MT-919C", state: "Human Review"}
    refreshed_issue = %Issue{id: "issue-human-review-validation-no-pr", identifier: "MT-919C", state: "Human Review"}

    write_script!(workspace, "scripts/validate.sh", "echo validation passed\nexit 0\n")

    before_snapshot = %RunInspector.Snapshot{workspace: workspace, fingerprint: 10, pr_url: nil}

    after_snapshot = %RunInspector.Snapshot{
      workspace: workspace,
      fingerprint: 10,
      pr_url: nil,
      harness: %RepoHarness{validation_command: "./scripts/validate.sh"}
    }

    assert {:ok, 1} = RunPolicy.evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, 0)
  end

  test "run policy blocks human review when no pull request exists" do
    configure_memory_tracker!()

    issue = %Issue{id: "issue-human-review-pr", identifier: "MT-919B", state: "Human Review"}
    refreshed_issue = %Issue{id: "issue-human-review-pr", identifier: "MT-919B", state: "Human Review"}
    snapshot = %RunInspector.Snapshot{workspace: "/tmp/phase6-human-review-pr", fingerprint: 10, pr_url: nil}

    assert {:stop, %RunPolicy.Violation{code: :publish_missing_pr}} =
             RunPolicy.evaluate_after_turn(issue, refreshed_issue, snapshot, snapshot, 0)

    assert_receive {:memory_tracker_state_update, "issue-human-review-pr", "Blocked"}
  end

  test "run policy ignores non-binary review states when deciding validation and PR requirements" do
    configure_memory_tracker!(policy_stop_on_noop_turn: false)

    issue = %Issue{id: "issue-human-review-non-binary", identifier: "MT-919D", state: "In Progress"}
    refreshed_issue = %{id: "issue-human-review-non-binary", identifier: "MT-919D", state: :human_review}
    snapshot = %RunInspector.Snapshot{workspace: "/tmp/phase6-human-review-non-binary", fingerprint: 10, pr_url: nil}

    assert {:ok, 1} = RunPolicy.evaluate_after_turn(issue, refreshed_issue, snapshot, snapshot, 0)
  end

  test "run policy stops when total token budget is exceeded" do
    configure_memory_tracker!(policy_token_budget: %{per_turn_input: nil, per_issue_total: 10, per_issue_total_output: nil})

    issue = %Issue{id: "issue-total-budget", identifier: "MT-912", state: "In Progress"}

    assert {:stop, %RunPolicy.Violation{code: :per_issue_total_budget_exceeded, details: details}} =
             RunPolicy.maybe_stop_for_token_budget(issue, %{
               codex_input_tokens: 4,
               codex_output_tokens: 2,
               codex_total_tokens: 11,
               turn_started_input_tokens: 1
             })

    assert details == "Budget per_issue_total exceeded with observed value 11."
    assert_receive {:memory_tracker_comment, "issue-total-budget", body}
    assert body =~ "budget.per_issue_total_exceeded"
    assert_receive {:memory_tracker_state_update, "issue-total-budget", "Blocked"}
  end

  test "run policy stops when output token budget is exceeded" do
    configure_memory_tracker!(policy_token_budget: %{per_turn_input: nil, per_issue_total: 50, per_issue_total_output: 5})

    issue = %Issue{id: "issue-output-budget", identifier: "MT-913", state: "In Progress"}

    assert {:stop, %RunPolicy.Violation{code: :per_issue_output_budget_exceeded, details: details}} =
             RunPolicy.maybe_stop_for_token_budget(issue, %{
               codex_input_tokens: 4,
               codex_output_tokens: 7,
               codex_total_tokens: 11,
               turn_started_input_tokens: 1
             })

    assert details == "Budget per_issue_total_output exceeded with observed value 7."
    assert_receive {:memory_tracker_comment, "issue-output-budget", body}
    assert body =~ "budget.per_issue_output_exceeded"
    assert_receive {:memory_tracker_state_update, "issue-output-budget", "Blocked"}
  end

  test "run policy allows runs that stay within configured budgets" do
    configure_memory_tracker!(policy_token_budget: %{per_turn_input: 10, per_issue_total: 20, per_issue_total_output: 8})

    issue = %Issue{id: "issue-budget-ok", identifier: "MT-914", state: "In Progress"}

    assert :ok =
             RunPolicy.maybe_stop_for_token_budget(issue, %{
               codex_input_tokens: 3,
               codex_output_tokens: 4,
               codex_total_tokens: 7,
               turn_started_input_tokens: 9
             })

    refute_receive {:memory_tracker_comment, "issue-budget-ok", _body}
    refute_receive {:memory_tracker_state_update, "issue-budget-ok", _state}
  end

  test "run policy uses stage-specific hard per-turn budgets when present" do
    configure_memory_tracker!(
      policy_token_budget: %{
        per_turn_input: 500_000,
        per_issue_total: 1_000_000,
        per_issue_total_output: 500_000,
        stages: %{
          implement: %{
            per_turn_input_soft: 60_000,
            per_turn_input_hard: 120_000
          }
        }
      }
    )

    issue = %Issue{id: "issue-stage-budget", identifier: "MT-914A", state: "In Progress"}

    assert {:stop, %RunPolicy.Violation{code: :per_turn_input_budget_exceeded, details: details}} =
             RunPolicy.maybe_stop_for_token_budget(issue, %{
               stage: "implement",
               codex_input_tokens: 130_000,
               codex_output_tokens: 0,
               codex_total_tokens: 130_000,
               turn_started_input_tokens: 0
             })

    assert details == "Budget per_turn_input exceeded with observed value 130000."
  end

  test "run policy records soft token pressure for stage-aware budgets" do
    configure_memory_tracker!(
      policy_token_budget: %{
        per_turn_input: 500_000,
        per_issue_total: 1_000_000,
        per_issue_total_output: 500_000,
        stages: %{
          implement: %{
            per_turn_input_soft: 60_000,
            per_turn_input_hard: 120_000
          }
        }
      }
    )

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stage-soft-budget-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{id: "issue-soft-budget", identifier: "MT-914C", state: "In Progress"}

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      workspace = Workspace.path_for_issue(issue.identifier)
      File.mkdir_p!(workspace)
      assert {:ok, _state} = RunStateStore.transition(workspace, "implement", %{})

      assert :ok =
               RunPolicy.maybe_stop_for_token_budget(issue, %{
                 stage: "implement",
                 codex_input_tokens: 65_000,
                 codex_output_tokens: 0,
                 codex_total_tokens: 65_000,
                 turn_started_input_tokens: 0
               })

      assert %{resume_context: %{token_pressure: "high"}} = RunStateStore.load_or_default(workspace, issue)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "run policy ignores malformed token budget values" do
    configure_memory_tracker!(policy_token_budget: %{per_turn_input: "ten", per_issue_total: %{}, per_issue_total_output: []})

    issue = %Issue{id: "issue-budget-malformed", identifier: "MT-914B", state: "In Progress"}

    assert :ok =
             RunPolicy.maybe_stop_for_token_budget(issue, %{
               codex_input_tokens: 500,
               codex_output_tokens: 100,
               codex_total_tokens: 900,
               turn_started_input_tokens: 0
             })

    refute_receive {:memory_tracker_comment, "issue-budget-malformed", _body}
    refute_receive {:memory_tracker_state_update, "issue-budget-malformed", _state}
  end

  test "pull request manager updates an existing PR and attaches it to the issue" do
    workspace = temp_workspace!("pull-request-edit")

    issue = %Issue{
      id: "issue-pr-edit",
      identifier: "MT-920",
      title: "Keep the PR current",
      url: "https://linear.app/test/issue/MT-920"
    }

    configure_memory_tracker!()

    assert {:ok, %{url: url, state: "OPEN", body_validation: %{status: "skipped"}}} =
             PullRequestManager.ensure_pull_request(
               workspace,
               issue,
               %{branch: "gaspar/phase6-edit", last_validation: %{status: "passed"}, last_verifier: %{status: "passed"}},
               github_client: __MODULE__.FakeGitHubClient,
               github_client_opts: [
                 test_pid: self(),
                 existing_result: {:ok, %{url: "https://github.com/g/s/pull/20", state: "OPEN"}},
                 edit_result: {:ok, %{url: "https://github.com/g/s/pull/20", state: "OPEN", output: "edited"}}
               ]
             )

    assert url == "https://github.com/g/s/pull/20"
    assert_receive {:existing_pull_request, ^workspace}
    assert_receive {:edited_pr, ^workspace, "MT-920: Keep the PR current", body}
    assert body =~ "Automated PR for MT-920."
    assert_receive {:memory_tracker_attach_link, "issue-pr-edit", "GitHub PR: MT-920", ^url}
    assert_receive {:persist_pr_url, ^workspace, "gaspar/phase6-edit", ^url}
  end

  test "pull request manager bubbles up lookup failures from the GitHub client" do
    workspace = temp_workspace!("pull-request-error")
    issue = %Issue{id: "issue-pr-error", identifier: "MT-921", title: "Surface lookup errors"}

    configure_memory_tracker!()

    assert {:error, :gh_down} =
             PullRequestManager.ensure_pull_request(
               workspace,
               issue,
               %{branch: "gaspar/phase6-error"},
               github_client: __MODULE__.FakeGitHubClient,
               github_client_opts: [test_pid: self(), existing_result: {:error, :gh_down}]
             )

    assert_receive {:existing_pull_request, ^workspace}
    refute_receive {:memory_tracker_attach_link, _, _, _}
  end

  test "pull request manager rejects publication when the branch is missing" do
    workspace = temp_workspace!("pull-request-missing-branch")

    configure_memory_tracker!()

    assert {:error, :missing_branch} =
             PullRequestManager.ensure_pull_request(
               workspace,
               %{"identifier" => "MT-922", "url" => "https://linear.app/test/issue/MT-922"},
               %{},
               github_client: __MODULE__.FakeGitHubClient,
               github_client_opts: [test_pid: self()]
             )

    refute_receive {:memory_tracker_attach_link, _, _, _}
    refute_receive {:persist_pr_url, _, _, _}
  end

  test "pull request manager skips tracker attachment for map issues without ids" do
    workspace = temp_workspace!("pull-request-map-issue")

    configure_memory_tracker!()

    assert {:ok, %{url: "https://github.com/g/s/pull/23", body_validation: %{status: "skipped"}}} =
             PullRequestManager.ensure_pull_request(
               workspace,
               %{"identifier" => "MT-923", "title" => nil, "url" => "https://linear.app/test/issue/MT-923"},
               %{branch: "gaspar/phase6-create"},
               github_client: __MODULE__.FakeGitHubClient,
               github_client_opts: [
                 test_pid: self(),
                 existing_result: {:error, :missing_pr},
                 create_result: {:ok, %{url: "https://github.com/g/s/pull/23", state: "OPEN"}}
               ]
             )

    assert_receive {:created_pr, ^workspace, "gaspar/phase6-create", "main", "MT-923: Untitled", body}
    assert body =~ "Issue: https://linear.app/test/issue/MT-923"
    refute_receive {:memory_tracker_attach_link, _, _, _}
    assert_receive {:persist_pr_url, ^workspace, "gaspar/phase6-create", "https://github.com/g/s/pull/23"}
  end

  test "pull request manager delegates existing and merge wrappers to the configured client" do
    assert {:ok, %{url: "https://github.com/g/s/pull/24", state: "OPEN"}} =
             PullRequestManager.existing_pull_request("/tmp/phase6-existing",
               github_client: __MODULE__.FakeGitHubClient,
               github_client_opts: [
                 test_pid: self(),
                 existing_result: {:ok, %{url: "https://github.com/g/s/pull/24", state: "OPEN"}}
               ]
             )

    assert_receive {:existing_pull_request, "/tmp/phase6-existing"}

    assert {:ok, %{merged: true, url: "https://github.com/g/s/pull/24", status: :merged}} =
             PullRequestManager.merge_pull_request("/tmp/phase6-merge",
               github_client: __MODULE__.FakeGitHubClient,
               github_client_opts: [
                 test_pid: self(),
                 merge_result: {:ok, %{merged: true, url: "https://github.com/g/s/pull/24", output: "merged", status: :merged}}
               ]
             )

    assert_receive {:merge_pull_request, "/tmp/phase6-merge"}
  end

  test "pull request manager default ensure wrapper still rejects missing branches" do
    workspace = temp_workspace!("pull-request-default-missing-branch")

    assert {:error, :missing_branch} =
             PullRequestManager.ensure_pull_request(
               workspace,
               %{"identifier" => "MT-924", "title" => "Default wrapper"},
               %{}
             )
  end

  test "pull request manager default wrappers use gh from PATH" do
    workspace = temp_workspace!("pull-request-default-gh")
    bin_dir = temp_workspace!("pull-request-default-gh-bin")

    write_script!(
      bin_dir,
      "gh",
      """
      case "$1 $2" in
        "pr view")
          printf '%s\\n' '{"url":"https://github.com/g/s/pull/25","state":"OPEN"}'
          ;;
        "pr merge")
          printf '%s\\n' 'merged'
          ;;
        *)
          printf '%s\\n' "unexpected gh args: $*" >&2
          exit 1
          ;;
      esac
      """
    )

    with_path_prefix(bin_dir, fn ->
      assert {:ok, %{url: "https://github.com/g/s/pull/25", state: "OPEN"}} =
               PullRequestManager.existing_pull_request(workspace)

      assert {:ok, %{merged: true, url: "https://github.com/g/s/pull/25", status: :merged}} =
               PullRequestManager.merge_pull_request(workspace)
    end)
  end

  test "pull request manager default ensure wrapper creates a PR via gh on PATH" do
    workspace = temp_workspace!("pull-request-default-create")
    bin_dir = temp_workspace!("pull-request-default-create-bin")
    issue = %Issue{id: "issue-pr-default-create", identifier: "MT-924", title: "Create via gh", url: "https://linear.app/test/issue/MT-924"}

    configure_memory_tracker!()
    File.mkdir_p!(Path.join(workspace, ".git"))

    write_script!(
      bin_dir,
      "gh",
      """
      case "$1 $2" in
        "pr view")
          printf '%s\\n' 'missing pr' >&2
          exit 1
          ;;
        "pr create")
          printf '%s\\n' 'https://github.com/g/s/pull/26'
          ;;
        *)
          printf '%s\\n' "unexpected gh args: $*" >&2
          exit 1
          ;;
      esac
      """
    )

    write_script!(
      bin_dir,
      "git",
      """
      if [ "$1" = "config" ]; then
        exit 0
      fi
      printf '%s\\n' "unexpected git args: $*" >&2
      exit 1
      """
    )

    with_path_prefix(bin_dir, fn ->
      assert {:ok, %{url: "https://github.com/g/s/pull/26", state: "OPEN", body_validation: %{status: "skipped"}}} =
               PullRequestManager.ensure_pull_request(
                 workspace,
                 issue,
                 %{branch: "gaspar/phase6-default-create"}
               )
    end)

    assert_receive {:memory_tracker_attach_link, "issue-pr-default-create", "GitHub PR: MT-924", "https://github.com/g/s/pull/26"}
  end

  test "pull request manager surfaces PR body lint failures before calling GitHub" do
    workspace = temp_workspace!("pull-request-pr-body-invalid")

    File.mkdir_p!(Path.join(workspace, ".github"))
    File.write!(Path.join(workspace, ".github/pull_request_template.md"), "template\n")
    File.mkdir_p!(Path.join([workspace, "elixir", "lib", "mix", "tasks"]))
    File.write!(Path.join([workspace, "elixir", "lib", "mix", "tasks", "pr_body.check.ex"]), "# marker\n")

    assert {:error, {:pr_body_invalid, status, output}} =
             PullRequestManager.ensure_pull_request(
               workspace,
               %{"identifier" => "MT-925", "title" => "Lint should fail"},
               %{branch: "gaspar/phase6-pr-body-invalid"}
             )

    assert status != 0
    assert output =~ "pr_body.check"
  end

  test "pull request manager surfaces temp file write failures" do
    workspace = temp_workspace!("pull-request-body-write-failure")
    tmp_dir = Path.join(workspace, "not-a-directory")
    File.write!(tmp_dir, "blocked")

    assert {:error, {:pr_body_write_failed, reason}} =
             PullRequestManager.ensure_pull_request(
               workspace,
               %{"identifier" => "MT-926", "title" => "Temp dir failure"},
               %{branch: "gaspar/phase6-pr-body-write"},
               github_client: __MODULE__.FakeGitHubClient,
               github_client_opts: [test_pid: self()],
               tmp_dir: tmp_dir
             )

    assert is_atom(reason)
  end

  test "verifier runner blocks results when the verifier mutated the workspace" do
    workspace = git_workspace!("verifier-mutated")
    issue = verifier_issue("issue-verifier-mutated", "MT-930")
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: fn _workspace, _issue, _state, _opts ->
          File.write!(Path.join(workspace, "runtime.txt"), "changed by verifier\n")

          {:ok,
           %VerifierResult{
             verdict: :pass,
             summary: "Verifier liked the diff",
             acceptance_gaps: [],
             risky_areas: [],
             evidence: ["Existing evidence"],
             raw_output: "pass"
           }}
        end
      )

    assert result.verdict == "blocked"
    assert result.summary =~ "mutated the workspace"
    assert result.risky_areas == ["Verification must not change files, git state, or PR metadata."]
  end

  test "verifier runner blocks invalid structured verifier results" do
    workspace = git_workspace!("verifier-invalid")
    issue = verifier_issue("issue-verifier-invalid", "MT-931")
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: fn _workspace, _issue, _state, _opts ->
          {:error, {:invalid_verifier_result, :bad_schema}}
        end
      )

    assert result.verdict == "blocked"
    assert result.summary =~ "invalid structured result"
    assert result.risky_areas == [":bad_schema"]
  end

  test "verifier runner blocks session failures before a result is produced" do
    workspace = git_workspace!("verifier-session-error")
    issue = verifier_issue("issue-verifier-session-error", "MT-932")
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: fn _workspace, _issue, _state, _opts ->
          {:error, :timeout}
        end
      )

    assert result.verdict == "blocked"
    assert result.summary =~ "session failed"
    assert result.risky_areas == [":timeout"]
  end

  test "verifier runner uses the default app-server session path" do
    test_root = temp_workspace!("verifier-app-server-valid")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = git_workspace_in_root!(workspace_root, "MT-933")
    codex_binary = write_fake_verifier_codex!(test_root, :valid)
    issue = verifier_issue("issue-verifier-app-valid", "MT-933")
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result = VerifierRunner.verify(workspace, issue, %{last_validation: %{output: "validation ok"}}, inspection)

    assert result.verdict == "pass"
    assert result.summary == "Ready to ship"
    assert "Verifier evidence" in result.evidence
    assert Enum.any?(result.evidence, &String.starts_with?(&1, "Changed files: "))
  end

  test "verifier runner formats empty acceptance criteria in the default app-server prompt" do
    test_root = temp_workspace!("verifier-app-server-empty-criteria")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = git_workspace_in_root!(workspace_root, "MT-933B")
    codex_binary = write_fake_verifier_codex!(test_root, :valid)

    issue = %Issue{
      id: "issue-verifier-app-empty-criteria",
      identifier: "MT-933B",
      title: "Verifier without acceptance bullets",
      description: nil
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result = VerifierRunner.verify(workspace, issue, %{last_validation: %{output: "validation ok"}}, inspection)

    assert result.verdict == "pass"
    assert result.summary == "Ready to ship"
  end

  test "verifier runner blocks when the default app-server path omits the verifier result" do
    test_root = temp_workspace!("verifier-app-server-missing")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = git_workspace_in_root!(workspace_root, "MT-934")
    codex_binary = write_fake_verifier_codex!(test_root, :missing_result)
    issue = verifier_issue("issue-verifier-app-missing", "MT-934")
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result = VerifierRunner.verify(workspace, issue, %{last_validation: %{output: "validation ok"}}, inspection)

    assert result.verdict == "blocked"
    assert result.summary =~ "without reporting"
    assert result.risky_areas == ["Verifier tool result missing."]
  end

  test "verifier runner blocks invalid default app-server verifier payloads" do
    test_root = temp_workspace!("verifier-app-server-invalid")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = git_workspace_in_root!(workspace_root, "MT-935")
    codex_binary = write_fake_verifier_codex!(test_root, :invalid_result)
    issue = verifier_issue("issue-verifier-app-invalid", "MT-935")
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result = VerifierRunner.verify(workspace, issue, %{last_validation: %{output: "validation ok"}}, inspection)

    assert result.verdict == "blocked"
    assert result.summary =~ "invalid structured result"
    assert Enum.any?(result.risky_areas, &String.contains?(&1, "missing_keys"))
  end

  test "verifier runner blocks unsupported default app-server tool calls that leave malformed state behind" do
    test_root = temp_workspace!("verifier-app-server-unsupported")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = git_workspace_in_root!(workspace_root, "MT-936")
    codex_binary = write_fake_verifier_codex!(test_root, :unsupported_tool)
    issue = verifier_issue("issue-verifier-app-unsupported", "MT-936")
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result =
      VerifierRunner.verify(workspace, issue, %{last_validation: %{output: "validation ok"}}, inspection,
        on_message: fn
          %{event: :tool_call_failed} ->
            Process.put({:symphony_verifier_result, issue.id}, :unexpected_payload)

          _message ->
            :ok
        end
      )

    assert result.verdict == "blocked"
    assert result.summary =~ "invalid structured result"
    assert result.risky_areas == [":unexpected_payload"]
  end

  test "verifier runner accepts map issues on the default app-server path and normalizes reasoning config for verifier runs" do
    test_root = temp_workspace!("verifier-app-server-map-issue")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = git_workspace_in_root!(workspace_root, "MT-937")
    codex_binary = write_fake_verifier_codex!(test_root, :valid)

    issue = %{
      id: "issue-verifier-app-map",
      identifier: "MT-937",
      title: "Map-backed verifier issue",
      description: "## Acceptance Criteria\n- verifier accepts plain maps"
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: "./smoke.sh"}}

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} --config model_reasoning_effort=high app-server"
    )

    write_script!(workspace, "smoke.sh", "echo smoke passed\nexit 0\n")
    write_behavioral_proof!(workspace)

    result = VerifierRunner.verify(workspace, issue, %{last_validation: %{output: "validation ok"}}, inspection)

    assert result.verdict == "pass"
    assert result.summary == "Ready to ship"
    assert "Verifier evidence" in result.evidence

    argv = File.read!(Path.join(test_root, "fake-codex-argv.txt"))
    input = File.read!(Path.join(test_root, "fake-codex-input.txt"))

    assert argv =~ "--config model_reasoning_effort=high app-server"
    assert input =~ "\"method\":\"turn/start\""
    assert input =~ "\"effort\":\"xhigh\""
  end

  test "verifier runner delegates post-merge verification to the harness command" do
    result =
      VerifierRunner.post_merge_verify("/tmp/phase6-post-merge", %RepoHarness{post_merge_command: "./post-merge.sh"},
        shell_runner: fn _workspace, "./post-merge.sh", _opts -> {"post-merge ok\n", 0} end
      )

    assert result.status == :passed
    assert result.command == "./post-merge.sh"
    assert result.output == "post-merge ok\n"
  end

  test "verifier runner default post-merge wrapper reports unavailable commands" do
    result = VerifierRunner.post_merge_verify("/tmp/phase6-post-merge-missing", nil)

    assert result.status == :unavailable
    assert result.command == nil
  end

  defmodule FakeGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def existing_pull_request(workspace, opts) do
      send(opts[:test_pid], {:existing_pull_request, workspace})
      Keyword.get(opts, :existing_result, {:error, :missing_pr})
    end

    @impl true
    def edit_pull_request(workspace, title, body_file, opts) do
      send(opts[:test_pid], {:edited_pr, workspace, title, File.read!(body_file)})
      Keyword.get(opts, :edit_result, {:ok, %{url: "https://github.com/g/s/pull/1", state: "OPEN", output: "edited"}})
    end

    @impl true
    def create_pull_request(workspace, branch, base_branch, title, body_file, opts) do
      send(opts[:test_pid], {:created_pr, workspace, branch, base_branch, title, File.read!(body_file)})
      Keyword.get(opts, :create_result, {:ok, %{url: "https://github.com/g/s/pull/2", state: "OPEN"}})
    end

    @impl true
    def merge_pull_request(workspace, opts) do
      send(opts[:test_pid], {:merge_pull_request, workspace})
      Keyword.fetch!(opts, :merge_result)
    end

    @impl true
    def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}

    @impl true
    def persist_pr_url(workspace, branch, url, opts) do
      send(opts[:test_pid], {:persist_pr_url, workspace, branch, url})
      :ok
    end
  end

  defmodule FailingLinearClient do
    def graphql(_query, _variables), do: {:error, :state_lookup_down}
  end

  defp configure_memory_tracker!(workflow_overrides \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(workflow_overrides, :tracker_kind, "memory"))
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)
  end

  defp configure_linear_tracker_failure! do
    Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.FailingLinearClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)
  end

  defp temp_workspace!(suffix) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    workspace
  end

  defp init_checkout!(workspace) do
    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    File.write!(Path.join(workspace, ".gitkeep"), "initial\n")
    System.cmd("git", ["add", ".gitkeep"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    :ok
  end

  defp write_valid_harness!(workspace) do
    write_harness!(
      workspace,
      """
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
      verification:
        behavioral_proof:
          required: true
          mode: unit_first
          source_paths:
            - Sources
          test_paths:
            - Tests
      pull_request:
        required_checks:
          - ci / validate
      """
    )
  end

  defp write_harness!(workspace, content) do
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, ".symphony/harness.yml"), content)
  end

  defp write_script!(workspace, relative_path, contents) do
    path = Path.join(workspace, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/usr/bin/env bash\n" <> contents)
    File.chmod!(path, 0o755)
    path
  end

  defp write_behavioral_proof!(workspace) do
    path = Path.join(workspace, "Tests/VerifierProofTests.swift")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "import XCTest\n\nfinal class VerifierProofTests: XCTestCase {}\n")
    path
  end

  defp with_path_prefix(path_prefix, fun) do
    previous_path = System.get_env("PATH")
    System.put_env("PATH", path_prefix <> ":" <> previous_path)

    try do
      fun.()
    after
      restore_env("PATH", previous_path)
    end
  end

  defp git_workspace!(suffix) do
    workspace = temp_workspace!(suffix)

    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    System.cmd("git", ["add", "README.md"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)

    workspace
  end

  defp git_workspace_in_root!(workspace_root, folder) do
    workspace = Path.join(workspace_root, folder)

    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    System.cmd("git", ["add", "README.md"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)
    workspace
  end

  defp write_fake_verifier_codex!(root, mode) do
    path = Path.join(root, "fake-codex")
    argv_path = Path.join(root, "fake-codex-argv.txt")
    input_path = Path.join(root, "fake-codex-input.txt")

    tool_event =
      case mode do
        :valid ->
          %{
            "id" => 104,
            "method" => "item/tool/call",
            "params" => %{
              "tool" => "report_verifier_result",
              "callId" => "call-verifier-valid",
              "threadId" => "thread-verifier",
              "turnId" => "turn-verifier",
              "arguments" => %{
                "verdict" => "pass",
                "summary" => "Ready to ship",
                "acceptance_gaps" => [],
                "risky_areas" => [],
                "evidence" => ["Verifier evidence"],
                "raw_output" => "pass"
              }
            }
          }

        :invalid_result ->
          %{
            "id" => 104,
            "method" => "item/tool/call",
            "params" => %{
              "tool" => "report_verifier_result",
              "callId" => "call-verifier-invalid",
              "threadId" => "thread-verifier",
              "turnId" => "turn-verifier",
              "arguments" => %{
                "verdict" => "pass",
                "summary" => ""
              }
            }
          }

        :unsupported_tool ->
          %{
            "id" => 104,
            "method" => "item/tool/call",
            "params" => %{
              "tool" => "unexpected_verifier_tool",
              "callId" => "call-verifier-unsupported",
              "threadId" => "thread-verifier",
              "turnId" => "turn-verifier",
              "arguments" => %{}
            }
          }

        :missing_result ->
          nil
      end

    tool_event_script =
      if tool_event do
        ~s|printf '%s\\n' '#{sh_escape(Jason.encode!(tool_event))}'|
      else
        ":"
      end

    completed_event = sh_escape(Jason.encode!(%{"method" => "turn/completed"}))

    turn_completion_script =
      if mode == :missing_result do
        """
        printf '%s\\n' '#{completed_event}'
        """
      else
        """
        #{tool_event_script}
        printf '%s\\n' '#{completed_event}'
        """
      end

    script = """
    #!/bin/sh
    printf '%s\\n' "$*" > "#{argv_path}"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "#{input_path}"
      case "$line" in
        *'"id":1'*)
          printf '%s\\n' '#{sh_escape(Jason.encode!(%{"id" => 1, "result" => %{}}))}'
          ;;
        *'"id":2'*)
          printf '%s\\n' '#{sh_escape(Jason.encode!(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-verifier"}}}))}'
          ;;
        *'"id":3'*)
          printf '%s\\n' '#{sh_escape(Jason.encode!(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-verifier"}}}))}'
          #{turn_completion_script}
          ;;
      esac
    done

    exit 0
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp sh_escape(value) do
    String.replace(value, "'", "'\"'\"'")
  end

  defp verifier_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Verify phase 6 coverage backfill",
      description: "## Acceptance Criteria\n- verifier coverage backfill"
    }
  end
end
