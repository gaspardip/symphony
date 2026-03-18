defmodule SymphonyElixir.PolicyPackTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{IssuePolicy, PolicyPack}

  test "built-in packs resolve sane defaults" do
    private_pack = PolicyPack.resolve("private_autopilot")
    client_pack = PolicyPack.resolve("client_safe")
    active_pack = PolicyPack.resolve("client_safe_pr_active")

    assert private_pack.operating_mode == "private_autopilot"
    assert private_pack.tracker_mutation_mode == "allowed"
    assert private_pack.external_comment_mode == "allowed"
    assert private_pack.draft_first_required
    assert private_pack.confidence_language == "measured"
    assert "pull_request" in private_pack.allowed_external_channels
    assert private_pack.default_issue_class == "fully_autonomous"
    assert "fully_autonomous" in private_pack.allowed_policy_classes
    assert client_pack.operating_mode == "client_safe_shadow"
    assert client_pack.tracker_mutation_mode == "forbidden"
    assert client_pack.external_comment_mode == "draft_only"
    assert client_pack.draft_first_required
    assert client_pack.confidence_language == "measured"
    assert client_pack.allowed_external_channels == ["pull_request"]
    refute client_pack.preview_deploy_allowed
    assert client_pack.default_issue_class == "review_required"
    refute "fully_autonomous" in client_pack.allowed_policy_classes
    assert active_pack.operating_mode == "client_safe_pr_active"
    assert active_pack.tracker_mutation_mode == "forbidden"
    assert active_pack.pr_posting_mode == "allowed"
  end

  test "helper predicates expose contractor-safe permissions" do
    private_pack = PolicyPack.resolve("private_autopilot")
    client_pack = PolicyPack.resolve("client_safe")
    active_pack = PolicyPack.resolve("client_safe_pr_active")

    assert PolicyPack.tracker_mutation_allowed?(private_pack)
    assert PolicyPack.pr_posting_allowed?(private_pack)
    assert PolicyPack.thread_resolution_allowed?(private_pack)
    assert PolicyPack.external_comment_posting_allowed?(private_pack)

    refute PolicyPack.tracker_mutation_allowed?(client_pack)
    refute PolicyPack.pr_posting_allowed?(client_pack)
    refute PolicyPack.thread_resolution_allowed?(client_pack)
    refute PolicyPack.external_comment_posting_allowed?(client_pack)

    refute PolicyPack.tracker_mutation_allowed?(active_pack)
    assert PolicyPack.pr_posting_allowed?(active_pack)
    refute PolicyPack.thread_resolution_allowed?(active_pack)
    refute PolicyPack.external_comment_posting_allowed?(active_pack)
  end

  test "issue policy blocks a class disallowed by the selected pack" do
    issue = %Issue{id: "issue-pack", identifier: "PACK-01", labels: ["policy:fully-autonomous"]}

    assert {:error, conflict} =
             IssuePolicy.resolve(issue,
               default: "review_required",
               allowed_classes: ["review_required", "never_automerge"],
               policy_pack: "client_safe"
             )

    assert conflict.code == :policy_pack_disallows_class
    assert conflict.rule_id == "policy.pack_disallows_class"
    assert conflict.requested_class == "fully_autonomous"
    assert conflict.pack_name == "client_safe"
  end

  test "automerge window defers outside the configured client window" do
    pack = %PolicyPack{
      name: :client_safe,
      description: "Client safe with window",
      default_issue_class: "review_required",
      allowed_policy_classes: ["review_required", "never_automerge"],
      merge_window: %{
        timezone: "Etc/UTC",
        days: [1],
        start_hour: 9,
        end_hour: 17
      }
    }

    monday_evening = DateTime.from_naive!(~N[2026-03-09 20:00:00], "Etc/UTC")

    assert {:deferred, wait} = PolicyPack.automerge_window_status(pack, monday_evening)
    assert wait.timezone == "Etc/UTC"
    assert wait.start_hour == 9
    assert wait.end_hour == 17
    assert String.starts_with?(wait.next_allowed_at, "2026-03-16T09:00:00")
  end

  test "automerge window normalizes raw string weekdays before computing the next window" do
    pack = %PolicyPack{
      name: :private_autopilot,
      description: "raw merge window",
      default_issue_class: "fully_autonomous",
      allowed_policy_classes: ["fully_autonomous"],
      merge_window: %{
        timezone: "Etc/UTC",
        days: ["monday"],
        start_hour: 9,
        end_hour: 10
      }
    }

    wednesday_morning = DateTime.from_naive!(~N[2026-03-11 07:17:40], "Etc/UTC")

    assert {:deferred, wait} = PolicyPack.automerge_window_status(pack, wednesday_morning)
    assert wait.next_allowed_at == "2026-03-16T09:00:00Z"
  end

  test "production deploy window defers outside the configured deploy window" do
    pack = %PolicyPack{
      name: :private_autopilot,
      description: "private autopilot with deploy window",
      default_issue_class: "fully_autonomous",
      allowed_policy_classes: ["fully_autonomous", "review_required", "never_automerge"],
      production_deploy_window: %{
        timezone: "Etc/UTC",
        days: [2],
        start_hour: 10,
        end_hour: 12
      }
    }

    monday_evening = DateTime.from_naive!(~N[2026-03-09 20:00:00], "Etc/UTC")

    assert {:deferred, wait} = PolicyPack.production_deploy_window_status(pack, monday_evening)
    assert wait.timezone == "Etc/UTC"
    assert wait.start_hour == 10
    assert wait.end_hour == 12
    assert String.starts_with?(wait.next_allowed_at, "2026-03-10T10:00:00")
  end

  test "workload label status requires one matching label when configured" do
    pack = %PolicyPack{
      name: :client_safe,
      description: "maintenance only",
      default_issue_class: "review_required",
      allowed_policy_classes: ["review_required", "never_automerge"],
      required_any_issue_labels: ["scope:maintenance", "scope:ops"],
      forbidden_issue_labels: []
    }

    assert {:missing_required_any, ["scope:maintenance", "scope:ops"]} =
             PolicyPack.workload_label_status(pack, ["symphony:events"])

    assert :allowed =
             PolicyPack.workload_label_status(pack, ["symphony:events", "scope:maintenance"])
  end

  test "workload label status rejects forbidden labels when configured" do
    pack = %PolicyPack{
      name: :client_safe,
      description: "block features",
      default_issue_class: "review_required",
      allowed_policy_classes: ["review_required", "never_automerge"],
      required_any_issue_labels: [],
      forbidden_issue_labels: ["scope:feature", "scope:experimental"]
    }

    assert {:forbidden_present, ["scope:feature"]} =
             PolicyPack.workload_label_status(pack, ["scope:feature", "symphony:events"])

    assert :allowed =
             PolicyPack.workload_label_status(pack, ["scope:maintenance", "symphony:events"])
  end

  test "resolves map overrides through normalization helpers" do
    pack =
      PolicyPack.resolve(%{
        "name" => "client_safe",
        "description" => "  Client-safe custom pack  ",
        "operating_mode" => "  custom_shadow  ",
        "default_issue_class" => "never_automerge",
        "approval_gate_state" => "  Client Review  ",
        "deploy_approval_gate_state" => "  Deploy Review  ",
        "preview_deploy_mode" => "after_merge",
        "production_deploy_mode" => "after_preview",
        "allowed_policy_classes" => ["review_required", "never_automerge", "never_automerge", "unknown"],
        "required_any_issue_labels" => "scope:ops, scope:ops, scope:maintenance",
        "forbidden_issue_labels" => ["scope:feature", " ", nil],
        "tracker_mutation_mode" => "allowed",
        "pr_posting_mode" => "draft_only",
        "thread_resolution_mode" => "allowed",
        "external_comment_mode" => "forbidden",
        "draft_first_required" => false,
        "confidence_language" => "  plain  ",
        "allowed_external_channels" => ["pull_request", "tracker", "tracker"],
        "preview_deploy_allowed" => true,
        "production_deploy_allowed" => true,
        "max_concurrent_runs_per_company" => 3,
        "max_merges_per_day_per_repo" => 9,
        "repo_frozen" => true,
        "company_frozen" => false,
        "merge_window" => %{"timezone" => "Etc/UTC", "days" => ["mon", "bad"], "start_hour" => "9", "end_hour" => "17"},
        "production_deploy_window" => %{"timezone" => "Etc/UTC", "days" => [2], "start_hour" => 10, "end_hour" => 12}
      })

    assert pack.name == :client_safe_shadow
    assert pack.description == "Client-safe custom pack"
    assert pack.operating_mode == "custom_shadow"
    assert pack.default_issue_class == "never_automerge"
    assert pack.approval_gate_state == "Client Review"
    assert pack.deploy_approval_gate_state == "Deploy Review"
    assert pack.preview_deploy_mode == :after_merge
    assert pack.production_deploy_mode == :after_preview
    assert pack.allowed_policy_classes == ["review_required", "never_automerge"]
    assert pack.required_any_issue_labels == ["scope:ops", "scope:maintenance"]
    assert pack.forbidden_issue_labels == ["scope:feature"]
    assert pack.tracker_mutation_mode == "allowed"
    assert pack.pr_posting_mode == "draft_only"
    assert pack.thread_resolution_mode == "allowed"
    assert pack.external_comment_mode == "forbidden"
    assert PolicyPack.draft_first_required?(pack)
    assert pack.confidence_language == "measured"
    assert pack.allowed_external_channels == ["pull_request"]
    assert pack.preview_deploy_allowed
    assert pack.production_deploy_allowed
    assert pack.max_concurrent_runs_per_company == 3
    assert pack.max_merges_per_day_per_repo == 9
    assert pack.repo_frozen
    refute pack.company_frozen
    assert PolicyPack.repo_or_company_frozen?(pack)
    assert pack.merge_window == %{timezone: "Etc/UTC", days: [1], start_hour: 9, end_hour: 17}
    assert pack.production_deploy_window == %{timezone: "Etc/UTC", days: [2], start_hour: 10, end_hour: 12}
    assert PolicyPack.allows?(pack, :never_automerge)
    refute PolicyPack.allows?(pack, :fully_autonomous)
    refute PolicyPack.contractor_mode?(pack)
    assert PolicyPack.name_string(pack) == "client_safe_shadow"
  end

  test "window helpers allow open windows and invalid timezones fall back to allowed" do
    open_pack = %PolicyPack{
      name: :private_autopilot,
      description: "open window",
      default_issue_class: "fully_autonomous",
      allowed_policy_classes: ["fully_autonomous"],
      merge_window: %{timezone: "Etc/UTC", days: [1], start_hour: 9, end_hour: 17},
      production_deploy_window: %{timezone: "Bad/Timezone", days: [1], start_hour: 9, end_hour: 17}
    }

    monday_morning = DateTime.from_naive!(~N[2026-03-09 10:00:00], "Etc/UTC")

    assert :allowed = PolicyPack.automerge_window_status(open_pack, monday_morning)
    assert :allowed = PolicyPack.production_deploy_window_status(open_pack, monday_morning)
  end
end
