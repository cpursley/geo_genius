BEGIN;

SELECT plan(38);

SELECT has_function('geo_genius', 'upsert_source', 'upsert_source exists');
SELECT has_function('geo_genius', 'upsert_source_release', 'upsert_source_release exists');
SELECT has_function('geo_genius', 'put_artifact', 'put_artifact exists');
SELECT has_function('geo_genius', 'record_artifact_observation',
  'record_artifact_observation exists');
SELECT has_function('geo_genius', 'open_release', 'open_release exists');
SELECT has_function('geo_genius', 'attach_source_release', 'attach_source_release exists');

SELECT geo_genius.upsert_collection('demo', 'Demo', NULL);

-- upsert_source

SELECT ok(
  geo_genius.upsert_source('demo', 'demo:src', 'geojson', 'CC0') IS NOT NULL,
  'upsert_source creates a source'
);

SELECT is(
  geo_genius.upsert_source('demo', 'demo:src', 'geojson', 'ODbL'),
  (SELECT id FROM geo_genius.source WHERE source_key = 'demo:src'),
  'upsert_source is idempotent on (collection, source_key)'
);

SELECT is(
  (SELECT license FROM geo_genius.source WHERE source_key = 'demo:src'),
  'ODbL',
  'upsert_source updates the license in place'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_source('nope', 'x', 'geojson', 'CC0')$$,
  '23503',
  NULL,
  'upsert_source refuses an unknown collection'
);

-- upsert_source_release

SELECT ok(
  geo_genius.upsert_source_release('demo', 'demo:src', 'v1', DATE '2026-01-15', '{"a":1}'::jsonb)
    IS NOT NULL,
  'upsert_source_release creates a vintage'
);

SELECT is(
  (SELECT metadata FROM geo_genius.source_release WHERE release_key = 'v1'),
  '{"a":1}'::jsonb,
  'upsert_source_release stores its metadata'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_source_release('demo', 'missing:src', 'v1', NULL, '{}'::jsonb)$$,
  '23503',
  NULL,
  'upsert_source_release refuses an unknown source'
);

-- put_artifact

SELECT ok(
  geo_genius.put_artifact(
    (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
    'areas.geojson',
    'https://example.test/areas.geojson',
    false,
    'geojson',
    repeat('a', 64),
    1024,
    '{"required":true}'::jsonb
  ) IS NOT NULL,
  'put_artifact records a downloadable artifact'
);

-- The same logical name again: an upsert, not a second row.
SELECT geo_genius.put_artifact(
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  'areas.geojson',
  'https://example.test/areas-corrected.geojson',
  false,
  'geojson',
  repeat('a', 64),
  1024,
  '{"required":true}'::jsonb
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.artifact),
  1,
  'put_artifact is idempotent on (source_release, logical_name)'
);

SELECT is(
  (SELECT url FROM geo_genius.artifact WHERE logical_name = 'areas.geojson'),
  'https://example.test/areas-corrected.geojson',
  'put_artifact updates the url in place'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_artifact(
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      'bad.geojson', 'https://example.test/bad', true, 'geojson', repeat('a', 64), 1, '{}'::jsonb)$$,
  '23514',
  NULL,
  'put_artifact refuses an artifact that is both operator-supplied and downloadable'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_artifact(
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      'bad.geojson', NULL, false, 'geojson', repeat('a', 64), 1, '{}'::jsonb)$$,
  '23514',
  NULL,
  'put_artifact refuses an artifact that is neither operator-supplied nor downloadable'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_artifact(
      '00000000-0000-0000-0000-000000000000'::uuid,
      'orphan.geojson', 'https://example.test/orphan', false, 'geojson',
      repeat('a', 64), 1, '{}'::jsonb)$$,
  '23503',
  'source release 00000000-0000-0000-0000-000000000000 does not exist',
  'put_artifact refuses a source release that does not exist'
);

-- The write side normalizes a digest exactly as record_artifact_observation
-- does below. artifact_expected_sha256_check is `^[0-9a-f]{64}$`, so without
-- the lower() an uppercase manifest digest stops being stored and starts
-- raising a raw 23514 from inside put_artifact. Asserting the stored value
-- rather than merely that the call lived also pins which way it normalized.
-- Wrapped rather than issued bare: without the lower() this raises a check
-- violation, and a bare statement would abort the whole file's transaction
-- and take every later assertion with it instead of naming this one.
SELECT lives_ok(
  $$SELECT geo_genius.put_artifact(
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      'upper.geojson', 'https://example.test/upper', false, 'geojson',
      upper(repeat('a', 64)), 2048, '{}'::jsonb)$$,
  'put_artifact accepts an uppercase expected digest instead of raising'
);

SELECT is(
  (SELECT expected_sha256 FROM geo_genius.artifact WHERE logical_name = 'upper.geojson'),
  repeat('a', 64),
  'put_artifact normalizes an uppercase expected digest instead of raising'
);

-- record_artifact_observation

SELECT geo_genius.record_artifact_observation(
  (SELECT id FROM geo_genius.artifact WHERE logical_name = 'areas.geojson'),
  repeat('a', 64),
  1024
);

