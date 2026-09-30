defmodule SymphonyElixir.AgentExecution do
  @moduledoc """
  Accounting context for one admitted worker and its live provider sessions.

  The worker owns the scoped context and the opaque session handles. The owner
  authenticates every context against its running entry and uses the pure registry
  functions below to propose usage changes. It commits those changes only after
  the corresponding durable checkpoint succeeds. This module creates no process,
  storage, identity or fallback admission.
  """

  alias SymphonyElixir.{DispatchAudit, RunStateStore}

  @context_key {__MODULE__, :context}
  @max_live 2
  @max_total 64
  @confirmation_timeout 5_000
  @zero %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  @dimensions [:input_tokens, :output_tokens, :total_tokens]
  @thread_paths [[:params, :msg, :payload, :info, :total_token_usage], [:params, :msg, :info, :total_token_usage], [:params, :tokenUsage, :total], [:tokenUsage, :total]]
  @input_keys [:input_tokens, :prompt_tokens, :inputTokens, :promptTokens]
  @output_keys [:output_tokens, :completion_tokens, :outputTokens, :completionTokens]
  @total_keys [:total_tokens, :totalTokens, :total]
  @usage_keys [:usage, :tokenUsage, :total_token_usage, :last_token_usage, :total_tokens, :totalTokens] ++ @input_keys ++ @output_keys

  @type counters :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), total_tokens: non_neg_integer()}
  @type binding :: {module(), :session | :thread, String.t()}
  @type context :: %{ticket: DispatchAudit.ticket(), lease_token: map(), owner: pid(), worker: pid(), issue_id: String.t()}
  @type invocation :: %{context: context(), binding: binding() | nil, ordinal: non_neg_integer()}
  @type terminal :: {:stop, {:accounting_uncertain, term()}}
  @type registry :: %{live: map(), retired: %{optional(binding()) => true}, retired_usage: counters(), current: binding() | nil, ordinal: non_neg_integer(), uncertain: term() | nil}
  @type observation :: :no_usage | {:ok, :thread_absolute | :invocation_absolute, counters()}

  @spec with_context(DispatchAudit.ticket(), map(), pid(), (-> result)) :: result | terminal() when result: var
  def with_context(ticket, token, owner, fun) when is_pid(owner) and is_function(fun, 0) do
    with nil <- Process.get(@context_key),
         {:ok, ^ticket} <- DispatchAudit.current_ticket(),
         :ok <- validate_context_token(ticket, token) do
      context = %{ticket: ticket, lease_token: token, owner: owner, worker: self(), issue_id: token.storage.issue_id}
      Process.put(@context_key, %{context: context, registry: new_registry(), handles: %{}})

      try do
        result = fun.()

        case Process.get(@context_key).registry.uncertain do
          nil -> result
          cause -> {:stop, {:accounting_uncertain, cause}}
        end
      after
        Process.delete(@context_key)
      end
    else
      {:error, reason} -> {:stop, {:accounting_uncertain, reason}}
      {:ok, _other_ticket} -> {:stop, {:accounting_uncertain, :dispatch_context_mismatch}}
      %{context: _context} -> fail(:execution_context_already_present)
    end
  end

  @spec current_context() :: {:ok, context()} | {:error, :execution_context_missing}
  def current_context do
    case Process.get(@context_key) do
      %{context: context} -> {:ok, context}
      nil -> {:error, :execution_context_missing}
    end
  end

  @doc "Requires captured authority for identified entries while preserving direct legacy entry."
  @spec entry_context(Path.t(), map() | String.t() | nil) :: {:ok, :legacy | context()} | terminal()
  def entry_context(workspace, issue) when is_binary(workspace) do
    case worker_state() do
      {:ok, state} ->
        with {:ok, ticket} <- DispatchAudit.current_ticket(),
             true <- (ticket == state.context.ticket and Path.expand(workspace) == ticket.workspace) or {:error, :execution_context_mismatch},
             {:ok, snapshot} <- RunStateStore.load(workspace),
             true <- (snapshot[:run_id] == ticket.run_id and snapshot[:issue_id] == state.context.issue_id) or {:error, :execution_snapshot_mismatch},
             :ok <- matching_entry_issue(issue, snapshot),
             :ok <- confirm_current_invocation() do
          {:ok, state.context}
        else
          {:error, reason} -> fail(reason)
          {:stop, _} = terminal -> terminal
        end

      {:error, :execution_context_missing} ->
        legacy_entry_context(workspace)

      {:error, reason} ->
        fail(reason)
    end
  end

  @doc "Confirms the scoped invocation before a hook or continuation without a captured callback."
  @spec confirm_current_invocation() :: :ok | terminal()
  def confirm_current_invocation do
    with {:ok, state} <- worker_state() do
      confirm_invocation(current_invocation(state))
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp matching_entry_issue(nil, _snapshot), do: :ok

  defp matching_entry_issue(%{id: id, identifier: identifier}, snapshot) do
    if id == snapshot[:issue_id] and identifier == snapshot[:issue_identifier],
      do: :ok,
      else: {:error, :execution_issue_mismatch}
  end

  defp matching_entry_issue(_issue, _snapshot), do: {:error, :execution_issue_mismatch}

  defp legacy_entry_context(workspace) do
    case DispatchAudit.current_ticket() do
      {:ok, _ticket} ->
        fail(:execution_context_missing)

      {:error, :dispatch_context_missing} ->
        case RunStateStore.load(workspace) do
          {:ok, snapshot} ->
            if Map.has_key?(snapshot, :run_id), do: fail(:execution_context_missing), else: {:ok, :legacy}

          {:error, :missing} ->
            {:ok, :legacy}

          {:error, reason} ->
            fail(reason)
        end
    end
  end

  @doc "Checks capacity and owner certainty before the caller opens a transport."
  @spec ensure_session_capacity() :: :ok | terminal()
  def ensure_session_capacity do
    with {:ok, state} <- worker_state(),
         :ok <- session_capacity(state.registry),
         :ok <- confirm_invocation(current_invocation(state)) do
      :ok
    else
      {:error, reason} -> fail(reason)
      {:stop, _} = terminal -> terminal
      {:discard, reason} -> fail(reason)
    end
  end

  @doc "Rejects unsupported providers before opening an audited transport."
  @spec ensure_session_capacity(module()) :: :ok | terminal()
  def ensure_session_capacity(provider) do
    with {:ok, _profile} <- provider_profile(provider) do
      ensure_session_capacity()
    else
      {:error, reason} -> fail(reason)
    end
  end

  @doc "Registers only the exact handle returned by a supported provider."
  @spec register_session(module(), map(), :main | :verifier) :: {:ok, binding()} | terminal()
  def register_session(provider, handle, purpose) do
    with {:ok, state} <- worker_state(),
         {:ok, binding} <- session_binding(provider, handle),
         {:ok, registry} <- register_binding(state.registry, binding, purpose),
         :ok <- call_owner(state.context, {:register, binding, purpose}) do
      Process.put(@context_key, %{state | registry: registry, handles: Map.put(state.handles, binding, handle)})
      {:ok, binding}
    else
      {:error, reason} -> fail(reason)
      {:stop, _} = terminal -> terminal
    end
  end

  @doc "Selects a registered handle and starts a new monotonically numbered invocation."
  @spec begin_invocation(binding()) :: {:ok, invocation()} | terminal()
  def begin_invocation(binding) do
    with {:ok, state} <- worker_state(),
         ordinal = state.registry.ordinal + 1,
         {:ok, registry} <- begin_binding(state.registry, binding, ordinal),
         :ok <- call_owner(state.context, {:begin, binding, ordinal}) do
      Process.put(@context_key, %{state | registry: registry})
      {:ok, %{context: state.context, binding: binding, ordinal: ordinal}}
    else
      {:error, reason} -> fail(reason)
      {:stop, _} = terminal -> terminal
    end
  end

  @doc "Checks the exact registered transport before advancing its invocation."
  @spec begin_invocation(module(), map(), binding()) :: {:ok, invocation()} | terminal()
  def begin_invocation(provider, handle, binding) do
    with {:ok, state} <- worker_state(),
         {^provider, _kind, _id} <- binding,
         {:ok, registered_handle} <- Map.fetch(state.handles, binding),
         true <- registered_handle === handle do
      begin_invocation(binding)
    else
      {:error, reason} -> fail(reason)
      _mismatch -> fail(:execution_handle_mismatch)
    end
  end

  @doc "Retires a stopped transport after confirming its last observation."
  @spec retire_session(binding()) :: :ok | terminal()
  def retire_session(binding) do
    with {:ok, state} <- worker_state(),
         :ok <- confirm_invocation(current_invocation(state)),
         {:ok, registry} <- retire_binding(state.registry, binding),
         :ok <- call_owner(state.context, {:retire, binding, state.registry.ordinal}) do
      Process.put(@context_key, %{state | registry: registry, handles: Map.delete(state.handles, binding)})
      :ok
    else
      {:error, reason} -> fail(reason)
      {:stop, _} = terminal -> terminal
      {:discard, reason} -> fail(reason)
    end
  end

  @spec guard_invocation(invocation()) :: :ok | {:discard, atom()} | terminal()
  def guard_invocation(%{context: %{worker: worker}}) when worker != self(), do: {:discard, :foreign_worker}

  def guard_invocation(%{context: context, binding: binding, ordinal: ordinal}) do
    case worker_state() do
      {:ok, %{context: ^context, registry: registry}} ->
        if registry.current == binding and registry.ordinal == ordinal and (is_nil(binding) or Map.has_key?(registry.live, binding)),
          do: :ok,
          else: {:discard, :obsolete_invocation}

      {:ok, _other_context} ->
        {:discard, :execution_context_changed}

      {:error, {:accounting_uncertain, cause}} ->
        {:stop, {:accounting_uncertain, cause}}

      {:error, reason} ->
        {:stop, {:accounting_uncertain, reason}}
    end
  end

  @spec confirm_invocation(invocation()) :: :ok | {:discard, atom()} | terminal()
  def confirm_invocation(invocation) do
    with :ok <- guard_invocation(invocation) do
      call_owner(invocation.context, {:confirm, invocation.binding, invocation.ordinal})
    end
  end

  @doc "Checks a canonical provider result before the runtime consumes it."
  @spec confirm_invocation(invocation(), map()) :: :ok | {:discard, atom()} | terminal()
  def confirm_invocation(invocation, result) when is_map(result) do
    with :ok <- guard_invocation(invocation),
         :ok <- validate_runtime_identity(invocation.binding, result) do
      confirm_invocation(invocation)
    else
      {:error, reason} -> fail(reason)
      other -> other
    end
  end

  @doc "Observes raw usage before an adapter normalizes it or returns to its provider."
  @spec observe_usage(invocation(), map()) :: :ok | {:discard, atom()} | terminal()
  def observe_usage(%{binding: {provider, _kind, _id}} = invocation, payload) do
    with :ok <- guard_invocation(invocation),
         {:ok, profile} <- provider_profile(provider),
         :ok <- validate_raw_identity(invocation.binding, payload),
         observation when observation == :no_usage or elem(observation, 0) == :ok <- classify_usage(profile, payload) do
      if observation != :no_usage do
        send(invocation.context.owner, {:agent_execution_usage, invocation, observation})
      end

      confirm_invocation(invocation)
    else
      {:error, reason} -> fail(reason)
      other -> other
    end
  end

  @doc "Sends an authenticated runtime update; provider data cannot replace its envelope."
  @spec forward_update(invocation(), map()) :: :ok | {:discard, atom()} | terminal()
  def forward_update(invocation, update) when is_map(update) do
    with :ok <- guard_invocation(invocation),
         :ok <- validate_runtime_identity(invocation.binding, update) do
      send(invocation.context.owner, {:agent_worker_update, invocation, update})
      confirm_invocation(invocation)
    else
      {:error, reason} -> fail(reason)
      other -> other
    end
  end

  @doc "Keeps the first local uncertainty even when a provider catches its callback failure."
  @spec fail(term()) :: terminal()
  def fail({:accounting_uncertain, cause}), do: fail(cause)
  def fail(nil), do: fail(:invalid_uncertainty_cause)

  def fail(cause) do
    case Process.get(@context_key) do
      %{registry: %{uncertain: nil}} = state ->
        registry = mark_uncertain(state.registry, cause)
        Process.put(@context_key, %{state | registry: registry})
        send(state.context.owner, {:agent_execution_uncertain, state.context, cause})
        {:stop, {:accounting_uncertain, cause}}

      %{registry: %{uncertain: previous}} ->
        {:stop, {:accounting_uncertain, previous}}

      nil ->
        {:stop, {:accounting_uncertain, cause}}
    end
  end

  @spec new_registry() :: registry()
  def new_registry, do: %{live: %{}, retired: %{}, retired_usage: @zero, current: nil, ordinal: 0, uncertain: nil}

  @spec session_capacity(registry()) :: :ok | {:error, term()}
  def session_capacity(%{uncertain: cause}) when not is_nil(cause), do: {:error, {:accounting_uncertain, cause}}

  def session_capacity(registry) do
    cond do
      map_size(registry.live) >= @max_live -> {:error, :live_binding_limit}
      map_size(registry.live) + map_size(registry.retired) >= @max_total -> {:error, :dispatch_binding_limit}
      true -> :ok
    end
  end

  @spec register_binding(registry(), binding(), :main | :verifier) :: {:ok, registry()} | {:error, term()}
  def register_binding(registry, {provider, kind, id} = binding, purpose)
      when kind in [:session, :thread] and is_binary(id) and id != "" and purpose in [:main, :verifier] do
    with :ok <- session_capacity(registry),
         {:ok, profile} <- provider_profile(provider),
         true <- kind == binding_kind(profile) or {:error, :invalid_session_binding} do
      cond do
        Map.has_key?(registry.live, binding) or Map.has_key?(registry.retired, binding) ->
          {:error, :binding_identity_reused}

        Enum.any?(registry.live, fn {_key, entry} -> entry.purpose == purpose end) ->
          {:error, :binding_purpose_in_use}

        true ->
          entry = %{purpose: purpose, contribution: @zero, thread: @zero, baseline: @zero, invocation: @zero}
          {:ok, %{registry | live: Map.put(registry.live, binding, entry)}}
      end
    end
  end

  def register_binding(_registry, _binding, _purpose), do: {:error, :invalid_session_binding}

  @spec begin_binding(registry(), binding(), pos_integer()) :: {:ok, registry()} | {:error, term()}
  def begin_binding(%{uncertain: cause}, _binding, _ordinal) when not is_nil(cause), do: {:error, {:accounting_uncertain, cause}}

  def begin_binding(registry, binding, ordinal) do
    case Map.fetch(registry.live, binding) do
      {:ok, entry} when ordinal == registry.ordinal + 1 ->
        entry = %{entry | baseline: entry.contribution, invocation: @zero}
        {:ok, %{registry | live: Map.put(registry.live, binding, entry), current: binding, ordinal: ordinal}}

      {:ok, _entry} ->
        {:error, :invalid_invocation_ordinal}

      :error ->
        {:error, :unknown_session_binding}
    end
  end

  @spec retire_binding(registry(), binding()) :: {:ok, registry()} | {:error, term()}
  def retire_binding(%{uncertain: cause}, _binding) when not is_nil(cause), do: {:error, {:accounting_uncertain, cause}}

  def retire_binding(registry, binding) do
    case Map.pop(registry.live, binding) do
      {nil, _live} ->
        {:error, :unknown_session_binding}

      {entry, live} ->
        {:ok,
         %{
           registry
           | live: live,
             retired: Map.put(registry.retired, binding, true),
             retired_usage: add_counters(registry.retired_usage, entry.contribution),
             current: if(registry.current == binding, do: nil, else: registry.current)
         }}
    end
  end

  @doc "Proposes a per-binding update. The owner must persist before installing the returned registry."
  @spec apply_usage(registry(), binding(), pos_integer(), observation()) :: {:ok, registry(), counters()} | {:error, term()}
  def apply_usage(%{uncertain: cause}, _binding, _ordinal, _observation) when not is_nil(cause), do: {:error, {:accounting_uncertain, cause}}

  def apply_usage(registry, binding, ordinal, observation) do
    with true <- (registry.current == binding and registry.ordinal == ordinal) or {:error, :obsolete_invocation},
         {:ok, entry} <- Map.fetch(registry.live, binding) do
      case observation do
        :no_usage ->
          {:ok, registry, @zero}

        {:ok, scope, counters} when scope in [:thread_absolute, :invocation_absolute] ->
          with :ok <- valid_counters(counters) do
            field = if scope == :thread_absolute, do: :thread, else: :invocation
            observed = max_counters(Map.fetch!(entry, field), counters)
            updated = Map.put(entry, field, observed)
            contribution = max_counters(updated.contribution, max_counters(updated.thread, add_counters(updated.baseline, updated.invocation)))
            delta = Map.new(@dimensions, &{&1, Map.fetch!(contribution, &1) - Map.fetch!(entry.contribution, &1)})
            updated = %{updated | contribution: contribution}
            {:ok, %{registry | live: Map.put(registry.live, binding, updated)}, delta}
          end

        _ ->
          {:error, :invalid_usage_observation}
      end
    else
      :error -> {:error, :unknown_session_binding}
      {:error, _} = error -> error
    end
  end

  @spec total_usage(registry()) :: counters()
  def total_usage(registry), do: Enum.reduce(registry.live, registry.retired_usage, fn {_key, entry}, acc -> add_counters(acc, entry.contribution) end)

  @spec mark_uncertain(registry(), term()) :: registry()
  def mark_uncertain(registry, nil), do: mark_uncertain(registry, :invalid_uncertainty_cause)
  def mark_uncertain(%{uncertain: nil} = registry, cause), do: %{registry | uncertain: cause}
  def mark_uncertain(registry, _cause), do: registry

  @doc "Classifies admitted raw shapes; missing usage differs from null or partial usage."
  @spec classify_usage(:claude_cli | :codex_cli | :app_server, term()) :: observation() | {:error, {:accounting_uncertain, term()}}
  def classify_usage(profile, payload) when profile in [:claude_cli, :codex_cli, :app_server] and is_map(payload) do
    classified = if usage_signal?(payload), do: usage_at_paths(profile, payload), else: :absent

    case classified do
      {:ok, scope, raw} ->
        case normalize_counters(raw) do
          {:ok, counters} -> {:ok, scope, counters}
          {:error, reason} -> {:error, {:accounting_uncertain, reason}}
        end

      :absent ->
        if usage_signal?(payload), do: {:error, {:accounting_uncertain, :unknown_usage_scope}}, else: :no_usage

      {:error, reason} ->
        {:error, {:accounting_uncertain, reason}}
    end
  end

  def classify_usage(_profile, _payload), do: {:error, {:accounting_uncertain, :invalid_usage_payload}}

  defp worker_state do
    case Process.get(@context_key) do
      nil -> {:error, :execution_context_missing}
      %{registry: %{uncertain: nil}} = state -> {:ok, state}
      %{registry: %{uncertain: cause}} -> {:error, {:accounting_uncertain, cause}}
    end
  end

  defp current_invocation(state), do: %{context: state.context, binding: state.registry.current, ordinal: state.registry.ordinal}

  defp call_owner(context, action) do
    response =
      try do
        GenServer.call(context.owner, {:agent_execution, context, action}, @confirmation_timeout)
      catch
        :exit, {:timeout, _call} -> {:error, :owner_confirmation_timeout}
        :exit, {:noproc, _call} -> {:error, :owner_unavailable}
        :exit, _reason -> {:error, :owner_confirmation_exit}
      end

    case response do
      :ok -> :ok
      {:stop, {:accounting_uncertain, cause}} -> fail(cause)
      {:error, cause} -> fail(cause)
      _ -> fail(:invalid_owner_confirmation)
    end
  end

  defp validate_context_token(ticket, %{
         owner: owner,
         epoch: epoch,
         lease_generation: generation,
         acquired_at: acquired_at,
         storage: %{issue_id: id, lease_path: lease_path, ledger_path: ledger_path, ttl_ms: ttl}
       })
       when is_binary(id) and id != "" and is_binary(generation) and generation != "" and is_binary(acquired_at) and
              is_binary(lease_path) and is_binary(ledger_path) and is_integer(ttl) and ttl > 0 do
    if owner == ticket.owner and epoch == ticket.epoch and ledger_path == ticket.ledger_path,
      do: :ok,
      else: {:error, :execution_token_mismatch}
  end

  defp validate_context_token(_ticket, _token), do: {:error, :invalid_execution_token}

  defp binding_kind(:app_server), do: :thread
  defp binding_kind(profile) when profile in [:claude_cli, :codex_cli], do: :session

  defp validate_raw_identity({_provider, :session, _id}, _payload), do: :ok

  defp validate_raw_identity({_provider, :thread, id}, payload) do
    containers = [[], [:params], [:params, :msg], [:params, :msg, :payload], [:params, :msg, :info], [:params, :msg, :payload, :info]]
    paths = for container <- containers, key <- [:thread_id, :threadId], do: container ++ [key]
    validate_identity_paths(payload, paths, id)
  end

  defp validate_runtime_identity({_provider, :session, id}, payload), do: validate_identity_paths(payload, [[:session_id]], id)
  defp validate_runtime_identity({_provider, :thread, id}, payload), do: validate_identity_paths(payload, [[:thread_id], [:threadId]], id)

  defp validate_identity_paths(payload, paths, id) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case identity_at_path(payload, path) do
        :absent -> {:cont, :ok}
        {:ok, ^id} -> {:cont, :ok}
        _other -> {:halt, {:error, :session_identity_mismatch}}
      end
    end)
  end

  defp identity_at_path(value, []), do: {:ok, value}

  defp identity_at_path(value, [key | rest]) when is_map(value) do
    case fetch_key(value, key) do
      {:ok, nested} -> identity_at_path(nested, rest)
      other -> other
    end
  end

  defp identity_at_path(_value, _path), do: :absent

  defp session_binding(provider, session) when is_map(session) do
    with {:ok, profile} <- provider_profile(provider) do
      {kind, field} = if profile == :app_server, do: {:thread, :thread_id}, else: {:session, :session_id}

      case Map.fetch(session, field) do
        {:ok, id} when is_binary(id) and id != "" -> {:ok, {provider, kind, id}}
        _ -> {:error, :invalid_session_identity}
      end
    end
  end

  defp session_binding(_provider, _session), do: {:error, :invalid_session_handle}

  defp provider_profile(SymphonyElixir.AgentProvider.Claude), do: {:ok, :claude_cli}
  defp provider_profile(SymphonyElixir.AgentProvider.CodexCLI), do: {:ok, :codex_cli}
  defp provider_profile(SymphonyElixir.AgentProvider.Codex), do: {:ok, :app_server}
  defp provider_profile(_provider), do: {:error, :unsupported_accounting_provider}

  defp usage_at_paths(:claude_cli, payload), do: classified_path(payload, [[:usage], [:message, :usage]], :invocation_absolute)
  defp usage_at_paths(:codex_cli, payload), do: classified_path(payload, [[:usage]], :invocation_absolute)

  defp usage_at_paths(:app_server, payload) do
    case classified_path(payload, @thread_paths, :thread_absolute) do
      :absent ->
        case fetch_key(payload, :method) do
          {:ok, method} when method in ["turn/completed", :turn_completed] -> classified_path(payload, [[:usage], [:params, :usage]], :invocation_absolute)
          {:error, _} = error -> error
          _ -> :absent
        end

      result ->
        result
    end
  end

  defp classified_path(payload, paths, scope) do
    Enum.reduce_while(paths, :absent, fn path, _acc ->
      case fetch_path(payload, path) do
        :absent -> {:cont, :absent}
        {:ok, usage} -> {:halt, {:ok, scope, usage}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [key | rest]) when is_map(value) do
    case fetch_key(value, key) do
      {:ok, nested} -> fetch_path(nested, rest)
      other -> other
    end
  end

  defp fetch_path(_value, _path), do: {:error, :invalid_usage_shape}

  defp fetch_key(map, key) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, {:ok, value}} -> {:ok, value}
      {{:ok, _left}, {:ok, _right}} -> {:error, :contradictory_usage_keys}
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :absent
    end
  end

  defp normalize_counters(raw) when is_map(raw) do
    with {:ok, input} <- dimension(raw, @input_keys),
         {:ok, output} <- dimension(raw, @output_keys),
         {:ok, total} <- total_dimension(raw, input, output) do
      {:ok, %{input_tokens: input, output_tokens: output, total_tokens: total}}
    end
  end

  defp normalize_counters(_raw), do: {:error, :invalid_usage_shape}

  defp dimension(raw, keys) do
    values = Enum.map(keys, &fetch_key(raw, &1)) |> Enum.reject(&(&1 == :absent)) |> Enum.uniq()

    case values do
      [{:ok, value}] when is_integer(value) and value >= 0 -> {:ok, value}
      [] -> {:error, :missing_usage_dimension}
      _ -> {:error, :invalid_usage_dimension}
    end
  end

  defp total_dimension(raw, input, output) do
    if Enum.all?(@total_keys, &(fetch_key(raw, &1) == :absent)),
      do: {:ok, input + output},
      else: dimension(raw, @total_keys)
  end

  defp usage_signal?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      key in @usage_keys or key in Enum.map(@usage_keys, &Atom.to_string/1) or usage_signal?(value)
    end)
  end

  defp usage_signal?(list) when is_list(list), do: Enum.any?(list, &usage_signal?/1)
  defp usage_signal?(_value), do: false

  defp valid_counters(counters) when is_map(counters) do
    if Enum.sort(Map.keys(counters)) == Enum.sort(@dimensions) and Enum.all?(@dimensions, &(is_integer(Map.fetch!(counters, &1)) and Map.fetch!(counters, &1) >= 0)),
      do: :ok,
      else: {:error, :invalid_usage_counters}
  end

  defp valid_counters(_counters), do: {:error, :invalid_usage_counters}

  defp max_counters(left, right), do: Map.new(@dimensions, &{&1, max(Map.fetch!(left, &1), Map.fetch!(right, &1))})
  defp add_counters(left, right), do: Map.new(@dimensions, &{&1, Map.fetch!(left, &1) + Map.fetch!(right, &1)})
end
