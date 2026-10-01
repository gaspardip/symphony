defmodule SymphonyElixir.GitHubEventContinuationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias SymphonyElixir.{
    AgentExecution,
    Config,
    DispatchAudit,
    DispatchGate,
    GitHubEvent,
    GitHubEventInbox,
    LeaseManager,
    Orchestrator,
    RunLedger,
    RunStateStore,
    TrackerReader,
    Workflow,
    WorkflowStore,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.State

  @pr "https://github.com/local/continuation/pull/1"
  @private "PRIVATE-C5-MARKER-DO-NOT-LOG"

  defmodule Client do
    def fetch_issue_by_id(id) do
      fixture = Application.fetch_env!(:symphony_elixir, :github_continuation_fixture)
      send(fixture.owner, {:github_read, self(), id})

      receive do
        {:answer, result} -> result
        {:raise, message} -> raise message
        {:exit, reason} -> exit(reason)
      after
        40_000 -> raise "GitHub fixture reader barrier expired"
      end
    end

    def fetch_issue_states_by_ids(ids) do
      fixture = Application.fetch_env!(:symphony_elixir, :github_continuation_fixture)

      if fixture[:hold_admission] do
        send(fixture.owner, {:admission_read, self(), ids})

        receive do
          {:answer, result} -> result
        after
          40_000 -> raise "Admission fixture barrier expired"
        end
      else
        {:ok, []}
      end
    end

    def fetch_candidate_issues do
      fixture = Application.fetch_env!(:symphony_elixir, :github_continuation_fixture)
      send(fixture.owner, :candidate_read)
      {:ok, Map.get(fixture, :candidates, [])}
    end

    def fetch_issues_by_states(states) do
      fixture = Application.fetch_env!(:symphony_elixir, :github_continuation_fixture)

      if fixture[:hold_poll_states] do
        send(fixture.owner, {:poll_states_read, self(), states})

        receive do
          {:answer, result} -> result
        after
          40_000 -> raise "Poll fixture barrier expired"
        end
      else
        {:ok, []}
      end
    end

    def fetch_issue_by_identifier(identifier) do
      fixture = Application.fetch_env!(:symphony_elixir, :github_continuation_fixture)

      case fixture[:control_issue] do
        %{identifier: ^identifier} = issue -> {:ok, issue}
        _ -> {:ok, nil}
      end
    end

    def graphql(query, variables) do
      fixture = Application.fetch_env!(:symphony_elixir, :github_continuation_fixture)

      if String.contains?(query, "issueUpdate") do
        send(fixture.owner, {:github_writer, variables.issueId})

        case Map.get(fixture, :writer, :ok) do
          :ok ->
            if fixture[:corrupt_ledger_after_writer], do: File.write!(RunLedger.ledger_file_path(), "{partial", [:append])
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

          {:raise, message} ->
            raise message

          {:error, _} = error ->
            error
        end
      else
        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}, "issue" => %{"team" => %{"id" => "c5-team", "states" => %{"nodes" => [%{"id" => "c5-state"}]}}}}}}
      end
    end
  end

  defmodule ReviewClient do
    def review_feedback(workspace, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :github_continuation_fixture).owner, {:review_read, workspace})

      if Application.fetch_env!(:symphony_elixir, :github_continuation_fixture)[:review_consumed] do
        {:ok, %{pr_url: "https://github.com/local/continuation/pull/1", review_decision: "APPROVED", reviews: [], comments: []}}
      else
        {:ok,
         %{
           pr_url: "https://github.com/local/continuation/pull/1",
           review_decision: "CHANGES_REQUESTED",
           reviews: [%{id: 91, body: "Please tighten this conditional.", state: "COMMENTED", submitted_at: "2026-03-11T12:00:00Z", author: "copilot-pull-request-reviewer"}],
           comments: [%{id: 92, body: "Consider simplifying this branch.", path: "sample.ex", line: 3, created_at: "2026-03-11T12:01:00Z", author: "copilot-pull-request-reviewer"}]
         }}
      end
    end
  end

  defmodule Driver do
    use GenServer
    def start_link(runtime, owner), do: GenServer.start_link(__MODULE__, {runtime, owner})
    @impl true
    def init({runtime, owner}), do: {:ok, %{runtime: runtime, owner: owner, hold: MapSet.new([:ack, :gate]), results: %{}}}
    @impl true
    def handle_info({:github_inbox_ack, _} = message, state), do: intercept(:ack, message, state)
    def handle_info({:github_inbox_continue, _} = message, state), do: intercept(:continue, message, state)
    def handle_info({:authorize_dispatch, _, _, _} = message, state), do: intercept(:gate, message, state)
    def handle_info({:github_inbox_wakeup, _, _, _} = message, state), do: intercept(:wakeup, message, state)
    def handle_info({:github_deadline, _} = message, state), do: intercept(:deadline, message, state)

    def handle_info({:tracker_read_result, ref, _} = message, state) do
      reader = state.runtime.tracker_poll_read

      if MapSet.member?(state.hold, :result) and is_map(reader) and reader.ref == ref and reader[:purpose] == :github_lookup do
        {:noreply, %{state | results: Map.put(state.results, ref, %{message: message, monitor: reader.monitor})}}
      else
        dispatch(message, state)
      end
    end

    def handle_info({:DOWN, monitor, :process, _, _} = message, state) do
      worker_down = Enum.any?(state.runtime.running, fn {_id, entry} -> entry.ref == monitor end)

      if worker_down and MapSet.member?(state.hold, :worker_down) do
        send(state.owner, {:github_callback, :worker_down, message})
        {:noreply, state}
      else
        case Enum.find(state.results, fn {_ref, result} -> result.monitor == monitor end) do
          {ref, result} ->
            send(state.owner, {:github_callback, :result, result.message})
            {:noreply, %{state | results: Map.put(state.results, ref, Map.put(result, :down, message))}}

          nil ->
            dispatch(message, state)
        end
      end
    end

    def handle_info(message, state), do: dispatch(message, state)
    @impl true
    def handle_call(:runtime, _from, state), do: {:reply, state.runtime, state}

    def handle_call({:hold, kind, value}, _from, state) do
      hold = if value, do: MapSet.put(state.hold, kind), else: MapSet.delete(state.hold, kind)
      {:reply, :ok, %{state | hold: hold}}
    end

    def handle_call({:deliver, message}, _from, state) do
      {pending, state} =
        case message do
          {:tracker_read_result, ref, _} ->
            {pending, rest} = Map.pop(state.results, ref)
            {pending, %{state | results: rest}}

          _ ->
            {nil, state}
        end

      {:noreply, next} = dispatch(message, state)
      next = if pending && pending[:down], do: elem(dispatch(pending.down, next), 1), else: next
      {:reply, :ok, next}
    end

    def handle_call(message, from, state) do
      {:reply, result, runtime} = Orchestrator.handle_call(message, from, state.runtime)
      {:reply, result, %{state | runtime: runtime}}
    end

    defp intercept(kind, message, state) do
      if MapSet.member?(state.hold, kind) do
        send(state.owner, {:github_callback, kind, message})
        {:noreply, state}
      else
        dispatch(message, state)
      end
    end

    defp dispatch(message, state) do
      {:noreply, runtime} = Orchestrator.handle_info(message, state.runtime)
      {:noreply, %{state | runtime: runtime}}
    end
  end

  setup do
    pause_default_scheduler!()
    root = Path.join(System.tmp_dir!(), "github-continuation-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    root = File.cd!(root, &File.cwd!/0)
    ready = Path.join(root, "worker-ready")
    release = Path.join(root, "worker-release")
    hook = %{root: root, release: release, pids: Path.join(root, "hook-pids")}
    keys = [:workflow_file_path, :log_file, :linear_client_module, :pr_watcher_github_client, :github_continuation_fixture]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})
    path = System.fetch_env!("PATH")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
      end)

      System.put_env("PATH", path)
      if Process.whereis(WorkflowStore), do: :ok = WorkflowStore.force_reload()
      assert fixture_hook_pids(hook) == [], "fixture shell still alive before removing its root"
      File.rm_rf!(root)
    end)

    if is_nil(Process.whereis(SymphonyElixir.TaskSupervisor)), do: start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
    if is_nil(Process.whereis(WorkflowStore)), do: start_supervised!(WorkflowStore)
    bin = Path.join(root, "bin")
    File.mkdir!(bin)
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\nprintf '%s\\n' '{\"url\":null,\"state\":null,\"reviewDecision\":null,\"statusCheckRollup\":[]}'\n")
    File.chmod!(Path.join(bin, "gh"), 0o700)
    System.put_env("PATH", bin <> ":" <> path)
    Application.put_env(:symphony_elixir, :linear_client_module, Client)
    Application.put_env(:symphony_elixir, :pr_watcher_github_client, ReviewClient)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "logs/symphony.log"))
    fixture(%{})

    config = %{
      tracker: %{kind: "linear", api_key: "synthetic-local-token", project_slug: "c5-local", required_labels: [], active_states: ["Todo", "In Progress", "Merging"], terminal_states: ["Done"]},
      polling: %{interval_ms: 1_000, discovery_interval_ms: 15_000, healing_interval_ms: 60_000},
      workspace: %{root: Path.join(root, "workspaces")},
      runner: %{install_root: Path.join(root, "runner"), self_host_project: false},
      manual: %{enabled: true, store_root: Path.join(root, "manual")},
      company: %{policy_pack: "private_autopilot", author_profile_path: Path.join(root, "author.json"), credential_registry_path: Path.join(root, "credentials.json")},
      agent: %{max_concurrent_agents: 0, turn_timeout_ms: 60_000, stall_timeout_ms: 0, codex: %{command: "/usr/bin/false", runtime_profile: %{inherit_env: false}}},
      hooks: %{before_run: "printf '%s\\n' \"$$\" >> '#{hook.pids}' || exit 1; printf ready > '#{ready}'; while [ ! -f '#{release}' ]; do sleep 0.01; done; exit 1", timeout_ms: 10_000},
      policy: %{publish_required: false, automerge_on_green: false, token_budget: %{per_issue_total: 200_000}}
    }

    workflow = Path.join(root, "WORKFLOW.md")
    write_config!(workflow, config)
    assert Config.poll_interval_ms() == 15_000
    assert Config.agent_stall_timeout_ms() == 0
    assert LeaseManager.ttl_ms() == 60_000
    assert :ok = GitHubEventInbox.reset()
    now = System.monotonic_time(:millisecond)

    state = %State{
      lease_owner: "c5-owner-#{System.unique_integer([:positive])}",
      max_concurrent_agents: 0,
      poll_interval_ms: 60_000,
      healing_poll_interval_ms: 60_000,
      next_poll_due_at_ms: now + 60_000,
      next_healing_poll_due_at_ms: now + 60_000,
      first_poll_completed: true,
      poll_check_in_progress: false,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:ok, pid} = Driver.start_link(state, self())
    Process.unlink(pid)

    on_exit(fn ->
      File.write!(release, "continue")
      cleanup_driver!(pid, hook)
    end)

    %{pid: pid, root: root, config: config, workflow: workflow, ready: ready, release: release, hook: hook}
  end

  test "absent workspace root is an empty capture and acknowledges the physical row", c do
    refute File.exists?(Config.workspace_root())
    enqueue!(c.pid)
    ack!(c.pid)
    assert {:ok, %{rows: []}} = GitHubEventInbox.capture(GitHubEventInbox.location(), %{max_rows: 100, max_bytes: 4 * 1024 * 1024})
    refute_received {:github_read, _, _}
  end

  test "workspace root IO failure is rejected by configuration before capture without acknowledgement", c do
    workspace_root = Config.workspace_root()
    File.write!(workspace_root, "not a directory")
    tracer = trace_effects!(c.pid)
    enqueue!(c.pid)
    state = await!(c.pid, &(&1.candidate_fetch_error == {:invalid_workspace_root, workspace_root, :enotdir}))
    assert state.candidate_fetch_error == {:invalid_workspace_root, workspace_root, :enotdir}
    assert state.github_inbox_batch == nil
    assert state.github_inbox_ack_pending == nil
    counts = trace_counts(tracer, c.pid)
    assert counts.cas == 0
    assert counts.writer == 0
    assert counts.ledger == 0
    assert counts.gate == 0
    assert counts.ack == 0
    refute_received {:github_callback, :ack, _}
    refute_received {:github_read, _, _}
    assert {:ok, %{rows: [_]}} = GitHubEventInbox.capture(GitHubEventInbox.location(), %{max_rows: 100, max_bytes: 4 * 1024 * 1024})
  end

  test "stat failure for a listed entry blocks rather than silently dropping it", c do
    File.mkdir!(Config.workspace_root())
    File.ln_s!(Path.join(c.root, "missing-directory"), Path.join(Config.workspace_root(), "broken"))
    enqueue!(c.pid)
    await!(c.pid, &match?(%{head: %{blocked: true}}, &1.github_inbox_batch))
    assert {:ok, %{rows: [_]}} = GitHubEventInbox.capture(GitHubEventInbox.location(), %{max_rows: 100, max_bytes: 4 * 1024 * 1024})
    refute_received {:github_callback, :ack, _}
    refute_received {:github_read, _, _}
  end

  test "held resolving reader serves snapshot and stop revokes even without a durable tombstone", c do
    workspace = workspace!("A")
    before = bytes(workspace)
    enqueue!(c.pid)
    reader = read!("A")
    state = runtime(c.pid)
    assert state.tracker_poll_read.purpose == :github_lookup
    assert state.github_inbox_ack_pending == nil
    assert is_map(Orchestrator.snapshot(c.pid, 500))
    assert is_map(Orchestrator.stop_issue(c.pid, "ISSUE-A"))
    await!(c.pid, &is_nil(&1.tracker_poll_read))
    refute Process.alive?(reader)
    assert bytes(workspace) == before
    refute_received {:github_writer, "A"}
    assert effect_count("A") == 0
    ack!(c.pid)
  end

  for {label, answer} <- [{"missing", {:ok, nil}}, {"returned reader-shaped error", {:error, {:tracker_reader_down, :ordinary_backend_error}}}] do
    test "initial tracker #{label} records only observation and never reopens", c do
      workspace = workspace!("A", %{stop_reason: %{code: "operator"}})
      enqueue!(c.pid)
      send(read!("A"), {:answer, unquote(Macro.escape(answer))})
      ack = callback!(:ack)
      raw = raw(workspace)
      assert raw["stage"] == "await_checks"
      assert raw["stop_reason"] == %{"code" => "operator"}
      assert raw["next_human_action"] =~ "Inspect"
      assert effect_count("A", "ci.failure_detected") == 1
      assert effect_count("A", "ci.failure_autonomous_follow_up") == 0
      refute_received {:github_writer, "A"}
      assert runtime(c.pid).running == %{}
      deliver!(c.pid, ack)
    end
  end

  test "reader exception is blocked and private exception text is not logged by C5", c do
    workspace = workspace!("A")
    before = bytes(workspace)
    enqueue!(c.pid)
    reader = read!("A")

    log =
      capture_log(fn ->
        send(reader, {:raise, @private})
        await!(c.pid, &blocked?/1)
      end)

    assert log =~ "GitHub continuation blocked"
    refute log =~ @private
    assert bytes(workspace) == before
    assert runtime(c.pid).github_inbox_ack_pending == nil
    refute_received {:github_callback, :ack, _}
  end

  test "wrong remote identity completes with zero CAS, writer, ledger or gate", c do
    workspace = workspace!("A")
    before = bytes(workspace)
    enqueue!(c.pid)
    reader = read!("A")

    log =
      capture_log(fn ->
        send(reader, {:answer, {:ok, %{issue("A") | identifier: "WRONG", title: @private}}})
        await!(c.pid, &(&1.github_inbox_ack_pending != nil))
      end)

    refute log =~ @private
    ack!(c.pid)
    assert bytes(workspace) == before
    assert effect_count("A") == 0
    refute_received {:github_writer, _}
    refute_received {:github_callback, :gate, _}
  end

  for source <- [:absent, nil] do
    test "legacy tracker source #{inspect(source)} accepts nil Issue source without normalizing RAW", c do
      workspace = workspace!("A", %{effective_policy_class: "human_approval"}, unquote(source))
      enqueue!(c.pid)
      send(read!("A"), {:answer, {:ok, %{issue("A") | source: nil}}})
      ack!(c.pid)
      raw = raw(workspace)
      if unquote(source) == :absent, do: refute(Map.has_key?(raw, "issue_source")), else: assert(raw["issue_source"] == nil)
      assert raw["stage"] == "await_checks"
      assert effect_count("A", "ci.failure_detected") == 1
      refute_received {:github_writer, _}
    end
  end

  test "absent source becoming explicit null during lookup invalidates the old CAS", c do
    workspace = workspace!("A", %{}, :absent)
    enqueue!(c.pid)
    reader = read!("A")
    write_raw!(workspace, Map.put(raw(workspace), "issue_source", nil))
    changed = bytes(workspace)
    send(reader, {:answer, {:ok, %{issue("A") | source: nil}}})
    ack!(c.pid)
    assert bytes(workspace) == changed
    assert effect_count("A") == 0
  end

  test "invalid RAW source never reaches the backend or becomes a seed", c do
    workspace = workspace!("manual:A", %{}, "unsupported")
    before = bytes(workspace)
    enqueue!(c.pid)
    ack!(c.pid)
    assert bytes(workspace) == before
    refute_received {:github_read, _, _}
    assert effect_count("manual:A") == 0
  end

  test "manual corrupt JSON blocks without exposing its data or using seeded fallback", c do
    workspace = workspace!("manual:A", %{}, "manual")
    File.mkdir_p!(c.config.manual.store_root)
    path = manual_path(c, "manual:A")
    File.write!(path, "{\"private\":\"#{@private}\"")
    before = bytes(workspace)

    log =
      capture_log(fn ->
        enqueue!(c.pid)
        await!(c.pid, &blocked?/1)
      end)

    refute log =~ @private
    assert bytes(workspace) == before
    assert runtime(c.pid).github_inbox_ack_pending == nil
    assert effect_count("manual:A") == 0
    refute_received {:github_writer, _}
  end

  test "manual path IO failure blocks and nil source missing does not seed", c do
    workspace = workspace!("manual:A", %{}, nil)
    File.mkdir_p!(manual_path(c, "manual:A"))
    before = bytes(workspace)
    enqueue!(c.pid)
    await!(c.pid, &blocked?/1)
    assert bytes(workspace) == before
    assert effect_count("manual:A") == 0
    assert runtime(c.pid).running == %{}
  end

  test "nil source in manual namespace with checked enoent observes without transition", c do
    workspace = workspace!("manual:A", %{}, nil)
    enqueue!(c.pid)
    ack!(c.pid)
    assert raw(workspace)["stage"] == "await_checks"
    assert raw(workspace)["issue_source"] == nil
    assert effect_count("manual:A", "ci.failure_detected") == 1
    assert runtime(c.pid).running == %{}
  end

  test "disabled manual source performs no read, seed or write", c do
    write_config!(c.workflow, put_in(c.config, [:manual, :enabled], false))
    workspace = workspace!("manual:A", %{}, "manual")
    before = bytes(workspace)
    enqueue!(c.pid)
    ack!(c.pid)
    assert bytes(workspace) == before
    assert effect_count("manual:A") == 0
    refute_received {:github_read, _, _}
  end

  test "blocked fully autonomous positive applies once and retains original deadline while enabled capacity is occupied", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace!("manual:BUSY", %{}, "manual")
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([event(:ci, "busy-capacity")])
    send(c.pid, :run_github_webhook_cycle)
    deliver!(c.pid, callback!(:gate))
    wait_file!(c.ready)
    ack!(c.pid)
    busy = runtime(c.pid).running["manual:BUSY"]
    assert busy.execution_started?
    assert Process.alive?(busy.pid)
    assert :ok = LeaseManager.ensure_current(busy.lease_token)
    workspace = workspace!("A", %{stage: "blocked", stop_reason: %{code: "previous"}, resume_context: %{token_pressure: "high", retained: 7}})
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    initial = runtime(c.pid)
    operation = operation(initial)
    claim = initial.lease_claims["A"]
    assert operation.effects == %{cas: :confirmed, writer: :ok, ledger: :confirmed}
    assert operation.authority.deadline == claim.started_at_ms + div(claim.token.storage.ttl_ms, 2)
    assert raw(workspace)["stage"] == "implement"
    assert raw(workspace)["stop_reason"] == nil
    assert raw(workspace)["resume_context"]["token_pressure"] == "high"
    assert raw(workspace)["resume_context"]["retained"] == 7
    send(refresh, {:answer, {:ok, issue("A")}})
    current = await!(c.pid, &phase?(&1, :waiting_admission))
    assert operation(current).authority.deadline == operation.authority.deadline
    assert current.lease_claims["A"].started_at_ms == claim.started_at_ms
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    assert transition_count(workspace, "implement") == 1
    assert current.github_inbox_ack_pending == nil
    refute_received {:github_writer, "A"}
  end

  test "disabled dispatch confirms effects and ACK while retaining its exact physical custody", c do
    workspace = workspace!("A")
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    before = runtime(c.pid)
    original = before.lease_claims["A"]
    assert operation(before).effects == %{cas: :confirmed, writer: :ok, ledger: :confirmed}
    send(refresh, {:answer, {:ok, issue("A")}})
    ack = callback!(:ack)
    retained = runtime(c.pid).lease_claims["A"]
    assert retained.token == original.token
    assert retained.custody_ref == original.custody_ref
    assert retained.started_at_ms == original.started_at_ms
    assert retained.deadline == original.deadline
    assert retained.timer == original.timer
    refute retained.completion.acked
    snapshot = bytes(workspace)
    physical = File.read!(original.token.storage.lease_path)
    deliver!(c.pid, ack)
    settled = await!(c.pid, &(is_nil(&1.github_inbox_batch) and is_nil(&1.github_inbox_ack_pending)))
    assert settled.github_last_assignment.assignment_state == "processed"
    assert settled.github_last_assignment.assignment_reason == "ci_failure_persisted"
    assert settled.lease_claims["A"].completion.acked
    assert settled.running == %{}
    assert settled.retry_attempts == %{}
    assert :ok = LeaseManager.ensure_current(original.token)
    assert File.read!(original.token.storage.lease_path) == physical
    assert bytes(workspace) == snapshot
    assert raw(workspace)["lease_owner"] == original.token.owner
    assert transition_count(workspace, "implement") == 1
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    refute_received {:github_writer, "A"}
    refute_received {:github_callback, :gate, _}
  end

  test "reenabling dispatch uses fresh admission and the retained token without replay or renewal", c do
    issue = issue("manual:A")
    workspace = workspace!(issue.id, %{token_usage: %{input_tokens: 7, output_tokens: 5, total_tokens: 12}}, "manual")
    manual_record!(c, issue)
    assert {:ok, source, _view} = RunStateStore.read_admission_source(workspace, issue)

    assert {:ok, bootstrap, _raw} =
             DispatchAudit.begin(
               workspace,
               %{issue_id: issue.id, issue_identifier: issue.identifier, actor_type: "runtime", actor_id: "fixture-bootstrap", metadata: %{owner: "fixture-bootstrap", epoch: 1, passive: true}},
               source
             )

    # No child is created for this genuine reserved identity admission.
    assert :ok = DispatchAudit.finish(bootstrap, :not_started)
    identified = raw(workspace)
    enqueue!(c.pid)
    ack = callback!(:ack)
    original = runtime(c.pid).lease_claims[issue.id]
    physical = File.read!(original.token.storage.lease_path)
    deliver!(c.pid, ack)
    await!(c.pid, &is_nil(&1.github_inbox_ack_pending))
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    send(c.pid, :run_poll_cycle)
    gate = callback!(:gate)
    pending = runtime(c.pid)
    entry = pending.running[issue.id]
    claim = pending.lease_claims[issue.id]
    assert entry.dispatch_ticket.run_id == identified["run_id"]
    assert claim.token == original.token
    assert claim.started_at_ms == original.started_at_ms
    assert claim.deadline == original.deadline
    assert claim.timer == original.timer
    assert claim.promotion_ref == original.completion.decision_ref
    assert File.read!(original.token.storage.lease_path) == physical
    assert raw(workspace)["token_usage"] == identified["token_usage"]
    assert raw(workspace)["run_id"] == identified["run_id"]
    assert effect_count(issue.id, "ci.failure_autonomous_follow_up") == 1
    assert transition_count(workspace, "implement") == 1
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    active = runtime(c.pid)
    assert active.running[issue.id].execution_started?
    assert active.running[issue.id].lease_token == original.token
    assert active.lease_claims[issue.id].timer == nil
    assert active.lease_claims[issue.id].completion == nil
    assert raw(workspace)["token_usage"] == identified["token_usage"]
    assert effect_count(issue.id, "ci.failure_autonomous_follow_up") == 1
    assert transition_count(workspace, "implement") == 1
  end

  for control <- [:pause, :budget] do
    test "reenabling disabled dispatch respects current #{control} before any worker", c do
      issue = issue("manual:A")
      workspace = workspace!(issue.id, %{}, "manual")
      manual_record!(c, issue)
      enqueue!(c.pid)
      ack!(c.pid)

      case unquote(control) do
        :pause -> assert %{ok: true} = Orchestrator.pause_issue(c.pid, issue.identifier)
        :budget -> assert {:ok, _} = RunStateStore.update(workspace, &Map.put(&1, :token_usage, %{input_tokens: 250_000, output_tokens: 0, total_tokens: 250_000}))
      end

      write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
      send(c.pid, :run_poll_cycle)
      assert_receive :candidate_read, 2_000
      await!(c.pid, &(is_nil(&1.tracker_poll_cycle) and is_nil(&1.tracker_poll_read) and is_nil(&1.admission_read)))
      assert runtime(c.pid).running == %{}
      refute File.exists?(c.ready)
      refute_received {:github_callback, :gate, _}
      assert effect_count(issue.id, "ci.failure_autonomous_follow_up") == 1
      assert transition_count(workspace, "implement") == 1

      case unquote(control) do
        :pause -> assert Map.has_key?(runtime(c.pid).paused_issue_states, issue.id)
        :budget -> assert raw(workspace)["token_usage"]["total_tokens"] == 250_000
      end
    end
  end

  test "expired disabled custody cannot authorize or close a fresh successor through late ACK and timeout", c do
    issue = issue("manual:A")
    workspace = workspace!(issue.id, %{}, "manual")
    manual_record!(c, issue)
    assert :ok = GenServer.call(c.pid, {:hold, :deadline, true})
    enqueue!(c.pid)
    ack = callback!(:ack)
    original = runtime(c.pid).lease_claims[issue.id]
    deliver!(c.pid, ack)
    await!(c.pid, &is_nil(&1.github_inbox_ack_pending))
    wait_until!(fn -> System.monotonic_time(:millisecond) >= original.deadline end, original.deadline + 2_000)
    deadline = callback!(:deadline)
    deliver!(c.pid, deadline)
    expired = runtime(c.pid)
    refute Map.has_key?(expired.lease_claims, issue.id)
    assert expired.running == %{}
    assert expired.retry_attempts == %{}
    assert {:error, :missing} = LeaseManager.read_at(original.token.storage)
    refute_received {:github_callback, :gate, _}
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    send(c.pid, :run_poll_cycle)
    gate = callback!(:gate)
    successor = runtime(c.pid)
    claim = successor.lease_claims[issue.id]
    entry = successor.running[issue.id]
    assert claim.token != original.token
    assert claim.custody_ref != original.custody_ref
    assert Process.alive?(entry.pid)
    physical = File.read!(claim.token.storage.lease_path)
    snapshot = bytes(workspace)
    deliver!(c.pid, ack)
    deliver!(c.pid, deadline)
    unchanged = runtime(c.pid)
    assert unchanged.lease_claims[issue.id] == claim
    assert unchanged.running[issue.id] == entry
    assert File.read!(claim.token.storage.lease_path) == physical
    assert bytes(workspace) == snapshot
    assert :ok = LeaseManager.ensure_current(claim.token)
    assert effect_count(issue.id, "ci.failure_autonomous_follow_up") == 1
    assert transition_count(workspace, "implement") == 1
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    assert runtime(c.pid).running[issue.id].execution_started?
    assert effect_count(issue.id, "ci.failure_autonomous_follow_up") == 1
  end

  test "review uses the same continuation and preserves fresh budget context", c do
    workspace = workspace!("A", %{resume_context: %{token_pressure: "high", retained: "usage"}})
    enqueue!(c.pid, :review)
    assert_receive {:review_read, ^workspace}, 2_000
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    persisted = raw(workspace)
    assert persisted["stage"] in ["implement", "review_verification"]
    assert persisted["resume_context"]["token_pressure"] == "high"
    assert persisted["resume_context"]["retained"] == "usage"
    assert map_size(persisted["review_claims"]) > 0
    assert map_size(persisted["review_threads"]) > 0
    send(refresh, {:answer, {:ok, nil}})
    ack!(c.pid)
    assert effect_count("A", "review.feedback_autonomous_follow_up") == 1
    refute_received {:review_read, ^workspace}
    refute_received {:github_writer, "A"}
  end

  for answer <- [{:ok, nil}, {:error, :ordinary_remote_error}] do
    test "refresh #{inspect(answer)} preserves applied effects and never falls back to old Issue", c do
      workspace = workspace!("A")
      enqueue!(c.pid)
      send(read!("A"), {:answer, {:ok, issue("A")}})
      assert_receive {:github_writer, "A"}, 2_000
      refresh = read!("A")
      after_apply = bytes(workspace)
      send(refresh, {:answer, unquote(Macro.escape(answer))})
      ack!(c.pid)
      assert bytes(workspace) == after_apply
      assert transition_count(workspace, "implement") == 1
      assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
      refute_received {:github_writer, "A"}
      refute_received {:github_callback, :gate, _}
    end
  end

  for writer <- [{:error, {:remote_failure, @private}}, {:raise, @private}] do
    test "writer #{elem(writer, 0)} after CAS is retained once, logged safely, and never refreshed/replayed", c do
      fixture(%{writer: unquote(Macro.escape(writer))})
      workspace = workspace!("A")
      enqueue!(c.pid)
      reader = read!("A")

      log =
        capture_log(fn ->
          send(reader, {:answer, {:ok, issue("A")}})
          await!(c.pid, &blocked?/1)
        end)

      refute log =~ @private
      assert_receive {:github_writer, "A"}, 2_000
      assert raw(workspace)["stage"] == "implement"
      assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
      assert operation(runtime(c.pid)).effects.ledger == :confirmed
      send(c.pid, :run_github_webhook_cycle)
      assert is_map(Orchestrator.snapshot(c.pid, 500))
      assert transition_count(workspace, "implement") == 1
      refute_receive {:github_read, _, "A"}, 100
      refute_received {:github_writer, "A"}
      refute_received {:github_callback, :ack, _}
    end
  end

  test "initial 429 is observed before policy eligibility and wakes resolving without another webhook", c do
    workspace = workspace!("A", %{effective_policy_class: "human_approval"})
    before = bytes(workspace)
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:error, {:linear_api_status, 429, %{retry_after_ms: 100}}}})
    state = await!(c.pid, &phase?(&1, :backoff))
    assert state.tracker_poll_read == nil
    assert state.lease_claims == %{}
    assert bytes(workspace) == before
    send(read!("A"), {:answer, {:ok, issue("A")}})
    ack!(c.pid)
    assert raw(workspace)["stage"] == "await_checks"
    assert effect_count("A", "ci.failure_detected") == 1
  end

  test "refresh 429 only refreshes again and retains the original acquisition", c do
    workspace = workspace!("A")
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    before = runtime(c.pid)
    send(refresh, {:answer, {:error, {:linear_rate_limited, %{retry_after_ms: 100}}}})
    await!(c.pid, &phase?(&1, :backoff))
    send(read!("A"), {:answer, {:ok, nil}})
    ack = callback!(:ack)
    assert transition_count(workspace, "implement") == 1
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    refute_received {:github_writer, "A"}
    assert before.lease_claims["A"].deadline == operation(before).authority.deadline
    deliver!(c.pid, ack)
  end

  test "refresh backoff beyond original deadline ends without replay or gate", c do
    workspace = workspace!("A")
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    deadline = operation(runtime(c.pid)).authority.deadline
    now = System.monotonic_time(:millisecond)
    retry_after_ms = max(deadline - now, 0) + 1_000
    assert now + retry_after_ms > deadline
    assert retry_after_ms <= 1_800_000
    send(refresh, {:answer, {:error, {:linear_rate_limited, %{retry_after_ms: retry_after_ms}}}})
    ack!(c.pid)
    assert transition_count(workspace, "implement") == 1
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    assert runtime(c.pid).running == %{}
    assert runtime(c.pid).lease_claims == %{}
    refute_received {:github_writer, "A"}
  end

  test "workspace A already completed is not repeated when workspace B wakes from 429", c do
    first = workspace!("A", %{effective_policy_class: "human_approval"})
    second = workspace!("B", %{effective_policy_class: "human_approval"})
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    reader = read!("B")
    first_done = bytes(first)
    send(reader, {:answer, {:error, {:linear_rate_limited, %{retry_after_ms: 100}}}})
    send(read!("B"), {:answer, {:ok, nil}})
    ack!(c.pid)
    assert bytes(first) == first_done
    assert effect_count("A", "ci.failure_detected") == 1
    assert effect_count("B", "ci.failure_detected") == 1
    assert raw(second)["stage"] == "await_checks"
    refute_received {:github_read, _, "A"}
  end

  test "ack IO failure retries only the same cursor and never the completed effects", c do
    workspace = workspace!("A", %{effective_policy_class: "human_approval"})
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, nil}})
    ack = callback!(:ack)
    done = bytes(workspace)
    location = GitHubEventInbox.location()
    saved = File.read!(location.state_path)
    File.rm!(location.state_path)
    File.mkdir!(location.state_path)
    deliver!(c.pid, ack)
    assert runtime(c.pid).github_inbox_ack_pending != nil
    File.rmdir!(location.state_path)
    File.write!(location.state_path, saved)
    send(c.pid, :run_github_webhook_cycle)
    await!(c.pid, &is_nil(&1.github_inbox_ack_pending))
    assert bytes(workspace) == done
    assert effect_count("A", "ci.failure_detected") == 1
    assert GitHubEventInbox.pending_events(100) == []
    refute_received {:github_read, _, _}
  end

  test "reset generation while resolving cannot acknowledge replacement inbox", c do
    workspace = workspace!("A")
    before = bytes(workspace)
    enqueue!(c.pid)
    reader = read!("A")
    assert :ok = GitHubEventInbox.reset()
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([event(:ci, "replacement")])
    send(reader, {:answer, {:ok, issue("A")}})
    await!(c.pid, &(&1.github_inbox_storage_error != nil and is_nil(&1.tracker_poll_read)))
    assert bytes(workspace) == before
    assert length(GitHubEventInbox.pending_events(100)) == 1
    refute_received {:github_callback, :ack, _}
  end

  test "new control between apply and refresh prevents dispatch without rolling back or replay", c do
    workspace = workspace!("A")
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    reader = read!("A")
    assert is_map(Orchestrator.pause_issue(c.pid, "ISSUE-A"))
    await!(c.pid, &is_nil(&1.tracker_poll_read))
    refute Process.alive?(reader)
    ack!(c.pid)
    assert raw(workspace)["stage"] == "implement"
    assert transition_count(workspace, "implement") == 1
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    assert runtime(c.pid).running == %{}
  end

  test "seeded local checked absence reaches a real admission ticket and gate", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace = workspace!("manual:A", %{}, "manual")
    enqueue!(c.pid)
    gate = callback!(:gate)
    before = runtime(c.pid)
    entry = before.running["manual:A"]
    operation = operation(before)
    assert entry.dispatch_ticket.run_id == raw(workspace)["run_id"]
    assert entry.lease_token == operation.authority.lease_token
    assert before.lease_claims["manual:A"].deadline == operation.authority.deadline
    assert before.lease_claims["manual:A"].started_at_ms + div(entry.lease_token.storage.ttl_ms, 2) == operation.authority.deadline
    refute operation.cleanup_owned
    assert operation.effects.writer == :not_applicable
    refute File.exists?(manual_path(c, "manual:A"))
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    current = runtime(c.pid)
    assert current.running["manual:A"].execution_started?
    assert current.lease_claims["manual:A"].custody_ref != before.lease_claims["manual:A"].custody_ref
    ack!(c.pid)
    refute_received {:github_writer, _}
    assert effect_count("manual:A", "ci.failure_autonomous_follow_up") == 1
  end

  test "extra coordinator material changed after admission but before gate denies the worker", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace = workspace!("manual:A", %{}, "manual")
    enqueue!(c.pid)
    gate = callback!(:gate)
    worker = runtime(c.pid).running["manual:A"].pid
    ref = Process.monitor(worker)
    updated = Map.put(raw(workspace), "next_human_action", "control after admission")
    write_raw!(workspace, updated)
    deliver!(c.pid, gate)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
    refute File.exists?(c.ready)
    assert raw(workspace)["next_human_action"] == "control after admission"
    assert runtime(c.pid).running == %{}
    assert transition_count(workspace, "implement") == 1
  end

  test "initial nil source manual record is checked physically rather than synthesized", c do
    workspace = workspace!("manual:A", %{effective_policy_class: "human_approval"}, nil)
    manual_record!(c, issue("manual:A"))
    enqueue!(c.pid)
    ack!(c.pid)
    assert raw(workspace)["issue_source"] == nil
    assert raw(workspace)["stage"] == "await_checks"
    assert effect_count("manual:A", "ci.failure_detected") == 1
    assert File.exists?(manual_path(c, "manual:A"))
  end

  test "real Orchestrator and seeded inbox cross CAS, ledger, refresh, admission, gate and ack", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace = workspace!("manual:REAL", %{}, "manual")
    name = String.to_atom("github-real-#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)
    Process.unlink(pid)

    on_exit(fn ->
      File.write!(c.release, "continue")
      cleanup_real_owner!(pid, c.hook)
    end)

    tracer = trace_effects!(pid)
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([event(:ci)])
    send(pid, :run_github_webhook_cycle)
    wait_file!(c.ready)
    state = :sys.get_state(pid, 500)
    entry = state.running["manual:REAL"]
    assert entry.execution_started?
    assert Process.alive?(entry.pid)
    assert entry.dispatch_ticket.run_id == raw(workspace)["run_id"]
    assert state.lease_claims["manual:REAL"].holder == :running
    wait_until!(fn -> GitHubEventInbox.pending_events(100) == [] end)
    counts = trace_counts(tracer, pid)
    assert counts.cas == 1
    assert counts.writer == 0
    assert counts.ledger == 1
    assert counts.read >= 2
    assert counts.gate == 1
    assert counts.ack == 1
    assert raw(workspace)["stage"] == "implement"
    assert effect_count("manual:REAL", "ci.failure_autonomous_follow_up") == 1
    assert effect_count("manual:REAL", "dispatch.started") == 1
    refute File.exists?(manual_path(c, "manual:REAL"))
  end

  test "W1 genuine normal DOWN closes its journal before C5 resolves and keeps retry metadata through admission", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace = workspace!("A", %{resume_context: %{token_pressure: "high", review_fix_budget_retry_count: 2, retained: "W1"}})
    worker = install_audited_worker!(c.pid, issue("A"))
    enqueue!(c.pid)
    await!(c.pid, &phase?(&1, :waiting_worker))
    before = bytes(workspace)
    refute_receive {:github_read, _, "A"}, 50
    assert bytes(workspace) == before
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 0
    monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    reader = read!("A")
    state = runtime(c.pid)
    retry = state.retry_attempts["A"]
    assert retry.attempt == 1
    assert retry.delay_type == :passive_continuation
    assert operation(state).retry == retry
    assert :ok = DispatchAudit.ensure_available(workspace)
    assert operation(state).waited_down == :normal
    send(c.pid, {:retry_issue, "A", retry.retry_ref})
    send(reader, {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    acquired = runtime(c.pid)
    assert acquired.retry_attempts["A"].attempt == retry.attempt
    assert acquired.retry_attempts["A"].delay_type == retry.delay_type
    assert acquired.lease_claims["A"].holder == :follow_up
    assert acquired.lease_claims["A"].custody_ref != retry.custody_ref
    assert operation(acquired).authority.deadline == acquired.lease_claims["A"].started_at_ms + div(acquired.lease_claims["A"].token.storage.ttl_ms, 2)
    send(refresh, {:answer, {:ok, issue("A")}})
    gate = callback!(:gate)
    gated = runtime(c.pid)
    assert gated.running["A"].retry_attempt == retry.attempt
    assert gated.running["A"].resume_context.token_pressure == "high"
    assert gated.running["A"].resume_context.review_fix_budget_retry_count == 2
    assert gated.lease_claims["A"].started_at_ms == acquired.lease_claims["A"].started_at_ms
    assert gated.lease_claims["A"].deadline == acquired.lease_claims["A"].deadline
    assert gated.lease_claims["A"].token == acquired.lease_claims["A"].token
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    ack!(c.pid)
    assert transition_count(workspace, "implement") == 1
    assert effect_count("A", "dispatch.started") == 2
  end

  test "W1 uncertain journal close never grants C5 observation or worker authority", c do
    workspace = workspace!("A")
    worker = install_audited_worker!(c.pid, issue("A"))
    enqueue!(c.pid)
    await!(c.pid, &phase?(&1, :waiting_worker))
    path = RunStateStore.state_path(workspace)
    saved = File.read!(path)
    File.write!(path, "{invalid-current-snapshot")
    send(worker, :finish)
    await!(c.pid, &blocked?/1)
    assert File.read!(path) == "{invalid-current-snapshot"
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 0
    assert runtime(c.pid).github_inbox_ack_pending == nil
    refute_received {:github_read, _, "A"}
    refute_received {:github_writer, "A"}
    # Only fixture teardown restores bytes; no production observer repairs the run.
    File.write!(path, saved)
  end

  test "same-token custody transfer during refresh revokes C5 cleanup and does not release the successor", c do
    workspace = workspace!("A")
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    original = runtime(c.pid).lease_claims["A"]
    successor_ref = make_ref()

    :sys.replace_state(c.pid, fn wrapper ->
      runtime = wrapper.runtime
      claim = %{runtime.lease_claims["A"] | custody_ref: successor_ref, holder: :retry}
      %{wrapper | runtime: put_in(runtime.lease_claims["A"], claim)}
    end)

    send(refresh, {:answer, {:ok, issue("A")}})
    ack!(c.pid)
    assert runtime(c.pid).lease_claims["A"].custody_ref == successor_ref
    assert runtime(c.pid).lease_claims["A"].token == original.token
    assert :ok = LeaseManager.ensure_current(original.token)
    assert raw(workspace)["stage"] == "implement"
    refute_received {:github_callback, :gate, _}
  end

  test "public control after own admission is denied before the real gate even with unchanged token", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace = workspace!("manual:A", %{}, "manual")
    enqueue!(c.pid)
    gate = callback!(:gate)
    worker = runtime(c.pid).running["manual:A"].pid
    monitor = Process.monitor(worker)
    assert is_map(Orchestrator.pause_issue(c.pid, "ISSUE-A"))
    deliver!(c.pid, gate)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
    refute File.exists?(c.ready)
    assert raw(workspace)["stage"] == "implement"
    assert effect_count("manual:A", "ci.failure_autonomous_follow_up") == 1
  end

  test "deadline expires while A remains occupied without extending acquisition or starting a worker", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 2))
    workspace!("A")
    fixture(%{hold_admission: true, candidates: [issue("OTHER")]})
    send(c.pid, :run_poll_cycle)
    assert_receive {:admission_read, admission, ["OTHER"]}, 2_000
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    send(refresh, {:answer, {:ok, issue("A")}})
    state = await!(c.pid, &phase?(&1, :waiting_admission))
    deadline = operation(state).authority.deadline
    started = state.lease_claims["A"].started_at_ms
    assert deadline == started + div(state.lease_claims["A"].token.storage.ttl_ms, 2)
    assert state.admission_read.pid != nil
    wait_until!(fn -> System.monotonic_time(:millisecond) >= deadline end, deadline + 2_000)
    ack!(c.pid)
    assert runtime(c.pid).running == %{}
    refute Map.has_key?(runtime(c.pid).lease_claims, "A")
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    refute_received {:github_callback, :gate, _}
    send(admission, {:answer, {:ok, []}})
  end

  test "backend private error remains a local observation without logging its body", c do
    workspace = workspace!("A")
    enqueue!(c.pid)
    reader = read!("A")

    log =
      capture_log(fn ->
        send(reader, {:answer, {:error, {:linear_api_error, %{body: @private}}}})
        await!(c.pid, &(&1.github_inbox_ack_pending != nil))
      end)

    refute log =~ @private
    assert raw(workspace)["stage"] == "await_checks"
    assert effect_count("A", "ci.failure_detected") == 1
    ack!(c.pid)
  end

  test "failed checked ledger preserves exactly one transition and writer with no refresh or automatic retry", c do
    workspace = workspace!("A")
    fixture(%{writer: :ok, corrupt_ledger_after_writer: true})
    enqueue!(c.pid)
    reader = read!("A")
    send(reader, {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    await!(c.pid, &blocked?/1)
    assert raw(workspace)["stage"] == "implement"
    assert operation(runtime(c.pid)).effects.cas == :confirmed
    assert operation(runtime(c.pid)).effects.writer == :ok
    assert match?({:error, _}, operation(runtime(c.pid)).effects.ledger)
    assert runtime(c.pid).github_inbox_ack_pending == nil
    send(c.pid, :run_github_webhook_cycle)
    assert is_map(Orchestrator.snapshot(c.pid, 500))
    refute_receive {:github_read, _, "A"}, 100
    refute_received {:github_writer, "A"}
  end

  for outcome <- [:corrupt, :missing] do
    test "real manual refresh #{outcome} preserves one applied result and never becomes a seed", c do
      workspace = workspace!("manual:A", %{}, "manual")
      manual_record!(c, issue("manual:A"))
      tracer = trace_effects!(c.pid)
      count = :atomics.new(1, [])
      owner = self()
      handler = {__MODULE__, make_ref()}

      assert :ok =
               :telemetry.attach(
                 handler,
                 [:symphony, :issue_source, :start],
                 fn _event, _measurements, metadata, _config ->
                   if metadata[:source] == "manual" and metadata[:operation] == "lookup" and :atomics.add_get(count, 1, 1) == 2 do
                     send(owner, {:manual_refresh_before_read, self()})

                     receive do
                       :continue_manual_refresh -> :ok
                     after
                       2_000 -> raise "manual refresh barrier expired"
                     end
                   end
                 end,
                 nil
               )

      on_exit(fn -> :telemetry.detach(handler) end)
      enqueue!(c.pid)
      assert_receive {:manual_refresh_before_read, reader}, 2_000
      assert raw(workspace)["stage"] == "implement"
      assert Jason.decode!(File.read!(manual_path(c, "manual:A")))["issue"]["state"] == "In Progress"
      applied = bytes(workspace)

      log =
        capture_log(fn ->
          case unquote(outcome) do
            :corrupt -> File.write!(manual_path(c, "manual:A"), "{invalid " <> @private)
            :missing -> File.rm!(manual_path(c, "manual:A"))
          end

          send(reader, :continue_manual_refresh)
          if unquote(outcome) == :corrupt, do: await!(c.pid, &blocked?/1), else: await!(c.pid, &(&1.github_inbox_ack_pending != nil))
        end)

      refute log =~ @private
      assert bytes(workspace) == applied
      counts = trace_counts(tracer, c.pid)
      assert counts.cas == 1
      assert counts.writer == 1
      assert counts.ledger == 1
      assert counts.gate == 0
      assert :atomics.get(count, 1) == 2
      assert effect_count("manual:A", "ci.failure_autonomous_follow_up") == 1
      refute_received {:github_callback, :gate, _}

      if unquote(outcome) == :corrupt do
        assert runtime(c.pid).github_inbox_ack_pending == nil
        send(c.pid, :run_github_webhook_cycle)
        assert is_map(Orchestrator.snapshot(c.pid, 500))
        assert :atomics.get(count, 1) == 2
      else
        ack!(c.pid)
        refute File.exists?(manual_path(c, "manual:A"))
      end
    end
  end

  test "a duplicate completed reader callback cannot replay CAS, ledger or acknowledgement", c do
    workspace = workspace!("A", %{effective_policy_class: "human_approval"})
    assert :ok = GenServer.call(c.pid, {:hold, :result, true})
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, nil}})
    result = callback!(:result)
    deliver!(c.pid, result)
    ack = callback!(:ack)
    persisted = bytes(workspace)
    deliver!(c.pid, result)
    assert bytes(workspace) == persisted
    assert effect_count("A", "ci.failure_detected") == 1
    refute_received {:github_callback, :ack, _}
    deliver!(c.pid, ack)
    assert GitHubEventInbox.pending_events(100) == []
  end

  test "worker W2 admitted during a held resolving read survives the obsolete return", c do
    workspace = workspace!("A")
    enqueue!(c.pid)
    reader = read!("A")
    worker = install_audited_worker!(c.pid, issue("A"))
    admitted = bytes(workspace)
    successor = runtime(c.pid).running["A"]
    assert :ok = GenServer.call(c.pid, {:hold, :continue, true})
    send(reader, {:answer, {:ok, issue("A")}})
    continuation = callback!(:continue)
    assert bytes(workspace) == admitted
    assert :ok = GenServer.call(c.pid, {:hold, :continue, false})
    deliver!(c.pid, continuation)
    ack!(c.pid)
    assert Process.alive?(worker)
    assert runtime(c.pid).running["A"].dispatch_ticket == successor.dispatch_ticket
    assert :ok = LeaseManager.ensure_current(successor.lease_token)
    assert effect_count("A") == 0
    refute_received {:github_writer, "A"}
  end

  test "physical lease replacement while refreshing is never released by the old acquisition", c do
    workspace!("A")
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    reader = read!("A")
    old = runtime(c.pid).lease_claims["A"].token
    assert {:ok, :released} = LeaseManager.release_token(old)
    assert {:ok, successor} = LeaseManager.acquire("A", "ISSUE-A", "successor-owner", storage: old.storage)
    assert successor.token != old
    send(reader, {:answer, {:ok, issue("A")}})
    ack!(c.pid)
    assert :ok = LeaseManager.ensure_current(successor.token)
    assert runtime(c.pid).running == %{}
    refute_received {:github_callback, :gate, _}
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
  end

  test "changed captured tracker context rejects a held result without effects or acknowledgement", c do
    workspace = workspace!("A")
    before = bytes(workspace)
    enqueue!(c.pid)
    reader = read!("A")
    write_config!(c.workflow, put_in(c.config, [:tracker, :project_slug], "new-context"))
    send(reader, {:answer, {:ok, issue("A")}})
    await!(c.pid, &(&1.github_inbox_storage_error != nil and is_nil(&1.tracker_poll_read)))
    assert bytes(workspace) == before
    assert effect_count("A") == 0
    assert length(GitHubEventInbox.pending_events(100)) == 1
    refute_received {:github_callback, :ack, _}
  end

  test "persisted token budget still rejects admission after a checked autonomous transition", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace = workspace!("A", %{token_usage: %{total_tokens: 250_000, input_tokens: 250_000, output_tokens: 0}})
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    send(read!("A"), {:answer, {:ok, issue("A")}})
    await!(c.pid, &blocked?/1)
    assert raw(workspace)["token_usage"]["total_tokens"] == 250_000
    assert transition_count(workspace, "implement") == 1
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    assert runtime(c.pid).running == %{}
    refute_received {:github_callback, :gate, _}
    refute File.exists?(c.ready)
  end

  for changed <- [%{"issue_source" => "invalid-source"}, %{"runner_channel" => "other-runner"}, %{"runner_instance_id" => "other-instance"}] do
    test "normal W1 closure rejects fresh source or routing #{inspect(changed)} before feedback and effects", c do
      workspace = workspace!("A")
      worker = install_audited_worker!(c.pid, issue("A"))
      assert :ok = GenServer.call(c.pid, {:hold, :worker_down, true})
      enqueue!(c.pid, :review)
      await!(c.pid, &phase?(&1, :waiting_worker))
      send(worker, :finish)
      down = callback!(:worker_down)
      write_raw!(workspace, Map.merge(raw(workspace), unquote(Macro.escape(changed))))
      changed = bytes(workspace)
      tracer = trace_effects!(c.pid)
      deliver!(c.pid, down)
      ack = callback!(:ack)
      state = runtime(c.pid)
      retry = state.retry_attempts["A"]
      claim = state.lease_claims["A"]
      assert retry.attempt == 1
      assert retry.custody_ref == claim.custody_ref
      assert :ok = LeaseManager.ensure_current(claim.token)
      assert bytes(workspace) == changed
      assert :ok = DispatchAudit.ensure_available(workspace)
      counts = trace_counts(tracer, c.pid)
      assert counts.cas == 0
      assert counts.writer == 0
      assert counts.ledger == 0
      assert counts.gate == 0
      refute_received {:review_read, _}
      refute_received {:github_read, _, _}
      refute_received {:github_writer, _}
      deliver!(c.pid, ack)
    end
  end

  test "normal W1 closure rebuilds the checked route from a valid new manual source", c do
    workspace = workspace!("A", %{effective_policy_class: "human_approval"})
    manual_record!(c, %{issue("A") | source: :manual})
    worker = install_audited_worker!(c.pid, issue("A"))
    assert :ok = GenServer.call(c.pid, {:hold, :worker_down, true})
    enqueue!(c.pid)
    await!(c.pid, &phase?(&1, :waiting_worker))
    send(worker, :finish)
    down = callback!(:worker_down)
    write_raw!(workspace, Map.put(raw(workspace), "issue_source", "manual"))
    deliver!(c.pid, down)
    ack!(c.pid)
    assert raw(workspace)["issue_source"] == "manual"
    assert raw(workspace)["stage"] == "await_checks"
    assert effect_count("A", "ci.failure_detected") == 1
    refute_received {:github_read, _, "A"}
    refute_received {:github_writer, _}
  end

  test "W1 reservation survives initial 429 and a ready retry through fresh resolution and real admission", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace = workspace!("A", %{resume_context: %{token_pressure: "high", review_fix_budget_retry_count: 2, retained: "W1"}})
    worker = install_audited_worker!(c.pid, issue("A"))
    assert :ok = GenServer.call(c.pid, {:hold, :wakeup, true})
    enqueue!(c.pid)
    await!(c.pid, &phase?(&1, :waiting_worker))
    send(worker, :finish)
    reader = read!("A")
    first = operation(runtime(c.pid))
    send(reader, {:answer, {:error, {:linear_rate_limited, %{retry_after_ms: 100}}}})
    backoff = await!(c.pid, &phase?(&1, :backoff))
    retry = backoff.retry_attempts["A"]
    claim = backoff.lease_claims["A"]
    assert operation(backoff).authority == nil
    assert operation(backoff).waited_worker == first.waited_worker
    assert operation(backoff).waited_down == :normal
    wake = callback!(:wakeup)
    send(c.pid, {:retry_issue, "A", retry.retry_ref})
    assert is_map(Orchestrator.snapshot(c.pid, 500))
    assert runtime(c.pid).lease_claims["A"].token == claim.token
    refute_received {:admission_read, _, _}
    refute_received {:github_callback, :ack, _}
    write_raw!(workspace, Map.update!(raw(workspace), "resume_context", &Map.put(&1, "fresh_during_backoff", "retained")))
    deliver!(c.pid, wake)
    reader = read!("A")
    fresh = operation(runtime(c.pid))
    assert fresh.ref != first.ref
    assert fresh.waited_worker == first.waited_worker
    assert fresh.waited_down == :normal
    assert fresh.custody == first.custody
    assert fresh.retry.attempt == retry.attempt
    assert fresh.view.resume_context["fresh_during_backoff"] == "retained"
    send(reader, {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    acquired = runtime(c.pid).lease_claims["A"]
    assert acquired.custody_ref != claim.custody_ref
    assert acquired.deadline == acquired.started_at_ms + div(acquired.token.storage.ttl_ms, 2)
    send(refresh, {:answer, {:ok, issue("A")}})
    gate = callback!(:gate)
    gated = runtime(c.pid)
    assert gated.running["A"].retry_attempt == retry.attempt
    assert gated.running["A"].resume_context.token_pressure == "high"
    assert gated.running["A"].resume_context.review_fix_budget_retry_count == 2
    assert gated.running["A"].resume_context.fresh_during_backoff == "retained"
    assert gated.lease_claims["A"].started_at_ms == acquired.started_at_ms
    assert gated.lease_claims["A"].deadline == acquired.deadline
    assert gated.lease_claims["A"].token == acquired.token
    deliver!(c.pid, wake)
    send(c.pid, {:github_deadline, first.ref})
    assert runtime(c.pid).lease_claims["A"] == gated.lease_claims["A"]
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    ack!(c.pid)
    assert transition_count(workspace, "implement") == 1
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    assert effect_count("A", "dispatch.started") == 2
    refute_received {:github_writer, "A"}
  end

  for reason <- [{:linear_rate_limited, %{retry_after_ms: 60_000, body: @private}}, {:linear_api_status, 429, %{retry_after_ms: 60_000, body: @private}}] do
    test "tracker writer #{elem(reason, 0)} updates shared backoff once while retaining the failed head", c do
      error = {:error, unquote(Macro.escape(reason))}
      fixture(%{writer: error})
      workspace = workspace!("A")
      tracer = trace_effects!(c.pid)
      enqueue!(c.pid)
      reader = read!("A")

      log =
        capture_log(fn ->
          send(reader, {:answer, {:ok, issue("A")}})
          await!(c.pid, &blocked?/1)
        end)

      refute log =~ @private
      assert_receive {:github_writer, "A"}, 2_000
      state = runtime(c.pid)
      assert operation(state).effects.writer == error
      assert operation(state).effects.ledger == :confirmed
      assert state.tracker_backoff_until_ms > System.monotonic_time(:millisecond)
      assert state.tracker_backoff_rule_id == "tracker.rate_limited"
      assert state.tracker_poll_read == nil
      assert state.github_inbox_ack_pending == nil
      assert transition_count(workspace, "implement") == 1
      assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
      send(c.pid, :run_github_webhook_cycle)
      assert is_map(Orchestrator.snapshot(c.pid, 500))
      counts = trace_counts(tracer, c.pid)
      assert counts.cas == 1
      assert counts.writer == 1
      assert counts.ledger == 1
      # Includes manual-only polling preludes as well as the one checked lookup.
      assert counts.read >= 1
      assert counts.gate == 0
      assert counts.ack == 0
      refute_receive {:github_read, _, _}, 100
      refute_received {:github_writer, _}
      refute_received {:github_callback, :gate, _}
      refute_received {:github_callback, :ack, _}
    end
  end

  test "W1 normal closure rereads review feedback already consumed while it ran and performs no old follow-up", c do
    workspace = workspace!("A")
    worker = install_audited_worker!(c.pid, issue("A"))
    enqueue!(c.pid, :review)
    await!(c.pid, &phase?(&1, :waiting_worker))
    refute_received {:review_read, _}
    # The existing backend seam now reports the externally consumed feedback.
    # W1 has a controlled body; this does not claim a real provider posted it.
    fixture(%{review_consumed: true})
    tracer = trace_effects!(c.pid)
    send(worker, :finish)
    assert_receive {:review_read, ^workspace}, 2_000
    ack = callback!(:ack)
    counts = trace_counts(tracer, c.pid)
    assert counts.cas == 0
    assert counts.writer == 0
    assert counts.ledger == 0
    assert counts.gate == 0
    assert counts.children == 0
    assert transition_count(workspace, "implement") == 0
    assert effect_count("A", "review.feedback_autonomous_follow_up") == 0
    assert effect_count("A", "dispatch.started") == 1
    assert :ok = DispatchAudit.ensure_available(workspace)
    refute_received {:github_read, _, "A"}
    refute_received {:github_writer, "A"}
    deliver!(c.pid, ack)
  end

  test "W1 reaches a real terminal CAS before normal DOWN and the captured CI cannot reopen implementation", c do
    workspace = workspace!("A")
    worker = install_audited_worker!(c.pid, issue("A"))
    enqueue!(c.pid)
    await!(c.pid, &phase?(&1, :waiting_worker))
    send(worker, {:transition, self(), "done", %{last_decision_summary: "W1 already completed the run"}})
    assert_receive {:worker_transition, ^worker, {:ok, %{stage: "done"}}}, 2_000
    assert runtime(c.pid).running["A"].agent_execution.known_terminal.stage == "done"
    tracer = trace_effects!(c.pid)
    send(worker, :finish)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    ack = callback!(:ack)
    assert raw(workspace)["stage"] == "done"
    assert transition_count(workspace, "implement") == 0
    assert transition_count(workspace, "done") == 1
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 0
    assert effect_count("A", "ci.failure_detected") == 1
    assert effect_count("A", "dispatch.started") == 1
    counts = trace_counts(tracer, c.pid)
    assert counts.cas == 1
    assert counts.writer == 0
    assert counts.ledger == 1
    assert counts.gate == 0
    assert counts.children == 0
    assert runtime(c.pid).running == %{}
    refute_received {:github_writer, "A"}
    deliver!(c.pid, ack)
  end

  test "manual candidate crosses a real worker gate while a remote GitHub head waits in backoff", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    remote = workspace!("A")
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:error, {:linear_rate_limited, %{retry_after_ms: 60_000}}}})
    waiting = await!(c.pid, &phase?(&1, :backoff))
    remote_bytes = bytes(remote)
    assert waiting.tracker_poll_read == nil
    manual = issue("manual:B")
    workspace!(manual.id, %{stage: "implement"}, "manual")
    manual_record!(c, manual)
    tracer = trace_effects!(c.pid)
    send(c.pid, :run_poll_cycle)
    gate = callback!(:gate)
    assert {:authorize_dispatch, "manual:B", dispatch_id, worker} = gate
    state = runtime(c.pid)
    assert state.running[manual.id].pid == worker
    assert state.running[manual.id].dispatch_ticket.dispatch_id == dispatch_id
    assert operation(state).ref == operation(waiting).ref
    assert phase?(state, :backoff)
    assert state.github_inbox_ack_pending == nil
    assert bytes(remote) == remote_bytes
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    state = runtime(c.pid)
    assert state.running[manual.id].execution_started?
    assert :ok = LeaseManager.ensure_current(state.lease_claims[manual.id].token)
    counts = trace_counts(tracer, c.pid)
    assert counts.gate == 1
    assert counts.cas == 0
    assert counts.writer == 0
    assert counts.ledger == 0
    assert counts.ack == 0
    assert effect_count(manual.id, "dispatch.started") == 1
    assert effect_count("A") == 0
    refute_received :candidate_read
    refute_received {:github_read, _, "A"}
    refute_received {:github_callback, :ack, _}
  end

  test "unanswered refresh ends at its real deadline even after physical renewal of the same lease generation", c do
    workspace = workspace!("A")
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    monitor = Process.monitor(refresh)
    before = runtime(c.pid)
    claim = before.lease_claims["A"]
    deadline = operation(before).authority.deadline
    assert {:ok, lease} = LeaseManager.read_at(claim.token.storage)
    assert {:ok, renewed} = LeaseManager.refresh_token(claim.token)
    assert renewed["lease_generation"] == lease["lease_generation"]
    assert renewed["acquired_at"] == lease["acquired_at"]
    assert renewed["owner"] == lease["owner"]
    assert renewed["epoch"] == lease["epoch"]
    assert renewed["updated_at"] != lease["updated_at"]
    assert runtime(c.pid).lease_claims["A"].deadline == deadline
    assert runtime(c.pid).lease_claims["A"].started_at_ms == claim.started_at_ms

    receive do
    after
      max(0, deadline - System.monotonic_time(:millisecond) + 1) -> :ok
    end

    assert System.monotonic_time(:millisecond) >= deadline
    assert_receive {:DOWN, ^monitor, :process, ^refresh, _}, 2_000
    ack = callback!(:ack)
    assert runtime(c.pid).tracker_poll_read == nil
    deliver!(c.pid, ack)
    await!(c.pid, &is_nil(&1.github_inbox_ack_pending))
    assert runtime(c.pid).lease_claims == %{}
    assert runtime(c.pid).running == %{}
    assert transition_count(workspace, "implement") == 1
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    refute_received {:github_writer, "A"}
    refute_received {:github_callback, :gate, _}
    refute File.exists?(c.ready)
  end

  test "refresh before deadline cannot authorize a real gate held until after the original deadline", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace = workspace!("manual:A", %{}, "manual")
    assert :ok = GenServer.call(c.pid, {:hold, :deadline, true})
    tracer = trace_effects!(c.pid)
    enqueue!(c.pid)
    gate = callback!(:gate)
    before = runtime(c.pid)
    original = operation(before)
    deadline = original.authority.deadline
    assert System.monotonic_time(:millisecond) < deadline
    worker = before.running["manual:A"].pid
    monitor = Process.monitor(worker)
    # The real C5 timer is retained at the Driver boundary; the late gate itself
    # must reject before the timer callback is delivered to the coordinator.
    receive do
    after
      max(0, deadline - System.monotonic_time(:millisecond) + 1) -> :ok
    end

    timer_message = callback!(:deadline)
    assert timer_message == {:github_deadline, original.ref}
    assert runtime(c.pid).lease_claims["manual:A"].deadline == deadline
    assert Process.alive?(worker)
    deliver!(c.pid, gate)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
    refute File.exists?(c.ready)
    assert runtime(c.pid).running == %{}
    assert trace_counts(tracer, c.pid).gate == 0
    assert [{_ticket, {:exit, _actual_reason}}] = trace_counts(tracer, c.pid).finishes
    deliver!(c.pid, timer_message)
    deliver!(c.pid, timer_message)
    assert transition_count(workspace, "implement") == 1
    assert effect_count("manual:A", "ci.failure_autonomous_follow_up") == 1
    refute_received {:github_writer, _}
  end

  test "repeated obsolete timeout shapes after accepted transfer cannot release the live worker", c do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    workspace!("manual:A", %{}, "manual")
    enqueue!(c.pid)
    gate = callback!(:gate)
    before = runtime(c.pid)
    original = operation(before)
    timer = before.lease_claims["manual:A"].timer
    deliver!(c.pid, gate)
    wait_file!(c.ready)
    accepted = runtime(c.pid)
    entry = accepted.running["manual:A"]
    claim = accepted.lease_claims["manual:A"]
    assert entry.execution_started?
    assert Process.read_timer(timer) == false
    # Acceptance cancels the timer, so these are explicit duplicate-callback
    # fixtures. They are not claimed to be an uncancelled real timer delivery.
    deliver!(c.pid, {:github_deadline, original.ref})
    deliver!(c.pid, {:github_deadline, original.ref})
    current = runtime(c.pid)
    assert current.lease_claims["manual:A"] == claim
    assert current.running["manual:A"].dispatch_ticket == entry.dispatch_ticket
    assert Process.alive?(entry.pid)
    assert :ok = LeaseManager.ensure_current(claim.token)
    assert claim.custody_ref != before.lease_claims["manual:A"].custody_ref
    assert effect_count("manual:A", "dispatch.finished") == 0
    ack!(c.pid)
  end

  test "a coordinator-only change during real begin rejects before child creation and closes only its own ticket", c do
    {workspace, before, tracer, _extra} = reject_admission_during_begin!(c, false)
    ack = callback!(:ack)
    state = runtime(c.pid)
    counts = trace_counts(tracer, c.pid)
    assert [{ticket, :not_started}] = counts.finishes
    assert ticket.workspace == workspace
    assert ticket.owner == before.lease_claims["A"].token.owner
    assert ticket.epoch == before.lease_claims["A"].token.epoch
    assert ticket.run_id == raw(workspace)["run_id"]
    assert counts.children == 0
    assert counts.gate == 0
    assert state.running == %{}
    assert state.lease_claims == %{}
    assert :ok = DispatchAudit.ensure_available(workspace)
    assert raw(workspace)["next_human_action"] == "changed while begin held its real lock"
    assert effect_count("A", "dispatch.finished") == 1
    refute File.exists?(c.ready)
    refute_received {:github_callback, :gate, _}
    deliver!(c.pid, ack)
  end

  for control <- [:pause, :stop, :retry] do
    test "uncertain no-child close retains exact custody across #{control} and stale deadlines", c do
      {workspace, before, tracer, extra} = reject_admission_during_begin!(c, true)
      failed = await!(c.pid, &blocked?/1)
      retained = operation(failed)
      claim = failed.lease_claims["A"]
      assert retained.admission_close_error == :dispatch_audit_unexpected_files
      assert retained.authority.deadline == operation(before).authority.deadline

      assert Map.take(claim, [:token, :custody_ref, :started_at_ms, :deadline, :timer]) ==
               Map.take(before.lease_claims["A"], [:token, :custody_ref, :started_at_ms, :deadline, :timer])

      assert claim.completion.decision_ref == operation(before).ref
      assert :ok = LeaseManager.ensure_current(claim.token)
      marker = Path.join(DispatchAudit.marker_directory(workspace), "marker.json")
      marker_bytes = File.read!(marker)
      assert Jason.decode!(marker_bytes)["status"] == "authorized"
      assert File.read!(extra) == "real close failure"
      assert [{ticket, :not_started}] = trace_counts(tracer, c.pid).finishes
      assert ticket == retained.ticket

      if unquote(control) == :retry do
        receive do
        after
          max(0, retained.authority.deadline - System.monotonic_time(:millisecond) + 1) -> :ok
        end

        assert System.monotonic_time(:millisecond) >= retained.authority.deadline
      end

      send(c.pid, {:github_deadline, retained.ref})
      send(c.pid, {:promotion_timeout, "A", claim.promotion_ref})

      reply =
        case unquote(control) do
          :pause -> Orchestrator.pause_issue(c.pid, "ISSUE-A")
          :stop -> Orchestrator.stop_issue(c.pid, "ISSUE-A")
          :retry -> Orchestrator.retry_issue_now(c.pid, "ISSUE-A")
        end

      assert is_map(reply)
      if unquote(control) == :retry, do: assert(reply.ok == false and reply.dispatch_outcome == "deferred"), else: assert(reply.ok == true)
      state = runtime(c.pid)
      assert blocked?(state)
      assert state.lease_claims["A"] == claim
      assert operation(state).ticket == ticket
      assert operation(state).admission_close_error == :dispatch_audit_unexpected_files
      assert operation(state).authority.deadline == retained.authority.deadline
      assert state.running == %{}
      assert state.github_inbox_ack_pending == nil
      assert :ok = LeaseManager.ensure_current(claim.token)
      assert File.read!(marker) == marker_bytes
      assert File.read!(extra) == "real close failure"
      counts = trace_counts(tracer, c.pid)
      assert counts.finishes == [{ticket, :not_started}]
      assert counts.children == 0
      assert counts.gate == 0
      assert counts.ack == 0
      assert counts.cas == 1
      assert counts.ledger == 1
      assert effect_count("A", "dispatch.finished") == 0
      refute File.exists?(c.ready)
      refute_received {:github_callback, :ack, _}
      refute_received {:github_callback, :gate, _}
    end
  end

  test "uncertain no-child evidence never reclaims or releases a physically replaced successor", c do
    {workspace, _before, tracer, _extra} = reject_admission_during_begin!(c, true)
    failed = await!(c.pid, &blocked?/1)
    own = failed.lease_claims["A"]
    retained = operation(failed)
    assert {:ok, :released} = LeaseManager.release_token(own.token)
    assert {:ok, successor} = LeaseManager.acquire("A", "ISSUE-A", "successor-owner", storage: own.token.storage)
    successor_ref = make_ref()
    if is_reference(own.timer), do: Process.cancel_timer(own.timer)

    :sys.replace_state(c.pid, fn wrapper ->
      runtime = wrapper.runtime
      claim = %{own | token: successor.token, lease: successor.lease, custody_ref: successor_ref, holder: :retry, deadline: :not_pending, promotion_ref: nil, timer: nil, completion: nil}
      %{wrapper | runtime: put_in(runtime.lease_claims["A"], claim)}
    end)

    send(c.pid, {:github_deadline, retained.ref})
    send(c.pid, {:promotion_timeout, "A", own.promotion_ref})
    send(c.pid, :run_github_webhook_cycle)
    state = runtime(c.pid)
    assert blocked?(state)
    assert state.lease_claims["A"].custody_ref == successor_ref
    assert state.lease_claims["A"].token == successor.token
    assert :ok = LeaseManager.ensure_current(successor.token)
    assert operation(state).ticket == retained.ticket
    assert operation(state).admission_close_error == retained.admission_close_error
    assert effect_count("A", "dispatch.finished") == 0
    assert trace_counts(tracer, c.pid).finishes == [{retained.ticket, :not_started}]
    assert state.github_inbox_ack_pending == nil
    assert raw(workspace)["next_human_action"] == "changed while begin held its real lock"
  end

  test "repeated expired cleanup and public controls preserve the exact uncertain operation and workspace", c do
    {workspace, _before, tracer, extra} = reject_admission_during_begin!(c, true)
    failed = await!(c.pid, &blocked?/1)
    retained = operation(failed)
    claim = failed.lease_claims["A"]
    head = failed.github_inbox_batch.head
    marker = Path.join(DispatchAudit.marker_directory(workspace), "marker.json")
    marker_bytes = File.read!(marker)
    assert retained.failure == {:github_admission_close_failed, :github_material_changed, :dispatch_audit_unexpected_files}
    assert retained.outcome == {:blocked, retained.failure}

    receive do
    after
      max(0, retained.authority.deadline - System.monotonic_time(:millisecond) + 1) -> :ok
    end

    assert System.monotonic_time(:millisecond) >= retained.authority.deadline

    for repetition <- 1..3 do
      deliver!(c.pid, {:github_deadline, retained.ref})
      deliver!(c.pid, {:promotion_timeout, "A", claim.promotion_ref})
      assert %{ok: true} = Orchestrator.pause_issue(c.pid, "ISSUE-A")
      assert %{ok: true} = Orchestrator.stop_issue(c.pid, "ISSUE-A")
      assert %{ok: false, dispatch_outcome: "deferred"} = Orchestrator.retry_issue_now(c.pid, "ISSUE-A")
      state = runtime(c.pid)
      assert operation(state) == retained
      assert state.github_inbox_batch.head.workspaces == head.workspaces
      assert state.github_inbox_batch.head.outcomes == head.outcomes
      assert state.github_inbox_batch.head.blocked
      assert state.lease_claims["A"] == claim
      assert :ok = LeaseManager.ensure_current(claim.token)
      assert state.running == %{}
      assert state.github_inbox_ack_pending == nil
      assert File.read!(marker) == marker_bytes
      assert File.read!(extra) == "real close failure"
      counts = trace_counts(tracer, c.pid)
      assert counts.finishes == [{retained.ticket, :not_started}]
      assert counts.children == 0
      assert counts.cas == 1
      # Each public pause and stop intentionally invokes its existing writer.
      assert counts.writer == 1 + 2 * repetition
      assert counts.ledger == 1
      assert counts.gate == 0
      assert counts.ack == 0
    end

    assert effect_count("A", "dispatch.finished") == 0
    refute File.exists?(c.ready)
    refute_received {:github_callback, :gate, _}
    refute_received {:github_callback, :ack, _}
  end

  # This delegates the real inbox/owner callbacks and real admission. The live
  # Task.Supervisor is deliberately capacity-constrained after the actual reader
  # DOWN; this does not claim B availability during that fixture-only interval.
  for close_failure <- [false, true] do
    test "returned task rejection preserves its cause with real own close failure #{close_failure}", c do
      write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
      fixture(%{control_issue: issue("A")})
      workspace = workspace!("A")
      tracer = trace_effects!(c.pid)
      enqueue!(c.pid)
      send(read!("A"), {:answer, {:ok, issue("A")}})
      assert_receive {:github_writer, "A"}, 2_000
      refresh = read!("A")
      assert :ok = GenServer.call(c.pid, {:hold, :result, true})
      send(refresh, {:answer, {:ok, issue("A")}})
      result = callback!(:result)
      refute Process.alive?(refresh)
      before = runtime(c.pid)
      original_expected = operation(before).expected
      extra = Path.join(DispatchAudit.marker_directory(workspace), "unexpected-spawn-fixture")
      handler = "c5-spawn-rejection-#{System.unique_integer([:positive])}"
      owner = c.pid
      parent = self()

      :ok =
        :telemetry.attach(
          handler,
          [:symphony, :ledger, :event],
          fn _event, _measurements, metadata, _config ->
            if self() == owner and metadata[:event_type] == "dispatch.started" and metadata[:issue_id] == "A" do
              if unquote(close_failure), do: File.write!(extra, "real spawn close failure")
              send(parent, :spawn_begin_confirmed)
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      original = Process.whereis(SymphonyElixir.TaskSupervisor)
      assert is_pid(original)
      supervisor = Process.whereis(SymphonyElixir.Supervisor)
      assert is_pid(supervisor)
      child_id = Task.Supervisor.child_spec(name: SymphonyElixir.TaskSupervisor).id
      assert Enum.any?(Supervisor.which_children(supervisor), fn {id, child, _, _} -> id == child_id and child == original end)
      wait_until!(fn -> Task.Supervisor.children(original) == [] end)
      assert Task.Supervisor.children(original) == []
      assert :ok = Supervisor.terminate_child(supervisor, child_id)

      try do
        assert {:ok, constrained} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor, max_children: 0)

        try do
          deliver!(c.pid, result)
          assert_receive :spawn_begin_confirmed, 2_000
          state = runtime(c.pid)
          assert blocked?(state)
          assert state.running == %{}
          assert Task.Supervisor.children(constrained) == []
          assert RunStateStore.coordinator_projection(raw(workspace)) == original_expected
          counts = trace_counts(tracer, c.pid)
          assert [{ticket, :not_started}] = counts.finishes
          assert ticket.workspace == workspace
          assert ticket.owner == before.lease_claims["A"].token.owner
          assert ticket.epoch == before.lease_claims["A"].token.epoch
          assert ticket.run_id == raw(workspace)["run_id"]
          assert counts.children == 1
          assert counts.gate == 0
          assert counts.ack == 0
          assert counts.cas == 1
          assert counts.writer == 1
          assert counts.ledger == 1
          assert state.github_inbox_ack_pending == nil

          if unquote(close_failure) do
            retained = operation(state)
            claim = state.lease_claims["A"]
            assert retained.ticket == ticket
            assert retained.admission_close_error == :dispatch_audit_unexpected_files
            assert retained.failure == {:github_admission_close_failed, {:dispatch_worker_start_failed, :max_children}, :dispatch_audit_unexpected_files}
            assert retained.outcome == {:blocked, retained.failure}
            assert retained.authority == operation(before).authority

            assert Map.take(claim, [:token, :custody_ref, :started_at_ms, :deadline, :timer]) ==
                     Map.take(before.lease_claims["A"], [:token, :custody_ref, :started_at_ms, :deadline, :timer])

            assert :ok = LeaseManager.ensure_current(claim.token)
            marker = Path.join(DispatchAudit.marker_directory(workspace), "marker.json")
            marker_bytes = File.read!(marker)
            assert Jason.decode!(marker_bytes)["status"] == "authorized"
            assert File.read!(extra) == "real spawn close failure"
            assert effect_count("A", "dispatch.finished") == 0

            for _ <- 1..2 do
              assert %{ok: true} = Orchestrator.pause_issue(c.pid, "ISSUE-A")
              assert %{ok: true} = Orchestrator.stop_issue(c.pid, "ISSUE-A")
              current = runtime(c.pid)
              assert operation(current) == retained
              assert current.lease_claims["A"] == claim
              assert current.github_inbox_batch.head.workspaces == state.github_inbox_batch.head.workspaces
              assert current.github_inbox_batch.head.outcomes == state.github_inbox_batch.head.outcomes
              assert current.github_inbox_ack_pending == nil
              assert File.read!(marker) == marker_bytes
              assert trace_counts(tracer, c.pid).finishes == [{ticket, :not_started}]
              assert :ok = LeaseManager.ensure_current(claim.token)
            end
          else
            assert operation(state).failure == {:dispatch_worker_start_failed, :max_children}
            assert operation(state).admission_close_error == nil
            assert state.lease_claims == %{}
            assert :ok = DispatchAudit.ensure_available(workspace)
            assert effect_count("A", "dispatch.finished") == 1
          end

          refute File.exists?(c.ready)
          refute_received {:github_callback, :gate, _}
          refute_received {:github_callback, :ack, _}
        after
          assert Task.Supervisor.children(constrained) == []
          assert :ok = Supervisor.stop(constrained)
        end
      after
        case Supervisor.restart_child(supervisor, child_id) do
          {:ok, restored} -> assert Process.whereis(SymphonyElixir.TaskSupervisor) == restored
          {:ok, restored, _info} -> assert Process.whereis(SymphonyElixir.TaskSupervisor) == restored
        end
      end
    end
  end

  # Existing synchronous ledger telemetry holds the real begin's workspace lock.
  # This variant changes current RAW after admitted_raw was captured; it does not
  # claim to reproduce a changed admitted_raw between precheck and begin.
  test "last completed workspace acknowledges its checked cursor while an unrelated B reader stays alive", c do
    workspace = workspace!("A")
    tracer = trace_effects!(c.pid)
    assert :ok = GenServer.call(c.pid, {:hold, :continue, true})
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    send(read!("A"), {:answer, {:ok, nil}})
    continuation = callback!(:continue)
    cursor = runtime(c.pid).github_inbox_batch.head.row.cursor
    applied = bytes(workspace)
    held = hold_poll_reader!(c.pid)
    before = runtime(c.pid)
    counts_before = trace_counts(tracer, c.pid)
    deliver!(c.pid, continuation)
    ack = callback!(:ack)
    assert ack == {:github_inbox_ack, cursor}
    pending = runtime(c.pid)
    assert pending.tracker_poll_read == before.tracker_poll_read
    assert pending.tracker_poll_cycle == before.tracker_poll_cycle
    assert pending.tracker_poll_pending == before.tracker_poll_pending
    assert Process.alive?(held.child)
    assert Process.alive?(held.reader.pid)
    assert pending.github_inbox_ack_pending == cursor
    deliver!(c.pid, ack)
    await!(c.pid, &is_nil(&1.github_inbox_ack_pending))
    assert GitHubEventInbox.pending_events(100) == []
    assert runtime(c.pid).tracker_poll_read == before.tracker_poll_read
    assert Process.alive?(held.child)
    assert Process.alive?(held.reader.pid)
    counts = trace_counts(tracer, c.pid)
    assert counts.read == counts_before.read
    assert counts.cas == 1
    assert counts.writer == 1
    assert counts.ledger == 1
    assert counts.ack == 1
    assert bytes(workspace) == applied
    assert effect_count("A", "ci.failure_autonomous_follow_up") == 1
    release_poll_reader!(held)
  end

  test "remaining workspaces retain one continuation until the existing B reader closes", c do
    workspace_a = workspace!("A")
    workspace_b = workspace!("B")
    tracer = trace_effects!(c.pid)
    assert :ok = GenServer.call(c.pid, {:hold, :continue, true})
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, nil}})
    continuation = callback!(:continue)
    assert runtime(c.pid).github_inbox_batch.head.workspaces == [workspace_b]
    applied_a = bytes(workspace_a)
    untouched_b = bytes(workspace_b)
    held = hold_poll_reader!(c.pid)
    counts_before = trace_counts(tracer, c.pid)
    deliver!(c.pid, continuation)
    deliver!(c.pid, continuation)
    queued = runtime(c.pid)
    assert queued.tracker_poll_read == held.reader
    assert queued.tracker_poll_pending == [:github_webhook]
    assert queued.github_webhook_check_in_progress
    assert Process.alive?(held.child)
    assert Process.alive?(held.reader.pid)
    assert trace_counts(tracer, c.pid).read == counts_before.read
    assert bytes(workspace_a) == applied_a
    assert bytes(workspace_b) == untouched_b
    refute_received {:github_read, _, "B"}
    refute_received {:github_callback, :ack, _}
    release_poll_reader!(held)
    next = read!("B")
    assert :ok = GenServer.call(c.pid, {:hold, :continue, false})
    send(next, {:answer, {:ok, nil}})
    ack!(c.pid)
    assert GitHubEventInbox.pending_events(100) == []
    assert effect_count("A", "ci.failure_detected") == 1
    assert effect_count("B", "ci.failure_detected") == 1
    assert bytes(workspace_a) == applied_a
    counts = trace_counts(tracer, c.pid)
    assert counts.cas == 2
    assert counts.writer == 0
    assert counts.ledger == 2
    assert counts.ack == 1
    refute_received {:github_read, _, "A"}
  end

  for drift <- [:context, :generation, :prefix] do
    test "completed workspace refuses #{drift} drift before ACK while another B reader stays owned", c do
      workspace = workspace!("A")
      tracer = trace_effects!(c.pid)
      assert :ok = GenServer.call(c.pid, {:hold, :continue, true})
      enqueue!(c.pid)
      send(read!("A"), {:answer, {:ok, nil}})
      continuation = callback!(:continue)
      applied = bytes(workspace)
      held = hold_poll_reader!(c.pid)
      before = runtime(c.pid)
      counts_before = trace_counts(tracer, c.pid)

      reason =
        case unquote(drift) do
          :context ->
            write_config!(c.workflow, put_in(c.config, [:tracker, :project_slug], "changed-before-ack"))
            :github_context_changed

          :generation ->
            assert :ok = GitHubEventInbox.reset()
            assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([event(:ci, "new-generation")])
            :github_cursor_changed

          :prefix ->
            path = GitHubEventInbox.location().events_path
            original = File.read!(path)
            changed = String.replace(original, @pr, @pr <> "/changed")
            assert changed != original
            File.write!(path, changed)
            :github_prefix_changed
        end

      deliver!(c.pid, continuation)
      after_rejection = runtime(c.pid)
      assert after_rejection.github_inbox_storage_error.reason_code == reason
      assert after_rejection.github_inbox_batch.head.blocked
      assert after_rejection.github_inbox_ack_pending == nil
      assert after_rejection.tracker_poll_read == before.tracker_poll_read
      assert after_rejection.tracker_poll_cycle == before.tracker_poll_cycle
      assert Process.alive?(held.child)
      assert Process.alive?(held.reader.pid)
      assert bytes(workspace) == applied
      assert length(GitHubEventInbox.pending_events(100)) == 1
      counts = trace_counts(tracer, c.pid)
      assert counts.read == counts_before.read
      assert counts.cas == 1
      assert counts.writer == 0
      assert counts.ledger == 1
      assert counts.ack == 0
      refute_received {:github_callback, :ack, _}
      release_poll_reader!(held)
      await!(c.pid, &is_nil(&1.tracker_poll_read))
      assert runtime(c.pid).github_inbox_batch.head.blocked
      assert runtime(c.pid).github_inbox_ack_pending == nil
      assert trace_counts(tracer, c.pid).ack == 0
      refute_received {:github_callback, :ack, _}
    end
  end

  defp hold_poll_reader!(pid) do
    fixture(%{hold_poll_states: true})
    send(pid, :run_poll_cycle)
    assert_receive {:poll_states_read, child, _states}, 2_000
    reader = runtime(pid).tracker_poll_read
    assert reader.phase == :approval
    assert Process.alive?(child)
    assert Process.alive?(reader.pid)
    %{child: child, reader: reader, child_monitor: Process.monitor(child), guardian_monitor: Process.monitor(reader.pid)}
  end

  defp release_poll_reader!(held) do
    child = held.child
    guardian = held.reader.pid
    child_monitor = held.child_monitor
    guardian_monitor = held.guardian_monitor
    send(child, {:answer, {:ok, []}})
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, 2_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 2_000
  end

  defp reject_admission_during_begin!(c, close_failure) do
    write_config!(c.workflow, put_in(c.config, [:agent, :max_concurrent_agents], 1))
    fixture(%{control_issue: issue("A")})
    workspace = workspace!("A")
    tracer = trace_effects!(c.pid)
    enqueue!(c.pid)
    send(read!("A"), {:answer, {:ok, issue("A")}})
    assert_receive {:github_writer, "A"}, 2_000
    refresh = read!("A")
    before = runtime(c.pid)
    handler = "c5-admission-#{System.unique_integer([:positive])}"
    parent = self()
    owner = c.pid

    :ok =
      :telemetry.attach(
        handler,
        [:symphony, :ledger, :event],
        fn _event, _measurements, metadata, _config ->
          if self() == owner and metadata[:event_type] == "dispatch.started" and metadata[:issue_id] == "A" do
            send(parent, {:admission_begin_barrier, self()})

            receive do
              :continue_admission_begin -> :ok
            after
              2_000 -> raise "Admission begin fixture barrier expired"
            end
          end
        end,
        nil
      )

    on_exit(fn ->
      send(owner, :continue_admission_begin)
      :telemetry.detach(handler)
    end)

    send(refresh, {:answer, {:ok, issue("A")}})
    assert_receive {:admission_begin_barrier, ^owner}, 2_000
    original = raw(workspace)
    changed = Map.put(original, "next_human_action", "changed while begin held its real lock")
    assert RunStateStore.material_projection(changed) == RunStateStore.material_projection(original)
    assert RunStateStore.coordinator_projection(changed) != operation(before).expected
    write_raw!(workspace, changed)
    extra = Path.join(DispatchAudit.marker_directory(workspace), "unexpected-fixture")
    if close_failure, do: File.write!(extra, "real close failure")
    send(owner, :continue_admission_begin)
    if close_failure, do: await!(owner, &blocked?/1), else: await!(owner, &(&1.github_inbox_ack_pending != nil))
    assert bytes(workspace) == Jason.encode!(changed)
    {workspace, before, tracer, extra}
  end

  # The fixture installs a real audited dispatch and gate, then delegates its real
  # DOWN to Orchestrator. Its body is controlled; it is not a provider session.
  defp install_audited_worker!(pid, issue) do
    :sys.replace_state(pid, fn wrapper ->
      state = wrapper.runtime
      workspace = Workspace.path_for_issue(issue)
      assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, state.lease_owner)
      assert {:ok, _} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(acquired.lease))
      assert {:ok, source, view} = RunStateStore.read_admission_source(workspace, issue)

      assert {:ok, ticket, admitted} =
               DispatchAudit.begin(
                 workspace,
                 %{
                   issue_id: issue.id,
                   issue_identifier: issue.identifier,
                   actor_type: "runtime",
                   actor_id: state.lease_owner,
                   policy_class: "fully_autonomous",
                   metadata: %{owner: state.lease_owner, epoch: acquired.token.epoch, passive: true, retry_attempt: 0}
                 },
                 source
               )

      owner = self()

      assert {:ok, worker} =
               Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
                 DispatchGate.run(owner, ticket.dispatch_id, fn ->
                   DispatchAudit.with_authorization(ticket, fn ->
                     AgentExecution.with_context(ticket, acquired.token, owner, admitted, fn ->
                       receive do
                         :finish ->
                           :ok

                         {:transition, caller, stage, attrs} ->
                           send(caller, {:worker_transition, self(), AgentExecution.transition_current(stage, attrs)})

                           receive do
                             :finish -> :ok
                           end
                       end
                     end)
                   end)
                 end)
               end)

      custody = make_ref()

      claim = %{
        token: acquired.token,
        lease: acquired.lease,
        custody_ref: custody,
        holder: :running,
        workspace: workspace,
        issue: issue,
        started_at_ms: System.monotonic_time(:millisecond),
        deadline: :not_pending,
        promotion_ref: nil,
        timer: nil,
        completion: nil
      }

      context = %{ticket: ticket, lease_token: acquired.token, owner: owner, worker: worker, issue_id: issue.id}

      entry = %{
        pid: worker,
        ref: Process.monitor(worker),
        identifier: issue.identifier,
        issue: issue,
        session_id: nil,
        workspace_path: workspace,
        workspace: workspace,
        dispatch_ticket: ticket,
        custody_ref: custody,
        lease_token: acquired.token,
        execution_started?: true,
        completion: nil,
        agent_execution: %{
          context: context,
          registry: AgentExecution.new_registry(),
          expected: RunStateStore.material_projection(admitted),
          terminal: nil,
          known_terminal: nil,
          final_usage_receipt: nil
        },
        started_at: DateTime.utc_now(),
        last_agent_timestamp: nil,
        last_agent_message: nil,
        last_agent_event: nil,
        agent_process_id: nil,
        agent_input_tokens: 0,
        agent_output_tokens: 0,
        agent_total_tokens: 0,
        issue_token_usage_base: Map.get(view, :token_usage, %{}),
        agent_last_reported_input_tokens: 0,
        agent_last_reported_output_tokens: 0,
        agent_last_reported_total_tokens: 0,
        turn_started_input_tokens: 0,
        recent_agent_updates: [],
        turn_count: 0,
        retry_attempt: 0,
        stage: view.stage,
        dispatch_stage: view.stage,
        resume_context: view.resume_context,
        last_ledger_event_id: admitted["last_ledger_event_id"],
        policy_override: nil,
        policy_class: "fully_autonomous",
        policy_source: "label"
      }

      assert :ok = LeaseManager.activate_dispatch(acquired.token, :not_pending, worker, ticket.dispatch_id)
      %{wrapper | runtime: %{state | running: Map.put(state.running, issue.id, entry), lease_claims: Map.put(state.lease_claims, issue.id, claim), claimed: MapSet.put(state.claimed, issue.id)}}
    end)

    runtime(pid).running[issue.id].pid
  end

  defp trace_effects!(owner) do
    functions = [
      {RunStateStore, :transition_coordinator_current, 4},
      {RunStateStore, :update_coordinator_current, 3},
      {SymphonyElixir.IssueSource, :update_issue_state_ref, 2},
      {RunLedger.CheckedStorage, :persist, 4},
      {TrackerReader, :start, 2},
      {LeaseManager, :activate_dispatch, 4},
      {GitHubEventInbox, :ack, 1},
      {DispatchAudit, :finish, 2},
      {Task.Supervisor, :start_child, 2}
    ]

    tracer = spawn(fn -> trace_loop(%{cas: 0, writer: 0, ledger: 0, read: 0, gate: 0, ack: 0, children: 0, finishes: []}) end)

    Enum.each(functions, fn {module, _, _} = mfa ->
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert 1 == :erlang.trace_pattern(mfa, true, [:local])
    end)

    assert 1 == :erlang.trace(owner, true, [:call, {:tracer, tracer}])

    on_exit(fn ->
      if Process.alive?(owner), do: :erlang.trace(owner, false, [:call])
      Enum.each(functions, &:erlang.trace_pattern(&1, false, [:local]))
      ref = Process.monitor(tracer)
      send(tracer, :stop)
      assert_receive {:DOWN, ^ref, :process, ^tracer, :normal}, 1_000
    end)

    tracer
  end

  defp trace_loop(counts) do
    receive do
      {:trace, _pid, :call, {RunStateStore, operation, _args}} when operation in [:transition_coordinator_current, :update_coordinator_current] ->
        trace_loop(Map.update!(counts, :cas, &(&1 + 1)))

      {:trace, _pid, :call, {SymphonyElixir.IssueSource, :update_issue_state_ref, _}} ->
        trace_loop(Map.update!(counts, :writer, &(&1 + 1)))

      {:trace, _pid, :call, {RunLedger.CheckedStorage, :persist, [entry | _]}} ->
        event = Map.get(entry, :event_type, Map.get(entry, "event_type", ""))
        counts = if String.starts_with?(event, "ci.failure") or String.starts_with?(event, "review.feedback"), do: Map.update!(counts, :ledger, &(&1 + 1)), else: counts
        trace_loop(counts)

      {:trace, _pid, :call, {TrackerReader, :start, _}} ->
        trace_loop(Map.update!(counts, :read, &(&1 + 1)))

      {:trace, _pid, :call, {LeaseManager, :activate_dispatch, _}} ->
        trace_loop(Map.update!(counts, :gate, &(&1 + 1)))

      {:trace, _pid, :call, {GitHubEventInbox, :ack, _}} ->
        trace_loop(Map.update!(counts, :ack, &(&1 + 1)))

      {:trace, _pid, :call, {Task.Supervisor, :start_child, _}} ->
        trace_loop(Map.update!(counts, :children, &(&1 + 1)))

      {:trace, _pid, :call, {DispatchAudit, :finish, [ticket, outcome]}} ->
        trace_loop(Map.update!(counts, :finishes, &(&1 ++ [{ticket, outcome}])))

      {:counts, caller, ref} ->
        send(caller, {:counts, ref, counts})
        trace_loop(counts)

      :stop ->
        :ok
    end
  end

  defp trace_counts(tracer, owner) do
    delivered = :erlang.trace_delivered(owner)
    assert_receive {:trace_delivered, ^owner, ^delivered}, 1_000
    ref = make_ref()
    send(tracer, {:counts, self(), ref})
    assert_receive {:counts, ^ref, counts}, 1_000
    counts
  end

  defp cleanup_real_owner!(pid, hook) do
    if Process.alive?(pid) do
      assert :ok = :sys.suspend(pid, 500)
      state = :sys.get_state(pid, 500)

      children =
        Enum.map(state.running, fn {_id, entry} -> entry.pid end) ++
          Enum.flat_map([state.tracker_poll_read, state.admission_read], fn
            nil -> []
            reader -> [reader.pid]
          end)

      refs = Enum.map(children, &{&1, Process.monitor(&1)})

      try do
        wait_fixture_hooks!(hook)
      after
        GenServer.stop(pid)
        Enum.each(refs, fn {child, ref} -> assert_receive {:DOWN, ^ref, :process, ^child, _}, 2_000 end)
      end
    end

    wait_fixture_hooks!(hook)
  end

  defp wait_until!(predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    unless predicate.() do
      assert System.monotonic_time(:millisecond) < deadline, "condition did not become true"

      receive do
      after
        5 -> wait_until!(predicate, deadline)
      end
    end
  end

  defp fixture(attrs), do: Application.put_env(:symphony_elixir, :github_continuation_fixture, Map.merge(%{owner: self()}, attrs))

  defp issue(id),
    do: %Issue{
      id: id,
      identifier: "ISSUE-" <> String.replace_prefix(id, "manual:", ""),
      title: "Local continuation",
      source: if(String.starts_with?(id, "manual:"), do: :manual, else: :tracker),
      state: "In Progress",
      labels: ["policy:fully-autonomous"],
      assigned_to_worker: true
    }

  defp workspace!(id, attrs \\ %{}, source \\ "tracker") do
    issue = issue(id)
    workspace = Workspace.path_for_issue(issue)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sample.ex"), "defmodule Sample do\n  def sample, do: :ok\nend\n")

    state =
      Map.merge(
        %{
          issue_id: id,
          issue_identifier: issue.identifier,
          stage: "await_checks",
          pr_url: @pr,
          effective_policy_class: "fully_autonomous",
          review_claims: %{},
          review_threads: %{},
          resume_context: %{},
          stage_history: [],
          stage_transition_counts: %{}
        },
        attrs
      )

    state = if source == :absent, do: state, else: Map.put(state, :issue_source, source)
    assert :ok = RunStateStore.save(workspace, state)
    workspace
  end

  defp event(kind, id \\ "delivery-1") do
    %GitHubEvent{
      provider: "github",
      raw: %{},
      event_id: id,
      event_name: if(kind == :review, do: "pull_request_review", else: "check_run"),
      action: if(kind == :review, do: "submitted", else: "completed"),
      pr_url: @pr,
      repo_full_name: "local/continuation",
      conclusion: if(kind == :review, do: nil, else: "failure"),
      check_name: "local-check",
      updated_at: ~U[2026-03-11 12:00:00Z]
    }
  end

  defp enqueue!(pid, kind \\ :ci) do
    assert {:ok, %{accepted: 1}} = GitHubEventInbox.enqueue([event(kind)])
    send(pid, :run_github_webhook_cycle)
  end

  defp read!(id) do
    assert_receive {:github_read, reader, ^id}, 2_000
    reader
  end

  defp callback!(kind) do
    assert_receive {:github_callback, ^kind, message}, 2_000
    message
  end

  defp deliver!(pid, message), do: assert(:ok == GenServer.call(pid, {:deliver, message}, 5_000))

  defp ack!(pid) do
    deliver!(pid, callback!(:ack))
    await!(pid, &is_nil(&1.github_inbox_ack_pending))
  end

  defp runtime(pid), do: GenServer.call(pid, :runtime, 500)
  defp operation(state), do: state.github_inbox_batch.head.operation
  defp phase?(%{github_inbox_batch: %{head: %{operation: %{phase: phase}}}}, phase), do: true
  defp phase?(_state, _phase), do: false
  defp blocked?(state), do: phase?(state, :blocked)
  defp raw(workspace), do: Jason.decode!(bytes(workspace))
  defp bytes(workspace), do: File.read!(RunStateStore.state_path(workspace))
  defp write_raw!(workspace, raw), do: File.write!(RunStateStore.state_path(workspace), Jason.encode!(raw))
  defp transition_count(workspace, stage), do: Enum.count(raw(workspace)["stage_history"], &(&1["stage"] == stage or &1["to"] == stage))

  defp effect_count(id, event \\ nil) do
    RunLedger.recent_entries(500)
    |> Enum.count(fn entry ->
      entry["issue_id"] == id and
        if event, do: entry["event_type"] == event, else: String.starts_with?(entry["event_type"] || "", "ci.failure") or String.starts_with?(entry["event_type"] || "", "review.feedback")
    end)
  end

  defp manual_path(c, id), do: Path.join(c.config.manual.store_root, Base.url_encode64(id, padding: false) <> ".json")

  defp manual_record!(c, issue) do
    File.mkdir_p!(c.config.manual.store_root)

    File.write!(
      manual_path(c, issue.id),
      Jason.encode!(%{issue: %{id: issue.id, identifier: issue.identifier, title: issue.title, source: "manual", state: issue.state, labels: issue.labels, assigned_to_worker: true}})
    )
  end

  defp write_config!(path, config) do
    File.write!(path, "---\n" <> Jason.encode!(config) <> "\n---\nLocal C5 fixture.\n")
    assert :ok = Workflow.set_workflow_file_path(path)
    assert :ok = WorkflowStore.force_reload()
    assert :ok = Config.validate!()
  end

  defp await!(pid, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    state = runtime(pid)

    if predicate.(state) do
      state
    else
      assert System.monotonic_time(:millisecond) < deadline, "GitHub continuation did not reach expected phase"

      receive do
      after
        5 -> await!(pid, predicate, deadline)
      end
    end
  end

  defp wait_file!(path, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    unless File.exists?(path) do
      assert System.monotonic_time(:millisecond) < deadline, "worker did not cross real gate"

      receive do
      after
        5 -> wait_file!(path, deadline)
      end
    end
  end

  defp cleanup_driver!(pid, hook) do
    if Process.alive?(pid) do
      assert :ok = :sys.suspend(pid, 500)
      state = :sys.get_state(pid, 500).runtime
      readers = Enum.reject([state.tracker_poll_read, state.admission_read], &is_nil/1)
      workers = Enum.map(state.running, fn {_id, entry} -> entry.pid end)
      monitors = Enum.map(Enum.uniq(Enum.map(readers, & &1.pid) ++ workers), &{&1, Process.monitor(&1)})

      :sys.replace_state(pid, fn wrapper ->
        Enum.each(readers, fn reader -> assert :ok = TrackerReader.cancel(reader) end)
        Enum.each(wrapper.runtime.retry_attempts, fn {_id, retry} -> if is_reference(retry.timer_ref), do: Process.cancel_timer(retry.timer_ref) end)
        Enum.each(wrapper.runtime.lease_claims, fn {_id, claim} -> if is_reference(claim.timer), do: Process.cancel_timer(claim.timer) end)
        if wrapper.runtime.github_inbox_wakeup, do: Process.cancel_timer(wrapper.runtime.github_inbox_wakeup.timer)
        wrapper
      end)

      try do
        wait_fixture_hooks!(hook)
      after
        GenServer.stop(pid)
        Enum.each(workers, fn worker -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
        Enum.each(monitors, fn {worker, ref} -> assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000 end)
      end
    end

    wait_fixture_hooks!(hook)
  end

  # Observe the physical shell, not a final marker or only its BEAM owner.
  # Only this fixture's PID records and exact shell command are considered.
  defp fixture_hook_pids(hook) do
    registered =
      case File.read(hook.pids) do
        {:ok, bytes} ->
          Enum.map(String.split(bytes, "\n", trim: true), fn value ->
            case Integer.parse(value) do
              {pid, ""} when pid > 0 -> pid
              _ -> flunk("invalid fixture hook PID record")
            end
          end)

        {:error, :enoent} ->
          []

        {:error, reason} ->
          flunk("cannot read fixture hook PID records: #{inspect(reason)}")
      end

    {output, status} = System.cmd("ps", ["-axww", "-o", "pid=", "-o", "command="], stderr_to_stdout: true)
    assert status == 0, "fixture process observation failed"

    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(String.trim(row), ~r/\s+/, parts: 2) do
        [pid_text, command] ->
          case Integer.parse(pid_text) do
            {pid, ""} ->
              expected_hook =
                Regex.match?(~r/^(?:.*\/)?sh -lc /, command) and
                  String.contains?(command, hook.pids) and String.contains?(command, hook.release)

              if pid in registered or expected_hook, do: [pid], else: []

            _ ->
              refute String.contains?(row, hook.root), "unreadable fixture process row"
              []
          end

        _ ->
          refute String.contains?(row, hook.root), "unreadable fixture process row"
          []
      end
    end)
  end

  defp wait_fixture_hooks!(hook, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    case fixture_hook_pids(hook) do
      [] ->
        :ok

      _pids ->
        assert System.monotonic_time(:millisecond) < deadline, "fixture shell did not exit after release"
        Process.sleep(5)
        wait_fixture_hooks!(hook, deadline)
    end
  end

  defp pause_default_scheduler! do
    if pid = Process.whereis(Orchestrator) do
      wait_default_idle!(pid, System.monotonic_time(:millisecond) + 2_000)
      assert :ok = :sys.suspend(pid)
      on_exit(fn -> assert :ok = :sys.resume(pid) end)
    end
  end

  defp wait_default_idle!(pid, deadline) do
    state = :sys.get_state(pid, 500)

    if state.running == %{} and is_nil(state.tracker_poll_cycle) and is_nil(state.tracker_poll_read) and is_nil(state.admission_read) and state.tracker_poll_pending == [] and
         not state.poll_check_in_progress do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "default scheduler must be idle"

      receive do
      after
        5 -> wait_default_idle!(pid, deadline)
      end
    end
  end
end
