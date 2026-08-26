CREATE SCHEMA IF NOT EXISTS $SCHEMA$;

--SPLIT--

CREATE OR REPLACE VIEW $SCHEMA$.geo_genius_version AS SELECT 1 AS installed;

--SPLIT--

CREATE FUNCTION $SCHEMA$.assert_extensions(required text[])
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  missing text;
  unreachable text;
BEGIN
  SELECT string_agg(name, ', ' ORDER BY name)
    INTO missing
    FROM unnest(required) AS name
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_extension WHERE extname = name
   );

  IF missing IS NOT NULL THEN
    RAISE EXCEPTION
      'GeoGenius has required PostgreSQL extension(s) that are not installed: %', missing
      USING
        ERRCODE = '42704',
        HINT = 'Install them with CREATE EXTENSION as a privileged role, then re-run the migration.';
  END IF;

  -- Every GeoGenius function pins search_path to pg_catalog, public, and the
  -- install prefix. An extension installed into some other schema is present
  -- in pg_extension but its unqualified operators and functions (ST_Covers,
  -- similarity, the % operator) will not resolve at runtime, so presence
  -- alone is not enough to call the install safe.
  SELECT string_agg(ext.extname || ' (in schema ' || ns.nspname || ')', ', ' ORDER BY ext.extname)
    INTO unreachable
    FROM pg_extension ext
    JOIN pg_namespace ns ON ns.oid = ext.extnamespace
   WHERE ext.extname = ANY(required)
     AND ext.extnamespace NOT IN (
       'pg_catalog'::regnamespace,
       'public'::regnamespace,
       coalesce(to_regnamespace('$SCHEMA$'), 0::oid)
     );

  IF unreachable IS NOT NULL THEN
    RAISE EXCEPTION
      'GeoGenius requires extension(s) reachable from pg_catalog, public, or $SCHEMA$: %', unreachable
      USING
        ERRCODE = '42704',
        HINT = 'Move the extension with ALTER EXTENSION ... SET SCHEMA public, or install GeoGenius into that schema.';
  END IF;
END;
$fn$;

--SPLIT--

SELECT $SCHEMA$.assert_extensions(ARRAY['postgis', 'pg_trgm']);

--SPLIT--

-- Collections, authorities, area types, and stable area identity

CREATE TABLE $SCHEMA$.collection (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text NOT NULL,
  name text NOT NULL,
  description text,
  requires_geometry boolean NOT NULL DEFAULT false,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT collection_key_uq UNIQUE (key),
  CONSTRAINT collection_key_format_chk CHECK (key ~ '^[a-z_][a-z0-9_]*$'),
  CONSTRAINT collection_name_nonempty_chk CHECK (btrim(name) <> '')
);

--SPLIT--

CREATE TABLE $SCHEMA$.authority (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  key text NOT NULL,
  name text NOT NULL,
  CONSTRAINT authority_collection_key_uq UNIQUE (collection_id, key),
  CONSTRAINT authority_key_format_chk CHECK (key ~ '^[a-z_][a-z0-9_]*$')
);

--SPLIT--

CREATE TABLE $SCHEMA$.area_type (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  key text NOT NULL,
  rank integer NOT NULL,
  CONSTRAINT area_type_collection_key_uq UNIQUE (collection_id, key),
  CONSTRAINT area_type_collection_rank_uq UNIQUE (collection_id, rank),
  CONSTRAINT area_type_key_format_chk CHECK (key ~ '^[a-z_][a-z0-9_]*$'),
  CONSTRAINT area_type_rank_positive_chk CHECK (rank > 0)
);

--SPLIT--

CREATE TABLE $SCHEMA$.area (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  authority_id uuid NOT NULL REFERENCES $SCHEMA$.authority(id) ON DELETE RESTRICT,
  area_type_id uuid NOT NULL REFERENCES $SCHEMA$.area_type(id) ON DELETE RESTRICT,
  code text NOT NULL,
  area_key text NOT NULL,
  -- The area's official name, maintained by a trigger on area_name. Reads
  -- resolve it as a column rather than a per-row lookup: release_areas is the
  -- surface hosts join, and a correlated subquery there costs every consumer
  -- an index probe per row on every scan.
  official_name text,
  retired_at timestamptz,
  successor_id uuid REFERENCES $SCHEMA$.area(id) ON DELETE SET NULL,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT area_area_key_uq UNIQUE (area_key),
  CONSTRAINT area_identity_uq UNIQUE (authority_id, area_type_id, code),
  CONSTRAINT area_code_nonempty_chk CHECK (btrim(code) <> ''),
  CONSTRAINT area_successor_not_self_chk CHECK (successor_id IS NULL OR successor_id <> id)
);

--SPLIT--

CREATE TABLE $SCHEMA$.area_name (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id uuid NOT NULL REFERENCES $SCHEMA$.area(id) ON DELETE CASCADE,
  name text NOT NULL,
  kind text NOT NULL DEFAULT 'official',
  locale text,
  CONSTRAINT area_name_nonempty_chk CHECK (btrim(name) <> ''),
  CONSTRAINT area_name_kind_chk
    CHECK (kind IN ('official', 'alias', 'mailing', 'abbreviation')),
  CONSTRAINT area_name_uq UNIQUE NULLS NOT DISTINCT (area_id, kind, name, locale)
);

--SPLIT--

CREATE INDEX area_name_trgm_idx
  ON $SCHEMA$.area_name USING gin (name gin_trgm_ops);

--SPLIT--

CREATE INDEX area_name_area_kind_idx
  ON $SCHEMA$.area_name (area_id, kind);

--SPLIT--

-- Recomputes area.official_name for a set of areas. The selection rule is the
-- one callers see wherever a name is resolved: the official-kind name, locale
-- NULLS FIRST so an unlocalized name outranks a localized one, then name for a
-- deterministic winner among equals.
CREATE FUNCTION $SCHEMA$.refresh_area_official_names(target_area_ids uuid[])
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  UPDATE $SCHEMA$.area
     SET official_name = (
       SELECT area_name.name
         FROM $SCHEMA$.area_name
        WHERE area_name.area_id = area.id
          AND area_name.kind = 'official'
        ORDER BY area_name.locale NULLS FIRST, area_name.name
        LIMIT 1
     )
   WHERE area.id = ANY(target_area_ids);
END;
$fn$;

--SPLIT--

-- Statement-level with transition tables, not row-level: an import writes
-- names in bulk, and a per-row trigger turns one insert of 100k names into
-- 100k single-row updates. Measured on 100k names: 3.8 s row-level against
-- 2.6 s for this set-based form, with a single-row write unaffected at 0.3 ms.
CREATE FUNCTION $SCHEMA$.area_name_maintains_official_name()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  -- Each branch reads only the transition tables its own trigger declares.
  -- plpgsql plans a statement the first time its branch runs, so a branch that
  -- does not apply is never planned and never fails to resolve its table.
  IF TG_OP = 'INSERT' THEN
    PERFORM $SCHEMA$.refresh_area_official_names(
      ARRAY(SELECT DISTINCT area_id FROM new_names));
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM $SCHEMA$.refresh_area_official_names(
      ARRAY(SELECT DISTINCT area_id FROM old_names));
  ELSE
    PERFORM $SCHEMA$.refresh_area_official_names(
      ARRAY(SELECT area_id FROM new_names UNION SELECT area_id FROM old_names));
  END IF;

  RETURN NULL;
END;
$fn$;

--SPLIT--

CREATE TRIGGER area_name_official_name_insert_trg
AFTER INSERT ON $SCHEMA$.area_name
REFERENCING NEW TABLE AS new_names
FOR EACH STATEMENT
EXECUTE FUNCTION $SCHEMA$.area_name_maintains_official_name();

--SPLIT--

CREATE TRIGGER area_name_official_name_update_trg
AFTER UPDATE ON $SCHEMA$.area_name
REFERENCING OLD TABLE AS old_names NEW TABLE AS new_names
FOR EACH STATEMENT
EXECUTE FUNCTION $SCHEMA$.area_name_maintains_official_name();

--SPLIT--

CREATE TRIGGER area_name_official_name_delete_trg
AFTER DELETE ON $SCHEMA$.area_name
REFERENCING OLD TABLE AS old_names
FOR EACH STATEMENT
EXECUTE FUNCTION $SCHEMA$.area_name_maintains_official_name();

--SPLIT--

CREATE TABLE $SCHEMA$.area_code (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id uuid NOT NULL REFERENCES $SCHEMA$.area(id) ON DELETE CASCADE,
  code_type text NOT NULL,
  code_value text NOT NULL,
  CONSTRAINT area_code_uq UNIQUE (area_id, code_type, code_value),
  CONSTRAINT area_code_type_format_chk CHECK (code_type ~ '^[a-z_][a-z0-9_]*$'),
  CONSTRAINT area_code_value_nonempty_chk CHECK (btrim(code_value) <> '')
);

--SPLIT--

CREATE INDEX area_code_lookup_idx
  ON $SCHEMA$.area_code (code_type, code_value, area_id);

--SPLIT--

-- Sources, releases, publication, and the publishable-release trigger

CREATE TABLE $SCHEMA$.source (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  source_key text NOT NULL,
  provider text NOT NULL,
  license text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT source_source_key_key UNIQUE (collection_id, source_key)
);

--SPLIT--

CREATE TABLE $SCHEMA$.source_release (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL
    REFERENCES $SCHEMA$.source(id),
  release_key text NOT NULL,
  source_date date,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT source_release_identity_key UNIQUE (source_id, release_key)
);

--SPLIT--

