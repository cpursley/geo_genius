BEGIN;

-- Proves a collection with requires_geometry = false is fully usable with
-- zero boundary rows: membership in a release comes from release_area, not
-- from having a polygon. This file exercises published_areas,
-- published_boundaries, areas_for_point, areas_near, areas_by_code,
-- search_areas, children_of, ancestors_of, verify_release, and
-- publish_import, plus the release-aware name and code write functions.

SELECT plan(22);

SELECT geo_genius.upsert_collection('metadata_catalog', 'Metadata Catalog', NULL, false);
SELECT geo_genius.upsert_authority('metadata_catalog', 'demo_auth', 'Metadata Authority');
SELECT geo_genius.upsert_area_type('metadata_catalog', 'state', 10);
SELECT geo_genius.upsert_area_type('metadata_catalog', 'city', 20);
SELECT geo_genius.upsert_area('metadata_catalog', 'demo_auth', 'state', 'GA');
SELECT geo_genius.upsert_area('metadata_catalog', 'demo_auth', 'city', 'atlanta');

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"metadata_catalog",
    "release":"r1",
    "collection_name":"Metadata Catalog",
    "requires_geometry":false,
    "authorities":[{"key":"demo_auth","name":"Metadata Authority"}],
    "area_types":[
      {"key":"state","rank":10,"requires_geometry":false},
      {"key":"city","rank":20,"requires_geometry":false}
    ]
  }'::jsonb,
  '{"owner":"pgtap-metadata-only","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'));

SELECT is(
  (SELECT policy.requires_geometry
     FROM geo_genius.release_collection_policy policy
     JOIN geo_genius.release ON release.id = policy.release_id
    WHERE release.release_key = 'r1'),
  false,
  'the release records its collection-level geometry policy'
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'normalizing');

SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'demo_auth:state:GA',
  ST_GeogFromText('POINT(-83.5 32.9)'),
  '{}'::jsonb
);

SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'demo_auth:city:atlanta',
  ST_GeogFromText('POINT(-84.388 33.749)'),
  '{}'::jsonb
);

SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'demo_auth:state:GA', 'Georgia', 'official', NULL);
SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'demo_auth:city:atlanta', 'Atlanta', 'official', NULL);
SELECT geo_genius.put_area_code(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'demo_auth:city:atlanta', 'postal', '30301');

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'relating');
SELECT geo_genius.put_relation(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'demo_auth:state:GA',
  'demo_auth:city:atlanta',
  'contains'
);

SELECT is(
  (SELECT relation_type FROM geo_genius.relation
    WHERE parent_area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'demo_auth:state:GA')
      AND child_area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'demo_auth:city:atlanta')),
  'contains',
  'put_relation records an asserted relation'
);

SELECT ok(
  (SELECT intersection_area_m2 IS NULL AND parent_coverage IS NULL AND child_coverage IS NULL
     FROM geo_genius.relation
    WHERE parent_area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'demo_auth:state:GA')
      AND child_area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'demo_auth:city:atlanta')),
  'an asserted relation carries no fabricated measurement -- the measured columns are NULL, not invented numbers'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_relation(
      geo_genius_test.import_run_id('metadata_catalog', 'r1'),
      geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
      'demo_auth:state:GA',
      'demo_auth:state:GA',
      'contains'
    )$$,
  '23514',
  NULL,
  'put_relation refuses parent = child'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_relation(
      geo_genius_test.import_run_id('metadata_catalog', 'r1'),
      geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
      'demo_auth:state:GA',
      'demo_auth:city:atlanta',
      'nonsense'
    )$$,
  '22023',
  NULL,
  'put_relation rejects an unknown relation type'
);

-- An area of this collection that was never put in the release. `relation`
-- has foreign keys to `area` and `release` but none to `release_area`, so
-- without put_relation's own membership checks both writes below are accepted
-- and the only thing that notices is verify_release, a whole phase later.
SELECT geo_genius.upsert_area('metadata_catalog', 'demo_auth', 'city', 'macon');

SELECT throws_ok(
  $$SELECT geo_genius.put_relation(
      geo_genius_test.import_run_id('metadata_catalog', 'r1'),
      geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
      'demo_auth:city:macon',
      'demo_auth:city:atlanta',
      'contains'
    )$$,
  '23503',
  'area demo_auth:city:macon is not a member of release ' ||
    (SELECT id::text FROM geo_genius.release WHERE release_key = 'r1'),
  'put_relation refuses a parent that is not a member of the release'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_relation(
      geo_genius_test.import_run_id('metadata_catalog', 'r1'),
      geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
      'demo_auth:state:GA',
      'demo_auth:city:macon',
      'contains'
    )$$,
  '23503',
  'area demo_auth:city:macon is not a member of release ' ||
    (SELECT id::text FROM geo_genius.release WHERE release_key = 'r1'),
  'put_relation refuses a child that is not a member of the release'
);

