defmodule SymphonyElixir.UiProofTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunInspector
  alias SymphonyElixir.UiProof

  test "does not require ui proof for docs-only changes" do
    result =
      UiProof.evaluate(
        System.tmp_dir!(),
        nil,
        ["README.md", "docs/runbook.md"],
        %RunInspector.Snapshot{pr_url: nil, check_statuses: []}
      )

    refute result.required?
    assert result.verify_satisfied?
  end

  test "requires local ui proof for changed ui paths and accepts changed ui tests" do
    result =
      UiProof.evaluate(
        System.tmp_dir!(),
        %{
          ui_proof: %{
            required: true,
            mode: "local",
            source_paths: ["LocalEventsExplorer/Views"],
            test_paths: ["LocalEventsExplorerUITests"],
            artifact_paths: [],
            required_checks: [],
            command: nil,
            provider: nil,
            result_url_pattern: nil,
            scenarios: []
          }
        },
        [
          "LocalEventsExplorer/Views/MapExploreView.swift",
          "LocalEventsExplorerUITests/MapExploreViewUITests.swift"
        ],
        %RunInspector.Snapshot{pr_url: nil, check_statuses: []}
      )

    assert result.required?
    assert result.verify_required?
    assert result.verify_satisfied?
    assert result.proof_paths == ["LocalEventsExplorerUITests/MapExploreViewUITests.swift"]
  end

  test "defers ci check ui proof until a pr exists" do
    result =
      UiProof.evaluate(
        System.tmp_dir!(),
        %{
          ui_proof: %{
            required: true,
            mode: "ci_check",
            source_paths: ["src/components"],
            test_paths: [],
            artifact_paths: [],
            required_checks: ["chromatic"],
            command: nil,
            provider: "chromatic",
            result_url_pattern: "https://example.test?pr={pr_url}",
            scenarios: []
          }
        },
        ["src/components/Button.tsx"],
        %RunInspector.Snapshot{pr_url: nil, check_statuses: []}
      )

    assert result.required?
    refute result.verify_required?
    assert result.deferred?
    assert result.merge_required?
    refute result.merge_satisfied?
  end

  test "marks ci check ui proof satisfied when declared checks pass" do
    result =
      UiProof.evaluate(
        System.tmp_dir!(),
        %{
          ui_proof: %{
            required: true,
            mode: "ci_check",
            source_paths: ["src/components"],
            test_paths: [],
            artifact_paths: [],
            required_checks: ["chromatic"],
            command: nil,
            provider: "chromatic",
            result_url_pattern: "https://example.test?pr={pr_url}",
            scenarios: []
          }
        },
        ["src/components/Button.tsx"],
        %RunInspector.Snapshot{
          pr_url: "https://github.com/example/repo/pull/1",
          check_statuses: [%{name: "chromatic", status: "COMPLETED", conclusion: "SUCCESS"}]
        }
      )

    assert result.merge_required?
    assert result.merge_satisfied?
    assert result.external_result_url =~ "https://github.com/example/repo/pull/1"
  end
end
