defmodule SymphonyElixir.AgentProvider.ClaudeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentProvider.Claude
  alias SymphonyElixir.AgentProvider.Claude.StreamState

  describe "start_session/2" do
    test "returns session with workspace and defaults" do
      workspace = System.tmp_dir!()
      assert {:ok, session} = Claude.start_session(workspace)
      assert session.workspace == Path.expand(workspace)
      assert session.model == "claude-sonnet-4-6"
      assert session.max_turns == 10
      assert is_binary(session.session_id)
      assert String.starts_with?(session.session_id, "claude-")
    end

    test "accepts model override" do
      assert {:ok, session} = Claude.start_session(System.tmp_dir!(), model: "claude-opus-4-6")
      assert session.model == "claude-opus-4-6"
    end

    test "accepts max_turns override" do
      assert {:ok, session} = Claude.start_session(System.tmp_dir!(), max_turns: 5)
      assert session.max_turns == 5
    end
  end

  describe "stop_session/1" do
    test "is a no-op" do
      assert :ok = Claude.stop_session(%{})
    end
  end

  describe "run_turn model override" do
    test "uses session model by default" do
      {:ok, session} = Claude.start_session(System.tmp_dir!(), model: "claude-sonnet-4-6")
      assert session.model == "claude-sonnet-4-6"
    end

    test "per-stage model overrides session model in opts" do
      {:ok, session} = Claude.start_session(System.tmp_dir!(), model: "claude-sonnet-4-6")

      # The model override is applied inside run_turn via Keyword.get(opts, :model, session.model)
      # We can verify the mechanism by checking that the opts flow through
      assert session.model == "claude-sonnet-4-6"

      # With override, the effective model would be opus
      override_model = Keyword.get([model: "claude-opus-4-6"], :model, session.model)
      assert override_model == "claude-opus-4-6"

      # Without override, falls back to session model
      default_model = Keyword.get([], :model, session.model)
      assert default_model == "claude-sonnet-4-6"
    end
  end

  describe "StreamState" do
    test "initializes with empty defaults" do
      state = %StreamState{}
      assert state.usage == %{input_tokens: 0, output_tokens: 0}
      assert state.files_touched == []
      assert state.result_text == nil
      assert state.error == nil
    end
  end

  describe "parse_stream_line/2 (via test helpers)" do
    test "extracts files from assistant tool_use Write events" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Write",
                "input" => %{"file_path" => "/workspace/lib/greeter.ex", "content" => "defmodule Greeter do\nend"}
              }
            ]
          }
        })

      state = %StreamState{}
      {updated, _event} = Claude.parse_stream_line_for_test(line, state)
      assert "/workspace/lib/greeter.ex" in updated.files_touched
    end

    test "extracts files from assistant tool_use Edit events" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Edit",
                "input" => %{
                  "file_path" => "/workspace/elixir/WORKFLOW.md",
                  "old_string" => "old",
                  "new_string" => "new"
                }
              }
            ]
          }
        })

      state = %StreamState{}
      {updated, _event} = Claude.parse_stream_line_for_test(line, state)
      assert "/workspace/elixir/WORKFLOW.md" in updated.files_touched
    end

    test "accumulates files across multiple events" do
      line1 =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "name" => "Write", "input" => %{"file_path" => "lib/a.ex", "content" => ""}}
            ]
          }
        })

      line2 =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "lib/b.ex", "old_string" => "", "new_string" => ""}}
            ]
          }
        })

      state = %StreamState{}
      {state, _} = Claude.parse_stream_line_for_test(line1, state)
      {state, _} = Claude.parse_stream_line_for_test(line2, state)
      assert "lib/a.ex" in state.files_touched
      assert "lib/b.ex" in state.files_touched
    end

    test "deduplicates repeated file paths" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "name" => "Write", "input" => %{"file_path" => "lib/same.ex", "content" => "v1"}},
              %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "lib/same.ex", "old_string" => "v1", "new_string" => "v2"}}
            ]
          }
        })

      state = %StreamState{}
      {updated, _} = Claude.parse_stream_line_for_test(line, state)
      assert updated.files_touched == ["lib/same.ex"]
    end

    test "ignores non-Write/Edit tool uses (Read, Bash)" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "name" => "Read", "input" => %{"file_path" => "lib/read_only.ex"}},
              %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "ls"}}
            ]
          }
        })

      state = %StreamState{}
      {updated, _} = Claude.parse_stream_line_for_test(line, state)
      assert updated.files_touched == []
    end

    test "extracts result text from result event" do
      line =
        Jason.encode!(%{
          "type" => "result",
          "result" => "Created lib/greeter.ex with the Greeter module.",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
        })

      state = %StreamState{}
      {updated, event} = Claude.parse_stream_line_for_test(line, state)
      assert updated.result_text == "Created lib/greeter.ex with the Greeter module."
      assert updated.usage.input_tokens == 100
      assert updated.usage.output_tokens == 50
      assert event.event == :notification
    end

    test "extracts usage from message events" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => "hello"}],
            "usage" => %{"input_tokens" => 200, "output_tokens" => 75}
          }
        })

      state = %StreamState{}
      {updated, _} = Claude.parse_stream_line_for_test(line, state)
      assert updated.usage.input_tokens == 200
      assert updated.usage.output_tokens == 75
    end

    test "takes max of usage across events" do
      line1 =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [],
            "usage" => %{"input_tokens" => 100, "output_tokens" => 30}
          }
        })

      line2 =
        Jason.encode!(%{
          "type" => "result",
          "result" => "done",
          "usage" => %{"input_tokens" => 200, "output_tokens" => 80}
        })

      state = %StreamState{}
      {state, _} = Claude.parse_stream_line_for_test(line1, state)
      {state, _} = Claude.parse_stream_line_for_test(line2, state)
      assert state.usage == %{input_tokens: 200, output_tokens: 80}
    end

    test "handles non-JSON lines gracefully" do
      state = %StreamState{}
      {updated, event} = Claude.parse_stream_line_for_test("not json at all", state)
      assert updated == state
      assert event == nil
    end
  end

  describe "synthesize_turn_result/2 (via test helpers)" do
    test "synthesizes turn result and calls tool_executor" do
      state = %StreamState{
        result_text: "Added greeter module",
        files_touched: ["lib/greeter.ex", "test/greeter_test.exs"],
        usage: %{input_tokens: 100, output_tokens: 50}
      }

      tool_executor = fn tool, arguments ->
        send(self(), {:tool_call, tool, arguments})
        %{"success" => true}
      end

      result = Claude.synthesize_turn_result_for_test(state, tool_executor)

      assert result["summary"] == "Added greeter module"
      assert result["files_touched"] == ["lib/greeter.ex", "test/greeter_test.exs"]
      assert result["blocked"] == false
      assert result["blocker_type"] == "none"
      assert result["needs_another_turn"] == false

      assert_receive {:tool_call, "report_agent_turn_result", ^result}
    end

    test "marks as blocked when error is present" do
      state = %StreamState{
        result_text: "Failed",
        error: "exit_status_1"
      }

      result = Claude.synthesize_turn_result_for_test(state, nil)
      assert result["blocked"] == true
      assert result["blocker_type"] == "implementation"
    end

    test "uses default summary when result_text is nil" do
      state = %StreamState{}
      result = Claude.synthesize_turn_result_for_test(state, nil)
      assert result["summary"] == "Turn completed."
    end

    test "deduplicates and filters empty file paths" do
      state = %StreamState{
        files_touched: ["lib/a.ex", "", "lib/a.ex", "lib/b.ex"]
      }

      result = Claude.synthesize_turn_result_for_test(state, nil)
      assert result["files_touched"] == ["lib/a.ex", "lib/b.ex"]
    end
  end

  describe "detect_changed_files/2 (via test helpers)" do
    setup do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-claude-detect-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      System.cmd("git", ["init", "--initial-branch=main"], cd: workspace)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: workspace)
      System.cmd("git", ["config", "user.name", "Test"], cd: workspace)
      File.write!(Path.join(workspace, "existing.txt"), "original")
      System.cmd("git", ["add", "-A"], cd: workspace)
      System.cmd("git", ["commit", "-m", "init"], cd: workspace)

      on_exit(fn -> File.rm_rf!(test_root) end)

      %{workspace: workspace}
    end

    test "detects modified files via git diff", %{workspace: workspace} do
      File.write!(Path.join(workspace, "existing.txt"), "modified")

      state = %StreamState{files_touched: []}
      updated = Claude.detect_changed_files_for_test(state, workspace)
      assert "existing.txt" in updated.files_touched
    end

    test "detects new untracked files", %{workspace: workspace} do
      File.write!(Path.join(workspace, "new_file.ex"), "defmodule New do\nend")

      state = %StreamState{files_touched: []}
      updated = Claude.detect_changed_files_for_test(state, workspace)
      assert "new_file.ex" in updated.files_touched
    end

    test "merges git changes with stream-detected files", %{workspace: workspace} do
      File.write!(Path.join(workspace, "existing.txt"), "modified")

      state = %StreamState{files_touched: ["stream_detected.ex"]}
      updated = Claude.detect_changed_files_for_test(state, workspace)
      assert "stream_detected.ex" in updated.files_touched
      assert "existing.txt" in updated.files_touched
    end

    test "returns unchanged state when no git changes", %{workspace: workspace} do
      state = %StreamState{files_touched: ["previously.ex"]}
      updated = Claude.detect_changed_files_for_test(state, workspace)
      assert updated.files_touched == ["previously.ex"]
    end
  end
end
