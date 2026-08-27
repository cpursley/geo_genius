defmodule GeoGenius.Providers.GeoJSON do
  @moduledoc """
  Provider for a single GeoJSON `FeatureCollection` artifact.

  One feature becomes one staged row: `payload` is the feature's
  `"properties"` map, `geom` is its decoded geometry or `nil` for a feature
  that carries none. `normalize/2` reads the code and name out of `payload`
  using the manifest's `options`, so the same module serves any collection
  whose properties name their code and display name differently.

  `required_options/0` requires `"area_type"` and `"code_property"`. The
  remaining `options` keys are optional:

    * `"name_property"` -- defaults to `"name"`.
    * `"authority"` -- defaults to the manifest's own authority, when it
      declares exactly one.
    * `"attribute_properties"` -- a list; defaults to `[]`.
    * `"alias_properties"` -- a list; defaults to `[]`.
    * `"code_properties"` -- a list of `%{"type" => ..., "property" => ...}`;
      defaults to `[]`.

  See the option-vocabulary table in `GeoGenius.Provider`'s moduledoc for how
  these correspond to `GeoGenius.Providers.CSV`'s own option keys.
  """

  @behaviour GeoGenius.Provider

  alias GeoGenius.Files
  alias GeoGenius.Manifest
  alias GeoGenius.Provider
  alias GeoGenius.Provider.Area
  alias GeoGenius.Providers.Batch
  alias GeoGenius.Providers.Fields
  alias GeoGenius.Providers.ManifestOptions
  alias GeoGenius.Staging

  # Bounds both the size of a single unnest bind (Staging.insert/3 binds
  # every row in one round trip) and how long a slow artifact can run
  # between heartbeats -- each chunk is one emit call, and the pipeline
  # heartbeats the run's lease from inside that call. Matches
  # Staging.stream/3's own default page size, so the two phases move
  # through a run at a comparable granularity.
  @chunk_size 1_000

  @impl Provider
  @doc "GeoJSON carries no fixed hierarchy of its own; every manifest supplies its own area_types."
  @spec area_types() :: [Manifest.area_type()]
  defdelegate area_types(), to: Provider, as: :no_area_types

  @impl Provider
  @doc "Requires `area_type` and `code_property` in the manifest's options."
  @spec required_options() :: [String.t()]
  def required_options, do: ["area_type", "code_property"]

  @impl Provider
  @doc "Every artifact declared across the manifest's sources; a GeoJSON collection's artifacts are all GeoJSON."
  @spec artifacts(Manifest.t()) :: [Manifest.Artifact.t()]
  defdelegate artifacts(manifest), to: Provider, as: :all_artifacts

  @impl Provider
  @doc """
  Reads `path` as a GeoJSON `FeatureCollection` and emits its features in
  chunks of #{@chunk_size} rows.
  """
  @spec stage(
          Manifest.t(),
          Manifest.Artifact.t(),
          Path.t(),
          ([Staging.Row.t()] -> :ok),
          Provider.stage_opts()
        ) :: :ok | {:error, Provider.reason()}
  def stage(%Manifest{}, %Manifest.Artifact{} = artifact, path, emit, _opts) do
    with {:ok, content} <- read_document(path),
         {:ok, decoded} <- parse_document(content),
         {:ok, document} <- require_feature_collection(decoded),
         {:ok, features} <- require_feature_list(document) do
      stage_features(features, artifact, emit)
    end
  end

  @impl Provider
  @doc "Reads the code and name out of the staged row's payload, using the manifest's options."
  @spec normalize(Manifest.t(), Staging.Row.t()) :: {:ok, Area.t()} | :skip | {:error, String.t()}
  def normalize(%Manifest{options: options} = manifest, %Staging.Row{} = row) do
    with {:ok, keys} <- ManifestOptions.area_keys(manifest, options, "code_property") do
      build_area(row, keys, options)
    end
  end

  @impl Provider
  @doc "GeoJSON areas carry no hierarchy of their own; relations are always rebuilt."
  @spec relations(Manifest.t()) :: :rebuild
  defdelegate relations(manifest), to: Provider, as: :always_rebuild

  @impl Provider
  @doc "Asserts no relations; this format carries no hierarchy in its columns."
  @spec asserted_relations(Manifest.t(), Staging.Row.t()) :: []
  defdelegate asserted_relations(manifest, row), to: Provider, as: :no_asserted_relations

  defp read_document(path) do
    case Files.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, Files.format_error(path, reason)}
    end
  end

  defp parse_document(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
    end
  end

  defp require_feature_collection(%{"type" => "FeatureCollection"} = document) do
    {:ok, document}
  end

  defp require_feature_collection(%{"type" => other}) do
    {:error, "expected a GeoJSON FeatureCollection, got type #{inspect(other)}"}
  end

  defp require_feature_collection(_other) do
    {:error, "expected a GeoJSON FeatureCollection document"}
  end

  defp require_feature_list(document) do
    case Map.get(document, "features", []) do
      features when is_list(features) -> require_feature_maps(features)
      other -> {:error, "expected \"features\" to be a list, got: #{inspect(other)}"}
    end
  end

  defp require_feature_maps(features) do
    case Enum.find_value(features, &invalid_feature_error/1) do
      nil -> {:ok, features}
      error -> {:error, error}
    end
  end

  defp invalid_feature_error(feature) when is_map(feature), do: nil

  defp invalid_feature_error(other) do
    "expected every feature to be a JSON object, got: #{inspect(other)}"
  end

  defp stage_features(features, artifact, emit) do
    features
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while(:ok, &stage_chunk(&1, artifact, emit, &2))
  end

  defp stage_chunk(chunk, artifact, emit, :ok) do
    case Batch.rows(chunk, &row_for(artifact, &1)) do
      {:ok, rows} ->
        :ok = emit.(rows)
        {:cont, :ok}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp row_for(artifact, feature) do
    case decode_geometry(Map.get(feature, "geometry")) do
      {:ok, geom} ->
        {:ok,
         %Staging.Row{
           artifact: artifact.logical_name,
           payload: Map.get(feature, "properties", %{}),
           geom: geom
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_geometry(nil), do: {:ok, nil}

  defp decode_geometry(geometry) when is_map(geometry) do
    case Geo.JSON.decode(geometry) do
      {:ok, geom} -> {:ok, geom}
      {:error, error} -> {:error, "invalid geometry: #{Exception.message(error)}"}
    end
  end

  defp decode_geometry(other) do
    {:error, "expected \"geometry\" to be a JSON object or null, got: #{inspect(other)}"}
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
           geometry: row.geom,
           names: names(row.payload, options),
           codes: ManifestOptions.codes(row.payload, options, "code_properties", "property"),
           attributes: ManifestOptions.attributes(row.payload, options, "attribute_properties")
         }}
    end
  end

  defp names(payload, options) do
    name_property = Map.get(options, "name_property", "name")
    alias_properties = Map.get(options, "alias_properties", [])

    ManifestOptions.names(payload, name_property, alias_properties)
  end
end
