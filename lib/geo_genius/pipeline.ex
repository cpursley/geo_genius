defmodule GeoGenius.Pipeline do
  @moduledoc """
  Turns a claimed import run into a verified release.

  `execute/3` receives a run id `GeoGenius.import/1` already obtained from
  `begin_or_resume_import`, reads what it needs out of PostgreSQL, and walks
  the run through its phases: download every artifact, check each required one
  arrived, stage them through the manifest's provider, normalize the staged
  rows into the catalog, rebuild relations and write every edge the provider
  asserts, analyze, and verify. It never claims a run and never opens a
  release; both belong to the caller that registered the manifest.

  The phases themselves live next door where they have room:
  `GeoGenius.Pipeline.Artifacts` owns everything that touches the cache, the
  downloader, and checksums; `GeoGenius.Pipeline.Normalize` owns everything
  that knows `GeoGenius.Provider.Area`; `GeoGenius.Pipeline.Relate` owns
  rebuilding measured relations and writing asserted edges. This module owns
  the driver, the failure path, staging, and the two remaining one-line
  phases, indexing and verifying.

  ## What an import does not do

  **It does not publish.** An import produces a verified candidate; making it
  visible is a separate, explicit act, which is why `mix geo_genius.publish`
  exists as its own task. `publish: true` is the convenience for a caller that
  wants both in one call.

  **It does not open a transaction.** Every catalog function is atomic as a
  single statement, and the state machine is deliberately resumable: wrapping
  the run would roll back the very progress `begin_or_resume_import` resumes
  from, and would hold one connection for the length of the slowest phase.

  ## Staging is emptied before it is written and dropped after

  Every phase runs on every attempt, a resumed run included, so the staging
  phase re-parses the artifact it staged before rather than reading what is
  already there. It therefore starts from an empty table for the run --
  `GeoGenius.Staging.reset/2` -- so an attempt that died where the cleanup
  below could not run does not leave its rows to be staged a second time
  beside the new ones, or to be normalized from a source that has since
  changed.

  The staging table is dropped in an `after`, on success and on failure alike.
  Keeping it would only help a retry that reuses the same `run_id`, which
  happens solely when the same owner resumes inside the lease's staleness
  window; every other retry is a new attempt with a new run and a new table
  name, so a kept table is a leak that `v01_down.sql`'s teardown check would
  later refuse to drop through. What actually makes a retry cheap is the
  artifact cache, which skips the network -- the expensive part. Re-parsing a
  local file is not worth leaking a table per failure. A drop that fails is
  logged at warning and the table left behind, because the alternative --
  letting cleanup raise -- would replace the run's own outcome with it.

  ## The failure path survives its own failures

  A phase that returns `{:error, reason}`, raises, exits, or throws all reach
  `fail_import/3` the same way, and the stored `error` column is the durable
  record of what happened. Everything after that point is written so it cannot
  destroy that record: cleanup cannot replace the return value, and the re-read
  that turns a recorded failure into a `%GeoGenius.ImportRun{}` cannot either.
  A caller that gets `{:error, {:unrecorded, reason}}` is being told the run's
  own row could not be read or written -- that, and only that, is when the
  reason arrives as a string instead of a run.

  ## A notifier cannot fail an import

  Every `notify/3` call is wrapped, so a notifier that raises, exits, or
  returns garbage is logged at warning level and dropped, and the phase
  continues. A host's event delivery is a side channel; letting it abort a
  two-hour import would be a worse contract than losing an event.

  `:phase_advanced` for a phase carries the metrics of the phase *before* it:
  a phase's own metrics are not known until it finishes, and they are written
  onto the run by the next `advance_import`. The metrics of the last phase
  arrive with `:import_completed`.

  ## What a provider is handed

  `stage/5` receives `opts[:work_dir]`, one directory resolved per run and
  removed when the run ends, and `opts[:command]`, the configured command
  adapter wrapped by `GeoGenius.Pipeline.CommandAllowlist` so a provider that
  reaches for something other than `ogr2ogr` is refused.

  ## Options

    * `:publish` -- publish the release after it verifies. Defaults to `false`.
    * `:batch_size` -- staged rows read and normalized or asserted per round
      trip, and the relate phase's heartbeat cadence. Defaults to 500.
    * `:work_dir` -- the directory the run's own working directory is created
      beneath. Defaults to the system temporary directory.
    * `:stale_after_seconds` -- the staleness window this run was claimed
      under (`GeoGenius.Catalog.begin_or_resume_import/3`'s own
      `:stale_after_seconds`, carried here through `GeoGenius.import/1` and a
      runner's `args`). Defaults to 900, matching that function's own default.
    * `:timeout` -- milliseconds allowed for each of the long single
      statements: a staging insert, the relation rebuild, the analyze, the
      verification, and the publication, which re-runs that same verification
      inside itself. Defaults to `:stale_after_seconds` converted to
      milliseconds, so an explicit `:timeout` here is only needed to diverge
      from the window the run was actually claimed under.

  Every other option is passed through to the cache, downloader, command, and
  notifier adapters untouched.

  ### What `:timeout` bounds

  DBConnection's default is fifteen seconds, which a national relation rebuild
  or the verification a publication re-runs exceeds by orders of magnitude; without an option here a host's only recourse
  is raising `:timeout` on its own Repo, for every query it runs. `:timeout`
  now derives from `:stale_after_seconds`, the same window
  `begin_or_resume_import/3` claimed the run under, rather than a value that
  merely resembled it: `GeoGenius.import/1` knows the window it claimed with
  and carries it through a runner's `args` to `execute/3`, so a caller that
  claims with a shorter window gets a shorter statement timeout to match,
  instead of a timeout longer than its own lease.

  The statement is narrow: a statement that runs past `:timeout` fails and is
  recorded as a failure, rather than running on indefinitely while another
  worker reclaims the lease and writes the same release. It is not a
  guarantee that the statement finishes inside the lease -- at the defaults,
  `advance_import` renews the lease immediately before the statement and the
  statement times out at roughly the moment the lease becomes reclaimable.
  """

  require Logger

  alias GeoGenius.Catalog
  alias GeoGenius.Config
  alias GeoGenius.Context
  alias GeoGenius.ImportRun
  alias GeoGenius.Manifest
  alias GeoGenius.Pipeline.Artifacts
  alias GeoGenius.Pipeline.CommandAllowlist
  alias GeoGenius.Pipeline.Normalize
  alias GeoGenius.Pipeline.Relate
  alias GeoGenius.Pipeline.State
  alias GeoGenius.Staging
  alias GeoGenius.Telemetry

  @default_batch_size 500
  @default_stale_after_seconds 900
  @milliseconds_per_second 1_000
  @stacktrace_frames 20
  @counter_index 1

  @doc """
  Runs a claimed import to completion, returning the run as PostgreSQL
  recorded it.

  Returns `{:error, run}` for a run that failed, with the run re-read so the
  caller sees the stored error. Returns `{:error, {:unrecorded, reason}}` only
  when there is no such record to return: a run id the catalog does not carry,
  a `fail_import/3` that failed itself, or a re-read that could not be
  completed.
  """
  @spec execute(Context.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ImportRun.t()} | {:error, ImportRun.t()} | {:error, {:unrecorded, String.t()}}
  def execute(%Context{} = context, run_id, opts \\ []) do
    case Catalog.import_run(context, run_id) do
      nil -> {:error, {:unrecorded, "GeoGenius import run #{run_id} does not exist"}}
      %ImportRun{} = run -> run_import(context, run, opts)
    end
  end

  # The run's own directory is created beneath whatever `:work_dir` names,
  # never used directly, so a caller that points several runs at one directory
  # -- or at a directory holding something else -- keeps everything but this
  # run's own files when the run ends.
  defp run_import(context, run, opts) do
    work_dir = Path.join(base_work_dir(opts), "run_" <> String.replace(run.run_id, "-", ""))
    File.mkdir_p!(work_dir)

    state = %State{
      context: context,
      run: run,
      opts: opts,
      work_dir: work_dir,
      publish?: Keyword.get(opts, :publish, false),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      timeout: Keyword.get_lazy(opts, :timeout, fn -> derived_timeout(opts) end)
    }

    try do
      load_and_run(state)
    after
      cleanup(context, run.run_id, work_dir)
    end
  end

  # An exception raised inside an `after` block replaces the value of the whole
  # `try`, so a failing cleanup here would throw away the `{:error, run}` that
  # was just built around a failure already durably recorded in PostgreSQL --
  # and `drop_staging` is a database call, which is exactly what has stopped
  # working in the case that matters. The table it could not drop is a leak,
  # logged at warning so an operator knows to remove it; losing the run's
  # outcome would be worse.
  defp cleanup(context, run_id, work_dir) do
    Staging.drop(context, run_id)
    :ok
  rescue
    exception -> leaked(run_id, Exception.message(exception))
  catch
    kind, reason -> leaked(run_id, "#{kind} #{inspect(reason)}")
  after
    File.rm_rf(work_dir)
  end

  # Swallowing the drop is the trade; swallowing it silently would not be. The
  # table this could not drop outlives the run, and an operator only knows to
  # go looking for it if the failure said so.
  defp leaked(run_id, reason) do
    Logger.warning(
      "GeoGenius could not drop the staging table for import run #{run_id} " <>
        "(#{Staging.table_name(run_id)}), so it is leaked and must be dropped by hand: #{reason}"
    )

    :ok
  end

  defp base_work_dir(opts) do
    Keyword.get_lazy(opts, :work_dir, fn -> Path.join(System.tmp_dir!(), "geo_genius") end)
  end

  # Only reached when the caller left `:timeout` unset: `:stale_after_seconds`
  # is the window this run was actually claimed under, carried here by
  # `GeoGenius.import/1` through a runner's `args`, so the derived timeout
  # matches the lease rather than a value that merely resembles it. A runner
  # backend always sets the key, even to `nil` when `Runner.stale_after_seconds/1`
  # found nothing to carry, so this falls back on the value rather than on
  # `Keyword.get/3`'s own default -- which only fires when the key is absent.
  defp derived_timeout(opts) do
    seconds = Keyword.get(opts, :stale_after_seconds) || @default_stale_after_seconds
    seconds * @milliseconds_per_second
  end

  defp load_and_run(%State{} = state) do
    case load_manifest(state) do
      {:ok, state} -> run_phases(state)
      {:error, reason} -> fail(state, state.run.status || "pending", reason)
    end
  end

  defp run_phases(%State{} = state) do
    notify(state, :import_started, run_payload(state))

    state
    |> phases()
    |> Enum.reduce_while({:ok, state}, &advance/2)
    |> finish()
  end

  defp phases(%State{publish?: true}), do: import_phases() ++ [{"publishing", &publish/1}]
  defp phases(%State{}), do: import_phases()

  defp import_phases do
    [
      {"downloading", &Artifacts.download/1},
      {"validating", &Artifacts.validate/1},
      {"staging", &stage/1},
      {"normalizing", &Normalize.normalize/1},
      {"relating", &relate/1},
      {"indexing", &index/1},
      {"verifying", &verify/1}
    ]
  end

  defp advance({phase, fun}, {:ok, state}) do
    case run_phase(state, phase, fun) do
      {:ok, state} -> {:cont, {:ok, state}}
      {:error, reason} -> {:halt, {:error, state, phase, reason}}
    end
  end

  # A phase boundary is one `advance_import` carrying the previous phase's
  # metrics, one event, and one telemetry span. A returned error, a raised
  # exception, and an exit or throw all leave here as an error tuple, so the
  # failure path below does not care which one a provider or a host adapter
  # produced -- and none of them can leave the run sitting in a phase with an
  # empty `error` column.
  defp run_phase(state, phase, fun) do
    Catalog.advance_import(state.context, state.run.run_id, phase, state.metrics)

    notify(state, :phase_advanced, %{
      run_id: state.run.run_id,
      phase: phase,
      metrics: state.metrics
    })

    state = %{state | metrics: %{}}

    Telemetry.import_span(phase, span_metadata(state), fn ->
      result = fun.(state)
      {result, phase_metrics(result), phase_status(result)}
    end)
  rescue
    exception -> {:error, {:exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:caught, kind, reason, __STACKTRACE__}}
  end

  # `collection_key` is the dimension a host charts an import against;
  # `run_id` is unique per run and unusable as a metrics tag.
  defp span_metadata(state) do
    %{
      run_id: state.run.run_id,
      release_id: state.run.release_id,
      collection_key: state.run.collection_key,
      prefix: state.context.prefix
    }
  end

  defp phase_metrics({:ok, %State{metrics: metrics}}), do: metrics
  defp phase_metrics({:error, _reason}), do: %{}

  defp phase_status({:ok, %State{}}), do: :ok
  defp phase_status({:error, _reason}), do: :error

  defp finish({:ok, state}), do: complete(state)
  defp finish({:error, state, phase, reason}), do: fail(state, phase, reason)

  defp complete(state) do
    case advance_to_completed(state) do
      :ok ->
        notify(state, :import_completed, run_payload(state))
        completed(state)

      {:error, reason} ->
        fail(state, "completed", reason)
    end
  end

  # Only the advance is guarded, and deliberately only the advance: it is the
  # call that decides whether the run completed.
  defp advance_to_completed(state) do
    Catalog.advance_import(state.context, state.run.run_id, "completed", state.metrics)
    :ok
  rescue
    exception -> {:error, {:exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:caught, kind, reason, __STACKTRACE__}}
  end

  # By the time this reads, the run is `completed` in PostgreSQL. A read that
  # fails here costs the caller its snapshot, never the outcome, so it must not
  # route to `fail/3`: `fail_import/3` refuses a completed run, so the call
  # would raise 55000 and bury the read error that actually happened behind a
  # failure to record it.
  defp completed(state) do
    case Catalog.import_run(state.context, state.run.run_id) do
      %ImportRun{} = run -> {:ok, run}
      nil -> {:error, {:unrecorded, unread(state, "the run is no longer in the catalog")}}
    end
  rescue
    exception -> {:error, {:unrecorded, unread(state, Exception.message(exception))}}
  catch
    kind, reason -> {:error, {:unrecorded, unread(state, "#{kind} #{inspect(reason)}")}}
  end

  defp unread(state, reason) do
    "GeoGenius import run #{state.run.run_id} completed, but reading it back failed: #{reason}"
  end

  # The stored error is the durable record, so recording it must not be able to
  # hide what actually went wrong: a `fail_import/3` that fails itself leaves
  # the original reason as this function's return value.
  defp fail(state, phase, reason) do
    detail = error_detail(phase, reason)

    notify(state, :import_failed, %{
      run_id: state.run.run_id,
      phase: phase,
      reason: detail["reason"]
    })

    case record_failure(state, detail) do
      :ok -> recorded(state, detail)
      {:error, _unrecorded} -> {:error, {:unrecorded, detail["reason"]}}
    end
  end

  defp record_failure(state, detail) do
    Catalog.fail_import(state.context, state.run.run_id, detail)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Re-reading the run is how the caller sees the stored error, but it is a
  # second database call after the one that mattered. The failure is already
  # durable by now, so a read that cannot be completed returns the reason
  # rather than raising over a record that was written successfully.
  defp recorded(state, detail) do
    case Catalog.import_run(state.context, state.run.run_id) do
      %ImportRun{} = run -> {:error, run}
      nil -> {:error, {:unrecorded, detail["reason"]}}
    end
  rescue
    _exception -> {:error, {:unrecorded, detail["reason"]}}
  catch
    _kind, _reason -> {:error, {:unrecorded, detail["reason"]}}
  end

  defp error_detail(phase, {:exception, exception, stacktrace}) do
    %{
      "phase" => phase,
      "reason" => Exception.message(exception),
      "exception" => inspect(exception.__struct__),
      "stacktrace" => frames(stacktrace)
    }
  end

  # An exit or a throw carries no exception struct, so `"exception"` names the
  # class instead -- `":exit"` for a host adapter's `GenServer.call` timeout or
  # a provider's dead task, `":throw"` for a non-local return that escaped.
  defp error_detail(phase, {:caught, kind, reason, stacktrace}) do
    %{
      "phase" => phase,
      "reason" => "the #{phase} phase #{caught_verb(kind)} #{inspect(reason)}",
      "exception" => inspect(kind),
      "stacktrace" => frames(stacktrace)
    }
  end

  defp error_detail(phase, reason) when is_binary(reason) do
    %{"phase" => phase, "reason" => reason}
  end

  defp error_detail(phase, reason), do: %{"phase" => phase, "reason" => inspect(reason)}

  defp caught_verb(:exit), do: "exited with"
  defp caught_verb(:throw), do: "threw"

  defp frames(stacktrace) do
    Enum.map(Enum.take(stacktrace, @stacktrace_frames), &Exception.format_stacktrace_entry/1)
  end

  # The manifest comes from the release row rather than the file it was loaded
  # from, so a resumed or retried run uses the document the release was opened
  # with even if the file on disk has since changed.
  defp load_manifest(%State{} = state) do
    case Catalog.release_manifest(state.context, state.run.release_id) do
      nil -> {:error, "release #{state.run.release_id} carries no manifest"}
      document -> build_manifest(state, document)
    end
  end

  defp build_manifest(state, document) do
    case Manifest.from_map(document) do
      {:ok, manifest} -> resolve_provider(state, manifest)
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp resolve_provider(state, manifest) do
    provider = Config.provider!(manifest.provider)
    artifacts = Map.new(provider.artifacts(manifest), &{&1.logical_name, &1})
    {:ok, %{state | manifest: manifest, provider: provider, manifest_artifacts: artifacts}}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp stage(%State{} = state) do
    Staging.reset(state.context, state.run.run_id)
    counter = :counters.new(1, [])

    state.resolved
    |> Enum.sort()
    |> Enum.reduce_while(:ok, &stage_artifact(&1, state, counter, &2))
    |> State.with_metrics(fn :ok -> %{state | metrics: %{"staged" => staged(counter)}} end)
  end

  defp staged(counter), do: :counters.get(counter, @counter_index)

  defp stage_artifact({logical_name, path}, state, counter, :ok) do
    case Map.fetch(state.manifest_artifacts, logical_name) do
      {:ok, artifact} -> stage_one(state, artifact, path, counter)
      :error -> {:halt, {:error, "the manifest declares no artifact named #{logical_name}"}}
    end
  end

  defp stage_one(state, artifact, path, counter) do
    emit = fn rows -> emit_rows(state, counter, rows) end

    case state.provider.stage(state.manifest, artifact, path, emit, stage_opts(state)) do
      :ok ->
        {:cont, :ok}

      {:error, reason} ->
        {:halt,
         {:error,
          "#{inspect(state.provider)} could not stage #{artifact.logical_name}: #{reason}"}}
    end
  end

  # Each `emit` call is both a bulk insert and a lease renewal, which is why a
  # provider stages a large artifact in chunks rather than in one call.
  defp emit_rows(state, counter, rows) do
    inserted = Staging.insert(state.context, state.run.run_id, rows, timeout: state.timeout)
    :counters.add(counter, @counter_index, inserted)
    Catalog.heartbeat_import(state.context, state.run.run_id, %{"staged" => staged(counter)})
    :ok
  end

  defp stage_opts(state) do
    Keyword.merge(state.opts,
      command: CommandAllowlist,
      command_target: Context.adapter(state.context, :command),
      work_dir: state.work_dir
    )
  end

  # Kept as a private one-line dispatch, rather than a direct
  # `&Relate.relate/1` in `import_phases/0`, so a phase-level test can drive
  # `GeoGenius.Pipeline.Relate.relate/1` in isolation the way
  # `GeoGenius.Pipeline.Normalize.normalize/1` already is, without this
  # module needing to expose anything beyond `execute/3`.
  defp relate(%State{} = state), do: Relate.relate(state)

  defp index(%State{} = state) do
    Catalog.analyze_release(state.context, state.run.release_id, timeout: state.timeout)
    {:ok, %{state | metrics: %{}}}
  end

  defp verify(%State{} = state) do
    report = Catalog.verify_release(state.context, state.run.release_id, timeout: state.timeout)

    metrics = %{
      "area_count" => report["area_count"],
      "boundary_count" => report["boundary_count"]
    }

    if report["ok"] do
      {:ok, %{state | metrics: metrics}}
    else
      {:error, "release failed verification: " <> Enum.join(report["failures"], "; ")}
    end
  end

  defp publish(%State{} = state) do
    Catalog.publish_release(state.context, state.run.release_id, timeout: state.timeout)

    notify(state, :release_published, %{
      release_id: state.run.release_id,
      collection_key: state.run.collection_key
    })

    {:ok, %{state | metrics: %{}}}
  end

  defp run_payload(state) do
    %{
      run_id: state.run.run_id,
      release_id: state.run.release_id,
      collection_key: state.run.collection_key,
      release_key: state.run.release_key
    }
  end

  # A notifier is called for side effects only and is never consulted for a
  # decision, so whatever it raises, exits with, or returns is dropped here
  # rather than allowed to end an import that is otherwise healthy. The event
  # is lost either way; logging it is what keeps that from being silent.
  defp notify(state, event, payload) do
    notifier = Context.adapter(state.context, :notifier)
    notifier.notify(event, payload, state.opts)
    :ok
  rescue
    exception ->
      dropped(event, Exception.message(exception))
  catch
    kind, reason ->
      dropped(event, "#{kind} #{inspect(reason)}")
  end

  defp dropped(event, reason) do
    Logger.warning("GeoGenius dropped the #{event} notification: #{reason}")
    :ok
  end
end
