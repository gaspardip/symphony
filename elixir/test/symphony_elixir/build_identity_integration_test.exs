defmodule SymphonyElixir.BuildIdentityIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000
  @driver Path.expand("../../scripts/build-with-identity.exs", __DIR__)
  @runtime Path.expand("../../lib/symphony_elixir/build_identity.ex", __DIR__)
  @build_timeout 120
  @runtime_timeout 30
  @build_alias Mix.Project.config() |> Keyword.fetch!(:aliases) |> Keyword.fetch!(:build)

  # No services/downloaded dependencies/network. One local Mix path dependency. At most one child VM at a time. Two real
  # fixture builds in setup, one dirty build, six deliberately rejected builder invocations,
  # and bounded escript invocations below. Python kills the whole child process
  # group on timeout; ExUnit's longer watchdog remains a final backstop.
  setup_all do
    root = Path.join(System.tmp_dir!(), "identity-real-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    project = Path.join(root, "project")
    seed!(project)
    refute File.exists?(Path.join(project, "_build"))
    assert {output_a, 0} = run(project, "mix", ["build"], @build_timeout)
    assert output_a =~ "Build identity"
    a = Path.join(root, "A")
    File.cp_r!(project, a)
    File.write!(Path.join(project, "lib/probe.ex"), probe("B"))
    File.write!(Path.join(project, "elixir/bin/tool"), "foreign tool B")
    File.write!(Path.join(project, "deps/identity_resource_fixture/priv/input.txt"), "resource B")
    git!(project, ["add", "."])
    git!(project, ["commit", "-m", "B"])
    assert {output_b, 0} = run(project, "mix", ["build"], @build_timeout)
    assert output_b =~ "Build identity"
    b = Path.join(root, "B")
    File.cp_r!(project, b)
    %{root: root, a: a, b: b}
  end

  test "E1-B01/B02/B04 real force builds preserve environment and inventories through both Mix packages", %{a: a, b: b} do
    first = receipt(a)
    second = receipt(b)
    refute first["build_id"] == second["build_id"]
    assert first["status"] == "compared"
    assert second["source"]["status"] == "clean"

    for path <- [a, b] do
      manifest = manifest(path)
      assert manifest["toolchain"]["env"] == "dev"
      assert manifest["toolchain"]["target"] == "host"
      assert manifest["scope"]["inventory"] == "mix_escript_probe"
      assert manifest["source"]["project_path"] == "."
      assert manifest["source"]["exclusions"] == ["_build/", "deps/", "bin/", "priv/build_identity.json"]

      for foreign <- ["elixir/bin/tool", "elixir/_build/input", "elixir/deps/input", "elixir/priv/build_identity.json"] do
        entry = Enum.find(manifest["source"]["entries"], &(&1["path"] == foreign))
        assert entry["sha256"] == :crypto.hash(:sha256, File.read!(Path.join(path, foreign))) |> Base.encode16(case: :lower)
      end

      source_entry = Enum.find(manifest["source"]["entries"], &(&1["path"] == "source-input.bin"))
      assert source_entry["size"] == 16 * 1024 * 1024 + 1
      assert source_entry["sha256"] == :crypto.hash(:sha256, File.read!(Path.join(path, "source-input.bin"))) |> Base.encode16(case: :lower)
      empty_entry = Enum.find(manifest["source"]["entries"], &(&1["path"] == "source-empty.txt"))
      assert empty_entry["size"] == 0
      assert empty_entry["sha256"] == :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

      assert [resource] = manifest["source"]["external_resources"]
      assert resource["app"] == "identity_resource_fixture"
      assert resource["resource_path"] == "priv/input.txt"
      assert resource["source_path"] == "deps/identity_resource_fixture/priv/input.txt"
      assert resource["compile_path"] == "_build/dev/lib/identity_resource_fixture/priv/input.txt"
      source_path = Path.join(path, resource["source_path"])
      alias_path = Path.join(path, resource["compile_path"])
      source_stat = File.stat!(source_path)
      alias_stat = File.stat!(alias_path)
      assert Map.take(source_stat, [:inode, :major_device, :minor_device]) == Map.take(alias_stat, [:inode, :major_device, :minor_device])
      assert resource["size"] == byte_size(File.read!(source_path))
      assert resource["sha256"] == :crypto.hash(:sha256, File.read!(source_path)) |> Base.encode16(case: :lower)

      assert Enum.any?(manifest["modules"], &(&1["app"] == "generated_launcher"))
      assert Enum.any?(manifest["compiled_inputs"], &String.contains?(&1["path"], "consolidated"))
      compiled_probe = Enum.find(manifest["compiled_inputs"], &String.ends_with?(&1["path"], "Elixir.SymphonyElixir.Probe.beam"))
      packaged_probe = Enum.find(receipt(path)["modules"], &(&1["name"] == "Elixir.SymphonyElixir.Probe"))
      refute compiled_probe["sha256"] == packaged_probe["packaged_beam_sha256"]
      assert Enum.map(manifest["modules"], & &1["code_md5"]) == Enum.map(receipt(path)["modules"], & &1["code_md5"])
      refute File.exists?(Path.join(path, "application-started"))
      observed = invoke(path, ["inspect"])
      assert [%{"status" => "matched"}] = observed["memory"]["results"]
      assert observed["resource_value"] == File.read!(source_path)
    end
  end

  test "E1-B03 dirty source is identified, missing Git fails and a release works without Git", %{root: root} do
    dirty_repo = Path.join(root, "nested")
    dirty = Path.join(dirty_repo, "elixir")
    seed!(dirty, dirty_repo)
    File.write!(Path.join(dirty_repo, "bin/tool"), "dirty foreign tool")
    File.write!(Path.join(dirty, "note.txt"), "local dirty input")
    assert {_, 0} = run(dirty, "mix", ["build"], @build_timeout)
    assert receipt(dirty)["source"]["status"] == "dirty"
    assert manifest(dirty)["source"]["status"] == "dirty"
    assert manifest(dirty)["source"]["project_path"] == "elixir"
    assert manifest(dirty)["source"]["exclusions"] == ["elixir/_build/", "elixir/deps/", "elixir/bin/", "elixir/priv/build_identity.json"]

    for foreign <- ["bin/tool", "_build/input", "deps/input", "priv/build_identity.json"] do
      entry = Enum.find(manifest(dirty)["source"]["entries"], &(&1["path"] == foreign))
      assert entry["sha256"] == :crypto.hash(:sha256, File.read!(Path.join(dirty_repo, foreign))) |> Base.encode16(case: :lower)
    end

    File.rm_rf!(Path.join(dirty_repo, ".git"))
    assert invoke(dirty, ["inspect"])["summary"]["capture_status"] == "captured"
    assert {output, status} = run(dirty, "mix", ["build"], @build_timeout)
    assert status != 0
    assert output =~ "source_unavailable"
  end

  test "E1-B02 preloaded runtime in a reused builder VM is rejected", %{a: a} do
    code = "Code.ensure_loaded!(SymphonyElixir.BuildIdentity); Code.eval_file(\"scripts/build-with-identity.exs\")"
    assert {output, status} = run(a, "mix", ["run", "--no-start", "--no-compile", "-e", code], @build_timeout)
    assert status != 0
    assert output =~ "preloaded_runtime"
  end

  test "E1-B01 source mutation during forced compilation cannot publish a new pair", %{root: root, a: a} do
    changed = copy!(a, Path.join(root, "changing"))
    original = File.read!(Path.join(changed, "bin/symphony.build.json"))
    # Compile-time file write is the deterministic boundary, not a timer race.
    File.write!(Path.join(changed, "lib/mutate.ex"), "File.write!(\"note.txt\", \"changed during compile\")\ndefmodule BuildMutation do\nend\n")
    assert {output, status} = run(changed, "mix", ["build"], @build_timeout)
    assert status != 0
    assert output =~ "source_changed"
    assert File.read!(Path.join(changed, "bin/symphony.build.json")) == original
  end

  test "E1-B01 changing only a declared resource during compile preserves the published pair", %{root: root, a: a} do
    changed = copy!(a, Path.join(root, "changing-resource"))
    archive = Path.join(changed, "bin/symphony")
    before_archive = File.read!(archive)
    before_receipt = File.read!(archive <> ".build.json")
    File.write!(Path.join(changed, "lib/mutate.ex"), "File.write!(\"deps/identity_resource_fixture/priv/input.txt\", \"changed resource\")\ndefmodule ResourceMutation do\nend\n")
    assert {output, status} = run(changed, "mix", ["build"], @build_timeout)
    assert status != 0
    assert output =~ "source_changed"
    assert File.read!(Path.join(changed, "deps/identity_resource_fixture/priv/input.txt")) == "changed resource"
    refute File.exists?(Path.join(changed, "note.txt"))
    assert File.read!(archive) == before_archive
    assert File.read!(archive <> ".build.json") == before_receipt
  end

  test "E1-B01 retargeting a resource alias to identical bytes preserves the published pair", %{root: root, a: a} do
    changed = copy!(a, Path.join(root, "retarget-resource"))
    archive = Path.join(changed, "bin/symphony")
    before_archive = File.read!(archive)
    before_receipt = File.read!(archive <> ".build.json")

    File.write!(Path.join(changed, "lib/retarget.ex"), ~S'''
    alias_priv = Application.app_dir(:identity_resource_fixture, "priv")
    other_priv = Path.expand("deps/other-resource/priv")
    File.mkdir_p!(other_priv)
    File.cp!(Path.join(alias_priv, "input.txt"), Path.join(other_priv, "input.txt"))
    File.rm!(alias_priv)
    File.ln_s!(other_priv, alias_priv)
    defmodule ResourceRetarget do
    end
    ''')

    assert {output, status} = run(changed, "mix", ["build"], @build_timeout)
    assert status != 0
    assert output =~ "external_resource_alias_mismatch"
    target = Path.join(changed, "deps/identity_resource_fixture/priv/input.txt")
    alias_path = Path.join(changed, "_build/dev/lib/identity_resource_fixture/priv/input.txt")
    assert File.read!(target) == File.read!(alias_path)
    refute File.stat!(target).inode == File.stat!(alias_path).inode
    assert File.read!(archive) == before_archive
    assert File.read!(archive <> ".build.json") == before_receipt
  end

  test "E1-B01 source budget is aggregate and rejects before compile without replacing the published pair", %{root: root, a: a} do
    oversized = copy!(a, Path.join(root, "source-budget"))
    archive_path = Path.join(oversized, "bin/symphony")
    receipt_path = archive_path <> ".build.json"
    original_archive = File.read!(archive_path)
    original_receipt = File.read!(receipt_path)

    for name <- ["budget-a.bin", "budget-b.bin"] do
      path = Path.join(oversized, name)

      File.open!(path, [:write, :binary], fn file ->
        assert {:ok, _position} = :file.position(file, {:bof, 32 * 1024 * 1024 - 1})
        assert :ok = IO.binwrite(file, <<0>>)
      end)

      assert File.stat!(path).size == 32 * 1024 * 1024
    end

    assert {output, status} = run(oversized, "mix", ["run", "--no-start", "--no-compile", "scripts/build-with-identity.exs"], @build_timeout)
    assert status != 0
    assert output =~ "source_budget_exceeded"
    refute output =~ "Compiling"
    assert File.read!(archive_path) == original_archive
    assert File.read!(receipt_path) == original_receipt
  end

  test "E1-B05/B11 invalid or missing receipts and manifests remain visible", %{root: root, a: a} do
    missing = copy!(a, Path.join(root, "missing-receipt"))
    File.rm!(Path.join(missing, "bin/symphony.build.json"))
    payload = invoke(missing, ["inspect"])
    assert payload["summary"]["capture_status"] == "unavailable"
    assert payload["summary"]["reason"] == "file_unavailable"

    duplicate = copy!(a, Path.join(root, "duplicate-receipt"))
    path = Path.join(duplicate, "bin/symphony.build.json")
    bytes = File.read!(path)
    File.write!(path, String.replace_prefix(bytes, "{", "{\"version\":1,"))
    assert invoke(duplicate, ["inspect"])["summary"]["reason"] == "duplicate_json_key"

    mismatched = copy!(a, Path.join(root, "mismatched-receipt"))
    path = Path.join(mismatched, "bin/symphony.build.json")
    File.write!(path, Jason.encode!(Map.put(receipt(mismatched), "escript_sha256", String.duplicate("0", 64))))
    assert invoke(mismatched, ["inspect"])["summary"]["reason"] == "receipt_mismatch"
  end

  test "E1-B05 explicit inspection rejects corrupt, duplicate and oversized archive entries", %{root: root, a: a} do
    for kind <- ["corrupt", "duplicate", "large"] do
      live = copy!(a, Path.join(root, "archive-" <> kind))
      payload = invoke(live, ["damage-archive", kind])
      assert payload["after"] == payload["before"]
      assert payload["disk"]["status"] == "unavailable"
      assert payload["disk"]["reason"] in ["invalid_archive", "file_unavailable"]
    end
  end

  test "E1-B05/B11 manifest schema failures remain read-only and distinct", %{root: root, a: a} do
    live = copy!(a, Path.join(root, "invalid-manifests"))
    payload = invoke(live, ["invalid-manifests"])

    assert Enum.map(payload["cases"], & &1["reason"]) == [
             "manifest_missing",
             "duplicate_json_key",
             "invalid_manifest",
             "invalid_manifest",
             "invalid_manifest",
             "invalid_manifest",
             "invalid_manifest",
             "invalid_manifest",
             "invalid_manifest",
             "invalid_manifest",
             "invalid_manifest",
             "invalid_manifest"
           ]

    assert Enum.all?(payload["cases"], & &1["bytes_preserved"])
    assert payload["before"] == payload["after"]
  end

  test "E1-B06/B15 A loaded while B replaces its disk archive retains startup A", %{root: root, a: a, b: b} do
    live = copy!(a, Path.join(root, "live"))
    payload = invoke(live, ["replace-disk", Path.join(b, "bin/symphony")])
    assert payload["before"] == payload["after"]
    assert payload["before"]["build_id"] == receipt(a)["build_id"]
    assert payload["disk"]["status"] == "disk_artifact_changed"
    assert [%{"status" => "matched"}] = payload["memory"]["results"]
  end

  test "E1-B07 current link moves to B but loaded process and captured artifact remain A", %{root: root, a: a, b: b} do
    current = Path.join(root, "current")
    File.ln_s!(a, current)
    payload = invoke(current, ["move-link", current, b])
    assert payload["before"] == payload["after"]
    assert payload["disk"]["status"] == "unchanged"
    assert File.read_link!(current) == b
    assert invoke(current, ["inspect"])["summary"]["build_id"] == receipt(b)["build_id"]
  end

  test "E1-B08/B09 filename and code path are not memory evidence; old code stays uncertain", %{a: a, b: b} do
    beam_b = Path.join(b, "_build/dev/lib/symphony_elixir/ebin/Elixir.SymphonyElixir.Probe.beam")
    payload = invoke(a, ["reload", beam_b])
    assert payload["before_value"] == "A"
    assert payload["after_value"] == "B"
    assert [%{"status" => "matched"}] = payload["before"]["results"]
    assert [%{"status" => "old_code_present"}] = payload["after"]["results"]
    assert payload["summary_before"] == payload["summary_after"]
  end

  test "E1-B08 misleading load_binary filename and disk code cannot replace memory evidence", %{a: a, b: b} do
    path = Path.join(b, "_build/dev/lib/symphony_elixir/ebin/Elixir.SymphonyElixir.Probe.beam")
    payload = invoke(a, ["filename", path])
    assert payload["filename"] == path
    refute payload["disk_md5"] == payload["memory_md5"]
    assert [%{"status" => "matched"}] = payload["memory"]["results"]
  end

  test "E1-B10 absent module is not loaded by inspection then matches after legitimate use", %{a: a} do
    payload = invoke(a, ["load-later"])
    assert [%{"status" => "not_loaded"}] = payload["before"]["results"]
    assert payload["value"] == "A"
    assert [%{"status" => "matched"}] = payload["after"]["results"]
  end

  defp seed!(root, repo_root \\ nil) do
    repo_root = repo_root || root
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "scripts"))
    File.cp!(@driver, Path.join(root, "scripts/build-with-identity.exs"))
    File.cp!(@runtime, Path.join(root, "lib/build_identity.ex"))
    File.write!(Path.join(root, ".gitignore"), "/_build/\n/deps/\n/bin/\n/priv/build_identity.json\n")

    File.write!(Path.join(root, "mix.exs"), """
    defmodule SymphonyElixir.MixProject do
      use Mix.Project
      def project do
        [app: :symphony_elixir, version: "0.1.0", deps: [{:identity_resource_fixture, path: "deps/identity_resource_fixture", runtime: false}],
         build_identity_resources: [identity_resource_fixture: "priv/input.txt"],
         escript: [app: nil, main_module: IdentityFixtureCLI, name: "symphony", path: "bin/symphony", include_priv_for: [:symphony_elixir]],
         aliases: [build: #{inspect(@build_alias)}]]
      end
      def application, do: [extra_applications: [:crypto]]
    end
    """)

    dependency = Path.join(root, "deps/identity_resource_fixture")
    File.mkdir_p!(Path.join(dependency, "lib"))
    File.mkdir_p!(Path.join(dependency, "priv"))
    File.write!(Path.join(dependency, "priv/input.txt"), "resource A")

    File.write!(Path.join(dependency, "mix.exs"), ~S'''
    defmodule IdentityResourceFixture.MixProject do
      use Mix.Project
      def project, do: [app: :identity_resource_fixture, version: "0.1.0", deps: []]
    end
    ''')

    File.write!(Path.join(dependency, "lib/resource.ex"), "defmodule IdentityResourceFixture do\n  def value, do: :fixture\nend\n")

    File.write!(Path.join(root, "lib/resource_probe.ex"), ~S'''
    defmodule SymphonyElixir.ResourceProbe do
      @path Application.app_dir(:identity_resource_fixture, "priv/input.txt")
      @external_resource @path
      @bytes File.read!(@path)
      def value, do: @bytes
    end
    ''')

    File.open!(Path.join(root, "source-input.bin"), [:write, :binary], fn file ->
      chunk = :binary.copy("S", 64 * 1024)
      Enum.each(1..256, fn _ -> :ok = IO.binwrite(file, chunk) end)
      :ok = IO.binwrite(file, "!")
    end)

    File.write!(Path.join(root, "source-empty.txt"), "")
    File.write!(Path.join(root, "lib/probe.ex"), probe("A"))
    File.write!(Path.join(root, "lib/cli.ex"), fixture_cli())
    foreign_root = if root == repo_root, do: Path.join(root, "elixir"), else: repo_root

    for {path, bytes} <- [{"bin/tool", "foreign tool A"}, {"_build/input", "foreign build input"}, {"deps/input", "foreign dependency input"}, {"priv/build_identity.json", "foreign manifest source"}] do
      full_path = Path.join(foreign_root, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, bytes)
    end

    git!(repo_root, ["init", "-b", "main"])
    git!(repo_root, ["config", "user.name", "Identity Test"])
    git!(repo_root, ["config", "user.email", "identity@example.invalid"])
    git!(repo_root, ["add", "."])
    git!(repo_root, ["commit", "-m", "A"])
  end

  defp probe(value) do
    """
    defmodule SymphonyElixir.Probe do
      def value, do: #{inspect(value)}
      def wait(parent) do
        send(parent, :holding_old_code)
        receive do :stop -> :ok end
      end
    end
    defprotocol FixtureProtocol do
      def value(term)
    end
    defimpl FixtureProtocol, for: Atom do
      def value(term), do: term
    end
    """
  end

  defp fixture_cli do
    ~S'''
    defmodule SymphonyElixir.Application do
      def start(_, _), do: File.write!("application-started", "unexpected")
    end
    defmodule IdentityFixtureCLI do
      alias SymphonyElixir.BuildIdentity, as: Identity
      def main(args) do
        Code.ensure_loaded!(SymphonyElixir.Application)
        :ok = Identity.capture_startup()
        IO.puts("IDENTITY=" <> IO.iodata_to_binary(:json.encode(run(args))))
      end
      defp run(["inspect"]) do
        %{summary: Identity.summary(), disk: Identity.inspect_artifact(), memory: Identity.inspect_loaded([Identity]), resource_value: SymphonyElixir.ResourceProbe.value()}
      end
      defp run(["replace-disk", source]) do
        before = Identity.summary()
        {:ok, %{result: {:ok, baseline}}} = Identity.capture()
        File.cp!(source, baseline.location.path)
        File.cp!(source <> ".build.json", baseline.location.path <> ".build.json")
        %{before: before, after: Identity.summary(), disk: Identity.inspect_artifact(), memory: Identity.inspect_loaded([Identity])}
      end
      defp run(["move-link", link, destination]) do
        before = Identity.summary()
        File.rm!(link)
        File.ln_s!(destination, link)
        %{before: before, after: Identity.summary(), disk: Identity.inspect_artifact()}
      end
      defp run(["load-later"]) do
        before = Identity.inspect_loaded([SymphonyElixir.Probe])
        value = SymphonyElixir.Probe.value()
        %{before: before, value: value, after: Identity.inspect_loaded([SymphonyElixir.Probe])}
      end
      defp run(["invalid-manifests"]) do
        before = Identity.summary()
        {:ok, %{result: {:ok, baseline}}} = Identity.capture()
        path = baseline.location.path
        {:ok, sections} = :escript.extract(String.to_charlist(path), [])
        {:ok, original} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])
        key = ~c"symphony_elixir/priv/build_identity.json"
        {^key, manifest_bytes} = List.keyfind(original, key, 0)
        manifest = :json.decode(manifest_bytes)
        source = manifest["source"]
        [resource] = source["external_resources"]
        bad_path = Map.put(resource, "resource_path", "../input.txt")
        over_budget = Map.put(resource, "size", 64 * 1024 * 1024)
        missing_resource = manifest_with_source(manifest, Map.delete(source, "external_resources"))
        invalid_resource = manifest_with_source(manifest, Map.put(source, "external_resources", [bad_path]))
        duplicate_resource = manifest_with_source(manifest, Map.put(source, "external_resources", [resource, resource]))
        aggregate_resource = manifest_with_source(manifest, Map.put(source, "external_resources", [over_budget]))
        wrong_fingerprint = manifest_with_build_id(put_in(manifest["source"]["fingerprint"], String.duplicate("0", 64)))
        cases = [nil, "{\"version\":1,\"version\":1}", :json.encode(Map.put(manifest, "version", 2)),
          :json.encode(manifest_with_build_id(Map.put(manifest, "modules", [hd(manifest["modules"]), hd(manifest["modules"])]))),
          :json.encode(Map.put(manifest, "compiled_inputs", false)),
          :json.encode(manifest_with_source_sizes(manifest, [64 * 1024 * 1024 + 1])),
          :json.encode(manifest_with_source_sizes(manifest, [32 * 1024 * 1024 + 1, 32 * 1024 * 1024])),
          :json.encode(missing_resource), :json.encode(invalid_resource), :json.encode(duplicate_resource),
          :json.encode(aggregate_resource), :json.encode(wrong_fingerprint)]
        results = Enum.map(cases, fn replacement ->
          entries = List.keydelete(original, key, 0)
          entries = if replacement, do: [{key, IO.iodata_to_binary(replacement)} | entries], else: entries
          {:ok, {_, archive}} = :zip.create(~c"memory", entries, [:memory])
          :ok = :escript.create(String.to_charlist(path), [:shebang, {:archive, archive}])
          bytes = File.read!(path)
          result = Identity.inspect_artifact()
          %{reason: result["reason"], bytes_preserved: File.read!(path) == bytes}
        end)
        %{before: before, after: Identity.summary(), cases: results}
      end
      defp run(["damage-archive", kind]) do
        before = Identity.summary()
        {:ok, %{result: {:ok, baseline}}} = Identity.capture()
        path = baseline.location.path
        case kind do
          "corrupt" -> File.write!(path, "corrupt")
          "duplicate" ->
            {:ok, {_, archive}} = :zip.create(~c"memory", [{~c"same", "A"}, {~c"same", "B"}], [:memory])
            :ok = :escript.create(String.to_charlist(path), [:shebang, {:archive, archive}])
          "large" ->
            {:ok, {_, archive}} = :zip.create(~c"memory", [{~c"large", :binary.copy("0", 16 * 1024 * 1024 + 1)}], [:memory])
            :ok = :escript.create(String.to_charlist(path), [:shebang, {:archive, archive}])
        end
        %{before: before, after: Identity.summary(), disk: Identity.inspect_artifact()}
      end
      defp run(["filename", path]) do
        Code.ensure_loaded!(SymphonyElixir.Probe)
        {SymphonyElixir.Probe, original, _} = :code.get_object_code(SymphonyElixir.Probe)
        {:module, SymphonyElixir.Probe} = :code.load_binary(SymphonyElixir.Probe, String.to_charlist(path), original)
        :code.purge(SymphonyElixir.Probe)
        :code.add_patha(String.to_charlist(Path.dirname(path)))
        {SymphonyElixir.Probe, disk, _} = :code.get_object_code(SymphonyElixir.Probe)
        {:ok, {_, disk_md5}} = :beam_lib.md5(disk)
        {:file, filename} = :code.is_loaded(SymphonyElixir.Probe)
        %{filename: List.to_string(filename), disk_md5: Base.encode16(disk_md5, case: :lower),
          memory_md5: Base.encode16(:erlang.get_module_info(SymphonyElixir.Probe, :md5), case: :lower),
          memory: Identity.inspect_loaded([SymphonyElixir.Probe])}
      end
      defp run(["reload", path]) do
        before_value = SymphonyElixir.Probe.value()
        before = Identity.inspect_loaded([SymphonyElixir.Probe])
        summary = Identity.summary()
        parent = self()
        holder = spawn(SymphonyElixir.Probe, :wait, [parent])
        receive do :holding_old_code -> :ok after 1000 -> raise "holder did not start" end
        bytes = File.read!(path)
        :code.add_patha(String.to_charlist(Path.dirname(path)))
        {:module, SymphonyElixir.Probe} = :code.load_binary(SymphonyElixir.Probe, String.to_charlist(path), bytes)
        result = %{before: before, after: Identity.inspect_loaded([SymphonyElixir.Probe]), before_value: before_value,
          after_value: SymphonyElixir.Probe.value(), summary_before: summary, summary_after: Identity.summary()}
        send(holder, :stop)
        result
      end
      # Negative schema fixtures only. Keep both digests valid so the
      # size/aggregate rejection cannot pass merely on a digest mismatch.
      defp manifest_with_source_sizes(manifest, sizes) do
        entries = sizes |> Enum.with_index() |> Enum.map(fn {size, index} ->
          %{"path" => "input-#{index}.bin", "size" => size, "sha256" => String.duplicate("0", 64)}
        end)
        source = Map.put(manifest["source"], "entries", entries)
        manifest_with_source(manifest, source)
      end
      defp manifest_with_source(manifest, source) do
        fingerprint = source |> Map.take(["entries", "external_resources"])
          |> canonical_manifest_value() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
        updated = Map.put(manifest, "source", Map.put(source, "fingerprint", fingerprint))
        manifest_with_build_id(updated)
      end
      defp manifest_with_build_id(manifest) do
        build_id = manifest |> Map.take(["source", "toolchain", "modules", "scope"])
          |> canonical_manifest_value() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
        Map.put(manifest, "build_id", build_id)
      end
      defp canonical_manifest_value(map) when is_map(map) do
        entries = map |> Enum.sort() |> Enum.map(fn {key, value} ->
          [:json.encode(key), ":", canonical_manifest_value(value)]
        end)
        ["{", Enum.intersperse(entries, ","), "}"]
      end
      defp canonical_manifest_value(list) when is_list(list) do
        ["[", Enum.intersperse(Enum.map(list, &canonical_manifest_value/1), ","), "]"]
      end
      defp canonical_manifest_value(value), do: :json.encode(value)
    end
    '''
  end

  defp copy!(source, destination) do
    File.cp_r!(source, destination)
    destination
  end

  defp invoke(root, args) do
    assert {output, 0} = run(root, "escript", [Path.join(root, "bin/symphony") | args], @runtime_timeout)
    line = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "IDENTITY="))
    assert is_binary(line), output
    line |> String.replace_prefix("IDENTITY=", "") |> Jason.decode!()
  end

  defp receipt(root), do: root |> Path.join("bin/symphony.build.json") |> File.read!() |> Jason.decode!()
  defp manifest(root), do: root |> Path.join("priv/build_identity.json") |> File.read!() |> Jason.decode!()

  defp run(root, executable, args, seconds) do
    watchdog = ~S'''
    import os, signal, subprocess, sys
    child = subprocess.Popen(sys.argv[2:], start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        output, _ = child.communicate(timeout=int(sys.argv[1]))
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        output, _ = child.communicate()
        sys.stdout.buffer.write(output)
        print("IDENTITY WATCHDOG TIMEOUT", flush=True)
        raise SystemExit(124)
    sys.stdout.buffer.write(output)
    raise SystemExit(child.returncode)
    '''

    System.cmd("python3", ["-c", watchdog, Integer.to_string(seconds), executable | args],
      cd: root,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "dev"}, {"MIX_TARGET", "host"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}, {"ERL_FLAGS", "+S 2:2"}]
    )
  end

  defp git!(root, args) do
    assert {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end
end
