defmodule SymphonyElixir.IssueAcceptanceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.IssueAcceptance
  alias SymphonyElixir.Linear.Issue

  test "extracts checklist items under acceptance sections" do
    issue = %Issue{
      title: "Ship the verifier",
      description: """
      ## Acceptance Criteria
      - [ ] Publish only after verifier pass
      - [ ] Block unsafe merges

      ## Notes
      This should remain autonomous.
      """
    }

    acceptance = IssueAcceptance.from_issue(issue)

    refute acceptance.implicit?
    assert acceptance.source_sections == ["Acceptance Criteria"]
    assert acceptance.criteria == ["Publish only after verifier pass", "Block unsafe merges"]
    assert acceptance.summary =~ "Ship the verifier"
  end

  test "extracts bullet items under validation sections" do
    issue = %Issue{
      title: "Validate harnesses",
      description: """
      ### Validation
      - Reject missing version
      - Reject unknown keys
      """
    }

    acceptance = IssueAcceptance.from_issue(issue)

    refute acceptance.implicit?
    assert acceptance.criteria == ["Reject missing version", "Reject unknown keys"]
  end

  test "falls back to implicit acceptance when no explicit section exists" do
    issue = %Issue{
      title: "Improve verifier",
      description: "Use a hybrid verifier and keep the pipeline autonomous."
    }

    acceptance = IssueAcceptance.from_issue(issue)

    assert acceptance.implicit?
    assert acceptance.criteria == []
    assert acceptance.summary =~ "Improve verifier"
  end

  test "extracts bold heading sections and trims duplicate bullets" do
    acceptance =
      IssueAcceptance.from_issue(%{
        "title" => "Normalize acceptance",
        "description" => """
        **Done When**
        - Ship the gate
        - Ship the gate
        -   
        """
      })

    refute acceptance.implicit?
    assert acceptance.source_sections == ["Done When"]
    assert acceptance.criteria == ["Ship the gate"]
  end

  test "to_prompt_map preserves fallback summaries" do
    acceptance = IssueAcceptance.from_issue(%{"title" => nil, "description" => nil})

    assert acceptance.implicit?

    assert IssueAcceptance.to_prompt_map(acceptance) == %{
             implicit_acceptance: true,
             summary: "No explicit acceptance criteria were provided.",
             source_sections: [],
             criteria: []
           }
  end
end
