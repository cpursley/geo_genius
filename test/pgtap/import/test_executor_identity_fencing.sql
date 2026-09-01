BEGIN;

CREATE TEMP TABLE executor_fencing_attempt AS
SELECT prepared.run_id, prepared.release_id
  FROM geo_genius.prepare_import(
    '{
      "collection":"executor_fencing",
      "collection_name":"Executor Fencing",
      "release":"r1",
      "provider":"fixture",
      "requires_geometry":false,
      "authorities":[],
      "area_types":[],
      "sources":[],
      "options":{}
    }'::jsonb,
    '{"owner":"test","runner_backend":"test","stale_after_seconds":900}'::jsonb
  ) AS prepared;

SELECT plan(15);

SELECT has_function(
  'geo_genius',
  'assert_import_write',
  ARRAY['uuid', 'uuid', 'text[]'],
  'the import write fence requires the claimed executor identity'
);

SELECT throws_ok(
  format(
    'SELECT geo_genius.assert_import_write(%L::uuid, %L::uuid, ARRAY[''pending''])',
    (SELECT run_id FROM executor_fencing_attempt),
    '11111111-1111-4111-8111-111111111111'
  ),
  '55000', NULL,
  'an unclaimed executor cannot mutate an import attempt'
);

SELECT is(
  geo_genius.claim_import_execution(
    (SELECT run_id FROM executor_fencing_attempt),
    '11111111-1111-4111-8111-111111111111'::uuid
  ),
  'claimed',
  'one executor claims the attempt'
);

SELECT throws_ok(
  format(
    'SELECT geo_genius.assert_import_write(%L::uuid, %L::uuid, ARRAY[''pending''])',
    (SELECT run_id FROM executor_fencing_attempt),
    '22222222-2222-4222-8222-222222222222'
  ),
  '55000', NULL,
  'a different executor cannot use the winning run id'
);

SELECT results_eq(
  format(
    'SELECT geo_genius.assert_import_write(%L::uuid, %L::uuid, ARRAY[''pending''])',
    (SELECT run_id FROM executor_fencing_attempt),
    '11111111-1111-4111-8111-111111111111'
  ),
  format(
    'VALUES (%L::uuid)',
    (SELECT release_id FROM executor_fencing_attempt)
  ),
  'the winning executor can exercise the write capability'
);

SELECT throws_ok(
  format(
    'SELECT geo_genius.heartbeat_import(%L::uuid, %L::uuid, ''{"wrong":true}''::jsonb)',
    (SELECT run_id FROM executor_fencing_attempt),
    '22222222-2222-4222-8222-222222222222'
  ),
  '55000', NULL,
  'a different executor cannot heartbeat the winning attempt'
);

SELECT geo_genius.heartbeat_import(
  (SELECT run_id FROM executor_fencing_attempt),
  '11111111-1111-4111-8111-111111111111'::uuid,
  '{"owned":true}'::jsonb
);

SELECT is(
  (SELECT progress
     FROM geo_genius.import_run_lease
    WHERE run_id = (SELECT run_id FROM executor_fencing_attempt)),
  '{"owned":true}'::jsonb,
  'the winning executor can renew and update its lease'
);

SELECT hasnt_function(
  'geo_genius', 'assert_import_write', ARRAY['uuid', 'text[]'],
  'no executor-free import write fence remains callable'
);

SELECT hasnt_function(
  'geo_genius', 'heartbeat_import', ARRAY['uuid', 'jsonb'],
  'no executor-free heartbeat remains callable'
);

SELECT hasnt_function(
  'geo_genius', 'advance_import', ARRAY['uuid', 'text', 'jsonb'],
  'no executor-free phase advance remains callable'
);

SELECT hasnt_function(
  'geo_genius', 'verify_import', ARRAY['uuid'],
  'no executor-free import verification remains callable'
);

SELECT hasnt_function(
  'geo_genius', 'publish_import', ARRAY['uuid'],
  'no executor-free import publication remains callable'
);

SELECT hasnt_function(
  'geo_genius', 'create_staging', ARRAY['uuid'],
  'no executor-free staging creation remains callable'
);

SELECT hasnt_function(
  'geo_genius', 'insert_staging_many', ARRAY['uuid', 'text[]', 'jsonb[]', 'geometry[]'],
  'no executor-free staging write remains callable'
);

SELECT hasnt_function(
  'geo_genius', 'analyze_import', ARRAY['uuid'],
  'no executor-free import analyze remains callable'
);

SELECT * FROM finish();
ROLLBACK;
