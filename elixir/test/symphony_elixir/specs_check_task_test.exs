defmodule SymphonyElixir.SpecsCheckTaskTest do
  use ExUnit.Case

  alias Mix.Tasks.Specs.Check, as: SpecsCheckTask

  setup do
    previous_shell = Mix.shell()
    previous_cwd = File.cwd!()

    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("specs.check")

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.cd!(previous_cwd)
    end)

    :ok
  end

  test "run succeeds with the default lib path and reports success" do
    project_root = tmp_dir("specs-check-task-default")
    lib_dir = Path.join(project_root, "lib")
    source_path = Path.join(lib_dir, "sample.ex")

    try do
      File.mkdir_p!(lib_dir)

      File.write!(source_path, """
      defmodule SpecsTaskDefault do
        @spec ok() :: :ok
        def ok, do: :ok
      end
      """)

      File.cd!(project_root)

      assert :ok = SpecsCheckTask.run([])
      assert_receive {:mix_shell, :info, [message]}
      assert message =~ "specs.check: all public functions have @spec or exemption"
    after
      File.rm_rf(project_root)
    end
  end

  test "run honors exemptions files" do
    project_root = tmp_dir("specs-check-task-exemptions")
    lib_dir = Path.join(project_root, "lib")
    source_path = Path.join(lib_dir, "sample.ex")
    exemptions_path = Path.join(project_root, "specs-exemptions.txt")

    try do
      File.mkdir_p!(lib_dir)

      File.write!(source_path, """
      defmodule SpecsTaskExemptions do
        def skipped, do: :ok
      end
      """)

      File.write!(exemptions_path, """
      # comment

      SpecsTaskExemptions.skipped/0
      """)

      File.cd!(project_root)

      assert :ok =
               SpecsCheckTask.run([
                 "--paths",
                 "lib",
                 "--exemptions-file",
                 "specs-exemptions.txt"
               ])

      assert_receive {:mix_shell, :info, [message]}
      assert message =~ "all public functions have @spec or exemption"
    after
      File.rm_rf(project_root)
    end
  end

  test "run reports missing specs and raises with the count" do
    project_root = tmp_dir("specs-check-task-failure")
    lib_dir = Path.join(project_root, "lib")
    source_path = Path.join(lib_dir, "sample.ex")

    try do
      File.mkdir_p!(lib_dir)

      File.write!(source_path, """
      defmodule SpecsTaskFailure do
        def missing(value), do: value
      end
      """)

      File.cd!(project_root)

      assert_raise Mix.Error, ~r/specs\.check failed with 1 missing @spec declaration\(s\)/, fn ->
        SpecsCheckTask.run(["--paths", "lib"])
      end

      assert_receive {:mix_shell, :error, [message]}
      assert message =~ "lib/sample.ex:2 missing @spec for SpecsTaskFailure.missing/1"
    after
      File.rm_rf(project_root)
    end
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
  end
end
