defmodule SymphonyElixir.Observability do
  @moduledoc """
  Central telemetry, span, and metadata helpers for Symphony runtime events.
  """

  require Logger
  require OpenTelemetry.Tracer

  @max_reason_length 1_000
  @ledger_event_mappings %{
    "stage.transition" => [:symphony, :stage, :transition],
    "runtime.stopped" => [:symphony, :runtime, :stopped],
    "runtime.repaired" => [:symphony, :repair, :applied],
    "operator.action" => [:symphony, :operator, :action],
    "policy.decided" => [:symphony, :policy, :decided]
  }

  @spec emit([atom()], map(), map()) :: :ok
  def emit(event_name, measurements \\ %{}, metadata \\ %{})
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event_name, sanitize_measurements(measurements), sanitize_metadata(metadata))
  rescue
    _error -> :ok
  end

  @spec with_span(String.t(), map(), (-> result)) :: result when result: var
  def with_span(name, metadata \\ %{}, fun) when is_binary(name) and is_function(fun, 0) do
    span_attributes = span_attributes(metadata)

    OpenTelemetry.Tracer.with_span name, %{attributes: span_attributes} do
      put_logger_metadata(metadata)
      fun.()
    end
  end

  @spec with_stage(String.t(), map(), (-> result)) :: result when result: var
  def with_stage(stage, metadata, fun)
      when is_binary(stage) and is_map(metadata) and is_function(fun, 0) do
    metadata = Map.put(metadata, :stage, stage)
    start_time = System.monotonic_time()

    emit([:symphony, :stage, :start], %{count: 1}, metadata)

    with_span("symphony.stage." <> stage, metadata, fn ->
      try do
        result = fun.()
        emit_stage_stop(stage, start_time, metadata, result)
        result
      rescue
        error ->
          stacktrace = __STACKTRACE__
          emit_stage_exception(stage, start_time, metadata, error, stacktrace)
          reraise error, stacktrace
      catch
        kind, reason ->
          emit_stage_throw(stage, start_time, metadata, kind, reason, __STACKTRACE__)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end)
  end

  @spec issue_metadata(map() | nil, map() | nil, map()) :: map()
  def issue_metadata(issue, state \\ %{}, extra \\ %{}) do
    issue = issue || %{}
    state = state || %{}

    %{
      issue_id: get_value(issue, :id),
      issue_identifier: get_value(issue, :identifier),
      issue_source: get_value(issue, :source) || Map.get(state, :issue_source),
      source: get_value(issue, :source) || Map.get(state, :issue_source),
      stage: Map.get(state, :stage),
      policy_class: Map.get(state, :effective_policy_class),
      workflow_profile: Map.get(state, :effective_policy_class),
      operating_mode: Map.get(state, :operating_mode) || SymphonyElixir.Config.company_mode(),
      company: SymphonyElixir.Config.company_name(),
      repo: SymphonyElixir.Config.company_repo_url()
    }
    |> Map.merge(extra)
    |> sanitize_metadata()
  end

  @spec emit_ledger_event(String.t(), map()) :: :ok
  def emit_ledger_event(event_type, entry) when is_binary(event_type) and is_map(entry) do
    metadata =
      entry
      |> Map.take([
        :event_id,
        :issue_id,
        :issue_identifier,
        :stage,
        :actor_type,
        :actor_id,
        :policy_class,
        :failure_class,
        :rule_id,
        :target_state
      ])
      |> Map.merge(Map.get(entry, :metadata, %{}))

    emit([:symphony, :ledger, :event], %{count: 1}, Map.put(metadata, :event_type, event_type))

    case Map.get(@ledger_event_mappings, event_type) do
      nil -> :ok
      event_name -> emit(event_name, %{count: 1}, Map.put(metadata, :event_type, event_type))
    end
  end

  @spec emit_token_delta(map(), map(), map()) :: :ok
  def emit_token_delta(running_entry, token_delta, update)
      when is_map(running_entry) and is_map(token_delta) and is_map(update) do
    measurements = %{
      input_tokens: Map.get(token_delta, :input_tokens, 0),
      output_tokens: Map.get(token_delta, :output_tokens, 0),
      total_tokens: Map.get(token_delta, :total_tokens, 0),
      count: 1
    }

    if Enum.any?(measurements, fn {key, value} -> key != :count and value > 0 end) do
      metadata =
        issue_metadata(
          Map.get(running_entry, :issue, %{}),
          %{
            stage: Map.get(running_entry, :stage),
            effective_policy_class: Map.get(running_entry, :policy_class),
            issue_source: Map.get(running_entry, :source),
            operating_mode: Map.get(running_entry, :operating_mode)
          },
          %{
            session_id: Map.get(running_entry, :session_id),
            turn_count: Map.get(running_entry, :turn_count),
            codex_event: Map.get(update, :event),
            model_provider: update_usage_value(update, "provider"),
            model_name: update_usage_value(update, "model"),
            reasoning_tier: Map.get(running_entry, :reasoning_tier)
          }
        )

      emit([:symphony, :tokens, :turn], measurements, metadata)
    else
      :ok
    end
  end

  @spec emit_tracker_backoff(:entered | :cleared, map()) :: :ok
  def emit_tracker_backoff(action, metadata) when action in [:entered, :cleared] and is_map(metadata) do
    event =
      case action do
        :entered -> [:symphony, :intake, :tracker, :backoff, :entered]
        :cleared -> [:symphony, :intake, :tracker, :backoff, :cleared]
      end

    emit(event, %{count: 1, retry_after_ms: Map.get(metadata, :retry_after_ms, 0)}, metadata)
  end

  @spec emit_debug_artifact_reference(String.t(), map(), map()) :: :ok
  def emit_debug_artifact_reference(event_type, artifact, metadata)
      when is_binary(event_type) and is_map(artifact) and is_map(metadata) do
    emit(
      [:symphony, :debug, :artifact, :stored],
      %{count: 1, bytes: Map.get(artifact, :bytes, 0)},
      %{
        event_type: event_type,
        artifact_id: Map.get(artifact, :artifact_id),
        artifact_sha256: Map.get(artifact, :sha256),
        artifact_truncated: Map.get(artifact, :truncated, false)
      }
      |> Map.merge(metadata)
    )
  end

  defp emit_stage_stop(stage, start_time, metadata, result) do
    metadata =
      metadata
      |> Map.merge(stage_result_metadata(result))
      |> Map.put(:stage, stage)

    emit([:symphony, :stage, :stop], %{count: 1, duration: System.monotonic_time() - start_time}, metadata)
  end

  defp emit_stage_exception(stage, start_time, metadata, error, stacktrace) do
    metadata =
      metadata
      |> Map.put(:stage, stage)
      |> Map.put(:outcome, "exception")
      |> Map.put(:failure_class, "exception")
      |> Map.put(:error, Exception.message(error))
      |> Map.put(:stacktrace, Exception.format_stacktrace(stacktrace))

    emit([:symphony, :stage, :stop], %{count: 1, duration: System.monotonic_time() - start_time}, metadata)
  end

  defp emit_stage_throw(stage, start_time, metadata, kind, reason, stacktrace) do
    metadata =
      metadata
      |> Map.put(:stage, stage)
      |> Map.put(:outcome, to_string(kind))
      |> Map.put(:failure_class, "throw")
      |> Map.put(:error, truncate_reason(reason))
      |> Map.put(:stacktrace, Exception.format_stacktrace(stacktrace))

    emit([:symphony, :stage, :stop], %{count: 1, duration: System.monotonic_time() - start_time}, metadata)
  end

  defp stage_result_metadata(:ok), do: %{outcome: "ok"}
  defp stage_result_metadata({:done, _issue}), do: %{outcome: "done"}
  defp stage_result_metadata({:skip, _issue}), do: %{outcome: "skip"}
  defp stage_result_metadata({:stop, reason}), do: %{outcome: "stop", error: truncate_reason(reason)}
  defp stage_result_metadata({:error, reason}), do: %{outcome: "error", error: truncate_reason(reason)}
  defp stage_result_metadata(_result), do: %{outcome: "other"}

  defp span_attributes(metadata) when is_map(metadata) do
    metadata
    |> sanitize_metadata()
    |> Enum.map(fn {key, value} ->
      {"symphony." <> normalize_key_name(key), value}
    end)
  end

  defp put_logger_metadata(metadata) when is_map(metadata) do
    metadata =
      metadata
      |> sanitize_metadata()
      |> Enum.filter(fn {_key, value} -> scalar?(value) end)

    Logger.metadata(metadata)
  rescue
    _error -> :ok
  end

  defp sanitize_measurements(measurements) when is_map(measurements) do
    Map.new(measurements, fn {key, value} ->
      normalized =
        cond do
          is_integer(value) -> value
          is_float(value) -> value
          true -> 0
        end

      {key, normalized}
    end)
  end

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> :metadata
      normalized -> existing_atom_or_string(normalized)
    end
  end

  defp normalize_key(key), do: normalize_key(to_string(key))

  defp normalize_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key_name(key) when is_binary(key), do: key
  defp normalize_key_name(key), do: to_string(key)

  # Preserve existing atom keys without creating new ones from untrusted input.
  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_value(value) when is_binary(value), do: String.slice(value, 0, @max_reason_length)
  defp normalize_value(value) when is_integer(value) or is_float(value) or is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_value(value) when is_list(value) do
    value
    |> Enum.map(&normalize_value/1)
    |> Enum.take(20)
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(value), do: value |> inspect(limit: 20, printable_limit: 200) |> String.slice(0, @max_reason_length)

  defp scalar?(value) when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value), do: true
  defp scalar?(_value), do: false

  defp get_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp truncate_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 200)
    |> String.slice(0, @max_reason_length)
  end

  defp update_usage_value(update, key) do
    usage = Map.get(update, :usage) || %{}

    case Map.get(usage, key) do
      nil ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        if is_atom(atom_key), do: Map.get(usage, atom_key), else: nil

      value ->
        value
    end
  end
end
