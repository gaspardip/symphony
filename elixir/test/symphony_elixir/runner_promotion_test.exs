defmodule SymphonyElixir.RunnerPromotionTest do
  use SymphonyElixir.TestSupport

  test "promotion CLI supports promote inspect canary recording and rollback" do
    root = Path.join(System.tmp_dir!(), "symphony-runner-cli-#{System.unique_integer([:positive])}")
    install_root = Path.join(root, "install")
    repo_root = Path.join(root, "repo")

    old_repo_url = System.get_env("SYMPHONY_RUNNER_REPO_URL")
    old_install_root = System.get_env("SYMPHONY_RUNNER_INSTALL_ROOT")
    old_canary_label = System.get_env("SYMPHONY_RUNNER_DEFAULT_CANARY_LABEL")

    on_exit(fn ->
      restore_env("SYMPHONY_RUNNER_REPO_URL", old_repo_url)
      restore_env("SYMPHONY_RUNNER_INSTALL_ROOT", old_install_root)
      restore_env("SYMPHONY_RUNNER_DEFAULT_CANARY_LABEL", old_canary_label)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    {first_sha, second_sha} = seed_runner_repo!(repo_root)

    System.put_env("SYMPHONY_RUNNER_REPO_URL", repo_root)
    System.put_env("SYMPHONY_RUNNER_INSTALL_ROOT", install_root)
    System.put_env("SYMPHONY_RUNNER_DEFAULT_CANARY_LABEL", "canary:symphony")

    assert {_, 0} = run_promotion_command(["promote", first_sha])

    first_metadata = read_runner_metadata(install_root)
    assert first_metadata["promoted_release_sha"] == first_sha
    assert first_metadata["runner_mode"] == "canary_active"
    assert first_metadata["canary_required_labels"] == ["canary:symphony"]
    assert first_metadata["repo_url"] == repo_root
    assert is_map(first_metadata["build_tool_versions"])
    assert is_binary(first_metadata["release_manifest_path"])
    assert is_binary(first_metadata["preflight_completed_at"])
    assert is_binary(first_metadata["smoke_completed_at"])
    assert is_binary(first_metadata["promotion_host"])
    assert is_binary(first_metadata["promotion_user"])
    assert File.read_link!(Path.join(install_root, "current")) =~ first_sha
    assert read_release_manifest(install_root, first_sha)["commit_sha"] == first_sha
    assert read_release_manifest(install_root, first_sha)["repo_url"] == repo_root

    assert {inspect_output, 0} = run_promotion_command(["inspect"])
    inspect_payload = Jason.decode!(inspect_output)
    assert inspect_payload["promoted_release_sha"] == first_sha
    assert inspect_payload["runner_mode"] == "canary_active"
    assert inspect_payload["release_manifest"]["commit_sha"] == first_sha
    assert is_list(inspect_payload["history"])

    assert {_, 0} =
             run_promotion_command([
               "record-canary",
               "pass",
               "--issue",
               "CLZ-10",
               "--pr",
               "https://github.com/gaspardip/symphony/pull/10",
               "--note",
               "looks healthy"
             ])

    passed_metadata = read_runner_metadata(install_root)
    assert passed_metadata["runner_mode"] == "stable"
    assert passed_metadata["canary_result"] == "pass"
    assert passed_metadata["rollback_recommended"] == false
    assert passed_metadata["canary_evidence"]["issues"] == ["CLZ-10"]
    assert passed_metadata["canary_evidence"]["prs"] == ["https://github.com/gaspardip/symphony/pull/10"]

    assert {_, 0} = run_promotion_command(["promote", second_sha, "--canary-label", "canary:symphony"])
    second_metadata = read_runner_metadata(install_root)
    assert second_metadata["promoted_release_sha"] == second_sha
    assert second_metadata["previous_release_sha"] == first_sha
    assert second_metadata["runner_mode"] == "canary_active"

    assert {_, 0} =
             run_promotion_command([
               "record-canary",
               "fail",
               "--issue",
               "CLZ-11",
               "--pr",
               "https://github.com/gaspardip/symphony/pull/11",
               "--note",
               "regression detected"
             ])

    failed_metadata = read_runner_metadata(install_root)
    assert failed_metadata["runner_mode"] == "canary_failed"
    assert failed_metadata["rollback_recommended"] == true
    assert failed_metadata["canary_result"] == "fail"
    assert failed_metadata["canary_evidence"]["issues"] == ["CLZ-11"]
    assert failed_metadata["canary_evidence"]["prs"] == ["https://github.com/gaspardip/symphony/pull/11"]

    assert {_, 0} = run_promotion_command(["rollback"])
    rolled_back_metadata = read_runner_metadata(install_root)
    assert rolled_back_metadata["promoted_release_sha"] == first_sha
    assert rolled_back_metadata["previous_release_sha"] == second_sha
    assert rolled_back_metadata["runner_mode"] == "stable"
    assert rolled_back_metadata["rollback_recommended"] == false
    assert rolled_back_metadata["release_manifest_path"] =~ first_sha
    assert rolled_back_metadata["canary_evidence"] == %{"issues" => [], "prs" => []}
    assert File.read_link!(Path.join(install_root, "current")) =~ first_sha

    history_entries = read_runner_history(install_root)
    assert Enum.any?(history_entries, &(&1["event_type"] == "runner.promoted"))
    assert Enum.any?(history_entries, &(&1["event_type"] == "runner.canary.recorded"))
    assert Enum.any?(history_entries, &(&1["event_type"] == "runner.rollback.completed"))
  end

  test "rollback fails cleanly when no previous release exists" do
    root = Path.join(System.tmp_dir!(), "symphony-runner-rollback-#{System.unique_integer([:positive])}")
    install_root = Path.join(root, "install")

    old_install_root = System.get_env("SYMPHONY_RUNNER_INSTALL_ROOT")

    on_exit(fn ->
      restore_env("SYMPHONY_RUNNER_INSTALL_ROOT", old_install_root)
      File.rm_rf(root)
    end)

    File.mkdir_p!(install_root)
    File.write!(
      Path.join(install_root, "metadata.json"),
      Jason.encode!(%{
        "promoted_release_sha" => "only-release",
        "promoted_release_path" => Path.join(install_root, "releases/only-release"),
        "runner_mode" => "stable"
      })
    )

    System.put_env("SYMPHONY_RUNNER_INSTALL_ROOT", install_root)

    assert {output, 1} = run_promotion_command(["rollback"])
    assert output =~ "No previous release is available for rollback"
  end

  defp seed_runner_repo!(repo_root) do
    File.mkdir_p!(repo_root)
    File.mkdir_p!(Path.join(repo_root, "scripts"))

    script_body = "#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n"

    Enum.each(
      ["symphony-preflight.sh", "symphony-smoke.sh"],
      fn name ->
        path = Path.join(repo_root, "scripts/#{name}")
        File.write!(path, script_body)
        File.chmod!(path, 0o755)
      end
    )

    run_git!(repo_root, ["init", "-b", "main"])
    run_git!(repo_root, ["config", "user.name", "Symphony Tests"])
    run_git!(repo_root, ["config", "user.email", "tests@example.com"])
    File.write!(Path.join(repo_root, "README.md"), "# runner test\n")
    run_git!(repo_root, ["add", "."])
    run_git!(repo_root, ["commit", "-m", "initial"])
    first_sha = git_output!(repo_root, ["rev-parse", "HEAD"])

    File.write!(Path.join(repo_root, "README.md"), "# runner test v2\n")
    run_git!(repo_root, ["commit", "-am", "second"])
    second_sha = git_output!(repo_root, ["rev-parse", "HEAD"])

    {first_sha, second_sha}
  end

  defp run_promotion_command(args) do
    System.cmd(
      "bash",
      [promotion_script() | args],
      stderr_to_stdout: true
    )
  end

  defp run_git!(repo_root, args) do
    assert {_, 0} = System.cmd("git", args, cd: repo_root, stderr_to_stdout: true)
  end

  defp git_output!(repo_root, args) do
    assert {output, 0} = System.cmd("git", args, cd: repo_root, stderr_to_stdout: true)
    String.trim(output)
  end

  defp read_runner_metadata(install_root) do
    install_root
    |> Path.join("metadata.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp read_runner_history(install_root) do
    install_root
    |> Path.join("history.jsonl")
    |> File.stream!()
    |> Enum.map(&Jason.decode!(String.trim(&1)))
  end

  defp read_release_manifest(install_root, sha) do
    install_root
    |> Path.join("releases/#{sha}/manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp promotion_script do
    Path.expand("../../../ops/promote-runner.sh", __DIR__)
  end
end
