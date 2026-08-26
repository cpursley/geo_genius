defmodule GeoGenius.MigrationTest do
  use ExUnit.Case, async: false

  alias GeoGenius.AppEnv
  alias GeoGenius.TestRepo

  # Reset-only per test: each test drops both prefixes and installs whichever
  # one it needs. ExUnit randomizes test order, so whichever test runs last
  # decides what's left installed when the module finishes -- fine for the
  # assertions in this file, but the pgTAP suite (./test/pgtap/run.sh) always
  # expects the default `geo_genius` prefix to be installed. The `setup_all`
  # below guarantees that regardless of run order or seed.
  setup do
    TestRepo.query!(~s(DROP SCHEMA IF EXISTS "geo_genius" CASCADE))
    TestRepo.query!(~s(DROP SCHEMA IF EXISTS "custom_geo" CASCADE))

    # `schema_migrations` lives in the repo's default schema (not per-prefix,
    # since the migrator no longer receives `:prefix`), so it is shared across
    # every prefix under test and must be reset between tests too.
    TestRepo.query(~s(DELETE FROM "schema_migrations"))

    :ok
  end

  # Runs once, after every test in this module has finished (in whatever
  # order ExUnit picked), regardless of which test ran last. Reinstalls the
  # schema at the default `geo_genius` prefix so the pgTAP suite's
  # precondition -- "geo_genius is installed" -- is guaranteed rather than
  # incidental to test order.
  setup_all do
    on_exit(fn ->
      AppEnv.with_env(:test_prefix, "geo_genius", fn ->
        TestRepo.query!(~s(DROP SCHEMA IF EXISTS "geo_genius" CASCADE))
        TestRepo.query!(~s(DELETE FROM "schema_migrations"))
        TestRepo.query!(~s(CREATE SCHEMA IF NOT EXISTS "geo_genius"))

        Ecto.Migrator.up(TestRepo, migration_version(), GeoGenius.TestMigrations.Install,
          log: false
        )
      end)
    end)

    :ok
  end

  defp migrate(prefix) do
    AppEnv.put(:test_prefix, prefix)
    TestRepo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))

    Ecto.Migrator.up(TestRepo, migration_version(), GeoGenius.TestMigrations.Install, log: false)
  end

  # Derives the migration version from the install migration's filename
  # (`<version>_install_geo_genius.exs`) instead of hard-coding the
  # timestamp, so a future regeneration of that file cannot desynchronize
  # from the version actually passed to `Ecto.Migrator`.
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

  test "installs at the default prefix and records the version" do
    :ok = migrate("geo_genius")
    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") == 1
  end

  test "installs at a non-default prefix" do
    :ok = migrate("custom_geo")
    assert GeoGenius.Migration.installed_version(TestRepo, "custom_geo") == 1
    assert GeoGenius.Migration.installed_version(TestRepo, "geo_genius") == 0
  end

  test "assert_extensions raises for a missing extension" do
    :ok = migrate("geo_genius")

    assert_raise Postgrex.Error, ~r/required PostgreSQL extension/, fn ->
      TestRepo.query!("SELECT geo_genius.assert_extensions(ARRAY['no_such_extension'])")
    end
  end
end
