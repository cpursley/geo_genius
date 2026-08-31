defmodule GeoGenius.Providers.GeoJSONGeometryTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Providers.GeoJSONGeometry

  test "decodes a GeoJSON geometry, accepts null, and names an invalid value" do
    assert {:ok, nil} = GeoJSONGeometry.decode(nil)

    assert {:ok, %Geo.Point{coordinates: {-73.99, 40.75}, srid: 4326}} =
             GeoJSONGeometry.decode(%{"type" => "Point", "coordinates" => [-73.99, 40.75]})

    assert {:error, reason} = GeoJSONGeometry.decode("not a geometry")
    assert reason =~ "geometry"
  end
end
