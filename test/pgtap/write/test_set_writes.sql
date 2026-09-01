BEGIN;

SELECT geo_genius_test.demo_fixture_build();

SELECT plan(21);

-- Two collections of one release each. The second exists so that "the same
-- input written two ways" can be compared: the scalar forms write into demo,
-- the plural forms write the identical input into mirror, and the two
-- collections' catalog state is compared column for column at the end.
--
-- mirror keys its areas under an authority of its own because area_key is
-- unique across the whole catalog rather than within a collection: two
-- collections naming the same authority, type and code compose one area_key
-- and collide, which is as true of the scalar form as of the plural one and is
-- not what this file is testing. The comparisons below therefore key on the
-- type and code, which the two collections share.
SELECT geo_genius.upsert_collection('mirror', 'Mirror', NULL);
SELECT geo_genius.upsert_authority('mirror', 'mirror_auth', 'Mirror Authority');
SELECT geo_genius.upsert_area_type('mirror', 'outer', 10);
SELECT geo_genius.upsert_area_type('mirror', 'inner', 20);

SELECT * FROM geo_genius.prepare_import(
  '{
    "collection":"mirror",
    "release":"m1",
    "collection_name":"Mirror",
    "requires_geometry":false,
    "authorities":[{"key":"mirror_auth","name":"Mirror Authority"}],
    "area_types":[
      {"key":"outer","rank":10,"requires_geometry":false},
      {"key":"inner","rank":20,"requires_geometry":false}
    ]
  }'::jsonb,
  '{"owner":"pgtap-set-writes","runner_backend":"pgtap"}'::jsonb
);
SELECT geo_genius_test.claim_import_executor(
  geo_genius_test.import_run_id('mirror', 'm1'));

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('mirror', 'm1'),
  geo_genius_test.import_executor_id('mirror', 'm1'),
  'normalizing');

-- A batch naming the same area twice is the shape a denormalised source
-- produces: every city row repeats its county. ON CONFLICT DO UPDATE raises
-- 21000 on a conflict key presented twice in one statement, so a batch that
-- did not deduplicate would not merely write the wrong rows, it would fail.
SELECT is(
  cardinality(geo_genius.upsert_area_many('mirror',
    ARRAY['mirror_auth', 'mirror_auth', 'mirror_auth', 'mirror_auth'],
    ARRAY['outer', 'inner', 'outer', 'inner'],
    ARRAY['A', 'B', 'A', 'C'])),
  4,
  'upsert_area_many returns one id per input position, repeats included'
);

SELECT is(
  (SELECT geo_genius.upsert_area_many('mirror',
     ARRAY['mirror_auth', 'mirror_auth'], ARRAY['outer', 'outer'], ARRAY['A', 'A'])),
  ARRAY[
    (SELECT id FROM geo_genius.area WHERE area_key = 'mirror_auth:outer:A'),
    (SELECT id FROM geo_genius.area WHERE area_key = 'mirror_auth:outer:A')
  ],
  'a repeated area resolves to one row, and its id is returned at both positions'
);

-- The second call above wrote an area the first had already written, and the
-- one below mixes that same area with one nothing has written yet.
SELECT is(
  (SELECT array_agg(area_key ORDER BY area_key) FROM geo_genius.area
    WHERE collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'mirror')),
  ARRAY['mirror_auth:inner:B', 'mirror_auth:inner:C', 'mirror_auth:outer:A'],
  'a batch mixing areas already in the catalog with a new one adds only the new one'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_area_many('mirror',
      ARRAY['nobody'], ARRAY['outer'], ARRAY['A'])$$,
  'P0002',
  'query returned no rows for authority key nobody',
  'an authority the collection does not carry is refused, not joined away'
);

SELECT throws_ok(
  $$SELECT geo_genius.upsert_area_many('mirror',
      ARRAY['mirror_auth'], ARRAY['nosuchtype'], ARRAY['A'])$$,
  'P0002',
  'query returned no rows for area type key nosuchtype',
  'an area type the collection does not carry is refused, not joined away'
);

