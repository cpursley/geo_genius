defmodule GeoGenius.StoreTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Store

  test "resolves a known backend name" do
    assert {:ok, GeoGenius.Stores.Postgres} = Store.module_for_backend("postgres")
  end

  test "an unknown backend is an error, not a raise" do
    assert {:error, :unknown_backend} = Store.module_for_backend("redis")
  end

  test "configured defaults to the Postgres store" do
    assert Store.configured([]) == GeoGenius.Stores.Postgres
  end

  test "configured honours an explicit override" do
    assert Store.configured(store: __MODULE__) == __MODULE__
  end

  # A fixture store proves the behaviour is satisfiable and that the registry
  # accepts a module the library did not write. The shipped store gets its own
  # reflective contract test in Task 9, once it exists.
  defmodule FixtureStore do
    @moduledoc false
    @behaviour GeoGenius.Store

    @impl true
    def areas_for_point(_context, _lon, _lat, _opts), do: []
    @impl true
    def areas_for_geometry(_context, _geom, _opts), do: []
    @impl true
    def areas_near(_context, _lon, _lat, _radius_m, _opts), do: []
    @impl true
    def areas_by_code(_context, _code_type, _code_value, _opts), do: []
    @impl true
    def search_areas(_context, _query, _opts), do: []
    @impl true
    def resolve(_context, _input, _opts), do: []
    @impl true
    def children_of(_context, _area_key, _opts), do: []
    @impl true
    def ancestors_of(_context, _area_key, _opts), do: []
    @impl true
    def related_areas(_context, _area_key, _opts), do: []
    @impl true
    def children_of_many(_context, _area_keys, _opts), do: []
    @impl true
    def ancestors_of_many(_context, _area_keys, _opts), do: []
    @impl true
    def related_areas_many(_context, _area_keys, _opts), do: []
    @impl true
    def areas_by_code_many(_context, _code_type, _code_values, _opts), do: []
    @impl true
    def release_at(_context, _as_of, _opts), do: nil
  end

  test "a module outside the library can satisfy the behaviour" do
    for {function, arity} <- Store.behaviour_info(:callbacks) do
      assert function_exported?(FixtureStore, function, arity),
             "FixtureStore is missing #{function}/#{arity}"
    end
  end

  test "the shipped store implements every callback" do
    # function_exported?/3 reports false for a module the running process has
    # not loaded yet, regardless of what the module defines. Nothing else in
    # this file forces GeoGenius.Stores.Postgres to load, so this test would
    # be order-dependent on whatever else the async run happened to load
    # first without loading it explicitly.
    Code.ensure_loaded!(GeoGenius.Stores.Postgres)

    for {function, arity} <- Store.behaviour_info(:callbacks) do
      assert function_exported?(GeoGenius.Stores.Postgres, function, arity),
             "GeoGenius.Stores.Postgres is missing #{function}/#{arity}"
    end
  end
end
