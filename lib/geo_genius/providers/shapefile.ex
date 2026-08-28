defmodule GeoGenius.Providers.Shapefile do
  @moduledoc """
  Provider for a shapefile archive.

  A shapefile is several sibling files (`.shp`, `.dbf`, `.shx`, and usually
  `.prj`) that must travel together, so the artifact this provider stages is
  a zip archive rather than a single file. `stage/5`:

    1. Unzips the archive into a private subdirectory of `opts[:work_dir]`
       with `:zip.unzip/2` from OTP -- no dependency, since the archive
       format is fixed.
    2. Finds exactly one `.shp` member. Zero is an error naming the archive;
       more than one is an error naming both, because picking one silently
       would publish half a dataset.
    3. Converts it with the configured `GeoGenius.Command` adapter:
       `ogr2ogr -f GeoJSON -t_srs EPSG:4326 <out.json> <in.shp>`. The
       `-t_srs` flag is not optional: a shapefile in a projected coordinate
       system would otherwise stage coordinates in metres that PostGIS
       accepts as degrees -- geometry that is silently, plausibly wrong
       rather than obviously broken.
    4. Delegates the parse of the converted document to
       `GeoGenius.Providers.GeoJSON.stage/5`.

  `normalize/2`, `required_options/0`, `area_types/0`, `artifacts/1`,
  `relations/1`, and `asserted_relations/2` all delegate to
  `GeoGenius.Providers.GeoJSON` unchanged: a converted shapefile is a GeoJSON
  `FeatureCollection` by the time anything downstream of `ogr2ogr` sees it,
  so the manifest options a release names are the same ones
  `GeoGenius.Providers.GeoJSON` reads.

  This is the only shipped provider that needs GDAL installed -- a host
  publishing GeoJSON or CSV collections never installs it. `available?/2` on
  the configured `GeoGenius.Command` is checked before `ogr2ogr` runs, so a
  host missing GDAL gets a named error rather than a raised exception or a
  bare non-zero exit.

  This module ships in place of the module name `Providers.Census` used
  elsewhere: what a Census-specific provider would actually contain is this
  format reader plus a vendor's file-naming and code conventions, and the
  second half is vendor knowledge a host-neutral catalog library has no
  business carrying. Shipping the format half means a Census release is an
  ordinary manifest naming `"shapefile"` with Census column names in its
  `options`, and a release from any other authority that ships shapefiles is
  another one.

  **Working directory.** `opts[:work_dir]` is resolved once per pipeline run
  and may be shared across every artifact in a manifest -- a downloaded
  archive can already be sitting in it, and another shapefile artifact in
  the same release may extract into it around the same time. This provider
  never removes `work_dir` itself: it creates its own uniquely-named
  subdirectory under it (`System.unique_integer/1`-suffixed, the shape used
  elsewhere in this codebase) to unzip and convert into, and removes only
  that subdirectory when the call returns. `stage/5` is eager -- `emit` has
  already run by the time this function returns -- so nothing outside the
  call needs the extracted or converted files afterward, and cleanup runs on
  both the success and error paths. Cleanup does not run if the process is
  killed by an exit signal rather than returning or raising; the default
  `work_dir` lives under `System.tmp_dir!/0`, so the OS reaps it regardless.

  **Member matching is case-sensitive and unfiltered by path.**
  `TERRITORIES.SHP` in an archive is read as "no `.shp` member", and an
  archive zipped by macOS that carries `__MACOSX/._territories.shp`
  alongside the real member is read as "more than one `.shp` member". Both
  fail loudly with a named error rather than silently choosing wrong, so
  this is a limit to know about, not a defect to route around silently.

  **Known limit.** `-f GeoJSON` produces one document that
  `GeoGenius.Providers.GeoJSON.stage/5` reads whole, so peak memory during a
  shapefile release scales with the size of the converted dataset. The
  streaming alternative is `ogr2ogr -f GeoJSONSeq`, which emits one feature
  per line, paired with a line-oriented reader instead of
  `GeoGenius.Providers.GeoJSON.stage/5`. That reader is not built here
  because no shipped manifest needs it yet.
  """

  @behaviour GeoGenius.Provider

  alias GeoGenius.Manifest
  alias GeoGenius.Provider
  alias GeoGenius.Provider.Area
  alias GeoGenius.Providers.GeoJSON
  alias GeoGenius.Staging

  @converted_filename "converted.json"

  @impl Provider
  @doc "Delegates to `GeoGenius.Providers.GeoJSON.area_types/0`: a converted shapefile carries no fixed hierarchy of its own."
  @spec area_types() :: [Manifest.area_type()]
  defdelegate area_types(), to: GeoJSON

  @impl Provider
  @doc "Delegates to `GeoGenius.Providers.GeoJSON.required_options/0`: the manifest options a shapefile release names are read from the converted GeoJSON document."
  @spec required_options() :: [String.t()]
  defdelegate required_options(), to: GeoJSON

  @impl Provider
  @doc "Delegates to `GeoGenius.Providers.GeoJSON.artifacts/1`: every artifact declared across the manifest's sources, all of them shapefile archives."
  @spec artifacts(Manifest.t()) :: [Manifest.Artifact.t()]
  defdelegate artifacts(manifest), to: GeoJSON

  @impl Provider
  @doc """
  Unzips `path` into a private subdirectory of `opts[:work_dir]`, converts
  its single `.shp` member to GeoJSON with `ogr2ogr`, and delegates the
  parse to `GeoGenius.Providers.GeoJSON.stage/5`.

  The subdirectory this call creates is removed once the call returns,
  whether it succeeds or fails; `opts[:work_dir]` itself, and anything else
  already in it, is left untouched.
  """
  @spec stage(
          Manifest.t(),
          Manifest.Artifact.t(),
          Path.t(),
          ([Staging.Row.t()] -> :ok),
          Provider.stage_opts()
        ) :: :ok | {:error, Provider.reason()}
  def stage(%Manifest{} = manifest, %Manifest.Artifact{} = artifact, path, emit, opts) do
    command = Keyword.get(opts, :command, GeoGenius.Commands.System)
    work_dir = Keyword.get_lazy(opts, :work_dir, &default_work_dir/0)
    extract_dir = Path.join(work_dir, "shp_#{System.unique_integer([:positive])}")

    try do
      stage_from_archive(manifest, artifact, path, emit, opts, command, extract_dir)
    after
      File.rm_rf(extract_dir)
    end
  end

  @impl Provider
  @doc "Delegates to `GeoGenius.Providers.GeoJSON.normalize/2`: a converted shapefile's staged rows carry the same shape as a GeoJSON feature's."
  @spec normalize(Manifest.t(), Staging.Row.t()) ::
          {:ok, Area.t()} | :skip | {:error, Provider.reason()}
  defdelegate normalize(manifest, row), to: GeoJSON

  @impl Provider
  @doc "Delegates to `GeoGenius.Providers.GeoJSON.relations/1`: a converted shapefile's areas carry no hierarchy of their own; relations are always rebuilt."
  @spec relations(Manifest.t()) :: :rebuild | :none
  defdelegate relations(manifest), to: GeoJSON

  @impl Provider
  @doc "Delegates to `GeoGenius.Providers.GeoJSON.asserted_relations/2`: a converted shapefile carries no hierarchy in its columns beyond what its geometry already expresses."
  @spec asserted_relations(Manifest.t(), Staging.Row.t()) :: []
  defdelegate asserted_relations(manifest, row), to: GeoJSON

  # The same fixed root the pipeline creates its per-run directories under.
  # `stage/5` nests a uniquely named `shp_` directory inside it and removes
  # that on the way out, so a direct call -- one that passes no `:work_dir` --
  # leaves nothing behind rather than one empty directory per call.
  defp default_work_dir, do: Path.join(System.tmp_dir!(), "geo_genius")

  defp stage_from_archive(manifest, artifact, path, emit, opts, command, extract_dir) do
    with :ok <- ensure_command_available(command, opts),
         :ok <- ensure_work_dir(extract_dir),
         {:ok, members} <- unzip(path, extract_dir),
         {:ok, shp_path} <- find_shp_member(members, path),
         {:ok, converted_path} <- convert(command, extract_dir, shp_path, opts) do
      GeoJSON.stage(manifest, artifact, converted_path, emit, opts)
    end
  end

  defp ensure_command_available(command, opts) do
    if command.available?("ogr2ogr", opts) do
      :ok
    else
      {:error,
       "ogr2ogr was not found on the search path; install GDAL to stage shapefile artifacts"}
    end
  end

  defp ensure_work_dir(extract_dir) do
    case File.mkdir_p(extract_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         "could not create working directory #{extract_dir}: #{:file.format_error(reason)}"}
    end
  end

  defp unzip(path, extract_dir) do
    case :zip.unzip(String.to_charlist(path), cwd: String.to_charlist(extract_dir)) do
      {:ok, members} -> {:ok, Enum.map(members, &List.to_string/1)}
      {:error, reason} -> {:error, "could not unzip #{path}: #{inspect(reason)}"}
    end
  end

  defp find_shp_member(members, archive_path) do
    case Enum.filter(members, &String.ends_with?(&1, ".shp")) do
      [shp_path] ->
        {:ok, shp_path}

      [] ->
        {:error, "#{Path.basename(archive_path)} contains no .shp member"}

      shp_paths ->
        names = Enum.map_join(shp_paths, ", ", &Path.basename/1)

        {:error,
         "#{Path.basename(archive_path)} contains more than one .shp member (#{names}); " <>
           "picking one would publish half a dataset"}
    end
  end

  defp convert(command, extract_dir, shp_path, opts) do
    out_path = Path.join(extract_dir, @converted_filename)
    args = ["-f", "GeoJSON", "-t_srs", "EPSG:4326", out_path, shp_path]

    case command.run("ogr2ogr", args, opts) do
      {:ok, _output} ->
        {:ok, out_path}

      {:error, {status, output}} ->
        {:error, "ogr2ogr exited #{status} converting #{shp_path}: #{output}"}
    end
  end
end
