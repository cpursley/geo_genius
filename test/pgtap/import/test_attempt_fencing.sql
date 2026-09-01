BEGIN;

-- An import attempt is the authority for every candidate mutation. The guard
-- must run inside the same statement as the write: a separate preflight can
-- pass, lose the release lock to an exact reset, and then write through the
-- old attempt into the replacement candidate.
CREATE FUNCTION pg_temp.attempt_fencing_available()
RETURNS boolean
LANGUAGE sql
AS $fn$
  SELECT to_regprocedure('geo_genius.assert_import_write(uuid,uuid,text[])') IS NOT NULL;
$fn$;

CREATE FUNCTION pg_temp.fencing_manifest()
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT '{
    "collection":"attempt_fencing",
    "collection_name":"Attempt Fencing",
    "release":"r1",
    "provider":"fixture",
    "requires_geometry":false,
    "authorities":[{"key":"fence_auth","name":"Fence Authority"}],
    "area_types":[
      {"key":"outer","rank":10,"requires_geometry":false},
      {"key":"inner","rank":20,"requires_geometry":false}
    ],
    "sources":[{
      "source_key":"attempt_fencing:source",
      "provider":"fixture",
      "license":"test",
      "release_key":"v1",
      "artifacts":[{
        "logical_name":"A",
        "url":"https://example.test/attempt-fencing/a",
        "operator_supplied":false,
        "format":"json",
        "required":true,
        "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bytes":10,
        "members":[],
        "metadata":{}
      }]
    }],
    "options":{}
  }'::jsonb;
$fn$;

CREATE FUNCTION pg_temp.fencing_claim(claim_owner text)
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT jsonb_build_object(
    'owner', claim_owner,
    'runner_backend', 'test',
    'stale_after_seconds', 900
  );
$fn$;

CREATE TEMP TABLE fencing_attempt (
  attempt integer PRIMARY KEY,
  release_id uuid NOT NULL,
  run_id uuid NOT NULL,
  executor_id uuid NOT NULL
);

-- These wrappers defer references to the exact-registration API until the
-- fencing interface exists. That keeps today's RED to one missing contract
-- instead of cascading into one parser error per counterfactual below.
DO $fn$
BEGIN
  IF pg_temp.attempt_fencing_available() THEN
    EXECUTE $sql$
      CREATE FUNCTION pg_temp.prepare_fencing_attempt()
      RETURNS void
      LANGUAGE plpgsql
      AS $body$
      DECLARE
        prepared record;
        retried record;
        prepared_executor_id uuid := gen_random_uuid();
        retried_executor_id uuid := gen_random_uuid();
      BEGIN
        SELECT * INTO STRICT prepared
          FROM geo_genius.prepare_import(
            pg_temp.fencing_manifest(),
            pg_temp.fencing_claim('worker-1')
          );

        PERFORM geo_genius.claim_import_execution(prepared.run_id, prepared_executor_id);

        INSERT INTO fencing_attempt(attempt, release_id, run_id, executor_id)
        VALUES (1, prepared.release_id, prepared.run_id, prepared_executor_id);

        PERFORM geo_genius.fail_import(
          prepared.run_id,
          prepared_executor_id,
          '{"reason":"fixture failure"}'::jsonb
        );

        SELECT * INTO STRICT retried
          FROM geo_genius.retry_failed(
            prepared.run_id,
            pg_temp.fencing_manifest(),
            pg_temp.fencing_claim('worker-2')
          );

        PERFORM geo_genius.claim_import_execution(retried.run_id, retried_executor_id);

        INSERT INTO fencing_attempt(attempt, release_id, run_id, executor_id)
        VALUES (2, retried.release_id, retried.run_id, retried_executor_id);
      END;
      $body$
    $sql$;
  ELSE
    EXECUTE $sql$
      CREATE FUNCTION pg_temp.prepare_fencing_attempt()
      RETURNS void
      LANGUAGE sql
      AS $body$ SELECT $body$
    $sql$;
  END IF;
