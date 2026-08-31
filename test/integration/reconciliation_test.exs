defmodule GeoGenius.ReconciliationIntegrationTest do
  use ExUnit.Case, async: false

  defmodule HostReconciliationMigration do
    use Ecto.Migration

    @target "sha256:0bb7f017525771075a7cb4dfed5568d1b14edb261e8fadbb82d14acbfba53fb1"

    def up do
      GeoGenius.Migration.reconcile(
        prefix: Application.fetch_env!(:geo_genius, :test_reconciliation_prefix),
        from: :legacy_v01_aebc28a,
        to: @target
      )
    end

    def down do
      GeoGenius.Migration.reconcile(
        prefix: Application.fetch_env!(:geo_genius, :test_reconciliation_prefix),
        from: @target,
        to: :legacy_v01_aebc28a
      )
    end
  end

  @moduletag :integration

  alias EctoEvolver.Adapters.Postgres
  alias GeoGenius.{AppEnv, LegacyV01Fixture, Migration, TestRepo, TestSimpleSQL}
  alias Mix.Tasks.GeoGenius.CheckSchema

  @reviewed_v01 "sha256:8c5adea2c1fab08fdbc67137ff99ea0864c69a3dff5a3952dd9d6e62d971ab25"

  setup do
    prefix = "gg_reconcile_#{System.unique_integer([:positive])}"
    escaped = Postgres.escape_identifier(prefix)

    TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)

    TestSimpleSQL.query!(TestRepo, Migration.render_sql(prefix: prefix, from: 0, to: 1))

    on_exit(fn -> TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false) end)

    %{prefix: prefix, escaped: escaped}
  end

  test "a frozen historical v01 is version 1 but incompatible and read-only diagnostics name the remedy",
       %{prefix: prefix} do
    LegacyV01Fixture.apply!(TestRepo, prefix)

    assert Migration.installed_version(TestRepo, prefix) == 1

    assert %{
             status: :legacy_unmarked,
             compatible?: false,
             installed_revision: :legacy_v01_aebc28a,
             remedy: remedy
           } = Migration.contract_status(TestRepo, prefix)

    assert remedy =~ "--from legacy_v01_aebc28a"
    assert remedy =~ "--to #{Migration.current_contract_revision()}"
    refute relation_exists?(prefix, "geo_genius_contract")
    refute function_exists?(prefix, "put_boundaries")
  end

  test "the forward reconciliation API is explicit and renders pinned transactional SQL", %{
    prefix: prefix
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)

    sql =
      Migration.render_reconciliation_sql(
        prefix: prefix,
        from: :legacy_v01_aebc28a,
        to: Migration.current_contract_revision(),
        transaction: true
      )

    assert String.starts_with?(sql, "BEGIN;")
    assert String.ends_with?(sql, "COMMIT;\n")
    assert sql =~ Postgres.escape_identifier(prefix)
    assert sql =~ Migration.current_contract_revision()
    refute sql =~ "$SCHEMA$"
    refute sql =~ "--SPLIT--"
  end

  test "a safe prefix requiring identifier quoting reconciles successfully" do
    prefix = "gg-reconcile-#{System.unique_integer([:positive])}"
    escaped = Postgres.escape_identifier(prefix)
    TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)

    try do
      TestSimpleSQL.query!(TestRepo, Migration.render_sql(prefix: prefix, from: 0, to: 1))

      LegacyV01Fixture.apply!(TestRepo, prefix)

      prefix
      |> reconciliation_sql(:legacy_v01_aebc28a, Migration.current_contract_revision())
      |> execute_sql!()

      assert %{status: :compatible} = Migration.contract_status(TestRepo, prefix)
    after
      TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)
    end
  end

  test "forward reconciliation is atomic, preserves catalog data, and is idempotent", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    TestRepo.query!("INSERT INTO #{escaped}.collection (key, name) VALUES ('kept', 'Kept')")

    sql =
      Migration.render_reconciliation_sql(
        prefix: prefix,
        from: :legacy_v01_aebc28a,
        to: Migration.current_contract_revision()
      )

    TestSimpleSQL.query!(TestRepo, sql)
    TestSimpleSQL.query!(TestRepo, sql)

    assert %{status: :compatible, compatible?: true} = Migration.contract_status(TestRepo, prefix)

    assert [["kept", "Kept"]] =
             TestRepo.query!("SELECT key, name FROM #{escaped}.collection").rows

    assert function_exists?(prefix, "put_boundaries")
  end

  test "reverse reconciliation restores the frozen legacy identity without data loss", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    TestRepo.query!("INSERT INTO #{escaped}.collection (key, name) VALUES ('kept', 'Kept')")

    prefix
    |> reconciliation_sql(:legacy_v01_aebc28a, Migration.current_contract_revision())
    |> execute_sql!()

    prefix
    |> reconciliation_sql(Migration.current_contract_revision(), :legacy_v01_aebc28a)
    |> execute_sql!()

    assert %{status: :legacy_unmarked, installed_revision: :legacy_v01_aebc28a} =
             Migration.contract_status(TestRepo, prefix)

    assert [["kept", "Kept"]] =
             TestRepo.query!("SELECT key, name FROM #{escaped}.collection").rows

    refute relation_exists?(prefix, "geo_genius_contract")
    refute function_exists?(prefix, "put_boundaries")
  end

  test "reconciliation rejects unknown drift without mutating the schema", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    TestRepo.query!("INSERT INTO #{escaped}.collection (key, name) VALUES ('kept', 'Kept')")

    TestRepo.query!("""
    CREATE OR REPLACE FUNCTION #{escaped}.put_boundary(
      target_release_id uuid,
      target_area_key text,
      target_source_release_id uuid,
      input_geom geometry,
      simplify_tolerance double precision DEFAULT 0.0
    ) RETURNS void LANGUAGE plpgsql AS 'BEGIN NULL; END'
    """)

    error =
      TestRepo.checkout(fn ->
        error =
          assert_raise Postgrex.Error, fn ->
            prefix
            |> reconciliation_sql(:legacy_v01_aebc28a, Migration.current_contract_revision())
            |> execute_sql!()
          end

        TestRepo.query!("ROLLBACK", [], log: false)
        error
      end)

    assert error.postgres.code == :object_not_in_prerequisite_state
    assert error.postgres.message =~ "unknown or drifted"
    assert %{status: :drifted} = Migration.contract_status(TestRepo, prefix)
    assert [["kept"]] = TestRepo.query!("SELECT key FROM #{escaped}.collection").rows
    refute relation_exists?(prefix, "geo_genius_contract")
    refute function_exists?(prefix, "put_boundaries")
  end

  test "a failure after applying definitions rolls the entire reconciliation back", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    TestRepo.query!("INSERT INTO #{escaped}.collection (key, name) VALUES ('kept', 'Kept')")

    failing_sql =
      prefix
      |> reconciliation_sql(:legacy_v01_aebc28a, Migration.current_contract_revision())
      |> String.replace("COMMIT;\n", "SELECT 1 / 0;\n\nCOMMIT;\n")

    TestRepo.checkout(fn ->
      assert_raise Postgrex.Error, fn -> execute_sql!(failing_sql) end
      TestRepo.query!("ROLLBACK", [], log: false)
    end)

    assert %{status: :legacy_unmarked} = Migration.contract_status(TestRepo, prefix)
    assert [["kept"]] = TestRepo.query!("SELECT key FROM #{escaped}.collection").rows
    refute relation_exists?(prefix, "geo_genius_contract")
    refute function_exists?(prefix, "put_boundaries")
  end

  test "rendering is deterministic and refuses unpinned identities", %{prefix: prefix} do
    opts = [
      prefix: prefix,
      from: :legacy_v01_aebc28a,
      to: Migration.current_contract_revision()
    ]

    assert Migration.render_reconciliation_sql(opts) == Migration.render_reconciliation_sql(opts)

    assert_raise ArgumentError, ~r/unsupported GeoGenius contract identity/, fn ->
      Migration.render_reconciliation_sql(Keyword.put(opts, :from, "current"))
    end

    assert_raise ArgumentError, ~r/unsupported GeoGenius reconciliation edge/, fn ->
      Migration.render_reconciliation_sql(
        prefix: prefix,
        from: Migration.current_contract_revision(),
        to: Migration.current_contract_revision()
      )
    end
  end

  test "all pinned v01 contract edges render deterministic reconciliation SQL", %{
    prefix: prefix
  } do
    target = Migration.current_contract_revision()

    for {from, to} <- [
          {:legacy_v01_aebc28a, @reviewed_v01},
          {@reviewed_v01, :legacy_v01_aebc28a},
          {:legacy_v01_aebc28a, target},
          {target, :legacy_v01_aebc28a},
          {@reviewed_v01, target},
          {target, @reviewed_v01}
        ] do
      sql =
        Migration.render_reconciliation_sql(
          prefix: prefix,
          from: from,
          to: to,
          transaction: false
        )

      assert sql =~ revision_text(to)
      refute sql =~ "$SCHEMA$"
      refute sql =~ "--SPLIT--"
    end
  end

  test "all pinned v01 contract edges execute and preserve catalog data" do
    target = Migration.current_contract_revision()

    for {from, to, expected_status} <- [
          {:legacy_v01_aebc28a, @reviewed_v01, :reviewed_v01},
          {@reviewed_v01, :legacy_v01_aebc28a, :legacy_unmarked},
          {:legacy_v01_aebc28a, target, :compatible},
          {target, :legacy_v01_aebc28a, :legacy_unmarked},
          {@reviewed_v01, target, :compatible},
          {target, @reviewed_v01, :reviewed_v01}
        ] do
      prefix = "gg_reconcile_edge_#{System.unique_integer([:positive])}"
      escaped = Postgres.escape_identifier(prefix)
      TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)

      try do
        TestSimpleSQL.query!(TestRepo, Migration.render_sql(prefix: prefix, from: 0, to: 1))
        install_contract_identity!(prefix, from)
        TestRepo.query!("INSERT INTO #{escaped}.collection (key, name) VALUES ('kept', 'Kept')")

        prefix
        |> reconciliation_sql(from, to)
        |> execute_sql!()

        assert %{status: ^expected_status} = Migration.contract_status(TestRepo, prefix)

        assert [["kept", "Kept"]] =
                 TestRepo.query!("SELECT key, name FROM #{escaped}.collection").rows
      after
        TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)
      end
    end
  end

  test "preflight reports a version-one legacy contract without changing it", %{prefix: prefix} do
    LegacyV01Fixture.apply!(TestRepo, prefix)

    assert {:error, reasons} = GeoGenius.verify(TestRepo, prefix: prefix)
    assert Enum.any?(reasons, &(&1 =~ "legacy_v01_aebc28a"))
    assert Enum.any?(reasons, &(&1 =~ "geo_genius.reconciliation_sql"))
    assert %{status: :legacy_unmarked} = Migration.contract_status(TestRepo, prefix)
    refute relation_exists?(prefix, "geo_genius_contract")
    refute function_exists?(prefix, "put_boundaries")
  end

  test "check_schema exits nonzero on a version-one legacy contract without changing it", %{
    prefix: prefix
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Task.reenable("geo_genius.check_schema")
      Mix.Task.reenable("app.config")

      exception =
        assert_raise Mix.Error, fn ->
          CheckSchema.run(["--repo", "GeoGenius.TestRepo", "--prefix", prefix])
        end

      assert exception.message =~ "legacy_v01_aebc28a"
      assert exception.message =~ "geo_genius.reconciliation_sql"
      assert %{status: :legacy_unmarked} = Migration.contract_status(TestRepo, prefix)
      refute relation_exists?(prefix, "geo_genius_contract")
      refute function_exists?(prefix, "put_boundaries")
    after
      Mix.shell(shell)
    end
  end

  test "contract diagnostics classify malformed marker rows and columns as drift", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)

    malformed_views = [
      "SELECT 1::integer AS schema_version",
      """
      SELECT 1::integer AS schema_version,
             'wrong'::text AS contract_revision,
             ARRAY[]::text[] AS capabilities
       WHERE false
      """,
      """
      SELECT 1::integer AS schema_version,
             'wrong'::text AS contract_revision,
             ARRAY[]::text[] AS capabilities
      UNION ALL
      SELECT 1, 'also-wrong', ARRAY[]::text[]
      """
    ]

    for select <- malformed_views do
      TestRepo.query!("DROP VIEW IF EXISTS #{escaped}.geo_genius_contract")
      TestRepo.query!("CREATE VIEW #{escaped}.geo_genius_contract AS #{select}")

      assert %{status: :drifted, compatible?: false, installed_revision: nil} =
               Migration.contract_status(TestRepo, prefix)
    end
  end

  test "reconciliation rejects a malformed marker with the stable drift error before writes", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    TestRepo.query!("CREATE VIEW #{escaped}.geo_genius_contract AS SELECT 1 AS wrong_column")

    error =
      TestRepo.checkout(fn ->
        error =
          assert_raise Postgrex.Error, fn ->
            prefix
            |> reconciliation_sql(:legacy_v01_aebc28a, Migration.current_contract_revision())
            |> execute_sql!()
          end

        TestRepo.query!("ROLLBACK", [], log: false)
        error
      end)

    assert error.postgres.code == :object_not_in_prerequisite_state
    assert error.postgres.message =~ "unknown or drifted"
    assert relation_exists?(prefix, "geo_genius_contract")
    refute function_exists?(prefix, "put_boundaries")
  end

  test "legacy remedy shell-quotes broad safe PostgreSQL identifiers" do
    prefix = "gg reconcile; must-not-run"
    escaped = Postgres.escape_identifier(prefix)
    TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)

    try do
      Migration.render_sql(prefix: prefix, from: 0, to: 1)
      |> execute_sql!()

      LegacyV01Fixture.apply!(TestRepo, prefix)

      assert %{status: :legacy_unmarked, remedy: remedy} =
               Migration.contract_status(TestRepo, prefix)

      assert remedy =~ "--prefix 'gg reconcile; must-not-run'"
      refute remedy =~ "--prefix gg reconcile"
    after
      TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)
    end
  end

  test "a host-owned Ecto migration applies and reverses the literal contract edge", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    TestRepo.query!("INSERT INTO #{escaped}.collection (key, name) VALUES ('kept', 'Kept')")
    AppEnv.restore_on_exit(:test_reconciliation_prefix)
    Application.put_env(:geo_genius, :test_reconciliation_prefix, prefix)
    version = 90_000_000_000_000 + System.unique_integer([:positive])

    on_exit(fn ->
      TestRepo.query!("DELETE FROM schema_migrations WHERE version = $1", [version], log: false)
    end)

    assert :ok = Ecto.Migrator.up(TestRepo, version, HostReconciliationMigration, log: false)
    assert %{status: :compatible} = Migration.contract_status(TestRepo, prefix)
    assert [["kept"]] = TestRepo.query!("SELECT key FROM #{escaped}.collection").rows

    assert :ok = Ecto.Migrator.down(TestRepo, version, HostReconciliationMigration, log: false)
    assert %{status: :legacy_unmarked} = Migration.contract_status(TestRepo, prefix)
    assert [["kept"]] = TestRepo.query!("SELECT key FROM #{escaped}.collection").rows
  end

  defp relation_exists?(prefix, name) do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $1 AND c.relname = $2
        """,
        [prefix, name]
      )

    rows != []
  end

  defp function_exists?(prefix, name) do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = $1 AND p.proname = $2
        """,
        [prefix, name]
      )

    rows != []
  end

  defp reconciliation_sql(prefix, from, to) do
    Migration.render_reconciliation_sql(prefix: prefix, from: from, to: to)
  end

  defp execute_sql!(sql) do
    TestSimpleSQL.query!(TestRepo, sql)
  end

  defp install_contract_identity!(prefix, :legacy_v01_aebc28a) do
    LegacyV01Fixture.apply!(TestRepo, prefix)
  end

  defp install_contract_identity!(prefix, @reviewed_v01) do
    prefix
    |> reconciliation_sql(Migration.current_contract_revision(), @reviewed_v01)
    |> execute_sql!()
  end

  defp install_contract_identity!(_prefix, revision) do
    if revision == Migration.current_contract_revision() do
      :ok
    else
      raise ArgumentError, "unsupported test contract identity: #{inspect(revision)}"
    end
  end

  defp revision_text(:legacy_v01_aebc28a), do: "GeoGenius legacy contract verification failed"
  defp revision_text(revision), do: revision
end
