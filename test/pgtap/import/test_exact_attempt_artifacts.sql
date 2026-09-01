BEGIN;

SELECT plan(5);

SELECT geo_genius.upsert_collection('attempts', 'Attempts', NULL);
SELECT geo_genius.upsert_source('attempts', 'attempts:src', 'fixture', 'test');
SELECT geo_genius.upsert_source_release(
  'attempts', 'attempts:src', 'v1', NULL, '{}'::jsonb);

SELECT geo_genius.put_artifact(
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  'A', 'https://example.test/A', false, 'json', repeat('a', 64), 10,
  '{"members":[],"required":true}'::jsonb);
SELECT geo_genius.put_artifact(
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  'B', 'https://example.test/B', false, 'json', repeat('b', 64), 20,
  '{"members":[],"required":false}'::jsonb);
SELECT geo_genius.put_artifact(
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  'C', 'https://example.test/C', false, 'json', repeat('c', 64), 30,
  '{"members":[],"required":true}'::jsonb);

CREATE TEMP TABLE exact_attempt_manifest (
  scenario text PRIMARY KEY,
  manifest jsonb NOT NULL
);

CREATE TEMP TABLE exact_attempt_executor (
  scenario text PRIMARY KEY,
  executor_id uuid NOT NULL
);

INSERT INTO exact_attempt_manifest (scenario, manifest) VALUES
  ('selection', '{
    "collection":"attempts","collection_name":"Attempt Selection",
    "release":"selection-r1","requires_geometry":false,
    "authorities":[{"key":"fixture_auth","name":"Fixture Authority"}],
    "area_types":[{"key":"fixture_area","rank":10,"requires_geometry":false}],
    "sources":[{
      "source_key":"attempts:src","provider":"fixture","license":"test",
      "release_key":"v1","artifacts":[
        {"logical_name":"A","url":"https://example.test/A","format":"json",
         "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bytes":10},
        {"logical_name":"B","url":"https://example.test/B","format":"json","required":false,
         "sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","bytes":20}
      ]
    }]
  }'::jsonb),
  ('observation', '{
    "collection":"attempts","collection_name":"Attempt Observations",
    "release":"observation-r1","requires_geometry":false,
    "authorities":[{"key":"fixture_auth","name":"Fixture Authority"}],
    "area_types":[{"key":"fixture_area","rank":10,"requires_geometry":false}],
    "sources":[{
      "source_key":"attempts:src","provider":"fixture","license":"test",
      "release_key":"v1","artifacts":[
        {"logical_name":"B","url":"https://example.test/B","format":"json","required":false,
         "sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","bytes":20}
      ]
    }]
  }'::jsonb);

-- Attempt 1 selects A+B. Replacing the mutable release's selection with A+C
-- afterwards must not rewrite the exact input set that attempt 1 records.
SELECT * FROM geo_genius.prepare_import(
  (SELECT manifest FROM exact_attempt_manifest WHERE scenario = 'selection'),
  '{"owner":"worker-selection-1","runner_backend":"test","stale_after_seconds":300}'::jsonb);
INSERT INTO exact_attempt_executor (scenario, executor_id)
SELECT 'selection-1', geo_genius_test.claim_import_executor(id)
  FROM geo_genius.import_run
 WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'selection-r1');
SELECT geo_genius.fail_import(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'selection-r1')),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'selection-1'),
  '{"reason":"snapshot fixture"}'::jsonb
);

DELETE FROM geo_genius.release_artifact
 WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'selection-r1')
   AND artifact_id = (SELECT id FROM geo_genius.artifact WHERE logical_name = 'B');
SELECT geo_genius.attach_artifact(
  (SELECT id FROM geo_genius.release WHERE release_key = 'selection-r1'),
  (SELECT id FROM geo_genius.artifact WHERE logical_name = 'C'));

SELECT is(
  (SELECT array_agg(logical_name ORDER BY logical_name)
     FROM geo_genius.run_artifacts
    WHERE run_id = (
      SELECT id FROM geo_genius.import_run
       WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'selection-r1'))),
  ARRAY['A', 'B']::text[],
  'run_artifacts preserves attempt 1 exact A+B selection after the release changes to A+C'
);

