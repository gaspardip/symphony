defmodule SymphonyElixir.ReviewPublication do
  @moduledoc """
  Durable review publication attempts shared by operator and execution callers.

  Location and history are evidence, never permission. Callers retain owner/AE
  authority; each transport is preceded by a current check and followed by a
  checked observation before continuation. Nothing retries a remote effect.
  """

  require Logger
  alias SymphonyElixir.{AgentExecution, Config, PRWatcher, RunIdentity, RunLedger, RunStateStore, Workspace}
  alias SymphonyElixir.RunLedger.{CheckedStorage, PersistenceError}

  @binding ~w(run_id run_identity_event_id run_identity_ledger_path)
  @identity ~w(issue_id issue_identifier run_id run_identity_event_id run_identity_ledger_path)
  @location_keys ~w(publication_version issue_id issue_identifier workspace_root workspace ledger_path location_event_id)
  @common ~w(publication_version location_event_id workspace pr_url pr_identity pr_source raw_pr thread_key operation reply_target draft_sha256 binding dispatch_id)
  @intent_keys @common ++ ["observation_event_id"]
  @observation_keys @common ++ ~w(intent_event_id outcome cause posted_reply_id posted_reply_url posted_at)
  @types ~w(review.publication.location review.publication.intent review.publication.observed)

  @type control_precondition :: %{kind: :control, context: map(), deadline: integer(), expected: map(), caller: pid()}
  @type permission :: :execution | control_precondition()
  @type failure :: {:error, term()} | AgentExecution.terminal()

  @doc "Publishes eligible replies one at a time, or rediscovers the original confirmed IDs."
  @spec publish(Path.t(), map(), String.t(), map(), permission(), keyword()) ::
          {:ok, map(), map()} | failure()
  def publish(workspace, issue, pr_url, threads, permission, opts)
      when is_binary(workspace) and is_map(issue) and is_binary(pr_url) and is_map(threads) do
    with {:ok, captured} <- capture(workspace, issue, permission),
         {:ok, pr_identity} <- pr_identity(pr_url),
         :ok <- require_fact(valid_raw_pr?(Map.take(captured.raw, ["pr_url"])), :invalid_raw_pr),
         :ok <- captured_pr_matches(captured, pr_url),
         captured = Map.merge(captured, %{pr_identity: pr_identity, pr_source: if(permission == :execution, do: "caller_result", else: "raw")}),
         :ok <- current(captured) do
      Enum.reduce_while(threads, {:ok, threads, %{posted_count: 0, skipped_count: 0, reconciled_count: 0, observation_ids: []}}, fn {key, thread}, {:ok, updated, stats} ->
        with :ok <- current(captured),
             {:ok, request} <- PRWatcher.prepare_review_reply(pr_url, key, thread, opts),
             {:ok, location} <- location(captured),
             {:ok, result, observation} <- publish_one(captured, location, to_string(key), thread, request) do
          case result do
            {:posted, next} -> {:cont, {:ok, Map.put(updated, key, next), count(stats, :posted_count, observation)}}
            {:reconciled, next} -> {:cont, {:ok, Map.put(updated, key, next), count(stats, :reconciled_count, observation)}}
            :returned_error -> {:cont, {:ok, updated, count(stats, :skipped_count, observation)}}
          end
        else
          :skip -> {:cont, {:ok, updated, %{stats | skipped_count: stats.skipped_count + 1}}}
          failure -> {:halt, failure}
        end
      end)
      |> case do
        {:ok, updated, stats} when stats.posted_count + stats.reconciled_count > 0 -> {:ok, updated, stats}
        {:ok, _updated, _stats} -> {:error, :no_postable_review_threads}
        failure -> failure
      end
    end
  end

  defp count(stats, key, observation) do
    stats |> Map.update!(key, &(&1 + 1)) |> Map.update!(:observation_ids, &(&1 ++ [observation["event_id"]]))
  end

  defp capture(workspace, issue, permission) do
    with :ok <- permission_current(workspace, issue, permission),
         {:ok, {:present, raw}, _view} <- RunStateStore.read_admission_source(workspace, issue),
         :ok <- require_fact(Path.expand(workspace) == workspace, :workspace_changed),
         {:ok, ledger_path} <- RunLedger.ledger_file_path_checked(),
         :ok <- verify_binding(workspace, issue, raw),
         :ok <- captured_control_matches(permission, raw),
         {:ok, dispatch_id} <- dispatch_identity(workspace, issue, permission) do
      {:ok, %{workspace: workspace, issue: issue, permission: permission, raw: raw, ledger_path: ledger_path, dispatch_id: dispatch_id, binding: Map.take(raw, @binding)}}
    else
      {:ok, :missing, _view} -> blocked(:snapshot_missing)
      failure -> failure
    end
  end

  # Delivery can have a newly confirmed PR before its next state CAS. Its caller
  # value is captured as provenance; it neither replaces RAW nor grants permission.
  defp captured_pr_matches(%{permission: :execution}, _pr_url), do: :ok
  defp captured_pr_matches(captured, pr_url), do: require_fact(captured.raw["pr_url"] == pr_url, :pr_changed)

  defp pr_identity(url) do
    case URI.parse(url) do
      %URI{host: "github.com", path: path} when is_binary(path) ->
        case String.split(path, "/", trim: true) do
          [owner, repo, "pull", number | _] ->
            case Integer.parse(number) do
              {value, ""} when value > 0 ->
                {:ok, %{"host" => "github.com", "owner" => String.downcase(owner), "repo" => String.downcase(repo), "number" => value}}

              _ ->
                blocked(:invalid_pr_identity)
            end

          _ ->
            blocked(:invalid_pr_identity)
        end

      _ ->
        blocked(:invalid_pr_identity)
    end
  end

  defp captured_control_matches(%{kind: :control, expected: expected}, raw), do: compare_raw(expected, raw, :control)
  defp captured_control_matches(:execution, _raw), do: :ok

  defp current(captured) do
    with :ok <- permission_current(captured.workspace, captured.issue, captured.permission),
         {:ok, path} <- RunLedger.ledger_file_path_checked(),
         :ok <- require_fact(path == captured.ledger_path, :location_changed),
         {:ok, {:present, raw}, _view} <- RunStateStore.read_admission_source(captured.workspace, captured.issue),
         :ok <- verify_binding(captured.workspace, captured.issue, raw),
         :ok <- compare_raw(captured.raw, raw, captured.permission),
         :ok <- caller_current(captured.permission),
         :ok <- before_deadline(deadline(captured)) do
      :ok
    else
      {:ok, :missing, _view} -> blocked(:snapshot_missing)
      failure -> failure
    end
  end

  defp compare_raw(expected, raw, permission) do
    project = if permission == :execution, do: &RunStateStore.material_projection/1, else: &RunStateStore.coordinator_projection/1
    require_fact(Map.take(expected, @identity) == Map.take(raw, @identity) and project.(expected) == project.(raw), :material_changed)
  end

  defp permission_current(workspace, issue, :execution) do
    case AgentExecution.entry_context(workspace, issue) do
      {:ok, _context} -> :ok
      terminal -> terminal
    end
  end

  defp permission_current(workspace, issue, %{kind: :control, context: context, deadline: deadline} = permission) do
    with :ok <- caller_current(permission),
         :ok <- before_deadline(deadline),
         :ok <- Config.validate!(),
         :ok <- require_fact(Config.tracker_read_context().fingerprint == context.fingerprint and Workspace.path_for_issue(issue.identifier) == workspace, :control_invalidated),
         :ok <- caller_current(permission),
         :ok <- before_deadline(deadline),
         do: :ok
  rescue
    _error in NimbleOptions.ValidationError -> blocked(:control_invalidated)
  end

  defp caller_current(:execution), do: :ok

  defp caller_current(%{kind: :control, caller: caller}) when is_pid(caller) and node(caller) == node(),
    do: require_fact(Process.alive?(caller), :control_invalidated)

  defp dispatch_identity(workspace, issue, :execution) do
    case AgentExecution.entry_context(workspace, issue) do
      {:ok, :legacy} -> {:ok, nil}
      {:ok, %{ticket: ticket}} -> {:ok, ticket.dispatch_id}
      terminal -> terminal
    end
  end

  defp dispatch_identity(_workspace, _issue, %{kind: :control}), do: {:ok, nil}

  defp verify_binding(workspace, issue, raw) do
    with :ok <- RunIdentity.validate_snapshot(raw) do
      if Map.has_key?(raw, "run_id"),
        do: RunIdentity.verify(workspace, raw["run_id"], issue.id, issue.identifier),
        else: :ok
    end
  end

  defp deadline(%{permission: %{kind: :control, deadline: deadline}}), do: deadline
  defp deadline(%{permission: :execution}), do: :not_pending
  defp before_deadline(:not_pending), do: :ok
  defp before_deadline(deadline), do: require_fact(System.monotonic_time(:millisecond) < deadline, :control_deadline_exceeded)

  defp location(captured) do
    root = Path.dirname(captured.workspace)
    name = ".review-publication-" <> digest(captured.issue.id) <> ".json"
    path = Path.join(root, name)

    case File.read(path) do
      {:ok, bytes} -> validate_location(bytes, captured, name)
      {:error, :enoent} -> create_location(path, name, captured)
      {:error, reason} -> storage_error(:review_location_read, nil, :uncertain, reason)
    end
  end

  defp create_location(path, name, captured) do
    metadata = %{"publication_version" => 1, "workspace_root" => Path.dirname(captured.workspace), "workspace" => captured.workspace, "ledger_path" => captured.ledger_path, "anchor_name" => name}

    with :ok <- current(captured),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.dirname(captured.workspace)),
         {:ok, event} <- RunLedger.prepare_entry("review.publication.location", event_attrs(captured, metadata)),
         anchor = metadata |> Map.delete("anchor_name") |> Map.merge(%{"issue_id" => captured.issue.id, "issue_identifier" => captured.issue.identifier, "location_event_id" => event.event_id}),
         {:ok, bytes} <- Jason.encode(anchor),
         :ok <- before_deadline(deadline(captured)) do
      case create_anchor(path, bytes <> "\n", event.event_id) do
        :ok ->
          with :ok <- current(captured),
               {:ok, _} <- CheckedStorage.persist(event, captured.ledger_path),
               do: validate_location(bytes, captured, name)

        {:error, %PersistenceError{phase: :review_location_open, reason: :eexist}} ->
          with {:ok, existing} <- File.read(path), do: validate_location(existing, captured, name)

        failure ->
          failure
      end
    else
      {:ok, %File.Stat{}} -> blocked(:invalid_workspace_root)
      failure -> failure
    end
  end

  defp create_anchor(path, bytes, id) do
    case :file.open(String.to_charlist(path), [:write, :exclusive, :binary, :raw]) do
      {:ok, file} ->
        result = checked_outcome(fn -> write_anchor_bytes(file, bytes) end)
        closed = :file.close(file)

        case {result, closed} do
          {:ok, :ok} ->
            :ok

          {{:error, phase, reason}, :ok} ->
            storage_error(phase, id, :uncertain, reason)

          {:ok, {:error, reason}} ->
            storage_error(:review_location_close, id, :uncertain, reason)

          {{:error, phase, reason}, {:error, cleanup}} ->
            {:error, %PersistenceError{phase: phase, event_id: id, confirmation: :uncertain, reason: reason, cleanup_errors: [close: cleanup]}}

          {{:raised, kind, reason, stack}, close_result} ->
            if close_result != :ok, do: Logger.error("Review location descriptor close failed after an exception event_id=#{id}")
            :erlang.raise(kind, reason, stack)
        end

      {:error, reason} ->
        storage_error(:review_location_open, id, :not_confirmed, reason)
    end
  end

  defp write_anchor_bytes(file, bytes) do
    case :file.write(file, bytes) do
      :ok ->
        case :file.sync(file) do
          :ok -> :ok
          {:error, reason} -> {:error, :review_location_sync, reason}
        end

      {:error, reason} ->
        {:error, :review_location_write, reason}
    end
  end

  defp validate_location(bytes, captured, name) do
    with {:ok, anchor} <- Jason.decode(bytes),
         :ok <- require_fact(is_map(anchor) and exact_keys?(anchor, @location_keys), :invalid_location),
         :ok <-
           require_fact(
             anchor["publication_version"] == 1 and anchor["workspace_root"] == Path.dirname(captured.workspace) and
               anchor["workspace"] == captured.workspace and anchor["issue_id"] == captured.issue.id and
               anchor["issue_identifier"] == captured.issue.identifier and anchor["ledger_path"] == captured.ledger_path and nonempty?(anchor["location_event_id"]),
             :location_changed
           ),
         {:ok, rows, _fingerprint} <- CheckedStorage.entries_checked(captured.ledger_path),
         row = Enum.find(rows, &(&1["event_id"] == anchor["location_event_id"])),
         metadata = anchor |> Map.drop(~w(issue_id issue_identifier location_event_id)) |> Map.put("anchor_name", name),
         :ok <-
           require_fact(
             is_map(row) and row["event_type"] == "review.publication.location" and
               row["issue_id"] == captured.issue.id and row["issue_identifier"] == captured.issue.identifier and row["metadata"] == metadata,
             :location_unconfirmed
           ) do
      {:ok, anchor}
    else
      {:error, %Jason.DecodeError{}} -> blocked(:invalid_location)
      failure -> failure
    end
  end

  defp publish_one(captured, location, key, thread, request) do
    with {:ok, rows, fingerprint} <- CheckedStorage.entries_checked(captured.ledger_path),
         :ok <- validate_history(rows),
         {:ok, decision} <- decide(rows, captured, key, request) do
      case decision do
        {:reconcile, observed} ->
          with :ok <- current(captured), do: {:ok, {:reconciled, posted_thread(thread, observed)}, observed}

        :new ->
          start_attempt(captured, location, key, thread, request, fingerprint)
      end
    end
  end

  defp start_attempt(captured, location, key, thread, request, fingerprint) do
    identity = %{
      "publication_version" => 1,
      "location_event_id" => location["location_event_id"],
      "workspace" => captured.workspace,
      "pr_url" => request.pr_url,
      "pr_identity" => captured.pr_identity,
      "pr_source" => captured.pr_source,
      "raw_pr" => Map.take(captured.raw, ["pr_url"]),
      "thread_key" => key,
      "operation" => Atom.to_string(request.operation),
      "reply_target" => request.target,
      "draft_sha256" => digest(request.body),
      "binding" => captured.binding,
      "dispatch_id" => captured.dispatch_id
    }

    with {:ok, observation} <- RunLedger.prepare_entry("review.publication.observed", event_attrs(captured, %{})),
         {:ok, intent} <- RunLedger.prepare_entry("review.publication.intent", event_attrs(captured, Map.put(identity, "observation_event_id", observation.event_id))),
         :ok <- current(captured),
         {:ok, _} <- CheckedStorage.persist_if_current(intent, captured.ledger_path, fingerprint, deadline(captured)),
         :ok <- current(captured) do
      result =
        try do
          {:returned, PRWatcher.execute_review_reply(request)}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      observed = checked_outcome(fn -> observe(captured, intent, observation.event_id, identity, result) end)
      permission = checked_outcome(fn -> current(captured) end)
      finish_result(result, observed, permission, thread)
    end
  end

  defp observe(captured, intent, id, identity, result) do
    {outcome, cause, reply_id, reply_url} = result_fields(result)

    with {:ok, prepared} <- RunLedger.prepare_entry("review.publication.observed", event_attrs(captured, %{})) do
      metadata =
        Map.merge(identity, %{
          "intent_event_id" => intent.event_id,
          "outcome" => outcome,
          "cause" => cause,
          "posted_reply_id" => reply_id,
          "posted_reply_url" => reply_url,
          "posted_at" => if(outcome == "returned_success", do: prepared.at, else: nil)
        })

      entry = %{prepared | event_id: id, metadata: metadata}

      with {:ok, rows, fingerprint} <- CheckedStorage.entries_checked(captured.ledger_path),
           :ok <- validate_history(rows),
           :ok <- require_fact(Enum.any?(rows, &(&1 == canonical(intent))), :intent_unconfirmed),
           {:ok, _} <- CheckedStorage.persist_if_current(entry, captured.ledger_path, fingerprint, :not_pending),
           do: {:ok, canonical(entry)}
    end
  end

  defp result_fields({:returned, {:ok, %{id: id, url: url}}}) when is_binary(id) and id != "" and is_binary(url) and url != "",
    do: {"returned_success", nil, id, url}

  defp result_fields({:returned, {:error, _reason}}), do: {"returned_error", "backend_error", nil, nil}
  defp result_fields({:raised, kind, _reason, _stack}), do: {"raised", Atom.to_string(kind), nil, nil}

  defp result_fields({:returned, {:ok, reply}}) when is_map(reply),
    do: {"invalid_result", "invalid_reply", usable_id(reply[:id]), usable_id(reply[:url])}

  defp result_fields(_result), do: {"invalid_result", "invalid_reply", nil, nil}
  defp usable_id(value) when is_binary(value) and value != "", do: value
  defp usable_id(_value), do: nil

  # Capture secondary exceptions only to preserve an original transport exception.
  # Every captured exception is logged safely and re-raised, never a fallback.
  defp checked_outcome(fun) do
    fun.()
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp finish_result({:raised, kind, reason, stack}, observed, permission, _thread) do
    report_secondary(observed)
    report_secondary_permission(permission)
    :erlang.raise(kind, reason, stack)
  end

  defp finish_result(_result, {:raised, kind, reason, stack}, _permission, _thread), do: :erlang.raise(kind, reason, stack)

  defp finish_result(_result, observed, {:raised, kind, reason, stack}, _thread) do
    report_secondary(observed)
    :erlang.raise(kind, reason, stack)
  end

  defp finish_result(_result, observed, {:stop, _} = terminal, _thread) do
    report_secondary(observed)
    terminal
  end

  defp finish_result(_result, {:error, _} = failure, _permission, _thread), do: failure
  defp finish_result(_result, {:ok, _observed}, {:error, _} = failure, _thread), do: failure

  defp finish_result(_result, {:ok, observed}, :ok, thread) do
    case observed["metadata"]["outcome"] do
      "returned_success" -> {:ok, {:posted, posted_thread(thread, observed)}, observed}
      "returned_error" -> {:ok, :returned_error, observed}
      _ -> blocked(:attempt_uncertain, observed["metadata"]["intent_event_id"])
    end
  end

  defp report_secondary_permission({:raised, _kind, _reason, _stack}), do: Logger.error("Review publication permission check raised after transport exception")
  defp report_secondary_permission(_outcome), do: :ok
  defp report_secondary({:raised, _kind, _reason, _stack}), do: Logger.error("Review publication observation raised after transport exception")
  defp report_secondary({:ok, _}), do: :ok

  defp report_secondary({:error, %PersistenceError{phase: phase, event_id: id}}),
    do: Logger.error("Review publication observation failed phase=#{phase} event_id=#{id}")

  defp report_secondary({:error, _}), do: Logger.error("Review publication observation failed domain=checked_history")

  defp posted_thread(thread, observed) do
    metadata = observed["metadata"]

    thread
    |> Map.put("draft_state", "posted")
    |> Map.put("posted_reply_id", metadata["posted_reply_id"])
    |> Map.put("posted_reply_url", metadata["posted_reply_url"])
    |> Map.put("posted_at", metadata["posted_at"])
    |> Map.put("reply_refresh_needed", false)
  end

  defp decide(rows, captured, key, request) do
    intents = Enum.filter(rows, &(&1["event_type"] == "review.publication.intent" and &1["issue_id"] == captured.issue.id))
    pairs = Enum.map(intents, fn intent -> {intent, Enum.find(rows, &(&1["event_id"] == intent["metadata"]["observation_event_id"]))} end)
    uncertain = Enum.find(pairs, fn {_intent, observed} -> not successful?(observed) end)
    conflict = Enum.find(pairs, fn {intent, _} -> intent["metadata"]["thread_key"] == key and intent["metadata"]["pr_identity"] != captured.pr_identity end)
    same = Enum.filter(pairs, fn {intent, _} -> intent["metadata"]["thread_key"] == key and intent["metadata"]["pr_identity"] == captured.pr_identity end)

    cond do
      uncertain != nil ->
        blocked(:attempt_uncertain, elem(uncertain, 0)["event_id"])

      conflict != nil ->
        blocked(:resource_changed, elem(conflict, 0)["event_id"])

      same == [] ->
        validate_new_target(captured, key, request)

      true ->
        {intent, observed} = List.last(same)
        metadata = intent["metadata"]

        cond do
          metadata["binding"] != captured.binding -> blocked(:binding_changed, intent["event_id"])
          metadata["draft_sha256"] == digest(request.body) -> {:ok, {:reconcile, observed}}
          request.operation == :edit and request.target == observed["metadata"]["posted_reply_id"] -> {:ok, :new}
          true -> blocked(:reply_already_posted, intent["event_id"])
        end
    end
  end

  defp validate_new_target(captured, key, %{operation: :post}) do
    previous = get_in(captured.raw, ["review_threads", key, "posted_reply_id"])
    if previous == nil, do: {:ok, :new}, else: blocked(:reply_already_posted)
  end

  defp validate_new_target(captured, key, %{operation: :edit, target: target}) do
    previous = get_in(captured.raw, ["review_threads", key, "posted_reply_id"])
    if nonempty?(target) and previous == target, do: {:ok, :new}, else: blocked(:reply_target_changed)
  end

  defp successful?(%{"metadata" => %{"outcome" => "returned_success", "posted_reply_id" => id, "posted_reply_url" => url}}), do: nonempty?(id) and nonempty?(url)
  defp successful?(_), do: false

  defp validate_history(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, known} ->
      type = row["event_type"]

      if is_binary(type) and String.starts_with?(type, "review.publication.") do
        if valid_row?(row, known), do: {:cont, {:ok, Map.put(known, row["event_id"], row)}}, else: {:halt, blocked(:invalid_history)}
      else
        {:cont, {:ok, known}}
      end
    end)
    |> case do
      {:ok, _known} -> :ok
      failure -> failure
    end
  end

  defp valid_row?(row, known) do
    metadata = row["metadata"]

    envelope =
      row["schema_version"] == 1 and row["event"] == row["event_type"] and row["event_type"] in @types and
        nonempty?(row["event_id"]) and valid_time?(row["at"]) and nonempty?(row["issue_id"]) and nonempty?(row["issue_identifier"]) and is_map(metadata)

    envelope and metadata["publication_version"] == 1 and valid_row_body?(row, known)
  end

  defp valid_row_body?(%{"event_type" => "review.publication.location", "metadata" => metadata}, _known) do
    exact_keys?(metadata, ~w(publication_version workspace_root workspace ledger_path anchor_name)) and
      Enum.all?(~w(workspace_root workspace ledger_path anchor_name), &nonempty?(metadata[&1]))
  end

  defp valid_row_body?(%{"event_type" => "review.publication.intent", "metadata" => metadata} = row, known) do
    location = known[metadata["location_event_id"]]

    exact_keys?(metadata, @intent_keys) and valid_common?(metadata) and nonempty?(metadata["observation_event_id"]) and
      metadata["observation_event_id"] != row["event_id"] and is_map(location) and location["event_type"] == "review.publication.location" and
      same_issue?(row, location) and metadata["workspace"] == location["metadata"]["workspace"]
  end

  defp valid_row_body?(%{"event_type" => "review.publication.observed", "metadata" => metadata} = row, known) do
    intent = known[metadata["intent_event_id"]]

    exact_keys?(metadata, @observation_keys) and valid_common?(metadata) and is_map(intent) and intent["event_type"] == "review.publication.intent" and
      same_issue?(row, intent) and intent["metadata"]["observation_event_id"] == row["event_id"] and
      Map.take(metadata, @common) == Map.take(intent["metadata"], @common) and valid_outcome?(metadata) and
      (metadata["outcome"] != "returned_success" or metadata["posted_at"] == row["at"])
  end

  defp valid_common?(metadata) do
    binding = metadata["binding"]

    Enum.all?(~w(location_event_id workspace pr_url thread_key reply_target draft_sha256), &nonempty?(metadata[&1])) and
      pr_identity(metadata["pr_url"]) == {:ok, metadata["pr_identity"]} and
      metadata["pr_source"] in ["raw", "caller_result"] and valid_raw_pr?(metadata["raw_pr"]) and
      byte_size(metadata["draft_sha256"]) == 64 and String.match?(metadata["draft_sha256"], ~r/\A[0-9a-f]+\z/) and
      metadata["operation"] in ["post", "edit"] and (is_nil(metadata["dispatch_id"]) or nonempty?(metadata["dispatch_id"])) and
      is_map(binding) and (binding == %{} or (exact_keys?(binding, @binding) and Enum.all?(Map.values(binding), &nonempty?/1)))
  end

  defp valid_raw_pr?(raw) when is_map(raw) and map_size(raw) == 0, do: true

  defp valid_raw_pr?(%{"pr_url" => value} = raw) when map_size(raw) == 1 do
    value in [nil, ""] or (is_binary(value) and match?({:ok, _}, pr_identity(value)))
  end

  defp valid_raw_pr?(_raw), do: false
  defp valid_time?(at) when is_binary(at), do: match?({:ok, _, _}, DateTime.from_iso8601(at))
  defp valid_time?(_at), do: false

  defp valid_outcome?(%{"outcome" => "returned_success", "cause" => nil, "posted_reply_id" => id, "posted_reply_url" => url, "posted_at" => at}), do: nonempty?(id) and nonempty?(url) and nonempty?(at)

  defp valid_outcome?(%{"outcome" => "invalid_result", "cause" => "invalid_reply", "posted_reply_id" => id, "posted_reply_url" => url, "posted_at" => nil}),
    do: (is_nil(id) or nonempty?(id)) and (is_nil(url) or nonempty?(url))

  defp valid_outcome?(%{"outcome" => outcome, "cause" => cause, "posted_reply_id" => nil, "posted_reply_url" => nil, "posted_at" => nil}) do
    {outcome, cause} in [{"returned_error", "backend_error"}, {"invalid_result", "invalid_reply"}, {"raised", "error"}, {"raised", "throw"}, {"raised", "exit"}]
  end

  defp valid_outcome?(_), do: false
  defp same_issue?(a, b), do: a["issue_id"] == b["issue_id"] and a["issue_identifier"] == b["issue_identifier"]
  defp event_attrs(captured, metadata), do: %{issue_id: captured.issue.id, issue_identifier: captured.issue.identifier, metadata: metadata}
  defp exact_keys?(map, keys), do: MapSet.new(Map.keys(map)) == MapSet.new(keys)
  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  defp canonical(map), do: map |> Jason.encode!() |> Jason.decode!()
  defp nonempty?(value), do: is_binary(value) and value != ""
  defp require_fact(true, _cause), do: :ok
  defp require_fact(false, cause), do: blocked(cause)
  defp blocked(cause, id \\ nil), do: {:error, {:review_publication_blocked, cause, id}}
  defp storage_error(phase, id, confirmation, reason), do: {:error, %PersistenceError{phase: phase, event_id: id, confirmation: confirmation, reason: reason}}
end
