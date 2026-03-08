defmodule SymphonyElixir.RecoveryAndLeaseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LeaseManager, RunStateStore}

  test "run state store merges new defaults into older persisted state files" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-state-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        RunStateStore.state_path(workspace),
        Jason.encode!(%{
          "issue_id" => "issue-legacy",
          "issue_identifier" => "MT-401",
          "stage" => "await_checks",
          "last_check_statuses" => [%{"name" => "ci / validate", "status" => "IN_PROGRESS"}]
        })
      )

      state =
        RunStateStore.load_or_default(workspace, %Issue{id: "issue-legacy", identifier: "MT-401"})

      assert state.stage == "await_checks"
      assert state.issue_id == "issue-legacy"
      assert state.await_checks_polls == 0
      assert state.merge_attempts == 0
      assert state.stage_transition_counts == %{}
      assert state.last_check_statuses == [%{name: "ci / validate", status: "IN_PROGRESS"}]
      assert state.last_required_checks_state == nil
    after
      File.rm_rf(workspace)
    end
  end

  test "lease takeover increments epoch and stale owners cannot refresh" do
    issue_id = "issue-lease-#{System.unique_integer([:positive])}"
    path = LeaseManager.lease_path(issue_id)
    old_timestamp = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    try do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: "MT-402",
          owner: "owner-a",
          lease_version: 1,
          epoch: 2,
          acquired_at: old_timestamp,
          updated_at: old_timestamp
        })
      )

      assert :ok = LeaseManager.acquire(issue_id, "MT-402", "owner-b", ttl_ms: 1)
      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert lease["owner"] == "owner-b"
      assert lease["epoch"] == 3
      assert LeaseManager.refresh(issue_id, "owner-a") == {:error, :claimed}
      assert :ok = LeaseManager.refresh(issue_id, "owner-b")
    after
      File.rm(path)
    end
  end
end
