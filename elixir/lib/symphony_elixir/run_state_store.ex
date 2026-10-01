defmodule SymphonyElixir.RunStateStore do
  @moduledoc """
  Persists per-workspace runtime state so runs can resume from explicit stages.
  """

  alias SymphonyElixir.DeployAudit
  alias SymphonyElixir.DispatchAudit
  alias SymphonyElixir.LeaseManager
  alias SymphonyElixir.Observability
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.RunnerRuntime
  alias SymphonyElixir.Config

  @relative_dir ".symphony"
  @filename "run_state.json"
  @stage_history_limit 25

  @material_fields ~w(stage last_ledger_event_id review_claims review_threads pr_url repo_url policy_pack effective_policy_class stop_reason implementation_turns policy_override review_return_stage)
  @current_stages ~w(checkout initialize_harness plan implement validate review_verification verify publish merge_readiness await_checks merge post_merge deploy_preview deploy_production post_deploy_verify done blocked)
  @current_counter_attrs ~w(implementation_turns validation_attempts verification_attempts publish_attempts await_checks_polls merge_attempts harness_attempts ci_fix_attempts)a
  @current_attrs @current_counter_attrs ++
                   ~w(issue_source branch base_branch harness_version progress_path effective_policy_class effective_policy_source policy_override
                      last_harness_init last_harness_check harness_status plan_completed resume_context review_claims review_threads last_turn_result
                      pr_url last_validation last_decision_summary next_human_action last_verifier last_verifier_verdict acceptance_summary ui_proof_required_checks
                      last_commit_sha last_pr_body_validation last_ci_failure last_pr_state last_review_decision last_check_statuses last_required_checks_state
                      last_missing_required_checks last_pending_required_checks last_failing_required_checks last_cancelled_required_checks merge_window_wait
                      last_merge last_merge_readiness last_post_deploy_verify last_decision deploy_approved last_post_merge current_deploy_target stop_reason
                      last_implementation_error reason last_rule_id last_failure_class deploy_window_wait)a

  @coordinator_fields @material_fields ++ ~w(resume_context last_ci_failure issue_source runner_channel runner_instance_id last_review_decision next_human_action)
  @coordinator_review_attrs ~w(review_threads review_claims last_review_decision last_decision_summary next_human_action resume_context)a
  @coordinator_ci_attrs ~w(last_ci_failure last_decision_summary next_human_action resume_context)a
  @coordinator_cleanup_attrs ~w(stop_reason last_decision last_rule_id last_failure_class next_human_action)a
  @coordinator_transition_attrs ~w(issue_source pr_url stop_reason last_decision last_rule_id last_failure_class)a
  @coordinator_binding ~w(run_id run_identity_event_id run_identity_ledger_path)a
  @coordinator_ci_fields ~w(event_name action check_name conclusion details_url head_sha pr_url summary)
  @coordinator_review_resume ~w(review_feedback_summary review_claim_summary review_feedback_pr_url)
  @coordinator_ci_resume ~w(ci_failure_summary ci_failure_pr_url ci_failure_details_url)

  @type coordinator_authority :: %{
          workspace: Path.t(),
          issue_id: String.t(),
          issue_identifier: String.t(),
          binding: :legacy_absent | {:identified, map()},
          lease_token: LeaseManager.token(),
          deadline: integer()
        }

  @type authority :: %{ticket: DispatchAudit.ticket(), lease_token: LeaseManager.token()}
  @type admission_source :: :missing | {:present, map()}

  @doc "Keeps canonical material values and real field presence, without defaults or usage metadata."
  @spec material_projection(map()) :: map()
  def material_projection(state) when is_map(state) do
    state |> Jason.encode!() |> Jason.decode!() |> Map.take(@material_fields)
  end

  @doc "Keeps the coordinator's complete canonical decision inputs without changing worker material."
  @spec coordinator_projection(map()) :: map()
  def coordinator_projection(state) when is_map(state) do
    state |> Jason.encode!() |> Jason.decode!() |> Map.take(@coordinator_fields)
  end

  @doc "Checks a pre-dispatch coordinator's captured run, token, material and deadline."
  @spec ensure_coordinator_current(coordinator_authority(), map()) :: {:ok, map()} | {:error, term()}
  def ensure_coordinator_current(authority, expected) do
    with {:ok, workspace} <- coordinator_workspace(authority) do
      with_workspace_lock(workspace, fn ->
        with {:ok, state, _lease} <- coordinator_state_unlocked(authority, expected), :ok <- coordinator_deadline(authority.deadline), do: {:ok, state}
      end)
    end
  end

  @doc "Persists one closed review or CI observation on the checked fresh snapshot."
  @spec update_coordinator_current(coordinator_authority(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_coordinator_current(authority, expected, attrs) do
    with {:ok, workspace} <- coordinator_workspace(authority) do
      with_workspace_lock(workspace, fn ->
        with {:ok, state, _lease} <- coordinator_state_unlocked(authority, expected),
             {:ok, attrs} <- coordinator_attrs(attrs, state, :update),
             updated = Map.merge(state, attrs),
             :ok <- write_coordinator_snapshot(workspace, updated, authority.deadline),
             do: {:ok, updated}
      end)
    end
  end

  @doc "Applies only an owner-decided CI/review transition under captured coordinator authority."
  @spec transition_coordinator_current(coordinator_authority(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transition_coordinator_current(authority, expected, stage, attrs) when stage in ["implement", "review_verification"] do
    with {:ok, workspace} <- coordinator_workspace(authority) do
      with_workspace_lock(workspace, fn ->
        with {:ok, state, lease} <- coordinator_state_unlocked(authority, expected),
             {:ok, attrs} <- coordinator_attrs(attrs, state, {:transition, stage}) do
          same_stage? = state[:stage] == stage

          updated =
            state
            |> Map.merge(attrs)
            |> apply_lease_attrs(LeaseManager.snapshot_for_state(lease))
            |> ensure_runner_metadata()
            |> Map.put(:stage, stage)
            |> maybe_record_stage_transition(stage, nil, same_stage?)

          if same_stage? do
            with :ok <- write_coordinator_snapshot(workspace, updated, authority.deadline), do: {:ok, updated}
          else
            commit_audited_transition(workspace, updated, attrs, state[:stage], %{}, authority.deadline)
          end
        end
      end)
    end
  end

  def transition_coordinator_current(_authority, _expected, _stage, _attrs), do: {:error, :invalid_coordinator_stage}

  defp coordinator_workspace(%{workspace: workspace, issue_id: id, issue_identifier: identifier, binding: _binding, lease_token: token, deadline: deadline} = authority)
       when is_binary(workspace) and workspace != "" and is_binary(id) and id != "" and is_binary(identifier) and identifier != "" and
              is_map(token) and is_integer(deadline) and map_size(authority) == 6 do
    if Path.type(workspace) == :absolute and Path.expand(workspace) == workspace,
      do: {:ok, workspace},
      else: coordinator_rejected(:invalid_coordinator_workspace)
  end

  defp coordinator_workspace(_authority), do: coordinator_rejected(:invalid_coordinator_authority)

  defp coordinator_state_unlocked(authority, expected) do
    with :ok <- coordinator_deadline(authority.deadline),
         :ok <- DispatchAudit.ensure_available(authority.workspace),
         :ok <- DeployAudit.ensure_available(authority.workspace),
         {:ok, raw} <- read_canonical_snapshot(authority.workspace),
         :ok <- coordinator_assert(raw["issue_id"] == authority.issue_id and raw["issue_identifier"] == authority.issue_identifier, :coordinator_issue_mismatch),
         :ok <- coordinator_binding(authority, raw),
         {:ok, path} <- RunLedger.ledger_file_path_checked(),
         :ok <- coordinator_token_location(authority, path),
         :ok <- coordinator_lease_check(LeaseManager.ensure_current(authority.lease_token)),
         {:ok, lease} <- LeaseManager.read_at(authority.lease_token.storage),
         :ok <- coordinator_physical_lease(authority, lease),
         :ok <- coordinator_assert(is_map(expected) and expected == coordinator_projection(raw), :coordinator_material_changed) do
      state =
        Map.new(raw, fn
          {"stage_transition_counts", counts} -> {:stage_transition_counts, counts}
          {key, value} -> {atom_key(key), atomize_value(value)}
        end)

      {:ok, state, lease}
    end
  end

  defp coordinator_binding(%{binding: :legacy_absent}, raw) do
    coordinator_assert(Enum.all?(@coordinator_binding, &(not Map.has_key?(raw, Atom.to_string(&1)))), :coordinator_binding_changed)
  end

  defp coordinator_binding(%{binding: {:identified, binding}} = authority, raw) when is_map(binding) do
    with :ok <- coordinator_assert(coordinator_keys?(binding, @coordinator_binding), :invalid_coordinator_binding),
         :ok <- coordinator_assert(Enum.all?(@coordinator_binding, &(is_binary(binding[&1]) and binding[&1] != "" and raw[Atom.to_string(&1)] == binding[&1])), :coordinator_binding_changed) do
      SymphonyElixir.RunIdentity.verify(authority.workspace, binding.run_id, authority.issue_id, authority.issue_identifier)
    end
  end

  defp coordinator_binding(_authority, _raw), do: coordinator_rejected(:invalid_coordinator_binding)

  defp coordinator_token_location(%{issue_id: id, lease_token: %{storage: %{issue_id: id, ledger_path: path}}}, path), do: :ok
  defp coordinator_token_location(_authority, _path), do: coordinator_rejected(:coordinator_lease_location_changed)

  defp coordinator_physical_lease(%{lease_token: token, issue_identifier: identifier}, lease) do
    same? =
      lease["lease_version"] == 2 and lease["issue_id"] == token.storage.issue_id and lease["issue_identifier"] == identifier and
        lease["owner"] == token.owner and lease["epoch"] == token.epoch and lease["lease_generation"] == token.lease_generation and
        lease["acquired_at"] == token.acquired_at

    with :ok <- coordinator_assert(same?, :lease_token_mismatch),
         age when is_integer(age) <- LeaseManager.age_ms(lease) do
      coordinator_assert(age < token.storage.ttl_ms, :lease_expired)
    else
      nil -> coordinator_rejected(:invalid_lease)
      {:error, _reason} = error -> error
    end
  end

  defp coordinator_lease_check({:error, reason}) when reason in [:lease_token_mismatch, :lease_expired, :invalid_lease_token, :invalid_lease_storage, :missing],
    do: coordinator_rejected(reason)

  defp coordinator_lease_check(result), do: result

  defp coordinator_deadline(:not_pending), do: :ok
  defp coordinator_deadline(deadline), do: coordinator_assert(System.monotonic_time(:millisecond) < deadline, :coordinator_deadline_expired)
  defp coordinator_assert(true, _cause), do: :ok
  defp coordinator_assert(false, cause), do: coordinator_rejected(cause)
  defp coordinator_rejected(cause), do: {:error, {:coordinator_precondition_failed, cause}}

  defp coordinator_keys?(map, keys), do: MapSet.new(Map.keys(map)) == MapSet.new(keys)

  defp coordinator_attrs(attrs, state, operation) when is_map(attrs) do
    with {:ok, kind} <- coordinator_attr_kind(attrs, operation),
         {:ok, encoded} <- Jason.encode(attrs),
         canonical = Jason.decode!(encoded),
         true <- coordinator_values?(canonical, state, kind, operation) do
      # A nil legacy source supplied by the closed shape must not materialize a missing RAW field.
      attrs = if operation != :update and not Map.has_key?(state, :issue_source), do: Map.delete(attrs, :issue_source), else: attrs
      {:ok, attrs}
    else
      _ -> {:error, :invalid_coordinator_attrs}
    end
  end

  defp coordinator_attrs(_attrs, _state, _operation), do: {:error, :invalid_coordinator_attrs}

  defp coordinator_attr_kind(attrs, :update) do
    cond do
      coordinator_keys?(attrs, @coordinator_review_attrs) -> {:ok, :review}
      coordinator_keys?(attrs, @coordinator_ci_attrs) -> {:ok, :ci}
      true -> {:error, :invalid_coordinator_attrs}
    end
  end

  defp coordinator_attr_kind(attrs, {:transition, stage}) do
    cond do
      stage == "implement" and coordinator_keys?(attrs, @coordinator_ci_attrs ++ @coordinator_transition_attrs ++ [:await_checks_polls]) -> {:ok, :ci}
      coordinator_keys?(attrs, @coordinator_review_attrs ++ @coordinator_transition_attrs ++ [:review_return_stage]) -> {:ok, :review}
      true -> {:error, :invalid_coordinator_attrs}
    end
  end

  defp coordinator_values?(attrs, state, kind, operation) do
    raw = state |> Jason.encode!() |> Jason.decode!()
    valid_summary? = is_binary(attrs["last_decision_summary"]) and (is_nil(attrs["next_human_action"]) or is_binary(attrs["next_human_action"]))

    valid_fields? =
      case kind do
        :review ->
          is_map(attrs["review_threads"]) and is_map(attrs["review_claims"]) and (is_nil(attrs["last_review_decision"]) or is_binary(attrs["last_review_decision"]))

        :ci ->
          is_map(attrs["last_ci_failure"]) and coordinator_keys?(attrs["last_ci_failure"], @coordinator_ci_fields) and
            Enum.all?(Map.values(attrs["last_ci_failure"]), &(is_nil(&1) or is_binary(&1))) and attrs["last_ci_failure"]["pr_url"] == raw["pr_url"]
      end

    valid_transition? =
      case operation do
        :update ->
          true

        {:transition, _stage} ->
          coordinator_source?(attrs["issue_source"]) and attrs["issue_source"] == raw["issue_source"] and
            is_binary(attrs["pr_url"]) and attrs["pr_url"] != "" and attrs["pr_url"] == raw["pr_url"] and
            Enum.all?(@coordinator_cleanup_attrs, &is_nil(attrs[Atom.to_string(&1)])) and
            if(kind == :ci, do: attrs["await_checks_polls"] == 0, else: attrs["review_return_stage"] == raw["stage"])
      end

    valid_summary? and valid_fields? and valid_transition? and coordinator_resume?(attrs["resume_context"], raw, kind)
  end

  defp coordinator_source?(nil), do: true
  defp coordinator_source?(source) when is_binary(source), do: String.downcase(String.trim(source)) in ["manual", "tracker"]
  defp coordinator_source?(_source), do: false

  defp coordinator_resume?(resume, raw, kind) when is_map(resume) do
    previous =
      case raw["resume_context"] do
        context when is_map(context) -> context
        _ -> %{}
      end

    fields = if kind == :review, do: @coordinator_review_resume, else: @coordinator_ci_resume
    pr_key = if kind == :review, do: "review_feedback_pr_url", else: "ci_failure_pr_url"
    allowed = ["next_objective" | fields]
    objective_unchanged? = Map.fetch(resume, "next_objective") == Map.fetch(previous, "next_objective")
    objective = resume["next_objective"]

    Enum.all?(fields, &(Map.has_key?(resume, &1) and (is_nil(resume[&1]) or is_binary(resume[&1])))) and
      resume[pr_key] == raw["pr_url"] and Map.drop(resume, allowed) == Map.drop(previous, allowed) and
      (objective_unchanged? or (is_binary(objective) and String.trim(objective) != ""))
  end

  defp coordinator_resume?(_resume, _raw, _kind), do: false

  defp write_coordinator_snapshot(workspace, state, deadline) do
    path = state_path(workspace)
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, payload} <- Jason.encode(state),
         :ok <- coordinator_deadline(deadline) do
      case File.write(tmp_path, payload, [:write]) do
        :ok ->
          case File.rename(tmp_path, path) do
            :ok -> :ok
            {:error, _reason} = error -> coordinator_snapshot_error(tmp_path, error)
          end

        {:error, _reason} = error ->
          coordinator_snapshot_error(tmp_path, error)
      end
    end
  end

  defp coordinator_snapshot_error(tmp_path, {:error, primary} = error) do
    case File.rm(tmp_path) do
      :ok -> error
      {:error, :enoent} -> error
      {:error, cleanup} -> {:error, {:coordinator_snapshot_cleanup_failed, primary, cleanup}}
    end
  end

  @doc "Reads the canonical admission witness and its derived view from one snapshot read."
  @spec read_admission_source(Path.t(), map()) :: {:ok, admission_source(), map()} | {:error, term()}
  def read_admission_source(workspace, %{id: id, identifier: identifier} = issue)
      when is_binary(workspace) and is_binary(id) and id != "" and is_binary(identifier) and identifier != "" do
    with :ok <- DeployAudit.ensure_available(workspace) do
      case read_canonical_snapshot(workspace) do
        {:ok, raw} ->
          if raw["issue_id"] == id and raw["issue_identifier"] == identifier,
            do: {:ok, {:present, raw}, merge_defaults(atomize(raw), issue)},
            else: {:error, :run_identity_issue_mismatch}

        {:error, :missing} ->
          with :ok <- ensure_no_bootstrap_admission(workspace), do: {:ok, :missing, default_state(issue)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def read_admission_source(_workspace, _issue), do: {:error, :invalid_admission_issue}

  defp ensure_no_bootstrap_admission(workspace) do
    parent = Path.dirname(workspace)
    prefix = ".#{Path.basename(workspace)}.bootstrap-"

    case File.ls(parent) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.reduce_while(:ok, fn entry, :ok ->
          case File.lstat(Path.join([parent, entry, @filename])) do
            {:ok, _stat} -> {:halt, {:error, :admission_bootstrap_present}}
            {:error, reason} when reason in [:enoent, :enotdir] -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:admission_bootstrap_unreadable, reason}}}
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:admission_bootstrap_unreadable, reason}}
    end
  end

  @doc "Checks the captured authority and material state without adopting a later snapshot."
  @spec ensure_current(authority(), map()) :: {:ok, map()} | {:error, term()}
  def ensure_current(authority, expected) do
    with {:ok, workspace} <- authority_workspace(authority) do
      with_workspace_lock(workspace, fn -> current_state_unlocked(authority, expected) end)
    end
  end

  @doc "Confirms an owner-authenticated terminal CAS result without granting permission to execute."
  @spec confirm_terminal_current(authority(), map()) :: :ok | {:error, term()}
  def confirm_terminal_current(authority, expected) do
    with {:ok, workspace} <- authority_workspace(authority) do
      with_workspace_lock(workspace, fn ->
        with {:ok, _state} <- terminal_state_unlocked(authority, expected), do: :ok
      end)
    end
  end

  @doc "Applies a finite attribute delta to the fresh state under its material precondition."
  @spec update_current(authority(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_current(authority, expected, attrs) do
    with {:ok, workspace} <- authority_workspace(authority) do
      with_workspace_lock(workspace, fn ->
        with {:ok, state} <- current_state_unlocked(authority, expected),
             {:ok, attrs} <- validate_current_attrs(attrs, state),
             updated = Map.merge(state, attrs),
             :ok <- write_json_atomically(state_path(workspace), updated) do
          {:ok, updated}
        end
      end)
    end
  end

  @doc "Transitions only from checked fresh state and records validated runtime provenance."
  @spec transition_current(authority(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transition_current(authority, expected, stage, attrs) when stage in @current_stages do
    transition_current_with_provenance(authority, expected, stage, attrs, :runtime)
  end

  def transition_current(_authority, _expected, _stage, _attrs), do: {:error, :invalid_current_stage}

  @doc "Persists only provenance supplied by the owner-confirmed worker invocation."
  @spec transition_current(authority(), map(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def transition_current(authority, expected, stage, attrs, provenance) when stage in @current_stages and is_map(provenance) do
    transition_current_with_provenance(authority, expected, stage, attrs, provenance)
  end

  def transition_current(_authority, _expected, _stage, _attrs, _provenance), do: {:error, :invalid_execution_provenance}

  defp transition_current_with_provenance(authority, expected, stage, attrs, provenance) do
    with {:ok, workspace} <- authority_workspace(authority) do
      with_workspace_lock(workspace, fn ->
        with {:ok, state} <- current_state_unlocked(authority, expected),
             {:ok, attrs} <- validate_current_attrs(attrs, state),
             {:ok, execution} <- execution_provenance(authority, state, provenance) do
          transition_from_state(workspace, stage, attrs, ensure_runner_metadata(state), %{execution: execution})
        end
      end)
    end
  end

  @doc false
  @spec check_deploy_current_locked(authority(), map()) :: {:ok, map()} | {:error, term()}
  def check_deploy_current_locked(authority, expected) do
    with {:ok, _workspace} <- authority_workspace(authority), do: current_state_unlocked(authority, expected)
  end

  @doc "Records usage only if captured material is still current inside the checkpoint lock."
  @spec record_token_usage_current(Path.t(), map(), map(), authority(), map()) :: {:ok, map()} | {:error, term()}
  def record_token_usage_current(workspace, issue, usage, authority, expected) do
    with {:ok, captured_workspace} <- authority_workspace(authority),
         :ok <- matching_usage_workspace(workspace, captured_workspace) do
      with_workspace_lock(captured_workspace, fn ->
        with {:ok, state} <- current_state_unlocked(authority, expected),
             :ok <- stale_check(matching_token_usage_context(workspace, issue, state, authority.ticket, authority.lease_token)) do
          persist_current_usage(workspace, state, usage)
        end
      end)
    end
  end

  @doc "Records only final usage for an owner-authenticated receipt of its own checked stop."
  @spec record_final_token_usage_current(Path.t(), map(), map(), authority(), map()) :: {:ok, map()} | {:error, term()}
  def record_final_token_usage_current(workspace, issue, usage, authority, receipt) do
    with {:ok, captured_workspace} <- authority_workspace(authority),
         :ok <- matching_usage_workspace(workspace, captured_workspace),
         :ok <- validate_stop_receipt(receipt) do
      with_workspace_lock(captured_workspace, fn ->
        with {:ok, state} <- terminal_state_unlocked(authority, receipt.next),
             :ok <- stale_check(matching_token_usage_context(workspace, issue, state, authority.ticket, authority.lease_token)) do
          persist_current_usage(workspace, state, usage)
        end
      end)
    end
  end

  defp authority_workspace(%{ticket: %{workspace: workspace}, lease_token: _token}) when is_binary(workspace) and workspace != "",
    do: {:ok, Path.expand(workspace)}

  defp authority_workspace(_authority), do: {:error, {:stale_execution, :invalid_execution_authority}}

  defp matching_usage_workspace(workspace, captured) when is_binary(workspace) do
    if Path.expand(workspace) == captured, do: :ok, else: {:error, {:stale_execution, :execution_workspace_mismatch}}
  end

  defp matching_usage_workspace(_workspace, _captured), do: {:error, {:stale_execution, :execution_workspace_mismatch}}

  defp read_canonical_snapshot(workspace) do
    with {:ok, raw} <- read_token_usage_snapshot(state_path(workspace)),
         :ok <- ensure_audit_complete(raw),
         :ok <- SymphonyElixir.RunIdentity.validate_snapshot(raw),
         do: {:ok, raw}
  end

  defp authority_snapshot_unlocked(%{ticket: ticket, lease_token: token}) do
    with :ok <- LeaseManager.ensure_current(token),
         {:ok, raw} <- read_canonical_snapshot(ticket.workspace),
         state = atomize(raw),
         issue = %{id: token.storage.issue_id, identifier: state[:issue_identifier]},
         :ok <- matching_token_usage_context(ticket.workspace, issue, state, ticket, token),
         do: {:ok, state}
  end

  defp current_state_unlocked(authority, expected) do
    result =
      with {:ok, state} <- authority_snapshot_unlocked(authority) do
        DispatchAudit.with_authorization(authority.ticket, fn ->
          with :ok <- DispatchAudit.ensure_workspace_access(authority.ticket.workspace),
               :ok <- matching_material(state, expected),
               do: {:ok, state}
        end)
      end

    stale_check(result)
  end

  defp terminal_state_unlocked(authority, %{"stage" => stage} = expected) when stage in ["blocked", "done"] do
    result =
      with {:ok, state} <- authority_snapshot_unlocked(authority) do
        DispatchAudit.with_authorization(authority.ticket, fn ->
          with :ok <- matching_material(state, expected), do: {:ok, state}
        end)
      end

    stale_check(result)
  end

  defp terminal_state_unlocked(_authority, _expected), do: {:error, {:stale_execution, :invalid_terminal_precondition}}

  defp matching_material(state, expected) when is_map(expected) do
    if expected == material_projection(state), do: :ok, else: {:error, :material_state_changed}
  end

  defp matching_material(_state, _expected), do: {:error, :invalid_material_precondition}

  defp stale_check({:error, reason}), do: {:error, {:stale_execution, reason}}
  defp stale_check(result), do: result

  defp validate_current_attrs(attrs, state) when is_map(attrs) do
    identities_match = Enum.all?([:issue_id, :issue_identifier], &(not Map.has_key?(attrs, &1) or attrs[&1] == state[&1]))
    attrs = Map.drop(attrs, [:issue_id, :issue_identifier])
    valid_counters = Enum.all?(@current_counter_attrs, &(not Map.has_key?(attrs, &1) or (is_integer(attrs[&1]) and attrs[&1] >= 0)))
    valid_maps = Enum.all?([:review_claims, :review_threads, :resume_context], &(not Map.has_key?(attrs, &1) or is_map(attrs[&1])))

    if identities_match and valid_counters and valid_maps and Enum.all?(Map.keys(attrs), &(&1 in @current_attrs)) do
      case Jason.encode(attrs) do
        {:ok, _encoded} -> {:ok, attrs}
        {:error, _reason} -> {:error, :invalid_current_attrs}
      end
    else
      {:error, :invalid_current_attrs}
    end
  end

  defp validate_current_attrs(_attrs, _state), do: {:error, :invalid_current_attrs}

  defp execution_provenance(authority, state, :runtime) do
    with {:ok, prior} <- checked_prior_agent_session(state) do
      {:ok,
       %{
         version: 1,
         actor_role: "runtime",
         run_id: authority.ticket.run_id,
         dispatch_id: authority.ticket.dispatch_id,
         lease_generation: authority.lease_token.lease_generation,
         agent_session: nil,
         prior_agent_session: prior
       }}
    end
  end

  defp execution_provenance(authority, state, provenance) when is_map(provenance) do
    with {:ok, expected} <- execution_provenance(authority, state, :runtime),
         true <- MapSet.new(Map.keys(provenance)) == MapSet.new(Map.keys(expected)) or {:error, :invalid_execution_provenance},
         true <- Map.delete(provenance, :agent_session) == Map.delete(expected, :agent_session) or {:error, :execution_provenance_mismatch},
         :ok <- valid_agent_session(provenance.agent_session) do
      {:ok, provenance}
    end
  end

  defp valid_agent_session(nil), do: :ok

  defp valid_agent_session(%{provider: provider, kind: kind, id: id, invocation: ordinal} = session)
       when provider in ["claude_cli", "codex_cli", "app_server"] and kind in ["session", "thread"] and is_binary(id) and id != "" and
              is_integer(ordinal) and ordinal > 0 and map_size(session) == 4,
       do: :ok

  defp valid_agent_session(_session), do: {:error, :invalid_execution_agent_session}

  defp checked_prior_agent_session(state) do
    case Map.fetch(state, :last_agent_session) do
      :error -> {:ok, nil}
      {:ok, previous} -> validate_prior_agent_session(state, previous)
    end
  end

  defp validate_prior_agent_session(state, %{version: 1, event_id: id, run_id: run_id, dispatch_id: dispatch_id, agent_session: session} = previous)
       when is_binary(id) and id != "" and is_binary(run_id) and run_id != "" and is_binary(dispatch_id) and dispatch_id != "" and
              is_map(session) and map_size(previous) == 5 do
    with :ok <- valid_agent_session(session),
         true <- run_id == state[:run_id] or {:error, :prior_agent_session_run_mismatch},
         {:ok, event} <- RunLedger.fetch_entry_checked(id),
         true <-
           (event["event_type"] == "stage.transition" and event["issue_id"] == state[:issue_id] and
              event["issue_identifier"] == state[:issue_identifier]) or {:error, :prior_agent_session_event_mismatch},
         execution when is_map(execution) <- get_in(event, ["metadata", "execution"]),
         true <-
           (execution["version"] == 1 and execution["actor_role"] == "runtime" and execution["run_id"] == run_id and
              execution["dispatch_id"] == dispatch_id and execution["agent_session"] == json_value(session)) or
             {:error, :prior_agent_session_event_mismatch} do
      {:ok, Map.take(previous, [:event_id, :run_id, :dispatch_id, :agent_session])}
    else
      {:error, reason} -> {:error, {:invalid_prior_agent_session, reason}}
      _ -> {:error, {:invalid_prior_agent_session, :missing_execution_provenance}}
    end
  end

  defp validate_prior_agent_session(_state, _previous), do: {:error, :invalid_prior_agent_session}

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp record_last_agent_session(state, %{execution: %{agent_session: session} = execution}, event_id) when is_map(session) do
    Map.put(state, :last_agent_session, %{
      version: 1,
      event_id: event_id,
      run_id: execution.run_id,
      dispatch_id: execution.dispatch_id,
      agent_session: session
    })
  end

  defp record_last_agent_session(state, _metadata, _event_id), do: state

  defp validate_stop_receipt(%{previous: previous, next: %{"stage" => "blocked", "stop_reason" => stop_reason} = next, binding: {provider, kind, id}, ordinal: ordinal, outcome: {:stop, _violation}})
       when is_map(previous) and is_map(stop_reason) and map_size(stop_reason) > 0 and is_atom(provider) and
              kind in [:session, :thread] and is_binary(id) and id != "" and is_integer(ordinal) and ordinal > 0 do
    if previous == material_projection(previous) and next == material_projection(next) and previous["stage"] not in ["blocked", "done"],
      do: :ok,
      else: {:error, :invalid_stop_receipt}
  end

  defp validate_stop_receipt(_receipt), do: {:error, :invalid_stop_receipt}

  defp persist_current_usage(workspace, state, usage) do
    with {:ok, usage} <- monotonic_token_usage(state, usage),
         updated = Map.put(state, :token_usage, usage),
         :ok <- write_json_atomically(state_path(workspace), updated),
         do: {:ok, updated}
  end

  @spec state_path(Path.t()) :: Path.t()
  def state_path(workspace) when is_binary(workspace) do
    Path.join([workspace, @relative_dir, @filename])
  end

  @spec load(Path.t()) :: {:ok, map()} | {:error, :missing | term()}
  def load(workspace) when is_binary(workspace) do
    with {:ok, path} <- load_path(workspace),
         {:ok, payload} <- File.read(path),
         {:ok, decoded} <- Jason.decode(payload),
         true <- is_map(decoded) or {:error, :invalid_state},
         :ok <- ensure_audit_complete(decoded),
         :ok <- SymphonyElixir.RunIdentity.validate_snapshot(decoded) do
      {:ok, atomize(decoded)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_audit_complete(%{"audit_pending" => pending}) when is_map(pending),
    do: {:error, {:audit_pending, Map.get(pending, "operation_id")}}

  defp ensure_audit_complete(%{"audit_pending" => _}), do: {:error, :invalid_audit_pending}
  defp ensure_audit_complete(_state), do: :ok

  defp load_path(workspace) when is_binary(workspace) do
    path = state_path(workspace)

    cond do
      File.exists?(path) ->
        {:ok, path}

      true ->
        case staged_bootstrap_state_path(workspace) do
          nil -> {:error, :missing}
          staged_path -> {:ok, staged_path}
        end
    end
  end

  defp staged_bootstrap_state_path(workspace) when is_binary(workspace) do
    basename = Path.basename(workspace)
    parent = Path.dirname(workspace)
    prefix = ".#{basename}.bootstrap-"

    parent
    |> File.ls()
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.map(&Path.join(parent, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(fn dir -> {dir, Path.join([dir, @filename])} end)
        |> Enum.filter(fn {_dir, path} -> File.exists?(path) end)
        |> Enum.max_by(
          fn {dir, _path} ->
            case File.stat(dir, time: :posix) do
              {:ok, stat} -> stat.mtime
              _ -> 0
            end
          end,
          fn -> nil end
        )
        |> case do
          {_dir, path} -> path
          nil -> nil
        end

      _ ->
        nil
    end
  end

  @spec load_checked(Path.t(), map()) :: {:ok, map()} | {:mismatch, map()} | {:error, :missing | term()}
  def load_checked(workspace, issue) when is_binary(workspace) and is_map(issue) do
    case load(workspace) do
      {:ok, state} ->
        if run_state_matches_issue?(state, issue) do
          {:ok, merge_defaults(state, issue)}
        else
          {:mismatch, state}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec load_or_default(Path.t(), map()) :: map()
  def load_or_default(workspace, issue) when is_binary(workspace) and is_map(issue) do
    case load(workspace) do
      {:ok, state} ->
        if run_state_matches_issue?(state, issue) do
          merge_defaults(state, issue)
        else
          default_state(issue)
        end

      {:error, :missing} ->
        default_state(issue)

      {:error, reason} ->
        unreadable_state(issue, reason)
    end
  end

  @spec ensure_readable(Path.t()) :: :ok | {:error, term()}
  def ensure_readable(workspace) when is_binary(workspace) do
    with :ok <- DeployAudit.ensure_available(workspace) do
      case load(workspace) do
        {:ok, _state} -> :ok
        {:error, :missing} -> :ok
        {:error, reason} -> {:error, unreadable_error(reason)}
      end
    end
  end

  @doc "Runs a workspace lifecycle operation while its readable snapshot is protected from local mutations."
  @spec with_readable_snapshot(Path.t(), (-> result)) :: result | {:error, term()} when result: var
  def with_readable_snapshot(workspace, fun) when is_binary(workspace) and is_function(fun, 0) do
    with_workspace_lock(workspace, fn ->
      with :ok <- ensure_readable(workspace), do: fun.()
    end)
  end

  @doc "Checks captured material before lifecycle movement and again after its existing restore."
  @spec with_readable_snapshot(Path.t(), %{authority: authority(), expected: map()}, (-> result)) :: result | {:error, term()} when result: var
  def with_readable_snapshot(workspace, %{authority: authority, expected: expected}, fun)
      when is_binary(workspace) and is_function(fun, 0) do
    with {:ok, captured_workspace} <- authority_workspace(authority),
         :ok <- matching_usage_workspace(workspace, captured_workspace) do
      with_workspace_lock(captured_workspace, fn ->
        with :ok <- stale_check(DeployAudit.ensure_available(workspace)),
             {:ok, _state} <- current_state_unlocked(authority, expected) do
          authorized_result =
            DispatchAudit.with_authorization(authority.ticket, fn ->
              result = fun.()

              postcheck =
                with :ok <- stale_check(DeployAudit.ensure_available(workspace)),
                     do: current_state_unlocked(authority, expected)

              checked_result =
                case postcheck do
                  {:ok, _state} -> result
                  {:error, {:stale_execution, reason}} -> {:error, {:stale_execution, {:lifecycle_result, result, reason}}}
                end

              {:checked_lifecycle, checked_result}
            end)

          case authorized_result do
            {:checked_lifecycle, result} -> result
            {:error, _reason} = error -> stale_check(error)
          end
        end
      end)
    end
  end

  defp load_for_update(workspace, issue) do
    case load_checked(workspace, issue) do
      {:ok, state} -> {:ok, state}
      {:mismatch, _state} -> {:ok, default_state(issue)}
      {:error, :missing} -> {:ok, default_state(issue)}
      {:error, reason} -> {:error, write_error(reason)}
    end
  end

  defp write_error(reason) when is_atom(reason) and reason != :invalid_state, do: reason
  defp write_error(reason), do: unreadable_error(reason)

  defp unreadable_error(%Jason.DecodeError{position: position}),
    do: {:run_state_unreadable, {:invalid_json, position}}

  defp unreadable_error(reason), do: {:run_state_unreadable, reason}

  defp unreadable_state(issue, {:audit_pending, operation_id}) do
    summary = "The persisted transition has an unconfirmed audit result; execution is blocked."
    action = "Reconcile the recorded operation before retrying. Preserve the snapshot and its ledger."

    default_state(issue)
    |> Map.merge(%{
      stage: "blocked",
      last_rule_id: "runtime.audit_pending",
      last_failure_class: "recovery",
      last_decision_summary: summary,
      next_human_action: action,
      stop_reason: %{
        code: "audit_pending",
        rule_id: "runtime.audit_pending",
        failure_class: "recovery",
        summary: summary,
        details: operation_id,
        human_action: action
      }
    })
  end

  defp unreadable_state(issue, reason) do
    summary = "The persisted run snapshot cannot be read; execution is blocked."
    action = "Restore a valid run_state.json from a trusted backup before retrying. The unreadable snapshot has been preserved."

    default_state(issue)
    |> Map.merge(%{
      stage: "blocked",
      last_rule_id: "runtime.snapshot_unreadable",
      last_failure_class: "recovery",
      last_decision_summary: summary,
      next_human_action: action,
      stop_reason: %{
        code: "snapshot_unreadable",
        rule_id: "runtime.snapshot_unreadable",
        failure_class: "recovery",
        summary: summary,
        details: inspect(unreadable_error(reason)),
        human_action: action
      }
    })
  end

  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(workspace, state) when is_binary(workspace) and is_map(state) do
    with_workspace_lock(workspace, fn -> save_unlocked(workspace, state) end)
  end

  @doc "Serializes local snapshot and workspace lifecycle changes, including dispatch admission."
  @spec with_workspace_lock(Path.t(), (-> result)) :: result when result: var
  def with_workspace_lock(workspace, fun) when is_binary(workspace) and is_function(fun, 0) do
    :global.trans({{__MODULE__, Path.expand(workspace)}, self()}, fun, [node()])
  end

  defp save_unlocked(workspace, state) do
    path = state_path(workspace)

    with {:ok, previous_state} <- load_for_update(workspace, %{}),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, state} <- SymphonyElixir.RunIdentity.preserve(state, previous_state) do
      state = preserve_token_usage(state, previous_state)
      write_json_atomically(path, ensure_runner_metadata(state))
    end
  end

  defp preserve_token_usage(state, previous_state) do
    issue = %{id: Map.get(state, :issue_id), identifier: Map.get(state, :issue_identifier)}

    if run_state_matches_issue?(previous_state, issue) and Map.has_key?(previous_state, :token_usage) do
      usage = Map.get(state, :token_usage, %{})
      previous_usage = Map.fetch!(previous_state, :token_usage)

      preserved =
        Map.new([:input_tokens, :output_tokens, :total_tokens], fn key ->
          {key, max(Map.get(usage, key, 0), Map.get(previous_usage, key, 0))}
        end)

      Map.put(state, :token_usage, preserved)
    else
      state
    end
  end

  @doc "Records legacy usage only when the snapshot has no complete or partial run identity."
  @spec record_token_usage(Path.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def record_token_usage(workspace, issue, usage) do
    with_workspace_lock(workspace, fn ->
      with :ok <- ensure_legacy_token_usage(workspace),
           {:ok, state} <- load_for_update(workspace, issue) do
        state = Map.put(state, :token_usage, usage)

        case save_unlocked(workspace, state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  @doc "Checks captured dispatch authority and records monotonic usage without creating or adopting a snapshot."
  @spec record_token_usage(Path.t(), map(), map(), %{ticket: DispatchAudit.ticket(), lease_token: LeaseManager.token()}) :: {:ok, map()} | {:error, term()}
  def record_token_usage(workspace, issue, usage, %{ticket: ticket, lease_token: token})
      when is_binary(workspace) and is_map(issue) and is_map(ticket) do
    with_workspace_lock(workspace, fn ->
      with :ok <- LeaseManager.ensure_current(token),
           {:ok, snapshot} <- read_token_usage_snapshot(state_path(workspace)),
           :ok <- ensure_audit_complete(snapshot),
           :ok <- SymphonyElixir.RunIdentity.validate_snapshot(snapshot),
           state = atomize(snapshot),
           :ok <- matching_token_usage_context(workspace, issue, state, ticket, token),
           {:ok, usage} <- monotonic_token_usage(state, usage) do
        DispatchAudit.with_authorization(ticket, fn ->
          state = Map.put(state, :token_usage, usage)

          with :ok <- DispatchAudit.ensure_workspace_access(workspace),
               :ok <- write_json_atomically(state_path(workspace), state) do
            {:ok, state}
          end
        end)
      end
    end)
  end

  def record_token_usage(_workspace, _issue, _usage, _context), do: {:error, :token_usage_context_mismatch}

  defp matching_token_usage_context(workspace, %{id: id, identifier: identifier}, state, ticket, token)
       when is_binary(id) and id != "" and is_binary(identifier) and identifier != "" do
    cond do
      ticket[:workspace] != Path.expand(workspace) or token.storage.issue_id != id or token.storage.ledger_path != ticket[:ledger_path] or
        token.owner != ticket[:owner] or token.epoch != ticket[:epoch] ->
        {:error, :token_usage_context_mismatch}

      state[:issue_id] != id or state[:issue_identifier] != identifier or not is_binary(ticket[:run_id]) or ticket[:run_id] == "" or state[:run_id] != ticket[:run_id] ->
        {:error, :token_usage_snapshot_mismatch}

      true ->
        :ok
    end
  end

  defp matching_token_usage_context(_workspace, _issue, _state, _ticket, _token), do: {:error, :token_usage_context_mismatch}

  defp monotonic_token_usage(state, usage) do
    previous = Map.get(state, :token_usage, %{input_tokens: 0, output_tokens: 0, total_tokens: 0})

    with :ok <- validate_token_usage(usage),
         :ok <- validate_token_usage(previous) do
      {:ok, Map.new([:input_tokens, :output_tokens, :total_tokens], fn key -> {key, max(Map.fetch!(usage, key), Map.fetch!(previous, key))} end)}
    end
  end

  defp validate_token_usage(%{input_tokens: input, output_tokens: output, total_tokens: total} = usage)
       when map_size(usage) == 3 and is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and is_integer(total) and total >= 0,
       do: :ok

  defp validate_token_usage(_usage), do: {:error, :invalid_token_usage}

  defp ensure_legacy_token_usage(workspace) do
    with {:ok, path} <- load_path(workspace),
         {:ok, snapshot} <- read_token_usage_snapshot(path) do
      if Enum.any?(["run_id", "run_identity_event_id", "run_identity_ledger_path", "run_identity_pending"], &Map.has_key?(snapshot, &1)),
        do: {:error, :token_usage_context_required},
        else: :ok
    else
      {:error, :missing} -> :ok
      {:error, reason} -> {:error, write_error(reason)}
    end
  end

  defp read_token_usage_snapshot(path) do
    with {:ok, payload} <- File.read(path),
         {:ok, snapshot} <- Jason.decode(payload),
         true <- is_map(snapshot) or {:error, :invalid_state} do
      {:ok, snapshot}
    else
      {:error, :enoent} -> {:error, :missing}
      {:error, _reason} = error -> error
    end
  end

  @spec transition(Path.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transition(workspace, stage, attrs \\ %{})
      when is_binary(workspace) and is_binary(stage) and is_map(attrs) do
    with_workspace_lock(workspace, fn ->
      with {:ok, previous_state} <- load_for_update(workspace, %{}) do
        transition_from_state(workspace, stage, attrs, previous_state)
      end
    end)
  end

  @doc "Checks a confirmed deploy against the current snapshot without changing it. Network work must remain outside this lock."
  @spec ensure_deploy_current(DeployAudit.ticket()) :: :ok | {:error, term()}
  def ensure_deploy_current(%{workspace: workspace} = ticket) do
    with_workspace_lock(workspace, fn ->
      with {:ok, context} <- DeployAudit.continuation_context_locked(ticket),
           {:ok, state} <- load(workspace) do
        matching_deploy_snapshot(state, context)
      end
    end)
  end

  @doc "Advances a confirmed deploy once, preserving fresh lease and consumption metadata under one snapshot lock."
  @spec transition_deploy(DeployAudit.ticket(), String.t(), map()) :: {:ok, map(), DeployAudit.continuation()} | {:error, term()}
  def transition_deploy(%{workspace: workspace, version: 1} = ticket, stage, attrs) when is_map(attrs) and stage in ["post_deploy_verify", "done"] do
    with_workspace_lock(workspace, fn ->
      with {:ok, context} <- DeployAudit.continuation_context_locked(ticket),
           {:ok, previous_state} <- load(workspace),
           :ok <- matching_deploy_snapshot(previous_state, context),
           :ok <- validate_deploy_attrs(attrs),
           {:ok, state} <- transition_from_state(workspace, stage, deploy_attrs(attrs, context), previous_state, deploy_metadata(context)),
           :ok <- DeployAudit.ensure_ledger_path(context.ledger_path),
           {:ok, event} <- RunLedger.fetch_entry_checked(state.last_ledger_event_id) do
        {:ok, state, %{stage: stage, event: event}}
      end
    end)
  end

  def transition_deploy(_ticket, _stage, _attrs), do: {:error, :invalid_deploy_transition}

  @doc "Checks dispatch material inside the existing deploy continuation lock and returns its persisted state."
  @spec transition_deploy(DeployAudit.ticket(), String.t(), map(), %{authority: authority(), expected: map()}) ::
          {:ok, map(), DeployAudit.continuation()} | {:error, term()}
  def transition_deploy(%{workspace: workspace, version: 2, execution: %{authority: bound_authority, expected: bound_expected} = execution} = ticket, stage, attrs, %{
        authority: authority,
        expected: expected
      })
      when is_binary(workspace) and is_map(attrs) and stage in ["post_deploy_verify", "done"] do
    with true <- (authority == bound_authority and expected == bound_expected) or {:error, :deploy_audit_execution_mismatch},
         {:ok, captured_workspace} <- authority_workspace(authority),
         :ok <- matching_usage_workspace(workspace, captured_workspace) do
      with_workspace_lock(captured_workspace, fn ->
        with {:ok, context} <- DeployAudit.continuation_context_locked(ticket),
             {:ok, previous_state} <- current_state_unlocked(authority, expected),
             :ok <- stale_check(matching_deploy_snapshot(previous_state, context)),
             :ok <- validate_deploy_attrs(attrs),
             {:ok, provenance} <- execution_provenance(authority, previous_state, execution.provenance),
             metadata = Map.put(deploy_metadata(context), :execution, provenance),
             {:ok, state} <- transition_from_state(workspace, stage, deploy_attrs(attrs, context), previous_state, metadata),
             :ok <- DeployAudit.ensure_ledger_path(context.ledger_path),
             {:ok, event} <- RunLedger.fetch_entry_checked(state.last_ledger_event_id),
             continuation = %{version: 2, stage: stage, event: event, previous: expected, next: material_projection(state)},
             :ok <- DeployAudit.anchor_continuation_locked(ticket, continuation) do
          {:ok, state, continuation}
        end
      end)
    end
  end

  def transition_deploy(_ticket, _stage, _attrs, _precondition), do: {:error, :invalid_deploy_transition}

  @doc false
  @spec confirm_deploy_continuation_locked(DeployAudit.ticket(), authority(), DeployAudit.continuation()) :: :ok | {:error, term()}
  def confirm_deploy_continuation_locked(
        %{version: 2, execution: %{authority: bound_authority, expected: bound_expected}} = ticket,
        authority,
        %{version: 2, stage: stage, event: event, previous: previous, next: next} = continuation
      )
      when stage in ["post_deploy_verify", "done"] do
    with :ok <- DeployAudit.assert_continuation_locked(ticket, continuation),
         true <- (authority == bound_authority and previous == bound_expected) or {:error, :deploy_audit_execution_mismatch},
         {:ok, _workspace} <- authority_workspace(authority),
         {:ok, state} <- deploy_next_state(authority, next, stage),
         true <-
           (state[:last_ledger_event_id] == event["event_id"] and state[:last_deploy_operation_id] == ticket.operation_id and
              is_nil(state[:stop_reason])) or {:error, :deploy_audit_continuation_mismatch},
         :ok <- DeployAudit.ensure_ledger_path(authority.ticket.ledger_path),
         {:ok, confirmed} <- RunLedger.fetch_entry_checked(event["event_id"]),
         true <- confirmed == event or {:error, :deploy_audit_continuation_mismatch},
         do: :ok
  end

  def confirm_deploy_continuation_locked(_ticket, _authority, _continuation), do: {:error, :invalid_deploy_audit_continuation}
  defp deploy_next_state(authority, %{"stage" => "done"} = next, "done"), do: terminal_state_unlocked(authority, next)
  defp deploy_next_state(authority, %{"stage" => "post_deploy_verify"} = next, "post_deploy_verify"), do: current_state_unlocked(authority, next)
  defp deploy_next_state(_authority, _next, _stage), do: {:error, :invalid_deploy_audit_continuation}

  defp matching_deploy_snapshot(state, %{version: 2} = context) do
    if state[:issue_id] == context.issue_id and state[:issue_identifier] == context.issue_identifier and state[:stage] == context.stage and
         state[:last_ledger_event_id] == context.entry_event_id and is_nil(state[:stop_reason]), do: :ok, else: {:error, :deploy_audit_snapshot_conflict}
  end

  defp matching_deploy_snapshot(state, context) do
    if state[:issue_id] == context.issue_id and state[:issue_identifier] == context.issue_identifier and state[:stage] == context.stage and
         state[:last_ledger_event_id] == context.entry_event_id and state[:lease_owner] == context.lease_owner and state[:lease_epoch] == context.lease_epoch and
         is_nil(state[:stop_reason]),
       do: :ok,
       else: {:error, :deploy_audit_snapshot_conflict}
  end

  defp validate_deploy_attrs(attrs) do
    allowed = [:issue_source, :last_decision_summary, :completed_at, :reason, :next_human_action, :stop_reason]

    if Enum.all?(Map.keys(attrs), &(&1 in allowed)) and is_nil(Map.get(attrs, :stop_reason)) and is_nil(Map.get(attrs, :next_human_action)),
      do: :ok,
      else: {:error, :invalid_deploy_transition_attrs}
  end

  defp deploy_attrs(attrs, context) do
    result_key = if context.target == "preview", do: :last_deploy_preview, else: :last_deploy_production

    attrs =
      attrs
      |> Map.put(result_key, context.result)
      |> Map.put(:last_deploy_operation_id, context.operation_id)
      |> Map.put(:current_deploy_target, context.target)
      |> Map.put(:last_decision, nil)

    if context.target == "production",
      do: Map.merge(attrs, %{deploy_window_wait: nil, deploy_approved: false}),
      else: attrs
  end

  defp deploy_metadata(context) do
    %{
      deploy_operation_id: context.operation_id,
      deploy_intent_event_id: context.intent_event_id,
      deploy_result_event_id: context.result_event_id
    }
  end

  defp transition_from_state(workspace, stage, attrs, previous_state, transition_metadata \\ %{}) do
    same_stage? = Map.get(previous_state, :stage) == stage

    state =
      previous_state
      |> Map.merge(attrs)
      |> preserve_token_usage(previous_state)
      |> Map.put(:stage, stage)
      |> maybe_record_stage_transition(stage, Map.get(attrs, :reason), same_stage?)

    if same_stage? do
      with :ok <- save_unlocked(workspace, state), do: {:ok, state}
    else
      commit_audited_transition(workspace, state, attrs, Map.get(previous_state, :stage), transition_metadata)
    end
  end

  defp commit_audited_transition(workspace, state, attrs, previous_stage, transition_metadata, coordinator_deadline \\ :not_pending) do
    state = ensure_runner_metadata(state)
    operation_id = SymphonyElixir.Util.generate_id("op_")

    event_attrs = %{
      issue_id: Map.get(state, :issue_id),
      issue_identifier: Map.get(state, :issue_identifier),
      stage: state.stage,
      actor_type: "runtime",
      actor_id: "run_state_store",
      policy_class: Map.get(state, :effective_policy_class),
      summary: "Transitioned to #{state.stage}",
      details: Map.get(attrs, :reason),
      metadata:
        Map.merge(transition_metadata, %{
          operation_id: operation_id,
          previous_stage: previous_stage,
          snapshot_digest: snapshot_digest(state),
          stage_transition_count: get_in(state, [:stage_transition_counts, state.stage]),
          stage_history_size: length(Map.get(state, :stage_history, []))
        })
    }

    intent_attrs = Map.put(event_attrs, :summary, "Requested transition to #{state.stage}")

    with {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
         {:ok, intent} <- RunLedger.prepare_entry("stage.transition.requested", intent_attrs),
         {:ok, confirmation} <- RunLedger.prepare_entry("stage.transition", event_attrs),
         state = record_last_agent_session(state, transition_metadata, confirmation.event_id),
         digest = snapshot_digest(state),
         intent = put_in(intent, [:metadata, :snapshot_digest], digest),
         confirmation = put_in(confirmation, [:metadata, :snapshot_digest], digest),
         :ok <- coordinator_deadline(coordinator_deadline),
         {:ok, _} <- RunLedger.persist_prepared(intent) do
      pending = %{
        operation_id: operation_id,
        ledger_path: ledger_path,
        intent_event_id: intent.event_id,
        confirmation: confirmation
      }

      with :ok <- save_unlocked(workspace, Map.put(state, :audit_pending, pending)),
           {:ok, _} <- RunLedger.persist_prepared(confirmation),
           {:ok, persisted} <- finalize_audited_transition(workspace, state, confirmation.event_id) do
        emit_transition(persisted)
        {:ok, persisted}
      end
    end
  end

  defp finalize_audited_transition(workspace, state, event_id) do
    persisted = state |> Map.delete(:audit_pending) |> Map.put(:last_ledger_event_id, event_id)
    with :ok <- write_json_atomically(state_path(workspace), persisted), do: {:ok, persisted}
  end

  defp emit_transition(state) do
    Observability.emit(
      [:symphony, :stage, :transition],
      %{count: 1},
      %{
        issue_id: Map.get(state, :issue_id),
        issue_identifier: Map.get(state, :issue_identifier),
        issue_source: Map.get(state, :issue_source),
        stage: state.stage,
        policy_class: Map.get(state, :effective_policy_class),
        stage_transition_count: get_in(state, [:stage_transition_counts, state.stage]),
        stage_history_size: length(Map.get(state, :stage_history, []))
      }
    )
  end

  @doc """
  Finalizes an interrupted transition only when both its intent and exact
  confirmation already exist in its original ledger. Missing or ambiguous
  evidence leaves the snapshot untouched; this never retries an audit write.
  """
  @spec reconcile_pending_transition(Path.t()) :: {:ok, map()} | {:error, term()}
  def reconcile_pending_transition(workspace) when is_binary(workspace) do
    with_workspace_lock(workspace, fn ->
      with {:ok, payload} <- File.read(state_path(workspace)),
           {:ok, decoded} <- Jason.decode(payload),
           {:ok, state, pending, confirmation} <- validate_pending_transition(decoded),
           {:ok, path} <- RunLedger.ledger_file_path_checked(),
           true <- path == pending["ledger_path"] or {:error, :audit_ledger_changed},
           {:ok, intent} <- RunLedger.fetch_entry_checked(pending["intent_event_id"]),
           :ok <- validate_transition_intent(intent, confirmation, pending),
           {:ok, recorded} <- RunLedger.fetch_entry_checked(confirmation["event_id"]),
           true <- recorded == confirmation or {:error, :audit_confirmation_mismatch} do
        finalize_audited_transition(workspace, atomize(state), confirmation["event_id"])
      end
    end)
  end

  defp validate_pending_transition(%{"audit_pending" => pending} = decoded) when is_map(pending) do
    state = Map.delete(decoded, "audit_pending")

    with %{
           "operation_id" => operation_id,
           "ledger_path" => ledger_path,
           "intent_event_id" => intent_id,
           "confirmation" =>
             %{
               "event_id" => event_id,
               "event_type" => "stage.transition",
               "stage" => stage,
               "metadata" => %{"operation_id" => operation_id, "snapshot_digest" => digest}
             } = confirmation
         } <- pending,
         true <- Enum.all?([operation_id, ledger_path, intent_id, event_id], &(is_binary(&1) and &1 != "")),
         true <- stage == state["stage"] and digest == snapshot_digest(state) do
      {:ok, state, pending, confirmation}
    else
      _ -> {:error, :invalid_audit_pending}
    end
  end

  defp validate_pending_transition(%{}), do: {:error, :no_audit_pending}
  defp validate_pending_transition(_), do: {:error, :invalid_state}

  defp validate_transition_intent(intent, confirmation, pending) do
    valid? =
      intent["event_type"] == "stage.transition.requested" and
        intent["event_id"] == pending["intent_event_id"] and
        intent["issue_id"] == confirmation["issue_id"] and
        intent["issue_identifier"] == confirmation["issue_identifier"] and
        intent["stage"] == confirmation["stage"] and
        intent["metadata"] == confirmation["metadata"]

    if valid?, do: :ok, else: {:error, :audit_intent_mismatch}
  end

  @doc "Canonical checksum shared by checked snapshot transitions and identity adoption."
  @spec snapshot_digest(map()) :: String.t()
  def snapshot_digest(state) do
    state
    |> Jason.encode!()
    |> Jason.decode!()
    |> canonical_snapshot()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_snapshot(value) when is_map(value),
    do: {:map, value |> Enum.map(fn {key, item} -> {key, canonical_snapshot(item)} end) |> Enum.sort()}

  defp canonical_snapshot(value) when is_list(value), do: Enum.map(value, &canonical_snapshot/1)
  defp canonical_snapshot(value), do: value

  @doc "Applies only confirmed review reply fields after a local owner has revalidated its control permission."
  @spec apply_review_publication(Path.t(), map(), map(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def apply_review_publication(workspace, %{id: id, identifier: identifier}, expected, patches, deadline)
      when is_binary(workspace) and is_map(expected) and is_map(patches) and is_integer(deadline) do
    with_workspace_lock(workspace, fn ->
      with :ok <- DeployAudit.ensure_available(workspace),
           {:ok, raw} <- read_canonical_snapshot(workspace),
           :ok <- publication_assert(raw["issue_id"] == id and raw["issue_identifier"] == identifier),
           :ok <-
             publication_assert(
               Map.take(raw, ~w(issue_id issue_identifier run_id run_identity_event_id run_identity_ledger_path)) ==
                 Map.take(expected, ~w(issue_id issue_identifier run_id run_identity_event_id run_identity_ledger_path)) and
                 coordinator_projection(raw) == coordinator_projection(expected)
             ),
           {:ok, threads} <- apply_publication_patches(raw["review_threads"], patches),
           updated =
             raw
             |> Map.put("review_threads", threads)
             |> Map.put("last_decision_summary", "Posted approved PR review replies.")
             |> Map.put("next_human_action", "Resolve the review threads once the reply has been acknowledged."),
           :ok <- write_coordinator_snapshot(workspace, updated, deadline) do
        {:ok, atomize(updated)}
      end
    end)
  end

  defp publication_assert(true), do: :ok
  defp publication_assert(false), do: {:error, :review_publication_snapshot_changed}

  defp apply_publication_patches(threads, patches) when is_map(threads) and map_size(patches) > 0 do
    Enum.reduce_while(patches, {:ok, threads}, fn {key, patch}, {:ok, updated} ->
      fields = ~w(draft_state posted_reply_id posted_reply_url posted_at reply_refresh_needed)

      valid =
        is_binary(key) and is_map(threads[key]) and is_map(patch) and
          MapSet.new(Map.keys(patch)) == MapSet.new(fields) and patch["draft_state"] == "posted" and
          patch["reply_refresh_needed"] == false and
          Enum.all?(~w(posted_reply_id posted_reply_url posted_at), &(is_binary(patch[&1]) and patch[&1] != ""))

      if valid,
        do: {:cont, {:ok, Map.update!(updated, key, &Map.merge(&1, patch))}},
        else: {:halt, {:error, :invalid_review_publication_patch}}
    end)
  end

  defp apply_publication_patches(_threads, _patches), do: {:error, :invalid_review_publication_patch}

  @spec update(Path.t(), (map() -> map())) :: {:ok, map()} | {:error, term()}
  def update(workspace, fun) when is_binary(workspace) and is_function(fun, 1) do
    with_workspace_lock(workspace, fn ->
      with {:ok, previous_state} <- load_for_update(workspace, %{}) do
        state = fun.(previous_state)

        case save_unlocked(workspace, state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  @doc "Synchronizes lease metadata without adding defaults to an existing matching snapshot."
  @spec sync_lease(Path.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def sync_lease(workspace, issue, lease_attrs)
      when is_binary(workspace) and is_map(issue) and is_map(lease_attrs) do
    with_workspace_lock(workspace, fn ->
      with {:ok, previous_state} <- load_for_lease_sync(workspace, issue) do
        state = apply_lease_attrs(previous_state, lease_attrs)

        case save_unlocked(workspace, state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp load_for_lease_sync(workspace, issue) do
    case load(workspace) do
      {:ok, state} ->
        if run_state_matches_issue?(state, issue),
          do: {:ok, state},
          else: {:ok, default_state(issue)}

      {:error, :missing} ->
        {:ok, default_state(issue)}

      {:error, reason} ->
        {:error, write_error(reason)}
    end
  end

  @spec clear_lease(Path.t()) :: {:ok, map()} | {:error, term()}
  def clear_lease(workspace) when is_binary(workspace) do
    update(workspace, &clear_lease_attrs/1)
  end

  @spec delete(Path.t()) :: :ok
  def delete(workspace) when is_binary(workspace) do
    File.rm(state_path(workspace))
    :ok
  end

  defp maybe_record_stage_transition(state, stage, reason, false) do
    state
    |> bump_stage_transition_count(stage)
    |> update_stage_history(stage, reason)
  end

  defp maybe_record_stage_transition(state, _stage, _reason, true), do: state

  defp update_stage_history(state, stage, reason) do
    entry = %{
      stage: stage,
      at: SymphonyElixir.Util.now_iso8601(),
      reason: reason
    }

    history =
      state
      |> Map.get(:stage_history, [])
      |> List.wrap()
      |> Kernel.++([entry])
      |> Enum.take(-@stage_history_limit)

    Map.put(state, :stage_history, history)
  end

  defp bump_stage_transition_count(state, stage) do
    stage_transition_counts =
      state
      |> Map.get(:stage_transition_counts, %{})
      |> Map.put(stage, Map.get(state |> Map.get(:stage_transition_counts, %{}), stage, 0) + 1)

    Map.put(state, :stage_transition_counts, stage_transition_counts)
  end

  defp default_state(issue) when is_map(issue) do
    issue |> state_defaults() |> ensure_runner_metadata()
  end

  defp state_defaults(issue) when is_map(issue) do
    %{
      issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      issue_source: Map.get(issue, :source) || Map.get(issue, "source"),
      runner_instance_id: nil,
      runner_instance_name: nil,
      runner_channel: nil,
      runner_runtime_version: nil,
      runner_workspace_root: nil,
      stage: "checkout",
      stage_history: [],
      stage_transition_counts: %{},
      implementation_turns: 0,
      validation_attempts: 0,
      verification_attempts: 0,
      publish_attempts: 0,
      await_checks_polls: 0,
      merge_attempts: 0,
      automerge_disabled: false,
      review_approved: false,
      merge_window_wait: nil,
      policy_override: nil,
      effective_policy_class: nil,
      effective_policy_source: nil,
      last_pr_state: nil,
      review_threads: %{},
      review_claims: %{},
      review_return_stage: nil,
      last_review_decision: nil,
      last_ci_failure: nil,
      last_check_statuses: [],
      last_required_checks_state: nil,
      last_missing_required_checks: [],
      last_pending_required_checks: [],
      last_failing_required_checks: [],
      last_cancelled_required_checks: [],
      acceptance_summary: nil,
      last_verifier_verdict: nil,
      last_harness_init: nil,
      last_harness_check: nil,
      harness_status: nil,
      harness_attempts: 0,
      resume_context: %{},
      last_decision: nil,
      last_rule_id: nil,
      last_failure_class: nil,
      last_decision_summary: nil,
      next_human_action: nil,
      last_ledger_event_id: nil,
      last_merge: nil,
      stop_reason: nil,
      lease_owner: nil,
      lease_owner_instance_id: nil,
      lease_owner_channel: nil,
      lease_acquired_at: nil,
      lease_updated_at: nil,
      lease_status: nil,
      lease_epoch: nil,
      lease_version: nil,
      lease_generation: nil
    }
  end

  defp merge_defaults(state, issue) when is_map(state) and is_map(issue) do
    defaults = state_defaults(issue)

    defaults
    |> Map.merge(state)
    |> Map.put(:issue_id, Map.get(state, :issue_id) || Map.get(defaults, :issue_id))
    |> Map.put(
      :issue_identifier,
      Map.get(state, :issue_identifier) || Map.get(defaults, :issue_identifier)
    )
    |> Map.put(
      :issue_source,
      Map.get(state, :issue_source) || Map.get(defaults, :issue_source)
    )
    |> ensure_runner_metadata()
  end

  defp write_json_atomically(path, payload) when is_binary(path) and is_map(payload) do
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, Jason.encode!(payload), [:write]),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp_path)
        error
    end
  end

  defp ensure_runner_metadata(state) when is_map(state) do
    state
    |> put_missing(:runner_instance_id, &Config.runner_instance_id/0)
    |> put_missing(:runner_instance_name, &Config.runner_instance_name/0)
    |> put_missing(:runner_channel, &Config.runner_channel/0)
    |> put_missing(:runner_runtime_version, &RunnerRuntime.runtime_version/0)
    |> put_missing(:runner_workspace_root, &Config.workspace_root/0)
  end

  defp apply_lease_attrs(state, lease_attrs) when is_map(state) and is_map(lease_attrs) do
    lease = normalize_lease_attrs(lease_attrs)

    state
    |> Map.put(:lease_owner, Map.get(lease, :lease_owner))
    |> Map.put(:lease_owner_instance_id, Map.get(lease, :lease_owner_instance_id))
    |> Map.put(:lease_owner_channel, Map.get(lease, :lease_owner_channel))
    |> Map.put(:lease_acquired_at, Map.get(lease, :lease_acquired_at))
    |> Map.put(:lease_updated_at, Map.get(lease, :lease_updated_at))
    |> Map.put(:lease_status, Map.get(lease, :lease_status) || "held")
    |> Map.put(:lease_epoch, Map.get(lease, :lease_epoch))
    |> Map.put(:lease_version, Map.get(lease, :lease_version))
    |> Map.put(:lease_generation, Map.get(lease, :lease_generation))
  end

  defp clear_lease_attrs(state) when is_map(state) do
    state
    |> Map.put(:lease_owner, nil)
    |> Map.put(:lease_owner_instance_id, nil)
    |> Map.put(:lease_owner_channel, nil)
    |> Map.put(:lease_acquired_at, nil)
    |> Map.put(:lease_updated_at, nil)
    |> Map.put(:lease_status, nil)
    |> Map.put(:lease_epoch, nil)
    |> Map.put(:lease_version, nil)
    |> Map.put(:lease_generation, nil)
  end

  defp normalize_lease_attrs(lease_attrs) when is_map(lease_attrs) do
    %{
      lease_owner:
        Map.get(lease_attrs, :lease_owner) || Map.get(lease_attrs, "lease_owner") ||
          Map.get(lease_attrs, :owner) || Map.get(lease_attrs, "owner"),
      lease_owner_instance_id:
        Map.get(lease_attrs, :lease_owner_instance_id) ||
          Map.get(lease_attrs, "lease_owner_instance_id"),
      lease_owner_channel: Map.get(lease_attrs, :lease_owner_channel) || Map.get(lease_attrs, "lease_owner_channel"),
      lease_acquired_at:
        Map.get(lease_attrs, :lease_acquired_at) || Map.get(lease_attrs, "lease_acquired_at") ||
          Map.get(lease_attrs, :acquired_at) || Map.get(lease_attrs, "acquired_at"),
      lease_updated_at:
        Map.get(lease_attrs, :lease_updated_at) || Map.get(lease_attrs, "lease_updated_at") ||
          Map.get(lease_attrs, :updated_at) || Map.get(lease_attrs, "updated_at"),
      lease_version: Map.get(lease_attrs, :lease_version) || Map.get(lease_attrs, "lease_version"),
      lease_generation: Map.get(lease_attrs, :lease_generation) || Map.get(lease_attrs, "lease_generation"),
      lease_status: Map.get(lease_attrs, :lease_status) || Map.get(lease_attrs, "lease_status"),
      lease_epoch:
        Map.get(lease_attrs, :lease_epoch) || Map.get(lease_attrs, "lease_epoch") ||
          Map.get(lease_attrs, :epoch) || Map.get(lease_attrs, "epoch")
    }
  end

  defp put_missing(state, key, value) when is_map(state) and is_function(value, 0) do
    case Map.get(state, key) do
      existing when existing in [nil, ""] -> Map.put(state, key, value.())
      _existing -> state
    end
  end

  defp run_state_matches_issue?(state, issue) when is_map(state) and is_map(issue) do
    state_id = Map.get(state, :issue_id)
    state_identifier = Map.get(state, :issue_identifier)
    issue_id = Map.get(issue, :id) || Map.get(issue, "id")
    issue_identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")

    cond do
      not present?(issue_id) and not present?(issue_identifier) ->
        true

      present?(state_id) ->
        state_id == issue_id

      present?(state_identifier) ->
        state_identifier == issue_identifier

      true ->
        true
    end
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value)

  defp atomize(map) when is_map(map) do
    if preserve_string_keys_map?(map) do
      Map.new(map, fn {key, value} ->
        {key, preserve_string_keys_value(value)}
      end)
    else
      Map.new(map, fn
        {"stage_transition_counts", counts} -> {:stage_transition_counts, counts}
        {key, value} -> {atom_key(key), atomize_value(value)}
      end)
    end
  end

  defp atomize_value(value) when is_map(value), do: atomize(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value

  defp preserve_string_keys_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {key, preserve_string_keys_value(nested_value)}
    end)
  end

  defp preserve_string_keys_value(value) when is_list(value),
    do: Enum.map(value, &preserve_string_keys_value/1)

  defp preserve_string_keys_value(value), do: value

  defp atom_key(key) when is_binary(key) do
    if atomizable_key?(key) do
      String.to_existing_atom(key)
    else
      key
    end
  rescue
    ArgumentError ->
      if atomizable_key?(key) do
        String.to_atom(key)
      else
        key
      end
  end

  defp atomizable_key?(key) when is_binary(key) do
    String.match?(key, ~r/^[a-z_][a-zA-Z0-9_]*[!?]?$/)
  end

  defp preserve_string_keys_map?(map) when is_map(map) do
    Enum.any?(Map.keys(map), fn
      key when is_binary(key) -> not atomizable_key?(key)
      _ -> false
    end)
  end
end
