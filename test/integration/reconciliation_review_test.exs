defmodule GeoGenius.ReconciliationReviewIntegrationTest do
  use ExUnit.Case, async: false

  defmodule NonTransactionalHostMigration do
    use Ecto.Migration

    @disable_ddl_transaction true
    @target GeoGenius.Migration.current_contract_revision()

    def up do
      GeoGenius.Migration.reconcile(
        prefix: Application.fetch_env!(:geo_genius, :test_reconciliation_prefix),
        from: :legacy_v01_aebc28a,
        to: @target
      )
    end
  end

  @moduletag :integration

  alias EctoEvolver.Adapters.Postgres
  alias GeoGenius.{AppEnv, LegacyV01Fixture, Migration, TestRepo, TestSimpleSQL}

  @reviewed "sha256:8c5adea2c1fab08fdbc67137ff99ea0864c69a3dff5a3952dd9d6e62d971ab25"
  @target Migration.current_contract_revision()

  setup do
    prefix = "gg_contract_review_#{System.unique_integer([:positive])}"
    escaped = Postgres.escape_identifier(prefix)
    TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)
    install!(prefix)

    on_exit(fn -> TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false) end)

    %{prefix: prefix, escaped: escaped}
  end

  test "status fingerprints function execution properties, not only function bodies", %{
    prefix: prefix,
    escaped: escaped
  } do
    for mutation <- property_mutations(escaped) do
      assert {:error, :checked} =
               TestRepo.transaction(fn ->
                 TestRepo.query!(mutation, [], log: false)
                 assert %{status: :drifted, compatible?: false} = status(prefix)
                 TestRepo.rollback(:checked)
               end)
    end

    assert %{status: :compatible} = status(prefix)
  end

  test "status fingerprints area type geometry metadata, not only functions", %{
    prefix: prefix,
    escaped: escaped
  } do
    for mutation <- target_metadata_mutations(escaped) do
      assert {:error, :checked} =
               TestRepo.transaction(fn ->
                 run_mutation!(mutation)
                 seed_nullable_geometry_flag_if_possible(escaped, prefix)

                 assert %{status: :drifted, compatible?: false} = status(prefix)

                 TestRepo.rollback(:checked)
               end)
    end

    assert %{status: :compatible} = status(prefix)
  end

  test "status and reconciliation fingerprint the area type base relation identity",
       %{prefix: setup_prefix} do
    for source <- [:legacy_v01_aebc28a, @reviewed, @target],
        mutation <- area_type_relation_identity_mutations() do
      prefix = "#{setup_prefix}_#{source_name(source)}_#{System.unique_integer([:positive])}"
      escaped = Postgres.escape_identifier(prefix)
      TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)

      try do
        install_contract_identity!(prefix, source)
        mutation_sql = mutation.(escaped)

        assert {:error, :checked} =
                 TestRepo.transaction(fn ->
                   run_mutation!(mutation_sql)
                   assert %{status: :drifted, compatible?: false} = status(prefix)

                   TestRepo.rollback(:checked)
                 end)

        for {from, to} <- source_edges(source) do
          assert_drift_rejected(prefix, mutation_sql, from, to)
        end

        assert_restored_status(source, status(prefix))
      after
        TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)
      end
    end
  end

  test "forward reconciliation rejects legacy function-property drift before writes", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)

    for mutation <- property_mutations(escaped) do
      assert_drift_rejected(prefix, mutation, :legacy_v01_aebc28a, @target)
      assert %{status: :legacy_unmarked} = status(prefix)
      refute function_exists?(prefix, "put_boundaries")
    end
  end

  test "frozen legacy and reviewed function APIs are exact source identities",
       %{prefix: setup_prefix} do
    for source <- [:legacy_v01_aebc28a, @reviewed],
        mutation <- frozen_api_mutations() do
      prefix = "#{setup_prefix}_#{source_name(source)}_api_#{System.unique_integer([:positive])}"
      escaped = Postgres.escape_identifier(prefix)
      TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)

      try do
        install_contract_identity!(prefix, source)
        mutation_sql = mutation.(escaped)

        assert {:error, :checked} =
                 TestRepo.transaction(fn ->
                   run_mutation!(mutation_sql)
                   assert %{status: :drifted, compatible?: false} = status(prefix)

                   TestRepo.rollback(:checked)
                 end)

        for {from, to} <- source_edges(source) do
          assert_drift_rejected(prefix, mutation_sql, from, to)
        end

        assert_restored_status(source, status(prefix))
      after
        TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)
      end
    end
  end

  test "frozen legacy fixture preserves executable old area type and verifier APIs", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)

    assert %{status: :legacy_unmarked} = status(prefix)

    TestRepo.query!(
      """
      INSERT INTO #{escaped}.collection (key, name, requires_geometry)
      VALUES ('typed_catalog', 'Typed Catalog', true)
      """,
      [],
      log: false
    )

    TestRepo.query!(
      "SELECT #{escaped}.upsert_authority('typed_catalog', 'source_a', 'Source A')",
      [],
      log: false
    )

    assert [[area_type_id]] =
             TestRepo.query!(
               "SELECT #{escaped}.upsert_area_type('typed_catalog', 'bounded_zone', 10)",
               [],
               log: false
             ).rows

    assert is_binary(area_type_id)

    TestRepo.query!(
      "SELECT #{escaped}.upsert_area('typed_catalog', 'source_a', 'bounded_zone', 'A')",
      [],
      log: false
    )

    assert [[release_id]] =
             TestRepo.query!(
               "SELECT #{escaped}.open_release('typed_catalog', 'legacy_fixture_release', '{}'::jsonb, NULL::date)",
               [],
               log: false
             ).rows

    TestRepo.query!(
      """
      SELECT #{escaped}.put_area_in_release(
        $1,
        'source_a:bounded_zone:A',
        NULL::geography,
        '{}'::jsonb
      )
      """,
      [release_id],
      log: false
    )

    assert [[%{"ok" => false} = verification]] =
             TestRepo.query!(
               "SELECT #{escaped}.verify_release($1)",
               [release_id],
               log: false
             ).rows

    assert "1 areas lack a boundary" in verification["failures"]
  end

  test "forward reconciliation upgrades only exact legacy or reviewed absence of type metadata",
       %{
         prefix: setup_prefix
       } do
    for from <- [:legacy_v01_aebc28a, @reviewed] do
      prefix = "#{setup_prefix}_#{System.unique_integer([:positive])}"
      escaped = Postgres.escape_identifier(prefix)
      TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)

      try do
        install_contract_identity!(prefix, from)

        TestRepo.query!(
          "ALTER TABLE #{escaped}.area_type ADD COLUMN requires_geometry text",
          [],
          log: false
        )

        assert_drift_error(committed_reconciliation_error(prefix, from, @target))

        refute function_signature_exists?(
                 prefix,
                 "upsert_area_type",
                 "text, text, integer, boolean"
               )

        assert requires_geometry_column_type(prefix) == "text"
      after
        TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)
      end
    end
  end

  test "reverse reconciliation rejects target function-property drift before writes", %{
    prefix: prefix,
    escaped: escaped
  } do
    for mutation <- property_mutations(escaped) do
      assert_drift_rejected(prefix, mutation, @target, :legacy_v01_aebc28a)
      assert %{status: :compatible} = status(prefix)
      assert function_exists?(prefix, "put_boundaries")
    end
  end

  test "schema version in an otherwise target-shaped marker is part of both edge preconditions",
       %{
         prefix: prefix,
         escaped: escaped
       } do
    mutation = target_marker_sql(escaped, 999)

    assert_drift_rejected(prefix, mutation, :legacy_v01_aebc28a, @target)
    assert_drift_rejected(prefix, mutation, @target, :legacy_v01_aebc28a)
    assert %{status: :compatible} = status(prefix)
  end

  test "target-idempotent forward reconciliation rejects target drift before DDL", %{
    prefix: prefix,
    escaped: escaped
  } do
    for mutation <- target_idempotence_drift_mutations(escaped) do
      assert_drift_rejected(prefix, mutation, :legacy_v01_aebc28a, @target)
      assert %{status: :compatible} = status(prefix)
    end
  end

  test "target to reviewed preflight hardens version and marker shape before writes", %{
    prefix: prefix,
    escaped: escaped
  } do
    for mutation <- target_to_reviewed_preflight_mutations(escaped) do
      assert_drift_rejected(prefix, mutation, @target, @reviewed)
      assert %{status: :compatible} = status(prefix)
      assert relation_kind(prefix, "geo_genius_contract") == "v"
      assert requires_geometry_column_type(prefix) == "boolean"
    end
  end

  test "an extra same-name overload is drift and blocks both reconciliation directions", %{
    prefix: prefix,
    escaped: escaped
  } do
    overload =
      "CREATE FUNCTION #{escaped}.put_boundary(integer) RETURNS void LANGUAGE sql AS 'SELECT'"

    assert {:error, :checked} =
             TestRepo.transaction(fn ->
               TestRepo.query!(overload, [], log: false)
               assert %{status: :drifted} = status(prefix)
               TestRepo.rollback(:checked)
             end)

    LegacyV01Fixture.apply!(TestRepo, prefix)
    assert_drift_rejected(prefix, overload, :legacy_v01_aebc28a, @target)
    refute function_signature_exists?(prefix, "put_boundary", "integer")

    install_target_functions!(prefix)
    assert_drift_rejected(prefix, overload, @target, :legacy_v01_aebc28a)
    refute function_signature_exists?(prefix, "put_boundary", "integer")
  end

  test "a non-view contract-name collision is drift and is rejected before writes", %{
    prefix: prefix,
    escaped: escaped
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    TestRepo.query!("CREATE TABLE #{escaped}.geo_genius_contract (value integer)", [], log: false)

    assert %{status: :drifted} = status(prefix)

    error = reconciliation_error(prefix, nil, :legacy_v01_aebc28a, @target)
    assert_drift_error(error)
    assert relation_kind(prefix, "geo_genius_contract") == "r"
    refute function_exists?(prefix, "put_boundaries")
  end

  test "renderer treats placeholder-token substrings in valid prefixes as data" do
    for token <- ["$SCHEMA$", "$PREFIX_LITERAL$", "$TARGET_REVISION$"] do
      prefix = "gg_#{token}_#{System.unique_integer([:positive])}"
      escaped = Postgres.escape_identifier(prefix)
      TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)

      try do
        install!(prefix)
        LegacyV01Fixture.apply!(TestRepo, prefix)

        result =
          TestRepo.checkout(fn ->
            try do
              prefix
              |> reconciliation_sql(:legacy_v01_aebc28a, @target)
              |> execute_sql!()

              :ok
            rescue
              error in Postgrex.Error ->
                TestRepo.query!("ROLLBACK", [], log: false)
                {:error, error}
            end
          end)

        assert :ok = result
        assert %{status: :compatible} = status(prefix)
      after
        TestRepo.query!("DROP SCHEMA IF EXISTS #{escaped} CASCADE", [], log: false)
      end
    end
  end

  test "Ecto reconciliation refuses a migration with DDL transactions disabled", %{
    prefix: prefix
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)
    AppEnv.restore_on_exit(:test_reconciliation_prefix)
    Application.put_env(:geo_genius, :test_reconciliation_prefix, prefix)
    version = 91_000_000_000_000 + System.unique_integer([:positive])

    on_exit(fn ->
      TestRepo.query!("DELETE FROM schema_migrations WHERE version = $1", [version], log: false)
    end)

    assert_raise ArgumentError, ~r/requires an active transactional Ecto migration/, fn ->
      Ecto.Migrator.up(TestRepo, version, NonTransactionalHostMigration, log: false)
    end

    assert %{status: :legacy_unmarked} = status(prefix)
    refute function_exists?(prefix, "put_boundaries")
  end

  test "Ecto reconciliation refuses calls outside an Ecto migration transaction", %{
    prefix: prefix
  } do
    LegacyV01Fixture.apply!(TestRepo, prefix)

    assert_raise ArgumentError, ~r/requires an active transactional Ecto migration/, fn ->
      Migration.reconcile(prefix: prefix, from: :legacy_v01_aebc28a, to: @target)
    end

    assert %{status: :legacy_unmarked} = status(prefix)
  end

  defp property_mutations(escaped) do
    [
      "ALTER FUNCTION #{escaped}.publish_release(uuid) SECURITY DEFINER",
      "ALTER FUNCTION #{escaped}.publish_release(uuid) STABLE",
      "ALTER FUNCTION #{escaped}.publish_release(uuid) SET search_path TO public",
      """
      CREATE OR REPLACE FUNCTION #{escaped}.publish_release(target_release_id uuid)
      RETURNS uuid
      LANGUAGE sql
      VOLATILE
      SECURITY INVOKER
      SET search_path = pg_catalog, public, #{escaped}
      AS 'SELECT target_release_id'
      """
    ]
  end

  defp target_metadata_mutations(escaped) do
    [
      "ALTER TABLE #{escaped}.area_type DROP COLUMN requires_geometry",
      "ALTER TABLE #{escaped}.area_type ALTER COLUMN requires_geometry DROP NOT NULL",
      "ALTER TABLE #{escaped}.area_type ALTER COLUMN requires_geometry SET DEFAULT true",
      "ALTER TABLE #{escaped}.area_type ALTER COLUMN requires_geometry TYPE text USING requires_geometry::text"
    ]
  end

  defp area_type_relation_identity_mutations do
    [
      fn escaped ->
        "ALTER TABLE #{escaped}.area_type RENAME TO area_type_shadow"
      end,
      fn escaped ->
        [
          "ALTER TABLE #{escaped}.area_type RENAME TO area_type_shadow",
          "CREATE VIEW #{escaped}.area_type AS SELECT * FROM #{escaped}.area_type_shadow"
        ]
      end,
      fn escaped ->
        [
          "ALTER TABLE #{escaped}.area_type RENAME TO area_type_shadow",
          "CREATE MATERIALIZED VIEW #{escaped}.area_type AS SELECT * FROM #{escaped}.area_type_shadow"
        ]
      end,
      fn escaped ->
        [
          "ALTER TABLE #{escaped}.area_type RENAME TO area_type_shadow",
          """
          CREATE TABLE #{escaped}.area_type (
            id uuid,
            collection_id uuid,
            key text,
            rank integer,
            requires_geometry boolean
          ) PARTITION BY LIST (key)
          """
        ]
      end
    ]
  end

  defp frozen_api_mutations do
    [
      fn escaped ->
        """
        CREATE OR REPLACE FUNCTION #{escaped}.verify_release(target_release_id uuid)
        RETURNS jsonb
        LANGUAGE sql
        STABLE
        PARALLEL SAFE
        SECURITY INVOKER
        SET search_path = pg_catalog, public, #{escaped}
        AS 'SELECT jsonb_build_object(''ok'', true)'
        """
      end,
      fn escaped ->
        """
        CREATE OR REPLACE FUNCTION #{escaped}.upsert_area_type(
          collection_key text,
          key text,
          rank integer
        )
        RETURNS uuid
        LANGUAGE sql
        VOLATILE
        SECURITY INVOKER
        SET search_path = pg_catalog, public, #{escaped}
        AS 'SELECT gen_random_uuid()'
        """
      end,
      fn escaped ->
        "CREATE FUNCTION #{escaped}.upsert_area_type(rank integer) RETURNS uuid LANGUAGE sql AS 'SELECT gen_random_uuid()'"
      end,
      fn escaped ->
        """
        CREATE FUNCTION #{escaped}.upsert_area_type(
          collection_key text,
          key text,
          rank integer,
          requires_geometry boolean
        )
        RETURNS uuid
        LANGUAGE sql
        AS 'SELECT gen_random_uuid()'
        """
      end
    ]
  end

  defp target_idempotence_drift_mutations(escaped) do
    [
      """
      CREATE OR REPLACE FUNCTION #{escaped}.verify_release(target_release_id uuid)
      RETURNS jsonb
      LANGUAGE sql
      STABLE
      PARALLEL SAFE
      SECURITY INVOKER
      SET search_path = pg_catalog, public, #{escaped}
      AS 'SELECT jsonb_build_object(''ok'', true)'
      """,
      """
      CREATE OR REPLACE FUNCTION #{escaped}.upsert_area_type(
        collection_key text,
        key text,
        rank integer
      )
      RETURNS uuid
      LANGUAGE sql
      VOLATILE
      SECURITY INVOKER
      SET search_path = pg_catalog, public, #{escaped}
      AS 'SELECT gen_random_uuid()'
      """,
      """
      CREATE OR REPLACE FUNCTION #{escaped}.upsert_area_type(
        collection_key text,
        key text,
        rank integer,
        requires_geometry boolean
      )
      RETURNS uuid
      LANGUAGE sql
      VOLATILE
      SECURITY INVOKER
      SET search_path = pg_catalog, public, #{escaped}
      AS 'SELECT gen_random_uuid()'
      """,
      "CREATE FUNCTION #{escaped}.upsert_area_type(integer) RETURNS void LANGUAGE sql AS 'SELECT'",
      "DROP FUNCTION #{escaped}.upsert_area_type(text, text, integer, boolean)",
      "ALTER TABLE #{escaped}.area_type ALTER COLUMN requires_geometry SET DEFAULT true"
    ]
  end

  defp target_to_reviewed_preflight_mutations(escaped) do
    [
      "COMMENT ON VIEW #{escaped}.geo_genius_version IS 'version=2'",
      """
      CREATE OR REPLACE VIEW #{escaped}.geo_genius_contract AS
      SELECT 1::integer AS schema_version,
             '#{@target}'::text AS contract_revision,
             ARRAY[
               'boundary_batches',
               'boundary_canonical_repair_once',
               'boundary_collection_provenance',
               'boundary_publication_serialization',
               'reversible_legacy_v01_reconciliation',
               'type_scoped_geometry_requirements'
             ]::text[] AS capabilities
      UNION ALL
      SELECT 1::integer, '#{@target}'::text, ARRAY[
               'boundary_batches',
               'boundary_canonical_repair_once',
               'boundary_collection_provenance',
               'boundary_publication_serialization',
               'reversible_legacy_v01_reconciliation',
               'type_scoped_geometry_requirements'
             ]::text[]
      """,
      [
        "DROP VIEW #{escaped}.geo_genius_contract",
        "CREATE TABLE #{escaped}.geo_genius_contract (schema_version integer, contract_revision text, capabilities text[])"
      ],
      [
        "DROP VIEW #{escaped}.geo_genius_contract",
        """
        CREATE MATERIALIZED VIEW #{escaped}.geo_genius_contract AS
        SELECT 1::integer AS schema_version,
               '#{@target}'::text AS contract_revision,
               ARRAY[
                 'boundary_batches',
                 'boundary_canonical_repair_once',
                 'boundary_collection_provenance',
                 'boundary_publication_serialization',
                 'reversible_legacy_v01_reconciliation',
                 'type_scoped_geometry_requirements'
               ]::text[] AS capabilities
        """
      ],
      [
        "DROP VIEW #{escaped}.geo_genius_contract",
        """
        CREATE VIEW #{escaped}.geo_genius_contract AS
        SELECT 1::integer AS schema_version,
               '#{@target}'::text AS contract_revision,
               ARRAY[
                 'boundary_batches',
                 'boundary_canonical_repair_once',
                 'boundary_collection_provenance',
                 'boundary_publication_serialization',
                 'reversible_legacy_v01_reconciliation',
                 'type_scoped_geometry_requirements'
               ]::text[] AS capabilities,
               true AS extra_column
        """
      ]
    ]
  end

  defp target_marker_sql(escaped, schema_version) do
    """
    CREATE OR REPLACE VIEW #{escaped}.geo_genius_contract AS
    SELECT #{schema_version}::integer AS schema_version,
           '#{@target}'::text AS contract_revision,
           ARRAY[
             'boundary_batches',
             'boundary_canonical_repair_once',
             'boundary_collection_provenance',
             'boundary_publication_serialization',
             'reversible_legacy_v01_reconciliation',
             'type_scoped_geometry_requirements'
           ]::text[] AS capabilities
    """
  end

  defp assert_drift_rejected(prefix, mutation, from, to) do
    prefix
    |> reconciliation_error(mutation, from, to)
    |> assert_drift_error()
  end

  defp assert_drift_error(%Postgrex.Error{} = error) do
    assert error.postgres.code == :object_not_in_prerequisite_state
    assert error.postgres.message =~ "unknown or drifted"
  end

  defp assert_drift_error(:accepted), do: flunk("reconciliation accepted a drifted contract")

  defp reconciliation_error(prefix, mutation, from, to) do
    {:error, result} =
      TestRepo.transaction(fn ->
        if mutation, do: run_mutation!(mutation)

        result =
          try do
            execute_reconciliation_statements!(prefix, from, to)

            :accepted
          rescue
            error in Postgrex.Error -> error
          end

        TestRepo.rollback(result)
      end)

    result
  end

  defp committed_reconciliation_error(prefix, from, to) do
    TestRepo.checkout(fn ->
      try do
        execute_sql!(reconciliation_sql(prefix, from, to))

        :accepted
      rescue
        error in Postgrex.Error ->
          TestRepo.query!("ROLLBACK", [], log: false)
          error
      end
    end)
  end

  defp run_mutation!(mutations) when is_list(mutations) do
    Enum.each(mutations, &TestRepo.query!(&1, [], log: false))
  end

  defp run_mutation!(mutation) do
    TestRepo.query!(mutation, [], log: false)
  end

  defp seed_nullable_geometry_flag_if_possible(escaped, prefix) do
    if requires_geometry_column_type(prefix) == "boolean" and
         requires_geometry_nullable?(prefix) do
      seed_nullable_geometry_flag!(escaped, prefix)
    else
      return_ok()
    end
  end

  defp seed_nullable_geometry_flag!(escaped, prefix) do
    TestRepo.query!(
      """
      INSERT INTO #{escaped}.collection (key, name)
      VALUES ('typed_catalog', 'Typed Catalog')
      ON CONFLICT (key) DO NOTHING
      """,
      [],
      log: false
    )

    TestRepo.query!(
      """
      INSERT INTO #{escaped}.area_type (collection_id, key, rank, requires_geometry)
      SELECT id, 'bounded_zone', 10, NULL
        FROM #{escaped}.collection
       WHERE key = 'typed_catalog'
         AND EXISTS (
           SELECT 1
             FROM information_schema.columns
            WHERE table_schema = $1
              AND table_name = 'area_type'
              AND column_name = 'requires_geometry'
              AND is_nullable = 'YES'
              AND data_type = 'boolean'
         )
      ON CONFLICT DO NOTHING
      """,
      [prefix],
      log: false
    )
  end

  defp return_ok, do: :ok

  defp install!(prefix) do
    Migration.render_sql(prefix: prefix, from: 0, to: 1)
    |> execute_sql!()
  end

  defp install_target_functions!(prefix) do
    prefix
    |> reconciliation_sql(:legacy_v01_aebc28a, @target)
    |> execute_sql!()
  end

  defp install_contract_identity!(prefix, :legacy_v01_aebc28a) do
    install!(prefix)
    LegacyV01Fixture.apply!(TestRepo, prefix)
  end

  defp install_contract_identity!(prefix, @reviewed) do
    install!(prefix)

    prefix
    |> reconciliation_sql(@target, @reviewed)
    |> execute_sql!()
  end

  defp install_contract_identity!(prefix, @target), do: install!(prefix)

  defp source_edges(:legacy_v01_aebc28a),
    do: [{:legacy_v01_aebc28a, @target}, {:legacy_v01_aebc28a, @reviewed}]

  defp source_edges(@reviewed), do: [{@reviewed, @target}, {@reviewed, :legacy_v01_aebc28a}]
  defp source_edges(@target), do: [{@target, :legacy_v01_aebc28a}, {@target, @reviewed}]

  defp assert_restored_status(:legacy_v01_aebc28a, %{status: :legacy_unmarked}), do: :ok
  defp assert_restored_status(@reviewed, %{status: :reviewed_v01}), do: :ok
  defp assert_restored_status(@target, %{status: :compatible}), do: :ok

  defp source_name(:legacy_v01_aebc28a), do: "legacy"
  defp source_name(@reviewed), do: "reviewed"
  defp source_name(@target), do: "target"

  defp requires_geometry_column_type(prefix) do
    case TestRepo.query!(
           """
           SELECT format_type(a.atttypid, a.atttypmod)
             FROM pg_attribute a
             JOIN pg_class c ON c.oid = a.attrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1
              AND c.relname = 'area_type'
              AND a.attname = 'requires_geometry'
              AND a.attnum > 0
              AND NOT a.attisdropped
           """,
           [prefix],
           log: false
         ).rows do
      [[type]] -> type
      [] -> nil
    end
  end

  defp requires_geometry_nullable?(prefix) do
    case TestRepo.query!(
           """
           SELECT NOT a.attnotnull
             FROM pg_attribute a
             JOIN pg_class c ON c.oid = a.attrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1
              AND c.relname = 'area_type'
              AND a.attname = 'requires_geometry'
              AND a.attnum > 0
              AND NOT a.attisdropped
           """,
           [prefix],
           log: false
         ).rows do
      [[nullable?]] -> nullable?
      [] -> false
    end
  end

  defp status(prefix), do: Migration.contract_status(TestRepo, prefix)

  defp reconciliation_sql(prefix, from, to, opts \\ []) do
    Migration.render_reconciliation_sql([prefix: prefix, from: from, to: to] ++ opts)
  end

  defp execute_sql!(sql), do: TestSimpleSQL.query!(TestRepo, sql)

  defp execute_reconciliation_statements!(prefix, from, to) do
    [prefix: prefix, from: from, to: to]
    |> GeoGenius.ReconciliationSQL.statements!()
    |> Enum.each(&TestRepo.query!(&1, [], log: false))
  end

  defp function_exists?(prefix, name) do
    TestRepo.query!(
      """
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = $1 AND p.proname = $2
      """,
      [prefix, name],
      log: false
    ).rows != []
  end

  defp function_signature_exists?(prefix, name, arguments) do
    TestRepo.query!(
      """
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = $1 AND p.proname = $2
         AND oidvectortypes(p.proargtypes) = $3
      """,
      [prefix, name, arguments],
      log: false
    ).rows != []
  end

  defp relation_kind(prefix, name) do
    case TestRepo.query!(
           """
           SELECT c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
           """,
           [prefix, name],
           log: false
         ).rows do
      [[kind]] -> kind
      [] -> nil
    end
  end
end
