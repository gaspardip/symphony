defmodule SymphonyElixir.PublishPreflightTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DeliveryEngine, PullRequestManager, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "publish-preflight-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "PB-13")
    File.mkdir_p!(Path.join(workspace, ".git"))

    issue = %Issue{id: "publication-preflight", identifier: "PB-13", title: "Publication gate", state: "In Progress"}

    {:ok, _state} =
      RunStateStore.transition(workspace, "publish", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        branch: "publication-fixture"
      })

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root, policy_publish_required: true)

    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "---\n", "---\nagent:\n  provider: codex-cli\n", global: false))
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()
    on_exit(fn -> File.rm_rf!(root) end)
    %{workspace: workspace, issue: issue}
  end

  test "forbidden publication blocks before any Git mutation", context do
    assert_blocked_before_mutation(context, :client_safe_shadow, "pr_posting_forbidden")
  end

  test "missing credential scope blocks before any Git mutation", context do
    assert_blocked_before_mutation(context, :client_safe_pr_active, "credential_scope_forbidden")
  end

  test "invalid PR body contract blocks before any Git mutation", context do
    File.mkdir_p!(Path.join(context.workspace, ".github"))
    File.write!(Path.join(context.workspace, ".github/pull_request_template.md"), "required contract\n")
    File.mkdir_p!(Path.join([context.workspace, "elixir", "lib", "mix", "tasks"]))
    File.write!(Path.join([context.workspace, "elixir", "lib", "mix", "tasks", "pr_body.check.ex"]), "# contract marker\n")
    assert_blocked_before_mutation(context, :private_autopilot, "pr_body_invalid")
  end

  test "allowed generic publication returns validation without publishing", context do
    assert {:ok, %{status: "skipped"}} =
             PullRequestManager.validate_publication(context.workspace, context.issue, %{branch: "publication-fixture"})
  end

  test "snapshot corruption during inspection blocks before publication", context do
    path = RunStateStore.state_path(context.workspace)
    payload = "{corrupt-during-inspection"
    runner = command_recorder(fn -> File.write!(path, payload) end)

    assert {:stop, {:run_state_unreadable, _reason}} =
             DeliveryEngine.run(context.workspace, context.issue, nil, command_runner: runner)

    refute_received {:forbidden_git_mutation, _}
    assert File.read!(path) == payload
  end

  test "blocked snapshot is durable before any tracker notification", context do
    parent = self()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, parent)

    attach_stop_handler(context.issue.id, fn ->
      send(parent, {:runtime_stop_recorded, self()})

      receive do
        :continue_stop -> :ok
      end
    end)

    task =
      Task.async(fn ->
        DeliveryEngine.run(context.workspace, context.issue, nil, command_runner: command_recorder(), policy_pack: :client_safe_shadow)
      end)

    assert_receive {:runtime_stop_recorded, emitter}, 1_000
    lock = {{RunStateStore, Path.expand(context.workspace)}, self()}
    assert :global.set_lock(lock, [node()], 0)

    try do
      send(emitter, :continue_stop)
      refute_receive {:memory_tracker_comment, _, _}, 100
      refute_receive {:memory_tracker_state_update, _, _}, 100
    after
      :global.del_lock(lock, [node()])
    end

    assert_receive {:memory_tracker_comment, _, _}, 1_000
    assert {:ok, state} = RunStateStore.load(context.workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "publish.failed"
    assert state.stop_reason.code == "publish_failed"
    assert_receive {:memory_tracker_state_update, _, "Blocked"}
    assert {:stop, :publish_failed} = Task.await(task)
  end

  test "failed blocked-state persistence reports an error without tracker writes", context do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    path = RunStateStore.state_path(context.workspace)
    payload = "{corrupt-during-block-persistence"
    attach_stop_handler(context.issue.id, fn -> File.write!(path, payload) end)

    log =
      capture_log(fn ->
        assert {:error, {:blocked_state_persist_failed, {:run_state_unreadable, _reason}}} =
                 DeliveryEngine.run(context.workspace, context.issue, nil, command_runner: command_recorder(), policy_pack: :client_safe_shadow)
      end)

    assert log =~ "Failed to persist blocked state"
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
    assert File.read!(path) == payload
  end

  defp attach_stop_handler(issue_id, callback) do
    id = "publication-stop-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:symphony, :ledger, :event],
        fn _event, _measurements, metadata, _config ->
          if metadata[:event_type] == "runtime.stopped" and metadata[:issue_id] == issue_id, do: callback.()
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp assert_blocked_before_mutation(context, policy_pack, expected_reason) do
    runner = command_recorder()

    assert {:stop, :publish_failed} = DeliveryEngine.run(context.workspace, context.issue, nil, command_runner: runner, policy_pack: policy_pack)
    refute_received {:forbidden_git_mutation, _}
    assert {:ok, state} = RunStateStore.load(context.workspace)
    assert state.stage == "blocked"
    assert inspect(state.stop_reason) =~ expected_reason
    refute Map.get(state, :last_commit_sha)
  end

  defp command_recorder(on_inspect \\ fn -> :ok end) do
    owner = self()

    fn
      "git", [operation | _] = args, _opts when operation in ["add", "commit", "push"] ->
        send(owner, {:forbidden_git_mutation, args})
        {"unexpected mutation", 1}

      "git", ["status", "--porcelain"], _opts ->
        on_inspect.()
        {" M source.ex\n", 0}

      "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts ->
        {"publication-fixture\n", 0}

      "git", ["rev-parse", "HEAD"], _opts ->
        {String.duplicate("a", 40), 0}

      "git", ["diff", "--stat", "--no-ext-diff", "HEAD"], _opts ->
        {"source.ex | 1 +\n", 0}

      "git", ["diff", "--numstat", "--no-ext-diff", "HEAD"], _opts ->
        {"1\t0\tsource.ex\n", 0}

      "git", _args, _opts ->
        {"", 0}

      "gh", ["pr", "view" | _], _opts ->
        {"No pull request\n", 1}

      command, args, _opts ->
        raise "unexpected command #{inspect({command, args})}"
    end
  end
end
