defmodule SymphonyElixir.StageProviderConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.AgentProvider

  test "YAML overrides select a provider for each existing stage" do
    load_frontmatter!("agent:\n  provider: codex\n  providers:\n    plan: claude\n    implement: codex-cli\n    verifier: codex\n")
    assert {:ok, %{config: %{"agent" => %{"providers" => %{"plan" => "claude"}}}}} = Workflow.current()
    assert Config.agent_provider_for_stage("plan") == "claude"
    assert Config.agent_provider_for_stage(:implement) == "codex-cli"
    assert AgentProvider.resolve_for_stage("plan") == SymphonyElixir.AgentProvider.Claude
    assert AgentProvider.resolve_for_stage(:implement) == SymphonyElixir.AgentProvider.CodexCLI
    assert AgentProvider.resolve_for_stage("verifier") == SymphonyElixir.AgentProvider.Codex
  end

  test "JSON frontmatter preserves overrides through the public workflow store" do
    load_json!(%{agent: %{provider: "claude", providers: %{plan: "codex-cli", implement: "codex"}}})
    assert Config.agent_provider_for_stage(:plan) == "codex-cli"
    assert Config.agent_provider_for_stage("implement") == "codex"
    assert AgentProvider.resolve_for_stage(:plan) == SymphonyElixir.AgentProvider.CodexCLI
    assert AgentProvider.resolve_for_stage("implement") == SymphonyElixir.AgentProvider.Codex
  end

  test "legacy codex providers retain the existing precedence when agent overrides are absent" do
    load_json!(%{codex: %{provider: "codex", providers: %{plan: "claude", implement: "codex-cli"}}})
    assert Config.agent_provider_for_stage("plan") == "claude"
    assert AgentProvider.resolve_for_stage("implement") == SymphonyElixir.AgentProvider.CodexCLI
  end

  test "agent provider mappings take precedence over the legacy mapping" do
    load_json!(%{
      agent: %{provider: "claude", providers: %{implement: "codex-cli"}},
      codex: %{provider: "codex", providers: %{implement: "claude", plan: "codex"}}
    })

    assert Config.agent_provider() == "claude"
    assert Config.agent_provider_for_stage(:implement) == "codex-cli"
    assert Config.agent_provider_for_stage(:plan) == nil
    assert AgentProvider.resolve_for_stage(:plan) == SymphonyElixir.AgentProvider.Claude
  end

  test "an explicit empty agent mapping masks a legacy mapping and keeps the global fallback" do
    load_json!(%{agent: %{provider: "claude", providers: %{}}, codex: %{providers: %{implement: "codex-cli"}}})
    assert Config.agent_provider_for_stage(:implement) == nil
    assert AgentProvider.resolve_for_stage(:implement) == SymphonyElixir.AgentProvider.Claude
  end

  test "missing mappings retain explicit resolution fallback and configured overrides win over it" do
    load_json!(%{agent: %{provider: "codex-cli"}})
    assert Config.agent_provider_for_stage(:implement) == nil
    assert AgentProvider.resolve_for_stage(:implement) == SymphonyElixir.AgentProvider.CodexCLI
    assert AgentProvider.resolve_for_stage(:implement, provider: "claude") == SymphonyElixir.AgentProvider.Claude
    load_json!(%{agent: %{providers: %{implement: "codex-cli"}}})
    assert AgentProvider.resolve_for_stage(:implement, provider: "claude") == SymphonyElixir.AgentProvider.CodexCLI
  end

  test "unknown stages are not interned as atoms by the provider mapping" do
    stage = "unknown_stage_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(stage) end
    load_json!(%{agent: %{provider: "claude", providers: %{stage => "codex-cli", "implement" => "codex"}}})
    assert Config.agent_provider_for_stage(stage) == nil
    assert Config.agent_provider_for_stage(:implement) == "codex"
    assert_raise ArgumentError, fn -> String.to_existing_atom(stage) end
  end

  test "unknown provider names retain the existing Codex resolution fallback" do
    load_json!(%{agent: %{providers: %{implement: "unknown-provider"}}})
    assert Config.agent_provider_for_stage(:implement) == "unknown-provider"
    assert AgentProvider.resolve_for_stage(:implement) == SymphonyElixir.AgentProvider.Codex
  end

  defp load_json!(config), do: load_frontmatter!(Jason.encode!(config))

  defp load_frontmatter!(frontmatter) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> frontmatter <> "\n---\nLocal provider configuration fixture.\n")
    :ok = WorkflowStore.force_reload()
  end
end
