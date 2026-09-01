BEGIN;

SELECT plan(21);

SELECT has_table('geo_genius', 'import_run', 'import_run table exists');
SELECT has_table('geo_genius', 'import_run_lease', 'import_run_lease table exists');

CREATE TEMP TABLE state_machine_manifest (scenario text PRIMARY KEY, manifest jsonb NOT NULL);
INSERT INTO state_machine_manifest (scenario, manifest) VALUES
  ('r1', '{"collection":"demo","collection_name":"Demo","release":"r1",
           "requires_geometry":false,"authorities":[],"area_types":[],"sources":[]}'::jsonb),
  ('r2', '{"collection":"demo2","collection_name":"Demo Two","release":"r2",
           "requires_geometry":false,"authorities":[],"area_types":[],"sources":[]}'::jsonb);

SELECT is(
  (SELECT decision || '/' || reason FROM geo_genius.prepare_import(
    (SELECT manifest FROM state_machine_manifest WHERE scenario = 'r1'),
    '{"owner":"worker-1","runner_backend":"task","stale_after_seconds":300}'::jsonb)),
  'enqueue/registered',
  'a fresh import registers and claims a run'
);

-- Age the lease, but keep it inside the staleness window, so the resume below
-- takes the same-owner branch and has something to refresh.
UPDATE geo_genius.import_run_lease SET heartbeat_at = now() - interval '2 minutes';
CREATE TEMP TABLE lease_snapshot AS
SELECT heartbeat_at FROM geo_genius.import_run_lease;

SELECT is(
  (SELECT run_id FROM geo_genius.prepare_import(
    (SELECT manifest FROM state_machine_manifest WHERE scenario = 'r1'),
    '{"owner":"worker-1","runner_backend":"task","stale_after_seconds":300}'::jsonb)),
  (SELECT id FROM geo_genius.import_run LIMIT 1),
  'the same owner receives its existing run for enqueue recovery'
);

-- Same-owner preparation closes the post-commit enqueue gap without changing
-- durable claim state. Only an executing worker heartbeat renews the lease.
SELECT is(
  (SELECT heartbeat_at FROM geo_genius.import_run_lease),
  (SELECT heartbeat_at FROM lease_snapshot),
  'same-owner enqueue recovery leaves the lease unchanged'
);

SELECT is(
  (SELECT decision || '/' || reason FROM geo_genius.prepare_import(
    (SELECT manifest FROM state_machine_manifest WHERE scenario = 'r1'),
    '{"owner":"worker-2","runner_backend":"task","stale_after_seconds":300}'::jsonb)),
  'error/live_import',
  'a second owner receives a structured refusal for a live run'
);

-- Age the lease past the staleness window. Preparation diagnoses the stale
-- claim but never rewrites attempt history or silently transfers ownership.
UPDATE geo_genius.import_run_lease SET heartbeat_at = now() - interval '1 hour';

SELECT is(
  (SELECT decision || '/' || reason FROM geo_genius.prepare_import(
    (SELECT manifest FROM state_machine_manifest WHERE scenario = 'r1'),
    '{"owner":"worker-2","runner_backend":"task","stale_after_seconds":300}'::jsonb)),
  'error/stale_import',
  'a stale run is diagnosed without implicit reclamation'
);

SELECT is(
  (SELECT status FROM geo_genius.import_run ORDER BY attempt LIMIT 1),
  'pending',
  'a stale-import refusal leaves the abandoned run unchanged'
);

SELECT is(
  (SELECT error ->> 'reason' FROM geo_genius.import_run ORDER BY attempt LIMIT 1),
  NULL,
  'a stale-import refusal does not synthesize terminal history'
);

SELECT is(
  (SELECT array_agg(attempt ORDER BY attempt) FROM geo_genius.import_run),
  ARRAY[1],
  'a stale-import refusal creates no replacement attempt'
);

CREATE TEMP TABLE state_machine_attempt (
  scenario text PRIMARY KEY,
  run_id uuid NOT NULL,
  executor_id uuid NOT NULL
);
INSERT INTO state_machine_attempt (scenario, run_id, executor_id)
SELECT 'r1', run_id, geo_genius_test.claim_import_executor(run_id)
  FROM (SELECT id AS run_id FROM geo_genius.import_run
        ORDER BY attempt DESC LIMIT 1) AS prepared;

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
      (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
      'nonsense', '{}'::jsonb)$$,
  '22023',
  NULL,
  'advance_import rejects an unknown phase'
);

-- Age the reclaimed run's lease so we can prove heartbeat_import advances it.
UPDATE geo_genius.import_run_lease
   SET heartbeat_at = now() - interval '10 minutes'
 WHERE run_id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1);

SELECT geo_genius.heartbeat_import(
  (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
  (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
  '{"stage": "loading"}'::jsonb
);

SELECT ok(
  (SELECT heartbeat_at FROM geo_genius.import_run_lease
    WHERE run_id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1))
    > now() - interval '1 minute',
  'heartbeat_import advances import_run_lease.heartbeat_at'
);

-- Age the lease again and advance a phase rather than heartbeating. A run
-- whose liveness rested on emit-time heartbeats alone would go stale during
-- any long phase that emits nothing, and prepare_import would then diagnose
-- the claim as stale.
UPDATE geo_genius.import_run_lease
   SET heartbeat_at = now() - interval '10 minutes'
 WHERE run_id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1);

