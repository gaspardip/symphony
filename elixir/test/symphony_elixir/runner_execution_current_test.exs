defmodule SymphonyElixir.RunnerExecutionCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunStateStore, VerifierResult, VerifierRunner}

  # Storage and lifecycle operations are real. This bounded owner fixture only
  # supports the no-provider invocation used here; Orchestrator custody is tested elsewhere.
  defmodule Owner do
    use GenServer
    alias SymphonyElixir.RunStateStore

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      context = %{ticket: opts.ticket, lease_token: opts.token, owner: self(), worker: opts.worker, issue_id: opts.issue.id}

      {:ok,
       %{
         context: context,
         authority: %{ticket: opts.ticket, lease_token: opts.token},
         expected: RunStateStore.material_projection(opts.raw),
         known: nil,
         calls: [],
         marker: opts.marker,
         marker_confirms: 0,
         terminal: nil
       }}
    end

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}

    def handle_call({:agent_execution, invocation, expected, action}, {pid, _tag}, state) do
      true = pid == state.context.worker
      true = invocation == %{context: state.context, binding: nil, ordinal: 0}
      true = expected == state.expected
      state = %{state | calls: state.calls ++ [action]}
      {reply, state} = reply_to(action, state)
      {:reply, reply, state}
    end

    defp reply_to({:confirm, nil, 0}, state) do
      # Acquiring from another process detects an owner RPC made inside the
      # worker's lifecycle lock, without relying on an RPC timeout to assert it.
      lock = {{RunStateStore, state.context.ticket.workspace}, self()}
      true = :global.set_lock(lock, [node()], 0)
      true = :global.del_lock(lock, [node()])
      marked? = is_binary(state.marker) and File.exists?(state.marker)
      count = state.marker_confirms + if(marked?, do: 1, else: 0)
      state = %{state | marker_confirms: count}

      if count == 2 do
        {{:error, :controlled_cleanup_uncertainty}, state}
      else
        case RunStateStore.ensure_current(state.authority, state.expected) do
          {:ok, _current} -> {:ok, state}
          {:error, reason} -> {{:error, reason}, state}
        end
      end
    end

    defp reply_to({:confirm_own_terminal, previous, next}, state) do
      true = previous == state.expected

      case RunStateStore.confirm_terminal_current(state.authority, next) do
        :ok -> {{:ok, :terminal_confirmed}, %{state | expected: next, known: next}}
        {:error, reason} -> {{:error, reason}, state}
      end
    end

    defp reply_to(:confirm_stop_notification, %{known: next, expected: next} = state) when is_map(next),
      do: {RunStateStore.confirm_terminal_current(state.authority, next), state}

    @impl true
    def handle_info({:agent_execution_stale, context, ids, cause}, state) do
      true = context == state.context
      true = ids == %{run_id: context.ticket.run_id, dispatch_id: context.ticket.dispatch_id}
      {:noreply, %{state | terminal: {:stale_execution, ids, cause}}}
    end

    def handle_info({:agent_execution_uncertain, context, cause}, state) do
      true = context == state.context
      {:noreply, %{state | terminal: {:accounting_uncertain, cause}}}
    end
  end

  defmodule TrackerClient do
    def graphql(query, vars) do
      parent = Application.fetch_env!(:symphony_elixir, __MODULE__)

      cond do
        String.contains?(query, "SymphonyCreateComment") ->
          send(parent, {:closure_effect, :comment, vars.issueId})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

        String.contains?(query, "SymphonyResolveStateId") ->
          {:ok, %{"data" => %{"issue" => %{"team" => %{"id" => "fixture-team", "states" => %{"nodes" => [%{"id" => vars.stateName}]}}}}}}

        String.contains?(query, "SymphonyUpdateIssueState") ->
          send(parent, {:closure_effect, :move, vars.issueId})
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "runner-current-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "RUNNER-1")

    issue = %Issue{
      id: "runner-current-#{System.unique_integer([:positive])}",
      identifier: "RUNNER-1",
      title: "Runner boundaries",
      description: "private-issue-payload-sentinel",
      state: "In Progress",
      source: :tracker
    }

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    workflow_opts = [workspace_root: workspace_root, runner_install_root: Path.join(root, "runner-install")]
    write_workflow_file!(Workflow.workflow_file_path(), workflow_opts)

    File.write!(
      RunStateStore.state_path(workspace),
      Jason.encode!(%{
        "issue_id" => issue.id,
        "issue_identifier" => issue.identifier,
        "stage" => "implement"
      })
    )

    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_fixture = Application.get_env(:symphony_elixir, TrackerClient)
    Application.put_env(:symphony_elixir, :linear_client_module, TrackerClient)
    Application.put_env(:symphony_elixir, TrackerClient, self())

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_app_env(:symphony_elixir, :linear_client_module, previous_client)
      SymphonyElixir.TestSupport.restore_app_env(:symphony_elixir, TrackerClient, previous_fixture)
      File.rm_rf!(root)
    end)

    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "runner-current-owner")
    assert {:ok, source, view} = RunStateStore.read_admission_source(workspace, issue)

    assert {:ok, ticket, raw} =
             DispatchAudit.begin(
               workspace,
               %{
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 stage: view.stage,
                 metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}
               },
               source
             )

    marker = if tags[:cleanup_failure], do: Path.join(root, "cleanup-marker")
    owner = start_supervised!({Owner, %{ticket: ticket, token: acquired.token, raw: raw, worker: self(), issue: issue, marker: marker}})
    on_exit(fn -> assert {:ok, :released} = LeaseManager.release_token(acquired.token) end)

    parent = self()
    telemetry_id = {__MODULE__, make_ref()}
    events = [[:symphony, :verifier, :completed], [:symphony, :proof, :behavioral, :evaluated], [:symphony, :proof, :ui, :evaluated]]
    assert :ok = :telemetry.attach_many(telemetry_id, events, fn event, _, _, pid -> send(pid, {:runner_event, event}) end, parent)
    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    %{root: root, workspace: workspace, issue: issue, workflow_opts: workflow_opts, ticket: ticket, token: acquired.token, raw: raw, owner: owner, marker: marker}
  end

  test "bootstrap restores admitted bytes with owner confirmation before the lifecycle lock", c do
    configure!(c, hook_after_create: "printf checkout > README.md")
    before = File.read!(RunStateStore.state_path(c.workspace))
    assert scoped(c, fn -> Workspace.create_for_issue(c.issue) end) == {:ok, c.workspace}
    assert File.read!(RunStateStore.state_path(c.workspace)) == before
    assert File.read!(Path.join(c.workspace, "README.md")) == "checkout"
    assert GenServer.call(c.owner, :state).calls != []
  end

  test "a material control blocks workspace hooks and preserves the control bytes", c do
    configure!(c, hook_after_create: "touch after-create")

    result =
      scoped(c, fn ->
        control!(c)
        before = File.read!(RunStateStore.state_path(c.workspace))
        terminal = Workspace.create_for_issue(c.issue)
        assert File.read!(RunStateStore.state_path(c.workspace)) == before
        terminal
      end)

    assert {:stop, {:stale_execution, _, :material_state_changed}} = result
    refute File.exists?(Path.join(c.workspace, "after-create"))
  end

  test "failed hook and failed restore both survive the lifecycle postcheck", c do
    configure!(c, hook_after_create: "touch .symphony; exit 17")
    result = scoped(c, fn -> Workspace.create_for_issue(c.issue) end)

    assert {:stop, {:stale_execution, _, {:lifecycle_result, {:workspace_lifecycle_result, {:error, {:workspace_lifecycle_failed, outcomes}}}, postcheck_cause}}} = result
    assert {:returned, {:error, {:workspace_hook_failed, "after_create", 17, _output}}} = outcomes.hook
    assert {:raised, :error, %File.Error{}, [_ | _]} = outcomes.restore
    assert postcheck_cause != nil
    [preserved] = Path.wildcard(Path.join(Path.dirname(c.workspace), ".RUNNER-1.bootstrap-*"), match_dot: true)
    assert File.exists?(Path.join(preserved, "run_state.json"))
  end

  test "a control from before_run prevents policy, delivery and after_run", c do
    controlled = c.raw |> Map.put("policy_override", "operator-control") |> Jason.encode!()
    control_path = Path.join(c.root, "control.json")
    File.write!(control_path, controlled)
    configure!(c, hook_after_create: "touch README.md", hook_before_run: "cp #{quote_shell(control_path)} .symphony/run_state.json", hook_after_run: "touch after-run")
    assert {:stop, {:stale_execution, _, :material_state_changed}} = scoped(c, fn -> AgentRunner.run(c.issue) end)
    assert File.read!(RunStateStore.state_path(c.workspace)) == controlled
    refute File.exists?(Path.join(c.workspace, "after-run"))
    refute_received {:closure_effect, _, _}
  end

  test "after_run shell failure is visible when audited and retains legacy warning behavior", c do
    configure!(c, hook_after_run: "exit 17")

    assert {:error, {:workspace_hook_failed, "after_run", 17, ""}} =
             scoped(c, fn -> Workspace.run_after_run_hook(c.workspace, c.issue) end)

    legacy_workspace = Path.join(Path.dirname(c.workspace), "LEGACY-1")
    File.mkdir_p!(legacy_workspace)
    assert :ok = Workspace.run_after_run_hook(legacy_workspace, "LEGACY-1")
  end

  test "own policy blocked result survives cleanup permission denial", c do
    configure!(c, hook_after_create: "touch README.md", hook_after_run: "touch after-run")
    assert {:stop, %RunPolicy.Violation{code: :missing_checkout}} = scoped(c, fn -> AgentRunner.run(c.issue) end)
    state = GenServer.call(c.owner, :state)
    assert state.known["stage"] == "blocked"
    assert Enum.count(state.calls, &match?({:confirm_own_terminal, _, _}, &1)) == 1
    assert Enum.count(state.calls, &(&1 == :confirm_stop_notification)) == 2
    assert_received {:closure_effect, :comment, _}
    assert_received {:closure_effect, :move, _}
    refute File.exists?(Path.join(c.workspace, "after-run"))
  end

  test "known done does not fabricate successful execution or run lifecycle hooks", c do
    configure!(c, hook_after_create: "touch after-create", hook_after_run: "touch after-run")

    assert {:done, issue} =
             scoped(c, fn ->
               assert {:ok, %{stage: "done"}} = AgentExecution.transition_current("done", %{})
               assert {:stop, {:execution_stopped, %{stage: "done"}}} = AgentRunner.run(c.issue)
               {:done, c.issue}
             end)

    assert issue == c.issue
    refute File.exists?(Path.join(c.workspace, "after-create"))
    refute File.exists?(Path.join(c.workspace, "after-run"))
  end

  @tag cleanup_failure: true
  test "primary exception survives cleanup uncertainty and both failures are logged", c do
    configure!(c, hook_after_create: "touch README.md", hook_before_run: "touch #{quote_shell(c.marker)}; exit 17", hook_after_run: "touch after-run")

    log =
      capture_log(fn ->
        assert_raise RuntimeError, ~r/workspace_hook_failed/, fn -> scoped(c, fn -> AgentRunner.run(c.issue) end) end
      end)

    assert log =~ "AgentRunner cleanup failed primary="
    assert log =~ "RuntimeError"
    assert log =~ "agent_runner.ex:"
    assert log =~ "cleanup=accounting_uncertain: :controlled_cleanup_uncertainty"
    refute log =~ c.issue.description
    refute File.exists?(Path.join(c.workspace, "after-run"))
    assert GenServer.call(c.owner, :state).terminal == {:accounting_uncertain, :controlled_cleanup_uncertainty}
  end

  test "smoke control stops verification before evidence and provider effects", c do
    opts = verifier_opts(c, fn -> control!(c) end)

    assert {:stop, {:stale_execution, _, :material_state_changed}} =
             scoped(c, fn ->
               VerifierRunner.verify(c.workspace, c.issue, %{}, inspection(c), opts)
             end)

    assert_received :shell_command
    refute_received {:git_command, _}
    refute_received :verifier_session
    refute_received {:runner_event, _}
  end

  test "post-merge control returns stale instead of the successful command result", c do
    opts = verifier_opts(c, fn -> control!(c) end)

    assert {:stop, {:stale_execution, _, :material_state_changed}} =
             scoped(c, fn ->
               VerifierRunner.post_merge_verify(c.workspace, inspection(c).harness, opts)
             end)

    assert_received :shell_command
  end

  for kind <- [:stale_execution, :execution_stopped] do
    @tag terminal_kind: kind
    test "verifier preserves #{kind} without manufacturing a domain verdict", c do
      parent = self()

      terminal =
        case c.terminal_kind do
          :stale_execution -> {:stop, {:stale_execution, %{run_id: c.ticket.run_id, dispatch_id: c.ticket.dispatch_id}, :fixture_boundary}}
          :execution_stopped -> {:stop, {:execution_stopped, %{stage: "done"}}}
        end

      # The injected boundary proves passthrough, not owner authorization.
      opts =
        Keyword.put(verifier_opts(c), :verifier_session_runner, fn _, _, _, _ ->
          send(parent, :verifier_session)
          terminal
        end)

      assert scoped(c, fn -> VerifierRunner.verify(c.workspace, c.issue, %{}, inspection(c), opts) end) == terminal
      assert_received :verifier_session
      assert_received {:git_command, ["rev-parse", "HEAD"]}
      refute_received {:git_command, ["rev-parse", "HEAD"]}
      refute_received {:runner_event, [:symphony, :verifier, :completed]}
    end
  end

  test "control on verifier return prevents a pass verdict and completion event", c do
    parent = self()

    opts =
      Keyword.put(verifier_opts(c), :verifier_session_runner, fn _, _, _, _ ->
        send(parent, :verifier_session)
        control!(c)
        {:ok, %VerifierResult{verdict: :pass, summary: "obsolete pass"}}
      end)

    assert {:stop, {:stale_execution, _, :material_state_changed}} =
             scoped(c, fn ->
               VerifierRunner.verify(c.workspace, c.issue, %{}, inspection(c), opts)
             end)

    assert_received :verifier_session
    assert_received {:git_command, ["rev-parse", "HEAD"]}
    refute_received {:git_command, ["rev-parse", "HEAD"]}
    refute_received {:runner_event, [:symphony, :verifier, :completed]}
  end

  defp scoped(c, fun) do
    DispatchAudit.with_authorization(c.ticket, fn ->
      AgentExecution.with_context(c.ticket, c.token, c.owner, c.raw, fun)
    end)
  end

  defp configure!(c, opts), do: write_workflow_file!(Workflow.workflow_file_path(), Keyword.merge(c.workflow_opts, opts))
  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp control!(c) do
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, "operator-control"))
    :ok
  end

  defp inspection(c) do
    %RunInspector.Snapshot{
      workspace: c.workspace,
      harness: %RepoHarness{
        smoke_command: "smoke-fixture",
        post_merge_command: "post-merge-fixture",
        behavioral_proof: %{required: false, mode: "unit_first", source_paths: ["lib"], test_paths: ["test"], artifact_path: nil},
        ui_proof: %{required: false}
      }
    }
  end

  defp verifier_opts(c, on_shell \\ fn -> :ok end) do
    File.mkdir_p!(Path.join(c.workspace, ".git"))
    parent = self()

    [
      include_pr_details: false,
      shell_runner: fn workspace, _command, _opts ->
        assert workspace == c.workspace
        send(parent, :shell_command)
        on_shell.()
        {"ok", 0}
      end,
      command_runner: fn "git", args, _opts ->
        send(parent, {:git_command, args})

        case args do
          ["status", "--porcelain", "--untracked-files=all"] -> {"", 0}
          ["diff", "--stat", "--no-ext-diff", "HEAD"] -> {"", 0}
          ["config", "--get", "remote.origin.url"] -> {"https://example.test/fixture.git", 0}
          ["rev-parse", "--abbrev-ref", "HEAD"] -> {"fixture", 0}
          ["rev-parse", "HEAD"] -> {"fixture-head", 0}
          ["status", "--porcelain"] -> {"", 0}
        end
      end,
      verifier_session_runner: fn _, _, _, _ ->
        send(parent, :verifier_session)
        {:ok, %VerifierResult{verdict: :pass, summary: "pass"}}
      end
    ]
  end
end
