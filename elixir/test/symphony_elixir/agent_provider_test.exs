defmodule SymphonyElixir.AgentProviderTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentProvider

  describe "resolve/1" do
    test "defaults to Codex provider" do
      assert AgentProvider.resolve() == SymphonyElixir.AgentProvider.Codex
    end

    test "resolves 'codex' to Codex provider" do
      assert AgentProvider.resolve(provider: "codex") == SymphonyElixir.AgentProvider.Codex
    end

    test "resolves 'claude' to Claude provider" do
      assert AgentProvider.resolve(provider: "claude") == SymphonyElixir.AgentProvider.Claude
    end

    test "resolves unknown string to Codex fallback" do
      assert AgentProvider.resolve(provider: "unknown") == SymphonyElixir.AgentProvider.Codex
    end

    test "resolves atom module directly" do
      assert AgentProvider.resolve(provider: MyCustomProvider) == MyCustomProvider
    end
  end

  describe "resolve_for_stage/2" do
    test "falls back to default provider when no stage override" do
      assert AgentProvider.resolve_for_stage("implement") == SymphonyElixir.AgentProvider.Codex
    end

    test "falls back to explicit provider when no stage override" do
      assert AgentProvider.resolve_for_stage("implement", provider: "claude") ==
               SymphonyElixir.AgentProvider.Claude
    end
  end
end
