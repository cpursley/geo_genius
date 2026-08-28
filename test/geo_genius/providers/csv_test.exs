defmodule GeoGenius.Providers.CSVTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Manifest
  alias GeoGenius.Provider.Area.Code
  alias GeoGenius.Provider.Area.Name
  alias GeoGenius.Providers.CSV
  alias GeoGenius.Staging

  @fixture Path.expand("../../support/artifacts/places.csv", __DIR__)

  defp manifest(options \\ %{}) do
    %Manifest{
      collection: "demo",
      release: "r1",
      provider: "csv",
      authorities: [%{key: "demo", name: "Demo"}],
      area_types: [%{key: "place", rank: 100}],
      sources: [],
      options:
        Map.merge(
          %{
            "area_type" => "place",
            "code_column" => "place_id",
            "name_column" => "place_name"
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
      provider: "csv",
      authorities: [%{key: "demo", name: "Demo"}],
      area_types: [%{key: "place", rank: 100}],
      sources: [],
      options: Map.merge(%{"area_type" => "place", "code_column" => "place_id"}, options)
    }
  end

  defp artifact do
    %Manifest.Artifact{
      logical_name: "places.csv",
      format: "csv",
      operator_supplied: true,
      sha256: String.duplicate("0", 64),
      bytes: 1,
      required: true
    }
  end

  defp stage(manifest, path) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn rows -> Agent.update(agent, &(&1 ++ rows)) end
    result = CSV.stage(manifest, artifact(), path, emit, [])
    {result, Agent.get(agent, & &1)}
  end

  defp stage_all(manifest) do
    {:ok, rows} = stage(manifest, @fixture)
    rows
  end

  defp tmp_csv(content, extension \\ "csv") do
    path =
      Path.join(System.tmp_dir!(), "gg_csv_#{System.unique_integer([:positive])}.#{extension}")

    File.write!(path, content)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "declares the manifest option keys it requires" do
    assert "area_type" in CSV.required_options()
    assert "code_column" in CSV.required_options()
  end

  test "validate_options accepts implied_areas entries naming code_column" do
    options = %{
      "implied_areas" => [
        %{"area_type" => "cluster", "code_column" => "CLUSTER", "names" => %{"1" => "One"}}
      ]
    }

    assert CSV.validate_options(options) == :ok
  end

  # The option vocabulary is this provider's own, so an entry written for the
  # other generic provider is rejected here rather than accepted and failed on
  # every row.
  test "validate_options rejects an implied_areas entry naming code_property instead" do
    options = %{"implied_areas" => [%{"area_type" => "cluster", "code_property" => "CLUSTER"}]}

    assert {:error, reason} = CSV.validate_options(options)
    assert reason =~ ~s("code_column")
  end

  test "validate_options accepts options that declare no implied areas" do
    assert CSV.validate_options(%{"code_column" => "id"}) == :ok
  end

  test "artifacts returns every artifact across the manifest's sources" do
    source_a = %Manifest.Source{
      source_key: "a",
      provider: "csv",
      license: "CC0-1.0",
      release_key: "r1",
      artifacts: [
        %Manifest.Artifact{
          logical_name: "a.csv",
          format: "csv",
          operator_supplied: true,
          sha256: String.duplicate("0", 64),
          bytes: 1,
          required: true
        }
      ]
    }

    source_b = %Manifest.Source{
      source_key: "b",
      provider: "csv",
      license: "CC0-1.0",
      release_key: "r1",
      artifacts: [
        %Manifest.Artifact{
          logical_name: "b.csv",
          format: "csv",
          operator_supplied: true,
          sha256: String.duplicate("1", 64),
          bytes: 1,
          required: true
        }
      ]
    }

    manifest = %{manifest() | sources: [source_a, source_b]}

    assert Enum.map(CSV.artifacts(manifest), & &1.logical_name) == ["a.csv", "b.csv"]
  end

  test "stages one row per data line, not counting the header" do
    rows = stage_all(manifest())

    assert length(rows) == 3
    assert Enum.map(rows, & &1.artifact) == List.duplicate("places.csv", 3)
  end

  test "the staged payload is keyed by header name, quoted delimiter preserved" do
    [first | _] = stage_all(manifest())

    assert first.payload["place_name"] == "West, Territory"
  end

  test "every payload value stays a string, including a code that looks numeric" do
    [first | _] = stage_all(manifest())

    assert first.payload["zip"] == "30309"
  end

  test "builds a Geo.Point from configured lon_column and lat_column" do
    [first | _] = stage_all(manifest(%{"lon_column" => "lon", "lat_column" => "lat"}))

    assert first.geom == %Geo.Point{coordinates: {-84.4, 33.8}, srid: 4326}
  end

  test "leaves geom nil for a row whose coordinate cells are empty" do
    rows = stage_all(manifest(%{"lon_column" => "lon", "lat_column" => "lat"}))

    assert [_west, _east, %{geom: nil}] = rows
  end

  test "leaves every row's geom nil when lon_column and lat_column are not configured" do
    rows = stage_all(manifest())

    assert Enum.map(rows, & &1.geom) == [nil, nil, nil]
  end

  test "rejects a row whose configured coordinate cell is non-empty but not numeric" do
    path = tmp_csv("place_id,lon,lat\nwest,abc,33.8\n")

    assert {{:error, reason}, []} =
             stage(manifest(%{"lon_column" => "lon", "lat_column" => "lat"}), path)

    assert reason =~ "lon"
  end

  test "rejects a manifest that configures only lon_column" do
    assert {{:error, reason}, []} = stage(manifest(%{"lon_column" => "lon"}), @fixture)

    assert reason =~ "lon_column"
    assert reason =~ "lat_column"
  end

  test "rejects a manifest that configures only lat_column" do
    assert {{:error, reason}, []} = stage(manifest(%{"lat_column" => "lat"}), @fixture)

    assert reason =~ "lon_column"
    assert reason =~ "lat_column"
  end

  test "honours a configured delimiter other than the default comma" do
    path = tmp_csv("place_id\tplace_name\nsouth\tSouth Territory\n")

    assert {:ok, rows} = stage(manifest(%{"delimiter" => "\t"}), path)
    assert Enum.map(rows, & &1.payload["place_name"]) == ["South Territory"]
  end

  test "rejects a delimiter outside the fixed allowlist" do
    assert {{:error, reason}, []} = stage(manifest(%{"delimiter" => "~"}), @fixture)

    assert reason =~ "delimiter"
  end

  test "chunks a large artifact into multiple emit calls, first chunk short by the header row" do
    row_count = 2_500
    header = "place_id\n"
    body = Enum.map_join(1..row_count, "", &"p#{&1}\n")
    path = tmp_csv(header <> body)

    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn rows -> Agent.update(agent, &[length(rows) | &1]) end

    assert :ok = CSV.stage(manifest(), artifact(), path, emit, [])

    chunk_sizes = Agent.get(agent, & &1) |> Enum.reverse()

    assert chunk_sizes == [999, 1_000, 501]
  end

  test "returns an error instead of raising on a malformed CSV, such as an unclosed quote" do
    path = tmp_csv(~s(place_id,place_name\nwest,"West\n))

    assert {{:error, reason}, []} = stage(manifest(), path)
    assert reason =~ "escape"
  end

  test "normalizes a staged row into an area" do
    row = %Staging.Row{
      artifact: "places.csv",
      payload: %{
        "place_id" => "west",
        "place_name" => "West, Territory",
        "short_name" => "W",
        "population" => "1200"
      },
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(manifest(%{"attribute_columns" => ["population"]}), row)

    assert area.authority_key == "demo"
    assert area.area_type_key == "place"
    assert area.code == "west"
    assert area.names == [%Name{name: "West, Territory", kind: :official, locale: nil}]
    assert area.attributes == %{"population" => "1200"}
  end

  test "a staged row's geom becomes the area's centroid, never its geometry" do
    point = %Geo.Point{coordinates: {-84.4, 33.8}, srid: 4326}
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => "west"}, geom: point}

    assert {:ok, area} = CSV.normalize(manifest(), row)

    assert area.centroid == point
    assert area.geometry == nil
  end

  test "the area type comes from the manifest option, not a constant" do
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => "x"}, geom: nil}

    assert {:ok, area} = CSV.normalize(manifest(%{"area_type" => "zone"}), row)
    assert area.area_type_key == "zone"
  end

  test "the code column comes from the manifest option, not a constant" do
    row = %Staging.Row{artifact: "a", payload: %{"other_id" => "x"}, geom: nil}

    assert {:ok, area} = CSV.normalize(manifest(%{"code_column" => "other_id"}), row)
    assert area.code == "x"
  end

  test "the authority comes from the manifest option when given" do
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => "x"}, geom: nil}

    assert {:ok, area} = CSV.normalize(manifest(%{"authority" => "acme"}), row)
    assert area.authority_key == "acme"
  end

  test "returns an error instead of raising when the manifest declares no authority" do
    manifest = %{manifest() | authorities: []}
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => "x"}, geom: nil}

    assert {:error, reason} = CSV.normalize(manifest, row)
    assert reason =~ "authority"
  end

  test "returns an error instead of picking one when the manifest declares several" do
    authorities = [%{key: "demo", name: "Demo"}, %{key: "acme", name: "Acme"}]
    manifest = %{manifest() | authorities: authorities}
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => "x"}, geom: nil}

    assert {:error, reason} = CSV.normalize(manifest, row)
    assert reason =~ "several authorities"
    assert reason =~ "demo, acme"
  end

  test "the name column defaults to \"name\" when options gives no name_column" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "x", "name" => "Default Name"},
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(bare_manifest(), row)
    assert %Name{name: "Default Name", kind: :official, locale: nil} in area.names
  end

  test "a blank name cell produces no official name, not an empty-string one" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "x", "place_name" => ""},
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(manifest(), row)
    assert area.names == []
  end

  test "collects the named alias columns as alias names" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "x", "place_name" => "Ex", "short_name" => "X"},
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(manifest(%{"alias_columns" => ["short_name"]}), row)

    assert %Name{name: "X", kind: :alias, locale: nil} in area.names
    assert %Name{name: "Ex", kind: :official, locale: nil} in area.names
  end

  test "alias_columns defaults to no alias names when omitted" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "x", "place_name" => "Ex", "short_name" => "X"},
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(manifest(), row)
    assert area.names == [%Name{name: "Ex", kind: :official, locale: nil}]
  end

  test "attribute_columns defaults to no attributes when omitted" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "x", "place_name" => "Ex", "population" => "5"},
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(manifest(), row)
    assert area.attributes == %{}
  end

  test "code_columns produce codes entries, keyed by their configured type" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "west", "place_name" => "West", "zip" => "30309"},
      geom: nil
    }

    manifest = manifest(%{"code_columns" => [%{"type" => "postal", "column" => "zip"}]})

    assert {:ok, area} = CSV.normalize(manifest, row)
    assert area.codes == [%Code{code_type: "postal", code_value: "30309"}]
  end

  test "code_columns defaults to no codes when omitted" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "west", "place_name" => "West", "zip" => "30309"},
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(manifest(), row)
    assert area.codes == []
  end

  test "skips a row with no value for the code column" do
    row = %Staging.Row{artifact: "a", payload: %{"place_name" => "No Id"}, geom: nil}

    assert CSV.normalize(manifest(), row) == :skip
  end

  test "skips a row whose code column value is an empty string" do
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => ""}, geom: nil}

    assert CSV.normalize(manifest(), row) == :skip
  end

  test "trims a padded code cell rather than carrying the padding into area_key" do
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => " 01001 "}, geom: nil}

    assert {:ok, area} = CSV.normalize(manifest(), row)
    assert area.code == "01001"
  end

  test "skips a row whose code column value is only whitespace" do
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => "   "}, geom: nil}

    assert CSV.normalize(manifest(), row) == :skip
  end

  test "trims a padded name cell" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "x", "place_name" => " West "},
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(manifest(), row)
    assert area.names == [%Name{name: "West", kind: :official, locale: nil}]
  end

  test "a whitespace-only name cell produces no official name" do
    row = %Staging.Row{
      artifact: "a",
      payload: %{"place_id" => "x", "place_name" => "   "},
      geom: nil
    }

    assert {:ok, area} = CSV.normalize(manifest(), row)
    assert area.names == []
  end

  test "returns an error instead of raising when options is missing a required key" do
    manifest = %{manifest() | options: %{"area_type" => "place"}}
    row = %Staging.Row{artifact: "a", payload: %{"place_id" => "x"}, geom: nil}

    assert {:error, reason} = CSV.normalize(manifest, row)
    assert reason =~ "code_column"
  end

  test "asks for relations to be rebuilt" do
    assert CSV.relations(manifest()) == :rebuild
  end

  describe "normalize/2 with implied_areas" do
    test "returns the row's area followed by its implied areas" do
      manifest = manifest_with_implied_areas()

      row = %Staging.Row{
        artifact: "a",
        payload: %{"code" => "X", "name" => "Ex", "CLUSTER" => "1"},
        geom: nil
      }

      assert {:ok, [own, implied]} = CSV.normalize(manifest, row)
      assert own.code == "X"
      assert implied.area_type_key == "cluster"
      assert implied.code == "1"
    end

    test "implies areas with no geometry from a row with no geometry" do
      manifest = manifest_with_implied_areas()

      row = %Staging.Row{
        artifact: "a",
        payload: %{"code" => "X", "name" => "Ex", "CLUSTER" => "1"},
        geom: nil
      }

      assert {:ok, [own, implied]} = CSV.normalize(manifest, row)
      assert own.centroid == nil
      assert implied.centroid == nil
      assert implied.geometry == nil
    end

    test "reads the code column, not the code property" do
      manifest = %Manifest{
        collection: "demo",
        release: "r1",
        provider: "csv",
        authorities: [%{key: "auth", name: "Auth"}],
        sources: [],
        options: %{
          "area_type" => "place",
          "code_column" => "code",
          "name_column" => "name",
          "implied_areas" => [
            %{"area_type" => "cluster", "code_property" => "CLUSTER", "names" => %{"1" => "F"}}
          ]
        }
      }

      row = %Staging.Row{
        artifact: "a",
        payload: %{"code" => "X", "name" => "Ex", "CLUSTER" => "1"},
        geom: nil
      }

      assert {:error, reason} = CSV.normalize(manifest, row)
      assert reason =~ "code_column"
    end

    test "skips the whole row when the row's own code is blank" do
      manifest = manifest_with_implied_areas()
      row = %Staging.Row{artifact: "a", payload: %{"code" => "", "CLUSTER" => "1"}, geom: nil}

      assert :skip = CSV.normalize(manifest, row)
    end

    test "errors on a malformed implied_areas option even when the row's own code is blank" do
      manifest =
        manifest(%{
          "code_column" => "code",
          "name_column" => "name",
          "implied_areas" => [
            %{"area_type" => "cluster", "code_column" => "CLUSTER", "relation" => "near"}
          ]
        })

      row = %Staging.Row{artifact: "a", payload: %{"code" => "", "CLUSTER" => "1"}, geom: nil}

      assert {:error, reason} = CSV.normalize(manifest, row)
      assert reason =~ "relation must be one of"
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

      assert [{"auth:cluster:1", "auth:place:X", "contains"}] =
               CSV.asserted_relations(manifest, row)
    end

    test "asserts nothing when the manifest implies nothing" do
      manifest = manifest_without_implied_areas()
      row = %Staging.Row{artifact: "a", payload: %{"code" => "X", "name" => "Ex"}, geom: nil}

      assert [] == CSV.asserted_relations(manifest, row)
    end

    test "asserts nothing when the row's own code is blank" do
      manifest = manifest_with_implied_areas()
      row = %Staging.Row{artifact: "a", payload: %{"code" => "", "CLUSTER" => "1"}, geom: nil}

      assert [] == CSV.asserted_relations(manifest, row)
    end
  end

  defp manifest_without_implied_areas do
    %Manifest{
      collection: "demo",
      release: "r1",
      provider: "csv",
      authorities: [%{key: "auth", name: "Auth"}],
      sources: [],
      options: %{
        "area_type" => "place",
        "code_column" => "code",
        "name_column" => "name"
      }
    }
  end

  defp manifest_with_implied_areas do
    %Manifest{
      collection: "demo",
      release: "r1",
      provider: "csv",
      authorities: [%{key: "auth", name: "Auth"}],
      sources: [],
      options: %{
        "area_type" => "place",
        "code_column" => "code",
        "name_column" => "name",
        "implied_areas" => [
          %{"area_type" => "cluster", "code_column" => "CLUSTER", "names" => %{"1" => "First"}}
        ]
      }
    }
  end
end
