defmodule SymphonyElixir.GitHubCLIClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubCLIClient

  test "existing pull request handles success malformed payloads and missing PRs" do
    assert {:ok, %{url: "https://github.com/example/repo/pull/1", state: "OPEN"}} =
             GitHubCLIClient.existing_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/1",
                      "state" => "OPEN"
                    }), 0}
               end
             )

    assert {:error, :missing_pr} =
             GitHubCLIClient.existing_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {"{}", 0}
               end
             )

    assert {:error, :missing_pr} =
             GitHubCLIClient.existing_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {"not json", 0}
               end
             )

    assert {:error, :missing_pr} =
             GitHubCLIClient.existing_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {"no pull request", 1}
               end
             )
  end

  test "edit and create pull request propagate gh failures and fallback paths" do
    assert {:ok,
            %{url: "https://github.com/example/repo/pull/2", state: "OPEN", output: "updated"}} =
             GitHubCLIClient.edit_pull_request("/tmp/workspace", "Title", "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/2",
                      "state" => "OPEN"
                    }), 0}

                 "gh", ["pr", "edit", "--title", "Title", "--body-file", "/tmp/body.md"], _opts ->
                   {"updated", 0}
               end
             )

    assert {:error, {:pr_edit_failed, 1, "boom"}} =
             GitHubCLIClient.edit_pull_request("/tmp/workspace", "Title", "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/2",
                      "state" => "OPEN"
                    }), 0}

                 "gh", ["pr", "edit", "--title", "Title", "--body-file", "/tmp/body.md"], _opts ->
                   {"boom", 1}
               end
             )

    assert {:ok, %{url: "https://github.com/example/repo/pull/3", state: "OPEN"}} =
             GitHubCLIClient.create_pull_request(
               "/tmp/workspace",
               "gaspar/test",
               "main",
               "Title",
               "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "create" | _args], _opts ->
                   {"https://github.com/example/repo/pull/3\n", 0}
               end
             )

    assert {:ok, %{url: "https://github.com/example/repo/pull/4", state: "OPEN"}} =
             GitHubCLIClient.create_pull_request(
               "/tmp/workspace",
               "gaspar/test",
               "main",
               "Title",
               "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "create" | _args], _opts ->
                   {"created", 0}

                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/4",
                      "state" => "OPEN"
                    }), 0}
               end
             )

    assert {:error, {:pr_create_failed, 1, "bad create"}} =
             GitHubCLIClient.create_pull_request(
               "/tmp/workspace",
               "gaspar/test",
               "main",
               "Title",
               "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "create" | _args], _opts ->
                   {"bad create", 1}
               end
             )
  end

  test "merge and persist PR URL handle open merged closed and blank cases" do
    assert {:ok, %{merged: true, status: :merged, url: "https://github.com/example/repo/pull/5"}} =
             GitHubCLIClient.merge_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/5",
                      "state" => "OPEN"
                    }), 0}

                 "gh", ["pr", "merge", "--squash", "--delete-branch=false"], _opts ->
                   {"merged", 0}
               end
             )

    assert {:error, {:merge_failed, 1, "merge boom"}} =
             GitHubCLIClient.merge_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/5",
                      "state" => "OPEN"
                    }), 0}

                 "gh", ["pr", "merge", "--squash", "--delete-branch=false"], _opts ->
                   {"merge boom", 1}
               end
             )

    assert {:ok, %{status: :already_merged}} =
             GitHubCLIClient.merge_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/6",
                      "state" => "MERGED"
                    }), 0}
               end
             )

    assert {:error, {:pr_closed, "https://github.com/example/repo/pull/7"}} =
             GitHubCLIClient.merge_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/7",
                      "state" => "CLOSED"
                    }), 0}
               end
             )

    ref = make_ref()

    assert :ok =
             GitHubCLIClient.persist_pr_url(
               "/tmp/workspace",
               "gaspar/test",
               "https://github.com/example/repo/pull/8",
               gh_runner: fn
                 "git",
                 [
                   "config",
                   "branch.gaspar/test.symphony-pr-url",
                   "https://github.com/example/repo/pull/8"
                 ],
                 _opts ->
                   send(self(), ref)
                   {"", 0}
               end
             )

    assert_received ^ref

    assert :ok =
             GitHubCLIClient.persist_pr_url("/tmp/workspace", "", "",
               gh_runner: fn _command, _args, _opts ->
                 flunk("blank branch/url should not call git config")
               end
             )
  end

  test "review_feedback loads reviews and inline comments from gh api" do
    assert {:ok, feedback} =
             GitHubCLIClient.review_feedback("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,number,reviewDecision"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/42",
                      "number" => 42,
                      "reviewDecision" => "CHANGES_REQUESTED"
                    }), 0}

                 "gh", ["api", "repos/example/repo/pulls/42/reviews"], _opts ->
                   {Jason.encode!([
                      %{
                        "id" => 1,
                        "body" => "Please fix this.",
                        "state" => "CHANGES_REQUESTED",
                        "submitted_at" => "2026-03-11T10:00:00Z",
                        "user" => %{"login" => "reviewer"}
                      }
                    ]), 0}

                 "gh", ["api", "repos/example/repo/pulls/42/comments"], _opts ->
                   {Jason.encode!([
                      %{
                        "id" => 2,
                        "body" => "nit: rename this",
                        "path" => "lib/example.ex",
                        "line" => 12,
                        "created_at" => "2026-03-11T10:01:00Z",
                        "user" => %{"login" => "reviewer"}
                      },
                      %{
                        "id" => 3,
                        "body" => "I fixed this locally.",
                        "in_reply_to_id" => 2,
                        "created_at" => "2026-03-11T10:02:00Z",
                        "html_url" => "https://github.com/example/repo/pull/42#discussion_r3",
                        "user" => %{"login" => "gaspardip"}
                      }
                    ]), 0}
               end
             )

    assert feedback.pr_url == "https://github.com/example/repo/pull/42"
    assert feedback.review_decision == "CHANGES_REQUESTED"
    assert [%{author: "reviewer", state: "CHANGES_REQUESTED"}] = feedback.reviews

    assert [
             %{
               author: "reviewer",
               path: "lib/example.ex",
               line: 12,
               replies: [%{id: "3", author: "gaspardip"}]
             }
           ] = feedback.comments
  end

  test "review_feedback_by_pr_url loads reviews and inline comments without a workspace checkout" do
    assert {:ok, feedback} =
             GitHubCLIClient.review_feedback_by_pr_url("https://github.com/example/repo/pull/42",
               gh_runner: fn
                 "gh", ["api", "repos/example/repo/pulls/42"], _opts ->
                   {Jason.encode!(%{
                      "url" => "https://github.com/example/repo/pull/42",
                      "review_decision" => "CHANGES_REQUESTED"
                    }), 0}

                 "gh", ["api", "repos/example/repo/pulls/42/reviews"], _opts ->
                   {Jason.encode!([
                      %{
                        "id" => 1,
                        "body" => "Please fix this.",
                        "state" => "CHANGES_REQUESTED",
                        "submitted_at" => "2026-03-11T10:00:00Z",
                        "user" => %{"login" => "reviewer"}
                      }
                    ]), 0}

                 "gh", ["api", "repos/example/repo/pulls/42/comments"], _opts ->
                   {Jason.encode!([
                      %{
                        "id" => 2,
                        "body" => "nit: rename this",
                        "path" => "lib/example.ex",
                        "line" => 12,
                        "created_at" => "2026-03-11T10:01:00Z",
                        "user" => %{"login" => "reviewer"}
                      }
                    ]), 0}
               end
             )

    assert feedback.pr_url == "https://github.com/example/repo/pull/42"
    assert feedback.review_decision == "CHANGES_REQUESTED"
    assert [%{author: "reviewer", state: "CHANGES_REQUESTED"}] = feedback.reviews
    assert [%{author: "reviewer", path: "lib/example.ex", line: 12}] = feedback.comments
  end

  test "post_review_comment_reply posts to the pull request review comment replies endpoint" do
    assert {:ok,
            %{
              id: "123",
              url: "https://github.com/example/repo/pull/42#discussion_r123",
              output: output
            }} =
             GitHubCLIClient.post_review_comment_reply(
               "https://github.com/example/repo/pull/42",
               "456",
               "Looks good.",
               gh_runner: fn
                 "gh",
                 [
                   "api",
                   "repos/example/repo/pulls/42/comments/456/replies",
                   "-f",
                   "body=Looks good."
                 ],
                 _opts ->
                   payload = %{
                     "id" => 123,
                     "html_url" => "https://github.com/example/repo/pull/42#discussion_r123"
                   }

                   {Jason.encode!(payload), 0}
               end
             )

    assert output =~ "\"id\":123"
  end

  test "post_review_comment_reply propagates gh failures" do
    assert {:error, {:review_reply_failed, 1, "boom"}} =
             GitHubCLIClient.post_review_comment_reply(
               "https://github.com/example/repo/pull/42",
               "456",
               "Looks good.",
               gh_runner: fn
                 "gh",
                 [
                   "api",
                   "repos/example/repo/pulls/42/comments/456/replies",
                   "-f",
                   "body=Looks good."
                 ],
                 _opts ->
                   {"boom", 1}
               end
             )
  end

  test "resolve_review_comment_thread finds and resolves the matching review thread" do
    assert {:ok, %{thread_id: "THREAD_123", resolved: true, output: output}} =
             GitHubCLIClient.resolve_review_comment_thread(
               "https://github.com/example/repo/pull/42",
               "456",
               gh_runner: fn
                 "gh",
                 [
                   "api",
                   "graphql",
                   "-f",
                   query_arg,
                   "-F",
                   "owner=example",
                   "-F",
                   "repo=repo",
                   "-F",
                   "number=42"
                 ],
                 _opts ->
                   assert String.starts_with?(query_arg, "query=")

                   payload = %{
                     "data" => %{
                       "repository" => %{
                         "pullRequest" => %{
                           "reviewThreads" => %{
                             "nodes" => [
                               %{
                                 "id" => "THREAD_123",
                                 "comments" => %{"nodes" => [%{"databaseId" => 456}]}
                               }
                             ],
                             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                           }
                         }
                       }
                     }
                   }

                   {Jason.encode!(payload), 0}

                 "gh",
                 ["api", "graphql", "-f", mutation_arg, "-F", "threadId=THREAD_123"],
                 _opts ->
                   assert String.starts_with?(mutation_arg, "query=")

                   payload = %{
                     "data" => %{
                       "resolveReviewThread" => %{
                         "thread" => %{"id" => "THREAD_123", "isResolved" => true}
                       }
                     }
                   }

                   {Jason.encode!(payload), 0}
               end
             )

    assert output =~ "THREAD_123"
  end
end
