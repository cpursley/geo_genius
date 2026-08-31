DROP VIEW IF EXISTS $SCHEMA$.geo_genius_contract;

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_boundaries(uuid, text[], uuid[], geometry[], integer[], jsonb[]);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_area_type(text, text, integer, boolean);

--SPLIT--

CREATE OR REPLACE FUNCTION $SCHEMA$.upsert_area_type(
  collection_key text,
  key text,
  rank integer
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_collection_id uuid;
  result_id uuid;
BEGIN
  IF collection_key IS NULL OR key IS NULL OR rank IS NULL THEN
    RAISE EXCEPTION 'collection, key, and rank are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'collection % does not exist', collection_key USING ERRCODE = '23503';
  END IF;

  PERFORM pg_advisory_xact_lock(
    ('x' || substr(md5('$SCHEMA$.area_type:' || target_collection_id::text || ':' || key), 1, 16))::bit(64)::bigint
  );

  INSERT INTO $SCHEMA$.area_type (collection_id, key, rank)
  VALUES (target_collection_id, key, rank)
  ON CONFLICT ON CONSTRAINT area_type_collection_key_uq
  DO UPDATE SET rank = EXCLUDED.rank
  RETURNING id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE OR REPLACE FUNCTION $SCHEMA$.verify_release(target_release_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  failures text[] := ARRAY[]::text[];
  area_count bigint;
  boundary_count bigint;
  invalid_count bigint;
  orphan_relations bigint;
  missing_sources bigint;
  collection_requires_geometry boolean;
  ungeometried_count bigint;
  foreign_members bigint;
BEGIN
  IF target_release_id IS NULL THEN
    RAISE EXCEPTION 'release id is required' USING ERRCODE = '22004';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM $SCHEMA$.release WHERE id = target_release_id) THEN
    RAISE EXCEPTION 'release % does not exist', target_release_id USING ERRCODE = '23503';
  END IF;

  SELECT count(*) INTO area_count
    FROM $SCHEMA$.release_area WHERE release_id = target_release_id;

  IF area_count = 0 THEN
    failures := failures || 'release contains no areas'::text;
  END IF;

  SELECT count(*) INTO boundary_count
    FROM $SCHEMA$.boundary WHERE release_id = target_release_id;

  SELECT collection.requires_geometry INTO STRICT collection_requires_geometry
    FROM $SCHEMA$.release
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE release.id = target_release_id;

  IF collection_requires_geometry THEN
    SELECT count(*) INTO ungeometried_count
      FROM $SCHEMA$.release_area ra
     WHERE ra.release_id = target_release_id
       AND NOT EXISTS (
         SELECT 1 FROM $SCHEMA$.boundary b
          WHERE b.release_id = ra.release_id
            AND b.area_id = ra.area_id
            AND b.display_tier = 0
       );

    IF ungeometried_count > 0 THEN
      failures := failures || format('%s areas lack a boundary', ungeometried_count);
    END IF;
  END IF;

  SELECT count(*) INTO invalid_count
    FROM $SCHEMA$.boundary
   WHERE release_id = target_release_id AND NOT ST_IsValid(geom);

  IF invalid_count > 0 THEN
    failures := failures || format('%s boundaries have invalid geometry', invalid_count);
  END IF;

  SELECT count(*) INTO orphan_relations
    FROM $SCHEMA$.relation r
   WHERE r.release_id = target_release_id
     AND (
       NOT EXISTS (
         SELECT 1 FROM $SCHEMA$.release_area ra
          WHERE ra.release_id = r.release_id AND ra.area_id = r.parent_area_id
       )
       OR NOT EXISTS (
         SELECT 1 FROM $SCHEMA$.release_area ra
          WHERE ra.release_id = r.release_id AND ra.area_id = r.child_area_id
       )
     );

  IF orphan_relations > 0 THEN
    failures := failures || format('%s relations reference an area outside the release', orphan_relations);
  END IF;

  SELECT count(*) INTO foreign_members
    FROM $SCHEMA$.release_area ra
    JOIN $SCHEMA$.area a ON a.id = ra.area_id
    JOIN $SCHEMA$.release rel ON rel.id = ra.release_id
   WHERE ra.release_id = target_release_id
     AND a.collection_id <> rel.collection_id;

  IF foreign_members > 0 THEN
    failures := failures || format('%s areas belong to another collection', foreign_members);
  END IF;

  SELECT count(*) INTO missing_sources
    FROM $SCHEMA$.release rel
   WHERE rel.id = target_release_id
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.release_source rs WHERE rs.release_id = rel.id
     );

  IF missing_sources > 0 THEN
    failures := failures || 'release declares no source releases'::text;
  END IF;

  RETURN jsonb_build_object(
    'ok', cardinality(failures) = 0,
    'failures', to_jsonb(failures),
    'area_count', area_count,
    'boundary_count', boundary_count
  );
END;
$fn$;

--SPLIT--

ALTER TABLE $SCHEMA$.area_type DROP COLUMN IF EXISTS requires_geometry;

--SPLIT--

CREATE OR REPLACE FUNCTION $SCHEMA$.put_boundary(
  target_release_id uuid,
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
  target_area_id uuid;
  canonical geometry;
  was_repaired boolean := false;
  display geometry;
BEGIN
  IF target_release_id IS NULL OR target_area_key IS NULL
     OR target_source_release_id IS NULL OR input_geom IS NULL THEN
    RAISE EXCEPTION 'release, area key, source release, and geometry are required'
      USING ERRCODE = '22004';
  END IF;

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

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  SELECT id INTO STRICT target_area_id
    FROM $SCHEMA$.area WHERE area_key = target_area_key;

  PERFORM $SCHEMA$.assert_area_in_collection(target_release_id, target_area_id);

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

CREATE OR REPLACE FUNCTION $SCHEMA$.publish_release(target_release_id uuid)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  verification jsonb;
  target_collection_id uuid;
  previous uuid;
BEGIN
  verification := $SCHEMA$.verify_release(target_release_id);

  IF NOT (verification ->> 'ok')::boolean THEN
    RAISE EXCEPTION 'release % failed verification: %',
      target_release_id, verification ->> 'failures'
      USING ERRCODE = '23514';
  END IF;

  SELECT collection_id INTO STRICT target_collection_id
    FROM $SCHEMA$.release WHERE id = target_release_id;

  PERFORM pg_advisory_xact_lock($SCHEMA$.publication_lock_key(target_collection_id));

  UPDATE $SCHEMA$.release
     SET status = 'completed', completed_at = coalesce(completed_at, now())
   WHERE id = target_release_id;

  SELECT release_id INTO previous
    FROM $SCHEMA$.publication WHERE collection_id = target_collection_id;

  -- Publishing the release that is already published is a no-op, not a
  -- re-publication. Falling through would set previous_release_id to the
  -- current release, which erases the only pointer rollback_publication has
  -- back to the last known-good release.
  IF previous IS NOT NULL AND previous = target_release_id THEN
    RETURN target_collection_id;
  END IF;

  INSERT INTO $SCHEMA$.publication (collection_id, release_id, previous_release_id)
  VALUES (target_collection_id, target_release_id, previous)
  ON CONFLICT (collection_id)
  DO UPDATE SET
    previous_release_id = EXCLUDED.previous_release_id,
    release_id = EXCLUDED.release_id,
    published_at = now();

  INSERT INTO $SCHEMA$.publication_event
    (collection_id, release_id, previous_release_id, kind)
  VALUES (target_collection_id, target_release_id, previous, 'published');

  RETURN target_collection_id;
END;
$fn$;
