defmodule SymphonyElixir.ManualIssueSpecTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ManualIssueSpec

  test "validates payloads, renders markdown sections, and builds manual issues" do
    payload = %{
      "id" => "clz-14",
      "identifier" => "CLZ-14",
      "title" => "Unify onboarding persistence",
      "description" => "Keep onboarding state in one source of truth.",
      "acceptance_criteria" => ["Persist onboarding completion", "Do not regress relaunch behavior"],
      "validation" => "Complete onboarding\nRelaunch app",
      "out_of_scope" => ["Large settings refactor"],
      "policy_class" => "review_required",
      "labels" => ["symphony:events", "pilot"],
      "priority" => 2,
      "url" => "https://linear.app/cylize/issue/CLZ-14",
      "branch_name" => "gaspar/clz-14",
      "internal_identifier" => "SYM-14",
      "internal_url" => "https://linear.app/internal/issue/SYM-14"
    }

    assert {:ok, spec} = ManualIssueSpec.validate(payload)
    assert spec.id == "clz-14"
    assert spec.acceptance_criteria == ["Persist onboarding completion", "Do not regress relaunch behavior"]
    assert spec.validation == ["Complete onboarding", "Relaunch app"]
    assert spec.out_of_scope == ["Large settings refactor"]
    assert spec.policy_class == "review_required"

    rendered = ManualIssueSpec.render_description(spec)
    assert rendered =~ "## Description"
    assert rendered =~ "## Acceptance Criteria"
    assert rendered =~ "## Validation"
    assert rendered =~ "## Out of Scope"

    issue = ManualIssueSpec.to_issue(spec)
    assert issue.id == "manual:clz-14"
    assert issue.external_id == "clz-14"
    assert issue.canonical_identifier == "CLZ-14"
    assert issue.identifier == "CLZ-14"
    assert issue.state == "Todo"
    assert issue.source == :manual
    assert "policy:review-required" in issue.labels
    assert "symphony:events" in issue.labels
    assert issue.branch_name == "gaspar/clz-14"
    assert issue.internal_identifier == "SYM-14"
    assert issue.internal_url == "https://linear.app/internal/issue/SYM-14"
  end

  test "rejects missing required fields and invalid policy classes" do
    assert {:error, {:invalid_manual_issue_spec, {:missing_required_field, "identifier"}}} =
             ManualIssueSpec.validate(%{
               "id" => "clz-14",
               "title" => "Missing identifier",
               "acceptance_criteria" => ["One"]
             })

    assert {:error, {:invalid_manual_issue_spec, {:invalid_policy_class, "chaos"}}} =
             ManualIssueSpec.validate(%{
               "id" => "clz-14",
               "identifier" => "CLZ-14",
               "title" => "Bad policy",
               "acceptance_criteria" => ["One"],
               "policy_class" => "chaos"
             })
  end

  test "acceptance criteria can be provided as a multiline string" do
    assert {:ok, spec} =
             ManualIssueSpec.validate(%{
               "id" => "clz-15",
               "identifier" => "CLZ-15",
               "title" => "String lists",
               "acceptance_criteria" => "First line\nSecond line\n"
             })

    assert spec.acceptance_criteria == ["First line", "Second line"]
  end
end
