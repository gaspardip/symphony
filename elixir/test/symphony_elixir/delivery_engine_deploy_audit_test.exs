defmodule SymphonyElixir.DeliveryEngineDeployAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DeliveryEngine, DeployAudit, RunLedger, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-deploy-audit-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "log/symphony.log"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 0,
      workspace_root: Path.join(root, "workspaces"),
      runner_install_root: Path.join(root, "runner"),
      manual_enabled: false,
      manual_store_root: Path.join(root, "manual"),
      company_repo_url: "",
      company_author_profile_path: Path.join(root, "author.json"),
      company_credential_registry_path: Path.join(root, "credentials.json"),
      codex_command: "/usr/bin/false",
      codex_runtime_profile_inherit_env: false,
      policy_publish_required: false,
      policy_automerge_on_green: false,
      policy_post_merge_verification_required: false
    )

    assert Config.tracker_kind() == "memory"
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  for target <- ["preview", "production"] do
    for destination <- ["post_deploy_verify", "done"] do
      @tag target: target, destination: destination
      test "#{target} records one effect and its own continuation to #{destination}", context do
        fixture = fixture!(context.root, context.target, :success, context.destination == "post_deploy_verify")

        if context.destination == "done" do
          assert {:done, returned_issue} = run(fixture)
          assert returned_issue == fixture.issue
          assert_receive {:memory_tracker_state_update, issue_id, "Done"}
          assert issue_id == fixture.issue.id
        else
          assert :ok = run(fixture)
          refute_received {:memory_tracker_state_update, _, _}
        end

        assert effect_count(fixture) == 1
        assert {:ok, state} = RunStateStore.load(fixture.workspace)
        assert state.stage == context.destination
        assert get_in(state, [fixture.result_key, :status]) == "passed"
        assert get_in(state, [fixture.result_key, :command]) == fixture.command
        assert get_in(state, [fixture.result_key, :output]) =~ "local deployment effect"
        assert state.current_deploy_target == context.target
        assert state.stage_transition_counts[context.destination] == 1
        assert state.stage_transition_counts[fixture.stage] == 1
        assert state.stop_reason == nil
        assert state.last_deploy_operation_id != nil
        assert :ok = DeployAudit.ensure_available(fixture.workspace)
        refute File.exists?(DeployAudit.marker_directory(fixture.workspace))

        rows = ledger_rows(fixture.ledger)
        requested = only_event!(rows, "deploy.#{context.target}.requested")
        observed = only_event!(rows, "deploy.#{context.target}.observed")
        assert requested["metadata"]["deploy_operation_id"] == state.last_deploy_operation_id
        assert observed["metadata"]["deploy_operation_id"] == state.last_deploy_operation_id
        assert observed["metadata"]["intent_event_id"] == requested["event_id"]
        assert observed["metadata"]["result"]["status"] == "passed"
        assert observed["metadata"]["result"]["command"] == fixture.command
        assert observed["metadata"]["result"]["output"] =~ "local deployment effect"
        assert {:ok, transition} = RunLedger.fetch_entry_checked(state.last_ledger_event_id)
        assert transition["event_type"] == "stage.transition"
        assert transition["stage"] == context.destination
        assert transition["issue_id"] == fixture.issue.id
        assert transition["metadata"]["deploy_operation_id"] == state.last_deploy_operation_id
        assert transition["metadata"]["deploy_intent_event_id"] == requested["event_id"]
        assert transition["metadata"]["deploy_result_event_id"] == observed["event_id"]

        if context.target == "production" do
          assert state.deploy_approved == false
          assert state.deploy_window_wait == nil
        end
      end
    end

    for fault <- [:missing, :directory] do
      @tag target: target, fault: fault
      test "#{target} executes no command when its entry ledger is #{fault}", context do
        fixture = fixture!(context.root, context.target, :success, true)
        before = snapshot_bytes(fixture)
        File.rename!(fixture.ledger, fixture.ledger_backup)
        if context.fault == :directory, do: File.mkdir!(fixture.ledger)

        assert {:error, %RunLedger.PersistenceError{} = error} = run(fixture)
        assert error.reason == if(context.fault == :missing, do: :enoent, else: :eisdir)
        assert effect_count(fixture) == 0
        assert snapshot_bytes(fixture) == before
        assert {:ok, state} = RunStateStore.load(fixture.workspace)
        assert state.stage == fixture.stage
        assert state.last_ledger_event_id == fixture.entry_event_id
        assert Map.get(state, fixture.result_key) == nil
        refute_received {:memory_tracker_state_update, _, _}

        if context.fault == :missing do
          refute File.exists?(fixture.ledger)
        else
          assert File.dir?(fixture.ledger)
        end

        assert ledger_rows(fixture.ledger_backup) == fixture.seed_ledger
      end
    end

    @tag target: target
    test "#{target} preserves the observed result and rejects reentry after the command breaks the ledger", context do
      fixture = fixture!(context.root, context.target, :break_ledger, true)
      before = snapshot_bytes(fixture)

      assert {:error, %RunLedger.PersistenceError{reason: :eisdir}} = run(fixture)
      assert effect_count(fixture) == 1
      assert File.dir?(fixture.ledger)
      assert snapshot_bytes(fixture) == before
      marker = marker!(fixture)
      assert marker["status"] == "result_pending"
      assert_observed_result!(fixture, marker, "passed")
      requested = only_event!(ledger_rows(fixture.ledger_backup), "deploy.#{context.target}.requested")
      assert marker["intent"] == requested
      assert Enum.all?(ledger_rows(fixture.ledger_backup), &(&1["event_type"] != "deploy.#{context.target}.observed"))
      assert_same_pending_reentry!(fixture)
      refute_received {:memory_tracker_state_update, _, _}
    end

    @tag target: target
    test "#{target} retains uncertainty after a nonzero command exit with a real local effect", context do
      fixture = fixture!(context.root, context.target, :exit_failure, true)
      before = snapshot_bytes(fixture)

      assert {:error, {:deploy_audit_result_uncertain, "failed"}} = run(fixture)
      assert effect_count(fixture) == 1
      assert snapshot_bytes(fixture) == before
      marker = marker!(fixture)
      assert marker["status"] == "result_confirmed"
      assert_observed_result!(fixture, marker, "failed")
      observed = only_event!(ledger_rows(fixture.ledger), "deploy.#{context.target}.observed")
      assert marker["result"] == observed
      assert_same_pending_reentry!(fixture)
      refute_received {:memory_tracker_state_update, _, _}
    end

    @tag target: target
    test "#{target} retains confirmed result when the command makes the snapshot path unusable", context do
      fixture = fixture!(context.root, context.target, :break_snapshot, true)
      before = snapshot_bytes(fixture)

      assert {:error, :eisdir} = run(fixture)
      assert effect_count(fixture) == 1
      assert File.dir?(RunStateStore.state_path(fixture.workspace))
      assert File.read!(fixture.snapshot_backup) == before
      assert {:error, :eisdir} = RunStateStore.load(fixture.workspace)
      marker = marker!(fixture)
      assert marker["status"] == "result_confirmed"
      assert_observed_result!(fixture, marker, "passed")
      assert marker["result"] == only_event!(ledger_rows(fixture.ledger), "deploy.#{context.target}.observed")
      marker_before = File.read!(marker_path(fixture))
      ledger_before = File.read!(fixture.ledger)
      assert {:stop, {:deploy_audit_pending, workspace}} = run(fixture)
      assert workspace == Path.expand(fixture.workspace)
      assert effect_count(fixture) == 1
      assert File.read!(marker_path(fixture)) == marker_before
      assert File.read!(fixture.ledger) == ledger_before
      assert File.read!(fixture.snapshot_backup) == before
      assert File.dir?(RunStateStore.state_path(fixture.workspace))
      refute_received {:memory_tracker_state_update, _, _}
    end

    @tag target: target
    test "#{target} cannot overwrite a persisted stop when a successful command returns late", context do
      fixture = fixture!(context.root, context.target, :success, false)
      parent = self()
      barrier = make_ref()
      supervisor = start_supervised!({Task.Supervisor, []})

      shell_runner = fn workspace, command, opts ->
        assert workspace == fixture.workspace
        assert command == fixture.command
        result = local_shell(workspace, command, opts)
        send(parent, {:deploy_effect_finished, barrier, self(), result})

        receive do
          {:release_deploy_result, ^barrier} -> result
        after
          5_000 -> raise "The test did not release the completed local deployment command"
        end
      end

      task = Task.Supervisor.async_nolink(supervisor, fn -> run(fixture, shell_runner: shell_runner) end)

      try do
        assert_receive {:deploy_effect_finished, ^barrier, worker, {_output, 0}}, 5_000
        assert worker == task.pid
        assert effect_count(fixture) == 1
        marker_before = marker!(fixture)
        assert marker_before["status"] == "authorized"

        assert {:ok, stopped} =
                 RunStateStore.transition(fixture.workspace, "blocked", %{
                   issue_id: fixture.issue.id,
                   issue_identifier: fixture.issue.identifier,
                   stop_reason: %{code: "operator_stop", source: "local_test"},
                   last_decision_summary: "Operator stop persisted while deployment result was in flight."
                 })

        assert stopped.stage == "blocked"
        stopped_bytes = snapshot_bytes(fixture)
        send(task.pid, {:release_deploy_result, barrier})
        assert {:error, :deploy_audit_snapshot_conflict} = Task.await(task, 5_000)
        assert snapshot_bytes(fixture) == stopped_bytes
        assert {:ok, final_state} = RunStateStore.load(fixture.workspace)
        assert final_state.stop_reason.code == "operator_stop"
        assert Map.get(final_state, fixture.result_key) == nil
        marker_after = marker!(fixture)
        assert marker_after["operation_id"] == marker_before["operation_id"]
        assert marker_after["intent"] == marker_before["intent"]
        assert marker_after["status"] == "result_confirmed"
        assert_observed_result!(fixture, marker_after, "passed")
        assert marker_after["result"] == only_event!(ledger_rows(fixture.ledger), "deploy.#{context.target}.observed")
        assert_same_pending_reentry!(fixture)
        refute_received {:memory_tracker_state_update, _, _}
      after
        send(task.pid, {:release_deploy_result, barrier})
        if Process.alive?(task.pid), do: Task.shutdown(task, 5_000)
      end
    end
  end

  defp fixture!(root, target, scenario, verify?) do
    stage = "deploy_" <> target
    workspace = Path.join(root, "workspaces/DEPLOY-TEST")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    ledger = RunLedger.ledger_file_path()
    ledger_backup = Path.join(root, "ledger-before-fault.jsonl")
    snapshot_backup = Path.join(root, "snapshot-before-fault.json")
    effects = Path.join(root, "effects.txt")
    script = Path.join(root, "deploy.sh")
    command = "/bin/sh " <> quote_shell(script)

    tail =
      case scenario do
        :success ->
          "exit 0\n"

        :exit_failure ->
          "exit 23\n"

        :break_ledger ->
          "/bin/mv " <> quote_shell(ledger) <> " " <> quote_shell(ledger_backup) <> "\n/bin/mkdir " <> quote_shell(ledger) <> "\n"

        :break_snapshot ->
          "/bin/mv " <> quote_shell(RunStateStore.state_path(workspace)) <> " " <> quote_shell(snapshot_backup) <> "\n/bin/mkdir " <> quote_shell(RunStateStore.state_path(workspace)) <> "\n"
      end

    File.write!(script, "set -eu\nprintf 'effect\\n' >> " <> quote_shell(effects) <> "\nprintf 'local deployment effect\\n'\n" <> tail, [:exclusive])
    deploy = %{target => %{command: command}}
    deploy = if verify?, do: Map.put(deploy, "post_deploy_verify", %{command: "true"}), else: deploy

    harness = %{
      version: 1,
      base_branch: "main",
      preflight: %{command: "true"},
      validation: %{command: "true"},
      smoke: %{command: "true"},
      post_merge: %{command: "true"},
      artifacts: %{command: "true"},
      deploy: deploy,
      pull_request: %{required_checks: ["local-proof"]}
    }

    File.write!(Path.join(workspace, ".symphony/harness.yml"), Jason.encode!(harness), [:exclusive])
    File.write!(Path.join(workspace, "README.md"), "Private deployment test; no remotes.\n", [:exclusive])
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/run_state.json\n.symphony/runtime/\n", [:exclusive])
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "-m", "test: local deployment fixture"])
    assert git!(workspace, ["remote"]) == ""
    assert {:ok, _harness} = RepoHarness.load(workspace)

    issue = %Issue{id: "local-deploy-#{target}", identifier: "DEPLOY-TEST", title: "Local deployment audit", state: "Merging", labels: [], description: "Private local shell only"}

    assert {:ok, state} =
             RunStateStore.transition(workspace, stage, %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: issue.source,
               effective_policy_class: "fully_autonomous",
               branch: "main",
               deploy_approved: true,
               current_deploy_target: target
             })

    %{
      workspace: workspace,
      issue: issue,
      stage: stage,
      target: target,
      result_key: if(target == "preview", do: :last_deploy_preview, else: :last_deploy_production),
      command: command,
      effects: effects,
      ledger: ledger,
      ledger_backup: ledger_backup,
      snapshot_backup: snapshot_backup,
      entry_event_id: state.last_ledger_event_id,
      seed_ledger: ledger_rows(ledger)
    }
  end

  defp run(fixture, opts \\ []) do
    shell_runner = fn workspace, command, shell_opts ->
      assert workspace == fixture.workspace
      assert command == fixture.command
      local_shell(workspace, command, shell_opts)
    end

    DeliveryEngine.run(fixture.workspace, fixture.issue, nil, Keyword.merge([command_runner: &inspect_command/3, shell_runner: shell_runner], opts))
  end

  defp inspect_command("git", args, opts) do
    assert args in [["config", "--get", "remote.origin.url"], ["rev-parse", "--abbrev-ref", "HEAD"], ["rev-parse", "HEAD"], ["status", "--porcelain"]]
    System.cmd("git", args, Keyword.put(opts, :env, git_env()))
  end

  defp inspect_command("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    {Jason.encode!(%{url: nil, state: nil, reviewDecision: nil, statusCheckRollup: []}), 0}
  end

  defp inspect_command(command, args, _opts), do: flunk("Unexpected inspection command: #{inspect({command, args})}")

  defp local_shell(workspace, command, opts) do
    System.cmd("/bin/sh", ["-c", command], Keyword.merge([cd: workspace], opts))
  end

  defp git!(workspace, args) do
    {output, status} =
      System.cmd("git", ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Local fixture", "-c", "user.email=fixture@example.invalid" | args],
        cd: workspace,
        stderr_to_stdout: true,
        env: git_env()
      )

    assert status == 0, output
    String.trim(output)
  end

  defp git_env do
    [
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
  end

  defp effect_count(fixture) do
    case File.read(fixture.effects) do
      {:ok, contents} -> length(String.split(contents, "\n", trim: true))
      {:error, :enoent} -> 0
      {:error, reason} -> flunk("Cannot inspect private effects: #{inspect(reason)}")
    end
  end

  defp ledger_rows(path) do
    rows = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.all?(rows, fn row -> is_binary(row["event_type"]) and row["event"] == row["event_type"] end)
    rows
  end

  defp snapshot_bytes(fixture), do: File.read!(RunStateStore.state_path(fixture.workspace))
  defp marker_path(fixture), do: Path.join(DeployAudit.marker_directory(fixture.workspace), "marker.json")
  defp marker!(fixture), do: fixture |> marker_path() |> File.read!() |> Jason.decode!()

  defp only_event!(rows, event) do
    assert [entry] = Enum.filter(rows, &(&1["event_type"] == event))
    entry
  end

  defp assert_observed_result!(fixture, marker, status) do
    assert marker["issue_id"] == fixture.issue.id
    assert marker["issue_identifier"] == fixture.issue.identifier
    assert marker["stage"] == fixture.stage
    assert marker["target"] == fixture.target
    assert marker["entry_event_id"] == fixture.entry_event_id
    assert marker["ledger_path"] == fixture.ledger
    assert is_binary(marker["operation_id"])
    assert marker["result"]["metadata"]["deploy_operation_id"] == marker["operation_id"]
    assert marker["result"]["metadata"]["intent_event_id"] == marker["intent"]["event_id"]
    assert marker["result"]["metadata"]["result"]["status"] == status
    assert marker["result"]["metadata"]["result"]["command"] == fixture.command
    assert marker["result"]["metadata"]["result"]["output"] =~ "local deployment effect"
  end

  defp assert_same_pending_reentry!(fixture) do
    marker_bytes = File.read!(marker_path(fixture))
    before = snapshot_bytes(fixture)
    assert {:stop, {:deploy_audit_pending, workspace}} = run(fixture)
    assert workspace == Path.expand(fixture.workspace)
    assert effect_count(fixture) == 1
    assert File.read!(marker_path(fixture)) == marker_bytes
    assert snapshot_bytes(fixture) == before
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
