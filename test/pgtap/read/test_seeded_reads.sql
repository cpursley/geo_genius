BEGIN;

-- r1 is extended below, so it is built unpublished and published once the
-- whole graph is in place: a published release is immutable.
SELECT geo_genius_test.demo_fixture_build();

-- Two more outer areas: P contains one inner area, Z contains none. A seed
-- with no children is what separates a plural read that drops it from one
-- that pads it with a row of nulls.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'P');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'inner', 'Q');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'Z');
SELECT geo_genius.put_area_name('demo_auth:outer:P', 'Papa', 'official', NULL);
SELECT geo_genius.put_area_name('demo_auth:inner:Q', 'Quebec', 'official', NULL);
SELECT geo_genius.put_area_name('demo_auth:outer:Z', 'Zulu', 'official', NULL);

SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:outer:P',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((10 10, 11 10, 11 11, 10 11, 10 10))', 4326), 0.0);

SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:inner:Q',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((10 10, 10.5 10, 10.5 10.5, 10 10.5, 10 10))', 4326), 0.0);

SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:outer:Z',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((20 20, 21 20, 21 21, 20 21, 20 20))', 4326), 0.0);

SELECT geo_genius.put_area_code('demo_auth:outer:A', 'fips', '01');
SELECT geo_genius.put_area_code('demo_auth:outer:P', 'fips', '02');

-- B is the row the whole-projection comparison below reads, so it is given a
-- code and attributes of its own. Left as the bare fixture builds it, its
-- codes and attributes come back NULL and empty on both sides of that
-- comparison, and a column dropped from the plural projection would match a
-- column dropped from nothing. Its centroid is restated because
-- put_area_in_release overwrites that column with whatever it is handed.
SELECT geo_genius.put_area_code('demo_auth:inner:B', 'fips', '01001');
SELECT geo_genius.put_area_code('demo_auth:inner:B', 'postal', '30309');
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:inner:B',
  ST_GeogFromText('POINT(0.25 0.25)'),
  '{"population": 4200, "lsad": "town"}'::jsonb);

SELECT geo_genius.rebuild_relations(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'));

SELECT geo_genius_test.demo_publish();

SELECT plan(14);

SELECT is(
  (SELECT array_agg(seed_key || '>' || area_key)
     FROM geo_genius.children_of_many(
            ARRAY['demo_auth:outer:A', 'demo_auth:outer:P'], NULL, NULL, 1, NULL)),
  ARRAY['demo_auth:outer:A>demo_auth:inner:B', 'demo_auth:outer:P>demo_auth:inner:Q'],
  'each row carries the seed that produced it'
);

-- A CROSS JOIN LATERAL drops a seed that matched nothing. A LEFT JOIN would
-- keep it as one row whose every area column is null, which a caller would
-- have to filter out and which no type could distinguish from a real match.
SELECT is(
  (SELECT array_agg(seed_key || '>' || coalesce(area_key, '<null>'))
     FROM geo_genius.children_of_many(
            ARRAY['demo_auth:outer:A', 'demo_auth:outer:Z'], NULL, NULL, 1, NULL)),
  ARRAY['demo_auth:outer:A>demo_auth:inner:B'],
  'a seed with no children contributes zero rows rather than a row of nulls'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.children_of_many(ARRAY[]::text[], NULL, NULL, 1, NULL)),
  0,
  'an empty seed array returns zero rows'
);

SELECT throws_ok(
  $$SELECT * FROM geo_genius.children_of_many(NULL::text[], NULL, NULL, 1, NULL)$$,
  '22004',
  NULL,
  'a null seed array is rejected the way a null singular seed is'
);

SELECT throws_ok(
  $$SELECT * FROM geo_genius.children_of_many(
      ARRAY['demo_auth:outer:A', NULL], NULL, NULL, 1, NULL)$$,
  '22004',
  NULL,
  'a null element inside the seed array is rejected rather than silently dropped'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.children_of_many(ARRAY['demo_auth:outer:nope'], NULL, NULL, 1, NULL)),
  0,
  'a seed no area carries returns zero rows'
);

