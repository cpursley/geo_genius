defmodule GeoGenius.PublicApiTest do
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv

  # Every read entry point, as {function, leading arguments, options it requires}.
  # Driven through one test so a new entry point is covered by adding a row.
  @read_entry_points [
    {:areas_for_point, [1.0, 2.0], []},
    {:areas_for_geometry, [%Geo.Point{coordinates: {0.0, 0.0}, srid: 4326}], []},
    {:areas_near, [1.0, 2.0, 100.0], []},
    {:areas_by_code, ["slug", "alpha"], []},
    {:search_areas, ["alpha"], []},
    {:resolve, [%{"name" => "Alpha"}], []},
    {:children_of, ["k"], []},
    {:ancestors_of, ["k"], []},
    {:related_areas, ["k"], []},
    {:release_at, [~U[2026-01-01 00:00:00Z]], [collection: "demo"]}
  ]

  defmodule RecordingStore do
    @moduledoc false
    @behaviour GeoGenius.Store

    @impl true
    def areas_for_point(context, lon, lat, opts) do
      send(self(), {:areas_for_point, context, [lon, lat, opts]})
      []
    end

    @impl true
    def areas_for_geometry(context, geometry, opts) do
      send(self(), {:areas_for_geometry, context, [geometry, opts]})
      []
    end

    @impl true
    def areas_near(context, lon, lat, radius_m, opts) do
      send(self(), {:areas_near, context, [lon, lat, radius_m, opts]})
      []
    end

    @impl true
    def areas_by_code(context, code_type, code_value, opts) do
      send(self(), {:areas_by_code, context, [code_type, code_value, opts]})
      []
    end

    @impl true
    def search_areas(context, query, opts) do
      send(self(), {:search_areas, context, [query, opts]})
      []
    end

    @impl true
    def resolve(context, input, opts) do
      send(self(), {:resolve, context, [input, opts]})
      []
    end

    @impl true
    def children_of(context, area_key, opts) do
      send(self(), {:children_of, context, [area_key, opts]})
      []
    end

    @impl true
    def ancestors_of(context, area_key, opts) do
      send(self(), {:ancestors_of, context, [area_key, opts]})
      []
    end

    @impl true
    def related_areas(context, area_key, opts) do
      send(self(), {:related_areas, context, [area_key, opts]})
      []
    end

    @impl true
    def release_at(context, as_of, opts) do
      send(self(), {:release_at, context, [as_of, opts]})
      nil
    end
  end

  setup do
    AppEnv.put(:store, RecordingStore)
    AppEnv.put(:repo, GeoGenius.TestRepo)
  end

  test "the read entry point matrix covers every Store callback" do
    covered = @read_entry_points |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    callbacks =
      GeoGenius.Store.behaviour_info(:callbacks) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert covered == callbacks,
           "@read_entry_points must hold one row per GeoGenius.Store callback"
  end

  test "every read entry point builds its context from the caller's options" do
    for {name, args, required_opts} <- @read_entry_points do
      arity = length(args) + 1
      opts = [prefix: "custom_geo", repo: GeoGenius.SandboxedRepo] ++ required_opts

      apply(GeoGenius, name, args ++ [opts])

      assert_received {^name, context, _},
                      "#{name}/#{arity} never reached the store"

      assert context.prefix == "custom_geo",
             "#{name}/#{arity} dropped :prefix on the way to Context.new/1"

      assert context.repo == GeoGenius.SandboxedRepo,
             "#{name}/#{arity} dropped :repo on the way to Context.new/1"
    end
  end

  test "delegates to the configured store with a built context" do
    assert [] = GeoGenius.areas_for_point(1.0, 2.0, probe: :sentinel)
    assert_received {:areas_for_point, context, [1.0, 2.0, [probe: :sentinel]]}
    assert context.repo == GeoGenius.TestRepo
    assert context.prefix == "geo_genius"
    assert context.store == RecordingStore
  end

  test "an explicit prefix overrides application environment" do
    assert [] = GeoGenius.search_areas("alpha", prefix: "custom_geo")
    assert_received {:search_areas, context, ["alpha", [prefix: "custom_geo"]]}
    assert context.prefix == "custom_geo"
  end

  test "areas_for_geometry passes the geometry and opts through" do
    geometry = %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326}
    assert [] = GeoGenius.areas_for_geometry(geometry, probe: :sentinel)
    assert_received {:areas_for_geometry, context, [^geometry, [probe: :sentinel]]}
    assert context.repo == GeoGenius.TestRepo
    assert context.store == RecordingStore
  end

  test "areas_near passes lon, lat, radius, and opts in order" do
    assert [] = GeoGenius.areas_near(1.0, 2.0, 100.0, limit: 5)
    assert_received {:areas_near, context, [1.0, 2.0, 100.0, [limit: 5]]}
    assert context.store == RecordingStore
  end

  test "areas_by_code passes code_type, code_value, and opts in order" do
    assert [] = GeoGenius.areas_by_code("slug", "alpha", probe: :sentinel)
    assert_received {:areas_by_code, context, ["slug", "alpha", [probe: :sentinel]]}
    assert context.store == RecordingStore
  end

  test "resolve passes the input map and opts through untouched" do
    input = %{"name" => "Alpha"}
    assert [] = GeoGenius.resolve(input, probe: :sentinel)
    assert_received {:resolve, context, [^input, [probe: :sentinel]]}
    assert context.store == RecordingStore
  end

  test "children_of passes the area key and opts through" do
    assert [] = GeoGenius.children_of("k", probe: :sentinel)
    assert_received {:children_of, context, ["k", [probe: :sentinel]]}
    assert context.store == RecordingStore
  end

  test "ancestors_of passes the area key and opts through" do
    assert [] = GeoGenius.ancestors_of("k", probe: :sentinel)
    assert_received {:ancestors_of, context, ["k", [probe: :sentinel]]}
    assert context.store == RecordingStore
  end

  test "related_areas passes the area key and opts through" do
    assert [] = GeoGenius.related_areas("k", probe: :sentinel)
    assert_received {:related_areas, context, ["k", [probe: :sentinel]]}
    assert context.store == RecordingStore
  end

  test "release_at passes as_of and the required :collection option" do
    as_of = DateTime.utc_now()
    assert is_nil(GeoGenius.release_at(as_of, collection: "demo"))
    assert_received {:release_at, context, [^as_of, [collection: "demo"]]}
    assert context.repo == GeoGenius.TestRepo
    assert context.store == RecordingStore
  end
end