-- A short array does not fail on its own: unnest pads it with nulls, and the
-- batch would be written with an area type of NULL rather than refused.
SELECT throws_ok(
  $$SELECT geo_genius.upsert_area_many('mirror',
      ARRAY['mirror_auth', 'mirror_auth'], ARRAY['outer'], ARRAY['A', 'B'])$$,
  '22023',
  'authority keys and area type keys must carry the same number of elements, and they carry 2 and 1',
  'arrays of different lengths are refused'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_area_name_many(
      geo_genius_test.import_run_id('mirror', 'm1'),
      geo_genius_test.import_executor_id('mirror', 'm1'),
      ARRAY['mirror_auth:outer:A'], ARRAY[NULL]::text[], ARRAY['official'],
      ARRAY[NULL]::text[])$$,
  '22004',
  'names must not contain a null element, and element 1 is null',
  'a null element in a required column is refused'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_area_code_many(
      geo_genius_test.import_run_id('mirror', 'm1'),
      geo_genius_test.import_executor_id('mirror', 'm1'),
      ARRAY['mirror_auth:nosuch:X'], ARRAY['fips'], ARRAY['01'])$$,
  'P0002',
  'query returned no rows for area key mirror_auth:nosuch:X',
  'an area key nothing in the catalog carries is refused, not joined away'
);

-- Names and codes accumulate rather than replacing each other, so a batch
-- carrying an area twice with different names writes both. A null locale is a
-- legal element, and area_name_uq compares locale NULLS NOT DISTINCT, so the
-- two unlocalized 'Alpha' rows here are one row.
SELECT geo_genius.put_area_in_release_many(
  geo_genius_test.import_run_id('mirror', 'm1'),
  geo_genius_test.import_executor_id('mirror', 'm1'),
  ARRAY['mirror_auth:outer:A', 'mirror_auth:inner:B', 'mirror_auth:inner:C'],
  ARRAY[NULL, NULL, NULL]::geography(Point, 4326)[],
  ARRAY[NULL, NULL, NULL]::jsonb[]);

SELECT is(
  cardinality(geo_genius.put_area_name_many(
    geo_genius_test.import_run_id('mirror', 'm1'),
    geo_genius_test.import_executor_id('mirror', 'm1'),
    ARRAY['mirror_auth:outer:A', 'mirror_auth:outer:A', 'mirror_auth:outer:A',
          'mirror_auth:inner:B', 'mirror_auth:inner:C'],
    ARRAY['Alpha', 'Alpha', 'Aardvark', 'Bravo', 'Charlie'],
    ARRAY['official', 'official', 'official', 'official', 'official'],
    ARRAY[NULL, NULL, NULL, NULL, NULL]::text[])),
  5,
  'put_area_name_many returns one id per input position'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.area_name
    WHERE area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'mirror_auth:outer:A')),
  2,
  'a name repeated in one batch is one row, and a second distinct name is another'
);

-- The plural write recomputes the release's official_name from every selected
-- official name, so the winner is the first by locale then name, not the last
-- one written.
SELECT is(
  (SELECT release_area.official_name
     FROM geo_genius.release_area
     JOIN geo_genius.area ON area.id = release_area.area_id
    WHERE release_area.release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'm1')
      AND area.area_key = 'mirror_auth:outer:A'),
  'Aardvark',
  'the area_name statement trigger maintains official_name through the plural write'
);

SELECT is(
  cardinality(geo_genius.put_area_code_many(
    geo_genius_test.import_run_id('mirror', 'm1'),
    geo_genius_test.import_executor_id('mirror', 'm1'),
    ARRAY['mirror_auth:outer:A', 'mirror_auth:outer:A', 'mirror_auth:inner:B'],
    ARRAY['fips', 'fips', 'fips'],
    ARRAY['01', '01', '01001'])),
  3,
  'put_area_code_many returns one id per input position, repeats included'
);

-- Membership is last-write-wins, so a key repeated inside one batch has to
-- keep the last of its occurrences rather than an arbitrary one. The two
-- payloads differ in both columns the upsert overwrites.
SELECT geo_genius.put_area_in_release_many(
  geo_genius_test.import_run_id('mirror', 'm1'),
  geo_genius_test.import_executor_id('mirror', 'm1'),
  ARRAY['mirror_auth:outer:A', 'mirror_auth:inner:B', 'mirror_auth:outer:A',
        'mirror_auth:inner:C'],
  ARRAY[
    ST_GeogFromText('POINT(1 1)'), ST_GeogFromText('POINT(2 2)'),
    ST_GeogFromText('POINT(9 9)'), NULL
  ]::geography(Point, 4326)[],
  ARRAY['{"pass": 1}', '{"pass": 1}', '{"pass": 2}', NULL]::jsonb[]);

SELECT is(
  (SELECT release_area.data
     FROM geo_genius.release_area
     JOIN geo_genius.area ON area.id = release_area.area_id
    WHERE release_area.release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'm1')
      AND area.area_key = 'mirror_auth:outer:A'),
  '{"pass": 2}'::jsonb,
  'membership repeated in one batch keeps the last occurrence, not the first'
);

