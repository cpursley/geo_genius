BEGIN;

SELECT plan(43);

CREATE TEMP TABLE lifecycle_attempt (
  scenario text PRIMARY KEY,
  run_id uuid NOT NULL,
  executor_id uuid NOT NULL
);

INSERT INTO lifecycle_attempt (scenario, run_id, executor_id)
SELECT scenario, run_id, geo_genius_test.claim_import_executor(run_id)
  FROM (
    SELECT scenario,
           (geo_genius.prepare_import(
             jsonb_build_object(
               'collection', 'lifecycle_' || scenario,
               'collection_name', 'Lifecycle ' || scenario,
               'release', 'r1',
               'requires_geometry', false,
               'authorities', '[]'::jsonb,
               'area_types', '[]'::jsonb,
               'sources', '[]'::jsonb
             ),
             jsonb_build_object(
               'owner', 'lifecycle-' || scenario,
               'runner_backend', 'pgtap'
             )
           )).run_id
      FROM unnest(ARRAY[
        'skip_pending',
        'complete_directly',
        'fail_directly',
        'skip_downloading',
        'backtrack',
        'valid',
        'fail_api'
      ]) AS scenarios(scenario)
  ) AS prepared;

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'skip_pending'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'skip_pending'),
      'staging', '{}'::jsonb)$$,
  '55000',
  'import run ' ||
    (SELECT run_id::text FROM lifecycle_attempt WHERE scenario = 'skip_pending') ||
    ' cannot advance from pending to staging',
  'advance_import rejects a phase skip from pending to staging'
);

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'complete_directly'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'complete_directly'),
      'completed', '{}'::jsonb)$$,
  '55000',
  'import run ' ||
    (SELECT run_id::text FROM lifecycle_attempt WHERE scenario = 'complete_directly') ||
    ' cannot advance from pending to completed',
  'advance_import cannot terminalize a run as completed'
);

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'fail_directly'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'fail_directly'),
      'failed', '{}'::jsonb)$$,
  '55000',
  'import run ' ||
    (SELECT run_id::text FROM lifecycle_attempt WHERE scenario = 'fail_directly') ||
    ' cannot advance from pending to failed',
  'advance_import cannot terminalize a run as failed'
);

SELECT lives_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'skip_downloading'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'skip_downloading'),
      'downloading', '{}'::jsonb)$$,
  'pending may advance to downloading'
);

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'skip_downloading'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'skip_downloading'),
      'staging', '{}'::jsonb)$$,
  '55000',
  'import run ' ||
    (SELECT run_id::text FROM lifecycle_attempt WHERE scenario = 'skip_downloading') ||
    ' cannot advance from downloading to staging',
  'advance_import rejects a phase skip from downloading to staging'
);

SELECT lives_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'backtrack'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'backtrack'),
      'downloading', '{}'::jsonb)$$,
  'backtracking fixture reaches downloading'
);

SELECT lives_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'backtrack'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'backtrack'),
      'validating', '{}'::jsonb)$$,
  'downloading may advance to validating'
);

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'backtrack'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'backtrack'),
      'downloading', '{}'::jsonb)$$,
  '55000',
  'import run ' ||
    (SELECT run_id::text FROM lifecycle_attempt WHERE scenario = 'backtrack') ||
    ' cannot advance from validating to downloading',
  'advance_import rejects a phase backtrack'
);

SELECT lives_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'downloading', '{}'::jsonb);
    SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'validating', '{}'::jsonb);
    SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'staging', '{}'::jsonb);
    SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'normalizing', '{}'::jsonb);
    SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'relating', '{}'::jsonb);
    SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'indexing', '{}'::jsonb);
    SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'verifying', '{}'::jsonb);
    SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'publishing', '{}'::jsonb)$$,
  'the complete nonterminal phase sequence is accepted'
);

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid')),
  'publishing',
  'the valid phase sequence stops at publishing'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid')
  ),
  'advance_import never removes the active lease'
);

SELECT geo_genius.fail_import(
  (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'fail_api'),
  (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'fail_api'),
  '{"reason":"expected"}'::jsonb
);

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'fail_api')),
  'failed',
  'fail_import terminalizes a run as failed'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'fail_api')
  ),
  'fail_import removes the terminal run lease'
);

