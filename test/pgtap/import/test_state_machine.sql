BEGIN;

SELECT plan(19);

SELECT has_table('geo_genius', 'import_run', 'import_run table exists');
SELECT has_table('geo_genius', 'import_run_lease', 'import_run_lease table exists');

SELECT geo_genius.upsert_collection('demo', 'Demo', NULL);
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r1', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';

SELECT ok(
  geo_genius.begin_or_resume_import(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
    'worker-1', 'task', interval '5 minutes'
  ) IS NOT NULL,
  'a fresh import claims a run'
);

-- Age the lease, but keep it inside the staleness window, so the resume below
-- takes the same-owner branch and has something to refresh.
UPDATE geo_genius.import_run_lease SET heartbeat_at = now() - interval '2 minutes';

SELECT is(
  geo_genius.begin_or_resume_import(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
    'worker-1', 'task', interval '5 minutes'
  ),
  (SELECT id FROM geo_genius.import_run LIMIT 1),
  'the same owner resumes its own run'
);

-- The third sibling of the property asserted for heartbeat_import and
-- advance_import below. A resume that hands back the run id without
-- refreshing its lease leaves the worker holding a claim that keeps ageing,
-- so the next caller can reclaim it as stale while it is still running.
SELECT ok(
  (SELECT heartbeat_at FROM geo_genius.import_run_lease) > now() - interval '1 minute',
  'resuming a run refreshes the lease it hands back'
);

SELECT throws_ok(
  $$SELECT geo_genius.begin_or_resume_import(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'worker-2', 'task', interval '5 minutes')$$,
  '55006',
  NULL,
  'a second owner cannot claim a live run'
);

-- Age the lease past the staleness window and reclaim it.
UPDATE geo_genius.import_run_lease SET heartbeat_at = now() - interval '1 hour';

SELECT ok(
  geo_genius.begin_or_resume_import(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
    'worker-2', 'task', interval '5 minutes'
  ) IS NOT NULL,
  'a stale run is reclaimed'
);

-- Reclaiming is not handing the same row to a new owner. guides/ingestion.md
-- promises the abandoned run is marked failed and a fresh attempt starts, and
-- a reclaim that returned the original id would satisfy the assertion above
-- while breaking both.
SELECT is(
  (SELECT status FROM geo_genius.import_run ORDER BY attempt LIMIT 1),
  'failed',
  'reclaiming marks the abandoned run failed'
);

SELECT is(
  (SELECT error ->> 'reason' FROM geo_genius.import_run ORDER BY attempt LIMIT 1),
  'lease expired',
  'the abandoned run records why it was reclaimed'
);

SELECT is(
  (SELECT array_agg(attempt ORDER BY attempt) FROM geo_genius.import_run),
  ARRAY[1, 2],
  'the reclaim starts a second attempt rather than reusing the first'
);

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
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
-- any long phase that emits nothing, and begin_or_resume_import would then
-- hand the release to a second worker.
UPDATE geo_genius.import_run_lease
   SET heartbeat_at = now() - interval '10 minutes'
 WHERE run_id = (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1);

SELECT geo_genius.advance_import(
  (SELECT id FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1),
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
      '00000000-0000-0000-0000-000000000000'::uuid, 'staging', '{}'::jsonb)$$,
  '23503',
  'import run 00000000-0000-0000-0000-000000000000 does not exist',
  'advance_import refuses a run that does not exist'
);

SELECT throws_ok(
  $$SELECT geo_genius.fail_import(
      '00000000-0000-0000-0000-000000000000'::uuid, '{"reason": "boom"}'::jsonb)$$,
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
      '{"stage": "loading"}'::jsonb)$$,
  '23503',
  'import run ' || (SELECT id::text FROM geo_genius.import_run ORDER BY attempt DESC LIMIT 1) ||
    ' has no active lease',
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

SELECT finish();

ROLLBACK;
