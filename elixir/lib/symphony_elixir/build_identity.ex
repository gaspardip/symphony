defmodule SymphonyElixir.BuildIdentity do
  @moduledoc """
  Local, unsigned build provenance. Startup capture is immutable for this VM.

  `summary/0` is a precomputed diagnostic, not a current verification. Fresh disk
  and memory observations are explicit worker operations, never coordinator reads.
  No API loads, purges or repairs code, builds receipts, or changes dispatch policy.
  """

  @capture_key {__MODULE__, :startup}
  @missing %{"capture_status" => "not_captured", "basis" => "startup_capture"}
  @manifest_entry "symphony_elixir/priv/build_identity.json"
  @json_limit 4 * 1024 * 1024
  @archive_limit 64 * 1024 * 1024
  @expanded_limit 128 * 1024 * 1024
  @entry_limit 16 * 1024 * 1024
  @source_limit 64 * 1024 * 1024
  @max_modules 10_000
  @max_scope 256

  @doc "Called only by Application.start before children. Repeated starts retain the original capture."
  @spec capture_startup() :: :ok
  def capture_startup do
    case :persistent_term.get(@capture_key, :not_captured) do
      :not_captured ->
        captured_at = now()
        process = %{"os_pid" => System.pid(), "node" => Atom.to_string(node()), "vm_start" => :erlang.system_info(:start_time)}
        location = locate()
        result = startup(location)
        summary = startup_summary(result, captured_at, process)
        record = %{result: result, location: location, captured_at: captured_at, process: process}
        :persistent_term.put(@capture_key, %{record: record, summary: summary})
        :ok

      _captured ->
        :ok
    end
  end

  @doc "O(1), no IO, hashing, enumeration, writing or implicit initialization."
  @spec summary() :: map()
  def summary do
    case :persistent_term.get(@capture_key, :not_captured) do
      :not_captured -> @missing
      %{summary: summary} -> summary
    end
  end

  @spec capture() :: {:ok, map()} | {:error, :not_captured}
  def capture do
    case :persistent_term.get(@capture_key, :not_captured) do
      :not_captured -> {:error, :not_captured}
      %{record: record} -> {:ok, record}
    end
  end

  @doc "Observe only an explicit, bounded scope of known module atoms. Does not load modules."
  @spec inspect_loaded([module()]) :: map()
  def inspect_loaded(required_modules) do
    with {:ok, %{result: {:ok, baseline}}} <- capture(),
         :ok <- validate_scope(required_modules, baseline.index) do
      results = Enum.map(required_modules, &observe_module(&1, Map.fetch!(baseline.index, Atom.to_string(&1))))

      %{
        "observed_at" => now(),
        "scope" => Enum.map(required_modules, &Atom.to_string/1),
        "results" => results,
        "status" => if(Enum.all?(results, &(&1["status"] == "matched")), do: "matched", else: "incomplete")
      }
    else
      {:ok, %{result: {:error, reason}}} -> inspection_error(reason)
      {:error, reason} -> inspection_error(reason)
    end
  end

  @doc "Explicit bounded disk check of the captured location. Never updates the baseline."
  @spec inspect_artifact() :: map()
  def inspect_artifact do
    with {:ok, %{result: result, location: {:ok, location}}} <- capture(),
         {:ok, current} <- read_location(location) do
      status =
        case result do
          {:ok, baseline} -> if artifact_binding(current) == artifact_binding(baseline), do: "unchanged", else: "disk_artifact_changed"
          {:error, _reason} -> "baseline_unavailable"
        end

      %{"observed_at" => now(), "status" => status, "build_id" => current.manifest["build_id"], "mode" => current.location.mode}
    else
      {:ok, %{result: {:error, reason}}} -> inspection_error(reason)
      {:error, reason} -> inspection_error(reason)
    end
  end

  defp startup(location_result) do
    with {:ok, location} <- location_result,
         {:ok, baseline} <- read_location(location),
         {:ok, loader_manifest} <- loader_read(location.manifest_path),
         true <- loader_manifest == baseline.manifest_bytes do
      initial =
        Enum.map([__MODULE__, SymphonyElixir.Application], fn module ->
          case Map.fetch(baseline.index, Atom.to_string(module)) do
            {:ok, expected} -> observe_module(module, expected)
            :error -> %{"module" => Atom.to_string(module), "status" => "unavailable"}
          end
        end)

      status = if Enum.all?(initial, &(&1["status"] == "matched")), do: "captured", else: "artifact_binding_uncertain"
      {:ok, Map.merge(baseline, %{initial_modules: initial, capture_status: status})}
    else
      false -> {:error, :loader_manifest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp startup_summary({:ok, baseline}, captured_at, process) do
    %{
      "basis" => "startup_capture",
      "captured_at" => captured_at,
      "process" => process,
      "capture_status" => baseline.capture_status,
      "mode" => baseline.location.mode,
      "build_id" => baseline.manifest["build_id"],
      "manifest_sha256" => digest(baseline.manifest_bytes),
      "artifact_sha256" => baseline.artifact_sha256,
      "source_status" => baseline.manifest["source"]["status"],
      "module_count" => map_size(baseline.index),
      "initial_observed_count" => length(baseline.initial_modules)
    }
  end

  defp startup_summary({:error, reason}, captured_at, process) do
    %{"basis" => "startup_capture", "captured_at" => captured_at, "process" => process, "capture_status" => "unavailable", "reason" => reason_label(reason)}
  end

  defp locate do
    with {:file, filename} when is_list(filename) <- :code.is_loaded(__MODULE__),
         {:file, app_filename} when is_list(app_filename) <- :code.is_loaded(SymphonyElixir.Application) do
      filename = List.to_string(filename)
      app_filename = List.to_string(app_filename)
      locate_files(filename, app_filename)
    else
      _ -> {:error, :loaded_location_unavailable}
    end
  end

  defp locate_files(filename, app_filename) do
    ebin = Path.dirname(filename)

    cond do
      Path.type(filename) != :absolute or Path.dirname(app_filename) != ebin ->
        {:error, :loaded_location_mismatch}

      File.regular?(filename) ->
        with {:ok, app_path} <- resolve_path(Path.dirname(ebin), 0) do
          {:ok, %{mode: "beam", path: app_path, manifest_path: Path.join(app_path, "priv/build_identity.json")}}
        end

      true ->
        case Regex.run(~r{^(.*)/symphony_elixir/ebin$}, ebin) do
          [_, archive] ->
            with {:ok, path} <- resolve_path(archive, 0) do
              {:ok, %{mode: "escript", path: path, launch_path: archive, manifest_path: Path.join(archive, @manifest_entry)}}
            end

          _ ->
            {:error, :archive_location_unavailable}
        end
    end
  end

  # Resolve each component, including a symlink in an ancestor, without using cwd/current.
  defp resolve_path(_path, depth) when depth > 32, do: {:error, :symlink_depth}

  defp resolve_path(path, depth) do
    Enum.reduce_while(Path.split(path), {:ok, ""}, fn component, {:ok, prefix} ->
      candidate = if prefix == "", do: component, else: Path.join(prefix, component)

      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} ->
          with {:ok, target} <- File.read_link(candidate),
               {:ok, resolved} <- resolve_path(Path.expand(target, Path.dirname(candidate)), depth + 1) do
            {:cont, {:ok, resolved}}
          else
            {:error, _} = error -> {:halt, error}
          end

        {:ok, _} ->
          {:cont, {:ok, candidate}}

        {:error, reason} ->
          {:halt, {:error, {:location_unavailable, reason}}}
      end
    end)
  end

  defp read_location(%{mode: "escript", path: path} = location) do
    with {:ok, bytes} <- read_file(path, @archive_limit),
         {:ok, entries} <- extract_archive(path),
         {:ok, after_bytes} <- read_file(path, @archive_limit),
         true <- bytes == after_bytes,
         {:ok, manifest_bytes} <- fetch_entry(entries, @manifest_entry),
         {:ok, manifest} <- decode_manifest(manifest_bytes),
         {:ok, receipt_bytes} <- read_file(path <> ".build.json", @json_limit),
         {:ok, receipt} <- decode_json(receipt_bytes),
         :ok <- validate_receipt(receipt, manifest, manifest_bytes, bytes, entries) do
      {:ok,
       %{
         location: location,
         manifest: manifest,
         manifest_bytes: manifest_bytes,
         index: Map.new(manifest["modules"], &{&1["name"], &1}),
         artifact_sha256: digest(bytes),
         receipt_sha256: digest(receipt_bytes)
       }}
    else
      false -> {:error, :unstable_observation}
      {:error, _} = error -> error
    end
  end

  defp read_location(%{mode: "beam", path: app_path} = location) do
    with {:ok, bytes} <- read_file(location.manifest_path, @json_limit),
         {:ok, manifest} <- decode_manifest(bytes),
         {:ok, beams} <- read_beam_inventory(app_path, manifest) do
      {:ok, %{location: location, manifest: manifest, manifest_bytes: bytes, index: Map.new(manifest["modules"], &{&1["name"], &1}), artifact_sha256: digest(canonical(beams)), receipt_sha256: nil}}
    end
  end

  defp read_beam_inventory(app_path, manifest) do
    manifest["modules"]
    |> Enum.filter(&(&1["app"] == "symphony_elixir"))
    |> Enum.reduce_while({:ok, []}, fn expected, {:ok, acc} ->
      path = Path.join([app_path, "ebin", Path.basename(expected["path"])])

      with {:ok, bytes} <- read_file(path, @entry_limit),
           {:ok, {module, md5}} <- :beam_lib.md5(bytes),
           true <- Atom.to_string(module) == expected["name"] and hex(md5) == expected["code_md5"] do
        {:cont, {:ok, [%{"path" => expected["path"], "sha256" => digest(bytes)} | acc]}}
      else
        false -> {:halt, {:error, :beam_inventory_mismatch}}
        {:error, _} -> {:halt, {:error, :beam_inventory_unavailable}}
        {:error, _, _} -> {:halt, {:error, :invalid_beam}}
      end
    end)
  end

  defp loader_read(path) do
    # Bound loader reads too: a path may refer to either an archive or a regular priv.
    case :erl_prim_loader.read_file_info(String.to_charlist(path)) do
      {:ok, info} when elem(info, 1) <= @json_limit ->
        case :erl_prim_loader.read_file(String.to_charlist(path)) do
          {:ok, bytes} when byte_size(bytes) <= @json_limit -> {:ok, bytes}
          _ -> {:error, :loader_manifest_unavailable}
        end

      _ ->
        {:error, :loader_manifest_unavailable}
    end
  end

  defp extract_archive(path) do
    with {:ok, sections} <- :escript.extract(String.to_charlist(path), []),
         {:ok, archive} <- Keyword.fetch(sections, :archive),
         {:ok, table} <- :zip.list_dir(archive),
         :ok <- validate_table(table),
         {:ok, extracted} <- :zip.extract(archive, [:memory]) do
      {:ok, Map.new(extracted, fn {name, bytes} -> {List.to_string(name), bytes} end)}
    else
      _ -> {:error, :invalid_archive}
    end
  end

  defp validate_table(table) do
    files = Enum.filter(table, &(elem(&1, 0) == :zip_file))
    names = Enum.map(files, &(elem(&1, 1) |> List.to_string()))
    sizes = Enum.map(files, &elem(elem(&1, 2), 1))

    if length(files) <= 20_000 and length(names) == MapSet.size(MapSet.new(names)) and
         Enum.all?(names, &safe_path?/1) and Enum.all?(sizes, &(&1 <= @entry_limit)) and Enum.sum(sizes) <= @expanded_limit, do: :ok, else: {:error, :invalid_archive_table}
  end

  defp fetch_entry(entries, path) do
    case Map.fetch(entries, path) do
      {:ok, bytes} when byte_size(bytes) <= @json_limit -> {:ok, bytes}
      :error -> {:error, :manifest_missing}
      _ -> {:error, :manifest_too_large}
    end
  end

  defp decode_json(bytes) when byte_size(bytes) <= @json_limit do
    decoders = %{
      object_start: fn _ -> %{} end,
      object_push: fn key, value, acc ->
        if Map.has_key?(acc, key), do: throw(:duplicate_json_key)
        Map.put(acc, key, value)
      end,
      object_finish: fn acc, old -> {acc, old} end
    }

    try do
      case :json.decode(bytes, nil, decoders) do
        {%{} = value, nil, rest} -> if String.trim(rest) == "", do: {:ok, value}, else: {:error, :invalid_json}
        _ -> {:error, :invalid_json}
      end
    catch
      :throw, :duplicate_json_key -> {:error, :duplicate_json_key}
      :error, reason -> {:error, {:invalid_json, reason}}
    end
  end

  defp decode_json(_bytes), do: {:error, :json_too_large}

  defp decode_manifest(bytes) do
    with {:ok, manifest} <- decode_json(bytes),
         true <- valid_manifest?(manifest),
         true <- digest(canonical(Map.take(manifest, ["source", "toolchain", "modules", "scope"]))) == manifest["build_id"] do
      {:ok, manifest}
    else
      false -> {:error, :invalid_manifest}
      {:error, _} = error -> error
    end
  end

  defp valid_manifest?(manifest) do
    manifest["version"] === 1 and hash?(manifest["build_id"], 64) and valid_source?(manifest["source"]) and
      is_map(manifest["toolchain"]) and is_map(manifest["scope"]) and is_list(manifest["compiled_inputs"]) and
      Enum.all?(manifest["compiled_inputs"], &valid_input?/1) and valid_modules?(manifest["modules"], false)
  end

  defp valid_source?(%{
         "status" => status,
         "base_commit" => commit,
         "tree_oid" => tree,
         "fingerprint" => fingerprint,
         "entries" => entries,
         "external_resources" => resources,
         "project_path" => project
       }) do
    status in ["clean", "dirty"] and hash?(commit, 40) and hash?(tree, 40) and hash?(fingerprint, 64) and
      (project == "." or safe_path?(project)) and is_list(entries) and is_list(resources) and length(entries) + length(resources) <= 50_000 and
      Enum.all?(entries, &valid_source_entry?/1) and Enum.all?(resources, &valid_external_resource?(&1, project)) and
      Enum.sum(Enum.map(entries ++ resources, & &1["size"])) <= @source_limit and
      length(entries) == MapSet.size(MapSet.new(entries, & &1["path"])) and
      length(resources) == MapSet.size(MapSet.new(resources, & &1["source_path"])) and
      length(resources) == MapSet.size(MapSet.new(resources, & &1["compile_path"])) and
      digest(canonical(%{"entries" => entries, "external_resources" => resources})) == fingerprint
  end

  defp valid_source?(_), do: false
  defp valid_source_entry?(%{"size" => size} = entry), do: is_integer(size) and size >= 0 and size <= @source_limit and valid_input?(entry)
  defp valid_source_entry?(_), do: false

  defp valid_external_resource?(%{"app" => app, "resource_path" => path, "source_path" => source, "compile_path" => compiled} = entry, project) do
    prefix = if project == ".", do: "", else: project <> "/"

    is_binary(app) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, app) and safe_path?(path) and String.starts_with?(path, "priv/") and
      safe_path?(source) and source == prefix <> "deps/" <> app <> "/" <> path and safe_path?(compiled) and
      String.starts_with?(compiled, prefix <> "_build/") and String.ends_with?(compiled, "/lib/" <> app <> "/" <> path) and
      valid_source_entry?(Map.put(entry, "path", source))
  end

  defp valid_external_resource?(_, _), do: false
  defp valid_input?(%{"path" => path, "sha256" => sha}), do: safe_path?(path) and hash?(sha, 64)
  defp valid_input?(_), do: false

  defp valid_modules?(modules, packaged?) when is_list(modules) and modules != [] and length(modules) <= @max_modules do
    Enum.all?(modules, fn module ->
      is_map(module) and is_binary(module["name"]) and byte_size(module["name"]) <= 1024 and
        is_binary(module["app"]) and safe_path?(module["path"]) and hash?(module["code_md5"], 32) and
        (not packaged? or hash?(module["packaged_beam_sha256"], 64))
    end) and length(modules) == MapSet.size(MapSet.new(modules, & &1["name"])) and
      length(modules) == MapSet.size(MapSet.new(modules, & &1["path"]))
  end

  defp valid_modules?(_, _), do: false

  defp validate_receipt(receipt, manifest, manifest_bytes, archive_bytes, entries) do
    valid =
      receipt["version"] === 1 and receipt["status"] == "compared" and receipt["build_id"] == manifest["build_id"] and
        receipt["escript_sha256"] == digest(archive_bytes) and receipt["embedded_manifest_sha256"] == digest(manifest_bytes) and
        receipt["source"] == Map.take(manifest["source"], ["base_commit", "tree_oid", "status", "fingerprint"]) and
        receipt["compiled_inputs_sha256"] == digest(canonical(manifest["compiled_inputs"])) and valid_modules?(receipt["modules"], true)

    if valid do
      expected = manifest["modules"] |> Enum.sort_by(& &1["name"])
      actual = receipt["modules"] |> Enum.map(&Map.delete(&1, "packaged_beam_sha256")) |> Enum.sort_by(& &1["name"])
      beam_paths = entries |> Map.keys() |> Enum.filter(&String.ends_with?(&1, ".beam")) |> Enum.sort()

      if expected == actual and beam_paths == Enum.sort(Enum.map(actual, & &1["path"])) and
           Enum.all?(receipt["modules"], &matching_beam?(&1, entries)), do: :ok, else: {:error, :artifact_binding_uncertain}
    else
      {:error, :receipt_mismatch}
    end
  end

  defp matching_beam?(expected, entries) do
    with {:ok, bytes} <- Map.fetch(entries, expected["path"]),
         {:ok, {module, md5}} <- :beam_lib.md5(bytes) do
      digest(bytes) == expected["packaged_beam_sha256"] and hex(md5) == expected["code_md5"] and Atom.to_string(module) == expected["name"]
    else
      _ -> false
    end
  end

  defp validate_scope(modules, index) when is_list(modules) and modules != [] and length(modules) <= @max_scope do
    if Enum.all?(modules, &(is_atom(&1) and Map.has_key?(index, Atom.to_string(&1)))) and length(modules) == MapSet.size(MapSet.new(modules)), do: :ok, else: {:error, :unknown_scope}
  end

  defp validate_scope(_, _), do: {:error, :unknown_scope}

  defp observe_module(module, expected) do
    first = module_sample(module)
    second = module_sample(module)

    status =
      cond do
        first != second -> "unstable_observation"
        first == :not_loaded -> "not_loaded"
        first == :cover_compiled -> "cover_compiled"
        first == :unavailable -> "unavailable"
        first.old_code -> "old_code_present"
        first.md5 != expected["code_md5"] -> "mismatch"
        true -> "matched"
      end

    %{"module" => Atom.to_string(module), "status" => status, "expected_code_md5" => expected["code_md5"], "observed_code_md5" => if(is_map(first), do: first.md5, else: nil)}
  end

  defp module_sample(module) do
    case :code.is_loaded(module) do
      false ->
        :not_loaded

      {:file, :cover_compiled} ->
        :cover_compiled

      {:file, _filename} ->
        try do
          %{md5: hex(:erlang.get_module_info(module, :md5)), old_code: :erlang.check_old_code(module)}
        catch
          :error, :badarg -> :unavailable
        end
    end
  end

  defp read_file(path, limit) do
    with {:ok, before} <- File.lstat(path, time: :posix),
         :ok <- readable(before, limit),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      bytes =
        try do
          IO.binread(file, limit + 1)
        after
          File.close(file)
        end

      bytes = if bytes == :eof, do: "", else: bytes

      with true <- is_binary(bytes) and byte_size(bytes) <= limit,
           {:ok, after_stat} <- File.lstat(path, time: :posix),
           true <- file_identity(before) == file_identity(after_stat) and byte_size(bytes) == before.size do
        {:ok, bytes}
      else
        _ -> {:error, :unstable_observation}
      end
    else
      {:error, reason} -> {:error, {:file_unavailable, reason}}
    end
  end

  defp readable(%{type: :regular, size: size}, limit) when size <= limit, do: :ok
  defp readable(_, _), do: {:error, :invalid_or_large_file}
  defp file_identity(stat), do: Map.take(stat, [:type, :size, :inode, :major_device, :minor_device, :mtime, :ctime, :mode])
  defp artifact_binding(baseline), do: {baseline.artifact_sha256, baseline.receipt_sha256, baseline.manifest_bytes}
  defp inspection_error(reason), do: %{"observed_at" => now(), "status" => "unavailable", "reason" => reason_label(reason)}
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label({category, _detail}), do: Atom.to_string(category)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> hex()
  defp hash?(value, length) when is_binary(value), do: byte_size(value) == length and String.match?(value, ~r/\A[0-9a-f]+\z/)
  defp hash?(_, _), do: false

  defp safe_path?(path) when is_binary(path),
    do:
      byte_size(path) in 1..4096 and Path.type(path) == :relative and not Enum.any?(Path.split(path), &(&1 in ["..", "."])) and not String.contains?(path, [<<0>>, "\\"]) and
        not String.ends_with?(path, "/")

  defp safe_path?(_), do: false
  defp canonical(map) when is_map(map), do: ["{", map |> Enum.sort() |> Enum.map(fn {key, value} -> [:json.encode(key), ":", canonical(value)] end) |> Enum.intersperse(","), "}"]
  defp canonical(list) when is_list(list), do: ["[", Enum.map(list, &canonical/1) |> Enum.intersperse(","), "]"]
  defp canonical(value), do: :json.encode(value)
end
