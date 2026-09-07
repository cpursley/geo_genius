-- Repairs the display geometry both boundary writes derive.
--
-- `boundary.display_geom` is `ST_QuantizeCoordinates(canonical, 6)`, and the
-- column carries the same `ST_IsValid` and `NOT ST_IsEmpty` checks the
-- canonical column does. Quantizing moves every coordinate by up to half a
-- unit in the sixth decimal place, so a valid canonical geometry can quantize
-- into an invalid one: a ring whose three distinct points differ only past
-- that place collapses onto a single point. Such an area failed the check
-- constraint mid-import and failed the whole run. Both writes now repair the
-- quantized geometry the way they already repair the canonical one, and keep
-- the canonical geometry when the repair leaves no polygon at all.

CREATE OR REPLACE VIEW $SCHEMA$.geo_genius_version AS SELECT 2 AS installed;

--SPLIT--

CREATE OR REPLACE VIEW $SCHEMA$.geo_genius_contract AS
SELECT
  2::integer AS schema_version,
  'sha256:5b8a85fb0b01123e7e9b1aef9eaf0206709a024254e3c6857819123c93a40567'::text
    AS contract_revision,
  ARRAY[
    'artifact_observation_publication_gate',
    'atomic_failed_candidate_retry',
    'atomic_import_completion',
    'atomic_import_publication',
    'boundary_batches',
    'boundary_canonical_repair_once',
    'boundary_collection_provenance',
    'boundary_display_repair',
    'boundary_publication_serialization',
    'exact_attempt_artifact_snapshots',
    'exact_attempt_manifest_snapshots',
    'executor_fenced_staging_cleanup',
    'failed_candidate_requires_explicit_retry',
    'idempotent_executor_reclaim',
    'immutable_failure_evidence',
    'publication_constraint_triggers',
    'release_retention_preserves_history',
    'release_scoped_catalog_declarations',
    'run_fenced_ingestion',
    'single_executor_import_claim',
    'strict_import_phase_transitions',
    'type_scoped_geometry_requirements'
  ]::text[] AS capabilities;

--SPLIT--

