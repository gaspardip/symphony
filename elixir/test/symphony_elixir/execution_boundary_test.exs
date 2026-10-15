defmodule SymphonyElixir.ExecutionBoundaryTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ExecutionBoundary

  setup do
    root = "/private/tmp/boundary-test-#{System.unique_integer([:positive])}"
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "CANDIDATE-1")
    tools = Path.join(root, "tools")
    File.mkdir_p!(Path.join(workspace, ".git"))
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.mkdir_p!(tools)
    File.write!(Path.join(workspace, ".git/config"), "protected git\n")
    File.write!(Path.join(workspace, ".symphony/run_state.json"), "protected runtime\n")
    File.write!(Path.join(workspace, "candidate.txt"), "answer=42\n")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)
    base_workflow = File.read!(Workflow.workflow_file_path())
    policy_path = Path.join(root, "policy.json")

    policy = %{
      "version" => 1,
      "backend" => "macos_deny_default_v1",
      "workspace_root" => workspace_root,
      "shell" => "/bin/bash",
      "executables" => Enum.map(["/bin/bash", "/usr/bin/true"], &tool/1),
      "read_roots" => []
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace_root: workspace_root, workspace: workspace, policy_path: policy_path, policy: policy, base_workflow: base_workflow, tools: tools}
  end

  test "only absent selection preserves the historical runner", c do
    assert {:ok, :legacy} = Config.execution_boundary()
    assert :legacy = ExecutionBoundary.run(c.workspace, "exit 99")

    assert %{status: :passed, output: "historical"} =
             RunInspector.run_validation(
               c.workspace,
               %RepoHarness{validation_command: "legacy"},
               shell_runner: fn _, _, _ -> {"historical", 0} end
             )

    selected!(c, nil)
    assert {:error, :invalid_execution_boundary_selection} = ExecutionBoundary.run(c.workspace, "exit 0")
  end

  test "invalid explicit selection cannot use a supplied runner", c do
    selected!(c, %{"policy_file" => c.policy_path, "sha256" => "wrong", "timeout_ms" => 1000})
    result = RunInspector.run_validation(c.workspace, %RepoHarness{validation_command: "exit 0"}, shell_runner: fn _, _, _ -> flunk("policy rejection ran historical callback") end)
    assert result.status == :unavailable
    assert result.error == :invalid_execution_boundary_selection
  end

  test "missing policy and changed digest are explicit before candidate effects", c do
    selected!(c, selection(c, String.duplicate("0", 64)))
    assert {:error, :enoent} = ExecutionBoundary.run(c.workspace, "printf changed > effect")
    policy!(c)
    File.chmod!(c.policy_path, 0o600)
    File.write!(c.policy_path, "{}")
    File.chmod!(c.policy_path, 0o400)
    assert {:error, :policy_digest_mismatch} = ExecutionBoundary.run(c.workspace, "printf changed > effect")
    refute File.exists?(Path.join(c.workspace, "effect"))
  end

  test "present policy IO and malformed JSON cannot select legacy", c do
    File.mkdir!(c.policy_path)
    selected!(c, selection(c, String.duplicate("0", 64)))
    assert {:error, :unexpected_boundary_file_type} = ExecutionBoundary.run(c.workspace, "exit 0")
    File.rmdir!(c.policy_path)
    File.write!(c.policy_path, "{")
    File.chmod!(c.policy_path, 0o400)
    selected!(c, selection(c, digest("{")))
    assert {:error, {:invalid_policy_json, _position}} = ExecutionBoundary.run(c.workspace, "exit 0")
  end

  test "policy and workflow inside any candidate root are rejected", c do
    inside = %{c | policy_path: Path.join(c.workspace, "policy.json")}
    policy!(inside)
    assert {:error, :policy_inside_candidate_root} = ExecutionBoundary.run(c.workspace, "exit 0")
    policy!(c)
    original = Workflow.workflow_file_path()
    candidate_workflow = Path.join(c.workspace, "WORKFLOW.md")
    File.copy!(original, candidate_workflow)
    Workflow.set_workflow_file_path(candidate_workflow)

    try do
      assert {:error, :policy_inside_candidate_root} = ExecutionBoundary.run(c.workspace, "exit 0")
    after
      Workflow.set_workflow_file_path(original)
    end
  end

  test "a tool inside the workspace cannot be made trusted by a matching hash", c do
    script = Path.join(c.workspace, "tool")
    File.write!(script, "#!/bin/bash\nexit 0\n")
    File.chmod!(script, 0o500)
    policy!(c, %{c.policy | "executables" => [tool(script)], "shell" => script})
    assert {:error, :tool_inside_candidate_root} = ExecutionBoundary.run(c.workspace, "exit 0")
  end

  test "tool hashes and physical paths are checked before launch", c do
    wrong = put_in(c.policy, ["executables", Access.at(0), "sha256"], String.duplicate("0", 64))
    policy!(c, wrong)
    assert {:error, :tool_digest_mismatch} = ExecutionBoundary.run(c.workspace, "exit 0")
    link = Path.join(c.tools, "shell")
    File.ln_s!("/bin/bash", link)
    policy!(c, %{c.policy | "executables" => [tool(link)], "shell" => link})
    assert {:error, :nonphysical_policy_path} = ExecutionBoundary.run(c.workspace, "exit 0")
  end

  test "broad and candidate-overlapping read roots are rejected", c do
    policy!(c, %{c.policy | "read_roots" => ["/private/tmp"]})
    assert {:error, :overbroad_read_root} = ExecutionBoundary.run(c.workspace, "exit 0")
    policy!(c, %{c.policy | "read_roots" => [c.root]})
    assert {:error, :read_root_overlaps_candidates} = ExecutionBoundary.run(c.workspace, "exit 0")
  end

  test "selected policy cannot be bypassed with an injected shell runner or environment", c do
    policy!(c)

    assert {:error, :execution_boundary_override_forbidden} =
             ExecutionBoundary.run(c.workspace, "exit 0", shell_runner: fn _, _, _ -> flunk("bypass") end)

    assert {:error, :execution_boundary_override_forbidden} = ExecutionBoundary.run(c.workspace, "exit 0", env: [{"TOKEN", "secret"}])
  end

  test "useful shell validation writes its own output and executes the exact allowed tool", c do
    policy!(c)
    command = "IFS= read -r value < candidate.txt; test \"$value\" = answer=42 && /usr/bin/true && printf validated > result.txt"
    assert %{status: :passed, error: nil} = RunInspector.run_validation(c.workspace, %RepoHarness{validation_command: command})
    assert File.read!(Path.join(c.workspace, "result.txt")) == "validated"
    assert File.read!(Path.join(c.workspace, ".symphony/run_state.json")) == "protected runtime\n"
  end

  test "absolute, parent and symlink writes cannot touch an outside witness", c do
    witness = Path.join(c.root, "outside")
    File.write!(witness, "unchanged")
    File.ln_s!(witness, Path.join(c.workspace, "escape"))
    policy!(c)

    for target <- [witness, "../../outside", "escape"] do
      assert {:ok, {_output, status}} = ExecutionBoundary.run(c.workspace, "printf changed > #{quote_shell(target)}")
      assert status != 0
      assert File.read!(witness) == "unchanged"
    end
  end

  test "run state and git metadata stay read-only", c do
    policy!(c)

    for target <- [".git/config", ".symphony/run_state.json"] do
      original = File.read!(Path.join(c.workspace, target))
      assert {:ok, {_output, status}} = ExecutionBoundary.run(c.workspace, "printf corrupt > #{target}")
      assert status != 0
      assert File.read!(Path.join(c.workspace, target)) == original
    end
  end

  test "a real external gitdir and commondir grant no new read or write access", c do
    File.rm_rf!(Path.join(c.workspace, ".git"))
    gitdir = Path.join(c.root, "git-worktree")
    common = Path.join(c.root, "common")
    File.mkdir!(gitdir)
    File.mkdir!(common)
    File.write!(Path.join(gitdir, "commondir"), "../common\n")
    File.write!(Path.join(common, "config"), "external secret metadata")
    File.write!(Path.join(c.workspace, ".git"), "gitdir: #{gitdir}\n")
    policy!(c)
    assert {:ok, {_output, 0}} = ExecutionBoundary.run(c.workspace, "/usr/bin/true")

    for command <- ["printf corrupt > #{quote_shell(Path.join(common, "config"))}", "IFS= read -r secret < #{quote_shell(Path.join(common, "config"))}"] do
      assert {:ok, {_output, status}} = ExecutionBoundary.run(c.workspace, command)
      assert status != 0
    end

    assert File.read!(Path.join(common, "config")) == "external secret metadata"
  end

  test "inherited secrets and trustee HOME are unavailable to candidate shell and child", c do
    previous = System.get_env("BOUNDARY_SECRET")
    System.put_env("BOUNDARY_SECRET", "not-for-candidate")
    on_exit(fn -> restore_env("BOUNDARY_SECRET", previous) end)
    policy!(c)

    command =
      ~s|test -z "${BOUNDARY_SECRET+x}" && test "$HOME" != #{quote_shell(System.user_home!())} && | <>
        "/bin/bash -c 'test -z \"${BOUNDARY_SECRET+x}\" && printf private > \"$HOME/own\"'"

    assert {:ok, {_output, 0}} = ExecutionBoundary.run(c.workspace, command)
  end

  test "trustee file canary cannot be read from a candidate or its child", c do
    canary = Path.join(c.root, "trustee-canary")
    File.write!(canary, "never-in-command-output")
    assert File.read!(canary) == "never-in-command-output"
    policy!(c)

    for prefix <- ["", "/bin/bash -c "] do
      command = "IFS= read -r value < #{quote_shell(canary)} && printf '%s' \"$value\""
      command = if prefix == "", do: command, else: prefix <> quote_shell(command)
      assert {:ok, {output, status}} = ExecutionBoundary.run(c.workspace, command)
      assert status != 0
      refute output =~ "never-in-command-output"
    end
  end

  test "a readable forbidden executable cannot create its valid marker", c do
    forbidden = Path.join(c.tools, "forbidden")
    marker = Path.join(c.workspace, "forbidden-ran")
    File.write!(forbidden, "#!/bin/bash\nprintf witness > #{quote_shell(marker)}\n")
    File.chmod!(forbidden, 0o500)
    assert {_, 0} = System.cmd(forbidden, [])
    assert File.read!(marker) == "witness"
    File.rm!(marker)
    File.chmod!(c.tools, 0o500)
    policy!(c, %{c.policy | "read_roots" => [c.tools]})

    try do
      assert {:ok, {_output, status}} = ExecutionBoundary.run(c.workspace, quote_shell(forbidden))
      assert status != 0
      refute File.exists?(marker)
    after
      File.chmod!(c.tools, 0o700)
    end
  end

  test "nonzero candidate exit stays a failed command with its output", c do
    policy!(c)

    assert %{status: :failed, output: "expected", error: nil} =
             RunInspector.run_validation(c.workspace, %RepoHarness{validation_command: "printf expected; exit 17"})
  end

  test "expired absolute deadline cannot prepare resources or launch", c do
    policy!(c)
    {:ok, selection} = Config.execution_boundary()
    assert {:error, :timeout} = SymphonyElixir.OwnedHook.run_boundary("printf wrong > late", c.workspace, selection, System.monotonic_time(:millisecond) - 1)
    refute File.exists?(Path.join(c.workspace, "late"))
  end

  test "native deadline at 500ms returns timeout without leaving new private roots", c do
    deadline_shell!(c, 500)
    before = private_roots()
    assert {:error, :timeout} = ExecutionBoundary.run(c.workspace, "record-private-roots-and-wait")
    assert MapSet.difference(private_roots(), before) == MapSet.new()
  end

  test "native deadline closes a witnessed running candidate before private roots are removed", c do
    deadline_shell!(c, 5000)
    before = private_roots()
    marker = Path.join(c.workspace, "private-roots")
    task = Task.async(fn -> ExecutionBoundary.run(c.workspace, "record-private-roots-and-wait") end)

    try do
      [_, _] = await_lines(marker, 250)
      assert File.exists?(marker)
      [home, tmp] = File.read!(marker) |> String.split("\n", trim: true)
      assert File.dir?(home)
      assert File.dir?(tmp)
      assert {:error, :timeout} = Task.await(task, 8000)
      refute File.exists?(home)
      refute File.exists?(tmp)
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      Enum.each(MapSet.difference(private_roots(), before), &await_absent(&1, 250))
    end
  end

  test "caller DOWN closes a running command and custodian removes its private roots", c do
    policy!(c, c.policy, 10_000)
    marker = Path.join(c.workspace, "private-roots")
    caller = spawn(fn -> ExecutionBoundary.run(c.workspace, "printf '%s\\n%s\\n' \"$HOME\" \"$TMPDIR\" > private-roots; while :; do :; done") end)
    monitor = Process.monitor(caller)

    try do
      [home, tmp] = await_lines(marker, 250)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 5_000
      assert Path.dirname(home) == Path.dirname(tmp)
      await_absent(Path.dirname(home), 250)
      refute File.exists?(home)
      refute File.exists?(tmp)
    after
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp deadline_shell!(c, timeout) do
    source = Path.join(c.root, "deadline-shell.c")
    executable = Path.join(c.tools, "deadline-shell")

    File.write!(source, """
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    int main(int argc, char **argv) {
      if (argc != 3 || strcmp(argv[1], "-c") || strcmp(argv[2], "record-private-roots-and-wait")) return 64;
      const char *home = getenv("HOME"), *tmp = getenv("TMPDIR");
      if (!home || !tmp) return 65;
      FILE *file = fopen("private-roots", "w"); if (!file) return 66;
      int written = fprintf(file, "%s\\n%s\\n", home, tmp);
      int closed = fclose(file);
      if (written < 0 || closed != 0) return 67;
      for (;;) {}
    }
    """)

    cc = System.find_executable("cc") || flunk("the native build compiler is unavailable")
    assert {_, 0} = System.cmd(cc, ["-Wall", "-Wextra", "-Werror", source, "-o", executable], stderr_to_stdout: true)
    File.chmod!(executable, 0o500)
    policy!(c, %{c.policy | "shell" => executable, "executables" => [tool(executable)]}, timeout)
  end

  defp private_roots do
    for {directory, prefix} <- [{System.tmp_dir!(), "symphony-owned-hook-"}, {"/private/tmp", "symphony-boundary-"}],
        name <- File.ls!(directory),
        String.starts_with?(name, prefix),
        into: MapSet.new() do
      Path.join(directory, name)
    end
  end

  defp policy!(c, policy \\ nil, timeout \\ 5000) do
    if File.exists?(c.policy_path), do: File.chmod!(c.policy_path, 0o600)
    bytes = Jason.encode!(policy || c.policy)
    File.write!(c.policy_path, bytes)
    File.chmod!(c.policy_path, 0o400)
    selected!(c, selection(c, digest(bytes), timeout))
  end

  defp selected!(c, selection) do
    yaml = "execution_boundary: #{Jason.encode!(selection)}\n"
    File.write!(Workflow.workflow_file_path(), String.replace(c.base_workflow, "---\n", "---\n" <> yaml, global: false))
    :ok = WorkflowStore.force_reload()
  end

  defp selection(c, sha, timeout \\ 5000), do: %{"policy_file" => c.policy_path, "sha256" => sha, "timeout_ms" => timeout}
  defp tool(path), do: %{"path" => path, "sha256" => digest(File.read!(path))}
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp await_lines(_path, 0), do: flunk("candidate never wrote its private roots")

  defp await_lines(path, attempts) do
    case File.read(path) do
      {:ok, bytes} ->
        case String.split(bytes, "\n", trim: true) do
          [home, tmp] ->
            [home, tmp]

          _partial ->
            Process.sleep(20)
            await_lines(path, attempts - 1)
        end

      {:error, :enoent} ->
        Process.sleep(20)
        await_lines(path, attempts - 1)

      {:error, reason} ->
        flunk("root witness unreadable: #{inspect(reason)}")
    end
  end

  defp await_absent(path, attempts) do
    cond do
      not File.exists?(path) ->
        :ok

      attempts == 0 ->
        flunk("custodian left private resources")

      true ->
        Process.sleep(20)
        await_absent(path, attempts - 1)
    end
  end
end
