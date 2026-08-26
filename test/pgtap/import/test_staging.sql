BEGIN;

SELECT plan(30);

SELECT has_function('geo_genius', 'staging_table_name', 'staging_table_name exists');
SELECT has_function('geo_genius', 'create_staging', 'create_staging exists');
SELECT has_function('geo_genius', 'drop_staging', 'drop_staging exists');
SELECT has_function('geo_genius', 'analyze_release', 'analyze_release exists');
SELECT has_function('geo_genius', 'published_release', 'published_release exists');
SELECT has_view('geo_genius', 'import_run_status', 'import_run_status view exists');
SELECT has_view('geo_genius', 'release_artifacts', 'release_artifacts view exists');

SELECT geo_genius.upsert_collection('demo', 'Demo', NULL);
SELECT geo_genius.open_release('demo', 'r1', '{}'::jsonb, NULL);

SELECT is(
  geo_genius.begin_or_resume_import(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
    'worker-1', 'test', interval '5 minutes'
  ) IS NOT NULL,
  true,
  'a run is claimed for the staging test'
);

SELECT is(
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'staging_' || replace((SELECT id::text FROM geo_genius.import_run LIMIT 1), '-', ''),
  'staging_table_name derives the name from the run id'
);

SELECT throws_ok(
  $$SELECT geo_genius.staging_table_name(NULL)$$,
  '22004',
  NULL,
  'staging_table_name requires a run id'
);

-- Without this check the call succeeds and leaves an unlogged table, its
-- identity sequence, and its primary key behind for a run that does not
-- exist. That orphan is worse than an ordinary leak: Staging.leaked/1 finds
-- leaked tables by joining import_run to pg_class, so a table whose run row
-- is missing has nothing to join to and mix geo_genius.sweep_staging can
-- never reclaim it.
SELECT throws_ok(
  $$SELECT geo_genius.create_staging('00000000-0000-0000-0000-000000000000'::uuid)$$,
  '23503',
  'import run 00000000-0000-0000-0000-000000000000 does not exist',
  'create_staging refuses a run that does not exist'
);

SELECT is(
  geo_genius.create_staging((SELECT id FROM geo_genius.import_run LIMIT 1)),
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'create_staging returns the table name it created'
);

SELECT has_table(
  'geo_genius',
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'create_staging creates the table in the installed schema'
);

-- A create_staging that emitted only the identity column would still pass
-- every existence and persistence check above, so the column shape the
-- normalization phase depends on is asserted directly.
SELECT has_column(
  'geo_genius',
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'artifact',
  'create_staging creates the artifact column'
);

SELECT col_type_is(
  'geo_genius',
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'artifact',
  'text',
  'the artifact column is text'
);

SELECT has_column(
  'geo_genius',
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'payload',
  'create_staging creates the payload column'
);

SELECT col_type_is(
  'geo_genius',
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'payload',
  'jsonb',
  'the payload column is jsonb'
);

SELECT has_column(
  'geo_genius',
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'geom',
  'create_staging creates the geom column'
);

SELECT col_type_is(
  'geo_genius',
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'geom',
  'geometry(Geometry,4326)',
  'the geom column is geometry(Geometry,4326)'
);

SELECT is(
  (SELECT relpersistence::text FROM pg_class
    JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
   WHERE pg_namespace.nspname = 'geo_genius'
     AND relname = geo_genius.staging_table_name(
       (SELECT id FROM geo_genius.import_run LIMIT 1))),
  'u',
  'the staging table is unlogged'
);

-- Seed a row before re-creating the staging table, so idempotency is proven
-- by the row surviving a resumed staging phase, not merely by the second
-- call not raising -- a DROP-then-CREATE would pass a bare lives_ok too.
DO $seed$
DECLARE
  target_run_id uuid := (SELECT id FROM geo_genius.import_run LIMIT 1);
BEGIN
  EXECUTE format(
    'INSERT INTO geo_genius.%I (artifact, payload) VALUES (%L, %L::jsonb)',
    geo_genius.staging_table_name(target_run_id), 'seed', '{}'
  );
