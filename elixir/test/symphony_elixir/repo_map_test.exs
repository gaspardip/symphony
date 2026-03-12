defmodule SymphonyElixir.RepoMapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RepoMap

  test "builds a compact map from harness data" do
    map =
      RepoMap.from_harness(%{
        base_branch: "main",
        project: %{type: "ios-app", xcodeproj: "App.xcodeproj", scheme: "AppScheme"},
        runtime: %{simulator_destination: "platform=iOS Simulator,name=iPhone", developer_dir: "xcode-select"},
        behavioral_proof: %{
          required: true,
          mode: "unit_first",
          source_paths: ["Sources/"],
          test_paths: ["Tests/"]
        },
        ui_proof: %{
          required: false,
          mode: "hybrid",
          source_paths: ["Sources/UI/"],
          test_paths: ["UITests/"],
          artifact_paths: ["artifacts/ui/*.png"]
        }
      })

    assert map.platform == "ios-app"
    assert map.base_branch == "main"
    assert map.project_ref == "App.xcodeproj | AppScheme"
    assert map.behavioral_proof.mode == "unit_first"
    assert map.ui_proof.mode == "hybrid"
  end

  test "renders a compact prompt block" do
    block =
      RepoMap.prompt_block(%RepoMap{
        platform: "ios-app",
        base_branch: "main",
        project_ref: "App.xcodeproj | AppScheme",
        runtime_note: "Use declared runtime target platform=iOS Simulator,name=iPhone.",
        behavioral_proof: %{
          required: true,
          mode: "unit_first",
          source_paths: ["Sources/"],
          test_paths: ["Tests/"],
          artifact_paths: []
        },
        ui_proof: %{
          required: false,
          mode: "local",
          source_paths: ["Sources/UI/"],
          test_paths: ["UITests/"],
          artifact_paths: []
        }
      })

    assert block =~ "Repo map:"
    assert block =~ "Platform: ios-app"
    assert block =~ "Base branch: main"
    assert block =~ "Behavioral proof: required; mode=unit_first; source=Sources/; tests=Tests/."
    assert block =~ "UI proof: optional; mode=local; source=Sources/UI/; tests=UITests/."
  end
end
