defmodule SymphonyElixir.DispatchAuditWorkspaceBindingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchAudit, RunIdentity, RunStateStore, SecretRedactor}

  setup do
    root = Path.join(System.tmp_dir!(), "dispatch-workspace-binding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.fetch_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "runtime.log"))

    on_exit(fn ->
      File.rm_rf!(root)

      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :log_file, value)
        :error -> Application.delete_env(:symphony_elixir, :log_file)
      end
    end)

    %{root: root, attrs: %{issue_id: "binding-1", issue_identifier: "BINDING-1", metadata: %{owner: "binding-owner", epoch: 1}}}
  end

  test "a redacted workspace display retains usable captured admission and finish binding", c do
    workspace = Path.join([c.root, "token=workspace-binding-sentinel", "BINDING-1"])
    issue = %{id: c.attrs.issue_id, identifier: c.attrs.issue_identifier}
    assert {:ok, source, _view} = RunStateStore.read_admission_source(workspace, issue)

    attrs = Map.update!(c.attrs, :metadata, &Map.merge(&1, %{"workspace_digest" => "spoofed-string", :workspace_digest => "spoofed-atom"}))
    assert {:ok, ticket, admitted} = DispatchAudit.begin(workspace, attrs, source)
    assert admitted["run_id"] == ticket.run_id
    marker = File.read!(marker_path(workspace))
    snapshot = File.read!(RunStateStore.state_path(workspace))
    prefix = File.read!(ticket.ledger_path)
    events = rows(ticket.ledger_path) |> Enum.filter(&(&1["event_type"] in ["dispatch.requested", "dispatch.started"]))
    assert length(events) == 2

    for event <- events do
      assert event["metadata"]["workspace"] == SecretRedactor.redact(workspace)
      refute event["metadata"]["workspace"] =~ "workspace-binding-sentinel"
      assert event["metadata"]["workspace_digest"] == digest(workspace)
      assert event["metadata"]["run_id"] == ticket.run_id
      assert event["metadata"]["dispatch_id"] == ticket.dispatch_id
    end

    assert :ok = RunIdentity.verify(workspace, ticket.run_id, issue.id, issue.identifier)

    assert :ok =
             DispatchAudit.with_authorization(ticket, fn ->
               assert {:ok, ^ticket} = DispatchAudit.current_ticket()
               DispatchAudit.ensure_workspace_access(workspace)
             end)

    assert File.read!(marker_path(workspace)) == marker
    assert File.read!(RunStateStore.state_path(workspace)) == snapshot
    assert File.read!(ticket.ledger_path) == prefix
    assert {:error, :dispatch_context_missing} = DispatchAudit.current_ticket()
    assert {:error, :dispatch_audit_not_authorized} = DispatchAudit.ensure_workspace_access(workspace)
    assert :ok = DispatchAudit.finish(ticket, :not_started)
    assert :ok = DispatchAudit.ensure_available(workspace)
    assert File.read!(RunStateStore.state_path(workspace)) == snapshot
    assert String.starts_with?(File.read!(ticket.ledger_path), prefix)
    [finished] = Enum.filter(rows(ticket.ledger_path), &(&1["event_type"] == "dispatch.finished"))
    assert finished["metadata"]["authorization_event_id"] == ticket.entry_event_id
    assert finished["metadata"]["workspace"] == SecretRedactor.redact(workspace)
    assert finished["metadata"]["workspace_digest"] == digest(workspace)
  end

  test "a present contradictory or malformed digest never falls back to matching literal display", c do
    for field <- ["requested", "authorized"], invalid <- [digest(Path.join(c.root, "OTHER")), nil, ""] do
      workspace = Path.join(c.root, "INVALID-#{System.unique_integer([:positive])}")
      assert {:ok, ticket} = DispatchAudit.begin(workspace, c.attrs)
      path = marker_path(workspace)
      marker = path |> File.read!() |> Jason.decode!()
      assert marker[field]["metadata"]["workspace"] == workspace
      corrupted = put_in(marker, [field, "metadata", "workspace_digest"], invalid)
      File.write!(path, Jason.encode!(corrupted))
      before = %{marker: File.read!(path), ledger: File.read!(ticket.ledger_path), snapshot: File.read!(RunStateStore.state_path(workspace))}
      expected = {:error, {:dispatch_audit_marker_unreadable, :invalid_dispatch_audit_marker}}

      assert DispatchAudit.with_authorization(ticket, fn -> flunk("contradictory binding authorized") end) == expected
      assert DispatchAudit.ensure_workspace_access(workspace) == expected
      assert DispatchAudit.finish(ticket, :not_started) == expected
      assert DispatchAudit.reconcile_finished(workspace) == expected
      assert File.read!(path) == before.marker
      assert File.read!(ticket.ledger_path) == before.ledger
      assert File.read!(RunStateStore.state_path(workspace)) == before.snapshot
      assert {:error, {:dispatch_audit_pending, ^workspace}} = DispatchAudit.ensure_available(workspace)
    end
  end

  test "historical digest-absent events require exact literal workspace and retain their bytes at finish", c do
    workspace = Path.join(c.root, "LEGACY-1")
    assert {:ok, ticket} = DispatchAudit.begin(workspace, c.attrs)
    snapshot = File.read!(RunStateStore.state_path(workspace))
    install_historical_event_format!(ticket)
    path = marker_path(workspace)
    marker = File.read!(path)
    prefix = File.read!(ticket.ledger_path)
    historical = Jason.decode!(marker)

    for field <- ["requested", "authorized"] do
      refute Map.has_key?(historical[field]["metadata"], "workspace_digest")
      assert historical[field]["metadata"]["workspace"] == workspace
    end

    assert :ok = RunIdentity.verify(workspace, ticket.run_id, c.attrs.issue_id, c.attrs.issue_identifier)

    assert :ok =
             DispatchAudit.with_authorization(ticket, fn ->
               assert {:ok, ^ticket} = DispatchAudit.current_ticket()
               DispatchAudit.ensure_workspace_access(workspace)
             end)

    assert File.read!(path) == marker
    assert File.read!(ticket.ledger_path) == prefix
    assert File.read!(RunStateStore.state_path(workspace)) == snapshot

    # Digest absence does not permit matching a redacted or substituted display.
    contradictory = put_in(historical, ["authorized", "metadata", "workspace"], "[REDACTED]")
    File.write!(path, Jason.encode!(contradictory))
    expected = {:error, {:dispatch_audit_marker_unreadable, :invalid_dispatch_audit_marker}}
    assert DispatchAudit.with_authorization(ticket, fn -> flunk("legacy display became authority") end) == expected
    assert DispatchAudit.finish(ticket, :not_started) == expected
    assert File.read!(ticket.ledger_path) == prefix
    assert File.read!(RunStateStore.state_path(workspace)) == snapshot
    assert File.read!(path) == Jason.encode!(contradictory)

    File.write!(path, marker)
    assert :ok = DispatchAudit.finish(ticket, :not_started)
    assert :ok = DispatchAudit.ensure_available(workspace)
    assert String.starts_with?(File.read!(ticket.ledger_path), prefix)
    assert File.read!(RunStateStore.state_path(workspace)) == snapshot
  end

  # Explicit historical-schema fixture, not a product migration: retain the
  # genuine ticket, event IDs, RunIdentity entries and RAW; remove only the new
  # field from the two existing dispatch records and their journal copies.
  defp install_historical_event_format!(ticket) do
    path = marker_path(ticket.workspace)
    marker = path |> File.read!() |> Jason.decode!()
    ids = Enum.map(["requested", "authorized"], &marker[&1]["event_id"])
    old_lines = ticket.ledger_path |> File.read!() |> String.split("\n", trim: true)

    new_lines =
      Enum.map(old_lines, fn line ->
        entry = Jason.decode!(line)
        if entry["event_id"] in ids, do: Jason.encode!(update_in(entry, ["metadata"], &Map.delete(&1, "workspace_digest"))), else: line
      end)

    for {old, new} <- Enum.zip(old_lines, new_lines), Jason.decode!(old)["event_id"] not in ids, do: assert(old == new)
    File.write!(ticket.ledger_path, Enum.join(new_lines, "\n") <> "\n")

    historical =
      Enum.reduce(["requested", "authorized"], marker, fn field, acc ->
        update_in(acc, [field, "metadata"], &Map.delete(&1, "workspace_digest"))
      end)

    File.write!(path, Jason.encode!(historical))
  end

  defp rows(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp marker_path(workspace), do: Path.join(DispatchAudit.marker_directory(workspace), "marker.json")
  defp digest(workspace), do: :crypto.hash(:sha256, Path.expand(workspace)) |> Base.encode16(case: :lower)
end
