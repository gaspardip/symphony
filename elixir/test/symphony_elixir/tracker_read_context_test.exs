defmodule SymphonyElixir.TrackerReadContextTest do
  use ExUnit.Case, async: false

  import SymphonyElixir.TestSupport, only: [restore_env: 2]
  alias SymphonyElixir.{Config, IssueSource, ManualIssueStore, Orchestrator, Tracker, Workflow, WorkflowStore}
  alias SymphonyElixir.Linear.{Adapter, Client, Issue}

  defmodule CapturedClient do
    def fetch_candidate_issues, do: {:ok, [:captured_candidate]}
    def fetch_issues_by_states(states), do: {:ok, [{:captured_states, states}]}
    def fetch_issue_states_by_ids(ids), do: {:ok, [{:captured_ids, ids}]}
    def fetch_issue_by_identifier(identifier), do: {:ok, {:captured_identifier, identifier}}
    def fetch_issue_by_id(id), do: {:ok, {:captured_id, id}}
  end

  defmodule ReplacementClient do
    def fetch_candidate_issues, do: raise("replacement client must not be called")
    def fetch_issues_by_states(_states), do: raise("replacement client must not be called")
    def fetch_issue_states_by_ids(_ids), do: raise("replacement client must not be called")
    def fetch_issue_by_identifier(_identifier), do: raise("replacement client must not be called")
    def fetch_issue_by_id(_id), do: raise("replacement client must not be called")
  end

  defmodule RateLimitedClient do
    def fetch_candidate_issues, do: {:error, {:linear_api_status, 429, %{retry_after_ms: 2_000}}}
    def fetch_issues_by_states(_states), do: fetch_candidate_issues()
    def fetch_issue_states_by_ids(ids), do: {:error, {:linear_api_status, 429, %{retry_after_ms: 2_000, ids: ids}}}
  end

  setup do
    pause_idle_scheduler!()
    root = Path.join(System.tmp_dir!(), "tracker-read-context-fixture-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir!(root)

    previous_app =
      Enum.map([:workflow_file_path, :log_file, :linear_client_module], fn key ->
        {key, Application.fetch_env(:symphony_elixir, key)}
      end)

    previous_assignee = System.get_env("LINEAR_ASSIGNEE")
    previous_token = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_ASSIGNEE", previous_assignee)
      restore_env("LINEAR_API_KEY", previous_token)

      Enum.each(previous_app, fn
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
      end)

      if Process.whereis(WorkflowStore), do: :ok = WorkflowStore.force_reload()
      File.rm_rf!(root)
    end)

    Application.delete_env(:symphony_elixir, :linear_client_module)
    System.delete_env("LINEAR_ASSIGNEE")
    System.delete_env("LINEAR_API_KEY")
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "log/symphony.log"))
    workflow = Path.join(root, "WORKFLOW.md")
    :ok = Workflow.set_workflow_file_path(workflow)
    :ok = write_workflow_file!(workflow)
    :ok
  end

  test "candidate pagination keeps endpoint, token, project and states captured before the first page" do
    {server, endpoint} = http_server()
    {_replacement, replacement_endpoint} = http_server()
    original = [tracker_endpoint: endpoint, tracker_api_token: "original-token", tracker_project_slug: "original-project", tracker_active_states: ["Todo"], manual_enabled: false]
    write_workflow_file!(Workflow.workflow_file_path(), original)

    task = Task.async(fn -> Client.fetch_candidate_issues() end)
    assert_receive {:request, ^server, first_headers, first_payload}, 5_000
    assert first_headers["authorization"] == "original-token"
    assert first_payload["variables"]["projectSlug"] == "original-project"
    assert first_payload["variables"]["stateNames"] == ["Todo"]
    assert first_payload["variables"]["after"] == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: replacement_endpoint,
      tracker_api_token: "replacement-token",
      tracker_project_slug: "replacement-project",
      tracker_active_states: ["Done"],
      tracker_assignee: "someone-else"
    )

    respond(server, page([issue("LIN-1")], true, "cursor-1"))
    assert_receive {:request, ^server, second_headers, second_payload}, 5_000
    assert second_headers["authorization"] == "original-token"
    assert second_payload["variables"]["projectSlug"] == "original-project"
    assert second_payload["variables"]["stateNames"] == ["Todo"]
    assert second_payload["variables"]["after"] == "cursor-1"
    respond(server, page([issue("LIN-2")], false, nil))

    assert {:ok, [%Issue{identifier: "LIN-1", assigned_to_worker: true}, %Issue{identifier: "LIN-2", assigned_to_worker: true}]} = Task.await(task, 5_000)
    refute_receive {:request, _pid, _headers, _payload}, 50
  end

  test "viewer lookup and identifier query share the capture even when routing and credentials change" do
    {server, endpoint} = http_server()
    {_replacement, replacement_endpoint} = http_server()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: endpoint,
      tracker_api_token: "viewer-original-token",
      tracker_project_slug: "viewer-original-project",
      tracker_assignee: "me"
    )

    task = Task.async(fn -> Client.fetch_issue_by_identifier("LIN-42") end)
    assert_receive {:request, ^server, viewer_headers, viewer_payload}, 5_000
    assert viewer_payload["query"] =~ "SymphonyLinearViewer"
    assert viewer_headers["authorization"] == "viewer-original-token"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: replacement_endpoint,
      tracker_api_token: "viewer-replacement-token",
      tracker_project_slug: "viewer-replacement-project",
      tracker_assignee: "other-user",
      tracker_handoff_mode: "labels"
    )

    respond(server, %{"data" => %{"viewer" => %{"id" => "original-user"}}})
    assert_receive {:request, ^server, query_headers, query_payload}, 5_000
    assert query_headers["authorization"] == "viewer-original-token"
    assert query_payload["variables"]["projectSlug"] == "viewer-original-project"
    assert query_payload["variables"]["teamKey"] == "LIN"
    respond(server, %{"data" => %{"issues" => %{"nodes" => [issue("LIN-42", "different-user")]}}})

    assert {:ok, %Issue{identifier: "LIN-42", assigned_to_worker: false}} = Task.await(task, 5_000)
    refute_receive {:request, _pid, _headers, _payload}, 50
  end

  test "captured injected client retains all original callback arities" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", manual_enabled: false)
    Application.put_env(:symphony_elixir, :linear_client_module, CapturedClient)
    context = Config.tracker_read_context()
    Application.put_env(:symphony_elixir, :linear_client_module, ReplacementClient)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", manual_enabled: false)

    for reader <- [Tracker, Adapter, IssueSource] do
      assert {:ok, [:captured_candidate]} = reader.fetch_candidate_issues(context)
      assert {:ok, [{:captured_states, ["Todo"]}]} = reader.fetch_issues_by_states(["Todo"], context)
      assert {:ok, [{:captured_ids, ["id-1"]}]} = reader.fetch_issue_states_by_ids(["id-1"], context)
      assert {:ok, {:captured_identifier, "LIN-1"}} = reader.fetch_issue_by_identifier("LIN-1", context)
      assert {:ok, {:captured_id, "id-1"}} = reader.fetch_issue_by_id("id-1", context)
    end
  end

  test "manual source uses the captured root after a remote read and workflow root change" do
    {server, endpoint} = http_server()
    old_root = temp_root("old")
    new_root = temp_root("new")
    common = [tracker_endpoint: endpoint, tracker_api_token: "manual-test-token", manual_enabled: true]
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(common, :manual_store_root, old_root))
    assert {:ok, old_issue} = ManualIssueStore.submit(manual_payload("OLD-1"))
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(common, :manual_store_root, new_root))
    assert {:ok, new_issue} = ManualIssueStore.submit(manual_payload("NEW-1"))
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(common, :manual_store_root, old_root))
    context = Config.tracker_read_context()

    task = Task.async(fn -> IssueSource.fetch_candidate_issues(context) end)
    assert_receive {:request, ^server, _headers, _payload}, 5_000
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(common, :manual_store_root, new_root))
    respond(server, page([], false, nil))

    assert {:ok, [^old_issue]} = Task.await(task, 5_000)
    assert {:ok, [^new_issue]} = IssueSource.fetch_manual_candidate_issues()
    assert {:ok, ^old_issue} = IssueSource.fetch_issue_by_id(old_issue.id, context)
    assert {:ok, ^old_issue} = IssueSource.fetch_issue_by_identifier(old_issue.identifier, context)
    assert {:ok, ^old_issue} = IssueSource.fetch_issue(IssueSource.issue_ref(old_issue), context)
    assert {:ok, ^old_issue} = IssueSource.refresh_issue(old_issue, context)
    assert {:ok, [^old_issue]} = IssueSource.fetch_manual_issues_by_states(["Todo"], context)
    assert {:ok, [^old_issue]} = IssueSource.fetch_manual_issue_states_by_ids([old_issue.id], context)
    assert {:ok, %{issue: ^old_issue}} = ManualIssueStore.load_record_by_identifier(old_issue.identifier, old_root)
    assert [%{issue: ^old_issue}] = ManualIssueStore.list_records(old_root)
  end

  test "raw source outcomes preserve remote throttling beside manual issues and distinguish disabled tracker" do
    root = temp_root("outcomes")
    write_workflow_file!(Workflow.workflow_file_path(), manual_store_root: root, manual_enabled: true)
    assert {:ok, manual_issue} = ManualIssueStore.submit(manual_payload("RAW-1"))
    Application.put_env(:symphony_elixir, :linear_client_module, RateLimitedClient)
    context = Config.tracker_read_context()

    expected = %{tracker: {:error, {:linear_api_status, 429, %{retry_after_ms: 2_000}}}, manual: {:ok, [manual_issue]}}
    assert ^expected = IssueSource.fetch_candidate_outcomes(context)
    assert ^expected = IssueSource.fetch_issues_by_states_outcomes(["Todo"], context)

    assert %{tracker: {:error, {:linear_api_status, 429, %{ids: ["remote-1"]}}}, manual: {:ok, [^manual_issue]}} =
             IssueSource.fetch_issue_states_by_ids_outcomes([manual_issue.id, "remote-1"], context)

    assert {:ok, [^manual_issue]} = IssueSource.fetch_candidate_issues(context)

    Application.put_env(:symphony_elixir, :linear_client_module, ReplacementClient)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: nil, manual_store_root: root, manual_enabled: false)
    disabled = Config.tracker_read_context()
    assert %{tracker: :disabled, manual: {:ok, []}} = IssueSource.fetch_candidate_outcomes(disabled)
    assert %{tracker: :disabled, manual: {:ok, []}} = IssueSource.fetch_issues_by_states_outcomes(["Todo"], disabled)
    assert %{tracker: :disabled, manual: {:ok, []}} = IssueSource.fetch_issue_states_by_ids_outcomes([manual_issue.id, "remote-1"], disabled)
  end

  test "fingerprint is stable and includes routing outside the request arguments" do
    options = [tracker_api_token: "never-print-this-token", tracker_required_labels: ["route-a"]]
    write_workflow_file!(Workflow.workflow_file_path(), options)
    first = Config.tracker_read_context()
    assert first == Config.tracker_read_context()
    assert byte_size(first.fingerprint) == 32
    refute inspect(first) =~ "never-print-this-token"

    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(options, :tracker_required_labels, ["route-b"]))
    second = Config.tracker_read_context()
    assert first.fingerprint != second.fingerprint
    assert Map.delete(first, :fingerprint) == Map.delete(second, :fingerprint)
  end

  test "graphql preserves two argument request injection and structured rate limit errors" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "captured-token")
    context = Config.tracker_read_context()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "replacement-token")

    request_fun = fn payload, headers ->
      assert payload["operationName"] == "ReadWithContext"
      assert {"Authorization", "captured-token"} in headers
      {:ok, %{status: 429, headers: [{"retry-after", "2"}], body: %{"error" => "throttled"}}}
    end

    assert {:error, {:linear_api_status, 429, %{retry_after_ms: 2_000, body: %{"error" => "throttled"}}}} =
             Client.graphql("query ReadWithContext { viewer { id } }", %{}, read_context: context, request_fun: request_fun, operation_name: "ReadWithContext")
  end

  test "missing captured credentials produce the existing error without issuing a request" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    context = Config.tracker_read_context()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "new-token")
    assert {:error, :missing_linear_api_token} = Client.fetch_candidate_issues(context)

    assert {:error, {:linear_api_request, :missing_linear_api_token}} =
             Client.graphql("query { viewer { id } }", %{}, read_context: context, request_fun: fn _, _ -> flunk("request without captured credentials") end)

    assert {:ok, []} = Client.fetch_issues_by_states([], context)
    assert {:ok, []} = Client.fetch_issue_states_by_ids([], context)
    assert {:ok, nil} = Client.fetch_issue_by_identifier("", context)
    assert {:ok, nil} = Client.fetch_issue_by_id("", context)
  end

  defp pause_idle_scheduler! do
    case Process.whereis(Orchestrator) do
      nil ->
        :ok

      pid ->
        supervisor = Process.whereis(SymphonyElixir.Supervisor)
        assert is_pid(supervisor), "Refusing to pause an Orchestrator outside the application supervisor"

        assert Enum.any?(Supervisor.which_children(supervisor), fn
                 {Orchestrator, ^pid, :worker, _} -> true
                 _ -> false
               end)

        {:status, ^pid, {:module, :gen_server}, [_, :running, _, _, _]} = :sys.get_status(pid)
        # Register restoration before suspension, including a failed suspension request.
        # ExUnit runs it after the later workflow/environment restoration callback.
        on_exit(fn -> :ok = :sys.resume(pid) end)
        suspend_quiescent_scheduler!(pid, System.monotonic_time(:millisecond) + 5_000)
        state = :sys.get_state(pid)
        assert state.running == %{}, "Refusing to change workflow with active issue workers"
        assert scheduler_quiescent?(state), "Refusing to change workflow while a tracker cycle is active"

        assert Task.Supervisor.children(SymphonyElixir.TaskSupervisor) == [],
               "Refusing to change workflow while application tasks are active"

        :ok
    end
  end

  defp suspend_quiescent_scheduler!(pid, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "Timed out waiting for the supervised scheduler to become quiescent"
    state = :sys.get_state(pid, remaining)
    assert state.running == %{}, "Refusing to change workflow with active issue workers"
    tasks = Task.Supervisor.children(SymphonyElixir.TaskSupervisor)

    if scheduler_quiescent?(state) and tasks == [] do
      remaining = deadline - System.monotonic_time(:millisecond)
      assert remaining > 0, "Timed out before suspending the supervised scheduler"
      :ok = :sys.suspend(pid, remaining)
      remaining = deadline - System.monotonic_time(:millisecond)
      assert remaining > 0, "Timed out before checking the suspended scheduler"
      suspended_state = :sys.get_state(pid, remaining)
      assert suspended_state.running == %{}, "Refusing to change workflow with active issue workers"
      suspended_tasks = Task.Supervisor.children(SymphonyElixir.TaskSupervisor)

      if scheduler_quiescent?(suspended_state) and suspended_tasks == [] do
        :ok
      else
        # A tick may have started between observation and suspension. Let only
        # this supervised owner finish its work, then attempt suspension again.
        :ok = :sys.resume(pid)
        await_scheduler_retry!(pid, deadline, suspended_state, suspended_tasks)
      end
    else
      await_scheduler_retry!(pid, deadline, state, tasks)
    end
  end

  defp await_scheduler_retry!(pid, deadline, state, tasks) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0, do: Process.sleep(min(5, remaining))

    if System.monotonic_time(:millisecond) >= deadline do
      cycle = state.tracker_poll_cycle
      reader = state.tracker_poll_read

      diagnostic = %{
        mode: if(cycle, do: cycle.mode),
        phase: if(cycle, do: cycle.phase),
        pending: state.tracker_poll_pending,
        reader_pid: if(reader, do: reader.pid),
        reader_phase: if(reader, do: reader.phase),
        poll_check_in_progress: state.poll_check_in_progress,
        github_check_in_progress: state.github_webhook_check_in_progress,
        task_pids: tasks
      }

      flunk("Timed out waiting for scheduler quiescence: #{inspect(diagnostic)}")
    end

    suspend_quiescent_scheduler!(pid, deadline)
  end

  defp scheduler_quiescent?(state) do
    is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and state.tracker_poll_pending == [] and
      not state.poll_check_in_progress and not state.github_webhook_check_in_progress
  end

  defp write_workflow_file!(path, overrides \\ []) do
    root = Path.dirname(path)

    defaults = [
      tracker_endpoint: "http://127.0.0.1:1/graphql",
      max_concurrent_agents: 0,
      codex_command: "/usr/bin/false",
      workspace_root: Path.join(root, "workspaces"),
      manual_store_root: Path.join(root, "manual"),
      runner_install_root: Path.join(root, "runner"),
      company_author_profile_path: Path.join(root, "author.json"),
      company_credential_registry_path: Path.join(root, "credentials.json")
    ]

    :ok = SymphonyElixir.TestSupport.write_workflow_file!(path, Keyword.merge(defaults, overrides))
    :ok = WorkflowStore.force_reload()
  end

  defp manual_payload(identifier) do
    %{"id" => String.downcase(identifier), "identifier" => identifier, "title" => "Frozen manual source", "acceptance_criteria" => ["Read the selected store"]}
  end

  defp temp_root(label) do
    root = Path.join(System.tmp_dir!(), "tracker-read-context-#{label}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp issue(identifier, assignee_id \\ nil) do
    %{"id" => identifier, "identifier" => identifier, "title" => "Frozen read", "state" => %{"name" => "Todo"}, "assignee" => %{"id" => assignee_id}}
  end

  defp page(nodes, has_next_page, cursor) do
    %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => cursor}}}}
  end

  defp respond(server, body), do: send(server, {:respond, body})

  defp http_server do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    server = start_supervised!({Task, fn -> accept_requests(listener, owner) end}, id: make_ref())
    on_exit(fn -> :gen_tcp.close(listener) end)
    {server, "http://127.0.0.1:#{port}/graphql"}
  end

  defp accept_requests(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, body} = receive_request(socket, "")
        send(owner, {:request, self(), headers, Jason.decode!(body)})

        receive do
          {:respond, response} ->
            payload = Jason.encode!(response)
            :ok = :gen_tcp.send(socket, ["HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ", Integer.to_string(byte_size(payload)), "\r\nconnection: close\r\n\r\n", payload])
        after
          10_000 -> raise "test server did not receive a response"
        end

        :ok = :gen_tcp.close(socket)
        accept_requests(listener, owner)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        raise "test server accept failed: #{inspect(reason)}"
    end
  end

  defp receive_request(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [raw_headers, body] ->
        headers =
          raw_headers
          |> String.split("\r\n")
          |> Enum.drop(1)
          |> Map.new(fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        content_length = headers |> Map.fetch!("content-length") |> String.to_integer()
        {headers, receive_body(socket, body, content_length)}

      [_incomplete] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        receive_request(socket, buffer <> chunk)
    end
  end

  defp receive_body(_socket, body, length) when byte_size(body) == length, do: body

  defp receive_body(socket, body, length) when byte_size(body) < length do
    {:ok, chunk} = :gen_tcp.recv(socket, length - byte_size(body), 5_000)
    receive_body(socket, body <> chunk, length)
  end
end
