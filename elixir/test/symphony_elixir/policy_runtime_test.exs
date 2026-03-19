defmodule SymphonyElixir.PolicyRuntimeTest do
  use SymphonyElixir.TestSupport

  test "repo harness loads preflight, validation, smoke, post-merge, and required checks" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-harness-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
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
        ci:
          required_checks:
            - ci / validate
            - ci / ui-tests
        pull_request:
          required_checks:
            - ci / validate
            - ci / ui-tests
        """
      )

      assert {:ok, harness} = RepoHarness.load(workspace)
      assert harness.preflight_command == "./scripts/preflight.sh"
      assert harness.validation_command == "./scripts/validate.sh"
      assert harness.smoke_command == "./scripts/smoke.sh"
      assert harness.post_merge_command == "./scripts/post-merge.sh"
      assert harness.required_checks == ["ci / validate", "ci / ui-tests"]
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy blocks issues with no checkout" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{id: "issue-missing-checkout", identifier: "MT-301", state: "Todo"}

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-checkout-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)

      assert {:stop, %RunPolicy.Violation{code: :missing_checkout}} =
               RunPolicy.enforce_pre_run(issue, workspace)

      assert_receive {:memory_tracker_comment, "issue-missing-checkout", body}
      assert body =~ "Rule ID: checkout.missing_git"
      assert body =~ "Failure class: environment"
      assert body =~ "Unblock action:"
      assert_receive {:memory_tracker_state_update, "issue-missing-checkout", "Blocked"}
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy moves todo issues to in progress after checkout succeeds" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{id: "issue-promote", identifier: "MT-302", state: "Todo"}

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-promote-#{System.unique_integer([:positive])}"
      )

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.mkdir_p!(Path.join(workspace, "scripts"))

      File.write!(
        Path.join(workspace, "scripts/preflight.sh"),
        "#!/usr/bin/env bash\nexit 0\n"
      )

      File.chmod!(Path.join(workspace, "scripts/preflight.sh"), 0o755)

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
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
              - lib
            test_paths:
              - test
        pull_request:
          required_checks:
            - validate
        """
      )

      assert :ok = RunPolicy.enforce_pre_run(issue, workspace)
      assert_receive {:memory_tracker_state_update, "issue-promote", "In Progress"}
      refute_receive {:memory_tracker_state_update, "issue-promote", "Blocked"}
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy blocks issues outside the active workload filter" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_policy_pack: "client_safe",
      policy_packs: %{
        client_safe: %{
          default_issue_class: "review_required",
          allowed_policy_classes: ["review_required", "never_automerge"],
          required_any_issue_labels: ["scope:maintenance"]
        }
      }
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{
      id: "issue-workload-blocked",
      identifier: "MT-WL-01",
      state: "Todo",
      labels: ["symphony:events"]
    }

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workload-blocked-#{System.unique_integer([:positive])}"
      )

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.mkdir_p!(Path.join(workspace, "scripts"))

      File.write!(Path.join(workspace, "scripts/preflight.sh"), "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(Path.join(workspace, "scripts/preflight.sh"), 0o755)

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
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
              - lib
            test_paths:
              - test
        pull_request:
          required_checks:
            - validate
        """
      )

      assert {:stop, %RunPolicy.Violation{code: :policy_workload_restricted, rule_id: "policy.workload_restricted"}} =
               RunPolicy.enforce_pre_run(issue, workspace)

      refute_receive {:memory_tracker_comment, "issue-workload-blocked", _body}
      refute_receive {:memory_tracker_state_update, "issue-workload-blocked", "Blocked"}
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy allows issues that match the active workload filter" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_policy_pack: "client_safe",
      policy_packs: %{
        client_safe: %{
          default_issue_class: "review_required",
          allowed_policy_classes: ["review_required", "never_automerge"],
          required_any_issue_labels: ["scope:maintenance"]
        }
      }
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{
      id: "issue-workload-allowed",
      identifier: "MT-WL-02",
      state: "Todo",
      labels: ["symphony:events", "scope:maintenance"]
    }

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workload-allowed-#{System.unique_integer([:positive])}"
      )

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.mkdir_p!(Path.join(workspace, "scripts"))

      File.write!(Path.join(workspace, "scripts/preflight.sh"), "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(Path.join(workspace, "scripts/preflight.sh"), 0o755)

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
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
              - lib
            test_paths:
              - test
        pull_request:
          required_checks:
            - validate
        """
      )

      assert :ok = RunPolicy.enforce_pre_run(issue, workspace)
      refute_receive {:memory_tracker_state_update, "issue-workload-allowed", "In Progress"}
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy blocks issues when the company policy pack is frozen" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_policy_pack: "client_safe",
      policy_packs: %{
        client_safe: %{
          company_frozen: true
        }
      }
    )

    issue = %Issue{id: "issue-company-frozen", identifier: "MT-CF-01", state: "Todo"}

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-company-frozen-#{System.unique_integer([:positive])}"
      )

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.mkdir_p!(Path.join(workspace, "scripts"))

      File.write!(Path.join(workspace, "scripts/preflight.sh"), "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(Path.join(workspace, "scripts/preflight.sh"), 0o755)

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
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
              - lib
            test_paths:
              - test
        pull_request:
          required_checks:
            - validate
        """
      )

      assert {:stop, %RunPolicy.Violation{code: :company_frozen, rule_id: "policy.company_frozen"}} =
               RunPolicy.enforce_pre_run(issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy blocks a checkout outside the configured company repo boundary" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_policy_pack: "client_safe",
      company_name: "Client Boundary",
      company_repo_url: "git@github.com:gaspardip/events.git"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{
      id: "issue-repo-boundary",
      identifier: "MT-BND-01",
      state: "Todo",
      labels: ["symphony:events"]
    }

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repo-boundary-#{System.unique_integer([:positive])}"
      )

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.mkdir_p!(Path.join(workspace, "scripts"))

      File.write!(Path.join(workspace, "scripts/preflight.sh"), "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(Path.join(workspace, "scripts/preflight.sh"), 0o755)

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
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
              - lib
            test_paths:
              - test
        pull_request:
          required_checks:
            - validate
        """
      )

      System.cmd("git", ["-C", workspace, "remote", "add", "origin", "git@github.com:someone-else/other.git"])

      assert {:stop, %RunPolicy.Violation{code: :repo_boundary_mismatch, rule_id: "checkout.repo_boundary_mismatch"}} =
               RunPolicy.enforce_pre_run(issue, workspace)

      refute_receive {:memory_tracker_comment, "issue-repo-boundary", _body}
      refute_receive {:memory_tracker_state_update, "issue-repo-boundary", "Blocked"}
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy blocks issues with no harness when validation is required" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{id: "issue-missing-harness", identifier: "MT-302A", state: "Todo"}

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-harness-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".git"))

      assert {:stop, %RunPolicy.Violation{code: :missing_harness}} =
               RunPolicy.enforce_pre_run(issue, workspace)

      assert_receive {:memory_tracker_comment, "issue-missing-harness", body}
      assert body =~ "Rule ID: harness.missing"
      assert body =~ "Failure class: environment"
      assert body =~ "Unblock action:"
      assert_receive {:memory_tracker_state_update, "issue-missing-harness", "Blocked"}
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy blocks invalid harnesses with a typed reason" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{id: "issue-invalid-harness", identifier: "MT-302B", state: "Todo"}

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-invalid-harness-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".git"))
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
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

      assert {:stop, %RunPolicy.Violation{code: :missing_harness_version}} =
               RunPolicy.enforce_pre_run(issue, workspace)

      assert_receive {:memory_tracker_comment, "issue-invalid-harness", body}
      assert body =~ "Rule ID: harness.missing_version"
      assert body =~ "Failure class: environment"
      assert body =~ "Unblock action:"
      assert_receive {:memory_tracker_state_update, "issue-invalid-harness", "Blocked"}
    after
      File.rm_rf(workspace)
    end
  end

  test "pre-run policy blocks workspaces that overlap the protected runner install" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-root-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      runner_install_root: runner_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{id: "issue-runner-overlap", identifier: "MT-302B", state: "Todo"}
    workspace = Path.join(runner_root, "workspaces/MT-302B")

    try do
      File.mkdir_p!(Path.join(workspace, ".git"))

      assert {:stop, %RunPolicy.Violation{code: :runner_overlap}} =
               RunPolicy.enforce_pre_run(issue, workspace)

      assert_receive {:memory_tracker_comment, "issue-runner-overlap", body}
      assert body =~ "runner_overlap"
      assert_receive {:memory_tracker_state_update, "issue-runner-overlap", "Blocked"}
    after
      File.rm_rf(runner_root)
    end
  end

  test "pre-run policy accepts equivalent https and ssh GitHub remotes for the same repo" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_policy_pack: "client_safe",
      company_name: "Client Boundary",
      company_repo_url: "https://github.com/gaspardip/events"
    )

    issue = %Issue{
      id: "issue-repo-boundary-equivalent",
      identifier: "MT-BND-SSH-HTTPS",
      state: "Todo",
      labels: ["symphony:events"]
    }

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repo-boundary-equivalent-#{System.unique_integer([:positive])}"
      )

    try do
      init_git_workspace!(workspace)
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.mkdir_p!(Path.join(workspace, "scripts"))

      File.write!(Path.join(workspace, "scripts/preflight.sh"), "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(Path.join(workspace, "scripts/preflight.sh"), 0o755)

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
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
              - lib
            test_paths:
              - test
        pull_request:
          required_checks:
            - validate
        """
      )

      System.cmd(
        "git",
        ["-C", workspace, "remote", "add", "origin", "git@github.com:gaspardip/events.git"]
      )

      assert :ok = RunPolicy.enforce_pre_run(issue, workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "label-gated dispatch only accepts issues with required labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"]
    )

    eligible_issue = %Issue{
      id: "issue-eligible",
      identifier: "MT-302C",
      title: "Eligible",
      state: "Todo",
      labels: ["dogfood:symphony"]
    }

    skipped_issue = %Issue{
      id: "issue-skipped",
      identifier: "MT-302D",
      title: "Skipped",
      state: "Todo",
      labels: ["ops"]
    }

    assert Orchestrator.should_dispatch_issue_for_test(eligible_issue, %Orchestrator.State{})
    refute Orchestrator.should_dispatch_issue_for_test(skipped_issue, %Orchestrator.State{})
  end

  test "canary-active runner requires canary labels in addition to dogfood labels" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-canary-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(runner_root)

      File.write!(
        Path.join(runner_root, "metadata.json"),
        Jason.encode!(%{
          "runner_mode" => "canary_active",
          "canary_required_labels" => ["canary:symphony"]
        })
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_required_labels: ["dogfood:symphony"],
        runner_install_root: runner_root,
        runner_channel: "canary"
      )

      dogfood_issue = %Issue{
        id: "issue-dogfood-only",
        identifier: "MT-302E",
        title: "Dogfood only",
        state: "Todo",
        labels: ["dogfood:symphony"]
      }

      canary_issue = %Issue{
        id: "issue-canary",
        identifier: "MT-302F",
        title: "Canary eligible",
        state: "Todo",
        labels: ["dogfood:symphony", "canary:symphony"]
      }

      refute Orchestrator.should_dispatch_issue_for_test(dogfood_issue, %Orchestrator.State{})
      assert Orchestrator.should_dispatch_issue_for_test(canary_issue, %Orchestrator.State{})

      File.write!(
        Path.join(runner_root, "metadata.json"),
        Jason.encode!(%{
          "runner_mode" => "stable",
          "canary_required_labels" => ["canary:symphony"]
        })
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_required_labels: ["dogfood:symphony"],
        runner_install_root: runner_root,
        runner_channel: "stable"
      )

      assert Orchestrator.should_dispatch_issue_for_test(dogfood_issue, %Orchestrator.State{})
    after
      File.rm_rf(runner_root)
    end
  end

  test "stable runner skips canary-targeted issues and records the channel mismatch" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"],
      runner_channel: "stable"
    )

    issue = %Issue{
      id: "issue-canary-routed",
      identifier: "MT-302F2",
      title: "Canary targeted",
      state: "Todo",
      labels: ["dogfood:symphony", "canary:symphony"]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, %Orchestrator.State{})
    assert Orchestrator.issue_target_runner_channel_for_test(issue) == "canary"

    {eligible, skipped} =
      Orchestrator.partition_issues_by_label_gate_for_test([issue], %Orchestrator.State{})

    assert eligible == []

    assert [
             %{
               issue_id: "issue-canary-routed",
               reason: "wrong runner channel",
               runner_channel: "stable",
               target_runner_channel: "canary"
             }
           ] = skipped
  end

  test "canary runner only dispatches canary-targeted issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"],
      runner_channel: "canary"
    )

    stable_issue = %Issue{
      id: "issue-stable-routed",
      identifier: "MT-302F3",
      title: "Stable targeted",
      state: "Todo",
      labels: ["dogfood:symphony"]
    }

    canary_issue = %Issue{
      id: "issue-canary-routed-2",
      identifier: "MT-302F4",
      title: "Canary targeted",
      state: "Todo",
      labels: ["dogfood:symphony", "canary:symphony"]
    }

    refute Orchestrator.should_dispatch_issue_for_test(stable_issue, %Orchestrator.State{})
    assert Orchestrator.should_dispatch_issue_for_test(canary_issue, %Orchestrator.State{})
    assert Orchestrator.issue_target_runner_channel_for_test(stable_issue) == "stable"
    assert Orchestrator.issue_target_runner_channel_for_test(canary_issue) == "canary"
  end

  test "seeded manual replay keeps canary channel routing on synthesized issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"],
      runner_channel: "canary"
    )

    run_state = %{
      issue_source: :manual,
      effective_policy_class: "fully_autonomous",
      issue_id: "manual:CLZ-22",
      issue_identifier: "CLZ-22",
      issue_state: "In Progress",
      runner_channel: "canary",
      branch: "codex/clz-22-local-canary"
    }

    issue = Orchestrator.seeded_manual_issue_from_run_state_for_test(run_state)

    assert %Issue{labels: labels, branch_name: "codex/clz-22-local-canary"} = issue
    assert "canary:symphony" in labels
    assert Orchestrator.issue_target_runner_channel_for_test(issue) == "canary"
  end

  test "canary runner channel honors custom promoted canary labels" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-canary-custom-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(runner_root)

      File.write!(
        Path.join(runner_root, "metadata.json"),
        Jason.encode!(%{
          "runner_mode" => "canary_active",
          "canary_required_labels" => ["canary:mainproof"]
        })
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_required_labels: ["dogfood:symphony"],
        runner_install_root: runner_root,
        runner_channel: "canary"
      )

      stable_issue = %Issue{
        id: "issue-stable-custom-routed",
        identifier: "MT-302F4A",
        title: "Stable targeted",
        state: "Todo",
        labels: ["dogfood:symphony"]
      }

      canary_issue = %Issue{
        id: "issue-canary-custom-routed",
        identifier: "MT-302F4B",
        title: "Canary targeted",
        state: "Todo",
        labels: ["dogfood:symphony", "canary:mainproof"]
      }

      refute Orchestrator.should_dispatch_issue_for_test(stable_issue, %Orchestrator.State{})
      assert Orchestrator.should_dispatch_issue_for_test(canary_issue, %Orchestrator.State{})
      assert Orchestrator.issue_target_runner_channel_for_test(stable_issue) == "stable"
      assert Orchestrator.issue_target_runner_channel_for_test(canary_issue) == "canary"
    after
      File.rm_rf(runner_root)
    end
  end

  test "seeded manual replay reflects blocked run state so retry can resume it" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    run_state = %{
      issue_source: :manual,
      effective_policy_class: "fully_autonomous",
      issue_id: "manual:CLZ-22",
      issue_identifier: "CLZ-22",
      issue_state: "In Progress",
      stage: "blocked",
      branch: "codex/clz-22-local-canary"
    }

    issue = Orchestrator.seeded_manual_issue_from_run_state_for_test(run_state)

    assert %Issue{state: "Blocked", branch_name: "codex/clz-22-local-canary"} = issue
  end

  test "after-turn policy blocks human review without a PR" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{id: "issue-no-pr", identifier: "MT-303", state: "In Progress"}
    refreshed_issue = %Issue{id: "issue-no-pr", identifier: "MT-303", state: "Human Review"}

    before_snapshot = %RunInspector.Snapshot{workspace: "/tmp", fingerprint: 10, pr_url: nil}
    after_snapshot = %RunInspector.Snapshot{workspace: "/tmp", fingerprint: 10, pr_url: nil}

    assert {:stop, %RunPolicy.Violation{code: :publish_missing_pr}} =
             RunPolicy.evaluate_after_turn(issue, refreshed_issue, before_snapshot, after_snapshot, 0)

    assert_receive {:memory_tracker_comment, "issue-no-pr", body}
    assert body =~ "Rule ID: publish.missing_pr"
    assert body =~ "Failure class: publish"
    assert body =~ "Unblock action:"
    assert_receive {:memory_tracker_state_update, "issue-no-pr", "Blocked"}
  end

  test "after-turn policy blocks failed validation when validation is required" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue = %Issue{id: "issue-validation", identifier: "MT-304", state: "In Progress"}
    refreshed_issue = %Issue{id: "issue-validation", identifier: "MT-304", state: "In Progress"}
    harness = %RepoHarness{validation_command: "./scripts/validate.sh"}

    before_snapshot = %RunInspector.Snapshot{workspace: "/tmp", fingerprint: 10, pr_url: nil}

    after_snapshot = %RunInspector.Snapshot{
      workspace: "/tmp",
      fingerprint: 11,
      pr_url: nil,
      harness: harness
    }

    assert {:stop, %RunPolicy.Violation{code: :validation_failed}} =
             RunPolicy.evaluate_after_turn(
               issue,
               refreshed_issue,
               before_snapshot,
               after_snapshot,
               0,
               shell_runner: fn _workspace, _command, _opts -> {"validation failed", 1} end
             )

    assert_receive {:memory_tracker_comment, "issue-validation", body}
    assert body =~ "Rule ID: validation.failed"
    assert body =~ "Failure class: validation"
    assert body =~ "Unblock action:"
    assert_receive {:memory_tracker_state_update, "issue-validation", "Blocked"}
  end

  test "orchestrator stops active issues when token budget is exceeded" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      policy_token_budget: %{
        per_turn_input: 5,
        per_issue_total: 50,
        per_issue_total_output: nil
      }
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue_id = "issue-token-budget"
    issue = %Issue{id: issue_id, identifier: "MT-305", state: "In Progress"}
    orchestrator_name = Module.concat(__MODULE__, :BudgetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    assert :ok = SymphonyElixir.LeaseManager.acquire(issue_id, issue.identifier, "budget-owner")

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-turn",
      turn_count: 1,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_started_input_tokens: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      |> Map.put(:lease_owner, "budget-owner")
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"inputTokens" => 10, "outputTokens" => 1, "totalTokens" => 11}
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    Process.sleep(100)
    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)
    assert {:error, :missing} = SymphonyElixir.LeaseManager.read(issue_id)
    assert_receive {:memory_tracker_comment, "issue-token-budget", body}
    assert body =~ "Rule ID: budget.per_turn_input_exceeded"
    assert body =~ "Failure class: budget"
    assert body =~ "Unblock action:"
    assert_receive {:memory_tracker_state_update, "issue-token-budget", "Blocked"}
  end

  defp init_git_workspace!(workspace, branch \\ "main") do
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-b", branch], cd: workspace, stderr_to_stdout: true)
    File.write!(Path.join(workspace, ".gitkeep"), "ok\n")
    System.cmd("git", ["add", ".gitkeep"], cd: workspace, stderr_to_stdout: true)

    System.cmd(
      "git",
      ["-c", "user.name=Symphony Test", "-c", "user.email=symphony@example.com", "commit", "-m", "init"],
      cd: workspace,
      stderr_to_stdout: true
    )
  end
end
