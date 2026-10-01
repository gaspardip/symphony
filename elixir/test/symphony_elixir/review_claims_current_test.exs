defmodule SymphonyElixir.ReviewClaimsCurrentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentExecution, DispatchAudit, LeaseManager, RunStateStore}
  alias SymphonyElixir.DeliveryEngine.ReviewClaims

  # Real admission, lease and checked state; the owner only models the pre-session
  # protocol. Orchestrator custody/DOWN and remote GitHub are separate boundaries.
  defmodule Owner do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      context = %{ticket: opts.ticket, lease_token: opts.token, owner: self(), worker: opts.worker, issue_id: opts.issue.id}
      {:ok, %{context: context, authority: %{ticket: opts.ticket, lease_token: opts.token}, expected: RunStateStore.material_projection(opts.raw), terminal: nil, advances: []}}
    end

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}

    def handle_call({:agent_execution, invocation, expected, action}, {pid, _tag}, state) do
      true = pid == state.context.worker
      true = invocation == %{context: state.context, binding: nil, ordinal: 0}
      true = expected === state.expected

      if state.terminal do
        {:reply, {:stop, state.terminal}, state}
      else
        case action do
          {:confirm, nil, 0} ->
            reply =
              case RunStateStore.ensure_current(state.authority, expected) do
                {:ok, _current} -> :ok
                {:error, _reason} = error -> error
              end

            {:reply, reply, state}

          {:advance_current, ^expected, next} ->
            case RunStateStore.ensure_current(state.authority, next) do
              {:ok, _current} ->
                {:reply, :ok, %{state | expected: next, advances: state.advances ++ [{expected, next}]}}

              {:error, _reason} = error ->
                {:reply, error, state}
            end
        end
      end
    end

    @impl true
    def handle_info({:agent_execution_stale, context, ids, cause}, state) do
      true = context == state.context
      true = ids == %{run_id: context.ticket.run_id, dispatch_id: context.ticket.dispatch_id}
      {:noreply, %{state | terminal: state.terminal || {:stale_execution, ids, cause}}}
    end

    def handle_info({:agent_execution_uncertain, context, cause}, state) do
      true = context == state.context
      {:noreply, %{state | terminal: state.terminal || {:accounting_uncertain, cause}}}
    end
  end

  defmodule GitHub do
    def review_feedback(_workspace, opts) do
      observe(opts, :feedback, nil)

      comments =
        if opts[:feedback_mode] == :comment do
          [%{id: 1, body: "Please verify error handling in this file.", author: "reviewer", path: "lib/example.ex", line: 1, replies: []}]
        else
          []
        end

      {:ok, %{pr_url: opts[:pr_url], review_decision: "CHANGES_REQUESTED", reviews: [], comments: comments}}
    end

    def post_review_comment_reply(pr_url, comment_id, body, opts) do
      observe(opts, :post, {comment_id, body})
      if opts[:post_error], do: {:error, :fixture_network_failure}, else: {:ok, %{id: "reply-#{comment_id}", url: pr_url <> "#reply"}}
    end

    def resolve_review_comment_thread(_pr_url, comment_id, opts) do
      observe(opts, :resolve, comment_id)
      {:ok, %{thread_id: "thread-#{comment_id}", resolved: true}}
    end

    defp observe(opts, phase, detail) do
      send(Keyword.fetch!(opts, :test), {:github_call, phase, detail})
      Keyword.get(opts, :effect, fn _phase -> :ok end).(phase)
    end
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "review-current-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "REVIEW-1")
    issue = %Issue{id: "review-#{System.unique_integer([:positive])}", identifier: "REVIEW-1", state: "In Progress", source: :tracker}
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/example.ex"), "defmodule Example do\n  def value(value), do: value\nend\n")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, tracker_kind: "memory", company_policy_pack: "private_autopilot")
    pr_url = "https://github.com/example/repo/pull/1"

    threads = %{
      "comment:1" => %{
        "id" => "1",
        "draft_state" => "drafted",
        "draft_reply" => "Addressed on the branch.",
        "implementation_status" => "addressed",
        "resolution_recommendation" => "resolve_after_change"
      }
    }

    assert {:ok, _state} =
             RunStateStore.transition(workspace, "implement", %{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               pr_url: pr_url,
               repo_url: "https://github.com/example/repo",
               policy_pack: "private_autopilot",
               review_threads: threads,
               resume_context: %{already_learned: "before", target_paths: ["lib/example.ex"]}
             })

    assert {:ok, state} = RunStateStore.record_token_usage(workspace, issue, usage(3))
    on_exit(fn -> File.rm_rf!(root) end)
    base = %{root: root, workspace: workspace, issue: issue, state: state, pr_url: pr_url, threads: threads}

    if tags[:legacy] do
      base
    else
      assert {:ok, acquired} = LeaseManager.acquire(issue.id, issue.identifier, "review-current-owner")
      assert {:ok, _state} = RunStateStore.sync_lease(workspace, issue, LeaseManager.snapshot_for_state(acquired.lease))
      assert {:ok, source, view} = RunStateStore.read_admission_source(workspace, issue)

      assert {:ok, ticket, raw} =
               DispatchAudit.begin(
                 workspace,
                 %{issue_id: issue.id, issue_identifier: issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}},
                 source
               )

      authority = %{ticket: ticket, lease_token: acquired.token}
      assert {:ok, state} = RunStateStore.ensure_current(authority, RunStateStore.material_projection(raw))
      owner = start_supervised!({Owner, %{ticket: ticket, token: acquired.token, raw: raw, worker: self(), issue: issue}})
      Map.merge(base, %{state: state, ticket: ticket, raw: raw, token: acquired.token, authority: authority, owner: owner})
    end
  end

  for action <- [:feedback, :post, :resolve] do
    @entry_action action
    test "material control before #{@entry_action} prevents the GitHub call", c do
      ids = ids(c)

      assert {:stop, {:stale_execution, ^ids, :material_state_changed}} =
               within(c, fn ->
                 control!(c, "before-#{@entry_action}")
                 before = evidence(c)

                 result =
                   case @entry_action do
                     :feedback ->
                       ReviewClaims.maybe_persist_reconciled_review_feedback(c.state, c.workspace, opts(c))

                     :post ->
                       ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, c.state, opts(c))

                     :resolve ->
                       threads = put_in(c.threads, ["comment:1", "draft_state"], "posted")
                       ReviewClaims.maybe_resolve_autonomous_review_threads(threads, c.workspace, c.pr_url, c.state, opts(c))
                   end

                 assert result == {:stop, {:stale_execution, ids, :material_state_changed}}
                 assert evidence(c) == before
                 result
               end)

      refute_received {:github_call, _, _}
      assert GenServer.call(c.owner, :state).advances == []
    end
  end

  test "control during feedback prevents reconciliation from persisting", c do
    ids = ids(c)

    effect = fn :feedback ->
      control!(c, "during-feedback")
      send(self(), {:control_evidence, evidence(c)})
    end

    assert {:stop, {:stale_execution, ^ids, :material_state_changed}} =
             within(c, fn ->
               ReviewClaims.maybe_persist_reconciled_review_feedback(c.state, c.workspace, opts(c, feedback_mode: :comment, effect: effect))
             end)

    assert_received {:github_call, :feedback, nil}
    assert_received {:control_evidence, before}
    assert evidence(c) == before
    assert GenServer.call(c.owner, :state).advances == []
    refute_received {:github_call, :post, _}
    refute_received {:github_call, :resolve, _}
  end

  test "control after a posted reply prevents resolution and the following persistence", c do
    ids = ids(c)

    effect = fn
      :post ->
        intent = c.ticket.ledger_path |> File.read!() |> publication_rows!() |> List.last()
        assert intent["event_type"] == "review.publication.intent"
        send(self(), {:publication_intent, intent})
        control!(c, "after-post")
        send(self(), {:control_evidence, evidence(c)})

      _ ->
        :ok
    end

    assert {:stop, {:stale_execution, ^ids, :material_state_changed}} =
             within(c, fn ->
               ReviewClaims.maybe_maintain_merge_readiness(c.workspace, c.issue, c.state, %{pr_url: c.pr_url}, opts(c, effect: effect))
             end)

    assert_received {:github_call, :post, {"1", "Addressed on the branch."}}
    refute_received {:github_call, :post, _}
    refute_received {:github_call, :resolve, _}
    assert_received {:control_evidence, before}
    assert_received {:publication_intent, intent}
    after_effect = evidence(c)
    assert Map.delete(after_effect, :ledger) == Map.delete(before, :ledger)
    [observed] = publication_append!(before.ledger, after_effect.ledger)
    location = publication_rows!(before.ledger) |> Enum.find(&(&1["event_id"] == intent["metadata"]["location_event_id"]))
    assert_publication_location!(location, c)
    assert_publication_intent!(intent, location, c)
    assert_publication_observation!(observed, intent, c, "returned_success", nil, "reply-1", c.pr_url <> "#reply")
    assert raw!(c)["review_threads"] == c.raw["review_threads"]
    assert GenServer.call(c.owner, :state).advances == []
  end

  test "both checked writers preserve accepted usage, refreshed lease and fresh resume fields", c do
    refresh = fn amount, learned ->
      fn
        :feedback ->
          assert {:ok, precondition} = AgentExecution.workspace_precondition(c.workspace, c.issue)
          assert {:ok, _} = RunStateStore.record_token_usage_current(c.workspace, c.issue, usage(amount), precondition.authority, precondition.expected)
          assert {:ok, refreshed} = LeaseManager.refresh_token(c.token)
          assert {:ok, lease_state} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(refreshed))
          assert {:ok, _} = RunStateStore.update_current(precondition.authority, precondition.expected, %{resume_context: %{already_learned: learned, target_paths: ["lib/example.ex"]}})
          send(self(), {:fresh_lease, amount, Map.take(lease_state, lease_fields())})

        _ ->
          :ok
      end
    end

    assert :ok =
             within(c, fn ->
               persisted = ReviewClaims.maybe_persist_reconciled_review_feedback(c.state, c.workspace, opts(c, feedback_mode: :comment, effect: refresh.(77, "fresh-from-feedback")))
               assert is_map(persisted)
               assert persisted.token_usage == usage(77)
               assert persisted.resume_context.already_learned == "fresh-from-feedback"
               assert_received {:fresh_lease, 77, lease}
               assert Map.take(persisted, lease_fields()) == lease
               assert {:ok, maintained} = ReviewClaims.maybe_maintain_merge_readiness(c.workspace, c.issue, persisted, %{pr_url: c.pr_url}, opts(c, effect: refresh.(99, "fresh-from-maintenance")))
               assert maintained.token_usage == usage(99)
               assert maintained.resume_context.already_learned == "fresh-from-maintenance"
               assert_received {:fresh_lease, 99, next_lease}
               assert Map.take(maintained, lease_fields()) == next_lease
               assert {:ok, current} = AgentExecution.ensure_current()
               assert current == maintained
               assert GenServer.call(c.owner, :state).expected == RunStateStore.material_projection(maintained)
               assert length(GenServer.call(c.owner, :state).advances) == 2
               :ok
             end)
  end

  test "identified snapshot without an execution scope rejects before any GitHub effect", c do
    before = evidence(c)

    assert {:stop, {:accounting_uncertain, :execution_context_missing}} =
             ReviewClaims.maybe_maintain_merge_readiness(c.workspace, c.issue, c.state, %{pr_url: c.pr_url}, opts(c))

    assert evidence(c) == before
    refute_received {:github_call, _, _}
    assert GenServer.call(c.owner, :state).advances == []
  end

  @tag legacy: true
  test "legacy merge readiness still posts, resolves and returns its persisted result", c do
    assert {:ok, persisted} = ReviewClaims.maybe_maintain_merge_readiness(c.workspace, c.issue, c.state, %{pr_url: c.pr_url}, opts(c))
    assert_received {:github_call, :feedback, nil}
    assert_received {:github_call, :post, {"1", "Addressed on the branch."}}
    assert_received {:github_call, :resolve, "1"}
    assert persisted.review_threads["comment:1"]["draft_state"] == "posted"
    assert persisted.review_threads["comment:1"]["resolution_state"] == "resolved"
    assert persisted.token_usage == usage(3)
    assert persisted.resume_context.already_learned == "before"
    assert {:ok, ^persisted} = RunStateStore.load(c.workspace)
    refute Map.has_key?(raw!(c), "run_id")
  end

  test "an ordinary posting failure keeps the existing fallback while execution remains current", c do
    before = evidence(c)

    result =
      within(c, fn ->
        result = ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, c.state, opts(c, post_error: true))
        assert {:ok, _current} = AgentExecution.ensure_current()
        result
      end)

    assert_received {:github_call, :post, {"1", "Addressed on the branch."}}
    assert result["comment:1"]["draft_state"] == "approved_to_post"
    refute Map.has_key?(result["comment:1"], "posted_reply_id")
    after_effect = evidence(c)
    assert Map.delete(after_effect, :ledger) == Map.delete(before, :ledger)
    [location, intent, observed] = publication_append!(before.ledger, after_effect.ledger)
    assert_publication_location!(location, c)
    assert_publication_intent!(intent, location, c)
    assert_publication_observation!(observed, intent, c, "returned_error", "backend_error", nil, nil)
    assert GenServer.call(c.owner, :state).terminal == nil
    assert GenServer.call(c.owner, :state).advances == []
  end

  test "an uncertain observed post blocks replay without replacing the ordinary first-call fallback", c do
    first = within(c, fn -> ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, c.state, opts(c, post_error: true)) end)
    assert first["comment:1"]["draft_state"] == "approved_to_post"
    assert_received {:github_call, :post, {"1", "Addressed on the branch."}}
    retained = evidence(c)
    intent = publication_rows!(retained.ledger) |> Enum.find(&(&1["event_type"] == "review.publication.intent"))
    intent_id = intent["event_id"]

    assert {:error, {:review_publication_blocked, :attempt_uncertain, ^intent_id}} =
             within(c, fn -> ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, c.state, opts(c)) end)

    refute_received {:github_call, :post, _}
    assert evidence(c) == retained
    assert GenServer.call(c.owner, :state).terminal == nil
    assert GenServer.call(c.owner, :state).advances == []
  end

  test "a confirmed real reply is rediscovered under current permission without posting it twice", c do
    first = within(c, fn -> ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, c.state, opts(c)) end)
    assert first["comment:1"]["draft_state"] == "posted"
    assert first["comment:1"]["posted_reply_id"] == "reply-1"
    assert first["comment:1"]["posted_reply_url"] == c.pr_url <> "#reply"
    assert_received {:github_call, :post, {"1", "Addressed on the branch."}}
    retained = evidence(c)

    second = within(c, fn -> ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, c.state, opts(c)) end)

    assert second == first
    refute_received {:github_call, :post, _}
    assert evidence(c) == retained
    assert raw!(c)["review_threads"] == c.raw["review_threads"]
    assert GenServer.call(c.owner, :state).advances == []
  end

  @tag legacy: true
  test "a pending legacy publication still blocks after genuine identified admission", c do
    first = ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, c.state, opts(c, post_error: true))
    assert first["comment:1"]["draft_state"] == "approved_to_post"
    assert_received {:github_call, :post, {"1", "Addressed on the branch."}}
    path = SymphonyElixir.RunLedger.ledger_file_path()
    intent = path |> File.read!() |> publication_rows!() |> Enum.find(&(&1["event_type"] == "review.publication.intent"))
    assert intent["metadata"]["binding"] == %{}
    assert intent["metadata"]["dispatch_id"] == nil
    intent_id = intent["event_id"]

    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "review-publication-successor")
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(acquired.lease))
    assert {:ok, source, view} = RunStateStore.read_admission_source(c.workspace, c.issue)

    assert {:ok, ticket, raw} =
             DispatchAudit.begin(
               c.workspace,
               %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}},
               source
             )

    authority = %{ticket: ticket, lease_token: acquired.token}
    assert {:ok, state} = RunStateStore.ensure_current(authority, RunStateStore.material_projection(raw))
    owner = start_supervised!({Owner, %{ticket: ticket, token: acquired.token, raw: raw, worker: self(), issue: c.issue}})
    identified = Map.merge(c, %{state: state, ticket: ticket, raw: raw, token: acquired.token, authority: authority, owner: owner})
    retained = evidence(identified)
    assert is_binary(raw["run_id"])
    assert raw["run_id"] == ticket.run_id

    assert {:error, {:review_publication_blocked, :attempt_uncertain, ^intent_id}} =
             within(identified, fn -> ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, state, opts(c)) end)

    refute_received {:github_call, :post, _}
    assert evidence(identified) == retained
    assert GenServer.call(owner, :state).terminal == nil
    assert GenServer.call(owner, :state).advances == []
  end

  @tag legacy: true
  test "a genuine new identified binding cannot adopt a successful legacy reply", c do
    first = ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, c.state, opts(c))
    assert first["comment:1"]["posted_reply_id"] == "reply-1"
    assert_received {:github_call, :post, {"1", "Addressed on the branch."}}
    assert {:ok, acquired} = LeaseManager.acquire(c.issue.id, c.issue.identifier, "review-publication-new-binding")
    assert {:ok, _} = RunStateStore.sync_lease(c.workspace, c.issue, LeaseManager.snapshot_for_state(acquired.lease))
    assert {:ok, source, view} = RunStateStore.read_admission_source(c.workspace, c.issue)

    assert {:ok, ticket, raw} =
             DispatchAudit.begin(
               c.workspace,
               %{issue_id: c.issue.id, issue_identifier: c.issue.identifier, stage: view.stage, metadata: %{owner: acquired.token.owner, epoch: acquired.token.epoch}},
               source
             )

    authority = %{ticket: ticket, lease_token: acquired.token}
    assert {:ok, state} = RunStateStore.ensure_current(authority, RunStateStore.material_projection(raw))
    owner = start_supervised!({Owner, %{ticket: ticket, token: acquired.token, raw: raw, worker: self(), issue: c.issue}})
    identified = Map.merge(c, %{state: state, ticket: ticket, raw: raw, token: acquired.token, authority: authority, owner: owner})
    before = evidence(identified)

    assert {:error, {:review_publication_blocked, :binding_changed, id}} =
             within(identified, fn ->
               ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, c.pr_url, state, opts(c))
             end)

    assert is_binary(id)
    assert evidence(identified) == before
    assert GenServer.call(owner, :state).advances == []
    refute_receive {:github_call, :post, _}, 30
  end

  # These are independent expected protocol rows. No production formatter or
  # normalizer computes the oracle; historical bytes must remain an exact prefix.
  defp publication_append!(before, after_effect) do
    assert byte_size(after_effect) > byte_size(before)
    assert binary_part(after_effect, 0, byte_size(before)) == before
    suffix = binary_part(after_effect, byte_size(before), byte_size(after_effect) - byte_size(before))
    publication_rows!(suffix)
  end

  test "identified execution can publish its caller PR result before the next RAW checkpoint", c do
    original = evidence(c)
    new_pr = "https://github.com/example/repo/pull/2"

    assert %{"comment:1" => posted} =
             within(c, fn ->
               ReviewClaims.maybe_post_autonomous_review_replies(c.threads, c.workspace, new_pr, c.state, opts(c))
             end)

    assert posted["posted_reply_url"] == new_pr <> "#reply"
    assert_received {:github_call, :post, {"1", "Addressed on the branch."}}
    assert Map.delete(evidence(c), :ledger) == Map.delete(original, :ledger)
    rows = publication_rows!(File.read!(c.ticket.ledger_path))
    [intent] = Enum.filter(rows, &(&1["event_type"] == "review.publication.intent"))
    assert intent["metadata"]["pr_source"] == "caller_result"
    assert intent["metadata"]["raw_pr"] == %{"pr_url" => c.pr_url}
    assert intent["metadata"]["pr_identity"] == %{"host" => "github.com", "owner" => "example", "repo" => "repo", "number" => 2}
    assert intent["metadata"]["binding"] == Map.take(c.raw, ~w(run_id run_identity_event_id run_identity_ledger_path))
    assert GenServer.call(c.owner, :state).advances == []
  end

  defp publication_rows!(bytes) do
    assert String.ends_with?(bytes, "\n")
    bytes |> String.split("\n") |> Enum.drop(-1) |> Enum.map(&Jason.decode!/1)
  end

  defp assert_publication_envelope!(entry, type, c) do
    assert is_map(entry)
    assert entry["schema_version"] == 1
    assert entry["event"] == type
    assert entry["event_type"] == type
    assert entry["issue_id"] == c.issue.id
    assert entry["issue_identifier"] == c.issue.identifier
    assert is_binary(entry["event_id"]) and entry["event_id"] != ""
    assert {:ok, _, 0} = DateTime.from_iso8601(entry["at"])
  end

  defp assert_publication_location!(location, c) do
    assert_publication_envelope!(location, "review.publication.location", c)
    anchor_name = ".review-publication-" <> Base.encode16(:crypto.hash(:sha256, c.issue.id), case: :lower) <> ".json"

    assert location["metadata"] == %{
             "publication_version" => 1,
             "workspace_root" => c.root,
             "workspace" => c.workspace,
             "ledger_path" => c.ticket.ledger_path,
             "anchor_name" => anchor_name
           }
  end

  defp publication_identity(c, location_id) do
    %{
      "publication_version" => 1,
      "location_event_id" => location_id,
      "workspace" => c.workspace,
      "pr_url" => c.pr_url,
      "pr_identity" => %{"host" => "github.com", "owner" => "example", "repo" => "repo", "number" => 1},
      "pr_source" => "caller_result",
      "raw_pr" => Map.take(c.raw, ["pr_url"]),
      "thread_key" => "comment:1",
      "operation" => "post",
      "reply_target" => "1",
      "draft_sha256" => Base.encode16(:crypto.hash(:sha256, "Addressed on the branch."), case: :lower),
      "binding" => Map.take(c.raw, ~w(run_id run_identity_event_id run_identity_ledger_path)),
      "dispatch_id" => c.ticket.dispatch_id
    }
  end

  defp assert_publication_intent!(intent, location, c) do
    assert_publication_envelope!(intent, "review.publication.intent", c)
    observation_id = intent["metadata"]["observation_event_id"]
    assert is_binary(observation_id) and observation_id != ""
    assert observation_id != intent["event_id"]
    assert intent["event_id"] != location["event_id"]
    assert intent["metadata"] == Map.put(publication_identity(c, location["event_id"]), "observation_event_id", observation_id)
  end

  defp assert_publication_observation!(observed, intent, c, outcome, cause, reply_id, reply_url) do
    assert_publication_envelope!(observed, "review.publication.observed", c)
    assert observed["event_id"] == intent["metadata"]["observation_event_id"]

    assert observed["metadata"] ==
             Map.merge(
               publication_identity(c, intent["metadata"]["location_event_id"]),
               %{
                 "intent_event_id" => intent["event_id"],
                 "outcome" => outcome,
                 "cause" => cause,
                 "posted_reply_id" => reply_id,
                 "posted_reply_url" => reply_url,
                 "posted_at" => if(outcome == "returned_success", do: observed["at"], else: nil)
               }
             )
  end

  defp within(c, fun), do: DispatchAudit.with_authorization(c.ticket, fn -> AgentExecution.with_context(c.ticket, c.token, c.owner, c.raw, fun) end)
  defp opts(c, extra \\ []), do: [github_client: GitHub, github_client_opts: Keyword.merge([test: self(), pr_url: c.pr_url], extra)]
  defp ids(c), do: %{run_id: c.ticket.run_id, dispatch_id: c.ticket.dispatch_id}
  defp usage(n), do: %{input_tokens: n, output_tokens: 0, total_tokens: n}
  defp raw!(c), do: c.workspace |> RunStateStore.state_path() |> File.read!() |> Jason.decode!()
  defp control!(c, value), do: assert({:ok, _} = RunStateStore.update(c.workspace, &Map.put(&1, :policy_override, value)))

  defp evidence(c),
    do: %{
      state: File.read!(RunStateStore.state_path(c.workspace)),
      lease: File.read!(c.token.storage.lease_path),
      ledger: File.read!(c.ticket.ledger_path),
      marker: File.read!(Path.join(DispatchAudit.marker_directory(c.workspace), "marker.json"))
    }

  defp lease_fields, do: [:lease_owner, :lease_owner_instance_id, :lease_owner_channel, :lease_acquired_at, :lease_updated_at, :lease_status, :lease_epoch, :lease_version, :lease_generation]
end
