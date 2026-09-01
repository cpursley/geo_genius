BEGIN;

SELECT plan(40);

SELECT has_schema('geo_genius', 'geo_genius schema exists');
SELECT has_view('geo_genius', 'geo_genius_version', 'version tracking view exists');
SELECT has_view('geo_genius', 'geo_genius_contract', 'contract marker view exists');
SELECT has_table('geo_genius', 'area_type', 'area_type is an ordinary table');
SELECT is(
  (SELECT schema_version FROM geo_genius.geo_genius_contract),
  1,
  'contract marker keeps the public schema at version 1'
);
SELECT is(
  (SELECT contract_revision FROM geo_genius.geo_genius_contract),
  'sha256:b2a132663db6baaf8482454a9dce7f385d98c665133b3b123fe3cf00630c0c44',
  'contract marker exposes the canonical content address'
);
SELECT is(
  (SELECT capabilities FROM geo_genius.geo_genius_contract),
  ARRAY[
    'artifact_observation_publication_gate', 'atomic_failed_candidate_retry',
    'atomic_import_completion', 'atomic_import_publication', 'boundary_batches',
    'boundary_canonical_repair_once', 'boundary_collection_provenance',
    'boundary_publication_serialization', 'exact_attempt_artifact_snapshots',
    'exact_attempt_manifest_snapshots', 'executor_fenced_staging_cleanup',
    'failed_candidate_requires_explicit_retry', 'idempotent_executor_reclaim',
    'immutable_failure_evidence',
    'publication_constraint_triggers', 'release_retention_preserves_history',
    'release_scoped_catalog_declarations', 'run_fenced_ingestion',
    'single_executor_import_claim', 'strict_import_phase_transitions',
    'type_scoped_geometry_requirements'
  ]::text[],
  'contract marker exposes the required capabilities in canonical order'
);
SELECT hasnt_column(
  'geo_genius',
  'area_type',
  'requires_geometry',
  'area_type carries stable identity only, not release geometry policy'
);
SELECT hasnt_column(
  'geo_genius',
  'collection',
  'name',
  'collection carries stable identity only, not a release display name'
);
SELECT hasnt_column(
  'geo_genius',
  'collection',
  'description',
  'collection carries stable identity only, not a release description'
);
SELECT hasnt_column(
  'geo_genius',
  'collection',
  'requires_geometry',
  'collection geometry policy belongs to a release declaration'
);
SELECT hasnt_column(
  'geo_genius',
  'authority',
  'name',
  'authority display names belong to release declarations'
);
SELECT hasnt_column(
  'geo_genius',
  'area_type',
  'rank',
  'area type rank belongs to a release declaration'
);
SELECT col_type_is(
  'geo_genius',
  'release_area_type',
  'requires_geometry',
  'boolean',
  'release_area_type.requires_geometry is boolean'
);
SELECT col_not_null(
  'geo_genius',
  'release_area_type',
  'requires_geometry',
  'release_area_type.requires_geometry is required'
);
SELECT has_column(
  'geo_genius',
  'import_run_lease',
  'executor_id',
  'import_run_lease exposes the winning executor id'
);
SELECT has_column(
  'geo_genius',
  'import_run_lease',
  'execution_started_at',
  'import_run_lease exposes when execution began'
);
SELECT has_function(
  'geo_genius',
  'claim_import_execution',
  ARRAY['uuid', 'uuid'],
  'claim_import_execution is installed'
);
SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = 'geo_genius.import_run_status'::regclass
      AND attnum > 0
      AND NOT attisdropped),
  ARRAY[
    'run_id', 'release_id', 'collection_key', 'release_key', 'attempt', 'status',
    'owner', 'runner_backend', 'started_at', 'heartbeat_at', 'completed_at',
    'error', 'stage_metrics', 'progress', 'executor_id', 'execution_started_at',
    'manifest'
  ]::text[],
  'import_run_status exposes execution ownership in stable column order'
);
SELECT ok(
  EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conrelid = 'geo_genius.import_run_lease'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) LIKE '%executor_id IS NULL%execution_started_at IS NULL%'
  ),
  'the executor identity and start timestamp carry a null-pair check'
);
SELECT ok(
  (SELECT strpos(pg_get_functiondef(p.oid), 'release_lock_key')
            < strpos(pg_get_functiondef(p.oid), 'publication_lock_key')
          AND strpos(pg_get_functiondef(p.oid), 'publication_lock_key')
            < strpos(pg_get_functiondef(p.oid), 'FOR UPDATE OF import_run, release')
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'geo_genius'
      AND p.proname = 'assert_import_write'),
  'the import fence takes release then publication advisory locks before row locks'
);
SELECT has_function(
  'geo_genius',
  'assert_extensions',
  ARRAY['text[]'],
  'assert_extensions exists'
);

