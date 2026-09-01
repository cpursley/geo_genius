BEGIN;

CREATE FUNCTION pg_temp.exact_manifest(
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
    'description', 'exact registration fixture',
    'release', release_key,
    'provider', 'fixture',
    'requires_geometry', false,
    'authorities', jsonb_build_array(
      jsonb_build_object('key', 'fixture_auth', 'name', 'Fixture Authority')
    ),
    'area_types', jsonb_build_array(
      jsonb_build_object(
        'key', 'outer', 'rank', 10, 'requires_geometry', false
      )
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
                'url', 'https://example.test/' || lower(artifact_name),
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

CREATE FUNCTION pg_temp.exact_claim(claim_owner text)
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT jsonb_build_object(
    'owner', claim_owner,
    'runner_backend', 'test',
    'stale_after_seconds', 900
  );
$fn$;

CREATE FUNCTION pg_temp.exact_catalog_snapshot()
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

CREATE FUNCTION pg_temp.prepare_available()
RETURNS boolean
LANGUAGE sql
AS $fn$
  SELECT to_regprocedure('geo_genius.prepare_import(jsonb,jsonb)') IS NOT NULL;
$fn$;

DO $fn$
BEGIN
  IF pg_temp.prepare_available() THEN
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
  END IF;
END;
$fn$;

CREATE TEMP TABLE exact_registration_result (
  case_key text PRIMARY KEY,
  decision text,
  reason text,
  release_id uuid,
  run_id uuid,
  attempt integer
);

CREATE TEMP TABLE exact_registration_snapshot (
  case_key text,
  phase text,
  state jsonb,
  PRIMARY KEY (case_key, phase)
);

CREATE TEMP TABLE exact_registration_executor (
  case_key text PRIMARY KEY,
  executor_id uuid NOT NULL
);

SELECT plan(43);

SELECT has_function(
  'geo_genius',
  'prepare_import',
  ARRAY['jsonb', 'jsonb'],
  'prepare_import exposes the atomic manifest-and-claim boundary'
);

SELECT * FROM skip(
  'prepare_import(jsonb,jsonb) is not installed',
  42
) WHERE NOT pg_temp.prepare_available();

-- An absent release is registered exactly and claimed as attempt 1.
INSERT INTO exact_registration_result
SELECT 'absent', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1'),
    pg_temp.exact_claim('worker-1')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_executor
SELECT 'absent', geo_genius_test.claim_import_executor(run_id)
  FROM exact_registration_result
 WHERE case_key = 'absent'
   AND pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'absent'),
  'enqueue',
  'an absent release is registered and enqueued'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'absent'),
  'registered',
  'an absent release reports that it was registered'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT attempt FROM exact_registration_result WHERE case_key = 'absent'),
  1,
  'an absent release starts at attempt 1'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT manifest FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent')),
  pg_temp.exact_manifest('registration_live', 'r1'),
  'the first attempt snapshots the exact claimed manifest'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT manifest FROM geo_genius.release
    WHERE id = (SELECT release_id FROM exact_registration_result WHERE case_key = 'absent')),
  pg_temp.exact_manifest('registration_live', 'r1'),
  'the candidate release stores the exact registered manifest'
) WHERE pg_temp.prepare_available();

-- An identical claim by the live owner is a read-only handoff of the same run.
INSERT INTO exact_registration_snapshot
SELECT 'live-identical', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'live-identical', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1'),
    pg_temp.exact_claim('worker-1')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'live-identical', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'live-identical'),
  'enqueue',
  'an identical claim by the live owner is re-enqueued after commit'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'live-identical'),
  'same_owner',
  'an identical live claim reports the same-owner handoff'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'live-identical'),
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent'),
  'an identical live claim returns the same run id'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'live-identical' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'live-identical' AND phase = 'before'),
  'an identical live claim performs zero catalog or lease writes'
) WHERE pg_temp.prepare_available();

