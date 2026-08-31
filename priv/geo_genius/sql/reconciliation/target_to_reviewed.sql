SELECT pg_advisory_xact_lock(
  hashtextextended('geo_genius:contract:' || $PREFIX_LITERAL$, 0)
);

--SPLIT--

DO $contract$
DECLARE
  installed_version integer;
  marker_schema_version integer;
  marker_revision text;
  marker_capabilities text[];
  marker_shape text[];
  marker_rows bigint;
  marker_relation_kind text;
  object_fingerprints text[];
  relation_metadata text[];
BEGIN
  SELECT substring(obj_description(c.oid) FROM 'version=([0-9]+)')::integer
    INTO installed_version
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = $PREFIX_LITERAL$
     AND c.relname = 'geo_genius_version'
     AND c.relkind = 'v';

  IF installed_version IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'GeoGenius v01 contract is unknown or drifted; reconciliation refused'
      USING ERRCODE = '55000';
  END IF;

  SELECT c.relkind::text INTO marker_relation_kind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = $PREFIX_LITERAL$
     AND c.relname = 'geo_genius_contract';

  IF marker_relation_kind IS DISTINCT FROM 'v' THEN
    RAISE EXCEPTION 'GeoGenius v01 contract is unknown or drifted; reconciliation refused'
      USING ERRCODE = '55000';
  END IF;

  SELECT array_agg(
           a.attname::text || ':' || format_type(a.atttypid, a.atttypmod)
           ORDER BY a.attnum)
    INTO marker_shape
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = $PREFIX_LITERAL$
     AND c.relname = 'geo_genius_contract'
     AND c.relkind = 'v'
     AND a.attnum > 0
     AND NOT a.attisdropped;

  IF marker_shape IS DISTINCT FROM ARRAY[
    'schema_version:integer',
    'contract_revision:text',
    'capabilities:text[]'
  ]::text[] THEN
    RAISE EXCEPTION 'GeoGenius v01 contract is unknown or drifted; reconciliation refused'
      USING ERRCODE = '55000';
  END IF;

  EXECUTE format(
    'SELECT count(*) FROM %I.geo_genius_contract',
    $PREFIX_LITERAL$
  ) INTO marker_rows;

  IF marker_rows <> 1 THEN
    RAISE EXCEPTION 'GeoGenius v01 contract is unknown or drifted; reconciliation refused'
      USING ERRCODE = '55000';
  END IF;

  EXECUTE format(
    'SELECT schema_version, contract_revision, capabilities FROM %I.geo_genius_contract',
    $PREFIX_LITERAL$
  ) INTO marker_schema_version, marker_revision, marker_capabilities;

  SELECT array_agg(
           objects.identity || '=' || objects.fingerprint
           ORDER BY objects.identity)
    INTO object_fingerprints
    FROM (
      SELECT
        p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')->' ||
          pg_get_function_result(p.oid) AS identity,
        md5(
          p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')->' ||
            pg_get_function_result(p.oid) ||
          '|arguments=' || pg_get_function_arguments(p.oid) ||
          '|language=' || l.lanname ||
          '|volatility=' || p.provolatile::text ||
          '|security_definer=' || p.prosecdef::text ||
          '|strict=' || p.proisstrict::text ||
          '|parallel=' || p.proparallel::text ||
          '|leakproof=' || p.proleakproof::text ||
          '|config=' || replace(
            coalesce(array_to_string(p.proconfig, E'\\x1f'), ''),
            format('%I', n.nspname),
            '$' || 'SCHEMA$') ||
          '|body=' || replace(p.prosrc, format('%I.', n.nspname), '$' || 'SCHEMA$.')
        ) AS fingerprint
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_language l ON l.oid = p.prolang
       WHERE n.nspname = $PREFIX_LITERAL$
         AND p.proname = ANY(ARRAY[
           'publish_release', 'put_boundaries', 'put_boundary',
           'upsert_area_type', 'verify_release'
       ])
    ) AS objects;

  SELECT array_agg(metadata.identity || '=' || metadata.fingerprint ORDER BY metadata.identity)
    INTO relation_metadata
    FROM (
      WITH relation AS (
        SELECT c.oid, c.relkind::text AS relkind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $PREFIX_LITERAL$
           AND c.relname = 'area_type'
      ),
      attribute AS (
        SELECT
          a.attname,
          format_type(a.atttypid, a.atttypmod) AS data_type,
          a.attnotnull,
          pg_get_expr(d.adbin, d.adrelid) AS column_default
        FROM relation r
        LEFT JOIN pg_attribute a
          ON a.attrelid = r.oid
         AND a.attname = 'requires_geometry'
         AND a.attnum > 0
         AND NOT a.attisdropped
        LEFT JOIN pg_attrdef d
          ON d.adrelid = r.oid
         AND d.adnum = a.attnum
        WHERE r.relkind = 'r'
      )
      SELECT
        identity,
        fingerprint
      FROM (
        SELECT
          'area_type' AS identity,
          CASE
            WHEN count(*) = 0 THEN 'absent'
            ELSE md5('area_type|relkind=' || max(relkind))
          END AS fingerprint
        FROM relation
        UNION ALL
        SELECT
          'area_type.requires_geometry' AS identity,
          CASE
            WHEN NOT EXISTS (SELECT 1 FROM relation WHERE relkind = 'r') THEN 'no_ordinary_table'
            WHEN count(attname) = 0 THEN 'absent'
            ELSE md5(
              'area_type.requires_geometry' ||
              '|type=' || max(data_type) ||
              '|not_null=' || bool_and(attnotnull)::text ||
              '|default=' || coalesce(max(column_default), '')
            )
          END AS fingerprint
        FROM attribute
      ) AS metadata
    ) AS metadata;

  IF marker_schema_version IS DISTINCT FROM 1
     OR marker_revision IS DISTINCT FROM $TARGET_REVISION$
     OR marker_capabilities IS DISTINCT FROM ARRAY[
       'boundary_batches',
       'boundary_canonical_repair_once',
       'boundary_collection_provenance',
       'boundary_publication_serialization',
       'reversible_legacy_v01_reconciliation',
       'type_scoped_geometry_requirements'
     ]::text[]
     OR object_fingerprints IS DISTINCT FROM ARRAY[
       'publish_release(target_release_id uuid)->uuid=1fbc7b4e627418afc2447f9be28b26c9',
       'put_boundaries(target_release_id uuid, target_area_keys text[], target_source_release_ids uuid[], input_geometries geometry[], display_tiers integer[], source_properties_values jsonb[])->void=729ab418df06c7b04fe7ff8278e308cb',
       'put_boundary(target_release_id uuid, target_area_key text, target_source_release_id uuid, input_geom geometry, simplify_tolerance double precision)->void=6c580e90b02cfbb5f983fe9bbb49c052',
       'upsert_area_type(collection_key text, key text, rank integer)->uuid=80f054a72417218c3fe5ecf7dc44a9d9',
       'upsert_area_type(collection_key text, key text, rank integer, requires_geometry boolean)->uuid=c600390eed3b8c5551084bcc7ef902a9',
       'verify_release(target_release_id uuid)->jsonb=31bc47c8b82ca9d802cc22f95325e6d4'
     ]::text[]
     OR relation_metadata IS DISTINCT FROM ARRAY[
       'area_type=958113835e7c799371edd8063ae7c206',
       'area_type.requires_geometry=ebc65b5bd8edf9693e6a23213d20bbb9'
     ]::text[] THEN
    RAISE EXCEPTION 'GeoGenius v01 contract is unknown or drifted; reconciliation refused'
      USING ERRCODE = '55000';
  END IF;
