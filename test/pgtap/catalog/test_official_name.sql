-- Official names are release-selected metadata. The stable area row carries
-- identity only, while each candidate records the names it reviewed and the
-- deterministic winner projected by release_areas.
BEGIN;

SELECT plan(9);

SELECT geo_genius.upsert_collection('names', 'Names', NULL);
SELECT geo_genius.upsert_authority('names', 'n_auth', 'Names Authority');
SELECT geo_genius.upsert_area_type('names', 'unit', 10);
SELECT geo_genius.upsert_area('names', 'n_auth', 'unit', 'A');
SELECT geo_genius.upsert_area('names', 'n_auth', 'unit', 'B');

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"names",
    "release":"r1",
    "collection_name":"Names",
    "requires_geometry":false,
    "authorities":[{"key":"n_auth","name":"Names Authority"}],
    "area_types":[{"key":"unit","rank":10,"requires_geometry":false}]
  }'::jsonb,
  '{"owner":"pgtap-official-name","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('names', 'r1'));
SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'normalizing');
SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'n_auth:unit:A', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'n_auth:unit:B', NULL, '{}'::jsonb);

SELECT is(
  (SELECT official_name FROM geo_genius.release_area
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
      AND area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'n_auth:unit:A')),
  NULL,
  'an area with no names has no official name in the release'
);

SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'n_auth:unit:A', 'Alpha', 'official', NULL);

SELECT is(
  (SELECT name FROM geo_genius.release_areas
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
      AND area_key = 'n_auth:unit:A'),
  'Alpha',
  'adding an official name sets the release projection'
);

SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'n_auth:unit:A', 'Aaaa', 'alias', NULL);

SELECT is(
  (SELECT name FROM geo_genius.release_areas
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
      AND area_key = 'n_auth:unit:A'),
  'Alpha',
  'a non-official name never becomes the release official name'
);

SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'n_auth:unit:A', 'Aaa', 'official', 'aa');

SELECT is(
  (SELECT name FROM geo_genius.release_areas
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
      AND area_key = 'n_auth:unit:A'),
  'Alpha',
  'an unlocalized official name outranks an earlier localized name'
);

SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'n_auth:unit:B', 'Zulu', 'official', 'en');
SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'n_auth:unit:B', 'Bravo', 'official', 'aa');
SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('names', 'r1'),
  geo_genius_test.import_executor_id('names', 'r1'),
  'n_auth:unit:B', 'Bee', 'alias', NULL);

SELECT is(
  (SELECT name FROM geo_genius.release_areas
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
      AND area_key = 'n_auth:unit:B'),
  'Bravo',
  'locale ordering ignores a non-official attachment when no unlocalized official name exists'
);

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"names",
    "release":"r2",
    "collection_name":"Candidate Names",
    "requires_geometry":false,
    "authorities":[{"key":"n_auth","name":"Candidate Authority"}],
    "area_types":[{"key":"unit","rank":20,"requires_geometry":false}]
  }'::jsonb,
  '{"owner":"pgtap-official-name","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('names', 'r2'));
SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('names', 'r2'),
  geo_genius_test.import_executor_id('names', 'r2'),
  'normalizing');
SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('names', 'r2'),
  geo_genius_test.import_executor_id('names', 'r2'),
  'n_auth:unit:A', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  geo_genius_test.import_run_id('names', 'r2'),
  geo_genius_test.import_executor_id('names', 'r2'),
  'n_auth:unit:B', NULL, '{}'::jsonb);

SELECT is(
  (SELECT name FROM geo_genius.release_areas
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r2')
      AND area_key = 'n_auth:unit:A'),
  NULL,
  'a second release does not inherit the first release selected names'
);

SELECT geo_genius.put_area_name(
  geo_genius_test.import_run_id('names', 'r2'),
  geo_genius_test.import_executor_id('names', 'r2'),
  'n_auth:unit:A', 'Candidate Alpha', 'official', NULL);

SELECT is(
  (SELECT name FROM geo_genius.release_areas
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
      AND area_key = 'n_auth:unit:A'),
  'Alpha',
  'a candidate official name cannot contaminate another release'
);

SELECT is(
  (SELECT name FROM geo_genius.release_areas
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r2')
      AND area_key = 'n_auth:unit:A'),
  'Candidate Alpha',
  'the candidate projects its own selected official name'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.release_area_names
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r2')),
  1,
  'release_area_names exposes only names explicitly selected by the candidate'
);

SELECT finish();

ROLLBACK;
