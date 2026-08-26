-- area.official_name is denormalized, so the only thing standing between a
-- host and a stale name is the trigger that maintains it. Every way a name can
-- change has to leave the column agreeing with the rule the column stands for:
-- the official-kind name, locale NULLS FIRST, then name.
BEGIN;

SELECT plan(9);

SELECT geo_genius.upsert_collection('names', 'Names', NULL);
SELECT geo_genius.upsert_authority('names', 'n_auth', 'Names Authority');
SELECT geo_genius.upsert_area_type('names', 'unit', 10);
SELECT geo_genius.upsert_area('names', 'n_auth', 'unit', 'A');
SELECT geo_genius.upsert_area('names', 'n_auth', 'unit', 'B');

SELECT is(
  (SELECT official_name FROM geo_genius.area WHERE area_key = 'n_auth:unit:A'),
  NULL,
  'an area with no names has no official name'
);

SELECT geo_genius.put_area_name('n_auth:unit:A', 'Alpha', 'official', NULL);

SELECT is(
  (SELECT official_name FROM geo_genius.area WHERE area_key = 'n_auth:unit:A'),
  'Alpha',
  'adding an official name sets it'
);

-- An alias must not win, however it sorts.
SELECT geo_genius.put_area_name('n_auth:unit:A', 'Aaaa', 'alias', NULL);

SELECT is(
  (SELECT official_name FROM geo_genius.area WHERE area_key = 'n_auth:unit:A'),
  'Alpha',
  'a non-official name never becomes the official name'
);

-- A localized official name that sorts earlier must still lose to the
-- unlocalized one: locale NULLS FIRST decides before name does.
SELECT geo_genius.put_area_name('n_auth:unit:A', 'Aaa', 'official', 'aa');

SELECT is(
  (SELECT official_name FROM geo_genius.area WHERE area_key = 'n_auth:unit:A'),
  'Alpha',
  'an unlocalized official name outranks an alphabetically earlier localized one'
);

-- With no unlocalized name at all, locale order decides.
SELECT geo_genius.put_area_name('n_auth:unit:B', 'Zulu', 'official', 'en');
SELECT geo_genius.put_area_name('n_auth:unit:B', 'Bravo', 'official', 'aa');

SELECT is(
  (SELECT official_name FROM geo_genius.area WHERE area_key = 'n_auth:unit:B'),
  'Bravo',
  'locale ordering decides when no unlocalized official name exists'
);

-- Removing the winner promotes the next one rather than leaving it stale.
DELETE FROM geo_genius.area_name
 WHERE area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'n_auth:unit:A')
   AND name = 'Alpha';

SELECT is(
  (SELECT official_name FROM geo_genius.area WHERE area_key = 'n_auth:unit:A'),
  'Aaa',
  'deleting the winning name promotes the next candidate'
);

-- Reassigning a name has to settle both the area losing it and the one
-- gaining it, which is the case a single-area refresh would miss.
UPDATE geo_genius.area_name
   SET area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'n_auth:unit:B')
 WHERE area_id = (SELECT id FROM geo_genius.area WHERE area_key = 'n_auth:unit:A')
   AND name = 'Aaa';

SELECT is(
  (SELECT official_name FROM geo_genius.area WHERE area_key = 'n_auth:unit:A'),
  NULL,
  'moving a name away clears the official name of the area that lost it'
);

SELECT is(
  (SELECT official_name FROM geo_genius.area WHERE area_key = 'n_auth:unit:B'),
  'Aaa',
  'moving a name in updates the official name of the area that gained it'
);

-- One statement touching many areas must settle all of them, not just one.
SELECT geo_genius.upsert_area('names', 'n_auth', 'unit', 'C');
SELECT geo_genius.upsert_area('names', 'n_auth', 'unit', 'D');

INSERT INTO geo_genius.area_name (area_id, name, kind, locale)
SELECT id, 'Bulk ' || code, 'official', NULL
  FROM geo_genius.area WHERE area_key IN ('n_auth:unit:C', 'n_auth:unit:D');

SELECT is(
  (SELECT count(*)::int FROM geo_genius.area
    WHERE area_key IN ('n_auth:unit:C', 'n_auth:unit:D')
      AND official_name = 'Bulk ' || code),
  2,
  'one statement inserting names for several areas settles every one of them'
);

SELECT finish();

ROLLBACK;