SELECT is(
  (SELECT ST_AsText(release_area.centroid::geometry)
     FROM geo_genius.release_area
     JOIN geo_genius.area ON area.id = release_area.area_id
    WHERE release_area.release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'm1')
      AND area.area_key = 'mirror_auth:outer:A'),
  'POINT(9 9)',
  'the last occurrence wins on every column the upsert overwrites, centroid included'
);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.import_run_id('mirror', 'm1'),
  geo_genius_test.import_executor_id('mirror', 'm1'),
  'relating'
);
SELECT geo_genius.put_relation_many(
  geo_genius_test.import_run_id('mirror', 'm1'),
  geo_genius_test.import_executor_id('mirror', 'm1'),
  ARRAY['mirror_auth:outer:A', 'mirror_auth:outer:A'],
  ARRAY['mirror_auth:inner:B', 'mirror_auth:inner:B'],
  ARRAY['overlaps', 'contains']);

SELECT is(
  (SELECT relation_type FROM geo_genius.relation
    WHERE release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'm1')),
  'contains',
  'a relation repeated in one batch keeps the last relation_type'
);

SELECT throws_ok(
  $$SELECT geo_genius.put_relation_many(
      geo_genius_test.import_run_id('mirror', 'm1'),
      geo_genius_test.import_executor_id('mirror', 'm1'),
      ARRAY['mirror_auth:outer:A'], ARRAY['mirror_auth:inner:B'], ARRAY['adjoins'])$$,
  '22023',
  'unknown relation type adjoins',
  'put_relation_many refuses an unknown relation type'
);

