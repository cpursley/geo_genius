defmodule GeoGenius do
  @moduledoc """
  A versioned catalog of named geographic areas for Elixir and
  PostgreSQL/PostGIS applications.
  """

  require Logger

  @doc """
  Verifies that the database satisfies GeoGenius's prerequisites.

  Returns `:ok`, or `{:error, reasons}` naming every unmet prerequisite.
  """
  @spec verify(module(), keyword()) :: :ok | {:error, [String.t()]}
  def verify(repo, opts \\ []), do: GeoGenius.Preflight.run(repo, opts)

  @doc """
  Verifies prerequisites and raises `GeoGenius.PreflightError` when any are unmet.
  """
  @spec verify!(module(), keyword()) :: :ok
  def verify!(repo, opts \\ []) do
    case verify(repo, opts) do
      :ok -> :ok
      {:error, reasons} -> raise GeoGenius.PreflightError, reasons: reasons
    end
  end

  alias GeoGenius.{AreaMatch, Context, Store}

  @doc """
  Areas whose boundary covers a point.

  Longitude first. Coordinates may be floats, integers, or the `%Decimal{}`
  a `numeric` column loads as. Options: `:collections`, `:types`,
  `:release_id`, `:include_retired`, plus `:repo` and `:prefix`.
  """
  @spec areas_for_point(Store.numeric(), Store.numeric(), keyword()) :: [AreaMatch.t()]
  def areas_for_point(lon, lat, opts \\ []) do
    context = Context.new(opts)
    context.store.areas_for_point(context, lon, lat, opts)
  end

  @doc "Areas overlapping a geometry, with the measured overlap of each."
  @spec areas_for_geometry(Geo.geometry(), keyword()) :: [AreaMatch.t()]
  def areas_for_geometry(geometry, opts \\ []) do
    context = Context.new(opts)
    context.store.areas_for_geometry(context, geometry, opts)
  end

  @doc "Areas within a radius of a point, nearest first. Accepts `:limit`."
  @spec areas_near(Store.numeric(), Store.numeric(), Store.numeric(), keyword()) ::
          [AreaMatch.t()]
  def areas_near(lon, lat, radius_m, opts \\ []) do
    context = Context.new(opts)
    context.store.areas_near(context, lon, lat, radius_m, opts)
  end

  @doc """
  Areas carrying a code.

  A code is unique only within a parent, so `:parent_area_key` scopes the
  lookup and `:parent_max_depth` controls how far down it reaches. Always
  returns a list: several areas can legitimately share one code.
  """
  @spec areas_by_code(String.t(), String.t(), keyword()) :: [AreaMatch.t()]
  def areas_by_code(code_type, code_value, opts \\ []) do
    context = Context.new(opts)
    context.store.areas_by_code(context, code_type, code_value, opts)
  end

  @doc "Areas ranked by name similarity. Accepts `:limit`."
  @spec search_areas(String.t(), keyword()) :: [AreaMatch.t()]
  def search_areas(query, opts \\ []) do
    context = Context.new(opts)
    context.store.search_areas(context, query, opts)
  end

  @doc """
  Resolves a mixed input through the cascade, returning the first strategy that
  matched.

  `input` carries whatever the caller holds: `lon` and `lat` together,
  `code_type` and `code_value` together, `name`, and `radius_m` for the
  proximity strategy. `parent_area_key` is not a signal of its own. It scopes
  the code and name strategies to one area's descendants; containment and
  proximity ignore it, holding a coordinate already.

  Accepts `:strategies` to constrain or reorder the cascade.
  """
  @spec resolve(map(), keyword()) :: [AreaMatch.t()]
  def resolve(input, opts \\ []) do
    context = Context.new(opts)
    context.store.resolve(context, input, opts)
  end

  @doc "Areas below this one. Accepts `:classifications` and `:max_depth`."
  @spec children_of(String.t(), keyword()) :: [AreaMatch.t()]
  def children_of(area_key, opts \\ []) do
    context = Context.new(opts)
    context.store.children_of(context, area_key, opts)
  end

  @doc "Areas above this one. Accepts `:classifications` and `:max_depth`."
  @spec ancestors_of(String.t(), keyword()) :: [AreaMatch.t()]
  def ancestors_of(area_key, opts \\ []) do
    context = Context.new(opts)
    context.store.ancestors_of(context, area_key, opts)
  end

  @doc "Areas related to this one in either direction, one level out."
  @spec related_areas(String.t(), keyword()) :: [AreaMatch.t()]
  def related_areas(area_key, opts \\ []) do
    context = Context.new(opts)
    context.store.related_areas(context, area_key, opts)
  end

  @doc """
  The release a collection had published at a moment, or nil if it had
  published nothing yet. Requires `:collection`.

  Reads take a release id rather than a timestamp, so this is how a caller
  holding a timestamp gets an argument for `:release_id`.
  """
  @spec release_at(DateTime.t(), keyword()) :: Ecto.UUID.t() | nil
  def release_at(as_of, opts \\ []) do
    context = Context.new(opts)
    context.store.release_at(context, as_of, opts)
  end

  alias GeoGenius.{Catalog, CatalogError, ImportRun, Manifest, ManifestError, Registration}

  @default_stale_after_seconds 900
  @default_await_timeout 300_000
  @await_poll_interval 250
  @default_publish_timeout 900_000

  @doc """
  Registers a release from its manifest, claims an import run, and enqueues
  it. Never runs the import itself -- `runner.enqueue/3` starts that, and
  `status/2` or `await/3` reads it back.

  `opts[:manifest]` is used as given; otherwise the manifest is loaded via
  `GeoGenius.Manifest.load/3` from `opts[:collection]` and `opts[:release]`
  (both required in that case). Registering the collection, its authorities,
  area types, source, source release, artifacts, and release-source link is
  idempotent, so importing the same release twice re-registers the same rows
  rather than duplicating them.

  `:owner` defaults to `to_string(node())`, so a worker restarting on the
  same node resumes its own run instead of colliding with it or waiting out
  its lease. A caller running two importers on one node passes `:owner`
  explicitly. `:stale_after_seconds` (default 900) is the window
  `GeoGenius.Catalog.begin_or_resume_import/3` claims the run under; it also
  travels through the runner's `args` so `GeoGenius.Pipeline` can derive its
  own statement timeout from the window the run was actually claimed under,
  rather than a value that merely resembles it. `:publish` (default `false`)
  is forwarded the same way.

  Returns `{:error, exception}` -- never raises -- for a manifest that
  cannot be resolved (`GeoGenius.ManifestError`) or a catalog write that
  cannot be completed (`GeoGenius.CatalogError`), including a release that is
  already published: `open_release` raises with a hint naming the fix
  (import under a new release key), and that hint is part of the message.
  """
  @spec import(keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def import(opts \\ []) do
    context = Context.new(opts)

    case resolve_manifest(opts) do
      {:ok, manifest} -> start_import(context, manifest, opts)
      {:error, %ManifestError{}} = error -> error
    end
  rescue
    error in [ManifestError, CatalogError] -> {:error, error}
  end

  @doc "One import run, or nil when no run carries that id."
  @spec status(Ecto.UUID.t(), keyword()) :: ImportRun.t() | nil
  def status(run_id, opts \\ []) do
    context = Context.new(opts)
    Catalog.import_run(context, run_id)
  end

  @doc """
  Polls the catalog for a run's outcome, in the calling process.

  Returns `{:ok, run}` once `GeoGenius.ImportRun.finished?/1` is true and the
  run succeeded, `{:error, run}` once it finished and failed, and
  `{:error, :timeout}` once `timeout` (default 300,000ms) elapses with
  neither. Polls the catalog every 250ms rather than monitoring a process:
  the run may be executing on another node entirely, and the durable row in
  PostgreSQL is the only thing both sides can see.
  """
  @spec await(Ecto.UUID.t(), timeout(), keyword()) ::
          {:ok, ImportRun.t()} | {:error, ImportRun.t()} | {:error, :timeout}
  def await(run_id, timeout \\ @default_await_timeout, opts \\ []) do
    context = Context.new(opts)
    poll_run(context, run_id, deadline_at(timeout))
  end

  @doc """
  Publishes a verified release, returning its id.

  The SQL `publish_release` re-runs the release's verification inside the
  publication, so this is one of the library's long single statements.
  `:timeout` bounds it, in milliseconds, and defaults to 900,000 -- the window
  `GeoGenius.Pipeline` gives the same statement in its verifying phase --
  rather than DBConnection's fifteen-second default, which a national release
  exceeds by orders of magnitude.

  Returns `{:error, exception}` -- never raises -- when the release fails
  verification or the catalog write cannot be completed.

  Only the publication is guarded. The collection key travelling in the
  `:release_published` payload is read back after the publication has already
  committed, and a read that fails there costs the payload its
  `:collection_key`, never the outcome: a publication that committed is
  reported as `{:ok, release_id}` and the event still fires.
  """
  @spec publish(Ecto.UUID.t(), keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def publish(release_id, opts \\ []) do
    context = Context.new(opts)

    case publish_release(context, release_id, opts) do
      :ok ->
        notify(context, opts, :release_published, %{
          release_id: release_id,
          collection_key: release_collection_key(context, release_id)
        })

        {:ok, release_id}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @doc """
  Rolls a collection's publication back to its previous release, returning
  that release's id.

  Returns `{:error, exception}` -- never raises, and never clears the
  publication -- for a collection with no previous release to roll back to,
  and `{:error, String.t()}` for a collection key the catalog does not carry.

  Only the rollback is guarded. The release the collection now publishes is
  read back afterwards, and a read that fails there returns
  `{:error, {:unread, message}}`, a shape distinct from every failure shape
  above: the publication moved whether or not the id can be read, so a caller
  matching this clause knows the rollback happened and must not retry it. The
  message says the same thing in words. `GeoGenius.Pipeline` uses
  `{:error, {:unrecorded, message}}` for its own committed-but-unread outcome;
  this is that pattern at the public API. The `:release_rolled_back` event
  fires either way, carrying a `nil` `:release_id` when the read failed.
  """
  @spec rollback(String.t(), keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def rollback(collection_key, opts \\ []) do
    context = Context.new(opts)

    case rollback_publication(context, collection_key) do
      {:ok, nil} ->
        {:error, "GeoGenius rollback: collection #{inspect(collection_key)} does not exist"}

      {:ok, _collection_id} ->
        rolled_back(context, opts, collection_key)

      {:error, exception} ->
        {:error, exception}
    end
  end

  @doc "The currently published release for a collection, or nil if none is published."
  @spec published_release(String.t(), keyword()) :: Ecto.UUID.t() | nil
  def published_release(collection_key, opts \\ []) do
    context = Context.new(opts)
    Catalog.published_release(context, collection_key)
  end

  defp resolve_manifest(opts) do
    case Keyword.get(opts, :manifest) do
      %Manifest{} = manifest ->
        {:ok, manifest}

      nil ->
        Manifest.load(Keyword.fetch!(opts, :collection), Keyword.fetch!(opts, :release), opts)
    end
  end

  defp start_import(context, %Manifest{} = manifest, opts) do
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, @default_stale_after_seconds)
    owner = Keyword.get(opts, :owner, to_string(node()))
    runner = Context.adapter(context, :runner)
    release_id = Registration.register(context, manifest)

    run_id =
      Catalog.begin_or_resume_import(context, release_id, %{
        owner: owner,
        runner_backend: runner.name(),
        stale_after_seconds: stale_after_seconds
      })

    args = %{
      publish: Keyword.get(opts, :publish, false),
      stale_after_seconds: stale_after_seconds
    }

    enqueue_import(context, opts, runner, run_id, release_id, manifest, args)
  end

  defp enqueue_import(context, opts, runner, run_id, release_id, manifest, args) do
    case runner.enqueue(context, run_id, args) do
      :ok ->
        notify(context, opts, :import_started, %{
          run_id: run_id,
          release_id: release_id,
          collection_key: manifest.collection,
          release_key: manifest.release
        })

        {:ok, run_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `timeout()` permits `:infinity`, the natural call from a mix task or a
  # CLI import that is willing to wait as long as it takes -- `deadline_at/1`
  # keeps that out of the arithmetic below rather than adding `:infinity` to
  # an integer, which raises `ArithmeticError`.
  defp deadline_at(:infinity), do: :infinity
  defp deadline_at(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp poll_run(context, run_id, deadline) do
    run = Catalog.import_run(context, run_id)

    if run && ImportRun.finished?(run) do
      run_outcome(run)
    else
      continue_await(context, run_id, deadline)
    end
  end

  defp run_outcome(%ImportRun{} = run) do
    if ImportRun.succeeded?(run), do: {:ok, run}, else: {:error, run}
  end

  defp continue_await(context, run_id, :infinity) do
    Process.sleep(@await_poll_interval)
    poll_run(context, run_id, :infinity)
  end

  defp continue_await(context, run_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      Process.sleep(min(@await_poll_interval, remaining))
      poll_run(context, run_id, deadline)
    end
  end

  # Only the publication is guarded, and deliberately only the publication: it
  # is the call that decides whether the release became visible. A confirmation
  # read left inside this rescue would report a publication that committed as a
  # failure, which is the shape `GeoGenius.Pipeline.complete/1` already avoids.
  defp publish_release(context, release_id, opts) do
    Catalog.publish_release(context, release_id, timeout: publish_timeout(opts))
    :ok
  rescue
    error in [CatalogError] -> {:error, error}
  end

  defp publish_timeout(opts), do: Keyword.get(opts, :timeout, @default_publish_timeout)

  # The rollback's own guard, held to the one call that moves the publication.
  defp rollback_publication(context, collection_key) do
    {:ok, Catalog.rollback_publication(context, collection_key)}
  rescue
    error in [CatalogError] -> {:error, error}
  end

  # By the time this reads, the publication has moved in PostgreSQL. The read
  # is how the caller learns which release it moved to, so a read that fails
  # costs the caller that id -- never the fact that the rollback happened,
  # which both the message and the event carry.
  defp rolled_back(context, opts, collection_key) do
    case published_after_rollback(context, collection_key) do
      {:ok, release_id} ->
        notify(context, opts, :release_rolled_back, %{
          collection_key: collection_key,
          release_id: release_id
        })

        {:ok, release_id}

      {:error, reason} ->
        notify(context, opts, :release_rolled_back, %{
          collection_key: collection_key,
          release_id: nil
        })

        {:error, {:unread, unread_rollback(collection_key, reason)}}
    end
  end

  defp published_after_rollback(context, collection_key) do
    {:ok, Catalog.published_release(context, collection_key)}
  rescue
    error in [CatalogError] -> {:error, Exception.message(error)}
  end

  defp unread_rollback(collection_key, reason) do
    "GeoGenius rolled collection #{inspect(collection_key)} back, but reading the release " <>
      "it now publishes failed: #{reason}"
  end

  # A post-success confirmation read, for the notification payload alone. The
  # publication has already committed, so a failure here yields a `nil`
  # collection key and a warning rather than an error the caller would read as
  # a publication that did not happen.
  defp release_collection_key(context, release_id) do
    case Catalog.release_manifest(context, release_id) do
      %{"collection" => collection_key} -> collection_key
      _not_found -> nil
    end
  rescue
    error in [CatalogError] ->
      Logger.warning(
        "GeoGenius published release #{release_id}, but reading its collection key failed: " <>
          Exception.message(error)
      )

      nil
  end

  # A notifier is called for side effects only and must not be able to fail a
  # registration or a publication that otherwise succeeded, mirroring
  # `GeoGenius.Pipeline`'s own wrapped `notify/3`.
  defp notify(context, opts, event, payload) do
    notifier = Context.adapter(context, :notifier)
    notifier.notify(event, payload, opts)
    :ok
  rescue
    exception -> dropped(event, Exception.message(exception))
  catch
    kind, reason -> dropped(event, "#{kind} #{inspect(reason)}")
  end

  defp dropped(event, reason) do
    Logger.warning("GeoGenius dropped the #{event} notification: #{reason}")
    :ok
  end
end
