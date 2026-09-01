CREATE SCHEMA IF NOT EXISTS $SCHEMA$;

--SPLIT--

CREATE OR REPLACE VIEW $SCHEMA$.geo_genius_version AS SELECT 1 AS installed;

--SPLIT--

CREATE OR REPLACE VIEW $SCHEMA$.geo_genius_contract AS
SELECT
  1::integer AS schema_version,
  'sha256:b2a132663db6baaf8482454a9dce7f385d98c665133b3b123fe3cf00630c0c44'::text
    AS contract_revision,
  ARRAY[
    'artifact_observation_publication_gate',
    'atomic_failed_candidate_retry',
    'atomic_import_completion',
    'atomic_import_publication',
    'boundary_batches',
    'boundary_canonical_repair_once',
    'boundary_collection_provenance',
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
  inserted_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT collection_key_uq UNIQUE (key),
  CONSTRAINT collection_key_format_chk CHECK (key ~ '^[a-z_][a-z0-9_]*$')
);

--SPLIT--

CREATE TABLE $SCHEMA$.authority (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  key text NOT NULL,
  CONSTRAINT authority_collection_key_uq UNIQUE (collection_id, key),
  CONSTRAINT authority_key_format_chk CHECK (key ~ '^[a-z_][a-z0-9_]*$')
);

--SPLIT--

CREATE TABLE $SCHEMA$.area_type (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  key text NOT NULL,
  CONSTRAINT area_type_collection_key_uq UNIQUE (collection_id, key),
  CONSTRAINT area_type_key_format_chk CHECK (key ~ '^[a-z_][a-z0-9_]*$')
);

--SPLIT--

