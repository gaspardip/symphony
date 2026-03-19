defmodule SymphonyElixir.ManualIssueStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{IssueSource, ManualIssueStore, Workflow}

  setup do
    store_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-manual-store-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      manual_store_root: store_root,
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"]
    )

    on_exit(fn -> File.rm_rf(store_root) end)

    {:ok, store_root: store_root}
  end

  test "submits, persists, and updates manual issues" do
    payload = %{
      "id" => "clz-14",
      "identifier" => "CLZ-14",
      "title" => "Manual pilot issue",
      "description" => "Tracker-free end-to-end test",
      "acceptance_criteria" => ["Build a PR", "Merge it"],
      "validation" => ["Run validation"],
      "labels" => ["symphony:events"],
      "policy_class" => "review_required",
      "internal_identifier" => "SYM-CLZ-14",
      "internal_url" => "https://linear.app/internal/issue/SYM-CLZ-14"
    }

    assert {:ok, issue} = ManualIssueStore.submit(payload)
    assert issue.source == :manual

    assert {:ok, fetched_issue} = ManualIssueStore.fetch_issue_by_identifier("CLZ-14")
    assert fetched_issue.id == issue.id
    assert fetched_issue.external_id == "clz-14"
    assert fetched_issue.canonical_identifier == "CLZ-14"
    assert fetched_issue.state == "Todo"
    assert fetched_issue.internal_identifier == "SYM-CLZ-14"
    assert fetched_issue.internal_url == "https://linear.app/internal/issue/SYM-CLZ-14"

    assert {:ok, [%{identifier: "CLZ-14"}]} = ManualIssueStore.fetch_candidate_issues()
    assert {:ok, [manual_candidate]} = IssueSource.fetch_manual_candidate_issues()
    assert manual_candidate.id == issue.id

    assert :ok = ManualIssueStore.create_comment(issue.id, "Waiting on verification.")
    assert :ok = ManualIssueStore.attach_link(issue.id, "PR", "https://github.com/example/repo/pull/14")
    assert :ok = ManualIssueStore.update_issue_state(issue.id, "Human Review")

    assert {:ok, record} = ManualIssueStore.load_record_by_identifier("CLZ-14")
    assert record.issue.state == "Human Review"
    assert record.last_decision_summary == "Moved to Human Review"
    assert [%{"body" => "Waiting on verification."} | _] = Enum.reverse(record.comments)
    assert [%{"title" => "PR", "url" => "https://github.com/example/repo/pull/14"} | _] = Enum.reverse(record.links)

    ref = IssueSource.issue_ref(record.issue)
    assert ref.source == :manual
    assert ref.id == issue.id
    assert ref.external_id == "clz-14"
    assert ref.canonical_identifier == "CLZ-14"

    assert {:ok, refreshed_issue} = IssueSource.fetch_issue(ref)
    assert refreshed_issue.id == issue.id
    assert refreshed_issue.external_id == "clz-14"
    assert {:ok, [manual_by_state]} = IssueSource.fetch_manual_issues_by_states(["Human Review"])
    assert manual_by_state.id == issue.id
    assert {:ok, [manual_by_id]} = IssueSource.fetch_manual_issue_states_by_ids([issue.id, "tracker-1"])
    assert manual_by_id.id == issue.id
  end

  test "rejects duplicate manual issues by id or identifier" do
    payload = %{
      "id" => "clz-14",
      "identifier" => "CLZ-14",
      "title" => "Manual pilot issue",
      "acceptance_criteria" => ["Keep identifiers unique"]
    }

    assert {:ok, _issue} = ManualIssueStore.submit(payload)

    assert {:error, :duplicate_manual_issue} = ManualIssueStore.submit(payload)

    assert {:error, :duplicate_manual_issue} =
             ManualIssueStore.submit(%{
               "id" => "clz-14-second",
               "identifier" => "CLZ-14",
               "title" => "Same identifier",
               "acceptance_criteria" => ["Still unique"]
             })
  end

  test "manual issue store ignores blank persisted records and leaves no temp files after updates",
       %{store_root: store_root} do
    payload = %{
      "id" => "clz-15",
      "identifier" => "CLZ-15",
      "title" => "Atomic manual issue record",
      "acceptance_criteria" => ["Persist cleanly"]
    }

    assert {:ok, issue} = ManualIssueStore.submit(payload)
    assert :ok = ManualIssueStore.update_issue_state(issue.id, "Human Review")

    File.write!(
      Path.join(store_root, Base.url_encode64("manual:blank-record", padding: false) <> ".json"),
      " \n"
    )

    assert {:ok, fetched_issue} = ManualIssueStore.fetch_issue_by_identifier("CLZ-15")
    assert fetched_issue.id == issue.id
    assert fetched_issue.state == "Human Review"
    assert Path.wildcard(Path.join(store_root, "*.tmp-*")) == []
  end
end
