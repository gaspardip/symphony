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

  describe "checked lookup" do
    test "returns the stored issue intact without changing the record", %{store_root: root} do
      assert {:ok, issue} =
               ManualIssueStore.submit(%{
                 "id" => "checked",
                 "identifier" => "CHECKED-1",
                 "title" => "Checked manual issue",
                 "acceptance_criteria" => ["Read exact record"]
               })

      assert {:ok, record} = ManualIssueStore.load_record_by_identifier(issue.identifier)
      expected = record.issue
      path = checked_path(root, issue.id)
      bytes = File.read!(path)

      assert {:ok, ^expected} = ManualIssueStore.fetch_issue_by_id_checked(issue.id, root)
      assert File.read!(path) == bytes
    end

    test "uses the captured root instead of the current workflow root", %{store_root: root} do
      id = "manual:captured"
      captured = Path.join(root, "captured")
      replacement = Path.join(root, "replacement")
      checked_record!(captured, id, %{"identifier" => "CAPTURED-1"})
      checked_record!(replacement, id, %{"identifier" => "REPLACEMENT-1"})
      write_workflow_file!(Workflow.workflow_file_path(), manual_store_root: replacement)

      assert {:ok, %{id: ^id, identifier: "CAPTURED-1", source: :manual}} =
               ManualIssueStore.fetch_issue_by_id_checked(id, captured)

      assert {:ok, %{identifier: "REPLACEMENT-1"}} = ManualIssueStore.fetch_issue_by_id(id)
    end

    test "only physical target absence is nil and lookup creates nothing", %{store_root: root} do
      checked_record!(root, "manual:sibling")
      before = Enum.sort(File.ls!(root))
      missing_root = Path.join(root, "absent-root")

      assert {:ok, nil} = ManualIssueStore.fetch_issue_by_id_checked("manual:missing", root)
      assert {:ok, nil} = ManualIssueStore.fetch_issue_by_id_checked("manual:missing", missing_root)
      assert Enum.sort(File.ls!(root)) == before
      assert {:error, :enoent} = File.lstat(missing_root)
    end

    test "a healthy sibling cannot hide corrupt target JSON", %{store_root: root} do
      id = "manual:corrupt"
      checked_record!(root, "manual:sibling")
      path = checked_path(root, id)
      File.write!(path, "{broken-target")
      bytes = File.read!(path)

      assert {:error, {:manual_issue_decode_failed, %Jason.DecodeError{}}} =
               ManualIssueStore.fetch_issue_by_id_checked(id, root)

      assert File.read!(path) == bytes
      assert {:ok, nil} = ManualIssueStore.fetch_issue_by_id(id, root)
    end

    test "directory and non-directory IO failures stay explicit", %{store_root: root} do
      id = "manual:io"
      File.mkdir_p!(checked_path(root, id))

      assert {:error, {:manual_issue_read_failed, :eisdir}} = ManualIssueStore.fetch_issue_by_id_checked(id, root)

      root_file = Path.join(root, "not-a-directory")
      File.write!(root_file, "unchanged")
      assert {:error, {:manual_issue_read_failed, :enotdir}} = ManualIssueStore.fetch_issue_by_id_checked(id, root_file)
      assert File.read!(root_file) == "unchanged"
    end

    test "requires a JSON object containing an issue object", %{store_root: root} do
      id = "manual:shape"
      File.mkdir_p!(root)

      for payload <- [nil, [], "record", %{}, %{"issue" => nil}, %{"issue" => []}] do
        path = checked_path(root, id)
        bytes = Jason.encode!(payload)
        File.write!(path, bytes)
        assert {:error, :invalid_manual_issue_record} = ManualIssueStore.fetch_issue_by_id_checked(id, root)
        assert File.read!(path) == bytes
      end
    end

    test "checks identity and explicit physical manual source before legacy decoding", %{store_root: root} do
      id = "manual:identity"
      valid = %{"id" => id, "identifier" => "MAN-1", "source" => "manual"}

      mutations = [
        {"id", nil, :id},
        {"id", "", :id},
        {"id", "manual:other", :id},
        {"id", 42, :id},
        {"identifier", nil, :identifier},
        {"identifier", "", :identifier},
        {"identifier", 42, :identifier},
        {"source", nil, :source},
        {"source", "tracker", :source},
        {"source", "unknown", :source},
        {"source", false, :source}
      ]

      File.mkdir_p!(root)

      for {key, value, field} <- mutations do
        path = checked_path(root, id)
        bytes = Jason.encode!(%{"issue" => Map.put(valid, key, value)})
        File.write!(path, bytes)

        assert {:error, {:manual_issue_identity_mismatch, ^field}} = ManualIssueStore.fetch_issue_by_id_checked(id, root)
        assert File.read!(path) == bytes
      end

      for {key, field} <- [{"id", :id}, {"identifier", :identifier}, {"source", :source}] do
        File.write!(checked_path(root, id), Jason.encode!(%{"issue" => Map.delete(valid, key)}))
        assert {:error, {:manual_issue_identity_mismatch, ^field}} = ManualIssueStore.fetch_issue_by_id_checked(id, root)
      end
    end
  end

  describe "checked identifier lookup" do
    test "reads the exact submitted issue without rewriting any record", %{store_root: root} do
      assert {:ok, issue} = ManualIssueStore.submit(%{"id" => "identifier", "identifier" => "ID-1", "title" => "Identifier", "acceptance_criteria" => ["Read exact issue"]})
      assert {:ok, record} = ManualIssueStore.load_record_by_identifier(issue.identifier)
      expected = record.issue
      path = checked_path(root, issue.id)
      before = File.read!(path)

      assert {:ok, ^expected} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
      assert File.read!(path) == before
    end

    test "uses the captured collection after the workflow root changes", %{store_root: root} do
      captured = Path.join(root, "captured-identifier")
      replacement = Path.join(root, "replacement-identifier")
      checked_record!(captured, "manual:old", %{"identifier" => "SAME-1"})
      checked_record!(replacement, "manual:new", %{"identifier" => "SAME-1"})
      write_workflow_file!(Workflow.workflow_file_path(), manual_store_root: replacement)

      assert {:ok, %{id: "manual:old"}} = ManualIssueStore.fetch_issue_by_identifier_checked("SAME-1", captured)
      assert {:ok, %{id: "manual:new"}} = ManualIssueStore.fetch_issue_by_identifier("SAME-1")
    end

    test "missing collection and unmatched identifier are nil without creating files", %{store_root: root} do
      assert {:ok, nil} = ManualIssueStore.fetch_issue_by_identifier_checked("ABSENT-1", root)
      assert {:error, :enoent} = File.lstat(root)
      checked_record!(root, "manual:other", %{"identifier" => "OTHER-1"})
      File.write!(Path.join(root, "notes.txt"), "not a record")
      names = Enum.sort(File.ls!(root))
      assert {:ok, nil} = ManualIssueStore.fetch_issue_by_identifier_checked("ABSENT-1", root)
      assert Enum.sort(File.ls!(root)) == names
    end

    test "a non-directory collection is an IO error rather than absence", %{store_root: root} do
      File.write!(root, "unchanged root file")
      assert {:error, {:manual_issue_list_failed, :enotdir}} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
      assert File.read!(root) == "unchanged root file"
    end

    test "a matching record cannot hide corrupt sibling JSON", %{store_root: root} do
      checked_record!(root, "manual:match", %{"identifier" => "MATCH-1"})
      corrupt = checked_path(root, "manual:sibling")
      File.write!(corrupt, "{broken sibling")
      before = File.read!(corrupt)
      assert {:error, {:manual_issue_decode_failed, %Jason.DecodeError{}}} = ManualIssueStore.fetch_issue_by_identifier_checked("MATCH-1", root)
      assert File.read!(corrupt) == before
    end

    test "rejects duplicate requested identifiers without picking an arbitrary record", %{store_root: root} do
      checked_record!(root, "manual:first", %{"identifier" => "DUP-1"})
      checked_record!(root, "manual:second", %{"identifier" => "DUP-1"})
      before = for name <- File.ls!(root), into: %{}, do: {name, File.read!(Path.join(root, name))}
      assert {:error, :duplicate_manual_issue_identifier} = ManualIssueStore.fetch_issue_by_identifier_checked("DUP-1", root)
      assert before == for(name <- File.ls!(root), into: %{}, do: {name, File.read!(Path.join(root, name))})
    end

    test "duplicate unrelated identifiers do not redefine uniqueness of the requested identifier", %{store_root: root} do
      checked_record!(root, "manual:first", %{"identifier" => "OTHER-1"})
      checked_record!(root, "manual:second", %{"identifier" => "OTHER-1"})
      checked_record!(root, "manual:target", %{"identifier" => "TARGET-1"})
      assert {:ok, %{id: "manual:target"}} = ManualIssueStore.fetch_issue_by_identifier_checked("TARGET-1", root)
    end

    test "validates canonical filename identity before accepting its payload", %{store_root: root} do
      File.mkdir_p!(root)

      for name <- [".json", "not+base64.json", "YQ==.json", "_w.json", "YQ.json.json"] do
        path = Path.join(root, name)
        File.write!(path, Jason.encode!(%{"issue" => %{"id" => "manual:payload", "identifier" => "ID-1", "source" => "manual"}}))
        assert {:error, :invalid_manual_issue_filename} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
        File.rm!(path)
      end

      checked_record!(root, "manual:filename", %{"id" => "manual:different", "identifier" => "ID-1"})
      assert {:error, {:manual_issue_identity_mismatch, :id}} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
    end

    test "validates every record shape and real manual source without legacy decoding fallback", %{store_root: root} do
      id = "manual:invalid-record"
      File.mkdir_p!(root)
      path = checked_path(root, id)

      for payload <- [nil, [], %{}, %{"issue" => nil}, %{"issue" => []}] do
        File.write!(path, Jason.encode!(payload))
        assert {:error, :invalid_manual_issue_record} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
      end

      for source <- [nil, false, "tracker", "unexpected"] do
        checked_record!(root, id, %{"identifier" => "ID-1", "source" => source})
        assert {:error, {:manual_issue_identity_mismatch, :source}} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
      end

      checked_record!(root, id, %{"identifier" => ""})
      assert {:error, {:manual_issue_identity_mismatch, :identifier}} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
    end

    test "an unreadable listed record stays a read error", %{store_root: root} do
      File.mkdir_p!(checked_path(root, "manual:directory"))
      assert {:error, {:manual_issue_read_failed, :eisdir}} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
    end

    test "enoent for a captured collection entry is not collection absence", %{store_root: root} do
      File.mkdir_p!(root)
      path = checked_path(root, "manual:dangling")
      assert :ok = File.ln_s(Path.join(root, "missing-target"), path)
      assert Path.basename(path) in File.ls!(root)
      assert {:error, {:manual_issue_read_failed, :enoent}} = ManualIssueStore.fetch_issue_by_identifier_checked("ID-1", root)
      assert {:ok, %{type: :symlink}} = File.lstat(path)
    end
  end

  defp checked_path(root, id), do: Path.join(root, Base.url_encode64(id, padding: false) <> ".json")

  defp checked_record!(root, id, attrs \\ %{}) do
    File.mkdir_p!(root)
    issue = Map.merge(%{"id" => id, "identifier" => "MAN-1", "source" => "manual"}, attrs)
    File.write!(checked_path(root, id), Jason.encode!(%{"issue" => issue}))
  end
end
