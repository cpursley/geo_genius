BEGIN;

SELECT plan(19);

-- The error contracts guides/sql_api.md publishes. A caller matching on
-- SQLSTATE reads that table, so a code that drifts away from it, or a
-- documented code no test ever provokes, is a contract nobody is holding.

SELECT geo_genius_test.demo_fixture_build();

SELECT throws_ok(
  $$SELECT geo_genius.rebuild_relations(
      '00000000-0000-0000-0000-000000000001'::uuid,
      geo_genius_test.demo_executor_id())$$,
  '23503',
  NULL,
  'rebuild_relations raises 23503 for an import run that does not exist'
);

SELECT throws_ok(
  $$SELECT geo_genius.verify_release('00000000-0000-0000-0000-000000000001'::uuid)$$,
  '23503',
  NULL,
  'verify_release raises 23503 for a release that does not exist'
);

-- The `SELECT ... INTO STRICT` family: PL/pgSQL's own P0002, naming neither
-- the function nor the value that was not found. Documented as such rather
-- than converted, so each reachable site is pinned to the code a caller
-- actually sees.
SELECT throws_ok(
  $$SELECT geo_genius.upsert_area('nope', 'demo_auth', 'outer', 'Z')$$,
  'P0002',
  NULL,
  'upsert_area raises P0002 for an unknown collection'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_area('demo', 'nope', 'outer', 'Z')$$,
  'P0002',
  NULL,
  'upsert_area raises P0002 for an unknown authority'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_area('demo', 'demo_auth', 'nope', 'Z')$$,
  'P0002',
  NULL,
  'upsert_area raises P0002 for an unknown area type'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_area_name(
      geo_genius_test.demo_run_id(),
      geo_genius_test.demo_executor_id(),
      'nope:nope:nope', 'Zed', 'official', NULL)$$,
  'P0002',
  NULL,
  'put_area_name raises P0002 for an unknown area key'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_area_code(
      geo_genius_test.demo_run_id(),
      geo_genius_test.demo_executor_id(),
      'nope:nope:nope', 'fips', '99')$$,
  'P0002',
  NULL,
  'put_area_code raises P0002 for an unknown area key'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_area_in_release(
      geo_genius_test.demo_run_id(),
      geo_genius_test.demo_executor_id(),
      'nope:nope:nope', NULL, NULL)$$,
  'P0002',
  NULL,
  'put_area_in_release raises P0002 for an unknown area key'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_area_in_release(
      '00000000-0000-0000-0000-000000000001'::uuid,
      geo_genius_test.demo_executor_id(),
      'demo_auth:outer:A', NULL, NULL)$$,
  '23503',
  NULL,
  'an import run id naming nothing raises 23503 before an ingestion write'
);

-- Finish every normalizing write before testing the relating contract.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'inner', 'C');
SELECT geo_genius.put_area_in_release(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:inner:C', NULL, NULL
);
SELECT geo_genius_test.advance_import_to(
  geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(),
  'relating');

SELECT throws_ok(
  $$SELECT geo_genius.put_relation(
      geo_genius_test.demo_run_id(),
      geo_genius_test.demo_executor_id(),
      'nope:nope:nope', 'demo_auth:inner:B', 'contains')$$,
  'P0002',
  NULL,
  'put_relation raises P0002 for an unknown parent area key'
);

-- Both staging helpers reject a missing run identity before resolving a
-- dynamic table name.
SELECT throws_ok(
  $$SELECT geo_genius.create_staging(NULL, geo_genius_test.demo_executor_id())$$,
  '22004',
  NULL,
  'create_staging(NULL) raises 22004 for its required run id'
);

SELECT throws_ok(
  $$SELECT geo_genius.drop_staging(NULL)$$,
  '22004',
  NULL,
  'drop_staging(NULL) raises 22004 from staging_table_name rather than dropping nothing'
);

-- 23514's two most reachable producers are the publication calls, not the
-- artifact check the guide used to name alone.
SELECT throws_ok(
  $$SELECT geo_genius.rollback_publication('demo')$$,
  '23514',
  NULL,
  'rollback_publication raises 23514 for a collection with no previous release'
);

SELECT is(
  geo_genius.published_release('no_such_collection'),
  NULL,
  'published_release returns NULL for a collection key the catalog does not carry'
);