CREATE TABLE $SCHEMA$.area (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_id uuid NOT NULL REFERENCES $SCHEMA$.collection(id) ON DELETE CASCADE,
  authority_id uuid NOT NULL REFERENCES $SCHEMA$.authority(id) ON DELETE RESTRICT,
  area_type_id uuid NOT NULL REFERENCES $SCHEMA$.area_type(id) ON DELETE RESTRICT,
  code text NOT NULL,
  area_key text NOT NULL,
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
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT artifact_logical_name_key
    UNIQUE (source_release_id, logical_name),
  CONSTRAINT artifact_expected_sha256_check
    CHECK (expected_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT artifact_expected_bytes_check
    CHECK (expected_bytes > 0),
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

CREATE TABLE $SCHEMA$.release_collection_policy (
  release_id uuid PRIMARY KEY REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  requires_geometry boolean NOT NULL,
  CONSTRAINT release_collection_policy_name_nonempty_chk CHECK (btrim(name) <> '')
);

--SPLIT--

CREATE TABLE $SCHEMA$.release_authority (
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  authority_id uuid NOT NULL REFERENCES $SCHEMA$.authority(id) ON DELETE RESTRICT,
  name text NOT NULL,
  CONSTRAINT release_authority_pkey PRIMARY KEY (release_id, authority_id),
  CONSTRAINT release_authority_name_nonempty_chk CHECK (btrim(name) <> '')
);

--SPLIT--

CREATE INDEX release_authority_authority_idx
  ON $SCHEMA$.release_authority (authority_id, release_id);

--SPLIT--

CREATE TABLE $SCHEMA$.release_area_type (
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  area_type_id uuid NOT NULL REFERENCES $SCHEMA$.area_type(id) ON DELETE RESTRICT,
  rank integer NOT NULL,
  requires_geometry boolean NOT NULL DEFAULT false,
  CONSTRAINT release_area_type_pkey PRIMARY KEY (release_id, area_type_id),
  CONSTRAINT release_area_type_rank_uq UNIQUE (release_id, rank),
  CONSTRAINT release_area_type_rank_positive_chk CHECK (rank > 0)
);

--SPLIT--

CREATE INDEX release_area_type_area_type_idx
  ON $SCHEMA$.release_area_type (area_type_id, release_id);

--SPLIT--

CREATE TABLE $SCHEMA$.release_artifact (
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  artifact_id uuid NOT NULL REFERENCES $SCHEMA$.artifact(id) ON DELETE RESTRICT,
  CONSTRAINT release_artifact_pkey PRIMARY KEY (release_id, artifact_id)
);

--SPLIT--

CREATE INDEX release_artifact_artifact_idx
  ON $SCHEMA$.release_artifact (artifact_id, release_id);

--SPLIT--

CREATE TABLE $SCHEMA$.release_area_name (
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  area_name_id uuid NOT NULL REFERENCES $SCHEMA$.area_name(id) ON DELETE RESTRICT,
  CONSTRAINT release_area_name_pkey PRIMARY KEY (release_id, area_name_id)
);

--SPLIT--

CREATE INDEX release_area_name_area_name_idx
  ON $SCHEMA$.release_area_name (area_name_id, release_id);

--SPLIT--

CREATE TABLE $SCHEMA$.release_area_code (
  release_id uuid NOT NULL REFERENCES $SCHEMA$.release(id) ON DELETE CASCADE,
  area_code_id uuid NOT NULL REFERENCES $SCHEMA$.area_code(id) ON DELETE RESTRICT,
  CONSTRAINT release_area_code_pkey PRIMARY KEY (release_id, area_code_id)
);

--SPLIT--

CREATE INDEX release_area_code_area_code_idx
  ON $SCHEMA$.release_area_code (area_code_id, release_id);

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

CREATE INDEX release_source_source_release_idx
  ON $SCHEMA$.release_source (source_release_id, release_id);

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
  official_name text,
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

  IF EXISTS (
    SELECT 1 FROM $SCHEMA$.import_run_lease WHERE release_id = target_release_id
  ) THEN
    RAISE EXCEPTION
      'release % has an active import lease and cannot change partitions',
      target_release_id
      USING ERRCODE = '55000';
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

  IF EXISTS (
    SELECT 1 FROM $SCHEMA$.import_run_lease WHERE release_id = target_release_id
  ) THEN
    RAISE EXCEPTION
      'release % has an active import lease and cannot drop partitions',
      target_release_id
      USING ERRCODE = '55000';
  END IF;

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
CREATE FUNCTION $SCHEMA$.release_lock_key(collection_key text, release_key text)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
  SELECT hashtextextended(
    '$SCHEMA$:release:' || collection_key || ':' || release_key,
    0
  );
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.publication_lock_key(collection_key text)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
  SELECT hashtextextended('$SCHEMA$:publication:' || collection_key, 0);
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

CREATE FUNCTION $SCHEMA$.assert_area_declared(
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
  target_area record;
BEGIN
  SELECT authority_id, area_type_id INTO STRICT target_area
    FROM $SCHEMA$.area WHERE id = target_area_id;

  IF NOT EXISTS (
    SELECT 1 FROM $SCHEMA$.release_authority
     WHERE release_id = target_release_id
       AND authority_id = target_area.authority_id
  ) THEN
    RAISE EXCEPTION 'area % uses an authority not declared by release %',
      target_area_id, target_release_id USING ERRCODE = '23503';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM $SCHEMA$.release_area_type
     WHERE release_id = target_release_id
       AND area_type_id = target_area.area_type_id
  ) THEN
    RAISE EXCEPTION 'area % uses an area type not declared by release %',
      target_area_id, target_release_id USING ERRCODE = '23503';
  END IF;
END;
$fn$;

--SPLIT--

-- Every code an area carries, grouped by code type. An area may legally hold
-- several values of one type (two postal codes, say), so each type maps to an
-- array rather than a single value: a scalar mapping silently drops all but
-- one, including the very code the caller looked the area up by.
CREATE FUNCTION $SCHEMA$.area_codes_json(target_release_id uuid, target_area_id uuid)
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
        FROM $SCHEMA$.release_area_code
        JOIN $SCHEMA$.area_code ON area_code.id = release_area_code.area_code_id
       WHERE release_area_code.release_id = target_release_id
         AND area_code.area_id = target_area_id
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

  INSERT INTO $SCHEMA$.collection AS target (key)
  VALUES (key)
  ON CONFLICT ON CONSTRAINT collection_key_uq
  DO UPDATE SET key = target.key
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

  INSERT INTO $SCHEMA$.authority AS target (collection_id, key)
  VALUES (target_collection_id, key)
  ON CONFLICT ON CONSTRAINT authority_collection_key_uq
  DO UPDATE SET key = target.key
  RETURNING id INTO result_id;

  RETURN result_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.upsert_area_type(
  collection_key text,
  key text,
  rank integer,
  requires_geometry boolean
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
  IF collection_key IS NULL OR key IS NULL OR rank IS NULL OR requires_geometry IS NULL THEN
    RAISE EXCEPTION 'collection, key, rank, and requires_geometry are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'collection % does not exist', collection_key USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.area_type AS target (collection_id, key)
  VALUES (target_collection_id, key)
  ON CONFLICT ON CONSTRAINT area_type_collection_key_uq
  DO UPDATE SET key = target.key
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
BEGIN
  IF collection_key IS NULL OR key IS NULL OR rank IS NULL THEN
    RAISE EXCEPTION 'collection, key, and rank are required'
      USING ERRCODE = '22004';
  END IF;

  RETURN $SCHEMA$.upsert_area_type(collection_key, key, rank, false);
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
  DO UPDATE SET source_key = target.source_key
  WHERE target.provider IS NOT DISTINCT FROM EXCLUDED.provider
    AND target.license IS NOT DISTINCT FROM EXCLUDED.license
  RETURNING target.id INTO result_id;

  IF result_id IS NULL THEN
    RAISE EXCEPTION 'source % in collection % already exists with different provider or license',
      source_key, collection_key
      USING
        ERRCODE = '55000',
        HINT = 'Use a new source key for a semantically different source definition.';
  END IF;

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
  DO UPDATE SET release_key = target.release_key
  WHERE target.source_date IS NOT DISTINCT FROM EXCLUDED.source_date
    AND target.metadata IS NOT DISTINCT FROM EXCLUDED.metadata
  RETURNING target.id INTO result_id;

  IF result_id IS NULL THEN
    RAISE EXCEPTION 'source release % for source % already exists with different semantics',
      release_key, source_key
      USING
        ERRCODE = '55000',
        HINT = 'Use a new source release key for a different date or metadata definition.';
  END IF;

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
  DO UPDATE SET logical_name = target.logical_name
  WHERE target.url IS NOT DISTINCT FROM EXCLUDED.url
    AND target.operator_supplied IS NOT DISTINCT FROM EXCLUDED.operator_supplied
    AND target.format IS NOT DISTINCT FROM EXCLUDED.format
    AND target.expected_sha256 IS NOT DISTINCT FROM EXCLUDED.expected_sha256
    AND target.expected_bytes IS NOT DISTINCT FROM EXCLUDED.expected_bytes
    AND target.metadata IS NOT DISTINCT FROM EXCLUDED.metadata
  RETURNING target.id INTO result_id;

  IF result_id IS NULL THEN
    RAISE EXCEPTION 'artifact % already exists on source release % with different semantics',
      logical_name, target_source_release_id
      USING
        ERRCODE = '55000',
        HINT = 'Use a new logical name or source release key for a different artifact definition.';
  END IF;

  RETURN result_id;
END;
$fn$;

--SPLIT--

-- Opens a release only when the semantic identity is absent or byte-for-byte
-- identical. Registration and retry own replacement semantics; this lower
-- level function must never turn a changed manifest into an in-place update.
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
  declared_count integer;
  existing record;
BEGIN
  IF collection_key IS NULL OR release_key IS NULL OR manifest IS NULL THEN
    RAISE EXCEPTION 'collection, release key, and manifest are required'
      USING ERRCODE = '22004';
  END IF;

  IF jsonb_typeof(manifest) <> 'object' THEN
    RAISE EXCEPTION 'manifest must be a JSON object' USING ERRCODE = '22023';
  END IF;

  -- Every lifecycle path takes these locks in this order before row locks.
  -- Both keys derive only from immutable manifest text, so the same order is
  -- available before the collection or release exists.
  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.release_lock_key(collection_key, release_key));
  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.publication_lock_key(collection_key));
  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  SELECT collection.id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'collection % does not exist', collection_key USING ERRCODE = '23503';
  END IF;

  SELECT id, release.manifest, release.source_date, status, retired_at
    INTO existing
    FROM $SCHEMA$.release
   WHERE collection_id = target_collection_id
     AND release.release_key = open_release.release_key
   FOR UPDATE;

  IF FOUND THEN
    IF existing.manifest IS NOT DISTINCT FROM manifest
       AND existing.source_date IS NOT DISTINCT FROM source_date
       AND existing.status <> 'completed'
       AND existing.retired_at IS NULL THEN
      RETURN existing.id;
    END IF;

    RAISE EXCEPTION 'release % of collection % already exists with different or protected state',
      release_key, collection_key
      USING
        ERRCODE = '55000',
        HINT = 'Use prepare_import for an identical candidate or retry_failed for an explicit correction.';
  END IF;

  INSERT INTO $SCHEMA$.release (collection_id, release_key, manifest, source_date)
  VALUES (target_collection_id, open_release.release_key, open_release.manifest,
          open_release.source_date)
  RETURNING id INTO result_id;

  PERFORM $SCHEMA$.create_release_partitions(result_id);

  INSERT INTO $SCHEMA$.release_collection_policy
    (release_id, name, description, requires_geometry)
  VALUES (
    result_id,
    coalesce(nullif(manifest ->> 'collection_name', ''), collection_key),
    manifest ->> 'description',
    coalesce((manifest ->> 'requires_geometry')::boolean, false)
  );

  INSERT INTO $SCHEMA$.release_authority (release_id, authority_id, name)
  SELECT result_id, authority.id, declaration ->> 'name'
    FROM jsonb_array_elements(coalesce(manifest -> 'authorities', '[]'::jsonb)) declaration
    JOIN $SCHEMA$.authority
     ON authority.collection_id = target_collection_id
     AND authority.key = declaration ->> 'key';

  GET DIAGNOSTICS declared_count = ROW_COUNT;
  IF declared_count <> jsonb_array_length(coalesce(manifest -> 'authorities', '[]'::jsonb)) THEN
    RAISE EXCEPTION 'manifest names an authority that is not registered in collection %',
      collection_key USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.release_area_type
    (release_id, area_type_id, rank, requires_geometry)
  SELECT result_id, area_type.id, (declaration ->> 'rank')::integer,
         coalesce((declaration ->> 'requires_geometry')::boolean, false)
    FROM jsonb_array_elements(coalesce(manifest -> 'area_types', '[]'::jsonb)) declaration
    JOIN $SCHEMA$.area_type
     ON area_type.collection_id = target_collection_id
     AND area_type.key = declaration ->> 'key';

  GET DIAGNOSTICS declared_count = ROW_COUNT;
  IF declared_count <> jsonb_array_length(coalesce(manifest -> 'area_types', '[]'::jsonb)) THEN
    RAISE EXCEPTION 'manifest names an area type that is not registered in collection %',
      collection_key USING ERRCODE = '23503';
  END IF;

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

CREATE FUNCTION $SCHEMA$.attach_artifact(
  target_release_id uuid,
  target_artifact_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF target_release_id IS NULL OR target_artifact_id IS NULL THEN
    RAISE EXCEPTION 'release id and artifact id are required' USING ERRCODE = '22004';
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  IF EXISTS (
    SELECT 1
      FROM $SCHEMA$.import_run_lease
     WHERE release_id = target_release_id
       AND executor_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION
      'release % has a claimed import executor and cannot attach artifacts',
      target_release_id
      USING ERRCODE = '55000';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM $SCHEMA$.release_artifact AS selected
      JOIN $SCHEMA$.artifact AS existing
        ON existing.id = selected.artifact_id
      JOIN $SCHEMA$.artifact AS incoming
        ON incoming.id = target_artifact_id
     WHERE selected.release_id = target_release_id
       AND existing.logical_name = incoming.logical_name
       AND existing.id IS DISTINCT FROM incoming.id
  ) THEN
    RAISE EXCEPTION
      'logical_name % is already attached to release %',
      (SELECT logical_name FROM $SCHEMA$.artifact WHERE id = target_artifact_id),
      target_release_id
      USING ERRCODE = '23505';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM $SCHEMA$.artifact
      JOIN $SCHEMA$.release_source
        ON release_source.source_release_id = artifact.source_release_id
     WHERE artifact.id = target_artifact_id
       AND release_source.release_id = target_release_id
  ) THEN
    RAISE EXCEPTION 'artifact % is not from a source release attached to release %',
      target_artifact_id, target_release_id
      USING ERRCODE = '23503';
  END IF;

  INSERT INTO $SCHEMA$.release_artifact (release_id, artifact_id)
  VALUES (target_release_id, target_artifact_id)
  ON CONFLICT ON CONSTRAINT release_artifact_pkey DO NOTHING;
END;
$fn$;

--SPLIT--

-- The parallel-array guard the plural writes share. Every plural write takes
-- one array per column and pairs them by position, so arrays of different
-- lengths do not fail on their own: unnest pads the shorter ones with nulls
-- and the batch written is one the caller never assembled. Each array must be
-- present, and all of them must agree on one length, which is what this
-- returns.
--
-- null_positions carries array_position(column, NULL) for a column whose
-- elements are required and NULL for a column that accepts a null element, so
-- which columns are optional is stated where the arrays are rather than
-- inferred here.
CREATE FUNCTION $SCHEMA$.assert_write_arrays(
  lengths integer[],
  null_positions integer[],
  labels text[]
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  column_index integer;
BEGIN
  FOR column_index IN 1 .. cardinality(lengths) LOOP
    IF lengths[column_index] IS NULL THEN
      RAISE EXCEPTION '% are required', labels[column_index] USING ERRCODE = '22004';
    END IF;

    IF lengths[column_index] <> lengths[1] THEN
      RAISE EXCEPTION
        '% and % must carry the same number of elements, and they carry % and %',
        labels[1], labels[column_index], lengths[1], lengths[column_index]
        USING ERRCODE = '22023';
    END IF;

    IF null_positions[column_index] IS NOT NULL THEN
      RAISE EXCEPTION '% must not contain a null element, and element % is null',
        labels[column_index], null_positions[column_index]
        USING ERRCODE = '22004';
    END IF;
  END LOOP;

  RETURN lengths[1];
END;
$fn$;

--SPLIT--

-- The advisory key one area serializes on. Every write that locks area rows
-- computes it here, so a batch and a single upsert of the same area take the
-- same lock and two callers computing it separately cannot disagree.
CREATE FUNCTION $SCHEMA$.area_lock_key(
  target_collection_id uuid,
  composed_key text
)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
  SELECT ('x' || substr(
    md5('$SCHEMA$.area:' || target_collection_id::text || ':' || composed_key),
    1, 16))::bit(64)::bigint;
$fn$;

--SPLIT--

-- Serializes a batch on every area it is about to touch, ascending by lock
-- key.
--
-- One lock order for the whole write path, not one per function. A plural
-- write locks many area rows per statement where a scalar write locks one, so
-- two plural writes that each sorted their own way -- one by composed key, one
-- by area id -- would form a cycle over any pair of areas they share, and a
-- release-scoped import lease means two releases of one collection normalize
-- at the same time. Ascending lock key is an order every caller computes
-- identically from the keys alone, so overlapping batches queue instead. And
-- because every lock is taken before any row is touched, two batches sharing
-- an area can never both reach their row writes.
--
-- A batch holds one lock per distinct area for the length of its statement, so
-- a caller's batch size bounds its share of the lock table.
CREATE FUNCTION $SCHEMA$.lock_areas(lock_keys bigint[])
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  lock_key bigint;
BEGIN
  FOR lock_key IN
    SELECT DISTINCT requested.lock_key
      FROM unnest(lock_keys) AS requested(lock_key)
     ORDER BY 1
  LOOP
    PERFORM pg_advisory_xact_lock(lock_key);
  END LOOP;
END;
$fn$;

--SPLIT--

-- Reports a key a plural write could not resolve. A plural write joins its
-- keys against the rows they name, and a join on its own would drop an
-- unknown key out of the batch and still report success, where the scalar
-- forms resolve with SELECT ... INTO STRICT and raise. This raises
-- NO_DATA_FOUND with the SQLSTATE and the wording that resolution raises, and
-- names the key it could not resolve, which the scalar form cannot.
CREATE FUNCTION $SCHEMA$.assert_resolved(
  missing_key text,
  label text
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF missing_key IS NOT NULL THEN
    RAISE EXCEPTION 'query returned no rows for % %', label, missing_key
      USING ERRCODE = 'P0002';
  END IF;
END;
$fn$;

--SPLIT--

-- One area is a batch of one. The required-argument check stays here rather
-- than being left to the plural form, because it names the four arguments a
-- scalar caller passed; the plural form reports the arrays it was given.
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
BEGIN
  IF collection_key IS NULL OR authority_key IS NULL
     OR area_type_key IS NULL OR code IS NULL THEN
    RAISE EXCEPTION 'collection, authority, area type, and code are required'
      USING ERRCODE = '22004';
  END IF;

  RETURN ($SCHEMA$.upsert_area_many(
    collection_key, ARRAY[authority_key], ARRAY[area_type_key], ARRAY[code]))[1];
END;
$fn$;

--SPLIT--

-- Creates or updates one area per position of its three parallel arrays,
-- returning their ids in that order. upsert_area is this function with
-- one-element arrays: an import writes areas by the batch, and a separate
-- statement per area is one round trip per area.
--
-- Areas repeat heavily within a batch -- every city row in a county names
-- that county, and every row in a state names that state -- so the batch is
-- reduced to one row per identity before it is inserted. ON CONFLICT DO
-- UPDATE raises 21000 when a single statement presents the same conflict key
-- twice, and a batch that did not deduplicate would fail on the first county
-- named by two cities. The returned array still carries one id per input
-- position, repeats included, so a caller can pair it with the array it sent.
CREATE FUNCTION $SCHEMA$.upsert_area_many(
  collection_key text,
  authority_keys text[],
  area_type_keys text[],
  codes text[]
)
RETURNS uuid[]
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_collection_id uuid;
  batch_size integer;
  result uuid[];
BEGIN
  IF collection_key IS NULL THEN
    RAISE EXCEPTION 'collection is required' USING ERRCODE = '22004';
  END IF;

  batch_size := $SCHEMA$.assert_write_arrays(
    ARRAY[cardinality(authority_keys), cardinality(area_type_keys), cardinality(codes)],
    ARRAY[array_position(authority_keys, NULL), array_position(area_type_keys, NULL),
          array_position(codes, NULL)],
    ARRAY['authority keys', 'area type keys', 'codes']);

  IF batch_size = 0 THEN
    RETURN ARRAY[]::uuid[];
  END IF;

  SELECT id INTO STRICT target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  -- An authority or area type the collection does not carry is refused rather
  -- than joined away: the join below would drop its rows and return an array
  -- shorter than the caller sent, which is the silent half of a write that
  -- did not happen.
  PERFORM $SCHEMA$.assert_resolved(
    (SELECT min(requested.authority_key)
       FROM unnest(authority_keys) AS requested(authority_key)
      WHERE NOT EXISTS (
        SELECT 1 FROM $SCHEMA$.authority
         WHERE authority.collection_id = target_collection_id
           AND authority.key = requested.authority_key)),
    'authority key');

  PERFORM $SCHEMA$.assert_resolved(
    (SELECT min(requested.area_type_key)
       FROM unnest(area_type_keys) AS requested(area_type_key)
      WHERE NOT EXISTS (
        SELECT 1 FROM $SCHEMA$.area_type
         WHERE area_type.collection_id = target_collection_id
           AND area_type.key = requested.area_type_key)),
    'area type key');

  -- The scalar form serializes on one area's composed key, for the reason
  -- given below the INSERT. A batch needs that protection for every area it
  -- writes, and it goes through lock_areas so that it and every other write
  -- that locks area rows take them in one order.
  PERFORM $SCHEMA$.lock_areas(ARRAY(
    SELECT $SCHEMA$.area_lock_key(
             target_collection_id,
             requested.authority_key || ':' || requested.area_type_key || ':' ||
               requested.code)
      FROM unnest(authority_keys, area_type_keys, codes)
             AS requested(authority_key, area_type_key, code)));

  -- area carries two unique constraints (identity and area_key) and a
  -- speculative-insert race: a concurrent caller can block on area_area_key_uq
  -- rather than the area_identity_uq arbiter and get a bare 23505. Every row
  -- that collides on area_key within a collection collides on identity too,
  -- since area_key is composed from the identity, so serializing on the
  -- composed key covers both and stays as narrow as one area.
  --
  -- Rows are deduplicated on the identity the arbiter names, not on the
  -- composed key, so two identities that compose the same area_key stay two
  -- rows and collide on area_area_key_uq exactly as two scalar calls would.
  WITH requested AS (
    SELECT t.ord, t.authority_key, t.area_type_key, t.code,
           t.authority_key || ':' || t.area_type_key || ':' || t.code AS composed_key
      FROM unnest(authority_keys, area_type_keys, codes) WITH ORDINALITY
             AS t(authority_key, area_type_key, code, ord)
  ),
  deduplicated AS (
    SELECT DISTINCT ON (authority_key, area_type_key, code)
           authority_key, area_type_key, code, composed_key
      FROM requested
     ORDER BY authority_key, area_type_key, code, ord DESC
  ),
  written AS (
    INSERT INTO $SCHEMA$.area
      (collection_id, authority_id, area_type_id, code, area_key)
    SELECT target_collection_id, authority.id, area_type.id,
           deduplicated.code, deduplicated.composed_key
      FROM deduplicated
      JOIN $SCHEMA$.authority
        ON authority.collection_id = target_collection_id
       AND authority.key = deduplicated.authority_key
      JOIN $SCHEMA$.area_type
        ON area_type.collection_id = target_collection_id
       AND area_type.key = deduplicated.area_type_key
     ORDER BY deduplicated.composed_key
    ON CONFLICT ON CONSTRAINT area_identity_uq
    DO UPDATE SET updated_at = now()
    RETURNING id, area_key
  )
  SELECT array_agg(written.id ORDER BY requested.ord)
    INTO result
    FROM requested
    JOIN written ON written.area_key = requested.composed_key;

  RETURN result;
END;
$fn$;

--SPLIT--

-- The ingestion overload derives its collection from the fenced run rather
-- than accepting caller-supplied collection text. The text-key overload above
-- remains the catalog/bootstrap primitive; pipeline normalization uses this
-- attempt-scoped form so a superseded worker cannot leave orphan identities.
CREATE FUNCTION $SCHEMA$.upsert_area_many(
  target_run_id uuid,
  target_executor_id uuid,
  authority_keys text[],
  area_type_keys text[],
  codes text[]
)
RETURNS uuid[]
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  target_collection_key text;
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['normalizing']);

  SELECT collection.key INTO STRICT target_collection_key
    FROM $SCHEMA$.release
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE release.id = target_release_id;

  RETURN $SCHEMA$.upsert_area_many(
    target_collection_key, authority_keys, area_type_keys, codes);
END;
$fn$;

--SPLIT--

-- One name is a batch of one, the same way upsert_area is.
CREATE FUNCTION $SCHEMA$.put_area_name(
  target_run_id uuid,
  target_executor_id uuid,
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
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL OR target_area_key IS NULL OR name IS NULL OR kind IS NULL THEN
    RAISE EXCEPTION 'run id, executor id, area key, name, and kind are required'
      USING ERRCODE = '22004';
  END IF;

  RETURN ($SCHEMA$.put_area_name_many(
    target_run_id, target_executor_id, ARRAY[target_area_key], ARRAY[name], ARRAY[kind], ARRAY[locale]))[1];
END;
$fn$;

--SPLIT--

-- Sets one name per position of its four parallel arrays, returning the name
-- rows' ids in that order. put_area_name is this function with one-element
-- arrays.
--
-- locales is the one column that accepts a null element: a name with no
-- locale is an unlocalized name, and area_name_uq compares locale NULLS NOT
-- DISTINCT, so two unlocalized names of the same kind and text are one row.
-- The deduplication below groups nulls the same way the constraint does.
CREATE FUNCTION $SCHEMA$.put_area_name_many(
  target_run_id uuid,
  target_executor_id uuid,
  target_area_keys text[],
  names text[],
  kinds text[],
  locales text[]
)
RETURNS uuid[]
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  batch_size integer;
  absent_area_key text;
  result uuid[];
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['normalizing']);

  batch_size := $SCHEMA$.assert_write_arrays(
    ARRAY[cardinality(target_area_keys), cardinality(names), cardinality(kinds),
          cardinality(locales)],
    ARRAY[array_position(target_area_keys, NULL), array_position(names, NULL),
          array_position(kinds, NULL), NULL],
    ARRAY['area keys', 'names', 'kinds', 'locales']);

  IF batch_size = 0 THEN
    RETURN ARRAY[]::uuid[];
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  PERFORM $SCHEMA$.assert_resolved(
    (SELECT min(requested.area_key)
       FROM unnest(target_area_keys) AS requested(area_key)
      WHERE NOT EXISTS (
        SELECT 1 FROM $SCHEMA$.area WHERE area.area_key = requested.area_key)),
    'area key');

  SELECT min(requested.area_key) INTO absent_area_key
    FROM unnest(target_area_keys) AS requested(area_key)
    JOIN $SCHEMA$.area ON area.area_key = requested.area_key
   WHERE NOT EXISTS (
     SELECT 1 FROM $SCHEMA$.release_area
      WHERE release_area.release_id = target_release_id
        AND release_area.area_id = area.id);

  IF absent_area_key IS NOT NULL THEN
    RAISE EXCEPTION 'area % is not a member of release %', absent_area_key, target_release_id
      USING ERRCODE = '23503';
  END IF;

  PERFORM $SCHEMA$.lock_areas(ARRAY(
    SELECT $SCHEMA$.area_lock_key(area.collection_id, area.area_key)
      FROM $SCHEMA$.area
     WHERE area.area_key = ANY(target_area_keys)));

  WITH requested AS (
    SELECT t.ord, area.id AS area_id, t.name, t.kind, t.locale
      FROM unnest(target_area_keys, names, kinds, locales) WITH ORDINALITY
             AS t(area_key, name, kind, locale, ord)
      JOIN $SCHEMA$.area ON area.area_key = t.area_key
  ),
  deduplicated AS (
    SELECT DISTINCT ON (area_id, kind, name, locale) area_id, name, kind, locale
      FROM requested
     ORDER BY area_id, kind, name, locale, ord DESC
  ),
  written AS MATERIALIZED (
    INSERT INTO $SCHEMA$.area_name (area_id, name, kind, locale)
    SELECT area_id, name, kind, locale
      FROM deduplicated
     ORDER BY area_id, kind, name, locale
    ON CONFLICT ON CONSTRAINT area_name_uq
    DO UPDATE SET name = $SCHEMA$.area_name.name
    RETURNING id, area_id, name, kind, locale
  )
  INSERT INTO $SCHEMA$.release_area_name (release_id, area_name_id)
  SELECT target_release_id, written.id FROM written
  ON CONFLICT ON CONSTRAINT release_area_name_pkey DO NOTHING;

  UPDATE $SCHEMA$.release_area target
     SET official_name = selected.name
    FROM (
      SELECT release_area.area_id,
             (array_agg(area_name.name
                ORDER BY area_name.locale NULLS FIRST, area_name.name)
                FILTER (WHERE area_name.id IS NOT NULL))[1] AS name
        FROM $SCHEMA$.release_area
        LEFT JOIN (
          $SCHEMA$.release_area_name
          JOIN $SCHEMA$.area_name
            ON area_name.id = release_area_name.area_name_id
           AND area_name.kind = 'official'
        )
          ON release_area_name.release_id = release_area.release_id
         AND area_name.area_id = release_area.area_id
       WHERE release_area.release_id = target_release_id
         AND release_area.area_id IN (
           SELECT area.id FROM $SCHEMA$.area WHERE area.area_key = ANY(target_area_keys))
       GROUP BY release_area.area_id
    ) selected
   WHERE target.release_id = target_release_id
     AND target.area_id = selected.area_id;

  SELECT array_agg(area_name.id ORDER BY requested.ord)
    INTO result
    FROM unnest(target_area_keys, names, kinds, locales) WITH ORDINALITY
           AS requested(area_key, name, kind, locale, ord)
    JOIN $SCHEMA$.area ON area.area_key = requested.area_key
    JOIN $SCHEMA$.area_name
      ON area_name.area_id = area.id
     AND area_name.kind = requested.kind
     AND area_name.name = requested.name
     AND area_name.locale IS NOT DISTINCT FROM requested.locale;

  RETURN result;
END;
$fn$;

--SPLIT--

-- One code is a batch of one, the same way upsert_area is.
CREATE FUNCTION $SCHEMA$.put_area_code(
  target_run_id uuid,
  target_executor_id uuid,
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
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL OR target_area_key IS NULL
     OR code_type IS NULL OR code_value IS NULL THEN
    RAISE EXCEPTION 'run id, executor id, area key, code type, and code value are required'
      USING ERRCODE = '22004';
  END IF;

  RETURN ($SCHEMA$.put_area_code_many(
    target_run_id, target_executor_id, ARRAY[target_area_key], ARRAY[code_type], ARRAY[code_value]))[1];
END;
$fn$;

--SPLIT--

-- Sets one external code per position of its three parallel arrays, returning
-- the code rows' ids in that order. put_area_code is this function with
-- one-element arrays.
CREATE FUNCTION $SCHEMA$.put_area_code_many(
  target_run_id uuid,
  target_executor_id uuid,
  target_area_keys text[],
  code_types text[],
  code_values text[]
)
RETURNS uuid[]
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  batch_size integer;
  absent_area_key text;
  result uuid[];
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['normalizing']);

  batch_size := $SCHEMA$.assert_write_arrays(
    ARRAY[cardinality(target_area_keys), cardinality(code_types), cardinality(code_values)],
    ARRAY[array_position(target_area_keys, NULL), array_position(code_types, NULL),
          array_position(code_values, NULL)],
    ARRAY['area keys', 'code types', 'code values']);

  IF batch_size = 0 THEN
    RETURN ARRAY[]::uuid[];
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  PERFORM $SCHEMA$.assert_resolved(
    (SELECT min(requested.area_key)
       FROM unnest(target_area_keys) AS requested(area_key)
      WHERE NOT EXISTS (
        SELECT 1 FROM $SCHEMA$.area WHERE area.area_key = requested.area_key)),
    'area key');

  SELECT min(requested.area_key) INTO absent_area_key
    FROM unnest(target_area_keys) AS requested(area_key)
    JOIN $SCHEMA$.area ON area.area_key = requested.area_key
   WHERE NOT EXISTS (
     SELECT 1 FROM $SCHEMA$.release_area
      WHERE release_area.release_id = target_release_id
        AND release_area.area_id = area.id);

  IF absent_area_key IS NOT NULL THEN
    RAISE EXCEPTION 'area % is not a member of release %', absent_area_key, target_release_id
      USING ERRCODE = '23503';
  END IF;

  -- area_code carries no trigger, so the only rows this touches are its own.
  -- The insert is still ordered on the conflict key, so two batches writing an
  -- overlapping set of codes take their row locks in the same order rather
  -- than in whatever order each caller's arrays arrived in.
  WITH requested AS (
    SELECT t.ord, area.id AS area_id, t.code_type, t.code_value
      FROM unnest(target_area_keys, code_types, code_values) WITH ORDINALITY
             AS t(area_key, code_type, code_value, ord)
      JOIN $SCHEMA$.area ON area.area_key = t.area_key
  ),
  deduplicated AS (
    SELECT DISTINCT ON (area_id, code_type, code_value) area_id, code_type, code_value
      FROM requested
     ORDER BY area_id, code_type, code_value, ord DESC
  ),
  written AS MATERIALIZED (
    INSERT INTO $SCHEMA$.area_code (area_id, code_type, code_value)
    SELECT area_id, code_type, code_value
      FROM deduplicated
     ORDER BY area_id, code_type, code_value
    ON CONFLICT ON CONSTRAINT area_code_uq
    DO UPDATE SET code_value = $SCHEMA$.area_code.code_value
    RETURNING id, area_id, code_type, code_value
  )
  INSERT INTO $SCHEMA$.release_area_code (release_id, area_code_id)
  SELECT target_release_id, written.id FROM written
  ON CONFLICT ON CONSTRAINT release_area_code_pkey DO NOTHING;

  SELECT array_agg(area_code.id ORDER BY requested.ord)
    INTO result
    FROM unnest(target_area_keys, code_types, code_values) WITH ORDINALITY
           AS requested(area_key, code_type, code_value, ord)
    JOIN $SCHEMA$.area ON area.area_key = requested.area_key
    JOIN $SCHEMA$.area_code
      ON area_code.area_id = area.id
     AND area_code.code_type = requested.code_type
     AND area_code.code_value = requested.code_value;

  RETURN result;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.put_boundary(
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
CREATE FUNCTION $SCHEMA$.put_boundaries(
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
         requested.geom, ST_QuantizeCoordinates(requested.geom, 6),
         requested.display_tier, requested.repaired, requested.source_properties
    FROM unnest(accepted_area_ids, accepted_source_release_ids,
                accepted_geometries, accepted_display_tiers,
                accepted_repaired, accepted_source_properties)
           AS requested(area_id, source_release_id, geom, display_tier,
                        repaired, source_properties)
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

--SPLIT--

-- One membership is a batch of one, the same way upsert_area is.
CREATE FUNCTION $SCHEMA$.put_area_in_release(
  target_run_id uuid,
  target_executor_id uuid,
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
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL OR target_area_key IS NULL THEN
    RAISE EXCEPTION 'run id, executor id, and area key are required'
      USING ERRCODE = '22004';
  END IF;

  PERFORM $SCHEMA$.put_area_in_release_many(
    target_run_id, target_executor_id, ARRAY[target_area_key], ARRAY[centroid], ARRAY[data]);
END;
$fn$;

--SPLIT--

-- Places one area into the release per position of its three parallel arrays.
-- put_area_in_release is this function with one-element arrays.
--
-- Membership is last-write-wins -- the upsert overwrites centroid and data --
-- so a batch that names the same area twice keeps the last of the two, which
-- is the row a caller writing them one at a time would have been left with.
-- That is why the arrays are unnested WITH ORDINALITY: without a position to
-- order on, the deduplication would keep an arbitrary one.
CREATE FUNCTION $SCHEMA$.put_area_in_release_many(
  target_run_id uuid,
  target_executor_id uuid,
  target_area_keys text[],
  centroids geography(Point, 4326)[],
  data jsonb[]
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
  foreign_area_id uuid;
  undeclared_area_id uuid;
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['normalizing']);

  batch_size := $SCHEMA$.assert_write_arrays(
    ARRAY[cardinality(target_area_keys), cardinality(centroids), cardinality(data)],
    ARRAY[array_position(target_area_keys, NULL), NULL, NULL],
    ARRAY['area keys', 'centroids', 'attributes']);

  IF batch_size = 0 THEN
    RETURN;
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  PERFORM $SCHEMA$.assert_resolved(
    (SELECT min(requested.area_key)
       FROM unnest(target_area_keys) AS requested(area_key)
      WHERE NOT EXISTS (
        SELECT 1 FROM $SCHEMA$.area WHERE area.area_key = requested.area_key)),
    'area key');

  -- The invariant helper reports one area against one release, so the first
  -- area of another collection is handed to it and it raises the message a
  -- scalar caller already reads.
  SELECT area.id INTO foreign_area_id
    FROM $SCHEMA$.area
    JOIN $SCHEMA$.release ON release.id = target_release_id
   WHERE area.area_key = ANY(target_area_keys)
     AND area.collection_id <> release.collection_id
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

  -- The unnested attribute column is named for what it holds rather than for
  -- the column it lands in: a CTE column named data would be ambiguous against
  -- this function's own data parameter.
  WITH requested AS (
    SELECT t.ord, area.id AS area_id, t.centroid, t.attributes
      FROM unnest(target_area_keys, centroids, data) WITH ORDINALITY
             AS t(area_key, centroid, attributes, ord)
      JOIN $SCHEMA$.area ON area.area_key = t.area_key
  ),
  deduplicated AS (
    SELECT DISTINCT ON (area_id) area_id, centroid, attributes
      FROM requested
     ORDER BY area_id, ord DESC
  )
  INSERT INTO $SCHEMA$.release_area (release_id, area_id, centroid, data)
  SELECT target_release_id, area_id, centroid, coalesce(attributes, '{}'::jsonb)
    FROM deduplicated
   ORDER BY area_id
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
--
-- One relation is a batch of one, the same way upsert_area is.
CREATE FUNCTION $SCHEMA$.put_relation(
  target_run_id uuid,
  target_executor_id uuid,
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
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL OR parent_area_key IS NULL
     OR child_area_key IS NULL OR relation_type IS NULL THEN
    RAISE EXCEPTION 'run, parent area key, child area key, and relation type are required'
      USING ERRCODE = '22004';
  END IF;

  PERFORM $SCHEMA$.put_relation_many(
    target_run_id, target_executor_id, ARRAY[parent_area_key], ARRAY[child_area_key],
    ARRAY[relation_type]);
END;
$fn$;

--SPLIT--

-- Asserts one relation per position of its three parallel arrays.
-- put_relation is this function with one-element arrays.
--
-- A relation is last-write-wins the way membership is, so a pair named twice
-- in one batch keeps the last relation_type, and the deduplication orders on
-- the arrays' own positions to find it.
CREATE FUNCTION $SCHEMA$.put_relation_many(
  target_run_id uuid,
  target_executor_id uuid,
  parent_area_keys text[],
  child_area_keys text[],
  relation_types text[]
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
  unknown_type text;
  absent_area_key text;
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['relating']);

  batch_size := $SCHEMA$.assert_write_arrays(
    ARRAY[cardinality(parent_area_keys), cardinality(child_area_keys),
          cardinality(relation_types)],
    ARRAY[array_position(parent_area_keys, NULL), array_position(child_area_keys, NULL),
          array_position(relation_types, NULL)],
    ARRAY['parent area keys', 'child area keys', 'relation types']);

  IF batch_size = 0 THEN
    RETURN;
  END IF;

  SELECT min(requested.relation_type) INTO unknown_type
    FROM unnest(relation_types) AS requested(relation_type)
   WHERE requested.relation_type NOT IN ('contains', 'mostly_contains', 'overlaps');

  IF unknown_type IS NOT NULL THEN
    RAISE EXCEPTION 'unknown relation type %', unknown_type USING ERRCODE = '22023';
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  PERFORM $SCHEMA$.assert_resolved(
    (SELECT min(requested.area_key)
       FROM unnest(parent_area_keys || child_area_keys) AS requested(area_key)
      WHERE NOT EXISTS (
        SELECT 1 FROM $SCHEMA$.area WHERE area.area_key = requested.area_key)),
    'area key');

  SELECT min(requested.area_key) INTO absent_area_key
    FROM unnest(parent_area_keys || child_area_keys) AS requested(area_key)
    JOIN $SCHEMA$.area ON area.area_key = requested.area_key
   WHERE NOT EXISTS (
     SELECT 1 FROM $SCHEMA$.release_area
      WHERE release_area.release_id = target_release_id
        AND release_area.area_id = area.id);

  IF absent_area_key IS NOT NULL THEN
    RAISE EXCEPTION 'area % is not a member of release %', absent_area_key, target_release_id
      USING ERRCODE = '23503';
  END IF;

  WITH requested AS (
    SELECT t.ord, parent.id AS parent_area_id, child.id AS child_area_id, t.relation_type
      FROM unnest(parent_area_keys, child_area_keys, relation_types) WITH ORDINALITY
             AS t(parent_area_key, child_area_key, relation_type, ord)
      JOIN $SCHEMA$.area parent ON parent.area_key = t.parent_area_key
      JOIN $SCHEMA$.area child ON child.area_key = t.child_area_key
  ),
  deduplicated AS (
    SELECT DISTINCT ON (parent_area_id, child_area_id)
           parent_area_id, child_area_id, relation_type
      FROM requested
     ORDER BY parent_area_id, child_area_id, ord DESC
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
  SELECT target_release_id, parent_area_id, child_area_id, relation_type, NULL, NULL, NULL
    FROM deduplicated
   ORDER BY parent_area_id, child_area_id
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
  target_run_id uuid,
  target_executor_id uuid
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  inserted_count bigint;
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['relating']);

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
    JOIN $SCHEMA$.release_area_type parent_area_type
      ON parent_area_type.release_id = parent_boundary.release_id
     AND parent_area_type.area_type_id = parent_area.area_type_id
    JOIN $SCHEMA$.boundary child_boundary
      ON child_boundary.release_id = parent_boundary.release_id
     AND child_boundary.display_tier = 0
     AND child_boundary.area_id <> parent_boundary.area_id
     AND parent_boundary.geom && child_boundary.geom
     AND ST_Intersects(parent_boundary.geom, child_boundary.geom)
    JOIN $SCHEMA$.area child_area
      ON child_area.id = child_boundary.area_id
    JOIN $SCHEMA$.release_area_type child_area_type
      ON child_area_type.release_id = child_boundary.release_id
     AND child_area_type.area_type_id = child_area.area_type_id
    -- Pairs run from lower type_rank to higher within one collection, so
    -- areas of equal rank are never paired: overlaps between same-type
    -- areas produce no stored relation here. Pairwise measurement within a
    -- type is quadratic and does not scale to large same-type collections;
    -- such an overlap remains discoverable on demand through areas_for_geometry.
    WHERE parent_boundary.release_id = target_release_id
      AND parent_boundary.display_tier = 0
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

  SELECT release_collection_policy.requires_geometry
    INTO STRICT collection_requires_geometry
    FROM $SCHEMA$.release_collection_policy
   WHERE release_collection_policy.release_id = target_release_id;

  SELECT count(*) INTO ungeometried_count
    FROM $SCHEMA$.release_area ra
    JOIN $SCHEMA$.area ON area.id = ra.area_id
    JOIN $SCHEMA$.release_area_type
      ON release_area_type.release_id = ra.release_id
     AND release_area_type.area_type_id = area.area_type_id
   WHERE ra.release_id = target_release_id
     AND (collection_requires_geometry OR release_area_type.requires_geometry)
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.boundary b
        WHERE b.release_id = ra.release_id
          AND b.area_id = ra.area_id
          AND b.display_tier = 0
     );

  IF ungeometried_count > 0 THEN
    failures := failures || format('%s areas lack a boundary', ungeometried_count);
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

CREATE FUNCTION $SCHEMA$.verify_import(target_run_id uuid, target_executor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['verifying']);

  RETURN $SCHEMA$.verify_release(target_release_id);
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
  target_collection_key text;
  target_release_key text;
  latest_run_id uuid;
  latest_run_status text;
  previous uuid;
BEGIN
  IF target_release_id IS NULL THEN
    RAISE EXCEPTION 'release id is required' USING ERRCODE = '22004';
  END IF;

  SELECT release.collection_id, collection.key, release.release_key
    INTO target_collection_id, target_collection_key, target_release_key
    FROM $SCHEMA$.release
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE release.id = target_release_id;

  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'release % does not exist', target_release_id USING ERRCODE = '23503';
  END IF;

  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.release_lock_key(target_collection_key, target_release_key));
  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.publication_lock_key(target_collection_key));
  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  IF EXISTS (
    SELECT 1
      FROM $SCHEMA$.import_run_lease
     WHERE import_run_lease.release_id = target_release_id
  ) THEN
    RAISE EXCEPTION 'release % has an active import and cannot be published directly',
      target_release_id
      USING
        ERRCODE = '55000',
        HINT = 'Let the owning import publish atomically with publish_import.';
  END IF;

  SELECT import_run.id, import_run.status INTO latest_run_id, latest_run_status
    FROM $SCHEMA$.import_run
   WHERE import_run.release_id = target_release_id
   ORDER BY import_run.attempt DESC
   LIMIT 1
   FOR UPDATE;

  IF FOUND AND latest_run_status <> 'completed' THEN
    RAISE EXCEPTION 'release % latest import is % and cannot be published',
      target_release_id, latest_run_status
      USING
        ERRCODE = '55000',
        HINT = 'Only a release with no import history or a completed latest import may publish.';
  END IF;

  IF latest_run_id IS NOT NULL THEN
    PERFORM $SCHEMA$.assert_required_artifact_observations(latest_run_id);
  END IF;

  verification := $SCHEMA$.verify_release(target_release_id);

  IF NOT (verification ->> 'ok')::boolean THEN
    RAISE EXCEPTION 'release % failed verification: %',
      target_release_id, verification ->> 'failures'
      USING ERRCODE = '23514';
  END IF;

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

CREATE FUNCTION $SCHEMA$.publish_import(target_run_id uuid, target_executor_id uuid)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  target_collection_id uuid;
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['publishing']);

  UPDATE $SCHEMA$.import_run
     SET status = 'completed',
         completed_at = coalesce(completed_at, now())
   WHERE id = target_run_id;

  DELETE FROM $SCHEMA$.import_run_lease
   WHERE run_id = target_run_id;

  target_collection_id := $SCHEMA$.publish_release(target_release_id);

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

  PERFORM pg_advisory_xact_lock($SCHEMA$.publication_lock_key(collection_key));
  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  SELECT id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  -- An unrecognized collection and a collection with nothing to roll back to
  -- both leave the caller in the same position: NULL, not an error, since a
  -- caller polling "did the rollback happen" cannot tell the two apart from
  -- the collection key alone.
  IF target_collection_id IS NULL THEN
    RETURN NULL;
  END IF;

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

  PERFORM pg_advisory_xact_lock($SCHEMA$.publication_lock_key(collection_key));
  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  SELECT id INTO target_collection_id
    FROM $SCHEMA$.collection WHERE collection.key = collection_key;

  -- retire_releases reports how many releases it retired, so an unknown
  -- collection has no NULL to distinguish "found nothing to retire" from
  -- "the collection does not exist" the way a nullable uuid result would;
  -- it raises instead, matching upsert_source and the rest of the write API.
  IF target_collection_id IS NULL THEN
    RAISE EXCEPTION 'collection % does not exist', collection_key USING ERRCODE = '23503';
  END IF;

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
  manifest jsonb NOT NULL,
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

CREATE TABLE $SCHEMA$.import_run_artifact (
  run_id uuid NOT NULL REFERENCES $SCHEMA$.import_run(id) ON DELETE CASCADE,
  artifact_id uuid NOT NULL REFERENCES $SCHEMA$.artifact(id) ON DELETE RESTRICT,
  observed_sha256 text,
  observed_bytes bigint,
  validated_at timestamptz,
  CONSTRAINT import_run_artifact_pkey PRIMARY KEY (run_id, artifact_id),
  CONSTRAINT import_run_artifact_observed_sha256_chk
    CHECK (observed_sha256 IS NULL OR observed_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT import_run_artifact_observed_bytes_chk
    CHECK (observed_bytes IS NULL OR observed_bytes >= 0),
  CONSTRAINT import_run_artifact_observation_pair_chk
    CHECK ((observed_sha256 IS NULL) = (observed_bytes IS NULL)),
  CONSTRAINT import_run_artifact_validation_complete_chk
    CHECK ((validated_at IS NULL) = (observed_sha256 IS NULL))
);

--SPLIT--

CREATE FUNCTION $SCHEMA$.record_artifact_observation(
  target_run_id uuid,
  target_executor_id uuid,
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
  IF target_run_id IS NULL OR target_executor_id IS NULL OR target_artifact_id IS NULL
     OR observed_sha256 IS NULL OR observed_bytes IS NULL THEN
    RAISE EXCEPTION 'run id, artifact id, observed sha256, and observed bytes are required'
      USING ERRCODE = '22004';
  END IF;

  PERFORM $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['downloading', 'validating']);

  SELECT artifact.expected_sha256,
         artifact.expected_bytes,
         selection.observed_sha256 AS prior_sha256,
         selection.observed_bytes AS prior_bytes
    INTO expectation
    FROM $SCHEMA$.import_run_artifact selection
    JOIN $SCHEMA$.import_run ON import_run.id = selection.run_id
   JOIN $SCHEMA$.artifact ON artifact.id = selection.artifact_id
   WHERE import_run.id = target_run_id
     AND artifact.id = target_artifact_id
     FOR UPDATE OF selection, import_run;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'artifact % is not attached to import run %', target_artifact_id, target_run_id
      USING ERRCODE = '23503';
  END IF;

  IF expectation.prior_sha256 IS NOT NULL THEN
    IF lower(observed_sha256) = expectation.prior_sha256
       AND observed_bytes = expectation.prior_bytes THEN
      RETURN;
    END IF;

    RAISE EXCEPTION
      'artifact observation for run % and artifact % is immutable',
      target_run_id, target_artifact_id
      USING
        ERRCODE = '55000',
        HINT = 'Start a new import attempt to record a different observation.';
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

  UPDATE $SCHEMA$.import_run_artifact
     SET observed_sha256 = lower(record_artifact_observation.observed_sha256),
         observed_bytes = record_artifact_observation.observed_bytes,
         validated_at = now()
   WHERE run_id = target_run_id
     AND artifact_id = target_artifact_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.assert_required_artifact_observations(target_run_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  unvalidated_artifact_count bigint;
BEGIN
  IF target_run_id IS NULL THEN
    RAISE EXCEPTION 'run id is required' USING ERRCODE = '22004';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM $SCHEMA$.import_run WHERE id = target_run_id) THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id USING ERRCODE = '23503';
  END IF;

  SELECT count(*) INTO unvalidated_artifact_count
    FROM $SCHEMA$.import_run_artifact
    JOIN $SCHEMA$.artifact
      ON artifact.id = import_run_artifact.artifact_id
   WHERE import_run_artifact.run_id = target_run_id
     AND import_run_artifact.validated_at IS NULL
     AND coalesce((artifact.metadata ->> 'required')::boolean, true);

  IF unvalidated_artifact_count > 0 THEN
    RAISE EXCEPTION
      'import run % has % required selected % without validated observations',
      target_run_id,
      unvalidated_artifact_count,
      CASE unvalidated_artifact_count WHEN 1 THEN 'artifact' ELSE 'artifacts' END
      USING
        ERRCODE = '23514',
        HINT = 'Start or retry the import and record every required artifact observation during downloading or validating.';
  END IF;
END;
$fn$;

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
  executor_id uuid,
  execution_started_at timestamptz,
  progress jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT import_run_lease_release_key
    UNIQUE (release_id),
  CONSTRAINT import_run_lease_execution_pair
    CHECK ((executor_id IS NULL) = (execution_started_at IS NULL)),
  CONSTRAINT import_run_lease_progress_object
    CHECK (jsonb_typeof(progress) = 'object')
);

--SPLIT--

CREATE FUNCTION $SCHEMA$.claim_import_execution(
  target_run_id uuid,
  target_executor_id uuid
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  target_collection_key text;
  target_release_key text;
  target_status text;
  target_attempt integer;
  latest_run_id uuid;
  latest_attempt integer;
  current_executor_id uuid;
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL THEN
    RAISE EXCEPTION 'run id and executor id are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT import_run.release_id, collection.key, release.release_key
    INTO target_release_id, target_collection_key, target_release_key
    FROM $SCHEMA$.import_run
    JOIN $SCHEMA$.release ON release.id = import_run.release_id
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE import_run.id = target_run_id;

  IF NOT FOUND THEN
    RETURN 'missing';
  END IF;

  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.release_lock_key(target_collection_key, target_release_key));

  SELECT import_run.release_id, import_run.status, import_run.attempt
    INTO target_release_id, target_status, target_attempt
    FROM $SCHEMA$.import_run
    JOIN $SCHEMA$.release ON release.id = import_run.release_id
   WHERE import_run.id = target_run_id
   FOR UPDATE OF import_run, release;

  IF NOT FOUND THEN
    RETURN 'missing';
  END IF;

  SELECT import_run.id, import_run.attempt
    INTO latest_run_id, latest_attempt
    FROM $SCHEMA$.import_run
   WHERE import_run.release_id = target_release_id
   ORDER BY import_run.attempt DESC
   LIMIT 1
   FOR UPDATE;

  IF latest_run_id IS DISTINCT FROM target_run_id
     OR latest_attempt IS DISTINCT FROM target_attempt THEN
    RETURN 'superseded';
  END IF;

  IF target_status = 'completed' THEN
    RETURN 'completed';
  ELSIF target_status = 'failed' THEN
    RETURN 'failed';
  ELSIF target_status <> 'pending' THEN
    RETURN 'occupied';
  END IF;

  SELECT import_run_lease.executor_id INTO current_executor_id
    FROM $SCHEMA$.import_run_lease
   WHERE import_run_lease.run_id = target_run_id
     AND import_run_lease.release_id = target_release_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 'occupied';
  ELSIF current_executor_id = target_executor_id THEN
    RETURN 'claimed';
  ELSIF current_executor_id IS NOT NULL THEN
    RETURN 'occupied';
  END IF;

  UPDATE $SCHEMA$.import_run_lease
     SET executor_id = target_executor_id,
         execution_started_at = clock_timestamp(),
         heartbeat_at = clock_timestamp()
   WHERE run_id = target_run_id;

  RETURN 'claimed';
END;
$fn$;

--SPLIT--

-- Serializes every ingestion mutation with registration and exact reset, then
-- proves the caller still owns the one attempt allowed to write the candidate.
-- The release-key lock is derived before any row lock, matching prepare_import
-- and retry_failed, so whichever side wins the lock determines the outcome:
-- an old write completes before reset removes it, or reset completes first and
-- the old run fails the latest-attempt/lease checks below.
CREATE FUNCTION $SCHEMA$.assert_import_write(
  target_run_id uuid,
  target_executor_id uuid,
  permitted_statuses text[]
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  target_collection_key text;
  target_release_key text;
  target_status text;
  target_attempt integer;
  latest_run_id uuid;
  latest_attempt integer;
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL OR permitted_statuses IS NULL THEN
    RAISE EXCEPTION 'run id, executor id, and permitted statuses are required'
      USING ERRCODE = '22004';
  END IF;

  IF cardinality(permitted_statuses) = 0
     OR array_position(permitted_statuses, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'permitted statuses must be a non-empty array without nulls'
      USING ERRCODE = '22023';
  END IF;

  SELECT release.id, collection.key, release.release_key
    INTO target_release_id, target_collection_key, target_release_key
    FROM $SCHEMA$.import_run
    JOIN $SCHEMA$.release ON release.id = import_run.release_id
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE import_run.id = target_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id
      USING ERRCODE = '23503';
  END IF;

  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.release_lock_key(target_collection_key, target_release_key));
  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.publication_lock_key(target_collection_key));

  SELECT import_run.release_id, import_run.status, import_run.attempt
    INTO target_release_id, target_status, target_attempt
    FROM $SCHEMA$.import_run
    JOIN $SCHEMA$.release ON release.id = import_run.release_id
   WHERE import_run.id = target_run_id
   FOR UPDATE OF import_run, release;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id
      USING ERRCODE = '23503';
  END IF;

  SELECT import_run.id, import_run.attempt
    INTO latest_run_id, latest_attempt
    FROM $SCHEMA$.import_run
   WHERE import_run.release_id = target_release_id
   ORDER BY import_run.attempt DESC
   LIMIT 1
   FOR UPDATE;

  IF latest_run_id IS DISTINCT FROM target_run_id
     OR latest_attempt IS DISTINCT FROM target_attempt THEN
    RAISE EXCEPTION
      'import run % was superseded by attempt % for release %',
      target_run_id, latest_attempt, target_release_id
      USING
        ERRCODE = '55000',
        HINT = 'Only the latest claimed attempt may write the candidate.';
  END IF;

  IF NOT (target_status = ANY(permitted_statuses)) THEN
    RAISE EXCEPTION
      'import run % is % and cannot write in the permitted phases %',
      target_run_id, target_status, permitted_statuses
      USING ERRCODE = '55000';
  END IF;

  PERFORM 1
    FROM $SCHEMA$.import_run_lease
   WHERE import_run_lease.run_id = target_run_id
     AND import_run_lease.release_id = target_release_id
     AND import_run_lease.executor_id = target_executor_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'executor % does not own import run %', target_executor_id, target_run_id
      USING
        ERRCODE = '55000',
        HINT = 'Only the executor that claimed the current attempt may write the candidate.';
  END IF;

  PERFORM $SCHEMA$.assert_release_mutable(target_release_id);

  RETURN target_release_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.prepare_import(manifest jsonb, claim jsonb)
RETURNS TABLE(
  decision text,
  reason text,
  release_id uuid,
  run_id uuid,
  attempt integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_collection_key text;
  target_release_key text;
  target_owner text;
  target_runner_backend text;
  target_stale_seconds double precision;
  target_stale_after interval;
  target_source_date date;
  target_collection_id uuid;
  target_release_id uuid;
  target_run_id uuid;
  target_attempt integer;
  next_attempt integer;
  existing_release record;
  latest_run record;
  live_heartbeat_at timestamptz;
  source_entry jsonb;
  artifact_entry jsonb;
  declaration jsonb;
  existing_source record;
  existing_source_release record;
  existing_artifact record;
  target_source_id uuid;
  target_source_release_id uuid;
  target_artifact_id uuid;
  target_artifact_metadata jsonb;
BEGIN
  IF manifest IS NULL OR claim IS NULL THEN
    RAISE EXCEPTION 'manifest and claim are required' USING ERRCODE = '22004';
  END IF;

  IF jsonb_typeof(manifest) <> 'object' OR jsonb_typeof(claim) <> 'object' THEN
    RAISE EXCEPTION 'manifest and claim must be JSON objects' USING ERRCODE = '22023';
  END IF;

  target_collection_key := nullif(manifest ->> 'collection', '');
  target_release_key := nullif(manifest ->> 'release', '');
  target_owner := nullif(claim ->> 'owner', '');
  target_runner_backend := nullif(claim ->> 'runner_backend', '');

  IF target_collection_key IS NULL OR target_release_key IS NULL
     OR target_owner IS NULL OR target_runner_backend IS NULL THEN
    RAISE EXCEPTION
      'manifest collection and release plus claim owner and runner_backend are required'
      USING ERRCODE = '22004';
  END IF;

  IF jsonb_typeof(coalesce(manifest -> 'authorities', '[]'::jsonb)) <> 'array'
     OR jsonb_typeof(coalesce(manifest -> 'area_types', '[]'::jsonb)) <> 'array'
     OR jsonb_typeof(coalesce(manifest -> 'sources', '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'manifest authorities, area_types, and sources must be arrays'
      USING ERRCODE = '22023';
  END IF;

  BEGIN
    target_stale_seconds := coalesce((claim ->> 'stale_after_seconds')::double precision, 900);
    target_stale_after := make_interval(secs => target_stale_seconds);
    target_source_date := nullif(manifest ->> 'source_date', '')::date;
  EXCEPTION
    WHEN invalid_text_representation OR datetime_field_overflow THEN
      RAISE EXCEPTION 'claim stale_after_seconds and manifest source_date must be valid values'
        USING ERRCODE = '22023';
  END;

  IF target_stale_seconds <= 0
     OR target_stale_seconds IN (
       'Infinity'::double precision,
       '-Infinity'::double precision,
       'NaN'::double precision
     ) THEN
    RAISE EXCEPTION 'stale_after_seconds must be a finite positive number'
      USING ERRCODE = '22023';
  END IF;

  -- Lock identities derive only from immutable text and are therefore
  -- available before either catalog row exists. No row lock is taken before
  -- the complete universal advisory-lock prefix is held.
  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.release_lock_key(target_collection_key, target_release_key));
  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.publication_lock_key(target_collection_key));
  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  SELECT collection.id INTO target_collection_id
    FROM $SCHEMA$.collection
   WHERE collection.key = target_collection_key;

  IF target_collection_id IS NOT NULL THEN
    SELECT release.* INTO existing_release
      FROM $SCHEMA$.release
     WHERE release.collection_id = target_collection_id
       AND release.release_key = target_release_key
     FOR UPDATE;

    IF FOUND THEN
      target_release_id := existing_release.id;

      IF existing_release.retired_at IS NOT NULL
         OR existing_release.status = 'completed'
         OR EXISTS (
           SELECT 1 FROM $SCHEMA$.publication
            WHERE publication.collection_id = target_collection_id
              AND (
                publication.release_id = target_release_id
                OR publication.previous_release_id = target_release_id
              )
         )
         OR EXISTS (
           SELECT 1 FROM $SCHEMA$.publication_event
            WHERE publication_event.release_id = target_release_id
         ) THEN
        decision := 'error';
        reason := 'protected';
        release_id := target_release_id;
        RETURN NEXT;
        RETURN;
      END IF;

      SELECT import_run.* INTO latest_run
        FROM $SCHEMA$.import_run
       WHERE import_run.release_id = target_release_id
       ORDER BY import_run.attempt DESC
       LIMIT 1
       FOR UPDATE;

      IF NOT FOUND THEN
        decision := 'error';
        reason := 'orphan_candidate';
        release_id := target_release_id;
        RETURN NEXT;
        RETURN;
      END IF;

      target_run_id := latest_run.id;
      target_attempt := latest_run.attempt;

      IF latest_run.status NOT IN ('completed', 'failed') THEN
        SELECT import_run_lease.heartbeat_at INTO live_heartbeat_at
          FROM $SCHEMA$.import_run_lease
         WHERE import_run_lease.run_id = target_run_id
         FOR UPDATE;

        IF NOT FOUND
           OR live_heartbeat_at <= clock_timestamp() - target_stale_after THEN
          decision := 'error';
          reason := 'stale_import';
          release_id := target_release_id;
          run_id := target_run_id;
          attempt := target_attempt;
          RETURN NEXT;
          RETURN;
        END IF;

        IF latest_run.owner = target_owner
           AND latest_run.manifest IS NOT DISTINCT FROM manifest
           AND existing_release.manifest IS NOT DISTINCT FROM manifest THEN
          decision := 'enqueue';
          reason := 'same_owner';
          release_id := target_release_id;
          run_id := target_run_id;
          attempt := target_attempt;
          RETURN NEXT;
          RETURN;
        END IF;

        decision := 'error';
        reason := 'live_import';
        release_id := target_release_id;
        run_id := target_run_id;
        attempt := target_attempt;
        RETURN NEXT;
        RETURN;
      ELSIF latest_run.status = 'completed' THEN
        IF latest_run.manifest IS NOT DISTINCT FROM manifest
           AND existing_release.manifest IS NOT DISTINCT FROM manifest THEN
          decision := 'existing';
          reason := 'completed';
          release_id := target_release_id;
          run_id := target_run_id;
          attempt := target_attempt;
          RETURN NEXT;
          RETURN;
        END IF;

        decision := 'error';
        reason := 'manifest_changed';
        release_id := target_release_id;
        run_id := target_run_id;
        attempt := target_attempt;
        RETURN NEXT;
        RETURN;
      ELSIF latest_run.status = 'failed' THEN
        decision := 'error';
        reason := CASE
          WHEN latest_run.manifest IS DISTINCT FROM manifest
            OR existing_release.manifest IS DISTINCT FROM manifest
          THEN 'manifest_changed'
          ELSE 'failed'
        END;
        release_id := target_release_id;
        run_id := target_run_id;
        attempt := target_attempt;
        RETURN NEXT;
        RETURN;
      ELSE
        RAISE EXCEPTION
          'import run % has unsupported status %', latest_run.id, latest_run.status
          USING ERRCODE = '55000';
      END IF;
    END IF;
  END IF;

  -- Semantic source identities are globally immutable. Inspect every source,
  -- source release, and artifact before the first write so a conflict returns
  -- a structured decision without leaving partial registration behind.
  FOR source_entry IN
    SELECT value FROM jsonb_array_elements(coalesce(manifest -> 'sources', '[]'::jsonb))
  LOOP
    IF nullif(source_entry ->> 'source_key', '') IS NULL
       OR nullif(coalesce(source_entry ->> 'provider', manifest ->> 'provider'), '') IS NULL
       OR nullif(source_entry ->> 'license', '') IS NULL
       OR nullif(source_entry ->> 'release_key', '') IS NULL
       OR jsonb_typeof(coalesce(source_entry -> 'artifacts', '[]'::jsonb)) <> 'array' THEN
      RAISE EXCEPTION 'each source requires source_key, provider, license, release_key, and artifacts'
        USING ERRCODE = '22023';
    END IF;

    SELECT source.*, collection.key AS collection_key INTO existing_source
      FROM $SCHEMA$.source
      JOIN $SCHEMA$.collection ON collection.id = source.collection_id
     WHERE collection.key = target_collection_key
       AND source.source_key = source_entry ->> 'source_key';

    IF FOUND AND (
      existing_source.provider IS DISTINCT FROM
        coalesce(source_entry ->> 'provider', manifest ->> 'provider')
      OR existing_source.license IS DISTINCT FROM source_entry ->> 'license'
    ) THEN
      decision := 'error';
      reason := 'source_definition_changed';
      release_id := target_release_id;
      run_id := target_run_id;
      attempt := target_attempt;
      RETURN NEXT;
      RETURN;
    END IF;

    IF FOUND THEN
      SELECT source_release.* INTO existing_source_release
        FROM $SCHEMA$.source_release
       WHERE source_release.source_id = existing_source.id
         AND source_release.release_key = source_entry ->> 'release_key';

      IF FOUND AND (
        existing_source_release.source_date IS DISTINCT FROM
          nullif(source_entry ->> 'source_date', '')::date
        OR existing_source_release.metadata IS DISTINCT FROM '{}'::jsonb
      ) THEN
        decision := 'error';
        reason := 'source_definition_changed';
        release_id := target_release_id;
        run_id := target_run_id;
        attempt := target_attempt;
        RETURN NEXT;
        RETURN;
      END IF;

      IF FOUND THEN
        FOR artifact_entry IN
          SELECT value FROM jsonb_array_elements(
            coalesce(source_entry -> 'artifacts', '[]'::jsonb))
        LOOP
          target_artifact_metadata :=
            coalesce(artifact_entry -> 'metadata', '{}'::jsonb)
            || CASE
                 WHEN artifact_entry ? 'cache_key'
                   THEN jsonb_build_object('cache_key', artifact_entry -> 'cache_key')
                 ELSE '{}'::jsonb
               END
            || jsonb_build_object(
                 'members', coalesce(artifact_entry -> 'members', '[]'::jsonb),
                 'required', coalesce((artifact_entry ->> 'required')::boolean, true)
               );

          SELECT artifact.* INTO existing_artifact
            FROM $SCHEMA$.artifact
           WHERE artifact.source_release_id = existing_source_release.id
             AND artifact.logical_name = artifact_entry ->> 'logical_name';

          IF FOUND AND (
            existing_artifact.url IS DISTINCT FROM artifact_entry ->> 'url'
            OR existing_artifact.operator_supplied IS DISTINCT FROM
              coalesce((artifact_entry ->> 'operator_supplied')::boolean, false)
            OR existing_artifact.format IS DISTINCT FROM artifact_entry ->> 'format'
            OR existing_artifact.expected_sha256 IS DISTINCT FROM lower(artifact_entry ->> 'sha256')
            OR existing_artifact.expected_bytes IS DISTINCT FROM (artifact_entry ->> 'bytes')::bigint
            OR existing_artifact.metadata IS DISTINCT FROM target_artifact_metadata
          ) THEN
            decision := 'error';
            reason := 'source_definition_changed';
            release_id := target_release_id;
            run_id := target_run_id;
            attempt := target_attempt;
            RETURN NEXT;
            RETURN;
          END IF;
        END LOOP;
      END IF;
    END IF;
  END LOOP;

  PERFORM $SCHEMA$.upsert_collection(
      target_collection_key,
      coalesce(nullif(manifest ->> 'collection_name', ''), target_collection_key),
      manifest ->> 'description',
      coalesce((manifest ->> 'requires_geometry')::boolean, false));

    FOR declaration IN
      SELECT value FROM jsonb_array_elements(coalesce(manifest -> 'authorities', '[]'::jsonb))
    LOOP
      PERFORM $SCHEMA$.upsert_authority(
        target_collection_key, declaration ->> 'key', declaration ->> 'name');
    END LOOP;

    FOR declaration IN
      SELECT value FROM jsonb_array_elements(coalesce(manifest -> 'area_types', '[]'::jsonb))
    LOOP
      PERFORM $SCHEMA$.upsert_area_type(
        target_collection_key,
        declaration ->> 'key',
        (declaration ->> 'rank')::integer,
        coalesce((declaration ->> 'requires_geometry')::boolean, false));
    END LOOP;

    target_release_id := $SCHEMA$.open_release(
      target_collection_key, target_release_key, manifest, target_source_date);

    -- The former in-place reset branch is gone. Failed candidates are
    -- replaced only by retry_failed. The rest of this function registers a
    -- new candidate.

  -- Sources and artifacts are immutable definitions already proven safe
  -- above; these calls therefore take only their identical/insert branches.
  FOR source_entry IN
    SELECT value FROM jsonb_array_elements(coalesce(manifest -> 'sources', '[]'::jsonb))
  LOOP
    target_source_id := $SCHEMA$.upsert_source(
      target_collection_key,
      source_entry ->> 'source_key',
      coalesce(source_entry ->> 'provider', manifest ->> 'provider'),
      source_entry ->> 'license');

    target_source_release_id := $SCHEMA$.upsert_source_release(
      target_collection_key,
      source_entry ->> 'source_key',
      source_entry ->> 'release_key',
      nullif(source_entry ->> 'source_date', '')::date,
      '{}'::jsonb);

    PERFORM $SCHEMA$.attach_source_release(target_release_id, target_source_release_id);

    FOR artifact_entry IN
      SELECT value FROM jsonb_array_elements(coalesce(source_entry -> 'artifacts', '[]'::jsonb))
    LOOP
      target_artifact_metadata :=
        coalesce(artifact_entry -> 'metadata', '{}'::jsonb)
        || CASE
             WHEN artifact_entry ? 'cache_key'
               THEN jsonb_build_object('cache_key', artifact_entry -> 'cache_key')
             ELSE '{}'::jsonb
           END
        || jsonb_build_object(
             'members', coalesce(artifact_entry -> 'members', '[]'::jsonb),
             'required', coalesce((artifact_entry ->> 'required')::boolean, true)
           );

      target_artifact_id := $SCHEMA$.put_artifact(
        target_source_release_id,
        artifact_entry ->> 'logical_name',
        artifact_entry ->> 'url',
        coalesce((artifact_entry ->> 'operator_supplied')::boolean, false),
        artifact_entry ->> 'format',
        artifact_entry ->> 'sha256',
        (artifact_entry ->> 'bytes')::bigint,
        target_artifact_metadata);

      PERFORM $SCHEMA$.attach_artifact(target_release_id, target_artifact_id);
    END LOOP;
  END LOOP;

  SELECT coalesce(max(import_run.attempt), 0) + 1 INTO next_attempt
    FROM $SCHEMA$.import_run
   WHERE import_run.release_id = target_release_id;

  INSERT INTO $SCHEMA$.import_run
    (release_id, attempt, owner, runner_backend, manifest)
  VALUES
    (target_release_id, next_attempt, target_owner, target_runner_backend, manifest)
  RETURNING id INTO target_run_id;

  INSERT INTO $SCHEMA$.import_run_artifact (run_id, artifact_id)
  SELECT target_run_id, release_artifact.artifact_id
    FROM $SCHEMA$.release_artifact
   WHERE release_artifact.release_id = target_release_id;

  INSERT INTO $SCHEMA$.import_run_lease (run_id, release_id)
  VALUES (target_run_id, target_release_id);

  decision := 'enqueue';
  reason := 'registered';
  release_id := target_release_id;
  run_id := target_run_id;
  attempt := next_attempt;
  RETURN NEXT;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.retry_failed(failed_run_id uuid, manifest jsonb, claim jsonb)
RETURNS TABLE(
  decision text,
  reason text,
  release_id uuid,
  run_id uuid,
  attempt integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_collection_key text;
  target_release_key text;
  target_owner text;
  target_runner_backend text;
  target_stale_seconds double precision;
  target_source_date date;
  target_collection_id uuid;
  target_release_id uuid;
  target_run_id uuid;
  next_attempt integer;
  failed_run record;
  latest_run record;
  source_entry jsonb;
  artifact_entry jsonb;
  declaration jsonb;
  existing_source record;
  existing_source_release record;
  existing_artifact record;
  target_source_release_id uuid;
  target_artifact_id uuid;
  target_artifact_metadata jsonb;
  candidate_area_ids uuid[] := ARRAY[]::uuid[];
  terminal_run_id uuid;
  suffix text;
  parent text;
BEGIN
  IF failed_run_id IS NULL OR manifest IS NULL OR claim IS NULL THEN
    RAISE EXCEPTION 'failed run id, manifest, and claim are required' USING ERRCODE = '22004';
  END IF;

  IF jsonb_typeof(manifest) <> 'object' OR jsonb_typeof(claim) <> 'object' THEN
    RAISE EXCEPTION 'manifest and claim must be JSON objects' USING ERRCODE = '22023';
  END IF;

  target_collection_key := nullif(manifest ->> 'collection', '');
  target_release_key := nullif(manifest ->> 'release', '');
  target_owner := nullif(claim ->> 'owner', '');
  target_runner_backend := nullif(claim ->> 'runner_backend', '');

  IF target_collection_key IS NULL OR target_release_key IS NULL
     OR target_owner IS NULL OR target_runner_backend IS NULL THEN
    RAISE EXCEPTION
      'manifest collection and release plus claim owner and runner_backend are required'
      USING ERRCODE = '22004';
  END IF;

  IF jsonb_typeof(coalesce(manifest -> 'authorities', '[]'::jsonb)) <> 'array'
     OR jsonb_typeof(coalesce(manifest -> 'area_types', '[]'::jsonb)) <> 'array'
     OR jsonb_typeof(coalesce(manifest -> 'sources', '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'manifest authorities, area_types, and sources must be arrays'
      USING ERRCODE = '22023';
  END IF;

  BEGIN
    target_stale_seconds := coalesce((claim ->> 'stale_after_seconds')::double precision, 900);
    target_source_date := nullif(manifest ->> 'source_date', '')::date;
  EXCEPTION
    WHEN invalid_text_representation OR datetime_field_overflow THEN
      RAISE EXCEPTION 'claim stale_after_seconds and manifest source_date must be valid values'
        USING ERRCODE = '22023';
  END;

  IF target_stale_seconds <= 0
     OR target_stale_seconds IN (
       'Infinity'::double precision,
       '-Infinity'::double precision,
       'NaN'::double precision
     ) THEN
    RAISE EXCEPTION 'stale_after_seconds must be a finite positive number'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.release_lock_key(target_collection_key, target_release_key));
  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.publication_lock_key(target_collection_key));
  PERFORM pg_advisory_xact_lock($SCHEMA$.partition_lock_key());

  SELECT import_run.*,
         release.id AS candidate_release_id,
         release.collection_id AS candidate_collection_id,
         release.release_key AS candidate_release_key,
         release.status AS candidate_release_status,
         release.retired_at AS candidate_retired_at,
         collection.key AS candidate_collection_key
    INTO failed_run
    FROM $SCHEMA$.import_run
    JOIN $SCHEMA$.release ON release.id = import_run.release_id
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE import_run.id = failed_run_id
   FOR UPDATE OF import_run, release;

  IF NOT FOUND THEN
    decision := 'error';
    reason := 'not_found';
    run_id := failed_run_id;
    RETURN NEXT;
    RETURN;
  END IF;

  target_collection_id := failed_run.candidate_collection_id;
  target_release_id := failed_run.candidate_release_id;
  target_run_id := failed_run.id;

  IF failed_run.candidate_collection_key IS DISTINCT FROM target_collection_key
     OR failed_run.candidate_release_key IS DISTINCT FROM target_release_key THEN
    decision := 'error';
    reason := 'candidate_mismatch';
    release_id := target_release_id;
    run_id := target_run_id;
    attempt := failed_run.attempt;
    RETURN NEXT;
    RETURN;
  END IF;

  IF failed_run.candidate_retired_at IS NOT NULL
     OR failed_run.candidate_release_status = 'completed'
     OR EXISTS (
       SELECT 1 FROM $SCHEMA$.publication
        WHERE publication.collection_id = target_collection_id
          AND (
            publication.release_id = target_release_id
            OR publication.previous_release_id = target_release_id
          )
     )
     OR EXISTS (
       SELECT 1 FROM $SCHEMA$.publication_event
        WHERE publication_event.release_id = target_release_id
     ) THEN
    decision := 'error';
    reason := 'protected';
    release_id := target_release_id;
    run_id := target_run_id;
    attempt := failed_run.attempt;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT import_run.* INTO latest_run
    FROM $SCHEMA$.import_run
   WHERE import_run.release_id = target_release_id
   ORDER BY import_run.attempt DESC
   LIMIT 1
   FOR UPDATE;

  IF latest_run.id <> failed_run_id THEN
    -- A previous retry_failed can commit the successor and lose its reply.
    -- Replaying against the same predecessor returns that successor instead
    -- of minting a third attempt.
    IF latest_run.attempt = failed_run.attempt + 1
       AND latest_run.status NOT IN ('completed', 'failed')
       AND latest_run.owner = target_owner
       AND latest_run.manifest IS NOT DISTINCT FROM manifest THEN
      decision := 'enqueue';
      reason := 'retried';
      release_id := target_release_id;
      run_id := latest_run.id;
      attempt := latest_run.attempt;
      RETURN NEXT;
      RETURN;
    END IF;

    decision := 'error';
    reason := 'not_latest_attempt';
    release_id := target_release_id;
    run_id := target_run_id;
    attempt := failed_run.attempt;
    RETURN NEXT;
    RETURN;
  END IF;

  IF failed_run.status <> 'failed' THEN
    decision := 'error';
    reason := 'not_failed';
    release_id := target_release_id;
    run_id := target_run_id;
    attempt := failed_run.attempt;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Preflight all immutable definitions before exact reset performs its first
  -- write. A corrected candidate may select a different artifact set, but it
  -- may not redefine a semantic source identity in place.
  FOR source_entry IN
    SELECT value FROM jsonb_array_elements(coalesce(manifest -> 'sources', '[]'::jsonb))
  LOOP
    IF nullif(source_entry ->> 'source_key', '') IS NULL
       OR nullif(coalesce(source_entry ->> 'provider', manifest ->> 'provider'), '') IS NULL
       OR nullif(source_entry ->> 'license', '') IS NULL
       OR nullif(source_entry ->> 'release_key', '') IS NULL
       OR jsonb_typeof(coalesce(source_entry -> 'artifacts', '[]'::jsonb)) <> 'array' THEN
      RAISE EXCEPTION 'each source requires source_key, provider, license, release_key, and artifacts'
        USING ERRCODE = '22023';
    END IF;

    SELECT source.*, collection.key AS collection_key INTO existing_source
      FROM $SCHEMA$.source
      JOIN $SCHEMA$.collection ON collection.id = source.collection_id
     WHERE collection.key = target_collection_key
       AND source.source_key = source_entry ->> 'source_key';

    IF FOUND AND (
      existing_source.provider IS DISTINCT FROM
        coalesce(source_entry ->> 'provider', manifest ->> 'provider')
      OR existing_source.license IS DISTINCT FROM source_entry ->> 'license'
    ) THEN
      decision := 'error';
      reason := 'source_definition_changed';
      release_id := target_release_id;
      run_id := target_run_id;
      attempt := failed_run.attempt;
      RETURN NEXT;
      RETURN;
    END IF;

    IF FOUND THEN
      SELECT source_release.* INTO existing_source_release
        FROM $SCHEMA$.source_release
       WHERE source_release.source_id = existing_source.id
         AND source_release.release_key = source_entry ->> 'release_key';

      IF FOUND AND (
        existing_source_release.source_date IS DISTINCT FROM
          nullif(source_entry ->> 'source_date', '')::date
        OR existing_source_release.metadata IS DISTINCT FROM '{}'::jsonb
      ) THEN
        decision := 'error';
        reason := 'source_definition_changed';
        release_id := target_release_id;
        run_id := target_run_id;
        attempt := failed_run.attempt;
        RETURN NEXT;
        RETURN;
      END IF;

      IF FOUND THEN
        FOR artifact_entry IN
          SELECT value FROM jsonb_array_elements(
            coalesce(source_entry -> 'artifacts', '[]'::jsonb))
        LOOP
          target_artifact_metadata :=
            coalesce(artifact_entry -> 'metadata', '{}'::jsonb)
            || CASE
                 WHEN artifact_entry ? 'cache_key'
                   THEN jsonb_build_object('cache_key', artifact_entry -> 'cache_key')
                 ELSE '{}'::jsonb
               END
            || jsonb_build_object(
                 'members', coalesce(artifact_entry -> 'members', '[]'::jsonb),
                 'required', coalesce((artifact_entry ->> 'required')::boolean, true)
               );

          SELECT artifact.* INTO existing_artifact
            FROM $SCHEMA$.artifact
           WHERE artifact.source_release_id = existing_source_release.id
             AND artifact.logical_name = artifact_entry ->> 'logical_name';

          IF FOUND AND (
            existing_artifact.url IS DISTINCT FROM artifact_entry ->> 'url'
            OR existing_artifact.operator_supplied IS DISTINCT FROM
              coalesce((artifact_entry ->> 'operator_supplied')::boolean, false)
            OR existing_artifact.format IS DISTINCT FROM artifact_entry ->> 'format'
            OR existing_artifact.expected_sha256 IS DISTINCT FROM lower(artifact_entry ->> 'sha256')
            OR existing_artifact.expected_bytes IS DISTINCT FROM (artifact_entry ->> 'bytes')::bigint
            OR existing_artifact.metadata IS DISTINCT FROM target_artifact_metadata
          ) THEN
            decision := 'error';
            reason := 'source_definition_changed';
            release_id := target_release_id;
            run_id := target_run_id;
            attempt := failed_run.attempt;
            RETURN NEXT;
            RETURN;
          END IF;
        END LOOP;
      END IF;
    END IF;
  END LOOP;

  SELECT coalesce(array_agg(candidate.area_id), ARRAY[]::uuid[])
    INTO candidate_area_ids
    FROM (
      SELECT release_area.area_id
        FROM $SCHEMA$.release_area
       WHERE release_area.release_id = target_release_id
      UNION
      SELECT boundary.area_id
        FROM $SCHEMA$.boundary
       WHERE boundary.release_id = target_release_id
      UNION
      SELECT boundary_part.area_id
        FROM $SCHEMA$.boundary_part
       WHERE boundary_part.release_id = target_release_id
      UNION
      SELECT relation.parent_area_id
        FROM $SCHEMA$.relation
       WHERE relation.release_id = target_release_id
      UNION
      SELECT relation.child_area_id
        FROM $SCHEMA$.relation
       WHERE relation.release_id = target_release_id
      UNION
      SELECT area_name.area_id
        FROM $SCHEMA$.release_area_name
        JOIN $SCHEMA$.area_name ON area_name.id = release_area_name.area_name_id
       WHERE release_area_name.release_id = target_release_id
      UNION
      SELECT area_code.area_id
        FROM $SCHEMA$.release_area_code
        JOIN $SCHEMA$.area_code ON area_code.id = release_area_code.area_code_id
       WHERE release_area_code.release_id = target_release_id
    ) candidate;

  FOR terminal_run_id IN
    SELECT import_run.id
      FROM $SCHEMA$.import_run
     WHERE import_run.release_id = target_release_id
       AND import_run.status IN ('completed', 'failed')
  LOOP
    EXECUTE format(
      'DROP TABLE IF EXISTS $SCHEMA$.%I',
      'staging_' || replace(terminal_run_id::text, '-', '')
    );
  END LOOP;

  suffix := replace(target_release_id::text, '-', '');
  FOREACH parent IN ARRAY ARRAY['release_area', 'relation', 'boundary_part', 'boundary'] LOOP
    EXECUTE format('DROP TABLE IF EXISTS $SCHEMA$.%I', parent || '_' || suffix);
  END LOOP;

  DELETE FROM $SCHEMA$.release_area_name AS selected
   WHERE selected.release_id = target_release_id;
  DELETE FROM $SCHEMA$.release_area_code AS selected
   WHERE selected.release_id = target_release_id;
  DELETE FROM $SCHEMA$.release_artifact AS selected
   WHERE selected.release_id = target_release_id;
  DELETE FROM $SCHEMA$.release_source AS selected
   WHERE selected.release_id = target_release_id;
  DELETE FROM $SCHEMA$.release_area_type AS selected
   WHERE selected.release_id = target_release_id;
  DELETE FROM $SCHEMA$.release_authority AS selected
   WHERE selected.release_id = target_release_id;
  DELETE FROM $SCHEMA$.release_collection_policy AS selected
   WHERE selected.release_id = target_release_id;

  DELETE FROM $SCHEMA$.area_name
   WHERE area_name.area_id = ANY(candidate_area_ids)
     AND NOT EXISTS (
     SELECT 1 FROM $SCHEMA$.release_area_name
      WHERE release_area_name.area_name_id = area_name.id);
  DELETE FROM $SCHEMA$.area_code
   WHERE area_code.area_id = ANY(candidate_area_ids)
     AND NOT EXISTS (
     SELECT 1 FROM $SCHEMA$.release_area_code
      WHERE release_area_code.area_code_id = area_code.id);
  DELETE FROM $SCHEMA$.area
   WHERE area.id = ANY(candidate_area_ids)
     AND area.collection_id = target_collection_id
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.release_area
        WHERE release_area.area_id = area.id)
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.boundary
        WHERE boundary.area_id = area.id)
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.boundary_part
        WHERE boundary_part.area_id = area.id)
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.relation
        WHERE relation.parent_area_id = area.id
           OR relation.child_area_id = area.id)
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.area_name WHERE area_name.area_id = area.id)
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.area_code WHERE area_code.area_id = area.id)
     AND NOT EXISTS (
       SELECT 1 FROM $SCHEMA$.area AS successor
        WHERE successor.successor_id = area.id);

  UPDATE $SCHEMA$.release
     SET manifest = retry_failed.manifest,
         source_date = target_source_date,
         status = 'pending',
         completed_at = NULL
   WHERE id = target_release_id;

  FOREACH parent IN ARRAY ARRAY['boundary', 'boundary_part', 'relation', 'release_area'] LOOP
    EXECUTE format(
      'CREATE TABLE $SCHEMA$.%I PARTITION OF $SCHEMA$.%I FOR VALUES IN (%L)',
      parent || '_' || suffix,
      parent,
      target_release_id
    );
  END LOOP;

  FOR declaration IN
    SELECT value FROM jsonb_array_elements(coalesce(manifest -> 'authorities', '[]'::jsonb))
  LOOP
    PERFORM $SCHEMA$.upsert_authority(
      target_collection_key, declaration ->> 'key', declaration ->> 'name');
  END LOOP;

  FOR declaration IN
    SELECT value FROM jsonb_array_elements(coalesce(manifest -> 'area_types', '[]'::jsonb))
  LOOP
    PERFORM $SCHEMA$.upsert_area_type(
      target_collection_key,
      declaration ->> 'key',
      (declaration ->> 'rank')::integer,
      coalesce((declaration ->> 'requires_geometry')::boolean, false));
  END LOOP;

  INSERT INTO $SCHEMA$.release_collection_policy
    (release_id, name, description, requires_geometry)
  VALUES (
    target_release_id,
    coalesce(nullif(manifest ->> 'collection_name', ''), target_collection_key),
    manifest ->> 'description',
    coalesce((manifest ->> 'requires_geometry')::boolean, false)
  );

  INSERT INTO $SCHEMA$.release_authority (release_id, authority_id, name)
  SELECT target_release_id, authority.id, manifest_authority.value ->> 'name'
    FROM jsonb_array_elements(coalesce(manifest -> 'authorities', '[]'::jsonb))
           AS manifest_authority(value)
    JOIN $SCHEMA$.authority
      ON authority.collection_id = target_collection_id
     AND authority.key = manifest_authority.value ->> 'key';

  INSERT INTO $SCHEMA$.release_area_type
    (release_id, area_type_id, rank, requires_geometry)
  SELECT target_release_id, area_type.id, (manifest_area_type.value ->> 'rank')::integer,
         coalesce((manifest_area_type.value ->> 'requires_geometry')::boolean, false)
    FROM jsonb_array_elements(coalesce(manifest -> 'area_types', '[]'::jsonb))
           AS manifest_area_type(value)
    JOIN $SCHEMA$.area_type
      ON area_type.collection_id = target_collection_id
     AND area_type.key = manifest_area_type.value ->> 'key';

  FOR source_entry IN
    SELECT value FROM jsonb_array_elements(coalesce(manifest -> 'sources', '[]'::jsonb))
  LOOP
    PERFORM $SCHEMA$.upsert_source(
      target_collection_key,
      source_entry ->> 'source_key',
      coalesce(source_entry ->> 'provider', manifest ->> 'provider'),
      source_entry ->> 'license');

    target_source_release_id := $SCHEMA$.upsert_source_release(
      target_collection_key,
      source_entry ->> 'source_key',
      source_entry ->> 'release_key',
      nullif(source_entry ->> 'source_date', '')::date,
      '{}'::jsonb);

    PERFORM $SCHEMA$.attach_source_release(target_release_id, target_source_release_id);

    FOR artifact_entry IN
      SELECT value FROM jsonb_array_elements(coalesce(source_entry -> 'artifacts', '[]'::jsonb))
    LOOP
      target_artifact_metadata :=
        coalesce(artifact_entry -> 'metadata', '{}'::jsonb)
        || CASE
             WHEN artifact_entry ? 'cache_key'
               THEN jsonb_build_object('cache_key', artifact_entry -> 'cache_key')
             ELSE '{}'::jsonb
           END
        || jsonb_build_object(
             'members', coalesce(artifact_entry -> 'members', '[]'::jsonb),
             'required', coalesce((artifact_entry ->> 'required')::boolean, true)
           );

      target_artifact_id := $SCHEMA$.put_artifact(
        target_source_release_id,
        artifact_entry ->> 'logical_name',
        artifact_entry ->> 'url',
        coalesce((artifact_entry ->> 'operator_supplied')::boolean, false),
        artifact_entry ->> 'format',
        artifact_entry ->> 'sha256',
        (artifact_entry ->> 'bytes')::bigint,
        target_artifact_metadata);

      PERFORM $SCHEMA$.attach_artifact(target_release_id, target_artifact_id);
    END LOOP;
  END LOOP;

  SELECT coalesce(max(import_run.attempt), 0) + 1 INTO next_attempt
    FROM $SCHEMA$.import_run
   WHERE import_run.release_id = target_release_id;

  INSERT INTO $SCHEMA$.import_run
    (release_id, attempt, owner, runner_backend, manifest)
  VALUES
    (target_release_id, next_attempt, target_owner, target_runner_backend, manifest)
  RETURNING id INTO target_run_id;

  INSERT INTO $SCHEMA$.import_run_artifact (run_id, artifact_id)
  SELECT target_run_id, release_artifact.artifact_id
    FROM $SCHEMA$.release_artifact
   WHERE release_artifact.release_id = target_release_id;

  INSERT INTO $SCHEMA$.import_run_lease (run_id, release_id)
  VALUES (target_run_id, target_release_id);

  decision := 'enqueue';
  reason := 'retried';
  release_id := target_release_id;
  run_id := target_run_id;
  attempt := next_attempt;
  RETURN NEXT;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.heartbeat_import(
  target_run_id uuid,
  target_executor_id uuid,
  progress_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL THEN
    RAISE EXCEPTION 'run id and executor id are required' USING ERRCODE = '22004';
  END IF;

  UPDATE $SCHEMA$.import_run_lease
     SET heartbeat_at = clock_timestamp(),
         progress = progress || coalesce(progress_patch, '{}'::jsonb)
   WHERE run_id = target_run_id
     AND executor_id = target_executor_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'executor % does not own import run %', target_executor_id, target_run_id
      USING ERRCODE = '55000';
  END IF;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.advance_import(
  target_run_id uuid,
  target_executor_id uuid,
  next_status text,
  metrics_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  current_status text;
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL OR next_status IS NULL THEN
    RAISE EXCEPTION 'run id, executor id, and next status are required' USING ERRCODE = '22004';
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

  PERFORM $SCHEMA$.assert_import_write(
    target_run_id,
    target_executor_id,
    ARRAY[
      'pending',
      'downloading',
      'validating',
      'staging',
      'normalizing',
      'relating',
      'indexing',
      'verifying',
      'publishing'
    ]);

  SELECT status INTO current_status
    FROM $SCHEMA$.import_run WHERE id = target_run_id;

  IF next_status IS DISTINCT FROM (CASE current_status
         WHEN 'pending' THEN 'downloading'
         WHEN 'downloading' THEN 'validating'
         WHEN 'validating' THEN 'staging'
         WHEN 'staging' THEN 'normalizing'
         WHEN 'normalizing' THEN 'relating'
         WHEN 'relating' THEN 'indexing'
         WHEN 'indexing' THEN 'verifying'
         WHEN 'verifying' THEN 'publishing'
       END) THEN
    RAISE EXCEPTION
      'import run % cannot advance from % to %', target_run_id, current_status, next_status
      USING
        ERRCODE = '55000',
        HINT = 'Advance each import phase in order; use complete_import, fail_import, or publish_import to terminalize the attempt.';
  END IF;

  UPDATE $SCHEMA$.import_run
     SET status = next_status,
         stage_metrics = stage_metrics || coalesce(metrics_patch, '{}'::jsonb)
   WHERE id = target_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id USING ERRCODE = '23503';
  END IF;

  UPDATE $SCHEMA$.import_run_lease
     SET heartbeat_at = clock_timestamp()
   WHERE run_id = target_run_id;
END;
$fn$;

--SPLIT--

-- Completes a verified candidate without publishing it. The caller's final
-- phase metrics land in the same transaction as both terminal status writes,
-- so a rejected artifact or verification gate cannot leave partial metrics.
CREATE FUNCTION $SCHEMA$.complete_import(
  target_run_id uuid,
  target_executor_id uuid,
  metrics_patch jsonb
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  verification jsonb;
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['verifying']);

  PERFORM $SCHEMA$.assert_required_artifact_observations(target_run_id);

  verification := $SCHEMA$.verify_release(target_release_id);

  IF NOT (verification ->> 'ok')::boolean THEN
    RAISE EXCEPTION 'release % failed verification: %',
      target_release_id, verification ->> 'failures'
      USING ERRCODE = '23514';
  END IF;

  UPDATE $SCHEMA$.release
     SET status = 'completed', completed_at = coalesce(completed_at, now())
   WHERE id = target_release_id;

  UPDATE $SCHEMA$.import_run
     SET status = 'completed',
         completed_at = coalesce(completed_at, now()),
         stage_metrics = stage_metrics || coalesce(metrics_patch, '{}'::jsonb)
   WHERE id = target_run_id;

  DELETE FROM $SCHEMA$.import_run_lease WHERE run_id = target_run_id;

  RETURN target_release_id;
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.fail_import(
  target_run_id uuid,
  target_executor_id uuid,
  error_detail jsonb
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
  target_collection_key text;
  target_release_key text;
  current_status text;
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL THEN
    RAISE EXCEPTION 'run id and executor id are required' USING ERRCODE = '22004';
  END IF;

  -- Derive the universal lock identity without taking a row lock. Registration,
  -- retry, publication, and every attempt-fenced writer acquire this same
  -- release/publication prefix before touching catalog rows, so the winner
  -- determines the terminal outcome without a publication/failure deadlock.
  SELECT import_run.release_id, collection.key, release.release_key
    INTO target_release_id, target_collection_key, target_release_key
    FROM $SCHEMA$.import_run
    JOIN $SCHEMA$.release ON release.id = import_run.release_id
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
   WHERE import_run.id = target_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id USING ERRCODE = '23503';
  END IF;

  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.release_lock_key(target_collection_key, target_release_key));
  PERFORM pg_advisory_xact_lock(
    $SCHEMA$.publication_lock_key(target_collection_key));

  -- Re-read after the advisory locks and hold the run/release rows through the
  -- terminal update. A publisher or another failure reporter may have won
  -- while the lock was pending; that committed state is authoritative.
  SELECT import_run.release_id, import_run.status
    INTO target_release_id, current_status
    FROM $SCHEMA$.import_run
    JOIN $SCHEMA$.release ON release.id = import_run.release_id
   WHERE import_run.id = target_run_id
   FOR UPDATE OF import_run, release;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id USING ERRCODE = '23503';
  END IF;

  IF current_status = 'completed' THEN
    RAISE EXCEPTION
      'import run % has completed and cannot be failed', target_run_id
      USING
        ERRCODE = '55000',
        HINT = 'A completed candidate is finished. Import a new release key, or call publish_release if it is unpublished.';
  END IF;

  IF current_status = 'failed' THEN
    RETURN;
  END IF;

  PERFORM 1
    FROM $SCHEMA$.import_run_lease
   WHERE import_run_lease.run_id = target_run_id
     AND import_run_lease.release_id = target_release_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'executor % does not own import run %', target_executor_id, target_run_id
      USING
        ERRCODE = '55000',
        HINT = 'Only the executor that claimed the current attempt may fail it.';
  END IF;

  -- An unclaimed pending lease may be terminalized by the enqueue-refusal
  -- path or a guardian that dies before claim_import_execution commits.
  -- Claiming and failing in this same statement keeps that refusal atomic.
  UPDATE $SCHEMA$.import_run_lease
     SET executor_id = target_executor_id,
         execution_started_at = coalesce(execution_started_at, clock_timestamp()),
         heartbeat_at = clock_timestamp()
   WHERE run_id = target_run_id
     AND executor_id IS NULL;

  PERFORM 1
    FROM $SCHEMA$.import_run_lease
   WHERE import_run_lease.run_id = target_run_id
     AND import_run_lease.release_id = target_release_id
     AND import_run_lease.executor_id = target_executor_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'executor % does not own import run %', target_executor_id, target_run_id
      USING
        ERRCODE = '55000',
        HINT = 'Only the executor that claimed the current attempt may fail it.';
  END IF;

  UPDATE $SCHEMA$.import_run
     SET status = 'failed',
         completed_at = now(),
         error = error_detail
   WHERE id = target_run_id;

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
CREATE FUNCTION $SCHEMA$.create_staging(target_run_id uuid, target_executor_id uuid)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  table_name text;
BEGIN
  PERFORM $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['staging']);

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

-- Writes one staging batch under the same attempt fence as table creation.
-- Keeping the guard and dynamic INSERT in this SQL function closes the race a
-- separate Elixir preflight would leave between validation and mutation.
CREATE FUNCTION $SCHEMA$.insert_staging_many(
  target_run_id uuid,
  target_executor_id uuid,
  artifacts text[],
  payloads jsonb[],
  geometries geometry[]
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  table_name text;
  batch_size integer;
  inserted_count bigint;
BEGIN
  PERFORM $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['staging']);

  batch_size := $SCHEMA$.assert_write_arrays(
    ARRAY[cardinality(artifacts), cardinality(payloads), cardinality(geometries)],
    ARRAY[array_position(artifacts, NULL), array_position(payloads, NULL), NULL],
    ARRAY['artifacts', 'payloads', 'geometries']);

  IF batch_size = 0 THEN
    RETURN 0;
  END IF;

  table_name := $SCHEMA$.staging_table_name(target_run_id);

  EXECUTE format(
    'INSERT INTO $SCHEMA$.%I (artifact, payload, geom)
     SELECT * FROM unnest($1::text[], $2::jsonb[], $3::geometry[])',
    table_name
  ) USING artifacts, payloads, geometries;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
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
DECLARE
  current_status text;
BEGIN
  IF target_run_id IS NULL THEN
    RAISE EXCEPTION 'run id is required' USING ERRCODE = '22004';
  END IF;

  SELECT status INTO current_status
    FROM $SCHEMA$.import_run
   WHERE id = target_run_id
   FOR UPDATE;

  IF FOUND AND current_status IN (
    'pending',
    'downloading',
    'validating',
    'staging',
    'normalizing',
    'relating',
    'indexing',
    'verifying',
    'publishing'
  ) THEN
    RAISE EXCEPTION 'import run % is active and cannot be cleaned up by an operator',
      target_run_id
      USING
        ERRCODE = '55000',
        HINT = 'Let the owning executor clean up, or wait until the import is terminal.';
  END IF;

  EXECUTE format(
    'DROP TABLE IF EXISTS $SCHEMA$.%I',
    $SCHEMA$.staging_table_name(target_run_id)
  );
END;
$fn$;

--SPLIT--

CREATE FUNCTION $SCHEMA$.drop_staging(target_run_id uuid, target_executor_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  PERFORM $SCHEMA$.assert_import_write(
    target_run_id,
    target_executor_id,
    ARRAY[
      'pending',
      'downloading',
      'validating',
      'staging',
      'normalizing',
      'relating',
      'indexing',
      'verifying',
      'publishing'
    ]
  );

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

CREATE FUNCTION $SCHEMA$.analyze_import(target_run_id uuid, target_executor_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
DECLARE
  target_release_id uuid;
BEGIN
  target_release_id := $SCHEMA$.assert_import_write(
    target_run_id, target_executor_id, ARRAY['indexing']);

  PERFORM $SCHEMA$.analyze_release(target_release_id);
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
  coalesce(import_run_lease.progress, '{}'::jsonb) AS progress,
  import_run_lease.executor_id,
  import_run_lease.execution_started_at,
  import_run.manifest
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
  release_artifact.release_id,
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
  observation.observed_sha256,
  observation.observed_bytes,
  observation.validated_at,
  artifact.metadata
FROM $SCHEMA$.release_artifact
JOIN $SCHEMA$.artifact ON artifact.id = release_artifact.artifact_id
JOIN $SCHEMA$.source_release ON source_release.id = artifact.source_release_id
JOIN $SCHEMA$.source ON source.id = source_release.source_id
JOIN $SCHEMA$.collection ON collection.id = source.collection_id
LEFT JOIN LATERAL (
  SELECT import_run.id
    FROM $SCHEMA$.import_run
   WHERE import_run.release_id = release_artifact.release_id
     AND import_run.status = 'completed'
   ORDER BY import_run.attempt DESC
   LIMIT 1
) completed_run ON true
LEFT JOIN $SCHEMA$.import_run_artifact observation
  ON observation.run_id = completed_run.id
 AND observation.artifact_id = release_artifact.artifact_id;

--SPLIT--

CREATE VIEW $SCHEMA$.run_artifacts AS
SELECT
  import_run.id AS run_id,
  import_run.release_id,
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
  import_run_artifact.observed_sha256,
  import_run_artifact.observed_bytes,
  import_run_artifact.validated_at,
  artifact.metadata
FROM $SCHEMA$.import_run_artifact
JOIN $SCHEMA$.import_run ON import_run.id = import_run_artifact.run_id
JOIN $SCHEMA$.artifact ON artifact.id = import_run_artifact.artifact_id
JOIN $SCHEMA$.source_release ON source_release.id = artifact.source_release_id
JOIN $SCHEMA$.source ON source.id = source_release.source_id
JOIN $SCHEMA$.collection ON collection.id = source.collection_id
;

--SPLIT--

-- Read views, in release-scoped/published pairs. Each release_* base carries
-- every release, published or not, and stamps release_id on every row. Each
-- published_* view is that base joined to publication and nothing else, so a
-- pointer swap changes what all of them show at once, under MVCC, with no
-- refresh step, and a caller holding a release id can read that release
-- through the base before it is ever published.
--
-- Pairing them this way means one definition of each column list. It also
-- means the same host-side query shape works either side of publication: the
-- pair projects identical columns in identical order.

-- release_areas is one row per (release, area) membership recorded in
-- release_area, whether or not the area has a boundary -- geometry is an
-- optional attachment, not a condition of membership. The resolution
-- functions below query it directly so a non-null target_release_id can reach
-- a release that is not (or not yet, or no longer) the published one.
-- The surface hosts join, and the base the other three bases build on. It
-- reads only columns: the official name is selected onto the release's
-- membership row when release-scoped names are attached, because resolving it
-- here per row costs an index probe for every row of every scan a host runs.
CREATE VIEW $SCHEMA$.release_areas AS
SELECT
  collection.key AS collection_key,
  release_area.release_id,
  area.id AS area_id,
  area.area_key,
  authority.key AS authority,
  area_type.key AS area_type,
  release_area_type.rank AS type_rank,
  release_area.official_name AS name,
  release_area.centroid,
  coalesce(release_area.data, '{}'::jsonb) AS attributes,
  area.retired_at
FROM $SCHEMA$.release_area
JOIN $SCHEMA$.area ON area.id = release_area.area_id
JOIN $SCHEMA$.release ON release.id = release_area.release_id
JOIN $SCHEMA$.collection ON collection.id = release.collection_id
JOIN $SCHEMA$.authority ON authority.id = area.authority_id
JOIN $SCHEMA$.release_authority
  ON release_authority.release_id = release_area.release_id
 AND release_authority.authority_id = authority.id
JOIN $SCHEMA$.area_type ON area_type.id = area.area_type_id
JOIN $SCHEMA$.release_area_type
  ON release_area_type.release_id = release_area.release_id
 AND release_area_type.area_type_id = area_type.id;

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

-- Codes and names hang off the area, and an area belongs to as many releases
-- as carry it, so both bases project release_id: without it the same code
-- comes back once per release with nothing on the row to say which release it
-- is speaking for, and a caller joining back to release_areas on area_id
-- alone would pair a code of one release with an area of another. The
-- published counterparts project it too, so one schema reads either source
-- and the release-scoped join predicate is available on both.
CREATE VIEW $SCHEMA$.release_area_codes AS
SELECT
  release_areas.collection_key,
  release_areas.release_id,
  release_areas.area_key,
  release_areas.area_id,
  area_code.code_type,
  area_code.code_value
FROM $SCHEMA$.release_areas
JOIN $SCHEMA$.release_area_code
  ON release_area_code.release_id = release_areas.release_id
JOIN $SCHEMA$.area_code
  ON area_code.id = release_area_code.area_code_id
 AND area_code.area_id = release_areas.area_id;

--SPLIT--

CREATE VIEW $SCHEMA$.published_area_codes AS
SELECT
  release_area_codes.collection_key,
  release_area_codes.release_id,
  release_area_codes.area_key,
  release_area_codes.area_id,
  release_area_codes.code_type,
  release_area_codes.code_value
FROM $SCHEMA$.release_area_codes
JOIN $SCHEMA$.publication ON publication.release_id = release_area_codes.release_id;

--SPLIT--

CREATE VIEW $SCHEMA$.release_area_names AS
SELECT
  release_areas.collection_key,
  release_areas.release_id,
  release_areas.area_key,
  release_areas.area_id,
  area_name.name,
  area_name.kind,
  area_name.locale
FROM $SCHEMA$.release_areas
JOIN $SCHEMA$.release_area_name
  ON release_area_name.release_id = release_areas.release_id
JOIN $SCHEMA$.area_name
  ON area_name.id = release_area_name.area_name_id
 AND area_name.area_id = release_areas.area_id;

--SPLIT--

CREATE VIEW $SCHEMA$.published_area_names AS
SELECT
  release_area_names.collection_key,
  release_area_names.release_id,
  release_area_names.area_key,
  release_area_names.area_id,
  release_area_names.name,
  release_area_names.kind,
  release_area_names.locale
FROM $SCHEMA$.release_area_names
JOIN $SCHEMA$.publication ON publication.release_id = release_area_names.release_id;

--SPLIT--

-- The collection key comes through release, not through publication, which is
-- the whole difference between this and its published counterpart: an edge of
-- an unpublished release still belongs to a collection.
CREATE VIEW $SCHEMA$.release_relations AS
SELECT
  collection.key AS collection_key,
  relation.release_id,
  relation.parent_area_id,
  parent_area.area_key AS parent_area_key,
  relation.child_area_id,
  child_area.area_key AS child_area_key,
  relation.relation_type,
  relation.intersection_area_m2,
  relation.parent_coverage,
  relation.child_coverage
FROM $SCHEMA$.relation
JOIN $SCHEMA$.release ON release.id = relation.release_id
JOIN $SCHEMA$.collection ON collection.id = release.collection_id
JOIN $SCHEMA$.area parent_area ON parent_area.id = relation.parent_area_id
JOIN $SCHEMA$.area child_area ON child_area.id = relation.child_area_id;

--SPLIT--

CREATE VIEW $SCHEMA$.published_area_relations AS
SELECT
  release_relations.collection_key,
  release_relations.release_id,
  release_relations.parent_area_id,
  release_relations.parent_area_key,
  release_relations.child_area_id,
  release_relations.child_area_key,
  release_relations.relation_type,
  release_relations.intersection_area_m2,
  release_relations.parent_coverage,
  release_relations.child_coverage
FROM $SCHEMA$.release_relations
JOIN $SCHEMA$.publication ON publication.release_id = release_relations.release_id;

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

-- The seed guard the plural reads below share. Their seed argument is
-- required, exactly as the singular reads' single seed is, and a null element
-- inside the array is rejected rather than skipped: a skipped element would
-- contribute no rows and no error, losing one seed out of thousands without
-- a trace.
CREATE FUNCTION $SCHEMA$.assert_seed_keys(
  seed_keys text[],
  label text
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF seed_keys IS NULL THEN
    RAISE EXCEPTION '% are required', label USING ERRCODE = '22004';
  END IF;

  IF array_position(seed_keys, NULL) IS NOT NULL THEN
    RAISE EXCEPTION '% must not contain a null element', label
      USING ERRCODE = '22004';
  END IF;
END;
$fn$;

--SPLIT--

-- area_match with the seed that produced the row in front of it. The plural
-- reads resolve many seeds in one call, so the seed has to travel with each
-- row: without it a caller cannot tell which of its thousands of inputs a
-- given row answers.
--
-- The sixteen trailing columns repeat area_match's definitions in
-- area_match's order, and that repetition is deliberate. PostgreSQL composite
-- types do not compose: a type cannot be declared as area_match plus one
-- column. The alternative shape,
-- RETURNS TABLE(seed_key text, match $SCHEMA$.area_match), nests a composite
-- inside a result column, which every client then has to decode -- Postgrex
-- decodes a nested composite poorly, and it would complicate the decoding
-- path shared with every caller of the singular reads. Flat and duplicated is
-- the cheaper of the two costs; test/pgtap/schema/test_install.sql pins both
-- column lists so the two cannot drift apart unnoticed.
--
-- The seed column is seed_key, not seed_area_key: three of the four plural
-- reads are seeded by an area key, areas_by_code_many is seeded by a code
-- value, and one type serves all four.
CREATE TYPE $SCHEMA$.seeded_area_match AS (
  seed_key text,
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
    SELECT $SCHEMA$.area_codes_json(area.release_id, area.area_id) AS codes
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
    SELECT $SCHEMA$.area_codes_json(intersections.release_id, intersections.area_id) AS codes
  ) codes ON true
  WHERE intersections.intersection_area_m2 > 0;
END;
$fn$;

--SPLIT--

-- Proximity, code lookup, and ranked name search. All three query
-- release_areas directly (not published_areas) so a non-null
-- target_release_id can reach a release that is not the currently
-- published one, matching areas_for_point and areas_for_geometry.
--
-- The two that take a result_limit pass it to LIMIT unwrapped, so an
-- explicit NULL is PostgreSQL's LIMIT ALL. A caller that narrows what came
-- back -- by a scope these functions do not model -- asks for the whole
-- ranked set that way, rather than naming a number that stands in for one.
-- Omitting the argument still takes the parameter default of 50.

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
    SELECT $SCHEMA$.area_codes_json(area.release_id, area.area_id) AS codes
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
  LIMIT result_limit;
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
  JOIN $SCHEMA$.release_area_code selected_code
    ON selected_code.release_id = area.release_id
  JOIN $SCHEMA$.area_code ac
    ON ac.id = selected_code.area_code_id
   AND ac.area_id = area.area_id
   AND ac.code_type = target_code_type
   AND ac.code_value = target_code_value
  LEFT JOIN LATERAL (
    SELECT $SCHEMA$.area_codes_json(area.release_id, area.area_id) AS codes
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

-- Every plural read delegates to the singular read beside it, once per
-- seed, the way resolve delegates to each strategy rather than reimplementing
-- it. One definition of what the read means serves both, and the plural
-- result for an array is exactly the singular results concatenated in the
-- array's order.
--
-- What that removes is the round trip, not the per-seed lookup: a caller
-- resolving three thousand seeds pays one call instead of three thousand.
-- These are SETOF plpgsql functions, so the planner cannot push a predicate
-- into them; a caller that wants to join or aggregate against catalog areas
-- wants GeoGenius.Query's composable, view-backed path instead of either
-- shape here.
--
-- CROSS JOIN, not LEFT JOIN: a seed that matched nothing contributes no rows
-- rather than one row whose every area column is null, which a caller would
-- have to filter out and which nothing in the type distinguishes from a real
-- match.
CREATE FUNCTION $SCHEMA$.areas_by_code_many(
  target_code_type text,
  target_code_values text[],
  collections text[] DEFAULT NULL,
  types text[] DEFAULT NULL,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false,
  parent_area_key text DEFAULT NULL,
  parent_max_depth integer DEFAULT 1
)
RETURNS SETOF $SCHEMA$.seeded_area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  IF target_code_type IS NULL THEN
    RAISE EXCEPTION 'code type is required' USING ERRCODE = '22004';
  END IF;

  PERFORM $SCHEMA$.assert_seed_keys(target_code_values, 'code values');

  -- areas_by_code leaves its rows unordered, so the plural pins an order the
  -- singular does not have to: seed order first, then area_key, which is
  -- unique within one code lookup.
  RETURN QUERY
  SELECT seed.seed_key, matched.*
  FROM unnest(target_code_values) WITH ORDINALITY AS seed(seed_key, seed_ord)
  CROSS JOIN LATERAL $SCHEMA$.areas_by_code(
    target_code_type, seed.seed_key, collections, types, target_release_id,
    include_retired, parent_area_key, parent_max_depth) matched
  ORDER BY seed.seed_ord, matched.area_key;
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
      release_area_name.release_id,
      area_name.area_id,
      area_name.name,
      similarity(area_name.name, query)::numeric AS score
    FROM $SCHEMA$.release_area_name
    JOIN $SCHEMA$.area_name ON area_name.id = release_area_name.area_name_id
    WHERE area_name.name % query OR area_name.name ILIKE query || '%'
  ),
  best AS (
    SELECT DISTINCT ON (release_id, area_id)
      release_id,
      area_id,
      name AS matched_name,
      score
    FROM matches
    -- name breaks a score tie so one area's aliases cannot alternate as
    -- matched_name between runs, which would in turn perturb the outer
    -- (score, matched_name, area_key) ordering and the LIMIT that follows it.
    ORDER BY release_id, area_id, score DESC, name
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
      release_area_type.rank AS type_rank,
      release_area.official_name,
      release_area.centroid,
      coalesce(release_area.data, '{}'::jsonb) AS attributes
    FROM best
    JOIN $SCHEMA$.release_area
      ON release_area.release_id = best.release_id
     AND release_area.area_id = best.area_id
    JOIN $SCHEMA$.area ON area.id = release_area.area_id
    JOIN $SCHEMA$.release ON release.id = release_area.release_id
    JOIN $SCHEMA$.collection ON collection.id = release.collection_id
    JOIN $SCHEMA$.authority ON authority.id = area.authority_id
    JOIN $SCHEMA$.area_type ON area_type.id = area.area_type_id
    JOIN $SCHEMA$.release_authority
      ON release_authority.release_id = release_area.release_id
     AND release_authority.authority_id = authority.id
    JOIN $SCHEMA$.release_area_type
      ON release_area_type.release_id = release_area.release_id
     AND release_area_type.area_type_id = area_type.id
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
    LIMIT result_limit
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
    SELECT $SCHEMA$.area_codes_json(top.release_id, top.area_id) AS codes
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
    $SCHEMA$.area_codes_json(area.release_id, area.area_id),
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

CREATE FUNCTION $SCHEMA$.children_of_many(
  parent_area_keys text[],
  types text[] DEFAULT NULL,
  classifications text[] DEFAULT NULL,
  max_depth integer DEFAULT 1,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.seeded_area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  PERFORM $SCHEMA$.assert_seed_keys(parent_area_keys, 'parent area keys');

  -- children_of collapses its walk to one row per area_key, so ordering on
  -- the seed's position and then area_key reproduces the singular's order
  -- inside each seed's block.
  RETURN QUERY
  SELECT seed.seed_key, walked.*
  FROM unnest(parent_area_keys) WITH ORDINALITY AS seed(seed_key, seed_ord)
  CROSS JOIN LATERAL $SCHEMA$.children_of(
    seed.seed_key, types, classifications, max_depth, target_release_id,
    include_retired) walked
  ORDER BY seed.seed_ord, walked.area_key;
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
    $SCHEMA$.area_codes_json(area.release_id, area.area_id),
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

CREATE FUNCTION $SCHEMA$.ancestors_of_many(
  child_area_keys text[],
  types text[] DEFAULT NULL,
  classifications text[] DEFAULT NULL,
  max_depth integer DEFAULT 1,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.seeded_area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  PERFORM $SCHEMA$.assert_seed_keys(child_area_keys, 'child area keys');

  RETURN QUERY
  SELECT seed.seed_key, walked.*
  FROM unnest(child_area_keys) WITH ORDINALITY AS seed(seed_key, seed_ord)
  CROSS JOIN LATERAL $SCHEMA$.ancestors_of(
    seed.seed_key, types, classifications, max_depth, target_release_id,
    include_retired) walked
  ORDER BY seed.seed_ord, walked.area_key;
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
    $SCHEMA$.area_codes_json(area.release_id, area.area_id),
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

CREATE FUNCTION $SCHEMA$.related_areas_many(
  target_area_keys text[],
  classifications text[] DEFAULT NULL,
  target_release_id uuid DEFAULT NULL,
  include_retired boolean DEFAULT false
)
RETURNS SETOF $SCHEMA$.seeded_area_match
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, public, $SCHEMA$
AS $fn$
BEGIN
  PERFORM $SCHEMA$.assert_seed_keys(target_area_keys, 'area keys');

  RETURN QUERY
  SELECT seed.seed_key, related.*
  FROM unnest(target_area_keys) WITH ORDINALITY AS seed(seed_key, seed_ord)
  CROSS JOIN LATERAL $SCHEMA$.related_areas(
    seed.seed_key, classifications, target_release_id, include_retired) related
  ORDER BY seed.seed_ord, related.area_key;
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
