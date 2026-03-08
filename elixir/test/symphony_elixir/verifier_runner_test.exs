defmodule SymphonyElixir.VerifierRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.VerifierResult
  alias SymphonyElixir.VerifierRunner

  test "maps smoke failure to needs_more_work" do
    workspace = git_workspace!("verifier-smoke-failure")
    issue = %Issue{id: "issue-verify-1", identifier: "MT-401", title: "Verify", description: "## Acceptance Criteria\n- ship it"}

    File.write!(Path.join(workspace, "smoke.sh"), "#!/usr/bin/env bash\necho smoke failed\nexit 1\n")
    File.chmod!(Path.join(workspace, "smoke.sh"), 0o755)
    File.write!(Path.join(workspace, "README.md"), "changed\n")

    harness = %RepoHarness{smoke_command: "./smoke.sh"}
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}

    result = VerifierRunner.verify(workspace, issue, %{}, inspection)

    assert result.verdict == "needs_more_work"
    assert result.summary =~ "smoke verification command failed"
  end

  test "maps smoke unavailable to blocked" do
    workspace = git_workspace!("verifier-smoke-unavailable")
    issue = %Issue{id: "issue-verify-2", identifier: "MT-402", title: "Verify", description: "No harness"}
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: %RepoHarness{smoke_command: nil}}

    result = VerifierRunner.verify(workspace, issue, %{}, inspection)

    assert result.verdict == "blocked"
    assert result.summary =~ "smoke command is unavailable"
  end

  test "maps model verifier pass to pass" do
    workspace = git_workspace!("verifier-pass")
    issue = %Issue{id: "issue-verify-3", identifier: "MT-403", title: "Verify", description: "## Acceptance Criteria\n- pass"}

    File.write!(Path.join(workspace, "smoke.sh"), "#!/usr/bin/env bash\necho smoke passed\nexit 0\n")
    File.chmod!(Path.join(workspace, "smoke.sh"), 0o755)
    File.write!(Path.join(workspace, "README.md"), "changed\n")

    harness = %RepoHarness{smoke_command: "./smoke.sh"}
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: fn _workspace, _issue, _state, _opts ->
          {:ok,
           %VerifierResult{
             verdict: :pass,
             summary: "Looks good",
             acceptance_gaps: [],
             risky_areas: [],
             evidence: ["Smoke passed"],
             raw_output: "pass"
           }}
        end
      )

    assert result.verdict == "pass"
    assert result.summary == "Looks good"
  end

  test "maps model verifier unsafe results to unsafe_to_merge" do
    workspace = git_workspace!("verifier-unsafe")
    issue = %Issue{id: "issue-verify-4", identifier: "MT-404", title: "Verify", description: "## Acceptance Criteria\n- pass"}

    File.write!(Path.join(workspace, "smoke.sh"), "#!/usr/bin/env bash\necho smoke passed\nexit 0\n")
    File.chmod!(Path.join(workspace, "smoke.sh"), 0o755)
    File.write!(Path.join(workspace, "README.md"), "changed\n")

    harness = %RepoHarness{smoke_command: "./smoke.sh"}
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: fn _workspace, _issue, _state, _opts ->
          {:ok,
           %VerifierResult{
             verdict: :unsafe_to_merge,
             summary: "Risky change",
             acceptance_gaps: [],
             risky_areas: ["Data loss"],
             evidence: [],
             raw_output: "unsafe"
           }}
        end
      )

    assert result.verdict == "unsafe_to_merge"
    assert result.summary == "Risky change"
  end

  test "missing verifier tool result blocks verification" do
    workspace = git_workspace!("verifier-missing-result")
    issue = %Issue{id: "issue-verify-5", identifier: "MT-405", title: "Verify", description: "## Acceptance Criteria\n- pass"}

    File.write!(Path.join(workspace, "smoke.sh"), "#!/usr/bin/env bash\necho smoke passed\nexit 0\n")
    File.chmod!(Path.join(workspace, "smoke.sh"), 0o755)
    File.write!(Path.join(workspace, "README.md"), "changed\n")

    harness = %RepoHarness{smoke_command: "./smoke.sh"}
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: fn _workspace, _issue, _state, _opts ->
          {:error, :missing_verifier_result}
        end
      )

    assert result.verdict == "blocked"
    assert result.summary =~ "without reporting"
  end

  defp git_workspace!(suffix) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    System.cmd("git", ["add", "README.md"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)
    workspace
  end
end
