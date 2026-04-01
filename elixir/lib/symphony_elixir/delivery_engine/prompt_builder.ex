defmodule SymphonyElixir.DeliveryEngine.PromptBuilder do
  @moduledoc """
  Builds agent prompts for delivery engine stages (plan, implement).

  Extracted from `SymphonyElixir.DeliveryEngine` — functions take issue/state/workspace
  data and return prompt strings or resume-context maps. Some functions read workspace
  state (e.g. dirty files, diff summary) as part of building resume context.
  """

  # credo:disable-for-this-file

  alias SymphonyElixir.AgentHarness
  alias SymphonyElixir.IssueAcceptance
  alias SymphonyElixir.RepoMap
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.WorkflowProfile

  # ---------------------------------------------------------------------------
  # Plan prompt
  # ---------------------------------------------------------------------------

  @spec plan_prompt(map(), term(), String.t()) :: String.t()
  def plan_prompt(issue, _state, workspace) do
    acceptance = IssueAcceptance.from_issue(issue)

    acceptance_text =
      case acceptance.criteria do
        [] -> "- #{acceptance.summary}"
        criteria -> Enum.map_join(criteria, "\n", &"- #{&1}")
      end

    progress_path =
      case AgentHarness.progress_file_path(workspace, issue) do
        {:ok, path} -> Path.relative_to(path, workspace)
        _ -> ".symphony/progress/#{issue.identifier}.md"
      end

    """
    #{SymphonyElixir.PromptBuilder.build_prompt(issue)}

    You are running a PLANNING turn. You must:

    1. READ the issue description above carefully — it specifies exactly which files to change and what to do.
    2. READ every source file mentioned in the issue description. If the description mentions `delivery_engine.ex`, open it and read the relevant functions. Do the same for every file referenced.
    3. WRITE a progress file at `#{progress_path}` with a DETAILED implementation plan.

    The progress file MUST contain these exact Markdown H2 sections with REAL content (not placeholders):

    ## Goal
    One sentence: what this ticket achieves.

    ## Acceptance
    #{acceptance_text}

    ## Plan
    A numbered list where EACH step names:
    - The exact file path (e.g., `elixir/lib/symphony_elixir/delivery_engine.ex`)
    - The exact function to modify or add
    - What the change does, with enough detail that another developer could implement it

    ## Work Log
    - Read the codebase and wrote the implementation plan.

    ## Evidence
    - List the files you read and what you learned from each.

    ## Next Step
    The first specific action: which file to open, which function to edit, what to add.

    IMPORTANT:
    - Do NOT write placeholder text like "Outline steps here" — write the ACTUAL plan.
    - Do NOT modify source code in this turn — only write the progress file.
    - You MUST read the relevant source files before writing the plan. A plan without reading code is useless.
    - Spend most of your turn reading files. The plan should reflect what you actually found in the code.
    """
  end

  # ---------------------------------------------------------------------------
  # Implement prompt
  # ---------------------------------------------------------------------------

  @spec implement_prompt(map(), map(), String.t(), map(), term(), non_neg_integer(), non_neg_integer()) :: String.t()
  def implement_prompt(issue, state, workspace, inspection, _opts, turn_number, max_turns) do
    acceptance = IssueAcceptance.from_issue(issue)
    resume_context = resume_context_for_prompt(workspace, issue, state, inspection)
    token_pressure = token_pressure_note(resume_context)
    repo_map = RepoMap.from_harness(inspection.harness)
    workflow_profile = WorkflowProfile.resolve(Map.get(state, :effective_policy_class))

    focused_review_claims =
      SymphonyElixir.DeliveryEngine.focused_review_claims(
        Map.get(state, :review_claims, %{}),
        SymphonyElixir.DeliveryEngine.focused_review_claim_limit(state)
      )

    prompt_lines =
      cond do
        review_fix_budget_mode?(resume_context) ->
          [
            "You are implementing ticket `#{issue.identifier}`.",
            "",
            "Title: #{to_string(issue.title || "Untitled issue")}",
            repo_platform_note(inspection),
            "Current implementation turn: #{turn_number} of #{max_turns}.",
            "",
            "This is a scoped review-fix turn. Do not rediscover the issue or rescan the repo.",
            "Resolved workflow profile: #{WorkflowProfile.name_string(workflow_profile)} (merge mode #{workflow_profile.merge_mode}).",
            maybe_named_line("PR under review", Map.get(state, :pr_url), 200),
            "",
            "Review-fix rules:",
            "- Touch only the files directly related to the current scope ids unless a directly adjacent helper must change to make the fix compile.",
            "- Do not rescan unrelated files, docs, or tests.",
            "- Do not run full validation, smoke, build, or test commands during `implement`.",
            "- Limit shell usage to narrow reads of the target files and minimal diff/status checks.",
            "- Keep command output small. Do not stream long logs or dump large files into the turn.",
            "- If you complete this scope but additional verified review claims or failed checks remain, set `needs_another_turn=true`.",
            "- Focus on writing code. Symphony will track your changes automatically.",
            "",
            "Resume context:",
            resume_context_block(resume_context),
            token_pressure,
            "",
            "Exact next objective:",
            review_fix_next_objective(resume_context) ||
              resume_context[:next_objective] ||
              "Advance the current diff toward validation with the smallest complete code change set possible."
          ]

        focused_review_claims == [] ->
          [
            "You are implementing ticket `#{issue.identifier}`.",
            "",
            "Title: #{to_string(issue.title || "Untitled issue")}",
            repo_platform_note(inspection),
            "Current implementation turn: #{turn_number} of #{max_turns}.",
            "",
            "Issue brief:",
            summarized_text(issue.description || "No description provided.", 2_500),
            "",
            "Resolved workflow profile: #{WorkflowProfile.name_string(workflow_profile)} (merge mode #{workflow_profile.merge_mode}).",
            "",
            RepoMap.prompt_block(repo_map),
            "",
            "Acceptance summary:",
            summarized_text(acceptance.summary, 1_200),
            maybe_acceptance_criteria_block(acceptance.criteria, resume_context),
            "",
            "Runtime-owned delivery rules:",
            "- Symphony owns git branch creation, commit, push, PR publication, CI waiting, merge, and post-merge closure.",
            "- Your job is limited to code changes in the checked out repo and reporting the structured turn result.",
            "- Do not create commits, push branches, open PRs, merge PRs, or change issue states yourself.",
            "- Do not run full validation, smoke, build, or test commands during `implement`.",
            "- Do not run heavyweight commands such as `xcodebuild`, `make all`, full test suites, or repo-wide validation scripts from this turn.",
            "- Do not inventory the entire repo or dump full diffs during `implement`: avoid `rg --files`, `fd`, `find .`, and full `git diff`; use targeted file reads and `git diff --stat` only.",
            "- Limit shell usage to targeted inspection and editing support only: prefer `rg`, `sed -n`, narrow file reads, and small `git status` or `git diff --stat` commands.",
            "- Keep command output small. Do not stream long logs or dump large files into the turn.",
            "- Focus on writing code. Symphony will track your changes automatically.",
            "- `files_touched` must list every path you changed this turn.",
            "- Set `blocked=true` only for a true blocker you cannot resolve from the repo or local environment.",
            "- Set `needs_another_turn=true` only when more implementation work is still required after this turn.",
            "",
            "Resume context:",
            resume_context_block(resume_context),
            token_pressure,
            "",
            "Exact next objective:",
            resume_context[:next_objective] ||
              "Advance the current diff toward validation with the smallest complete code change set possible."
          ]

        true ->
          [
            "You are implementing ticket `#{issue.identifier}`.",
            "",
            "Title: #{to_string(issue.title || "Untitled issue")}",
            repo_platform_note(inspection),
            "Current implementation turn: #{turn_number} of #{max_turns}.",
            "",
            "This is a scoped review-fix turn. Do not rediscover the issue or rescan the repo.",
            "Resolved workflow profile: #{WorkflowProfile.name_string(workflow_profile)} (merge mode #{workflow_profile.merge_mode}).",
            maybe_named_line("PR under review", Map.get(state, :pr_url), 200),
            "",
            "Scoped review claims for this turn:",
            SymphonyElixir.DeliveryEngine.focused_review_claim_block(focused_review_claims, Map.get(state, :review_claims, %{})),
            token_pressure,
            "",
            "Review-fix rules:",
            "- Touch only the files named in the scoped review claims unless a directly adjacent helper must change to make the fix compile.",
            "- Do not rescan unrelated files, docs, or tests.",
            "- Do not run full validation, smoke, build, or test commands during `implement`.",
            "- Limit shell usage to narrow reads of the listed files and minimal diff/status checks.",
            "- Keep command output small. Do not stream long logs or dump large files into the turn.",
            "- If you complete this claim batch but additional verified review claims remain, set `needs_another_turn=true`.",
            "- Focus on writing code. Symphony will track your changes automatically.",
            "",
            "Resume context:",
            focused_resume_context_block(resume_context),
            "",
            "Exact next objective:",
            SymphonyElixir.DeliveryEngine.focused_review_next_objective(
              focused_review_claims,
              Map.get(state, :review_claims, %{})
            )
          ]
      end

    prompt_lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Acceptance criteria
  # ---------------------------------------------------------------------------

  @spec maybe_acceptance_criteria_block(list(), map()) :: String.t() | nil
  def maybe_acceptance_criteria_block([], _resume_context), do: nil

  def maybe_acceptance_criteria_block(criteria, resume_context) when is_list(criteria) do
    criteria =
      criteria
      |> Enum.take(8)
      |> Enum.map(&("- " <> summarized_text(&1, 200)))

    diff_hint =
      case Map.get(resume_context, :dirty_files, []) do
        [] ->
          nil

        files ->
          "Current dirty files:\n" <> Enum.map_join(Enum.take(files, 20), "\n", &("- " <> &1))
      end

    [Enum.join(criteria, "\n"), diff_hint]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Resume context construction
  # ---------------------------------------------------------------------------

  @spec resume_context_for_prompt(String.t(), map(), map(), map()) :: map()
  def resume_context_for_prompt(workspace, issue, state, inspection) do
    stored =
      case Map.get(state, :resume_context) do
        context when is_map(context) -> normalize_resume_context(context)
        _ -> %{}
      end

    if resume_context_stale?(stored, inspection) do
      Map.merge(
        fresh_resume_context(workspace, issue, state, inspection, %{}),
        preserved_resume_context(stored)
        |> Map.merge(carry_forward_review_fix_budget_context(stored))
      )
    else
      Map.merge(fresh_resume_context(workspace, issue, state, inspection, %{}), stored)
    end
  end

  @spec resume_context_stale?(map(), map()) :: boolean()
  def resume_context_stale?(context, inspection) when is_map(context) do
    Map.get(context, :fingerprint) != inspection.fingerprint
  end

  @spec fresh_resume_context(String.t(), map(), map(), map(), map()) :: map()
  def fresh_resume_context(workspace, issue, state, inspection, overrides) do
    target_stage = Map.get(overrides, :target_stage) || Map.get(state, :stage) || "implement"
    stored_resume_context = normalize_resume_context(Map.get(state, :resume_context, %{}))

    focused_review_claims =
      SymphonyElixir.DeliveryEngine.focused_review_claims(
        Map.get(state, :review_claims, %{}),
        SymphonyElixir.DeliveryEngine.focused_review_claim_limit(state)
      )

    review_fix_context = review_fix_resume_context(state, stored_resume_context, target_stage)
    review_fix_progress_delta = Map.get(overrides, :review_fix_progress_delta, 0)

    %{
      issue_identifier: issue.identifier,
      fingerprint: inspection.fingerprint,
      last_turn_summary: get_in(state, [:last_turn_result, :summary]),
      last_validation_summary: summarized_command_output(get_in(state, [:last_validation, :output]), 800),
      last_verifier_summary:
        summarized_text(
          get_in(state, [:last_verifier, :summary]) || get_in(state, [:last_verifier, :output]),
          800
        ),
      dirty_files: RunInspector.changed_paths(workspace) |> Enum.take(20),
      diff_summary: summarized_diff_summary(RunInspector.diff_summary(workspace), 30),
      last_blocking_rule: get_in(state, [:stop_reason, :code]) || Map.get(state, :last_rule_id),
      review_feedback_summary:
        Map.get(overrides, :review_feedback_summary) ||
          SymphonyElixir.DeliveryEngine.default_review_feedback_summary(state, focused_review_claims),
      review_claim_summary:
        Map.get(overrides, :review_claim_summary) ||
          SymphonyElixir.DeliveryEngine.default_review_claim_summary(state, focused_review_claims),
      next_objective:
        Map.get(overrides, :next_objective) ||
          SymphonyElixir.DeliveryEngine.default_next_objective(state, focused_review_claims)
    }
    |> Map.merge(review_fix_context)
    |> maybe_increment_review_fix_progress(review_fix_progress_delta)
    |> Map.merge(Enum.into(overrides, %{}))
    |> Map.drop([:target_stage, :review_fix_progress_delta])
  end

  @spec preserved_resume_context(map()) :: map()
  def preserved_resume_context(context) when is_map(context) do
    context
    |> Map.take([
      :next_objective,
      :review_feedback_summary,
      :review_claim_summary,
      :review_feedback_pr_url,
      :token_pressure,
      :review_fix_budget_retry_count,
      :implementation_turn_window_base
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec repo_platform_note(map()) :: String.t() | nil
  def repo_platform_note(%{harness: %{project: %{type: type}}}) when is_binary(type) do
    normalized = String.trim(type)

    cond do
      normalized == "" ->
        nil

      normalized == "ios-app" ->
        "Repo platform: iOS app (SwiftUI/Xcode). Ignore unrelated web or JavaScript framework guidance such as Vue, React, or Next.js."

      true ->
        "Repo platform: #{normalized}. Ignore unrelated framework guidance that does not match this repo."
    end
  end

  def repo_platform_note(_inspection), do: nil

  @spec resume_context_attrs(String.t(), map(), map(), map(), map(), keyword()) :: map()
  def resume_context_attrs(workspace, issue, state, inspection, overrides, _opts) do
    %{resume_context: refreshed_resume_context(workspace, issue, state, inspection, overrides)}
  end

  @spec refreshed_resume_context(String.t(), map(), map(), map(), map()) :: map()
  def refreshed_resume_context(workspace, issue, state, inspection, overrides) do
    preserved =
      state
      |> Map.get(:resume_context, %{})
      |> preserved_resume_context()

    fresh_resume_context(workspace, issue, state, inspection, overrides)
    |> Map.merge(preserved)
  end

  @spec resume_context_block(map()) :: String.t()
  def resume_context_block(resume_context) when is_map(resume_context) do
    lines =
      if review_fix_budget_mode?(resume_context) do
        [
          "Scoped review-fix lane: active",
          maybe_named_line("Budget pressure", resume_context[:budget_pressure_level], 40),
          maybe_named_line("Budget retry count", resume_context[:budget_retry_count], 20),
          maybe_named_line("Scope kind", resume_context[:budget_scope_kind], 60),
          maybe_named_list("Scope ids", resume_context[:budget_scope_ids], 8),
          maybe_named_line("Last implementation summary", resume_context[:last_turn_summary], 280),
          maybe_named_line("Latest validation summary", resume_context[:last_validation_summary], 400),
          maybe_named_line("Latest verifier summary", resume_context[:last_verifier_summary], 400),
          maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200),
          maybe_named_list("Dirty files", Enum.take(Map.get(resume_context, :dirty_files, []), 8), 8)
        ]
      else
        [
          maybe_named_line("Last implementation summary", resume_context[:last_turn_summary], 400),
          maybe_named_line(
            "Latest validation summary",
            resume_context[:last_validation_summary],
            800
          ),
          maybe_named_line("Latest verifier summary", resume_context[:last_verifier_summary], 800),
          maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200),
          maybe_named_multiline(
            "Pending PR review feedback",
            resume_context[:review_feedback_summary]
          ),
          maybe_named_multiline("Pending PR review claims", resume_context[:review_claim_summary]),
          maybe_named_list("Dirty files", resume_context[:dirty_files], 20),
          maybe_named_multiline("Diff stat", resume_context[:diff_summary])
        ]
      end

    lines
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No prior resume context recorded."
      lines -> Enum.join(lines, "\n")
    end
  end

  @spec focused_resume_context_block(map()) :: String.t()
  def focused_resume_context_block(resume_context) when is_map(resume_context) do
    lines =
      if review_fix_budget_mode?(resume_context) do
        [
          "Scoped review-fix lane: active",
          maybe_named_line("Budget pressure", resume_context[:budget_pressure_level], 40),
          maybe_named_line("Budget retry count", resume_context[:budget_retry_count], 20),
          maybe_named_line("Scope kind", resume_context[:budget_scope_kind], 60),
          maybe_named_list("Scope ids", resume_context[:budget_scope_ids], 8),
          maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200)
        ]
      else
        [
          maybe_named_line("Last blocking rule", resume_context[:last_blocking_rule], 200)
        ]
      end

    lines
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No focused review context recorded."
      lines -> Enum.join(lines, "\n")
    end
  end

  @spec token_pressure_note(map()) :: String.t() | nil
  def token_pressure_note(resume_context) when is_map(resume_context) do
    cond do
      review_fix_budget_mode?(resume_context) and Map.get(resume_context, :budget_pressure_level) in ["soft", "high", "critical"] ->
        "\nScoped review-fix token pressure is active. Keep the turn limited to the current scope ids, avoid diff summaries, and do not restate old evidence."

      Map.get(resume_context, :token_pressure) == "high" ->
        "\nToken pressure is high. Keep reads narrow, avoid repeated scans, and do not reprint prior evidence."

      true ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Review-fix budget context
  # ---------------------------------------------------------------------------

  @spec review_fix_next_objective(map()) :: String.t() | nil
  def review_fix_next_objective(resume_context) when is_map(resume_context) do
    if review_fix_budget_mode?(resume_context) do
      scope_kind = Map.get(resume_context, :budget_scope_kind, "review_claim_batch")
      scope_ids = Map.get(resume_context, :budget_scope_ids, []) |> Enum.map(&to_string/1)

      if scope_ids == [] do
        nil
      else
        "Address the scoped #{scope_kind} items only: #{Enum.join(scope_ids, ", ")}."
      end
    end
  end

  @spec review_fix_resume_context(map(), map(), String.t()) :: map()
  def review_fix_resume_context(state, stored_resume_context, "implement") do
    cond do
      review_fix_budget_mode?(stored_resume_context) ->
        carry_forward_review_fix_budget_context(stored_resume_context)

      review_fix_scope_ids(state, "review_claim_batch") != [] ->
        initial_review_fix_resume_context(state, "review_claim_batch", review_fix_scope_ids(state, "review_claim_batch"))

      review_fix_scope_ids(state, "ci_failure_batch") != [] ->
        initial_review_fix_resume_context(state, "ci_failure_batch", review_fix_scope_ids(state, "ci_failure_batch"))

      true ->
        %{}
    end
  end

  def review_fix_resume_context(_state, _stored_resume_context, _target_stage), do: %{}

  @spec initial_review_fix_resume_context(map(), String.t(), list()) :: map()
  def initial_review_fix_resume_context(state, scope_kind, scope_ids) do
    %{
      budget_mode: "review_fix",
      budget_pressure_level: "normal",
      budget_retry_count: 0,
      budget_window_base_turn: Map.get(state, :implementation_turns, 0) + 1,
      budget_last_stop_code: nil,
      budget_last_observed_input_tokens: nil,
      budget_scope_kind: scope_kind,
      budget_scope_ids: scope_ids,
      budget_progress_count: 0,
      budget_total_extension_used: false,
      budget_auto_narrowed: false
    }
  end

  @spec carry_forward_review_fix_budget_context(map()) :: map()
  def carry_forward_review_fix_budget_context(resume_context) do
    Map.take(resume_context, [
      :budget_mode,
      :budget_pressure_level,
      :budget_retry_count,
      :budget_window_base_turn,
      :budget_last_stop_code,
      :budget_last_observed_input_tokens,
      :budget_scope_kind,
      :budget_scope_ids,
      :budget_progress_count,
      :budget_total_extension_used,
      :budget_auto_narrowed,
      :token_pressure
    ])
  end

  @spec review_fix_scope_ids(map(), String.t()) :: list(String.t())
  def review_fix_scope_ids(state, "review_claim_batch") do
    state
    |> Map.get(:review_claims, %{})
    |> Enum.filter(fn {_thread_key, claim} -> SymphonyElixir.DeliveryEngine.claim_pending_review_fix?(claim) end)
    |> Enum.map(fn {thread_key, _claim} -> to_string(thread_key) end)
    |> Enum.sort()
  end

  def review_fix_scope_ids(state, "ci_failure_batch") do
    state
    |> Map.get(:last_failing_required_checks, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def review_fix_scope_ids(_state, _scope_kind), do: []

  @spec review_fix_budget_mode?(term()) :: boolean()
  def review_fix_budget_mode?(resume_context) when is_map(resume_context),
    do: Map.get(resume_context, :budget_mode) == "review_fix"

  def review_fix_budget_mode?(_resume_context), do: false

  @spec maybe_increment_review_fix_progress(map(), term()) :: map()
  def maybe_increment_review_fix_progress(resume_context, delta)
      when is_map(resume_context) and is_integer(delta) and delta > 0 do
    if review_fix_budget_mode?(resume_context) do
      Map.update(resume_context, :budget_progress_count, delta, &(&1 + delta))
    else
      resume_context
    end
  end

  def maybe_increment_review_fix_progress(resume_context, _delta), do: resume_context

  # ---------------------------------------------------------------------------
  # Normalize resume context
  # ---------------------------------------------------------------------------

  @spec normalize_resume_context(term()) :: map()
  def normalize_resume_context(context) when is_map(context) do
    context
    |> Enum.into(%{}, fn
      {key, value} when is_binary(key) ->
        case normalize_resume_context_key(key) do
          nil -> {key, value}
          atom_key -> {atom_key, value}
        end

      {key, value} ->
        {key, value}
    end)
  end

  def normalize_resume_context(_context), do: %{}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize_resume_context_key("budget_mode"), do: :budget_mode
  defp normalize_resume_context_key("budget_pressure_level"), do: :budget_pressure_level
  defp normalize_resume_context_key("budget_retry_count"), do: :budget_retry_count
  defp normalize_resume_context_key("budget_window_base_turn"), do: :budget_window_base_turn
  defp normalize_resume_context_key("budget_last_stop_code"), do: :budget_last_stop_code
  defp normalize_resume_context_key("budget_last_observed_input_tokens"), do: :budget_last_observed_input_tokens
  defp normalize_resume_context_key("budget_scope_kind"), do: :budget_scope_kind
  defp normalize_resume_context_key("budget_scope_ids"), do: :budget_scope_ids
  defp normalize_resume_context_key("budget_progress_count"), do: :budget_progress_count
  defp normalize_resume_context_key("budget_total_extension_used"), do: :budget_total_extension_used
  defp normalize_resume_context_key("budget_auto_narrowed"), do: :budget_auto_narrowed
  defp normalize_resume_context_key("token_pressure"), do: :token_pressure
  defp normalize_resume_context_key(_key), do: nil

  # Text formatting helpers (duplicated from DeliveryEngine to keep the module self-contained)

  defp maybe_named_line(_label, nil, _limit), do: nil

  defp maybe_named_line(label, value, limit) do
    "#{label}: #{summarized_text(value, limit)}"
  end

  defp maybe_named_multiline(_label, nil), do: nil
  defp maybe_named_multiline(label, value), do: "#{label}:\n#{value}"

  defp maybe_named_list(_label, [], _limit), do: nil

  defp maybe_named_list(label, values, limit) when is_list(values) do
    trimmed =
      values
      |> Enum.take(limit)
      |> Enum.map(&to_string/1)

    "#{label}:\n" <> Enum.map_join(trimmed, "\n", &("- " <> &1))
  end

  defp summarized_text(nil, _limit), do: nil

  defp summarized_text(value, limit) when is_integer(limit) and limit > 0 do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.slice(text, 0, limit)
    end
  end

  defp summarized_command_output(nil, _limit), do: nil

  defp summarized_command_output(output, limit) do
    output
    |> to_string()
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(12)
    |> Enum.join("\n")
    |> summarized_text(limit)
  end

  defp summarized_diff_summary(nil, _line_limit), do: nil

  defp summarized_diff_summary(summary, line_limit) do
    summary
    |> to_string()
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.take(line_limit)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end
end
