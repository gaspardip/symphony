defmodule SymphonyElixir.RunInspector do
  @moduledoc """
  Inspects workspace state, PR status, and harness-based validation commands.
  """

  alias SymphonyElixir.{Config, ExecutionBoundary, RepoHarness, RunIdentity, RunLedger, RunStateStore, Util, Workspace}

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

    defstruct [:status, :command, :output, :error, :exit_code, :gate_id, :gate_kind, :started_at, :finished_at, :duration_us, :environment]
  end

  @type snapshot :: %Snapshot{}
  @type command_result :: %CommandResult{}
  @type command_runner :: (String.t(), [String.t()], keyword() -> {binary(), integer()})

  @spec inspect(Path.t(), keyword()) :: snapshot()
  def inspect(workspace, opts \\ []) when is_binary(workspace) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    shell_runner = Keyword.get(opts, :shell_runner, &default_shell_runner/3)
    include_pr_details? = Keyword.get(opts, :include_pr_details, true)

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
      if git? and include_pr_details? do
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

  @doc "Reads a single persisted run by one exact selector, without probing Git, a tracker or a provider."
  @spec traceability(map()) :: {:ok, map()} | {:error, map()}
  def traceability(selector) do
    with {:ok, key, value} <- traceability_selector(selector),
         {:ok, ledger_path} <- traceability_read(RunLedger.ledger_file_path_checked(), :ledger_unavailable),
         root = Path.expand(Config.workspace_root()),
         {:ok, rows, ledger_digest} <- traceability_entries(ledger_path),
         {:ok, identities} <- traceability_identities(rows),
         {:ok, candidates} <- traceability_candidates(identities, rows, key, value),
         {:ok, readings} <- traceability_readings(candidates, root, ledger_path, rows),
         :ok <- traceability_unchanged(readings, root, ledger_path, ledger_digest),
         {:ok, reading} <- traceability_unique(readings, key, value) do
      {:ok, Map.put(reading, :ledger_sha256, ledger_digest)}
    end
  end

  defp traceability_selector(selector) when is_map(selector) and map_size(selector) == 1 do
    case Map.to_list(selector) do
      [{key, value}] when key in ["issue", "run", "workspace", "pr"] and is_binary(value) and value != "" ->
        cond do
          key == "workspace" and (Path.type(value) != :absolute or Path.expand(value) != value) -> traceability_error(:invalid_selector, :workspace_must_be_absolute)
          key == "pr" and not traceability_pr?(value) -> traceability_error(:invalid_selector, :invalid_pr_url)
          true -> {:ok, key, value}
        end

      _ ->
        traceability_error(:invalid_selector, :one_nonempty_selector_required)
    end
  end

  defp traceability_selector(_), do: traceability_error(:invalid_selector, :one_nonempty_selector_required)

  defp traceability_entries(path) do
    case RunLedger.CheckedStorage.entries_checked(path) do
      {:ok, rows, digest} -> {:ok, rows, digest}
      {:error, reason} -> traceability_error(:ledger_unavailable, reason)
    end
  end

  defp traceability_identities(rows) do
    rows
    |> Enum.filter(&(&1["event_type"] in ["run.identity.created", "run.identity.adopted"]))
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, identities} ->
      metadata = row["metadata"]

      if is_map(metadata) and Enum.all?([row["event_id"], row["issue_id"], row["issue_identifier"], metadata["run_id"], metadata["workspace"], metadata["intent_event_id"]], &traceability_present?/1) do
        identity = %{
          run_id: metadata["run_id"],
          issue_id: row["issue_id"],
          issue_identifier: row["issue_identifier"],
          workspace: metadata["workspace"],
          event_id: row["event_id"],
          intent_event_id: metadata["intent_event_id"]
        }

        {:cont, {:ok, [identity | identities]}}
      else
        {:halt, traceability_error(:identity_incomplete, :invalid_identity_confirmation)}
      end
    end)
  end

  defp traceability_candidates(identities, rows, key, value) do
    candidates = Enum.filter(identities, &traceability_matches?(&1, key, value))

    cond do
      candidates != [] -> {:ok, candidates}
      Enum.any?(rows, &traceability_unbound_match?(&1, key, value)) -> traceability_error(:identity_incomplete, :confirmed_identity_missing)
      true -> traceability_error(:not_found, :no_matching_identity)
    end
  end

  defp traceability_matches?(identity, "issue", value), do: value in [identity.issue_id, identity.issue_identifier]
  defp traceability_matches?(identity, "run", value), do: identity.run_id == value
  defp traceability_matches?(identity, "workspace", value), do: identity.workspace == value
  defp traceability_matches?(_identity, "pr", _value), do: true

  defp traceability_unbound_match?(row, "issue", value), do: value in [row["issue_id"], row["issue_identifier"]]

  defp traceability_unbound_match?(row, key, value) do
    metadata_key = %{"run" => "run_id", "workspace" => "workspace", "pr" => "pr_url"}[key]
    is_map(row["metadata"]) and row["metadata"][metadata_key] == value
  end

  defp traceability_readings(identities, root, ledger_path, rows) do
    Enum.reduce_while(identities, {:ok, []}, fn identity, {:ok, readings} ->
      result = RunStateStore.with_workspace_lock(identity.workspace, fn -> traceability_reading(identity, root, ledger_path, rows) end)

      case result do
        {:ok, reading} -> {:cont, {:ok, [reading | readings]}}
        {:error, reason} -> {:halt, {:error, Map.put(reason, :run_id, identity.run_id)}}
        :aborted -> {:halt, traceability_error(:snapshot_unavailable, :local_lock_aborted)}
      end
    end)
  end

  defp traceability_reading(identity, root, ledger_path, rows) do
    with :ok <- traceability_workspace(identity, root),
         {:ok, bytes} <- traceability_read(File.read(RunStateStore.state_path(identity.workspace)), :snapshot_unavailable),
         {:ok, raw} <- traceability_raw(bytes),
         true <-
           (raw["run_id"] == identity.run_id and raw["run_identity_event_id"] == identity.event_id and raw["run_identity_ledger_path"] == ledger_path) or
             traceability_error(:identity_conflict, :snapshot_binding_changed),
         :ok <- traceability_check(RunIdentity.verify(identity.workspace, identity.run_id, identity.issue_id, identity.issue_identifier), :identity_incomplete),
         {:ok, dispatches} <- traceability_dispatches(identity, rows),
         {:ok, last_event} <- traceability_last_event(raw, identity, rows) do
      {:ok, %{identity: identity, state: raw, dispatches: dispatches, last_event: last_event, snapshot_sha256: traceability_digest(bytes)}}
    end
  end

  defp traceability_raw(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = raw} ->
        with :ok <- traceability_check(RunIdentity.validate_snapshot(raw), :identity_incomplete),
             true <- not Map.has_key?(raw, "audit_pending") or traceability_error(:snapshot_incomplete, :audit_pending),
             true <- traceability_present?(raw["stage"]) or traceability_error(:snapshot_incomplete, :stage_missing),
             :ok <- traceability_result_shape(raw),
             do: {:ok, raw}

      {:ok, _} ->
        traceability_error(:snapshot_incomplete, :invalid_state)

      {:error, reason} ->
        traceability_error(:snapshot_unavailable, reason)
    end
  end

  defp traceability_result_shape(raw) do
    text_fields = ~w(pr_url last_rule_id last_failure_class next_human_action)
    stop = raw["stop_reason"]
    valid_stop = is_nil(stop) or (is_map(stop) and Enum.all?(Map.take(stop, ~w(code rule_id failure_class summary human_action)), fn {_key, value} -> is_nil(value) or is_binary(value) end))

    stopped_cause = raw["stage"] != "blocked" or (is_map(stop) and traceability_present?(stop["code"]))

    if valid_stop and stopped_cause and Enum.all?(text_fields, &(is_nil(raw[&1]) or is_binary(raw[&1]))) and
         (is_nil(raw["pr_url"]) or traceability_pr?(raw["pr_url"])),
       do: :ok,
       else: traceability_error(:snapshot_incomplete, :invalid_result_shape)
  end

  defp traceability_pr?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} when scheme in ["http", "https"] and is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp traceability_pr?(_), do: false

  defp traceability_workspace(identity, root) do
    expected = Path.expand(Workspace.path_for_issue(identity.issue_identifier))

    if identity.workspace == expected and String.starts_with?(expected, root <> "/") do
      path = RunStateStore.state_path(expected)
      parts = path |> Path.relative_to(root) |> Path.split()
      paths = [root | Enum.scan(parts, root, &Path.join(&2, &1))]

      Enum.reduce_while(paths, :ok, fn current, :ok ->
        expected_type = if current == path, do: :regular, else: :directory

        case File.lstat(current) do
          {:ok, %{type: ^expected_type}} -> {:cont, :ok}
          {:ok, _} -> {:halt, traceability_error(:workspace_unavailable, :unexpected_path_type)}
          {:error, reason} -> {:halt, traceability_error(:workspace_unavailable, reason)}
        end
      end)
    else
      traceability_error(:source_changed, :workspace_root_or_identity_path_changed)
    end
  end

  defp traceability_dispatches(identity, rows) do
    events =
      Enum.filter(rows, fn row ->
        is_map(row["metadata"]) and row["metadata"]["run_id"] == identity.run_id and row["event_type"] in ["dispatch.requested", "dispatch.started", "dispatch.finished"]
      end)

    events
    |> Enum.group_by(& &1["metadata"]["dispatch_id"])
    |> Enum.reduce_while({:ok, []}, fn {id, group}, {:ok, dispatches} ->
      requested = Enum.filter(group, &(&1["event_type"] == "dispatch.requested"))
      started = Enum.filter(group, &(&1["event_type"] == "dispatch.started"))
      finished = Enum.filter(group, &(&1["event_type"] == "dispatch.finished"))

      case {requested, started, finished} do
        {[request], [authorization], finish} when length(finish) <= 1 ->
          custody = Map.take(authorization["metadata"], ~w(owner epoch))

          valid =
            traceability_present?(id) and request["metadata"] == authorization["metadata"] and
              group == [request, authorization | finish] and
              traceability_present?(custody["owner"]) and is_integer(custody["epoch"]) and custody["epoch"] > 0 and
              Enum.all?(group, &(traceability_event_identity?(&1, identity) and traceability_event_shape?(&1))) and
              Enum.all?(finish, &(&1["metadata"]["authorization_event_id"] == authorization["event_id"] and Map.take(&1["metadata"], ~w(owner epoch)) == custody))

          if valid do
            {:cont, {:ok, [%{dispatch_id: id, requested: request, authorized: authorization, finished: List.first(finish)} | dispatches]}}
          else
            {:halt, traceability_error(:dispatch_incomplete, :dispatch_reference_mismatch)}
          end

        _ ->
          {:halt, traceability_error(:dispatch_incomplete, :dispatch_chain_incomplete_or_ambiguous)}
      end
    end)
    |> case do
      {:ok, []} -> traceability_error(:dispatch_incomplete, :dispatch_authorization_missing)
      result -> result
    end
  end

  defp traceability_event_shape?(event) do
    traceability_present?(event["event_id"]) and traceability_present?(event["event_type"]) and
      Enum.all?(Map.take(event, ~w(at stage actor_type actor_id)), fn {_key, value} -> is_nil(value) or is_binary(value) end)
  end

  defp traceability_event_identity?(row, identity) do
    row["issue_id"] == identity.issue_id and row["issue_identifier"] == identity.issue_identifier and
      case Map.fetch(row["metadata"], "workspace_digest") do
        {:ok, digest} -> digest == traceability_digest(identity.workspace)
        :error -> row["metadata"]["workspace"] == identity.workspace
      end
  end

  defp traceability_last_event(raw, identity, rows) do
    confirmation = Enum.find(rows, &(&1["event_id"] == identity.event_id))
    latest_id = traceability_latest_stage_event_id(identity, rows)

    case raw["last_ledger_event_id"] do
      nil ->
        cond do
          confirmation["stage"] != raw["stage"] or not is_nil(latest_id) ->
            traceability_error(:snapshot_incomplete, :last_ledger_reference_missing)

          not Map.has_key?(confirmation["metadata"], "inherited_stage_event_id") ->
            traceability_error(:snapshot_incomplete, :last_ledger_witness_missing)

          is_nil(confirmation["metadata"]["inherited_stage_event_id"]) ->
            {:ok, nil}

          true ->
            traceability_error(:snapshot_incomplete, :last_ledger_reference_missing)
        end

      id when is_binary(id) and id != "" ->
        case Enum.find(rows, &(&1["event_id"] == id)) do
          %{"issue_id" => issue_id, "issue_identifier" => identifier} = event when issue_id == identity.issue_id and identifier == identity.issue_identifier ->
            if traceability_event_shape?(event) and event["event_type"] == "stage.transition" and event["stage"] == raw["stage"] and
                 traceability_stage_witness?(event, raw, identity, confirmation, latest_id),
               do: {:ok, event},
               else: traceability_error(:snapshot_incomplete, :last_ledger_material_mismatch)

          _ ->
            traceability_error(:snapshot_incomplete, :last_ledger_reference_missing_or_mismatched)
        end

      _ ->
        traceability_error(:snapshot_incomplete, :invalid_last_ledger_reference)
    end
  end

  defp traceability_stage_witness?(%{"metadata" => %{} = metadata} = event, raw, identity, confirmation, latest_id) do
    execution = metadata["execution"]

    expected = %{
      "run_id" => identity.run_id,
      "run_identity_event_id" => identity.event_id,
      "run_identity_ledger_path" => raw["run_identity_ledger_path"],
      "workspace" => identity.workspace
    }

    if is_nil(execution) or (is_map(execution) and execution["run_id"] == identity.run_id) do
      case Map.fetch(metadata, "run_binding") do
        {:ok, binding} ->
          traceability_stage_binding?(binding, expected) and latest_id == event["event_id"]

        :error when is_map(execution) ->
          latest_id == event["event_id"]

        :error ->
          is_nil(latest_id) and confirmation["event_type"] == "run.identity.adopted" and
            confirmation["stage"] == event["stage"] and
            Map.fetch(confirmation["metadata"], "inherited_stage_event_id") == {:ok, event["event_id"]}
      end
    else
      false
    end
  end

  defp traceability_stage_witness?(_event, _raw, _identity, _confirmation, _latest_id), do: false

  defp traceability_stage_binding?(%{} = binding, expected) do
    case Map.fetch(binding, "workspace_digest") do
      {:ok, _digest} ->
        expected =
          expected
          |> Map.put("workspace_digest", traceability_digest(expected["workspace"]))
          |> Map.put("workspace", SymphonyElixir.SecretRedactor.redact(expected["workspace"]))

        binding == expected

      :error ->
        binding == expected
    end
  end

  defp traceability_stage_binding?(_binding, _expected), do: false

  defp traceability_latest_stage_event_id(identity, rows) do
    Enum.reduce(rows, nil, fn row, latest_id ->
      case row do
        %{"event_type" => "stage.transition", "issue_id" => issue_id, "issue_identifier" => identifier, "metadata" => %{} = metadata}
        when issue_id == identity.issue_id and identifier == identity.issue_identifier ->
          binding = metadata["run_binding"]
          execution = metadata["execution"]
          if (is_map(binding) and binding["run_id"] == identity.run_id) or (is_map(execution) and execution["run_id"] == identity.run_id), do: row["event_id"], else: latest_id

        _ ->
          latest_id
      end
    end)
  end

  defp traceability_unique(readings, key, value) do
    matches = if key == "pr", do: Enum.filter(readings, &(&1.state["pr_url"] == value)), else: readings

    case matches do
      [reading] -> {:ok, reading}
      [] -> traceability_error(:not_found, :no_matching_pr)
      _ -> traceability_error(:ambiguous, :multiple_matching_runs)
    end
  end

  defp traceability_unchanged(readings, root, ledger_path, ledger_digest) do
    with true <- Path.expand(Config.workspace_root()) == root or traceability_error(:source_changed, :workspace_root_changed),
         {:ok, current_path} <- traceability_read(RunLedger.ledger_file_path_checked(), :ledger_unavailable),
         true <- current_path == ledger_path or traceability_error(:source_changed, :ledger_path_changed),
         :ok <- traceability_snapshots_unchanged(readings, root),
         {:ok, _rows, current_digest} <- traceability_entries(ledger_path),
         true <- current_digest == ledger_digest or traceability_error(:source_changed, :ledger_changed),
         do: :ok
  end

  defp traceability_snapshots_unchanged(readings, root) do
    Enum.reduce_while(readings, :ok, fn reading, :ok ->
      result =
        RunStateStore.with_workspace_lock(reading.identity.workspace, fn ->
          with :ok <- traceability_workspace(reading.identity, root),
               {:ok, bytes} <- traceability_read(File.read(RunStateStore.state_path(reading.identity.workspace)), :snapshot_unavailable),
               true <- traceability_digest(bytes) == reading.snapshot_sha256 or traceability_error(:source_changed, :snapshot_changed),
               do: :ok
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        :aborted -> {:halt, traceability_error(:snapshot_unavailable, :local_lock_aborted)}
      end
    end)
  end

  defp traceability_read({:ok, value}, _code), do: {:ok, value}
  defp traceability_read({:error, reason}, code), do: traceability_error(code, reason)
  defp traceability_check(:ok, _code), do: :ok
  defp traceability_check({:error, reason}, code), do: traceability_error(code, reason)
  defp traceability_present?(value), do: is_binary(value) and value != ""
  defp traceability_digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp traceability_error(code, cause), do: {:error, %{code: code, cause: cause}}

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
    run_gate_command(workspace, harness && harness.preflight_command, :preflight, opts)
  end

  @spec run_validation(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_validation(workspace, harness, opts \\ []) do
    run_gate_command(workspace, harness && harness.validation_command, :validation, opts)
  end

  @spec run_artifacts(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_artifacts(workspace, harness, opts \\ []) do
    run_gate_command(workspace, harness && harness.artifacts_command, :artifacts, opts)
  end

  @spec run_smoke(Path.t(), RepoHarness.t() | nil, keyword()) :: command_result()
  def run_smoke(workspace, harness, opts \\ []) do
    run_gate_command(workspace, harness && harness.smoke_command, :smoke, opts)
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

  @doc "Checked file selection for accepting evidence. Git failure is never an empty diff."
  @spec changed_paths_checked(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def changed_paths_checked(workspace, opts \\ []) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case command_runner.("git", ["status", "--porcelain", "--untracked-files=all"], cd: workspace, stderr_to_stdout: true, env: [{"GIT_OPTIONAL_LOCKS", "0"}]) do
      {output, 0} ->
        paths = output |> to_string() |> String.split(~r/\r?\n/, trim: true) |> Enum.map(&status_path/1) |> Enum.reject(&runtime_artifact_path?/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        {:ok, paths}

      {_output, status} ->
        {:error, {:evidence_file_selection_failed, status}}
    end
  end

  @doc "Captures the real branch delta against one resolved harness base, including local files."
  def evidence_scope_checked(workspace, harness, opts \\ [])

  @spec evidence_scope_checked(Path.t(), RepoHarness.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def evidence_scope_checked(workspace, %{base_branch: base}, opts) when is_binary(base) and base != "" do
    runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    with {:ok, branch} <- evidence_branch(workspace, runner),
         {:ok, output} <- evidence_git(workspace, runner, ["rev-parse", "--verify", "--end-of-options", "#{base}^{commit}"], :base),
         commit = String.trim(output),
         true <- valid_git_oid?(commit) or {:error, :evidence_base_invalid},
         {:ok, material} <- evidence_material(workspace, commit, runner) do
      {:ok, %{base_commit: commit, branch: branch, paths: Enum.map(material, & &1.path), material: material}}
    end
  end

  def evidence_scope_checked(_workspace, _harness, _opts), do: {:error, :evidence_base_missing}

  @doc "Confirms the captured material, allowing a commit of the same bytes without adopting a new base."
  @spec confirm_evidence_scope(Path.t(), map() | nil) :: :ok | {:error, term()}
  def confirm_evidence_scope(_workspace, nil), do: :ok

  def confirm_evidence_scope(workspace, scope) do
    with {:ok, branch} <- evidence_branch(workspace, &System.cmd/3),
         true <- branch == scope.branch or {:error, :evidence_branch_changed},
         {:ok, material} <- evidence_material(workspace, scope.base_commit, &System.cmd/3),
         true <- material == scope.material or {:error, :evidence_scope_changed} do
      :ok
    end
  end

  defp evidence_branch(workspace, runner) do
    with {:ok, output} <- evidence_git(workspace, runner, ["symbolic-ref", "--quiet", "--short", "HEAD"], :branch),
         branch = String.trim(output),
         true <- branch != "" or {:error, :evidence_branch_unknown},
         do: {:ok, branch}
  end

  defp evidence_material(workspace, base_commit, runner) do
    with {:ok, changed} <- evidence_git(workspace, runner, ["diff", "--name-only", "-z", "--no-ext-diff", base_commit, "--"], :diff),
         {:ok, untracked} <- evidence_git(workspace, runner, ["ls-files", "--others", "--exclude-standard", "-z"], :untracked),
         {:ok, deleted} <- evidence_git(workspace, runner, ["diff", "--diff-filter=D", "--name-only", "-z", "--no-ext-diff", base_commit, "--"], :deleted) do
      paths = (nul_paths(changed) ++ nul_paths(untracked)) |> Enum.uniq() |> Enum.reject(&runtime_artifact_path?/1) |> Enum.sort()
      deleted_paths = nul_paths(deleted)

      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, material} ->
        case evidence_path_material(workspace, path, deleted_paths, runner) do
          {:ok, entry} -> {:cont, {:ok, material ++ [entry]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp evidence_path_material(workspace, path, deleted, runner) do
    case File.lstat(Path.join(workspace, path)) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        with {:ok, output} <- evidence_git(workspace, runner, ["hash-object", "--no-filters", "--", path], :hash),
             oid = String.trim(output),
             true <- valid_git_oid?(oid) or {:error, :evidence_material_invalid},
             do: {:ok, %{path: path, kind: "regular", executable: Bitwise.band(mode, 0o111) != 0, git_blob: oid}}

      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(Path.join(workspace, path)),
             do: {:ok, %{path: path, kind: "symlink", sha256: :crypto.hash(:sha256, target) |> Base.encode16(case: :lower)}}

      {:error, :enoent} ->
        if path in deleted, do: {:ok, %{path: path, kind: "deleted"}}, else: {:error, :evidence_scope_file_missing}

      {:ok, _unsupported} ->
        {:error, :evidence_scope_file_unsupported}

      {:error, reason} ->
        {:error, {:evidence_scope_read_failed, reason}}
    end
  end

  defp evidence_git(workspace, runner, args, phase) do
    case runner.("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, to_string(output)}
      {_output, status} -> {:error, {:evidence_scope_command_failed, phase, status}}
    end
  end

  defp valid_git_oid?(value), do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)
  defp nul_paths(output), do: String.split(output, <<0>>, trim: true)

  @spec changed_paths(Path.t(), keyword()) :: [String.t()]
  def changed_paths(workspace, opts \\ []) when is_binary(workspace) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case command_runner.("git", ["status", "--porcelain", "--untracked-files=all"], cd: workspace, stderr_to_stdout: true, env: [{"GIT_OPTIONAL_LOCKS", "0"}]) do
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

  # Identity is created at invocation, never reconstructed from persisted results.
  defp run_gate_command(workspace, command, kind, opts) do
    gate_id = Util.generate_id("gate_")
    started_at = DateTime.to_iso8601(DateTime.utc_now())
    start_time = System.monotonic_time(:microsecond)
    {result, executor} = execute_harness_command(workspace, command, opts)
    duration_us = System.monotonic_time(:microsecond) - start_time
    {os_family, os_name} = :os.type()

    %{
      result
      | gate_id: gate_id,
        gate_kind: kind,
        started_at: started_at,
        finished_at: DateTime.to_iso8601(DateTime.utc_now()),
        duration_us: duration_us,
        environment: %{os_family: os_family, os_name: os_name, executor: executor}
    }
  end

  defp run_harness_command(workspace, command, opts) do
    {result, _executor} = execute_harness_command(workspace, command, opts)
    result
  end

  defp execute_harness_command(_workspace, nil, _opts) do
    {%CommandResult{status: :unavailable, command: nil, output: "No harness command configured."}, :not_started}
  end

  defp execute_harness_command(workspace, command, opts) when is_binary(command) do
    case ExecutionBoundary.run(workspace, command, opts) do
      :legacy ->
        {run_legacy_harness_command(workspace, command, opts), :legacy_shell}

      {:ok, {output, status}} ->
        {%CommandResult{status: if(status == 0, do: :passed, else: :failed), command: command, output: output, exit_code: status}, :execution_boundary}

      {:error, reason} ->
        {%CommandResult{status: :unavailable, command: command, output: "Execution boundary failed: #{Kernel.inspect(reason)}", error: reason}, :execution_boundary}
    end
  end

  defp run_legacy_harness_command(workspace, command, opts) do
    shell_runner = Keyword.get(opts, :shell_runner, &default_shell_runner/3)
    env = workspace_runtime_env(workspace)
    {output, status} = shell_runner.(workspace, command, stderr_to_stdout: true, env: env)

    %CommandResult{
      status: if(status == 0, do: :passed, else: :failed),
      exit_code: status,
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
    case command_runner.("git", args, cd: workspace, stderr_to_stdout: true, env: [{"GIT_OPTIONAL_LOCKS", "0"}]) do
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
    if env = Keyword.get(opts, :env), do: prepare_workspace_runtime_env(workspace, env)
    System.cmd("sh", ["-lc", command], Keyword.merge([cd: workspace], opts))
  end

  # Apply these values only to the child process; never mutate the daemon's environment.
  defp workspace_runtime_env(workspace) do
    runtime_home = Path.join(Path.expand(workspace), ".symphony/runtime")
    inherited_mix_home = System.get_env("MIX_HOME")
    inherited_archives = System.get_env("MIX_ARCHIVES")
    mix_home = inherited_mix_home || Path.join(runtime_home, "mix_home")

    archives =
      inherited_archives ||
        if(inherited_mix_home, do: Path.join(mix_home, "archives"), else: Path.join(runtime_home, "mix_archives"))

    [
      {"MIX_HOME", mix_home},
      {"HEX_HOME", System.get_env("HEX_HOME") || Path.join(runtime_home, "hex_home")},
      {"MIX_ARCHIVES", archives}
    ]
  end

  defp prepare_workspace_runtime_env(workspace, env) do
    case File.stat(workspace) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> raise File.Error, reason: :enotdir, action: "open workspace", path: workspace
      {:error, reason} -> raise File.Error, reason: reason, action: "open workspace", path: workspace
    end

    Enum.each(env, fn {_key, path} -> File.mkdir_p!(Path.expand(path, workspace)) end)

    if is_nil(System.get_env("MIX_HOME")) do
      source_home = default_mix_home()
      mix_home = List.keyfind(env, "MIX_HOME", 0) |> elem(1)
      seed_runtime_path(Path.join(source_home, rebar_relative_path()), Path.join(mix_home, rebar_relative_path()))

      if is_nil(System.get_env("MIX_ARCHIVES")) do
        archives = List.keyfind(env, "MIX_ARCHIVES", 0) |> elem(1)
        seed_runtime_path(Path.join(source_home, "archives"), archives)
      end
    end
  end

  defp default_mix_home do
    if System.get_env("MIX_XDG") in ["1", "true"] do
      :filename.basedir(:user_data, "mix", %{os: :linux})
    else
      Path.join(System.user_home!(), ".mix")
    end
  end

  defp rebar_relative_path do
    [major, minor | _] = String.split(System.version(), ".")
    Path.join(["elixir", "#{major}-#{minor}-otp-#{System.otp_release()}", "rebar3"])
  end

  # Preserve workspace installs and copy only installed tools, never global config or credentials.
  defp seed_runtime_path(source, destination) do
    case File.stat(source) do
      {:ok, _stat} ->
        File.mkdir_p!(Path.dirname(destination))
        File.cp_r!(source, destination, on_conflict: fn _source, _destination -> false end, dereference_symlinks: true)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read runtime seed", path: source
    end
  end

  defp runtime_artifact_path?(nil), do: false

  defp runtime_artifact_path?(path) do
    normalized = path |> to_string() |> String.trim()
    normalized == ".symphony" or String.starts_with?(normalized, ".symphony/")
  end
end
