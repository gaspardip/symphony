defmodule SymphonyElixir.RunnerRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, RunnerRuntime}

  test "runner runtime exposes health provenance manifest and canary evidence" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-runtime-#{System.unique_integer([:positive])}"
      )

    release_path = Path.join(runner_root, "releases/promoted123")
    manifest_path = Path.join(release_path, "manifest.json")

    try do
      File.mkdir_p!(release_path)

      File.write!(
        manifest_path,
        Jason.encode!(%{
          "commit_sha" => "promoted123",
          "promoted_ref" => "main",
          "repo_url" => "git@github.com:gaspardip/symphony.git"
        })
      )

      File.write!(
        RunnerRuntime.metadata_path(runner_root),
        Jason.encode!(%{
          "current_version_sha" => "promoted123",
          "promoted_release_sha" => "promoted123",
          "promoted_ref" => "main",
          "promoted_release_path" => release_path,
          "previous_release_sha" => "previous456",
          "previous_release_path" => Path.join(runner_root, "releases/previous456"),
          "runner_mode" => "canary_active",
          "canary_required_labels" => ["canary:symphony"],
          "canary_started_at" => "2026-03-06T02:00:00Z",
          "rollback_recommended" => true,
          "repo_url" => "git@github.com:gaspardip/symphony.git",
          "release_manifest_path" => manifest_path,
          "build_tool_versions" => %{"git" => %{"version" => "git version 2.50.1"}},
          "preflight_completed_at" => "2026-03-06T01:55:00Z",
          "smoke_completed_at" => "2026-03-06T01:58:00Z",
          "promotion_host" => "dogfood-host",
          "promotion_user" => "gaspar",
          "canary_evidence" => %{
            "issues" => ["CLZ-10"],
            "prs" => ["https://github.com/gaspardip/symphony/pull/10"]
          }
        })
      )

      File.ln_s!(release_path, Path.join(runner_root, "current"))

      File.write!(
        RunnerRuntime.history_path(runner_root),
        Jason.encode!(%{
          "event_type" => "runner.promoted",
          "summary" => "Promoted canary runner.",
          "at" => "2026-03-06T02:00:00Z"
        }) <> "\n"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        runner_install_root: runner_root,
        runner_instance_name: "dogfood-runner",
        runner_channel: "canary",
        tracker_required_labels: ["dogfood:symphony"]
      )

      info = RunnerRuntime.info()

      assert info.instance_id == "canary:dogfood-runner"
      assert info.instance_name == "dogfood-runner"
      assert info.channel == "canary"
      assert info.install_root == runner_root
      assert info.workspace_root == Config.workspace_root()
      assert info.current_link_target == release_path
      assert info.promoted_release_sha == "promoted123"
      assert info.previous_release_sha == "previous456"
      assert info.runner_mode == "canary_active"
      assert info.runner_health == "healthy"
      assert info.runner_health_rule_id == nil
      assert info.dispatch_enabled == true
      assert info.canary_required_labels == ["canary:symphony"]
      assert info.effective_required_labels == ["dogfood:symphony", "canary:symphony"]
      assert info.canary_evidence == %{issues: ["CLZ-10"], prs: ["https://github.com/gaspardip/symphony/pull/10"]}
      assert info.release_manifest_path == manifest_path
      assert info.release_manifest["commit_sha"] == "promoted123"
      assert info.repo_url == "git@github.com:gaspardip/symphony.git"
      assert info.promotion_host == "dogfood-host"
      assert info.promotion_user == "gaspar"
      assert info.rollback_target_exists == false
      assert info.rule_id == "runner.canary_active"
      assert info.rollback_rule_id == "runner.rollback_recommended"
      assert is_binary(info.runtime_version)
      assert [%{"event_type" => "runner.promoted"}] = info.history

      assert RunnerRuntime.effective_required_labels(
               ["dogfood:symphony"],
               %{"runner_mode" => "stable", "canary_required_labels" => ["canary:symphony"]}
             ) == ["dogfood:symphony"]
    after
      File.rm_rf(runner_root)
    end
  end

  test "runner health returns not_required when dogfood label gating is disabled" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-runtime-not-required-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(runner_root)
      health = RunnerRuntime.runner_health(["ops-only"], runner_root)
      assert health.status == "not_required"
      assert health.dispatch_enabled == true
      assert health.rule_id == nil
    after
      File.rm_rf(runner_root)
    end
  end

  test "runner health rejects missing metadata current mismatches and missing releases" do
    base_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-runtime-invalid-#{System.unique_integer([:positive])}"
      )

    missing_root = Path.join(base_root, "missing")
    mismatch_root = Path.join(base_root, "mismatch")
    release_missing_root = Path.join(base_root, "release-missing")

    try do
      assert RunnerRuntime.runner_health(["dogfood:symphony"], missing_root).rule_id ==
               "runner.install_missing"

      File.mkdir_p!(mismatch_root)
      mismatch_release = Path.join(mismatch_root, "releases/current-a")
      File.mkdir_p!(mismatch_release)
      File.ln_s!(mismatch_release, Path.join(mismatch_root, "current"))

      File.write!(
        RunnerRuntime.metadata_path(mismatch_root),
        Jason.encode!(%{
          "promoted_release_sha" => "current-b",
          "promoted_release_path" => Path.join(mismatch_root, "releases/current-b"),
          "runner_mode" => "stable"
        })
      )

      mismatch_health = RunnerRuntime.runner_health(["dogfood:symphony"], mismatch_root)
      assert mismatch_health.status == "invalid"
      assert mismatch_health.rule_id == "runner.release_missing"
      assert mismatch_health.dispatch_enabled == false

      File.mkdir_p!(release_missing_root)

      File.write!(
        RunnerRuntime.metadata_path(release_missing_root),
        Jason.encode!(%{
          "promoted_release_sha" => "missing-release",
          "promoted_release_path" => Path.join(release_missing_root, "releases/missing-release"),
          "runner_mode" => "stable"
        })
      )

      release_missing_health = RunnerRuntime.runner_health(["dogfood:symphony"], release_missing_root)
      assert release_missing_health.rule_id == "runner.current_missing"
    after
      File.rm_rf(base_root)
    end
  end

  test "runner health detects metadata and current mismatches once both targets exist" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-runtime-mismatch-#{System.unique_integer([:positive])}"
      )

    current_release = Path.join(runner_root, "releases/current-a")
    metadata_release = Path.join(runner_root, "releases/current-b")

    try do
      File.mkdir_p!(current_release)
      File.mkdir_p!(metadata_release)
      File.ln_s!(current_release, Path.join(runner_root, "current"))

      File.write!(
        RunnerRuntime.metadata_path(runner_root),
        Jason.encode!(%{
          "promoted_release_sha" => "current-b",
          "promoted_release_path" => metadata_release,
          "runner_mode" => "stable"
        })
      )

      health = RunnerRuntime.runner_health(["dogfood:symphony"], runner_root)
      assert health.status == "invalid"
      assert health.rule_id == "runner.current_mismatch"
      assert health.dispatch_enabled == false
    after
      File.rm_rf(runner_root)
    end
  end

  test "runner health rejects invalid metadata payloads and invalid runner modes" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-runtime-invalid-metadata-#{System.unique_integer([:positive])}"
      )

    invalid_json_root = Path.join(runner_root, "invalid-json")
    invalid_mode_root = Path.join(runner_root, "invalid-mode")

    try do
      File.mkdir_p!(invalid_json_root)
      File.write!(RunnerRuntime.metadata_path(invalid_json_root), "{invalid")

      invalid_json_health = RunnerRuntime.runner_health(["dogfood:symphony"], invalid_json_root)
      assert invalid_json_health.status == "invalid"
      assert invalid_json_health.rule_id == "runner.metadata_invalid"
      assert invalid_json_health.dispatch_enabled == false

      release_path = Path.join(invalid_mode_root, "releases/promoted123")
      File.mkdir_p!(release_path)
      File.ln_s!(release_path, Path.join(invalid_mode_root, "current"))

      File.write!(
        RunnerRuntime.metadata_path(invalid_mode_root),
        Jason.encode!(%{
          "promoted_release_sha" => "promoted123",
          "promoted_release_path" => release_path,
          "runner_mode" => "drifted"
        })
      )

      invalid_mode_health = RunnerRuntime.runner_health(["dogfood:symphony"], invalid_mode_root)
      assert invalid_mode_health.status == "invalid"
      assert invalid_mode_health.rule_id == "runner.metadata_invalid"
      assert invalid_mode_health.dispatch_enabled == false
    after
      File.rm_rf(runner_root)
    end
  end

  test "runner runtime tolerates invalid manifest payloads and derives rollback target from previous sha" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-runtime-manifest-#{System.unique_integer([:positive])}"
      )

    release_path = Path.join(runner_root, "releases/promoted123")
    manifest_path = Path.join(release_path, "manifest.json")

    try do
      File.mkdir_p!(release_path)
      File.write!(manifest_path, "{invalid")
      File.ln_s!(release_path, Path.join(runner_root, "current"))

      File.write!(
        RunnerRuntime.metadata_path(runner_root),
        Jason.encode!(%{
          "promoted_release_sha" => "promoted123",
          "promoted_release_path" => release_path,
          "previous_release_sha" => "previous456",
          "runner_mode" => "stable",
          "canary_required_labels" => []
        })
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        runner_install_root: runner_root,
        tracker_required_labels: ["dogfood:symphony"]
      )

      info = RunnerRuntime.info()

      assert info.runner_health == "healthy"
      assert info.release_manifest_path == manifest_path
      assert info.release_manifest == nil
      assert info.canary_required_labels == ["canary:symphony"]
      assert info.effective_required_labels == ["dogfood:symphony"]

      assert info.rollback_target_path ==
               Path.join([runner_root, "releases", "previous456"])

      assert info.rollback_target_exists == false
    after
      File.rm_rf(runner_root)
    end
  end

  test "recent history ignores malformed rows and non-positive limits" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-runtime-history-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(runner_root)

      File.write!(
        RunnerRuntime.history_path(runner_root),
        [
          "{\"event_type\":\"runner.promoted\",\"summary\":\"ok\"}\n",
          "not-json\n",
          "{\"event_type\":\"runner.rollback.completed\",\"summary\":\"rolled back\"}\n"
        ]
      )

      assert RunnerRuntime.recent_history(runner_root, 1) == [
               %{"event_type" => "runner.rollback.completed", "summary" => "rolled back"}
             ]

      assert RunnerRuntime.recent_history(runner_root, 0) == []
    after
      File.rm_rf(runner_root)
    end
  end

  test "runner control wrappers expose command templates and execute the promotion script" do
    previous_cmd_fun = Application.get_env(:symphony_elixir, :runner_runtime_cmd_fun)

    Application.put_env(
      :symphony_elixir,
      :runner_runtime_cmd_fun,
      fn command, args, opts ->
        send(self(), {:runner_runtime_cmd, command, args, opts})
        {"runner command ok\n", 0}
      end
    )

    on_exit(fn ->
      if is_nil(previous_cmd_fun) do
        Application.delete_env(:symphony_elixir, :runner_runtime_cmd_fun)
      else
        Application.put_env(:symphony_elixir, :runner_runtime_cmd_fun, previous_cmd_fun)
      end
    end)

    commands = RunnerRuntime.commands()
    assert commands.inspect =~ "inspect"
    assert commands.promote =~ "promote <git-ref>"
    assert commands.record_canary =~ "record-canary <pass|fail>"
    assert commands.rollback =~ "rollback [release-sha]"

    assert {:ok, promote_payload} =
             RunnerRuntime.promote("main", canary_labels: ["canary:symphony"])

    assert promote_payload.ok == true
    assert promote_payload.action == "promote"
    assert promote_payload.output == "runner command ok"
    assert promote_payload.command =~ "promote"
    assert_receive {:runner_runtime_cmd, "bash", [script_path, "promote", "main", "--canary-label", "canary:symphony"], options}
    assert script_path == RunnerRuntime.promotion_script_path()
    assert options[:stderr_to_stdout] == true

    assert {:ok, canary_payload} =
             RunnerRuntime.record_canary("pass",
               issues: ["CLZ-22"],
               prs: ["https://github.com/gaspardip/symphony/pull/1"],
               note: "healthy"
             )

    assert canary_payload.action == "record_canary"
    assert_receive {:runner_runtime_cmd, "bash", [_script_path, "record-canary", "pass", "--issue", "CLZ-22", "--pr", "https://github.com/gaspardip/symphony/pull/1", "--note", "healthy"], _options}

    assert {:ok, rollback_payload} = RunnerRuntime.rollback("deadbeef")
    assert rollback_payload.action == "rollback"
    assert_receive {:runner_runtime_cmd, "bash", [_script_path, "rollback", "deadbeef"], _options}

    assert {:error, invalid_payload} = RunnerRuntime.record_canary("unknown")
    assert invalid_payload.error == "invalid_result"
  end

  test "runner control wrappers expose rollback default path and command failures" do
    previous_cmd_fun = Application.get_env(:symphony_elixir, :runner_runtime_cmd_fun)

    Application.put_env(
      :symphony_elixir,
      :runner_runtime_cmd_fun,
      fn command, args, opts ->
        send(self(), {:runner_runtime_cmd, command, args, opts})

        case args do
          [_script_path, "rollback"] ->
            {"rollback ok\n", 0}

          [_script_path, "record-canary", "fail"] ->
            {"runner failed\n", 7}

          _ ->
            {"unexpected\n", 1}
        end
      end
    )

    on_exit(fn ->
      if is_nil(previous_cmd_fun) do
        Application.delete_env(:symphony_elixir, :runner_runtime_cmd_fun)
      else
        Application.put_env(:symphony_elixir, :runner_runtime_cmd_fun, previous_cmd_fun)
      end
    end)

    assert {:ok, rollback_payload} = RunnerRuntime.rollback()
    assert rollback_payload.action == "rollback"
    assert rollback_payload.output == "rollback ok"
    assert_receive {:runner_runtime_cmd, "bash", [_script_path, "rollback"], options}
    assert options[:stderr_to_stdout] == true

    assert {:error, failed_payload} = RunnerRuntime.record_canary("fail", note: "   ")
    assert failed_payload.action == "record_canary"
    assert failed_payload.error == "command_failed"
    assert failed_payload.exit_status == 7
    assert failed_payload.output == "runner failed"
    assert_receive {:runner_runtime_cmd, "bash", [_script_path, "record-canary", "fail"], _options}
  end
end