SELECT is(
  to_regprocedure('geo_genius.put_area_name(text,text,text,text)'),
  NULL::regprocedure,
  'the unsafe release-less scalar name writer is absent'
);
SELECT is(
  to_regprocedure('geo_genius.put_area_code(text,text,text)'),
  NULL::regprocedure,
  'the unsafe release-less scalar code writer is absent'
);
SELECT is(
  to_regprocedure('geo_genius.put_area_name_many(text[],text[],text[],text[])'),
  NULL::regprocedure,
  'the unsafe release-less plural name writer is absent'
);
SELECT is(
  to_regprocedure('geo_genius.put_area_code_many(text[],text[],text[])'),
  NULL::regprocedure,
  'the unsafe release-less plural code writer is absent'
);

SELECT is(
  (SELECT array_agg(attribute.attname::text ORDER BY key_position.ordinality)
     FROM pg_constraint constraint_row
     CROSS JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY
       AS key_position(attnum, ordinality)
     JOIN pg_attribute attribute
       ON attribute.attrelid = constraint_row.conrelid
      AND attribute.attnum = key_position.attnum
    WHERE constraint_row.conrelid = 'geo_genius.import_run_artifact'::regclass
      AND constraint_row.contype = 'p'),
  ARRAY['run_id', 'artifact_id']::text[],
  'an attempt selects each artifact at most once'
);

SELECT is(
  (SELECT array_agg(
            attribute.attname::text || '->' || referenced.relname::text
            ORDER BY attribute.attname)
     FROM pg_constraint constraint_row
     JOIN pg_class referenced ON referenced.oid = constraint_row.confrelid
     CROSS JOIN LATERAL unnest(constraint_row.conkey) AS key_position(attnum)
     JOIN pg_attribute attribute
       ON attribute.attrelid = constraint_row.conrelid
      AND attribute.attnum = key_position.attnum
    WHERE constraint_row.conrelid = 'geo_genius.import_run_artifact'::regclass
      AND constraint_row.contype = 'f'),
  ARRAY['artifact_id->artifact', 'run_id->import_run']::text[],
  'attempt artifact selections reference one real run and one real artifact'
);

SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = 'geo_genius.run_artifacts'::regclass
      AND attnum > 0
      AND NOT attisdropped),
  ARRAY[
    'run_id', 'release_id', 'source_release_id', 'source_key', 'source_release_key',
    'collection_key', 'artifact_id', 'logical_name', 'url', 'operator_supplied',
    'format', 'expected_sha256', 'expected_bytes', 'observed_sha256',
    'observed_bytes', 'validated_at', 'metadata'
  ]::text[],
  'run_artifacts column order is stable for host projections'
);

SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = 'geo_genius.release_artifacts'::regclass
      AND attnum > 0
      AND NOT attisdropped),
  ARRAY[
    'release_id', 'source_release_id', 'source_key', 'source_release_key',
    'collection_key', 'artifact_id', 'logical_name', 'url', 'operator_supplied',
    'format', 'expected_sha256', 'expected_bytes', 'observed_sha256',
    'observed_bytes', 'validated_at', 'metadata'
  ]::text[],
  'release_artifacts column order is stable for host projections'
);

-- The published_* views are the host binding surface and area_match is the
-- shape every resolution function returns. Reordering two same-typed columns
-- in either would silently transpose values in a host's positional read, and
-- no behavioural test would notice, so the order is pinned here.
SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = 'geo_genius.published_areas'::regclass
      AND attnum > 0 AND NOT attisdropped),
  ARRAY[
    'collection_key', 'release_id', 'area_id', 'area_key', 'authority',
    'area_type', 'type_rank', 'name', 'centroid', 'attributes', 'retired_at'
  ],
  'published_areas column order is unchanged'
);

SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = 'geo_genius.release_areas'::regclass
      AND attnum > 0 AND NOT attisdropped),
  ARRAY[
    'collection_key', 'release_id', 'area_id', 'area_key', 'authority',
    'area_type', 'type_rank', 'name', 'centroid', 'attributes', 'retired_at'
  ],
  'release_areas column order matches published_areas'
);

SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = (SELECT typrelid FROM pg_type
                       WHERE typname = 'area_match'
                         AND typnamespace = 'geo_genius'::regnamespace)
      AND attnum > 0 AND NOT attisdropped),
  ARRAY[
    'collection_key', 'release_id', 'area_key', 'authority', 'area_type',
    'type_rank', 'name', 'codes', 'centroid', 'attributes', 'match_method',
    'distance_m', 'intersection_area_m2', 'coverage_of_input',
    'coverage_of_area', 'score'
  ],
  'area_match column order is unchanged'
);

