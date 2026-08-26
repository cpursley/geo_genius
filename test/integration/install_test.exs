defmodule GeoGenius.InstallIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias GeoGenius.AppEnv
  alias GeoGenius.TestRepo

  # Every named function GeoGenius installs, grouped roughly by the layer it
  # serves. A complete install must expose all of them, not merely "some
  # tables exist".
  @required_functions ~w(
    assert_extensions publication_release_is_publishable create_release_partitions
    drop_release_partitions partition_lock_key classify_relation relation_lock_key
    publication_lock_key
    upsert_collection upsert_authority upsert_area_type upsert_area put_area_name put_area_code
    put_boundary put_area_in_release put_relation rebuild_relations verify_release
    publish_release rollback_publication retire_releases begin_or_resume_import
    heartbeat_import advance_import fail_import areas_for_point areas_for_geometry
    areas_near areas_by_code search_areas children_of ancestors_of related_areas
    resolve assert_release_mutable assert_area_in_collection area_codes_json release_at
    upsert_source upsert_source_release put_artifact record_artifact_observation
    open_release attach_source_release staging_table_name create_staging drop_staging
    analyze_release published_release
  )

  setup do
    for prefix <- ~w(geo_genius custom_geo) do
      TestRepo.query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end

    # `schema_migrations` is global to the repo (the migrator never receives
    # `:prefix` -- see `install/1` below), so it is shared across every
    # prefix under test and must be reset between tests, or installing at a
    # second prefix after a first silently no-ops as `:already_up`. Only this
    # module's own wrapper version is removed: the table belongs to the host,
    # and a blanket delete would erase migrations these tests never applied.
    unrecord_wrapper()

    :ok
  end

  # Regardless of run order, guarantee `geo_genius` is installed at the
  # default prefix once every test in this module has finished, matching
  # `GeoGenius.MigrationTest`'s convention -- the pgTAP suite
  # (./test/pgtap/run.sh) depends on it being present.
  setup_all do
    on_exit(fn ->
      AppEnv.with_env(:test_prefix, "geo_genius", fn ->
        TestRepo.query!(~s(DROP SCHEMA IF EXISTS "geo_genius" CASCADE))
        TestRepo.query!(~s(DROP SCHEMA IF EXISTS "custom_geo" CASCADE))
        unrecord_wrapper()
        TestRepo.query!(~s(CREATE SCHEMA IF NOT EXISTS "geo_genius"))

        Ecto.Migrator.up(TestRepo, migration_version(), GeoGenius.TestMigrations.Install,
          log: false
        )
      end)
    end)

    :ok
  end

  # NEVER pass `:prefix` to the migrator here. That option relocates Ecto's
  # own `schema_migrations` table INTO the target prefix, and this
  # migration's `down/0` drops that prefix, so the DROP deadlocks against
  # its own bookkeeping. `GeoGenius.TestMigrations.Install` reads its target
  # prefix from application environment instead.
  defp install(prefix) do
    AppEnv.put(:test_prefix, prefix)
    TestRepo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
    Ecto.Migrator.up(TestRepo, migration_version(), GeoGenius.TestMigrations.Install, log: false)
  end

  defp uninstall(prefix) do
    AppEnv.put(:test_prefix, prefix)

    Ecto.Migrator.down(TestRepo, migration_version(), GeoGenius.TestMigrations.Install,
      log: false
    )
  end

  # The timestamp `mix ecto.gen.migration` generated for
  # `test/support/migrations/*_install_geo_genius.exs`, read from the
  # filename rather than hard-coded.
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

  defp unrecord_wrapper do
    TestRepo.query!("DELETE FROM schema_migrations WHERE version = $1", [migration_version()])
  end

  defp table_names(prefix) do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1",
        [prefix]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp view_names(prefix) do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT table_name FROM information_schema.views WHERE table_schema = $1",
        [prefix]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp function_names(prefix) do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT p.proname
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = $1
        """,
        [prefix]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp type_names(prefix) do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT t.typname
          FROM pg_type t
          JOIN pg_namespace n ON n.oid = t.typnamespace
         WHERE n.nspname = $1
        """,
        [prefix]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp relkind(prefix, name) do
    case TestRepo.query!(
           """
           SELECT c.relkind
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
           """,
           [prefix, name]
         ).rows do
      [[kind]] -> kind
      [] -> nil
    end
  end

  defp relation_count(prefix) do
    %{rows: [[count]]} =
      TestRepo.query!(
        "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1",
        [prefix]
      )

    count
  end

  defp schema_exists?(prefix) do
    %{rows: rows} = TestRepo.query!("SELECT 1 FROM pg_namespace WHERE nspname = $1", [prefix])
    rows != []
  end

  test "installs, reports its version, and uninstalls at the default prefix" do
    :ok = install("geo_genius")

    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") ==
             GeoGenius.Migration.current_version()

    :ok = uninstall("geo_genius")
    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") == 0
  end

  # EctoEvolver substitutes $SCHEMA$ with an ESCAPED identifier, so a prefix
  # that is a SQL reserved word arrives quoted. Any SQL that treats the
  # substitution as a bare name -- a string literal, an identifier spliced into
  # a quoted DROP -- breaks only at such a prefix, and at no other.
  test "installs and uninstalls at a prefix that requires quoting" do
    TestRepo.query!(~s(DROP SCHEMA IF EXISTS "user" CASCADE))

    :ok = install("user")

    assert GeoGenius.Migration.installed_version(TestRepo, "user") ==
             GeoGenius.Migration.current_version()

    assert "area" in table_names("user")

    :ok = uninstall("user")

    refute schema_exists?("user"), "rollback left the quoted-prefix schema behind"
  end

  # GeoGenius may be installed into a schema the host already uses. Rolling
  # the migration back drops the objects it created; taking the schema itself
  # with a CASCADE would destroy the host's unrelated tables alongside them.
  test "rolling back leaves a shared schema and its foreign objects in place" do
    TestRepo.query!(~s(CREATE SCHEMA IF NOT EXISTS "custom_geo"))
    TestRepo.query!(~s|CREATE TABLE "custom_geo"."host_owned" (id integer PRIMARY KEY)|)

    :ok = install("custom_geo")
    :ok = uninstall("custom_geo")

    assert schema_exists?("custom_geo"), "rollback dropped a schema it does not exclusively own"
    assert "host_owned" in table_names("custom_geo"), "rollback destroyed a host-owned table"
    refute "area" in table_names("custom_geo"), "rollback left GeoGenius tables behind"
    assert GeoGenius.Migration.installed_version(TestRepo, "custom_geo") == 0

    TestRepo.query!(~s(DROP SCHEMA "custom_geo" CASCADE))
  end

  # Dropping the schema is only half an uninstall: the host's migration row
  # has to go with it, or ecto.migrate skips the wrapper as already applied
  # and the catalog can never be reinstalled.
  test "a catalog can be reinstalled after its schema and migration row are removed" do
    :ok = install("geo_genius")

    TestRepo.query!(~s(DROP SCHEMA "geo_genius" CASCADE))
    unrecord_wrapper()

    :ok = install("geo_genius")

    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") ==
             GeoGenius.Migration.current_version()
  end

  test "a full install exposes a representative object from every layer" do
    :ok = install("geo_genius")

    tables = table_names("geo_genius")
    assert "area" in tables, "missing identity table area"
    assert "release" in tables, "missing release table"
    assert "publication" in tables, "missing publication table"
    assert "boundary" in tables, "missing partitioned spatial table boundary"
    assert relkind("geo_genius", "boundary") == "p", "boundary is not a partitioned table"

    assert "published_areas" in view_names("geo_genius"), "missing published_areas view"
    assert "area_match" in type_names("geo_genius"), "missing area_match type"

    names = function_names("geo_genius")

    for required <- @required_functions do
      assert required in names, "missing function #{required}"
    end
  end

  test "installs at a custom prefix without touching the default one" do
    :ok = install("custom_geo")

    assert GeoGenius.Migration.installed_version(TestRepo, "custom_geo") ==
             GeoGenius.Migration.current_version()

    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") == 0
    assert relation_count("custom_geo") > 10
    refute schema_exists?("geo_genius")
  end

  test "installs at the default prefix without touching a custom one" do
    :ok = install("geo_genius")

    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") ==
             GeoGenius.Migration.current_version()

    assert GeoGenius.Migration.installed_version(TestRepo, "custom_geo") == 0
    refute schema_exists?("custom_geo")
  end

  test "the full API is present under a custom prefix" do
    :ok = install("custom_geo")

    names = function_names("custom_geo")

    for required <- @required_functions do
      assert required in names, "missing function #{required}"
    end
  end

  test "uninstall removes every relation, function, type, and the schema itself" do
    :ok = install("custom_geo")
    :ok = uninstall("custom_geo")

    assert GeoGenius.Migration.installed_version(TestRepo, "custom_geo") == 0
    assert relation_count("custom_geo") == 0
    assert MapSet.size(function_names("custom_geo")) == 0
    assert MapSet.size(type_names("custom_geo")) == 0
    refute schema_exists?("custom_geo")
  end

  test "running the install migration twice is a no-op that leaves the version unchanged" do
    :ok = install("geo_genius")

    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") ==
             GeoGenius.Migration.current_version()

    # Ecto's own migration bookkeeping (`schema_migrations`) already recorded
    # this version, so the migrator skips re-running `GeoGenius.Migration.up/1`
    # entirely and reports `:already_up` rather than raising a
    # duplicate-object error.
    assert Ecto.Migrator.up(TestRepo, migration_version(), GeoGenius.TestMigrations.Install,
             log: false
           ) == :already_up

    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") ==
             GeoGenius.Migration.current_version()
  end

  test "GeoGenius.verify/2 passes against a freshly installed schema and fails otherwise" do
    :ok = install("geo_genius")

    assert GeoGenius.verify(TestRepo, prefix: "geo_genius") == :ok

    assert {:error, reasons} = GeoGenius.verify(TestRepo, prefix: "custom_geo")
    assert Enum.any?(reasons, &(&1 =~ "not installed"))
  end
end
