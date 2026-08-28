defmodule GeoGenius.Providers.SimpleMaps do
  @moduledoc """
  The SimpleMaps US cities and ZIP codes datasets.

  Two delimited files, `uscities` and `uszips`, that denormalise the whole
  hierarchy into every row: a city row names its county and state, a ZIP row
  names every county it touches. Counties exist only as those columns, never
  as rows of their own, so they are derived and validated rather than read.

  Each file carries dozens of demographic columns this provider never reads;
  a row's payload keeps every one of them, keyed by its real header name, so
  reading another column is a change to `GeoGenius.Providers.SimpleMaps.Rows`
  alone, with nothing to restage.

  The data carries centroids and no boundaries, so relations are asserted
  from the FIPS columns rather than measured, and `relations/1` is `:none`.
  """

  @behaviour GeoGenius.Provider

  alias GeoGenius.Files
  alias GeoGenius.Manifest
  alias GeoGenius.Provider
  alias GeoGenius.Providers.Delimited
  alias GeoGenius.Providers.SimpleMaps.Rows
  alias GeoGenius.Staging

  # Bounds both the size of a single unnest bind (Staging.insert/3 binds
  # every row in one round trip) and how long a slow artifact can run
  # between heartbeats -- each chunk is one emit call, and the pipeline
  # heartbeats the run's lease from inside that call.
  @chunk_size 1_000

  @area_types [
    %{key: "state", rank: 10},
    %{key: "county", rank: 20},
    %{key: "city", rank: 30},
    %{key: "zip", rank: 40}
  ]

  @impl Provider
  @doc "The fixed US hierarchy this dataset describes."
  @spec area_types() :: [Manifest.area_type()]
  def area_types, do: @area_types

  @impl Provider
  @doc "Reads its columns by name, so a manifest supplies no options."
  @spec required_options() :: [String.t()]
  def required_options, do: []

  @impl Provider
  @doc "Both declared artifacts; the logical name selects the parser."
  @spec artifacts(Manifest.t()) :: [Manifest.Artifact.t()]
  defdelegate artifacts(manifest), to: Provider, as: :all_artifacts

  @impl Provider
  @doc """
  Reads `path` as comma-delimited text and emits its data rows in chunks of
  #{@chunk_size} rows.

  `geom` is always `nil` -- SimpleMaps centroids ride on the `Area` in
  `normalize/2`, not on the staged row, because the source has no boundary
  for a centroid to summarise.
  """
  @spec stage(
          Manifest.t(),
          Manifest.Artifact.t(),
          Path.t(),
          ([Staging.Row.t()] -> :ok),
          Provider.stage_opts()
        ) :: :ok | {:error, Provider.reason()}
  def stage(%Manifest{}, %Manifest.Artifact{} = artifact, path, emit, _opts) do
    Delimited.stage(path, NimbleCSV.RFC4180, @chunk_size, emit, &row_for(&1, &2, artifact))
  rescue
    error in File.Error ->
      {:error, Files.format_error(path, error.reason)}

    error in NimbleCSV.ParseError ->
      {:error, "could not parse #{path}: #{Exception.message(error)}"}
  end

  @impl Provider
  @doc "A city row describes its city, county and state; a ZIP row its ZIP, counties and state."
  @spec normalize(Manifest.t(), Staging.Row.t()) ::
          {:ok, [Provider.Area.t()]} | {:error, Provider.reason()}
  def normalize(%Manifest{}, %Staging.Row{} = row), do: Rows.areas(row)

  @impl Provider
  @doc "SimpleMaps carries no geometry to measure relations from."
  @spec relations(Manifest.t()) :: :none
  def relations(%Manifest{}), do: :none

  @impl Provider
  @doc "State, county, city and ZIP edges read from the row's FIPS columns."
  @spec asserted_relations(Manifest.t(), Staging.Row.t()) ::
          [{String.t(), String.t(), String.t()}]
  def asserted_relations(%Manifest{}, %Staging.Row{} = row), do: Rows.edges(row)

  # The header line names every column; each data line becomes a map keyed
  # by it, so a column this provider never reads is carried rather than
  # dropped.
  defp row_for(headers, values, artifact) do
    payload = headers |> Enum.zip(values) |> Map.new()
    {:ok, %Staging.Row{artifact: artifact.logical_name, payload: payload, geom: nil}}
  end
end
