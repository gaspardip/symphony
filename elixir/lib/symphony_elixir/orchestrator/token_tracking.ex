defmodule SymphonyElixir.Orchestrator.TokenTracking do
  @moduledoc """
  Pure data-transformation functions for agent token/usage tracking.

  Extracted from Orchestrator — no GenServer coupling.
  """

  alias SymphonyElixir.Orchestrator.State

  # ---------------------------------------------------------------------------
  # integrate_agent_update and helpers
  # ---------------------------------------------------------------------------

  @spec integrate_agent_update(map(), map()) :: {map(), map()}
  def integrate_agent_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    agent_input_tokens = Map.get(running_entry, :agent_input_tokens, 0)
    agent_output_tokens = Map.get(running_entry, :agent_output_tokens, 0)
    agent_total_tokens = Map.get(running_entry, :agent_total_tokens, 0)
    agent_process_id = Map.get(running_entry, :agent_process_id)
    last_reported_input = Map.get(running_entry, :agent_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :agent_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :agent_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_agent_timestamp: timestamp,
        last_agent_message: summarize_agent_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_agent_event: event,
        agent_process_id: agent_process_id_for_update(agent_process_id, update),
        agent_input_tokens: agent_input_tokens + token_delta.input_tokens,
        agent_output_tokens: agent_output_tokens + token_delta.output_tokens,
        agent_total_tokens: agent_total_tokens + token_delta.total_tokens,
        agent_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        agent_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        agent_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_started_input_tokens:
          turn_started_input_for_update(
            Map.get(running_entry, :turn_started_input_tokens, 0),
            agent_input_tokens + token_delta.input_tokens,
            running_entry.session_id,
            update
          ),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        recent_agent_updates:
          append_recent_agent_update(
            Map.get(running_entry, :recent_agent_updates, []),
            summarize_agent_update(update)
          )
      }),
      token_delta
    }
  end

  @spec summarize_agent_update(map()) :: map()
  def summarize_agent_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  @spec append_recent_agent_update(term(), map()) :: list(map())
  def append_recent_agent_update(existing, summarized_update) when is_list(existing) do
    (existing ++ [summarized_update])
    |> Enum.take(-12)
  end

  def append_recent_agent_update(_existing, summarized_update), do: [summarized_update]

  @spec agent_process_id_for_update(term(), map()) :: term()
  def agent_process_id_for_update(_existing, %{agent_process_id: pid})
      when is_binary(pid),
      do: pid

  def agent_process_id_for_update(_existing, %{agent_process_id: pid})
      when is_integer(pid),
      do: Integer.to_string(pid)

  def agent_process_id_for_update(_existing, %{agent_process_id: pid}) when is_list(pid),
    do: to_string(pid)

  def agent_process_id_for_update(existing, _update), do: existing

  @spec session_id_for_update(term(), map()) :: term()
  def session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  def session_id_for_update(existing, _update), do: existing

  @spec turn_count_for_update(term(), term(), map()) :: non_neg_integer()
  def turn_count_for_update(existing_count, existing_session_id, %{
        event: :session_started,
        session_id: session_id
      })
      when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  def turn_count_for_update(existing_count, _existing_session_id, _update)
      when is_integer(existing_count),
      do: existing_count

  def turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  @spec turn_started_input_for_update(term(), integer(), term(), map()) :: non_neg_integer()
  def turn_started_input_for_update(_existing, current_total, _existing_session_id, %{
        event: :session_started,
        session_id: _session_id
      })
      when is_integer(current_total) do
    current_total
  end

  def turn_started_input_for_update(existing, _current_total, _existing_session_id, _update)
      when is_integer(existing),
      do: existing

  def turn_started_input_for_update(_existing, _current_total, _existing_session_id, _update),
    do: 0

  # ---------------------------------------------------------------------------
  # apply_agent_token_delta / apply_agent_rate_limits
  # ---------------------------------------------------------------------------

  @spec apply_agent_token_delta(map(), map()) :: map()
  def apply_agent_token_delta(
        %{agent_totals: agent_totals} = state,
        %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
      )
      when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
  end

  def apply_agent_token_delta(state, _token_delta), do: state

  @spec apply_agent_rate_limits(term(), map()) :: term()
  def apply_agent_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | agent_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  def apply_agent_rate_limits(state, _update), do: state

  # ---------------------------------------------------------------------------
  # apply_token_delta
  # ---------------------------------------------------------------------------

  @spec apply_token_delta(map(), map()) :: map()
  def apply_token_delta(agent_totals, token_delta) do
    input_tokens = Map.get(agent_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(agent_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(agent_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(agent_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  # ---------------------------------------------------------------------------
  # extract_token_delta / compute_token_delta
  # ---------------------------------------------------------------------------

  @spec extract_token_delta(map() | nil, map()) :: map()
  def extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :agent_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :agent_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :agent_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  @spec compute_token_delta(map(), atom(), map(), atom()) :: map()
  def compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  # ---------------------------------------------------------------------------
  # extract_token_usage / extract_rate_limits
  # ---------------------------------------------------------------------------

  @spec extract_token_usage(map()) :: map()
  def extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      Enum.find_value(payloads, &direct_token_usage_from_payload/1) ||
      %{}
  end

  @spec extract_rate_limits(map()) :: map() | nil
  def extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  # ---------------------------------------------------------------------------
  # Payload introspection helpers
  # ---------------------------------------------------------------------------

  @spec absolute_token_usage_from_payload(term()) :: map() | nil
  def absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  def absolute_token_usage_from_payload(_payload), do: nil

  @spec turn_completed_usage_from_payload(term()) :: map() | nil
  def turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  def turn_completed_usage_from_payload(_payload), do: nil

  @spec direct_token_usage_from_payload(term()) :: map() | nil
  def direct_token_usage_from_payload(payload) when is_map(payload) do
    if integer_token_map?(payload), do: payload
  end

  def direct_token_usage_from_payload(_payload), do: nil

  @spec rate_limits_from_payload(term()) :: map() | nil
  def rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  def rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  def rate_limits_from_payload(_payload), do: nil

  @spec rate_limit_payloads(term()) :: map() | nil
  def rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  def rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  @spec rate_limits_map?(term()) :: boolean()
  def rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  def rate_limits_map?(_payload), do: false

  @spec explicit_map_at_paths(term(), list()) :: map() | nil
  def explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  def explicit_map_at_paths(_payload, _paths), do: nil

  @spec map_at_path(term(), list()) :: term()
  def map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  def map_at_path(_payload, _path), do: nil

  @spec integer_token_map?(term()) :: boolean()
  def integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    Enum.any?(token_fields, fn field ->
      !is_nil(payload_get(payload, field))
    end)
  end

  @spec get_token_usage(map(), atom()) :: non_neg_integer() | nil
  def get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  def get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  def get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  @spec payload_get(term(), list() | term()) :: non_neg_integer() | nil
  def payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  def payload_get(payload, field), do: map_integer_value(payload, field)

  @spec map_integer_value(term(), term()) :: non_neg_integer() | nil
  def map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  @spec running_seconds(term(), term()) :: non_neg_integer()
  def running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  def running_seconds(_started_at, _now), do: 0

  @spec integer_like(term()) :: non_neg_integer() | nil
  def integer_like(value) when is_integer(value) and value >= 0, do: value

  def integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  def integer_like(_value), do: nil
end
