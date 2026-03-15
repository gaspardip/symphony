defmodule SymphonyElixir.OrchestratorControlsPhase6Test do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{GitHubEvent, GitHubEventInbox, LeaseManager, ManualIssueStore, RunStateStore}
  alias SymphonyElixir.Orchestrator.State

  defmodule PostingGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def existing_pull_request(_workspace, _opts), do: {:error, :missing_pr}

    @impl true
    def edit_pull_request(_workspace, _title, _body_file, _opts), do: {:error, :unsupported}

    @impl true
    def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, _opts),
      do: {:error, :unsupported}

    @impl true
    def merge_pull_request(_workspace, _opts), do: {:error, :unsupported}

    @impl true
    def review_feedback(_workspace, _opts), do: {:error, :review_feedback_unavailable}

    @impl true
    def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok

    @impl true
    def post_review_comment_reply(_pr_url, comment_id, _body, _opts) do
      {:ok, %{id: "reply-#{comment_id}", url: "https://github.com/example/reply/#{comment_id}", output: ""}}
    end
  end

  defmodule ReviewFeedbackGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def existing_pull_request(_workspace, _opts), do: {:error, :missing_pr}

    @impl true
    def edit_pull_request(_workspace, _title, _body_file, _opts), do: {:error, :unsupported}

    @impl true
    def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, _opts),
      do: {:error, :unsupported}

    @impl true
    def merge_pull_request(_workspace, _opts), do: {:error, :unsupported}

    @impl true
    def review_feedback(_workspace, _opts) do
      {:ok,
       %{
         pr_url: "https://github.com/gaspardip/events/pull/8",
         review_decision: "COMMENTED",
         reviews: [],
         comments: [
           %{
             id: 91,
             body: "Please tighten this conditional.",
             path: "lib/example.ex",
             line: 2,
             created_at: "2026-03-11T12:01:00Z",
             author: "copilot-pull-request-reviewer"
           }
         ]
       }}
    end

    @impl true
    def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok

    @impl true
    def post_review_comment_reply(_pr_url, comment_id, _body, _opts) do
      {:ok, %{id: "reply-#{comment_id}", url: "https://github.com/example/reply/#{comment_id}", output: ""}}
    end
  end

  test "invalid dogfood runner install disables dispatch while keeping snapshots available" do
    runner_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-invalid-dispatch-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"],
      runner_install_root: runner_root
    )

    issue = %Issue{
      id: "issue-dogfood-runner-invalid",
      identifier: "MT-DOGFOOD-RUNNER-INVALID",
      title: "Dogfood invalid runner",
      description: "runner install should disable dispatch",
      state: "Todo",
      labels: ["dogfood:symphony"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :InvalidRunnerOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(runner_root)
    end)

    snapshot =
      Enum.reduce_while(1..20, nil, fn _, _acc ->
        Process.sleep(20)
        snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

        if get_in(snapshot, [:runner, :dispatch_enabled]) == false do
          {:halt, snapshot}
        else
          {:cont, snapshot}
        end
      end)

    assert snapshot.runner.dispatch_enabled == false
    assert snapshot.runner.runner_health == "invalid"
    assert snapshot.runner.runner_health_rule_id == "runner.install_missing"
    assert snapshot.running == []

    assert snapshot.queue == [] or
             snapshot.queue == [%{error: "{:runner_health, \"runner.install_missing\"}"}]
  end

  test "request refresh, snapshot, and queue payloads expose paused skipped and queued issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_max_concurrent_agents: 2
    )

    orchestrator_name = Module.concat(__MODULE__, :SnapshotControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    queue_issue = %Issue{
      id: "issue-queue",
      identifier: "MT-QUEUE",
      title: "Queued issue",
      description: "queue me",
      priority: 3,
      state: "Todo",
      labels: ["dogfood:symphony"]
    }

    paused_entry = %{
      identifier: "MT-PAUSED",
      resume_state: "In Progress",
      policy_class: "review_required",
      policy_source: "override",
      policy_override: "review_required",
      next_human_action: "Resume it",
      last_rule_id: "operator.pause",
      last_failure_class: "policy",
      last_decision_summary: "Paused manually",
      last_ledger_event_id: "evt-pause"
    }

    skipped_entry = %{
      issue_id: "issue-skip",
      issue_identifier: "MT-SKIP",
      state: "Todo",
      labels: ["dogfood:symphony"],
      required_labels: ["dogfood:symphony", "canary:symphony"],
      reason: "missing canary labels",
      policy_class: "fully_autonomous",
      policy_source: "label",
      policy_override: nil,
      next_human_action: "Add the canary label",
      last_rule_id: "runner.canary_active",
      last_failure_class: "policy"
    }

    state =
      :sys.get_state(pid)
      |> Map.put(:paused_issue_states, %{"issue-paused" => paused_entry})
      |> Map.put(:skipped_issues, [skipped_entry])
      |> Map.put(:last_candidate_issues, [queue_issue])
      |> Map.put(:priority_overrides, %{"MT-QUEUE" => 0})
      |> Map.put(:retry_attempts, %{"issue-queue" => %{attempt: 2, due_at_ms: now_ms + 5_000, identifier: "MT-QUEUE"}})
      |> Map.put(:candidate_fetch_error, nil)
      |> Map.put(:next_poll_due_at_ms, now_ms - 1)

    :sys.replace_state(pid, fn _ -> state end)

    refresh = Orchestrator.request_refresh(orchestrator_name)
    assert refresh.queued == true
    assert refresh.coalesced == false
    assert refresh.operations == ["events", "github_events", "reconcile"]

    refreshed_state = :sys.get_state(pid)
    assert refreshed_state.poll_check_in_progress == true
    assert refreshed_state.github_webhook_check_in_progress == true

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert [%{identifier: "MT-PAUSED", resume_state: "In Progress"}] = Map.get(snapshot, :paused)

    assert [%{issue_identifier: "MT-SKIP", reason: "missing canary labels"}] =
             snapshot.skipped

    assert [
             %{
               issue_identifier: "MT-QUEUE",
               operator_override: 0,
               retry_penalty: 2,
               label_gate_eligible: true
             }
           ] = snapshot.queue
  end

  test "github review inbox drains under invalid runner health when refreshing webhook follow-up" do
    unique = System.unique_integer([:positive])
    workspace_root = Path.join(System.tmp_dir!(), "orchestrator-github-drain-#{unique}")
    manual_store_root = Path.join(workspace_root, "manual-store")
    runner_root = Path.join(workspace_root, "missing-runner-install")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      manual_store_root: manual_store_root,
      max_concurrent_agents: 0,
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"],
      runner_install_root: runner_root,
      runner_instance_name: "canary-runner",
      runner_channel: "canary"
    )

    Application.put_env(:symphony_elixir, :pr_watcher_github_client, ReviewFeedbackGitHubClient)
    GitHubEventInbox.reset()

    {:ok, issue} =
      ManualIssueStore.submit(%{
        "id" => "orchestrator-github-drain-#{unique}",
        "identifier" => "MT-GH-DRAIN-#{unique}",
        "title" => "Drain GitHub review inbox with invalid runner health",
        "description" => "Review follow-up should still run when normal dispatch is disabled",
        "acceptance_criteria" => [
          "GitHub review feedback drains and updates the matching run state under degraded runner health"
        ],
        "policy_class" => "fully_autonomous"
      })

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(workspace)

    :ok =
      RunStateStore.save(workspace, %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_source: issue.source,
        stage: "await_checks",
        effective_policy_class: "fully_autonomous",
        pr_url: "https://github.com/gaspardip/events/pull/8",
        review_threads: %{},
        review_claims: %{},
        stage_history: [%{stage: "publish"}, %{stage: "await_checks"}],
        stage_transition_counts: %{"publish" => 1, "await_checks" => 1}
      })

    orchestrator_name = Module.concat(__MODULE__, :"GitHubDrainOrchestrator#{unique}")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      GitHubEventInbox.reset()
      File.rm_rf(workspace_root)
    end)

    {:ok, _enqueue_result} =
      GitHubEventInbox.enqueue([
        %GitHubEvent{
          provider: "github",
          event_id: "delivery-runner-health",
          event_name: "pull_request_review",
          action: "submitted",
          entity_type: "review",
          entity_id: "91",
          pr_url: "https://github.com/gaspardip/events/pull/8",
          repo_full_name: "gaspardip/events",
          updated_at: ~U[2026-03-11 12:00:00Z],
          raw: %{
            "action" => "submitted",
            "review" => %{"id" => 91, "body" => "Please tighten this conditional."},
            "pull_request" => %{"html_url" => "https://github.com/gaspardip/events/pull/8"}
          }
        }
      ])

    :ok =
      Orchestrator.notify_github_events(orchestrator_name, %{
        accepted_at: DateTime.utc_now(),
        accepted: 1,
        duplicates: 0,
        event_ids: ["delivery-runner-health"]
      })

    assert_eventually(
      fn ->
        snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
        {:ok, run_state} = RunStateStore.load(workspace)

        assert get_in(snapshot, [:runner, :dispatch_enabled]) == false
        assert get_in(snapshot, [:runner, :runner_health]) == "invalid"
        assert get_in(snapshot, [:github_inbox, :last_drained_at]) != nil
        assert get_in(snapshot, [:github_inbox, :depth]) == 0
        assert get_in(snapshot, [:github_inbox, :last_assignment, :assignment_state]) == "processed"

        assert get_in(snapshot, [:github_inbox, :last_assignment, :assignment_reason]) ==
                 "review_feedback_persisted"

        assert Map.get(run_state, :last_review_decision) == "COMMENTED"
        assert Map.get(run_state, :last_decision_summary) =~ "non-actionable noise"
        assert get_in(run_state, [:review_threads, "comment:91", "draft_state"]) == "drafted"
        assert get_in(run_state, [:review_claims, "comment:91", "disposition"]) == "dismissed"
      end,
      60
    )
  end

  test "pause and resume controls mutate orchestrator runtime state" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-pause-runtime",
      identifier: "MT-PAUSE",
      title: "Pause me",
      description: "control plane pause test",
      state: "In Progress",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :PauseResumeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    claim_issue_lease!(issue.id, issue.identifier, initial_state.lease_owner)
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      started_at: DateTime.utc_now()
    }

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
    end)

    pause_payload = Orchestrator.pause_issue(orchestrator_name, issue.identifier)
    assert pause_payload.ok == true
    assert pause_payload.action == "pause"
    assert pause_payload.state == "Paused"
    assert is_binary(pause_payload.ledger_event_id)

    paused_state = :sys.get_state(pid)
    assert paused_state.running == %{}
    assert get_in(paused_state.paused_issue_states, [issue.id, :resume_state]) == "In Progress"

    resume_payload = Orchestrator.resume_issue(orchestrator_name, issue.identifier)
    assert resume_payload.ok == true
    assert resume_payload.action == "resume"
    assert resume_payload.state == "In Progress"
    assert is_binary(resume_payload.ledger_event_id)

    resumed_state = :sys.get_state(pid)
    assert resumed_state.paused_issue_states == %{}
  end

  test "policy override, approve for merge, retry now, and reprioritize controls return structured payloads" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-policy-runtime",
      identifier: "MT-POLICY-RUNTIME",
      title: "Policy runtime",
      description: "exercise operator controls",
      state: "Human Review",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, :PolicyControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    set_payload = Orchestrator.set_policy_class(orchestrator_name, issue.identifier, "never_automerge")
    assert set_payload.ok == true
    assert set_payload.policy_class == "never_automerge"
    assert set_payload.policy_source == "override"

    approve_payload = Orchestrator.approve_issue_for_merge(orchestrator_name, issue.identifier)
    assert approve_payload.ok == false
    assert approve_payload.error == "policy forbids automerge"

    clear_payload = Orchestrator.clear_policy_override(orchestrator_name, issue.identifier)
    assert clear_payload.ok == true
    assert clear_payload.policy_class == nil
    assert clear_payload.policy_source == "label_or_default"

    approve_payload = Orchestrator.approve_issue_for_merge(orchestrator_name, issue.identifier)
    assert approve_payload.ok == true
    assert approve_payload.state == "Merging"

    retry_payload = Orchestrator.retry_issue_now(orchestrator_name, issue.identifier)
    assert retry_payload.ok == true
    assert retry_payload.action == "retry_now"

    reprioritize_payload = Orchestrator.reprioritize_issue(orchestrator_name, issue.identifier, 1)
    assert reprioritize_payload.ok == true
    assert reprioritize_payload.override_rank == 1

    reset_payload = Orchestrator.reprioritize_issue(orchestrator_name, issue.identifier, nil)
    assert reset_payload.ok == true
    assert reset_payload.override_rank == nil
  end

  test "retry_now moves blocked tracker issue without workspace back to Todo for redispatch" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-retry-blocked-no-workspace",
      identifier: "MT-RETRY-BLOCKED-NO-WS",
      title: "Retry blocked without workspace",
      description: "Should reset to Todo when no resumable workspace exists",
      state: "Blocked",
      labels: ["policy:fully-autonomous"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    issue_id = issue.id
    orchestrator_name = Module.concat(__MODULE__, :RetryBlockedNoWorkspaceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    workspace = SymphonyElixir.Workspace.path_for_issue(issue.identifier)
    File.rm_rf(workspace)

    {_, resumed_issue} =
      Orchestrator.maybe_resume_blocked_issue_for_test(:sys.get_state(pid), issue)

    assert resumed_issue.id == issue_id
    assert resumed_issue.state == "Todo"
  end

  test "review thread lifecycle controls update persisted manual thread state" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-review-threads-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    File.rm_rf(workspace_root)

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: manual_store_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, issue} =
      SymphonyElixir.ManualIssueStore.submit(%{
        "id" => "review-thread-lifecycle",
        "identifier" => "MT-REVIEW-THREADS",
        "title" => "Review lifecycle",
        "description" => "Exercise review thread controls",
        "acceptance_criteria" => ["Keep persisted review thread state in sync"],
        "policy_class" => "review_required"
      })

    workspace = Path.join(workspace_root, issue.identifier)
    init_git_workspace!(workspace, branch: "symphony/mt-review-threads")

    review_threads = %{
      "review:1" => %{
        "thread_key" => "review:1",
        "draft_state" => "drafted",
        "draft_reply" => "Draft reply"
      },
      "comment:2" => %{
        "thread_key" => "comment:2",
        "draft_state" => "drafted",
        "draft_reply" => "Inline draft reply"
      }
    }

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "human_review", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_source: issue.source,
        review_threads: review_threads,
        pr_url: "https://github.com/example/repo/pull/1"
      })

    orchestrator_name = Module.concat(__MODULE__, :ReviewThreadControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    approve_payload = Orchestrator.approve_review_drafts(orchestrator_name, issue.identifier)
    assert approve_payload.ok == true
    assert approve_payload.action == "approve_review_drafts"
    assert approve_payload.changed_threads == 2
    assert is_binary(approve_payload.ledger_event_id)

    {:ok, approved_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert get_in(approved_state, [:review_threads, "review:1", "draft_state"]) == "approved_to_post"
    assert get_in(approved_state, [:review_threads, "comment:2", "draft_state"]) == "approved_to_post"

    posted_payload = Orchestrator.mark_review_threads_posted(orchestrator_name, issue.identifier)
    assert posted_payload.ok == true
    assert posted_payload.action == "mark_review_threads_posted"
    assert posted_payload.changed_threads == 2

    {:ok, posted_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert get_in(posted_state, [:review_threads, "review:1", "draft_state"]) == "posted"
    assert get_in(posted_state, [:review_threads, "comment:2", "draft_state"]) == "posted"

    resolved_payload = Orchestrator.resolve_review_threads(orchestrator_name, issue.identifier)
    assert resolved_payload.ok == true
    assert resolved_payload.action == "resolve_review_threads"
    assert resolved_payload.changed_threads == 2

    {:ok, resolved_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert get_in(resolved_state, [:review_threads, "review:1", "draft_state"]) == "resolved"
    assert get_in(resolved_state, [:review_threads, "comment:2", "draft_state"]) == "resolved"
  end

  test "post review drafts posts approved inline replies when policy allows" do
    unique_suffix = System.unique_integer([:positive])

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-post-review-drafts-#{unique_suffix}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: manual_store_root,
      company_mode: "private_autopilot",
      company_policy_pack: "private_autopilot"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, issue} =
      SymphonyElixir.ManualIssueStore.submit(%{
        "id" => "review-post-#{unique_suffix}",
        "identifier" => "MT-REVIEW-POST-#{unique_suffix}",
        "title" => "Post approved review drafts",
        "description" => "Exercise posting approved review drafts",
        "acceptance_criteria" => ["Post approved inline review replies"],
        "policy_class" => "review_required"
      })

    workspace = Path.join(workspace_root, issue.identifier)
    init_git_workspace!(workspace, branch: "symphony/mt-review-post")

    review_threads = %{
      "review:1" => %{
        "thread_key" => "review:1",
        "draft_state" => "approved_to_post",
        "draft_reply" => "Review summary reply."
      },
      "comment:2" => %{
        "thread_key" => "comment:2",
        "draft_state" => "approved_to_post",
        "draft_reply" => "Inline draft reply"
      }
    }

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "human_review", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_source: issue.source,
        review_threads: review_threads,
        pr_url: "https://github.com/example/repo/pull/1"
      })

    previous_client = Application.get_env(:symphony_elixir, :pr_watcher_github_client)
    Application.put_env(:symphony_elixir, :pr_watcher_github_client, PostingGitHubClient)

    orchestrator_name = Module.concat(__MODULE__, :PostReviewDraftsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :pr_watcher_github_client)
      else
        Application.put_env(:symphony_elixir, :pr_watcher_github_client, previous_client)
      end
    end)

    payload = Orchestrator.post_review_drafts(orchestrator_name, issue.identifier)
    assert payload.ok == true
    assert payload.action == "post_review_drafts"
    assert payload.posted_threads == 1
    assert payload.skipped_threads == 1
    assert is_binary(payload.ledger_event_id)

    {:ok, posted_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert get_in(posted_state, [:review_threads, "comment:2", "draft_state"]) == "posted"
    assert is_binary(get_in(posted_state, [:review_threads, "comment:2", "posted_reply_id"]))
    assert is_binary(get_in(posted_state, [:review_threads, "comment:2", "posted_reply_url"]))
    assert get_in(posted_state, [:review_threads, "review:1", "draft_state"]) == "approved_to_post"
  end

  test "retry now restores a blocked manual issue to its last actionable stage" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-retry-resume-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: manual_store_root
    )

    issue = %Issue{
      id: "manual:retry-blocked",
      identifier: "MT-RETRY-BLOCKED",
      title: "Retry blocked manual issue",
      description: "resume from verify",
      state: "Blocked",
      source: :manual,
      labels: ["policy:fully-autonomous"]
    }

    workspace = Path.join(workspace_root, issue.identifier)
    init_git_workspace!(workspace, branch: "symphony/mt-retry-blocked")

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "implement", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier
      })

    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "validate", %{})
    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "verify", %{})
    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "blocked", %{})

    {:ok, _submitted_issue} =
      SymphonyElixir.ManualIssueStore.submit(%{
        "id" => "retry-blocked",
        "identifier" => issue.identifier,
        "title" => issue.title,
        "description" => issue.description,
        "acceptance_criteria" => ["Resume blocked issue"]
      })

    :ok = SymphonyElixir.ManualIssueStore.update_issue_state(issue.id, "Blocked")
    :ok = SymphonyElixir.LeaseManager.release(issue.id)
    :ok = SymphonyElixir.LeaseManager.acquire(issue.id, issue.identifier, "stale-owner")

    orchestrator_name = Module.concat(__MODULE__, :RetryResumeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    retry_payload = Orchestrator.retry_issue_now(orchestrator_name, issue.identifier)
    assert retry_payload.ok == true

    {:ok, refreshed_issue} = SymphonyElixir.ManualIssueStore.fetch_issue_by_identifier(issue.identifier)
    assert refreshed_issue.state == "In Progress"

    {:ok, run_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert run_state.stage == "verify"
    assert run_state.stop_reason == nil
    assert run_state.last_decision == nil

    {:ok, lease} = SymphonyElixir.LeaseManager.read(issue.id)
    assert lease["owner"] != "stale-owner"
  end

  test "retry now resumes a seeded blocked manual replay without a manual store record" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-retry-seeded-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: Path.join(workspace_root, "manual-store")
    )

    issue = %Issue{
      id: "manual:clz-22",
      identifier: "CLZ-22",
      title: "Seeded blocked replay",
      description: "resume from implement",
      state: "Blocked",
      source: :manual,
      labels: ["policy:fully-autonomous"]
    }

    workspace = Path.join(workspace_root, issue.identifier)
    init_git_workspace!(workspace, branch: "codex/clz-22-local-canary")

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "implement", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_source: issue.source,
        effective_policy_class: "fully_autonomous",
        runner_channel: "canary",
        branch: "codex/clz-22-local-canary"
      })

    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "blocked", %{})

    orchestrator_name = Module.concat(__MODULE__, :RetrySeededManualOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    retry_payload = Orchestrator.retry_issue_now(orchestrator_name, issue.identifier)
    assert retry_payload.ok == true

    {:ok, run_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert run_state.stage == "implement"
    assert run_state.stop_reason == nil

    {_state, resumed_issue} =
      Orchestrator.maybe_resume_blocked_issue_for_test(:sys.get_state(pid), issue)

    assert resumed_issue.state == "In Progress"
  end

  test "retry now sends verifier feedback blocks back to implement" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-retry-verifier-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: manual_store_root
    )

    issue = %Issue{
      id: "manual:retry-verifier-failed",
      identifier: "MT-RETRY-VERIFIER",
      title: "Retry verifier failed issue",
      description: "resume from implement after verifier needs more work",
      state: "Blocked",
      source: :manual,
      labels: ["policy:fully-autonomous"]
    }

    workspace = Path.join(workspace_root, issue.identifier)
    init_git_workspace!(workspace, branch: "symphony/mt-retry-verifier")

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "implement", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier
      })

    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "validate", %{})
    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "verify", %{})

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "blocked", %{
        stop_reason: %{
          code: "verifier_failed",
          rule_id: "verification.needs_more_work",
          failure_class: "verification",
          details: "needs more work"
        }
      })

    {:ok, _submitted_issue} =
      SymphonyElixir.ManualIssueStore.submit(%{
        "id" => "retry-verifier-failed",
        "identifier" => issue.identifier,
        "title" => issue.title,
        "description" => issue.description,
        "acceptance_criteria" => ["Retry after verifier asks for more work"]
      })

    :ok = SymphonyElixir.ManualIssueStore.update_issue_state(issue.id, "Blocked")

    orchestrator_name = Module.concat(__MODULE__, :RetryVerifierResumeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    retry_payload = Orchestrator.retry_issue_now(orchestrator_name, issue.identifier)
    assert retry_payload.ok == true

    {:ok, refreshed_issue} = SymphonyElixir.ManualIssueStore.fetch_issue_by_identifier(issue.identifier)
    assert refreshed_issue.state == "In Progress"

    {:ok, run_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert run_state.stage == "implement"
    assert run_state.stop_reason == nil
  end

  test "retry now falls back to checkout when the persisted run state belongs to another issue" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-retry-stale-state-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: manual_store_root
    )

    issue = %Issue{
      id: "manual:events-map-filters",
      identifier: "EVT-PILOT-01",
      title: "Retry stale-state manual issue",
      description: "resume from checkout when workspace state is stale",
      state: "Blocked",
      source: :manual,
      labels: ["policy:fully-autonomous"]
    }

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      SymphonyElixir.RunStateStore.state_path(workspace),
      Jason.encode!(%{
        issue_id: "manual:clz-14-manual",
        issue_identifier: "CLZ-14",
        stage: "publish",
        stop_reason: %{code: "noop_turn"}
      })
    )

    {:ok, _submitted_issue} =
      SymphonyElixir.ManualIssueStore.submit(%{
        "id" => "events-map-filters",
        "identifier" => issue.identifier,
        "title" => issue.title,
        "description" => issue.description,
        "acceptance_criteria" => ["Resume stale state from checkout"]
      })

    :ok = SymphonyElixir.ManualIssueStore.update_issue_state(issue.id, "Blocked")

    orchestrator_name = Module.concat(__MODULE__, :RetryStaleStateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    retry_payload = Orchestrator.retry_issue_now(orchestrator_name, issue.identifier)
    assert retry_payload.ok == true

    {:ok, refreshed_issue} = SymphonyElixir.ManualIssueStore.fetch_issue_by_identifier(issue.identifier)
    assert refreshed_issue.state == "Todo"

    {:ok, run_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert run_state.issue_id == issue.id
    assert run_state.issue_identifier == issue.identifier
    assert run_state.stage == "checkout"
    assert run_state.stop_reason == nil
  end

  test "retry now sends verifier feedback with dirty workspace back to validate" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-retry-verifier-validate-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: manual_store_root
    )

    issue = %Issue{
      id: "manual:retry-verifier-validate",
      identifier: "MT-RETRY-VERIFIER-VALIDATE",
      title: "Retry verifier dirty workspace",
      description: "resume from validate after verifier asks for more work",
      state: "Blocked",
      source: :manual,
      labels: ["policy:fully-autonomous"]
    }

    workspace = Path.join(workspace_root, issue.identifier)
    init_git_workspace!(workspace, branch: "symphony/mt-retry-verifier-validate")
    System.cmd("git", ["init"], cd: workspace)
    File.write!(Path.join(workspace, "feature.txt"), "new proof\n")

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "implement", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier
      })

    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "validate", %{})
    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "verify", %{})

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "blocked", %{
        stop_reason: %{
          code: "verifier_failed",
          rule_id: "verification.needs_more_work",
          failure_class: "verification",
          details: "needs more work"
        }
      })

    {:ok, _submitted_issue} =
      SymphonyElixir.ManualIssueStore.submit(%{
        "id" => "retry-verifier-validate",
        "identifier" => issue.identifier,
        "title" => issue.title,
        "description" => issue.description,
        "acceptance_criteria" => ["Retry from validate when workspace changed after verifier"]
      })

    :ok = SymphonyElixir.ManualIssueStore.update_issue_state(issue.id, "Blocked")

    orchestrator_name = Module.concat(__MODULE__, :RetryVerifierValidateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    retry_payload = Orchestrator.retry_issue_now(orchestrator_name, issue.identifier)
    assert retry_payload.ok == true

    {:ok, refreshed_issue} = SymphonyElixir.ManualIssueStore.fetch_issue_by_identifier(issue.identifier)
    assert refreshed_issue.state == "In Progress"

    {:ok, run_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert run_state.stage == "validate"
    assert run_state.stop_reason == nil
  end

  test "retry now resumes noop-blocked proof runs at verify when proof is already present" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-retry-proof-verify-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: manual_store_root
    )

    issue = %Issue{
      id: "manual:retry-proof-ready",
      identifier: "MT-RETRY-PROOF-READY",
      title: "Retry proof-ready issue",
      description: "resume verifier when proof is already present",
      state: "Blocked",
      source: :manual,
      labels: ["policy:fully-autonomous"]
    }

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(workspace)

    System.cmd("git", ["init"], cd: workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(Path.join(workspace, ".symphony/harness.yml"), """
    version: 1
    base_branch: main
    preflight:
      command: "echo preflight"
    validation:
      command: "echo validation"
    smoke:
      command: "echo smoke"
    post_merge:
      command: "echo post"
    artifacts:
      command: "echo artifacts"
    pull_request:
      required_checks: ["make-all"]
    verification:
      behavioral_proof:
        required: true
        mode: unit_first
        source_paths: ["Sources"]
        test_paths: ["Tests"]
    """)

    File.mkdir_p!(Path.join(workspace, "Sources"))
    File.mkdir_p!(Path.join(workspace, "Tests"))
    File.write!(Path.join([workspace, "Sources", "Feature.swift"]), "struct Feature {}\n")
    File.write!(Path.join([workspace, "Tests", "FeatureTests.swift"]), "struct FeatureTests {}\n")

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "implement", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier
      })

    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "validate", %{})
    {:ok, _} = SymphonyElixir.RunStateStore.transition(workspace, "verify", %{})

    {:ok, _} =
      SymphonyElixir.RunStateStore.transition(workspace, "blocked", %{
        stop_reason: %{
          code: "noop_turn",
          rule_id: "noop.max_turns_exceeded",
          failure_class: "implementation",
          details: "Noop after adding proof"
        },
        last_verifier: %{
          reason_code: "behavior_proof_missing"
        }
      })

    {:ok, _submitted_issue} =
      SymphonyElixir.ManualIssueStore.submit(%{
        "id" => "retry-proof-ready",
        "identifier" => issue.identifier,
        "title" => issue.title,
        "description" => issue.description,
        "acceptance_criteria" => ["Retry verify when proof is already present"]
      })

    :ok = SymphonyElixir.ManualIssueStore.update_issue_state(issue.id, "Blocked")

    orchestrator_name = Module.concat(__MODULE__, :RetryProofVerifyOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workspace_root)
    end)

    retry_payload = Orchestrator.retry_issue_now(orchestrator_name, issue.identifier)
    assert retry_payload.ok == true

    {:ok, refreshed_issue} = SymphonyElixir.ManualIssueStore.fetch_issue_by_identifier(issue.identifier)
    assert refreshed_issue.state == "In Progress"

    {:ok, run_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert run_state.stage == "verify"
    assert run_state.stop_reason == nil
  end

  test "candidate processing blocks manual issues whose policy class is disallowed by the company pack" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-policy-pack-block-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      manual_store_root: manual_store_root,
      company_policy_pack: "client_safe"
    )

    {:ok, issue} =
      SymphonyElixir.ManualIssueStore.submit(%{
        "id" => "policy-pack-blocked",
        "identifier" => "MT-POLICY-PACK-BLOCKED",
        "title" => "Client-safe pack should block fully autonomous issues",
        "description" => "prove pre-dispatch policy pack blocking",
        "policy_class" => "fully_autonomous",
        "labels" => ["symphony:events"],
        "acceptance_criteria" => ["The issue is blocked before implementation."]
      })

    on_exit(fn -> File.rm_rf(workspace_root) end)

    next_state =
      Orchestrator.process_candidate_issues_for_test(%Orchestrator.State{}, [issue])

    assert next_state.skipped_issues == []

    {:ok, refreshed_issue} =
      SymphonyElixir.ManualIssueStore.fetch_issue_by_identifier(issue.identifier)

    assert refreshed_issue.state == "Blocked"

    {:ok, record} =
      SymphonyElixir.ManualIssueStore.load_record_by_identifier(issue.identifier)

    assert record.last_decision_summary == "Moved to Blocked"
    assert Enum.any?(record.comments, &String.contains?(Map.get(&1, "body", ""), "policy.pack_disallows_class"))
  end

  test "dispatch helper functions cover label gates blockers and revalidation outcomes" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["dogfood:symphony"],
      agent_max_concurrent_agents: 1
    )

    eligible_issue = %Issue{
      id: "issue-eligible",
      identifier: "MT-ELIGIBLE",
      title: "Eligible",
      description: "can dispatch",
      state: "Todo",
      labels: ["dogfood:symphony"],
      assigned_to_worker: true
    }

    blocked_todo =
      Map.put(eligible_issue, :blocked_by, [%{state: "In Progress"}])

    missing_label_issue =
      %{eligible_issue | id: "issue-missing-label", identifier: "MT-MISSING-LABEL", labels: ["ops"]}

    claimed_state = %State{
      max_concurrent_agents: 1,
      claimed: MapSet.new(["issue-eligible"])
    }

    assert Orchestrator.should_dispatch_issue_for_test(eligible_issue, claimed_state) == false
    assert Orchestrator.should_dispatch_issue_for_test(blocked_todo, %State{max_concurrent_agents: 1}) == false
    assert Orchestrator.should_dispatch_issue_for_test(missing_label_issue, %State{max_concurrent_agents: 1}) == false
    assert Orchestrator.should_dispatch_issue_for_test(eligible_issue, %State{max_concurrent_agents: 1}) == true

    second_issue = %{eligible_issue | id: "issue-second", identifier: "MT-SECOND", priority: 4}
    third_issue = %{eligible_issue | id: "issue-third", identifier: "MT-THIRD", priority: 0}

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test(
        [second_issue, eligible_issue, third_issue],
        %State{priority_overrides: %{"MT-SECOND" => 0}, retry_attempts: %{"issue-third" => 3}}
      )

    assert Enum.map(sorted, & &1.identifier) == ["MT-SECOND", "MT-ELIGIBLE", "MT-THIRD"]

    assert {:skip, :missing} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(eligible_issue, fn [_id] -> {:ok, []} end)

    manual_issue = %Issue{
      id: "manual:issue-seeded",
      identifier: "MT-MANUAL",
      title: "Seeded manual replay",
      state: "In Progress",
      source: :manual
    }

    assert {:ok, ^manual_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(manual_issue, fn [_id] ->
               {:ok, []}
             end)

    assert {:skip, %Issue{state: "Done"}} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(eligible_issue, fn [_id] ->
               {:ok, [%{eligible_issue | state: "Done"}]}
             end)

    assert {:error, :boom} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(eligible_issue, fn [_id] ->
               {:error, :boom}
             end)
  end

  test "dispatch helper wrappers cover success skip and refresh-error branches" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    terminal_states = MapSet.new(["done"])
    refute Orchestrator.terminal_issue_state_for_test(%{}, terminal_states)

    issue = %Issue{
      id: "issue-dispatch-skip",
      identifier: "MT-DISPATCH-SKIP",
      title: "Dispatch skip",
      description: "cover skip logging",
      state: "Todo",
      labels: ["ops"]
    }

    dispatched_state =
      Orchestrator.dispatch_issue_for_test(%State{}, issue,
        attempt: 3,
        issue_fetcher: fn [_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
        dispatch_fun: fn state, refreshed_issue, attempt ->
          send(self(), {:dispatch_fun_called, refreshed_issue.identifier, refreshed_issue.state, attempt})
          %{state | candidate_fetch_error: refreshed_issue.state}
        end
      )

    assert_receive {:dispatch_fun_called, "MT-DISPATCH-SKIP", "In Progress", 3}
    assert %State{candidate_fetch_error: "In Progress"} = dispatched_state

    missing_log =
      capture_log(fn ->
        assert %State{} =
                 Orchestrator.dispatch_issue_for_test(%State{}, issue, issue_fetcher: fn [_id] -> {:ok, []} end)
      end)

    assert missing_log =~
             "Skipping dispatch; issue no longer active or visible: issue_id=issue-dispatch-skip issue_identifier=MT-DISPATCH-SKIP"

    stale_log =
      capture_log(fn ->
        assert %State{} =
                 Orchestrator.dispatch_issue_for_test(%State{}, issue, issue_fetcher: fn [_id] -> {:ok, [%{issue | state: "Done"}]} end)
      end)

    assert stale_log =~
             "Skipping stale dispatch after issue refresh: issue_id=issue-dispatch-skip issue_identifier=MT-DISPATCH-SKIP"

    assert stale_log =~ "state=\"Done\""
    assert stale_log =~ "blocked_by=0"

    error_log =
      capture_log(fn ->
        assert %State{} =
                 Orchestrator.dispatch_issue_for_test(%State{}, issue, issue_fetcher: fn [_id] -> {:error, :boom} end)
      end)

    assert error_log =~
             "Skipping dispatch; issue refresh failed for issue_id=issue-dispatch-skip issue_identifier=MT-DISPATCH-SKIP: :boom"
  end

  test "default dispatch path and direct worker dispatch helpers cover the real spawn path" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-default-dispatch-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: nil,
      runner_instance_name: "stable-runner",
      runner_channel: "stable"
    )

    issue = %Issue{
      id: "issue-default-dispatch",
      identifier: "MT-DEFAULT-DISPATCH",
      title: "Default dispatch",
      description: "cover real dispatch path",
      state: "Todo",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    owner = "dispatch-owner-#{System.unique_integer([:positive])}"

    assert %State{} =
             Orchestrator.dispatch_issue_for_test(
               %State{lease_owner: owner, max_concurrent_agents: 1},
               issue
             )

    spawned_issue = %{
      issue
      | id: "issue-direct-dispatch",
        identifier: "MT-DIRECT-DISPATCH",
        title: "Direct dispatch"
    }

    state =
      Orchestrator.do_dispatch_issue_for_test(
        %State{lease_owner: owner, max_concurrent_agents: 1},
        spawned_issue
      )

    refute state.running == %{} and state.retry_attempts == %{}

    pid =
      case Map.get(state.running, spawned_issue.id) do
        %{pid: running_pid} when is_pid(running_pid) -> running_pid
        _ -> nil
      end

    workspace = Path.join(workspace_root, spawned_issue.identifier)
    assert {:ok, run_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert {:ok, lease} = LeaseManager.read(spawned_issue.id)
    assert run_state.lease_owner == owner
    assert run_state.lease_owner == lease["owner"]
    assert run_state.lease_owner_channel == "stable"
    assert run_state.lease_owner_instance_id == "stable:stable-runner"
    assert run_state.lease_epoch == lease["epoch"]
    assert run_state.lease_status == "held"

    on_exit(fn ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      LeaseManager.release(issue.id, owner)
      LeaseManager.release(spawned_issue.id, owner)
      File.rm_rf(workspace_root)
    end)
  end

  test "dispatch helpers cover lease acquisition and worker spawn failures" do
    owner = "dispatch-owner-#{System.unique_integer([:positive])}"

    issue = %Issue{
      id: "issue-dispatch-errors",
      identifier: "MT-DISPATCH-ERRORS",
      title: "Dispatch errors",
      description: "cover orchestrator error paths",
      state: "Todo",
      labels: ["ops"]
    }

    lease_log =
      capture_log(fn ->
        returned_state =
          Orchestrator.do_dispatch_issue_for_test(
            %State{lease_owner: owner},
            issue,
            nil,
            acquire_fun: fn _, _, _ -> {:error, :disk_full} end
          )

        assert returned_state == %State{lease_owner: owner}
      end)

    assert lease_log =~
             "Skipping dispatch; failed to acquire lease for issue_id=issue-dispatch-errors issue_identifier=MT-DISPATCH-ERRORS: :disk_full"

    spawned_state =
      Orchestrator.do_spawn_issue_worker_for_test(
        %State{lease_owner: owner},
        %{issue | id: "issue-spawn-errors", identifier: "MT-SPAWN-ERRORS"},
        4,
        self(),
        start_child_fun: fn _supervisor, _fun -> {:error, :noproc} end
      )

    retry_entry = Map.fetch!(spawned_state.retry_attempts, "issue-spawn-errors")
    assert retry_entry.attempt == 5
    assert retry_entry.identifier == "MT-SPAWN-ERRORS"
    assert retry_entry.error =~ "failed to spawn agent: :noproc"
  end

  test "dispatch clears persisted lease metadata when worker startup fails after lease acquisition" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-dispatch-lease-clear-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      runner_instance_name: "stable-runner",
      runner_channel: "stable"
    )

    owner = "dispatch-owner-#{System.unique_integer([:positive])}"

    issue = %Issue{
      id: "issue-dispatch-clear",
      identifier: "MT-DISPATCH-CLEAR",
      title: "Dispatch clears lease",
      description: "cover persisted lease cleanup on startup failure",
      state: "Todo",
      labels: ["ops"]
    }

    returned_state =
      Orchestrator.do_dispatch_issue_for_test(
        %State{lease_owner: owner},
        issue,
        2,
        spawn_fun: fn dispatch_state, dispatch_issue, attempt, recipient ->
          Orchestrator.do_spawn_issue_worker_for_test(
            dispatch_state,
            dispatch_issue,
            attempt,
            recipient,
            start_child_fun: fn _supervisor, _fun -> {:error, :noproc} end
          )
        end
      )

    retry_entry = Map.fetch!(returned_state.retry_attempts, issue.id)
    assert retry_entry.attempt == 3
    assert retry_entry.identifier == issue.identifier
    assert match?({:error, :missing}, LeaseManager.read(issue.id))

    workspace = Path.join(workspace_root, issue.identifier)
    assert {:ok, run_state} = SymphonyElixir.RunStateStore.load(workspace)
    assert run_state.lease_owner == nil
    assert run_state.lease_owner_instance_id == nil
    assert run_state.lease_owner_channel == nil
    assert run_state.lease_acquired_at == nil
    assert run_state.lease_updated_at == nil
    assert run_state.lease_status == nil
    assert run_state.lease_epoch == nil

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)
  end

  test "dispatch default wrappers cover claimed leases and default worker spawning" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-wrapper-dispatch-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: nil
    )

    issue = %Issue{
      id: "issue-wrapper-dispatch",
      identifier: "MT-WRAPPER-DISPATCH",
      title: "Wrapper dispatch",
      description: "cover wrapper branches",
      state: "Todo",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    missing_log =
      capture_log(fn ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

        assert %State{} =
                 Orchestrator.dispatch_issue_default_for_test(
                   %State{lease_owner: "wrapper-owner-1"},
                   issue,
                   7
                 )
      end)

    assert missing_log =~
             "Skipping dispatch; issue no longer active or visible: issue_id=issue-wrapper-dispatch issue_identifier=MT-WRAPPER-DISPATCH"

    claimed_log =
      capture_log(fn ->
        returned_state =
          Orchestrator.do_dispatch_issue_for_test(
            %State{lease_owner: "wrapper-owner-2"},
            issue,
            nil,
            acquire_fun: fn _, _, _ -> {:error, :claimed} end
          )

        assert returned_state == %State{lease_owner: "wrapper-owner-2"}
      end)

    assert claimed_log =~
             "Skipping dispatch; lease already held for issue_id=issue-wrapper-dispatch issue_identifier=MT-WRAPPER-DISPATCH"

    spawned_issue = %{issue | id: "issue-wrapper-spawn", identifier: "MT-WRAPPER-SPAWN"}

    state =
      Orchestrator.do_spawn_issue_worker_default_for_test(
        %State{lease_owner: "wrapper-owner-3"},
        spawned_issue,
        nil,
        self()
      )

    pid =
      case Map.get(state.running, spawned_issue.id) do
        %{pid: running_pid} when is_pid(running_pid) -> running_pid
        _ -> nil
      end

    assert is_pid(pid)

    on_exit(fn ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      LeaseManager.release(spawned_issue.id, "wrapper-owner-3")
      File.rm_rf(workspace_root)
    end)
  end

  test "dispatch wrapper default arities cover omitted optional arguments" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-wrapper-default-arity-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: nil
    )

    issue = %Issue{
      id: "issue-wrapper-default-arity",
      identifier: "MT-WRAPPER-DEFAULT-ARITY",
      title: "Wrapper defaults",
      description: "cover omitted optional args",
      state: "Todo",
      labels: ["ops"]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert %State{} =
             Orchestrator.dispatch_issue_default_for_test(
               %State{lease_owner: "wrapper-owner-4", max_concurrent_agents: 1},
               issue
             )

    assert %State{} =
             Orchestrator.dispatch_issue_private_head_for_test(
               %State{lease_owner: "wrapper-owner-4b", max_concurrent_agents: 1},
               issue,
               nil
             )

    spawned_issue = %{issue | id: "issue-wrapper-default-spawn", identifier: "MT-WRAPPER-DEFAULT-SPAWN"}

    state =
      Orchestrator.do_spawn_issue_worker_for_test(
        %State{lease_owner: "wrapper-owner-5"},
        spawned_issue,
        nil,
        self()
      )

    pid =
      case Map.get(state.running, spawned_issue.id) do
        %{pid: running_pid} when is_pid(running_pid) -> running_pid
        _ -> nil
      end

    assert is_pid(pid)

    on_exit(fn ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      LeaseManager.release(issue.id, "wrapper-owner-4")
      LeaseManager.release(issue.id, "wrapper-owner-4b")
      LeaseManager.release(spawned_issue.id, "wrapper-owner-5")
      File.rm_rf(workspace_root)
    end)
  end

  test "revalidate passthrough and retry scheduling helpers cover fallback and timer cancellation branches" do
    assert {:ok, %{id: "passthrough"}} =
             Orchestrator.revalidate_issue_passthrough_for_test(%{id: "passthrough"})

    old_timer = Process.send_after(self(), :stale_retry, 10_000)

    state =
      Orchestrator.schedule_issue_retry_for_test(
        %State{
          retry_attempts: %{
            "issue-retry-cancel" => %{
              attempt: 2,
              timer_ref: old_timer,
              identifier: "MT-RETRY-CANCEL",
              error: "old error"
            }
          }
        },
        "issue-retry-cancel",
        nil,
        %{
          identifier: "MT-RETRY-CANCEL",
          error: "new error",
          delay_type: :passive_continuation,
          issue: %Issue{id: "issue-retry-cancel", identifier: "MT-RETRY-CANCEL"}
        }
      )

    retry_entry = Map.fetch!(state.retry_attempts, "issue-retry-cancel")
    assert retry_entry.attempt == 3
    assert retry_entry.identifier == "MT-RETRY-CANCEL"
    assert retry_entry.error == "new error"
    assert retry_entry.delay_type == :passive_continuation
    assert retry_entry.issue.identifier == "MT-RETRY-CANCEL"
    assert is_reference(retry_entry.timer_ref)
    assert retry_entry.timer_ref != old_timer
    assert Process.read_timer(old_timer) == false

    on_exit(fn ->
      Process.cancel_timer(retry_entry.timer_ref)
    end)
  end

  test "passive retry path uses issue lookup instead of candidate list fetch" do
    issue_id = "manual:issue-passive-retry"
    identifier = "MT-PASSIVE-RETRY"
    owner = "passive-retry-owner"

    state = %State{
      lease_owner: owner,
      claimed: MapSet.new([issue_id])
    }

    {:noreply, next_state} =
      Orchestrator.handle_retry_issue_for_test(
        state,
        issue_id,
        1,
        %{identifier: identifier, delay_type: :passive_continuation},
        {:error, :candidate_fetch_should_not_run},
        {:ok, nil}
      )

    refute MapSet.member?(next_state.claimed, issue_id)
    refute Map.has_key?(next_state.retry_attempts, issue_id)
  end

  test "manual continuation retry reuses seeded issue metadata when tracker lookup is empty" do
    issue_id = "manual:issue-continuation-retry"
    identifier = "MT-CONTINUATION-RETRY"

    issue = %Issue{
      id: issue_id,
      identifier: identifier,
      title: "Continuation retry",
      state: "In Progress",
      source: :manual
    }

    {:noreply, next_state} =
      Orchestrator.handle_retry_issue_for_test(
        %State{max_concurrent_agents: 0},
        issue_id,
        1,
        %{identifier: identifier, delay_type: :continuation, issue: issue},
        {:ok, []}
      )

    retry_entry = Map.fetch!(next_state.retry_attempts, issue_id)
    assert retry_entry.attempt == 2
    assert retry_entry.identifier == identifier
    assert retry_entry.issue == issue
    assert retry_entry.error == "no available orchestrator slots"
  end

  test "control resolution falls back to seeded manual run state when tracker lookup is empty" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-control-seeded-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      runner_channel: "canary"
    )

    identifier = "MT-CONTROL-SEEDED"
    workspace = Workspace.path_for_issue(identifier)

    try do
      File.mkdir_p!(workspace)

      assert {:ok, _state} =
               SymphonyElixir.RunStateStore.transition(workspace, "implement", %{
                 issue_id: "manual:control-seeded",
                 issue_identifier: identifier,
                 issue_source: :manual,
                 issue_state: "In Progress",
                 effective_policy_class: "fully_autonomous",
                 runner_channel: "canary",
                 branch: "codex/control-seeded"
               })

      assert {:ok, %Issue{} = issue} =
               Orchestrator.resolve_issue_for_control_for_test(%State{}, identifier)

      assert issue.id == "manual:control-seeded"
      assert issue.identifier == identifier
      assert issue.source == :manual
      assert issue.branch_name == "codex/control-seeded"
      assert "canary:symphony" in issue.labels
    after
      File.rm_rf(workspace_root)
    end
  end

  test "passive continuation metadata backs off await_checks retries based on poll count" do
    identifier = "MT-PASSIVE-DELAY"
    workspace = Workspace.path_for_issue(identifier)

    File.rm_rf!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, _state} =
             SymphonyElixir.RunStateStore.transition(workspace, "await_checks", %{
               issue_id: "manual:passive-delay",
               issue_identifier: identifier,
               await_checks_polls: 6
             })

    metadata =
      Orchestrator.continuation_metadata_for_running_entry_for_test(%{identifier: identifier})

    assert metadata.delay_type == :passive_continuation
    assert metadata.passive_delay_ms == 30_000
  end

  test "blocked review-fix budget stop with addressed claim progress auto-continues" do
    identifier = "MT-REVIEW-FIX-AUTO-CONTINUE"
    workspace = Workspace.path_for_issue(identifier)

    File.rm_rf!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, _state} =
             SymphonyElixir.RunStateStore.transition(workspace, "blocked", %{
               issue_id: "manual:auto-continue",
               issue_identifier: identifier,
               last_rule_id: "budget.per_turn_input_exceeded",
               stop_reason: %{
                 code: "per_turn_input_budget_exceeded",
                 rule_id: "budget.per_turn_input_exceeded"
               },
               last_turn_result: %{
                 blocked: false,
                 needs_another_turn: true,
                 summary: "Addressed one scoped review claim and need another turn."
               },
               review_claims: %{
                 "comment:1" => %{
                   "disposition" => "accepted",
                   "actionable" => false,
                   "implementation_status" => "addressed"
                 },
                 "comment:2" => %{
                   "disposition" => "accepted",
                   "actionable" => true
                 }
               }
             })

    metadata =
      Orchestrator.continuation_metadata_for_running_entry_for_test(%{identifier: identifier})

    assert metadata.delay_type == :continuation
  end

  test "blocked review-fix budget stop without claim progress stays blocked" do
    identifier = "MT-REVIEW-FIX-HOLD"
    workspace = Workspace.path_for_issue(identifier)

    File.rm_rf!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, _state} =
             SymphonyElixir.RunStateStore.transition(workspace, "blocked", %{
               issue_id: "manual:hold",
               issue_identifier: identifier,
               last_rule_id: "budget.per_turn_input_exceeded",
               stop_reason: %{
                 code: "per_turn_input_budget_exceeded",
                 rule_id: "budget.per_turn_input_exceeded"
               },
               last_turn_result: %{
                 blocked: false,
                 needs_another_turn: true,
                 summary: "Need another turn."
               },
               review_claims: %{
                 "comment:1" => %{
                   "disposition" => "accepted",
                   "actionable" => true
                 }
               }
             })

    metadata =
      Orchestrator.continuation_metadata_for_running_entry_for_test(%{identifier: identifier})

    assert metadata.delay_type == :none
  end

  test "budget-stopped review-fix runs schedule a continuation retry when claim progress exists" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-budget-stop-continuation-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      policy_token_budget: %{
        per_turn_input: 250_000,
        stages: %{
          implement: %{
            per_turn_input_soft: 60_000,
            per_turn_input_hard: 220_000
          }
        }
      }
    )

    issue = %Issue{
      id: "manual:budget-continuation",
      identifier: "MT-BUDGET-CONTINUATION",
      title: "Budget continuation",
      description: "keep moving after a scoped review-fix budget stop",
      state: "In Progress",
      source: :manual
    }

    workspace = Workspace.path_for_issue(issue.identifier)
    File.rm_rf!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    assert {:ok, _state} =
             SymphonyElixir.RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               review_claims: %{
                 "comment:1" => %{
                   "disposition" => "accepted",
                   "actionable" => false,
                   "implementation_status" => "addressed"
                 },
                 "comment:2" => %{
                   "disposition" => "accepted",
                   "actionable" => true
                 }
               },
               resume_context: %{
                 token_pressure: "high",
                 review_fix_budget_retry_count: 2,
                 implementation_turn_window_base: 12
               },
               last_turn_result: %{
                 blocked: false,
                 needs_another_turn: true,
                 summary: "Addressed one scoped review claim and need another turn."
               }
             })

    running_entry = %{
      issue: issue,
      identifier: issue.identifier,
      workspace_path: workspace,
      stage: "implement",
      codex_input_tokens: 248_759,
      codex_output_tokens: 0,
      codex_total_tokens: 248_759,
      turn_started_input_tokens: 0
    }

    state =
      Orchestrator.maybe_stop_issue_for_token_budget_for_test(
        %State{running: %{issue.id => running_entry}, lease_owner: "test-owner"},
        issue.id,
        running_entry
      )

    retry_entry = Map.fetch!(state.retry_attempts, issue.id)
    assert retry_entry.attempt == 1
    assert retry_entry.identifier == issue.identifier
    assert retry_entry.delay_type == :continuation
    assert retry_entry.issue == issue
  end

  test "budget-stopped runs without review-fix progress do not schedule continuation retries" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "orchestrator-budget-stop-no-continuation-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      policy_token_budget: %{
        per_turn_input: 250_000,
        stages: %{
          implement: %{
            per_turn_input_soft: 60_000,
            per_turn_input_hard: 220_000
          }
        }
      }
    )

    issue = %Issue{
      id: "manual:budget-no-continuation",
      identifier: "MT-BUDGET-NO-CONTINUATION",
      title: "Budget hold",
      description: "do not auto-continue without claim progress",
      state: "In Progress",
      source: :manual
    }

    workspace = Workspace.path_for_issue(issue.identifier)
    File.rm_rf!(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    assert {:ok, _state} =
             SymphonyElixir.RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               review_claims: %{
                 "comment:1" => %{
                   "disposition" => "accepted",
                   "actionable" => true
                 }
               },
               resume_context: %{
                 token_pressure: "high",
                 review_fix_budget_retry_count: 2,
                 implementation_turn_window_base: 12
               },
               last_turn_result: %{
                 blocked: false,
                 needs_another_turn: true,
                 summary: "Need another turn."
               }
             })

    running_entry = %{
      issue: issue,
      identifier: issue.identifier,
      workspace_path: workspace,
      stage: "implement",
      codex_input_tokens: 248_759,
      codex_output_tokens: 0,
      codex_total_tokens: 248_759,
      turn_started_input_tokens: 0
    }

    state =
      Orchestrator.maybe_stop_issue_for_token_budget_for_test(
        %State{running: %{issue.id => running_entry}, lease_owner: "test-owner"},
        issue.id,
        running_entry
      )

    refute Map.has_key?(state.retry_attempts, issue.id)
  end

  test "passive dispatch reuses existing claim and marks running entry as passive" do
    issue = %Issue{
      id: "issue-passive-running",
      identifier: "MT-PASSIVE-RUNNING",
      title: "Passive running",
      description: "passive dispatch",
      state: "Merging",
      labels: []
    }

    worker = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker) do
        Process.exit(worker, :kill)
      end
    end)

    state =
      Orchestrator.dispatch_passive_issue_for_test(
        %State{lease_owner: "passive-owner", claimed: MapSet.new([issue.id])},
        issue,
        spawn_fun: fn dispatch_state, dispatch_issue, attempt, recipient ->
          Orchestrator.do_spawn_passive_worker_for_test(
            dispatch_state,
            dispatch_issue,
            attempt,
            recipient,
            start_child_fun: fn _supervisor, fun ->
              send(self(), {:passive_spawn_invoked, fun})
              {:ok, worker}
            end
          )
        end
      )

    assert_received {:passive_spawn_invoked, _fun}

    assert %{passive?: true, issue: ^issue, identifier: "MT-PASSIVE-RUNNING"} =
             Map.fetch!(state.running, issue.id)

    assert MapSet.member?(state.claimed, issue.id)
  end

  test "stage-aware runtime dispatch routes await_checks issues to passive dispatch" do
    workspace_root =
      Path.join(System.tmp_dir!(), "orchestrator-runtime-dispatch-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, tracker_kind: "memory")

    issue = %Issue{
      id: "issue-runtime-passive",
      identifier: "MT-RUNTIME-PASSIVE",
      title: "Runtime passive",
      description: "dispatch routing",
      state: "Merging",
      labels: []
    }

    workspace = Path.join(workspace_root, issue.identifier)
    init_git_workspace!(workspace, branch: "symphony/mt-runtime-passive")

    SymphonyElixir.RunStateStore.transition(workspace, "await_checks", %{
      issue_id: issue.id,
      issue_identifier: issue.identifier
    })

    on_exit(fn ->
      File.rm_rf(workspace_root)
    end)

    assert %{mode: :passive, issue: ^issue, attempt: 2} =
             Orchestrator.dispatch_runtime_issue_for_test(
               %State{},
               issue,
               2,
               active_dispatch_fun: fn _state, dispatch_issue, attempt ->
                 %{mode: :active, issue: dispatch_issue, attempt: attempt}
               end,
               passive_dispatch_fun: fn _state, dispatch_issue, attempt ->
                 %{mode: :passive, issue: dispatch_issue, attempt: attempt}
               end
             )
  end

  test "stop hold and validation error branches on operator controls return structured failures" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issues = [
      %Issue{
        id: "issue-stop-runtime",
        identifier: "MT-STOP-RUNTIME",
        title: "Stop runtime",
        description: "stop control",
        state: "In Progress",
        labels: ["ops"]
      },
      %Issue{
        id: "issue-hold-runtime",
        identifier: "MT-HOLD-RUNTIME",
        title: "Hold runtime",
        description: "hold control",
        state: "In Progress",
        labels: ["ops"]
      }
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    orchestrator_name = Module.concat(__MODULE__, :StopHoldControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    stop_payload = Orchestrator.stop_issue(orchestrator_name, "MT-STOP-RUNTIME")
    assert stop_payload.ok == true
    assert stop_payload.state == "Blocked"
    assert stop_payload.action == "stop"

    hold_payload = Orchestrator.hold_issue_for_human_review(orchestrator_name, "MT-HOLD-RUNTIME")
    assert hold_payload.ok == true
    assert hold_payload.state == "Human Review"
    assert hold_payload.action == "hold_for_human_review"

    assert %{ok: false, error: "blank issue identifier"} =
             Orchestrator.reprioritize_issue(orchestrator_name, "   ", 1)

    assert %{ok: false, error: "blank issue identifier"} =
             Orchestrator.set_policy_class(orchestrator_name, "   ", "review_required")

    assert %{ok: false, error: "invalid policy class"} =
             Orchestrator.set_policy_class(orchestrator_name, "MT-HOLD-RUNTIME", "bogus")

    assert %{ok: false, error: "blank issue identifier"} =
             Orchestrator.clear_policy_override(orchestrator_name, "   ")
  end

  test "snapshot surfaces queue fetch errors when no dispatchable issues remain" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :QueueErrorOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_candidate_issues: [],
          candidate_fetch_error: :linear_timeout
      }
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert [%{error: ":linear_timeout"}] = snapshot.queue
  end

  defp claim_issue_lease!(issue_id, identifier, owner) do
    assert :ok = LeaseManager.acquire(issue_id, identifier, owner)

    on_exit(fn ->
      LeaseManager.release(issue_id)
    end)
  end

  defp assert_eventually(fun, attempts \\ 60)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp init_git_workspace!(workspace, opts \\ []) do
    branch = Keyword.get(opts, :branch, "main")
    File.mkdir_p!(workspace)
    assert {_, 0} = System.cmd("git", ["init", "-b", branch], cd: workspace)
    assert {_, 0} = System.cmd("git", ["config", "user.name", "Symphony Test"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["config", "user.email", "symfony@example.com"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "# test\n")
    assert {_, 0} = System.cmd("git", ["add", "README.md"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: workspace)
  end
end
