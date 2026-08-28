defmodule GeoGenius.OperationalTasksTest do
  # Mix.Task and Mix.shell state are global, and the forwarding cases drive a
  # non-default prefix through the whole stack, so these never run alongside
  # anything else.
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.Cache
  alias GeoGenius.Caches.FileSystem
  alias GeoGenius.Catalog
  alias GeoGenius.Context
  alias GeoGenius.ImportFixture
  alias GeoGenius.RecordingRepo
  alias GeoGenius.Runners
  alias GeoGenius.Staging
  alias GeoGenius.TestRepo

  alias Mix.Tasks.GeoGenius.Import
  alias Mix.Tasks.GeoGenius.Publish
  alias Mix.Tasks.GeoGenius.Rollback
  alias Mix.Tasks.GeoGenius.Status
  alias Mix.Tasks.GeoGenius.SweepStaging

  defmodule NoopRunner do
    @moduledoc "A runner backend that claims to accept work but never runs it."
    @behaviour GeoGenius.Runner

    @impl GeoGenius.Runner
    def name, do: "noop"

    @impl GeoGenius.Runner
    def available?, do: true

    @impl GeoGenius.Runner
    def enqueue(_context, _run_id, _args), do: :ok
  end

  # Never installed anywhere. Every query a task issues under it fails, which
  # is exactly what makes a prefix that was actually forwarded distinguishable
  # from the default one: "geo_genius" exists in this database, so a task that
  # dropped `prefix:` would succeed here and look identical.
  @probe_prefix "gg_task_probe"
  @probe_repo "GeoGenius.RecordingRepo"
  @probe_uuid "00000000-0000-4000-8000-000000000000"

  @repo_opts [repo: TestRepo, prefix: "geo_genius"]

  # A second, genuinely installed prefix. See the setup_all below for why a
  # fake one cannot replace it.
  @alt_prefix "gg_alt"
  @alt_opts [repo: TestRepo, prefix: "gg_alt"]

  # The full set of forwarding promises these five tasks make, closed at once
  # rather than one at a time. Each entry names the task, the arguments that
  # reach one API call, and a fragment of the SQL that call must issue --
  # asserted together with the probe prefix, in the same statement, at the
  # recording repo the `--repo` option named.
  @forwarding [
    {"geo_genius.import", Import, ["--collection", "demo", "--release", "r1"],
     "upsert_collection"},
    {"geo_genius.publish --release-id", Publish, ["--release-id", @probe_uuid],
     "publish_release"},
    {"geo_genius.publish --collection", Publish, ["--collection", "demo", "--release", "r1"],
     "import_run_status"},
    {"geo_genius.rollback --yes", Rollback, ["--collection", "demo", "--yes"],
     "rollback_publication"},
    {"geo_genius.rollback dry run", Rollback, ["--collection", "demo"], "published_release"},
    {"geo_genius.sweep_staging", SweepStaging, ["--yes"], "staging_table_name"},
    {"geo_genius.status --run-id", Status, ["--run-id", @probe_uuid], "import_run_status"},
    {"geo_genius.status --collection", Status, ["--collection", "demo"], "import_run_status"}
  ]

  # The smallest argument list each task accepts, so the shared parsing cases
  # below vary exactly one thing at a time.
  @minimal [
    {Import, ["--collection", "demo", "--release", "r1"]},
    {Publish, ["--release-id", @probe_uuid]},
    {Rollback, ["--collection", "demo"]},
    {SweepStaging, []},
    {Status, ["--run-id", @probe_uuid]}
  ]

  # Installs GeoGenius a second time, for real, at `gg_alt`.
  #
  # The `option forwarding` probe below drives a prefix installed nowhere and
  # asserts the statement arrives carrying it. That is a fail-fast seam: it is
  # structurally blind to every call site downstream of the first statement
  # that fails at a fake prefix. Two forwarding sites sit behind a *successful*
  # first call -- `await/3` after `import/1` in geo_genius.import, and
  # `published_release/2` after `import_runs/2` in geo_genius.status -- and no
  # uninstalled prefix can ever reach them. A prefix that is genuinely
  # installed can. One full run through `gg_alt` exercises all ten sites at
  # once, and will keep reaching new ones as this surface grows, which two more
  # hand-placed assertions would not.
  #
  # No configuration change is involved: this is a runtime install through the
  # same host migration wrapper `mix geo_genius.setup` generates. `config/` is
  # untouched.
  setup_all do
    TestRepo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{@alt_prefix}"))

    # `schema_migrations` is global to the repo -- the migrator deliberately
    # never receives `:prefix`, since that option would relocate the table into
    # the prefix being installed -- so the wrapper's row has to go first, or a
    # second install reports `:already_up` and installs nothing. The migrator
    # writes the row back, leaving the table as every other module finds it.
    unrecord_wrapper()

    :ok =
      AppEnv.with_env(:test_prefix, @alt_prefix, fn ->
        Ecto.Migrator.up(TestRepo, migration_version(), GeoGenius.TestMigrations.Install,
          log: false
        )
      end)

    assert GeoGenius.Migration.installed_version(TestRepo, @alt_prefix) == 1

    on_exit(fn -> TestRepo.query!(~s(DROP SCHEMA IF EXISTS "#{@alt_prefix}" CASCADE)) end)

    :ok
  end

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    unique = System.unique_integer([:positive])
    cache_dir = Path.join(System.tmp_dir!(), "geo_genius_task_cache_#{unique}")
    AppEnv.put(:cache_dir, cache_dir)
    AppEnv.restore_on_exit(:manifest_paths)
    AppEnv.restore_on_exit(:runner)

    on_exit(fn ->
      Mix.shell(shell)
      File.rm_rf(cache_dir)
    end)

    :ok
  end

  describe "argument parsing" do
    # Each of these asserts the message's payload, not its prefix: the option
    # the operator actually typed, the positional they actually passed, the
    # prefix string they actually gave. A message that names none of them
    # still exits non-zero and tells them nothing.
    test "rejects an unknown option, naming it" do
      for {task, args} <- @minimal do
        exception = assert_raise Mix.Error, fn -> task.parse_args(args ++ ["--nope"]) end
        assert exception.message == "unknown option: --nope"
      end
    end

    test "rejects an unexpected positional argument, naming it" do
      for {task, args} <- @minimal do
        exception = assert_raise Mix.Error, fn -> task.parse_args(args ++ ["extra"]) end
        assert exception.message == "unexpected positional argument: extra"
      end
    end

    test "rejects an invalid prefix, naming it" do
      for {task, args} <- @minimal do
        exception =
          assert_raise Mix.Error, fn -> task.parse_args(args ++ ["--prefix", "Bad Prefix"]) end

        assert exception.message == ~s(invalid PostgreSQL prefix: "Bad Prefix")
      end
    end

    test "parses an explicit repo and prefix" do
      for {task, args} <- @minimal do
        parsed = task.parse_args(args ++ ["--repo", "MyApp.Repo", "--prefix", "custom_geo"])

        assert parsed.repo == MyApp.Repo
        assert parsed.prefix == "custom_geo"
      end
    end

    test "defaults the repo to nil and the prefix to geo_genius" do
      for {task, args} <- @minimal do
        parsed = task.parse_args(args)

        assert parsed.repo == nil
        assert parsed.prefix == "geo_genius"
      end
    end

    test "geo_genius.import names the required option that is missing" do
      no_collection = assert_raise Mix.Error, fn -> Import.parse_args(["--release", "r1"]) end
      assert no_collection.message == "--collection is required"

      no_release = assert_raise Mix.Error, fn -> Import.parse_args(["--collection", "demo"]) end
      assert no_release.message == "--release is required"
    end

    test "geo_genius.import parses its full happy path" do
      assert %{
               repo: MyApp.Repo,
               prefix: "custom_geo",
               collection: "demo",
               release: "r1",
               publish: true,
               await: true,
               timeout: 1234,
               owner: "deploy-1"
             } =
               Import.parse_args([
                 "--collection",
                 "demo",
                 "--release",
                 "r1",
                 "--publish",
                 "--await",
                 "--timeout",
                 "1234",
                 "--owner",
                 "deploy-1",
                 "--repo",
                 "MyApp.Repo",
                 "--prefix",
                 "custom_geo"
               ])
    end

    # An absent --timeout parses to nil rather than to a number of its own:
    # a value here would win against `GeoGenius.await/3`'s resolution and put
    # `config :geo_genius, :await_timeout` out of the task's reach entirely.
    test "geo_genius.import defaults its flags and leaves the await timeout unresolved" do
      assert %{publish: false, await: false, timeout: nil, owner: nil} =
               Import.parse_args(["--collection", "demo", "--release", "r1"])
    end

    test "geo_genius.publish rejects --release-id together with --collection or --release" do
      for extra <- [["--collection", "demo"], ["--release", "r1"]] do
        exception =
          assert_raise Mix.Error, fn ->
            Publish.parse_args(["--release-id", @probe_uuid] ++ extra)
          end

        # Naming both options is the payload: "mutually exclusive" alone
        # leaves the operator to guess which two.
        assert exception.message ==
                 "--release-id and --collection are mutually exclusive; pass one or the other"
      end
    end

    test "geo_genius.publish requires one of its two selections, in full" do
      exception = assert_raise Mix.Error, fn -> Publish.parse_args([]) end

      assert exception.message ==
               "--release-id is required, or --collection and --release together"

      missing_release =
        assert_raise Mix.Error, fn -> Publish.parse_args(["--collection", "demo"]) end

      assert missing_release.message == "--release is required alongside --collection"

      missing_collection =
        assert_raise Mix.Error, fn -> Publish.parse_args(["--release", "r1"]) end

      assert missing_collection.message == "--collection is required alongside --release"
    end

    test "geo_genius.publish parses both selections" do
      assert %{release_id: @probe_uuid, collection: nil, release: nil} =
               Publish.parse_args(["--release-id", @probe_uuid])

      assert %{release_id: nil, collection: "demo", release: "r1"} =
               Publish.parse_args(["--collection", "demo", "--release", "r1"])
    end

    test "geo_genius.rollback requires a collection and defaults --yes to false" do
      no_collection = assert_raise Mix.Error, fn -> Rollback.parse_args([]) end
      assert no_collection.message == "--collection is required"

      assert %{collection: "demo", yes?: false} = Rollback.parse_args(["--collection", "demo"])
      assert %{yes?: true} = Rollback.parse_args(["--collection", "demo", "--yes"])
    end

    test "geo_genius.sweep_staging defaults --yes to false" do
      assert %{yes?: false} = SweepStaging.parse_args([])
      assert %{yes?: true} = SweepStaging.parse_args(["--yes"])
    end

    test "geo_genius.status requires exactly one of --run-id and --collection" do
      missing = assert_raise Mix.Error, fn -> Status.parse_args([]) end
      assert missing.message == "--run-id is required, or --collection"

      both =
        assert_raise Mix.Error, fn ->
          Status.parse_args(["--run-id", @probe_uuid, "--collection", "demo"])
        end

      assert both.message ==
               "--run-id and --collection are mutually exclusive; pass one or the other"

      assert %{run_id: @probe_uuid, collection: nil} =
               Status.parse_args(["--run-id", @probe_uuid])

      assert %{run_id: nil, collection: "demo"} = Status.parse_args(["--collection", "demo"])
    end
  end

  describe "repo resolution" do
    # The last `Mix.raise` in the five tasks' reachable set: every task calls
    # `MixHelpers.resolve_repo/1`, and with `--repo` omitted and the host
    # configuring no `:ecto_repos` this is what the operator is told. Nothing
    # exercised it, because this project always configures one.
    test "a task with no --repo and no configured :ecto_repos names both ways out" do
      AppEnv.put(:ecto_repos, [])

      exception =
        assert_raise Mix.Error, fn -> Status.run(~w(--run-id #{@probe_uuid})) end

      assert exception.message ==
               "no Ecto Repo is configured for :geo_genius; pass --repo or configure :ecto_repos"
    end
  end

  describe "option forwarding" do
    test "every task forwards its --repo and --prefix into the call it makes" do
      AppEnv.put(:manifest_paths, [manifest_search_path()])

      unmet =
        for {name, task, args, fragment} <- @forwarding,
            not forwarded?(task, args, fragment),
            do: name

      # Parsing is not forwarding. A task that parses `--prefix gg_task_probe`
      # and then calls its API function with no opts operates on the default
      # prefix, which exists in this database and looks identical from the
      # outside. Only the SQL that actually reached a repo tells them apart,
      # and only a non-default prefix makes the difference visible.
      assert unmet == []
    end

    test "geo_genius.publish forwards --timeout onto the publication statement" do
      # `publish_release` re-runs `verify_release` inside itself, so a task
      # that parses `--timeout` and then calls `GeoGenius.publish/2` without
      # it leaves an operator with no way to publish a release too large for
      # the default. Only the options that reached the repo tell the two
      # apart.
      assert publish_timeout(["--timeout", "7777"]) == 7_777
      assert publish_timeout([]) == 900_000
    end
  end

  describe "end to end" do
    setup :inline_runner

    test "geo_genius.import imports, awaits, publishes, and geo_genius.status reports it" do
      {collection, release} = seeded_manifest!()

      Import.run(
        ~w(--collection #{collection} --release #{release} --await --publish) ++ repo_args()
      )

      assert_receive {:mix_shell, :info, [completion]}
      assert completion =~ "completed"

      run_id = run_id!(context(), collection, release)
      assert %GeoGenius.ImportRun{status: "completed"} = GeoGenius.status(run_id, @repo_opts)

      release_id = GeoGenius.published_release(collection, @repo_opts)
      assert is_binary(release_id)

      Status.run(~w(--run-id #{run_id}) ++ repo_args())
      assert_receive {:mix_shell, :info, [one_run]}
      assert one_run =~ run_id
      assert one_run =~ "completed"

      # A second run in the same collection. With one run a listing that
      # rendered only its head, or reversed the order the catalog returned,
      # is indistinguishable from a correct one.
      later = seeded_release!(collection)
      Import.run(~w(--collection #{collection} --release #{later} --await) ++ repo_args())
      assert_receive {:mix_shell, :info, [_later_completion]}
      later_run_id = run_id!(context(), collection, later)

      Status.run(~w(--collection #{collection}) ++ repo_args())
      assert_receive {:mix_shell, :info, [listing]}
      assert listing =~ run_id
      assert listing =~ later_run_id
      assert listing =~ release_id

      # The brief specifies "every run for a collection newest first", and
      # `Catalog.import_runs/2` orders by `started_at DESC`. Nothing pinned
      # that the task preserves that order on the way to the operator.
      assert position!(listing, later_run_id) < position!(listing, run_id)
    end

    test "geo_genius.status reports a run id the catalog does not carry" do
      Status.run(~w(--run-id #{@probe_uuid}) ++ repo_args())

      assert_receive {:mix_shell, :info, [message]}
      assert message == "GeoGenius has no import run #{@probe_uuid} at prefix geo_genius"
    end

    test "geo_genius.publish publishes by collection and release key" do
      {collection, release} = seeded_manifest!()
      Import.run(~w(--collection #{collection} --release #{release} --await) ++ repo_args())
      assert_receive {:mix_shell, :info, [_completion]}

      # A newer release in the same collection, deliberately left unpublished.
      # `Catalog.import_runs/2` returns newest first, so with one run -- or
      # while publishing the newest -- a resolver that ignored `--release`
      # entirely and took the head of the list would agree with the fixture.
      # Publishing the *older* key is what separates them.
      later = seeded_release!(collection)
      Import.run(~w(--collection #{collection} --release #{later} --await) ++ repo_args())
      assert_receive {:mix_shell, :info, [_later_completion]}

      later_id = release_id!(context(), collection, later)

      assert GeoGenius.published_release(collection, @repo_opts) == nil

      # A collection that has published nothing reads as "none", not as the
      # `nil` an `inspect/1` would render.
      Status.run(~w(--collection #{collection}) ++ repo_args())
      assert_receive {:mix_shell, :info, [unpublished]}
      assert unpublished =~ "published release: none"

      Publish.run(~w(--collection #{collection} --release #{release}) ++ repo_args())
      assert_receive {:mix_shell, :info, [published]}

      release_id = GeoGenius.published_release(collection, @repo_opts)
      assert is_binary(release_id)
      assert published =~ release_id
      assert release_id == release_id!(context(), collection, release)
      assert release_id != later_id

      # And a published one reads bare. `=~` alone tolerates the quoted form
      # `inspect/1` produces, so the quoted form is refuted explicitly.
      Status.run(~w(--collection #{collection}) ++ repo_args())
      assert_receive {:mix_shell, :info, [listing]}
      assert listing =~ "published release: #{release_id}"
      refute listing =~ ~s("#{release_id}")
    end

    test "geo_genius.publish exits non-zero for a release key nothing imported, naming it" do
      {collection, _release} = seeded_manifest!()

      exception =
        assert_raise Mix.Error, fn ->
          Publish.run(~w(--collection #{collection} --release nope) ++ repo_args())
        end

      # The one error path in the five tasks that echoes back both values the
      # operator typed. Dropping them leaves a deploy log saying some release
      # was not imported, with no statement of which key or which collection
      # was looked for -- the likeliest causes being a typo in --release or
      # the wrong --prefix.
      assert exception.message ==
               "GeoGenius has no imported release nope in collection #{collection}"
    end

    # A task's error message is the whole of what the operator has to work
    # from, and `MixHelpers.reason_message/1` is what turns three different
    # failure shapes -- an exception, a plain string, an arbitrary runner
    # reason -- into one readable line. Collapsing it to `inspect/1` leaves
    # every one of these paths still exiting non-zero while printing an Elixir
    # struct dump or a quote-escaped string, so each of the three call sites
    # asserts its payload, not just its prefix.
    test "geo_genius.import exits non-zero for a manifest that cannot be resolved, naming why" do
      exception =
        assert_raise Mix.Error, ~r/GeoGenius import failed/, fn ->
          Import.run(~w(--collection gg_no_such_collection --release r1) ++ repo_args())
        end

      assert exception.message =~ ~s(no manifest for collection "gg_no_such_collection")
      refute exception.message =~ "%GeoGenius.ManifestError{"
    end

    test "geo_genius.publish exits non-zero for a release id the catalog does not carry" do
      exception =
        assert_raise Mix.Error, ~r/GeoGenius publish failed/, fn ->
          Publish.run(~w(--release-id #{@probe_uuid}) ++ repo_args())
        end

      assert exception.message =~ "publish_release failed"
      assert exception.message =~ "release #{@probe_uuid} does not exist"
      refute exception.message =~ "%GeoGenius.CatalogError{"
    end

    test "geo_genius.rollback rolls a collection back to its previous release" do
      {collection, first} = seeded_manifest!()

      Import.run(
        ~w(--collection #{collection} --release #{first} --await --publish) ++ repo_args()
      )

      assert_receive {:mix_shell, :info, [_first]}

      first_id = GeoGenius.published_release(collection, @repo_opts)

      second = seeded_release!(collection)

      Import.run(
        ~w(--collection #{collection} --release #{second} --await --publish) ++ repo_args()
      )

      assert_receive {:mix_shell, :info, [_second]}

      assert GeoGenius.published_release(collection, @repo_opts) != first_id

      Rollback.run(~w(--collection #{collection} --yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [rolled_back]}

      assert GeoGenius.published_release(collection, @repo_opts) == first_id

      assert rolled_back ==
               "GeoGenius rolled collection #{collection} back to release #{first_id}"
    end

    test "geo_genius.rollback exits non-zero for a collection the catalog does not carry" do
      exception =
        assert_raise Mix.Error, ~r/GeoGenius rollback failed/, fn ->
          Rollback.run(~w(--collection gg_no_such_collection --yes) ++ repo_args())
        end

      # The plain-string clause. `inspect/1` here would wrap the whole reason
      # in quotes and escape the ones inside it.
      assert exception.message =~ ~s(collection "gg_no_such_collection" does not exist)
    end

    test "geo_genius.sweep_staging drops every staging table left behind by a finished run" do
      leaks = leaked_staging!(2)

      SweepStaging.run(~w(--yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [dropped]}

      remaining = Staging.leaked(context())
      listed = listed_tables(dropped)

      # The sweep drops every leaked table at the prefix, not only the two this
      # test created, so the count it prints is not this test's to predict: an
      # import another test left mid-flight puts a third table in the same
      # window. The count is held against the tables the message itself lists
      # instead. That still catches both mutations the pair is here for -- a
      # hard-coded count disagrees with a listing of two, and a count taken
      # before a drop that stopped partway disagrees with the shorter listing
      # that drop produced.
      assert reported_count(dropped) == length(listed)
      assert length(listed) >= length(leaks)

      # Asserted per table rather than against the count, which is derived from
      # the list the task decided to drop and so agrees with itself even when
      # the drop stopped after the first element.
      for {run_id, table} <- leaks do
        assert table in listed
        refute staging_table?("geo_genius", table)
        refute Enum.any?(remaining, fn {id, _table} -> id == run_id end)
      end
    end

    test "geo_genius.sweep_staging drops a staging table whose run row is gone" do
      ctx = context()
      {collection, _release_id, run_id} = ImportFixture.claim_run!(ctx)
      table = Staging.create(ctx, run_id)
      on_exit(fn -> TestRepo.query!(~s(DROP TABLE IF EXISTS "geo_genius"."#{table}")) end)

      # Remove the run row and leave its table standing. Nothing that starts
      # from import_run can see this table: there is no status to read and no
      # row to join to, so it is unreclaimable by anything but a scan that
      # starts from pg_class.
      ImportFixture.teardown!(collection)

      assert staging_table?("geo_genius", table)

      assert %Postgrex.Result{rows: [[0]]} =
               TestRepo.query!("SELECT count(*) FROM geo_genius.import_run WHERE id = $1", [
                 Ecto.UUID.dump!(run_id)
               ])

      assert Enum.any?(Staging.leaked(ctx), fn {id, name} -> id == run_id and name == table end),
             "a staging table with no import_run row must still be reported as leaked"

      SweepStaging.run(~w(--yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [dropped]}

      assert dropped =~ table
      refute staging_table?("geo_genius", table)
    end

    test "geo_genius.sweep_staging drops nothing without --yes" do
      ctx = context()
      {_collection, _release_id, run_id} = ImportFixture.claim_run!(ctx)
      table = Staging.create(ctx, run_id)
      Catalog.advance_import(ctx, run_id, "completed", %{})
      on_exit(fn -> TestRepo.query!(~s(DROP TABLE IF EXISTS "geo_genius"."#{table}")) end)

      SweepStaging.run(repo_args())
      assert_receive {:mix_shell, :info, [preview]}

      assert preview =~ "Pass --yes to drop them"
      assert preview =~ table

      assert staging_table?("geo_genius", table),
             "the preview must not drop anything"
    end

    test "geo_genius.sweep_staging leaves a still-running run's staging table alone" do
      ctx = context()
      {_collection, _release_id, run_id} = ImportFixture.claim_run!(ctx)
      table = Staging.create(ctx, run_id)
      on_exit(fn -> TestRepo.query!(~s(DROP TABLE IF EXISTS "geo_genius"."#{table}")) end)

      # The run is still `pending`: its staging table is the landing area the
      # import is about to fill, and dropping it would destroy work in flight.
      SweepStaging.run(~w(--yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [_swept]}

      assert staging_table?("geo_genius", table)
    end

    test "geo_genius.sweep_staging names what it already dropped when the sweep fails partway" do
      # Clear anything an earlier test left behind, so the two below are the
      # whole leaked set and the "1 of 2" reading is unambiguous.
      SweepStaging.run(~w(--yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [_cleared]}

      leaked_staging!(2)
      assert [{_id_a, table_a}, {_id_b, table_b}] = Staging.leaked(context())

      # Both drops issue identical SQL and differ only in a bound run id, so
      # the seam counts matches rather than matching text. The first drop
      # commits; the second fails.
      RecordingRepo.fail_on("drop_staging", after: 1)

      exception =
        assert_raise Mix.Error, fn ->
          SweepStaging.run(~w(--yes) ++ probe_repo_args())
        end

      # A sweep that stopped partway has already dropped everything before the
      # table it stopped on. Raising the driver's reason alone reads as a sweep
      # that did nothing and sends an operator looking for a table that is gone.
      assert exception.message =~ "dropped 1 of 2 leaked staging table(s)"
      assert exception.message =~ "Already dropped:"
      assert exception.message =~ table_a
      refute exception.message =~ table_b
    end

    test "geo_genius.sweep_staging claims nothing dropped when the first drop fails" do
      SweepStaging.run(~w(--yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [_cleared]}

      leaked_staging!(2)
      assert [{_id_a, table_a}, {_id_b, table_b}] = Staging.leaked(context())

      RecordingRepo.fail_on("drop_staging")

      exception =
        assert_raise Mix.Error, fn ->
          SweepStaging.run(~w(--yes) ++ probe_repo_args())
        end

      # The count alone does not separate this from the partial case: a
      # message that always appends the section would print an empty
      # "Already dropped:" heading claiming work that never happened.
      assert exception.message =~ "dropped 0 of 2 leaked staging table(s)"
      refute exception.message =~ "Already dropped:"
      refute exception.message =~ table_a
      refute exception.message =~ table_b
    end

    test "geo_genius.sweep_staging reports nothing to do when no table leaked" do
      # The suite shares one database, so anything already leaked is swept
      # first; what this pins is the empty-set message, not the empty set.
      SweepStaging.run(~w(--yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [_swept]}

      SweepStaging.run(~w(--yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [message]}
      assert message == "GeoGenius found no leaked staging tables at prefix geo_genius"
    end
  end

  describe "geo_genius.status rendering" do
    # Nothing else in this suite ever drives the task against a run that has
    # not finished: status, owner, attempt and the two keys are read through
    # the API, never through the surface whose whole job is to render them. A
    # `describe/1` hard-coding "completed", or reading `attempt` where it means
    # `status`, or swapping the two keys, is invisible without these.
    test "renders each run's own status, for runs in several non-terminal states" do
      ctx = context()

      for status <- ~w(pending downloading normalizing verifying) do
        {collection, release, run_id} = claim_probe_run!(ctx)
        if status != "pending", do: Catalog.advance_import(ctx, run_id, status, %{})

        Status.run(~w(--run-id #{run_id}) ++ repo_args())
        assert_receive {:mix_shell, :info, [line]}

        assert line =~ run_id
        assert line =~ " #{status} "
        refute line =~ "completed"
        assert line =~ "#{collection}/#{release}"
        assert line =~ "owner gg-probe-owner"
        assert line =~ "via gg-probe-backend"

        # The seventh rendered field. It is what separates a run that is stuck
        # from one that just started, which is most of the reason to look at a
        # non-terminal run at all, and it is the field a `completed_at`-for-
        # `started_at` slip would silently swap.
        assert line =~ "started #{GeoGenius.status(run_id, @repo_opts).started_at}"
      end
    end

    test "renders a run's own attempt number and a failed run as failed" do
      ctx = context()
      {_collection, release_id, first_run} = claim_probe_run!(ctx, :with_release_id)
      Catalog.fail_import(ctx, first_run, %{"reason" => "probe failure"})

      retry =
        Catalog.begin_or_resume_import(ctx, release_id, %{
          owner: "gg-retry-owner",
          runner_backend: "gg-probe-backend",
          stale_after_seconds: 300
        })

      assert retry != first_run

      Status.run(~w(--run-id #{first_run}) ++ repo_args())
      assert_receive {:mix_shell, :info, [failed_line]}
      assert failed_line =~ " failed "
      refute failed_line =~ "completed"
      assert failed_line =~ "attempt 1"
      assert failed_line =~ "owner gg-probe-owner"

      # Two runs of one release: `attempt` can only be right if it is read off
      # the run being rendered, not off a constant or a neighbouring field.
      Status.run(~w(--run-id #{retry}) ++ repo_args())
      assert_receive {:mix_shell, :info, [retry_line]}
      assert retry_line =~ "attempt 2"
      assert retry_line =~ "owner gg-retry-owner"
    end

    test "reports a collection that has no runs and nothing published" do
      collection = "gg_empty_#{System.unique_integer([:positive])}"

      Catalog.upsert_collection(context(), %{
        key: collection,
        name: collection,
        description: nil,
        requires_geometry: false
      })

      on_exit(fn -> ImportFixture.teardown!(collection) end)

      Status.run(~w(--collection #{collection}) ++ repo_args())
      assert_receive {:mix_shell, :info, [listing]}

      # The report's own first line. It is how an operator confirms they read
      # the install they meant to, and it can be deleted whole -- or render
      # the prefix where the collection was meant -- without any other
      # assertion in the suite noticing.
      assert listing =~ "Collection #{collection} at prefix geo_genius"
      assert listing =~ "no import runs"
      assert listing =~ "published release: none"
    end
  end

  describe "rollback depth" do
    setup :inline_runner

    # Ruling FJ: the fixture must exceed the arity of the distinction under
    # test, not merely exceed one. With two publications "roll back to the
    # previous release" and "roll back to the oldest release" name the same
    # release and no assertion can separate them. Three can.
    test "geo_genius.rollback returns to the previous release, not the oldest" do
      {collection, first} = seeded_manifest!()
      first_id = import_and_publish!(collection, first)

      second = seeded_release!(collection)
      second_id = import_and_publish!(collection, second)

      third = seeded_release!(collection)
      third_id = import_and_publish!(collection, third)

      assert Enum.uniq([first_id, second_id, third_id]) == [first_id, second_id, third_id]
      assert GeoGenius.published_release(collection, @repo_opts) == third_id

      Rollback.run(~w(--collection #{collection} --yes) ++ repo_args())
      assert_receive {:mix_shell, :info, [rolled_back]}

      assert GeoGenius.published_release(collection, @repo_opts) == second_id
      assert GeoGenius.published_release(collection, @repo_opts) != first_id
      assert rolled_back =~ second_id
      refute rolled_back =~ first_id
    end

    test "geo_genius.rollback reports a committed rollback whose confirmation read failed " <>
           "rather than exiting non-zero" do
      {collection, first} = seeded_manifest!()
      first_id = import_and_publish!(collection, first)

      second = seeded_release!(collection)
      second_id = import_and_publish!(collection, second)

      assert GeoGenius.published_release(collection, @repo_opts) == second_id

      # The rollback commits; the read naming the release it landed on fails.
      # `Mix.raise` here would exit non-zero for a rollback that already moved
      # the publication, and a deploy script retrying on exit code would roll
      # the collection back a second step.
      RecordingRepo.fail_on("published_release($1)")

      assert Rollback.run(~w(--collection #{collection} --yes) ++ probe_repo_args()) == :ok

      assert_receive {:mix_shell, :error, [message]}
      assert message =~ "rolled collection"
      assert message =~ "but reading the release it now publishes failed"

      assert GeoGenius.published_release(collection, @repo_opts) == first_id
    end
  end

  describe "--await on a run that fails" do
    setup :inline_runner

    # The brief specifies that `--await` "exits non-zero through `Mix.raise/1`
    # on a failed or timed-out run". Only the timed-out half was pinned, and
    # this is the half that matters to a deploy gate: an import that ran and
    # failed reported success.
    test "geo_genius.import exits non-zero for a run that finished failed, naming why" do
      {collection, release} = seeded_manifest!(corrupt: true)

      exception =
        assert_raise Mix.Error, fn ->
          Import.run(
            ~w(--collection #{collection} --release #{release} --await --publish) ++ repo_args()
          )
        end

      run_id = run_id!(context(), collection, release)
      assert GeoGenius.status(run_id, @repo_opts).status == "failed"
      assert exception.message =~ "GeoGenius import run #{run_id} failed"

      # Exiting non-zero is half the gate; the other half is the reason, which
      # is the whole of what the person who gets paged has to work from. The
      # corrupt fixture makes `Pipeline.Artifacts` record a stable,
      # fixture-specific message, so the payload can be asserted rather than
      # only its prefix.
      assert exception.message =~ "does not match its manifest"
      assert GeoGenius.status(run_id, @repo_opts).error != nil

      # `--publish` is carried through to the runner, so this is a real
      # assertion about the failure path: a run that WAS asked to publish, and
      # failed before it could, must leave the collection unpublished.
      assert GeoGenius.published_release(collection, @repo_opts) == nil
    end
  end

  describe "--yes gating" do
    setup :inline_runner

    test "geo_genius.rollback without --yes changes nothing" do
      {collection, first} = seeded_manifest!()

      Import.run(
        ~w(--collection #{collection} --release #{first} --await --publish) ++ repo_args()
      )

      assert_receive {:mix_shell, :info, [_first]}

      second = seeded_release!(collection)

      Import.run(
        ~w(--collection #{collection} --release #{second} --await --publish) ++ repo_args()
      )

      assert_receive {:mix_shell, :info, [_second]}

      second_id = GeoGenius.published_release(collection, @repo_opts)

      Rollback.run(~w(--collection #{collection}) ++ repo_args())
      assert_receive {:mix_shell, :info, [preview]}

      assert preview =~ "Pass --yes"
      assert preview =~ "currently publishes #{second_id}"
      refute preview =~ ~s("#{second_id}")
      assert GeoGenius.published_release(collection, @repo_opts) == second_id
    end

    test "geo_genius.sweep_staging without --yes drops nothing and previews every leak" do
      leaks = leaked_staging!(2)

      SweepStaging.run(repo_args())
      assert_receive {:mix_shell, :info, [preview]}

      assert preview =~ "Pass --yes"
      assert preview =~ "#{length(leaks)} leaked staging table(s)"

      for {run_id, table} <- leaks do
        assert preview =~ "#{table} (run #{run_id})"
        assert staging_table?("geo_genius", table)
      end
    end
  end

  describe "--await" do
    setup :noop_runner

    @tag timeout: 20_000
    test "geo_genius.import forwards --timeout into await/3 rather than its own default" do
      {collection, release} = seeded_manifest!()

      started = System.monotonic_time(:millisecond)

      exception =
        assert_raise Mix.Error, fn ->
          Import.run(
            ~w(--collection #{collection} --release #{release} --await --timeout 300) ++
              repo_args()
          )
        end

      elapsed = System.monotonic_time(:millisecond) - started

      # NoopRunner never advances the run, so this call can only end by
      # timing out. A task that parses --timeout and then calls
      # `GeoGenius.await(run_id)` waits the 300_000ms default instead, which
      # is invisible in the message and invisible in the outcome -- the run
      # times out either way. Elapsed time is the only witness.
      run_id = run_id!(context(), collection, release)
      assert exception.message == "GeoGenius import run #{run_id} did not finish within 300ms"
      assert elapsed < 10_000
    end

    @tag timeout: 20_000
    test "geo_genius.import honours the configured await timeout when --timeout is absent" do
      {collection, release} = seeded_manifest!()

      Application.put_env(:geo_genius, :await_timeout, 300)
      on_exit(fn -> Application.delete_env(:geo_genius, :await_timeout) end)

      started = System.monotonic_time(:millisecond)

      exception =
        assert_raise Mix.Error, fn ->
          Import.run(~w(--collection #{collection} --release #{release} --await) ++ repo_args())
        end

      elapsed = System.monotonic_time(:millisecond) - started

      # A task carrying a default of its own passes it to `await/3` as an
      # explicit argument, which wins the resolution -- so the configured
      # value never applies and the wait runs to the library ceiling instead.
      run_id = run_id!(context(), collection, release)
      assert exception.message == "GeoGenius import run #{run_id} did not finish within 300ms"
      assert elapsed < 10_000
    end

    test "geo_genius.import forwards --owner onto the claimed run" do
      {collection, release} = seeded_manifest!()

      Import.run(
        ~w(--collection #{collection} --release #{release} --owner gg-probe) ++ repo_args()
      )

      assert_receive {:mix_shell, :info, [enqueued]}
      run_id = run_id!(context(), collection, release)

      # Without --await the task returns as soon as the run is handed to a
      # runner that may be executing on another node. NoopRunner never
      # advances it, so the run is demonstrably still `pending` here: a
      # message that said "completed" would be a false success report on the
      # default path of the task that starts imports.
      assert enqueued == "GeoGenius enqueued import run #{run_id}"
      assert GeoGenius.status(run_id, @repo_opts).status == "pending"
      assert GeoGenius.status(run_id, @repo_opts).owner == "gg-probe"
    end

    test "geo_genius.import defaults --owner to the node name" do
      {collection, release} = seeded_manifest!()

      Import.run(~w(--collection #{collection} --release #{release}) ++ repo_args())
      assert_receive {:mix_shell, :info, [_enqueued]}

      run_id = run_id!(context(), collection, release)
      assert GeoGenius.status(run_id, @repo_opts).owner == to_string(node())
    end
  end

  describe "a second real install" do
    setup :inline_runner

    test "one full run through gg_alt reaches every forwarded call site" do
      # Every real host has `config :geo_genius, :repo` set, and it is what a
      # dropped `repo:` silently falls back to. Pointing it at a repo that
      # cannot serve a query from this process turns that fallback from
      # "happens to be the same repo" into a loud failure, so `repo:`
      # forwarding is pinned positively rather than by the ambient key
      # happening to be unset.
      AppEnv.put(:repo, GeoGenius.SandboxedRepo)

      {collection, first} = seeded_manifest!()

      # geo_genius.import -- import/1, and await/3 behind a successful import/1.
      Import.run(
        ~w(--collection #{collection} --release #{first} --await --timeout 5000 --publish) ++
          alt_args()
      )

      assert_receive {:mix_shell, :info, [completed]}
      assert completed =~ "completed"

      run_id = run_id!(alt_context(), collection, first)
      assert GeoGenius.status(run_id, @alt_opts).status == "completed"

      # The run exists only at gg_alt. An `await/3` polling the default install
      # would never observe it and would time out instead of returning here.
      assert GeoGenius.status(run_id, @repo_opts) == nil

      first_id = GeoGenius.published_release(collection, @alt_opts)
      assert is_binary(first_id)
      assert GeoGenius.published_release(collection, @repo_opts) == nil

      # geo_genius.status --run-id
      Status.run(~w(--run-id #{run_id}) ++ alt_args())
      assert_receive {:mix_shell, :info, [one_run]}
      assert one_run =~ run_id
      assert one_run =~ "completed"

      # geo_genius.status --collection -- import_runs/2, and published_release/2
      # behind it. `published_release/2` returns NULL for a collection the
      # catalog does not carry, so reading the default install here prints
      # "none" rather than raising: only the id itself distinguishes them.
      Status.run(~w(--collection #{collection}) ++ alt_args())
      assert_receive {:mix_shell, :info, [listing]}
      assert listing =~ "Collection #{collection} at prefix #{@alt_prefix}"
      refute listing =~ "at prefix geo_genius"
      assert listing =~ run_id
      assert listing =~ first_id

      # geo_genius.publish, by collection and release key.
      second = seeded_release!(collection)

      Import.run(
        ~w(--collection #{collection} --release #{second} --await --timeout 5000) ++ alt_args()
      )

      assert_receive {:mix_shell, :info, [_second_completed]}

      Publish.run(~w(--collection #{collection} --release #{second}) ++ alt_args())
      assert_receive {:mix_shell, :info, [published]}

      second_id = GeoGenius.published_release(collection, @alt_opts)
      assert is_binary(second_id)
      assert second_id != first_id
      assert published =~ second_id

      # geo_genius.rollback, dry run then --yes.
      Rollback.run(~w(--collection #{collection}) ++ alt_args())
      assert_receive {:mix_shell, :info, [preview]}
      assert preview =~ second_id
      assert GeoGenius.published_release(collection, @alt_opts) == second_id

      Rollback.run(~w(--collection #{collection} --yes) ++ alt_args())
      assert_receive {:mix_shell, :info, [rolled_back]}
      assert rolled_back =~ first_id
      assert GeoGenius.published_release(collection, @alt_opts) == first_id

      # geo_genius.sweep_staging -- leaked/1 and the drop behind it. Both runs
      # finished, so both leak; one leak could not tell a sweep that drops
      # every table from one that drops the first.
      second_run_id = run_id!(alt_context(), collection, second)
      tables = Enum.map([run_id, second_run_id], &Staging.create(alt_context(), &1))
      assert Enum.all?(tables, &staging_table?(@alt_prefix, &1))

      SweepStaging.run(~w(--yes) ++ alt_args())
      assert_receive {:mix_shell, :info, [swept]}

      for table <- tables do
        assert swept =~ table
        refute staging_table?(@alt_prefix, table)
      end
    end
  end

  defp inline_runner(_context) do
    AppEnv.put(:runner, Runners.Inline)
    :ok
  end

  defp noop_runner(_context) do
    AppEnv.put(:runner, NoopRunner)
    :ok
  end

  defp context, do: Context.new(@repo_opts)

  defp alt_context, do: Context.new(@alt_opts)

  defp repo_args, do: ["--repo", "GeoGenius.TestRepo", "--prefix", "geo_genius"]

  # The same installed prefix, reached through the seam that can be told to
  # fail one named statement. Every query still runs against GeoGenius.TestRepo.
  defp probe_repo_args, do: ["--repo", @probe_repo, "--prefix", "geo_genius"]

  defp alt_args, do: ["--repo", "GeoGenius.TestRepo", "--prefix", @alt_prefix]

  # Derives the install migration's version from its filename rather than
  # hard-coding the timestamp, matching `GeoGenius.MigrationTest`.
  defp migration_version do
    ["test", "support", "migrations", "*_install_geo_genius.exs"]
    |> Path.join()
    |> Path.wildcard()
    |> List.first()
    |> Path.basename()
    |> String.split("_", parts: 2)
    |> List.first()
    |> String.to_integer()
  end

  # Removes only this wrapper's row. The table belongs to the host, and a
  # blanket delete would erase migrations these tests never applied.
  defp unrecord_wrapper do
    TestRepo.query!("DELETE FROM schema_migrations WHERE version = $1", [migration_version()])
  end

  defp publish_timeout(extra) do
    RecordingRepo.recorded()

    catch_error(
      Publish.run(
        ["--release-id", @probe_uuid, "--repo", @probe_repo, "--prefix", @probe_prefix] ++ extra
      )
    )

    RecordingRepo.recorded()
    |> RecordingRepo.options_for("publish_release")
    |> Keyword.get(:timeout)
  end

  defp forwarded?(task, args, fragment) do
    RecordingRepo.recorded()

    # Every probe runs against a prefix nothing is installed at, so the call
    # always raises; which exception it raises is the API's business, not this
    # test's. What the probe reads is the statement that reached the repo
    # before it failed.
    catch_error(task.run(args ++ ["--repo", @probe_repo, "--prefix", @probe_prefix]))

    Enum.any?(RecordingRepo.recorded(), fn {sql, _opts} ->
      sql =~ fragment and sql =~ @probe_prefix
    end)
  end

  defp manifest_search_path, do: Path.expand("../../support/manifests", __DIR__)

  # Writes a manifest onto the search path and seeds its artifact into the
  # cache, so an import driven entirely through `mix geo_genius.import` --
  # which takes a collection and a release key, never a manifest struct --
  # completes without reaching for a downloader.
  defp seeded_manifest!(opts \\ []) do
    unique = System.unique_integer([:positive])
    collection = "gg_task_#{unique}"

    dir = Path.join(System.tmp_dir!(), "geo_genius_task_manifests_#{unique}")
    File.mkdir_p!(Path.join(dir, collection))
    AppEnv.put(:manifest_paths, [dir])

    on_exit(fn ->
      File.rm_rf(dir)
      ImportFixture.teardown!(collection)
    end)

    {collection, seeded_release!(collection, opts)}
  end

  defp seeded_release!(collection, opts \\ []) do
    [dir] = Application.fetch_env!(:geo_genius, :manifest_paths)
    release = "r#{System.unique_integer([:positive])}"
    document = manifest_document(collection, release)

    dir
    |> Path.join("#{collection}/#{release}.json")
    |> File.write!(Jason.encode!(document))

    seed_cache!(collection, release, Keyword.get(opts, :corrupt, false))
    release
  end

  # `corrupt?` seeds bytes that do not match the manifest's own checksum, so
  # the run genuinely fails in its downloading phase and reaches a terminal
  # `failed` status -- the only way to drive a real, catalog-recorded failure
  # through a task that takes a collection key and nothing else.
  defp seed_cache!(collection, release, corrupt?) do
    path =
      [collection, "#{collection}:territories", release, "territories.geojson"]
      |> Cache.key()
      |> FileSystem.path([])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, if(corrupt?, do: "not the reviewed bytes", else: ImportFixture.body()))
  end

  defp import_and_publish!(collection, release) do
    Import.run(
      ~w(--collection #{collection} --release #{release} --await --publish) ++ repo_args()
    )

    assert_receive {:mix_shell, :info, [completion]}
    assert completion =~ "completed"
    release_id!(context(), collection, release)
  end

  defp manifest_document(collection, release) do
    body = ImportFixture.body()

    %{
      "collection" => collection,
      "collection_name" => "Operational Task Fixture",
      "release" => release,
      "provider" => "geojson",
      "requires_geometry" => false,
      "source_date" => "2026-01-15",
      "authorities" => [%{"key" => collection, "name" => "Operational Task Operations"}],
      "area_types" => [%{"key" => "territory", "rank" => 100}],
      "sources" => [
        %{
          "source_key" => "#{collection}:territories",
          "provider" => "geojson",
          "license" => "CC0-1.0",
          "release_key" => release,
          "source_date" => "2026-01-15",
          "artifacts" => [
            %{
              "logical_name" => "territories.geojson",
              "operator_supplied" => true,
              "format" => "geojson",
              "required" => true,
              "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower),
              "bytes" => byte_size(body)
            }
          ]
        }
      ],
      "options" => %{
        "code_property" => "territory_id",
        "name_property" => "territory_name",
        "area_type" => "territory",
        "attribute_properties" => ["short_name", "population"]
      }
    }
  end

  # A claimed run with a distinctive collection, release, owner and backend, so
  # a rendered line can be checked field by field rather than only for the run
  # id -- which the task's own "no import run <id>" fallback also contains.
  defp claim_probe_run!(ctx, shape \\ :keys) do
    unique = System.unique_integer([:positive])
    collection = "gg_status_#{unique}"
    release = "rel_#{unique}"

    {^collection, release_id, run_id} =
      ImportFixture.claim_run!(ctx,
        collection: collection,
        release: release,
        owner: "gg-probe-owner",
        runner_backend: "gg-probe-backend"
      )

    case shape do
      :keys -> {collection, release, run_id}
      :with_release_id -> {collection, release_id, run_id}
    end
  end

  defp release_id!(ctx, collection, release) do
    %GeoGenius.ImportRun{release_id: release_id} =
      ctx
      |> Catalog.import_runs(collection)
      |> Enum.find(&(&1.release_key == release))

    release_id
  end

  defp run_id!(ctx, collection, release) do
    %GeoGenius.ImportRun{run_id: run_id} =
      ctx
      |> Catalog.import_runs(collection)
      |> Enum.find(&(&1.release_key == release))

    run_id
  end

  # Seeds `count` leaked staging tables, never one. A fixture of cardinality 1
  # cannot distinguish "drops every leak" from "drops a leak", and the second
  # of those still prints `length(leaked)` and every name -- a truthful-looking
  # report of N reclaimed tables with N-1 still standing, which is the exact
  # failure this task exists to prevent.
  defp leaked_staging!(count) when count > 1 do
    ctx = context()

    Enum.map(1..count, fn _seeded ->
      {_collection, _release_id, run_id} = ImportFixture.claim_run!(ctx)
      table = Staging.create(ctx, run_id)
      Catalog.advance_import(ctx, run_id, "completed", %{})

      on_exit(fn -> TestRepo.query!(~s(DROP TABLE IF EXISTS "geo_genius"."#{table}")) end)

      assert Enum.any?(Staging.leaked(ctx), fn {id, _table} -> id == run_id end)
      {run_id, table}
    end)
  end

  # The count `mix geo_genius.sweep_staging` reports, and the table names it
  # lists beneath that count -- one `  <table> (run <uuid>)` line each.
  defp reported_count(message) do
    [count] =
      Regex.run(~r/dropped (\d+) leaked staging table\(s\)/, message, capture: :all_but_first)

    String.to_integer(count)
  end

  defp listed_tables(message) do
    ~r/^ +(staging_[0-9a-f]{32}) \(run /m
    |> Regex.scan(message, capture: :all_but_first)
    |> List.flatten()
  end

  # The byte offset of `needle` in `text`, for asserting the order two ids
  # appear in rather than merely that both do.
  defp position!(text, needle) do
    {index, _length} = :binary.match(text, needle)
    index
  end

  defp staging_table?(prefix, table) do
    %Postgrex.Result{rows: [[exists?]]} =
      TestRepo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{table}"])

    exists?
  end
end