-- seeded_area_match repeats area_match's columns after its own seed_key, and
-- the plural reads project one straight into the other. A column added to
-- area_match alone, or reordered in one and not the other, would transpose
-- values with no behavioural test to catch it.
SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = (SELECT typrelid FROM pg_type
                       WHERE typname = 'seeded_area_match'
                         AND typnamespace = 'geo_genius'::regnamespace)
      AND attnum > 0 AND NOT attisdropped),
  ARRAY['seed_key'] || (
    SELECT array_agg(attname::text ORDER BY attnum)
      FROM pg_attribute
     WHERE attrelid = (SELECT typrelid FROM pg_type
                        WHERE typname = 'area_match'
                          AND typnamespace = 'geo_genius'::regnamespace)
       AND attnum > 0 AND NOT attisdropped
  ),
  'seeded_area_match is seed_key followed by area_match''s columns in order'
);

-- Nothing GeoGenius installs runs with the definer's rights, and every
-- function pins its search path. A function switched to SECURITY DEFINER, or
-- left with a mutable search path, would be a privilege-escalation surface
-- that behaves identically in every other test.
SELECT is(
  (SELECT count(*)::int
     FROM pg_proc
    WHERE pronamespace = 'geo_genius'::regnamespace
      AND prosecdef),
  0,
  'no installed function is SECURITY DEFINER'
);

SELECT is(
  (SELECT array_agg(proname::text ORDER BY proname)
     FROM pg_proc
    WHERE pronamespace = 'geo_genius'::regnamespace
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(proconfig, ARRAY[]::text[])) AS setting
         WHERE setting LIKE 'search_path=%'
      )),
  NULL,
  'every installed function pins its search path'
);

-- The invariant helpers are what the write API and the read functions call
-- into. Dropping one would leave those callers unguarded, so their presence
-- is asserted directly rather than only through the behaviour they enforce.
SELECT is(
  (SELECT count(*)::int FROM pg_proc
    WHERE pronamespace = 'geo_genius'::regnamespace
      AND proname IN ('assert_release_mutable', 'assert_area_in_collection',
                      'area_codes_json', 'release_at')),
  4,
  'the invariant and resolution helpers are installed'
);

-- guides/sql_api.md publishes the volatility and parallel-safety markings as
-- a contract. A read function that loses PARALLEL SAFE silently costs every
-- host a parallel plan, and a write function marked STABLE would be run
-- inside a plan that assumes it writes nothing.
SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'geo_genius'
      AND p.provolatile <> 'v'
      AND p.proparallel <> 's'),
  ARRAY['assert_area_declared', 'assert_area_in_collection', 'assert_extensions', 'assert_release_mutable',
        'assert_required_artifact_observations', 'release_at', 'staging_table_name'],
  'the non-volatile functions lacking PARALLEL SAFE are exactly the documented helpers'
);

SELECT is(
  (SELECT array_agg(DISTINCT p.provolatile::text || p.proparallel::text)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'geo_genius'
      AND p.proname = ANY(ARRAY[
        'areas_for_point', 'areas_for_geometry', 'areas_near', 'areas_by_code',
        'search_areas', 'resolve', 'children_of', 'ancestors_of', 'related_areas',
        'areas_by_code_many', 'children_of_many', 'ancestors_of_many',
        'related_areas_many', 'published_release', 'verify_release'])),
  ARRAY['ss'],
  'every documented read function is STABLE PARALLEL SAFE'
);

SELECT is(
  (SELECT count(*)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'geo_genius'
      AND p.provolatile <> 'v'
      AND p.proname = ANY(ARRAY[
        'upsert_collection', 'upsert_authority', 'upsert_area_type', 'upsert_area',
        'put_area_name', 'put_area_code', 'put_area_in_release', 'put_boundary', 'put_boundaries',
        'put_relation', 'rebuild_relations', 'publish_release', 'rollback_publication',
        'retire_releases', 'open_release', 'attach_source_release', 'attach_artifact', 'put_artifact',
        'record_artifact_observation', 'upsert_source', 'upsert_source_release',
        'prepare_import', 'retry_failed', 'heartbeat_import', 'advance_import', 'fail_import',
        'create_staging', 'drop_staging', 'analyze_release'])),
  0::bigint,
  'every documented write function is VOLATILE'
);

SELECT finish();

ROLLBACK;
