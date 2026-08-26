BEGIN;

SELECT plan(11);

SELECT has_table('geo_genius', 'boundary', 'boundary table exists');
SELECT has_table('geo_genius', 'boundary_part', 'boundary_part table exists');
SELECT has_table('geo_genius', 'relation', 'relation table exists');
SELECT has_table('geo_genius', 'release_area', 'release_area table exists');

SELECT is(
  (SELECT relkind::text FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'geo_genius' AND c.relname = 'boundary'),
  'p',
  'boundary is partitioned'
);

SELECT has_index('geo_genius', 'boundary', 'boundary_geom_gist_idx', 'canonical geometry is GiST indexed');
SELECT has_index('geo_genius', 'boundary_part', 'boundary_part_geom_gist_idx', 'subdivided parts are GiST indexed');
SELECT has_index('geo_genius', 'release_area', 'release_area_area_idx',
  ARRAY['area_id', 'release_id'],
  'members are indexed from the area side, leading with area_id');

INSERT INTO geo_genius.collection (key, name) VALUES ('demo', 'Demo');
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'demo-2026', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';

SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'demo-2026')
);

-- Scoped to the partition this test just created, not to a count of every
-- boundary partition in the schema. This database is shared, so an absolute
-- count asserts against whatever releases happen to exist and false-fails for
-- reasons that have nothing to do with the subject. Naming the partition also
-- asserts more than a count did: that the one attached is the one derived from
-- this release's id.
SELECT is(
  (SELECT count(*)::int FROM pg_inherits i
     JOIN pg_class p ON p.oid = i.inhparent
     JOIN pg_class c ON c.oid = i.inhrelid
     JOIN pg_namespace n ON n.oid = p.relnamespace
    WHERE n.nspname = 'geo_genius'
      AND p.relname = 'boundary'
      AND c.relname = 'boundary_' || replace(
        (SELECT id::text FROM geo_genius.release WHERE release_key = 'demo-2026'), '-', '')),
  1,
  'creating partitions attaches this release''s own boundary partition'
);

SELECT throws_ok(
  $$SELECT geo_genius.create_release_partitions(NULL)$$,
  '22004',
  NULL,
  'partition creation requires a release id'
);

-- Without this, a release id that names nothing silently gets four partitions
-- of its own: real tables, attached to the real parents, for a release that
-- does not exist and never will. The NULL check above does not cover it, and
-- guides/sql_api.md documents the 23503 as part of this function's contract.
SELECT throws_ok(
  $$SELECT geo_genius.create_release_partitions('00000000-0000-0000-0000-000000000000'::uuid)$$,
  '23503',
  NULL,
  'partition creation refuses a release that does not exist'
);

SELECT finish();

ROLLBACK;
