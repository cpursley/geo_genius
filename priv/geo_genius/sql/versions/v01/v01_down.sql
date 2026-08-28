-- The resolve cascade

DROP FUNCTION IF EXISTS $SCHEMA$.resolve(
  jsonb, text[], text[], text[], uuid, boolean);

--SPLIT--

-- Hierarchy traversal

DROP FUNCTION IF EXISTS $SCHEMA$.related_areas_many(
  text[], text[], uuid, boolean);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.related_areas(
  text, text[], uuid, boolean);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.ancestors_of_many(
  text[], text[], text[], integer, uuid, boolean);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.ancestors_of(
  text, text[], text[], integer, uuid, boolean);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.children_of_many(
  text[], text[], text[], integer, uuid, boolean);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.children_of(
  text, text[], text[], integer, uuid, boolean);

--SPLIT--

-- Proximity, code lookup, and ranked name search

DROP FUNCTION IF EXISTS $SCHEMA$.search_areas(
  text, text[], text[], integer, uuid, boolean);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.areas_by_code_many(
  text, text[], text[], text[], uuid, boolean, text, integer);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.areas_by_code(
  text, text, text[], text[], uuid, boolean, text, integer);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.areas_near(
  double precision, double precision, double precision, text[], text[], integer, uuid, boolean);

--SPLIT--

-- The area_match type and spatial resolution functions

DROP FUNCTION IF EXISTS $SCHEMA$.areas_for_geometry(
  geometry, text[], text[], uuid, boolean);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.areas_for_point(
  double precision, double precision, text[], text[], uuid, boolean);

--SPLIT--

DROP TYPE IF EXISTS $SCHEMA$.seeded_area_match;

--SPLIT--

DROP TYPE IF EXISTS $SCHEMA$.area_match;

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.assert_seed_keys(text[], text);

--SPLIT--

-- Read views, dropped published-before-base so every RESTRICT dependency is
-- already gone by the time its base view is reached: published_area_relations
-- depends on release_relations, the codes and names pairs on each other and on
-- release_areas, and published_areas on release_areas.

DROP VIEW IF EXISTS $SCHEMA$.published_boundaries;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.published_area_relations;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.release_relations;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.published_area_names;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.release_area_names;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.published_area_codes;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.release_area_codes;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.published_areas;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.release_areas;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.release_artifacts;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.import_run_status;

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.published_release(text);

--SPLIT--

-- The durable import run state machine

DROP FUNCTION IF EXISTS $SCHEMA$.analyze_release(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.drop_staging(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.create_staging(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.staging_table_name(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.fail_import(uuid, jsonb);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.advance_import(uuid, text, jsonb);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.heartbeat_import(uuid, jsonb);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.begin_or_resume_import(uuid, text, text, interval);

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.import_run_lease;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.import_run;

--SPLIT--

-- Publication lifecycle functions

DROP FUNCTION IF EXISTS $SCHEMA$.retire_releases(text, integer);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.rollback_publication(text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.publish_release(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.verify_release(uuid);

--SPLIT--

-- Write-side functions for areas, boundaries, and relations

DROP FUNCTION IF EXISTS $SCHEMA$.rebuild_relations(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_relation(uuid, text, text, text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_relation_many(uuid, text[], text[], text[]);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_area_in_release(uuid, text, geography, jsonb);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_area_in_release_many(uuid, text[], geography[], jsonb[]);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_boundary(uuid, text, uuid, geometry, double precision);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_area_code(text, text, text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_area_code_many(text[], text[], text[]);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_area_name(text, text, text, text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_area_name_many(text[], text[], text[], text[]);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_area(text, text, text, text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_area_many(text, text[], text[], text[]);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.assert_resolved(text, text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.lock_areas(bigint[]);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.area_lock_key(uuid, text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.assert_write_arrays(integer[], integer[], text[]);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.attach_source_release(uuid, uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.open_release(text, text, jsonb, date);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.record_artifact_observation(uuid, text, bigint);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.put_artifact(uuid, text, text, boolean, text, text, bigint, jsonb);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_source_release(text, text, text, date, jsonb);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_source(text, text, text, text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_area_type(text, text, integer);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_authority(text, text, text);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.upsert_collection(text, text, text, boolean);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.release_at(text, timestamptz);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.area_codes_json(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.assert_area_in_collection(uuid, uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.assert_release_mutable(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.publication_lock_key(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.relation_lock_key(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.classify_relation(numeric, numeric);

--SPLIT--

-- Partitioned boundaries, subdivided parts, relations, and attributes

DROP FUNCTION IF EXISTS $SCHEMA$.drop_release_partitions(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.create_release_partitions(uuid);

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.partition_lock_key();

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.release_area;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.relation;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.boundary_part;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.boundary;

--SPLIT--

-- Sources, releases, publication, and the publishable-release trigger

DROP TABLE IF EXISTS $SCHEMA$.publication_event;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.publication;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.release_source;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.release;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.artifact;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.source_release;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.source;

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.publication_release_is_publishable();

--SPLIT--

-- Collections, authorities, area types, and stable area identity

DROP TABLE IF EXISTS $SCHEMA$.area_code;

--SPLIT--

DROP TRIGGER IF EXISTS area_name_official_name_delete_trg ON $SCHEMA$.area_name;

--SPLIT--

DROP TRIGGER IF EXISTS area_name_official_name_update_trg ON $SCHEMA$.area_name;

--SPLIT--

DROP TRIGGER IF EXISTS area_name_official_name_insert_trg ON $SCHEMA$.area_name;

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.area_name_maintains_official_name();

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.refresh_area_official_names(uuid[]);

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.area_name;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.area;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.area_type;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.authority;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.collection;

--SPLIT--

DROP FUNCTION IF EXISTS $SCHEMA$.assert_extensions(text[]);

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.geo_genius_version;

--SPLIT--

-- Every object this migration created has been dropped by name above. The
-- schema itself is removed only when nothing else remains in it: GeoGenius
-- can be installed into a schema the host already uses, and a CASCADE here
-- would take the host's unrelated tables with it.
-- $SCHEMA$ expands to an escaped identifier, quoted when the prefix needs
-- quoting, so it is resolved to a namespace OID rather than compared as a
-- name; regnamespace input accepts both the quoted and the bare form.
-- A staging table (created by create_staging, named from a run id) is not
-- among the objects dropped above, so a run that died mid-phase and left one
-- behind keeps the count below from reaching zero, blocking the schema drop
-- with a notice rather than silently taking the leaked table with it.
DO $do$
DECLARE
  target_namespace oid := to_regnamespace('$SCHEMA$');
  remaining bigint;
BEGIN
  IF target_namespace IS NULL THEN
    RETURN;
  END IF;

  SELECT count(*) INTO remaining
    FROM pg_class
   WHERE pg_class.relnamespace = target_namespace
     AND pg_class.relispartition = false;

  SELECT remaining + count(*) INTO remaining
    FROM pg_proc
   WHERE pg_proc.pronamespace = target_namespace;

  SELECT remaining + count(*) INTO remaining
    FROM pg_type
   WHERE pg_type.typnamespace = target_namespace
     AND pg_type.typtype <> 'c';

  IF remaining = 0 THEN
    EXECUTE format('DROP SCHEMA %s RESTRICT', '$SCHEMA$');
  ELSE
    RAISE NOTICE
      'schema % still holds % object(s) that GeoGenius does not own; leaving it in place',
      target_namespace::regnamespace, remaining;
  END IF;
END;
$do$;
