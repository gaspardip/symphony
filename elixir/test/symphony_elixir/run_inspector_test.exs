defmodule SymphonyElixir.RunInspectorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RunInspector

  test "required checks rollup classifies missing, pending, failed, and cancelled checks" do
    harness = %RepoHarness{required_checks: ["ci / validate", "ci / ui-tests", "ci / smoke", "ci / docs"]}

    snapshot = %RunInspector.Snapshot{
      pr_url: "https://example.com/pr/1",
      pr_state: "OPEN",
      review_decision: "APPROVED",
      harness: harness,
      check_statuses: [
        %{name: "ci / validate", status: "COMPLETED", conclusion: "SUCCESS"},
        %{name: "ci / ui-tests", status: "IN_PROGRESS", conclusion: nil},
        %{name: "ci / smoke", status: "COMPLETED", conclusion: "FAILURE"},
        %{name: "ci / docs", status: "COMPLETED", conclusion: "CANCELLED"}
      ]
    }

    rollup = RunInspector.required_checks_rollup(snapshot)

    assert rollup.state == :failed
    assert rollup.required == ["ci / validate", "ci / ui-tests", "ci / smoke", "ci / docs"]
    assert rollup.pending == ["ci / ui-tests"]
    assert rollup.failed == ["ci / smoke"]
    assert rollup.cancelled == ["ci / docs"]
    assert rollup.missing == []
    refute RunInspector.required_checks_passed?(snapshot)
    refute RunInspector.ready_for_merge?(snapshot)
  end

  test "required checks rollup treats absent required checks as missing" do
    snapshot = %RunInspector.Snapshot{
      pr_url: "https://example.com/pr/2",
      pr_state: "OPEN",
      review_decision: "APPROVED",
      harness: %RepoHarness{required_checks: ["ci / validate"]},
      check_statuses: []
    }

    rollup = RunInspector.required_checks_rollup(snapshot)

    assert rollup.state == :missing
    assert rollup.missing == ["ci / validate"]
    refute RunInspector.required_checks_passed?(snapshot)
  end

  test "required checks rollup matches GitHub workflow names when the check-run name differs" do
    snapshot = %RunInspector.Snapshot{
      pr_url: "https://example.com/pr/4",
      pr_state: "OPEN",
      review_decision: "APPROVED",
      harness: %RepoHarness{required_checks: ["pr-description-lint"]},
      check_statuses: [
        %{
          name: "validate-pr-description",
          workflow_name: "pr-description-lint",
          status: "COMPLETED",
          conclusion: "SUCCESS"
        }
      ]
    }

    rollup = RunInspector.required_checks_rollup(snapshot)

    assert rollup.state == :passed
    assert rollup.missing == []
    assert RunInspector.required_checks_passed?(snapshot)
  end

  test "run_harness_command injects workspace-local runtime env into shell commands" do
    workspace = Path.join(System.tmp_dir!(), "inspector-runtime-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    # Shell runner that captures the env passed via opts
    capture_runner = fn _workspace, _command, opts ->
      env = Keyword.get(opts, :env, [])
      env_str = Enum.map_join(env, "\n", fn {k, v} -> "#{k}=#{v}" end)
      {env_str, 0}
    end

    harness = %RepoHarness{preflight_command: "echo preflight"}

    result = RunInspector.run_preflight(workspace, harness, shell_runner: capture_runner)

    assert result.status == :passed
    assert result.output =~ "MIX_HOME="
    assert result.output =~ "HEX_HOME="
    assert result.output =~ "MIX_ARCHIVES="
    assert result.output =~ ".symphony/runtime/mix_home"
    assert result.output =~ ".symphony/runtime/hex_home"
    assert result.output =~ ".symphony/runtime/mix_archives"

    # Verify the runtime dirs were created
    runtime_home = Path.join(workspace, ".symphony/runtime")
    assert File.dir?(Path.join(runtime_home, "mix_home"))
    assert File.dir?(Path.join(runtime_home, "hex_home"))
    assert File.dir?(Path.join(runtime_home, "mix_archives"))
  end

  test "ready_for_merge requires an open pull request even when checks and reviews pass" do
    harness = %RepoHarness{required_checks: ["ci / validate"]}

    merged_snapshot = %RunInspector.Snapshot{
      pr_url: "https://example.com/pr/3",
      pr_state: "MERGED",
      review_decision: "APPROVED",
      harness: harness,
      check_statuses: [%{name: "ci / validate", status: "COMPLETED", conclusion: "SUCCESS"}]
    }

    closed_snapshot = %{merged_snapshot | pr_state: "CLOSED"}
    open_snapshot = %{merged_snapshot | pr_state: "OPEN"}

    refute RunInspector.ready_for_merge?(merged_snapshot)
    refute RunInspector.ready_for_merge?(closed_snapshot)
    assert RunInspector.ready_for_merge?(open_snapshot)
  end
end
