defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.Linear.Client

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "config validation rejects invalid dogfood runner harnesses on startup" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dogfood-config-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace_root, ".symphony"))

      File.write!(
        Path.join(workspace_root, ".symphony/harness.yml"),
        """
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
            - validate
        """
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        runner_self_host_project: true
      )

      assert {:error, :missing_harness_version} =
               SymphonyElixir.RepoHarness.validate_runner_checkout(true, workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "config exposes stage-aware token budgets" do
    write_workflow_file!(Workflow.workflow_file_path(),
      policy_per_turn_input_budget: 150_000,
      policy_per_issue_total_budget: 500_000
    )

    assert Config.policy_stage_token_budget("implement")[:per_turn_input_soft] == 60_000
    assert Config.policy_stage_token_budget("implement")[:per_turn_input_hard] == 120_000
    assert Config.policy_stage_token_budget("verify")[:per_turn_input_soft] == 40_000
    assert Config.policy_stage_token_budget("verify")[:per_turn_input_hard] == 80_000
    assert Config.policy_review_fix_token_budget()[:enabled] == true
    assert Config.policy_review_fix_token_budget()[:per_turn_input_soft] == 60_000
    assert Config.policy_review_fix_token_budget()[:per_turn_input_hard] == 120_000
    assert Config.policy_review_fix_token_budget()[:retry_2_per_turn_input_hard] == 150_000
    assert Config.policy_review_fix_token_budget()[:retry_3_per_turn_input_hard] == 220_000
    assert Config.policy_review_fix_token_budget()[:max_turns_in_window] == 3
    assert Config.policy_review_fix_token_budget()[:retry_2_max_turns_in_window] == 5
    assert Config.policy_review_fix_token_budget()[:retry_3_max_turns_in_window] == 7
    assert Config.policy_review_fix_token_budget()[:per_issue_total_extension] == 150_000
    assert Config.policy_review_fix_token_budget()[:auto_retry_limit] == 3
    assert Config.policy_review_fix_token_budget()[:narrow_scope_batch_size] == 1
  end

  test "config exposes normalized runner channel and instance identity" do
    previous_channel = System.get_env("SYMPHONY_RUNNER_CHANNEL")

    on_exit(fn ->
      restore_env("SYMPHONY_RUNNER_CHANNEL", previous_channel)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      runner_instance_name: "dogfood-runner",
      runner_channel: "CANARY"
    )

    assert Config.runner_channel() == "canary"
    assert Config.runner_instance_id() == "canary:dogfood-runner"

    write_workflow_file!(Workflow.workflow_file_path(),
      runner_instance_name: "dogfood-runner",
      runner_channel: "$SYMPHONY_RUNNER_CHANNEL"
    )

    System.put_env("SYMPHONY_RUNNER_CHANNEL", "EXPERIMENTAL")
    assert Config.runner_channel() == "experimental"
    assert Config.runner_instance_id() == "experimental:dogfood-runner"
  end

  test "config exposes default abstract reasoning tiers and codex mappings by stage" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert Config.reasoning_tier_for_stage("implement") == "balanced"
    assert Config.reasoning_tier_for_stage("verify") == "deep"
    assert Config.reasoning_tier_for_stage("verifier") == "rigorous"

    assert Config.codex_turn_effort("implement") == "medium"
    assert Config.codex_turn_effort("verify") == "high"
    assert Config.codex_turn_effort("verifier") == "xhigh"
  end

  test "company mode defaults to the policy pack and can be overridden explicitly" do
    write_workflow_file!(Workflow.workflow_file_path(),
      company_name: "Client Example",
      company_policy_pack: "client_safe"
    )

    assert Config.company_mode() == "client_safe_shadow"
    assert Config.policy_pack_name() == "client_safe"

    write_workflow_file!(Workflow.workflow_file_path(),
      company_name: "Client Example",
      company_mode: "private_autopilot",
      company_policy_pack: "client_safe"
    )

    assert Config.company_mode() == "private_autopilot"
    assert Config.policy_pack_name() == "client_safe"
  end

  test "config allows overriding stage reasoning tiers and provider mappings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_reasoning_stages: %{
        implement: "deep",
        verify: "rigorous",
        verifier: "balanced"
      },
      codex_reasoning_providers: %{
        codex: %{
          reasoning_map: %{
            balanced: "medium",
            deep: "high",
            rigorous: "high"
          }
        }
      }
    )

    assert Config.reasoning_tier_for_stage("implement") == "deep"
    assert Config.reasoning_tier_for_stage("verify") == "rigorous"
    assert Config.reasoning_tier_for_stage("verifier") == "balanced"

    assert Config.codex_turn_effort("implement") == "high"
    assert Config.codex_turn_effort("verify") == "high"
    assert Config.codex_turn_effort("verifier") == "medium"
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      refute File.exists?(Path.join([second_workspace, "tmp", "scratch.txt"]))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reruns after_create for metadata-only bootstrap directories and preserves .symphony state" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-bootstrap-only-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "mkdir -p .git .symphony && echo bootstrapped > README.md && echo version: 1 > .symphony/harness.yml"
      )

      workspace = Path.join(workspace_root, "MT-BOOTSTRAP")
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.write!(Path.join(workspace, ".symphony/run_state.json"), ~s({"stage":"checkout"}))

      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-BOOTSTRAP")
      assert File.dir?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "bootstrapped\n"
      assert File.read!(Path.join(workspace, ".symphony/harness.yml")) == "version: 1\n"
      assert File.read!(Path.join(workspace, ".symphony/run_state.json")) == ~s({"stage":"checkout"})
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reruns after_create for tmp-only bootstrap directories" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-tmp-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "mkdir -p .git && echo bootstrapped > README.md"
      )

      workspace = Path.join(workspace_root, "MT-TMP-BOOTSTRAP")
      File.mkdir_p!(Path.join(workspace, "tmp"))
      File.write!(Path.join(workspace, "tmp/scratch.txt"), "stale\n")

      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-TMP-BOOTSTRAP")
      assert File.dir?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "bootstrapped\n"
      refute File.exists?(Path.join(workspace, "tmp/scratch.txt"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace recreates stale directories that belong to a different runtime instance" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-runtime-reset-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        runner_instance_name: "dogfood-main",
        runner_channel: "canary"
      )

      workspace = Path.join(workspace_root, "MT-RUNTIME-RESET")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "local-progress.txt"), "stale\n")

      :ok =
        RunStateStore.save(workspace, %{
          issue_id: "issue-runtime-reset",
          issue_identifier: "MT-RUNTIME-RESET",
          issue_source: "manual",
          runner_instance_id: "canary:other-runner",
          runner_workspace_root: workspace_root,
          stage: "implement"
        })

      assert {:ok, recreated_workspace} = Workspace.create_for_issue("MT-RUNTIME-RESET")
      assert recreated_workspace == workspace
      refute File.exists?(Path.join(workspace, "local-progress.txt"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == stale_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_symlink_escape, ^symlink_path, ^workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_equals_root, ^workspace_root, ^workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace restores preserved .symphony state when metadata-only bootstrap rerun fails" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-bootstrap-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "mkdir -p .git .symphony && echo nope && exit 17"
      )

      workspace = Path.join(workspace_root, "MT-BOOTSTRAP-FAIL")
      File.mkdir_p!(Path.join(workspace, ".symphony/nested"))
      File.write!(Path.join(workspace, ".symphony/run_state.json"), ~s({"stage":"checkout"}))
      File.write!(Path.join(workspace, ".symphony/nested/evidence.txt"), "preserve me\n")

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-BOOTSTRAP-FAIL")

      assert File.read!(Path.join(workspace, ".symphony/run_state.json")) == ~s({"stage":"checkout"})
      assert File.read!(Path.join(workspace, ".symphony/nested/evidence.txt")) == "preserve me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")

      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client helper seams cover assignee and header fallback branches" do
    previous_token = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      if is_nil(previous_token) do
        System.delete_env("LINEAR_API_KEY")
      else
        System.put_env("LINEAR_API_KEY", previous_token)
      end
    end)

    System.delete_env("LINEAR_API_KEY")

    assert Client.helper_for_test(:build_assignee_filter, ["   "]) == {:ok, nil}
    assert match?({:error, _}, Client.helper_for_test(:build_assignee_filter, ["me"]))
    assert Client.helper_for_test(:assigned_to_worker, [%{}, %{match_values: MapSet.new(["user-1"])}]) == false
    assert Client.helper_for_test(:assigned_to_worker, [nil, :invalid]) == false
    assert Client.helper_for_test(:truncate_error_body, [String.duplicate("a", 1_050)]) =~ "...<truncated>"
    assert Client.helper_for_test(:normalize_assignee_match_value, [nil]) == nil
    assert {:ok, _headers} = Client.helper_for_test(:graphql_headers, [])
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400, %{retry_after_ms: nil, body: %{"errors" => _}}}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      assert Config.workspace_hooks().after_create =~ "echo after_create > after_create.log"
      assert Config.workspace_hooks().before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_runtime_profile_codex_home: nil,
      codex_runtime_profile_inherit_env: nil,
      codex_runtime_profile_env_allowlist: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert Config.linear_endpoint() == "https://api.linear.app/graphql"
    assert Config.linear_api_token() == nil
    assert Config.linear_project_slug() == nil
    assert Config.workspace_root() == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert Config.max_concurrent_agents() == 10
    assert Config.codex_command() == "codex app-server"

    assert Config.codex_approval_policy() == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert Config.codex_thread_sandbox() == "workspace-write"
    assert Config.codex_runtime_profile() == %{codex_home: nil, inherit_env: true, env_allowlist: []}

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Config.codex_turn_timeout_ms() == 3_600_000
    assert Config.codex_read_timeout_ms() == 5_000
    assert Config.codex_stall_timeout_ms() == 300_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server --model gpt-5.3-codex")
    assert Config.codex_command() == "codex app-server --model gpt-5.3-codex"

    codex_home_env_var = "SYMP_CODEX_HOME_#{System.unique_integer([:positive])}"
    previous_codex_home = System.get_env(codex_home_env_var)
    codex_home = Path.join(System.tmp_dir!(), "codex-home-config")
    System.put_env(codex_home_env_var, codex_home)

    on_exit(fn -> restore_env(codex_home_env_var, previous_codex_home) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_runtime_profile_codex_home: "$#{codex_home_env_var}",
      codex_runtime_profile_inherit_env: false,
      codex_runtime_profile_env_allowlist: ["HOME", "PATH", "GH_TOKEN"],
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["/tmp/workspace", "/tmp/cache"]}
    )

    assert Config.codex_runtime_profile() == %{
             codex_home: Path.expand(codex_home),
             inherit_env: false,
             env_allowlist: ["HOME", "PATH", "GH_TOKEN"]
           }

    assert Config.codex_approval_policy() == "on-request"
    assert Config.codex_thread_sandbox() == "workspace-write"

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["/tmp/workspace", "/tmp/cache"]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert Config.linear_active_states() == ["Todo", "In Progress"]

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert Config.max_concurrent_agents() == 10

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert Config.codex_turn_timeout_ms() == 3_600_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert Config.codex_read_timeout_ms() == 5_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert Config.codex_stall_timeout_ms() == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert Config.linear_active_states() == ["Todo", "In Progress"]
    assert Config.linear_terminal_states() == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert Config.poll_interval_ms() == 600_000
    assert Config.healing_poll_interval_ms() == 1_800_000
    assert Config.workspace_root() == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert Config.max_retry_backoff_ms() == 300_000
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("Review") == 10
    assert Config.hook_timeout_ms() == 60_000
    assert Config.observability_enabled?()
    assert Config.observability_refresh_ms() == 1_000
    assert Config.observability_render_interval_ms() == 16
    assert Config.server_port() == nil
    assert Config.server_host() == "123"

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")

    assert Config.codex_approval_policy() == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert {:error, {:invalid_codex_approval_policy, ""}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert Config.codex_thread_sandbox() == "workspace-write"
    assert {:error, {:invalid_codex_thread_sandbox, ""}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:error, {:invalid_codex_turn_sandbox_policy, {:unsupported_value, "bad"}}} =
             Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    assert Config.codex_approval_policy() == "future-policy"
    assert Config.codex_thread_sandbox() == "future-sandbox"

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.codex_command() == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    assert Config.linear_api_token() == api_key
    assert Config.workspace_root() == Path.expand(workspace_root)
    assert Config.codex_command() == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    assert Config.linear_api_token() == "env:#{api_key_env_var}"
    assert Config.workspace_root() == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.max_concurrent_agents() == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end
end
