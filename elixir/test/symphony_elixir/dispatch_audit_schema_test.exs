defmodule SymphonyElixir.DispatchAuditSchemaTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, RunLedger}

  for {field, invalid_metadata} <- [{"requested", "not-a-map"}, {"authorized", ["not", "a", "map"]}] do
    @tag event_field: field, invalid_metadata: invalid_metadata
    test "parseable journal with malformed #{field} metadata is rejected without crashing", context do
      root = Path.join(System.tmp_dir!(), "dispatch-schema-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
      workspace = Path.join(root, "SCHEMA-1")
      on_exit(fn -> File.rm_rf!(root) end)
      attrs = %{issue_id: "schema-1", issue_identifier: "SCHEMA-1", metadata: %{owner: "schema-owner", epoch: 1}}
      assert {:ok, ticket} = DispatchAudit.begin(workspace, attrs)
      path = Path.join(DispatchAudit.marker_directory(workspace), "marker.json")
      corrupted = Jason.decode!(File.read!(path)) |> put_in([context.event_field, "metadata"], context.invalid_metadata)
      File.write!(path, Jason.encode!(corrupted))
      previous = File.read!(path)
      ledger = File.read!(RunLedger.ledger_file_path())
      expected = {:error, {:dispatch_audit_marker_unreadable, :invalid_dispatch_audit_marker}}
      assert DispatchAudit.ensure_workspace_access(workspace) == expected
      assert DispatchAudit.with_authorization(ticket, fn -> flunk("invalid journal executed") end) == expected
      assert DispatchAudit.finish(ticket, :not_started) == expected
      assert DispatchAudit.reconcile_finished(workspace) == expected
      assert File.read!(path) == previous
      assert File.read!(RunLedger.ledger_file_path()) == ledger
    end
  end
end
