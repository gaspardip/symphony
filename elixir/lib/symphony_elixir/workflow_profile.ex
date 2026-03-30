defmodule SymphonyElixir.WorkflowProfile do
  @moduledoc """
  Resolves runtime workflow profiles from policy class and workflow config.

  Profiles are runtime-owned behavior bundles; the agent does not choose them.
  """

  alias SymphonyElixir.{Config, PolicyPack}
  alias SymphonyElixir.IssuePolicy

  defstruct [
    :name,
    :merge_mode,
    :approval_gate_kind,
    :approval_gate_state,
    :deploy_approval_gate_kind,
    :deploy_approval_gate_state,
    :post_merge_verification_required,
    :preview_deploy_mode,
    :production_deploy_mode,
    :post_deploy_verification_required,
    :max_turns_override
  ]

  @type name :: :fully_autonomous | :review_required | :never_automerge
  @type merge_mode :: :automerge | :review_gate | :manual_only

  @type t :: %__MODULE__{
          name: name(),
          merge_mode: merge_mode(),
          approval_gate_kind: String.t(),
          approval_gate_state: String.t(),
          deploy_approval_gate_kind: String.t(),
          deploy_approval_gate_state: String.t(),
          post_merge_verification_required: boolean(),
          preview_deploy_mode: :disabled | :after_merge,
          production_deploy_mode: :disabled | :after_preview,
          post_deploy_verification_required: boolean(),
          max_turns_override: pos_integer() | nil
        }

  @default_profiles %{
    fully_autonomous: %{
      merge_mode: :automerge,
      approval_gate_state: "Human Review",
      deploy_approval_gate_state: "Deploy Approval",
      post_merge_verification_required: true,
      preview_deploy_mode: :disabled,
      production_deploy_mode: :disabled,
      post_deploy_verification_required: true,
      max_turns_override: nil
    },
    review_required: %{
      merge_mode: :review_gate,
      approval_gate_state: "Human Review",
      deploy_approval_gate_state: "Deploy Approval",
      post_merge_verification_required: true,
      preview_deploy_mode: :disabled,
      production_deploy_mode: :disabled,
      post_deploy_verification_required: true,
      max_turns_override: nil
    },
    never_automerge: %{
      merge_mode: :manual_only,
      approval_gate_state: "Human Review",
      deploy_approval_gate_state: "Deploy Approval",
      post_merge_verification_required: true,
      preview_deploy_mode: :disabled,
      production_deploy_mode: :disabled,
      post_deploy_verification_required: true,
      max_turns_override: nil
    }
  }

  @spec default_profiles() :: map()
  def default_profiles, do: @default_profiles

  @spec resolve(String.t() | atom() | nil, keyword()) :: t()
  def resolve(policy_class, opts \\ []) do
    name = IssuePolicy.normalize_class(policy_class) || :fully_autonomous
    pack = PolicyPack.resolve(Keyword.get(opts, :policy_pack))
    default_profile = Map.get(@default_profiles, name, %{})
    configured_profile = Map.get(Config.workflow_profiles(), name, %{})

    profile =
      default_profile
      |> Map.merge(configured_profile)

    approval_gate_state =
      normalize_approval_gate_state(
        Map.get(configured_profile, :approval_gate_state) ||
          pack.approval_gate_state ||
          Map.get(default_profile, :approval_gate_state)
      )

    deploy_approval_gate_state =
      normalize_approval_gate_state(
        Map.get(configured_profile, :deploy_approval_gate_state) ||
          Map.get(profile, :deploy_approval_gate_state) ||
          pack.deploy_approval_gate_state ||
          "Deploy Approval"
      )

    %__MODULE__{
      name: name,
      merge_mode: normalize_merge_mode(Map.get(profile, :merge_mode)),
      approval_gate_state: approval_gate_state,
      approval_gate_kind: approval_gate_kind(approval_gate_state),
      deploy_approval_gate_state: deploy_approval_gate_state,
      deploy_approval_gate_kind: approval_gate_kind(deploy_approval_gate_state),
      post_merge_verification_required: Map.get(profile, :post_merge_verification_required, true),
      preview_deploy_mode:
        normalize_preview_deploy_mode(
          Map.get(configured_profile, :preview_deploy_mode) ||
            Map.get(profile, :preview_deploy_mode) ||
            pack.preview_deploy_mode
        ),
      production_deploy_mode:
        normalize_production_deploy_mode(
          Map.get(configured_profile, :production_deploy_mode) ||
            Map.get(profile, :production_deploy_mode) ||
            pack.production_deploy_mode
        ),
      post_deploy_verification_required: Map.get(profile, :post_deploy_verification_required, true),
      max_turns_override: normalize_max_turns(Map.get(profile, :max_turns_override))
    }
  end

  @spec approval_gate_state(String.t() | atom() | nil, keyword()) :: String.t()
  def approval_gate_state(policy_class, opts \\ []) do
    policy_class
    |> resolve(opts)
    |> Map.get(:approval_gate_state)
  end

  @spec approval_gate_states(keyword()) :: [String.t()]
  def approval_gate_states(opts \\ []) do
    @default_profiles
    |> Map.keys()
    |> Enum.map(&resolve(&1, opts))
    |> Enum.flat_map(&[&1.approval_gate_state, &1.deploy_approval_gate_state])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec approval_gate_state?(String.t() | nil) :: boolean()
  @spec approval_gate_state?(String.t() | nil, keyword()) :: boolean()
  def approval_gate_state?(state, opts \\ [])

  @spec approval_gate_state?(String.t() | nil, keyword()) :: boolean()
  def approval_gate_state?(state, opts) when is_binary(state) do
    normalized = normalize_approval_gate_state_key(state)
    Enum.any?(approval_gate_states(opts), &(normalize_approval_gate_state_key(&1) == normalized))
  end

  def approval_gate_state?(_state, _opts), do: false

  @spec name_string(t() | name() | nil) :: String.t() | nil
  def name_string(%__MODULE__{name: name}), do: name_string(name)
  def name_string(name) when is_atom(name), do: Atom.to_string(name)
  def name_string(_name), do: nil

  @spec approval_gate_kind(String.t() | nil) :: String.t()
  def approval_gate_kind(state) when is_binary(state) do
    case normalize_approval_gate_state_key(state) do
      "client approval" -> "client_approval"
      "deploy approval" -> "deploy_approval"
      "human review" -> "review"
      "human approval" -> "review"
      _ -> "approval"
    end
  end

  def approval_gate_kind(_state), do: "approval"

  defp normalize_merge_mode(:automerge), do: :automerge
  defp normalize_merge_mode(:review_gate), do: :review_gate
  defp normalize_merge_mode(:manual_only), do: :manual_only
  defp normalize_merge_mode("automerge"), do: :automerge
  defp normalize_merge_mode("review_gate"), do: :review_gate
  defp normalize_merge_mode("manual_only"), do: :manual_only
  defp normalize_merge_mode(_), do: :automerge

  defp normalize_preview_deploy_mode(:disabled), do: :disabled
  defp normalize_preview_deploy_mode(:after_merge), do: :after_merge
  defp normalize_preview_deploy_mode("disabled"), do: :disabled
  defp normalize_preview_deploy_mode("after_merge"), do: :after_merge
  defp normalize_preview_deploy_mode(_), do: :disabled

  defp normalize_production_deploy_mode(:disabled), do: :disabled
  defp normalize_production_deploy_mode(:after_preview), do: :after_preview
  defp normalize_production_deploy_mode("disabled"), do: :disabled
  defp normalize_production_deploy_mode("after_preview"), do: :after_preview
  defp normalize_production_deploy_mode(_), do: :disabled

  defp normalize_approval_gate_state(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "Human Review"
      trimmed -> trimmed
    end
  end

  defp normalize_approval_gate_state(_), do: "Human Review"

  defp normalize_max_turns(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_turns(_value), do: nil

  defp normalize_approval_gate_state_key(value) do
    value
    |> SymphonyElixir.Util.normalize_state()
    |> String.replace(~r/[\s_-]+/u, " ")
  end
end
