defmodule SymphonyElixir.GitHubCLIClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubCLIClient

  test "existing pull request handles success malformed payloads and missing PRs" do
    assert {:ok, %{url: "https://github.com/example/repo/pull/1", state: "OPEN"}} =
             GitHubCLIClient.existing_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{"url" => "https://github.com/example/repo/pull/1", "state" => "OPEN"}), 0}
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
    assert {:ok, %{url: "https://github.com/example/repo/pull/2", state: "OPEN", output: "updated"}} =
             GitHubCLIClient.edit_pull_request("/tmp/workspace", "Title", "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{"url" => "https://github.com/example/repo/pull/2", "state" => "OPEN"}), 0}

                 "gh", ["pr", "edit", "--title", "Title", "--body-file", "/tmp/body.md"], _opts ->
                   {"updated", 0}
               end
             )

    assert {:error, {:pr_edit_failed, 1, "boom"}} =
             GitHubCLIClient.edit_pull_request("/tmp/workspace", "Title", "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{"url" => "https://github.com/example/repo/pull/2", "state" => "OPEN"}), 0}

                 "gh", ["pr", "edit", "--title", "Title", "--body-file", "/tmp/body.md"], _opts ->
                   {"boom", 1}
               end
             )

    assert {:ok, %{url: "https://github.com/example/repo/pull/3", state: "OPEN"}} =
             GitHubCLIClient.create_pull_request("/tmp/workspace", "gaspar/test", "main", "Title", "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "create" | _args], _opts ->
                   {"https://github.com/example/repo/pull/3\n", 0}
               end
             )

    assert {:ok, %{url: "https://github.com/example/repo/pull/4", state: "OPEN"}} =
             GitHubCLIClient.create_pull_request("/tmp/workspace", "gaspar/test", "main", "Title", "/tmp/body.md",
               gh_runner: fn
                 "gh", ["pr", "create" | _args], _opts ->
                   {"created", 0}

                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{"url" => "https://github.com/example/repo/pull/4", "state" => "OPEN"}), 0}
               end
             )

    assert {:error, {:pr_create_failed, 1, "bad create"}} =
             GitHubCLIClient.create_pull_request("/tmp/workspace", "gaspar/test", "main", "Title", "/tmp/body.md",
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
                   {Jason.encode!(%{"url" => "https://github.com/example/repo/pull/5", "state" => "OPEN"}), 0}

                 "gh", ["pr", "merge", "--squash", "--delete-branch=false"], _opts ->
                   {"merged", 0}
               end
             )

    assert {:error, {:merge_failed, 1, "merge boom"}} =
             GitHubCLIClient.merge_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{"url" => "https://github.com/example/repo/pull/5", "state" => "OPEN"}), 0}

                 "gh", ["pr", "merge", "--squash", "--delete-branch=false"], _opts ->
                   {"merge boom", 1}
               end
             )

    assert {:ok, %{status: :already_merged}} =
             GitHubCLIClient.merge_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{"url" => "https://github.com/example/repo/pull/6", "state" => "MERGED"}), 0}
               end
             )

    assert {:error, {:pr_closed, "https://github.com/example/repo/pull/7"}} =
             GitHubCLIClient.merge_pull_request("/tmp/workspace",
               gh_runner: fn
                 "gh", ["pr", "view", "--json", "url,state"], _opts ->
                   {Jason.encode!(%{"url" => "https://github.com/example/repo/pull/7", "state" => "CLOSED"}), 0}
               end
             )

    ref = make_ref()

    assert :ok =
             GitHubCLIClient.persist_pr_url("/tmp/workspace", "gaspar/test", "https://github.com/example/repo/pull/8",
               gh_runner: fn
                 "git", ["config", "branch.gaspar/test.symphony-pr-url", "https://github.com/example/repo/pull/8"], _opts ->
                   send(self(), ref)
                   {"", 0}
               end
             )

    assert_received ^ref

    assert :ok =
             GitHubCLIClient.persist_pr_url("/tmp/workspace", "", "", gh_runner: fn _command, _args, _opts ->
               flunk("blank branch/url should not call git config")
             end)
  end
end
