defmodule GeoGenius.Providers.ShapefileTest do
  use ExUnit.Case, async: true

  alias GeoGenius.Manifest
  alias GeoGenius.Manifest.Source
  alias GeoGenius.Provider
  alias GeoGenius.Providers.GeoJSON
  alias GeoGenius.Providers.Shapefile
  alias GeoGenius.Staging

  @geojson Path.expand("../../support/artifacts/territories.geojson", __DIR__)

  defmodule StubCommand do
    @moduledoc false
    @behaviour GeoGenius.Command

    @impl GeoGenius.Command
    def available?(_executable, _opts), do: true

    @impl GeoGenius.Command
    def run(executable, args, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:ran, executable, args})
      File.cp!(Keyword.fetch!(opts, :fixture), output_path(args))
      {:ok, ""}
    end

    defp output_path(args) do
      # ogr2ogr -f GeoJSON -t_srs EPSG:4326 <out> <in>
      Enum.at(args, -2)
    end
  end

  defmodule MissingCommand do
    @moduledoc false
    @behaviour GeoGenius.Command

    @impl GeoGenius.Command
    def available?(_executable, _opts), do: false

    @impl GeoGenius.Command
    def run(_executable, _args, _opts), do: {:error, {127, "not found"}}
  end

  defp archive(members) do
    dir = Path.join(System.tmp_dir!(), "gg_shp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    entries =
      Enum.map(members, fn name -> {String.to_charlist(name), "stand-in for #{name}"} end)

    zip_path = Path.join(dir, "shapes.zip")
    {:ok, _} = :zip.create(String.to_charlist(zip_path), entries)
    zip_path
  end

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
      logical_name: "shapes.zip",
      format: "shapefile",
      operator_supplied: true,
      sha256: String.duplicate("0", 64),
      bytes: 1,
      required: true
    }
  end

  defp opts(extra \\ []) do
    work_dir = Path.join(System.tmp_dir!(), "gg_shp_work_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(work_dir) end)

    Keyword.merge(
      [command: StubCommand, work_dir: work_dir, test_pid: self(), fixture: @geojson],
      extra
    )
  end

  test "declares the same manifest options the GeoJSON provider reads" do
    assert Shapefile.required_options() == GeoJSON.required_options()
  end

  test "area_types delegates to the GeoJSON provider" do
    assert Shapefile.area_types() == GeoJSON.area_types()
    assert Shapefile.area_types() == []
  end

  test "artifacts returns every artifact declared across the manifest's sources" do
    declared_artifact = artifact()

    source = %Source{
      source_key: "shapes",
      provider: "shapefile",
      license: "public-domain",
      release_key: "r1",
      artifacts: [declared_artifact]
    }

    manifest_with_source = %{manifest() | sources: [source]}

    # A stub that ignored the manifest's sources and returned [] would still
    # pass every other test in this file, since none of them call
    # artifacts/1. Asserting a real artifact comes back -- and matches what
    # GeoJSON.artifacts/1 (the module this delegates to) returns for the
    # same manifest -- catches that.
    assert Shapefile.artifacts(manifest_with_source) == [declared_artifact]
    assert Shapefile.artifacts(manifest_with_source) == GeoJSON.artifacts(manifest_with_source)
  end

  test "unzips, converts, and stages every feature" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn rows -> Agent.update(agent, &(&1 ++ rows)) end

    zip = archive(["territories.shp", "territories.dbf", "territories.shx", "territories.prj"])

    assert :ok = Shapefile.stage(manifest(), artifact(), zip, emit, opts())
    assert length(Agent.get(agent, & &1)) == 3
  end

  test "invokes ogr2ogr with the SRS flag and value in the exact expected pairing" do
    zip = archive(["territories.shp", "territories.dbf"])
    stage_opts = opts()
    work_dir = Keyword.fetch!(stage_opts, :work_dir)

    assert :ok = Shapefile.stage(manifest(), artifact(), zip, fn _ -> :ok end, stage_opts)

    assert_receive {:ran, "ogr2ogr", args}

    # A fixed-length destructure fails outright if an implementation slips
    # in an extra flag (an added "-s_srs EPSG:4326" declaring a projected
    # source as lat/long, for instance) -- that mutation produces an 8-element
    # list, not 6, and this match raises before the equality assertion below
    # ever runs.
    [_flag_f, _fmt, _flag_srs, _srs_value, out_path, shp_path] = args

    assert args == ["-f", "GeoJSON", "-t_srs", "EPSG:4326", out_path, shp_path],
           "a transposed flag/value pair, or an extra CRS flag, would silently mislocate geometry"

    assert Path.basename(shp_path) == "territories.shp"
    assert Path.basename(out_path) == "converted.json"
    assert Path.dirname(out_path) == Path.dirname(shp_path)
    assert String.starts_with?(shp_path, work_dir)
  end

  test "an archive with no shapefile member is an error naming the archive" do
    zip = archive(["readme.txt", "data.dbf"])

    assert {:error, reason} =
             Shapefile.stage(manifest(), artifact(), zip, fn _ -> :ok end, opts())

    assert reason =~ "no .shp"
    assert reason =~ "shapes.zip"
  end

  test "an archive with two shapefile members is an error naming both" do
    zip = archive(["a.shp", "b.shp"])

    assert {:error, reason} =
             Shapefile.stage(manifest(), artifact(), zip, fn _ -> :ok end, opts())

    assert reason =~ "a.shp"
    assert reason =~ "b.shp"
  end

  test "reports a missing converter by name rather than raising" do
    zip = archive(["territories.shp"])

    assert {:error, reason} =
             Shapefile.stage(
               manifest(),
               artifact(),
               zip,
               fn _ -> :ok end,
               opts(command: MissingCommand)
             )

    assert reason =~ "ogr2ogr"
    assert reason =~ "GDAL"
  end

  test "does not silently pick a shapefile member when the archive has none available at all" do
    # An implementation that returns the first member it finds regardless of
    # extension, rather than filtering for ".shp", would still "succeed" on
    # an archive that carries only a ".dbf" -- and then hand ogr2ogr a file
    # it cannot read as a shapefile. Asserting the specific "no .shp" wording
    # (checked above) already catches that; this asserts the failure happens
    # before any command runs at all, so a broken member filter cannot be
    # masked by StubCommand always succeeding regardless of its input file.
    zip = archive(["data.dbf"])

    assert {:error, _reason} =
             Shapefile.stage(manifest(), artifact(), zip, fn _ -> :ok end, opts())

    refute_receive {:ran, _executable, _args}
  end

  test "an archive that cannot be unzipped is reported by path" do
    dir = Path.join(System.tmp_dir!(), "gg_shp_corrupt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    corrupt_path = Path.join(dir, "shapes.zip")
    File.write!(corrupt_path, "this is not a zip archive")

    assert {:error, reason} =
             Shapefile.stage(manifest(), artifact(), corrupt_path, fn _ -> :ok end, opts())

    assert reason =~ "could not unzip"
    assert reason =~ corrupt_path
  end

  test "normalize delegates to the GeoJSON provider" do
    row = %Staging.Row{
      artifact: "shapes.zip",
      payload: %{"territory_id" => "west", "territory_name" => "West"},
      geom: nil
    }

    assert {:ok, %Provider.Area{} = area} = Shapefile.normalize(manifest(), row)
    assert area.code == "west"
    assert area == elem(GeoJSON.normalize(manifest(), row), 1)
  end

  test "asks for relations to be rebuilt, matching the GeoJSON provider" do
    assert Shapefile.relations(manifest()) == :rebuild
    assert Shapefile.relations(manifest()) == GeoJSON.relations(manifest())
  end

  test "leaves the pipeline-supplied work_dir and its other contents alone on success" do
    zip = archive(["territories.shp"])
    stage_opts = opts()
    work_dir = Keyword.fetch!(stage_opts, :work_dir)

    File.mkdir_p!(work_dir)
    sibling = Path.join(work_dir, "sibling-artifact.bin")
    File.write!(sibling, "another artifact's downloaded bytes")

    assert :ok = Shapefile.stage(manifest(), artifact(), zip, fn _ -> :ok end, stage_opts)

    assert File.exists?(work_dir)
    assert File.read!(sibling) == "another artifact's downloaded bytes"
    # Only the sibling remains: this call's own extraction subdirectory was
    # removed, but work_dir itself, and what else was already in it, was not.
    assert File.ls!(work_dir) == ["sibling-artifact.bin"]
  end

  test "leaves the pipeline-supplied work_dir and its other contents alone on failure" do
    zip = archive(["readme.txt"])
    stage_opts = opts()
    work_dir = Keyword.fetch!(stage_opts, :work_dir)

    File.mkdir_p!(work_dir)
    sibling = Path.join(work_dir, "sibling-artifact.bin")
    File.write!(sibling, "another artifact's downloaded bytes")

    assert {:error, _reason} =
             Shapefile.stage(manifest(), artifact(), zip, fn _ -> :ok end, stage_opts)

    assert File.exists?(work_dir)
    assert File.read!(sibling) == "another artifact's downloaded bytes"
    assert File.ls!(work_dir) == ["sibling-artifact.bin"]
  end
end