-- A release with areas but no declared source release fails verification on
-- that alone, isolated from the "contains no areas" check that would
-- otherwise account for the same failure.
SELECT geo_genius.upsert_collection('sourceless', 'Sourceless', NULL);
SELECT geo_genius.upsert_authority('sourceless', 'sl_auth', 'Sourceless Authority');
SELECT geo_genius.upsert_area_type('sourceless', 'unit', 10);
SELECT geo_genius.upsert_area('sourceless', 'sl_auth', 'unit', 'A');

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"sourceless",
    "release":"sl1",
    "collection_name":"Sourceless",
    "requires_geometry":false,
    "authorities":[{"key":"sl_auth","name":"Sourceless Authority"}],
    "area_types":[{"key":"unit","rank":10,"requires_geometry":false}]
  }'::jsonb,
  '{"owner":"pgtap-error-contracts","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('sourceless', 'sl1'));

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('sourceless', 'sl1'),
  geo_genius_test.import_executor_id('sourceless', 'sl1'),
  'normalizing'
);

SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('sourceless', 'sl1'),
  geo_genius_test.import_executor_id('sourceless', 'sl1'),
  'sl_auth:unit:A', NULL, NULL
);

SELECT ok(
  (SELECT geo_genius.verify_release(
     (SELECT id FROM geo_genius.release WHERE release_key = 'sl1')
   ) -> 'failures' @> '["release declares no source releases"]'::jsonb),
  'verify_release fails a release that declares no source releases'
);

SELECT ok(
  NOT (SELECT geo_genius.verify_release(
     (SELECT id FROM geo_genius.release WHERE release_key = 'sl1')
   ) -> 'failures' @> '["release contains no areas"]'::jsonb),
  'the sourceless release is not also failing for want of areas'
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('sourceless', 'sl1'),
  geo_genius_test.import_executor_id('sourceless', 'sl1'),
  'publishing'
);

SELECT throws_ok(
  $$SELECT geo_genius.publish_import(
      geo_genius_test.import_run_id('sourceless', 'sl1'),
      geo_genius_test.import_executor_id('sourceless', 'sl1'))$$,
  '23514',
  NULL,
  'publish_import raises 23514 for a release that fails verification'
);

-- Removing partitions from a legitimately claimed candidate is a loud
-- failure, not a silent no-op.
SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"sourceless",
    "release":"sl2",
    "collection_name":"Sourceless",
    "requires_geometry":false,
    "authorities":[{"key":"sl_auth","name":"Sourceless Authority"}],
    "area_types":[{"key":"unit","rank":10,"requires_geometry":false}]
  }'::jsonb,
  '{"owner":"pgtap-error-contracts","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('sourceless', 'sl2'));
SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('sourceless', 'sl2'),
  geo_genius_test.import_executor_id('sourceless', 'sl2'),
  'normalizing'
);
SELECT throws_ok(
  $$SELECT geo_genius.drop_release_partitions(
      (SELECT id FROM geo_genius.release WHERE release_key = 'sl2'))$$,
  '55000',
  NULL,
  'drop_release_partitions refuses a claimed live import'
);

-- guides/ingestion.md names invalid boundary geometry as one of the four
-- conditions the verifying phase refuses to publish. In practice nothing
-- reaches that check: put_boundary repairs with ST_MakeValid before it
-- stores anything, and boundary_geom_valid_chk refuses an invalid geometry
-- written straight to the table. This pins the constraint that makes
-- verify_release's own invalid-geometry branch unreachable.
SELECT throws_ok(
  $$INSERT INTO geo_genius.boundary
      (release_id, area_id, source_release_id, geom, display_geom)
    SELECT
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      (SELECT id FROM geo_genius.area WHERE area_key = 'demo_auth:inner:C'),
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      ST_GeomFromText('MULTIPOLYGON(((0 0, 2 2, 2 0, 0 2, 0 0)))', 4326),
      ST_GeomFromText('MULTIPOLYGON(((0 0, 2 2, 2 0, 0 2, 0 0)))', 4326)$$,
  '23514',
  NULL,
  'the boundary table refuses a self-intersecting geometry outright'
);

SELECT finish();

ROLLBACK;