SELECT ok(
  (SELECT validated_at FROM geo_genius.artifact WHERE logical_name = 'areas.geojson')
    IS NOT NULL,
  'record_artifact_observation stamps validated_at'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'areas.geojson'),
      repeat('b', 64), 9)$$,
  '23514',
  NULL,
  'record_artifact_observation refuses an observation that contradicts the expectation'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'areas.geojson'),
      repeat('b', 64), 1024)$$,
  '23514',
  NULL,
  'record_artifact_observation refuses a digest that does not match, even with the right byte count'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'areas.geojson'),
      repeat('a', 64), 9)$$,
  '23514',
  NULL,
  'record_artifact_observation refuses a byte count that does not match, even with the right digest'
);

SELECT lives_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'areas.geojson'),
      repeat('A', 64), 1024)$$,
  'record_artifact_observation normalizes an uppercase digest instead of raising'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      '00000000-0000-0000-0000-000000000000'::uuid, repeat('a', 64), 1024)$$,
  '23503',
  'artifact 00000000-0000-0000-0000-000000000000 does not exist',
  'record_artifact_observation refuses an artifact that does not exist'
);

-- open_release

SELECT throws_ok(
  $$SELECT geo_genius.open_release('no_such_collection', 'r1', '{}'::jsonb, NULL)$$,
  '23503',
  'collection no_such_collection does not exist',
  'open_release refuses a collection that does not exist'
);

SELECT ok(
  geo_genius.open_release('demo', 'r1', '{"release":"r1"}'::jsonb, DATE '2026-01-15')
    IS NOT NULL,
  'open_release creates a release'
);

SELECT is(
  (SELECT count(*)::int FROM pg_class, LATERAL (
     SELECT replace(release.id::text, '-', '') AS suffix
       FROM geo_genius.release WHERE release.release_key = 'r1'
   ) r
    WHERE pg_class.relname IN (
      'boundary_' || r.suffix,
      'boundary_part_' || r.suffix,
      'relation_' || r.suffix,
      'release_area_' || r.suffix
    )),
  4,
  'open_release creates all four release partitions'
);

SELECT is(
  geo_genius.open_release('demo', 'r1', '{"v":2}'::jsonb, NULL),
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'open_release reopens an unpublished release rather than duplicating it'
);

SELECT is(
  (SELECT manifest FROM geo_genius.release WHERE release_key = 'r1'),
  '{"v":2}'::jsonb,
  'reopening replaces the stored manifest rather than merging into it'
);

-- attach_source_release

SELECT geo_genius.attach_source_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')
);

SELECT geo_genius.attach_source_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.release_source),
  1,
  'attach_source_release is idempotent'
);

SELECT throws_ok(
  $$SELECT geo_genius.attach_source_release(
      '00000000-0000-0000-0000-000000000000'::uuid,
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'))$$,
  '23503',
  NULL,
  'attach_source_release refuses an unknown release'
);

SELECT throws_ok(
  $$SELECT geo_genius.attach_source_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      '00000000-0000-0000-0000-000000000000'::uuid)$$,
  '23503',
  'source release 00000000-0000-0000-0000-000000000000 does not exist',
  'attach_source_release refuses a source release that does not exist'
);

SELECT geo_genius.upsert_collection('other', 'Other', NULL);
SELECT geo_genius.upsert_source('other', 'other:src', 'geojson', 'CC0');
SELECT geo_genius.upsert_source_release('other', 'other:src', 'ov1', NULL, '{}'::jsonb);

SELECT throws_ok(
  $$SELECT geo_genius.attach_source_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'ov1'))$$,
  '23503',
  NULL,
  'attach_source_release refuses a source release from a different collection'
);

-- A published release is closed to reopening.

SELECT geo_genius.upsert_authority('demo', 'a', 'A');
SELECT geo_genius.upsert_area_type('demo', 't', 10);
SELECT geo_genius.upsert_area('demo', 'a', 't', 'c');
SELECT geo_genius.put_area_name('a:t:c', 'Area', 'official', NULL);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'a:t:c', ST_GeogFromText('POINT(0 0)'), '{}'::jsonb);

SELECT geo_genius.upsert_source_release('demo', 'demo:src', 'v2', NULL, '{}'::jsonb);

SELECT geo_genius.publish_release((SELECT id FROM geo_genius.release WHERE release_key = 'r1'));

-- A published release is immutable, and provenance is part of what it
-- publishes: release_artifacts joins through release_source, so attaching a
-- source release after publication changes what readers of a published
-- release see. The sibling writes (put_area_in_release, put_boundary,
-- put_relation, rebuild_relations) all refuse a completed release; this one
-- must too.
SELECT throws_ok(
  $$SELECT geo_genius.attach_source_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v2'))$$,
  '55000',
  NULL,
  'attach_source_release refuses to add provenance to a published release'
);

SELECT throws_ok(
  $$SELECT geo_genius.open_release('demo', 'r1', '{}'::jsonb, NULL)$$,
  '55000',
  NULL,
  'open_release refuses to reopen a published release'
);

SELECT finish();

ROLLBACK;
