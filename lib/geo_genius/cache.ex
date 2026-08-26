defmodule GeoGenius.Cache do
  @moduledoc """
  Where downloaded and operator-supplied artifacts live between runs.

  An import that reruns against the same manifest must not re-download an
  artifact whose checksum already matched, and a licensed artifact that no URL
  can serve is placed here by an operator before the run starts. Both are the
  same lookup, so the cache is checked before the downloader is ever consulted.

  A key is a slash-joined path of validated segments. Build one with `key/1`
  rather than by interpolation: the segments come from a manifest, and a
  segment carrying a separator or a parent reference would place the file
  outside the cache root.
  """

  @callback fetch(key :: String.t(), opts :: keyword()) :: {:ok, Path.t()} | :miss
  @callback put(key :: String.t(), source_path :: Path.t(), opts :: keyword()) ::
              {:ok, Path.t()} | {:error, term()}
  @callback path(key :: String.t(), opts :: keyword()) :: Path.t()
  @callback delete(key :: String.t(), opts :: keyword()) :: :ok

  @segment ~r/\A[A-Za-z0-9_:][A-Za-z0-9_.:-]*\z/

  @doc """
  Joins validated segments into a cache key.

  Each segment must match #{inspect(@segment)}: alphanumerics, underscore,
  colon, dot, and hyphen, starting with something other than a dot. That
  excludes the path separator and both `.` and `..`, so no manifest value can
  make a key that resolves outside the cache root.
  """
  @spec key([String.t()]) :: String.t()
  def key([_ | _] = segments) do
    Enum.each(segments, &validate_segment!/1)
    Enum.join(segments, "/")
  end

  def key(segments) do
    raise ArgumentError, "a cache key needs at least one segment, got: #{inspect(segments)}"
  end

  defp validate_segment!(segment) when is_binary(segment) do
    unless Regex.match?(@segment, segment) do
      raise ArgumentError,
            "invalid cache key segment #{inspect(segment)}: expected #{inspect(@segment)}"
    end
  end

  defp validate_segment!(segment) do
    raise ArgumentError, "a cache key segment must be a string, got: #{inspect(segment)}"
  end
end
