BEGIN;

CREATE FUNCTION pg_temp.retry_manifest(
  collection_key text,
  release_key text,
  artifact_names text[] DEFAULT ARRAY['A']::text[]
)
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT jsonb_build_object(
    'collection', collection_key,
    'collection_name', initcap(replace(collection_key, '-', ' ')),
    'description', 'exact retry fixture',
    'release', release_key,
    'provider', 'fixture',
    'requires_geometry', false,
    'authorities', jsonb_build_array(
      jsonb_build_object('key', 'fixture_auth', 'name', 'Fixture Authority')
    ),
    'area_types', jsonb_build_array(
      jsonb_build_object('key', 'outer', 'rank', 10, 'requires_geometry', false),
      jsonb_build_object('key', 'inner', 'rank', 20, 'requires_geometry', false)
    ),
    'sources', jsonb_build_array(
      jsonb_build_object(
        'source_key', collection_key || ':source',
        'provider', 'fixture',
        'license', 'test',
        'release_key', 'v1',
        'artifacts', (
          SELECT coalesce(
            jsonb_agg(
              jsonb_build_object(
                'logical_name', artifact_name,
                'url', 'https://example.test/' || collection_key || '/' || lower(artifact_name),
                'operator_supplied', false,
                'format', 'json',
                'required', true,
                'sha256', repeat(
                  CASE artifact_name
                    WHEN 'A' THEN 'a'
                    WHEN 'B' THEN 'b'
                    ELSE 'c'
                  END,
                  64
                ),
                'bytes', ord * 10,
                'members', jsonb_build_array(),
                'metadata', jsonb_build_object()
              )
              ORDER BY ord
            ),
            '[]'::jsonb
          )
          FROM unnest(artifact_names) WITH ORDINALITY AS selected(artifact_name, ord)
        )
      )
    ),
    'options', jsonb_build_object()
  );
$fn$;

CREATE FUNCTION pg_temp.corrected_retry_manifest(collection_key text, release_key text)
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT jsonb_set(
    jsonb_set(
      jsonb_set(
        pg_temp.retry_manifest(collection_key, release_key, ARRAY['A']),
        '{collection_name}',
        to_jsonb('Corrected Collection'::text)
      ),
      '{authorities,0,name}',
      to_jsonb('Corrected Authority'::text)
    ),
    '{area_types,1,rank}',
    '30'::jsonb
  );
$fn$;

CREATE FUNCTION pg_temp.retry_claim(claim_owner text)
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT jsonb_build_object(
    'owner', claim_owner,
    'runner_backend', 'test',
    'stale_after_seconds', 900
  );
$fn$;

