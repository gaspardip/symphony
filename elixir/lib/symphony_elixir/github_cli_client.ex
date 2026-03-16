defmodule SymphonyElixir.GitHubCLIClient do
  @moduledoc """
  Default GitHub client backed by `gh` and local git config.
  """

  @behaviour SymphonyElixir.GitHubClient

  @impl true
  def existing_pull_request(workspace, opts) when is_binary(workspace) do
    runner = command_runner(opts)

    case runner.(
           "gh",
           ["pr", "view", "--json", "url,state"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        with {:ok, payload} <- Jason.decode(output),
             url when is_binary(url) <- payload["url"] do
          {:ok, %{url: url, state: payload["state"]}}
        else
          _ -> {:error, :missing_pr}
        end

      {_output, _status} ->
        {:error, :missing_pr}
    end
  end

  @impl true
  def edit_pull_request(workspace, title, body_file, opts) do
    runner = command_runner(opts)

    with {:ok, %{url: url, state: state}} <- existing_pull_request(workspace, opts) do
      case runner.(
             "gh",
             ["pr", "edit", "--title", title, "--body-file", body_file],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          {:ok, %{url: url, state: state, output: output}}

        {output, status} ->
          {:error, {:pr_edit_failed, status, output}}
      end
    end
  end

  @impl true
  def create_pull_request(workspace, branch, base_branch, title, body_file, opts) do
    runner = command_runner(opts)

    case runner.(
           "gh",
           [
             "pr",
             "create",
             "--title",
             title,
             "--body-file",
             body_file,
             "--base",
             base_branch,
             "--head",
             branch
           ],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        normalize_pr_create_output(output, workspace, opts)

      {output, status} ->
        {:error, {:pr_create_failed, status, output}}
    end
  end

  @impl true
  def merge_pull_request(workspace, opts) when is_binary(workspace) do
    runner = command_runner(opts)

    case existing_pull_request(workspace, opts) do
      {:ok, %{url: url, state: state}} when state in ["MERGED", "merged"] ->
        {:ok,
         %{
           merged: true,
           url: url,
           output: "Pull request already merged.",
           status: :already_merged
         }}

      {:ok, %{url: url, state: state}} when state in ["CLOSED", "closed"] ->
        {:error, {:pr_closed, url}}

      {:ok, %{url: url}} ->
        case runner.(
               "gh",
               ["pr", "merge", "--squash", "--delete-branch=false"],
               cd: workspace,
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            {:ok, %{merged: true, url: url, output: output, status: :merged}}

          {output, status} ->
            {:error, {:merge_failed, status, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def review_feedback(workspace, opts) when is_binary(workspace) do
    runner = command_runner(opts)

    with {payload, 0} <-
           runner.(
             "gh",
             ["pr", "view", "--json", "url,number,reviewDecision"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         {:ok, pr_payload} <- Jason.decode(payload),
         url when is_binary(url) <- pr_payload["url"],
         number when is_integer(number) <- pr_payload["number"],
         {:ok, %{owner: owner, repo: repo}} <- parse_pr_repo(url),
         {reviews_output, 0} <-
           runner.(
             "gh",
             ["api", "repos/#{owner}/#{repo}/pulls/#{number}/reviews"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         {:ok, reviews_payload} <- Jason.decode(reviews_output),
         {comments_output, 0} <-
           runner.(
             "gh",
             ["api", "repos/#{owner}/#{repo}/pulls/#{number}/comments"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         {:ok, comments_payload} <- Jason.decode(comments_output) do
      {:ok,
       normalize_review_feedback(
         url,
         pr_payload["reviewDecision"],
         reviews_payload,
         comments_payload
       )}
    else
      {_output, _status} -> {:error, :review_feedback_unavailable}
      _ -> {:error, :review_feedback_unavailable}
    end
  end

  @impl true
  def review_feedback_by_pr_url(pr_url, opts) when is_binary(pr_url) do
    runner = command_runner(opts)

    with {:ok, %{owner: owner, repo: repo, number: number}} <- parse_pr_identity(pr_url),
         {payload, 0} <-
           runner.(
             "gh",
             ["api", "repos/#{owner}/#{repo}/pulls/#{number}"],
             stderr_to_stdout: true
           ),
         {:ok, pr_payload} <- Jason.decode(payload),
         {reviews_output, 0} <-
           runner.(
             "gh",
             ["api", "repos/#{owner}/#{repo}/pulls/#{number}/reviews"],
             stderr_to_stdout: true
           ),
         {:ok, reviews_payload} <- Jason.decode(reviews_output),
         {comments_output, 0} <-
           runner.(
             "gh",
             ["api", "repos/#{owner}/#{repo}/pulls/#{number}/comments"],
             stderr_to_stdout: true
           ),
         {:ok, comments_payload} <- Jason.decode(comments_output) do
      {:ok,
       normalize_review_feedback(
         pr_url,
         pr_payload["review_decision"] || pr_payload["reviewDecision"],
         reviews_payload,
         comments_payload
       )}
    else
      {_output, _status} -> {:error, :review_feedback_unavailable}
      _ -> {:error, :review_feedback_unavailable}
    end
  end

  @impl true
  def persist_pr_url(workspace, branch, url, opts) do
    runner = command_runner(opts)

    if is_binary(branch) and branch != "" and is_binary(url) and url != "" do
      runner.(
        "git",
        ["config", "branch.#{branch}.symphony-pr-url", url],
        cd: workspace,
        stderr_to_stdout: true
      )
    end

    :ok
  end

  @impl true
  def post_review_comment_reply(pr_url, comment_id, body, opts)
      when is_binary(pr_url) and is_binary(comment_id) and is_binary(body) do
    runner = command_runner(opts)

    with {:ok, %{owner: owner, repo: repo, number: number}} <- parse_pr_identity(pr_url),
         {output, 0} <-
           runner.(
             "gh",
             [
               "api",
               "repos/#{owner}/#{repo}/pulls/#{number}/comments/#{comment_id}/replies",
               "-f",
               "body=#{body}"
             ],
             stderr_to_stdout: true
           ),
         {:ok, payload} <- Jason.decode(output) do
      {:ok,
       %{
         id: payload["id"] && to_string(payload["id"]),
         url: payload["html_url"],
         output: output
       }}
    else
      {output, status} when is_integer(status) ->
        {:error, {:review_reply_failed, status, output}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :review_reply_failed}
    end
  end

  @impl true
  def edit_review_comment_reply(pr_url, comment_id, body, opts)
      when is_binary(pr_url) and is_binary(comment_id) and is_binary(body) do
    runner = command_runner(opts)

    with {:ok, %{owner: owner, repo: repo, number: _number}} <- parse_pr_identity(pr_url),
         {output, 0} <-
           runner.(
             "gh",
             [
               "api",
               "--method",
               "PATCH",
               "repos/#{owner}/#{repo}/pulls/comments/#{comment_id}",
               "-f",
               "body=#{body}"
             ],
             stderr_to_stdout: true
           ),
         {:ok, payload} <- Jason.decode(output) do
      {:ok,
       %{
         id: payload["id"] && to_string(payload["id"]),
         url: payload["html_url"],
         output: output
       }}
    else
      {output, status} when is_integer(status) ->
        {:error, {:review_reply_update_failed, status, output}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :review_reply_update_failed}
    end
  end

  defp normalize_pr_create_output(output, workspace, opts) do
    url =
      output
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "http"))

    if is_binary(url) do
      {:ok, %{url: url, state: "OPEN"}}
    else
      existing_pull_request(workspace, opts)
    end
  end

  defp parse_pr_repo(url) when is_binary(url) do
    with {:ok, %{owner: owner, repo: repo}} <- parse_pr_identity(url) do
      {:ok, %{owner: owner, repo: repo}}
    end
  end

  defp parse_pr_identity(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: "github.com", path: path} ->
        case String.split(path || "", "/", trim: true) do
          [owner, repo, "pull", number | _rest] ->
            {:ok, %{owner: owner, repo: repo, number: number}}

          _ ->
            {:error, :invalid_pr_url}
        end

      _ ->
        {:error, :invalid_pr_url}
    end
  end

  defp normalize_review_feedback(url, review_decision, reviews_payload, comments_payload) do
    %{
      pr_url: url,
      review_decision: review_decision,
      reviews: normalize_reviews(reviews_payload),
      comments: normalize_review_comments(comments_payload)
    }
  end

  defp normalize_reviews(reviews) when is_list(reviews) do
    Enum.map(reviews, fn review ->
      %{
        id: review["id"],
        body: blank_to_nil(review["body"]),
        state: blank_to_nil(review["state"]),
        submitted_at: blank_to_nil(review["submitted_at"]),
        author: get_in(review, ["user", "login"])
      }
    end)
  end

  defp normalize_reviews(_), do: []

  defp normalize_review_comments(comments) when is_list(comments) do
    Enum.map(comments, fn comment ->
      %{
        id: comment["id"],
        body: blank_to_nil(comment["body"]),
        path: blank_to_nil(comment["path"]),
        line: comment["line"] || comment["original_line"],
        created_at: blank_to_nil(comment["created_at"]),
        updated_at: blank_to_nil(comment["updated_at"]),
        url: blank_to_nil(comment["html_url"]),
        author: get_in(comment, ["user", "login"])
      }
    end)
  end

  defp normalize_review_comments(_), do: []

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp command_runner(opts) do
    Keyword.get(opts, :gh_runner, &System.cmd/3)
  end
end
