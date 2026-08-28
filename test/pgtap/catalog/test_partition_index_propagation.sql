BEGIN;

SELECT geo_genius_test.demo_fixture_build();

-- Two host-style indexes on release_area's partitioned parent, of the two
-- shapes guides/reading.md documents: a btree over one extracted attribute
-- key, for ranking, and a GIN over the whole document, for containment.
-- GeoGenius ships neither, because the keys inside data are vendor-defined
-- and no shipped function filters or orders by them.
CREATE INDEX host_population_idx
  ON geo_genius.release_area (((data->>'population')::numeric));

CREATE INDEX host_attributes_idx
  ON geo_genius.release_area USING gin (data jsonb_path_ops);

-- A release whose partitions the library creates after both indexes exist.
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r2', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';

SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

CREATE OR REPLACE FUNCTION geo_genius_test.partition_index_shapes(target_release_key text)
RETURNS text[]
LANGUAGE sql
STABLE
AS $fn$
  SELECT array_agg(shape ORDER BY shape)
  FROM (
    SELECT substring(pg_get_indexdef(i.oid) from 'USING .*$') AS shape
    FROM geo_genius.release
    JOIN pg_class partition
      ON partition.oid = to_regclass(
           'geo_genius.release_area_' || replace(release.id::text, '-', ''))
    JOIN pg_index x ON x.indrelid = partition.oid
    JOIN pg_class i ON i.oid = x.indexrelid
    WHERE release.release_key = target_release_key
  ) shapes;
$fn$;

SELECT plan(5);

-- PostgreSQL propagates an index on a partitioned parent to every partition
-- created under it afterwards, so a host indexes release_area once, on the
-- parent, and every future release's partition inherits it. Nothing in
-- create_release_partitions has to know the index exists -- but a partition
-- built as a standalone table rather than PARTITION OF would inherit nothing,
-- and no other test would notice.
SELECT is(
  geo_genius_test.partition_index_shapes('r2'),
  geo_genius_test.partition_index_shapes('r1'),
  'a partition created after a host index carries the same indexes as one created before it'
);

SELECT ok(
  geo_genius_test.partition_index_shapes('r2') @>
    ARRAY['USING btree ((((data ->> ''population''::text))::numeric))'],
  'the host''s btree expression index reaches a partition created afterwards'
);

SELECT ok(
  geo_genius_test.partition_index_shapes('r2') @>
    ARRAY['USING gin (data jsonb_path_ops)'],
  'the host''s GIN index reaches a partition created afterwards'
);

-- retire_releases drops a release's partitions, and an import can rebuild
-- them. The host index lives on the parent, so it survives the drop and is
-- rebuilt on the replacement partition.
SELECT geo_genius.drop_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));
SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

SELECT is(
  geo_genius_test.partition_index_shapes('r2'),
  geo_genius_test.partition_index_shapes('r1'),
  'dropping and recreating a release''s partitions rebuilds the host indexes'
);

-- Part of the library's contract rather than an accident: release_area.data
-- carries no shipped index. No installed function issues a containment, key
-- existence, or jsonpath predicate against it, and no installed function
-- orders by a value extracted from it, so an index here would be write cost
-- with no read to pay for it. A host that needs one adds its own, above.
SELECT is(
  (SELECT array_agg(shape ORDER BY shape)
     FROM (
       SELECT substring(pg_get_indexdef(i.oid) from 'USING .*$') AS shape
         FROM pg_index x
         JOIN pg_class i ON i.oid = x.indexrelid
        WHERE x.indrelid = 'geo_genius.release_area'::regclass
          AND i.relname NOT LIKE 'host\_%'
     ) shipped),
  ARRAY[
    'USING btree (area_id, release_id)',
    'USING btree (release_id, area_id)',
    'USING gist (centroid)'
  ],
  'GeoGenius ships no index on release_area.data'
);

SELECT finish();

ROLLBACK;
