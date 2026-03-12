defmodule SymphonyElixir.ManualIssueSpec do
  @moduledoc """
  Validation and normalization for tracker-free manual issue submissions.
  """

  alias SymphonyElixir.IssuePolicy
  alias SymphonyElixir.Linear.Issue

  @runtime_prefix "manual:"

  @type spec_map :: %{
          id: String.t(),
          identifier: String.t(),
          title: String.t(),
          description: String.t() | nil,
          acceptance_criteria: [String.t()],
          validation: [String.t()],
          out_of_scope: [String.t()],
          policy_class: String.t() | nil,
          labels: [String.t()],
          priority: integer() | nil,
          url: String.t() | nil,
          branch_name: String.t() | nil,
          internal_identifier: String.t() | nil,
          internal_url: String.t() | nil
        }

  @spec validate(map()) :: {:ok, spec_map()} | {:error, term()}
  def validate(payload) when is_map(payload) do
    with {:ok, id} <- require_string(payload, "id"),
         {:ok, identifier} <- require_string(payload, "identifier"),
         {:ok, title} <- require_string(payload, "title"),
         {:ok, acceptance_criteria} <- require_string_list(payload, "acceptance_criteria"),
         {:ok, policy_class} <- optional_policy_class(payload, "policy_class") do
      {:ok,
       %{
         id: id,
         identifier: identifier,
         title: title,
         description: optional_string(payload, "description"),
         acceptance_criteria: acceptance_criteria,
         validation: optional_string_list(payload, "validation"),
         out_of_scope: optional_string_list(payload, "out_of_scope"),
         policy_class: policy_class,
         labels: optional_string_list(payload, "labels"),
         priority: optional_integer(payload, "priority"),
         url: optional_string(payload, "url"),
         branch_name: optional_string(payload, "branch_name"),
         internal_identifier: optional_string(payload, "internal_identifier"),
         internal_url: optional_string(payload, "internal_url")
       }}
    end
  end

  def validate(_payload), do: {:error, {:invalid_manual_issue_spec, :not_a_map}}

  @spec runtime_issue_id(String.t()) :: String.t()
  def runtime_issue_id(id) when is_binary(id) do
    @runtime_prefix <> String.trim(id)
  end

  @spec runtime_issue_id?(term()) :: boolean()
  def runtime_issue_id?(value) when is_binary(value), do: String.starts_with?(value, @runtime_prefix)
  def runtime_issue_id?(_value), do: false

  @spec render_description(spec_map()) :: String.t()
  def render_description(spec) when is_map(spec) do
    []
    |> maybe_add_section("Description", List.wrap(Map.get(spec, :description)))
    |> maybe_add_section("Acceptance Criteria", Map.get(spec, :acceptance_criteria, []))
    |> maybe_add_section("Validation", Map.get(spec, :validation, []))
    |> maybe_add_section("Out of Scope", Map.get(spec, :out_of_scope, []))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  @spec to_issue(spec_map()) :: Issue.t()
  def to_issue(spec) when is_map(spec) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    labels = normalized_labels(spec)

    %Issue{
      id: runtime_issue_id(Map.fetch!(spec, :id)),
      external_id: Map.fetch!(spec, :id),
      canonical_identifier: Map.fetch!(spec, :identifier),
      identifier: Map.fetch!(spec, :identifier),
      title: Map.fetch!(spec, :title),
      description: render_description(spec),
      priority: Map.get(spec, :priority),
      state: "Todo",
      branch_name: Map.get(spec, :branch_name),
      url: Map.get(spec, :url),
      internal_identifier: Map.get(spec, :internal_identifier),
      internal_url: Map.get(spec, :internal_url),
      assignee_id: nil,
      source: :manual,
      labels: labels,
      blocked_by: [],
      assigned_to_worker: true,
      created_at: now,
      updated_at: now
    }
  end

  defp normalized_labels(spec) do
    base_labels = Map.get(spec, :labels, [])

    policy_label =
      spec
      |> Map.get(:policy_class)
      |> IssuePolicy.normalize_class()
      |> IssuePolicy.label_for_class()

    [policy_label | base_labels]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp require_string(payload, key) do
    case optional_string(payload, key) do
      nil -> {:error, {:invalid_manual_issue_spec, {:missing_required_field, key}}}
      value -> {:ok, value}
    end
  end

  defp require_string_list(payload, key) do
    values = optional_string_list(payload, key)

    if values == [] do
      {:error, {:invalid_manual_issue_spec, {:missing_required_field, key}}}
    else
      {:ok, values}
    end
  end

  defp optional_policy_class(payload, key) do
    case optional_string(payload, key) do
      nil ->
        {:ok, nil}

      value ->
        case IssuePolicy.normalize_class(value) do
          nil -> {:error, {:invalid_manual_issue_spec, {:invalid_policy_class, value}}}
          class -> {:ok, IssuePolicy.class_to_string(class)}
        end
    end
  end

  defp optional_string(payload, key) when is_binary(key) do
    payload
    |> get_value(key)
    |> case do
      nil ->
        nil

      value ->
        value
        |> to_string()
        |> String.trim()
        |> case do
          "" -> nil
          normalized -> normalized
        end
    end
  end

  defp optional_string_list(payload, key) when is_binary(key) do
    payload
    |> get_value(key)
    |> normalize_string_list()
  end

  defp optional_integer(payload, key) when is_binary(key) do
    case get_value(payload, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&optional_string(%{"value" => &1}, "value"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(_value), do: []

  defp maybe_add_section(sections, _title, []), do: sections

  defp maybe_add_section(sections, title, values) when is_list(values) do
    normalized =
      values
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if normalized == [] do
      sections
    else
      [
        sections,
        [
          "## " <> title,
          Enum.map_join(normalized, "\n", fn value -> "- " <> value end)
        ]
      ]
      |> List.flatten()
    end
  end

  defp get_value(payload, key) when is_map(payload) do
    Map.get(payload, key) ||
      case existing_atom_key(key) do
        nil -> nil
        atom_key -> Map.get(payload, atom_key)
      end
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
