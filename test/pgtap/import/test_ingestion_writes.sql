BEGIN;

SELECT plan(62);

SELECT has_column('geo_genius', 'import_run', 'manifest',
  'import_run stores the exact manifest claimed by each attempt');
SELECT col_not_null('geo_genius', 'import_run', 'manifest',
  'an import run manifest snapshot is required');
SELECT has_table('geo_genius', 'release_artifact',
  'release_artifact stores the exact artifact set selected by a release');
SELECT has_table('geo_genius', 'import_run_artifact',
  'import_run_artifact stores observations for one attempt');
SELECT has_table('geo_genius', 'release_area_name',
  'release_area_name scopes selected names to one release');
SELECT has_table('geo_genius', 'release_area_code',
  'release_area_code scopes selected codes to one release');
SELECT has_table('geo_genius', 'release_authority',
  'release_authority snapshots authority declarations by release');
SELECT has_table('geo_genius', 'release_area_type',
  'release_area_type snapshots area type declarations by release');
SELECT has_column('geo_genius', 'release_collection_policy', 'requires_geometry',
  'release_collection_policy snapshots the collection geometry policy');
SELECT has_function(
  'geo_genius', 'put_area_name', ARRAY['uuid', 'uuid', 'text', 'text', 'text', 'text'],
  'put_area_name requires the import run and executor that own the write');
SELECT has_function(
  'geo_genius', 'put_area_code', ARRAY['uuid', 'uuid', 'text', 'text', 'text'],
  'put_area_code requires the import run and executor that own the write');
SELECT has_function(
  'geo_genius', 'attach_artifact', ARRAY['uuid', 'uuid'],
  'attach_artifact selects an exact artifact for one release');
SELECT has_function(
  'geo_genius', 'record_artifact_observation', ARRAY['uuid', 'uuid', 'uuid', 'text', 'bigint'],
  'record_artifact_observation requires the attempt executor that observed it');

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
  geo_genius.upsert_source('demo', 'demo:src', 'geojson', 'CC0'),
  (SELECT id FROM geo_genius.source WHERE source_key = 'demo:src'),
  'upsert_source is idempotent for an identical semantic definition'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_source('demo', 'demo:src', 'geojson', 'ODbL')$$,
  '55000',
  NULL,
  'upsert_source refuses a conflicting descriptor under the same key'
);

