defmodule SymphonyElixir.WorkspaceRunnerSafetyTest do
  use SymphonyElixir.TestSupport

  setup do
    path = Path.join(System.tmp_dir!(), "workspace-runner-safety-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    root = File.cd!(path, &File.cwd!/0)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, workspaces: Path.join(root, "workspaces")}
  end

  test "creation refuses a missing workspace inside the runner install before bootstrap", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-NEW")
    configure(workspaces, workspace, "echo created > marker")

    assert {:error, {:workspace_runner_overlap, ^workspace, ^workspace}} = Workspace.create_for_issue("MT-NEW")
    refute File.exists?(workspace)
    refute File.exists?(Path.join(root, "marker"))
  end

  test "blocked selected release is preserved before workspace reset and after_create", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-BLOCKED")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    snapshot = ~s({"stage":"blocked"})
    File.write!(Path.join(workspace, ".symphony/run_state.json"), snapshot)
    File.write!(Path.join(workspace, "keep"), "release bytes")
    install = select_release(root, workspace)
    configure(workspaces, install, "echo created > marker")

    assert {:error, {:workspace_runner_overlap, ^workspace, ^workspace}} = Workspace.create_for_issue("MT-BLOCKED")
    assert File.read!(Path.join(workspace, "keep")) == "release bytes"
    assert File.read!(Path.join(workspace, ".symphony/run_state.json")) == snapshot
    refute File.exists?(Path.join(workspace, "marker"))
  end

  test "current checkout is preserved before reuse cleanup", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-CHECKOUT")
    File.mkdir_p!(Path.join(workspace, "tmp"))
    File.write!(Path.join(workspace, "tmp/keep"), "checkout bytes")
    configure(workspaces, Path.join(root, "install"), nil)

    File.cd!(workspace, fn ->
      assert {:error, {:workspace_runner_overlap, ^workspace, ^workspace}} = Workspace.create_for_issue("MT-CHECKOUT")
    end)

    assert File.read!(Path.join(workspace, "tmp/keep")) == "checkout bytes"
  end

  test "removal refuses a workspace containing the selected release before its hook", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-REMOVE")
    release = Path.join(workspace, "release")
    File.mkdir_p!(release)
    File.write!(Path.join(release, "keep"), "release bytes")
    install = select_release(root, release)
    configure(workspaces, install, nil, hook_before_remove: "echo removed > marker")

    assert {:error, {:workspace_runner_overlap, ^workspace, ^release}, ""} = Workspace.remove(workspace)
    assert File.read!(Path.join(release, "keep")) == "release bytes"
    refute File.exists?(Path.join(workspace, "marker"))
  end

  test "before_run refuses a newly selected protected workspace", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-BEFORE")
    File.mkdir_p!(workspace)
    install = select_release(root, workspace)
    configure(workspaces, install, nil, hook_before_run: "echo before > marker")

    assert {:error, {:workspace_runner_overlap, ^workspace, ^workspace}} = Workspace.run_before_run_hook(workspace, "MT-BEFORE")
    refute File.exists?(Path.join(workspace, "marker"))
  end

  test "after_run logs refusal and preserves its best effort contract", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-AFTER")
    File.mkdir_p!(workspace)
    install = select_release(root, workspace)
    configure(workspaces, install, nil, hook_after_run: "echo after > marker")

    log = capture_log(fn -> assert :ok = Workspace.run_after_run_hook(workspace, "MT-AFTER") end)

    assert log =~ "Workspace hook refused"
    assert log =~ "workspace_runner_overlap"
    refute File.exists?(Path.join(workspace, "marker"))
  end

  test "a workspace root alias cannot bypass protection of an existing release", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-ALIAS")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "keep"), "release bytes")
    alias_root = Path.join(root, "alias")
    File.ln_s!(workspaces, alias_root)
    alias_workspace = Path.join(alias_root, "MT-ALIAS")
    configure(alias_root, workspace, nil)

    assert {:error, {:workspace_runner_overlap, ^alias_workspace, ^workspace}, ""} = Workspace.remove(alias_workspace)
    assert File.read!(Path.join(workspace, "keep")) == "release bytes"
  end

  test "a workspace root alias cannot bypass protection of a missing install directory", %{root: root, workspaces: workspaces} do
    File.mkdir_p!(workspaces)
    workspace = Path.join(workspaces, "MT-MISSING")
    alias_root = Path.join(root, "alias")
    File.ln_s!(workspaces, alias_root)
    alias_workspace = Path.join(alias_root, "MT-MISSING")
    configure(alias_root, workspace, "echo created > marker")

    assert {:error, {:workspace_runner_overlap, ^alias_workspace, ^workspace}} = Workspace.create_for_issue("MT-MISSING")
    refute File.exists?(workspace)
  end

  test "a protected install alias is resolved before cleanup", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-INSTALL")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "keep"), "install bytes")
    install = Path.join(root, "install-link")
    File.ln_s!(workspace, install)
    configure(workspaces, install, nil)

    assert {:error, {:workspace_runner_overlap, ^workspace, ^workspace}, ""} = Workspace.remove(workspace)
    assert File.read!(Path.join(workspace, "keep")) == "install bytes"
  end

  test "unresolvable protected paths fail explicitly before creation", %{root: root, workspaces: workspaces} do
    install = Path.join(root, "loop")
    File.ln_s!("loop", install)
    configure(workspaces, install, nil)

    assert {:error, {:workspace_path_unreadable, ^install, :eloop}} = Workspace.create_for_issue("MT-LOOP")
    refute File.exists?(Path.join(workspaces, "MT-LOOP"))
  end

  test "a neighboring workspace with the same prefix retains its normal lifecycle", %{workspaces: workspaces} do
    install = Path.join(workspaces, "MT-OK-runner")
    configure(workspaces, install, "echo created > created", hook_before_run: "echo before > before", hook_after_run: "echo after > after", hook_before_remove: "echo removed > removed")

    assert {:ok, workspace} = Workspace.create_for_issue("MT-OK")
    assert :ok = Workspace.run_before_run_hook(workspace, "MT-OK")
    assert :ok = Workspace.run_after_run_hook(workspace, "MT-OK")
    assert File.read!(Path.join(workspace, "created")) == "created\n"
    assert File.read!(Path.join(workspace, "before")) == "before\n"
    assert File.read!(Path.join(workspace, "after")) == "after\n"
    assert {:ok, _paths} = Workspace.remove(workspace)
    refute File.exists?(workspace)
  end

  test "protected symlink targets resolve parent segments after nested links", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "release")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspaces, "inner"))
    File.ln_s!(Path.join(workspaces, "inner"), Path.join(root, "nested"))
    install = Path.join(root, "install-link")
    File.ln_s!("nested/../release", install)
    File.write!(Path.join(workspace, "keep"), "release bytes")
    configure(workspaces, install, nil)

    assert {:error, {:workspace_runner_overlap, ^workspace, ^workspace}, ""} = Workspace.remove(workspace)
    assert File.read!(Path.join(workspace, "keep")) == "release bytes"
  end

  test "a protected filesystem root refuses creation of any child", %{workspaces: workspaces} do
    workspace = Path.join(workspaces, "MT-ROOT")
    configure(workspaces, "/", nil)

    assert {:error, {:workspace_runner_overlap, ^workspace, "/"}} = Workspace.create_for_issue("MT-ROOT")
    refute File.exists?(workspace)
  end

  test "selected current is resolved physically before normalizing parent segments", %{root: root, workspaces: workspaces} do
    workspace = Path.join(workspaces, "release")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspaces, "inner"))
    install = Path.join(root, "install")
    File.mkdir_p!(install)
    File.ln_s!(Path.join(workspaces, "inner"), Path.join(install, "nested"))
    File.ln_s!("nested/../release", Path.join(install, "current"))
    File.write!(Path.join(workspace, "keep"), "release bytes")
    configure(workspaces, install, nil)

    assert {:error, {:workspace_runner_overlap, ^workspace, ^workspace}, ""} = Workspace.remove(workspace)
    assert File.read!(Path.join(workspace, "keep")) == "release bytes"
  end

  defp configure(workspaces, install, after_create, hooks \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      [tracker_kind: "memory", workspace_root: workspaces, runner_install_root: install, hook_after_create: after_create] ++ hooks
    )
  end

  defp select_release(root, release) do
    install = Path.join(root, "install")
    File.mkdir_p!(install)
    File.ln_s!(release, Path.join(install, "current"))
    install
  end
end
