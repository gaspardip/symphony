defmodule SymphonyElixir.LeaseManager do
  @moduledoc """
  Persists per-issue dispatch leases so multiple orchestrators do not double-run the same issue.
  """

  alias SymphonyElixir.{Config, RunLedger, RunnerRuntime}

  @lease_dir "leases"
  @lease_version 1
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
    if Map.has_key?(lease, "audit_pending") or Map.has_key?(lease, :audit_pending) do
      false
    else
      ttl_ms = Keyword.get(opts, :ttl_ms, ttl_ms())

      lease
      |> updated_at_value()
      |> stale_lease?(now, ttl_ms)
    end
  end

  def reclaimable?(_lease, _now, _opts), do: false

  @spec read(String.t()) :: {:ok, map()} | {:error, :missing | term()}
  def read(issue_id) when is_binary(issue_id) do
    path = lease_path(issue_id)

    case File.read(path) do
      {:ok, payload} ->
        case Jason.decode(payload) do
          {:ok, %{} = lease} ->
            with :ok <- ensure_audit_complete(lease), do: {:ok, lease}

          {:ok, _other} ->
            {:error, :invalid_lease}

          {:error, _reason} = error ->
            error
        end

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, reason}
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
      lease_epoch: lease["epoch"] || lease[:epoch]
    }
  end

  @spec acquire(String.t(), String.t() | nil, String.t(), keyword()) :: :ok | {:error, term()}
  def acquire(issue_id, issue_identifier, owner, opts \\ [])
      when is_binary(issue_id) and is_binary(owner) do
    with_lease_lock(issue_id, fn -> acquire_locked(issue_id, issue_identifier, owner, opts) end)
  end

  defp acquire_locked(issue_id, issue_identifier, owner, opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, default_ttl_ms())
    now = DateTime.utc_now()
    path = lease_path(issue_id)

    case read(issue_id) do
      {:ok, existing} ->
        case acquire_decision(existing, owner, now, ttl_ms) do
          {:ok, epoch, acquired_at} ->
            write_lease(path, issue_id, issue_identifier, owner, now, epoch, acquired_at)

          {:takeover, epoch, acquired_at} ->
            commit_takeover(
              path,
              issue_id,
              issue_identifier,
              owner,
              now,
              epoch,
              acquired_at,
              existing
            )

          {:error, :claimed} ->
            {:error, :claimed}
        end

      {:error, :missing} ->
        write_lease(path, issue_id, issue_identifier, owner, now, 1, now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec refresh(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def refresh(issue_id, owner, _opts \\ [])
      when is_binary(issue_id) and is_binary(owner) do
    with_lease_lock(issue_id, fn -> refresh_locked(issue_id, owner) end)
  end

  defp refresh_locked(issue_id, owner) do
    now = DateTime.utc_now()
    path = lease_path(issue_id)

    case read(issue_id) do
      {:ok, existing} ->
        existing_owner = existing["owner"] || existing[:owner]

        if existing_owner == owner do
          write_lease(
            path,
            issue_id,
            existing["issue_identifier"] || existing[:issue_identifier],
            owner,
            now,
            existing["epoch"] || existing[:epoch] || 1,
            existing["acquired_at"] || existing[:acquired_at] || DateTime.to_iso8601(now)
          )
        else
          {:error, :claimed}
        end

      {:error, :missing} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec release(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def release(issue_id, owner \\ nil) when is_binary(issue_id) do
    with_lease_lock(issue_id, fn -> release_locked(issue_id, owner) end)
  end

  defp release_locked(issue_id, owner) do
    path = lease_path(issue_id)

    case File.read(path) do
      {:ok, payload} ->
        with {:ok, decoded} <- Jason.decode(payload),
             true <- is_map(decoded) or {:error, :invalid_lease},
             :ok <- ensure_audit_complete(decoded) do
          if is_nil(owner) or decoded["owner"] == owner do
            case File.rm(path) do
              :ok -> :ok
              {:error, :enoent} -> :ok
              {:error, reason} -> {:error, reason}
            end
          else
            :ok
          end
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Finalizes only an already-confirmed takeover. Never retries a ledger write or removes a pending lease."
  @spec reconcile_pending_takeover(String.t()) :: :ok | {:error, term()}
  def reconcile_pending_takeover(issue_id) when is_binary(issue_id) do
    with_lease_lock(issue_id, fn ->
      path = lease_path(issue_id)

      with {:ok, bytes} <- File.read(path),
           {:ok, decoded} <- Jason.decode(bytes),
           {:ok, candidate, pending} <- validate_pending_takeover(decoded, issue_id),
           {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
           true <- ledger_path == pending["ledger_path"] or {:error, :lease_audit_ledger_changed},
           {:ok, intent} <- RunLedger.fetch_entry_checked(pending["intent_event_id"]),
           :ok <- validate_takeover_intent(intent, pending["confirmation"]),
           {:ok, recorded} <- RunLedger.fetch_entry_checked(pending["confirmation"]["event_id"]),
           true <-
             recorded == pending["confirmation"] or {:error, :lease_audit_confirmation_mismatch} do
        write_json_atomically(path, candidate)
      end
    end)
  end

  @spec lease_path(String.t()) :: Path.t()
  def lease_path(issue_id) when is_binary(issue_id) do
    Path.join([Path.dirname(RunLedger.ledger_file_path()), @lease_dir, "#{issue_id}.json"])
  end

  # mkdir provides exclusion between independent OS processes sharing this store.
  # Only the creator removes this directory. A crashed holder leaves an explicit
  # blocking condition; lease TTL must never be used to steal a critical-section lock.
  defp with_lease_lock(issue_id, operation) do
    lock_path = lease_path(issue_id) <> ".lock"
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

  defp write_lease(path, issue_id, issue_identifier, owner, now, epoch, acquired_at) do
    :ok = File.mkdir_p(Path.dirname(path))

    write_json_atomically(
      path,
      lease_payload(issue_id, issue_identifier, owner, now, epoch, acquired_at)
    )
  end

  defp lease_payload(issue_id, issue_identifier, owner, now, epoch, acquired_at) do
    %{
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      owner: owner,
      lease_version: @lease_version,
      epoch: epoch,
      acquired_at: normalize_timestamp(acquired_at, now),
      updated_at: DateTime.to_iso8601(now)
    }
  end

  defp commit_takeover(path, issue_id, issue_identifier, owner, now, epoch, acquired_at, previous) do
    candidate = lease_payload(issue_id, issue_identifier, owner, now, epoch, acquired_at)
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

    with {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
         {:ok, intent} <- RunLedger.prepare_entry("lease.takeover.requested", intent_attrs),
         {:ok, confirmation} <- RunLedger.prepare_entry("lease.taken_over", attrs),
         :ok <- audit_step(:intent, operation_id, RunLedger.persist_prepared(intent)) do
      pending = %{
        operation_id: operation_id,
        ledger_path: ledger_path,
        intent_event_id: intent.event_id,
        confirmation: confirmation,
        previous_lease: previous
      }

      with :ok <-
             audit_step(
               :lease_write,
               operation_id,
               write_json_atomically(path, Map.put(candidate, :audit_pending, pending))
             ),
           :ok <-
             audit_step(:confirmation, operation_id, RunLedger.persist_prepared(confirmation)),
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
  defp validate_pending_takeover(_other, _issue_id), do: {:error, :invalid_lease}

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
