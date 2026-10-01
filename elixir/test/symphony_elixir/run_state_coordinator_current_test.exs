defmodule SymphonyElixir.RunStateCoordinatorCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DeployAudit, DispatchAudit, LeaseManager, RunLedger, RunStateStore}

  setup do
    root = Path.join(System.tmp_dir!(), "coordinator-current-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "C5-1")
    issue = %{id: "manual:c5-#{System.unique_integer([:positive])}", identifier: "C5-1"}
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    raw = %{
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "issue_source" => "manual",
      "stage" => "await_checks",
      "pr_url" => "https://github.com/example/c5/pull/1",
      "effective_policy_class" => "fully_autonomous",
      "resume_context" => %{"budget_pressure" => "high", "turn_count" => 7},
      "token_usage" => %{"input_tokens" => 70, "output_tokens" => 30, "total_tokens" => 100}
    }

    File.write!(RunStateStore.state_path(workspace), Jason.encode!(raw))
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "coordinator-owner")

    authority = %{
      workspace: workspace,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      binding: :legacy_absent,
      lease_token: acquired.token,
      deadline: System.monotonic_time(:millisecond) + 30_000
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, raw: raw, authority: authority, expected: RunStateStore.coordinator_projection(raw)}
  end

  test "coordinator projection adds seven inputs and preserves RAW absence without changing worker projection", c do
    extra = ~w(resume_context last_ci_failure issue_source runner_channel runner_instance_id last_review_decision next_human_action)
    raw = Map.merge(c.raw, Map.new(extra, &{&1, nil}))
    worker = RunStateStore.material_projection(raw)
    coordinator = RunStateStore.coordinator_projection(raw)
    assert coordinator == Map.merge(worker, Map.take(raw, extra))
    assert Enum.all?(extra, &(not Map.has_key?(worker, &1)))
    assert RunStateStore.coordinator_projection(Map.drop(raw, extra)) == worker
    refute RunStateStore.coordinator_projection(Map.drop(raw, extra)) == coordinator
    assert RunStateStore.coordinator_projection(Map.put(raw, "token_usage", %{"total_tokens" => 999})) == coordinator
    assert RunStateStore.coordinator_projection(Map.put(raw, "lease_updated_at", "new")) == coordinator
    before = evidence(c)
    assert {:ok, state} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    assert json(state) == c.raw
    assert evidence(c) == before
    refute Map.has_key?(state, :policy_override)
  end

  for kind <- [:review, :ci] do
    @tag kind: kind
    test "#{kind} observation preserves stop, budget, identity and RAW missing fields", c do
      c = control(c, &Map.put(&1, "stop_reason", %{"code" => "previous-control"}))
      attrs = observation(c, c.kind)
      before_ledger = ledger(c)
      assert {:ok, persisted} = RunStateStore.update_coordinator_current(c.authority, c.expected, attrs)
      assert json(persisted) == raw!(c)
      assert persisted.stage == "await_checks"
      assert persisted.stop_reason == %{code: "previous-control"}
      assert persisted.token_usage.total_tokens == 100
      assert json(persisted.resume_context)["budget_pressure"] == "high"
      assert json(persisted.resume_context)["turn_count"] == 7
      refute Map.has_key?(persisted, :run_id)
      refute Map.has_key?(persisted, :last_ledger_event_id)
      refute Map.has_key?(persisted, :policy_override)
      assert ledger(c) == before_ledger
      assert {:ok, _} = RunStateStore.ensure_coordinator_current(c.authority, RunStateStore.coordinator_projection(persisted))
      assert {:error, {:coordinator_precondition_failed, :coordinator_material_changed}} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    end
  end

  for {kind, stage} <- [{:ci, "implement"}, {:review, "implement"}, {:review, "review_verification"}] do
    @tag kind: kind, destination: stage
    test "#{kind} transition to #{stage} records one audited operation from prior blocked state", c do
      c = control(c, &Map.merge(&1, %{"stage" => "blocked", "stop_reason" => %{"code" => "token_budget"}, "last_decision" => "blocked", "last_rule_id" => "budget", "last_failure_class" => "budget"}))
      before = length(rows(c))
      assert {:ok, persisted} = RunStateStore.transition_coordinator_current(c.authority, c.expected, c.destination, transition(c, c.kind))
      assert persisted.stage == c.destination
      assert persisted.stop_reason == nil
      assert persisted.last_decision == nil
      assert persisted.last_rule_id == nil
      assert persisted.last_failure_class == nil
      assert persisted.next_human_action == nil
      assert persisted.token_usage.total_tokens == 100
      assert json(persisted.resume_context)["budget_pressure"] == "high"
      assert persisted.lease_generation == c.authority.lease_token.lease_generation
      refute Map.has_key?(persisted, :run_id)
      assert persisted.stage_transition_counts[c.destination] == 1
      assert List.last(persisted.stage_history).stage == c.destination
      assert json(persisted) == raw!(c)
      events = Enum.drop(rows(c), before)
      assert Enum.map(events, & &1["event_type"]) == ["stage.transition.requested", "stage.transition"]
      assert List.last(events)["event_id"] == persisted.last_ledger_event_id
      assert List.last(events)["metadata"]["previous_stage"] == "blocked"
      assert :ok = DispatchAudit.ensure_available(c.workspace)
      assert :ok = DeployAudit.ensure_available(c.workspace)
      assert {:ok, _} = RunStateStore.ensure_coordinator_current(c.authority, RunStateStore.coordinator_projection(persisted))
    end
  end

  test "an unrelated string-keyed extension does not hide the current top-level stage", c do
    c = control(c, &Map.merge(&1, %{"stage" => "implement", "retained-extension" => %{"value" => "keep"}}))
    before = ledger(c)
    assert {:ok, state} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
    assert state.stage == "implement"
    assert json(state)["retained-extension"] == c.raw["retained-extension"]
    assert json(state) == raw!(c)
    assert ledger(c) == before
  end

  test "same-stage transition does not add events, defaults or stage history", c do
    c = control(c, &Map.put(&1, "stage", "implement"))
    before = ledger(c)
    assert {:ok, persisted} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
    assert persisted.await_checks_polls == 0
    refute Map.has_key?(persisted, :last_ledger_event_id)
    refute Map.has_key?(persisted, :stage_history)
    refute Map.has_key?(persisted, :policy_override)
    assert ledger(c) == before
    assert json(persisted) == raw!(c)
  end

  for source <- [:absent, nil, "manual", "tracker", " MANUAL "] do
    @tag source: source
    test "transition preserves source representation #{inspect(source)}", c do
      c = control(c, fn raw -> if c.source == :absent, do: Map.delete(raw, "issue_source"), else: Map.put(raw, "issue_source", c.source) end)
      assert {:ok, _} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
      assert Map.fetch(raw!(c), "issue_source") == Map.fetch(c.raw, "issue_source")
    end
  end

  test "identified authority is verified after its real dispatch closes without opening another ticket", c do
    c = identified(c)
    before = evidence(c)
    assert {:ok, state} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    assert state.run_id == elem(c.authority.binding, 1).run_id
    assert evidence(c) == before
    assert {:ok, updated} = RunStateStore.update_coordinator_current(c.authority, c.expected, observation(c, :review))
    assert updated.run_id == state.run_id
    assert updated.run_identity_event_id == state.run_identity_event_id
    assert updated.run_identity_ledger_path == state.run_identity_ledger_path
    assert :ok = DispatchAudit.ensure_available(c.workspace)
  end

  test "identified binding never becomes legacy and a different captured run is rejected", c do
    c = identified(c)
    before = evidence(c)
    legacy = %{c.authority | binding: :legacy_absent}
    assert {:error, {:coordinator_precondition_failed, :coordinator_binding_changed}} = RunStateStore.ensure_coordinator_current(legacy, c.expected)
    {:identified, binding} = c.authority.binding
    other = %{c.authority | binding: {:identified, %{binding | run_id: "other"}}}
    assert {:error, {:coordinator_precondition_failed, :coordinator_binding_changed}} = RunStateStore.ensure_coordinator_current(other, c.expected)
    assert evidence(c) == before
  end

  test "identified evidence corruption is checked and never repaired or adopted", c do
    c = identified(c)
    File.write!(c.authority.lease_token.storage.ledger_path, ledger!(c) <> "{broken}\n")
    before = evidence(c)
    assert {:error, %RunLedger.PersistenceError{phase: :decode}} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    assert {:error, %RunLedger.PersistenceError{phase: :decode}} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
    assert evidence(c) == before
  end

  for {field, value, error} <- [
        {"run_id", nil, :invalid_run_identity},
        {"run_id", "partial", :invalid_run_identity},
        {"run_identity_event_id", nil, :invalid_run_identity},
        {"run_identity_ledger_path", nil, :invalid_run_identity},
        {"run_identity_pending", nil, :run_identity_pending},
        {"audit_pending", nil, :invalid_audit_pending}
      ] do
    @tag bad_snapshot: {field, value, error}
    test "legacy rejects present #{field}=#{inspect(value)}", c do
      {field, value, error} = c.bad_snapshot
      c = control(c, &Map.put(&1, field, value))
      before = evidence(c)
      assert {:error, ^error} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
      assert {:error, ^error} = RunStateStore.update_coordinator_current(c.authority, c.expected, observation(c, :review))
      assert evidence(c) == before
    end
  end

  test "canonical snapshot missing, malformed and wrong issue never selects default or bootstrap", c do
    path = RunStateStore.state_path(c.workspace)
    File.rm!(path)
    bootstrap = Path.join(c.root, ".C5-1.bootstrap-retained")
    File.mkdir_p!(bootstrap)
    bootstrap_path = Path.join(bootstrap, "run_state.json")
    File.write!(bootstrap_path, Jason.encode!(c.raw))
    assert {:ok, _legacy_fallback} = RunStateStore.load(c.workspace)
    before = evidence(c)
    assert {:error, :missing} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    assert evidence(c) == before
    assert File.read!(bootstrap_path) == Jason.encode!(c.raw)
    File.write!(path, "{broken}")
    before = evidence(c)
    assert {:error, %Jason.DecodeError{}} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    assert evidence(c) == before
    write_raw(c, %{c.raw | "issue_identifier" => "OTHER"})
    before = evidence(c)
    assert {:error, {:coordinator_precondition_failed, :coordinator_issue_mismatch}} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    assert evidence(c) == before
  end

  for audit <- [DispatchAudit, DeployAudit] do
    @tag audit: audit
    test "#{inspect(audit)} pending evidence blocks every coordinator entry", c do
      File.mkdir_p!(c.audit.marker_directory(c.workspace))
      before = evidence(c)
      error = if c.audit == DispatchAudit, do: :dispatch_audit_pending, else: :deploy_audit_pending
      workspace = c.workspace
      assert {:error, {^error, ^workspace}} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
      assert {:error, {^error, ^workspace}} = RunStateStore.update_coordinator_current(c.authority, c.expected, observation(c, :review))
      assert {:error, {^error, ^workspace}} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
      assert evidence(c) == before
    end
  end

  test "a real live dispatch cannot lend its authorization to a coordinator", c do
    attrs = %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: c.raw["stage"], metadata: %{owner: c.authority.lease_token.owner, epoch: c.authority.lease_token.epoch}}
    assert {:ok, source, _view} = RunStateStore.read_admission_source(c.workspace, c.issue)
    assert {:ok, ticket, raw} = DispatchAudit.begin(c.workspace, attrs, source)
    binding = %{run_id: raw["run_id"], run_identity_event_id: raw["run_identity_event_id"], run_identity_ledger_path: raw["run_identity_ledger_path"]}
    authority = %{c.authority | binding: {:identified, binding}}
    expected = RunStateStore.coordinator_projection(raw)
    before = evidence(c)
    workspace = c.workspace
    assert {:error, {:dispatch_audit_pending, ^workspace}} = DispatchAudit.with_authorization(ticket, fn -> RunStateStore.ensure_coordinator_current(authority, expected) end)
    assert evidence(c) == before
    assert :ok = DispatchAudit.finish(ticket, :normal)
    assert {:ok, _} = RunStateStore.ensure_coordinator_current(authority, expected)
  end

  test "malformed authority and unlimited deadline are rejected without writes", c do
    before = evidence(c)

    for authority <- [Map.delete(c.authority, :binding), Map.put(c.authority, :ticket, %{}), %{c.authority | deadline: :not_pending}, %{c.authority | issue_identifier: ""}] do
      assert {:error, {:coordinator_precondition_failed, :invalid_coordinator_authority}} = RunStateStore.ensure_coordinator_current(authority, c.expected)
    end

    assert {:error, {:coordinator_precondition_failed, :invalid_coordinator_workspace}} = RunStateStore.ensure_coordinator_current(%{c.authority | workspace: "relative"}, c.expected)
    assert evidence(c) == before
  end

  test "every captured material input rejects a concurrent control without changing bytes", c do
    changes = [
      {"stage", "human_review"},
      {"last_ledger_event_id", "other"},
      {"review_claims", %{"R" => "changed"}},
      {"review_threads", %{"T" => "changed"}},
      {"pr_url", "https://github.com/example/c5/pull/2"},
      {"repo_url", "other"},
      {"policy_pack", "other"},
      {"effective_policy_class", "manual"},
      {"stop_reason", nil},
      {"implementation_turns", 3},
      {"policy_override", "manual"},
      {"review_return_stage", "validate"},
      {"resume_context", %{"budget_pressure" => "critical"}},
      {"last_ci_failure", %{"summary" => "new"}},
      {"issue_source", nil},
      {"runner_channel", "canary"},
      {"runner_instance_id", "other"},
      {"last_review_decision", "APPROVED"},
      {"next_human_action", "hold"}
    ]

    for {field, value} <- changes do
      write_raw(c, Map.put(c.raw, field, value))
      before = evidence(c)
      assert {:error, {:coordinator_precondition_failed, :coordinator_material_changed}} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
      assert {:error, {:coordinator_precondition_failed, :coordinator_material_changed}} = RunStateStore.update_coordinator_current(c.authority, c.expected, observation(c, :review))
      assert {:error, {:coordinator_precondition_failed, :coordinator_material_changed}} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
      assert evidence(c) == before
    end
  end

  test "accepted usage and physical renewal stay fresh across the CAS", c do
    assert {:ok, _} = RunStateStore.update(c.workspace, & &1)
    normalized = raw!(c)
    c = %{c | raw: normalized, expected: RunStateStore.coordinator_projection(normalized)}
    usage = %{input_tokens: 120, output_tokens: 80, total_tokens: 200}
    assert {:ok, _} = RunStateStore.record_token_usage(c.workspace, c.issue, usage)
    assert RunStateStore.coordinator_projection(raw!(c)) == c.expected
    assert {:ok, renewal} = LeaseManager.refresh_token(c.authority.lease_token)
    assert {:ok, persisted} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
    assert persisted.token_usage == usage
    assert persisted.lease_updated_at == renewal["updated_at"]
    assert persisted.lease_generation == c.authority.lease_token.lease_generation
    assert json(persisted.resume_context)["budget_pressure"] == "high"
    assert json(persisted) == raw!(c)
  end

  test "capture A rejects a physical same-owner same-epoch successor B without touching B", c do
    captured = c.authority.lease_token
    assert {:ok, :released} = LeaseManager.release_token(captured)
    assert {:ok, successor} = LeaseManager.acquire(c.issue.id, c.issue.identifier, captured.owner)
    assert successor.token.owner == captured.owner
    assert successor.token.epoch == captured.epoch
    refute successor.token.lease_generation == captured.lease_generation
    before = evidence(c)
    assert {:error, {:coordinator_precondition_failed, :lease_token_mismatch}} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    assert {:error, {:coordinator_precondition_failed, :lease_token_mismatch}} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
    assert evidence(c) == before
    assert {:ok, physical} = LeaseManager.read_at(successor.token.storage)
    assert physical == successor.lease
  end

  test "changed ledger root and captured path are rejected without recapture", c do
    previous = Application.fetch_env!(:symphony_elixir, :log_file)
    on_exit(fn -> Application.put_env(:symphony_elixir, :log_file, previous) end)
    Application.put_env(:symphony_elixir, :log_file, Path.join(c.root, "new-root/runtime.log"))
    before = evidence(c)
    assert {:error, {:coordinator_precondition_failed, :coordinator_lease_location_changed}} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
    assert evidence(c) == before
    Application.put_env(:symphony_elixir, :log_file, previous)
    bad = put_in(c.authority, [:lease_token, :storage, :lease_path], Path.join(c.root, "forged.json"))
    assert {:error, {:coordinator_precondition_failed, :invalid_lease_storage}} = RunStateStore.ensure_coordinator_current(bad, c.expected)
    assert evidence(c) == before
  end

  test "four closed shapes reject extras, mixed forms and whole snapshots without side effects", c do
    cases = [{:update, observation(c, :review)}, {:update, observation(c, :ci)}, {{:transition, "implement"}, transition(c, :ci)}, {{:transition, "review_verification"}, transition(c, :review)}]
    before = evidence(c)

    for {operation, attrs} <- cases do
      for {field, value} <- [
            issue_id: c.issue.id,
            issue_identifier: c.issue.identifier,
            stage: "done",
            run_id: "new",
            last_ledger_event_id: "new",
            token_usage: %{},
            lease_token: c.authority.lease_token,
            audit_pending: nil,
            stage_history: [],
            policy_override: nil,
            implementation_turns: 0
          ] do
        assert {:error, :invalid_coordinator_attrs} = mutate(c, operation, Map.put(attrs, field, value))
        assert evidence(c) == before
      end

      assert {:error, :invalid_coordinator_attrs} = mutate(c, operation, Map.delete(attrs, :resume_context))
      assert {:error, :invalid_coordinator_attrs} = mutate(c, operation, json(attrs))
      assert {:error, :invalid_coordinator_attrs} = mutate(c, operation, c.raw)
      assert evidence(c) == before
    end

    assert {:error, :invalid_coordinator_attrs} = RunStateStore.update_coordinator_current(c.authority, c.expected, Map.merge(observation(c, :review), observation(c, :ci)))
    assert {:error, :invalid_coordinator_attrs} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "review_verification", transition(c, :ci))
    assert {:error, :invalid_coordinator_stage} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "done", transition(c, :ci))
    assert evidence(c) == before
  end

  test "stop cleanup only accepts nil in transitions and cannot enter observations", c do
    before = evidence(c)

    for field <- [:stop_reason, :last_decision, :last_rule_id, :last_failure_class, :next_human_action] do
      assert {:error, :invalid_coordinator_attrs} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", Map.put(transition(c, :ci), field, "forged"))

      if field != :next_human_action do
        assert {:error, :invalid_coordinator_attrs} = RunStateStore.update_coordinator_current(c.authority, c.expected, Map.put(observation(c, :review), field, nil))
      end
    end

    assert evidence(c) == before
  end

  test "source, PR, return stage, CI shape and protected resume context cannot be replaced", c do
    bad = [
      Map.put(transition(c, :review), :issue_source, "tracker"),
      Map.put(transition(c, :review), :issue_source, "unsupported"),
      Map.put(transition(c, :review), :pr_url, "foreign"),
      Map.put(transition(c, :review), :review_return_stage, "future"),
      Map.put(transition(c, :ci), :await_checks_polls, 1),
      put_in(transition(c, :ci), [:last_ci_failure, :unexpected], "extra"),
      update_in(transition(c, :ci), [:last_ci_failure], &Map.delete(&1, :summary)),
      put_in(transition(c, :ci), [:resume_context, "budget_pressure"], "low"),
      update_in(transition(c, :ci), [:resume_context], &Map.delete(&1, "turn_count")),
      put_in(transition(c, :ci), [:resume_context, :next_objective], ""),
      put_in(transition(c, :ci), [:resume_context, :ci_failure_pr_url], "foreign"),
      Map.put(transition(c, :review), :review_threads, nil),
      Map.put(transition(c, :review), :review_claims, %{invalid: self()})
    ]

    before = evidence(c)

    for attrs <- bad do
      assert {:error, :invalid_coordinator_attrs} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", attrs)
      assert evidence(c) == before
    end
  end

  test "two simultaneous checked transitions consume only one expected projection", c do
    parent = self()

    workers =
      for destination <- ["implement", "review_verification"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> RunStateStore.transition_coordinator_current(c.authority, c.expected, destination, transition(c, :review))
          after
            5_000 -> raise "coordinator writer was not released"
          end
        end)
      end

    for worker <- workers do
      pid = worker.pid
      assert_receive {:ready, ^pid}, 5_000
    end

    for worker <- workers, do: send(worker.pid, :go)
    results = Enum.map(workers, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, {:coordinator_precondition_failed, :coordinator_material_changed}})) == 1
    assert Enum.map(rows(c), & &1["event_type"]) == ["stage.transition.requested", "stage.transition"]
  end

  for boundary <- [:ensure, :update, :transition] do
    @tag boundary: boundary
    test "#{boundary} expires while waiting for the workspace lock without starting a writer", c do
      parent = self()

      holder =
        Task.async(fn ->
          RunStateStore.with_workspace_lock(c.workspace, fn ->
            send(parent, :workspace_held)

            receive do
              :release -> :ok
            after
              5_000 -> raise "workspace fixture lock not released"
            end
          end)
        end)

      assert_receive :workspace_held, 5_000
      c = short_deadline(c)
      before = evidence(c)
      worker = Task.async(fn -> invoke(c, c.boundary) end)
      expire(c)
      send(holder.pid, :release)
      assert :ok = Task.await(holder, 5_000)
      assert {:error, {:coordinator_precondition_failed, :coordinator_deadline_expired}} = Task.await(worker, 5_000)
      assert evidence(c) == before
    end
  end

  for boundary <- [:ensure, :update, :transition] do
    @tag boundary: boundary
    test "#{boundary} rechecks deadline after physical lease blocking and retains workspace exclusion", c do
      lock_path = c.authority.lease_token.storage.lease_path <> ".lock"
      File.mkdir!(lock_path)
      c = short_deadline(c)
      parent = self()

      worker =
        Task.async(fn ->
          receive do
            :go -> invoke(c, c.boundary)
          after
            5_000 -> raise "physical lease boundary not started"
          end
        end)

      worker_pid = worker.pid
      pattern = {File, :mkdir, 1}
      assert :erlang.trace_pattern(pattern, [{[lock_path], [], []}], [:local]) == 1
      :erlang.trace(worker_pid, true, [:call, {:tracer, self()}])
      before = evidence(c)

      try do
        send(worker_pid, :go)
        assert_receive {:trace, ^worker_pid, :call, {File, :mkdir, [^lock_path]}}, 500

        competitor =
          Task.async(fn ->
            send(parent, :competitor_entering)
            RunStateStore.with_workspace_lock(c.workspace, fn -> send(parent, :competitor_entered) end)
          end)

        assert_receive :competitor_entering, 100
        refute_receive :competitor_entered, 50
        expire(c)
        File.rmdir!(lock_path)
        assert {:error, {:coordinator_precondition_failed, :coordinator_deadline_expired}} = Task.await(worker, 5_000)
        assert :competitor_entered = Task.await(competitor, 5_000)
        assert_receive :competitor_entered, 5_000
        assert evidence(c) == before
      after
        if Process.alive?(worker_pid), do: :erlang.trace(worker_pid, false, [:call])
        :erlang.trace_pattern(pattern, false, [:local])
        if File.dir?(lock_path), do: File.rmdir!(lock_path)
      end
    end
  end

  for failure <- [false, true] do
    @tag failure: failure
    test "deadline after the first confirmed intent preserves #{if failure, do: "the real error", else: "the completed result"}", c do
      handler = "coordinator-intent-#{System.unique_integer([:positive])}"
      assert :ok = :telemetry.attach(handler, [:symphony, :ledger, :event], &__MODULE__.hold_intent/4, {self(), c.issue.id})
      on_exit(fn -> :telemetry.detach(handler) end)
      c = %{c | authority: %{c.authority | deadline: System.monotonic_time(:millisecond) + 2_000}}
      worker = Task.async(fn -> RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci)) end)
      assert_receive {:intent_confirmed, writer}, 5_000
      assert Enum.map(rows(c), & &1["event_type"]) == ["stage.transition.requested"]
      assert raw!(c) == c.raw

      if c.failure do
        File.rename!(RunStateStore.state_path(c.workspace), Path.join(c.root, "preserved-before.json"))
        File.mkdir!(RunStateStore.state_path(c.workspace))
      end

      expire(c)
      send(writer, :continue)
      result = Task.await(worker, 5_000)

      if c.failure do
        assert result == {:error, :eisdir}
        assert Enum.map(rows(c), & &1["event_type"]) == ["stage.transition.requested"]
        assert File.read!(Path.join(c.root, "preserved-before.json")) == Jason.encode!(c.raw)
      else
        assert {:ok, state} = result
        assert state.stage == "implement"
        assert json(state) == raw!(c)
        assert Enum.map(rows(c), & &1["event_type"]) == ["stage.transition.requested", "stage.transition"]
        assert {:error, {:coordinator_precondition_failed, :coordinator_deadline_expired}} = RunStateStore.ensure_coordinator_current(c.authority, RunStateStore.coordinator_projection(state))
      end
    end
  end

  test "review transition preserves a genuinely absent previous stage as nil return stage", c do
    c = control(c, &Map.delete(&1, "stage"))
    assert {:ok, state} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "review_verification", transition(c, :review))
    assert state.review_return_stage == nil
    assert state.stage == "review_verification"
    assert List.last(rows(c))["metadata"]["previous_stage"] == nil
  end

  test "checked ledger failure preserves snapshot and original persistence error", c do
    File.write!(c.authority.lease_token.storage.ledger_path, "{broken}\n")
    before = evidence(c)
    assert {:error, %RunLedger.PersistenceError{}} = RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
    assert evidence(c) == before
  end

  for operation <- [:update, :same_stage], failure <- [:cleanup_denied, :temporary_absent, :rename] do
    @tag operation: operation, failure: failure
    test "#{operation} snapshot failure #{failure} preserves the primary error and reports failed cleanup", c do
      c = if c.operation == :same_stage, do: control(c, &Map.put(&1, "stage", "implement")), else: c
      before = evidence(c)
      path = RunStateStore.state_path(c.workspace)
      directory = Path.dirname(path)
      preserved = Path.join(c.root, "snapshot-before-cleanup.json")
      {:ok, %{mode: original_mode}} = File.stat(directory)
      lock_path = c.authority.lease_token.storage.lease_path <> ".lock"
      File.mkdir!(lock_path)

      worker =
        Task.async(fn ->
          receive do
            :go ->
              if c.operation == :update,
                do: RunStateStore.update_coordinator_current(c.authority, c.expected, observation(c, :review)),
                else: RunStateStore.transition_coordinator_current(c.authority, c.expected, "implement", transition(c, :ci))
          after
            5_000 -> raise "snapshot cleanup fixture was not started"
          end
        end)

      worker_pid = worker.pid

      patterns = [
        {{File, :mkdir, 1}, [{[lock_path], [], []}]},
        {{File, :mkdir_p, 1}, [{[directory], [], [{:return_trace}]}]},
        {{File, :write, 3}, [{:_, [], [{:return_trace}]}]},
        {{File, :rename, 2}, [{:_, [], [{:return_trace}]}]},
        {{File, :rm, 1}, [{:_, [], [{:return_trace}]}]}
      ]

      previous_patterns = Enum.map(patterns, fn {mfa, _pattern} -> {mfa, :erlang.trace_info(mfa, :match_spec)} end)

      result =
        try do
          for {mfa, pattern} <- patterns, do: assert(:erlang.trace_pattern(mfa, pattern, [:local]) == 1)
          :erlang.trace(worker_pid, true, [:call, {:tracer, self()}])
          send(worker_pid, :go)
          assert_receive {:trace, ^worker_pid, :call, {File, :mkdir, [^lock_path]}}, 500

          case c.failure do
            :cleanup_denied ->
              File.chmod!(directory, 0o000)

            :temporary_absent ->
              File.chmod!(directory, 0o500)

            :rename ->
              File.rename!(path, preserved)
              File.mkdir!(path)
          end

          File.rmdir!(lock_path)
          Task.await(worker, 5_000)
        after
          if Process.alive?(worker_pid), do: Task.shutdown(worker, :brutal_kill)
          File.chmod!(directory, original_mode)

          if File.exists?(preserved) do
            if File.dir?(path), do: File.rmdir!(path)
            File.rename!(preserved, path)
          end

          if File.dir?(lock_path), do: File.rmdir!(lock_path)
          if Process.alive?(worker_pid), do: :erlang.trace(worker_pid, false, [:call])

          for {mfa, {:match_spec, previous}} <- previous_patterns do
            :erlang.trace_pattern(mfa, previous, [:local])
          end
        end

      expected_error =
        case c.failure do
          :cleanup_denied -> {:error, {:coordinator_snapshot_cleanup_failed, :eacces, :eacces}}
          :temporary_absent -> {:error, :eacces}
          :rename -> {:error, :eisdir}
        end

      assert result == expected_error
      trace_ref = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^trace_ref}, 500
      assert_received {:trace, ^worker_pid, :return_from, {File, :mkdir_p, 1}, :ok}
      assert_received {:trace, ^worker_pid, :call, {File, :write, [temporary, _payload, [:write]]}}
      assert String.starts_with?(temporary, path <> ".tmp-")
      assert_received {:trace, ^worker_pid, :call, {File, :rm, [^temporary]}}

      case c.failure do
        :cleanup_denied ->
          assert_received {:trace, ^worker_pid, :return_from, {File, :write, 3}, {:error, :eacces}}
          assert_received {:trace, ^worker_pid, :return_from, {File, :rm, 1}, {:error, :eacces}}
          refute_received {:trace, ^worker_pid, :call, {File, :rename, _}}

        :temporary_absent ->
          assert_received {:trace, ^worker_pid, :return_from, {File, :write, 3}, {:error, :eacces}}
          assert_received {:trace, ^worker_pid, :return_from, {File, :rm, 1}, {:error, :enoent}}
          refute_received {:trace, ^worker_pid, :call, {File, :rename, _}}

        :rename ->
          assert_received {:trace, ^worker_pid, :return_from, {File, :write, 3}, :ok}
          assert_received {:trace, ^worker_pid, :call, {File, :rename, [^temporary, ^path]}}
          assert_received {:trace, ^worker_pid, :return_from, {File, :rename, 2}, {:error, :eisdir}}
          assert_received {:trace, ^worker_pid, :return_from, {File, :rm, 1}, :ok}
      end

      refute_received {:trace, ^worker_pid, :call, {File, :write, _}}
      refute_received {:trace, ^worker_pid, :call, {File, :rm, _}}
      assert evidence(c) == before
      assert Path.wildcard(path <> ".tmp-*") == []
      assert {:ok, fresh} = RunStateStore.ensure_coordinator_current(c.authority, c.expected)
      assert json(fresh) == c.raw
    end
  end

  def hold_intent(_event, _measurements, metadata, {parent, issue_id}) do
    if metadata[:event_type] == "stage.transition.requested" and metadata[:issue_id] == issue_id do
      send(parent, {:intent_confirmed, self()})

      receive do
        :continue -> :ok
      after
        5_000 -> raise "coordinator intent barrier not released"
      end
    end
  end

  defp identified(c) do
    attrs = %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: c.raw["stage"], metadata: %{owner: c.authority.lease_token.owner, epoch: c.authority.lease_token.epoch}}
    assert {:ok, source, _view} = RunStateStore.read_admission_source(c.workspace, c.issue)
    assert {:ok, ticket, _raw} = DispatchAudit.begin(c.workspace, attrs, source)
    assert :ok = DispatchAudit.finish(ticket, :normal)
    raw = raw!(c)
    binding = %{run_id: raw["run_id"], run_identity_event_id: raw["run_identity_event_id"], run_identity_ledger_path: raw["run_identity_ledger_path"]}
    %{c | raw: raw, expected: RunStateStore.coordinator_projection(raw), authority: %{c.authority | binding: {:identified, binding}}}
  end

  defp observation(c, :review) do
    %{
      review_threads: %{},
      review_claims: %{},
      last_review_decision: "CHANGES_REQUESTED",
      last_decision_summary: "Review observation",
      next_human_action: "Review evidence",
      resume_context: Map.merge(c.raw["resume_context"] || %{}, %{review_feedback_summary: "feedback", review_claim_summary: nil, review_feedback_pr_url: c.raw["pr_url"]})
    }
  end

  defp observation(c, :ci) do
    %{
      last_ci_failure: %{
        event_name: "check_run",
        action: "completed",
        check_name: "tests",
        conclusion: "failure",
        details_url: nil,
        head_sha: "abc",
        pr_url: c.raw["pr_url"],
        summary: "tests (failure)"
      },
      last_decision_summary: "CI observation",
      next_human_action: "Inspect CI",
      resume_context: Map.merge(c.raw["resume_context"] || %{}, %{ci_failure_summary: "tests (failure)", ci_failure_pr_url: c.raw["pr_url"], ci_failure_details_url: nil})
    }
  end

  defp transition(c, kind) do
    attrs =
      observation(c, kind)
      |> Map.merge(%{issue_source: c.raw["issue_source"], pr_url: c.raw["pr_url"], stop_reason: nil, last_decision: nil, last_rule_id: nil, last_failure_class: nil, next_human_action: nil})

    if kind == :ci, do: Map.put(attrs, :await_checks_polls, 0), else: Map.put(attrs, :review_return_stage, c.raw["stage"])
  end

  defp mutate(c, :update, attrs), do: RunStateStore.update_coordinator_current(c.authority, c.expected, attrs)
  defp mutate(c, {:transition, stage}, attrs), do: RunStateStore.transition_coordinator_current(c.authority, c.expected, stage, attrs)
  defp invoke(c, :ensure), do: RunStateStore.ensure_coordinator_current(c.authority, c.expected)
  defp invoke(c, :update), do: mutate(c, :update, observation(c, :review))
  defp invoke(c, :transition), do: mutate(c, {:transition, "implement"}, transition(c, :ci))
  defp short_deadline(c), do: %{c | authority: %{c.authority | deadline: System.monotonic_time(:millisecond) + 150}}

  defp expire(c) do
    Process.sleep(max(c.authority.deadline - System.monotonic_time(:millisecond) + 1, 0))
    assert System.monotonic_time(:millisecond) >= c.authority.deadline
  end

  defp control(c, fun) do
    raw = fun.(c.raw)
    write_raw(c, raw)
    %{c | raw: raw, expected: RunStateStore.coordinator_projection(raw)}
  end

  defp write_raw(c, raw), do: File.write!(RunStateStore.state_path(c.workspace), Jason.encode!(raw))
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp ledger(c), do: File.read(c.authority.lease_token.storage.ledger_path)
  defp ledger!(c), do: File.read!(c.authority.lease_token.storage.ledger_path)

  defp rows(c) do
    case ledger(c) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp evidence(c) do
    %{
      snapshot: File.read(RunStateStore.state_path(c.workspace)),
      ledger: ledger(c),
      lease: File.read(c.authority.lease_token.storage.lease_path),
      dispatch: File.lstat(DispatchAudit.marker_directory(c.workspace)),
      deploy: File.lstat(DeployAudit.marker_directory(c.workspace))
    }
  end
end
