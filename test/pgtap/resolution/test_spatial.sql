BEGIN;

SELECT plan(18);

SELECT geo_genius_test.demo_fixture();

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_for_point(0.25, 0.25, NULL, NULL, NULL)),
  2,
  'an interior point matches both nested areas'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_for_point(0.75, 0.75, NULL, NULL, NULL)),
  1,
  'a point outside the inner area matches only the outer area'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_for_point(0.0, 0.0, NULL, NULL, NULL)),
  2,
  'a point exactly on a shared boundary is included'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_point(0.25, 0.25, NULL, ARRAY['inner'], NULL)),
  1,
  'the types filter narrows results'
);

SELECT is(
  (SELECT match_method FROM geo_genius.areas_for_point(0.75, 0.75, NULL, NULL, NULL)),
  'containment',
  'point matches are stamped as containment'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_geometry(
       ST_GeomFromText('POLYGON((2 2, 3 2, 3 3, 2 3, 2 2))', 4326), NULL, NULL, NULL)),
  0,
  'a disjoint polygon overlaps nothing'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_geometry(
       ST_GeomFromText('POLYGON((1 0, 2 0, 2 1, 1 1, 1 0))', 4326), NULL, NULL, NULL)),
  0,
  'edge-only contact has zero intersection area and is excluded'
);

SELECT ok(
  (SELECT coverage_of_input
     FROM geo_genius.areas_for_geometry(
       ST_GeomFromText('POLYGON((0 0, 0.5 0, 0.5 0.5, 0 0.5, 0 0))', 4326),
       NULL, ARRAY['outer'], NULL)) > 99.9,
  'coverage_of_input is denominated by the input geometry'
);

UPDATE geo_genius.area SET retired_at = now() WHERE code = 'B';

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_for_point(0.25, 0.25, NULL, NULL, NULL)),
  1,
  'retired areas are excluded by default'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_point(0.25, 0.25, NULL, NULL, NULL, true)),
  2,
  'include_retired brings retired areas back'
);

-- Publish a second release (r2) in the same collection, relocating area A far
-- away from the original unit square. r1 becomes previous_release_id but its
-- boundaries and boundary_part rows are untouched -- retire_releases has not
-- run, so it is still queryable directly by id. This is the scenario the
-- bug missed: a non-null target_release_id must reach r1 even though r2 is
-- now the published release.
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r2', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';

SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id
  FROM geo_genius.release r, geo_genius.source_release sr
 WHERE r.release_key = 'r2' AND sr.release_key = 'v1';

SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'),
  'demo_auth:outer:A',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((10 10, 11 10, 11 11, 10 11, 10 10))', 4326),
  0.0
);

SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_point(0.25, 0.25, NULL, NULL,
       (SELECT id FROM geo_genius.release WHERE release_key = 'r1')))
  ,
  1,
  'pinning to r1 still finds its area even though r2 is now published'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_point(0.25, 0.25, NULL, NULL,
       (SELECT id FROM geo_genius.release WHERE release_key = 'r2'))),
  0,
  'pinning to r2 reflects r2''s relocated geometry, not r1''s'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_for_point(0.25, 0.25, NULL, NULL, NULL)),
  0,
  'a null target_release_id still resolves to the published release (now r2)'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_geometry(
       ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326), NULL, NULL,
       (SELECT id FROM geo_genius.release WHERE release_key = 'r1'))),
  1,
  'areas_for_geometry pinned to r1 still overlaps its area even though r2 is published'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_geometry(
       ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326), NULL, NULL,
       (SELECT id FROM geo_genius.release WHERE release_key = 'r2'))),
  0,
  'areas_for_geometry pinned to r2 reflects r2''s relocated geometry'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_geometry(
       ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326), NULL, NULL, NULL)),
  0,
  'areas_for_geometry with a null target_release_id also resolves to the published release'
);

-- A release in a collection that has never published anything at all: no row
-- in publication for this collection exists, so the null branch (EXISTS
-- against publication) can never match it -- only an explicit
-- target_release_id can reach it.
SELECT geo_genius.upsert_collection('demo3', 'Demo Three', NULL);
SELECT geo_genius.upsert_authority('demo3', 'demo3_auth', 'Demo Three Authority');
SELECT geo_genius.upsert_area_type('demo3', 'zone', 10);
SELECT geo_genius.upsert_area('demo3', 'demo3_auth', 'zone', 'Z');

INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r3', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo3';

SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r3'));

INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'demo3:src', 'demo3', 'test' FROM geo_genius.collection WHERE key = 'demo3';

INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v2' FROM geo_genius.source WHERE source_key = 'demo3:src';

-- put_boundary attributes geometry to a source release, so the release has to
-- declare that source before any boundary can cite it.
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT
  (SELECT id FROM geo_genius.release WHERE release_key = 'r3'),
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v2');

SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r3'),
  'demo3_auth:zone:Z',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v2'),
  ST_GeomFromText('POLYGON((5 5, 6 5, 6 6, 5 6, 5 5))', 4326),
  0.0
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_point(5.25, 5.25, NULL, NULL,
       (SELECT id FROM geo_genius.release WHERE release_key = 'r3'))),
  1,
  'a release in a never-published collection resolves when pinned explicitly'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.areas_for_geometry(
       ST_GeomFromText('POLYGON((5 5, 6 5, 6 6, 5 6, 5 5))', 4326), NULL, NULL,
       (SELECT id FROM geo_genius.release WHERE release_key = 'r3'))),
  1,
  'areas_for_geometry resolves a never-published collection''s release when pinned explicitly'
);

SELECT finish();

ROLLBACK;
