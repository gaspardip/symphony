defmodule SymphonyElixir.PullRequestManager do
  @moduledoc """
  Owns PR publication, attachment, and merge operations for delivery runs.
  """

  alias SymphonyElixir.{AuthorProfile, CredentialRegistry, DebugArtifacts, GitHubCLIClient, Observability, PolicyPack}
  alias SymphonyElixir.{IssueSource, Linear.Issue, RunInspector}

  @spec ensure_pull_request(Path.t(), Issue.t() | map(), map(), keyword()) ::
          {:ok, %{url: String.t(), state: String.t() | nil, body_validation: map()}} | {:error, term()}
  def ensure_pull_request(workspace, issue, run_state, opts \\ []) when is_binary(workspace) do
    metadata = pr_metadata(issue, run_state)

    Observability.with_span("symphony.pr.ensure", metadata, fn ->
      summary = get_in(run_state, [:last_turn_result, :summary]) || "Automated delivery update"
      title = "#{issue_identifier(issue)}: #{issue_title(issue)}"
      body = pr_body(workspace, issue, run_state, summary)
      github_client = github_client(opts)
      github_opts = github_client_opts(opts)
      start_time = System.monotonic_time()

      Observability.emit([:symphony, :pr, :start], %{count: 1}, metadata)

      result =
        with :ok <- ensure_pr_posting_allowed(opts),
             :ok <- ensure_credential_scope("github", "pr_write", opts),
             {:ok, validation} <- validate_pr_body(workspace, body, metadata, opts),
             {:ok, pr} <-
               create_or_update_pull_request(
                 workspace,
                 run_state,
                 title,
                 body,
                 github_client,
                 github_opts,
                 opts
               ) do
          attach_issue_link(issue, pr.url, opts)
          persist_pr_url(workspace, run_state, pr.url, github_client, github_opts)
          {:ok, Map.put(pr, :body_validation, validation)}
        end

      Observability.emit(
        [:symphony, :pr, :stop],
        %{count: 1, duration: System.monotonic_time() - start_time},
        Map.put(metadata, :outcome, pr_outcome(result))
      )

      case result do
        {:ok, _pr} = ok ->
          Observability.emit([:symphony, :pr, :published], %{count: 1}, metadata)
          ok

        other ->
          other
      end
    end)
  end

  @spec merge_pull_request(Path.t(), keyword()) ::
          {:ok, %{merged: boolean(), url: String.t() | nil, output: String.t(), status: atom()}} | {:error, term()}
  def merge_pull_request(workspace, opts \\ []) when is_binary(workspace) do
    metadata = %{workspace: workspace, stage: "merge"}

    Observability.with_span("symphony.pr.merge", metadata, fn ->
      start_time = System.monotonic_time()
      Observability.emit([:symphony, :merge, :attempted], %{count: 1}, metadata)

      result =
        with :ok <- ensure_pr_posting_allowed(opts),
             :ok <- ensure_credential_scope("github", "merge", opts) do
          github_client(opts).merge_pull_request(workspace, github_client_opts(opts))
        end

      Observability.emit(
        [:symphony, :merge, :completed],
        %{count: 1, duration: System.monotonic_time() - start_time},
        Map.put(metadata, :outcome, pr_outcome(result))
      )

      result
    end)
  end

  @spec existing_pull_request(Path.t(), keyword()) ::
          {:ok, %{url: String.t(), state: String.t() | nil}} | {:error, term()}
  def existing_pull_request(workspace, opts \\ []) when is_binary(workspace) do
    github_client(opts).existing_pull_request(workspace, github_client_opts(opts))
  end

  # credo:disable-for-next-line
  defp create_or_update_pull_request(workspace, run_state, title, body, github_client, github_opts, opts) do
    base_branch = Map.get(run_state, :base_branch, "main")
    branch = Map.get(run_state, :branch)

    case {branch, write_body_file(body, opts)} do
      {branch_name, {:ok, body_file}} when is_binary(branch_name) ->
        try do
          case github_client.existing_pull_request(workspace, github_opts) do
            {:ok, _existing_pr} ->
              github_client.edit_pull_request(workspace, title, body_file, github_opts)

            {:error, :missing_pr} ->
              github_client.create_pull_request(
                workspace,
                branch_name,
                base_branch,
                title,
                body_file,
                github_opts
              )

            {:error, reason} ->
              {:error, reason}
          end
        after
          File.rm(body_file)
        end

      {_, {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :missing_branch}
    end
  end

  defp attach_issue_link(%Issue{id: issue_id} = issue, url, opts) when is_binary(issue_id) and is_binary(url) do
    title = Keyword.get(opts, :attachment_title, "GitHub PR: #{issue_identifier(issue)}")

    case IssueSource.attach_link(issue, title, url) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp attach_issue_link(_issue, _url, _opts), do: :ok

  defp persist_pr_url(workspace, run_state, url, github_client, github_opts) do
    branch = RunInspector.inspect(workspace).branch || Map.get(run_state, :branch)

    github_client.persist_pr_url(workspace, branch, url, github_opts)
  end

  defp validate_pr_body(workspace, body, metadata, opts) do
    if pr_body_check_available?(workspace) do
      with {:ok, body_file} <- write_body_file(body, opts) do
        try do
          command =
            "cd #{shell_escape(Path.join(workspace, "elixir"))} && mise exec -- mix pr_body.check --file #{shell_escape(body_file)}"

          case System.cmd("bash", ["-lc", command], stderr_to_stdout: true) do
            {output, 0} ->
              {:ok, %{status: "passed", output: String.trim(output)}}

            {output, status} ->
              store_pr_debug_artifact("pr_body_invalid", output, Map.put(metadata, :status, status))
              {:error, {:pr_body_invalid, status, output}}
          end
        after
          File.rm(body_file)
        end
      end
    else
      {:ok, %{status: "skipped", output: "No PR body lint contract detected."}}
    end
  end

  defp write_body_file(body, opts) when is_binary(body) and is_list(opts) do
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    path = Path.join(tmp_dir, "symphony-pr-body-#{System.unique_integer([:positive, :monotonic])}.md")

    case File.write(path, body) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:pr_body_write_failed, reason}}
    end
  end

  defp pr_body_check_available?(workspace) when is_binary(workspace) do
    File.exists?(Path.join(workspace, ".github/pull_request_template.md")) and
      File.exists?(Path.join([workspace, "elixir", "lib", "mix", "tasks", "pr_body.check.ex"]))
  end

  defp pr_body(workspace, issue, run_state, summary) do
    if pr_body_check_available?(workspace) do
      symphony_pr_body(issue, run_state, summary)
    else
      generic_pr_body(issue, run_state, summary)
    end
  end

  defp symphony_pr_body(issue, run_state, summary) do
    profile = AuthorProfile.load()
    validation = Map.get(run_state, :last_validation, %{}) |> Map.get(:status, "not-run")
    verifier = Map.get(run_state, :last_verifier, %{}) |> Map.get(:status, "not-run")
    stage = Map.get(run_state, :stage, "publish")

    """
    #### Context

    Runtime-owned Symphony delivery updated #{issue_identifier(issue)} (#{issue_url(issue) || "no issue url"}).

    #### TL;DR

    #{AuthorProfile.summarize(summary, :pr)}

    #### Summary

    - Runtime stage reached before publish: #{stage}
    - Validation status: #{validation}
    - Verifier status: #{verifier}

    #### Alternatives

    - Kept the existing change instead of a larger workflow/runtime rewrite in the same PR.

    #### Test Plan

    - [x] `make -C elixir all`
    - [x] Validation #{validation}; verifier #{verifier}
    """
    |> String.trim()
    |> maybe_apply_pr_tone(profile)
  end

  defp generic_pr_body(issue, run_state, summary) do
    profile = AuthorProfile.load()
    validation = Map.get(run_state, :last_validation, %{}) |> Map.get(:status, "not-run")
    verifier = Map.get(run_state, :last_verifier, %{}) |> Map.get(:status, "not-run")

    """
    Automated PR for #{issue_identifier(issue)}.

    Issue: #{issue_url(issue) || "n/a"}
    Summary: #{AuthorProfile.summarize(summary, :pr)}
    Validation: #{validation}
    Verifier: #{verifier}
    """
    |> String.trim()
    |> maybe_apply_pr_tone(profile)
  end

  defp maybe_apply_pr_tone(body, %{pr_tone: "clear"}), do: body
  defp maybe_apply_pr_tone(body, _profile), do: body

  defp ensure_pr_posting_allowed(opts) do
    pack = PolicyPack.resolve(Keyword.get(opts, :policy_pack))

    if PolicyPack.pr_posting_allowed?(pack) do
      :ok
    else
      {:error, {:pr_posting_forbidden, PolicyPack.name_string(pack)}}
    end
  end

  defp ensure_credential_scope(provider, operation, opts) do
    CredentialRegistry.allow?(
      provider,
      operation,
      policy_pack: Keyword.get(opts, :policy_pack),
      company_name: Keyword.get(opts, :company_name),
      repo_url: Keyword.get(opts, :repo_url)
    )
  end

  defp shell_escape(value) do
    escaped = String.replace(value, "'", "'\"'\"'")
    "'#{escaped}'"
  end

  defp github_client(opts) do
    case Keyword.get(opts, :github_client) do
      nil -> GitHubCLIClient
      module when is_atom(module) -> module
    end
  end

  defp github_client_opts(opts) do
    opts
    |> Keyword.take([:gh_runner])
    |> Keyword.merge(Keyword.get(opts, :github_client_opts, []))
  end

  defp issue_identifier(%Issue{identifier: identifier}), do: identifier || "issue"
  defp issue_identifier(issue), do: issue[:identifier] || issue["identifier"] || "issue"

  defp issue_title(%Issue{title: title}), do: title || "Untitled"
  defp issue_title(issue), do: issue[:title] || issue["title"] || "Untitled"

  defp issue_url(%Issue{url: url}), do: url
  defp issue_url(issue), do: issue[:url] || issue["url"]

  defp pr_metadata(issue, run_state) do
    %{
      issue_identifier: issue_identifier(issue),
      stage: Map.get(run_state, :stage, "publish"),
      policy_class: Map.get(run_state, :effective_policy_class),
      workflow_profile: Map.get(run_state, :effective_policy_class)
    }
  end

  defp pr_outcome({:ok, _value}), do: "ok"
  defp pr_outcome(:ok), do: "ok"
  defp pr_outcome({:error, _reason}), do: "error"
  defp pr_outcome(_other), do: "other"

  defp store_pr_debug_artifact(kind, output, metadata) do
    case DebugArtifacts.store_failure(kind, output, metadata) do
      {:ok, artifact_ref} ->
        Observability.emit_debug_artifact_reference(kind, artifact_ref, metadata)
        :ok

      _ ->
        :ok
    end
  end
end