SELECT throws_ok(
  $$SELECT geo_genius.advance_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      'completed', '{}'::jsonb)$$,
  '55000',
  'import run ' ||
    (SELECT run_id::text FROM lifecycle_attempt WHERE scenario = 'valid') ||
    ' cannot advance from publishing to completed',
  'publishing must terminalize through publish_import, not advance_import'
);

CREATE TEMP TABLE publication_attempt (
  scenario text PRIMARY KEY,
  run_id uuid NOT NULL,
  executor_id uuid NOT NULL
);

INSERT INTO publication_attempt (scenario, run_id, executor_id)
SELECT scenario, run_id, geo_genius_test.claim_import_executor(run_id)
  FROM (
    SELECT scenario,
           (geo_genius.prepare_import(
             jsonb_build_object(
               'collection', 'publication_' || scenario,
               'collection_name', 'Publication ' || scenario,
               'release', 'r1',
               'requires_geometry', false,
               'authorities', jsonb_build_array(
                 jsonb_build_object('key', 'authority', 'name', 'Authority')
               ),
               'area_types', jsonb_build_array(
                 jsonb_build_object(
                   'key', 'area',
                   'rank', 1,
                   'requires_geometry', false
                 )
               ),
               'sources', jsonb_build_array(
                 jsonb_build_object(
                   'source_key', 'source',
                   'provider', 'csv',
                   'license', 'test',
                   'release_key', 'v1',
                   'artifacts', jsonb_build_array(
                     jsonb_build_object(
                       'logical_name', 'areas',
                       'operator_supplied', true,
                       'format', 'csv',
                       'sha256', repeat('a', 64),
                       'bytes', 1,
                       'required', scenario NOT IN (
                         'optional_missing',
                         'complete_optional_missing'
                       )
                     )
                   )
                 )
               )
             ),
             jsonb_build_object(
               'owner', 'publication-' || scenario,
               'runner_backend', 'pgtap'
             )
           )).run_id
      FROM unnest(ARRAY[
        'missing_observation',
        'direct_missing_observation',
        'optional_missing',
        'observed',
        'complete_required_missing',
        'complete_optional_missing',
        'complete_observed',
        'complete_invalid_release'
      ]) AS scenarios(scenario)
  ) AS prepared;

DO $setup$
DECLARE
  attempt record;
  target_artifact_id uuid;
BEGIN
  FOR attempt IN SELECT * FROM publication_attempt LOOP
    PERFORM geo_genius.advance_import(
      attempt.run_id, attempt.executor_id, 'downloading', '{}'::jsonb);

    IF attempt.scenario IN ('observed', 'complete_observed', 'complete_invalid_release') THEN
      SELECT artifact_id INTO STRICT target_artifact_id
        FROM geo_genius.import_run_artifact
       WHERE run_id = attempt.run_id;

      PERFORM geo_genius.record_artifact_observation(
        attempt.run_id,
        attempt.executor_id,
        target_artifact_id,
        repeat('a', 64),
        1
      );
    END IF;

    PERFORM geo_genius.advance_import(
      attempt.run_id, attempt.executor_id, 'validating', '{}'::jsonb);
    PERFORM geo_genius.advance_import(
      attempt.run_id, attempt.executor_id, 'staging', '{}'::jsonb);
    PERFORM geo_genius.advance_import(
      attempt.run_id, attempt.executor_id, 'normalizing', '{}'::jsonb);
    IF attempt.scenario <> 'complete_invalid_release' THEN
      PERFORM geo_genius.upsert_area_many(
        attempt.run_id,
        attempt.executor_id,
        ARRAY['authority'],
        ARRAY['area'],
        ARRAY[attempt.scenario]
      );
      PERFORM geo_genius.put_area_in_release(
        attempt.run_id,
        attempt.executor_id,
        'authority:area:' || attempt.scenario,
        NULL::geography,
        '{}'::jsonb
      );
    END IF;
    PERFORM geo_genius.advance_import(
      attempt.run_id, attempt.executor_id, 'relating', '{}'::jsonb);
    PERFORM geo_genius.advance_import(
      attempt.run_id, attempt.executor_id, 'indexing', '{}'::jsonb);
    PERFORM geo_genius.advance_import(
      attempt.run_id, attempt.executor_id, 'verifying', '{}'::jsonb);
    IF attempt.scenario NOT LIKE 'complete_%' THEN
      PERFORM geo_genius.advance_import(
        attempt.run_id, attempt.executor_id, 'publishing', '{}'::jsonb);
    END IF;
  END LOOP;
