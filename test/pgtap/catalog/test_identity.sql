BEGIN;

SELECT plan(15);

SELECT has_table('geo_genius', 'collection', 'collection table exists');
SELECT has_table('geo_genius', 'authority', 'authority table exists');
SELECT has_table('geo_genius', 'area_type', 'area_type table exists');
SELECT has_table('geo_genius', 'area', 'area table exists');
SELECT has_table('geo_genius', 'area_name', 'area_name table exists');
SELECT has_table('geo_genius', 'area_code', 'area_code table exists');

INSERT INTO geo_genius.collection (key, name)
VALUES ('demo', 'Demo');

INSERT INTO geo_genius.authority (collection_id, key, name)
SELECT id, 'demo_auth', 'Demo Authority' FROM geo_genius.collection WHERE key = 'demo';

INSERT INTO geo_genius.area_type (collection_id, key, rank)
SELECT id, 'region', 10 FROM geo_genius.collection WHERE key = 'demo';

INSERT INTO geo_genius.area (collection_id, authority_id, area_type_id, code, area_key)
SELECT c.id, a.id, t.id, '01', 'demo_auth:region:01'
FROM geo_genius.collection c
JOIN geo_genius.authority a ON a.collection_id = c.id
JOIN geo_genius.area_type t ON t.collection_id = c.id
WHERE c.key = 'demo';

SELECT is(
  (SELECT area_key FROM geo_genius.area WHERE code = '01'),
  'demo_auth:region:01',
  'area carries its portable key'
);

SELECT throws_ok(
  $$INSERT INTO geo_genius.collection (key, name) VALUES ('Bad Key', 'x')$$,
  '23514',
  NULL,
  'collection key must be a lowercase identifier'
);

SELECT throws_ok(
  $$INSERT INTO geo_genius.area (collection_id, authority_id, area_type_id, code, area_key)
    SELECT c.id, a.id, t.id, '01', 'demo_auth:region:01'
    FROM geo_genius.collection c
    JOIN geo_genius.authority a ON a.collection_id = c.id
    JOIN geo_genius.area_type t ON t.collection_id = c.id
    WHERE c.key = 'demo'$$,
  '23505',
  NULL,
  'area_key is globally unique'
);

SELECT throws_ok(
  $$UPDATE geo_genius.area SET successor_id = id WHERE code = '01'$$,
  '23514',
  NULL,
  'an area cannot succeed itself'
);

SELECT throws_ok(
  $$INSERT INTO geo_genius.area_type (collection_id, key, rank)
    SELECT id, 'other', 10 FROM geo_genius.collection WHERE key = 'demo'$$,
  '23505',
  NULL,
  'type rank is unique within a collection'
);

INSERT INTO geo_genius.area_name (area_id, name, kind)
SELECT id, 'Region One', 'official' FROM geo_genius.area WHERE code = '01';

INSERT INTO geo_genius.area_code (area_id, code_type, code_value)
SELECT id, 'postal', '30309' FROM geo_genius.area WHERE code = '01';

SELECT is(
  (SELECT count(*)::int FROM geo_genius.area_name WHERE kind = 'official'),
  1,
  'official name stored'
);

SELECT throws_ok(
  $$INSERT INTO geo_genius.area_name (area_id, name, kind)
    SELECT id, 'Region One', 'nonsense' FROM geo_genius.area WHERE code = '01'$$,
  '23514',
  NULL,
  'name kind is constrained'
);

SELECT has_index('geo_genius', 'area_code', 'area_code_lookup_idx', 'code lookup index exists');
SELECT has_index('geo_genius', 'area_name', 'area_name_trgm_idx', 'name trigram index exists');

SELECT finish();

ROLLBACK;
