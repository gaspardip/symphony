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

  test "normalizes invalid workflow profile values back to safe defaults" do
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
        fully_autonomous:
          merge_mode: invalid_mode
          approval_gate_state: "   "
          deploy_approval_gate_state: ""
          preview_deploy_mode: invalid_preview
          production_deploy_mode: invalid_production
          max_turns_override: 0
      ---

      Ticket `{{ issue.identifier }}`.
      """
    )

    SymphonyElixir.WorkflowStore.force_reload()

    profile = WorkflowProfile.resolve("fully_autonomous")

    assert profile.merge_mode == :automerge
    assert profile.approval_gate_state == "Human Review"
    assert profile.approval_gate_kind == "review"
    assert profile.deploy_approval_gate_state == "Human Review"
    assert profile.deploy_approval_gate_kind == "review"
    assert profile.preview_deploy_mode == :disabled
    assert profile.production_deploy_mode == :disabled
    assert profile.max_turns_override == nil
  end

  test "helper accessors normalize gate kinds and profile names" do
    assert WorkflowProfile.approval_gate_kind("Deploy Approval") == "deploy_approval"
    assert WorkflowProfile.approval_gate_kind("Human Approval") == "review"
    assert WorkflowProfile.approval_gate_kind("Something Else") == "approval"
    assert WorkflowProfile.approval_gate_kind(nil) == "approval"

    assert WorkflowProfile.name_string(:never_automerge) == "never_automerge"
    assert WorkflowProfile.name_string(%WorkflowProfile{name: :review_required}) == "review_required"
    assert WorkflowProfile.name_string(nil) == "nil"

    refute WorkflowProfile.approval_gate_state?(nil)
  end

  test "resolves valid deploy modes and unknown policy classes safely" do
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
        fully_autonomous:
          deploy_approval_gate_state: Deploy Approval
          preview_deploy_mode: after_merge
          production_deploy_mode: after_preview
          post_merge_verification_required: false
          post_deploy_verification_required: false
      ---

      Ticket `{{ issue.identifier }}`.
      """
    )

    SymphonyElixir.WorkflowStore.force_reload()

    profile = WorkflowProfile.resolve("fully_autonomous")
    fallback = WorkflowProfile.resolve("totally_unknown")

    assert profile.deploy_approval_gate_state == "Deploy Approval"
    assert profile.deploy_approval_gate_kind == "deploy_approval"
    assert profile.preview_deploy_mode == :after_merge
    assert profile.production_deploy_mode == :after_preview
    refute profile.post_merge_verification_required
    refute profile.post_deploy_verification_required

    assert fallback.name == :fully_autonomous
    assert fallback.merge_mode == :automerge
    assert fallback.approval_gate_state == "Human Review"
    assert WorkflowProfile.default_profiles()[:fully_autonomous][:merge_mode] == :automerge
  end

  test "resolves atom policy classes while preserving default deploy approval state" do
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
      policy_packs:
        client_safe:
          deploy_approval_gate_state: Client Approval
      ---

      Ticket `{{ issue.identifier }}`.
      """
    )

    SymphonyElixir.WorkflowStore.force_reload()

    profile = WorkflowProfile.resolve(:review_required, policy_pack: :client_safe)

    assert profile.name == :review_required
    assert profile.deploy_approval_gate_state == "Deploy Approval"
    assert profile.deploy_approval_gate_kind == "deploy_approval"
  end

  test "approval gate helpers normalize duplicate configured states" do
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
        fully_autonomous:
          approval_gate_state: Client Approval
          deploy_approval_gate_state: Client Approval
      ---

      Ticket `{{ issue.identifier }}`.
      """
    )

    SymphonyElixir.WorkflowStore.force_reload()

    assert WorkflowProfile.resolve(nil).name == :fully_autonomous
    assert WorkflowProfile.approval_gate_state?(:client_approval) == false
    assert WorkflowProfile.approval_gate_state?("client_approval")
    assert WorkflowProfile.approval_gate_state?("client-approval")
    assert Enum.count(WorkflowProfile.approval_gate_states(), &(&1 == "Client Approval")) == 1
  end
end