SELECT is(
  (SELECT license FROM geo_genius.source WHERE source_key = 'demo:src'),
  'CC0',
  'a refused source conflict leaves the existing definition unchanged'
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

SELECT is(
  geo_genius.upsert_source_release(
    'demo', 'demo:src', 'v1', DATE '2026-01-15', '{"a":1}'::jsonb),
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  'upsert_source_release is idempotent for an identical semantic definition'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_source_release(
      'demo', 'demo:src', 'v1', DATE '2026-01-16', '{"a":2}'::jsonb)$$,
  '55000',
  NULL,
  'upsert_source_release refuses changed date or metadata under the same key'
);

SELECT is(
  (SELECT source_date::text || ':' || metadata::text
     FROM geo_genius.source_release WHERE release_key = 'v1'),
  '2026-01-15:{"a": 1}',
  'a refused source-release conflict leaves the existing definition unchanged'
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

SELECT is(
  geo_genius.put_artifact(
    (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
    'areas.geojson', 'https://example.test/areas.geojson', false, 'geojson',
    repeat('a', 64), 1024, '{"required":true}'::jsonb),
  (SELECT id FROM geo_genius.artifact WHERE logical_name = 'areas.geojson'),
  'put_artifact is idempotent for an identical semantic definition'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_artifact(
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      'areas.geojson', 'https://example.test/areas-corrected.geojson', false,
      'geojson', repeat('a', 64), 1024, '{"required":true}'::jsonb)$$,
  '55000',
  NULL,
  'put_artifact refuses a conflicting definition under the same logical name'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.artifact),
  1,
  'put_artifact keeps one immutable row per semantic identity'
);

SELECT is(
  (SELECT url FROM geo_genius.artifact WHERE logical_name = 'areas.geojson'),
  'https://example.test/areas.geojson',
  'a refused artifact conflict leaves the existing definition unchanged'
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

CREATE TEMP TABLE observation_manifest AS
SELECT '{
  "collection":"demo","collection_name":"Demo","release":"observation-run",
  "requires_geometry":false,
  "authorities":[{"key":"observation_auth","name":"Observation Authority"}],
  "area_types":[{"key":"observation_area","rank":10,"requires_geometry":false}],
  "sources":[{
    "source_key":"demo:observation-src","provider":"geojson","license":"CC0",
    "release_key":"observation-v1","artifacts":[{
      "logical_name":"observed.geojson","url":"https://example.test/observed.geojson",
      "format":"geojson",
      "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bytes":1024
    }]
  }]
}'::jsonb AS manifest;

SELECT * FROM geo_genius.prepare_import(
  (SELECT manifest FROM observation_manifest),
  '{"owner":"worker","runner_backend":"inline","stale_after_seconds":300}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('demo', 'observation-run'));

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'observation-run'),
  geo_genius_test.import_executor_id('demo', 'observation-run'),
  'validating'
);

SELECT results_eq(
  $$SELECT manifest FROM geo_genius.import_run
     WHERE release_id = (SELECT id FROM geo_genius.release
                          WHERE release_key = 'observation-run')$$,
  $$SELECT manifest FROM observation_manifest$$,
  'an import attempt retains the exact manifest it claimed'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.release_artifacts
    WHERE release_id = (SELECT id FROM geo_genius.release
                         WHERE release_key = 'observation-run')),
  1,
  'release_artifacts exposes only explicitly selected artifact definitions'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.import_run
       WHERE release_id = (SELECT id FROM geo_genius.release
                            WHERE release_key = 'observation-run')),
      geo_genius_test.import_executor_id('demo', 'observation-run'),
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'observed.geojson'),
      repeat('b', 64), 9)$$,
  '23514',
  NULL,
  'record_artifact_observation refuses an observation that contradicts the expectation'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.import_run
       WHERE release_id = (SELECT id FROM geo_genius.release
                            WHERE release_key = 'observation-run')),
      geo_genius_test.import_executor_id('demo', 'observation-run'),
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'observed.geojson'),
      repeat('b', 64), 1024)$$,
  '23514',
  NULL,
  'record_artifact_observation refuses a digest that does not match, even with the right byte count'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.import_run
       WHERE release_id = (SELECT id FROM geo_genius.release
                            WHERE release_key = 'observation-run')),
      geo_genius_test.import_executor_id('demo', 'observation-run'),
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'observed.geojson'),
      repeat('a', 64), 9)$$,
  '23514',
  NULL,
  'record_artifact_observation refuses a byte count that does not match, even with the right digest'
);

SELECT geo_genius.record_artifact_observation(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release
                         WHERE release_key = 'observation-run')),
  geo_genius_test.import_executor_id('demo', 'observation-run'),
  (SELECT id FROM geo_genius.artifact WHERE logical_name = 'observed.geojson'),
  repeat('a', 64),
  1024
);

SELECT ok(
  (SELECT validated_at FROM geo_genius.import_run_artifact)
    IS NOT NULL,
  'record_artifact_observation stamps validated_at'
);

SELECT is(
  (SELECT validated_at FROM geo_genius.release_artifacts
    WHERE release_id = (SELECT id FROM geo_genius.release
                         WHERE release_key = 'observation-run')),
  NULL::timestamptz,
  'release_artifacts does not expose an observation from an incomplete run'
);

SELECT ok(
  (SELECT validated_at FROM geo_genius.run_artifacts
    WHERE run_id = (SELECT id FROM geo_genius.import_run
                     WHERE release_id = (SELECT id FROM geo_genius.release
                                          WHERE release_key = 'observation-run')))
    IS NOT NULL,
  'run_artifacts exposes the observation only to the attempt that recorded it'
);

SELECT lives_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.import_run
       WHERE release_id = (SELECT id FROM geo_genius.release
                            WHERE release_key = 'observation-run')),
      geo_genius_test.import_executor_id('demo', 'observation-run'),
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'observed.geojson'),
      repeat('A', 64), 1024)$$,
  'record_artifact_observation normalizes an uppercase digest instead of raising'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.import_run
       WHERE release_id = (SELECT id FROM geo_genius.release
                            WHERE release_key = 'observation-run')),
      geo_genius_test.import_executor_id('demo', 'observation-run'),
      '00000000-0000-0000-0000-000000000000'::uuid, repeat('a', 64), 1024)$$,
  '23503',
  NULL,
  'record_artifact_observation refuses an artifact that does not exist'
);

