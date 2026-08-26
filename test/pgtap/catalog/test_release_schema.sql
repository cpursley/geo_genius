BEGIN;

SELECT plan(14);

SELECT has_table('geo_genius', 'source', 'source table exists');
SELECT has_table('geo_genius', 'source_release', 'source_release table exists');
SELECT has_table('geo_genius', 'artifact', 'artifact table exists');
SELECT has_table('geo_genius', 'release', 'release table exists');
SELECT has_table('geo_genius', 'release_source', 'release_source table exists');
SELECT has_table('geo_genius', 'publication', 'publication table exists');
SELECT has_table('geo_genius', 'publication_event', 'publication_event table exists');

INSERT INTO geo_genius.collection (key, name) VALUES ('demo', 'Demo');

INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'demo-2026', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';

SELECT throws_ok(
  $$INSERT INTO geo_genius.publication (collection_id, release_id)
    SELECT c.id, r.id
    FROM geo_genius.collection c
    JOIN geo_genius.release r ON r.collection_id = c.id
    WHERE c.key = 'demo'$$,
  '23514',
  NULL,
  'a pending release cannot be published'
);

UPDATE geo_genius.release SET status = 'completed', completed_at = now()
WHERE release_key = 'demo-2026';

INSERT INTO geo_genius.publication (collection_id, release_id)
SELECT c.id, r.id
FROM geo_genius.collection c
JOIN geo_genius.release r ON r.collection_id = c.id
WHERE c.key = 'demo';

SELECT is(
  (SELECT count(*)::int FROM geo_genius.publication),
  1,
  'a completed release publishes'
);

SELECT throws_ok(
  $$UPDATE geo_genius.release SET status = 'failed' WHERE release_key = 'demo-2026'$$,
  '23514',
  NULL,
  'a published release cannot leave completed status'
);

SELECT throws_ok(
  $$INSERT INTO geo_genius.artifact
      (source_release_id, logical_name, url, format, expected_sha256, expected_bytes)
    VALUES (gen_random_uuid(), 'x', 'https://example.test/x.zip', 'zip', 'nothex', 1)$$,
  '23514',
  NULL,
  'artifact checksum must be 64 lowercase hex characters'
);

SELECT throws_ok(
  $$INSERT INTO geo_genius.release (collection_id, release_key, manifest, status)
    SELECT id, 'demo-bad', '{}'::jsonb, 'nonsense'
    FROM geo_genius.collection WHERE key = 'demo'$$,
  '23514',
  NULL,
  'release status is constrained to the declared phases'
);

INSERT INTO geo_genius.collection (key, name) VALUES ('demo2', 'Demo Two');

SELECT lives_ok(
  $$INSERT INTO geo_genius.release (collection_id, release_key, manifest)
    SELECT id, 'demo-2026', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo2'$$,
  'two different collections can each hold a release with the same release_key'
);

INSERT INTO geo_genius.release (collection_id, release_key, manifest, status, completed_at)
SELECT id, 'demo-2027', '{}'::jsonb, 'completed', now()
FROM geo_genius.collection WHERE key = 'demo';

UPDATE geo_genius.publication
SET previous_release_id = (
  SELECT r.id
  FROM geo_genius.release r
  JOIN geo_genius.collection c ON c.id = r.collection_id
  WHERE c.key = 'demo' AND r.release_key = 'demo-2027'
)
WHERE collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo');

DELETE FROM geo_genius.release
WHERE release_key = 'demo-2027'
  AND collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo');

SELECT is(
  (SELECT previous_release_id
     FROM geo_genius.publication
    WHERE collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo')),
  NULL::uuid,
  'deleting the previous release succeeds and nulls the publication pointer'
);

SELECT finish();

ROLLBACK;
