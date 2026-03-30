defmodule SymphonyElixir.ConfigWarningsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State

  describe "validate!/0 project_slug warnings" do
    test "warns when project_slug looks like a URL slug (name-hash)" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "symphony-0c79b11b75ea"
      )

      log =
        capture_log(fn ->
          assert :ok = Config.validate!()
        end)

      assert log =~ "[config] project_slug 'symphony-0c79b11b75ea' looks like a URL slug"
      assert log =~ "0c79b11b75ea"
    end

    test "does not warn for a plain hash slugId" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "7262055276bc"
      )

      log =
        capture_log(fn ->
          assert :ok = Config.validate!()
        end)

      refute log =~ "[config] project_slug"
    end

    test "does not warn for a multi-hyphen slug that does not match the URL pattern" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: "my-cool-project-abc123"
      )

      log =
        capture_log(fn ->
          assert :ok = Config.validate!()
        end)

      refute log =~ "[config] project_slug"
    end
  end

  describe "validate!/0 runner.channel warnings" do
    test "warns when runner.channel is normalized to a different value" do
      write_workflow_file!(Workflow.workflow_file_path(),
        runner_channel: "nightly"
      )

      log =
        capture_log(fn ->
          assert :ok = Config.validate!()
        end)

      assert log =~ "[config] runner.channel 'nightly' normalized to 'stable'"
      assert log =~ "invalid values fall back to 'stable'"
    end

    test "does not warn for valid channel values" do
      for channel <- ["stable", "canary", "experimental"] do
        write_workflow_file!(Workflow.workflow_file_path(),
          runner_channel: channel
        )

        log =
          capture_log(fn ->
            assert :ok = Config.validate!()
          end)

        refute log =~ "[config] runner.channel"
      end
    end
  end

  describe "first poll warnings in orchestrator" do
    test "warns on first poll with 0 candidates and assignee filter" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_assignee: "me"
      )

      state = %State{
        max_concurrent_agents: 10,
        first_poll_completed: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        paused_issue_states: %{},
        priority_overrides: %{},
        policy_overrides: %{},
        issue_routing_cache: %{}
      }

      log =
        capture_log(fn ->
          Orchestrator.process_candidate_issues_for_test(state, [])
        end)

      assert log =~ "[dispatch] First poll returned 0 candidates with assignee filter 'me'"
      assert log =~ "[dispatch] First poll returned 0 candidates. Query:"
    end

    test "warns on first poll with 0 candidates without assignee filter" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_assignee: nil
      )

      state = %State{
        max_concurrent_agents: 10,
        first_poll_completed: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        paused_issue_states: %{},
        priority_overrides: %{},
        policy_overrides: %{},
        issue_routing_cache: %{}
      }

      log =
        capture_log(fn ->
          Orchestrator.process_candidate_issues_for_test(state, [])
        end)

      refute log =~ "assignee filter"
      assert log =~ "[dispatch] First poll returned 0 candidates. Query:"
    end

    test "does not warn on second poll with 0 candidates" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_assignee: "me"
      )

      state = %State{
        max_concurrent_agents: 10,
        first_poll_completed: true,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        paused_issue_states: %{},
        priority_overrides: %{},
        policy_overrides: %{},
        issue_routing_cache: %{}
      }

      log =
        capture_log(fn ->
          Orchestrator.process_candidate_issues_for_test(state, [])
        end)

      refute log =~ "[dispatch] First poll"
    end

    test "does not warn on first poll when candidates are found" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_assignee: "me"
      )

      issue = %Issue{
        id: "issue-1",
        identifier: "S-1",
        title: "Test issue",
        state: "Todo",
        labels: [],
        assignee_id: nil,
        priority: 2,
        description: nil
      }

      state = %State{
        max_concurrent_agents: 10,
        first_poll_completed: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        paused_issue_states: %{},
        priority_overrides: %{},
        policy_overrides: %{},
        issue_routing_cache: %{}
      }

      log =
        capture_log(fn ->
          Orchestrator.process_candidate_issues_for_test(state, [issue])
        end)

      refute log =~ "[dispatch] First poll returned 0 candidates"
    end
  end
end
