# Evaluated from source by a fresh `mix run --no-start --no-compile` process.
# Deliberately does not call Symphony runtime modules, even after compilation.
defmodule SymphonyBuildDriver do
  @manifest "symphony_elixir/priv/build_identity.json"
  @json_limit 4 * 1024 * 1024
  @archive_limit 64 * 1024 * 1024
  @expanded_limit 128 * 1024 * 1024
  @entry_limit 16 * 1024 * 1024
  @source_limit 64 * 1024 * 1024
  @source_chunk 64 * 1024

  def run do
    bootstrap!()
    config = Mix.Project.config()
    root = git!(File.cwd!(), ["rev-parse", "--show-toplevel"]) |> String.trim()
    scope = source_scope!(root, config)
    source = source!(root, scope)
    toolchain = toolchain(config)
    generated = Path.expand("priv/build_identity.json")
    output = Path.expand(Keyword.fetch!(config[:escript], :path))
    temporary = output <> ".identity-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.dirname(generated))
    File.mkdir_p!(Path.dirname(output))

    try do
      Mix.Task.reenable("compile")
      Mix.Task.run("compile", ["--force"])
      equal!(source, source!(root, scope), :source_changed)
      inputs = compiled_inputs!()
      resources!(source, root)
      File.write!(generated, ~s({"status":"build_probe"}))
      pack!(config, temporary <> ".probe")
      probe = archive!(temporary <> ".probe")
      own_modules!(probe.modules)

      identity = %{
        "version" => 1,
        "source" => source,
        "toolchain" => toolchain,
        "modules" => Enum.map(probe.modules, &Map.delete(&1, "packaged_beam_sha256")),
        "compiled_inputs" => inputs,
        "scope" => %{"inventory" => "mix_escript_probe", "trust" => "local_unsigned", "otp" => "external"}
      }

      build_id = digest(canonical(Map.take(identity, ["source", "toolchain", "modules", "scope"])))
      manifest = Map.merge(identity, %{"build_id" => build_id, "built_at" => DateTime.to_iso8601(DateTime.utc_now())})
      manifest_bytes = json!(manifest)
      File.write!(generated, manifest_bytes)
      pack!(config, temporary <> ".final")
      final = archive!(temporary <> ".final")
      equal!(manifest_bytes, Map.fetch!(final.entries, @manifest), :embedded_manifest_mismatch)
      equal!(probe.modules |> comparable_modules(), final.modules |> comparable_modules(), :packaged_code_changed)
      equal!(source, source!(root, scope), :source_changed)
      equal!(inputs, compiled_inputs!(), :compiled_inputs_changed)
      equal!(toolchain, toolchain(Mix.Project.config()), :build_environment_changed)

      receipt = %{
        "version" => 1,
        "status" => "compared",
        "build_id" => build_id,
        "source" => Map.take(source, ["base_commit", "tree_oid", "status", "fingerprint"]),
        "embedded_manifest_sha256" => digest(manifest_bytes),
        "escript_sha256" => digest(final.bytes),
        "compiled_inputs_sha256" => digest(canonical(inputs)),
        "modules" => final.modules
      }

      File.write!(temporary <> ".receipt", json!(receipt))
      File.rename!(temporary <> ".final", output)
      File.rename!(temporary <> ".receipt", output <> ".build.json")
      Mix.shell().info("Build identity #{build_id} (#{source["status"]}); receipt #{output}.build.json")
    after
      Mix.ProjectStack.merge_config(config)

      Enum.each([".probe", ".final", ".receipt"], fn suffix ->
        case File.rm(temporary <> suffix) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> Mix.shell().error("identity temporary cleanup failed: #{inspect(reason)}")
        end
      end)
    end
  end

  defp bootstrap! do
    if Process.get({__MODULE__, :entered}), do: Mix.raise("build_identity: reused_builder_vm")
    Process.put({__MODULE__, :entered}, true)
    unless Mix.Project.config()[:app] == :symphony_elixir, do: Mix.raise("build_identity: unexpected_project")

    loaded =
      Enum.filter(:code.all_loaded(), fn {module, _} ->
        name = Atom.to_string(module)

        (name == "Elixir.SymphonyElixir" or String.starts_with?(name, "Elixir.SymphonyElixir.") or String.starts_with?(name, "Elixir.SymphonyElixirWeb.")) and
          module != SymphonyElixir.MixProject
      end)

    if loaded != [] or Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :symphony_elixir end),
      do: Mix.raise("build_identity: preloaded_runtime")

    unless System.otp_release() == "28" and System.version() == "1.19.5",
      do: Mix.raise("build_identity: unsupported_toolchain (requires Elixir/Mix 1.19.5 and OTP 28)")
  end

  defp toolchain(config) do
    configuration = config |> Keyword.update!(:escript, &Keyword.delete(&1, :path)) |> Enum.sort_by(&elem(&1, 0))

    %{
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "mix" => System.version(),
      "otp_version" => :erlang.system_info(:version) |> List.to_string(),
      "elixir_path" => :code.lib_dir(:elixir) |> List.to_string(),
      "mix_path" => :code.lib_dir(:mix) |> List.to_string(),
      "otp_root" => :code.root_dir() |> List.to_string(),
      "env" => Atom.to_string(Mix.env()),
      "target" => Atom.to_string(Mix.target()),
      "configuration_sha256" => digest(inspect(configuration, limit: :infinity, printable_limit: :infinity)),
      "escript" => inspect(Keyword.delete(config[:escript], :path), limit: :infinity),
      "selection" => %{"MIX_ENV" => System.get_env("MIX_ENV"), "MIX_TARGET" => System.get_env("MIX_TARGET")}
    }
  end

  defp source_scope!(root, config) do
    # Mix's evaluated project file fixes the scope; caller cwd alone is not authority.
    project = Mix.ProjectStack.project_file() |> Path.expand() |> Path.dirname()
    relative = Path.relative_to(project, root)

    unless project == File.cwd!() and (project == root or String.starts_with?(project, root <> "/")),
      do: Mix.raise("build_identity: unbounded_project_scope")

    build_root = Path.join(project, "_build")
    build_paths = [Mix.Project.build_path(config), Mix.Project.app_path(config), Mix.Project.consolidation_path(config)]

    unless Enum.all?(build_paths, &String.starts_with?(Path.expand(&1), build_root <> "/")) and
             Path.expand(config[:deps_path]) == Path.join(project, "deps") and
             Path.expand(Keyword.fetch!(config[:escript], :path)) == Path.join(project, "bin/symphony"),
           do: Mix.raise("build_identity: unbounded_output_scope")

    Enum.each(build_paths ++ [Path.join(project, "deps"), Path.join(project, "bin"), Path.join(project, "priv")], &bounded_output_path!(&1, project))
    prefix = if relative == ".", do: "", else: relative <> "/"

    %{
      "project_path" => relative,
      "exclusions" => Enum.map(["_build/", "deps/", "bin/", "priv/build_identity.json"], &(prefix <> &1)),
      "external_resources" => external_resource_declarations!(root, project, config)
    }
  end

  defp external_resource_declarations!(root, project, config) do
    declarations = Keyword.fetch!(config, :build_identity_resources)

    unless is_list(declarations) and length(declarations) <= 50_000,
      do: Mix.raise("build_identity: invalid_external_resources")

    dependencies = Mix.Project.deps_paths()

    resources =
      Enum.map(declarations, fn
        {app, path} when is_atom(app) and is_binary(path) ->
          name = Atom.to_string(app)
          safe_path!(path)

          unless Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) and String.starts_with?(path, "priv/") and not secret_path?(path),
            do: Mix.raise("build_identity: invalid_external_resource")

          dependency = Path.join([project, "deps", name])

          unless is_binary(dependencies[app]) and Path.expand(dependencies[app]) == dependency,
            do: Mix.raise("build_identity: external_resource_dependency_mismatch")

          alias_path = Path.join([Mix.Project.build_path(config), "lib", name, path]) |> Path.expand()

          unless Application.app_dir(app, path) |> Path.expand() == alias_path,
            do: Mix.raise("build_identity: external_resource_app_path_mismatch")

          %{"app" => name, "resource_path" => path, "source_path" => Path.relative_to(Path.join(dependency, path), root), "compile_path" => Path.relative_to(alias_path, root)}

        _ ->
          Mix.raise("build_identity: invalid_external_resource")
      end)

    unless length(resources) == MapSet.size(MapSet.new(resources, & &1["source_path"])),
      do: Mix.raise("build_identity: duplicate_external_resource")

    Enum.sort_by(resources, & &1["source_path"])
  end

  defp external_resource_binding!(root, project, resource) do
    source = Path.join(root, resource["source_path"])
    alias_path = Path.join(root, resource["compile_path"])
    dependency_priv = Path.join([project, "deps", resource["app"], "priv"])
    alias_priv = Path.join([Mix.Project.build_path(), "lib", resource["app"], "priv"]) |> Path.expand()
    bounded_output_path!(source, project)
    bounded_output_path!(Path.dirname(alias_priv), project)
    {:ok, link} = File.read_link(alias_priv)
    equal!(Path.expand(link, Path.dirname(alias_priv)), dependency_priv, :external_resource_alias_mismatch)
    source_stat = File.lstat!(source, time: :posix)
    alias_stat = File.stat!(alias_path, time: :posix)
    unless source_stat.type == :regular, do: Mix.raise("build_identity: invalid_external_resource_file")
    equal!(source_file_identity(source_stat), source_file_identity(alias_stat), :external_resource_alias_mismatch)
    {link, source_file_identity(File.lstat!(alias_priv, time: :posix)), source_file_identity(source_stat)}
  end

  defp bounded_output_path!(path, project) do
    Path.relative_to(Path.expand(path), project)
    |> Path.split()
    |> Enum.reduce(project, fn component, parent ->
      candidate = Path.join(parent, component)

      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} -> Mix.raise("build_identity: unbounded_output_scope (symlink)")
        {:ok, _stat} -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Mix.raise("build_identity: output_scope_unavailable (#{reason})")
      end

      candidate
    end)
  end

  defp source!(root, scope) do
    head = String.trim(git!(root, ["rev-parse", "HEAD"]))
    tree = String.trim(git!(root, ["rev-parse", "HEAD^{tree}"]))

    paths =
      git!(root, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]) |> String.split(<<0>>, trim: true) |> Enum.uniq() |> Enum.reject(&excluded?(&1, scope["exclusions"])) |> Enum.sort()

    if length(paths) + length(scope["external_resources"]) > 50_000, do: Mix.raise("build_identity: too_many_source_files")

    {entries, remaining} =
      Enum.map_reduce(paths, @source_limit, fn path, remaining ->
        safe_path!(path)
        if secret_path?(path), do: Mix.raise("build_identity: secret_source_path")
        # lstat the ancestors too: a regular leaf under a symlink is not source in this checkout.
        Enum.reduce(Path.split(path), root, fn component, parent ->
          candidate = Path.join(parent, component)
          if source_stat!(candidate).type == :symlink, do: Mix.raise("build_identity: symlink_source")
          candidate
        end)

        {size, sha256} = source_digest!(Path.join(root, path), remaining)
        {%{"path" => path, "size" => size, "sha256" => sha256}, remaining - size}
      end)

    project = Path.expand(scope["project_path"], root)

    {resources, _remaining} =
      Enum.map_reduce(scope["external_resources"], remaining, fn resource, budget ->
        before = external_resource_binding!(root, project, resource)
        {size, sha256} = source_digest!(Path.join(root, resource["source_path"]), budget)
        equal!(before, external_resource_binding!(root, project, resource), :external_resource_changed)
        {Map.merge(resource, %{"size" => size, "sha256" => sha256}), budget - size}
      end)

    status = if git!(root, ["status", "--porcelain", "--untracked-files=all"]) == "", do: "clean", else: "dirty"

    %{
      "base_commit" => head,
      "tree_oid" => tree,
      "status" => status,
      "entries" => entries,
      "external_resources" => resources,
      "fingerprint" => digest(canonical(%{"entries" => entries, "external_resources" => resources})),
      "project_path" => scope["project_path"],
      "exclusions" => scope["exclusions"]
    }
  end

  defp source_digest!(path, remaining) do
    before = File.lstat!(path, time: :posix)
    unless before.type == :regular, do: Mix.raise("build_identity: invalid_source_file #{path}")
    if before.size > remaining, do: Mix.raise("build_identity: source_budget_exceeded #{path}")
    {:ok, file} = File.open(path, [:read, :binary])

    try do
      equal!(source_file_identity(before), source_file_identity(source_handle_stat!(file)), :file_changed)
      {context, size} = source_chunks!(file, :crypto.hash_init(:sha256), 0, remaining, path)
      equal!(source_file_identity(before), source_file_identity(source_handle_stat!(file)), :file_changed)
      equal!(source_file_identity(before), source_file_identity(File.lstat!(path, time: :posix)), :file_changed)
      equal!(before.size, size, :file_changed)
      {size, :crypto.hash_final(context) |> Base.encode16(case: :lower)}
    after
      case File.close(file) do
        :ok -> :ok
        {:error, reason} -> Mix.raise("build_identity: source_close_failed #{path}: #{inspect(reason)}")
      end
    end
  end

  defp source_handle_stat!(file) do
    {:ok, info} = :file.read_file_info(file, time: :posix)
    File.Stat.from_record(info)
  end

  defp source_file_identity(stat), do: stat |> Map.from_struct() |> Map.drop([:atime])

  defp source_chunks!(file, context, size, limit, path) do
    case IO.binread(file, min(@source_chunk, limit - size + 1)) do
      :eof ->
        {context, size}

      bytes when is_binary(bytes) ->
        next_size = size + byte_size(bytes)
        if next_size > limit, do: Mix.raise("build_identity: source_budget_exceeded #{path}")
        source_chunks!(file, :crypto.hash_update(context, bytes), next_size, limit, path)

      {:error, reason} ->
        Mix.raise("build_identity: source_read_failed #{path}: #{inspect(reason)}")
    end
  end

  defp excluded?(path, exclusions) do
    Enum.any?(exclusions, fn exclusion ->
      if String.ends_with?(exclusion, "/"), do: String.starts_with?(path, exclusion), else: path == exclusion
    end)
  end

  defp source_stat!(path) do
    case File.lstat(path) do
      {:ok, stat} -> stat
      {:error, reason} -> Mix.raise("build_identity: source_unavailable (listed file #{path}: #{reason})")
    end
  end

  defp secret_path?(path) do
    Enum.any?(Path.split(path), &(&1 in [".env", ".secrets", ".credentials"] or String.starts_with?(&1, ".env.")))
  end

  defp compiled_inputs! do
    (Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin/*.{beam,app}")) ++
       Path.wildcard(Path.join(Mix.Project.consolidation_path(), "*.beam")))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path -> %{"path" => Path.relative_to(path, Mix.Project.build_path()), "sha256" => digest(read!(path, @entry_limit))} end)
  end

  defp resources!(source, root) do
    declared_paths = Enum.flat_map(source["external_resources"], &[&1["source_path"], &1["compile_path"]])
    paths = MapSet.new(Enum.map(source["entries"], & &1["path"]) ++ declared_paths)

    for path <- Path.wildcard(Path.join(Mix.Project.compile_path(), "*.beam")) do
      {:ok, {_, [{:attributes, attributes}]}} = :beam_lib.chunks(read!(path, @entry_limit), [:attributes])

      for resource <- Keyword.get(attributes, :external_resource, []) do
        relative = Path.relative_to(Path.expand(to_string(resource)), root)
        unless MapSet.member?(paths, relative), do: Mix.raise("build_identity: external_resource_not_captured #{relative}")
      end
    end
  end

  defp own_modules!(modules) do
    {:ok, [{:application, :symphony_elixir, properties}]} = :file.consult(String.to_charlist(Path.join(Mix.Project.compile_path(), "symphony_elixir.app")))
    expected = Keyword.fetch!(properties, :modules) |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    actual = modules |> Enum.filter(&(&1["app"] == "symphony_elixir")) |> Enum.map(& &1["name"]) |> Enum.sort()
    equal!(expected, actual, :own_modules_mismatch)
  end

  defp pack!(config, path) do
    Mix.ProjectStack.merge_config(escript: Keyword.put(config[:escript], :path, path))
    Mix.Task.reenable("escript.build")
    Mix.Task.run("escript.build", [])
  end

  defp archive!(path) do
    bytes = read!(path, @archive_limit)
    {:ok, sections} = :escript.extract(String.to_charlist(path), [])
    equal!(bytes, read!(path, @archive_limit), :archive_changed)
    archive = Keyword.fetch!(sections, :archive)
    {:ok, table} = :zip.list_dir(archive)
    files = Enum.filter(table, &(elem(&1, 0) == :zip_file))
    if length(files) > 20_000, do: Mix.raise("build_identity: too_many_archive_entries")
    names = Enum.map(files, fn file -> elem(file, 1) |> List.to_string() end)
    Enum.each(names, &safe_path!/1)
    equal!(length(names), MapSet.size(MapSet.new(names)), :duplicate_archive_path)
    sizes = Enum.map(files, &elem(elem(&1, 2), 1))
    if Enum.any?(sizes, &(&1 > @entry_limit)) or Enum.sum(sizes) > @expanded_limit, do: Mix.raise("build_identity: archive_too_large")
    {:ok, extracted} = :zip.extract(archive, [:memory])
    entries = Map.new(extracted, fn {name, binary} -> {List.to_string(name), binary} end)
    if Enum.count(names, &String.ends_with?(&1, ".beam")) > 10_000, do: Mix.raise("build_identity: too_many_modules")

    modules =
      entries
      |> Enum.filter(fn {name, _} -> String.ends_with?(name, ".beam") end)
      |> Enum.map(fn {name, binary} ->
        {:ok, {module, md5}} = :beam_lib.md5(binary)

        app =
          case Path.split(name) do
            [app, "ebin", _] -> app
            [_] -> "generated_launcher"
            _ -> Mix.raise("build_identity: invalid_beam_path")
          end

        %{"name" => Atom.to_string(module), "app" => app, "path" => name, "code_md5" => Base.encode16(md5, case: :lower), "packaged_beam_sha256" => digest(binary)}
      end)
      |> Enum.sort_by(& &1["name"])

    if length(modules) > 10_000, do: Mix.raise("build_identity: too_many_modules")
    equal!(length(modules), MapSet.size(MapSet.new(modules, & &1["name"])), :duplicate_module)
    %{bytes: bytes, entries: entries, modules: modules}
  end

  defp comparable_modules(modules) do
    Enum.map(modules, fn module ->
      if module["app"] == "generated_launcher", do: Map.delete(module, "packaged_beam_sha256"), else: module
    end)
  end

  defp safe_path!(path) do
    unless byte_size(path) <= 4096 and Path.type(path) == :relative and not Enum.any?(Path.split(path), &(&1 in ["..", "."])) and not String.contains?(path, [<<0>>, "\\"]),
      do: Mix.raise("build_identity: invalid_path")
  end

  defp read!(path, limit) do
    before = File.lstat!(path, time: :posix)
    unless before.type == :regular and before.size <= limit, do: Mix.raise("build_identity: invalid_or_large_file #{path}")
    {:ok, file} = File.open(path, [:read, :binary])

    bytes =
      try do
        IO.binread(file, limit + 1)
      after
        File.close(file)
      end

    bytes = if bytes == :eof, do: "", else: bytes
    unless is_binary(bytes) and byte_size(bytes) <= limit, do: Mix.raise("build_identity: file_read_failed #{path}")
    equal!(Map.drop(Map.from_struct(before), [:atime]), Map.drop(Map.from_struct(File.lstat!(path, time: :posix)), [:atime]), :file_changed)
    equal!(before.size, byte_size(bytes), :file_changed)
    bytes
  end

  defp git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {_output, status} -> Mix.raise("build_identity: source_unavailable (git exit #{status})")
    end
  end

  defp equal!(value, value, _reason), do: :ok
  defp equal!(_left, _right, reason), do: Mix.raise("build_identity: #{reason}")
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp canonical(map) when is_map(map), do: ["{", map |> Enum.sort() |> Enum.map(fn {key, value} -> [:json.encode(key), ":", canonical(value)] end) |> Enum.intersperse(","), "}"]
  defp canonical(list) when is_list(list), do: ["[", Enum.map(list, &canonical/1) |> Enum.intersperse(","), "]"]
  defp canonical(value), do: :json.encode(value)

  defp json!(value) do
    bytes = canonical(value) |> IO.iodata_to_binary()
    if byte_size(bytes) > @json_limit, do: Mix.raise("build_identity: json_too_large")
    bytes
  end
end

SymphonyBuildDriver.run()
