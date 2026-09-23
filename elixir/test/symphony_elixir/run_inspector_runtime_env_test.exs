defmodule SymphonyElixir.RunInspectorRuntimeEnvTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RepoHarness
  alias SymphonyElixir.RunInspector

  @env_keys ~w(MIX_HOME HEX_HOME MIX_ARCHIVES MIX_REBAR3 MIX_XDG XDG_DATA_HOME HEX_OFFLINE SYMPHONY_HARNESS_SENTINEL)

  setup do
    previous_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    installed_archives = Mix.path_for(:archives)
    root = Path.join(System.tmp_dir!(), "symphony harness env #{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace with spaces")
    data_home = Path.join(root, "user data")

    File.mkdir_p!(workspace)
    Enum.each(@env_keys, &System.delete_env/1)
    System.put_env("MIX_XDG", "1")
    System.put_env("XDG_DATA_HOME", data_home)
    System.put_env("HEX_OFFLINE", "1")

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, workspace: workspace, source_home: Path.join(data_home, "mix"), root: root, installed_archives: installed_archives}
  end

  test "real shell gets local defaults in paths with spaces without changing parent environment", %{workspace: workspace} do
    System.put_env("SYMPHONY_HARNESS_SENTINEL", "keep this value")

    command = ~S"""
    printf '%s\n' "$MIX_HOME" "$HEX_HOME" "$MIX_ARCHIVES" "$SYMPHONY_HARNESS_SENTINEL"
    test -d "$MIX_HOME" && test -d "$HEX_HOME" && test -d "$MIX_ARCHIVES"
    """

    result = RunInspector.run_shell_command(workspace, command)

    assert result.status == :passed

    assert String.split(result.output, "\n", trim: true) == [
             Path.join(workspace, ".symphony/runtime/mix_home"),
             Path.join(workspace, ".symphony/runtime/hex_home"),
             Path.join(workspace, ".symphony/runtime/mix_archives"),
             "keep this value"
           ]

    for key <- ~w(MIX_HOME HEX_HOME MIX_ARCHIVES), do: assert(is_nil(System.get_env(key)))
    assert System.get_env("SYMPHONY_HARNESS_SENTINEL") == "keep this value"
  end

  test "all harness stages pass the same scoped environment to their runner", %{workspace: workspace} do
    runner = fn ^workspace, "verify harness", opts ->
      assert opts[:stderr_to_stdout]
      assert Map.new(opts[:env])["HEX_HOME"] == Path.join(workspace, ".symphony/runtime/hex_home")
      {"verified", 0}
    end

    for {function, field} <- [
          {:run_preflight, :preflight_command},
          {:run_validation, :validation_command},
          {:run_smoke, :smoke_command},
          {:run_post_merge, :post_merge_command},
          {:run_deploy_preview, :deploy_preview_command},
          {:run_deploy_production, :deploy_production_command},
          {:run_post_deploy_verify, :post_deploy_verify_command},
          {:run_deploy_rollback, :deploy_rollback_command}
        ] do
      result = apply(RunInspector, function, [workspace, struct!(RepoHarness, [{field, "verify harness"}]), [shell_runner: runner]])
      assert result.status == :passed
      assert result.output == "verified"
    end
  end

  test "explicit tool directories and unrelated environment remain available", %{workspace: workspace, root: root} do
    overrides = %{
      "MIX_HOME" => Path.join(root, "custom mix"),
      "HEX_HOME" => Path.join(root, "custom hex"),
      "MIX_ARCHIVES" => Path.join(root, "custom archives")
    }

    System.put_env(overrides)
    System.put_env("MIX_REBAR3", Path.join(root, "custom rebar"))

    result = RunInspector.run_shell_command(workspace, ~S(printf '%s\n' "$MIX_HOME" "$HEX_HOME" "$MIX_ARCHIVES" "$MIX_REBAR3"))

    assert result.status == :passed

    assert String.split(result.output, "\n", trim: true) == [
             overrides["MIX_HOME"],
             overrides["HEX_HOME"],
             overrides["MIX_ARCHIVES"],
             System.get_env("MIX_REBAR3")
           ]

    assert Map.take(System.get_env(), Map.keys(overrides)) == overrides
    refute File.exists?(Path.join(workspace, ".symphony/runtime"))
  end

  test "explicit MIX_HOME retains its default archives directory", %{workspace: workspace, root: root} do
    mix_home = Path.join(root, "existing mix")
    archive = Path.join(mix_home, "archives/example/ebin/task.beam")
    File.mkdir_p!(Path.dirname(archive))
    File.write!(archive, "installed task")
    System.put_env("MIX_HOME", mix_home)

    result = RunInspector.run_shell_command(workspace, ~S(cat "$MIX_ARCHIVES/example/ebin/task.beam"))

    assert result.status == :passed
    assert result.output == "installed task"
    assert File.read!(archive) == "installed task"
    assert is_nil(System.get_env("MIX_ARCHIVES"))
  end

  test "seeded tools and cache survive repeated runs without copying global configuration", %{
    workspace: workspace,
    source_home: source_home
  } do
    archive = Path.join(source_home, "archives/example/ebin/task.beam")
    [major, minor | _] = String.split(System.version(), ".")
    rebar_relative = Path.join(["elixir", "#{major}-#{minor}-otp-#{System.otp_release()}", "rebar3"])
    rebar = Path.join(source_home, rebar_relative)
    File.mkdir_p!(Path.dirname(archive))
    File.mkdir_p!(Path.dirname(rebar))
    File.write!(archive, "installed task")
    File.write!(rebar, "#!/bin/sh\nprintf rebar-ok\n")
    File.chmod!(rebar, 0o755)
    File.write!(Path.join(source_home, "config.exs"), "private configuration")

    command = ~S"""
    cat "$MIX_ARCHIVES/example/ebin/task.beam"
    printf cache > "$HEX_HOME/cache.ets"
    """

    assert %{status: :passed, output: "installed task"} = RunInspector.run_shell_command(workspace, command)

    runtime_home = Path.join(workspace, ".symphony/runtime")
    local_archive = Path.join(runtime_home, "mix_archives/example/ebin/task.beam")
    local_rebar = Path.join([runtime_home, "mix_home", rebar_relative])
    File.write!(local_archive, "workspace version")

    assert %{status: :passed, output: "workspace versioncache"} =
             RunInspector.run_shell_command(workspace, ~S(cat "$MIX_ARCHIVES/example/ebin/task.beam" "$HEX_HOME/cache.ets"))

    assert System.cmd(local_rebar, []) == {"rebar-ok", 0}
    assert File.read!(archive) == "installed task"
    refute File.exists?(Path.join(runtime_home, "mix_home/config.exs"))
    refute File.exists?(Path.join(runtime_home, "mix_home/.symphony"))
  end

  test "real Mix loads installed Hex from seeded archives offline and retains project dependencies", context do
    %{workspace: workspace, source_home: source_home, installed_archives: installed_archives} = context
    assert File.dir?(installed_archives), "The test toolchain must have Hex installed before running this suite."
    File.mkdir_p!(source_home)
    File.cp_r!(installed_archives, Path.join(source_home, "archives"), dereference_symlinks: true)

    for path <- ["deps/existing/marker", "_build/test/marker"] do
      full_path = Path.join(workspace, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, "keep")
    end

    result = RunInspector.run_shell_command(workspace, mix_command("hex.info"))

    assert result.status == :passed, result.output
    assert result.output =~ ~r/^Hex:[ \t]+\d+\.\d+\.\d+(?:[-+][^\s]+)?$/m
    assert File.dir?(Path.join(workspace, ".symphony/runtime/mix_archives"))
    assert File.read!(Path.join(workspace, "deps/existing/marker")) == "keep"
    assert File.read!(Path.join(workspace, "_build/test/marker")) == "keep"
  end

  test "missing installed Hex is reported by the actual offline command", %{workspace: workspace} do
    result = RunInspector.run_shell_command(workspace, mix_command("help hex.info"))

    assert result.status == :failed
    assert result.output =~ "hex.info"
    assert result.output =~ "could not be found"
  end

  test "failed commands preserve failure and combined output", %{workspace: workspace} do
    command = "printf failed-harness >&2; exit 23"
    result = RunInspector.run_shell_command(workspace, command)

    assert result.status == :failed
    assert result.command == command
    assert result.output == "failed-harness"
  end

  test "runtime directory failure is unavailable and never invokes the harness", %{workspace: workspace} do
    File.write!(Path.join(workspace, ".symphony"), "not a directory")

    result = RunInspector.run_shell_command(workspace, "touch must-not-run")

    assert result.status == :unavailable
    assert result.output =~ ".symphony"
    refute File.exists?(Path.join(workspace, "must-not-run"))
  end

  test "unreadable seed is unavailable and never invokes the harness", %{workspace: workspace, source_home: source_home} do
    File.mkdir_p!(source_home)
    File.ln_s!("archives", Path.join(source_home, "archives"))

    result = RunInspector.run_shell_command(workspace, "touch must-not-run")

    assert result.status == :unavailable
    assert result.output =~ "read runtime seed"
    assert result.output =~ "archives"
    refute File.exists?(Path.join(workspace, "must-not-run"))
  end

  test "relative user overrides are created relative to the command workspace", %{workspace: workspace} do
    System.put_env("MIX_HOME", "relative mix")
    System.put_env("HEX_HOME", "relative hex")

    result = RunInspector.run_shell_command(workspace, ~S(test -d "$MIX_HOME/archives" && test -d "$HEX_HOME"))

    assert result.status == :passed
    assert File.dir?(Path.join(workspace, "relative mix/archives"))
    assert File.dir?(Path.join(workspace, "relative hex"))
  end

  test "missing workspace is unavailable and is never created", %{root: root} do
    workspace = Path.join(root, "missing workspace")
    assert %{status: :unavailable} = RunInspector.run_shell_command(workspace, "printf must-not-run")
    refute File.exists?(workspace)
  end

  test "unconfigured command creates no runtime directories", %{workspace: workspace} do
    assert %{status: :unavailable, command: nil} = RunInspector.run_preflight(workspace, nil)
    refute File.exists?(Path.join(workspace, ".symphony"))
  end

  defp mix_command(arguments) do
    elixir = System.find_executable("elixir") || raise "elixir executable missing from test toolchain"
    mix = System.find_executable("mix") || raise "mix executable missing from test toolchain"
    "#{shell_quote(elixir)} #{shell_quote(mix)} #{arguments}"
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
