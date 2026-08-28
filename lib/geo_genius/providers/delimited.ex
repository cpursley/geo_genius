defmodule GeoGenius.Providers.Delimited do
  @moduledoc """
  Streams a delimited artifact in chunks, reading its first line as the
  header row and handing each data line to the provider's own row builder.

  Sits directly above `GeoGenius.Providers.Batch`, which turns one chunk's
  data lines into staged rows: this is the header-tracking accumulator around
  it -- `:pending` until the header line is read, `{:headers, headers}` from
  then on -- plus the chunking and the emit call. `GeoGenius.Providers.CSV`
  and `GeoGenius.Providers.SimpleMaps` both read that shape of file and differ
  only in the parser they choose and in what each builds from a line, so both
  supply those two things and share everything else. A third delimited
  provider supplies them too rather than copying either.

  Whatever `File.stream!/1` and the parser raise is left to propagate: each
  provider rescues those around its own call and reports them in the
  vocabulary of the format it documents.
  """

  alias GeoGenius.Providers.Batch
  alias GeoGenius.Staging

  @typedoc "Builds one staged row from the file's header names and one data line's values."
  @type row_builder ::
          ([String.t()], [String.t()] -> {:ok, Staging.Row.t()} | {:error, term()})

  @doc """
  Parses `path` with `parser`, emitting the staged rows of each `chunk_size`
  lines in one `emit` call.

  Returns the first `{:error, reason}` `row_builder` produces, staging none of
  the lines after it, and `:ok` for a file every line of which built a row --
  including one carrying nothing but a header.
  """
  @spec stage(
          Path.t(),
          module(),
          pos_integer(),
          ([Staging.Row.t()] -> :ok),
          row_builder()
        ) :: :ok | {:error, term()}
  def stage(path, parser, chunk_size, emit, row_builder) do
    path
    |> File.stream!()
    |> parser.parse_stream(skip_headers: false)
    |> Stream.chunk_every(chunk_size)
    |> Enum.reduce_while(:pending, &stage_chunk(&1, emit, row_builder, &2))
    |> finish()
  end

  defp finish(:pending), do: :ok
  defp finish({:headers, _headers}), do: :ok
  defp finish({:error, _reason} = error), do: error

  defp stage_chunk([headers | rows], emit, row_builder, :pending) do
    stage_rows(rows, headers, emit, row_builder)
  end

  defp stage_chunk(chunk, emit, row_builder, {:headers, headers}) do
    stage_rows(chunk, headers, emit, row_builder)
  end

  defp stage_rows([], headers, _emit, _row_builder), do: {:cont, {:headers, headers}}

  defp stage_rows(values_rows, headers, emit, row_builder) do
    case Batch.rows(values_rows, &row_builder.(headers, &1)) do
      {:ok, rows} ->
        :ok = emit.(rows)
        {:cont, {:headers, headers}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end
end
