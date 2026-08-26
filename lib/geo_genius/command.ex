defmodule GeoGenius.Command do
  @moduledoc """
  Behaviour for invoking an external executable.

  The shapefile provider shells out to `ogr2ogr` to convert a source file to
  the format GeoGenius ingests. `available?/2` lets a phase check for that
  binary up front rather than discovering its absence mid-run, and `run/3`
  invokes it and reports success or failure without raising: a missing
  executable, a non-zero exit, and a zero exit all come back as plain return
  values so a pipeline phase can handle every one of them the same way.
  """

  @doc """
  Reports whether `executable` can be found on the host's search path.

  Takes the same `opts` as `run/3`, so an adapter that wraps or redirects
  another one -- `GeoGenius.Pipeline.CommandAllowlist` does both -- answers a
  probe about the same executable `run/3` would actually invoke, rather than
  about whatever a second resolution path happens to find.
  """
  @callback available?(executable :: String.t(), opts :: keyword()) :: boolean()

  @doc """
  Runs `executable` with `args` and returns its combined output.

  Returns `{:ok, output}` for a zero exit, or `{:error, {exit_status, output}}`
  otherwise. `output` interleaves stdout and stderr in the order the process
  produced them. `opts` carries adapter-specific options such as `:cd` for the
  working directory.
  """
  @callback run(executable :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {:ok, output :: String.t()}
              | {:error, {exit_status :: integer(), output :: String.t()}}
end
