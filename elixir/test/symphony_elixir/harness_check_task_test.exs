defmodule SymphonyElixir.HarnessCheckTaskTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureIO

  test "mix harness.check passes for the checked-in symphony repo" do
    repo_root = Path.expand("../../..", __DIR__)

    File.cd!(repo_root, fn ->
      assert capture_io(fn ->
               Mix.Tasks.Harness.Check.run([])
             end) =~ "harness.check: self-development harness is valid"
    end)
  end
end
