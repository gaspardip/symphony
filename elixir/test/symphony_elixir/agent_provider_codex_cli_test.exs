defmodule SymphonyElixir.AgentProvider.CodexCLITest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentProvider.CodexCLI

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-codex-cli-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace with spaces")
    bin = Path.join(root, "bin")
    argv_path = Path.join(root, "argv")
    File.mkdir_p!(workspace)
    File.mkdir_p!(bin)

    for args <- [["init", "-q"], ["config", "user.name", "Symphony Test"], ["config", "user.email", "test@example.invalid"], ["commit", "--allow-empty", "-qm", "test fixture"]] do
      {_output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    binary = Path.join(bin, "codex")

    File.write!(binary, """
    #!/bin/sh
    printf '%s\\0' "$@" > "$SYMPHONY_CODEX_TEST_ARGV"
    printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """)

    File.chmod!(binary, 0o755)
    previous_argv = System.get_env("SYMPHONY_CODEX_TEST_ARGV")
    System.put_env("SYMPHONY_CODEX_TEST_ARGV", argv_path)
    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    on_exit(fn ->
      restore_env("SYMPHONY_CODEX_TEST_ARGV", previous_argv)
      File.rm_rf!(root)
    end)

    %{workspace: workspace, argv_path: argv_path}
  end

  test "passes an explicit reasoning effort to the CLI without splitting the prompt", context do
    {:ok, session} = CodexCLI.start_session(context.workspace, model: "test-model")
    prompt = "Implement the change with spaces and \"quoted text\"."
    issue = %{id: "effort-1", identifier: "EFFORT-1"}

    assert {:ok, %{result: :turn_completed}} =
             CodexCLI.run_turn(session, prompt, issue, effort: "high")

    args = context.argv_path |> File.read!() |> String.split(<<0>>, trim: true)
    assert ["exec", "--json" | _] = args
    assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["-m", "test-model"])
    assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["-C", context.workspace])
    assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["-c", "model_reasoning_effort=\"high\""])
    assert List.last(args) == prompt
  end

  test "leaves CLI reasoning configuration unchanged when effort is omitted", context do
    {:ok, session} = CodexCLI.start_session(context.workspace, model: "test-model")

    assert {:ok, %{result: :turn_completed}} =
             CodexCLI.run_turn(session, "A simple task", %{identifier: "EFFORT-2"})

    args = context.argv_path |> File.read!() |> String.split(<<0>>, trim: true)
    refute Enum.any?(args, &String.contains?(&1, "model_reasoning_effort"))
    assert List.last(args) == "A simple task"
  end
end
