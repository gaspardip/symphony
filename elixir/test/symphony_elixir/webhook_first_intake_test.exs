defmodule SymphonyElixir.WebhookFirstIntakeTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn

  alias SymphonyElixir.Linear.{Adapter, Client, Issue, Webhook}

  alias SymphonyElixir.{
    GitHubEventInbox,
    LeaseManager,
    ManualIssueStore,
    Orchestrator,
    RunStateStore,
    TrackerEvent,
    TrackerEventInbox
  }

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule CachedLinearClient do
    def graphql(query, variables) do
      send(self(), {:cached_graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule RateLimitedLinearClient do
    def fetch_issue_by_id(_issue_id) do
      {:error, {:linear_rate_limited, %{retry_after_ms: 1_000}}}
    end

    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_by_identifier(_identifier), do: {:ok, nil}
    def graphql(_query, _variables), do: {:ok, %{"data" => %{}}}
  end

  defmodule FakeGitHubReviewClient do
    def review_feedback(workspace, _opts) do
      send(self(), {:github_review_feedback_called, workspace})

      {:ok,
       %{
         pr_url: "https://github.com/gaspardip/events/pull/8",
         review_decision: "CHANGES_REQUESTED",
         reviews: [
           %{
             id: 91,
             body: "Please tighten this conditional.",
             state: "COMMENTED",
             submitted_at: "2026-03-11T12:00:00Z",
             author: "copilot-pull-request-reviewer"
           }
         ],
         comments: [
           %{
             id: 92,
             body: "Consider simplifying this branch.",
             path: "LocalEventsExplorer/ViewModels/EventsViewModel.swift",
             line: 42,
             created_at: "2026-03-11T12:01:00Z",
             author: "copilot-pull-request-reviewer"
           }
         ]
       }}
    end
  end

  defmodule FakeGitHubNoiseClient do
    def review_feedback(workspace, _opts) do
      send(self(), {:github_review_feedback_called, workspace})

      {:ok,
       %{
         pr_url: "https://github.com/gaspardip/events/pull/8",
         review_decision: "COMMENTED",
         reviews: [
           %{
             id: 191,
             body: "nit: tweak this wording.",
             state: "COMMENTED",
             submitted_at: "2026-03-11T13:00:00Z",
             author: "copilot-pull-request-reviewer"
           }
         ],
         comments: [
           %{
             id: 192,
             body: "nit: rename this local for clarity.",
             path: "LocalEventsExplorer/ViewModels/EventsViewModel.swift",
             line: 3,
             created_at: "2026-03-11T13:01:00Z",
             author: "copilot-pull-request-reviewer"
           }
         ]
       }}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    log_file = Application.get_env(:symphony_elixir, :log_file)
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    pr_watcher_client = Application.get_env(:symphony_elixir, :pr_watcher_github_client)

    inbox_root =
      Path.join(System.tmp_dir!(), "symphony-webhook-#{System.unique_integer([:positive])}")

    Application.put_env(:symphony_elixir, :log_file, Path.join(inbox_root, "symphony.log"))
    TrackerEventInbox.reset()
    GitHubEventInbox.reset()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      if is_nil(log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, log_file)
      end

      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end

      if is_nil(pr_watcher_client) do
        Application.delete_env(:symphony_elixir, :pr_watcher_github_client)
      else
        Application.put_env(:symphony_elixir, :pr_watcher_github_client, pr_watcher_client)
      end

      File.rm_rf(inbox_root)
      TrackerEventInbox.reset()
      GitHubEventInbox.reset()

      case :ets.whereis(:symphony_linear_state_ids) do
        :undefined -> :ok
        tid -> :ets.delete(tid)
      end
    end)

    :ok
  end

  test "github webhook controller enqueues verified review events and updates matching workspace state" do
    secret = "github-webhook-secret"
    previous_secret = System.get_env("GITHUB_WEBHOOK_SECRET")
    System.put_env("GITHUB_WEBHOOK_SECRET", secret)
    on_exit(fn -> restore_env("GITHUB_WEBHOOK_SECRET", previous_secret) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-webhook-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    Application.put_env(:symphony_elixir, :pr_watcher_github_client, FakeGitHubReviewClient)

    orchestrator_name = :"github-webhook-orchestrator-#{System.unique_integer([:positive])}"

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        orchestrator: orchestrator_name,
        secret_key_base: String.duplicate("s", 64),
        server: false
      )
    )

    start_supervised!({Orchestrator, name: orchestrator_name})
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    workspace = Path.join(workspace_root, "EVT-GH-1")
    File.mkdir_p!(workspace)

    :ok =
      RunStateStore.save(workspace, %{
        issue_id: "manual:evt-gh-1",
        issue_identifier: "EVT-GH-1",
        issue_source: "manual",
        stage: "human_review",
        pr_url: "https://github.com/gaspardip/events/pull/8",
        review_threads: %{},
        stage_history: [],
        stage_transition_counts: %{}
      })

    raw_body =
      Jason.encode!(%{
        "action" => "submitted",
        "review" => %{
          "id" => 91,
          "body" => "Please tighten this conditional.",
          "submitted_at" => "2026-03-11T12:00:00Z"
        },
        "pull_request" => %{
          "html_url" => "https://github.com/gaspardip/events/pull/8",
          "updated_at" => "2026-03-11T12:00:00Z"
        },
        "repository" => %{"full_name" => "gaspardip/events"}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "pull_request_review")
      |> put_req_header("x-github-delivery", "delivery-1")
      |> put_req_header("x-hub-signature-256", github_signature(secret, raw_body))
      |> post("/api/webhooks/github", raw_body)

    assert json_response(conn, 200) == %{"accepted" => 1, "duplicates" => 0}

    assert_eventually(fn ->
      {:ok, run_state} = RunStateStore.load(workspace)

      assert Map.get(run_state, :last_review_decision) == "CHANGES_REQUESTED"

      assert Map.get(run_state, :last_decision_summary) ==
               "New PR review feedback detected on https://github.com/gaspardip/events/pull/8."

      assert Map.get(run_state, :next_human_action) =~ "Review drafted replies"

      review_threads = Map.get(run_state, :review_threads)
      assert get_in(review_threads, ["review:91", "draft_state"]) == "drafted"
      assert is_binary(get_in(review_threads, ["review:91", "draft_reply"]))
      assert get_in(review_threads, ["comment:92", "draft_state"]) == "drafted"

      assert get_in(review_threads, ["comment:92", "path"]) ==
               "LocalEventsExplorer/ViewModels/EventsViewModel.swift"

      assert get_in(review_threads, ["comment:92", "line"]) == 42
      assert get_in(review_threads, ["comment:92", "body"]) =~ "Consider simplifying this branch."
    end)
  end

  test "github webhook controller returns fully autonomous PRs to implement with review context" do
    secret = "github-webhook-secret"
    previous_secret = System.get_env("GITHUB_WEBHOOK_SECRET")
    System.put_env("GITHUB_WEBHOOK_SECRET", secret)
    on_exit(fn -> restore_env("GITHUB_WEBHOOK_SECRET", previous_secret) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-webhook-autonomous-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      manual_store_root: manual_store_root,
      max_concurrent_agents: 0,
      runner_instance_name: "stable-runner",
      runner_channel: "stable"
    )

    Application.put_env(:symphony_elixir, :pr_watcher_github_client, FakeGitHubReviewClient)

    orchestrator_name =
      :"github-webhook-autonomous-orchestrator-#{System.unique_integer([:positive])}"

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        orchestrator: orchestrator_name,
        secret_key_base: String.duplicate("s", 64),
        server: false
      )
    )

    start_supervised!({Orchestrator, name: orchestrator_name})
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    unique = System.unique_integer([:positive])

    {:ok, issue} =
      ManualIssueStore.submit(%{
        "id" => "github-webhook-autonomous-#{unique}",
        "identifier" => "EVT-GH-AUTO-#{unique}",
        "title" => "Autonomous webhook review follow-up",
        "description" => "Resume automatically when PR review feedback arrives",
        "acceptance_criteria" => [
          "Return the runtime to implement when GitHub review feedback lands"
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
        stage_history: [%{stage: "publish"}, %{stage: "await_checks"}],
        stage_transition_counts: %{"publish" => 1, "await_checks" => 1}
      })

    raw_body =
      Jason.encode!(%{
        "action" => "submitted",
        "review" => %{
          "id" => 91,
          "body" => "Please tighten this conditional.",
          "submitted_at" => "2026-03-11T12:00:00Z"
        },
        "pull_request" => %{
          "html_url" => "https://github.com/gaspardip/events/pull/8",
          "updated_at" => "2026-03-11T12:00:00Z"
        },
        "repository" => %{"full_name" => "gaspardip/events"}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "pull_request_review")
      |> put_req_header("x-github-delivery", "delivery-autonomous")
      |> put_req_header("x-hub-signature-256", github_signature(secret, raw_body))
      |> post("/api/webhooks/github", raw_body)

    assert json_response(conn, 200) == %{"accepted" => 1, "duplicates" => 0}

    assert_eventually(
      fn ->
        {:ok, run_state} = RunStateStore.load(workspace)
        assert {:ok, lease} = LeaseManager.read(issue.id)

        {:ok, %Issue{} = refreshed_issue} =
          ManualIssueStore.fetch_issue_by_identifier(issue.identifier)

        assert Map.get(run_state, :stage) == "review_verification"
        assert Map.get(run_state, :last_review_decision) == "CHANGES_REQUESTED"
        assert Map.get(run_state, :last_decision_summary) =~ "Returning to review_verification"
        assert Map.get(run_state, :next_human_action) == nil
        assert Map.get(run_state, :review_return_stage) == "await_checks"

        assert get_in(run_state, [:review_claims, "review:91", "verification_status"]) == "pending"
        assert get_in(run_state, [:review_claims, "review:91", "disposition"]) == "needs_verification"

        assert get_in(run_state, [:resume_context, :next_objective]) =~
                 "Verify the pending GitHub review feedback"

        assert get_in(run_state, [:resume_context, :review_feedback_summary]) =~
                 "LocalEventsExplorer/ViewModels/EventsViewModel.swift:42"

        assert get_in(run_state, [:resume_context, :review_claim_summary]) =~
                 "correctness_risk"

        assert get_in(run_state, [:review_threads, "review:91", "body"]) =~
                 "Please tighten this conditional."

        assert get_in(run_state, [:review_threads, "comment:92", "draft_state"]) == "drafted"
        assert is_binary(Map.get(run_state, :lease_owner))
        assert Map.get(run_state, :lease_owner) == lease["owner"]
        assert Map.get(run_state, :lease_owner_channel) == "stable"
        assert Map.get(run_state, :lease_owner_instance_id) == "stable:stable-runner"
        assert Map.get(run_state, :lease_epoch) == lease["epoch"]
        assert Map.get(run_state, :lease_acquired_at) == lease["acquired_at"]
        assert Map.get(run_state, :lease_updated_at) == lease["updated_at"]
        assert Map.get(run_state, :lease_status) == "held"
        assert refreshed_issue.state == "In Progress"
      end,
      60
    )
  end

  test "github webhook controller leaves fully autonomous runs in place when review noise is non-actionable" do
    secret = "github-webhook-secret"
    previous_secret = System.get_env("GITHUB_WEBHOOK_SECRET")
    System.put_env("GITHUB_WEBHOOK_SECRET", secret)
    on_exit(fn -> restore_env("GITHUB_WEBHOOK_SECRET", previous_secret) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-webhook-noise-#{System.unique_integer([:positive])}"
      )

    manual_store_root = Path.join(workspace_root, "manual-store")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      manual_store_root: manual_store_root,
      max_concurrent_agents: 0
    )

    Application.put_env(:symphony_elixir, :pr_watcher_github_client, FakeGitHubNoiseClient)

    orchestrator_name =
      :"github-webhook-noise-orchestrator-#{System.unique_integer([:positive])}"

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        orchestrator: orchestrator_name,
        secret_key_base: String.duplicate("s", 64),
        server: false
      )
    )

    start_supervised!({Orchestrator, name: orchestrator_name})
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    {:ok, issue} =
      ManualIssueStore.submit(%{
        "id" => "github-webhook-noise",
        "identifier" => "EVT-GH-NOISE",
        "title" => "Ignore noisy webhook review feedback",
        "description" => "Keep autonomous runs stable when review noise is non-actionable",
        "acceptance_criteria" => [
          "Do not reopen implement on Copilot nit noise"
        ],
        "policy_class" => "fully_autonomous"
      })

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(Path.join(workspace, "LocalEventsExplorer/ViewModels"))

    File.write!(
      Path.join(workspace, "LocalEventsExplorer/ViewModels/EventsViewModel.swift"),
      "one\ntwo\nthree\nfour\n"
    )

    :ok =
      RunStateStore.save(workspace, %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_source: issue.source,
        stage: "await_checks",
        effective_policy_class: "fully_autonomous",
        pr_url: "https://github.com/gaspardip/events/pull/8",
        review_threads: %{},
        stage_history: [%{stage: "publish"}, %{stage: "await_checks"}],
        stage_transition_counts: %{"publish" => 1, "await_checks" => 1}
      })

    raw_body =
      Jason.encode!(%{
        "action" => "submitted",
        "review" => %{
          "id" => 191,
          "body" => "nit: tweak this wording.",
          "submitted_at" => "2026-03-11T13:00:00Z"
        },
        "pull_request" => %{
          "html_url" => "https://github.com/gaspardip/events/pull/8",
          "updated_at" => "2026-03-11T13:00:00Z"
        },
        "repository" => %{"full_name" => "gaspardip/events"}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "pull_request_review")
      |> put_req_header("x-github-delivery", "delivery-noise")
      |> put_req_header("x-hub-signature-256", github_signature(secret, raw_body))
      |> post("/api/webhooks/github", raw_body)

    assert json_response(conn, 200) == %{"accepted" => 1, "duplicates" => 0}

    assert_eventually(
      fn ->
        {:ok, run_state} = RunStateStore.load(workspace)
        summary = Map.get(run_state, :last_decision_summary)

        assert Map.get(run_state, :stage) == "await_checks"
        assert is_binary(summary)
        assert summary =~ "triaged it as non-actionable noise"

        assert Map.get(run_state, :next_human_action) == nil
        assert get_in(run_state, [:review_threads, "review:191", "disposition"]) == "dismissed"
        assert get_in(run_state, [:review_threads, "comment:192", "disposition"]) == "dismissed"
        assert get_in(run_state, [:review_threads, "comment:192", "actionable"]) == false
      end,
      60
    )
  end

  test "github webhook controller does not refresh workspaces owned by another runner channel" do
    secret = "github-webhook-secret"
    previous_secret = System.get_env("GITHUB_WEBHOOK_SECRET")
    System.put_env("GITHUB_WEBHOOK_SECRET", secret)
    on_exit(fn -> restore_env("GITHUB_WEBHOOK_SECRET", previous_secret) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-webhook-routed-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      runner_instance_name: "stable-runner",
      runner_channel: "stable"
    )

    Application.put_env(:symphony_elixir, :pr_watcher_github_client, FakeGitHubReviewClient)

    orchestrator_name =
      :"github-webhook-routed-orchestrator-#{System.unique_integer([:positive])}"

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        orchestrator: orchestrator_name,
        secret_key_base: String.duplicate("s", 64),
        server: false
      )
    )

    start_supervised!({Orchestrator, name: orchestrator_name})
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    workspace = Path.join(workspace_root, "EVT-GH-CANARY")
    File.mkdir_p!(workspace)

    :ok =
      RunStateStore.save(workspace, %{
        issue_id: "manual:evt-gh-canary",
        issue_identifier: "EVT-GH-CANARY",
        issue_source: "manual",
        stage: "await_checks",
        pr_url: "https://github.com/gaspardip/events/pull/8",
        runner_channel: "canary",
        runner_instance_id: "canary:dogfood-runner",
        review_threads: %{},
        stage_history: [%{stage: "publish"}, %{stage: "await_checks"}],
        stage_transition_counts: %{"publish" => 1, "await_checks" => 1}
      })

    raw_body =
      Jason.encode!(%{
        "action" => "submitted",
        "review" => %{
          "id" => 91,
          "body" => "Please tighten this conditional.",
          "submitted_at" => "2026-03-11T12:00:00Z"
        },
        "pull_request" => %{
          "html_url" => "https://github.com/gaspardip/events/pull/8",
          "updated_at" => "2026-03-11T12:00:00Z"
        },
        "repository" => %{"full_name" => "gaspardip/events"}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "pull_request_review")
      |> put_req_header("x-github-delivery", "delivery-routed")
      |> put_req_header("x-hub-signature-256", github_signature(secret, raw_body))
      |> post("/api/webhooks/github", raw_body)

    assert json_response(conn, 200) == %{"accepted" => 1, "duplicates" => 0}

    assert_eventually(fn ->
      {:ok, run_state} = RunStateStore.load(workspace)
      assert Map.get(run_state, :stage) == "await_checks"
      assert Map.get(run_state, :last_review_decision) == nil
      assert Map.get(run_state, :review_threads) == %{}
      assert Map.get(run_state, :runner_channel) == "canary"
      assert Map.get(run_state, :runner_instance_id) == "canary:dogfood-runner"
    end)

    refute_received {:github_review_feedback_called, ^workspace}
  end

  test "github webhook controller does not refresh workspaces leased by another owner on the same runner" do
    secret = "github-webhook-secret"
    previous_secret = System.get_env("GITHUB_WEBHOOK_SECRET")
    System.put_env("GITHUB_WEBHOOK_SECRET", secret)
    on_exit(fn -> restore_env("GITHUB_WEBHOOK_SECRET", previous_secret) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-webhook-leased-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      runner_instance_name: "stable-runner",
      runner_channel: "stable"
    )

    Application.put_env(:symphony_elixir, :pr_watcher_github_client, FakeGitHubReviewClient)

    orchestrator_name =
      :"github-webhook-leased-orchestrator-#{System.unique_integer([:positive])}"

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        orchestrator: orchestrator_name,
        secret_key_base: String.duplicate("s", 64),
        server: false
      )
    )

    start_supervised!({Orchestrator, name: orchestrator_name})
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    workspace = Path.join(workspace_root, "EVT-GH-LEASED")
    File.mkdir_p!(workspace)

    :ok = LeaseManager.acquire("manual:evt-gh-leased", "EVT-GH-LEASED", "other-orchestrator-owner")

    on_exit(fn ->
      LeaseManager.release("manual:evt-gh-leased")
    end)

    :ok =
      RunStateStore.save(workspace, %{
        issue_id: "manual:evt-gh-leased",
        issue_identifier: "EVT-GH-LEASED",
        issue_source: "manual",
        stage: "await_checks",
        pr_url: "https://github.com/gaspardip/events/pull/8",
        runner_channel: "stable",
        runner_instance_id: "stable:stable-runner",
        review_threads: %{},
        stage_history: [%{stage: "publish"}, %{stage: "await_checks"}],
        stage_transition_counts: %{"publish" => 1, "await_checks" => 1}
      })

    raw_body =
      Jason.encode!(%{
        "action" => "submitted",
        "review" => %{
          "id" => 91,
          "body" => "Please tighten this conditional.",
          "submitted_at" => "2026-03-11T12:00:00Z"
        },
        "pull_request" => %{
          "html_url" => "https://github.com/gaspardip/events/pull/8",
          "updated_at" => "2026-03-11T12:00:00Z"
        },
        "repository" => %{"full_name" => "gaspardip/events"}
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "pull_request_review")
      |> put_req_header("x-github-delivery", "delivery-leased")
      |> put_req_header("x-hub-signature-256", github_signature(secret, raw_body))
      |> post("/api/webhooks/github", raw_body)

    assert json_response(conn, 200) == %{"accepted" => 1, "duplicates" => 0}

    assert_eventually(fn ->
      {:ok, run_state} = RunStateStore.load(workspace)
      assert Map.get(run_state, :stage) == "await_checks"
      assert Map.get(run_state, :last_review_decision) == nil
      assert Map.get(run_state, :review_threads) == %{}
      assert Map.get(run_state, :runner_channel) == "stable"
      assert Map.get(run_state, :runner_instance_id) == "stable:stable-runner"
    end)

    refute_received {:github_review_feedback_called, ^workspace}
  end

  test "linear webhook controller enqueues verified issue events and notifies the orchestrator" do
    secret = "linear-webhook-secret"
    write_workflow_file!(Workflow.workflow_file_path(), tracker_webhook_secret: secret)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        orchestrator: self(),
        secret_key_base: String.duplicate("s", 64),
        server: false
      )
    )

    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    raw_body =
      webhook_payload(%{
        "updatedFrom" => %{"stateId" => "todo"},
        "data" => %{
          "id" => "issue-1",
          "identifier" => "MT-1",
          "state" => %{"name" => "Todo"},
          "labels" => [%{"name" => "policy:review-required"}],
          "project" => %{"slugId" => "project-1"},
          "assignee" => %{"id" => "worker-1"},
          "updatedAt" => "2026-03-08T05:10:00Z"
        }
      })
      |> Jason.encode!()

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", webhook_signature(secret, raw_body))
      |> post("/api/webhooks/linear", raw_body)

    assert json_response(conn, 200) == %{"accepted" => 1, "duplicates" => 0}

    assert_receive {:tracker_events_available, %{accepted: 1, duplicates: 0, event_ids: [_event_id]}}

    assert [%{"event" => event_payload}] = TrackerEventInbox.pending_events(10)
    assert event_payload["issue_identifier"] == "MT-1"
    assert event_payload["label_names"] == ["policy:review-required"]
  end

  test "linear webhook controller rejects invalid signatures and records the rejection" do
    secret = "linear-webhook-secret"
    write_workflow_file!(Workflow.workflow_file_path(), tracker_webhook_secret: secret)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        orchestrator: self(),
        secret_key_base: String.duplicate("s", 64),
        server: false
      )
    )

    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    raw_body = webhook_payload() |> Jason.encode!()

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", "bad-signature")
      |> post("/api/webhooks/linear", raw_body)

    assert json_response(conn, 401)["error"]["code"] == "invalid_signature"

    assert_receive {:tracker_webhook_rejected,
                    %{
                      rule_id: "webhook.signature_invalid",
                      reason: "Linear webhook signature verification failed."
                    }}
  end

  test "linear webhook controller records ignored non schedule-affecting issue events" do
    secret = "linear-webhook-secret"
    write_workflow_file!(Workflow.workflow_file_path(), tracker_webhook_secret: secret)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(
        orchestrator: self(),
        secret_key_base: String.duplicate("s", 64),
        server: false
      )
    )

    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    raw_body =
      webhook_payload(%{
        "updatedFrom" => %{"priority" => 1},
        "data" => %{"id" => "issue-ignored", "identifier" => "MT-IGNORED"}
      })
      |> Jason.encode!()

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", webhook_signature(secret, raw_body))
      |> post("/api/webhooks/linear", raw_body)

    assert json_response(conn, 200) == %{
             "accepted" => 0,
             "ignored" => true,
             "reason" => "non_schedule_affecting_event"
           }

    assert_receive {:tracker_webhook_ignored, %{rule_id: "webhook.event_ignored", reason: "non_schedule_affecting_event"}}
  end

  test "linear webhook decoder parses millisecond timestamps and ignores non schedule-affecting updates" do
    secret = "linear-webhook-secret"
    write_workflow_file!(Workflow.workflow_file_path(), tracker_webhook_secret: secret)

    ignored_payload =
      webhook_payload(%{
        "updatedFrom" => %{"priority" => 1},
        "data" => %{"id" => "issue-2", "identifier" => "MT-2", "updatedAt" => 1_778_055_000_000}
      })

    ignored_body = Jason.encode!(ignored_payload)

    assert {:ignore, :non_schedule_affecting_event} =
             Webhook.decode(
               [{"linear-signature", webhook_signature(secret, ignored_body)}],
               ignored_body
             )

    accepted_payload =
      webhook_payload(%{
        "updatedFrom" => %{"assigneeId" => "worker-1"},
        "data" => %{"id" => "issue-3", "identifier" => "MT-3", "updatedAt" => 1_778_055_000_000}
      })

    accepted_body = Jason.encode!(accepted_payload)

    assert {:ok, [%TrackerEvent{} = event]} =
             Webhook.decode(
               [{"linear-signature", webhook_signature(secret, accepted_body)}],
               accepted_body
             )

    assert event.issue_identifier == "MT-3"
    assert event.updated_at == DateTime.from_unix!(1_778_055_000_000, :millisecond)
  end

  test "tracker event inbox dedupes, acknowledges, and replays persisted events" do
    event = %TrackerEvent{
      provider: "linear",
      event_id: "evt-1",
      entity_type: "Issue",
      entity_id: "issue-1",
      issue_identifier: "MT-1",
      project_slug: "project-1",
      action: "update",
      state_name: "Todo",
      label_names: ["policy:fully-autonomous"],
      assignee_id: "worker-1",
      updated_at: ~U[2026-03-08 05:15:00Z],
      raw: %{"type" => "Issue"}
    }

    assert {:ok, %{accepted: 1, duplicates: 0}} = TrackerEventInbox.enqueue([event])
    assert {:ok, %{accepted: 0, duplicates: 1}} = TrackerEventInbox.enqueue([event])

    assert [%{"event" => payload}] = TrackerEventInbox.pending_events(10)
    assert payload["issue_identifier"] == "MT-1"

    assert :ok = TrackerEventInbox.ack(1)
    assert [] == TrackerEventInbox.pending_events(10)
  end

  test "orchestrator records ignored webhook notices in runtime state" do
    orchestrator_name = Module.concat(__MODULE__, :IgnoredWebhookOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    ignored_at = ~U[2026-03-08 07:00:00Z]

    state = :sys.get_state(pid)

    assert {:noreply, next_state} =
             Orchestrator.handle_info(
               {:tracker_webhook_ignored,
                %{
                  rule_id: "webhook.event_ignored",
                  reason: "non_schedule_affecting_event",
                  ignored_at: ignored_at
                }},
               state
             )

    assert next_state.webhook_last_ignored_rule_id == "webhook.event_ignored"
    assert next_state.webhook_last_ignored_reason == "non_schedule_affecting_event"
    assert next_state.webhook_last_ignored_at == ignored_at
  end

  test "webhook cycle replays stale events as drops and leaves rate-limited events pending" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_required_labels: [],
      tracker_handoff_mode: "labels"
    )

    stale_event = %TrackerEvent{
      provider: "linear",
      event_id: "evt-stale",
      entity_type: "Issue",
      entity_id: "issue-stale",
      issue_identifier: "MT-STALE",
      project_slug: "project",
      action: "update",
      state_name: "Todo",
      label_names: [],
      assignee_id: nil,
      updated_at: ~U[2026-03-08 07:05:00Z],
      raw: %{"type" => "Issue"}
    }

    rate_limited_event = %TrackerEvent{
      stale_event
      | event_id: "evt-rate-limited",
        entity_id: "issue-rate-limited",
        issue_identifier: "MT-RATE"
    }

    assert {:ok, %{accepted: 2}} = TrackerEventInbox.enqueue([stale_event, rate_limited_event])

    Application.put_env(:symphony_elixir, :linear_client_module, RateLimitedLinearClient)

    orchestrator_name = Module.concat(__MODULE__, :ReplayWebhookOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    state =
      :sys.get_state(pid)
      |> Map.put(:poll_check_in_progress, true)
      |> Map.put(:current_poll_mode, :webhook)
      |> Map.put(:issue_routing_cache, %{
        "issue-stale" => %{
          state: "Todo",
          assignee_id: nil,
          labels: [],
          updated_at: ~U[2026-03-08 07:10:00Z]
        }
      })

    assert {:noreply, next_state} = Orchestrator.handle_info(:run_webhook_cycle, state)
    assert next_state.tracker_backoff_rule_id == "tracker.rate_limited"

    assert [%{"event" => payload}] = TrackerEventInbox.pending_events(10)
    assert payload["issue_identifier"] == "MT-RATE"
  end

  test "linear client handoff mode controls assignee routing" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", "worker-1")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_handoff_mode: "labels"
    )

    assert {:ok, nil} = Client.helper_for_test(:routing_assignee_filter, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_handoff_mode: "assignee"
    )

    assert {:ok, %{match_values: assignee_match_values}} =
             Client.helper_for_test(:routing_assignee_filter, [])

    assert MapSet.member?(assignee_match_values, "worker-1")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_handoff_mode: "hybrid"
    )

    assert {:ok, %{match_values: hybrid_match_values}} =
             Client.helper_for_test(:routing_assignee_filter, [])

    assert hybrid_match_values == assignee_match_values
  end

  test "linear adapter caches state identifiers by team and state name" do
    Application.put_env(:symphony_elixir, :linear_client_module, CachedLinearClient)

    Process.put(
      {CachedLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{"id" => "team-1", "states" => %{"nodes" => [%{"id" => "state-1"}]}}
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{"id" => "team-1", "states" => %{"nodes" => [%{"id" => "state-1"}]}}
             }
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")

    assert_receive {:cached_graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "__unused__"}}

    assert state_lookup_query =~ "team"

    assert_receive {:cached_graphql_called, _state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}

    assert_receive {:cached_graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    assert :ok = Adapter.update_issue_state("issue-1", "Done")

    assert_receive {:cached_graphql_called, second_update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert second_update_issue_query =~ "issueUpdate"
    refute_received {:cached_graphql_called, _, %{issueId: "issue-1", stateName: "__unused__"}}
  end

  defp webhook_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "Issue",
        "action" => "update",
        "updatedFrom" => %{"stateId" => "todo"},
        "data" => %{
          "id" => "issue-1",
          "identifier" => "MT-1",
          "title" => "Webhook ticket",
          "description" => "Body",
          "state" => %{"name" => "Todo"},
          "project" => %{"slugId" => "project-1"},
          "labels" => [%{"name" => "policy:review-required"}],
          "assignee" => %{"id" => "worker-1"},
          "updatedAt" => "2026-03-08T05:10:00Z"
        }
      },
      overrides
    )
  end

  defp webhook_signature(secret, raw_body) do
    :crypto.mac(:hmac, :sha256, secret, raw_body)
    |> Base.encode16(case: :lower)
  end

  defp github_signature(secret, raw_body) do
    digest =
      :crypto.mac(:hmac, :sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    "sha256=" <> digest
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
