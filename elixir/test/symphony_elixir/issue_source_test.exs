defmodule SymphonyElixir.IssueSourceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{IssueSource, ManualIssueStore, Workflow}
  alias SymphonyElixir.Linear.Issue

  setup do
    store_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-issue-source-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      manual_store_root: store_root
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "tracker-123",
        external_id: "tracker-123",
        canonical_identifier: "TRK-123",
        identifier: "TRK-123",
        title: "Tracker issue",
        state: "Todo",
        source: :tracker
      }
    ])

    on_exit(fn ->
      File.rm_rf(store_root)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    :ok
  end

  test "issue_ref normalizes manual and tracker issue identities" do
    assert {:ok, manual_issue} =
             ManualIssueStore.submit(%{
               "id" => "manual-123",
               "identifier" => "MAN-123",
               "title" => "Manual issue",
               "acceptance_criteria" => ["Keep identity normalized"]
             })

    manual_ref = IssueSource.issue_ref(manual_issue)
    assert manual_ref.source == :manual
    assert manual_ref.id == "manual:manual-123"
    assert manual_ref.external_id == "manual-123"
    assert manual_ref.canonical_identifier == "MAN-123"

    tracker_ref =
      IssueSource.issue_ref(%{
        "id" => "tracker-123",
        "identifier" => "TRK-123",
        "source" => "tracker"
      })

    assert tracker_ref.source == :tracker
    assert tracker_ref.id == "tracker-123"
    assert tracker_ref.external_id == "tracker-123"
    assert tracker_ref.canonical_identifier == "TRK-123"
  end

  test "fetch_issue resolves both manual and tracker issues from normalized refs" do
    assert {:ok, manual_issue} =
             ManualIssueStore.submit(%{
               "id" => "manual-lookup",
               "identifier" => "MAN-LOOKUP",
               "title" => "Manual lookup",
               "acceptance_criteria" => ["Resolve manual issue from issue_ref"]
             })

    assert {:ok, fetched_manual} = IssueSource.fetch_issue(IssueSource.issue_ref(manual_issue))
    assert fetched_manual.identifier == "MAN-LOOKUP"
    assert fetched_manual.source == :manual

    assert {:ok, fetched_tracker} =
             IssueSource.fetch_issue(%{
               source: :tracker,
               id: "tracker-123",
               canonical_identifier: "TRK-123"
             })

    assert fetched_tracker.identifier == "TRK-123"
    assert fetched_tracker.source == :tracker
  end

  test "tracker-backed mutations are blocked in client-safe shadow mode" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      manual_store_root:
        Path.join(
          System.tmp_dir!(),
          "symphony-issue-source-shadow-#{System.unique_integer([:positive])}"
        ),
      company_policy_pack: "client_safe"
    )

    assert {:error, {:tracker_mutation_forbidden, "client_safe_shadow"}} =
             IssueSource.create_comment("tracker-123", "shadow comment")

    assert {:error, {:tracker_mutation_forbidden, "client_safe_shadow"}} =
             IssueSource.update_issue_state("tracker-123", "Blocked")

    assert {:error, {:tracker_mutation_forbidden, "client_safe_shadow"}} =
             IssueSource.attach_link("tracker-123", "PR", "https://example.com/pr")
  end

  test "tracker-backed mutations are blocked by the credential registry" do
    registry_path =
      Path.join(System.tmp_dir!(), "symphony-issue-source-registry-#{System.unique_integer([:positive])}.json")

    File.write!(
      registry_path,
      Jason.encode!(%{
        "companies" => %{
          "Client A" => %{
            "providers" => %{
              "tracker" => %{"forbidden_operations" => ["write"]}
            }
          }
        }
      })
    )

    on_exit(fn -> File.rm(registry_path) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      company_name: "Client A",
      company_credential_registry_path: registry_path
    )

    assert {:error, {:credential_scope_forbidden, "tracker", "write"}} =
             IssueSource.create_comment("tracker-123", "shadow comment")
  end
end
