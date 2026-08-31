BEGIN;

-- Every function in this schema that validates a required argument raises
-- SQLSTATE 22004 naming what was missing. Thirty-seven functions carry such a
-- guard, covering eighty-three arguments between them, and before this file
-- three of the thirty-seven had a test.
--
-- The table below is written out rather than discovered from the catalog. A
-- list derived by grepping for the guard would shrink to match whatever the
-- code currently does, so deleting a guard would drop the function from its
-- own test instead of failing it. The argument lists and types are derived,
-- because those belong to the signature rather than to the contract.
--
-- One row per guarded argument, not one per function. A single all-NULL call
-- per function would prove only that some NULL trips the guard: narrowing
-- `IF a IS NULL OR b IS NULL` to `IF a IS NULL` passes such a test, because
-- `a` is NULL in it too. Each row here passes NULL for its own argument and a
-- valid value for every other guarded one, so it fails if that argument stops
-- being checked.
--
-- The message is asserted as well as the SQLSTATE. Several of these guards
-- degrade to a backstop raising 22004 of its own once removed: without its
-- guard, analyze_release reaches format('%I', NULL), which raises "null values
-- cannot be formatted as an SQL identifier", also 22004. A code-only assertion
-- cannot tell the contract from the accident.
SELECT plan(84);

CREATE TEMP TABLE guarded_arg (
  fname text,
  identity_args text,
  argname text,
  message text NOT NULL
);

