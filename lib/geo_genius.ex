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

  alias GeoGenius.{AreaMatch, Context, ReleaseArtifacts, SeededMatch, Store}

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

  @doc "Areas within a radius of a point, nearest first. Accepts `:limit`, `nil` for none."
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

  @doc "Areas ranked by name similarity. Accepts `:limit`, `nil` for none."
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
  Areas below each of these, one call instead of one call per key.

  Every row carries the seed it came from in `GeoGenius.SeededMatch`'s
  `:seed_key`, because a result mixes rows from every seed. A seed with no
  children contributes no row rather than an empty one, and the rows come back
  in the order the seeds were given. Takes the same options as
  `children_of/2`.

  Resolving a list this way collapses N round trips to one, which is the whole
  of what it saves: the SQL still runs the singular read once per seed, and
  the planner cannot push a predicate into a `SETOF` function either way. A
  caller that wants to join catalog areas against its own tables, or aggregate
  over them, wants `GeoGenius.Query`'s composable path instead of this.

      GeoGenius.children_of_many(county_keys)
      |> Enum.group_by(& &1.seed_key, & &1.match)
  """
  @spec children_of_many(Store.seeds(), keyword()) :: [SeededMatch.t()]
  def children_of_many(area_keys, opts \\ []) do
    context = Context.new(opts)
    context.store.children_of_many(context, area_keys, opts)
  end

  @doc """
  Areas above each of these, one call instead of one call per key. Seed
  attribution and options match `children_of_many/2`.
  """
  @spec ancestors_of_many(Store.seeds(), keyword()) :: [SeededMatch.t()]
  def ancestors_of_many(area_keys, opts \\ []) do
    context = Context.new(opts)
    context.store.ancestors_of_many(context, area_keys, opts)
  end

  @doc """
  Areas related to each of these in either direction, one call instead of one
  call per key. Seed attribution and options match `children_of_many/2`.
  """
  @spec related_areas_many(Store.seeds(), keyword()) :: [SeededMatch.t()]
  def related_areas_many(area_keys, opts \\ []) do
    context = Context.new(opts)
    context.store.related_areas_many(context, area_keys, opts)
  end

  @doc """
  Areas carrying any of these code values under one code type, one call
  instead of one call per value.

  The seed here is the code value, not an area key, so `:seed_key` holds the
  value that found each row. Options match `areas_by_code/3`, including
  `:parent_area_key` and `:parent_max_depth`, which apply to every value in
  the list.
  """
  @spec areas_by_code_many(String.t(), Store.seeds(), keyword()) :: [SeededMatch.t()]
  def areas_by_code_many(code_type, code_values, opts \\ []) do
    context = Context.new(opts)
    context.store.areas_by_code_many(context, code_type, code_values, opts)
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

  alias GeoGenius.{
    CandidateError,
    Catalog,
    CatalogError,
    Config,
    EnqueueError,
    ImportRun,
    Manifest,
    ManifestError,
    Registration
  }

  @default_stale_after_seconds 900
  @await_poll_interval 250
  @default_publish_timeout 900_000

  @doc """
  Atomically registers an exact release candidate, claims its import run, and
  enqueues it. Never runs the import itself -- `runner.enqueue/3` starts that,
  and `status/2` or `await/3` reads it back.

  `opts[:manifest]` is used as given; otherwise the manifest is loaded via
  `GeoGenius.Manifest.load/3` from `opts[:collection]` and `opts[:release]`
  (both required in that case). A completed unpublished candidate returns its
  existing run without enqueueing, while the owner of a live run may safely
  submit that same run to its runner again.

  Repeating an import whose latest attempt failed returns
  `{:error, %GeoGenius.CandidateError{reason: :failed}}` with that attempt's
  run id. It never creates a replacement implicitly; pass the failed run id
  to `retry_failed/2` to create the next attempt.

  `:owner` defaults to `to_string(node())`. Repeating the exact request under
  the same owner closes a post-commit enqueue gap by delivering the existing
  run again; the run's executor claim makes a duplicate delivery a no-op, not
  a takeover. A caller running two importers on one node passes `:owner`
  explicitly. `:stale_after_seconds` (default 900) is the window used to
  diagnose an abandoned run; staleness never transfers its executor or
  creates a retry. The value also travels through the runner's `args` so
  `GeoGenius.Pipeline` can derive its statement timeout from the original
  claim. `:publish` (default `false`) is forwarded the same way.

  Returns `{:error, exception}` -- never raises -- for a manifest that
  cannot be resolved (`GeoGenius.ManifestError`) or a catalog write that
  cannot be completed (`GeoGenius.CatalogError`). Expected candidate
  refusals, including a published release, return
  `GeoGenius.CandidateError` with a closed `:reason` and the conflicting
  release/run identifiers. A runner enqueue failure returns
  `GeoGenius.EnqueueError`, including the run id, backend, acceptance
  certainty, original reason, and safe status/redelivery guidance.
  """
  @spec import(keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def import(opts \\ []), do: request_import(:prepare, opts)

  @doc """
  Explicitly replaces a failed latest attempt with the supplied exact
  manifest and enqueues the newly claimed attempt.

  The manifest and runner options resolve exactly as they do for `import/1`.
  Candidate mismatches, protected releases, non-latest attempts, and runs that
  are not failed return a structured `GeoGenius.CandidateError` without
  enqueueing anything.
  """
  @spec retry_failed(Ecto.UUID.t(), keyword()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def retry_failed(failed_run_id, opts \\ []), do: request_import({:retry, failed_run_id}, opts)

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
  `{:error, :timeout}` once `timeout` elapses with neither. Polls the catalog
  every 250ms rather than monitoring a process: the run may be executing on
  another node entirely, and the durable row in PostgreSQL is the only thing
  both sides can see.

  `timeout` resolves in this order: the argument given here, then
  `config :geo_genius, :await_timeout`, then the library default of
  1,800,000ms (thirty minutes) -- comfortably past the ~17 minutes a full US
  SimpleMaps import takes, without blocking a caller that never says
  otherwise for the length of a genuinely hung run. `:infinity` is accepted
  at every level for a caller willing to wait as long as it takes.
  """
  @spec await(Ecto.UUID.t(), timeout() | nil, keyword()) ::
          {:ok, ImportRun.t()} | {:error, ImportRun.t()} | {:error, :timeout}
  def await(run_id, timeout \\ nil, opts \\ []) do
    context = Context.new(opts)
    poll_run(context, run_id, deadline_at(timeout || Config.await_timeout(opts)))
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

  @doc """
  Every artifact the collection's published release was built from, with where
  each one resolves to on this machine, ordered by logical name.

  `:release_id` reads a release other than the published one, which is how a
  host fills a projection for a release before it goes live. See
  `GeoGenius.ReleaseArtifacts` and `guides/projections.md`.
  """
  @spec release_artifacts(String.t(), keyword()) ::
          {:ok, [ReleaseArtifacts.Artifact.t()]} | {:error, GeoGenius.ArtifactError.t()}
  defdelegate release_artifacts(collection_key, opts \\ []), to: ReleaseArtifacts, as: :list

  @doc """
  The local file one artifact of a release resolves to.

  Returns `{:error, %GeoGenius.ArtifactError{reason: :not_cached}}` naming both
  the expected path and the cache key when nothing is there yet, rather than a
  path to a file that does not exist.
  """
  @spec artifact_path(String.t(), String.t(), keyword()) ::
          {:ok, Path.t()} | {:error, GeoGenius.ArtifactError.t()}
  defdelegate artifact_path(collection_key, logical_name, opts \\ []),
    to: ReleaseArtifacts,
    as: :path

  defp resolve_manifest(opts) do
    case Keyword.get(opts, :manifest) do
      %Manifest{} = manifest ->
        {:ok, manifest}

      nil ->
        Manifest.load(Keyword.fetch!(opts, :collection), Keyword.fetch!(opts, :release), opts)
    end
  end

  defp request_import(operation, opts) do
    context = Context.new(opts)

    case resolve_manifest(opts) do
      {:ok, manifest} -> start_import(context, manifest, operation, opts)
      {:error, %ManifestError{}} = error -> error
    end
  rescue
    error in [ManifestError, CatalogError] -> {:error, error}
  end

  defp start_import(context, %Manifest{} = manifest, operation, opts) do
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, @default_stale_after_seconds)
    owner = Keyword.get(opts, :owner, to_string(node()))
    runner = Context.adapter(context, :runner)

    claim = %{
      owner: owner,
      runner_backend: runner.name(),
      stale_after_seconds: stale_after_seconds
    }

    args = %{
      publish: Keyword.get(opts, :publish, false),
      stale_after_seconds: stale_after_seconds
    }

    operation
    |> register_import(context, manifest, claim)
    |> finish_import_request(context, opts, runner, manifest, args)
  end

  defp register_import(:prepare, context, manifest, claim) do
    Registration.prepare_import(context, manifest, claim)
  end

  defp register_import({:retry, failed_run_id}, context, manifest, claim) do
    Registration.retry_failed(context, failed_run_id, manifest, claim)
  end

  defp finish_import_request(
         {:error, %CandidateError{}} = error,
         _context,
         _opts,
         _runner,
         _manifest,
         _args
       ),
       do: error

  defp finish_import_request(
         {:existing, %{run_id: run_id}},
         _context,
         _opts,
         _runner,
         _manifest,
         _args
       ),
       do: {:ok, run_id}

  defp finish_import_request(
         {:enqueue, decision},
         context,
         opts,
         runner,
         manifest,
         args
       ) do
    case enqueue(runner, context, decision.run_id, args) do
      :ok ->
        notify(context, opts, :import_started, %{
          run_id: decision.run_id,
          release_id: decision.release_id,
          collection_key: manifest.collection,
          release_key: manifest.release
        })

        {:ok, decision.run_id}

      {:error, {certainty, reason}}
      when certainty in [:not_enqueued, :outcome_unknown] ->
        enqueue_failed(context, decision, runner, certainty, reason)

      {:error, reason} ->
        enqueue_failed(context, decision, runner, :not_enqueued, reason)

      other ->
        enqueue_failed(
          context,
          decision,
          runner,
          :outcome_unknown,
          {:invalid_enqueue_result, other}
        )
    end
  end

  defp enqueue(runner, context, run_id, args) do
    runner.enqueue(context, run_id, args)
  rescue
    exception -> {:error, {:outcome_unknown, exception}}
  catch
    kind, reason when kind in [:exit, :throw] ->
      {:error, {:outcome_unknown, {kind, reason}}}
  end

  defp enqueue_failed(context, decision, runner, :not_enqueued, reason) do
    enqueue_error(
      decision,
      runner,
      :not_enqueued,
      reason,
      terminalize_enqueue_failure(context, decision, runner, reason)
    )
  end

  defp enqueue_failed(_context, decision, runner, certainty, reason) do
    enqueue_error(decision, runner, certainty, reason, :not_applicable)
  end

  defp enqueue_error(decision, runner, certainty, reason, terminalization) do
    {:error,
     EnqueueError.exception(
       run_id: decision.run_id,
       runner_backend: runner.name(),
       certainty: certainty,
       lifecycle: decision.reason,
       reason: reason,
       terminalization: terminalization
     )}
  end

  defp terminalize_enqueue_failure(context, decision, runner, reason)
       when decision.reason in [:registered, :retried] do
    executor_id = Ecto.UUID.generate()

    detail = %{
      "reason" => "runner_enqueue_failed",
      "runner_backend" => runner.name(),
      "detail" => inspect(reason)
    }

    with {:error, first} <- record_enqueue_failure(context, decision.run_id, executor_id, detail),
         {:error, second} <- record_enqueue_failure(context, decision.run_id, executor_id, detail) do
      {:not_recorded, {first, second}}
    else
      :ok -> :recorded_failed
    end
  end

  defp terminalize_enqueue_failure(_context, _decision, _runner, _reason), do: :not_applicable

  defp record_enqueue_failure(context, run_id, executor_id, detail) do
    Catalog.fail_import(context, run_id, executor_id, detail)
    :ok
  rescue
    exception -> {:error, exception}
  catch
    kind, caught_reason -> {:error, {kind, caught_reason}}
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
    error in [CatalogError] -> recover_publish(context, release_id, error)
  end

  defp recover_publish(context, release_id, error) do
    confirm_published(
      context,
      Catalog.release_collection_key(context, release_id),
      release_id,
      error
    )
  rescue
    _exception -> {:error, {:outcome_unknown, error}}
  end

  defp confirm_published(_context, nil, _release_id, error), do: {:error, error}

  defp confirm_published(context, collection_key, release_id, error) do
    case Catalog.published_release(context, collection_key) do
      ^release_id -> :ok
      _other -> {:error, error}
    end
  end

  defp publish_timeout(opts), do: Keyword.get(opts, :timeout, @default_publish_timeout)

  # The rollback's own guard, held to the one call that moves the publication.
  defp rollback_publication(context, collection_key) do
    expected = snapshot_published(context, collection_key)

    case do_rollback_publication(context, collection_key) do
      {:ok, collection_id} ->
        {:ok, collection_id}

      {:error, exception} ->
        recover_rollback(context, collection_key, expected, exception)
    end
  end

  defp snapshot_published(context, collection_key) do
    {:ok, Catalog.published_release(context, collection_key)}
  rescue
    _exception -> :unread
  end

  defp do_rollback_publication(context, collection_key) do
    {:ok, Catalog.rollback_publication(context, collection_key)}
  rescue
    error in [CatalogError] -> {:error, error}
  end

  defp recover_rollback(_context, _collection_key, :unread, exception), do: {:error, exception}

  defp recover_rollback(context, collection_key, {:ok, expected}, exception) do
    case Catalog.published_release(context, collection_key) do
      ^expected -> {:error, exception}
      _other -> {:error, {:outcome_unknown, exception}}
    end
  rescue
    _read_error -> {:error, {:outcome_unknown, exception}}
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
    Catalog.release_collection_key(context, release_id)
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
