defmodule SymphonyElixir.EvidenceIntegrityPublicationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DeliveryEngine, EvidenceAcceptance, GitManager, PullRequestManager, RepoHarness, RunInspector, RunStateStore, VerifierRunner}

  defmodule GitHub do
    def existing_pull_request(_workspace, opts) do
      send(opts[:test], :pr_lookup)
      if action = opts[:on_lookup], do: action.()
      {:error, :missing_pr}
    end

    def create_pull_request(_workspace, _branch, _base, _title, _body, opts) do
      send(opts[:test], :pr_create)
      {:ok, %{url: "https://github.com/example/repo/pull/71", state: "OPEN"}}
    end

    def edit_pull_request(_workspace, _title, _body, opts) do
      send(opts[:test], :pr_edit)
      {:ok, %{url: "https://github.com/example/repo/pull/71", state: "OPEN"}}
    end

    def persist_pr_url(_workspace, _branch, _url, opts),
      do:
        (
          send(opts[:test], :pr_reference)
          :ok
        )

    def review_feedback(_workspace, _opts), do: {:ok, %{pr_url: nil, review_decision: nil, reviews: [], comments: []}}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "evidence-publication-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "PROOF-2")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["config", "user.name", "Evidence Test"], cd: workspace)
    File.write!(Path.join(workspace, ".gitignore"), ".symphony/\n")
    File.write!(Path.join(workspace, "README.md"), "fixture\n")
    assert {_, 0} = System.cmd("git", ["add", ".gitignore", "README.md"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "fixture"], cd: workspace)
    assert {_, 0} = System.cmd("git", ["init", "--bare", Path.join(root, "origin.git")])
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", Path.join(root, "origin.git")], cd: workspace)
    assert {_, 0} = System.cmd("git", ["checkout", "-b", "symphony/proof-2"], cd: workspace)
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/feature.ex"), "defmodule Feature do\nend\n")
    File.write!(Path.join(workspace, "proof.json"), "{\"criterion\":true}\n")

    harness = %{
      version: 1,
      base_branch: "main",
      preflight: %{command: "test -s README.md"},
      post_merge: %{command: "test -s README.md"},
      artifacts: %{command: "test -s README.md"},
      pull_request: %{required_checks: ["make-all"]},
      validation: %{command: "test -s README.md"},
      smoke: %{command: "if [ -f proof.json ]; then grep -q true proof.json; else true; fi"},
      verification: %{behavioral_proof: %{required: true, mode: "harness_artifact_only", source_paths: ["lib"], test_paths: ["test"], artifact_path: "proof.json"}}
    }

    File.write!(Path.join(workspace, ".symphony/harness.yml"), Jason.encode!(harness))

    issue = %Issue{
      id: "publication-#{System.unique_integer([:positive])}",
      identifier: "PROOF-2",
      title: "Evidence publication",
      state: "In Progress",
      source: :tracker,
      description: "## Acceptance Criteria\n- fixture criterion"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      runner_install_root: Path.join(root, "runner"),
      company_policy_pack: "private_autopilot",
      policy_publish_required: true,
      codex_command: local_codex!(root)
    )

    assert {:ok, _} = RunStateStore.transition(workspace, "publish", %{issue_id: issue.id, issue_identifier: issue.identifier, issue_source: :tracker, branch: "symphony/proof-2"})
    {:ok, parsed} = RepoHarness.load(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, issue: issue, inspection: %RunInspector.Snapshot{workspace: workspace, harness: parsed}, proof: Path.join(workspace, "proof.json")}
  end

  test "resumed publish obtains real current gates before one local push and PR", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
      assert :ok = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
      assert_received :pr_create
      refute_received :pr_create
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.validation_attempts == 1
      assert state.verification_attempts == 1
      assert state.stage == "await_checks"
      assert state.last_verifier_verdict == "pass"
      assert {local_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)
      assert {remote_head, 0} = System.cmd("git", ["--git-dir", Path.join(c.root, "origin.git"), "rev-parse", "symphony/proof-2"])
      assert local_head == remote_head
    end)
  end

  test "resumed publication stops at the real failed artifacts command before verification or publication", c do
    harness_path = Path.join(c.workspace, ".symphony/harness.yml")
    harness = harness_path |> File.read!() |> Jason.decode!()
    command = "printf 'artifact check failed\n'; exit 17"
    File.write!(harness_path, Jason.encode!(Map.put(harness, "artifacts", %{"command" => command})))
    assert {:ok, %{artifacts_command: ^command}} = RepoHarness.load(c.workspace)
    before_head = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)
    before_refs = System.cmd("git", ["--git-dir", Path.join(c.root, "origin.git"), "for-each-ref", "--format=%(refname)"])
    assert {"", 0} = before_refs

    admitted(c.workspace, c.issue, fn execution ->
      opts = Keyword.put(delivery_opts(), :verifier_session_runner, fn _, _, _, _ -> flunk("failed artifacts reached verifier") end)
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
      assert {:stop, :artifacts_failed} = DeliveryEngine.run(c.workspace, c.issue, nil, opts)
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.stage == "blocked"
      assert state.stop_reason.code == "artifacts_failed"
      assert state.validation_attempts == 1
      assert state.verification_attempts == 0
      assert state.last_validation.status == "passed"
      assert {:stop, {:execution_stopped, %{stage: "blocked"}}} = EvidenceAcceptance.current(c.workspace)
      assert {:ok, rows, _digest} = SymphonyElixir.RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [event] = Enum.filter(rows, &(&1["event"] == "artifacts.completed"))
      assert event["issue_id"] == c.issue.id
      assert event["metadata"]["run_id"] == execution.ticket.run_id
      assert event["metadata"]["workspace"] == c.workspace
      assert event["metadata"]["command"] == command
      assert event["metadata"]["status"] == "failed"
      assert event["metadata"]["exit_code"] == 17
      assert event["metadata"]["attempt"] == 1
      refute Enum.any?(rows, &(&1["event"] in ["verification.completed", "proof.integrity_verified"]))
      refute_received :pr_lookup
      refute_received :pr_create
      refute_received :pr_edit
      refute_received :pr_reference
      assert System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace) == before_head
      assert System.cmd("git", ["--git-dir", Path.join(c.root, "origin.git"), "for-each-ref", "--format=%(refname)"]) == before_refs
    end)
  end

  test "missing proof blocks resumed publication without commit, push or PR", c do
    File.rm!(c.proof)
    before = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)

    admitted(c.workspace, c.issue, fn _execution ->
      assert {:stop, :behavior_proof_missing} = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.stage == "blocked"
      assert state.stop_reason.code == "behavior_proof_missing"
      refute_received :pr_create
      assert System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace) == before
    end)
  end

  test "a valid hash cannot override a failing concrete smoke criterion", c do
    File.write!(c.proof, "{\"criterion\":false}\n")

    admitted(c.workspace, c.issue, fn _execution ->
      assert {:stop, :verifier_blocked} = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.last_verifier_verdict == "needs_more_work"
      assert state.stage == "blocked"
      refute_received :pr_create
      assert {:stop, {:execution_stopped, %{stage: "blocked"}}} = EvidenceAcceptance.current(c.workspace)
    end)
  end

  test "PR lookup cannot authorize create after proof mutation", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      assert %{verdict: "pass"} = VerifierRunner.verify(c.workspace, c.issue, %{}, c.inspection, include_pr_details: false, verifier_session_runner: &verifier_pass/4)
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      opts = [evidence_handle: handle, github_client: GitHub, github_client_opts: [test: self(), on_lookup: fn -> File.write!(c.proof, "tampered\n") end]]
      assert {:error, {:evidence_rejected, :evidence_changed}} = PullRequestManager.ensure_pull_request(c.workspace, c.issue, %{branch: "main"}, opts)
      assert_received :pr_lookup
      refute_received :pr_create
      refute_received :pr_reference
    end)
  end

  test "Git status cannot hide changed evidence behind a noop", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      assert %{verdict: "pass"} = VerifierRunner.verify(c.workspace, c.issue, %{}, c.inspection, include_pr_details: false, verifier_session_runner: &verifier_pass/4)
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)

      runner = fn
        "git", ["status", "--porcelain"], _opts ->
          File.write!(c.proof, "tampered\n")
          {"", 0}

        command, args, _opts ->
          flunk("unexpected positive effect #{inspect({command, args})}")
      end

      assert {:error, {:evidence_rejected, :evidence_changed}} = GitManager.commit_all(c.workspace, c.issue, "attempt", evidence_handle: handle, command_runner: runner)
    end)
  end

  test "persisted verification budget cannot be renewed by resumed publish", c do
    assert {:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :verification_attempts, SymphonyElixir.Config.policy_max_validation_attempts_per_run()))

    admitted(c.workspace, c.issue, fn _execution ->
      assert {:stop, :verifier_blocked} = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
      refute_received :pr_lookup
      refute_received :pr_create
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.stage == "blocked"
      assert state.verification_attempts == SymphonyElixir.Config.policy_max_validation_attempts_per_run()
    end)
  end

  test "a later worker reverifies committed source before handoff without republishing", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
    end)

    assert_received :pr_create
    assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: c.workspace)
    {published, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
    issue = %{c.issue | labels: ["policy:review-required"]}

    admitted(c.workspace, issue, fn execution ->
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
      assert :ok = DeliveryEngine.run(c.workspace, issue, nil, handoff_opts())
      issue_id = issue.id
      assert_received {:memory_tracker_state_update, ^issue_id, "Human Review"}
      refute_received :pr_create
      refute_received :pr_edit
      assert {^published, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.verification_attempts == 2
      assert state.validation_attempts == 2
      assert state.pr_url == "https://github.com/example/repo/pull/71"
      assert {:ok, rows, _} = SymphonyElixir.RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [receipt] = Enum.filter(rows, &(&1["event"] == "proof.integrity_verified" and &1["metadata"]["dispatch_id"] == execution.ticket.dispatch_id))
      assert receipt["metadata"]["selection"]["required"] == true
      assert receipt["metadata"]["selection"]["paths"] == ["proof.json"]
      assert "lib/feature.ex" in receipt["metadata"]["selection"]["scope"]["paths"]
    end)
  end

  test "handoff denial keeps the already published commit and PR", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
    end)

    assert_received :pr_create
    {published, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)
    File.write!(c.proof, "{\"criterion\":false}\n")
    issue = %{c.issue | labels: ["policy:review-required"]}
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

    admitted(c.workspace, issue, fn _execution ->
      assert {:stop, :verifier_blocked} = DeliveryEngine.run(c.workspace, issue, nil, handoff_opts())
      issue_id = issue.id
      refute_received {:memory_tracker_state_update, ^issue_id, "Human Review"}
      refute_received :pr_create
      refute_received :pr_edit
      assert {^published, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.stage == "blocked"
      assert state.pr_url == "https://github.com/example/repo/pull/71"
      assert state.last_verifier_verdict == "needs_more_work"
      assert state.verification_attempts == 2
    end)
  end

  test "checked branch selection preserves docs-only proof policy", c do
    File.rm!(Path.join(c.workspace, "lib/feature.ex"))
    File.rm!(c.proof)
    File.write!(Path.join(c.workspace, "README.md"), "docs only\n")

    admitted(c.workspace, c.issue, fn execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      assert %{verdict: "pass"} = VerifierRunner.verify(c.workspace, c.issue, %{}, c.inspection, evidence_reentry: true, include_pr_details: false, verifier_session_runner: &verifier_pass/4)
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      assert :ok = EvidenceAcceptance.before_effect(c.workspace, handle, :handoff)
      assert {:ok, rows, _} = SymphonyElixir.RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [receipt] = Enum.filter(rows, &(&1["event"] == "proof.integrity_verified"))
      assert receipt["metadata"]["selection"]["required"] == false
      assert receipt["metadata"]["files"] == []
      assert receipt["metadata"]["selection"]["scope"]["paths"] == ["README.md"]
    end)
  end

  test "an unresolved base blocks reentry rather than yielding an empty selection", c do
    inspection = %{c.inspection | harness: %{c.inspection.harness | base_branch: "missing-proof-base"}}

    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, inspection.harness))

      result =
        VerifierRunner.verify(c.workspace, c.issue, %{}, inspection,
          evidence_reentry: true,
          include_pr_details: false,
          verifier_session_runner: fn _, _, _, _ -> flunk("invalid base reached verifier") end
        )

      assert result.verdict == "blocked"
      assert {:evidence_scope_command_failed, :base, status} = result.integrity_error
      assert status != 0
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
      refute_received :pr_create
    end)
  end

  test "same-path source mutation after verification is rejected before publication", c do
    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = AgentExecution.observe_validation(c.workspace, RunInspector.run_validation(c.workspace, c.inspection.harness))
      assert %{verdict: "pass"} = VerifierRunner.verify(c.workspace, c.issue, %{}, c.inspection, evidence_reentry: true, include_pr_details: false, verifier_session_runner: &verifier_pass/4)
      assert {:ok, handle} = EvidenceAcceptance.current(c.workspace)
      File.write!(Path.join(c.workspace, "lib/feature.ex"), "defmodule Changed do\nend\n")
      assert {:error, :evidence_scope_changed} = EvidenceAcceptance.before_effect(c.workspace, handle, :push)
    end)
  end

  test "an admitted adapter call cannot silently omit the current acceptance handle", c do
    before = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)

    admitted(c.workspace, c.issue, fn _execution ->
      assert {:error, {:evidence_rejected, :evidence_handle_required}} =
               GitManager.commit_all(c.workspace, c.issue, "unverified")

      assert System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace) == before
      assert {:error, :evidence_reverification_required} = EvidenceAcceptance.current(c.workspace)
    end)
  end

  for entry <- [:admitted, :legacy] do
    @validation_budget_entry entry
    test "#{entry} exhausted validation budget denies the command before execution", c do
      budget_workflow!(c, 1)
      assert {:ok, _} = RunStateStore.transition(c.workspace, "validate", %{validation_attempts: 1})
      sentinel = Path.join(c.workspace, ".symphony/forbidden-validation")
      harness = c.workspace |> Path.join(".symphony/harness.yml") |> File.read!() |> Jason.decode!()
      File.write!(Path.join(c.workspace, ".symphony/harness.yml"), Jason.encode!(put_in(harness, ["validation", "command"], "printf executed > .symphony/forbidden-validation; exit 0")))

      run = fn ledger_path ->
        assert {:stop, :validation_failed} = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
        refute File.exists?(sentinel)
        assert {:ok, state} = RunStateStore.load(c.workspace)
        assert state.validation_attempts == 1
        assert state.verification_attempts == 0
        assert state.stage == "blocked"
        assert state.stop_reason.details == "The existing validation attempt budget is exhausted."
        assert {:ok, events, _} = SymphonyElixir.RunLedger.CheckedStorage.entries_checked(ledger_path)
        refute Enum.any?(events, &(&1["event"] in ["validation.completed", "artifacts.completed", "smoke.completed", "verification.completed", "proof.integrity_verified", "publish.completed"]))
      end

      case @validation_budget_entry do
        :admitted ->
          admitted(c.workspace, c.issue, fn execution -> run.(execution.ticket.ledger_path) end)

        :legacy ->
          assert {:ok, ledger_path} = SymphonyElixir.RunLedger.ledger_file_path_checked()
          run.(ledger_path)
      end

      refute_received :pr_create
      refute_received :pr_edit
    end
  end

  test "failed terminal validation remains consumed when a later worker resumes", c do
    budget_workflow!(c, 1)
    assert {:ok, _} = RunStateStore.transition(c.workspace, "validate")
    path = Path.join(c.workspace, ".symphony/harness.yml")
    harness = Jason.decode!(File.read!(path))
    File.write!(path, Jason.encode!(put_in(harness, ["validation", "command"], "printf 'attempt\n' >> .symphony/physical-validation-attempts; exit 17")))

    shell = fn workspace, command, opts ->
      assert {:ok, reserved} = RunStateStore.load(workspace)
      assert reserved.validation_attempts == 1
      System.cmd("sh", ["-lc", command], Keyword.put(opts, :cd, workspace))
    end

    admitted(c.workspace, c.issue, fn _execution ->
      opts = delivery_opts() |> Keyword.put(:include_pr_details, false) |> Keyword.put(:shell_runner, shell)
      assert {:stop, :validation_failed} = DeliveryEngine.run(c.workspace, c.issue, nil, opts)
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.validation_attempts == 1
      assert state.stage == "blocked"
    end)

    assert {:ok, first} = RunStateStore.load(c.workspace)
    assert {:ok, _} = RunStateStore.transition(c.workspace, "validate")

    admitted(c.workspace, c.issue, fn execution ->
      assert {:stop, :validation_failed} = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.run_id == first.run_id
      assert state.validation_attempts == 1
      assert state.verification_attempts == 0
      assert state.stop_reason.details == "The existing validation attempt budget is exhausted."
      assert File.read!(Path.join(c.workspace, ".symphony/physical-validation-attempts")) == "attempt\n"
      assert {:ok, events, _} = SymphonyElixir.RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      [validation] = Enum.filter(events, &(&1["event"] == "validation.completed"))
      assert validation["metadata"]["attempt"] == 1
      assert validation["metadata"]["gate"]["exit_code"] == 17
      refute Enum.any?(events, &(&1["event"] in ["artifacts.completed", "smoke.completed", "verification.completed", "publish.completed"]))
    end)

    refute_received :pr_create
    refute_received :pr_edit
  end

  test "two successful workers consume the original budget and a third cannot renew it", c do
    assert SymphonyElixir.Config.policy_max_validation_attempts_per_run() == 2

    admitted(c.workspace, c.issue, fn _execution ->
      assert :ok = DeliveryEngine.run(c.workspace, c.issue, nil, delivery_opts())
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.validation_attempts == 1
      assert state.verification_attempts == 1
    end)

    assert_received :pr_create
    assert {:ok, initial} = RunStateStore.load(c.workspace)
    issue = %{c.issue | labels: ["policy:review-required"]}

    admitted(c.workspace, issue, fn _execution ->
      assert :ok = DeliveryEngine.run(c.workspace, issue, nil, handoff_opts())
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.run_id == initial.run_id
      assert state.validation_attempts == 2
      assert state.verification_attempts == 2
    end)

    assert {published, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)

    admitted(c.workspace, issue, fn execution ->
      assert {:stop, :verifier_blocked} = DeliveryEngine.run(c.workspace, issue, nil, handoff_opts())
      assert {:ok, state} = RunStateStore.load(c.workspace)
      assert state.run_id == initial.run_id
      assert state.validation_attempts == 2
      assert state.verification_attempts == 2
      assert state.stage == "blocked"
      assert state.pr_url == initial.pr_url
      assert {^published, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: c.workspace)
      assert {:ok, events, _} = SymphonyElixir.RunLedger.CheckedStorage.entries_checked(execution.ticket.ledger_path)
      assert Enum.count(events, &(&1["event"] == "verification.completed")) == 2

      refute Enum.any?(
               events,
               &(&1["event"] in ["validation.completed", "artifacts.completed", "smoke.completed", "verification.completed", "publish.completed"] and
                   &1["metadata"]["dispatch_id"] == execution.ticket.dispatch_id)
             )
    end)

    refute_received :pr_create
    refute_received :pr_edit
  end

  defp budget_workflow!(c, limit) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: c.root,
      runner_install_root: Path.join(c.root, "runner"),
      company_policy_pack: "private_autopilot",
      policy_publish_required: true,
      policy_retry_validation_failures_within_run: false,
      policy_max_validation_attempts_per_run: limit,
      codex_command: local_codex!(c.root)
    )
  end

  defp handoff_opts do
    Keyword.put(delivery_opts(), :command_runner, fn
      "gh", ["pr", "view" | _], _ ->
        {Jason.encode!(%{
           "url" => "https://github.com/example/repo/pull/71",
           "state" => "OPEN",
           "reviewDecision" => "APPROVED",
           "statusCheckRollup" => [%{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
         }), 0}

      command, args, opts ->
        System.cmd(command, args, opts)
    end)
  end

  defp delivery_opts do
    [
      github_client: GitHub,
      github_client_opts: [test: self()],
      verifier_session_runner: &verifier_pass/4,
      command_runner: fn
        "gh", ["pr", "view" | _], _ ->
          {Jason.encode!(%{
             "url" => "https://github.com/example/repo/pull/71",
             "state" => "OPEN",
             "reviewDecision" => "CHANGES_REQUESTED",
             "statusCheckRollup" => [%{"name" => "make-all", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
           }), 0}

        command, args, opts ->
          System.cmd(command, args, opts)
      end
    ]
  end

  # Genuine lease/admission/AE and checked storage; the fixture owner models
  # the worker RPC protocol. It does not claim Orchestrator scheduling or DOWN.
  defmodule Owner do
    use GenServer
    alias SymphonyElixir.{AgentExecution, RunStateStore}

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      context = %{ticket: opts.ticket, lease_token: opts.token, owner: self(), worker: opts.worker, issue_id: opts.issue.id}

      {:ok,
       %{
         context: context,
         authority: %{ticket: opts.ticket, lease_token: opts.token},
         issue: opts.issue,
         expected: RunStateStore.material_projection(opts.raw),
         registry: AgentExecution.new_registry(),
         known: nil,
         terminal: nil,
         calls: [],
         before_advance: nil
       }}
    end

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}
    def handle_call({:before_advance, fun}, _from, state), do: {:reply, :ok, %{state | before_advance: fun}}

    def handle_call({:agent_execution, invocation, expected, action}, {pid, _}, state) do
      true = pid == state.context.worker
      :ok = authenticate(state, invocation)
      state = %{state | calls: state.calls ++ [{expected, action}]}
      {reply, state} = perform(state, expected, action)
      {:reply, reply, state}
    end

    defp perform(%{terminal: terminal} = state, _, _) when not is_nil(terminal), do: {{:stop, terminal}, state}
    defp perform(state, expected, _) when expected != state.expected, do: terminal(state, {:stale_execution, :owner_expected_changed})

    defp perform(state, _, {kind, previous, next}) when kind in [:advance_current, :confirm_own_terminal] do
      true = previous == state.expected
      if state.before_advance, do: state.before_advance.()
      state = %{state | before_advance: nil}

      result =
        if kind == :confirm_own_terminal,
          do: RunStateStore.confirm_terminal_current(state.authority, next),
          else: RunStateStore.ensure_current(state.authority, next)

      case result do
        :ok -> {{:ok, :terminal_confirmed}, %{state | expected: next, known: next}}
        {:ok, _current} -> {:ok, %{state | expected: next}}
        {:error, reason} -> terminal(state, reason)
      end
    end

    defp perform(%{known: %{"stage" => "blocked"} = next} = state, _, :confirm_stop_notification) do
      case RunStateStore.confirm_terminal_current(state.authority, next) do
        :ok -> {:ok, state}
        {:error, reason} -> terminal(state, reason)
      end
    end

    defp perform(%{known: %{"stage" => stage}} = state, _, _),
      do: {{:stop, {:execution_stopped, %{stage: stage}}}, state}

    defp perform(state, _, action) do
      with {:ok, _current} <- RunStateStore.ensure_current(state.authority, state.expected),
           {:ok, registry} <- registry_action(state.registry, action) do
        {:ok, %{state | registry: registry}}
      else
        {:error, reason} -> terminal(state, reason)
      end
    end

    defp registry_action(registry, {:register, binding, purpose}), do: AgentExecution.register_binding(registry, binding, purpose)
    defp registry_action(registry, {:begin, binding, ordinal}), do: AgentExecution.begin_binding(registry, binding, ordinal)

    defp registry_action(registry, {:retire, binding, ordinal}) when ordinal == registry.ordinal,
      do: AgentExecution.retire_binding(registry, binding)

    defp registry_action(registry, {:confirm, binding, ordinal}) when binding == registry.current and ordinal == registry.ordinal,
      do: {:ok, registry}

    @impl true
    def handle_info({:agent_execution_usage, invocation, expected, observation}, state) do
      :ok = authenticate(state, invocation)
      true = expected == state.expected
      {:ok, registry, _delta} = AgentExecution.apply_usage(state.registry, invocation.binding, invocation.ordinal, observation)

      case RunStateStore.record_token_usage_current(state.context.ticket.workspace, state.issue, AgentExecution.total_usage(registry), state.authority, expected) do
        {:ok, _current} ->
          {:noreply, %{state | registry: registry}}

        {:error, reason} ->
          {_reply, next} = terminal(state, reason)
          {:noreply, next}
      end
    end

    def handle_info({:agent_worker_update, invocation, expected, _update}, state) do
      :ok = authenticate(state, invocation)
      true = expected == state.expected

      case RunStateStore.ensure_current(state.authority, expected) do
        {:ok, _current} ->
          {:noreply, state}

        {:error, reason} ->
          {_reply, next} = terminal(state, reason)
          {:noreply, next}
      end
    end

    def handle_info({:agent_execution_stale, context, ids, cause}, state) do
      true = context == state.context
      true = ids == ids(state)
      {_reply, next} = terminal(state, {:stale_execution, cause})
      {:noreply, next}
    end

    def handle_info({:agent_execution_uncertain, context, cause}, state) do
      true = context == state.context
      {_reply, next} = terminal(state, cause)
      {:noreply, next}
    end

    defp authenticate(state, %{context: context, binding: binding, ordinal: ordinal}) do
      true = context == state.context
      true = binding == state.registry.current and ordinal == state.registry.ordinal
      :ok
    end

    defp terminal(%{terminal: cause} = state, _) when not is_nil(cause), do: {{:stop, cause}, state}

    defp terminal(state, {:stale_execution, cause}) do
      terminal = {:stale_execution, ids(state), cause}
      {{:stop, terminal}, %{state | terminal: terminal}}
    end

    defp terminal(state, cause) do
      terminal = {:accounting_uncertain, cause}
      {{:stop, terminal}, %{state | terminal: terminal}}
    end

    defp ids(state), do: %{run_id: state.context.ticket.run_id, dispatch_id: state.context.ticket.dispatch_id}
  end

  defp admitted(workspace, issue, fun) do
    alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunStateStore}
    assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "evidence-owner-#{System.unique_integer([:positive])}")
    assert {:ok, _} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(acquired.lease))
    assert {:ok, source, view} = RunStateStore.read_admission_source(workspace, issue)

    assert {:ok, ticket, raw} =
             DispatchAudit.begin(workspace, %{issue_id: issue.id, issue_identifier: issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}}, source)

    assert {:ok, owner} = Owner.start_link(%{ticket: ticket, token: acquired.token, raw: raw, issue: issue, worker: self()})

    try do
      DispatchAudit.with_authorization(ticket, fn ->
        AgentExecution.with_context(ticket, acquired.token, owner, raw, fn -> fun.(%{ticket: ticket, token: acquired.token, owner: owner, raw: raw}) end)
      end)
    after
      if Process.alive?(owner), do: GenServer.stop(owner)
      assert :ok = DispatchAudit.finish(ticket, :normal)
      assert {:ok, release} = LeaseManager.release_token(acquired.token)
      assert release in [:released, :missing]
    end
  end

  defp verifier_pass(_workspace, _issue, _state, _opts) do
    {:ok, %SymphonyElixir.VerifierResult{verdict: :pass, summary: "Fixture criterion passed", acceptance_gaps: [], risky_areas: [], evidence: ["Runtime fixture"], raw_output: "pass"}}
  end

  defp local_codex!(root) do
    binary = Path.join(root, "fake-codex")

    File.write!(binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-phase3"}}}'
          ;;
        *)
          case "$line" in
            *'"method":"turn/start"'*)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-phase3"}}}'
              printf '%s\\n' '{"id":99,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"Follow-up implementation","files_touched":[],"needs_another_turn":false,"blocked":false,"blocker_type":"none"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
              ;;
          esac
          ;;
      esac
    done
    """)

    File.chmod!(binary, 0o755)
    "#{binary} app-server"
  end
end
