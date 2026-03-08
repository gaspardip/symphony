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
end