-- A different owner cannot take a live claim, even with the same manifest.
INSERT INTO exact_registration_snapshot
SELECT 'live-owner', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'live-owner', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1'),
    pg_temp.exact_claim('worker-2')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'live-owner', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'live-owner'),
  'error',
  'a different owner receives an error decision for a live import'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'live-owner'),
  'live_import',
  'a different owner is refused as a live import'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'live-owner' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'live-owner' AND phase = 'before'),
  'a refused live owner performs zero writes'
) WHERE pg_temp.prepare_available();

-- A changed manifest cannot mutate a candidate while any import is live.
INSERT INTO exact_registration_snapshot
SELECT 'live-changed', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'live-changed', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1') ||
      '{"description":"changed while live"}'::jsonb,
    pg_temp.exact_claim('worker-1')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'live-changed', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'live-changed'),
  'error',
  'a changed manifest receives an error decision while the import is live'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'live-changed'),
  'live_import',
  'live-state protection takes precedence over a changed manifest'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'live-changed' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'live-changed' AND phase = 'before'),
  'a changed live manifest performs zero writes'
) WHERE pg_temp.prepare_available();

-- A stale nonterminal run is inspectable but never reclaimed or reset.
UPDATE geo_genius.import_run_lease
   SET heartbeat_at = clock_timestamp() - interval '1 hour'
 WHERE run_id = (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent')
   AND pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'stale', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'stale', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1'),
    pg_temp.exact_claim('worker-1')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'stale', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'stale'),
  'error',
  'a stale nonterminal run receives an error decision'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'stale'),
  'stale_import',
  'a stale nonterminal run is refused without reclamation'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'stale' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'stale' AND phase = 'before'),
  'a stale refusal performs zero writes or reset'
) WHERE pg_temp.prepare_available();

-- A failed candidate refuses every ordinary prepare call. Only retry_failed
-- may reset it into a new attempt, even when the manifest is identical.
SELECT geo_genius.upsert_area(
  'registration_live', 'fixture_auth', 'outer', 'candidate-only'
) WHERE pg_temp.prepare_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'absent'),
  'normalizing'
) WHERE pg_temp.prepare_available();

SELECT geo_genius.put_area_in_release(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'absent'),
  'fixture_auth:outer:candidate-only', NULL, '{}'::jsonb
) WHERE pg_temp.prepare_available();

SELECT geo_genius.put_area_name(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'absent'),
  'fixture_auth:outer:candidate-only', 'Candidate Only', 'official', NULL
) WHERE pg_temp.prepare_available();

SELECT geo_genius.put_area_code(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'absent'),
  'fixture_auth:outer:candidate-only', 'fixture', 'candidate-only'
) WHERE pg_temp.prepare_available();

SELECT geo_genius.fail_import(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'absent'),
  '{"reason":"fixture failure"}'::jsonb
) WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'failed-changed', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'failed-changed', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1') ||
      '{"description":"corrected"}'::jsonb,
    pg_temp.exact_claim('worker-2')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'failed-changed', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'failed-changed'),
  'error',
  'ordinary prepare refuses a changed manifest for a failed candidate'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'failed-changed'),
  'manifest_changed',
  'ordinary prepare identifies the failed candidate manifest change'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'failed-changed' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'failed-changed' AND phase = 'before'),
  'a refused failed-candidate correction performs zero writes'
) WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'failed-identical', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'failed-identical', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1'),
    pg_temp.exact_claim('worker-2')
 ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'failed-identical', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'failed-identical'),
  'error',
  'ordinary prepare refuses an identical failed candidate'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'failed-identical'),
  'failed',
  'an identical failed candidate directs the caller to explicit recovery'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'failed-identical'),
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'absent'),
  'an identical failed-candidate refusal identifies the failed run'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT attempt FROM exact_registration_result WHERE case_key = 'failed-identical'),
  1,
  'an identical failed-candidate refusal returns the failed attempt number'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'failed-identical' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'failed-identical' AND phase = 'before'),
  'an identical failed-candidate refusal performs zero writes'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT count(*)::integer FROM geo_genius.import_run
    WHERE release_id = (SELECT release_id FROM exact_registration_result
                         WHERE case_key = 'failed-identical')),
  1,
  'ordinary prepare creates no replacement attempt for a failed candidate'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM exact_registration_result
                 WHERE case_key = 'failed-identical')),
  'failed',
  'ordinary prepare preserves the failed attempt as terminal evidence'
) WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'failed-retry', retried.*
  FROM geo_genius.retry_failed(
    (SELECT run_id FROM exact_registration_result WHERE case_key = 'failed-identical'),
    pg_temp.exact_manifest('registration_live', 'r1'),
    pg_temp.exact_claim('worker-2')
  ) retried
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_executor
SELECT 'failed-retry', geo_genius_test.claim_import_executor(run_id)
  FROM exact_registration_result
 WHERE case_key = 'failed-retry'
   AND pg_temp.prepare_available();

