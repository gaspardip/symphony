defmodule SymphonyElixir.UtilityPhase6BackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, LogFile, SpecsCheck, TurnResult, Workspace}
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Adapter

  defmodule FakeLinearClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(states), do: {:ok, states}
    def fetch_issue_states_by_ids(issue_ids), do: {:ok, issue_ids}

    def fetch_issue_by_identifier(identifier) do
      send(self(), {:fetch_issue_by_identifier_called, identifier})
      {:ok, %{identifier: identifier}}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  test "turn result normalizes valid payloads and serializes normalized blocker types" do
    assert {:ok, result} =
             TurnResult.normalize(%{
               "summary" => "  Finished the backfill  ",
               "files_touched" => [" lib/a.ex ", :README, ""],
               "needs_another_turn" => false,
               "blocked" => true,
               "blocker_type" => " Post-Merge "
             })

    assert result == %TurnResult{
             summary: "Finished the backfill",
             files_touched: ["lib/a.ex", "README"],
             needs_another_turn: false,
             blocked: true,
             blocker_type: :post_merge
           }

    assert TurnResult.to_map(result) == %{
             summary: "Finished the backfill",
             files_touched: ["lib/a.ex", "README"],
             needs_another_turn: false,
             blocked: true,
             blocker_type: "post_merge"
           }

    assert {:ok, unblocked} =
             TurnResult.normalize(%{
               "summary" => "Ready for review",
               "files_touched" => [],
               "needs_another_turn" => false,
               "blocked" => false,
               "blocker_type" => nil
             })

    assert unblocked.blocker_type == :none
    refute TurnResult.implementation_blocker?(unblocked)
    assert TurnResult.implementation_blocker?(%TurnResult{blocker_type: :implementation})
    assert TurnResult.implementation_blocker?(%TurnResult{blocker_type: :validation})
    refute TurnResult.implementation_blocker?(%TurnResult{blocker_type: :merge})
  end

  test "turn result rejects malformed contracts" do
    assert {:error, :invalid_turn_result} = TurnResult.normalize(:bad)
    assert {:error, :invalid_files_touched} = TurnResult.normalize(valid_turn_result(files_touched: :bad))
    assert {:error, {:invalid_boolean, :needs_another_turn}} = TurnResult.normalize(valid_turn_result(needs_another_turn: "yes"))
    assert {:error, :invalid_blocker_type} = TurnResult.normalize(valid_turn_result(blocked: true, blocker_type: "unknown"))

    assert {:error, {:missing_keys, missing}} = TurnResult.normalize(%{})
    assert :summary in missing
    assert :files_touched in missing
  end

  test "turn result coerces noisy non-blocking blocker types to none" do
    assert {:ok, %TurnResult{blocked: false, blocker_type: :none}} =
             TurnResult.normalize(valid_turn_result(blocker_type: "validation"))

    assert {:ok, %TurnResult{blocked: false, blocker_type: :none}} =
             TurnResult.normalize(valid_turn_result(blocker_type: "unknown"))
  end

  test "turn result handles blank blocker types and invalid summary values" do
    assert {:error, :empty_summary} = TurnResult.normalize(valid_turn_result(summary: "   "))
    assert {:error, :invalid_summary} = TurnResult.normalize(valid_turn_result(summary: 123))
    assert {:error, {:invalid_boolean, :blocked}} = TurnResult.normalize(valid_turn_result(blocked: "no"))

    assert {:ok, %TurnResult{blocker_type: :none, blocked: true}} =
             TurnResult.normalize(valid_turn_result(blocked: true, blocker_type: "   "))

    assert {:error, :invalid_blocker_type} =
             TurnResult.normalize(valid_turn_result(blocked: true, blocker_type: "ok"))

    assert {:error, :invalid_blocker_type} =
             TurnResult.normalize(valid_turn_result(blocked: true, blocker_type: 123))
  end

  test "log file configure creates the directory and tolerates repeated setup" do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    previous_max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes)
    previous_max_files = Application.get_env(:symphony_elixir, :log_file_max_files)
    previous_handler = :logger.get_handler_config(:symphony_disk_log)
    previous_default_handler = :logger.get_handler_config(:default)
    log_root = tmp_dir("log-file")
    log_file = Path.join(log_root, "nested/symphony.log")

    on_exit(fn ->
      restore_app_env(:symphony_elixir, :log_file, previous_log_file)
      restore_app_env(:symphony_elixir, :log_file_max_bytes, previous_max_bytes)
      restore_app_env(:symphony_elixir, :log_file_max_files, previous_max_files)
      restore_logger_handler(:symphony_disk_log, previous_handler)
      restore_logger_handler(:default, previous_default_handler)
      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_file)
    Application.put_env(:symphony_elixir, :log_file_max_bytes, 8_192)
    Application.put_env(:symphony_elixir, :log_file_max_files, 2)

    assert :ok = LogFile.configure()
    assert File.dir?(Path.dirname(log_file))
    assert {:ok, _handler_config} = :logger.get_handler_config(:symphony_disk_log)

    assert :ok = LogFile.configure()
    assert {:ok, _handler_config} = :logger.get_handler_config(:symphony_disk_log)
  end

  test "log file configure logs a warning and returns ok when handler config is invalid" do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    previous_max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes)
    previous_max_files = Application.get_env(:symphony_elixir, :log_file_max_files)
    previous_handler = :logger.get_handler_config(:symphony_disk_log)
    previous_default_handler = :logger.get_handler_config(:default)
    log_root = tmp_dir("log-file-invalid")
    log_file = Path.join(log_root, "nested/symphony.log")

    on_exit(fn ->
      restore_app_env(:symphony_elixir, :log_file, previous_log_file)
      restore_app_env(:symphony_elixir, :log_file_max_bytes, previous_max_bytes)
      restore_app_env(:symphony_elixir, :log_file_max_files, previous_max_files)
      restore_logger_handler(:symphony_disk_log, previous_handler)
      restore_logger_handler(:default, previous_default_handler)
      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_file)
    Application.put_env(:symphony_elixir, :log_file_max_bytes, 0)
    Application.put_env(:symphony_elixir, :log_file_max_files, 2)

    log =
      capture_log(fn ->
        assert :ok = LogFile.configure()
      end)

    assert log =~ "Failed to configure rotating log file handler"
    assert {:error, {:not_found, :symphony_disk_log}} = :logger.get_handler_config(:symphony_disk_log)
  end

  test "specs check handles direct files, ignores non-elixir files, and raises on parse errors" do
    specs_root = tmp_dir("specs-check")
    module_path = Path.join(specs_root, "sample.ex")
    note_path = Path.join(specs_root, "notes.txt")
    broken_path = Path.join(specs_root, "broken.ex")

    on_exit(fn -> File.rm_rf(specs_root) end)

    File.write!(module_path, """
    defmodule UtilityPhase6Sample do
      def run(input), do: input
    end
    """)

    File.write!(note_path, "not elixir")

    File.write!(broken_path, """
    defmodule BrokenSpecSample do
      def missing(
    end
    """)

    findings = SpecsCheck.missing_public_specs([module_path])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == [
             "UtilityPhase6Sample.run/1"
           ]

    assert SpecsCheck.missing_public_specs([note_path]) == []

    assert_raise ArgumentError, ~r/cannot convert the given list to a string/, fn ->
      SpecsCheck.missing_public_specs([broken_path])
    end
  end

  test "specs check scans directories, handles guarded specs, nested modules, duplicates, and exemptions" do
    specs_root = tmp_dir("specs-check-tree")
    alpha_path = Path.join(specs_root, "a.ex")
    beta_path = Path.join(specs_root, "b.ex")

    on_exit(fn -> File.rm_rf(specs_root) end)

    File.write!(alpha_path, """
    defmodule Alpha do
      @ignored_attribute true
      @spec guarded(term()) :: term() when term: var
      def guarded(value) when is_integer(value), do: value

      def missing(value), do: helper(value)
      def missing(value) when is_integer(value), do: value

      defp helper(value), do: value

      defmodule Nested do
        def nested_missing, do: :ok
      end
    end
    """)

    File.write!(beta_path, """
    defmodule Beta do
      @spec zero() :: integer()
      def zero, do: 0

      def missing_two(left, right), do: {left, right}
    end
    """)

    findings =
      SpecsCheck.missing_public_specs([specs_root], exemptions: ["Beta.missing_two/2"])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == [
             "Alpha.missing/1",
             "Nested.nested_missing/0"
           ]
  end

  test "specs check drops pending specs when non definition forms intervene" do
    specs_root = tmp_dir("specs-check-reset")
    module_path = Path.join(specs_root, "reset.ex")

    on_exit(fn -> File.rm_rf(specs_root) end)

    File.write!(module_path, """
    defmodule ResetSpec do
      @spec dropped(term()) :: term()
      1 + 1
      def dropped(value), do: value
    end
    """)

    assert Enum.map(SpecsCheck.missing_public_specs([module_path]), &SpecsCheck.finding_identifier/1) == [
             "ResetSpec.dropped/1"
           ]
  end

  test "config returns runner settings, hook maps, and prompt and server fallbacks" do
    previous_instance_name = System.get_env("SYMPHONY_INSTANCE_NAME")
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)
    runner_root = tmp_dir("runner-root")

    on_exit(fn ->
      restore_env("SYMPHONY_INSTANCE_NAME", previous_instance_name)
      restore_app_env(:symphony_elixir, :server_port_override, previous_port_override)
      File.rm_rf(runner_root)
    end)

    System.put_env("SYMPHONY_INSTANCE_NAME", "   ")

    write_workflow_file!(Workflow.workflow_file_path(),
      runner_install_root: Path.join(runner_root, "install"),
      runner_instance_name: nil,
      hook_before_run: "echo before",
      hook_after_run: "exit 7",
      hook_timeout_ms: 321,
      server_port: 4444,
      prompt: "   "
    )

    assert Config.runner() == %{
             install_root: Path.join(runner_root, "install"),
             instance_name: "default",
             channel: "stable",
             self_host_project: false
           }

    assert Config.workspace_hooks() == %{
             after_create: nil,
             before_run: "echo before",
             after_run: "exit 7",
             before_remove: nil,
             timeout_ms: 321
           }

    Application.put_env(:symphony_elixir, :server_port_override, 4311)
    assert Config.server_port() == 4311

    Application.put_env(:symphony_elixir, :server_port_override, -1)
    assert Config.server_port() == 4444
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
  end

  test "config normalizes empty assignee env refs and preserves uri codex homes" do
    previous_assignee = System.get_env("UTILITY_PHASE6_ASSIGNEE")

    on_exit(fn ->
      restore_env("UTILITY_PHASE6_ASSIGNEE", previous_assignee)
    end)

    System.put_env("UTILITY_PHASE6_ASSIGNEE", "")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: "$UTILITY_PHASE6_ASSIGNEE",
      codex_runtime_profile_codex_home: "https://codex.example.test/home",
      codex_runtime_profile_inherit_env: "maybe",
      codex_runtime_profile_env_allowlist: ""
    )

    assert Config.linear_assignee() == nil

    assert Config.codex_runtime_profile() == %{
             codex_home: "https://codex.example.test/home",
             inherit_env: true,
             env_allowlist: []
           }
  end

  test "workspace remove rejects paths outside the configured root" do
    workspace_root = tmp_dir("workspace-root")
    outside_root = tmp_dir("workspace-outside")
    outside_file = Path.join(outside_root, "outside.txt")

    on_exit(fn ->
      File.rm_rf(workspace_root)
      File.rm_rf(outside_root)
    end)

    File.write!(outside_file, "keep me")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    expanded_file = Path.expand(outside_file)
    expanded_root = Path.expand(workspace_root)

    assert {:error, {:workspace_outside_root, ^expanded_file, ^expanded_root}, ""} =
             Workspace.remove(outside_file)

    assert File.exists?(outside_file)
  end

  test "workspace run hooks treat missing before_run hooks and failing after_run hooks as non fatal" do
    workspace_root = tmp_dir("workspace-hooks")
    workspace = Path.join(workspace_root, "ISSUE-42")

    on_exit(fn -> File.rm_rf(workspace_root) end)

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_run: nil,
      hook_after_run: "printf 'hook failed' && exit 7",
      hook_timeout_ms: 1_000
    )

    assert :ok = Workspace.run_before_run_hook(workspace, "ISSUE-42")
    assert :ok = Workspace.run_after_run_hook(workspace, %{identifier: "ISSUE-42"})
  end

  test "linear adapter delegates identifier lookups and validates attachment responses" do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      restore_app_env(:symphony_elixir, :linear_client_module, previous_client)
      Process.delete({FakeLinearClient, :graphql_result})
      Process.delete({FakeLinearClient, :graphql_results})
    end)

    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, %{identifier: "MT-123"}} = Adapter.fetch_issue_by_identifier("MT-123")
    assert_receive {:fetch_issue_by_identifier_called, "MT-123"}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"attachmentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.attach_link("issue-1", "Spec", "https://example.test/spec")

    assert_receive {:graphql_called, attachment_query, %{issueId: "issue-1", title: "Spec", url: "https://example.test/spec"}}
    assert attachment_query =~ "attachmentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"attachmentCreate" => %{"success" => false}}}}
    )

    assert {:error, :attachment_create_failed} =
             Adapter.attach_link("issue-1", "Broken", "https://example.test/broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :network})

    assert {:error, :network} =
             Adapter.attach_link("issue-1", "Down", "https://example.test/down")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)

    assert {:error, :attachment_create_failed} =
             Adapter.attach_link("issue-1", "Odd", "https://example.test/odd")
  end

  test "dynamic tool report helpers return success payloads" do
    turn_response =
      DynamicTool.execute("report_agent_turn_result", %{
        "summary" => "Done",
        "files_touched" => [],
        "needs_another_turn" => false,
        "blocked" => false,
        "blocker_type" => "none"
      })

    assert turn_response["success"] == true
    assert [%{"text" => turn_text}] = turn_response["contentItems"]
    assert Jason.decode!(turn_text) == %{"reported" => true}

    verifier_response =
      DynamicTool.execute("report_verifier_result", %{
        "verdict" => "pass",
        "summary" => "Verified",
        "acceptance_gaps" => [],
        "risky_areas" => [],
        "evidence" => [],
        "raw_output" => "ok"
      })

    assert verifier_response["success"] == true
    assert [%{"text" => verifier_text}] = verifier_response["contentItems"]
    assert Jason.decode!(verifier_text) == %{"reported" => true}
  end

  defp valid_turn_result(overrides) do
    %{
      "summary" => "Done",
      "files_touched" => [],
      "needs_another_turn" => false,
      "blocked" => false,
      "blocker_type" => nil
    }
    |> Map.merge(Map.new(overrides))
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_logger_handler(id, {:ok, %{module: module} = handler_config}) do
    _ = :logger.remove_handler(id)
    :ok = :logger.add_handler(id, module, Map.drop(handler_config, [:id, :module]))
  end

  defp restore_logger_handler(id, _previous_handler) do
    _ = :logger.remove_handler(id)
    :ok
  end
end
