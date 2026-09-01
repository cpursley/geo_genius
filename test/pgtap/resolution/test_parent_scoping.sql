-- Parent-scoped resolution, by name and by code. search_areas cuts to its own
-- limit before any caller can filter its output, so resolve has to ask for a
-- candidate pool wide enough that scoping still has the right area to find. A
-- handful of unrelated exact-name matches is enough to expose a scoping filter
-- that runs after the cut instead of before it. The code strategy shares the
-- same hazard: a slug is unique only within a parent, so resolve has to thread
-- parent_area_key into areas_by_code rather than reading the whole catalog.
BEGIN;

SELECT plan(5);

SELECT geo_genius_test.demo_fixture_build();
SELECT geo_genius.upsert_area_type('demo', 'city', 50);

-- The one area that is genuinely a child of A.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'city', 'CHILD');
SELECT geo_genius.put_area_in_release(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:city:CHILD', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_name(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:city:CHILD', 'Springfield', 'official', NULL);

-- Thirty areas carrying the same name and no relation to A, enough to fill
-- any candidate list the scoping filter is applied to too late.
DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..30 LOOP
    PERFORM geo_genius.upsert_area('demo', 'demo_auth', 'city', 'NOISE' || i);
    PERFORM geo_genius.put_area_in_release(
      geo_genius_test.demo_run_id(),
      geo_genius_test.demo_executor_id(),
      'demo_auth:city:NOISE' || i, NULL, '{}'::jsonb);
    PERFORM geo_genius.put_area_name(
      geo_genius_test.demo_run_id(),
      geo_genius_test.demo_executor_id(),
      'demo_auth:city:NOISE' || i, 'Springfield', 'official', NULL);
  END LOOP;
END $$;

-- CHILD and one unrelated area carry the same slug, so a code lookup is
-- ambiguous outside a parent scope and unambiguous inside one.
SELECT geo_genius.put_area_code(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:city:CHILD', 'slug', 'springfield');
SELECT geo_genius.put_area_code(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:city:NOISE1', 'slug', 'springfield');

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(),
  'relating');
SELECT geo_genius.put_relation(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:outer:A', 'demo_auth:city:CHILD', 'contains');

SELECT geo_genius_test.demo_publish();

SELECT is(
  (SELECT string_agg(area_key, ',') FROM geo_genius.resolve(
     jsonb_build_object('name', 'Springfield', 'parent_area_key', 'demo_auth:outer:A'),
     NULL, NULL, ARRAY['name'])),
  'demo_auth:city:CHILD',
  'parent scoping finds the child even when unrelated areas share its name'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.search_areas('Springfield', NULL, NULL, 50)),
  31,
  'unscoped name search still returns every area sharing the name'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.resolve(
     jsonb_build_object('name', 'Springfield', 'parent_area_key', 'demo_auth:inner:B'),
     NULL, NULL, ARRAY['name'])),
  0,
  'parent scoping returns nothing when the parent has no matching child'
);

SELECT is(
  (SELECT string_agg(area_key, ',' ORDER BY area_key) FROM geo_genius.resolve(
     jsonb_build_object(
       'code_type', 'slug', 'code_value', 'springfield',
       'parent_area_key', 'demo_auth:outer:A'),
     NULL, NULL, ARRAY['code'])),
  'demo_auth:city:CHILD',
  'parent scoping narrows a code resolution to the scoped area'
);

SELECT is(
  (SELECT string_agg(area_key, ',' ORDER BY area_key) FROM geo_genius.resolve(
     jsonb_build_object('code_type', 'slug', 'code_value', 'springfield'),
     NULL, NULL, ARRAY['code'])),
  'demo_auth:city:CHILD,demo_auth:city:NOISE1',
  'an unscoped code resolution still returns every area carrying the code'
);

SELECT finish();

ROLLBACK;
