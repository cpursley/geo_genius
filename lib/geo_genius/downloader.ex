defmodule GeoGenius.Downloader do
  @moduledoc """
  Behaviour for fetching a remote artifact to a local path.

  A downloader only reports what it observed while streaming: how many bytes
  arrived and what they hashed to. It never compares that observation against
  an expectation drawn from a manifest. `record_artifact_observation/3` in
  PostgreSQL is where expectation meets observation; keeping the comparison
  there, and only there, is what keeps the two from disagreeing.
  """

  @doc """
  Reports whether this downloader's underlying HTTP client is loaded and
  usable. A caller checks this before attempting a fetch so a missing
  optional dependency surfaces as a plain error rather than an
  `UndefinedFunctionError` deep inside an import phase.
  """
  @callback available?() :: boolean()

  @doc """
  Streams the body at `url` to `destination`, hashing it as it arrives.

  Returns `{:ok, %{bytes: non_neg_integer(), sha256: String.t()}}` describing
  what was written, or `{:error, term()}` if the request failed. A failed
  fetch must not leave a partial or corrupt file at `destination`.
  """
  @callback fetch(url :: String.t(), destination :: Path.t(), opts :: keyword()) ::
              {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, term()}

  @chunk_bytes 65_536

  @doc """
  The SHA-256 and byte count of a file already on disk.

  A cache hit is verified with this before its observation is recorded, so a
  downloaded artifact and a cached one reach `record_artifact_observation/3`
  through the same check. It reads in chunks of #{@chunk_bytes} bytes rather
  than loading the file, because an artifact is routinely larger than memory.

  `GeoGenius.Downloaders.Req` computes the same digest while streaming and so
  never calls this; the two must agree, and the import pipeline's test proves
  they do by recording an observation from each path.
  """
  @spec hash_file(Path.t()) ::
          {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, term()}
  def hash_file(path) do
    path
    |> File.stream!(@chunk_bytes)
    |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {state, bytes} ->
      {:crypto.hash_update(state, chunk), bytes + byte_size(chunk)}
    end)
    |> then(fn {state, bytes} ->
      {:ok, %{bytes: bytes, sha256: Base.encode16(:crypto.hash_final(state), case: :lower)}}
    end)
  rescue
    error -> {:error, error}
  end
end
