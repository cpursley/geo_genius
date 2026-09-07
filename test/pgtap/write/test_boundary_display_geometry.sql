BEGIN;

SELECT plan(11);

SELECT geo_genius_test.demo_fixture_build();

CREATE TEMP TABLE display_attempt AS
SELECT geo_genius_test.demo_run_id() AS run_id,
       geo_genius_test.demo_executor_id() AS executor_id,
       (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1')
         AS source_release_id;

-- The fixture already attached a boundary to each demo area. Removing those
-- rows makes every assertion below read the geometry this file writes: an
-- insert that the display check constraint rejects leaves nothing behind
-- instead of leaving the fixture's own valid row to be read as a pass.
DELETE FROM geo_genius.boundary_part
 WHERE area_id IN (SELECT id FROM geo_genius.area
                    WHERE area_key IN ('demo_auth:outer:A', 'demo_auth:inner:B'));

DELETE FROM geo_genius.boundary
 WHERE area_id IN (SELECT id FROM geo_genius.area
                    WHERE area_key IN ('demo_auth:outer:A', 'demo_auth:inner:B'));

CREATE TEMP TABLE display_geometry_case AS
SELECT
  -- Zillow's 2018 Broadmoor (Seattle, RegionID 250149) neighborhood reduced
  -- to the five vertices that carry its pathology: the ring returns to
  -- -122.2896177 and steps 1e-7 of a degree north, so it touches itself.
  -- ST_MakeValid splits that into the real polygon plus a zero-width sliver,
  -- and the pair is valid. Quantizing to six decimals collapses the sliver's
  -- three distinct vertices onto one point, which leaves a ring with too few
  -- points and makes the quantized geometry invalid.
  ST_GeomFromText(
    'POLYGON((-122.2896171 47.6280851, -122.2896177 47.6279214,' ||
    ' -122.2896177 47.6279215, -122.2868289 47.6298175,' ||
    ' -122.2896171 47.6280851))',
    4326
  ) AS self_touching,
  -- That sliver on its own. It is a valid polygon, but every vertex it has
  -- quantizes to the same point, so repairing the quantized geometry yields
  -- no polygon at all and there is nothing left to store as a display shape.
  ST_GeomFromText(
    'POLYGON((-122.2896177 47.6279215, -122.28961769963256 47.627921500249805,' ||
    ' -122.2896177 47.6279214, -122.2896177 47.6279215))',
    4326
  ) AS collapsing;

SELECT ok(
  (SELECT ST_IsValid(ST_MakeValid(self_touching))
      AND NOT ST_IsValid(ST_QuantizeCoordinates(ST_MakeValid(self_touching), 6))
     FROM display_geometry_case),
  'the repaired canonical geometry is valid until it is quantized to six decimals'
);

SELECT ok(
  (SELECT ST_IsValid(collapsing)
      AND ST_IsEmpty(
            ST_CollectionExtract(
              ST_MakeValid(ST_QuantizeCoordinates(collapsing, 6)), 3))
     FROM display_geometry_case),
  'the collapsing case leaves no polygon behind once quantized'
);

SELECT lives_ok(
  $$SELECT geo_genius.put_boundaries(
      (SELECT run_id FROM display_attempt),
      (SELECT executor_id FROM display_attempt),
      ARRAY['demo_auth:outer:A'],
      ARRAY[(SELECT source_release_id FROM display_attempt)],
      ARRAY[(SELECT self_touching FROM display_geometry_case)],
      ARRAY[0],
      ARRAY['{}'::jsonb])$$,
  'put_boundaries accepts a polygon that quantizing would invalidate'
);

SELECT ok(
  (SELECT ST_IsValid(display_geom)
      AND NOT ST_IsEmpty(display_geom)
      AND GeometryType(display_geom) IN ('POLYGON', 'MULTIPOLYGON')
     FROM geo_genius.boundary b
     JOIN geo_genius.area a ON a.id = b.area_id
    WHERE a.area_key = 'demo_auth:outer:A'),
  'put_boundaries stores a valid nonempty polygonal display geometry'
);

SELECT ok(
  (SELECT ST_Equals(
            geom,
            (SELECT ST_MakeValid(self_touching) FROM display_geometry_case))
     FROM geo_genius.boundary b
     JOIN geo_genius.area a ON a.id = b.area_id
    WHERE a.area_key = 'demo_auth:outer:A'),
  'repairing the display geometry leaves the canonical geometry alone'
);

SELECT ok(
  (SELECT ST_Area(display_geom) > 0
      AND abs(ST_Area(display_geom) - ST_Area(geom)) < ST_Area(geom) / 1000
     FROM geo_genius.boundary b
     JOIN geo_genius.area a ON a.id = b.area_id
    WHERE a.area_key = 'demo_auth:outer:A'),
  'the repaired display geometry still covers the canonical geometry'
);

SELECT lives_ok(
  $$SELECT geo_genius.put_boundary(
      (SELECT run_id FROM display_attempt),
      (SELECT executor_id FROM display_attempt),
      'demo_auth:inner:B',
      (SELECT source_release_id FROM display_attempt),
      (SELECT collapsing FROM display_geometry_case),
      0.0)$$,
  'put_boundary accepts a polygon that quantizing would collapse'
);

SELECT ok(
  (SELECT ST_IsValid(display_geom) AND NOT ST_IsEmpty(display_geom)
     FROM geo_genius.boundary b
     JOIN geo_genius.area a ON a.id = b.area_id
    WHERE a.area_key = 'demo_auth:inner:B'),
  'put_boundary stores a valid nonempty display geometry for a collapsing polygon'
);

SELECT ok(
  (SELECT ST_OrderingEquals(display_geom, geom)
     FROM geo_genius.boundary b
     JOIN geo_genius.area a ON a.id = b.area_id
    WHERE a.area_key = 'demo_auth:inner:B'),
  'a display geometry with nothing left to repair falls back to the canonical geometry'
);

SELECT lives_ok(
  $$SELECT geo_genius.put_boundary(
      (SELECT run_id FROM display_attempt),
      (SELECT executor_id FROM display_attempt),
      'demo_auth:inner:B',
      (SELECT source_release_id FROM display_attempt),
      (SELECT self_touching FROM display_geometry_case),
      0.0000000001)$$,
  'the simplify branch repairs the quantized display geometry too'
);

SELECT ok(
  (SELECT ST_IsValid(display_geom)
      AND NOT ST_IsEmpty(display_geom)
      AND GeometryType(display_geom) IN ('POLYGON', 'MULTIPOLYGON')
     FROM geo_genius.boundary b
     JOIN geo_genius.area a ON a.id = b.area_id
    WHERE a.area_key = 'demo_auth:inner:B'),
  'the simplify branch stores a valid nonempty display geometry'
);

SELECT finish();

ROLLBACK;
