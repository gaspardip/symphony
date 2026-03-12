defmodule SymphonyElixir.RiskClassifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{RiskClassifier, WorkflowProfile}

  test "classifies docs-only changes as low-risk docs proof" do
    profile = WorkflowProfile.resolve("fully_autonomous")

    result =
      RiskClassifier.classify(
        %{changed_paths: ["README.md", "docs/usage.md", "config/settings.yml"]},
        %{},
        nil,
        profile
      )

    assert result.change_type == "docs_or_config"
    assert result.risk_level == "low"
    assert result.proof_class == "docs_only"
    assert result.approval_class == "autonomous"
    refute result.ui_proof_required
  end

  test "classifies ui-affecting changes with ui proof" do
    profile = WorkflowProfile.resolve("review_required")

    harness = %{
      ui_proof: %{
        required: true,
        mode: "local",
        source_paths: ["LocalEventsExplorer/Views"],
        test_paths: ["LocalEventsExplorerUITests"]
      }
    }

    result =
      RiskClassifier.classify(
        %{changed_paths: ["LocalEventsExplorer/Views/OnboardingView.swift"]},
        %{},
        harness,
        profile
      )

    assert result.change_type == "ui_affecting"
    assert result.risk_level == "high"
    assert result.proof_class == "ui"
    assert result.approval_class == "review_gate"
    assert result.ui_proof_required
    assert result.behavioral_proof_required
  end

  test "classifies deploy-sensitive changes" do
    profile = WorkflowProfile.resolve("fully_autonomous")

    result =
      RiskClassifier.classify(
        %{changed_paths: [".github/workflows/deploy.yml", ".symphony/harness.yml"]},
        %{},
        nil,
        profile
      )

    assert result.change_type == "deploy_sensitive"
    assert result.risk_level == "high"
    assert result.proof_class == "deploy"
  end
end
