defmodule SymphonyElixir.VerifierRunner do
  @moduledoc """
  Runs the hybrid publish gate: deterministic smoke first, then a read-only Codex verifier.
  """

  alias SymphonyElixir.BehavioralProof
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.DebugArtifacts
  alias SymphonyElixir.IssueAcceptance
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Observability
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.UiProof
  alias SymphonyElixir.VerifierResult

  @report_verifier_result_tool "report_verifier_result"
  @verifier_result_key_prefix :symphony_verifier_result

  @spec verify(Path.t(), Issue.t() | map(), map(), RunInspector.snapshot(), keyword()) :: map()
  def verify(workspace, issue, state, inspection, opts \\ [])
      when is_binary(workspace) and is_map(state) do
    metadata = %{
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      stage: "verify",
      policy_class: Map.get(state, :effective_policy_class),
      workflow_profile: Map.get(state, :effective_policy_class)
    }

    Observability.with_span("symphony.verifier", metadata, fn ->
      start_time = System.monotonic_time()
      smoke_result = RunInspector.run_smoke(workspace, inspection.harness, opts)
      acceptance = IssueAcceptance.from_issue(issue)
      context = verification_context(workspace, inspection, state, acceptance, smoke_result, opts)

      emit_proof_event(:behavioral, context.behavioral_proof, metadata)
      emit_proof_event(:ui, context.ui_proof, metadata)

      result =
        case smoke_result.status do
          :unavailable ->
            blocked_result(
              "The repo smoke command is unavailable, so Symphony cannot verify this change.",
              ["Smoke command missing or invalid in `.symphony/harness.yml`."],
              context
            )

          :failed ->
            store_failure_artifact("verify_smoke_failed", smoke_result.output || "", metadata)

            needs_more_work_result(
              "The smoke verification command failed, so the implementation needs another pass.",
              context
            )

          :passed ->
            cond do
              context.behavioral_proof.required? and not context.behavioral_proof.satisfied? ->
                missing_behavioral_proof_result(context)

              context.ui_proof.verify_required? and not context.ui_proof.verify_satisfied? ->
                missing_ui_proof_result(context)

              true ->
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

      Observability.emit(
        [:symphony, :verifier, :completed],
        %{count: 1, duration: System.monotonic_time() - start_time},
        metadata
        |> Map.put(:verdict, Map.get(result, :verdict) || Map.get(result, "verdict"))
        |> Map.put(:smoke_status, smoke_result.status)
      )

      result
    end)
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
      effort: Config.codex_turn_effort("verifier"),
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
    content_evidence = Map.get(context, :content_evidence, [])

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

    #{format_content_evidence(content_evidence)}

    Validation output excerpt:
    #{format_command_output_excerpt(validation_output)}

    Smoke output excerpt:
    #{format_command_output_excerpt(smoke_result.output || "")}

    Return one verifier verdict:
    - `pass` if the diff satisfies the issue and is safe to publish
    - `needs_more_work` if implementation gaps remain
    - `unsafe_to_merge` if the current change is risky even if tests passed
    - `blocked` if you cannot complete the review from the repo and local evidence
    """
    |> String.trim()
  end

  defp verification_context(workspace, inspection, state, acceptance, smoke_result, opts) do
    changed_files = RunInspector.changed_paths(workspace, opts)

    %{
      acceptance: IssueAcceptance.to_prompt_map(acceptance),
      changed_files: changed_files,
      diff_summary: RunInspector.diff_summary(workspace, opts),
      content_evidence: changed_file_content_evidence(workspace, changed_files),
      smoke_result: smoke_result,
      validation_output: get_in(state, [:last_validation, :output]),
      behavioral_proof: BehavioralProof.evaluate(workspace, inspection.harness, changed_files),
      ui_proof: UiProof.evaluate(workspace, inspection.harness, changed_files, inspection, opts)
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
      acceptance: context.acceptance,
      behavioral_proof: BehavioralProof.to_map(context.behavioral_proof),
      ui_proof: UiProof.to_map(context.ui_proof)
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
      acceptance: context.acceptance,
      behavioral_proof: BehavioralProof.to_map(context.behavioral_proof),
      ui_proof: UiProof.to_map(context.ui_proof)
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
      acceptance: context.acceptance,
      behavioral_proof: BehavioralProof.to_map(context.behavioral_proof),
      ui_proof: UiProof.to_map(context.ui_proof)
    }
  end

  defp missing_behavioral_proof_result(context) do
    %{
      verdict: "needs_more_work",
      summary: context.behavioral_proof.reason,
      acceptance_gaps: ["Add or update repo-owned behavioral proof before publish."],
      risky_areas: [],
      evidence: blocking_evidence(context),
      raw_output: context.behavioral_proof.reason,
      reason_code: "behavior_proof_missing",
      smoke: command_result_to_map(context.smoke_result),
      acceptance: context.acceptance,
      behavioral_proof: BehavioralProof.to_map(context.behavioral_proof),
      ui_proof: UiProof.to_map(context.ui_proof)
    }
  end

  defp missing_ui_proof_result(context) do
    %{
      verdict: "needs_more_work",
      summary: context.ui_proof.reason,
      acceptance_gaps: ["Add repo-owned UI proof before publish or merge."],
      risky_areas: [],
      evidence: blocking_evidence(context),
      raw_output: context.ui_proof.reason,
      reason_code: "ui_proof_missing",
      smoke: command_result_to_map(context.smoke_result),
      acceptance: context.acceptance,
      behavioral_proof: BehavioralProof.to_map(context.behavioral_proof),
      ui_proof: UiProof.to_map(context.ui_proof)
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

  @doc false
  def format_command_output_excerpt(output) do
    output = to_string(output || "")

    case String.length(output) do
      0 ->
        "No command output recorded."

      length when length <= 2_400 ->
        output

      _ ->
        head = String.slice(output, 0, 800)
        tail = String.slice(output, -1_600, 1_600)

        """
        #{head}

        ...

        #{tail}
        """
        |> String.trim()
    end
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
      external_id: Map.get(issue, :external_id) || Map.get(issue, "external_id"),
      canonical_identifier:
        Map.get(issue, :canonical_identifier) || Map.get(issue, "canonical_identifier") ||
          Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      title: Map.get(issue, :title) || Map.get(issue, "title"),
      description: Map.get(issue, :description) || Map.get(issue, "description")
    }
  end

  defp emit_proof_event(:behavioral, proof, metadata) do
    Observability.emit(
      [:symphony, :proof, :behavioral, :evaluated],
      %{count: 1},
      %{
        required: proof.required?,
        satisfied: proof.satisfied?,
        reason: proof.reason
      }
      |> Map.merge(metadata)
    )
  end

  defp emit_proof_event(:ui, proof, metadata) do
    Observability.emit(
      [:symphony, :proof, :ui, :evaluated],
      %{count: 1},
      %{
        required: proof.verify_required?,
        satisfied: proof.verify_satisfied?,
        reason: proof.reason
      }
      |> Map.merge(metadata)
    )
  end

  defp store_failure_artifact(kind, output, metadata) do
    case DebugArtifacts.store_failure(kind, output, metadata) do
      {:ok, artifact_ref} ->
        Observability.emit_debug_artifact_reference(kind, artifact_ref, metadata)
        :ok

      _ ->
        :ok
    end
  end

  defp command_result_to_map(result) do
    %{
      status: result.status,
      command: result.command,
      output: String.slice(to_string(result.output || ""), 0, 2_000)
    }
  end

  defp format_content_evidence([]), do: "Changed file content evidence:\n- none"

  defp format_content_evidence(entries) do
    rendered =
      entries
      |> Enum.map(fn %{path: path, excerpt: excerpt} ->
        "- #{path}:\n#{indent_text(excerpt, 2)}"
      end)
      |> Enum.join("\n")

    "Changed file content evidence:\n#{rendered}"
  end

  defp changed_file_content_evidence(workspace, changed_files) do
    changed_files
    |> Enum.filter(&doc_like_path?/1)
    |> Enum.take(4)
    |> Enum.map(&content_evidence_entry(workspace, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp content_evidence_entry(workspace, path) do
    file = Path.join(workspace, path)

    cond do
      not File.regular?(file) ->
        nil

      true ->
        case File.read(file) do
          {:ok, contents} ->
            excerpt = doc_content_excerpt(contents)

            if excerpt == "" do
              nil
            else
              %{path: path, excerpt: excerpt}
            end

          _ ->
            nil
        end
    end
  end

  defp doc_content_excerpt(contents) when is_binary(contents) do
    trimmed = String.trim(contents)

    cond do
      trimmed == "" ->
        ""

      String.length(trimmed) <= 2_400 ->
        trimmed

      true ->
        head = String.slice(trimmed, 0, 1_400)
        tail = String.slice(trimmed, -800, 800)

        """
        #{String.trim(head)}

        ...

        #{String.trim(tail)}
        """
        |> String.trim()
    end
  end

  defp doc_like_path?(path) when is_binary(path) do
    downcased = String.downcase(path)

    String.starts_with?(downcased, "docs/") or
      String.starts_with?(downcased, ".github/") or
      String.ends_with?(downcased, ".md") or
      String.ends_with?(downcased, ".txt") or
      String.ends_with?(downcased, ".json") or
      String.ends_with?(downcased, ".yaml") or
      String.ends_with?(downcased, ".yml") or
      String.ends_with?(downcased, ".toml") or
      String.ends_with?(downcased, ".sh") or
      Path.basename(downcased) in ["readme", "readme.md", "changelog.md"]
  end

  defp format_list([]), do: "    - none"

  defp format_list(items) do
    items
    |> Enum.map_join("\n", fn item -> "    - #{item}" end)
  end

  defp indent_text(text, spaces) do
    prefix = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end
end
