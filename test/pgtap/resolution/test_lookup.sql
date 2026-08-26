BEGIN;

SELECT geo_genius_test.demo_fixture_build();
SELECT geo_genius.put_area_code('demo_auth:outer:A', 'postal', '30309');
SELECT geo_genius.put_area_name('demo_auth:outer:A', 'Alpha City', 'alias', NULL);

-- Two areas in different states share a slug, which is what makes an
-- unscoped code lookup ambiguous for a host resolving /pa/washington. This
-- extends r1 before publishing (a published release is immutable), so it
-- has to land here rather than after the assertions that depend on r1
-- already being published.
SELECT geo_genius.upsert_area_type('demo', 'state', 5);
SELECT geo_genius.upsert_area_type('demo', 'city', 15);
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'state', 'PA');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'state', 'OH');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'city', 'PA-WASH');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'city', 'OH-WASH');
SELECT geo_genius.put_area_code('demo_auth:city:PA-WASH', 'slug', 'washington');
SELECT geo_genius.put_area_code('demo_auth:city:OH-WASH', 'slug', 'washington');

SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:state:PA', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:state:OH', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:city:PA-WASH', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:city:OH-WASH', NULL, '{}'::jsonb);
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:state:PA', 'demo_auth:city:PA-WASH', 'contains');
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:state:OH', 'demo_auth:city:OH-WASH', 'contains');

SELECT geo_genius_test.demo_publish();

SELECT plan(10);

SELECT is(
  (SELECT area_key FROM geo_genius.areas_by_code('postal', '30309', NULL, NULL)),
  'demo_auth:outer:A',
  'code lookup resolves an area'
);

SELECT is(
  (SELECT match_method FROM geo_genius.areas_by_code('postal', '30309', NULL, NULL)),
  'code',
  'code lookups are stamped as code matches'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_by_code('postal', '99999', NULL, NULL)),
  0,
  'an unknown code matches nothing'
);

SELECT ok(
  (SELECT distance_m FROM geo_genius.areas_near(0.25, 0.25, 100000, NULL, ARRAY['outer'], 10, NULL))
    IS NOT NULL,
  'proximity results carry a distance'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_near(50.0, 50.0, 1000, NULL, NULL, 10, NULL)),
  0,
  'nothing is near a far-away point'
);

SELECT is(
  (SELECT area_key FROM geo_genius.search_areas('Alph', NULL, NULL, 5, NULL) LIMIT 1),
  'demo_auth:outer:A',
  'trigram search finds an area by a name prefix'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_by_code(
     'slug', 'washington', NULL, NULL,
     (SELECT id FROM geo_genius.release WHERE release_key = 'r1'), false)),
  2,
  'an unscoped code lookup returns every area carrying the code'
);

SELECT is(
  (SELECT string_agg(area_key, ',') FROM geo_genius.areas_by_code(
     'slug', 'washington', NULL, NULL,
     (SELECT id FROM geo_genius.release WHERE release_key = 'r1'), false,
     'demo_auth:state:PA')),
  'demo_auth:city:PA-WASH',
  'scoping to a parent keeps only that parent''s descendant'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_by_code(
     'slug', 'washington', NULL, NULL,
     (SELECT id FROM geo_genius.release WHERE release_key = 'r1'), false,
     'demo_auth:state:OH')),
  1,
  'scoping to a different parent selects the other area'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_by_code(
     'slug', 'washington', NULL, NULL,
     (SELECT id FROM geo_genius.release WHERE release_key = 'r1'), false,
     'demo_auth:city:PA-WASH')),
  0,
  'a parent with no descendants carrying the code matches nothing'
);

SELECT finish();

ROLLBACK;
