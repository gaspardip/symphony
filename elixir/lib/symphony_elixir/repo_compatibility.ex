defmodule SymphonyElixir.RepoCompatibility do
  @moduledoc """
  Validates whether a checked-out repo meets Symphony's autonomous-compatible contract.
  """

  alias SymphonyElixir.{Config, RepoHarness, RunInspector, WorkflowProfile}

  @type check_status :: :passed | :failed | :warning
  @type check_result :: %{
          id: String.t(),
          required: boolean(),
          status: check_status(),
          summary: String.t(),
          details: String.t()
        }

  @spec report(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def report(workspace, opts \\ []) when is_binary(workspace) do
    inspection = RunInspector.inspect(workspace, opts)
    harness = inspection.harness

    checks = [
      git_checkout_check(inspection),
      harness_valid_check(inspection),
      deterministic_commands_check(harness),
      required_checks_check(harness),
      branch_base_setup_check(workspace, inspection, opts),
      behavioral_proof_check(harness),
      deploy_preview_check(harness),
      deploy_production_check(harness),
      acceptance_verifier_check(harness)
    ]

    failed_required =
      Enum.filter(checks, fn check -> check.required and check.status == :failed end)

    report = %{
      workspace: workspace,
      compatible: failed_required == [],
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: checks,
      failing_checks: Enum.map(failed_required, & &1.id),
      warnings:
        checks
        |> Enum.filter(&(&1.status == :warning))
        |> Enum.map(& &1.id),
      ui_proof: ui_proof_payload(harness)
    }

    {:ok, report}
  end

  @spec compatible?(Path.t(), keyword()) :: {:ok, boolean(), map()}
  def compatible?(workspace, opts \\ []) when is_binary(workspace) do
    {:ok, report} = report(workspace, opts)
    {:ok, report.compatible, report}
  end

  defp git_checkout_check(%RunInspector.Snapshot{checkout?: true, git?: true}) do
    pass("git_checkout", "Git checkout detected.", "The workspace contains a valid Git checkout.")
  end

  defp git_checkout_check(%RunInspector.Snapshot{checkout?: true, git?: false}) do
    fail("git_checkout", "Git checkout missing.", "The workspace exists but does not contain a `.git` checkout.")
  end

  defp git_checkout_check(%RunInspector.Snapshot{}) do
    fail("git_checkout", "Workspace missing.", "The workspace directory does not exist yet.")
  end

  defp harness_valid_check(%RunInspector.Snapshot{harness: %RepoHarness{}, harness_error: nil}) do
    pass("harness_valid", "Harness contract loaded.", "`.symphony/harness.yml` loaded successfully.")
  end

  defp harness_valid_check(%RunInspector.Snapshot{harness_error: nil}) do
    fail("harness_valid", "Harness contract missing.", "`.symphony/harness.yml` was not found.")
  end

  defp harness_valid_check(%RunInspector.Snapshot{harness_error: reason}) do
    fail("harness_valid", "Harness contract invalid.", "Harness load failed: #{inspect(reason)}")
  end

  defp deterministic_commands_check(nil) do
    fail("deterministic_commands", "Repo commands unavailable.", "Cannot validate commands without a valid harness.")
  end

  defp deterministic_commands_check(harness) do
    commands = [
      harness.preflight_command,
      harness.validation_command,
      harness.smoke_command,
      harness.post_merge_command,
      harness.artifacts_command
    ]

    if Enum.all?(commands, &(is_binary(&1) and String.trim(&1) != "")) do
      pass(
        "deterministic_commands",
        "Core repo commands are declared.",
        "Preflight, validation, smoke, post-merge, and artifacts commands are present in the harness."
      )
    else
      fail(
        "deterministic_commands",
        "Missing deterministic repo commands.",
        "All core harness commands must be declared for autonomous mode."
      )
    end
  end

  defp required_checks_check(nil) do
    fail("required_checks", "Required checks unavailable.", "Cannot validate publish checks without a valid harness.")
  end

  defp required_checks_check(harness) do
    checks = Map.get(harness, :publish_required_checks, []) || []

    if checks == [] do
      fail("required_checks", "Required checks missing.", "The harness must declare `pull_request.required_checks`.")
    else
      pass("required_checks", "Required checks declared.", "Publish is gated by: #{Enum.join(checks, ", ")}.")
    end
  end

  defp branch_base_setup_check(_workspace, %RunInspector.Snapshot{git?: false}, _opts) do
    fail("branch_base_setup", "Branch/base setup unavailable.", "A valid Git checkout is required to validate base-branch setup.")
  end

  defp branch_base_setup_check(_workspace, %RunInspector.Snapshot{harness: nil}, _opts) do
    fail("branch_base_setup", "Branch/base setup unavailable.", "A valid harness is required to validate base-branch setup.")
  end

  defp branch_base_setup_check(workspace, %RunInspector.Snapshot{harness: harness}, opts) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    base_branch = harness.base_branch

    exists? =
      case command_runner.(
             "git",
             ["rev-parse", "--verify", "--quiet", base_branch],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> true
        _ -> false
      end

    remote_exists? =
      case command_runner.(
             "git",
             ["rev-parse", "--verify", "--quiet", "origin/#{base_branch}"],
             cd: workspace,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> true
        _ -> false
      end

    cond do
      exists? or remote_exists? ->
        pass(
          "branch_base_setup",
          "Base branch is available.",
          "Base branch `#{base_branch}` exists locally or on origin for branch preparation and reset."
        )

      true ->
        fail(
          "branch_base_setup",
          "Base branch is not available.",
          "Base branch `#{base_branch}` does not exist locally or as `origin/#{base_branch}`."
        )
    end
  end

  defp behavioral_proof_check(nil) do
    fail("behavioral_proof", "Behavioral proof unavailable.", "Cannot validate proof requirements without a valid harness.")
  end

  defp behavioral_proof_check(harness) do
    proof = Map.get(harness, :behavioral_proof)

    cond do
      is_nil(proof) ->
        fail("behavioral_proof", "Behavioral proof missing.", "The harness must declare `verification.behavioral_proof`.")

      Map.get(proof, :required) != true ->
        fail("behavioral_proof", "Behavioral proof not required.", "Autonomous mode requires behavioral proof to be enabled.")

      proof_configured?(proof) ->
        pass("behavioral_proof", "Behavioral proof configured.", "Behavior-changing diffs will be gated by repo-owned proof.")

      true ->
        fail(
          "behavioral_proof",
          "Behavioral proof incomplete.",
          "Behavioral proof must declare test paths, source paths, or a proof artifact."
        )
    end
  end

  defp deploy_preview_check(nil) do
    if preview_deploy_required?() do
      fail("deploy_preview", "Preview deploy unavailable.", "Cannot validate preview deployment support without a valid harness.")
    else
      pass("deploy_preview", "Preview deploy not required.", "No autonomous preview deployment is configured for the active workflow profile.")
    end
  end

  defp deploy_preview_check(harness) do
    if preview_deploy_required?() do
      if is_binary(harness.deploy_preview_command) and String.trim(harness.deploy_preview_command) != "" do
        pass("deploy_preview", "Preview deploy configured.", "The harness declares a preview deploy command for autonomous deployment.")
      else
        fail("deploy_preview", "Preview deploy missing.", "The active workflow profile requires `deploy.preview.command` in the harness.")
      end
    else
      pass("deploy_preview", "Preview deploy not required.", "No autonomous preview deployment is configured for the active workflow profile.")
    end
  end

  defp deploy_production_check(nil) do
    if production_deploy_required?() do
      fail("deploy_production", "Production deploy unavailable.", "Cannot validate production deployment support without a valid harness.")
    else
      pass("deploy_production", "Production deploy not required.", "No autonomous production deployment is configured for the active workflow profile.")
    end
  end

  defp deploy_production_check(harness) do
    if production_deploy_required?() do
      if is_binary(harness.deploy_production_command) and String.trim(harness.deploy_production_command) != "" do
        pass("deploy_production", "Production deploy configured.", "The harness declares a production deploy command for autonomous deployment.")
      else
        fail("deploy_production", "Production deploy missing.", "The active workflow profile requires `deploy.production.command` in the harness.")
      end
    else
      pass("deploy_production", "Production deploy not required.", "No autonomous production deployment is configured for the active workflow profile.")
    end
  end

  defp acceptance_verifier_check(nil) do
    fail("acceptance_verifier", "Verifier compatibility unavailable.", "Cannot validate verifier compatibility without a valid harness.")
  end

  defp acceptance_verifier_check(harness) do
    if is_binary(harness.smoke_command) and String.trim(harness.smoke_command) != "" do
      pass(
        "acceptance_verifier",
        "Verifier-compatible repo contract present.",
        "Smoke verification is configured and issue acceptance can be evaluated against repo evidence."
      )
    else
      fail(
        "acceptance_verifier",
        "Verifier-compatible contract missing.",
        "The repo must expose a deterministic smoke command for acceptance verification."
      )
    end
  end

  defp ui_proof_payload(nil), do: %{configured: false, required: false, mode: nil}

  defp ui_proof_payload(harness) do
    proof = Map.get(harness, :ui_proof)

    %{
      configured: is_map(proof),
      required: is_map(proof) and Map.get(proof, :required, false),
      mode: if(is_map(proof), do: Map.get(proof, :mode), else: nil),
      source_paths: if(is_map(proof), do: Map.get(proof, :source_paths, []), else: []),
      test_paths: if(is_map(proof), do: Map.get(proof, :test_paths, []), else: []),
      artifact_paths: if(is_map(proof), do: Map.get(proof, :artifact_paths, []), else: []),
      required_checks: if(is_map(proof), do: Map.get(proof, :required_checks, []), else: [])
    }
  end

  defp proof_configured?(proof) do
    Map.get(proof, :source_paths, []) != [] and
      (Map.get(proof, :test_paths, []) != [] or is_binary(Map.get(proof, :artifact_path)))
  end

  defp preview_deploy_required? do
    WorkflowProfile.resolve("fully_autonomous", policy_pack: Config.policy_pack_name()).preview_deploy_mode == :after_merge
  end

  defp production_deploy_required? do
    WorkflowProfile.resolve("fully_autonomous", policy_pack: Config.policy_pack_name()).production_deploy_mode == :after_preview
  end

  defp pass(id, summary, details), do: %{id: id, required: true, status: :passed, summary: summary, details: details}
  defp fail(id, summary, details), do: %{id: id, required: true, status: :failed, summary: summary, details: details}
end
