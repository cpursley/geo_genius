BEGIN;

-- Proves the resolve() cascade: strategy ordering and restriction, the
-- lon/lat pairing guard, that it works for a metadata-only (boundary-less)
-- reference hierarchy exactly as it does for a geometried one, that
-- parent_area_key scopes the name branch to a subtree, and that an
-- explicit target_release_id reaches an unpublished release.

SELECT geo_genius_test.demo_fixture();
SELECT geo_genius.put_area_code('demo_auth:outer:A', 'postal', '30309');

-- A metadata-only collection: no boundaries anywhere, membership and
-- hierarchy come entirely from release_area and relation rows.
SELECT geo_genius.upsert_collection('refdir', 'Reference Directory', NULL, false);
SELECT geo_genius.upsert_authority('refdir', 'ref_auth', 'Reference Authority');
SELECT geo_genius.upsert_area_type('refdir', 'state', 10);
SELECT geo_genius.upsert_area_type('refdir', 'city', 20);
SELECT geo_genius.upsert_area('refdir', 'ref_auth', 'state', 'GA');
SELECT geo_genius.upsert_area('refdir', 'ref_auth', 'state', 'FL');
SELECT geo_genius.upsert_area('refdir', 'ref_auth', 'city', 'springfield_ga');
SELECT geo_genius.upsert_area('refdir', 'ref_auth', 'city', 'springfield_fl');
SELECT geo_genius.upsert_area('refdir', 'ref_auth', 'city', 'macon');

SELECT geo_genius.put_area_name('ref_auth:state:GA', 'Georgia', 'official', NULL);
SELECT geo_genius.put_area_name('ref_auth:state:FL', 'Florida', 'official', NULL);
-- Same name under two different states, to prove parent_area_key scoping
-- actually restricts the name branch instead of just returning the first
-- match: an unscoped search for "Springfield" has two equally-scored
-- candidates.
SELECT geo_genius.put_area_name('ref_auth:city:springfield_ga', 'Springfield', 'official', NULL);
SELECT geo_genius.put_area_name('ref_auth:city:springfield_fl', 'Springfield', 'official', NULL);
SELECT geo_genius.put_area_name('ref_auth:city:macon', 'Macon', 'official', NULL);
SELECT geo_genius.put_area_code('ref_auth:city:springfield_ga', 'postal', '30301');

INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'refdir_r1', '{}'::jsonb FROM geo_genius.collection WHERE key = 'refdir';

SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r1'));

SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r1'),
  'ref_auth:state:GA', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r1'),
  'ref_auth:state:FL', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r1'),
  'ref_auth:city:springfield_ga', NULL, '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r1'),
  'ref_auth:city:springfield_fl', NULL, '{}'::jsonb);

SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r1'),
  'ref_auth:state:GA', 'ref_auth:city:springfield_ga', 'contains');
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r1'),
  'ref_auth:state:FL', 'ref_auth:city:springfield_fl', 'contains');

INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'refdir:src', 'refdir', 'test' FROM geo_genius.collection WHERE key = 'refdir';
INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'refdir:src';
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'refdir_r1';

SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r1'));

-- A second, unpublished release of the same collection carries an area
-- ('Macon') that r1 never had -- only an explicit target_release_id can
-- reach it.
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'refdir_r2', '{}'::jsonb FROM geo_genius.collection WHERE key = 'refdir';

SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r2'));

SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r2'),
  'ref_auth:city:macon', NULL, '{}'::jsonb);

SELECT plan(16);

SELECT is(
  (SELECT match_method FROM geo_genius.resolve(
    '{"lon": 0.75, "lat": 0.75, "code_type": "postal", "code_value": "30309"}'::jsonb,
    NULL, NULL, NULL, NULL) LIMIT 1),
  'containment',
  'containment outranks code when coordinates are present'
);

SELECT is(
  (SELECT match_method FROM geo_genius.resolve(
    '{"code_type": "postal", "code_value": "30309"}'::jsonb,
    NULL, NULL, NULL, NULL) LIMIT 1),
  'code',
  'code resolves when there are no coordinates'
);

