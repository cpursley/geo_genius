BEGIN;

SELECT plan(23);

SELECT has_view('geo_genius', 'published_areas', 'published_areas exists');
SELECT has_view('geo_genius', 'published_area_codes', 'published_area_codes exists');
SELECT has_view('geo_genius', 'published_area_names', 'published_area_names exists');
SELECT has_view('geo_genius', 'published_area_relations', 'published_area_relations exists');
SELECT has_view('geo_genius', 'published_boundaries', 'published_boundaries exists');

SELECT geo_genius.upsert_collection('demo', 'Demo', NULL);
SELECT geo_genius.upsert_authority('demo', 'demo_auth', 'Demo Authority');
SELECT geo_genius.upsert_area_type('demo', 'outer', 10);
SELECT geo_genius.upsert_area_type('demo', 'inner', 20);
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'A');
SELECT geo_genius.put_area_name('demo_auth:outer:A', 'Alpha', 'official', NULL);
SELECT geo_genius.put_area_code('demo_auth:outer:A', 'postal', '30309');

INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r1', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';
SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'));
INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'demo:src', 'demo', 'test' FROM geo_genius.collection WHERE key = 'demo';
INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'demo:src';
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'r1';
SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:outer:A',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326),
  0.0
);

-- Area B is never given a boundary in any release. It exists (with a name
-- and a code) purely to prove that published_area_codes/published_area_names
-- cannot leak an area that publication never made visible -- they build on
-- published_areas, so they inherit its scoping instead of re-deriving it.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'B');
SELECT geo_genius.put_area_name('demo_auth:outer:B', 'Bravo', 'official', NULL);
SELECT geo_genius.put_area_code('demo_auth:outer:B', 'postal', '30310');

-- Area C is a smaller area, fully inside A, boundaried in r1 to exercise
-- published_area_relations. It is written before publication because a
-- published release is immutable: publication is what makes the whole
-- release visible at once, with no refresh step of any kind.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'inner', 'C');
SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  'demo_auth:inner:C',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((0.1 0.1, 0.6 0.1, 0.6 0.6, 0.1 0.6, 0.1 0.1))', 4326),
  0.0
);
SELECT geo_genius.rebuild_relations(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'));

-- A second official name for A, with a non-null locale that alphabetically
-- precedes the existing NULL-locale name. If the view's name subquery just
-- ordered by name it would flip to this one; the locale NULLS FIRST rule
-- must keep 'Alpha' the winner regardless.
SELECT geo_genius.put_area_name('demo_auth:outer:A', 'Aaa', 'official', 'aa');

-- C never gets a NULL-locale name, only two locale-bearing ones, to prove
-- the "then name" tie-break actually runs when NULLS FIRST does not decide
-- the winner outright.
SELECT geo_genius.put_area_name('demo_auth:inner:C', 'Charlie', 'official', 'en');
SELECT geo_genius.put_area_name('demo_auth:inner:C', 'AlphaC', 'official', 'aa');

-- A second, coarser display_tier for A within the same release, modeling a
-- later zoom tier. published_areas must still surface A exactly once.
INSERT INTO geo_genius.boundary
  (release_id, area_id, source_release_id, geom, display_geom, display_tier)
SELECT
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'),
  (SELECT id FROM geo_genius.area WHERE area_key = 'demo_auth:outer:A'),
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'),
  ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326),
  ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326),
  1;

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_areas),
  0,
  'nothing is visible before publication'
);

SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r1'));

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:A'),
  1,
  'the published release becomes visible'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:A'),
  1,
  'a later display tier does not duplicate the area row'
);

SELECT is(
  (SELECT name FROM geo_genius.published_areas WHERE area_key = 'demo_auth:outer:A'),
  'Alpha',
  'name resolution keeps the NULL-locale official name over an alphabetically earlier one'
);

SELECT is(
  (SELECT name FROM geo_genius.published_areas WHERE area_key = 'demo_auth:inner:C'),
  'AlphaC',
  'name resolution falls back to locale ordering when no NULL-locale name exists'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_area_codes
    WHERE area_key = 'demo_auth:outer:B'),
  0,
  'published_area_codes cannot leak a code for an unpublished area'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_area_names
    WHERE area_key = 'demo_auth:outer:B'),
  0,
  'published_area_names cannot leak a name for an unpublished area'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_boundaries
    WHERE area_key = 'demo_auth:outer:A'),
  2,
  'published_boundaries exposes every display tier, unlike published_areas'
);

SELECT ok(
  (SELECT geom IS NOT NULL AND display_geom IS NOT NULL
     FROM geo_genius.published_boundaries
    WHERE area_key = 'demo_auth:outer:A' AND display_tier = 0),
  'published_boundaries exposes both canonical and display geometry'
);

SELECT is(
  (SELECT relation_type FROM geo_genius.published_area_relations
    WHERE parent_area_key = 'demo_auth:outer:A' AND child_area_key = 'demo_auth:inner:C'),
  'contains',
  'published_area_relations surfaces a measured relation for the published release'
);

