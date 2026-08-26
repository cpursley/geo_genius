-- The catalog's lifecycle invariants, each asserted against the operation
-- that would violate it. These are the rules no foreign key or CHECK can
-- express on its own: a published release is immutable, a release only holds
-- areas from its own collection, provenance is declared before it is cited,
-- retention reclaims data without erasing history, and a terminal import run
-- stays terminal.
BEGIN;

SELECT plan(26);

SELECT geo_genius_test.demo_fixture_build();

-- ---------------------------------------------------------------------------
-- Collection isolation
-- ---------------------------------------------------------------------------

SELECT geo_genius.upsert_collection('other', 'Other', NULL);
SELECT geo_genius.upsert_authority('other', 'other_auth', 'Other Authority');
SELECT geo_genius.upsert_area_type('other', 'zone', 10);
SELECT geo_genius.upsert_area('other', 'other_auth', 'zone', 'X');

SELECT throws_ok(
  $$SELECT geo_genius.put_area_in_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'other_auth:zone:X', NULL, '{}'::jsonb)$$,
  '23503',
  NULL,
  'put_area_in_release refuses an area from another collection'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_boundary(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'other_auth:zone:X',
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326), 0.0)$$,
  '23503',
  NULL,
  'put_boundary refuses an area from another collection'
);

-- verify_release re-checks membership rather than trusting the write API,
-- because the partitioned tables are reachable directly.
INSERT INTO geo_genius.release_area (release_id, area_id)
SELECT
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  (SELECT id FROM geo_genius.area WHERE area_key = 'other_auth:zone:X');

SELECT is(
  (SELECT (geo_genius.verify_release(
     (SELECT id FROM geo_genius.release WHERE release_key = 'r1')) ->> 'ok')::boolean),
  false,
  'verify_release fails a release holding an area from another collection'
);

DELETE FROM geo_genius.release_area
 WHERE area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'other_auth:zone:X');

-- ---------------------------------------------------------------------------
-- Provenance and geometry validity
-- ---------------------------------------------------------------------------

INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v9' FROM geo_genius.source WHERE source_key = 'demo:src';

SELECT throws_ok(
  $$SELECT geo_genius.put_boundary(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'demo_auth:outer:A',
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v9'),
      ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326), 0.0)$$,
  '23503',
  NULL,
  'put_boundary refuses a source release the release never declared'
);

-- SRID 4326 does not bound coordinates. A polygon at longitude 200 stores as
-- geometry but normalizes to about -160 under a geography cast, so
-- containment and distance would disagree about where the area is.
SELECT throws_ok(
  $$SELECT geo_genius.put_boundary(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'demo_auth:outer:A',
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      ST_GeomFromText('POLYGON((199 5, 201 5, 201 6, 199 6, 199 5))', 4326), 0.0)$$,
  '22023',
  NULL,
  'put_boundary refuses coordinates outside the SRID 4326 domain'
);

-- ---------------------------------------------------------------------------
-- Asserted relations survive a geometry rebuild
-- ---------------------------------------------------------------------------

SELECT geo_genius.upsert_area_type('demo', 'reference', 90);
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'reference', 'P');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'reference', 'Q');
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:reference:P', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:reference:Q', NULL, '{}'::jsonb);
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:reference:P', 'demo_auth:reference:Q', 'contains');

SELECT geo_genius.rebuild_relations(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'));

SELECT is(
  (SELECT count(*)::int FROM geo_genius.relation r
     JOIN geo_genius.area p ON p.id = r.parent_area_id
    WHERE p.area_key = 'demo_auth:reference:P'
      AND r.intersection_area_m2 IS NULL),
  1,
  'rebuild_relations leaves a source-asserted relation in place'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.relation r
     JOIN geo_genius.area p ON p.id = r.parent_area_id
    WHERE p.area_key = 'demo_auth:outer:A'
      AND r.intersection_area_m2 IS NOT NULL),
  1,
  'rebuild_relations still measures the geometry-derived relations'
);

SELECT throws_ok(
  $$INSERT INTO geo_genius.relation
      (release_id, parent_area_id, child_area_id, relation_type, intersection_area_m2)
    SELECT
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      (SELECT id FROM geo_genius.area WHERE area_key = 'demo_auth:reference:Q'),
      (SELECT id FROM geo_genius.area WHERE area_key = 'demo_auth:reference:P'),
      'contains', 1.0$$,
  '23514',
  NULL,
  'a relation cannot be half-measured'
);

-- ---------------------------------------------------------------------------
-- Repeated code types survive the area_match projection
-- ---------------------------------------------------------------------------

SELECT geo_genius.put_area_code('demo_auth:outer:A', 'postal', '30309');
SELECT geo_genius.put_area_code('demo_auth:outer:A', 'postal', '30310');