CREATE OR REPLACE FUNCTION $SCHEMA$.put_boundary(
  target_run_id uuid,
  target_executor_id uuid,
  target_area_key text,
  target_source_release_id uuid,
  input_geom geometry,
  simplify_tolerance double precision DEFAULT 0.0
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  target_collection_id uuid;
  target_collection_key text;
  target_area_id uuid;
  source_collection_id uuid;
  canonical geometry;
  was_repaired boolean := false;
  display geometry;
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL OR target_area_key IS NULL
     OR target_source_release_id IS NULL OR input_geom IS NULL THEN
    RAISE EXCEPTION 'run, area key, source release, and geometry are required'
      USING ERRCODE = '22004';
  END IF;

  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['normalizing']);

  IF ST_SRID(input_geom) <> 4326 THEN
    RAISE EXCEPTION 'geometry must use SRID 4326' USING ERRCODE = '22023';
  END IF;

  IF GeometryType(input_geom) NOT IN ('POLYGON', 'MULTIPOLYGON') THEN
    RAISE EXCEPTION 'geometry must be POLYGON or MULTIPOLYGON, got %',
      GeometryType(input_geom)
      USING ERRCODE = '22023';
  END IF;

  IF ST_IsEmpty(input_geom) THEN
    RAISE EXCEPTION 'geometry must not be empty' USING ERRCODE = '22023';
  END IF;

  -- SRID 4326 does not by itself bound the coordinates. A polygon sitting at
  -- longitude 200 stores happily as geometry but normalizes to roughly -160
  -- the moment it is cast to geography, so containment and distance would
  -- then disagree about where the area is.
  IF ST_XMin(input_geom) < -180 OR ST_XMax(input_geom) > 180
     OR ST_YMin(input_geom) < -90 OR ST_YMax(input_geom) > 90 THEN
    RAISE EXCEPTION
      'geometry coordinates are out of range for SRID 4326 (x %..%, y %..%)',
      ST_XMin(input_geom), ST_XMax(input_geom), ST_YMin(input_geom), ST_YMax(input_geom)
      USING ERRCODE = '22023';
  END IF;

  SELECT release.collection_id, collection.key
    INTO STRICT target_collection_id, target_collection_key
    FROM $SCHEMA$.release
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE release.id = target_release_id;

  PERFORM pg_advisory_xact_lock($SCHEMA$.publication_lock_key(target_collection_key));
  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  SELECT id INTO STRICT target_area_id
    FROM $SCHEMA$.area WHERE area_key = target_area_key;

  PERFORM $SCHEMA$.assert_area_in_collection(target_release_id, target_area_id);
  PERFORM $SCHEMA$.assert_area_declared(target_release_id, target_area_id);

  -- A boundary's provenance has to come from a source this release actually
  -- declares; an unrelated source release would attribute the geometry to
  -- data that was never part of the import.
  IF NOT EXISTS (
    SELECT 1 FROM $SCHEMA$.release_source
     WHERE release_id = target_release_id
       AND source_release_id = target_source_release_id
  ) THEN
    RAISE EXCEPTION
      'source release % is not declared by release %',
      target_source_release_id, target_release_id
      USING ERRCODE = '23503';
  END IF;

  SELECT source.collection_id INTO source_collection_id
    FROM $SCHEMA$.source_release
    JOIN $SCHEMA$.source ON source.id = source_release.source_id
   WHERE source_release.id = target_source_release_id;

  IF source_collection_id IS DISTINCT FROM target_collection_id THEN
    RAISE EXCEPTION
      'source release % belongs to another collection than release %',
      target_source_release_id, target_release_id
      USING ERRCODE = '23503';
  END IF;

  canonical := input_geom;

  IF NOT ST_IsValid(canonical) THEN
    canonical := ST_MakeValid(canonical);
    was_repaired := true;

    IF GeometryType(canonical) NOT IN ('POLYGON', 'MULTIPOLYGON') THEN
      canonical := ST_CollectionExtract(canonical, 3);
    END IF;
  END IF;

  display :=
    CASE
      WHEN simplify_tolerance > 0
      THEN ST_QuantizeCoordinates(
             ST_SimplifyPreserveTopology(canonical, simplify_tolerance), 6)
      ELSE ST_QuantizeCoordinates(canonical, 6)
    END;

  -- Quantizing moves every coordinate by up to half a unit in the sixth
  -- decimal place, so a display shape derived from an already-repaired
  -- canonical geometry can still self-intersect, or lose a ring that had
  -- three distinct points only past that place. The display column carries
  -- the same validity checks the canonical column does, so it is repaired
  -- the same way; a repair that leaves no polygon at all keeps the canonical
  -- geometry rather than storing nothing.
  IF NOT ST_IsValid(display) THEN
    display := ST_CollectionExtract(ST_MakeValid(display), 3);
  END IF;

  IF ST_IsEmpty(display) THEN
    display := canonical;
  END IF;

  -- A polygon-first caller never has to call put_area_in_release
  -- separately: attaching a boundary always ensures the area's membership
  -- in the release first.
  INSERT INTO $SCHEMA$.release_area (release_id, area_id, centroid)
  VALUES (
    target_release_id,
    target_area_id,
    ST_PointOnSurface(canonical)::geography
  )
  ON CONFLICT (release_id, area_id)
  DO UPDATE SET centroid = EXCLUDED.centroid;

  DELETE FROM $SCHEMA$.boundary
   WHERE release_id = target_release_id AND area_id = target_area_id;

  DELETE FROM $SCHEMA$.boundary_part
   WHERE release_id = target_release_id AND area_id = target_area_id;

  INSERT INTO $SCHEMA$.boundary
    (release_id, area_id, source_release_id, geom, display_geom, display_tier, repaired)
  VALUES
    (target_release_id, target_area_id, target_source_release_id,
     canonical, display, 0, was_repaired);

  INSERT INTO $SCHEMA$.boundary_part (release_id, area_id, geom)
  SELECT
    target_release_id,
    target_area_id,
    ST_Multi(part)
  FROM ST_Subdivide(canonical, 256) AS part;
END;
$fn$;

--SPLIT--

