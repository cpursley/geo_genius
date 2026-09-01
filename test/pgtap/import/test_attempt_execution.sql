BEGIN;

CREATE FUNCTION pg_temp.execution_manifest(collection_key text, release_key text)
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT jsonb_build_object(
    'collection', collection_key,
    'collection_name', collection_key,
    'release', release_key,
    'provider', 'geojson',
    'requires_geometry', false,
    'authorities', jsonb_build_array(
      jsonb_build_object('key', 'fixture_auth', 'name', 'Fixture Authority')
    ),
    'area_types', jsonb_build_array(
      jsonb_build_object('key', 'fixture_area', 'rank', 10, 'requires_geometry', false)
    ),
    'sources', jsonb_build_array(
      jsonb_build_object(
        'source_key', collection_key || ':source',
        'provider', 'fixture',
        'license', 'test',
        'release_key', 'v1',
        'artifacts', '[]'::jsonb
      )
    ),
    'options', '{}'::jsonb
  );
$fn$;

CREATE FUNCTION pg_temp.execution_claim(claim_owner text)
RETURNS jsonb
LANGUAGE sql
AS $fn$
  SELECT jsonb_build_object(
    'owner', claim_owner,
    'runner_backend', 'test',
    'stale_after_seconds', 900
  );
$fn$;

CREATE TEMP TABLE execution_attempt AS
SELECT prepared.run_id, prepared.release_id
  FROM geo_genius.prepare_import(
    pg_temp.execution_manifest('execution_fixture', 'r1'),
    pg_temp.execution_claim('owner-a')
  ) AS prepared;

SELECT plan(23);

SELECT has_column(
  'geo_genius', 'import_run_lease', 'executor_id',
  'an import lease records the executor that won single-flight execution'
);

SELECT has_column(
  'geo_genius', 'import_run_lease', 'execution_started_at',
  'an import lease records when single-flight execution began'
);

SELECT col_type_is(
  'geo_genius', 'import_run_lease', 'executor_id', 'uuid',
  'executor_id is a uuid'
);

SELECT col_type_is(
  'geo_genius', 'import_run_lease', 'execution_started_at',
  'timestamp with time zone',
  'execution_started_at is a timestamp with time zone'
);

SELECT is(
  (SELECT jsonb_build_array(executor_id, execution_started_at)
     FROM geo_genius.import_run_lease
    WHERE run_id = (SELECT run_id FROM execution_attempt)),
  '[null, null]'::jsonb,
  'a newly prepared attempt has not yet been executed'
);

SELECT throws_ok(
  format(
    'UPDATE geo_genius.import_run_lease SET executor_id = %L::uuid WHERE run_id = %L::uuid',
    '11111111-1111-4111-8111-111111111111',
    (SELECT run_id FROM execution_attempt)
  ),
  '23514', NULL,
  'the executor identity and start timestamp cannot be written separately'
);

SELECT has_function(
  'geo_genius', 'claim_import_execution', ARRAY['uuid', 'uuid'],
  'claim_import_execution is installed'
);

SELECT is(
  geo_genius.claim_import_execution(
    (SELECT run_id FROM execution_attempt),
    '11111111-1111-4111-8111-111111111111'::uuid
  ),
  'claimed',
  'the first executor claims a pending latest leased attempt'
);

CREATE TEMP TABLE first_execution AS
SELECT executor_id, execution_started_at
  FROM geo_genius.import_run_lease
 WHERE run_id = (SELECT run_id FROM execution_attempt);

SELECT is(
  (SELECT executor_id FROM first_execution),
  '11111111-1111-4111-8111-111111111111'::uuid,
  'a successful claim stores the winning executor id'
);

SELECT isnt(
  (SELECT execution_started_at FROM first_execution),
  NULL::timestamptz,
  'a successful claim stores its execution start time'
);

SELECT is(
  geo_genius.claim_import_execution(
    (SELECT run_id FROM execution_attempt),
    '22222222-2222-4222-8222-222222222222'::uuid
  ),
  'occupied',
  'a duplicate executor receives an occupied decision'
);

SELECT is(
  (SELECT jsonb_build_object(
            'executor_id', executor_id,
            'execution_started_at', execution_started_at)
     FROM geo_genius.import_run_lease
    WHERE run_id = (SELECT run_id FROM execution_attempt)),
  (SELECT jsonb_build_object(
            'executor_id', executor_id,
            'execution_started_at', execution_started_at)
     FROM first_execution),
  'a duplicate claim preserves the winner and its original timestamp'
);

CREATE TEMP TABLE advanced_attempt AS
SELECT prepared.run_id
  FROM geo_genius.prepare_import(
    pg_temp.execution_manifest('execution_advanced', 'r1'),
    pg_temp.execution_claim('owner-b')
  ) AS prepared;

SELECT throws_ok(
  format(
    'SELECT geo_genius.advance_import(%L::uuid, %L::uuid, ''downloading'', ''{}''::jsonb)',
    (SELECT run_id FROM advanced_attempt),
    '33333333-3333-4333-8333-333333333333'
  ),
  '55000', NULL,
  'an unclaimed executor cannot advance an import attempt'
);

SELECT is(
  geo_genius.claim_import_execution(
    (SELECT run_id FROM advanced_attempt),
    '33333333-3333-4333-8333-333333333333'::uuid
  ),
  'claimed',
  'the executor can claim after its refused unclaimed advance'
);

