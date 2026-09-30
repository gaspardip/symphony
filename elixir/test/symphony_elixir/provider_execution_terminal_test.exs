defmodule SymphonyElixir.ProviderExecutionTerminalTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentProvider.{Claude, CodexCLI}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-provider-terminal-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "TERM-1")
    bin = Path.join(root, "bin")
    File.mkdir_p!(workspace)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    %{workspace: workspace, bin: bin}
  end

  for {adapter, name} <- [{Claude, "claude"}, {CodexCLI, "codex"}, {AppServer, "app-server"}],
      kind <- [:stale_execution, :execution_stopped],
      mode <- [:return, :throw] do
    @tag adapter: adapter, binary_name: name, terminal_kind: kind, callback_mode: mode
    test "#{name} preserves #{kind} from a #{mode} callback before later effects", c do
      terminal =
        case c.terminal_kind do
          :stale_execution -> {:stop, {:stale_execution, %{run_id: "captured-run", dispatch_id: "captured-dispatch"}, :material_changed}}
          :execution_stopped -> {:stop, {:execution_stopped, %{stage: "blocked"}}}
        end

      executable = Path.join(c.bin, c.binary_name)
      write_transport!(executable, c.adapter)
      observer = self()
      ports_before = owned_ports()

      opts = [
        on_usage: fn raw ->
          if Map.has_key?(raw, "usage") do
            send(observer, :terminal_observed)

            case c.callback_mode do
              :return -> terminal
              :throw -> throw({:agent_execution_halt, terminal})
            end
          else
            :ok
          end
        end,
        on_message: fn message -> send(observer, {:provider_event, message.event}) end,
        tool_executor: fn _, _ ->
          send(observer, :unexpected_tool_effect)
          %{success: true, output: "unexpected"}
        end
      ]

      issue = %{id: "terminal-issue", identifier: "TERM-1", title: "Preserve execution stop"}

      case c.adapter do
        AppServer ->
          assert catch_throw(AppServer.run(c.workspace, "test", issue, Keyword.put(opts, :codex_command, quote_shell(executable)))) ==
                   {:agent_execution_halt, terminal}

        adapter ->
          assert {:ok, session} = adapter.start_session(c.workspace, model: "fixture-model")
          assert adapter.run_turn(session, "test", issue, opts) == terminal
          assert :ok = adapter.stop_session(session)
      end

      assert_received :terminal_observed
      refute_received :unexpected_tool_effect
      refute_received {:provider_event, :turn_ended_with_error}
      refute_received {:provider_event, :turn_completed}
      assert owned_ports() == ports_before
    end
  end

  defp owned_ports do
    Port.list()
    |> Enum.filter(&(Port.info(&1, :connected) == {:connected, self()}))
    |> Enum.sort()
  end

  defp write_transport!(path, AppServer) do
    File.write!(path, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"terminal-thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"terminal-turn"}}}'
          printf '%s\\n' '{"usage":{"input_tokens":1,"output_tokens":1}}'
          printf '%s\\n' '{"id":72,"method":"item/tool/call","params":{"tool":"test","arguments":{},"callId":"terminal-call","threadId":"terminal-thread","turnId":"terminal-turn"}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"terminal-thread","turnId":"terminal-turn"}}'
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp write_transport!(path, _adapter) do
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """)

    File.chmod!(path, 0o755)
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