-- Attaches one accepted boundary per area key. Parallel arrays preserve the
-- source row's alignment and ordinality makes a repeated area last-write-wins.
CREATE OR REPLACE FUNCTION $SCHEMA$.put_boundaries(
  target_run_id uuid,
  target_executor_id uuid,
  target_area_keys text[],
  target_source_release_ids uuid[],
  input_geometries geometry[],
  display_tiers integer[],
  source_properties_values jsonb[]
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  batch_size integer;
  target_collection_id uuid;
  target_collection_key text;
  foreign_area_id uuid;
  undeclared_area_id uuid;
  undeclared_source_release_id uuid;
  foreign_source_release_id uuid;
  invalid_geometry geometry;
  invalid_display_tier integer;
  invalid_source_properties jsonb;
  accepted_area_ids uuid[];
  accepted_source_release_ids uuid[];
  accepted_geometries geometry[];
  accepted_display_geometries geometry[];
  accepted_display_tiers integer[];
  accepted_source_properties jsonb[];
  accepted_repaired boolean[];
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['normalizing']);

  batch_size := $SCHEMA$.assert_write_arrays(
    ARRAY[cardinality(target_area_keys), cardinality(target_source_release_ids),
          cardinality(input_geometries), cardinality(display_tiers),
          cardinality(source_properties_values)],
    ARRAY[array_position(target_area_keys, NULL),
          array_position(target_source_release_ids, NULL),
          array_position(input_geometries, NULL),
          array_position(display_tiers, NULL),
          array_position(source_properties_values, NULL)],
    ARRAY['area keys', 'source release ids', 'geometries', 'display tiers',
          'source properties']);

  IF batch_size = 0 THEN
    RETURN;
  END IF;

  -- Publication, rollback, retirement, and this write all serialize on the
  -- collection's existing lifecycle key. The mutability check is deliberately
  -- after the lock: a writer that waited for publication must see the release
  -- as completed and fail rather than committing after it became published.
  SELECT release.collection_id, collection.key
    INTO STRICT target_collection_id, target_collection_key
    FROM $SCHEMA$.release
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE release.id = target_release_id;

  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.publication_lock_key(target_collection_key));

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  PERFORM $SCHEMA$.assert_resolved(
    (SELECT min(requested.area_key)
       FROM unnest(target_area_keys) AS requested(area_key)
      WHERE NOT EXISTS (
        SELECT 1 FROM $SCHEMA$.area WHERE area.area_key = requested.area_key)),
    'area key');

  SELECT area.id INTO foreign_area_id
    FROM $SCHEMA$.area
   WHERE area.area_key = ANY(target_area_keys)
     AND area.collection_id <> target_collection_id
   ORDER BY area.area_key
   LIMIT 1;

  IF foreign_area_id IS NOT NULL THEN
    PERFORM $SCHEMA$.assert_area_in_collection(target_release_id, foreign_area_id);
  END IF;

  SELECT area.id INTO undeclared_area_id
    FROM $SCHEMA$.area
   WHERE area.area_key = ANY(target_area_keys)
     AND (
       NOT EXISTS (
         SELECT 1 FROM $SCHEMA$.release_authority
          WHERE release_authority.release_id = target_release_id
            AND release_authority.authority_id = area.authority_id)
       OR NOT EXISTS (
         SELECT 1 FROM $SCHEMA$.release_area_type
          WHERE release_area_type.release_id = target_release_id
            AND release_area_type.area_type_id = area.area_type_id)
     )
   ORDER BY area.area_key
   LIMIT 1;

  IF undeclared_area_id IS NOT NULL THEN
    PERFORM $SCHEMA$.assert_area_declared(target_release_id, undeclared_area_id);
  END IF;

  -- Resolve and deduplicate once. Every later array is ordered by area id, so
  -- parallel positions stay aligned and the first row write acquires shared
  -- release_area locks in one deterministic order.
  WITH requested AS (
    SELECT DISTINCT ON (t.area_key)
           area.id AS area_id, t.source_release_id, t.input_geom,
           t.display_tier, t.source_properties
      FROM unnest(target_area_keys, target_source_release_ids, input_geometries,
                  display_tiers, source_properties_values) WITH ORDINALITY
             AS t(area_key, source_release_id, input_geom, display_tier,
                  source_properties, ord)
      JOIN $SCHEMA$.area ON area.area_key = t.area_key
     ORDER BY t.area_key, t.ord DESC
  )
  SELECT array_agg(area_id ORDER BY area_id),
         array_agg(source_release_id ORDER BY area_id),
         array_agg(input_geom ORDER BY area_id),
         array_agg(display_tier ORDER BY area_id),
         array_agg(source_properties ORDER BY area_id)
    INTO accepted_area_ids, accepted_source_release_ids, accepted_geometries,
         accepted_display_tiers, accepted_source_properties
    FROM requested;

  SELECT requested.source_release_id INTO undeclared_source_release_id
    FROM unnest(accepted_source_release_ids) AS requested(source_release_id)
   WHERE NOT EXISTS (
     SELECT 1 FROM $SCHEMA$.release_source
      WHERE release_source.release_id = target_release_id
        AND release_source.source_release_id = requested.source_release_id)
   ORDER BY requested.source_release_id
   LIMIT 1;

  IF undeclared_source_release_id IS NOT NULL THEN
    RAISE EXCEPTION
      'source release % is not declared by release %',
      undeclared_source_release_id, target_release_id
      USING ERRCODE = '23503';
  END IF;

  -- release_source is directly writable, so membership alone cannot prove
  -- provenance belongs to the release's collection. Recheck the source chain
  -- independently before accepting geometry attributed to it.
  SELECT source_release.id INTO foreign_source_release_id
    FROM unnest(accepted_source_release_ids) AS requested(source_release_id)
    JOIN $SCHEMA$.source_release ON source_release.id = requested.source_release_id
    JOIN $SCHEMA$.source ON source.id = source_release.source_id
   WHERE source.collection_id <> target_collection_id
   ORDER BY source_release.id
   LIMIT 1;

  IF foreign_source_release_id IS NOT NULL THEN
    RAISE EXCEPTION
      'source release % belongs to another collection than release %',
      foreign_source_release_id, target_release_id
      USING ERRCODE = '23503';
  END IF;

  SELECT display_tier INTO invalid_display_tier
    FROM unnest(accepted_display_tiers) AS requested(display_tier)
   WHERE display_tier NOT BETWEEN 0 AND 20
   LIMIT 1;

  IF invalid_display_tier IS NOT NULL THEN
    RAISE EXCEPTION 'display tier % must be between 0 and 20', invalid_display_tier
      USING ERRCODE = '22023';
  END IF;

  SELECT source_properties INTO invalid_source_properties
    FROM unnest(accepted_source_properties) AS requested(source_properties)
   WHERE jsonb_typeof(source_properties) <> 'object'
   LIMIT 1;

  IF invalid_source_properties IS NOT NULL THEN
    RAISE EXCEPTION 'source properties must be a JSON object' USING ERRCODE = '22023';
  END IF;

  SELECT input_geom INTO invalid_geometry
    FROM unnest(accepted_geometries) AS requested(input_geom)
   WHERE ST_SRID(input_geom) <> 4326
      OR GeometryType(input_geom) NOT IN ('POLYGON', 'MULTIPOLYGON')
      OR ST_IsEmpty(input_geom)
      OR ST_XMin(input_geom) < -180 OR ST_XMax(input_geom) > 180
      OR ST_YMin(input_geom) < -90 OR ST_YMax(input_geom) > 90
   LIMIT 1;

  IF invalid_geometry IS NOT NULL THEN
    IF ST_SRID(invalid_geometry) <> 4326 THEN
      RAISE EXCEPTION 'geometry must use SRID 4326' USING ERRCODE = '22023';
    ELSIF GeometryType(invalid_geometry) NOT IN ('POLYGON', 'MULTIPOLYGON') THEN
      RAISE EXCEPTION 'geometry must be POLYGON or MULTIPOLYGON, got %',
        GeometryType(invalid_geometry) USING ERRCODE = '22023';
    ELSIF ST_IsEmpty(invalid_geometry) THEN
      RAISE EXCEPTION 'geometry must not be empty' USING ERRCODE = '22023';
    ELSE
      RAISE EXCEPTION
        'geometry coordinates are out of range for SRID 4326 (x %..%, y %..%)',
        ST_XMin(invalid_geometry), ST_XMax(invalid_geometry),
        ST_YMin(invalid_geometry), ST_YMax(invalid_geometry)
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Materialize validity and repair once. ST_MakeValid is the expensive part
  -- for national polygons; every subsequent write unnests the accepted
  -- canonical array instead of recomputing it for membership, boundary, and
  -- subdivision independently.
  WITH requested AS MATERIALIZED (
    SELECT t.ord, t.input_geom, ST_IsValid(t.input_geom) AS valid
      FROM unnest(accepted_geometries) WITH ORDINALITY AS t(input_geom, ord)
  ),
  made AS MATERIALIZED (
    SELECT ord, NOT valid AS repaired,
           CASE WHEN valid THEN input_geom ELSE ST_MakeValid(input_geom) END AS geom
      FROM requested
  ),
  canonical AS (
    SELECT ord, repaired,
           CASE
             WHEN GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON') THEN geom
             ELSE ST_CollectionExtract(geom, 3)
           END AS geom
      FROM made
  )
  SELECT array_agg(geom ORDER BY ord), array_agg(repaired ORDER BY ord)
    INTO accepted_geometries, accepted_repaired
    FROM canonical;

  SELECT geom INTO invalid_geometry
    FROM unnest(accepted_geometries) AS requested(geom)
   WHERE GeometryType(geom) NOT IN ('POLYGON', 'MULTIPOLYGON')
      OR ST_IsEmpty(geom)
      OR NOT ST_IsValid(geom)
   LIMIT 1;

  IF invalid_geometry IS NOT NULL THEN
    RAISE EXCEPTION 'geometry could not be repaired into a valid nonempty polygon'
      USING ERRCODE = '22023';
  END IF;

  -- Quantizing moves every coordinate by up to half a unit in the sixth
  -- decimal place, so a display shape derived from an already-repaired
  -- canonical geometry can still self-intersect, or lose a ring that had
  -- three distinct points only past that place. The display column carries
  -- the same validity checks the canonical column does, so it is repaired
  -- the same way; a repair that leaves no polygon at all keeps the canonical
  -- geometry rather than storing nothing.
  WITH quantized AS MATERIALIZED (
    SELECT ord, geom, ST_QuantizeCoordinates(geom, 6) AS display_geom
      FROM unnest(accepted_geometries) WITH ORDINALITY AS t(geom, ord)
  ),
  repaired_display AS (
    SELECT ord, geom,
           CASE
             WHEN ST_IsValid(display_geom) THEN display_geom
             ELSE ST_CollectionExtract(ST_MakeValid(display_geom), 3)
           END AS display_geom
      FROM quantized
  )
  SELECT array_agg(
           CASE WHEN ST_IsEmpty(display_geom) THEN geom ELSE display_geom END
           ORDER BY ord)
    INTO accepted_display_geometries
    FROM repaired_display;

  -- This is the first row write. The singular SQL path also begins with the
  -- membership upsert, so plural/plural and plural/singular overlap queue on
  -- release_area before either path can lock boundary or boundary_part. The
  -- area-id order prevents two plural batches from walking shared rows in
  -- opposite directions.
  INSERT INTO $SCHEMA$.release_area (release_id, area_id, centroid)
  SELECT target_release_id, requested.area_id,
         ST_PointOnSurface(requested.geom)::geography
    FROM unnest(accepted_area_ids, accepted_geometries)
           AS requested(area_id, geom)
   ORDER BY requested.area_id
  ON CONFLICT (release_id, area_id)
  DO UPDATE SET centroid = EXCLUDED.centroid;

  -- Match the singular write's relation order after membership: boundary
  -- first, subdivision parts second.
  DELETE FROM $SCHEMA$.boundary target
   USING unnest(accepted_area_ids, accepted_display_tiers)
           AS requested(area_id, display_tier)
   WHERE target.release_id = target_release_id
     AND target.area_id = requested.area_id
     AND target.display_tier <> requested.display_tier;

  DELETE FROM $SCHEMA$.boundary_part target
   USING unnest(accepted_area_ids) AS requested(area_id)
   WHERE target.release_id = target_release_id
     AND target.area_id = requested.area_id;

  INSERT INTO $SCHEMA$.boundary AS target
    (release_id, area_id, source_release_id, geom, display_geom,
     display_tier, repaired, source_properties)
  SELECT target_release_id, requested.area_id, requested.source_release_id,
         requested.geom, requested.display_geom,
         requested.display_tier, requested.repaired, requested.source_properties
    FROM unnest(accepted_area_ids, accepted_source_release_ids,
                accepted_geometries, accepted_display_geometries,
                accepted_display_tiers, accepted_repaired,
                accepted_source_properties)
           AS requested(area_id, source_release_id, geom, display_geom,
                        display_tier, repaired, source_properties)
   ORDER BY requested.area_id
  ON CONFLICT (release_id, area_id, display_tier)
  DO UPDATE SET
    source_release_id = EXCLUDED.source_release_id,
    geom = EXCLUDED.geom,
    display_geom = EXCLUDED.display_geom,
    repaired = EXCLUDED.repaired,
    source_properties = EXCLUDED.source_properties;

  INSERT INTO $SCHEMA$.boundary_part (release_id, area_id, geom)
  SELECT target_release_id, requested.area_id, ST_Multi(part)
    FROM unnest(accepted_area_ids, accepted_geometries)
           AS requested(area_id, geom)
    CROSS JOIN LATERAL ST_Subdivide(requested.geom, 256) AS part
   ORDER BY requested.area_id;
END;
$fn$;
