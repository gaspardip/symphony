defmodule SymphonyElixir.OrchestratorArchivedWorkspaceTest do
  use SymphonyElixir.TestSupport
  @moduletag timeout: 120_000

  alias SymphonyElixir.{GitHubEvent, GitHubEventInbox, LeaseManager, ManualIssueStore, RunStateStore}

  @pr_url "https://github.com/local-fixture/archive-filtering/pull/1"

  defmodule ClosedGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def review_feedback(workspace, _opts) do
      record("review_feedback", workspace)

      {:ok,
       %{
         pr_url: "https://github.com/local-fixture/archive-filtering/pull/1",
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
    def existing_pull_request(workspace, _opts), do: forbidden("existing_pull_request", workspace)
    @impl true
    def edit_pull_request(workspace, _title, _body, _opts), do: forbidden("edit_pull_request", workspace)
    @impl true
    def create_pull_request(workspace, _branch, _base, _title, _body, _opts),
      do: forbidden("create_pull_request", workspace)

    @impl true
    def merge_pull_request(workspace, _opts), do: forbidden("merge_pull_request", workspace)
    @impl true
    def persist_pr_url(workspace, _branch, _url, _opts), do: forbidden("persist_pr_url", workspace)
    @impl true
    def post_review_comment_reply(url, _id, _body, _opts), do: forbidden("post_review_comment_reply", url)

    defp forbidden(callback, workspace) do
      record(callback, workspace)
      raise "unexpected GitHub callback in archived workspace test: #{callback}"
    end

    defp record(callback, workspace) do
      path = Application.fetch_env!(:symphony_elixir, :archived_workspace_test_callback_path)
      File.write!(path, Jason.encode!(%{callback: callback, workspace: workspace}) <> "\n", [:append])
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-archived-workspace-#{unique}")
    File.mkdir_p!(Path.join(root, "log"))
    callback_path = Path.join(root, "callbacks.jsonl")
    File.write!(callback_path, "")

    keys = [:log_file, :memory_tracker_issues, :pr_watcher_github_client, :archived_workspace_test_callback_path]
    previous = Map.new(keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})

    on_exit(fn ->
      case Process.whereis(__MODULE__.Runtime) do
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 5_000)
        nil -> :ok
      end

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
      end)

      File.rm_rf!(root)
    end)

    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "log/symphony.log"))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :pr_watcher_github_client, ClosedGitHubClient)
    Application.put_env(:symphony_elixir, :archived_workspace_test_callback_path, callback_path)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      manual_store_root: Path.join(root, "manual"),
      runner_install_root: Path.join(root, "runner"),
      runner_instance_name: "archived-workspace-test",
      company_policy_pack: "private_autopilot",
      company_author_profile_path: Path.join(root, "author-profile.json"),
      company_credential_registry_path: Path.join(root, "credential-registry.json"),
      max_concurrent_agents: 0,
      codex_command: "/usr/bin/false",
      codex_runtime_profile_inherit_env: false,
      policy_publish_required: false,
      poll_interval_ms: 60_000
    )

    assert :ok = Config.validate!()
    assert %{depth: 0} = GitHubEventInbox.stats()
    assert {:ok, []} = SymphonyElixir.Tracker.Memory.fetch_candidate_issues()

    assert {:ok, issue} =
             ManualIssueStore.submit(%{
               "id" => "archived-workspace-#{unique}",
               "identifier" => "MT/ARCHIVE-#{unique}",
               "title" => "Keep archived snapshots outside GitHub follow-up",
               "description" => "Only the canonical workspace should receive this PR event.",
               "acceptance_criteria" => ["An archived copy retains its original snapshot bytes."],
               "policy_class" => "fully_autonomous"
             })

    canonical = Workspace.path_for_issue(issue)
    assert canonical == Path.join(Config.workspace_root(), "MT_ARCHIVE-#{unique}")
    archived = canonical <> ".base-branch-blocked"

    Enum.each([canonical, archived], fn workspace ->
      File.mkdir_p!(workspace)

      assert :ok =
               RunStateStore.save(workspace, %{
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 issue_source: issue.source,
                 stage: "await_checks",
                 effective_policy_class: "fully_autonomous",
                 pr_url: @pr_url,
                 review_threads: if(workspace == archived, do: %{"comment:91" => %{"draft_state" => "posted"}}, else: %{}),
                 review_claims: %{},
                 stage_history: [%{stage: "publish"}, %{stage: "await_checks"}],
                 stage_transition_counts: %{"publish" => 1, "await_checks" => 1}
               })
    end)

    {canonical_state, _canonical_bytes} = read_snapshot!(canonical)
    {archived_state, archived_bytes} = read_snapshot!(archived)
    metadata = [:runner_instance_id, :runner_instance_name, :runner_channel, :runner_workspace_root]
    assert Map.take(canonical_state, metadata) == Map.take(archived_state, metadata)
    assert canonical_state.runner_instance_id == Config.runner_instance_id()
    assert canonical_state.runner_workspace_root == Config.workspace_root()

    assert {:ok, pid} = Orchestrator.start_link(name: __MODULE__.Runtime)

    assert_eventually(fn ->
      snapshot = Orchestrator.snapshot(pid, 5_000)
      assert is_map(snapshot)
      assert snapshot.running == []
      assert snapshot.polling.checking? == false
      assert is_integer(snapshot.polling.next_poll_in_ms)
      assert snapshot.polling.next_poll_in_ms > 0
    end)

    {:ok, pid: pid, issue: issue, canonical: canonical, archived: archived, archived_bytes: archived_bytes, callback_path: callback_path, unique: unique}
  end

  test "review inbox refreshes the canonical workspace and leaves an archived copy untouched", fixture do
    event = %GitHubEvent{
      provider: "github",
      event_id: "review-#{fixture.unique}",
      event_name: "pull_request_review",
      action: "submitted",
      entity_type: "review",
      entity_id: "91",
      pr_url: @pr_url,
      repo_full_name: "local-fixture/archive-filtering",
      updated_at: ~U[2026-03-11 12:01:00Z],
      raw: %{"action" => "submitted", "review" => %{"id" => 91}, "pull_request" => %{"html_url" => @pr_url}}
    }

    drain_and_stop!(fixture.pid, event, "review_feedback_persisted")
    {canonical, _bytes} = read_snapshot!(fixture.canonical)
    assert canonical.review_threads["comment:91"]["draft_state"] == "drafted"
    assert canonical.last_review_decision == "COMMENTED"
    assert canonical.review_claims["comment:91"]["disposition"] == "dismissed"
    assert canonical.last_decision_summary =~ "non-actionable noise"

    assert callbacks(fixture.callback_path) == [
             %{"callback" => "review_feedback", "workspace" => fixture.canonical}
           ]

    {archived, bytes} = read_snapshot!(fixture.archived)
    assert archived.review_threads["comment:91"]["draft_state"] == "posted"
    assert bytes == fixture.archived_bytes
  end

  test "CI inbox reopens the canonical workspace and leaves an archived copy untouched", fixture do
    event = %GitHubEvent{
      provider: "github",
      event_id: "ci-#{fixture.unique}",
      event_name: "check_run",
      action: "completed",
      entity_type: "check_run",
      entity_id: "301",
      pr_url: @pr_url,
      repo_full_name: "local-fixture/archive-filtering",
      updated_at: ~U[2026-03-16 20:00:00Z],
      conclusion: "failure",
      check_name: "make-all",
      head_sha: "abc123",
      details_url: "https://github.com/local-fixture/archive-filtering/actions/runs/123/job/456",
      raw: %{"action" => "completed", "check_run" => %{"id" => 301, "name" => "make-all", "conclusion" => "failure"}}
    }

    drain_and_stop!(fixture.pid, event, "ci_failure_persisted")
    {canonical, _bytes} = read_snapshot!(fixture.canonical)
    assert canonical.stage == "implement"
    assert canonical.last_decision_summary =~ "Returning to implement to fix failing checks"
    assert canonical.last_ci_failure.check_name == "make-all"
    assert canonical.last_ci_failure.conclusion == "failure"
    assert canonical.resume_context.ci_failure_summary == "make-all (failure)"
    assert canonical.resume_context.ci_failure_pr_url == @pr_url
    assert canonical.resume_context.next_objective =~ "Investigate and fix the failing GitHub checks"
    assert {:ok, lease} = LeaseManager.read(fixture.issue.id)
    assert is_binary(canonical.lease_owner)
    assert canonical.lease_owner == lease["owner"]
    assert {:ok, issue} = ManualIssueStore.fetch_issue_by_identifier(fixture.issue.identifier)
    assert issue.state == "In Progress"
    assert callbacks(fixture.callback_path) == []

    {archived, bytes} = read_snapshot!(fixture.archived)
    assert archived.stage == "await_checks"
    assert bytes == fixture.archived_bytes
  end

  defp drain_and_stop!(pid, event, reason) do
    event_id = event.event_id
    assert {:ok, %{accepted: 1, duplicates: 0, event_ids: [^event_id]}} = GitHubEventInbox.enqueue([event])
    accepted_at = DateTime.utc_now()
    assert :ok = Orchestrator.notify_github_events(pid, %{accepted_at: accepted_at, accepted: 1, duplicates: 0, event_ids: [event_id]})

    assert_eventually(fn ->
      snapshot = Orchestrator.snapshot(pid, 5_000)
      assert is_map(snapshot)
      assert snapshot.github_webhooks.last_accepted_at == DateTime.to_iso8601(accepted_at)
      assert snapshot.github_inbox.depth == 0

      assert %{event_id: ^event_id, assignment_state: "processed", assignment_reason: ^reason} =
               snapshot.github_inbox.last_assignment

      assert is_binary(snapshot.github_inbox.last_drained_at)
      assert {:ok, drained_at, _offset} = DateTime.from_iso8601(snapshot.github_inbox.last_drained_at)
      assert DateTime.compare(drained_at, accepted_at) == :gt
      assert snapshot.running == []
      assert snapshot.retrying == []
    end)

    monitor = Process.monitor(pid)
    assert :ok = GenServer.stop(pid, :normal, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  defp read_snapshot!(workspace) do
    RunStateStore.with_workspace_lock(workspace, fn ->
      assert {:ok, state} = RunStateStore.load(workspace)
      {state, File.read!(RunStateStore.state_path(workspace))}
    end)
  end

  defp callbacks(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
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
end
