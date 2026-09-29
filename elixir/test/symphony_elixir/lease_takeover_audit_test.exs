defmodule SymphonyElixir.LeaseTakeoverAuditTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{LeaseManager, RunLedger}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      observability_tracing_enabled: false
    )

    id = "takeover-#{System.unique_integer([:positive])}"
    path = LeaseManager.lease_path(id)
    at = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
    File.mkdir_p!(Path.dirname(path))

    old =
      Jason.encode!(%{
        issue_id: id,
        issue_identifier: "LEASE-1",
        owner: "old-owner",
        epoch: 7,
        lease_version: 1,
        acquired_at: at,
        updated_at: at
      })

    File.write!(path, old)
    %{id: id, path: path, old: old, ledger: RunLedger.ledger_file_path()}
  end

  test "takeover confirmation observes the persisted candidate before acquisition returns", c do
    parent = self()

    observe(c, fn meta ->
      send(parent, {:boundary, meta.event_type, File.read!(c.path), LeaseManager.read(c.id)})
    end)

    assert {:ok, %{token: token, acquisition: :takeover}} = LeaseManager.acquire(c.id, "LEASE-1", "new-owner")
    assert_receive {:boundary, "lease.takeover.requested", old, {:ok, %{"owner" => "old-owner"}}}
    assert old == c.old

    assert_receive {:boundary, "lease.taken_over", candidate_bytes, {:error, {:lease_audit_pending, op}}}

    candidate = Jason.decode!(candidate_bytes)
    assert candidate["owner"] == "new-owner"
    assert candidate["epoch"] == 8
    assert candidate["lease_generation"] == token.lease_generation
    assert candidate["audit_pending"]["operation_id"] == op
    [intent, confirmation] = rows(c)
    assert intent["event_type"] == "lease.takeover.requested"
    assert confirmation["event_type"] == "lease.taken_over"
    assert confirmation == candidate["audit_pending"]["confirmation"]
    assert intent["event_id"] == candidate["audit_pending"]["intent_event_id"]
    assert intent["metadata"]["operation_id"] == op
    assert confirmation["metadata"]["operation_id"] == op
    assert intent["event_id"] != confirmation["event_id"]

    write_trace(
      "trace-success.json",
      Jason.encode!(
        %{
          old: Jason.decode!(old),
          at_confirmation: candidate,
          guarded_read: "lease_audit_pending",
          rows: [intent, confirmation],
          returned: "ok"
        },
        pretty: true
      )
    )

    assert {:ok, lease} = LeaseManager.read(c.id)
    refute Map.has_key?(lease, "audit_pending")
    assert {:error, :lease_token_required} = LeaseManager.refresh(c.id, "old-owner")
    assert {:error, :lease_token_required} = LeaseManager.release(c.id, "old-owner")
    assert {:ok, ^lease} = LeaseManager.read(c.id)
  end

  test "initial acquisition and normal refresh do not require takeover events", c do
    id = c.id <> "-initial"
    assert {:ok, acquired} = LeaseManager.acquire(id, "LEASE-2", "owner")
    assert {:ok, _lease} = LeaseManager.refresh_token(acquired.token)
    assert {:ok, %{"epoch" => 1, "owner" => "owner"}} = LeaseManager.read(id)
    refute File.exists?(c.ledger)
  end

  test "invalid ledger blocks intent and the real dispatch gate never spawns", c do
    File.write!(c.ledger, "{corrupt\n")

    assert {:error, {:lease_takeover_failed, :intent, _, _}} =
             LeaseManager.acquire(c.id, "LEASE-1", "new-owner")

    parent = self()
    state = %Orchestrator.State{lease_owner: "new-owner"}

    issue = %Issue{
      id: c.id,
      identifier: "LEASE-1",
      title: "Synthetic audited lease",
      state: "In Progress"
    }

    spawn = fn st, _, _, _ ->
      send(parent, :spawned)
      st
    end

    assert ^state = Orchestrator.do_dispatch_issue_for_test(state, issue, nil, spawn_fun: spawn)
    refute_received :spawned
    assert File.read!(c.path) == c.old
    assert File.read!(c.ledger) == "{corrupt\n"
  end

  test "lease write obstruction does not emit taken_over and preserves old bytes", c do
    backup = c.path <> ".owned-backup"

    observe(c, fn
      %{event_type: "lease.takeover.requested"} ->
        File.rename!(c.path, backup)
        File.mkdir!(c.path)

      _ ->
        :ok
    end)

    assert {:error, {:lease_takeover_failed, :lease_write, _, _}} =
             LeaseManager.acquire(c.id, "LEASE-1", "new-owner")

    assert File.read!(backup) == c.old
    assert File.dir?(c.path)
    assert [intent] = rows(c)
    assert intent["event_type"] == "lease.takeover.requested"
    assert {:error, :eisdir} = LeaseManager.release(c.id)
    assert File.dir?(c.path)
  end

  test "confirmation failure preserves a pending lease and blocks every mutation despite TTL",
       c do
    observe(c, fn
      %{event_type: "lease.takeover.requested"} ->
        File.rename!(c.ledger, c.ledger <> ".owned-backup")
        File.mkdir!(c.ledger)

      _ ->
        :ok
    end)

    assert {:error, {:lease_takeover_failed, :confirmation, op, _}} =
             LeaseManager.acquire(c.id, "LEASE-1", "new-owner")

    bytes = File.read!(c.path)
    pending = Jason.decode!(bytes)
    assert pending["audit_pending"]["operation_id"] == op
    assert {:error, {:lease_audit_pending, ^op}} = LeaseManager.read(c.id)

    for owner <- ["old-owner", "new-owner", "third-owner"] do
      assert {:error, {:lease_audit_pending, ^op}} =
               LeaseManager.acquire(c.id, "LEASE-1", owner, ttl_ms: 1)

      assert {:error, {:lease_audit_pending, ^op}} = LeaseManager.refresh(c.id, owner)
      assert {:error, {:lease_audit_pending, ^op}} = LeaseManager.release(c.id, owner)
    end

    assert {:error, {:lease_audit_pending, ^op}} = LeaseManager.release(c.id)

    refute LeaseManager.reclaimable?(pending, DateTime.add(DateTime.utc_now(), 86_400, :second), ttl_ms: 1)

    write_trace("pending-fixture.json", bytes)
    assert File.read!(c.path) == bytes
    assert {:error, _} = LeaseManager.reconcile_pending_takeover(c.id)
    assert File.read!(c.path) == bytes
  end

  test "failed finalization is explicitly reconciled only from already-confirmed identical rows",
       c do
    bytes = confirmed_pending(c)
    [intent, confirmation] = rows(c)
    assert :ok = LeaseManager.reconcile_pending_takeover(c.id)
    assert rows(c) == [intent, confirmation]
    assert {:ok, lease} = LeaseManager.read(c.id)
    assert lease == Map.delete(Jason.decode!(bytes), "audit_pending")
    assert {:error, :no_lease_audit_pending} = LeaseManager.reconcile_pending_takeover(c.id)
  end

  for scenario <- [
        :missing_confirmation,
        :corrupt_ledger,
        :duplicate_confirmation,
        :altered_candidate,
        :altered_intent,
        :different_ledger_path
      ] do
    test "reconciliation preserves evidence for #{scenario}", c do
      confirmed_pending(c)
      [intent, confirmation] = rows(c)

      case unquote(scenario) do
        :missing_confirmation ->
          File.write!(c.ledger, Jason.encode!(intent) <> "\n")

        :corrupt_ledger ->
          File.write!(c.ledger, "{corrupt\n", [:append])

        :duplicate_confirmation ->
          File.write!(c.ledger, Jason.encode!(confirmation) <> "\n", [:append])

        :altered_candidate ->
          alter_pending(c.path, &Map.put(&1, "owner", "foreign-owner"))

        :altered_intent ->
          File.write!(
            c.ledger,
            Jason.encode!(Map.put(intent, "actor_id", "foreign-owner")) <>
              "\n" <> Jason.encode!(confirmation) <> "\n"
          )

        :different_ledger_path ->
          alter_pending(
            c.path,
            &put_in(&1, ["audit_pending", "ledger_path"], c.ledger <> ".other")
          )
      end

      bytes = File.read!(c.path)
      ledger = File.read!(c.ledger)
      assert {:error, _} = LeaseManager.reconcile_pending_takeover(c.id)
      assert File.read!(c.path) == bytes
      assert File.read!(c.ledger) == ledger
    end
  end

  test "release returns diagnostics for corrupt leases without deleting evidence", c do
    for payload <- ["{invalid", "[]", "null", "123", "\"text\""] do
      File.write!(c.path, payload)
      assert {:error, _} = LeaseManager.release(c.id)
      assert {:error, _} = LeaseManager.release(c.id, "owner")
      assert File.read!(c.path) == payload
    end
  end

  defp confirmed_pending(c) do
    backup = c.path <> ".owned-pending"

    observe(c, fn
      %{event_type: "lease.taken_over"} ->
        File.rename!(c.path, backup)
        File.mkdir!(c.path)

      _ ->
        :ok
    end)

    assert {:error, {:lease_takeover_failed, :finalize, op, _}} =
             LeaseManager.acquire(c.id, "LEASE-1", "new-owner")

    # Explicit restoration of this test's obstruction, not production recovery.
    File.rmdir!(c.path)
    File.rename!(backup, c.path)
    bytes = File.read!(c.path)
    assert {:error, {:lease_audit_pending, ^op}} = LeaseManager.read(c.id)
    bytes
  end

  defp alter_pending(path, fun),
    do: File.write!(path, path |> File.read!() |> Jason.decode!() |> fun.() |> Jason.encode!())

  defp rows(c),
    do: c.ledger |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp write_trace(name, bytes) do
    if root = System.get_env("PB10_TEST_ROOT"), do: File.write!(Path.join(root, name), bytes)
  end

  defp observe(c, fun) do
    handler = "lease-audit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:symphony, :ledger, :event],
        fn _, _, meta, _ ->
          if meta.issue_id == c.id, do: fun.(meta)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
