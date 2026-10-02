defmodule SymphonyElixir.GateIdentityTest do
  use SymphonyElixir.TestSupport

  setup do
    root = "/private/tmp/gate-identity-#{System.unique_integer([:positive])}"
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GATE-1")
    File.mkdir_p!(Path.join(workspace, ".git"))
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "input"), "physical input\n")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, workspace_root: workspace_root}
  end

  for kind <- [:preflight, :validation, :smoke, :artifacts] do
    @kind kind
    test "#{kind} identifies physical success, nonzero exit and unavailable as separate invocations", c do
      passed = run(@kind, c.workspace, "test -s input && printf completed >> witness")
      failed = run(@kind, c.workspace, "printf rejected >> witness; exit 17")
      absent = run(@kind, c.workspace, nil)
      assert File.read!(Path.join(c.workspace, "witness")) == "completedrejected"
      assert passed.status == :passed
      assert passed.exit_code == 0
      assert failed.status == :failed
      assert failed.exit_code == 17
      assert absent.status == :unavailable
      assert absent.exit_code == nil
      assert absent.command == nil
      assert absent.environment.executor == :not_started
      assert passed.environment.executor == :legacy_shell
      assert failed.environment.executor == :legacy_shell

      ids =
        Enum.map([passed, failed, absent], fn result ->
          assert result.gate_kind == @kind
          assert String.starts_with?(result.gate_id, "gate_")
          assert {:ok, _, 0} = DateTime.from_iso8601(result.started_at)
          assert {:ok, _, 0} = DateTime.from_iso8601(result.finished_at)
          assert is_integer(result.duration_us) and result.duration_us >= 0
          assert Enum.sort(Map.keys(result.environment)) == [:executor, :os_family, :os_name]
          result.gate_id
        end)

      assert length(Enum.uniq(ids)) == 3
    end
  end

  test "historical and non-gate command results are not assigned a retrospective identity", c do
    historical = %RunInspector.CommandResult{status: :passed, command: "old", output: "old"}
    assert historical.gate_id == nil
    current = RunInspector.run_validation(c.workspace, %RepoHarness{validation_command: "test -s input"}, gate_id: "gate_supplied_by_caller")
    assert current.status == :passed
    assert current.gate_id != "gate_supplied_by_caller"
    assert RunInspector.run_shell_command(c.workspace, "printf ordinary").gate_id == nil
    assert RunInspector.run_post_merge(c.workspace, %RepoHarness{post_merge_command: "printf post"}).gate_id == nil
  end

  test "selected physical execution reports its returned executor and exact exit without environment contents", c do
    selected!(c)
    result = run(:validation, c.workspace, "test -s input && /usr/bin/true && printf selected > selected-witness; exit 17")
    assert result.status == :failed
    assert result.exit_code == 17
    assert result.environment.executor == :execution_boundary
    assert File.read!(Path.join(c.workspace, "selected-witness")) == "selected"
    assert String.starts_with?(result.gate_id, "gate_")
    refute inspect(result.environment) =~ c.root
    refute Map.has_key?(result.environment, :env)
  end

  test "selected denied write has its own ID and a physical unchanged witness", c do
    outside = Path.join(c.root, "outside")
    File.write!(outside, "unchanged")
    selected!(c)
    result = run(:artifacts, c.workspace, "printf forbidden > '#{outside}'")
    assert result.status == :failed
    assert result.exit_code != 0
    assert result.environment.executor == :execution_boundary
    assert result.gate_kind == :artifacts
    assert is_binary(result.gate_id)
    assert File.read!(outside) == "unchanged"
  end

  test "invalid selected policy records unavailable without legacy execution", c do
    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "---\n", "---\nexecution_boundary: null\n", global: false))
    :ok = WorkflowStore.force_reload()
    result = run(:preflight, c.workspace, "printf forbidden > never")
    assert result.status == :unavailable
    assert result.error == :invalid_execution_boundary_selection
    assert result.exit_code == nil
    assert result.environment.executor == :execution_boundary
    assert is_binary(result.gate_id)
    refute File.exists?(Path.join(c.workspace, "never"))
  end

  defp run(:preflight, w, cmd), do: RunInspector.run_preflight(w, %RepoHarness{preflight_command: cmd})
  defp run(:validation, w, cmd), do: RunInspector.run_validation(w, %RepoHarness{validation_command: cmd})
  defp run(:smoke, w, cmd), do: RunInspector.run_smoke(w, %RepoHarness{smoke_command: cmd})
  defp run(:artifacts, w, cmd), do: RunInspector.run_artifacts(w, %RepoHarness{artifacts_command: cmd})

  defp selected!(c) do
    policy = %{
      "version" => 1,
      "backend" => "macos_deny_default_v1",
      "workspace_root" => c.workspace_root,
      "shell" => "/bin/bash",
      "executables" => Enum.map(["/bin/bash", "/usr/bin/true"], fn path -> %{"path" => path, "sha256" => digest(File.read!(path))} end),
      "read_roots" => []
    }

    bytes = Jason.encode!(policy)
    policy_path = Path.join(c.root, "policy.json")
    File.write!(policy_path, bytes)
    File.chmod!(policy_path, 0o400)
    selection = %{"policy_file" => policy_path, "sha256" => digest(bytes), "timeout_ms" => 5000}
    workflow = Workflow.workflow_file_path()
    File.write!(workflow, String.replace(File.read!(workflow), "---\n", "---\nexecution_boundary: #{Jason.encode!(selection)}\n", global: false))
    :ok = WorkflowStore.force_reload()
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
