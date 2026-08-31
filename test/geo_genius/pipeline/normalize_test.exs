defmodule GeoGenius.Pipeline.NormalizeTest do
  use ExUnit.Case, async: false

  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportFixture
  alias GeoGenius.Pipeline.Normalize
  alias GeoGenius.Pipeline.State
  alias GeoGenius.Provider.Area
  alias GeoGenius.Provider.Area.Name
  alias GeoGenius.RecordingRepo
  alias GeoGenius.Staging
  alias GeoGenius.TestRepo

  @two_level_area_types [%{key: "city", rank: 30}, %{key: "state", rank: 10}]
  @three_level_area_types [
    %{key: "city", rank: 30},
    %{key: "state", rank: 10},
    %{key: "zip", rank: 40}
  ]

  defmodule MultiAreaProvider do
    @moduledoc false
    @behaviour GeoGenius.Provider

    @impl true
    def required_options, do: []
    @impl true
    defdelegate artifacts(manifest), to: GeoGenius.Provider, as: :all_artifacts
    @impl true
    def stage(_manifest, _artifact, _path, _emit, _opts), do: :ok
    @impl true
    defdelegate relations(manifest), to: GeoGenius.Provider, as: :always_rebuild

    @impl true
    defdelegate asserted_relations(manifest, row),
      to: GeoGenius.Provider,
      as: :no_asserted_relations

    @impl true
    def normalize(_manifest, %{payload: %{"city" => city, "state" => state}}) do
      {:ok,
       [
         %Area{
           authority_key: "demo_auth",
           area_type_key: "city",
           code: city,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: city, kind: :official}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "state",
           code: state,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: state, kind: :official}],
           codes: [],
           attributes: %{}
         }
       ]}
    end
  end

  defmodule SecondAreaBadKindProvider do
    @moduledoc false
    @behaviour GeoGenius.Provider

    @impl true
    def required_options, do: []
    @impl true
    defdelegate artifacts(manifest), to: GeoGenius.Provider, as: :all_artifacts
    @impl true
    def stage(_manifest, _artifact, _path, _emit, _opts), do: :ok
    @impl true
    defdelegate relations(manifest), to: GeoGenius.Provider, as: :always_rebuild

    @impl true
    defdelegate asserted_relations(manifest, row),
      to: GeoGenius.Provider,
      as: :no_asserted_relations

    # The row's second area carries a name kind outside `Name.kind/0`, so
    # `write_areas/4` must fail the whole row rather than land the first
    # area and silently drop the second.
    @impl true
    def normalize(_manifest, %{payload: %{"city" => city, "state" => state}}) do
      {:ok,
       [
         %Area{
           authority_key: "demo_auth",
           area_type_key: "city",
           code: city,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: city, kind: :official}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "state",
           code: state,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: state, kind: :bogus}],
           codes: [],
           attributes: %{}
         }
       ]}
    end
  end

  defmodule MiddleAreaBadKindProvider do
    @moduledoc false
    @behaviour GeoGenius.Provider

    @impl true
    def required_options, do: []
    @impl true
    defdelegate artifacts(manifest), to: GeoGenius.Provider, as: :all_artifacts
    @impl true
    def stage(_manifest, _artifact, _path, _emit, _opts), do: :ok
    @impl true
    defdelegate relations(manifest), to: GeoGenius.Provider, as: :always_rebuild

    @impl true
    defdelegate asserted_relations(manifest, row),
      to: GeoGenius.Provider,
      as: :no_asserted_relations

    # The rejected area sits between two writable ones, so a `write_areas/4`
    # that folded the whole list and returned the accumulated error would
    # still land the trailing area. Only halting leaves it unwritten.
    @impl true
    def normalize(_manifest, %{payload: %{"city" => city, "state" => state, "zip" => zip}}) do
      {:ok,
       [
         %Area{
           authority_key: "demo_auth",
           area_type_key: "city",
           code: city,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: city, kind: :official}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "state",
           code: state,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: state, kind: :bogus}],
           codes: [],
           attributes: %{}
         },
         %Area{
           authority_key: "demo_auth",
           area_type_key: "zip",
           code: zip,
           centroid: nil,
           geometry: nil,
           names: [%Name{name: zip, kind: :official}],
           codes: [],
           attributes: %{}
         }
       ]}
    end
  end

  defmodule MixedGeometryProvider do
    @moduledoc false
    @behaviour GeoGenius.Provider

    @impl true
    def required_options, do: []
    @impl true
    defdelegate artifacts(manifest), to: GeoGenius.Provider, as: :all_artifacts
    @impl true
    def stage(_manifest, _artifact, _path, _emit, _opts), do: :ok
    @impl true
    defdelegate relations(manifest), to: GeoGenius.Provider, as: :always_rebuild

    @impl true
    defdelegate asserted_relations(manifest, row),
      to: GeoGenius.Provider,
      as: :no_asserted_relations

    @impl true
    def normalize(_manifest, %{payload: %{"code" => code, "geometry" => geometry?}}) do
      geometry =
        if geometry? do
          offset = if code == "first", do: 0.0, else: 2.0

          %Geo.Polygon{
            coordinates: [
              [
                {offset, offset},
                {offset + 1.0, offset},
                {offset + 1.0, offset + 1.0},
                {offset, offset + 1.0},
                {offset, offset}
              ]
            ],
            srid: 4326
          }
        end

      {:ok,
       %Area{
         authority_key: "demo_auth",
         area_type_key: "city",
         code: code,
         centroid: nil,
         geometry: geometry,
         names: [%Name{name: code, kind: :official}],
         codes: [],
         attributes: %{}
       }}
    end
  end

  test "a row returning two areas writes both and counts both" do
    state =
      normalize_fixture(MultiAreaProvider, @two_level_area_types, [
        %{"city" => "LA", "state" => "CA"}
      ])

    assert {:ok, %State{metrics: metrics}} = Normalize.normalize(state)
    assert metrics["areas"] == 2
    assert metrics["skipped"] == 0

    keys = area_keys_in_release(state)
    assert "demo_auth:city:LA" in keys
    assert "demo_auth:state:CA" in keys
  end

  test "two rows implying the same state converge on one area" do
    rows = [%{"city" => "LA", "state" => "CA"}, %{"city" => "SF", "state" => "CA"}]
    state = normalize_fixture(MultiAreaProvider, @two_level_area_types, rows)

    assert {:ok, %State{metrics: metrics}} = Normalize.normalize(state)
    assert metrics["areas"] == 4

    keys = area_keys_in_release(state)
    assert Enum.count(keys, &(&1 == "demo_auth:state:CA")) == 1
  end

  test "a bad name kind on the second area fails the batch outright" do
    state =
      normalize_fixture(SecondAreaBadKindProvider, @two_level_area_types, [
        %{"city" => "LA", "state" => "CA"}
      ])

    assert {:error, reason} = Normalize.normalize(state)
    assert reason =~ "demo_auth:state:CA"
    assert reason =~ ":bogus"

    # A batch is collected before any of it is written, so the area the
    # provider described legally, ahead of the one it did not, is not written
    # either: the phase fails having written nothing.
    assert area_keys_in_release(state) == []
  end

  test "a bad name kind leaves no area of the batch written, before it or after" do
    payloads = [%{"city" => "LA", "state" => "CA", "zip" => "90001"}]
    state = normalize_fixture(MiddleAreaBadKindProvider, @three_level_area_types, payloads)

    assert {:error, reason} = Normalize.normalize(state)
    assert reason =~ "demo_auth:state:CA"

    keys = area_keys_in_release(state)
    refute "demo_auth:city:LA" in keys
    refute "demo_auth:state:CA" in keys
    refute "demo_auth:zip:90001" in keys
  end

  test "a batch costs one statement per kind of write, not one per area" do
    rows = Enum.map(1..40, &%{"city" => "city-#{&1}", "state" => "CA"})
    state = normalize_fixture(MultiAreaProvider, @two_level_area_types, rows)
    recording = %{state | context: %{state.context | repo: RecordingRepo}}

    assert {:ok, %State{metrics: metrics}} = Normalize.normalize(recording)
    assert metrics["areas"] == 80

    written =
      recorded_statements()
      |> Enum.filter(&String.contains?(&1, "geo_genius"))
      |> Enum.map(&statement_name/1)
      |> Enum.frequencies()

    # 40 rows describing 80 areas, in one batch: without the set writes this
    # would be 40 upserts, 40 name writes and 40 membership writes for the
    # cities alone, and as many again for the state each row repeats.
    assert written["upsert_area_many"] == 1
    assert written["put_area_name_many"] == 1
    assert written["put_area_in_release_many"] == 1
    refute Map.has_key?(written, "upsert_area")
    refute Map.has_key?(written, "put_area_name")
    refute Map.has_key?(written, "put_area_in_release")

    # No codes were described, so no statement was issued for them at all.
    refute Map.has_key?(written, "put_area_code_many")
  end

  test "a page writes its geometries in one aligned boundary call" do
    rows = [
      %{"code" => "first", "geometry" => true},
      %{"code" => "without", "geometry" => false},
      %{"code" => "third", "geometry" => true}
    ]

    state = normalize_fixture(MixedGeometryProvider, [%{key: "city", rank: 30}], rows)
    recording = %{state | context: %{state.context | repo: RecordingRepo}}

    assert {:ok, %State{metrics: metrics}} = Normalize.normalize(recording)
    assert metrics == %{"areas" => 3, "boundaries" => 2, "skipped" => 0}

    boundary_queries =
      recorded_queries()
      |> Enum.filter(fn {sql, _params} -> sql =~ ~s|"geo_genius".put_boundaries(| end)

    assert [{_sql, [_release_id, area_keys, source_ids, geometries, tiers, properties]}] =
             boundary_queries

    assert area_keys == ["demo_auth:city:first", "demo_auth:city:third"]
    assert length(source_ids) == 2
    assert length(geometries) == 2
    assert Enum.map(geometries, &hd(hd(&1.coordinates))) == [{0.0, 0.0}, {2.0, 2.0}]
    assert tiers == [0, 0]
    assert properties == [%{}, %{}]
  end

  # Registers a collection carrying `area_types` under a fixed authority key,
  # opens a release, stages `payloads` as rows, and returns the `%State{}` a
  # normalize test drives directly against
  # `GeoGenius.Pipeline.Normalize.normalize/1` -- the manifest a real run
  # would carry is never built, since nothing on this path reads it.
  defp normalize_fixture(provider, area_types, payloads) do
    context = Context.new(repo: TestRepo, prefix: "geo_genius")
    collection = "normalize_fixture_#{System.unique_integer([:positive])}"

    ExUnit.Callbacks.on_exit({__MODULE__, collection}, fn ->
      ImportFixture.teardown!(collection)
    end)

    Catalog.upsert_collection(context, %{key: collection, name: collection})
    Catalog.upsert_authority(context, collection, %{key: "demo_auth", name: "Demo Authority"})

    Enum.each(area_types, fn area_type ->
      Catalog.upsert_area_type(context, collection, area_type)
    end)

    release_id =
      Catalog.open_release(context, collection, %{
        release_key: "r1",
        manifest: %{"collection" => collection},
        source_date: ~D[2026-01-15]
      })

    Catalog.upsert_source(context, collection, %{
      source_key: "fixture:source",
      provider: "fixture",
      license: "test"
    })

    source_release_id =
      Catalog.upsert_source_release(context, collection, %{
        source_key: "fixture:source",
        release_key: "v1",
        source_date: nil,
        metadata: %{}
      })

    Catalog.attach_source_release(context, release_id, source_release_id)

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: "normalize-fixture",
        runner_backend: "test",
        stale_after_seconds: 300
      })

    on_exit({__MODULE__, {:staging, run_id}}, fn -> Staging.drop(context, run_id) end)

    Staging.create(context, run_id)
    rows = Enum.map(payloads, &%Staging.Row{artifact: "fixture", payload: &1, geom: nil})
    Staging.insert(context, run_id, rows)

    %State{
      context: context,
      run: Catalog.import_run(context, run_id),
      opts: [],
      work_dir: System.tmp_dir!(),
      publish?: false,
      batch_size: 500,
      timeout: 30_000,
      manifest: nil,
      providers: [provider],
      artifact_providers: %{"fixture" => provider},
      sources: %{"fixture" => source_release_id}
    }
  end

  defp area_keys_in_release(%State{context: context, run: run}) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT area.area_key
          FROM "#{context.prefix}".release_area
          JOIN "#{context.prefix}".area ON area.id = release_area.area_id
         WHERE release_area.release_id = $1
        """,
        [Ecto.UUID.dump!(run.release_id)]
      )

    Enum.map(rows, fn [area_key] -> area_key end)
  end

  # Every statement RecordingRepo saw, in the order it saw them. Normalize runs
  # in the calling process, so the records are already in this test's mailbox.
  defp recorded_statements do
    receive do
      {:query, sql, _params, _opts} -> [sql | recorded_statements()]
    after
      0 -> []
    end
  end

  defp recorded_queries do
    receive do
      {:query, sql, params, _opts} -> [{sql, params} | recorded_queries()]
    after
      0 -> []
    end
  end

  # The catalog function a statement calls, which is what the count above is
  # about: `SELECT "geo_genius".upsert_area_many($1, ...)` names
  # `upsert_area_many`.
  defp statement_name(sql) do
    case Regex.run(~r/"geo_genius"\.(\w+)\(/, sql) do
      [_match, function] -> function
      nil -> sql
    end
  end
end
