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

  test "disabled behavioral proof still runs the verifier and preserves its rejection for source changes" do
    workspace = git_workspace!("verifier-disabled-proof-source")
    on_exit(fn -> File.rm_rf!(workspace) end)
    File.mkdir_p!(Path.join(workspace, "lib"))
    source_path = Path.join(workspace, "lib/feature.ex")
    source = "defmodule Feature do\n  def enabled?, do: true\nend\n"
    File.write!(source_path, source)

    issue = %Issue{id: "disabled-proof-source", identifier: "PROOF-01", title: "Review source", description: "## Acceptance Criteria\n- review the behavior"}

    harness = %RepoHarness{
      smoke_command: "true",
      behavioral_proof: %{required: false, mode: "unit_first", source_paths: ["lib"], test_paths: ["test"], artifact_path: nil}
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}
    caller = self()
    verifier_ref = make_ref()

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        include_pr_details: false,
        verifier_session_runner: fn _workspace, _issue, _state, opts ->
          send(caller, {verifier_ref, :verifier_called})
          context = Keyword.fetch!(opts, :verification_context)
          assert context.smoke_result.status == :passed
          refute context.behavioral_proof.required?
          assert context.behavioral_proof.satisfied?
          assert context.behavioral_proof.behavior_paths == ["lib/feature.ex"]
          assert context.behavioral_proof.proof_paths == []
          refute context.behavioral_proof.artifact_present?

          {:ok,
           %VerifierResult{
             verdict: :unsafe_to_merge,
             summary: "The behavior is unsafe",
             acceptance_gaps: [],
             risky_areas: ["Unvalidated behavior"],
             evidence: ["Reviewed the source change"],
             raw_output: "unsafe"
           }}
        end
      )

    assert_receive {^verifier_ref, :verifier_called}
    refute_receive {^verifier_ref, :verifier_called}
    assert result.verdict == "unsafe_to_merge"
    assert result.summary == "The behavior is unsafe"
    assert result.smoke.status == :passed
    refute result.behavioral_proof.required
    assert result.behavioral_proof.behavior_paths == ["lib/feature.ex"]
    assert File.read!(source_path) == source
  end

  test "disabled behavioral proof preserves smoke failure for source changes without invoking the verifier" do
    workspace = git_workspace!("verifier-disabled-proof-smoke-failure")
    on_exit(fn -> File.rm_rf!(workspace) end)
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/feature.ex"), "defmodule Feature do\nend\n")

    issue = %Issue{id: "disabled-proof-smoke", identifier: "PROOF-02", title: "Review source", description: "## Acceptance Criteria\n- smoke must pass"}

    harness = %RepoHarness{
      smoke_command: "exit 1",
      behavioral_proof: %{required: false, mode: "unit_first", source_paths: ["lib"], test_paths: ["test"], artifact_path: nil}
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        include_pr_details: false,
        verifier_session_runner: fn _workspace, _issue, _state, _opts ->
          flunk("The verifier must not run after a failed smoke command")
        end
      )

    assert result.verdict == "needs_more_work"
    assert result.summary =~ "smoke verification command failed"
    assert result.smoke.status == :failed
    refute result.behavioral_proof.required
    assert result.behavioral_proof.behavior_paths == ["lib/feature.ex"]
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
      VerifierRunner.verify(workspace, issue, %{}, inspection, verifier_session_runner: verifier_runner)

    assert result.verdict == "pass"
  end

  test "includes changed harness sources and new tests before docs, with redacted content" do
    workspace = git_workspace!("verifier-python-evidence")
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.mkdir_p!(Path.join(workspace, "test"))
    File.write!(Path.join(workspace, "lib/labels.py"), "def normalize_label(value):\n    return value\n")
    {_, 0} = System.cmd("git", ["add", "lib/labels.py"], cd: workspace)
    {_, 0} = System.cmd("git", ["commit", "-m", "initial source"], cd: workspace)

    File.write!(
      Path.join(workspace, "lib/labels.py"),
      "def normalize_label(value):\n    return ' '.join(value.split()).casefold()\npassword = 'fixture-secret-value'\n"
    )

    File.write!(Path.join(workspace, "test/test_edge.py"), "assert normalize_label(' A ') == 'a'\n# fixture-secret-value\n")
    Enum.each(1..5, &File.write!(Path.join(workspace, "doc#{&1}.md"), "Documentation #{&1}\n"))

    harness = %RepoHarness{
      smoke_command: "true",
      behavioral_proof: %{required: true, mode: "unit_first", source_paths: ["lib"], test_paths: ["test"]}
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}
    issue = %Issue{id: "python-evidence", identifier: "MT-409", title: "Normalize labels", description: "## Acceptance Criteria\n- normalize labels"}

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: fn _workspace, _issue, _state, opts ->
          context = Keyword.fetch!(opts, :verification_context)
          assert context.behavioral_proof.satisfied?
          assert length(context.content_evidence) == 4
          [source, test | _docs] = context.content_evidence
          assert source.path == "lib/labels.py"
          assert source.excerpt =~ "join(value.split()).casefold()"
          assert source.excerpt =~ "[REDACTED]"
          refute source.excerpt =~ "fixture-secret-value"
          assert test.path == "test/test_edge.py"
          assert test.excerpt =~ "assert normalize_label(' A ') == 'a'"
          assert test.excerpt =~ "[REDACTED]"
          refute test.excerpt =~ "fixture-secret-value"
          {:error, :missing_verifier_result}
        end
      )

    assert result.verdict == "blocked"
  end

  test "omits binary, invalid text and symlink source content without following links" do
    workspace = git_workspace!("verifier-unsafe-evidence")
    outside = git_workspace!("verifier-outside-evidence")
    File.write!(Path.join(outside, "private.txt"), "outside-private-marker\n")
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.mkdir_p!(Path.join(workspace, "test"))
    File.write!(Path.join(workspace, "lib/00_binary.bin"), <<0, 1, 2>>)
    File.write!(Path.join(workspace, "lib/01_invalid.py"), <<255>>)
    File.ln_s!(Path.join(outside, "private.txt"), Path.join(workspace, "lib/02_escape.py"))
    File.write!(Path.join(workspace, "test/test_edge.py"), "assert True\n")

    harness = %RepoHarness{
      smoke_command: "true",
      behavioral_proof: %{required: true, mode: "unit_first", source_paths: ["lib"], test_paths: ["test"]}
    }

    inspection = %RunInspector.Snapshot{workspace: workspace, harness: harness}
    issue = %Issue{id: "unsafe-evidence", identifier: "MT-410", title: "Review safely", description: "## Acceptance Criteria\n- review local changes"}

    result =
      VerifierRunner.verify(workspace, issue, %{}, inspection,
        verifier_session_runner: fn _workspace, _issue, _state, opts ->
          entries = Keyword.fetch!(opts, :verification_context).content_evidence
          by_path = Map.new(entries, &{&1.path, &1.excerpt})
          assert by_path["lib/00_binary.bin"] =~ "Content omitted: binary"
          assert by_path["lib/01_invalid.py"] =~ "Content omitted: binary"
          assert by_path["lib/02_escape.py"] =~ "Content omitted: :symlink_path"
          assert by_path["test/test_edge.py"] == "assert True"
          refute inspect(entries) =~ "outside-private-marker"
          {:error, :missing_verifier_result}
        end
      )

    assert result.verdict == "blocked"
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

  for {provider_name, provider, stream} <- [
        {"claude", SymphonyElixir.AgentProvider.Claude, ~s({"type":"result","result":"Checked","usage":{"input_tokens":2,"output_tokens":1}})},
        {"codex-cli", SymphonyElixir.AgentProvider.CodexCLI, ~s({"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":1}})}
      ] do
    @provider_name provider_name
    @provider provider
    @stream stream

    test "P3-B1-04 #{@provider_name}: real verifier transport cannot prepare delivery", do: verify_cli_read_only(@provider_name, @provider, @stream)
  end

  test "P3-B1-05: real AppServer verifier report does not permit transport mutation" do
    workspace = git_workspace!("b1-verifier-mutating")
    bin = workspace <> "-bin"
    File.mkdir_p!(bin)

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(bin)
    end)

    binary = Path.join(bin, "fake-verifier")

    File.write!(binary, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        *'"id":2'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"b1-verifier"}}}' ;;
        *'"method":"turn/start"'*)
          printf changed > README.md
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"b1-turn"}}}'
          printf '%s\n' '{"id":104,"method":"item/tool/call","params":{"tool":"report_verifier_result","callId":"b1-call","threadId":"b1-verifier","turnId":"b1-turn","arguments":{"verdict":"pass","summary":"Reviewed","acceptance_gaps":[],"risky_areas":[],"evidence":["Read source"],"raw_output":"pass"}}}'
          printf '%s\n' '{"method":"turn/completed"}' ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.dirname(workspace), codex_command: binary)
    issue = %Issue{id: "b1-mutating", identifier: "B1-MUTATING", title: "Verify", description: "Verify source"}
    result = VerifierRunner.verify(workspace, issue, %{}, verifier_inspection(workspace), include_pr_details: false)
    assert result.verdict == "blocked"
    assert result.risky_areas == [":verifier_mutated_workspace"]
    assert File.read!(Path.join(workspace, "README.md")) == "changed"
    refute Enum.any?(Process.get(), fn {key, _} -> key == {:symphony_verifier_result, issue.id} end)
  end

  defp verify_cli_read_only(provider_name, provider, stream) do
    workspace = git_workspace!("b1-verifier-#{provider_name}")
    bin = workspace <> "-bin"
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(workspace, "elixir"))
    File.mkdir_p!(Path.join(workspace, ".symphony/progress"))
    progress = Path.join(workspace, ".symphony/progress/verifier.md")
    File.write!(progress, "## Work Log\n\n## Evidence\n\n")
    File.write!(Path.join(workspace, "README.md"), "pending changes\n")
    binary_name = if provider_name == "claude", do: "claude", else: "codex"
    File.write!(Path.join(bin, binary_name), "#!/bin/sh\nprintf '%s\\n' '#{stream}'\n")
    File.chmod!(Path.join(bin, binary_name), 0o755)
    File.write!(Path.join(bin, "mix"), "#!/bin/sh\nprintf forbidden > ../runtime-prepared\nexit 0\n")
    File.chmod!(Path.join(bin, "mix"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(bin)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.dirname(workspace))
    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "agent:\n", "agent:\n  provider: #{provider_name}\n"))
    WorkflowStore.force_reload()
    issue = %Issue{id: "b1-cli-#{provider_name}", identifier: "B1-CLI", title: "Verify", description: "Verify existing source"}
    System.cmd("git", ["status", "--porcelain"], cd: workspace)
    before = verifier_bytes(workspace, progress)
    caller = self()

    result =
      count_session_stops(provider, fn ->
        VerifierRunner.verify(workspace, issue, %{}, verifier_inspection(workspace), include_pr_details: false, on_message: fn event -> send(caller, {:cli_verifier_event, event}) end)
      end)

    assert result.verdict == "blocked"
    assert result.summary =~ "without reporting `report_verifier_result`"
    assert verifier_bytes(workspace, progress) == before
    refute File.exists?(Path.join(workspace, "runtime-prepared"))
    assert_receive {:cli_verifier_event, %{event: :turn_completed, usage: %{input_tokens: 2, output_tokens: 1}}}
    refute_receive {:cli_verifier_event, %{event: :turn_completed}}
    refute Enum.any?(Process.get(), fn {key, _} -> key in [{:symphony_verifier_result, issue.id}, {:symphony_turn_result, issue.id}] end)
  end

  defp verifier_inspection(workspace) do
    %RunInspector.Snapshot{
      workspace: workspace,
      harness: %RepoHarness{smoke_command: "true", behavioral_proof: %{required: false, mode: "unit_first", source_paths: [], test_paths: [], artifact_path: nil}, ui_proof: %{required: false}}
    }
  end

  defp verifier_bytes(workspace, progress) do
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    %{head: head, index: File.read!(Path.join(workspace, ".git/index")), progress: File.read!(progress), source: File.read!(Path.join(workspace, "README.md"))}
  end

  defp count_session_stops(provider, fun) do
    Code.ensure_loaded!(provider)
    owner = self()
    tracer = spawn(fn -> relay_stop_calls(owner) end)
    :erlang.trace_pattern({provider, :stop_session, 1}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^ref}
      send(tracer, {:flush, self()})
      assert_receive {:stop_count, 1}
      result
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({provider, :stop_session, 1}, false, [])
      send(tracer, :stop)
    end
  end

  defp relay_stop_calls(owner, count \\ 0) do
    receive do
      {:trace, ^owner, :call, {_provider, :stop_session, [_session]}} ->
        relay_stop_calls(owner, count + 1)

      {:flush, ^owner} ->
        send(owner, {:stop_count, count})
        relay_stop_calls(owner, count)

      :stop ->
        :ok
    end
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