-- The same input again, written into demo one scalar call at a time. The
-- fixture already gave demo A and B with their names, so only what mirror
-- received above is added, in the order the plural forms received it.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'inner', 'C');
SELECT geo_genius.put_area_in_release(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:inner:C', NULL, NULL);
SELECT geo_genius.put_area_name(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'demo_auth:outer:A', 'Alpha', 'official', NULL);
SELECT geo_genius.put_area_name(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'demo_auth:outer:A', 'Alpha', 'official', NULL);
SELECT geo_genius.put_area_name(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'demo_auth:outer:A', 'Aardvark', 'official', NULL);
SELECT geo_genius.put_area_name(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'demo_auth:inner:B', 'Bravo', 'official', NULL);
SELECT geo_genius.put_area_name(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'demo_auth:inner:C', 'Charlie', 'official', NULL);
SELECT geo_genius.put_area_code(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'demo_auth:outer:A', 'fips', '01');
SELECT geo_genius.put_area_code(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'demo_auth:outer:A', 'fips', '01');
SELECT geo_genius.put_area_code(geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(), 'demo_auth:inner:B', 'fips', '01001');

SELECT geo_genius.put_area_in_release(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:outer:A', ST_GeogFromText('POINT(1 1)'), '{"pass": 1}'::jsonb);
SELECT geo_genius.put_area_in_release(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:inner:B', ST_GeogFromText('POINT(2 2)'), '{"pass": 1}'::jsonb);
SELECT geo_genius.put_area_in_release(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:outer:A', ST_GeogFromText('POINT(9 9)'), '{"pass": 2}'::jsonb);
SELECT geo_genius.put_area_in_release(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:inner:C', NULL, NULL);

SELECT geo_genius_test.advance_import_to(
  geo_genius_test.demo_run_id(), geo_genius_test.demo_executor_id(),
  'relating');
SELECT geo_genius.put_relation(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:outer:A', 'demo_auth:inner:B', 'overlaps');
SELECT geo_genius.put_relation(
  geo_genius_test.demo_run_id(),
  geo_genius_test.demo_executor_id(),
  'demo_auth:outer:A', 'demo_auth:inner:B', 'contains');

-- to_jsonb renders a whole row keyed by column name, so a value landing in the
-- wrong column is caught as well as a value going missing.
SELECT is(
  (SELECT jsonb_agg(row ORDER BY row ->> 'area_key')
     FROM (
       SELECT to_jsonb(area) - 'id' - 'collection_id' - 'authority_id' - 'area_type_id'
              - 'area_key' - 'inserted_at' - 'updated_at' - 'successor_id'
              || jsonb_build_object('area_key', geo_genius_test.type_and_code(area.area_key))
                AS row
         FROM geo_genius.area
        WHERE area.collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo')
     ) demo_rows),
  (SELECT jsonb_agg(row ORDER BY row ->> 'area_key')
     FROM (
       SELECT to_jsonb(area) - 'id' - 'collection_id' - 'authority_id' - 'area_type_id'
              - 'area_key' - 'inserted_at' - 'updated_at' - 'successor_id'
              || jsonb_build_object('area_key', geo_genius_test.type_and_code(area.area_key))
                AS row
         FROM geo_genius.area
        WHERE area.collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'mirror')
     ) mirror_rows),
  'the scalar and plural forms leave the same areas, column for column'
);

SELECT is(
  (SELECT jsonb_agg(row ORDER BY row ->> 'area_key', row ->> 'name')
     FROM (
       SELECT to_jsonb(area_name) - 'id' - 'area_id'
              || jsonb_build_object('area_key', geo_genius_test.type_and_code(area.area_key))
                AS row
         FROM geo_genius.area_name
         JOIN geo_genius.area ON area.id = area_name.area_id
        WHERE area.collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo')
     ) demo_rows),
  (SELECT jsonb_agg(row ORDER BY row ->> 'area_key', row ->> 'name')
     FROM (
       SELECT to_jsonb(area_name) - 'id' - 'area_id'
              || jsonb_build_object('area_key', geo_genius_test.type_and_code(area.area_key))
                AS row
         FROM geo_genius.area_name
         JOIN geo_genius.area ON area.id = area_name.area_id
        WHERE area.collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'mirror')
     ) mirror_rows),
  'the scalar and plural forms leave the same names, column for column'
);

SELECT is(
  (SELECT jsonb_agg(row ORDER BY row ->> 'area_key', row ->> 'code_value')
     FROM (
       SELECT to_jsonb(area_code) - 'id' - 'area_id'
              || jsonb_build_object('area_key', geo_genius_test.type_and_code(area.area_key))
                AS row
         FROM geo_genius.area_code
         JOIN geo_genius.area ON area.id = area_code.area_id
        WHERE area.collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'demo')
     ) demo_rows),
  (SELECT jsonb_agg(row ORDER BY row ->> 'area_key', row ->> 'code_value')
     FROM (
       SELECT to_jsonb(area_code) - 'id' - 'area_id'
              || jsonb_build_object('area_key', geo_genius_test.type_and_code(area.area_key))
                AS row
         FROM geo_genius.area_code
         JOIN geo_genius.area ON area.id = area_code.area_id
        WHERE area.collection_id = (SELECT id FROM geo_genius.collection WHERE key = 'mirror')
     ) mirror_rows),
  'the scalar and plural forms leave the same codes, column for column'
);

SELECT is(
  (SELECT jsonb_agg(row ORDER BY row ->> 'area_key')
     FROM (
       SELECT to_jsonb(membership) - 'release_id' - 'area_id'
              || jsonb_build_object('area_key', geo_genius_test.type_and_code(area.area_key))
                AS row
         FROM geo_genius.release_area membership
         JOIN geo_genius.area ON area.id = membership.area_id
        WHERE membership.release_id =
              (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
     ) demo_rows),
  (SELECT jsonb_agg(row ORDER BY row ->> 'area_key')
     FROM (
       SELECT to_jsonb(membership) - 'release_id' - 'area_id'
              || jsonb_build_object('area_key', geo_genius_test.type_and_code(area.area_key))
                AS row
         FROM geo_genius.release_area membership
         JOIN geo_genius.area ON area.id = membership.area_id
        WHERE membership.release_id =
              (SELECT id FROM geo_genius.release WHERE release_key = 'm1')
     ) mirror_rows),
  'the scalar and plural forms leave the same release membership, column for column'
);

SELECT is(
  (SELECT jsonb_agg(row ORDER BY row ->> 'parent_area_key')
     FROM (
       SELECT to_jsonb(edge) - 'release_id' - 'parent_area_id' - 'child_area_id'
              || jsonb_build_object(
                   'parent_area_key', geo_genius_test.type_and_code(parent.area_key),
                   'child_area_key', geo_genius_test.type_and_code(child.area_key)) AS row
         FROM geo_genius.relation edge
         JOIN geo_genius.area parent ON parent.id = edge.parent_area_id
         JOIN geo_genius.area child ON child.id = edge.child_area_id
        WHERE edge.release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'r1')
     ) demo_rows),
  (SELECT jsonb_agg(row ORDER BY row ->> 'parent_area_key')
     FROM (
       SELECT to_jsonb(edge) - 'release_id' - 'parent_area_id' - 'child_area_id'
              || jsonb_build_object(
                   'parent_area_key', geo_genius_test.type_and_code(parent.area_key),
                   'child_area_key', geo_genius_test.type_and_code(child.area_key)) AS row
         FROM geo_genius.relation edge
         JOIN geo_genius.area parent ON parent.id = edge.parent_area_id
         JOIN geo_genius.area child ON child.id = edge.child_area_id
        WHERE edge.release_id = (SELECT id FROM geo_genius.release WHERE release_key = 'm1')
     ) mirror_rows),
  'the scalar and plural forms leave the same relations, column for column'
);

SELECT finish();

ROLLBACK;