-- A valid completed candidate is protected even before publication.
SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'failed-retry'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'failed-retry'),
  'downloading'
) WHERE pg_temp.prepare_available();

SELECT geo_genius.record_artifact_observation(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'failed-retry'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'failed-retry'),
  (SELECT artifact.id
     FROM geo_genius.artifact
     JOIN geo_genius.source_release ON source_release.id = artifact.source_release_id
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'registration_live:source'
      AND artifact.logical_name = 'A'),
  repeat('a', 64),
  10
) WHERE pg_temp.prepare_available();

SELECT geo_genius.upsert_area(
  'registration_live', 'fixture_auth', 'outer', 'completed-only'
) WHERE pg_temp.prepare_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'failed-retry'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'failed-retry'),
  'normalizing'
) WHERE pg_temp.prepare_available();

SELECT geo_genius.put_area_in_release(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'failed-retry'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'failed-retry'),
  'fixture_auth:outer:completed-only',
  NULL,
  '{}'::jsonb
) WHERE pg_temp.prepare_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'failed-retry'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'failed-retry'),
  'verifying'
) WHERE pg_temp.prepare_available();

SELECT geo_genius.complete_import(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'failed-retry'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'failed-retry'),
  '{}'::jsonb
) WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'completed-identical', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'completed-identical', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1'),
    pg_temp.exact_claim('worker-3')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'completed-identical', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'completed-identical'),
  'error',
  'an identical completed candidate receives an error decision'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'completed-identical'),
  'protected',
  'an identical completed candidate reports its protected state'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'completed-identical'),
  NULL::uuid,
  'a protected completed candidate exposes no claimable run id'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'completed-identical' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'completed-identical' AND phase = 'before'),
  'an identical completed candidate performs zero writes'
) WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'completed-changed', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'completed-changed', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_live', 'r1') ||
      '{"description":"changed after completion"}'::jsonb,
    pg_temp.exact_claim('worker-3')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'completed-changed', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'completed-changed'),
  'error',
  'a changed completed candidate receives an error decision'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'completed-changed'),
  'protected',
  'a changed completed candidate remains protected without reopening it'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'completed-changed' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'completed-changed' AND phase = 'before'),
  'a changed completed candidate performs zero writes'
) WHERE pg_temp.prepare_available();

-- Atomic import publication protects the candidate after its latest attempt
-- completes successfully.
INSERT INTO exact_registration_result
SELECT 'protected-first', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_protected', 'r1'),
    pg_temp.exact_claim('worker-protected')
 ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_executor
SELECT 'protected-first', geo_genius_test.claim_import_executor(run_id)
  FROM exact_registration_result
 WHERE case_key = 'protected-first'
   AND pg_temp.prepare_available();

SELECT geo_genius.upsert_area(
  'registration_protected', 'fixture_auth', 'outer', 'only'
) WHERE pg_temp.prepare_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'protected-first'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'protected-first'),
  'downloading'
) WHERE pg_temp.prepare_available();

