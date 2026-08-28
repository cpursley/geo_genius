BEGIN;

SELECT plan(13);

SELECT has_schema('geo_genius', 'geo_genius schema exists');
SELECT has_view('geo_genius', 'geo_genius_version', 'version tracking view exists');
SELECT has_function(
  'geo_genius',
  'assert_extensions',
  ARRAY['text[]'],
  'assert_extensions exists'
);

-- The published_* views are the host binding surface and area_match is the
-- shape every resolution function returns. Reordering two same-typed columns
-- in either would silently transpose values in a host's positional read, and
-- no behavioural test would notice, so the order is pinned here.
SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = 'geo_genius.published_areas'::regclass
      AND attnum > 0 AND NOT attisdropped),
  ARRAY[
    'collection_key', 'release_id', 'area_id', 'area_key', 'authority',
    'area_type', 'type_rank', 'name', 'centroid', 'attributes', 'retired_at'
  ],
  'published_areas column order is unchanged'
);

SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = 'geo_genius.release_areas'::regclass
      AND attnum > 0 AND NOT attisdropped),
  ARRAY[
    'collection_key', 'release_id', 'area_id', 'area_key', 'authority',
    'area_type', 'type_rank', 'name', 'centroid', 'attributes', 'retired_at'
  ],
  'release_areas column order matches published_areas'
);

SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = (SELECT typrelid FROM pg_type
                       WHERE typname = 'area_match'
                         AND typnamespace = 'geo_genius'::regnamespace)
      AND attnum > 0 AND NOT attisdropped),
  ARRAY[
    'collection_key', 'release_id', 'area_key', 'authority', 'area_type',
    'type_rank', 'name', 'codes', 'centroid', 'attributes', 'match_method',
    'distance_m', 'intersection_area_m2', 'coverage_of_input',
    'coverage_of_area', 'score'
  ],
  'area_match column order is unchanged'
);

-- seeded_area_match repeats area_match's columns after its own seed_key, and
-- the plural reads project one straight into the other. A column added to
-- area_match alone, or reordered in one and not the other, would transpose
-- values with no behavioural test to catch it.
SELECT is(
  (SELECT array_agg(attname::text ORDER BY attnum)
     FROM pg_attribute
    WHERE attrelid = (SELECT typrelid FROM pg_type
                       WHERE typname = 'seeded_area_match'
                         AND typnamespace = 'geo_genius'::regnamespace)
      AND attnum > 0 AND NOT attisdropped),
  ARRAY['seed_key'] || (
    SELECT array_agg(attname::text ORDER BY attnum)
      FROM pg_attribute
     WHERE attrelid = (SELECT typrelid FROM pg_type
                        WHERE typname = 'area_match'
                          AND typnamespace = 'geo_genius'::regnamespace)
       AND attnum > 0 AND NOT attisdropped
  ),
  'seeded_area_match is seed_key followed by area_match''s columns in order'
);

-- Nothing GeoGenius installs runs with the definer's rights, and every
-- function pins its search path. A function switched to SECURITY DEFINER, or
-- left with a mutable search path, would be a privilege-escalation surface
-- that behaves identically in every other test.
SELECT is(
  (SELECT count(*)::int
     FROM pg_proc
    WHERE pronamespace = 'geo_genius'::regnamespace
      AND prosecdef),
  0,
  'no installed function is SECURITY DEFINER'
);

SELECT is(
  (SELECT array_agg(proname::text ORDER BY proname)
     FROM pg_proc
    WHERE pronamespace = 'geo_genius'::regnamespace
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(proconfig, ARRAY[]::text[])) AS setting
         WHERE setting LIKE 'search_path=%'
      )),
  NULL,
  'every installed function pins its search path'
);

-- The invariant helpers are what the write API and the read functions call
-- into. Dropping one would leave those callers unguarded, so their presence
-- is asserted directly rather than only through the behaviour they enforce.
SELECT is(
  (SELECT count(*)::int FROM pg_proc
    WHERE pronamespace = 'geo_genius'::regnamespace
      AND proname IN ('assert_release_mutable', 'assert_area_in_collection',
                      'area_codes_json', 'release_at')),
  4,
  'the invariant and resolution helpers are installed'
);

-- guides/sql_api.md publishes the volatility and parallel-safety markings as
-- a contract. A read function that loses PARALLEL SAFE silently costs every
-- host a parallel plan, and a write function marked STABLE would be run
-- inside a plan that assumes it writes nothing.
SELECT is(
  (SELECT array_agg(p.proname::text ORDER BY p.proname)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'geo_genius'
      AND p.provolatile <> 'v'
      AND p.proparallel <> 's'),
  ARRAY['assert_area_in_collection', 'assert_extensions', 'assert_release_mutable',
        'release_at', 'staging_table_name'],
  'the non-volatile functions lacking PARALLEL SAFE are exactly the documented five'
);

SELECT is(
  (SELECT array_agg(DISTINCT p.provolatile::text || p.proparallel::text)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'geo_genius'
      AND p.proname = ANY(ARRAY[
        'areas_for_point', 'areas_for_geometry', 'areas_near', 'areas_by_code',
        'search_areas', 'resolve', 'children_of', 'ancestors_of', 'related_areas',
        'areas_by_code_many', 'children_of_many', 'ancestors_of_many',
        'related_areas_many', 'published_release', 'verify_release'])),
  ARRAY['ss'],
  'every documented read function is STABLE PARALLEL SAFE'
);

SELECT is(
  (SELECT count(*)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'geo_genius'
      AND p.provolatile <> 'v'
      AND p.proname = ANY(ARRAY[
        'upsert_collection', 'upsert_authority', 'upsert_area_type', 'upsert_area',
        'put_area_name', 'put_area_code', 'put_area_in_release', 'put_boundary',
        'put_relation', 'rebuild_relations', 'publish_release', 'rollback_publication',
        'retire_releases', 'open_release', 'attach_source_release', 'put_artifact',
        'record_artifact_observation', 'upsert_source', 'upsert_source_release',
        'begin_or_resume_import', 'heartbeat_import', 'advance_import', 'fail_import',
        'create_staging', 'drop_staging', 'analyze_release'])),
  0::bigint,
  'every documented write function is VOLATILE'
);

SELECT finish();

ROLLBACK;
