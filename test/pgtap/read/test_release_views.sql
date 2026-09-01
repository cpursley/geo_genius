BEGIN;

SELECT plan(27);

-- The release-scoped bases every published_* view builds on. published_areas
-- has had release_areas under it since the catalog was first installed; these
-- three give the other three published views the same shape, so a caller
-- holding a release id can read that release before it is published.
SELECT has_view('geo_genius', 'release_area_codes', 'release_area_codes exists');
SELECT has_view('geo_genius', 'release_area_names', 'release_area_names exists');
SELECT has_view('geo_genius', 'release_relations', 'release_relations exists');

-- Column parity, read out of the catalog rather than hand-listed: a column
-- added to one side of a pair and not the other, or reordered in one and not
-- the other, fails here. Name and type both, because two same-typed columns
-- transposed would otherwise pass.
CREATE FUNCTION pg_temp.view_signature(view_name text)
RETURNS text[]
LANGUAGE sql
AS $fn$
  SELECT array_agg(attname::text || ' ' || atttypid::regtype::text ORDER BY attnum)
    FROM pg_attribute
   WHERE attrelid = ('geo_genius.' || view_name)::regclass
     AND attnum > 0
     AND NOT attisdropped;
$fn$;

SELECT is(
  pg_temp.view_signature('release_areas'),
  pg_temp.view_signature('published_areas'),
  'release_areas projects exactly published_areas'' columns'
);

SELECT is(
  pg_temp.view_signature('release_area_codes'),
  pg_temp.view_signature('published_area_codes'),
  'release_area_codes projects exactly published_area_codes'' columns'
);

SELECT is(
  pg_temp.view_signature('release_area_names'),
  pg_temp.view_signature('published_area_names'),
  'release_area_names projects exactly published_area_names'' columns'
);

SELECT is(
  pg_temp.view_signature('release_relations'),
  pg_temp.view_signature('published_area_relations'),
  'release_relations projects exactly published_area_relations'' columns'
);

-- r1, published, carrying a code, an alias name, and one relation. r2 opened
-- afterwards over the same two areas, deliberately never published: it is the
-- release a host wants to verify or project ahead of go-live.
SELECT geo_genius_test.demo_fixture_build();
SELECT geo_genius.put_area_code(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:outer:A', 'postal', '30309');
SELECT geo_genius.put_area_name(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:outer:A', 'Alfa', 'alias', NULL);
SELECT geo_genius_test.advance_import_to(
  geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(),
  'relating');
SELECT geo_genius.put_relation(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:outer:A', 'demo_auth:inner:B', 'contains');
SELECT geo_genius_test.demo_publish();

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"demo",
    "release":"r2",
    "collection_name":"Candidate Demo",
    "requires_geometry":true,
    "authorities":[{"key":"demo_auth","name":"Candidate Authority"}],
    "area_types":[
      {"key":"outer","rank":5,"requires_geometry":true},
      {"key":"inner","rank":25,"requires_geometry":true}
    ]
  }'::jsonb,
  '{"owner":"pgtap-release-views","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('demo', 'r2'));
SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'r2'),
  geo_genius_test.import_executor_id('demo', 'r2'),
  'normalizing');
SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('demo', 'r2'),
  geo_genius_test.import_executor_id('demo', 'r2'),
  'demo_auth:outer:A', ST_GeogFromText('POINT(0.25 0.25)'), '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('demo', 'r2'),
  geo_genius_test.import_executor_id('demo', 'r2'),
  'demo_auth:inner:B', ST_GeogFromText('POINT(0.25 0.25)'), '{}'::jsonb);
SELECT geo_genius.put_area_code(
  geo_genius_test.import_run_id('demo', 'r2'),
  geo_genius_test.import_executor_id('demo', 'r2'),
  'demo_auth:outer:A', 'postal', '30309');
SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('demo', 'r2'),
  geo_genius_test.import_executor_id('demo', 'r2'),
  'demo_auth:outer:A', 'Alfa', 'alias', NULL);

SELECT lives_ok(
  $$SELECT geo_genius.put_area_name(
      geo_genius_test.import_run_id('demo', 'r2'),
      geo_genius_test.import_executor_id('demo', 'r2'),
      'demo_auth:outer:A', 'Aardvark Candidate', 'official', NULL)$$,
  'a candidate writes its official name under its own release'
);

SELECT lives_ok(
  $$SELECT geo_genius.put_area_code(
      geo_genius_test.import_run_id('demo', 'r2'),
      geo_genius_test.import_executor_id('demo', 'r2'),
      'demo_auth:outer:A', 'postal', '99999')$$,
  'a candidate writes its external code under its own release'
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'r2'),
  geo_genius_test.import_executor_id('demo', 'r2'),
  'relating');
SELECT geo_genius.put_relation(
  geo_genius_test.import_run_id('demo', 'r2'),
  geo_genius_test.import_executor_id('demo', 'r2'),
  'demo_auth:inner:B', 'demo_auth:outer:A', 'overlaps');

