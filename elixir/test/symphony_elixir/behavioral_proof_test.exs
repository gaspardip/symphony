defmodule SymphonyElixir.BehavioralProofTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.BehavioralProof

  test "requires proof for behavior changes declared in the harness" do
    result =
      BehavioralProof.evaluate(
        System.tmp_dir!(),
        %{
          behavioral_proof: %{
            required: true,
            mode: "unit_first",
            source_paths: ["LocalEventsExplorer"],
            test_paths: ["LocalEventsExplorerTests"],
            artifact_path: nil
          }
        },
        ["LocalEventsExplorer/ContentView.swift"]
      )

    assert result.required?
    refute result.satisfied?
    assert result.reason =~ "Behavioral proof is required before publish"
  end

  test "accepts changed tests as behavioral proof" do
    result =
      BehavioralProof.evaluate(
        System.tmp_dir!(),
        %{
          behavioral_proof: %{
            required: true,
            mode: "unit_first",
            source_paths: ["LocalEventsExplorer"],
            test_paths: ["LocalEventsExplorerTests"],
            artifact_path: nil
          }
        },
        [
          "LocalEventsExplorer/ContentView.swift",
          "LocalEventsExplorerTests/OnboardingPersistenceTests.swift"
        ]
      )

    assert result.required?
    assert result.satisfied?
    assert result.proof_paths == ["LocalEventsExplorerTests/OnboardingPersistenceTests.swift"]
  end

  test "accepts harness prefixes declared with trailing slashes" do
    result =
      BehavioralProof.evaluate(
        System.tmp_dir!(),
        %{
          behavioral_proof: %{
            required: true,
            mode: "unit_first",
            source_paths: ["LocalEventsExplorer/"],
            test_paths: ["LocalEventsExplorerTests/"],
            artifact_path: nil
          }
        },
        [
          "LocalEventsExplorer/ContentView.swift",
          "LocalEventsExplorerTests/OnboardingPersistenceTests.swift"
        ]
      )

    assert result.required?
    assert result.satisfied?
    assert result.behavior_paths == ["LocalEventsExplorer/ContentView.swift"]
    assert result.proof_paths == ["LocalEventsExplorerTests/OnboardingPersistenceTests.swift"]
  end

  test "docs-only changes do not require behavioral proof by default" do
    result = BehavioralProof.evaluate(System.tmp_dir!(), nil, ["README.md", "docs/runbook.md"])

    refute result.required?
    assert result.satisfied?
  end

  test "artifact-only mode accepts the configured proof artifact" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-behavioral-proof-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, ".symphony/proof.json"), "{}")

    result =
      BehavioralProof.evaluate(
        workspace,
        %{
          behavioral_proof: %{
            required: true,
            mode: "harness_artifact_only",
            source_paths: ["Sources"],
            test_paths: [],
            artifact_path: ".symphony/proof.json"
          }
        },
        ["Sources/Feature.swift"]
      )

    assert result.required?
    assert result.satisfied?
    assert result.artifact_present?
  end
end
