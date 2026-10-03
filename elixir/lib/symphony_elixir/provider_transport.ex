defmodule SymphonyElixir.ProviderTransport do
  @moduledoc false
  alias SymphonyElixir.{AgentExecution, OwnedHook, RunLedger}
  require Logger

  @limit 1_048_576
  @chunk 16_384
  @cleanup_budget 3_000

  defmodule Error do
    defexception [:phase, :reason]
    @impl true
    def message(_error), do: "Selected provider transport failed."
  end

  @type handle :: {:owned_provider, pid(), pid(), reference(), integer()}

  @spec open(Path.t(), map(), map()) :: {:ok, handle(), map()} | {:error, term()}
  def open(workspace, %{provider: provider, command: command, started_at: started_at}, selection) when provider in ["codex", "claude", "codex-cli"] do
    deadline = min(started_at, now()) + selection.timeout_ms

    with {:ok, audit} <- capture_audit_context(),
         {:ok, handle, identity} <- OwnedHook.prepare_stream(workspace, selection, command, deadline) do
      state = %{
        identity: identity,
        queue: :queue.new(),
        size: 0,
        buffer: "",
        closed: nil,
        serial: 0,
        started_at: started_at,
        selection: selection,
        provider: provider,
        operation_id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
        attribution: audit.attribution,
        ledger_path: audit.ledger_path,
        start_event: nil,
        audit_closed: false
      }

      put(handle, state)

      case record(handle, "execution.boundary.started", %{operation: "provider_process"}) do
        {:ok, event} ->
          put(handle, %{get(handle) | start_event: event.event_id})
          :ok = OwnedHook.stream_control(handle, "G" <> Integer.to_string(max(deadline - now(), 0)))

          case await_started(handle) do
            :ok -> {:ok, handle, identity}
            {:error, _} = primary -> combine_failure(primary, close(handle))
          end

        {:error, error} ->
          combine_failure({:error, error}, close(handle))
      end
    else
      {:error, {:provider_cleanup_uncertain, _}} = error -> preserve_close_failure(error)
      {:error, _} = error -> error
    end
  end

  @spec command(handle(), binary()) :: :ok | {:error, term()}
  def command({:owned_provider, _pid, caller, _ref, _deadline} = handle, data) when caller == self() and is_binary(data) do
    cond do
      get(handle).closed != nil -> {:error, :provider_closed}
      now() >= deadline(handle) -> {:error, :provider_deadline}
      byte_size(data) > @limit -> {:error, :provider_input_limit}
      data == "" -> :ok
      true -> write_chunks(handle, data)
    end
  end

  def command(_handle, _data), do: {:error, :foreign_stream_owner}

  @spec command!(handle(), binary()) :: :ok
  def command!(handle, bytes) do
    case command(handle, bytes) do
      :ok -> :ok
      {:error, reason} -> raise Error, phase: :write, reason: reason
    end
  end

  @spec recv(handle(), non_neg_integer()) :: term()
  def recv({:owned_provider, _pid, caller, _ref, _deadline} = handle, timeout) when caller == self() do
    if now() >= deadline(handle) and get(handle).closed == nil do
      OwnedHook.stream_control(handle, "T")
      {:transport_error, :provider_deadline}
    else
      read_line(handle, now() + timeout)
    end
  end

  @spec close(handle()) :: :ok | {:error, term()}
  def close({:owned_provider, _pid, caller, _ref, _deadline} = handle) when caller == self() do
    if get(handle).closed == nil, do: OwnedHook.stream_control(handle, if(now() >= deadline(handle), do: "T", else: "C"))
    result = await_close(handle, now() + @cleanup_budget)
    put(handle, %{get(handle) | queue: :queue.new(), size: 0, buffer: ""})
    result
  end

  def close(_handle), do: {:error, :foreign_stream_owner}

  @spec metadata(handle()) :: %{child: pos_integer(), pgid: pos_integer(), helper: pos_integer()}
  def metadata({:owned_provider, _pid, caller, _ref, _deadline} = handle) when caller == self(), do: get(handle).identity

  @doc false
  @spec with_cleanup((-> term()), (-> term())) :: term()
  def with_cleanup(work, cleanup) do
    primary = capture(work)
    secondary = capture(cleanup)

    cond do
      secondary == {:returned, :ok} or secondary == primary ->
        restore(primary)

      retained?(primary) and match?({:returned, {:stop, {:execution_stopped, _}}}, secondary) ->
        restore(primary)

      retained?(primary) ->
        Logger.error("Provider cleanup failed " <> inspect(%{primary: diagnostic(primary), cleanup: diagnostic(secondary)}))
        restore(primary)

      true ->
        restore(secondary)
    end
  end

  defp capture(fun) do
    {:returned, fun.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp restore({:returned, value}), do: value
  defp restore({:raised, kind, reason, stack}), do: :erlang.raise(kind, reason, stack)
  defp retained?({:raised, _, _, _}), do: true
  defp retained?({:returned, {tag, _}}) when tag in [:stop, :done, :error], do: true
  defp retained?(_outcome), do: false
  defp diagnostic({:returned, {tag, reason}}), do: %{kind: tag, cause: reason_tag(reason)}
  defp diagnostic({:returned, _healthy}), do: %{kind: :returned}

  defp diagnostic({:raised, kind, reason, stack}) do
    frames =
      Enum.take(stack, 8)
      |> Enum.map(fn
        {module, fun, arity, location} when is_atom(module) and is_atom(fun) and (is_integer(arity) or is_list(arity)) ->
          {module, fun, if(is_list(arity), do: length(arity), else: arity), Keyword.get(location, :line)}

        _frame ->
          :frame
      end)

    %{kind: kind, cause: reason_tag(reason), stack: frames}
  end

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(%{__struct__: module}), do: module
  defp reason_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: reason_tag(elem(reason, 0))
  defp reason_tag(_reason), do: :details_retained_in_primary_outcome

  defp write_chunks(_handle, ""), do: :ok

  defp write_chunks(handle, bytes) do
    size = min(byte_size(bytes), @chunk)
    <<chunk::binary-size(size), rest::binary>> = bytes
    state = get(handle)
    serial = state.serial + 1
    put(handle, %{state | serial: serial})
    :ok = OwnedHook.stream_control(handle, <<"I", serial::unsigned-big-32, chunk::binary>>)
    with :ok <- await_written(handle, serial), do: write_chunks(handle, rest)
  end

  defp await_started(handle) do
    case wait(handle, deadline(handle)) do
      :started -> :ok
      {:closed, result} -> transport_failure(result)
      {:error, _} = error -> error
      _unexpected -> abort(handle, :unexpected_start_packet)
    end
  end

  defp await_written(handle, serial) do
    case wait(handle, deadline(handle)) do
      {:written, ^serial} ->
        :ok

      {:chunk, stream, bytes} ->
        with :ok <- enqueue(handle, stream, bytes), do: await_written(handle, serial)

      {:closed, result} ->
        transport_failure(result)

      {:error, _} = error ->
        error

      _unexpected ->
        abort(handle, :invalid_write_ack)
    end
  end

  defp read_line(handle, read_deadline) do
    state = get(handle)

    case :binary.match(state.buffer, "\n") do
      {index, 1} when index < @limit ->
        <<line::binary-size(index), "\n", rest::binary>> = state.buffer
        put(handle, %{state | buffer: rest})
        {:data, {:eol, line}}

      _line when byte_size(state.buffer) >= @limit ->
        <<part::binary-size(@limit), rest::binary>> = state.buffer
        put(handle, %{state | buffer: rest})
        {:data, {:noeol, part}}

      :nomatch ->
        next_chunk(handle, read_deadline)
    end
  end

  defp next_chunk(handle, read_deadline) do
    state = get(handle)

    case :queue.out(state.queue) do
      {{:value, {stream, bytes}}, queue} ->
        put(handle, %{state | queue: queue, size: state.size - byte_size(bytes)})
        consume_chunk(handle, stream, bytes, read_deadline)

      {:empty, _queue} when state.closed != nil ->
        if state.buffer != "" do
          put(handle, %{state | buffer: ""})
          {:data, {:noeol, state.buffer}}
        else
          closed_event(state.closed)
        end

      {:empty, _queue} ->
        case wait(handle, min(read_deadline, deadline(handle))) do
          {:chunk, stream, bytes} ->
            :ok = OwnedHook.stream_control(handle, "A")
            consume_chunk(handle, stream, bytes, read_deadline)

          {:closed, _result} ->
            next_chunk(handle, read_deadline)

          {:error, :receive_timeout} ->
            if deadline(handle) <= read_deadline do
              OwnedHook.stream_control(handle, "T")
              {:transport_error, :provider_deadline}
            else
              :timeout
            end

          {:error, reason} ->
            {:transport_error, reason}

          _unexpected ->
            abort(handle, :unexpected_stream_packet)
            {:transport_error, :unexpected_stream_packet}
        end
    end
  end

  defp consume_chunk(handle, :stdout, bytes, read_deadline) do
    state = get(handle)
    put(handle, %{state | buffer: state.buffer <> bytes})
    read_line(handle, read_deadline)
  end

  defp consume_chunk(_handle, :stderr, bytes, _read_deadline), do: {:stderr, bytes}

  # While a request is being written, output must drain without invoking usage or
  # tool callbacks early. Retain its exact order for recv/2, with a hard byte cap.
  defp enqueue(handle, stream, bytes) do
    state = get(handle)

    if state.size + byte_size(state.buffer) + byte_size(bytes) <= @limit do
      put(handle, %{state | queue: :queue.in({stream, bytes}, state.queue), size: state.size + byte_size(bytes)})
      OwnedHook.stream_control(handle, "A")
    else
      abort(handle, :provider_output_limit)
    end
  end

  defp wait({:owned_provider, owner, _caller, _ref, _deadline} = handle, limit) do
    monitor = Process.monitor(owner)

    result =
      receive do
        {^handle, {:closed, result}} ->
          {:closed, remember_closed(handle, result)}

        {^handle, event} ->
          event

        {:EXIT, sender, :shutdown} when is_pid(sender) ->
          OwnedHook.stream_control(handle, "C")
          exit(:shutdown)

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          {:closed, remember_closed(handle, {:error, {:provider_cleanup_uncertain, :custodian_down}})}
      after
        max(limit - now(), 0) -> {:error, :receive_timeout}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp await_close(handle, limit) do
    case get(handle).closed do
      nil ->
        case wait(handle, limit) do
          {:closed, _result} -> await_close(handle, limit)
          {:error, :receive_timeout} -> remember_closed(handle, {:error, {:provider_cleanup_uncertain, :close_deadline}})
          _drained -> await_close(handle, limit)
        end

      {:ok, _receipt} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp remember_closed(handle, physical) do
    result = finish_audit(handle, physical)
    put(handle, %{get(handle) | closed: result})
    preserve_close_failure(result)
  end

  # This runs in the admitted caller, after physical cleanup and its checked
  # evidence attempt. A previous owner/worker terminal wins. Only a confirmed
  # current invocation can latch a new cause; the physical error stays visible.
  defp preserve_close_failure({:error, reason} = original) do
    Logger.error("Selected provider close failed cause=" <> inspect(reason_tag(reason)))

    case AgentExecution.current_context() do
      {:ok, _context} ->
        case AgentExecution.ensure_current() do
          {:ok, _snapshot} -> AgentExecution.fail({:provider_close_failed, reason})
          {:stop, _} = terminal -> terminal
        end

      {:error, :execution_context_missing} ->
        :ok
    end

    original
  end

  defp preserve_close_failure({:ok, _receipt} = result), do: result

  defp closed_event({:ok, %{failure: nil, receipt: %{trigger: 0, status: status}}}), do: {:exit_status, status}
  defp closed_event({:ok, %{receipt: %{trigger: 1}}}), do: {:transport_error, :provider_deadline}
  defp closed_event({:ok, %{failure: failure, receipt: receipt}}), do: {:transport_error, {:provider_interrupted, failure, receipt.trigger}}
  defp closed_event({:error, reason}), do: {:transport_error, reason}

  defp transport_failure(result) do
    case closed_event(result) do
      {:transport_error, reason} -> {:error, reason}
      {:exit_status, status} -> {:error, {:provider_exited_during_request, status}}
    end
  end

  defp abort(handle, reason) do
    OwnedHook.stream_control(handle, "C")
    {:error, reason}
  end

  defp finish_audit(handle, primary) do
    state = get(handle)

    if state.audit_closed or is_nil(state.start_event) do
      primary
    else
      put(handle, %{state | audit_closed: true})

      metadata =
        case primary do
          {:ok, %{receipt: receipt, failure: failure}} ->
            %{trigger: receipt.trigger, exit_status: receipt.status, certain: receipt.certain, native_phase: receipt.phase, native_errno: receipt.reason, failure: safe_tag(failure)}

          {:error, _} ->
            %{certain: 0, failure: "cleanup_uncertain"}
        end

      case record(handle, "execution.boundary.finished", Map.put(metadata, :started_event_id, state.start_event)) do
        {:ok, _event} -> primary
        {:error, error} -> {:error, {:provider_audit_failed, primary, error}}
      end
    end
  end

  defp record(handle, event, extra) do
    state = get(handle)

    attrs =
      Map.merge(state.attribution, %{
        actor_type: "runtime",
        actor_id: "provider_transport",
        metadata:
          Map.merge(
            %{
              operation_id: state.operation_id,
              provider: state.provider,
              backend: "macos_deny_default_v1",
              protocol_version: 2,
              policy_sha256: state.selection.sha256,
              child_pid: state.identity.child,
              process_group: state.identity.pgid,
              helper_pid: state.identity.helper,
              duration_ms: max(now() - state.started_at, 0)
            },
            extra
          )
      })

    with {:ok, prepared} <- RunLedger.prepare_entry(event, attrs) do
      RunLedger.CheckedStorage.persist(prepared, state.ledger_path)
    end
  end

  defp capture_audit_context do
    case AgentExecution.current_context() do
      {:ok, %{ticket: ticket, issue_id: id}} ->
        {:ok, %{ledger_path: ticket.ledger_path, attribution: %{issue_id: id, run_id: ticket.run_id, dispatch_id: ticket.dispatch_id}}}

      {:error, :execution_context_missing} ->
        with {:ok, path} <- RunLedger.ledger_file_path_checked(),
             do: {:ok, %{ledger_path: path, attribution: %{}}}
    end
  end

  defp combine_failure(primary, :ok), do: primary
  defp combine_failure(primary, {:error, cleanup}), do: {:error, {:provider_start_cleanup_failed, primary, cleanup}}
  defp safe_tag(nil), do: nil
  defp safe_tag(value) when is_atom(value), do: Atom.to_string(value)
  defp deadline({:owned_provider, _, _, _, deadline}), do: deadline
  defp now, do: System.monotonic_time(:millisecond)
  defp get(handle), do: Process.get({__MODULE__, handle}) || raise(Error, phase: :ownership, reason: :unknown_stream)
  defp put(handle, state), do: Process.put({__MODULE__, handle}, state)
end
