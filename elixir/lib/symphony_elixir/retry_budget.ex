defmodule SymphonyElixir.RetryBudget do
  @moduledoc """
  Retry budget calculations shared by policy evaluation and delivery continuation.

  Calculations do not acquire execution authority, persist state or schedule work.
  Durable resume keys and the distinct adaptive and historical turn windows retain
  their existing meanings.
  """

  alias SymphonyElixir.DeliveryEngine.ReviewClaims
  alias SymphonyElixir.RetryBudget.Focus
  alias SymphonyElixir.{Config, RunLedger, RunStateStore, Workspace}

  @review_fix_max_turns 6

  @type delivery_context :: %{
          stored_resume: map(),
          budget_context: map(),
          stale_budget_context: map()
        }

  @type delivery_limit_request ::
          :implementation_turns
          | :focused_claim_limit
          | :command_output_budget
          | {:max_turns, integer()}

  defmodule Observation do
    @moduledoc false
    @enforce_keys [:source, :issue, :entry, :state, :workspace, :issue_usage, :token_budget, :review_fix_budget, :broad_budget]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            source: :checked | :legacy,
            issue: map(),
            entry: map(),
            state: map(),
            workspace: Path.t() | nil,
            issue_usage: map() | nil,
            token_budget: map(),
            review_fix_budget: map(),
            broad_budget: map()
          }
    @type text_fact :: %{
            fragments: [String.t()],
            summary: :empty | :unsupported | {:binary, String.t()} | {:structured, [String.t()]} | {:scalar, atom() | number()}
          }

    @spec text_facts(term()) :: text_fact()
    def text_facts(nil), do: %{fragments: [], summary: :empty}
    def text_facts(value) when is_binary(value), do: %{fragments: [value], summary: {:binary, value}}

    def text_facts(value) when is_map(value) or is_list(value) do
      fragments = text_fragments(value)
      %{fragments: fragments, summary: {:structured, fragments}}
    end

    def text_facts(value) when is_atom(value) or is_number(value),
      do: %{fragments: [], summary: {:scalar, value}}

    def text_facts(_value), do: %{fragments: [], summary: :unsupported}

    defp text_fragments(value) when is_binary(value), do: [value]
    defp text_fragments(value) when is_list(value), do: Enum.flat_map(value, &text_fragments/1)

    defp text_fragments(value) when is_map(value) do
      preferred =
        [:text, "text", :message, "message", :payload, "payload", :raw, "raw", :content, "content"]
        |> Enum.flat_map(fn key ->
          case Map.fetch(value, key) do
            {:ok, nested} -> text_fragments(nested)
            :error -> []
          end
        end)

      if preferred != [] do
        preferred
      else
        value |> Map.values() |> Enum.flat_map(&text_fragments/1)
      end
    end

    defp text_fragments(_value), do: []
  end

  defmodule PolicyView do
    @moduledoc false
    @enforce_keys [
      :source,
      :mode,
      :issue,
      :entry,
      :workspace,
      :initial_state,
      :initial_resume,
      :stage,
      :stage_budget,
      :total_budget,
      :token_budget,
      :review_fix_budget,
      :broad_budget,
      :current_turn_input,
      :issue_usage
    ]
    defstruct @enforce_keys ++ [adaptive_budget: nil, soft_pressure: nil]

    @type t :: %__MODULE__{
            source: :checked | :legacy,
            mode: :scoped_review_fix | :generic,
            issue: map(),
            entry: map(),
            workspace: Path.t() | nil,
            initial_state: map(),
            initial_resume: map(),
            stage: String.t() | nil,
            stage_budget: map(),
            total_budget: integer() | nil,
            token_budget: map(),
            review_fix_budget: map(),
            broad_budget: map(),
            current_turn_input: integer(),
            issue_usage: map(),
            adaptive_budget: map() | nil,
            soft_pressure: map() | nil
          }
  end

  defmodule Stop do
    @moduledoc false
    @enforce_keys [:kind, :observed, :metadata]
    defstruct @enforce_keys

    @type kind ::
            :per_turn_input
            | :per_issue_total
            | :per_issue_total_output
            | :review_fix_total_extension_exhausted
            | :review_fix_turn_window_exhausted
            | :review_fix_scope_exhausted
            | :broad_implement_focus_insufficient
            | :broad_implement_expansion_exhausted
            | :broad_implement_scope_exhausted
    @type t :: %__MODULE__{kind: kind(), observed: integer(), metadata: map()}
  end

  defmodule Decision do
    @moduledoc false
    @enforce_keys [:result]
    defstruct [:resume_context | @enforce_keys]

    @type t :: %__MODULE__{
            resume_context: map() | nil,
            result: :ok | {:retry, map()} | {:stop, SymphonyElixir.RetryBudget.Stop.t()}
          }
  end

  @spec decide(PolicyView.t(), map()) :: Decision.t()
  def decide(%PolicyView{mode: :scoped_review_fix} = view, state) do
    resume =
      if view.source == :legacy,
        do: view.initial_resume,
        else: observation_resume(state, view.entry, :checked)

    cond do
      budget_exceeded?(
        effective_review_fix_total_budget(view.token_budget, view.review_fix_budget, resume),
        view.issue_usage.total_tokens
      ) ->
        scoped_total_stop(view, resume)

      budget_exceeded?(view.token_budget[:per_issue_total_output], view.issue_usage.output_tokens) ->
        stop_decision(:per_issue_total_output, view.issue_usage.output_tokens)

      budget_exceeded?(view.adaptive_budget.per_turn_input_hard, view.current_turn_input) ->
        scoped_turn_stop(view, resume)

      true ->
        scoped_total_extension(view, resume)
    end
  end

  def decide(%PolicyView{mode: :generic} = view, state) do
    resume = observation_resume(state, view.entry, view.source)
    admission = broad_implement_admission_state(view.issue, view.entry, resume, view.broad_budget, view.stage, view.stage_budget, view.current_turn_input, view.workspace, state)

    if admission.enter_retry_lane? and admission.budget_exceeded? do
      view
      |> broad_turn_stop(resume, admission)
      |> enforce_accumulated_totals(view)
    else
      generic_decision(view, resume, admission)
    end
  end

  defp scoped_total_stop(view, resume) do
    base = view.token_budget[:per_issue_total]
    extension = view.review_fix_budget[:per_issue_total_extension]

    if SymphonyElixir.Util.truthy?(Map.get(resume, :budget_total_extension_used)) and
         is_integer(base) and is_integer(extension) do
      metadata = review_fix_budget_metadata(view.entry, resume, %{base_budget: base, extension_budget: extension})
      next_resume = review_fix_resume_context_for_budget_retry(resume, view.entry, "budget.review_fix_total_extension_exhausted", view.issue_usage.total_tokens, %{budget_pressure_level: "critical"})
      stop_decision(:review_fix_total_extension_exhausted, view.issue_usage.total_tokens, metadata, next_resume)
    else
      stop_decision(:per_issue_total, view.issue_usage.total_tokens)
    end
  end

  defp scoped_total_extension(view, resume) do
    base = view.token_budget[:per_issue_total]
    extension = view.review_fix_budget[:per_issue_total_extension]
    total = view.issue_usage.total_tokens

    cond do
      not is_integer(base) ->
        %Decision{result: :ok}

      not is_integer(extension) ->
        %Decision{result: :ok}

      total <= base ->
        %Decision{result: :ok}

      SymphonyElixir.Util.truthy?(Map.get(resume, :budget_total_extension_used)) ->
        %Decision{result: :ok}

      not review_fix_total_extension_eligible?(resume, extension) ->
        stop_decision(:per_issue_total, total)

      true ->
        next_resume =
          review_fix_resume_context_for_budget_retry(resume, view.entry, "budget.review_fix_total_extension_activated", total, %{budget_total_extension_used: true, budget_pressure_level: "critical"})

        %Decision{resume_context: next_resume, result: :ok}
    end
  end

  defp scoped_turn_stop(view, resume) do
    count = review_fix_retry_count(resume)
    can_retry? = count < (view.review_fix_budget[:auto_retry_limit] || 0)
    turns = review_fix_turns_in_window(view.entry, resume)
    ids = normalize_scope_ids(Map.get(resume, :budget_scope_ids))
    narrowed = narrow_review_fix_scope_ids(resume, view.adaptive_budget.narrow_scope_batch_size)
    can_narrow? = narrowed != ids

    next_resume =
      review_fix_resume_context_for_budget_retry(resume, view.entry, "budget.per_turn_input_exceeded", view.current_turn_input, %{
        budget_retry_count: count + 1,
        budget_pressure_level: review_fix_pressure_level_for_retry(count + 1),
        budget_scope_ids: narrowed,
        budget_auto_narrowed: can_narrow?
      })

    cond do
      can_retry? and turns < view.adaptive_budget.max_turns_in_window and
          review_fix_retry_continues?(count, can_narrow?) ->
        %Decision{
          resume_context: next_resume,
          result:
            {:retry,
             %{
               kind: :review_fix_budget_retry,
               summary: "Adaptive review-fix retry scheduled after token budget pressure.",
               resume_context: next_resume,
               observed_input_tokens: view.current_turn_input,
               retry_count: count + 1,
               max_turns_in_window: view.adaptive_budget.max_turns_in_window
             }}
        }

      turns >= view.adaptive_budget.max_turns_in_window ->
        metadata = review_fix_budget_metadata(view.entry, next_resume, %{turns_in_window: turns})
        stop_decision(:review_fix_turn_window_exhausted, view.current_turn_input, metadata, next_resume)

      true ->
        metadata = review_fix_budget_metadata(view.entry, next_resume, %{})
        stop_decision(:review_fix_scope_exhausted, view.current_turn_input, metadata, next_resume)
    end
  end

  defp generic_decision(view, resume, admission) do
    cond do
      budget_exceeded?(
        view.stage_budget[:per_turn_input_hard] || view.token_budget[:per_turn_input],
        view.current_turn_input
      ) ->
        next_resume = generic_budget_resume_context_for_stop(resume, admission, view.current_turn_input)

        metadata = %{
          budget_admission_reason: admission.admission_reason,
          resume_context: next_resume,
          target_paths: Map.get(next_resume, :target_paths, []),
          next_required_path: Map.get(next_resume, :next_required_path),
          budget_expansion_used: SymphonyElixir.Util.truthy?(Map.get(next_resume, :budget_expansion_used))
        }

        # Generic hard stops carry resume in the Violation; they do not add a resume write.
        stop_decision(:per_turn_input, view.current_turn_input, metadata)

      budget_exceeded?(view.total_budget, view.issue_usage.total_tokens) ->
        stop_decision(:per_issue_total, view.issue_usage.total_tokens)

      budget_exceeded?(view.token_budget[:per_issue_total_output], view.issue_usage.output_tokens) ->
        stop_decision(:per_issue_total_output, view.issue_usage.output_tokens)

      true ->
        %Decision{result: :ok}
    end
  end

  defp broad_turn_stop(view, resume, admission) do
    count = broad_implement_retry_count(resume)
    can_retry? = count < (view.broad_budget[:auto_retry_limit] || 0)
    primary = admission.primary_target_path || Focus.primary_path(view.entry, resume)
    expanded? = SymphonyElixir.Util.truthy?(Map.get(resume, :budget_expansion_used))
    next = Focus.next_path(view.entry, resume, primary)

    cond do
      count == 0 and can_retry? and is_binary(primary) ->
        broad_retry(view, resume, admission, count, [primary], nil, false, :broad_implement_budget_retry, "Adaptive broad-implement retry scheduled with one focused file.")

      count >= 1 and not expanded? and is_binary(primary) and is_binary(next) ->
        broad_retry(view, resume, admission, count, [primary, next], next, true, :broad_implement_budget_expansion_retry, "Adaptive broad-implement retry scheduled with one explicit expansion file.")

      count >= 1 and not expanded? and is_binary(primary) ->
        broad_stop(view, resume, "budget.broad_implement_focus_insufficient", :broad_implement_focus_insufficient, %{
          budget_pressure_level: "critical",
          target_paths: [primary],
          next_required_path: next,
          budget_expansion_used: false,
          budget_admission_reason: admission.admission_reason
        })

      expanded? ->
        broad_stop(view, resume, "budget.broad_implement_expansion_exhausted", :broad_implement_expansion_exhausted, %{
          budget_pressure_level: "critical",
          next_required_path: next,
          budget_admission_reason: admission.admission_reason
        })

      true ->
        broad_stop(view, resume, "budget.broad_implement_scope_exhausted", :broad_implement_scope_exhausted, %{budget_pressure_level: "critical", budget_admission_reason: admission.admission_reason})
    end
  end

  defp broad_retry(view, resume, admission, count, paths, next, expanded?, kind, summary) do
    next_resume =
      broad_implement_resume_context_for_budget_retry(resume, view.entry, "budget.per_turn_input_exceeded", view.current_turn_input, %{
        budget_retry_count: count + 1,
        budget_pressure_level: broad_implement_pressure_level_for_retry(count + 1),
        budget_auto_narrowed: true,
        target_paths: paths,
        next_required_path: next,
        budget_expansion_used: expanded?,
        budget_admission_reason: admission.admission_reason
      })

    %Decision{
      resume_context: next_resume,
      result:
        {:retry,
         %{
           kind: kind,
           summary: summary,
           budget_mode: "broad_implement",
           resume_context: next_resume,
           observed_input_tokens: view.current_turn_input,
           retry_count: count + 1
         }}
    }
  end

  defp broad_stop(view, resume, code, kind, overrides) do
    next_resume = broad_implement_resume_context_for_budget_retry(resume, view.entry, code, view.current_turn_input, overrides)

    metadata =
      broad_implement_budget_metadata(view.entry, next_resume)
      |> Map.put(:resume_context, next_resume)

    stop_decision(kind, view.current_turn_input, metadata, next_resume)
  end

  defp enforce_accumulated_totals(%Decision{result: {:retry, _}} = decision, view) do
    cond do
      budget_exceeded?(view.total_budget, view.issue_usage.total_tokens) ->
        stop_decision(:per_issue_total, view.issue_usage.total_tokens, %{}, decision.resume_context)

      budget_exceeded?(view.token_budget[:per_issue_total_output], view.issue_usage.output_tokens) ->
        stop_decision(:per_issue_total_output, view.issue_usage.output_tokens, %{}, decision.resume_context)

      true ->
        decision
    end
  end

  defp enforce_accumulated_totals(%Decision{} = decision, _view), do: decision

  defp stop_decision(kind, observed, metadata \\ %{}, resume \\ nil) do
    %Decision{resume_context: resume, result: {:stop, %Stop{kind: kind, observed: observed, metadata: metadata}}}
  end

  @spec pressure(Observation.t()) :: PolicyView.t()
  def pressure(%Observation{issue_usage: issue_usage} = observation) when is_map(issue_usage) do
    issue = observation.issue
    entry = observation.entry
    state = observation.state
    workspace = observation.workspace
    stage_budget = observation_stage_budget(issue, entry, workspace, state, observation.source)
    total_budget = current_total_token_budget(observation.token_budget, issue, entry, state)
    input = current_turn_input_tokens(entry)
    resume = observation_resume(state, entry, observation.source)

    scoped? =
      case observation.source do
        :legacy ->
          review_fix_budget_mode?(entry, resume, observation.review_fix_budget)

        :checked ->
          stage = Map.get(entry, :stage) || Map.get(entry, :dispatch_stage) || Map.get(state, :stage, "checkout")

          Map.get(observation.review_fix_budget, :enabled, true) and
            stage == "implement" and Map.get(resume, :budget_mode) == "review_fix"
      end

    {stage, adaptive, soft} =
      if scoped? do
        adaptive = adaptive_review_fix_budget(observation.review_fix_budget, resume)
        {nil, adaptive, scoped_soft_pressure(entry, resume, input, adaptive)}
      else
        stage =
          Map.get(entry, :dispatch_stage) || Map.get(entry, :stage) ||
            observation_stage(issue, workspace, state, observation.source)

        {stage, nil, generic_soft_pressure(issue, entry, input, stage_budget, state)}
      end

    %PolicyView{
      source: observation.source,
      mode: if(scoped?, do: :scoped_review_fix, else: :generic),
      issue: issue,
      entry: entry,
      workspace: workspace,
      initial_state: state,
      initial_resume: resume,
      stage: stage,
      stage_budget: stage_budget,
      total_budget: total_budget,
      token_budget: observation.token_budget,
      review_fix_budget: observation.review_fix_budget,
      broad_budget: observation.broad_budget,
      current_turn_input: input,
      issue_usage: issue_usage,
      adaptive_budget: adaptive,
      soft_pressure: soft
    }
  end

  defp observation_resume(state, entry, :legacy), do: effective_resume_context(state, entry)

  defp observation_resume(state, _entry, :checked),
    do: normalize_resume_context(Map.get(state, :resume_context, %{}))

  defp observation_stage(issue, workspace, state, :legacy), do: current_stage(issue, workspace, state)
  defp observation_stage(_issue, _workspace, state, :checked), do: Map.get(state, :stage, "checkout")

  defp observation_stage_budget(issue, entry, workspace, state, :legacy),
    do: current_stage_token_budget(issue, entry, workspace, state)

  defp observation_stage_budget(issue, entry, workspace, state, :checked) do
    stage = Map.get(entry, :dispatch_stage) || Map.get(entry, :stage) || Map.get(state, :stage, "checkout")
    budget = Config.policy_stage_token_budget(stage)
    maybe_relax_review_fix_budget(if(is_map(budget), do: budget, else: %{}), issue, stage, workspace, state)
  end

  defp scoped_soft_pressure(entry, resume, input, adaptive) do
    if budget_exceeded?(adaptive.per_turn_input_soft, input) and
         Map.get(resume, :budget_pressure_level, "normal") == "normal" do
      %{
        resume_context: review_fix_resume_context_for_budget_retry(resume, entry, "budget.review_fix_soft_pressure", input, %{budget_pressure_level: "soft", token_pressure: "high"}),
        stage: Map.get(entry, :stage),
        observed: input,
        soft_budget: adaptive.per_turn_input_soft
      }
    end
  end

  defp generic_soft_pressure(issue, entry, input, stage_budget, state) do
    soft_budget = stage_budget[:per_turn_input_soft]

    if budget_exceeded?(soft_budget, input) do
      stage = Map.get(entry, :stage) || Map.get(state, :stage)
      identifier = issue_identifier_for(issue, state)
      count = review_fix_budget_retry_count(state, identifier)
      tracking? = review_fix_retry_tracking_candidate?(state, stage)
      needs_count? = tracking? and count == 0

      if review_token_pressure_high?(state) and not needs_count? do
        nil
      else
        next_count =
          cond do
            not tracking? -> nil
            needs_count? -> 1
            true -> min(count + 1, 2)
          end

        resume =
          state
          |> Map.get(:resume_context, %{})
          |> Enum.into(%{})
          |> Map.put(:token_pressure, "high")
          |> maybe_put_review_fix_retry_count(next_count)

        %{resume_context: resume, stage: stage, observed: input, soft_budget: soft_budget, review_fix_budget_retry_count: next_count, issue_identifier: identifier}
      end
    end
  end

  @spec runtime(Observation.t()) :: map()
  def runtime(%Observation{source: :legacy} = observation) do
    issue = observation.issue
    running_entry = observation.entry
    workspace = observation.workspace
    token_budget = observation.token_budget
    review_fix_budget = observation.review_fix_budget
    broad_implement_budget = observation.broad_budget
    run_state = observation.state
    resume_context = effective_resume_context(run_state, running_entry)
    stage_budget = current_stage_token_budget(issue, running_entry, workspace, run_state)
    current_turn_input = current_turn_input_tokens(running_entry)

    stage =
      Map.get(running_entry, :dispatch_stage) ||
        Map.get(running_entry, :stage) ||
        current_stage(issue, workspace, run_state)

    broad_admission =
      broad_implement_admission_state(
        issue,
        running_entry,
        resume_context,
        broad_implement_budget,
        stage,
        stage_budget,
        current_turn_input,
        workspace,
        run_state
      )

    if review_fix_budget_mode?(running_entry, resume_context, review_fix_budget) do
      adaptive_budget = adaptive_review_fix_budget(review_fix_budget, resume_context)

      %{
        mode: "review_fix",
        admission_reason: Map.get(resume_context, :budget_admission_reason),
        pressure_level: Map.get(resume_context, :budget_pressure_level, "normal"),
        retry_count: review_fix_retry_count(resume_context),
        window_base_turn: Map.get(resume_context, :budget_window_base_turn),
        last_stop_code: Map.get(resume_context, :budget_last_stop_code),
        last_observed_input_tokens: Map.get(resume_context, :budget_last_observed_input_tokens),
        scope_kind: Map.get(resume_context, :budget_scope_kind),
        scope_ids: normalize_scope_ids(Map.get(resume_context, :budget_scope_ids)),
        auto_narrowed: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_auto_narrowed)),
        total_extension_used: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_total_extension_used)),
        target_paths: Focus.normalize_paths(Map.get(resume_context, :target_paths, [])),
        next_required_path: Map.get(resume_context, :next_required_path),
        expansion_used: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_expansion_used)),
        per_turn_input_soft: adaptive_budget.per_turn_input_soft,
        per_turn_input_hard: adaptive_budget.per_turn_input_hard,
        max_turns_in_window: adaptive_budget.max_turns_in_window,
        per_issue_total_limit:
          effective_review_fix_total_budget(
            token_budget,
            review_fix_budget,
            resume_context
          ),
        per_issue_total_extension: review_fix_budget[:per_issue_total_extension]
      }
    else
      stage_budget = current_stage_token_budget(issue, running_entry)

      if broad_implement_budget_mode?(resume_context, broad_implement_budget) do
        %{
          mode: "broad_implement",
          admission_reason:
            Map.get(resume_context, :budget_admission_reason) ||
              Map.get(broad_admission, :admission_reason),
          pressure_level: Map.get(resume_context, :budget_pressure_level, "normal"),
          retry_count: broad_implement_retry_count(resume_context),
          window_base_turn: Map.get(resume_context, :budget_window_base_turn),
          last_stop_code: Map.get(resume_context, :budget_last_stop_code),
          last_observed_input_tokens: Map.get(resume_context, :budget_last_observed_input_tokens),
          scope_kind: nil,
          scope_ids: [],
          auto_narrowed: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_auto_narrowed)),
          total_extension_used: false,
          target_paths: Focus.normalize_paths(Map.get(resume_context, :target_paths, [])),
          next_required_path: Map.get(resume_context, :next_required_path),
          expansion_used: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_expansion_used)),
          per_turn_input_soft: stage_budget[:per_turn_input_soft],
          per_turn_input_hard: stage_budget[:per_turn_input_hard] || token_budget[:per_turn_input],
          max_turns_in_window: nil,
          per_issue_total_limit: token_budget[:per_issue_total],
          per_issue_total_extension: nil
        }
      else
        %{
          mode: "broad",
          admission_reason:
            Map.get(resume_context, :budget_admission_reason) ||
              Map.get(broad_admission, :admission_reason),
          pressure_level: if(Map.get(resume_context, :token_pressure) == "high", do: "high", else: "normal"),
          retry_count: 0,
          window_base_turn: Map.get(resume_context, :budget_window_base_turn),
          last_stop_code: Map.get(resume_context, :budget_last_stop_code),
          last_observed_input_tokens: Map.get(resume_context, :budget_last_observed_input_tokens),
          scope_kind: nil,
          scope_ids: [],
          auto_narrowed: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_auto_narrowed)),
          total_extension_used: false,
          target_paths: Focus.normalize_paths(Map.get(resume_context, :target_paths, [])),
          next_required_path: Map.get(resume_context, :next_required_path),
          expansion_used: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_expansion_used)),
          per_turn_input_soft: stage_budget[:per_turn_input_soft],
          per_turn_input_hard: stage_budget[:per_turn_input_hard] || token_budget[:per_turn_input],
          max_turns_in_window: nil,
          per_issue_total_limit: token_budget[:per_issue_total],
          per_issue_total_extension: nil
        }
      end
    end
  end

  @spec delivery_context(map(), map(), keyword()) :: delivery_context()
  def delivery_context(state, stored_resume, opts) do
    target_stage = Keyword.fetch!(opts, :target_stage)
    normalized = normalize_resume_context(stored_resume)
    review_context = review_fix_resume_context(state, normalized, target_stage)
    stored = Map.merge(normalized, review_context)

    broad_context =
      if review_fix_budget_mode?(review_context),
        do: %{},
        else: broad_retry_resume_context(normalized, target_stage)

    %{
      stored_resume: stored,
      budget_context:
        review_context
        |> Map.merge(broad_context)
        |> maybe_increment_review_fix_progress(Keyword.get(opts, :progress_delta, 0)),
      stale_budget_context: carry_forward_review_fix_budget_context(stored)
    }
  end

  @spec delivery_limits(map(), delivery_limit_request()) :: integer() | map()
  def delivery_limits(state, :implementation_turns), do: effective_implementation_turns(state)
  def delivery_limits(state, {:max_turns, max_turns}), do: effective_max_turns(max_turns, state)
  def delivery_limits(state, :focused_claim_limit), do: focused_review_claim_limit(state)
  def delivery_limits(state, :command_output_budget), do: implement_command_output_budget(state)

  @spec auto_continue?(map()) :: boolean()
  def auto_continue?(run_state) when is_map(run_state) do
    blocked_review_fix_budget_stop?(run_state) and
      actionable_review_claims_present?(run_state) and
      (addressed_review_claims_present?(run_state) or
         review_fix_retry_budget_active?(run_state))
  end

  defp review_fix_resume_context(state, stored_resume_context, "implement") do
    cond do
      review_fix_budget_mode?(stored_resume_context) ->
        carry_forward_review_fix_budget_context(stored_resume_context)

      review_fix_scope_ids(state, "review_claim_batch") != [] ->
        initial_review_fix_resume_context(
          state,
          "review_claim_batch",
          review_fix_scope_ids(state, "review_claim_batch")
        )

      review_fix_scope_ids(state, "ci_failure_batch") != [] ->
        initial_review_fix_resume_context(
          state,
          "ci_failure_batch",
          review_fix_scope_ids(state, "ci_failure_batch")
        )

      true ->
        %{}
    end
  end

  defp review_fix_resume_context(_state, _stored_resume_context, _target_stage), do: %{}

  defp broad_retry_resume_context(stored_resume_context, "implement") do
    if broad_implement_budget_mode?(stored_resume_context) do
      Map.take(stored_resume_context, [
        :budget_mode,
        :budget_pressure_level,
        :budget_retry_count,
        :budget_window_base_turn,
        :budget_last_stop_code,
        :budget_last_observed_input_tokens,
        :budget_auto_narrowed,
        :target_paths,
        :already_learned,
        :next_required_path,
        :budget_expansion_used,
        :budget_admission_reason,
        :token_pressure
      ])
    else
      %{}
    end
  end

  defp broad_retry_resume_context(_stored_resume_context, _target_stage), do: %{}

  defp initial_review_fix_resume_context(state, scope_kind, scope_ids) do
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

  defp carry_forward_review_fix_budget_context(resume_context) do
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

  defp review_fix_scope_ids(state, "review_claim_batch") do
    state
    |> Map.get(:review_claims, %{})
    |> Enum.filter(fn {_thread_key, claim} -> ReviewClaims.claim_pending_review_fix?(claim) end)
    |> Enum.map(fn {thread_key, _claim} -> to_string(thread_key) end)
    |> Enum.sort()
  end

  defp review_fix_scope_ids(state, "ci_failure_batch") do
    state
    |> Map.get(:last_failing_required_checks, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp review_fix_scope_ids(_state, _scope_kind), do: []

  defp review_fix_budget_mode?(resume_context) when is_map(resume_context),
    do: Map.get(resume_context, :budget_mode) == "review_fix"

  defp review_fix_budget_mode?(_resume_context), do: false

  defp broad_implement_budget_mode?(resume_context) when is_map(resume_context),
    do: Map.get(resume_context, :budget_mode) == "broad_implement"

  defp broad_implement_budget_mode?(resume_context, broad_implement_budget)
       when is_map(resume_context) and is_map(broad_implement_budget) do
    Map.get(broad_implement_budget, :enabled, true) and
      Map.get(resume_context, :budget_mode) == "broad_implement"
  end

  defp broad_implement_budget_mode?(_resume_context, _broad_implement_budget), do: false

  defp maybe_increment_review_fix_progress(resume_context, delta)
       when is_map(resume_context) and is_integer(delta) and delta > 0 do
    if review_fix_budget_mode?(resume_context) do
      Map.update(resume_context, :budget_progress_count, delta, &(&1 + delta))
    else
      resume_context
    end
  end

  defp maybe_increment_review_fix_progress(resume_context, _delta), do: resume_context

  defp normalize_resume_context(context) when is_map(context) do
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

  defp normalize_resume_context(_context), do: %{}

  defp normalize_resume_context_key("budget_mode"), do: :budget_mode

  defp normalize_resume_context_key("budget_pressure_level"), do: :budget_pressure_level

  defp normalize_resume_context_key("budget_retry_count"), do: :budget_retry_count

  defp normalize_resume_context_key("budget_window_base_turn"), do: :budget_window_base_turn

  defp normalize_resume_context_key("budget_last_stop_code"), do: :budget_last_stop_code

  defp normalize_resume_context_key("budget_last_observed_input_tokens"),
    do: :budget_last_observed_input_tokens

  defp normalize_resume_context_key("budget_scope_kind"), do: :budget_scope_kind

  defp normalize_resume_context_key("budget_scope_ids"), do: :budget_scope_ids

  defp normalize_resume_context_key("budget_progress_count"), do: :budget_progress_count

  defp normalize_resume_context_key("budget_total_extension_used"),
    do: :budget_total_extension_used

  defp normalize_resume_context_key("budget_auto_narrowed"), do: :budget_auto_narrowed

  defp normalize_resume_context_key("target_paths"), do: :target_paths

  defp normalize_resume_context_key("already_learned"), do: :already_learned

  defp normalize_resume_context_key("next_required_path"), do: :next_required_path

  defp normalize_resume_context_key("budget_expansion_used"), do: :budget_expansion_used

  defp normalize_resume_context_key("budget_admission_reason"), do: :budget_admission_reason

  defp normalize_resume_context_key("token_pressure"), do: :token_pressure

  defp normalize_resume_context_key(_key), do: nil

  defp implement_command_output_budget(state) do
    cond do
      ReviewClaims.focused_review_claims(Map.get(state, :review_claims, %{})) == [] ->
        %{
          stage: "implement",
          per_command_bytes: 8_192,
          per_turn_bytes: 32_768,
          max_command_count: 12
        }

      get_in(state, [:resume_context, :token_pressure]) == "high" ->
        %{
          stage: "implement",
          per_command_bytes: 4_096,
          per_turn_bytes: 12_288,
          max_command_count: 4
        }

      true ->
        %{
          stage: "implement",
          per_command_bytes: 6_144,
          per_turn_bytes: 24_576,
          max_command_count: 6
        }
    end
  end

  defp focused_review_claim_limit(state) do
    case get_in(state, [:resume_context, :token_pressure]) do
      "high" -> 1
      _ -> 2
    end
  end

  defp effective_implementation_turns(state) when is_map(state) do
    implementation_turns = Map.get(state, :implementation_turns, 0)
    window_base = get_in(state, [:resume_context, :implementation_turn_window_base]) || 0

    cond do
      not is_integer(implementation_turns) ->
        0

      not is_integer(window_base) ->
        implementation_turns

      implementation_turns >= window_base ->
        implementation_turns - window_base

      true ->
        implementation_turns
    end
  end

  defp effective_max_turns(max_turns, state) when is_integer(max_turns) and is_map(state) do
    if review_fix_turn_budget_candidate?(state) do
      max(max_turns, @review_fix_max_turns)
    else
      max_turns
    end
  end

  defp review_fix_turn_budget_candidate?(state) when is_map(state) do
    get_in(state, [:resume_context, :token_pressure]) == "high" and
      Enum.any?(Map.get(state, :review_claims, %{}), fn {_thread_key, claim} ->
        claim_value(claim, :disposition) == "accepted" and claim_value(claim, :actionable, false)
      end)
  end

  defp claim_value(claim, key, default \\ nil) when is_map(claim) and is_atom(key) do
    Map.get(claim, key, Map.get(claim, Atom.to_string(key), default))
  end

  defp review_fix_retry_budget_active?(run_state) when is_map(run_state) do
    review_fix_budget_retry_count(run_state) > 0 and
      resume_context_token_pressure(run_state) == "high"
  end

  defp review_fix_budget_retry_count(run_state) when is_map(run_state) do
    run_state
    |> resume_context_map()
    |> map_value("review_fix_budget_retry_count")
    |> case do
      value when is_integer(value) and value > 0 -> value
      _ -> 0
    end
  end

  defp resume_context_token_pressure(run_state) when is_map(run_state) do
    run_state
    |> resume_context_map()
    |> map_value("token_pressure")
  end

  defp resume_context_map(run_state) when is_map(run_state) do
    case Map.get(run_state, :resume_context) || Map.get(run_state, "resume_context") do
      context when is_map(context) -> context
      _ -> %{}
    end
  end

  defp blocked_review_fix_budget_stop?(run_state) when is_map(run_state) do
    last_rule_id = Map.get(run_state, :last_rule_id) || Map.get(run_state, "last_rule_id")

    stop_reason =
      Map.get(run_state, :stop_reason) ||
        Map.get(run_state, "stop_reason") ||
        %{}

    last_rule_id == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, :rule_id) == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, "rule_id") == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, :code) == "per_turn_input_budget_exceeded" or
      Map.get(stop_reason, "code") == "per_turn_input_budget_exceeded"
  end

  defp addressed_review_claims_present?(run_state) when is_map(run_state) do
    run_state
    |> review_claim_values()
    |> Enum.any?(fn claim ->
      map_value(claim, "implementation_status") == "addressed"
    end)
  end

  defp actionable_review_claims_present?(run_state) when is_map(run_state) do
    run_state
    |> review_claim_values()
    |> Enum.any?(fn claim ->
      map_value(claim, "disposition") == "accepted" and
        truthy_map_value(claim, "actionable") and
        map_value(claim, "implementation_status") != "addressed"
    end)
  end

  defp review_claim_values(run_state) when is_map(run_state) do
    case Map.get(run_state, :review_claims) || Map.get(run_state, "review_claims") do
      claims when is_map(claims) -> Map.values(claims)
      _ -> []
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_map_atom_key(key))
  end

  defp map_value(_map, _key), do: nil

  defp known_map_atom_key("implementation_status"), do: :implementation_status

  defp known_map_atom_key("disposition"), do: :disposition

  defp known_map_atom_key("actionable"), do: :actionable

  defp known_map_atom_key("blocked"), do: :blocked

  defp known_map_atom_key("needs_another_turn"), do: :needs_another_turn

  defp known_map_atom_key(_key), do: nil

  defp truthy_map_value(map, key) do
    case map_value(map, key) do
      true -> true
      "true" -> true
      1 -> true
      "1" -> true
      _ -> false
    end
  end

  defp budget_exceeded?(nil, _observed), do: false

  defp budget_exceeded?(budget, observed) when is_integer(budget), do: observed > budget

  defp review_fix_budget_mode?(running_entry, resume_context, review_fix_budget) do
    issue = Map.get(running_entry, :issue, %{})

    workspace =
      Map.get(running_entry, :workspace) ||
        Map.get(running_entry, :workspace_path) ||
        Workspace.path_for_issue(
          Map.get(issue, :identifier) || Map.get(issue, "identifier") ||
            Map.get(running_entry, :identifier)
        )

    run_state =
      if is_binary(workspace), do: RunStateStore.load_or_default(workspace, issue), else: %{}

    stage =
      Map.get(running_entry, :stage) ||
        Map.get(running_entry, :dispatch_stage) ||
        current_stage(issue, workspace, run_state)

    Map.get(review_fix_budget, :enabled, true) and
      stage == "implement" and
      Map.get(resume_context, :budget_mode) == "review_fix"
  end

  defp adaptive_review_fix_budget(review_fix_budget, resume_context) do
    retry_count = review_fix_retry_count(resume_context)

    hard_budget =
      cond do
        retry_count >= 3 ->
          review_fix_budget[:retry_3_per_turn_input_hard] ||
            review_fix_budget[:per_turn_input_hard]

        retry_count >= 2 ->
          review_fix_budget[:retry_2_per_turn_input_hard] ||
            review_fix_budget[:per_turn_input_hard]

        true ->
          review_fix_budget[:per_turn_input_hard]
      end

    max_turns_in_window =
      cond do
        retry_count >= 3 ->
          review_fix_budget[:retry_3_max_turns_in_window] ||
            review_fix_budget[:max_turns_in_window]

        retry_count >= 2 ->
          review_fix_budget[:retry_2_max_turns_in_window] ||
            review_fix_budget[:max_turns_in_window]

        true ->
          review_fix_budget[:max_turns_in_window]
      end

    %{
      per_turn_input_soft: review_fix_budget[:per_turn_input_soft],
      per_turn_input_hard: hard_budget,
      max_turns_in_window: max_turns_in_window,
      narrow_scope_batch_size: review_fix_budget[:narrow_scope_batch_size] || 1,
      auto_retry_limit: review_fix_budget[:auto_retry_limit] || 0
    }
  end

  defp workspace_for_issue(issue, running_entry) do
    Map.get(running_entry, :workspace_path) ||
      Map.get(running_entry, :workspace) ||
      Workspace.path_for_issue(Map.get(issue, :identifier) || Map.get(issue, "identifier"))
  end

  defp effective_resume_context(run_state, running_entry) do
    run_state
    |> Map.get(:resume_context, %{})
    |> normalize_resume_context()
    |> Map.merge(normalize_resume_context(Map.get(running_entry, :resume_context, %{})))
  end

  defp current_stage_token_budget(issue, running_entry) do
    workspace = workspace_for_issue(issue, running_entry)

    run_state =
      if is_binary(workspace), do: RunStateStore.load_or_default(workspace, issue), else: %{}

    current_stage_token_budget(issue, running_entry, workspace, run_state)
  end

  defp current_stage_token_budget(issue, running_entry, workspace, run_state) do
    stage =
      Map.get(running_entry, :dispatch_stage) ||
        Map.get(running_entry, :stage) ||
        current_stage(issue, workspace, run_state)

    stage_budget =
      case Config.policy_stage_token_budget(stage) do
        budget when is_map(budget) -> budget
        _ -> %{}
      end

    maybe_relax_review_fix_budget(stage_budget, issue, stage, workspace, run_state)
  end

  defp current_turn_input_tokens(running_entry) when is_map(running_entry) do
    input_total = Map.get(running_entry, :agent_input_tokens, 0)
    turn_started_input = Map.get(running_entry, :turn_started_input_tokens, 0)
    max(0, input_total - turn_started_input)
  end

  defp current_total_token_budget(token_budget, issue, running_entry, run_state)
       when is_map(token_budget) and is_map(run_state) do
    total_budget = Map.get(token_budget, :per_issue_total)
    stage = Map.get(running_entry, :dispatch_stage) || Map.get(running_entry, :stage)

    maybe_relax_review_fix_total_budget(total_budget, issue, stage, run_state)
  end

  defp current_total_token_budget(token_budget, _issue, _running_entry, _run_state)
       when is_map(token_budget) do
    Map.get(token_budget, :per_issue_total)
  end

  defp current_stage(issue, workspace, run_state)
       when is_binary(workspace) and is_map(run_state) do
    case run_state do
      %{stage: stage} when is_binary(stage) -> stage
      _ -> current_stage(issue, workspace)
    end
  end

  defp current_stage(%{state: issue_state}, _workspace, run_state)
       when is_binary(issue_state) and is_map(run_state) do
    Map.get(run_state, :stage) || fallback_stage_from_issue_state(issue_state)
  end

  defp current_stage(_issue, _workspace, _run_state), do: nil

  defp current_stage(issue, workspace) when is_binary(workspace) do
    case RunStateStore.load_or_default(workspace, issue) do
      %{stage: stage} when is_binary(stage) -> stage
      _ -> nil
    end
  end

  defp fallback_stage_from_issue_state(issue_state) when is_binary(issue_state) do
    case String.downcase(String.trim(issue_state)) do
      "todo" -> "checkout"
      "in progress" -> "implement"
      "review" -> "review"
      "merging" -> "await_checks"
      "done" -> "done"
      _ -> nil
    end
  end

  defp maybe_relax_review_fix_budget(stage_budget, issue, stage, _workspace, state)
       when is_map(stage_budget) and is_map(state) do
    issue_identifier = issue_identifier_for(issue, state)
    retry_count = review_fix_budget_retry_count(state, issue_identifier)

    if review_fix_budget_candidate?(state, stage) and retry_count > 0 do
      review_fix_relaxed_stage_budget(stage_budget, retry_count, state)
    else
      stage_budget
    end
  end

  defp review_fix_relaxed_stage_budget(stage_budget, retry_count, state)
       when is_map(stage_budget) and is_integer(retry_count) do
    cond do
      retry_count >= 2 and review_fix_turn_window_active?(state) ->
        stage_budget
        |> Map.put(
          :per_turn_input_soft,
          relaxed_budget_value(stage_budget[:per_turn_input_soft], 110_000)
        )
        |> Map.put(
          :per_turn_input_hard,
          relaxed_budget_value(stage_budget[:per_turn_input_hard], 220_000)
        )

      true ->
        stage_budget
        |> Map.put(
          :per_turn_input_soft,
          relaxed_budget_value(stage_budget[:per_turn_input_soft], 85_000)
        )
        |> Map.put(
          :per_turn_input_hard,
          relaxed_budget_value(stage_budget[:per_turn_input_hard], 150_000)
        )
    end
  end

  defp review_fix_budget_candidate?(state, stage) do
    stage == "implement" and
      review_token_pressure_high?(state) and
      accepted_review_claim_count(state) > 0
  end

  defp maybe_relax_review_fix_total_budget(total_budget, issue, stage, state)
       when is_integer(total_budget) and is_map(state) do
    issue_identifier = issue_identifier_for(issue, state)
    retry_count = review_fix_budget_retry_count(state, issue_identifier)

    if review_fix_total_budget_candidate?(state, stage) and retry_count > 0 do
      total_budget + review_fix_total_budget_extension(state, retry_count)
    else
      total_budget
    end
  end

  defp maybe_relax_review_fix_total_budget(total_budget, _issue, _stage, _state), do: total_budget

  defp review_fix_total_budget_candidate?(state, stage) do
    review_fix_budget_candidate?(state, stage) and
      addressed_review_claim_count(state) > 0
  end

  defp review_fix_total_budget_extension(state, retry_count)
       when is_map(state) and is_integer(retry_count) do
    actionable_count = accepted_review_claim_count(state)

    per_claim_extension =
      cond do
        retry_count >= 2 and review_fix_turn_window_active?(state) -> 110_000
        true -> 80_000
      end

    actionable_count
    |> Kernel.*(per_claim_extension)
    |> min(320_000)
  end

  defp review_fix_turn_window_active?(state) when is_map(state) do
    case get_in(state, [:resume_context, :implementation_turn_window_base]) do
      value when is_integer(value) and value >= 0 -> true
      _ -> false
    end
  end

  defp review_fix_retry_tracking_candidate?(state, stage) do
    stage == "implement" and accepted_review_claim_count(state) > 0
  end

  defp review_token_pressure_high?(%{resume_context: %{"token_pressure" => "high"}}), do: true

  defp review_token_pressure_high?(%{resume_context: %{token_pressure: "high"}}), do: true

  defp review_token_pressure_high?(_state), do: false

  defp review_fix_budget_retry_count(state, issue_identifier) when is_map(state) do
    context =
      state
      |> Map.get(:resume_context, %{})
      |> Enum.into(%{})

    case Map.get(context, :review_fix_budget_retry_count) ||
           Map.get(context, "review_fix_budget_retry_count") do
      count when is_integer(count) and count >= 0 -> count
      _ -> legacy_review_fix_retry_count(state, issue_identifier)
    end
  end

  defp maybe_put_review_fix_retry_count(resume_context, nil), do: resume_context

  defp maybe_put_review_fix_retry_count(resume_context, count) when is_map(resume_context) do
    Map.put(resume_context, :review_fix_budget_retry_count, count)
  end

  defp accepted_review_claim_count(state) when is_map(state) do
    state
    |> Map.get(:review_claims, %{})
    |> Enum.count(fn {_thread_key, claim} ->
      Map.get(claim, "disposition") == "accepted" and Map.get(claim, "actionable", false)
    end)
  end

  defp addressed_review_claim_count(state) when is_map(state) do
    state
    |> Map.get(:review_claims, %{})
    |> Enum.count(fn {_thread_key, claim} ->
      Map.get(claim, "implementation_status") == "addressed"
    end)
  end

  defp relaxed_budget_value(nil, fallback), do: fallback

  defp relaxed_budget_value(value, fallback) when is_integer(value), do: max(value, fallback)

  defp legacy_review_fix_retry_count(state, issue_identifier) do
    if prior_review_fix_budget_stop?(state, issue_identifier) do
      1
    else
      0
    end
  end

  defp prior_review_fix_budget_stop?(state, issue_identifier) do
    review_fix_budget_stop_reason?(state) or
      prior_review_fix_budget_stop_in_ledger?(issue_identifier)
  end

  defp review_fix_budget_stop_reason?(state) when is_map(state) do
    last_rule_id = Map.get(state, :last_rule_id) || Map.get(state, "last_rule_id")

    stop_reason =
      state
      |> Map.get(:stop_reason)
      |> mapish()

    resume_context =
      state
      |> Map.get(:resume_context)
      |> mapish()

    last_rule_id == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, :rule_id) == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, "rule_id") == "budget.per_turn_input_exceeded" or
      Map.get(stop_reason, :code) == "per_turn_input_budget_exceeded" or
      Map.get(stop_reason, "code") == "per_turn_input_budget_exceeded" or
      Map.get(resume_context, :last_blocking_rule) == "budget.per_turn_input_exceeded" or
      Map.get(resume_context, "last_blocking_rule") == "budget.per_turn_input_exceeded"
  end

  defp prior_review_fix_budget_stop_in_ledger?(issue_identifier)
       when is_binary(issue_identifier) do
    RunLedger.recent_entries(200)
    |> Enum.reverse()
    |> Enum.any?(fn entry ->
      Map.get(entry, "issue_identifier") == issue_identifier and
        Map.get(entry, "event") == "runtime.stopped" and
        Map.get(entry, "rule_id") == "budget.per_turn_input_exceeded"
    end)
  end

  defp prior_review_fix_budget_stop_in_ledger?(_issue_identifier), do: false

  defp issue_identifier_for(issue, state) do
    Map.get(issue, :identifier) ||
      Map.get(issue, "identifier") ||
      Map.get(state, :issue_identifier) ||
      Map.get(state, "issue_identifier")
  end

  defp mapish(value) when is_map(value), do: Enum.into(value, %{})

  defp mapish(_value), do: %{}

  defp review_fix_resume_context_for_budget_retry(
         resume_context,
         running_entry,
         stop_code,
         observed_tokens,
         overrides
       ) do
    default_scope_kind = Map.get(resume_context, :budget_scope_kind) || "review_claim_batch"
    turn_count = Map.get(running_entry, :turn_count, 0)

    resume_context
    |> Map.put_new(:budget_mode, "review_fix")
    |> Map.put_new(:budget_pressure_level, "normal")
    |> Map.put_new(:budget_retry_count, 0)
    |> Map.put_new(:budget_window_base_turn, turn_count)
    |> Map.put_new(:budget_scope_kind, default_scope_kind)
    |> Map.put_new(
      :budget_scope_ids,
      normalize_scope_ids(Map.get(resume_context, :budget_scope_ids))
    )
    |> Map.put(:budget_last_stop_code, stop_code)
    |> Map.put(:budget_last_observed_input_tokens, observed_tokens)
    |> Map.put(:token_pressure, "high")
    |> Map.merge(Enum.into(overrides, %{}))
  end

  defp review_fix_retry_count(resume_context) do
    case Map.get(resume_context, :budget_retry_count, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp normalize_scope_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_scope_ids(_ids), do: []

  defp broad_implement_admission_state(
         issue,
         running_entry,
         resume_context,
         broad_implement_budget,
         stage,
         stage_budget,
         current_turn_input,
         workspace,
         run_state
       )
       when is_map(running_entry) and is_map(resume_context) and is_map(stage_budget) and
              is_map(run_state) do
    hard_budget = stage_budget[:per_turn_input_hard] || Config.policy_per_turn_input_budget()
    primary_target_path = Focus.primary_path(Map.put(running_entry, :issue, issue), resume_context)
    budget_exceeded = budget_exceeded?(hard_budget, current_turn_input)

    admission_reason =
      cond do
        not is_binary(Map.get(running_entry, :workspace_path) || Map.get(running_entry, :workspace)) or
            not broad_implement_workspace_candidate?(workspace) ->
          "missing_workspace"

        not Map.get(broad_implement_budget, :enabled, true) ->
          "broad_implement_disabled"

        stage != "implement" ->
          "stage_not_implement"

        review_fix_budget_candidate?(run_state, stage) or
          Map.get(resume_context, :budget_mode) == "review_fix" or
            Map.get(resume_context, :budget_scope_kind) in ["review_claim_batch", "ci_failure_batch"] ->
          "review_fix_candidate"

        not is_nil(Map.get(run_state, :last_ci_failure)) ->
          "ci_failure_present"

        not budget_exceeded ->
          "budget_not_exceeded"

        is_nil(primary_target_path) ->
          "no_target_path"

        true ->
          nil
      end

    %{
      budget_exceeded?: budget_exceeded,
      admission_reason: admission_reason,
      enter_retry_lane?: budget_exceeded and admission_reason in [nil, "no_target_path"],
      primary_target_path: primary_target_path
    }
  end

  defp broad_implement_budget_metadata(running_entry, resume_context) do
    %{
      stage: Map.get(running_entry, :stage),
      retry_count: broad_implement_retry_count(resume_context),
      pressure_level: Map.get(resume_context, :budget_pressure_level),
      auto_narrowed: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_auto_narrowed)),
      target_paths: Map.get(resume_context, :target_paths, []),
      next_required_path: Map.get(resume_context, :next_required_path),
      expansion_used: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_expansion_used))
    }
  end

  defp broad_implement_pressure_level_for_retry(retry_count) when retry_count >= 1,
    do: "high"

  defp broad_implement_pressure_level_for_retry(_retry_count), do: "normal"

  defp broad_implement_resume_context_for_budget_retry(
         resume_context,
         running_entry,
         stop_code,
         observed_tokens,
         overrides
       ) do
    turn_count = Map.get(running_entry, :turn_count, 0)
    override_map = Enum.into(overrides, %{})

    %{target_paths: target_paths, already_learned: already_learned} =
      Focus.retry_fields(running_entry, resume_context, override_map)

    resume_context
    |> Map.put(:budget_mode, "broad_implement")
    |> Map.put_new(:budget_pressure_level, "normal")
    |> Map.put_new(:budget_retry_count, 0)
    |> Map.put_new(:budget_window_base_turn, turn_count)
    |> Map.put(:budget_last_stop_code, stop_code)
    |> Map.put(:budget_last_observed_input_tokens, observed_tokens)
    |> maybe_put_broad_retry_target_paths(target_paths)
    |> maybe_put_broad_retry_learned(already_learned)
    |> maybe_put_broad_retry_next_required_path(Map.get(override_map, :next_required_path))
    |> maybe_put_budget_admission_reason(Map.get(override_map, :budget_admission_reason))
    |> Map.put(:token_pressure, "high")
    |> Map.merge(override_map)
  end

  defp broad_implement_retry_count(resume_context) do
    case Map.get(resume_context, :budget_retry_count, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp broad_implement_workspace_candidate?(workspace) when is_binary(workspace),
    do: File.dir?(workspace)

  defp effective_review_fix_total_budget(token_budget, review_fix_budget, resume_context) do
    base_budget = token_budget[:per_issue_total]
    extension_budget = review_fix_budget[:per_issue_total_extension]
    extension_eligible? = review_fix_total_extension_eligible?(resume_context, extension_budget)

    extension_used_or_eligible? =
      SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_total_extension_used)) or extension_eligible?

    cond do
      not is_integer(base_budget) ->
        nil

      extension_used_or_eligible? and is_integer(extension_budget) ->
        base_budget + extension_budget

      true ->
        base_budget
    end
  end

  defp generic_budget_resume_context_for_stop(resume_context, broad_admission, observed_tokens)
       when is_map(resume_context) and is_map(broad_admission) and is_integer(observed_tokens) do
    resume_context
    |> Map.put(:budget_mode, "broad")
    |> maybe_put_budget_admission_reason(Map.get(broad_admission, :admission_reason))
    |> Map.put(:budget_last_stop_code, "budget.per_turn_input_exceeded")
    |> Map.put(:budget_last_observed_input_tokens, observed_tokens)
    |> Map.put(:token_pressure, "high")
  end

  defp narrow_review_fix_scope_ids(resume_context, batch_size) do
    resume_context
    |> Map.get(:budget_scope_ids, [])
    |> normalize_scope_ids()
    |> Enum.take(max(batch_size || 1, 1))
  end

  defp review_fix_budget_metadata(running_entry, resume_context, extras) do
    %{
      stage: Map.get(running_entry, :stage),
      retry_count: review_fix_retry_count(resume_context),
      pressure_level: Map.get(resume_context, :budget_pressure_level),
      scope_kind: Map.get(resume_context, :budget_scope_kind),
      scope_ids: normalize_scope_ids(Map.get(resume_context, :budget_scope_ids)),
      total_extension_used: SymphonyElixir.Util.truthy?(Map.get(resume_context, :budget_total_extension_used))
    }
    |> Map.merge(extras)
  end

  defp review_fix_pressure_level_for_retry(retry_count) when retry_count >= 3, do: "critical"

  defp review_fix_pressure_level_for_retry(retry_count) when retry_count >= 2, do: "high"

  defp review_fix_pressure_level_for_retry(_retry_count), do: "soft"

  defp review_fix_progress_count(resume_context) do
    case Map.get(resume_context, :budget_progress_count, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp review_fix_retry_continues?(retry_count, _can_narrow_scope?) when retry_count < 3, do: true

  defp review_fix_retry_continues?(_retry_count, can_narrow_scope?), do: can_narrow_scope?

  defp review_fix_total_extension_eligible?(resume_context, extension_budget) do
    is_integer(extension_budget) and review_fix_progress_count(resume_context) >= 1
  end

  defp review_fix_turns_in_window(running_entry, resume_context) do
    turn_count = Map.get(running_entry, :turn_count, 0)
    base_turn = Map.get(resume_context, :budget_window_base_turn, turn_count)
    max(turn_count - base_turn + 1, 1)
  end

  defp maybe_put_broad_retry_learned(resume_context, nil), do: resume_context

  defp maybe_put_broad_retry_learned(resume_context, text),
    do: Map.put(resume_context, :already_learned, text)

  defp maybe_put_broad_retry_next_required_path(resume_context, nil),
    do: Map.delete(resume_context, :next_required_path)

  defp maybe_put_broad_retry_next_required_path(resume_context, path),
    do: Map.put(resume_context, :next_required_path, path)

  defp maybe_put_broad_retry_target_paths(resume_context, []), do: resume_context

  defp maybe_put_broad_retry_target_paths(resume_context, target_paths),
    do: Map.put(resume_context, :target_paths, target_paths)

  defp maybe_put_budget_admission_reason(resume_context, nil),
    do: Map.delete(resume_context, :budget_admission_reason)

  defp maybe_put_budget_admission_reason(resume_context, reason),
    do: Map.put(resume_context, :budget_admission_reason, reason)
end
