defmodule GeoGenius.Providers.GeoJSONSequence do
  @moduledoc """
  Streams newline- or RFC 8142 record-separator-delimited GeoJSON Features.

  Each non-blank record is decoded and staged independently. Rows accumulate
  only until `:emit_batch_size` (500 by default), then the provided `emit`
  function receives that batch before the reader advances through the file.
  """

  @behaviour GeoGenius.Provider

  alias GeoGenius.Files
  alias GeoGenius.Manifest
  alias GeoGenius.Provider
  alias GeoGenius.Providers.Batch
  alias GeoGenius.Providers.GeoJSON
  alias GeoGenius.Providers.GeoJSONGeometry
  alias GeoGenius.Staging

  @default_emit_batch_size 500

  @impl Provider
  defdelegate required_options(), to: GeoJSON

  @impl Provider
  defdelegate validate_options(options), to: GeoJSON

  @impl Provider
  defdelegate artifacts(manifest), to: GeoJSON

  @impl Provider
  @spec stage(
          Manifest.t(),
          Manifest.Artifact.t(),
          Path.t(),
          ([Staging.Row.t()] -> :ok),
          Provider.stage_opts()
        ) :: :ok | {:error, Provider.reason()}
  def stage(%Manifest{}, %Manifest.Artifact{} = artifact, path, emit, opts) do
    batch_size = Keyword.get(opts, :emit_batch_size, @default_emit_batch_size)

    with :ok <- validate_batch_size(batch_size) do
      stage_file(path, artifact, emit, batch_size)
    end
  rescue
    error in File.Error ->
      {:error, Files.format_error(path, error.reason)}
  end

  @impl Provider
  defdelegate normalize(manifest, row), to: GeoJSON

  @impl Provider
  defdelegate relations(manifest), to: GeoJSON

  @impl Provider
  defdelegate asserted_relations(manifest, row), to: GeoJSON

  defp validate_batch_size(size) when is_integer(size) and size > 0, do: :ok

  defp validate_batch_size(size) do
    {:error, "emit_batch_size must be a positive integer, got: #{inspect(size)}"}
  end

  defp stage_file(path, artifact, emit, batch_size) do
    path
    |> File.stream!([], :line)
    |> Enum.reduce_while({:ok, 0, []}, &stage_record(&1, artifact, emit, batch_size, &2))
    |> finish(artifact, emit)
  end

  defp stage_record(line, artifact, emit, batch_size, {:ok, record_number, batch}) do
    stage_parsed_record(record(line), artifact, emit, batch_size, record_number, batch)
  end

  defp stage_parsed_record(:blank, _artifact, _emit, _batch_size, record_number, batch),
    do: {:cont, {:ok, record_number, batch}}

  defp stage_parsed_record(
         {:error, reason},
         _artifact,
         _emit,
         _batch_size,
         record_number,
         _batch
       ),
       do: {:halt, {:error, "record #{record_number + 1}: #{reason}"}}

  defp stage_parsed_record({:ok, feature}, artifact, emit, batch_size, record_number, batch) do
    next_record_number = record_number + 1
    next_batch = [{next_record_number, feature} | batch]

    stage_batch(next_batch, artifact, emit, batch_size, next_record_number)
  end

  defp stage_batch(batch, artifact, emit, batch_size, record_number)
       when length(batch) == batch_size do
    case emit_batch(Enum.reverse(batch), artifact, emit) do
      :ok -> {:cont, {:ok, record_number, []}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp stage_batch(batch, _artifact, _emit, _batch_size, record_number),
    do: {:cont, {:ok, record_number, batch}}

  defp finish({:ok, _record_number, []}, _artifact, _emit), do: :ok

  defp finish({:ok, _record_number, batch}, artifact, emit) do
    emit_batch(Enum.reverse(batch), artifact, emit)
  end

  defp finish({:error, _reason} = error, _artifact, _emit), do: error

  defp record(line) do
    line
    |> String.replace_prefix(<<0x1E>>, "")
    |> String.trim()
    |> decode_record()
  end

  defp decode_record(""), do: :blank

  defp decode_record(content) do
    with {:ok, decoded} <- Jason.decode(content),
         :ok <- require_feature(decoded) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      {:error, _reason} = error -> error
    end
  end

  defp require_feature(%{"type" => "Feature"}), do: :ok

  defp require_feature(%{"type" => type}) do
    {:error, "expected a GeoJSON Feature, got type #{inspect(type)}"}
  end

  defp require_feature(_record), do: {:error, "expected a GeoJSON Feature object"}

  defp emit_batch(records, artifact, emit) do
    case Batch.rows(records, &row_for(artifact, &1)) do
      {:ok, rows} ->
        :ok = emit.(rows)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp row_for(artifact, {record_number, feature}) do
    case GeoJSONGeometry.decode(Map.get(feature, "geometry")) do
      {:ok, geom} ->
        {:ok,
         %Staging.Row{
           artifact: artifact.logical_name,
           payload: Map.get(feature, "properties", %{}),
           geom: geom
         }}

      {:error, reason} ->
        {:error, "record #{record_number}: #{reason}"}
    end
  end
end
