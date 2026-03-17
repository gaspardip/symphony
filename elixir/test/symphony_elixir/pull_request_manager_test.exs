defmodule SymphonyElixir.PullRequestManagerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PullRequestManager

  test "ensure_pull_request generates a PR body that passes the Symphony lint contract" do
    workspace = Path.expand("../../..", __DIR__)

    issue = %Issue{
      id: "issue-pr-body",
      identifier: "MT-901",
      title: "Generate deterministic PR body",
      url: "https://linear.app/test/issue/MT-901"
    }

    run_state = %{
      branch: "gaspar/test-pr-body",
      base_branch: "main",
      stage: "publish",
      last_turn_result: %{summary: "Add a deterministic runtime-owned publish flow."},
      last_validation: %{status: "passed"},
      last_verifier: %{status: "passed"}
    }

    gh_runner = fn
      "gh", ["pr", "view", "--json", "url,state"], _opts ->
        {"no pull request found", 1}

      "gh", ["pr", "create" | args], _opts ->
        body_file = body_file_from_args(args)
        send(self(), {:pr_body_created, File.read!(body_file)})
        {"https://github.com/gaspardip/symphony/pull/1\n", 0}

      "git", ["config", _key, _value], _opts ->
        {"", 0}
    end

    assert {:ok, %{url: url, body_validation: %{status: "passed"}}} =
             PullRequestManager.ensure_pull_request(workspace, issue, run_state, gh_runner: gh_runner)

    assert url == "https://github.com/gaspardip/symphony/pull/1"

    assert_receive {:pr_body_created, body}
    assert body =~ "#### Context"
    assert body =~ "#### TL;DR"
    assert body =~ "#### Summary"
    assert body =~ "#### Alternatives"
    assert body =~ "#### Test Plan"
    assert body =~ "- [x] `make -C elixir all`"
  end

  test "ensure_pull_request can use a GitHub adapter module instead of direct gh calls" do
    workspace = Path.join(System.tmp_dir!(), "symphony-pr-adapter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-pr-adapter",
      identifier: "MT-902",
      title: "Use GitHub adapter seam",
      url: "https://linear.app/test/issue/MT-902"
    }

    run_state = %{
      branch: "gaspar/test-pr-adapter",
      base_branch: "main",
      stage: "publish",
      last_turn_result: %{summary: "Route PR operations through a gh-backed adapter seam."},
      last_validation: %{status: "passed"},
      last_verifier: %{status: "passed"}
    }

    assert {:ok, %{url: "https://github.com/gaspardip/symphony/pull/2"}} =
             PullRequestManager.ensure_pull_request(
               workspace,
               issue,
               run_state,
               github_client: __MODULE__.FakeGitHubClient,
               github_client_opts: [test_pid: self()]
             )

    assert_received {:adapter_existing_pull_request, ^workspace}
    assert_received {:adapter_create_pull_request, ^workspace, "gaspar/test-pr-adapter", "main", _title}
    assert_received {:adapter_persist_pr_url, ^workspace, "gaspar/test-pr-adapter", "https://github.com/gaspardip/symphony/pull/2"}
    assert_received {:adapter_body_contents, body}
    assert body =~ "Automated PR for MT-902."
  end

  test "ensure_pull_request updates an existing PR through the GitHub adapter seam" do
    workspace = Path.join(System.tmp_dir!(), "symphony-pr-edit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-pr-edit",
      identifier: "MT-904",
      title: "Update PR hygiene on an existing PR",
      url: "https://linear.app/test/issue/MT-904"
    }

    run_state = %{
      branch: "gaspar/test-pr-edit",
      base_branch: "main",
      stage: "merge_readiness",
      last_turn_result: %{summary: "Refresh the PR body without opening a new PR."},
      last_validation: %{status: "passed"},
      last_verifier: %{status: "passed"}
    }

    assert {:ok, %{url: "https://github.com/gaspardip/symphony/pull/22", body_validation: %{status: "skipped"}}} =
             PullRequestManager.ensure_pull_request(
               workspace,
               issue,
               run_state,
               github_client: __MODULE__.FakeExistingPullRequestGitHubClient,
               github_client_opts: [test_pid: self()]
             )

    assert_received {:adapter_existing_pull_request, ^workspace, :existing}
    assert_received {:adapter_edit_pull_request, ^workspace, _title}
    assert_received {:adapter_existing_body_contents, body}
    assert body =~ "Automated PR for MT-904."
    assert_received {:adapter_persist_pr_url, ^workspace, "gaspar/test-pr-edit", "https://github.com/gaspardip/symphony/pull/22"}
  end

  test "merge_pull_request is idempotent when the PR is already merged" do
    workspace = "/tmp/symphony-pr-merged"

    gh_runner = fn
      "gh", ["pr", "view", "--json", "url,state"], _opts ->
        {Jason.encode!(%{"url" => "https://github.com/gaspardip/symphony/pull/3", "state" => "MERGED"}), 0}

      "gh", ["pr", "merge" | _args], _opts ->
        send(self(), :unexpected_merge_attempt)
        {"should not merge", 1}
    end

    assert {:ok, %{merged: true, url: "https://github.com/gaspardip/symphony/pull/3", status: :already_merged}} =
             PullRequestManager.merge_pull_request(workspace, gh_runner: gh_runner)

    refute_received :unexpected_merge_attempt
  end

  test "merge_pull_request fails cleanly when the PR is already closed" do
    workspace = "/tmp/symphony-pr-closed"

    gh_runner = fn
      "gh", ["pr", "view", "--json", "url,state"], _opts ->
        {Jason.encode!(%{"url" => "https://github.com/gaspardip/symphony/pull/4", "state" => "CLOSED"}), 0}
    end

    assert {:error, {:pr_closed, "https://github.com/gaspardip/symphony/pull/4"}} =
             PullRequestManager.merge_pull_request(workspace, gh_runner: gh_runner)
  end

  test "ensure_pull_request respects policy-pack PR posting restrictions" do
    workspace = Path.join(System.tmp_dir!(), "symphony-pr-forbidden-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{id: "issue-pr-forbidden", identifier: "MT-903", title: "Shadow mode PR restriction"}
    run_state = %{branch: "gaspar/test-pr-forbidden", base_branch: "main"}

    assert {:error, {:pr_posting_forbidden, "client_safe_shadow"}} =
             PullRequestManager.ensure_pull_request(
               workspace,
               issue,
               run_state,
               policy_pack: :client_safe
             )
  end

  test "merge_pull_request respects credential scope" do
    registry_path =
      Path.join(System.tmp_dir!(), "symphony-pr-registry-#{System.unique_integer([:positive])}.json")

    File.write!(
      registry_path,
      Jason.encode!(%{
        "companies" => %{
          "Client A" => %{
            "providers" => %{
              "github" => %{"forbidden_operations" => ["merge"]}
            }
          }
        }
      })
    )

    on_exit(fn -> File.rm(registry_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      company_name: "Client A",
      company_credential_registry_path: registry_path
    )

    assert {:error, {:credential_scope_forbidden, "github", "merge"}} =
             PullRequestManager.merge_pull_request("/tmp/symphony-pr-scope")
  end

  defmodule FakeGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def existing_pull_request(workspace, opts) do
      send(opts[:test_pid], {:adapter_existing_pull_request, workspace})
      {:error, :missing_pr}
    end

    @impl true
    def edit_pull_request(_workspace, _title, _body_file, _opts) do
      raise "edit should not be called when no PR exists"
    end

    @impl true
    def create_pull_request(workspace, branch, base_branch, title, body_file, opts) do
      send(opts[:test_pid], {:adapter_create_pull_request, workspace, branch, base_branch, title})
      send(opts[:test_pid], {:adapter_body_contents, File.read!(body_file)})
      {:ok, %{url: "https://github.com/gaspardip/symphony/pull/2", state: "OPEN"}}
    end

    @impl true
    def merge_pull_request(_workspace, _opts) do
      raise "merge should not be called in this test"
    end

    @impl true
    def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}

    @impl true
    def persist_pr_url(workspace, branch, url, opts) do
      send(opts[:test_pid], {:adapter_persist_pr_url, workspace, branch, url})
      :ok
    end

    @impl true
    def post_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}
  end

  defmodule FakeExistingPullRequestGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def existing_pull_request(workspace, opts) do
      send(opts[:test_pid], {:adapter_existing_pull_request, workspace, :existing})
      {:ok, %{url: "https://github.com/gaspardip/symphony/pull/22", state: "OPEN"}}
    end

    @impl true
    def edit_pull_request(workspace, title, body_file, opts) do
      send(opts[:test_pid], {:adapter_edit_pull_request, workspace, title})
      send(opts[:test_pid], {:adapter_existing_body_contents, File.read!(body_file)})
      {:ok, %{url: "https://github.com/gaspardip/symphony/pull/22", state: "OPEN"}}
    end

    @impl true
    def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, _opts) do
      raise "create should not be called when an existing PR is present"
    end

    @impl true
    def merge_pull_request(_workspace, _opts) do
      raise "merge should not be called in this test"
    end

    @impl true
    def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}

    @impl true
    def persist_pr_url(workspace, branch, url, opts) do
      send(opts[:test_pid], {:adapter_persist_pr_url, workspace, branch, url})
      :ok
    end

    @impl true
    def post_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}
  end

  defp body_file_from_args(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--body-file", file] -> file
      _ -> nil
    end)
  end
end
