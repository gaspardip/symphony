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

  defmodule CheckedClient do
    def fetch_issue_by_id(id) do
      {owner, action} = Application.fetch_env!(:symphony_elixir, :c5_checked_issue_source_response)
      send(owner, {:checked_source_called, self(), id})

      case action do
        {:return, result} ->
          result

        {:raise, message} ->
          raise ArgumentError, message

        {:hold, ref} ->
          send(owner, {:checked_source_held, self(), ref})

          receive do
            {:release_checked_source, ^ref, result} -> result
          end
      end
    end

    def telemetry(event, measurements, metadata, owner) do
      if self() == owner, do: send(owner, {:checked_source_event, event, measurements, metadata})
    end
  end

  defmodule ReplacementCheckedClient do
    def fetch_issue_by_id(_id), do: raise("replacement captured client must not be called")
  end

  describe "checked lookup" do
    setup do
      previous =
        for key <- [:linear_client_module, :c5_checked_issue_source_response] do
          {key, Application.fetch_env(:symphony_elixir, key)}
        end

      on_exit(fn ->
        Enum.each(previous, fn
          {key, :error} -> Application.delete_env(:symphony_elixir, key)
          {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
        end)
      end)

      context = %{Config.tracker_read_context() | tracker_kind: "linear", linear_client_module: CheckedClient}
      {:ok, read_context: context, ref: %{id: "tracker-123", identifier: "TRK-123", source: :tracker}}
    end

    test "keeps the captured client and tracker route after configuration changes", c do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", manual_store_root: c.read_context.manual_store_root)
      Application.put_env(:symphony_elixir, :linear_client_module, CheckedClient)
      context = Config.tracker_read_context()
      Application.put_env(:symphony_elixir, :linear_client_module, ReplacementCheckedClient)
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", manual_store_root: c.read_context.manual_store_root)
      issue = %Issue{id: c.ref.id, identifier: c.ref.identifier, source: nil, title: "Captured client"}
      checked_reply!({:ok, issue})

      assert {:ok, {:issue, :tracker, ^issue}} = IssueSource.fetch_issue_checked(c.ref, context)
      assert_received {:checked_source_called, _, "tracker-123"}
      refute_received {:checked_source_called, _, _}
    end

    test "accepts nil tracker source unchanged for explicit and legacy routes", c do
      context = %{c.read_context | tracker_kind: "memory"}

      for issue_source <- [nil, :tracker], source <- [:tracker, "tracker", nil] do
        issue = %Issue{id: c.ref.id, identifier: c.ref.identifier, source: issue_source}
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
        assert {:ok, {:issue, :tracker, ^issue}} = IssueSource.fetch_issue_checked(%{c.ref | source: source}, context)
      end
    end

    test "accepts a real manual record for explicit or nil namespace routes from the captured root", c do
      id = "manual:captured"
      root = c.read_context.manual_store_root
      path = checked_manual_record!(root, id, %{"identifier" => "MAN-CAPTURED"})
      bytes = File.read!(path)
      write_workflow_file!(Workflow.workflow_file_path(), manual_store_root: Path.join(root, "replacement"))
      ref = %{id: id, identifier: "MAN-CAPTURED", source: :manual}

      for source <- [:manual, "manual", nil] do
        assert {:ok, {:issue, :manual, %Issue{id: ^id, identifier: "MAN-CAPTURED", source: :manual}}} =
                 IssueSource.fetch_issue_checked(%{ref | source: source}, c.read_context)
      end

      assert File.read!(path) == bytes
      refute_received {:checked_source_called, _, _}
    end

    test "reports missing per route and never constructs a seed or creates a record", c do
      checked_reply!({:ok, nil})
      assert {:ok, {:missing, :tracker}} = IssueSource.fetch_issue_checked(c.ref, c.read_context)
      assert_received {:checked_source_called, _, "tracker-123"}
      id = "manual:missing"
      path = checked_manual_path(c.read_context.manual_store_root, id)
      assert {:error, :enoent} = File.lstat(path)

      for source <- [:manual, nil] do
        assert {:ok, {:missing, :manual}} =
                 IssueSource.fetch_issue_checked(%{id: id, identifier: "MISSING-1", source: source}, c.read_context)
      end

      assert {:error, :enoent} = File.lstat(path)
      refute_received {:checked_source_called, _, _}
    end

    test "disabled routes avoid the backend and do not become missing", c do
      checked_action!({:raise, "disabled backend must not run"})
      assert {:ok, {:disabled, :tracker}} = IssueSource.fetch_issue_checked(c.ref, %{c.read_context | tracker_kind: nil})
      assert {:ok, {:disabled, :tracker}} = IssueSource.fetch_issue_checked(c.ref, %{c.read_context | tracker_kind: ""})
      id = "manual:disabled"
      path = checked_manual_record!(c.read_context.manual_store_root, id)
      File.write!(path, "{corrupt-but-disabled")

      assert {:ok, {:disabled, :manual}} =
               IssueSource.fetch_issue_checked(%{id: id, identifier: "MAN-1", source: :manual}, %{c.read_context | manual_enabled: false})

      assert File.read!(path) == "{corrupt-but-disabled"
      refute_received {:checked_source_called, _, _}
    end

    test "invalid refs never infer an invalid source or replace missing identity", c do
      checked_action!({:raise, "invalid reference must not reach backend"})

      refs = [
        {nil, :id},
        {%{}, :id},
        {Map.delete(c.ref, :id), :id},
        {%{c.ref | id: ""}, :id},
        {%{c.ref | id: 42}, :id},
        {Map.delete(c.ref, :identifier), :identifier},
        {%{c.ref | identifier: nil}, :identifier},
        {%{c.ref | identifier: ""}, :identifier},
        {%{c.ref | identifier: 42}, :identifier},
        {Map.delete(c.ref, :source), :source},
        {%{c.ref | source: false}, :source},
        {%{c.ref | source: "unknown"}, :source},
        {%{id: "manual:invalid", identifier: "MAN-1", source: :unknown}, :source},
        {%{source: :tracker, external_id: c.ref.id, canonical_identifier: c.ref.identifier}, :id}
      ]

      for {ref, field} <- refs do
        assert {:ok, {:invalid, :reference, {:invalid_issue_ref, ^field}}} = IssueSource.fetch_issue_checked(ref, c.read_context)
      end

      refute_received {:checked_source_called, _, _}
    end

    test "remote identity is exact and its source cannot change the captured route", c do
      valid = %Issue{id: c.ref.id, identifier: c.ref.identifier, source: :tracker}

      for {issue, field} <- [
            {%{valid | id: "other"}, :id},
            {%{valid | id: " tracker-123 "}, :id},
            {%{valid | identifier: "OTHER-1"}, :identifier},
            {%{valid | source: :manual}, :source},
            {%{valid | source: "tracker"}, :source}
          ] do
        checked_reply!({:ok, issue})
        assert {:ok, {:invalid, :issue, {:issue_identity_mismatch, ^field}}} = IssueSource.fetch_issue_checked(c.ref, c.read_context)
        assert_received {:checked_source_called, _, "tracker-123"}
      end
    end

    test "malformed remote values and outer returns are distinct protocol rejections", c do
      for value <- [false, [], %{}, %{id: c.ref.id, identifier: c.ref.identifier}, "issue"] do
        checked_reply!({:ok, value})
        assert {:ok, {:invalid, :issue, :invalid_issue}} = IssueSource.fetch_issue_checked(c.ref, c.read_context)
        assert_received {:checked_source_called, _, "tracker-123"}
      end

      for response <- [:ok, nil, {:ok, nil, :extra}, {:error, :reason, :extra}] do
        checked_reply!(response)
        assert {:ok, {:invalid, :response, :invalid_source_result}} = IssueSource.fetch_issue_checked(c.ref, c.read_context)
        assert_received {:checked_source_called, _, "tracker-123"}
      end
    end

    test "preserves both supported rate limits and rejects non-map metadata", c do
      for reason <- [
            {:linear_rate_limited, %{errors: [%{"message" => "rate limit"}]}},
            {:linear_api_status, 429, %{retry_after_ms: 2_000, body: %{"error" => "throttled"}}},
            {:linear_rate_limited, %{}}
          ] do
        checked_reply!({:error, reason})
        assert {:ok, {:rate_limited, ^reason}} = IssueSource.fetch_issue_checked(c.ref, c.read_context)
        assert_received {:checked_source_called, _, "tracker-123"}
      end

      for metadata <- [nil, [], "retry", 42], reason <- [{:linear_rate_limited, metadata}, {:linear_api_status, 429, metadata}] do
        checked_reply!({:error, reason})
        assert {:ok, {:invalid, :response, :invalid_rate_limit_metadata}} = IssueSource.fetch_issue_checked(c.ref, c.read_context)
        assert_received {:checked_source_called, _, "tracker-123"}
      end
    end

    test "ordinary backend errors retain their exact reason even when named like reader failures", c do
      for reason <- [
            :missing_linear_api_token,
            {:linear_api_status, 503, %{retry_after_ms: 2_000}},
            {:linear_api_status, "429", %{}},
            {:tracker_reader_exit, :killed},
            {:tracker_reader_down, :shutdown},
            {:tracker_read_exception, :error, ArgumentError.exception("backend error data")}
          ] do
        checked_reply!({:error, reason})
        assert {:ok, {:read_error, :tracker, ^reason}} = IssueSource.fetch_issue_checked(c.ref, c.read_context)
        assert_received {:checked_source_called, _, "tracker-123"}
      end
    end

    test "manual checked errors and identifier mismatch never become remote invalid or missing", c do
      id = "manual:errors"
      path = checked_manual_record!(c.read_context.manual_store_root, id, %{"identifier" => "ACTUAL-1"})
      ref = %{id: id, identifier: "EXPECTED-1", source: :manual}
      bytes = File.read!(path)

      assert {:ok, {:read_error, :manual, {:manual_issue_identity_mismatch, :identifier}}} =
               IssueSource.fetch_issue_checked(ref, c.read_context)

      assert File.read!(path) == bytes
      File.write!(path, "{bad-json")

      assert {:ok, {:read_error, :manual, {:manual_issue_decode_failed, %Jason.DecodeError{}}}} =
               IssueSource.fetch_issue_checked(ref, c.read_context)

      File.write!(path, Jason.encode!(%{"issue" => %{"id" => id, "identifier" => "EXPECTED-1"}}))

      assert {:ok, {:read_error, :manual, {:manual_issue_identity_mismatch, :source}}} =
               IssueSource.fetch_issue_checked(ref, c.read_context)

      refute_received {:checked_source_called, _, _}
    end

    test "a previously real manual record becoming absent returns missing without reconstructing the Issue", c do
      id = "manual:removed"
      path = checked_manual_record!(c.read_context.manual_store_root, id)
      ref = %{id: id, identifier: "MAN-1", source: :manual}
      assert {:ok, {:issue, :manual, %Issue{}}} = IssueSource.fetch_issue_checked(ref, c.read_context)
      File.rm!(path)
      assert {:ok, {:missing, :manual}} = IssueSource.fetch_issue_checked(ref, c.read_context)
      assert {:error, :enoent} = File.lstat(path)
    end

    test "backend exception-shaped data is nested while a real exception stays outside the envelope", c do
      supervisor = start_supervised!(Task.Supervisor)
      reason = {:tracker_read_exception, :error, ArgumentError.exception("real checked reader failure")}
      checked_reply!({:error, reason})
      reader = checked_reader!(c, supervisor)
      assert_checked_reader_result(reader, {:ok, {:read_error, :tracker, reason}})

      checked_action!({:raise, "real checked reader failure"})
      reader = checked_reader!(c, supervisor)
      assert_checked_reader_result(reader, {:error, reason})
    end

    test "actual child death stays a reader failure distinct from a returned backend exit reason", c do
      supervisor = start_supervised!(Task.Supervisor)
      checked_reply!({:error, {:tracker_reader_exit, :killed}})
      reader = checked_reader!(c, supervisor)
      assert_checked_reader_result(reader, {:ok, {:read_error, :tracker, {:tracker_reader_exit, :killed}}})

      hold_ref = make_ref()
      checked_action!({:hold, hold_ref})
      reader = checked_reader!(c, supervisor)
      assert_receive {:checked_source_held, child, ^hold_ref}, 1_000
      Process.exit(child, :kill)
      assert_checked_reader_result(reader, {:error, {:tracker_reader_exit, :killed}})
    end

    test "telemetry classifies semantic outcomes instead of marking every envelope successful", c do
      handler = "checked-issue-source-#{System.unique_integer([:positive])}"
      events = [[:symphony, :issue_source, :start], [:symphony, :issue_source, :stop]]
      assert :ok = :telemetry.attach_many(handler, events, &CheckedClient.telemetry/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)
      issue = %Issue{id: c.ref.id, identifier: c.ref.identifier, source: nil}

      for {response, label} <- [
            {{:ok, issue}, "ok"},
            {{:ok, nil}, "missing"},
            {{:error, {:backend, "private-error-payload"}}, "error"},
            {{:error, {:linear_api_status, 429, %{body: "private-rate-payload"}}}, "rate_limited"},
            {{:ok, %{secret: "private-invalid-payload"}}, "invalid"},
            {:not_a_response, "invalid"}
          ] do
        checked_reply!(response)
        assert {:ok, _outcome} = IssueSource.fetch_issue_checked(c.ref, c.read_context)
        assert_received {:checked_source_called, _, "tracker-123"}
        assert_received {:checked_source_event, [:symphony, :issue_source, :start], %{count: 1}, %{source: "tracker", operation: "lookup"}}
        assert_received {:checked_source_event, [:symphony, :issue_source, :stop], measurements, metadata}
        assert measurements.count == 1
        assert is_integer(measurements.duration) and measurements.duration >= 0
        assert metadata == %{source: "tracker", operation: "lookup", outcome: label}
      end
    end
  end

  defp checked_reply!(result), do: checked_action!({:return, result})

  defp checked_action!(action),
    do: Application.put_env(:symphony_elixir, :c5_checked_issue_source_response, {self(), action})

  defp checked_manual_path(root, id), do: Path.join(root, Base.url_encode64(id, padding: false) <> ".json")

  defp checked_manual_record!(root, id, attrs \\ %{}) do
    File.mkdir_p!(root)
    issue = Map.merge(%{"id" => id, "identifier" => "MAN-1", "source" => "manual"}, attrs)
    path = checked_manual_path(root, id)
    File.write!(path, Jason.encode!(%{"issue" => issue}))
    path
  end

  defp checked_reader!(c, supervisor) do
    assert {:ok, reader} =
             SymphonyElixir.TrackerReader.start(fn -> IssueSource.fetch_issue_checked(c.ref, c.read_context) end, supervisor: supervisor)

    reader
  end

  defp assert_checked_reader_result(reader, expected) do
    %{ref: ref, pid: pid, monitor: monitor} = reader
    assert_receive {:tracker_read_result, ^ref, ^expected}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    refute Process.alive?(pid)
  end
end
