defmodule SymphonyElixir.RunStateCleanupAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RunLedger, RunStateStore, Workspace}

  @owned_tasks {__MODULE__, :owned_tasks}

  setup do
    root = Path.join(System.tmp_dir!(), "run-state-cleanup-audit-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "CLEANUP-AUDIT-1")
    File.mkdir_p!(root)
    Process.put(@owned_tasks, [])
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, issue_id: "cleanup-audit-1", identifier: "CLEANUP-AUDIT-1"}
  end

  for {operation, initial_stage} <- [remove: "implement", create: "blocked"] do
    test "#{operation} keeps the mutation lock throughout its hook and cleanup", context do
      operation = unquote(operation)
      initial_stage = unquote(initial_stage)
      attrs = %{issue_id: context.issue_id, issue_identifier: context.identifier}
      assert {:ok, _} = RunStateStore.transition(context.workspace, initial_stage, attrs)
      barrier = open_hook_barrier!(context.root)

      try do
        configure_hook(context, operation, barrier.command)
        cleanup = owned_task(fn -> cleanup(operation, context) end)
        await_hook_entered(barrier.port)

        # Same immediate mutex oracle as RunStateConcurrencyTest. No elapsed-time
        # assumption is needed to prove that the real hook owns the mutation lock.
        assert_cleanup_holds_lock(context.workspace)
        parent = self()

        transition =
          owned_task(fn ->
            send(parent, {:transition_started, self()})
            RunStateStore.transition(context.workspace, "verify", attrs)
          end)

        assert_receive {:transition_started, pid}, 5_000
        assert pid == transition.pid
        assert Task.yield(transition, 0) == nil
        release_hook(barrier)

        assert {:ok, _} = Task.await(cleanup, 5_000)
        assert {:ok, transitioned} = Task.await(transition, 5_000)
        assert {:ok, persisted} = RunStateStore.load(context.workspace)
        assert persisted == transitioned
        assert persisted.stage == "verify"
        assert persisted.issue_id == context.issue_id
        assert persisted.stage_transition_counts == %{"verify" => 1}
        assert File.regular?(RunStateStore.state_path(context.workspace))
        assert {:ok, row} = RunLedger.fetch_entry_checked(persisted.last_ledger_event_id)
        assert row["stage"] == "verify"
        assert row["event_type"] == "stage.transition"
        assert row["issue_id"] == context.issue_id
      after
        # Release before waiting for owned tasks, even when an assertion fails.
        # Both FIFO descriptors belong to this test process and remain open until
        # its shell hook and reader have had an opportunity to leave normally.
        release_hook(barrier)
        cleanup_owned_tasks()
        close_hook_barrier(barrier)
      end
    end
  end

  test "a pending transition created before removal preserves snapshot and evidence without running hooks", context do
    attrs = %{issue_id: context.issue_id, issue_identifier: context.identifier}
    assert {:ok, _} = RunStateStore.transition(context.workspace, "implement", attrs)
    marker = Path.join(context.root, "hook-must-not-run")
    evidence = Path.join(context.workspace, "pending-evidence.txt")
    File.write!(evidence, "preserve pending evidence\n")
    handler = "cleanup-audit-barrier-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.confirmation_barrier/4, {self(), context.issue_id})

    try do
      transition = owned_task(fn -> RunStateStore.transition(context.workspace, "verify") end)
      assert_receive {:confirmation_pending, pid}, 5_000
      assert pid == transition.pid
      Process.exit(transition.pid, :kill)
      assert {:exit, :killed} = Task.yield(transition, 5_000)
      assert {:error, {:audit_pending, operation_id}} = RunStateStore.load(context.workspace)
      assert is_binary(operation_id)
      snapshot = File.read!(RunStateStore.state_path(context.workspace))
      ledger = File.read!(RunLedger.ledger_file_path())
      hook = "printf 'hook ran\\n' > " <> shell_quote(marker)
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: context.root, hook_before_remove: hook, hook_after_create: hook)

      assert {:error, {:run_state_unreadable, {:audit_pending, ^operation_id}}, ""} = Workspace.remove(context.workspace)
      assert {:error, {:run_state_unreadable, {:audit_pending, ^operation_id}}, ""} = Workspace.remove_issue_workspaces(context.identifier)
      assert {:error, {:run_state_unreadable, {:audit_pending, ^operation_id}}} = Workspace.create_for_issue(context.identifier)
      refute File.exists?(marker)
      assert File.read!(RunStateStore.state_path(context.workspace)) == snapshot
      assert File.read!(evidence) == "preserve pending evidence\n"
      assert File.read!(RunLedger.ledger_file_path()) == ledger
      assert {:error, {:audit_pending, ^operation_id}} = RunStateStore.load(context.workspace)
    after
      :telemetry.detach(handler)
      cleanup_owned_tasks()
    end
  end

  @spec confirmation_barrier(term(), map(), map(), {pid(), String.t()}) :: :ok
  def confirmation_barrier(_event, _measurements, metadata, {owner, issue_id}) do
    if metadata[:event_type] == "stage.transition" and metadata[:issue_id] == issue_id and metadata[:stage] == "verify" do
      send(owner, {:confirmation_pending, self()})

      receive do
        :release_confirmation -> :ok
      after
        10_000 -> raise "Owned confirmation barrier was not released"
      end
    end

    :ok
  end

  defp configure_hook(context, :remove, command) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: context.root, hook_before_remove: command, hook_timeout_ms: 15_000)
  end

  defp configure_hook(context, :create, command) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: context.root, hook_after_create: command, hook_timeout_ms: 15_000)
  end

  defp cleanup(:remove, context), do: Workspace.remove(context.workspace)
  defp cleanup(:create, context), do: Workspace.create_for_issue(context.identifier)

  defp assert_cleanup_holds_lock(workspace) do
    lock = {{RunStateStore, Path.expand(workspace)}, self()}
    acquired = :global.set_lock(lock, [node()], 0)
    if acquired, do: :global.del_lock(lock, [node()])
    refute acquired, "The workspace hook ran without retaining the snapshot mutation lock"
  end

  defp owned_task(fun) do
    task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fun)
    Process.put(@owned_tasks, [task | Process.get(@owned_tasks, [])])
    task
  end

  defp cleanup_owned_tasks do
    for task <- Process.delete(@owned_tasks) || [], Process.alive?(task.pid) do
      send(task.pid, :release_confirmation)
      Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    end
  end

  defp open_hook_barrier!(root) do
    ready = Path.join(root, "hook-ready.fifo")
    release = Path.join(root, "hook-release.fifo")
    mkfifo = System.find_executable("mkfifo") || raise "mkfifo is required for this local POSIX hook fixture"
    {_, 0} = System.cmd(mkfifo, [ready, release], stderr_to_stdout: true)
    # O_RDWR prevents open/write deadlocks during cleanup before the hook starts.
    {:ok, ready_device} = :file.open(String.to_charlist(ready), [:read, :write, :raw, :binary])
    {:ok, release_device} = :file.open(String.to_charlist(release), [:read, :write, :raw, :binary])
    shell = System.find_executable("sh") || raise "sh is required for workspace hooks"
    reader = "IFS= read -r signal < " <> shell_quote(ready) <> "; printf '%s\\n' \"$signal\""
    port = Port.open({:spawn_executable, String.to_charlist(shell)}, [:binary, :exit_status, args: ["-c", reader]])
    command = "printf 'hook-entered\\n' > " <> shell_quote(ready) <> "; IFS= read -r signal < " <> shell_quote(release)
    %{port: port, ready_device: ready_device, release_device: release_device, command: command}
  end

  defp await_hook_entered(port, output \\ "") do
    receive do
      {^port, {:data, bytes}} ->
        await_hook_entered(port, output <> bytes)

      {^port, {:exit_status, status}} ->
        assert status == 0
        assert output == "hook-entered\n"
    after
      5_000 -> flunk("Owned hook did not reach the FIFO barrier")
    end
  end

  defp release_hook(barrier), do: :ok = :file.write(barrier.release_device, "continue\n")

  defp close_hook_barrier(barrier) do
    # If an assertion failed before readiness, release the owned reader too.
    :ok = :file.write(barrier.ready_device, "cancel\n")

    if Port.info(barrier.port) != nil do
      receive do
        {port, {:exit_status, _}} when port == barrier.port -> :ok
      after
        5_000 -> Port.close(barrier.port)
      end
    end

    :ok = :file.close(barrier.ready_device)
    :ok = :file.close(barrier.release_device)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