-- verify_release / publish_import need a source release declared.
INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'metadata_catalog:src', 'metadata_catalog', 'test' FROM geo_genius.collection WHERE key = 'metadata_catalog';
INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'metadata_catalog:src';
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'r1';

SELECT ok(
  ((geo_genius.verify_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
  )) ->> 'ok')::boolean,
  'a metadata-only release with zero boundaries and an asserted relation still verifies'
);

SELECT is(
  ((geo_genius.verify_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
  )) ->> 'area_count')::int,
  2,
  'verify_release reports area_count from release_area membership'
);

SELECT is(
  ((geo_genius.verify_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
  )) ->> 'boundary_count')::int,
  0,
  'verify_release still reports boundary_count, here zero'
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'),
  'publishing');
SELECT geo_genius.publish_import(
  geo_genius_test.import_run_id('metadata_catalog', 'r1'),
  geo_genius_test.import_executor_id('metadata_catalog', 'r1'));

-- 1. published_areas returns both areas.
SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_areas WHERE collection_key = 'metadata_catalog'),
  2,
  'published_areas returns both metadata-only areas'
);

-- 2. published_boundaries returns nothing for them.
SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_boundaries WHERE collection_key = 'metadata_catalog'),
  0,
  'published_boundaries returns nothing -- neither area ever got a polygon'
);

-- 8. areas_for_point over the city's centroid returns nothing: no polygon
-- exists to contain the point, even though the area is published metadata.
SELECT is(
  (SELECT count(*)::int FROM geo_genius.areas_for_point(-84.388, 33.749, ARRAY['metadata_catalog'], NULL, NULL)),
  0,
  'areas_for_point finds nothing for a metadata-only area -- there is no polygon to test containment against'
);

-- 9. areas_near falls back to the release_area centroid when no boundary
-- exists: Atlanta has only a centroid, and a tight radius around it still
-- resolves it as a proximity match.
SELECT is(
  (SELECT area_key
     FROM geo_genius.areas_near(-84.388, 33.749, 1000, ARRAY['metadata_catalog'], NULL, 10, NULL)),
  'demo_auth:city:atlanta',
  'areas_near falls back to the centroid for a geometry-less area'
);

-- areas_by_code resolves the city by its postal code with no geometry
-- involved at all.
SELECT is(
  (SELECT area_key FROM geo_genius.areas_by_code('postal', '30301', ARRAY['metadata_catalog'], NULL)),
  'demo_auth:city:atlanta',
  'areas_by_code resolves a metadata-only area by its postal code'
);

-- search_areas finds the city by a name prefix, also with no geometry
-- involved.
SELECT is(
  (SELECT area_key FROM geo_genius.search_areas('Atl', ARRAY['metadata_catalog'], NULL, 5, NULL) LIMIT 1),
  'demo_auth:city:atlanta',
  'search_areas finds a metadata-only area by a name prefix'
);

-- children_of / ancestors_of walk the asserted 'contains' relation
-- directly -- no geometry, no boundary, no measured coverage anywhere in
-- this collection.
SELECT is(
  (SELECT area_key
     FROM geo_genius.children_of('demo_auth:state:GA', NULL, NULL, 1, NULL)),
  'demo_auth:city:atlanta',
  'children_of returns the city from the state via an asserted relation, no geometry involved'
);

SELECT is(
  (SELECT area_key
     FROM geo_genius.ancestors_of('demo_auth:city:atlanta', NULL, NULL, 1, NULL)),
  'demo_auth:state:GA',
  'ancestors_of returns the state from the city via the same asserted relation'
);

-- 10. a requires_geometry = true collection whose release has an area
-- lacking a boundary fails verify_release, and publish_import raises
-- 23514.
SELECT geo_genius.upsert_collection('parcels', 'Parcels', NULL, true);
SELECT geo_genius.upsert_authority('parcels', 'parcel_auth', 'Parcel Authority');
SELECT geo_genius.upsert_area_type('parcels', 'parcel', 10);
SELECT geo_genius.upsert_area('parcels', 'parcel_auth', 'parcel', 'P1');

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"parcels",
    "release":"p1",
    "collection_name":"Parcels",
    "requires_geometry":true,
    "authorities":[{"key":"parcel_auth","name":"Parcel Authority"}],
    "area_types":[{"key":"parcel","rank":10,"requires_geometry":false}]
  }'::jsonb,
  '{"owner":"pgtap-metadata-only","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('parcels', 'p1'));

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('parcels', 'p1'),
  geo_genius_test.import_executor_id('parcels', 'p1'),
  'normalizing');

SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('parcels', 'p1'),
  geo_genius_test.import_executor_id('parcels', 'p1'),
  'parcel_auth:parcel:P1',
  NULL,
  '{}'::jsonb
);

INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'parcels:src', 'parcels', 'test' FROM geo_genius.collection WHERE key = 'parcels';
INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'parcels:src';
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id
  FROM geo_genius.release r
  JOIN geo_genius.collection c ON c.id = r.collection_id
  JOIN geo_genius.source s ON s.collection_id = c.id
  JOIN geo_genius.source_release sr ON sr.source_id = s.id
 WHERE r.release_key = 'p1'
   AND s.source_key = 'parcels:src';

SELECT ok(
  NOT ((geo_genius.verify_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'p1')
  )) ->> 'ok')::boolean,
  'a requires_geometry collection with an ungeometried area fails verification'
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('parcels', 'p1'),
  geo_genius_test.import_executor_id('parcels', 'p1'),
  'publishing');

SELECT throws_ok(
  $$SELECT geo_genius.publish_import(
      geo_genius_test.import_run_id('parcels', 'p1'),
      geo_genius_test.import_executor_id('parcels', 'p1'))$$,
  '23514',
  NULL,
  'publishing an ungeometried release in a requires_geometry collection is refused'
);

-- 11. a metadata collection can require geometry only for selected area
-- types. The metadata record stays ungeometried while verification fails for
-- the required bounded zone only, then passes after its boundary is present.
SELECT geo_genius.upsert_collection('typed_catalog', 'Typed Catalog', NULL, false);
SELECT geo_genius.upsert_authority('typed_catalog', 'typed_auth', 'Typed Authority');
SELECT geo_genius.upsert_area_type('typed_catalog', 'bounded_zone', 10, true);
SELECT geo_genius.upsert_area_type('typed_catalog', 'metadata_record', 20, false);
SELECT geo_genius.upsert_area('typed_catalog', 'typed_auth', 'bounded_zone', 'BZ1');
SELECT geo_genius.upsert_area('typed_catalog', 'typed_auth', 'metadata_record', 'R1');

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"typed_catalog",
    "release":"typed1",
    "collection_name":"Typed Catalog",
    "requires_geometry":false,
    "authorities":[{"key":"typed_auth","name":"Typed Authority"}],
    "area_types":[
      {"key":"bounded_zone","rank":10,"requires_geometry":true},
      {"key":"metadata_record","rank":20,"requires_geometry":false}
    ]
  }'::jsonb,
  '{"owner":"pgtap-metadata-only","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('typed_catalog', 'typed1'));

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('typed_catalog', 'typed1'),
  geo_genius_test.import_executor_id('typed_catalog', 'typed1'),
  'normalizing');

SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('typed_catalog', 'typed1'),
  geo_genius_test.import_executor_id('typed_catalog', 'typed1'),
  'typed_auth:bounded_zone:BZ1',
  NULL,
  '{}'::jsonb
);
SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('typed_catalog', 'typed1'),
  geo_genius_test.import_executor_id('typed_catalog', 'typed1'),
  'typed_auth:metadata_record:R1',
  NULL,
  '{}'::jsonb
);

INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'typed_catalog:src', 'fixture', 'test'
  FROM geo_genius.collection WHERE key = 'typed_catalog';
INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'typed_catalog:src';
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id
  FROM geo_genius.release r
  JOIN geo_genius.source_release sr ON sr.release_key = 'v1'
  JOIN geo_genius.source s ON s.id = sr.source_id
 WHERE r.release_key = 'typed1'
   AND s.source_key = 'typed_catalog:src';

SELECT is(
  (geo_genius.verify_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'typed1')
  ) -> 'failures'),
  '["1 areas lack a boundary"]'::jsonb,
  'verify_release fails only the ungeometried required type'
);

SELECT geo_genius.put_boundary(
  geo_genius_test.import_run_id('typed_catalog', 'typed1'),
  geo_genius_test.import_executor_id('typed_catalog', 'typed1'),
  'typed_auth:bounded_zone:BZ1',
  (SELECT source_release_id
     FROM geo_genius.release_source
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'typed1')),
  ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326),
  0.0
);

SELECT ok(
  ((geo_genius.verify_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'typed1')
  )) ->> 'ok')::boolean,
  'verify_release ignores ungeometried non-required types'
);

SELECT finish();

ROLLBACK;