-- Ordering follows the array the caller passed, not the sort order of the
-- seeds themselves: a caller zipping results back onto its own list depends
-- on it.
SELECT is(
  (SELECT array_agg(seed_key)
     FROM geo_genius.children_of_many(
            ARRAY['demo_auth:outer:P', 'demo_auth:outer:A'], NULL, NULL, 1, NULL)),
  ARRAY['demo_auth:outer:P', 'demo_auth:outer:A'],
  'rows come back in the seed array''s order, not the seeds'' sort order'
);

-- The expected side carries its own seed ordinal and sorts on it explicitly.
-- A bare UNION ALL feeding array_agg would be relying on the planner to append
-- its branches in written order, which no plan is obliged to do; this test
-- would then fail on a plan change with no defect behind it. Ordering within
-- a seed is area_key, which children_of has already collapsed to one row per
-- area, so the expected array is fully determined. The actual side stays
-- unordered on purpose: the row order children_of_many emits is what is
-- under test.
SELECT is(
  (SELECT array_agg(area_key)
     FROM geo_genius.children_of_many(
            ARRAY['demo_auth:outer:A', 'demo_auth:outer:P'], NULL, NULL, 1, NULL)),
  (SELECT array_agg(area_key ORDER BY seed_ord, area_key) FROM (
     SELECT 1 AS seed_ord, area_key
       FROM geo_genius.children_of('demo_auth:outer:A', NULL, NULL, 1, NULL)
     UNION ALL
     SELECT 2 AS seed_ord, area_key
       FROM geo_genius.children_of('demo_auth:outer:P', NULL, NULL, 1, NULL)
   ) singular),
  'the plural result equals the singular results concatenated in seed order'
);

-- Every column, not a sample of them: to_jsonb renders the whole row keyed by
-- column name, and dropping seed_key from the plural side leaves exactly
-- area_match's sixteen. Comparing by name rather than by position also means
-- this catches a value landing in the wrong column, which a positional
-- comparison of the same sixteen values would not.
SELECT is(
  (SELECT to_jsonb(plural) - 'seed_key'
     FROM geo_genius.children_of_many(
            ARRAY['demo_auth:outer:A'], NULL, NULL, 1, NULL) plural),
  (SELECT to_jsonb(singular)
     FROM geo_genius.children_of('demo_auth:outer:A', NULL, NULL, 1, NULL) singular),
  'the plural row projects every area_match column with the value the singular read gives it'
);

SELECT is(
  (SELECT array_agg(seed_key || '>' || area_key)
     FROM geo_genius.ancestors_of_many(
            ARRAY['demo_auth:inner:B', 'demo_auth:inner:Q'], NULL, NULL, 1, NULL)),
  ARRAY['demo_auth:inner:B>demo_auth:outer:A', 'demo_auth:inner:Q>demo_auth:outer:P'],
  'ancestors_of_many attributes each ancestor to the seed it was reached from'
);

SELECT is(
  (SELECT array_agg(seed_key || '>' || area_key)
     FROM geo_genius.related_areas_many(
            ARRAY['demo_auth:inner:B', 'demo_auth:inner:Q'], NULL, NULL)),
  ARRAY['demo_auth:inner:B>demo_auth:outer:A', 'demo_auth:inner:Q>demo_auth:outer:P'],
  'related_areas_many attributes each relation to the seed it was reached from'
);

-- The seed here is a code value, not an area key, which is why the column is
-- named seed_key rather than seed_area_key.
SELECT is(
  (SELECT array_agg(seed_key || '>' || area_key)
     FROM geo_genius.areas_by_code_many('fips', ARRAY['01', '02'], NULL, NULL, NULL)),
  ARRAY['01>demo_auth:outer:A', '02>demo_auth:outer:P'],
  'areas_by_code_many attributes each area to the code value that found it'
);

SELECT throws_ok(
  $$SELECT * FROM geo_genius.areas_by_code_many(NULL, ARRAY['01'], NULL, NULL, NULL)$$,
  '22004',
  NULL,
  'areas_by_code_many still requires a code type'
);

SELECT throws_ok(
  $$SELECT * FROM geo_genius.areas_by_code_many('fips', NULL::text[], NULL, NULL, NULL)$$,
  '22004',
  NULL,
  'areas_by_code_many rejects a null code value array'
);

SELECT finish();

ROLLBACK;
