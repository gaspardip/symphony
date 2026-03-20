defmodule SymphonyElixir.DeliveryRuntimePhase6BackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeliveryEngine
  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PriorityEngine
  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.RunStateStore
  alias SymphonyElixir.Workflow

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  test "delivery engine blocks implement turns with invalid turn results" do
    {workspace, issue} = implement_workspace!("invalid-turn-result")
    issue_id = issue.id

    configure_delivery_workflow!(workspace, fake_codex_binary!("invalid-turn-result", :invalid))

    assert {:stop, :invalid_turn_result} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "implementation.invalid_turn_result"
  end

  test "delivery engine returns bootstrap errors when Codex session startup fails for active stages" do
    {workspace, issue} = implement_workspace!("bootstrap-failure")

    configure_delivery_workflow!(
      workspace,
      "/definitely/missing-codex-#{System.unique_integer([:positive])} app-server"
    )

    assert {:error, reason} = DeliveryEngine.run(workspace, issue, nil)
    assert inspect(reason) =~ "port_exit"
  end

  test "delivery engine blocks implement turns that omit the turn-result tool call" do
    {workspace, issue} = implement_workspace!("missing-turn-result")
    issue_id = issue.id

    configure_delivery_workflow!(workspace, fake_codex_binary!("missing-turn-result", :missing))

    assert {:stop, :missing_turn_result} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "implementation.missing_turn_result"
  end

  test "delivery engine retries implement turns after Codex stream errors and can recover on the next turn" do
    {workspace, issue} = git_implement_workspace!("stream-error-retry")
    issue_id = issue.id

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("stream-error-retry", :stream_error_then_code_change)
    )

    assert {:stop, :validation_unavailable} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.implementation_turns == 2

    assert get_in(state, [:last_turn_result, :summary]) ==
             "Recovered after transient stream error"

    assert get_in(state, [:last_implementation_error, :summary]) =~ "stream_error"
    assert get_in(state, [:stop_reason, :code]) == "validation_unavailable"
  end

  test "delivery engine blocks implement turns that make no code or PR progress" do
    {workspace, issue} = implement_workspace!("noop-turn")
    issue_id = issue.id

    configure_delivery_workflow!(workspace, fake_codex_binary!("noop-turn", :noop))

    assert {:stop, :noop_turn} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert get_in(state, [:stop_reason, :code]) == "noop_turn"
  end

  test "delivery engine blocks validate stage when validation is unavailable" do
    {workspace, issue} = validate_workspace!("validation-unavailable")
    issue_id = issue.id

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("validation-unavailable", :missing)
    )

    assert {:stop, :validation_unavailable} = DeliveryEngine.run(workspace, issue, nil)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert get_in(state, [:stop_reason, :code]) == "validation_unavailable"
  end

  test "delivery engine can complete checkout and then block on an invalid implementation turn result" do
    {workspace, issue} = checkout_workspace!("checkout-to-invalid-turn")

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("checkout-to-invalid-turn", :invalid)
    )

    assert result =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: &checkout_command_runner/3,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end
             )

    assert result in [{:stop, :invalid_turn_result}, {:stop, :blocked}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.branch == "symphony/mt-runtime"
    assert state.base_branch == "main"
    assert state.harness_version == 1
    assert state.effective_policy_class == "fully_autonomous"
    assert state.effective_policy_source == "default"
    assert get_in(state, [:stop_reason, :code]) == "invalid_turn_result"
  end

  test "delivery engine initializes the agent harness before continuing from checkout" do
    {workspace, issue} = checkout_workspace!("checkout-with-agent-harness")

    write_agent_harness_yaml!(workspace)

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("checkout-with-agent-harness", :missing)
    )

    assert result =
             DeliveryEngine.run(workspace, issue, nil,
               command_runner: &checkout_command_runner/3,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
             )

    assert result in [{:stop, :missing_turn_result}, {:stop, :blocked}]

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.harness_status in ["initialized", "ready"]
    assert is_binary(state.last_harness_init)
    assert get_in(state, [:stop_reason, :code]) == "missing_turn_result"
    assert get_in(state, [:last_harness_check, :status]) == "passed"
    assert File.exists?(Path.join(workspace, ".symphony/progress/MT-RUNTIME.md"))
    assert File.exists?(Path.join(workspace, ".symphony/knowledge/product.md"))
  end

  test "delivery engine advances from implement to validate after a real code change" do
    {workspace, issue} = git_implement_workspace!("implement-to-validate")
    issue_id = issue.id

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("implement-to-validate", :code_change)
    )

    assert {:stop, :validation_unavailable} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.implementation_turns >= 1
    assert get_in(state, [:last_turn_result, :summary]) == "Updated tracked file"
    assert state.branch == "main"
    assert get_in(state, [:stop_reason, :code]) == "validation_unavailable"
  end

  test "delivery engine blocks implement turns when the agent reports a blocker" do
    {workspace, issue} = implement_workspace!("agent-blocked")
    issue_id = issue.id

    configure_delivery_workflow!(workspace, fake_codex_binary!("agent-blocked", :blocked))

    assert {:stop, :validation} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end)

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert state.last_rule_id == "runtime.validation"
    assert get_in(state, [:stop_reason, :code]) == "validation"
  end

  test "delivery engine finishes when the issue disappears during refresh" do
    {workspace, issue} = implement_workspace!("missing-after-turn")

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("missing-after-turn", :code_change)
    )

    assert {:done, :missing} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, []} end)
  end

  test "delivery engine keeps seeded manual issues alive when refresh returns no tracker record" do
    {workspace, issue} = git_implement_workspace!("manual-missing-after-turn")

    manual_issue = %Issue{issue | id: "manual:MT-RUNTIME", source: :manual}

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: manual_issue.id,
               issue_identifier: manual_issue.identifier,
               issue_source: manual_issue.source
             })

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("manual-missing-after-turn", :code_change)
    )

    assert {:stop, :validation_unavailable} =
             DeliveryEngine.run(workspace, manual_issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, []} end)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert get_in(state, [:last_turn_result, :summary]) == "Updated tracked file"
    assert get_in(state, [:stop_reason, :code]) == "validation_unavailable"
  end

  test "delivery engine returns refresh errors from implement turns" do
    {workspace, issue} = git_implement_workspace!("refresh-error-after-turn")

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("refresh-error-after-turn", :code_change)
    )

    assert {:error, {:issue_state_refresh_failed, :refresh_failed}} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:error, :refresh_failed} end)
  end

  test "delivery engine stops advancing when the refreshed issue is no longer active" do
    {workspace, issue} = implement_workspace!("inactive-after-turn")

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("inactive-after-turn", :code_change)
    )

    refreshed_issue = %{issue | state: "Done"}

    assert {:done, %Issue{state: "Done", identifier: "MT-RUNTIME"}} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [refreshed_issue]} end)
  end

  test "delivery engine advances validate into verify after a passing validation command" do
    {workspace, issue} = validate_workspace!("validate-to-verify")

    configure_delivery_workflow!(workspace, fake_codex_binary!("validate-to-verify", :missing))
    File.mkdir_p!(Path.join(workspace, "scripts"))
    write_harness_yaml!(workspace)

    File.write!(
      Path.join(workspace, "scripts/validate.sh"),
      "#!/usr/bin/env bash\necho validation passed\nexit 0\n"
    )

    File.chmod!(Path.join(workspace, "scripts/validate.sh"), 0o755)

    assert {:stop, :verifier_blocked} =
             DeliveryEngine.run(workspace, issue, nil,
               verifier_runner: fn _workspace, _issue, _state, _inspection, _opts ->
                 %{
                   verdict: "blocked",
                   summary: "Verifier intentionally blocked the run",
                   acceptance_gaps: [],
                   risky_areas: ["blocked"],
                   evidence: [],
                   raw_output: "blocked",
                   acceptance: %{summary: "blocked"}
                 }
               end
             )

    assert {:ok, state} = RunStateStore.load(workspace)
    assert Enum.any?(state.stage_history, &(&1.stage == "verify"))
    assert get_in(state, [:last_validation, :status]) == "passed"
  end

  test "delivery engine review_verification reopens implement when focused proof confirms a review claim" do
    {workspace, issue} = review_verification_workspace!("review-claim-accepted")

    assert {:stop, :review_verification_completed} = DeliveryEngine.run(workspace, issue, nil)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "implement"

    assert get_in(state, [:review_claims, "review:91", "verification_status"]) ==
             "verified_review_decision"

    assert get_in(state, [:review_claims, "review:91", "disposition"]) == "accepted"

    assert get_in(state, [:review_threads, "review:91", "verification_status"]) ==
             "verified_review_decision"

    assert get_in(state, [:review_threads, "review:91", "draft_reply"]) =~
             "verified this concern locally"

    assert get_in(state, [:review_threads, "review:91", "resolution_recommendation"]) ==
             "keep_open_until_change"

    assert get_in(state, [:resume_context, :review_claim_summary]) =~ "verified_review_decision"
    assert get_in(state, [:resume_context, :review_claim_summary]) =~ "lib/example.ex:2"
    assert get_in(state, [:resume_context, :review_feedback_summary]) =~ "lib/example.ex:2"

    assert get_in(state, [:resume_context, :next_objective]) =~
             "Address only the verified PR review claims"

    assert get_in(state, [:resume_context, :token_pressure]) == "high"
  end

  test "delivery engine review_verification returns to the passive stage when focused proof contradicts a claim" do
    {workspace, issue} = review_verification_workspace!("review-claim-contradicted")

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn state ->
               state
               |> Map.put(:review_claims, %{
                 "comment:92" => %{
                   "thread_key" => "comment:92",
                   "kind" => "comment",
                   "path" => "lib/missing.ex",
                   "line" => 3,
                   "claim_type" => "correctness_risk",
                   "disposition" => "needs_verification",
                   "actionable" => true,
                   "verification_status" => "pending"
                 }
               })
               |> Map.put(:review_threads, %{
                 "comment:92" => %{
                   "thread_key" => "comment:92",
                   "kind" => "comment",
                   "path" => "lib/missing.ex",
                   "line" => 3,
                   "disposition" => "needs_verification",
                   "actionable" => true,
                   "draft_state" => "drafted"
                 }
               })
             end)

    assert {:stop, :review_verification_completed} = DeliveryEngine.run(workspace, issue, nil)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "await_checks"
    assert get_in(state, [:review_claims, "comment:92", "verification_status"]) == "contradicted"
    assert get_in(state, [:review_claims, "comment:92", "disposition"]) == "dismissed"

    assert get_in(state, [:review_threads, "comment:92", "draft_reply"]) =~
             "could not confirm the claim"

    assert state.last_decision_summary =~ "did not find enough evidence"
  end

  test "delivery engine auto-posts contradicted inline review replies for autonomous runs" do
    {workspace, issue} = review_verification_workspace!("review-claim-contradicted-posted")

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn state ->
               state
               |> Map.put(:policy_pack, :private_autopilot)
               |> Map.put(:effective_policy_class, "fully_autonomous")
               |> Map.put(:pr_url, "https://github.com/example/repo/pull/42")
               |> Map.put(:review_claims, %{
                 "comment:92" => %{
                   "thread_key" => "comment:92",
                   "kind" => "comment",
                   "path" => "lib/missing.ex",
                   "line" => 3,
                   "claim_type" => "correctness_risk",
                   "disposition" => "needs_verification",
                   "actionable" => true,
                   "verification_status" => "pending"
                 }
               })
               |> Map.put(:review_threads, %{
                 "comment:92" => %{
                   "thread_key" => "comment:92",
                   "kind" => "comment",
                   "path" => "lib/missing.ex",
                   "line" => 3,
                   "disposition" => "needs_verification",
                   "actionable" => true,
                   "draft_state" => "drafted"
                 }
               })
             end)

    assert {:stop, :review_verification_completed} =
             DeliveryEngine.run(workspace, issue, nil, github_client: __MODULE__.PostingGitHubClient)

    assert_receive {:posted_review_reply, "https://github.com/example/repo/pull/42", "92", body}
    assert body =~ "could not confirm the claim"

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "await_checks"
    assert get_in(state, [:review_threads, "comment:92", "draft_state"]) == "posted"
    assert is_binary(get_in(state, [:review_threads, "comment:92", "posted_reply_id"]))
  end

  test "delivery engine auto-posts addressed inline review replies after an implement turn" do
    {workspace, issue} = git_implement_workspace!("review-claim-addressed-posted")
    issue_id = issue.id

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("review-claim-addressed-posted", :code_change)
    )

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn state ->
               state
               |> Map.put(:policy_pack, :private_autopilot)
               |> Map.put(:effective_policy_class, "fully_autonomous")
               |> Map.put(:pr_url, "https://github.com/example/repo/pull/42")
               |> Map.put(:review_claims, %{
                 "comment:93" => %{
                   "thread_key" => "comment:93",
                   "kind" => "comment",
                   "path" => "README.md",
                   "line" => 1,
                   "claim_type" => "maintainability",
                   "disposition" => "accepted",
                   "actionable" => true,
                   "verification_status" => "verified_scope"
                 }
               })
               |> Map.put(:review_threads, %{
                 "comment:93" => %{
                   "thread_key" => "comment:93",
                   "kind" => "comment",
                   "path" => "README.md",
                   "line" => 1,
                   "disposition" => "accepted",
                   "actionable" => true,
                   "draft_state" => "drafted"
                 }
               })
             end)

    assert {:stop, :validation_unavailable} =
             DeliveryEngine.run(workspace, issue, nil,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end,
               github_client: __MODULE__.PostingGitHubClient
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert_receive {:posted_review_reply, "https://github.com/example/repo/pull/42", "93", body}
    assert body =~ "addressed this concern locally"
    assert body =~ "included on the branch"

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:review_claims, "comment:93", "implementation_status"]) == "addressed"
    assert get_in(state, [:review_threads, "comment:93", "draft_state"]) == "posted"

    assert get_in(state, [:review_threads, "comment:93", "resolution_recommendation"]) ==
             "resolve_after_change"
  end

  test "delivery engine auto-posts already-addressed inline replies before the next implement turn" do
    {workspace, issue} = implement_workspace!("review-claim-addressed-preflight-posted")
    issue_id = issue.id

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("review-claim-addressed-preflight-posted", :missing)
    )

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn state ->
               state
               |> Map.put(:policy_pack, :private_autopilot)
               |> Map.put(:effective_policy_class, "fully_autonomous")
               |> Map.put(:pr_url, "https://github.com/example/repo/pull/42")
               |> Map.put(:review_claims, %{
                 "comment:94" => %{
                   "thread_key" => "comment:94",
                   "kind" => "comment",
                   "path" => "README.md",
                   "line" => 1,
                   "claim_type" => "correctness_risk",
                   "disposition" => "accepted",
                   "actionable" => false,
                   "verification_status" => "verified_scope",
                   "implementation_status" => "addressed",
                   "addressed_summary" => "Preflight addressed the scoped metrics-path fix."
                 }
               })
               |> Map.put(:review_threads, %{
                 "comment:94" => %{
                   "thread_key" => "comment:94",
                   "kind" => "comment",
                   "path" => "README.md",
                   "line" => 1,
                   "disposition" => "accepted",
                   "actionable" => false,
                   "draft_state" => "drafted"
                 }
               })
             end)

    assert {:stop, :missing_turn_result} =
             DeliveryEngine.run(workspace, issue, nil,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
               github_client: __MODULE__.PostingGitHubClient
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert_receive {:posted_review_reply, "https://github.com/example/repo/pull/42", "94", body}
    assert body =~ "addressed this concern locally"
    assert body =~ "Preflight addressed the scoped metrics-path fix."

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:review_threads, "comment:94", "draft_state"]) == "posted"

    assert get_in(state, [:review_threads, "comment:94", "resolution_recommendation"]) ==
             "resolve_after_change"
  end

  test "delivery engine keeps deferred and insufficient-evidence inline review replies as drafts before implement" do
    {workspace, issue} = implement_workspace!("review-claim-non-actionable-preflight-posted")
    issue_id = issue.id

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("review-claim-non-actionable-preflight-posted", :missing)
    )

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn state ->
               state
               |> Map.put(:policy_pack, :private_autopilot)
               |> Map.put(:effective_policy_class, "fully_autonomous")
               |> Map.put(:pr_url, "https://github.com/example/repo/pull/42")
               |> Map.put(:review_claims, %{
                 "comment:95" => %{
                   "thread_key" => "comment:95",
                   "kind" => "comment",
                   "path" => "README.md",
                   "line" => 1,
                   "claim_type" => "maintainability",
                   "disposition" => "deferred",
                   "actionable" => false,
                   "verification_status" => "not_needed"
                 },
                 "comment:96" => %{
                   "thread_key" => "comment:96",
                   "kind" => "comment",
                   "path" => "README.md",
                   "line" => 1,
                   "claim_type" => "unclear",
                   "disposition" => "dismissed",
                   "actionable" => false,
                   "verification_status" => "not_needed",
                   "consensus_summary" => "Consensus mixed and no concrete local proof was found."
                 }
               })
               |> Map.put(:review_threads, %{
                 "comment:95" => %{
                   "thread_key" => "comment:95",
                   "kind" => "comment",
                   "path" => "README.md",
                   "line" => 1,
                   "disposition" => "deferred",
                   "actionable" => false,
                   "draft_state" => "drafted"
                 },
                 "comment:96" => %{
                   "thread_key" => "comment:96",
                   "kind" => "comment",
                   "path" => "README.md",
                   "line" => 1,
                   "disposition" => "dismissed",
                   "actionable" => false,
                   "draft_state" => "drafted"
                 }
               })
             end)

    assert {:stop, :missing_turn_result} =
             DeliveryEngine.run(workspace, issue, nil,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
               github_client: __MODULE__.PostingGitHubClient
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}
    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:review_threads, "comment:95", "draft_state"]) == "drafted"
    assert get_in(state, [:review_threads, "comment:96", "draft_state"]) == "drafted"
  end

  test "delivery engine refreshes stale posted inline replies when the reply plan changes" do
    {workspace, issue} = implement_workspace!("review-claim-posted-refresh")
    issue_id = issue.id

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("review-claim-posted-refresh", :missing)
    )

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn state ->
               state
               |> Map.put(:policy_pack, :private_autopilot)
               |> Map.put(:effective_policy_class, "fully_autonomous")
               |> Map.put(:pr_url, "https://github.com/example/repo/pull/42")
               |> Map.put(:review_claims, %{
                 "comment:97" => %{
                   "thread_key" => "comment:97",
                   "kind" => "comment",
                   "path" => "lib/missing.ex",
                   "line" => 1,
                   "claim_type" => "correctness_risk",
                   "disposition" => "dismissed",
                   "actionable" => false,
                   "verification_status" => "contradicted"
                 }
               })
               |> Map.put(:review_threads, %{
                 "comment:97" => %{
                   "thread_key" => "comment:97",
                   "kind" => "comment",
                   "path" => "lib/missing.ex",
                   "line" => 1,
                   "disposition" => "dismissed",
                   "actionable" => false,
                   "draft_state" => "posted",
                   "draft_reply" => "Old reply.",
                   "posted_reply_id" => "reply-97",
                   "posted_reply_url" => "https://github.com/example/repo/pull/42#reply-97"
                 }
               })
             end)

    assert {:stop, :missing_turn_result} =
             DeliveryEngine.run(workspace, issue, nil,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
               github_client: __MODULE__.PostingGitHubClient
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}

    assert_receive {:updated_review_reply, "https://github.com/example/repo/pull/42", "reply-97", body}

    assert body =~ "could not confirm the claim"

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:review_threads, "comment:97", "draft_state"]) == "posted"
    assert get_in(state, [:review_threads, "comment:97", "reply_refresh_needed"]) == false
  end

  test "delivery engine reconciles stale posted inline replies from live GitHub feedback before implement" do
    {workspace, issue} = implement_workspace!("review-claim-live-reconcile")
    issue_id = issue.id

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("review-claim-live-reconcile", :missing)
    )

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn state ->
               state
               |> Map.put(:policy_pack, :private_autopilot)
               |> Map.put(:effective_policy_class, "fully_autonomous")
               |> Map.put(:pr_url, "https://github.com/example/repo/pull/42")
               |> Map.put(:review_claims, %{
                 "comment:98" => %{
                   "thread_key" => "comment:98",
                   "kind" => "comment",
                   "body" => "Please harden the local-only default.",
                   "path" => "ops/observability/docker-compose.yml",
                   "line" => 56,
                   "claim_type" => "maintainability",
                   "disposition" => "deferred",
                   "actionable" => false,
                   "verification_status" => "not_needed"
                 }
               })
               |> Map.put(:review_threads, %{
                 "comment:98" => %{
                   "thread_key" => "comment:98",
                   "kind" => "comment",
                   "path" => "ops/observability/docker-compose.yml",
                   "line" => 56,
                   "disposition" => "deferred",
                   "actionable" => false,
                   "draft_state" => "posted",
                   "draft_reply" => "Old local reply.",
                   "posted_reply_id" => "reply-98",
                   "posted_reply_url" => "https://github.com/example/repo/pull/42#discussion_rreply-98",
                   "reply_refresh_needed" => true
                 }
               })
             end)

    assert {:stop, :missing_turn_result} =
             DeliveryEngine.run(workspace, issue, nil,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
               github_client: __MODULE__.ReconcilingGitHubClient
             )

    assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}

    assert {:ok, state} = RunStateStore.load(workspace)
    assert get_in(state, [:review_threads, "comment:98", "draft_state"]) in ["posted", "approved_to_update"]
    refute get_in(state, [:review_threads, "comment:98", "draft_reply"]) == "Old local reply."
    assert get_in(state, [:review_threads, "comment:98", "posted_reply_id"]) == "reply-98"
    assert get_in(state, [:review_threads, "comment:98", "posted_at"]) == "2026-03-16T12:06:00Z"
    assert get_in(state, [:resume_context, :review_feedback_summary]) =~ "docker-compose.yml:56"
  end

  test "delivery engine refreshes pending review claims from local proof before implement" do
    {workspace, issue} = implement_workspace!("review-claim-preflight-pattern-refresh")

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("review-claim-preflight-pattern-refresh", :missing)
    )

    tracker_file = Path.join(workspace, "elixir/lib/symphony_elixir/tracker_event.ex")
    File.mkdir_p!(Path.dirname(tracker_file))

    File.write!(
      tracker_file,
      """
      defmodule Example do
        def dedupe_key(hash) do
          ("tracker-event:" <> hash)
          |> Base.encode16(case: :lower)
        end
      end
      """
    )

    assert {:ok, _state} =
             RunStateStore.update(workspace, fn state ->
               state
               |> Map.put(:policy_pack, :private_autopilot)
               |> Map.put(:effective_policy_class, "fully_autonomous")
               |> Map.put(:pr_url, "https://github.com/example/repo/pull/42")
               |> Map.put(:review_claims, %{
                 "comment:97" => %{
                   "thread_key" => "comment:97",
                   "kind" => "comment",
                   "body" => "`dedupe_key/1` now produces a completely different key and may break deduplication/backfill logic.",
                   "path" => "elixir/lib/symphony_elixir/tracker_event.ex",
                   "line" => 3,
                   "claim_type" => "unclear",
                   "disposition" => "needs_verification",
                   "actionable" => true,
                   "verification_status" => "insufficient_evidence"
                 }
               })
               |> Map.put(:review_threads, %{
                 "comment:97" => %{
                   "thread_key" => "comment:97",
                   "kind" => "comment",
                   "path" => "elixir/lib/symphony_elixir/tracker_event.ex",
                   "line" => 3,
                   "disposition" => "needs_verification",
                   "actionable" => true,
                   "draft_state" => "drafted"
                 }
               })
             end)

    assert {:stop, :missing_turn_result} =
             DeliveryEngine.run(workspace, issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end)

    assert {:ok, state} = RunStateStore.load(workspace)

    assert get_in(state, [:review_claims, "comment:97", "verification_status"]) ==
             "verified_local_pattern"

    assert get_in(state, [:review_claims, "comment:97", "disposition"]) == "accepted"
    assert get_in(state, [:review_claims, "comment:97", "hard_proof"]) == true
  end

  test "delivery engine blocks deploy preview stage when the harness omits a preview command" do
    {workspace, issue} = checkout_workspace!("deploy-preview-missing")

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("deploy-preview-missing", :missing)
    )

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "deploy_preview", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    assert {:stop, :deploy_preview_missing} = DeliveryEngine.run(workspace, issue, nil)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert get_in(state, [:stop_reason, :code]) == "deploy_preview_missing"
  end

  test "delivery engine blocks deploy production stage when the harness omits a production command" do
    {workspace, issue} = checkout_workspace!("deploy-production-missing")

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("deploy-production-missing", :missing)
    )

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "deploy_production", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    assert {:stop, :deploy_production_missing} = DeliveryEngine.run(workspace, issue, nil)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert get_in(state, [:stop_reason, :code]) == "deploy_production_missing"
  end

  test "delivery engine blocks post-deploy verification when the harness omits the verify command" do
    {workspace, issue} = checkout_workspace!("post-deploy-verify-missing")

    configure_delivery_workflow!(
      workspace,
      fake_codex_binary!("post-deploy-verify-missing", :missing)
    )

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "post_deploy_verify", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               current_deploy_target: "preview"
             })

    assert {:stop, :post_deploy_failed} = DeliveryEngine.run(workspace, issue, nil)

    assert {:ok, state} = RunStateStore.load(workspace)
    assert state.stage == "blocked"
    assert get_in(state, [:stop_reason, :code]) == "post_deploy_failed"
  end

  test "run inspector public helpers handle bare rollups and wrapper commands" do
    assert RunInspector.required_checks_rollup(nil, [%{name: "ignored"}]) == %{
             state: :passed,
             required: [],
             missing: [],
             pending: [],
             failed: [],
             cancelled: []
           }

    assert RunInspector.required_checks_rollup(
             %RepoHarness{required_checks: ["ci / validate"]},
             []
           ).state ==
             :missing

    harness = %RepoHarness{validation_command: "validate", smoke_command: "smoke"}

    shell_runner = fn
      _workspace, "validate", _opts -> {"validated", 0}
      _workspace, "smoke", _opts -> {"smoke failed", 1}
    end

    assert %RunInspector.CommandResult{status: :passed, output: "validated"} =
             RunInspector.run_validation("/tmp/run-inspector", harness, shell_runner: shell_runner)

    assert %RunInspector.CommandResult{status: :failed, output: "smoke failed"} =
             RunInspector.run_smoke("/tmp/run-inspector", harness, shell_runner: shell_runner)
  end

  test "run inspector supports post-merge and default git-backed helpers" do
    workspace = temp_workspace!("run-inspector-defaults")

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "before\n")
      System.cmd("git", ["init", "-b", "main"], cd: workspace)
      System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
      System.cmd("git", ["add", "README.md"], cd: workspace)
      System.cmd("git", ["commit", "-m", "initial"], cd: workspace)

      File.write!(Path.join(workspace, "README.md"), "after\n")
      File.write!(Path.join(workspace, "notes.txt"), "new file\n")

      assert %RunInspector.CommandResult{status: :unavailable, command: nil} =
               RunInspector.run_post_merge(workspace, nil)

      assert Enum.sort(RunInspector.changed_paths(workspace)) == ["README.md", "notes.txt"]
      assert RunInspector.diff_summary(workspace) =~ "1 file changed"
    after
      File.rm_rf(workspace)
    end
  end

  test "repo harness validates a minimal harness and rejects missing base_branch" do
    assert {:ok, normalized} = RepoHarness.validate(minimal_harness_config())
    assert normalized.preflight.command == "./scripts/preflight.sh"
    assert normalized.validation.command == "./scripts/validate.sh"
    assert normalized.pull_request.required_checks == ["ci / validate"]

    assert {:error, {:invalid_harness_value, ["base_branch"]}} =
             RepoHarness.validate(Map.delete(minimal_harness_config(), "base_branch"))
  end

  test "repo harness accepts empty rule groups and rejects invalid pull_request sections" do
    config =
      minimal_harness_config()
      |> put_in(["pull_request", "review_ready"], %{})
      |> put_in(["pull_request", "merge_safe"], %{})

    assert {:ok, normalized} = RepoHarness.validate(config)
    assert normalized.pull_request.review_ready == %{all: []}
    assert normalized.pull_request.merge_safe == %{all: []}

    assert {:error, {:invalid_harness_section, ["pull_request"]}} =
             RepoHarness.validate(Map.put(minimal_harness_config(), "pull_request", "bad"))
  end

  test "repo harness load rejects non-map YAML roots" do
    workspace = temp_workspace!("repo-harness-invalid-root")

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.write!(RepoHarness.harness_file_path(workspace), "false\n")

      assert {:error, :invalid_harness_root} = RepoHarness.load(workspace)
    after
      File.rm_rf(workspace)
    end
  end

  test "lease manager surfaces read errors for non-file lease paths" do
    issue_id = unique_issue_id("lease-read-error")
    path = LeaseManager.lease_path(issue_id)

    try do
      File.mkdir_p!(Path.dirname(path))
      File.mkdir!(path)

      assert {:error, :eisdir} = LeaseManager.read(issue_id)
    after
      File.rm_rf(path)
    end
  end

  test "lease manager refresh normalizes invalid acquired_at timestamps" do
    issue_id = unique_issue_id("lease-refresh-invalid-acquired-at")
    path = LeaseManager.lease_path(issue_id)

    try do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: "MT-LEASE",
          owner: "owner-a",
          lease_version: 1,
          epoch: 2,
          acquired_at: "not-a-date",
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      )

      assert :ok = LeaseManager.refresh(issue_id, "owner-a")
      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert lease["owner"] == "owner-a"
      assert lease["epoch"] == 2
      assert lease["acquired_at"] != "not-a-date"
      assert match?({:ok, _, _}, DateTime.from_iso8601(lease["acquired_at"]))
    after
      File.rm(path)
    end
  end

  test "lease manager releases matching owners and normalizes non-string acquired_at values" do
    issue_id = unique_issue_id("lease-release-matching-owner")
    path = LeaseManager.lease_path(issue_id)

    try do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          issue_id: issue_id,
          issue_identifier: "MT-LEASE",
          owner: "owner-a",
          lease_version: 1,
          epoch: 3,
          acquired_at: 123,
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      )

      assert :ok = LeaseManager.refresh(issue_id, "owner-a")
      assert {:ok, lease} = LeaseManager.read(issue_id)
      assert lease["acquired_at"] != 123
      assert match?({:ok, _, _}, DateTime.from_iso8601(lease["acquired_at"]))

      assert :ok = LeaseManager.release(issue_id, "owner-a")
      refute File.exists?(path)
    after
      File.rm(path)
    end
  end

  test "priority engine ranks issues with default opts and created_at fallbacks" do
    earlier = DateTime.from_naive!(~N[2024-01-01 12:00:00], "Etc/UTC")

    dated_issue = %Issue{id: "1", identifier: "MT-1", priority: 1, created_at: earlier}
    undated_issue = %Issue{id: "2", identifier: "MT-2", priority: nil, created_at: nil}

    ranked = PriorityEngine.rank_issues([undated_issue, dated_issue])

    assert Enum.map(ranked, & &1.issue_id) == ["1", "2"]

    assert PriorityEngine.score(dated_issue, %{}, %{}) ==
             {100, 1, 0, DateTime.to_unix(earlier, :microsecond), "MT-1"}

    assert PriorityEngine.score(undated_issue, %{}, %{}) ==
             {100, 5, 0, 9_223_372_036_854_775_807, "MT-2"}
  end

  defp configure_delivery_workflow!(workspace, codex_command) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.dirname(workspace),
      codex_command: codex_command
    )
  end

  defp implement_workspace!(suffix) do
    workspace = temp_workspace!("delivery-engine-#{suffix}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    issue = %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-RUNTIME",
      title: "Runtime backfill #{suffix}",
      description: "## Acceptance Criteria\n- cover runtime helper branches",
      state: "In Progress"
    }

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    {workspace, issue}
  end

  defp validate_workspace!(suffix) do
    {workspace, issue} = implement_workspace!(suffix)

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "validate", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    {workspace, issue}
  end

  defp review_verification_workspace!(suffix) do
    {workspace, issue} = implement_workspace!(suffix)
    File.mkdir_p!(Path.join(workspace, "lib"))

    File.write!(
      Path.join(workspace, "lib/example.ex"),
      "defmodule Example do\n  def ok, do: :ok\nend\n"
    )

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "review_verification", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               review_return_stage: "await_checks",
               review_claims: %{
                 "review:91" => %{
                   "thread_key" => "review:91",
                   "kind" => "review",
                   "path" => "lib/example.ex",
                   "line" => 2,
                   "review_decision" => "CHANGES_REQUESTED",
                   "claim_type" => "correctness_risk",
                   "disposition" => "needs_verification",
                   "actionable" => true,
                   "verification_status" => "pending"
                 }
               },
               review_threads: %{
                 "review:91" => %{
                   "thread_key" => "review:91",
                   "kind" => "review",
                   "path" => "lib/example.ex",
                   "line" => 2,
                   "review_decision" => "CHANGES_REQUESTED",
                   "disposition" => "needs_verification",
                   "actionable" => true,
                   "draft_state" => "drafted"
                 }
               }
             })

    {workspace, issue}
  end

  defmodule PostingGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def existing_pull_request(_workspace, _opts), do: {:error, :missing_pr}

    @impl true
    def edit_pull_request(_workspace, _title, _body_file, _opts), do: {:error, :unsupported}

    @impl true
    def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, _opts),
      do: {:error, :unsupported}

    @impl true
    def merge_pull_request(_workspace, _opts), do: {:error, :unsupported}

    @impl true
    def review_feedback(_workspace, _opts), do: {:error, :review_feedback_unavailable}

    @impl true
    def review_feedback_by_pr_url(_pr_url, _opts), do: {:error, :review_feedback_unavailable}

    @impl true
    def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok

    @impl true
    def post_review_comment_reply(pr_url, comment_id, body, _opts) do
      send(self(), {:posted_review_reply, pr_url, to_string(comment_id), body})
      {:ok, %{id: "reply-#{comment_id}", url: "#{pr_url}#reply-#{comment_id}", output: ""}}
    end

    @impl true
    def edit_review_comment_reply(pr_url, comment_id, body, _opts) do
      send(self(), {:updated_review_reply, pr_url, to_string(comment_id), body})
      {:ok, %{id: to_string(comment_id), url: "#{pr_url}#reply-#{comment_id}", output: ""}}
    end
  end

  defmodule ReconcilingGitHubClient do
    @behaviour SymphonyElixir.GitHubClient

    @impl true
    def existing_pull_request(_workspace, _opts), do: {:error, :missing_pr}

    @impl true
    def edit_pull_request(_workspace, _title, _body_file, _opts), do: {:error, :unsupported}

    @impl true
    def create_pull_request(_workspace, _branch, _base_branch, _title, _body_file, _opts),
      do: {:error, :unsupported}

    @impl true
    def merge_pull_request(_workspace, _opts), do: {:error, :unsupported}

    @impl true
    def review_feedback(_workspace, _opts) do
      {:ok,
       %{
         pr_url: "https://github.com/example/repo/pull/42",
         review_decision: "COMMENTED",
         reviews: [],
         comments: [
           %{
             id: "98",
             user: %{login: "Copilot"},
             body: "Please harden the local-only default.",
             path: "ops/observability/docker-compose.yml",
             line: 56,
             created_at: "2026-03-16T12:00:00Z",
             replies: [
               %{
                 id: "reply-98",
                 url: "https://github.com/example/repo/pull/42#discussion_rreply-98",
                 body: "I agree this may be worthwhile, but I am deferring it for now to avoid churn on the current PR.",
                 created_at: "2026-03-16T12:05:00Z",
                 updated_at: "2026-03-16T12:06:00Z"
               }
             ]
           }
         ]
       }}
    end

    @impl true
    def review_feedback_by_pr_url(_pr_url, _opts), do: review_feedback(nil, nil)

    @impl true
    def persist_pr_url(_workspace, _branch, _url, _opts), do: :ok

    @impl true
    def post_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}

    @impl true
    def edit_review_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :unsupported}
  end

  defp checkout_workspace!(suffix) do
    workspace = temp_workspace!("delivery-engine-#{suffix}")
    File.mkdir_p!(Path.join(workspace, ".git"))
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    write_harness_yaml!(workspace)

    issue = %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-RUNTIME",
      title: "Runtime checkout #{suffix}",
      description: "## Acceptance Criteria\n- cover checkout success branches",
      state: "Todo"
    }

    {workspace, issue}
  end

  defp git_implement_workspace!(suffix) do
    workspace = temp_workspace!("delivery-engine-#{suffix}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, "README.md"), "before\n")

    System.cmd("git", ["init", "-b", "main"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["add", "README.md"], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)

    issue = %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-RUNTIME",
      title: "Runtime implement #{suffix}",
      description: "## Acceptance Criteria\n- cover implement success transition",
      state: "In Progress"
    }

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier
             })

    {workspace, issue}
  end

  defp temp_workspace!(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-delivery-runtime-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp fake_codex_binary!(suffix, mode) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-delivery-runtime-fake-codex-#{suffix}-#{System.unique_integer([:positive])}"
      )

    binary = Path.join(root, "fake-codex")
    File.mkdir_p!(root)

    if mode == :stream_error_then_code_change do
      File.write!(binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-#{suffix}"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-#{suffix}"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"codex/event/stream_error","params":{"message":"provider stream dropped"}}'
            printf '%s\\n' '{"method":"error","params":{"message":"stream lost"}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-#{suffix}-retry"}}}'
            printf '%s\n' 'changed after retry' >> README.md
            printf '%s\\n' '{"id":101,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"Recovered after transient stream error","files_touched":["README.md"],"needs_another_turn":false,"blocked":false,"blocker_type":"none"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(binary, 0o755)
      "#{binary} app-server"
    else
      tool_events =
        case mode do
          :invalid ->
            [
              ~s|printf '%s\\n' '{"id":99,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"bad result"}}}'|,
              ~s|printf '%s\\n' '{"method":"turn/completed"}'|
            ]

          :missing ->
            [~s|printf '%s\\n' '{"method":"turn/completed"}'|]

          :noop ->
            [
              ~s|printf '%s\\n' '{"id":100,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"No-op implementation pass","files_touched":[],"needs_another_turn":false,"blocked":false,"blocker_type":"none"}}}'|,
              ~s|printf '%s\\n' '{"method":"turn/completed"}'|
            ]

          :blocked ->
            [
              ~s|printf '%s\\n' '{"id":100,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"Validation is unavailable in this workspace","files_touched":[],"needs_another_turn":false,"blocked":true,"blocker_type":"validation"}}}'|,
              ~s|printf '%s\\n' '{"method":"turn/completed"}'|
            ]

          :code_change ->
            [
              ~s|printf '%s\n' 'changed' >> README.md|,
              ~s|printf '%s\\n' '{"id":101,"method":"item/tool/call","params":{"tool":"report_agent_turn_result","arguments":{"summary":"Updated tracked file","files_touched":["README.md"],"needs_another_turn":false,"blocked":false,"blocker_type":"none"}}}'|,
              ~s|printf '%s\\n' '{"method":"turn/completed"}'|
            ]
        end
        |> Enum.join("\n              ")

      File.write!(binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-#{suffix}"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-#{suffix}"}}}'
            ;;
          4)
            #{tool_events}
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(binary, 0o755)
      "#{binary} app-server"
    end
  end

  defp checkout_command_runner("git", ["config", "--get", "remote.origin.url"], _opts),
    do: {"git@example.com:repo.git\n", 0}

  defp checkout_command_runner("git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts),
    do: {"main\n", 0}

  defp checkout_command_runner("git", ["rev-parse", "HEAD"], _opts), do: {"abc123\n", 0}
  defp checkout_command_runner("git", ["status", "--porcelain"], _opts), do: {"", 0}

  defp checkout_command_runner(
         "gh",
         ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"],
         _opts
       ),
       do: {"", 1}

  defp checkout_command_runner("git", ["fetch", "origin", "main"], _opts), do: {"", 0}
  defp checkout_command_runner("git", ["checkout", "symphony/mt-runtime"], _opts), do: {"", 1}

  defp checkout_command_runner(
         "git",
         ["checkout", "-B", "symphony/mt-runtime", "origin/main"],
         _opts
       ),
       do: {"", 0}

  defp checkout_command_runner(
         "git",
         ["config", "branch.symphony/mt-runtime.symphony-base-branch", "main"],
         _opts
       ),
       do: {"", 0}

  defp checkout_command_runner(command, args, opts), do: System.cmd(command, args, opts)

  defp minimal_harness_config do
    %{
      "version" => 1,
      "base_branch" => "main",
      "preflight" => %{"command" => ["./scripts/preflight.sh"]},
      "validation" => %{"command" => ["./scripts/validate.sh"]},
      "smoke" => %{"command" => ["./scripts/smoke.sh"]},
      "post_merge" => %{"command" => ["./scripts/post-merge.sh"]},
      "artifacts" => %{"command" => ["./scripts/artifacts.sh"]},
      "pull_request" => %{"required_checks" => ["ci / validate"]}
    }
  end

  defp write_harness_yaml!(workspace) do
    File.write!(
      RepoHarness.harness_file_path(workspace),
      """
      version: 1
      base_branch: main
      preflight:
        command:
          - ./scripts/preflight.sh
      validation:
        command:
          - ./scripts/validate.sh
      smoke:
        command:
          - ./scripts/smoke.sh
      post_merge:
        command:
          - ./scripts/post-merge.sh
      artifacts:
        command:
          - ./scripts/artifacts.sh
      pull_request:
        required_checks:
          - ci / validate
      """
    )
  end

  defp write_agent_harness_yaml!(workspace) do
    File.write!(
      RepoHarness.harness_file_path(workspace),
      """
      version: 1
      base_branch: main
      agent_harness:
        scope: self_host_only
        initializer:
          enabled: true
          max_turns: 1
          refresh: missing
        knowledge:
          root: .symphony/knowledge
          required_files:
            - product.md
            - architecture.md
            - codebase-map.md
            - delivery-loop.md
            - testing-and-ops.md
        progress:
          root: .symphony/progress
          pattern: "{{ issue.identifier }}.md"
          required_sections:
            - Goal
            - Acceptance
            - Plan
            - Work Log
            - Evidence
            - Next Step
        features:
          root: .symphony/features
          format: yaml
          required_fields:
            - id
            - title
            - status
            - summary
            - source_paths
            - acceptance_signals
            - dependencies
            - last_updated_by_issue
        publish_gate:
          require_progress: true
          require_feature_update_on_code_change: true
      preflight:
        command:
          - ./scripts/preflight.sh
      validation:
        command:
          - ./scripts/validate.sh
      smoke:
        command:
          - ./scripts/smoke.sh
      post_merge:
        command:
          - ./scripts/post-merge.sh
      artifacts:
        command:
          - ./scripts/artifacts.sh
      pull_request:
        required_checks:
          - ci / validate
      """
    )
  end

  defp unique_issue_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  describe "auto-loaded context trimming" do
    test "trims large SPEC.md and restores it" do
      workspace = Path.join(System.tmp_dir!(), "context-trim-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      large_content =
        Enum.map_join(1..300, "\n", fn i -> "## Section #{i}\n\nDetailed content for section #{i} with enough text." end)

      spec_path = Path.join(workspace, "SPEC.md")
      File.write!(spec_path, large_content)
      assert byte_size(large_content) > 8_192

      DeliveryEngine.trim_auto_loaded_context_for_test(workspace)

      trimmed = File.read!(spec_path)
      assert byte_size(trimmed) < byte_size(large_content)
      assert trimmed =~ "auto-trimmed by the Symphony runner"
      assert trimmed =~ ".symphony/runtime/context_backups/SPEC.md"
      assert File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/SPEC.md"))
      assert File.read!(Path.join(workspace, ".symphony/runtime/context_backups/SPEC.md")) == large_content

      DeliveryEngine.restore_auto_loaded_context_for_test(workspace)
      assert File.read!(spec_path) == large_content
      refute File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/SPEC.md"))
    end

    test "trims large CLAUDE.md the same way" do
      workspace = Path.join(System.tmp_dir!(), "context-trim-claude-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      large_content =
        Enum.map_join(1..300, "\n", fn i -> "## Rule #{i}\n\nAlways do thing #{i} when writing code." end)

      claude_path = Path.join(workspace, "CLAUDE.md")
      File.write!(claude_path, large_content)
      assert byte_size(large_content) > 8_192

      DeliveryEngine.trim_auto_loaded_context_for_test(workspace)

      trimmed = File.read!(claude_path)
      assert byte_size(trimmed) < byte_size(large_content)
      assert trimmed =~ ".symphony/runtime/context_backups/CLAUDE.md"
      assert File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/CLAUDE.md"))

      DeliveryEngine.restore_auto_loaded_context_for_test(workspace)
      assert File.read!(claude_path) == large_content
      refute File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/CLAUDE.md"))
    end

    test "trims both SPEC.md and CLAUDE.md when both are oversized" do
      workspace = Path.join(System.tmp_dir!(), "context-trim-both-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      large = Enum.map_join(1..300, "\n", fn i -> "## Section #{i}\n\nContent #{i} padded." end)

      File.write!(Path.join(workspace, "SPEC.md"), large)
      File.write!(Path.join(workspace, "CLAUDE.md"), large)

      DeliveryEngine.trim_auto_loaded_context_for_test(workspace)

      assert File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/SPEC.md"))
      assert File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/CLAUDE.md"))
      assert byte_size(File.read!(Path.join(workspace, "SPEC.md"))) < byte_size(large)
      assert byte_size(File.read!(Path.join(workspace, "CLAUDE.md"))) < byte_size(large)

      DeliveryEngine.restore_auto_loaded_context_for_test(workspace)
      refute File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/SPEC.md"))
      refute File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/CLAUDE.md"))
      assert File.read!(Path.join(workspace, "SPEC.md")) == large
      assert File.read!(Path.join(workspace, "CLAUDE.md")) == large
    end

    test "skips small files" do
      workspace = Path.join(System.tmp_dir!(), "context-trim-small-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      small_content = "# SPEC\n\nSmall spec."
      File.write!(Path.join(workspace, "SPEC.md"), small_content)

      DeliveryEngine.trim_auto_loaded_context_for_test(workspace)

      assert File.read!(Path.join(workspace, "SPEC.md")) == small_content
      refute File.exists?(Path.join(workspace, ".symphony/runtime/context_backups/SPEC.md"))
    end
  end
end
