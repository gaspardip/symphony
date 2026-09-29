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

    for key <- ["build_id", "build_receipt_sha256", "embedded_manifest_sha256", "escript_sha256"] do
      assert read_release_manifest(install_root, first_sha)[key] =~ ~r/^[0-9a-f]{64}$/
    end

    refute File.exists?(Path.join([install_root, "releases", first_sha, ".git"]))

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

  test "E1-B14 altered copy is rejected before current changes", _context do
    root = Path.join(System.tmp_dir!(), "identity-promotion-copy-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    install = Path.join(root, "install")
    old_repo = System.get_env("SYMPHONY_RUNNER_REPO_URL")
    old_install = System.get_env("SYMPHONY_RUNNER_INSTALL_ROOT")
    old_path = System.get_env("PATH")
    real_rsync = System.find_executable("rsync")

    on_exit(fn ->
      restore_env("SYMPHONY_RUNNER_REPO_URL", old_repo)
      restore_env("SYMPHONY_RUNNER_INSTALL_ROOT", old_install)
      restore_env("PATH", old_path)
      File.rm_rf!(root)
    end)

    {sha, _} = seed_runner_repo!(repo)
    previous = Path.join(install, "previous")
    File.mkdir_p!(previous)
    File.ln_s!(previous, Path.join(install, "current"))
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    executable = Path.join(bin, "rsync")
    File.write!(executable, "#!/bin/bash\nset -euo pipefail\n#{inspect(real_rsync)} \"$@\"\ndestination=\"${@: -1}\"\nprintf corrupted >> \"$destination/elixir/bin/symphony.build.json\"\n")
    File.chmod!(executable, 0o755)
    System.put_env("PATH", bin <> ":" <> old_path)
    System.put_env("SYMPHONY_RUNNER_REPO_URL", repo)
    System.put_env("SYMPHONY_RUNNER_INSTALL_ROOT", install)
    assert {output, status} = run_promotion_command(["promote", sha])
    assert status != 0
    assert output =~ "build identity:"
    assert File.read_link!(Path.join(install, "current")) == previous
    refute File.exists?(Path.join(install, "metadata.json"))
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
        File.write!(path, if(name == "symphony-smoke.sh", do: shell_receipt_fixture(), else: script_body))
        File.chmod!(path, 0o755)
      end
    )

    File.write!(Path.join(repo_root, ".gitignore"), "/elixir/bin/\n")
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

  # Synthetic archive/receipt ONLY for shell orchestration. It is not executable
  # code provenance. BuildIdentityIntegrationTest exercises the actual builder.
  defp shell_receipt_fixture do
    ~S"""
    #!/usr/bin/env bash
    set -euo pipefail
    cd "$(dirname "$0")/.."
    python3 <<'PYFIXTURE'
    import hashlib, json, pathlib, subprocess, zipfile
    def canonical(value):
        return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
    def sha(value):
        return hashlib.sha256(value).hexdigest()
    source = {"status": "clean", "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip(),
              "tree_oid": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"]).decode().strip(),
              "entries": [], "external_resources": [], "fingerprint": sha(canonical({"entries": [], "external_resources": []}))}
    module = {"name": "Fixture", "app": "symphony_elixir", "path": "symphony_elixir/ebin/Fixture.beam", "code_md5": "0" * 32}
    manifest = {"version": 1, "source": source, "toolchain": {}, "scope": {"fixture": "shell_orchestration_only"}, "modules": [module], "compiled_inputs": []}
    manifest["build_id"] = sha(canonical({key: manifest[key] for key in ("source", "toolchain", "modules", "scope")}))
    embedded = canonical(manifest)
    archive = pathlib.Path("elixir/bin/symphony")
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "w") as zipped:
        zipped.writestr("symphony_elixir/priv/build_identity.json", embedded)
        zipped.writestr(module["path"], b"shell fixture; not a BEAM")
    receipt = {"version": 1, "status": "compared", "build_id": manifest["build_id"],
               "source": {key: source[key] for key in ("base_commit", "tree_oid", "status", "fingerprint")},
               "embedded_manifest_sha256": sha(embedded), "escript_sha256": sha(archive.read_bytes()),
               "compiled_inputs_sha256": sha(canonical([])), "modules": [dict(module, packaged_beam_sha256=sha(b"shell fixture; not a BEAM"))]}
    archive.with_name("symphony.build.json").write_bytes(canonical(receipt))
    PYFIXTURE
    """
  end

  defp run_promotion_command(args) do
    # Bound the script and its version-probe children, including failures during copy.
    watchdog = ~S"""
    import os, signal, subprocess, sys
    child = subprocess.Popen(sys.argv[1:], start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        output, _ = child.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        output, _ = child.communicate()
        sys.stdout.buffer.write(output)
        print("PROMOTION WATCHDOG TIMEOUT", flush=True)
        raise SystemExit(124)
    sys.stdout.buffer.write(output)
    raise SystemExit(child.returncode)
    """

    System.cmd("python3", ["-c", watchdog, "bash", promotion_script() | args], stderr_to_stdout: true)
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
