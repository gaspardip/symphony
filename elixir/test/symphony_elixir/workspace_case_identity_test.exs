defmodule SymphonyElixir.WorkspaceCaseIdentityTest do
  use SymphonyElixir.TestSupport

  setup do
    path = Path.join(System.tmp_dir!(), "workspace-case-identity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    root = File.cd!(path, &File.cwd!/0)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "creating a child through a case variant refuses an existing runner directory identity", %{root: root} do
    install = Path.join(root, "RunnerCase")
    variant = Path.join(root, "runnercase")
    File.mkdir_p!(install)
    File.write!(Path.join(install, "keep"), "runner bytes")
    same_directory = File.exists?(variant)
    workspace = Path.join(variant, "NEW")

    configure(variant, install, hook_after_create: "echo created > created")

    if same_directory do
      assert directory_identity(variant) == directory_identity(install)

      assert {:error, {:workspace_runner_overlap, ^workspace, ^install}} = Workspace.create_for_issue("NEW")
      refute File.exists?(workspace)
      refute File.exists?(Path.join(install, "NEW/created"))
    else
      assert {:ok, ^workspace} = Workspace.create_for_issue("NEW")
      refute directory_identity(variant) == directory_identity(install)
      assert File.read!(Path.join(workspace, "created")) == "created\n"
    end

    assert File.read!(Path.join(install, "keep")) == "runner bytes"
  end

  test "removing an ancestor through a case variant preserves the selected release identity", %{root: root} do
    workspaces = Path.join(root, "workspaces")
    ancestor = Path.join(workspaces, "RunnerCase")
    variant = Path.join(workspaces, "runnercase")
    release = Path.join(ancestor, "release")
    File.mkdir_p!(release)
    File.write!(Path.join(release, "keep"), "selected release bytes")
    install = Path.join(root, "install")
    File.mkdir_p!(install)
    File.ln_s!(release, Path.join(install, "current"))
    same_directory = File.exists?(variant)

    configure(workspaces, install, hook_before_remove: "echo removed > removed")

    if same_directory do
      assert directory_identity(variant) == directory_identity(ancestor)

      assert {:error, {:workspace_runner_overlap, ^variant, ^release}, ""} = Workspace.remove(variant)
      refute File.exists?(Path.join(ancestor, "removed"))
      assert File.dir?(ancestor)
    else
      File.mkdir_p!(variant)
      File.write!(Path.join(variant, "workspace-only"), "independent workspace")
      refute directory_identity(variant) == directory_identity(ancestor)

      assert {:ok, _paths} = Workspace.remove(variant)
      refute File.exists?(variant)
    end

    assert File.read!(Path.join(release, "keep")) == "selected release bytes"
    assert File.read_link!(Path.join(install, "current")) == release
  end

  test "case-distinct existing directories retain lifecycle when the filesystem distinguishes them", %{root: root} do
    workspaces = Path.join(root, "workspaces")
    install = Path.join(workspaces, "RunnerCase")
    workspace = Path.join(workspaces, "runnercase")
    File.mkdir_p!(install)
    File.write!(Path.join(install, "keep"), "runner bytes")
    same_directory = File.exists?(workspace)

    configure(workspaces, install, hook_before_run: "echo before > before")

    if same_directory do
      assert directory_identity(workspace) == directory_identity(install)

      assert {:error, {:workspace_runner_overlap, ^workspace, ^install}} = Workspace.create_for_issue("runnercase")
      refute File.exists?(Path.join(install, "before"))
    else
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "workspace-only"), "independent workspace")
      refute directory_identity(workspace) == directory_identity(install)

      assert {:ok, ^workspace} = Workspace.create_for_issue("runnercase")
      assert File.read!(Path.join(workspace, "workspace-only")) == "independent workspace"
      assert :ok = Workspace.run_before_run_hook(workspace, "runnercase")
      assert File.read!(Path.join(workspace, "before")) == "before\n"
      assert {:ok, _paths} = Workspace.remove(workspace)
      refute File.exists?(workspace)
    end

    assert File.read!(Path.join(install, "keep")) == "runner bytes"
  end

  test "a selected link with an unresolved parent segment refuses ordinary workspace creation", %{root: root} do
    workspaces = Path.join(root, "workspaces")
    workspace = Path.join(workspaces, "ORDINARY")
    install = Path.join(root, "install")
    release = Path.join(install, "release")
    missing = Path.join(install, "missing")
    current = Path.join(install, "current")
    File.mkdir_p!(release)
    File.write!(Path.join(release, "keep"), "release bytes")
    File.ln_s!("missing/../release", current)
    configure(workspaces, install, hook_after_create: "echo created > created")

    refute File.exists?(missing)
    assert File.read_link!(current) == "missing/../release"
    assert File.stat(current) == {:error, :enoent}

    assert {:error, {:workspace_path_unreadable, ^missing, :unresolved_parent}} = Workspace.create_for_issue("ORDINARY")
    refute File.exists?(workspace)
    refute File.exists?(Path.join(workspace, "created"))
    assert File.read!(Path.join(release, "keep")) == "release bytes"
    assert File.read_link!(current) == "missing/../release"
  end

  defp directory_identity(path) do
    stat = File.stat!(path)
    assert stat.type == :directory
    assert is_integer(stat.major_device)
    assert is_integer(stat.inode) and stat.inode > 0
    {stat.major_device, stat.inode}
  end

  defp configure(workspaces, install, hooks) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      [tracker_kind: "memory", workspace_root: workspaces, runner_install_root: install] ++ hooks
    )
  end
end
