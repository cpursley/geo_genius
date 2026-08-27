defmodule GeoGenius.Providers.SimpleMapsTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Manifest
  alias GeoGenius.Provider.Area
  alias GeoGenius.Providers.SimpleMaps
  alias GeoGenius.Staging

  @cities Path.expand("../../support/fixtures/simplemaps/uscities_sample.csv", __DIR__)
  @zips Path.expand("../../support/fixtures/simplemaps/uszips_sample.csv", __DIR__)

  defp manifest_fixture do
    %Manifest{
      collection: "simplemaps",
      release: "r1",
      provider: "simplemaps",
      authorities: [%{key: "simplemaps", name: "SimpleMaps"}],
      area_types: SimpleMaps.area_types(),
      sources: [],
      options: %{}
    }
  end

  defp artifact_fixture(logical_name) do
    %Manifest.Artifact{
      logical_name: logical_name,
      format: "csv",
      sha256: "x",
      bytes: 1
    }
  end

  defp collect(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn rows -> Agent.update(agent, &(&1 ++ rows)) end
    result = fun.(emit)
    {result, Agent.get(agent, & &1)}
  end

  test "declares the four area types in rank order" do
    assert SimpleMaps.area_types() == [
             %{key: "state", rank: 10},
             %{key: "county", rank: 20},
             %{key: "city", rank: 30},
             %{key: "zip", rank: 40}
           ]
  end

  test "requires no manifest options" do
    assert SimpleMaps.required_options() == []
  end

  test "stages one row per data line, carrying the artifact's logical name" do
    manifest = manifest_fixture()
    artifact = artifact_fixture("uscities")

    {result, rows} =
      collect(fn emit -> SimpleMaps.stage(manifest, artifact, @cities, emit, []) end)

    assert result == :ok
    assert length(rows) == 12
    assert Enum.all?(rows, &(&1.artifact == "uscities"))
    assert Enum.all?(rows, &is_nil(&1.geom))

    first = hd(rows)
    assert first.payload["city"] == "Los Angeles"
    assert first.payload["county_fips_all"] == "06037"

    # A column no callback reads yet -- proves the payload carries the
    # source's full 91-column shape rather than a hand-picked subset.
    assert map_size(first.payload) == 91

    # uscities names its counties column "county_name_all" (singular
    # "name"); uszips names the equivalent column "county_names_all"
    # (plural). Normalization reads this exact key.
    assert first.payload["county_name_all"] == "Los Angeles"
    refute Map.has_key?(first.payload, "county_names_all")
  end

  test "stages the uszips artifact under its own logical name" do
    manifest = manifest_fixture()
    artifact = artifact_fixture("uszips")

    {result, rows} = collect(fn emit -> SimpleMaps.stage(manifest, artifact, @zips, emit, []) end)

    assert result == :ok
    assert length(rows) == 14
    assert Enum.all?(rows, &(&1.artifact == "uszips"))
    assert Enum.all?(rows, &is_nil(&1.geom))

    multi_county = Enum.find(rows, &(&1.payload["zip"] == "01002"))

    # Pins that NimbleCSV's doubled-quote escaping is unwound, not merely
    # that the comma inside the quoted field survived. A payload still
    # carrying `""25015""` would satisfy a substring check on "25011" but
    # fail a later JSON decode of this column.
    assert multi_county.payload["county_weights"] == ~s({"25015": 93.26, "25011": 6.74})

    # uszips names its counties column "county_names_all" (plural
    # "names"); uscities names the equivalent column "county_name_all"
    # (singular).
    assert multi_county.payload["county_names_all"] == "Hampshire|Franklin"
    refute Map.has_key?(multi_county.payload, "county_name_all")
  end

  test "returns an error rather than raising for a path it cannot read" do
    manifest = manifest_fixture()
    artifact = artifact_fixture("uscities")

    missing_path =
      Path.join(
        System.tmp_dir!(),
        "gg_simplemaps_missing_#{System.unique_integer([:positive])}.csv"
      )

    {result, rows} =
      collect(fn emit -> SimpleMaps.stage(manifest, artifact, missing_path, emit, []) end)

    assert {:error, message} = result
    assert message =~ missing_path
    assert rows == []
  end

  test "a city row yields the city, its county, and its state" do
    areas = normalize_row!("uscities", city_payload("Los Angeles"))

    assert areas |> Enum.map(& &1.area_type_key) |> Enum.sort() == ["city", "county", "state"]

    city = area_of_type(areas, "city")
    assert city.authority_key == "simplemaps"
    assert city.code == "1840020491"
    assert city.centroid == %Geo.Point{coordinates: {-118.4068, 34.1141}, srid: 4326}
    assert %Area.Name{name: "Los Angeles", kind: :official} in city.names
    assert city.codes == []

    county = area_of_type(areas, "county")
    assert county.authority_key == "census"
    assert county.code == "06037"
    assert is_nil(county.centroid)
    assert %Area.Name{name: "Los Angeles", kind: :official} in county.names
    assert %Area.Code{code_type: "county_fips", code_value: "06037"} in county.codes

    state = area_of_type(areas, "state")
    assert state.authority_key == "census"
    assert state.code == "CA"
    assert is_nil(state.centroid)
    assert %Area.Name{name: "California", kind: :official} in state.names
    assert %Area.Code{code_type: "ansi_state", code_value: "CA"} in state.codes
  end

  test "a multi-county city yields one county per county_fips_all entry" do
    areas = normalize_row!("uscities", city_payload("Kansas City"))

    counties =
      areas |> Enum.filter(&(&1.area_type_key == "county")) |> Enum.map(& &1.code) |> Enum.sort()

    assert counties == ["29037", "29047", "29095", "29165"]
  end

  test "county names pair positionally with county_fips_all" do
    areas = normalize_row!("uscities", city_payload("Kansas City"))

    assert county_name(areas, "29095") == "Jackson"
    assert county_name(areas, "29047") == "Clay"
    assert county_name(areas, "29165") == "Platte"
    assert county_name(areas, "29037") == "Cass"
  end

  # Both real multi-county rows above name their counties in the same order
  # a sort of their fips codes would produce, because a county's fips is
  # assigned in alphabetical order within its state. Virginia's independent
  # cities break that: Alexandria sorts before Arlington by name and after it
  # by fips, so this row fails if the two lists are sorted before pairing.
  test "county names pair by position even where name order inverts fips order" do
    payload =
      "Kansas City"
      |> city_payload()
      |> Map.put("county_fips", "51510")
      |> Map.put("county_fips_all", "51510|51013")
      |> Map.put("county_name_all", "Alexandria|Arlington")

    areas = normalize_row!("uscities", payload)

    assert county_name(areas, "51510") == "Alexandria"
    assert county_name(areas, "51013") == "Arlington"
  end

  # `GeoGenius.Providers.SimpleMaps.Validation.check/1` runs ahead of this
  # module's own pairing, so a counties column shorter than county_fips_all
  # fails the row rather than reaching `counties/2` and yielding an area with
  # no name.
  test "a name list shorter than county_fips_all fails validation" do
    payload =
      "Kansas City"
      |> city_payload()
      |> Map.put("county_fips_all", "29095|29047|29165")
      |> Map.put("county_name_all", "Jackson|Clay")

    row = %Staging.Row{artifact: "uscities", payload: payload, geom: nil}

    assert {:error, message} = SimpleMaps.normalize(manifest_fixture(), row)
    assert message =~ "3 county FIPS"
    assert message =~ "2 county names"
  end

  # uszips spells the column "county_names_all"; reading the uscities
  # spelling here would leave every ZIP's counties nameless.
  test "a zip row reads its county names from the plural county_names_all column" do
    areas = normalize_row!("uszips", zip_payload("01002"))

    assert county_name(areas, "25015") == "Hampshire"
    assert county_name(areas, "25011") == "Franklin"
  end

  test "a county_fips_all repeating a fips yields that county once" do
    payload =
      "Kansas City"
      |> city_payload()
      |> Map.put("county_fips_all", "29095|29047|29095")
      |> Map.put("county_name_all", "Jackson|Clay|Jackson")

    areas = normalize_row!("uscities", payload)

    codes = areas |> Enum.filter(&(&1.area_type_key == "county")) |> Enum.map(& &1.code)
    assert codes == ["29095", "29047"]
  end

  test "city_ascii and city_alt become aliases, not second official names" do
    payload = "Cañon City" |> city_payload() |> Map.put("city_alt", "Canyon City")
    city = "uscities" |> normalize_row!(payload) |> area_of_type("city")

    assert Enum.count(city.names, &(&1.kind == :official)) == 1
    assert %Area.Name{name: "Cañon City", kind: :official} in city.names
    assert %Area.Name{name: "Canon City", kind: :alias} in city.names
    assert %Area.Name{name: "Canyon City", kind: :alias} in city.names
  end

  test "a city_ascii equal to the official name adds no alias" do
    areas = normalize_row!("uscities", city_payload("Los Angeles"))

    assert area_of_type(areas, "city").names == [
             %Area.Name{name: "Los Angeles", kind: :official}
           ]
  end

  test "a zip row yields the zip, its counties, and its state but no city" do
    areas = normalize_row!("uszips", zip_payload("90001"))

    assert "city" not in Enum.map(areas, & &1.area_type_key)

    zip = area_of_type(areas, "zip")
    assert zip.authority_key == "usps"
    assert zip.code == "90001"
    assert zip.centroid == %Geo.Point{coordinates: {-118.24904, 33.97365}, srid: 4326}
    assert %Area.Code{code_type: "usps_zip", code_value: "90001"} in zip.codes

    # A ZIP row's `city` column is the mailing name USPS prefers for that
    # ZIP, not a city this row describes.
    assert %Area.Name{name: "Los Angeles", kind: :mailing} in zip.names

    assert area_of_type(areas, "county").code == "06037"
    assert area_of_type(areas, "state").code == "CA"
  end

  test "state and county centroids stay nil rather than being invented" do
    areas = normalize_row!("uscities", city_payload("Los Angeles"))

    for area <- areas, area.area_type_key in ["state", "county"] do
      assert is_nil(area.centroid), "#{area.area_type_key} must not carry a synthetic centroid"
    end
  end

  test "a row whose coordinates are blank or will not parse carries no centroid" do
    for {column, value} <- [
          {"lng", ""},
          {"lat", ""},
          {"lat", "34.1abc"},
          {"lng", "-118 W"}
        ] do
      payload = "Los Angeles" |> city_payload() |> Map.put(column, value)
      city = "uscities" |> normalize_row!(payload) |> area_of_type("city")

      assert is_nil(city.centroid), "#{column}=#{inspect(value)} must not yield a centroid"
    end
  end

  test "the city carries the whole row; the county and state it implies carry none of it" do
    payload = city_payload("Los Angeles")
    areas = normalize_row!("uscities", payload)

    assert area_of_type(areas, "city").attributes == payload
    assert area_of_type(areas, "county").attributes == %{}
    assert area_of_type(areas, "state").attributes == %{}
  end

  test "the zip carries the whole row; the county and state it implies carry none of it" do
    payload = zip_payload("90001")
    areas = normalize_row!("uszips", payload)

    assert area_of_type(areas, "zip").attributes == payload
    assert area_of_type(areas, "county").attributes == %{}
    assert area_of_type(areas, "state").attributes == %{}
    assert is_nil(area_of_type(areas, "county").centroid)
    assert is_nil(area_of_type(areas, "state").centroid)
  end

  # `put_area_in_release/4` is last-write-wins for both attributes and
  # centroid, so a county carrying the row it was derived from would take
  # whichever of its cities or ZIPs happened to import last. Deriving the
  # same county from a city row and from a ZIP row and comparing the whole
  # struct is what pins that the two converge on identical content, not
  # merely on the same key.
  test "a county derived from a city row and from a zip row is the same area" do
    from_city =
      "uscities" |> normalize_row!(city_payload("Los Angeles")) |> area_of_type("county")

    from_zip = "uszips" |> normalize_row!(zip_payload("90001")) |> area_of_type("county")

    assert from_city.code == "06037"
    assert from_city == from_zip
  end

  test "a state derived from a city row and from a zip row is the same area" do
    from_city = "uscities" |> normalize_row!(city_payload("Los Angeles")) |> area_of_type("state")
    from_zip = "uszips" |> normalize_row!(zip_payload("90001")) |> area_of_type("state")

    assert from_city.code == "CA"
    assert from_city == from_zip
  end

  # Neither sample file carries a multi-county row the other also carries,
  # so the divergence most likely to matter -- the two files spell their
  # counties column differently, and their lists could disagree in order --
  # is built here rather than found. Comparing the whole county list, not a
  # set of codes, pins that the two spellings are read into identical areas
  # in identical order.
  test "a multi-county row converges on the same counties from either file" do
    overridden =
      "90001"
      |> zip_payload()
      |> Map.put("county_fips", "17031")
      |> Map.put("county_fips_all", "17031|17043")
      |> Map.put("county_names_all", "Cook|DuPage")
      |> Map.put("county_weights", ~s({"17031": 82.5, "17043": 17.5}))

    from_city = "uscities" |> normalize_row!(city_payload("Chicago")) |> counties_of()
    from_zip = "uszips" |> normalize_row!(overridden) |> counties_of()

    assert Enum.map(from_city, & &1.code) == ["17031", "17043"]
    assert from_city == from_zip
  end

  test "a single-county city asserts state->county and county->city, both contains" do
    edges = asserted_edges("uscities", city_payload("Los Angeles"))

    assert {"census:state:CA", "census:county:06037", "contains"} in edges
    assert {"census:county:06037", "simplemaps:city:1840020491", "contains"} in edges
    assert length(edges) == 2
  end

  test "a multi-county city asserts overlaps, never contains" do
    edges = asserted_edges("uscities", city_payload("Kansas City"))

    city_edges = Enum.filter(edges, fn {_parent, child, _type} -> child =~ "simplemaps:city:" end)

    assert length(city_edges) == 4
    assert Enum.all?(city_edges, fn {_parent, _child, type} -> type == "overlaps" end)
  end

  # A county's FIPS is assigned within its state, so no county spans two and
  # a state contains every county on the row however many there are.
  test "state-to-county stays contains however many counties the row names" do
    edges = asserted_edges("uscities", city_payload("Kansas City"))

    county_edges = Enum.filter(edges, fn {_parent, child, _type} -> child =~ "census:county:" end)

    assert length(county_edges) == 4

    assert Enum.all?(county_edges, fn {parent, _child, type} ->
             parent == "census:state:MO" and type == "contains"
           end)
  end

  # A ZIP crosses city lines, so a ZIP row's `city` column is the mailing
  # name USPS prefers for that ZIP rather than a containment the row can
  # assert in either direction.
  test "a zip asserts county->zip and state->county, never city->zip" do
    edges = asserted_edges("uszips", zip_payload("90001"))

    refute Enum.any?(edges, fn {parent, _child, _type} -> parent =~ "simplemaps:city:" end)
    refute Enum.any?(edges, fn {_parent, child, _type} -> child =~ "simplemaps:city:" end)

    assert Enum.any?(edges, fn {parent, child, _type} ->
             parent =~ "census:county:" and child =~ "usps:zip:"
           end)

    assert {"census:county:06037", "usps:zip:90001", "contains"} in edges
  end

  test "a multi-county zip asserts overlaps on every county it touches" do
    edges = asserted_edges("uszips", zip_payload("01002"))

    zip_edges = Enum.filter(edges, fn {_parent, child, _type} -> child =~ "usps:zip:" end)

    assert length(zip_edges) == 2
    assert Enum.all?(zip_edges, fn {_parent, _child, type} -> type == "overlaps" end)
  end

  # `GeoGenius.Catalog.put_relation/3` takes the parent first, and a swapped
  # pair writes successfully while silently inverting `children_of` and
  # `ancestors_of`. Every edge is checked against the declared ranks rather
  # than against pairs named here, so an inversion fails whichever pair it is
  # rather than only the ones an assertion happened to spell out.
  test "every asserted edge names the parent first" do
    edges =
      Enum.flat_map(
        [
          {"uscities", city_payload("Los Angeles")},
          {"uscities", city_payload("Kansas City")},
          {"uszips", zip_payload("90001")},
          {"uszips", zip_payload("01002")},
          {"uszips", zip_payload("09002")},
          {"uszips", zip_payload("96941")}
        ],
        fn {artifact, payload} -> asserted_edges(artifact, payload) end
      )

    refute edges == []

    for {parent, child, _type} <- edges do
      assert rank_of(parent) < rank_of(child),
             "#{parent} -> #{child} is inverted; put_relation takes the parent first"
    end
  end

  # A military APO ZIP sits in no US county, so it yields a ZIP and a state
  # with nothing between them and hangs off that state directly. For a ZIP
  # that is the whole truth the row carries: it is in AE and in no county.
  # The equivalent `uscities` row is a validation error instead -- not
  # because its edge would be missing, but because every city does sit in a
  # county, so a city row naming none is corruption. The fixture row is cut
  # from the real download, blank columns and all.
  test "a zip in no county hangs off its state directly" do
    areas = normalize_row!("uszips", zip_payload("09002"))

    assert areas |> Enum.map(& &1.area_type_key) |> Enum.sort() == ["state", "zip"]
    assert area_of_type(areas, "zip").code == "09002"

    # The state is the only parent such a ZIP has, and one edge to it is
    # truer than no parent at all.
    assert asserted_edges("uszips", zip_payload("09002")) == [
             {"usps:state:AE", "usps:zip:09002", "contains"}
           ]

    # The real row carries no coordinates and no `state_name` either, so the
    # ZIP gets no centroid and the state it implies gets no name at all.
    assert is_nil(area_of_type(areas, "zip").centroid)
  end

  # Where the row names counties they already connect the ZIP, so a
  # state-to-zip edge beside them would assert a second path to the same
  # place.
  test "a zip in a county has no direct state-to-zip edge" do
    for zip <- ["90001", "01002"] do
      edges = asserted_edges("uszips", zip_payload(zip))

      refute Enum.any?(edges, fn {parent, child, _type} ->
               parent =~ "state:" and child =~ "usps:zip:"
             end),
             "#{zip} must reach its state through its counties, not directly"
    end
  end

  # AE is a USPS construct for military mail, not a Census state, and the
  # Census assigns it no ANSI code. Keying it under `census` with an
  # `ansi_state` code would assert two things no source says.
  test "a military state keys under usps and carries no ansi code" do
    state = "uszips" |> normalize_row!(zip_payload("09002")) |> area_of_type("state")

    assert state.authority_key == "usps"
    assert state.code == "AE"
    assert %Area.Code{code_type: "usps_state", code_value: "AE"} in state.codes
    refute Enum.any?(state.codes, &(&1.code_type == "ansi_state"))

    # No row of either file supplies a `state_name` for AA, AE or AP, and no
    # name is invented for them: a label out of a table in this library would
    # be a fact the source does not carry.
    assert state.names == []
  end

  # FM is the Federated States of Micronesia, a sovereign country the USPS
  # serves rather than a state of any kind, so the Census defines it no more
  # than it defines AE. Unlike the military codes its rows do carry a
  # `state_name`, and it gets that name the way every other state does --
  # only the authority and the code type differ.
  test "a freely associated state keys under usps but keeps its name" do
    areas = normalize_row!("uszips", zip_payload("96941"))
    state = area_of_type(areas, "state")

    assert state.authority_key == "usps"
    assert state.code == "FM"
    assert %Area.Code{code_type: "usps_state", code_value: "FM"} in state.codes
    refute Enum.any?(state.codes, &(&1.code_type == "ansi_state"))

    assert %Area.Name{name: "Federated States of Micronesia", kind: :official} in state.names

    # A real row producing a cross-authority parent edge, rather than a
    # constructed one: this ZIP is in no county either.
    assert asserted_edges("uszips", zip_payload("96941")) == [
             {"usps:state:FM", "usps:zip:96941", "contains"}
           ]
  end

  test "an ordinary state still keys under census with its ansi code" do
    state = "uscities" |> normalize_row!(city_payload("Los Angeles")) |> area_of_type("state")

    assert state.authority_key == "census"
    assert state.code == "CA"
    assert %Area.Code{code_type: "ansi_state", code_value: "CA"} in state.codes
    refute Enum.any?(state.codes, &(&1.code_type == "usps_state"))
  end

  # The only edge whose parent authority is not the default for its type.
  # `edges/1` reads its keys off the `%Area{}` structs `areas/1` builds, so
  # the authority follows the key with nothing to keep in step -- this pins
  # that it does. The row is constructed rather than found: no AA, AE or AP
  # row of the real file names a county, so no real row produces this edge.
  test "a military state's edges name it under usps, not census" do
    payload =
      "09002"
      |> zip_payload()
      |> Map.put("county_fips", "06037")
      |> Map.put("county_fips_all", "06037")
      |> Map.put("county_names_all", "Los Angeles")
      |> Map.put("county_weights", ~s({"06037": 100}))

    edges = asserted_edges("uszips", payload)

    assert {"usps:state:AE", "census:county:06037", "contains"} in edges
    refute Enum.any?(edges, fn {parent, _child, _type} -> parent == "census:state:AE" end)
  end

  test "a row from an artifact this provider does not parse asserts no edges" do
    assert asserted_edges("uscounties", %{}) == []
  end

  test "a row from an artifact this provider does not parse is an error" do
    row = %Staging.Row{artifact: "uscounties", payload: %{}, geom: nil}

    assert {:error, message} = SimpleMaps.normalize(manifest_fixture(), row)
    assert message =~ "uscounties"
  end

  test "a blank id is an error rather than a city keyed on an empty code" do
    assert {:error, message} = blank_field_error("uscities", city_payload("Los Angeles"), "id")
    assert message =~ ~s("id")
  end

  test "a blank zip is an error rather than a zip keyed on an empty code" do
    assert {:error, message} = blank_field_error("uszips", zip_payload("90001"), "zip")
    assert message =~ ~s("zip")
  end

  test "a blank state_id is an error on either file" do
    assert {:error, cities_message} =
             blank_field_error("uscities", city_payload("Los Angeles"), "state_id")

    assert {:error, zips_message} = blank_field_error("uszips", zip_payload("90001"), "state_id")

    assert cities_message =~ ~s("state_id")
    assert zips_message =~ ~s("state_id")
  end

  # An import halts on the first row it cannot normalize, so the error has to
  # name the row as well as the column.
  test "a blank-column error names the row it halted on" do
    assert {:error, message} = blank_field_error("uscities", city_payload("Los Angeles"), "id")
    assert message =~ "city=Los Angeles"
    assert message =~ "state_id=CA"

    assert {:error, zip_message} = blank_field_error("uszips", zip_payload("90001"), "state_id")
    assert zip_message =~ "zip=90001"
  end

  # A required column goes blank when the download is corrupt or truncated,
  # which in a CSV usually means broken quoting, and a mis-quoted field can
  # swallow a whole line into one cell. The error is persisted on the import
  # run, so each value it names is capped rather than copied whole.
  test "a blank-column error caps each value it names" do
    swallowed = String.duplicate("a", 500)
    payload = "Los Angeles" |> city_payload() |> Map.put("city", swallowed)

    assert {:error, message} = blank_field_error("uscities", payload, "id")

    refute message =~ swallowed
    assert message =~ "city=" <> String.duplicate("a", 64) <> "..."
  end

  # The columns that describe a row are the same ones that can be blank, so a
  # row can carry none of them and the error still has to say something.
  test "a row carrying none of the columns that describe it says so" do
    payload =
      "Los Angeles"
      |> city_payload()
      |> Map.merge(%{"city" => "", "state_id" => ""})

    assert {:error, message} = blank_field_error("uscities", payload, "id")
    assert message =~ "no other column identifies it"
  end

  defp blank_field_error(artifact, payload, column) do
    SimpleMaps.normalize(manifest_fixture(), row(artifact, Map.put(payload, column, "")))
  end

  defp normalize_row!(artifact, payload) do
    {:ok, areas} = SimpleMaps.normalize(manifest_fixture(), row(artifact, payload))
    areas
  end

  defp asserted_edges(artifact, payload) do
    SimpleMaps.asserted_relations(manifest_fixture(), row(artifact, payload))
  end

  defp row(artifact, payload) do
    %Staging.Row{artifact: artifact, payload: payload, geom: nil}
  end

  # An area key is `<authority>:<area_type>:<code>`, so its middle segment
  # names the type whose declared rank orders the hierarchy.
  # Matching the find rather than reading its result keeps the guard total:
  # a nil rank would compare below every integer under Elixir term order, so
  # an edge naming a type no manifest declares would satisfy the direction
  # assertion vacuously instead of failing it.
  defp rank_of(area_key) do
    [_authority, area_type, _code] = String.split(area_key, ":", parts: 3)
    %{rank: rank} = Enum.find(SimpleMaps.area_types(), &(&1.key == area_type))
    rank
  end

  defp counties_of(areas), do: Enum.filter(areas, &(&1.area_type_key == "county"))

  defp area_of_type(areas, area_type_key) do
    Enum.find(areas, &(&1.area_type_key == area_type_key))
  end

  defp county_name(areas, code) do
    area = Enum.find(areas, &(&1.area_type_key == "county" and &1.code == code))

    Enum.find_value(area.names, &(&1.kind == :official && &1.name))
  end

  defp city_payload(city), do: staged_payload(@cities, "uscities", "city", city)
  defp zip_payload(zip), do: staged_payload(@zips, "uszips", "zip", zip)

  # Normalization payloads are staged out of the sample files rather than
  # written by hand, so a column name this provider gets wrong -- uscities
  # spells its counties column "county_name_all", uszips spells the same
  # column "county_names_all" -- fails here rather than only against the
  # real download.
  defp staged_payload(path, artifact, column, value) do
    {:ok, rows} =
      collect(fn emit ->
        SimpleMaps.stage(manifest_fixture(), artifact_fixture(artifact), path, emit, [])
      end)

    Enum.find(rows, &(&1.payload[column] == value)).payload
  end
end
