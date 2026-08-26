defmodule GeoGenius.CacheTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Cache

  test "builds a key from validated segments" do
    assert Cache.key(["demo", "demo:territories", "2026-01", "areas.geojson"]) ==
             "demo/demo:territories/2026-01/areas.geojson"
  end

  test "refuses a segment that could change the key's shape" do
    for bad <- [["demo", "a/b"], ["demo", ".."], ["demo", "."], ["demo", ""], ["demo", "a b"]] do
      assert_raise ArgumentError, fn -> Cache.key(bad) end
    end
  end

  test "refuses an empty segment list" do
    assert_raise ArgumentError, fn -> Cache.key([]) end
  end
end