END;
$setup$;

SELECT throws_ok(
  $$SELECT geo_genius.publish_import(
      (SELECT run_id FROM publication_attempt
        WHERE scenario = 'missing_observation'),
      (SELECT executor_id FROM publication_attempt
        WHERE scenario = 'missing_observation'))$$,
  '23514',
  'import run ' ||
    (SELECT run_id::text FROM publication_attempt
      WHERE scenario = 'missing_observation') ||
    ' has 1 required selected artifact without validated observations',
  'publish_import rejects a selected artifact that was not validated'
);

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'missing_observation')),
  'publishing',
  'rejected publication leaves the import in its nonterminal phase'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT run_id FROM publication_attempt
       WHERE scenario = 'missing_observation')
  ),
  'rejected publication preserves the executor lease'
);

-- Direct publication is valid for a release with no import history. When a
-- completed import does exist, however, it must carry the same artifact proof
-- as publish_import. Build that historical shape directly to isolate the
-- operator API's gate from publish_import itself.
UPDATE geo_genius.import_run
   SET status = 'completed', completed_at = now()
 WHERE id = (SELECT run_id FROM publication_attempt
   WHERE scenario = 'direct_missing_observation');

DELETE FROM geo_genius.import_run_lease
 WHERE run_id = (SELECT run_id FROM publication_attempt
   WHERE scenario = 'direct_missing_observation');

SELECT throws_ok(
  $$SELECT geo_genius.publish_release(
      (SELECT release_id FROM geo_genius.import_run
        WHERE id = (SELECT run_id FROM publication_attempt
          WHERE scenario = 'direct_missing_observation')))$$,
  '23514',
  'import run ' ||
    (SELECT run_id::text FROM publication_attempt
      WHERE scenario = 'direct_missing_observation') ||
    ' has 1 required selected artifact without validated observations',
  'direct publication enforces the completed import artifact proof'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
      FROM geo_genius.publication
      JOIN geo_genius.release ON release.id = publication.release_id
     WHERE release.id = (SELECT release_id FROM geo_genius.import_run
       WHERE id = (SELECT run_id FROM publication_attempt
         WHERE scenario = 'direct_missing_observation'))
  ),
  'an unvalidated completed import remains unpublished'
);

SELECT lives_ok(
  $$SELECT geo_genius.publish_import(
      (SELECT run_id FROM publication_attempt WHERE scenario = 'optional_missing'),
      (SELECT executor_id FROM publication_attempt WHERE scenario = 'optional_missing'))$$,
  'publish_import permits a missing optional artifact observation'
);

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'optional_missing')),
  'completed',
  'an optional missing artifact does not prevent completion'
);

SELECT lives_ok(
  $$SELECT geo_genius.publish_import(
      (SELECT run_id FROM publication_attempt WHERE scenario = 'observed'),
      (SELECT executor_id FROM publication_attempt WHERE scenario = 'observed'))$$,
  'publish_import accepts a validated selected artifact'
);

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt WHERE scenario = 'observed')),
  'completed',
  'publish_import is the successful completion terminalizer'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT run_id FROM publication_attempt WHERE scenario = 'observed')
  ),
  'successful publication removes the terminal run lease'
);

SELECT throws_ok(
  $$SELECT geo_genius.complete_import(
      (SELECT run_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      (SELECT executor_id FROM lifecycle_attempt WHERE scenario = 'valid'),
      '{}'::jsonb)$$,
  '55000',
  NULL,
  'complete_import rejects an attempt outside the verifying phase'
);

SELECT throws_ok(
  $$SELECT geo_genius.complete_import(
      (SELECT run_id FROM publication_attempt WHERE scenario = 'complete_observed'),
      '00000000-0000-0000-0000-000000000003'::uuid,
      '{}'::jsonb)$$,
  '55000',
  NULL,
  'complete_import rejects an executor that does not own the current attempt'
);

SELECT throws_ok(
  $$SELECT geo_genius.complete_import(
      (SELECT run_id FROM publication_attempt
        WHERE scenario = 'complete_required_missing'),
      (SELECT executor_id FROM publication_attempt
        WHERE scenario = 'complete_required_missing'),
      '{"should_not_persist":true}'::jsonb)$$,
  '23514',
  'import run ' ||
    (SELECT run_id::text FROM publication_attempt
      WHERE scenario = 'complete_required_missing') ||
    ' has 1 required selected artifact without validated observations',
  'complete_import rejects a missing required artifact observation'
);

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'complete_required_missing')),
  'verifying',
  'an artifact-gate rejection leaves the non-publishing import verifying'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT run_id FROM publication_attempt
       WHERE scenario = 'complete_required_missing')
  ),
  'an artifact-gate rejection preserves the non-publishing executor lease'
);