INSERT INTO guarded_arg (fname, identity_args, argname, message) VALUES
  ('advance_import', NULL, 'target_run_id', 'run id and next status are required'),
  ('advance_import', NULL, 'next_status', 'run id and next status are required'),
  ('analyze_release', NULL, 'target_release_id', 'release id is required'),
  ('ancestors_of', NULL, 'child_area_key', 'child area key is required'),
  ('areas_by_code', NULL, 'target_code_type', 'code type and code value are required'),
  ('areas_by_code', NULL, 'target_code_value', 'code type and code value are required'),
  ('areas_for_geometry', NULL, 'input_geom', 'geometry is required'),
  ('areas_for_point', NULL, 'lon', 'longitude and latitude are required'),
  ('areas_for_point', NULL, 'lat', 'longitude and latitude are required'),
  ('areas_near', NULL, 'lon', 'longitude, latitude, and radius are required'),
  ('areas_near', NULL, 'lat', 'longitude, latitude, and radius are required'),
  ('areas_near', NULL, 'radius_m', 'longitude, latitude, and radius are required'),
  ('attach_source_release', NULL, 'target_release_id', 'release id and source release id are required'),
  ('attach_source_release', NULL, 'target_source_release_id', 'release id and source release id are required'),
  ('begin_or_resume_import', NULL, 'target_release_id', 'release id, owner, and runner backend are required'),
  ('begin_or_resume_import', NULL, 'owner', 'release id, owner, and runner backend are required'),
  ('begin_or_resume_import', NULL, 'runner_backend', 'release id, owner, and runner backend are required'),
  ('children_of', NULL, 'parent_area_key', 'parent area key is required'),
  ('create_release_partitions', NULL, 'target_release_id', 'release id is required'),
  ('drop_release_partitions', NULL, 'target_release_id', 'release id is required'),
  ('fail_import', NULL, 'target_run_id', 'run id is required'),
  ('heartbeat_import', NULL, 'target_run_id', 'run id is required'),
  ('open_release', NULL, 'collection_key', 'collection, release key, and manifest are required'),
  ('open_release', NULL, 'release_key', 'collection, release key, and manifest are required'),
  ('open_release', NULL, 'manifest', 'collection, release key, and manifest are required'),
  ('published_release', NULL, 'collection_key', 'collection key is required'),
  ('put_area_code', NULL, 'target_area_key', 'area key, code type, and code value are required'),
  ('put_area_code', NULL, 'code_type', 'area key, code type, and code value are required'),
  ('put_area_code', NULL, 'code_value', 'area key, code type, and code value are required'),
  ('put_area_in_release', NULL, 'target_release_id', 'release id and area key are required'),
  ('put_area_in_release', NULL, 'target_area_key', 'release id and area key are required'),
  ('put_area_name', NULL, 'target_area_key', 'area key, name, and kind are required'),
  ('put_area_name', NULL, 'name', 'area key, name, and kind are required'),
  ('put_area_name', NULL, 'kind', 'area key, name, and kind are required'),
  ('put_artifact', NULL, 'target_source_release_id', 'source release, logical name, format, expected sha256, and expected bytes are required'),
  ('put_artifact', NULL, 'logical_name', 'source release, logical name, format, expected sha256, and expected bytes are required'),
  ('put_artifact', NULL, 'format', 'source release, logical name, format, expected sha256, and expected bytes are required'),
  ('put_artifact', NULL, 'expected_sha256', 'source release, logical name, format, expected sha256, and expected bytes are required'),
  ('put_artifact', NULL, 'expected_bytes', 'source release, logical name, format, expected sha256, and expected bytes are required'),
  ('put_boundary', NULL, 'target_release_id', 'release, area key, source release, and geometry are required'),
  ('put_boundary', NULL, 'target_area_key', 'release, area key, source release, and geometry are required'),
  ('put_boundary', NULL, 'target_source_release_id', 'release, area key, source release, and geometry are required'),
  ('put_boundary', NULL, 'input_geom', 'release, area key, source release, and geometry are required'),
  ('put_relation', NULL, 'target_release_id', 'release, parent area key, child area key, and relation type are required'),
  ('put_relation', NULL, 'parent_area_key', 'release, parent area key, child area key, and relation type are required'),
  ('put_relation', NULL, 'child_area_key', 'release, parent area key, child area key, and relation type are required'),
  ('put_relation', NULL, 'relation_type', 'release, parent area key, child area key, and relation type are required'),
  ('rebuild_relations', NULL, 'target_release_id', 'release id is required'),
  ('record_artifact_observation', NULL, 'target_artifact_id', 'artifact id, observed sha256, and observed bytes are required'),
  ('record_artifact_observation', NULL, 'observed_sha256', 'artifact id, observed sha256, and observed bytes are required'),
  ('record_artifact_observation', NULL, 'observed_bytes', 'artifact id, observed sha256, and observed bytes are required'),
  ('related_areas', NULL, 'target_area_key', 'area key is required'),
  ('release_at', NULL, 'collection_key', 'collection key and as_of are required'),
  ('release_at', NULL, 'as_of', 'collection key and as_of are required'),
  ('retire_releases', NULL, 'collection_key', 'collection key and keep are required'),
  ('retire_releases', NULL, 'keep', 'collection key and keep are required'),
  ('rollback_publication', NULL, 'collection_key', 'collection key is required'),
  ('search_areas', NULL, 'query', 'query is required'),
  ('staging_table_name', NULL, 'target_run_id', 'run id is required'),
  ('upsert_area', NULL, 'collection_key', 'collection, authority, area type, and code are required'),
  ('upsert_area', NULL, 'authority_key', 'collection, authority, area type, and code are required'),
  ('upsert_area', NULL, 'area_type_key', 'collection, authority, area type, and code are required'),
  ('upsert_area', NULL, 'code', 'collection, authority, area type, and code are required'),
  ('upsert_area_type', 'collection_key text, key text, rank integer', 'collection_key', 'collection, key, and rank are required'),
  ('upsert_area_type', 'collection_key text, key text, rank integer', 'key', 'collection, key, and rank are required'),
  ('upsert_area_type', 'collection_key text, key text, rank integer', 'rank', 'collection, key, and rank are required'),
  ('upsert_area_type', 'collection_key text, key text, rank integer, requires_geometry boolean', 'collection_key', 'collection, key, rank, and requires_geometry are required'),
  ('upsert_area_type', 'collection_key text, key text, rank integer, requires_geometry boolean', 'key', 'collection, key, rank, and requires_geometry are required'),
  ('upsert_area_type', 'collection_key text, key text, rank integer, requires_geometry boolean', 'rank', 'collection, key, rank, and requires_geometry are required'),
  ('upsert_area_type', 'collection_key text, key text, rank integer, requires_geometry boolean', 'requires_geometry', 'collection, key, rank, and requires_geometry are required'),
  ('upsert_authority', NULL, 'collection_key', 'collection, key, and name are required'),
  ('upsert_authority', NULL, 'key', 'collection, key, and name are required'),
  ('upsert_authority', NULL, 'name', 'collection, key, and name are required'),
  ('upsert_collection', NULL, 'key', 'key and name are required'),
  ('upsert_collection', NULL, 'name', 'key and name are required'),
  ('upsert_source', NULL, 'collection_key', 'collection, source key, provider, and license are required'),
  ('upsert_source', NULL, 'source_key', 'collection, source key, provider, and license are required'),
  ('upsert_source', NULL, 'provider', 'collection, source key, provider, and license are required'),
  ('upsert_source', NULL, 'license', 'collection, source key, provider, and license are required'),
  ('upsert_source_release', NULL, 'collection_key', 'collection, source key, and release key are required'),
  ('upsert_source_release', NULL, 'source_key', 'collection, source key, and release key are required'),
  ('upsert_source_release', NULL, 'release_key', 'collection, source key, and release key are required'),
  ('verify_release', NULL, 'target_release_id', 'release id is required');

