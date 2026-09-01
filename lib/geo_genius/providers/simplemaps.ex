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

  ## Options

  No option is required. By default every `state_id` value uses the `state`
  area type. A collection that requires geometry for its ordinary states can
  keep the six USPS-only codes (`AA`, `AE`, `AP`, `FM`, `MH`, and `PW`) in a
  separately declared, non-geometric type:

      "options": {"non_census_state_area_type": "postal_region"}

  The value is an area-type key chosen by the host, not a type this provider
  registers. The manifest must declare it in `area_types`; its default remains
  `state` so existing manifests and area keys do not change.
  """

  @behaviour GeoGenius.Provider

  alias GeoGenius.Files
  alias GeoGenius.Manifest
  alias GeoGenius.Provider
  alias GeoGenius.Providers.Delimited
  alias GeoGenius.Providers.SimpleMaps.Rows
  alias GeoGenius.Staging

  @non_census_state_area_type_option "non_census_state_area_type"

  # Bounds both the size of a single unnest bind (Staging.insert/4 binds
  # every row in one round trip) and how long a slow artifact can run
  # between heartbeats -- each chunk is one emit call, and the pipeline
  # heartbeats the run's lease from inside that call.
  @chunk_size 1_000

  @impl Provider
  @doc "Reads its columns by name, so a manifest requires no options."
  @spec required_options() :: [String.t()]
  def required_options, do: []

  @impl Provider
  @doc "Validates the optional area type used for the six non-Census USPS state codes."
  @spec validate_options(map() | nil) :: :ok | {:error, String.t()}
  def validate_options(options) do
    case non_census_state_area_type(options) do
      {:ok, _area_type} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl Provider
  @doc "Ensures the effective non-Census state type is declared and non-geometric."
  @spec validate_manifest(Manifest.t()) :: :ok | {:error, String.t()}
  def validate_manifest(%Manifest{area_types: area_types, options: options}) do
    with {:ok, area_type} <- non_census_state_area_type(options) do
      validate_non_census_state_area_type(area_types, area_type)
    end
  end

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
  @doc "Describes each row's city or ZIP, counties, and state-like area."
  @spec normalize(Manifest.t(), Staging.Row.t()) ::
          {:ok, [Provider.Area.t()]} | {:error, Provider.reason()}
  def normalize(%Manifest{options: options}, %Staging.Row{} = row) do
    with {:ok, area_type} <- non_census_state_area_type(options) do
      Rows.areas(row, area_type)
    end
  end

  @impl Provider
  @doc "SimpleMaps carries no geometry to measure relations from."
  @spec relations(Manifest.t()) :: :none
  def relations(%Manifest{}), do: :none

  @impl Provider
  @doc "State-like, county, city and ZIP edges read from the row's FIPS columns."
  @spec asserted_relations(Manifest.t(), Staging.Row.t()) ::
          [{String.t(), String.t(), String.t()}]
  def asserted_relations(%Manifest{options: options}, %Staging.Row{} = row) do
    case non_census_state_area_type(options) do
      {:ok, area_type} -> Rows.edges(row, area_type)
      {:error, _reason} -> []
    end
  end

  defp non_census_state_area_type(options) when is_map(options) do
    case Map.fetch(options, @non_census_state_area_type_option) do
      :error ->
        {:ok, "state"}

      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          invalid_non_census_state_area_type(value)
        else
          {:ok, value}
        end

      {:ok, value} ->
        invalid_non_census_state_area_type(value)
    end
  end

  defp non_census_state_area_type(nil), do: {:ok, "state"}

  defp non_census_state_area_type(options) do
    {:error, "options must be a map or nil, got: #{inspect(options)}"}
  end

  defp invalid_non_census_state_area_type(value) do
    {:error,
     "#{@non_census_state_area_type_option} must be a non-blank string, got: #{inspect(value)}"}
  end

  defp validate_non_census_state_area_type(area_types, configured_type) do
    case Enum.find(List.wrap(area_types), &(&1.key == configured_type)) do
      nil ->
        {:error,
         "non_census_state_area_type #{inspect(configured_type)} must name an entry in area_types"}

      %{requires_geometry: true} ->
        {:error,
         "non_census_state_area_type #{inspect(configured_type)} must have requires_geometry false"}

      _non_geometric_type ->
        :ok
    end
  end

  # The header line names every column; each data line becomes a map keyed
  # by it, so a column this provider never reads is carried rather than
  # dropped.
  defp row_for(headers, values, artifact) do
    payload = headers |> Enum.zip(values) |> Map.new()
    {:ok, %Staging.Row{artifact: artifact.logical_name, payload: payload, geom: nil}}
  end
end
