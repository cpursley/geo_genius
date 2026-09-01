defmodule GeoGenius.SchemaContract do
  @moduledoc false

  alias EctoEvolver.Adapters.Postgres

  @capabilities [
    "artifact_observation_publication_gate",
    "atomic_failed_candidate_retry",
    "atomic_import_completion",
    "atomic_import_publication",
    "boundary_batches",
    "boundary_canonical_repair_once",
    "boundary_collection_provenance",
    "boundary_publication_serialization",
    "exact_attempt_artifact_snapshots",
    "exact_attempt_manifest_snapshots",
    "executor_fenced_staging_cleanup",
    "failed_candidate_requires_explicit_retry",
    "idempotent_executor_reclaim",
    "immutable_failure_evidence",
    "publication_constraint_triggers",
    "release_retention_preserves_history",
    "release_scoped_catalog_declarations",
    "run_fenced_ingestion",
    "single_executor_import_claim",
    "strict_import_phase_transitions",
    "type_scoped_geometry_requirements"
  ]

  @signatures Enum.sort([
                "advance_import(uuid,uuid,text,jsonb)->void",
                "analyze_import(uuid,uuid)->void",
                "analyze_release(uuid)->void",
                "assert_import_write(uuid,uuid,text[])->uuid",
                "assert_required_artifact_observations(uuid)->void",
                "assert_release_mutable(uuid)->void",
                "attach_artifact(uuid,uuid)->void",
                "attach_source_release(uuid,uuid)->void",
                "claim_import_execution(uuid,uuid)->text",
                "complete_import(uuid,uuid,jsonb)->uuid",
                "create_release_partitions(uuid)->void",
                "create_staging(uuid,uuid)->text",
                "drop_release_partitions(uuid)->void",
                "drop_staging(uuid)->void",
                "drop_staging(uuid,uuid)->void",
                "fail_import(uuid,uuid,jsonb)->void",
                "heartbeat_import(uuid,uuid,jsonb)->void",
                "insert_staging_many(uuid,uuid,text[],jsonb[],geometry[])->bigint",
                "open_release(text,text,jsonb,date)->uuid",
                "partition_lock_key()->bigint",
                "prepare_import(jsonb,jsonb)->record",
                "publication_lock_key(text)->bigint",
                "publication_release_is_publishable()->trigger",
                "publish_import(uuid,uuid)->uuid",
                "publish_release(uuid)->uuid",
                "published_release(text)->uuid",
                "put_area_code(uuid,uuid,text,text,text)->uuid",
                "put_area_code_many(uuid,uuid,text[],text[],text[])->uuid[]",
                "put_area_in_release(uuid,uuid,text,geography,jsonb)->void",
                "put_area_in_release_many(uuid,uuid,text[],geography[],jsonb[])->void",
                "put_area_name(uuid,uuid,text,text,text,text)->uuid",
                "put_area_name_many(uuid,uuid,text[],text[],text[],text[])->uuid[]",
                "put_artifact(uuid,text,text,boolean,text,text,bigint,jsonb)->uuid",
                "put_boundaries(uuid,uuid,text[],uuid[],geometry[],integer[],jsonb[])->void",
                "put_boundary(uuid,uuid,text,uuid,geometry,double precision)->void",
                "put_relation(uuid,uuid,text,text,text)->void",
                "put_relation_many(uuid,uuid,text[],text[],text[])->void",
                "rebuild_relations(uuid,uuid)->bigint",
                "record_artifact_observation(uuid,uuid,uuid,text,bigint)->void",
                "relation_lock_key(uuid)->bigint",
                "release_at(text,timestamp with time zone)->uuid",
                "release_lock_key(text,text)->bigint",
                "retire_releases(text,integer)->integer",
                "retry_failed(uuid,jsonb,jsonb)->record",
                "rollback_publication(text)->uuid",
                "upsert_area(text,text,text,text)->uuid",
                "upsert_area_many(text,text[],text[],text[])->uuid[]",
                "upsert_area_many(uuid,uuid,text[],text[],text[])->uuid[]",
                "upsert_area_type(text,text,integer)->uuid",
                "upsert_area_type(text,text,integer,boolean)->uuid",
                "upsert_authority(text,text,text)->uuid",
                "upsert_collection(text,text,text,boolean)->uuid",
                "upsert_source(text,text,text,text)->uuid",
                "upsert_source_release(text,text,text,date,jsonb)->uuid",
                "verify_import(uuid,uuid)->jsonb",
                "verify_release(uuid)->jsonb"
              ])

  @relation_metadata Enum.sort([
                       "area_type:key_only_identity",
                       "artifact:immutable_semantic_definition",
                       "authority:key_only_identity",
                       "boundary:partitioned_release_geometry",
                       "boundary_part:partitioned_release_geometry_parts",
                       "collection:key_only_identity",
                       "import_run:manifest_snapshot:not_null",
                       "import_run_artifact:attempt_artifact_snapshot",
                       "import_run_lease:single_executor_claim",
                       "import_run_status:executor_and_manifest",
                       "published_area_codes:release_attachment_projection",
                       "published_area_names:release_attachment_projection",
                       "published_area_relations:release_scoped_type_order",
                       "published_areas:release_scoped_declarations",
                       "published_boundaries:release_scoped_projection",
                       "publication:current_and_previous_release_pointer",
                       "publication_event:immutable_publication_history",
                       "relation:partitioned_release_hierarchy",
                       "release:lifecycle_and_retention",
                       "release_area:partitioned_release_membership",
                       "release_area_code:release_attachment",
                       "release_area_codes:release_attachment_projection",
                       "release_area_name:release_attachment",
                       "release_area_names:release_attachment_projection",
                       "release_area_type:release_declaration",
                       "release_areas:release_scoped_declarations",
                       "release_artifact:release_attachment",
                       "release_artifacts:latest_completed_attempt_observations",
                       "release_authority:release_declaration",
                       "release_collection_policy:release_declaration",
                       "release_relations:release_scoped_type_order",
                       "release_source:release_attachment",
                       "run_artifacts:exact_attempt_selection",
                       "source:immutable_semantic_definition",
                       "source_release:immutable_semantic_definition"
                     ])

  @trigger_metadata [
    "publication_completed_release_check:publication_release_constraint",
    "release_publication_check:release_mutation_constraint"
  ]

  @function_names @signatures
                  |> Enum.map(&(&1 |> String.split("(", parts: 2) |> hd()))
                  |> Enum.uniq()

  @relation_names ~w(
    area_type artifact authority boundary boundary_part collection import_run import_run_artifact
    import_run_lease import_run_status publication publication_event published_area_codes
    published_area_names published_area_relations published_areas published_boundaries relation
    release release_area release_area_code release_area_codes release_area_name release_area_names
    release_area_type release_areas release_artifact release_artifacts release_authority
    release_collection_policy release_relations release_source run_artifacts source source_release
  )

  @trigger_names ~w(publication_completed_release_check release_publication_check)

  @canonical_manifest Enum.map_join(
                        ["schema_version=1"] ++
                          Enum.map(@capabilities, &"capability=#{&1}") ++
                          Enum.map(@signatures, &"signature=#{&1}") ++
                          Enum.map(@relation_metadata, &"relation_metadata=#{&1}") ++
                          Enum.map(@trigger_metadata, &"trigger_metadata=#{&1}"),
                        "\n",
                        & &1
                      ) <> "\n"

  @revision "sha256:" <>
              (:crypto.hash(:sha256, @canonical_manifest) |> Base.encode16(case: :lower))

  @target_fingerprints [
    {"advance_import(target_run_id uuid, target_executor_id uuid, next_status text, metrics_patch jsonb)->void",
     "80cb2240964f4685f5b62974de001f94"},
    {"analyze_import(target_run_id uuid, target_executor_id uuid)->void",
     "851e04467447509aeaaa22c9594bb8ce"},
    {"analyze_release(target_release_id uuid)->void", "2c9f4641751cac962f36c03b0be5c7e8"},
    {"assert_import_write(target_run_id uuid, target_executor_id uuid, permitted_statuses text[])->uuid",
     "e9da32fcd71b8b88064b345c1c7e4129"},
    {"assert_release_mutable(target_release_id uuid)->void", "30efa0a8dd343d1ea292632431af2a5f"},
    {"assert_required_artifact_observations(target_run_id uuid)->void",
     "101090ce0cb3911baf96f20959499a6f"},
    {"attach_artifact(target_release_id uuid, target_artifact_id uuid)->void",
     "3d023dd982f57afe26b3e212ef3cca8c"},
    {"attach_source_release(target_release_id uuid, target_source_release_id uuid)->void",
     "08c48a51706c19b1036e43afc2b86127"},
    {"claim_import_execution(target_run_id uuid, target_executor_id uuid)->text",
     "0207867ecc8f984f57ef0fb01c4146d2"},
    {"complete_import(target_run_id uuid, target_executor_id uuid, metrics_patch jsonb)->uuid",
     "2cfb22e4fea7e92051bc6fdec5a07297"},
    {"create_release_partitions(target_release_id uuid)->void",
     "24f25a6b0bec08469f005efe8f28ada1"},
    {"create_staging(target_run_id uuid, target_executor_id uuid)->text",
     "5c2f520a1084bff475a46ea95da5ba94"},
    {"drop_release_partitions(target_release_id uuid)->void", "d7b3538fa2aaffbcc8a47d3ac0752c13"},
    {"drop_staging(target_run_id uuid)->void", "911e03438af5ba551ae96abc3676da3d"},
    {"drop_staging(target_run_id uuid, target_executor_id uuid)->void",
     "50f18e698bb5df19c46870a5d80c1486"},
    {"fail_import(target_run_id uuid, target_executor_id uuid, error_detail jsonb)->void",
     "b367112348007df95dd90beaa853cdf5"},
    {"heartbeat_import(target_run_id uuid, target_executor_id uuid, progress_patch jsonb)->void",
     "55261a725b17fa896d8d26badbc5cf1b"},
    {"insert_staging_many(target_run_id uuid, target_executor_id uuid, artifacts text[], payloads jsonb[], geometries geometry[])->bigint",
     "f8124cfbd715f0ed97cb0dc1e3db6132"},
    {"open_release(collection_key text, release_key text, manifest jsonb, source_date date)->uuid",
     "f1cfe503d329bb57242b7fda3c7306e0"},
    {"partition_lock_key()->bigint", "addd2ece2db315d2edda5537c02cff60"},
    {"prepare_import(manifest jsonb, claim jsonb)->TABLE(decision text, reason text, release_id uuid, run_id uuid, attempt integer)",
     "2cb1d42efb75bfd910603b2498bf72f8"},
    {"publication_lock_key(collection_key text)->bigint", "392eee6b9d7a5586d6ecf00a806dd0d9"},
    {"publication_release_is_publishable()->trigger", "d2fe7bdf7996ac35515c0e169579701c"},
    {"publish_import(target_run_id uuid, target_executor_id uuid)->uuid",
     "3d5de711782a51e1a02a5d68d4eadf13"},
    {"publish_release(target_release_id uuid)->uuid", "44ba7b8c7b6e4d60615bb594e6ca1169"},
    {"published_release(collection_key text)->uuid", "d6afec9a0f68da377d837143963fe868"},
    {"put_area_code(target_run_id uuid, target_executor_id uuid, target_area_key text, code_type text, code_value text)->uuid",
     "15dd80fc5505ec791ff98a6ea4ff680c"},
    {"put_area_code_many(target_run_id uuid, target_executor_id uuid, target_area_keys text[], code_types text[], code_values text[])->uuid[]",
     "831b9b7874f18178a9150f0331129b55"},
    {"put_area_in_release(target_run_id uuid, target_executor_id uuid, target_area_key text, centroid geography, data jsonb)->void",
     "3a255ea5000e9f47855ce3dfbc852459"},
    {"put_area_in_release_many(target_run_id uuid, target_executor_id uuid, target_area_keys text[], centroids geography[], data jsonb[])->void",
     "fb976cca8c34682f0510f6a0808b5461"},
    {"put_area_name(target_run_id uuid, target_executor_id uuid, target_area_key text, name text, kind text, locale text)->uuid",
     "c8b4965b4487a3e77375209cdccca7e5"},
    {"put_area_name_many(target_run_id uuid, target_executor_id uuid, target_area_keys text[], names text[], kinds text[], locales text[])->uuid[]",
     "d5fb4404f5b04b4305b8538b2b0eae5f"},
    {"put_artifact(target_source_release_id uuid, logical_name text, url text, operator_supplied boolean, format text, expected_sha256 text, expected_bytes bigint, metadata jsonb)->uuid",
     "bbd6014ce7ddb008061eb5868634f841"},
    {"put_boundaries(target_run_id uuid, target_executor_id uuid, target_area_keys text[], target_source_release_ids uuid[], input_geometries geometry[], display_tiers integer[], source_properties_values jsonb[])->void",
     "735d26b4728d9715a93b7f967ec74ec2"},
    {"put_boundary(target_run_id uuid, target_executor_id uuid, target_area_key text, target_source_release_id uuid, input_geom geometry, simplify_tolerance double precision)->void",
     "a6c232fe775c26d234160d721cba16f9"},
    {"put_relation(target_run_id uuid, target_executor_id uuid, parent_area_key text, child_area_key text, relation_type text)->void",
     "66a920480e40d882121e16ff27e76a7c"},
    {"put_relation_many(target_run_id uuid, target_executor_id uuid, parent_area_keys text[], child_area_keys text[], relation_types text[])->void",
     "2a3898761a2f7145e9a2506c007cf6ac"},
    {"rebuild_relations(target_run_id uuid, target_executor_id uuid)->bigint",
     "c9d94d34027489ca5c50994a9ebca879"},
    {"record_artifact_observation(target_run_id uuid, target_executor_id uuid, target_artifact_id uuid, observed_sha256 text, observed_bytes bigint)->void",
     "f8273d486be7d3db563493d59dff3bf6"},
    {"relation_lock_key(target_release_id uuid)->bigint", "8561f299944a106ec081be69c495570d"},
    {"release_at(collection_key text, as_of timestamp with time zone)->uuid",
     "e3cb8719e57e876ff77e429aec980caf"},
    {"release_lock_key(collection_key text, release_key text)->bigint",
     "e5e1c4d24c708a52ed9e43987226e0e2"},
    {"retire_releases(collection_key text, keep integer)->integer",
     "002d17d8b6a3ff6b7460e31044713c64"},
    {"retry_failed(failed_run_id uuid, manifest jsonb, claim jsonb)->TABLE(decision text, reason text, release_id uuid, run_id uuid, attempt integer)",
     "d18c0058d2a6514e83fe2dd66bef22df"},
    {"rollback_publication(collection_key text)->uuid", "0599305bab565779039980bf6b30ad2b"},
    {"upsert_area(collection_key text, authority_key text, area_type_key text, code text)->uuid",
     "2e5e1c5aa3a62c5fd06ca1294c57ea7e"},
    {"upsert_area_many(collection_key text, authority_keys text[], area_type_keys text[], codes text[])->uuid[]",
     "88403b541657e05e170a5349ce56a5f1"},
    {"upsert_area_many(target_run_id uuid, target_executor_id uuid, authority_keys text[], area_type_keys text[], codes text[])->uuid[]",
     "e7ef575c0f31f0a5b3a283ab70ae7935"},
    {"upsert_area_type(collection_key text, key text, rank integer)->uuid",
     "80f054a72417218c3fe5ecf7dc44a9d9"},
    {"upsert_area_type(collection_key text, key text, rank integer, requires_geometry boolean)->uuid",
     "d8c70dbd9b2cf9ed0f2a2f557026495f"},
    {"upsert_authority(collection_key text, key text, name text)->uuid",
     "f1a24f082cf373fb0a15c37954664d9a"},
    {"upsert_collection(key text, name text, description text, requires_geometry boolean)->uuid",
     "ed49fc6797705bf2ed7ce5d5e720ef68"},
    {"upsert_source(collection_key text, source_key text, provider text, license text)->uuid",
     "85df6ec430667b21abda7ddbb4594c56"},
    {"upsert_source_release(collection_key text, source_key text, release_key text, source_date date, metadata jsonb)->uuid",
     "580fc17c97b169988e25d11cc34c47b9"},
    {"verify_import(target_run_id uuid, target_executor_id uuid)->jsonb",
     "7fde81b99bdf8cb47cbda832ca9e88eb"},
    {"verify_release(target_release_id uuid)->jsonb", "ecf8368c03f73763544538dbfff1060c"}
  ]

  @target_relation_metadata [
    {"area_type", "3b1193f1b548bff868a21a9549c6bfe1"},
    {"artifact", "c8cf0a3bc86c18a41efe2afaa26e0d40"},
    {"authority", "44c8f6560edeb340642b82d43ff968f5"},
    {"boundary", "3fa7365b793d810615dc262b1b5a6b14"},
    {"boundary_part", "ee91eae7bcbd89d68a41cfd5fdf1e370"},
    {"collection", "f927a9ec75cdd4a1d3f9f114e1456f10"},
    {"import_run", "417f40cf3f56561f3ff8b668a5543ea9"},
    {"import_run_artifact", "661682e3951c86039a0812b1483cfa17"},
    {"import_run_lease", "c040bd84217d122001c50a76b1da9455"},
    {"import_run_status", "5b8ff5fa5d8767d06c9d10fc97816d34"},
    {"publication", "98f1f40e99f5ac3b44cc31dcbd80ed94"},
    {"publication_event", "0a1a65ab884e15e07e00e993c6aa1ca0"},
    {"published_area_codes", "8a13a2160acd74a5d7bc94aef31d0aa8"},
    {"published_area_names", "431d5ad8676e82dbafde10b7e4f861b0"},
    {"published_area_relations", "b612d03d6765a5cc445f75995f017e2b"},
    {"published_areas", "f4231a0987c3574d5ba27c6a2fcf9597"},
    {"published_boundaries", "ff5b60e6e793e1ebafe7e4d2cb564af8"},
    {"relation", "9130cea7e62c07a0f9739db66d18ea85"},
    {"release", "26777e0a31df5703c785a61d2e080bd1"},
    {"release_area", "f7b76093e731c9ca819c8347b156f083"},
    {"release_area_code", "585935b249724aa5275ff043d51a7f6f"},
    {"release_area_codes", "5604ed8e4daf0c5be1cd24e0fc8cabc6"},
    {"release_area_name", "fa43c1545613b24edbd9d990281af8e4"},
    {"release_area_names", "108fe042ec6c400ff5c064df9d25157b"},
    {"release_area_type", "8954c9e257236d7625f69bd285663c12"},
    {"release_areas", "6ff39688d78132f41926150b6a6dd5e7"},
    {"release_artifact", "fa947c8d821ed5c7ab0b8ccfa68f179d"},
    {"release_artifacts", "31ac963ef10a7cca2f8e9affca56256e"},
    {"release_authority", "026948f7943a75281ed2e6dd8bb0f420"},
    {"release_collection_policy", "b3b2ad522068dd58d8acdc6769693da9"},
    {"release_relations", "3aae7c168354fce38440285afbe3dd94"},
    {"release_source", "4bb996583a1809b8e98cea3e8079e970"},
    {"run_artifacts", "b3a27fe325bee222da59ca3580cfecf7"},
    {"source", "1b0c30220a45ee1d6390038e8505af91"},
    {"source_release", "ff8f046472958b68a694533c353eca99"}
  ]

  @target_trigger_metadata [
    {"publication_completed_release_check", "790ac3b93409294c13b8337ea3115b5b"},
    {"release_publication_check", "ee3ac9e9925e68be3465d25b58aa7f3c"}
  ]

  @doc false
  def manifest do
    %{
      schema_version: 1,
      capabilities: @capabilities,
      signatures: @signatures,
      relation_metadata: @relation_metadata,
      trigger_metadata: @trigger_metadata
    }
  end

  @doc false
  def canonical_manifest, do: @canonical_manifest

  @doc false
  def revision, do: @revision

  @doc false
  def capabilities, do: @capabilities

  @doc false
  def target_fingerprints, do: @target_fingerprints

  @doc false
  def target_relation_metadata, do: @target_relation_metadata

  @doc false
  def target_trigger_metadata, do: @target_trigger_metadata

  @doc false
  def status(repo, prefix) do
    prefix = validate_prefix!(prefix)
    version = GeoGenius.Migration.installed_version(repo, prefix)

    if version == 0 do
      status(:not_installed, version, nil, [], [], "install GeoGenius schema v1")
    else
      marker = marker(repo, prefix)
      fingerprints = fingerprints(repo, prefix)
      relation_metadata = relation_metadata(repo, prefix)
      trigger_metadata = trigger_metadata(repo, prefix)
      signatures = signatures(repo, prefix)

      classify(
        version,
        marker,
        fingerprints,
        relation_metadata,
        trigger_metadata,
        signatures,
        prefix
      )
    end
  end

  @doc false
  def validate_prefix!(prefix) when is_binary(prefix) do
    cond do
      prefix in ~w(public information_schema pg_catalog pg_toast pg_temp) ->
        raise ArgumentError, "PostgreSQL prefix #{inspect(prefix)} is reserved"

      String.starts_with?(prefix, "pg_") ->
        raise ArgumentError, "PostgreSQL prefix #{inspect(prefix)} is reserved"

      prefix == "" or byte_size(prefix) > 63 or not String.valid?(prefix) or
          String.contains?(prefix, "\0") ->
        raise ArgumentError, "invalid PostgreSQL prefix"

      true ->
        prefix
    end
  end

  def validate_prefix!(_prefix), do: raise(ArgumentError, "PostgreSQL prefix must be a string")

  defp classify(
         1,
         %{schema_version: 1, revision: @revision, capabilities: @capabilities},
         @target_fingerprints,
         @target_relation_metadata,
         @target_trigger_metadata,
         @signatures,
         _prefix
       ) do
    status(:compatible, 1, @revision, @capabilities, [], nil)
  end

  defp classify(
         version,
         marker,
         _fingerprints,
         _relation_metadata,
         _trigger_metadata,
         signatures,
         prefix
       ) do
    drift_status(version, marker, signatures, prefix)
  end

  defp drift_status(version, marker, signatures, prefix) do
    installed_revision = if match?(%{revision: _}, marker), do: marker.revision, else: nil
    missing = @signatures -- signatures

    status(
      :drifted,
      version,
      installed_revision,
      if(match?(%{capabilities: _}, marker), do: marker.capabilities, else: []),
      missing,
      "schema #{prefix} does not match the current pre-release GeoGenius contract; " <>
        "regenerate the host's pinned GeoGenius migration and recreate this non-production schema"
    )
  end

  defp status(kind, version, installed_revision, capabilities, missing, remedy) do
    %{
      status: kind,
      compatible?: kind == :compatible,
      schema_version: version,
      installed_revision: installed_revision,
      expected_revision: @revision,
      capabilities: capabilities,
      required_capabilities: @capabilities,
      missing: missing,
      remedy: remedy
    }
  end

  defp marker(repo, prefix) do
    case repo.query!(
           """
           SELECT c.relkind
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = 'geo_genius_contract'
           """,
           [prefix],
           log: false
         ).rows do
      [] ->
        nil

      [["v"]] ->
        read_marker(repo, prefix)

      [[kind]] ->
        %{malformed: {:relation_kind, kind}}
    end
  end

  defp read_marker(repo, prefix) do
    expected_columns = [
      ["schema_version", "integer"],
      ["contract_revision", "text"],
      ["capabilities", "text[]"]
    ]

    %{rows: columns} =
      repo.query!(
        """
        SELECT a.attname, format_type(a.atttypid, a.atttypmod)
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $1
           AND c.relname = 'geo_genius_contract'
           AND c.relkind = 'v'
           AND a.attnum > 0
           AND NOT a.attisdropped
         ORDER BY a.attnum
        """,
        [prefix],
        log: false
      )

    if columns == expected_columns do
      escaped = Postgres.escape_identifier(prefix)

      case repo.query!(
             "SELECT schema_version, contract_revision, capabilities FROM #{escaped}.geo_genius_contract",
             [],
             log: false
           ).rows do
        [[schema_version, revision, capabilities]]
        when is_integer(schema_version) and is_binary(revision) and is_list(capabilities) ->
          %{schema_version: schema_version, revision: revision, capabilities: capabilities}

        rows ->
          %{malformed: {:row_count, length(rows)}}
      end
    else
      %{malformed: {:columns, columns}}
    end
  end

  defp fingerprints(repo, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT
          p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')->' ||
            pg_get_function_result(p.oid) AS identity,
          md5(
            p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')->' ||
              pg_get_function_result(p.oid) ||
            '|arguments=' || pg_get_function_arguments(p.oid) ||
            '|language=' || l.lanname ||
            '|volatility=' || p.provolatile::text ||
            '|security_definer=' || p.prosecdef::text ||
            '|strict=' || p.proisstrict::text ||
            '|parallel=' || p.proparallel::text ||
            '|leakproof=' || p.proleakproof::text ||
            '|config=' || replace(
              replace(
                coalesce(array_to_string(p.proconfig, E'\\x1f'), ''),
                '"' || replace(n.nspname, '"', '""') || '"',
                '$SCHEMA$'
              ),
              format('%I', n.nspname),
              '$SCHEMA$'
            ) ||
            '|body=' || replace(
              replace(
                replace(
                  replace(p.prosrc, format('%I.', n.nspname), '$SCHEMA$.'),
                  '"' || replace(n.nspname, '"', '""') || '".',
                  '$SCHEMA$.'
                ),
                '"' || replace(n.nspname, '"', '""') || '":',
                '$SCHEMA$:'
              ),
              n.nspname || ':',
              '$SCHEMA$:'
            )
          ) AS fingerprint
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          JOIN pg_language l ON l.oid = p.prolang
         WHERE n.nspname = $1
           AND p.proname = ANY($2)
         ORDER BY identity
        """,
        [prefix, @function_names],
        log: false
      )

    Enum.map(rows, fn [identity, fingerprint] -> {identity, fingerprint} end)
  end

  defp relation_metadata(repo, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        WITH relation_contract AS (
          SELECT c.oid, c.relname, c.relkind::text AS relkind, n.nspname
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = $1
             AND c.relname = ANY($2)
        ),
        column_contract AS (
          SELECT relation_contract.oid,
                 string_agg(
                   a.attname || ':' || format_type(a.atttypid, a.atttypmod) ||
                     ':not_null=' || a.attnotnull::text ||
                     ':identity=' || a.attidentity::text ||
                     ':generated=' || a.attgenerated::text ||
                     ':default=' || coalesce(
                       replace(
                         replace(
                           pg_get_expr(d.adbin, d.adrelid),
                           format('%I.', relation_contract.nspname),
                           '$SCHEMA$.'
                         ),
                         '"' || replace(relation_contract.nspname, '"', '""') || '".',
                         '$SCHEMA$.'
                       ),
                       ''
                     ),
                   E'\\x1f' ORDER BY a.attnum
                 ) AS definition
            FROM relation_contract
          LEFT JOIN pg_attribute a
            ON a.attrelid = relation_contract.oid
           AND a.attnum > 0
           AND NOT a.attisdropped
          LEFT JOIN pg_attrdef d
            ON d.adrelid = a.attrelid
           AND d.adnum = a.attnum
           GROUP BY relation_contract.oid
        ),
        constraint_contract AS (
          SELECT relation_contract.oid,
                 string_agg(
                   constraint_row.conname || ':' || constraint_row.contype::text || ':' ||
                     replace(
                       replace(
                         pg_get_constraintdef(constraint_row.oid, true),
                         format('%I.', relation_contract.nspname),
                         '$SCHEMA$.'
                       ),
                       '"' || replace(relation_contract.nspname, '"', '""') || '".',
                       '$SCHEMA$.'
                     ),
                   E'\\x1f' ORDER BY constraint_row.conname
                 ) AS definition
            FROM relation_contract
            LEFT JOIN pg_constraint constraint_row
              ON constraint_row.conrelid = relation_contract.oid
           GROUP BY relation_contract.oid
        ),
        index_contract AS (
          SELECT relation_contract.oid,
                 string_agg(
                   replace(
                     replace(
                       pg_get_indexdef(index_row.indexrelid),
                       format('%I.', relation_contract.nspname),
                       '$SCHEMA$.'
                     ),
                     '"' || replace(relation_contract.nspname, '"', '""') || '".',
                     '$SCHEMA$.'
                   ),
                   E'\\x1f' ORDER BY index_class.relname
                 ) AS definition
            FROM relation_contract
            LEFT JOIN pg_index index_row ON index_row.indrelid = relation_contract.oid
            LEFT JOIN pg_class index_class ON index_class.oid = index_row.indexrelid
           GROUP BY relation_contract.oid
        )
        SELECT relation_contract.relname,
               md5(
                 relation_contract.relname || '|kind=' || relation_contract.relkind ||
                 '|columns=' || coalesce(column_contract.definition, '') ||
                 '|constraints=' || coalesce(constraint_contract.definition, '') ||
                 '|indexes=' || coalesce(index_contract.definition, '') ||
                 '|partition_key=' || coalesce(
                   replace(
                     replace(
                       pg_get_partkeydef(relation_contract.oid),
                       format('%I.', relation_contract.nspname),
                       '$SCHEMA$.'
                     ),
                     '"' || replace(relation_contract.nspname, '"', '""') || '".',
                     '$SCHEMA$.'
                   ),
                   ''
                 ) ||
                 '|view=' || CASE WHEN relation_contract.relkind IN ('v', 'm')
                   THEN replace(
                     replace(
                       pg_get_viewdef(relation_contract.oid, true),
                       format('%I.', relation_contract.nspname),
                       '$SCHEMA$.'
                     ),
                     '"' || replace(relation_contract.nspname, '"', '""') || '".',
                     '$SCHEMA$.'
                   )
                   ELSE ''
                 END
               ) AS fingerprint
          FROM relation_contract
          JOIN column_contract USING (oid)
          JOIN constraint_contract USING (oid)
          JOIN index_contract USING (oid)
         ORDER BY relation_contract.relname
        """,
        [prefix, @relation_names],
        log: false
      )

    Enum.map(rows, fn [identity, fingerprint] -> {identity, fingerprint} end)
  end

  defp trigger_metadata(repo, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        WITH trigger_contract AS (
          SELECT trigger_row.tgname,
                 target.relname AS relation_name,
                 trigger_row.tgenabled::text AS enabled,
                 trigger_row.tgdeferrable,
                 trigger_row.tginitdeferred,
                 replace(
                   replace(
                     pg_get_triggerdef(trigger_row.oid, true),
                     format('%I.', namespace.nspname),
                     '$SCHEMA$.'
                   ),
                   '"' || replace(namespace.nspname, '"', '""') || '".',
                   '$SCHEMA$.'
                 ) AS definition
            FROM pg_trigger trigger_row
            JOIN pg_class target ON target.oid = trigger_row.tgrelid
            JOIN pg_namespace namespace ON namespace.oid = target.relnamespace
           WHERE namespace.nspname = $1
             AND NOT trigger_row.tgisinternal
             AND trigger_row.tgname = ANY($2)
        )
        SELECT tgname,
               md5(
                 tgname || '|relation=' || relation_name ||
                 '|enabled=' || enabled ||
                 '|deferrable=' || tgdeferrable::text ||
                 '|initially_deferred=' || tginitdeferred::text ||
                 '|definition=' || definition
               ) AS fingerprint
          FROM trigger_contract
         ORDER BY tgname
        """,
        [prefix, @trigger_names],
        log: false
      )

    Enum.map(rows, fn [identity, fingerprint] -> {identity, fingerprint} end)
  end

  defp signatures(repo, prefix) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT p.proname || '(' || replace(oidvectortypes(p.proargtypes), ', ', ',') ||
               ')->' || format_type(p.prorettype, NULL)
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = $1
           AND p.proname = ANY($2)
         ORDER BY 1
        """,
        [prefix, @function_names],
        log: false
      )

    List.flatten(rows)
  end
end
