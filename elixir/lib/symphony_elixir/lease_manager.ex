defmodule SymphonyElixir.LeaseManager do
  @moduledoc """
  Persists per-issue dispatch leases so multiple orchestrators do not double-run the same issue.
  """

  alias SymphonyElixir.{Config, RunLedger, RunnerRuntime}

  @lease_dir "leases"
  @lease_version 1

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
    ttl_ms = Keyword.get(opts, :ttl_ms, ttl_ms())

    lease
    |> updated_at_value()
    |> stale_lease?(now, ttl_ms)
  end

  def reclaimable?(_lease, _now, _opts), do: false

  @spec read(String.t()) :: {:ok, map()} | {:error, :missing | term()}
  def read(issue_id) when is_binary(issue_id) do
    path = lease_path(issue_id)

    case File.read(path) do
      {:ok, payload} ->
        Jason.decode(payload)

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
    ttl_ms = Keyword.get(opts, :ttl_ms, default_ttl_ms())
    now = DateTime.utc_now()
    path = lease_path(issue_id)

    case read(issue_id) do
      {:ok, existing} ->
        case acquire_decision(existing, owner, now, ttl_ms) do
          {:ok, epoch, acquired_at} ->
            write_lease(path, issue_id, issue_identifier, owner, now, epoch, acquired_at)

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

  @spec release(String.t(), String.t() | nil) :: :ok
  def release(issue_id, owner \\ nil) when is_binary(issue_id) do
    path = lease_path(issue_id)

    case File.read(path) do
      {:ok, payload} when is_binary(owner) ->
        with {:ok, existing} <- Jason.decode(payload),
             true <- (existing["owner"] || existing[:owner]) == owner do
          File.rm(path)
          :ok
        else
          _ -> :ok
        end

      _ ->
        File.rm(path)
        :ok
    end
  end

  @spec lease_path(String.t()) :: Path.t()
  def lease_path(issue_id) when is_binary(issue_id) do
    Path.join([Path.dirname(RunLedger.ledger_file_path()), @lease_dir, "#{issue_id}.json"])
  end

  defp write_lease(path, issue_id, issue_identifier, owner, now, epoch, acquired_at) do
    :ok = File.mkdir_p(Path.dirname(path))

    payload = %{
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      owner: owner,
      lease_version: @lease_version,
      epoch: epoch,
      acquired_at: normalize_timestamp(acquired_at, now),
      updated_at: DateTime.to_iso8601(now)
    }

    File.write(path, Jason.encode!(payload), [:write])
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
        takeover_epoch = epoch + 1

        RunLedger.record("lease.taken_over", %{
          issue_id: existing["issue_id"] || existing[:issue_id],
          issue_identifier: existing["issue_identifier"] || existing[:issue_identifier],
          actor_type: "system",
          actor_id: owner,
          failure_class: "coordination",
          rule_id: "coordination.lease_taken_over",
          summary: "Lease was taken over after the previous holder went stale.",
          details: "Previous owner #{inspect(existing_owner)} replaced by #{inspect(owner)}.",
          metadata: %{epoch: takeover_epoch, previous_owner: existing_owner}
        })

        {:ok, takeover_epoch, now}

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

  defp default_ttl_ms do
    max(Config.agent_stall_timeout_ms(), max(Config.poll_interval_ms() * 4, 60_000))
  end
end
