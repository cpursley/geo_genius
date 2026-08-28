defmodule GeoGenius.QueryError do
  @moduledoc """
  Raised when a reading call through `GeoGenius.Store` cannot be completed.

  The boundary is the module, not the direction of the call:
  `GeoGenius.Catalog` raises `GeoGenius.CatalogError` for its own reads as
  well as its writes, so a host matching on this catches the query layer's
  failures and not the ingestion side's.

  Carries the SQL function that was called, so a failure names the read that
  produced it rather than surfacing as a bare database error.
  """

  defexception [:message, :function, :reason]

  @type t :: %__MODULE__{message: String.t(), function: String.t(), reason: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    function = Keyword.fetch!(opts, :function)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      function: function,
      reason: reason,
      message: "GeoGenius read #{function} failed: #{inspect(reason)}"
    }
  end
end

defmodule GeoGenius.CatalogError do
  @moduledoc """
  Raised when a `GeoGenius.Catalog` call cannot be completed.

  Every call that module makes raises this, its reads -- `release_manifest/2`,
  `release_artifacts/2`, `published_release/2` -- included;
  `GeoGenius.QueryError` covers the reading calls that go through
  `GeoGenius.Store`.

  Carries the SQL function that was called and the original driver error as
  `:reason`, so a caller can match a constraint violation the operator caused
  against a connection failure it cannot fix.
  """

  defexception [:message, :function, :reason]

  @type t :: %__MODULE__{message: String.t(), function: String.t(), reason: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    function = Keyword.fetch!(opts, :function)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      function: function,
      reason: reason,
      message: "GeoGenius catalog call #{function} failed: #{inspect(reason)}"
    }
  end
end

defmodule GeoGenius.ManifestError do
  @moduledoc """
  Raised when a manifest cannot be read, decoded, or validated.

  A manifest is a reviewed artifact, so every failure names the field that was
  wrong rather than reporting that the document as a whole was rejected.
  """

  defexception [:message, :path, :reason]

  @type t :: %__MODULE__{message: String.t(), path: String.t() | nil, reason: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    path = Keyword.get(opts, :path)
    located = if path, do: " in #{path}", else: ""

    %__MODULE__{path: path, reason: reason, message: "GeoGenius manifest#{located}: #{reason}"}
  end
end

defmodule GeoGenius.ImportError do
  @moduledoc """
  Raised when an import run cannot continue.

  Carries the run and the phase it failed in. The run's own `error` column in
  PostgreSQL is the durable record; this exception is how the failure reaches a
  caller that is waiting synchronously.
  """

  defexception [:message, :run_id, :phase, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          run_id: Ecto.UUID.t() | nil,
          phase: String.t() | nil,
          reason: term()
        }

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    run_id = Keyword.get(opts, :run_id)
    phase = Keyword.get(opts, :phase)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      run_id: run_id,
      phase: phase,
      reason: reason,
      message: "GeoGenius import #{run_id} failed during #{phase}: #{inspect(reason)}"
    }
  end
end

defmodule GeoGenius.StagingError do
  @moduledoc """
  Raised when a staging table cannot be written to or read from.

  Carries the operation that was attempted (`"insert"`, `"stream"`, or
  `"count"`) and the original driver error as `:reason`, since staging issues
  raw SQL rather than calling a catalog function.
  """

  defexception [:message, :operation, :reason]

  @type t :: %__MODULE__{message: String.t(), operation: String.t(), reason: term()}

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    operation = Keyword.fetch!(opts, :operation)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      operation: operation,
      reason: reason,
      message: "GeoGenius staging #{operation} failed: #{inspect(reason)}"
    }
  end
end

defmodule GeoGenius.ArtifactError do
  @moduledoc """
  Raised when a release's artifacts cannot be listed, or one of them cannot be
  resolved to a file on this machine.

  Carries `:reason` -- `:no_published_release`, `:unknown_release`,
  `:foreign_release`, `:unknown_artifact`, `:invalid_cache_key`, or
  `:not_cached` -- so a caller can tell an artifact nobody has placed in the
  cache yet, which an operator fixes by placing it, from a logical name this
  release never composed, which is a caller's own mistake. `:not_cached`
  carries the `:cache_key` the artifact resolves under and the `:path` it was
  expected at, because those two values are the whole remedy: a `File.Error`
  from inside a stream names neither.

  `:unknown_release` and `:foreign_release` are separate reasons because they
  are separate host defects. The first is an id that has gone stale; the second
  is an id that was never this collection's, which reads another collection's
  artifacts under this one's name if nothing refuses it.
  """

  defexception [
    :message,
    :reason,
    :collection_key,
    :release_id,
    :logical_name,
    :cache_key,
    :path,
    :detail
  ]

  @type reason ::
          :no_published_release
          | :unknown_release
          | :foreign_release
          | :unknown_artifact
          | :invalid_cache_key
          | :not_cached

  @type t :: %__MODULE__{
          message: String.t(),
          reason: reason(),
          collection_key: String.t() | nil,
          release_id: String.t() | nil,
          logical_name: String.t() | nil,
          cache_key: String.t() | nil,
          path: Path.t() | nil,
          detail: String.t() | nil
        }

  @impl Exception
  @spec exception(keyword()) :: t()
  def exception(opts) do
    error = %__MODULE__{
      reason: Keyword.fetch!(opts, :reason),
      collection_key: Keyword.get(opts, :collection_key),
      release_id: Keyword.get(opts, :release_id),
      logical_name: Keyword.get(opts, :logical_name),
      cache_key: Keyword.get(opts, :cache_key),
      path: Keyword.get(opts, :path),
      detail: Keyword.get(opts, :detail)
    }

    %{error | message: describe(error)}
  end

  defp describe(%__MODULE__{reason: :no_published_release} = error) do
    "GeoGenius collection #{inspect(error.collection_key)} publishes no release; publish one, " <>
      "or name the release to read with :release_id"
  end

  defp describe(%__MODULE__{reason: :unknown_release} = error) do
    "GeoGenius has no release #{inspect(error.release_id)} to read for collection " <>
      "#{inspect(error.collection_key)}; the id is unknown, or the release has been removed"
  end

  defp describe(%__MODULE__{reason: :foreign_release} = error) do
    "GeoGenius release #{inspect(error.release_id)} is not a release of collection " <>
      "#{inspect(error.collection_key)}#{detail(error)}"
  end

  defp describe(%__MODULE__{reason: :unknown_artifact} = error) do
    "GeoGenius collection #{inspect(error.collection_key)} composes no artifact named " <>
      "#{inspect(error.logical_name)} in this release#{detail(error)}"
  end

  defp describe(%__MODULE__{reason: :invalid_cache_key} = error) do
    "GeoGenius artifact #{inspect(error.logical_name)} has no usable cache key#{detail(error)}"
  end

  defp describe(%__MODULE__{reason: :not_cached} = error) do
    "GeoGenius artifact #{inspect(error.logical_name)} is not on this machine: expected it at " <>
      "#{error.path}, under cache key #{error.cache_key}. Place the file there, or run the " <>
      "import again to fetch it."
  end

  defp detail(%__MODULE__{detail: nil}), do: ""
  defp detail(%__MODULE__{detail: detail}), do: "; #{detail}"
end
