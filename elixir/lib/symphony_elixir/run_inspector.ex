defmodule SymphonyElixir.RunInspector do
  @moduledoc """
  Inspects workspace state, PR status, and harness-based validation commands.
  """

  alias SymphonyElixir.RepoHarness

  defmodule Snapshot do
    @moduledoc false

    defstruct [
      :workspace,
      :checkout?,
      :git?,
      :origin_url,
      :branch,
      :head_sha,
      :status_text,
      :fingerprint,
      :pr_url,
      :pr_state,
      :review_decision,
      :check_statuses,
      :required_checks_state,
      :missing_required_checks,
      :failing_required_checks,
      :cancelled_required_checks,
      :pending_required_checks,
      :harness,
      :harness_error,
      dirty?: false,
      changed_files: 0
    ]
  end

  defmodule CommandResult do
    @moduledoc false

    defstruct [:status, :command, :output]
  end

  @type snapshot :: %Snapshot{}
  @type command_result :: %CommandResult{}
  @type command_runner :: (String.t(), [String.t()], keyword() -> {binary(), integer()})

  @spec inspect(Path.t(), keyword()) :: snapshot()
  def inspect(workspace, opts \\ []) when is_binary(workspace) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    shell_runner = Keyword.get(opts, :shell_runner, &default_shell_runner/3)

    checkout? = File.dir?(workspace)
    git? = checkout? and File.exists?(Path.join(workspace, ".git"))
    {harness, harness_error} = harness_for_workspace(workspace)

    git_data =
      if git? do
        %{
          origin_url: git_output(command_runner, workspace, ["config", "--get", "remote.origin.url"]),
          branch: git_output(command_runner, workspace, ["rev-parse", "--abbrev-ref", "HEAD"]),
          head_sha: git_output(command_runner, workspace, ["rev-parse", "HEAD"]),
          status_text: git_output(command_runner, workspace, ["status", "--porcelain"])
        }
      else
        %{origin_url: nil, branch: nil, head_sha: nil, status_text: nil}
      end

    pr_data =
      if git? do
        pr_details(command_runner, shell_runner, workspace)
      else
        %{pr_url: nil, pr_state: nil, review_decision: nil, check_statuses: []}
      end

    check_rollup = required_checks_rollup(harness, pr_data.check_statuses)

    status_text = filter_runtime_status_entries(git_data.status_text)

    %Snapshot{
      workspace: workspace,
      checkout?: checkout?,
      git?: git?,
      origin_url: git_data.origin_url,
      branch: git_data.branch,
      head_sha: git_data.head_sha,
      status_text: status_text,
      fingerprint: fingerprint(git_data.head_sha, status_text, pr_data.pr_url),
      pr_url: pr_data.pr_url,
      pr_state: pr_data.pr_state,
      review_decision: pr_data.review_decision,
      check_statuses: pr_data.check_statuses,
      required_checks_state: check_rollup.state,
      missing_required_checks: check_rollup.missing,
      failing_required_checks: check_rollup.failed,
      cancelled_required_checks: check_rollup.cancelled,
      pending_required_checks: check_rollup.pending,
      harness: harness,
      harness_error: harness_error,
      dirty?: status_dirty?(status_text),
      changed_files: changed_file_count(status_text)
    }
  end

  @spec code_changed?(snapshot(), snapshot()) :: boolean()
  def code_changed?(%Snapshot{fingerprint: before_fp}, %Snapshot{fingerprint: after_fp}) do
    before_fp != after_fp
  end

  @spec required_checks_passed?(snapshot()) :: boolean()
  def required_checks_passed?(%Snapshot{harness: nil}), do: true

  def required_checks_passed?(%Snapshot{} = snapshot) do
    required_checks_rollup(snapshot).state == :passed
  end

  @spec approved_for_merge?(snapshot()) :: boolean()
  def approved_for_merge?(%Snapshot{review_decision: review_decision}) do
    case normalize_review_decision(review_decision) do
      nil -> true
      "" -> true
      "approved" -> true
      "changes_requested" -> false
      "review_required" -> false
      _other -> false
    end
  end

  @spec ready_for_merge?(snapshot()) :: boolean()
  def ready_for_merge?(%Snapshot{} = snapshot) do
    not is_nil(snapshot.pr_url) and pr_open_for_merge?(snapshot) and approved_for_merge?(snapshot) and required_checks_passed?(snapshot)
  end

  @spec required_checks_rollup(snapshot()) :: %{
          state: :passed | :missing | :pending | :failed | :cancelled,
          required: [String.t()],
          missing: [String.t()],
          pending: [String.t()],
          failed: [String.t()],
          cancelled: [String.t()]
        }
  def required_checks_rollup(%Snapshot{harness: harness, check_statuses: check_statuses}) do
    required_checks_rollup(harness, check_statuses)
  end

  @spec required_checks_rollup(map() | nil, list()) :: %{
          state: :passed | :missing | :pending | :failed | :cancelled,
          required: [String.t()],
          missing: [String.t()],
          pending: [String.t()],
          failed: [String.t()],
          cancelled: [String.t()]
        }
  def required_checks_rollup(nil, _check_statuses) do
    %{state: :passed, required: [], missing: [], pending: [], failed: [], cancelled: []}
  end

  def required_checks_rollup(harness, check_statuses) when is_map(harness) and is_list(check_statuses) do
    required =
      case Map.get(harness, :publish_required_checks, []) do
        [] -> Map.get(harness, :required_checks, [])
        checks -> checks
      end

    required_checks_rollup(required, check_statuses)
  end

  @spec required_checks_rollup([String.t()], list()) :: %{
          state: :passed | :missing | :pending | :failed | :cancelled,
          required: [String.t()],
          missing: [String.t()],
          pending: [String.t()],
          failed: [String.t()],
          cancelled: [String.t()]
        }
  def required_checks_rollup(required, check_statuses)
      when is_list(required) and is_list(check_statuses) do
    required = Enum.reject(required, &(&1 in [nil, ""]))

    states =
      Enum.map(required, fn required_check ->
        matching_entries = Enum.filter(check_statuses, &matches_required_check?(&1, required_check))

        {required_check, aggregate_required_check_state(matching_entries)}
      end)

    missing = named_checks_in_state(states, :missing)
    pending = named_checks_in_state(states, :pending)
    failed = named_checks_in_state(states, :failed)
    cancelled = named_checks_in_state(states, :cancelled)

    state =
      cond do
        failed != [] -> :failed
        cancelled != [] -> :cancelled
        missing != [] -> :missing
        pending != [] -> :pending
        true -> :passed
      end

    %{
      state: state,
      required: required,
      missing: missing,
      pending: pending,
      failed: failed,
      cancelled: cancelled
    }
  end

  @spec run_preflight(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_preflight(workspace, harness, opts \\ []) do
    run_harness_command(workspace, harness && harness.preflight_command, opts)
  end

  @spec run_validation(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_validation(workspace, harness, opts \\ []) do
    run_harness_command(workspace, harness && harness.validation_command, opts)
  end

  @spec run_smoke(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_smoke(workspace, harness, opts \\ []) do
    run_harness_command(workspace, harness && harness.smoke_command, opts)
  end

  @spec run_post_merge(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_post_merge(workspace, harness, opts \\ []) do
    run_harness_command(workspace, harness && harness.post_merge_command, opts)
  end

  @spec run_deploy_preview(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_deploy_preview(workspace, harness, opts \\ []) do
    run_harness_command(workspace, harness && harness.deploy_preview_command, opts)
  end

  @spec run_deploy_production(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_deploy_production(workspace, harness, opts \\ []) do
    run_harness_command(workspace, harness && harness.deploy_production_command, opts)
  end

  @spec run_post_deploy_verify(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_post_deploy_verify(workspace, harness, opts \\ []) do
    run_harness_command(workspace, harness && harness.post_deploy_verify_command, opts)
  end

  @spec run_deploy_rollback(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_deploy_rollback(workspace, harness, opts \\ []) do
    run_harness_command(workspace, harness && harness.deploy_rollback_command, opts)
  end

  @spec run_shell_command(Path.t(), String.t() | nil, keyword()) :: command_result()
  def run_shell_command(workspace, command, opts \\ []) do
    run_harness_command(workspace, command, opts)
  end

  @spec changed_paths(Path.t(), keyword()) :: [String.t()]
  def changed_paths(workspace, opts \\ []) when is_binary(workspace) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case command_runner.("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> to_string()
        |> String.split(~r/\r?\n/, trim: true)
        |> Enum.map(&status_path/1)
        |> Enum.reject(&runtime_artifact_path?/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @spec diff_summary(Path.t(), keyword()) :: String.t() | nil
  def diff_summary(workspace, opts \\ []) when is_binary(workspace) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case command_runner.("git", ["diff", "--stat", "--no-ext-diff", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> to_string()
        |> String.trim()
        |> blank_to_nil()

      _ ->
        nil
    end
  end

  defp run_harness_command(_workspace, nil, _opts) do
    %CommandResult{status: :unavailable, command: nil, output: "No harness command configured."}
  end

  defp run_harness_command(workspace, command, opts) when is_binary(command) do
    shell_runner = Keyword.get(opts, :shell_runner, &default_shell_runner/3)
    {output, status} = shell_runner.(workspace, command, stderr_to_stdout: true)

    %CommandResult{
      status: if(status == 0, do: :passed, else: :failed),
      command: command,
      output: output
    }
  rescue
    error ->
      %CommandResult{
        status: :unavailable,
        command: command,
        output: Exception.message(error)
      }
  end

  defp harness_for_workspace(workspace) do
    case RepoHarness.load(workspace) do
      {:ok, harness} -> {harness, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  defp git_output(command_runner, workspace, args) do
    case command_runner.("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> to_string()
        |> String.trim()
        |> blank_to_nil()

      _ ->
        nil
    end
  end

  defp pr_details(command_runner, shell_runner, workspace) do
    with {output, 0} <-
           command_runner.(
             "gh",
             ["pr", "view", "--json", "url,state,reviewDecision,statusCheckRollup"],
             cd: workspace,
             stderr_to_stdout: true
           ),
         {:ok, payload} <- Jason.decode(output) do
      %{
        pr_url: blank_to_nil(payload["url"]),
        pr_state: blank_to_nil(payload["state"]),
        review_decision: blank_to_nil(payload["reviewDecision"]),
        check_statuses: normalize_checks(payload["statusCheckRollup"])
      }
    else
      _ ->
        fallback_pr_details(shell_runner, workspace)
    end
  end

  defp fallback_pr_details(shell_runner, workspace) do
    {output, status} =
      shell_runner.(
        workspace,
        "git config --get branch.$(git rev-parse --abbrev-ref HEAD).symphony-pr-url",
        stderr_to_stdout: true
      )

    if status == 0 do
      %{pr_url: blank_to_nil(output), pr_state: nil, review_decision: nil, check_statuses: []}
    else
      %{pr_url: nil, pr_state: nil, review_decision: nil, check_statuses: []}
    end
  end

  defp normalize_checks(checks) when is_list(checks) do
    Enum.map(checks, fn
      %{"name" => name, "status" => status, "conclusion" => conclusion} = payload ->
        %{
          name: blank_to_nil(name),
          workflow_name: blank_to_nil(payload["workflowName"]),
          status: blank_to_nil(status),
          conclusion: blank_to_nil(conclusion)
        }

      _ ->
        %{}
    end)
  end

  defp normalize_checks(_checks), do: []

  defp matches_required_check?(entry, required_check) when is_map(entry) and is_binary(required_check) do
    Map.get(entry, :name) == required_check or Map.get(entry, :workflow_name) == required_check
  end

  defp matches_required_check?(_entry, _required_check), do: false

  defp status_path(line) when is_binary(line) do
    line
    |> String.slice(3..-1//1)
    |> String.split(" -> ")
    |> List.last()
    |> blank_to_nil()
  end

  defp filter_runtime_status_entries(nil), do: nil

  defp filter_runtime_status_entries(status_text) do
    status_text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reject(fn line ->
      line
      |> status_path()
      |> runtime_artifact_path?()
    end)
    |> Enum.join("\n")
    |> blank_to_nil()
  end

  defp normalize_check_conclusion(nil), do: nil

  defp normalize_check_conclusion(conclusion) do
    conclusion
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_review_decision(nil), do: nil

  defp normalize_review_decision(review_decision) do
    review_decision
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_check_status(nil), do: nil

  defp normalize_check_status(status) do
    status
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp aggregate_required_check_state([]), do: :missing

  defp aggregate_required_check_state(check_entries) do
    states = Enum.map(check_entries, &classify_check_entry/1)

    cond do
      :pending in states -> :pending
      :success in states -> :success
      :cancelled in states -> :cancelled
      :failed in states -> :failed
    end
  end

  defp classify_check_entry(entry) do
    case normalize_check_conclusion(Map.get(entry, :conclusion)) do
      "success" -> :success
      "cancelled" -> :cancelled
      "canceled" -> :cancelled
      "failure" -> :failed
      "timed_out" -> :failed
      "action_required" -> :failed
      "startup_failure" -> :failed
      "stale" -> :failed
      "skipped" -> :failed
      "neutral" -> :failed
      nil -> classify_pending_status(entry)
      "" -> classify_pending_status(entry)
      _other -> classify_pending_status(entry)
    end
  end

  defp classify_pending_status(entry) do
    case normalize_check_status(Map.get(entry, :status)) do
      "queued" -> :pending
      "in_progress" -> :pending
      "pending" -> :pending
      "requested" -> :pending
      "waiting" -> :pending
      "expected" -> :pending
      "completed" -> :pending
      _ -> :pending
    end
  end

  defp named_checks_in_state(states, target_state) do
    states
    |> Enum.filter(fn {_required_check, state} -> state == target_state end)
    |> Enum.map(fn {required_check, _state} -> required_check end)
  end

  defp pr_open_for_merge?(%Snapshot{pr_state: nil}), do: true

  defp pr_open_for_merge?(%Snapshot{pr_state: pr_state}) do
    case pr_state |> to_string() |> String.trim() |> String.upcase() do
      "" -> true
      "OPEN" -> true
      _ -> false
    end
  end

  defp fingerprint(head_sha, status_text, pr_url) do
    :erlang.phash2({head_sha || "", status_text || "", pr_url || ""})
  end

  defp status_dirty?(nil), do: false
  defp status_dirty?(status_text), do: String.trim(status_text) != ""

  defp changed_file_count(nil), do: 0

  defp changed_file_count(status_text) do
    status_text
    |> String.split("\n", trim: true)
    |> length()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp default_shell_runner(workspace, command, opts) do
    System.cmd("sh", ["-lc", command], Keyword.merge([cd: workspace], opts))
  end

  defp runtime_artifact_path?(nil), do: false

  defp runtime_artifact_path?(path) do
    normalized = path |> to_string() |> String.trim()
    normalized == ".symphony" or String.starts_with?(normalized, ".symphony/")
  end
end
