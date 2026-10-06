defmodule SymphonyElixir.StageProviderValueContractTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.AgentProvider

  test "provider map preserves unrestricted non-string values without treating them as modules" do
    load!(%{agent: %{provider: "claude", providers: %{plan: 17, implement: %{unexpected: "value"}, verifier: ["codex-cli"]}}})
    assert Config.agent_provider_for_stage(:plan) == 17
    assert Config.agent_provider_for_stage(:implement) == %{"unexpected" => "value"}
    assert Config.agent_provider_for_stage(:verifier) == ["codex-cli"]

    for stage <- [:plan, :implement, :verifier] do
      assert AgentProvider.resolve_for_stage(stage) == SymphonyElixir.AgentProvider.Codex
    end
  end

  test "nil and false stage values preserve the existing global fallback" do
    load!(%{agent: %{provider: "claude", providers: %{plan: nil, implement: false}}})
    assert Config.agent_provider_for_stage(:plan) == nil
    assert Config.agent_provider_for_stage(:implement) == false
    assert AgentProvider.resolve_for_stage(:plan) == SymphonyElixir.AgentProvider.Claude
    assert AgentProvider.resolve_for_stage(:implement) == SymphonyElixir.AgentProvider.Claude
  end

  test "provider mappings coexist with existing model and reasoning selection" do
    load!(%{
      agent: %{
        provider: "claude",
        model: "global-model",
        providers: %{plan: "claude", implement: "codex-cli"},
        models: %{plan: "plan-model", implement: "implementation-model"},
        reasoning: %{stages: %{implement: "deep", verify: "rigorous", verifier: "balanced"}, providers: %{codex: %{reasoning_map: %{deep: "high", rigorous: "high", balanced: "medium"}}}}
      }
    })

    assert Config.agent_model() == "global-model"
    assert Config.agent_model_for_stage(:plan) == "plan-model"
    assert Config.agent_model_for_stage("implement") == "implementation-model"
    assert Config.reasoning_tier_for_stage("implement") == "deep"
    assert Config.reasoning_tier_for_stage(:verify) == "rigorous"
    assert Config.provider_reasoning_value("codex", :implement) == "high"
    assert AgentProvider.resolve_for_stage(:plan) == SymphonyElixir.AgentProvider.Claude
    assert AgentProvider.resolve_for_stage(:implement) == SymphonyElixir.AgentProvider.CodexCLI
  end

  defp load!(config) do
    File.write!(Workflow.workflow_file_path(), "---\n" <> Jason.encode!(config) <> "\n---\nLocal configuration contract fixture.\n")
    :ok = WorkflowStore.force_reload()
  end
end
