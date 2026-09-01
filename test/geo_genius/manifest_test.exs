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

  test "rejects the same logical_name on two sources" do
    map = valid_map()
    [source] = map["sources"]
    second = %{source | "source_key" => "other"}
    map = %{map | "sources" => [source, second]}

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason =~ "logical_name"
    assert reason =~ "more than one artifact"
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

  # An entry that names no key or no name cannot register an authority:
  # `upsert_authority` writes NOT NULL columns, so an entry validated no
  # further than "is a map" dies as a `CatalogError` naming a SQL function
  # partway through the import. Checking the entry's own fields is what keeps
  # the moduledoc's promise that a failure names the field, at load.
  test "rejects an authorities entry that names no key, naming the field" do
    map = Map.put(valid_map(), "authorities", [%{}])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason == "authorities entry key is required"
  end

  test "rejects an authorities entry that names no name, naming the field" do
    map = Map.put(valid_map(), "authorities", [%{"key" => "census"}])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason == "authorities entry name is required"
  end

  test "rejects an authorities entry whose key is not a string, naming the field" do
    map = Map.put(valid_map(), "authorities", [%{"key" => 10, "name" => "US Census Bureau"}])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason == "authorities entry key must be a string, got: 10"
  end

  # `rank` orders the area types of a collection, and `upsert_area_type`
  # writes it to an integer column. A quoted rank is the shape a hand-edited
  # manifest reaches for, and it fails the cast in PL/pgSQL rather than here
  # unless the entry's fields are checked.
  test "rejects an area_types entry that names no key, naming the field" do
    map = Map.put(valid_map(), "area_types", [%{"rank" => 100}])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason == "area_types entry key is required"
  end

  test "rejects an area_types entry that names no rank, naming the field" do
    map = Map.put(valid_map(), "area_types", [%{"key" => "bounded_zone"}])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason == "area_types entry rank is required"
  end

  test "rejects an area_types entry whose rank is not a positive integer, naming the field" do
    map = Map.put(valid_map(), "area_types", [%{"key" => "bounded_zone", "rank" => "10"}])

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason == "area_types entry rank must be a positive integer, got: \"10\""
  end

  test "area_types accept optional requires_geometry booleans and preserve explicit values" do
    area_types = [
      %{"key" => "bounded_zone", "rank" => 10, "requires_geometry" => true},
      %{"key" => "parent_record", "rank" => 20},
      %{"key" => "metadata_record", "rank" => 30, "requires_geometry" => false}
    ]

    map = Map.put(valid_map(), "area_types", area_types)

    assert {:ok, manifest} = Manifest.from_map(map)

    assert manifest.area_types == [
             %{key: "bounded_zone", rank: 10, requires_geometry: true},
             %{key: "parent_record", rank: 20},
             %{key: "metadata_record", rank: 30, requires_geometry: false}
           ]

    assert Manifest.to_map(manifest)["area_types"] == area_types
  end

  test "area_types reject non-boolean requires_geometry values" do
    for value <- ["true", 1, nil, %{}, []] do
      map =
        Map.put(valid_map(), "area_types", [
          %{"key" => "bounded_zone", "rank" => 10, "requires_geometry" => value}
        ])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map),
             "requires_geometry accepted #{inspect(value)}"

      assert reason ==
               "area_types entry requires_geometry must be a boolean, got: #{inspect(value)}"
    end
  end

  # The first failing entry is the one reported: a later well-formed entry
  # does not mask an earlier malformed one, and the message says which list
  # the entry came from rather than only which field.
  test "reports the first malformed entry of a list whose other entries are valid" do
    authorities = [
      %{"key" => "census", "name" => "US Census Bureau"},
      %{"key" => "usps"},
      %{"key" => "simplemaps", "name" => "SimpleMaps"}
    ]

    map = Map.put(valid_map(), "authorities", authorities)

    assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
    assert reason == "authorities entry name is required"
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

  # A provider that exports `validate_options/1` is handed the manifest's whole
  # options map at load, after the required keys are known to be present. That
  # is what turns an option only the provider understands -- `implied_areas`,
  # whose entries name their code key in the provider's own vocabulary -- into
  # an error naming the field before a release row exists, rather than a
  # per-row failure partway through normalizing an artifact already downloaded
  # and staged. The demo fixture's provider is "geojson", so the entries below
  # are read under that vocabulary.
  describe "provider option validation at load" do
    test "accepts a well-formed implied_areas entry" do
      map =
        with_implied_areas([
          %{
            "area_type" => "cluster",
            "code_property" => "CLUSTER",
            "names" => %{"1" => "Cluster One"}
          }
        ])

      assert {:ok, manifest} = Manifest.from_map(map)
      assert [%{"area_type" => "cluster"}] = manifest.options["implied_areas"]
    end

    test "rejects an implied_areas that is not a list" do
      map = with_implied_areas(%{"area_type" => "cluster"})

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "implied_areas must be a list"
    end

    test "rejects an implied_areas entry that is not an object" do
      map = with_implied_areas(["cluster"])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "implied_areas entry must be an object"
    end

    test "rejects an implied_areas entry that names no area_type" do
      map = with_implied_areas([%{"code_property" => "CLUSTER"}])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ ~s(implied_areas entry requires "area_type")
    end

    test "rejects an implied_areas entry whose area_type is blank" do
      map = with_implied_areas([%{"area_type" => "", "code_property" => "CLUSTER"}])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ ~s(implied_areas entry requires "area_type")
    end

    test "rejects an unknown implied_areas relation" do
      map =
        with_implied_areas([
          %{"area_type" => "cluster", "code_property" => "CLUSTER", "relation" => "near"}
        ])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "implied_areas relation must be one of"
      assert reason =~ "near"
    end

    test "rejects an implied_areas names map that is not an object" do
      map =
        with_implied_areas([
          %{"area_type" => "cluster", "code_property" => "CLUSTER", "names" => ["Cluster One"]}
        ])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "implied_areas names must be an object"
    end

    test "rejects an implied_areas names entry whose value is not a string" do
      map =
        with_implied_areas([
          %{"area_type" => "cluster", "code_property" => "CLUSTER", "names" => %{"1" => 42}}
        ])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "implied_areas names entry"
      assert reason =~ "string key and a string value"
    end

    # The code key an entry names is the calling provider's own, so the same
    # document is valid under one provider and invalid under another. Without
    # this, a manifest could name `code_column` under a GeoJSON provider and
    # load cleanly, then fail on every row -- which is the failure this whole
    # gate exists to move forward.
    test "rejects an implied_areas entry naming the CSV vocabulary under a GeoJSON provider" do
      map = with_implied_areas([%{"area_type" => "cluster", "code_column" => "CLUSTER"}])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ ~s(implied_areas entry requires "code_property")
    end

    test "accepts under a CSV provider the entry a GeoJSON provider rejects" do
      map =
        valid_map()
        |> Map.put("provider", "csv")
        |> put_source_provider("csv")
        |> put_option("code_column", "territory_id")
        |> put_option("implied_areas", [
          %{
            "area_type" => "cluster",
            "code_column" => "CLUSTER",
            "names" => %{"1" => "Cluster One"}
          }
        ])

      assert {:ok, manifest} = Manifest.from_map(map)
      assert manifest.provider == "csv"
    end

    # `validate_options/1` is optional. A provider that does not export it
    # contributes no checks, rather than every manifest naming it failing to
    # load.
    test "accepts a manifest whose provider exports no validate_options/1" do
      map =
        valid_map()
        |> Map.put("provider", "satisfied_provider")
        |> put_source_provider("satisfied_provider")
        |> put_option("implied_areas", "not even a list")

      Application.put_env(:geo_genius, :providers, %{
        "satisfied_provider" => GeoGenius.ManifestTest.SatisfiedSchemaProvider
      })

      assert {:ok, manifest} = Manifest.from_map(map)
      assert manifest.provider == "satisfied_provider"
    end

    # The required-key check runs first, so a manifest that is missing a
    # required key and also carries a malformed option reports the missing key.
    # Reporting the option instead would send an operator to fix the entry that
    # is not the reason the manifest cannot be used.
    test "reports a missing required key before a malformed option" do
      map =
        valid_map()
        |> Map.delete("options")
        |> Map.put("options", %{"implied_areas" => "not even a list"})

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "missing required key"
    end
  end

  # A release composed of sources in different formats names a provider per
  # source. The release's own `provider` is the default rather than the only
  # answer, so a single-provider manifest -- every manifest written before this
  # existed -- keeps loading unchanged.
  describe "per-source providers" do
    test "a source that names no provider inherits the manifest's" do
      map = update_in(valid_map(), ["sources", Access.at(0)], &Map.delete(&1, "provider"))

      assert {:ok, manifest} = Manifest.from_map(map)
      assert [%{provider: "geojson"}] = manifest.sources
    end

    # `simplemaps` rather than `csv`: option validation soon covers every
    # provider a manifest names, and the demo fixture's options carry
    # `code_property` but not `code_column`.
    test "a source's own provider overrides the manifest's" do
      map =
        valid_map()
        |> put_source_provider("simplemaps")
        |> Map.update!("area_types", &[%{"key" => "state", "rank" => 10} | &1])

      assert {:ok, manifest} = Manifest.from_map(map)
      assert manifest.provider == "geojson"
      assert [%{provider: "simplemaps"}] = manifest.sources
    end

    test "rejects a source naming a provider that does not resolve" do
      map = put_source_provider(valid_map(), "no_such_provider")

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "no_such_provider"
    end

    test "rejects a source whose provider is not a string" do
      map = put_source_provider(valid_map(), 7)

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "provider must be a string"
    end

    # The resolved default is written back, so a document that omitted the key
    # round-trips to one that names it and the catalog row registration writes
    # never carries a null provider.
    test "to_map writes the resolved provider for a source that omitted it" do
      map = update_in(valid_map(), ["sources", Access.at(0)], &Map.delete(&1, "provider"))

      assert {:ok, manifest} = Manifest.from_map(map)
      assert [%{"provider" => "geojson"}] = Manifest.to_map(manifest)["sources"]
      assert {:ok, ^manifest} = Manifest.from_map(Manifest.to_map(manifest))
    end

    # Two providers stage this release, so the options map must satisfy both.
    # Validating only the release's own would let a manifest load that the
    # source provider cannot stage a single row of.
    test "requires the option keys a source's provider needs" do
      map =
        valid_map()
        |> Map.put("provider", "simplemaps")
        |> put_source_provider("csv")
        |> put_option("area_type", "territory")

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ "code_column"
      assert reason =~ "GeoGenius.Providers.CSV"
    end

    test "runs a source provider's validate_options/1" do
      map =
        valid_map()
        |> Map.put("provider", "simplemaps")
        |> put_source_provider("geojson")
        |> put_option("implied_areas", [%{"area_type" => "cluster", "code_column" => "C"}])

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ ~s(implied_areas entry requires "code_property")
    end

    test "runs a source provider's whole-manifest validation" do
      map =
        valid_map()
        |> put_source_provider("simplemaps")
        |> put_option("non_census_state_area_type", "postal_region")

      assert {:error, %GeoGenius.ManifestError{reason: reason}} = Manifest.from_map(map)
      assert reason =~ ~s(non_census_state_area_type "postal_region")
      assert reason =~ "area_types"
    end

    test "accepts options that satisfy both the release and source providers" do
      map =
        valid_map()
        |> Map.put("provider", "simplemaps")
        |> put_source_provider("geojson")
        |> Map.update!("area_types", &[%{"key" => "state", "rank" => 10} | &1])
        |> put_option("implied_areas", [
          %{"area_type" => "cluster", "code_property" => "C", "names" => %{"1" => "One"}}
        ])

      assert {:ok, manifest} = Manifest.from_map(map)
      assert manifest.provider == "simplemaps"
      assert [%{provider: "geojson"}] = manifest.sources
    end
  end

  defp put_source_provider(map, provider) do
    update_in(map, ["sources", Access.at(0)], &Map.put(&1, "provider", provider))
  end

  defp put_option(map, key, value) do
    update_in(map, ["options"], &Map.put(&1, key, value))
  end

  defp with_implied_areas(entries) do
    put_option(valid_map(), "implied_areas", entries)
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