SELECT is(
  (SELECT codes -> 'postal'
     FROM geo_genius.areas_by_code('postal', '30309', NULL, NULL,
       (SELECT id FROM geo_genius.release WHERE release_key = 'r1'))),
  '["30309", "30310"]'::jsonb,
  'an area carrying two codes of one type reports both, including the one looked up'
);

-- ---------------------------------------------------------------------------
-- A published release is immutable
-- ---------------------------------------------------------------------------

SELECT geo_genius_test.demo_publish();

SELECT throws_ok(
  $$SELECT geo_genius.put_area_in_release(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'demo_auth:inner:B', NULL, '{}'::jsonb)$$,
  '55000',
  NULL,
  'put_area_in_release refuses a published release'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_boundary(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'demo_auth:outer:A',
      (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
      ST_GeomFromText('POLYGON((0 0, 2 0, 2 2, 0 2, 0 0))', 4326), 0.0)$$,
  '55000',
  NULL,
  'put_boundary refuses a published release'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_relation(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'demo_auth:reference:Q', 'demo_auth:reference:P', 'contains')$$,
  '55000',
  NULL,
  'put_relation refuses a published release'
);

SELECT throws_ok(
  $$SELECT geo_genius.rebuild_relations(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'))$$,
  '55000',
  NULL,
  'rebuild_relations refuses a published release'
);

-- ---------------------------------------------------------------------------
-- Publication pointer arithmetic
-- ---------------------------------------------------------------------------

SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'R');
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r2', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';
SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'),
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1');
SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'),
  'demo_auth:outer:R',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((40 40, 41 40, 41 41, 40 41, 40 40))', 4326), 0.0);
SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

-- Publishing what is already published is a no-op. Letting it fall through
-- would set previous_release_id to the current release, erasing the only
-- pointer rollback has back to the last known-good one.
SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

SELECT is(
  (SELECT r.release_key FROM geo_genius.publication p
     JOIN geo_genius.release r ON r.id = p.previous_release_id
    WHERE p.collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo')),
  'r1',
  're-publishing the current release preserves the rollback pointer'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.publication_event
    WHERE collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo')),
  2,
  're-publishing the current release appends no event'
);

SELECT geo_genius.rollback_publication('demo');

SELECT is(
  (SELECT r.release_key FROM geo_genius.publication p
     JOIN geo_genius.release r ON r.id = p.release_id
    WHERE p.collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo')),
  'r1',
  'rollback still reaches the last known-good release after a repeated publish'
);

-- ---------------------------------------------------------------------------
-- Retention reclaims data without erasing history
-- ---------------------------------------------------------------------------

SELECT is(
  geo_genius.retire_releases('demo', 1),
  1,
  'retire_releases retires the completed release that is no longer published'
);

SELECT ok(
  (SELECT retired_at IS NOT NULL FROM geo_genius.release WHERE release_key = 'r2'),
  'the retired release row survives, marked retired'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.publication_event
    WHERE collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo')),
  3,
  'retention leaves the publication event sequence intact'
);

SELECT is(
  geo_genius.retire_releases('demo', 1),
  0,
  'retire_releases does not retire the same release twice'
);

SELECT throws_ok(
  $$SELECT geo_genius.retire_releases('nope', 1)$$,
  '23503',
  NULL,
  'retire_releases refuses an unknown collection'
);

-- r2 was the rollback target. Retiring it emptied its partitions, so the
-- pointer to it is cleared and rollback fails loudly rather than swapping the
-- collection onto a release with no areas in it.
SELECT throws_ok(
  $$SELECT geo_genius.rollback_publication('demo')$$,
  '23514',
  NULL,
  'rollback refuses once retention has taken the release it would roll back to'
);

-- ---------------------------------------------------------------------------
-- Historical release resolution
-- ---------------------------------------------------------------------------

SELECT is(
  geo_genius.release_at('demo', now()),
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'release_at resolves the collection''s currently published release'
);

SELECT is(
  geo_genius.release_at('demo', now() - interval '1 day'),
  NULL,
  'release_at returns nothing for a moment before the collection published anything'
);

-- ---------------------------------------------------------------------------
-- Import runs stay terminal
-- ---------------------------------------------------------------------------

SELECT throws_ok(
  $$SELECT geo_genius.begin_or_resume_import(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'worker-1', 'test', interval '-1 minute')$$,
  '22023',
  NULL,
  'begin_or_resume_import refuses a negative staleness window'
);

SELECT geo_genius.advance_import(
  geo_genius.begin_or_resume_import(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
    'worker-1', 'test'),
  'completed',
  '{}'::jsonb);

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT id FROM geo_genius.import_run
        WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
        ORDER BY attempt DESC LIMIT 1),
      'pending',
      '{}'::jsonb)$$,
  '55000',
  NULL,
  'advance_import refuses to resurrect a completed run'
);

SELECT finish();

ROLLBACK;
