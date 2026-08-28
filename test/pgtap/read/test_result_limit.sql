BEGIN;

-- A caller with no way to say "return everything" has to name a number large
-- enough to stand in for one, and a number is only ever a guess about how many
-- areas a collection publishes. These read `result_limit` at its three
-- distinct values: absent, explicitly NULL, and a number.
--
-- Sixty probe areas is what separates them. Fewer than the default of 50 and
-- an absent limit answers with the same rows an unlimited read does, so the
-- default could be dropped and nothing here would notice.

SELECT geo_genius_test.demo_fixture_build();

SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'PROBE-' || to_char(g, 'FM00'))
  FROM generate_series(1, 60) AS g;

SELECT geo_genius.put_area_name(
  'demo_auth:outer:PROBE-' || to_char(g, 'FM00'),
  'Probeton ' || to_char(g, 'FM00'),
  'official', NULL)
  FROM generate_series(1, 60) AS g;

-- The probes sit far from the fixture's own areas, so the proximity reads
-- below measure the probes and nothing else.
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:outer:PROBE-' || to_char(g, 'FM00'),
  ST_GeogFromText('POINT(' || (100 + g * 0.001)::text || ' 40)'),
  '{}'::jsonb)
  FROM generate_series(1, 60) AS g;

SELECT geo_genius_test.demo_publish();

SELECT plan(6);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.search_areas('Probeton', NULL, NULL, NULL)),
  60,
  'search_areas with an explicit null limit returns every match'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.search_areas('Probeton', NULL, NULL)),
  50,
  'search_areas with no limit returns the default 50'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.search_areas('Probeton', NULL, NULL, 5)),
  5,
  'search_areas cuts to the limit it is given'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_near(100.03, 40.0, 20000, NULL, NULL, NULL)),
  60,
  'areas_near with an explicit null limit returns every area in the radius'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_near(100.03, 40.0, 20000, NULL, NULL)),
  50,
  'areas_near with no limit returns the default 50'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_near(100.03, 40.0, 20000, NULL, NULL, 5)),
  5,
  'areas_near cuts to the limit it is given'
);

SELECT finish();

ROLLBACK;
