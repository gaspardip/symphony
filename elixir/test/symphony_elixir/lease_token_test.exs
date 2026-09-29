defmodule SymphonyElixir.LeaseTokenTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{DispatchGate, LeaseManager, RunLedger}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", observability_tracing_enabled: false)
    id = "token-#{System.unique_integer([:positive])}"
    assert {:ok, storage} = LeaseManager.capture_storage(id, ttl_ms: 60_000)
    {:ok, id: id, storage: storage}
  end

  test "acquire returns its persisted identity and reacquire requires the original token", ctx do
    assert {:ok, %{token: token, lease: lease, acquisition: :created}} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    assert token.storage == ctx.storage
    assert lease["lease_version"] == 2
    assert token.lease_generation == lease["lease_generation"]
    assert token.epoch == 1
    assert token.acquired_at == lease["acquired_at"]
    assert {:ok, ^lease} = LeaseManager.read_at(ctx.storage)
    assert {:error, :lease_token_required} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    assert {:error, :claimed} = LeaseManager.acquire(ctx.id, "TOKEN-1", "other", storage: ctx.storage)
    assert {:ok, %{token: ^token, lease: renewed, acquisition: :reacquired}} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage, expected_token: token)
    assert renewed["acquired_at"] == lease["acquired_at"]
    assert renewed["lease_generation"] == lease["lease_generation"]
    assert {:ok, refreshed} = LeaseManager.refresh_token(token)
    assert refreshed["lease_generation"] == token.lease_generation
    assert {:ok, :released} = LeaseManager.release_token(token)
    assert {:ok, :missing} = LeaseManager.release_token(token)
    assert {:error, :missing} = LeaseManager.refresh_token(token)
    assert {:error, :missing} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage, expected_token: token)
    refute File.exists?(ctx.storage.lease_path)
  end

  test "same-owner and same-epoch ABA cannot refresh release reacquire or activate a successor", ctx do
    assert {:ok, first} = LeaseManager.acquire(ctx.id, "TOKEN-1", "same", storage: ctx.storage)
    assert {:ok, :released} = LeaseManager.release_token(first.token)
    assert {:ok, second} = LeaseManager.acquire(ctx.id, "TOKEN-1", "same", storage: ctx.storage)
    assert first.token.epoch == second.token.epoch
    refute first.token.lease_generation == second.token.lease_generation
    bytes = File.read!(ctx.storage.lease_path)
    assert {:error, :lease_token_mismatch} = LeaseManager.refresh_token(first.token)
    assert {:error, :lease_token_mismatch} = LeaseManager.release_token(first.token)
    assert {:error, :lease_token_mismatch} = LeaseManager.acquire(ctx.id, "TOKEN-1", "same", storage: ctx.storage, expected_token: first.token)
    {worker, ref} = gated_worker!()
    assert {:error, :lease_token_mismatch} = LeaseManager.activate_dispatch(first.token, :not_pending, worker, "dispatch")
    refute_receive {:body, ^worker}, 30
    assert File.read!(ctx.storage.lease_path) == bytes
    assert :ok = LeaseManager.activate_dispatch(second.token, :not_pending, worker, "dispatch")
    assert_receive {:body, ^worker}, 500
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 500
  end

  test "token operations stay on the captured root after configuration changes", ctx do
    assert {:ok, first} = LeaseManager.acquire(ctx.id, "TOKEN-1", "same", storage: ctx.storage)
    other_log = Path.join(Path.dirname(ctx.storage.ledger_path), "other/symphony.log")
    Application.put_env(:symphony_elixir, :log_file, other_log)
    assert {:ok, other_storage} = LeaseManager.capture_storage(ctx.id, ttl_ms: 60_000)
    assert {:ok, second} = LeaseManager.acquire(ctx.id, "TOKEN-1", "same", storage: other_storage)
    bytes = File.read!(other_storage.lease_path)
    assert {:ok, _} = LeaseManager.refresh_token(first.token)
    assert {:ok, :released} = LeaseManager.release_token(first.token)
    assert File.read!(other_storage.lease_path) == bytes
    assert {:ok, lease} = LeaseManager.read_at(other_storage)
    assert lease["lease_generation"] == second.token.lease_generation
    assert {:error, :missing} = LeaseManager.read_at(ctx.storage)
    assert {:error, :lease_token_mismatch} = LeaseManager.acquire(ctx.id, "TOKEN-1", "same", storage: other_storage, expected_token: first.token)
  end

  test "invalid TTL and storage mismatch never create lease files", ctx do
    for ttl <- [0, -1, nil, "100", 1.0] do
      assert {:error, :invalid_lease_ttl} = LeaseManager.capture_storage(ctx.id, ttl_ms: ttl)
      assert {:error, :invalid_lease_ttl} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", ttl_ms: ttl)
    end

    assert {:error, :lease_storage_mismatch} = LeaseManager.acquire("different", "TOKEN-1", "owner", storage: ctx.storage)
    assert {:error, :invalid_lease_storage} = LeaseManager.read_at(%{ctx.storage | lease_path: ctx.storage.lease_path <> ".other"})
    assert {:error, :invalid_lease_owner} = LeaseManager.acquire(ctx.id, "TOKEN-1", "", storage: ctx.storage)
    refute File.exists?(ctx.storage.lease_path)
  end

  test "new-format owner-only APIs always reject and preserve bytes", ctx do
    assert {:ok, acquired} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    bytes = File.read!(ctx.storage.lease_path)

    for owner <- ["owner", "other"] do
      assert {:error, :lease_token_required} = LeaseManager.refresh(ctx.id, owner)
      assert {:error, :lease_token_required} = LeaseManager.release(ctx.id, owner)
    end

    assert {:error, :lease_token_required} = LeaseManager.release(ctx.id)
    assert File.read!(ctx.storage.lease_path) == bytes
    snapshot = LeaseManager.snapshot_for_state(acquired.lease)
    assert snapshot.lease_generation == acquired.token.lease_generation
    assert snapshot.lease_version == 2
    refute Map.has_key?(snapshot, :token)
  end

  test "legacy read stays read-only and explicit acquisition adopts its unchanged identity fields", ctx do
    old = legacy(ctx.id)
    write_lease!(ctx.storage, old)
    bytes = File.read!(ctx.storage.lease_path)
    assert {:ok, ^old} = LeaseManager.read_at(ctx.storage)
    assert File.read!(ctx.storage.lease_path) == bytes
    assert :ok = LeaseManager.refresh(ctx.id, old["owner"])
    assert {:ok, refreshed_legacy} = LeaseManager.read_at(ctx.storage)
    assert refreshed_legacy["lease_version"] == 1
    refute Map.has_key?(refreshed_legacy, "lease_generation")
    assert {:ok, %{token: token, lease: adopted, acquisition: :adopted_legacy}} = LeaseManager.acquire(ctx.id, "TOKEN-1", old["owner"], storage: ctx.storage)
    assert token.epoch == old["epoch"]
    assert token.acquired_at == old["acquired_at"]
    assert adopted["lease_version"] == 2
    assert {:error, :lease_token_required} = LeaseManager.release(ctx.id)
  end

  test "legacy release remains conditional without conferring authority over v2", ctx do
    old = legacy(ctx.id)
    write_lease!(ctx.storage, old)
    assert :ok = LeaseManager.release(ctx.id, "other")
    assert {:ok, ^old} = LeaseManager.read_at(ctx.storage)
    assert :ok = LeaseManager.release(ctx.id, old["owner"])
    assert {:error, :missing} = LeaseManager.read_at(ctx.storage)
    assert :ok = LeaseManager.release(ctx.id)
  end

  test "partial v2 identities are invalid rather than legacy or reclaimable", ctx do
    assert {:ok, acquired} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)

    for bad <- [
          Map.delete(acquired.lease, "lease_generation"),
          Map.put(acquired.lease, "lease_generation", ""),
          Map.put(acquired.lease, "epoch", 0),
          Map.put(acquired.lease, "acquired_at", nil),
          Map.put(acquired.lease, "updated_at", "broken"),
          Map.delete(acquired.lease, "lease_version"),
          Map.put(acquired.lease, "issue_id", "other")
        ] do
      write_lease!(ctx.storage, bad)
      bytes = File.read!(ctx.storage.lease_path)
      assert {:error, :invalid_lease} = LeaseManager.read_at(ctx.storage)
      assert {:error, :invalid_lease} = LeaseManager.refresh_token(acquired.token)
      assert {:error, :invalid_lease} = LeaseManager.release_token(acquired.token)
      assert {:error, :invalid_lease} = LeaseManager.release(ctx.id)
      if bad["issue_id"] == ctx.id, do: refute(LeaseManager.reclaimable?(bad))
      assert File.read!(ctx.storage.lease_path) == bytes
    end
  end

  test "deadline remains expired after refresh and is checked inside the final lock", ctx do
    assert {:ok, acquired} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    {worker, ref} = gated_worker!()
    deadline = System.monotonic_time(:millisecond)
    assert {:ok, _} = LeaseManager.refresh_token(acquired.token)
    assert {:error, :dispatch_deadline_expired} = LeaseManager.activate_dispatch(acquired.token, deadline, worker, "dispatch")
    refute_receive {:body, ^worker}, 30
    assert :ok = LeaseManager.activate_dispatch(acquired.token, System.monotonic_time(:millisecond) + 1_000, worker, "dispatch")
    assert_receive {:body, ^worker}, 500
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 500
  end

  test "a deadline that expires while waiting for the lock never opens the gate", ctx do
    assert {:ok, acquired} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    lock = ctx.storage.lease_path <> ".lock"
    File.mkdir!(lock)
    {worker, _ref} = gated_worker!()
    deadline = System.monotonic_time(:millisecond) + 20
    parent = self()

    {releaser, ref} =
      spawn_monitor(fn ->
        receive do
          :release ->
            Process.sleep(40)
            File.rmdir!(lock)
            send(parent, :lock_released)
        end
      end)

    on_exit(fn -> if Process.alive?(releaser), do: Process.exit(releaser, :kill) end)
    send(releaser, :release)
    assert {:error, :dispatch_deadline_expired} = LeaseManager.activate_dispatch(acquired.token, deadline, worker, "dispatch")
    assert_receive :lock_released, 500
    assert_receive {:DOWN, ^ref, :process, ^releaser, :normal}, 500
    refute_receive {:body, ^worker}, 30
  end

  test "not_pending still checks captured lease TTL", ctx do
    assert {:ok, acquired} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    expired = Map.put(acquired.lease, "updated_at", DateTime.utc_now() |> DateTime.add(-61, :second) |> DateTime.to_iso8601())
    write_lease!(ctx.storage, expired)
    {worker, _ref} = gated_worker!()
    assert {:error, :lease_expired} = LeaseManager.activate_dispatch(acquired.token, :not_pending, worker, "dispatch")
    refute_receive {:body, ^worker}, 30
    assert {:ok, _} = LeaseManager.refresh_token(acquired.token)
    assert :ok = LeaseManager.activate_dispatch(acquired.token, :not_pending, worker, "dispatch")
    assert_receive {:body, ^worker}, 500
  end

  test "reclaimability distinguishes live expired exact TTL and audit-pending metadata", ctx do
    assert {:ok, acquired} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    {:ok, updated, _offset} = DateTime.from_iso8601(acquired.lease["updated_at"])
    refute LeaseManager.reclaimable?(acquired.lease, updated, ttl_ms: 60_000)
    refute LeaseManager.reclaimable?(acquired.lease, DateTime.add(updated, 60_000, :millisecond), ttl_ms: 60_000)
    assert LeaseManager.reclaimable?(acquired.lease, DateTime.add(updated, 60_001, :millisecond), ttl_ms: 60_000)
    pending = Map.put(acquired.lease, "audit_pending", %{operation_id: "held"})
    refute LeaseManager.reclaimable?(pending, DateTime.add(updated, 86_400, :second), ttl_ms: 1)
    legacy_metadata = %{updated_at: updated}
    refute LeaseManager.reclaimable?(legacy_metadata, DateTime.add(updated, 60_000, :millisecond), ttl_ms: 60_000)
    assert LeaseManager.reclaimable?(legacy_metadata, DateTime.add(updated, 60_001, :millisecond), ttl_ms: 60_000)
    assert LeaseManager.age_ms(legacy_metadata, DateTime.add(updated, 123, :millisecond)) == 123
    assert LeaseManager.age_ms(legacy_metadata, DateTime.add(updated, -123, :millisecond)) == 0
    assert LeaseManager.age_ms(%{updated_at: "invalid"}, updated) == nil
  end

  test "atom-key v2 diagnostics validate complete identity and reject contradictory aliases", ctx do
    assert {:ok, acquired} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    fields = [:issue_id, :owner, :epoch, :lease_version, :lease_generation, :acquired_at, :updated_at]
    atoms = Map.new(fields, fn key -> {key, Map.fetch!(acquired.lease, Atom.to_string(key))} end)
    {:ok, updated, _offset} = DateTime.from_iso8601(atoms.updated_at)
    expired = DateTime.add(updated, 60_001, :millisecond)
    refute LeaseManager.reclaimable?(atoms, updated, ttl_ms: 60_000)
    assert LeaseManager.reclaimable?(atoms, expired, ttl_ms: 60_000)
    assert LeaseManager.reclaimable?(Map.put(atoms, "lease_version", 2), expired, ttl_ms: 60_000)

    for invalid <- [
          Map.delete(atoms, :lease_generation),
          Map.delete(atoms, :lease_version),
          Map.delete(atoms, :issue_id),
          Map.put(atoms, :issue_id, ""),
          %{lease_version: 2, updated_at: atoms.updated_at},
          %{lease_generation: atoms.lease_generation, updated_at: atoms.updated_at},
          Map.put(atoms, "lease_version", 1),
          Map.put(atoms, "lease_generation", "other"),
          Map.put(atoms, "updated_at", updated),
          Map.put(atoms, :audit_pending, nil)
        ] do
      refute LeaseManager.reclaimable?(invalid, expired, ttl_ms: 60_000)
    end
  end

  test "audited takeover keeps the captured ledger even if config changes during intent", ctx do
    old = legacy(ctx.id, -3_600)
    write_lease!(ctx.storage, old)
    new_root = Path.join(Path.dirname(ctx.storage.ledger_path), "new-ledger")

    observe(ctx.id, fn
      %{event_type: "lease.takeover.requested"} -> Application.put_env(:symphony_elixir, :log_file, Path.join(new_root, "symphony.log"))
      _ -> :ok
    end)

    assert {:ok, %{token: token, acquisition: :takeover}} = LeaseManager.acquire(ctx.id, "TOKEN-1", "new-owner", storage: ctx.storage)
    assert token.storage == ctx.storage
    assert token.epoch == old["epoch"] + 1
    assert [intent, confirmation] = ledger_rows(ctx.storage)
    assert intent["event_type"] == "lease.takeover.requested"
    assert confirmation["event_type"] == "lease.taken_over"
    refute File.exists?(Path.join(new_root, "run_ledger.jsonl"))
    assert {:ok, lease} = LeaseManager.read_at(ctx.storage)
    assert lease["lease_generation"] == token.lease_generation
  end

  test "audit pending blocks every token mutation and gate", ctx do
    assert {:ok, acquired} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    pending = Map.put(acquired.lease, "audit_pending", %{"operation_id" => "held-operation"})
    write_lease!(ctx.storage, pending)
    bytes = File.read!(ctx.storage.lease_path)
    {worker, _ref} = gated_worker!()
    assert {:error, {:lease_audit_pending, "held-operation"}} = LeaseManager.refresh_token(acquired.token)
    assert {:error, {:lease_audit_pending, "held-operation"}} = LeaseManager.release_token(acquired.token)
    assert {:error, {:lease_audit_pending, "held-operation"}} = LeaseManager.activate_dispatch(acquired.token, :not_pending, worker, "dispatch")
    assert {:error, {:lease_audit_pending, "held-operation"}} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage, expected_token: acquired.token)
    assert File.read!(ctx.storage.lease_path) == bytes
    refute_receive {:body, ^worker}, 30
  end

  test "confirmed v2 reconciliation preserves generation and writes no new ledger rows", ctx do
    write_lease!(ctx.storage, legacy(ctx.id, -3_600))
    backup = ctx.storage.lease_path <> ".pending-fixture"

    observe(ctx.id, fn
      %{event_type: "lease.taken_over"} ->
        File.rename!(ctx.storage.lease_path, backup)
        File.mkdir!(ctx.storage.lease_path)

      _ ->
        :ok
    end)

    assert {:error, {:lease_takeover_failed, :finalize, _operation, _reason}} = LeaseManager.acquire(ctx.id, "TOKEN-1", "new-owner", storage: ctx.storage)
    # Remove only this fixture's obstruction; reconciliation itself never repairs it.
    File.rmdir!(ctx.storage.lease_path)
    File.rename!(backup, ctx.storage.lease_path)
    pending = ctx.storage.lease_path |> File.read!() |> Jason.decode!()
    generation = pending["lease_generation"]
    ledger_before = File.read!(ctx.storage.ledger_path)
    assert {:error, {:lease_audit_pending, _}} = LeaseManager.read_at(ctx.storage)
    assert :ok = LeaseManager.reconcile_pending_takeover(ctx.storage)
    assert {:ok, lease} = LeaseManager.read_at(ctx.storage)
    assert lease == Map.delete(pending, "audit_pending")
    assert lease["lease_generation"] == generation
    assert File.read!(ctx.storage.ledger_path) == ledger_before
    assert {:error, :lease_token_required} = LeaseManager.acquire(ctx.id, "TOKEN-1", "new-owner", storage: ctx.storage)
  end

  test "reconciliation preserves a confirmed v1 candidate and its original digests", ctx do
    previous = legacy(ctx.id, -3_600)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    candidate = %{previous | "owner" => "new-owner", "epoch" => previous["epoch"] + 1, "acquired_at" => now, "updated_at" => now}
    operation = "legacy-confirmed-operation"

    attrs = %{
      issue_id: ctx.id,
      issue_identifier: "TOKEN-1",
      actor_type: "system",
      actor_id: "new-owner",
      failure_class: "coordination",
      rule_id: "coordination.lease_taken_over",
      summary: "legacy fixture",
      metadata: %{
        operation_id: operation,
        epoch: candidate["epoch"],
        previous_epoch: previous["epoch"],
        previous_owner: previous["owner"],
        candidate_digest: digest(candidate),
        previous_lease_digest: digest(previous)
      }
    }

    assert {:ok, intent} = RunLedger.prepare_entry("lease.takeover.requested", attrs)
    assert {:ok, confirmation} = RunLedger.prepare_entry("lease.taken_over", attrs)
    assert {:ok, _} = RunLedger.CheckedStorage.persist(intent, ctx.storage.ledger_path)
    assert {:ok, _} = RunLedger.CheckedStorage.persist(confirmation, ctx.storage.ledger_path)
    pending = %{operation_id: operation, ledger_path: ctx.storage.ledger_path, intent_event_id: intent.event_id, confirmation: confirmation, previous_lease: previous}
    write_lease!(ctx.storage, Map.put(candidate, "audit_pending", pending))
    ledger_before = File.read!(ctx.storage.ledger_path)
    Application.put_env(:symphony_elixir, :log_file, Path.join(Path.dirname(ctx.storage.ledger_path), "unrelated/symphony.log"))
    assert :ok = LeaseManager.reconcile_pending_takeover(ctx.storage)
    assert {:ok, ^candidate} = LeaseManager.read_at(ctx.storage)
    refute Map.has_key?(candidate, "lease_generation")
    assert File.read!(ctx.storage.ledger_path) == ledger_before
    assert {:ok, %{acquisition: :adopted_legacy}} = LeaseManager.acquire(ctx.id, "TOKEN-1", "new-owner", storage: ctx.storage)
  end

  test "OS release then acquire preserves a same-owner successor against the old token", ctx do
    assert {:ok, first} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    before = File.read!(ctx.storage.lease_path)
    lock = ctx.storage.lease_path <> ".lock"
    File.mkdir!(lock)

    try do
      with_lease_child(ctx.storage, "release-first", fn paths ->
        ready = wait_child_file!(paths.ready)
        assert ready.os_pid != System.pid()
        assert ready.result == {:error, {:lease_lock_timeout, lock}}
        assert ready.bytes == before
        # This is ordered release -> acquire. The fixture lock above proves
        # the other OS process observes the shared storage lock.
        File.rmdir!(lock)
        assert {:ok, :released} = LeaseManager.release_token(first.token)
        refute File.exists?(ctx.storage.lease_path)
        File.write!(paths.go, "release-confirmed")
        result = wait_child_file!(paths.result)
        assert {:ok, successor} = result.acquired
        assert successor.token.owner == first.token.owner
        assert successor.token.epoch == first.token.epoch
        refute successor.token.lease_generation == first.token.lease_generation
        assert {:error, :lease_token_mismatch} = LeaseManager.release_token(first.token)
        assert {:error, :lease_token_mismatch} = LeaseManager.refresh_token(first.token)
        assert File.read!(ctx.storage.lease_path) == result.bytes
        report_child_phase(:release_then_acquire, result)
      end)
    after
      if File.dir?(lock), do: File.rmdir!(lock)
    end
  end

  test "OS acquire holding the shared lock excludes release and preserves the successor", ctx do
    assert {:ok, first} = LeaseManager.acquire(ctx.id, "TOKEN-1", "owner", storage: ctx.storage)
    expired = Map.put(first.lease, "updated_at", DateTime.utc_now() |> DateTime.add(-61, :second) |> DateTime.to_iso8601())
    write_lease!(ctx.storage, expired)
    before = File.read!(ctx.storage.lease_path)

    with_lease_child(ctx.storage, "acquire-first", fn paths ->
      ready = wait_child_file!(paths.ready)
      assert ready.os_pid != System.pid()
      assert ready.phase == :intent_confirmed_lock_held
      assert ready.bytes == before
      assert File.dir?(ctx.storage.lease_path <> ".lock")
      assert [%{"event_type" => "lease.takeover.requested"}] = ledger_rows(ctx.storage)
      # The telemetry barrier is inside the actual acquisition's lease lock.
      assert {:error, {:lease_lock_timeout, lock_path}} = LeaseManager.release_token(first.token)
      assert lock_path == ctx.storage.lease_path <> ".lock"
      assert File.read!(ctx.storage.lease_path) == before
      File.write!(paths.go, "release-attempt-confirmed")
      result = wait_child_file!(paths.result)
      assert {:ok, successor} = result.acquired
      assert successor.acquisition == :takeover
      assert successor.token.epoch == first.token.epoch + 1
      refute successor.token.lease_generation == first.token.lease_generation
      assert [intent, confirmation] = ledger_rows(ctx.storage)
      assert intent["event_type"] == "lease.takeover.requested"
      assert confirmation["event_type"] == "lease.taken_over"
      ledger = File.read!(ctx.storage.ledger_path)
      assert {:error, :lease_token_mismatch} = LeaseManager.release_token(first.token)
      assert {:error, :lease_token_mismatch} = LeaseManager.refresh_token(first.token)
      assert File.read!(ctx.storage.lease_path) == result.bytes
      assert File.read!(ctx.storage.ledger_path) == ledger
      report_child_phase(:acquire_then_release, result)
    end)
  end

  defp with_lease_child(storage, scenario, assertion) do
    executable = System.find_executable("elixir") || flunk("Elixir executable required for the approved isolated child VM")
    build = Mix.Project.build_path() |> Path.expand()
    app_ebin = Mix.Project.compile_path() |> Path.expand()
    assert app_ebin == Path.join(build, "lib/symphony_elixir/ebin")
    jason_ebin = Path.join(build, "lib/jason/ebin")
    telemetry_ebin = Path.join(build, "lib/telemetry/ebin")

    modules = [
      {LeaseManager, "lease_manager.ex"},
      {RunLedger, "run_ledger.ex"},
      {RunLedger.CheckedStorage, "run_ledger.ex"},
      {RunLedger.PersistenceError, "run_ledger.ex"},
      {SymphonyElixir.Observability, "observability.ex"},
      {SymphonyElixir.Util, "util.ex"},
      {SymphonyElixir.SecretRedactor, "secret_redactor.ex"}
    ]

    artifacts =
      Enum.map(modules, fn {module, source} ->
        artifact = child_artifact!(module, app_ebin)
        assert artifact.source == Path.expand("lib/symphony_elixir/" <> source)
        artifact
      end) ++ [child_artifact!(Jason, jason_ebin), child_artifact!(:telemetry, telemetry_ebin)]

    IO.puts("Lease child artifacts: #{inspect(artifacts)}")
    root = Path.join(Path.dirname(storage.lease_path), "child-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    paths = %{ready: Path.join(root, "ready"), go: Path.join(root, "go"), result: Path.join(root, "result")}
    manifest = Path.join(root, "fixture")
    File.write!(manifest, :erlang.term_to_binary(%{storage: storage, scenario: scenario, paths: paths, artifacts: artifacts}))
    parent = self()
    reply = make_ref()

    {runner, monitor} =
      spawn_monitor(fn ->
        result = System.cmd(executable, ["--erl", "+S 1:1 +A 1", "-pa", app_ebin, "-pa", jason_ebin, "-pa", telemetry_ebin, "-e", lease_child_script(), "--", manifest], stderr_to_stdout: true)
        send(parent, {reply, result})
      end)

    # Also release and observe the exact runner if the test process is killed.
    on_exit(fn ->
      File.write!(paths.go, "teardown")
      ref = Process.monitor(runner)
      assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 11_000
    end)

    try do
      assertion.(paths)
    after
      File.write!(paths.go, "teardown")
      assert_receive {^reply, {output, status}}, 11_000
      IO.puts("Lease child exit: #{inspect(%{status: status, output: output})}")
      assert status == 0
      assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}, 1_000
    end
  end

  defp child_artifact!(module, ebin) do
    path = Path.join(ebin, Atom.to_string(module) <> ".beam")
    assert {:ok, {^module, [compile_info: info]}} = :beam_lib.chunks(String.to_charlist(path), [:compile_info])
    source = info |> Keyword.fetch!(:source) |> to_string() |> Path.expand()
    %{module: module, path: path, source: source, source_sha256: file_hash(source), sha256: file_hash(path)}
  end

  defp lease_child_script do
    ~S'''
    spawn(fn -> Process.sleep(10_000); System.halt(90) end)
    [manifest] = System.argv()
    fixture = manifest |> File.read!() |> :erlang.binary_to_term()
    for artifact <- fixture.artifacts do
      module = artifact.module
      {:module, ^module} = Code.ensure_loaded(module)
      path = module |> :code.which() |> List.to_string() |> Path.expand()
      if path != artifact.path, do: raise("Child loaded artifact outside candidate build")
      bytes = File.read!(path)
      sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      if sha != artifact.sha256, do: raise("Child artifact bytes changed")
      {:ok, {^module, md5}} = :beam_lib.md5(bytes)
      if :erlang.get_module_info(module, :md5) != md5, do: raise("Child module differs from captured artifact")
    end
    {:ok, _} = Application.ensure_all_started(:telemetry)
    publish = fn path, value ->
      File.write!(path <> ".tmp", :erlang.term_to_binary(value))
      File.rename!(path <> ".tmp", path)
    end
    await_go = fn await_go ->
      unless File.exists?(fixture.paths.go) do
        Process.sleep(5)
        await_go.(await_go)
      end
    end
    storage = fixture.storage
    acquire = fn owner -> SymphonyElixir.LeaseManager.acquire(storage.issue_id, "TOKEN-1", owner, storage: storage) end
    if fixture.scenario == "release-first" do
      result = acquire.("owner")
      publish.(fixture.paths.ready, %{os_pid: System.pid(), result: result, bytes: File.read!(storage.lease_path)})
      await_go.(await_go)
    else
      :ok = :telemetry.attach("lease-child-barrier", [:symphony, :ledger, :event], fn _, _, metadata, _ ->
        if metadata.event_type == "lease.takeover.requested" and metadata.issue_id == storage.issue_id do
          publish.(fixture.paths.ready, %{os_pid: System.pid(), phase: :intent_confirmed_lock_held, bytes: File.read!(storage.lease_path)})
          await_go.(await_go)
        end
      end, nil)
    end
    owner = if fixture.scenario == "release-first", do: "owner", else: "successor"
    acquired = acquire.(owner)
    publish.(fixture.paths.result, %{os_pid: System.pid(), acquired: acquired, bytes: File.read!(storage.lease_path)})
    IO.puts("lease-child-checked")
    '''
  end

  defp wait_child_file!(path) do
    wait_child_file!(path, System.monotonic_time(:millisecond) + 5_000)
  end

  defp wait_child_file!(path, deadline) do
    if File.exists?(path) do
      path |> File.read!() |> :erlang.binary_to_term()
    else
      assert System.monotonic_time(:millisecond) < deadline, "Child did not publish #{path}"
      Process.sleep(5)
      wait_child_file!(path, deadline)
    end
  end

  defp report_child_phase(phase, result) do
    IO.puts(
      "Lease child phase: #{inspect(%{phase: phase, os_pid: result.os_pid, bytes: byte_size(result.bytes), sha256: :crypto.hash(:sha256, result.bytes) |> Base.encode16(case: :lower), acquired: result.acquired})}"
    )
  end

  defp file_hash(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp legacy(id, age_seconds \\ 0) do
    timestamp = DateTime.utc_now() |> DateTime.add(age_seconds, :second) |> DateTime.to_iso8601()
    %{"issue_id" => id, "issue_identifier" => "TOKEN-1", "owner" => "legacy-owner", "epoch" => 7, "lease_version" => 1, "acquired_at" => timestamp, "updated_at" => timestamp}
  end

  defp write_lease!(storage, lease) do
    File.mkdir_p!(Path.dirname(storage.lease_path))
    File.write!(storage.lease_path, Jason.encode!(lease))
  end

  defp gated_worker! do
    owner = self()
    {worker, ref} = spawn_monitor(fn -> DispatchGate.run(owner, "dispatch", fn -> send(owner, {:body, self()}) end) end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    {worker, ref}
  end

  defp observe(id, callback) do
    handler = "lease-token-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:symphony, :ledger, :event],
        fn _, _, metadata, _ ->
          if metadata.issue_id == id, do: callback.(metadata)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp ledger_rows(storage), do: storage.ledger_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp digest(payload) do
    canonical = payload |> Jason.encode!() |> Jason.decode!() |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end) |> Jason.encode!()
    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end
end
