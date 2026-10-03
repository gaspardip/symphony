defmodule SymphonyElixir.RunStateIssueUpdateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, LeaseManager, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "issue-update-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "ISSUE-UPDATE-1")
    issue = %{id: "issue-update-1", identifier: "ISSUE-UPDATE-1", source: :tracker}
    on_exit(fn -> File.rm_rf!(root) end)
    %{workspace: workspace, issue: issue}
  end

  test "a missing snapshot receives the issue identity before admission", c do
    assert {:ok, updated} = RunStateStore.update(c.workspace, c.issue, &Map.put(&1, :review_approved, true))
    assert updated.issue_id == c.issue.id
    assert updated.issue_identifier == c.issue.identifier
    assert updated.issue_source == c.issue.source
    assert updated.review_approved
    assert Jason.decode!(File.read!(RunStateStore.state_path(c.workspace))) == Jason.decode!(Jason.encode!(updated))
    assert {:ok, persisted} = RunStateStore.load(c.workspace)
    assert persisted.issue_id == c.issue.id
    assert persisted.issue_identifier == c.issue.identifier
    assert persisted.issue_source == "tracker"
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "issue-update-owner")
    attrs = %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: updated.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}
    assert {:ok, _ticket} = DispatchAudit.begin(c.workspace, attrs)
  end

  test "a matching snapshot retains its stage and existing material", c do
    raw = %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: "validate", policy_override: "never_automerge"}
    assert :ok = RunStateStore.save(c.workspace, raw)
    assert {:ok, updated} = RunStateStore.update(c.workspace, c.issue, &Map.put(&1, :review_approved, true))
    assert updated.stage == "validate"
    assert updated.policy_override == "never_automerge"
    assert updated.issue_id == c.issue.id
    assert updated.issue_identifier == c.issue.identifier
    assert updated.review_approved
  end

  for {field, value} <- [issue_id: "different-issue", issue_identifier: "DIFFERENT-IDENTIFIER"] do
    test "a snapshot with mismatched #{field} rejects the update without invoking its callback", c do
      raw = Map.put(%{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: "validate"}, unquote(field), unquote(value))
      assert :ok = RunStateStore.save(c.workspace, raw)
      before = File.read!(RunStateStore.state_path(c.workspace))
      owner = self()

      assert {:error, :run_identity_issue_mismatch} =
               RunStateStore.update(c.workspace, c.issue, fn state ->
                 send(owner, :callback_invoked)
                 state
               end)

      refute_received :callback_invoked
      assert File.read!(RunStateStore.state_path(c.workspace)) == before
    end
  end

  test "an unreadable snapshot rejects the update without changing its bytes", c do
    path = RunStateStore.state_path(c.workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{invalid-json")
    owner = self()

    assert {:error, %Jason.DecodeError{}} =
             RunStateStore.update(c.workspace, c.issue, fn state ->
               send(owner, :callback_invoked)
               state
             end)

    refute_received :callback_invoked
    assert File.read!(path) == "{invalid-json"
  end

  test "the update callback cannot replace the issue identity", c do
    assert {:error, :run_identity_issue_mismatch} = RunStateStore.update(c.workspace, c.issue, &Map.put(&1, :issue_id, "different-issue"))
    refute File.exists?(RunStateStore.state_path(c.workspace))
  end
end