CREATE TABLE $SCHEMA$.artifact (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_release_id uuid NOT NULL
    REFERENCES $SCHEMA$.source_release(id) ON DELETE CASCADE,
  logical_name text NOT NULL,
  url text,
  operator_supplied boolean NOT NULL DEFAULT false,
  format text NOT NULL,
  expected_sha256 text NOT NULL,
  expected_bytes bigint NOT NULL,
  observed_sha256 text,
  observed_bytes bigint,
  validated_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT artifact_logical_name_key
    UNIQUE (source_release_id, logical_name),
  CONSTRAINT artifact_expected_sha256_check
    CHECK (expected_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT artifact_expected_bytes_check
    CHECK (expected_bytes > 0),
  CONSTRAINT artifact_observed_sha256_check
    CHECK (observed_sha256 IS NULL OR observed_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT artifact_observed_bytes_check
    CHECK (observed_bytes IS NULL OR observed_bytes >= 0),
  CONSTRAINT artifact_observation_pair_check
    CHECK ((observed_sha256 IS NULL) = (observed_bytes IS NULL)),
  CONSTRAINT artifact_location_check
    CHECK ((url IS NOT NULL) <> operator_supplied)
);

--SPLIT--

CREATE TABLE $SCHEMA$.release (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  release_key text NOT NULL,
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending',
  manifest jsonb NOT NULL,
  source_date date,
  completed_at timestamptz,
  -- Set by retire_releases, which drops the release's partitions but keeps
  -- this row: publication_event and import_run reference it, and both are
  -- meant to survive retention indefinitely.
  retired_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT release_release_key_key UNIQUE (collection_id, release_key),
  CONSTRAINT release_status_check
    CHECK (status IN (
      'pending',
      'downloading',
      'validating',
      'staging',
      'normalizing',
      'relating',
      'indexing',
      'verifying',
      'publishing',
      'completed',
      'failed'
    ))
);

--SPLIT--

CREATE TABLE $SCHEMA$.release_source (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  release_id uuid NOT NULL
    REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  source_release_id uuid NOT NULL
    REFERENCES $SCHEMA$.source_release(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT release_source_identity_key
    UNIQUE (release_id, source_release_id)
);

--SPLIT--

CREATE TABLE $SCHEMA$.publication (
  collection_id uuid PRIMARY KEY
    REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  release_id uuid NOT NULL
    REFERENCES $SCHEMA$.release(id),
  previous_release_id uuid
    REFERENCES $SCHEMA$.release(id) ON DELETE SET NULL,
  published_at timestamptz NOT NULL DEFAULT now()
);

--SPLIT--

CREATE TABLE $SCHEMA$.publication_event (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Assigned before commit, so a concurrent poller can briefly see a gap
  -- that a slightly-behind concurrent transaction later fills. Poll off
  -- the highest contiguous sequence, or accept a small lag, rather than
  -- treating the latest value as an immediate watermark.
  sequence bigint GENERATED ALWAYS AS IDENTITY,
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  previous_release_id uuid REFERENCES $SCHEMA$.release(id) ON DELETE SET NULL,
  kind text NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT publication_event_kind_chk CHECK (kind IN ('published', 'rolled_back'))
);

--SPLIT--

CREATE INDEX publication_event_collection_occurred_idx
  ON $SCHEMA$.publication_event (collection_id, occurred_at DESC, id);

--SPLIT--

CREATE INDEX publication_event_sequence_idx
  ON $SCHEMA$.publication_event (sequence);

--SPLIT--

CREATE FUNCTION $SCHEMA$.publication_release_is_publishable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  current_publication record;
BEGIN
  IF TG_TABLE_NAME = 'publication' THEN
    SELECT
      publication.collection_id,
      publication.release_id,
      release.collection_id AS release_collection_id,
      release.status AS release_status
    INTO current_publication
    FROM $SCHEMA$.publication
    JOIN $SCHEMA$.release
      ON release.id = publication.release_id
    WHERE publication.collection_id = NEW.collection_id
    FOR UPDATE OF release;
  ELSE
    SELECT
      publication.collection_id,
      publication.release_id,
      release.collection_id AS release_collection_id,
      release.status AS release_status
    INTO current_publication
    FROM $SCHEMA$.release
    JOIN $SCHEMA$.publication
      ON publication.release_id = release.id
    WHERE release.id = NEW.id
      AND (
        release.status <> 'completed'
        OR release.collection_id <> publication.collection_id
      )
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF current_publication.release_status <> 'completed'
     OR current_publication.release_collection_id <> current_publication.collection_id
  THEN
    RAISE EXCEPTION
      'release % is not a completed release for collection %',
      current_publication.release_id,
      current_publication.collection_id
      USING
        ERRCODE = '23514',
        CONSTRAINT = TG_NAME;
  END IF;

  RETURN NULL;
END;
$fn$;

--SPLIT--

CREATE CONSTRAINT TRIGGER publication_completed_release_check
AFTER INSERT OR UPDATE ON $SCHEMA$.publication
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE FUNCTION $SCHEMA$.publication_release_is_publishable();

--SPLIT--

CREATE CONSTRAINT TRIGGER release_publication_check
AFTER UPDATE ON $SCHEMA$.release
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
WHEN (
  OLD.status IS DISTINCT FROM NEW.status
  OR OLD.collection_id IS DISTINCT FROM NEW.collection_id
)
EXECUTE FUNCTION $SCHEMA$.publication_release_is_publishable();

--SPLIT--

-- Partitioned boundaries, subdivided parts, relations, and attributes

CREATE TABLE $SCHEMA$.boundary (
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  area_id uuid NOT NULL REFERENCES $SCHEMA$.area(id),
  source_release_id uuid NOT NULL REFERENCES $SCHEMA$.source_release(id),
  geom geometry(Geometry, 4326) NOT NULL,
  display_geom geometry(Geometry, 4326) NOT NULL,
  display_tier smallint NOT NULL DEFAULT 0,
  valid_from date,
  valid_to date,
  repaired boolean NOT NULL DEFAULT false,
  source_properties jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT boundary_pkey PRIMARY KEY (release_id, area_id, display_tier),
  CONSTRAINT boundary_geom_polygonal_chk
    CHECK (GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON')),
  CONSTRAINT boundary_display_geom_polygonal_chk
    CHECK (GeometryType(display_geom) IN ('POLYGON', 'MULTIPOLYGON')),
  CONSTRAINT boundary_geom_valid_chk CHECK (ST_IsValid(geom)),
  CONSTRAINT boundary_geom_nonempty_chk CHECK (NOT ST_IsEmpty(geom)),
  CONSTRAINT boundary_display_geom_valid_chk CHECK (ST_IsValid(display_geom)),
  CONSTRAINT boundary_display_geom_nonempty_chk CHECK (NOT ST_IsEmpty(display_geom)),
  CONSTRAINT boundary_display_tier_chk CHECK (display_tier BETWEEN 0 AND 20),
  CONSTRAINT boundary_validity_window_chk
    CHECK (valid_from IS NULL OR valid_to IS NULL OR valid_from <= valid_to)
) PARTITION BY LIST (release_id);

--SPLIT--

CREATE INDEX boundary_geom_gist_idx ON $SCHEMA$.boundary USING gist (geom);

--SPLIT--

CREATE INDEX boundary_area_idx ON $SCHEMA$.boundary (area_id, release_id);

--SPLIT--

-- areas_near measures on the geography cast, which the plain geometry GiST
-- index cannot serve. Without this expression index every proximity query
-- scans each tier-zero boundary in the release.
CREATE INDEX boundary_geog_gist_idx
  ON $SCHEMA$.boundary USING gist ((geom::geography));

--SPLIT--

ALTER TABLE $SCHEMA$.boundary ALTER COLUMN geom SET STATISTICS 1000;

--SPLIT--

CREATE TABLE $SCHEMA$.boundary_part (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  area_id uuid NOT NULL REFERENCES $SCHEMA$.area(id),
  geom geometry(Geometry, 4326) NOT NULL,
  CONSTRAINT boundary_part_pkey PRIMARY KEY (release_id, id),
  CONSTRAINT boundary_part_geom_polygonal_chk
    CHECK (GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON'))
) PARTITION BY LIST (release_id);

--SPLIT--

CREATE INDEX boundary_part_geom_gist_idx ON $SCHEMA$.boundary_part USING gist (geom);

--SPLIT--

CREATE INDEX boundary_part_area_idx ON $SCHEMA$.boundary_part (release_id, area_id);

--SPLIT--

CREATE TABLE $SCHEMA$.relation (
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  parent_area_id uuid NOT NULL REFERENCES $SCHEMA$.area(id),
  child_area_id uuid NOT NULL REFERENCES $SCHEMA$.area(id),
  relation_type text NOT NULL,
  -- intersection_area_m2, parent_coverage, and child_coverage hold a
  -- geometry-measured value, or NULL when the relation is asserted from
  -- source data rather than measured. A CHECK constraint accepts NULL
  -- (it is neither true nor false), so any value that is present is still
  -- held to the same bounds as a measured one.
  intersection_area_m2 numeric,
  parent_coverage numeric,
  child_coverage numeric,
  CONSTRAINT relation_pkey PRIMARY KEY (release_id, parent_area_id, child_area_id),
  CONSTRAINT relation_distinct_areas_chk CHECK (parent_area_id <> child_area_id),
  CONSTRAINT relation_type_chk
    CHECK (relation_type IN ('contains', 'mostly_contains', 'overlaps')),
  CONSTRAINT relation_intersection_area_chk CHECK (intersection_area_m2 > 0),
  CONSTRAINT relation_parent_coverage_chk CHECK (parent_coverage BETWEEN 0 AND 1),
  CONSTRAINT relation_child_coverage_chk CHECK (child_coverage BETWEEN 0 AND 1),
  -- A relation is measured (all three present) or asserted (all three
  -- absent). A partially populated row would make that distinction
  -- unreadable, so it is rejected outright.
  CONSTRAINT relation_measurement_complete_chk CHECK (
    num_nonnulls(intersection_area_m2, parent_coverage, child_coverage) IN (0, 3)
  )
) PARTITION BY LIST (release_id);

--SPLIT--

CREATE INDEX relation_child_lookup_idx
  ON $SCHEMA$.relation (release_id, child_area_id, relation_type, parent_area_id);

--SPLIT--

-- This area participates in this release, with this centroid and these
-- attributes. A row here is what makes an area a member of a release;
-- neither a centroid nor a boundary is required.
CREATE TABLE $SCHEMA$.release_area (
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  area_id uuid NOT NULL REFERENCES $SCHEMA$.area(id),
  centroid geography(Point, 4326),
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT release_area_pkey PRIMARY KEY (release_id, area_id),
  CONSTRAINT release_area_data_object_chk CHECK (jsonb_typeof(data) = 'object')
) PARTITION BY LIST (release_id);

--SPLIT--

-- search_areas and areas_by_code both reach release_area from area_id with
-- no release predicate, which the (release_id, area_id) primary key cannot
-- serve. boundary_area_idx is the same mirror for boundary.
CREATE INDEX release_area_area_idx
  ON $SCHEMA$.release_area (area_id, release_id);

--SPLIT--

CREATE INDEX release_area_centroid_gist_idx
  ON $SCHEMA$.release_area USING gist (centroid);

--SPLIT--

-- One key for every statement that creates or drops a release's partitions.
-- Creating a partition clones the parent's foreign key to release, which needs
-- a ShareRowExclusiveLock on release, while the caller that just inserted that
-- release row holds a RowExclusiveLock on it; two callers doing this at once
-- each hold what the other needs and PostgreSQL breaks the cycle by killing
-- one with a 40P01. Serializing on one key removes the cycle and costs
-- nothing, because partition DDL already serializes globally on each parent's
-- AccessExclusiveLock: two callers were never going to build partitions at the
-- same time, only to deadlock trying.
--
-- The key is global rather than per-release on purpose. A per-release key
-- serializes two imports of the same release and leaves two imports of
-- different releases free to form exactly the cycle above.
CREATE FUNCTION $SCHEMA$.partition_lock_key()
RETURNS bigint
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
  SELECT (
    (
      'x' || substr(
        md5('$SCHEMA$.release_partitions'),
        1,
        16
      )
    )::bit(64)
  )::bigint;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.create_release_partitions(target_release_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  suffix text;
  parent text;
BEGIN
  IF target_release_id IS NULL THEN
    RAISE EXCEPTION 'release id is required' USING ERRCODE = '22004';
  END IF;

  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  IF NOT EXISTS (SELECT 1 FROM $SCHEMA$.release WHERE id = target_release_id) THEN
    RAISE EXCEPTION 'release % does not exist', target_release_id USING ERRCODE = '23503';
  END IF;

  suffix := replace(target_release_id::text, '-', '');

  FOREACH parent IN ARRAY ARRAY['boundary', 'boundary_part', 'relation', 'release_area'] LOOP
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS $SCHEMA$.%I PARTITION OF $SCHEMA$.%I FOR VALUES IN (%L)',
      parent || '_' || suffix,
      parent,
      target_release_id
    );
  END LOOP;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.drop_release_partitions(target_release_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  suffix text;
  parent text;
BEGIN
  IF target_release_id IS NULL THEN
    RAISE EXCEPTION 'release id is required' USING ERRCODE = '22004';
  END IF;

  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  suffix := replace(target_release_id::text, '-', '');

  FOREACH parent IN ARRAY ARRAY['release_area', 'relation', 'boundary_part', 'boundary'] LOOP
    EXECUTE format('DROP TABLE IF EXISTS $SCHEMA$.%I', parent || '_' || suffix);
  END LOOP;
END;
$fn$;

--SPLIT--

-- Write-side functions for areas, boundaries, and relations

CREATE FUNCTION $SCHEMA$.classify_relation(
  intersection_area numeric,
  child_coverage numeric
)
RETURNS text
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF intersection_area IS NULL OR child_coverage IS NULL THEN
    RETURN NULL;
  END IF;

  IF intersection_area < 0
     OR child_coverage < 0
     OR child_coverage > 1
  THEN
    RAISE EXCEPTION
      'invalid relation measurement: intersection area %, child coverage %',
      intersection_area,
      child_coverage
      USING ERRCODE = '22023';
  END IF;

  IF intersection_area = 0 THEN
    RETURN NULL;
  ELSIF child_coverage >= 0.999 THEN
    RETURN 'contains';
  ELSIF child_coverage >= 0.50 THEN
    RETURN 'mostly_contains';
  END IF;

  RETURN 'overlaps';
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.relation_lock_key(
  target_release_id uuid
)
RETURNS bigint
LANGUAGE sql
STABLE
STRICT
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
  SELECT (
    (
      'x' || substr(
        md5('$SCHEMA$.relations:' || target_release_id::text),
        1,
        16
      )
    )::bit(64)
  )::bigint;
$fn$;

--SPLIT--

-- Raises unless the release can still be written to. A release that has been
-- published is the immutable input to every published_* read; letting a
-- writer change it in place would move published results with no verification
-- and no publication_event, which is the only change signal hosts get.
-- Retired releases are closed for the same reason: their partitions are gone.
-- One key for every statement that moves a collection's publication pointer.
-- publish_release, rollback_publication, and retire_releases all swap or read
-- that pointer and must not interleave: two concurrent publishes in one
-- collection would otherwise race to set previous_release_id and could leave a
-- rollback target that was never the published release. Defined once here
-- rather than restated at each call site, so the three cannot drift apart and
-- so a test can take the same lock by calling this.
CREATE FUNCTION $SCHEMA$.publication_lock_key(target_collection_id uuid)
RETURNS bigint
LANGUAGE sql
STABLE
STRICT
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
  SELECT (
    (
      'x' || substr(
        md5('$SCHEMA$.publication:' || target_collection_id::text),
        1,
        16
      )
    )::bit(64)
  )::bigint;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.assert_release_mutable(target_release_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  release_status text;
  release_retired_at timestamptz;
BEGIN
  SELECT status, retired_at INTO STRICT release_status, release_retired_at
    FROM $SCHEMA$.release WHERE id = target_release_id;

  IF release_retired_at IS NOT NULL THEN
    RAISE EXCEPTION 'release % is retired and cannot be modified', target_release_id
      USING
        ERRCODE = '55000',
        HINT = 'Build a new release instead of writing to a retired one.';
  END IF;

  IF release_status = 'completed' THEN
    RAISE EXCEPTION 'release % is completed and cannot be modified', target_release_id
      USING
        ERRCODE = '55000',
        HINT = 'Build a new release and publish it; a completed release is immutable.';
  END IF;
END;
$fn$;

--SPLIT--

-- Raises unless the area belongs to the same collection as the release it is
-- being written into. Every spatial table references area(id) directly, so no
-- foreign key can express this; the write API is where it is enforced.
CREATE FUNCTION $SCHEMA$.assert_area_in_collection(
  target_release_id uuid,
  target_area_id uuid
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  release_collection_id uuid;
  area_collection_id uuid;
BEGIN
  SELECT collection_id INTO STRICT release_collection_id
    FROM $SCHEMA$.release WHERE id = target_release_id;

  SELECT collection_id INTO STRICT area_collection_id
    FROM $SCHEMA$.area WHERE id = target_area_id;

  IF release_collection_id <> area_collection_id THEN
    RAISE EXCEPTION
      'area % belongs to collection %, but release % belongs to collection %',
      target_area_id, area_collection_id, target_release_id, release_collection_id
      USING ERRCODE = '23503';
  END IF;
END;
$fn$;

--SPLIT--

-- Every code an area carries, grouped by code type. An area may legally hold
-- several values of one type (two postal codes, say), so each type maps to an
-- array rather than a single value: a scalar mapping silently drops all but
-- one, including the very code the caller looked the area up by.
CREATE FUNCTION $SCHEMA$.area_codes_json(target_area_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
  SELECT jsonb_object_agg(code_type, code_values)
    FROM (
      SELECT area_code.code_type,
             jsonb_agg(area_code.code_value ORDER BY area_code.code_value) AS code_values
        FROM $SCHEMA$.area_code
       WHERE area_code.area_id = target_area_id
       GROUP BY area_code.code_type
    ) grouped;
$fn$;

--SPLIT--

-- The release a collection had published at a given moment, or NULL if it had
-- published nothing yet. Reads take a release id rather than a timestamp, so
-- this is how a caller turns "what did we serve on January 15" into an
-- argument for target_release_id.
CREATE FUNCTION $SCHEMA$.release_at(collection_key text, as_of timestamptz)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_collection_id uuid;
  result_id uuid;
BEGIN
  IF collection_key IS NULL OR as_of IS NULL THEN
    RAISE EXCEPTION 'collection key and as_of are required' USING ERRCODE = '22004';
  END IF;

  SELECT id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  -- A collection the catalog does not carry and a collection that has
  -- published nothing are the same answer to a caller: there is no release to
  -- pin, so both return NULL rather than one of them raising.
  IF target_collection_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT event.release_id INTO result_id
    FROM $SCHEMA$.publication_event event
   WHERE event.collection_id = target_collection_id
     AND event.occurred_at <= as_of
   ORDER BY event.occurred_at DESC, event.sequence DESC
   LIMIT 1;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.upsert_collection(
  key text,
  name text,
  description text,
  requires_geometry boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  result_id uuid;
BEGIN
  IF key IS NULL OR name IS NULL THEN
    RAISE EXCEPTION 'key and name are required'
      USING ERRCODE = '22004';
  END IF;

  INSERT INTO $SCHEMA$.collection (key, name, description, requires_geometry)
  VALUES (key, name, description, coalesce(requires_geometry, false))
  ON CONFLICT ON CONSTRAINT collection_key_uq
  DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    requires_geometry = EXCLUDED.requires_geometry,
    updated_at = now()
  RETURNING id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.upsert_authority(
  collection_key text,
  key text,
  name text
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
  IF collection_key IS NULL OR key IS NULL OR name IS NULL THEN
    RAISE EXCEPTION 'collection, key, and name are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'collection % does not exist', collection_key USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.authority (collection_id, key, name)
  VALUES (target_collection_id, key, name)
  ON CONFLICT ON CONSTRAINT authority_collection_key_uq
  DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.upsert_area_type(
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

  -- area_type carries two unique constraints, and ON CONFLICT can name only
  -- one of them as its arbiter. Two callers upserting the same area type at
  -- once each insert speculatively; the one that loses can block on the rank
  -- index rather than the key index it named, and a wait that resolves there
  -- surfaces as a bare 23505 on area_type_collection_rank_uq instead of the
  -- DO UPDATE this call asked for. Serializing on the arbiter's own identity
  -- means the second caller sees a committed row and takes the DO UPDATE
  -- path. Two callers upserting *different* keys at the same rank do not
  -- serialize here and still get the rank violation, which is the constraint
  -- doing its job.
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

CREATE FUNCTION $SCHEMA$.upsert_source(
  collection_key text,
  source_key text,
  provider text,
  license text
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
  IF collection_key IS NULL OR source_key IS NULL OR provider IS NULL OR license IS NULL THEN
    RAISE EXCEPTION 'collection, source key, provider, and license are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT collection.id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'collection % does not exist', collection_key USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.source AS target
    (collection_id, source_key, provider, license)
  VALUES
    (target_collection_id, upsert_source.source_key, upsert_source.provider,
     upsert_source.license)
  ON CONFLICT ON CONSTRAINT source_source_key_key
  DO UPDATE SET provider = EXCLUDED.provider, license = EXCLUDED.license
  RETURNING target.id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.upsert_source_release(
  collection_key text,
  source_key text,
  release_key text,
  source_date date,
  metadata jsonb
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_source_id uuid;
  result_id uuid;
BEGIN
  IF collection_key IS NULL OR source_key IS NULL OR release_key IS NULL THEN
    RAISE EXCEPTION 'collection, source key, and release key are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT source.id INTO target_source_id
    FROM $SCHEMA$.source
    JOIN $SCHEMA$.collection ON collection.id = source.collection_id
   WHERE collection.key = collection_key
     AND source.source_key = upsert_source_release.source_key;

  IF target_source_id IS NULL THEN
    RAISE EXCEPTION 'source % does not exist in collection %', source_key, collection_key
      USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.source_release AS target
    (source_id, release_key, source_date, metadata)
  VALUES
    (target_source_id, upsert_source_release.release_key,
     upsert_source_release.source_date, coalesce(metadata, '{}'::jsonb))
  ON CONFLICT ON CONSTRAINT source_release_identity_key
  DO UPDATE SET
    source_date = EXCLUDED.source_date,
    metadata = EXCLUDED.metadata
  RETURNING target.id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.put_artifact(
  target_source_release_id uuid,
  logical_name text,
  url text,
  operator_supplied boolean,
  format text,
  expected_sha256 text,
  expected_bytes bigint,
  metadata jsonb
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  result_id uuid;
BEGIN
  IF target_source_release_id IS NULL OR logical_name IS NULL OR format IS NULL
     OR expected_sha256 IS NULL OR expected_bytes IS NULL THEN
    RAISE EXCEPTION
      'source release, logical name, format, expected sha256, and expected bytes are required'
      USING ERRCODE = '22004';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM $SCHEMA$.source_release WHERE id = target_source_release_id
  ) THEN
    RAISE EXCEPTION 'source release % does not exist', target_source_release_id
      USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.artifact AS target
    (source_release_id, logical_name, url, operator_supplied, format,
     expected_sha256, expected_bytes, metadata)
  VALUES
    (target_source_release_id, put_artifact.logical_name, put_artifact.url,
     coalesce(operator_supplied, false), put_artifact.format,
     lower(expected_sha256), put_artifact.expected_bytes, coalesce(metadata, '{}'::jsonb))
  ON CONFLICT ON CONSTRAINT artifact_logical_name_key
  DO UPDATE SET
    url = EXCLUDED.url,
    operator_supplied = EXCLUDED.operator_supplied,
    format = EXCLUDED.format,
    expected_sha256 = EXCLUDED.expected_sha256,
    expected_bytes = EXCLUDED.expected_bytes,
    metadata = EXCLUDED.metadata
  RETURNING target.id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

-- Records what was actually fetched. The expectation is the manifest's; the
-- observation is the wire's. Storing a mismatch would leave a release able to
-- pass verification on data nobody reviewed, so the mismatch is refused here
-- rather than reported to a caller who might carry on.
CREATE FUNCTION $SCHEMA$.record_artifact_observation(
  target_artifact_id uuid,
  observed_sha256 text,
  observed_bytes bigint
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  expectation record;
BEGIN
  IF target_artifact_id IS NULL OR observed_sha256 IS NULL OR observed_bytes IS NULL THEN
    RAISE EXCEPTION 'artifact id, observed sha256, and observed bytes are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT artifact.expected_sha256, artifact.expected_bytes
    INTO expectation
    FROM $SCHEMA$.artifact WHERE artifact.id = target_artifact_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'artifact % does not exist', target_artifact_id USING ERRCODE = '23503';
  END IF;

  IF lower(observed_sha256) <> expectation.expected_sha256
     OR observed_bytes <> expectation.expected_bytes THEN
    RAISE EXCEPTION
      'artifact % does not match its manifest: expected % bytes with sha256 %, observed % with %',
      target_artifact_id, expectation.expected_bytes, expectation.expected_sha256,
      observed_bytes, lower(observed_sha256)
      USING
        ERRCODE = '23514',
        HINT = 'The manifest is the reviewed record. Re-fetch the artifact, or ship a corrected manifest.';
  END IF;

  UPDATE $SCHEMA$.artifact
     SET observed_sha256 = lower(record_artifact_observation.observed_sha256),
         observed_bytes = record_artifact_observation.observed_bytes,
         validated_at = now()
   WHERE id = target_artifact_id;
END;
$fn$;

--SPLIT--

-- Opens a release for writing. A release that has never been published is
-- reopened with the manifest it is being rebuilt from, via a single upsert
-- rather than a check-then-insert, so two concurrent imports of the same
-- release_key cannot both miss each other and race to a raw unique-constraint
-- violation: the loser hits this function's own ON CONFLICT branch instead. A
-- published release is immutable, so the upsert's WHERE clause excludes it
-- from the update; the RETURNING clause then yields no row, and that is
-- reported as this function's own 55000 error rather than left as a silent
-- no-op or a bare 23505.
CREATE FUNCTION $SCHEMA$.open_release(
  collection_key text,
  release_key text,
  manifest jsonb,
  source_date date
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
  IF collection_key IS NULL OR release_key IS NULL OR manifest IS NULL THEN
    RAISE EXCEPTION 'collection, release key, and manifest are required'
      USING ERRCODE = '22004';
  END IF;

  IF jsonb_typeof(manifest) <> 'object' THEN
    RAISE EXCEPTION 'manifest must be a JSON object' USING ERRCODE = '22023';
  END IF;

  -- Taken here, ahead of the insert below, and not left to
  -- create_release_partitions to take on its own: by the time that function
  -- runs, this transaction already holds a RowExclusiveLock on release from
  -- its own insert, and holding that while waiting is exactly what closes the
  -- deadlock cycle partition_lock_key describes. Two importers starting at
  -- once therefore serialize here, before either has locked a release row,
  -- and the loser goes on to open the same or a different release cleanly.
  -- For two imports of one release, that means the loser reaches
  -- begin_or_resume_import and is told a live import already holds it, which
  -- is the refusal it should get instead of a 40P01.
  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  SELECT collection.id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'collection % does not exist', collection_key USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.release (collection_id, release_key, manifest, source_date)
  VALUES (target_collection_id, open_release.release_key, open_release.manifest,
          open_release.source_date)
  ON CONFLICT ON CONSTRAINT release_release_key_key
  DO UPDATE SET
    manifest = EXCLUDED.manifest,
    source_date = EXCLUDED.source_date,
    status = 'pending'
  WHERE release.status <> 'completed'
  RETURNING id INTO result_id;

  IF result_id IS NULL THEN
    -- The conflict fired but the WHERE excluded the row: the release is published.
    RAISE EXCEPTION 'release % of collection % is published and cannot be reopened',
      release_key, collection_key
      USING
        ERRCODE = '55000',
        HINT = 'A change to what hosts see is a new release. Import under a new release key.';
  END IF;

  PERFORM $SCHEMA$.create_release_partitions(result_id);

  RETURN result_id;
END;
$fn$;

--SPLIT--

-- Raises unless the source release belongs to the same collection as the
-- release it is being attached to. release_source has no foreign key that can
-- express that constraint (source_release and release each reference their
-- own collection independently), so the write API enforces it here, the same
-- way assert_area_in_collection enforces it for areas and boundaries.
-- Existence is checked explicitly, ahead of assert_release_mutable, so a
-- missing release is reported as this function's own 23503 rather than the
-- P0002 that assert_release_mutable's SELECT ... INTO STRICT would raise.
CREATE FUNCTION $SCHEMA$.attach_source_release(
  target_release_id uuid,
  target_source_release_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  release_collection_id uuid;
  source_release_collection_id uuid;
BEGIN
  IF target_release_id IS NULL OR target_source_release_id IS NULL THEN
    RAISE EXCEPTION 'release id and source release id are required' USING ERRCODE = '22004';
  END IF;

  SELECT release.collection_id INTO release_collection_id
    FROM $SCHEMA$.release WHERE release.id = target_release_id;

  IF release_collection_id IS NULL THEN
    RAISE EXCEPTION 'release % does not exist', target_release_id USING ERRCODE = '23503';
  END IF;

  SELECT source.collection_id INTO source_release_collection_id
    FROM $SCHEMA$.source_release
    JOIN $SCHEMA$.source ON source.id = source_release.source_id
   WHERE source_release.id = target_source_release_id;

  IF source_release_collection_id IS NULL THEN
    RAISE EXCEPTION 'source release % does not exist', target_source_release_id
      USING ERRCODE = '23503';
  END IF;

  IF release_collection_id <> source_release_collection_id THEN
    RAISE EXCEPTION
      'source release % belongs to collection %, but release % belongs to collection %',
      target_source_release_id, source_release_collection_id,
      target_release_id, release_collection_id
      USING ERRCODE = '23503';
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  INSERT INTO $SCHEMA$.release_source (release_id, source_release_id)
  VALUES (target_release_id, target_source_release_id)
  ON CONFLICT ON CONSTRAINT release_source_identity_key DO NOTHING;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.upsert_area(
  collection_key text,
  authority_key text,
  area_type_key text,
  code text
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_collection_id uuid;
  target_authority_id uuid;
  target_area_type_id uuid;
  composed_key text;
  result_id uuid;
BEGIN
  IF collection_key IS NULL OR authority_key IS NULL
     OR area_type_key IS NULL OR code IS NULL THEN
    RAISE EXCEPTION 'collection, authority, area type, and code are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT id INTO STRICT target_collection_id
    FROM $SCHEMA$.collection WHERE key = collection_key;

  SELECT id INTO STRICT target_authority_id
    FROM $SCHEMA$.authority
   WHERE collection_id = target_collection_id AND key = authority_key;

  SELECT id INTO STRICT target_area_type_id
    FROM $SCHEMA$.area_type
   WHERE collection_id = target_collection_id AND key = area_type_key;

  composed_key := authority_key || ':' || area_type_key || ':' || code;

  -- area carries two unique constraints (identity and area_key) and the same
  -- speculative-insert race as upsert_area_type above: a concurrent caller
  -- can block on area_area_key_uq rather than the area_identity_uq arbiter
  -- and get a bare 23505. Every row that collides on area_key within a
  -- collection collides on identity too, since area_key is composed from the
  -- identity, so serializing on the composed key covers both and stays as
  -- narrow as one area.
  PERFORM pg_advisory_xact_lock(
    ('x' || substr(md5('$SCHEMA$.area:' || target_collection_id::text || ':' || composed_key), 1, 16))::bit(64)::bigint
  );

  INSERT INTO $SCHEMA$.area
    (collection_id, authority_id, area_type_id, code, area_key)
  VALUES
    (target_collection_id, target_authority_id, target_area_type_id, code, composed_key)
  ON CONFLICT ON CONSTRAINT area_identity_uq
  DO UPDATE SET updated_at = now()
  RETURNING id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.put_area_name(
  target_area_key text,
  name text,
  kind text,
  locale text
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_area_id uuid;
  result_id uuid;
BEGIN
  IF target_area_key IS NULL OR name IS NULL OR kind IS NULL THEN
    RAISE EXCEPTION 'area key, name, and kind are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT id INTO STRICT target_area_id
    FROM $SCHEMA$.area WHERE area_key = target_area_key;

  INSERT INTO $SCHEMA$.area_name (area_id, name, kind, locale)
  VALUES (target_area_id, name, kind, locale)
  ON CONFLICT ON CONSTRAINT area_name_uq
  DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.put_area_code(
  target_area_key text,
  code_type text,
  code_value text
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_area_id uuid;
  result_id uuid;
BEGIN
  IF target_area_key IS NULL OR code_type IS NULL OR code_value IS NULL THEN
    RAISE EXCEPTION 'area key, code type, and code value are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT id INTO STRICT target_area_id
    FROM $SCHEMA$.area WHERE area_key = target_area_key;

  INSERT INTO $SCHEMA$.area_code (area_id, code_type, code_value)
  VALUES (target_area_id, code_type, code_value)
  ON CONFLICT ON CONSTRAINT area_code_uq
  DO UPDATE SET code_value = EXCLUDED.code_value
  RETURNING id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.put_boundary(
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

CREATE FUNCTION $SCHEMA$.put_area_in_release(
  target_release_id uuid,
  target_area_key text,
  centroid geography(Point, 4326),
  data jsonb
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_area_id uuid;
BEGIN
  IF target_release_id IS NULL OR target_area_key IS NULL THEN
    RAISE EXCEPTION 'release id and area key are required'
      USING ERRCODE = '22004';
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  SELECT id INTO STRICT target_area_id
    FROM $SCHEMA$.area WHERE area_key = target_area_key;

  PERFORM $SCHEMA$.assert_area_in_collection(target_release_id, target_area_id);

  INSERT INTO $SCHEMA$.release_area (release_id, area_id, centroid, data)
  VALUES (target_release_id, target_area_id, centroid, coalesce(data, '{}'::jsonb))
  ON CONFLICT (release_id, area_id)
  DO UPDATE SET
    centroid = EXCLUDED.centroid,
    data = EXCLUDED.data;
END;
$fn$;

--SPLIT--

-- Records a relation asserted from source data (for example, a parent
-- column in a reference hierarchy) rather than measured from geometry.
-- Both areas must already be members of the release; the measured columns
-- (intersection_area_m2, parent_coverage, child_coverage) are left NULL
-- because there is no geometry to measure them from.
CREATE FUNCTION $SCHEMA$.put_relation(
  target_release_id uuid,
  parent_area_key text,
  child_area_key text,
  relation_type text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_parent_area_id uuid;
  target_child_area_id uuid;
BEGIN
  IF target_release_id IS NULL OR parent_area_key IS NULL
     OR child_area_key IS NULL OR relation_type IS NULL THEN
    RAISE EXCEPTION 'release, parent area key, child area key, and relation type are required'
      USING ERRCODE = '22004';
  END IF;

  IF relation_type NOT IN ('contains', 'mostly_contains', 'overlaps') THEN
    RAISE EXCEPTION 'unknown relation type %', relation_type USING ERRCODE = '22023';
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  SELECT id INTO STRICT target_parent_area_id
    FROM $SCHEMA$.area WHERE area_key = parent_area_key;

  SELECT id INTO STRICT target_child_area_id
    FROM $SCHEMA$.area WHERE area_key = child_area_key;

  IF NOT EXISTS (
    SELECT 1 FROM $SCHEMA$.release_area
     WHERE release_id = target_release_id AND area_id = target_parent_area_id
  ) THEN
    RAISE EXCEPTION 'area % is not a member of release %', parent_area_key, target_release_id
      USING ERRCODE = '23503';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM $SCHEMA$.release_area
     WHERE release_id = target_release_id AND area_id = target_child_area_id
  ) THEN
    RAISE EXCEPTION 'area % is not a member of release %', child_area_key, target_release_id
      USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.relation (
    release_id,
    parent_area_id,
    child_area_id,
    relation_type,
    intersection_area_m2,
    parent_coverage,
    child_coverage
  )
  VALUES (
    target_release_id,
    target_parent_area_id,
    target_child_area_id,
    relation_type,
    NULL,
    NULL,
    NULL
  )
  ON CONFLICT ON CONSTRAINT relation_pkey
  DO UPDATE SET
    relation_type = EXCLUDED.relation_type,
    intersection_area_m2 = EXCLUDED.intersection_area_m2,
    parent_coverage = EXCLUDED.parent_coverage,
    child_coverage = EXCLUDED.child_coverage;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.rebuild_relations(
  target_release_id uuid
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  inserted_count bigint;
BEGIN
  IF target_release_id IS NULL THEN
    RAISE EXCEPTION 'release id is required'
      USING ERRCODE = '22004';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM $SCHEMA$.release
     WHERE id = target_release_id
  ) THEN
    RAISE EXCEPTION
      'release % does not exist',
      target_release_id
      USING ERRCODE = '22023';
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.relation_lock_key(target_release_id)
  );

  -- Only measured relations are rebuilt from geometry. Relations asserted by
  -- put_relation carry no measurements and no geometry to re-derive them
  -- from, so clearing them here would silently destroy the only hierarchy a
  -- metadata-only release has.
  DELETE FROM $SCHEMA$.relation
   WHERE release_id = target_release_id
     AND intersection_area_m2 IS NOT NULL;

  WITH candidate_pairs AS MATERIALIZED (
    SELECT
      parent_boundary.release_id,
      parent_boundary.area_id AS parent_area_id,
      child_boundary.area_id AS child_area_id,
      parent_boundary.geom AS parent_geom,
      child_boundary.geom AS child_geom
    FROM $SCHEMA$.boundary parent_boundary
    JOIN $SCHEMA$.area parent_area
      ON parent_area.id = parent_boundary.area_id
    JOIN $SCHEMA$.area_type parent_area_type
      ON parent_area_type.id = parent_area.area_type_id
    JOIN $SCHEMA$.boundary child_boundary
      ON child_boundary.release_id = parent_boundary.release_id
     AND child_boundary.display_tier = 0
     AND child_boundary.area_id <> parent_boundary.area_id
     AND parent_boundary.geom && child_boundary.geom
     AND ST_Intersects(parent_boundary.geom, child_boundary.geom)
    JOIN $SCHEMA$.area child_area
      ON child_area.id = child_boundary.area_id
    JOIN $SCHEMA$.area_type child_area_type
      ON child_area_type.id = child_area.area_type_id
    -- Pairs run from lower type_rank to higher within one collection, so
    -- areas of equal rank are never paired: overlaps between same-type
    -- areas produce no stored relation here. Pairwise measurement within a
    -- type is quadratic and does not scale to large same-type collections;
    -- such an overlap remains discoverable on demand through areas_for_geometry.
    WHERE parent_boundary.release_id = target_release_id
      AND parent_boundary.display_tier = 0
      AND parent_area_type.collection_id = child_area_type.collection_id
      AND parent_area_type.rank < child_area_type.rank
  ),
  measured_pairs AS MATERIALIZED (
    SELECT
      release_id,
      parent_area_id,
      child_area_id,
      ST_Area(parent_geom::geography) AS parent_area,
      ST_Area(child_geom::geography) AS child_area,
      ST_Area(ST_Intersection(parent_geom, child_geom)::geography) AS intersection_area
    FROM candidate_pairs
  ),
  classified_pairs AS (
    SELECT
      release_id,
      parent_area_id,
      child_area_id,
      intersection_area,
      LEAST(
        1::double precision,
        GREATEST(
          0::double precision,
          intersection_area / parent_area
        )
      )::numeric AS parent_coverage,
      LEAST(
        1::double precision,
        GREATEST(
          0::double precision,
          intersection_area / child_area
        )
      )::numeric AS child_coverage
    FROM measured_pairs
    WHERE intersection_area > 0
      AND parent_area > 0
      AND child_area > 0
  )
  INSERT INTO $SCHEMA$.relation (
    release_id,
    parent_area_id,
    child_area_id,
    relation_type,
    intersection_area_m2,
    parent_coverage,
    child_coverage
  )
  SELECT
    release_id,
    parent_area_id,
    child_area_id,
    $SCHEMA$.classify_relation(
      intersection_area::numeric,
      child_coverage
    ),
    intersection_area::numeric,
    parent_coverage,
    child_coverage
  FROM classified_pairs
  ON CONFLICT ON CONSTRAINT relation_pkey
  DO UPDATE SET
    relation_type = EXCLUDED.relation_type,
    intersection_area_m2 = EXCLUDED.intersection_area_m2,
    parent_coverage = EXCLUDED.parent_coverage,
    child_coverage = EXCLUDED.child_coverage;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
END;
$fn$;

--SPLIT--

-- Publication lifecycle functions

CREATE FUNCTION $SCHEMA$.verify_release(target_release_id uuid)
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

  -- A relation's parent and child need only be release members, not
  -- geometried, so an asserted relation between two metadata-only areas is
  -- not orphaned.
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

  -- The write API refuses a cross-collection member, but the tables are
  -- reachable directly and no foreign key can express the rule, so the
  -- publication gate re-checks it rather than trusting the writer.
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

CREATE FUNCTION $SCHEMA$.publish_release(target_release_id uuid)
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

--SPLIT--

CREATE FUNCTION $SCHEMA$.rollback_publication(collection_key text)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_collection_id uuid;
  current_release_id uuid;
  previous uuid;
BEGIN
  IF collection_key IS NULL THEN
    RAISE EXCEPTION 'collection key is required' USING ERRCODE = '22004';
  END IF;

  SELECT id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  -- An unrecognized collection and a collection with nothing to roll back to
  -- both leave the caller in the same position: NULL, not an error, since a
  -- caller polling "did the rollback happen" cannot tell the two apart from
  -- the collection key alone.
  IF target_collection_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM pg_advisory_xact_lock($SCHEMA$.publication_lock_key(target_collection_id));

  SELECT release_id, previous_release_id INTO current_release_id, previous
    FROM $SCHEMA$.publication WHERE collection_id = target_collection_id;

  IF NOT FOUND OR previous IS NULL THEN
    RAISE EXCEPTION 'collection % has no previous release to roll back to', collection_key
      USING ERRCODE = '23514';
  END IF;

  UPDATE $SCHEMA$.publication
     SET release_id = previous,
         previous_release_id = current_release_id,
         published_at = now()
   WHERE collection_id = target_collection_id;

  INSERT INTO $SCHEMA$.publication_event
    (collection_id, release_id, previous_release_id, kind)
  VALUES (target_collection_id, previous, current_release_id, 'rolled_back');

  RETURN target_collection_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.retire_releases(collection_key text, keep integer)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_collection_id uuid;
  published_release_id uuid;
  retire_id uuid;
  retired_count integer := 0;
BEGIN
  IF collection_key IS NULL OR keep IS NULL THEN
    RAISE EXCEPTION 'collection key and keep are required' USING ERRCODE = '22004';
  END IF;

  IF keep < 1 THEN
    RAISE EXCEPTION 'keep must be at least 1' USING ERRCODE = '22023';
  END IF;

  SELECT id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  -- retire_releases reports how many releases it retired, so an unknown
  -- collection has no NULL to distinguish "found nothing to retire" from
  -- "the collection does not exist" the way a nullable uuid result would;
  -- it raises instead, matching upsert_source and the rest of the write API.
  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'collection % does not exist', collection_key USING ERRCODE = '23503';
  END IF;

  PERFORM pg_advisory_xact_lock($SCHEMA$.publication_lock_key(target_collection_id));

  SELECT release_id INTO published_release_id
    FROM $SCHEMA$.publication WHERE collection_id = target_collection_id;

  -- Retention reclaims the bulk data by dropping the release's partitions
  -- and marks the release retired. The release row itself stays:
  -- publication_event and import_run reference it, and deleting it would
  -- cascade both away -- tearing holes in the monotonic event sequence hosts
  -- poll and erasing import history the catalog promises to keep.
  FOR retire_id IN
    SELECT r.id
      FROM $SCHEMA$.release r
     WHERE r.collection_id = target_collection_id
       AND r.status = 'completed'
       AND r.retired_at IS NULL
       AND r.id IS DISTINCT FROM published_release_id
     ORDER BY r.completed_at DESC, r.id DESC
     OFFSET (keep - 1)
  LOOP
    PERFORM $SCHEMA$.drop_release_partitions(retire_id);

    UPDATE $SCHEMA$.release
       SET retired_at = now()
     WHERE id = retire_id;

    retired_count := retired_count + 1;
  END LOOP;

  -- A retired release still exists as a row but holds no data, so leaving the
  -- rollback pointer aimed at one would let rollback_publication succeed and
  -- serve an empty catalog. Clearing it makes the next rollback fail loudly
  -- instead: keep asked for this release to go, and rollback has nowhere left
  -- to go with it gone.
  UPDATE $SCHEMA$.publication
     SET previous_release_id = NULL
   WHERE collection_id = target_collection_id
     AND previous_release_id IN (
       SELECT id FROM $SCHEMA$.release WHERE retired_at IS NOT NULL
     );

  RETURN retired_count;
END;
$fn$;

--SPLIT--

-- The durable import run state machine

CREATE TABLE $SCHEMA$.import_run (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  release_id uuid NOT NULL
    REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  attempt integer NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'pending',
  owner text NOT NULL,
  runner_backend text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  heartbeat_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  error jsonb,
  stage_metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT import_run_attempt_key
    UNIQUE (release_id, attempt),
  CONSTRAINT import_run_attempt_positive_check
    CHECK (attempt > 0),
  CONSTRAINT import_run_status_check
    CHECK (status IN (
      'pending',
      'downloading',
      'validating',
      'staging',
      'normalizing',
      'relating',
      'indexing',
      'verifying',
      'publishing',
      'completed',
      'failed'
    ))
);

--SPLIT--

CREATE UNIQUE INDEX import_run_active_release_idx
  ON $SCHEMA$.import_run (release_id)
  WHERE status IN (
    'pending',
    'downloading',
    'validating',
    'staging',
    'normalizing',
    'relating',
    'indexing',
    'verifying',
    'publishing'
  );

--SPLIT--

CREATE TABLE $SCHEMA$.import_run_lease (
  run_id uuid PRIMARY KEY
    REFERENCES $SCHEMA$.import_run(id) ON DELETE CASCADE,
  release_id uuid NOT NULL
    REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  heartbeat_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  progress jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT import_run_lease_release_key
    UNIQUE (release_id),
  CONSTRAINT import_run_lease_progress_object
    CHECK (jsonb_typeof(progress) = 'object')
);

--SPLIT--

CREATE FUNCTION $SCHEMA$.begin_or_resume_import(
  target_release_id uuid,
  owner text,
  runner_backend text,
  stale_after interval DEFAULT interval '15 minutes'
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  live record;
  live_heartbeat_at timestamptz;
  next_attempt integer;
  result_id uuid;
BEGIN
  IF target_release_id IS NULL OR owner IS NULL OR runner_backend IS NULL THEN
    RAISE EXCEPTION 'release id, owner, and runner backend are required'
      USING ERRCODE = '22004';
  END IF;

  -- A negative window makes every lease retroactively stale, so the next
  -- caller steals a claim that is seconds old and two workers process the
  -- same release.
  IF stale_after IS NULL OR stale_after < interval '0' THEN
    RAISE EXCEPTION 'stale_after must be a non-negative interval' USING ERRCODE = '22023';
  END IF;

  -- Serializes claim attempts for this release across concurrent callers, so
  -- that racing workers see each other's claim rather than each observing no
  -- live run and both inserting a fresh attempt. Held for the transaction,
  -- not the session, so it releases automatically at commit or rollback.
  PERFORM pg_advisory_xact_lock(
    ('x' || substr(md5('$SCHEMA$.import_claim:' || target_release_id::text), 1, 16))::bit(64)::bigint
  );

  SELECT run.id, run.owner
    INTO live
    FROM $SCHEMA$.import_run run
   WHERE run.release_id = target_release_id
     AND run.status NOT IN ('completed', 'failed')
     FOR UPDATE;

  IF FOUND THEN
    -- The heartbeat lives on the lease, not the run, so reading it through a
    -- join off the locked run row can return a snapshot taken before an
    -- in-flight heartbeat commits. Locking the lease itself makes this wait
    -- for that commit and then re-read, so a live worker cannot be judged
    -- stale and have its lease deleted out from under it.
    SELECT lease.heartbeat_at INTO live_heartbeat_at
      FROM $SCHEMA$.import_run_lease lease
     WHERE lease.run_id = live.id
       FOR UPDATE;

    IF NOT FOUND THEN
      -- An active run with no lease cannot be heartbeating, so it is dead
      -- regardless of age.
      live_heartbeat_at := '-infinity'::timestamptz;
    END IF;

    IF live.owner = owner AND live_heartbeat_at > clock_timestamp() - stale_after THEN
      UPDATE $SCHEMA$.import_run_lease
         SET heartbeat_at = clock_timestamp()
       WHERE run_id = live.id;

      RETURN live.id;
    END IF;

    IF live_heartbeat_at > clock_timestamp() - stale_after THEN
      RAISE EXCEPTION
        'release % already has a live import claimed by %', target_release_id, live.owner
        USING ERRCODE = '55006';
    END IF;

    UPDATE $SCHEMA$.import_run
       SET status = 'failed',
           completed_at = now(),
           error = jsonb_build_object('reason', 'lease expired')
     WHERE id = live.id;

    DELETE FROM $SCHEMA$.import_run_lease WHERE run_id = live.id;
  END IF;

  SELECT coalesce(max(attempt), 0) + 1 INTO next_attempt
    FROM $SCHEMA$.import_run WHERE release_id = target_release_id;

  INSERT INTO $SCHEMA$.import_run (release_id, attempt, owner, runner_backend)
  VALUES (target_release_id, next_attempt, owner, runner_backend)
  RETURNING id INTO result_id;

  INSERT INTO $SCHEMA$.import_run_lease (run_id, release_id)
  VALUES (result_id, target_release_id);

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.heartbeat_import(target_run_id uuid, progress_patch jsonb)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF target_run_id IS NULL THEN
    RAISE EXCEPTION 'run id is required' USING ERRCODE = '22004';
  END IF;

  UPDATE $SCHEMA$.import_run_lease
     SET heartbeat_at = clock_timestamp(),
         progress = progress || coalesce(progress_patch, '{}'::jsonb)
   WHERE run_id = target_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % has no active lease', target_run_id
      USING ERRCODE = '23503';
  END IF;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.advance_import(target_run_id uuid, next_status text, metrics_patch jsonb)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  current_status text;
BEGIN
  IF target_run_id IS NULL OR next_status IS NULL THEN
    RAISE EXCEPTION 'run id and next status are required' USING ERRCODE = '22004';
  END IF;

  IF next_status NOT IN (
    'pending',
    'downloading',
    'validating',
    'staging',
    'normalizing',
    'relating',
    'indexing',
    'verifying',
    'publishing',
    'completed',
    'failed'
  ) THEN
    RAISE EXCEPTION 'unknown import phase %', next_status USING ERRCODE = '22023';
  END IF;

  -- completed and failed are terminal. Advancing out of one resurrects a run
  -- that has already released its lease, leaving an active run nothing is
  -- heartbeating -- which then blocks the next claim on the partial unique
  -- index rather than being reclaimed as stale.
  -- No early exit for a run that does not exist: current_status stays NULL,
  -- the terminal guard below is NULL and falls through, and the UPDATE's own
  -- NOT FOUND raises the 23503. A second check here would only skip a
  -- zero-row UPDATE.
  SELECT status INTO current_status
    FROM $SCHEMA$.import_run WHERE id = target_run_id;

  IF current_status IN ('completed', 'failed') AND next_status <> current_status THEN
    RAISE EXCEPTION
      'import run % is % and cannot advance to %', target_run_id, current_status, next_status
      USING
        ERRCODE = '55000',
        HINT = 'Start a new attempt with begin_or_resume_import instead.';
  END IF;

  UPDATE $SCHEMA$.import_run
     SET status = next_status,
         stage_metrics = stage_metrics || coalesce(metrics_patch, '{}'::jsonb),
         completed_at = CASE
           WHEN next_status IN ('completed', 'failed') THEN now()
           ELSE completed_at
         END
   WHERE id = target_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id USING ERRCODE = '23503';
  END IF;

  IF next_status IN ('completed', 'failed') THEN
    DELETE FROM $SCHEMA$.import_run_lease WHERE run_id = target_run_id;
  ELSE
    UPDATE $SCHEMA$.import_run_lease
       SET heartbeat_at = clock_timestamp()
     WHERE run_id = target_run_id;
  END IF;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.fail_import(target_run_id uuid, error_detail jsonb)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF target_run_id IS NULL THEN
    RAISE EXCEPTION 'run id is required' USING ERRCODE = '22004';
  END IF;

  UPDATE $SCHEMA$.import_run
     SET status = 'failed',
         completed_at = now(),
         error = error_detail
   WHERE id = target_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id USING ERRCODE = '23503';
  END IF;

  DELETE FROM $SCHEMA$.import_run_lease WHERE run_id = target_run_id;
END;
$fn$;

--SPLIT--

-- A staging table per run, inside the installed schema, named from the run's
-- uuid. Deriving the name means it is [0-9a-f_]+ by construction rather than
-- by validation, so no caller-supplied text ever reaches an identifier.
CREATE FUNCTION $SCHEMA$.staging_table_name(target_run_id uuid)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF target_run_id IS NULL THEN
    RAISE EXCEPTION 'run id is required' USING ERRCODE = '22004';
  END IF;

  RETURN 'staging_' || replace(target_run_id::text, '-', '');
END;
$fn$;

--SPLIT--

-- UNLOGGED because staging content is rebuilt from a checksummed artifact
-- after any restart, and skipping WAL is the reason staging is its own phase.
CREATE FUNCTION $SCHEMA$.create_staging(target_run_id uuid)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  table_name text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM $SCHEMA$.import_run WHERE id = target_run_id) THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id USING ERRCODE = '23503';
  END IF;

  table_name := $SCHEMA$.staging_table_name(target_run_id);

  EXECUTE format(
    'CREATE UNLOGGED TABLE IF NOT EXISTS $SCHEMA$.%I (
       id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
       artifact text NOT NULL,
       payload jsonb NOT NULL,
       geom geometry(Geometry, 4326)
     )',
    table_name
  );

  RETURN table_name;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.drop_staging(target_run_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  EXECUTE format(
    'DROP TABLE IF EXISTS $SCHEMA$.%I',
    $SCHEMA$.staging_table_name(target_run_id)
  );
END;
$fn$;

--SPLIT--

-- The planner has no statistics for a partition that was empty when the run
-- began and holds every area by the time relations are measured, so the
-- indexing phase asks for them explicitly.
CREATE FUNCTION $SCHEMA$.analyze_release(target_release_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  suffix text;
  parent text;
  partition_name text;
BEGIN
  IF target_release_id IS NULL THEN
    RAISE EXCEPTION 'release id is required' USING ERRCODE = '22004';
  END IF;

  suffix := replace(target_release_id::text, '-', '');

  FOREACH parent IN ARRAY ARRAY['boundary', 'boundary_part', 'relation', 'release_area'] LOOP
    partition_name := parent || '_' || suffix;

    IF to_regclass(format('$SCHEMA$.%I', partition_name)) IS NOT NULL THEN
      EXECUTE format('ANALYZE $SCHEMA$.%I', partition_name);
    END IF;
  END LOOP;
END;
$fn$;

--SPLIT--

-- Resolves a collection's currently published release, the pointer every
-- published_* view and read-side function joins through.
CREATE FUNCTION $SCHEMA$.published_release(collection_key text)
RETURNS uuid
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  result_id uuid;
BEGIN
  IF collection_key IS NULL THEN
    RAISE EXCEPTION 'collection key is required' USING ERRCODE = '22004';
  END IF;

  SELECT publication.release_id INTO result_id
    FROM $SCHEMA$.publication
    JOIN $SCHEMA$.collection ON collection.id = publication.collection_id
   WHERE collection.key = collection_key;

  -- A collection the catalog does not carry and a collection that has
  -- published nothing are the same answer to a caller: there is no release to
  -- read, so both return NULL rather than one of them raising.
  RETURN result_id;
END;
$fn$;

--SPLIT--

-- One row per import run, carrying the keys a caller knows a run by and the
-- lease progress a caller polls. Reading a run means reading this view, so no
-- caller assembles the four-way join itself.
CREATE VIEW $SCHEMA$.import_run_status AS
SELECT
  import_run.id AS run_id,
  import_run.release_id,
  collection.key AS collection_key,
  release.release_key,
  import_run.attempt,
  import_run.status,
  import_run.owner,
  import_run.runner_backend,
  import_run.started_at,
  coalesce(import_run_lease.heartbeat_at, import_run.heartbeat_at) AS heartbeat_at,
  import_run.completed_at,
  import_run.error,
  import_run.stage_metrics,
  coalesce(import_run_lease.progress, '{}'::jsonb) AS progress
FROM $SCHEMA$.import_run
JOIN $SCHEMA$.release ON release.id = import_run.release_id
JOIN $SCHEMA$.collection ON collection.id = release.collection_id
LEFT JOIN $SCHEMA$.import_run_lease ON import_run_lease.run_id = import_run.id;

--SPLIT--

-- The pipeline's download phase needs every artifact a release composes,
-- together with the source release each one is attributed to, so this view
-- assembles that three-way join once rather than leaving it to the call site.
CREATE VIEW $SCHEMA$.release_artifacts AS
SELECT
  release_source.release_id,
  source_release.id AS source_release_id,
  source.source_key,
  source_release.release_key AS source_release_key,
  collection.key AS collection_key,
  artifact.id AS artifact_id,
  artifact.logical_name,
  artifact.url,
  artifact.operator_supplied,
  artifact.format,
  artifact.expected_sha256,
  artifact.expected_bytes,
  artifact.observed_sha256,
  artifact.observed_bytes,
  artifact.validated_at,
  artifact.metadata
FROM $SCHEMA$.release_source
JOIN $SCHEMA$.source_release ON source_release.id = release_source.source_release_id
JOIN $SCHEMA$.source ON source.id = source_release.source_id
JOIN $SCHEMA$.collection ON collection.id = source.collection_id
JOIN $SCHEMA$.artifact ON artifact.source_release_id = source_release.id;

--SPLIT--

-- Published read views. Every view resolves through publication,
-- so no view takes a release argument and a pointer swap changes what all
-- of them show at once, under MVCC, with no refresh step.

-- release_areas is release-scoped (no publication join): one row per
-- (release, area) membership recorded in release_area, published or not,
-- whether or not the area has a boundary -- geometry is an optional
-- attachment, not a condition of membership.
-- published_areas narrows it to the currently published release per
-- collection; the resolution functions below query release_areas
-- directly so a non-null target_release_id can reach a release that is not
-- (or not yet, or no longer) the published one.
-- The surface hosts join, and the base every published_* view builds on. It
-- reads only columns: the official name is denormalized onto area and kept
-- current by a trigger, because resolving it here per row costs an index probe
-- for every row of every scan a host runs.
CREATE VIEW $SCHEMA$.release_areas AS
SELECT
  collection.key AS collection_key,
  release_area.release_id,
  area.id AS area_id,
  area.area_key,
  authority.key AS authority,
  area_type.key AS area_type,
  area_type.rank AS type_rank,
  area.official_name AS name,
  release_area.centroid,
  coalesce(release_area.data, '{}'::jsonb) AS attributes,
  area.retired_at
FROM $SCHEMA$.release_area
JOIN $SCHEMA$.area ON area.id = release_area.area_id
JOIN $SCHEMA$.release ON release.id = release_area.release_id
JOIN $SCHEMA$.collection ON collection.id = release.collection_id
JOIN $SCHEMA$.authority ON authority.id = area.authority_id
JOIN $SCHEMA$.area_type ON area_type.id = area.area_type_id;

--SPLIT--

CREATE VIEW $SCHEMA$.published_areas AS
SELECT
  release_areas.collection_key,
  release_areas.release_id,
  release_areas.area_id,
  release_areas.area_key,
  release_areas.authority,
  release_areas.area_type,
  release_areas.type_rank,
  release_areas.name,
  release_areas.centroid,
  release_areas.attributes,
  release_areas.retired_at
FROM $SCHEMA$.release_areas
JOIN $SCHEMA$.publication ON publication.release_id = release_areas.release_id;

--SPLIT--

CREATE VIEW $SCHEMA$.published_area_codes AS
SELECT
  published_areas.collection_key,
  published_areas.area_key,
  published_areas.area_id,
  area_code.code_type,
  area_code.code_value
FROM $SCHEMA$.published_areas
JOIN $SCHEMA$.area_code ON area_code.area_id = published_areas.area_id;

--SPLIT--

CREATE VIEW $SCHEMA$.published_area_names AS
SELECT
  published_areas.collection_key,
  published_areas.area_key,
  published_areas.area_id,
  area_name.name,
  area_name.kind,
  area_name.locale
FROM $SCHEMA$.published_areas
JOIN $SCHEMA$.area_name ON area_name.area_id = published_areas.area_id;

--SPLIT--

CREATE VIEW $SCHEMA$.published_area_relations AS
SELECT
  collection.key AS collection_key,
  publication.release_id,
  relation.parent_area_id,
  parent_area.area_key AS parent_area_key,
  relation.child_area_id,
  child_area.area_key AS child_area_key,
  relation.relation_type,
  relation.intersection_area_m2,
  relation.parent_coverage,
  relation.child_coverage
FROM $SCHEMA$.publication
JOIN $SCHEMA$.collection ON collection.id = publication.collection_id
JOIN $SCHEMA$.relation ON relation.release_id = publication.release_id
JOIN $SCHEMA$.area parent_area ON parent_area.id = relation.parent_area_id
JOIN $SCHEMA$.area child_area ON child_area.id = relation.child_area_id;

--SPLIT--

CREATE VIEW $SCHEMA$.published_boundaries AS
SELECT
  collection.key AS collection_key,
  publication.release_id,
  boundary.area_id,
  area.area_key,
  boundary.display_tier,
  boundary.geom,
  boundary.display_geom,
  boundary.valid_from,
  boundary.valid_to,
  boundary.source_properties
FROM $SCHEMA$.publication
JOIN $SCHEMA$.collection ON collection.id = publication.collection_id
JOIN $SCHEMA$.boundary ON boundary.release_id = publication.release_id
JOIN $SCHEMA$.area ON area.id = boundary.area_id;

--SPLIT--

-- The area_match type and spatial resolution functions

CREATE TYPE $SCHEMA$.area_match AS (
  collection_key text,
  release_id uuid,
  area_key text,
  authority text,
  area_type text,
  type_rank integer,
  name text,
  codes jsonb,
  centroid geography(Point, 4326),
  attributes jsonb,
  match_method text,
  distance_m numeric,
  intersection_area_m2 numeric,
  coverage_of_input numeric,
  coverage_of_area numeric,
  score numeric
);

--SPLIT--

CREATE FUNCTION $SCHEMA$.areas_for_point(
  lon double precision,
  lat double precision,
  collections text[] DEFAULT NULL,
  types text[] DEFAULT NULL,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  probe geometry;
BEGIN
  IF lon IS NULL OR lat IS NULL THEN
    RAISE EXCEPTION 'longitude and latitude are required' USING ERRCODE = '22004';
  END IF;

  IF lon < -180 OR lon > 180 OR lat < -90 OR lat > 90 THEN
    RAISE EXCEPTION 'longitude and latitude are out of range' USING ERRCODE = '22023';
  END IF;

  probe := ST_SetSRID(ST_MakePoint(lon, lat), 4326);

  -- Every read function scopes to a release with the same predicate: an
  -- explicit target_release_id, or else any release a publication points at.
  -- The EXISTS reads as a per-row probe but does not plan as one -- Postgres
  -- turns it into a hashed SubPlan evaluated once per query (verified at 100k
  -- release areas: loops=1 on a full scan), so publication is read a single
  -- time no matter how many candidate rows the predicate filters.
  RETURN QUERY
  SELECT DISTINCT ON (area.area_key)
    area.collection_key,
    area.release_id,
    area.area_key,
    area.authority,
    area.area_type,
    area.type_rank,
    area.name,
    codes.codes,
    area.centroid,
    area.attributes,
    'containment'::text,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric
  FROM $SCHEMA$.release_areas area
  JOIN $SCHEMA$.boundary_part part
    ON part.release_id = area.release_id AND part.area_id = area.area_id
  LEFT JOIN LATERAL (
    SELECT $SCHEMA$.area_codes_json(area.area_id) AS codes
  ) codes ON true
  WHERE (collections IS NULL OR area.collection_key = ANY(collections))
    AND (types IS NULL OR area.area_type = ANY(types))
    AND (
      (target_release_id IS NOT NULL AND area.release_id = target_release_id)
      OR (target_release_id IS NULL AND EXISTS (
            SELECT 1 FROM $SCHEMA$.publication p
             WHERE p.release_id = area.release_id
          ))
    )
    AND (include_retired OR area.retired_at IS NULL)
    AND part.geom && probe
    AND ST_Covers(part.geom, probe)
  ORDER BY area.area_key, area.type_rank;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.areas_for_geometry(
  input_geom geometry,
  collections text[] DEFAULT NULL,
  types text[] DEFAULT NULL,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF input_geom IS NULL THEN
    RAISE EXCEPTION 'geometry is required' USING ERRCODE = '22004';
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

  RETURN QUERY
  WITH intersections AS (
    SELECT
      area.collection_key,
      area.release_id,
      area.area_id,
      area.area_key,
      area.authority,
      area.area_type,
      area.type_rank,
      area.name,
      area.centroid,
      area.attributes,
      boundary.geom AS area_geom,
      ST_Area(ST_Intersection(boundary.geom, input_geom)::geography)::numeric
        AS intersection_area_m2
    FROM $SCHEMA$.release_areas area
    JOIN $SCHEMA$.boundary
      ON boundary.release_id = area.release_id
     AND boundary.area_id = area.area_id
     AND boundary.display_tier = 0
    WHERE (collections IS NULL OR area.collection_key = ANY(collections))
      AND (types IS NULL OR area.area_type = ANY(types))
      AND (
        (target_release_id IS NOT NULL AND area.release_id = target_release_id)
        OR (target_release_id IS NULL AND EXISTS (
              SELECT 1 FROM $SCHEMA$.publication p
               WHERE p.release_id = area.release_id
            ))
      )
      AND (include_retired OR area.retired_at IS NULL)
      AND boundary.geom && input_geom
      AND ST_Intersects(boundary.geom, input_geom)
  )
  SELECT
    intersections.collection_key,
    intersections.release_id,
    intersections.area_key,
    intersections.authority,
    intersections.area_type,
    intersections.type_rank,
    intersections.name,
    codes.codes,
    intersections.centroid,
    intersections.attributes,
    'overlap'::text,
    NULL::numeric,
    intersections.intersection_area_m2,
    LEAST(100::numeric, GREATEST(0::numeric,
      100::numeric * intersections.intersection_area_m2
        / ST_Area(input_geom::geography)::numeric))
      AS coverage_of_input,
    LEAST(100::numeric, GREATEST(0::numeric,
      100::numeric * intersections.intersection_area_m2
        / ST_Area(intersections.area_geom::geography)::numeric))
      AS coverage_of_area,
    NULL::numeric
  FROM intersections
  LEFT JOIN LATERAL (
    SELECT $SCHEMA$.area_codes_json(intersections.area_id) AS codes
  ) codes ON true
  WHERE intersections.intersection_area_m2 > 0;
END;
$fn$;

--SPLIT--

-- Proximity, code lookup, and ranked name search. All three query
-- release_areas directly (not published_areas) so a non-null
-- target_release_id can reach a release that is not the currently
-- published one, matching areas_for_point and areas_for_geometry.

CREATE FUNCTION $SCHEMA$.areas_near(
  lon double precision,
  lat double precision,
  radius_m double precision,
  collections text[] DEFAULT NULL,
  types text[] DEFAULT NULL,
  result_limit integer DEFAULT 50,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  probe geography;
BEGIN
  IF lon IS NULL OR lat IS NULL OR radius_m IS NULL THEN
    RAISE EXCEPTION 'longitude, latitude, and radius are required' USING ERRCODE = '22004';
  END IF;

  IF lon < -180 OR lon > 180 OR lat < -90 OR lat > 90 THEN
    RAISE EXCEPTION 'longitude and latitude are out of range' USING ERRCODE = '22023';
  END IF;

  IF radius_m <= 0 THEN
    RAISE EXCEPTION 'radius must be positive' USING ERRCODE = '22023';
  END IF;

  probe := ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography;

  -- Areas without a polygon (metadata-only collections) still have a
  -- release_area centroid, so proximity measures against the boundary
  -- when one exists and falls back to the centroid otherwise.
  RETURN QUERY
  SELECT
    area.collection_key,
    area.release_id,
    area.area_key,
    area.authority,
    area.area_type,
    area.type_rank,
    area.name,
    codes.codes,
    area.centroid,
    area.attributes,
    'proximity'::text,
    (CASE WHEN boundary.geom IS NOT NULL
       THEN ST_Distance(boundary.geom::geography, probe)
       ELSE ST_Distance(area.centroid, probe)
     END)::numeric,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric
  FROM $SCHEMA$.release_areas area
  LEFT JOIN $SCHEMA$.boundary
    ON boundary.release_id = area.release_id
   AND boundary.area_id = area.area_id
   AND boundary.display_tier = 0
  LEFT JOIN LATERAL (
    SELECT $SCHEMA$.area_codes_json(area.area_id) AS codes
  ) codes ON true
  WHERE (collections IS NULL OR area.collection_key = ANY(collections))
    AND (types IS NULL OR area.area_type = ANY(types))
    AND (
      (target_release_id IS NOT NULL AND area.release_id = target_release_id)
      OR (target_release_id IS NULL AND EXISTS (
            SELECT 1 FROM $SCHEMA$.publication p
             WHERE p.release_id = area.release_id
          ))
    )
    AND (include_retired OR area.retired_at IS NULL)
    AND (
      (boundary.geom IS NOT NULL AND ST_DWithin(boundary.geom::geography, probe, radius_m))
      OR (boundary.geom IS NULL AND area.centroid IS NOT NULL
          AND ST_DWithin(area.centroid, probe, radius_m))
    )
  ORDER BY
    CASE WHEN boundary.geom IS NOT NULL
      THEN ST_Distance(boundary.geom::geography, probe)
      ELSE ST_Distance(area.centroid, probe)
    END
  LIMIT coalesce(result_limit, 50);
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.areas_by_code(
  target_code_type text,
  target_code_value text,
  collections text[] DEFAULT NULL,
  types text[] DEFAULT NULL,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false,
  parent_area_key text DEFAULT NULL,
  parent_max_depth integer DEFAULT 1
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF target_code_type IS NULL OR target_code_value IS NULL THEN
    RAISE EXCEPTION 'code type and code value are required' USING ERRCODE = '22004';
  END IF;

  -- area_code and area_name hang off area, not off any release, so joining
  -- them to release_areas (already scoped to the resolved release) is
  -- sufficient; no boundary or geometry is involved in a code lookup.
  RETURN QUERY
  SELECT
    area.collection_key,
    area.release_id,
    area.area_key,
    area.authority,
    area.area_type,
    area.type_rank,
    area.name,
    codes.codes,
    area.centroid,
    area.attributes,
    'code'::text,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric
  FROM $SCHEMA$.release_areas area
  JOIN $SCHEMA$.area_code ac
    ON ac.area_id = area.area_id
   AND ac.code_type = target_code_type
   AND ac.code_value = target_code_value
  LEFT JOIN LATERAL (
    SELECT $SCHEMA$.area_codes_json(area.area_id) AS codes
  ) codes ON true
  WHERE (collections IS NULL OR area.collection_key = ANY(collections))
    AND (types IS NULL OR area.area_type = ANY(types))
    AND (
      (target_release_id IS NOT NULL AND area.release_id = target_release_id)
      OR (target_release_id IS NULL AND EXISTS (
            SELECT 1 FROM $SCHEMA$.publication p
             WHERE p.release_id = area.release_id
          ))
    )
    AND (include_retired OR area.retired_at IS NULL)
    -- Scoping to a parent intersects the code matches with that parent's
    -- descendants rather than reimplementing traversal here. A code such as a
    -- slug is unique only within a parent: twenty-three areas can share
    -- 'washington', and only the state tells them apart.
    AND (
      parent_area_key IS NULL
      OR area.area_key IN (
        SELECT child.area_key
          FROM $SCHEMA$.children_of(
                 parent_area_key, types, NULL, parent_max_depth,
                 target_release_id, include_retired) child
      )
    );
END;
$fn$;

--SPLIT--



CREATE FUNCTION $SCHEMA$.search_areas(
  query text,
  collections text[] DEFAULT NULL,
  types text[] DEFAULT NULL,
  result_limit integer DEFAULT 50,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF query IS NULL OR btrim(query) = '' THEN
    RAISE EXCEPTION 'query is required' USING ERRCODE = '22004';
  END IF;

  -- Cheap-first: rank by trigram similarity against area_name alone (no
  -- joins), collapse to the best-scoring name per area, apply every
  -- release/collection/type/retired filter against a lean join that skips
  -- release_areas' per-row cost (no boundary attachment, no correlated
  -- official-name lookup), THEN cut to result_limit -- and only pay for the
  -- official name lookup and area_code aggregation for the survivors.
  -- Filtering happens entirely before the cut, so LIMIT never drops an
  -- area that would otherwise have passed the filters. Ordering breaks
  -- ties on the winning matched name text carried through from area_name
  -- (free -- already read off the trigram-indexed row, equal to the
  -- official name whenever the winning match came from the area's
  -- official-kind row, the common case) and then on area_key, which is
  -- always unique and always available for free from the filtering join
  -- -- so, unlike a bare (score, name) ordering, this ordering is always
  -- fully deterministic. One residual case remains (an alias outscoring its
  -- own area's official name at an exact-score, exact-name tie), where this
  -- can select a different member of an
  -- already-ambiguous tied group than the pre-restructure query did.
  RETURN QUERY
  WITH matches AS MATERIALIZED (
    SELECT
      area_name.area_id,
      area_name.name,
      similarity(area_name.name, query)::numeric AS score
    FROM $SCHEMA$.area_name
    WHERE area_name.name % query OR area_name.name ILIKE query || '%'
  ),
  best AS (
    SELECT DISTINCT ON (area_id)
      area_id,
      name AS matched_name,
      score
    FROM matches
    -- name breaks a score tie so one area's aliases cannot alternate as
    -- matched_name between runs, which would in turn perturb the outer
    -- (score, matched_name, area_key) ordering and the LIMIT that follows it.
    ORDER BY area_id, score DESC, name
  ),
  eligible AS (
    SELECT
      best.area_id,
      best.matched_name,
      best.score,
      collection.key AS collection_key,
      release_area.release_id,
      area.area_key,
      authority.key AS authority,
      area_type.key AS area_type,
      area_type.rank AS type_rank,
      area.official_name,
      release_area.centroid,
      coalesce(release_area.data, '{}'::jsonb) AS attributes
    FROM best
    JOIN $SCHEMA$.release_area ON release_area.area_id = best.area_id
    JOIN $SCHEMA$.area ON area.id = release_area.area_id
    JOIN $SCHEMA$.release ON release.id = release_area.release_id
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
    JOIN $SCHEMA$.authority ON authority.id = area.authority_id
    JOIN $SCHEMA$.area_type ON area_type.id = area.area_type_id
    WHERE (collections IS NULL OR collection.key = ANY(collections))
      AND (types IS NULL OR area_type.key = ANY(types))
      AND (
        (target_release_id IS NOT NULL AND release_area.release_id = target_release_id)
        OR (target_release_id IS NULL AND EXISTS (
              SELECT 1 FROM $SCHEMA$.publication p
               WHERE p.release_id = release_area.release_id
            ))
      )
      AND (include_retired OR area.retired_at IS NULL)
  ),
  top AS MATERIALIZED (
    SELECT *
    FROM eligible
    ORDER BY score DESC, matched_name, area_key
    LIMIT coalesce(result_limit, 50)
  )
  SELECT
    top.collection_key,
    top.release_id,
    top.area_key,
    top.authority,
    top.area_type,
    top.type_rank,
    top.official_name,
    codes.codes,
    top.centroid,
    top.attributes,
    'name'::text,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric,
    NULL::numeric,
    top.score
  FROM top
  LEFT JOIN LATERAL (
    SELECT $SCHEMA$.area_codes_json(top.area_id) AS codes
  ) codes ON true
  ORDER BY top.score DESC, top.matched_name, top.area_key;
END;
$fn$;

--SPLIT--

-- Hierarchy traversal. children_of, ancestors_of, and
-- related_areas walk relation directly (release-scoped, not
-- published_area_relations, which is hard-scoped to each collection's
-- currently published release and would make a non-null target_release_id
-- inert). They join release_areas for enrichment, so a reference
-- hierarchy with no boundaries at all -- relations asserted from source
-- data via put_relation, with intersection_area_m2/parent_coverage/
-- child_coverage left NULL -- traverses exactly like a measured one; none
-- of the three functions filters on those measurement columns.

CREATE FUNCTION $SCHEMA$.children_of(
  parent_area_key text,
  types text[] DEFAULT NULL,
  classifications text[] DEFAULT NULL,
  max_depth integer DEFAULT 1,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF parent_area_key IS NULL THEN
    RAISE EXCEPTION 'parent area key is required' USING ERRCODE = '22004';
  END IF;

  IF max_depth IS NULL OR max_depth < 1 THEN
    RAISE EXCEPTION 'max depth must be at least 1' USING ERRCODE = '22023';
  END IF;

  -- visited tracks every area id seen on this path (seed included) so a
  -- cyclic overlap graph (A overlaps B, B overlaps A) cannot walk back
  -- onto an area already on the path -- otherwise the origin area would
  -- reappear as its own descendant, and the walk would keep re-deriving
  -- the same pair every level instead of terminating on new ground.
  RETURN QUERY
  WITH RECURSIVE walk AS (
    SELECT
      relation.child_area_id AS area_id,
      relation.release_id AS release_id,
      1 AS depth,
      ARRAY[relation.parent_area_id, relation.child_area_id] AS visited
    FROM $SCHEMA$.relation relation
    JOIN $SCHEMA$.area parent_area ON parent_area.id = relation.parent_area_id
    WHERE parent_area.area_key = parent_area_key
      AND (classifications IS NULL OR relation.relation_type = ANY(classifications))
      AND (
        (target_release_id IS NOT NULL AND relation.release_id = target_release_id)
        OR (target_release_id IS NULL AND EXISTS (
              SELECT 1 FROM $SCHEMA$.publication p
               WHERE p.release_id = relation.release_id
            ))
      )

    UNION ALL

    SELECT
      relation.child_area_id,
      relation.release_id,
      walk.depth + 1,
      walk.visited || relation.child_area_id
    FROM walk
    JOIN $SCHEMA$.relation relation
      ON relation.parent_area_id = walk.area_id
     AND relation.release_id = walk.release_id
    WHERE walk.depth < max_depth
      AND NOT relation.child_area_id = ANY(walk.visited)
      AND (classifications IS NULL OR relation.relation_type = ANY(classifications))
  )
  SELECT DISTINCT ON (area.area_key)
    area.collection_key, area.release_id, area.area_key, area.authority,
    area.area_type, area.type_rank, area.name,
    $SCHEMA$.area_codes_json(area.area_id),
    area.centroid, area.attributes,
    'relation'::text,
    NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric
  FROM walk
  JOIN $SCHEMA$.release_areas area
    ON area.area_id = walk.area_id AND area.release_id = walk.release_id
  WHERE (types IS NULL OR area.area_type = ANY(types))
    AND (include_retired OR area.retired_at IS NULL)
  ORDER BY area.area_key, area.type_rank;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.ancestors_of(
  child_area_key text,
  types text[] DEFAULT NULL,
  classifications text[] DEFAULT NULL,
  max_depth integer DEFAULT 1,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF child_area_key IS NULL THEN
    RAISE EXCEPTION 'child area key is required' USING ERRCODE = '22004';
  END IF;

  IF max_depth IS NULL OR max_depth < 1 THEN
    RAISE EXCEPTION 'max depth must be at least 1' USING ERRCODE = '22023';
  END IF;

  -- children_of with parent and child exchanged in both the seed and the
  -- recursive branch -- same visited-set guard, walked upward instead of
  -- downward.
  RETURN QUERY
  WITH RECURSIVE walk AS (
    SELECT
      relation.parent_area_id AS area_id,
      relation.release_id AS release_id,
      1 AS depth,
      ARRAY[relation.child_area_id, relation.parent_area_id] AS visited
    FROM $SCHEMA$.relation relation
    JOIN $SCHEMA$.area child_area ON child_area.id = relation.child_area_id
    WHERE child_area.area_key = child_area_key
      AND (classifications IS NULL OR relation.relation_type = ANY(classifications))
      AND (
        (target_release_id IS NOT NULL AND relation.release_id = target_release_id)
        OR (target_release_id IS NULL AND EXISTS (
              SELECT 1 FROM $SCHEMA$.publication p
               WHERE p.release_id = relation.release_id
            ))
      )

    UNION ALL

    SELECT
      relation.parent_area_id,
      relation.release_id,
      walk.depth + 1,
      walk.visited || relation.parent_area_id
    FROM walk
    JOIN $SCHEMA$.relation relation
      ON relation.child_area_id = walk.area_id
     AND relation.release_id = walk.release_id
    WHERE walk.depth < max_depth
      AND NOT relation.parent_area_id = ANY(walk.visited)
      AND (classifications IS NULL OR relation.relation_type = ANY(classifications))
  )
  SELECT DISTINCT ON (area.area_key)
    area.collection_key, area.release_id, area.area_key, area.authority,
    area.area_type, area.type_rank, area.name,
    $SCHEMA$.area_codes_json(area.area_id),
    area.centroid, area.attributes,
    'relation'::text,
    NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric
  FROM walk
  JOIN $SCHEMA$.release_areas area
    ON area.area_id = walk.area_id AND area.release_id = walk.release_id
  WHERE (types IS NULL OR area.area_type = ANY(types))
    AND (include_retired OR area.retired_at IS NULL)
  ORDER BY area.area_key, area.type_rank;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.related_areas(
  target_area_key text,
  classifications text[] DEFAULT NULL,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF target_area_key IS NULL THEN
    RAISE EXCEPTION 'area key is required' USING ERRCODE = '22004';
  END IF;

  -- Non-recursive: an area's relations are whatever relation rows name it
  -- as parent or as child, unioned, filtered by classifications.
  RETURN QUERY
  WITH related AS (
    SELECT relation.child_area_id AS area_id, relation.release_id AS release_id
    FROM $SCHEMA$.relation relation
    JOIN $SCHEMA$.area parent_area ON parent_area.id = relation.parent_area_id
    WHERE parent_area.area_key = target_area_key
      AND (classifications IS NULL OR relation.relation_type = ANY(classifications))
      AND (
        (target_release_id IS NOT NULL AND relation.release_id = target_release_id)
        OR (target_release_id IS NULL AND EXISTS (
              SELECT 1 FROM $SCHEMA$.publication p
               WHERE p.release_id = relation.release_id
            ))
      )

    UNION

    SELECT relation.parent_area_id, relation.release_id
    FROM $SCHEMA$.relation relation
    JOIN $SCHEMA$.area child_area ON child_area.id = relation.child_area_id
    WHERE child_area.area_key = target_area_key
      AND (classifications IS NULL OR relation.relation_type = ANY(classifications))
      AND (
        (target_release_id IS NOT NULL AND relation.release_id = target_release_id)
        OR (target_release_id IS NULL AND EXISTS (
              SELECT 1 FROM $SCHEMA$.publication p
               WHERE p.release_id = relation.release_id
            ))
      )
  )
  SELECT DISTINCT ON (area.area_key)
    area.collection_key, area.release_id, area.area_key, area.authority,
    area.area_type, area.type_rank, area.name,
    $SCHEMA$.area_codes_json(area.area_id),
    area.centroid, area.attributes,
    'relation'::text,
    NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric
  FROM related
  JOIN $SCHEMA$.release_areas area
    ON area.area_id = related.area_id AND area.release_id = related.release_id
  WHERE (include_retired OR area.retired_at IS NULL)
  ORDER BY area.area_key, area.type_rank;
END;
$fn$;

--SPLIT--

-- The resolve cascade. Delegates every strategy to the function
-- that already implements it (areas_for_point, areas_by_code,
-- search_areas, areas_near) and never reimplements a strategy's query
-- inline. Each strategy's candidate rows are materialized once into a
-- local area_match[] via array_agg, then either returned (winning
-- strategy, loop stops) or discarded (empty, try the next strategy) --
-- one execution per attempted strategy, never two. A probe-then-rerun
-- shape (IF EXISTS (...) THEN RETURN QUERY SELECT ...) would run the
-- delegate's query twice for every winning strategy; materializing once
-- and returning from the array costs the same as the probe alone.
CREATE FUNCTION $SCHEMA$.resolve(
  input jsonb,
  collections text[] DEFAULT NULL,
  types text[] DEFAULT NULL,
  strategies text[] DEFAULT NULL,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  order_of_attempts text[] :=
    coalesce(strategies, ARRAY['containment', 'code', 'name', 'proximity']);
  strategy text;
  has_lon boolean := coalesce(input ? 'lon', false);
  has_lat boolean := coalesce(input ? 'lat', false);
  candidates $SCHEMA$.area_match[];
BEGIN
  IF input IS NULL OR jsonb_typeof(input) <> 'object' THEN
    RAISE EXCEPTION 'input must be a JSON object' USING ERRCODE = '22023';
  END IF;

  IF has_lon <> has_lat THEN
    RAISE EXCEPTION 'lon and lat must be supplied together' USING ERRCODE = '22023';
  END IF;

  FOREACH strategy IN ARRAY order_of_attempts LOOP
    candidates := NULL;

    -- A strategy whose required input is absent is skipped, not an
    -- error: candidates stays NULL and the loop moves to the next
    -- strategy.
    IF strategy = 'containment' AND has_lon THEN
      SELECT array_agg(match) INTO candidates
      FROM $SCHEMA$.areas_for_point(
        (input ->> 'lon')::double precision,
        (input ->> 'lat')::double precision,
        collections, types, target_release_id, include_retired) match;

    ELSIF strategy = 'code' AND input ? 'code_type' AND input ? 'code_value' THEN
      -- A code is unique only within a parent, so parent_area_key threads
      -- through to areas_by_code, which already intersects its matches with
      -- that parent's descendants. Its parent_max_depth stays at the default
      -- of one, the same reach the name strategy's scoping uses.
      SELECT array_agg(match) INTO candidates
      FROM $SCHEMA$.areas_by_code(
        input ->> 'code_type', input ->> 'code_value',
        collections, types, target_release_id, include_retired,
        input ->> 'parent_area_key') match;

    ELSIF strategy = 'name' AND input ? 'name' THEN
      -- Scoping to a parent area intersects the name matches with the
      -- parent's children rather than reimplementing name search with a
      -- parent filter baked in. include_retired threads to both sides of
      -- the intersection so the scoping does not silently apply a
      -- different retirement policy than the name search itself.
      IF input ? 'parent_area_key' THEN
        -- search_areas cuts to its own limit before this filter can run, so
        -- asking it for 25 would let 25 unrelated same-name areas crowd out
        -- the one child that survives scoping. It is asked for a wide
        -- candidate pool instead, and the cut to 25 happens after the
        -- intersection. A name shared by more than 500 areas
        -- can still push a child out; search_areas with an explicit type
        -- filter is the precise tool when that matters.
        SELECT array_agg(match) INTO candidates
        FROM (
          SELECT scoped.*
          FROM $SCHEMA$.search_areas(
            input ->> 'name', collections, types, 500, target_release_id, include_retired) scoped
          WHERE scoped.area_key IN (
            SELECT child.area_key FROM $SCHEMA$.children_of(
              input ->> 'parent_area_key', types, NULL, 1, target_release_id, include_retired) child
          )
          ORDER BY scoped.score DESC, scoped.area_key
          LIMIT 25
        ) match;
      ELSE
        SELECT array_agg(match) INTO candidates
        FROM $SCHEMA$.search_areas(
          input ->> 'name', collections, types, 25, target_release_id, include_retired) match;
      END IF;

    ELSIF strategy = 'proximity' AND has_lon THEN
      SELECT array_agg(match) INTO candidates
      FROM $SCHEMA$.areas_near(
        (input ->> 'lon')::double precision,
        (input ->> 'lat')::double precision,
        coalesce((input ->> 'radius_m')::double precision, 25000),
        collections, types, 25, target_release_id, include_retired) match;
    END IF;

    IF candidates IS NOT NULL AND array_length(candidates, 1) > 0 THEN
      RETURN QUERY SELECT * FROM unnest(candidates);
      RETURN;
    END IF;
  END LOOP;

  RETURN;
END;
$fn$;
