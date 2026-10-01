defmodule SymphonyElixir.ReviewPublicationControlTest do
  use SymphonyElixir.TestSupport
  @moduletag timeout: 30_000
  alias SymphonyElixir.{RunLedger, RunStateStore}
  alias SymphonyElixir.DeliveryEngine.ReviewClaims
  alias SymphonyElixir.Orchestrator.State

  defmodule Client do
    def post_review_comment_reply(pr, id, _body, opts) do
      send(Keyword.fetch!(opts, :observer), {:real_control_transport, self(), pr, id})

      receive do
        {:transport_result, result} -> result
      after
        7_000 -> raise "test did not release the local review transport"
      end
    end
  end

  # Delegates real caller/from, async readers, timeout and reply. It does not
  # fabricate a worker admission or claim to exercise public Orchestrator.init.
  defmodule Driver do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state, state}

    def handle_call({:control, request} = message, {caller, _tag} = from, state) do
      observer = Application.fetch_env!(:symphony_elixir, :pr_watcher_github_client_opts) |> Keyword.fetch!(:observer)
      send(observer, {:real_control_request, caller, request.ref, request.deadline})
      Orchestrator.handle_call(message, from, state)
    end

    def handle_call(message, from, state), do: Orchestrator.handle_call(message, from, state)
    @impl true
    def handle_info(message, state), do: Orchestrator.handle_info(message, state)
  end

  setup do
    if pid = Process.whereis(Orchestrator) do
      idle!(pid, System.monotonic_time(:millisecond) + 2_000)
      assert :ok = :sys.suspend(pid)
      on_exit(fn -> assert :ok = :sys.resume(pid) end)
    end

    root = Path.join(System.tmp_dir!(), "publication-control-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    config = [workspace_root: root, tracker_kind: "memory", max_concurrent_agents: 0, company_policy_pack: "private_autopilot", company_credential_registry_path: Path.join(root, "credentials.json")]
    write_workflow_file!(Workflow.workflow_file_path(), config)
    issue = %Issue{id: "publication-control", identifier: "RPC-1", title: "Review publication", state: "In Progress", source: :tracker, labels: ["policy:fully-autonomous"], assigned_to_worker: true}
    previous = Enum.map([:memory_tracker_issues, :pr_watcher_github_client, :pr_watcher_github_client_opts], &{&1, Application.fetch_env(:symphony_elixir, &1)})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_watcher_github_client, Client)
    Application.put_env(:symphony_elixir, :pr_watcher_github_client_opts, observer: self())
    workspace = Workspace.path_for_issue(issue.identifier)
    threads = %{"comment:1" => %{"draft_state" => "approved_to_post", "draft_reply" => "Addressed.", "retained" => "yes"}}
    pr = "https://github.com/example/repo/pull/1"

    assert {:ok, state} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_source: :tracker,
               pr_url: pr,
               policy_pack: "private_autopilot",
               review_threads: threads
             })

    runtime = %State{lease_owner: "publication-owner", max_concurrent_agents: 0, poll_interval_ms: 60_000, healing_poll_interval_ms: 60_000, poll_check_in_progress: false}
    {:ok, owner} = Driver.start_link(runtime)

    on_exit(fn ->
      if Process.alive?(owner) do
        assert :ok = :sys.suspend(owner)
        current = :sys.get_state(owner)
        readers = Enum.reject([current.admission_read, current.tracker_poll_read], &is_nil/1)
        :ok = GenServer.stop(owner, :normal, 5_000)
        Enum.each(readers, fn reader -> dead!(reader.pid) end)
      end

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
      end)

      File.rm_rf!(root)
    end)

    %{owner: owner, issue: issue, workspace: workspace, state: state, pr: pr, threads: threads, config: config}
  end

  test "real control and execution callers share the durable pending reservation", c do
    task = Task.async(fn -> Orchestrator.post_review_drafts(c.owner, c.issue.identifier) end)
    assert_receive {:real_control_transport, transport, pr, "1"}, 1_000
    assert pr == c.pr
    before = File.read!(RunStateStore.state_path(c.workspace))

    assert {:error, {:review_publication_blocked, :attempt_uncertain, intent_id}} =
             ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr, c.state, github_client: Client, github_client_opts: [observer: self()])

    assert is_binary(intent_id)
    refute_receive {:real_control_transport, _, _, _}, 30
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    send(transport, {:transport_result, {:ok, %{id: "control-reply", url: c.pr <> "#control"}}})
    assert %{ok: true, posted_threads: 1, reconciled_threads: 0} = Task.await(task, 1_000)
    assert {:ok, saved} = RunStateStore.load(c.workspace)
    assert saved.review_threads["comment:1"]["posted_reply_id"] == "control-reply"
    assert saved.review_threads["comment:1"]["retained"] == "yes"
    assert is_nil(GenServer.call(c.owner, :runtime).control_reservation)
    assert [%{"metadata" => %{"pr_source" => "raw"}}] = publication_rows("intent")
    assert [%{"metadata" => %{"posted_reply_id" => "control-reply"}}] = publication_rows("observed")
  end

  test "real five second caller timeout still records the physical return without late RAW", c do
    before = File.read!(RunStateStore.state_path(c.workspace))
    task = Task.async(fn -> Orchestrator.post_review_drafts(c.owner, c.issue.identifier) end)
    assert_receive {:real_control_transport, transport, _, "1"}, 1_000
    assert %{ok: false, error: "control_deadline_exceeded"} = Task.await(task, 6_000)
    send(transport, {:transport_result, {:ok, %{id: "late-control", url: c.pr <> "#late"}}})
    assert is_nil(GenServer.call(c.owner, :runtime, 1_000).control_reservation)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    assert [%{"metadata" => %{"posted_reply_id" => "late-control"}}] = publication_rows("observed")
    # A new real permission reconstructs IDs and conditionally writes RAW, without
    # calling transport again; the old receipt never granted that permission.
    assert %{ok: true, posted_threads: 0, reconciled_threads: 1} = Orchestrator.post_review_drafts(c.owner, c.issue.identifier)
    assert {:ok, saved} = RunStateStore.load(c.workspace)
    assert saved.review_threads["comment:1"]["posted_reply_id"] == "late-control"
    refute_receive {:real_control_transport, _, _, _}, 30
  end

  test "configuration changes during real control transport preserve observation but no RAW", c do
    before = File.read!(RunStateStore.state_path(c.workspace))
    task = Task.async(fn -> Orchestrator.post_review_drafts(c.owner, c.issue.identifier) end)
    assert_receive {:real_control_transport, transport, _, "1"}, 1_000
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(c.config, :company_policy_pack, "client_safe_shadow"))
    send(transport, {:transport_result, {:ok, %{id: "context-reply", url: c.pr <> "#context"}}})
    assert %{ok: false} = Task.await(task, 1_000)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    assert [%{"metadata" => %{"posted_reply_id" => "context-reply"}}] = publication_rows("observed")
    assert is_nil(GenServer.call(c.owner, :runtime).control_reservation)
    refute_receive {:real_control_transport, _, _, _}, 30
  end

  test "caller DOWN after a confirmed first reply stops the second transport and RAW", c do
    threads = Map.put(c.threads, "comment:2", %{"draft_state" => "approved_to_post", "draft_reply" => "Second addressed.", "retained" => "second"})
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :review_threads, threads))
    before = File.read!(RunStateStore.state_path(c.workspace))
    observer = self()
    handler = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:symphony, :ledger, :event],
               fn _, _, metadata, {observer, issue_id, handler} ->
                 if metadata.event_type == "review.publication.observed" and metadata.issue_id == issue_id do
                   # CheckedStorage emits only after write/sync/close and releases its lock.
                   # Hold this genuine continuation after the physical backend return.
                   send(observer, {:confirmed_reply_barrier, self(), metadata.event_id})

                   receive do
                     {:release_observation, ^handler} -> :ok
                   after
                     2_000 ->
                       send(observer, {:observation_barrier_timeout, handler})
                       raise "test did not release the confirmed observation"
                   end
                 end
               end,
               {observer, c.issue.id, handler}
             )

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        reply = Orchestrator.post_review_drafts(c.owner, c.issue.identifier)
        send(observer, {:abandoned_control_reply, self(), reply})
      end)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      send(c.owner, {:release_observation, handler})
      :telemetry.detach(handler)
    end)

    assert_receive {:real_control_request, ^caller, request_ref, deadline}, 1_000
    assert is_reference(request_ref)
    assert_receive {:real_control_transport, transport, pr, first_id}, 1_000
    assert pr == c.pr
    assert first_id in ["1", "2"]
    send(transport, {:transport_result, {:ok, %{id: "first-physical-reply", url: c.pr <> "#first-physical"}}})
    assert_receive {:confirmed_reply_barrier, ^transport, observation_id}, 1_000
    assert [%{"event_id" => ^observation_id, "metadata" => %{"outcome" => "returned_success", "posted_reply_id" => "first-physical-reply"}}] = publication_rows("observed")
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert System.monotonic_time(:millisecond) < deadline
    send(transport, {:release_observation, handler})
    assert is_nil(GenServer.call(c.owner, :runtime, 1_000).control_reservation)
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    assert [%{"metadata" => %{"thread_key" => key, "observation_event_id" => ^observation_id}}] = publication_rows("intent")
    assert key == "comment:" <> first_id
    assert [%{"event_id" => ^observation_id, "metadata" => %{"posted_reply_id" => "first-physical-reply", "posted_reply_url" => url}}] = publication_rows("observed")
    assert url == c.pr <> "#first-physical"
    assert {:ok, saved} = RunStateStore.load(c.workspace)
    assert saved.review_threads == threads
    refute_receive {:real_control_transport, _, _, _}, 30
    refute_receive {:abandoned_control_reply, ^caller, _}, 30
    refute_received {:observation_barrier_timeout, ^handler}
  end

  defp publication_rows(suffix) do
    assert {:ok, rows, _} = RunLedger.CheckedStorage.entries_checked(RunLedger.ledger_file_path())
    Enum.filter(rows, &(&1["event_type"] == "review.publication.#{suffix}"))
  end

  defp idle!(pid, deadline) do
    state = :sys.get_state(pid)

    if state.running == %{} and is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and is_nil(state.admission_read) and state.tracker_poll_pending == [] and
         not state.poll_check_in_progress do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      idle!(pid, deadline)
    end
  end

  defp dead!(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
  end
end
