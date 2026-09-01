CREATE SCHEMA IF NOT EXISTS geo_genius_test;

-- Advances fixture setup through the public import state machine without
-- obscuring lifecycle tests that assert individual transitions directly.
CREATE OR REPLACE FUNCTION geo_genius_test.advance_import_to(
  target_run_id uuid,
  target_executor_id uuid,
  target_active_status text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  active_statuses text[] := ARRAY[
    'pending',
    'downloading',
    'validating',
    'staging',
    'normalizing',
    'relating',
    'indexing',
    'verifying',
    'publishing'
  ];
  current_status text;
  current_position integer;
  target_position integer;
  position integer;
BEGIN
  IF target_run_id IS NULL OR target_executor_id IS NULL OR target_active_status IS NULL THEN
    RAISE EXCEPTION 'run id, executor id, and target active status are required'
      USING ERRCODE = '22004';
  END IF;

  SELECT status INTO current_status
    FROM geo_genius.import_run
   WHERE id = target_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'import run % does not exist', target_run_id USING ERRCODE = '23503';
  END IF;

  current_position := array_position(active_statuses, current_status);
  target_position := array_position(active_statuses, target_active_status);

  IF target_position IS NULL THEN
    RAISE EXCEPTION 'unknown active import phase %', target_active_status USING ERRCODE = '22023';
  END IF;

  IF current_position IS NULL OR target_position < current_position THEN
    RAISE EXCEPTION 'fixture cannot advance import run % from % to %',
      target_run_id, current_status, target_active_status
      USING ERRCODE = '55000';
  END IF;

  IF target_position > current_position THEN
    FOR position IN (current_position + 1)..target_position LOOP
      PERFORM geo_genius.advance_import(
        target_run_id,
        target_executor_id,
        active_statuses[position],
        '{}'::jsonb
      );
    END LOOP;
  END IF;
END;
$fn$;

-- Builds the demo collection and its r1 release, and stops short of
-- publishing it. A published release is immutable, so any test that needs to
-- add areas, boundaries, or relations of its own builds with this, extends
-- r1, and publishes when it is done.
CREATE OR REPLACE FUNCTION geo_genius_test.demo_fixture_build(extra_area_types jsonb)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  release_id uuid;
  run_id uuid;
  executor_id uuid := gen_random_uuid();
  source_release_id uuid;
  manifest jsonb;
  area_types jsonb := '[
    {"key":"outer","rank":10,"requires_geometry":false},
    {"key":"inner","rank":20,"requires_geometry":false},
    {"key":"city","rank":50,"requires_geometry":false},
    {"key":"district","rank":60,"requires_geometry":false}
  ]'::jsonb;