END;
$fn$;

CREATE FUNCTION pg_temp.candidate_snapshot(target_release_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  relation_name text;
  relation_snapshot jsonb;
  result jsonb := '{}'::jsonb;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'release_area',
    'release_area_name',
    'release_area_code',
    'boundary',
    'boundary_part',
    'relation'
  ]
  LOOP
    EXECUTE format(
      'SELECT jsonb_build_object(
         ''count'', count(*),
         ''digest'', md5(coalesce(string_agg(row_json, E''\n'' ORDER BY row_json), ''''))
       )
       FROM (
         SELECT to_jsonb(candidate)::text AS row_json
           FROM geo_genius.%I candidate
          WHERE release_id = $1
       ) rows',
      relation_name
    ) INTO relation_snapshot USING target_release_id;

    result := result || jsonb_build_object(relation_name, relation_snapshot);
  END LOOP;

  -- Global identities are still part of the candidate write path. A stale
  -- normalizer must not be able to leave unattached areas, names, or codes
  -- behind merely because those dictionaries are shared across releases.
  result := result || jsonb_build_object(
    'areas', (
      SELECT coalesce(jsonb_agg(to_jsonb(area) ORDER BY area.id), '[]'::jsonb)
        FROM geo_genius.area
        JOIN geo_genius.release ON release.collection_id = area.collection_id
       WHERE release.id = target_release_id
    ),
    'area_names', (
      SELECT coalesce(jsonb_agg(to_jsonb(area_name) ORDER BY area_name.id), '[]'::jsonb)
        FROM geo_genius.area_name
        JOIN geo_genius.area ON area.id = area_name.area_id
        JOIN geo_genius.release ON release.collection_id = area.collection_id
       WHERE release.id = target_release_id
    ),
    'area_codes', (
      SELECT coalesce(jsonb_agg(to_jsonb(area_code) ORDER BY area_code.id), '[]'::jsonb)
        FROM geo_genius.area_code
        JOIN geo_genius.area ON area.id = area_code.area_id
        JOIN geo_genius.release ON release.collection_id = area.collection_id
       WHERE release.id = target_release_id
    ),
    'artifact_observations', (
      SELECT coalesce(
               jsonb_agg(to_jsonb(import_run_artifact)
                         ORDER BY import_run_artifact.run_id,
                                  import_run_artifact.artifact_id),
               '[]'::jsonb
             )
        FROM geo_genius.import_run_artifact
        JOIN geo_genius.import_run ON import_run.id = import_run_artifact.run_id
       WHERE import_run.release_id = target_release_id
    )
  );

  SELECT result || jsonb_build_object(
    'staging_tables', coalesce(jsonb_agg(pg_class.relname ORDER BY pg_class.relname), '[]'::jsonb)
  )
    INTO result
    FROM pg_class
    JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
   WHERE pg_namespace.nspname = 'geo_genius'
     AND pg_class.relname LIKE 'staging\_%' ESCAPE '\';

  RETURN result;
END;
$fn$;

CREATE TEMP TABLE fencing_snapshot (
  phase text PRIMARY KEY,
  state jsonb NOT NULL
);

CREATE TEMP TABLE observation_stamp (
  validated_at timestamptz NOT NULL
);

SELECT plan(58);

SELECT has_function(
  'geo_genius',
  'assert_import_write',
  ARRAY['uuid', 'uuid', 'text[]'],
  'assert_import_write exposes the executor-bound atomic attempt-fencing boundary'
);

SELECT * FROM skip(
  'assert_import_write(uuid,uuid,text[]) is not installed',
  57
) WHERE NOT pg_temp.attempt_fencing_available();

SELECT pg_temp.prepare_fencing_attempt()
 WHERE pg_temp.attempt_fencing_available();

CREATE TEMP TABLE failed_run_history AS
SELECT import_run.completed_at, import_run.error
  FROM geo_genius.import_run
 WHERE import_run.id = (SELECT run_id FROM fencing_attempt WHERE attempt = 1)
   AND pg_temp.attempt_fencing_available();

SELECT geo_genius.fail_import(
         (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 1),
         '{"reason":"late duplicate failure"}'::jsonb
       )
 WHERE pg_temp.attempt_fencing_available();

SELECT is(
  (SELECT completed_at
     FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM fencing_attempt WHERE attempt = 1)),
  (SELECT completed_at FROM failed_run_history),
  'failing an already-failed attempt preserves its original completion time'
) WHERE pg_temp.attempt_fencing_available();

SELECT is(
  (SELECT error
     FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM fencing_attempt WHERE attempt = 1)),
  (SELECT error FROM failed_run_history),
  'failing an already-failed attempt preserves its original error detail'
) WHERE pg_temp.attempt_fencing_available();

SELECT geo_genius.upsert_area('attempt_fencing', 'fence_auth', 'outer', 'parent')
 WHERE pg_temp.attempt_fencing_available();
SELECT geo_genius.upsert_area('attempt_fencing', 'fence_auth', 'inner', 'child')
 WHERE pg_temp.attempt_fencing_available();
SELECT geo_genius.upsert_area('attempt_fencing', 'fence_auth', 'inner', 'stale')
 WHERE pg_temp.attempt_fencing_available();

-- The current attempt owns the candidate while it is leased and in one of
-- the exact phases named by its caller.
SELECT results_eq(
  format(
    'SELECT geo_genius.assert_import_write(%L::uuid, %L::uuid, ARRAY[''pending''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  format(
    'VALUES (%L::uuid)',
    (SELECT release_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current leased attempt is authorized in a permitted phase'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.assert_import_write(%L::uuid, %L::uuid, ARRAY[''staging''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '55000',
  NULL,
  'the current leased attempt is refused in the wrong phase'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.record_artifact_observation(%L::uuid, %L::uuid, '
      || '(SELECT artifact.id FROM geo_genius.artifact '
      || 'WHERE artifact.logical_name = ''A''), repeat(''a'',64), 10)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '55000',
  NULL,
  'artifact observation is refused before the downloading phase'
) WHERE pg_temp.attempt_fencing_available();

DELETE FROM geo_genius.import_run_lease
 WHERE run_id = (SELECT run_id FROM fencing_attempt WHERE attempt = 2)
   AND pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.assert_import_write(%L::uuid, %L::uuid, ARRAY[''pending''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '55000',
  NULL,
  'a current attempt without its lease is refused'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.advance_import(%L::uuid, %L::uuid, ''downloading'', ''{}''::jsonb)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '55000',
  NULL,
  'an attempt without its lease cannot advance phases'
) WHERE pg_temp.attempt_fencing_available();

UPDATE geo_genius.import_run
   SET status = 'downloading'
 WHERE id = (SELECT run_id FROM fencing_attempt WHERE attempt = 2)
   AND pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.record_artifact_observation(%L::uuid, %L::uuid, '
      || '(SELECT artifact.id FROM geo_genius.artifact '
      || 'WHERE artifact.logical_name = ''A''), repeat(''a'',64), 10)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '55000',
  NULL,
  'an attempt without its lease cannot record an artifact observation'
) WHERE pg_temp.attempt_fencing_available();

UPDATE geo_genius.import_run
   SET status = 'pending'
 WHERE id = (SELECT run_id FROM fencing_attempt WHERE attempt = 2)
   AND pg_temp.attempt_fencing_available();

INSERT INTO geo_genius.import_run_lease(
  run_id,
  release_id,
  executor_id,
  execution_started_at
)
SELECT run_id, release_id, executor_id, clock_timestamp()
  FROM fencing_attempt WHERE attempt = 2
  AND pg_temp.attempt_fencing_available();

-- Supersession is independent of terminal status. Even if corrupt external
-- SQL makes the old row look active and gives it the lease, the greater
-- attempt number remains authoritative.
DELETE FROM geo_genius.import_run_lease
 WHERE run_id = (SELECT run_id FROM fencing_attempt WHERE attempt = 2)
   AND pg_temp.attempt_fencing_available();
INSERT INTO geo_genius.import_run_lease(
  run_id,
  release_id,
  executor_id,
  execution_started_at
)
SELECT run_id, release_id, executor_id, clock_timestamp()
  FROM fencing_attempt WHERE attempt = 1
  AND pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.assert_import_write(%L::uuid, %L::uuid, ARRAY[''failed''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000',
  NULL,
  'an older leased attempt is refused after a newer attempt exists'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.advance_import(%L::uuid, %L::uuid, ''relating'', ''{}''::jsonb)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000',
  NULL,
  'an older leased attempt cannot advance after it is superseded'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.record_artifact_observation(%L::uuid, %L::uuid, '
      || '(SELECT artifact.id FROM geo_genius.artifact '
      || 'WHERE artifact.logical_name = ''A''), repeat(''a'',64), 10)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000',
  NULL,
  'an older leased failed attempt cannot record after it is superseded'
) WHERE pg_temp.attempt_fencing_available();

SELECT is(
  (SELECT observed_sha256
     FROM geo_genius.import_run_artifact
    WHERE run_id = (SELECT run_id FROM fencing_attempt WHERE attempt = 1)
      AND artifact_id = (SELECT id FROM geo_genius.artifact WHERE logical_name = 'A')),
  NULL::text,
  'a refused superseded observation leaves the old attempt history unchanged'
) WHERE pg_temp.attempt_fencing_available();

DELETE FROM geo_genius.import_run_lease
 WHERE run_id = (SELECT run_id FROM fencing_attempt WHERE attempt = 1)
   AND pg_temp.attempt_fencing_available();
INSERT INTO geo_genius.import_run_lease(
  run_id,
  release_id,
  executor_id,
  execution_started_at
)
SELECT run_id, release_id, executor_id, clock_timestamp()
  FROM fencing_attempt WHERE attempt = 2
  AND pg_temp.attempt_fencing_available();

INSERT INTO fencing_snapshot(phase, state)
SELECT 'before-stale-writes', pg_temp.candidate_snapshot(release_id)
  FROM fencing_attempt
 WHERE attempt = 2
   AND pg_temp.attempt_fencing_available();

-- Every mutation below names attempt 1 after exact reset created attempt 2.
-- Each statement must acquire the fence itself and fail before touching the
-- recreated candidate partitions or the old staging-table namespace.
SELECT throws_ok(
  format('SELECT geo_genius.create_staging(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)),
  '55000', NULL,
  'a failed superseded attempt cannot recreate its staging table'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.insert_staging_many(%L::uuid, %L::uuid, ARRAY[''stale''], '
      || 'ARRAY[''{"stale":true}''::jsonb], ARRAY[NULL::geometry])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot batch-insert staged rows'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.upsert_area_many(%L::uuid, %L::uuid, ARRAY[''fence_auth''], '
      || 'ARRAY[''inner''], ARRAY[''stale-global''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot create global area identities'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.upsert_area_many(%L::uuid, %L::uuid, ARRAY[''fence_auth''], '
      || 'ARRAY[''inner''], ARRAY[''release-bypass''])',
    (SELECT release_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '23503', NULL,
  'a release id cannot bypass attempt fencing for global area identities'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_in_release(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:stale'', ST_GeogFromText(''POINT(9 9)''), '
      || '''{"stale":true}''::jsonb)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot add singular candidate membership'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_in_release(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:stale'', ST_GeogFromText(''POINT(9 9)''), '
      || '''{"release_bypass":true}''::jsonb)',
    (SELECT release_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '23503', NULL,
  'a release id cannot bypass attempt fencing for singular membership'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_name(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:stale'', ''Stale Singular Name'', ''official'', NULL)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot attach a singular candidate name'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_name(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:stale'', ''Release Bypass Name'', ''official'', NULL)',
    (SELECT release_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '23503', NULL,
  'a release id cannot bypass attempt fencing for a singular name'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_code(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:stale'', ''fixture'', ''STALE-SINGULAR'')',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot attach a singular candidate code'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_code(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:stale'', ''fixture'', ''RELEASE-BYPASS'')',
    (SELECT release_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '23503', NULL,
  'a release id cannot bypass attempt fencing for a singular code'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_boundary(%L::uuid, %L::uuid, ''fence_auth:inner:stale'', '
      || '(SELECT source_release.id FROM geo_genius.source_release '
      || 'JOIN geo_genius.source ON source.id = source_release.source_id '
      || 'WHERE source.source_key = ''attempt_fencing:source''), '
      || 'ST_GeomFromText(''POLYGON((8 8,10 8,10 10,8 10,8 8))'',4326), 0.0)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot add a singular candidate boundary'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_boundary(%L::uuid, %L::uuid, ''fence_auth:inner:stale'', '
      || '(SELECT source_release.id FROM geo_genius.source_release '
      || 'JOIN geo_genius.source ON source.id = source_release.source_id '
      || 'WHERE source.source_key = ''attempt_fencing:source''), '
      || 'ST_GeomFromText(''POLYGON((8 8,10 8,10 10,8 10,8 8))'',4326), 0.0)',
    (SELECT release_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '23503', NULL,
  'a release id cannot bypass attempt fencing for a singular boundary'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_relation(%L::uuid, %L::uuid, ''fence_auth:outer:parent'', '
      || '''fence_auth:inner:stale'', ''contains'')',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot add a singular asserted relation'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_relation(%L::uuid, %L::uuid, ''fence_auth:outer:parent'', '
      || '''fence_auth:inner:stale'', ''contains'')',
    (SELECT release_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  '23503', NULL,
  'a release id cannot bypass attempt fencing for a singular asserted relation'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_in_release_many(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:inner:stale''], '
      || 'ARRAY[ST_GeogFromText(''POINT(9 9)'')], '
      || 'ARRAY[''{"stale":true}''::jsonb])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot add candidate membership'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_name_many(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:inner:stale''], ARRAY[''Stale Name''], '
      || 'ARRAY[''official''], ARRAY[NULL::text])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot attach candidate names'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_area_code_many(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:inner:stale''], ARRAY[''fixture''], ARRAY[''STALE''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot attach candidate codes'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_boundaries(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:inner:stale''], '
      || 'ARRAY[(SELECT source_release.id FROM geo_genius.source_release '
      || 'JOIN geo_genius.source ON source.id = source_release.source_id '
      || 'WHERE source.source_key = ''attempt_fencing:source'')], '
      || 'ARRAY[ST_GeomFromText(''POLYGON((8 8,10 8,10 10,8 10,8 8))'',4326)], '
      || 'ARRAY[0], ARRAY[''{}''::jsonb])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot add candidate boundaries'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format(
    'SELECT geo_genius.put_relation_many(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:outer:parent''], ARRAY[''fence_auth:inner:stale''], '
      || 'ARRAY[''contains''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)
  ),
  '55000', NULL,
  'a failed superseded attempt cannot add asserted relations'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format('SELECT geo_genius.rebuild_relations(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)),
  '55000', NULL,
  'a failed superseded attempt cannot rebuild measured relations'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format('SELECT geo_genius.analyze_import(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)),
  '55000', NULL,
  'a failed superseded attempt cannot analyze replacement partitions'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format('SELECT geo_genius.verify_import(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)),
  '55000', NULL,
  'a failed superseded attempt cannot verify the replacement candidate'
) WHERE pg_temp.attempt_fencing_available();

SELECT throws_ok(
  format('SELECT geo_genius.publish_import(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 1),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 1)),
  '55000', NULL,
  'a failed superseded attempt cannot publish the replacement candidate'
) WHERE pg_temp.attempt_fencing_available();

INSERT INTO fencing_snapshot(phase, state)
SELECT 'after-stale-writes', pg_temp.candidate_snapshot(release_id)
  FROM fencing_attempt
 WHERE attempt = 2
   AND pg_temp.attempt_fencing_available();

SELECT is(
  (SELECT state FROM fencing_snapshot WHERE phase = 'after-stale-writes'),
  (SELECT state FROM fencing_snapshot WHERE phase = 'before-stale-writes'),
  'all refused stale writes leave the replacement candidate and staging namespace unchanged'
) WHERE pg_temp.attempt_fencing_available();

-- The same entry points must work for the current leased attempt in their
-- exact phases; otherwise a blanket terminal-run rejection could satisfy all
-- stale counterfactuals while making imports unusable.
SELECT lives_ok(
  format(
    'SELECT geo_genius.advance_import(%L::uuid, %L::uuid, ''downloading'', ''{}''::jsonb)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current leased latest attempt can advance phases'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.record_artifact_observation(%L::uuid, %L::uuid, '
      || '(SELECT artifact.id FROM geo_genius.artifact '
      || 'WHERE artifact.logical_name = ''A''), repeat(''a'',64), 10)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current leased downloading attempt can record its artifact observation'
) WHERE pg_temp.attempt_fencing_available();

INSERT INTO observation_stamp(validated_at)
SELECT validated_at
  FROM geo_genius.import_run_artifact
 WHERE run_id = (SELECT run_id FROM fencing_attempt WHERE attempt = 2)
   AND artifact_id = (SELECT id FROM geo_genius.artifact WHERE logical_name = 'A')
   AND pg_temp.attempt_fencing_available();

SELECT geo_genius.advance_import(
  (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
  (SELECT executor_id FROM fencing_attempt WHERE attempt = 2),
  'validating',
  '{}'::jsonb
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.record_artifact_observation(%L::uuid, %L::uuid, '
      || '(SELECT artifact.id FROM geo_genius.artifact '
      || 'WHERE artifact.logical_name = ''A''), repeat(''A'',64), 10)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'an identical observation remains idempotent during validation'
) WHERE pg_temp.attempt_fencing_available();

SELECT is(
  (SELECT validated_at
     FROM geo_genius.import_run_artifact
    WHERE run_id = (SELECT run_id FROM fencing_attempt WHERE attempt = 2)
      AND artifact_id = (SELECT id FROM geo_genius.artifact WHERE logical_name = 'A')),
  (SELECT validated_at FROM observation_stamp),
  'an identical validating observation preserves its original timestamp'
) WHERE pg_temp.attempt_fencing_available();

SELECT geo_genius.advance_import(
  (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
  (SELECT executor_id FROM fencing_attempt WHERE attempt = 2),
  'staging',
  '{}'::jsonb
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format('SELECT geo_genius.create_staging(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)),
  'the current leased staging attempt can create its staging table'
) WHERE pg_temp.attempt_fencing_available();

SELECT results_eq(
  format(
    'SELECT geo_genius.insert_staging_many(%L::uuid, %L::uuid, ARRAY[''A''], '
      || 'ARRAY[''{"current":true}''::jsonb], ARRAY[NULL::geometry])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'VALUES (1::bigint)',
  'the current leased staging attempt can batch-insert rows'
) WHERE pg_temp.attempt_fencing_available();

SELECT geo_genius.advance_import(
  (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
  (SELECT executor_id FROM fencing_attempt WHERE attempt = 2),
  'normalizing',
  '{}'::jsonb
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.upsert_area_many(%L::uuid, %L::uuid, ARRAY[''fence_auth''], '
      || 'ARRAY[''inner''], ARRAY[''singular''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can create global area identities'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_area_in_release_many(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:outer:parent'',''fence_auth:inner:child''], '
      || 'ARRAY[ST_GeogFromText(''POINT(0 0)''),ST_GeogFromText(''POINT(1 1)'')], '
      || 'ARRAY[''{}''::jsonb,''{}''::jsonb])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can write membership'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_area_in_release(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:singular'', ST_GeogFromText(''POINT(1.5 1.5)''), '
      || '''{"singular":true}''::jsonb)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can write singular membership'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_area_name_many(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:outer:parent'',''fence_auth:inner:child''], '
      || 'ARRAY[''Parent'',''Child''], ARRAY[''official'',''official''], '
      || 'ARRAY[NULL::text,NULL::text])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can attach names'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_area_name(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:singular'', ''Singular'', ''official'', NULL)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can attach a singular name'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_area_code_many(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:inner:child''], ARRAY[''fixture''], ARRAY[''CHILD''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can attach codes'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_area_code(%L::uuid, %L::uuid, '
      || '''fence_auth:inner:singular'', ''fixture'', ''SINGULAR'')',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can attach a singular code'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_boundaries(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:inner:child''], '
      || 'ARRAY[(SELECT source_release.id FROM geo_genius.source_release '
      || 'JOIN geo_genius.source ON source.id = source_release.source_id '
      || 'WHERE source.source_key = ''attempt_fencing:source'')], '
      || 'ARRAY[ST_GeomFromText(''POLYGON((0 0,2 0,2 2,0 2,0 0))'',4326)], '
      || 'ARRAY[0], ARRAY[''{}''::jsonb])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can write boundaries'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_boundary(%L::uuid, %L::uuid, ''fence_auth:inner:singular'', '
      || '(SELECT source_release.id FROM geo_genius.source_release '
      || 'JOIN geo_genius.source ON source.id = source_release.source_id '
      || 'WHERE source.source_key = ''attempt_fencing:source''), '
      || 'ST_GeomFromText(''POLYGON((1 1,2 1,2 2,1 2,1 1))'',4326), 0.0)',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current normalizing attempt can write a singular boundary'
) WHERE pg_temp.attempt_fencing_available();

SELECT geo_genius.advance_import(
  (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
  (SELECT executor_id FROM fencing_attempt WHERE attempt = 2),
  'relating',
  '{}'::jsonb
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_relation_many(%L::uuid, %L::uuid, '
      || 'ARRAY[''fence_auth:outer:parent''], ARRAY[''fence_auth:inner:child''], '
      || 'ARRAY[''contains''])',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current relating attempt can add asserted relations'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format(
    'SELECT geo_genius.put_relation(%L::uuid, %L::uuid, ''fence_auth:outer:parent'', '
      || '''fence_auth:inner:singular'', ''contains'')',
    (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
    (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)
  ),
  'the current relating attempt can add a singular asserted relation'
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format('SELECT geo_genius.rebuild_relations(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)),
  'the current relating attempt can rebuild measured relations'
) WHERE pg_temp.attempt_fencing_available();

SELECT geo_genius.advance_import(
  (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
  (SELECT executor_id FROM fencing_attempt WHERE attempt = 2),
  'indexing',
  '{}'::jsonb
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format('SELECT geo_genius.analyze_import(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)),
  'the current indexing attempt can analyze its candidate partitions'
) WHERE pg_temp.attempt_fencing_available();

SELECT geo_genius.advance_import(
  (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
  (SELECT executor_id FROM fencing_attempt WHERE attempt = 2),
  'verifying',
  '{}'::jsonb
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format('SELECT geo_genius.verify_import(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)),
  'the current verifying attempt can verify its candidate'
) WHERE pg_temp.attempt_fencing_available();

SELECT geo_genius.advance_import(
  (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
  (SELECT executor_id FROM fencing_attempt WHERE attempt = 2),
  'publishing',
  '{}'::jsonb
) WHERE pg_temp.attempt_fencing_available();

SELECT lives_ok(
  format('SELECT geo_genius.publish_import(%L::uuid, %L::uuid)',
         (SELECT run_id FROM fencing_attempt WHERE attempt = 2),
         (SELECT executor_id FROM fencing_attempt WHERE attempt = 2)),
  'the current publishing attempt can publish its candidate'
) WHERE pg_temp.attempt_fencing_available();

SELECT * FROM finish();

ROLLBACK;
