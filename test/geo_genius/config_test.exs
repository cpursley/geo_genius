defmodule GeoGenius.ConfigTest.AcmeProvider do
  @moduledoc false
end

defmodule GeoGenius.ConfigTest do
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Config
  alias GeoGenius.ConfigTest.AcmeProvider

  defp register!(providers), do: AppEnv.put(:providers, providers)

  test "accepts a valid prefix" do
    assert Config.validate_prefix!("geo_genius") == "geo_genius"
    assert Config.validate_prefix!("_custom9") == "_custom9"
  end

  test "rejects non-identifiers, non-strings, and over-long prefixes" do
    assert_raise ArgumentError, fn -> Config.validate_prefix!("Geo Genius") end
    assert_raise ArgumentError, fn -> Config.validate_prefix!(:geo_genius) end
    assert_raise ArgumentError, fn -> Config.validate_prefix!(String.duplicate("a", 64)) end
  end

  # Uninstalling drops the prefix schema, so a prefix naming a schema GeoGenius
  # does not own is a request to destroy someone else's objects.
  test "rejects schemas GeoGenius must not own" do
    for reserved <- ~w(public information_schema pg_catalog pg_toast pg_temp pg_anything) do
      assert_raise ArgumentError, fn -> Config.validate_prefix!(reserved) end
    end
  end

  test "resolves a registered provider name to its module" do
    register!(%{"acme" => AcmeProvider})

    assert Config.provider!("acme") == AcmeProvider
  end

  test "raises for an unknown provider name, naming the registered providers" do
    register!(%{"acme" => AcmeProvider})

    error = assert_raise ArgumentError, fn -> Config.provider!("nope") end

    assert error.message =~ "nope"
    assert error.message =~ "acme"
  end

  test "raises for a name with nothing registered, naming it among the known providers" do
    error = assert_raise ArgumentError, fn -> Config.provider!("unregistered") end

    assert error.message =~ "unregistered"
    assert error.message =~ "geojson"
  end

  test "resolves the shipped geojson provider with nothing registered" do
    assert Config.provider!("geojson") == GeoGenius.Providers.GeoJSON
    assert Config.providers()["geojson"] == GeoGenius.Providers.GeoJSON
  end

  test "resolves the shipped csv provider with nothing registered" do
    assert Config.provider!("csv") == GeoGenius.Providers.CSV
    assert Config.providers()["csv"] == GeoGenius.Providers.CSV
  end

  test "resolves the shipped shapefile provider with nothing registered" do
    assert Config.provider!("shapefile") == GeoGenius.Providers.Shapefile
    assert Config.providers()["shapefile"] == GeoGenius.Providers.Shapefile
  end

  test "resolves the shipped simplemaps provider with nothing registered" do
    assert Config.provider!("simplemaps") == GeoGenius.Providers.SimpleMaps
    assert Config.providers()["simplemaps"] == GeoGenius.Providers.SimpleMaps
  end

  # A name resolving to a module that does not load is a configuration error.
  # Answering with the atom leaves manifest validation reading "module absent"
  # as "provider requires no options", which accepts every options block
  # written for that provider.
  test "raises for a provider name whose module does not load, naming the module" do
    register!(%{"ghost" => GeoGenius.ConfigTest.NoSuchProvider})

    error = assert_raise ArgumentError, fn -> Config.provider!("ghost") end

    assert error.message =~ "ghost"
    assert error.message =~ "GeoGenius.ConfigTest.NoSuchProvider"
    assert error.message =~ "does not load"
  end

  test "manifest_paths appends the package's own manifest directory last" do
    paths = Config.manifest_paths(manifest_paths: ["/custom/manifests"])

    assert List.last(paths) == Application.app_dir(:geo_genius, "priv/geo_genius/manifests")
    assert "/custom/manifests" in paths

    assert Enum.find_index(paths, &(&1 == "/custom/manifests")) <
             Enum.find_index(
               paths,
               &(&1 == Application.app_dir(:geo_genius, "priv/geo_genius/manifests"))
             )
  end
end
