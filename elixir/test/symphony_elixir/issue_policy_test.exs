defmodule SymphonyElixir.IssuePolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.RuleCatalog

  test "resolve uses override before label before default" do
    issue = %Issue{id: "issue-policy", identifier: "MT-POLICY", labels: ["policy:review-required"]}

    assert {:ok, %{class: :review_required, source: :label, override: nil}} =
             IssuePolicy.resolve(issue, default: "fully_autonomous")

    assert {:ok, %{class: :never_automerge, source: :override, override: :never_automerge}} =
             IssuePolicy.resolve(issue,
               override: "never_automerge",
               default: "fully_autonomous"
             )

    unlabeled_issue = %Issue{id: "issue-default", identifier: "MT-DEFAULT", labels: ["ops"]}

    assert {:ok, %{class: :fully_autonomous, source: :default, labels: []}} =
             IssuePolicy.resolve(unlabeled_issue, default: "fully_autonomous")
  end

  test "resolve rejects conflicting policy labels with a typed conflict" do
    issue = %Issue{
      id: "issue-conflict",
      identifier: "MT-CONFLICT",
      labels: ["policy:review-required", "policy:never-automerge"]
    }

    assert {:error, conflict} = IssuePolicy.resolve(issue, default: "fully_autonomous")
    assert conflict.code == :invalid_labels
    assert conflict.rule_id == RuleCatalog.rule_id(:policy_invalid_labels)
    assert conflict.failure_class == RuleCatalog.failure_class(:policy_invalid_labels)
    assert conflict.human_action == RuleCatalog.human_action(:policy_invalid_labels)
    assert Enum.sort(conflict.labels) == ["policy:never-automerge", "policy:review-required"]
  end

  test "normalize helpers cover valid and invalid classes" do
    assert IssuePolicy.valid_classes() == [:fully_autonomous, :review_required, :never_automerge]

    assert IssuePolicy.normalize_class(:review_required) == :review_required
    assert IssuePolicy.normalize_class("never-automerge") == :never_automerge
    assert IssuePolicy.normalize_class(" fully_autonomous ") == :fully_autonomous
    assert IssuePolicy.normalize_class("unknown") == nil
    assert IssuePolicy.normalize_class(123) == nil

    assert IssuePolicy.class_to_string(:review_required) == "review_required"
    assert IssuePolicy.class_to_string(nil) == nil
    assert IssuePolicy.label_for_class(:never_automerge) == "policy:never-automerge"
    assert IssuePolicy.label_for_class("bad") == nil
  end

  test "policy_labels normalizes map and string label inputs" do
    map_issue = %{"labels" => [" Policy:Review-Required ", "ops", "policy:review-required"]}

    assert IssuePolicy.policy_labels(map_issue) == ["policy:review-required"]
    assert IssuePolicy.policy_labels(%{labels: nil}) == []
    assert IssuePolicy.policy_labels(nil) == []
  end
end
