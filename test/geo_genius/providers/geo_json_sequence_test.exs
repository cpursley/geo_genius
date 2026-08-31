defmodule GeoGenius.Providers.GeoJSONSequenceTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Manifest
  alias GeoGenius.Providers.GeoJSONSequence

  defp manifest do
    %Manifest{
      collection: "demo",
      release: "r1",
      provider: "shapefile",
      authorities: [%{key: "demo", name: "Demo"}],
      area_types: [%{key: "territory", rank: 100}],
      sources: [],
      options: %{
        "area_type" => "territory",
        "code_property" => "territory_id",
        "name_property" => "territory_name"
      }
    }
  end

  defp artifact do
    %Manifest.Artifact{
      logical_name: "territories.geojsonl",
      format: "geojson",
      operator_supplied: true,
      sha256: String.duplicate("0", 64),
      bytes: 1,
      required: true
    }
  end

  defp feature(id) do
    Jason.encode!(%{
      "type" => "Feature",
      "properties" => %{"territory_id" => id, "territory_name" => String.upcase(id)},
      "geometry" => nil
    })
  end

  defp sequence_file(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "gg_geojson_seq_#{System.unique_integer([:positive])}.geojsonl"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "stages newline-delimited features in bounded batches without a final newline" do
    path = sequence_file("\n#{feature("first")}\n\n#{feature("second")}\n#{feature("third")}")

    emit = fn rows ->
      send(self(), {:emitted, rows})
      :ok
    end

    assert :ok = GeoJSONSequence.stage(manifest(), artifact(), path, emit, emit_batch_size: 2)

    assert_received {:emitted, [first, second]}
    assert_received {:emitted, [third]}

    assert [
             first.payload["territory_id"],
             second.payload["territory_id"],
             third.payload["territory_id"]
           ] ==
             ["first", "second", "third"]
  end

  test "stages RFC 8142 record-separator-delimited features" do
    path = sequence_file("\u001E#{feature("first")}\n\u001E#{feature("second")}\n")

    emit = fn rows ->
      send(self(), {:emitted, rows})
      :ok
    end

    assert :ok = GeoJSONSequence.stage(manifest(), artifact(), path, emit, [])
    assert_received {:emitted, [first, second]}
    assert Enum.map([first, second], & &1.payload["territory_id"]) == ["first", "second"]
  end

  test "reports malformed JSON with its one-based record number" do
    path = sequence_file("\n#{feature("first")}\nnot json\n")

    assert {:error, reason} =
             GeoJSONSequence.stage(manifest(), artifact(), path, fn _ -> :ok end, [])

    assert reason =~ "record 2"
    assert reason =~ "unexpected"
  end

  test "rejects a record that is not a GeoJSON Feature" do
    path = sequence_file(Jason.encode!(%{"type" => "FeatureCollection", "features" => []}))

    assert {:error, reason} =
             GeoJSONSequence.stage(manifest(), artifact(), path, fn _ -> :ok end, [])

    assert reason =~ "record 1"
    assert reason =~ "Feature"
  end

  test "emits 1,001 records without retaining more than the requested batch" do
    path =
      1..1_001
      |> Enum.map_join("\n", &feature("territory-#{&1}"))
      |> sequence_file()

    emit = fn rows ->
      send(self(), {:batch_size, length(rows)})
      :ok
    end

    assert :ok = GeoJSONSequence.stage(manifest(), artifact(), path, emit, emit_batch_size: 100)

    batch_sizes =
      for _ <- 1..11 do
        assert_receive {:batch_size, size}
        size
      end

    assert batch_sizes == List.duplicate(100, 10) ++ [1]
  end
end
