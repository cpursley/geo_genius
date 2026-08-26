defmodule GeoGenius.Files do
  @moduledoc """
  Filesystem helpers shared by manifest loading and the providers that read
  staged artifacts from disk.

  `read/1` returns the raw `File.posix()` reason on failure rather than a
  formatted string, so a caller can tell `:enoent` -- a licensed artifact the
  operator has not dropped into the cache yet, which has a specific remedy --
  from `:eacces` or another failure it cannot recover from the same way.
  `format_error/2` turns that reason into the message most callers want to
  surface, once they have decided they have nothing more specific to say.

  `read/1` looks like it adds nothing over calling `File.read/1` directly --
  it is a one-line body with no branching -- but the raw passthrough is the
  point, not an oversight: `GeoGenius.Manifest` needs the unformatted reason
  to build its own `ManifestError`, carrying `path` and a formatted `reason`
  as separate fields, while `GeoGenius.Providers.GeoJSON` formats the same
  reason into a plain string. Pre-formatting inside `read/1` would serve the
  second caller and break the first. This module's actual job is owning
  `format_error/2` -- the one formatting rule every caller shares -- while
  leaving each caller free to decide whether and how to wrap the raw reason.
  `test/geo_genius/files_test.exs` pins the raw-passthrough contract down
  with an assertion in its own name.
  """

  @doc "Reads `path`, returning the OS-level failure reason unchanged on error."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: File.read(path)

  @doc "Formats a `read/1` failure, naming the path it was for."
  @spec format_error(Path.t(), File.posix()) :: String.t()
  def format_error(path, reason), do: "could not read #{path}: #{:file.format_error(reason)}"
end
