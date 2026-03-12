defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.RepoHarness
      alias SymphonyElixir.RunInspector
      alias SymphonyElixir.RunPolicy
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        previous_path = System.get_env("PATH")
        SymphonyElixir.TestSupport.set_preferred_git_path!()

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          restore_env("PATH", previous_path)
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def set_preferred_git_path! do
    case preferred_git_bin_dir() do
      nil ->
        :ok

      git_bin_dir ->
        path =
          System.get_env("PATH", "")
          |> String.split(":", trim: true)
          |> Enum.reject(&(&1 == git_bin_dir))
          |> List.insert_at(0, git_bin_dir)
          |> Enum.join(":")

        System.put_env("PATH", path)
    end
  end

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp preferred_git_bin_dir do
    ["/opt/homebrew/opt/git/bin", "/usr/local/opt/git/bin"]
    |> Enum.find(fn dir -> File.exists?(Path.join(dir, "git")) end)
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_webhook_secret: nil,
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_handoff_mode: "assignee",
          tracker_required_labels: [],
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 600_000,
          discovery_poll_interval_ms: 600_000,
          healing_poll_interval_ms: 1_800_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          manual_enabled: true,
          manual_store_root: nil,
          runner_install_root: Path.join(System.tmp_dir!(), "symphony-runner"),
          runner_instance_name: "test-runner",
          runner_self_host_project: false,
          company_name: nil,
          company_repo_url: nil,
          company_internal_project_name: nil,
          company_internal_project_url: nil,
          company_mode: nil,
          company_policy_pack: "private_autopilot",
          company_author_profile_path: nil,
          company_credential_registry_path: nil,
          portfolio_instances: [],
          policy_packs: %{},
          max_concurrent_agents: 10,
          max_turns: 3,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_runtime_profile_codex_home: nil,
          codex_runtime_profile_inherit_env: true,
          codex_runtime_profile_env_allowlist: [],
          codex_reasoning_stages: nil,
          codex_reasoning_providers: nil,
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          policy_require_checkout: true,
          policy_require_pr_before_review: true,
          policy_require_validation: true,
          policy_require_verifier: true,
          policy_retry_validation_failures_within_run: true,
          policy_max_validation_attempts_per_run: 2,
          policy_publish_required: true,
          policy_post_merge_verification_required: true,
          policy_automerge_on_green: true,
          policy_default_issue_class: "fully_autonomous",
          policy_stop_on_noop_turn: true,
          policy_max_noop_turns: 1,
          policy_token_budget: %{
            per_turn_input: 150_000,
            per_issue_total: 500_000,
            per_issue_total_output: nil
          },
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_webhook_secret = Keyword.get(config, :tracker_webhook_secret)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_handoff_mode = Keyword.get(config, :tracker_handoff_mode)
    tracker_required_labels = Keyword.get(config, :tracker_required_labels)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    discovery_poll_interval_ms = Keyword.get(config, :discovery_poll_interval_ms)
    healing_poll_interval_ms = Keyword.get(config, :healing_poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    manual_enabled = Keyword.get(config, :manual_enabled)
    manual_store_root = Keyword.get(config, :manual_store_root)
    runner_install_root = Keyword.get(config, :runner_install_root)
    runner_instance_name = Keyword.get(config, :runner_instance_name)
    runner_self_host_project = Keyword.get(config, :runner_self_host_project)
    company_name = Keyword.get(config, :company_name)
    company_repo_url = Keyword.get(config, :company_repo_url)
    company_internal_project_name = Keyword.get(config, :company_internal_project_name)
    company_internal_project_url = Keyword.get(config, :company_internal_project_url)
    company_mode = Keyword.get(config, :company_mode)
    company_policy_pack = Keyword.get(config, :company_policy_pack)
    company_author_profile_path = Keyword.get(config, :company_author_profile_path)
    company_credential_registry_path = Keyword.get(config, :company_credential_registry_path)
    portfolio_instances = Keyword.get(config, :portfolio_instances)
    policy_packs = Keyword.get(config, :policy_packs)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_runtime_profile_codex_home = Keyword.get(config, :codex_runtime_profile_codex_home)
    codex_runtime_profile_inherit_env = Keyword.get(config, :codex_runtime_profile_inherit_env)
    codex_runtime_profile_env_allowlist = Keyword.get(config, :codex_runtime_profile_env_allowlist)
    codex_reasoning_stages = Keyword.get(config, :codex_reasoning_stages)
    codex_reasoning_providers = Keyword.get(config, :codex_reasoning_providers)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    policy_require_checkout = Keyword.get(config, :policy_require_checkout)
    policy_require_pr_before_review = Keyword.get(config, :policy_require_pr_before_review)
    policy_require_validation = Keyword.get(config, :policy_require_validation)
    policy_require_verifier = Keyword.get(config, :policy_require_verifier)
    policy_retry_validation_failures_within_run = Keyword.get(config, :policy_retry_validation_failures_within_run)
    policy_max_validation_attempts_per_run = Keyword.get(config, :policy_max_validation_attempts_per_run)
    policy_publish_required = Keyword.get(config, :policy_publish_required)
    policy_post_merge_verification_required = Keyword.get(config, :policy_post_merge_verification_required)
    policy_automerge_on_green = Keyword.get(config, :policy_automerge_on_green)
    policy_default_issue_class = Keyword.get(config, :policy_default_issue_class)
    policy_stop_on_noop_turn = Keyword.get(config, :policy_stop_on_noop_turn)
    policy_max_noop_turns = Keyword.get(config, :policy_max_noop_turns)
    policy_token_budget = Keyword.get(config, :policy_token_budget)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  webhook_secret: #{yaml_value(tracker_webhook_secret)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  handoff_mode: #{yaml_value(tracker_handoff_mode)}",
        "  required_labels: #{yaml_value(tracker_required_labels)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "  discovery_interval_ms: #{yaml_value(discovery_poll_interval_ms)}",
        "  healing_interval_ms: #{yaml_value(healing_poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        "manual:",
        "  enabled: #{yaml_value(manual_enabled)}",
        "  store_root: #{yaml_value(manual_store_root)}",
        "runner:",
        "  install_root: #{yaml_value(runner_install_root)}",
        "  instance_name: #{yaml_value(runner_instance_name)}",
        "  self_host_project: #{yaml_value(runner_self_host_project)}",
        "company:",
        "  name: #{yaml_value(company_name)}",
        "  repo_url: #{yaml_value(company_repo_url)}",
        "  internal_project_name: #{yaml_value(company_internal_project_name)}",
        "  internal_project_url: #{yaml_value(company_internal_project_url)}",
        "  mode: #{yaml_value(company_mode)}",
        "  policy_pack: #{yaml_value(company_policy_pack)}",
        "  author_profile_path: #{yaml_value(company_author_profile_path)}",
        "  credential_registry_path: #{yaml_value(company_credential_registry_path)}",
        portfolio_yaml(portfolio_instances),
        policy_packs_yaml(policy_packs),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  runtime_profile: #{yaml_value(%{codex_home: codex_runtime_profile_codex_home, inherit_env: codex_runtime_profile_inherit_env, env_allowlist: codex_runtime_profile_env_allowlist})}",
        "  reasoning: #{yaml_value(%{stages: codex_reasoning_stages, providers: codex_reasoning_providers})}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        policy_yaml(
          policy_require_checkout,
          policy_require_pr_before_review,
          policy_require_validation,
          policy_require_verifier,
          policy_retry_validation_failures_within_run,
          policy_max_validation_attempts_per_run,
          policy_publish_required,
          policy_post_merge_verification_required,
          policy_automerge_on_green,
          policy_default_issue_class,
          policy_stop_on_noop_turn,
          policy_max_noop_turns,
          policy_token_budget
        ),
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp policy_packs_yaml(packs) when packs in [%{}, nil], do: nil

  defp portfolio_yaml(instances) when instances in [[], nil], do: nil

  defp portfolio_yaml(instances) when is_list(instances) do
    ["portfolio:" | yaml_key_value_lines("instances", instances, 2)]
    |> Enum.join("\n")
  end

  defp portfolio_yaml(instances), do: "portfolio: #{yaml_value(instances)}"

  defp policy_packs_yaml(packs) when is_map(packs) do
    ["policy_packs:" | yaml_object_lines(packs, 2)]
    |> Enum.join("\n")
  end

  defp policy_packs_yaml(packs), do: "policy_packs: #{yaml_value(packs)}"

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp yaml_object_lines(map, indent) when is_map(map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      yaml_key_value_lines(to_string(key), value, indent)
    end)
  end

  defp yaml_key_value_lines(key, value, indent) when is_map(value) do
    prefix = String.duplicate(" ", indent)
    ["#{prefix}#{key}:" | yaml_object_lines(value, indent + 2)]
  end

  defp yaml_key_value_lines(key, values, indent) when is_list(values) do
    prefix = String.duplicate(" ", indent)

    case values do
      [] ->
        ["#{prefix}#{key}: []"]

      [head | _] when is_map(head) ->
        ["#{prefix}#{key}:" | yaml_list_of_objects_lines(values, indent + 2)]

      _ ->
        ["#{prefix}#{key}: [#{Enum.map_join(values, ", ", &yaml_value/1)}]"]
    end
  end

  defp yaml_key_value_lines(key, value, indent) do
    prefix = String.duplicate(" ", indent)
    ["#{prefix}#{key}: #{yaml_value(value)}"]
  end

  defp yaml_list_of_objects_lines(values, indent) do
    Enum.flat_map(values, fn value ->
      prefix = String.duplicate(" ", indent)

      case value do
        %{} = map ->
          ["#{prefix}-" | yaml_object_lines(map, indent + 2)]

        other ->
          ["#{prefix}- #{yaml_value(other)}"]
      end
    end)
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  # credo:disable-for-next-line
  defp policy_yaml(
         require_checkout,
         require_pr_before_review,
         require_validation,
         require_verifier,
         retry_validation_failures_within_run,
         max_validation_attempts_per_run,
         publish_required,
         post_merge_verification_required,
         automerge_on_green,
         default_issue_class,
         stop_on_noop_turn,
         max_noop_turns,
         token_budget
       ) do
    [
      "policy:",
      "  require_checkout: #{yaml_value(require_checkout)}",
      "  require_pr_before_review: #{yaml_value(require_pr_before_review)}",
      "  require_validation: #{yaml_value(require_validation)}",
      "  require_verifier: #{yaml_value(require_verifier)}",
      "  retry_validation_failures_within_run: #{yaml_value(retry_validation_failures_within_run)}",
      "  max_validation_attempts_per_run: #{yaml_value(max_validation_attempts_per_run)}",
      "  publish_required: #{yaml_value(publish_required)}",
      "  post_merge_verification_required: #{yaml_value(post_merge_verification_required)}",
      "  automerge_on_green: #{yaml_value(automerge_on_green)}",
      "  default_issue_class: #{yaml_value(default_issue_class)}",
      "  stop_on_noop_turn: #{yaml_value(stop_on_noop_turn)}",
      "  max_noop_turns: #{yaml_value(max_noop_turns)}",
      "  token_budget: #{yaml_value(token_budget)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
