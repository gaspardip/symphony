defmodule SymphonyElixir.BuildIdentityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.BuildIdentity

  @keys [{BuildIdentity, :startup}]

  setup do
    saved = Enum.map(@keys, &{&1, :persistent_term.get(&1, :missing)})
    Enum.each(@keys, &:persistent_term.erase/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, :missing} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)
    end)

    :ok
  end

  test "E1-B11 absent capture stays explicit and getters never initialize it" do
    assert BuildIdentity.summary() == %{"capture_status" => "not_captured", "basis" => "startup_capture"}
    assert {:error, :not_captured} = BuildIdentity.capture()
    assert BuildIdentity.inspect_artifact()["reason"] == "not_captured"
    assert BuildIdentity.inspect_loaded([__MODULE__])["reason"] == "not_captured"
    assert Enum.all?(@keys, &(:persistent_term.get(&1, :missing) == :missing))
  end

  test "E1-B11 a second startup retains an unavailable baseline too" do
    record = %{result: {:error, :manifest_missing}, location: {:error, :loaded_location_unavailable}, captured_at: "first"}
    summary = %{"capture_status" => "unavailable", "captured_at" => "first"}
    put_record(record, summary)
    assert :ok = BuildIdentity.capture_startup()
    assert {:ok, ^record} = BuildIdentity.capture()
    assert BuildIdentity.summary() == summary
  end

  test "E1-B12 maximal stored inventory does not make summary enumerate or perform IO" do
    # A structural fixture for getter purity, not evidence of a verified artifact.
    index = Map.new(1..10_000, &{"module#{&1}", %{"code_md5" => String.duplicate("0", 32)}})
    baseline(index)
    summary = %{"basis" => "startup_capture", "capture_status" => "captured", "module_count" => 10_000}
    {:ok, record} = BuildIdentity.capture()
    put_record(record, summary)
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :go -> send(parent, {:summary, BuildIdentity.summary()})
        end
      end)

    targets = [{:file, :_, :_}, {:crypto, :hash, :_}, {:code, :all_loaded, 0}, {:erlang, :loaded, 0}, {Enum, :_, :_}, {:persistent_term, :put, 2}]
    Enum.each(targets, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(worker, true, [:call, {:tracer, self()}])

    try do
      send(worker, :go)
      assert_receive {:summary, ^summary}
      refute_receive {:trace, ^worker, :call, _}, 50
      assert byte_size(Jason.encode!(summary)) < 2048
    after
      Enum.each(targets, &:erlang.trace_pattern(&1, false, [:local]))
    end
  end

  test "E1-B10 scoped observation does not load an absent known module or accept unknown scopes" do
    absent = SymphonyElixir.IdentityNotLoadedFixture
    baseline(%{Atom.to_string(absent) => %{"code_md5" => String.duplicate("0", 32)}})
    assert :code.is_loaded(absent) == false
    assert [%{"status" => "not_loaded"}] = BuildIdentity.inspect_loaded([absent])["results"]
    assert :code.is_loaded(absent) == false

    for scope <- [[], [absent, absent], [__MODULE__], ["Elixir.NewUntrustedAtom"], List.duplicate(absent, 257)] do
      assert BuildIdentity.inspect_loaded(scope)["reason"] == "unknown_scope"
    end
  end

  test "E1-B08 memory digest is checked independently of disk helpers" do
    md5 = :erlang.get_module_info(__MODULE__, :md5) |> Base.encode16(case: :lower)
    baseline(%{Atom.to_string(__MODULE__) => %{"code_md5" => md5}})
    status = BuildIdentity.inspect_loaded([__MODULE__])["results"] |> hd() |> Map.fetch!("status")
    assert status in ["matched", "cover_compiled"]
    baseline(%{Atom.to_string(__MODULE__) => %{"code_md5" => String.duplicate("0", 32)}})
    status = BuildIdentity.inspect_loaded([__MODULE__])["results"] |> hd() |> Map.fetch!("status")
    assert status in ["mismatch", "cover_compiled"]
  end

  test "E1-B15 unavailable artifact inspection does not replace the startup diagnostic" do
    root = Path.join(System.tmp_dir!(), "identity-missing-#{System.unique_integer([:positive])}")
    summary = %{"basis" => "startup_capture", "build_id" => "A", "captured_at" => "first"}
    put_record(%{result: {:error, :manifest_missing}, location: {:ok, %{mode: "beam", path: root, manifest_path: Path.join(root, "missing")}}}, summary)
    assert BuildIdentity.inspect_artifact()["reason"] == "file_unavailable"
    assert BuildIdentity.summary() == summary
  end

  defp put_record(record, summary), do: :persistent_term.put({BuildIdentity, :startup}, %{record: record, summary: summary})

  defp baseline(index) do
    put_record(%{result: {:ok, %{index: index}}, captured_at: "fixture"}, %{})
  end
end
