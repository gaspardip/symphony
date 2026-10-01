defmodule SymphonyElixir.ReviewPublicationProcessTest do
  use SymphonyElixir.TestSupport
  @moduletag timeout: 60_000
  alias SymphonyElixir.{ReviewPublication, RunLedger, RunStateStore}
  alias SymphonyElixir.RunLedger.{CheckedStorage, PersistenceError}

  setup do
    root = Path.join(System.tmp_dir!(), "publication-process-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "RP-OS")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, tracker_kind: "memory", company_policy_pack: "private_autopilot")
    issue = %{id: "same-issue", identifier: "RP-OS"}
    pr = "https://github.com/example/repo/pull/1"
    threads = %{"comment:1" => %{"draft_state" => "approved_to_post", "draft_reply" => "Addressed."}}
    assert {:ok, _} = RunStateStore.transition(workspace, "implement", %{issue_id: issue.id, issue_identifier: issue.identifier, pr_url: pr, review_threads: threads})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, pr: pr, threads: threads, log: Application.fetch_env!(:symphony_elixir, :log_file), ledger: RunLedger.ledger_file_path()}
  end

  test "two independent OS owners cannot reserve and publish the same reply twice", c do
    results = children(c, [{"A", c.log, "normal"}, {"B", c.log, "normal"}])
    posted = Enum.count(results, fn {_name, result, status} -> status == 0 and match?({:ok, _, %{posted_count: 1}}, result) end)
    assert posted in [0, 1]
    calls = physical_calls(c)
    assert length(calls) in [0, 1]
    assert length(rows(c, "intent")) <= 1
    assert length(rows(c, "observed")) <= length(rows(c, "intent"))
    assert posted <= length(calls)
    before = calls
    if rows(c, "observed") == [], do: assert({:error, _} = parent_publish(c))
    assert physical_calls(c) == before

    for {_name, result, status} <- results do
      assert status == 0
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end

    refute File.exists?(c.ledger <> ".checked.lock")
  end

  test "two independent owners with different log roots share one immutable location", c do
    other_log = Path.join(c.root, "different-log/symphony.log")
    results = children(c, [{"A", c.log, "normal"}, {"B", other_log, "normal"}])
    posted = Enum.count(results, fn {_name, result, status} -> status == 0 and match?({:ok, _, %{posted_count: 1}}, result) end)
    assert posted in [0, 1]
    assert length(physical_calls(c)) in [0, 1]
    assert posted <= length(physical_calls(c))
    anchor = c |> anchor_path() |> File.read!() |> Jason.decode!()
    assert anchor["ledger_path"] in [c.ledger, Path.join(Path.dirname(other_log), "run_ledger.jsonl")]
    assert Enum.count(results, fn {_name, result, _} -> match?({:error, _}, result) end) == 2 - posted
  end

  test "two OS writers compare one captured complete history with exactly one winning append", c do
    results = children(c, [{"A", c.log, "reserve"}, {"B", c.log, "reserve"}])
    assert Enum.count(results, fn {_name, result, status} -> status == 0 and match?({:ok, %{}}, result) end) == 1
    assert Enum.count(results, fn {_name, result, status} -> status == 0 and match?({:error, %PersistenceError{}}, result) end) == 1
    assert {:ok, rows, _} = CheckedStorage.entries_checked(c.ledger)
    assert Enum.count(rows, &(&1["event_type"] == "test.concurrent.intent")) == 1
    assert physical_calls(c) == []
    refute File.exists?(c.ledger <> ".checked.lock")
  end

  for phase <- ["intent", "transport", "observed"] do
    test "physical VM death at #{phase} retains evidence and never replays transport", c do
      phase = unquote(phase)
      [{"A", :no_result, 77}] = children(c, [{"A", c.log, phase}])
      raw = File.read!(RunStateStore.state_path(c.workspace))
      calls = physical_calls(c)
      assert length(rows(c, "intent")) == 1

      if phase == "observed" do
        assert length(rows(c, "observed")) == 1
        assert {:ok, threads, %{posted_count: 0, reconciled_count: 1}} = parent_publish(c)
        assert threads["comment:1"]["posted_reply_id"] == "os-reply"
      else
        assert rows(c, "observed") == []
        assert {:error, {:review_publication_blocked, :attempt_uncertain, _}} = parent_publish(c)
      end

      assert physical_calls(c) == calls
      assert length(calls) == if(phase == "intent", do: 0, else: 1)
      assert File.read!(RunStateStore.state_path(c.workspace)) == raw
      refute File.exists?(c.ledger <> ".checked.lock")
    end
  end

  test "anchor confirmed on disk but missing its event cannot be repaired by another caller", c do
    File.mkdir!(c.ledger <> ".checked.lock")

    try do
      assert {:error, %PersistenceError{phase: :lock}} = parent_publish(c)
      assert File.exists?(anchor_path(c))
      assert physical_calls(c) == []
    after
      File.rmdir!(c.ledger <> ".checked.lock")
    end

    before = File.read!(c.ledger)
    assert {:error, {:review_publication_blocked, :location_unconfirmed, nil}} = parent_publish(c)
    assert File.read!(c.ledger) == before
    assert physical_calls(c) == []
  end

  # Controlled local transport only. It records the physical call before returning
  # a genuine result, or terminates the entire child VM without a result map.
  defmodule ParentClient do
    def post_review_comment_reply(pr, _id, _body, opts) do
      File.write!(opts[:calls], "parent\n", [:append])
      {:ok, %{id: "os-reply", url: pr <> "#os-reply"}}
    end
  end

  defp parent_publish(c),
    do:
      ReviewPublication.publish(c.workspace, c.issue, c.pr, c.threads, :execution,
        policy_pack: :private_autopilot,
        github_client: ParentClient,
        github_client_opts: [calls: Path.join(c.root, "calls")]
      )

  defp children(c, specs) do
    executable = System.find_executable("elixir") || flunk("Elixir executable is required for independent OS publication tests")
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    modules = [ReviewPublication, RunLedger, CheckedStorage, RunStateStore, SymphonyElixir.AgentExecution, SymphonyElixir.PRWatcher]

    hashes =
      Map.new(modules, fn mod ->
        assert {:module, ^mod} = Code.ensure_loaded(mod)

        beam =
          case :code.which(mod) do
            :cover_compiled ->
              assert {:file, original} = :cover.is_compiled(mod)
              path = List.to_string(original)
              assert Path.extname(path) == ".beam"
              path

            original when is_list(original) ->
              List.to_string(original)
          end

        {mod, digest(File.read!(beam))}
      end)

    gate = Path.join(c.root, "start")

    script = ~S'''
    spawn(fn -> Process.sleep(25_000); System.halt(91) end)
    [input] = System.argv()
    config = input |> File.read!() |> :erlang.binary_to_term()
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:crypto)
    Enum.each(config.hashes, fn {mod, expected} ->
      {:module, ^mod} = Code.ensure_loaded(mod)
      actual = mod |> :code.which() |> List.to_string() |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
      if actual != expected, do: raise("child build differs from captured artifact")
    end)
    Application.put_env(:symphony_elixir, :log_file, config.log)
    SymphonyElixir.Workflow.set_workflow_file_path(config.workflow)
    :ok = :telemetry.attach("publication-crash", [:symphony, :ledger, :event], fn _, _, metadata, phase ->
      if {metadata.event_type, phase} in [{"review.publication.intent", "intent"}, {"review.publication.observed", "observed"}], do: System.halt(77)
    end, config.phase)
    defmodule LocalPublicationClient do
      def post_review_comment_reply(pr, _id, _body, opts) do
        File.write!(opts[:calls], System.pid() <> "\n", [:append])
        if opts[:phase] == "transport", do: System.halt(77)
        {:ok, %{id: "os-reply", url: pr <> "#os-reply"}}
      end
    end
    File.write!(config.ready, System.pid())
    wait = fn wait ->
      if File.exists?(config.gate), do: :ok, else: (Process.sleep(5); wait.(wait))
    end
    wait.(wait)
    result = if config.phase == "reserve" do
      {:ok, entry} = SymphonyElixir.RunLedger.prepare_entry("test.concurrent.intent", %{issue_id: config.issue.id})
      SymphonyElixir.RunLedger.CheckedStorage.persist_if_current(entry, config.ledger, config.fingerprint, :not_pending)
    else
      SymphonyElixir.ReviewPublication.publish(config.workspace, config.issue, config.pr, config.threads, :execution,
        policy_pack: :private_autopilot, github_client: LocalPublicationClient, github_client_opts: [calls: config.calls, phase: config.phase])
    end
    File.write!(config.output, :erlang.term_to_binary(result))
    '''

    assert {:ok, _, fingerprint} = CheckedStorage.entries_checked(c.ledger)

    runners =
      Enum.map(specs, fn {name, log, phase} ->
        input = Path.join(c.root, name <> ".input")
        ready = Path.join(c.root, name <> ".ready")
        output = Path.join(c.root, name <> ".result")

        config = %{
          hashes: hashes,
          ledger: c.ledger,
          fingerprint: fingerprint,
          log: log,
          workflow: Workflow.workflow_file_path(),
          phase: phase,
          ready: ready,
          output: output,
          gate: gate,
          workspace: c.workspace,
          issue: c.issue,
          pr: c.pr,
          threads: c.threads,
          calls: Path.join(c.root, "calls")
        }

        File.write!(input, :erlang.term_to_binary(config))
        task = Task.async(fn -> System.cmd(executable, ["--erl", "+S 1:1 +A 1"] ++ paths ++ ["-e", script, "--", input], stderr_to_stdout: true) end)
        %{name: name, ready: ready, output: output, task: task}
      end)

    try do
      wait_files!(Enum.map(runners, & &1.ready), System.monotonic_time(:millisecond) + 15_000)
      assert runners |> Enum.map(&File.read!(&1.ready)) |> Enum.uniq() |> length() == length(runners)
      File.write!(gate, "go")

      Enum.map(runners, fn runner ->
        {output, status} = Task.await(runner.task, 30_000)
        assert status in [0, 77], output

        result =
          case File.read(runner.output) do
            {:ok, bytes} -> :erlang.binary_to_term(bytes, [:safe])
            {:error, :enoent} -> :no_result
          end

        {runner.name, result, status}
      end)
    after
      # Release even if readiness assertions fail. The child's bounded watchdog
      # terminates its real OS process; do not kill only a Task around System.cmd.
      File.write!(gate, "go")

      Enum.each(runners, fn runner ->
        if Process.alive?(runner.task.pid), do: Task.await(runner.task, 30_000)
      end)
    end
  end

  defp wait_files!(files, deadline) do
    if Enum.all?(files, &File.exists?/1) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "independent VM readiness timeout"
      Process.sleep(10)
      wait_files!(files, deadline)
    end
  end

  defp physical_calls(c) do
    case File.read(Path.join(c.root, "calls")) do
      {:ok, bytes} -> String.split(bytes, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp rows(c, suffix) do
    assert {:ok, rows, _} = CheckedStorage.entries_checked(c.ledger)
    Enum.filter(rows, &(&1["event_type"] == "review.publication.#{suffix}"))
  end

  defp anchor_path(c), do: Path.join(c.root, ".review-publication-" <> digest(c.issue.id) <> ".json")
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