BEGIN
  IF jsonb_typeof(extra_area_types) <> 'array' THEN
    RAISE EXCEPTION 'extra area types must be a JSON array' USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(jsonb_agg(base_declaration), '[]'::jsonb)
    INTO area_types
    FROM jsonb_array_elements(area_types) AS base(base_declaration)
   WHERE NOT EXISTS (
     SELECT 1
       FROM jsonb_array_elements(extra_area_types) AS extra(extra_declaration)
      WHERE extra_declaration ->> 'key' = base_declaration ->> 'key'
   );
  area_types := area_types || extra_area_types;

  manifest := jsonb_build_object(
      'collection', 'demo',
      'collection_name', 'Demo',
      'release', 'r1',
      'provider', 'geojson',
      'requires_geometry', false,
      'authorities', jsonb_build_array(
        jsonb_build_object('key', 'demo_auth', 'name', 'Demo Authority')),
      'area_types', area_types,
      'sources', jsonb_build_array(
        jsonb_build_object(
          'source_key', 'demo:src',
          'provider', 'geojson',
          'license', 'test',
          'release_key', 'v1',
          'artifacts', '[]'::jsonb
        )
      ),
      'options', '{}'::jsonb
  );

  SELECT prepared.release_id, prepared.run_id
    INTO release_id, run_id
    FROM geo_genius.prepare_import(
      manifest,
      jsonb_build_object(
        'owner', 'geo-genius-test-fixture',
        'runner_backend', 'test',
        'stale_after_seconds', 900
      )
    ) AS prepared;

  IF run_id IS NULL THEN
    RAISE EXCEPTION 'demo fixture could not prepare its import run'
      USING ERRCODE = '55000';
  END IF;

  IF geo_genius.claim_import_execution(run_id, executor_id) <> 'claimed' THEN
    RAISE EXCEPTION 'demo fixture could not claim its import executor'
      USING ERRCODE = '55000';
  END IF;

  SELECT id INTO STRICT source_release_id
    FROM geo_genius.source_release
   WHERE source_id = (SELECT id FROM geo_genius.source WHERE source_key = 'demo:src')
     AND release_key = 'v1';

  PERFORM geo_genius_test.advance_import_to(run_id, executor_id, 'normalizing');
  PERFORM geo_genius.upsert_area_many(
    run_id,
    executor_id,
    ARRAY['demo_auth', 'demo_auth'],
    ARRAY['outer', 'inner'],
    ARRAY['A', 'B']);

  -- A unit square and a quarter square sharing its lower-left corner.
  PERFORM geo_genius.put_boundary(
    run_id, executor_id, 'demo_auth:outer:A', source_release_id,
    ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326), 0.0);

  PERFORM geo_genius.put_boundary(
    run_id, executor_id, 'demo_auth:inner:B', source_release_id,
    ST_GeomFromText('POLYGON((0 0, 0.5 0, 0.5 0.5, 0 0.5, 0 0))', 4326), 0.0);

  PERFORM geo_genius.put_area_name(
    run_id, executor_id, 'demo_auth:outer:A', 'Alpha', 'official', NULL);
  PERFORM geo_genius.put_area_name(
    run_id, executor_id, 'demo_auth:inner:B', 'Bravo', 'official', NULL);

END;
$fn$;

-- Returns the most recent attempt for the demo fixture's r1 candidate. Tests
-- use this as the first argument to attempt-fenced writes while the release
-- remains the explicit identity used by read and operator APIs.
CREATE OR REPLACE FUNCTION geo_genius_test.demo_run_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $fn$
  SELECT import_run.id
    FROM geo_genius.import_run
    JOIN geo_genius.release ON release.id = import_run.release_id
    JOIN geo_genius.collection ON collection.id = release.collection_id
   WHERE collection.key = 'demo'
     AND release.release_key = 'r1'
   ORDER BY import_run.attempt DESC
   LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION geo_genius_test.demo_executor_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $fn$
  SELECT import_run_lease.executor_id
    FROM geo_genius.import_run_lease
   WHERE import_run_lease.run_id = geo_genius_test.demo_run_id();
$fn$;

-- Resolves the latest attempt for any fixture candidate without duplicating
-- the release/collection join throughout tests that build their own catalog.
CREATE OR REPLACE FUNCTION geo_genius_test.import_run_id(
  target_collection_key text,
  target_release_key text
)
RETURNS uuid
LANGUAGE sql
STABLE
AS $fn$
  SELECT import_run.id
    FROM geo_genius.import_run
    JOIN geo_genius.release ON release.id = import_run.release_id
    JOIN geo_genius.collection ON collection.id = release.collection_id
   WHERE collection.key = target_collection_key
     AND release.release_key = target_release_key
   ORDER BY import_run.attempt DESC
   LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION geo_genius_test.import_executor_id(
  target_collection_key text,
  target_release_key text
)
RETURNS uuid
LANGUAGE sql
STABLE
AS $fn$
  SELECT import_run_lease.executor_id
    FROM geo_genius.import_run_lease
   WHERE import_run_lease.run_id = geo_genius_test.import_run_id(
     target_collection_key,
     target_release_key
   );
$fn$;

