BEGIN;

SELECT plan(12);

SELECT geo_genius_test.demo_fixture_build();

CREATE TEMP TABLE boundary_attempt AS
SELECT geo_genius_test.demo_run_id() AS run_id,
       geo_genius_test.demo_executor_id() AS executor_id;

SELECT lives_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      ARRAY['demo_auth:outer:A', 'demo_auth:inner:B', 'demo_auth:outer:A'],
      ARRAY[
        (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
        (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
        (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')
      ],
      ARRAY[
        ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326),
        ST_GeomFromText('POLYGON((0 0, 1 1, 1 0, 0 1, 0 0))', 4326),
        ST_GeomFromText('POLYGON((2 2, 3 2, 3 3, 2 3, 2 2))', 4326)
      ],
      ARRAY[0, 1, 2],
      ARRAY['{"ordinal": 1}'::jsonb, '{"ordinal": 2}'::jsonb, '{"ordinal": 3}'::jsonb]
    )$$,
  'put_boundaries writes a set and repairs an invalid polygon'
);

SELECT results_eq(
  $$SELECT display_tier, source_properties
      FROM geo_genius.boundary b
      JOIN geo_genius.area a ON a.id = b.area_id
     WHERE a.area_key = 'demo_auth:outer:A'$$,
  $$VALUES (2::smallint, '{"ordinal": 3}'::jsonb)$$,
  'a duplicate area keeps the last input position'
);

SELECT is(
  (SELECT ST_AsText(centroid::geometry)
     FROM geo_genius.release_area membership
     JOIN geo_genius.area a ON a.id = membership.area_id
    WHERE a.area_key = 'demo_auth:outer:A'),
  'POINT(2.5 2.5)',
  'the accepted last geometry recomputes the membership centroid'
);

SELECT ok(
  (SELECT repaired AND ST_IsValid(geom)
     FROM geo_genius.boundary b
     JOIN geo_genius.area a ON a.id = b.area_id
    WHERE a.area_key = 'demo_auth:inner:B'),
  'an invalid polygon is made valid and records that it was repaired'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      ARRAY['demo_auth:outer:A'],
      ARRAY[]::uuid[],
      ARRAY[ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326)],
      ARRAY[0], ARRAY['{}'::jsonb])$$,
  '22023',
  NULL,
  'put_boundaries rejects unequal parallel arrays before writing'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      ARRAY['demo_auth:outer:A'],
      ARRAY[(SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')],
      ARRAY[ST_GeomFromText('POINT(0 0)', 4326)],
      ARRAY[0], ARRAY['{}'::jsonb])$$,
  '22023',
  NULL,
  'put_boundaries rejects non-polygonal geometry'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      ARRAY['demo_auth:outer:A'],
      ARRAY[(SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')],
      ARRAY[ST_GeomFromText('POLYGON((199 5, 201 5, 201 6, 199 6, 199 5))', 4326)],
      ARRAY[0], ARRAY['{}'::jsonb])$$,
  '22023',
  NULL,
  'put_boundaries rejects geometry outside the SRID 4326 domain'
);

SELECT geo_genius.upsert_collection('other', 'Other', NULL);
SELECT geo_genius.upsert_authority('other', 'other_auth', 'Other Authority');
SELECT geo_genius.upsert_area_type('other', 'zone', 10);
SELECT geo_genius.upsert_area('other', 'other_auth', 'zone', 'X');
SELECT geo_genius.upsert_source('other', 'other:src', 'demo', 'test');
SELECT geo_genius.upsert_source_release('other', 'other:src', 'v9', NULL, '{}'::jsonb);

SELECT throws_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      ARRAY['other_auth:zone:X'],
      ARRAY[(SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')],
      ARRAY[ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326)],
      ARRAY[0], ARRAY['{}'::jsonb])$$,
  '23503',
  NULL,
  'put_boundaries refuses an area from another collection'
);

SELECT lives_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      ARRAY['demo_auth:outer:A', 'demo_auth:outer:A'],
      ARRAY[
        (SELECT sr.id FROM geo_genius.source_release sr
          JOIN geo_genius.source s ON s.id = sr.source_id
         WHERE s.source_key = 'other:src'),
        (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')
      ],
      ARRAY[
        ST_GeomFromText('POLYGON((4 4, 5 4, 5 5, 4 5, 4 4))', 4326),
        ST_GeomFromText('POLYGON((6 6, 7 6, 7 7, 6 7, 6 6))', 4326)
      ],
      ARRAY[0, 0], ARRAY['{}'::jsonb, '{}'::jsonb])$$,
  'validation applies to the last accepted row for a repeated area'
);

INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  (SELECT sr.id FROM geo_genius.source_release sr
    JOIN geo_genius.source s ON s.id = sr.source_id
   WHERE s.source_key = 'other:src');

SELECT throws_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      ARRAY['demo_auth:outer:A'],
      ARRAY[(SELECT sr.id FROM geo_genius.source_release sr
              JOIN geo_genius.source s ON s.id = sr.source_id
             WHERE s.source_key = 'other:src')],
      ARRAY[ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326)],
      ARRAY[0], ARRAY['{}'::jsonb])$$,
  '23503',
  NULL,
  'put_boundaries refuses a malformed cross-collection release-source association'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_boundary(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      'demo_auth:outer:A',
      (SELECT sr.id FROM geo_genius.source_release sr
        JOIN geo_genius.source s ON s.id = sr.source_id
       WHERE s.source_key = 'other:src'),
      ST_GeomFromText('POLYGON((8 8, 9 8, 9 9, 8 9, 8 8))', 4326),
      0.25)$$,
  '23503',
  NULL,
  'put_boundary refuses malformed cross-collection provenance on the singular path'
);

SELECT geo_genius_test.demo_publish();

SELECT throws_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM boundary_attempt),
      (SELECT executor_id FROM boundary_attempt),
      ARRAY['demo_auth:outer:A'],
      ARRAY[(SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')],
      ARRAY[ST_GeomFromText('POLYGON((0 0, 2 0, 2 2, 0 2, 0 0))', 4326)],
      ARRAY[0], ARRAY['{}'::jsonb])$$,
  '55000',
  NULL,
  'put_boundaries refuses a published release'
);

SELECT finish();

ROLLBACK;
