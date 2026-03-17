defmodule SymphonyElixir.PRWatcherTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PRWatcher

  test "private autopilot resolves to an active watcher posture" do
    status = PRWatcher.status(:private_autopilot)

    assert status.enabled == true
    assert status.mode == "draft_first"
    assert status.posting_allowed == true
    assert status.draft_first_required == true
    assert status.thread_resolution_allowed == true
    assert "pull_request" in status.allowed_channels
  end

  test "client safe shadow resolves to draft-only watcher posture" do
    status = PRWatcher.status(:client_safe_shadow)

    assert status.enabled == true
    assert status.mode == "draft_only"
    assert status.posting_allowed == false
    assert status.draft_first_required == true
    assert status.thread_resolution_allowed == false
    assert status.external_comment_mode == "draft_only"
  end

  test "client safe pr-active resolves to draft-first watcher posture" do
    status = PRWatcher.status(:client_safe_pr_active)

    assert status.enabled == true
    assert status.mode == "draft_first"
    assert status.posting_allowed == true
    assert status.draft_first_required == true
    assert status.thread_resolution_allowed == false
  end

  test "review_feedback drafts replies from reviews and comments" do
    feedback =
      PRWatcher.review_feedback(
        "/tmp/symphony-pr-feedback",
        policy_pack: :client_safe_shadow,
        github_client: __MODULE__.FakeGitHubClient
      )

    assert feedback.status == "ok"
    assert feedback.pending_drafts_count == 2
    assert feedback.actionable_items_count == 1

    assert Enum.any?(
             feedback.items,
             &(&1.kind == :review and &1.resolution_recommendation == "keep_open_until_change")
           )

    assert Enum.any?(feedback.items, fn item ->
             item.kind == :review and item.disposition == "needs_verification" and
               item.actionable == true
           end)

    assert Enum.any?(feedback.items, fn item ->
             item.kind == :comment and item.draft_state == "drafted" and
               item.disposition == "dismissed"
           end)
  end

  test "review_feedback reuses persisted thread state when present" do
    feedback =
      PRWatcher.review_feedback(
        "/tmp/symphony-pr-feedback",
        policy_pack: :client_safe_shadow,
        github_client: __MODULE__.FakeGitHubClient,
        thread_states: %{
          "review:1" => %{
            "draft_state" => "approved_to_post",
            "draft_reply" => "Use the approved reply.",
            "resolution_recommendation" => "resolve_after_change"
          }
        }
      )

    review_item = Enum.find(feedback.items, &(&1.thread_key == "review:1"))

    assert review_item.draft_state == "approved_to_post"
    assert review_item.draft_reply == "Use the approved reply."
    assert review_item.resolution_recommendation == "resolve_after_change"
  end

  test "review_feedback reconciles posted inline replies from live GitHub thread data" do
    feedback =
      PRWatcher.review_feedback(
        "/tmp/symphony-pr-feedback",
        policy_pack: :private_autopilot,
        github_client: __MODULE__.FakeGitHubClient,
        thread_states: %{
          "comment:2" => %{
            "draft_state" => "posted",
            "draft_reply" => "Old local reply.",
            "posted_reply_id" => "3",
            "posted_reply_url" => "https://github.com/example/repo/pull/42#discussion_r3"
          }
        }
      )

    comment_item = Enum.find(feedback.items, &(&1.thread_key == "comment:2"))

    assert comment_item.draft_state == "posted"
    assert comment_item.posted_reply_id == "3"

    assert comment_item.posted_reply_url ==
             "https://github.com/example/repo/pull/42#discussion_r3"

    assert comment_item.draft_reply == "I fixed this locally."
    assert comment_item.reply_refresh_needed == false
  end

  test "review_feedback falls back to pr_url when workspace lookup is unavailable" do
    feedback =
      PRWatcher.review_feedback(
        "/tmp/non-checkout",
        policy_pack: :client_safe_shadow,
        pr_url: "https://github.com/example/repo/pull/42",
        github_client: __MODULE__.FallbackGitHubClient
      )

    assert feedback.status == "ok"
    assert feedback.pr_url == "https://github.com/example/repo/pull/42"
    assert feedback.pending_drafts_count == 2
  end

  test "review_feedback returns cached drafts when provider feedback is unavailable" do
    feedback =
      PRWatcher.review_feedback(
        "/tmp/non-checkout",
        policy_pack: :client_safe_shadow,
        pr_url: "https://github.com/example/repo/pull/42",
        github_client: __MODULE__.UnavailableGitHubClient,
        thread_states: %{
          "review:1" => %{
            "draft_state" => "drafted",
            "draft_reply" => "Planned reply",
            "resolution_recommendation" => "keep_open_until_confirmed"
          }
        }
      )

    assert feedback.status == "cached"
    assert feedback.pr_url == "https://github.com/example/repo/pull/42"
    assert feedback.pending_drafts_count == 1
    assert Enum.at(feedback.items, 0).draft_reply == "Planned reply"
  end

  test "review_feedback derives cached pr_url from persisted posted reply urls when direct pr_url is missing" do
    feedback =
      PRWatcher.review_feedback(
        "/tmp/non-checkout",
        policy_pack: :private_autopilot,
        github_client: __MODULE__.UnavailableGitHubClient,
        thread_states: %{
          "comment:2" => %{
            "draft_state" => "posted",
            "draft_reply" => "Already posted",
            "posted_reply_url" => "https://github.com/example/repo/pull/42#discussion_r123"
          }
        }
      )

    assert feedback.status == "cached"
    assert feedback.pr_url == "https://github.com/example/repo/pull/42"
    assert feedback.pending_drafts_count == 1
  end

  test "post_approved_drafts posts approved inline replies when policy allows" do
    {:ok, updated_threads, stats} =
      PRWatcher.post_approved_drafts(
        "/tmp/symphony-pr-feedback",
        "https://github.com/example/repo/pull/42",
        %{
          "comment:2" => %{
            "draft_state" => "approved_to_post",
            "draft_reply" => "Posting this now."
          },
          "review:1" => %{
            "draft_state" => "approved_to_post",
            "draft_reply" => "Review summary reply."
          }
        },
        policy_pack: :private_autopilot,
        github_client: __MODULE__.PostingGitHubClient
      )

    assert stats.posted_count == 1
    assert stats.skipped_count == 1
    assert get_in(updated_threads, ["comment:2", "draft_state"]) == "posted"
    assert is_binary(get_in(updated_threads, ["comment:2", "posted_reply_id"]))
    assert is_binary(get_in(updated_threads, ["comment:2", "posted_reply_url"]))
    assert get_in(updated_threads, ["review:1", "draft_state"]) == "approved_to_post"
  end

  test "post_approved_drafts updates approved stale inline replies when policy allows" do
    {:ok, updated_threads, stats} =
      PRWatcher.post_approved_drafts(
        "/tmp/symphony-pr-feedback",
        "https://github.com/example/repo/pull/42",
        %{
          "comment:2" => %{
            "draft_state" => "approved_to_update",
            "draft_reply" => "Updated reply text.",
            "posted_reply_id" => "reply-2"
          }
        },
        policy_pack: :private_autopilot,
        github_client: __MODULE__.PostingGitHubClient
      )

    assert stats.posted_count == 1
    assert stats.skipped_count == 0
    assert get_in(updated_threads, ["comment:2", "draft_state"]) == "posted"
    assert get_in(updated_threads, ["comment:2", "posted_reply_id"]) == "reply-2"
    assert get_in(updated_threads, ["comment:2", "reply_refresh_needed"]) == false
  end

  test "post_approved_drafts is forbidden in client safe shadow mode" do
    assert {:error, {:external_comment_posting_forbidden, "client_safe_shadow"}} =
             PRWatcher.post_approved_drafts(
               "/tmp/symphony-pr-feedback",
               "https://github.com/example/repo/pull/42",
               %{
                 "comment:2" => %{
                   "draft_state" => "approved_to_post",
                   "draft_reply" => "Posting this now."
                 }
               },
               policy_pack: :client_safe_shadow,
               github_client: __MODULE__.PostingGitHubClient
             )
  end

  test "resolve_posted_threads resolves addressed inline threads when policy allows" do
    {:ok, updated_threads, stats} =
      PRWatcher.resolve_posted_threads(
        "https://github.com/example/repo/pull/42",
        %{
          "comment:2" => %{
            "draft_state" => "posted",
            "draft_reply" => "Included on the branch.",
            "implementation_status" => "addressed",
            "resolution_recommendation" => "resolve_after_change"
          },
          "comment:3" => %{
            "draft_state" => "posted",
            "draft_reply" => "Need more proof.",
            "implementation_status" => nil,
            "resolution_recommendation" => "keep_open_until_confirmed"
          }
        },
        policy_pack: :private_autopilot,
        github_client: __MODULE__.PostingGitHubClient
      )

    assert stats.resolved_count == 1
    assert stats.skipped_count == 0
    assert get_in(updated_threads, ["comment:2", "resolution_state"]) == "resolved"
    assert is_binary(get_in(updated_threads, ["comment:2", "resolved_at"]))
    assert get_in(updated_threads, ["comment:3", "resolution_state"]) == nil
  end

  test "resolve_posted_threads resolves contradicted false-positive threads when policy allows" do
    {:ok, updated_threads, stats} =
      PRWatcher.resolve_posted_threads(
        "https://github.com/example/repo/pull/42",
        %{
          "comment:2" => %{
            "draft_state" => "posted",
            "draft_reply" => "This claim was contradicted locally.",
            "disposition" => "dismissed",
            "verification_status" => "contradicted",
            "resolution_recommendation" => "resolve_after_contradiction"
          }
        },
        policy_pack: :private_autopilot,
        github_client: __MODULE__.PostingGitHubClient
      )

    assert stats.resolved_count == 1
    assert get_in(updated_threads, ["comment:2", "resolution_state"]) == "resolved"
    assert is_binary(get_in(updated_threads, ["comment:2", "resolved_at"]))
  end

  defmodule FakeGitHubClient do
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
         pr_url: "https://github.com/example/repo/pull/42",
         review_decision: "CHANGES_REQUESTED",
         reviews: [
           %{
             id: 1,
             body: "Please fix this edge case before merge.",
             state: "CHANGES_REQUESTED",
             author: "reviewer"
           }
         ],
         comments: [
           %{
             id: 2,
             body: "nit: tighten this copy",
             path: "lib/example.ex",
             line: 12,
             author: "reviewer",
             replies: [
               %{
                 id: "3",
                 body: "I fixed this locally.",
                 url: "https://github.com/example/repo/pull/42#discussion_r3",
                 author: "gaspardip",
                 created_at: "2026-03-11T10:02:00Z",
                 updated_at: "2026-03-11T10:03:00Z"
               }
             ]
           }
         ]
       }}
    end

    @impl true
    def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok

    @impl true
    def post_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}

    @impl true
    def edit_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}
  end

  defmodule FallbackGitHubClient do
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
    def review_feedback_by_pr_url(_pr_url, _opts) do
      {:ok,
       %{
         pr_url: "https://github.com/example/repo/pull/42",
         review_decision: "CHANGES_REQUESTED",
         reviews: [
           %{
             id: 1,
             body: "Please fix this edge case before merge.",
             state: "CHANGES_REQUESTED",
             author: "reviewer"
           }
         ],
         comments: [
           %{
             id: 2,
             body: "nit: tighten this copy",
             path: "lib/example.ex",
             line: 12,
             author: "reviewer",
             replies: []
           }
         ]
       }}
    end

    @impl true
    def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok

    @impl true
    def post_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}

    @impl true
    def edit_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}
  end

  defmodule UnavailableGitHubClient do
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
    def post_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}

    @impl true
    def edit_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}
  end

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
      {:ok,
       %{
         id: "reply-#{comment_id}",
         url: "https://github.com/example/reply/#{comment_id}",
         output: ""
       }}
    end

    @impl true
    def edit_review_comment_reply(_pr_url, comment_id, _body, _opts) do
      {:ok,
       %{
         id: to_string(comment_id),
         url: "https://github.com/example/reply/#{comment_id}",
         output: ""
       }}
    end

    @impl true
    def resolve_review_comment_thread(_pr_url, comment_id, _opts) do
      {:ok, %{thread_id: "thread-#{comment_id}", resolved: true, output: ""}}
    end
  end
end
