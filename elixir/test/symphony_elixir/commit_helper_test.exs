defmodule SymphonyElixir.AgentProvider.CommitHelperTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentProvider.CommitHelper

  defmodule StreamState do
    @moduledoc false
    defstruct usage: %{input_tokens: 0, output_tokens: 0},
              files_touched: [],
              result_text: nil,
              error: nil
  end

  describe "synthesize_turn_result/2" do
    test "builds the turn result payload and reports it through the tool executor" do
      state = %StreamState{
        result_text: "Added shared commit helper",
        files_touched: ["lib/a.ex", "", "lib/a.ex", "test/a_test.exs"]
      }

      tool_executor = fn tool, arguments ->
        send(self(), {:tool_call, tool, arguments})
        %{"success" => true}
      end

      result = CommitHelper.synthesize_turn_result(state, tool_executor)

      assert result == %{
               "summary" => "Added shared commit helper",
               "files_touched" => ["lib/a.ex", "test/a_test.exs"],
               "needs_another_turn" => false,
               "blocked" => false,
               "blocker_type" => "none"
             }

      assert_receive {:tool_call, "report_agent_turn_result", ^result}
    end

    test "marks the turn as blocked when the state carries an error" do
      result = CommitHelper.synthesize_turn_result(%StreamState{error: "timeout"}, nil)

      assert result["blocked"] == true
      assert result["blocker_type"] == "implementation"
      assert result["summary"] == "Turn completed."
    end
  end

  describe "detect_changed_files/2" do
    setup [:create_git_workspace]

    test "merges modified and untracked files with stream-detected paths", %{workspace: workspace} do
      File.write!(Path.join(workspace, "tracked.txt"), "updated")
      File.write!(Path.join(workspace, "new.txt"), "brand new")

      state = %StreamState{files_touched: ["stream_detected.ex"]}
      updated = CommitHelper.detect_changed_files(state, workspace)

      assert "stream_detected.ex" in updated.files_touched
      assert "tracked.txt" in updated.files_touched
      assert "new.txt" in updated.files_touched
    end

    test "returns the existing file list unchanged when git sees no new changes", %{
      workspace: workspace
    } do
      state = %StreamState{files_touched: ["existing.ex"]}
      updated = CommitHelper.detect_changed_files(state, workspace)
      assert updated.files_touched == ["existing.ex"]
    end
  end

  describe "maybe_patch_progress_file/2" do
    test "fills empty work log and evidence sections" do
      workspace = make_workspace("progress")
      progress_dir = Path.join(workspace, ".symphony/progress")
      File.mkdir_p!(progress_dir)
      progress_path = Path.join(progress_dir, "CLZ-48.md")

      File.write!(
        progress_path,
        """
        # CLZ-48

        ## Work Log

        ## Evidence

        ## Next Step
        - keep going
        """
      )

      state = %StreamState{
        result_text: "Extracted CommitHelper",
        files_touched: ["elixir/lib/symphony_elixir/agent_provider/commit_helper.ex"]
      }

      assert :ok = CommitHelper.maybe_patch_progress_file(workspace, state)

      patched = File.read!(progress_path)
      assert patched =~ ~r/## Work Log\s+- Extracted CommitHelper/

      assert patched =~
               ~r/## Evidence\s+- `elixir\/lib\/symphony_elixir\/agent_provider\/commit_helper\.ex`/
    end
  end

  describe "maybe_auto_commit/2" do
    setup [:create_git_workspace]

    test "is a no-op when no files were touched", %{workspace: workspace} do
      before_head = git_head(workspace)
      state = %StreamState{files_touched: []}

      assert CommitHelper.maybe_auto_commit(state, workspace) == state
      assert git_head(workspace) == before_head
    end

    test "formats elixir sources before committing staged changes", %{workspace: workspace} do
      elixir_dir = Path.join(workspace, "elixir")
      File.mkdir_p!(Path.join(elixir_dir, "lib"))

      File.write!(
        Path.join(elixir_dir, "mix.exs"),
        """
        defmodule CommitHelperFixture.MixProject do
          use Mix.Project

          def project do
            [app: :commit_helper_fixture, version: "0.1.0", elixir: "~> 1.19"]
          end
        end
        """
      )

      File.write!(
        Path.join(elixir_dir, ".formatter.exs"),
        """
        [
          inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
        ]
        """
      )

      source_path = Path.join(elixir_dir, "lib/demo.ex")
      File.write!(source_path, "defmodule Demo do\n def hello,do: :world\nend\n")

      before_head = git_head(workspace)

      state = %StreamState{
        files_touched: ["elixir/lib/demo.ex"],
        result_text: "Commit formatted demo module"
      }

      assert CommitHelper.maybe_auto_commit(state, workspace) == state
      assert git_head(workspace) != before_head
      assert File.read!(source_path) =~ "def hello, do: :world"

      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: workspace)
      assert String.trim(log) == "Commit formatted demo module"
    end
  end

  defp create_git_workspace(_context) do
    workspace = make_workspace("git")
    System.cmd("git", ["init", "--initial-branch=main"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test"], cd: workspace)
    File.write!(Path.join(workspace, "tracked.txt"), "original")
    System.cmd("git", ["add", "-A"], cd: workspace)
    System.cmd("git", ["commit", "-m", "init"], cd: workspace)
    {:ok, workspace: workspace}
  end

  defp make_workspace(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-commit-helper-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    root
  end

  defp git_head(workspace) do
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    String.trim(head)
  end
end
