defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    assert Config.poll_interval_ms() == 600_000
    assert Config.healing_poll_interval_ms() == 1_800_000
    assert Config.linear_active_states() == ["Todo", "In Progress"]
    assert Config.linear_terminal_states() == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert Config.linear_assignee() == nil
    assert Config.agent_max_turns() == 3
    assert Config.policy_require_checkout?() == true
    assert Config.policy_require_pr_before_review?() == true
    assert Config.policy_require_validation?() == true
    assert Config.policy_stop_on_noop_turn?() == true
    assert Config.policy_max_noop_turns() == 1
    assert Config.policy_per_turn_input_budget() == 150_000
    assert Config.policy_per_issue_total_budget() == 500_000
    assert Config.policy_per_issue_total_output_budget() == nil

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")
    assert Config.poll_interval_ms() == 600_000

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.poll_interval_ms() == 45_000
    assert Config.discovery_poll_interval_ms() == 45_000

    write_workflow_file!(Workflow.workflow_file_path(),
      poll_interval_ms: 45_000,
      discovery_poll_interval_ms: 15_000
    )

    assert Config.poll_interval_ms() == 15_000
    assert Config.discovery_poll_interval_ms() == 15_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert Config.agent_max_turns() == 3

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.agent_max_turns() == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert Config.linear_active_states() == ["Todo", "Review"]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_codex_approval_policy, 123}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_codex_thread_sandbox, 123}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: 123)
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), policy_default_issue_class: "totally_invalid")
    assert {:error, {:invalid_policy_default_issue_class, "totally_invalid"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    repo_workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.set_workflow_file_path(repo_workflow_path)
    WorkflowStore.force_reload()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1 https://github.com/openai/symphony ."
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "implement prompt enforces execution hygiene and defers heavyweight validation" do
    issue = %Issue{
      id: "issue-execution-hygiene",
      identifier: "MT-HYGIENE",
      title: "Reduce implement-stage command bloat",
      description: "Keep implementation focused on code changes."
    }

    prompt = SymphonyElixir.DeliveryEngine.implement_prompt_for_test(issue, %{}, [], 1, 3)

    assert prompt =~ "Do not run full validation, smoke, build, or test commands during `implement`."
    assert prompt =~ "Do not run heavyweight commands such as `xcodebuild`, `make all`, full test suites"
    assert prompt =~ "Limit shell usage to targeted inspection and editing support only"
    assert prompt =~ "Keep command output small."
  end

  test "implement prompt includes repo platform guidance for ios apps" do
    issue = %Issue{
      id: "issue-platform-guidance",
      identifier: "MT-IOS",
      title: "Respect the iOS repo platform",
      description: "Keep implementation guidance aligned to the current repository."
    }

    inspection = %SymphonyElixir.RunInspector.Snapshot{
      fingerprint: "ios-fingerprint",
      dirty?: false,
      changed_files: 0,
      pr_url: nil,
      harness: %{project: %{type: "ios-app"}}
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{},
        [inspection: inspection],
        1,
        3
      )

    assert prompt =~ "Repo platform: iOS app (SwiftUI/Xcode)."
    assert prompt =~ "Ignore unrelated web or JavaScript framework guidance such as Vue, React, or Next.js."
  end

  test "implement prompt includes compact repo map facts from the harness" do
    issue = %Issue{
      id: "issue-repo-map",
      identifier: "MT-MAP",
      title: "Use the harness-backed repo map",
      description: "Avoid rediscovering stable project facts."
    }

    inspection = %SymphonyElixir.RunInspector.Snapshot{
      fingerprint: "repo-map-fingerprint",
      dirty?: false,
      changed_files: 0,
      pr_url: nil,
      harness: %{
        base_branch: "gaspar/harness-engineering",
        project: %{
          type: "ios-app",
          xcodeproj: "LocalEventsExplorer.xcodeproj",
          scheme: "LocalEventsExplorerSymphony"
        },
        runtime: %{
          simulator_destination: "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2",
          developer_dir: "xcode-select"
        },
        behavioral_proof: %{
          required: true,
          mode: "unit_first",
          source_paths: ["LocalEventsExplorer/"],
          test_paths: ["LocalEventsExplorerTests/", "LocalEventsExplorerUITests/"]
        },
        ui_proof: %{
          required: false,
          mode: "local",
          source_paths: ["LocalEventsExplorer/Views/"],
          test_paths: ["LocalEventsExplorerUITests/"]
        }
      }
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{},
        [inspection: inspection],
        1,
        3
      )

    assert prompt =~ "Resolved workflow profile: fully_autonomous"
    assert prompt =~ "Repo map:"
    assert prompt =~ "Project reference: LocalEventsExplorer.xcodeproj | LocalEventsExplorerSymphony"
    assert prompt =~ "Base branch: gaspar/harness-engineering"
    assert prompt =~ "Behavioral proof: required; mode=unit_first"
    assert prompt =~ "UI proof: optional; mode=local"
  end

  test "implement prompt switches to scoped review-fix mode for accepted review claims" do
    issue = %Issue{
      id: "issue-review-fix",
      identifier: "MT-REVIEW",
      title: "Address review comments",
      description: "Large issue context that should not dominate the scoped review-fix turn."
    }

    state = %{
      pr_url: "https://github.com/gaspardip/symphony/pull/1",
      review_claims: %{
        "comment:1" => %{
          "disposition" => "accepted",
          "actionable" => true,
          "claim_type" => "correctness_risk",
          "path" => "lib/one.ex",
          "line" => 10,
          "body" => "First verified review claim."
        },
        "comment:2" => %{
          "disposition" => "accepted",
          "actionable" => true,
          "claim_type" => "failure_handling_risk",
          "path" => "lib/two.ex",
          "line" => 20,
          "body" => "Second verified review claim."
        },
        "comment:3" => %{
          "disposition" => "accepted",
          "actionable" => true,
          "claim_type" => "correctness_risk",
          "path" => "lib/three.ex",
          "line" => 30,
          "body" => "Third verified review claim."
        }
      },
      resume_context: %{token_pressure: "high"}
    }

    prompt = SymphonyElixir.DeliveryEngine.implement_prompt_for_test(issue, state, [], 1, 3)

    assert prompt =~ "This is a scoped review-fix turn. Do not rediscover the issue or rescan the repo."
    assert prompt =~ "Scoped review-fix lane: active"
    assert prompt =~ "Scope kind: review_claim_batch"
    assert prompt =~ "Scope ids:\n- comment:1\n- comment:2\n- comment:3"
    assert prompt =~ "Address the scoped review_claim_batch items only: comment:1, comment:2, comment:3."
    refute prompt =~ "Issue brief:"
    refute prompt =~ "Repo map:"
    refute prompt =~ "Last implementation summary:"
  end

  test "implement prompt narrows high-pressure review-fix retries to one scope id" do
    issue = %Issue{
      id: "issue-review-fix-pressure",
      identifier: "MT-REVIEW-PRESSURE",
      title: "Address review comments under budget pressure",
      description: "Keep scoped review turns small."
    }

    state = %{
      review_claims: %{
        "comment:1" => %{
          "disposition" => "accepted",
          "actionable" => true,
          "claim_type" => "correctness_risk",
          "path" => "lib/one.ex",
          "line" => 10,
          "body" => "First verified review claim."
        },
        "comment:2" => %{
          "disposition" => "accepted",
          "actionable" => true,
          "claim_type" => "correctness_risk",
          "path" => "lib/two.ex",
          "line" => 20,
          "body" => "Second verified review claim."
        }
      },
      resume_context: %{
        budget_mode: "review_fix",
        budget_pressure_level: "soft",
        budget_retry_count: 1,
        budget_scope_kind: "review_claim_batch",
        budget_scope_ids: ["comment:1"],
        budget_auto_narrowed: true,
        token_pressure: "high"
      }
    }

    prompt = SymphonyElixir.DeliveryEngine.implement_prompt_for_test(issue, state, [], 1, 3)

    assert prompt =~ "Scoped review-fix lane: active"
    assert prompt =~ "Scope ids:\n- comment:1"
    refute prompt =~ "- comment:2"
    assert prompt =~ "Address the scoped review_claim_batch items only: comment:1."
  end

  test "implement prompt narrows resume context for scoped review-fix retries" do
    issue = %Issue{
      id: "issue-review-fix-budget",
      identifier: "MT-REVIEW-FIX",
      title: "Address scoped review feedback",
      description: "Keep the prompt focused on the current review-fix batch."
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{
          review_threads: %{
            "comment:1" => %{"draft_state" => "drafted"},
            "comment:2" => %{"draft_state" => "drafted"}
          },
          resume_context: %{
            budget_mode: "review_fix",
            budget_pressure_level: "high",
            budget_retry_count: 1,
            budget_scope_kind: "review_claim_batch",
            budget_scope_ids: ["comment:1"],
            budget_auto_narrowed: true,
            token_pressure: "high",
            last_turn_summary: "Adjusted the first claim locally.",
            diff_summary: " lib/foo.ex | 10 +-"
          }
        },
        [],
        2,
        5
      )

    assert prompt =~ "Scoped review-fix lane: active"
    assert prompt =~ "Scope ids:\n- comment:1"
    assert prompt =~ "Scoped review-fix token pressure is active."
    assert prompt =~ "Address the scoped review_claim_batch items only: comment:1."
    refute prompt =~ "Diff stat:"
  end

  test "implement prompt enters scoped ci-failure budget lane from failed checks" do
    issue = %Issue{
      id: "issue-ci-failure-prompt",
      identifier: "MT-CI-FAILURE",
      title: "Fix the failing required check",
      description: "Keep the recovery turn scoped to CI failures."
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{
          last_failing_required_checks: ["make-all"],
          implementation_turns: 2
        },
        [],
        3,
        5
      )

    assert prompt =~ "Scoped review-fix lane: active"
    assert prompt =~ "Scope kind: ci_failure_batch"
    assert prompt =~ "Scope ids:\n- make-all"
    assert prompt =~ "Address the scoped ci_failure_batch items only: make-all."
  end

  test "implement prompt narrows broad implement retries under token pressure" do
    issue = %Issue{
      id: "issue-broad-budget-prompt",
      identifier: "MT-BROAD-BUDGET",
      title: "Shape broad implement context",
      description: "Operators need the issue, state, and delivery telemetry surfaces to agree."
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{
          resume_context: %{
            budget_mode: "broad_implement",
            budget_pressure_level: "high",
            budget_retry_count: 1,
            budget_auto_narrowed: true,
            token_pressure: "high",
            last_turn_summary: "Mapped the parity bug to the issue payload presenter path.",
            already_learned: "The parity bug is concentrated in elixir/lib/symphony_elixir_web/presenter.ex.",
            target_paths: ["elixir/lib/symphony_elixir_web/presenter.ex"],
            last_blocking_rule: "budget.per_turn_input_exceeded",
            dirty_files: ["elixir/lib/symphony_elixir_web/presenter.ex"],
            review_feedback_summary: "- correctness_risk lib/foo.ex: repeated context",
            review_claim_summary: "- correctness_risk lib/foo.ex: verified",
            diff_summary: " presenter.ex | 40 ++++++++++++++++++++++"
          }
        },
        [],
        2,
        3
      )

    assert prompt =~ "This is a narrow broad-implement retry."
    assert prompt =~ "Broad implement retry lane: active"
    assert prompt =~ "Budget retry count: 1"
    assert prompt =~ "Broad implement token pressure is active."
    assert prompt =~ "Execution hint:"
    assert prompt =~ "Focus path: `elixir/lib/symphony_elixir_web/presenter.ex`."
    assert prompt =~ "If one more file is strictly required, name the exact path instead of expanding heuristically."
    assert prompt =~ "Already learned: The parity bug is concentrated"
    assert prompt =~ "Exact next objective:"
    assert prompt =~ "Advance the ticket by working only in `elixir/lib/symphony_elixir_web/presenter.ex`."
    assert prompt =~ "If one additional file is strictly required, name the exact path and stop"
    assert prompt =~ "Target paths:\n- elixir/lib/symphony_elixir_web/presenter.ex"
    refute prompt =~ "Pending PR review feedback"
    refute prompt =~ "Pending PR review claims"
    refute prompt =~ "Diff stat:"
    refute prompt =~ "Dirty files:"
    refute prompt =~ "Last implementation summary:"
    refute prompt =~ "Issue brief:"
    refute prompt =~ "Repo map:"
  end

  test "implement prompt bounds broad implement expansion retries to two explicit files" do
    issue = %Issue{
      id: "issue-broad-budget-expansion-prompt",
      identifier: "MT-BROAD-EXPANSION",
      title: "Shape bounded broad implement expansion",
      description: "If one extra file is needed, the retry should stay inside exactly two explicit files."
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{
          resume_context: %{
            budget_mode: "broad_implement",
            budget_pressure_level: "high",
            budget_retry_count: 2,
            budget_auto_narrowed: true,
            budget_expansion_used: true,
            token_pressure: "high",
            already_learned: "Stay inside elixir/lib/symphony_elixir_web/presenter.ex, elixir/lib/symphony_elixir_web/router.ex and avoid unrelated reads or repo-wide rediscovery.",
            target_paths: [
              "elixir/lib/symphony_elixir_web/presenter.ex",
              "elixir/lib/symphony_elixir_web/router.ex"
            ],
            next_required_path: "elixir/lib/symphony_elixir_web/router.ex",
            last_blocking_rule: "budget.broad_implement_focus_insufficient"
          }
        },
        [],
        3,
        3
      )

    assert prompt =~ "Focus path: `elixir/lib/symphony_elixir_web/presenter.ex` plus approved expansion `elixir/lib/symphony_elixir_web/router.ex`."
    assert prompt =~ "Do not read outside these two files in this retry."
    assert prompt =~ "Next required path: elixir/lib/symphony_elixir_web/router.ex"
    assert prompt =~ "Advance the ticket by working only in `elixir/lib/symphony_elixir_web/presenter.ex` and `elixir/lib/symphony_elixir_web/router.ex`."
    refute prompt =~ "adjacent helper"
  end

  test "implement prompt keeps fallback broad retry context when no target path exists yet" do
    issue = %Issue{
      id: "issue-broad-budget-fallback-prompt",
      identifier: "MT-BROAD-FALLBACK",
      title: "Shape fallback broad retry context",
      description: "Keep the issue brief only until a concrete focus path exists."
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{
          resume_context: %{
            budget_mode: "broad_implement",
            budget_pressure_level: "high",
            budget_retry_count: 1,
            budget_auto_narrowed: true,
            token_pressure: "high",
            last_turn_summary: "Need to confirm the first concrete parity surface before editing.",
            dirty_files: ["elixir/lib/symphony_elixir_web/presenter.ex"],
            next_objective: "Pick the smallest concrete path and stop broad discovery."
          }
        },
        [],
        2,
        3
      )

    assert prompt =~ "This is a narrow broad-implement retry."
    assert prompt =~ "Execution hint: stay inside the first concrete path you confirm and avoid broad discovery."
    assert prompt =~ "Issue brief:"
    refute prompt =~ "Last implementation summary:"
    refute prompt =~ "Dirty files:"
    refute prompt =~ "Target paths:"
  end

  test "implement prompt normalizes broad retry resume context from persisted string keys" do
    issue = %Issue{
      id: "issue-broad-budget-string-keys",
      identifier: "MT-BROAD-STRING",
      title: "Normalize persisted broad retry state",
      description: "Blocked retry payloads may round-trip through JSON before prompting again."
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{
          resume_context: %{
            "budget_mode" => "broad_implement",
            "budget_pressure_level" => "high",
            "budget_retry_count" => 2,
            "budget_auto_narrowed" => true,
            "token_pressure" => "high",
            "target_paths" => ["elixir/lib/symphony_elixir/run_policy.ex"],
            "next_required_path" => "elixir/lib/symphony_elixir/delivery_engine.ex",
            "already_learned" =>
              "Stay inside elixir/lib/symphony_elixir/run_policy.ex and avoid unrelated reads or repo-wide rediscovery.",
            "budget_expansion_used" => true,
            "budget_last_stop_code" => "budget.broad_implement_focus_insufficient"
          }
        },
        [],
        3,
        4
      )

    assert prompt =~ "Broad implement retry lane: active"
    assert prompt =~ "Budget retry count: 2"
    assert prompt =~ "Next required path: elixir/lib/symphony_elixir/delivery_engine.ex"
    assert prompt =~
             "Focus path: `elixir/lib/symphony_elixir/run_policy.ex`. Stay inside this file."
    assert prompt =~
             "Advance the ticket by working only in `elixir/lib/symphony_elixir/run_policy.ex`."
  end

  test "implement prompt enters scoped review-fix budget lane from accepted review claims" do
    issue = %Issue{
      id: "issue-review-fix-prompt",
      identifier: "MT-REVIEW-FIX",
      title: "Address accepted review claims",
      description: "Keep the recovery turn scoped to accepted review feedback."
    }

    prompt =
      SymphonyElixir.DeliveryEngine.implement_prompt_for_test(
        issue,
        %{
          review_claims: %{
            "comment:1" => %{
              "disposition" => "accepted",
              "actionable" => true,
              "implementation_status" => "pending"
            },
            "comment:2" => %{
              "disposition" => "dismissed",
              "actionable" => false,
              "implementation_status" => "not_needed"
            }
          },
          implementation_turns: 4
        },
        [],
        5,
        7
      )

    assert prompt =~ "Scoped review-fix lane: active"
    assert prompt =~ "Scope kind: review_claim_batch"
    assert prompt =~ "Scope ids:\n- comment:1"
    assert prompt =~ "Address the scoped review_claim_batch items only: comment:1."
  end

  test "implement prompt skips review claims already addressed in prior turns" do
    issue = %Issue{
      id: "issue-review-fix-addressed",
      identifier: "MT-REVIEW-ADDRESSED",
      title: "Continue remaining review comments",
      description: "Move on to the next verified claim."
    }

    state = %{
      review_claims: %{
        "comment:1" => %{
          "disposition" => "accepted",
          "actionable" => false,
          "implementation_status" => "addressed",
          "claim_type" => "correctness_risk",
          "path" => "lib/one.ex",
          "line" => 10,
          "body" => "Already addressed review claim."
        },
        "comment:2" => %{
          "disposition" => "accepted",
          "actionable" => true,
          "claim_type" => "correctness_risk",
          "path" => "lib/two.ex",
          "line" => 20,
          "body" => "Next verified review claim."
        }
      },
      resume_context: %{token_pressure: "high"}
    }

    prompt = SymphonyElixir.DeliveryEngine.implement_prompt_for_test(issue, state, [], 1, 3)

    refute prompt =~ "- comment:1"
    assert prompt =~ "Scope ids:\n- comment:2"
    assert prompt =~ "Address the scoped review_claim_batch items only: comment:2."
  end

  test "implement prompt keeps the last blocking rule in focused review context" do
    issue = %Issue{
      id: "issue-review-fix-rule",
      identifier: "MT-REVIEW-RULE",
      title: "Address review comments after a budget stop",
      description: "Keep only the relevant retry context."
    }

    state = %{
      review_claims: %{
        "comment:1" => %{
          "disposition" => "accepted",
          "actionable" => true,
          "claim_type" => "correctness_risk",
          "path" => "lib/one.ex",
          "line" => 10,
          "body" => "First verified review claim."
        }
      },
      last_rule_id: "budget.per_turn_input_exceeded",
      resume_context: %{token_pressure: "high"}
    }

    prompt = SymphonyElixir.DeliveryEngine.implement_prompt_for_test(issue, state, [], 1, 3)

    assert prompt =~ "Last blocking rule: budget.per_turn_input_exceeded"
    refute prompt =~ "Last implementation summary:"
  end

  test "high-pressure scoped review turns use a tighter command budget" do
    state = %{
      review_claims: %{
        "comment:1" => %{
          "disposition" => "accepted",
          "actionable" => true,
          "claim_type" => "correctness_risk",
          "path" => "lib/one.ex",
          "line" => 10,
          "body" => "First verified review claim."
        }
      },
      resume_context: %{token_pressure: "high"}
    }

    assert SymphonyElixir.DeliveryEngine.implement_command_output_budget_for_test(state) == %{
             stage: "implement",
             per_command_bytes: 4_096,
             per_turn_bytes: 12_288,
             max_command_count: 4
           }
  end

  test "existing workspace changes can advance to validation without a new diff" do
    turn_result = %SymphonyElixir.TurnResult{
      summary: "Existing diff is ready for validation",
      files_touched: [],
      needs_another_turn: false,
      blocked: false,
      blocker_type: :none
    }

    before_snapshot = %SymphonyElixir.RunInspector.Snapshot{
      fingerprint: "same-fingerprint",
      dirty?: false,
      pr_url: nil
    }

    after_snapshot = %SymphonyElixir.RunInspector.Snapshot{
      fingerprint: "different-fingerprint",
      dirty?: true,
      changed_files: 7,
      pr_url: nil
    }

    assert :ok =
             SymphonyElixir.DeliveryEngine.ensure_turn_progress_for_test(
               turn_result,
               before_snapshot,
               after_snapshot
             )

    assert {:ok, "validate"} =
             SymphonyElixir.DeliveryEngine.implement_next_stage_for_test(
               turn_result,
               before_snapshot,
               after_snapshot
             )
  end

  test "implementation command-output budget failures are classified as non-retryable" do
    reason = {:turn_failed, %{"reason" => "implementation.command_output_budget_exceeded", "scope" => "per_turn"}}

    assert SymphonyElixir.DeliveryEngine.implementation_turn_error_summary_for_test(reason) =~
             "command output budget"

    refute SymphonyElixir.DeliveryEngine.retryable_implementation_error_for_test(reason)
    assert SymphonyElixir.DeliveryEngine.non_retryable_implementation_error_for_test(reason)

    assert SymphonyElixir.DeliveryEngine.implementation_error_code_for_test(reason) ==
             :command_output_budget_exceeded
  end

  test "implementation command-count failures are classified as non-retryable" do
    reason = {:turn_failed, %{"reason" => "implementation.command_count_exceeded", "count" => 13}}

    assert SymphonyElixir.DeliveryEngine.implementation_turn_error_summary_for_test(reason) =~
             "too many shell commands"

    refute SymphonyElixir.DeliveryEngine.retryable_implementation_error_for_test(reason)
    assert SymphonyElixir.DeliveryEngine.non_retryable_implementation_error_for_test(reason)

    assert SymphonyElixir.DeliveryEngine.implementation_error_code_for_test(reason) ==
             :command_count_exceeded
  end

  test "implementation broad-read violations are classified as non-retryable" do
    reason = {:turn_failed, %{"reason" => "implementation.broad_read_violation", "command" => "rg --files ."}}

    assert SymphonyElixir.DeliveryEngine.implementation_turn_error_summary_for_test(reason) =~
             "broad repository read"

    refute SymphonyElixir.DeliveryEngine.retryable_implementation_error_for_test(reason)
    assert SymphonyElixir.DeliveryEngine.non_retryable_implementation_error_for_test(reason)

    assert SymphonyElixir.DeliveryEngine.implementation_error_code_for_test(reason) ==
             :broad_read_violation
  end

  test "implementation stage-command violations are classified as non-retryable" do
    reason = {:turn_failed, %{"reason" => "implementation.stage_command_violation", "command" => "xcodebuild test"}}

    assert SymphonyElixir.DeliveryEngine.implementation_turn_error_summary_for_test(reason) =~
             "runtime-owned validation command"

    refute SymphonyElixir.DeliveryEngine.retryable_implementation_error_for_test(reason)
    assert SymphonyElixir.DeliveryEngine.non_retryable_implementation_error_for_test(reason)

    assert SymphonyElixir.DeliveryEngine.implementation_error_code_for_test(reason) ==
             :stage_command_violation
  end

  test "existing workspace changes stay in implement when the agent explicitly needs another turn" do
    turn_result = %SymphonyElixir.TurnResult{
      summary: "Continue refining the existing diff",
      files_touched: [],
      needs_another_turn: true,
      blocked: false,
      blocker_type: :none
    }

    before_snapshot = %SymphonyElixir.RunInspector.Snapshot{
      fingerprint: "same-fingerprint",
      dirty?: true,
      changed_files: 7,
      pr_url: nil
    }

    after_snapshot = %SymphonyElixir.RunInspector.Snapshot{
      fingerprint: "same-fingerprint",
      dirty?: true,
      changed_files: 7,
      pr_url: nil
    }

    assert {:ok, "implement"} =
             SymphonyElixir.DeliveryEngine.implement_next_stage_for_test(
               turn_result,
               before_snapshot,
               after_snapshot
             )
  end

  test "true no-op implement turn still blocks when no diff or pr exists" do
    turn_result = %SymphonyElixir.TurnResult{
      summary: "No-op turn",
      files_touched: [],
      needs_another_turn: false,
      blocked: false,
      blocker_type: :none
    }

    before_snapshot = %SymphonyElixir.RunInspector.Snapshot{
      fingerprint: "same-fingerprint",
      dirty?: false,
      pr_url: nil
    }

    after_snapshot = %SymphonyElixir.RunInspector.Snapshot{
      fingerprint: "same-fingerprint",
      dirty?: false,
      pr_url: nil
    }

    assert {:error, {:noop_turn, "No code change and no PR"}} =
             SymphonyElixir.DeliveryEngine.ensure_turn_progress_for_test(
               turn_result,
               before_snapshot,
               after_snapshot
             )

    assert {:error, {:noop_turn, "No code change and no PR"}} =
             SymphonyElixir.DeliveryEngine.implement_next_stage_for_test(
               turn_result,
               before_snapshot,
               after_snapshot
             )
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.linear_api_token() == env_api_key
    assert Config.linear_project_slug() == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.linear_assignee() == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, -5_000, 1_100)
  end

  test "normal worker exit schedules passive-stage continuation retry with a slower delay" do
    issue_id = "issue-passive"
    identifier = "MT-560"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :PassiveContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-passive-continuation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    workspace = Workspace.path_for_issue(identifier)
    File.mkdir_p!(workspace)

    SymphonyElixir.RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue_id,
      issue_identifier: identifier,
      pr_url: "https://github.com/example/repo/pull/42"
    })

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "Merging"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert_due_in_range(due_at_ms, -5_000, 5_100)
    refute_due_in_range(due_at_ms, -5_000, 1_100)
  end

  test "normal worker exit does not schedule continuation retry for terminal completed stages" do
    issue_id = "issue-terminal"
    identifier = "MT-561"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :TerminalContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-terminal-continuation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    workspace = Workspace.path_for_issue(identifier)
    File.mkdir_p!(workspace)

    SymphonyElixir.RunStateStore.transition(workspace, "done", %{
      issue_id: issue_id,
      issue_identifier: identifier
    })

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "Done"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    refute Map.has_key?(state.retry_attempts, issue_id)
    assert MapSet.member?(state.completed, issue_id)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 36_000, 41_000)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid, 15_000)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid, 15_000)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, -5_000, 10_500)
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp refute_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    refute remaining_ms >= min_remaining_ms and remaining_ms <= max_remaining_ms
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("../../WORKFLOW.md", __DIR__))
    WorkflowStore.force_reload()

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn ->
      Workflow.set_workflow_file_path(workflow_path)
      WorkflowStore.force_reload()
    end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "Ticket `MT-616`."
    assert prompt =~ "Retry attempt #2. Resume from the existing workspace."
    assert prompt =~ "- Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "- Status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "Symphony owns branching, commits, PRs, checks, merges, and tracker state."
    assert prompt =~ "Do not perform those steps yourself."
    assert prompt =~ "End each implementation turn by calling `report_agent_turn_result` exactly once."
    assert prompt =~ "report_agent_turn_result"
    assert prompt =~ "Retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"report_agent_turn_result\",\"arguments\":{\"summary\":\"Workspace retained\",\"files_touched\":[],\"needs_another_turn\":false,\"blocked\":false,\"blocker_type\":\"none\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{template_repo} .",
        codex_command: "#{codex_binary} app-server",
        policy_require_checkout: false,
        policy_require_validation: false,
        policy_stop_on_noop_turn: false
      )

      issue = %Issue{
        id: "issue-s99",
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner accepts an external codex update recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"id\":99,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"report_agent_turn_result\",\"arguments\":{\"summary\":\"Captured updates\",\"files_touched\":[],\"needs_another_turn\":false,\"blocked\":false,\"blocker_type\":\"none\"}}}'
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{template_repo} .",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      recipient =
        spawn(fn ->
          receive do
            _message -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert :ok =
               AgentRunner.run(
                 issue,
                 recipient,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      File.mkdir_p!(Path.join(template_repo, ".symphony"))
      File.mkdir_p!(Path.join(template_repo, "scripts"))

      File.write!(
        Path.join(template_repo, ".symphony/harness.yml"),
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
            - ./scripts/validate.sh
        post_merge:
          command:
            - ./scripts/validate.sh
        artifacts:
          command:
            - ./scripts/preflight.sh
        pull_request:
          required_checks:
            - validate
        """
      )

      File.write!(
        Path.join(template_repo, "scripts/preflight.sh"),
        """
        #!/bin/sh
        exit 0
        """
      )

      File.chmod!(Path.join(template_repo, "scripts/preflight.sh"), 0o755)

      File.write!(
        Path.join(template_repo, "scripts/validate.sh"),
        """
        #!/bin/sh
        count_file=".symphony/validate-count"
        count=0
        if [ -f "$count_file" ]; then
          count="$(cat "$count_file")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        if [ "$count" -eq 1 ]; then
          echo "validation failed"
          exit 1
        fi
        echo "validation passed"
        exit 0
        """
      )

      File.chmod!(Path.join(template_repo, "scripts/validate.sh"), 0o755)
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "."])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      turn_count=0

      while IFS= read -r line; do
        count=$((count + 1))
        if [ "$count" -eq 1 ]; then
          printf '%s\\n' '{"id":1,"result":{}}'
          continue
        fi
        if [ "$count" -eq 3 ]; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
          continue
        fi
        case "$line" in
          *'"method":"turn/start"'*)
            turn_count=$((turn_count + 1))
            if [ "$turn_count" -eq 1 ]; then
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
              printf '%s\\n' '{"id":99,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"First implementation pass","files_touched":[],"needs_another_turn":true,"blocked":false,"blocker_type":"none"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
            else
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
              printf '%s\\n' '{"id":100,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"Second implementation pass","files_touched":[],"needs_another_turn":false,"blocked":false,"blocker_type":"none"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
            fi
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{template_repo} .",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        policy_require_checkout: false,
        policy_require_verifier: false,
        policy_stop_on_noop_turn: false
      )

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      workspace = Path.join(workspace_root, issue.identifier)
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      File.mkdir_p!(Path.join(template_repo, ".symphony"))
      File.mkdir_p!(Path.join(template_repo, "scripts"))

      File.write!(
        Path.join(template_repo, ".symphony/harness.yml"),
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
            - ./scripts/validate.sh
        post_merge:
          command:
            - ./scripts/validate.sh
        artifacts:
          command:
            - ./scripts/preflight.sh
        pull_request:
          required_checks:
            - validate
        """
      )

      File.write!(
        Path.join(template_repo, "scripts/preflight.sh"),
        """
        #!/bin/sh
        exit 0
        """
      )

      File.chmod!(Path.join(template_repo, "scripts/preflight.sh"), 0o755)

      File.write!(
        Path.join(template_repo, "scripts/validate.sh"),
        """
        #!/bin/sh
        echo "validation failed"
        exit 1
        """
      )

      File.chmod!(Path.join(template_repo, "scripts/validate.sh"), 0o755)
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "."])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      turn_count=0

      while IFS= read -r line; do
        count=$((count + 1))
        if [ "$count" -eq 1 ]; then
          printf '%s\\n' '{"id":1,"result":{}}'
          continue
        fi
        if [ "$count" -eq 3 ]; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
          continue
        fi
        case "$line" in
          *'"method":"turn/start"'*)
            turn_count=$((turn_count + 1))
            if [ "$turn_count" -eq 1 ]; then
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
              printf '%s\\n' '{"id":99,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"First implementation pass","files_touched":[],"needs_another_turn":true,"blocked":false,"blocker_type":"none"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
            else
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
              printf '%s\\n' '{"id":100,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"Second implementation pass","files_touched":[],"needs_another_turn":true,"blocked":false,"blocker_type":"none"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
            fi
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{template_repo} .",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2,
        policy_require_checkout: false,
        policy_require_verifier: false,
        policy_stop_on_noop_turn: false
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      workspace = Path.join(workspace_root, issue.identifier)
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "review claim progression retires claims touched with absolute workspace paths" do
    review_claims = %{
      "comment:1" => %{
        "disposition" => "accepted",
        "actionable" => true,
        "claim_type" => "correctness_risk",
        "path" => "elixir/lib/symphony_elixir/observability.ex"
      }
    }

    focused_claims = [{"comment:1", Map.fetch!(review_claims, "comment:1")}]

    turn_result = %SymphonyElixir.TurnResult{
      summary: "Patched observability metadata sanitization.",
      blocked: false,
      needs_another_turn: true,
      blocker_type: "none",
      files_touched: [
        Path.join(
          Config.workspace_root(),
          "CLZ-22/elixir/lib/symphony_elixir/observability.ex"
        )
      ]
    }

    updated_claims =
      SymphonyElixir.DeliveryEngine.advance_review_claims_after_turn_for_test(
        review_claims,
        focused_claims,
        turn_result
      )

    assert %{
             "actionable" => false,
             "implementation_status" => "addressed",
             "addressed_summary" => "Patched observability metadata sanitization."
           } = updated_claims["comment:1"]
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == Path.expand(workspace)
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace)],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == Path.expand(workspace) &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --model gpt-5.3-codex app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--model gpt-5.3-codex app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), Path.join(Path.expand(workspace_root), ".cache")]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), Path.join(Path.expand(workspace_root), ".cache")]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
