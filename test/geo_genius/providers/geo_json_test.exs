defmodule GeoGenius.Providers.GeoJSONTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Manifest
  alias GeoGenius.Provider.Area
  alias GeoGenius.Provider.Area.Code
  alias GeoGenius.Provider.Area.Name
  alias GeoGenius.Providers.GeoJSON
  alias GeoGenius.Staging

  @fixture Path.expand("../../support/artifacts/territories.geojson", __DIR__)

  defp manifest(options \\ %{}) do
    %Manifest{
      collection: "demo",
      release: "r1",
      provider: "geojson",
      authorities: [%{key: "demo", name: "Demo"}],
      area_types: [%{key: "territory", rank: 100}],
      sources: [],
      options:
        Map.merge(
          %{
            "area_type" => "territory",
            "code_property" => "territory_id",
            "name_property" => "territory_name"
          },
          options
        )
    }
  end

  # Carries only the two required keys, so a test can omit an optional key
  # entirely and exercise its real default rather than the default `manifest/1`
  # itself hardcodes for the other tests' convenience.
  defp bare_manifest(options \\ %{}) do
    %Manifest{
      collection: "demo",
      release: "r1",
      provider: "geojson",
      authorities: [%{key: "demo", name: "Demo"}],
      area_types: [%{key: "territory", rank: 100}],
      sources: [],
      options:
        Map.merge(%{"area_type" => "territory", "code_property" => "territory_id"}, options)
    }
  end

  defp artifact do
    %Manifest.Artifact{
      logical_name: "territories.geojson",
      format: "geojson",
      operator_supplied: true,
      sha256: String.duplicate("0", 64),
      bytes: 1,
      required: true
    }
  end

  defp stage_all(manifest) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn rows -> Agent.update(agent, &(&1 ++ rows)) end
    :ok = GeoJSON.stage(manifest, artifact(), @fixture, emit, [])
    Agent.get(agent, & &1)
  end

  defp tmp_geojson(content) do
    path = Path.join(System.tmp_dir!(), "gg_bad_#{System.unique_integer([:positive])}.geojson")
    File.write!(path, content)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "declares the manifest option keys it requires" do
    assert "area_type" in GeoJSON.required_options()
    assert "code_property" in GeoJSON.required_options()
  end

  test "validate_options accepts implied_areas entries naming code_property" do
    options = %{
      "implied_areas" => [
        %{"area_type" => "cluster", "code_property" => "CLUSTER", "names" => %{"1" => "One"}}
      ]
    }

    assert GeoJSON.validate_options(options) == :ok
  end

  # The option vocabulary is this provider's own, so an entry written for the
  # other generic provider is rejected here rather than accepted and failed on
  # every row.
  test "validate_options rejects an implied_areas entry naming code_column instead" do
    options = %{"implied_areas" => [%{"area_type" => "cluster", "code_column" => "CLUSTER"}]}

    assert {:error, reason} = GeoJSON.validate_options(options)
    assert reason =~ ~s("code_property")
  end

  test "validate_options accepts options that declare no implied areas" do
    assert GeoJSON.validate_options(%{"code_property" => "id"}) == :ok
  end

  test "artifacts returns every artifact across the manifest's sources" do
    source_a = %Manifest.Source{
      source_key: "a",
      provider: "geojson",
      license: "CC0-1.0",
      release_key: "r1",
      artifacts: [
        %Manifest.Artifact{
          logical_name: "a.geojson",
          format: "geojson",
          operator_supplied: true,
          sha256: String.duplicate("0", 64),
          bytes: 1,
          required: true
        }
      ]
    }

    source_b = %Manifest.Source{
      source_key: "b",
      provider: "geojson",
      license: "CC0-1.0",
      release_key: "r1",
      artifacts: [
        %Manifest.Artifact{
          logical_name: "b.geojson",
          format: "geojson",
          operator_supplied: true,
          sha256: String.duplicate("1", 64),
          bytes: 1,
          required: true
        }
      ]
    }

    manifest = %{manifest() | sources: [source_a, source_b]}

    assert Enum.map(GeoJSON.artifacts(manifest), & &1.logical_name) == ["a.geojson", "b.geojson"]
  end

  test "stages one row per feature" do
    rows = stage_all(manifest())

    assert length(rows) == 3
    assert Enum.map(rows, & &1.artifact) == List.duplicate("territories.geojson", 3)
  end

  test "the staged payload is the feature's properties" do
    [first | _] = stage_all(manifest())

    assert first.payload["territory_id"] == "west"
    assert first.payload["population"] == 1200
  end

  test "decodes each feature's geometry, and leaves a null geometry nil" do
    rows = stage_all(manifest())

    assert [%{geom: %Geo.Polygon{}}, %{geom: %Geo.Polygon{}}, %{geom: nil}] = rows
  end

  test "chunks a large artifact into multiple emit calls" do
    feature_count = 2_500

    features =
      for i <- 1..feature_count do
        %{"type" => "Feature", "properties" => %{"territory_id" => "t#{i}"}, "geometry" => nil}
      end

    document = %{"type" => "FeatureCollection", "features" => features}
    path = tmp_geojson(Jason.encode!(document))

    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn rows -> Agent.update(agent, &[length(rows) | &1]) end

    assert :ok = GeoJSON.stage(manifest(), artifact(), path, emit, [])

    chunk_sizes = Agent.get(agent, & &1) |> Enum.reverse()

    assert length(chunk_sizes) > 1,
           "expected more than one emit call for #{feature_count} features"

    assert Enum.sum(chunk_sizes) == feature_count
  end

  test "rejects a document that is not a FeatureCollection" do
    path = tmp_geojson(~s({"type":"Polygon","coordinates":[]}))

    assert {:error, reason} = GeoJSON.stage(manifest(), artifact(), path, fn _ -> :ok end, [])
    assert reason =~ "FeatureCollection"
  end

  test "rejects a file that is not JSON" do
    path = tmp_geojson("not json at all")

    assert {:error, _reason} = GeoJSON.stage(manifest(), artifact(), path, fn _ -> :ok end, [])
  end

  test "rejects a document whose features is not a list" do
    path = tmp_geojson(~s({"type":"FeatureCollection","features":{"a":1}}))

    assert {:error, reason} = GeoJSON.stage(manifest(), artifact(), path, fn _ -> :ok end, [])
    assert reason =~ "features"
  end

  test "rejects a document containing a non-object feature" do
    path = tmp_geojson(~s({"type":"FeatureCollection","features":[null]}))

    assert {:error, reason} = GeoJSON.stage(manifest(), artifact(), path, fn _ -> :ok end, [])
    assert reason =~ "feature"
  end

  test "rejects a feature whose geometry is malformed" do
    document = %{
      "type" => "FeatureCollection",
      "features" => [
        %{"type" => "Feature", "properties" => %{}, "geometry" => %{"type" => "Bogus"}}
      ]
    }

    path = tmp_geojson(Jason.encode!(document))

    assert {:error, reason} = GeoJSON.stage(manifest(), artifact(), path, fn _ -> :ok end, [])
    assert reason =~ "geometry"
  end

  test "rejects a feature whose geometry is not an object" do
    document = %{
      "type" => "FeatureCollection",
      "features" => [%{"type" => "Feature", "properties" => %{}, "geometry" => "nonsense"}]
    }

    path = tmp_geojson(Jason.encode!(document))

    assert {:error, reason} = GeoJSON.stage(manifest(), artifact(), path, fn _ -> :ok end, [])
    assert reason =~ "geometry"
  end

  test "normalizes a staged row into an area" do
    row = %Staging.Row{
      artifact: "territories.geojson",
      payload: %{
        "territory_id" => "west",
        "territory_name" => "West Territory",
        "short_name" => "W",
        "population" => 1200
      },
      geom: %Geo.Polygon{coordinates: [[{0.0, 0.0}]], srid: 4326}
    }

    assert {:ok, area} = GeoJSON.normalize(manifest(), row)

    assert area.authority_key == "demo"
    assert area.area_type_key == "territory"
    assert area.code == "west"
    assert area.names == [%Name{name: "West Territory", kind: :official, locale: nil}]
    assert area.geometry == row.geom
  end

  test "the area type comes from the manifest option, not a constant" do
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => "x"}, geom: nil}

    assert {:ok, area} = GeoJSON.normalize(manifest(%{"area_type" => "zone"}), row)
    assert area.area_type_key == "zone"
  end

  test "the code property comes from the manifest option, not a constant" do
    row = %Staging.Row{artifact: "a", payload: %{"other_id" => "x"}, geom: nil}

    assert {:ok, area} = GeoJSON.normalize(manifest(%{"code_property" => "other_id"}), row)
    assert area.code == "x"
  end

  test "the authority comes from the manifest option when given" do
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => "x"}, geom: nil}

    assert {:ok, area} = GeoJSON.normalize(manifest(%{"authority" => "acme"}), row)
    assert area.authority_key == "acme"
  end

  test "the name property defaults to \"name\" when options gives no name_property" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"territory_id" => "x", "name" => "Default Name"},
      geom: nil
    }

    assert {:ok, area} = GeoJSON.normalize(bare_manifest(), row)
    assert %Name{name: "Default Name", kind: :official, locale: nil} in area.names
  end

  test "collects the named alias properties as alias names" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"territory_id" => "x", "territory_name" => "Ex", "short_name" => "X"},
      geom: nil
    }

    assert {:ok, area} = GeoJSON.normalize(manifest(%{"alias_properties" => ["short_name"]}), row)

    assert %Name{name: "X", kind: :alias, locale: nil} in area.names
    assert %Name{name: "Ex", kind: :official, locale: nil} in area.names
  end

  test "collects the named attribute properties" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"territory_id" => "x", "population" => 1200, "ignored" => "yes"},
      geom: nil
    }

    manifest = manifest(%{"attribute_properties" => ["population"]})

    assert {:ok, area} = GeoJSON.normalize(manifest, row)
    assert area.attributes == %{"population" => 1200}
  end

  test "attribute_properties defaults to no attributes when omitted" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{
        "territory_id" => "x",
        "territory_name" => "X",
        "short_name" => "S",
        "population" => 5
      },
      geom: nil
    }

    assert {:ok, area} = GeoJSON.normalize(manifest(), row)
    assert area.attributes == %{}
  end

  test "code_properties produce codes entries, keyed by their configured type" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"territory_id" => "west", "territory_name" => "West", "gnis_id" => "12345"},
      geom: nil
    }

    manifest = manifest(%{"code_properties" => [%{"type" => "gnis", "property" => "gnis_id"}]})

    assert {:ok, area} = GeoJSON.normalize(manifest, row)
    assert area.codes == [%Code{code_type: "gnis", code_value: "12345"}]
  end

  test "code_properties defaults to no codes when omitted" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"territory_id" => "west", "territory_name" => "West", "gnis_id" => "12345"},
      geom: nil
    }

    assert {:ok, area} = GeoJSON.normalize(manifest(), row)
    assert area.codes == []
  end

  test "skips a row with no value for the code property" do
    row = %Staging.Row{artifact: "a", payload: %{"territory_name" => "No Id"}, geom: nil}

    assert GeoJSON.normalize(manifest(), row) == :skip
  end

  test "skips a row whose code property value is an empty string" do
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => ""}, geom: nil}

    assert GeoJSON.normalize(manifest(), row) == :skip
  end

  test "trims a padded code property rather than carrying the padding into area_key" do
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => " 01001 "}, geom: nil}

    assert {:ok, area} = GeoJSON.normalize(manifest(), row)
    assert area.code == "01001"
  end

  test "skips a row whose code property value is only whitespace" do
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => "   "}, geom: nil}

    assert GeoJSON.normalize(manifest(), row) == :skip
  end

  test "trims a padded name property" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"territory_id" => "x", "territory_name" => " West Territory "},
      geom: nil
    }

    assert {:ok, area} = GeoJSON.normalize(manifest(), row)
    assert area.names == [%Name{name: "West Territory", kind: :official, locale: nil}]
  end

  test "a whitespace-only name property produces no official name" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"territory_id" => "x", "territory_name" => "   "},
      geom: nil
    }

    assert {:ok, area} = GeoJSON.normalize(manifest(), row)
    assert area.names == []
  end

  test "coerces a numeric code property value to a string" do
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => 7}, geom: nil}

    assert {:ok, area} = GeoJSON.normalize(manifest(), row)
    assert area.code == "7"
  end

  test "returns an error instead of raising when options is missing a required key" do
    manifest = %{manifest() | options: %{"area_type" => "territory"}}
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => "x"}, geom: nil}

    assert {:error, reason} = GeoJSON.normalize(manifest, row)
    assert reason =~ "code_property"
  end

  test "returns an error instead of raising when the manifest declares no authority" do
    manifest = %{manifest() | authorities: []}
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => "x"}, geom: nil}

    assert {:error, reason} = GeoJSON.normalize(manifest, row)
    assert reason =~ "authority"
  end

  test "returns an error instead of picking one when the manifest declares several" do
    authorities = [%{key: "demo", name: "Demo"}, %{key: "acme", name: "Acme"}]
    manifest = %{manifest() | authorities: authorities}
    row = %Staging.Row{artifact: "a", payload: %{"territory_id" => "x"}, geom: nil}

    assert {:error, reason} = GeoJSON.normalize(manifest, row)
    assert reason =~ "several authorities"
    assert reason =~ "demo, acme"
  end

  test "asks for relations to be rebuilt" do
    assert GeoJSON.relations(manifest()) == :rebuild
  end

  describe "normalize/2 with implied_areas" do
    test "returns the row's area followed by its implied areas" do
      manifest = manifest_with_implied_areas()

      row = %Staging.Row{
        artifact: "a",
        payload: %{"code" => "X", "name" => "Ex", "CLUSTER" => "1"},
        geom: nil
      }

      assert {:ok, [own, implied]} = GeoJSON.normalize(manifest, row)
      assert own.area_type_key == "place"
      assert own.code == "X"
      assert implied.area_type_key == "cluster"
      assert implied.code == "1"
    end

    test "returns a bare area when the manifest implies nothing" do
      manifest = manifest_without_implied_areas()
      row = %Staging.Row{artifact: "a", payload: %{"code" => "X", "name" => "Ex"}, geom: nil}

      assert {:ok, %Area{}} = GeoJSON.normalize(manifest, row)
    end

    test "skips the whole row when the row's own code is blank" do
      manifest = manifest_with_implied_areas()
      row = %Staging.Row{artifact: "a", payload: %{"code" => "", "CLUSTER" => "1"}, geom: nil}

      assert :skip = GeoJSON.normalize(manifest, row)
    end

    test "errors on a malformed implied_areas option even when the row's own code is blank" do
      manifest =
        manifest(%{
          "area_type" => "place",
          "code_property" => "code",
          "name_property" => "name",
          "implied_areas" => [
            %{"area_type" => "cluster", "code_property" => "CLUSTER", "relation" => "near"}
          ]
        })

      row = %Staging.Row{artifact: "a", payload: %{"code" => "", "CLUSTER" => "1"}, geom: nil}

      assert {:error, reason} = GeoJSON.normalize(manifest, row)
      assert reason =~ "relation must be one of"
    end

    test "surfaces an unnamed implied code as an error" do
      manifest = manifest_with_implied_areas()

      row = %Staging.Row{
        artifact: "a",
        payload: %{"code" => "X", "name" => "Ex", "CLUSTER" => "7"},
        geom: nil
      }

      assert {:error, reason} = GeoJSON.normalize(manifest, row)
      assert reason =~ "names"
    end
  end

  describe "asserted_relations/2" do
    test "asserts an edge from each implied area to the row's area" do
      manifest = manifest_with_implied_areas()

      row = %Staging.Row{
        artifact: "a",
        payload: %{"code" => "X", "name" => "Ex", "CLUSTER" => "1"},
        geom: nil
      }

      assert [{"demo:cluster:1", "demo:place:X", "contains"}] =
               GeoJSON.asserted_relations(manifest, row)
    end

    test "asserts nothing when the manifest implies nothing" do
      manifest = manifest_without_implied_areas()
      row = %Staging.Row{artifact: "a", payload: %{"code" => "X", "name" => "Ex"}, geom: nil}

      assert [] == GeoJSON.asserted_relations(manifest, row)
    end

    test "asserts nothing when the row's own code is blank" do
      manifest = manifest_with_implied_areas()
      row = %Staging.Row{artifact: "a", payload: %{"code" => "", "CLUSTER" => "1"}, geom: nil}

      assert [] == GeoJSON.asserted_relations(manifest, row)
    end
  end

  defp manifest_with_implied_areas do
    manifest(%{
      "area_type" => "place",
      "code_property" => "code",
      "name_property" => "name",
      "implied_areas" => [
        %{
          "area_type" => "cluster",
          "code_property" => "CLUSTER",
          "names" => %{"1" => "First"}
        }
      ]
    })
  end

  defp manifest_without_implied_areas do
    manifest(%{"area_type" => "place", "code_property" => "code", "name_property" => "name"})
  end
end
