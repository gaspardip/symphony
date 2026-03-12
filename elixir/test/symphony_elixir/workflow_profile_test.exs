defmodule SymphonyElixir.WorkflowProfileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, PolicyPack, Workflow, WorkflowProfile}

  test "resolves default profiles from policy class" do
    assert WorkflowProfile.resolve("fully_autonomous").merge_mode == :automerge
    assert WorkflowProfile.resolve("review_required").merge_mode == :review_gate
    assert WorkflowProfile.resolve("never_automerge").merge_mode == :manual_only
  end

  test "workflow config can override profile settings" do
    path = Workflow.workflow_file_path()

    File.write!(
      path,
      """
      ---
      tracker:
        kind: linear
        endpoint: https://api.linear.app/graphql
        api_key: token
        project_slug: project
        handoff_mode: assignee
        active_states:
          - Todo
          - In Progress
        terminal_states:
          - Closed
          - Cancelled
          - Canceled
          - Duplicate
          - Done
      policy:
        default_issue_class: fully_autonomous
      profiles:
        review_required:
          merge_mode: manual_only
          approval_gate_state: Client Review
          max_turns_override: 7
      ---

      Ticket `{{ issue.identifier }}`.
      """
    )

    SymphonyElixir.WorkflowStore.force_reload()

    assert Config.workflow_profiles()[:review_required][:merge_mode] == "manual_only"
    assert Config.workflow_profiles()[:review_required][:approval_gate_state] == "Client Review"

    profile = WorkflowProfile.resolve("review_required")
    assert profile.merge_mode == :manual_only
    assert profile.approval_gate_state == "Client Review"
    assert profile.max_turns_override == 7
  end

  test "approval gate state helpers include configured override" do
    path = Workflow.workflow_file_path()

    File.write!(
      path,
      """
      ---
      tracker:
        kind: linear
        endpoint: https://api.linear.app/graphql
        api_key: token
        project_slug: project
      profiles:
        review_required:
          approval_gate_state: Client Review
      ---

      Ticket `{{ issue.identifier }}`.
      """
    )

    SymphonyElixir.WorkflowStore.force_reload()

    assert WorkflowProfile.approval_gate_state("review_required") == "Client Review"
    assert WorkflowProfile.approval_gate_state?("Client Review")
    refute WorkflowProfile.approval_gate_state?("Random Review")
    assert "Client Review" in WorkflowProfile.approval_gate_states()
  end

  test "company policy pack can override the approval gate state" do
    path = Workflow.workflow_file_path()

    File.write!(
      path,
      """
      ---
      tracker:
        kind: linear
        endpoint: https://api.linear.app/graphql
        api_key: token
        project_slug: project
      company:
        policy_pack: client_safe
      policy_packs:
        client_safe:
          approval_gate_state: Client Approval
      ---

      Ticket `{{ issue.identifier }}`.
      """
    )

    SymphonyElixir.WorkflowStore.force_reload()

    assert PolicyPack.resolve(:client_safe).approval_gate_state == "Client Approval"
    assert WorkflowProfile.approval_gate_state("review_required", policy_pack: :client_safe) == "Client Approval"
    assert WorkflowProfile.approval_gate_state?("Client Approval", policy_pack: :client_safe)
    assert "Client Approval" in WorkflowProfile.approval_gate_states(policy_pack: :client_safe)
  end

  test "client_safe pack defaults review-required issues to Client Approval" do
    profile = WorkflowProfile.resolve("review_required", policy_pack: :client_safe)

    assert profile.approval_gate_kind == "client_approval"
    assert profile.approval_gate_state == "Client Approval"
    assert profile.merge_mode == :review_gate
  end
end
