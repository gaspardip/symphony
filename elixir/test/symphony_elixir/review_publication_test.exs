defmodule SymphonyElixir.ReviewPublicationTest do
  use SymphonyElixir.TestSupport
  @moduletag timeout: 30_000
  alias SymphonyElixir.{ReviewPublication, RunLedger, RunStateStore}
  alias SymphonyElixir.RunLedger.{CheckedStorage, PersistenceError}

  defmodule Client do
    def post_review_comment_reply(pr, id, _body, opts) do
      send(Keyword.fetch!(opts, :observer), {:publication_transport, self(), id})
      Keyword.get(opts, :result, fn -> {:ok, %{id: "reply-#{id}", url: pr <> "#reply-#{id}"}} end).()
    end

    def edit_review_comment_reply(pr, id, body, opts), do: post_review_comment_reply(pr, id, body, opts)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "review-publication-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "RP-1")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, tracker_kind: "memory", company_policy_pack: "private_autopilot")
    issue = %Issue{id: "rp-#{System.unique_integer([:positive])}", identifier: "RP-1", source: :tracker, state: "In Progress"}
    pr = "https://github.com/example/repo/pull/1"
    threads = %{"comment:1" => %{"draft_state" => "approved_to_post", "draft_reply" => "Addressed.", "retained" => "yes"}}
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier, pr_url: pr, review_threads: threads})
    raw = workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, pr: pr, threads: threads, raw: raw, ledger: RunLedger.ledger_file_path()}
  end

  test "confirmed IDs are rediscovered after an old writer regenerates approved state", c do
    before = File.read!(RunStateStore.state_path(c.workspace))
    assert {:ok, first, %{posted_count: 1}} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    [observed] = rows(c, "observed")
    assert {:ok, _} = RunStateStore.apply_review_publication(c.workspace, c.issue, c.raw, patch(observed), System.monotonic_time(:millisecond) + 5_000)
    # The public historical writer drops posted IDs again; the ledger is unchanged.
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :review_threads, c.threads))
    before_replay = File.read!(RunStateStore.state_path(c.workspace))
    ledger = File.read!(c.ledger)
    assert {:ok, same, %{posted_count: 0, reconciled_count: 1}} = publish(c)
    assert same == first
    assert same["comment:1"]["retained"] == "yes"
    assert File.read!(c.ledger) == ledger
    assert File.read!(RunStateStore.state_path(c.workspace)) == before_replay
    refute_receive {:publication_transport, _, _}, 30
  end

  test "ordinary failure is observed once and the next caller sees an explicit pending attempt", c do
    assert {:error, :no_postable_review_threads} = publish(c, :execution, result: fn -> {:error, "private backend body"} end)
    assert_receive {:publication_transport, _, "1"}
    [intent] = rows(c, "intent")
    [observed] = rows(c, "observed")
    assert observed["event_id"] == intent["metadata"]["observation_event_id"]
    assert observed["metadata"]["outcome"] == "returned_error"
    refute File.read!(c.ledger) =~ "private backend body"
    before = File.read!(c.ledger)
    assert {:error, {:review_publication_blocked, :attempt_uncertain, id}} = publish(c)
    assert id == intent["event_id"]
    assert File.read!(c.ledger) == before
    refute_receive {:publication_transport, _, _}, 30
  end

  test "late control result is durable while expired permission cannot write RAW or replay", c do
    permission = control(c, 5_000)
    before = File.read!(RunStateStore.state_path(c.workspace))

    assert {:error, {:review_publication_blocked, :control_deadline_exceeded, nil}} =
             publish(c, permission,
               result: fn ->
                 Process.sleep(max(permission.deadline - System.monotonic_time(:millisecond) + 1, 0))
                 {:ok, %{id: "late-id", url: c.pr <> "#late"}}
               end
             )

    assert_receive {:publication_transport, _, "1"}
    assert [observed] = rows(c, "observed")
    assert observed["metadata"]["posted_reply_id"] == "late-id"
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    assert {:error, _} = RunStateStore.apply_review_publication(c.workspace, c.issue, c.raw, patch(observed), permission.deadline)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    assert {:ok, threads, %{posted_count: 0, reconciled_count: 1}} = publish(c, control(c, 5_000))
    assert threads["comment:1"]["posted_reply_id"] == "late-id"
    refute_receive {:publication_transport, _, _}, 30
  end

  test "configuration change during a response retains observation and rejects continuation", c do
    permission = control(c, 5_000)
    before = File.read!(RunStateStore.state_path(c.workspace))

    assert {:error, {:review_publication_blocked, :control_invalidated, nil}} =
             publish(c, permission,
               result: fn ->
                 write_workflow_file!(Workflow.workflow_file_path(), workspace_root: c.root, tracker_kind: "memory", company_policy_pack: "client_safe_shadow")
                 {:ok, %{id: "observed", url: c.pr <> "#observed"}}
               end
             )

    assert_receive {:publication_transport, _, "1"}
    assert [%{"metadata" => %{"posted_reply_id" => "observed"}}] = rows(c, "observed")
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
  end

  test "a caller PR result can precede RAW persistence but never replaces its captured material", c do
    path = RunStateStore.state_path(c.workspace)
    raw = Map.delete(c.raw, "pr_url")
    File.write!(path, Jason.encode!(raw))
    before = File.read!(path)
    assert {:ok, _, %{posted_count: 1}} = publish(%{c | raw: raw})
    assert_receive {:publication_transport, _, "1"}
    assert [intent] = rows(c, "intent")
    assert intent["metadata"]["raw_pr"] == %{}
    assert intent["metadata"]["pr_source"] == "caller_result"
    assert intent["metadata"]["pr_identity"] == %{"host" => "github.com", "owner" => "example", "repo" => "repo", "number" => 1}
    assert File.read!(path) == before
    assert {:error, {:review_publication_blocked, :pr_changed, nil}} = publish(%{c | raw: raw}, control(%{c | raw: raw}, 5_000))
    refute_receive {:publication_transport, _, _}, 30
  end

  test "equivalent GitHub endpoint cannot open a second resource and another PR is explicit", c do
    assert {:ok, first, _} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    assert {:ok, ^first, %{reconciled_count: 1}} = publish(%{c | pr: "https://github.com/EXAMPLE/REPO/pull/01/files?view=1#reply"})
    assert {:error, {:review_publication_blocked, :resource_changed, _}} = publish(%{c | pr: "https://github.com/example/repo/pull/2"})
    refute_receive {:publication_transport, _, _}, 30
  end

  test "changing log_file does not open a new history for the same issue", c do
    assert {:ok, _, _} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    original = Application.fetch_env!(:symphony_elixir, :log_file)
    new_log = Path.join(c.root, "other/log")

    try do
      Application.put_env(:symphony_elixir, :log_file, new_log)
      assert {:error, {:review_publication_blocked, :location_changed, nil}} = publish(c)
      refute File.exists?(RunLedger.ledger_file_path())
    after
      Application.put_env(:symphony_elixir, :log_file, original)
    end

    refute_receive {:publication_transport, _, _}, 30
  end

  test "ordinary append between read and CAS rejects without replacing its bytes", c do
    {:ok, _, fingerprint} = CheckedStorage.entries_checked(c.ledger)
    {:ok, competing} = RunLedger.record_checked("another.event", %{issue_id: c.issue.id})
    {:ok, intended} = RunLedger.prepare_entry("test.intent", %{})
    before = File.read!(c.ledger)

    assert {:error, %PersistenceError{phase: :compare, reason: :ledger_changed}} =
             CheckedStorage.persist_if_current(intended, c.ledger, fingerprint, :not_pending)

    assert File.read!(c.ledger) == before
    assert {:ok, row} = CheckedStorage.fetch(c.ledger, competing.event_id)
    assert row["event_id"] == competing.event_id
  end

  for phase <- [:write, :sync, :close] do
    @tag conditional_failure_phase: phase
    test "conditional append retains checked #{phase} failure and never emits success", c do
      phase = c.conditional_failure_phase
      {:ok, _, fingerprint} = CheckedStorage.entries_checked(c.ledger)
      {:ok, intended} = RunLedger.prepare_entry("test.intent", %{})

      io = %{
        open: &:file.open/2,
        write: fn fd, bytes -> if phase == :write, do: {:error, :eio}, else: :file.write(fd, bytes) end,
        sync: fn fd -> if phase == :sync, do: {:error, :eio}, else: :file.sync(fd) end,
        close: fn fd ->
          result = :file.close(fd)
          send(self(), {:descriptor_closed, result})
          if phase == :close, do: {:error, :eio}, else: result
        end
      }

      observer = fn _, _ -> flunk("failed append must not emit success") end

      assert {:error, %PersistenceError{phase: ^phase, event_id: id, confirmation: :uncertain}} =
               CheckedStorage.persist_if_current(intended, c.ledger, fingerprint, :not_pending, io, observer)

      assert id == intended.event_id
      assert_receive {:descriptor_closed, :ok}
      refute File.exists?(c.ledger <> ".checked.lock")
    end
  end

  for change <- [:removed, :replaced, :modified] do
    @tag conditional_storage_change: change
    test "conditional append rejects real #{change} storage before its descriptor can write", c do
      change = c.conditional_storage_change
      assert {:ok, _, fingerprint} = CheckedStorage.entries_checked(c.ledger)
      assert {:ok, intended} = RunLedger.prepare_entry("test.intent", %{})
      before = File.read!(c.ledger)
      retained = c.ledger <> ".retained"
      changed_bytes = String.replace_prefix(before, "{", "[")
      assert changed_bytes != before and byte_size(changed_bytes) == byte_size(before)

      io = %{
        open: fn path, modes ->
          case change do
            :removed ->
              File.rename!(c.ledger, retained)

            :replaced ->
              File.rename!(c.ledger, retained)
              File.write!(c.ledger, before)

            :modified ->
              File.write!(c.ledger, changed_bytes)
          end

          :file.open(path, modes)
        end,
        write: fn fd, bytes ->
          send(self(), :conditional_write_started)
          :file.write(fd, bytes)
        end,
        sync: &:file.sync/1,
        close: fn fd ->
          result = :file.close(fd)
          send(self(), {:conditional_closed, result})
          result
        end
      }

      observer = fn _, _ -> send(self(), :conditional_confirmed) end

      try do
        reason = if change == :modified, do: :ledger_changed, else: :ledger_file_changed

        assert {:error, %PersistenceError{phase: :compare, reason: ^reason, event_id: id, confirmation: :uncertain, cleanup_errors: []}} =
                 CheckedStorage.persist_if_current(intended, c.ledger, fingerprint, :not_pending, io, observer)

        assert id == intended.event_id
        assert_receive {:conditional_closed, :ok}
        refute_received :conditional_write_started
        refute_received :conditional_confirmed
        refute File.exists?(c.ledger <> ".checked.lock")

        case change do
          :removed ->
            assert File.read!(retained) == before
            assert File.read!(c.ledger) == ""

          :replaced ->
            assert File.read!(retained) == before
            assert File.read!(c.ledger) == before

          :modified ->
            assert File.read!(c.ledger) == changed_bytes
        end
      after
        if change in [:removed, :replaced] do
          File.rm!(c.ledger)
          File.rename!(retained, c.ledger)
        end
      end
    end
  end

  for phase <- [:sync, :close] do
    @tag conditional_replacement_phase: phase
    test "conditional append detects a real pathname replacement after #{phase} without emitting confirmation", c do
      phase = c.conditional_replacement_phase
      assert {:ok, _, fingerprint} = CheckedStorage.entries_checked(c.ledger)
      assert {:ok, intended} = RunLedger.prepare_entry("test.intent", %{})
      before = File.read!(c.ledger)
      retained = c.ledger <> ".retained"

      swap = fn ->
        File.rename!(c.ledger, retained)
        File.write!(c.ledger, before)
      end

      io = %{
        open: &:file.open/2,
        write: &:file.write/2,
        sync: fn fd ->
          result = :file.sync(fd)
          if phase == :sync, do: swap.()
          result
        end,
        close: fn fd ->
          result = :file.close(fd)
          if phase == :close, do: swap.()
          send(self(), {:conditional_closed, result})
          result
        end
      }

      observer = fn _, _ -> send(self(), :conditional_confirmed) end

      try do
        assert {:error, %PersistenceError{phase: :confirm, reason: :ledger_file_changed, event_id: id, confirmation: :uncertain, cleanup_errors: []}} =
                 CheckedStorage.persist_if_current(intended, c.ledger, fingerprint, :not_pending, io, observer)

        assert id == intended.event_id
        assert_receive {:conditional_closed, :ok}
        refute_received :conditional_confirmed
        assert File.read!(c.ledger) == before
        assert File.read!(retained) == before <> Jason.encode!(intended) <> "\n"
        assert {:ok, rows, ^fingerprint} = CheckedStorage.entries_checked(c.ledger)
        refute Enum.any?(rows, &(&1["event_id"] == intended.event_id))
        refute File.exists?(c.ledger <> ".checked.lock")
      after
        File.rm!(c.ledger)
        File.rename!(retained, c.ledger)
      end
    end
  end

  test "conditional append checks its original deadline after opening the actual descriptor", c do
    assert {:ok, _, fingerprint} = CheckedStorage.entries_checked(c.ledger)
    assert {:ok, intended} = RunLedger.prepare_entry("test.intent", %{})
    before = File.read!(c.ledger)
    deadline = System.monotonic_time(:millisecond) + 5_000

    io = %{
      open: fn path, modes ->
        result = :file.open(path, modes)
        Process.sleep(max(deadline - System.monotonic_time(:millisecond) + 1, 0))
        result
      end,
      write: fn fd, bytes ->
        send(self(), :conditional_write_started)
        :file.write(fd, bytes)
      end,
      sync: &:file.sync/1,
      close: fn fd ->
        result = :file.close(fd)
        send(self(), {:conditional_closed, result})
        result
      end
    }

    observer = fn _, _ -> send(self(), :conditional_confirmed) end

    assert {:error, %PersistenceError{phase: :deadline, reason: :deadline_expired, event_id: id, confirmation: :not_confirmed}} =
             CheckedStorage.persist_if_current(intended, c.ledger, fingerprint, deadline, io, observer)

    assert id == intended.event_id
    assert_receive {:conditional_closed, :ok}
    refute_received :conditional_write_started
    refute_received :conditional_confirmed
    assert File.read!(c.ledger) == before
    refute File.exists?(c.ledger <> ".checked.lock")
  end

  test "expired or physically occupied conditional append never changes the ledger", c do
    {:ok, _, fingerprint} = CheckedStorage.entries_checked(c.ledger)
    {:ok, intended} = RunLedger.prepare_entry("test.intent", %{})
    before = File.read!(c.ledger)
    assert {:error, %PersistenceError{phase: :deadline}} = CheckedStorage.persist_if_current(intended, c.ledger, fingerprint, System.monotonic_time(:millisecond) - 1)
    File.mkdir!(c.ledger <> ".checked.lock")

    try do
      assert {:error, %PersistenceError{phase: :lock}} = CheckedStorage.persist_if_current(intended, c.ledger, fingerprint, :not_pending)
      assert File.read!(c.ledger) == before
    after
      File.rmdir!(c.ledger <> ".checked.lock")
    end
  end

  test "full history rejects malformed suffixes and missing storage rather than treating them as empty", c do
    assert {:ok, _, %{posted_count: 1}} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    File.write!(c.ledger, "{private-body\n", [:append])
    assert {:error, %PersistenceError{phase: :decode}} = publish(c)
    refute_received {:publication_transport, _, _}
    File.rm!(c.ledger)
    assert {:error, %PersistenceError{phase: :read, reason: :enoent}} = publish(c)
    refute_received {:publication_transport, _, _}
  end

  test "initial corruption fails the exact location preflight and never confirms an anchor event", c do
    File.write!(c.ledger, "{private-body\n", [:append])
    before = File.read!(c.ledger)
    raw = File.read!(RunStateStore.state_path(c.workspace))
    assert {:error, %PersistenceError{phase: :preflight, reason: {:invalid_record, _}, event_id: id, confirmation: :uncertain}} = publish(c)
    assert is_binary(id) and id != ""
    anchor_path = Path.join(c.root, ".review-publication-" <> Base.encode16(:crypto.hash(:sha256, c.issue.id), case: :lower) <> ".json")
    anchor_bytes = File.read!(anchor_path)
    assert Jason.decode!(anchor_bytes)["location_event_id"] == id
    assert File.read!(c.ledger) == before
    assert File.read!(RunStateStore.state_path(c.workspace)) == raw
    refute_received {:publication_transport, _, _}
    assert {:error, %PersistenceError{phase: :decode, reason: {:invalid_record, _}, event_id: nil}} = publish(c)
    assert File.read!(anchor_path) == anchor_bytes
    assert File.read!(c.ledger) == before
    refute_received {:publication_transport, _, _}
  end

  test "malformed anchor cannot choose an empty new history", c do
    assert {:ok, _, _} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    anchor = Path.join(c.root, ".review-publication-" <> Base.encode16(:crypto.hash(:sha256, c.issue.id), case: :lower) <> ".json")
    File.write!(anchor, "{invalid private marker")
    before = File.read!(c.ledger)
    assert {:error, {:review_publication_blocked, :invalid_location, nil}} = publish(c)
    assert File.read!(anchor) == "{invalid private marker"
    assert File.read!(c.ledger) == before
    refute_receive {:publication_transport, _, _}, 30
  end

  test "directory at a captured ledger preserves the old bytes and surfaces checked read failure", c do
    assert {:ok, _, _} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    before = File.read!(c.ledger)
    retained = c.ledger <> ".retained"
    File.rename!(c.ledger, retained)
    File.mkdir!(c.ledger)

    try do
      assert {:error, %PersistenceError{phase: :read}} = publish(c)
      assert File.read!(retained) == before
      assert File.dir?(c.ledger)
      refute_receive {:publication_transport, _, _}, 30
    after
      File.rmdir!(c.ledger)
      File.rename!(retained, c.ledger)
    end
  end

  test "workspace alias for the same issue cannot silently initialize a second location", c do
    assert {:ok, _, _} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    alias_workspace = Path.join(c.root, "alias")
    File.mkdir_p!(Path.dirname(RunStateStore.state_path(alias_workspace)))
    File.write!(RunStateStore.state_path(alias_workspace), File.read!(RunStateStore.state_path(c.workspace)))
    before = File.read!(c.ledger)
    assert {:error, {:review_publication_blocked, :location_changed, nil}} = publish(%{c | workspace: alias_workspace})
    assert File.read!(c.ledger) == before
    refute_receive {:publication_transport, _, _}, 30
  end

  test "domain history malformed beyond the recent window blocks transport", c do
    assert {:ok, _, _} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    {:ok, _} = RunLedger.record_checked("review.publication.intent", %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, metadata: %{invalid: true}})
    for n <- 1..60, do: assert({:ok, _} = RunLedger.record_checked("ordinary", %{metadata: %{n: n}}))
    before = File.read!(c.ledger)
    assert {:error, {:review_publication_blocked, :invalid_history, nil}} = publish(c)
    assert File.read!(c.ledger) == before
    refute_receive {:publication_transport, _, _}, 30
  end

  test "one result is confirmed before the next transport fails", c do
    threads = Map.put(c.threads, "comment:2", c.threads["comment:1"])

    result = fn ->
      intents = rows(c, "intent")
      observed = rows(c, "observed")
      assert length(intents) == length(observed) + 1
      id = List.last(intents)["metadata"]["thread_key"]
      if observed == [], do: {:ok, %{id: "reply-#{id}", url: c.pr <> "##{id}"}}, else: {:error, :second_transport_failed}
    end

    assert {:ok, _, %{posted_count: 1, skipped_count: 1}} = publish(%{c | threads: threads}, :execution, result: result)
    assert length(rows(c, "intent")) == 2
    assert length(rows(c, "observed")) == 2
    assert Enum.map(rows(c, "observed"), & &1["metadata"]["outcome"]) == ["returned_success", "returned_error"]
    assert_receive {:publication_transport, _, "1"}
    assert_receive {:publication_transport, _, "2"}
    assert {:error, {:review_publication_blocked, :attempt_uncertain, _}} = publish(%{c | threads: threads})
    refute_receive {:publication_transport, _, _}, 30
  end

  test "RAW conditional reconciliation preserves unrelated fresh values and rejects material drift", c do
    assert {:ok, _, _} = publish(c)
    [observed] = rows(c, "observed")
    path = RunStateStore.state_path(c.workspace)
    raw = Map.merge(c.raw, %{"last_token_usage" => %{"total_tokens" => 3}, "lease_updated_at" => "fresh", "unknown_future_field" => true})
    File.write!(path, Jason.encode!(raw))
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert {:ok, saved} = RunStateStore.apply_review_publication(c.workspace, c.issue, c.raw, patch(observed), deadline)
    assert saved.review_threads["comment:1"]["posted_reply_id"] == "reply-1"
    after_raw = path |> File.read!() |> Jason.decode!()
    for key <- ~w(last_token_usage lease_updated_at unknown_future_field), do: assert(after_raw[key] == raw[key])
    assert Map.drop(after_raw, ~w(review_threads last_decision_summary next_human_action)) == Map.drop(raw, ~w(review_threads last_decision_summary next_human_action))
    before = File.read!(path)
    assert {:error, :review_publication_snapshot_changed} = RunStateStore.apply_review_publication(c.workspace, c.issue, c.raw, patch(observed), deadline)
    assert File.read!(path) == before
  end

  for {label, reply} <- [
        {"non-map success", {:ok, "private malformed backend payload"}},
        {"unexpected envelope", {:unexpected, "private malformed backend payload"}}
      ] do
    @tag malformed_reply: reply
    test "#{label} is observed as invalid and cannot publish again", c do
      before_raw = File.read!(RunStateStore.state_path(c.workspace))

      assert {:error, {:review_publication_blocked, :attempt_uncertain, attempt_id}} =
               publish(c, :execution, result: fn -> c.malformed_reply end)

      assert_receive {:publication_transport, _, "1"}
      assert [intent] = rows(c, "intent")
      assert [observed] = rows(c, "observed")
      assert attempt_id == intent["event_id"]
      assert observed["event_id"] == intent["metadata"]["observation_event_id"]
      assert observed["metadata"]["intent_event_id"] == intent["event_id"]

      assert Map.take(observed["metadata"], ~w(outcome cause posted_reply_id posted_reply_url posted_at)) == %{
               "outcome" => "invalid_result",
               "cause" => "invalid_reply",
               "posted_reply_id" => nil,
               "posted_reply_url" => nil,
               "posted_at" => nil
             }

      assert File.read!(RunStateStore.state_path(c.workspace)) == before_raw
      ledger = File.read!(c.ledger)
      refute ledger =~ "private malformed backend payload"
      assert {:error, {:review_publication_blocked, :attempt_uncertain, ^attempt_id}} = publish(c)
      assert File.read!(c.ledger) == ledger
      assert File.read!(RunStateStore.state_path(c.workspace)) == before_raw
      refute_receive {:publication_transport, _, _}, 30
    end
  end

  test "incomplete returned IDs and a raised transport remain visible without replay", c do
    assert {:error, {:review_publication_blocked, :attempt_uncertain, _}} = publish(c, :execution, result: fn -> {:ok, %{id: "real-id", url: nil}} end)
    assert_receive {:publication_transport, _, "1"}
    assert [%{"metadata" => %{"outcome" => "invalid_result", "posted_reply_id" => "real-id", "posted_reply_url" => nil}}] = rows(c, "observed")
    assert {:error, {:review_publication_blocked, :attempt_uncertain, _}} = publish(c)
    refute_receive {:publication_transport, _, _}, 30
  end

  test "the original exception is raised after its safe observation", c do
    assert_raise ArgumentError, "private exception marker", fn -> publish(c, :execution, result: fn -> raise ArgumentError, "private exception marker" end) end
    assert_receive {:publication_transport, _, "1"}
    assert [%{"metadata" => %{"outcome" => "raised", "cause" => "error"}}] = rows(c, "observed")
    refute File.read!(c.ledger) =~ "private exception marker"
    assert {:error, {:review_publication_blocked, :attempt_uncertain, _}} = publish(c)
    refute_receive {:publication_transport, _, _}, 30
  end

  test "a checked observation failure is not the ordinary transport fallback", c do
    lock = c.ledger <> ".checked.lock"

    try do
      assert {:error, %PersistenceError{phase: :lock}} =
               publish(c, :execution,
                 result: fn ->
                   File.mkdir!(lock)
                   {:ok, %{id: "physical-id", url: c.pr <> "#physical"}}
                 end
               )

      assert_receive {:publication_transport, _, "1"}
    after
      File.rmdir!(lock)
    end

    assert length(rows(c, "intent")) == 1
    assert rows(c, "observed") == []
    assert {:error, {:review_publication_blocked, :attempt_uncertain, _}} = publish(c)
    refute_receive {:publication_transport, _, _}, 30
  end

  test "deadline spent after a confirmed intent cannot be reused for transport", c do
    permission = control(c, 5_000)
    handler = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:symphony, :ledger, :event],
               fn _, _, metadata, deadline ->
                 if metadata.event_type == "review.publication.intent" do
                   Process.sleep(max(deadline - System.monotonic_time(:millisecond) + 1, 0))
                 end
               end,
               permission.deadline
             )

    try do
      assert {:error, {:review_publication_blocked, :control_deadline_exceeded, nil}} = publish(c, permission)
    after
      :telemetry.detach(handler)
    end

    assert length(rows(c, "intent")) == 1
    assert rows(c, "observed") == []
    refute_received {:publication_transport, _, _}
    assert {:error, {:review_publication_blocked, :attempt_uncertain, _}} = publish(c, control(c, 5_000))
    refute_receive {:publication_transport, _, _}, 30
  end

  test "a subsequent edit requires the actual prior reply ID and changed content", c do
    assert {:ok, first, _} = publish(c)
    assert_receive {:publication_transport, _, "1"}
    proposed = first |> put_in(["comment:1", "draft_state"], "approved_to_update") |> put_in(["comment:1", "draft_reply"], "Updated evidence.")
    forged = put_in(proposed, ["comment:1", "posted_reply_id"], "foreign-reply")
    assert {:error, {:review_publication_blocked, :reply_already_posted, _}} = publish(%{c | threads: forged})
    refute_receive {:publication_transport, _, _}, 30
    assert {:ok, _, %{posted_count: 1}} = publish(%{c | threads: proposed})
    assert_receive {:publication_transport, _, "reply-1"}
    assert length(rows(c, "intent")) == 2
    assert length(rows(c, "observed")) == 2
  end

  test "legacy known reply IDs are not converted into a fresh post when history is absent", c do
    raw = put_in(c.raw, ["review_threads", "comment:1", "posted_reply_id"], "existing-reply")
    File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(raw))
    assert {:error, {:review_publication_blocked, :reply_already_posted, nil}} = publish(%{c | raw: raw})
    assert rows(c, "intent") == []
    refute_received {:publication_transport, _, _}
  end

  test "the legacy adapter keeps its historical skip count and does not require RAW or publication history", c do
    threads =
      c.threads
      |> Map.put("comment:draft", %{"draft_state" => "drafted", "draft_reply" => "Not approved."})
      |> Map.put("review:1", %{"draft_state" => "approved_to_post", "draft_reply" => "Not an inline thread."})

    before = File.read!(c.ledger)

    assert {:ok, updated, %{posted_count: 1, skipped_count: 1}} =
             SymphonyElixir.PRWatcher.post_approved_drafts(
               Path.join(c.root, "absent-legacy-workspace"),
               c.pr,
               threads,
               policy_pack: :private_autopilot,
               github_client: Client,
               github_client_opts: [observer: self()]
             )

    assert updated["comment:draft"] == threads["comment:draft"]
    assert updated["review:1"] == threads["review:1"]
    assert File.read!(c.ledger) == before
    assert_receive {:publication_transport, _, "1"}
  end

  defp publish(c, permission \\ :execution, extra \\ []) do
    ReviewPublication.publish(c.workspace, c.issue, c.pr, c.threads, permission, policy_pack: :private_autopilot, github_client: Client, github_client_opts: Keyword.merge([observer: self()], extra))
  end

  defp control(c, ms), do: %{kind: :control, caller: self(), context: Config.tracker_read_context(), deadline: System.monotonic_time(:millisecond) + ms, expected: c.raw}

  defp rows(c, suffix) do
    {:ok, all, _} = CheckedStorage.entries_checked(c.ledger)
    Enum.filter(all, &(&1["event_type"] == "review.publication.#{suffix}"))
  end

  defp patch(observed), do: %{"comment:1" => Map.take(observed["metadata"], ~w(posted_reply_id posted_reply_url posted_at)) |> Map.merge(%{"draft_state" => "posted", "reply_refresh_needed" => false})}
end