END;
$contract$;

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

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_area_type(text, text, integer, boolean);

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

ALTER TABLE $SCHEMA$.area_type
  DROP COLUMN IF EXISTS requires_geometry;

--SPLIT--

CREATE OR REPLACE VIEW $SCHEMA$.geo_genius_contract AS
SELECT
  1::integer AS schema_version,
  $REVIEWED_REVISION$::text AS contract_revision,
  ARRAY[
    'boundary_batches',
    'boundary_canonical_repair_once',
    'boundary_collection_provenance',
    'boundary_publication_serialization',
    'reversible_legacy_v01_reconciliation'
  ]::text[] AS capabilities;

--SPLIT--

DO $contract$
DECLARE
  marker_schema_version integer;
  marker_revision text;
  marker_capabilities text[];
  reviewed_fingerprints text[];
  relation_metadata text[];
BEGIN
  EXECUTE format(
    'SELECT schema_version, contract_revision, capabilities FROM %I.geo_genius_contract',
    $PREFIX_LITERAL$
  ) INTO marker_schema_version, marker_revision, marker_capabilities;

  SELECT array_agg(
           objects.identity || '=' || objects.fingerprint
           ORDER BY objects.identity)
    INTO reviewed_fingerprints
    FROM (
      SELECT
        p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')->' ||
          pg_get_function_result(p.oid) AS identity,
        md5(
          p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')->' ||
            pg_get_function_result(p.oid) ||
          '|arguments=' || pg_get_function_arguments(p.oid) ||
          '|language=' || l.lanname ||
          '|volatility=' || p.provolatile::text ||
          '|security_definer=' || p.prosecdef::text ||
          '|strict=' || p.proisstrict::text ||
          '|parallel=' || p.proparallel::text ||
          '|leakproof=' || p.proleakproof::text ||
          '|config=' || replace(
            coalesce(array_to_string(p.proconfig, E'\\x1f'), ''),
            format('%I', n.nspname),
            '$' || 'SCHEMA$') ||
          '|body=' || replace(p.prosrc, format('%I.', n.nspname), '$' || 'SCHEMA$.')
        ) AS fingerprint
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_language l ON l.oid = p.prolang
       WHERE n.nspname = $PREFIX_LITERAL$
         AND p.proname = ANY(ARRAY[
           'publish_release', 'put_boundaries', 'put_boundary',
           'upsert_area_type', 'verify_release'
         ])
    ) AS objects;

  SELECT array_agg(metadata.identity || '=' || metadata.fingerprint ORDER BY metadata.identity)
    INTO relation_metadata
    FROM (
      WITH relation AS (
        SELECT c.oid, c.relkind::text AS relkind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $PREFIX_LITERAL$
           AND c.relname = 'area_type'
      ),
      attribute AS (
        SELECT
          a.attname,
          format_type(a.atttypid, a.atttypmod) AS data_type,
          a.attnotnull,
          pg_get_expr(d.adbin, d.adrelid) AS column_default
        FROM relation r
        LEFT JOIN pg_attribute a
          ON a.attrelid = r.oid
         AND a.attname = 'requires_geometry'
         AND a.attnum > 0
         AND NOT a.attisdropped
        LEFT JOIN pg_attrdef d
          ON d.adrelid = r.oid
         AND d.adnum = a.attnum
        WHERE r.relkind = 'r'
      )
      SELECT
        identity,
        fingerprint
      FROM (
        SELECT
          'area_type' AS identity,
          CASE
            WHEN count(*) = 0 THEN 'absent'
            ELSE md5('area_type|relkind=' || max(relkind))
          END AS fingerprint
        FROM relation
        UNION ALL
        SELECT
          'area_type.requires_geometry' AS identity,
          CASE
            WHEN NOT EXISTS (SELECT 1 FROM relation WHERE relkind = 'r') THEN 'no_ordinary_table'
            WHEN count(attname) = 0 THEN 'absent'
            ELSE md5(
              'area_type.requires_geometry' ||
              '|type=' || max(data_type) ||
              '|not_null=' || bool_and(attnotnull)::text ||
              '|default=' || coalesce(max(column_default), '')
            )
          END AS fingerprint
        FROM attribute
      ) AS metadata
    ) AS metadata;

  IF marker_schema_version IS DISTINCT FROM 1
     OR marker_revision IS DISTINCT FROM $REVIEWED_REVISION$
     OR marker_capabilities IS DISTINCT FROM ARRAY[
       'boundary_batches',
       'boundary_canonical_repair_once',
       'boundary_collection_provenance',
       'boundary_publication_serialization',
       'reversible_legacy_v01_reconciliation'
     ]::text[]
     OR reviewed_fingerprints IS DISTINCT FROM ARRAY[
       'publish_release(target_release_id uuid)->uuid=1fbc7b4e627418afc2447f9be28b26c9',
       'put_boundaries(target_release_id uuid, target_area_keys text[], target_source_release_ids uuid[], input_geometries geometry[], display_tiers integer[], source_properties_values jsonb[])->void=729ab418df06c7b04fe7ff8278e308cb',
       'put_boundary(target_release_id uuid, target_area_key text, target_source_release_id uuid, input_geom geometry, simplify_tolerance double precision)->void=6c580e90b02cfbb5f983fe9bbb49c052',
       'upsert_area_type(collection_key text, key text, rank integer)->uuid=d8fd4afb9182614ee9aec5707ae4c774',
       'verify_release(target_release_id uuid)->jsonb=5a3e77d9be44a97d9fff105107fee614'
     ]::text[]
     OR relation_metadata IS DISTINCT FROM ARRAY[
       'area_type=958113835e7c799371edd8063ae7c206',
       'area_type.requires_geometry=absent'
     ]::text[] THEN
    RAISE EXCEPTION 'GeoGenius reviewed contract verification failed'
      USING ERRCODE = '55000';
  END IF;
END;
$contract$;
