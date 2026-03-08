defmodule SymphonyElixir.GitManager do
  @moduledoc """
  Owns branch preparation, commits, pushes, and base-branch resets for delivery runs.
  """

  alias SymphonyElixir.Linear.Issue

  @spec prepare_issue_branch(Path.t(), Issue.t() | map(), map() | nil, keyword()) ::
          {:ok, %{branch: String.t(), base_branch: String.t()}} | {:error, term()}
  def prepare_issue_branch(workspace, issue, harness, opts \\ []) when is_binary(workspace) do
    branch = issue_branch_name(issue)
    base_branch = harness_base_branch(harness)
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    with :ok <- ensure_git_checkout(workspace),
         :ok <- git_ok(command_runner, workspace, ["fetch", "origin", "--prune", base_branch]),
         :ok <- checkout_branch(command_runner, workspace, branch, base_branch),
         :ok <- git_ok(command_runner, workspace, ["config", "branch.#{branch}.symphony-base-branch", base_branch]) do
      {:ok, %{branch: branch, base_branch: base_branch}}
    end
  end

  @spec commit_all(Path.t(), Issue.t() | map(), String.t(), keyword()) ::
          {:ok, :noop | %{sha: String.t(), message: String.t()}} | {:error, term()}
  def commit_all(workspace, issue, summary, opts \\ [])
      when is_binary(workspace) and is_binary(summary) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    with :ok <- ensure_git_checkout(workspace),
         dirty? <- dirty?(command_runner, workspace),
         {:dirty?, true} <- {:dirty?, dirty?},
         :ok <- git_ok(command_runner, workspace, ["add", "-A"]),
         message <- commit_message(issue, summary),
         :ok <- git_ok(command_runner, workspace, ["commit", "-m", message]),
         {:ok, sha} <- git_output(command_runner, workspace, ["rev-parse", "HEAD"]) do
      {:ok, %{sha: sha, message: message}}
    else
      {:dirty?, false} -> {:ok, :noop}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec push_branch(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def push_branch(workspace, branch, opts \\ []) when is_binary(workspace) and is_binary(branch) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    git_ok(command_runner, workspace, ["push", "-u", "origin", branch])
  end

  @spec reset_to_base(Path.t(), map() | nil, keyword()) :: :ok | {:error, term()}
  def reset_to_base(workspace, harness, opts \\ []) when is_binary(workspace) do
    base_branch = harness_base_branch(harness)
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    with :ok <- ensure_git_checkout(workspace),
         :ok <- git_ok(command_runner, workspace, ["fetch", "origin", "--prune", base_branch]),
         :ok <- git_ok(command_runner, workspace, ["checkout", base_branch]) do
      git_ok(command_runner, workspace, ["reset", "--hard", "origin/#{base_branch}"])
    end
  end

  @spec issue_branch_name(Issue.t() | map()) :: String.t()
  def issue_branch_name(%Issue{} = issue), do: issue_branch_name(Map.from_struct(issue))

  def issue_branch_name(issue) when is_map(issue) do
    preferred =
      issue[:branch_name] || issue["branch_name"] || issue[:branchName] || issue["branchName"]

    case preferred do
      value when is_binary(value) and value != "" ->
        sanitize_branch(value)

      _ ->
        identifier = issue[:identifier] || issue["identifier"] || "issue"
        "symphony/#{sanitize_branch(identifier)}"
    end
  end

  defp checkout_branch(command_runner, workspace, branch, base_branch) do
    case command_runner.("git", ["checkout", branch], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} ->
        git_ok(command_runner, workspace, ["reset", "--hard", "origin/#{base_branch}"])

      {_output, _status} ->
        git_ok(command_runner, workspace, ["checkout", "-B", branch, "origin/#{base_branch}"])
    end
  end

  defp ensure_git_checkout(workspace) do
    if File.exists?(Path.join(workspace, ".git")) do
      :ok
    else
      {:error, :missing_checkout}
    end
  end

  defp dirty?(command_runner, workspace) do
    case command_runner.("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp git_output(command_runner, workspace, args) do
    case command_runner.("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output |> to_string() |> String.trim()}
      {output, status} -> {:error, {:git_failed, Enum.join(args, " "), status, output}}
    end
  end

  defp git_ok(command_runner, workspace, args) do
    case command_runner.("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_failed, Enum.join(args, " "), status, output}}
    end
  end

  defp commit_message(issue, summary) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || "issue"
    title = sanitized_summary(summary)
    "#{identifier}: #{title}"
  end

  defp sanitized_summary(summary) do
    summary
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 72)
  end

  defp sanitize_branch(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._\/-]+/, "-")
    |> String.trim("-")
  end

  defp harness_base_branch(%{base_branch: value}) when is_binary(value) and value != "", do: value
  defp harness_base_branch(_harness), do: "main"
end
