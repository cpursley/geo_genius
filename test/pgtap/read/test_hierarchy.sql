BEGIN;

-- r1 is extended below, so it is built unpublished and published once the
-- whole graph is in place: a published release is immutable.
SELECT geo_genius_test.demo_fixture_build();

SELECT geo_genius.upsert_area_type('demo', 'innermost', 30);
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'innermost', 'C');
SELECT geo_genius.put_area_name('demo_auth:innermost:C', 'Charlie', 'official', NULL);
SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:innermost:C',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((0 0, 0.2 0, 0.2 0.2, 0 0.2, 0 0))', 4326), 0.0);

SELECT geo_genius.rebuild_relations(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'));

-- A two-node cycle asserted directly (not measured from geometry): D
-- overlaps E, E overlaps D. Neither area needs a boundary -- put_relation
-- accepts any two areas that are already members of the release, which is
-- exactly how a cyclic overlap graph can show up from asserted source data.
SELECT geo_genius.upsert_area_type('demo', 'unranked', 40);
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'D');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'E');
SELECT geo_genius.put_area_name('demo_auth:unranked:D', 'Delta', 'official', NULL);
SELECT geo_genius.put_area_name('demo_auth:unranked:E', 'Echo', 'official', NULL);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:D', ST_GeogFromText('POINT(5 5)'), '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:E', ST_GeogFromText('POINT(6 6)'), '{}'::jsonb);
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:D', 'demo_auth:unranked:E', 'overlaps');
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:E', 'demo_auth:unranked:D', 'overlaps');

-- A three-node cycle asserted directly: F overlaps G, G overlaps H, H
-- overlaps F -- a longer walk back to the origin than the two-node case
-- above, still guarded by the same per-branch visited array.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'F');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'G');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'H');
SELECT geo_genius.put_area_name('demo_auth:unranked:F', 'Foxtrot', 'official', NULL);
SELECT geo_genius.put_area_name('demo_auth:unranked:G', 'Golf', 'official', NULL);
SELECT geo_genius.put_area_name('demo_auth:unranked:H', 'Hotel', 'official', NULL);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:F', ST_GeogFromText('POINT(7 7)'), '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:G', ST_GeogFromText('POINT(8 8)'), '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:H', ST_GeogFromText('POINT(9 9)'), '{}'::jsonb);
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:F', 'demo_auth:unranked:G', 'overlaps');
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:G', 'demo_auth:unranked:H', 'overlaps');
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:H', 'demo_auth:unranked:F', 'overlaps');

-- A diamond: two independent paths (W->X->Z and W->Y->Z) converge on Z.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'W');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'X');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'Y');
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'unranked', 'Z');
SELECT geo_genius.put_area_name('demo_auth:unranked:W', 'Whiskey', 'official', NULL);
SELECT geo_genius.put_area_name('demo_auth:unranked:X', 'Xray', 'official', NULL);
SELECT geo_genius.put_area_name('demo_auth:unranked:Y', 'Yankee', 'official', NULL);
SELECT geo_genius.put_area_name('demo_auth:unranked:Z', 'Zulu', 'official', NULL);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:W', ST_GeogFromText('POINT(10 10)'), '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:X', ST_GeogFromText('POINT(11 11)'), '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:Y', ST_GeogFromText('POINT(12 12)'), '{}'::jsonb);
SELECT geo_genius.put_area_in_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:Z', ST_GeogFromText('POINT(13 13)'), '{}'::jsonb);
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:W', 'demo_auth:unranked:X', 'overlaps');
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:W', 'demo_auth:unranked:Y', 'overlaps');
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:X', 'demo_auth:unranked:Z', 'overlaps');
SELECT geo_genius.put_relation(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:unranked:Y', 'demo_auth:unranked:Z', 'overlaps');

SELECT plan(10);

-- Asserted before publication: put_relation refuses to write to a published
-- release at all, so the self-relation constraint can only be reached while
-- r1 is still mutable.
SELECT throws_ok(
  $$SELECT geo_genius.put_relation(
      (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
      'demo_auth:unranked:F', 'demo_auth:unranked:F', 'overlaps')$$,
  '23514',
  NULL,
  'put_relation rejects a self relation via relation_distinct_areas_chk'
);

SELECT geo_genius_test.demo_publish();

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.children_of('demo_auth:outer:A', NULL, NULL, 1, NULL)),
  2,
  'depth 1 returns both directly contained areas'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.children_of('demo_auth:outer:A', ARRAY['inner'], NULL, 1, NULL)),
  1,
  'the types filter narrows children'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.ancestors_of('demo_auth:innermost:C', NULL, NULL, 5, NULL)),
  2,
  'ancestors walk up to every containing area'
);

SELECT is(
  (SELECT match_method
     FROM geo_genius.children_of('demo_auth:outer:A', ARRAY['inner'], NULL, 1, NULL)),
  'relation',
  'traversal results are stamped as relation matches'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.related_areas('demo_auth:outer:A', ARRAY['contains'], NULL)),
  2,
  'related_areas filters by classification'
);

SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.children_of('demo_auth:unranked:D', NULL, NULL, 1000, NULL)),
  1,
  'a two-node overlap cycle terminates at a generous max_depth without looping'
);

SELECT is(
  (SELECT area_key
     FROM geo_genius.children_of('demo_auth:unranked:D', NULL, NULL, 1000, NULL)),
  'demo_auth:unranked:E',
  'the visited-set guard excludes the origin area from its own children'
);

SELECT is(
  (SELECT array_agg(area_key ORDER BY area_key)
     FROM geo_genius.children_of('demo_auth:unranked:F', NULL, NULL, 1000, NULL)),
  ARRAY['demo_auth:unranked:G', 'demo_auth:unranked:H'],
  'a three-node overlap cycle terminates and returns exactly its two other members, excluding the origin'
);

-- The visited array is tracked per branch, not globally: the branch that
-- reaches Z through X and the branch that reaches Z through Y each carry
-- their own visited path, and neither excludes the other from also
-- reaching Z. Z therefore appears twice in the recursive term's raw
-- output (once per converging path) and collapses to a single row only
-- because the outer SELECT DISTINCT ON (area.area_key) removes the
-- duplicate. Removing that DISTINCT ON would surface Z once per
-- converging path instead of once per area.
SELECT is(
  (SELECT count(*)::int
     FROM geo_genius.children_of('demo_auth:unranked:W', NULL, NULL, 5, NULL)
    WHERE area_key = 'demo_auth:unranked:Z'),
  1,
  'convergent paths through a diamond collapse to exactly one row for the shared descendant'
);


SELECT finish();

ROLLBACK;
