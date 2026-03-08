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
           ["pr", "create", "--title", title, "--body-file", body_file, "--base", base_branch, "--head", branch],
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
        {:ok, %{merged: true, url: url, output: "Pull request already merged.", status: :already_merged}}

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

  defp command_runner(opts) do
    Keyword.get(opts, :gh_runner, &System.cmd/3)
  end
end
