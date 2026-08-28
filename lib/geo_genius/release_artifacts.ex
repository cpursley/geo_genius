defmodule GeoGenius.ReleaseArtifacts.Artifact do
  @moduledoc """
  One artifact a release composes, together with where it resolves to on this
  machine.

  `:path` is where the artifact belongs in the configured cache, whether or not
  anything is there: `:present?` is what says a file is actually sitting at it.
  Reporting the two separately is what lets a caller name the path an operator
  has to place a licensed file at, rather than only reporting that something is
  missing.

  Every other field restates the catalog row the artifact was read from, so a
  caller that has this struct never has to go back to the catalog for the
  checksum it should verify against or the source release it came from.
  """

  @enforce_keys [:logical_name, :cache_key, :path, :present?]
  defstruct [
    :logical_name,
    :cache_key,
    :path,
    :present?,
    :release_id,
    :source_release_id,
    :artifact_id,
    :collection_key,
    :source_key,
    :source_release_key,
    :url,
    :operator_supplied,
    :format,
    :expected_sha256,
    :expected_bytes,
    :observed_sha256,
    :observed_bytes,
    :validated_at,
    :metadata
  ]

  @type t :: %__MODULE__{
          logical_name: String.t(),
          cache_key: String.t(),
          path: Path.t(),
          present?: boolean(),
          release_id: Ecto.UUID.t(),
          source_release_id: Ecto.UUID.t(),
          artifact_id: Ecto.UUID.t(),
          collection_key: String.t(),
          source_key: String.t(),
          source_release_key: String.t(),
          url: String.t() | nil,
          operator_supplied: boolean(),
          format: String.t(),
          expected_sha256: String.t(),
          expected_bytes: integer(),
          observed_sha256: String.t() | nil,
          observed_bytes: integer() | nil,
          validated_at: DateTime.t() | nil,
          metadata: map()
        }
end