SELECT geo_genius.advance_import(
  (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
  (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
  'downloading',
  '{}'::jsonb
);

SELECT geo_genius.advance_import(
  (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
  (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
  'validating',
  '{}'::jsonb
);

SELECT geo_genius.advance_import(
  (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
  (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
  'staging',
  '{}'::jsonb
);

SELECT ok(
  (SELECT heartbeat_at FROM geo_genius.import_run_lease
    WHERE run_id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1))
    > now() - interval '1 minute',
  'advance_import renews the lease of the run it advances'
);

SELECT geo_genius.fail_import(
  (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
  (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
  '{"reason": "boom"}'::jsonb
);

SELECT ok(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1)) = 'failed'
  AND NOT EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1)
  ),
  'fail_import marks the run failed and removes its lease'
);

-- The three run-scoped contracts, each of which fails silently when its
-- check is removed: a phase advance that never happened, a failure that was
-- never recorded, and a lease the caller believes it renewed while holding
-- none.
SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      '00000000-0000-0000-0000-000000000000'::uuid,
      (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
      'staging', '{}'::jsonb)$$,
  '23503',
  'import run 00000000-0000-0000-0000-000000000000 does not exist',
  'advance_import refuses a run that does not exist'
);

SELECT throws_ok(
  $$SELECT geo_genius.fail_import(
      '00000000-0000-0000-0000-000000000000'::uuid,
      (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
      '{"reason": "boom"}'::jsonb)$$,
  '23503',
  'import run 00000000-0000-0000-0000-000000000000 does not exist',
  'fail_import refuses a run that does not exist'
);

-- A terminal run has had its lease deleted, so this is the real shape of the
-- contract rather than a synthetic id: heartbeating a run that is no longer
-- live must say so instead of quietly doing nothing.
SELECT throws_ok(
  $$SELECT geo_genius.heartbeat_import(
      (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
      (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
      '{"stage": "loading"}'::jsonb)$$,
  '55000',
  'executor ' ||
    (SELECT executor_id::text FROM state_machine_attempt WHERE scenario = 'r1') ||
    ' does not own import run ' ||
    (SELECT id::text FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
  'heartbeat_import refuses a run holding no active lease'
);

-- The same terminal run through the view hosts actually read. A lease-less
-- run left NULL progress and NULL heartbeat_at would read as a run that has
-- never reported anything rather than one that has finished.
SELECT is(
  (SELECT progress FROM geo_genius.import_run_status
    WHERE run_id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1)),
  '{}'::jsonb,
  'import_run_status reports an empty progress map for a run holding no lease'
);

SELECT is(
  (SELECT s.heartbeat_at FROM geo_genius.import_run_status s
    WHERE s.run_id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1)),
  (SELECT r.heartbeat_at FROM geo_genius.import_run r
    ORDER BY r.attempt DESC LIMIT 1),
  'import_run_status falls back to the run''s own heartbeat_at once the lease is gone'
);

-- fail_import mirrors advance_import's terminal guard. Without it a late
-- failure -- a runner reporting its own error, a cleanup that failed after the
-- pipeline already finished -- stamps 'failed' over a run that completed and
-- published, leaving the catalog's history contradicting the release it holds.
SELECT * FROM geo_genius.prepare_import(
  (SELECT manifest FROM state_machine_manifest WHERE scenario = 'r2'),
  '{"owner":"worker-2","runner_backend":"task","stale_after_seconds":300}'::jsonb
);

INSERT INTO state_machine_attempt (scenario, run_id, executor_id)
SELECT 'r2', run_id, geo_genius_test.claim_import_executor(run_id)
  FROM (SELECT id AS run_id FROM geo_genius.import_run
        WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r2')) AS prepared;

-- Build the already-completed fixture directly. Only publish_import may create
-- this terminal state through the public API; this row isolates fail_import's
-- guard from publication's independent verification requirements.
UPDATE geo_genius.import_run
   SET status = 'completed', completed_at = now()
 WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r2');

DELETE FROM geo_genius.import_run_lease
 WHERE run_id = (SELECT id FROM geo_genius.import_run
   WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

SELECT throws_ok(
  $$SELECT geo_genius.fail_import(
      (SELECT id FROM geo_genius.import_run
        WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r2')),
      (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r2'),
      '{"reason": "late"}'::jsonb)$$,
  '55000',
  'import run ' ||
    (SELECT id::text FROM geo_genius.import_run
      WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r2')) ||
    ' has completed and cannot be failed',
  'fail_import refuses a run that has completed'
);

-- Only completed is refused. A retry path that records a failure twice, or a
-- pipeline failing after a phase already did, must not raise on the second.
SELECT lives_ok(
  $$SELECT geo_genius.fail_import(
      (SELECT id FROM geo_genius.import_run
        WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
        ORDER BY attempt DESC LIMIT 1),
      (SELECT executor_id FROM state_machine_attempt WHERE scenario = 'r1'),
      '{"reason": "again"}'::jsonb)$$,
  'fail_import is idempotent on a run that already failed'
);

SELECT finish();

ROLLBACK;
