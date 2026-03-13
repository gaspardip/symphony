defmodule SymphonyElixir.RiskClassifier do
  @moduledoc """
  Runtime-owned heuristic change classifier used to surface risk and proof posture.
  """

  alias SymphonyElixir.{RunInspector, UiProof, WorkflowProfile}

  defstruct [
    :change_type,
    :risk_level,
    :proof_class,
    :approval_class,
    :reason,
    ui_proof_required: false,
    behavioral_proof_required: false
  ]

  @type t :: %__MODULE__{
          change_type: String.t(),
          risk_level: String.t(),
          proof_class: String.t(),
          approval_class: String.t(),
          reason: String.t(),
          ui_proof_required: boolean(),
          behavioral_proof_required: boolean()
        }

  @doc """
  Classify the current run using changed paths, harness proof posture, and workflow profile.
  """
  @spec classify(map(), RunInspector.snapshot() | map(), map() | nil, WorkflowProfile.t()) :: t()
  def classify(entry, workspace, harness, workflow_profile) when is_map(entry) do
    changed_paths = changed_paths(entry, workspace)
    ui_required = ui_proof_required?(changed_paths, entry, harness)
    docs_only = docs_or_config_only?(changed_paths)
    deploy_change = deploy_related?(changed_paths)
    proof_class = proof_class(docs_only, ui_required, deploy_change)
    approval_class = approval_class(workflow_profile, deploy_change)
    change_type = change_type(docs_only, ui_required, deploy_change, changed_paths)
    risk_level = risk_level(change_type, workflow_profile)

    %__MODULE__{
      change_type: change_type,
      risk_level: risk_level,
      proof_class: proof_class,
      approval_class: approval_class,
      reason: reason(change_type, proof_class, approval_class),
      ui_proof_required: ui_required,
      behavioral_proof_required: proof_class in ["behavioral", "ui", "deploy"]
    }
  end

  defp changed_paths(entry, workspace) do
    from_entry = Map.get(entry, :changed_paths) || Map.get(entry, "changed_paths")

    cond do
      is_list(from_entry) and from_entry != [] ->
        Enum.map(from_entry, &to_string/1)

      is_map(workspace) and is_binary(Map.get(workspace, :workspace)) ->
        RunInspector.changed_paths(Map.get(workspace, :workspace))

      is_map(workspace) and is_binary(Map.get(workspace, "workspace")) ->
        RunInspector.changed_paths(Map.get(workspace, "workspace"))

      true ->
        []
    end
  end

  defp ui_proof_required?(changed_paths, entry, harness) do
    explicit =
      Map.get(entry, :ui_proof_required) ||
        Map.get(entry, "ui_proof_required") ||
        false

    explicit or ui_proof_required_from_harness?(changed_paths, harness)
  end

  defp ui_proof_required_from_harness?(changed_paths, harness) do
    result =
      UiProof.evaluate(
        ".",
        harness,
        changed_paths,
        %RunInspector.Snapshot{pr_url: nil, check_statuses: [], harness: harness},
        shell_runner: fn _, _, _ -> {"", 0} end
      )

    result.required?
  end

  defp docs_or_config_only?([]), do: false

  defp docs_or_config_only?(changed_paths) do
    Enum.all?(changed_paths, fn path ->
      downcased = String.downcase(path)

      String.ends_with?(downcased, [".md", ".txt", ".rst", ".json", ".yaml", ".yml", ".toml"]) or
        String.starts_with?(downcased, ".github/") or
        String.contains?(downcased, "/docs/") or
        String.contains?(downcased, "/doc/")
    end)
  end

  defp deploy_related?(changed_paths) do
    Enum.any?(changed_paths, fn path ->
      downcased = String.downcase(path)

      String.contains?(downcased, "deploy") or
        String.contains?(downcased, ".symphony/") or
        String.contains?(downcased, ".github/workflows/")
    end)
  end

  defp proof_class(_docs_only, _ui_required, true), do: "deploy"
  defp proof_class(true, false, _deploy_change), do: "docs_only"
  defp proof_class(_docs_only, true, _deploy_change), do: "ui"
  defp proof_class(_docs_only, _ui_required, _deploy_change), do: "behavioral"

  defp approval_class(%WorkflowProfile{merge_mode: :manual_only}, _deploy_change), do: "manual_gate"
  defp approval_class(%WorkflowProfile{merge_mode: :review_gate}, _deploy_change), do: "review_gate"

  defp approval_class(%WorkflowProfile{} = workflow_profile, true)
       when workflow_profile.production_deploy_mode not in [:disabled] do
    "deploy_gate"
  end

  defp approval_class(_workflow_profile, _deploy_change), do: "autonomous"

  defp change_type(_docs_only, _ui_required, true, _paths), do: "deploy_sensitive"
  defp change_type(true, _ui_required, _deploy_change, _paths), do: "docs_or_config"
  defp change_type(_docs_only, true, _deploy_change, _paths), do: "ui_affecting"
  defp change_type(_docs_only, _ui_required, _deploy_change, []), do: "unknown"
  defp change_type(_docs_only, _ui_required, _deploy_change, _paths), do: "behavioral"

  defp risk_level("docs_or_config", _workflow_profile), do: "low"
  defp risk_level("unknown", _workflow_profile), do: "medium"
  defp risk_level("behavioral", %WorkflowProfile{merge_mode: :automerge}), do: "medium"
  defp risk_level("behavioral", _workflow_profile), do: "high"
  defp risk_level("ui_affecting", _workflow_profile), do: "high"
  defp risk_level("deploy_sensitive", _workflow_profile), do: "high"
  defp risk_level(_change_type, _workflow_profile), do: "medium"

  defp reason(change_type, proof_class, approval_class) do
    "#{change_type} change; proof=#{proof_class}; approval=#{approval_class}"
  end
end