-- Attempt 1 observes B. An identical active repeat is a no-op, while a
-- changed repeat is an immutable-history violation. After attempt 1 becomes
-- terminal, observations are closed. Attempt 2 then selects B but records no
-- observation; release_artifacts must reflect that latest completed attempt,
-- not reach backward to attempt 1's observation.
SELECT * FROM geo_genius.prepare_import(
  (SELECT manifest FROM exact_attempt_manifest WHERE scenario = 'observation'),
  '{"owner":"worker-observation-1","runner_backend":"test","stale_after_seconds":300}'::jsonb);
INSERT INTO exact_attempt_executor (scenario, executor_id)
SELECT 'observation-1', geo_genius_test.claim_import_executor(id)
  FROM geo_genius.import_run
 WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
   AND attempt = 1;
SELECT geo_genius_test.advance_import_to(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 1),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-1'),
  'validating');
SELECT geo_genius.record_artifact_observation(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 1),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-1'),
  (SELECT id FROM geo_genius.artifact WHERE logical_name = 'B'),
  repeat('b', 64), 20);

UPDATE geo_genius.import_run_artifact
   SET validated_at = '2000-01-01 00:00:00+00'::timestamptz
 WHERE run_id = (
   SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 1)
   AND artifact_id = (SELECT id FROM geo_genius.artifact WHERE logical_name = 'B');

SELECT geo_genius.record_artifact_observation(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 1),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-1'),
  (SELECT id FROM geo_genius.artifact WHERE logical_name = 'B'),
  repeat('b', 64), 20);

SELECT is(
  (SELECT validated_at FROM geo_genius.import_run_artifact
    WHERE run_id = (
      SELECT id FROM geo_genius.import_run
       WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
         AND attempt = 1)
      AND artifact_id = (SELECT id FROM geo_genius.artifact WHERE logical_name = 'B')),
  '2000-01-01 00:00:00+00'::timestamptz,
  'an identical active observation repeat preserves its original validation time'
);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.import_run
        WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
          AND attempt = 1),
      (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-1'),
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'B'),
      repeat('b', 64), 21)$$,
  '55000',
  NULL,
  'an active observation cannot be changed after it is recorded'
);

SELECT geo_genius.fail_import(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 1),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-1'),
  '{"reason":"retry fixture"}'::jsonb);

SELECT throws_ok(
  $$SELECT geo_genius.record_artifact_observation(
      (SELECT id FROM geo_genius.import_run
        WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
          AND attempt = 1),
      (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-1'),
      (SELECT id FROM geo_genius.artifact WHERE logical_name = 'B'),
      repeat('b', 64), 20)$$,
  '55000',
  NULL,
  'a terminal run rejects artifact observations'
);

SELECT * FROM geo_genius.retry_failed(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 1),
  (SELECT manifest FROM exact_attempt_manifest WHERE scenario = 'observation'),
  '{"owner":"worker-observation-2","runner_backend":"test","stale_after_seconds":300}'::jsonb);
INSERT INTO exact_attempt_executor (scenario, executor_id)
SELECT 'observation-2', geo_genius_test.claim_import_executor(id)
  FROM geo_genius.import_run
 WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
   AND attempt = 2;

SELECT geo_genius.upsert_area(
  'attempts', 'fixture_auth', 'fixture_area', 'completed-only'
);

SELECT geo_genius_test.advance_import_to(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 2),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-2'),
  'normalizing'
);

SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 2),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-2'),
  'fixture_auth:fixture_area:completed-only',
  NULL,
  '{}'::jsonb
);

SELECT geo_genius_test.advance_import_to(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 2),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-2'),
  'verifying'
);

SELECT geo_genius.complete_import(
  (SELECT id FROM geo_genius.import_run
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND attempt = 2),
  (SELECT executor_id FROM exact_attempt_executor WHERE scenario = 'observation-2'),
  '{}'::jsonb
);

SELECT is(
  (SELECT observed_sha256 FROM geo_genius.release_artifacts
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'observation-r1')
      AND logical_name = 'B'),
  NULL,
  'release_artifacts uses attempt 2 null observation instead of attempt 1 observed B'
);

SELECT finish();

ROLLBACK;