-- A second collection, published independently, to prove no view assumes a
-- single collection: a query spanning both must see areas from each.
SELECT geo_genius.upsert_collection('demo2', 'Demo Two', NULL);
SELECT geo_genius.upsert_authority('demo2', 'demo2_auth', 'Demo Two Authority');
SELECT geo_genius.upsert_area_type('demo2', 'outer', 10);
SELECT geo_genius.upsert_area('demo2', 'demo2_auth', 'outer', 'E');
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'demo2-r1', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo2';
SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'demo2-r1'));
INSERT INTO geo_genius.source (collection_id, source_key, provider, license)
SELECT id, 'demo2:src', 'demo', 'test' FROM geo_genius.collection WHERE key = 'demo2';
INSERT INTO geo_genius.source_release (source_id, release_key)
SELECT id, 'v1' FROM geo_genius.source WHERE source_key = 'demo2:src';
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'demo2-r1';
SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'demo2-r1'),
  'demo2_auth:outer:E',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'
    AND source_id = (SELECT id FROM geo_genius.source WHERE source_key = 'demo2:src')),
  ST_GeomFromText('POLYGON((10 10, 11 10, 11 11, 10 11, 10 10))', 4326),
  0.0
);
SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'demo2-r1'));

SELECT is(
  (SELECT count(DISTINCT collection_key)::int FROM geo_genius.published_areas),
  2,
  'a query spanning collections sees areas from every published collection'
);

-- A release with a boundary, left at status 'pending' and never passed to
-- publish_release: it must stay invisible, proving no view exposes an
-- unpublished release.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'F');
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r3', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';
SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r3'));
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'r3'
  AND sr.release_key = 'v1'
  AND sr.source_id = (SELECT id FROM geo_genius.source WHERE source_key = 'demo:src');
SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r3'),
  'demo_auth:outer:F',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'
    AND source_id = (SELECT id FROM geo_genius.source WHERE source_key = 'demo:src')),
  ST_GeomFromText('POLYGON((20 20, 21 20, 21 21, 20 21, 20 20))', 4326),
  0.0
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:F'),
  0,
  'a verified but unpublished release stays invisible'
);

-- The atomic-swap property: publish a second release for the same
-- collection with a different area (G), and confirm every view flips from
-- r1's areas to r2's areas together, with no refresh step of any kind.
SELECT geo_genius.upsert_area('demo', 'demo_auth', 'outer', 'G');
INSERT INTO geo_genius.release (collection_id, release_key, manifest)
SELECT id, 'r2', '{}'::jsonb FROM geo_genius.collection WHERE key = 'demo';
SELECT geo_genius.create_release_partitions(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));
INSERT INTO geo_genius.release_source (release_id, source_release_id)
SELECT r.id, sr.id FROM geo_genius.release r, geo_genius.source_release sr
WHERE r.release_key = 'r2'
  AND sr.release_key = 'v1'
  AND sr.source_id = (SELECT id FROM geo_genius.source WHERE source_key = 'demo:src');
SELECT geo_genius.put_boundary(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'),
  'demo_auth:outer:G',
  (SELECT id FROM geo_genius.source_release WHERE release_key = 'v1'
    AND source_id = (SELECT id FROM geo_genius.source WHERE source_key = 'demo:src')),
  ST_GeomFromText('POLYGON((30 30, 31 30, 31 31, 30 31, 30 30))', 4326),
  0.0
);
SELECT geo_genius.publish_release(
  (SELECT id FROM geo_genius.release WHERE release_key = 'r2'));

SELECT is(
  (SELECT area_key FROM geo_genius.published_areas WHERE collection_key = 'demo'),
  'demo_auth:outer:G',
  'the pointer swap makes r2''s area the only one visible for the collection'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_boundaries
    WHERE area_key IN ('demo_auth:outer:A', 'demo_auth:inner:C')),
  0,
  'published_boundaries drops every r1 row atomically once r2 is published'
);

SELECT is(
  (SELECT count(*)::int FROM geo_genius.published_area_relations
    WHERE parent_area_key = 'demo_auth:outer:A'),
  0,
  'published_area_relations drops r1''s relation atomically once r2 is published'
);

-- Rollback is a distinct path through publication -- it swaps release_id
-- and previous_release_id rather than overwriting the pointer forward -- so
-- it needs its own proof that every view flips back atomically, not just
-- the forward swap above.
SELECT geo_genius.rollback_publication('demo');

SELECT ok(
  (SELECT count(*)::int FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:A') = 1
  AND (SELECT count(*)::int FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:G') = 0,
  'rollback restores r1''s area in published_areas and hides r2''s'
);

SELECT ok(
  (SELECT count(*)::int FROM geo_genius.published_boundaries
    WHERE area_key = 'demo_auth:outer:A') > 0
  AND (SELECT count(*)::int FROM geo_genius.published_boundaries
    WHERE area_key = 'demo_auth:outer:G') = 0,
  'rollback restores r1''s boundary in published_boundaries and hides r2''s'
);

-- r1 is published again after the rollback, so r2 is now the completed,
-- unpublished release retire_releases will drop. Retiring it must not
-- disturb what the views show: the guarantee holds whether or not the old
-- release still physically exists.
SELECT geo_genius.retire_releases('demo', 1);

SELECT ok(
  (SELECT count(*)::int FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:A') = 1
  AND (SELECT count(*)::int FROM geo_genius.published_areas
    WHERE area_key = 'demo_auth:outer:G') = 0,
  'retiring the rolled-back-away release leaves the published view unchanged'
);

SELECT finish();

ROLLBACK;
