defmodule GeoGenius.FilesTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Files

  @fixture Path.expand("../support/artifacts/territories.geojson", __DIR__)

  test "reads an existing file's contents" do
    assert {:ok, content} = Files.read(@fixture)
    assert content =~ "FeatureCollection"
  end

  test "returns the raw posix reason, not a formatted string, for a missing file" do
    path =
      Path.join(System.tmp_dir!(), "gg_missing_#{System.unique_integer([:positive])}.geojson")

    assert {:error, :enoent} = Files.read(path)
  end

  test "format_error names the path and describes the reason" do
    path = "/no/such/directory/file.geojson"

    message = Files.format_error(path, :enoent)

    assert message =~ path
    assert message =~ "no such file"
  end
end