SELECT is(
  (SELECT match_method FROM geo_genius.resolve(
    '{"lon": 0.75, "lat": 0.75, "code_type": "postal", "code_value": "30309"}'::jsonb,
    NULL, NULL, ARRAY['code', 'containment'], NULL) LIMIT 1),
  'code',
  'the strategies argument reorders the cascade'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.resolve(
    '{"lon": 50.0, "lat": 50.0}'::jsonb, NULL, NULL, ARRAY['containment'], NULL)),
  0,
  'restricting strategies prevents a fallback'
);

SELECT is(
  (SELECT match_method FROM geo_genius.resolve(
    '{"name": "Alpha"}'::jsonb, NULL, NULL, NULL, NULL) LIMIT 1),
  'name',
  'name resolution runs when nothing earlier matches'
);

SELECT throws_ok(
  $$SELECT * FROM geo_genius.resolve('{"lon": 0.5}'::jsonb, NULL, NULL, NULL, NULL)$$,
  '22023',
  NULL,
  'a partial coordinate pair is rejected'
);

SELECT is(
  (SELECT area_key FROM geo_genius.resolve(
    '{"code_type": "postal", "code_value": "30301"}'::jsonb,
    NULL, NULL, NULL, NULL) LIMIT 1),
  'ref_auth:city:springfield_ga',
  'a metadata-only area resolves through the code strategy'
);

-- Guards types being threaded through to areas_by_code: the code matches
-- a 'city', so restricting types to 'state' must suppress it rather than
-- ignore the filter.
SELECT is(
  (SELECT count(*)::int FROM geo_genius.resolve(
    '{"code_type": "postal", "code_value": "30301"}'::jsonb,
    NULL, ARRAY['state'], NULL, NULL)),
  0,
  'a types filter that excludes the matched area suppresses a code resolution'
);

SELECT is(
  (SELECT area_key FROM geo_genius.resolve(
    '{"name": "Georgia"}'::jsonb, NULL, NULL, NULL, NULL) LIMIT 1),
  'ref_auth:state:GA',
  'a metadata-only area resolves through the name strategy'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.resolve(
    '{"name": "Springfield", "parent_area_key": "ref_auth:state:GA"}'::jsonb,
    NULL, NULL, NULL, NULL)),
  1,
  'parent_area_key scopes the name branch to one subtree out of two equally-named candidates'
);

SELECT is(
  (SELECT area_key FROM geo_genius.resolve(
    '{"name": "Macon"}'::jsonb, NULL, NULL, NULL,
    (SELECT id FROM geo_genius.release WHERE release_key = 'refdir_r2')) LIMIT 1),
  'ref_auth:city:macon',
  'an explicit target_release_id reaches an unpublished release''s data'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.resolve(
    '{"name": "Macon"}'::jsonb, NULL, NULL, NULL, NULL)),
  0,
  'without the pin, the unpublished release''s area is not resolvable'
);

-- A retired area is a saved reference that must keep resolving, on demand
-- -- excluded by default (matching every delegate's own default), reachable
-- with include_retired => true. Retiring here, at the end of the file,
-- so no earlier assertion (which relies on these two areas being live)
-- is disturbed.
UPDATE geo_genius.area SET retired_at = now() WHERE area_key = 'ref_auth:city:springfield_ga';
UPDATE geo_genius.area SET retired_at = now() WHERE area_key = 'ref_auth:state:GA';

SELECT is(
  (SELECT count(*)::int FROM geo_genius.resolve(
    '{"code_type": "postal", "code_value": "30301"}'::jsonb,
    NULL, NULL, NULL, NULL)),
  0,
  'a retired area is not resolvable through the code strategy by default'
);

SELECT is(
  (SELECT area_key FROM geo_genius.resolve(
    '{"code_type": "postal", "code_value": "30301"}'::jsonb,
    NULL, NULL, NULL, NULL, true) LIMIT 1),
  'ref_auth:city:springfield_ga',
  'include_retired reaches a retired area through the code strategy'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.resolve(
    '{"name": "Georgia"}'::jsonb, NULL, NULL, NULL, NULL)),
  0,
  'a retired area is not resolvable through the name strategy by default'
);

SELECT is(
  (SELECT area_key FROM geo_genius.resolve(
    '{"name": "Georgia"}'::jsonb, NULL, NULL, NULL, NULL, true) LIMIT 1),
  'ref_auth:state:GA',
  'include_retired reaches a retired area through the name strategy'
);

SELECT finish();

ROLLBACK;