SELECT geo_genius.upsert_area(
  'demo', 'observation_auth', 'observation_area', 'completed-only'
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'observation-run'),
  geo_genius_test.import_executor_id('demo', 'observation-run'),
  'normalizing'
);

SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('demo', 'observation-run'),
  geo_genius_test.import_executor_id('demo', 'observation-run'),
  'observation_auth:observation_area:completed-only',
  NULL,
  '{}'::jsonb
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'observation-run'),
  geo_genius_test.import_executor_id('demo', 'observation-run'),
  'verifying'
);

SELECT geo_genius.complete_import(
  geo_genius_test.import_run_id('demo', 'observation-run'),
  geo_genius_test.import_executor_id('demo', 'observation-run'),
  '{}'::jsonb
);

SELECT ok(
  (SELECT validated_at FROM geo_genius.release_artifacts
    WHERE release_id = (SELECT id FROM geo_genius.release
                         WHERE release_key = 'observation-run'))
    IS NOT NULL,
  'release_artifacts exposes observations only from the latest completed run'
);

-- open_release

SELECT geo_genius.upsert_authority('demo', 'a', 'A');
SELECT geo_genius.upsert_area_type('demo', 't', 10);

SELECT throws_ok(
  $$SELECT geo_genius.open_release('no_such_collection', 'r1', '{}'::jsonb, NULL)$$,
  '23503',
  'collection no_such_collection does not exist',
  'open_release refuses a collection that does not exist'
);

SELECT ok(
  geo_genius.open_release(
    'demo', 'open_r1',
    '{"collection":"demo","collection_name":"Demo","release":"open_r1",
      "requires_geometry":false,
      "authorities":[{"key":"a","name":"A"}],
      "area_types":[{"key":"t","rank":10,"requires_geometry":false}]}'::jsonb,
    DATE '2026-01-15')
    IS NOT NULL,
  'open_release creates a release'
);

SELECT is(
  (SELECT count(*)::int FROM pg_class, LATERAL (
     SELECT replace(release.id::text, '-', '') AS suffix
       FROM geo_genius.release WHERE release.release_key = 'open_r1'
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
  geo_genius.open_release(
    'demo', 'open_r1',
    '{"collection":"demo","collection_name":"Demo","release":"open_r1",
      "requires_geometry":false,
      "authorities":[{"key":"a","name":"A"}],
      "area_types":[{"key":"t","rank":10,"requires_geometry":false}]}'::jsonb,
    DATE '2026-01-15'),
  (SELECT id FROM geo_genius.release WHERE release_key = 'open_r1'),
  'open_release reopens an unpublished release rather than duplicating it'
);

SELECT is(
  (SELECT manifest FROM geo_genius.release WHERE release_key = 'open_r1'),
  '{"collection":"demo","collection_name":"Demo","release":"open_r1",
    "requires_geometry":false,
    "authorities":[{"key":"a","name":"A"}],
    "area_types":[{"key":"t","rank":10,"requires_geometry":false}]}'::jsonb,
  'reopening an identical unpublished release retains its exact manifest'
);

SELECT * FROM geo_genius.prepare_import(
  '{"collection":"demo","collection_name":"Demo","release":"r1",
    "requires_geometry":false,
    "authorities":[{"key":"a","name":"A"}],
    "area_types":[{"key":"t","rank":10,"requires_geometry":false}]}'::jsonb,
  '{"owner":"pgtap-ingestion-writes","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('demo', 'r1'));

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'r1'),
  geo_genius_test.import_executor_id('demo', 'r1'),
  'normalizing'
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
  (SELECT count(*)::int FROM geo_genius.release_source
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')),
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

SELECT geo_genius.upsert_area('demo', 'a', 't', 'c');
SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('demo', 'r1'),
  geo_genius_test.import_executor_id('demo', 'r1'),
  'a:t:c', ST_GeogFromText('POINT(0 0)'), '{}'::jsonb);
SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('demo', 'r1'),
  geo_genius_test.import_executor_id('demo', 'r1'),
  'a:t:c', 'Area', 'official', NULL);

SELECT geo_genius.upsert_source_release('demo', 'demo:src', 'v2', NULL, '{}'::jsonb);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('demo', 'r1'),
  geo_genius_test.import_executor_id('demo', 'r1'),
  'publishing'
);
SELECT geo_genius.publish_import(
  geo_genius_test.import_run_id('demo', 'r1'),
  geo_genius_test.import_executor_id('demo', 'r1'));

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
