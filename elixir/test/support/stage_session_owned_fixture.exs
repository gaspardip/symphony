Code.require_file("stage_session_fixture.exs", __DIR__)

defmodule SymphonyElixir.TestSupport.StageSessionOwnedFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias SymphonyElixir.{ProviderTransport, RunLedger, Workflow, WorkflowStore}
  alias SymphonyElixir.TestSupport.StageSessionFixture, as: Fixture

  def create! do
    c = Fixture.cli_fixture!("codex", "claude")
    transport = Path.join(c.root, "app-server")

    File.write!(transport, """
    #!/bin/bash
    set -eu
    printf '%s\\n' "$$" > provider.pid
    printf '%s\\n%s\\n' "$HOME" "$TMPDIR" > private-roots
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"stage-owned-thread"}}}' ;;
        *'"method":"turn/start"'*) exit 17 ;;
      esac
    done
    """)

    File.chmod!(transport, 0o500)

    policy = %{
      "version" => 1,
      "backend" => "macos_deny_default_v1",
      "workspace_root" => Path.join(c.root, "workspaces"),
      "shell" => "/bin/bash",
      "executables" => Enum.map(["/bin/bash", "/bin/sleep", "/usr/bin/true", transport], &tool/1),
      "read_roots" => []
    }

    bytes = Jason.encode!(policy)
    policy_path = Path.join(c.root, "policy.json")
    File.write!(policy_path, bytes)
    File.chmod!(policy_path, 0o400)
    selected = %{"policy_file" => policy_path, "sha256" => digest(bytes), "timeout_ms" => 5000}
    workflow = Workflow.workflow_file_path()
    text = File.read!(workflow)
    text = String.replace(text, ~r/^  command: .+$/m, "  command: " <> Jason.encode!(Fixture.quote_shell(transport) <> " app-server"))
    assert String.contains?(text, " app-server")
    File.write!(workflow, String.replace(text, "---\n", "---\nprovider_execution_boundary: #{Jason.encode!(selected)}\n", global: false))
    :ok = WorkflowStore.force_reload()

    ExUnit.Callbacks.on_exit(fn ->
      case File.read(Path.join(c.root, "captured-owned.json")) do
        {:ok, bytes} -> bytes |> Jason.decode!(keys: :atoms) |> cleanup_uncertain!()
        {:error, :enoent} -> :ok
        {:error, reason} -> flunk("owned physical identity receipt unavailable: #{inspect(reason)}")
      end
    end)

    c
  end

  def capture!(c, session) do
    {:owned_provider, custodian, caller, _, _} = handle = session.port
    assert caller == self() and Process.alive?(custodian)
    identity = ProviderTransport.metadata(handle)
    port = Enum.find(Port.list(), &(Port.info(&1, :os_pid) == {:os_pid, identity.helper}))
    assert is_port(port)
    {:name, artifact} = Port.info(port, :name)
    [home, _tmp] = File.read!(Path.join(c.workspace, "private-roots")) |> String.split("\n", trim: true)
    child = process_identity!(identity.child)
    helper = process_identity!(identity.helper)
    assert {pgid, 0} = System.cmd("/bin/ps", ["-p", to_string(identity.child), "-o", "pgid="])
    assert String.trim(pgid) == to_string(identity.pgid)
    tree = %{child: child, helper: helper, pgid: identity.pgid, resource: Path.dirname(home), artifact: to_string(artifact)}
    File.write!(Path.join(c.root, "captured-owned.json"), Jason.encode!(tree))
    tree
  end

  def kill_custodian!(session) do
    {:owned_provider, custodian, caller, _, _} = session.port
    assert caller == self() and Process.alive?(custodian)
    monitor = Process.monitor(custodian)
    Process.exit(custodian, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^custodian, :killed}, 5_000
    :ok
  end

  def assert_tree_absent!(tree) do
    await_tree_absent!(tree, System.monotonic_time(:millisecond) + 5_000)
  end

  def cleanup_uncertain!(tree) do
    assert_tree_absent!(tree)
    assert Path.dirname(tree.resource) == "/private/tmp"
    assert String.starts_with?(Path.basename(tree.resource), "symphony-boundary-")
    assert Path.dirname(Path.dirname(tree.artifact)) == Path.expand(System.tmp_dir!())
    assert Path.basename(tree.artifact) == "owner"
    assert String.starts_with?(Path.basename(Path.dirname(tree.artifact)), "symphony-owned-hook-")
    # Independent fixture cleanup after physical absence; never a product finish.
    if File.exists?(tree.resource) do
      for file <- ["boundary", "policy.sb"], do: File.rm!(Path.join(tree.resource, file))
      for directory <- ["home", "tmp"], do: File.rmdir!(Path.join(tree.resource, directory))
      File.rmdir!(tree.resource)
    end

    if File.exists?(tree.artifact) do
      File.rm!(tree.artifact)
      File.rmdir!(Path.dirname(tree.artifact))
    end

    assert_closed!(tree)
  end

  def assert_closed!(tree) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_closed!(tree, deadline)
  end

  def assert_receipts!(entry, certain) do
    assert [started, finished] = boundary_events()

    for event <- [started, finished] do
      assert event["metadata"]["run_id"] == entry.dispatch_ticket.run_id
      assert event["metadata"]["dispatch_id"] == entry.dispatch_ticket.dispatch_id
      assert {:ok, ^event} = RunLedger.fetch_entry_checked(event["event_id"])
    end

    assert finished["metadata"]["started_event_id"] == started["event_id"]
    assert finished["metadata"]["certain"] == certain
  end

  def boundary_events, do: RunLedger.recent_entries() |> Enum.filter(&String.starts_with?(&1["event_type"], "execution.boundary."))

  defp process_identity!(pid) do
    assert {identity, 0} = System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "pid=,pgid=,lstart="])
    %{pid: pid, identity: identity}
  end

  defp absent?(%{pid: pid}) do
    case System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "pid="]) do
      {text, 1} ->
        assert String.trim(text) == ""
        true

      {_text, 0} ->
        false
    end
  end

  defp await_tree_absent!(tree, deadline) do
    assert {groups, 0} = System.cmd("/bin/ps", ["-axo", "pgid="])
    absent = absent?(tree.child) and absent?(tree.helper) and to_string(tree.pgid) not in String.split(groups)

    unless absent do
      assert System.monotonic_time(:millisecond) < deadline, "actual owned process tree remains after custodian channel closure"
      Process.sleep(10)
      await_tree_absent!(tree, deadline)
    end

    :ok
  end

  defp await_closed!(tree, deadline) do
    assert {groups, 0} = System.cmd("/bin/ps", ["-axo", "pgid="])
    closed = absent?(tree.child) and absent?(tree.helper) and to_string(tree.pgid) not in String.split(groups) and not File.exists?(tree.resource) and not File.exists?(Path.dirname(tree.artifact))

    unless closed do
      assert System.monotonic_time(:millisecond) < deadline, "actual owned process tree or temporary resources remain after cleanup"
      Process.sleep(10)
      await_closed!(tree, deadline)
    end

    :ok
  end

  defp tool(path), do: %{"path" => path, "sha256" => digest(File.read!(path))}
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
