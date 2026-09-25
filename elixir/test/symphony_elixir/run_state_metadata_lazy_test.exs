defmodule SymphonyElixir.RunStateMetadataLazyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunStateStore

  @metadata_keys [
    :runner_instance_id,
    :runner_instance_name,
    :runner_channel,
    :runner_runtime_version,
    :runner_workspace_root
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "snapshot-metadata-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    bin = Path.join(root, "bin")
    log = Path.join(root, "git-calls")
    original_path = System.fetch_env!("PATH")
    git = System.find_executable("git")
    assert is_binary(git)
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.dirname(RunStateStore.state_path(workspace)))
    issue = %Issue{id: "metadata-issue", identifier: "METADATA-ISSUE", state: "In Progress"}
    baseline = RunStateStore.load_or_default(workspace, issue)
    current_metadata = Map.take(baseline, @metadata_keys)

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
      printf '%s\\n' called >> #{shell_quote(log)}
    fi
    exec #{shell_quote(git)} "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    System.put_env("PATH", bin <> ":" <> original_path)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.rm_rf!(root)
    end)

    %{workspace: workspace, issue: issue, baseline: baseline, current_metadata: current_metadata, log: log}
  end

  test "existing metadata survives reads and usage-preserving writes without consulting Git", context do
    saved_metadata = Map.new(@metadata_keys, &{&1, "saved-#{&1}"})
    state = Map.merge(context.baseline, saved_metadata)
    seed!(context.workspace, state)

    assert {:ok, loaded} = RunStateStore.load_checked(context.workspace, context.issue)
    assert Map.take(loaded, @metadata_keys) == saved_metadata
    assert Map.take(RunStateStore.load_or_default(context.workspace, context.issue), @metadata_keys) == saved_metadata
    assert :ok = RunStateStore.save(context.workspace, Map.put(loaded, :stage, "implement"))

    usage = %{input_tokens: 21, output_tokens: 8, total_tokens: 29}
    assert {:ok, _} = RunStateStore.record_token_usage(context.workspace, context.issue, usage)
    assert :ok = RunStateStore.save(context.workspace, Map.put(loaded, :stage, "validate"))
    assert {:ok, persisted} = RunStateStore.load(context.workspace)
    assert persisted.token_usage == usage
    assert persisted.stage == "validate"
    assert Map.take(persisted, @metadata_keys) == saved_metadata
    refute File.exists?(context.log)
  end

  for missing <- [:absent, nil, ""] do
    test "metadata #{inspect(missing)} is completed by the existing getters without changing the read snapshot", context do
      state = missing_metadata(context.baseline, unquote(missing))

      bytes = seed!(context.workspace, state)
      assert {:ok, loaded} = RunStateStore.load_checked(context.workspace, context.issue)
      assert Map.take(loaded, @metadata_keys) == context.current_metadata
      assert File.read!(RunStateStore.state_path(context.workspace)) == bytes
      assert File.read!(context.log) == "called\n"
      assert :ok = RunStateStore.save(context.workspace, loaded)
      assert {:ok, persisted} = RunStateStore.load(context.workspace)
      assert Map.take(persisted, @metadata_keys) == context.current_metadata
    end
  end

  for value <- [false, 0, %{stage: "saved"}, ["saved"]] do
    test "metadata #{inspect(value)} retains the existing fill predicate", context do
      value = unquote(Macro.escape(value))
      saved_metadata = Map.new(@metadata_keys, &{&1, value})
      seed!(context.workspace, Map.merge(context.baseline, saved_metadata))
      assert {:ok, loaded} = RunStateStore.load_checked(context.workspace, context.issue)
      assert Map.take(loaded, @metadata_keys) == saved_metadata
      assert :ok = RunStateStore.save(context.workspace, loaded)
      assert {:ok, persisted} = RunStateStore.load(context.workspace)
      assert Map.take(persisted, @metadata_keys) == saved_metadata
      refute File.exists?(context.log)
    end
  end

  test "a new snapshot still observes current runtime metadata", context do
    state = RunStateStore.load_or_default(context.workspace, context.issue)
    assert Map.take(state, @metadata_keys) == context.current_metadata
    assert state.issue_id == context.issue.id
    assert state.issue_identifier == context.issue.identifier
    assert state.stage == "checkout"
    assert File.read!(context.log) == "called\n"
    assert {:error, :missing} = RunStateStore.load(context.workspace)
  end

  defp missing_metadata(state, :absent), do: Map.drop(state, @metadata_keys)
  defp missing_metadata(state, value), do: Map.merge(state, Map.new(@metadata_keys, &{&1, value}))

  defp seed!(workspace, state) do
    bytes = Jason.encode!(state)
    File.write!(RunStateStore.state_path(workspace), bytes)
    bytes
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
