defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias NimbleOptions
  alias SymphonyElixir.{IssuePolicy, PolicyPack, RepoHarness, RunnerRuntime, Workflow}

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_linear_handoff_mode "assignee"
  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_poll_interval_ms 600_000
  @default_healing_poll_interval_ms 1_800_000
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @default_runner_install_root Path.join(System.user_home!(), ".local/share/symphony-runner")
  @default_runner_instance_name "default"
  @default_runner_channel "stable"
  @default_author_profile_path Path.join([System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"), "symphony", "author_profile.json"])
  @default_credential_registry_path Path.join([System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"), "symphony", "credential_registry.json"])
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_agent_max_turns 3
  @default_max_retry_backoff_ms 300_000
  @default_codex_command "codex app-server"
  @default_reasoning_stages %{
    implement: "balanced",
    verify: "deep",
    verifier: "rigorous"
  }
  @default_provider_reasoning_maps %{
    "codex" => %{
      "minimal" => "low",
      "balanced" => "medium",
      "deep" => "high",
      "rigorous" => "xhigh"
    },
    "claude" => %{
      "minimal" => "low",
      "balanced" => "medium",
      "deep" => "high",
      "rigorous" => "high"
    }
  }
  @default_agent_turn_timeout_ms 3_600_000
  @default_agent_read_timeout_ms 5_000
  @default_agent_stall_timeout_ms 300_000
  @default_policy_require_checkout true
  @default_policy_require_pr_before_review true
  @default_policy_require_validation true
  @default_policy_require_verifier true
  @default_policy_retry_validation_failures_within_run true
  @default_policy_max_validation_attempts_per_run 2
  @default_policy_publish_required true
  @default_policy_post_merge_verification_required true
  @default_policy_automerge_on_green true
  @default_policy_default_issue_class "fully_autonomous"
  @default_company_policy_pack "private_autopilot"
  @default_company_mode "private_autopilot"
  @default_policy_stop_on_noop_turn true
  @default_policy_max_noop_turns 1
  @default_policy_per_turn_input_budget 150_000
  @default_policy_per_issue_total_budget 500_000
  @default_policy_implement_per_turn_input_soft_budget 60_000
  @default_policy_implement_per_turn_input_hard_budget 120_000
  @default_policy_verify_per_turn_input_soft_budget 40_000
  @default_policy_verify_per_turn_input_hard_budget 80_000
  @default_policy_review_fix_enabled true
  @default_policy_review_fix_per_turn_input_soft_budget 60_000
  @default_policy_review_fix_per_turn_input_hard_budget 120_000
  @default_policy_review_fix_retry_2_per_turn_input_hard_budget 150_000
  @default_policy_review_fix_retry_3_per_turn_input_hard_budget 220_000
  @default_policy_review_fix_max_turns_in_window 3
  @default_policy_review_fix_retry_2_max_turns_in_window 5
  @default_policy_review_fix_retry_3_max_turns_in_window 7
  @default_policy_review_fix_per_issue_total_extension_budget 150_000
  @default_policy_review_fix_auto_retry_limit 3
  @default_policy_review_fix_narrow_scope_batch_size 1
  @default_codex_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @default_codex_thread_sandbox "workspace-write"
  @default_manual_enabled true
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_observability_metrics_enabled true
  @default_observability_metrics_path "/metrics"
  @default_observability_tracing_enabled true
  @default_observability_structured_logs true
  @default_observability_debug_artifacts_enabled true
  @default_observability_debug_capture_on_failure true
  @default_observability_debug_artifact_max_bytes 262_144
  @default_observability_debug_artifact_tail_bytes 131_072
  @default_server_host "127.0.0.1"
  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 endpoint: [type: :string, default: @default_linear_endpoint],
                                 api_key: [type: {:or, [:string, nil]}, default: nil],
                                 webhook_secret: [type: {:or, [:string, nil]}, default: nil],
                                 project_slug: [type: {:or, [:string, nil]}, default: nil],
                                 assignee: [type: {:or, [:string, nil]}, default: nil],
                                 handoff_mode: [
                                   type: :string,
                                   default: @default_linear_handoff_mode
                                 ],
                                 required_labels: [
                                   type: {:list, :string},
                                   default: []
                                 ],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 interval_ms: [type: :integer, default: @default_poll_interval_ms],
                                 discovery_interval_ms: [
                                   type: :integer,
                                   default: @default_poll_interval_ms
                                 ],
                                 healing_interval_ms: [
                                   type: :integer,
                                   default: @default_healing_poll_interval_ms
                                 ]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [type: {:or, [:string, nil]}, default: @default_workspace_root]
                               ]
                             ],
                             manual: [
                               type: :map,
                               default: %{},
                               keys: [
                                 enabled: [type: :boolean, default: @default_manual_enabled],
                                 store_root: [type: {:or, [:string, nil]}, default: nil]
                               ]
                             ],
                             runner: [
                               type: :map,
                               default: %{},
                               keys: [
                                 install_root: [
                                   type: {:or, [:string, nil]},
                                   default: @default_runner_install_root
                                 ],
                                 instance_name: [
                                   type: {:or, [:string, nil]},
                                   default: @default_runner_instance_name
                                 ],
                                 channel: [
                                   type: {:or, [:string, nil]},
                                   default: @default_runner_channel
                                 ],
                                 self_host_project: [
                                   type: :boolean,
                                   default: false
                                 ]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ],
                                 provider: [type: {:or, [:string, nil]}, default: nil],
                                 model: [type: {:or, [:string, nil]}, default: nil],
                                 providers: [type: {:or, [:map, nil]}, default: nil],
                                 reasoning: [
                                   type: :map,
                                   default: %{}
                                 ],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_turn_timeout_ms
                                 ],
                                 read_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_read_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_agent_stall_timeout_ms
                                 ],
                                 codex: [
                                   type: :map,
                                   default: %{},
                                   keys: [
                                     command: [type: :string, default: @default_codex_command],
                                     runtime_profile: [
                                       type: :map,
                                       default: %{},
                                       keys: [
                                         codex_home: [type: {:or, [:string, nil]}, default: nil],
                                         inherit_env: [type: :boolean, default: true],
                                         env_allowlist: [type: {:list, :string}, default: []]
                                       ]
                                     ]
                                   ]
                                 ]
                               ]
                             ],
                             policy: [
                               type: :map,
                               default: %{},
                               keys: [
                                 require_checkout: [
                                   type: :boolean,
                                   default: @default_policy_require_checkout
                                 ],
                                 require_pr_before_review: [
                                   type: :boolean,
                                   default: @default_policy_require_pr_before_review
                                 ],
                                 require_validation: [
                                   type: :boolean,
                                   default: @default_policy_require_validation
                                 ],
                                 require_verifier: [
                                   type: :boolean,
                                   default: @default_policy_require_verifier
                                 ],
                                 retry_validation_failures_within_run: [
                                   type: :boolean,
                                   default: @default_policy_retry_validation_failures_within_run
                                 ],
                                 max_validation_attempts_per_run: [
                                   type: :pos_integer,
                                   default: @default_policy_max_validation_attempts_per_run
                                 ],
                                 publish_required: [
                                   type: :boolean,
                                   default: @default_policy_publish_required
                                 ],
                                 post_merge_verification_required: [
                                   type: :boolean,
                                   default: @default_policy_post_merge_verification_required
                                 ],
                                 automerge_on_green: [
                                   type: :boolean,
                                   default: @default_policy_automerge_on_green
                                 ],
                                 default_issue_class: [
                                   type: :string,
                                   default: @default_policy_default_issue_class
                                 ],
                                 stop_on_noop_turn: [
                                   type: :boolean,
                                   default: @default_policy_stop_on_noop_turn
                                 ],
                                 max_noop_turns: [
                                   type: :pos_integer,
                                   default: @default_policy_max_noop_turns
                                 ],
                                 token_budget: [
                                   type: :map,
                                   default: %{},
                                   keys: [
                                     per_turn_input: [
                                       type: {:or, [:non_neg_integer, nil]},
                                       default: @default_policy_per_turn_input_budget
                                     ],
                                     per_issue_total: [
                                       type: {:or, [:non_neg_integer, nil]},
                                       default: @default_policy_per_issue_total_budget
                                     ],
                                     per_issue_total_output: [
                                       type: {:or, [:non_neg_integer, nil]},
                                       default: nil
                                     ],
                                     stages: [
                                       type: :map,
                                       default: %{},
                                       keys: [
                                         implement: [
                                           type: :map,
                                           default: %{},
                                           keys: [
                                             per_turn_input_soft: [
                                               type: {:or, [:non_neg_integer, nil]},
                                               default: @default_policy_implement_per_turn_input_soft_budget
                                             ],
                                             per_turn_input_hard: [
                                               type: {:or, [:non_neg_integer, nil]},
                                               default: @default_policy_implement_per_turn_input_hard_budget
                                             ]
                                           ]
                                         ],
                                         verify: [
                                           type: :map,
                                           default: %{},
                                           keys: [
                                             per_turn_input_soft: [
                                               type: {:or, [:non_neg_integer, nil]},
                                               default: @default_policy_verify_per_turn_input_soft_budget
                                             ],
                                             per_turn_input_hard: [
                                               type: {:or, [:non_neg_integer, nil]},
                                               default: @default_policy_verify_per_turn_input_hard_budget
                                             ]
                                           ]
                                         ]
                                       ]
                                     ],
                                     review_fix: [
                                       type: :map,
                                       default: %{},
                                       keys: [
                                         enabled: [
                                           type: :boolean,
                                           default: @default_policy_review_fix_enabled
                                         ],
                                         per_turn_input_soft: [
                                           type: {:or, [:non_neg_integer, nil]},
                                           default: @default_policy_review_fix_per_turn_input_soft_budget
                                         ],
                                         per_turn_input_hard: [
                                           type: {:or, [:non_neg_integer, nil]},
                                           default: @default_policy_review_fix_per_turn_input_hard_budget
                                         ],
                                         retry_2_per_turn_input_hard: [
                                           type: {:or, [:non_neg_integer, nil]},
                                           default: @default_policy_review_fix_retry_2_per_turn_input_hard_budget
                                         ],
                                         retry_3_per_turn_input_hard: [
                                           type: {:or, [:non_neg_integer, nil]},
                                           default: @default_policy_review_fix_retry_3_per_turn_input_hard_budget
                                         ],
                                         max_turns_in_window: [
                                           type: :non_neg_integer,
                                           default: @default_policy_review_fix_max_turns_in_window
                                         ],
                                         retry_2_max_turns_in_window: [
                                           type: :non_neg_integer,
                                           default: @default_policy_review_fix_retry_2_max_turns_in_window
                                         ],
                                         retry_3_max_turns_in_window: [
                                           type: :non_neg_integer,
                                           default: @default_policy_review_fix_retry_3_max_turns_in_window
                                         ],
                                         per_issue_total_extension: [
                                           type: {:or, [:non_neg_integer, nil]},
                                           default: @default_policy_review_fix_per_issue_total_extension_budget
                                         ],
                                         auto_retry_limit: [
                                           type: :non_neg_integer,
                                           default: @default_policy_review_fix_auto_retry_limit
                                         ],
                                         narrow_scope_batch_size: [
                                           type: :pos_integer,
                                           default: @default_policy_review_fix_narrow_scope_batch_size
                                         ]
                                       ]
                                     ]
                                   ]
                                 ]
                               ]
                             ],
                             profiles: [
                               type: :map,
                               default: %{}
                             ],
                             company: [
                               type: :map,
                               default: %{},
                               keys: [
                                 name: [
                                   type: :string,
                                   default: ""
                                 ],
                                 repo_url: [
                                   type: :string,
                                   default: ""
                                 ],
                                 internal_project_name: [
                                   type: {:or, [:string, nil]},
                                   default: nil
                                 ],
                                 internal_project_url: [
                                   type: {:or, [:string, nil]},
                                   default: nil
                                 ],
                                 mode: [
                                   type: {:or, [:string, nil]},
                                   default: nil
                                 ],
                                 policy_pack: [
                                   type: :string,
                                   default: @default_company_policy_pack
                                 ],
                                 author_profile_path: [
                                   type: {:or, [:string, nil]},
                                   default: @default_author_profile_path
                                 ],
                                 credential_registry_path: [
                                   type: {:or, [:string, nil]},
                                   default: @default_credential_registry_path
                                 ]
                               ]
                             ],
                             policy_packs: [
                               type: :map,
                               default: %{}
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [type: :pos_integer, default: @default_hook_timeout_ms]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 dashboard_enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ],
                                 metrics_enabled: [
                                   type: :boolean,
                                   default: @default_observability_metrics_enabled
                                 ],
                                 metrics_path: [
                                   type: :string,
                                   default: @default_observability_metrics_path
                                 ],
                                 tracing_enabled: [
                                   type: :boolean,
                                   default: @default_observability_tracing_enabled
                                 ],
                                 structured_logs: [
                                   type: :boolean,
                                   default: @default_observability_structured_logs
                                 ],
                                 debug_artifacts: [
                                   type: :map,
                                   default: %{},
                                   keys: [
                                     enabled: [
                                       type: :boolean,
                                       default: @default_observability_debug_artifacts_enabled
                                     ],
                                     capture_on_failure: [
                                       type: :boolean,
                                       default: @default_observability_debug_capture_on_failure
                                     ],
                                     root: [type: {:or, [:string, nil]}, default: nil],
                                     max_bytes: [
                                       type: :pos_integer,
                                       default: @default_observability_debug_artifact_max_bytes
                                     ],
                                     tail_bytes: [
                                       type: :pos_integer,
                                       default: @default_observability_debug_artifact_tail_bytes
                                     ]
                                   ]
                                 ]
                               ]
                             ],
                             portfolio: [
                               type: :map,
                               default: %{},
                               keys: [
                                 instances: [type: {:list, :map}, default: []]
                               ]
                             ],
                             server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 port: [type: {:or, [:non_neg_integer, nil]}, default: nil],
                                 host: [type: :string, default: @default_server_host]
                               ]
                             ]
                           )

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type runner_settings :: %{
          install_root: String.t() | nil,
          instance_name: String.t() | nil,
          channel: String.t(),
          self_host_project: boolean()
        }
  @type manual_settings :: %{
          enabled: boolean(),
          store_root: String.t()
        }
  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }
  @type codex_runtime_profile_settings :: %{
          codex_home: String.t() | nil,
          inherit_env: boolean(),
          env_allowlist: [String.t()]
        }
  @type reasoning_tier :: String.t()
  @type policy_settings :: %{
          require_checkout: boolean(),
          require_pr_before_review: boolean(),
          require_validation: boolean(),
          require_verifier: boolean(),
          retry_validation_failures_within_run: boolean(),
          max_validation_attempts_per_run: pos_integer(),
          publish_required: boolean(),
          post_merge_verification_required: boolean(),
          automerge_on_green: boolean(),
          default_issue_class: String.t(),
          stop_on_noop_turn: boolean(),
          max_noop_turns: pos_integer(),
          token_budget: %{
            per_turn_input: non_neg_integer() | nil,
            per_issue_total: non_neg_integer() | nil,
            per_issue_total_output: non_neg_integer() | nil,
            stages: %{
              implement: %{
                per_turn_input_soft: non_neg_integer() | nil,
                per_turn_input_hard: non_neg_integer() | nil
              },
              verify: %{
                per_turn_input_soft: non_neg_integer() | nil,
                per_turn_input_hard: non_neg_integer() | nil
              }
            },
            review_fix: %{
              enabled: boolean(),
              per_turn_input_soft: non_neg_integer() | nil,
              per_turn_input_hard: non_neg_integer() | nil,
              retry_2_per_turn_input_hard: non_neg_integer() | nil,
              retry_3_per_turn_input_hard: non_neg_integer() | nil,
              max_turns_in_window: non_neg_integer(),
              retry_2_max_turns_in_window: non_neg_integer(),
              retry_3_max_turns_in_window: non_neg_integer(),
              per_issue_total_extension: non_neg_integer() | nil,
              auto_retry_limit: non_neg_integer(),
              narrow_scope_batch_size: pos_integer()
            }
          }
        }
  @type workflow_profile_settings :: %{
          optional(atom()) => %{
            merge_mode: String.t() | atom(),
            approval_gate_state: String.t(),
            deploy_approval_gate_state: String.t(),
            post_merge_verification_required: boolean(),
            preview_deploy_mode: String.t() | atom(),
            production_deploy_mode: String.t() | atom(),
            post_deploy_verification_required: boolean(),
            max_turns_override: pos_integer() | nil
          }
        }
  @type policy_pack_settings :: %{
          optional(atom()) => %{
            description: String.t() | nil,
            default_issue_class: String.t(),
            allowed_policy_classes: [String.t()],
            required_any_issue_labels: [String.t()],
            forbidden_issue_labels: [String.t()],
            approval_gate_state: String.t() | nil,
            preview_deploy_mode: String.t() | atom() | nil,
            production_deploy_mode: String.t() | atom() | nil,
            deploy_approval_gate_state: String.t() | nil,
            merge_window: map() | nil,
            production_deploy_window: map() | nil
          }
        }
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }
  @type observability_settings :: %{
          dashboard_enabled: boolean(),
          refresh_ms: pos_integer(),
          render_interval_ms: pos_integer(),
          metrics_enabled: boolean(),
          metrics_path: String.t(),
          tracing_enabled: boolean(),
          structured_logs: boolean(),
          debug_artifacts: %{
            enabled: boolean(),
            capture_on_failure: boolean(),
            root: String.t(),
            max_bytes: pos_integer(),
            tail_bytes: pos_integer()
          }
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    get_in(validated_workflow_options(), [:tracker, :kind])
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    get_in(validated_workflow_options(), [:tracker, :endpoint])
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    validated_workflow_options()
    |> get_in([:tracker, :api_key])
    |> resolve_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    get_in(validated_workflow_options(), [:tracker, :project_slug])
  end

  @spec linear_webhook_secret() :: String.t() | nil
  def linear_webhook_secret do
    validated_workflow_options()
    |> get_in([:tracker, :webhook_secret])
    |> resolve_env_value(System.get_env("LINEAR_WEBHOOK_SECRET"))
    |> normalize_secret_value()
  end

  @spec github_webhook_secret() :: String.t() | nil
  def github_webhook_secret do
    System.get_env("GITHUB_WEBHOOK_SECRET")
    |> normalize_secret_value()
  end

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee do
    validated_workflow_options()
    |> get_in([:tracker, :assignee])
    |> resolve_env_value(System.get_env("LINEAR_ASSIGNEE"))
    |> normalize_secret_value()
  end

  @spec linear_required_labels() :: [String.t()]
  def linear_required_labels do
    get_in(validated_workflow_options(), [:tracker, :required_labels]) || []
  end

  @spec tracker_handoff_mode() :: String.t()
  def tracker_handoff_mode do
    validated_workflow_options()
    |> get_in([:tracker, :handoff_mode])
    |> normalize_handoff_mode()
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    get_in(validated_workflow_options(), [:tracker, :active_states])
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    discovery_poll_interval_ms()
  end

  @spec discovery_poll_interval_ms() :: pos_integer()
  def discovery_poll_interval_ms do
    options = validated_workflow_options()

    interval_ms = get_in(options, [:polling, :interval_ms])
    discovery_interval_ms = get_in(options, [:polling, :discovery_interval_ms])

    if discovery_interval_ms == @default_poll_interval_ms and interval_ms != @default_poll_interval_ms do
      interval_ms
    else
      discovery_interval_ms || interval_ms
    end
  end

  @spec healing_poll_interval_ms() :: pos_integer()
  def healing_poll_interval_ms do
    get_in(validated_workflow_options(), [:polling, :healing_interval_ms])
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_path_value(@default_workspace_root)
  end

  @spec manual() :: manual_settings()
  def manual do
    %{
      enabled: manual_enabled?(),
      store_root: manual_store_root()
    }
  end

  @spec manual_enabled?() :: boolean()
  def manual_enabled? do
    case get_in(validated_workflow_options(), [:manual, :enabled]) do
      value when is_boolean(value) -> value
      _ -> @default_manual_enabled
    end
  end

  @spec manual_store_root() :: Path.t()
  def manual_store_root do
    validated_workflow_options()
    |> get_in([:manual, :store_root])
    |> resolve_path_value(default_manual_store_root())
  end

  @spec runner() :: runner_settings()
  def runner do
    %{
      install_root: runner_install_root(),
      instance_name: runner_instance_name(),
      channel: runner_channel(),
      self_host_project: runner_self_host_project?()
    }
  end

  @spec runner_install_root() :: Path.t()
  def runner_install_root do
    validated_workflow_options()
    |> get_in([:runner, :install_root])
    |> resolve_path_value(@default_runner_install_root)
  end

  @spec runner_instance_name() :: String.t()
  def runner_instance_name do
    validated_workflow_options()
    |> get_in([:runner, :instance_name])
    |> resolve_env_value(System.get_env("SYMPHONY_INSTANCE_NAME"))
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @default_runner_instance_name
          trimmed -> trimmed
        end

      _ ->
        @default_runner_instance_name
    end
  end

  @spec runner_channel() :: String.t()
  def runner_channel do
    validated_workflow_options()
    |> get_in([:runner, :channel])
    |> resolve_env_value(System.get_env("SYMPHONY_RUNNER_CHANNEL"))
    |> normalize_runner_channel()
  end

  @spec runner_instance_id() :: String.t()
  def runner_instance_id do
    "#{runner_channel()}:#{runner_instance_name()}"
  end

  @spec runner_self_host_project?() :: boolean()
  def runner_self_host_project? do
    case get_in(validated_workflow_options(), [:runner, :self_host_project]) do
      value when is_boolean(value) -> value
      _ -> false
    end
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms)
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec agent_provider() :: String.t()
  def agent_provider do
    get_in(validated_workflow_options(), [:agent, :provider]) || "codex"
  end

  @spec agent_model() :: String.t() | nil
  def agent_model do
    get_in(validated_workflow_options(), [:agent, :model])
  end

  @spec agent_provider_for_stage(String.t() | atom()) :: String.t() | nil
  def agent_provider_for_stage(stage) do
    stage_key =
      case stage do
        s when is_atom(s) -> s
        s when is_binary(s) -> String.to_existing_atom(s)
      end

    get_in(validated_workflow_options(), [:agent, :providers, stage_key])
  rescue
    ArgumentError -> nil
  end

  @spec codex_command() :: String.t()
  def codex_command do
    get_in(validated_workflow_options(), [:agent, :codex, :command])
  end

  @spec codex_runtime_profile() :: codex_runtime_profile_settings()
  def codex_runtime_profile do
    runtime_profile = get_in(validated_workflow_options(), [:agent, :codex, :runtime_profile]) || %{}

    %{
      codex_home:
        runtime_profile
        |> Map.get(:codex_home)
        |> resolve_path_value(nil),
      inherit_env:
        case Map.get(runtime_profile, :inherit_env) do
          value when is_boolean(value) -> value
          _ -> true
        end,
      env_allowlist: Map.get(runtime_profile, :env_allowlist) || []
    }
  end

  @spec reasoning_tier_for_stage(String.t() | atom()) :: reasoning_tier()
  def reasoning_tier_for_stage(stage) when is_binary(stage) do
    reasoning_stages()
    |> Map.get(String.to_existing_atom(stage))
  rescue
    ArgumentError -> @default_reasoning_stages[:implement]
  end

  def reasoning_tier_for_stage(stage) when is_atom(stage) do
    Map.get(reasoning_stages(), stage, @default_reasoning_stages[:implement])
  end

  @spec provider_reasoning_value(String.t() | atom(), String.t() | atom()) :: String.t() | nil
  def provider_reasoning_value(provider, stage) do
    provider_key =
      case provider do
        value when is_atom(value) -> Atom.to_string(value)
        value -> to_string(value)
      end

    tier = reasoning_tier_for_stage(stage)
    mapping = provider_reasoning_map(provider_key)
    Map.get(mapping, tier)
  end

  @spec agent_turn_effort(String.t() | atom()) :: String.t() | nil
  def agent_turn_effort(stage) do
    provider = agent_provider()
    provider_reasoning_value(provider, stage)
  end

  @spec agent_turn_timeout_ms() :: pos_integer()
  def agent_turn_timeout_ms do
    get_in(validated_workflow_options(), [:agent, :turn_timeout_ms])
  end

  @spec codex_approval_policy() :: String.t() | map()
  def codex_approval_policy do
    case resolve_codex_approval_policy() do
      {:ok, approval_policy} -> approval_policy
      {:error, _reason} -> @default_codex_approval_policy
    end
  end

  @spec codex_thread_sandbox() :: String.t()
  def codex_thread_sandbox do
    case resolve_codex_thread_sandbox() do
      {:ok, thread_sandbox} -> thread_sandbox
      {:error, _reason} -> @default_codex_thread_sandbox
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case resolve_codex_turn_sandbox_policy(workspace) do
      {:ok, turn_sandbox_policy} -> turn_sandbox_policy
      {:error, _reason} -> default_codex_turn_sandbox_policy(workspace)
    end
  end

  @spec agent_read_timeout_ms() :: pos_integer()
  def agent_read_timeout_ms do
    get_in(validated_workflow_options(), [:agent, :read_timeout_ms])
  end

  @spec agent_stall_timeout_ms() :: non_neg_integer()
  def agent_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:agent, :stall_timeout_ms])
    |> max(0)
  end

  @spec policy_settings() :: policy_settings()
  def policy_settings do
    get_in(validated_workflow_options(), [:policy])
  end

  @spec policy_require_checkout?() :: boolean()
  def policy_require_checkout? do
    get_in(validated_workflow_options(), [:policy, :require_checkout])
  end

  @spec policy_require_pr_before_review?() :: boolean()
  def policy_require_pr_before_review? do
    get_in(validated_workflow_options(), [:policy, :require_pr_before_review])
  end

  @spec policy_require_validation?() :: boolean()
  def policy_require_validation? do
    get_in(validated_workflow_options(), [:policy, :require_validation])
  end

  @spec policy_require_verifier?() :: boolean()
  def policy_require_verifier? do
    get_in(validated_workflow_options(), [:policy, :require_verifier])
  end

  @spec policy_retry_validation_failures_within_run?() :: boolean()
  def policy_retry_validation_failures_within_run? do
    get_in(validated_workflow_options(), [:policy, :retry_validation_failures_within_run])
  end

  @spec policy_max_validation_attempts_per_run() :: pos_integer()
  def policy_max_validation_attempts_per_run do
    get_in(validated_workflow_options(), [:policy, :max_validation_attempts_per_run])
  end

  @spec policy_publish_required?() :: boolean()
  def policy_publish_required? do
    get_in(validated_workflow_options(), [:policy, :publish_required])
  end

  @spec policy_post_merge_verification_required?() :: boolean()
  def policy_post_merge_verification_required? do
    get_in(validated_workflow_options(), [:policy, :post_merge_verification_required])
  end

  @spec policy_automerge_on_green?() :: boolean()
  def policy_automerge_on_green? do
    get_in(validated_workflow_options(), [:policy, :automerge_on_green])
  end

  @spec policy_default_issue_class() :: String.t()
  def policy_default_issue_class do
    get_in(validated_workflow_options(), [:policy, :default_issue_class]) ||
      @default_policy_default_issue_class
  end

  @spec policy_pack_name() :: String.t()
  def policy_pack_name do
    get_in(validated_workflow_options(), [:company, :policy_pack]) ||
      get_in(validated_workflow_options(), [:company, :mode]) ||
      @default_company_policy_pack
  end

  @spec company_mode() :: String.t()
  def company_mode do
    explicit_mode =
      validated_workflow_options()
      |> get_in([:company, :mode])
      |> empty_string_to_nil()

    case explicit_mode do
      value when is_binary(value) ->
        value

      _ ->
        PolicyPack.resolve(policy_pack_name()).operating_mode || @default_company_mode
    end
  end

  @spec company_name() :: String.t() | nil
  def company_name do
    validated_workflow_options()
    |> get_in([:company, :name])
    |> scalar_string_value()
    |> empty_string_to_nil()
  end

  @spec company_repo_url() :: String.t() | nil
  def company_repo_url do
    validated_workflow_options()
    |> get_in([:company, :repo_url])
    |> scalar_string_value()
    |> empty_string_to_nil()
  end

  @spec company_internal_project_name() :: String.t() | nil
  def company_internal_project_name do
    validated_workflow_options()
    |> get_in([:company, :internal_project_name])
    |> scalar_string_value()
    |> empty_string_to_nil()
  end

  @spec company_internal_project_url() :: String.t() | nil
  def company_internal_project_url do
    validated_workflow_options()
    |> get_in([:company, :internal_project_url])
    |> scalar_string_value()
    |> empty_string_to_nil()
  end

  @spec author_profile_path() :: String.t() | nil
  def author_profile_path do
    validated_workflow_options()
    |> get_in([:company, :author_profile_path])
    |> scalar_string_value()
    |> empty_string_to_nil()
  end

  @spec credential_registry_path() :: String.t() | nil
  def credential_registry_path do
    validated_workflow_options()
    |> get_in([:company, :credential_registry_path])
    |> scalar_string_value()
    |> empty_string_to_nil()
  end

  @spec portfolio_instances() :: [map()]
  def portfolio_instances do
    get_in(validated_workflow_options(), [:portfolio, :instances]) || []
  end

  @spec policy_packs() :: policy_pack_settings()
  def policy_packs do
    get_in(validated_workflow_options(), [:policy_packs]) || %{}
  end

  @spec policy_stop_on_noop_turn?() :: boolean()
  def policy_stop_on_noop_turn? do
    get_in(validated_workflow_options(), [:policy, :stop_on_noop_turn])
  end

  @spec policy_max_noop_turns() :: pos_integer()
  def policy_max_noop_turns do
    get_in(validated_workflow_options(), [:policy, :max_noop_turns])
  end

  @spec policy_token_budget() :: map()
  def policy_token_budget do
    get_in(validated_workflow_options(), [:policy, :token_budget])
  end

  @spec workflow_profiles() :: workflow_profile_settings()
  def workflow_profiles do
    get_in(validated_workflow_options(), [:profiles]) || %{}
  end

  @spec policy_per_turn_input_budget() :: non_neg_integer() | nil
  def policy_per_turn_input_budget do
    get_in(validated_workflow_options(), [:policy, :token_budget, :per_turn_input])
  end

  @spec policy_per_issue_total_budget() :: non_neg_integer() | nil
  def policy_per_issue_total_budget do
    get_in(validated_workflow_options(), [:policy, :token_budget, :per_issue_total])
  end

  @spec policy_per_issue_total_output_budget() :: non_neg_integer() | nil
  def policy_per_issue_total_output_budget do
    get_in(validated_workflow_options(), [:policy, :token_budget, :per_issue_total_output])
  end

  @spec policy_stage_token_budget(String.t() | atom()) :: map()
  def policy_stage_token_budget(stage) when is_binary(stage) do
    validated_workflow_options()
    |> get_in([:policy, :token_budget, :stages, String.to_existing_atom(stage)])
  rescue
    ArgumentError -> %{}
  end

  def policy_stage_token_budget(stage) when is_atom(stage) do
    get_in(validated_workflow_options(), [:policy, :token_budget, :stages, stage]) || %{}
  end

  @spec policy_review_fix_token_budget() :: map()
  def policy_review_fix_token_budget do
    get_in(validated_workflow_options(), [:policy, :token_budget, :review_fix]) || %{}
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :dashboard_enabled])
  end

  @spec observability() :: observability_settings()
  def observability do
    %{
      dashboard_enabled: observability_enabled?(),
      refresh_ms: observability_refresh_ms(),
      render_interval_ms: observability_render_interval_ms(),
      metrics_enabled: observability_metrics_enabled?(),
      metrics_path: observability_metrics_path(),
      tracing_enabled: observability_tracing_enabled?(),
      structured_logs: observability_structured_logs?(),
      debug_artifacts: %{
        enabled: observability_debug_artifacts_enabled?(),
        capture_on_failure: observability_debug_capture_on_failure?(),
        root: observability_debug_artifact_root(),
        max_bytes: observability_debug_artifact_max_bytes(),
        tail_bytes: observability_debug_artifact_tail_bytes()
      }
    }
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec observability_metrics_enabled?() :: boolean()
  def observability_metrics_enabled? do
    get_in(validated_workflow_options(), [:observability, :metrics_enabled])
  end

  @spec observability_metrics_path() :: String.t()
  def observability_metrics_path do
    get_in(validated_workflow_options(), [:observability, :metrics_path])
  end

  @spec observability_tracing_enabled?() :: boolean()
  def observability_tracing_enabled? do
    get_in(validated_workflow_options(), [:observability, :tracing_enabled])
  end

  @spec observability_structured_logs?() :: boolean()
  def observability_structured_logs? do
    get_in(validated_workflow_options(), [:observability, :structured_logs])
  end

  @spec observability_debug_artifacts_enabled?() :: boolean()
  def observability_debug_artifacts_enabled? do
    get_in(validated_workflow_options(), [:observability, :debug_artifacts, :enabled])
  end

  @spec observability_debug_capture_on_failure?() :: boolean()
  def observability_debug_capture_on_failure? do
    get_in(validated_workflow_options(), [:observability, :debug_artifacts, :capture_on_failure])
  end

  @spec observability_debug_artifact_root() :: String.t()
  def observability_debug_artifact_root do
    validated_workflow_options()
    |> get_in([:observability, :debug_artifacts, :root])
    |> resolve_path_value(default_debug_artifact_root())
  end

  @spec observability_debug_artifact_max_bytes() :: pos_integer()
  def observability_debug_artifact_max_bytes do
    get_in(validated_workflow_options(), [:observability, :debug_artifacts, :max_bytes])
  end

  @spec observability_debug_artifact_tail_bytes() :: pos_integer()
  def observability_debug_artifact_tail_bytes do
    get_in(validated_workflow_options(), [:observability, :debug_artifacts, :tail_bytes])
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        get_in(validated_workflow_options(), [:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    get_in(validated_workflow_options(), [:server, :host])
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- require_tracker_kind(),
         :ok <- require_linear_token(),
         :ok <- require_linear_project(),
         :ok <- require_valid_handoff_mode(),
         :ok <- require_valid_policy_defaults(),
         :ok <- require_valid_policy_pack(),
         :ok <- require_valid_codex_runtime_settings(),
         :ok <- require_valid_runner_harness() do
      :ok
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) :: {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, approval_policy} <- resolve_codex_approval_policy(),
         {:ok, thread_sandbox} <- resolve_codex_thread_sandbox(),
         {:ok, turn_sandbox_policy} <- resolve_codex_turn_sandbox_policy(workspace) do
      {:ok,
       %{
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp require_tracker_kind do
    case tracker_kind() do
      "linear" -> :ok
      "memory" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_linear_token do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_api_token()) do
          :ok
        else
          {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_project do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_project_slug()) do
          :ok
        else
          {:error, :missing_linear_project_slug}
        end

      _ ->
        :ok
    end
  end

  defp require_valid_codex_runtime_settings do
    case codex_runtime_settings() do
      {:ok, _settings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_valid_runner_harness do
    case RepoHarness.validate_runner_checkout(runner_self_host_project?(), RunnerRuntime.current_checkout_root()) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_valid_policy_defaults do
    if IssuePolicy.normalize_class(policy_default_issue_class()) do
      :ok
    else
      {:error, {:invalid_policy_default_issue_class, policy_default_issue_class()}}
    end
  end

  defp require_valid_policy_pack do
    case PolicyPack.normalize_name(policy_pack_name()) do
      nil ->
        {:error, {:invalid_policy_pack, policy_pack_name()}}

      _ ->
        pack = PolicyPack.resolve(policy_pack_name())

        cond do
          pack.default_issue_class not in pack.allowed_policy_classes ->
            {:error, {:invalid_policy_pack_default_issue_class, policy_pack_name(), pack.default_issue_class}}

          Enum.empty?(pack.allowed_policy_classes) ->
            {:error, {:invalid_policy_pack_allowed_policy_classes, policy_pack_name()}}

          invalid_issue_labels?(pack.required_any_issue_labels) ->
            {:error, {:invalid_policy_pack_required_issue_labels, policy_pack_name()}}

          invalid_issue_labels?(pack.forbidden_issue_labels) ->
            {:error, {:invalid_policy_pack_forbidden_issue_labels, policy_pack_name()}}

          true ->
            :ok
        end
    end
  end

  defp require_valid_handoff_mode do
    case tracker_handoff_mode() do
      "assignee" -> :ok
      "labels" -> :ok
      "hybrid" -> :ok
      other -> {:error, {:invalid_tracker_handoff_mode, other}}
    end
  end

  defp validated_workflow_options do
    workflow_config()
    |> extract_workflow_options()
    |> NimbleOptions.validate!(@workflow_options_schema)
  end

  defp extract_workflow_options(config) do
    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      manual: extract_manual_options(section_map(config, "manual")),
      runner: extract_runner_options(section_map(config, "runner")),
      agent: extract_merged_agent_options(config),
      policy: extract_policy_options(section_map(config, "policy")),
      profiles: extract_profiles_options(section_map(config, "profiles")),
      company: extract_company_options(section_map(config, "company")),
      policy_packs: extract_policy_packs_options(section_map(config, "policy_packs")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability")),
      portfolio: extract_portfolio_options(section_map(config, "portfolio")),
      server: extract_server_options(section_map(config, "server"))
    }
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(:kind, normalize_tracker_kind(scalar_string_value(Map.get(section, "kind"))))
    |> put_if_present(:endpoint, scalar_string_value(Map.get(section, "endpoint")))
    |> put_if_present(:api_key, binary_value(Map.get(section, "api_key"), allow_empty: true))
    |> put_if_present(:webhook_secret, binary_value(Map.get(section, "webhook_secret"), allow_empty: true))
    |> put_if_present(:project_slug, scalar_string_value(Map.get(section, "project_slug")))
    |> put_if_present(:assignee, scalar_string_value(Map.get(section, "assignee")))
    |> put_if_present(:handoff_mode, scalar_string_value(Map.get(section, "handoff_mode")))
    |> put_if_present(:required_labels, csv_value(Map.get(section, "required_labels")))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
  end

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
    |> put_if_present(
      :discovery_interval_ms,
      integer_value(Map.get(section, "discovery_interval_ms"))
    )
    |> put_if_present(:healing_interval_ms, integer_value(Map.get(section, "healing_interval_ms")))
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_profiles_options(section) when is_map(section) do
    section
    |> Enum.map(fn {name, profile} ->
      {normalize_profile_name(name), extract_profile_options(profile)}
    end)
    |> Enum.reject(fn {name, _profile} -> is_nil(name) end)
    |> Map.new()
  end

  defp extract_profiles_options(_section), do: %{}

  defp extract_company_options(section) when is_map(section) do
    %{}
    |> put_if_present(:name, scalar_string_value(Map.get(section, "name")))
    |> put_if_present(:repo_url, scalar_string_value(Map.get(section, "repo_url")))
    |> put_if_present(
      :internal_project_name,
      scalar_string_value(Map.get(section, "internal_project_name"))
    )
    |> put_if_present(
      :internal_project_url,
      scalar_string_value(Map.get(section, "internal_project_url"))
    )
    |> put_if_present(:mode, scalar_string_value(Map.get(section, "mode")))
    |> put_if_present(:policy_pack, scalar_string_value(Map.get(section, "policy_pack")))
    |> put_if_present(:author_profile_path, scalar_string_value(Map.get(section, "author_profile_path")))
    |> put_if_present(
      :credential_registry_path,
      scalar_string_value(Map.get(section, "credential_registry_path"))
    )
  end

  defp extract_company_options(_section), do: %{}

  defp extract_portfolio_options(section) when is_map(section) do
    %{}
    |> put_if_present(:instances, extract_portfolio_instances(Map.get(section, "instances")))
  end

  defp extract_portfolio_options(_section), do: %{}

  defp extract_portfolio_instances(instances) when is_list(instances) do
    instances
    |> Enum.map(fn
      %{} = entry ->
        %{}
        |> put_if_present(:name, scalar_string_value(Map.get(entry, "name")))
        |> put_if_present(:url, scalar_string_value(Map.get(entry, "url")))

      _ ->
        %{}
    end)
    |> Enum.reject(&(map_size(&1) == 0))
  end

  defp extract_portfolio_instances(_instances), do: []

  defp extract_policy_packs_options(section) when is_map(section) do
    section
    |> Enum.reduce(%{}, fn {pack_name, value}, acc ->
      key =
        pack_name
        |> scalar_string_value()
        |> PolicyPack.normalize_name()

      entry =
        %{}
        |> put_if_present(:description, scalar_string_value(Map.get(value, "description")))
        |> put_if_present(:operating_mode, scalar_string_value(Map.get(value, "operating_mode")))
        |> put_if_present(:default_issue_class, scalar_string_value(Map.get(value, "default_issue_class")))
        |> put_if_present(:allowed_policy_classes, csv_value(Map.get(value, "allowed_policy_classes")))
        |> put_if_present(:required_any_issue_labels, csv_value(Map.get(value, "required_any_issue_labels")))
        |> put_if_present(:forbidden_issue_labels, csv_value(Map.get(value, "forbidden_issue_labels")))
        |> put_if_present(
          :tracker_mutation_mode,
          scalar_string_value(Map.get(value, "tracker_mutation_mode"))
        )
        |> put_if_present(:pr_posting_mode, scalar_string_value(Map.get(value, "pr_posting_mode")))
        |> put_if_present(
          :thread_resolution_mode,
          scalar_string_value(Map.get(value, "thread_resolution_mode"))
        )
        |> put_if_present(
          :external_comment_mode,
          scalar_string_value(Map.get(value, "external_comment_mode"))
        )
        |> put_if_present(:draft_first_required, scalar_boolean_value(Map.get(value, "draft_first_required")))
        |> put_if_present(
          :confidence_language,
          scalar_string_value(Map.get(value, "confidence_language"))
        )
        |> put_if_present(
          :allowed_external_channels,
          csv_value(Map.get(value, "allowed_external_channels"))
        )
        |> put_if_present(:preview_deploy_allowed, scalar_boolean_value(Map.get(value, "preview_deploy_allowed")))
        |> put_if_present(
          :production_deploy_allowed,
          scalar_boolean_value(Map.get(value, "production_deploy_allowed"))
        )
        |> put_if_present(
          :max_concurrent_runs_per_company,
          scalar_integer_value(Map.get(value, "max_concurrent_runs_per_company"))
        )
        |> put_if_present(
          :max_merges_per_day_per_repo,
          scalar_integer_value(Map.get(value, "max_merges_per_day_per_repo"))
        )
        |> put_if_present(:repo_frozen, scalar_boolean_value(Map.get(value, "repo_frozen")))
        |> put_if_present(:company_frozen, scalar_boolean_value(Map.get(value, "company_frozen")))
        |> put_if_present(:approval_gate_state, scalar_string_value(Map.get(value, "approval_gate_state")))
        |> put_if_present(:preview_deploy_mode, scalar_string_value(Map.get(value, "preview_deploy_mode")))
        |> put_if_present(:production_deploy_mode, scalar_string_value(Map.get(value, "production_deploy_mode")))
        |> put_if_present(:deploy_approval_gate_state, scalar_string_value(Map.get(value, "deploy_approval_gate_state")))
        |> put_if_present(:merge_window, extract_merge_window_options(Map.get(value, "merge_window")))
        |> put_if_present(
          :production_deploy_window,
          extract_merge_window_options(Map.get(value, "production_deploy_window"))
        )

      if is_nil(key) or map_size(entry) == 0 do
        acc
      else
        Map.put(acc, key, entry)
      end
    end)
  end

  defp extract_policy_packs_options(_section), do: %{}

  defp extract_merge_window_options(section) when is_map(section) do
    %{}
    |> put_if_present(:timezone, scalar_string_value(Map.get(section, "timezone")))
    |> put_if_present(:days, csv_value(Map.get(section, "days")))
    |> put_if_present(:start_hour, integer_value(Map.get(section, "start_hour")))
    |> put_if_present(:end_hour, integer_value(Map.get(section, "end_hour")))
  end

  defp extract_merge_window_options(_section), do: nil

  defp invalid_issue_labels?(labels) when is_list(labels) do
    Enum.any?(labels, fn
      label when is_binary(label) -> String.trim(label) == ""
      _ -> true
    end)
  end

  defp invalid_issue_labels?(_labels), do: false

  defp extract_profile_options(section) when is_map(section) do
    %{}
    |> put_if_present(:merge_mode, scalar_string_value(Map.get(section, "merge_mode")))
    |> put_if_present(
      :approval_gate_state,
      scalar_string_value(Map.get(section, "approval_gate_state"))
    )
    |> put_if_present(
      :deploy_approval_gate_state,
      scalar_string_value(Map.get(section, "deploy_approval_gate_state"))
    )
    |> put_if_present(
      :post_merge_verification_required,
      boolean_value(Map.get(section, "post_merge_verification_required"))
    )
    |> put_if_present(:preview_deploy_mode, scalar_string_value(Map.get(section, "preview_deploy_mode")))
    |> put_if_present(:production_deploy_mode, scalar_string_value(Map.get(section, "production_deploy_mode")))
    |> put_if_present(
      :post_deploy_verification_required,
      boolean_value(Map.get(section, "post_deploy_verification_required"))
    )
    |> put_if_present(:max_turns_override, integer_value(Map.get(section, "max_turns_override")))
  end

  defp extract_profile_options(_section), do: %{}

  defp normalize_profile_name(name) when is_binary(name) do
    case name |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      "fully_autonomous" -> :fully_autonomous
      "review_required" -> :review_required
      "never_automerge" -> :never_automerge
      _ -> nil
    end
  end

  defp normalize_profile_name(name) when is_atom(name), do: normalize_profile_name(Atom.to_string(name))
  defp normalize_profile_name(_name), do: nil

  defp extract_manual_options(section) do
    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
    |> put_if_present(:store_root, binary_value(Map.get(section, "store_root")))
  end

  defp extract_runner_options(section) do
    %{}
    |> put_if_present(:install_root, binary_value(Map.get(section, "install_root")))
    |> put_if_present(:instance_name, scalar_string_value(Map.get(section, "instance_name")))
    |> put_if_present(:channel, scalar_string_value(Map.get(section, "channel")))
    |> put_if_present(:self_host_project, boolean_value(Map.get(section, "self_host_project")))
  end

  defp normalize_runner_channel(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "canary" -> "canary"
      "experimental" -> "experimental"
      "stable" -> "stable"
      _ -> @default_runner_channel
    end
  end

  defp normalize_runner_channel(_value), do: @default_runner_channel

  defp default_manual_store_root do
    case Application.get_env(:symphony_elixir, :log_file) do
      value when is_binary(value) ->
        value
        |> Path.expand()
        |> Path.dirname()
        |> Path.dirname()
        |> Path.join("manual_issues")

      _ ->
        Path.join(File.cwd!(), "manual_issues")
    end
  end

  defp default_debug_artifact_root do
    case Application.get_env(:symphony_elixir, :log_file) do
      value when is_binary(value) ->
        value
        |> Path.expand()
        |> Path.dirname()
        |> Path.join("artifacts")

      _ ->
        Path.join(File.cwd!(), Path.join("log", "artifacts"))
    end
  end

  defp extract_merged_agent_options(config) do
    agent_section = section_map(config, "agent")
    legacy_codex_section = section_map(config, "codex")

    # Orchestrator-level from agent: section
    base =
      %{}
      |> put_if_present(:max_concurrent_agents, integer_value(Map.get(agent_section, "max_concurrent_agents")))
      |> put_if_present(:max_turns, positive_integer_value(Map.get(agent_section, "max_turns")))
      |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(agent_section, "max_retry_backoff_ms")))
      |> put_if_present(
        :max_concurrent_agents_by_state,
        state_limits_value(Map.get(agent_section, "max_concurrent_agents_by_state"))
      )

    # Generic runtime settings: prefer agent: section, fall back to legacy codex: section
    runtime_source = if Map.has_key?(agent_section, "turn_timeout_ms"), do: agent_section, else: legacy_codex_section

    generic =
      base
      |> put_if_present(:provider, binary_value(Map.get(agent_section, "provider") || Map.get(legacy_codex_section, "provider")))
      |> put_if_present(:model, binary_value(Map.get(agent_section, "model") || Map.get(legacy_codex_section, "model")))
      |> put_if_present(:providers, map_value(Map.get(agent_section, "providers") || Map.get(legacy_codex_section, "providers")))
      |> put_if_present(:reasoning, reasoning_settings_value(Map.get(agent_section, "reasoning") || Map.get(legacy_codex_section, "reasoning")))
      |> put_if_present(:turn_timeout_ms, integer_value(Map.get(runtime_source, "turn_timeout_ms")))
      |> put_if_present(:read_timeout_ms, integer_value(Map.get(runtime_source, "read_timeout_ms")))
      |> put_if_present(:stall_timeout_ms, integer_value(Map.get(runtime_source, "stall_timeout_ms")))

    # Codex-specific: prefer agent.codex nested section, fall back to legacy codex: top-level
    codex_nested = section_map(agent_section, "codex")
    codex_source = if codex_nested != %{}, do: codex_nested, else: legacy_codex_section

    codex_opts = extract_codex_provider_options(codex_source)

    if codex_opts == %{} do
      generic
    else
      Map.put(generic, :codex, codex_opts)
    end
  end

  defp extract_codex_provider_options(section) do
    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:runtime_profile, runtime_profile_value(Map.get(section, "runtime_profile")))
  end

  defp runtime_profile_value(section) when is_map(section) do
    %{}
    |> put_if_present(:codex_home, binary_value(Map.get(section, "codex_home")))
    |> put_if_present(:inherit_env, boolean_value(Map.get(section, "inherit_env")))
    |> put_if_present(:env_allowlist, csv_value(Map.get(section, "env_allowlist")))
  end

  defp runtime_profile_value(_value), do: :omit

  defp reasoning_settings_value(section) when is_map(section) do
    %{}
    |> put_if_present(:stages, reasoning_stage_overrides_value(Map.get(section, "stages")))
    |> put_if_present(:providers, reasoning_provider_overrides_value(Map.get(section, "providers")))
  end

  defp reasoning_settings_value(_value), do: :omit

  defp reasoning_stage_overrides_value(section) when is_map(section) do
    %{}
    |> put_if_present(:implement, scalar_string_value(Map.get(section, "implement")))
    |> put_if_present(:verify, scalar_string_value(Map.get(section, "verify")))
    |> put_if_present(:verifier, scalar_string_value(Map.get(section, "verifier")))
  end

  defp reasoning_stage_overrides_value(_value), do: :omit

  defp reasoning_provider_overrides_value(section) when is_map(section) do
    section
    |> Enum.reduce(%{}, fn {provider, value}, acc ->
      case reasoning_provider_override_value(value) do
        :omit -> acc
        normalized -> Map.put(acc, to_string(provider), normalized)
      end
    end)
    |> empty_map_to_omit()
  end

  defp reasoning_provider_overrides_value(_value), do: :omit

  defp reasoning_provider_override_value(section) when is_map(section) do
    %{}
    |> put_if_present(:reasoning_map, reasoning_map_value(Map.get(section, "reasoning_map")))
  end

  defp reasoning_provider_override_value(_value), do: :omit

  defp reasoning_map_value(section) when is_map(section) do
    section
    |> Enum.reduce(%{}, fn {tier, value}, acc ->
      case scalar_string_value(value) do
        :omit -> acc
        normalized -> Map.put(acc, to_string(tier), normalized)
      end
    end)
    |> empty_map_to_omit()
  end

  defp reasoning_map_value(_value), do: :omit

  defp extract_policy_options(section) do
    %{}
    |> put_if_present(:require_checkout, boolean_value(Map.get(section, "require_checkout")))
    |> put_if_present(
      :require_pr_before_review,
      boolean_value(Map.get(section, "require_pr_before_review"))
    )
    |> put_if_present(:require_validation, boolean_value(Map.get(section, "require_validation")))
    |> put_if_present(:require_verifier, boolean_value(Map.get(section, "require_verifier")))
    |> put_if_present(
      :retry_validation_failures_within_run,
      boolean_value(Map.get(section, "retry_validation_failures_within_run"))
    )
    |> put_if_present(
      :max_validation_attempts_per_run,
      positive_integer_value(Map.get(section, "max_validation_attempts_per_run"))
    )
    |> put_if_present(:publish_required, boolean_value(Map.get(section, "publish_required")))
    |> put_if_present(
      :post_merge_verification_required,
      boolean_value(Map.get(section, "post_merge_verification_required"))
    )
    |> put_if_present(:automerge_on_green, boolean_value(Map.get(section, "automerge_on_green")))
    |> put_if_present(:default_issue_class, scalar_string_value(Map.get(section, "default_issue_class")))
    |> put_if_present(:stop_on_noop_turn, boolean_value(Map.get(section, "stop_on_noop_turn")))
    |> put_if_present(:max_noop_turns, positive_integer_value(Map.get(section, "max_noop_turns")))
    |> put_if_present(:token_budget, policy_token_budget_value(Map.get(section, "token_budget")))
  end

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
    |> put_if_present(:metrics_enabled, boolean_value(Map.get(section, "metrics_enabled")))
    |> put_if_present(:metrics_path, scalar_string_value(Map.get(section, "metrics_path")))
    |> put_if_present(:tracing_enabled, boolean_value(Map.get(section, "tracing_enabled")))
    |> put_if_present(:structured_logs, boolean_value(Map.get(section, "structured_logs")))
    |> put_if_present(:debug_artifacts, extract_debug_artifact_options(Map.get(section, "debug_artifacts")))
  end

  defp extract_server_options(section) do
    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp extract_debug_artifact_options(section) when is_map(section) do
    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
    |> put_if_present(:capture_on_failure, boolean_value(Map.get(section, "capture_on_failure")))
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
    |> put_if_present(:max_bytes, positive_integer_value(Map.get(section, "max_bytes")))
    |> put_if_present(:tail_bytes, positive_integer_value(Map.get(section, "tail_bytes")))
  end

  defp extract_debug_artifact_options(_section), do: %{}

  defp policy_token_budget_value(section) when is_map(section) do
    %{}
    |> put_if_present(:per_turn_input, non_negative_integer_value(Map.get(section, "per_turn_input")))
    |> put_if_present(:per_issue_total, non_negative_integer_value(Map.get(section, "per_issue_total")))
    |> put_if_present(
      :per_issue_total_output,
      non_negative_integer_value(Map.get(section, "per_issue_total_output"))
    )
    |> put_if_present(:stages, policy_stage_token_budget_stages_value(Map.get(section, "stages")))
    |> put_if_present(:review_fix, policy_review_fix_token_budget_value(Map.get(section, "review_fix")))
  end

  defp policy_token_budget_value(_value), do: :omit

  defp policy_stage_token_budget_stages_value(section) when is_map(section) do
    %{}
    |> put_if_present(:implement, policy_stage_token_budget_stage_value(Map.get(section, "implement")))
    |> put_if_present(:verify, policy_stage_token_budget_stage_value(Map.get(section, "verify")))
  end

  defp policy_stage_token_budget_stages_value(_value), do: :omit

  defp policy_stage_token_budget_stage_value(section) when is_map(section) do
    %{}
    |> put_if_present(
      :per_turn_input_soft,
      non_negative_integer_value(Map.get(section, "per_turn_input_soft"))
    )
    |> put_if_present(
      :per_turn_input_hard,
      non_negative_integer_value(Map.get(section, "per_turn_input_hard"))
    )
  end

  defp policy_stage_token_budget_stage_value(_value), do: :omit

  defp policy_review_fix_token_budget_value(section) when is_map(section) do
    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
    |> put_if_present(
      :per_turn_input_soft,
      non_negative_integer_value(Map.get(section, "per_turn_input_soft"))
    )
    |> put_if_present(
      :per_turn_input_hard,
      non_negative_integer_value(Map.get(section, "per_turn_input_hard"))
    )
    |> put_if_present(
      :retry_2_per_turn_input_hard,
      non_negative_integer_value(Map.get(section, "retry_2_per_turn_input_hard"))
    )
    |> put_if_present(
      :retry_3_per_turn_input_hard,
      non_negative_integer_value(Map.get(section, "retry_3_per_turn_input_hard"))
    )
    |> put_if_present(
      :max_turns_in_window,
      non_negative_integer_value(Map.get(section, "max_turns_in_window"))
    )
    |> put_if_present(
      :retry_2_max_turns_in_window,
      non_negative_integer_value(Map.get(section, "retry_2_max_turns_in_window"))
    )
    |> put_if_present(
      :retry_3_max_turns_in_window,
      non_negative_integer_value(Map.get(section, "retry_3_max_turns_in_window"))
    )
    |> put_if_present(
      :per_issue_total_extension,
      non_negative_integer_value(Map.get(section, "per_issue_total_extension"))
    )
    |> put_if_present(
      :auto_retry_limit,
      non_negative_integer_value(Map.get(section, "auto_retry_limit"))
    )
    |> put_if_present(
      :narrow_scope_batch_size,
      positive_integer_value(Map.get(section, "narrow_scope_batch_size"))
    )
  end

  defp policy_review_fix_token_budget_value(_value), do: :omit

  defp reasoning_stages do
    overrides = get_in(validated_workflow_options(), [:agent, :reasoning, :stages]) || %{}

    @default_reasoning_stages
    |> Map.merge(overrides)
  end

  defp provider_reasoning_map(provider_key) do
    default_mapping = Map.get(@default_provider_reasoning_maps, provider_key, %{})

    overrides =
      validated_workflow_options()
      |> get_in([:agent, :reasoning, :providers, provider_key, :reasoning_map])
      |> case do
        value when is_map(value) -> value
        _ -> %{}
      end

    Map.merge(default_mapping, overrides)
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp empty_map_to_omit(%{} = map) when map_size(map) == 0, do: :omit
  defp empty_map_to_omit(map), do: map

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp scalar_boolean_value(value) when value in [true, false], do: value

  defp scalar_boolean_value(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp scalar_boolean_value(_value), do: :omit

  defp scalar_integer_value(value) when is_integer(value), do: value

  defp scalar_integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> :omit
    end
  end

  defp scalar_integer_value(_value), do: :omit

  defp empty_string_to_nil(""), do: nil
  defp empty_string_to_nil(:omit), do: nil
  defp empty_string_to_nil(value), do: value

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp map_value(value) when is_map(value) and map_size(value) > 0, do: value
  defp map_value(_value), do: :omit

  defp command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp command_value(_value), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp non_negative_integer_value(value) do
    case parse_non_negative_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp fetch_value(paths, default) do
    config = workflow_config()

    case resolve_config_value(config, paths) do
      :missing -> default
      value -> value
    end
  end

  defp resolve_codex_approval_policy do
    case fetch_value([["agent", "codex", "approval_policy"], ["codex", "approval_policy"]], :missing) do
      :missing ->
        {:ok, @default_codex_approval_policy}

      nil ->
        {:ok, @default_codex_approval_policy}

      value when is_binary(value) ->
        approval_policy = String.trim(value)

        if approval_policy == "" do
          {:error, {:invalid_codex_approval_policy, value}}
        else
          {:ok, approval_policy}
        end

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_approval_policy, value}}
    end
  end

  defp resolve_codex_thread_sandbox do
    case fetch_value([["agent", "codex", "thread_sandbox"], ["codex", "thread_sandbox"]], :missing) do
      :missing ->
        {:ok, @default_codex_thread_sandbox}

      nil ->
        {:ok, @default_codex_thread_sandbox}

      value when is_binary(value) ->
        thread_sandbox = String.trim(value)

        if thread_sandbox == "" do
          {:error, {:invalid_codex_thread_sandbox, value}}
        else
          {:ok, thread_sandbox}
        end

      value ->
        {:error, {:invalid_codex_thread_sandbox, value}}
    end
  end

  defp resolve_codex_turn_sandbox_policy(workspace) do
    case fetch_value([["agent", "codex", "turn_sandbox_policy"], ["codex", "turn_sandbox_policy"]], :missing) do
      :missing ->
        {:ok, default_codex_turn_sandbox_policy(workspace)}

      nil ->
        {:ok, default_codex_turn_sandbox_policy(workspace)}

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_turn_sandbox_policy, {:unsupported_value, value}}}
    end
  end

  defp default_codex_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and String.trim(workspace) != "" do
        Path.expand(workspace)
      else
        Path.expand(workspace_root())
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp normalize_handoff_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "" -> @default_linear_handoff_mode
      normalized -> normalized
    end
  end

  defp normalize_handoff_mode(_mode), do: @default_linear_handoff_mode

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp resolve_config_value(%{} = config, paths) do
    Enum.reduce_while(paths, :missing, fn path, _acc ->
      case get_in_path(config, path) do
        :missing -> {:cont, :missing}
        value -> {:halt, value}
      end
    end)
  end

  defp get_in_path(config, path) when is_list(path) and is_map(config) do
    get_in_path(config, path, 0)
  end

  defp get_in_path(_, _), do: :missing

  defp get_in_path(config, [], _depth), do: config

  defp get_in_path(%{} = current, [segment | rest], _depth) do
    case Map.fetch(current, normalize_key(segment)) do
      {:ok, value} -> get_in_path(value, rest, 0)
      :error -> :missing
    end
  end

  defp get_in_path(_, _, _depth), do: :missing

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