SELECT geo_genius.record_artifact_observation(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'protected-first'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'protected-first'),
  (SELECT artifact.id
     FROM geo_genius.artifact
     JOIN geo_genius.source_release ON source_release.id = artifact.source_release_id
     JOIN geo_genius.source ON source.id = source_release.source_id
    WHERE source.source_key = 'registration_protected:source'
      AND artifact.logical_name = 'A'),
  repeat('a', 64),
  10
) WHERE pg_temp.prepare_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'protected-first'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'protected-first'),
  'normalizing'
) WHERE pg_temp.prepare_available();

SELECT geo_genius.put_area_in_release(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'protected-first'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'protected-first'),
  'fixture_auth:outer:only',
  NULL,
  '{}'::jsonb
) WHERE pg_temp.prepare_available();

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'protected-first'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'protected-first'),
  'publishing'
) WHERE pg_temp.prepare_available();

SELECT geo_genius.publish_import(
  (SELECT run_id FROM exact_registration_result WHERE case_key = 'protected-first'),
  (SELECT executor_id FROM exact_registration_executor WHERE case_key = 'protected-first')
) WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'published', 'before', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'published', prepared.*
  FROM pg_temp.call_prepare(
    pg_temp.exact_manifest('registration_protected', 'r1') ||
      '{"description":"changed after publication"}'::jsonb,
    pg_temp.exact_claim('worker-protected-2')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_snapshot
SELECT 'published', 'after', pg_temp.exact_catalog_snapshot()
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'published'),
  'error',
  'a published candidate receives an error decision'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT reason FROM exact_registration_result WHERE case_key = 'published'),
  'protected',
  'publication protects a candidate from ordinary registration'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'published' AND phase = 'after'),
  (SELECT state FROM exact_registration_snapshot
    WHERE case_key = 'published' AND phase = 'before'),
  'a protected publication refusal performs zero writes'
) WHERE pg_temp.prepare_available();

-- A source key is stable only inside its collection. Two unrelated catalogs
-- may deliberately use the same provider-native key without sharing an
-- identity or blocking one another's registration.
INSERT INTO exact_registration_result
SELECT 'shared-source-a', prepared.*
  FROM pg_temp.call_prepare(
    jsonb_set(
      pg_temp.exact_manifest('registration_source_a', 'r1'),
      '{sources,0,source_key}',
      to_jsonb('shared_source'::text)
    ),
    pg_temp.exact_claim('worker-source-a')
  ) prepared
 WHERE pg_temp.prepare_available();

INSERT INTO exact_registration_result
SELECT 'shared-source-b', prepared.*
  FROM pg_temp.call_prepare(
    jsonb_set(
      pg_temp.exact_manifest('registration_source_b', 'r1'),
      '{sources,0,source_key}',
      to_jsonb('shared_source'::text)
    ),
    pg_temp.exact_claim('worker-source-b')
  ) prepared
 WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'shared-source-a'),
  'enqueue',
  'the first collection may register a provider-native source key'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT decision FROM exact_registration_result WHERE case_key = 'shared-source-b'),
  'enqueue',
  'another collection may independently register the same source key'
) WHERE pg_temp.prepare_available();

SELECT is(
  (SELECT count(*)::integer
     FROM geo_genius.source
     JOIN geo_genius.collection ON collection.id = source.collection_id
    WHERE source.source_key = 'shared_source'
      AND collection.key IN ('registration_source_a', 'registration_source_b')),
  2,
  'source identity remains scoped by collection and source key together'
) WHERE pg_temp.prepare_available();

SELECT hasnt_function(
  'geo_genius',
  'begin_or_resume_import',
  ARRAY['uuid', 'text', 'text', 'interval'],
  'the legacy claim bypass is absent from the callable SQL contract'
) WHERE pg_temp.prepare_available();

SELECT finish();

ROLLBACK;