defmodule GeoGenius.ReleaseArtifacts do
  @moduledoc """
  What files a release was built from, and where each one is on this machine.

  GeoGenius stores area identity -- keys, names, codes, relations, centroids,
  boundaries -- and deliberately not a source's own wide attribute columns. A
  host that wants those keeps a **projection**: its own table, keyed
  `(release_id, area_key)`, filled from the same artifacts the import consumed.
  Building one means answering two questions this module owns, and nothing
  about the file's contents, which the host owns entirely. See
  `guides/projections.md`.

  Locating an artifact is not a `Path.join/2`. An artifact reaches the machine
  through `GeoGenius.Cache`, under a key the manifest supplied or the catalog
  derived, and an **operator-supplied** artifact has no `url` to fall back on
  -- the cache key is the only address it has. A caller that looked in `priv/`,
  or in the directory an import happened to stage a download in, works against
  a fixture and raises `:enoent` on a documented fresh install.

  Reads the release a collection currently publishes. `:release_id` names a
  different one, published or not, which is how a projection is backfilled for
  a release before it goes live; it is checked against the collection first, so
  a stale id and another collection's id are both refused rather than answered
  with the wrong rows or none. Every function also takes the usual `:repo`,
  `:prefix`, and adapter options, and passes `opts` to the cache unchanged, so
  `:cache_dir` reaches `GeoGenius.Caches.FileSystem`.
  """

  alias GeoGenius.ArtifactError
  alias GeoGenius.Cache
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ReleaseArtifacts.Artifact

  @doc """
  Every artifact a release composes, ordered by logical name -- the order
  `GeoGenius.Catalog.release_artifacts/2` reads them in, so it is PostgreSQL's
  guarantee rather than this module's.

  `:release_id` reads a release other than the published one. It must be a
  release of `collection_key`: an id the catalog does not carry, or one
  belonging to another collection, is refused rather than read.

  Returns `{:error, %GeoGenius.ArtifactError{reason: :no_published_release}}`
  for a collection publishing nothing, rather than an empty list: a release
  that legitimately composes no artifacts is a different answer, and a caller
  repopulating a projection needs to tell them apart.

  One artifact whose stored cache key is unusable fails the whole call. A
  catalog row nothing can address is a defect in what was registered, and
  quietly returning the rest would let a projection be rebuilt from a subset of
  the files it was supposed to read.
  """
  @spec list(String.t(), keyword()) :: {:ok, [Artifact.t()]} | {:error, ArtifactError.t()}
  def list(collection_key, opts \\ []) do
    context = Context.new(opts)

    with {:ok, release_id} <- release_id(context, collection_key, opts) do
      context
      |> Catalog.release_artifacts(release_id)
      |> resolve_all(context, collection_key, opts)
    end
  end

  @doc """
  One artifact of a release, by the logical name its manifest gave it.

  Resolves the artifact whether or not its file is present, so a caller can ask
  where a licensed artifact *would* be before an operator has placed it.
  `path/3` is the same lookup for a caller that wants a file it can open.
  """
  @spec fetch(String.t(), String.t(), keyword()) ::
          {:ok, Artifact.t()} | {:error, ArtifactError.t()}
  def fetch(collection_key, logical_name, opts \\ []) do
    with {:ok, artifacts} <- list(collection_key, opts) do
      case Enum.find(artifacts, &(&1.logical_name == logical_name)) do
        %Artifact{} = artifact -> {:ok, artifact}
        nil -> {:error, unknown_artifact(collection_key, logical_name, artifacts)}
      end
    end
  end

  @doc """
  The local file one artifact of a release resolves to.

  Returns `{:error, %GeoGenius.ArtifactError{reason: :not_cached}}` when
  nothing is at that path yet, naming both the path and the cache key, so an
  operator reading the message knows where to put the file. That is the whole
  point of returning an error here rather than the path regardless: a caller
  handed a path to a file that does not exist discovers it as an `:enoent`
  raised from inside whatever stream it opened, which names neither.
  """
  @spec path(String.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, ArtifactError.t()}
  def path(collection_key, logical_name, opts \\ []) do
    with {:ok, artifact} <- fetch(collection_key, logical_name, opts) do
      if artifact.present?,
        do: {:ok, artifact.path},
        else: {:error, not_cached(collection_key, artifact)}
    end
  end

  @doc """
  The cache key an artifact row resolves under.

  Takes a row of the `release_artifacts` view, as
  `GeoGenius.Catalog.release_artifacts/2` returns it. A key the manifest
  supplied -- stored on the row's `metadata` -- wins over the one the row's
  columns derive, because that is the whole reason a manifest may carry one: a
  licensed artifact an operator drops into a shared location has an address of
  its own and no `url` to fall back on.

  A supplied key is validated the same way a derived one is. A manifest is
  reviewed, not trusted, and the metadata comes back out of jsonb rather than
  out of manifest validation, so a segment carrying a separator or a parent
  reference is refused here too. The error is the detail alone, without an
  artifact name, so each caller states the failure in its own terms.

  `GeoGenius.Pipeline.Artifacts` resolves its downloads through this function,
  so a release read here is addressed exactly as the import that wrote it
  addressed it.
  """
  @spec cache_key(map()) :: {:ok, String.t()} | {:error, String.t()}
  def cache_key(%{"metadata" => %{"cache_key" => supplied}}) when is_binary(supplied) do
    validated(String.split(supplied, "/"))
  end

  def cache_key(%{"metadata" => %{"cache_key" => supplied}}) do
    {:error, "cache_key is not a string: #{inspect(supplied)}"}
  end

  def cache_key(row) do
    validated([
      row["collection_key"],
      row["source_key"],
      row["source_release_key"],
      row["logical_name"]
    ])
  end

  defp validated(segments) do
    {:ok, Cache.key(segments)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp release_id(context, collection_key, opts) do
    case Keyword.get(opts, :release_id) do
      nil -> published_release_id(context, collection_key)
      release_id -> named_release_id(context, collection_key, release_id)
    end
  end

  # Every release-scoped read filters on the release id alone, so an id that is
  # stale, or that belongs to a different collection, otherwise reads as a
  # release of this one that happens to compose nothing -- or, worse, as this
  # collection's artifacts when they are another's. Neither is a shape a host
  # repopulating a projection can act on: it deletes its rows for that id and
  # writes nothing back. A malformed id is refused the same way a stale one is,
  # rather than raising out of `Ecto.UUID.dump!/1`, because a caller cannot tell
  # the two apart and the remedy is the same.
  defp named_release_id(context, collection_key, release_id) do
    case release_collection_key(context, release_id) do
      ^collection_key ->
        {:ok, release_id}

      nil ->
        {:error,
         ArtifactError.exception(
           reason: :unknown_release,
           collection_key: collection_key,
           release_id: release_id
         )}

      owner ->
        {:error,
         ArtifactError.exception(
           reason: :foreign_release,
           collection_key: collection_key,
           release_id: release_id,
           detail: "it belongs to collection #{inspect(owner)}"
         )}
    end
  end

  defp release_collection_key(context, release_id) do
    Catalog.release_collection_key(context, release_id)
  rescue
    ArgumentError -> nil
  end

  defp published_release_id(context, collection_key) do
    case Catalog.published_release(context, collection_key) do
      nil ->
        {:error,
         ArtifactError.exception(reason: :no_published_release, collection_key: collection_key)}

      release_id ->
        {:ok, release_id}
    end
  end

  # The cache adapter is resolved once for the whole list rather than per row,
  # and travels with the collection key and the options the cache needs in one
  # value, so the reducer below stays inside Credo's arity cap.
  defp resolve_all(rows, context, collection_key, opts) do
    resolver = %{
      cache: Context.adapter(context, :cache),
      collection_key: collection_key,
      opts: opts
    }

    rows
    |> Enum.reduce_while({:ok, []}, &collect(&1, resolver, &2))
    |> collected()
  end

  defp collect(row, resolver, {:ok, acc}) do
    case resolve(row, resolver) do
      {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
      {:error, _error} = error -> {:halt, error}
    end
  end

  defp collected({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp collected({:error, _error} = error), do: error

  defp resolve(row, resolver) do
    case cache_key(row) do
      {:ok, key} -> {:ok, build(row, key, locate(resolver, key))}
      {:error, detail} -> {:error, invalid_cache_key(row, resolver, detail)}
    end
  end

  # `fetch/2` is asked first because it is the cache's own answer to "is this
  # key populated", and it returns the path it found. `path/2` is consulted
  # only for a key nothing is stored under, where it says where a file would
  # have to go.
  defp locate(%{cache: cache, opts: opts}, key) do
    case cache.fetch(key, opts) do
      {:ok, path} -> {path, true}
      :miss -> {cache.path(key, opts), false}
    end
  end

  defp build(row, key, {path, present?}) do
    %Artifact{
      logical_name: row["logical_name"],
      cache_key: key,
      path: path,
      present?: present?,
      release_id: row["release_id"],
      source_release_id: row["source_release_id"],
      artifact_id: row["artifact_id"],
      collection_key: row["collection_key"],
      source_key: row["source_key"],
      source_release_key: row["source_release_key"],
      url: row["url"],
      operator_supplied: row["operator_supplied"],
      format: row["format"],
      expected_sha256: row["expected_sha256"],
      expected_bytes: row["expected_bytes"],
      observed_sha256: row["observed_sha256"],
      observed_bytes: row["observed_bytes"],
      validated_at: row["validated_at"],
      metadata: row["metadata"]
    }
  end

  defp invalid_cache_key(row, resolver, detail) do
    ArtifactError.exception(
      reason: :invalid_cache_key,
      collection_key: resolver.collection_key,
      logical_name: row["logical_name"],
      detail: detail
    )
  end

  # Names what the release does compose. A caller reaching this has a logical
  # name that is wrong or stale, and the list of real ones is what tells it
  # which.
  defp unknown_artifact(collection_key, logical_name, []) do
    ArtifactError.exception(
      reason: :unknown_artifact,
      collection_key: collection_key,
      logical_name: logical_name,
      detail: "the release composes no artifacts at all"
    )
  end

  defp unknown_artifact(collection_key, logical_name, artifacts) do
    ArtifactError.exception(
      reason: :unknown_artifact,
      collection_key: collection_key,
      logical_name: logical_name,
      detail: "it composes " <> Enum.map_join(artifacts, ", ", & &1.logical_name)
    )
  end

  defp not_cached(collection_key, %Artifact{} = artifact) do
    ArtifactError.exception(
      reason: :not_cached,
      collection_key: collection_key,
      logical_name: artifact.logical_name,
      cache_key: artifact.cache_key,
      path: artifact.path
    )
  end
end
