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

    harness = %RepoHarness{
      smoke_command: "./smoke.sh",
      behavioral_proof: %{
        required: false,
        mode: "unit_first",
        source_paths: ["src"],
        test_paths: ["tests"],
        artifact_path: nil
      }
    }
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
    File.mkdir_p!(Path.join(workspace, "Tests"))
    File.write!(Path.join(workspace, "Tests/VerifierTests.swift"), "final class VerifierTests {}\n")

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
    File.mkdir_p!(Path.join(workspace, "Tests"))
    File.write!(Path.join(workspace, "Tests/VerifierTests.swift"), "final class VerifierTests {}\n")

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

  test "returns needs_more_work when behavioral proof is missing" do
    workspace = git_workspace!("verifier-behavioral-proof-missing")

    issue = %Issue{
      id: "issue-verify-6",
      identifier: "MT-406",
      title: "Verify",
      description: "## Acceptance Criteria\n- persist onboarding state"
    }

    File.mkdir_p!(Path.join(workspace, "LocalEventsExplorer"))
    File.write!(Path.join(workspace, "LocalEventsExplorer/ContentView.swift"), "struct ContentView {}\n")

    File.write!(Path.join(workspace, "smoke.sh"), "#!/usr/bin/env bash\necho smoke passed\nexit 0\n")
    File.chmod!(Path.join(workspace, "smoke.sh"), 0o755)

    harness = %RepoHarness{
      smoke_command: "./smoke.sh",
      behavioral_proof: %{
        required: true,
        mode: "unit_first",
        source_paths: ["LocalEventsExplorer"],
        test_paths: ["LocalEventsExplorerTests"],
        artifact_path: nil
      }
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}

    result = VerifierRunner.verify(workspace, issue, %{}, inspection)

    assert result.verdict == "needs_more_work"
    assert result.reason_code == "behavior_proof_missing"
    assert result.behavioral_proof.required
    refute result.behavioral_proof.satisfied
  end

  test "returns needs_more_work when local ui proof is missing" do
    workspace = git_workspace!("verifier-ui-proof-missing")

    issue = %Issue{
      id: "issue-verify-7",
      identifier: "MT-407",
      title: "Verify UI",
      description: "## Acceptance Criteria\n- update the UI safely"
    }

    File.mkdir_p!(Path.join(workspace, "src/components"))
    File.write!(Path.join(workspace, "src/components/Button.tsx"), "export const Button = () => null;\n")
    System.cmd("git", ["add", "."], cd: workspace)

    File.write!(Path.join(workspace, "smoke.sh"), "#!/usr/bin/env bash\necho smoke passed\nexit 0\n")
    File.chmod!(Path.join(workspace, "smoke.sh"), 0o755)

    harness = %RepoHarness{
      smoke_command: "./smoke.sh",
      behavioral_proof: %{
        required: false,
        mode: "unit_first",
        source_paths: ["server"],
        test_paths: ["server/tests"],
        artifact_path: nil
      },
      ui_proof: %{
        required: true,
        mode: "local",
        source_paths: ["src/components"],
        test_paths: ["tests/ui"],
        artifact_paths: [],
        required_checks: [],
        command: nil,
        provider: nil,
        result_url_pattern: nil,
        scenarios: []
      }
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}

    result = VerifierRunner.verify(workspace, issue, %{}, inspection)

    assert result.verdict == "needs_more_work"
    assert result.reason_code == "ui_proof_missing"
    assert result.ui_proof.required
    assert result.ui_proof.verify_required
    refute result.ui_proof.verify_satisfied
  end

  test "missing verifier tool result blocks verification" do
    workspace = git_workspace!("verifier-missing-result")
    issue = %Issue{id: "issue-verify-5", identifier: "MT-405", title: "Verify", description: "## Acceptance Criteria\n- pass"}

    File.write!(Path.join(workspace, "smoke.sh"), "#!/usr/bin/env bash\necho smoke passed\nexit 0\n")
    File.chmod!(Path.join(workspace, "smoke.sh"), 0o755)
    File.mkdir_p!(Path.join(workspace, "Tests"))
    File.write!(Path.join(workspace, "Tests/VerifierTests.swift"), "final class VerifierTests {}\n")

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

  test "passes full small docs content evidence into verifier context" do
    workspace = git_workspace!("verifier-doc-evidence")

    issue = %Issue{
      id: "issue-verify-8",
      identifier: "MT-408",
      title: "Document app",
      description: "## Acceptance Criteria\n- add a README with overview"
    }

    File.write!(Path.join(workspace, "smoke.sh"), "#!/usr/bin/env bash\necho smoke passed\nexit 0\n")
    File.chmod!(Path.join(workspace, "smoke.sh"), 0o755)
    System.cmd("git", ["add", "smoke.sh"], cd: workspace)
    System.cmd("git", ["commit", "-m", "add smoke"], cd: workspace)

    File.write!(
      Path.join(workspace, "README.md"),
      """
      # Local Events Explorer

      Overview text.

      ## Local Development

      - `./scripts/symphony-preflight.sh`
      - `./scripts/symphony-validate.sh`
      - `./scripts/symphony-smoke.sh`
      """
    )
    System.cmd("git", ["add", "README.md"], cd: workspace)

    harness = %RepoHarness{smoke_command: "./smoke.sh"}
    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}

    verifier_runner = fn _workspace, _issue, _state, opts ->
      context = Keyword.fetch!(opts, :verification_context)
      [entry] = context.content_evidence
      assert entry.path == "README.md"
      assert entry.excerpt =~ "Local Events Explorer"
      assert entry.excerpt =~ "## Local Development"
      assert entry.excerpt =~ "./scripts/symphony-preflight.sh"

      {:ok,
       %VerifierResult{
         verdict: :pass,
         summary: "Docs look good",
         acceptance_gaps: [],
         risky_areas: [],
         evidence: ["README content reviewed"],
         raw_output: "pass"
       }}
    end

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: verifier_runner
      )

    assert result.verdict == "pass"
  end

  test "format_command_output_excerpt keeps both head and success tail for long output" do
    output =
      Enum.join([
        String.duplicate("build log line\n", 220),
        "** TEST SUCCEEDED **\n",
        "12 tests passed\n"
      ])

    excerpt = VerifierRunner.format_command_output_excerpt(output)

    assert excerpt =~ "build log line"
    assert excerpt =~ "** TEST SUCCEEDED **"
    assert excerpt =~ "12 tests passed"
    assert excerpt =~ "\n...\n"
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
