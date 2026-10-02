defmodule SymphonyElixir.ArtifactsGateIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DeliveryEngine, LeaseManager, RunLedger, RunStateStore}

  # Git and harness commands are physical. This transport denies publication;
  # the actual VerifierRunner decides from proof or the reported model verdict.
  defmodule GitHub do
    def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}
    def existing_pull_request(_workspace, _opts), do: raise("unexpected publication")
    def create_pull_request(_, _, _, _, _, _), do: raise("unexpected publication")
    def edit_pull_request(_, _, _, _), do: raise("unexpected publication")
    def persist_pr_url(_, _, _, _), do: raise("unexpected publication")
    def merge_pull_request(_, _), do: raise("unexpected merge")
  end

  # Only the worker job is captured. Admission, gate, owner RPC and genuine DOWN
  # delegate to production. No owner state, authority or result is fabricated.
  defmodule Driver do
    use GenServer
    alias SymphonyElixir.{AgentExecution, DispatchAudit, DispatchGate, Orchestrator, RunStateStore, Workspace}

    @impl true
    def init(observer) do
      {:ok,
       %{
         observer: observer,
         runtime: %Orchestrator.State{
           lease_owner: "artifacts-#{System.unique_integer([:positive])}",
           max_concurrent_agents: 1,
           agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0}
         }
       }}
    end

    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

    def handle_call({:dispatch, issue}, _from, state) do
      owner = self()
      observer = state.observer

      start_child = fn supervisor, _job ->
        raw = issue |> Workspace.path_for_issue() |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()

        Task.Supervisor.start_child(supervisor, fn ->
          receive do
            {:captured, context} ->
              result =
                DispatchGate.run(owner, context.ticket.dispatch_id, fn ->
                  DispatchAudit.with_authorization(context.ticket, fn ->
                    AgentExecution.with_context(context.ticket, context.lease_token, owner, raw, fn ->
                      send(observer, {:artifacts_worker_ready, self()})

                      receive do
                        {:exercise, fun} ->
                          result = fun.()
                          send(observer, {:artifacts_worker_result, self(), result})
                          result
                      end
                    end)
                  end)
                end)

              case result do
                {:stop, {:stale_execution, ids, cause}} -> exit({:stale_execution, ids, cause})
                {:stop, {:accounting_uncertain, cause}} -> exit({:accounting_uncertain, cause})
                other -> other
              end
          end
        end)
      end

      spawn_worker = fn runtime, selected, attempt, recipient ->
        Orchestrator.do_spawn_issue_worker_for_test(runtime, selected, attempt, recipient, start_child_fun: start_child)
      end

      runtime = Orchestrator.do_dispatch_issue_for_test(state.runtime, issue, nil, spawn_fun: spawn_worker)
      entry = Map.fetch!(runtime.running, issue.id)
      send(entry.pid, {:captured, entry.agent_execution.context})
      {:reply, entry, %{state | runtime: runtime}}
    end

    def handle_call(message, from, state) do
      {:reply, reply, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      {:reply, reply, %{state | runtime: runtime}}
    end

    @impl true
    def handle_info({:DOWN, _, :process, _, _} = message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      send(state.observer, {:artifacts_owner_down, message})
      {:noreply, %{state | runtime: runtime}}
    end

    def handle_info(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "artifacts-gate-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "ARTIFACTS-1")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/\n")
    File.write!(Path.join(workspace, "lib/feature.ex"), "before\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.name", "Artifact Fixture"],
          ["config", "user.email", "artifacts@example.invalid"],
          ["add", "-A"],
          ["-c", "commit.gpgsign=false", "commit", "-qm", "fixture"]
        ] do
      assert {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    File.write!(Path.join(workspace, "lib/feature.ex"), "after\n")

    issue = %Issue{
      id: "artifacts-1",
      identifier: "ARTIFACTS-1",
      source: :tracker,
      state: "In Progress",
      title: "Artifact evidence",
      description: "## Acceptance Criteria\n- Preserve evidence before publication",
      labels: []
    }

    assert {_, 0} = System.cmd("git", ["checkout", "-q", "-b", SymphonyElixir.GitManager.issue_branch_name(issue)], cd: workspace, stderr_to_stdout: true)
    provider = Path.join(root, "provider")
    File.write!(provider, provider_script())
    File.chmod!(provider, 0o755)
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(bin, "gh"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner"),
      max_concurrent_agents: 1,
      codex_command: quote_shell(provider) <> " app-server",
      codex_stall_timeout_ms: 0,
      policy_retry_validation_failures_within_run: false,
      policy_max_validation_attempts_per_run: 1,
      policy_require_verifier: true,
      policy_automerge_on_green: false
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    c = %{root: root, workspace: workspace, issue: issue}
    harness!(c, "printf 'artifact evidence' > .symphony/proof.txt; printf artifacts-ok")
    assert {:ok, _} = RunStateStore.transition(workspace, "validate", %{issue_id: issue.id, issue_identifier: issue.identifier})
    on_exit(fn -> File.rm_rf!(root) end)
    c
  end

  test "physical artifacts follow validation and precede real verification with durable event linkage", c do
    assert {:stop, :unsafe_to_merge} = run(c)
    assert order(c) == ["validation", "artifacts", "smoke"]
    [event] = events("artifacts.completed")
    assert event["metadata"]["status"] == "passed"
    assert event["metadata"]["exit_code"] == 0
    assert event["metadata"]["attempt"] == 1
    assert event["metadata"]["workspace"] == c.workspace
    assert event["details"] == "artifacts-ok"
    assert is_binary(event["event_id"])
    raw = raw!(c)
    assert raw["last_validation"]["exit_code"] == 0
    assert raw["last_validation"]["artifacts"]["ledger_event_id"] == event["event_id"]
    assert raw["last_validation"]["artifacts"]["exit_code"] == 0
    assert File.read!(Path.join(c.workspace, ".symphony/proof.txt")) == "artifact evidence"
    [verification] = events("verification.completed")
    assert verification["metadata"]["verdict"] == "unsafe_to_merge"
    assert raw["last_rule_id"] == "verification.unsafe_to_merge"
    assert_no_publication(c)
  end

  test "artifact exit 17 records failure and blocks before verifier or publication", c do
    harness!(c, "printf artifact-failed >&2; exit 17")
    assert {:stop, :artifacts_failed} = run(c)
    assert order(c) == ["validation", "artifacts"]
    [event] = events("artifacts.completed")
    assert event["metadata"]["status"] == "failed"
    assert event["metadata"]["exit_code"] == 17
    assert event["details"] == "artifact-failed"
    assert raw!(c)["stop_reason"]["code"] == "artifacts_failed"
    assert raw!(c)["last_rule_id"] == "artifacts.failed"
    assert events("verification.completed") == []
    assert_no_publication(c)
  end

  test "a validation failure never executes artifacts", c do
    harness!(c, "touch forbidden-artifact", validation: "printf validation-failed; exit 23")
    assert {:stop, :validation_failed} = run(c)
    assert order(c) == ["validation"]
    [event] = events("validation.completed")
    assert event["metadata"]["exit_code"] == 23
    assert events("artifacts.completed") == []
    refute File.exists?(Path.join(c.workspace, "forbidden-artifact"))
    assert_no_publication(c)
  end

  test "zero artifact exit does not fabricate the required proof file", c do
    harness!(c, "printf command-passed-without-proof")
    assert {:stop, :behavior_proof_missing} = run(c)
    assert order(c) == ["validation", "artifacts", "smoke"]
    [event] = events("artifacts.completed")
    assert event["metadata"]["exit_code"] == 0
    [verification] = events("verification.completed")
    assert verification["metadata"]["verdict"] == "needs_more_work"
    assert raw!(c)["stop_reason"]["code"] == "behavior_proof_missing"
    refute File.exists?(Path.join(c.workspace, ".symphony/proof.txt"))
    assert_no_publication(c)
  end

  test "missing configured executable is a physical exit 127, never unavailable or passed", c do
    harness!(c, "./missing-artifact-executable")
    assert {:stop, :artifacts_failed} = run(c)
    [event] = events("artifacts.completed")
    assert event["metadata"]["exit_code"] == 127
    assert event["metadata"]["status"] == "failed"
    assert_no_publication(c)
  end

  test "real runtime-directory IO failure blocks artifacts before the shell starts", c do
    for {key, directory} <- [{"MIX_HOME", "mix-home"}, {"HEX_HOME", "hex-home"}, {"MIX_ARCHIVES", "mix-archives"}] do
      previous = System.get_env(key)
      System.put_env(key, Path.join(c.root, directory))
      on_exit(fn -> restore_env(key, previous) end)
    end

    harness!(c, "touch forbidden-artifact", validation: ~S(rmdir "$MIX_HOME" && printf blocked > "$MIX_HOME"))
    assert {:stop, :artifacts_unavailable} = run(c)
    assert order(c) == ["validation"]
    [event] = events("artifacts.completed")
    assert event["metadata"]["status"] == "unavailable"
    assert event["metadata"]["exit_code"] == nil
    assert event["details"] =~ "mix-home"
    assert raw!(c)["stop_reason"]["code"] == "artifacts_unavailable"
    assert events("verification.completed") == []
    refute File.exists?(Path.join(c.workspace, "forbidden-artifact"))
    assert_no_publication(c)
  end

  test "absent configuration and missing workspace preserve unavailable with no observed exit", c do
    result = RunInspector.run_artifacts(c.workspace, nil)
    assert result.status == :unavailable
    assert result.command == nil
    assert result.exit_code == nil
    missing = Path.join(c.root, "missing-workspace")
    result = RunInspector.run_artifacts(missing, %RepoHarness{artifacts_command: "touch must-not-run"})
    assert result.status == :unavailable
    assert result.exit_code == nil
    refute File.exists?(missing)
  end

  for step <- ["validation", "artifacts"] do
    @tag guarded_step: step
    test "material change during physical #{step} stops the audited chain without later effects", c do
      started = Path.join(c.root, "held-started")
      release = Path.join(c.root, "held-release")
      wait_command = "touch #{quote_shell(started)}; while ! test -f #{quote_shell(release)}; do sleep 0.02; done; printf observed"

      if c.guarded_step == "validation",
        do: harness!(c, "touch forbidden-artifact", validation: wait_command),
        else: harness!(c, wait_command)

      {:ok, owner} = GenServer.start(Driver, self())
      on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
      entry = GenServer.call(owner, {:dispatch, c.issue}, 10_000)
      worker = entry.pid
      monitor = Process.monitor(worker)

      on_exit(fn ->
        File.write!(release, "release\n")

        if Process.alive?(worker) do
          ref = Process.monitor(worker)
          send(worker, {:exercise, fn -> :ok end})
          assert_receive {:DOWN, ^ref, :process, ^worker, _}, 10_000
        end

        if Process.alive?(owner), do: GenServer.stop(owner)
        assert {:ok, released} = LeaseManager.release_token(entry.lease_token)
        assert released in [:released, :missing]
      end)

      assert_receive {:artifacts_worker_ready, ^worker}, 5_000
      send(worker, {:exercise, fn -> run(c) end})
      await_file!(started, System.monotonic_time(:millisecond) + 5_000)

      :global.trans({{RunStateStore, c.workspace}, self()}, fn ->
        raw = raw!(c)
        File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(Map.put(raw, "policy_override", "operator-control")))
      end)

      controlled = File.read!(RunStateStore.state_path(c.workspace))
      File.write!(release, "release\n")
      assert_receive {:artifacts_worker_result, ^worker, {:stop, {:stale_execution, ids, :material_state_changed}}}, 5_000
      assert ids == %{run_id: entry.dispatch_ticket.run_id, dispatch_id: entry.dispatch_ticket.dispatch_id}
      assert_receive {:DOWN, ^monitor, :process, ^worker, {:stale_execution, ^ids, :material_state_changed}}, 5_000
      assert_receive {:artifacts_owner_down, {:DOWN, _, :process, ^worker, {:stale_execution, ^ids, :material_state_changed}}}, 5_000
      assert File.read!(RunStateStore.state_path(c.workspace)) == controlled
      assert events("artifacts.completed") == []
      assert events("verification.completed") == []
      refute File.exists?(Path.join(c.workspace, "forbidden-artifact"))
      assert_no_publication(c)
    end
  end

  defp run(c) do
    DeliveryEngine.run(c.workspace, c.issue, nil,
      github_client: GitHub,
      issue_state_fetcher: fn [id] ->
        assert id == c.issue.id
        {:ok, [c.issue]}
      end,
      command_runner: fn
        "git", args, opts -> System.cmd("git", args, opts)
        "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _ -> {"", 1}
        "gh", ["pr", "view", "--json", "url,number,reviewDecision"], _ -> {"", 1}
        executable, args, _ -> flunk("Unexpected command: #{inspect({executable, args})}")
      end
    )
  end

  defp harness!(c, artifact_body, opts \\ []) do
    validation = Keyword.get(opts, :validation, "printf validation-ok")
    command = fn stage, body -> "printf '%s\\n' #{quote_shell(stage)} >> #{quote_shell(Path.join(c.root, "command-order"))}; " <> body end

    harness = %{
      version: 1,
      base_branch: "main",
      preflight: %{command: "true"},
      validation: %{command: command.("validation", validation)},
      artifacts: %{command: command.("artifacts", artifact_body)},
      smoke: %{command: command.("smoke", "test -f lib/feature.ex")},
      post_merge: %{command: "true"},
      pull_request: %{required_checks: ["fixture-check"]},
      verification: %{
        behavioral_proof: %{
          required: true,
          mode: "harness_artifact_only",
          source_paths: ["lib"],
          test_paths: ["test"],
          artifact_path: ".symphony/proof.txt"
        }
      }
    }

    File.write!(Path.join(c.workspace, ".symphony/harness.yml"), Jason.encode!(harness))
  end

  defp assert_no_publication(c) do
    assert events("publish.completed") == []
    refute Enum.any?(raw!(c)["stage_history"], &(&1["stage"] == "publish"))
    refute raw!(c)["pr_url"]
  end

  defp order(c), do: c.root |> Path.join("command-order") |> File.read!() |> String.split("\n", trim: true)
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp events(type), do: RunLedger.ledger_file_path() |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.filter(&(&1["event_type"] == type))
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp await_file!(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "Physical command did not reach barrier"
      Process.sleep(10)
      await_file!(path, deadline)
    end
  end

  defp provider_script do
    """
    #!/bin/sh
    set -eu
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"artifacts-thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"artifacts-turn"}}}'
          printf '%s\\n' '{"id":72,"method":"item/tool/call","params":{"tool":"report_verifier_result","callId":"artifact-verifier","threadId":"artifacts-thread","turnId":"artifacts-turn","arguments":{"verdict":"unsafe_to_merge","summary":"Declared transport blocks publication after exercising real gates","acceptance_gaps":[],"risky_areas":["Fixture intentionally requires human review"],"evidence":["Gates executed by runtime"],"raw_output":"transport fixture"}}}'
          ;;
        *'"id":72'*) printf '%s\\n' '{"method":"turn/completed"}' ;;
        *'"method":"initialized"'*) : ;;
        *) exit 91 ;;
      esac
    done
    """
  end
end
