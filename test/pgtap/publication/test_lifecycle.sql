BEGIN;

SELECT plan(10);

SELECT geo_genius.upsert_collection('demo', 'Demo', NULL);
SELECT geo_genius.upsert_authority('demo', 'demo_auth', 'Demo Authority');
SELECT geo_genius.upsert_area_type('demo', 'outer', 10);
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'A');

INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r1', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';

SELECT ok(
  NOT ((geo_genius.verify_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
  )) ->> 'ok')::boolean,
  'a release with no boundaries fails verification'
);

SELECT throws_ok(
  $$SELECT geo_genius.publish_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'))$$,
  '23514',
  NULL,
  'publishing an unverifiable release is refused'
);

-- Give r1 a boundary so it verifies.
SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'));

INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'demo:src', 'demo', 'test' FROM geo_genius.collection WHERE key = 'demo';
INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'demo:src';
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'r1';

SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:outer:A',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326),
  0.0
);

SELECT ok(
  ((geo_genius.verify_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
  )) ->> 'ok')::boolean,
  'a release with boundaries verifies'
);

SELECT ok(
  geo_genius.publish_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1')) IS NOT NULL,
  'r1 publishes'
);

SELECT is(
  (SELECT kind FROM geo_genius.publication_event ORDER BY occurred_at DESC LIMIT 1),
  'published',
  'publication emits an event'
);

-- Publish a second release and roll back to the first.
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r2', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';
SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'r2';
SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'),
  'demo_auth:outer:A',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((0 0, 2 0, 2 2, 0 2, 0 0))', 4326),
  0.0
);
SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

SELECT is(
  (SELECT r.release_key FROM geo_genius.publication p
     JOIN geo_genius.release r ON r.id = p.release_id),
  'r2',
  'r2 is now published'
);

SELECT geo_genius.rollback_publication('demo');

SELECT is(
  (SELECT r.release_key FROM geo_genius.publication p
     JOIN geo_genius.release r ON r.id = p.release_id),
  'r1',
  'rollback restores the previous release'
);

SELECT ok(
  (SELECT pe.sequence FROM geo_genius.publication_event pe
     JOIN geo_genius.release r ON r.id = pe.release_id
    WHERE r.release_key = 'r2' AND pe.kind = 'published')
  <
  (SELECT sequence FROM geo_genius.publication_event WHERE kind = 'rolled_back'),
  'publication_event.sequence increases monotonically from publish to rollback'
);

SELECT is(
  geo_genius.retire_releases('demo', 1),
  1,
  'retiring keeps the active release and drops the rest'
);

-- An unknown collection and a collection that has published nothing are the
-- same answer to a caller holding a timestamp: there is no release to pin.
SELECT is(
  geo_genius.release_at('no_such_collection', now()),
  NULL::uuid,
  'release_at returns NULL for a collection key the catalog does not carry'
);

SELECT finish();

ROLLBACK;
