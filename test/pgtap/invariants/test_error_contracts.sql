BEGIN;

SELECT plan(19);

-- The error contracts guides/sql_api.md publishes. A caller matching on
-- SQLSTATE reads that table, so a code that drifts away from it, or a
-- documented code no test ever provokes, is a contract nobody is holding.

SELECT geo_genius_test.demo_fixture_build();

-- `rebuild_relations` is the one documented outlier: every sibling raising
-- 'release % does not exist' raises 23503, and this one raises 22023.
SELECT throws_ok(
  $$SELECT geo_genius.rebuild_relations('00000000-0000-0000-0000-000000000001'::uuid)$$,
  '22023',
  NULL,
  'rebuild_relations raises 22023 for a release that does not exist'
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
  $$SELECT geo_genius.put_area_name('nope:nope:nope', 'Zed', 'official', NULL)$$,
  'P0002',
  NULL,
  'put_area_name raises P0002 for an unknown area key'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_area_code('nope:nope:nope', 'fips', '99')$$,
  'P0002',
  NULL,
  'put_area_code raises P0002 for an unknown area key'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_area_in_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'nope:nope:nope', NULL, NULL)$$,
  'P0002',
  NULL,
  'put_area_in_release raises P0002 for an unknown area key'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_relation(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'nope:nope:nope', 'demo_auth:inner:B', 'contains')$$,
  'P0002',
  NULL,
  'put_relation raises P0002 for an unknown parent area key'
);

-- assert_release_mutable is how every release-scoped write reports a release
-- id that names nothing, so its P0002 reaches four functions.
SELECT throws_ok(
  $$SELECT geo_genius.put_area_in_release(
      '00000000-0000-0000-0000-000000000001'::uuid,
      'demo_auth:outer:A', NULL, NULL)$$,
  'P0002',
  NULL,
  'a release id naming nothing reaches P0002 through assert_release_mutable'
);

-- create_staging and drop_staging sit outside the 22004 required-argument
-- set: both funnel a null run id through the existence check instead.
SELECT throws_ok(
  $$SELECT geo_genius.create_staging(NULL)$$,
  '23503',
  NULL,
  'create_staging(NULL) raises 23503 rather than the 22004 of a guarded argument'
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

INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'sl1', '{}'::jsonb FROM geo_genius.collection WHERE key = 'sourceless';

SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'sl1')
);

SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'sl1'),
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

SELECT throws_ok(
  $$SELECT geo_genius.publish_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'sl1'))$$,
  '23514',
  NULL,
  'publish_release raises 23514 for a release that fails verification'
);

-- Omitting create_release_partitions is a loud failure, not a silent no-op.
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'sl2', '{}'::jsonb FROM geo_genius.collection WHERE key = 'sourceless';

SELECT throws_matching(
  $$SELECT geo_genius.put_area_in_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'sl2'),
      'sl_auth:unit:A', NULL, NULL)$$,
  'no partition of relation',
  'writing to a release whose partitions were never created fails loudly'
);

-- guides/ingestion.md names invalid boundary geometry as one of the four
-- conditions the verifying phase refuses to publish. In practice nothing
-- reaches that check: put_boundary repairs with ST_MakeValid before it
-- stores anything, and boundary_geom_valid_chk refuses an invalid geometry
-- written straight to the table. This pins the constraint that makes
-- verify_release's own invalid-geometry branch unreachable.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'inner', 'C');

SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:inner:C', NULL, NULL
);

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