SELECT is(
  (SELECT stage_metrics FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'complete_required_missing')),
  '{}'::jsonb,
  'an artifact-gate rejection does not merge terminal metrics'
);

SELECT throws_ok(
  $$SELECT geo_genius.complete_import(
      (SELECT run_id FROM publication_attempt
        WHERE scenario = 'complete_invalid_release'),
      (SELECT executor_id FROM publication_attempt
        WHERE scenario = 'complete_invalid_release'),
      '{}'::jsonb)$$,
  '23514',
  'release ' ||
    (SELECT release_id::text FROM geo_genius.import_run
      WHERE id = (SELECT run_id FROM publication_attempt
        WHERE scenario = 'complete_invalid_release')) ||
    ' failed verification: ["release contains no areas"]',
  'complete_import rejects a release that fails structural verification'
);

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'complete_invalid_release')),
  'verifying',
  'a verification rejection leaves the non-publishing import verifying'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT run_id FROM publication_attempt
       WHERE scenario = 'complete_invalid_release')
  ),
  'a verification rejection preserves the non-publishing executor lease'
);

SELECT is(
  geo_genius.complete_import(
    (SELECT run_id FROM publication_attempt
      WHERE scenario = 'complete_optional_missing'),
    (SELECT executor_id FROM publication_attempt
      WHERE scenario = 'complete_optional_missing'),
    '{}'::jsonb),
  (SELECT release_id FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'complete_optional_missing')),
  'complete_import permits a missing optional artifact observation'
);

SELECT is(
  (SELECT status FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'complete_optional_missing')),
  'completed',
  'optional-artifact completion marks the import completed'
);

SELECT is(
  (SELECT release.status FROM geo_genius.release
    JOIN geo_genius.import_run ON import_run.release_id = release.id
   WHERE import_run.id = (SELECT run_id FROM publication_attempt
     WHERE scenario = 'complete_optional_missing')),
  'completed',
  'optional-artifact completion marks the release completed'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT run_id FROM publication_attempt
       WHERE scenario = 'complete_optional_missing')
  ),
  'optional-artifact completion removes the terminal run lease'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM geo_genius.publication
     WHERE release_id = (SELECT release_id FROM geo_genius.import_run
       WHERE id = (SELECT run_id FROM publication_attempt
         WHERE scenario = 'complete_optional_missing'))
  ),
  'complete_import does not publish the optional-artifact release'
);

SELECT is(
  geo_genius.complete_import(
    (SELECT run_id FROM publication_attempt WHERE scenario = 'complete_observed'),
    (SELECT executor_id FROM publication_attempt WHERE scenario = 'complete_observed'),
    '{"verifying":{"area_count":1}}'::jsonb),
  (SELECT release_id FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt WHERE scenario = 'complete_observed')),
  'complete_import accepts a validated required artifact'
);

SELECT ok(
  (SELECT import_run.status = 'completed' AND release.status = 'completed'
     FROM geo_genius.import_run
     JOIN geo_genius.release ON release.id = import_run.release_id
    WHERE import_run.id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'complete_observed')),
  'validated completion terminalizes both the import and release'
);

SELECT is(
  (SELECT stage_metrics FROM geo_genius.import_run
    WHERE id = (SELECT run_id FROM publication_attempt
      WHERE scenario = 'complete_observed')),
  '{"verifying":{"area_count":1}}'::jsonb,
  'complete_import merges the final verifying metrics atomically'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM geo_genius.import_run_lease
     WHERE run_id = (SELECT run_id FROM publication_attempt
       WHERE scenario = 'complete_observed')
  ),
  'validated completion removes the terminal run lease'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM geo_genius.publication
     WHERE release_id = (SELECT release_id FROM geo_genius.import_run
       WHERE id = (SELECT run_id FROM publication_attempt
         WHERE scenario = 'complete_observed'))
  ),
  'complete_import leaves the validated release unpublished'
);

SELECT finish();

ROLLBACK;
