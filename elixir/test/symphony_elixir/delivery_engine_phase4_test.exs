defmodule SymphonyElixir.DeliveryEnginePhase4Test do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeliveryEngine
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.Workflow

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  test "review_required issues publish successfully but stop at Human Review" do
    {workspace, issue} = await_checks_workspace!("review-required", ["policy:review-required"])
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("review-required")
    )

    assert :ok =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &review_ready_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "Rule ID: policy.review_required"
    assert body =~ "Failure class: policy"
    assert body =~ "Unblock action:"

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.last_rule_id == "policy.review_required"
    assert state.last_failure_class == "policy"
    assert state.next_human_action =~ "approve it for merge"
  end

  test "never_automerge issues stay in Human Review even when checks are green" do
    {workspace, issue} = await_checks_workspace!("never-automerge", ["policy:never-automerge"])
    issue_id = issue.id

    RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: fake_codex_binary!("never-automerge")
    )

    assert :ok =
             DeliveryEngine.run(workspace, issue, nil, command_runner: &review_ready_command_runner/3)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "Rule ID: policy.never_automerge"
    assert body =~ "Failure class: policy"
    assert body =~ "Unblock action:"

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.last_rule_id == "policy.never_automerge"
    assert state.last_failure_class == "policy"
    assert state.next_human_action =~ "will not automerge"
  end

  defp await_checks_workspace!(suffix, labels) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-delivery-engine-phase4-#{suffix}-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "MT-AWAIT")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "README.md"), "initial\n")

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command:
        - ./scripts/preflight.sh
    validation:
      command:
        - ./scripts/validate.sh
    smoke:
      command:
        - ./scripts/smoke.sh
    post_merge:
      command:
        - ./scripts/post-merge.sh
    artifacts:
      command:
        - ./scripts/artifacts.sh
    pull_request:
      required_checks:
        - make-all
    """)

    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["add", "README.md", ".symphony/harness.yml"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)

    issue = %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-AWAIT",
      title: "Policy gated merge",
      description: "## Acceptance Criteria\n- wait for policy routing",
      state: "In Progress",
      labels: labels
    }

    {workspace, issue}
  end

  defp review_ready_command_runner("gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts) do
    payload = %{
      "url" => "https://github.com/example/repo/pull/42",
      "state" => "OPEN",
      "reviewDecision" => "APPROVED",
      "statusCheckRollup" => [
        %{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
      ]
    }

    {Jason.encode!(payload), 0}
  end

  defp review_ready_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp fake_codex_binary!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-phase4-fake-codex-#{suffix}-#{System.unique_integer([:positive])}"
      )

    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(root)

    File.write!(binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-phase4"}}}'
          ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)
    "#{binary} app-server"
  end
end