CREATE FUNCTION pg_temp.release_id(key text)
RETURNS uuid
LANGUAGE sql
AS $fn$
  SELECT id FROM geo_genius.release WHERE release_key = key;
$fn$;

SELECT is(
  (SELECT count(*)::int FROM geo_genius.release_areas
    WHERE release_id = pg_temp.release_id('r2')),
  2,
  'release_areas carries the staged release''s memberships'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_areas
    WHERE release_id = pg_temp.release_id('r2')),
  0,
  'published_areas still shows nothing of the staged release'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.release_area_codes
    WHERE release_id = pg_temp.release_id('r2') AND code_value = '30309'),
  1,
  'release_area_codes carries the staged release''s codes'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_area_codes
    WHERE release_id = pg_temp.release_id('r2')),
  0,
  'published_area_codes still shows nothing of the staged release'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.release_area_names
    WHERE release_id = pg_temp.release_id('r2') AND kind = 'alias'),
  1,
  'release_area_names carries the staged release''s names'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_area_names
    WHERE release_id = pg_temp.release_id('r2')),
  0,
  'published_area_names still shows nothing of the staged release'
);

SELECT is(
  (SELECT relation_type FROM geo_genius.release_relations
    WHERE release_id = pg_temp.release_id('r2')),
  'overlaps',
  'release_relations carries the staged release''s edge'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_area_relations
    WHERE release_id = pg_temp.release_id('r2')),
  0,
  'published_area_relations still shows nothing of the staged release'
);

-- The reason the codes and names bases carry release_id at all. area_code
-- hangs off the area, and the area belongs to both releases, so without
-- release_id on the projection the same code would come back twice with
-- nothing on the row to say which release each row is speaking for.
SELECT is(
  (SELECT count(DISTINCT release_id)::int FROM geo_genius.release_area_codes
    WHERE area_key = 'demo_auth:outer:A' AND code_value = '30309'),
  2,
  'a code held by an area in two releases is one distinguishable row per release'
);

SELECT is(
  (SELECT release_id FROM geo_genius.published_area_codes
    WHERE area_key = 'demo_auth:outer:A' AND code_value = '30309'),
  geo_genius.published_release('demo'),
  'published_area_codes stamps every row with the release publication resolves'
);

-- No release mixing at the source: every relation row is reported under its
-- own release_id, so a caller joining release_relations to release_areas on
-- release_id can never pair an edge of one release with an area of another.
SELECT is(
  (SELECT count(*)::int FROM geo_genius.release_relations base
     JOIN geo_genius.relation source
       ON source.parent_area_id = base.parent_area_id
      AND source.child_area_id = base.child_area_id
      AND source.release_id <> base.release_id),
  0,
  'release_relations never reports an edge under a release other than its own'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.release_relations edge
     JOIN geo_genius.release_areas area
       ON area.area_key = edge.child_area_key
      AND area.release_id = edge.release_id
    WHERE edge.release_id = pg_temp.release_id('r2')),
  1,
  'joining release_relations to release_areas on release_id keeps one release'
);

-- A candidate and a published release may share the same stable area row.
-- Candidate-selected names, codes, declaration labels, ranks and geometry
-- policy must remain facts of that candidate rather than mutations visible
-- through the published release.
SELECT is(
  (SELECT name FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:A'),
  'Alpha',
  'candidate official-name changes cannot contaminate the published release'
);

SELECT is(
  (SELECT array_agg(code_value ORDER BY code_value)
     FROM geo_genius.published_area_codes
    WHERE area_key = 'demo_auth:outer:A' AND code_type = 'postal'),
  ARRAY['30309']::text[],
  'candidate code changes cannot contaminate the published release'
);

SELECT is(
  (SELECT type_rank FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:A'),
  10,
  'candidate rank changes cannot contaminate the published release'
);

SELECT is(
  (SELECT array_agg(release_authority.name ORDER BY release.release_key)
     FROM geo_genius.release_authority
     JOIN geo_genius.release ON release.id = release_authority.release_id
    WHERE release.release_key IN ('r1', 'r2')
      AND release_authority.authority_id = (
        SELECT id FROM geo_genius.authority WHERE key = 'demo_auth')),
  ARRAY['Demo Authority', 'Candidate Authority']::text[],
  'authority descriptors remain exact declarations of their own releases'
);

SELECT is(
  (SELECT array_agg(policy.requires_geometry ORDER BY release.release_key)
     FROM geo_genius.release_collection_policy policy
     JOIN geo_genius.release ON release.id = policy.release_id
    WHERE release.release_key IN ('r1', 'r2')),
  ARRAY[false, true]::boolean[],
  'collection geometry policy remains exact to each release'
);

SELECT lives_ok(
  $$SELECT geo_genius.verify_release(pg_temp.release_id('r1'))$$,
  'candidate geometry-policy changes cannot invalidate the published release'
);

SELECT finish();

ROLLBACK;