CREATE OR REPLACE FUNCTION geo_genius_test.claim_import_executor(target_run_id uuid)
RETURNS uuid
LANGUAGE plpgsql
AS $fn$
DECLARE
  claimed_executor_id uuid := gen_random_uuid();
BEGIN
  IF geo_genius.claim_import_execution(target_run_id, claimed_executor_id) <> 'claimed' THEN
    RAISE EXCEPTION 'test fixture could not claim import executor for run %', target_run_id
      USING ERRCODE = '55000';
  END IF;

  RETURN claimed_executor_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION geo_genius_test.executor_id(target_run_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
AS $fn$
  SELECT import_run_lease.executor_id
    FROM geo_genius.import_run_lease
   WHERE import_run_lease.run_id = target_run_id;
$fn$;

CREATE OR REPLACE FUNCTION geo_genius_test.demo_fixture_build()
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  PERFORM geo_genius_test.demo_fixture_build('[]'::jsonb);
END;
$fn$;

-- The common case: build r1 and publish it. Tests that only read use this.
CREATE OR REPLACE FUNCTION geo_genius_test.demo_fixture()
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  PERFORM geo_genius_test.demo_fixture_build();
  PERFORM geo_genius_test.demo_publish();
END;
$fn$;

CREATE OR REPLACE FUNCTION geo_genius_test.demo_publish()
RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  PERFORM geo_genius_test.advance_import_to(
    geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(),
    'publishing');
  PERFORM geo_genius.publish_import(
    geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id());
END;
$fn$;

-- ExUnit cases commit, unlike the pgTAP suite which rolls back, so they need
-- an explicit way to remove the demo collection and everything hanging off it.
-- Deleting the collection cascades to its areas, authorities, area types,
-- sources, and releases. Three things it reaches are joined by foreign keys
-- that do not cascade -- the partitions holding release-scoped geometry, the
-- publication row, and the source_release rows -- so those go first.
CREATE OR REPLACE FUNCTION geo_genius_test.demo_teardown()
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  demo_collection_id uuid;
  demo_release_id uuid;
BEGIN
  SELECT id INTO demo_collection_id
    FROM geo_genius.collection
   WHERE key = 'demo';

  IF demo_collection_id IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM geo_genius.import_run_lease
   WHERE release_id IN (
     SELECT id FROM geo_genius.release WHERE collection_id = demo_collection_id
   );

  FOR demo_release_id IN
    SELECT id FROM geo_genius.release WHERE collection_id = demo_collection_id
  LOOP
    PERFORM geo_genius.drop_release_partitions(demo_release_id);
  END LOOP;

  DELETE FROM geo_genius.publication WHERE collection_id = demo_collection_id;

  DELETE FROM geo_genius.import_run
   WHERE release_id IN (
     SELECT id FROM geo_genius.release WHERE collection_id = demo_collection_id);

  DELETE FROM geo_genius.release_artifact
   WHERE release_id IN (
     SELECT id FROM geo_genius.release WHERE collection_id = demo_collection_id);

  DELETE FROM geo_genius.release_source
   WHERE release_id IN (
     SELECT id FROM geo_genius.release WHERE collection_id = demo_collection_id);

  DELETE FROM geo_genius.release
   WHERE collection_id = demo_collection_id;

  DELETE FROM geo_genius.source_release
   WHERE source_id IN (
     SELECT id FROM geo_genius.source WHERE collection_id = demo_collection_id);

  DELETE FROM geo_genius.collection WHERE id = demo_collection_id;
END;
$fn$;

-- The type and code halves of an area key, which two collections keying the
-- same areas under authorities of their own still share. area_key is unique
-- across the whole catalog rather than within a collection, so a test that
-- writes one input two ways into two collections cannot compare whole keys.
CREATE OR REPLACE FUNCTION geo_genius_test.type_and_code(area_key text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT split_part(area_key, ':', 2) || ':' || split_part(area_key, ':', 3);
$fn$;
