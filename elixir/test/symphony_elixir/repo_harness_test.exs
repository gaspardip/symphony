defmodule SymphonyElixir.RepoHarnessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepoHarness

  test "loads a strict core harness with optional metadata" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repo-harness-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        Path.join(workspace, ".symphony/harness.yml"),
        """
        version: 1
        base_branch: main
        preflight:
          description: Bootstrap tools
          command:
            - ./scripts/preflight.sh
          outputs:
            format: text
          success:
            exit_code: 0
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
        agent_harness:
          scope: self_host_only
          initializer:
            enabled: true
            max_turns: 1
            refresh: missing
          knowledge:
            root: .symphony/knowledge
            required_files:
              - product.md
          progress:
            root: .symphony/progress
            pattern: "{{ issue.identifier }}.md"
            required_sections:
              - Goal
              - Acceptance
          features:
            root: .symphony/features
            format: yaml
            required_fields:
              - id
              - title
              - status
              - summary
              - source_paths
              - acceptance_signals
              - dependencies
              - last_updated_by_issue
          publish_gate:
            require_progress: true
            require_feature_update_on_code_change: true
        verification:
          behavioral_proof:
            required: true
            mode: unit_first
            source_paths:
              - Sources
            test_paths:
              - Tests
            artifact_path: .symphony/proof.json
          ui_proof:
            required: true
            mode: hybrid
            source_paths:
              - Sources/UI
            test_paths:
              - UITests
            artifact_paths:
              - artifacts/ui/*.png
            required_checks:
              - chromatic
            command:
              - ./scripts/ui-proof.sh
            provider: chromatic
            result_url_pattern: https://example.test?pr={pr_url}
            scenarios:
              - Button/default
        project:
          type: ios-app
          xcodeproj: LocalEventsExplorer.xcodeproj
          scheme: LocalEventsExplorer
        runtime:
          simulator_destination: platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2
        ci:
          provider: github-actions
          workflow: .github/workflows/ci.yml
          env:
            FOO: bar
          required_checks:
            - validate
        pull_request:
          required_checks:
            - validate
          template: .github/PULL_REQUEST_TEMPLATE.md
          review_ready:
            all:
              - checkbox: Review ready
          merge_safe:
            all:
              - github_check: validate
        """
      )

      assert {:ok, harness} = RepoHarness.load(workspace)
      assert harness.version == 1
      assert harness.base_branch == "main"
      assert harness.preflight_command == "./scripts/preflight.sh"
      assert harness.validation_command == "./scripts/validate.sh"
      assert harness.smoke_command == "./scripts/smoke.sh"
      assert harness.post_merge_command == "./scripts/post-merge.sh"
      assert harness.artifacts_command == "./scripts/artifacts.sh"
      assert harness.agent_harness.scope == "self_host_only"
      assert harness.agent_harness.initializer.enabled == true
      assert harness.agent_harness.features.format == "yaml"
      assert harness.behavioral_proof.mode == "unit_first"
      assert harness.behavioral_proof.source_paths == ["Sources"]
      assert harness.behavioral_proof.test_paths == ["Tests"]
      assert harness.behavioral_proof.artifact_path == ".symphony/proof.json"
      assert harness.ui_proof.mode == "hybrid"
      assert harness.ui_proof.source_paths == ["Sources/UI"]
      assert harness.ui_proof.test_paths == ["UITests"]
      assert harness.ui_proof.artifact_paths == ["artifacts/ui/*.png"]
      assert harness.ui_proof.required_checks == ["chromatic"]
      assert harness.ui_proof.command == "./scripts/ui-proof.sh"
      assert harness.ui_proof.provider == "chromatic"
      assert harness.publish_required_checks == ["validate"]
      assert harness.ci_required_checks == ["validate"]
      assert harness.pull_request.template == ".github/PULL_REQUEST_TEMPLATE.md"
    after
      File.rm_rf(workspace)
    end
  end

  test "accepts the checked-in symphony harness" do
    repo_root = Path.expand("../../..", __DIR__)

    assert {:ok, harness} = RepoHarness.load(repo_root)
    assert harness.version == 1
    assert harness.publish_required_checks == ["make-all", "pr-description-lint"]
    assert harness.agent_harness.scope == "self_host_only"
    assert ".symphony/knowledge" == harness.agent_harness.knowledge.root
  end

  test "rejects missing version" do
    assert {:error, :missing_harness_version} =
             RepoHarness.validate(%{
               "base_branch" => "main",
               "preflight" => %{"command" => ["./scripts/preflight.sh"]},
               "validation" => %{"command" => ["./scripts/validate.sh"]},
               "smoke" => %{"command" => ["./scripts/smoke.sh"]},
               "post_merge" => %{"command" => ["./scripts/post-merge.sh"]},
               "artifacts" => %{"command" => ["./scripts/artifacts.sh"]},
               "pull_request" => %{"required_checks" => ["validate"]}
             })
  end

  test "rejects missing required commands" do
    assert {:error, {:missing_harness_command, "smoke"}} =
             RepoHarness.validate(%{
               "version" => 1,
               "base_branch" => "main",
               "preflight" => %{"command" => ["./scripts/preflight.sh"]},
               "validation" => %{"command" => ["./scripts/validate.sh"]},
               "smoke" => %{},
               "post_merge" => %{"command" => ["./scripts/post-merge.sh"]},
               "artifacts" => %{"command" => ["./scripts/artifacts.sh"]},
               "pull_request" => %{"required_checks" => ["validate"]}
             })
  end

  test "rejects missing required checks" do
    assert {:error, :missing_required_checks} =
             RepoHarness.validate(%{
               "version" => 1,
               "base_branch" => "main",
               "preflight" => %{"command" => ["./scripts/preflight.sh"]},
               "validation" => %{"command" => ["./scripts/validate.sh"]},
               "smoke" => %{"command" => ["./scripts/smoke.sh"]},
               "post_merge" => %{"command" => ["./scripts/post-merge.sh"]},
               "artifacts" => %{"command" => ["./scripts/artifacts.sh"]},
               "pull_request" => %{}
             })
  end

  test "rejects unknown keys" do
    assert {:error, {:unknown_harness_keys, [], ["mystery"]}} =
             RepoHarness.validate(%{
               "version" => 1,
               "base_branch" => "main",
               "mystery" => true,
               "preflight" => %{"command" => ["./scripts/preflight.sh"]},
               "validation" => %{"command" => ["./scripts/validate.sh"]},
               "smoke" => %{"command" => ["./scripts/smoke.sh"]},
               "post_merge" => %{"command" => ["./scripts/post-merge.sh"]},
               "artifacts" => %{"command" => ["./scripts/artifacts.sh"]},
               "pull_request" => %{"required_checks" => ["validate"]}
             })
  end

  test "rejects unknown behavioral proof keys" do
    assert {:error, {:unknown_harness_keys, ["verification", "behavioral_proof"], ["mystery"]}} =
             RepoHarness.validate(%{
               "version" => 1,
               "base_branch" => "main",
               "preflight" => %{"command" => ["./scripts/preflight.sh"]},
               "validation" => %{"command" => ["./scripts/validate.sh"]},
               "smoke" => %{"command" => ["./scripts/smoke.sh"]},
               "post_merge" => %{"command" => ["./scripts/post-merge.sh"]},
               "artifacts" => %{"command" => ["./scripts/artifacts.sh"]},
               "verification" => %{
                 "behavioral_proof" => %{
                   "required" => true,
                   "mode" => "unit_first",
                   "source_paths" => ["Sources"],
                   "test_paths" => ["Tests"],
                   "mystery" => true
                 }
               },
               "pull_request" => %{"required_checks" => ["validate"]}
             })
  end

  test "rejects unknown ui proof keys" do
    assert {:error, {:unknown_harness_keys, ["verification", "ui_proof"], ["mystery"]}} =
             RepoHarness.validate(%{
               "version" => 1,
               "base_branch" => "main",
               "preflight" => %{"command" => ["./scripts/preflight.sh"]},
               "validation" => %{"command" => ["./scripts/validate.sh"]},
               "smoke" => %{"command" => ["./scripts/smoke.sh"]},
               "post_merge" => %{"command" => ["./scripts/post-merge.sh"]},
               "artifacts" => %{"command" => ["./scripts/artifacts.sh"]},
               "verification" => %{
                 "ui_proof" => %{
                   "required" => true,
                   "mode" => "local",
                   "source_paths" => ["Sources/UI"],
                   "test_paths" => ["UITests"],
                   "mystery" => true
                 }
               },
               "pull_request" => %{"required_checks" => ["validate"]}
             })
  end
end
