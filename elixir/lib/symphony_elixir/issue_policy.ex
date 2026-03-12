defmodule SymphonyElixir.IssuePolicy do
  @moduledoc """
  Resolves the effective policy class for an issue from operator overrides,
  standardized issue labels, and workflow defaults.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RuleCatalog

  @fully_autonomous :fully_autonomous
  @review_required :review_required
  @never_automerge :never_automerge

  @label_to_class %{
    "policy:fully-autonomous" => @fully_autonomous,
    "policy:review-required" => @review_required,
    "policy:never-automerge" => @never_automerge
  }

  @class_to_label Map.new(@label_to_class, fn {label, class} -> {class, label} end)
  @valid_classes [@fully_autonomous, @review_required, @never_automerge]

  @type class :: :fully_autonomous | :review_required | :never_automerge

  @type resolution :: %{
          class: class(),
          source: :override | :label | :default,
          override: class() | nil,
          label: String.t() | nil,
          labels: [String.t()]
        }

  @type conflict :: %{
          code: :invalid_labels,
          rule_id: String.t(),
          failure_class: String.t(),
          summary: String.t(),
          human_action: String.t(),
          labels: [String.t()]
        }

  @spec valid_classes() :: [class()]
  def valid_classes, do: @valid_classes

  @spec normalize_class(term()) :: class() | nil
  def normalize_class(value) when is_atom(value) do
    if value in @valid_classes, do: value, else: nil
  end

  def normalize_class(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      "fully_autonomous" -> @fully_autonomous
      "review_required" -> @review_required
      "never_automerge" -> @never_automerge
      _ -> nil
    end
  end

  def normalize_class(_value), do: nil

  @spec class_to_string(class() | nil) :: String.t() | nil
  def class_to_string(nil), do: nil
  def class_to_string(@fully_autonomous), do: "fully_autonomous"
  def class_to_string(@review_required), do: "review_required"
  def class_to_string(@never_automerge), do: "never_automerge"

  @spec label_for_class(class() | nil) :: String.t() | nil
  def label_for_class(class) when is_atom(class), do: Map.get(@class_to_label, class)
  def label_for_class(_class), do: nil

  @spec resolve(Issue.t() | map(), keyword()) :: {:ok, resolution()} | {:error, conflict()}
  def resolve(issue, opts \\ []) do
    override = normalize_class(Keyword.get(opts, :override))
    default = normalize_class(Keyword.get(opts, :default)) || @fully_autonomous
    allowed_classes = normalize_allowed_classes(Keyword.get(opts, :allowed_classes))
    pack_name = Keyword.get(opts, :policy_pack)
    labels = policy_labels(issue)
    matched_classes = labels |> Enum.map(&Map.fetch!(@label_to_class, &1)) |> Enum.uniq()

    case matched_classes do
      [] ->
        maybe_validate_allowed_classes(
          %{
            class: override || default,
            source: if(is_nil(override), do: :default, else: :override),
            override: override,
            label: nil,
            labels: []
          },
          allowed_classes,
          pack_name
        )

      [label_class] ->
        maybe_validate_allowed_classes(
          %{
            class: override || label_class,
            source: if(is_nil(override), do: :label, else: :override),
            override: override,
            label: Enum.at(labels, 0),
            labels: labels
          },
          allowed_classes,
          pack_name
        )

      _multiple ->
        {:error,
         %{
           code: :invalid_labels,
           rule_id: RuleCatalog.rule_id(:policy_invalid_labels),
           failure_class: RuleCatalog.failure_class(:policy_invalid_labels),
           summary: "The issue has conflicting policy labels.",
           human_action: RuleCatalog.human_action(:policy_invalid_labels),
           labels: labels
         }}
    end
  end

  @spec policy_labels(Issue.t() | map()) :: [String.t()]
  def policy_labels(issue) do
    issue
    |> issue_labels()
    |> Enum.map(&normalize_label/1)
    |> Enum.filter(&Map.has_key?(@label_to_class, &1))
    |> Enum.uniq()
  end

  defp issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  defp issue_labels(%{} = issue), do: Map.get(issue, :labels) || Map.get(issue, "labels") || []
  defp issue_labels(_issue), do: []

  defp normalize_label(label) do
    label
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_allowed_classes(value) when is_list(value) do
    value
    |> Enum.map(&normalize_class/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_classes(_value), do: []

  defp maybe_validate_allowed_classes(resolution, [], _pack_name), do: {:ok, resolution}

  defp maybe_validate_allowed_classes(%{class: class} = resolution, allowed_classes, pack_name) do
    if class in allowed_classes do
      {:ok, resolution}
    else
      class_string = class_to_string(class)
      pack_label = pack_name |> to_string() |> String.replace("_", " ")

      {:error,
       %{
         code: :policy_pack_disallows_class,
         rule_id: RuleCatalog.rule_id(:policy_pack_disallows_class),
         failure_class: RuleCatalog.failure_class(:policy_pack_disallows_class),
         summary: "The current policy pack does not allow the requested policy class.",
         human_action: RuleCatalog.human_action(:policy_pack_disallows_class),
         labels: Map.get(resolution, :labels, []),
         pack_name: pack_name,
         requested_class: class_string,
         details: "Policy pack `#{pack_label}` does not allow `#{class_string}`."
       }}
    end
  end
end
