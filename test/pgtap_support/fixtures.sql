CREATE SCHEMA IF NOT EXISTS geo_genius_test;

-- Builds the demo collection and its r1 release, and stops short of
-- publishing it. A published release is immutable, so any test that needs to
-- add areas, boundaries, or relations of its own builds with this, extends
-- r1, and publishes when it is done.
CREATE OR REPLACE FUNCTION geo_genius_test.demo_fixture_build()
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  release_id uuid;
  source_release_id uuid;
BEGIN
  PERFORM geo_genius.upsert_collection('demo', 'Demo', NULL);
  PERFORM geo_genius.upsert_authority('demo', 'demo_auth', 'Demo Authority');
  PERFORM geo_genius.upsert_area_type('demo', 'outer', 10);
  PERFORM geo_genius.upsert_area_type('demo', 'inner', 20);
  PERFORM geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'A');
  PERFORM geo_genius.upsert_area('demo', 'demo_auth', 'inner', 'B');
  PERFORM geo_genius.put_area_name('demo_auth:outer:A', 'Alpha', 'official', NULL);
  PERFORM geo_genius.put_area_name('demo_auth:inner:B', 'Bravo', 'official', NULL);

  INSERT INTO geo_genius.release (collection_id, release_key, manifest)
  SELECT id, 'r1', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo'
  RETURNING id INTO release_id;

  PERFORM geo_genius.create_release_partitions(release_id);

  INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
  SELECT id, 'demo:src', 'demo', 'test' FROM geo_genius.collection WHERE key = 'demo';

  INSERT INTO geo_genius.source_release (source_id, release_key)
  SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'demo:src'
  RETURNING id INTO source_release_id;

  INSERT INTO geo_genius.release_source (release_id, source_release_id)
  VALUES (release_id, source_release_id);

  -- A unit square and a quarter square sharing its lower-left corner.
  PERFORM geo_genius.put_boundary(
    release_id, 'demo_auth:outer:A', source_release_id,
    ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326), 0.0);

  PERFORM geo_genius.put_boundary(
    release_id, 'demo_auth:inner:B', source_release_id,
    ST_GeomFromText('POLYGON((0 0, 0.5 0, 0.5 0.5, 0 0.5, 0 0))', 4326), 0.0);

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
  PERFORM geo_genius.publish_release(
    (SELECT id FROM geo_genius.release WHERE release_key = 'r1'));
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

  FOR demo_release_id IN
    SELECT id FROM geo_genius.release WHERE collection_id = demo_collection_id
  LOOP
    PERFORM geo_genius.drop_release_partitions(demo_release_id);
  END LOOP;

  DELETE FROM geo_genius.publication WHERE collection_id = demo_collection_id;

  DELETE FROM geo_genius.release_source
   WHERE release_id IN (
     SELECT id FROM geo_genius.release WHERE collection_id = demo_collection_id);

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
