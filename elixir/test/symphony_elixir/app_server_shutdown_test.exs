defmodule SymphonyElixir.AppServerShutdownTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{Config, Workflow, WorkflowStore}
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.AppServerShutdownTest.HookFixture
  alias SymphonyElixir.Linear.Issue

  # Pause an existing idle test scheduler without restarting it or replacing its
  # state. The isolated runner has no application scheduler to pause.
  setup context do
    pause_idle_scheduler!()
    evidence_root = Application.get_env(:shutdown_probe, :root)

    root =
      if is_binary(evidence_root) do
        name = context.test |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
        Path.join(evidence_root, name)
      else
        Path.join(System.tmp_dir!(), "symphony-app-server-shutdown-#{System.pid()}-#{System.unique_integer([:positive])}")
      end

    File.mkdir!(root)
    directory = File.cd!(root, &File.cwd!/0)

    previous_app =
      Enum.map([:workflow_file_path, :log_file, :memory_tracker_issues], fn key ->
        {key, Application.fetch_env(:symphony_elixir, key)}
      end)

    environment = [
      {"HOME", Path.join(directory, "home")},
      {"XDG_CONFIG_HOME", Path.join(directory, "home/config")},
      {"GH_CONFIG_DIR", Path.join(directory, "home/gh")},
      {"CODEX_HOME", Path.join(directory, "codex-home")},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"}
    ]

    previous_environment = Enum.map(environment, fn {key, _} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous_environment, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(previous_app, fn
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
      end)

      if Process.whereis(WorkflowStore), do: :ok = WorkflowStore.force_reload()
      if is_nil(evidence_root), do: File.rm_rf!(directory)
    end)

    for name <- ["home/config", "home/gh", "codex-home"], do: File.mkdir_p!(Path.join(directory, name))
    System.put_env(environment)
    Application.put_env(:symphony_elixir, :log_file, Path.join(directory, "log/symphony.log"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    workspace = Path.join(directory, "workspaces/PROBE")
    File.mkdir_p!(workspace)

    python =
      Application.get_env(:shutdown_probe, :python) || System.find_executable("python3") ||
        raise "Python 3 is required for the local JSONL shutdown fixture"

    provider = Path.join(directory, "provider.py")
    File.write!(provider, provider_script(), [:exclusive])
    command = Enum.map_join([python, provider, directory, context.phase], " ", &quote_shell/1)

    config = %{
      tracker: %{kind: "memory"},
      workspace: %{root: Path.join(directory, "workspaces")},
      runner: %{install_root: Path.join(directory, "runner")},
      manual: %{enabled: false, store_root: Path.join(directory, "manual")},
      company: %{author_profile_path: Path.join(directory, "author.json"), credential_registry_path: Path.join(directory, "credentials.json")},
      agent: %{turn_timeout_ms: 20_000, read_timeout_ms: 20_000, codex: %{command: command, runtime_profile: %{inherit_env: true, codex_home: Path.join(directory, "codex-home")}}},
      policy: %{publish_required: false, automerge_on_green: false}
    }

    workflow = Path.join(directory, "WORKFLOW.md")
    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nLocal cancellation regression.\n", [:exclusive])
    :ok = Workflow.set_workflow_file_path(workflow)
    :ok = WorkflowStore.force_reload()
    20_000 = Config.agent_read_timeout_ms()
    20_000 = Config.agent_turn_timeout_ms()
    :ok = assert_scheduler_paused!()
    supervisor = start_supervised!({Task.Supervisor, []})
    issue = %Issue{id: "local-cancel-probe", identifier: "PROBE", title: "Local cancellation regression", state: "In Progress", description: "Controlled stdio fixture", labels: []}
    {:ok, directory: directory, workspace: workspace, supervisor: supervisor, issue: issue, command: command, config: config, workflow: workflow}
  end

  for phase <- ["initialize", "thread/start", "turn/start", "stream"] do
    @tag phase: phase
    test "supervisor shutdown is honored in #{phase}", context do
      {worker, monitor, port, ready} = start_at_barrier(context)
      started = System.monotonic_time(:millisecond)
      :ok = Task.Supervisor.terminate_child(context.supervisor, worker)
      reason = down(monitor, worker)
      eof = wait_value(fn -> read_optional(context.directory, "provider-exit.json") end)

      checks = %{
        shutdown_reason: reason == :shutdown,
        after_executed: File.regular?(Path.join(context.directory, "after.json")),
        port_closed: Port.info(port) == nil,
        provider_owner_eof: eof["reason"] == "owner_eof"
      }

      record(context, checks, %{reason: inspect(reason), elapsed_ms: System.monotonic_time(:millisecond) - started, provider: ready, worker: inspect(worker), port: inspect(port)})
      assert Enum.all?(checks, fn {_, value} -> value end), inspect(checks)
    end
  end

  @tag phase: "stream"
  test "direct PID shutdown is honored without the supervisor request", context do
    {worker, monitor, port, ready} = start_at_barrier(context)
    true = Process.exit(worker, :shutdown)

    initial =
      receive do
        {:DOWN, ^monitor, :process, ^worker, reason} -> {:received, reason}
      after
        1_000 -> :not_observed
      end

    reason =
      case initial do
        {:received, reason} ->
          reason

        :not_observed ->
          :ok = Task.Supervisor.terminate_child(context.supervisor, worker)
          down(monitor, worker)
      end

    eof = wait_value(fn -> read_optional(context.directory, "provider-exit.json") end)

    checks = %{
      direct_shutdown_observed: initial == {:received, :shutdown},
      shutdown_reason: reason == :shutdown,
      after_executed: File.regular?(Path.join(context.directory, "after.json")),
      port_closed: Port.info(port) == nil,
      provider_owner_eof: eof["reason"] == "owner_eof"
    }

    record(context, checks, %{initial: inspect(initial), final_reason: inspect(reason), provider: ready, cleanup_termination_required: initial == :not_observed})
    assert Enum.all?(checks, fn {_, value} -> value end), inspect(checks)
  end

  @tag phase: "initialize"
  test "captured startup shutdown closes port while its owner remains alive", context do
    parent = self()

    {:ok, worker} =
      Task.Supervisor.start_child(context.supervisor, fn ->
        outcome =
          try do
            {:returned, AppServer.start_session(context.workspace, codex_command: context.command)}
          catch
            :exit, reason -> {:caught, reason}
          end

        send(parent, {:startup_outcome, self(), outcome, Process.info(self(), :trap_exit)})

        receive do
          :finish_observation -> :ok
        after
          15_000 -> raise "Caller observation was not released"
        end
      end)

    monitor = Process.monitor(worker)
    {port, ready} = barrier(context, worker)
    true = Process.exit(worker, :shutdown)

    outcome =
      receive do
        {:startup_outcome, ^worker, result, flag} -> %{result: result, trap_exit: flag}
      after
        1_000 -> nil
      end

    owner_alive = Process.alive?(worker)
    port_closed_while_owner_alive = Port.info(port) == nil

    if outcome do
      send(worker, :finish_observation)
    else
      :ok = Task.Supervisor.terminate_child(context.supervisor, worker)
    end

    final_reason = down(monitor, worker)
    eof = wait_value(fn -> read_optional(context.directory, "provider-exit.json") end)

    checks = %{
      caught_shutdown: outcome != nil and outcome.result == {:caught, :shutdown},
      owner_kept_alive: owner_alive,
      original_trap_exit_restored: outcome != nil and outcome.trap_exit == {:trap_exit, false},
      port_closed_before_owner_exit: port_closed_while_owner_alive,
      normal_owner_exit: final_reason == :normal,
      provider_owner_eof: eof["reason"] == "owner_eof"
    }

    record(context, checks, %{caught: inspect(outcome), final_reason: inspect(final_reason), provider: ready, cleanup_termination_required: outcome == nil})
    assert Enum.all?(checks, fn {_, value} -> value end), inspect(checks)
  end

  @tag phase: "complete"
  test "uncancelled session still completes and cleans up", context do
    {worker, monitor, port, ready} = start_at_barrier(context)
    File.write!(Path.join(context.directory, "complete"), "Complete the declared test turn.\n", [:exclusive])
    reason = down(monitor, worker)

    result =
      receive do
        {:worker_result, ^worker, result} -> result
      after
        1_000 -> flunk("Worker result was not delivered")
      end

    eof = wait_value(fn -> read_optional(context.directory, "provider-exit.json") end)

    checks = %{
      normal_owner_exit: reason == :normal,
      successful_result: match?({:ok, %{result: :turn_completed}}, result),
      after_executed: File.regular?(Path.join(context.directory, "after.json")),
      port_closed: Port.info(port) == nil,
      provider_owner_eof: eof["reason"] == "owner_eof"
    }

    record(context, checks, %{reason: inspect(reason), result: inspect(result), provider: ready})
    assert Enum.all?(checks, fn {_, value} -> value end), inspect(checks)
  end

  @tag phase: "port_error"
  test "spontaneous provider exit remains an explicit port error", context do
    result = AppServer.run(context.workspace, "Observe controlled exit.", context.issue, codex_command: context.command)
    checks = %{port_error_preserved: result == {:error, {:port_exit, 17}}}
    record(context, checks, %{result: inspect(result)})
    assert checks.port_error_preserved
  end

  @tag phase: "initialize"
  test "AgentRunner executes after_run once after closing the startup port", context do
    fixture = HookFixture.prepare!(context.directory, context.workspace, context.issue, context.config)
    File.write!(context.workflow, "---\n" <> Jason.encode!(fixture.config) <> "\n---\nLocal AgentRunner cancellation.\n")
    :ok = Workflow.set_workflow_file_path(context.workflow)
    :ok = WorkflowStore.force_reload()
    original_environment = Enum.map(fixture.environment, fn {key, _} -> {key, System.get_env(key)} end)

    original_application_environment =
      Enum.map(fixture.application_environment, fn {app, key, _} ->
        {app, key, Application.fetch_env(app, key)}
      end)

    System.put_env(fixture.environment)
    Enum.each(fixture.application_environment, fn {app, key, value} -> Application.put_env(app, key, value) end)
    {:module, AppServer} = Code.ensure_loaded(AppServer)
    {:module, SymphonyElixir.Workspace} = Code.ensure_loaded(SymphonyElixir.Workspace)

    try do
      {worker, monitor} = HookFixture.start!(context.supervisor, fixture)
      {port, ready} = barrier(context, worker)
      1 = :erlang.trace_pattern({AppServer, :stop_port, 1}, [{:_, [], [{:return_trace}]}], [:local])
      1 = :erlang.trace_pattern({SymphonyElixir.Workspace, :run_after_run_hook, 2}, true, [:local])
      1 = :erlang.trace(worker, true, [:call, {:tracer, self()}])
      :ok = Task.Supervisor.terminate_child(context.supervisor, worker)
      reason = down(monitor, worker)
      reference = :erlang.trace_delivered(:all)
      trace = trace_events(reference, [])
      eof = wait_value(fn -> read_optional(context.directory, "provider-exit.json") end)

      hook_lines =
        case File.read(fixture.hook_path) do
          {:ok, text} -> String.split(text, "\n", trim: true)
          {:error, :enoent} -> []
          {:error, error} -> raise File.Error, reason: error, action: "read hook effect", path: fixture.hook_path
        end

      close_index = Enum.find_index(trace, &match?({:trace, ^worker, :return_from, {AppServer, :stop_port, 1}, _}, &1))
      hook_index = Enum.find_index(trace, &match?({:trace, ^worker, :call, {SymphonyElixir.Workspace, :run_after_run_hook, _}}, &1))

      checks = %{
        shutdown_reason: reason == :shutdown,
        port_closed: Port.info(port) == nil,
        provider_owner_eof: eof["reason"] == "owner_eof",
        hook_exactly_once: hook_lines == [context.workspace],
        close_completed_before_hook: close_index != nil and hook_index != nil and close_index < hook_index
      }

      record(context, checks, %{
        reason: inspect(reason),
        provider: ready,
        hook_lines: hook_lines,
        trace: Enum.map(trace, &inspect(&1, limit: :infinity)),
        fixture_commit: fixture.git_head,
        gh_reads: File.read!(fixture.gh_log)
      })

      assert Enum.all?(checks, fn {_, value} -> value end), inspect(checks)
    after
      :erlang.trace_pattern({AppServer, :stop_port, 1}, false, [:local])
      :erlang.trace_pattern({SymphonyElixir.Workspace, :run_after_run_hook, 2}, false, [:local])

      Enum.each(original_environment, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(original_application_environment, fn
        {app, key, :error} -> Application.delete_env(app, key)
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
      end)
    end
  end

  defp pause_idle_scheduler! do
    case Process.whereis(SymphonyElixir.Orchestrator) do
      nil ->
        :ok

      pid ->
        supervisor = Process.whereis(SymphonyElixir.Supervisor)
        assert is_pid(supervisor), "Refusing to pause an Orchestrator outside the application supervisor"

        assert Enum.any?(Supervisor.which_children(supervisor), fn
                 {SymphonyElixir.Orchestrator, ^pid, :worker, _} -> true
                 _ -> false
               end)

        {:status, ^pid, {:module, :gen_server}, [_, :running, _, _, _]} = :sys.get_status(pid)
        :ok = :sys.suspend(pid)
        # ExUnit runs this callback after the later environment restoration.
        on_exit(fn -> :ok = :sys.resume(pid) end)
        state = :sys.get_state(pid)
        assert state.running == %{}, "Refusing to pause a scheduler with active issue workers"

        assert Task.Supervisor.children(SymphonyElixir.TaskSupervisor) == [],
               "Refusing to run the fixture while application tasks are active"

        :ok
    end
  end

  defp assert_scheduler_paused! do
    case Process.whereis(SymphonyElixir.Orchestrator) do
      nil ->
        :ok

      pid ->
        assert {:status, ^pid, {:module, :gen_server}, [_, :suspended, _, _, _]} = :sys.get_status(pid)
        :ok
    end
  end

  defp trace_events(reference, events) do
    receive do
      {:trace_delivered, :all, ^reference} -> Enum.reverse(events)
      {:trace, _, _, _} = event -> trace_events(reference, [event | events])
      {:trace, _, _, _, _} = event -> trace_events(reference, [event | events])
    after
      2_000 -> flunk("Trace delivery was not confirmed")
    end
  end

  defp start_at_barrier(context) do
    parent = self()

    {:ok, worker} =
      Task.Supervisor.start_child(context.supervisor, fn ->
        try do
          result =
            AppServer.run(context.workspace, "Wait for local cancellation.", context.issue, codex_command: context.command, on_message: fn event -> send(parent, {:provider_event, self(), event}) end)

          send(parent, {:worker_result, self(), result})
        after
          write(context.directory, "after.json", %{worker: inspect(self()), at: DateTime.utc_now()})
        end
      end)

    monitor = Process.monitor(worker)
    {port, ready} = barrier(context, worker)

    if context.phase in ["stream", "complete"] do
      receive do
        {:provider_event, ^worker, %{event: :session_started}} -> :ok
      after
        5_000 -> flunk("Session never reached streaming")
      end

      stack =
        wait_value(fn ->
          case Process.info(worker, :current_stacktrace) do
            {:current_stacktrace, frames} ->
              if Enum.any?(frames, &match?({AppServer, :receive_loop, 6, _}, &1)), do: frames

            nil ->
              nil
          end
        end)

      write(context.directory, "streaming-stack.json", %{worker: inspect(worker), stack: inspect(stack)})
    end

    {worker, monitor, port, ready}
  end

  defp barrier(context, worker) do
    ready = wait_value(fn -> read_optional(context.directory, "provider-ready.json") end)
    {:links, links} = Process.info(worker, :links)
    [port] = Enum.filter(links, &is_port/1)
    {:os_pid, provider_pid} = Port.info(port, :os_pid)
    assert provider_pid == ready["pid"]
    write(context.directory, "barrier.json", %{worker: inspect(worker), port: inspect(port), provider: ready, trap_exit: inspect(Process.info(worker, :trap_exit)), phase: context.phase})
    {port, ready}
  end

  defp down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, reason} -> reason
    after
      7_000 -> flunk("Owned worker did not terminate")
    end
  end

  defp wait_value(fun), do: wait_value(fun, System.monotonic_time(:millisecond) + 5_000)

  defp wait_value(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "Local fixture observation deadline exceeded"
        Process.sleep(10)
        wait_value(fun, deadline)
    end
  end

  defp read_optional(root, name) do
    case File.read(Path.join(root, name)) do
      {:ok, content} -> Jason.decode!(content)
      {:error, :enoent} -> nil
      {:error, reason} -> raise File.Error, reason: reason, action: "read local fixture evidence", path: Path.join(root, name)
    end
  end

  defp record(context, checks, observations) do
    write(context.directory, "result.json", %{
      test: context.test,
      phase: context.phase,
      checks: checks,
      passed: Enum.all?(checks, fn {_, value} -> value end),
      observations: observations,
      supervisor_children_after: length(Task.Supervisor.children(context.supervisor)),
      at: DateTime.utc_now()
    })
  end

  defp write(root, name, value), do: File.write!(Path.join(root, name), Jason.encode!(value, pretty: true) <> "\n", [:exclusive])
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defmodule HookFixture do
    @moduledoc false

    alias SymphonyElixir.{AgentProvider, AgentRunner, Config, DispatchAudit, LeaseManager, RepoHarness, RunLedger, Workspace}
    alias SymphonyElixir.Linear.Issue

    @spec prepare!(Path.t(), Path.t(), Issue.t(), map()) :: map()
    def prepare!(directory, workspace, %Issue{} = issue, config) do
      directory = Path.expand(directory)
      workspace = Path.expand(workspace)
      true = String.starts_with?(workspace, directory <> "/")
      :directory = File.lstat!(workspace).type
      [] = File.ls!(workspace)
      "In Progress" = issue.state
      "memory" = get_in(config, [:tracker, :kind])
      true = is_binary(get_in(config, [:agent, :codex, :command]))
      true = is_binary(issue.id) and issue.id != ""
      true = is_binary(issue.identifier) and issue.identifier != ""
      true = Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, issue.id)
      true = Path.basename(workspace) == issue.identifier

      for relative <- [".symphony", "src", "test"], do: File.mkdir!(Path.join(workspace, relative))

      write!(Path.join(workspace, "README.md"), "Local AgentRunner shutdown fixture. No remote operations.\n")
      write!(Path.join(workspace, "src/sentinel.txt"), "Preserve this local fixture source.\n")
      write!(Path.join(workspace, "test/sentinel.txt"), "Preserve this local fixture test.\n")
      write!(Path.join(workspace, ".gitignore"), ".symphony/run_state.json\n.symphony/runtime/\n")

      harness = %{
        version: 1,
        base_branch: "main",
        preflight: %{command: "true"},
        validation: %{command: "true"},
        smoke: %{command: "true"},
        post_merge: %{command: "true"},
        artifacts: %{command: "true"},
        pull_request: %{required_checks: ["local-fixture"]},
        verification: %{
          behavioral_proof: %{required: true, mode: "unit_first", source_paths: ["src/"], test_paths: ["test/"]},
          ui_proof: %{required: false, mode: "local"}
        }
      }

      write!(Path.join(workspace, ".symphony/harness.yml"), Jason.encode!(harness, pretty: true) <> "\n")
      git!(workspace, ["init", "-b", "main"])
      git!(workspace, ["add", "."])
      git!(workspace, ["commit", "-m", "fixture: local agent hook shutdown"])
      "" = git!(workspace, ["remote"])
      {:ok, _harness} = RepoHarness.load(workspace)

      bin = Path.join(directory, "hook-fixture-bin")
      File.mkdir!(bin)
      gh = Path.join(bin, "gh")
      gh_log = Path.join(directory, "hook-fixture-gh-reads.log")

      write!(gh, """
      #!/bin/sh
      set -eu
      if [ "$#" -ne 4 ] || [ "$1" != "pr" ] || [ "$2" != "view" ] || [ "$3" != "--json" ] || [ "$4" != "url,state,reviewDecision,statusCheckRollup" ]; then
        printf '%s\\n' 'Unexpected gh invocation in local hook fixture' >&2
        exit 65
      fi
      printf '%s\\n' "$*" >> #{quote_shell(gh_log)}
      printf '%s\\n' '{"url":null,"state":null,"reviewDecision":null,"statusCheckRollup":[]}'
      """)

      File.chmod!(gh, 0o700)
      hook_path = Path.join(directory, "after-run-observed.txt")
      false = File.exists?(hook_path)
      hook_command = "printf '%s\\n' \"$PWD\" >> " <> quote_shell(hook_path)
      log_file = Path.join(directory, "log/symphony.log")

      config =
        config
        |> Map.update!(:agent, &Map.put(&1, :provider, "codex"))
        |> Map.update!(:company, &Map.merge(&1, %{repo_url: "", policy_pack: "private_autopilot"}))
        |> Map.put(:hooks, %{after_run: hook_command, timeout_ms: 1_000})
        |> Map.put(:policy_packs, %{
          private_autopilot: %{
            pr_posting_mode: "forbidden",
            thread_resolution_mode: "forbidden",
            external_comment_mode: "forbidden",
            preview_deploy_allowed: false,
            production_deploy_allowed: false
          }
        })

      %{
        directory: directory,
        workspace: workspace,
        issue: issue,
        config: config,
        environment: [
          {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
          {"MIX_HOME", Path.join(directory, "runtime/mix")},
          {"MIX_ARCHIVES", Path.join(directory, "runtime/archives")},
          {"HEX_HOME", Path.join(directory, "runtime/hex")}
        ],
        application_environment: [{:symphony_elixir, :log_file, log_file}],
        log_file: log_file,
        ledger_path: Path.join(directory, "log/run_ledger.jsonl"),
        lease_path: Path.join(directory, "log/leases/#{issue.id}.json"),
        journal_path: DispatchAudit.marker_directory(workspace),
        gh_path: gh,
        gh_log: gh_log,
        hook_path: hook_path,
        hook_command: hook_command,
        git_head: git!(workspace, ["rev-parse", "HEAD"])
      }
    end

    @spec start!(pid(), map()) :: {pid(), reference()}
    def start!(supervisor, fixture) when is_pid(supervisor) do
      case Process.whereis(SymphonyElixir.Orchestrator) do
        nil ->
          :ok

        pid ->
          {:status, ^pid, {:module, :gen_server}, [_, :suspended, _, _, _]} = :sys.get_status(pid)
      end

      true = System.find_executable("gh") == fixture.gh_path
      true = Workspace.path_for_issue(fixture.issue) == fixture.workspace
      true = Config.workspace_hooks()[:after_run] == fixture.hook_command
      SymphonyElixir.AgentProvider.Codex = AgentProvider.resolve_for_stage("checkout")
      true = Application.get_env(:symphony_elixir, :log_file) == fixture.log_file
      true = RunLedger.ledger_file_path() == fixture.ledger_path
      true = LeaseManager.lease_path(fixture.issue.id) == fixture.lease_path
      :ok = DispatchAudit.ensure_available(fixture.workspace)
      {:error, :missing} = LeaseManager.read(fixture.issue.id)
      parent = self()

      {:ok, worker} =
        Task.Supervisor.start_child(supervisor, fn ->
          result = AgentRunner.run(fixture.issue)
          send(parent, {:agent_runner_result, self(), result})
        end)

      {worker, Process.monitor(worker)}
    end

    @spec git!(Path.t(), [String.t()]) :: String.t()
    defp git!(workspace, args) do
      git = System.find_executable("git") || raise "Git is required by the local fixture"

      {output, status} =
        System.cmd(
          git,
          ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Local hook fixture", "-c", "user.email=fixture@example.invalid" | args],
          cd: workspace,
          stderr_to_stdout: true,
          env: [
            {"GIT_CONFIG_GLOBAL", "/dev/null"},
            {"GIT_CONFIG_NOSYSTEM", "1"},
            {"GIT_TERMINAL_PROMPT", "0"},
            {"GIT_DIR", nil},
            {"GIT_WORK_TREE", nil},
            {"GIT_INDEX_FILE", nil},
            {"GIT_OBJECT_DIRECTORY", nil},
            {"GIT_ALTERNATE_OBJECT_DIRECTORIES", nil},
            {"GIT_CONFIG_COUNT", nil},
            {"GIT_CONFIG_PARAMETERS", nil}
          ]
        )

      if status != 0, do: raise("Local Git fixture failed: #{inspect(args)}: #{output}")
      String.trim(output)
    end

    @spec write!(Path.t(), String.t()) :: :ok
    defp write!(path, contents), do: File.write!(path, contents, [:exclusive])

    @spec quote_shell(String.t()) :: String.t()
    defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp provider_script do
    ~S'''
    """Local JSONL fixture that holds a chosen protocol phase until owner EOF."""
    from __future__ import annotations

    import json
    import os
    from pathlib import Path
    import select
    import sys
    import time


    def main() -> int:
        root, phase = Path(sys.argv[1]), sys.argv[2]
        assert phase in {'initialize', 'thread/start', 'turn/start', 'stream', 'complete', 'port_error'}
        log = root / 'provider.jsonl'

        def record(event: str, **fields: object) -> None:
            with log.open('a') as output:
                output.write(json.dumps({'event': event, 'pid': os.getpid(), 'phase': phase,
                                         'monotonic_ns': time.monotonic_ns(), **fields}) + '\n')

        def emit(payload: dict) -> None:
            print(json.dumps(payload), flush=True)
            record('response', payload=payload)

        def ready() -> None:
            save('provider-ready.json', {'pid': os.getpid(), 'phase': phase})
            record('ready')

        def save(name: str, value: dict) -> None:
            destination = root / name
            assert not destination.exists(), f'Checkpoint already exists: {name}'
            temporary = root / (name + '.writing')
            with temporary.open('x') as output:
                output.write(json.dumps(value) + '\n')
            temporary.rename(destination)

        expected = [('initialize', 1), ('initialized', None), ('thread/start', 2), ('turn/start', 3)]
        index = 0
        holding = False
        completed = False
        buffer = b''
        deadline = time.monotonic() + 30
        record('started', cwd=str(Path.cwd()))
        try:
            while time.monotonic() < deadline:
                if phase == 'complete' and holding and not completed and (root / 'complete').is_file():
                    emit({'method': 'turn/completed', 'params': {'turn': {'id': 'turn-cancel-probe'}}})
                    completed = True
                if b'\n' not in buffer:
                    readable, _, _ = select.select([sys.stdin.fileno()], [], [], 0.05)
                    if not readable:
                        continue
                    chunk = os.read(sys.stdin.fileno(), 65536)
                    if not chunk:
                        assert not buffer, 'Incomplete message at EOF'
                        record('owner_eof')
                        save('provider-exit.json', {'pid': os.getpid(), 'reason': 'owner_eof', 'exit_code': 0})
                        return 0
                    buffer += chunk
                if b'\n' not in buffer:
                    continue
                line, buffer = buffer.split(b'\n', 1)
                request = json.loads(line)
                record('request', payload=request)
                assert not holding, 'Unexpected request after phase barrier'
                method, request_id = expected[index]
                assert request.get('method') == method and request.get('id') == request_id, request
                index += 1
                if method == 'initialized':
                    continue
                if phase == 'port_error':
                    record('controlled_exit', exit_code=17)
                    return 17
                if phase == method:
                    holding = True
                    ready()
                    continue
                result = {} if method == 'initialize' else (
                    {'thread': {'id': 'thread-cancel-probe'}} if method == 'thread/start'
                    else {'turn': {'id': 'turn-cancel-probe'}})
                emit({'id': request_id, 'result': result})
                if method == 'turn/start':
                    holding = True
                    ready()
            raise TimeoutError('Fixture did not observe owner EOF within 30 seconds')
        except Exception as error:
            record('error', error=repr(error))
            raise


    if __name__ == '__main__':
        raise SystemExit(main())
    '''
  end
end
