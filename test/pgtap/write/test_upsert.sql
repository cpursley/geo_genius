BEGIN;

SELECT plan(10);

SELECT geo_genius.upsert_collection('demo', 'Demo', NULL);
SELECT geo_genius.upsert_authority('demo', 'demo_auth', 'Demo Authority');
SELECT geo_genius.upsert_area_type('demo', 'outer', 10);
SELECT geo_genius.upsert_area_type('demo', 'inner', 20);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_authority('nope', 'a', 'A')$$,
  '23503',
  NULL,
  'upsert_authority refuses an unknown collection'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_area_type('nope', 't', 10)$$,
  '23503',
  NULL,
  'upsert_area_type refuses an unknown collection'
);

SELECT is(
  geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'A')::text,
  geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'A')::text,
  'upsert_area is idempotent'
);

SELECT is(
  (SELECT area_key FROM geo_genius.area WHERE code = 'A'),
  'demo_auth:outer:A',
  'area_key is composed from authority, type, and code'
);

SELECT geo_genius.upsert_area('demo', 'demo_auth', 'inner', 'B');

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"demo",
    "release":"demo-2026",
    "collection_name":"Demo",
    "requires_geometry":false,
    "authorities":[{"key":"demo_auth","name":"Demo Authority"}],
    "area_types":[
      {"key":"outer","rank":10,"requires_geometry":false},
      {"key":"inner","rank":20,"requires_geometry":false}
    ]
  }'::jsonb,
  '{"owner":"pgtap-upsert","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('demo', 'demo-2026'));

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'demo-2026'),
  geo_genius_test.import_executor_id('demo', 'demo-2026'),
  'normalizing');

INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'demo:src', 'demo', 'test' FROM geo_genius.collection WHERE key = 'demo';

INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'demo:src';

INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'demo-2026';

-- A 1-degree square and a 0.5-degree square fully inside it.
SELECT geo_genius.put_boundary(
  geo_genius_test.import_run_id('demo', 'demo-2026'),
  geo_genius_test.import_executor_id('demo', 'demo-2026'),
  'demo_auth:outer:A',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326),
  0.0
);

SELECT geo_genius.put_boundary(
  geo_genius_test.import_run_id('demo', 'demo-2026'),
  geo_genius_test.import_executor_id('demo', 'demo-2026'),
  'demo_auth:inner:B',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((0.1 0.1, 0.6 0.1, 0.6 0.6, 0.1 0.6, 0.1 0.1))', 4326),
  0.0
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.boundary),
  2,
  'both boundaries stored'
);

SELECT ok(
  (SELECT count(*) FROM geo_genius.boundary_part) >= 2,
  'subdivided parts were generated'
);

SELECT ok(
  (SELECT centroid IS NOT NULL FROM geo_genius.release_area a
     JOIN geo_genius.area ar ON ar.id = a.area_id
    WHERE ar.code = 'A'),
  'centroid recorded for the outer area'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_boundary(
      geo_genius_test.import_run_id('demo', 'demo-2026'),
      geo_genius_test.import_executor_id('demo', 'demo-2026'),
      'demo_auth:outer:A',
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      ST_GeomFromText('POINT(0 0)', 4326),
      0.0
    )$$,
  '22023',
  NULL,
  'put_boundary rejects non-polygonal geometry'
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'demo-2026'),
  geo_genius_test.import_executor_id('demo', 'demo-2026'),
  'relating'
);

SELECT is(
  geo_genius.rebuild_relations(
    geo_genius_test.import_run_id('demo', 'demo-2026'),
    geo_genius_test.import_executor_id('demo', 'demo-2026')
  ),
  1::bigint,
  'one containment relation measured'
);

SELECT is(
  (SELECT relation_type FROM geo_genius.relation),
  'contains',
  'a fully enclosed child is classified as contained'
);

SELECT finish();

ROLLBACK;
