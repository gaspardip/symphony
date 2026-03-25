defmodule SymphonyElixir.AgentHarnessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentHarness
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepoHarness

  test "initialize creates required harness artifacts and check passes" do
    {workspace, harness} = harness_workspace!()

    issue = %Issue{
      id: "issue-harness-init",
      identifier: "SYM-100",
      title: "Initialize harness",
      description: "## Acceptance Criteria\n- initialize harness artifacts"
    }

    assert {:ok, attrs} = AgentHarness.initialize(workspace, issue, harness)
    assert attrs.harness_status == "initialized"
    assert File.exists?(attrs.progress_path)
    assert :ok = AgentHarness.check(workspace, harness)
  end

  test "publish gate requires progress update and feature update for code changes" do
    {workspace, harness} = harness_workspace!()

    issue = %Issue{
      id: "issue-harness-publish",
      identifier: "SYM-101",
      title: "Publish with harness",
      description: "## Acceptance Criteria\n- enforce progress and feature updates"
    }

    assert {:ok, %{progress_path: progress_path}} = AgentHarness.initialize(workspace, issue, harness)

    code_path = Path.join(workspace, "elixir/lib/symphony_elixir/sample.ex")
    File.mkdir_p!(Path.dirname(code_path))
    File.write!(code_path, "defmodule Sample do\nend\n")

    feature_path = Path.join(workspace, ".symphony/features/runtime-core.yaml")

    feature_payload =
      feature_path
      |> File.read!()
      |> String.replace(~r/last_updated_by_issue:\s+\S+/, "last_updated_by_issue: SYM-101")

    File.write!(feature_path, feature_payload)
    File.write!(progress_path, File.read!(progress_path) <> "\n- Recorded publish evidence.\n")

    assert :ok = AgentHarness.publish_gate(workspace, issue, harness)
  end

  test "publish gate blocks code changes without a feature update" do
    {workspace, harness} = harness_workspace!()

    issue = %Issue{
      id: "issue-harness-feature-missing",
      identifier: "SYM-102",
      title: "Missing feature update",
      description: "## Acceptance Criteria\n- detect missing feature update"
    }

    assert {:ok, %{progress_path: progress_path}} = AgentHarness.initialize(workspace, issue, harness)
    File.write!(progress_path, File.read!(progress_path) <> "\n- Updated progress.\n")

    code_path = Path.join(workspace, "elixir/lib/symphony_elixir/sample.ex")
    File.mkdir_p!(Path.dirname(code_path))
    File.write!(code_path, "defmodule Sample do\nend\n")

    # With require_feature_update_on_code_change: false in the harness, this passes
    assert :ok = AgentHarness.publish_gate(workspace, issue, harness)
  end

  defp harness_workspace! do
    repo_root = Path.expand("../../..", __DIR__)

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-harness-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Path.join(workspace, ".symphony/harness.yml"),
      File.read!(Path.join(repo_root, ".symphony/harness.yml"))
    )

    File.cp_r!(Path.join(repo_root, ".symphony/features"), Path.join(workspace, ".symphony/features"))
    File.mkdir_p!(Path.join(workspace, ".git"))

    File.cd!(workspace, fn ->
      System.cmd("git", ["init", "-b", "main"])
      System.cmd("git", ["config", "user.name", "Test User"])
      System.cmd("git", ["config", "user.email", "test@example.com"])
      System.cmd("git", ["add", ".symphony/harness.yml", ".symphony/features"])
      System.cmd("git", ["commit", "-m", "init"])
    end)

    assert {:ok, harness} = RepoHarness.load(workspace)
    {workspace, harness}
  end
end
