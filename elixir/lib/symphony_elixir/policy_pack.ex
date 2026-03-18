defmodule SymphonyElixir.PolicyPack do
  @moduledoc """
  Company/repo policy packs that shape default autonomy for a workflow.

  Packs are runtime-owned. They define the default issue class and the set of
  allowed policy classes for a given repo/company operating mode.
  """

  alias SymphonyElixir.{Config, IssuePolicy}

  defstruct [
    :name,
    :description,
    :operating_mode,
    :default_issue_class,
    :allowed_policy_classes,
    :required_any_issue_labels,
    :forbidden_issue_labels,
    :tracker_mutation_mode,
    :pr_posting_mode,
    :thread_resolution_mode,
    :external_comment_mode,
    :draft_first_required,
    :confidence_language,
    :allowed_external_channels,
    :preview_deploy_allowed,
    :production_deploy_allowed,
    :max_concurrent_runs_per_company,
    :max_merges_per_day_per_repo,
    :repo_frozen,
    :company_frozen,
    :approval_gate_state,
    :preview_deploy_mode,
    :production_deploy_mode,
    :deploy_approval_gate_state,
    :merge_window,
    :production_deploy_window
  ]

  @type name :: :private_autopilot | :client_safe_shadow | :client_safe_pr_active

  @type t :: %__MODULE__{
          name: name() | atom(),
          description: String.t(),
          operating_mode: String.t(),
          default_issue_class: String.t(),
          allowed_policy_classes: [String.t()],
          required_any_issue_labels: [String.t()],
          forbidden_issue_labels: [String.t()],
          tracker_mutation_mode: String.t(),
          pr_posting_mode: String.t(),
          thread_resolution_mode: String.t(),
          external_comment_mode: String.t(),
          draft_first_required: boolean(),
          confidence_language: String.t(),
          allowed_external_channels: [String.t()],
          preview_deploy_allowed: boolean(),
          production_deploy_allowed: boolean(),
          max_concurrent_runs_per_company: pos_integer() | nil,
          max_merges_per_day_per_repo: pos_integer() | nil,
          repo_frozen: boolean(),
          company_frozen: boolean(),
          approval_gate_state: String.t(),
          preview_deploy_mode: :disabled | :after_merge,
          production_deploy_mode: :disabled | :after_preview,
          deploy_approval_gate_state: String.t(),
          merge_window: map() | nil,
          production_deploy_window: map() | nil
        }

  @default_packs %{
    private_autopilot: %{
      description: "Autonomous-first mode for your own repos and experiments.",
      operating_mode: "private_autopilot",
      default_issue_class: "fully_autonomous",
      tracker_mutation_mode: "allowed",
      pr_posting_mode: "allowed",
      thread_resolution_mode: "allowed",
      external_comment_mode: "allowed",
      draft_first_required: true,
      confidence_language: "measured",
      allowed_external_channels: ["pull_request", "tracker"],
      preview_deploy_allowed: true,
      production_deploy_allowed: true,
      max_concurrent_runs_per_company: nil,
      max_merges_per_day_per_repo: nil,
      repo_frozen: false,
      company_frozen: false,
      approval_gate_state: "Human Review",
      preview_deploy_mode: :disabled,
      production_deploy_mode: :disabled,
      deploy_approval_gate_state: "Deploy Approval",
      allowed_policy_classes: [
        "fully_autonomous",
        "review_required",
        "never_automerge"
      ],
      required_any_issue_labels: [],
      forbidden_issue_labels: [],
      production_deploy_window: nil
    },
    client_safe_shadow: %{
      description: "Conservative mode for client repos with review-gated defaults.",
      operating_mode: "client_safe_shadow",
      default_issue_class: "review_required",
      tracker_mutation_mode: "forbidden",
      pr_posting_mode: "forbidden",
      thread_resolution_mode: "forbidden",
      external_comment_mode: "draft_only",
      draft_first_required: true,
      confidence_language: "measured",
      allowed_external_channels: ["pull_request"],
      preview_deploy_allowed: false,
      production_deploy_allowed: false,
      max_concurrent_runs_per_company: 2,
      max_merges_per_day_per_repo: 5,
      repo_frozen: false,
      company_frozen: false,
      approval_gate_state: "Client Approval",
      preview_deploy_mode: :disabled,
      production_deploy_mode: :disabled,
      deploy_approval_gate_state: "Deploy Approval",
      allowed_policy_classes: [
        "review_required",
        "never_automerge"
      ],
      required_any_issue_labels: [],
      forbidden_issue_labels: [],
      production_deploy_window: nil
    },
    client_safe_pr_active: %{
      description: "Client-safe mode that may open/update PRs while keeping tracker mutations disabled.",
      operating_mode: "client_safe_pr_active",
      default_issue_class: "review_required",
      tracker_mutation_mode: "forbidden",
      pr_posting_mode: "allowed",
      thread_resolution_mode: "forbidden",
      external_comment_mode: "draft_only",
      draft_first_required: true,
      confidence_language: "measured",
      allowed_external_channels: ["pull_request"],
      preview_deploy_allowed: false,
      production_deploy_allowed: false,
      max_concurrent_runs_per_company: 2,
      max_merges_per_day_per_repo: 5,
      repo_frozen: false,
      company_frozen: false,
      approval_gate_state: "Client Approval",
      preview_deploy_mode: :disabled,
      production_deploy_mode: :disabled,
      deploy_approval_gate_state: "Deploy Approval",
      allowed_policy_classes: [
        "review_required",
        "never_automerge"
      ],
      required_any_issue_labels: [],
      forbidden_issue_labels: [],
      production_deploy_window: nil
    }
  }

  @spec default_packs() :: map()
  def default_packs, do: @default_packs

  @spec contractor_mode?(t() | String.t() | atom() | nil) :: boolean()
  def contractor_mode?(pack_or_name) do
    pack = resolve(pack_or_name)
    pack.operating_mode in ["client_safe_shadow", "client_safe_pr_active"]
  end

  @spec resolve() :: t()
  def resolve, do: resolve(Config.policy_pack_name())

  @spec resolve(String.t() | atom() | nil) :: t()
  def resolve(%__MODULE__{} = pack) do
    %__MODULE__{
      name: normalize_name(pack.name) || :private_autopilot,
      description: normalize_description(pack.description),
      operating_mode:
        normalize_operating_mode(
          pack.operating_mode,
          default_operating_mode(normalize_name(pack.name) || :private_autopilot)
        ),
      default_issue_class:
        pack.default_issue_class
        |> normalize_issue_class(default_default_issue_class(normalize_name(pack.name) || :private_autopilot)),
      approval_gate_state:
        pack.approval_gate_state
        |> normalize_approval_gate_state(default_approval_gate_state(normalize_name(pack.name) || :private_autopilot)),
      preview_deploy_mode:
        pack.preview_deploy_mode
        |> normalize_preview_deploy_mode(default_preview_deploy_mode(normalize_name(pack.name) || :private_autopilot)),
      production_deploy_mode:
        pack.production_deploy_mode
        |> normalize_production_deploy_mode(default_production_deploy_mode(normalize_name(pack.name) || :private_autopilot)),
      deploy_approval_gate_state:
        pack.deploy_approval_gate_state
        |> normalize_approval_gate_state(default_deploy_approval_gate_state(normalize_name(pack.name) || :private_autopilot)),
      allowed_policy_classes:
        normalize_allowed_policy_classes(
          pack.allowed_policy_classes,
          default_allowed_policy_classes(normalize_name(pack.name) || :private_autopilot)
        ),
      required_any_issue_labels: normalize_issue_labels(pack.required_any_issue_labels),
      forbidden_issue_labels: normalize_issue_labels(pack.forbidden_issue_labels),
      tracker_mutation_mode:
        normalize_permission_mode(
          pack.tracker_mutation_mode,
          default_tracker_mutation_mode(normalize_name(pack.name) || :private_autopilot)
        ),
      pr_posting_mode:
        normalize_permission_mode(
          pack.pr_posting_mode,
          default_pr_posting_mode(normalize_name(pack.name) || :private_autopilot)
        ),
      thread_resolution_mode:
        normalize_permission_mode(
          pack.thread_resolution_mode,
          default_thread_resolution_mode(normalize_name(pack.name) || :private_autopilot)
        ),
      external_comment_mode:
        normalize_permission_mode(
          pack.external_comment_mode,
          default_external_comment_mode(normalize_name(pack.name) || :private_autopilot)
        ),
      draft_first_required: normalize_boolean(pack.draft_first_required, default_draft_first_required(normalize_name(pack.name) || :private_autopilot)),
      confidence_language:
        normalize_string_setting(
          pack.confidence_language,
          default_confidence_language(normalize_name(pack.name) || :private_autopilot)
        ),
      allowed_external_channels: normalize_issue_labels(pack.allowed_external_channels),
      preview_deploy_allowed: normalize_boolean(pack.preview_deploy_allowed, default_preview_deploy_allowed(normalize_name(pack.name) || :private_autopilot)),
      production_deploy_allowed: normalize_boolean(pack.production_deploy_allowed, default_production_deploy_allowed(normalize_name(pack.name) || :private_autopilot)),
      max_concurrent_runs_per_company: normalize_optional_positive_integer(pack.max_concurrent_runs_per_company),
      max_merges_per_day_per_repo: normalize_optional_positive_integer(pack.max_merges_per_day_per_repo),
      repo_frozen: normalize_boolean(pack.repo_frozen, false),
      company_frozen: normalize_boolean(pack.company_frozen, false),
      merge_window: normalize_merge_window(pack.merge_window),
      production_deploy_window: normalize_merge_window(pack.production_deploy_window)
    }
  end

  def resolve(%{} = value) do
    key = normalize_name(Map.get(value, :name) || Map.get(value, "name")) || :private_autopilot

    pack =
      @default_packs
      |> Map.get(key, %{})
      |> Map.merge(%{
        description: map_value(value, :description),
        operating_mode: map_value(value, :operating_mode),
        default_issue_class: map_value(value, :default_issue_class),
        tracker_mutation_mode: map_value(value, :tracker_mutation_mode),
        pr_posting_mode: map_value(value, :pr_posting_mode),
        thread_resolution_mode: map_value(value, :thread_resolution_mode),
        external_comment_mode: map_value(value, :external_comment_mode),
        preview_deploy_allowed: map_value(value, :preview_deploy_allowed),
        production_deploy_allowed: map_value(value, :production_deploy_allowed),
        max_concurrent_runs_per_company: map_value(value, :max_concurrent_runs_per_company),
        max_merges_per_day_per_repo: map_value(value, :max_merges_per_day_per_repo),
        repo_frozen: map_value(value, :repo_frozen),
        company_frozen: map_value(value, :company_frozen),
        approval_gate_state: map_value(value, :approval_gate_state),
        preview_deploy_mode: map_value(value, :preview_deploy_mode),
        production_deploy_mode: map_value(value, :production_deploy_mode),
        deploy_approval_gate_state: map_value(value, :deploy_approval_gate_state),
        allowed_policy_classes: map_value(value, :allowed_policy_classes),
        required_any_issue_labels: map_value(value, :required_any_issue_labels),
        forbidden_issue_labels: map_value(value, :forbidden_issue_labels),
        merge_window: map_value(value, :merge_window),
        production_deploy_window: map_value(value, :production_deploy_window)
      })

    %__MODULE__{
      name: key,
      description: normalize_description(Map.get(pack, :description)),
      operating_mode:
        pack
        |> map_value(:operating_mode)
        |> normalize_operating_mode(default_operating_mode(key)),
      default_issue_class:
        pack
        |> map_value(:default_issue_class)
        |> normalize_issue_class(default_default_issue_class(key)),
      approval_gate_state:
        pack
        |> map_value(:approval_gate_state)
        |> normalize_approval_gate_state(default_approval_gate_state(key)),
      preview_deploy_mode:
        pack
        |> map_value(:preview_deploy_mode)
        |> normalize_preview_deploy_mode(default_preview_deploy_mode(key)),
      production_deploy_mode:
        pack
        |> map_value(:production_deploy_mode)
        |> normalize_production_deploy_mode(default_production_deploy_mode(key)),
      deploy_approval_gate_state:
        pack
        |> map_value(:deploy_approval_gate_state)
        |> normalize_approval_gate_state(default_deploy_approval_gate_state(key)),
      allowed_policy_classes:
        pack
        |> map_value(:allowed_policy_classes)
        |> normalize_allowed_policy_classes(default_allowed_policy_classes(key)),
      required_any_issue_labels:
        pack
        |> map_value(:required_any_issue_labels)
        |> normalize_issue_labels(),
      forbidden_issue_labels:
        pack
        |> map_value(:forbidden_issue_labels)
        |> normalize_issue_labels(),
      tracker_mutation_mode:
        pack
        |> map_value(:tracker_mutation_mode)
        |> normalize_permission_mode(default_tracker_mutation_mode(key)),
      pr_posting_mode:
        pack
        |> map_value(:pr_posting_mode)
        |> normalize_permission_mode(default_pr_posting_mode(key)),
      thread_resolution_mode:
        pack
        |> map_value(:thread_resolution_mode)
        |> normalize_permission_mode(default_thread_resolution_mode(key)),
      external_comment_mode:
        pack
        |> map_value(:external_comment_mode)
        |> normalize_permission_mode(default_external_comment_mode(key)),
      draft_first_required:
        pack
        |> map_value(:draft_first_required)
        |> normalize_boolean(default_draft_first_required(key)),
      confidence_language:
        pack
        |> map_value(:confidence_language)
        |> normalize_string_setting(default_confidence_language(key)),
      allowed_external_channels:
        pack
        |> map_value(:allowed_external_channels)
        |> normalize_issue_labels(),
      preview_deploy_allowed:
        pack
        |> map_value(:preview_deploy_allowed)
        |> normalize_boolean(default_preview_deploy_allowed(key)),
      production_deploy_allowed:
        pack
        |> map_value(:production_deploy_allowed)
        |> normalize_boolean(default_production_deploy_allowed(key)),
      max_concurrent_runs_per_company:
        pack
        |> map_value(:max_concurrent_runs_per_company)
        |> normalize_optional_positive_integer(),
      max_merges_per_day_per_repo:
        pack
        |> map_value(:max_merges_per_day_per_repo)
        |> normalize_optional_positive_integer(),
      repo_frozen:
        pack
        |> map_value(:repo_frozen)
        |> normalize_boolean(false),
      company_frozen:
        pack
        |> map_value(:company_frozen)
        |> normalize_boolean(false),
      merge_window:
        pack
        |> map_value(:merge_window)
        |> normalize_merge_window(),
      production_deploy_window:
        pack
        |> map_value(:production_deploy_window)
        |> normalize_merge_window()
    }
  end

  def resolve(name) do
    key = normalize_name(name) || :private_autopilot

    config_overrides =
      Config.policy_packs()
      |> map_value(key)
      |> case do
        %{} = overrides -> overrides
        _ -> %{}
      end

    pack =
      @default_packs
      |> Map.get(key, %{})
      |> Map.merge(config_overrides)

    %__MODULE__{
      name: key,
      description: normalize_description(Map.get(pack, :description)),
      operating_mode:
        pack
        |> map_value(:operating_mode)
        |> normalize_operating_mode(default_operating_mode(key)),
      default_issue_class:
        pack
        |> map_value(:default_issue_class)
        |> normalize_issue_class(default_default_issue_class(key)),
      approval_gate_state:
        pack
        |> map_value(:approval_gate_state)
        |> normalize_approval_gate_state(default_approval_gate_state(key)),
      preview_deploy_mode:
        pack
        |> map_value(:preview_deploy_mode)
        |> normalize_preview_deploy_mode(default_preview_deploy_mode(key)),
      production_deploy_mode:
        pack
        |> map_value(:production_deploy_mode)
        |> normalize_production_deploy_mode(default_production_deploy_mode(key)),
      deploy_approval_gate_state:
        pack
        |> map_value(:deploy_approval_gate_state)
        |> normalize_approval_gate_state(default_deploy_approval_gate_state(key)),
      allowed_policy_classes:
        pack
        |> map_value(:allowed_policy_classes)
        |> normalize_allowed_policy_classes(default_allowed_policy_classes(key)),
      required_any_issue_labels:
        pack
        |> map_value(:required_any_issue_labels)
        |> normalize_issue_labels(),
      forbidden_issue_labels:
        pack
        |> map_value(:forbidden_issue_labels)
        |> normalize_issue_labels(),
      tracker_mutation_mode:
        pack
        |> map_value(:tracker_mutation_mode)
        |> normalize_permission_mode(default_tracker_mutation_mode(key)),
      pr_posting_mode:
        pack
        |> map_value(:pr_posting_mode)
        |> normalize_permission_mode(default_pr_posting_mode(key)),
      thread_resolution_mode:
        pack
        |> map_value(:thread_resolution_mode)
        |> normalize_permission_mode(default_thread_resolution_mode(key)),
      external_comment_mode:
        pack
        |> map_value(:external_comment_mode)
        |> normalize_permission_mode(default_external_comment_mode(key)),
      draft_first_required:
        pack
        |> map_value(:draft_first_required)
        |> normalize_boolean(default_draft_first_required(key)),
      confidence_language:
        pack
        |> map_value(:confidence_language)
        |> normalize_string_setting(default_confidence_language(key)),
      allowed_external_channels:
        pack
        |> map_value(:allowed_external_channels)
        |> normalize_issue_labels(),
      preview_deploy_allowed:
        pack
        |> map_value(:preview_deploy_allowed)
        |> normalize_boolean(default_preview_deploy_allowed(key)),
      production_deploy_allowed:
        pack
        |> map_value(:production_deploy_allowed)
        |> normalize_boolean(default_production_deploy_allowed(key)),
      max_concurrent_runs_per_company:
        pack
        |> map_value(:max_concurrent_runs_per_company)
        |> normalize_optional_positive_integer(),
      max_merges_per_day_per_repo:
        pack
        |> map_value(:max_merges_per_day_per_repo)
        |> normalize_optional_positive_integer(),
      repo_frozen:
        pack
        |> map_value(:repo_frozen)
        |> normalize_boolean(false),
      company_frozen:
        pack
        |> map_value(:company_frozen)
        |> normalize_boolean(false),
      merge_window:
        pack
        |> map_value(:merge_window)
        |> normalize_merge_window(),
      production_deploy_window:
        pack
        |> map_value(:production_deploy_window)
        |> normalize_merge_window()
    }
  end

  @spec name_string(t() | atom() | nil) :: String.t() | nil
  def name_string(%__MODULE__{name: name}), do: name_string(name)
  def name_string(name) when is_atom(name), do: Atom.to_string(name)
  def name_string(_name), do: nil

  @spec allows?(t(), String.t() | atom() | nil) :: boolean()
  def allows?(%__MODULE__{} = pack, policy_class) do
    candidate =
      policy_class
      |> IssuePolicy.normalize_class()
      |> IssuePolicy.class_to_string()

    is_binary(candidate) and candidate in pack.allowed_policy_classes
  end

  @spec tracker_mutation_allowed?(t()) :: boolean()
  def tracker_mutation_allowed?(%__MODULE__{} = pack), do: pack.tracker_mutation_mode == "allowed"

  @spec pr_posting_allowed?(t()) :: boolean()
  def pr_posting_allowed?(%__MODULE__{} = pack), do: pack.pr_posting_mode == "allowed"

  @spec thread_resolution_allowed?(t()) :: boolean()
  def thread_resolution_allowed?(%__MODULE__{} = pack), do: pack.thread_resolution_mode == "allowed"

  @spec external_comment_posting_allowed?(t()) :: boolean()
  def external_comment_posting_allowed?(%__MODULE__{} = pack), do: pack.external_comment_mode == "allowed"

  @spec draft_first_required?(t()) :: boolean()
  def draft_first_required?(%__MODULE__{} = pack), do: pack.draft_first_required

  @spec repo_or_company_frozen?(t()) :: boolean()
  def repo_or_company_frozen?(%__MODULE__{} = pack), do: pack.repo_frozen or pack.company_frozen

  @spec workload_label_status(t(), [String.t()]) ::
          :allowed | {:missing_required_any, [String.t()]} | {:forbidden_present, [String.t()]}
  def workload_label_status(%__MODULE__{} = pack, labels) do
    issue_labels = normalize_issue_labels(labels)
    issue_label_set = MapSet.new(issue_labels)
    required = normalize_issue_labels(pack.required_any_issue_labels)
    forbidden = normalize_issue_labels(pack.forbidden_issue_labels)

    cond do
      required != [] and Enum.all?(required, &(not MapSet.member?(issue_label_set, &1))) ->
        {:missing_required_any, required}

      forbidden != [] ->
        matches = Enum.filter(forbidden, &MapSet.member?(issue_label_set, &1))

        if matches == [] do
          :allowed
        else
          {:forbidden_present, matches}
        end

      true ->
        :allowed
    end
  end

  @spec automerge_window_status(t(), DateTime.t()) :: :allowed | {:deferred, map()}
  def automerge_window_status(%__MODULE__{merge_window: nil}, _now), do: :allowed

  def automerge_window_status(%__MODULE__{merge_window: merge_window}, now) when is_map(merge_window) do
    case normalize_merge_window(merge_window) do
      nil ->
        :allowed

      normalized ->
        timezone = Map.get(normalized, :timezone, "Etc/UTC")

        with {:ok, local_now} <- DateTime.shift_zone(now, timezone) do
          if merge_window_open?(local_now, normalized) do
            :allowed
          else
            next_allowed_at = next_allowed_datetime(local_now, normalized)

            {:deferred,
             %{
               timezone: timezone,
               days: Map.get(normalized, :days, []),
               start_hour: Map.get(normalized, :start_hour),
               end_hour: Map.get(normalized, :end_hour),
               current_at: DateTime.to_iso8601(local_now),
               next_allowed_at: DateTime.to_iso8601(next_allowed_at)
             }}
          end
        else
          _ -> :allowed
        end
    end
  end

  @spec production_deploy_window_status(t(), DateTime.t()) :: :allowed | {:deferred, map()}
  def production_deploy_window_status(%__MODULE__{production_deploy_window: nil}, _now), do: :allowed

  def production_deploy_window_status(%__MODULE__{production_deploy_window: deploy_window}, now)
      when is_map(deploy_window) do
    case normalize_merge_window(deploy_window) do
      nil ->
        :allowed

      normalized ->
        timezone = Map.get(normalized, :timezone, "Etc/UTC")

        with {:ok, local_now} <- DateTime.shift_zone(now, timezone) do
          if merge_window_open?(local_now, normalized) do
            :allowed
          else
            next_allowed_at = next_allowed_datetime(local_now, normalized)

            {:deferred,
             %{
               timezone: timezone,
               days: Map.get(normalized, :days, []),
               start_hour: Map.get(normalized, :start_hour),
               end_hour: Map.get(normalized, :end_hour),
               current_at: DateTime.to_iso8601(local_now),
               next_allowed_at: DateTime.to_iso8601(next_allowed_at)
             }}
          end
        else
          _ -> :allowed
        end
    end
  end

  @spec normalize_name(String.t() | atom() | nil) :: atom() | nil
  def normalize_name(value) when is_atom(value) do
    case value do
      :client_safe ->
        :client_safe_shadow

      name ->
        if Map.has_key?(@default_packs, name), do: name, else: nil
    end
  end

  def normalize_name(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      "private_autopilot" -> :private_autopilot
      "client_safe" -> :client_safe_shadow
      "client_safe_shadow" -> :client_safe_shadow
      "client_safe_pr_active" -> :client_safe_pr_active
      _ -> nil
    end
  end

  def normalize_name(_value), do: nil

  defp normalize_description(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "No description provided."
      trimmed -> trimmed
    end
  end

  defp normalize_description(_value), do: "No description provided."

  defp normalize_issue_class(value, fallback) do
    value
    |> IssuePolicy.normalize_class()
    |> IssuePolicy.class_to_string() || fallback
  end

  defp normalize_allowed_policy_classes(value, fallback) when is_list(value) do
    value
    |> Enum.map(&IssuePolicy.normalize_class/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&IssuePolicy.class_to_string/1)
    |> Enum.uniq()
    |> case do
      [] -> fallback
      classes -> classes
    end
  end

  defp normalize_allowed_policy_classes(_value, fallback), do: fallback

  defp normalize_issue_labels(value) when is_list(value) do
    value
    |> Enum.map(&normalize_issue_label/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_issue_labels(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_issue_labels()
  end

  defp normalize_issue_labels(_value), do: []

  defp normalize_issue_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_issue_label(_value), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)

  defp default_default_issue_class(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:default_issue_class)
  end

  defp default_allowed_policy_classes(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:allowed_policy_classes)
  end

  defp default_operating_mode(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:operating_mode)
  end

  defp default_tracker_mutation_mode(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:tracker_mutation_mode)
  end

  defp default_pr_posting_mode(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:pr_posting_mode)
  end

  defp default_thread_resolution_mode(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:thread_resolution_mode)
  end

  defp default_external_comment_mode(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:external_comment_mode)
  end

  defp default_draft_first_required(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:draft_first_required)
  end

  defp default_confidence_language(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:confidence_language)
  end

  defp default_preview_deploy_allowed(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:preview_deploy_allowed)
  end

  defp default_production_deploy_allowed(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:production_deploy_allowed)
  end

  defp default_approval_gate_state(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:approval_gate_state)
  end

  defp default_preview_deploy_mode(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:preview_deploy_mode)
  end

  defp default_production_deploy_mode(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:production_deploy_mode)
  end

  defp default_deploy_approval_gate_state(name) do
    @default_packs
    |> Map.fetch!(name)
    |> Map.fetch!(:deploy_approval_gate_state)
  end

  defp normalize_preview_deploy_mode(:disabled, _fallback), do: :disabled
  defp normalize_preview_deploy_mode(:after_merge, _fallback), do: :after_merge
  defp normalize_preview_deploy_mode("disabled", _fallback), do: :disabled
  defp normalize_preview_deploy_mode("after_merge", _fallback), do: :after_merge
  defp normalize_preview_deploy_mode(_, fallback), do: fallback

  defp normalize_production_deploy_mode(:disabled, _fallback), do: :disabled
  defp normalize_production_deploy_mode(:after_preview, _fallback), do: :after_preview
  defp normalize_production_deploy_mode("disabled", _fallback), do: :disabled
  defp normalize_production_deploy_mode("after_preview", _fallback), do: :after_preview
  defp normalize_production_deploy_mode(_, fallback), do: fallback

  defp normalize_approval_gate_state(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp normalize_approval_gate_state(_value, fallback), do: fallback

  defp normalize_operating_mode(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp normalize_operating_mode(_value, fallback), do: fallback

  defp normalize_permission_mode(value, fallback) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "allowed" -> "allowed"
      "forbidden" -> "forbidden"
      "draft_only" -> "draft_only"
      "" -> fallback
      _ -> fallback
    end
  end

  defp normalize_permission_mode(_value, fallback), do: fallback

  defp normalize_string_setting(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      normalized -> normalized
    end
  end

  defp normalize_string_setting(_value, fallback), do: fallback

  defp normalize_boolean(value, _fallback) when value in [true, false], do: value
  defp normalize_boolean(_value, fallback), do: fallback

  defp normalize_optional_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_optional_positive_integer(_value), do: nil

  defp normalize_merge_window(%{} = value) do
    timezone = Map.get(value, :timezone) || Map.get(value, "timezone") || "Etc/UTC"

    days =
      value
      |> then(fn window -> Map.get(window, :days) || Map.get(window, "days") || [] end)
      |> normalize_window_days()

    start_hour =
      value
      |> then(fn window -> Map.get(window, :start_hour) || Map.get(window, "start_hour") end)
      |> normalize_hour()

    end_hour =
      value
      |> then(fn window -> Map.get(window, :end_hour) || Map.get(window, "end_hour") end)
      |> normalize_hour()

    if days == [] or is_nil(start_hour) or is_nil(end_hour) or start_hour == end_hour do
      nil
    else
      %{
        timezone: to_string(timezone),
        days: days,
        start_hour: start_hour,
        end_hour: end_hour
      }
    end
  end

  defp normalize_merge_window(_value), do: nil

  defp normalize_window_days(days) when is_list(days) do
    days
    |> Enum.map(&normalize_weekday/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_window_days(_days), do: []

  defp normalize_weekday(value) when is_integer(value) and value in 1..7, do: value

  defp normalize_weekday(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "mon" -> 1
      "monday" -> 1
      "tue" -> 2
      "tues" -> 2
      "tuesday" -> 2
      "wed" -> 3
      "wednesday" -> 3
      "thu" -> 4
      "thur" -> 4
      "thurs" -> 4
      "thursday" -> 4
      "fri" -> 5
      "friday" -> 5
      "sat" -> 6
      "saturday" -> 6
      "sun" -> 7
      "sunday" -> 7
      _ -> nil
    end
  end

  defp normalize_weekday(_value), do: nil

  defp normalize_hour(value) when is_integer(value) and value in 0..23, do: value

  defp normalize_hour(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {hour, ""} when hour in 0..23 -> hour
      _ -> nil
    end
  end

  defp normalize_hour(_value), do: nil

  defp merge_window_open?(%DateTime{} = local_now, merge_window) do
    day = Date.day_of_week(DateTime.to_date(local_now))
    days = Map.get(merge_window, :days, [])
    hour = local_now.hour
    start_hour = Map.get(merge_window, :start_hour)
    end_hour = Map.get(merge_window, :end_hour)

    day in days and hour >= start_hour and hour < end_hour
  end

  defp next_allowed_datetime(%DateTime{} = local_now, merge_window) do
    days = Map.get(merge_window, :days, [])
    start_hour = Map.get(merge_window, :start_hour)

    Enum.find_value(0..7, fn offset ->
      candidate_date = Date.add(DateTime.to_date(local_now), offset)
      candidate_day = Date.day_of_week(candidate_date)

      if candidate_day in days do
        candidate =
          candidate_date
          |> NaiveDateTime.new!(~T[00:00:00])
          |> NaiveDateTime.add(start_hour * 3600, :second)
          |> DateTime.from_naive!(local_now.time_zone)

        if DateTime.compare(candidate, local_now) == :gt do
          candidate
        else
          nil
        end
      end
    end) || local_now
  end
end
