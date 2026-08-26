defmodule GeoGenius.Caches.FileSystem do
  @moduledoc """
  The shipped `GeoGenius.Cache`: artifacts stored as plain files under one
  root directory.

  The root is `opts[:cache_dir]`, then `config :geo_genius, :cache_dir`, then
  a `geo_genius` directory under the system temp directory. A key becomes a
  path by joining its segments onto the root; `path/2` refuses a key whose
  segments would resolve outside that root, both by rejecting an invalid
  segment before any joining happens and by checking the joined, expanded
  path still starts with the expanded root.
  """

  @behaviour GeoGenius.Cache

  alias GeoGenius.Cache

  @impl GeoGenius.Cache
  @spec fetch(String.t(), keyword()) :: {:ok, Path.t()} | :miss
  def fetch(key, opts) do
    stored = path(key, opts)

    if File.regular?(stored) do
      {:ok, stored}
    else
      :miss
    end
  end

  @doc """
  Copies `source_path` into the cache under `key`.

  The copy lands at a `.part.<unique>` sibling of the final path first and is
  renamed onto the final path only once it is complete, so a copy interrupted
  midway never leaves a truncated file for `fetch/2` to report as a hit. The
  unique suffix gives every call its own staging file, so two concurrent
  `put/3` calls for the same key -- two manifest sources sharing a
  `cache_key`, or a parallel runner -- never truncate each other's copy under
  them. The source is copied, not moved or renamed: the caller may still need
  it after the cache has its own copy. On failure the staging file is removed
  before the error is returned, so a copy that fails partway (an out-of-space
  disk, for instance) leaves nothing behind in the cache root.
  """
  @impl GeoGenius.Cache
  @spec put(String.t(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def put(key, source_path, opts) do
    destination = path(key, opts)
    part_path = destination <> ".part." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, _bytes} <- File.copy(source_path, part_path),
         :ok <- File.rename(part_path, destination) do
      {:ok, destination}
    else
      {:error, _reason} = error ->
        File.rm(part_path)
        error
    end
  end

  @impl GeoGenius.Cache
  @spec path(String.t(), keyword()) :: Path.t()
  def path(key, opts) when is_binary(key) do
    root = root(opts)
    segments = String.split(key, "/")
    _validated = Cache.key(segments)

    candidate = Path.join([root | segments])

    if within_root?(candidate, root) do
      candidate
    else
      raise ArgumentError, "cache key #{inspect(key)} resolves outside the cache root"
    end
  end

  def path(key, _opts) do
    raise ArgumentError, "cache key must be a string, got: #{inspect(key)}"
  end

  @doc false
  @spec within_root?(Path.t(), Path.t()) :: boolean()
  def within_root?(candidate, root) do
    String.starts_with?(Path.expand(candidate) <> "/", Path.expand(root) <> "/")
  end

  @doc "Removes the file stored under `key`, if any. Removing a missing key is not an error."
  @impl GeoGenius.Cache
  @spec delete(String.t(), keyword()) :: :ok
  def delete(key, opts) do
    File.rm(path(key, opts))
    :ok
  end

  defp root(opts) do
    Keyword.get_lazy(opts, :cache_dir, fn ->
      Application.get_env(:geo_genius, :cache_dir, Path.join(System.tmp_dir!(), "geo_genius"))
    end)
  end
end
