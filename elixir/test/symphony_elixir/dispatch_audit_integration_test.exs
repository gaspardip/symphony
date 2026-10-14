defmodule SymphonyElixir.DispatchAuditIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, GitManager, LeaseManager, RunLedger, RunStateStore}
  alias SymphonyElixir.Orchestrator.State

  defmodule OwnerHarness do
    use GenServer
    alias SymphonyElixir.Orchestrator

    def init({runtime, observer}),
      do: {:ok, %{runtime: runtime, observer: observer, authorization: nil, hold_down?: false, down: nil}}

    def handle_call({:dispatch, issue}, _from, state) do
      runtime = Orchestrator.dispatch_runtime_issue(state.runtime, issue, nil)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call({:dispatch_held_start, issue}, _from, state) do
      start_child = fn supervisor, job ->
        Task.Supervisor.start_child(supervisor, fn ->
          receive do
            :release_worker -> job.()
          end
        end)
      end

      spawn_worker = fn runtime, issue, attempt, recipient ->
        Orchestrator.do_spawn_issue_worker_for_test(runtime, issue, attempt, recipient, start_child_fun: start_child)
      end

      # Existing seam controls only scheduling. Lease acquisition, admission,
      # worker creation, the authorization callback and DOWN handler are real.
      runtime = Orchestrator.do_dispatch_issue_for_test(state.runtime, issue, nil, spawn_fun: spawn_worker)

      {:reply, runtime, %{state | runtime: runtime, hold_down?: true}}
    end

    def handle_call(:deliver_down, _from, %{down: message} = state) when not is_nil(message) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:reply, runtime, %{state | runtime: runtime, down: nil, hold_down?: false}}
    end

    def handle_call(:authorize, _from, %{authorization: message} = state)
        when not is_nil(message) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:reply, runtime, %{state | runtime: runtime, authorization: nil}}
    end

    def handle_call({:stop, id, cleanup?}, _from, state) do
      runtime = Orchestrator.terminate_running_issue(state.runtime, id, cleanup?)
      {:reply, runtime, %{state | runtime: runtime}}
    end

    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

    def handle_call(message, from, state) do
      {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      {:reply, reply, %{state | runtime: runtime}}
    end

    def handle_info({:authorize_dispatch, id, dispatch_id, pid} = message, state) do
      # This is a real subsequent GenServer callback. Its runtime was installed
      # by the preceding dispatch call before the queued authorization arrived.
      send(
        state.observer,
        {:authorization_held, self(), id, dispatch_id, pid, state.runtime.running[id]}
      )

      {:noreply, %{state | authorization: message}}
    end

    def handle_info(
          {:DOWN, _ref, :process, _pid, _reason} = message,
          %{hold_down?: true} = state
        ) do
      send(state.observer, {:down_held, self(), message})
      {:noreply, %{state | down: message}}
    end

    def handle_info(message, state) do
      case Orchestrator.handle_info(message, state.runtime) do
        {:noreply, runtime} -> {:noreply, %{state | runtime: runtime}}
      end
    end
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "dispatch-audit-integration-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner-install"),
      max_concurrent_agents: 1,
      codex_command: "printf invoked > .symphony/provider-invoked; exit 99",
      hook_before_run: "printf 'hook-ran\\n' > .symphony/hook-executed; exit 27"
    )

    issue = %Issue{
      id: "dispatch-audit-issue",
      identifier: "DISPATCH-AUDIT-ISSUE",
      title: "Audit integration",
      state: "In Progress",
      source: :tracker,
      labels: []
    }

    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)

    for args <- [["init", "-q"], ["checkout", "-q", "-b", GitManager.issue_branch_name(issue)]] do
      assert {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, ".gitignore"), ".symphony/\n")
    File.write!(Path.join(workspace, "keep.txt"), "workspace must survive uncertain audit\n")

    assert {_, 0} =
             System.cmd("git", ["add", ".gitignore", "keep.txt"],
               cd: workspace,
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-c",
                 "user.name=Local Probe",
                 "-c",
                 "user.email=probe@invalid",
                 "-c",
                 "core.hooksPath=/dev/null",
                 "commit",
                 "-q",
                 "-m",
                 "fixture"
               ],
               cd: workspace,
               stderr_to_stdout: true
             )

    # Preparation uses a healthy ledger. Fault injection occurs only in tests.
    assert {:ok, _} =
             RunStateStore.transition(
               workspace,
               Map.get(context, :dispatch_stage, "implement"),
               %{issue_id: issue.id, issue_identifier: issue.identifier}
             )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    File.write!(
      Path.join(bin, "gh"),
      "#!/bin/sh\nprintf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n"
    )

    File.chmod!(Path.join(bin, "gh"), 0o700)
    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> old_path)
    lease = LeaseManager.lease_path(issue.id)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(lease)
      File.rm_rf!(lease <> ".lock")
      File.rm_rf!(root)
    end)

    %{issue: issue, workspace: workspace, root: root}
  end

  for stage <- ["implement", "await_checks"] do
    @tag dispatch_stage: stage
    test "#{stage} ledger ENOTDIR denies worker creation and retry", context do
      owner = owner_harness()
      before_workers = MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor))
      ledger_fault!(context.root)
      runtime = GenServer.call(owner, {:dispatch, context.issue})
      assert runtime.running == %{}
      assert runtime.retry_attempts == %{}
      assert {:dispatch_audit_failed, id, _reason} = runtime.candidate_fetch_error
      assert id == context.issue.id
      assert MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor)) == before_workers
      refute File.exists?(Path.join(context.workspace, ".symphony/hook-executed"))
      refute File.exists?(Path.join(context.workspace, ".symphony/provider-invoked"))
      refute_received {:authorization_held, ^owner, _, _, _, _}
      assert {:error, :enotdir} = File.read(RunLedger.ledger_file_path())

      assert File.read!(Path.join(context.workspace, "keep.txt")) ==
               "workspace must survive uncertain audit\n"
    end
  end

  for field <- ["issue_id", "issue_identifier"] do
    @tag conflicting_identity_field: field
    test "I1-14 conflicting #{field} blocks the orchestrator before lease snapshot overwrite", context do
      path = RunStateStore.state_path(context.workspace)
      conflicting = File.read!(path) |> Jason.decode!() |> Map.put(context.conflicting_identity_field, "other-issue") |> Jason.encode!()
      File.write!(path, conflicting)
      ledger = File.read!(RunLedger.ledger_file_path())
      owner = owner_harness()
      workers = MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor))
      runtime = GenServer.call(owner, {:dispatch, context.issue})
      assert runtime.running == %{}
      assert runtime.retry_attempts == %{}
      assert File.read!(path) == conflicting
      assert File.read!(RunLedger.ledger_file_path()) == ledger
      assert MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor)) == workers
      refute File.exists?(Path.join(context.workspace, ".symphony/hook-executed"))
      refute File.exists?(Path.join(context.workspace, ".symphony/provider-invoked"))
      refute_received {:authorization_held, ^owner, _, _, _, _}
    end
  end

  test "I1-13 identity persisted but authorization fails before worker creation", context do
    handler = "identity-admission-fault-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.identity_boundary_fault/4, context.issue.id)
    on_exit(fn -> :telemetry.detach(handler) end)
    owner = owner_harness()
    workers = MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor))
    runtime = GenServer.call(owner, {:dispatch, context.issue})
    assert runtime.running == %{}
    assert runtime.retry_attempts == %{}
    assert {:dispatch_audit_failed, _, _} = runtime.candidate_fetch_error
    assert MapSet.new(Task.Supervisor.children(SymphonyElixir.TaskSupervisor)) == workers
    assert {:ok, snapshot} = RunStateStore.load(context.workspace)
    assert is_binary(snapshot.run_id)
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
    refute File.exists?(Path.join(context.workspace, ".symphony/hook-executed"))
    refute File.exists?(Path.join(context.workspace, ".symphony/provider-invoked"))
    refute_received {:authorization_held, ^owner, _, _, _, _}
  end

  def identity_boundary_fault(_event, _measurements, metadata, issue_id) do
    if metadata[:event_type] == "run.identity.adopted" and metadata[:issue_id] == issue_id,
      do: File.write!(RunLedger.ledger_file_path(), "{torn", [:append])
  end

  test "worker body waits until a callback sees its installed running ticket", context do
    owner = owner_harness()
    runtime = GenServer.call(owner, {:dispatch, context.issue})
    id = context.issue.id
    assert %{pid: worker, dispatch_ticket: ticket} = runtime.running[id]
    assert_receive {:authorization_held, ^owner, ^id, dispatch_id, ^worker, installed}, 5_000
    assert dispatch_id == ticket.dispatch_id
    assert installed.pid == worker
    assert installed.dispatch_ticket == ticket
    assert Process.alive?(worker)
    refute File.exists?(Path.join(context.workspace, ".symphony/hook-executed"))

    assert {:error, {:dispatch_audit_pending, workspace}} =
             DispatchAudit.ensure_available(context.workspace)

    assert workspace == Path.expand(context.workspace)
    assert {:ok, confirmed} = RunLedger.fetch_entry_checked(ticket.entry_event_id)
    assert confirmed["metadata"]["dispatch_id"] == ticket.dispatch_id
    ref = Process.monitor(worker)
    GenServer.call(owner, :authorize)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
    assert File.read!(Path.join(context.workspace, ".symphony/hook-executed")) == "hook-ran\n"
    refute File.exists?(Path.join(context.workspace, ".symphony/provider-invoked"))
  end

  test "owner death cancels waiting worker and preserves journal against fresh admission and cleanup",
       context do
    owner = owner_harness()
    runtime = GenServer.call(owner, {:dispatch, context.issue})
    id = context.issue.id
    assert %{pid: worker} = runtime.running[id]
    assert_receive {:authorization_held, ^owner, ^id, _, ^worker, _}, 5_000
    marker_path = Path.join(DispatchAudit.marker_directory(context.workspace), "marker.json")
    marker_before = File.read!(marker_path)
    ref = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
    refute File.exists?(Path.join(context.workspace, ".symphony/hook-executed"))
    assert File.read!(marker_path) == marker_before

    assert {:error, {:dispatch_audit_pending, _}} =
             DispatchAudit.ensure_available(context.workspace)

    fresh_owner = owner_harness()
    fresh = GenServer.call(fresh_owner, {:dispatch, context.issue})
    assert fresh.running == %{}
    assert fresh.retry_attempts == %{}
    assert {:dispatch_audit_pending, _} = fresh.candidate_fetch_error
    assert {:error, {:dispatch_audit_pending, _}, ""} = Workspace.remove(context.workspace)
    assert File.read!(marker_path) == marker_before

    assert File.read!(Path.join(context.workspace, "keep.txt")) ==
             "workspace must survive uncertain audit\n"
  end

  test "stop with failed outcome audit preserves workspace and pending journal without retry",
       context do
    owner = owner_harness()
    runtime = GenServer.call(owner, {:dispatch, context.issue})
    id = context.issue.id
    assert %{pid: worker} = runtime.running[id]
    assert_receive {:authorization_held, ^owner, ^id, _, ^worker, _}, 5_000
    marker_path = Path.join(DispatchAudit.marker_directory(context.workspace), "marker.json")
    marker_before = File.read!(marker_path)
    ref = Process.monitor(worker)
    ledger_fault!(context.root)
    stopped = GenServer.call(owner, {:stop, id, true})
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
    assert stopped.running == %{}
    assert stopped.retry_attempts == %{}
    assert {:dispatch_audit_failed, ^id, _reason} = stopped.candidate_fetch_error
    assert File.read!(marker_path) == marker_before

    assert {:error, {:dispatch_audit_pending, _}} =
             DispatchAudit.ensure_available(context.workspace)

    assert File.read!(Path.join(context.workspace, "keep.txt")) ==
             "workspace must survive uncertain audit\n"

    refute File.exists?(Path.join(context.workspace, ".symphony/hook-executed"))
    # A previously queued authorization cannot execute after stop removed running.
    GenServer.call(owner, :authorize)
    refute File.exists?(Path.join(context.workspace, ".symphony/hook-executed"))
  end

  test "worker authorization failure stays pending when ledger recovers before DOWN", context do
    owner = owner_harness()
    runtime = GenServer.call(owner, {:dispatch_held_start, context.issue})
    id = context.issue.id
    assert %{pid: worker, dispatch_ticket: ticket, lease_token: token} = runtime.running[id]
    assert_receive {:authorization_held, ^owner, ^id, dispatch_id, ^worker, _}, 5_000
    assert dispatch_id == ticket.dispatch_id
    marker_path = Path.join(DispatchAudit.marker_directory(context.workspace), "marker.json")
    marker_before = File.read!(marker_path)

    # The callback validates a healthy admission and sends authorization; the
    # worker is still held before DispatchGate.run, so the message stays queued.
    GenServer.call(owner, :authorize)
    assert Process.alive?(worker)
    ledger_fault!(context.root)
    send(worker, :release_worker)

    assert_receive {:down_held, ^owner, {:DOWN, _ref, :process, ^worker, {:accounting_uncertain, {:dispatch_authorization_failed, authorization_reason}}}},
                   2_000

    ledger = RunLedger.ledger_file_path()
    assert :ok = File.rm(ledger)
    assert :ok = File.rename(ledger <> ".healthy-before-fault", ledger)
    assert {:ok, _entry} = RunLedger.fetch_entry_checked(ticket.entry_event_id)

    stopped = GenServer.call(owner, :deliver_down)
    assert stopped.running == %{}
    assert stopped.retry_attempts == %{}
    refute Map.has_key?(stopped.completed, id)
    assert {:accounting_uncertain, ^id, {:dispatch_authorization_failed, ^authorization_reason}} = stopped.candidate_fetch_error
    assert stopped.lease_claims[id].token == token
    assert File.read!(marker_path) == marker_before
    assert {:error, {:dispatch_audit_pending, _}} = DispatchAudit.ensure_available(context.workspace)
    refute File.exists?(Path.join(context.workspace, ".symphony/hook-executed"))
    refute File.exists?(Path.join(context.workspace, ".symphony/provider-invoked"))
  end

  defp owner_harness do
    runtime = %State{
      lease_owner: "audit-owner-#{System.unique_integer([:positive])}",
      max_concurrent_agents: 1,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
    }

    assert {:ok, owner} = GenServer.start(OwnerHarness, {runtime, self()})

    on_exit(fn ->
      if Process.alive?(owner) do
        runtime = GenServer.call(owner, :runtime)

        workers =
          Enum.map(runtime.running, fn {_id, entry} -> {entry.pid, Process.monitor(entry.pid)} end)

        ref = Process.monitor(owner)
        Process.exit(owner, :kill)

        receive do
          {:DOWN, ^ref, :process, ^owner, _} -> :ok
        after
          5_000 -> raise "test owner did not terminate"
        end

        Enum.each(workers, fn {worker, worker_ref} ->
          receive do
            {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
          after
            5_000 -> raise "owned test worker survived its coordinator"
          end
        end)
      end
    end)

    owner
  end

  defp ledger_fault!(root) do
    path = RunLedger.ledger_file_path()
    assert :ok = File.rename(path, path <> ".healthy-before-fault")
    blocker = Path.join(root, "ledger-parent-is-file")
    File.write!(blocker, "intentional filesystem fault")
    File.ln_s!(Path.join(blocker, "ledger.jsonl"), path)
    assert {:error, :enotdir} = File.read(path)
  end
end