CREATE TEMP TABLE arg_call AS
SELECT target.fname,
       target.argname,
       target.message,
       format(
         'SELECT geo_genius.%I(%s)',
         target.fname,
         (SELECT string_agg(
                   CASE
                     WHEN argument.name = target.argname
                       THEN 'NULL::' || format_type(argument.oid, NULL)
                     WHEN EXISTS (
                       SELECT 1 FROM guarded_arg AS sibling
                        WHERE sibling.fname = target.fname
                          AND sibling.argname = argument.name
                     )
                       THEN CASE format_type(argument.oid, NULL)
                              WHEN 'text' THEN '''x'''
                              WHEN 'uuid' THEN '''00000000-0000-0000-0000-000000000001''::uuid'
                              WHEN 'jsonb' THEN '''{}''::jsonb'
                              WHEN 'integer' THEN '1'
                              WHEN 'bigint' THEN '1'
                              WHEN 'boolean' THEN 'true'
                              WHEN 'double precision' THEN '1.0'
                              WHEN 'timestamp with time zone' THEN 'now()'
                              WHEN 'geometry' THEN 'ST_GeomFromText(''POINT(0 0)'', 4326)'
                            END
                     ELSE 'NULL::' || format_type(argument.oid, NULL)
                   END,
                   ', ' ORDER BY argument.position
                 )
            FROM unnest(proc.proargtypes) WITH ORDINALITY AS types(oid, position)
            JOIN unnest(proc.proargnames) WITH ORDINALITY AS argnames(name, position)
              ON argnames.position = types.position,
                 LATERAL (SELECT types.oid, types.position, argnames.name) AS argument
         )
       ) AS statement
  FROM guarded_arg AS target
  JOIN pg_catalog.pg_proc AS proc
    ON proc.proname = target.fname
   AND (target.identity_args IS NULL OR pg_get_function_identity_arguments(proc.oid) = target.identity_args)
  JOIN pg_catalog.pg_namespace AS schema
    ON schema.oid = proc.pronamespace
 WHERE schema.nspname = 'geo_genius';

-- A name or argument that no longer resolves would drop out of the run below
-- and leave the plan short, which reads as a plan failure rather than as the
-- missing coverage it is. This says it directly, and a NULL statement here
-- would mean an argument type with no valid value above.
SELECT is(
  (SELECT count(*)::int FROM arg_call WHERE statement IS NOT NULL),
  83,
  'every guarded argument named above resolves to a callable signature'
);

SELECT throws_ok(
  arg_call.statement,
  '22004',
  arg_call.message,
  arg_call.fname || '.' || arg_call.argname || ' is checked, with its own message'
)
  FROM arg_call
 ORDER BY arg_call.fname, arg_call.argname;

SELECT finish();

ROLLBACK;
