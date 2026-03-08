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
    labels = policy_labels(issue)
    matched_classes = labels |> Enum.map(&Map.fetch!(@label_to_class, &1)) |> Enum.uniq()

    case matched_classes do
      [] ->
        {:ok,
         %{
           class: override || default,
           source: if(is_nil(override), do: :default, else: :override),
           override: override,
           label: nil,
           labels: []
         }}

      [label_class] ->
        {:ok,
         %{
           class: override || label_class,
           source: if(is_nil(override), do: :label, else: :override),
           override: override,
           label: Enum.at(labels, 0),
           labels: labels
         }}

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
end
