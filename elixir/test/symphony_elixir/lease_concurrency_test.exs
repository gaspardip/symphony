defmodule SymphonyElixir.LeaseConcurrencyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LeaseManager

  @source Path.expand("../../lib/symphony_elixir/lease_manager.ex", __DIR__)

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      observability_tracing_enabled: false
    )

    root = Path.dirname(Application.fetch_env!(:symphony_elixir, :log_file))
    File.mkdir_p!(root)
    %{root: root}
  end

  test "independent BEAM processes acquire one owner behind a shared start barrier", %{root: root} do
    for round <- 1..3 do
      issue_id = "cross-process-acquire-#{round}"

      results =
        contend(root, issue_id, [
          {"runner-a", :acquire},
          {"runner-b", :acquire}
        ])

      assert Enum.count(results, fn {_owner, result} -> result == :ok end) == 1
      assert Enum.count(results, fn {_owner, result} -> result == {:error, :claimed} end) == 1
      {winner, :ok} = Enum.find(results, fn {_owner, result} -> result == :ok end)
      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert lease["owner"] == winner
      assert lease["epoch"] == 1
      refute File.exists?(LeaseManager.lease_path(issue_id) <> ".lock")
    end
  end

  test "old-owner release cannot delete a concurrent takeover from another BEAM", %{root: root} do
    issue_id = "cross-process-release"
    seed_expired_lease(issue_id)

    results = contend(root, issue_id, [{"old-owner", :release}, {"new-owner", :acquire}])

    assert Enum.sort(results) == [{"new-owner", :ok}, {"old-owner", :ok}]
    assert {:ok, lease} = LeaseManager.read(issue_id)
    assert lease["owner"] == "new-owner"
    assert lease["epoch"] in [1, 8]
    assert {:error, :claimed} = LeaseManager.refresh(issue_id, "old-owner")
    assert :ok = LeaseManager.release(issue_id, "old-owner")
    assert {:ok, ^lease} = LeaseManager.read(issue_id)
  end

  test "concurrent refresh and takeover preserve a single linear ownership decision", %{
    root: root
  } do
    issue_id = "cross-process-refresh"
    seed_expired_lease(issue_id)

    results = contend(root, issue_id, [{"old-owner", :refresh}, {"new-owner", :acquire}])
    assert {:ok, lease} = LeaseManager.read(issue_id)

    case lease["owner"] do
      "old-owner" ->
        assert Map.new(results) == %{"old-owner" => :ok, "new-owner" => {:error, :claimed}}
        assert lease["epoch"] == 7

      "new-owner" ->
        assert Map.new(results) == %{"old-owner" => {:error, :claimed}, "new-owner" => :ok}
        assert lease["epoch"] == 8
    end
  end

  test "a foreign or orphaned lock blocks every mutation and is never removed" do
    issue_id = "foreign-lock"
    assert :ok = LeaseManager.acquire(issue_id, "LOCK-1", "owner-a")
    lease_path = LeaseManager.lease_path(issue_id)
    lock_path = lease_path <> ".lock"
    payload = File.read!(lease_path)
    File.mkdir!(lock_path)
    marker = Path.join(lock_path, "foreign-owner")
    File.write!(marker, "must remain untouched")

    assert {:error, {:lease_lock_timeout, ^lock_path}} =
             LeaseManager.acquire(issue_id, "LOCK-1", "owner-b")

    assert {:error, {:lease_lock_timeout, ^lock_path}} = LeaseManager.refresh(issue_id, "owner-a")
    assert {:error, {:lease_lock_timeout, ^lock_path}} = LeaseManager.release(issue_id)
    assert File.read!(lease_path) == payload
    assert File.read!(marker) == "must remain untouched"
  end

  test "filesystem errors while creating the lock fail without creating a lease", %{root: root} do
    File.write!(Path.join(root, "leases"), "not a directory")
    lock_path = LeaseManager.lease_path("unwritable-lock") <> ".lock"

    assert {:error, {:lease_lock_failed, ^lock_path, _reason}} =
             LeaseManager.acquire("unwritable-lock", "LOCK-2", "owner-a")
  end

  test "invalid JSON and non-map leases cannot be acquired, refreshed or released" do
    issue_id = "invalid-lease"
    path = LeaseManager.lease_path(issue_id)
    File.mkdir_p!(Path.dirname(path))

    for payload <- ["{invalid-json", "[]", "null", "123", "\"text\""] do
      File.write!(path, payload)
      assert {:error, _reason} = LeaseManager.acquire(issue_id, "LOCK-3", "owner-a")
      assert {:error, _reason} = LeaseManager.refresh(issue_id, "owner-a")
      assert {:error, release_reason} = LeaseManager.release(issue_id, "owner-a")

      if payload == "{invalid-json" do
        assert %Jason.DecodeError{} = release_reason
      else
        assert release_reason == :invalid_lease
      end

      assert File.read!(path) == payload
      refute File.exists?(path <> ".lock")
    end
  end

  defp seed_expired_lease(issue_id) do
    path = LeaseManager.lease_path(issue_id)
    timestamp = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601()
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        issue_id: issue_id,
        issue_identifier: "CONCURRENT-1",
        owner: "old-owner",
        lease_version: 1,
        epoch: 7,
        acquired_at: timestamp,
        updated_at: timestamp
      })
    )
  end

  defp contend(root, issue_id, operations) do
    gate = Path.join(root, issue_id <> ".go")

    executable =
      System.find_executable("elixir") ||
        raise "Elixir executable is required for cross-process lease tests"

    code_paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
    workflow_path = Workflow.workflow_file_path()
    log_file = Application.fetch_env!(:symphony_elixir, :log_file)

    candidates =
      for {owner, operation} <- operations do
        ready = Path.join(root, issue_id <> "-" <> owner <> ".ready")
        result_path = Path.join(root, issue_id <> "-" <> owner <> ".result")

        script = """
        Code.compiler_options(ignore_module_conflict: true)
        Code.compile_file(#{inspect(@source)})
        Application.put_env(:symphony_elixir, :workflow_file_path, #{inspect(workflow_path)})
        Application.put_env(:symphony_elixir, :log_file, #{inspect(log_file)})
        File.write!(#{inspect(ready)}, System.pid())
        wait = fn wait, deadline ->
          unless File.exists?(#{inspect(gate)}) do
            if System.monotonic_time(:millisecond) >= deadline, do: raise("start barrier timed out")
            Process.sleep(5)
            wait.(wait, deadline)
          end
        end
        wait.(wait, System.monotonic_time(:millisecond) + 15_000)
        result = #{operation_source(operation, issue_id, owner)}
        File.write!(#{inspect(result_path)}, :erlang.term_to_binary(result))
        """

        task =
          Task.async(fn ->
            System.cmd(executable, ["--erl", "+S 1:1"] ++ code_paths ++ ["-e", script], stderr_to_stdout: true)
          end)

        %{owner: owner, task: task, ready: ready, result_path: result_path}
      end

    wait_until_ready(candidates, System.monotonic_time(:millisecond) + 15_000)

    assert candidates |> Enum.map(&File.read!(&1.ready)) |> Enum.uniq() |> length() ==
             length(candidates)

    File.write!(gate, "go")

    Enum.map(candidates, fn candidate ->
      {output, status} = Task.await(candidate.task, 20_000)
      assert status == 0, output
      {candidate.owner, candidate.result_path |> File.read!() |> :erlang.binary_to_term([:safe])}
    end)
  end

  defp wait_until_ready(candidates, deadline) do
    if Enum.all?(candidates, &File.exists?(&1.ready)) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "independent BEAMs did not reach the start barrier"

      Process.sleep(10)
      wait_until_ready(candidates, deadline)
    end
  end

  defp operation_source(:acquire, issue_id, owner) do
    "SymphonyElixir.LeaseManager.acquire(#{inspect(issue_id)}, \"CONCURRENT-1\", #{inspect(owner)}, ttl_ms: 60_000)"
  end

  defp operation_source(:refresh, issue_id, owner) do
    "SymphonyElixir.LeaseManager.refresh(#{inspect(issue_id)}, #{inspect(owner)})"
  end

  defp operation_source(:release, issue_id, owner) do
    "SymphonyElixir.LeaseManager.release(#{inspect(issue_id)}, #{inspect(owner)})"
  end
end
