defmodule GeoGenius.ManifestTest.SchemaProvider do
  @moduledoc false
  def required_options, do: ["code_property", "widget_key"]
end

defmodule GeoGenius.ManifestTest.SatisfiedSchemaProvider do
  @moduledoc false
  def required_options, do: ["code_property", "name_property"]
end

defmodule GeoGenius.ManifestTest do
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Manifest

  @paths [Path.expand("../support/manifests", __DIR__)]

  # The demo fixture's provider is "geojson", which resolves to the shipped
  # GeoGenius.Providers.GeoJSON without any host registration -- its
  # required_options keys are already present in the fixture's options. Tests
  # below that register their own providers to exercise option-key validation
  # do not clean up after themselves, so this restores a clean environment
  # before every test regardless of which one, if any, last touched it.
  setup do
    AppEnv.restore_on_exit(:providers)
  end

  defp valid_map do
    Manifest.to_map(Manifest.load!("demo", "r1", manifest_paths: @paths))
  end

  test "loads a manifest from the configured search path" do
    manifest = Manifest.load!("demo", "r1", manifest_paths: @paths)

    assert manifest.collection == "demo"
    assert manifest.release == "r1"
    assert manifest.provider == "geojson"
    assert manifest.requires_geometry == true
    assert manifest.source_date == ~D[2026-01-15]
    assert manifest.authorities == [%{key: "demo", name: "Demo Operations"}]
    assert manifest.area_types == [%{key: "territory", rank: 100}]
    assert manifest.options["code_property"] == "territory_id"
  end

  test "decodes the sources and artifacts into structs" do
    manifest = Manifest.load!("demo", "r1", manifest_paths: @paths)

    assert [source] = manifest.sources
    assert source.source_key == "demo:territories"
    assert source.license == "CC0-1.0"
    assert source.release_key == "2026-01"

    assert [artifact] = source.artifacts
    assert artifact.logical_name == "territories.geojson"
    assert artifact.url == "https://example.test/territories.geojson"
    assert artifact.operator_supplied == false
    assert artifact.bytes == 4096
    assert artifact.required == true
    assert artifact.members == ["territories.geojson"]
  end

  test "load returns an error tuple for a manifest that is not on the search path" do
    assert {:error, %GeoGenius.ManifestError{} = error} =
             Manifest.load("demo", "nope", manifest_paths: @paths)

    assert error.reason =~ "no manifest for collection \"demo\" release \"nope\""
  end

  test "load! raises for a manifest that fails validation" do
    error =
      assert_raise GeoGenius.ManifestError, fn ->
        Manifest.load!("demo", "invalid", manifest_paths: @paths)
      end

    assert error.reason =~ "sha256"
    assert error.path =~ "invalid.json"
  end

  test "rejects a collection name that could escape the manifest directory" do
    for escape <- ["../etc", "/etc/passwd", "demo/../..", ".."] do
      assert {:error, %GeoGenius.ManifestError{path: nil, reason: reason}} =
               Manifest.load(escape, "r1", manifest_paths: @paths)

      assert reason =~ "is not a valid name",
             "expected #{inspect(escape)} to be rejected by the safe-name rule before any " <>
               "path was built, got: #{reason}"
    end
  end

  test "rejects a release name that could escape the manifest directory" do
    assert {:error, %GeoGenius.ManifestError{path: nil, reason: reason}} =
             Manifest.load("demo", "../../secrets", manifest_paths: @paths)

    assert reason =~ "is not a valid name"
  end

  test "a name rejected by validate_name/2 carries no path, unlike a genuine not-found" do
    assert {:error, %GeoGenius.ManifestError{path: nil}} =
             Manifest.load("../etc", "r1", manifest_paths: @paths)

    assert {:error, %GeoGenius.ManifestError{path: path}} =
             Manifest.load("demo", "nope", manifest_paths: @paths)

    refute is_nil(path),
           "a name that reached locate/3 and found nothing should carry the candidate it checked"
  end

  test "a bait file placed exactly where an unguarded join would resolve is never read" do
    bait_dir = Path.expand(Path.join([hd(@paths), "..", "etc"]))
    File.mkdir_p!(bait_dir)
    File.write!(Path.join(bait_dir, "r1.json"), ~s({"collection":"x"}))
    on_exit(fn -> File.rm_rf!(bait_dir) end)

    # "../etc" joined onto hd(@paths) resolves, at the filesystem level, to
    # exactly bait_dir/r1.json -- the file above is not unreachable bait, it
    # sits precisely where locate/3 would find it if validate_name/2 did not
    # run first.
    assert {:error, %GeoGenius.ManifestError{path: nil, reason: reason}} =
             Manifest.load("../etc", "r1", manifest_paths: @paths)

    assert reason =~ "is not a valid name"
  end

  test "from_map round-trips through to_map" do
    map = valid_map()

    assert {:ok, manifest} = Manifest.from_map(map)
    assert Manifest.to_map(manifest) == map
  end

  test "to_map matches the raw fixture exactly, not a value derived from our own code" do
    fixture_path = Path.join([hd(@paths), "demo", "r1.json"])
    raw = Jason.decode!(File.read!(fixture_path))

    assert Manifest.to_map(Manifest.load!("demo", "r1", manifest_paths: @paths)) == raw
  end

  test "rejects a manifest with no sources" do
    map = Map.put(valid_map(), "sources", [])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "sources"
  end

  test "rejects a manifest missing the provider field" do
    map = Map.delete(valid_map(), "provider")

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "provider is required"
  end

  test "rejects an unknown provider" do
    map = Map.put(valid_map(), "provider", "no_such_provider")

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "is not a known provider"
  end

  # A provider name whose module does not load contributes no required option
  # keys only because nothing about it can be read. Reading that as "requires
  # nothing" accepted every options block written for the provider.
  test "rejects a manifest whose provider module does not load" do
    map = Map.put(valid_map(), "provider", "ghost")

    Application.put_env(:geo_genius, :providers, %{
      "ghost" => GeoGenius.ManifestTest.NoSuchProvider
    })

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "does not load"
    assert reason =~ "GeoGenius.ManifestTest.NoSuchProvider"
  end

  test "rejects a source missing its license" do
    map = update_in(valid_map(), ["sources", Access.at(0)], &Map.delete(&1, "license"))

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "license"
  end

  test "rejects a source with no artifacts" do
    map = update_in(valid_map(), ["sources", Access.at(0)], &Map.put(&1, "artifacts", []))

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "artifacts"
  end

  test "rejects an artifact whose logical_name is not a safe name" do
    map = put_in_artifact(valid_map(), "logical_name", "../escape")

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "logical_name"
  end

  test "rejects an artifact missing its format" do
    map = delete_in_artifact(valid_map(), "format")

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "format"
  end

  test "rejects a malformed sha256, naming the field" do
    map = put_in_artifact(valid_map(), "sha256", "not-a-digest")

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "sha256"
  end

  test "rejects an artifact that is both downloadable and operator-supplied" do
    map = put_in_artifact(valid_map(), "operator_supplied", true)

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "operator_supplied"
  end

  test "rejects an artifact that is neither downloadable nor operator-supplied" do
    map =
      valid_map()
      |> put_in_artifact("url", nil)
      |> put_in_artifact("operator_supplied", false)

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "operator_supplied"
  end

  test "accepts an operator-supplied artifact with no url" do
    map =
      valid_map()
      |> put_in_artifact("url", nil)
      |> put_in_artifact("operator_supplied", true)

    assert {:ok, manifest} = Manifest.from_map(map)
    assert [%{artifacts: [artifact]}] = manifest.sources
    assert artifact.operator_supplied == true
    assert artifact.url == nil
  end

  test "rejects a members list that is not a list of strings" do
    for bad <- ["shp", %{"0" => "shp"}, ["shp", 42], ["shp", ""]] do
      map = put_in_artifact(valid_map(), "members", bad)

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map),
             "members accepted #{inspect(bad)}"

      assert reason =~ "members"
    end
  end

  test "accepts an artifact with no members and one listing archive members" do
    assert {:ok, manifest} = Manifest.from_map(put_in_artifact(valid_map(), "members", nil))
    assert [%{artifacts: [artifact]}] = manifest.sources
    assert artifact.members == []

    map = put_in_artifact(valid_map(), "members", ["shape.shp", "shape.dbf"])
    assert {:ok, manifest} = Manifest.from_map(map)
    assert [%{artifacts: [artifact]}] = manifest.sources
    assert artifact.members == ["shape.shp", "shape.dbf"]
  end

  test "rejects a non-positive byte count" do
    map = put_in_artifact(valid_map(), "bytes", 0)

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "bytes"
  end

  test "rejects a manifest missing an option key the provider's schema requires" do
    map = Map.put(valid_map(), "provider", "schema_provider")

    Application.put_env(:geo_genius, :providers, %{
      "schema_provider" => GeoGenius.ManifestTest.SchemaProvider
    })

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "widget_key"
  end

  test "accepts a manifest whose options satisfy the provider's required keys" do
    map = Map.put(valid_map(), "provider", "satisfied_provider")

    Application.put_env(:geo_genius, :providers, %{
      "satisfied_provider" => GeoGenius.ManifestTest.SatisfiedSchemaProvider
    })

    assert {:ok, manifest} = Manifest.from_map(map)
    assert manifest.provider == "satisfied_provider"
  end

  test "accepts a valid cache_key and carries it through to artifact metadata" do
    map =
      put_in_artifact(
        valid_map(),
        "cache_key",
        "demo/demo:territories/2026-01/territories.geojson"
      )

    assert {:ok, manifest} = Manifest.from_map(map)
    assert [%{artifacts: [artifact]}] = manifest.sources
    assert artifact.metadata["cache_key"] == "demo/demo:territories/2026-01/territories.geojson"
    assert Manifest.to_map(manifest) == map
  end

  test "rejects a cache_key that could escape the cache root, naming the field" do
    map = put_in_artifact(valid_map(), "cache_key", "demo/../../secrets")

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "cache_key"
  end

  test "rejects a malformed source_date, naming the field" do
    map = Map.put(valid_map(), "source_date", "not-a-date")

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "source_date"
  end

  test "a manifest with no source_date leaves it nil" do
    map = Map.delete(valid_map(), "source_date")

    assert {:ok, manifest} = Manifest.from_map(map)
    assert manifest.source_date == nil
  end

  test "carries every authority a collection draws on, in the order declared" do
    authorities = [
      %{"key" => "census", "name" => "US Census Bureau"},
      %{"key" => "usps", "name" => "US Postal Service"}
    ]

    map = Map.put(valid_map(), "authorities", authorities)

    assert {:ok, manifest} = Manifest.from_map(map)

    assert manifest.authorities == [
             %{key: "census", name: "US Census Bureau"},
             %{key: "usps", name: "US Postal Service"}
           ]

    assert Manifest.to_map(manifest)["authorities"] == authorities
  end

  test "rejects a manifest that declares no authorities, naming the field" do
    map = Map.delete(valid_map(), "authorities")

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "authorities"
  end

  test "rejects an empty authorities list, naming the field" do
    map = Map.put(valid_map(), "authorities", [])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "authorities"
  end

  # A file written against the singular `authority` key decodes with no
  # `authorities` at all. Accepting that as "declares none" would carry a
  # manifest that names its authority in a key nothing reads all the way to
  # `upsert_area`, which raises `:no_data_found` from PL/pgSQL partway through
  # normalization. The stale key is caught here instead, at load.
  test "rejects a manifest carrying the singular authority key instead of reading it" do
    map =
      valid_map()
      |> Map.delete("authorities")
      |> Map.put("authority", %{"key" => "demo", "name" => "Demo Operations"})

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "authorities"
  end

  test "rejects a null authorities, instead of raising Enumerable errors on nil" do
    map = Map.put(valid_map(), "authorities", nil)

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "authorities"
  end

  test "rejects a bare object where the authorities list belongs, instead of raising" do
    map = Map.put(valid_map(), "authorities", %{"key" => "demo", "name" => "Demo Operations"})

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "authorities"
  end

  test "rejects authorities entries that are not objects, instead of raising" do
    map = Map.put(valid_map(), "authorities", ["demo"])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "authorities"
  end

  # Validation covers the documents `from_map/2` reads. A `%Manifest{}` built
  # in Elixir skips it entirely, and without the enforced key it would default
  # `authorities` to nil and surface as a Protocol.UndefinedError from
  # registration's Enum.each rather than as an error naming the field.
  test "refuses to build a manifest struct that names no authorities" do
    fields = %{collection: "demo", release: "r1", provider: "geojson", sources: []}

    error = assert_raise ArgumentError, fn -> struct!(Manifest, fields) end

    assert Exception.message(error) =~ "authorities"
  end

  test "rejects a null area_types, instead of raising Enumerable errors on nil" do
    map = Map.put(valid_map(), "area_types", nil)

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "area_types"
  end

  test "rejects area_types entries that are not objects, instead of raising" do
    map = Map.put(valid_map(), "area_types", ["territory"])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "area_types"

    map = Map.put(valid_map(), "area_types", [1])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "area_types"
  end

  test "rejects a blank required string with a message that does not read as nonsense" do
    map = update_in(valid_map(), ["sources", Access.at(0)], &Map.put(&1, "license", ""))

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason == "license must not be blank"
  end

  defp put_in_artifact(map, key, value) do
    update_in(map, ["sources", Access.at(0), "artifacts", Access.at(0)], fn artifact ->
      Map.put(artifact, key, value)
    end)
  end

  defp delete_in_artifact(map, key) do
    update_in(map, ["sources", Access.at(0), "artifacts", Access.at(0)], fn artifact ->
      Map.delete(artifact, key)
    end)
  end
end
