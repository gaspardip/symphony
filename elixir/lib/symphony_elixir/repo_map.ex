defmodule SymphonyElixir.RepoMap do
  @moduledoc """
  Builds a compact static repo map from the validated harness so agent turns do not
  need to rediscover stable project facts.
  """

  alias SymphonyElixir.RepoHarness

  defstruct [
    :platform,
    :base_branch,
    :project_ref,
    :runtime_note,
    :behavioral_proof,
    :ui_proof
  ]

  @type proof_summary :: %{
          required: boolean(),
          mode: String.t() | nil,
          source_paths: [String.t()],
          test_paths: [String.t()],
          artifact_paths: [String.t()]
        }

  @type t :: %__MODULE__{
          platform: String.t() | nil,
          base_branch: String.t() | nil,
          project_ref: String.t() | nil,
          runtime_note: String.t() | nil,
          behavioral_proof: proof_summary | nil,
          ui_proof: proof_summary | nil
        }

  @spec from_harness(RepoHarness.t() | map() | nil) :: t() | nil
  def from_harness(nil), do: nil

  def from_harness(%RepoHarness{} = harness) do
    build_repo_map(harness)
  end

  def from_harness(harness) when is_map(harness) do
    build_repo_map(harness)
  end

  @spec prompt_block(t() | nil) :: String.t() | nil
  def prompt_block(nil), do: nil

  def prompt_block(%__MODULE__{} = map) do
    lines =
      [
        "Repo map:",
        maybe_line("Platform", map.platform),
        maybe_line("Project reference", map.project_ref),
        maybe_line("Base branch", map.base_branch),
        maybe_line("Runtime note", map.runtime_note),
        proof_line("Behavioral proof", map.behavioral_proof),
        proof_line("UI proof", map.ui_proof)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(lines, "\n")
  end

  defp build_repo_map(harness) do
    project = Map.get(harness, :project, %{}) || %{}
    runtime = Map.get(harness, :runtime, %{}) || %{}

    %__MODULE__{
      platform: normalize_optional_string(Map.get(project, :type) || Map.get(project, "type")),
      base_branch: normalize_optional_string(Map.get(harness, :base_branch) || Map.get(harness, "base_branch")),
      project_ref: project_ref(project),
      runtime_note: runtime_note(runtime),
      behavioral_proof: proof_summary(Map.get(harness, :behavioral_proof) || Map.get(harness, "behavioral_proof")),
      ui_proof: proof_summary(Map.get(harness, :ui_proof) || Map.get(harness, "ui_proof"))
    }
  end

  defp project_ref(project) do
    [Map.get(project, :xcodeproj) || Map.get(project, "xcodeproj"), Map.get(project, :scheme) || Map.get(project, "scheme")]
    |> Enum.reject(&is_nil_or_blank?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " | ")
    end
  end

  defp runtime_note(runtime) do
    destination = Map.get(runtime, :simulator_destination) || Map.get(runtime, "simulator_destination")
    developer_dir = Map.get(runtime, :developer_dir) || Map.get(runtime, "developer_dir")

    [normalize_optional_string(destination), normalize_optional_string(developer_dir)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      [dest] -> "Use declared runtime target #{dest}."
      [dest, dev] -> "Use declared runtime target #{dest}; developer dir via #{dev}."
    end
  end

  defp proof_summary(nil), do: nil

  defp proof_summary(proof) when is_map(proof) do
    %{
      required: SymphonyElixir.Util.truthy?(Map.get(proof, :required) || Map.get(proof, "required")),
      mode: normalize_optional_string(Map.get(proof, :mode) || Map.get(proof, "mode")),
      source_paths: normalize_string_list(Map.get(proof, :source_paths) || Map.get(proof, "source_paths")),
      test_paths: normalize_string_list(Map.get(proof, :test_paths) || Map.get(proof, "test_paths")),
      artifact_paths: normalize_string_list(Map.get(proof, :artifact_paths) || Map.get(proof, "artifact_paths") || [Map.get(proof, :artifact_path) || Map.get(proof, "artifact_path")])
    }
  end

  defp proof_summary(_proof), do: nil

  defp proof_line(_label, nil), do: nil

  defp proof_line(label, proof) do
    requirement = if proof.required, do: "required", else: "optional"
    mode = proof.mode || "unspecified"
    source_paths = maybe_paths("source", proof.source_paths)
    test_paths = maybe_paths("tests", proof.test_paths)
    artifact_paths = maybe_paths("artifacts", proof.artifact_paths)

    [source_paths, test_paths, artifact_paths]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "#{label}: #{requirement}; mode=#{mode}."
      details -> "#{label}: #{requirement}; mode=#{mode}; #{Enum.join(details, "; ")}."
    end
  end

  defp maybe_paths(_label, []), do: nil
  defp maybe_paths(label, paths), do: "#{label}=#{Enum.join(Enum.take(paths, 4), ", ")}"

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(label, value), do: "#{label}: #{value}"

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_value), do: []

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp is_nil_or_blank?(value), do: is_nil(normalize_optional_string(value))
end