CREATE FUNCTION pg_temp.retry_catalog_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  relation_name text;
  relation_snapshot jsonb;
  result jsonb := '{}'::jsonb;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'collection',
    'release_collection_policy',
    'authority',
    'release_authority',
    'area_type',
    'release_area_type',
    'source',
    'source_release',
    'artifact',
    'release',
    'release_source',
    'release_artifact',
    'area',
    'release_area',
    'area_name',
    'release_area_name',
    'area_code',
    'release_area_code',
    'boundary',
    'boundary_part',
    'relation',
    'import_run',
    'import_run_artifact',
    'import_run_lease',
    'publication',
    'publication_event'
  ]
  LOOP
    EXECUTE format(
      'SELECT jsonb_build_object(
         ''count'', count(*),
         ''digest'', md5(coalesce(string_agg(row_json, E''\n'' ORDER BY row_json), ''''))
       )
       FROM (SELECT to_jsonb(candidate)::text AS row_json FROM geo_genius.%I candidate) rows',
      relation_name
    ) INTO relation_snapshot;

    result := result || jsonb_build_object(relation_name, relation_snapshot);
  END LOOP;

  SELECT result || jsonb_build_object(
    'partitions', jsonb_build_object(
      'count', count(*) FILTER (WHERE parent.relname IS NOT NULL),
      'digest', md5(coalesce(
        string_agg(
          child.oid::text || ':' || child.relname,
          E'\n' ORDER BY child.oid, child.relname
        ) FILTER (WHERE parent.relname IS NOT NULL),
        ''
      ))
    ),
    'staging_tables', jsonb_build_object(
      'count', count(*) FILTER (WHERE child.relname LIKE 'staging\_%' ESCAPE '\'),
      'digest', md5(coalesce(
        string_agg(
          child.oid::text || ':' || child.relname,
          E'\n' ORDER BY child.oid, child.relname
        ) FILTER (WHERE child.relname LIKE 'staging\_%' ESCAPE '\'),
        ''
      ))
    )
  )
    INTO result
    FROM pg_class child
    JOIN pg_namespace child_namespace ON child_namespace.oid = child.relnamespace
    LEFT JOIN pg_inherits inheritance ON inheritance.inhrelid = child.oid
    LEFT JOIN pg_class parent
      ON parent.oid = inheritance.inhparent
     AND parent.relname IN ('boundary', 'boundary_part', 'relation', 'release_area')
   WHERE child_namespace.nspname = 'geo_genius'
     AND (
       parent.relname IS NOT NULL
       OR child.relname LIKE 'staging\_%' ESCAPE '\'
     );

  RETURN result;
END;
$fn$;

CREATE FUNCTION pg_temp.exact_retry_available()
RETURNS boolean
LANGUAGE sql
AS $fn$
  SELECT to_regprocedure('geo_genius.prepare_import(jsonb,jsonb)') IS NOT NULL
     AND to_regprocedure('geo_genius.retry_failed(uuid,jsonb,jsonb)') IS NOT NULL;
$fn$;

DO $fn$
BEGIN
  IF pg_temp.exact_retry_available() THEN
    EXECUTE $sql$
      CREATE FUNCTION pg_temp.call_prepare(manifest jsonb, claim jsonb)
      RETURNS TABLE(
        decision text,
        reason text,
        release_id uuid,
        run_id uuid,
        attempt integer
      )
      LANGUAGE sql
      AS $body$
        SELECT * FROM geo_genius.prepare_import(manifest, claim)
      $body$
    $sql$;

    EXECUTE $sql$
      CREATE FUNCTION pg_temp.call_retry(failed_run_id uuid, manifest jsonb, claim jsonb)
      RETURNS TABLE(
        decision text,
        reason text,
        release_id uuid,
        run_id uuid,
        attempt integer
      )
      LANGUAGE sql
      AS $body$
        SELECT * FROM geo_genius.retry_failed(failed_run_id, manifest, claim)
      $body$
    $sql$;
  ELSE
    EXECUTE $sql$
      CREATE FUNCTION pg_temp.call_prepare(manifest jsonb, claim jsonb)
      RETURNS TABLE(
        decision text,
        reason text,
        release_id uuid,
        run_id uuid,
        attempt integer
      )
      LANGUAGE sql
      AS $body$
        SELECT NULL::text, NULL::text, NULL::uuid, NULL::uuid, NULL::integer
        WHERE false
      $body$
    $sql$;

    EXECUTE $sql$
      CREATE FUNCTION pg_temp.call_retry(failed_run_id uuid, manifest jsonb, claim jsonb)
      RETURNS TABLE(
        decision text,
        reason text,
        release_id uuid,
        run_id uuid,
        attempt integer
      )
      LANGUAGE sql
      AS $body$
        SELECT NULL::text, NULL::text, NULL::uuid, NULL::uuid, NULL::integer
        WHERE false
      $body$
    $sql$;
  END IF;
END;
$fn$;

CREATE TEMP TABLE exact_retry_result (
  case_key text PRIMARY KEY,
  decision text,
  reason text,
  release_id uuid,
  run_id uuid,
  attempt integer
);

CREATE TEMP TABLE exact_retry_snapshot (
  case_key text,
  phase text,
  state jsonb,
  PRIMARY KEY (case_key, phase)
);

CREATE TEMP TABLE exact_retry_executor (
  case_key text PRIMARY KEY,
  executor_id uuid NOT NULL
);

SELECT plan(59);

SELECT has_function(
  'geo_genius',
  'retry_failed',
  ARRAY['uuid', 'jsonb', 'jsonb'],
  'retry_failed exposes the explicit failed-attempt reset boundary'
);

SELECT * FROM skip(
  'prepare_import and retry_failed are not both installed',
  58
) WHERE NOT pg_temp.exact_retry_available();

-- Attempt 1 selects A+B and accumulates every class of candidate data that
-- exact reset must remove without touching its durable attempt evidence.
INSERT INTO exact_retry_result
SELECT 'attempt-1', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.retry_manifest('retry_exact', 'r1', ARRAY['A', 'B']),
    pg_temp.retry_claim('worker-1')
 ) prepared
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_executor
SELECT 'attempt-1', geo_genius_test.claim_import_executor(run_id)
  FROM exact_retry_result
 WHERE case_key = 'attempt-1'
   AND pg_temp.exact_retry_available();

SELECT geo_genius.upsert_area('retry_exact', 'fixture_auth', 'outer', 'parent')
 WHERE pg_temp.exact_retry_available();
SELECT geo_genius.upsert_area('retry_exact', 'fixture_auth', 'inner', 'A')
 WHERE pg_temp.exact_retry_available();
SELECT geo_genius.upsert_area('retry_exact', 'fixture_auth', 'inner', 'B')
 WHERE pg_temp.exact_retry_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'downloading'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.record_artifact_observation(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  (SELECT artifact.id
     FROM geo_genius.artifact
     JOIN geo_genius.source_release ON source_release.id = artifact.source_release_id
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'retry_exact:source' AND artifact.logical_name = 'A'),
  repeat('a', 64), 10
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.record_artifact_observation(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  (SELECT artifact.id
     FROM geo_genius.artifact
     JOIN geo_genius.source_release ON source_release.id = artifact.source_release_id
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'retry_exact:source' AND artifact.logical_name = 'B'),
  repeat('b', 64), 20
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'validating'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.advance_import(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'staging',
  '{"fixture_rows":2}'::jsonb
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.create_staging(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1')
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'normalizing'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.put_boundary(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'fixture_auth:outer:parent',
  (SELECT source_release.id
     FROM geo_genius.source_release
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'retry_exact:source'),
  ST_GeomFromText('POLYGON((0 0, 4 0, 4 4, 0 4, 0 0))', 4326),
  0.0
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.put_boundary(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'fixture_auth:inner:A',
  (SELECT source_release.id
     FROM geo_genius.source_release
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'retry_exact:source'),
  ST_GeomFromText('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))', 4326),
  0.0
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.put_boundary(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'fixture_auth:inner:B',
  (SELECT source_release.id
     FROM geo_genius.source_release
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'retry_exact:source'),
  ST_GeomFromText('POLYGON((2 2, 3 2, 3 3, 2 3, 2 2))', 4326),
  0.0
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.put_area_name(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'fixture_auth:inner:A', 'Area A', 'official', NULL
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.put_area_name(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'fixture_auth:inner:B', 'Area B', 'official', NULL
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.put_area_code(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'fixture_auth:inner:A', 'fixture', 'A'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.put_area_code(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'fixture_auth:inner:B', 'fixture', 'B'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'relating'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.rebuild_relations(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1')
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.put_relation(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  'fixture_auth:inner:A', 'fixture_auth:inner:B', 'contains'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.relation
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-1')
      AND intersection_area_m2 IS NOT NULL),
  2,
  'attempt 1 contains measured relations before reset'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.relation
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-1')
      AND intersection_area_m2 IS NULL),
  1,
  'attempt 1 contains an asserted relation before reset'
) WHERE pg_temp.exact_retry_available();

-- Exact reset may prune only identities that participated in this failed
-- candidate. Preserve an unrelated, unattached area in the same collection,
-- plus dictionary rows and an inbound successor reference from another
-- collection, so a schema-wide or collection-wide sweep is observable.
SELECT geo_genius.upsert_area('retry_exact', 'fixture_auth', 'outer', 'unrelated')
 WHERE pg_temp.exact_retry_available();

INSERT INTO geo_genius.area_name (area_id, name, kind, locale)
SELECT id, 'Unrelated Area', 'official', NULL
  FROM geo_genius.area
 WHERE area_key = 'fixture_auth:outer:unrelated'
   AND pg_temp.exact_retry_available();

INSERT INTO geo_genius.area_code (area_id, code_type, code_value)
SELECT id, 'fixture', 'unrelated'
  FROM geo_genius.area
 WHERE area_key = 'fixture_auth:outer:unrelated'
   AND pg_temp.exact_retry_available();

SELECT geo_genius.upsert_collection('retry_observer', 'Retry Observer', NULL, false)
 WHERE pg_temp.exact_retry_available();
SELECT geo_genius.upsert_authority('retry_observer', 'observer_auth', 'Observer Authority')
 WHERE pg_temp.exact_retry_available();
SELECT geo_genius.upsert_area_type('retry_observer', 'observer', 10, false)
 WHERE pg_temp.exact_retry_available();
SELECT geo_genius.upsert_area('retry_observer', 'observer_auth', 'observer', 'keeper')
 WHERE pg_temp.exact_retry_available();

UPDATE geo_genius.area AS observer
   SET successor_id = unrelated.id
  FROM geo_genius.area AS unrelated
 WHERE observer.area_key = 'observer_auth:observer:keeper'
   AND unrelated.area_key = 'fixture_auth:outer:unrelated'
   AND pg_temp.exact_retry_available();

INSERT INTO geo_genius.area_name (area_id, name, kind, locale)
SELECT id, 'Observer Area', 'official', NULL
  FROM geo_genius.area
 WHERE area_key = 'observer_auth:observer:keeper'
   AND pg_temp.exact_retry_available();

INSERT INTO geo_genius.area_code (area_id, code_type, code_value)
SELECT id, 'fixture', 'observer'
  FROM geo_genius.area
 WHERE area_key = 'observer_auth:observer:keeper'
   AND pg_temp.exact_retry_available();

DO $fn$
DECLARE
  table_name text;
BEGIN
  IF pg_temp.exact_retry_available() THEN
    table_name := geo_genius.staging_table_name(
      (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1')
    );
    EXECUTE format(
      'INSERT INTO geo_genius.%I (artifact, payload) VALUES ($1, $2)',
      table_name
    ) USING 'B', '{"fixture":"B"}'::jsonb;
  END IF;
END;
$fn$;

SELECT geo_genius.fail_import(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-1'),
  '{"reason":"fixture failure","detail":"preserve me"}'::jsonb
) WHERE pg_temp.exact_retry_available();

-- Corrected manifests must still identify the same failed candidate.
INSERT INTO exact_retry_snapshot
SELECT 'key-mismatch', 'before', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_result
SELECT 'collection-mismatch', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
    pg_temp.corrected_retry_manifest('retry_other', 'r1'),
    pg_temp.retry_claim('worker-2')
  ) retried
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_result
SELECT 'release-mismatch', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
    pg_temp.corrected_retry_manifest('retry_exact', 'r2'),
    pg_temp.retry_claim('worker-2')
  ) retried
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'key-mismatch', 'after', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'collection-mismatch'),
  'error',
  'retry refuses a manifest naming another collection'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'collection-mismatch'),
  'candidate_mismatch',
  'a collection mismatch has a structured reason'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'release-mismatch'),
  'error',
  'retry refuses a manifest naming another release'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'release-mismatch'),
  'candidate_mismatch',
  'a release mismatch has a structured reason'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'key-mismatch' AND phase = 'after'),
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'key-mismatch' AND phase = 'before'),
  'key-mismatch refusals perform zero writes'
) WHERE pg_temp.exact_retry_available();

-- A database failure after reset has started restores every table, partition,
-- staging table, manifest, run, and observation through statement rollback.
CREATE FUNCTION pg_temp.force_exact_reset_failure()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  RAISE EXCEPTION 'forced exact reset failure' USING ERRCODE = '23514';
END;
$fn$;

CREATE TRIGGER force_exact_reset_failure
BEFORE INSERT ON geo_genius.release_artifact
FOR EACH ROW
EXECUTE FUNCTION pg_temp.force_exact_reset_failure();

INSERT INTO exact_retry_snapshot
SELECT 'rollback', 'before', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT throws_ok(
  $$SELECT * FROM geo_genius.retry_failed(
      (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
      pg_temp.corrected_retry_manifest('retry_exact', 'r1'),
      pg_temp.retry_claim('worker-2')
    )$$,
  '23514',
  'forced exact reset failure',
  'a database fault during exact reset escapes as an exception'
) WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'rollback', 'after', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'rollback' AND phase = 'after'),
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'rollback' AND phase = 'before'),
  'a failed exact-reset statement restores the entire candidate catalog state'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.import_run
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-1')),
  1,
  'a rolled-back reset creates no replacement attempt'
) WHERE pg_temp.exact_retry_available();

DROP TRIGGER force_exact_reset_failure ON geo_genius.release_artifact;
DROP FUNCTION pg_temp.force_exact_reset_failure();

-- The explicit corrected retry atomically replaces candidate registration and
-- then claims the next attempt without erasing attempt 1 evidence.
INSERT INTO exact_retry_result
SELECT 'attempt-2', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
    pg_temp.corrected_retry_manifest('retry_exact', 'r1'),
    pg_temp.retry_claim('worker-2')
  ) retried
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_executor
SELECT 'attempt-2', geo_genius_test.claim_import_executor(run_id)
  FROM exact_retry_result
 WHERE case_key = 'attempt-2'
   AND pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'attempt-2'),
  'enqueue',
  'an explicit corrected retry is enqueued'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'attempt-2'),
  'retried',
  'an explicit corrected retry reports its exact-reset decision'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT attempt FROM exact_retry_result WHERE case_key = 'attempt-2'),
  2,
  'an explicit corrected retry creates attempt 2'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2'),
  (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
  'exact retry resets the same candidate release'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT manifest FROM geo_genius.release
    WHERE id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  pg_temp.corrected_retry_manifest('retry_exact', 'r1'),
  'the candidate release stores the corrected A-only manifest'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT manifest FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1')),
  pg_temp.retry_manifest('retry_exact', 'r1', ARRAY['A', 'B']),
  'attempt 1 retains its exact A+B manifest'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1')),
  'failed',
  'attempt 1 remains failed after exact retry'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT error FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1')),
  '{"reason":"fixture failure","detail":"preserve me"}'::jsonb,
  'attempt 1 retains its exact failure evidence'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT stage_metrics FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1')),
  '{"fixture_rows":2}'::jsonb,
  'attempt 1 retains its exact stage metrics'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT array_agg(artifact.logical_name ORDER BY artifact.logical_name)
     FROM geo_genius.import_run_artifact observation
     JOIN geo_genius.artifact ON artifact.id = observation.artifact_id
    WHERE observation.run_id =
      (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1')),
  ARRAY['A', 'B']::text[],
  'attempt 1 retains its exact A+B artifact selection'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT observation.observed_sha256
     FROM geo_genius.import_run_artifact observation
     JOIN geo_genius.artifact ON artifact.id = observation.artifact_id
    WHERE observation.run_id =
      (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1')
      AND artifact.logical_name = 'B'),
  repeat('b', 64),
  'attempt 1 retains its B observation'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT array_agg(artifact.logical_name ORDER BY artifact.logical_name)
     FROM geo_genius.import_run_artifact observation
     JOIN geo_genius.artifact ON artifact.id = observation.artifact_id
    WHERE observation.run_id =
      (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  ARRAY['A']::text[],
  'attempt 2 snapshots only corrected artifact A'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer
     FROM geo_genius.import_run_artifact
    WHERE run_id = (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-2')
      AND observed_sha256 IS NOT NULL),
  0,
  'attempt 2 begins with no inherited observations'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT array_agg(artifact.logical_name ORDER BY artifact.logical_name)
     FROM geo_genius.release_artifact selection
     JOIN geo_genius.artifact ON artifact.id = selection.artifact_id
    WHERE selection.release_id =
      (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  ARRAY['A']::text[],
  'the candidate release selects only corrected artifact A'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.release_source
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  1,
  'the candidate release has exactly the corrected source selection'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT release_authority.name
     FROM geo_genius.release_authority
     JOIN geo_genius.authority ON authority.id = release_authority.authority_id
    WHERE release_authority.release_id =
      (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')
      AND authority.key = 'fixture_auth'),
  'Corrected Authority',
  'the candidate release replaces its authority declaration exactly'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT release_area_type.rank
     FROM geo_genius.release_area_type
     JOIN geo_genius.area_type ON area_type.id = release_area_type.area_type_id
    WHERE release_area_type.release_id =
      (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')
      AND area_type.key = 'inner'),
  30,
  'the candidate release replaces its area-type declaration exactly'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.release_area
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  0,
  'exact reset leaves no stale candidate area memberships'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.release_area_name
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  0,
  'exact reset leaves no stale candidate name attachments'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.release_area_code
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  0,
  'exact reset leaves no stale candidate code attachments'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.boundary
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  0,
  'exact reset leaves no stale candidate boundaries'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.relation
    WHERE release_id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'attempt-2')),
  0,
  'exact reset leaves no measured or asserted candidate relations'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.area
    WHERE area_key = 'fixture_auth:outer:unrelated'),
  1,
  'exact reset preserves an unrelated unattached area in the candidate collection'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer
     FROM geo_genius.area_name
     JOIN geo_genius.area ON area.id = area_name.area_id
    WHERE area.area_key = 'fixture_auth:outer:unrelated'
      AND area_name.name = 'Unrelated Area'),
  1,
  'exact reset preserves an unrelated unattached name'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer
     FROM geo_genius.area_code
     JOIN geo_genius.area ON area.id = area_code.area_id
    WHERE area.area_key = 'fixture_auth:outer:unrelated'
      AND area_code.code_value = 'unrelated'),
  1,
  'exact reset preserves an unrelated unattached code'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT successor.area_key
     FROM geo_genius.area AS observer
     JOIN geo_genius.area AS successor ON successor.id = observer.successor_id
    WHERE observer.area_key = 'observer_auth:observer:keeper'),
  'fixture_auth:outer:unrelated',
  'exact reset preserves inbound successor identity outside the candidate'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer
     FROM geo_genius.area_name
     JOIN geo_genius.area ON area.id = area_name.area_id
    WHERE area.area_key = 'observer_auth:observer:keeper'
      AND area_name.name = 'Observer Area'),
  1,
  'exact reset does not prune another collection name dictionary'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT count(*)::integer
     FROM geo_genius.area_code
     JOIN geo_genius.area ON area.id = area_code.area_id
    WHERE area.area_key = 'observer_auth:observer:keeper'
      AND area_code.code_value = 'observer'),
  1,
  'exact reset does not prune another collection code dictionary'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  to_regclass(
    'geo_genius.' || geo_genius.staging_table_name(
      (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1')
    )
  ),
  NULL::regclass,
  'exact reset drops the terminal attempt staging table'
) WHERE pg_temp.exact_retry_available();

-- A live latest attempt is not a failed-attempt retry target.
INSERT INTO exact_retry_snapshot
SELECT 'not-failed', 'before', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_result
SELECT 'not-failed', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-2'),
    pg_temp.corrected_retry_manifest('retry_exact', 'r1'),
    pg_temp.retry_claim('worker-3')
  ) retried
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'not-failed', 'after', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'not-failed'),
  'error',
  'a latest attempt that is still live receives an error decision'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'not-failed'),
  'not_failed',
  'retry_failed refuses a latest attempt that is still live'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'not-failed' AND phase = 'after'),
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'not-failed' AND phase = 'before'),
  'a not-failed refusal performs zero writes'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.fail_import(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-2'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'attempt-2'),
  '{"reason":"second fixture failure"}'::jsonb
) WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'nonlatest', 'before', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_result
SELECT 'nonlatest', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'attempt-1'),
    pg_temp.corrected_retry_manifest('retry_exact', 'r1'),
    pg_temp.retry_claim('worker-3')
  ) retried
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'nonlatest', 'after', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'nonlatest'),
  'error',
  'an older failed attempt receives an error decision'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'nonlatest'),
  'not_latest_attempt',
  'retry_failed refuses an older failed attempt'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'nonlatest' AND phase = 'after'),
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'nonlatest' AND phase = 'before'),
  'a nonlatest-attempt refusal performs zero writes'
) WHERE pg_temp.exact_retry_available();

-- Valid completed attempts are protected retry refusals.
INSERT INTO exact_retry_result
SELECT 'completed-first', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.retry_manifest('retry_completed', 'r1'),
    pg_temp.retry_claim('worker-completed')
  ) prepared
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_executor
SELECT 'completed-first', geo_genius_test.claim_import_executor(run_id)
  FROM exact_retry_result
 WHERE case_key = 'completed-first'
   AND pg_temp.exact_retry_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'completed-first'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'completed-first'),
  'downloading'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.record_artifact_observation(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'completed-first'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'completed-first'),
  (SELECT artifact.id
     FROM geo_genius.artifact
     JOIN geo_genius.source_release ON source_release.id = artifact.source_release_id
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'retry_completed:source'
      AND artifact.logical_name = 'A'),
  repeat('a', 64),
  10
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.upsert_area(
  'retry_completed', 'fixture_auth', 'outer', 'completed-only'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'completed-first'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'completed-first'),
  'normalizing'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.put_area_in_release(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'completed-first'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'completed-first'),
  'fixture_auth:outer:completed-only',
  NULL,
  '{}'::jsonb
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'completed-first'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'completed-first'),
  'verifying'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.complete_import(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'completed-first'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'completed-first'),
  '{}'::jsonb
) WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'completed', 'before', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_result
SELECT 'completed', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'completed-first'),
    pg_temp.retry_manifest('retry_completed', 'r1'),
    pg_temp.retry_claim('worker-completed-2')
  ) retried
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'completed', 'after', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'completed'),
  'error',
  'a completed unpublished attempt receives an error decision'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'completed'),
  'protected',
  'retry_failed identifies a valid completed attempt as protected'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'completed' AND phase = 'after'),
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'completed' AND phase = 'before'),
  'a completed-attempt refusal performs zero writes'
) WHERE pg_temp.exact_retry_available();

-- Current, prior-published/rollback-associated, and retired releases remain
-- protected after their owning attempts complete atomically with publication.
INSERT INTO exact_retry_result
SELECT 'published-r1', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.retry_manifest('retry_protected', 'r1'),
    pg_temp.retry_claim('worker-published-1')
  ) prepared
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_executor
SELECT 'published-r1', geo_genius_test.claim_import_executor(run_id)
  FROM exact_retry_result
 WHERE case_key = 'published-r1'
   AND pg_temp.exact_retry_available();

SELECT geo_genius.upsert_area('retry_protected', 'fixture_auth', 'outer', 'only')
 WHERE pg_temp.exact_retry_available();
SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r1'),
  'downloading'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.record_artifact_observation(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r1'),
  (SELECT artifact.id
     FROM geo_genius.artifact
     JOIN geo_genius.source_release ON source_release.id = artifact.source_release_id
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'retry_protected:source'
      AND artifact.logical_name = 'A'),
  repeat('a', 64),
  10
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r1'),
  'normalizing'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.put_area_in_release(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r1'),
  'fixture_auth:outer:only', NULL, '{}'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r1'),
  'publishing'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.publish_import(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r1'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r1')
) WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_result
SELECT 'published-r2', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.retry_manifest('retry_protected', 'r2'),
    pg_temp.retry_claim('worker-published-2')
  ) prepared
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_executor
SELECT 'published-r2', geo_genius_test.claim_import_executor(run_id)
  FROM exact_retry_result
 WHERE case_key = 'published-r2'
   AND pg_temp.exact_retry_available();
SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r2'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r2'),
  'downloading'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.record_artifact_observation(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r2'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r2'),
  (SELECT artifact.id
     FROM geo_genius.artifact
     JOIN geo_genius.source_release ON source_release.id = artifact.source_release_id
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'retry_protected:source'
      AND artifact.logical_name = 'A'),
  repeat('a', 64),
  10
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r2'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r2'),
  'normalizing'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.put_area_in_release(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r2'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r2'),
  'fixture_auth:outer:only', NULL, '{}'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r2'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r2'),
  'publishing'
) WHERE pg_temp.exact_retry_available();
SELECT geo_genius.publish_import(
  (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r2'),
  (SELECT executor_id FROM exact_retry_executor WHERE case_key = 'published-r2')
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT previous_release_id FROM geo_genius.publication
    WHERE collection_id = (
      SELECT collection_id FROM geo_genius.release
       WHERE id = (SELECT release_id FROM exact_retry_result WHERE case_key = 'published-r2'))),
  (SELECT release_id FROM exact_retry_result WHERE case_key = 'published-r1'),
  'r1 is the prior-published rollback target before protected retry checks'
) WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'prior-published', 'before', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();
INSERT INTO exact_retry_result
SELECT 'prior-published', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r1'),
    pg_temp.retry_manifest('retry_protected', 'r1'),
    pg_temp.retry_claim('worker-published-3')
  ) retried
 WHERE pg_temp.exact_retry_available();
INSERT INTO exact_retry_snapshot
SELECT 'prior-published', 'after', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'prior-published'),
  'error',
  'a prior-published rollback target receives an error decision'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'prior-published'),
  'protected',
  'retry_failed protects a prior-published rollback target'
) WHERE pg_temp.exact_retry_available();
SELECT is(
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'prior-published' AND phase = 'after'),
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'prior-published' AND phase = 'before'),
  'a prior-published refusal performs zero writes'
) WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'current', 'before', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();
INSERT INTO exact_retry_result
SELECT 'current', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r2'),
    pg_temp.retry_manifest('retry_protected', 'r2'),
    pg_temp.retry_claim('worker-published-3')
  ) retried
 WHERE pg_temp.exact_retry_available();
INSERT INTO exact_retry_snapshot
SELECT 'current', 'after', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'current'),
  'error',
  'a currently published release receives an error decision'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'current'),
  'protected',
  'retry_failed protects the currently published release'
) WHERE pg_temp.exact_retry_available();
SELECT is(
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'current' AND phase = 'after'),
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'current' AND phase = 'before'),
  'a current-publication refusal performs zero writes'
) WHERE pg_temp.exact_retry_available();

SELECT geo_genius.retire_releases('retry_protected', 1)
 WHERE pg_temp.exact_retry_available();

INSERT INTO exact_retry_snapshot
SELECT 'retired', 'before', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();
INSERT INTO exact_retry_result
SELECT 'retired', retried.*
  FROM pg_temp.call_retry(
    (SELECT run_id FROM exact_retry_result WHERE case_key = 'published-r1'),
    pg_temp.retry_manifest('retry_protected', 'r1'),
    pg_temp.retry_claim('worker-published-4')
  ) retried
 WHERE pg_temp.exact_retry_available();
INSERT INTO exact_retry_snapshot
SELECT 'retired', 'after', pg_temp.retry_catalog_snapshot()
 WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT decision FROM exact_retry_result WHERE case_key = 'retired'),
  'error',
  'a retired release receives an error decision'
) WHERE pg_temp.exact_retry_available();

SELECT is(
  (SELECT reason FROM exact_retry_result WHERE case_key = 'retired'),
  'protected',
  'retry_failed protects a retired release'
) WHERE pg_temp.exact_retry_available();
SELECT is(
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'retired' AND phase = 'after'),
  (SELECT state FROM exact_retry_snapshot WHERE case_key = 'retired' AND phase = 'before'),
  'a retired-release refusal performs zero writes'
) WHERE pg_temp.exact_retry_available();

SELECT finish();

ROLLBACK;
