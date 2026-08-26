NimbleCSV.define(GeoGenius.Providers.CSV.Parsers.Tab,
  separator: "\t",
  escape: "\"",
  moduledoc: "NimbleCSV parser for a tab-delimited artifact, defined once at compile time."
)

NimbleCSV.define(GeoGenius.Providers.CSV.Parsers.Semicolon,
  separator: ";",
  escape: "\"",
  moduledoc: "NimbleCSV parser for a semicolon-delimited artifact, defined once at compile time."
)

NimbleCSV.define(GeoGenius.Providers.CSV.Parsers.Pipe,
  separator: "|",
  escape: "\"",
  moduledoc: "NimbleCSV parser for a pipe-delimited artifact, defined once at compile time."
)

defmodule GeoGenius.Providers.CSV do
  @moduledoc """
  Provider for a single delimited-text artifact with a header row.

  One data row becomes one staged row: `payload` is a map keyed by header
  name, every value a string, and `geom` is a `%Geo.Point{}` built from
  `lon_column`/`lat_column` when both are configured and the row's cells for
  them are non-empty, or `nil` otherwise. A CSV source carries no polygons --
  a collection of postal codes with centroids and no boundaries is a
  first-class catalog, not a degraded one. `normalize/2` reads the code and
  names out of `payload` using the manifest's `options`, so the same module
  serves any collection whose columns name their code and display name
  differently.

  `required_options/0` requires `"area_type"` and `"code_column"`. The
  remaining `options` keys are optional:

    * `"name_column"` -- defaults to `"name"`.
    * `"authority"` -- defaults to the manifest's `authority.key`.
    * `"lon_column"` and `"lat_column"` -- both required together to build a
      centroid; neither alone.
    * `"attribute_columns"` -- a list; defaults to `[]`.
    * `"alias_columns"` -- a list; defaults to `[]`.
    * `"code_columns"` -- a list of `%{"type" => ..., "column" => ...}`;
      defaults to `[]`.
    * `"delimiter"` -- one of `","`, `"\\t"`, `";"`, `"|"`; defaults to `","`.

  See the option-vocabulary table in `GeoGenius.Provider`'s moduledoc for how
  these correspond to `GeoGenius.Providers.GeoJSON`'s own option keys.
  """

  @behaviour GeoGenius.Provider

  alias GeoGenius.Files
  alias GeoGenius.Manifest
  alias GeoGenius.Provider
  alias GeoGenius.Provider.Area
  alias GeoGenius.Providers.Batch
  alias GeoGenius.Providers.CSV.Parsers.Pipe
  alias GeoGenius.Providers.CSV.Parsers.Semicolon
  alias GeoGenius.Providers.CSV.Parsers.Tab
  alias GeoGenius.Providers.Fields
  alias GeoGenius.Providers.ManifestOptions
  alias GeoGenius.Staging

  # Bounds both the size of a single unnest bind (Staging.insert/3 binds
  # every row in one round trip) and how long a slow artifact can run
  # between heartbeats -- each chunk is one emit call, and the pipeline
  # heartbeats the run's lease from inside that call.
  @chunk_size 1_000

  # A fixed set defined once at compile time. NimbleCSV.define/2 generates a
  # module, so building one per delimiter at runtime would leak atoms; an
  # unbounded delimiter is not a feature anyone asked for.
  @parsers %{
    "," => NimbleCSV.RFC4180,
    "\t" => Tab,
    ";" => Semicolon,
    "|" => Pipe
  }

  @impl Provider
  @doc "CSV carries no fixed hierarchy of its own; every manifest supplies its own area_types."
  @spec area_types() :: [Manifest.area_type()]
  defdelegate area_types(), to: Provider, as: :no_area_types

  @impl Provider
  @doc "Requires `area_type` and `code_column` in the manifest's options."
  @spec required_options() :: [String.t()]
  def required_options, do: ["area_type", "code_column"]

  @impl Provider
  @doc "Every artifact declared across the manifest's sources; a CSV collection's artifacts are all delimited text."
  @spec artifacts(Manifest.t()) :: [Manifest.Artifact.t()]
  defdelegate artifacts(manifest), to: Provider, as: :all_artifacts

  @impl Provider
  @doc """
  Reads `path` as delimited text and emits its data rows in chunks of #{@chunk_size} rows.
  """
  @spec stage(
          Manifest.t(),
          Manifest.Artifact.t(),
          Path.t(),
          ([Staging.Row.t()] -> :ok),
          Provider.stage_opts()
        ) :: :ok | {:error, Provider.reason()}
  def stage(%Manifest{options: options}, %Manifest.Artifact{} = artifact, path, emit, _opts) do
    with {:ok, parser} <- parser_for(Map.get(options, "delimiter", ",")),
         {:ok, coord_columns} <- coordinate_columns(options) do
      stage_file(path, parser, coord_columns, artifact, emit)
    end
  end

  @impl Provider
  @doc "Reads the code and names out of the staged row's payload, using the manifest's options."
  @spec normalize(Manifest.t(), Staging.Row.t()) :: {:ok, Area.t()} | :skip | {:error, String.t()}
  def normalize(%Manifest{options: options} = manifest, %Staging.Row{} = row) do
    with {:ok, keys} <- ManifestOptions.area_keys(manifest, options, "code_column") do
      build_area(row, keys, options)
    end
  end

  @impl Provider
  @doc "CSV areas carry no hierarchy of their own; relations are always rebuilt."
  @spec relations(Manifest.t()) :: :rebuild
  defdelegate relations(manifest), to: Provider, as: :always_rebuild

  defp parser_for(delimiter) do
    case Map.fetch(@parsers, delimiter) do
      {:ok, parser} ->
        {:ok, parser}

      :error ->
        supported = @parsers |> Map.keys() |> Enum.map_join(", ", &inspect/1)

        {:error,
         "unsupported CSV delimiter #{inspect(delimiter)}; supported delimiters are #{supported}"}
    end
  end

  defp coordinate_columns(options) do
    case {Map.get(options, "lon_column"), Map.get(options, "lat_column")} do
      {nil, nil} ->
        {:ok, nil}

      {lon, lat} when is_binary(lon) and is_binary(lat) ->
        {:ok, {lon, lat}}

      _partial ->
        {:error,
         "manifest options must set both \"lon_column\" and \"lat_column\" together to build a centroid, or neither"}
    end
  end

  defp stage_file(path, parser, coord_columns, artifact, emit) do
    path
    |> File.stream!()
    |> parser.parse_stream(skip_headers: false)
    |> Stream.chunk_every(@chunk_size)
    |> Enum.reduce_while(:pending, &stage_chunk(&1, coord_columns, artifact, emit, &2))
    |> finish()
  rescue
    error in File.Error ->
      {:error, Files.format_error(path, error.reason)}

    error in NimbleCSV.ParseError ->
      {:error, "could not parse #{path} as delimited text: #{Exception.message(error)}"}
  end

  defp finish(:pending), do: :ok
  defp finish({:headers, _headers}), do: :ok
  defp finish({:error, _reason} = error), do: error

  defp stage_chunk([headers | rows], coord_columns, artifact, emit, :pending) do
    stage_rows(rows, headers, coord_columns, artifact, emit)
  end

  defp stage_chunk(chunk, coord_columns, artifact, emit, {:headers, headers}) do
    stage_rows(chunk, headers, coord_columns, artifact, emit)
  end

  defp stage_chunk(_chunk, _coord_columns, _artifact, _emit, {:error, _reason} = error),
    do: {:halt, error}

  defp stage_rows([], headers, _coord_columns, _artifact, _emit), do: {:cont, {:headers, headers}}

  defp stage_rows(values_rows, headers, coord_columns, artifact, emit) do
    case Batch.rows(values_rows, &row_for(headers, &1, coord_columns, artifact)) do
      {:ok, rows} ->
        :ok = emit.(rows)
        {:cont, {:headers, headers}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp row_for(headers, values, coord_columns, artifact) do
    payload = headers |> Enum.zip(values) |> Map.new()

    case geom_for(payload, coord_columns) do
      {:ok, geom} ->
        {:ok, %Staging.Row{artifact: artifact.logical_name, payload: payload, geom: geom}}

      {:error, _reason} = error ->
        error
    end
  end

  defp geom_for(_payload, nil), do: {:ok, nil}

  defp geom_for(payload, {lon_column, lat_column}) do
    with {:ok, lon} <- coerce_coordinate(Map.get(payload, lon_column), lon_column),
         {:ok, lat} <- coerce_coordinate(Map.get(payload, lat_column), lat_column) do
      point_for(lon, lat)
    end
  end

  defp point_for(nil, _lat), do: {:ok, nil}
  defp point_for(_lon, nil), do: {:ok, nil}
  defp point_for(lon, lat), do: {:ok, %Geo.Point{coordinates: {lon, lat}, srid: 4326}}

  defp coerce_coordinate(value, _column) when value in [nil, ""], do: {:ok, nil}

  defp coerce_coordinate(value, column) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} ->
        {:ok, number}

      _other ->
        {:error,
         "expected a numeric coordinate in column #{inspect(column)}, got #{inspect(value)}"}
    end
  end

  defp build_area(row, keys, options) do
    case Fields.presence(Map.get(row.payload, keys.code_field)) do
      nil ->
        :skip

      code ->
        {:ok,
         %Area{
           authority_key: keys.authority_key,
           area_type_key: keys.area_type_key,
           code: code,
           centroid: row.geom,
           names: names(row.payload, options),
           codes: ManifestOptions.codes(row.payload, options, "code_columns", "column"),
           attributes: ManifestOptions.attributes(row.payload, options, "attribute_columns")
         }}
    end
  end

  defp names(payload, options) do
    name_column = Map.get(options, "name_column", "name")
    alias_columns = Map.get(options, "alias_columns", [])

    ManifestOptions.names(payload, name_column, alias_columns)
  end
end
