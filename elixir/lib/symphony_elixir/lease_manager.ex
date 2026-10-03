defmodule SymphonyElixir.LeaseManager do
  @moduledoc """
  Persists per-issue dispatch leases so multiple orchestrators do not double-run the same issue.
  """

  alias SymphonyElixir.{Config, RunLedger, RunnerRuntime}

  @lease_dir "leases"
  @lease_version 2
  @lock_timeout_ms 1_000
  @lock_retry_ms 10

  @spec ttl_ms() :: pos_integer()
  def ttl_ms do
    default_ttl_ms()
  end

  @spec age_ms(map()) :: non_neg_integer() | nil
  def age_ms(lease) when is_map(lease) do
    age_ms(lease, DateTime.utc_now())
  end

  @spec age_ms(map(), DateTime.t()) :: non_neg_integer() | nil
  def age_ms(lease, %DateTime{} = now) when is_map(lease) do
    lease
    |> updated_at_value()
    |> case do
      %DateTime{} = timestamp ->
        max(DateTime.diff(now, timestamp, :millisecond), 0)

      _ ->
        nil
    end
  end

  def age_ms(_lease, _now), do: nil

  @spec reclaimable?(map()) :: boolean()
  def reclaimable?(lease) when is_map(lease) do
    reclaimable?(lease, DateTime.utc_now())
  end

  @spec reclaimable?(map(), DateTime.t()) :: boolean()
  def reclaimable?(lease, %DateTime{} = now) when is_map(lease) do
    reclaimable?(lease, now, [])
  end

  @spec reclaimable?(map(), DateTime.t(), keyword()) :: boolean()
  def reclaimable?(lease, %DateTime{} = now, opts) when is_map(lease) and is_list(opts) do
    ttl = Keyword.get_lazy(opts, :ttl_ms, &ttl_ms/0)

    with true <- is_integer(ttl) and ttl > 0,
         {:ok, normalized} <- normalize_diagnostic_lease(lease),
         false <- Map.has_key?(normalized, "audit_pending"),
         true <- normalized["lease_version"] != @lease_version or (is_binary(normalized["issue_id"]) and normalized["issue_id"] != ""),
         :ok <- validate_lease(normalized, normalized["issue_id"]) do
      stale_lease?(normalized["updated_at"], now, ttl)
    else
      _ -> false
    end
  end

  def reclaimable?(_lease, _now, _opts), do: false

  defp normalize_diagnostic_lease(lease) do
    keys = [:issue_id, :owner, :epoch, :lease_version, :lease_generation, :acquired_at, :updated_at, :audit_pending]

    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, normalized} ->
      string_key = Atom.to_string(key)

      case {Map.fetch(lease, key), Map.fetch(lease, string_key)} do
        {{:ok, value}, {:ok, value}} -> {:cont, {:ok, Map.put(normalized, string_key, value)}}
        {{:ok, _atom_value}, {:ok, _string_value}} -> {:halt, {:error, :contradictory_lease_keys}}
        {{:ok, value}, :error} -> {:cont, {:ok, Map.put(normalized, string_key, value)}}
        {:error, {:ok, value}} -> {:cont, {:ok, Map.put(normalized, string_key, value)}}
        {:error, :error} -> {:cont, {:ok, normalized}}
      end
    end)
  end

  @type storage_context :: %{issue_id: String.t(), lease_path: Path.t(), ledger_path: Path.t(), ttl_ms: pos_integer()}
  @type token :: %{storage: storage_context(), owner: String.t(), epoch: pos_integer(), lease_generation: String.t(), acquired_at: String.t()}
  @type acquired :: %{token: token(), lease: map(), acquisition: :created | :reacquired | :adopted_legacy | :takeover}

  @spec capture_storage(String.t(), keyword()) :: {:ok, storage_context()} | {:error, term()}
  def capture_storage(issue_id, opts \\ []) when is_binary(issue_id) and is_list(opts) do
    ttl = Keyword.get_lazy(opts, :ttl_ms, &default_ttl_ms/0)

    with true <- (is_integer(ttl) and ttl > 0) or {:error, :invalid_lease_ttl},
         {:ok, ledger_path} <- RunLedger.ledger_file_path_checked() do
      storage = %{issue_id: issue_id, lease_path: lease_path_at(ledger_path, issue_id), ledger_path: ledger_path, ttl_ms: ttl}
      with :ok <- validate_storage(storage), do: {:ok, storage}
    end
  end

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(issue_id) when is_binary(issue_id) do
    with {:ok, storage} <- capture_storage(issue_id), do: read_at(storage)
  end

  @spec read_at(storage_context()) :: {:ok, map()} | {:error, term()}
  def read_at(storage) do
    with :ok <- validate_storage(storage),
         {:ok, lease} <- read_lease_file(storage.lease_path),
         :ok <- ensure_audit_complete(lease),
         :ok <- validate_lease(lease, storage.issue_id) do
      {:ok, lease}
    end
  end

  @doc "Holds the physical lease lock while diagnosing missing or expired custody; never acquires, renews or releases it."
  @spec with_inactive(storage_context(), (:missing | {:expired, map(), binary()} -> result)) :: result | {:error, term()} when result: var
  def with_inactive(storage, operation) when is_function(operation, 1) do
    with :ok <- validate_storage(storage) do
      with_lease_lock(storage, fn ->
        case File.lstat(storage.lease_path) do
          {:error, :enoent} ->
            operation.(:missing)

          {:ok, %{type: :regular}} ->
            with {:ok, lease} <- read_at(storage),
                 :ok <- validate_acquirable_legacy(lease, storage.issue_id),
                 true <- stale_lease?(lease["updated_at"], DateTime.utc_now(), storage.ttl_ms) or {:error, :lease_still_active},
                 {:ok, bytes} <- File.read(storage.lease_path),
                 true <- Jason.decode(bytes) == {:ok, lease} or {:error, :lease_observation_changed} do
              operation.({:expired, lease, bytes})
            end

          {:ok, _stat} ->
            {:error, :invalid_lease_path_type}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  @spec snapshot_for_state(map()) :: map()
  def snapshot_for_state(lease) when is_map(lease) do
    %{
      lease_owner: lease["owner"] || lease[:owner],
      lease_owner_instance_id: RunnerRuntime.instance_id(),
      lease_owner_channel: Config.runner_channel(),
      lease_acquired_at: lease["acquired_at"] || lease[:acquired_at],
      lease_updated_at: lease["updated_at"] || lease[:updated_at],
      lease_status: "held",
      lease_epoch: lease["epoch"] || lease[:epoch],
      lease_version: lease["lease_version"] || lease[:lease_version],
      lease_generation: lease["lease_generation"] || lease[:lease_generation]
    }
  end

  @spec acquire(String.t(), String.t() | nil, String.t(), keyword()) :: {:ok, acquired()} | {:error, term()}
  def acquire(issue_id, issue_identifier, owner, opts \\ []) when is_binary(issue_id) and is_binary(owner) do
    with true <- owner != "" or {:error, :invalid_lease_owner},
         {:ok, storage} <- acquisition_storage(issue_id, opts) do
      with_lease_lock(storage, fn -> acquire_locked(storage, issue_identifier, owner, Keyword.get(opts, :expected_token)) end)
    end
  end

  defp acquire_locked(storage, issue_identifier, owner, expected) do
    now = DateTime.utc_now()

    case read_at(storage) do
      {:ok, existing} ->
        with :ok <- expected_acquisition(storage, existing, owner, expected),
             :ok <- validate_acquirable_legacy(existing, storage.issue_id) do
          case acquire_decision(existing, owner, now, storage.ttl_ms) do
            {:ok, epoch, acquired_at} ->
              current = existing["lease_version"] == @lease_version
              generation = if current, do: existing["lease_generation"], else: new_generation()
              payload = lease_payload(storage.issue_id, issue_identifier, owner, now, epoch, acquired_at, generation)
              outcome = if current, do: :reacquired, else: :adopted_legacy
              write_acquired(storage, payload, outcome)

            {:takeover, epoch, acquired_at} ->
              payload = lease_payload(storage.issue_id, issue_identifier, owner, now, epoch, acquired_at, new_generation())
              with :ok <- commit_takeover(storage, payload, previous: existing), do: acquired(storage, payload, :takeover)

            error ->
              error
          end
        end

      {:error, :missing} when is_nil(expected) ->
        payload = lease_payload(storage.issue_id, issue_identifier, owner, now, 1, now, new_generation())
        write_acquired(storage, payload, :created)

      error ->
        error
    end
  end

  @doc "Checks the complete captured token under its physical lock without renewing or adopting the lease."
  @spec ensure_current(token()) :: :ok | {:error, term()}
  def ensure_current(token) do
    with :ok <- validate_token(token) do
      with_lease_lock(token.storage, fn ->
        with {:ok, existing} <- read_at(token.storage),
             :ok <- compare_token(token, existing),
             true <- not stale_lease?(existing["updated_at"], DateTime.utc_now(), token.storage.ttl_ms) or {:error, :lease_expired} do
          :ok
        end
      end)
    end
  end

  @spec refresh_token(token()) :: {:ok, map()} | {:error, term()}
  def refresh_token(token) do
    with :ok <- validate_token(token) do
      with_lease_lock(token.storage, fn ->
        with {:ok, existing} <- read_at(token.storage),
             :ok <- compare_token(token, existing),
             payload = Map.put(existing, "updated_at", DateTime.to_iso8601(DateTime.utc_now())),
             :ok <- write_json_atomically(token.storage.lease_path, payload) do
          {:ok, payload}
        end
      end)
    end
  end

  @spec release_token(token()) :: {:ok, :released | :missing} | {:error, term()}
  def release_token(token) do
    with :ok <- validate_token(token) do
      with_lease_lock(token.storage, fn ->
        case read_at(token.storage) do
          {:ok, existing} ->
            with :ok <- compare_token(token, existing), :ok <- File.rm(token.storage.lease_path), do: {:ok, :released}

          {:error, :missing} ->
            {:ok, :missing}

          error ->
            error
        end
      end)
    end
  end

  @spec activate_dispatch(token(), integer() | :not_pending, pid(), String.t()) :: :ok | {:error, term()}
  def activate_dispatch(token, deadline, worker, dispatch_id) when is_pid(worker) and is_binary(dispatch_id) do
    with :ok <- validate_token(token),
         true <- is_integer(deadline) or deadline == :not_pending or {:error, :invalid_dispatch_deadline} do
      with_lease_lock(token.storage, fn ->
        with {:ok, existing} <- read_at(token.storage),
             :ok <- compare_token(token, existing),
             true <- not stale_lease?(existing["updated_at"], DateTime.utc_now(), token.storage.ttl_ms) or {:error, :lease_expired},
             :ok <- check_dispatch_deadline(deadline) do
          SymphonyElixir.DispatchGate.activate(worker, dispatch_id)
        end
      end)
    end
  end

  @spec refresh(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def refresh(issue_id, owner, opts \\ []) when is_binary(issue_id) and is_binary(owner) do
    with {:ok, storage} <- acquisition_storage(issue_id, opts) do
      with_lease_lock(storage, fn ->
        with {:ok, existing} <- read_at(storage),
             :ok <- legacy_only(existing) do
          if existing["owner"] == owner do
            now = DateTime.utc_now()

            refreshed =
              existing
              |> Map.put("acquired_at", normalize_timestamp(existing["acquired_at"], now))
              |> Map.put("updated_at", DateTime.to_iso8601(now))

            write_json_atomically(storage.lease_path, refreshed)
          else
            {:error, :claimed}
          end
        end
      end)
    end
  end

  @spec release(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def release(issue_id, owner \\ nil) when is_binary(issue_id) do
    with {:ok, storage} <- capture_storage(issue_id) do
      with_lease_lock(storage, fn ->
        case read_at(storage) do
          {:ok, existing} ->
            with :ok <- legacy_only(existing) do
              if is_nil(owner) or existing["owner"] == owner, do: File.rm(storage.lease_path), else: :ok
            end

          {:error, :missing} ->
            :ok

          error ->
            error
        end
      end)
    end
  end

  @doc "Finalizes only an already-confirmed takeover at its captured location. Never writes ledger evidence."
  @spec reconcile_pending_takeover(String.t() | storage_context()) :: :ok | {:error, term()}
  def reconcile_pending_takeover(issue_id) when is_binary(issue_id) do
    with {:ok, storage} <- capture_storage(issue_id), do: reconcile_pending_takeover(storage)
  end

  def reconcile_pending_takeover(storage) when is_map(storage) do
    with :ok <- validate_storage(storage) do
      with_lease_lock(storage, fn ->
        with {:ok, decoded} <- read_lease_file(storage.lease_path),
             {:ok, candidate, pending} <- validate_pending_takeover(decoded, storage.issue_id),
             :ok <- validate_lease(candidate, storage.issue_id),
             true <- storage.ledger_path == pending["ledger_path"] or {:error, :lease_audit_ledger_changed},
             {:ok, intent} <- RunLedger.CheckedStorage.fetch(storage.ledger_path, pending["intent_event_id"]),
             :ok <- validate_takeover_intent(intent, pending["confirmation"]),
             {:ok, recorded} <- RunLedger.CheckedStorage.fetch(storage.ledger_path, pending["confirmation"]["event_id"]),
             true <- recorded == pending["confirmation"] or {:error, :lease_audit_confirmation_mismatch} do
          write_json_atomically(storage.lease_path, candidate)
        end
      end)
    end
  end

  @spec lease_path(String.t()) :: Path.t()
  def lease_path(issue_id) when is_binary(issue_id), do: lease_path_at(Path.expand(RunLedger.ledger_file_path()), issue_id)

  # mkdir provides exclusion between independent OS processes sharing this store.
  # Only the creator removes this directory. A crashed holder leaves an explicit
  # blocking condition; lease TTL must never be used to steal a critical-section lock.
  defp with_lease_lock(storage, operation) do
    lock_path = storage.lease_path <> ".lock"
    deadline = System.monotonic_time(:millisecond) + @lock_timeout_ms

    with :ok <- ensure_lock_parent(lock_path),
         :ok <- acquire_lock(lock_path, deadline) do
      try do
        operation.()
      after
        case File.rmdir(lock_path) do
          :ok ->
            :ok

          {:error, reason} ->
            raise File.Error, reason: reason, action: "release lease lock", path: lock_path
        end
      end
    end
  end

  defp ensure_lock_parent(lock_path) do
    case File.mkdir_p(Path.dirname(lock_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:lease_lock_failed, lock_path, reason}}
    end
  end

  defp acquire_lock(lock_path, deadline) do
    case File.mkdir(lock_path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms > 0 do
          Process.sleep(min(@lock_retry_ms, remaining_ms))
          acquire_lock(lock_path, deadline)
        else
          {:error, {:lease_lock_timeout, lock_path}}
        end

      {:error, reason} ->
        {:error, {:lease_lock_failed, lock_path, reason}}
    end
  end

  defp write_acquired(storage, payload, outcome) do
    with :ok <- write_json_atomically(storage.lease_path, payload), do: acquired(storage, payload, outcome)
  end

  defp acquired(storage, payload, outcome) do
    token = %{storage: storage, owner: payload["owner"], epoch: payload["epoch"], lease_generation: payload["lease_generation"], acquired_at: payload["acquired_at"]}
    {:ok, %{token: token, lease: payload, acquisition: outcome}}
  end

  defp lease_payload(issue_id, issue_identifier, owner, now, epoch, acquired_at, generation) do
    %{
      "issue_id" => issue_id,
      "issue_identifier" => issue_identifier,
      "owner" => owner,
      "lease_version" => @lease_version,
      "lease_generation" => generation,
      "epoch" => epoch,
      "acquired_at" => normalize_timestamp(acquired_at, now),
      "updated_at" => DateTime.to_iso8601(now)
    }
  end

  defp commit_takeover(storage, candidate, previous: previous) do
    path = storage.lease_path
    issue_id = storage.issue_id
    issue_identifier = candidate["issue_identifier"]
    owner = candidate["owner"]
    epoch = candidate["epoch"]
    operation_id = SymphonyElixir.Util.generate_id("lease_op_")
    previous_owner = previous["owner"] || previous[:owner]

    attrs = %{
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      actor_type: "system",
      actor_id: owner,
      failure_class: "coordination",
      rule_id: "coordination.lease_taken_over",
      summary: "Lease was taken over after the previous holder went stale.",
      details: "Previous owner #{inspect(previous_owner)} replaced by #{inspect(owner)}.",
      metadata: %{
        operation_id: operation_id,
        epoch: epoch,
        previous_owner: previous_owner,
        previous_epoch: previous["epoch"] || previous[:epoch] || 1,
        candidate_digest: lease_digest(candidate),
        previous_lease_digest: lease_digest(previous)
      }
    }

    intent_attrs =
      Map.put(attrs, :summary, "Requested lease takeover after the previous holder went stale.")

    with {:ok, intent} <- RunLedger.prepare_entry("lease.takeover.requested", intent_attrs),
         {:ok, confirmation} <- RunLedger.prepare_entry("lease.taken_over", attrs),
         :ok <- audit_step(:intent, operation_id, RunLedger.CheckedStorage.persist(intent, storage.ledger_path)) do
      pending = %{
        operation_id: operation_id,
        ledger_path: storage.ledger_path,
        intent_event_id: intent.event_id,
        confirmation: confirmation,
        previous_lease: previous
      }

      with :ok <-
             audit_step(
               :lease_write,
               operation_id,
               write_json_atomically(path, Map.put(candidate, "audit_pending", pending))
             ),
           :ok <-
             audit_step(:confirmation, operation_id, RunLedger.CheckedStorage.persist(confirmation, storage.ledger_path)),
           :ok <- audit_step(:finalize, operation_id, write_json_atomically(path, candidate)) do
        :ok
      end
    end
  end

  defp audit_step(_phase, _operation_id, :ok), do: :ok
  defp audit_step(_phase, _operation_id, {:ok, _entry}), do: :ok

  defp audit_step(phase, operation_id, {:error, reason}),
    do: {:error, {:lease_takeover_failed, phase, operation_id, reason}}

  defp ensure_audit_complete(%{"audit_pending" => %{"operation_id" => operation_id}})
       when is_binary(operation_id) and operation_id != "",
       do: {:error, {:lease_audit_pending, operation_id}}

  defp ensure_audit_complete(%{"audit_pending" => _}), do: {:error, :invalid_lease_audit_pending}
  defp ensure_audit_complete(_lease), do: :ok

  defp validate_pending_takeover(%{"audit_pending" => pending} = decoded, issue_id)
       when is_map(pending) do
    candidate = Map.delete(decoded, "audit_pending")

    with %{
           "operation_id" => operation_id,
           "ledger_path" => ledger_path,
           "intent_event_id" => intent_id,
           "previous_lease" => %{} = previous,
           "confirmation" => %{
             "event_id" => confirmation_id,
             "event_type" => "lease.taken_over",
             "issue_id" => ^issue_id,
             "actor_id" => owner,
             "metadata" => %{
               "operation_id" => operation_id,
               "epoch" => epoch,
               "previous_epoch" => previous_epoch,
               "previous_owner" => previous_owner,
               "candidate_digest" => candidate_digest,
               "previous_lease_digest" => previous_digest
             }
           }
         } <- pending,
         true <-
           Enum.all?(
             [operation_id, ledger_path, intent_id, confirmation_id, owner],
             &(is_binary(&1) and &1 != "")
           ),
         true <-
           confirmation_id != intent_id and candidate["issue_id"] == issue_id and
             candidate["owner"] == owner,
         true <-
           is_integer(epoch) and is_integer(previous_epoch) and epoch == previous_epoch + 1 and
             candidate["epoch"] == epoch,
         true <-
           previous_owner == previous["owner"] and previous_epoch == (previous["epoch"] || 1),
         true <-
           previous_owner != owner and lease_digest(candidate) == candidate_digest and
             lease_digest(previous) == previous_digest do
      {:ok, candidate, pending}
    else
      _ -> {:error, :invalid_lease_audit_pending}
    end
  end

  defp validate_pending_takeover(%{"audit_pending" => _}, _issue_id),
    do: {:error, :invalid_lease_audit_pending}

  defp validate_pending_takeover(%{}, _issue_id), do: {:error, :no_lease_audit_pending}

  defp validate_takeover_intent(
         %{"event_type" => "lease.takeover.requested"} = intent,
         confirmation
       ) do
    ignored = ["event", "event_type", "event_id", "at", "summary"]

    if Map.drop(intent, ignored) == Map.drop(confirmation, ignored),
      do: :ok,
      else: {:error, :lease_audit_intent_mismatch}
  end

  defp validate_takeover_intent(_intent, _confirmation),
    do: {:error, :lease_audit_intent_mismatch}

  defp lease_digest(payload) do
    canonical =
      payload
      |> Jason.encode!()
      |> Jason.decode!()
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> [key, value] end)
      |> Jason.encode!()

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  defp lease_path_at(ledger_path, issue_id), do: Path.join([Path.dirname(ledger_path), @lease_dir, "#{issue_id}.json"]) |> Path.expand()
  defp new_generation, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp acquisition_storage(issue_id, opts) do
    case Keyword.fetch(opts, :storage) do
      {:ok, storage} ->
        with :ok <- validate_storage(storage),
             true <- storage.issue_id == issue_id or {:error, :lease_storage_mismatch} do
          {:ok, storage}
        end

      :error ->
        capture_storage(issue_id, opts)
    end
  end

  defp validate_storage(%{issue_id: id, lease_path: path, ledger_path: ledger, ttl_ms: ttl})
       when is_binary(id) and id != "" and is_binary(path) and is_binary(ledger) and is_integer(ttl) and ttl > 0 do
    if Path.type(path) == :absolute and Path.type(ledger) == :absolute and
         path == Path.expand(path) and ledger == Path.expand(ledger) and path == lease_path_at(ledger, id) do
      :ok
    else
      {:error, :invalid_lease_storage}
    end
  end

  defp validate_storage(_storage), do: {:error, :invalid_lease_storage}

  defp validate_token(%{storage: storage, owner: owner, epoch: epoch, lease_generation: generation, acquired_at: acquired_at})
       when is_binary(owner) and owner != "" and is_integer(epoch) and epoch > 0 and is_binary(generation) and generation != "" do
    with :ok <- validate_storage(storage), true <- valid_timestamp?(acquired_at) or {:error, :invalid_lease_token}, do: :ok
  end

  defp validate_token(_token), do: {:error, :invalid_lease_token}

  defp compare_token(token, lease) do
    if lease["lease_version"] == @lease_version and lease["issue_id"] == token.storage.issue_id and
         lease["owner"] == token.owner and lease["epoch"] == token.epoch and
         lease["lease_generation"] == token.lease_generation and lease["acquired_at"] == token.acquired_at do
      :ok
    else
      {:error, :lease_token_mismatch}
    end
  end

  defp expected_acquisition(storage, existing, owner, nil) do
    if existing["lease_version"] == @lease_version and existing["owner"] == owner do
      {:error, :lease_token_required}
    else
      validate_lease(existing, storage.issue_id)
    end
  end

  defp expected_acquisition(storage, existing, owner, expected) do
    with :ok <- validate_token(expected), true <- (expected.storage == storage and expected.owner == owner) or {:error, :lease_token_mismatch}, :ok <- compare_token(expected, existing), do: :ok
  end

  defp read_lease_file(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{} = lease} -> {:ok, lease}
          {:ok, _} -> {:error, :invalid_lease}
          error -> error
        end

      {:error, :enoent} ->
        {:error, :missing}

      error ->
        error
    end
  end

  defp validate_lease(%{"lease_version" => @lease_version} = lease, issue_id) do
    if valid_identity_fields?(lease, issue_id) and is_binary(lease["lease_generation"]) and lease["lease_generation"] != "" do
      :ok
    else
      {:error, :invalid_lease}
    end
  end

  defp validate_lease(lease, _issue_id) when is_map(lease) do
    if Map.has_key?(lease, "lease_generation") or Map.get(lease, "lease_version") not in [nil, 1] do
      {:error, :invalid_lease}
    else
      :ok
    end
  end

  defp validate_acquirable_legacy(%{"lease_version" => @lease_version}, _issue_id), do: :ok

  defp validate_acquirable_legacy(lease, issue_id) do
    if valid_identity_fields?(lease, issue_id), do: :ok, else: {:error, :invalid_lease}
  end

  defp valid_identity_fields?(lease, issue_id) do
    lease["issue_id"] == issue_id and is_binary(lease["owner"]) and lease["owner"] != "" and
      is_integer(lease["epoch"]) and lease["epoch"] > 0 and valid_timestamp?(lease["acquired_at"]) and valid_timestamp?(lease["updated_at"])
  end

  defp valid_timestamp?(value) when is_binary(value), do: match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))
  defp valid_timestamp?(_value), do: false
  defp legacy_only(%{"lease_version" => @lease_version}), do: {:error, :lease_token_required}
  defp legacy_only(_legacy), do: :ok

  defp check_dispatch_deadline(:not_pending), do: :ok

  defp check_dispatch_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :dispatch_deadline_expired}
  end

  defp acquire_decision(existing, owner, now, ttl_ms) do
    existing_owner = existing["owner"] || existing[:owner]
    updated_at = existing["updated_at"] || existing[:updated_at]
    acquired_at = existing["acquired_at"] || existing[:acquired_at] || DateTime.to_iso8601(now)
    epoch = existing["epoch"] || existing[:epoch] || 1

    cond do
      existing_owner == owner ->
        {:ok, epoch, acquired_at}

      stale_lease?(updated_at, now, ttl_ms) ->
        {:takeover, epoch + 1, now}

      true ->
        {:error, :claimed}
    end
  end

  defp stale_lease?(%DateTime{} = updated_at, now, ttl_ms), do: DateTime.diff(now, updated_at, :millisecond) > ttl_ms

  defp stale_lease?(updated_at, now, ttl_ms) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, timestamp, _offset} ->
        DateTime.diff(now, timestamp, :millisecond) > ttl_ms

      _ ->
        true
    end
  end

  defp stale_lease?(_updated_at, _now, _ttl_ms), do: true

  defp updated_at_value(lease) when is_map(lease) do
    case lease["updated_at"] || lease[:updated_at] do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, timestamp, _offset} -> timestamp
          _ -> nil
        end

      %DateTime{} = timestamp ->
        timestamp

      _ ->
        nil
    end
  end

  defp normalize_timestamp(%DateTime{} = timestamp, _now), do: DateTime.to_iso8601(timestamp)

  defp normalize_timestamp(timestamp, now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _datetime, _offset} -> timestamp
      _ -> DateTime.to_iso8601(now)
    end
  end

  defp normalize_timestamp(_timestamp, now), do: DateTime.to_iso8601(now)

  defp write_json_atomically(path, payload) when is_binary(path) and is_map(payload) do
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, Jason.encode!(payload), [:write]),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp_path)
        error
    end
  end

  defp default_ttl_ms do
    max(Config.agent_stall_timeout_ms(), max(Config.poll_interval_ms() * 4, 60_000))
  end
end