END;
$seed$;

SELECT lives_ok(
  $$SELECT geo_genius.create_staging((SELECT id FROM geo_genius.import_run LIMIT 1))$$,
  'create_staging is idempotent'
);

SELECT results_eq(
  format(
    'SELECT count(*)::int FROM geo_genius.%I',
    geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1))
  ),
  ARRAY[1],
  'create_staging does not discard already-staged rows on a resumed run'
);

SELECT geo_genius.drop_staging((SELECT id FROM geo_genius.import_run LIMIT 1));

SELECT hasnt_table(
  'geo_genius',
  geo_genius.staging_table_name((SELECT id FROM geo_genius.import_run LIMIT 1)),
  'drop_staging removes the table'
);

SELECT lives_ok(
  $$SELECT geo_genius.drop_staging((SELECT id FROM geo_genius.import_run LIMIT 1))$$,
  'drop_staging is idempotent'
);

SELECT lives_ok(
  $$SELECT geo_genius.analyze_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'))$$,
  'analyze_release runs against a release whose partitions exist'
);

-- That lives_ok only proves the call did not raise: a body emptied of its
-- ANALYZE loop passes it unchanged. pg_class.reltuples is -1 for a table that
-- has never been analyzed and >= 0 once it has, and ANALYZE's catalog update
-- is visible inside this transaction, so this is the assertion that the work
-- happened. bool_and covers all four partitions rather than one, because a
-- loop that analyzed only its first parent would satisfy any single-table
-- check.
SELECT ok(
  (SELECT bool_and(pg_class.reltuples >= 0)
     FROM pg_class, LATERAL (
       SELECT replace(release.id::text, '-', '') AS suffix
         FROM geo_genius.release WHERE release.release_key = 'r1'
     ) r
    WHERE pg_class.relname IN (
      'boundary_' || r.suffix,
      'boundary_part_' || r.suffix,
      'relation_' || r.suffix,
      'release_area_' || r.suffix
    )),
  'analyze_release analyzes every one of the release partitions, not merely the first'
);

-- open_release always creates partitions, so the release above never
-- exercises the to_regclass guard. A release id with no partitions at all
-- (retired, or never opened) is the case the guard exists for.
SELECT lives_ok(
  $$SELECT geo_genius.analyze_release(gen_random_uuid())$$,
  'analyze_release no-ops against a release whose partitions do not exist'
);

SELECT is(
  geo_genius.published_release('demo'),
  NULL,
  'published_release returns NULL for a collection that has published nothing'
);

-- Build a publishable release: an area with an official name, an attached
-- source release, and a release-membership centroid. requires_geometry
-- defaults to false, so no boundary is needed for verify_release to pass.
SELECT geo_genius.upsert_authority('demo', 'demo_auth', 'Demo Authority');
SELECT geo_genius.upsert_area_type('demo', 'outer', 10);
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'A');
SELECT geo_genius.put_area_name('demo_auth:outer:A', 'Area A', 'official', NULL);

SELECT geo_genius.upsert_source('demo', 'demo:src', 'demo', 'test');
SELECT geo_genius.upsert_source_release('demo', 'demo:src', 'v1', NULL, '{}'::jsonb);

SELECT geo_genius.open_release('demo', 'r2', '{}'::jsonb, NULL);

SELECT geo_genius.attach_source_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'),
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')
);

SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'),
  'demo_auth:outer:A',
  ST_GeogFromText('POINT(0 0)'),
  '{}'::jsonb
);

SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

-- A published_release stubbed as `RETURN NULL;` would pass the earlier
-- nothing-published check too, so the positive case is required to close
-- that gap.
SELECT is(
  geo_genius.published_release('demo'),
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'),
  'published_release returns the id of the currently published release'
);

SELECT throws_ok(
  $$SELECT geo_genius.published_release(NULL)$$,
  '22004',
  NULL,
  'published_release requires a collection key'
);

SELECT finish();

ROLLBACK;
