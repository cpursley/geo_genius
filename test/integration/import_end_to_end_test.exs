defmodule GeoGenius.ImportEndToEndTest do
  @moduledoc """
  The acceptance cases for the ingestion layer: the properties that only
  appear once a manifest, an adapter set, a provider, the pipeline, the
  publication lifecycle, and the read layer are all in play at once.

  Every case drives the public API (`GeoGenius.import/1`, `publish/2`,
  `rollback/2`, `published_release/2`, and the reads) rather than the
  pipeline directly, because the seams between those functions are what
  these cases are about.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias GeoGenius.AppEnv
  alias GeoGenius.Cache
  alias GeoGenius.Caches.FileSystem
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportFixture
  alias GeoGenius.ImportRun
  alias GeoGenius.Manifest
  alias GeoGenius.Runners
  alias GeoGenius.TestRepo

  @geojson_url "https://example.test/territories.geojson"

  defmodule FixtureDownloader do
    @moduledoc """
    Serves the repository's own artifact fixtures over a URL.

    `GeoGenius.StubDownloader` reads its bodies out of `opts[:bodies]`, and a
    runner forwards only `:publish` and `:stale_after_seconds` to
    `GeoGenius.Pipeline.execute/3`, so there is no channel for that map on a
    run started through `GeoGenius.import/1`. This resolves a URL to a file on
    disk instead, which needs no options at all.
    """

    @behaviour GeoGenius.Downloader

    @bodies %{
      "https://example.test/territories.geojson" =>
        Path.expand("../support/artifacts/territories.geojson", __DIR__)
    }

    @impl GeoGenius.Downloader
    @spec available?() :: boolean()
    def available?, do: true

    @impl GeoGenius.Downloader
    @spec fetch(String.t(), Path.t(), keyword()) ::
            {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, String.t()}
    def fetch(url, destination, _opts) do
      case Map.fetch(@bodies, url) do
        {:ok, source} ->
          File.mkdir_p!(Path.dirname(destination))
          File.cp!(source, destination)
          body = File.read!(destination)

          {:ok,
           %{
             bytes: byte_size(body),
             sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
           }}

        :error ->
          {:error, "no fixture artifact is served at #{url}"}
      end
    end
  end

  @repo_opts [repo: TestRepo, prefix: "geo_genius"]

  # Defined before every use. A module attribute read above its definition
  # silently evaluates to nil, and nil here would make `relname = ANY(NULL)`
  # match nothing, so the placement assertion would count zero locks and pass
  # no matter where the lock was taken.
  #
  # What the partition lock orders: the release row a caller inserts and the
  # four partitioned parents whose partitions it creates or drops.
  @partition_relations ~w(release boundary boundary_part relation release_area)

  # What the publication lock orders: the release row whose status the swap
  # sets, the pointer itself, and the append-only log the swap writes to.
  @publication_relations ~w(release publication publication_event)

  setup do
    unique = System.unique_integer([:positive])
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_end_to_end_cache_#{unique}")
    AppEnv.put(:cache_dir, cache_dir)
    on_exit(fn -> File.rm_rf(cache_dir) end)

    :ok
  end

  describe "an operator-supplied collection and a downloadable one" do
    test "both publish, through the same phases and the same measurements" do
      {supplied_collection, supplied_release} = fresh_collection!("supplied")
      {fetched_collection, fetched_release} = fresh_collection!("fetched")

      supplied = geojson_manifest(supplied_collection, supplied_release, :operator_supplied)
      seed_cache!(supplied, ImportFixture.body())

      fetched = geojson_manifest(fetched_collection, fetched_release, :downloadable)

      supplied_run = import_and_publish!(supplied)
      fetched_run = import_and_publish!(fetched)

      assert supplied_run.status == "completed"
      assert fetched_run.status == "completed"

      assert GeoGenius.published_release(supplied_collection, @repo_opts) ==
               supplied_run.release_id

      assert GeoGenius.published_release(fetched_collection, @repo_opts) ==
               fetched_run.release_id

      # The identity that matters is the shape of what was measured, not the
      # values: one run resolved its artifact from the cache and the other
      # pulled it over the wire, so `cached` and `downloaded` are the two
      # counters that differ while every key stays the same.
      assert Map.keys(supplied_run.stage_metrics) |> Enum.sort() ==
               Map.keys(fetched_run.stage_metrics) |> Enum.sort()

      assert supplied_run.stage_metrics["cached"] == 1
      assert supplied_run.stage_metrics["downloaded"] == 0
      assert fetched_run.stage_metrics["cached"] == 0
      assert fetched_run.stage_metrics["downloaded"] == 1

      assert supplied_run.stage_metrics["area_count"] == fetched_run.stage_metrics["area_count"]
    end
  end

  describe "a collection whose records carry no coordinates" do
    test "resolves through codes and names alone" do
      {collection, release} = fresh_collection!("codes_only")
      body = districts_csv()
      manifest = csv_manifest(collection, release, body)
      seed_cache!(manifest, body)

      run = import_and_publish!(manifest)
      assert run.status == "completed"
      assert run.stage_metrics["area_count"] == 3
      assert run.stage_metrics["boundary_count"] == 0

      # Three areas carry three distinct codes, so a lookup that returned the
      # collection's areas indiscriminately would not pass this.
      assert [south] = GeoGenius.areas_by_code("fips", "48003", @repo_opts)
      assert south.area_key == "#{collection}:district:south"
      assert south.name == "Southgate District"
      assert south.centroid == nil

      assert [north] = GeoGenius.areas_by_code("fips", "48001", @repo_opts)
      assert north.area_key == "#{collection}:district:north"

      assert [] = GeoGenius.areas_by_code("fips", "48099", @repo_opts)

      # All three names end in "District", so a search that ranked nothing
      # would still return three rows; the discriminator is which one leads.
      assert [top | rest] = GeoGenius.search_areas("harborview", @repo_opts)
      assert top.area_key == "#{collection}:district:harbor"
      assert top.score > 0

      assert Enum.all?(rest, &(&1.score <= top.score)),
             "search_areas must return its matches ranked, best first"
    end
  end

  describe "a candidate that fails verification" do
    test "never replaces the release that is already published" do
      {collection, first_release} = fresh_collection!("failed_candidate")

      first = geojson_manifest(collection, first_release, :operator_supplied)
      seed_cache!(first, ImportFixture.body())
      published = import_and_publish!(first)

      assert published.status == "completed"
      published_id = published.release_id
      assert GeoGenius.published_release(collection, @repo_opts) == published_id

      # The same artifact, imported into a collection that now demands a
      # boundary for every area. The fixture's third feature has none, so
      # `verify_release` refuses the candidate.
      second_release = "r#{System.unique_integer([:positive])}"

      second =
        geojson_manifest(collection, second_release, :operator_supplied, requires_geometry: true)

      seed_cache!(second, ImportFixture.body())

      assert {:ok, run_id} = GeoGenius.import(import_opts(second, publish: true))
      assert {:error, %ImportRun{} = failed} = GeoGenius.await(run_id, 60_000, @repo_opts)

      assert failed.status == "failed"
      assert failed.release_id != published_id
      assert failed.error["reason"] =~ "failed verification"
      assert failed.error["reason"] =~ "lack a boundary"

      assert GeoGenius.published_release(collection, @repo_opts) == published_id

      assert [west] = GeoGenius.areas_for_point(0.5, 0.5, @repo_opts)
      assert west.area_key == "#{collection}:territory:west"
      assert west.release_id == published_id

      assert [east] = GeoGenius.areas_for_point(1.5, 0.5, @repo_opts)
      assert east.area_key == "#{collection}:territory:east"
      assert east.release_id == published_id
    end
  end

  describe "rollback" do
    test "returns the previous release, not the oldest one" do
      {collection, [first, second, third]} = publish_three!("rollback")

      assert GeoGenius.published_release(collection, @repo_opts) == third

      assert {:ok, ^second} = GeoGenius.rollback(collection, @repo_opts)
      assert GeoGenius.published_release(collection, @repo_opts) == second

      refute second == first,
             "three releases are what separates 'the previous' from 'the oldest'"
    end
  end

  describe "re-importing under a second release key" do
    test "produces two releases, and release_at resolves the earlier moment" do
      {collection, [first, second, third], moments} = publish_three_with_moments!("release_at")

      assert Enum.uniq([first, second, third]) == [first, second, third]

      [after_first, after_second, after_third] = moments

      assert GeoGenius.release_at(after_first, [collection: collection] ++ @repo_opts) == first

      assert GeoGenius.release_at(after_second, [collection: collection] ++ @repo_opts) ==
               second

      assert GeoGenius.release_at(after_third, [collection: collection] ++ @repo_opts) == third
    end
  end

  describe "two concurrent imports of the same release" do
    test "preserve exactly one claim" do
      {collection, release} = fresh_collection!("concurrent")
      manifest = geojson_manifest(collection, release, :operator_supplied)
      seed_cache!(manifest, ImportFixture.body())

      case race_imports(manifest) do
        {[_ok], [error]} ->
          assert_live_import_error(error)

        {[_first, _second], []} ->
          # Both claims landed only because the first run finished before the
          # second one reached atomic import preparation: a completed run holds
          # no lease, so the second claim is a legitimate new attempt rather
          # than a lost race. One retry, then this is a real failure.
          case race_imports(manifest) do
            {[_ok], [error]} ->
              assert_live_import_error(error)

            other ->
              flunk(
                "two concurrent imports of one release must leave exactly one claim, " <>
                  "got #{inspect(other)} twice in a row"
              )
          end

        {oks, errors} ->
          flunk("expected one claim and one refusal, got #{inspect({oks, errors})}")
      end
    end
  end

  describe "two concurrent imports of different releases" do
    test "both complete and both publish" do
      {first_collection, first_release} = fresh_collection!("parallel_one")
      {second_collection, second_release} = fresh_collection!("parallel_two")

      first = geojson_manifest(first_collection, first_release, :operator_supplied)
      second = geojson_manifest(second_collection, second_release, :operator_supplied)
      seed_cache!(first, ImportFixture.body())
      seed_cache!(second, ImportFixture.body())

      # Opening two different releases at once used to deadlock: each caller
      # held the RowExclusiveLock of its own insert into `release` while
      # waiting for the ShareRowExclusiveLock its partitions' cloned foreign
      # key needs on that same table.
      results =
        [first, second]
        |> Enum.map(fn manifest ->
          Task.async(fn -> GeoGenius.import(import_opts(manifest, publish: true)) end)
        end)
        |> Task.await_many(120_000)

      assert [{:ok, first_run_id}, {:ok, second_run_id}] = results

      assert {:ok, %ImportRun{status: "completed"} = first_run} =
               GeoGenius.await(first_run_id, 60_000, @repo_opts)

      assert {:ok, %ImportRun{status: "completed"} = second_run} =
               GeoGenius.await(second_run_id, 60_000, @repo_opts)

      assert GeoGenius.published_release(first_collection, @repo_opts) == first_run.release_id

      assert GeoGenius.published_release(second_collection, @repo_opts) ==
               second_run.release_id
    end
  end

  describe "the publication advisory lock" do
    # Same harness as the partition lock above, pointed at the other key
    # family. All three members swap or read one collection's publication
    # pointer and must not interleave: two concurrent publishes in a
    # collection would otherwise race to set previous_release_id and could
    # leave a rollback target that was never published.
    test "publish_release takes it before it writes" do
      {collection, release_id} = publishable_release!("pub_lock_publish")

      assert {:ok, %Postgrex.Result{}} =
               blocked_on_publication_lock!(
                 collection,
                 "SELECT geo_genius.publish_release($1)",
                 [Ecto.UUID.dump!(release_id)],
                 "publish_release"
               )

      assert GeoGenius.published_release(collection, @repo_opts) == release_id
    end

    test "rollback_publication takes it before it writes" do
      {collection, first_id} = publishable_release!("pub_lock_rollback")
      ctx = context()
      Catalog.publish_release(ctx, first_id)
      second_id = second_release!(ctx, collection, "r2")
      Catalog.publish_release(ctx, second_id)

      assert {:ok, %Postgrex.Result{}} =
               blocked_on_publication_lock!(
                 collection,
                 "SELECT geo_genius.rollback_publication($1)",
                 [collection],
                 "rollback_publication"
               )

      assert GeoGenius.published_release(collection, @repo_opts) == first_id
    end

    test "retire_releases takes it before it writes" do
      {collection, first_id} = publishable_release!("pub_lock_retire")
      ctx = context()
      Catalog.publish_release(ctx, first_id)
      second_id = second_release!(ctx, collection, "r2")
      Catalog.publish_release(ctx, second_id)

      assert {:ok, %Postgrex.Result{}} =
               blocked_on_publication_lock!(
                 collection,
                 "SELECT geo_genius.retire_releases($1, $2)",
                 [collection, 1],
                 "retire_releases"
               )

      assert %Postgrex.Result{rows: [[1]]} =
               TestRepo.query!(
                 """
                 SELECT count(*) FROM geo_genius.release
                   JOIN geo_genius.collection ON collection.id = release.collection_id
                  WHERE collection.key = $1 AND release.retired_at IS NOT NULL
                 """,
                 [collection]
               )
    end
  end

  describe "concurrent identical upserts" do
    # `area` and `area_type` each carry two unique constraints, and ON CONFLICT
    # can name only one arbiter. Two callers upserting the same row at once
    # each insert speculatively, and the loser can block on the index that is
    # not the arbiter, where the wait resolves into a bare 23505 instead of the
    # DO UPDATE the call asked for. Measured at 28 failures in 60 trials for
    # `upsert_area` and 19 in 60 for `upsert_area_type` before they serialized.
    @trials 20

    test "never surface a bare unique violation" do
      {collection, _release} = fresh_collection!("upsert_race")
      ctx = context()
      Catalog.upsert_collection(ctx, %{key: collection, name: collection})
      Catalog.upsert_authority(ctx, collection, %{key: collection, name: collection})

      Catalog.upsert_area_type(ctx, collection, %{key: "territory", rank: 1})

      left = raw_connection!()
      right = raw_connection!()

      # Every trial races a row that does not exist yet. Racing one identity
      # repeatedly would only be a real insert race on the first trial: after
      # that the row is committed and both callers take DO UPDATE, where there
      # is nothing to collide on and nothing to detect.
      area_type_outcomes =
        race_statement(left, right, "SELECT geo_genius.upsert_area_type($1, $2, $3)", fn trial ->
          [collection, "type_#{trial}", 100 + trial]
        end)

      assert Enum.all?(area_type_outcomes, &(&1 == :ok)),
             "upsert_area_type raced with itself: #{inspect(Enum.uniq(area_type_outcomes))}"

      area_outcomes =
        race_statement(
          left,
          right,
          "SELECT geo_genius.upsert_area($1, $1, 'territory', $2)",
          fn trial -> [collection, "code_#{trial}"] end
        )

      assert Enum.all?(area_outcomes, &(&1 == :ok)),
             "upsert_area raced with itself: #{inspect(Enum.uniq(area_outcomes))}"
    end
  end

  describe "the partition advisory lock" do
    # Each of these holds the lock on one connection and watches another wait
    # for it. The assertion is never merely "the caller waited": a caller that
    # takes the lock too late waits too, having already done the work the lock
    # was there to order. What separates the two is what the waiter holds while
    # it waits, which is why every case reads `pg_locks`. Effects cannot serve
    # as the discriminator on their own, either -- a statement cancelled by a
    # timeout rolls its own DDL back, so a drop that ran before it waited looks
    # exactly like a drop that never ran.
    test "open_release takes it before it locks a release row" do
      {collection, release} = fresh_collection!("lock_placement")
      Catalog.upsert_collection(context(), %{key: collection, name: collection})

      assert {:ok, %Postgrex.Result{rows: [[raw_id]]}} =
               blocked_until_lock_released!(
                 "SELECT geo_genius.open_release($1, $2, '{}'::jsonb, NULL)",
                 [collection, release],
                 "open_release"
               )

      # The release did not exist before the call, so opening it is real work
      # rather than something the fixture had already done: it inserted a row
      # and built four partitions once the lock was free.
      assert partition_count(Ecto.UUID.load!(raw_id)) == 4
    end

    test "create_release_partitions takes it before it builds anything" do
      release_id = release_with_partitions!("lock_direct")

      # `open_release` built this release's partitions on the way in, and
      # `CREATE TABLE IF NOT EXISTS` short-circuits on every one of them. Left
      # that way, the call under test does no DDL, takes no lock the deadlock
      # cycle is made of, and the assertions below hold no matter where the
      # lock sits. Dropping them first is what makes the call actually build.
      TestRepo.query!("SELECT geo_genius.drop_release_partitions($1)", [
        Ecto.UUID.dump!(release_id)
      ])

      assert partition_count(release_id) == 0

      assert {:ok, %Postgrex.Result{}} =
               blocked_until_lock_released!(
                 "SELECT geo_genius.create_release_partitions($1)",
                 [Ecto.UUID.dump!(release_id)],
                 "create_release_partitions"
               )

      # Now an assertion about the call under test rather than about the
      # fixture that set it up.
      assert partition_count(release_id) == 4
    end

    test "drop_release_partitions takes it before it drops anything" do
      release_id = release_with_partitions!("lock_drop")

      # open_release built this release's four partitions on the way in, so the
      # drop below has something to remove.
      assert partition_count(release_id) == 4

      assert {:ok, %Postgrex.Result{}} =
               blocked_until_lock_released!(
                 "SELECT geo_genius.drop_release_partitions($1)",
                 [Ecto.UUID.dump!(release_id)],
                 "drop_release_partitions"
               )

      assert partition_count(release_id) == 0
    end
  end

  defp context, do: Context.new(@repo_opts)

  defp assert_live_import_error(error) do
    message = Exception.message(error)

    assert message =~ "live import",
           "the refused caller must be told a live import already holds the release, got: " <>
             message
  end

  # Runs one statement on two connections at the same instant, `@trials` times,
  # and reports every outcome. Both connections wait on a message rather than a
  # sleep, so the two statements really are issued together.
  defp race_statement(left, right, sql, params_for) do
    Enum.flat_map(1..@trials, fn trial ->
      race_trial(left, right, sql, params_for.(trial))
    end)
  end

  defp race_trial(left, right, sql, params) do
    parent = self()
    runners = Enum.map([left, right], &spawn_racer(&1, sql, params, parent))

    # Both pids are collected before either is released: releasing the first as
    # it reports ready would let it finish before the second had started, which
    # is not a race at all.
    runners
    |> Enum.map(fn _ ->
      assert_receive {:ready, pid}, 5_000
      pid
    end)
    |> Enum.each(&send(&1, :go))

    Enum.map(runners, fn _ ->
      assert_receive {:outcome, outcome}, 10_000
      outcome
    end)
  end

  defp spawn_racer(conn, sql, params, parent) do
    spawn(fn ->
      send(parent, {:ready, self()})
      await_go()
      send(parent, {:outcome, statement_outcome(conn, sql, params)})
    end)
  end

  defp await_go do
    receive do
      :go -> :ok
    after
      5_000 -> :ok
    end
  end

  defp statement_outcome(conn, sql, params) do
    case Postgrex.query(conn, sql, params) do
      {:ok, %Postgrex.Result{}} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: code}}} -> code
      {:error, other} -> other
    end
  end

  # The partition tables a release owns, counted by the suffix
  # create_release_partitions derives from the release id, so this counts one
  # release's partitions rather than every partition in the schema.
  defp partition_count(release_id) do
    suffix = String.replace(release_id, "-", "")

    %Postgrex.Result{rows: [[count]]} =
      TestRepo.query!(
        """
        SELECT count(*) FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'geo_genius'
           AND c.relname IN ($1, $2, $3, $4)
        """,
        [
          "boundary_" <> suffix,
          "boundary_part_" <> suffix,
          "relation_" <> suffix,
          "release_area_" <> suffix
        ]
      )

    count
  end

  # The publication lock is keyed by the immutable collection key, so the
  # holder uses the same value the statement under test derives.
  defp blocked_on_publication_lock!(collection, sql, params, label) do
    blocked_until_lock_released!(sql, params, label,
      key: "geo_genius.publication_lock_key('#{collection}')",
      relations: @publication_relations
    )
  end

  # A release that passes verify_release: one area with an official name, a
  # declared source release, and a membership row. requires_geometry defaults
  # to false, so no boundary is needed.
  defp publishable_release!(label) do
    {collection, release} = fresh_collection!(label)
    ctx = context()
    release_id = seeded_release!(ctx, collection, release)

    {collection, release_id}
  end

  defp second_release!(ctx, collection, release), do: seeded_release!(ctx, collection, release)

  defp seeded_release!(ctx, collection, release) do
    body = ImportFixture.body()

    {:ok, manifest} =
      Manifest.from_map(%{
        "collection" => collection,
        "collection_name" => collection,
        "release" => release,
        "provider" => "geojson",
        "requires_geometry" => false,
        "authorities" => [%{"key" => "auth", "name" => "Authority"}],
        "area_types" => [%{"key" => "area", "rank" => 10, "requires_geometry" => false}],
        "sources" => [
          %{
            "source_key" => "#{collection}:src",
            "provider" => "geojson",
            "license" => "CC0-1.0",
            "release_key" => release,
            "artifacts" => [
              %{
                "logical_name" => "fixture.geojson",
                "operator_supplied" => true,
                "format" => "geojson",
                "required" => true,
                "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
                "bytes" => byte_size(body)
              }
            ]
          }
        ],
        "options" => %{"area_type" => "area", "code_property" => "code"}
      })

    candidate =
      ImportFixture.prepare!(ctx, manifest,
        owner: "end-to-end-fixture",
        runner_backend: "test"
      )

    executor_id = ImportFixture.claim_executor!(ctx, candidate.run_id)
    ImportFixture.advance_to!(ctx, candidate.run_id, executor_id, "downloading")

    ImportFixture.observe_selected_artifacts!(
      ctx,
      candidate.release_id,
      candidate.run_id,
      executor_id
    )

    ImportFixture.advance_to!(ctx, candidate.run_id, executor_id, "normalizing")

    Catalog.upsert_area_many(ctx, candidate.run_id, executor_id, [
      %{authority_key: "auth", area_type_key: "area", code: "a"}
    ])

    Catalog.put_area_in_release(ctx, candidate.run_id, executor_id, "auth:area:a", %{
      centroid: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326}
    })

    Catalog.put_area_name(ctx, candidate.run_id, executor_id, "auth:area:a", %{
      name: "Area A",
      kind: "official"
    })

    # These lock tests exercise the explicit operator publish API, so leave
    # the release unpublished but close its import before handing it back.
    ImportFixture.advance_to!(ctx, candidate.run_id, executor_id, "verifying")
    Catalog.complete_import(ctx, candidate.run_id, executor_id, %{})

    candidate.release_id
  end

  # A connection outside the Repo's pool, so a test can hold a transaction open
  # and watch another session block on it.
  defp raw_connection! do
    config = TestRepo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: config[:username],
        password: config[:password],
        database: config[:database],
        types: config[:types]
      )

    # Postgrex's pool child can exit :shutdown rather than :normal, which
    # GenServer.stop/1 reports as a stop failure, so this monitors instead.
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(conn) do
        ref = Process.monitor(conn)
        Process.exit(conn, :shutdown)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          5_000 -> :ok
        end
      end
    end)

    conn
  end

  defp backend_pid(conn) do
    %Postgrex.Result{rows: [[pid]]} = Postgrex.query!(conn, "SELECT pg_backend_pid()", [])
    pid
  end

  # Runs `fun` while `conn` holds the lock `key_sql` names, in an open
  # transaction, then rolls that transaction back. `key_sql` is always a call
  # to the shipped key function rather than a restated constant, so this holds
  # exactly the lock the code under test takes and cannot drift from it.
  defp hold_lock(conn, key_sql, fun) do
    parent = self()

    Task.async(fn ->
      Postgrex.transaction(
        conn,
        fn tx ->
          Postgrex.query!(tx, "SELECT pg_advisory_xact_lock(#{key_sql})", [])
          send(parent, {:locked, self()})

          receive do
            :release -> :ok
          after
            60_000 -> :ok
          end

          Postgrex.rollback(tx, :released)
        end,
        timeout: 120_000
      )
    end)
    |> then(fn holder ->
      assert_receive {:locked, holder_pid}, 10_000

      try do
        fun.()
      after
        send(holder_pid, :release)
        Task.await(holder, 60_000)
      end
    end)
  end

  # Matches the partition lock specifically, not any advisory wait. PostgreSQL
  # splits a bigint advisory key across `classid` (high 32 bits) and `objid`
  # (low 32 bits), with `objsubid` 1 marking the two-argument form, and both
  # halves are read back from the shipped function so the test cannot drift
  # from the key the code actually takes.
  defp await_advisory_wait(observer, backend_pid, key_sql, attempts \\ 100) do
    %Postgrex.Result{rows: [[waiting]]} =
      Postgrex.query!(
        observer,
        """
        SELECT count(*) FROM pg_locks
         WHERE pid = $1
           AND locktype = 'advisory'
           AND NOT granted
           AND objsubid = 1
           AND classid = ((((#{key_sql}) >> 32) & 4294967295))::oid
           AND objid = (((#{key_sql}) & 4294967295))::oid
        """,
        [backend_pid]
      )

    cond do
      waiting > 0 ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(50) && await_advisory_wait(observer, backend_pid, key_sql, attempts - 1)
    end
  end

  # Every relation the partition lock exists to order: the release row a caller
  # inserts, and the four partitioned parents whose partitions it creates or
  # drops. A caller waiting on the lock correctly holds none of them. A caller
  # that took the lock after doing its work holds all of them, which is exactly
  # the half of the deadlock cycle the lock is meant to prevent.
  #
  # Only the modes that take part in that cycle are counted. `AccessShareLock`
  # is what an ordinary read of `release` leaves behind and conflicts with
  # nothing but `AccessExclusiveLock`, so counting it would let a benign read
  # stand in for the real signal and would make this assertion say something
  # other than what the comment above claims.
  defp granted_ddl_locks(observer, backend_pid, relations) do
    %Postgrex.Result{rows: [[count]]} =
      Postgrex.query!(
        observer,
        """
        SELECT count(*) FROM pg_locks
         WHERE pid = $1 AND granted
           AND locktype = 'relation'
           AND mode IN ('RowExclusiveLock', 'ShareRowExclusiveLock', 'AccessExclusiveLock')
           AND relation IN (
             SELECT c.oid FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'geo_genius' AND c.relname = ANY($2)
           )
        """,
        [backend_pid, relations]
      )

    count
  end

  # Issues `sql` on its own connection while another holds the lock `key_sql`
  # names, asserts it is waiting on that lock and holding nothing it should not
  # be, then releases the lock and returns what the statement finally did. No
  # statement timeout: the point is to let the statement finish, so its real
  # effect can be asserted afterwards.
  #
  # `opts` carries `:key` (the shipped key function to hold, defaulting to the
  # partition lock) and `:relations` (the tables that lock orders, so the
  # placement assertion looks at the ones this lock is actually about).
  defp blocked_until_lock_released!(sql, params, label, opts \\ []) do
    key_sql = Keyword.get(opts, :key, "geo_genius.partition_lock_key()")
    relations = Keyword.get(opts, :relations, @partition_relations)

    holder = raw_connection!()
    worker = raw_connection!()
    observer = raw_connection!()
    worker_backend = backend_pid(worker)

    running =
      hold_lock(holder, key_sql, fn ->
        running = Task.async(fn -> Postgrex.query(worker, sql, params, timeout: 60_000) end)

        assert await_advisory_wait(observer, worker_backend, key_sql),
               "#{label} must wait on #{key_sql} while another session holds it"

        assert granted_ddl_locks(observer, worker_backend, relations) == 0,
               "#{label} took #{key_sql} too late: it is waiting while already " <>
                 "holding locks on the tables the lock orders"

        running
      end)

    Task.await(running, 60_000)
  end

  defp release_with_partitions!(label) do
    {collection, release} = fresh_collection!(label)
    ctx = context()
    manifest = geojson_manifest(collection, release, :operator_supplied)

    release_id =
      ImportFixture.prepare!(ctx, manifest,
        owner: "partition-lock-fixture",
        runner_backend: "test"
      ).release_id

    TestRepo.query!("DELETE FROM geo_genius.import_run_lease WHERE release_id = $1", [
      Ecto.UUID.dump!(release_id)
    ])

    release_id
  end

  defp race_imports(%Manifest{} = manifest) do
    [
      Task.async(fn -> GeoGenius.import(import_opts(manifest, owner: "racer-a")) end),
      Task.async(fn -> GeoGenius.import(import_opts(manifest, owner: "racer-b")) end)
    ]
    |> Task.await_many(60_000)
    |> Enum.split_with(&match?({:ok, _run_id}, &1))
    |> then(fn {oks, errors} -> {oks, Enum.map(errors, fn {:error, reason} -> reason end)} end)
  end

  # Three releases, published oldest first. Two would not distinguish "the
  # previous release" from "the oldest release": both rollback and a
  # time-scoped lookup can pass a two-release fixture while answering the
  # wrong question.
  defp publish_three!(label) do
    {collection, _release} = fresh_collection!(label)

    ids =
      Enum.map(1..3, fn index ->
        publish_one!(collection, "r#{index}_#{System.unique_integer([:positive])}")
      end)

    {collection, ids}
  end

  defp publish_three_with_moments!(label) do
    {collection, _release} = fresh_collection!(label)

    {ids, moments} =
      Enum.map(1..3, fn index ->
        id = publish_one!(collection, "r#{index}_#{System.unique_integer([:positive])}")
        moment = DateTime.utc_now()
        Process.sleep(10)
        {id, moment}
      end)
      |> Enum.unzip()

    {collection, ids, moments}
  end

  defp publish_one!(collection, release) do
    manifest = geojson_manifest(collection, release, :operator_supplied)
    seed_cache!(manifest, ImportFixture.body())
    run = import_and_publish!(manifest)
    assert run.status == "completed"
    run.release_id
  end

  defp import_and_publish!(%Manifest{} = manifest) do
    assert {:ok, run_id} = GeoGenius.import(import_opts(manifest, publish: true))
    assert {:ok, %ImportRun{} = run} = GeoGenius.await(run_id, 60_000, @repo_opts)
    run
  end

  defp import_opts(%Manifest{} = manifest, extra) do
    Keyword.merge(
      @repo_opts ++
        [manifest: manifest, runner: Runners.Inline, downloader: FixtureDownloader],
      extra
    )
  end

  defp fresh_collection!(label) do
    unique = System.unique_integer([:positive])
    collection = "end_to_end_#{label}_#{unique}"

    on_exit({ImportFixture, collection}, fn -> ImportFixture.teardown!(collection) end)

    {collection, "r#{unique}"}
  end

  defp geojson_manifest(collection, release, location, opts \\ []) do
    body = ImportFixture.body()

    artifact =
      Map.merge(
        %{
          "logical_name" => "territories.geojson",
          "format" => "geojson",
          "required" => true,
          "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
          "bytes" => byte_size(body)
        },
        location_fields(location)
      )

    build_manifest!(%{
      "collection" => collection,
      "collection_name" => "End-to-end Territories",
      "description" => "Acceptance coverage for the ingestion layer",
      "release" => release,
      "provider" => "geojson",
      "requires_geometry" => Keyword.get(opts, :requires_geometry, false),
      "source_date" => "2026-01-15",
      "authorities" => [%{"key" => collection, "name" => "End-to-end Operations"}],
      "area_types" => [%{"key" => "territory", "rank" => 100}],
      "sources" => [
        %{
          "source_key" => "#{collection}:territories",
          "provider" => "geojson",
          "license" => "CC0-1.0",
          "release_key" => release,
          "source_date" => "2026-01-15",
          "artifacts" => [artifact]
        }
      ],
      "options" => %{
        "code_property" => "territory_id",
        "name_property" => "territory_name",
        "area_type" => "territory",
        "attribute_properties" => ["short_name", "population"]
      }
    })
  end

  defp location_fields(:operator_supplied), do: %{"operator_supplied" => true}
  defp location_fields(:downloadable), do: %{"url" => @geojson_url, "operator_supplied" => false}

  defp csv_manifest(collection, release, body) do
    build_manifest!(%{
      "collection" => collection,
      "collection_name" => "End-to-end Districts",
      "description" => "A collection with codes and names and no coordinates",
      "release" => release,
      "provider" => "csv",
      "requires_geometry" => false,
      "source_date" => "2026-02-01",
      "authorities" => [%{"key" => collection, "name" => "End-to-end Registry"}],
      "area_types" => [%{"key" => "district", "rank" => 100}],
      "sources" => [
        %{
          "source_key" => "#{collection}:districts",
          "provider" => "csv",
          "license" => "CC0-1.0",
          "release_key" => release,
          "source_date" => "2026-02-01",
          "artifacts" => [
            %{
              "logical_name" => "districts.csv",
              "operator_supplied" => true,
              "format" => "csv",
              "required" => true,
              "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
              "bytes" => byte_size(body)
            }
          ]
        }
      ],
      "options" => %{
        "area_type" => "district",
        "code_column" => "district_id",
        "name_column" => "district_name",
        "code_columns" => [%{"type" => "fips", "column" => "fips"}],
        "attribute_columns" => ["population"]
      }
    })
  end

  # No longitude or latitude column exists to configure, so nothing in this
  # release can carry a centroid even by accident.
  defp districts_csv do
    """
    district_id,district_name,fips,population
    north,Northwood District,48001,1200
    south,Southgate District,48003,800
    harbor,Harborview District,48005,450
    """
  end

  defp build_manifest!(map) do
    {:ok, manifest} = Manifest.from_map(map)
    manifest
  end

  defp seed_cache!(%Manifest{} = manifest, body) do
    [source] = manifest.sources
    [artifact] = source.artifacts

    key =
      Cache.key([
        manifest.collection,
        source.source_key,
        source.release_key,
        artifact.logical_name
      ])

    path = FileSystem.path(key, [])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end
end
