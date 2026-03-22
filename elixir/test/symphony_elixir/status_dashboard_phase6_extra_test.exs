defmodule SymphonyElixir.StatusDashboardPhase6ExtraTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StatusDashboard

  defmodule SnapshotStub do
    use GenServer

    def start_link(snapshot_reply) do
      GenServer.start_link(__MODULE__, snapshot_reply, name: SymphonyElixir.Orchestrator)
    end

    def init(snapshot_reply), do: {:ok, snapshot_reply}

    def handle_call(:snapshot, _from, snapshot_reply) when is_function(snapshot_reply, 0) do
      {:reply, snapshot_reply.(), snapshot_reply}
    end

    def handle_call(:snapshot, _from, snapshot_reply) do
      {:reply, snapshot_reply, snapshot_reply}
    end
  end

  test "start_link honors a custom name and remains disabled under test defaults" do
    dashboard_name = Module.concat(__MODULE__, :StartedDashboard)

    {:ok, pid} = StatusDashboard.start_link(name: dashboard_name, render_fun: fn _content -> :ok end)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert Process.whereis(dashboard_name) == pid
    assert :sys.get_state(pid).enabled == false
  end

  test "disabled callbacks and stale flush timers leave dashboard state unchanged" do
    parent = self()
    state = dashboard_state(enabled: false, render_fun: fn content -> send(parent, {:rendered, content}) end)

    assert {:noreply, ^state} = StatusDashboard.handle_info(:tick, state)
    assert {:noreply, ^state} = StatusDashboard.handle_info(:refresh, state)
    assert {:noreply, ^state} = StatusDashboard.handle_info({:flush_render, make_ref()}, state)

    refute_receive {:rendered, _content}, 20
    refute_receive :tick, 20
  end

  test "flush renders clear empty timers and recover from render failures" do
    parent = self()
    flush_ref = make_ref()

    empty_pending_state =
      dashboard_state(
        enabled: true,
        flush_timer_ref: flush_ref,
        pending_content: nil,
        render_fun: fn content -> send(parent, {:unexpected_render, content}) end
      )

    assert {:noreply, cleared_state} =
             StatusDashboard.handle_info({:flush_render, flush_ref}, empty_pending_state)

    assert cleared_state.flush_timer_ref == nil
    assert cleared_state.pending_content == nil
    refute_receive {:unexpected_render, _content}, 20

    assert {:noreply, ^cleared_state} =
             StatusDashboard.handle_info({:flush_render, make_ref()}, cleared_state)

    failing_ref = make_ref()

    failing_state =
      dashboard_state(
        enabled: true,
        flush_timer_ref: failing_ref,
        pending_content: "frame",
        render_fun: fn _content -> raise RuntimeError, "frame exploded" end
      )

    log =
      capture_log(fn ->
        assert {:noreply, recovered_state} =
                 StatusDashboard.handle_info({:flush_render, failing_ref}, failing_state)

        assert recovered_state.flush_timer_ref == nil
        assert recovered_state.pending_content == nil
      end)

    assert log =~ "Failed rendering terminal dashboard frame"
  end

  test "refresh handles unavailable snapshots, prunes samples, dedupes unchanged output, and rerenders when idle" do
    without_orchestrator(fn ->
      parent = self()
      now_ms = System.monotonic_time(:millisecond)

      state =
        dashboard_state(
          enabled: true,
          enabled_override: true,
          refresh_ms: 5_000,
          refresh_ms_override: 5_000,
          render_interval_ms: 1,
          render_interval_ms_override: 1,
          render_fun: fn content -> send(parent, {:rendered, content}) end,
          token_samples: [{now_ms - 10_000, 10}, {now_ms - 500, 20}]
        )

      assert {:noreply, %StatusDashboard{} = first_state} =
               StatusDashboard.handle_info(:refresh, state)

      assert_receive {:rendered, first_content}, 100
      assert first_content =~ "Orchestrator snapshot unavailable"
      assert first_state.last_snapshot_fingerprint == :error
      assert Enum.all?(first_state.token_samples, fn {timestamp, _tokens} -> timestamp >= now_ms - 5_000 end)
      assert length(first_state.token_samples) == 1

      deduped_state = %StatusDashboard{
        first_state
        | last_rendered_at_ms: System.monotonic_time(:millisecond),
          last_rendered_content: first_content
      }

      assert {:noreply, _same_state} = StatusDashboard.handle_info(:refresh, deduped_state)
      refute_receive {:rendered, _content}, 20

      overdue_state = %StatusDashboard{
        deduped_state
        | last_rendered_at_ms: System.monotonic_time(:millisecond) - 1_500,
          last_rendered_content: "stale frame"
      }

      assert {:noreply, rerendered_state} = StatusDashboard.handle_info(:refresh, overdue_state)
      assert_receive {:rendered, second_content}, 100
      assert second_content == first_content
      assert rerendered_state.last_snapshot_fingerprint == :error
    end)
  end

  test "refresh handles malformed orchestrator snapshots and unusual running payloads" do
    with_orchestrator_stub(%{running: :bad, retrying: [], agent_totals: %{}}, fn ->
      parent = self()

      state =
        dashboard_state(
          enabled: true,
          enabled_override: true,
          render_fun: fn content -> send(parent, {:rendered, content}) end
        )

      assert {:noreply, malformed_state} = StatusDashboard.handle_info(:refresh, state)
      assert_receive {:rendered, content}, 100
      assert content =~ "Orchestrator snapshot unavailable"
      assert malformed_state.last_snapshot_fingerprint == :error
    end)

    with_orchestrator_stub(
      %{
        running: [
          %{
            identifier: "MT-BAD",
            state: "running",
            session_id: "thread-bad",
            agent_process_id: "4242",
            agent_total_tokens: 0,
            runtime_seconds: 0,
            last_agent_event: :notification,
            last_agent_message: <<255>>
          }
        ],
        retrying: [],
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      },
      fn ->
        parent = self()

        state =
          dashboard_state(
            enabled: true,
            enabled_override: true,
            render_fun: fn content -> send(parent, {:rendered_unusual, content}) end
          )

        assert {:noreply, unusual_state} = StatusDashboard.handle_info(:refresh, state)
        assert_receive {:rendered_unusual, rendered_content}, 100
        assert strip_ansi(rendered_content) =~ "MT-BAD"
        assert strip_ansi(unusual_state.last_rendered_content) =~ "MT-BAD"
      end
    )
  end

  test "refresh covers periodic rerender, helper fallbacks, flush scheduling, and queued refs" do
    with_orchestrator_stub(minimal_snapshot(), fn ->
      parent = self()
      snapshot_data = minimal_snapshot_data()
      content = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

      periodic_state =
        dashboard_state(
          enabled: true,
          enabled_override: true,
          last_snapshot_fingerprint: snapshot_data,
          last_rendered_at_ms: nil,
          last_rendered_content: "older frame",
          render_fun: fn frame -> send(parent, {:rendered, frame}) end
        )

      assert {:noreply, _periodic_result} = StatusDashboard.handle_info(:refresh, periodic_state)
      assert_receive {:rendered, ^content}, 100

      fallback_state =
        dashboard_state(
          enabled: true,
          enabled_override: true,
          last_snapshot_fingerprint: snapshot_data,
          last_rendered_at_ms: :unknown,
          render_fun: fn frame -> send(parent, {:unexpected_render, frame}) end
        )

      assert {:noreply, fallback_result} = StatusDashboard.handle_info(:refresh, fallback_state)
      assert fallback_result.last_rendered_at_ms == :unknown
      assert fallback_result.flush_timer_ref == nil
      assert fallback_result.last_snapshot_fingerprint == snapshot_data
      refute_receive {:unexpected_render, _frame}, 20

      deduped_state =
        dashboard_state(
          enabled: true,
          enabled_override: true,
          last_snapshot_fingerprint: :stale,
          last_rendered_at_ms: System.monotonic_time(:millisecond),
          last_rendered_content: content,
          render_fun: fn frame -> send(parent, {:duplicate_render, frame}) end
        )

      assert {:noreply, deduped_result} = StatusDashboard.handle_info(:refresh, deduped_state)
      assert deduped_result.last_snapshot_fingerprint == snapshot_data
      refute_receive {:duplicate_render, _frame}, 20

      queued_state =
        dashboard_state(
          enabled: true,
          enabled_override: true,
          last_snapshot_fingerprint: :stale,
          last_rendered_at_ms: nil,
          last_rendered_content: "stale frame",
          flush_timer_ref: :queued,
          render_interval_ms: 1_000,
          render_interval_ms_override: 1_000,
          render_fun: fn frame -> send(parent, {:queued_render, frame}) end
        )

      assert {:noreply, queued_result} = StatusDashboard.handle_info(:refresh, queued_state)
      assert is_reference(queued_result.flush_timer_ref)
      assert queued_result.pending_content == content
      refute_receive {:queued_render, _frame}, 20
      assert_receive {:flush_render, queued_ref}, 50
      assert queued_ref == queued_result.flush_timer_ref

      existing_ref = make_ref()

      existing_timer_state =
        dashboard_state(
          enabled: true,
          enabled_override: true,
          last_snapshot_fingerprint: :stale,
          last_rendered_at_ms: :pending,
          last_rendered_content: "stale frame",
          flush_timer_ref: existing_ref,
          render_fun: fn frame -> send(parent, {:existing_ref_render, frame}) end
        )

      assert {:noreply, existing_timer_result} =
               StatusDashboard.handle_info(:refresh, existing_timer_state)

      assert existing_timer_result.flush_timer_ref == existing_ref
      assert existing_timer_result.pending_content == content
      refute_receive {:existing_ref_render, _frame}, 20
    end)
  end

  test "tick renders and schedules the next refresh when the dashboard is enabled" do
    without_orchestrator(fn ->
      parent = self()

      state =
        dashboard_state(
          enabled: true,
          enabled_override: true,
          refresh_ms: 1,
          refresh_ms_override: 1,
          render_interval_ms: 1,
          render_interval_ms_override: 1,
          render_fun: fn content -> send(parent, {:rendered, content}) end
        )

      assert {:noreply, _next_state} = StatusDashboard.handle_info(:tick, state)
      assert_receive {:rendered, content}, 100
      assert content =~ "Orchestrator snapshot unavailable"
      assert_receive :tick, 100
    end)
  end

  test "snapshot formatting covers rate limit fallbacks, retry sanitization, and countdown normalization" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           %{issue_id: "issue-fast", identifier: "MT-FAST", attempt: 2, due_in_ms: 1_500, error: "line1\nline2"},
           %{issue_id: "issue-unknown", identifier: nil, attempt: 0, due_in_ms: "soon", error: "   "}
         ],
         agent_totals: %{input_tokens: 1200, output_tokens: 450, total_tokens: 1650, seconds_running: 75},
         rate_limits: %{
           limit_name: "codex",
           primary: %{remaining: 5, reset_in_seconds: 3},
           secondary: %{limit: 10, resetsAt: "soon"},
           credits: %{has_credits: true}
         },
         polling: %{next_poll_in_ms: -10}
       }}

    rendered =
      snapshot_data
      |> StatusDashboard.format_snapshot_content_for_test(12.9, 96)
      |> strip_ansi()

    assert rendered =~
             "Rate Limits: codex | primary remaining 5 reset 3s | secondary limit 10 reset soon | credits available"

    assert rendered =~ "Next refresh: 0s"
    assert rendered =~ "MT-FAST attempt=2 in 1.500s error=line1 line2"
    assert rendered =~ "issue-unknown attempt=0 in n/a"
    refute rendered =~ "error=   "
  end

  test "snapshot formatting covers project, running row, rate limit, and graph fallbacks" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    snapshot_data =
      {:ok,
       %{
         running: [
           %{
             identifier: "MT-NONE",
             state: nil,
             session_id: nil,
             agent_process_id: nil,
             agent_total_tokens: "abc",
             runtime_seconds: "warming",
             turn_count: 0,
             last_agent_event: :none,
             last_agent_message: nil
           }
         ],
         retrying: [],
         agent_totals: %{input_tokens: nil, output_tokens: "4500", total_tokens: 12.5, seconds_running: nil},
         rate_limits: %{
           limit_id: "limit-a",
           primary: %{},
           secondary: :secondary,
           credits: nil
         },
         polling: nil
       }}

    rendered =
      snapshot_data
      |> StatusDashboard.format_snapshot_content_for_test(12.9, 96)
      |> strip_ansi()

    assert rendered =~ "Project: n/a"
    assert rendered =~ "Runtime: 0m 0s"
    assert rendered =~ "Tokens: in 0 | out 4,500 | total 12.5"
    assert rendered =~ "Rate Limits: limit-a | primary n/a | secondary secondary | credits n/a"
    assert rendered =~ "MT-NONE"
    assert rendered =~ "unknown"
    assert rendered =~ "warming"
    assert rendered =~ "abc"
    assert rendered =~ "no agent message yet"

    assert StatusDashboard.dashboard_url_for_test(" example.internal ", 4040, nil) ==
             "http://example.internal:4040/"

    assert StatusDashboard.format_tps_for_test(12) == "12"
    assert StatusDashboard.format_tps_for_test(-1200.7) == "1,200-"
    assert StatusDashboard.tps_graph_for_test([{10_000, 50}], 20_000, 10) == String.duplicate("▁", 24)
  end

  test "snapshot formatting covers alternate rate limit and credit shapes" do
    snapshot_with_balances =
      {:ok,
       %{
         running: [],
         retrying: [%{issue_id: "issue-map", identifier: "MT-MAP", attempt: 1, due_in_ms: 250, error: %{}}],
         agent_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 4},
         rate_limits: %{
           limit_name: "mixed",
           primary: %{remaining: 5, limit: 9, reset_at: :later},
           secondary: %{foo: "bar"},
           credits: %{has_credits: true, balance: 7}
         },
         polling: %{checking?: true}
       }}

    rendered_with_balances =
      snapshot_with_balances
      |> StatusDashboard.format_snapshot_content_for_test(0.0, 96)
      |> strip_ansi()

    assert rendered_with_balances =~ "Next refresh: checking now"

    assert rendered_with_balances =~
             "Rate Limits: mixed | primary 5/9 reset later | secondary %{foo: \"bar\"} | credits 7"

    assert rendered_with_balances =~ "MT-MAP attempt=1 in 0.250s"

    snapshot_with_other_credits =
      {:ok,
       %{
         running: [],
         retrying: [%{issue_id: "issue-nonbinary", identifier: "MT-NONBINARY", attempt: 1, due_in_ms: 0, error: %{reason: :oops}}],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: %{
           limit_name: "credits-other",
           primary: %{remaining: 1, reset_at: "soon"},
           secondary: %{limit: 3},
           credits: "blocked"
         },
         polling: nil
       }}

    rendered_with_other_credits =
      snapshot_with_other_credits
      |> StatusDashboard.format_snapshot_content_for_test(0.0, 96)
      |> strip_ansi()

    assert rendered_with_other_credits =~
             "Rate Limits: credits-other | primary remaining 1 reset soon | secondary limit 3 | credits blocked"

    refute rendered_with_other_credits =~ "error="
  end

  test "humanize helpers cover account events, tool aliases, wrapper updates, and token summaries" do
    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "thread/started",
               "params" => %{"thread" => %{"id" => "thread-42"}}
             }
           }) == "thread started (thread-42)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "tool/requestUserInput",
               "params" => %{"prompt" => "Proceed?"}
             }
           }) == "tool requires user input: Proceed?"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "account/updated",
               "params" => %{"authMode" => "chatgpt"}
             }
           }) == "account updated (auth chatgpt)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "account/rateLimits/updated",
               "params" => %{
                 "rateLimits" => %{
                   "primary" => %{"usedPercent" => 40.5, "windowDurationMins" => 5},
                   "secondary" => %{"usedPercent" => 10}
                 }
               }
             }
           }) == "rate limits updated: primary 40.5% / 5m; secondary 10% used"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{"method" => "account/chatgptAuthTokens/refresh"}
           }) == "account auth token refresh requested"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "codex/event/mcp_startup_update",
               "params" => %{"msg" => %{"server" => "linear", "status" => %{"state" => "ready"}}}
             }
           }) == "mcp startup: linear ready"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{"method" => "codex/event/mcp_startup_complete"}
           }) == "mcp startup complete"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "codex/event/item_started",
               "params" => %{"msg" => %{"payload" => %{"type" => "fileChange"}}}
             }
           }) == "item started (file change)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "codex/event/item_completed",
               "params" => %{
                 "msg" => %{
                   "payload" => %{"type" => "token_count"},
                   "info" => %{"total_token_usage" => %{"input_tokens" => "4", "output_tokens" => 2, "total_tokens" => 6}}
                 }
               }
             }
           }) == "token count update (in 4, out 2, total 6)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "codex/event/exec_command_end",
               "params" => %{"msg" => %{"exitCode" => 2}}
             }
           }) == "command completed (exit 2)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               "method" => "codex/event/reasoning_content_delta",
               "params" => %{"msg" => %{"payload" => %{"content" => "  keep\nthinking  "}}}
             }
           }) == "reasoning content streaming: keep thinking"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{"method" => "turn/cancelled"}
           }) == "turn cancelled"
  end

  test "humanize helpers cover event fallbacks, payload fallback text, and binary cleanup" do
    assert StatusDashboard.humanize_agent_message(nil) == "no agent message yet"

    assert StatusDashboard.humanize_agent_message(%{
             event: :approval_auto_approved,
             message: %{
               reason: "ignored",
               payload: %{"method" => "item/tool/call", "params" => %{"tool" => "linear_graphql"}},
               decision: "acceptForSession"
             }
           }) == "dynamic tool call requested (auto-approved): acceptForSession"

    assert StatusDashboard.humanize_agent_message(%{
             event: :approval_auto_approved,
             message: %{decision: "accept"}
           }) == "approval request auto-approved: accept"

    assert StatusDashboard.humanize_agent_message(%{
             event: :turn_ended_with_error,
             message: %{foo: "bar"}
           }) == "turn ended with error: %{foo: \"bar\"}"

    assert StatusDashboard.humanize_agent_message(%{
             event: :startup_failed,
             message: %{reason: %{message: "bad auth"}}
           }) == "startup failed: bad auth"

    assert StatusDashboard.humanize_agent_message(%{
             event: :turn_cancelled,
             message: %{}
           }) == "turn cancelled"

    assert StatusDashboard.humanize_agent_message(%{
             event: :malformed,
             message: %{}
           }) == "malformed JSON event from agent"

    assert StatusDashboard.humanize_agent_message(%{message: %{session_id: "sess-inline"}}) ==
             "session started (sess-inline)"

    assert StatusDashboard.humanize_agent_message(%{message: %{foo: "bar"}}) == "%{foo: \"bar\"}"
    assert StatusDashboard.humanize_agent_message(" \e[31mhello\nthere\0 ") == "hello there"
  end

  test "humanize helpers cover atom keyed methods, wrapper defaults, and command normalization" do
    assert StatusDashboard.humanize_agent_message(%{
             message: %{
               method: "turn/completed",
               params: %{turn: %{status: "done"}, usage: %{input_tokens: "5", output_tokens: 1, total_tokens: 6}}
             }
           }) == "turn completed (done) (in 5, out 1, total 6)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "turn/failed", params: %{error: %{message: "exploded"}}}
           }) == "turn failed: exploded"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "turn/diff/updated", params: %{diff: "a\nb\nc"}}
           }) == "turn diff updated (3 lines)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "turn/plan/updated", params: %{steps: [%{}, %{}]}}
           }) == "plan updated (2 steps)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "item/tool/requestUserInput", params: %{question: "Continue now?"}}
           }) == "tool requires user input: Continue now?"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "account/updated", params: %{authMode: "api_key"}}
           }) == "account updated (auth api_key)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "account/rateLimits/updated", params: %{rateLimits: %{primary: %{usedPercent: 75}}}}
           }) == "rate limits updated: primary 75% used"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "thread/tokenUsage/updated", params: %{tokenUsage: %{total: %{}}}}
           }) == "thread token usage updated"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "custom/event", params: %{msg: %{type: "delta"}}}
           }) == "custom/event (delta)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/task_started"}
           }) == "task started"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/user_message"}
           }) == "user message received"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/item_started", params: %{msg: %{payload: %{type: "token_count"}}}}
           }) == "token count update"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/item_completed", params: %{msg: %{payload: %{}}}}
           }) == "item completed"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/agent_reasoning_delta", params: %{msg: %{payload: %{text: "  compare\npaths  "}}}}
           }) == "reasoning streaming: compare paths"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/agent_reasoning_section_break"}
           }) == "reasoning section break"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/turn_diff"}
           }) == "turn diff updated"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/exec_command_output_delta"}
           }) == "command output streaming"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/mcp_tool_call_begin"}
           }) == "mcp tool call started"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/mcp_tool_call_end"}
           }) == "mcp tool call completed"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/other", params: %{msg: %{type: "shell"}}}
           }) == "other (shell)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/other", params: %{}}
           }) == "other"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/exec_command_begin", params: %{msg: %{parsed_cmd: %{command: "mix", args: ["test", "--seed", "0"]}}}}
           }) == "mix test --seed 0"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "codex/event/exec_command_begin", params: %{msg: %{parsed_cmd: %{command: "mix", args: [1, 2]}}}}
           }) == "command started"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "item/commandExecution/requestApproval", params: %{argv: ["mix", "format", "lib"]}}
           }) == "command approval requested (mix format lib)"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "item/fileChange/requestApproval", params: %{fileChangeCount: 0}}
           }) == "file change approval requested"

    assert StatusDashboard.humanize_agent_message(%{
             event: :tool_call_completed,
             message: %{payload: %{method: "item/tool/call", params: %{tool: "   "}}}
           }) == "dynamic tool call completed"

    assert StatusDashboard.humanize_agent_message(%{
             event: :tool_call_failed,
             message: %{payload: %{}}
           }) == "dynamic tool call failed"

    assert StatusDashboard.humanize_agent_message(%{
             message: %{method: "item/completed", params: %{item: %{type: :sync}}}
           }) == "item completed: sync"
  end

  test "helper seams cover formatting, parsing, and environment fallback branches" do
    assert StatusDashboard.helper_for_test(:dashboard_url_host, ["[2001:db8::1]"]) == "[2001:db8::1]"

    previous_columns = System.get_env("COLUMNS")

    on_exit(fn ->
      if is_binary(previous_columns) do
        System.put_env("COLUMNS", previous_columns)
      else
        System.delete_env("COLUMNS")
      end
    end)

    System.put_env("COLUMNS", "144")
    assert StatusDashboard.helper_for_test(:terminal_columns_from_env, []) == 144
    System.put_env("COLUMNS", "bogus")
    assert StatusDashboard.helper_for_test(:terminal_columns_from_env, []) == 115

    assert StatusDashboard.helper_for_test(:format_cell, ["line\nbreak", 8]) == "line ..."
    assert StatusDashboard.helper_for_test(:truncate_plain, ["abcdefghijklmnopqrstuvwxyz", 8]) == "abcde..."
    assert StatusDashboard.helper_for_test(:compact_session_id, [123]) == "n/a"
    assert StatusDashboard.helper_for_test(:group_thousands, ["-1200"]) == "1,200-"
    assert StatusDashboard.helper_for_test(:format_rate_limits_summary, [nil]) == "n/a"
    assert StatusDashboard.helper_for_test(:format_rate_limits_summary, ["oops"]) == "n/a"
    assert StatusDashboard.helper_for_test(:format_rate_limit_bucket_summary, [%{"usedPercent" => 12.5}]) == "12.5% used"
    assert StatusDashboard.helper_for_test(:format_rate_limit_bucket_summary, [%{}]) == nil
    assert StatusDashboard.helper_for_test(:format_reason, ["boom"]) == "\"boom\""
    assert StatusDashboard.helper_for_test(:normalize_command, [%{"command" => "git", "args" => ["status"]}]) == "git status"
    assert StatusDashboard.helper_for_test(:normalize_command, [[1, 2]]) == nil
    assert StatusDashboard.helper_for_test(:inline_text, [123]) == "123"
    assert StatusDashboard.helper_for_test(:parse_integer, ["bogus"]) == nil
    assert StatusDashboard.helper_for_test(:map_path, ["oops", ["params"]]) == nil
    assert StatusDashboard.helper_for_test(:alternate_key, ["not_an_existing_atom"]) == "not_an_existing_atom"
    assert StatusDashboard.helper_for_test(:alternate_key, [:status]) == "status"
    assert StatusDashboard.helper_for_test(:truncate, ["abcdefghijklmnopqrstuvwxyz", 10]) == "abcdefghij..."
    assert is_boolean(StatusDashboard.helper_for_test(:dashboard_enabled, []))
  end

  defp dashboard_state(overrides) do
    defaults = %StatusDashboard{
      refresh_ms: 10_000,
      enabled: false,
      render_interval_ms: 16,
      refresh_ms_override: nil,
      enabled_override: nil,
      render_interval_ms_override: nil,
      render_fun: fn _content -> :ok end,
      token_samples: [],
      last_tps_second: nil,
      last_tps_value: nil,
      last_rendered_content: nil,
      last_rendered_at_ms: nil,
      pending_content: nil,
      flush_timer_ref: nil,
      last_snapshot_fingerprint: nil
    }

    Enum.reduce(overrides, defaults, fn {key, value}, state ->
      Map.put(state, key, value)
    end)
  end

  defp without_orchestrator(fun) when is_function(fun, 0) do
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)
    had_orchestrator? = is_pid(orchestrator_pid)

    if had_orchestrator? do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    try do
      fun.()
    after
      if had_orchestrator? and is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end
  end

  defp with_orchestrator_stub(snapshot_reply, fun) when is_function(fun, 0) do
    without_orchestrator(fn ->
      {:ok, pid} = SnapshotStub.start_link(snapshot_reply)

      try do
        fun.()
      after
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, 1_000)
        end
      end
    end)
  end

  defp minimal_snapshot do
    %{
      running: [],
      retrying: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp minimal_snapshot_data do
    {:ok,
     %{
       running: [],
       retrying: [],
       agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
       rate_limits: nil,
       polling: nil
     }}
  end

  defp strip_ansi(content) do
    String.replace(content, ~r/\e\[[0-9;]*m/, "")
  end
end
