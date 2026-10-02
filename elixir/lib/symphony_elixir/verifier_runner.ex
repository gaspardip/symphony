defmodule SymphonyElixir.VerifierRunner do
  @moduledoc """
  Runs the hybrid publish gate: deterministic smoke first, then a read-only agent verifier.
  """

  require Logger

  alias SymphonyElixir.AgentExecution
  alias SymphonyElixir.AgentProvider
  alias SymphonyElixir.BehavioralProof
  alias SymphonyElixir.Config
  alias SymphonyElixir.DebugArtifacts
  alias SymphonyElixir.EvidenceAcceptance
  alias SymphonyElixir.IssueAcceptance
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Observability
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.SecretRedactor
  alias SymphonyElixir.UiProof
  alias SymphonyElixir.VerifierResult

  @report_verifier_result_tool "report_verifier_result"
  @verifier_result_key_prefix :symphony_verifier_result

  @spec verify(Path.t(), Issue.t() | map(), map(), RunInspector.snapshot(), keyword()) :: map() | AgentExecution.terminal()
  def verify(workspace, issue, state, inspection, opts \\ [])
      when is_binary(workspace) and is_map(state) do
    with {:ok, _context} <- AgentExecution.entry_context(workspace, issue) do
      verify_with_context(workspace, issue, state, inspection, opts, :agent)
    end
  end

  @doc "Runs the real smoke/proof gates without a model when policy disables the agent verifier."
  @spec verify_without_agent(Path.t(), Issue.t() | map(), map(), RunInspector.snapshot(), keyword()) :: map() | AgentExecution.terminal()
  def verify_without_agent(workspace, issue, state, inspection, opts \\ []) do
    with {:ok, _context} <- AgentExecution.entry_context(workspace, issue) do
      if Config.policy_require_verifier?() do
        integrity_blocked(:evidence_verifier_required)
      else
        verify_with_context(workspace, issue, state, inspection, opts, :gate_only)
      end
    end
  end

  defp verify_with_context(workspace, issue, state, inspection, opts, mode) do
    metadata = %{
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      stage: "verify",
      policy_class: Map.get(state, :effective_policy_class),
      workflow_profile: Map.get(state, :effective_policy_class)
    }

    Observability.with_span("symphony.verifier", metadata, fn ->
      start_time = System.monotonic_time()

      with {:ok, smoke_result} <- current_step(workspace, issue, fn -> RunInspector.run_smoke(workspace, inspection.harness, opts) end),
           {:ok, {:ok, changed_files, scope}} <- current_step(workspace, issue, fn -> evidence_selection(workspace, inspection, opts) end),
           acceptance = IssueAcceptance.from_issue(issue),
           {:ok, context} <- verification_context(workspace, issue, inspection, state, acceptance, smoke_result, changed_files, scope, opts),
           {:ok, _} <- current_step(workspace, issue, fn -> emit_proof_event(:behavioral, context.behavioral_proof, metadata) end),
           {:ok, _} <- current_step(workspace, issue, fn -> emit_proof_event(:ui, context.ui_proof, metadata) end) do
        result = verifier_verdict(workspace, issue, state, smoke_result, context, metadata, opts, mode)
        result = accept_current_observation(result, context, mode)

        with result when is_map(result) <- result,
             {:ok, _execution_context} <- AgentExecution.entry_context(workspace, issue) do
          Observability.emit(
            [:symphony, :verifier, :completed],
            %{count: 1, duration: System.monotonic_time() - start_time},
            metadata
            |> Map.put(:verdict, Map.get(result, :verdict) || Map.get(result, "verdict"))
            |> Map.put(:smoke_status, smoke_result.status)
          )

          result
        end
      else
        {:ok, {:error, reason}} -> integrity_blocked(reason)
        {:error, reason} -> integrity_blocked(reason)
        {:stop, _} = terminal -> terminal
      end
    end)
  end

  defp verifier_verdict(workspace, issue, state, smoke_result, context, metadata, opts, mode) do
    case smoke_result.status do
      :unavailable ->
        blocked_result(
          "The repo smoke command is unavailable, so Symphony cannot verify this change.",
          ["Smoke command missing or invalid in `.symphony/harness.yml`."],
          context
        )

      :failed ->
        with {:ok, _} <- current_step(workspace, issue, fn -> store_failure_artifact("verify_smoke_failed", smoke_result.output || "", metadata) end) do
          needs_more_work_result("The smoke verification command failed, so the implementation needs another pass.", context)
        end

      :passed ->
        cond do
          context.behavioral_proof.required? and not context.behavioral_proof.satisfied? -> missing_behavioral_proof_result(context)
          context.ui_proof.verify_required? and not context.ui_proof.verify_satisfied? -> missing_ui_proof_result(context)
          mode == :gate_only -> gate_only_result(context)
          true -> verify_with_session(workspace, issue, state, context, opts)
        end
    end
  end

  defp verify_with_session(workspace, issue, state, context, opts) do
    runner = Keyword.get(opts, :verifier_session_runner, &run_verifier_session/4)

    with {:ok, before_snapshot} <- current_step(workspace, issue, fn -> RunInspector.inspect(workspace, opts) end),
         {:ok, result} <- current_step(workspace, issue, fn -> runner.(workspace, issue, state, Keyword.put(opts, :verification_context, context)) end) do
      case result do
        {:ok, %VerifierResult{} = result} ->
          with {:ok, after_snapshot} <- current_step(workspace, issue, fn -> RunInspector.inspect(workspace, opts) end) do
            if RunInspector.code_changed?(before_snapshot, after_snapshot) do
              blocked_result(
                "The verifier mutated the workspace, which is forbidden for read-only verification.",
                ["Verification must not change files, git state, or PR metadata."],
                context
              )
            else
              verifier_result_payload(result, context)
            end
          end

        {:error, :missing_verifier_result} ->
          blocked_result("The verifier turn completed without reporting `report_verifier_result`.", ["Verifier tool result missing."], context)

        {:error, {:invalid_verifier_result, reason}} ->
          blocked_result("The verifier reported an invalid structured result.", [inspect(reason)], context)

        {:error, reason} ->
          blocked_result("The verifier session failed before producing a usable result.", [inspect(reason)], context)
      end
    end
  end

  @spec post_merge_verify(Path.t(), map() | nil, keyword()) :: RunInspector.command_result() | AgentExecution.terminal()
  def post_merge_verify(workspace, harness, opts \\ []) do
    with {:ok, result} <- current_step(workspace, nil, fn -> RunInspector.run_post_merge(workspace, harness, opts) end), do: result
  end

  defp run_verifier_session(workspace, issue, state, opts) do
    prompt = verifier_prompt(issue, state, Keyword.fetch!(opts, :verification_context))

    with {:ok, before_snapshot} <- current_step(workspace, issue, fn -> RunInspector.inspect(workspace, opts) end) do
      clear_verifier_result(issue)

      verifier_opts = [
        effort: Config.agent_turn_effort("verifier"),
        model: Config.agent_model_for_stage("verifier") || Config.agent_model(),
        on_message: Keyword.get(opts, :on_message, fn _message -> :ok end),
        tool_executor: verifier_tool_executor(issue),
        issue: issue
      ]

      provider = AgentProvider.resolve_for_stage("verifier")

      with {:ok, session, binding} <- AgentProvider.open_session(provider, workspace, issue, :verifier, verifier_opts) do
        primary =
          capture_outcome(fn ->
            turn_opts = Keyword.put(verifier_opts, :execution_binding, binding)
            turn_result = AgentProvider.run_turn(provider, session, workspace, prompt, verifier_issue(issue), turn_opts, :verifier)

            with {:ok, _turn_session} <- turn_result,
                 {:ok, {:ok, result}} <- current_step(workspace, issue, fn -> fetch_verifier_result(issue) end),
                 {:ok, after_snapshot} <- current_step(workspace, issue, fn -> RunInspector.inspect(workspace, opts) end) do
              if RunInspector.code_changed?(before_snapshot, after_snapshot), do: {:error, :verifier_mutated_workspace}, else: {:ok, result}
            else
              {:ok, {:error, _} = error} -> error
              other -> other
            end
          end)

        cleanup =
          capture_outcome(fn ->
            clear_verifier_result(issue)
            AgentProvider.close_session(provider, session, binding)
          end)

        finish_with_cleanup(primary, cleanup)
      end
    end
  end

  defp current_step(workspace, issue, fun) do
    with {:ok, _context} <- AgentExecution.entry_context(workspace, issue) do
      result = fun.()
      current_result(workspace, issue, result)
    end
  end

  defp current_result(_workspace, _issue, {:stop, {kind, _}} = terminal) when kind in [:accounting_uncertain, :execution_stopped], do: terminal
  defp current_result(_workspace, _issue, {:stop, {:stale_execution, _, _}} = terminal), do: terminal

  defp current_result(workspace, issue, result) do
    with {:ok, _context} <- AgentExecution.entry_context(workspace, issue), do: {:ok, result}
  end

  # Capture only to run cleanup and then return/re-raise the exact selected outcome.
  defp capture_outcome(fun) do
    {:returned, fun.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp finish_with_cleanup(primary, cleanup) do
    cond do
      cleanup == {:returned, :ok} or cleanup == primary ->
        restore_outcome(primary)

      stopped_cleanup?(cleanup) and retained_primary?(primary) ->
        restore_outcome(primary)

      retained_primary?(primary) ->
        Logger.error(
          "VerifierRunner cleanup failed primary=" <>
            outcome_diagnostic(primary) <>
            " cleanup=" <> outcome_diagnostic(cleanup)
        )

        restore_outcome(primary)

      true ->
        restore_outcome(cleanup)
    end
  end

  defp stopped_cleanup?({:returned, {:stop, {:execution_stopped, _}}}), do: true
  defp stopped_cleanup?(_outcome), do: false
  defp retained_primary?({:raised, _, _, _}), do: true
  defp retained_primary?({:returned, {:stop, _}}), do: true
  defp retained_primary?({:returned, {:error, _}}), do: true
  defp retained_primary?(_outcome), do: false
  defp restore_outcome({:returned, value}), do: value
  defp restore_outcome({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  defp outcome_diagnostic({:raised, kind, reason, stacktrace}), do: Exception.format(kind, reason, stacktrace)

  defp outcome_diagnostic({:returned, {:stop, {:stale_execution, _ids, cause}}}),
    do: "stale_execution: " <> inspect(cause, limit: 8, printable_limit: 512)

  defp outcome_diagnostic({:returned, {:stop, {tag, cause}}}) when tag in [:accounting_uncertain, :execution_stopped],
    do: Atom.to_string(tag) <> ": " <> inspect(cause, limit: 8, printable_limit: 512)

  defp outcome_diagnostic({:returned, {:stop, reason}}), do: "stop: " <> inspect(reason, limit: 8, printable_limit: 512)

  defp outcome_diagnostic({:returned, {:error, {:workspace_hook_failed, hook, status, _output}}}),
    do: "workspace_hook_failed: hook=#{hook} status=#{status}"

  defp outcome_diagnostic({:returned, {:error, reason}}), do: "error: " <> inspect(reason, limit: 8, printable_limit: 512)
  defp outcome_diagnostic({:returned, _value}), do: "returned"

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

  defp evidence_selection(workspace, inspection, opts) do
    if Keyword.get(opts, :evidence_reentry, false) do
      with {:ok, scope} <- RunInspector.evidence_scope_checked(workspace, inspection.harness, opts),
           do: {:ok, scope.paths, scope}
    else
      with {:ok, paths} <- RunInspector.changed_paths_checked(workspace, opts), do: {:ok, paths, nil}
    end
  end

  defp verification_context(workspace, issue, inspection, state, acceptance, smoke_result, changed_files, scope, opts) do
    with {:ok, behavioral_proof} <- current_step(workspace, issue, fn -> BehavioralProof.evaluate(workspace, inspection.harness, changed_files) end),
         {:ok, diff_summary} <- current_step(workspace, issue, fn -> RunInspector.diff_summary(workspace, opts) end),
         {:ok, content_evidence} <- current_step(workspace, issue, fn -> changed_file_content_evidence(workspace, changed_files, behavioral_proof) end),
         {:ok, ui_proof} <- current_step(workspace, issue, fn -> UiProof.evaluate(workspace, inspection.harness, changed_files, inspection, opts) end),
         {:ok, evidence_handle, proof_contents} <- begin_current_observation(workspace, behavioral_proof, smoke_result, ui_proof, scope) do
      {:ok,
       %{
         acceptance: IssueAcceptance.to_prompt_map(acceptance),
         changed_files: changed_files,
         diff_summary: diff_summary,
         content_evidence: proof_contents ++ Enum.reject(content_evidence, fn entry -> Enum.any?(proof_contents, &(&1.path == entry.path)) end),
         evidence_handle: evidence_handle,
         smoke_result: smoke_result,
         validation_output: get_in(state, [:last_validation, :output]),
         behavioral_proof: behavioral_proof,
         ui_proof: ui_proof
       }}
    end
  end

  defp begin_current_observation(_workspace, _selection, %{status: status}, _ui, _scope) when status != :passed, do: {:ok, nil, []}
  defp begin_current_observation(_workspace, %{satisfied?: false}, _gate, _ui, _scope), do: {:ok, nil, []}

  defp begin_current_observation(_workspace, _selection, _gate, %{verify_required?: true, verify_satisfied?: false}, _scope), do: {:ok, nil, []}

  defp begin_current_observation(workspace, selection, gate, _ui, scope) do
    case AgentExecution.current_context() do
      {:ok, _context} ->
        with {:ok, handle, contents} <- EvidenceAcceptance.begin_observation(workspace, selection, gate, Config.policy_require_validation?(), scope) do
          # These excerpts come from the exact buffers hashed by the observer.
          {:ok, handle, contents |> SecretRedactor.redact() |> Enum.map(&Map.update!(&1, :excerpt, fn bytes -> doc_content_excerpt(bytes) end))}
        end

      {:error, :execution_context_missing} ->
        {:ok, nil, []}
    end
  end

  defp accept_current_observation(%{verdict: "pass", acceptance_gaps: [_ | _]}, _context, _mode),
    do: integrity_blocked(:verifier_pass_with_acceptance_gaps)

  defp accept_current_observation(%{verdict: "pass", acceptance_gaps: []} = result, %{evidence_handle: handle}, mode) when is_reference(handle) do
    case EvidenceAcceptance.accept(handle, Map.put(result, :verification_mode, mode)) do
      :ok -> result
      {:error, reason} -> integrity_blocked(reason)
      {:stop, _} = terminal -> terminal
    end
  end

  defp accept_current_observation(%{verdict: verdict} = result, %{evidence_handle: handle}, _mode) when is_reference(handle) and verdict != "pass" do
    case EvidenceAcceptance.accept(handle, result) do
      :ok -> result
      {:error, reason} -> integrity_blocked(reason)
      {:stop, _} = terminal -> terminal
    end
  end

  defp accept_current_observation(result, _context, _mode), do: result

  defp gate_only_result(context) do
    %{
      verdict: "pass",
      summary: "The configured deterministic smoke and proof gates passed; the agent verifier is disabled by policy.",
      acceptance_gaps: [],
      risky_areas: [],
      evidence: ["Runtime smoke gate passed"],
      raw_output: nil,
      smoke: command_result_to_map(context.smoke_result),
      acceptance: context.acceptance,
      behavioral_proof: BehavioralProof.to_map(context.behavioral_proof),
      ui_proof: UiProof.to_map(context.ui_proof)
    }
  end

  defp integrity_blocked(reason) do
    %{
      verdict: "blocked",
      reason_code: "evidence_integrity_failed",
      summary: "Current verification evidence could not be accepted: #{EvidenceAcceptance.failure_code(reason)}.",
      acceptance_gaps: [],
      risky_areas: [],
      evidence: [],
      raw_output: nil,
      integrity_error: reason
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
  @spec format_command_output_excerpt(term()) :: String.t()
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

  defp changed_file_content_evidence(workspace, changed_files, behavioral_proof) do
    (behavioral_proof.behavior_paths ++ behavioral_proof.proof_paths ++ Enum.filter(changed_files, &doc_like_path?/1))
    |> Enum.uniq()
    |> Enum.take(4)
    |> Enum.map(&content_evidence_entry(workspace, &1))
    |> SecretRedactor.redact()
    |> Enum.map(&Map.update!(&1, :excerpt, fn contents -> doc_content_excerpt(contents) end))
  end

  defp content_evidence_entry(workspace, path) do
    with {:ok, file} <- confined_content_file(workspace, path),
         {:ok, contents} <- File.read(file),
         true <- String.valid?(contents) and not String.contains?(contents, <<0>>) do
      %{path: path, excerpt: contents}
    else
      false -> %{path: path, excerpt: "[Content omitted: binary or invalid UTF-8 text]"}
      {:error, reason} -> %{path: path, excerpt: "[Content omitted: #{inspect(reason)}]"}
    end
  end

  defp confined_content_file(workspace, path) do
    segments = Path.split(path)

    if Path.type(path) != :relative or segments == [] or Enum.any?(segments, &(&1 in [".", ".."])) do
      {:error, :unsafe_path}
    else
      Enum.reduce_while(segments, {:ok, Path.expand(workspace)}, fn segment, {:ok, current} ->
        next = Path.join(current, segment)

        case File.lstat(next) do
          {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_path}}
          {:ok, %File.Stat{type: type}} when type in [:regular, :directory] -> {:cont, {:ok, next}}
          {:ok, _stat} -> {:halt, {:error, :unsupported_file_type}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
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
