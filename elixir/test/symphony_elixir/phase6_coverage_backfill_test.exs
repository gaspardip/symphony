defmodule SymphonyElixir.Phase6CoverageBackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LeaseManager, PriorityEngine}

  test "RepoHarness normalizes rich configs and validates dogfood checkouts" do
    workspace = temp_workspace("repo-harness-checkout")

    try do
      assert RepoHarness.relative_path() == Path.join(".symphony", "harness.yml")
      assert RepoHarness.harness_file_path(workspace) == Path.join(workspace, ".symphony/harness.yml")

      assert :ok = RepoHarness.validate_runner_checkout(["other:label"], workspace)
      assert {:error, :missing} = RepoHarness.validate_runner_checkout([" DOGFOOD:SYMPHONY "], workspace)

      write_harness_yaml!(workspace, ["ci / publish"])

      assert :ok = RepoHarness.validate_runner_checkout(["dogfood:symphony"], workspace)

      assert {:ok, normalized} = RepoHarness.validate(rich_harness_config())
      assert normalized.version == 1
      assert normalized.base_branch == "main"
      assert normalized.preflight.description == "Prep"
      assert normalized.preflight.command == "'./scripts/preflight.sh' '--flag' 'it'\"'\"'s'"
      assert normalized.preflight.outputs == %{format: "text"}
      assert normalized.preflight.success == %{exit_code: 0}
      assert normalized.validation.command == "./scripts/validate.sh"
      assert normalized.runtime["simulator"]["device"] == "iPhone 17 Pro"
      assert normalized.runtime["targets"] == [%{"name" => "unit"}]
      assert normalized.ci.env == %{"FOO" => "bar"}
      assert normalized.ci.required_checks == ["ci / publish", "ci / validate"]
      assert normalized.pull_request.required_checks == ["ci / publish", "ci / validate"]
      assert normalized.pull_request.review_ready == %{all: [%{checkbox: "Review ready"}]}
      assert normalized.pull_request.merge_safe == %{all: [%{github_check: "ci / publish"}]}
    after
      File.rm_rf(workspace)
    end
  end

  test "RepoHarness load returns missing or parse errors" do
    workspace = temp_workspace("repo-harness-load")

    try do
      assert {:error, :missing} = RepoHarness.load(workspace)

      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.write!(RepoHarness.harness_file_path(workspace), ":\n")

      assert match?({:error, _reason}, RepoHarness.load(workspace))

      File.write!(RepoHarness.harness_file_path(workspace), "- preflight\n- validation\n")

      assert {:error, :invalid_harness_root} = RepoHarness.load(workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "RepoHarness rejects invalid versions, branches, and stage shapes" do
    base = base_harness_config()

    assert {:error, :invalid_harness_root} = RepoHarness.validate(:bad)
    assert {:error, {:invalid_harness_version, "2"}} = RepoHarness.validate(Map.put(base, "version", "2"))
    assert {:error, {:invalid_harness_version, 2}} = RepoHarness.validate(Map.put(base, "version", 2))
    assert {:error, {:invalid_harness_value, ["base_branch"]}} = RepoHarness.validate(Map.delete(base, "base_branch"))
    assert {:error, {:invalid_harness_value, ["base_branch"]}} = RepoHarness.validate(Map.put(base, "base_branch", "   "))
    assert {:error, {:invalid_harness_value, ["base_branch"], 7}} = RepoHarness.validate(Map.put(base, "base_branch", 7))
    assert {:error, {:invalid_harness_section, ["preflight"]}} = RepoHarness.validate(Map.put(base, "preflight", "bad"))
    assert {:error, {:missing_harness_command, "validation"}} = RepoHarness.validate(put_in(base, ["validation", "command"], []))
    assert {:error, {:invalid_harness_section, ["validation", "outputs"]}} = RepoHarness.validate(put_in(base, ["validation", "outputs"], "text"))
    assert {:error, {:invalid_harness_section, ["smoke", "success"]}} = RepoHarness.validate(put_in(base, ["smoke", "success"], "bad"))

    assert {:error, {:invalid_harness_value, ["artifacts", "success"], "NaN"}} =
             RepoHarness.validate(put_in(base, ["artifacts", "success"], %{"exit_code" => "NaN"}))
  end

  test "RepoHarness rejects invalid nested sections and rule definitions" do
    base = base_harness_config()

    assert {:error, {:invalid_harness_section, ["project"]}} = RepoHarness.validate(Map.put(base, "project", "ios"))
    assert {:error, {:invalid_harness_section, ["runtime"]}} = RepoHarness.validate(Map.put(base, "runtime", "runtime"))
    assert {:error, {:invalid_harness_section, ["ci"]}} = RepoHarness.validate(Map.put(base, "ci", "gha"))
    assert {:error, {:invalid_harness_section, ["pull_request"]}} = RepoHarness.validate(Map.delete(base, "pull_request"))

    assert {:error, {:invalid_harness_section, ["ci", "env"]}} =
             RepoHarness.validate(Map.put(base, "ci", %{"env" => "oops"}))

    assert {:error, {:invalid_harness_value, ["ci", "env", "FOO"], ""}} =
             RepoHarness.validate(Map.put(base, "ci", %{"env" => %{"FOO" => ""}}))

    assert {:error, {:unknown_harness_keys, ["validation"], ["mystery"]}} =
             RepoHarness.validate(put_in(base, ["validation", "mystery"], true))

    assert {:error, {:invalid_harness_section, ["pull_request", "review_ready"]}} =
             RepoHarness.validate(put_in(base, ["pull_request", "review_ready"], "yes"))

    assert {:error, {:invalid_harness_section, ["pull_request", "review_ready", "all"]}} =
             RepoHarness.validate(put_in(base, ["pull_request", "review_ready"], %{"all" => "yes"}))

    assert {:error, {:invalid_harness_section, ["pull_request", "review_ready", "all", "0"]}} =
             RepoHarness.validate(put_in(base, ["pull_request", "review_ready"], %{"all" => ["bad"]}))

    assert {:error, {:unknown_harness_keys, ["pull_request", "review_ready", "all", "0"], ["mystery"]}} =
             RepoHarness.validate(put_in(base, ["pull_request", "review_ready"], %{"all" => [%{"mystery" => "x"}]}))

    assert {:error, {:invalid_harness_value, ["pull_request", "review_ready", "all", "0"]}} =
             RepoHarness.validate(put_in(base, ["pull_request", "review_ready"], %{"all" => [%{}]}))
  end

  test "RepoHarness rejects invalid optional string fields in strict sections" do
    base = base_harness_config()

    assert {:error, {:invalid_harness_value, ["ci", "provider"], 7}} =
             RepoHarness.validate(Map.put(base, "ci", %{"provider" => 7}))

    assert {:error, {:invalid_harness_value, ["validation", "outputs"], 9}} =
             RepoHarness.validate(put_in(base, ["validation", "outputs"], %{"format" => 9}))
  end

  test "RepoHarness accepts empty success maps and rejects invalid exit codes or blank commands" do
    base = base_harness_config()

    assert {:ok, normalized} = RepoHarness.validate(put_in(base, ["validation", "success"], %{}))
    assert normalized.validation.success == %{exit_code: nil}

    assert {:error, {:invalid_harness_value, ["validation", "success"], %{}}} =
             RepoHarness.validate(put_in(base, ["validation", "success"], %{"exit_code" => %{}}))

    assert {:error, {:missing_harness_command, "validation"}} =
             RepoHarness.validate(put_in(base, ["validation", "command"], "   "))
  end

  test "RunInspector inspects git workspaces with gh metadata" do
    workspace = temp_workspace("run-inspector-gh")
    write_harness_yaml!(workspace, ["ci / publish"])

    File.mkdir_p!(Path.join(workspace, ".git"))

    command_runner = fn
      "git", ["config", "--get", "remote.origin.url"], _opts ->
        {" git@github.com:example/repo.git \n", 0}

      "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts ->
        {" feature/coverage \n", 0}

      "git", ["rev-parse", "HEAD"], _opts ->
        {" deadbeef \n", 0}

      "git", ["status", "--porcelain"], _opts ->
        {" M lib/a.ex\n?? test/new_test.exs\n", 0}

      "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts ->
        {Jason.encode!(%{
           "url" => " https://example.test/pr/1 ",
           "state" => " OPEN ",
           "reviewDecision" => " APPROVED ",
           "statusCheckRollup" => [
             %{"name" => "ci / publish", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
           ]
         }), 0}
    end

    try do
      snapshot = RunInspector.inspect(workspace, command_runner: command_runner)

      assert snapshot.checkout?
      assert snapshot.git?
      assert snapshot.origin_url == "git@github.com:example/repo.git"
      assert snapshot.branch == "feature/coverage"
      assert snapshot.head_sha == "deadbeef"
      assert snapshot.pr_url == "https://example.test/pr/1"
      assert snapshot.pr_state == "OPEN"
      assert snapshot.review_decision == "APPROVED"
      assert snapshot.required_checks_state == :passed
      assert snapshot.changed_files == 2
      assert snapshot.dirty?
      assert snapshot.harness.publish_required_checks == ["ci / publish"]
      assert snapshot.harness_error == nil
    after
      File.rm_rf(workspace)
    end
  end

  test "RunInspector falls back to git config PR URLs and handles absent workspaces" do
    workspace = temp_workspace("run-inspector-fallback")
    write_harness_yaml!(workspace, ["ci / publish"])
    File.mkdir_p!(Path.join(workspace, ".git"))

    command_runner = fn
      "git", ["config", "--get", "remote.origin.url"], _opts -> {"", 1}
      "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts -> {"feature/fallback\n", 0}
      "git", ["rev-parse", "HEAD"], _opts -> {"abc123\n", 0}
      "git", ["status", "--porcelain"], _opts -> {"", 0}
      "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts -> {"nope", 1}
    end

    shell_runner = fn
      _workspace, "git config --get branch.$(git rev-parse --abbrev-ref HEAD).symphony-pr-url", _opts ->
        {" https://example.test/pr/fallback \n", 0}
    end

    try do
      snapshot = RunInspector.inspect(workspace, command_runner: command_runner, shell_runner: shell_runner)

      assert snapshot.pr_url == "https://example.test/pr/fallback"
      assert snapshot.pr_state == nil
      assert snapshot.review_decision == nil
      assert snapshot.required_checks_state == :missing
      refute snapshot.dirty?
      assert snapshot.changed_files == 0

      missing_snapshot = RunInspector.inspect(Path.join(workspace, "missing"))

      refute missing_snapshot.checkout?
      refute missing_snapshot.git?
      assert missing_snapshot.harness == nil
      assert missing_snapshot.harness_error == :missing
      assert missing_snapshot.required_checks_state == :passed
      assert missing_snapshot.changed_files == 0
    after
      File.rm_rf(workspace)
    end
  end

  test "RunInspector normalizes malformed GitHub check rollups" do
    workspace = temp_workspace("run-inspector-malformed-rollup")
    write_harness_yaml!(workspace, ["ci / publish"])
    File.mkdir_p!(Path.join(workspace, ".git"))

    base_git_runner = fn
      "git", ["config", "--get", "remote.origin.url"], _opts -> {"git@github.com:example/repo.git\n", 0}
      "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts -> {"main\n", 0}
      "git", ["rev-parse", "HEAD"], _opts -> {"abc123\n", 0}
      "git", ["status", "--porcelain"], _opts -> {"", 0}
    end

    non_list_runner = fn
      "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts ->
        {Jason.encode!(%{
           "url" => "https://example.test/pr/2",
           "state" => "OPEN",
           "reviewDecision" => "APPROVED",
           "statusCheckRollup" => "unexpected"
         }), 0}

      command, args, opts ->
        base_git_runner.(command, args, opts)
    end

    malformed_list_runner = fn
      "gh", ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"], _opts ->
        {Jason.encode!(%{
           "url" => "https://example.test/pr/3",
           "state" => "OPEN",
           "reviewDecision" => "APPROVED",
           "statusCheckRollup" => [%{name: "ci / publish", status: "COMPLETED", conclusion: "SUCCESS"}, 42]
         }), 0}

      command, args, opts ->
        base_git_runner.(command, args, opts)
    end

    try do
      non_list_snapshot = RunInspector.inspect(workspace, command_runner: non_list_runner)
      assert non_list_snapshot.check_statuses == []
      assert non_list_snapshot.required_checks_state == :missing

      malformed_list_snapshot = RunInspector.inspect(workspace, command_runner: malformed_list_runner)

      assert malformed_list_snapshot.check_statuses == [
               %{
                 name: "ci / publish",
                 workflow_name: nil,
                 status: "COMPLETED",
                 conclusion: "SUCCESS"
               },
               %{}
             ]

      assert malformed_list_snapshot.required_checks_state == :passed
    after
      File.rm_rf(workspace)
    end
  end

  test "RunInspector public helpers cover readiness, command execution, and diff helpers" do
    assert RunInspector.required_checks_rollup(%RunInspector.Snapshot{}) == %{
             state: :passed,
             required: [],
             missing: [],
             pending: [],
             failed: [],
             cancelled: []
           }

    assert RunInspector.required_checks_passed?(%RunInspector.Snapshot{harness: nil})
    assert RunInspector.ready_for_merge?(%RunInspector.Snapshot{pr_url: "url", pr_state: nil, review_decision: nil, harness: nil})
    refute RunInspector.ready_for_merge?(%RunInspector.Snapshot{pr_url: "url", pr_state: "closed", review_decision: nil, harness: nil})

    assert RunInspector.approved_for_merge?(%RunInspector.Snapshot{review_decision: nil})
    assert RunInspector.approved_for_merge?(%RunInspector.Snapshot{review_decision: " "})
    assert RunInspector.approved_for_merge?(%RunInspector.Snapshot{review_decision: "APPROVED"})
    refute RunInspector.approved_for_merge?(%RunInspector.Snapshot{review_decision: "changes_requested"})
    refute RunInspector.approved_for_merge?(%RunInspector.Snapshot{review_decision: "review_required"})
    refute RunInspector.approved_for_merge?(%RunInspector.Snapshot{review_decision: "commented"})

    harness = %RepoHarness{
      preflight_command: "preflight",
      validation_command: "validate",
      smoke_command: "smoke",
      post_merge_command: "post-merge"
    }

    shell_runner = fn
      _workspace, "preflight", _opts -> {"ok", 0}
      _workspace, "validate", _opts -> {"bad", 1}
      _workspace, "smoke", _opts -> raise RuntimeError, "boom"
      _workspace, "post-merge", _opts -> {"post", 0}
    end

    assert RunInspector.run_preflight("/tmp", nil).status == :unavailable

    assert %RunInspector.CommandResult{status: :passed, command: "preflight", output: "ok"} =
             RunInspector.run_preflight("/tmp", harness, shell_runner: shell_runner)

    assert %RunInspector.CommandResult{status: :failed, command: "validate", output: "bad"} =
             RunInspector.run_validation("/tmp", harness, shell_runner: shell_runner)

    assert %RunInspector.CommandResult{status: :unavailable, command: "smoke", output: "boom"} =
             RunInspector.run_smoke("/tmp", harness, shell_runner: shell_runner)

    assert %RunInspector.CommandResult{status: :passed, command: "post-merge", output: "post"} =
             RunInspector.run_post_merge("/tmp", harness, shell_runner: shell_runner)

    changed_paths_runner = fn
      "git", ["status", "--porcelain"], _opts ->
        {" M lib/a.ex\nR  old/name.txt -> new/name.txt\n?? lib/a.ex\n", 0}
    end

    assert RunInspector.changed_paths("/tmp", command_runner: changed_paths_runner) == ["lib/a.ex", "new/name.txt"]
    assert RunInspector.changed_paths("/tmp", command_runner: fn _, _, _ -> {"??\n", 0} end) == []
    assert RunInspector.changed_paths("/tmp", command_runner: fn _, _, _ -> {"", 1} end) == []

    assert RunInspector.diff_summary("/tmp", command_runner: fn _, _, _ -> {" 2 files changed \n", 0} end) == "2 files changed"
    assert RunInspector.diff_summary("/tmp", command_runner: fn _, _, _ -> {" \n", 0} end) == nil
    assert RunInspector.diff_summary("/tmp", command_runner: fn _, _, _ -> {"", 1} end) == nil

    refute RunInspector.code_changed?(%RunInspector.Snapshot{fingerprint: 10}, %RunInspector.Snapshot{fingerprint: 10})
    assert RunInspector.code_changed?(%RunInspector.Snapshot{fingerprint: 10}, %RunInspector.Snapshot{fingerprint: 11})
  end

  test "RunInspector default validation and smoke wrappers return unavailable without commands" do
    assert %RunInspector.CommandResult{status: :unavailable, command: nil} =
             RunInspector.run_validation("/tmp/phase6-no-validate", %RepoHarness{})

    assert %RunInspector.CommandResult{status: :unavailable, command: nil} =
             RunInspector.run_smoke("/tmp/phase6-no-smoke", %RepoHarness{})
  end

  test "RunInspector classifies required checks across publish, cancelled, failed, and pending states" do
    snapshot = %RunInspector.Snapshot{
      harness: %RepoHarness{
        publish_required_checks: [
          "success",
          "cancelled",
          "canceled",
          "failure",
          "timed_out",
          "action_required",
          "startup_failure",
          "stale",
          "skipped",
          "neutral",
          "queued",
          "in_progress",
          "pending",
          "requested",
          "waiting",
          "expected",
          "completed",
          "unknown"
        ],
        required_checks: ["ignored"]
      },
      check_statuses: [
        %{name: "success", status: "COMPLETED", conclusion: "SUCCESS"},
        %{name: "cancelled", status: "COMPLETED", conclusion: "CANCELLED"},
        %{name: "canceled", status: "COMPLETED", conclusion: "CANCELED"},
        %{name: "failure", status: "COMPLETED", conclusion: "FAILURE"},
        %{name: "timed_out", status: "COMPLETED", conclusion: "TIMED_OUT"},
        %{name: "action_required", status: "COMPLETED", conclusion: "ACTION_REQUIRED"},
        %{name: "startup_failure", status: "COMPLETED", conclusion: "STARTUP_FAILURE"},
        %{name: "stale", status: "COMPLETED", conclusion: "STALE"},
        %{name: "skipped", status: "COMPLETED", conclusion: "SKIPPED"},
        %{name: "neutral", status: "COMPLETED", conclusion: "NEUTRAL"},
        %{name: "queued", status: "QUEUED", conclusion: nil},
        %{name: "in_progress", status: "IN_PROGRESS", conclusion: nil},
        %{name: "pending", status: "PENDING", conclusion: nil},
        %{name: "requested", status: "REQUESTED", conclusion: nil},
        %{name: "waiting", status: "WAITING", conclusion: nil},
        %{name: "expected", status: "EXPECTED", conclusion: nil},
        %{name: "completed", status: "COMPLETED", conclusion: nil},
        %{name: "unknown", status: "MYSTERY", conclusion: " "}
      ]
    }

    rollup = RunInspector.required_checks_rollup(snapshot)

    assert rollup.required == snapshot.harness.publish_required_checks
    assert "success" not in rollup.failed
    assert Enum.sort(rollup.cancelled) == ["canceled", "cancelled"]
    assert Enum.sort(rollup.pending) == ["completed", "expected", "in_progress", "pending", "queued", "requested", "unknown", "waiting"]
    assert Enum.sort(rollup.failed) == ["action_required", "failure", "neutral", "skipped", "stale", "startup_failure", "timed_out"]
    assert rollup.missing == []
    assert rollup.state == :failed

    assert RunInspector.required_checks_rollup(%RunInspector.Snapshot{
             harness: %RepoHarness{required_checks: ["ci / cancelled"]},
             check_statuses: [%{name: "ci / cancelled", status: "COMPLETED", conclusion: "CANCELLED"}]
           }).state == :cancelled

    assert RunInspector.required_checks_rollup(%RunInspector.Snapshot{
             harness: %RepoHarness{required_checks: ["ci / pending"]},
             check_statuses: [%{name: "ci / pending", status: "QUEUED", conclusion: nil}]
           }).state == :pending

    assert RunInspector.required_checks_rollup(%RunInspector.Snapshot{
             harness: %RepoHarness{required_checks: ["ci / passed"]},
             check_statuses: [%{name: "ci / passed", status: "COMPLETED", conclusion: "SUCCESS"}]
           }).state == :passed

    assert RunInspector.required_checks_rollup(%RunInspector.Snapshot{
             harness: %RepoHarness{required_checks: ["ci / nil-status"]},
             check_statuses: [%{name: "ci / nil-status", status: nil, conclusion: nil}]
           }).state == :pending

    assert RunInspector.required_checks_rollup(%RunInspector.Snapshot{
             harness: %RepoHarness{required_checks: ["ci / unknown-conclusion"]},
             check_statuses: [%{name: "ci / unknown-conclusion", status: "WAITING", conclusion: "CUSTOM"}]
           }).state == :pending

    assert RunInspector.ready_for_merge?(%RunInspector.Snapshot{
             pr_url: "https://example.com/pr/blank",
             pr_state: "   ",
             review_decision: "APPROVED",
             harness: %RepoHarness{required_checks: ["ci / passed"]},
             check_statuses: [%{name: "ci / passed", status: "COMPLETED", conclusion: "SUCCESS"}]
           })
  end

  test "PriorityEngine ranks issues using overrides, retries, and timestamps" do
    earlier = DateTime.from_naive!(~N[2024-01-01 12:00:00], "Etc/UTC")
    later = DateTime.from_naive!(~N[2024-01-01 12:00:10], "Etc/UTC")

    issue_one = issue(id: "1", identifier: "MT-1", priority: 2, created_at: later)
    issue_two = issue(id: "2", identifier: "MT-2", priority: nil, created_at: nil)
    issue_three = issue(id: "3", identifier: nil, priority: 1, created_at: earlier)

    ranked =
      PriorityEngine.rank_issues([issue_one, issue_two, issue_three],
        priority_overrides: %{"MT-2" => 1, "MT-1" => "high"},
        retry_attempts: %{"MT-1" => %{attempt: 2}, "3" => 1}
      )

    assert Enum.map(ranked, & &1.issue_id) == ["2", "3", "1"]
    assert Enum.map(ranked, & &1.rank) == [1, 2, 3]
    assert Enum.at(ranked, 0).reasons.operator_override == 1
    assert Enum.at(ranked, 1).reasons.retry_penalty == 1
    assert Enum.at(ranked, 2).reasons.retry_penalty == 2
    assert Enum.at(ranked, 2).reasons.linear_priority == 2
  end

  test "PriorityEngine score falls back for missing identifiers, priorities, retries, and timestamps" do
    created_at = DateTime.from_naive!(~N[2024-01-01 12:00:00], "Etc/UTC")

    assert PriorityEngine.score(issue(id: nil, identifier: nil, priority: 9, created_at: nil), %{}, %{}) ==
             {100, 5, 0, 9_223_372_036_854_775_807, ""}

    assert PriorityEngine.score(issue(id: "4", identifier: "MT-4", priority: 4, created_at: created_at), %{"MT-4" => 3}, %{"MT-4" => %{attempt: 5}}) ==
             {3, 4, 5, DateTime.to_unix(created_at, :microsecond), "MT-4"}
  end

  test "PriorityEngine rank_issues defaults options and sorts a single issue" do
    [entry] =
      PriorityEngine.rank_issues([
        issue(id: "solo", identifier: "MT-SOLO", priority: 2, created_at: ~U[2026-03-06 00:00:00Z])
      ])

    assert entry.rank == 1
    assert entry.identifier == "MT-SOLO"
    assert entry.reasons.operator_override == nil
  end

  test "LeaseManager acquires, refreshes, and preserves leases for the current owner" do
    issue_id = unique_issue_id("lease-acquire")
    path = LeaseManager.lease_path(issue_id)

    try do
      assert {:error, :missing} = LeaseManager.refresh(issue_id, "owner-a")
      assert :ok = LeaseManager.acquire(issue_id, "MT-1", "owner-a")
      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert lease["issue_identifier"] == "MT-1"
      assert lease["owner"] == "owner-a"
      assert lease["epoch"] == 1
      assert match?({:ok, _, _}, DateTime.from_iso8601(lease["acquired_at"]))
      assert :ok = LeaseManager.refresh(issue_id, "owner-a")

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: "MT-1",
          owner: "owner-a",
          lease_version: 1,
          epoch: 4,
          acquired_at: "2024-01-01T00:00:00Z",
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      )

      assert :ok = LeaseManager.acquire(issue_id, "MT-1", "owner-a", ttl_ms: 60_000)
      assert {:ok, same_owner_lease} = LeaseManager.read(issue_id)
      assert same_owner_lease["epoch"] == 4
      assert same_owner_lease["acquired_at"] == "2024-01-01T00:00:00Z"
    after
      File.rm(path)
    end
  end

  test "LeaseManager handles claimed, stale, malformed, and release branches" do
    issue_id = unique_issue_id("lease-branches")
    path = LeaseManager.lease_path(issue_id)

    try do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: "MT-2",
          owner: "owner-a",
          lease_version: 1,
          epoch: 2,
          acquired_at: "2024-01-01T00:00:00Z",
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      )

      assert {:error, :claimed} = LeaseManager.acquire(issue_id, "MT-2", "owner-b", ttl_ms: 60_000)
      assert {:error, :claimed} = LeaseManager.refresh(issue_id, "owner-b")

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: "MT-2",
          owner: "owner-a",
          lease_version: 1,
          epoch: 5,
          acquired_at: "not-a-date",
          updated_at: "not-a-date"
        })
      )

      assert :ok = LeaseManager.acquire(issue_id, "MT-2", "owner-c", ttl_ms: 1)
      assert {:ok, taken_over_lease} = LeaseManager.read(issue_id)
      assert taken_over_lease["owner"] == "owner-c"
      assert taken_over_lease["epoch"] == 6
      assert match?({:ok, _, _}, DateTime.from_iso8601(taken_over_lease["acquired_at"]))

      assert :ok = LeaseManager.release(issue_id, "owner-a")
      assert File.exists?(path)

      File.write!(path, "{not-json")
      assert match?({:error, _reason}, LeaseManager.read(issue_id))
      assert match?({:error, _reason}, LeaseManager.acquire(issue_id, "MT-2", "owner-c", ttl_ms: 1))
      assert match?({:error, _reason}, LeaseManager.refresh(issue_id, "owner-c"))
      assert :ok = LeaseManager.release(issue_id, "owner-c")
      assert File.exists?(path)

      assert :ok = LeaseManager.release(issue_id)
      refute File.exists?(path)
      assert :ok = LeaseManager.release(unique_issue_id("lease-release-missing"))
    after
      File.rm(path)
    end
  end

  test "LeaseManager treats nil updated_at as stale" do
    issue_id = unique_issue_id("lease-nil-updated-at")
    path = LeaseManager.lease_path(issue_id)

    try do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: "MT-3",
          owner: "owner-a",
          lease_version: 1,
          epoch: 7,
          acquired_at: "2024-01-01T00:00:00Z",
          updated_at: nil
        })
      )

      assert :ok = LeaseManager.acquire(issue_id, "MT-3", "owner-z", ttl_ms: 1)
      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert lease["owner"] == "owner-z"
      assert lease["epoch"] == 8
    after
      File.rm(path)
    end
  end

  test "LeaseManager read surfaces filesystem errors and refresh normalizes invalid acquired_at strings" do
    issue_id = unique_issue_id("lease-invalid-acquired-at")
    path = LeaseManager.lease_path(issue_id)
    File.mkdir_p!(Path.dirname(path))

    try do
      File.mkdir_p!(path)
      assert match?({:error, _reason}, LeaseManager.read(issue_id))
      File.rm_rf!(path)

      File.write!(
        path,
        Jason.encode!(%{
          "issue_id" => issue_id,
          "issue_identifier" => "MT-LEASE",
          "owner" => "owner-a",
          "lease_version" => 1,
          "epoch" => 4,
          "acquired_at" => "not-an-iso8601-timestamp",
          "updated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })
      )

      assert :ok = LeaseManager.refresh(issue_id, "owner-a")
      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert is_binary(lease["acquired_at"])
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(lease["acquired_at"])
    after
      File.rm_rf(Path.dirname(path))
    end
  end

  defp temp_workspace(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp write_harness_yaml!(workspace, required_checks) do
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    checks =
      required_checks
      |> Enum.map_join("\n", &"    - #{&1}")

    File.write!(
      RepoHarness.harness_file_path(workspace),
      """
      version: 1
      base_branch: main
      preflight:
        command: ./scripts/preflight.sh
      validation:
        command: ./scripts/validate.sh
      smoke:
        command: ./scripts/smoke.sh
      post_merge:
        command: ./scripts/post-merge.sh
      artifacts:
        command: ./scripts/artifacts.sh
      pull_request:
        required_checks:
      #{checks}
      """
    )
  end

  defp base_harness_config do
    %{
      "version" => 1,
      "base_branch" => "main",
      "preflight" => %{"command" => "./scripts/preflight.sh"},
      "validation" => %{"command" => "./scripts/validate.sh"},
      "smoke" => %{"command" => "./scripts/smoke.sh"},
      "post_merge" => %{"command" => "./scripts/post-merge.sh"},
      "artifacts" => %{"command" => "./scripts/artifacts.sh"},
      "pull_request" => %{"required_checks" => ["ci / publish"]}
    }
  end

  defp rich_harness_config do
    %{
      version: "1",
      base_branch: " main ",
      preflight: %{
        description: " Prep ",
        command: ["./scripts/preflight.sh", "--flag", "it's"],
        outputs: %{format: " text "},
        success: %{exit_code: "0"}
      },
      validation: %{command: ["./scripts/validate.sh"]},
      smoke: %{command: "./scripts/smoke.sh"},
      post_merge: %{command: "./scripts/post-merge.sh"},
      artifacts: %{command: "./scripts/artifacts.sh"},
      project: %{type: "ios-app", xcodeproj: "App.xcodeproj", scheme: "App"},
      runtime: %{simulator: %{device: "iPhone 17 Pro"}, targets: [%{name: "unit"}]},
      ci: %{
        provider: "github-actions",
        workflow: ".github/workflows/ci.yml",
        env: %{FOO: " bar "},
        required_checks: ["ci / publish", " ci / validate ", "ci / publish"]
      },
      pull_request: %{
        required_checks: ["ci / publish", "ci / validate", "ci / publish"],
        template: " .github/PULL_REQUEST_TEMPLATE.md ",
        review_ready: %{all: [%{checkbox: " Review ready "}]},
        merge_safe: %{all: [%{github_check: " ci / publish "}]}
      }
    }
  end

  defp issue(attrs) do
    struct!(Issue, attrs)
  end

  defp unique_issue_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
