defmodule SymphonyElixir.VerifierRunner do
  @moduledoc """
  Runs the hybrid publish gate: deterministic smoke first, then a read-only Codex verifier.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.IssueAcceptance
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.VerifierResult

  @report_verifier_result_tool "report_verifier_result"
  @verifier_result_key_prefix :symphony_verifier_result

  @spec verify(Path.t(), Issue.t() | map(), map(), RunInspector.snapshot(), keyword()) :: map()
  def verify(workspace, issue, state, inspection, opts \\ [])
      when is_binary(workspace) and is_map(state) do
    smoke_result = RunInspector.run_smoke(workspace, inspection.harness, opts)
    acceptance = IssueAcceptance.from_issue(issue)
    context = verification_context(workspace, state, acceptance, smoke_result, opts)

    case smoke_result.status do
      :unavailable ->
        blocked_result(
          "The repo smoke command is unavailable, so Symphony cannot verify this change.",
          ["Smoke command missing or invalid in `.symphony/harness.yml`."],
          context
        )

      :failed ->
        needs_more_work_result(
          "The smoke verification command failed, so the implementation needs another pass.",
          context
        )

      :passed ->
        before_snapshot = RunInspector.inspect(workspace, opts)
        verifier_session_runner = Keyword.get(opts, :verifier_session_runner, &run_verifier_session/4)

        case verifier_session_runner.(workspace, issue, state, Keyword.put(opts, :verification_context, context)) do
          {:ok, %VerifierResult{} = result} ->
            after_snapshot = RunInspector.inspect(workspace, opts)

            if RunInspector.code_changed?(before_snapshot, after_snapshot) do
              blocked_result(
                "The verifier mutated the workspace, which is forbidden for read-only verification.",
                ["Verification must not change files, git state, or PR metadata."],
                context
              )
            else
              verifier_result_payload(result, context)
            end

          {:error, :missing_verifier_result} ->
            blocked_result(
              "The verifier turn completed without reporting `report_verifier_result`.",
              ["Verifier tool result missing."],
              context
            )

          {:error, {:invalid_verifier_result, reason}} ->
            blocked_result(
              "The verifier reported an invalid structured result.",
              [inspect(reason)],
              context
            )

          {:error, reason} ->
            blocked_result(
              "The verifier session failed before producing a usable result.",
              [inspect(reason)],
              context
            )
        end
    end
  end

  @spec post_merge_verify(Path.t(), map() | nil, keyword()) :: RunInspector.command_result()
  def post_merge_verify(workspace, harness, opts \\ []) do
    RunInspector.run_post_merge(workspace, harness, opts)
  end

  defp run_verifier_session(workspace, issue, state, opts) do
    prompt = verifier_prompt(issue, state, Keyword.fetch!(opts, :verification_context))
    before_snapshot = RunInspector.inspect(workspace, opts)
    clear_verifier_result(issue)

    verifier_opts = [
      codex_command: verifier_codex_command(),
      on_message: Keyword.get(opts, :on_message, fn _message -> :ok end),
      tool_executor: verifier_tool_executor(issue),
      issue: issue
    ]

    with {:ok, session} <- AppServer.start_session(workspace, verifier_opts) do
      try do
        with {:ok, _turn_session} <- AppServer.run_turn(session, prompt, verifier_issue(issue), verifier_opts),
             {:ok, result} <- fetch_verifier_result(issue) do
          after_snapshot = RunInspector.inspect(workspace, opts)

          if RunInspector.code_changed?(before_snapshot, after_snapshot) do
            {:error, :verifier_mutated_workspace}
          else
            {:ok, result}
          end
        end
      after
        clear_verifier_result(issue)
        AppServer.stop_session(session)
      end
    end
  end

  defp verifier_prompt(issue, state, context) do
    issue = verifier_issue(issue)
    acceptance = Map.fetch!(context, :acceptance)
    smoke_result = Map.fetch!(context, :smoke_result)
    changed_files = Map.get(context, :changed_files, [])
    diff_summary = Map.get(context, :diff_summary) || "No diff summary available."
    validation_output = get_in(state, [:last_validation, :output]) || "No validation output recorded."

    """
    #{PromptBuilder.build_prompt(issue)}

    You are running a single read-only verifier turn for Symphony's hybrid publish gate.

    Hard rules:
    - Read the current workspace state, but do not edit files.
    - Do not create commits, push branches, open PRs, merge PRs, or change Linear states.
    - Do not use any tool except `#{@report_verifier_result_tool}`.
    - Call `#{@report_verifier_result_tool}` exactly once before the turn ends.

    Acceptance input:
    - implicit_acceptance: #{Map.get(acceptance, :implicit_acceptance, true)}
    - source_sections: #{Enum.join(Map.get(acceptance, :source_sections, []), ", ")}
    - summary: #{Map.get(acceptance, :summary)}
    - criteria:
    #{format_list(Map.get(acceptance, :criteria, []))}

    Workspace evidence:
    - changed_files:
    #{format_list(changed_files)}

    Git diff summary:
    #{diff_summary}

    Validation output excerpt:
    #{String.slice(to_string(validation_output), 0, 2_000)}

    Smoke output excerpt:
    #{String.slice(to_string(smoke_result.output || ""), 0, 2_000)}

    Return one verifier verdict:
    - `pass` if the diff satisfies the issue and is safe to publish
    - `needs_more_work` if implementation gaps remain
    - `unsafe_to_merge` if the current change is risky even if tests passed
    - `blocked` if you cannot complete the review from the repo and local evidence
    """
    |> String.trim()
  end

  defp verification_context(workspace, state, acceptance, smoke_result, opts) do
    %{
      acceptance: IssueAcceptance.to_prompt_map(acceptance),
      changed_files: RunInspector.changed_paths(workspace, opts),
      diff_summary: RunInspector.diff_summary(workspace, opts),
      smoke_result: smoke_result,
      validation_output: get_in(state, [:last_validation, :output])
    }
  end

  defp verifier_result_payload(%VerifierResult{} = result, context) do
    %{
      verdict: Atom.to_string(result.verdict),
      summary: result.summary,
      acceptance_gaps: result.acceptance_gaps,
      risky_areas: result.risky_areas,
      evidence:
        (result.evidence ++
           [
             "Acceptance summary: #{Map.get(context.acceptance, :summary)}",
             "Changed files: #{Enum.join(context.changed_files, ", ")}",
             "Diff summary: #{context.diff_summary || "No diff summary available."}"
           ])
        |> Enum.reject(&(&1 in [nil, "Changed files: ", "Acceptance summary: "])),
      raw_output: result.raw_output,
      smoke: command_result_to_map(context.smoke_result),
      acceptance: context.acceptance
    }
  end

  defp blocked_result(summary, risky_areas, context) do
    %{
      verdict: "blocked",
      summary: summary,
      acceptance_gaps: [],
      risky_areas: risky_areas,
      evidence: blocking_evidence(context),
      raw_output: summary,
      smoke: command_result_to_map(context.smoke_result),
      acceptance: context.acceptance
    }
  end

  defp needs_more_work_result(summary, context) do
    %{
      verdict: "needs_more_work",
      summary: summary,
      acceptance_gaps: [],
      risky_areas: [],
      evidence: blocking_evidence(context),
      raw_output: String.slice(to_string(context.smoke_result.output || ""), 0, 2_000),
      smoke: command_result_to_map(context.smoke_result),
      acceptance: context.acceptance
    }
  end

  defp blocking_evidence(context) do
    [
      "Acceptance summary: #{Map.get(context.acceptance, :summary)}",
      "Smoke status: #{context.smoke_result.status}",
      "Changed files: #{Enum.join(context.changed_files, ", ")}"
    ]
    |> Enum.reject(&(&1 in [nil, "Changed files: ", "Acceptance summary: "]))
  end

  defp verifier_tool_executor(issue) do
    fn tool, arguments ->
      case tool do
        @report_verifier_result_tool ->
          case VerifierResult.normalize(arguments) do
            {:ok, result} ->
              Process.put(verifier_result_key(issue), result)
              %{"success" => true, "contentItems" => [%{"type" => "inputText", "text" => "verifier result recorded"}]}

            {:error, reason} ->
              Process.put(verifier_result_key(issue), {:error, reason})
              %{"success" => false, "contentItems" => [%{"type" => "inputText", "text" => inspect(reason)}]}
          end

        _ ->
          %{
            "success" => false,
            "contentItems" => [
              %{
                "type" => "inputText",
                "text" => "Unsupported verifier tool: #{inspect(tool)}"
              }
            ]
          }
      end
    end
  end

  defp fetch_verifier_result(issue) do
    case Process.get(verifier_result_key(issue)) do
      %VerifierResult{} = result -> {:ok, result}
      nil -> {:error, :missing_verifier_result}
      {:error, reason} -> {:error, {:invalid_verifier_result, reason}}
      other -> {:error, {:invalid_verifier_result, other}}
    end
  end

  defp clear_verifier_result(issue) do
    Process.delete(verifier_result_key(issue))
    :ok
  end

  defp verifier_result_key(%Issue{id: issue_id}), do: {@verifier_result_key_prefix, issue_id}

  defp verifier_result_key(issue) when is_map(issue) do
    {@verifier_result_key_prefix, Map.get(issue, :id) || Map.get(issue, "id")}
  end

  defp verifier_issue(%Issue{} = issue), do: issue

  defp verifier_issue(issue) when is_map(issue) do
    %Issue{
      id: Map.get(issue, :id) || Map.get(issue, "id"),
      identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      title: Map.get(issue, :title) || Map.get(issue, "title"),
      description: Map.get(issue, :description) || Map.get(issue, "description")
    }
  end

  defp verifier_codex_command do
    command =
      Config.codex_command()
      |> String.replace(~r/--model_reasoning_effort(?:=|\s+)\S+/, "--model_reasoning_effort=medium")

    if String.contains?(command, "--model_reasoning_effort") do
      command
    else
      command <> " --model_reasoning_effort=medium"
    end
  end

  defp command_result_to_map(result) do
    %{
      status: result.status,
      command: result.command,
      output: String.slice(to_string(result.output || ""), 0, 2_000)
    }
  end

  defp format_list([]), do: "    - none"

  defp format_list(items) do
    items
    |> Enum.map_join("\n", fn item -> "    - #{item}" end)
  end
end