SELECT is(
  geo_genius.claim_import_execution(
    '00000000-0000-4000-8000-000000000000'::uuid,
    '44444444-4444-4444-8444-444444444444'::uuid
  ),
  'missing',
  'a missing run is a decision rather than an exception'
);

CREATE TEMP TABLE completed_attempt AS
SELECT prepared.run_id
  FROM geo_genius.prepare_import(
    pg_temp.execution_manifest('execution_completed', 'r1'),
    pg_temp.execution_claim('owner-c')
  ) AS prepared;

SELECT geo_genius.claim_import_execution(
  (SELECT run_id FROM completed_attempt),
  '55555555-5555-4555-8555-555555555555'::uuid
);

SELECT geo_genius.upsert_area(
  'execution_completed', 'fixture_auth', 'fixture_area', 'completed-only'
);

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM completed_attempt),
  '55555555-5555-4555-8555-555555555555'::uuid,
  'normalizing'
);

SELECT geo_genius.put_area_in_release(
  (SELECT run_id FROM completed_attempt),
  '55555555-5555-4555-8555-555555555555'::uuid,
  'fixture_auth:fixture_area:completed-only',
  NULL,
  '{}'::jsonb
);

SELECT geo_genius_test.advance_import_to(
  (SELECT run_id FROM completed_attempt),
  '55555555-5555-4555-8555-555555555555'::uuid,
  'verifying'
);

SELECT geo_genius.complete_import(
  (SELECT run_id FROM completed_attempt),
  '55555555-5555-4555-8555-555555555555'::uuid,
  '{}'::jsonb
);

SELECT is(
  geo_genius.claim_import_execution(
    (SELECT run_id FROM completed_attempt),
    '55555555-5555-4555-8555-555555555555'::uuid
  ),
  'completed',
  'a completed run is returned as a terminal decision'
);

CREATE TEMP TABLE failed_attempt AS
SELECT prepared.run_id
  FROM geo_genius.prepare_import(
    pg_temp.execution_manifest('execution_failed', 'r1'),
    pg_temp.execution_claim('owner-d')
  ) AS prepared;

SELECT geo_genius.claim_import_execution(
  (SELECT run_id FROM failed_attempt),
  '66666666-6666-4666-8666-666666666666'::uuid
);

SELECT geo_genius.fail_import(
  (SELECT run_id FROM failed_attempt),
  '66666666-6666-4666-8666-666666666666'::uuid,
  '{"reason":"fixture"}'::jsonb);

SELECT is(
  geo_genius.claim_import_execution(
    (SELECT run_id FROM failed_attempt),
    '66666666-6666-4666-8666-666666666666'::uuid
  ),
  'failed',
  'a failed run is returned as a terminal decision'
);

CREATE TEMP TABLE stranded_attempt AS
SELECT prepared.run_id, prepared.release_id
  FROM geo_genius.prepare_import(
    pg_temp.execution_manifest('execution_stranded', 'r1'),
    pg_temp.execution_claim('owner-e')
  ) AS prepared;

SELECT geo_genius.claim_import_execution(
  (SELECT run_id FROM stranded_attempt),
  '77777777-7777-4777-8777-777777777777'::uuid
);

SELECT throws_ok(
  format(
    'SELECT geo_genius.publish_release(%L::uuid)',
    (SELECT release_id FROM stranded_attempt)
  ),
  '55000', NULL,
  'admin publication refuses a release while an import lease is active'
);

SELECT is(
  (SELECT status
     FROM geo_genius.release
    WHERE id = (SELECT release_id FROM stranded_attempt)),
  'pending',
  'refused admin publication leaves the live candidate mutable'
);

-- This deliberately constructs the invalid state that publish_release now
-- refuses. The common attempt fence must still make a catalog damaged by a
-- direct table write fail closed instead of mutating a published candidate.
UPDATE geo_genius.import_run
   SET status = 'relating'
 WHERE id = (SELECT run_id FROM stranded_attempt);

UPDATE geo_genius.release
   SET status = 'completed', completed_at = now()
 WHERE id = (SELECT release_id FROM stranded_attempt);

SELECT throws_ok(
  format(
    'SELECT geo_genius.rebuild_relations(%L::uuid, %L::uuid)',
    (SELECT run_id FROM stranded_attempt),
    '77777777-7777-4777-8777-777777777777'
  ),
  '55000', NULL,
  'the common attempt fence refuses relation rebuilds on a completed release'
);

SELECT is(
  (SELECT count(*)::bigint
     FROM geo_genius.relation
    WHERE release_id = (SELECT release_id FROM stranded_attempt)),
  0::bigint,
  'a refused relation rebuild leaves published edges unchanged'
);

UPDATE geo_genius.import_run
   SET status = 'staging'
 WHERE id = (SELECT run_id FROM stranded_attempt);

SELECT throws_ok(
  format(
    'SELECT geo_genius.create_staging(%L::uuid, %L::uuid)',
    (SELECT run_id FROM stranded_attempt),
    '77777777-7777-4777-8777-777777777777'
  ),
  '55000', NULL,
  'the common attempt fence refuses staging writes on a completed release'
);

SELECT is(
  to_regclass(
    'geo_genius.' || geo_genius.staging_table_name(
      (SELECT run_id FROM stranded_attempt)
    )
  ),
  NULL::regclass,
  'a refused staging write creates no table'
);

SELECT * FROM finish();

ROLLBACK;
