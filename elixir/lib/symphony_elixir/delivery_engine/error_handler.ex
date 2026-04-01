defmodule SymphonyElixir.DeliveryEngine.ErrorHandler do
  @moduledoc """
  Pure error classification, turn-result logging helpers, and checkout-error
  classification extracted from DeliveryEngine.

  Every function here is either a pure data transform or a thin Logger wrapper —
  no RunStateStore writes, no issue-source mutations.
  """

  # credo:disable-for-this-file

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TurnResult

  # ---------------------------------------------------------------------------
  # safe_detail_text — shared text-truncation utility
  # ---------------------------------------------------------------------------

  @doc "Truncate a detail value to a safe log/comment length."
  def safe_detail_text(details) when is_binary(details) do
    details
    |> String.trim()
    |> String.slice(0, 2_000)
  end

  def safe_detail_text(details) do
    details
    |> inspect()
    |> String.trim()
    |> String.slice(0, 2_000)
  end

  # ---------------------------------------------------------------------------
  # Turn logging — run_logged_agent_turn / log_agent_turn_lifecycle
  # ---------------------------------------------------------------------------

  @doc "Run a provider turn and return `{turn_result, log_context}`."
  def run_logged_agent_turn(provider, app_session, prompt, issue, opts) do
    started_at = System.monotonic_time()
    turn_result = provider.run_turn(app_session, prompt, issue, opts)

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    log_context =
      agent_turn_log_context(
        Keyword.get(opts, :stage),
        provider,
        Keyword.get(opts, :model),
        issue,
        duration_ms,
        normalize_turn_tokens(turn_result)
      )

    {turn_result, log_context}
  end

  @doc "Emit a structured log line for an agent turn lifecycle event."
  def log_agent_turn_lifecycle(log_context, result) do
    Logger.info(
      "event=delivery_engine.agent_turn stage=#{log_context.stage} provider=#{log_context.provider} model=#{inspect(log_context.model)} issue=#{log_context.issue} duration_ms=#{log_context.duration_ms} tokens=#{inspect(log_context.tokens)} result=#{result}",
      event: "delivery_engine.agent_turn",
      stage: log_context.stage,
      provider: log_context.provider,
      model: log_context.model,
      issue: log_context.issue,
      issue_identifier: log_context.issue_identifier,
      duration_ms: log_context.duration_ms,
      tokens: log_context.tokens,
      result: result
    )
  end

  # ---------------------------------------------------------------------------
  # Turn log-context builders (pure)
  # ---------------------------------------------------------------------------

  def agent_turn_log_context(stage, provider, model, issue, duration_ms, tokens) do
    %{
      stage: stage,
      provider: normalize_turn_provider(provider),
      model: model,
      issue: normalize_issue_log_value(issue),
      issue_identifier: Map.get(issue, :identifier),
      duration_ms: duration_ms,
      tokens: tokens
    }
  end

  def plan_turn_log_result(provider_turn_result, reported_turn_result, plan_completed) do
    "provider=#{normalize_provider_turn_outcome(provider_turn_result)},turn=#{normalize_reported_turn_outcome(reported_turn_result)},plan_completed=#{plan_completed}"
  end

  def implement_turn_log_result(provider_turn_result, reported_turn_result) do
    "provider=#{normalize_provider_turn_outcome(provider_turn_result)},turn=#{normalize_reported_turn_outcome(reported_turn_result)}"
  end

  # ---------------------------------------------------------------------------
  # Normalization helpers (pure)
  # ---------------------------------------------------------------------------

  def normalize_turn_provider(SymphonyElixir.AgentProvider.Codex), do: "codex"
  def normalize_turn_provider(SymphonyElixir.AgentProvider.CodexCLI), do: "codex-cli"
  def normalize_turn_provider(SymphonyElixir.AgentProvider.Claude), do: "claude"
  def normalize_turn_provider(provider) when is_binary(provider), do: provider
  def normalize_turn_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  def normalize_turn_provider(provider), do: inspect(provider)

  def normalize_issue_log_value(%Issue{identifier: identifier, id: issue_id}) do
    identifier || issue_id || "unknown"
  end

  def normalize_issue_log_value(issue) when is_map(issue) do
    Map.get(issue, :identifier) || Map.get(issue, :id) || "unknown"
  end

  def normalize_issue_log_value(_issue), do: "unknown"

  def normalize_turn_tokens({:ok, response}) when is_map(response) do
    usage = Map.get(response, :usage) || Map.get(response, "usage")

    case usage do
      usage when is_map(usage) ->
        input_tokens = normalize_token_count(Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens"))
        output_tokens = normalize_token_count(Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens"))
        total_tokens = normalize_token_count(Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens"))

        %{
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: if(total_tokens > 0, do: total_tokens, else: input_tokens + output_tokens)
        }

      _ ->
        default_turn_tokens()
    end
  end

  def normalize_turn_tokens(_turn_result), do: default_turn_tokens()

  def default_turn_tokens do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  def normalize_token_count(nil), do: 0
  def normalize_token_count(value) when is_integer(value), do: max(value, 0)

  def normalize_token_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> max(parsed, 0)
      :error -> 0
    end
  end

  def normalize_token_count(_value), do: 0

  def normalize_provider_turn_outcome({:ok, response}) when is_map(response) do
    response
    |> Map.get(:result, Map.get(response, "result"))
    |> normalize_turn_outcome_value("completed")
  end

  def normalize_provider_turn_outcome({:error, reason}) do
    normalize_turn_outcome_value(reason, "error")
  end

  def normalize_provider_turn_outcome(_result), do: "unknown"

  def normalize_reported_turn_outcome({:ok, %TurnResult{blocked: true, blocker_type: blocker_type}}) do
    "blocked:#{blocker_type || "unknown"}"
  end

  def normalize_reported_turn_outcome({:ok, %TurnResult{needs_another_turn: true}}),
    do: "needs_another_turn"

  def normalize_reported_turn_outcome({:ok, %TurnResult{}}), do: "completed"

  def normalize_reported_turn_outcome({:error, reason}) do
    normalize_turn_outcome_value(reason, "missing")
  end

  def normalize_reported_turn_outcome({:done, _issue}), do: "done"
  def normalize_reported_turn_outcome({:skip, _issue}), do: "skip"
  def normalize_reported_turn_outcome(_result), do: "unknown"

  def normalize_turn_outcome_value({tag, _details}, _default) when is_atom(tag),
    do: Atom.to_string(tag)

  def normalize_turn_outcome_value(value, _default) when is_atom(value), do: Atom.to_string(value)
  def normalize_turn_outcome_value(value, _default) when is_binary(value), do: value
  def normalize_turn_outcome_value(_value, default), do: default

  # ---------------------------------------------------------------------------
  # Error classification (pure)
  # ---------------------------------------------------------------------------

  def implementation_turn_error_summary(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(&implementation_turn_error_summary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" | ")
  end

  def implementation_turn_error_summary({:turn_failed, details}) do
    case turn_failed_reason_code(details) do
      "implementation.command_output_budget_exceeded" ->
        "Implement turn exceeded the command output budget: #{safe_detail_text(details)}"

      "implementation.command_count_exceeded" ->
        "Implement turn issued too many shell commands: #{safe_detail_text(details)}"

      "implementation.broad_read_violation" ->
        "Implement turn attempted a broad repository read instead of targeted inspection: #{safe_detail_text(details)}"

      "implementation.stage_command_violation" ->
        "Implement turn attempted a runtime-owned validation command: #{safe_detail_text(details)}"

      _ ->
        "Agent turn failed: #{safe_detail_text(details)}"
    end
  end

  def implementation_turn_error_summary({:port_exit, status}),
    do: "Agent process exited during the turn with status #{status}."

  def implementation_turn_error_summary(:turn_timeout),
    do: "Agent turn timed out before completing."

  def implementation_turn_error_summary({:agent_notification_error, method, details}),
    do: "Agent reported #{method}: #{safe_detail_text(details)}"

  def implementation_turn_error_summary({:turn_cancelled, details}),
    do: "Agent turn was cancelled: #{safe_detail_text(details)}"

  def implementation_turn_error_summary({:approval_required, details}),
    do: "Agent requested approval unexpectedly: #{safe_detail_text(details)}"

  def implementation_turn_error_summary({:turn_input_required, details}),
    do: "Agent requested operator input unexpectedly: #{safe_detail_text(details)}"

  def implementation_turn_error_summary(reason), do: safe_detail_text(reason)

  def implementation_error_to_map(reasons) when is_list(reasons),
    do: Enum.map(reasons, &implementation_error_to_map/1)

  def implementation_error_to_map({:agent_notification_error, method, details}),
    do: %{type: "agent_notification_error", method: method, details: safe_detail_text(details)}

  def implementation_error_to_map({tag, details}) when is_atom(tag),
    do: %{type: Atom.to_string(tag), details: safe_detail_text(details)}

  def implementation_error_to_map(reason),
    do: %{type: "unknown", details: safe_detail_text(reason)}

  def retryable_implementation_error?({:turn_failed, details}) do
    case turn_failed_reason_code(details) do
      "implementation.command_output_budget_exceeded" -> false
      "implementation.command_count_exceeded" -> false
      "implementation.broad_read_violation" -> false
      "implementation.stage_command_violation" -> false
      _ -> true
    end
  end

  def retryable_implementation_error?({:port_exit, _status}), do: true
  def retryable_implementation_error?(:turn_timeout), do: true
  def retryable_implementation_error?(_reason), do: false

  def non_retryable_implementation_error?({:turn_failed, details}) do
    case turn_failed_reason_code(details) do
      "implementation.command_output_budget_exceeded" -> true
      "implementation.command_count_exceeded" -> true
      "implementation.broad_read_violation" -> true
      "implementation.stage_command_violation" -> true
      _ -> false
    end
  end

  def non_retryable_implementation_error?({:turn_cancelled, _details}), do: true
  def non_retryable_implementation_error?({:approval_required, _details}), do: true
  def non_retryable_implementation_error?({:turn_input_required, _details}), do: true
  def non_retryable_implementation_error?(_reason), do: false

  def implementation_error_code({:turn_failed, details}) do
    case turn_failed_reason_code(details) do
      "implementation.command_output_budget_exceeded" -> :command_output_budget_exceeded
      "implementation.command_count_exceeded" -> :command_count_exceeded
      "implementation.broad_read_violation" -> :broad_read_violation
      "implementation.stage_command_violation" -> :stage_command_violation
      _ -> :turn_failed
    end
  end

  def implementation_error_code(_reason), do: :turn_failed

  def turn_failed_reason_code(details) when is_map(details) do
    Map.get(details, :reason) || Map.get(details, "reason")
  end

  def turn_failed_reason_code(_details), do: nil

  # ---------------------------------------------------------------------------
  # Checkout error classification (pure)
  # ---------------------------------------------------------------------------

  @doc """
  Classify a checkout error into `{blocker_code, message}`.

  Returns `{code :: atom(), message :: String.t()}` so the caller can pass them
  to `block_issue/5` without this module needing side-effectful dependencies.
  """
  def classify_checkout_error({:error, reason})
      when reason in [:missing_harness_version, :missing_required_checks] do
    {reason, "The repo harness contract is incomplete."}
  end

  def classify_checkout_error({:error, {:missing_harness_command, stage}}) do
    {:missing_harness_command, "The repo harness is missing the required `#{stage}.command` entry."}
  end

  def classify_checkout_error({:error, {:unknown_harness_keys, path, keys}}) do
    {:invalid_harness, "Unknown harness keys under #{Enum.join(path, ".")}: #{Enum.join(keys, ", ")}"}
  end

  def classify_checkout_error({:error, :missing}) do
    {:missing_harness, "The repo harness contract is missing after checkout."}
  end

  def classify_checkout_error({:error, :invalid_harness_root}) do
    {:invalid_harness, inspect(:invalid_harness_root)}
  end

  def classify_checkout_error({:error, %{code: :policy_pack_disallows_class} = conflict}) do
    {:policy_pack_disallows_class, Map.get(conflict, :details) || Map.get(conflict, :summary) || inspect(conflict)}
  end

  def classify_checkout_error({:error, %{code: :invalid_labels} = conflict}) do
    {:policy_invalid_labels, Map.get(conflict, :details) || Map.get(conflict, :summary) || inspect(conflict)}
  end

  def classify_checkout_error({:error, reason}) do
    {:checkout_failed, reason}
  end
end
